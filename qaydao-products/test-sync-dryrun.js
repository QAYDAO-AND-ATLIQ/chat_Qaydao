// Test sync engine in dry-run mode (no actual changes)
const sync = require('./sync-engine');

(async () => {
  console.log('🧪 DRY-RUN: Testing sync without applying changes\n');

  const result = await sync.syncAll({ dryRun: true });

  console.log('═══ Studio Sync (dry-run) ═══');
  const s = result.studio;
  if (s.error) {
    console.error('  ❌', s.error);
  } else {
    console.log(`  Checked:     ${s.checked}`);
    console.log(`  Would update:  ${s.updated}`);
    console.log(`  Skipped:     ${s.skipped} (already in sync)`);
    console.log(`  Would deactivate: ${s.deactivated}`);
    console.log(`  Errors:      ${s.errors}`);
    console.log(`  Duration:    ${s.duration_ms}ms`);
  }

  console.log('\n═══ Sales Sync (dry-run) ═══');
  const sa = result.sales;
  if (sa.error) {
    console.error('  ❌', sa.error);
  } else {
    console.log(`  Checked:     ${sa.checked}`);
    console.log(`  Would update:  ${sa.updated}`);
    console.log(`  Skipped:     ${sa.skipped} (already in sync OR sales-only)`);
    console.log(`  Errors:      ${sa.errors}`);
    console.log(`  Duration:    ${sa.duration_ms}ms`);
  }

  console.log(`\n⏱  Total: ${result.total_duration_ms}ms`);
  console.log('\n✅ Dry-run complete. No changes were made.');

  process.exit(0);
})();
