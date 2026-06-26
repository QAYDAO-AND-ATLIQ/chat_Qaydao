"""
Quality Guard — DB-backed rules + admin layer.
Rules/policies/settings live in the DB so admins edit them from the UI (no code changes).
In-memory cache with TTL keeps matching fast. All admin writes are audit-logged and passphrase-gated.
"""
import time, hashlib
from classifier import normalize

_pool = None
def bind_pool(p):
    global _pool
    _pool = p

# ---------------- rules cache ----------------
_cache = {"rules": None, "ts": 0}
_TTL = 30  # seconds

async def _load_rules():
    p = await _pool()
    async with p.acquire() as c:
        rows = await c.fetch("SELECT * FROM qg_rules WHERE is_active")
    rules = []
    for r in rows:
        rules.append({
            "phrase_norm": normalize(r["phrase"]),
            "scope": r["scope"], "alert_type": r["alert_type"], "severity": r["severity"],
            "ai_reason": r["ai_reason"], "suggested_correction": r["suggested_correction"],
            "policy_reference": r["policy_reference"], "matched_rule": r["phrase"],
        })
    return rules

async def get_rules(force=False):
    now = time.time()
    if force or _cache["rules"] is None or (now - _cache["ts"]) > _TTL:
        _cache["rules"] = await _load_rules()
        _cache["ts"] = now
    return _cache["rules"]

def invalidate():
    _cache["ts"] = 0

async def classify_db(body: str, is_private: bool):
    """Match against DB rules. Returns dict or None. Honors safe-overrides + doc-quote guard via classifier consts."""
    from classifier import SAFE_OVERRIDES, QUOTE_MARKERS, _hit
    t = normalize(body or "")
    if not t:
        return None
    scope = "note" if is_private else "external"
    if not is_private and _hit(t, SAFE_OVERRIDES):
        return None
    quoted = _hit(t, QUOTE_MARKERS) if is_private else None
    rules = await get_rules()
    # severity priority so 'high' wins ties
    order = {"high": 0, "medium": 1, "low": 2}
    best = None
    for r in rules:
        if r["scope"] != scope:
            continue
        if r["phrase_norm"] and r["phrase_norm"] in t:
            # doc-quote guard: client-label notes shouldn't fire inside a clear quote
            if quoted and r["alert_type"] == "unprofessional_note":
                continue
            if best is None or order.get(r["severity"], 9) < order.get(best["severity"], 9):
                best = r
    if not best:
        return None
    return {k: best[k] for k in ("alert_type","severity","matched_rule","ai_reason","suggested_correction","policy_reference")}

# ---------------- settings ----------------
async def get_setting(key, default=None):
    p = await _pool()
    async with p.acquire() as c:
        v = await c.fetchval("SELECT value FROM qg_settings WHERE key=$1", key)
    return v if v is not None else default

async def set_setting(key, value, actor):
    p = await _pool()
    async with p.acquire() as c:
        old = await c.fetchval("SELECT value FROM qg_settings WHERE key=$1", key)
        await c.execute("INSERT INTO qg_settings (key,value) VALUES ($1,$2) "
                        "ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now()", key, str(value))
        await _audit(c, actor, "update_setting", "settings", key, old, str(value))

# ---------------- admin auth ----------------
import os as _os, httpx as _httpx
_CW_BASE = _os.environ.get("CHATWOOT_BASE", "http://chatwoot_web:3000")
_CW_ACCOUNT = int(_os.environ.get("CHATWOOT_ACCOUNT_ID", "1"))

async def verify_admin_by_user_id(user_id):
    """Check whether a given Chatwoot user id is an administrator on this account,
    using the QG bot token. Used with the iframe's currentAgent context (no password)."""
    if not user_id:
        return None
    bot = _os.environ.get("CHATWOOT_BOT_TOKEN", "")
    if not bot:
        return None
    try:
        async with _httpx.AsyncClient(timeout=8) as cl:
            r = await cl.get(f"{_CW_BASE}/api/v1/accounts/{_CW_ACCOUNT}/agents",
                             headers={"api_access_token": bot, "X-Forwarded-Proto": "https"})
        if r.status_code != 200:
            return None
        for a in r.json():
            if a.get("id") == int(user_id) and a.get("role") == "administrator":
                return a.get("email") or f"user:{user_id}"
    except Exception:
        return None
    return None


async def verify_session_admin(access_token: str, client: str, uid: str):
    """Verify the viewer via their Chatwoot session headers (devise-token-auth) and admin role.
    Returns admin email if valid, else None. Fully automatic — read from cw_d_session_info cookie."""
    if not (access_token and client and uid):
        return None
    try:
        async with _httpx.AsyncClient(timeout=8) as cl:
            r = await cl.get(f"{_CW_BASE}/api/v1/profile",
                             headers={"access-token": access_token, "client": client, "uid": uid,
                                      "X-Forwarded-Proto": "https"})
        if r.status_code != 200:
            return None
        d = r.json()
        for a in (d.get("accounts") or []):
            if a.get("id") == _CW_ACCOUNT and a.get("role") == "administrator":
                return d.get("email") or f"user:{d.get('id')}"
    except Exception:
        return None
    return None


async def verify_chatwoot_admin(token: str):
    """Verify the viewer is a Chatwoot administrator on this account, using their own token.
    Returns the admin's email if valid, else None. No extra password needed."""
    if not token:
        return None
    try:
        async with _httpx.AsyncClient(timeout=8) as cl:
            r = await cl.get(f"{_CW_BASE}/api/v1/profile",
                             headers={"api_access_token": token, "X-Forwarded-Proto": "https"})
        if r.status_code != 200:
            return None
        d = r.json()
        for a in (d.get("accounts") or []):
            if a.get("id") == _CW_ACCOUNT and a.get("role") == "administrator":
                return d.get("email") or f"user:{d.get('id')}"
    except Exception:
        return None
    return None

async def verify_admin(passphrase: str) -> bool:
    if not passphrase:
        return False
    h = hashlib.sha256(passphrase.encode("utf-8")).hexdigest()
    stored = await get_setting("admin_pass_hash")
    return bool(stored) and h == stored

# ---------------- audit ----------------
async def _audit(c, actor, action, entity, entity_id, old, new):
    await c.execute(
        "INSERT INTO qg_audit_log (actor, action, entity, entity_id, old_value, new_value) "
        "VALUES ($1,$2,$3,$4,$5,$6)",
        actor or "unknown", action, entity, str(entity_id) if entity_id is not None else None,
        (str(old)[:2000] if old is not None else None), (str(new)[:2000] if new is not None else None))

async def audit_list(limit=200):
    p = await _pool()
    async with p.acquire() as c:
        rows = await c.fetch("SELECT * FROM qg_audit_log ORDER BY created_at DESC LIMIT $1", limit)
    return [dict(r) for r in rows]

# ---------------- rule CRUD (audited) ----------------
async def rules_list():
    p = await _pool()
    async with p.acquire() as c:
        rows = await c.fetch("SELECT * FROM qg_rules ORDER BY scope, alert_type, id")
    return [dict(r) for r in rows]

async def rule_create(data, actor):
    p = await _pool()
    async with p.acquire() as c:
        nid = await c.fetchval(
            "INSERT INTO qg_rules (rule_group, phrase, alert_type, severity, scope, ai_reason, suggested_correction, policy_reference) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id",
            data.get("rule_group","CUSTOM"), data["phrase"], data["alert_type"], data["severity"],
            data["scope"], data.get("ai_reason"), data.get("suggested_correction"), data.get("policy_reference"))
        await _audit(c, actor, "create_rule", "rules", nid, None, data.get("phrase"))
    invalidate()
    return nid

async def rule_update(rid, data, actor):
    p = await _pool()
    async with p.acquire() as c:
        old = await c.fetchrow("SELECT * FROM qg_rules WHERE id=$1", rid)
        if not old:
            return False
        await c.execute(
            "UPDATE qg_rules SET phrase=$2, alert_type=$3, severity=$4, scope=$5, ai_reason=$6, "
            "suggested_correction=$7, policy_reference=$8, is_active=$9, updated_at=now() WHERE id=$1",
            rid, data.get("phrase", old["phrase"]), data.get("alert_type", old["alert_type"]),
            data.get("severity", old["severity"]), data.get("scope", old["scope"]),
            data.get("ai_reason", old["ai_reason"]), data.get("suggested_correction", old["suggested_correction"]),
            data.get("policy_reference", old["policy_reference"]),
            data.get("is_active", old["is_active"]))
        await _audit(c, actor, "update_rule", "rules", rid, dict(old).get("phrase"), data.get("phrase", old["phrase"]))
    invalidate()
    return True

async def rule_delete(rid, actor):
    p = await _pool()
    async with p.acquire() as c:
        old = await c.fetchval("SELECT phrase FROM qg_rules WHERE id=$1", rid)
        await c.execute("UPDATE qg_rules SET is_active=FALSE, updated_at=now() WHERE id=$1", rid)
        await _audit(c, actor, "delete_rule", "rules", rid, old, None)
    invalidate()
    return True
