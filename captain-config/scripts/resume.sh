#!/usr/bin/env bash
# QAYDAO Captain — RESUME (exit maintenance mode)
# ================================================
# Re-binds Captain to all customer channels and removes the maintenance flag.
# Runs the full seed afterwards to guarantee everything is correct.
#
# Usage:
#   /root/chat-qaydao/captain-config/scripts/resume.sh

set -euo pipefail

FLAG_FILE="/root/chat-qaydao/captain-config/MAINTENANCE"
APPLY="/root/chat-qaydao/captain-config/scripts/apply.sh"

echo "▶️  QAYDAO Captain — Resume"
echo "=============================================="

if [ ! -f "$FLAG_FILE" ]; then
  echo "ℹ️  No maintenance flag found — Captain may already be active."
fi

# 1. Remove maintenance flag FIRST so apply.sh will proceed
rm -f "$FLAG_FILE"
echo "✓ Maintenance flag removed"

# 2. Run full seed → re-binds inboxes + restores all settings idempotently
echo "✓ Running full configuration (re-binds channels + verifies everything)..."
"$APPLY" 2>&1 | grep -E "✓|=|✅" | tail -15

echo ""
echo "=============================================="
echo "✅ Captain is BACK ONLINE on all 4 channels."
echo "   Test: open https://chat.qaydao.com → القائد → Playground"
echo "   Or send a message on the website chat widget."
