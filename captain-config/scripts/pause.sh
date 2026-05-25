#!/usr/bin/env bash
# QAYDAO Captain — PAUSE (maintenance mode)
# ==========================================
# Stops Captain from replying to customers across ALL channels,
# while keeping all data (FAQs, Scenarios, Tools) intact.
#
# Sets a MAINTENANCE flag that:
#   - apply.sh respects (won't re-enable Captain during the 6h auto-heal)
#   - monitor.py respects (won't alert about captain being down — it's intentional)
#
# Usage:
#   /root/chat-qaydao/captain-config/scripts/pause.sh
#
# To bring Captain back:
#   /root/chat-qaydao/captain-config/scripts/resume.sh

set -euo pipefail

FLAG_FILE="/root/chat-qaydao/captain-config/MAINTENANCE"
BACKUP_FILE="/root/chat-qaydao/captain-config/.captain_inboxes_before_pause"

echo "⏸️  QAYDAO Captain — Pause (Maintenance Mode)"
echo "=============================================="

# 1. Save current inbox bindings so resume.sh can restore exactly
docker exec chatwoot_postgres psql -U chatwoot_user -d chatwoot_production -t -A -c \
  "SELECT inbox_id FROM captain_inboxes WHERE captain_assistant_id = 1 ORDER BY inbox_id;" \
  > "$BACKUP_FILE"
echo "✓ Saved current bindings: $(tr '\n' ' ' < "$BACKUP_FILE")"

# 2. Unbind Captain from all inboxes → stops replies immediately
docker exec chatwoot_sidekiq bundle exec rails runner "
  CaptainInbox.where(captain_assistant_id: 1).destroy_all
  puts 'Captain unbound from all inboxes'
" 2>&1 | grep -vE "WARN|INFO|deprecated|connecting|Sidekiq" | tail -1

# 3. Set maintenance flag (apply.sh + monitor read this)
echo "paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FLAG_FILE"
echo "paused_by=${USER:-admin}" >> "$FLAG_FILE"
echo "✓ Maintenance flag set: $FLAG_FILE"

echo ""
echo "=============================================="
echo "✅ Captain is PAUSED — it will NOT reply to any customer."
echo ""
echo "What still works:"
echo "  • Human agents reply normally in Chatwoot"
echo "  • All FAQs / Scenarios / Tools are preserved"
echo "  • You can edit everything at /products/captain"
echo "  • auto-heal (apply.sh) will NOT re-enable during maintenance"
echo ""
echo "When done improving, run:"
echo "  /root/chat-qaydao/captain-config/scripts/resume.sh"
