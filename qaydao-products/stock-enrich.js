// Enrich product search results' delivery_class from REAL warehouse stock.
//   linked + total available > 0  -> 'ready'
//   linked + total available == 0 -> 'made_to_order'
//   NOT linked                    -> unchanged (existing heuristic)
//   cn unreachable / slow / error -> unchanged (full fallback, search never fails)
const db = require('./db-pg');

const CN_URL    = process.env.CN_AVAILABILITY_URL || 'https://cn.qaydao.com/api/warehouse/public-availability';
const TTL_MS    = 60 * 1000;
const TIMEOUT_MS = 1500;
const cache = new Map(); // CODE -> { qty, ts }

function cached(code) {
  const e = cache.get(code);
  return (e && (Date.now() - e.ts) < TTL_MS) ? e.qty : undefined;
}

async function fetchAvailability(codes) {
  const out = {};
  const missing = [];
  for (const c of codes) {
    const v = cached(c);
    if (v !== undefined) out[c] = v; else missing.push(c);
  }
  if (missing.length) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    try {
      const r = await fetch(`${CN_URL}?codes=${encodeURIComponent(missing.join(','))}`, { signal: ctrl.signal });
      if (!r.ok) throw new Error('cn status ' + r.status);
      const data = await r.json();
      const now = Date.now();
      for (const c of missing) {
        const qty = Number.isFinite(data[c]) ? data[c] : 0; // absent in warehouse => 0 => made_to_order
        out[c] = qty;
        cache.set(c, { qty, ts: now });
      }
    } finally {
      clearTimeout(t);
    }
  }
  return out;
}

async function enrichDeliveryFromStock(products) {
  if (!Array.isArray(products) || !products.length) return products;
  const sallaIds = [...new Set(products.map(p => p.salla_id && String(p.salla_id)).filter(Boolean))];
  if (!sallaIds.length) return products;

  let linkRows;
  try {
    ({ rows: linkRows } = await db.query(
      `SELECT salla_id, warehouse_qd_code FROM product_warehouse_link WHERE salla_id = ANY($1)`,
      [sallaIds]));
  } catch (e) {
    console.error('[stock-enrich] link query failed, fallback:', e.message);
    return products;
  }
  if (!linkRows.length) return products; // nothing linked -> heuristic stays

  const bySalla = new Map();
  const allCodes = new Set();
  for (const r of linkRows) {
    const code = String(r.warehouse_qd_code).toUpperCase();
    allCodes.add(code);
    (bySalla.get(String(r.salla_id)) || bySalla.set(String(r.salla_id), []).get(String(r.salla_id))).push(code);
  }

  let avail;
  try {
    avail = await fetchAvailability([...allCodes]);
  } catch (e) {
    console.error('[stock-enrich] cn availability failed, fallback:', e.message);
    return products; // full fallback
  }

  for (const p of products) {
    const codes = bySalla.get(p.salla_id && String(p.salla_id));
    if (!codes) continue; // unlinked -> keep heuristic
    const total = codes.reduce((s, c) => s + (avail[c] || 0), 0);
    if (total > 0) {
      p.delivery_class = 'ready';
      p.delivery_estimate = '3-7 أيام (جاهز)';
    } else {
      p.delivery_class = 'made_to_order';
      p.delivery_estimate = '30-60 يوم (يُصنع حسب الطلب)';
    }
    p.stock_source = 'warehouse'; // provenance: authoritative (linked)
  }
  return products;
}

async function getAvailability(codes) {
  return fetchAvailability((codes||[]).map(c=>String(c).toUpperCase()));
}

module.exports = { enrichDeliveryFromStock, getAvailability, _cache: cache };
