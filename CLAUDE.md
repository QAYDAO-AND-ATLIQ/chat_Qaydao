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
