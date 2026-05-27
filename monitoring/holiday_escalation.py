#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
QAYDAO Chat — Holiday Urgent Escalation
=======================================
During the Eid holiday (team away until Sat 30 May 2026), QAYDAO AI handles
routine chats but cannot resolve human-only matters. Any OPEN conversation whose
last real message is from the CUSTOMER and has been waiting beyond WAIT_MINUTES
means the AI either handed off (needs a human) or stalled — Rami should know.
Sends ONE consolidated alert via the existing alert_rami.py (Telegram + Email),
flagging priority / B2B / labels as extra markers.

De-dup: each conversation alerted once (state file).
Self-expiry: does nothing on/after END_DATE (KSA). Remove cron line after Eid.

Run:  python3 holiday_escalation.py            (live)
      DRY=1 python3 holiday_escalation.py       (print only)
"""
import json, os, subprocess, sys, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(HERE, "holiday_escalated.json")
ALERT_SCRIPT = os.path.join(HERE, "alert_rami.py")
END_DATE = datetime.date(2026, 5, 30)     # team returns; stop escalating
WAIT_MINUTES = 45                          # AI answers in seconds; 45m waiting = stuck
B2B_TEAM_ID = 3
SYSTEM_INBOX_ID = 7                         # 🚨 تنبيهات النظام — not a customer inbox
BASE_URL = "https://chat.qaydao.com/app/accounts/1/conversations/"
DRY = os.environ.get("DRY") == "1"

PSQL = ["docker", "exec", "-i", "chatwoot_postgres", "psql",
        "-U", "chatwoot_user", "-d", "chatwoot_production", "-t", "-A", "-F", "\t"]


def ksa_today():
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=3)).date()


def q(sql):
    r = subprocess.run(PSQL + ["-c", sql], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        sys.stderr.write("PSQL ERROR: " + r.stderr[:300] + "\n")
        sys.exit(2)
    return [ln for ln in r.stdout.splitlines() if ln.strip()]


def load_state():
    try:
        return set(json.load(open(STATE_FILE)))
    except Exception:
        return set()


def save_state(ids):
    json.dump(sorted(ids), open(STATE_FILE, "w"))


def main():
    if ksa_today() >= END_DATE:
        print("Holiday over — escalation disabled.")
        return

    sql = f"""
    WITH last_real AS (
      SELECT DISTINCT ON (conversation_id) conversation_id, message_type, created_at
      FROM messages WHERE message_type IN (0,1)
      ORDER BY conversation_id, created_at DESC
    )
    SELECT c.id, c.display_id, c.inbox_id,
      btrim(
        (CASE WHEN c.priority IS NOT NULL THEN 'أولوية:'||c.priority||' ' ELSE '' END) ||
        (CASE WHEN c.team_id = {B2B_TEAM_ID} THEN '[B2B] ' ELSE '' END) ||
        COALESCE((SELECT string_agg(t.name,',') FROM taggings tg JOIN tags t ON t.id=tg.tag_id
                  WHERE tg.taggable_type='Conversation' AND tg.taggable_id=c.id
                    AND tg.context='labels'),'')
      ) AS reason,
      round(EXTRACT(EPOCH FROM (now()-lr.created_at))/60)::int AS wait_min,
      COALESCE(regexp_replace(left(lm.content,90),E'[\\n\\r\\t]+',' ','g'),'') AS last_msg
    FROM conversations c
    JOIN last_real lr ON lr.conversation_id=c.id AND lr.message_type=0
    LEFT JOIN LATERAL (
      SELECT content FROM messages m
      WHERE m.conversation_id=c.id AND m.message_type=0 AND m.content IS NOT NULL AND m.content<>''
      ORDER BY m.created_at DESC LIMIT 1
    ) lm ON true
    WHERE c.status=0 AND c.inbox_id <> {SYSTEM_INBOX_ID}
      AND lr.created_at < now() - interval '{WAIT_MINUTES} minutes'
    ORDER BY wait_min DESC;
    """
    rows = []
    for ln in q(sql):
        p = ln.split("\t")
        if len(p) >= 6:
            rows.append({"id": int(p[0]), "disp": p[1], "inbox": p[2],
                         "reason": p[3].strip() or "بانتظار رد", "wait": p[4],
                         "msg": p[5].strip()})

    state = load_state()
    new = [r for r in rows if r["id"] not in state]
    print(f"waiting open={len(rows)} | already alerted={len(rows)-len(new)} | new={len(new)}")
    if not new:
        return

    lines = [f"محادثات مفتوحة العميل ينتظر فيها أكثر من {WAIT_MINUTES} دقيقة (إجازة العيد):", ""]
    for r in new:
        hrs = int(r["wait"]) // 60
        wait_h = f"{hrs}س {int(r['wait'])%60}د" if hrs else f"{r['wait']}د"
        lines.append(f"• #{r['disp']} — {r['reason']} — انتظار {wait_h}")
        if r["msg"]:
            lines.append(f"  «{r['msg']}»")
        lines.append(f"  {BASE_URL}{r['disp']}")
        lines.append("")
    body = "\n".join(lines).strip()
    subject = f"محادثات بانتظار متابعة ({len(new)}) — إجازة العيد"

    if DRY:
        print("--- DRY RUN ---\n" + subject + "\n\n" + body)
        return

    r = subprocess.run(["python3", ALERT_SCRIPT, subject, body],
                       capture_output=True, text=True, timeout=60)
    print(r.stdout.strip())
    if r.returncode != 0:
        sys.stderr.write("ALERT FAILED: " + r.stderr[:300] + "\n")
        sys.exit(3)
    save_state(state | {x["id"] for x in new})
    print(f"alerted + state saved ({len(new)} new).")


if __name__ == "__main__":
    main()
