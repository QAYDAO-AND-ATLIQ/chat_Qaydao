#!/usr/bin/env bash
# QAYDAO Chatwoot — Assignment Workflow Setup (idempotent)
# ========================================================
# Problem 1+2: round-robin auto-assignment was piling conversations onto one
# agent and making per-agent counts wildly inconsistent.
#
# This sets the desired workflow:
#   • Auto-assignment DISABLED on customer inboxes (2,3,5,6)
#       → new conversations land in "غير معين" (fair, everyone sees them)
#   • assign-on-reply webhook (in qaydao-products) assigns a conversation to
#     the agent who sends the first reply.
#
# Re-run anytime (e.g. after a Chatwoot rebuild) to restore the workflow.
# The webhook URL secret is read from /root/qaydao-products/.env.

set -euo pipefail

echo "🔧 Configuring assignment workflow..."

# 1. Disable round-robin auto-assignment on customer inboxes
docker cp - chatwoot_sidekiq:/tmp/_disable_aa.rb <<'RUBY' 2>/dev/null || true
[2,3,5,6].each do |iid|
  ib = Inbox.find_by(id: iid) or next
  ib.update!(enable_auto_assignment: false)
  puts "  inbox #{iid} (#{ib.name}): auto_assignment=#{ib.enable_auto_assignment}"
end
RUBY
docker exec chatwoot_sidekiq bundle exec rails runner /tmp/_disable_aa.rb 2>&1 \
  | grep -E "inbox [0-9]" || true

# 2. (Re)register the assign-on-reply webhook
SECRET=$(grep ASSIGN_WEBHOOK_SECRET /root/qaydao-products/.env | cut -d= -f2)
docker cp - chatwoot_sidekiq:/tmp/_reg_wh.rb <<RUBY 2>/dev/null || true
account = Account.find(1)
url = "https://chat.qaydao.com/products/api/webhook/chatwoot?secret=${SECRET}"
account.webhooks.where("url LIKE ?", "%/products/api/webhook/chatwoot%").destroy_all
wh = account.webhooks.create!(url: url, webhook_type: :account_type, subscriptions: ["message_created"])
puts "  webhook id #{wh.id} events=#{wh.subscriptions.inspect}"
RUBY
docker exec chatwoot_sidekiq bundle exec rails runner /tmp/_reg_wh.rb 2>&1 \
  | grep -E "webhook id" || true

echo "✅ Assignment workflow configured."
echo "   New conversations → unassigned; first agent reply → auto-assigned."
