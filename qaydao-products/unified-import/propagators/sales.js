// Propagate unified products to sales.qaydao.com SQLite
// CRITICAL: Never overwrite cost_price, shipping_cost, customs_cost, cbm,
//   width, height, depth — those are entered by the sales employee.
const Database = require("better-sqlite3");

const DB_PATH = "/var/www/sales/database/database.sqlite";

// Fields we own and update freely (from Salla feed):
const OWNED_FIELDS = ["name_ar", "default_price", "image", "description_ar"];

// Fields we NEVER touch on update — only set on insert with defaults:
const PROTECTED_FIELDS = [
  "cost_price", "shipping_cost", "customs_cost", "cbm",
  "width", "height", "depth", "lead_time_days", "factory_name",
  "has_technical_specs", "technical_specs", "internal_notes",
  "translation_status", "is_translation_verified",
];

async function propagate(products) {
  const stats = { added: 0, updated: 0, unchanged: 0, errors: 0, skipped_no_sku: 0, protected_fields_kept: 0, error_samples: [] };

  let sdb;
  try {
    sdb = new Database(DB_PATH, { readonly: false, fileMustExist: true });
    sdb.pragma("journal_mode = WAL");
  } catch (err) {
    return { error: `cannot open sales DB: ${err.message}`, ...stats };
  }

  const selectStmt = sdb.prepare("SELECT id, default_price, name_ar, image FROM products WHERE sku = ?");
  const insertStmt = sdb.prepare(`
    INSERT INTO products (
      sku, name_ar, name_en, default_price,
      cost_price, shipping_cost, customs_cost,
      description_ar, image, unit, is_active,
      created_at, updated_at
    ) VALUES (
      @sku, @name_ar, @name_en, @default_price,
      0, 0, 0,
      @description_ar, @image, 'PEC', 1,
      datetime('now'), datetime('now')
    )
  `);
  const updateStmt = sdb.prepare(`
    UPDATE products SET
      name_ar = @name_ar,
      default_price = @default_price,
      image = COALESCE(@image, image),
      description_ar = COALESCE(@description_ar, description_ar),
      updated_at = datetime('now')
    WHERE sku = @sku
  `);

  const tx = sdb.transaction((records) => {
    for (const p of records) {
      if (!p.sku) { stats.skipped_no_sku++; continue; }

      try {
        const existing = selectStmt.get(p.sku);
        const payload = {
          sku: p.sku,
          name_ar: p.name,
          name_en: p.name_en,
          default_price: p.price_regular || 0,
          description_ar: p.description,
          image: p.image_url,
        };

        if (existing) {
          // Skip update if nothing changed
          if (
            existing.name_ar === payload.name_ar &&
            Number(existing.default_price) === Number(payload.default_price) &&
            existing.image === payload.image
          ) {
            stats.unchanged++;
          } else {
            updateStmt.run(payload);
            stats.updated++;
            stats.protected_fields_kept++;  // cost/shipping/customs preserved
          }
        } else {
          insertStmt.run(payload);
          stats.added++;
        }
      } catch (err) {
        stats.errors++;
        if (stats.error_samples.length < 5) {
          stats.error_samples.push({ sku: p.sku, salla_id: p.salla_id, error: err.message });
        }
      }
    }
  });

  try {
    tx(products);
  } finally {
    sdb.close();
  }

  return stats;
}

module.exports = { propagate, OWNED_FIELDS, PROTECTED_FIELDS };
