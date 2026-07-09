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

# 3. accountant login is now SESSION-BASED (not nginx basic-auth).
#    Users live in the `accountant_users` table (bcrypt passwords). Seed them with:
#    docker exec returns_service python3 -c "..."  (bcrypt hash + INSERT) — see below.
#    Login page: /accountant-login  ·  Logout: /accountant-logout
#    Cookie 'returns_session' (httponly, secure); "تذكرني" = 30 days, else 1 day.
```

## Seeding an accountant user

```bash
docker exec -e EM='financial@qaydao.com' -e PW='<password>' returns_service python3 -c "
import os,asyncio,asyncpg,bcrypt
async def m():
    c=await asyncpg.connect(os.environ['DATABASE_URL'])
    h=bcrypt.hashpw(os.environ['PW'].encode(),bcrypt.gensalt()).decode()
    await c.execute('INSERT INTO accountant_users(email,password_hash,display_name) VALUES(\$1,\$2,\$3) ON CONFLICT(email) DO UPDATE SET password_hash=EXCLUDED.password_hash', os.environ['EM'], h, 'المحاسبة')
    await c.close()
asyncio.run(m())"
```

> ⚠ Re-check the injected script after every Chatwoot upgrade (same as all `qaydao-*.js`).
> This copy is a snapshot; the server file is the source of truth for live behavior.
