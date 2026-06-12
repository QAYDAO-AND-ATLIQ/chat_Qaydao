#!/usr/bin/env node
// Scheduled sync runner - called by cron
// Runs hourly to keep Studio + Sales in sync with Master

const sync = require('/root/qaydao-products/sync-engine');

(async () => {
  console.log(`[${new Date().toISOString()}] Auto-sync starting...`);

  try {
    const result = await sync.syncAll({ dryRun: false });

    const s = result.studio;
    const sa = result.sales;

    console.log(`  Studio: ${s.updated} updated, ${s.skipped} skipped, ${s.deactivated} deactivated, ${s.errors} errors`);
    console.log(`  Sales:  ${sa.updated} updated, ${sa.skipped} skipped, ${sa.errors} errors`);
    console.log(`  Total:  ${result.total_duration_ms}ms`);

    process.exit(0);
  } catch (err) {
    console.error('Auto-sync failed:', err.message);
    process.exit(1);
  }
})();
