#!/bin/sh
# QAYDAO — startup patches, run inside chatwoot_web on every container start,
# BEFORE rails boots. All patches are idempotent and safe. Re-applied
# automatically so customizations survive `docker compose up --force-recreate`
# and image recreation. (On a Chatwoot version upgrade, re-verify the patterns.)

# ── Patch 1: client-side label filter (.every → .some) ───────────────────────
# Multi-label custom folders were displayed empty because the compiled frontend
# matched label arrays with .every (AND) instead of .some (OR). Only patches
# files that contain BOTH the equalTo "all" guard and the exact minified pattern.
for f in /app/public/vite/assets/*.js; do
  if grep -q 'includes("all")' "$f" 2>/dev/null && grep -q 'e.every(a=>E.includes(a))' "$f" 2>/dev/null; then
    sed -i 's/e\.every(a=>E\.includes(a))/e.some(a=>E.includes(a))/g' "$f"
    echo "[qaydao-patch] label filter patched in $f"
  fi
done

# ── Patch 2: Arabic locale fixes for QAYDAO AI (Captain) ─────────────────────
# (a) Captain auto-resolution message was untranslated (English) in ar.yml.
# (b) The handoff message was terse/robotic. Both replaced with professional
#     Arabic. Idempotent: only replaces the English/old strings if still present.
AR=/app/config/locales/ar.yml
if [ -f "$AR" ]; then
  sed -i "s|auto_resolution_message: 'Resolving the conversation as it has been inactive for a while. Please start a new conversation if you need further assistance.'|auto_resolution_message: 'نسعد بخدمتك دائماً. سيتم إنهاء هذه المحادثة لعدم وجود نشاط لفترة. لا تتردد في بدء محادثة جديدة في أي وقت، وكواي داو في خدمتك.'|" "$AR"
  sed -i "s|handoff: 'تحويل إلى وكيل آخر لمزيد من المساعدة.'|handoff: 'يسعدنا تحويلك إلى أحد ممثلي خدمة العملاء لمساعدتك بشكل أفضل. سيصلك الرد في أقرب وقت ضمن أوقات العمل. شكراً لتفهّمك.'|" "$AR"
  echo "[qaydao-patch] ar.yml captain locale fixed"
fi

exit 0
