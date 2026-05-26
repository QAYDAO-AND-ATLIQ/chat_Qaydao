#!/usr/bin/env ruby
# QAYDAO AI — reply quality audit (run on demand).
#   docker cp this chatwoot_sidekiq:/tmp/ && docker exec chatwoot_sidekiq bundle exec rails runner /tmp/audit_qaydao_ai.rb [hours]
#
# Scans QAYDAO AI's customer-facing replies (inboxes 2,3,5,6 — excludes the
# internal alerts inbox 7) for the quality issues we fixed:
#   - markdown ([text](url) or **bold**) — breaks on WhatsApp
#   - fractional prices (e.g. 374.4 ريال) — must be whole riyals
#   - emoji — not allowed in QAYDAO AI replies
#   - real English leakage (4+ consecutive English words after stripping URLs;
#     internal Auto-handoff/Auto-resolved system notes are technical, not
#     customer-facing, and are reported separately)
#   - duplicate product (same URL twice in one reply)

hours = (ARGV[0] || 48).to_i
account = Account.find(1)
CUSTOMER_INBOXES = [2, 3, 5, 6].freeze

replies = Message.where(account_id: account.id, sender_type: 'Captain::Assistant', message_type: 1)
                 .joins(:conversation).where(conversations: { inbox_id: CUSTOMER_INBOXES })
                 .where('messages.created_at > ?', hours.hours.ago)
                 .order('messages.created_at DESC')

total = replies.count
issues = Hash.new(0)
examples = Hash.new { |h, k| h[k] = [] }
add = ->(k, cid) { issues[k] += 1; examples[k] << cid if examples[k].size < 5 }

replies.each do |m|
  c = m.content.to_s
  cid = m.conversation_id
  body = c.gsub(%r{https?://\S+}, '') # strip URLs before text checks
  add.call(:markdown, cid)       if c.match?(/\[[^\]]+\]\([^)]+\)/) || c.include?('**')
  add.call(:price_fraction, cid) if c.match?(/\d+\.\d+\s*ريال/)
  add.call(:emoji, cid)          if c.match?(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/)
  add.call(:dup_product, cid)    if (u = c.scan(%r{https?://\S+})) && u.size != u.uniq.size
  if body.match?(/[A-Za-z]+\s+[A-Za-z]+\s+[A-Za-z]+\s+[A-Za-z]+/)
    # separate internal system notes (not customer-facing) from real leakage
    if c.start_with?('Auto-handoff:', 'Auto-resolved:')
      add.call(:english_system_note, cid)
    else
      add.call(:english_customer, cid)
    end
  end
end

puts "═══ QAYDAO AI Reply Audit — آخر #{hours} ساعة (قنوات العملاء فقط) ═══"
puts "إجمالي الردود: #{total}"
pct = ->(n) { "#{n} (#{(100.0 * n / [total, 1].max).round(1)}%)" }
{
  markdown: 'ماركداون', price_fraction: 'كسور أسعار', emoji: 'إيموجي',
  dup_product: 'منتج مكرر', english_customer: 'إنجليزي للعميل (مشكلة)',
  english_system_note: 'إنجليزي ملاحظة نظام (مقبول)'
}.each do |k, label|
  puts "  #{label}: #{pct.call(issues[k])}#{examples[k].any? ? "  [#{examples[k].join(', ')}]" : ''}"
end
