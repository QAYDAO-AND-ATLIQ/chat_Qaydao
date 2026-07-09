# Returns Service — Rollback

Fully isolated sidecar. Removing it does NOT affect Chatwoot in any way.

## 1. Stop & remove the service + its database (data included)
```bash
cd /root/chat-qaydao/returns-service
docker compose -p returns_service -f docker-compose.yml down -v
# -v also drops the returns_pgdata volume (all return-request data). Omit -v to keep data.
```

## 2. Remove nginx blocks + injected script
Edit `/etc/nginx/sites-available/chat.qaydao.com` and delete:
- `location = /accountant-returns { ... }`
- `location /returns/api { ... }`
- `location = /qaydao-returns-tab.js { ... }`
- The `<script src="/qaydao-returns-tab.js" defer></script>` fragment inside the `sub_filter` line.

Or restore the pre-change backup:
```bash
ls -t /etc/nginx/sites-available/chat.qaydao.com.bak-accountant-* | head -1   # find newest
cp <that-backup> /etc/nginx/sites-available/chat.qaydao.com
nginx -t && systemctl reload nginx
```

## 3. Remove files
```bash
rm -f /var/www/qaydao-injection/qaydao-returns-tab.js
rm -f /etc/nginx/.htpasswd-accountant-returns
rm -rf /root/chat-qaydao/returns-service     # optional: removes source too
systemctl reload nginx
```

## Guarantees
- No Chatwoot table, container, network config, or volume is modified by this service.
- `returns_db` is a separate Postgres container/volume; dropping it cannot affect `chatwoot_postgres`.
- The only edits outside this folder are additive nginx location blocks + one static JS file.
