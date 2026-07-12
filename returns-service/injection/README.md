# Returns Service — Injection Layer & Feature Reference (archival)

The Returns feature = a **fully isolated FastAPI sidecar** (this repo, `returns-service/`) + a
**frontend injected into Chatwoot** + **nginx routes**. The frontend/nginx parts live outside the
Chatwoot repo on the server (the existing `qaydao-*.js` pattern); archival copies are kept here so
the whole feature is reconstructable from git. These files are NOT auto-applied.

## Files here

| File | Live server location | Purpose |
|------|----------------------|---------|
| `qaydao-returns-tab.js` | `/var/www/qaydao-injection/qaydao-returns-tab.js` | The **المرجعات** dropdown injected into Chatwoot's sidebar. |
| `nginx-returns-blocks.conf` | inside `/etc/nginx/sites-available/chat.qaydao.com` | nginx `location` blocks + the `sub_filter` line that injects the script. |

## What the feature does

**Agent side (inside Chatwoot, no extra login):**
- Sidebar dropdown **المرجعات** → *طلب إرجاع جديد* (form overlay) · *الطلبات المرفوعة* (team page).
- Form fields are all **required**, incl. a **mandatory** bank-account file/image (PDF/JPG/PNG/WEBP, ≤10MB).
  Conversation number is typed manually (prefilled from the URL) and is the `conversation_id` link.
  "سبب آخر" reveals a free-text reason. Form resets after each submit.
- **Agents are dynamic**: the script fetches the account's agents from Chatwoot
  (`/api/v1/profile` → `/api/v1/accounts/{id}/agents`, using the agent's own session — **no token stored**)
  to fill the *الموظف المسؤول* dropdown, and passes the list to the team page via `?agents=`.

**Team page** (`/returns/team-requests`, opened inside Chatwoot):
- **Agent boxes** (per *الموظف المسؤول*) + **8 status sections** inside the selected box:
  الكل / جديدة / سيتم الإرجاع / جاري الإرجاع / تم الإرجاع / مرفوض / قديمة—تم الإرجاع / قديمة—مرفوضة.
- Closed requests older than **7 days** move to the *قديمة* sections (age = last status change).
- Shows the accountant's reject reason + an email-contact alert, and a **transfer-receipt** download.
- **No bank account / IBAN columns** (privacy).

**Accountant page** (`/accountant-returns`, session login):
- Login page `/accountant-login` (email + password + تذكّرني 30d) · logout `/accountant-logout`.
- Users in `accountant_users` (bcrypt) — currently `financial@qaydao.com` and `rami@qaydao.com`.
- Same 8 status sections. Status flow is **pick → send**: choose a status, fill what it needs,
  then press the single **إرسال** button.
- **تم الإرجاع requires a transfer receipt** (PDF/image) — enforced in the UI *and* the API (400).
- **مرفوض is final**: reason mandatory; a rejected request can never change status (409). Re-submitting
  for that conversation creates a **new** request; the rejected one stays archived.

## Restore on a fresh server

```bash
# 1. backend
cd returns-service && docker compose -p returns_service -f docker-compose.yml up -d

# 2. injected script
cp returns-service/injection/qaydao-returns-tab.js /var/www/qaydao-injection/

# 3. nginx: add the blocks from nginx-returns-blocks.conf into the HTTPS server{} block
#    (before the main `location / {`) and append the script to the sub_filter line.
nginx -t && systemctl reload nginx
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
> The server files are the source of truth for live behavior; this is a snapshot.
