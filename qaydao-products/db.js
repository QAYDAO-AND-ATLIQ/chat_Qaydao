const Database = require('better-sqlite3');
const path = require('path');
const dbPath = path.join(__dirname, 'data', 'products.db');
const db = new Database(dbPath);
db.pragma('journal_mode = WAL');
db.exec(`
  CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sku TEXT, salla_no TEXT UNIQUE, name TEXT NOT NULL, category TEXT,
    description TEXT, price REAL, discounted_price REAL, quantity INTEGER DEFAULT 0,
    status TEXT, product_type TEXT, promo_label TEXT, image_url TEXT,
    weight REAL, variants TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT DEFAULT CURRENT_TIMESTAMP
  );
  CREATE INDEX IF NOT EXISTS idx_p_category ON products(category);
  CREATE INDEX IF NOT EXISTS idx_p_sku ON products(sku);
  CREATE VIRTUAL TABLE IF NOT EXISTS products_fts USING fts5(
    name, category, description, sku, promo_label,
    content='products', content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
  );
  CREATE TRIGGER IF NOT EXISTS products_ai AFTER INSERT ON products BEGIN
    INSERT INTO products_fts(rowid, name, category, description, sku, promo_label)
    VALUES (new.id, new.name, new.category, new.description, new.sku, new.promo_label);
  END;
  CREATE TRIGGER IF NOT EXISTS products_ad AFTER DELETE ON products BEGIN
    DELETE FROM products_fts WHERE rowid = old.id;
  END;
  CREATE TRIGGER IF NOT EXISTS products_au AFTER UPDATE ON products BEGIN
    DELETE FROM products_fts WHERE rowid = old.id;
    INSERT INTO products_fts(rowid, name, category, description, sku, promo_label)
    VALUES (new.id, new.name, new.category, new.description, new.sku, new.promo_label);
  END;
  CREATE TABLE IF NOT EXISTS uploads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL, file_size INTEGER,
    products_added INTEGER DEFAULT 0, products_updated INTEGER DEFAULT 0,
    products_deleted INTEGER DEFAULT 0, total_after INTEGER DEFAULT 0,
    duration_ms INTEGER, status TEXT DEFAULT 'pending',
    error_message TEXT, uploaded_by TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
  );
  CREATE INDEX IF NOT EXISTS idx_uploads_created ON uploads(created_at DESC);
`);
module.exports = db;
