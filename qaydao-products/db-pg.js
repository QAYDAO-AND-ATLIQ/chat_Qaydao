// QAYDAO Master Catalog - Database connection (PostgreSQL)
require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PG_HOST || '127.0.0.1',
  database: process.env.PG_DB || 'qaydao_master',
  user: process.env.PG_USER || 'qaydao_master',
  password: process.env.PG_PASSWORD || '',
  port: parseInt(process.env.PG_PORT) || 5432,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000
});

pool.on('error', (err) => {
  console.error('[PG] Pool error:', err.message);
});

// Helper: simple query
async function query(sql, params = []) {
  return pool.query(sql, params);
}

// Helper: get single row
async function one(sql, params = []) {
  const { rows } = await pool.query(sql, params);
  return rows[0] || null;
}

// Helper: get all rows
async function all(sql, params = []) {
  const { rows } = await pool.query(sql, params);
  return rows;
}

// Helper: transaction
async function tx(callback) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, query, one, all, tx };
