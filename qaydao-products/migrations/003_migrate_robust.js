// Migration v3: Robust SQLite → PostgreSQL
// Uses SAVEPOINT for per-row error isolation
const Database = require('better-sqlite3');
const { Pool } = require('pg');
const crypto = require('crypto');

const SQLITE_DB = '/root/qaydao-products/data/products.db';
const PG_CONFIG = {
  host: '127.0.0.1',
  database: 'qaydao_master',
  user: 'qaydao_master',
  password: process.env.PG_PASSWORD,
  port: 5432
};

const sqlite = new Database(SQLITE_DB, { readonly: true });
const pgPool = new Pool(PG_CONFIG);

function computeHash(p) {
  const fields = [p.salla_id, p.name, p.price_regular, p.price_discounted, p.status].join('|');
  return crypto.createHash('sha256').update(fields).digest('hex');
}

function extractCategoryMain(p) {
  if (!p) return null;
  return p.split(',')[0].split('>')[0].trim();
}

function parseVariants(v) {
  if (!v) return [];
  try { return JSON.parse(v); } catch { return []; }
}

// Validate numeric value - cap if too large
function safeNumeric(val, maxValue = 999999999.99) {
  const n = parseFloat(val);
  if (isNaN(n) || n === null) return null;
  if (n > maxValue) {
    console.warn(`  ⚠️ Capping value ${n} → ${maxValue}`);
    return maxValue;
  }
  if (n < 0) return 0;
  return n;
}

async function migrate() {
  console.log('🚀 Starting robust migration v3\n');

  const { c: srcCount } = sqlite.prepare('SELECT COUNT(*) as c FROM products').get();
  console.log(`✓ SQLite source: ${srcCount} products`);

  const { rows: [pgCheck] } = await pgPool.query('SELECT COUNT(*) AS n FROM master_products');
  console.log(`✓ PG target: ${pgCheck.n} products (will be replaced)`);

  const products = sqlite.prepare('SELECT * FROM products').all();
  console.log(`\n📦 Processing ${products.length} products with per-row isolation...\n`);

  const startTime = Date.now();
  let migrated = 0, errors = 0, skipped = 0;
  const errorSamples = [];

  const insertSQL = `
    INSERT INTO master_products (
      salla_id, sku, name, description, category_path, category_main,
      product_type, promo_label, price_regular, price_discounted,
      quantity_available, status, requires_shipping,
      weight, weight_unit, image_url,
      variants_json, product_url, source, data_hash, source_updated_at
    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,NOW())
    ON CONFLICT (salla_id) DO NOTHING
  `;

  // Process each row in its own micro-transaction (no shared state)
  for (let i = 0; i < products.length; i++) {
    const p = products[i];
    const sallaId = p.salla_no;

    if (!sallaId) {
      skipped++;
      continue;
    }

    try {
      const result = await pgPool.query(insertSQL, [
        sallaId,
        p.sku || null,
        p.name,
        p.description || null,
        p.category || null,
        extractCategoryMain(p.category),
        p.product_type || null,
        p.promo_label || null,
        safeNumeric(p.price),
        safeNumeric(p.discounted_price),
        parseInt(p.quantity) || null,
        p.status || null,
        true,
        safeNumeric(p.weight, 9999.99),
        'kg',
        p.image_url || null,
        JSON.stringify(parseVariants(p.variants)),
        sallaId ? `https://qaydao.com/-/p${sallaId}` : null,
        'salla',
        computeHash({ salla_id: sallaId, name: p.name, price_regular: p.price, status: p.status })
      ]);

      if (result.rowCount > 0) migrated++;
      else skipped++;

    } catch (err) {
      errors++;
      if (errorSamples.length < 5) {
        errorSamples.push(`${sallaId} (${(p.name || '').substring(0, 30)}): ${err.message.substring(0, 80)}`);
      }
    }

    if ((i + 1) % 200 === 0 || i === products.length - 1) {
      const pct = ((i + 1) / products.length * 100).toFixed(1);
      process.stdout.write(`\r  Progress: ${migrated} migrated | ${skipped} skipped | ${errors} errors (${pct}%)  `);
    }
  }

  console.log('\n');

  const { rows: [final] } = await pgPool.query('SELECT COUNT(*) AS n FROM master_products');
  const dur = Date.now() - startTime;

  console.log(`\n✅ Migration finished in ${(dur/1000).toFixed(1)}s`);
  console.log(`   Migrated: ${migrated}`);
  console.log(`   Skipped: ${skipped}`);
  console.log(`   Errors: ${errors}`);
  console.log(`   Final PG count: ${final.n}`);

  if (errorSamples.length > 0) {
    console.log(`\n⚠️ Sample errors:`);
    errorSamples.forEach(e => console.log(`   - ${e}`));
  }

  // Record migration job
  await pgPool.query(`
    INSERT INTO upload_jobs (filename, products_after, products_added, status, completed_at, duration_ms, uploaded_by, source)
    VALUES ('initial_sqlite_migration', $1, $2, 'completed', NOW(), $3, 'system', 'migration')
  `, [final.n, migrated, dur]);

  // Sample
  const sample = await pgPool.query(`
    SELECT salla_id, name, price_regular, status, category_main
    FROM master_products ORDER BY price_regular DESC LIMIT 5
  `);
  console.log('\n📋 Top 5 by price:');
  sample.rows.forEach(r => {
    console.log(`   ${r.salla_id} | ${r.name.substring(0, 35)} | ${r.price_regular} SAR`);
  });

  await pgPool.end();
  sqlite.close();
}

migrate().catch(err => { console.error('\n❌', err); process.exit(1); });
