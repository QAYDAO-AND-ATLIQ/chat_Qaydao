// Migration: SQLite (legacy) → PostgreSQL (master)
const Database = require('better-sqlite3');
const { Pool } = require('pg');
const crypto = require('crypto');
const path = require('path');

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
  const fields = [
    p.salla_id, p.name, p.price_regular, p.price_discounted,
    p.quantity_available, p.status, p.description?.slice(0, 500)
  ].join('|');
  return crypto.createHash('sha256').update(fields).digest('hex');
}

function extractCategoryMain(path) {
  if (!path) return null;
  return path.split(',')[0].split('>')[0].trim();
}

function parseVariants(variantsStr) {
  if (!variantsStr) return [];
  try {
    return JSON.parse(variantsStr);
  } catch { return []; }
}

async function migrate() {
  console.log('🚀 Starting SQLite → PostgreSQL migration\n');

  // Verify Postgres connection
  const pgVer = await pgPool.query('SELECT version()');
  console.log('✓ PostgreSQL:', pgVer.rows[0].version.substring(0, 50));

  // Count SQLite products
  const { c: srcCount } = sqlite.prepare('SELECT COUNT(*) as c FROM products').get();
  console.log(`✓ Source SQLite: ${srcCount} products`);

  // Check if PostgreSQL is empty
  const { rows: [pgCheck] } = await pgPool.query('SELECT COUNT(*) AS n FROM master_products');
  console.log(`✓ Target PostgreSQL: ${pgCheck.n} products`);

  if (parseInt(pgCheck.n) > 0) {
    console.log('⚠️  PostgreSQL already has products. Skipping migration.');
    process.exit(0);
  }

  // Fetch all SQLite products
  const products = sqlite.prepare('SELECT * FROM products').all();
  console.log(`\n📦 Migrating ${products.length} products...\n`);

  let migrated = 0;
  let errors = 0;
  const startTime = Date.now();

  // Begin transaction
  const client = await pgPool.connect();
  try {
    await client.query('BEGIN');

    const insertSQL = `
      INSERT INTO master_products (
        salla_id, sku, name, description, category_path, category_main,
        product_type, promo_label, price_regular, price_discounted,
        quantity_available, status, requires_shipping,
        weight, weight_unit, image_url, image_alt,
        barcode, mpn, gtin, taxable, variants_json,
        product_url, source, data_hash, source_updated_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
        $11, $12, $13, $14, $15, $16, $17,
        $18, $19, $20, $21, $22, $23, $24, $25, NOW()
      )
      ON CONFLICT (salla_id) DO NOTHING
    `;

    // Batch process for memory efficiency
    const BATCH_SIZE = 100;
    for (let i = 0; i < products.length; i += BATCH_SIZE) {
      const batch = products.slice(i, i + BATCH_SIZE);

      for (const p of batch) {
        try {
          const sallaId = p.salla_no || null;
          if (!sallaId) {
            errors++;
            continue;
          }

          const hash = computeHash({
            salla_id: sallaId,
            name: p.name,
            price_regular: p.price,
            price_discounted: p.discounted_price,
            quantity_available: p.quantity,
            status: p.status,
            description: p.description
          });

          await client.query(insertSQL, [
            sallaId,                                          // salla_id
            p.sku || null,                                    // sku
            p.name,                                            // name
            p.description || null,                             // description
            p.category || null,                                // category_path
            extractCategoryMain(p.category),                   // category_main
            p.product_type || null,                            // product_type
            p.promo_label || null,                             // promo_label
            parseFloat(p.price) || 0,                          // price_regular
            parseFloat(p.discounted_price) || null,            // price_discounted
            parseInt(p.quantity) || null,                      // quantity_available
            p.status || null,                                  // status
            true,                                              // requires_shipping
            parseFloat(p.weight) || null,                      // weight
            'kg',                                              // weight_unit
            p.image_url || null,                               // image_url
            null,                                              // image_alt
            null,                                              // barcode
            null,                                              // mpn
            null,                                              // gtin
            true,                                              // taxable
            JSON.stringify(parseVariants(p.variants)),         // variants_json
            sallaId ? `https://qaydao.com/-/p${sallaId}` : null, // product_url
            'salla',                                           // source
            hash                                               // data_hash
          ]);

          migrated++;
        } catch (err) {
          errors++;
          if (errors < 5) console.error(`  ❌ ${p.name?.substring(0, 40)}: ${err.message.substring(0, 80)}`);
        }
      }

      const pct = ((i + batch.length) / products.length * 100).toFixed(1);
      process.stdout.write(`\r  Progress: ${migrated}/${products.length} (${pct}%) - errors: ${errors}`);
    }

    await client.query('COMMIT');
    console.log('\n');

    // Verify
    const { rows: [final] } = await pgPool.query('SELECT COUNT(*) AS n FROM master_products');
    const dur = Date.now() - startTime;
    console.log(`\n✅ Migration complete in ${(dur/1000).toFixed(1)}s`);
    console.log(`   Migrated: ${migrated}`);
    console.log(`   Errors: ${errors}`);
    console.log(`   PostgreSQL count: ${final.n}`);

    // Sample data
    const sample = await pgPool.query(`
      SELECT salla_id, name, price_regular, status, category_main
      FROM master_products ORDER BY id LIMIT 5
    `);
    console.log('\n📋 Sample (first 5):');
    sample.rows.forEach(r => {
      console.log(`   ${r.salla_id} | ${r.name.substring(0, 40)} | ${r.price_regular} SAR | ${r.status || '-'}`);
    });

    // Record migration as upload job
    await pgPool.query(`
      INSERT INTO upload_jobs (filename, products_after, products_added, status, completed_at, duration_ms, uploaded_by, source)
      VALUES ('sqlite_migration', $1, $2, 'completed', NOW(), $3, 'system', 'migration')
    `, [migrated, migrated, dur]);

  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }

  await pgPool.end();
  sqlite.close();
}

migrate().catch(err => {
  console.error('\n❌ Migration failed:', err);
  process.exit(1);
});
