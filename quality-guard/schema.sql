-- QAYDAO Agent Quality Guard — isolated schema (DB: quality_guard, NOT chatwoot_production)

CREATE TABLE IF NOT EXISTS qg_alerts (
    id                  BIGSERIAL PRIMARY KEY,
    account_id          INTEGER      NOT NULL,
    conversation_id     INTEGER      NOT NULL,
    message_id          BIGINT,
    inbox_id            INTEGER,
    user_id             INTEGER,                 -- chatwoot sender (agent) id
    employee_name       TEXT,
    employee_email      TEXT,
    channel_type        TEXT,
    alert_type          TEXT         NOT NULL,   -- abuse | unprofessional_note | internal_argument | reply_without_assignment | response_delay
    severity            TEXT         NOT NULL,   -- low | medium | high
    message_type        TEXT,                    -- outgoing | template | ...
    message_direction   TEXT,                    -- to_customer | internal_note
    is_private          BOOLEAN      DEFAULT FALSE,
    message_snippet     TEXT,                    -- PII-masked, truncated
    ai_reason           TEXT,                    -- phase 1: rule reason; phase 4: AI reason
    suggested_correction TEXT,
    policy_reference    TEXT,
    matched_rule        TEXT,                    -- which rule key fired (audit)
    is_repeated         BOOLEAN      DEFAULT FALSE,
    repeated_count      INTEGER      DEFAULT 1,
    supervisor_status   TEXT         DEFAULT 'pending',  -- pending|approved_violation|training_only|rejected|escalated|needs_followup
    supervisor_id       INTEGER,
    supervisor_note     TEXT,
    created_at          TIMESTAMPTZ  DEFAULT now(),
    updated_at          TIMESTAMPTZ  DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_qg_alerts_created   ON qg_alerts (created_at);
CREATE INDEX IF NOT EXISTS idx_qg_alerts_employee  ON qg_alerts (employee_email);
CREATE INDEX IF NOT EXISTS idx_qg_alerts_conv      ON qg_alerts (conversation_id);
CREATE INDEX IF NOT EXISTS idx_qg_alerts_type      ON qg_alerts (alert_type);
CREATE INDEX IF NOT EXISTS idx_qg_alerts_severity  ON qg_alerts (severity);

-- Raw webhook audit log (debug / replay). Snippets masked before insert.
CREATE TABLE IF NOT EXISTS qg_events (
    id              BIGSERIAL PRIMARY KEY,
    event_name      TEXT,
    conversation_id INTEGER,
    message_id      BIGINT,
    received_at     TIMESTAMPTZ DEFAULT now(),
    classified_as   TEXT                         -- safe | low | medium | high
);

-- Batch A+B additions (greeting tracking + SLA)
CREATE TABLE IF NOT EXISTS qg_seen_conversations (
    conversation_id   INTEGER PRIMARY KEY,
    first_message_id  BIGINT,
    first_seen_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS qg_pending_response (
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
CREATE INDEX IF NOT EXISTS idx_qg_pending_due ON qg_pending_response (due_at) WHERE NOT alerted;

-- Section 1: official policy source-of-truth (manual entry / future Salla sync)
CREATE TABLE IF NOT EXISTS qg_policies (
    id                BIGSERIAL PRIMARY KEY,
    policy_category   TEXT NOT NULL,
    official_statement TEXT NOT NULL,
    numbers_or_limits TEXT,
    conditions        TEXT,
    exceptions        TEXT,
    source_url        TEXT,
    page_title        TEXT,
    content_hash      TEXT,
    is_active         BOOLEAN DEFAULT TRUE,
    last_verified_at  TIMESTAMPTZ DEFAULT now(),
    last_fetched_at   TIMESTAMPTZ,
    stale             BOOLEAN DEFAULT FALSE,
    created_at        TIMESTAMPTZ DEFAULT now(),
    updated_at        TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_qg_policies_cat ON qg_policies (policy_category) WHERE is_active;

-- Section 1 alert fields
ALTER TABLE qg_alerts ADD COLUMN IF NOT EXISTS official_policy_snippet TEXT;
ALTER TABLE qg_alerts ADD COLUMN IF NOT EXISTS source_url TEXT;

-- Admin Settings: editable rules, settings, audit log (Quality Guard Admin)
CREATE TABLE IF NOT EXISTS qg_rules (
    id BIGSERIAL PRIMARY KEY, rule_group TEXT NOT NULL, phrase TEXT NOT NULL,
    alert_type TEXT NOT NULL, severity TEXT NOT NULL, scope TEXT NOT NULL,
    ai_reason TEXT, suggested_correction TEXT, policy_reference TEXT,
    is_active BOOLEAN DEFAULT TRUE, created_at TIMESTAMPTZ DEFAULT now(), updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_qg_rules_active ON qg_rules (scope) WHERE is_active;

CREATE TABLE IF NOT EXISTS qg_settings (
    key TEXT PRIMARY KEY, value TEXT, updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS qg_audit_log (
    id BIGSERIAL PRIMARY KEY, actor TEXT, action TEXT NOT NULL, entity TEXT, entity_id TEXT,
    old_value TEXT, new_value TEXT, created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_qg_audit_created ON qg_audit_log (created_at);

-- WhatsApp outreach: track customer engagement so greeting is evaluated only after the customer replies
ALTER TABLE qg_seen_conversations ADD COLUMN IF NOT EXISTS customer_engaged BOOLEAN DEFAULT FALSE;

-- GeoIP cache: city/country resolved from client IP (via ip-api.com), to avoid repeat lookups
CREATE TABLE IF NOT EXISTS qg_geoip_cache (
    ip          TEXT PRIMARY KEY,
    city        TEXT,
    country     TEXT,
    resolved    BOOLEAN DEFAULT FALSE,
    fetched_at  TIMESTAMPTZ DEFAULT now()
);

-- WhatsApp: greeting & closing/rating fire at most ONCE per conversation
-- (24h window may reopen/resolve repeatedly; never re-request intro/closing)
ALTER TABLE qg_seen_conversations ADD COLUMN IF NOT EXISTS greeting_checked BOOLEAN DEFAULT FALSE;
ALTER TABLE qg_seen_conversations ADD COLUMN IF NOT EXISTS closing_checked BOOLEAN DEFAULT FALSE;
