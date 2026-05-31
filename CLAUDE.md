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
- `patches/enterprise/app/services/captain/llm/system_prompts_service.rb` — bind-mounted (ro) into both web+sidekiq. Patches the Captain `[Task]` line so the assistant greets the customer by their first name (from `[Contact Information]`). **Re-apply/re-check on every Chatwoot upgrade** (upstream may change this file).
- `patches/enterprise/app/services/captain/assistant/agent_runner_service.rb` — bind-mounted (ro) into web+sidekiq. (1) Lowers runner `max_turns` 100→15 so tool-call loops fail fast instead of burning 100 turns. (2) In `process_agent_result`, suppresses internal runner failure text (e.g. "Exceeded maximum turns", "Conversation ended:") and returns `conversation_handoff` so the customer never sees internal status messages. **Re-apply/re-check on every Chatwoot upgrade.**
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

### 2026-05-31 (later 2) — Disable out-of-office on AI inboxes + unify working hours
- Disabled `working_hours_enabled` on inboxes 3 (WebWidget), 5 (WhatsApp), 6 (Instagram) so the
  out-of-office template no longer fires — QAYDAO AI answers 24/7. (DB config; no seed manages it.
  Email inbox 2 left as-is.) To re-enable later: set working_hours_enabled=true on those inboxes.
- Unified human-support hours everywhere in seed_captain.rb to **Sat-Thu 9am-12** (weekly off: Friday),
  matching the live working_hours config. Previously the instruction wrongly said Sun-Thu 9am-6pm.
- Handoff (Scenario #4) now says "forwarded your message to the team + working hours"; the AI also
  clarifies forwarded+hours if the customer is confused after a handoff.

### 2026-05-31 (later 3) — Daily CS digest email (replace per-event email flood)
- Disabled per-event Chatwoot email notifications (`notification_settings.email_flags=0`) for the CS
  team: fay, marwa, amira, omar (admin/supervisor/support unchanged). Stops the email flood.
- Added `monitoring/daily_cs_digest.py`: one aggregated Arabic-RTL HTML email each morning summarizing
  the last 24h (new/resolved/open/pending, handoffs, in/out message counts) and — most importantly —
  the list of conversations waiting on the team (customer sent the last message) with direct links.
  Sends via Mailjet SMTP read at runtime from `.env` (no secrets in the script). Default recipients =
  the 4 CS agents above.
- Cron: `0 5 * * *` (08:00 Asia/Riyadh) -> logs to `monitoring/cs_digest.log`. First run: next morning.
- To change recipients: edit DEFAULT_TO in the script or run with `--to a@b,c@d`. `--test EMAIL` previews to one address.

## Change Log

### 2026-05-31 (later) — Stop internal-status leaks + tool-loop cascade
**Symptom (WhatsApp):** customer sent a fake order number; got "Conversation ended: Exceeded maximum turns: 100" sent to them, then ~1h later an unsolicited "outside working hours" greeting (no new customer message).
**Root cause:** track API returned 404 for unknown orders -> Captain HttpTool error -> runner retried tools up to `max_turns: 100` -> the runner's failure string was sent to the customer; the failed job later retried, produced a handoff, reopened the conversation, and reopening outside business hours fired the inbox out-of-office greeting.
**Fixes:** (1) track returns 200+success:false (see tark-Qaydao). (2) Vendored patch `agent_runner_service.rb`: `max_turns` 100→15 + suppress internal failure text -> graceful `conversation_handoff`. (3) Instruction-injection fix (earlier today) makes the AI escalate/answer instead of looping.
**Note:** the out-of-office greeting on the WhatsApp inbox still fires for genuine out-of-hours NEW conversations; since QAYDAO AI answers 24/7, consider disabling it on the AI inboxes (open decision).

### 2026-05-31 — Warehouse stock answers + AI quality + post-Eid cleanup
**What:** QAYDAO AI can now answer real stock/availability and reply professionally.
- **Stock tools:** added Captain custom tools `check_warehouse_stock` (→ cn.qaydao.com `/api/warehouse/public-availability` & `/public-search`) and `lookup_salla_product` (→ products `/api/links/stock-by-salla`, extracts `salla_id` from a product link). Customer gives a code/link/image-code → AI checks the real warehouse → "available, ships 3-7d" or "made-to-order 30-60d", and suggests in-stock alternatives. Images: Captain pipeline already forwards image attachments to gpt-4.1; instruction now reads codes / describes products from images.
- **Product↔warehouse link:** new `product_warehouse_link` table in `qaydao_master` (70 auto-seeded by sku==code) + link API + linking UI in cn.qaydao.com `dashboard/warehouse` (for the ~247 codes whose sku≠warehouse code). `qaydao-products` `search_products` now sets `delivery_class` from REAL stock for linked products (safe fallback to heuristic if cn unreachable).
- **🔴 Root bug fixed:** the Captain prompt template injects `config["instructions"]` (PLURAL) but the assistant stored `config["instruction"]` (SINGULAR) — so the entire custom instruction was NEVER reaching the LLM (prompt was ~3976 chars, none of our rules present). `seed_captain.rb` now sets BOTH keys → instruction is live (prompt ~12k chars). All custom rules (conciseness, escalation, stock, image, name) only started working after this fix.
- **AI quality:** instruction rewritten for brevity (2-3 sentences, no filler), escalate-to-human on ambiguity/unfulfillable requests (e.g. "see fabric up close") with a short offer, and address the customer by first name.
- **Name greeting:** enabled `feature_contact_attributes`; instruction alone was insufficient (upstream `[Task] Start by introducing yourself` suppressed it), so vendored-patched `system_prompts_service.rb` `[Task]` to greet by first name. Verified 4/4 → "أهلاً أبرار،...".
- **Post-Eid cleanup:** removed the stale Eid-holiday block from `seed_captain.rb` (instruction + Scenario#2 not-found [trigger phrase kept] + working-hours + Scenario#4 handoff) and removed the `holiday-escalation` cron line. (Completes the 2026-05-27 POST-EID TODO.)

**Verify:** `apply.sh`; Playground/WhatsApp send `15FKNZ063` → "متوفر، ٣-٧ أيام"; send a product link → made-to-order + alternatives; named contact → greeted by name.
**Backups:** `seed_captain.rb.bak-*`, `docker-compose.yml.bak-sps-*`, products `server.js.bak-*`, cn `warehouse.py.bak-*`.


### 2026-05-27 — Eid holiday: AI honesty + urgent escalation
**Problem:** During Eid (human team away until Sat 30 May), QAYDAO AI handed off human-only matters (refund/return/delay/B2B) promising "سيتواصل معك مختص قريباً / في أقرب وقت" while no human was available — customers waited 10h–34h. Scenario #4 also said "بعد التحويل لا ترد" → silence.

**Root cause:** The false-promise text lived in `captain-config/scripts/seed_captain.rb` Scenario #2 (order-not-found) & #4 (handoff), NOT the main instruction. Also `apply.sh` (6-hourly self-heal) was failing silently (`set -u` unbound var) so config never self-healed.

**Changes (all in source-of-truth → cron-proof):**
- `seed_captain.rb`: prepended a HOLIDAY block to `canonical_instruction`; rewrote Scenario #2 not-found message (KEPT trigger phrase "تم رفع طلبك لخدمة العملاء للمراجعة" needed by automation rule #6) and Scenario #4 handoff message to honest "الفريق يعود السبت ٣٠ مايو" with no "قريباً"; replaced Scenario #4 "do not reply" rule with "keep helping".
- `apply.sh`: fixed unbound-variable bug (split prefix assignment from command) — self-heal restored & verified end-to-end.
- inbox 2 (email) `working_hours` mirrored to inbox 5 (closed Tue–Fri, open Sun/Mon/Sat) so the Eid OOO fires consistently on email too.
- NEW `monitoring/holiday_escalation.py` + cron every 10 min: alerts Rami (Telegram @qaydaochatbot + Email via alert_rami.py) for any OPEN conversation where the customer has waited > 45 min; dedup via `holiday_escalated.json`; SELF-EXPIRES on 2026-05-30.
- One-time honest reassurance message sent to 7 stuck open conversations (msg ids 45527–45533); tracked in `holiday_reassured.json`.

**⚠ POST-EID TODO (after Sat 30 May 2026):** the HOLIDAY block does NOT auto-remove. Remove it from `seed_captain.rb` (3 spots marked with "إجازة العيد") + run `apply.sh`; remove the `holiday-escalation` cron line.


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

### 2026-05-05 (final) — Team-based auto-assignment (managers excluded from round-robin)
**Problem reported:** New WhatsApp conversations were being auto-assigned to managers (e.g. Fai got Ghazala Ghyas conversation #118 on May 5, 10:07 AM Riyadh after customer reopened it). This polluted manager workload metrics and skewed daily reports. Managers should see all conversations (visibility, achieved earlier today via filter patch + custom views) but not receive auto-assignments.

**Root cause analysis (code dive into ConversationFinder, AutoAssignmentHandler, AssignmentService):**
1. Inbox 5 (and 2/3/6) has `enable_auto_assignment=true` with auto_assignment_v2_enabled=true.
2. Round-robin uses `inbox.member_ids_with_assignment_capacity` — returns ALL online inbox_members (including managers).
3. `auto_assignment_handler.rb` re-runs assignment when conversation status changes to `open` (i.e., on reopen).
4. The system DOES respect `conversation.team_id` if set: `filter_agents_by_team` intersects with team members → effectively excludes managers if they're not in the team.

**Solution: 3-part change**

#### 1. Cleaned team 2 (الدعم الفني)
Removed admin (id=2), Fai (id=8), maali (id=11). Kept only: شيماء (id=5) + مروة (id=6).
```sql
DELETE FROM team_members WHERE team_id = 2 AND user_id IN (2, 8, 11);
```

#### 2. Created 4 automation rules (one per inbox)
All have `event_name='conversation_created'`, condition on inbox_id, action `assign_team` to team 2.

| Rule ID | Inbox | Channel |
|---------|-------|---------|
| 2 | 2 | Email (QAYDAO بريد) |
| 3 | 3 | WebWidget |
| 4 | 5 | WhatsApp |
| 5 | 6 | Instagram |

Created via Rails to ensure validation. JSON structure:
```ruby
conditions: [{"attribute_key" => "inbox_id", "filter_operator" => "equal_to", "values" => [N], "query_operator" => nil}]
actions: [{"action_name" => "assign_team", "action_params" => [2]}]
```

#### 3. Backfilled team_id=2 on 150 existing open+pending conversations
Without this, reopening any of the 181 currently-open conversations would still trigger old behavior (round-robin to managers). Backfill ensures team_id persists so reopens route correctly.
```sql
UPDATE conversations SET team_id = 2
WHERE account_id = 1 AND inbox_id IN (2,3,5,6) AND status IN (0,2) AND team_id IS NULL;
-- 150 rows updated
```

**Verification (passed):**
- `inbox.available_agents` (no team filter): 2 agents (شيماء + Fai online now)
- After `filter_agents_by_team` (with team_id=2): **1 agent** (شيماء only — Fai filtered out, مروة offline)
- Without team_id: 2 agents including Fai (the broken behavior — proves the fix is necessary)

**Behavior going forward:**
- New WhatsApp/Web/Email/Instagram conversation → `conversation_created` event → automation rule fires → team_id=2 set → assignment service round-robins between شيماء/مروة only.
- Managers (rami, supervisor, admin, support, Fai, maali) remain inbox_members → can see all conversations (custom view + status patch from earlier today) → never auto-assigned.
- Fai/managers can still MANUALLY take a conversation if needed (clicking assign-to-self).
- Reopens of existing 150 backfilled conversations → also route to team 2.
- The 1 conversation already on team 4 (الشحن) untouched.

**Edge cases not handled (intentional):**
- Currently-assigned-to-managers conversations: NOT reassigned. Disrupting active customer chats is worse than the metric pollution. Will resolve naturally as conversations close.
- Team 2 (الدعم الفني) name is misleading now (it does general customer service, not just technical). Consider renaming later if confusing.

**Backups:** `backups/20260505/teams_automation_pre_*.sql.gz`

**Rollback:**
```sql
-- 1. Delete automation rules
DELETE FROM automation_rules WHERE id IN (2,3,4,5);
-- 2. Restore team members
INSERT INTO team_members (team_id, user_id, created_at, updated_at) VALUES
  (2, 2, NOW(), NOW()), (2, 8, NOW(), NOW()), (2, 11, NOW(), NOW());
-- 3. Clear backfilled team_id (only the ones we set)
-- WARNING: this also clears any other team_id=2 set since 2026-05-05. Use with care.
```

### 2026-05-05 (final 2) — Cron-based unassigned recovery + Fai fallback
**Problem:** After implementing team-based assignment, a new gap appeared: if both شيماء AND مروة are offline when a customer messages during working hours, the conversation stays `assignee_id = NULL` forever. Chatwoot's auto-assignment only re-runs on conversation status changes, never on agent online/offline transitions.

**Solution:** Custom cron job that runs every 5 minutes with priority logic:
1. **Step 1 — Primary:** Call existing `AutoAssignment::AssignmentJob` for each target inbox. This uses the team-based assignment we set up earlier (شيماء + مروة via team 2).
2. **Step 2 — Fallback:** If primary team is **fully offline** AND Fai is online → assign all remaining unassigned conversations to Fai. This is intentional for QAYDAO: Fai is the customer service department head, so falling back to her is acceptable.
3. **Step 3 — None:** If Fai is also offline → leave unassigned (visible in "غير معيّن" tab + managers' "الكل" view).

**Why custom job (not Chatwoot's built-in `PeriodicAssignmentJob`):**
- Built-in job filters via `inbox.joins(:assignment_policy)` — our inboxes have no `assignment_policy` so it skips them entirely.
- Built-in runs every 30 minutes; ours runs every 5 (faster recovery).
- Built-in has no fallback concept; we need Fai-as-last-resort.

**Files added (bind-mounted, like other patches):**
- `patches/jobs/qaydao_retry_unassigned_conversations_job.rb` — the job class with 4 sceanrio handling
- `patches/initializers/qaydao_cron_jobs.rb` — registers the schedule via `Sidekiq::Cron::Job.create`

**Schedule:** `*/5 * * * *` (every 5 minutes) on `scheduled_jobs` queue.

**Configuration constants in job (to update if team changes):**
```ruby
TARGET_INBOX_IDS  = [2, 3, 5, 6]    # Email, WebWidget, WhatsApp, Instagram
PRIMARY_TEAM_ID   = 2                # الدعم الفني (شيماء + مروة)
FALLBACK_EMAILS   = %w[fay@qaydao.com]  # ordered by priority (extend list to add more)
```

**Verification (all passed):**
- Ruby syntax: ✅ both files
- Cron registered in Sidekiq: ✅ `qaydao_retry_unassigned_conversations` listed alongside core jobs
- Idempotent on empty input: ✅ ran cleanly with 0 unassigned conversations
- Fallback decision logic (4 scenarios via Rails console):
  - شيماء online → SKIP fallback ✅
  - Team offline + Fai online → returns Fai ✅
  - Everyone offline → returns nil ✅
  - rami online (not in FALLBACK_EMAILS) → returns nil ✅
- End-to-end transaction-wrapped test: created unassigned conversation → ran job → ✅ assigned to شيماء (correct, since she's online); transaction rolled back (no permanent changes).

**Behavior matrix:**
| شيماء | مروة | Fai | Result |
|-------|------|-----|--------|
| 🟢 | any | any | round-robin between online team members |
| 🔴 | 🟢 | any | round-robin to مروة |
| 🔴 | 🔴 | 🟢 | **fallback to Fai** (NEW) |
| 🔴 | 🔴 | 🔴 | unassigned, retried in 5 min |

**Operational notes:**
- Max delay for unassigned conversation pickup: 5 minutes (next cron tick).
- The job is safe to re-run (idempotent) — if conversation already assigned, no action.
- Fai's assignments via fallback can be distinguished from her direct picks via the conversation `assignee_last_seen_at` and Sidekiq logs (search for `[QAYDAO Fallback]`).
- To add more fallback candidates (e.g., maali if Fai is also offline): append email to `FALLBACK_EMAILS` array.
- To temporarily disable: `Sidekiq::Cron::Job.find('qaydao_retry_unassigned_conversations').disable!`

**Rollback:**
```bash
# 1. Remove bind-mount lines from docker-compose.yml (the 2 lines ending in ...job.rb and qaydao_cron_jobs.rb)
# 2. Recreate containers — initializer won't load → cron job auto-deleted on next deploy cycle
cd /root/chat-qaydao && docker compose up -d --force-recreate chatwoot-web chatwoot-sidekiq
# 3. Manually clean up Redis cron entry (if needed):
docker exec chatwoot_sidekiq bundle exec rails runner "Sidekiq::Cron::Job.destroy('qaydao_retry_unassigned_conversations')"
```
