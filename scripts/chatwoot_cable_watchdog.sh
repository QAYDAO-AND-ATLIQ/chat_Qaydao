#!/usr/bin/env bash
# Chatwoot ActionCable fan-out watchdog.
# Failure it guards against: chatwoot_web loses its Redis pub/sub SUBSCRIBER
# (e.g. after a Redis restart). Symptom: agent dashboard shows new messages
# only after a manual page refresh; live broadcasts are dropped.
#
# Self-heals by restarting chatwoot_web, but ONLY when there is live WS traffic
# yet ZERO cable subscribers. Hardened against false positives / restart loops:
#   - 2 consecutive confirmations required before acting
#   - 10 min cooldown between auto-restarts
#   - if Redis/web cannot be read, do NOTHING (monitoring failure != action)
#
# Run every minute from cron. Logs to /var/log/chatwoot_cable_watchdog.log
set -uo pipefail

WEB=chatwoot_web
REDIS=chatwoot_redis
PREFIX="chatwoot_production_action_cable:"
STATE=/run/chatwoot_cable_wd.state            # consecutive-fail strike count
LASTFILE=/run/chatwoot_cable_wd.lastrestart   # epoch of last auto-restart
COOLDOWN=600                                  # seconds between auto-restarts
LOG=/var/log/chatwoot_cable_watchdog.log
DRYRUN="${1:-}"

log(){ echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

# --- read redis password from the running container (no secret on disk) ---
PW=$(docker exec "$WEB" printenv REDIS_PASSWORD 2>/dev/null)
if [ -z "${PW:-}" ]; then log "WARN cannot read REDIS_PASSWORD from $WEB; skip"; exit 0; fi

# --- count active cable subscribers (redis unreachable => skip, never act) ---
raw=$(docker exec "$REDIS" redis-cli -a "$PW" --no-auth-warning PUBSUB CHANNELS "${PREFIX}*" 2>/dev/null)
if [ $? -ne 0 ]; then log "WARN redis unreachable; skip"; exit 0; fi
subs=$(printf '%s\n' "$raw" | grep -c . || true)

# --- proxy for "clients are actively connected/streaming" ---
recent_ws=$(docker logs "$WEB" --since 3m 2>&1 | grep -c 'Successfully upgraded to WebSocket' || true)

# --- healthy (subs present) OR idle (no WS traffic) => reset strikes, exit ---
if [ "${subs:-0}" -gt 0 ] || [ "${recent_ws:-0}" -eq 0 ]; then
  echo 0 > "$STATE" 2>/dev/null
  exit 0
fi

# --- broken signature: live WS traffic but zero cable subscribers ---
strikes=$(cat "$STATE" 2>/dev/null || echo 0)
strikes=$((strikes + 1))
echo "$strikes" > "$STATE" 2>/dev/null
log "DETECT broken cable fan-out: subs=0 recent_ws=$recent_ws strike=$strikes/2"

[ "$strikes" -ge 2 ] || exit 0   # need 2 consecutive confirmations

# --- cooldown guard (avoid restart loop while cable re-establishes) ---
now=$(date +%s)
last=$(cat "$LASTFILE" 2>/dev/null || echo 0)
if [ $((now - last)) -lt "$COOLDOWN" ]; then
  log "COOLDOWN active ($((now - last))s < ${COOLDOWN}s); skip restart"
  exit 0
fi

if [ "$DRYRUN" = "--dry-run" ]; then
  log "DRYRUN: would restart $WEB"
  echo "DRYRUN: conditions met -> would restart $WEB"
  exit 0
fi

log "ACTION restarting $WEB (cable fan-out down)"
if docker restart "$WEB" >/dev/null 2>&1; then
  log "OK restarted $WEB"
else
  log "ERR restart failed"
fi
echo "$now" > "$LASTFILE" 2>/dev/null
echo 0 > "$STATE" 2>/dev/null
