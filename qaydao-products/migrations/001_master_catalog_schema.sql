-- ════════════════════════════════════════════════════════════
--  QAYDAO Master Catalog Schema
--  Single Source of Truth for Products across all systems
--  Date: 2026-05-20
-- ════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "unaccent";

-- 1. MASTER PRODUCTS
CREATE TABLE IF NOT EXISTS master_products (
  id              BIGSERIAL PRIMARY KEY,
  salla_id        VARCHAR(50)  UNIQUE,
  sku             VARCHAR(100) UNIQUE,
  barcode         VARCHAR(50),
  mpn             VARCHAR(100),
  gtin            VARCHAR(50),
  name            TEXT NOT NULL,
  name_en         TEXT,
  description     TEXT,
  short_desc      TEXT,
  category_path   TEXT,
  category_main   TEXT,
  product_type    VARCHAR(50),
  promo_label     TEXT,
  price_regular   NUMERIC(10,2) NOT NULL DEFAULT 0,
  price_discounted NUMERIC(10,2),
  currency        VARCHAR(3) DEFAULT 'SAR',
  quantity_available INTEGER,
  status          VARCHAR(20),
  requires_shipping BOOLEAN DEFAULT TRUE,
  weight          NUMERIC(8,2),
  weight_unit     VARCHAR(10) DEFAULT 'kg',
  image_url       TEXT,
  gallery_urls    JSONB DEFAULT '[]'::jsonb,
  image_alt       TEXT,
  variants_json   JSONB DEFAULT '[]'::jsonb,
  taxable         BOOLEAN DEFAULT TRUE,
  product_url     TEXT,
  source          VARCHAR(20) DEFAULT 'salla',
  source_version  INTEGER DEFAULT 1,
  data_hash       VARCHAR(64),
  raw_payload     JSONB,
  is_active       BOOLEAN DEFAULT TRUE,
  deleted_at      TIMESTAMPTZ,
  source_updated_at TIMESTAMPTZ,
  last_synced_at  TIMESTAMPTZ DEFAULT NOW(),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mp_salla_id ON master_products(salla_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_sku ON master_products(sku) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_status ON master_products(status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_category ON master_products(category_main) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_price ON master_products(price_regular) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_active ON master_products(is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_updated ON master_products(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_mp_name_trgm ON master_products USING gin(name gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mp_desc_trgm ON master_products USING gin(description gin_trgm_ops) WHERE deleted_at IS NULL;

-- 2. PRODUCT CHANGE EVENTS
CREATE TABLE IF NOT EXISTS product_change_events (
  id              BIGSERIAL PRIMARY KEY,
  product_id      BIGINT REFERENCES master_products(id) ON DELETE CASCADE,
  salla_id        VARCHAR(50),
  event_type      VARCHAR(30) NOT NULL,
  field_name      VARCHAR(50),
  old_value       TEXT,
  new_value       TEXT,
  source          VARCHAR(20),
  triggered_by    VARCHAR(100),
  metadata        JSONB DEFAULT '{}'::jsonb,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pce_product ON product_change_events(product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pce_type ON product_change_events(event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pce_created ON product_change_events(created_at DESC);

-- 3. UPLOAD JOBS
CREATE TABLE IF NOT EXISTS upload_jobs (
  id              BIGSERIAL PRIMARY KEY,
  filename        VARCHAR(255) NOT NULL,
  file_size       BIGINT,
  file_sha256     VARCHAR(64),
  products_before INTEGER,
  products_after  INTEGER,
  products_added  INTEGER DEFAULT 0,
  products_updated INTEGER DEFAULT 0,
  products_removed INTEGER DEFAULT 0,
  products_unchanged INTEGER DEFAULT 0,
  status          VARCHAR(20) DEFAULT 'processing',
  error_message   TEXT,
  warnings        JSONB DEFAULT '[]'::jsonb,
  uploaded_by     VARCHAR(100),
  source          VARCHAR(30) DEFAULT 'manual_csv',
  started_at      TIMESTAMPTZ DEFAULT NOW(),
  completed_at    TIMESTAMPTZ,
  duration_ms     INTEGER,
  studio_synced   BOOLEAN DEFAULT FALSE,
  studio_synced_at TIMESTAMPTZ,
  sales_synced    BOOLEAN DEFAULT FALSE,
  sales_synced_at TIMESTAMPTZ,
  captain_synced  BOOLEAN DEFAULT FALSE,
  captain_synced_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_uj_started ON upload_jobs(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_uj_status ON upload_jobs(status);

-- 4. AI EVENTS
CREATE TABLE IF NOT EXISTS ai_events (
  id              BIGSERIAL PRIMARY KEY,
  event_type      VARCHAR(50) NOT NULL,
  event_source    VARCHAR(30) NOT NULL,
  product_id      BIGINT REFERENCES master_products(id) ON DELETE SET NULL,
  product_sku     VARCHAR(100),
  product_salla_id VARCHAR(50),
  user_hash       VARCHAR(64),
  session_hash    VARCHAR(64),
  query_text      TEXT,
  intent_detected VARCHAR(100),
  sentiment       VARCHAR(20),
  language        VARCHAR(5) DEFAULT 'ar',
  outcome         VARCHAR(50),
  conversion_value NUMERIC(10,2),
  payload         JSONB DEFAULT '{}'::jsonb,
  response_time_ms INTEGER,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ae_type ON ai_events(event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ae_source ON ai_events(event_source, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ae_product ON ai_events(product_id, created_at DESC) WHERE product_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ae_session ON ai_events(session_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ae_created ON ai_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ae_outcome ON ai_events(outcome) WHERE outcome IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ae_query_trgm ON ai_events USING gin(query_text gin_trgm_ops) WHERE query_text IS NOT NULL;

-- 5. SYSTEM SYNC STATUS
CREATE TABLE IF NOT EXISTS system_sync_status (
  id              BIGSERIAL PRIMARY KEY,
  master_product_id BIGINT REFERENCES master_products(id) ON DELETE CASCADE,
  system          VARCHAR(20) NOT NULL,
  external_id     VARCHAR(100),
  status          VARCHAR(20) DEFAULT 'pending',
  last_synced_at  TIMESTAMPTZ,
  last_error      TEXT,
  retry_count     INTEGER DEFAULT 0,
  source_hash_at_sync VARCHAR(64),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(master_product_id, system)
);
CREATE INDEX IF NOT EXISTS idx_sss_system ON system_sync_status(system, status);
CREATE INDEX IF NOT EXISTS idx_sss_product ON system_sync_status(master_product_id);

-- TRIGGERS
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE 'plpgsql';

DROP TRIGGER IF EXISTS trg_mp_updated ON master_products;
CREATE TRIGGER trg_mp_updated BEFORE UPDATE ON master_products
  FOR EACH ROW EXECUTE FUNCTION update_modified_column();

DROP TRIGGER IF EXISTS trg_sss_updated ON system_sync_status;
CREATE TRIGGER trg_sss_updated BEFORE UPDATE ON system_sync_status
  FOR EACH ROW EXECUTE FUNCTION update_modified_column();

-- VIEWS
CREATE OR REPLACE VIEW v_captain_products AS
SELECT id, salla_id, sku, name, description, short_desc,
  category_path, category_main, promo_label, product_type,
  price_regular, price_discounted, currency,
  quantity_available, status, requires_shipping,
  image_url, product_url, variants_json, updated_at
FROM master_products
WHERE deleted_at IS NULL AND is_active = TRUE;

SELECT 'Schema created' AS result;
