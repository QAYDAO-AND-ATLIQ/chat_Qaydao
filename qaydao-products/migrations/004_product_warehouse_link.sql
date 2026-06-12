-- 004: product ↔ warehouse stock link (qaydao_master)
-- Maps a Salla product (salla_id) to one-or-more physical warehouse codes (qd_code/cn_code).
-- Used by search_products to set delivery_class from REAL stock, and by check_warehouse_stock tool.
CREATE TABLE IF NOT EXISTS product_warehouse_link (
  id                SERIAL PRIMARY KEY,
  salla_id          TEXT NOT NULL,
  sku               TEXT,
  warehouse_qd_code TEXT NOT NULL UNIQUE,
  source            TEXT NOT NULL DEFAULT 'manual',  -- 'auto' | 'manual'
  linked_by         TEXT,
  linked_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pwl_salla ON product_warehouse_link(salla_id);
