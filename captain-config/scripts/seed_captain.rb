#!/usr/bin/env ruby
# frozen_string_literal: true
#
# QAYDAO Captain AI — Idempotent Seed Script
# ==========================================
# Rebuilds Captain configuration from source-of-truth in this script.
# Safe to run multiple times — uses find_or_create / update! patterns.
#
# Usage (inside chatwoot_sidekiq container):
#   docker exec chatwoot_sidekiq bundle exec rails runner /path/to/seed_captain.rb
#
# Or from host (auto-copies):
#   /root/chat-qaydao/captain-config/scripts/apply.sh
#
# What this script guarantees:
#   1. Pricing plan = enterprise + cache cleared
#   2. captain_integration + captain_integration_v2 features enabled
#   3. Captain assistant instruction is set to canonical version
#   4. 2 custom tools (search_products + track_order) with url_encode
#   5. 4 scenarios with handoff-back rules
#   6. Captain bound to all customer-facing inboxes
#   7. All FAQ embeddings present (regenerates missing ones)
#   8. Automation rule #3 event = conversation_opened
#   9. auto_resolve_duration = NULL
#  10. captain_learning_suggestions table exists
#
# ============================================

require "active_record"

ACCOUNT_ID = 1
ASSISTANT_ID = 1

log = ->(msg) { puts "[seed_captain] #{msg}" }

# ──────────────── 1. Pricing plan ────────────────
log.call "→ 1/10 Pricing plan + cache clear"
pp_cfg = InstallationConfig.find_by!(name: "INSTALLATION_PRICING_PLAN")
pp_cfg.update!(value: "enterprise", locked: false) unless pp_cfg.value == "enterprise"
qty_cfg = InstallationConfig.find_by!(name: "INSTALLATION_PRICING_PLAN_QUANTITY")
qty_cfg.update!(value: "100", locked: false) unless qty_cfg.value.to_s == "100"
GlobalConfig.clear_cache
log.call "   ✓ plan=enterprise qty=100 cache=cleared"

# ──────────────── 2. Feature flags ────────────────
log.call "→ 2/10 Feature flags"
account = Account.find(ACCOUNT_ID)
%w[captain_integration captain_integration_v2 help_center captain_tasks].each do |f|
  account.enable_features!(f) unless account.feature_enabled?(f)
end
log.call "   ✓ captain_integration + V2 enabled"

# ──────────────── 3. Assistant instruction ────────────────
log.call "→ 3/10 Assistant instruction"
assistant = Captain::Assistant.find(ASSISTANT_ID)
canonical_instruction = <<~PROMPT
  أنت QAYDAO AI - مساعد ذكي رسمي لخدمة عملاء متجر كواي داو (qaydao.com)، متجر سعودي للأثاث المنزلي والمكتبي الفاخر.

  الهوية:
  • اسمك: QAYDAO AI
  • شركتك: كواي داو (QAYDAO)
  • لهجتك: عربية مبسطة مع لمسات سعودية ودودة (حياك، أبشر، يسعدنا)
  • ابدأ كل رد بـ: 🤖 معك QAYDAO AI

  معلومات أساسية:
  • الموقع: qaydao.com (منصة Salla)
  • خدمة العملاء: +966 54 845 6966 | info@qaydao.com
  • الموردين: supply@qaydao.com
  • B2B: b2b.qaydao.com
  • الاستوديو: studio.qaydao.com
  • التتبع: track.qaydao.com
  • الرقم الضريبي: 312614700300003
  • التطبيق: App Store + Google Play

  السياسات:
  • الشحن المجاني: فوق 700 ريال
  • التوصيل (جاهز): 1-3 شحن + 3-7 توصيل
  • التوصيل (مصنوع خصيصاً): 30-60 يوم (قد تصل 90)
  • الاسترجاع: 24 ساعة من الاستلام (خلل مصنعي موثق)
  • الإلغاء: 24 ساعة من التأكيد بدون رسوم
  • استرداد المبلغ: 7-14 يوم عمل
  • طرق الدفع: فيزا (3% رسوم استرداد)، مدى، أبل باي، تابي/تمارا (8% رسوم استرداد)
  • خدمة التركيب: غير متوفرة حالياً
  • أوقات العمل: الأحد-الخميس 9 ص - 6 م (إجازة: الجمعة والسبت)

  الأقسام:
  • أثاث الشركات (مكاتب، كراسي، طاولات اجتماعات، خزائن)
  • أثاث منزلي (نوم، معيشة، طعام، أطفال، كلاسيكي)
  • كراسي ومعدات المساج
  • تجهيز المشاريع (مقاهي، تعليمي، مراكز تجميل)

  قواعد التحويل الفوري للموظف:
  🚨 شكوى/غضب (زعلانة، للأسف، بشتكي، محكمة، نظام التجارة)
  🚨 طلب استرجاع أو إلغاء
  🚨 شكوى منتج تالف
  🚨 طلب صريح: أبغى أكلم موظف
  🚨 B2B كبير
  🚨 فواتير/ضريبة/IBAN

  قواعد الردود:
  • قصير ومباشر (2-4 أسطر)
  • Emojis باعتدال: ✅ ⏰ 📦 🚚 🤍
  • لو لا تعرف، قل بصراحة ولا تخترع
  • لا تطلب IBAN في الشات
  • خارج ساعات العمل البشرية، أنت الوحيد المتاح

  أدوات متاحة:
  🔍 search_products: ابحث في كتالوج المنتجات (9,796 منتج)
  📦 track_order: تتبع حالة طلب
PROMPT

if assistant.config["instruction"] != canonical_instruction
  assistant.update!(config: assistant.config.merge("instruction" => canonical_instruction))
  log.call "   ✓ instruction updated"
else
  log.call "   = instruction unchanged"
end

# ──────────────── 4. Custom Tools ────────────────
log.call "→ 4/10 Custom tools"

search_tool = Captain::CustomTool.find_or_initialize_by(account_id: ACCOUNT_ID, slug: "search_products")
search_tool.assign_attributes(
  title: "البحث عن منتج",
  description: "ابحث في كتالوج منتجات كواي داو (9,796 منتج). استخدم هذه الأداة عندما يسأل العميل عن منتج معين، أو يبحث عن خيارات في فئة. ترجع أفضل 5 نتائج مع الأسعار والروابط.",
  endpoint_url: "https://chat.qaydao.com/products/api/search?q={{query | url_encode}}",
  http_method: "GET",
  auth_type: "none",
  param_schema: [
    { "name" => "query", "type" => "string", "required" => true,
      "description" => "اسم المنتج أو نوعه (مثل: كرسي مكتب، طاولة طعام)" }
  ],
  enabled: true
)
search_tool.save!
log.call "   ✓ search_products tool"

track_tool = Captain::CustomTool.find_or_initialize_by(account_id: ACCOUNT_ID, slug: "track_order")
track_tool.assign_attributes(
  title: "تتبع حالة الطلب",
  description: "يستخدم هذا الـ tool لجلب حالة طلب من نظام تتبع كواي داو (track.qaydao.com) باستخدام رقم الطلب. يعطي الحالة الحالية، تاريخ الطلب، المدينة، الموعد المتوقع، وكامل تاريخ مراحل التصنيع. استخدمه عندما يطلب العميل تتبع طلب أو حالة طلبه.",
  endpoint_url: "https://track.qaydao.com/api/tracking/{{order_number | url_encode}}",
  http_method: "GET",
  auth_type: "none",
  param_schema: [
    { "name" => "order_number", "type" => "string", "required" => true,
      "description" => "رقم الطلب كما هو في فاتورة العميل (أرقام فقط)" }
  ],
  enabled: true
)
track_tool.save!
log.call "   ✓ track_order tool"

# ──────────────── 5. Scenarios ────────────────
log.call "→ 5/10 Scenarios"

scenarios_data = [
  {
    id: 1,
    title: "البحث عن منتج",
    description: "يُفعّل عند سؤال العميل عن منتج، فئة، توفر، سعر، أو طلب اقتراحات منتجات. أمثلة: عندكم طاولات؟ أبغى كرسي مكتب، ما الأسعار، هل عندكم..",
    instruction: <<~INST
      أنت scenario_1_agent المتخصص في البحث عن منتجات كواي داو. عندما يسأل العميل عن منتج، فئة، توفر، أو سعر:

      1. استخدم [البحث عن منتج](tool://search_products) فوراً للبحث في كتالوج 9,796 منتج.
      2. مرر استعلام دقيق (مثل: كرسي مكتب، طاولة طعام، أريكة).
      3. اعرض أفضل 3-5 نتائج بهذا التنسيق:
         • **اسم المنتج** — السعر ريال
           🔗 رابط المنتج
      4. إذا سأل عن سعر معين، فلتر بالسعر.
      5. إذا لم تجد نتائج، اقترح فئة بديلة.
      6. ابدأ ردك بـ 🤖 معك QAYDAO AI ثم تحية قصيرة.

      ⚠️ قاعدة التحويل الإلزامي:
      بعد عرض المنتجات، إذا سأل العميل عن شيء آخر (تتبع طلب، أوقات عمل، شحن، استرجاع، طلب موظف)، استخدم handoff_to_qaydao_ai فوراً. لا تقل أبداً "أنا متخصص في X فقط".

      ⚠️ لا تخترع منتجات. فقط من نتائج الأداة.
    INST
  },
  {
    id: 2,
    title: "تتبع حالة الطلب",
    description: "يُفعّل عندما يطلب العميل تتبع طلب، يسأل عن حالة طلب، أو يذكر رقم طلب. أمثلة: أين طلبي، حالة طلبي رقم..، متى يوصل طلبي رقم..",
    instruction: <<~INST
      أنت scenario_2_agent المتخصص في تتبع الطلبات. عندما يذكر العميل رقم طلب أو يسأل عن حالة طلبه:

      1. إذا أعطى رقم الطلب، استخدم [تتبع الطلب](tool://track_order) فوراً.
      2. إذا لم يعطِ رقم، اطلب رقم الطلب بأدب: "تفضل برقم طلبك للتحقق من حالته 📦"
      3. بعد جلب الحالة، اعرض:
         - 📦 رقم الطلب
         - 🚚 الحالة الحالية
         - 📍 المدينة
         - 📅 الموعد المتوقع
      4. إذا "قيد التصنيع" → اشرح أن المنتج مصنوع خصيصاً (30-60 يوم).
      5. إذا فشل البحث، اعتذر واطلب التأكد من الرقم.

      ⚠️ قاعدة التحويل الإلزامي:
      بعد عرض حالة الطلب، إذا سأل العميل عن منتجات، سياسات، أوقات عمل، أو طلب موظف، استخدم handoff_to_qaydao_ai فوراً.
      🚨 لا تقل أبداً "أنا متخصص في تتبع الطلبات فقط" — حوّل تلقائياً بدون اعتذار.

      ابدأ بـ 🤖 معك QAYDAO AI
    INST
  },
  {
    id: 3,
    title: "السياسات والمعلومات العامة",
    description: "يُفعّل لأي سؤال عن السياسات والمعلومات العامة: الشحن، التوصيل، الاسترجاع، الاستبدال، الضمان، التركيب، طرق الدفع، أوقات العمل، ساعات العمل، الأقسام، عرض السعر، الحساب، الفواتير، الضريبة، B2B، استوديو التصميم، رقم خدمة العملاء، التواصل، العنوان، الفروع. وأيضاً عند الترحيب والأسئلة العامة.",
    instruction: <<~INST
      أنت scenario_3_agent المتخصص في السياسات والمعلومات العامة لكواي داو.

      🔥 ابحث أولاً في FAQs قبل الرد - استخدم captain--tools--faq_lookup.

      ابدأ بـ 🤖 معك QAYDAO AI ثم تحية: حياك / أبشر / يسعدنا تواصلك

      معرفة جاهزة:

      ⏰ أوقات العمل: الأحد-الخميس 9 ص - 6 م. إجازة: الجمعة والسبت.
      📞 خدمة العملاء: +966 54 845 6966 | info@qaydao.com
      📦 الشحن: مجاني فوق 700 ريال. جاهز 1-3 شحن + 3-7 توصيل. مصنوع خصيصاً 30-60 يوم.
      🔄 الاسترجاع: 24 ساعة من الاستلام (خلل مصنعي). استرداد 7-14 يوم عمل.
      💳 الدفع: فيزا (3% رسوم استرداد)، مدى، أبل باي، تابي/تمارا (8% رسوم).
      🏢 B2B: b2b.qaydao.com | 🎨 الاستوديو: studio.qaydao.com | 📦 التتبع: track.qaydao.com

      أسلوب الرد:
      - 2-4 أسطر، مباشر بدون حشو
      - emojis باعتدال: ✅ ⏰ 📦 🚚 🤍
      - إذا غير متأكد قل "دعني أحوّلك لموظف للتأكد"

      ⚠️ قاعدة التحويل الإلزامي:
      إذا سأل العميل عن منتج محدد، تتبع طلب، أو طلب موظف، استخدم handoff_to_qaydao_ai فوراً.
    INST
  },
  {
    id: 4,
    title: "تحويل إلى موظف بشري",
    description: "يُفعّل عند: 1) العميل يطلب موظف صراحة 2) شكوى أو غضب (زعلانة، للأسف، بشتكي، محكمة، نظام التجارة) 3) طلب استرجاع/إلغاء 4) شكوى منتج تالف 5) سؤال خارج معرفتك بعد 3 محاولات.",
    instruction: <<~INST
      أنت scenario_4_agent المتخصص في تحويل العملاء للموظف البشري.

      حوّل في هذه الحالات:
      - طلب صريح: أبغى أكلم موظف، محتاج إنسان
      - شكوى أو غضب: زعلانة، للأسف، بشتكي، محكمة، نظام التجارة
      - طلب استرجاع أو إلغاء طلب
      - شكوى عن منتج تالف، مفقود، أو غير مطابق
      - طلب B2B كبير أو تأثيث مشروع
      - فواتير، ضريبة، IBAN

      أرسل هذه الرسالة بالضبط:
      "🤝 يسعدنا تحويلك لأحد موظفي خدمة العملاء.
      سيتواصل معك أحد المسؤولين في أقرب وقت ممكن خلال ساعات العمل (الأحد-الخميس 9 ص - 6 م).
      شكراً لتفهمك وثقتك في كواي داو 🤍"
    INST
  }
]

scenarios_data.each do |data|
  s = Captain::Scenario.find_or_initialize_by(id: data[:id])
  s.assign_attributes(
    assistant_id: ASSISTANT_ID,
    account_id: ACCOUNT_ID,
    title: data[:title],
    description: data[:description],
    instruction: data[:instruction],
    enabled: true
  )
  s.save!
  log.call "   ✓ Scenario ##{data[:id]} #{data[:title]}"
end

# Remove any extra scenarios not in our spec
expected_ids = scenarios_data.map { |s| s[:id] }
Captain::Scenario.where(assistant_id: ASSISTANT_ID).where.not(id: expected_ids).destroy_all

# ──────────────── 6. Inbox bindings ────────────────
log.call "→ 6/10 Captain inbox bindings"
customer_inboxes = account.inboxes.where.not(channel_type: "Channel::Api")
customer_inboxes.each do |inbox|
  CaptainInbox.find_or_create_by(captain_assistant_id: ASSISTANT_ID, inbox_id: inbox.id)
  log.call "   ✓ inbox ##{inbox.id} #{inbox.name} (#{inbox.channel_type})"
end

# ──────────────── 7. FAQ embeddings ────────────────
log.call "→ 7/10 FAQ embeddings"
missing = Captain::AssistantResponse.where(assistant_id: ASSISTANT_ID, embedding: nil)
if missing.any?
  log.call "   ⚙ regenerating #{missing.count} missing embeddings (background)"
  missing.each do |faq|
    Captain::Llm::UpdateEmbeddingJob.perform_later(faq, "#{faq.question}: #{faq.answer}")
  end
else
  log.call "   = all #{Captain::AssistantResponse.where(assistant_id: ASSISTANT_ID).count} FAQs have embeddings"
end

# ──────────────── 8. Automation rule #3 ────────────────
log.call "→ 8/10 Automation rule #3 event"
rule = AutomationRule.find_by(id: 3)
if rule
  if rule.event_name != "conversation_opened"
    rule.update!(event_name: "conversation_opened")
    log.call "   ✓ rule #3 event set to conversation_opened"
  else
    log.call "   = rule #3 already conversation_opened"
  end
else
  log.call "   ⚠ rule #3 not found (skip)"
end

# ──────────────── 9. Auto-resolve disabled ────────────────
log.call "→ 9/10 Auto-resolve disabled"
if account.auto_resolve_duration.present?
  account.update!(auto_resolve_duration: nil)
  log.call "   ✓ auto_resolve_duration set to NULL"
else
  log.call "   = auto_resolve_duration already NULL"
end

# ──────────────── 10. Learning system table ────────────────
log.call "→ 10/10 Learning suggestions table"
exists = ActiveRecord::Base.connection.table_exists?("captain_learning_suggestions")
if exists
  log.call "   = captain_learning_suggestions table already exists"
else
  log.call "   ⚙ creating captain_learning_suggestions table"
  ActiveRecord::Base.connection.execute(<<~SQL)
    CREATE TABLE captain_learning_suggestions (
      id BIGSERIAL PRIMARY KEY,
      conversation_id BIGINT NOT NULL,
      account_id BIGINT NOT NULL DEFAULT 1,
      assistant_id BIGINT NOT NULL DEFAULT 1,
      original_question TEXT NOT NULL,
      original_agent_reply TEXT NOT NULL,
      agent_name TEXT,
      channel_type TEXT,
      suggested_question TEXT,
      suggested_answer TEXT,
      ai_reasoning TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      reviewed_by TEXT,
      reviewed_at TIMESTAMP WITH TIME ZONE,
      rejection_reason TEXT,
      created_faq_id BIGINT,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
      updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
      UNIQUE(conversation_id, original_question)
    );
    CREATE INDEX idx_cls_status ON captain_learning_suggestions(status);
    CREATE INDEX idx_cls_created ON captain_learning_suggestions(created_at DESC);
  SQL
  log.call "   ✓ table created"
end

puts ""
puts "============================================"
puts "✅ Captain configuration applied successfully"
puts "============================================"
puts "Verify with:"
puts "  curl https://chat.qaydao.com/products/login → HTTP 200"
puts "  open https://chat.qaydao.com → القائد → Playground"
puts "  monitor: /root/chat-qaydao/monitoring/monitor.py"
