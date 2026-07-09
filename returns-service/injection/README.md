# Returns Service — Injection Layer (archival)

The frontend of the Returns feature lives **outside** the Chatwoot repo on the server, following the
existing `qaydao-*.js` injection pattern. This folder keeps an **archival copy** so the whole feature
is reconstructable from git. These files are NOT auto-applied — they must be placed on the server.

## Files here

| File | Live server location | Purpose |
|------|----------------------|---------|
| `qaydao-returns-tab.js` | `/var/www/qaydao-injection/qaydao-returns-tab.js` | The **المرجعات** dropdown injected into Chatwoot's sidebar: "طلب إرجاع جديد" (CS form overlay, wired to `conversation_id`) + "الطلبات المرفوعة" (team page). |
| `nginx-returns-blocks.conf` | inside `/etc/nginx/sites-available/chat.qaydao.com` | The nginx `location` blocks + the `sub_filter` line that injects the script. |

## How it wires together

1. **Backend** (this repo, versioned): `returns-service/` — FastAPI on `127.0.0.1:8091` + isolated `returns_db`.
   Deploy: `docker compose -p returns_service -f docker-compose.yml up -d`.
2. **nginx** routes:
   - `/accountant-returns` → basic-auth (`financial@qaydao.com`) → service accountant page.
   - `/returns/team-requests` → service team page (opened inside Chatwoot; no bank columns).
   - `/returns/api/...` → service API (used by the CS tab + both pages).
   - `location = /qaydao-returns-tab.js` serves the injected script; a `sub_filter` adds
     `<script src="/qaydao-returns-tab.js" defer>` before `</body>` on Chatwoot HTML.
3. **Script** adds the sidebar dropdown; the CS form saves via `POST /returns/api/requests`;
   the accountant changes status (incl. **rejected** with a mandatory reason).

## To restore the frontend on a fresh server

```bash
# 1. copy the injected script
cp returns-service/injection/qaydao-returns-tab.js /var/www/qaydao-injection/

# 2. add the nginx blocks from nginx-returns-blocks.conf into the HTTPS server{} block
#    (before the main `location / {`), plus append the returns-tab script to the sub_filter line.
nginx -t && systemctl reload nginx

# 3. create the accountant basic-auth user
htpasswd -cB /etc/nginx/.htpasswd-accountant-returns financial@qaydao.com
```

> ⚠ Re-check the injected script after every Chatwoot upgrade (same as all `qaydao-*.js`).
> This copy is a snapshot; the server file is the source of truth for live behavior.
