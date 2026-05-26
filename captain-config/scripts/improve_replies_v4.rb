#!/usr/bin/env ruby
# QAYDAO AI — v4 reply-quality improvements (idempotent)
# Applies: (1) the canonical base instruction, (2) a mandatory formatting rule
# on every scenario (no markdown, plain URLs, whole-riyal prices, no repeats).
# Run inside the chatwoot container:
#   docker cp this chatwoot_sidekiq:/tmp/ && docker exec chatwoot_sidekiq bundle exec rails runner /tmp/improve_replies_v4.rb
# The Arabic locale fixes (auto-resolution message + handoff) are applied
# separately by patches/qaydao-startup-patch.sh on container start.

assistant = Captain::Assistant.find(1)

# ── 1. Base instruction (canonical) ──────────────────────────────────────────
instruction_path = "/tmp/instruction_v2.txt"
if File.exist?(instruction_path)
  instr = File.read(instruction_path)
  if assistant.config["instruction"] != instr
    assistant.update!(config: assistant.config.merge("instruction" => instr))
    puts "✓ base instruction updated (#{instr.length} chars)"
  else
    puts "= base instruction unchanged"
  end
else
  puts "⚠ #{instruction_path} not found — skipping base instruction"
end

# ── 2. Mandatory formatting rule on every scenario ───────────────────────────
FMT = <<~FMT

قواعد التنسيق الإلزامية (مهمة جداً — العرض على واتساب):
• ممنوع تماماً استخدام صيغة الماركداون: لا روابط مزخرفة بصيغة [نص](رابط)، ولا نجمتين ** للعريض، ولا علامة # للعناوين. هذه الرموز تظهر مكسورة على واتساب.
• اكتب الرابط دائماً كنص صريح كامل في سطر مستقل.
• عند عرض منتج، استخدم هذا الشكل بالضبط:
  اسم المنتج — السعر ريال
  https://qaydao.com/-/pXXXX
• الأسعار بالريال السعودي مقرّبة لأقرب ريال كامل دون كسور عشرية (1050 ريال، وليس 1050.00).
• لا تكرر عرض نفس المنتج، وقدّم 3-5 خيارات كحد أقصى.
• لا تستخدم أي رموز تعبيرية (إيموجي).
FMT

marker = "قواعد التنسيق الإلزامية"
Captain::Scenario.where(assistant_id: 1).order(:id).each do |s|
  if s.instruction.to_s.include?(marker)
    puts "= scenario #{s.id} (#{s.title}): formatting rule present"
  else
    s.update!(instruction: s.instruction.to_s.rstrip + "\n" + FMT)
    puts "✓ scenario #{s.id} (#{s.title}): formatting rule added"
  end
end

# ── 3. Scenario 1 match-accuracy rule (don't show a wrong product type) ──────
MATCH_RULE = <<~RULE

دقة البحث والمطابقة (مهم جداً — لا تخالفه):
• ابحث بالكلمات التي ذكرها العميل حرفياً (مثل: "كرسي ألعاب"، "كرسي قيمنق/gaming"، "كرسي مكتب"). لا تستبدل نوع المنتج ولا تخمّن فئة أخرى.
• قبل عرض أي نتيجة، تأكّد أنها تطابق ما طلبه العميل فعلاً. إذا طلب نوعاً (مثل كرسي ألعاب) وجاءت النتائج من فئة مختلفة (مثل كرسي طعام)، لا تعرضها إطلاقاً.
• في هذه الحالة: أعد البحث بصياغة أدق مرة واحدة. فإن لم تجد تطابقاً حقيقياً، كن صادقاً وقل مثلاً: "لم أجد كرسي ألعاب مطابقاً في المتجر حالياً. هل تود أن أبحث في فئة قريبة، أو أحوّلك لمختص لمساعدتك؟" — ولا تعرض نوعاً لم يطلبه العميل.
RULE

s1 = Captain::Scenario.find_by(id: 1, assistant_id: 1)
if s1 && !s1.instruction.to_s.include?("دقة البحث والمطابقة")
  if s1.instruction.include?("خطوات البحث:")
    s1.instruction = s1.instruction.sub("خطوات البحث:", MATCH_RULE.strip + "\n\nخطوات البحث:")
  else
    s1.instruction = s1.instruction.rstrip + "\n" + MATCH_RULE
  end
  s1.save!
  puts "✓ scenario 1: match-accuracy rule added"
else
  puts "= scenario 1: match-accuracy rule present"
end

puts "✅ QAYDAO AI v4 reply-quality improvements applied"
