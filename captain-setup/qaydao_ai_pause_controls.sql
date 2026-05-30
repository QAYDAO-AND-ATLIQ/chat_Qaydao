-- QAYDAO AI — pause controls (labels + macros) — idempotent.
-- Companion to patches/qaydao_captain_no_interrupt.rb (the guard reads these labels).
-- Recreate after any DB rebuild:
--   docker exec -i chatwoot_postgres psql -U chatwoot_user -d chatwoot_production \
--     < captain-setup/qaydao_ai_pause_controls.sql
-- Behavior: guard pauses QAYDAO AI per-conversation when an ai-off* label is
-- active (1h/4h/today by label age, or indefinite for plain ai-off), OR when a
-- real human agent replied within the last 3h (rolling). Account id = 1.

INSERT INTO labels (title,color,show_on_sidebar,account_id,created_at,updated_at)
SELECT v.title, v.color, false, 1, now(), now()
FROM (VALUES
  ('ai-off','#6b7280'),
  ('ai-off-1h','#f59e0b'),
  ('ai-off-4h','#f97316'),
  ('ai-off-today','#ef4444')
) AS v(title,color)
WHERE NOT EXISTS (SELECT 1 FROM labels l WHERE l.account_id=1 AND l.title=v.title);

INSERT INTO macros (account_id,name,visibility,created_by_id,updated_by_id,actions,created_at,updated_at)
SELECT 1, v.name, 1, 2, 2, v.actions::jsonb, now(), now()
FROM (VALUES
  ('⏸️ إيقاف QAYDAO AI — ساعة',     '[{"action_name":"add_label","action_params":["ai-off-1h"]}]'),
  ('⏸️ إيقاف QAYDAO AI — ٤ ساعات',  '[{"action_name":"add_label","action_params":["ai-off-4h"]}]'),
  ('⏸️ إيقاف QAYDAO AI — لليوم',    '[{"action_name":"add_label","action_params":["ai-off-today"]}]'),
  ('⏸️ إيقاف QAYDAO AI — يدوي',     '[{"action_name":"add_label","action_params":["ai-off"]}]'),
  ('▶️ تشغيل QAYDAO AI',            '[{"action_name":"remove_label","action_params":["ai-off","ai-off-1h","ai-off-4h","ai-off-today"]}]')
) AS v(name,actions)
WHERE NOT EXISTS (SELECT 1 FROM macros m WHERE m.account_id=1 AND m.name=v.name);
