// Propagate unified products to studio.qaydao.com SQLite
// CRITICAL: Never overwrite AI/intelligence fields.
// Studio uses salla_product_id as the cross-system key.
const Database = require("better-sqlite3");
const crypto = require("crypto");

const DB_PATH = "/opt/qaydao-studio/app/database/database.sqlite";

// Fields owned by us (Salla feed):
const OWNED_FIELDS = [
  "title", "title_ar", "description", "description_ar",
  "price", "sale_price", "image_url", "availability", "category",
];

// Fields PROTECTED — never overwritten on update:
const PROTECTED_FIELDS = [
  // AI/intelligence
  "clean_image_url", "bg_status", "bg_processed_at", "default_scale", "shadow_strength", "anchor_type",
  "has_options", "requires_manual_selection", "options_confidence",
  "data_quality_status", "inferred_options_json", "quality_flags_json",
  "room_types_supported", "scene_types_supported", "style_tags_computed",
  "primary_color_normalized", "secondary_colors_normalized", "color_family",
  "material_primary", "material_secondary", "finish_type", "price_tier",
  "premium_level", "hero_eligible", "ai_generation_eligible", "visual_reference_quality",
  "mood_tags", "intelligence_computed_at", "diagnostics_reviewed_at",
  // Admin override
  "admin_review_required", "admin_review_status", "admin_override_payload",
  "reviewed_by", "reviewed_at", "review_notes",
  "manual_override_fields", "last_manual_override_at", "intelligence_source",
  // Stats
  "design_score", "times_used_in_designs", "times_rated_positive",
  "times_rated_negative", "times_added_to_cart", "successful_combinations",
];

function slugify(text) {
  if (!text) return "";
  return String(text)
    .toLowerCase()
    .replace(/[^\u0600-\u06FFa-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 200);
}

async function propagate(products) {
  const stats = { added: 0, updated: 0, unchanged: 0, errors: 0, protected_fields_kept: 0, error_samples: [] };

  let sdb;
  try {
    sdb = new Database(DB_PATH, { readonly: false, fileMustExist: true });
    sdb.pragma("journal_mode = WAL");
  } catch (err) {
    return { error: `cannot open studio DB: ${err.message}`, ...stats };
  }

  const selectStmt = sdb.prepare("SELECT id, title, price, image_url, sync_hash FROM products WHERE salla_product_id = ?");
  const insertStmt = sdb.prepare(`
    INSERT INTO products (
      id, salla_product_id, title, title_ar, slug,
      description, description_ar, price, sale_price,
      currency, image_url, category, availability, condition,
      source, is_active, sync_hash,
      created_at, updated_at, last_synced_at
    ) VALUES (
      @id, @salla_product_id, @title, @title_ar, @slug,
      @description, @description_ar, @price, @sale_price,
      'SAR', @image_url, @category, @availability, 'new',
      'unified', 1, @sync_hash,
      datetime('now'), datetime('now'), datetime('now')
    )
  `);
  const updateStmt = sdb.prepare(`
    UPDATE products SET
      title = @title,
      title_ar = @title_ar,
      description = COALESCE(@description, description),
      description_ar = COALESCE(@description_ar, description_ar),
      price = @price,
      sale_price = @sale_price,
      image_url = COALESCE(@image_url, image_url),
      category = COALESCE(@category, category),
      availability = @availability,
      sync_hash = @sync_hash,
      updated_at = datetime('now'),
      last_synced_at = datetime('now')
    WHERE salla_product_id = @salla_product_id
  `);

  const tx = sdb.transaction((records) => {
    for (const p of records) {
      if (!p.salla_id) { stats.errors++; continue; }

      try {
        const newHash = crypto.createHash("md5").update(
          [p.salla_id, p.name, p.price_regular, p.image_url, p.status].join("|")
        ).digest("hex");

        const existing = selectStmt.get(p.salla_id);
        const payload = {
          id: `unified_${p.salla_id}`,
          salla_product_id: p.salla_id,
          title: p.name,
          title_ar: p.name,
          slug: slugify(p.name) + "-" + p.salla_id,
          description: p.description,
          description_ar: p.description,
          price: p.price_regular || 0,
          sale_price: p.price_discounted || null,
          image_url: p.image_url,
          category: p.category_main,
          availability: p.status === "out of stock" || p.status === "غير متوفر" ? "out of stock" : "in stock",
          sync_hash: newHash,
        };

        if (existing) {
          if (existing.sync_hash === newHash) {
            stats.unchanged++;
          } else {
            updateStmt.run(payload);
            stats.updated++;
            stats.protected_fields_kept++;
          }
        } else {
          insertStmt.run(payload);
          stats.added++;
        }
      } catch (err) {
        stats.errors++;
        if (stats.error_samples.length < 5) {
          stats.error_samples.push({ salla_id: p.salla_id, error: err.message });
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
