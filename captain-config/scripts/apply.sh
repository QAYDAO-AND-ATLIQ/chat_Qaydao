#!/usr/bin/env bash
# QAYDAO Captain — Apply Configuration
# ====================================
# Runs the canonical seed script inside chatwoot_sidekiq.
# Idempotent — safe to run anytime.
#
# Usage:
#   /root/chat-qaydao/captain-config/scripts/apply.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="$SCRIPT_DIR/seed_captain.rb"

if [ ! -f "$SEED_FILE" ]; then
  echo "❌ Seed file not found: $SEED_FILE"
  exit 1
fi

# Respect maintenance mode — if Captain is intentionally paused, do nothing
MAINTENANCE_FLAG="$SCRIPT_DIR/../MAINTENANCE"
if [ -f "$MAINTENANCE_FLAG" ]; then
  echo "⏸️  Captain is in MAINTENANCE mode — skipping apply (set by pause.sh)."
  echo "    Flag: $MAINTENANCE_FLAG"
  cat "$MAINTENANCE_FLAG" 2>/dev/null | sed 's/^/    /'
  echo "    Run resume.sh to bring Captain back."
  exit 0
fi

echo "📦 Copying seed script into chatwoot_sidekiq..."
docker cp "$SEED_FILE" chatwoot_sidekiq:/tmp/seed_captain.rb

echo "🚀 Running seed (this may take 30-90 seconds)..."
CAPTAIN_MAINTENANCE=$([ -f "$MAINTENANCE_FLAG" ] && echo 1 || echo 0) \
  docker exec -e CAPTAIN_MAINTENANCE="$CAPTAIN_MAINTENANCE" chatwoot_sidekiq bundle exec rails runner /tmp/seed_captain.rb 2>&1 | \
  grep -vE "^(W|I), \[|DEPRECATION WARNING|RubyLLM|^$" | \
  grep -vE "Sidekiq 7|connecting to Redis|warn|Sidekiq notice"

echo ""
echo "✅ Done. Run monitor to verify:"
echo "   cd /root/chat-qaydao/monitoring && python3 monitor.py"
