#!/bin/bash
# Daily AI Quality Scorecard logger — appends one JSON snapshot (last 24h) to history.
# Scheduled via cron 18:00 UTC (= 21:00 Riyadh).
set -uo pipefail
HIST=/root/qaydao-products/logs/ai_scorecard_history.jsonl
mkdir -p /root/qaydao-products/logs
NOW=$(date -u '+%Y-%m-%d %H:%M')
START=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M')

ROW=$(docker exec chatwoot_postgres psql -U chatwoot_user -d chatwoot_production -t -A -c "
WITH ai AS (
  SELECT id, conversation_id, content FROM messages
  WHERE sender_type='Captain::Assistant' AND created_at >= '${START}' AND created_at < '${NOW}'
    AND content NOT LIKE 'Auto-%' AND (private=false OR private IS NULL) AND length(trim(content))>0
),
dup AS (SELECT conversation_id FROM ai WHERE length(content)>40 GROUP BY conversation_id, content HAVING count(*)>=2),
closes AS (SELECT conversation_id, min(created_at) close_at FROM messages
  WHERE content LIKE '%إنهاء هذه المحادثة%' AND sender_type='Captain::Assistant'
    AND created_at >= '${START}' AND created_at < '${NOW}' GROUP BY conversation_id)
SELECT json_build_object(
  'ts', '${NOW}', 'window', '24h',
  'total_replies', (SELECT count(*) FROM ai),
  'reasoning_leaks', (SELECT count(*) FROM ai WHERE content LIKE 'العميل ي%' OR content LIKE '%لا توجد معلومات كافية%' OR content LIKE '%قد لا أملكها%' OR content LIKE '%قاعدة البيانات%'),
  'english_leaks', (SELECT count(*) FROM ai WHERE content ILIKE '%unfortunately%' OR content ILIKE '% the customer %' OR content ILIKE '%I apologize%' OR content ILIKE '%I cannot%'),
  'broken_img_md', (SELECT count(*) FROM ai WHERE content LIKE '%![%'),
  'mentions_unavailable', (SELECT count(*) FROM ai WHERE content LIKE '%غير متوفر%' OR content LIKE '%غير متاح%'),
  'convs_with_loops', (SELECT count(DISTINCT conversation_id) FROM dup),
  'auto_handoffs', (SELECT count(*) FROM messages WHERE sender_type='Captain::Assistant' AND content LIKE 'Auto-handoff:%' AND created_at >= '${START}' AND created_at < '${NOW}'),
  'max_turns_errors', (SELECT count(*) FROM ai WHERE content LIKE '%Exceeded maximum turns%'),
  'closes', (SELECT count(*) FROM closes),
  'reopened', (SELECT count(*) FROM closes cl WHERE EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id=cl.conversation_id AND m.message_type=0 AND m.created_at > cl.close_at))
);" 2>/dev/null | tr -d '\n' | sed 's/^[[:space:]]*//')

if [ -n "$ROW" ]; then
  echo "$ROW" >> "$HIST"
  echo "[$(date -u '+%F %T')Z] scorecard logged: $ROW"
else
  echo "[$(date -u '+%F %T')Z] ERROR: empty scorecard result"
fi
