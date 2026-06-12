require('dotenv').config();
const express = require('express');
const rateLimit = require('express-rate-limit');
const path = require('path');
const db = require('./db');               // read-only catalog
const recordsDb = require('./recordsDb'); // write — deal_records ONLY

const app = express();
const PORT = parseInt(process.env.PORT, 10) || 3611;
const KEY = process.env.PREVIEW_KEY || '';
const ADMIN_KEY = process.env.ADMIN_KEY || '';
const BASE = '/deal';

// ── Chatwoot ──
const CW_URL = (process.env.CHATWOOT_BASE_URL || 'https://chat.qaydao.com').replace(/\/$/, '');
const CW_TOK = process.env.CHATWOOT_API_TOKEN || '';
const CW_ACC = process.env.CHATWOOT_ACCOUNT_ID || '1';

// ── commission model: SERVER-SIDE source of truth (client values are never trusted) ──
const COMMISSION = { baseRateByDiscount: { 0: 1.5, 3: 1.5, 5: 1, 7: 1, 10: 0.5 }, addonRate: 1.5 };
const ALLOWED_DISCOUNTS = [0, 3, 5, 7, 10];
function computeDeal({ base_price, discount_pct, addons }) {
  const price = Math.max(0, parseFloat(base_price) || 0);
  const disc = ALLOWED_DISCOUNTS.includes(Number(discount_pct)) ? Number(discount_pct) : 0;
  const list = Array.isArray(addons) ? addons.slice(0, 30).map(a => ({
    id: String(a.id || ''), name: String(a.name || '').slice(0, 300), price: Math.max(0, parseFloat(a.price) || 0),
  })) : [];
  const baseAfter = Math.round(price * (1 - disc / 100));
  const rate = COMMISSION.baseRateByDiscount[disc] ?? 1;
  const baseComm = baseAfter * rate / 100;
  const addonComm = list.reduce((s, a) => s + a.price * COMMISSION.addonRate / 100, 0);
  const cart = baseAfter + list.reduce((s, a) => s + a.price, 0);
  return { price, disc, addons: list, baseAfter, cart, commission: Math.round((baseComm + addonComm) * 100) / 100 };
}

// ── Chatwoot identity verification from the browser session cookie (same domain) ──
function parseCwSession(cookieHeader) {
  try {
    const m = (cookieHeader || '').match(/cw_d_session_info=([^;]+)/);
    if (!m) return null;
    const j = JSON.parse(decodeURIComponent(m[1]));
    const at = j['access-token'] || j.access_token, client = j.client, uid = j.uid;
    if (at && client && uid) return { 'access-token': at, client, uid, 'token-type': 'Bearer' };
    return null;
  } catch { return null; }
}
async function chatwootIdentity(req) {
  const h = parseCwSession(req.headers.cookie);
  if (!h) return null;
  try {
    const r = await fetch(`${CW_URL}/api/v1/profile`, { headers: h });
    if (!r.ok) return null;
    const p = await r.json();
    if (!p || !p.id) return null;
    return { id: String(p.id), name: (p.available_name || p.name || '').trim(), email: p.email || '' };
  } catch { return null; }
}

app.set('trust proxy', 1);
app.use(express.json({ limit: '256kb' }));

// ── gates ──
function gate(req, res, next) {
  const cookieKey = (req.headers.cookie || '').match(/deal_key=([^;]+)/);
  const k = req.query.key || req.get('x-deal-key') || (cookieKey ? cookieKey[1] : null);
  if ((KEY && k === KEY) || (ADMIN_KEY && k === ADMIN_KEY)) {
    if (req.query.key) res.setHeader('Set-Cookie', `deal_key=${k}; Path=${BASE}; HttpOnly; SameSite=Lax; Max-Age=43200`);
    return next();
  }
  return res.status(401).type('html').send('<div dir="rtl" style="font-family:system-ui;text-align:center;padding:3rem;color:#444"><h2>\u{1F512} \u0635\u0641\u062D\u0629 \u0642\u064A\u062F \u0627\u0644\u0645\u0631\u0627\u062C\u0639\u0629</h2><p>\u0645\u0641\u062A\u0627\u062D \u0627\u0644\u0648\u0635\u0648\u0644 \u063A\u064A\u0631 \u0635\u0627\u0644\u062D.</p></div>');
}
function adminGate(req, res, next) {
  const cookieKey = (req.headers.cookie || '').match(/deal_key=([^;]+)/);
  const k = req.query.key || req.get('x-deal-key') || (cookieKey ? cookieKey[1] : null);
  if (ADMIN_KEY && k === ADMIN_KEY) {
    if (req.query.key) res.setHeader('Set-Cookie', `deal_key=${k}; Path=${BASE}; HttpOnly; SameSite=Lax; Max-Age=43200`);
    return next();
  }
  return res.status(401).json({ ok: false, error: '\u0635\u0644\u0627\u062D\u064A\u0629 \u0625\u062F\u0627\u0631\u064A\u0629 \u0645\u0637\u0644\u0648\u0628\u0629' });
}

const apiLimiter = rateLimit({ windowMs: 60000, max: 150, standardHeaders: true, legacyHeaders: false });

// ── catalog helpers ──
const VISIBLE = "is_active = true AND (status IS NULL OR status NOT IN ('\u0645\u062E\u0641\u064A','\u063A\u064A\u0631 \u0645\u062A\u0627\u062D'))";
const COLS = 'id,name,category_main,category_path,price_regular,price_discounted,quantity_available,status,image_url';
function mapProduct(p) {
  const d = parseFloat(p.price_discounted) || 0;
  const r = parseFloat(p.price_regular) || 0;
  const sell = d > 0 ? d : r;
  return { id: p.id, name: p.name, category: p.category_main || null, price: Math.round(sell),
           was: r > sell ? Math.round(r) : null,
           image: p.image_url ? String(p.image_url).split(',')[0] : null, qty: p.quantity_available };
}

// ── search ──
app.get(BASE + '/api/search', gate, apiLimiter, async (req, res) => {
  try {
    const q = (req.query.q || '').trim();
    const max = parseFloat(req.query.max) || null;
    const limit = Math.min(parseInt(req.query.limit, 10) || 24, 40);
    const params = []; const where = [VISIBLE];
    if (q) { params.push('%' + q + '%'); where.push(`(name ILIKE $${params.length} OR sku ILIKE $${params.length} OR category_path ILIKE $${params.length})`); }
    if (max) { params.push(max); where.push(`COALESCE(NULLIF(price_discounted,0),price_regular) <= $${params.length}`); }
    params.push(limit);
    const rows = await db.all(`SELECT ${COLS} FROM master_products WHERE ${where.join(' AND ')}
      ORDER BY (image_url IS NOT NULL) DESC, (price_discounted IS NOT NULL) DESC, id LIMIT $${params.length}`, params);
    res.json({ ok: true, count: rows.length, products: rows.map(mapProduct) });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── complements ──
app.get(BASE + '/api/complements', gate, apiLimiter, async (req, res) => {
  try {
    const cat = (req.query.category || '').trim();
    const exclude = (req.query.exclude || '').trim();
    const limit = Math.min(parseInt(req.query.limit, 10) || 8, 16);
    const params = []; const where = [VISIBLE, 'image_url IS NOT NULL'];
    if (exclude) { params.push(exclude); where.push(`id <> $${params.length}`); }
    if (cat) { params.push(cat); where.push(`(category_main = $${params.length} OR category_path ILIKE '%' || $${params.length} || '%')`); }
    params.push(limit);
    const rows = await db.all(`SELECT ${COLS} FROM master_products WHERE ${where.join(' AND ')}
      ORDER BY (price_discounted IS NOT NULL) DESC, random() LIMIT $${params.length}`, params);
    res.json({ ok: true, count: rows.length, products: rows.map(mapProduct) });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── who am I (verified Chatwoot identity from session cookie) ──
app.get(BASE + '/api/whoami', gate, apiLimiter, async (req, res) => {
  const me = await chatwootIdentity(req);
  res.json({ ok: true, identified: !!me, me });
});

// ── agents (fallback list when no Chatwoot session) ──
let agentsCache = { t: 0, data: null };
app.get(BASE + '/api/agents', gate, apiLimiter, async (req, res) => {
  try {
    if (agentsCache.data && Date.now() - agentsCache.t < 300000) return res.json({ ok: true, cached: true, agents: agentsCache.data });
    const r = await fetch(`${CW_URL}/api/v1/accounts/${CW_ACC}/agents`, { headers: { api_access_token: CW_TOK } });
    if (!r.ok) throw new Error('chatwoot HTTP ' + r.status);
    const list = await r.json();
    const agents = (Array.isArray(list) ? list : [])
      .map(a => ({ id: String(a.id), name: (a.available_name || a.name || '').trim(), email: a.email }))
      .filter(a => a.name).sort((a, b) => a.name.localeCompare(b.name, 'ar'));
    agentsCache = { t: Date.now(), data: agents };
    res.json({ ok: true, agents });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── record (server recomputes commission; identity enforced from Chatwoot session when present) ──
app.post(BASE + '/api/record', gate, apiLimiter, async (req, res) => {
  try {
    const b = req.body || {};
    const order = String(b.order_number || '').trim().slice(0, 40);
    if (!order) return res.status(400).json({ ok: false, error: '\u0631\u0642\u0645 \u0627\u0644\u0637\u0644\u0628 \u0645\u0637\u0644\u0648\u0628' });
    if (!/^[0-9A-Za-z\-]{3,40}$/.test(order)) return res.status(400).json({ ok: false, error: '\u0631\u0642\u0645 \u0627\u0644\u0637\u0644\u0628 \u063A\u064A\u0631 \u0635\u0627\u0644\u062D' });

    // identity: Chatwoot session wins; otherwise fall back to the submitted name (flagged unverified)
    const cw = await chatwootIdentity(req);
    const empId = cw ? cw.id : String(b.employee_id || '').trim();
    const empName = cw ? cw.name : String(b.employee_name || '').trim();
    const verified = !!cw;
    if (!empId || !empName) return res.status(400).json({ ok: false, error: '\u0627\u0644\u0647\u0648\u064A\u0629 \u0645\u0637\u0644\u0648\u0628\u0629 \u2014 \u0633\u062C\u0651\u0644 \u062F\u062E\u0648\u0644\u0643 \u0641\u064A chat.qaydao.com' });

    // money: server-side recompute (client commission is ignored)
    const calc = computeDeal({ base_price: b.base_price, discount_pct: b.discount_pct, addons: b.addons });
    if (calc.price <= 0) return res.status(400).json({ ok: false, error: '\u0633\u0639\u0631 \u0627\u0644\u0645\u0646\u062A\u062C \u063A\u064A\u0631 \u0635\u0627\u0644\u062D' });

    const coupon = String(b.coupon || '').trim().slice(0, 60) || null;
    const row = await recordsDb.one(
      `INSERT INTO deal_records
        (order_number, employee_id, employee_name, base_product_id, base_product_name,
         base_price, discount_pct, base_after, addons, cart_value, commission, coupon, status, verified_employee)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'pending',$13)
       ON CONFLICT (order_number) WHERE status <> 'rejected' DO NOTHING
       RETURNING id, commission`,
      [order, empId, empName, String(b.base_product_id || '').slice(0, 60) || null,
       String(b.base_product_name || '').slice(0, 300) || null,
       calc.price, calc.disc, calc.baseAfter, JSON.stringify(calc.addons),
       calc.cart, calc.commission, coupon, verified]
    );
    if (!row) return res.status(409).json({ ok: false, error: '\u0631\u0642\u0645 \u0627\u0644\u0637\u0644\u0628 \u0645\u0633\u062C\u0651\u0644 \u0645\u0633\u0628\u0642\u0627\u064B \u0644\u0635\u0641\u0642\u0629 \u0623\u062E\u0631\u0649' });
    res.json({ ok: true, id: row.id, commission: Number(row.commission), verified, employee_name: empName, status: 'pending' });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── review (Mareek): approve / reject — ADMIN_KEY only ──
app.post(BASE + '/api/review', adminGate, apiLimiter, async (req, res) => {
  try {
    const id = parseInt((req.body || {}).id, 10);
    const action = (req.body || {}).action;
    if (!id || !['approve', 'reject', 'pending'].includes(action)) return res.status(400).json({ ok: false, error: 'id/action \u063A\u064A\u0631 \u0635\u0627\u0644\u062D' });
    const status = action === 'approve' ? 'approved' : action === 'reject' ? 'rejected' : 'pending';
    const row = await recordsDb.one(
      `UPDATE deal_records SET status=$1, reviewed_by='admin', reviewed_at=now() WHERE id=$2 RETURNING id, status`,
      [status, id]);
    if (!row) return res.status(404).json({ ok: false, error: '\u0627\u0644\u0635\u0641\u0642\u0629 \u063A\u064A\u0631 \u0645\u0648\u062C\u0648\u062F\u0629' });
    res.json({ ok: true, id: row.id, status: row.status });
  } catch (e) {
    if (String(e.message).includes('deal_records_order_active_uq')) return res.status(409).json({ ok: false, error: '\u0631\u0642\u0645 \u0627\u0644\u0637\u0644\u0628 \u0623\u0635\u0628\u062D \u0645\u0633\u062C\u0651\u0644\u0627\u064B \u0641\u064A \u0635\u0641\u0642\u0629 \u0623\u062E\u0631\u0649' });
    res.status(500).json({ ok: false, error: e.message });
  }
});

// ── monthly report data (status-aware) ──
app.get(BASE + '/api/report', adminGate, apiLimiter, async (req, res) => {
  try {
    const month = /^\d{4}-\d{2}$/.test(req.query.month || '') ? req.query.month : new Date().toISOString().slice(0, 7);
    const summary = await recordsDb.all(
      `SELECT employee_name,
              count(*) FILTER (WHERE status<>'rejected')::int AS deals,
              COALESCE(sum(cart_value) FILTER (WHERE status<>'rejected'),0)::float AS cart,
              COALESCE(sum(commission) FILTER (WHERE status='approved'),0)::float AS comm_approved,
              COALESCE(sum(commission) FILTER (WHERE status='pending'),0)::float AS comm_pending
       FROM deal_records WHERE to_char(created_at,'YYYY-MM') = $1
       GROUP BY employee_name ORDER BY comm_approved DESC, comm_pending DESC`, [month]);
    const detail = await recordsDb.all(
      `SELECT id, order_number, employee_name, base_product_name, discount_pct::float, cart_value::float,
              commission::float, coupon, status, verified_employee, created_at
       FROM deal_records WHERE to_char(created_at,'YYYY-MM') = $1 ORDER BY created_at DESC`, [month]);
    const totals = {
      deals: summary.reduce((s, r) => s + r.deals, 0),
      cart: summary.reduce((s, r) => s + r.cart, 0),
      comm_approved: summary.reduce((s, r) => s + r.comm_approved, 0),
      comm_pending: summary.reduce((s, r) => s + r.comm_pending, 0),
    };
    res.json({ ok: true, month, summary, detail, totals });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── employee dashboard data (status-aware) ──
app.get(BASE + '/api/me', gate, apiLimiter, async (req, res) => {
  try {
    const cw = await chatwootIdentity(req);
    const empId = cw ? cw.id : String(req.query.employee_id || '').trim();
    if (!empId) return res.status(400).json({ ok: false, error: 'employee_id \u0645\u0637\u0644\u0648\u0628' });
    const month = /^\d{4}-\d{2}$/.test(req.query.month || '') ? req.query.month : new Date().toISOString().slice(0, 7);
    const board = await recordsDb.all(
      `SELECT employee_id, employee_name,
              count(*) FILTER (WHERE status<>'rejected')::int AS deals,
              COALESCE(sum(cart_value) FILTER (WHERE status<>'rejected'),0)::float AS cart,
              COALESCE(sum(commission) FILTER (WHERE status<>'rejected'),0)::float AS comm,
              COALESCE(sum(commission) FILTER (WHERE status='approved'),0)::float AS comm_approved,
              COALESCE(sum(commission) FILTER (WHERE status='pending'),0)::float AS comm_pending,
              COALESCE(max(cart_value) FILTER (WHERE status<>'rejected'),0)::float AS biggest,
              COALESCE(sum(jsonb_array_length(addons)) FILTER (WHERE status<>'rejected'),0)::int AS addons_sold
       FROM deal_records WHERE to_char(created_at,'YYYY-MM') = $1
       GROUP BY employee_id, employee_name ORDER BY comm DESC`, [month]);
    const idx = board.findIndex(r => String(r.employee_id) === empId);
    const me = idx >= 0 ? board[idx] : { deals: 0, cart: 0, comm: 0, comm_approved: 0, comm_pending: 0, biggest: 0, addons_sold: 0 };
    const recent = await recordsDb.all(
      `SELECT order_number, base_product_name, discount_pct::float, cart_value::float, commission::float, coupon, status, created_at
       FROM deal_records WHERE employee_id = $1 AND to_char(created_at,'YYYY-MM') = $2
       ORDER BY created_at DESC LIMIT 5`, [empId, month]);
    const badges = [];
    if (me.deals >= 1) badges.push({ icon: '\u{1F31F}', name: '\u0623\u0648\u0644 \u0635\u0641\u0642\u0629' });
    if (me.deals >= 10) badges.push({ icon: '\u{1F525}', name: '10 \u0635\u0641\u0642\u0627\u062A' });
    if (me.biggest >= 3000) badges.push({ icon: '\u{1F451}', name: '\u0633\u0644\u0629 \u0630\u0647\u0628\u064A\u0629 +3000' });
    if (me.addons_sold >= 15) badges.push({ icon: '\u{1F9F2}', name: '\u0645\u0644\u0643 \u0627\u0644\u0645\u0643\u0645\u0651\u0644\u0627\u062A' });
    if (idx === 0 && board.length > 1) badges.push({ icon: '\u{1F3C6}', name: '\u0627\u0644\u0645\u0631\u0643\u0632 \u0627\u0644\u0623\u0648\u0644' });
    res.json({ ok: true, month, identified: !!cw,
      me: { deals: me.deals, cart: me.cart, comm: me.comm, comm_approved: me.comm_approved, comm_pending: me.comm_pending,
            biggest: me.biggest, addons_sold: me.addons_sold, avg_cart: me.deals ? me.cart / me.deals : 0 },
      rank: idx >= 0 ? idx + 1 : null, total_employees: board.length,
      leaderboard: board.slice(0, 3).map(r => ({ name: r.employee_name, comm: r.comm, deals: r.deals })),
      recent, badges });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── pages ──
function sendPage(res, file) {
  res.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.sendFile(path.join(__dirname, 'public', file));
}
app.get([BASE, BASE + '/'], gate, (req, res) => sendPage(res, 'index.html'));
app.get(BASE + '/me', gate, (req, res) => sendPage(res, 'me.html'));
app.get(BASE + '/report', adminGate, (req, res) => sendPage(res, 'report.html'));

// ── health ──
app.get(BASE + '/health', (req, res) => res.json({ ok: true, service: 'qaydao-deal' }));

app.listen(PORT, '127.0.0.1', () => console.log(`[qaydao-deal] listening on 127.0.0.1:${PORT}${BASE}`));
