# Architecture

A deep-dive into how the Widget Bridge intercepts webhooks and decides what to do.

## Component diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                         qaydao.com Storefront                        │
│                              ┌──────────┐                            │
│                              │  Widget  │ ← Visitor fills name+phone │
│                              └─────┬────┘                            │
└──────────────────────────────────────────────────────────────────────┘
                                     │ submit
                                     ▼
              ┌────────────────────────────────────────────┐
              │           Chatwoot (chat.qaydao.com)       │
              │  ┌────────────────────┐  ┌──────────────┐  │
              │  │ WebWidget Inbox #3 │  │ WhatsApp #5  │  │
              │  └─────────┬──────────┘  └──────▲───────┘  │
              │            │ conversation_       │         │
              │            │ created             │ template│
              │            ▼                     │ message │
              │       ┌──────────┐               │         │
              │       │ Sidekiq  │ ────POST───┐  │         │
              │       │ Webhook  │            │  │         │
              │       └──────────┘            ▼  │         │
              └───────────────────────────────────┼─────────┘
                                                 │
                              chatwoot_internal Docker network
                                                 │
                                       ┌─────────▼──────────┐
                                       │   widget_bridge     │
                                       │   (this project)    │
                                       │ ┌─────────────────┐ │
                                       │ │ FastAPI uvicorn │ │
                                       │ │ working_hours   │ │
                                       │ │ Chatwoot client │ │
                                       │ │ Redis dedup     │ │
                                       │ └─────────────────┘ │
                                       └──────────┬──────────┘
                                                  │
                                       ┌──────────▼──────────┐
                                       │  chatwoot_redis     │
                                       │  DB index 3 (dedup) │
                                       └─────────────────────┘
```

## Request lifecycle (out-of-hours flow)

1. **Customer submits widget form** → Chatwoot creates `Conversation` row + `Message` row
2. **`conversation_created` event fires** → Sidekiq picks it up
3. **Sidekiq HTTP POSTs to** `http://widget-bridge:8000/webhook/chatwoot/{secret}`
4. **Bridge validates** secret, parses payload
5. **Bridge filters**:
   - Is it `conversation_created`? → If not, return `skip`
   - Is `inbox_id == 3`? → If not, return `skip`
   - Does the contact have a phone? → Normalize; if invalid, return `skip`
6. **Bridge classifies** time → `business_hours` or not
7. **In-hours branch** → label conversation `from_website` and stop
8. **Out-of-hours branch**:
   - Redis `SETNX` on `widget_bridge:dedup:{phone}` with TTL 24h
   - If existed → `skip_dedup`
   - If newly set → continue
9. **Bridge fetches template** definition from Chatwoot's WhatsApp inbox config
10. **Bridge resolves contact** in WhatsApp inbox (or creates `contact_inbox` row)
11. **Bridge creates a new conversation** in WhatsApp inbox #5
12. **Bridge sends template message** via Chatwoot API → Chatwoot calls Meta WhatsApp Cloud API
13. **Bridge writes internal note** in the original widget conversation: *"📲 تم إرسال رسالة واتساب تلقائية للعميل…"*
14. **Bridge labels conversation** `after_hours`
15. **Bridge appends event** to in-memory rolling stats buffer (visible at `/stats`)

Total latency in production: **~700–800 ms** (most spent on Chatwoot API round-trips).

## Why "send via Chatwoot API" instead of "Meta directly"

Sending via Chatwoot has key advantages:
- 🔁 The reply lands back in **Chatwoot's WhatsApp inbox** automatically
- 👥 Same agents handle both widget chats and WhatsApp chats
- 📊 No data fragmentation — analytics, CSAT, reports all stay in Chatwoot
- 🎯 Token management is centralized — Chatwoot owns the WhatsApp API key

Going direct to Meta would require us to also build a webhook receiver to handle replies and manually mirror them back into Chatwoot — duplicating work Chatwoot already does correctly.

## Why FastAPI (not Flask, Django, raw http.server)

- **Async-first** — webhooks are I/O bound (we make multiple Chatwoot API calls per event)
- **Pydantic config** — validates env vars at boot
- **Built-in OpenAPI** — `/docs` for free
- **Tiny memory footprint** — ~80 MB total image, ~50 MB RSS

## Why a separate Redis DB index

The bridge uses Redis DB index `3` while Chatwoot uses `0`. This isolates dedup keys completely, avoids collisions with Chatwoot's own keys, and lets you `FLUSHDB` independently.
