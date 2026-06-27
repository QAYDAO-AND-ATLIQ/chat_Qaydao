# Standalone test for the QAYDAO no-repeat guard.
# Requires the initializer file; the Rails-dependent block is skipped when Rails
# is undefined, so only the pure QaydaoCannedReply module loads.
require_relative 'qaydao_captain_no_interrupt'

$fail = 0
def ok(cond, msg)
  if cond then puts "  ok  : #{msg}" else puts "  FAIL: #{msg}"; $fail += 1 end
end

# Real discount reply (as sent to the customer in conv with Nada Alamoudi)
discount_real     = 'يسعدنا نقدم لك خصم باستخدام كود (F5) عند إتمام الطلب لتحصلي على تخفيض إضافي على القطعة!'
# Same intent, reworded by the LLM (must still be caught)
discount_reworded = 'تقدر تستخدم كوبون الخصم F5 وقت الدفع عشان تحصل على تخفيض.'
discount_english  = 'You can use coupon code F5 at checkout to get an extra discount.'
greeting          = 'مرحبا بك في كواي داو، كيف أقدر أساعدك اليوم؟'
shipping          = 'الشحن يستغرق من ٢ إلى ٥ أيام عمل داخل الرياض.'
price_only        = 'سعر هذه القطعة ٣٢٠ ريال شامل الضريبة.'  # mentions price, no coupon -> not flagged

puts '--- detection ---'
ok(QaydaoCannedReply.category(discount_real)     == 'discount', 'real discount reply detected')
ok(QaydaoCannedReply.category(discount_reworded) == 'discount', 'reworded discount reply detected')
ok(QaydaoCannedReply.category(discount_english)  == 'discount', 'english discount reply detected')
ok(QaydaoCannedReply.category(greeting).nil?,                   'greeting NOT flagged')
ok(QaydaoCannedReply.category(shipping).nil?,                   'shipping NOT flagged')
ok(QaydaoCannedReply.category(price_only).nil?,                 'price-only NOT flagged (no coupon)')

# Simulate the conversation-wide dedup decision used by the patch.
def repeat?(history, new_reply)
  cat = QaydaoCannedReply.category(new_reply)
  return false if cat.nil?
  history.any? { |h| QaydaoCannedReply.category(h) == cat }
end

puts '--- conversation-wide dedup ---'
history = []
ok(repeat?(history, discount_real) == false, 'first discount reply ALLOWED')
history << discount_real
ok(repeat?(history, discount_reworded) == true,  'second discount (reworded) BLOCKED -> not sent twice')
ok(repeat?(history, discount_english)  == true,  'second discount (english) BLOCKED')
ok(repeat?(history, greeting)          == false, 'greeting still allowed after a discount')
ok(repeat?(history, shipping)          == false, 'shipping still allowed after a discount')

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} TEST(S) FAILED")
exit($fail.zero? ? 0 : 1)
