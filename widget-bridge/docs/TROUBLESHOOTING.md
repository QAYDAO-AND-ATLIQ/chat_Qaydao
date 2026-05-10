# Troubleshooting

Common issues and how to diagnose them.

## "redis_ok: false" in /health

**Symptoms:** `/health` returns `redis_ok: false`.

**Causes:**
1. Wrong REDIS_URL (missing password, wrong host alias)
2. Redis container down
3. Network not shared

**Fix:**
```bash
# Verify password
docker exec chatwoot_web env | grep REDIS_PASSWORD

# Verify hostname resolves
docker exec widget_bridge python3 -c "import socket; print(socket.gethostbyname('chatwoot-redis'))"

# Test ping with auth
docker exec chatwoot_redis redis-cli -a "PASSWORD" PING
```

## Chatwoot returns "301 Moved Permanently"

**Symptoms:** Webhook handler returns `fatal: Redirect response '301'...`.

**Cause:** Chatwoot enforces HTTPS internally. `http://chatwoot-web:3000` redirects to `https://chatwoot-web:3000` which has an invalid certificate.

**Fix:** Use the public URL in `.env`:
```bash
CHATWOOT_BASE_URL=https://chat.qaydao.com
```

This routes through your reverse proxy (Nginx/Traefik) with a valid cert.

## "Filter chain halted as :validate_hmac"

**Symptoms:** Chatwoot rejects `set_user` calls with HMAC error.

**Cause:** `hmac_mandatory: true` on the WebWidget channel, but Salla integration doesn't send `identifier_hash`.

**Fix:**
```ruby
docker exec chatwoot_web bundle exec rails runner '
  ch = Inbox.find(3).channel
  ch.update!(hmac_mandatory: false)
'
docker restart chatwoot_web   # IMPORTANT: clears AR cache
```

The container restart is critical — Rails caches the channel record in process memory.

## "زودنا بوسيلة للتواصل" (email collection) appears mid-conversation

**Cause:** Even with pre-chat form enabled, Chatwoot's `enable_email_collect` flag triggers a separate prompt when contact has no email.

**Fix:**
```ruby
docker exec chatwoot_web bundle exec rails runner '
  Inbox.find(3).update!(enable_email_collect: false)
'
```

## Template not found

**Symptoms:** `decision: error, reason: template_not_found:website_ooh_v1`.

**Causes:**
1. Template not synced from Meta into Chatwoot
2. Wrong language code
3. Template still PENDING in Meta

**Fix:**
```ruby
# Force sync
docker exec chatwoot_web bundle exec rails runner '
  Inbox.find(5).channel.sync_templates
'

# Check status
docker exec chatwoot_web bundle exec rails runner '
  tpl = Inbox.find(5).channel.message_templates
    .find { |t| t["name"] == "website_ooh_v1" && t["language"] == "ar" }
  puts tpl ? tpl["status"] : "NOT FOUND"
'
```

If `PENDING`, wait for Meta. If `REJECTED`, check Meta Business Manager for the rejection reason.

## Webhook not firing from Chatwoot

**Symptoms:** Real conversations created but no events in `/stats`.

**Diagnose:**
```bash
# 1. Confirm webhook exists
docker exec chatwoot_web bundle exec rails runner '
  Webhook.all.each { |w| puts "#{w.id}: #{w.url} #{w.subscriptions}" }
'

# 2. Test manual trigger from Sidekiq
docker exec chatwoot_sidekiq bundle exec rails runner '
  Webhooks::TriggerService.new(
    Webhook.find(1),
    Conversation.last.webhook_data,
    "conversation_created"
  ).perform
'

# 3. Verify network reachability
docker exec chatwoot_web sh -c '
  apt-get install -y curl 2>/dev/null
  curl -sv http://widget-bridge:8000/health
'
```

## Customer received OOH template inside business hours

**This should never happen.** If it did, check:

1. **Server timezone**: `date` should match Asia/Riyadh
2. **Container env**: `docker exec widget_bridge env | grep TIMEZONE`
3. **/health endpoint**: `business_hours` field should reflect current time
4. **Decision matrix**: Run the included `decision_matrix.py` test

If still wrong, file an issue with `/stats` output of the offending event.

## Same customer receives multiple OOH templates

**Cause:** Redis dedup not working.

**Diagnose:**
```bash
# Check the dedup key exists for that phone
docker exec chatwoot_redis redis-cli -a PASSWORD -n 3 \
  GET "widget_bridge:dedup:+966xxxxxxxxx"

# Check TTL
docker exec chatwoot_redis redis-cli -a PASSWORD -n 3 \
  TTL "widget_bridge:dedup:+966xxxxxxxxx"
```

If key is missing right after a send, Redis writes are failing — check `/health` for `redis_ok`.

## Container restarts in a loop

```bash
docker logs widget_bridge --tail 50
```

Common causes:
- Syntax error in code (didn't pass `python3 -c "import ast; ast.parse(open('main.py').read())"`)
- Wrong `.env` value (e.g., `CLOSED_DAYS=4` instead of `[4]`)
- Redis URL malformed
