#!/usr/bin/env bash
# ============================================================================
# QAYDAO Chatwoot — Apply Folders (Custom Views) for ALL account users
# ============================================================================
# Canonical, idempotent self-heal. Runs seed_folders.rb inside chatwoot_sidekiq.
#
# Independent of Captain maintenance mode ON PURPOSE — folders are a base UX
# guarantee for the CS team and must persist even while Captain is paused.
#
# Scheduled by host cron (every 6h) so it survives:
#   - docker compose up -d --force-recreate
#   - Chatwoot image upgrades
#   - accidental folder deletion
#   - new agent onboarding (auto-provisions all 9 folders)
#
# Usage:
#   /root/chat-qaydao/captain-config/scripts/apply_folders.sh
#   FOLDERS_FORCE_SYNC=1 /root/chat-qaydao/captain-config/scripts/apply_folders.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="$SCRIPT_DIR/seed_folders.rb"
CONTAINER="chatwoot_sidekiq"

[ -f "$SEED_FILE" ] || { echo "❌ Seed file not found: $SEED_FILE"; exit 1; }

echo "📁 Copying seed_folders.rb into ${CONTAINER}..."
docker cp "$SEED_FILE" "${CONTAINER}:/tmp/seed_folders.rb"

echo "🚀 Seeding folders for all account users..."
docker exec \
  -e FOLDERS_FORCE_SYNC="${FOLDERS_FORCE_SYNC:-0}" \
  -e FOLDERS_ACCOUNT_ID="${FOLDERS_ACCOUNT_ID:-1}" \
  "${CONTAINER}" bundle exec rails runner /tmp/seed_folders.rb 2>&1 | \
  grep -vE "^(W|I), \[|DEPRECATION WARNING|RubyLLM|^$|Sidekiq |connecting to Redis|warn|Sidekiq notice"

echo "✅ Folders apply complete."
