#!/bin/sh
# QAYDAO — startup patch: fix client-side label filter (.every → .some)
# Runs inside chatwoot_web on every container start, BEFORE rails boots.
# Only patches files that contain BOTH the equalTo "all" guard AND the exact
# minified pattern, so it can never touch unrelated code. Safe + idempotent.
# If a Chatwoot upgrade changes the minified variable names, this becomes a
# harmless no-op (update the pattern then).
for f in /app/public/vite/assets/*.js; do
  if grep -q 'includes("all")' "$f" 2>/dev/null && grep -q 'e.every(a=>E.includes(a))' "$f" 2>/dev/null; then
    sed -i 's/e\.every(a=>E\.includes(a))/e.some(a=>E.includes(a))/g' "$f"
    echo "[qaydao-patch] label filter patched in $f"
  fi
done
exit 0
