-- ============================================================================
-- Quality Guard — Migration 001: manager-controlled alert types
-- ----------------------------------------------------------------------------
-- Creates qg_alert_types (the control table read by the enforcement gate in
-- app._store_alert) and seeds the 14 system types.
--
-- Idempotent: safe to re-run on an existing database — the table/indexes are
-- IF NOT EXISTS and the seed is ON CONFLICT DO NOTHING, so it never overwrites
-- values a manager has since edited from the settings UI.
--
-- Seed values below were exported from the production DB on 2026-07-12 and
-- include the live per-conversation repeat caps (NOT the original all-zero
-- defaults): cap=1 for customer_abuse / first_response_delay /
-- missing_rating_close / missing_greeting, cap=2 for abuse /
-- unprofessional_reply, cap=0 (unlimited) for the remaining eight.
-- official_policy_mismatch ships disabled (reflects production reality:
-- qg_policies has no active rows, so the check is a no-op anyway).
--
-- Apply:
--   docker exec -i quality_guard_db psql -U qguard -d quality_guard \
--     -v ON_ERROR_STOP=1 < migrations/001_alert_types.sql
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS qg_alert_types (
  id                   BIGSERIAL PRIMARY KEY,
  alert_type           TEXT NOT NULL UNIQUE,
  name_ar              TEXT NOT NULL,
  description_ar       TEXT,
  category             TEXT NOT NULL DEFAULT 'other',
  scope                TEXT NOT NULL DEFAULT 'external',
  is_enabled           BOOLEAN NOT NULL DEFAULT TRUE,
  severity             TEXT NOT NULL DEFAULT 'medium',
  max_per_conversation INTEGER NOT NULL DEFAULT 1,   -- 0 = unlimited
  cooldown_minutes     INTEGER NOT NULL DEFAULT 0,   -- 0 = no cooldown
  threshold_value      INTEGER,                      -- SLA minutes / notes cap / NULL
  suggested_correction TEXT,
  is_system            BOOLEAN NOT NULL DEFAULT TRUE, -- system types can't be deleted
  sort_order           INTEGER NOT NULL DEFAULT 100,
  created_at           TIMESTAMPTZ DEFAULT now(),
  updated_at           TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_qg_alert_types_enabled
  ON qg_alert_types(alert_type) WHERE is_enabled;

-- The gate counts per-conversation repeats on every alert; this keeps it O(log n).
CREATE INDEX IF NOT EXISTS idx_qg_alerts_conv_type
  ON qg_alerts(conversation_id, alert_type, created_at DESC);

INSERT INTO qg_alert_types
(alert_type, name_ar, description_ar, category, scope, is_enabled, severity,
 max_per_conversation, cooldown_minutes, threshold_value, is_system, sort_order)
VALUES
('first_response_delay','تأخر أول رد (SLA)','تجاوز مهلة الرد الأول على العميل خلال ساعات العمل','chat_standards','external',TRUE,'medium',1,0,5,TRUE,10),
('missing_greeting','غياب الترحيب','الرد الأول لا يحتوي ترحيباً مع تعريف بالاسم أو العلامة','chat_standards','external',TRUE,'low',1,0,NULL,TRUE,20),
('missing_closing_check','غياب سؤال الختام','لم يُسأل العميل عن استفسار آخر قبل الإنهاء','chat_standards','external',TRUE,'low',0,0,NULL,TRUE,30),
('missing_rating_close','غياب رسالة التقييم','لم تُستخدم رسالة إغلاق مهنية أو ترك العميل مع التقييم','chat_standards','external',TRUE,'low',1,0,NULL,TRUE,40),
('excessive_internal_notes','كثرة الملاحظات الداخلية','عدد الملاحظات الداخلية تجاوز الحد المسموح','chat_standards','note',TRUE,'medium',0,0,5,TRUE,50),
('official_policy_mismatch','مخالفة السياسة الرسمية','الرد يخالف الأرقام أو الالتزامات في السياسة الرسمية','policy','external',FALSE,'high',0,0,NULL,TRUE,60),
('abuse','إساءة للعميل','لفظ مسيء أو اتهام للعميل في رد خارجي','agent_conduct','external',TRUE,'high',2,0,NULL,TRUE,70),
('unprofessional_reply','رد غير مهني','أسلوب جاف أو تحميل العميل الخطأ أو تهرّب من المسؤولية','agent_conduct','external',TRUE,'medium',2,0,NULL,TRUE,80),
('policy_risk','وعد/رفض غير مؤكد','وعد غير مؤكد أو رفض إلغاء/استرجاع بأسلوب حاد','risk','external',TRUE,'high',0,0,NULL,TRUE,90),
('sales_risk','أسلوب السعر والعروض','تعامل غير مهني حول الأسعار أو العروض','risk','external',TRUE,'medium',0,0,NULL,TRUE,100),
('delay_handling_risk','تعامل مع تأخر الشحن','تعامل غير مهني مع شكوى تأخر الشحن','risk','external',TRUE,'medium',0,0,NULL,TRUE,110),
('unprofessional_note','وصف مسيء بالنوت','وصف غير مهني للعميل داخل الملاحظة الداخلية','internal_notes','note',TRUE,'high',0,0,NULL,TRUE,120),
('internal_argument','جدال بين الموظفين','جدال أو لوم بين الموظفين داخل الملاحظات','internal_notes','note',TRUE,'medium',0,0,NULL,TRUE,130),
('customer_abuse','إساءة أو تهديد من العميل','العميل استخدم ألفاظاً مسيئة أو وجّه تهديداً','customer_conduct','customer',TRUE,'high',1,0,NULL,TRUE,140)
ON CONFLICT (alert_type) DO NOTHING;

-- one-time cleanup: stuck test rule (inactive) left in qg_rules
DELETE FROM qg_rules WHERE alert_type = 'تجريبي';

COMMIT;
