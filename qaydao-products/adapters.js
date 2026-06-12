// QAYDAO System Adapters
// Each adapter knows how to read & sync products in its specific system
const Database = require('better-sqlite3');
const path = require('path');

// ────────────────────────────────────────────────────────────
// STUDIO ADAPTER - studio.qaydao.com (Laravel + SQLite)
// ────────────────────────────────────────────────────────────
class StudioAdapter {
  constructor() {
    this.name = 'studio';
    this.dbPath = '/opt/qaydao-studio/app/database/database.sqlite';
    this.url = 'https://studio.qaydao.com';
  }

  getDb(readonly = true) {
    return new Database(this.dbPath, { readonly });
  }

  async getStats() {
    try {
      const db = this.getDb();
      const total = db.prepare('SELECT COUNT(*) AS n FROM products').get().n;
      const active = db.prepare('SELECT COUNT(*) AS n FROM products WHERE is_active = 1').get().n;
      const withSalla = db.prepare("SELECT COUNT(*) AS n FROM products WHERE salla_product_id IS NOT NULL AND salla_product_id != ''").get().n;
      db.close();
      return { total, active, with_salla_id: withSalla };
    } catch (err) {
      return { error: err.message, total: 0 };
    }
  }

  async getSallaIds() {
    try {
      const db = this.getDb();
      const rows = db.prepare("SELECT salla_product_id FROM products WHERE salla_product_id IS NOT NULL AND salla_product_id != ''").all();
      db.close();
      return new Set(rows.map(r => String(r.salla_product_id)));
    } catch (err) {
      console.error('[Studio] getSallaIds error:', err.message);
      return new Set();
    }
  }
}

// ────────────────────────────────────────────────────────────
// SALES ADAPTER - sales.qaydao.com (Laravel + SQLite)
// ────────────────────────────────────────────────────────────
class SalesAdapter {
  constructor() {
    this.name = 'sales';
    this.dbPath = '/var/www/sales/database/database.sqlite';
    this.url = 'https://sales.qaydao.com';
  }

  getDb(readonly = true) {
    return new Database(this.dbPath, { readonly });
  }

  async getStats() {
    try {
      const db = this.getDb();
      const total = db.prepare('SELECT COUNT(*) AS n FROM products').get().n;
      const active = db.prepare('SELECT COUNT(*) AS n FROM products WHERE is_active = 1').get().n;
      const withSku = db.prepare("SELECT COUNT(*) AS n FROM products WHERE sku IS NOT NULL AND sku != ''").get().n;
      db.close();
      return { total, active, with_sku: withSku };
    } catch (err) {
      return { error: err.message, total: 0 };
    }
  }

  async getSkus() {
    try {
      const db = this.getDb();
      const rows = db.prepare("SELECT sku FROM products WHERE sku IS NOT NULL").all();
      db.close();
      return new Set(rows.map(r => String(r.sku).trim().toUpperCase()));
    } catch (err) {
      console.error('[Sales] getSkus error:', err.message);
      return new Set();
    }
  }
}

// ────────────────────────────────────────────────────────────
// CAPTAIN ADAPTER - Chatwoot (PostgreSQL)
// Captain just reads from master_products directly via the search API.
// No separate sync needed.
// ────────────────────────────────────────────────────────────
class CaptainAdapter {
  constructor() {
    this.name = 'captain';
    this.url = 'https://chat.qaydao.com';
  }

  async getStats(pgPool) {
    try {
      const { rows } = await pgPool.query(`
        SELECT COUNT(*) AS n FROM master_products
        WHERE deleted_at IS NULL AND is_active = TRUE
      `);
      return { total: parseInt(rows[0].n), source: 'master_products (live)' };
    } catch (err) {
      return { error: err.message, total: 0 };
    }
  }
}

module.exports = {
  studio: new StudioAdapter(),
  sales: new SalesAdapter(),
  captain: new CaptainAdapter()
};
