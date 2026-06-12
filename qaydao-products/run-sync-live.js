// LIVE sync execution
const sync = require('./sync-engine');

(async () => {
  console.log('🚀 LIVE SYNC: Applying changes to Studio + Sales\n');
  console.log('   (Master Catalog → Studio & Sales)\n');

  const result = await sync.syncAll({ dryRun: false });

  console.log('═══ Studio Sync (LIVE) ═══');
  const s = result.studio;
  if (s.error) {
    console.error('  ❌', s.error);
  } else {
    console.log(`  ✅ Updated:      ${s.updated}`);
    console.log(`  ⏸  Deactivated:  ${s.deactivated}`);
    console.log(`  ⏭  Skipped:      ${s.skipped}`);
    console.log(`  ❌ Errors:       ${s.errors}`);
    console.log(`  ⏱  Duration:     ${s.duration_ms}ms`);
  }

  console.log('\n═══ Sales Sync (LIVE) ═══');
  const sa = result.sales;
  if (sa.error) {
    console.error('  ❌', sa.error);
  } else {
    console.log(`  ✅ Updated:      ${sa.updated}`);
    console.log(`  ⏭  Skipped:      ${sa.skipped}`);
    console.log(`  ❌ Errors:       ${sa.errors}`);
    console.log(`  ⏱  Duration:     ${sa.duration_ms}ms`);
  }

  console.log(`\n🎯 Total Time: ${result.total_duration_ms}ms`);
  console.log(`📝 Logged to: ai_events table`);
  console.log(`📝 Change events: product_change_events table`);

  process.exit(0);
})();
