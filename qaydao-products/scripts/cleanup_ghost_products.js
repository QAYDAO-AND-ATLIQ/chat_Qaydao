#!/usr/bin/env node
/**
 * QAYDAO — Ghost Product Cleanup
 * ===============================
 * Soft-deletes products in master_products that don't exist in
 * studio.qaydao.com SQLite (the source-of-truth synced with Salla).
 *
 * Safe to run anytime — idempotent + transactional.
 *
 * Usage:
 *   node /root/qaydao-products/scripts/cleanup_ghost_products.js
 *
 * Or via cron (daily at 4am):
 *   0 4 * * * cd /root/qaydao-products && node scripts/cleanup_ghost_products.js >> logs/ghost-cleanup.log 2>&1
 *
 * Why it exists:
 * 2026-05-21 — discovered 7,650 ghost products causing Captain to
 * suggest dead product URLs to customers. Studio is synced with Salla
 * via direct DB writes, so it's the truth source.
 */
const Database = require("better-sqlite3");
const db = require("../db-pg");
const fs = require("fs");
const path = require("path");

const STUDIO_DB = "/opt/qaydao-studio/app/database/database.sqlite";
const LOG_PREFIX = "[ghost-cleanup]";

function log(msg) {
  const ts = new Date().toISOString().replace("T", " ").slice(0, 19);
  console.log(`${ts} ${LOG_PREFIX} ${msg}`);
}

async function main() {
  log("→ start");

  // 1. Read source-of-truth from studio
  const sdb = new Database(STUDIO_DB, { readonly: true });
  const validRows = sdb.prepare(`
    SELECT DISTINCT salla_product_id
    FROM products
    WHERE salla_product_id IS NOT NULL
      AND salla_product_id != ''
  `).all();
  sdb.close();

  const validIds = validRows.map((r) => String(r.salla_product_id));
  log(`studio source has ${validIds.length} valid salla_ids`);

  if (validIds.length === 0) {
    log("⚠ studio has 0 products — refusing to soft-delete master_products");
    process.exit(1);
  }
  if (validIds.length < 100) {
    log(`⚠ studio has only ${validIds.length} products — suspicious, aborting`);
    process.exit(1);
  }

  // 2. Run soft-delete in a transaction
  const client = await require("pg").Pool ? null : null; // placeholder
  await db.tx(async (tx) => {
    // Preview
    const { rows: previewRows } = await tx.query(
      `
      SELECT COUNT(*) AS n
      FROM master_products mp
      WHERE mp.deleted_at IS NULL
        AND mp.salla_id IS NOT NULL
        AND mp.salla_id != ALL($1::varchar[])
    `,
      [validIds]
    );
    const toDelete = parseInt(previewRows[0].n, 10);
    log(`will soft-delete ${toDelete} ghost products`);

    if (toDelete === 0) {
      log("✓ no ghosts found, nothing to do");
      return;
    }

    // Safety: refuse if would delete >90% of active products
    const { rows: activeRows } = await tx.query(
      "SELECT COUNT(*) AS n FROM master_products WHERE deleted_at IS NULL"
    );
    const totalActive = parseInt(activeRows[0].n, 10);
    const ratio = toDelete / totalActive;
    if (ratio > 0.9) {
      log(`⚠ would delete ${(ratio * 100).toFixed(1)}% of active — refusing`);
      throw new Error("Safety threshold exceeded");
    }

    // Apply
    const { rowCount } = await tx.query(
      `
      UPDATE master_products mp
      SET deleted_at = NOW(),
          is_active = FALSE
      WHERE mp.deleted_at IS NULL
        AND mp.salla_id IS NOT NULL
        AND mp.salla_id != ALL($1::varchar[])
    `,
      [validIds]
    );
    log(`✓ soft-deleted ${rowCount} ghost products`);

    // Final stats
    const { rows: finalRows } = await tx.query(`
      SELECT
        COUNT(*) FILTER (WHERE deleted_at IS NULL AND is_active = TRUE) AS active,
        COUNT(*) FILTER (WHERE deleted_at IS NOT NULL) AS deleted,
        COUNT(*) AS total
      FROM master_products
    `);
    const f = finalRows[0];
    log(`final state: active=${f.active} | deleted=${f.deleted} | total=${f.total}`);
  });

  log("→ done");
  process.exit(0);
}

main().catch((err) => {
  log(`✗ ERROR: ${err.message}`);
  console.error(err);
  process.exit(1);
});
