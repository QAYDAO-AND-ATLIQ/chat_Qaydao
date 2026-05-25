#!/usr/bin/env bash
# QAYDAO Chatwoot — Fix client-side label filter bug (multi-label custom folders)
# ==============================================================================
# Chatwoot's compiled frontend `equalTo` helper matches label arrays with
# `.every()` (requires ALL labels = AND) instead of `.some()` (any label = OR).
# This makes multi-label custom folders (e.g. B2B with 3 labels) display EMPTY
# even when the server filter matches conversations — and makes folder counts
# disagree with the displayed list.
#
# Fix: patch the minified bundle, changing the label-matching `.every` → `.some`.
# Only affects array-valued attributes (labels); status/priority use other
# branches, so this is safe.
#
# NOTE: the bundle is baked into the Chatwoot image. Re-run this after any
# `docker compose up --force-recreate` or Chatwoot version upgrade.
# Idempotent.

set -euo pipefail
CTN=chatwoot_web
echo "🔧 Patching client-side label filter (.every → .some)..."

for CONTAINER in chatwoot_web; do
  # Find the bundle containing the equalTo pattern
  FILE=$(docker exec $CONTAINER sh -c "grep -rl 'e.every(a=>E.includes(a))' /app/public/vite/assets/*.js 2>/dev/null | head -1" || true)
  if [ -z "$FILE" ]; then
    # already patched?
    ALT=$(docker exec $CONTAINER sh -c "grep -rl 'e.some(a=>E.includes(a))' /app/public/vite/assets/*.js 2>/dev/null | head -1" || true)
    if [ -n "$ALT" ]; then echo "  = already patched ($ALT)"; else echo "  ⚠ pattern not found (var names may have changed on upgrade — update this script)"; fi
    continue
  fi
  docker exec $CONTAINER sh -c "sed -i 's/e\.every(a=>E\.includes(a))/e.some(a=>E.includes(a))/' '$FILE'"
  echo "  ✓ patched $FILE"
done
echo "✅ Done. Multi-label folders now display with OR-matching (any label)."
