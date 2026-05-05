# Chat QAYDAO — Customer Chat Platform

> **Production:** [chat.qaydao.com](https://chat.qaydao.com)
> **Stack:** Chatwoot v4.13.0 (Ruby on Rails) + PostgreSQL + Redis + Sidekiq
> **Deployment:** Docker Compose on QAYDAO VPS (69.62.73.5)

---

## Overview

Chatwoot-based omnichannel customer support platform for QAYDAO ecosystem.
Handles WhatsApp Business, Email, WebWidget, and Instagram in a unified inbox.

## Tech Stack

| Layer | Technology |
|---|---|
| Application | Chatwoot v4.13.0 (Ruby on Rails) |
| Database | PostgreSQL 16 (pgvector image) |
| Cache / Queue | Redis 7 |
| Background jobs | Sidekiq |
| Reverse proxy | Nginx (host) → Traefik network |
| TLS | Wildcard cert via Traefik DNS-01 |

## Channels (Inboxes)

| ID | Name | Channel | Notes |
|---|---|---|---|
| 2 | QAYDAO بريد | Email | SMTP via Gmail |
| 3 | QAYDAO | WebWidget | qaydao.com chat bubble |
| 5 | QAYDAO | WhatsApp | via Whatomate / Evolution API |
| 6 | qaydao | Instagram | Meta Business |

## Key Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Service stack |
| `.env` | Secrets + runtime config (gitignored) |
| `custom-theme/` | QAYDAO branding overrides |
| `nginx-chat.qaydao.com.conf` | Nginx server block |
| `patches/services/messages/in_reply_to_message_builder.rb` | QAYDAO patch: preserve quote context for messages from outside Chatwoot (Whatomate) |
| `setup_*.rb` | One-shot account/agent/inbox/automation bootstrap scripts |
| `check_inboxes.rb` | Inbox verification helper |
| `apply-branding.sh` | Apply custom theme |

## Deployment

```bash
docker compose up -d
# To pick up .env changes:
docker compose up -d --force-recreate chatwoot-web chatwoot-sidekiq
```

## Operational Configuration (current)

These are non-default decisions baked into `.env` and DB state. Document any change here.

### Performance / UX
- **`CONVERSATION_RESULTS_PER_PAGE=50`** *(default 25)* — single page covers normal daily load (~37–50 open convos), eliminates infinite-scroll surprise where the badge said "37" but only 25 rendered until scroll.

### Account Architecture
- **Single account** (`account_id=1`, name "QAYDAO"). A duplicate empty `account_id=2` was deleted in the unification migration (see Change Log 2026-05-03).
- All admins and agents live under account 1.

### Inbox Membership Policy — **Cross-channel visibility ON**
- **Every active user (admins + agents) is a member of every inbox** (2, 3, 5, 6).
- Rationale: QAYDAO support is one unified workflow, not siloed channels. A customer may start on email and continue on WhatsApp; any agent picking up should see the full picture under tab "All".
- **Important:** removing a user from an inbox will hide that inbox's conversations from them in tab "All" — even for admins, even when assigned to them.
- New agents must be added to all 4 inboxes on onboarding. Add to `setup_agents.rb` if creating one.

### Patches (vendored on top of upstream Chatwoot)
- `patches/services/messages/in_reply_to_message_builder.rb` — bind-mounted read-only into `/app/...` for both `chatwoot-web` and `chatwoot-sidekiq`. Re-apply on every Chatwoot upgrade.

## Roles in this Account

| User | Role | Login |
|---|---|---|
| QAYDAO Admin | administrator | admin@qaydao.com |
| فريق QAYDAO | administrator | support@qaydao.com (shared team mailbox) |
| rami | administrator | rami@qaydao.com (founder) |
| مشرف عام | administrator | supervisor@qaydao.com |
| شيماء | agent | shimaa@qaydao.com |
| مروة | agent | marwa@qaydao.com |
| Fai | agent | fay@qaydao.com |
| محمد B2B | agent | mohammed@qaydao.com |
| maali | agent | maali@qaydao.com |

## Backup & Recovery

Pre-change snapshots live under `backups/YYYYMMDD/` (gitignored). To restore:
```bash
zcat backups/<date>/chatwoot_*.sql.gz | docker exec -i chatwoot_postgres psql -U chatwoot_user -d chatwoot_production
docker compose up -d --force-recreate chatwoot-web chatwoot-sidekiq
```

## Gotchas

- **Container restart required** for any `.env` change — `docker compose restart` is NOT enough; use `up -d --force-recreate`.
- **Patch volumes are read-only bind mounts.** Editing `patches/...` on host requires container restart to take effect.
- **`enterprise/`** code paths are loaded via `prepend_mod_with`. Custom roles only kick in for users with `role='agent' AND custom_role_id IS NOT NULL` — administrators bypass them entirely.

## Change Log

### 2026-05-03 — Unification & cross-channel visibility
**Problem reported:** Tab "All" showed only some conversations (25 of 37). Employee reported assigned conversations being invisible across users.

**Root causes found (all three real):**
1. Default `CONVERSATION_RESULTS_PER_PAGE=25` truncated page 1 silently.
2. `rami@qaydao.com` was isolated in a duplicate empty `account_id=2` — login from that account showed no data.
3. Several agents (notably `maali`) were not members of all inboxes; their tab "All" filtered out conversations from non-member inboxes — confirming the employee's report.

**Changes applied:**
- `.env`: added `CONVERSATION_RESULTS_PER_PAGE=50`.
- DB: moved `rami` from account 2 → account 1, then deleted account 2.
- DB: inserted 12 missing `inbox_members` rows so all 9 active users are members of all 4 inboxes.
- Containers: `force-recreate` of `chatwoot-web` and `chatwoot-sidekiq` to load the new env var.

**Verification:** API checks confirmed `maali` now sees all 38 open conversations (was 23), and `rami` sees full data under his own login.

**Backups:** `backups/20260503/chatwoot_pre_unification_*.sql.gz` + `.env.bak.*` + `docker-compose.yml.bak.*`.

### 2026-05-05 — Manager "All Active" Custom View
**Problem reported:** رامي (manager) couldn't see conversations #89 and #285 in tab "All". Investigation showed both were `pending` (status=2), not `open` (status=0). Tab "All" filters by assignment only and defaults to status=`open`. With 181 pending conversations vs 32 open across the account, managers were missing 85% of active workload — including conversations assigned to other agents that they need to monitor.

**Root cause:** Chatwoot's tab "All" applies a default status filter of `open`, hiding all `pending` conversations regardless of inbox membership or assignment.

**Solution:** Created a per-user `custom_filter` named `📋 كل النشطة (Open + Pending)` for the 6 manager-level users. Filter combines `status IN (open, pending)` with no other constraints, so it respects each user's inbox membership exactly the same way "All" does — but includes pending.

**Filters created (filter_type=0, account_id=1):**
| ID | User | Email | Role |
|---|---|---|---|
| 50 | rami | rami@qaydao.com | admin |
| 51 | QAYDAO Admin | admin@qaydao.com | admin |
| 52 | مشرف عام | supervisor@qaydao.com | admin |
| 53 | maali | maali@qaydao.com | agent (manager) |
| 54 | Fai | fay@qaydao.com | agent (manager) |
| 55 | فريق QAYDAO | support@qaydao.com | admin |

**Query JSON (identical for all 6):**
```json
{"payload":[{"values":["open","pending"],"attribute_key":"status","query_operator":null,"attribute_model":"standard","filter_operator":"equal_to"}]}
```

**Verification:** All 6 users see 213 conversations through the view (32 open + 181 pending), matching the inbox-membership-filtered count exactly. No container restart needed — custom_filters are read live by the frontend via REST API.

**Backup:** `backups/20260505/custom_filters_pre_view_*.sql.gz`

**To add for a new manager later:**
```sql
INSERT INTO custom_filters (name, filter_type, query, account_id, user_id, created_at, updated_at)
SELECT '📋 كل النشطة (Open + Pending)', 0,
  '{"payload":[{"values":["open","pending"],"attribute_key":"status","query_operator":null,"attribute_model":"standard","filter_operator":"equal_to"}]}'::jsonb,
  1, u.id, NOW(), NOW()
FROM users u WHERE u.email = '<new-manager-email>';
```

### 2026-05-05 (later) — Multi-status filter patch (`status=open,pending`)
**Problem reported (continued):** After creating the Custom View `📋 كل النشطة`, رامي wanted the default `الكل` tab to natively show open+pending without needing a separate Folder click.

**Constraint discovered:** Chatwoot's `ConversationFinder#filter_by_status` only accepts a single status value (`open`, `pending`, `resolved`, `snoozed`, or `all`). It does not support multi-status. The `all` value bypasses status filtering entirely → also includes 365 resolved + 5 snoozed (584 total) — too noisy for managers.

**Solution: backend patch + per-user `ui_settings` update**

#### 1. Patch file: `patches/finders/conversation_finder.rb`
Modified `filter_by_status` to accept comma-separated status values:
```ruby
def filter_by_status
  return if params[:status] == 'all'
  status_param = params[:status] || DEFAULT_STATUS
  if status_param.is_a?(String) && status_param.include?(',')
    statuses = status_param.split(',').map(&:strip).reject(&:blank?)
    @conversations = @conversations.where(status: statuses)
  else
    @conversations = @conversations.where(status: status_param)
  end
end
```
- 100% backwards-compatible: single status (`open`, `pending`, etc.) still works exactly as before.
- New behavior: `status=open,pending` → `WHERE status IN ('open','pending')`.

#### 2. docker-compose.yml mounts (added to BOTH `chatwoot-web` and `chatwoot-sidekiq`)
```yaml
- ./patches/finders/conversation_finder.rb:/app/app/finders/conversation_finder.rb:ro
```

#### 3. Per-user UI default (the 6 managers)
```sql
UPDATE users
SET ui_settings = jsonb_set(
  COALESCE(ui_settings, '{}'::jsonb),
  '{conversations_filter_by}',
  COALESCE(ui_settings->'conversations_filter_by', '{}'::jsonb) || '{"status": "open,pending"}'::jsonb,
  true
)
WHERE email IN ('rami@qaydao.com','admin@qaydao.com','support@qaydao.com',
                'fay@qaydao.com','supervisor@qaydao.com','maali@qaydao.com');
```

**Verification (all passed):**
- Ruby syntax check: ✅ `ruby -c` on patched file = `Syntax OK`
- Rails console: `open=32`, `open,pending=213`, `open, pending (whitespace)=213`, `pending=181`, `all=583` ✅
- Live HTTPS API (rami's token): `open=33`, `open,pending=214`, `pending=181`, `all=584` ✅ (small drift from real-time traffic, expected)
- All 6 users verified to have `ui_settings.conversations_filter_by.status = "open,pending"` in DB.
- `fay@qaydao.com` (had complex pre-existing ui_settings) preserved all other settings — only status updated.

**Known UX caveats:**
- The status dropdown in `ConversationBasicFilter.vue` lists 5 options (open/pending/resolved/snoozed/all). The value `open,pending` is not in that list, so the dropdown's "selected" indicator may not visually highlight any option. Functionality is unaffected.
- If a manager clicks any other status from the dropdown (e.g. `open`), the frontend writes that single value back to `ui_settings`, **overwriting** the `open,pending` default. To restore: re-run the UPDATE SQL above (or that user can use the `📋 كل النشطة` Folder as fallback).
- This patch must be re-applied on every Chatwoot upgrade. The bind-mounted file at `patches/finders/conversation_finder.rb` is the source of truth.

**Backups:** `backups/20260505/conversation_finder_original_*.rb` + `docker-compose.yml.bak.*` + `users_pre_patch_*.sql.gz`

**Rollback procedure:**
```bash
# 1. Remove bind-mount lines from docker-compose.yml (delete the 2 conversation_finder.rb lines)
# 2. Restore ui_settings (clears the override; users go back to status='open' default)
docker exec chatwoot_postgres psql -U chatwoot_user -d chatwoot_production -c "
UPDATE users SET ui_settings = ui_settings #- '{conversations_filter_by,status}'
WHERE email IN ('rami@qaydao.com','admin@qaydao.com','support@qaydao.com',
                'fay@qaydao.com','supervisor@qaydao.com','maali@qaydao.com');"
# 3. Recreate containers
cd /root/chat-qaydao && docker compose up -d --force-recreate chatwoot-web chatwoot-sidekiq
```
