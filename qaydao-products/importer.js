const fs = require('fs');
const path = require('path');
const { parse } = require('csv-parse');
const db = require('./db');

function stripHtml(html) {
  if (!html) return '';
  return html.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/\s+/g, ' ').trim().substring(0, 1000);
}
function extractVariants(row) {
  const v = [];
  for (let i = 1; i <= 10; i++) {
    const n = row[`[${i}] الاسم`], val = row[`[${i}] القيمة`];
    if (n && val) v.push(`${n.trim()}: ${val.trim()}`);
  }
  return v.length > 0 ? v.join(' | ') : null;
}
function parseRow(row) {
  const name = (row['أسم المنتج'] || '').trim();
  if (!name) return null;
  return {
    salla_no: (row['No.'] || '').toString().trim() || null,
    sku: (row['رمز المنتج sku'] || '').trim() || null,
    name, category: (row['تصنيف المنتج'] || '').trim() || null,
    description: stripHtml(row['الوصف']),
    price: parseFloat(row['سعر المنتج']) || null,
    discounted_price: parseFloat(row['السعر المخفض']) || null,
    quantity: parseInt(row['الكمية المتوفرة']) || 0,
    status: (row['حالة المنتج'] || '').trim() || null,
    product_type: (row['نوع المنتج'] || '').trim() || null,
    promo_label: (row['العنوان الترويجي'] || '').trim() || null,
    image_url: (row['صورة المنتج'] || '').trim() || null,
    weight: parseFloat(row['الوزن']) || null,
    variants: extractVariants(row)
  };
}
async function importFromCsv(filePath, uploadedBy) {
  const startTime = Date.now();
  const u = db.prepare(`INSERT INTO uploads (filename, file_size, status, uploaded_by) VALUES (?, ?, 'processing', ?)`)
    .run(path.basename(filePath), fs.statSync(filePath).size, uploadedBy || 'employee');
  const uploadId = u.lastInsertRowid;
  try {
    const existing = new Set(db.prepare('SELECT salla_no FROM products WHERE salla_no IS NOT NULL').all().map(r => r.salla_no));
    const seen = new Set();
    let added = 0, updated = 0;
    const upsert = db.prepare(`
      INSERT INTO products (salla_no, sku, name, category, description, price, discounted_price,
        quantity, status, product_type, promo_label, image_url, weight, variants, updated_at)
      VALUES (@salla_no, @sku, @name, @category, @description, @price, @discounted_price,
        @quantity, @status, @product_type, @promo_label, @image_url, @weight, @variants, CURRENT_TIMESTAMP)
      ON CONFLICT(salla_no) DO UPDATE SET
        sku=excluded.sku, name=excluded.name, category=excluded.category,
        description=excluded.description, price=excluded.price, discounted_price=excluded.discounted_price,
        quantity=excluded.quantity, status=excluded.status, product_type=excluded.product_type,
        promo_label=excluded.promo_label, image_url=excluded.image_url, weight=excluded.weight,
        variants=excluded.variants, updated_at=CURRENT_TIMESTAMP
    `);
    const records = await new Promise((resolve, reject) => {
      parse(fs.readFileSync(filePath, 'utf-8'), {
        bom: true, columns: (cols) => cols.map(c => c ? c.toString() : ''),
        skip_empty_lines: true, relax_column_count: true, from_line: 2
      }, (err, recs) => err ? reject(err) : resolve(recs));
    });
    console.log(`[Import] Parsed ${records.length} rows`);
    db.transaction((recs) => {
      for (const row of recs) {
        const p = parseRow(row);
        if (!p || !p.salla_no) continue;
        seen.add(p.salla_no);
        if (existing.has(p.salla_no)) updated++; else added++;
        upsert.run(p);
      }
    })(records);
    let deleted = 0;
    if (seen.size > 0) {
      deleted = db.prepare('DELETE FROM products WHERE salla_no NOT IN (SELECT value FROM json_each(?))')
        .run(JSON.stringify([...seen])).changes;
    }
    const totalAfter = db.prepare('SELECT COUNT(*) as c FROM products').get().c;
    const duration = Date.now() - startTime;
    db.prepare(`UPDATE uploads SET products_added=?, products_updated=?, products_deleted=?, total_after=?, duration_ms=?, status='success' WHERE id=?`)
      .run(added, updated, deleted, totalAfter, duration, uploadId);
    return { uploadId, added, updated, deleted, totalAfter, durationMs: duration, status: 'success' };
  } catch (err) {
    db.prepare(`UPDATE uploads SET status='failed', error_message=?, duration_ms=? WHERE id=?`)
      .run(err.message, Date.now() - startTime, uploadId);
    throw err;
  }
}
module.exports = { importFromCsv, parseRow };
