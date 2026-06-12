// Attempts to create an isolated read-only Postgres role for qaydao-deal.
// SELECT-only on master_products. Prints RO_ROLE_OK or RO_ROLE_SKIP:<reason>.
const { Pool } = require('pg');
const crypto = require('crypto');
const fs = require('fs');

const ADMIN = {
  host: '127.0.0.1', port: 5432, database: 'qaydao_master',
  user: 'qaydao_master', password: process.env.PG_PASSWORD,
};
const RO_USER = 'qaydao_deal_ro';
const RO_PASS = 'ro_' + crypto.randomBytes(12).toString('hex');

(async () => {
  const admin = new Pool(ADMIN);
  try {
    const exists = await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1', [RO_USER]);
    if (exists.rowCount === 0) {
      await admin.query(`CREATE ROLE ${RO_USER} LOGIN PASSWORD '${RO_PASS}'`);
    } else {
      await admin.query(`ALTER ROLE ${RO_USER} PASSWORD '${RO_PASS}'`);
    }
    await admin.query(`GRANT CONNECT ON DATABASE qaydao_master TO ${RO_USER}`);
    await admin.query(`GRANT USAGE ON SCHEMA public TO ${RO_USER}`);
    await admin.query(`GRANT SELECT ON master_products TO ${RO_USER}`);
    fs.writeFileSync('/root/qaydao-deal/.ro_credentials', RO_USER + '|' + RO_PASS + '\n', { mode: 0o600 });
    console.log('RO_ROLE_OK');
  } catch (e) {
    console.log('RO_ROLE_SKIP:' + e.message);
  } finally {
    await admin.end();
  }
})();
