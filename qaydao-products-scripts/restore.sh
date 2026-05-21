#!/usr/bin/env bash
# QAYDAO Products — Restore from Git
# ===================================
# Restores /root/qaydao-products/ files from the chat-qaydao git repo mirror.
# Use this if any file is accidentally deleted or corrupted.
#
# Safe to run anytime. Idempotent. Backs up current state before overwriting.
#
# Usage:
#   /root/chat-qaydao/qaydao-products-scripts/restore.sh
#
# What gets restored:
#   - server.js (main Node app)
#   - public/index.html (main UI)
#   - public/captain-learn.html
#   - public/captain-replies.html
#   - captain-manager.js
#   - scripts/cleanup_ghost_products.js
#   - scripts/extract_learning_suggestions.js
#   - unified-import/ (entire directory)
#
# What is NOT restored:
#   - .env (secrets — manage manually)
#   - node_modules (re-installed via npm)
#   - data/ logs/ backups/ (runtime data — never touched)

set -euo pipefail

SRC="/root/chat-qaydao/qaydao-products-scripts"
DST="/root/qaydao-products"
BACKUP_DIR="$DST/backups/restore-pre-$(date +%Y%m%d_%H%M%S)"

if [ ! -d "$SRC" ]; then
  echo "❌ Source not found: $SRC"
  echo "   Run: cd /root/chat-qaydao && git pull origin main"
  exit 1
fi

echo "🔄 QAYDAO Products Restore"
echo "=========================="
echo "Source: $SRC"
echo "Destination: $DST"
echo ""

# 1. Backup current state
mkdir -p "$BACKUP_DIR"
for f in server.js captain-manager.js public/index.html public/captain.html \
         public/captain-replies.html public/captain-learn.html; do
  if [ -f "$DST/$f" ]; then
    cp --parents "$DST/$f" "$BACKUP_DIR/" 2>/dev/null || true
  fi
done
if [ -d "$DST/unified-import" ]; then
  cp -r "$DST/unified-import" "$BACKUP_DIR/unified-import" 2>/dev/null || true
fi
echo "✅ Backup: $BACKUP_DIR"
echo ""

# 2. Restore files (additive — git mirror is source of truth)
mkdir -p "$DST/public" "$DST/scripts" "$DST/unified-import/parsers" "$DST/unified-import/propagators"

# Top-level
[ -f "$SRC/server.js" ]            && cp "$SRC/server.js" "$DST/server.js"            && echo "  ✓ server.js"
[ -f "$SRC/captain-manager.js" ]   && cp "$SRC/captain-manager.js" "$DST/captain-manager.js" && echo "  ✓ captain-manager.js"

# Public
[ -f "$SRC/index.html" ]              && cp "$SRC/index.html" "$DST/public/index.html"              && echo "  ✓ public/index.html"
[ -f "$SRC/captain-replies.html" ]    && cp "$SRC/captain-replies.html" "$DST/public/captain-replies.html" && echo "  ✓ public/captain-replies.html"
[ -f "$SRC/captain-learn.html" ]      && cp "$SRC/captain-learn.html" "$DST/public/captain-learn.html"     && echo "  ✓ public/captain-learn.html"

# Scripts
[ -f "$SRC/cleanup_ghost_products.js" ]       && cp "$SRC/cleanup_ghost_products.js" "$DST/scripts/"       && echo "  ✓ scripts/cleanup_ghost_products.js"
[ -f "$SRC/extract_learning_suggestions.js" ] && cp "$SRC/extract_learning_suggestions.js" "$DST/scripts/" && echo "  ✓ scripts/extract_learning_suggestions.js"

# Unified import system
for f in index.js parsers/csv.js parsers/xml.js \
         propagators/master.js propagators/sales.js propagators/studio.js; do
  if [ -f "$SRC/unified-import/$f" ]; then
    cp "$SRC/unified-import/$f" "$DST/unified-import/$f"
    echo "  ✓ unified-import/$f"
  fi
done

echo ""
echo "📦 Installing dependencies..."
cd "$DST"
npm install --silent 2>&1 | tail -2 || echo "  ⚠ npm install had warnings (usually safe)"

echo ""
echo "🔄 Restarting service..."
pkill -f "node $DST/server.js" 2>/dev/null || true
sleep 2
cd "$DST"
mkdir -p logs
nohup node server.js > logs/server.log 2>&1 & disown
sleep 3

if ss -tlnp 2>/dev/null | grep -q ":3601"; then
  echo "✅ Service running on 127.0.0.1:3601"
else
  echo "❌ Service NOT running — check logs/server.log"
  tail -20 logs/server.log
  exit 1
fi

echo ""
echo "============================================"
echo "✅ Restore complete"
echo "============================================"
echo "Backup at: $BACKUP_DIR"
echo "Verify:"
echo "  curl -s https://chat.qaydao.com/products/api/health | jq"
echo "  open https://chat.qaydao.com/products/"
