# Deployment Guide

End-to-end production deployment on a fresh server.

## 0. Prerequisites checklist

- [ ] Chatwoot 4.x running on Docker
- [ ] Both `chatwoot_internal` Docker network exists and `chatwoot_redis` is on it
- [ ] WhatsApp Cloud API channel configured in Chatwoot
- [ ] At least one **APPROVED** UTILITY template (best to use `website_ooh_v1` recipe — see step 4)
- [ ] WebWidget inbox configured with a pre-chat form (recommended: name + phone, no email)
- [ ] Server has Python 3.12+, Docker, Docker Compose v2

## 1. Clone

```bash
cd /opt
git clone git@github.com:atmenai/chatwoot-widget-bridge.git
cd chatwoot-widget-bridge
```

## 2. Configure environment

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and fill in:

### Chatwoot section

```bash
# Get this by running:
docker exec chatwoot_web bundle exec rails runner '
  puts User.find_by(email: "you@example.com").access_token.token
'
```

### Redis section

Get Chatwoot's Redis password:
```bash
docker exec chatwoot_web env | grep REDIS_PASSWORD
```

Build the URL with database index `3`:
```
REDIS_URL=redis://:THE_PASSWORD@chatwoot-redis:6379/3
```

### Webhook secret

Generate a strong secret:
```bash
openssl rand -hex 32
```
Paste it into `WEBHOOK_SECRET=`.

### Behavior

Start with **`DRY_RUN=true`** for safety. Flip to `false` only after end-to-end test.

## 3. Build & launch

```bash
docker compose up -d --build
```

Verify:
```bash
docker run --rm --network chatwoot_internal curlimages/curl:latest \
  -s http://widget-bridge:8000/health | jq
```

Expected:
```json
{
  "status": "ok",
  "dry_run": true,
  "redis_ok": true,
  ...
}
```

## 4. (One-time) Create a Meta UTILITY template

Use the WhatsApp Business Manager UI, or via API:

```bash
WABA_ID=$(docker exec chatwoot_web bundle exec rails runner '
  puts Inbox.find(WHATSAPP_INBOX_ID).channel.provider_config["business_account_id"]
')
TOKEN=$(docker exec chatwoot_web bundle exec rails runner '
  puts Inbox.find(WHATSAPP_INBOX_ID).channel.provider_config["api_key"]
')

cat > /tmp/template.json <<JSON
{
  "name": "website_ooh_v1",
  "language": "ar",
  "category": "UTILITY",
  "components": [
    {"type":"HEADER","format":"TEXT","text":"شكراً لتواصلك"},
    {"type":"BODY","text":"مرحباً {{1}} 👋\\nوصلتنا رسالتك...","example":{"body_text":[["أحمد"]]}},
    {"type":"FOOTER","text":"اسم الشركة"}
  ]
}
JSON

curl -s -X POST "https://graph.facebook.com/v21.0/${WABA_ID}/message_templates" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/template.json
```

Wait 1–24 hours for Meta approval. Then sync into Chatwoot:

```bash
docker exec chatwoot_web bundle exec rails runner '
  Inbox.find(WHATSAPP_INBOX_ID).channel.sync_templates
'
```

## 5. Register the webhook in Chatwoot

```bash
SECRET=$(grep ^WEBHOOK_SECRET /opt/chatwoot-widget-bridge/.env | cut -d= -f2)

docker exec chatwoot_web bundle exec rails runner "
  Webhook.where(account_id: 1).where(\"url LIKE 'http://widget-bridge%'\").destroy_all
  Webhook.create!(
    account_id: 1,
    url: 'http://widget-bridge:8000/webhook/chatwoot/${SECRET}',
    subscriptions: ['conversation_created'],
    inbox_id: 3
  )
"
```

## 6. End-to-end test (still DRY_RUN)

Submit a real test through the WebWidget on your site. Then check:

```bash
docker run --rm --network chatwoot_internal curlimages/curl:latest \
  -s "http://widget-bridge:8000/stats?limit=5" | jq '.events'
```

You should see your event with `decision: would_send_dry_run` (if outside hours) or `in_hours_no_send` (if inside).

## 7. Go live

Once confident:

```bash
sed -i 's/^DRY_RUN=.*/DRY_RUN=false/' .env
docker compose up -d --force-recreate
```

Verify:
```bash
curl -s http://widget-bridge:8000/health | jq '.dry_run'
# → false
```

## 8. Set up monitoring (recommended)

Tail logs to your aggregator (Papertrail / Datadog / Loki):

```yaml
# In docker-compose.yml
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "5"
```

Or pipe to syslog:
```yaml
logging:
  driver: syslog
  options:
    syslog-address: "udp://your-log-server:514"
    tag: widget_bridge
```

## Rollback

```bash
docker compose down
sed -i 's/^DRY_RUN=.*/DRY_RUN=true/' .env
docker compose up -d
```

To fully remove:

```bash
docker compose down -v
docker exec chatwoot_web bundle exec rails runner '
  Webhook.where("url LIKE \"http://widget-bridge%\"").destroy_all
'
```
