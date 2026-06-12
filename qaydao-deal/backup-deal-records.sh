#!/bin/bash
# QAYDAO Deal — daily backup of the deal_records (commission) table
set -e
export PGPASSWORD="$(grep '^PG_PASSWORD=' /root/qaydao-deal/.env | cut -d= -f2-)"
OUT="/root/backups/deal/deal_records_$(date +%Y%m%d).sql.gz"
pg_dump -h 127.0.0.1 -U qaydao_master -d qaydao_master -t deal_records --no-owner | gzip > "$OUT"
# keep last 14 days locally
ls -1t /root/backups/deal/deal_records_*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
# offsite to R2 (same convention as unified-backup)
rclone copy "$OUT" "r2:cnqaydao/_server-backups/deal-records/" 2>/dev/null || true
