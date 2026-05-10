# Security

## Threat model

The bridge sits in the path between Chatwoot and customers' WhatsApp inboxes. The risks we defend against:

| Risk | Impact | Mitigation |
|---|---|---|
| Unauthorized webhook calls trigger real WhatsApp sends | Spam, financial cost, regulatory | URL secret + internal-only network |
| Same customer spammed in a loop | Customer complaints, Meta penalty | Redis 24h dedup |
| Logic bug sends in-hours messages | Bad UX, brand damage | Hard-coded `return` before send call when in-hours |
| Misconfigured template name | Customers receive wrong content | Template fetched & validated before send |
| Missing/invalid phone numbers | Failed sends, error noise | Strict normalizer rejects invalid input |
| Redis outage causes runaway sends | Mass duplication | Fail-open allows send (single duplicate worse than mass loss) |
| Container compromise | API token exposure | Read-only mounts, minimal image, capped resources |
| Secrets in version control | Token leak | `.gitignore` + `.env.example` separation |

## Defense layers (in order of execution)

1. **Network isolation** — bridge only listens on the `chatwoot_internal` Docker network
2. **Webhook secret** — 64-byte hex token in URL path, validated before payload parse
3. **Event filter** — only `conversation_created` accepted
4. **Inbox filter** — only configured `WIDGET_INBOX_ID` accepted
5. **Phone validation** — strict normalizer drops bad input
6. **Time-of-day guard** — `is_business_hours()` short-circuits the function
7. **Dedup window** — Redis SETNX with 24h TTL
8. **Template existence check** — fetched from Chatwoot before send attempt
9. **Per-call try/except** — never crashes the process
10. **Error logging** — all failures recorded in `/stats`

## What an attacker would need

To trigger a real WhatsApp send via this bridge, an attacker needs **all** of:

- Network access to the `chatwoot_internal` Docker network (i.e., compromised the Docker host)
- The 64-byte webhook secret (only stored in `/opt/chatwoot-widget-bridge/.env`, mode 0600)
- A phone number not already in the dedup window
- The current time to be outside business hours
- A valid `conversation_created` payload structure

This is essentially equivalent to "they already own the server."

## Secret rotation

```bash
# 1. Generate new secret
NEW=$(openssl rand -hex 32)

# 2. Update .env
sed -i "s/^WEBHOOK_SECRET=.*/WEBHOOK_SECRET=${NEW}/" .env

# 3. Restart bridge
docker compose up -d --force-recreate

# 4. Update Chatwoot webhook URL
docker exec chatwoot_web bundle exec rails runner "
  w = Webhook.find_by('url LIKE \"http://widget-bridge%\"')
  w.update!(url: 'http://widget-bridge:8000/webhook/chatwoot/${NEW}')
"
```

## API token rotation

The bridge uses a Chatwoot user API token (`CHATWOOT_API_TOKEN`). To rotate:

1. Create a new user (or new token) in Chatwoot UI: Profile → Settings → Reset Token
2. Update `.env`
3. `docker compose up -d --force-recreate`

Use a **dedicated bot user** (e.g., `bridge@qaydao.com`) rather than a real human account. This limits blast radius and makes audit trails clearer.

## Logs do NOT contain secrets

The bridge's logs include phone numbers and conversation IDs but never:
- API tokens
- Webhook secrets
- Redis passwords
- Customer email addresses (we don't collect them)

Phone numbers are PII — secure the log destination accordingly.

## Reporting vulnerabilities

Email security@qaydao.com (or open a private issue if applicable). Please do not file public issues for security bugs.
