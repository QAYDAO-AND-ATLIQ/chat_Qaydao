#!/usr/bin/env bash
# QAYDAO Chatwoot — Web Push (VAPID) Setup
# ========================================
# Without VAPID keys, agents get NO real-time browser/desktop notifications
# (e.g. when @mentioned). This generates and stores VAPID keys so web push
# works. Agents must then grant browser notification permission once
# (Profile Settings → Notifications, or accept the browser prompt).
#
# Keys are stored in installation_configs (DB, survives image rebuilds).
# Idempotent — won't overwrite existing keys.

set -euo pipefail
echo "🔔 Configuring web push (VAPID)..."

docker cp - chatwoot_sidekiq:/tmp/_vapid.rb <<'RUBY' 2>/dev/null || true
if InstallationConfig.find_by(name: "VAPID_PUBLIC_KEY")&.value.present?
  puts "  = VAPID already configured"
else
  v = WebPush.generate_key
  p1 = InstallationConfig.new(name: "VAPID_PUBLIC_KEY");  p1.value = v.public_key;  p1.save!
  p2 = InstallationConfig.new(name: "VAPID_PRIVATE_KEY"); p2.value = v.private_key; p2.save!
  GlobalConfig.clear_cache rescue nil
  puts "  ✓ VAPID keys generated and stored"
end
RUBY
docker exec chatwoot_sidekiq bundle exec rails runner /tmp/_vapid.rb 2>&1 | grep -E "VAPID|✓|=" || true

echo "  ↻ restart web+sidekiq to expose the public key to the dashboard:"
echo "     docker restart chatwoot_web chatwoot_sidekiq"
echo "✅ Done. Agents: grant browser notification permission once to receive alerts."
