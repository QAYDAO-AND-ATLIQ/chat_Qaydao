// QAYDAO Deal — read-WRITE connection, SCOPED to the deal_records table ONLY.
// The product catalog stays strictly read-only (see db.js). This pool never touches master_products.
require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PG_HOST || '127.0.0.1',
  port: parseInt(process.env.PG_PORT, 10) || 5432,
  database: process.env.PG_DB || 'qaydao_master',
  user: process.env.PG_USER || 'qaydao_master',
  password: process.env.PG_PASSWORD || '',
  max: 6,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});
pool.on('error', (e) => console.error('[deal-records] pool error:', e.message));

async function all(sql, params = []) { const { rows } = await pool.query(sql, params); return rows; }
async function one(sql, params = []) { const { rows } = await pool.query(sql, params); return rows[0] || null; }

module.exports = { all, one, pool };
