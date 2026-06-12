// TDD: product_warehouse_link table + /products/api/links endpoints
require('dotenv').config();
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const db = require('../db-pg');

const BASE = `http://127.0.0.1:${process.env.PORT || 3601}/products/api/links`;
const TOK = process.env.LINKS_SERVICE_TOKEN;
const H = { 'Content-Type': 'application/json', 'X-Service-Token': TOK };
const TEST_CODE = 'TEST_WH_0001';
const TEST_SALLA = 'TEST_SALLA_1';

async function cleanup() {
  await db.query(`DELETE FROM product_warehouse_link WHERE warehouse_qd_code LIKE 'TEST\\_%' OR salla_id LIKE 'TEST\\_%'`);
}
before(cleanup);
after(async () => { await cleanup(); await db.pool.end(); });

test('1. table product_warehouse_link exists', async () => {
  const { rows } = await db.query(
    `SELECT 1 FROM information_schema.tables WHERE table_name='product_warehouse_link'`);
  assert.equal(rows.length, 1);
});

test('2. POST creates a link, GET ?salla_id returns it', async () => {
  const post = await fetch(BASE, { method: 'POST', headers: H,
    body: JSON.stringify({ salla_id: TEST_SALLA, sku: 'TESTSKU', warehouse_qd_code: TEST_CODE, linked_by: 'tester' }) });
  assert.equal(post.status, 200);
  const pj = await post.json(); assert.equal(pj.success, true);
  const get = await fetch(`${BASE}?salla_id=${TEST_SALLA}`, { headers: H });
  const gj = await get.json();
  assert.ok(gj.links.some(l => l.warehouse_qd_code === TEST_CODE));
});

test('3. duplicate code = clean upsert (no second row)', async () => {
  await fetch(BASE, { method: 'POST', headers: H,
    body: JSON.stringify({ salla_id: TEST_SALLA, warehouse_qd_code: TEST_CODE, linked_by: 'tester2' }) });
  const { rows } = await db.query(
    `SELECT count(*)::int n FROM product_warehouse_link WHERE warehouse_qd_code=$1`, [TEST_CODE]);
  assert.equal(rows[0].n, 1);
});

test('4a. lookup?code returns the linked product', async () => {
  const r = await fetch(`${BASE}/lookup?code=${TEST_CODE}`, { headers: H });
  const j = await r.json();
  assert.equal(j.linked, true);
  assert.equal(j.salla_id, TEST_SALLA);
});

test('4b. lookup unknown code -> linked:false', async () => {
  const r = await fetch(`${BASE}/lookup?code=NOPE_NOT_REAL`, { headers: H });
  const j = await r.json();
  assert.equal(j.linked, false);
});

test('5. DELETE removes the link', async () => {
  const r = await fetch(`${BASE}/${TEST_CODE}`, { method: 'DELETE', headers: H });
  const j = await r.json();
  assert.equal(j.deleted, 1);
  const { rows } = await db.query(
    `SELECT count(*)::int n FROM product_warehouse_link WHERE warehouse_qd_code=$1`, [TEST_CODE]);
  assert.equal(rows[0].n, 0);
});

test('6. write without token -> 401', async () => {
  const r = await fetch(BASE, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ salla_id: 'X', warehouse_qd_code: 'Y' }) });
  assert.equal(r.status, 401);
});

test('7. auto-seed present & invariant holds (code = upper(sku))', async () => {
  const { rows } = await db.query(
    `SELECT count(*) FILTER (WHERE source='auto')::int auto,
            count(*) FILTER (WHERE source='auto' AND warehouse_qd_code<>upper(trim(sku)))::int bad
       FROM product_warehouse_link`);
  assert.ok(rows[0].auto > 0, 'expected auto-seed rows');
  assert.equal(rows[0].bad, 0, 'invariant violated');
});
