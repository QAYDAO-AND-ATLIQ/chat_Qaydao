# QAYDAO Products System — Maintenance Scripts

These scripts live in `/root/qaydao-products/scripts/` on the production server but are versioned here as the source of truth.

## `cleanup_ghost_products.js`

Soft-deletes products in `master_products` table that don't exist in `studio.qaydao.com`'s SQLite DB (the source-of-truth, synced directly with Salla).

### Why it exists

On 2026-05-21 we discovered that of 9,739 products in `master_products`, **7,650 were ghosts** — they existed in DB but had no corresponding entry in Salla. Captain AI was suggesting their URLs to customers, leading to 404/403 pages.

The cleanup script restored data integrity. This script runs daily to prevent regressions.

### Safety features

- **Backup-first design**: Run pg_dump before modifications (the operator does this; script does NOT auto-backup).
- **Hard floor**: Aborts if studio has fewer than 100 products (catches sync failures).
- **Soft delete only**: Sets `deleted_at = NOW()` and `is_active = FALSE`. Never DROPs. Easy rollback: `UPDATE master_products SET deleted_at = NULL, is_active = TRUE WHERE deleted_at::date = '2026-05-21';`
- **Drift threshold**: Refuses to delete if it would soft-delete >90% of active products.
- **Idempotent**: Safe to run any time. Reports "no ghosts found" if already clean.

### Deployment

Installed on server with cron schedule:
```
0 4 * * * cd /root/qaydao-products && /usr/bin/node scripts/cleanup_ghost_products.js >> logs/ghost-cleanup.log 2>&1
```

### Sync workflow (how products flow)

```
Salla (source) 
  ↓ (real-time webhook → studio app)
studio.qaydao.com SQLite (truth)
  ↓ (sync-engine.js nightly)
master_products PostgreSQL (catalog)
  ↓ (search API)
Captain AI → customer
```

This cleanup script guarantees no `master_products` entry survives that doesn't have a corresponding `studio.products.salla_product_id`.

## Monitor integration

The system monitor (`/root/chat-qaydao/monitoring/monitor.py`) has a `ghost_products` check that runs every 5 minutes:

- Compares `COUNT(master_products WHERE active)` vs `COUNT(DISTINCT studio.salla_product_id)`
- Allows up to 5% drift (or 50 products, whichever is larger) for sync timing
- Alerts to inbox 7 (🚨 تنبيهات النظام) if exceeded with exact fix command

## Recovery

If `cleanup_ghost_products.js` accidentally soft-deleted too many:

```sql
-- Restore everything cleaned on a specific date
UPDATE master_products 
SET deleted_at = NULL, is_active = TRUE 
WHERE deleted_at::date = '2026-05-21';
```

The 2026-05-21 backup is at:
`/root/qaydao-products/backups/master_products_pre_ghost_cleanup_20260521_155953.sql.gz`
