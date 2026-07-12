-- ============================================================================
-- Quality Guard — Migration 002: post-handoff SLA (رامي's decision 2026-07-12)
-- ----------------------------------------------------------------------------
-- Context: Captain AI public replies now stop the first-response SLA clock
-- (they ARE real replies — 50% direct answers, 40% of conversations fully
-- closed by AI with zero human involvement). But ~13% of Captain replies are
-- handoffs to the human team; those must NOT silently satisfy the SLA.
--
-- This migration adds:
--   1. qg_pending_handoff — the post-handoff timer table. Started when
--      Captain's private "Auto-handoff:" note arrives (structural signal,
--      no Arabic-text regex). Cleared ONLY by a public human agent reply.
--   2. handoff_response_delay alert type — manager-controlled from the
--      settings UI like every other type (threshold default 15 min: median
--      human follow-up after handoff is 7 min, p90 is 13.5h).
--
-- Idempotent: IF NOT EXISTS + ON CONFLICT DO NOTHING.
--
-- Apply:
--   docker exec -i quality_guard_db psql -U qguard -d quality_guard \
--     -v ON_ERROR_STOP=1 < migrations/002_handoff_sla.sql
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS qg_pending_handoff (
    conversation_id      INTEGER PRIMARY KEY,
    account_id           INTEGER,
    inbox_id             INTEGER,
    channel_type         TEXT,
    assignee_id          INTEGER,
    assignee_name        TEXT,
    assignee_email       TEXT,
    waiting_since        TIMESTAMPTZ,
    due_at               TIMESTAMPTZ,
    alerted              BOOLEAN DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_qg_pending_handoff_due ON qg_pending_handoff (due_at) WHERE NOT alerted;

INSERT INTO qg_alert_types
  (alert_type, name_ar, description_ar, category, scope, is_enabled, severity,
   max_per_conversation, cooldown_minutes, threshold_value, suggested_correction, is_system, sort_order)
VALUES
  ('handoff_response_delay',
   'تأخر الرد بعد تحويل الذكاء الاصطناعي',
   'حوّل QAYDAO AI المحادثة للفريق البشري ولم يرد أي موظف على العميل خلال المهلة المحددة. يبدأ العدّاد عند إشارة التحويل (Auto-handoff) ويوقفه رد بشري علني فقط — ردود الذكاء الاصطناعي لا توقفه.',
   'chat_standards', 'external', TRUE, 'medium',
   1, 0, 15,
   'يرجى الرد على العميل فوراً — المحادثة محوّلة من QAYDAO AI وتنتظر تدخلاً بشرياً.',
   TRUE, 15)
ON CONFLICT (alert_type) DO NOTHING;

COMMIT;
