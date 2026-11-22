// Real warehouse stock for product search results.
//
// 2026-11-22 (QAYDAO AI audit): search used to rank by Salla quantity/labels and only
// corrected delivery_class for explicitly LINKED products — so a chair with 35 units in
// the Jeddah warehouse was offered as "made to order" while five made-to-order chairs
// were shown first. Now:
//   * codes per product = explicit links (product_warehouse_link) + the product SKU
//     (same auto sku==code match the stock-by-salla endpoint already uses);
//   * any product with a code gets an authoritative answer from the warehouse:
//       available > 0 -> ready (in_stock=true, available_qty)
//       available = 0 -> made_to_order
//   * products without any code keep the old label heuristic;
//   * warehouse unreachable / slow -> everything unchanged (search never fails).
//   * readyFromWarehouse(q) finds IN-STOCK warehouse items matching the query and maps
//     them back to store products, so ready stock is offered even when the text search
//     did not rank it in the top results.
const db = require('./db-pg');

const CN_URL        = process.env.CN_AVAILABILITY_URL || 'https://cn.qaydao.com/api/warehouse/public-availability';
const CN_SEARCH_URL = process.env.CN_SEARCH_URL || CN_URL.replace(/public-availability$/, 'public-search');
const TTL_MS     = 60 * 1000;
const TIMEOUT_MS = 1500;
const cache = new Map(); // CODE -> { qty, ts }

// Lead times approved by Rami (2026-11-02).
const READY_ESTIMATE = 'جاهز في المستودع: تجهيز خلال 48 ساعة ثم توصيل خلال 3 أيام';
const MTO_ESTIMATE   = 'يُصنع حسب الطلب: حتى 60 يوم عمل من تاريخ الطلب';

const norm = c => String(c || '').trim().toUpperCase();

function cached(code) {
  const e = cache.get(code);
  return (e && (Date.now() - e.ts) < TTL_MS) ? e.qty : undefined;
}

async function fetchJson(url) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(url, { signal: ctrl.signal });
    if (!r.ok) throw new Error('cn status ' + r.status);
    return await r.json();
  } finally {
    clearTimeout(t);
  }
}

async function fetchAvailability(codes) {
  const out = {};
  const missing = [];
  for (const c of codes) {
    const v = cached(c);
    if (v !== undefined) out[c] = v; else missing.push(c);
  }
  if (missing.length) {
    const data = await fetchJson(`${CN_URL}?codes=${encodeURIComponent(missing.join(','))}`);
    const now = Date.now();
    for (const c of missing) {
      const qty = Number.isFinite(data[c]) ? data[c] : 0; // absent in warehouse => 0 => made_to_order
      out[c] = qty;
      cache.set(c, { qty, ts: now });
    }
  }
  return out;
}

async function codesForProducts(products) {
  const bySalla = new Map();
  const sallaIds = [];
  for (const p of products) {
    const sid = p.salla_id && String(p.salla_id);
    if (!sid) continue;
    sallaIds.push(sid);
    if (p.sku) bySalla.set(sid, new Set([norm(p.sku)]));
  }
  if (sallaIds.length) {
    const { rows } = await db.query(
      `SELECT salla_id, warehouse_qd_code FROM product_warehouse_link WHERE salla_id = ANY($1)`,
      [[...new Set(sallaIds)]]);
    for (const r of rows) {
      const sid = String(r.salla_id);
      (bySalla.get(sid) || bySalla.set(sid, new Set()).get(sid)).add(norm(r.warehouse_qd_code));
    }
  }
  return bySalla;
}

function markReady(p, qty) {
  p.delivery_class = 'ready';
  p.delivery_estimate = READY_ESTIMATE;
  p.in_stock = true;
  p.available_qty = qty;
  p.availability = 'متوفر في المستودع';
  p.stock_source = 'warehouse';
}

function markMadeToOrder(p) {
  p.delivery_class = 'made_to_order';
  p.delivery_estimate = MTO_ESTIMATE;
  p.in_stock = false;
  p.available_qty = 0;
  p.availability = 'يُصنع حسب الطلب';
  p.stock_source = 'warehouse';
}

async function enrichDeliveryFromStock(products) {
  if (!Array.isArray(products) || !products.length) return products;
  let bySalla;
  try {
    bySalla = await codesForProducts(products);
  } catch (e) {
    console.error('[stock-enrich] link query failed, fallback:', e.message);
    return products;
  }
  const allCodes = new Set();
  for (const set of bySalla.values()) for (const c of set) allCodes.add(c);
  if (!allCodes.size) return products;

  let avail;
  try {
    avail = await fetchAvailability([...allCodes]);
  } catch (e) {
    console.error('[stock-enrich] cn availability failed, fallback:', e.message);
    return products; // full fallback
  }

  for (const p of products) {
    const codes = bySalla.get(p.salla_id && String(p.salla_id));
    if (!codes || !codes.size) continue; // no code at all -> heuristic stays
    const total = [...codes].reduce((s, c) => s + (avail[c] || 0), 0);
    if (total > 0) markReady(p, total); else markMadeToOrder(p);
  }
  return products;
}

// Store product rows (master_products) for in-stock warehouse items matching q.
// Returns [] on any failure.
async function readyFromWarehouse(q, { exclude = [], limit = 5 } = {}) {
  try {
    const items = await fetchJson(`${CN_SEARCH_URL}?q=${encodeURIComponent(q)}&limit=30`);
    const ready = (Array.isArray(items) ? items : []).filter(i => (i.available_qty || 0) > 0);
    if (!ready.length) return [];
    const codes = [...new Set(ready.flatMap(i => [norm(i.qd_code), norm(i.cn_code)]).filter(Boolean))];
    const { rows } = await db.query(`
      SELECT DISTINCT ON (mp.salla_id)
             mp.id, mp.salla_id, mp.sku, mp.name, mp.description, mp.short_desc, mp.category_path,
             mp.category_main, mp.product_type, mp.price_regular, mp.price_discounted, mp.status,
             mp.quantity_available, mp.promo_label, mp.weight, mp.weight_unit, mp.image_url,
             mp.product_url, mp.taxable, mp.variants_json, 0.0 AS name_score
      FROM master_products mp
      LEFT JOIN product_warehouse_link l ON l.salla_id = mp.salla_id
      WHERE mp.deleted_at IS NULL AND mp.is_active = TRUE
        AND mp.status IS DISTINCT FROM 'مخفي' AND mp.status IS DISTINCT FROM 'غير متاح'
        AND (UPPER(TRIM(mp.sku)) = ANY($1) OR UPPER(TRIM(l.warehouse_qd_code)) = ANY($1))
        AND NOT (mp.salla_id = ANY($2))
      ORDER BY mp.salla_id
      LIMIT $3`, [codes, exclude.map(String), limit]);
    return rows;
  } catch (e) {
    console.error('[stock-enrich] readyFromWarehouse failed, skipped:', e.message);
    return [];
  }
}

async function getAvailability(codes) {
  return fetchAvailability((codes || []).map(norm));
}

module.exports = {
  enrichDeliveryFromStock, readyFromWarehouse, getAvailability,
  READY_ESTIMATE, MTO_ESTIMATE, _cache: cache,
};
