#!/bin/bash
# AI Quality Scorecard for QAYDAO AI (Captain) — re-runnable before/after tracker
# Usage: ./ai_quality_scorecard.sh "START_UTC" "END_UTC"   (e.g. "2026-05-20 00:00" "2026-05-28 23:28")
START="${1:-2026-05-20 00:00}"
END="${2:-now}"
[ "$END" = "now" ] && END=$(date -u '+%Y-%m-%d %H:%M')

docker exec chatwoot_postgres psql -U chatwoot_user -d chatwoot_production -P pager=off -c "
WITH ai AS (
  SELECT id, conversation_id, content
  FROM messages
  WHERE sender_type='Captain::Assistant'
    AND created_at >= '${START}' AND created_at < '${END}'
    AND content NOT LIKE 'Auto-%' AND (private=false OR private IS NULL) AND length(trim(content))>0
),
dup AS (
  SELECT conversation_id FROM ai WHERE length(content)>40
  GROUP BY conversation_id, content HAVING count(*)>=2
),
closes AS (
  SELECT conversation_id, min(created_at) close_at FROM messages
  WHERE content LIKE '%إنهاء هذه المحادثة%' AND sender_type='Captain::Assistant'
    AND created_at >= '${START}' AND created_at < '${END}' GROUP BY conversation_id
)
SELECT
  (SELECT count(*) FROM ai)                                                           AS total_replies,
  (SELECT count(*) FROM ai WHERE content LIKE 'العميل ي%' OR content LIKE '%لا توجد معلومات كافية%' OR content LIKE '%قد لا أملكها%' OR content LIKE '%قاعدة البيانات%') AS reasoning_leaks,
  (SELECT count(*) FROM ai WHERE content ILIKE '%unfortunately%' OR content ILIKE '% the customer %' OR content ILIKE '%I apologize%' OR content ILIKE '%I cannot%') AS english_leaks,
  (SELECT count(*) FROM ai WHERE content LIKE '%![%')                                  AS broken_img_md,
  (SELECT count(*) FROM ai WHERE content LIKE '%غير متوفر%' OR content LIKE '%غير متاح%') AS mentions_unavailable,
  (SELECT count(DISTINCT conversation_id) FROM dup)                                    AS convs_with_loops,
  (SELECT count(*) FROM messages WHERE sender_type='Captain::Assistant' AND content LIKE 'Auto-handoff:%' AND created_at >= '${START}' AND created_at < '${END}') AS auto_handoffs,
  (SELECT count(*) FROM ai WHERE content LIKE '%Exceeded maximum turns%')              AS max_turns_errors,
  (SELECT count(*) FROM closes)                                                        AS closes,
  (SELECT count(*) FROM closes cl WHERE EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id=cl.conversation_id AND m.message_type=0 AND m.created_at > cl.close_at)) AS reopened
;"
