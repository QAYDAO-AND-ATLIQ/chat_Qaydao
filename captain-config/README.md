# QAYDAO Captain AI — Configuration Source of Truth

This folder contains the **canonical, idempotent configuration** for QAYDAO AI (the customer-facing Captain assistant on chat.qaydao.com).

## What's here

```
captain-config/
├── README.md                       ← you are here
└── scripts/
    ├── seed_captain.rb            ← canonical config (the source of truth)
    └── apply.sh                   ← runner: copies + executes seed in container
```

## Purpose

Every change made to Captain (instructions, tools, scenarios, inbox bindings, pricing plan, automation rules) is persisted **in code** here — not just in the database. This guarantees:

1. **Survives restarts and migrations** — if anything is reset, run `apply.sh` to restore.
2. **Versioned in Git** — every change is traceable.
3. **Reproducible** — same config can be applied to a fresh Chatwoot instance.
4. **Idempotent** — running twice produces the same result, no duplicates.

## What gets configured (9 steps)

| # | Step | What it does |
|---|------|--------------|
| 1 | Pricing plan | Sets `INSTALLATION_PRICING_PLAN=enterprise` + clears Redis cache (unlocks UI paywall) |
| 2 | Feature flags | Enables `captain_integration` + `captain_integration_v2` + `help_center` + `captain_tasks` |
| 3 | Assistant instruction | Sets canonical Arabic system prompt for QAYDAO AI |
| 4 | Custom tools | Creates `search_products` + `track_order` with `url_encode` filter |
| 5 | Scenarios | Creates 4 V2 scenarios: products, tracking, policies, human-handoff |
| 6 | Inbox bindings | Binds Captain to all 4 customer inboxes (WebWidget, Email, WhatsApp, Instagram) |
| 7 | FAQ embeddings | Regenerates missing embeddings (FAQs without embeddings are invisible to Captain) |
| 8 | Automation rule #3 | Ensures `event_name='conversation_opened'` (NOT `conversation_created` — Captain must fire first) |
| 9 | Auto-resolve | Ensures `auto_resolve_duration=NULL` (disabled) |

## How to apply

### Manual run (after any change to `seed_captain.rb`):
```bash
/root/chat-qaydao/captain-config/scripts/apply.sh
```

### Verify it worked:
```bash
cd /root/chat-qaydao/monitoring && python3 monitor.py
# Expected: all 11 checks ✓
```

### Test Captain replies:
1. Open https://chat.qaydao.com
2. Sidebar: القائد → Playground
3. Try: "عندكم طاولات طعام؟" — should return 5 products with prices & links
4. Try: "أين طلبي رقم 260746244" — should use `track_order` tool
5. Try: "متى أوقات العمل؟" — should answer with FAQ lookup

## Critical rules

- ❌ **Never edit Captain config directly in the database without updating this script.**
  If you do, your changes will be lost the next time someone runs `apply.sh`.
- ✅ **Always edit `seed_captain.rb` first**, commit to git, then run `apply.sh`.
- ✅ **Every change is committed** — the script lives in `atmenai/chat_Qaydao` on GitHub.

## How the monitor protects this config

The system monitor (`/root/chat-qaydao/monitoring/monitor.py`) runs **every 5 minutes** via cron and checks 11 conditions including:

- `captain_config`: OpenAI API key in DB
- `captain_features`: V1 + V2 enabled
- `captain_inbox_binding`: Widget inbox linked to Captain
- `rule_event_correct`: rule #3 event is `conversation_opened`
- `pricing_plan`: plan is `enterprise` (not community)
- `auto_resolve`: disabled

If any check fails, an alert appears in **inbox 7 (🚨 تنبيهات النظام)** in Chatwoot UI with the exact fix command.

## Control panels (where to edit content from dashboard)

| Setting | URL | What you can change |
|---------|-----|---------------------|
| FAQs (47) | https://chat.qaydao.com → القائد → FAQs | Add/edit/delete Q&A pairs |
| Documents (6) | https://chat.qaydao.com → القائد → Documents | Upload policy docs |
| Scenarios (4) | https://chat.qaydao.com → القائد → Scenarios | Edit scenario instructions |
| Tools | https://chat.qaydao.com → القائد → Tools | View custom tools (search/track) |
| Assistant config | https://chat.qaydao.com → القائد → Settings | Edit base instruction |
| Backup admin panel | https://chat.qaydao.com/products/login (pw: `qaydao2026`) | FAQs + Docs + Tools + Instructions |

> Changes made in the UI are stored in the database but **not in code**. Periodically sync them back to `seed_captain.rb` by exporting them.

## Change log

| Date | What changed | By |
|------|-------------|------|
| 2026-05-21 | Initial seed: 4 scenarios + 2 tools + 4 inbox bindings + 47 FAQ embeddings | Claude (Rami's CTO assistant) |

---
For broader Chatwoot operations, see `/root/chat-qaydao/CLAUDE.md`.
