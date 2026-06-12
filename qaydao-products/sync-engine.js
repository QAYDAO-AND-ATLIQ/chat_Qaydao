// QAYDAO Sync Engine
// Conservative sync: UPDATE-only for overlapping products
// Respects each system's domain (Studio AI fields, Sales cost fields stay untouched)

const Database = require('better-sqlite3');
const db = require('./db-pg');

// ────────────────────────────────────────────────────────────
// STUDIO SYNC
// Updates: name, description, price, image, availability, status
// Preserves: ALL AI/intelligence fields (color_family, material_primary, etc.)
// ────────────────────────────────────────────────────────────
class StudioSync {
  constructor() {
    this.name = 'studio';
    this.dbPath = '/opt/qaydao-studio/app/database/database.sqlite';
  }

  async run(options = {}) {
    const dryRun = options.dryRun || false;
    const startTime = Date.now();
    const stats = {
      system: 'studio',
      checked: 0, updated: 0, skipped: 0, deactivated: 0, errors: 0,
      changes: []
    };

    // Read Studio products (with salla_id)
    const sdb = new Database(this.dbPath, { readonly: false });

    try {
      // Get all Studio products with salla_product_id
      const studioRows = sdb.prepare(`
        SELECT id, salla_product_id, title, price, sale_price, image_url, availability, is_active
        FROM products
        WHERE salla_product_id IS NOT NULL AND salla_product_id != ''
      `).all();

      stats.checked = studioRows.length;

      // Get Master Catalog for matching products
      const sallaIds = studioRows.map(r => String(r.salla_product_id));
      const { rows: masterRows } = await db.query(`
        SELECT salla_id, name, description, price_regular, price_discounted,
               status, image_url, quantity_available, deleted_at
        FROM master_products
        WHERE salla_id = ANY($1)
      `, [sallaIds]);

      // Build Master lookup map
      const masterMap = new Map();
      masterRows.forEach(m => masterMap.set(String(m.salla_id), m));

      const updateStmt = sdb.prepare(`
        UPDATE products
        SET title = COALESCE(?, title),
            price = COALESCE(?, price),
            sale_price = ?,
            image_url = COALESCE(?, image_url),
            availability = COALESCE(?, availability),
            is_active = ?,
            last_synced_at = datetime('now'),
            updated_at = datetime('now')
        WHERE id = ?
      `);

      // Process each Studio product
      for (const sp of studioRows) {
        const master = masterMap.get(String(sp.salla_product_id));

        // If not in Master OR soft-deleted in Master → deactivate in Studio
        if (!master || master.deleted_at) {
          if (sp.is_active === 1) {
            if (!dryRun) {
              sdb.prepare(`UPDATE products SET is_active = 0, updated_at = datetime('now') WHERE id = ?`).run(sp.id);
            }
            stats.deactivated++;
            stats.changes.push({ id: sp.id, salla_id: sp.salla_product_id, action: 'deactivated', reason: 'not_in_master' });
          }
          continue;
        }

        // Check what needs updating
        const newTitle = master.name;
        const newPrice = parseFloat(master.price_regular || 0);
        const newSalePrice = master.price_discounted ? parseFloat(master.price_discounted) : null;
        const newImage = master.image_url;
        const newAvail = (master.quantity_available > 0 || master.status === 'متاح') ? 'in stock' : 'out of stock';
        const isActive = master.status !== 'مخفي' && master.status !== 'ملغي' ? 1 : 0;

        const changed =
          (sp.title !== newTitle) ||
          (Math.abs((sp.price || 0) - newPrice) > 0.01) ||
          (sp.sale_price != newSalePrice) ||
          (sp.image_url !== newImage && newImage) ||
          (sp.availability !== newAvail) ||
          (sp.is_active !== isActive);

        if (!changed) {
          stats.skipped++;
          continue;
        }

        if (!dryRun) {
          try {
            updateStmt.run(newTitle, newPrice, newSalePrice, newImage, newAvail, isActive, sp.id);
            stats.updated++;

            // Log change event in Master
            await db.query(`
              INSERT INTO product_change_events (salla_id, event_type, source, triggered_by, metadata)
              VALUES ($1, 'studio_sync', 'sync_engine', 'system', $2)
            `, [sp.salla_product_id, JSON.stringify({
              old: { title: sp.title, price: sp.price, sale: sp.sale_price, avail: sp.availability },
              new: { title: newTitle, price: newPrice, sale: newSalePrice, avail: newAvail }
            })]).catch(() => {});
          } catch (err) {
            stats.errors++;
            console.error(`[Studio sync error ${sp.salla_product_id}]`, err.message);
          }
        } else {
          stats.updated++;
        }
      }

      // Update sync status in Master
      if (!dryRun) {
        // Mark Studio sync as completed in upload_jobs (latest job)
        await db.query(`
          UPDATE upload_jobs
          SET studio_synced = TRUE, studio_synced_at = NOW()
          WHERE id = (SELECT MAX(id) FROM upload_jobs WHERE status = 'completed')
        `).catch(() => {});
      }

    } finally {
      sdb.close();
    }

    stats.duration_ms = Date.now() - startTime;
    stats.dry_run = dryRun;
    return stats;
  }
}

// ────────────────────────────────────────────────────────────
// SALES SYNC
// Updates: name_ar, default_price, image, is_active, description_ar
// Preserves: cost_price, shipping_cost, customs_cost, factory_name, technical_specs
// ────────────────────────────────────────────────────────────
class SalesSync {
  constructor() {
    this.name = 'sales';
    this.dbPath = '/var/www/sales/database/database.sqlite';
  }

  async run(options = {}) {
    const dryRun = options.dryRun || false;
    const startTime = Date.now();
    const stats = {
      system: 'sales',
      checked: 0, updated: 0, skipped: 0, deactivated: 0, errors: 0,
      changes: []
    };

    const sdb = new Database(this.dbPath, { readonly: false });

    try {
      // Get Sales products with SKU
      const salesRows = sdb.prepare(`
        SELECT id, sku, name_ar, default_price, image, is_active, description_ar
        FROM products
        WHERE sku IS NOT NULL AND deleted_at IS NULL
      `).all();

      stats.checked = salesRows.length;

      // Get matching Master products by SKU (case-insensitive)
      const skus = salesRows.map(r => String(r.sku).trim());
      const { rows: masterRows } = await db.query(`
        SELECT UPPER(sku) AS sku_upper, sku, name, description,
               price_regular, price_discounted, status, image_url, deleted_at
        FROM master_products
        WHERE deleted_at IS NULL AND UPPER(sku) = ANY($1)
      `, [skus.map(s => s.toUpperCase())]);

      const masterMap = new Map();
      masterRows.forEach(m => masterMap.set(m.sku_upper, m));

      const updateStmt = sdb.prepare(`
        UPDATE products
        SET name_ar = COALESCE(?, name_ar),
            default_price = COALESCE(?, default_price),
            image = COALESCE(?, image),
            is_active = ?,
            description_ar = COALESCE(?, description_ar),
            updated_at = datetime('now')
        WHERE id = ?
      `);

      for (const sp of salesRows) {
        const master = masterMap.get(String(sp.sku).trim().toUpperCase());

        if (!master) {
          // Sales-only product (supplier inventory) → don't touch
          stats.skipped++;
          continue;
        }

        // Use discounted price if available, else regular
        const newPrice = parseFloat(master.price_discounted || master.price_regular);
        const newName = master.name;
        const newImage = master.image_url;
        const isActive = master.status !== 'مخفي' && master.status !== 'ملغي' ? 1 : 0;
        const newDesc = master.description ? master.description.slice(0, 1000) : null;

        const changed =
          (sp.name_ar !== newName && newName) ||
          (Math.abs((sp.default_price || 0) - newPrice) > 0.01) ||
          (sp.image !== newImage && newImage) ||
          (sp.is_active !== isActive);

        if (!changed) {
          stats.skipped++;
          continue;
        }

        if (!dryRun) {
          try {
            updateStmt.run(newName, newPrice, newImage, isActive, newDesc, sp.id);
            stats.updated++;

            await db.query(`
              INSERT INTO product_change_events (salla_id, event_type, source, triggered_by, metadata)
              VALUES ($1, 'sales_sync', 'sync_engine', 'system', $2)
            `, [master.salla_id || sp.sku, JSON.stringify({
              old: { name: sp.name_ar, price: sp.default_price, active: sp.is_active },
              new: { name: newName, price: newPrice, active: isActive }
            })]).catch(() => {});
          } catch (err) {
            stats.errors++;
            console.error(`[Sales sync error ${sp.sku}]`, err.message);
          }
        } else {
          stats.updated++;
        }
      }

      if (!dryRun) {
        await db.query(`
          UPDATE upload_jobs
          SET sales_synced = TRUE, sales_synced_at = NOW()
          WHERE id = (SELECT MAX(id) FROM upload_jobs WHERE status = 'completed')
        `).catch(() => {});
      }

    } finally {
      sdb.close();
    }

    stats.duration_ms = Date.now() - startTime;
    stats.dry_run = dryRun;
    return stats;
  }
}

// ────────────────────────────────────────────────────────────
// SYNC ORCHESTRATOR
// ────────────────────────────────────────────────────────────
class SyncEngine {
  constructor() {
    this.studio = new StudioSync();
    this.sales = new SalesSync();
  }

  async syncAll(options = {}) {
    const startTime = Date.now();
    const results = {
      started_at: new Date().toISOString(),
      dry_run: options.dryRun || false,
      studio: null,
      sales: null
    };

    // Run in parallel (different DBs, safe)
    const [studioResult, salesResult] = await Promise.allSettled([
      this.studio.run(options),
      this.sales.run(options)
    ]);

    results.studio = studioResult.status === 'fulfilled' ? studioResult.value : { error: studioResult.reason?.message };
    results.sales = salesResult.status === 'fulfilled' ? salesResult.value : { error: salesResult.reason?.message };

    results.total_duration_ms = Date.now() - startTime;
    results.completed_at = new Date().toISOString();

    // Log to ai_events for analytics
    await db.query(`
      INSERT INTO ai_events (event_type, event_source, outcome, response_time_ms, payload)
      VALUES ('sync_run', 'sync_engine', $1, $2, $3)
    `, [
      (results.studio?.errors || 0) + (results.sales?.errors || 0) === 0 ? 'success' : 'partial',
      results.total_duration_ms,
      JSON.stringify(results)
    ]).catch(() => {});

    return results;
  }

  async syncStudio(options = {}) { return await this.studio.run(options); }
  async syncSales(options = {}) { return await this.sales.run(options); }
}

module.exports = new SyncEngine();
