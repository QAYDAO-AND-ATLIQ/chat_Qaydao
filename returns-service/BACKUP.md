# Returns Service — Backup & Restore

## Automated backup

`backup.sh` runs **daily at 03:00** via cron:

```
0 3 * * * /root/chat-qaydao/returns-service/backup.sh >> /var/log/returns-backup.log 2>&1
```

Each run writes to `/root/backups/returns/<YYYYMMDD-HHMMSS>/`:

| File | Contents |
|------|----------|
| `returns_db.sql.gz` | Full `pg_dump` of the `returns` database (requests, status history, accountant users, sessions) |
| `uploads.tar.gz` | Bank-account attachments + transfer receipts (omitted if there are none) |

**Retention:** 30 days (older backup folders are pruned automatically).
**Safety checks:** the script aborts if a container is down or if the dump doesn't contain
`return_requests`, so a broken backup never silently replaces a good one.
**Log:** `/var/log/returns-backup.log`

## Restore

```bash
# pick a backup
LATEST=$(ls -td /root/backups/returns/*/ | head -1)   # or a specific folder

# 1. database (the dump is --clean --if-exists, so it drops+recreates its own objects)
zcat "$LATEST/returns_db.sql.gz" | docker exec -i returns_db psql -U rguard -d returns

# 2. uploaded files (only if uploads.tar.gz exists)
tar -xzf "$LATEST/uploads.tar.gz" -C /tmp/
docker cp /tmp/uploads/. returns_service:/data/uploads/
rm -rf /tmp/uploads

# 3. verify
docker exec returns_db psql -U rguard -d returns -c "SELECT count(*) FROM return_requests;"
docker exec returns_service sh -c 'ls -A /data/uploads | wc -l'
```

Restoring the DB also restores `accountant_users` — the accountant/admin logins come back with it.

> This restore path was tested end-to-end (create data → back up → wipe → restore → data intact).

## Manual backup (before risky changes)

```bash
/root/chat-qaydao/returns-service/backup.sh
```
