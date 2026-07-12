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
from fastapi import FastAPI, Request, Response, Query, Body
from classifier import classify, classify_first_reply, classify_closing, snippet, is_opening_template, is_template_message, classify_customer_abuse
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
# Inboxes fully invisible to Quality Guard (system/monitoring inboxes, e.g. 7 = 🚨 تنبيهات النظام).
# Comma-separated ids, set in docker-compose — extendable without a rebuild.
EXCLUDED_INBOXES = {int(x) for x in os.environ.get("QG_EXCLUDED_INBOXES", "").replace(" ", "").split(",") if x}

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
    """Store an alert IF the manager-controlled gate allows it.
    Returns the new alert id, or None when the alert is suppressed
    (type disabled / per-conversation cap reached / inside cooldown).
    Callers MUST NOT post a private note when this returns None."""
    p = await pool()

    # ═══ ALERT-TYPE ENFORCEMENT GATE ═══
    # at is None (unknown type / table dropped) => fail-open: store as before.
    at = await admin.get_alert_type(rec["alert_type"])
    if at is not None:
        # 1) type disabled by the manager
        if not at["is_enabled"]:
            return None

        async with p.acquire() as c:
            # 2) per-conversation repeat cap (0 = unlimited)
            cap = at["max_per_conversation"] or 0
            if cap > 0 and rec.get("conversation_id"):
                seen = await c.fetchval(
                    "SELECT count(*) FROM qg_alerts WHERE conversation_id=$1 AND alert_type=$2",
                    rec["conversation_id"], rec["alert_type"])
                if seen >= cap:
                    return None

            # 3) cooldown window (0 = none)
            cd = at["cooldown_minutes"] or 0
            if cd > 0 and rec.get("conversation_id"):
                recent = await c.fetchval(
                    "SELECT 1 FROM qg_alerts WHERE conversation_id=$1 AND alert_type=$2 "
                    "AND created_at > now() - ($3 || ' minutes')::interval LIMIT 1",
                    rec["conversation_id"], rec["alert_type"], str(cd))
                if recent:
                    return None

        # 4) severity comes from the table (manager override);
        #    auto-escalation below may still raise it to high.
        rec["severity"] = at["severity"]
    # ═══ END GATE ═══

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

    # ---- excluded inboxes (monitoring/system) -> fully invisible to QG ----
    _conv_probe = body.get("conversation") or body
    _inbox_probe = _conv_probe.get("inbox_id") or (body.get("inbox") or {}).get("id")
    try:
        if _inbox_probe is not None and int(_inbox_probe) in EXCLUDED_INBOXES:
            return {"skip": "excluded_inbox", "inbox_id": int(_inbox_probe)}
    except (TypeError, ValueError):
        pass

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
    # Chatwoot's real webhook sends message_type as a string ("incoming"/"outgoing"/"template")
    # and often sender_type=None for customer messages. Detect the customer side by message_type.
    _mt = msg.get("message_type")
    _is_incoming = (str(_mt).lower() == "incoming") or (_mt == 0)
    _is_customer = _is_incoming or (str(sender_type).lower() == "contact")
    # ONLY human agents are monitored. Everything else (Contact, AgentBot, Captain::Assistant,
    # Captain, bots) is excluded from Quality Guard entirely.
    HUMAN_TYPES = ("user", "User")
    BOT_USER_IDS = {14, 2}  # 14=Quality Guard bot, 2=QAYDAO Admin (system-alerts account, not an agent)

    # ---- SLA clocks (رامي's decision 2026-07-12) ----
    # Any PUBLIC OUTGOING message that actually reaches the customer stops the
    # first-response clock — human or AI alike. Excluded: private notes, the QG
    # bot itself (id=14), activity/template system messages (not "outgoing").
    # The post-handoff clock is stricter: only a real human agent clears it.
    _is_outgoing = (str(_mt).lower() == "outgoing") or (_mt == 1)
    _is_public = not bool(msg.get("private"))
    _sender_id = (msg.get("sender") or {}).get("id")
    _conv_id_early = conv.get("id") or msg.get("conversation_id")
    _is_qg_bot = (sender_type in HUMAN_TYPES and _sender_id == 14)
    if _is_outgoing and _is_public and not _is_qg_bot:
        await sla.on_agent_reply(pool, _conv_id_early)
        if sender_type in HUMAN_TYPES and _sender_id not in BOT_USER_IDS:
            await sla.on_human_reply_after_handoff(pool, _conv_id_early)

    # Captain handed off to the human team -> start the handoff clock.
    # Structural signal (its own private note), no Arabic-text matching.
    if (str(sender_type) == "Captain::Assistant" and bool(msg.get("private"))
            and str(msg.get("content") or "").lstrip().startswith("Auto-handoff:")):
        await sla.on_handoff(pool, conv, msg)

    if sender_type not in HUMAN_TYPES:
        # customer (incoming) message -> SLA timer + customer-abuse check; bots -> ignore
        if _is_customer and not bool(msg.get("private")):
            await sla.on_customer_message(pool, conv, msg)
            cid = conv.get("id") or msg.get("conversation_id")
            await _mark_customer_engaged(cid)
            # detect customer abuse/threats and post an internal support note for the agent
            # prefer DB rules (scope='customer', editable from settings); fall back to code
            try:
                cab = await admin.classify_db_customer(msg.get("content", ""))
            except Exception:
                cab = None
            if not cab:
                cab = classify_customer_abuse(msg.get("content", ""))
            if cab:
                rec = {
                    "account_id": conv.get("account_id") or CHATWOOT_ACCOUNT,
                    "conversation_id": cid, "message_id": msg.get("id"),
                    "inbox_id": conv.get("inbox_id"),
                    "user_id": None, "employee_name": None, "employee_email": None,
                    "channel_type": (conv.get("channel") or ""),
                    "message_type": str(msg.get("message_type")),
                    "message_direction": "from_customer", "is_private": True,
                    "message_snippet": snippet(msg.get("content", "")), **cab,
                }
                aid = await _store_alert(rec)
                if aid is None:
                    return {"suppressed": True, "type": rec["alert_type"]}
                await _post_private_note(cid, _fmt_note(rec))
                return {"alert_id": aid, "type": "customer_abuse", "posted": POST_ALERTS}
        return {"skip": "not_human:" + str(sender_type)}
    # extra guard: exclude known bot user ids and any AI-assistant identities by name/email
    _sid = sender.get("id")
    _sname = (sender.get("name") or "").strip().lower()
    _semail = (sender.get("email") or "").strip().lower()
    if _sid in BOT_USER_IDS or _sname in ("qaydao ai", "qaydao admin", "captain", "bot") or "bot@" in _semail or _semail == "admin@qaydao.com":
        return {"skip": "bot_excluded"}

    is_priv = bool(msg.get("private"))
    conv_id = conv.get("id") or msg.get("conversation_id")
    # enrich the conversation sidebar with client IP / city / country (idempotent, best-effort)
    asyncio.create_task(_enrich_client_info(conv_id))
    # (first-response + handoff timers are cleared earlier, in the unified SLA-clocks block)

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

    # excessive internal notes check (fires once per conversation when threshold exceeded)
    if is_priv:
        note_alert = await _excessive_notes_check(conv_id)
        if note_alert:
            fired.append(note_alert)

    # 2) greeting check — fire on the agent's FIRST reply that comes AFTER the customer has
    #    engaged. Uses an authoritative Chatwoot lookup (not a local flag) to avoid missed
    #    webhooks / races. The approved outreach opening template is never evaluated.
    #    2026-07-11 FIX (Omar): pass the full msg payload so the classifier can read
    #    Chatwoot's authoritative template flag (content_type / additional_attributes)
    #    instead of guessing from a hardcoded phrase list.
    if not is_priv and not is_template_message(msg) and not is_opening_template(msg.get("content", "")):
        gstate = await _greeting_should_check(conv_id, msg.get("id"))
        if gstate:
            g = classify_first_reply(msg.get("content", ""), msg)
            if g:
                fired.append(g)

    if not fired:
        return {"classified": "safe"}

    alert_ids = []
    suppressed = 0
    for res in fired:
        rec = {**base, **res}
        aid = await _store_alert(rec)
        if aid is None:
            suppressed += 1
            continue
        alert_ids.append(aid)
        await _post_private_note(conv_id, _fmt_note(rec))
    return {"alert_ids": alert_ids, "count": len(alert_ids),
            "suppressed": suppressed, "posted": POST_ALERTS}


# Arabic display labels for in-conversation notes (internal keys stay unchanged in code/DB)
ALERT_TYPE_AR = {
    "abuse": "\u0625\u0633\u0627\u0621\u0629/\u0623\u0633\u0644\u0648\u0628",
    "unprofessional_reply": "\u0631\u062f \u063a\u064a\u0631 \u0645\u0647\u0646\u064a",
    "unprofessional_note": "\u0646\u0648\u062a \u063a\u064a\u0631 \u0645\u0647\u0646\u064a",
    "internal_argument": "\u062c\u062f\u0627\u0644 \u062f\u0627\u062e\u0644\u064a",
    "policy_risk": "\u0645\u062e\u0627\u0637\u0631\u0629 \u0633\u064a\u0627\u0633\u0629",
    "sales_risk": "\u0645\u062e\u0627\u0637\u0631\u0629 \u0633\u0639\u0631\u064a\u0629",
    "delay_handling_risk": "\u062a\u0639\u0627\u0645\u0644 \u0645\u0639 \u0627\u0644\u062a\u0623\u062e\u064a\u0631",
    "missing_greeting": "\u0646\u0642\u0635 \u062a\u0631\u062d\u064a\u0628",
    "missing_closing_check": "\u0646\u0642\u0635 \u062e\u062a\u0627\u0645",
    "missing_rating_close": "\u0646\u0642\u0635 \u0637\u0644\u0628 \u062a\u0642\u064a\u064a\u0645",
    "first_response_delay": "\u062a\u0623\u062e\u0631 \u0627\u0644\u0631\u062f \u0627\u0644\u0623\u0648\u0644\u064a",
    "handoff_response_delay": "\u062a\u0623\u062e\u0631 \u0627\u0644\u0631\u062f \u0628\u0639\u062f \u062a\u062d\u0648\u064a\u0644 \u0627\u0644\u0630\u0643\u0627\u0621 \u0627\u0644\u0627\u0635\u0637\u0646\u0627\u0639\u064a",
    "official_policy_mismatch": "\u0645\u062e\u0627\u0644\u0641\u0629 \u0633\u064a\u0627\u0633\u0629 \u0631\u0633\u0645\u064a\u0629",
    "customer_abuse": "\u0625\u0633\u0627\u0621\u0629 \u0645\u0646 \u0627\u0644\u0639\u0645\u064a\u0644",
    "excessive_internal_notes": "\u0643\u062b\u0631\u0629 \u0627\u0644\u0645\u0644\u0627\u062d\u0638\u0627\u062a \u0627\u0644\u062f\u0627\u062e\u0644\u064a\u0629",
}
SEVERITY_AR = {
    "high": "\u0639\u0627\u0644\u064a\u0629",
    "medium": "\u0645\u062a\u0648\u0633\u0637\u0629",
    "low": "\u0645\u0646\u062e\u0641\u0636\u0629",
}

def _ar_type(t):
    return ALERT_TYPE_AR.get(t, t)

def _ar_sev(sv):
    return SEVERITY_AR.get(sv, sv)

def _fmt_note(res):
    return (f"\U0001f6e1\ufe0f \u062a\u0646\u0628\u064a\u0647 \u062c\u0648\u062f\u0629 \u062f\u0627\u062e\u0644\u064a (Quality Guard)\n"
            f"\u0627\u0644\u0646\u0648\u0639: {_ar_type(res['alert_type'])} | \u0627\u0644\u062e\u0637\u0648\u0631\u0629: {_ar_sev(res['severity'])}\n"
            f"\u0627\u0644\u0633\u0628\u0628: {res['ai_reason']}\n"
            f"\u0627\u0644\u0645\u0642\u062a\u0631\u062d: {res['suggested_correction']}")


async def _geo_lookup(ip):
    """Resolve city/country from an IP via ip-api.com, cached in qg_geoip_cache.
    Returns (city, country) or (None, None) on any failure. Never raises."""
    if not ip or ip in ("127.0.0.1", "::1"):
        return (None, None)
    p = await pool()
    # 1) cache hit
    try:
        async with p.acquire() as c:
            row = await c.fetchrow("SELECT city, country, resolved FROM qg_geoip_cache WHERE ip=$1", ip)
        if row:
            return (row["city"], row["country"]) if row["resolved"] else (None, None)
    except Exception:
        pass
    # 2) live lookup
    city = country = None
    resolved = False
    try:
        async with httpx.AsyncClient(timeout=6) as cl:
            r = await cl.get(f"http://ip-api.com/json/{ip}",
                             params={"fields": "status,country,city"})
        if r.status_code == 200:
            d = r.json()
            if d.get("status") == "success":
                city = d.get("city") or None
                country = d.get("country") or None
                resolved = bool(city or country)
    except Exception:
        resolved = False
    # 3) store in cache (even failures, to avoid hammering the API)
    try:
        async with p.acquire() as c:
            await c.execute(
                "INSERT INTO qg_geoip_cache (ip, city, country, resolved) VALUES ($1,$2,$3,$4) "
                "ON CONFLICT (ip) DO UPDATE SET city=EXCLUDED.city, country=EXCLUDED.country, "
                "resolved=EXCLUDED.resolved, fetched_at=now()", ip, city, country, resolved)
    except Exception:
        pass
    return (city, country)


async def _enrich_client_info(conv_id):
    """Populate conversation custom attributes (client_ip/city/country) from Chatwoot data.
    Idempotent: skips if client_ip already set. Reads only; writes NEW conversation attributes
    (does NOT modify the customer's original contact record). Missing values -> 'غير متوفر'."""
    if not conv_id:
        return
    headers = {"api_access_token": BOT_TOKEN, "X-Forwarded-Proto": "https"}
    try:
        async with httpx.AsyncClient(timeout=10) as cl:
            rc = await cl.get(f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conv_id}", headers=headers)
            if rc.status_code != 200:
                return
            cdata = rc.json()
            # already enriched? skip to avoid redundant writes
            ca = cdata.get("custom_attributes") or {}
            if ca.get("client_ip"):
                return
            contact = (cdata.get("meta") or {}).get("sender") or {}
            contact_id = contact.get("id")
            conv_addl = cdata.get("additional_attributes") or {}
            # IP can be on the conversation or the contact record
            ip = conv_addl.get("created_at_ip")
            city = None
            country = None
            if contact_id:
                rci = await cl.get(f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/contacts/{contact_id}", headers=headers)
                if rci.status_code == 200:
                    aa = (rci.json().get("payload") or {}).get("additional_attributes") or {}
                    ip = ip or aa.get("created_at_ip")
                    city = aa.get("city")
                    country = aa.get("country") or aa.get("country_code")
            # GeoIP enrichment: if city/country missing but we have an IP, resolve it
            if ip and not (city and country):
                geo_city, geo_country = await _geo_lookup(ip)
                city = city or geo_city
                country = country or geo_country
            NA = "\u063a\u064a\u0631 \u0645\u062a\u0648\u0641\u0631"  # غير متوفر
            payload = {"custom_attributes": {
                "client_ip": ip or NA,
                "client_city": city or NA,
                "client_country": country or NA,
            }}
            await cl.post(f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conv_id}/custom_attributes",
                          headers={**headers, "Content-Type": "application/json"}, json=payload)
    except Exception:
        return


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
    # 2026-07-11 FIX (Omar): per_page=100 silently truncated long conversations, so the
    # real first reply fell outside the window and QG evaluated a MID-CONVERSATION message
    # instead — demanding a greeting from "العفو عزيزي" or even a closing message.
    # 44 of 80 remaining missing_greeting alerts were NOT first replies at all.
    # Fetch the earliest page explicitly (oldest-first) so the true first reply is present.
    url = f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conv_id}/messages"
    try:
        async with httpx.AsyncClient(timeout=10) as cl:
            r = await cl.get(url, headers={"api_access_token": BOT_TOKEN, "X-Forwarded-Proto": "https"},
                             params={"per_page": 100})
        payload = r.json().get("payload", [])
    except Exception:
        return False
    # sort oldest-first by id: never rely on API ordering when picking "the first" reply
    payload = sorted(payload, key=lambda m: (m.get("id") or 0))
    customer_msgs = [m for m in payload if m.get("message_type") == 0]
    if not customer_msgs:
        return False  # customer hasn't engaged yet -> outbound opener, don't evaluate

    # GUARD (2026-07-11): if the message we are asked to judge is OLDER than the oldest
    # message we can see, our window is incomplete and we cannot know what the first reply
    # was. Never accuse on a partial view — skip and mark evaluated.
    oldest_seen = payload[0].get("id") if payload else None
    if oldest_seen is not None and message_id is not None and message_id < oldest_seen:
        await _record_first_reply(conv_id, message_id)
        return False

    # is THIS message the first human (User) agent outgoing reply in the conversation?
    first_human = None
    ai_engaged = False  # Captain/AgentBot spoke publicly to the customer before the first human reply
    for m in payload:
        if m.get("message_type") == 1 and not m.get("private"):
            st = (m.get("sender_type") or (m.get("sender") or {}).get("type") or "")
            sid = (m.get("sender") or {}).get("id")
            sname = ((m.get("sender") or {}).get("name") or "").strip().lower()
            if str(st).lower() in ("captain_assistant", "captain::assistant", "agent_bot", "agentbot") \
               or sname in ("qaydao ai", "captain"):
                ai_engaged = True
                continue
            if st in ("user", "User") and sid not in (14, 2) and sname not in ("qaydao ai", "qaydao admin", "captain", "bot"):
                # the approved outreach template is not a service reply -> skip it,
                # so the first SUBSTANTIVE human reply is the one evaluated for greeting
                if is_opening_template(m.get("content", "")):
                    continue
                # authoritative template flag (Facebook/WhatsApp sends are not CS replies)
                if is_template_message(m):
                    continue
                first_human = m
                break
    if not first_human or first_human.get("id") != message_id:
        # mark as evaluated if a human first reply exists but isn't this one (so we don't re-check)
        if first_human:
            await _record_first_reply(conv_id, first_human.get("id"))
        return False
    await _record_first_reply(conv_id, message_id)
    # قرار 2026-07-12: إن رحّب Captain بالعميل علنياً قبل أول رد بشري، يُعفى الموظف
    # من الترحيب — انضم لمحادثة جارية افتتحها الذكاء الاصطناعي، لا يُطالب بترحيب ثانٍ.
    if ai_engaged:
        return False
    return True


async def _mark_closing_checked(conv_id):
    p = await pool()
    async with p.acquire() as c:
        await c.execute(
            "INSERT INTO qg_seen_conversations (conversation_id, closing_checked) VALUES ($1, TRUE) "
            "ON CONFLICT (conversation_id) DO UPDATE SET closing_checked=TRUE", conv_id)


async def _excessive_notes_check(conv_id):
    """If internal (private) notes by humans in this conversation exceed the configured
    threshold (default 5), fire ONE alert. Counts authoritatively via Chatwoot."""
    if not conv_id:
        return None
    p = await pool()
    async with p.acquire() as c:
        already = await c.fetchval(
            "SELECT notes_alerted FROM qg_seen_conversations WHERE conversation_id=$1", conv_id)
    if already:
        return None
    try:
        _fallback = int(await admin.get_setting("max_internal_notes", "5") or "5")
    except Exception:
        _fallback = 5
    limit = await admin.get_alert_type_threshold("excessive_internal_notes", _fallback)
    # count private notes authored by humans (exclude the QG bot id=14 and system id=2)
    try:
        async with httpx.AsyncClient(timeout=10) as cl:
            r = await cl.get(f"{CHATWOOT_BASE}/api/v1/accounts/{CHATWOOT_ACCOUNT}/conversations/{conv_id}/messages",
                             headers={"api_access_token": BOT_TOKEN, "X-Forwarded-Proto": "https"},
                             params={"per_page": 100})
        if r.status_code != 200:
            return None
        payload = r.json().get("payload", [])
    except Exception:
        return None
    count = 0
    for m in payload:
        if m.get("private"):
            sid = (m.get("sender") or {}).get("id")
            if sid not in (14, 2):
                count += 1
    if count <= limit:
        return None
    # mark alerted so it fires only once
    async with p.acquire() as c:
        await c.execute(
            "INSERT INTO qg_seen_conversations (conversation_id, notes_alerted) VALUES ($1, TRUE) "
            "ON CONFLICT (conversation_id) DO UPDATE SET notes_alerted=TRUE", conv_id)
    return {
        "alert_type": "excessive_internal_notes",
        "severity": "medium",
        "matched_rule": "max_internal_notes",
        "ai_reason": "\u0639\u062f\u062f \u0627\u0644\u0645\u0644\u0627\u062d\u0638\u0627\u062a \u0627\u0644\u062f\u0627\u062e\u0644\u064a\u0629 \u0641\u064a \u0627\u0644\u0645\u062d\u0627\u062f\u062b\u0629 \u062a\u062c\u0627\u0648\u0632 \u0627\u0644\u062d\u062f \u0627\u0644\u0645\u0633\u0645\u0648\u062d (" + str(limit) + ").",
        "suggested_correction": "\u064a\u062c\u0628 \u0627\u0644\u062a\u0631\u0643\u064a\u0632 \u0645\u0639 \u0645\u062d\u0627\u062f\u062b\u0629 \u0627\u0644\u0639\u0645\u064a\u0644 \u0628\u062f\u0644\u0627\u064b \u0645\u0646 \u062a\u062d\u0648\u064a\u0644 \u0627\u0644\u0645\u062d\u0627\u062f\u062b\u0629 \u0625\u0644\u0649 \u062a\u0648\u0627\u0635\u0644 \u062f\u0627\u062e\u0644\u064a \u0628\u064a\u0646 \u0627\u0644\u0641\u0631\u064a\u0642\u061b \u0641\u064a \u0627\u0644\u062d\u0627\u0644\u0627\u062a \u0627\u0644\u0637\u0627\u0631\u0626\u0629 \u0627\u0633\u062a\u062e\u062f\u0645\u0648\u0627 \u0627\u0644\u0642\u0631\u0648\u0628 \u0623\u0648 \u0627\u0644\u0625\u064a\u0645\u064a\u0644.",
        "policy_reference": "Internal Notes / \u0627\u0644\u0645\u0644\u0627\u062d\u0638\u0627\u062a \u0627\u0644\u062f\u0627\u062e\u0644\u064a\u0629",
    }


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
    """On resolve, fetch the last agent message and run closing/rating check.
    Fires at most ONCE per conversation (WhatsApp 24h window may reopen/resolve repeatedly)."""
    conv_id = conv.get("id")
    if not conv_id:
        return {"skip": "no_conv"}
    # once-per-conversation guard for closing/rating
    p = await pool()
    async with p.acquire() as c:
        already = await c.fetchval(
            "SELECT closing_checked FROM qg_seen_conversations WHERE conversation_id=$1", conv_id)
    if already:
        return {"skip": "closing_already_checked"}
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
            # قرار 2026-07-12: يُقيَّم الموظف على رسالة الإغلاق فقط إن كان هو المُغلق
            # الفعلي. آخر رسالة علنية من Captain/AgentBot => الإغلاق آلي، ولا يُحاكم
            # موظف على رسالة وسطية كتبها قبل ساعات (حُوكمت رسالة عمرها 68 يوماً كإغلاق).
            # API identity is snake_case (captain_assistant); DB form kept as fallback.
            if str(st).lower() in ("captain_assistant", "captain::assistant", "agent_bot", "agentbot") \
               or sname in ("qaydao ai", "captain"):
                await _mark_closing_checked(conv_id)
                return {"skip": "ai_closed"}
            if st not in ("user", "User"):
                continue
            if s.get("id") in (14, 2) or sname in ("qaydao ai", "qaydao admin", "captain", "bot") or (s.get("email") or "").strip().lower() == "admin@qaydao.com":
                continue
            last = m
            break
    if not last:
        await _mark_closing_checked(conv_id)
        return {"skip": "no_agent_msg"}
    await _mark_closing_checked(conv_id)
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
    if alert_id is None:
        return {"suppressed": True, "type": res["alert_type"]}
    await _post_private_note(conv_id, _fmt_note(rec))
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

@app.put("/alerts/_moved_to_router")
async def _supervisor_status_moved():
    """Supervisor-status endpoints moved into report_ui.router (prefixed /quality-guard)."""
    return {"moved": True}


@app.get("/report.csv")
async def report_csv():
    # Delegate to the clean Arabic export in report_ui (single source of truth).
    # Kept for backward-compat with the root path; the UI uses /quality-guard/report.csv.
    return await report_ui.report_csv()
