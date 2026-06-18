# Runbook — Chatwoot real-time messages not appearing (ActionCable fan-out)

## Symptom
Agents on `https://chat.qaydao.com` do **not** see new messages live; they only
appear after a **manual page refresh**. This makes reply time look much worse
than reality (e.g. "12 minutes late" when the message was never shown live).

## Root cause
Chatwoot delivers live updates as:

```
new message → Sidekiq runs ActionCableBroadcastJob (queue: critical)
            → ActionCable.server.broadcast → PUBLISH to Redis pub/sub channel
            → chatwoot_web's ActionCable SUBSCRIBER receives it
            → pushes down each browser's WebSocket
```

If `chatwoot_web` loses its **Redis pub/sub subscriber** connection (typically
after `chatwoot_redis` is restarted/recreated while `chatwoot_web` keeps
running), broadcasts are PUBLISHed to Redis with **no subscriber listening** →
they are silently dropped → browsers never get the update.

WebSocket upgrade itself keeps working (Traefik is fine), which is why the
problem is easy to misdiagnose as a proxy issue.

## Diagnose
```bash
PW=$(docker exec chatwoot_web printenv REDIS_PASSWORD)
R(){ docker exec chatwoot_redis redis-cli -a "$PW" --no-auth-warning "$@"; }

# Healthy: >0 channels AND a client with sub>0 named ActionCable-PID-*
R PUBSUB CHANNELS 'chatwoot_production_action_cable:*' | wc -l
R CLIENT LIST | grep -vE 'sub=0 psub=0 ssub=0'

# Broken signature: many WS upgrades in logs but the two checks above return 0
docker logs chatwoot_web --since 5m 2>&1 | grep -c 'Successfully upgraded to WebSocket'
```

## Fix (manual)
```bash
docker restart chatwoot_web        # ~10–30s; clients auto-reconnect
```
Verify after ~30s: `R PUBSUB CHANNELS 'chatwoot_production_action_cable:*'`
returns >0 and `R CLIENT LIST` shows `name=ActionCable-PID-* ... sub=N (>0)`.
Final confirm: send a test message from the web widget → it appears in the
agent dashboard **without** refreshing.

## Prevention (automated)
`scripts/chatwoot_cable_watchdog.sh` runs every minute (see
`scripts/crontab.snippet`). It restarts `chatwoot_web` automatically **only**
when there is live WS traffic but zero cable subscribers, with a 2-strike
confirmation + 10-minute cooldown, and does nothing if Redis/web can't be read.
Log: `/var/log/chatwoot_cable_watchdog.log`.

## Related / open item
Mailer noise: `ConversationReplyMailer` fails with `StandardError: Channel email
domain not present` for web/WhatsApp inboxes that have "conversation continuity
via email" enabled without a configured sending domain. Harmless to customers
(they are on web/WhatsApp) but it pollutes the Sidekiq dead set. Root fix:
disable continuity-via-email on those inboxes, or configure the inbound email
domain. SMTP itself (Mailjet) is healthy — agent notification email works.
