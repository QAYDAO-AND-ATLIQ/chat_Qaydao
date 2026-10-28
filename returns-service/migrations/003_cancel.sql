-- 003_cancel.sql — CS-team cancellation (customer no longer wants the return).
-- Allowed only before the accountant starts (new / done_salla). Final state.
ALTER TABLE return_requests
  ADD COLUMN IF NOT EXISTS cancel_reason TEXT,
  ADD COLUMN IF NOT EXISTS cancelled_by  TEXT,
  ADD COLUMN IF NOT EXISTS cancelled_at  TIMESTAMPTZ;

ALTER TABLE return_requests DROP CONSTRAINT IF EXISTS return_requests_status_check;
ALTER TABLE return_requests ADD CONSTRAINT return_requests_status_check
  CHECK (status IN ('new','will','doing','done','rejected','done_salla','cancelled'));
