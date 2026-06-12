// QAYDAO Deal — read-only connection to the master catalog (PostgreSQL).
// Exposes only all()/one(). No insert/update/delete/transaction helpers exist here by design.
require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PG_HOST || '127.0.0.1',
  port: parseInt(process.env.PG_PORT, 10) || 5432,
  database: process.env.PG_DB || 'qaydao_master',
  user: process.env.PG_USER || 'qaydao_master',
  password: process.env.PG_PASSWORD || '',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  // belt-and-suspenders: force the session itself to be read-only
  options: '-c default_transaction_read_only=on',
});

pool.on('error', (err) => console.error('[deal-db] pool error:', err.message));

async function all(sql, params = []) {
  const { rows } = await pool.query(sql, params);
  return rows;
}

async function one(sql, params = []) {
  const { rows } = await pool.query(sql, params);
  return rows[0] || null;
}

module.exports = { all, one, pool };
