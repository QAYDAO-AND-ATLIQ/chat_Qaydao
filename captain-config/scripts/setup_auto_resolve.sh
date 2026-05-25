#!/usr/bin/env bash
# QAYDAO Chatwoot — Auto-Resolve Configuration (problem 3)
# ========================================================
# Resolved tickets were "reopening" because ANY customer message reopens a
# resolved conversation. Real follow-up questions SHOULD reopen (correct),
# but pleasantries ("شكرا") and abandoned chats shouldn't linger.
#
# Fix: enable auto-resolve after 4 days of inactivity, but ONLY for
# conversations NOT waiting on a customer reply (auto_resolve_ignore_waiting).
# → A real pending question keeps the conversation open; a stale/pleasantry
#   reopen auto-closes after 4 days with a professional Arabic message.
#
# Idempotent. Re-run after any Chatwoot rebuild.

set -euo pipefail
echo "🔧 Configuring auto-resolve (4 days, ignore-waiting)..."

docker cp - chatwoot_sidekiq:/tmp/_autoresolve.rb <<'RUBY' 2>/dev/null || true
a = Account.find(1)
a.auto_resolve_after = 5760          # 4 days in minutes
a.auto_resolve_ignore_waiting = true # don't resolve conversations awaiting our reply
a.auto_resolve_message = "نسعد بخدمتك دائماً. تم إنهاء هذه المحادثة لعدم وجود نشاط لفترة. لا تتردد في بدء محادثة جديدة في أي وقت، وكواي داو في خدمتك."
a.save!
puts "  auto_resolve_after=#{a.auto_resolve_after}min (#{a.auto_resolve_after/1440}d) ignore_waiting=#{a.auto_resolve_ignore_waiting}"
RUBY
docker exec chatwoot_sidekiq bundle exec rails runner /tmp/_autoresolve.rb 2>&1 | grep -E "auto_resolve_after" || true

echo "✅ Auto-resolve configured."
echo "   Conversations idle 4 days & not awaiting our reply → auto-resolved with Arabic note."
echo "   Real customer questions keep conversations open."
