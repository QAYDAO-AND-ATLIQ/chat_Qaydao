"""
QAYDAO Agent Quality Guard — Phase 1 sidecar.
Receives Chatwoot message_created webhooks, classifies (rules-only), stores alerts,
posts internal alert back as a PRIVATE NOTE (invisible to customer), serves basic report + CSV.

Hard guarantees:
- Never connects to chatwoot_production. Only DB is the isolated quality_guard DB.
- Only Chatwoot contact is the public Application API on chatwoot_web, using the dedicated bot token.
- Alert-only in Phase 1: NO message blocking.
"""
import os, io, csv, datetime, json
import asyncpg, httpx
from fastapi import FastAPI, Request, Response, Query
from classifier import classify, classify_first_reply, classify_closing, snippet, is_opening_template
import report_ui
import sla
import asyncio
import policy
import admin

QG_DB_DSN        = os.environ["QG_DB_DSN"]                # postgres://qguard:...@quality_guard_db:5432/quality_guard
CHATWOOT_BASE    = os.environ.get("CHATWOOT_BASE", "http://chatwoot_web:3000")
CHATWOOT_ACCOUNT = int(os.environ.get("CHATWOOT_ACCOUNT_ID", "1"))
BOT_TOKEN        = os.environ.get("CHATWOOT_BOT_TOKEN", "")
WEBHOOK_SECRET   = os.environ.get("QG_WEBHOOK_SECRET", "")
POST_ALERTS      = os.environ.get("QG_POST_ALERTS", "false").lower() == "true"  # gate: stays false until Step 5

app = FastAPI(title="QAYDAO Quality Guard")
report_ui.bind_pool(lambda: pool())
policy.bind_pool(lambda: pool())
admin.bind_pool(lambda: pool())
app.include_router(report_ui.router, prefix="/quality-guard")

@app.on_event("startup")
async def _start_sla_loop():
    asyncio.create_task(sla.background_loop(pool, _store_alert,
                        lambda cid, txt: _post_private_note(cid, txt)))
_pool = None

async def pool():
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(QG_DB_DSN, min_size=1, max_size=5)
    return _pool

@app.get("/health")
async def health():
    try:
        p = await pool()
        async with p.acquire() as c:
            await c.fetchval("SELECT 1")
        return {"status": "ok", "post_alerts": POST_ALERTS}
    except Exception as e:
        return {"status": "degraded", "error": str(e)}

def _is_private(msg: dict) -> bool:
    return bool(msg.get("private")) or msg.get("message_type") in ("template",) and False

async def _store_alert(rec: dict):
    p = await pool()
    async with p.acquire() as c:
        # repeat detection: same employee + same alert_type in last 7 days
        prev = await c.fetchval(
            "SELECT count(*) FROM qg_alerts WHERE employee_email=$1 AND alert_type=$2 "
            "AND created_at > now() - interval '7 days'",
            rec.get("employee_email"), rec.get("alert_type"))
        rec["is_repeated"] = prev > 0
        rec["repeated_count"] = prev + 1
        # auto-escalation: same employee repeats the SAME alert_type 3+ times within 7 days
        # -> raise severity to high (turns red in the report) and set the explicit reason.
        if rec.get("employee_email") and rec["repeated_count"] >= 3:
            rec["severity"] = "high"
            rec["ai_reason"] = "\u0643\u0631\u0631 \u0627\u0644\u0645\u0648\u0638\u0641 \u0646\u0641\u0633 \u0627\u0644\u062e\u0637\u0623 3 \u0645\u0631\u0627\u062a \u062e\u0644\u0627\u0644 \u0623\u0633\u0628\u0648\u0639"
            rec["matched_rule"] = (rec.get("matched_rule") or "") + " | auto_escalated"
        return await c.fetchval("""
            INSERT INTO qg_alerts
            (account_id, conversation_id, message_id, inbox_id, user_id, employee_name,
             employee_email, channel_type, alert_type, severity, message_type, message_direction,
             is_private, message_snippet, ai_reason, suggested_correction, policy_reference,
             matched_rule, is_repeated, repeated_count, official_policy_snippet, source_url)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22)
            RETURNING id
        """, rec["account_id"], rec["conversation_id"], rec.get("message_id"), rec.get("inbox_id"),
             rec.get("user_id"), rec.get("employee_name"), rec.get("employee_email"),
             rec.get("channel_type"), rec["alert_type"], rec["severity"], rec.get("message_type"),
             rec.get("message_direction"), rec.get("is_private", False), rec.get("message_snippet"),
             rec.get("ai_reason"), rec.get("suggested_correction"), rec.get("policy_reference"),
             rec.get("matched_rule"), rec.get("is_repeated", False), rec.get("repeated_count", 1),
             rec.get("official_policy_snippet"), rec.get("source_url"))

async def _post_private_note(conversation_id: int, text: str):
    if not (POST_ALERTS and BOT_TOKEN):
        return  # gated off until Step 5
    url = f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conversation_id}/messages"
    async with httpx.AsyncClient(timeout=10) as cl:
        await cl.post(url, headers={"api_access_token": BOT_TOKEN, "X-Forwarded-Proto": "https"},
                      json={"content": text, "message_type": "outgoing", "private": True})

@app.post("/webhook")
async def webhook(request: Request, secret: str = Query(default="")):
    if WEBHOOK_SECRET and secret != WEBHOOK_SECRET:
        return Response(status_code=403)
    body = await request.json()
    event = body.get("event")

    # ---- conversation status changed -> only act when resolved ----
    if event == "conversation_status_changed":
        conv = body.get("conversation") or body
        status = (conv.get("status") or body.get("status") or "")
        if str(status).lower() != "resolved":
            return {"skip": "not_resolved"}
        return await _handle_resolved(conv)

    if event != "message_created":
        return {"skip": "event"}

    msg = body.get("message") or body
    conv = (body.get("conversation") or {})
    sender = (msg.get("sender") or {})
    sender_type = (msg.get("sender_type") or sender.get("type") or "")
    # ONLY human agents are monitored. Everything else (Contact, AgentBot, Captain::Assistant,
    # Captain, bots) is excluded from Quality Guard entirely.
    HUMAN_TYPES = ("user", "User")
    BOT_USER_IDS = {14, 2}  # 14=Quality Guard bot, 2=QAYDAO Admin (system-alerts account, not an agent)
    if sender_type not in HUMAN_TYPES:
        # customer (Contact) message -> start first-response SLA timer; bots -> ignore completely
        if str(sender_type).lower() in ("contact",) and not bool(msg.get("private")):
            await sla.on_customer_message(pool, conv, msg)
            await _mark_customer_engaged(conv.get("id") or msg.get("conversation_id"))
        return {"skip": "not_human:" + str(sender_type)}
    # extra guard: exclude known bot user ids and any AI-assistant identities by name/email
    _sid = sender.get("id")
    _sname = (sender.get("name") or "").strip().lower()
    _semail = (sender.get("email") or "").strip().lower()
    if _sid in BOT_USER_IDS or _sname in ("qaydao ai", "qaydao admin", "captain", "bot") or "bot@" in _semail or _semail == "admin@qaydao.com":
        return {"skip": "bot_excluded"}

    is_priv = bool(msg.get("private"))
    conv_id = conv.get("id") or msg.get("conversation_id")
    # agent (human, not the QG bot) external reply clears the first-response timer
    if not is_priv and sender.get("id") != 14:
        await sla.on_agent_reply(pool, conv_id)

    base = {
        "account_id": conv.get("account_id") or CHATWOOT_ACCOUNT,
        "conversation_id": conv_id,
        "message_id": msg.get("id"),
        "inbox_id": conv.get("inbox_id"),
        "user_id": sender.get("id"),
        "employee_name": sender.get("name"),
        "employee_email": sender.get("email"),
        "channel_type": (conv.get("channel") or ""),
        "message_type": str(msg.get("message_type")),
        "message_direction": "internal_note" if is_priv else "to_customer",
        "is_private": is_priv,
        "message_snippet": snippet(msg.get("content", "")),
    }

    fired = []

    # 1) banned-phrase / style classification
    res = await admin.classify_db(msg.get("content", ""), is_priv)
    if not res:
        res = classify(body=msg.get("content", ""), is_private=is_priv,
                       message_type=msg.get("message_type"))
    if res:
        fired.append(res)

    # official-policy mismatch check (external replies only; deterministic, no AI)
    if not is_priv:
        pol = await policy.check_policy(msg.get("content", ""))
        if pol:
            fired.append(pol)

    # 2) greeting check — fire on the agent's FIRST reply that comes AFTER the customer has
    #    engaged. Uses an authoritative Chatwoot lookup (not a local flag) to avoid missed
    #    webhooks / races. The approved outreach opening template is never evaluated.
    if not is_priv and not is_opening_template(msg.get("content", "")):
        gstate = await _greeting_should_check(conv_id, msg.get("id"))
        if gstate:
            g = classify_first_reply(msg.get("content", ""))
            if g:
                fired.append(g)

    if not fired:
        return {"classified": "safe"}

    alert_ids = []
    for res in fired:
        rec = {**base, **res}
        alert_ids.append(await _store_alert(rec))
        await _post_private_note(conv_id, _fmt_note(res))
    return {"alert_ids": alert_ids, "count": len(alert_ids), "posted": POST_ALERTS}


def _fmt_note(res):
    return (f"\U0001f6e1\ufe0f \u062a\u0646\u0628\u064a\u0647 \u062c\u0648\u062f\u0629 \u062f\u0627\u062e\u0644\u064a (Quality Guard)\n"
            f"\u0627\u0644\u0646\u0648\u0639: {res['alert_type']} | \u0627\u0644\u062e\u0637\u0648\u0631\u0629: {res['severity']}\n"
            f"\u0627\u0644\u0633\u0628\u0628: {res['ai_reason']}\n"
            f"\u0627\u0644\u0645\u0642\u062a\u0631\u062d: {res['suggested_correction']}")


async def _greeting_should_check(conv_id, message_id):
    """Authoritative: True if customer engaged AND this is the first human agent reply,
    evaluated at most once per conversation."""
    if not conv_id:
        return False
    p = await pool()
    async with p.acquire() as c:
        row = await c.fetchrow("SELECT first_message_id FROM qg_seen_conversations WHERE conversation_id=$1", conv_id)
        if row and row["first_message_id"] is not None:
            return False  # already evaluated the first reply for this conversation
    # ask Chatwoot for the conversation's messages
    url = f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conv_id}/messages"
    try:
        async with httpx.AsyncClient(timeout=10) as cl:
            r = await cl.get(url, headers={"api_access_token": BOT_TOKEN, "X-Forwarded-Proto": "https"},
                             params={"per_page": 100})
        payload = r.json().get("payload", [])
    except Exception:
        return False
    customer_msgs = [m for m in payload if m.get("message_type") == 0]
    if not customer_msgs:
        return False  # customer hasn't engaged yet -> outbound opener, don't evaluate
    # is THIS message the first human (User) agent outgoing reply in the conversation?
    first_human = None
    for m in payload:
        if m.get("message_type") == 1 and not m.get("private"):
            st = (m.get("sender_type") or (m.get("sender") or {}).get("type") or "")
            sid = (m.get("sender") or {}).get("id")
            sname = ((m.get("sender") or {}).get("name") or "").strip().lower()
            if st in ("user", "User") and sid not in (14, 2) and sname not in ("qaydao ai", "qaydao admin", "captain", "bot"):
                # the approved outreach template is not a service reply -> skip it,
                # so the first SUBSTANTIVE human reply is the one evaluated for greeting
                if is_opening_template(m.get("content", "")):
                    continue
                first_human = m
                break
    if not first_human or first_human.get("id") != message_id:
        # mark as evaluated if a human first reply exists but isn't this one (so we don't re-check)
        if first_human:
            await _record_first_reply(conv_id, first_human.get("id"))
        return False
    await _record_first_reply(conv_id, message_id)
    return True


async def _record_first_reply(conv_id, message_id):
    p = await pool()
    async with p.acquire() as c:
        await c.execute(
            "INSERT INTO qg_seen_conversations (conversation_id, first_message_id) VALUES ($1,$2) "
            "ON CONFLICT (conversation_id) DO UPDATE SET first_message_id=EXCLUDED.first_message_id "
            "WHERE qg_seen_conversations.first_message_id IS NULL", conv_id, message_id)


async def _mark_customer_engaged(conv_id):
    if not conv_id:
        return
    p = await pool()
    async with p.acquire() as c:
        await c.execute(
            "INSERT INTO qg_seen_conversations (conversation_id, customer_engaged) VALUES ($1, TRUE) "
            "ON CONFLICT (conversation_id) DO UPDATE SET customer_engaged=TRUE", conv_id)


async def _customer_has_engaged(conv_id):
    if not conv_id:
        return False
    p = await pool()
    async with p.acquire() as c:
        return bool(await c.fetchval(
            "SELECT customer_engaged FROM qg_seen_conversations WHERE conversation_id=$1", conv_id))


async def _is_first_agent_reply(conv_id, message_id):
    """True if no prior agent external reply was recorded (first_message_id still NULL).
    Decoupled from row existence, since the row may already exist from customer engagement."""
    p = await pool()
    async with p.acquire() as c:
        row = await c.fetchrow("SELECT first_message_id FROM qg_seen_conversations WHERE conversation_id=$1", conv_id)
        if row and row["first_message_id"] is not None:
            return False
        await c.execute(
            "INSERT INTO qg_seen_conversations (conversation_id, first_message_id) VALUES ($1,$2) "
            "ON CONFLICT (conversation_id) DO UPDATE SET first_message_id=EXCLUDED.first_message_id "
            "WHERE qg_seen_conversations.first_message_id IS NULL", conv_id, message_id)
        return True


async def _handle_resolved(conv):
    """On resolve, fetch the last agent message and run closing/rating check."""
    conv_id = conv.get("id")
    if not conv_id:
        return {"skip": "no_conv"}
    # fetch recent messages to find last agent external reply
    url = f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conv_id}/messages"
    try:
        async with httpx.AsyncClient(timeout=10) as cl:
            r = await cl.get(url, headers={"api_access_token": BOT_TOKEN, "X-Forwarded-Proto": "https"})
        payload = r.json().get("payload", [])
    except Exception:
        return {"skip": "fetch_failed"}
    # last outgoing, non-private, HUMAN agent message (exclude bots/Captain/QG bot)
    last = None
    for m in reversed(payload):
        if m.get("message_type") == 1 and not m.get("private"):
            s = m.get("sender") or {}
            st = (m.get("sender_type") or s.get("type") or "")
            sname = (s.get("name") or "").strip().lower()
            if st not in ("user", "User"):
                continue
            if s.get("id") in (14, 2) or sname in ("qaydao ai", "qaydao admin", "captain", "bot") or (s.get("email") or "").strip().lower() == "admin@qaydao.com":
                continue
            last = m
            break
    if not last:
        return {"skip": "no_agent_msg"}
    res = classify_closing(last.get("content", ""))
    if not res:
        return {"classified": "safe"}
    s = last.get("sender") or {}
    rec = {
        "account_id": CHATWOOT_ACCOUNT, "conversation_id": conv_id,
        "message_id": last.get("id"), "inbox_id": conv.get("inbox_id"),
        "user_id": s.get("id"), "employee_name": s.get("name"), "employee_email": s.get("email"),
        "channel_type": (conv.get("channel") or ""), "message_type": "1",
        "message_direction": "to_customer", "is_private": False,
        "message_snippet": snippet(last.get("content", "")), **res,
    }
    alert_id = await _store_alert(rec)
    await _post_private_note(conv_id, _fmt_note(res))
    return {"alert_id": alert_id, "type": res["alert_type"], "posted": POST_ALERTS}


@app.get("/report")
async def report(date_from: str = Query(default=None), date_to: str = Query(default=None),
                 employee: str = Query(default=None), alert_type: str = Query(default=None),
                 severity: str = Query(default=None)):
    p = await pool()
    q = "SELECT * FROM qg_alerts WHERE 1=1"
    args, i = [], 0
    def add(cond, val):
        nonlocal i
        i += 1; args.append(val); return f" AND {cond} ${i}"
    if date_from: q += add("created_at >=", datetime.datetime.fromisoformat(date_from))
    if date_to:   q += add("created_at <=", datetime.datetime.fromisoformat(date_to))
    if employee:  q += add("employee_email =", employee)
    if alert_type:q += add("alert_type =", alert_type)
    if severity:  q += add("severity =", severity)
    q += " ORDER BY created_at DESC LIMIT 1000"
    async with p.acquire() as c:
        rows = await c.fetch(q, *args)
    return {"count": len(rows), "alerts": [dict(r) for r in rows]}

@app.get("/report.csv")
async def report_csv():
    p = await pool()
    async with p.acquire() as c:
        rows = await c.fetch("SELECT * FROM qg_alerts ORDER BY created_at DESC LIMIT 5000")
    buf = io.StringIO()
    if rows:
        w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow({k: ("" if v is None else v) for k, v in dict(r).items()})
    return Response(content=buf.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": "attachment; filename=quality_guard.csv"})
