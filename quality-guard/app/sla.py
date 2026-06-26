"""
QAYDAO Quality Guard — section 5: first-response delay SLA.
Working hours: Sat-Thu, 09:00-20:00 Asia/Riyadh. SLA = 5 minutes (configurable).
A customer message starts/refreshes the waiting timer; an agent reply clears it.
A background loop fires first_response_delay alerts for overdue conversations.
No customer-facing messages; alert is a Private Note only.
"""
import os
import datetime
import asyncio

try:
    from zoneinfo import ZoneInfo
    _RIYADH = ZoneInfo("Asia/Riyadh")
except Exception:
    _RIYADH = datetime.timezone(datetime.timedelta(hours=3))

SLA_MINUTES = int(os.environ.get("QG_FIRST_RESPONSE_SLA_MIN", "5"))
WORK_START_H = 9
WORK_END_H = 20
# Python weekday(): Mon=0..Sun=6. Friday=4 is OFF. Sat=5..Thu=3 are working.
_OFF_DAYS = {4}  # Friday


def in_working_hours(dt_utc: datetime.datetime) -> bool:
    local = dt_utc.astimezone(_RIYADH)
    if local.weekday() in _OFF_DAYS:
        return False
    return WORK_START_H <= local.hour < WORK_END_H


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


async def on_customer_message(pool, conv: dict, msg: dict):
    """Customer awaits a reply -> set/refresh pending timer (only within work hours)."""
    if not in_working_hours(now_utc()):
        return
    conv_id = conv.get("id") or msg.get("conversation_id")
    if not conv_id:
        return
    meta = conv.get("meta") or {}
    assignee = meta.get("assignee") or {}
    waiting = now_utc()
    due = waiting + datetime.timedelta(minutes=SLA_MINUTES)
    p = await pool()
    async with p.acquire() as c:
        # only (re)start the clock if not already waiting (don't push due_at forward on every customer msg)
        existing = await c.fetchval("SELECT 1 FROM qg_pending_response WHERE conversation_id=$1 AND NOT alerted", conv_id)
        if existing:
            return
        await c.execute("""
            INSERT INTO qg_pending_response
              (conversation_id, account_id, inbox_id, channel_type, assignee_id, assignee_name, assignee_email, waiting_since, due_at, alerted)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,FALSE)
            ON CONFLICT (conversation_id) DO UPDATE SET
              waiting_since=EXCLUDED.waiting_since, due_at=EXCLUDED.due_at, alerted=FALSE,
              assignee_id=EXCLUDED.assignee_id, assignee_name=EXCLUDED.assignee_name, assignee_email=EXCLUDED.assignee_email
        """, conv_id, conv.get("account_id"), conv.get("inbox_id"), (conv.get("channel") or ""),
             assignee.get("id"), assignee.get("name"), assignee.get("email"), waiting, due)


async def on_agent_reply(pool, conv_id):
    """Agent replied -> clear the pending timer."""
    if not conv_id:
        return
    p = await pool()
    async with p.acquire() as c:
        await c.execute("DELETE FROM qg_pending_response WHERE conversation_id=$1", conv_id)


async def sweep_overdue(pool, store_alert, post_note):
    """Find overdue, un-alerted pending rows; fire one alert each; mark alerted."""
    p = await pool()
    async with p.acquire() as c:
        rows = await c.fetch(
            "SELECT * FROM qg_pending_response WHERE NOT alerted AND due_at <= now()")
        for r in rows:
            # double-check still within work hours when firing
            if not in_working_hours(now_utc()):
                continue
            rec = {
                "account_id": r["account_id"] or 1,
                "conversation_id": r["conversation_id"],
                "message_id": None,
                "inbox_id": r["inbox_id"],
                "user_id": r["assignee_id"],
                "employee_name": r["assignee_name"],
                "employee_email": r["assignee_email"],
                "channel_type": r["channel_type"],
                "alert_type": "first_response_delay",
                "severity": "medium",
                "message_type": None,
                "message_direction": "to_customer",
                "is_private": False,
                "message_snippet": None,
                "ai_reason": "\u0644\u0645 \u064a\u062a\u0645 \u0627\u0644\u0631\u062f \u0639\u0644\u0649 \u0627\u0644\u0639\u0645\u064a\u0644 \u062e\u0644\u0627\u0644 \u0645\u062f\u0629 \u0627\u0644\u0631\u062f \u0627\u0644\u0623\u0648\u0644\u064a \u0627\u0644\u0645\u0639\u062a\u0645\u062f\u0629 \u062e\u0644\u0627\u0644 \u0623\u0648\u0642\u0627\u062a \u0627\u0644\u062f\u0648\u0627\u0645.",
                "suggested_correction": "\u064a\u0631\u062c\u0649 \u0627\u0644\u0631\u062f \u0639\u0644\u0649 \u0627\u0644\u0639\u0645\u064a\u0644 \u0641\u0648\u0631\u0627\u064b \u0623\u0648 \u0625\u0631\u0633\u0627\u0644 \u0631\u0633\u0627\u0644\u0629 \u062a\u0648\u0636\u064a\u062d\u064a\u0629 \u0628\u0623\u0646 \u0627\u0644\u062d\u0627\u0644\u0629 \u0642\u064a\u062f \u0627\u0644\u0645\u0631\u0627\u062c\u0639\u0629.",
                "policy_reference": "Section 5",
                "matched_rule": "first_response_sla",
            }
            try:
                await store_alert(rec)
                note = (f"\U0001f6e1\ufe0f \u062a\u0646\u0628\u064a\u0647 \u062c\u0648\u062f\u0629 \u062f\u0627\u062e\u0644\u064a (Quality Guard)\n"
                        f"\u0627\u0644\u0646\u0648\u0639: first_response_delay | \u0627\u0644\u062e\u0637\u0648\u0631\u0629: medium\n"
                        f"\u0627\u0644\u0633\u0628\u0628: {rec['ai_reason']}\n"
                        f"\u0627\u0644\u0625\u062c\u0631\u0627\u0621: {rec['suggested_correction']}")
                await post_note(r["conversation_id"], note)
            finally:
                await c.execute("UPDATE qg_pending_response SET alerted=TRUE WHERE conversation_id=$1", r["conversation_id"])


async def background_loop(pool, store_alert, post_note, interval=30):
    while True:
        try:
            await sweep_overdue(pool, store_alert, post_note)
        except Exception as e:
            print("sla sweep error:", e)
        await asyncio.sleep(interval)
