-- QAYDAO Returns Service — ISOLATED schema.
-- This DB (`returns`) is fully separate from chatwoot_production.
-- It only stores a conversation_id as a loose reference (no FK to Chatwoot).

CREATE TABLE IF NOT EXISTS return_requests (
    id                BIGSERIAL PRIMARY KEY,
    conversation_id   BIGINT,
    customer_name     TEXT,
    order_number      TEXT,
    order_amount      TEXT,
    return_created_at DATE,
    original_order_at DATE,
    reason            TEXT,
    bank_name         TEXT,
    bank_account      TEXT,
    iban              TEXT,
    attachment_name   TEXT,
    attachment_path   TEXT,
    attachment_mime   TEXT,
    assignee          TEXT,
    status            TEXT NOT NULL DEFAULT 'new'
                      CHECK (status IN ('new','will','doing','done')),
    status_history    JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_by        TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_return_conversation ON return_requests (conversation_id);
CREATE INDEX IF NOT EXISTS idx_return_status       ON return_requests (status);
CREATE INDEX IF NOT EXISTS idx_return_created      ON return_requests (created_at DESC);

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_touch_return ON return_requests;
CREATE TRIGGER trg_touch_return BEFORE UPDATE ON return_requests
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
