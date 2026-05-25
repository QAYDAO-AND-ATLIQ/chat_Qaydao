#!/usr/bin/env bash
# QAYDAO Chatwoot — Arabic locale fixes
# ======================================
# Re-applies custom Arabic translations that ship untranslated (English)
# in Chatwoot's ar.yml. Run after any Chatwoot image rebuild/upgrade.
#
# Idempotent. Safe to run anytime.
#
# Usage: /root/chat-qaydao/captain-config/scripts/fix_arabic_locale.sh

set -euo pipefail

CTN="chatwoot_sidekiq"
WEB="chatwoot_web"
AR_YML="/app/config/locales/ar.yml"

EN_AUTO_RESOLVE="Resolving the conversation as it has been inactive for a while. Please start a new conversation if you need further assistance."
AR_AUTO_RESOLVE="نسعد بخدمتك دائماً. تم إنهاء هذه المحادثة لعدم وجود نشاط لفترة. لا تتردد في بدء محادثة جديدة في أي وقت، وكواي داو في خدمتك."

echo "🌐 Applying Arabic locale fixes..."

# auto_resolution_message (shown to customers when Captain resolves idle chats)
if docker exec "$CTN" grep -qF "$EN_AUTO_RESOLVE" "$AR_YML" 2>/dev/null; then
  docker exec "$CTN" sh -c "sed -i \"s|auto_resolution_message: '${EN_AUTO_RESOLVE}'|auto_resolution_message: '${AR_AUTO_RESOLVE}'|\" $AR_YML"
  echo "  ✓ auto_resolution_message translated to Arabic"
  NEED_RESTART=1
else
  if docker exec "$CTN" grep -qF "$AR_AUTO_RESOLVE" "$AR_YML" 2>/dev/null; then
    echo "  = auto_resolution_message already Arabic"
  else
    echo "  ⚠ auto_resolution_message not found (Chatwoot may have changed the string)"
  fi
fi

if [ "${NEED_RESTART:-0}" = "1" ]; then
  echo "🔄 Restarting web + sidekiq to load locale..."
  docker restart "$WEB" "$CTN" >/dev/null 2>&1
  sleep 20
  echo "  ✓ restarted"
fi

echo ""
echo "Verify:"
docker exec "$CTN" bundle exec rails runner 'puts "  → " + I18n.t("conversations.activity.auto_resolution_message", locale: :ar)' 2>/dev/null | grep "→" || echo "  (run manually to verify)"
echo "✅ Done"
