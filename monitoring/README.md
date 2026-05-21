# QAYDAO Chat — Monitoring System

## Purpose
Detect and alert on outages that cause customer loss:
- `widget_bridge` down → WhatsApp not sent to website visitors after hours
- Captain AI broken → QAYDAO AI not responding to customers
- Auto-resolve re-enabled → tickets closing prematurely
- WhatsApp inbox disconnected → no outbound messages working
- Silence during peak hours → website chat possibly broken
- Sustained errors → systemic issue

## Architecture
```
cron */5 * * * *
    │
    ▼
monitor.py  ────► 7 checks (container, health, captain, autoresolve, errors, silence, runtime)
    │                │
    │                ├─ All OK → exit 0, send any RECOVERY messages
    │                │
    │                └─ Any FAIL → check Redis dedup → send WhatsApp alert via Chatwoot
    ▼
active_alerts.json  (state for recovery detection)
/var/log/widget-bridge-monitor.log
```

## Files
- `config.py` — all thresholds + destination phone + Chatwoot creds (uses ENV vars)
- `monitor.py` — main script, run by cron
- `alert_sender.py` — sends WhatsApp via Chatwoot WhatsApp Cloud channel (inbox 5)
- `active_alerts.json` — auto-generated, tracks currently-active alerts for recovery messages
- `README.md` — this file

## One-time setup

### 1. Set destination phone
```bash
# Recommended: via systemd env file (more secure than editing config.py)
cat > /etc/default/qaydao-monitor <<EOF
ALERT_DEST_PHONE=966XXXXXXXXX   # rami's personal whatsapp, E.164 no +
CHATWOOT_API_TOKEN=<paste user token from chatwoot profile>
EOF
chmod 600 /etc/default/qaydao-monitor
```

### 2. Verify Python deps
```bash
python3 -c "import redis, urllib.request, zoneinfo, subprocess" && echo "deps OK"
# If redis missing:
pip3 install --break-system-packages redis
```

### 3. Get Chatwoot API token
- Login to chat.qaydao.com as rami → Profile → Access Token → copy
- Paste in /etc/default/qaydao-monitor (CHATWOOT_API_TOKEN)

### 4. Dry-run test (no alerts sent)
```bash
cd /root/chat-qaydao/monitoring
set -a; . /etc/default/qaydao-monitor; set +a
MONITOR_DRY_RUN=true python3 monitor.py
# Expect: all checks pass (✓), exit 0
```

### 5. Live test (sends a real alert)
```bash
# Temporarily break something safe: stop widget_bridge briefly
docker stop widget_bridge
set -a; . /etc/default/qaydao-monitor; set +a
python3 monitor.py    # should send alert
docker start widget_bridge
sleep 30
python3 monitor.py    # should send recovery
```

### 6. Install cron
```bash
# Add to root crontab
(crontab -l 2>/dev/null; echo "*/5 * * * * cd /root/chat-qaydao/monitoring && set -a && . /etc/default/qaydao-monitor && set +a && /usr/bin/python3 monitor.py >> /var/log/widget-bridge-monitor.log 2>&1") | crontab -
```

## Maintenance

### View recent activity
```bash
tail -200 /var/log/widget-bridge-monitor.log
```

### Manually mute an alert for X hours
```bash
docker exec -it chatwoot_redis redis-cli -n 4
> SETEX qaydao:monitor:alert_sent:<check_id> 7200 "muted"
```

### Disable monitor temporarily
```bash
crontab -e   # comment the line
```

### Re-enable after fixing a known issue
```bash
# Clear all active alert state so next failure sends fresh alert
> /root/chat-qaydao/monitoring/active_alerts.json
echo "{}" > /root/chat-qaydao/monitoring/active_alerts.json
```

## What each check guards

| Check | Failure means | Customer impact |
|---|---|---|
| `widget_bridge_container` | Container stopped | 0 after-hours WhatsApp messages sent |
| `widget_bridge_health` | App crashed inside container | Same as above |
| `captain_config` | OpenAI key gone from DB | QAYDAO AI silent |
| `captain_runtime` | Daemon process can't reach OpenAI | QAYDAO AI silent |
| `auto_resolve` | Auto-close re-enabled | Tickets close before resolution |
| `widget_error_rate` | Multiple send failures | Some customers lose contact |
| `silence_detector` | No webhook events during peak | Website widget likely broken |

## Behavior notes
- Each alert is deduped for 60 min (configurable in `config.py`)
- Recovery messages send only once per resolved issue
- All Riyadh-timezone aware
- Exit code 1 if any active alert (for shell scripting)
- DRY_RUN env var disables actual send

## Cost
- ~7 docker exec calls per tick (light, ~2s total)
- 1 WhatsApp template/freeform message per actual outage (≤ 1 SAR)
- No external dependencies beyond `redis` Python package
