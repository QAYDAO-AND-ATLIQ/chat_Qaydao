// Propagate unified products to master_products (PostgreSQL)
// This is the SOURCE OF TRUTH — full overwrite of Salla-sourced fields.
const crypto = require("crypto");
const db = require("../../db-pg");

async function propagate(products) {
  const stats = { added: 0, updated: 0, unchanged: 0, errors: 0, error_samples: [] };

  for (const p of products) {
    try {
      const hash = crypto.createHash("sha256").update(
        [p.salla_id, p.name, p.price_regular, p.price_discounted, p.status, p.image_url].join("|")
      ).digest("hex");

      const { rows, rowCount } = await db.query(`
        INSERT INTO master_products (
          salla_id, sku, name, name_en, description, category_path, category_main,
          product_type, promo_label, price_regular, price_discounted,
          quantity_available, status, weight,
          image_url, gallery_urls, variants_json, product_url,
          source, data_hash, source_updated_at, last_synced_at, is_active, deleted_at
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,'unified',$19,NOW(),NOW(),TRUE,NULL)
        ON CONFLICT (salla_id) DO UPDATE SET
          sku = EXCLUDED.sku,
          name = EXCLUDED.name,
          name_en = EXCLUDED.name_en,
          description = EXCLUDED.description,
          category_path = EXCLUDED.category_path,
          category_main = EXCLUDED.category_main,
          product_type = EXCLUDED.product_type,
          promo_label = EXCLUDED.promo_label,
          price_regular = EXCLUDED.price_regular,
          price_discounted = EXCLUDED.price_discounted,
          quantity_available = EXCLUDED.quantity_available,
          status = EXCLUDED.status,
          weight = EXCLUDED.weight,
          image_url = EXCLUDED.image_url,
          gallery_urls = EXCLUDED.gallery_urls,
          variants_json = EXCLUDED.variants_json,
          product_url = EXCLUDED.product_url,
          data_hash = EXCLUDED.data_hash,
          source_updated_at = NOW(),
          last_synced_at = NOW(),
          is_active = TRUE,
          deleted_at = NULL
        WHERE master_products.data_hash IS DISTINCT FROM EXCLUDED.data_hash
        RETURNING (xmax = 0) AS inserted
      `, [
        p.salla_id, p.sku, p.name, p.name_en, p.description,
        p.category_path, p.category_main, p.product_type, p.promo_label,
        p.price_regular, p.price_discounted, p.quantity_available, p.status, p.weight,
        p.image_url, JSON.stringify(p.gallery_urls || []), JSON.stringify(p.variants || []),
        p.product_url, hash,
      ]);

      if (rowCount === 0) {
        stats.unchanged++;
      } else if (rows[0].inserted) {
        stats.added++;
      } else {
        stats.updated++;
      }
    } catch (err) {
      stats.errors++;
      if (stats.error_samples.length < 5) {
        stats.error_samples.push({ salla_id: p.salla_id, error: err.message });
      }
    }
  }

  return stats;
}

module.exports = { propagate };
