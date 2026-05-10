# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-05-10

### 🎉 Initial Production Release

The first stable release. Used in production at QAYDAO (qaydao.com) to recover
after-hours website leads via WhatsApp.

### Added
- **Async webhook processing** — FastAPI app with `/webhook/chatwoot/{secret}` endpoint
- **Working hours engine** — `is_business_hours()` for Asia/Riyadh, Sat–Thu 9am–midnight, Friday closed
- **Redis-based 24h dedup** — same phone number can't receive two pushes in a day
- **Chatwoot async API client** — wraps contact search, contact_inbox creation, conversation creation, template message send, internal note, label add
- **WhatsApp template renderer** — substitutes `{{1}}` with sanitized first name
- **Title prefix parser** — handles Arabic (`م.`, `د.`, `أ.`) and English (`Eng.`, `Dr.`, `Mr.`) titles
- **Saudi phone normalizer** — accepts `+966`, `966`, `05X…`, `5X…` formats
- **DRY_RUN mode** — defaults to true; logs decisions without sending real messages
- **Stats endpoint** — rolling buffer of last 200 events for debugging
- **Healthcheck endpoint** — liveness + Redis connectivity status
- **Internal note generator** — leaves a record in the original widget conversation for the morning team
- **Inbox filter** — strict, only processes events from configured `WIDGET_INBOX_ID`
- **Resource caps** — Docker compose limits container to 256 MB RAM / 0.5 CPU
- **Auto healthcheck** — Docker restarts container if /health fails 3 times

### Security
- **Webhook secret in URL path** — 64-byte hex, embedded in `/webhook/chatwoot/{secret}`
- **Header-based alternative** — `X-Webhook-Secret` header for manual curl tests
- **Internal Docker network only** — `chatwoot_internal`, never exposed to public internet
- **`.env` excluded from version control** — strict `.gitignore`
- **`.env.example` provided** — onboarding-friendly template with no secrets

### Documentation
- Bilingual README (Arabic & English) with Mermaid architecture diagram
- Architecture deep-dive
- Deployment guide
- Troubleshooting guide
- Security threat model

[1.0.0]: https://github.com/atmenai/chatwoot-widget-bridge/releases/tag/v1.0.0
