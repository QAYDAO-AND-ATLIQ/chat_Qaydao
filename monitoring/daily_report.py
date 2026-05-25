#!/usr/bin/env python3
"""
QAYDAO AI — Daily Report to Rami via Telegram
Sends a concise daily summary: conversations, success rate, top questions,
handoffs, and replies that may need improvement.

Run via cron once a day (e.g. 8 PM Riyadh).
"""
import subprocess
import json
import os
from datetime import datetime
from zoneinfo import ZoneInfo

RIYADH = ZoneInfo("Asia/Riyadh")
ALERT_SCRIPT = "/root/chat-qaydao/monitoring/alert_rami.py"

PG = ["docker", "exec", "chatwoot_postgres", "psql", "-U", "chatwoot_user",
      "-d", "chatwoot_production", "-t", "-A", "-c"]


def q(sql: str) -> str:
    try:
        r = subprocess.run(PG + [sql], capture_output=True, text=True, timeout=30)
        return r.stdout.strip()
    except Exception:
        return ""


def main():
    now = datetime.now(tz=RIYADH)
    since = "NOW() - INTERVAL '24 hours'"

    total = q(f"SELECT COUNT(*) FROM conversations WHERE account_id=1 AND created_at > {since};")
    resolved = q(f"SELECT COUNT(*) FROM conversations WHERE account_id=1 AND status=1 AND last_activity_at > {since};")
    open_now = q("SELECT COUNT(*) FROM conversations WHERE account_id=1 AND status=0 AND last_activity_at > NOW() - INTERVAL '24 hours';")
    ai_replies = q(f"SELECT COUNT(*) FROM messages WHERE sender_type='Captain::Assistant' AND (private=false OR private IS NULL) AND content NOT LIKE 'Auto-handoff:%' AND created_at > {since};")
    handoffs = q(f"SELECT COUNT(DISTINCT conversation_id) FROM messages WHERE sender_type='Captain::Assistant' AND content LIKE 'Auto-handoff:%' AND created_at > {since};")

    # Replies flagged as needing improvement (English leak / broken markdown)
    flagged = q(f"""SELECT COUNT(*) FROM messages
        WHERE sender_type='Captain::Assistant' AND (private=false OR private IS NULL)
        AND content NOT LIKE 'Auto-handoff:%'
        AND (content LIKE '%![%' OR content ILIKE '%unfortunately%' OR content ILIKE '%I cannot%')
        AND created_at > {since};""")

    # New learning suggestions awaiting review
    pending_learn = q("SELECT COUNT(*) FROM captain_learning_suggestions WHERE status='pending';") or "0"

    # Top customer questions (last 24h), excluding greetings
    top_q = q(f"""SELECT string_agg(line, E'\\n') FROM (
        SELECT '• ' || LEFT(REGEXP_REPLACE(content, E'[\\n\\r]+', ' ', 'g'), 40) || ' (' || COUNT(*) || ')' AS line
        FROM messages
        WHERE message_type=0 AND sender_type='Contact'
          AND LENGTH(TRIM(content)) BETWEEN 6 AND 40
          AND content NOT ILIKE '%سلام%' AND content NOT ILIKE '%مرحب%'
          AND content NOT ILIKE '%شكر%' AND content NOT ILIKE '%تمام%'
          AND created_at > {since}
        GROUP BY LEFT(REGEXP_REPLACE(content, E'[\\n\\r]+', ' ', 'g'), 40)
        ORDER BY COUNT(*) DESC LIMIT 5
    ) t;""")

    def n(x, d="0"):
        return x if x and x.strip() else d

    report = f"""📊 تقرير QAYDAO AI اليومي
{now.strftime('%Y-%m-%d %H:%M')}

المحادثات (آخر 24 ساعة):
• إجمالي جديد: {n(total)}
• تم حلها: {n(resolved)}
• مفتوحة نشطة: {n(open_now)}
• ردود المساعد: {n(ai_replies)}
• تحويلات لموظف: {n(handoffs)}

الجودة:
• ردود تحتاج مراجعة: {n(flagged)}
• اقتراحات تعلّم بانتظارك: {n(pending_learn)}

أبرز أسئلة العملاء:
{n(top_q, '• لا يوجد')}

— لمراجعة الردود وتحسينها:
chat.qaydao.com/products/captain/replies"""

    try:
        subprocess.run(["python3", ALERT_SCRIPT, "تقرير QAYDAO AI اليومي", report],
                       capture_output=True, text=True, timeout=40)
    except Exception as e:
        print(f"report send failed: {e}")
    print("report sent")


if __name__ == "__main__":
    main()
