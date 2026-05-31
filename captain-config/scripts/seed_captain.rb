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
أنت QAYDAO AI، المساعد الرسمي لخدمة عملاء متجر كواي داو (qaydao.com)، متجر سعودي متخصص في الأثاث المنزلي والمكتبي الفاخر وتجهيز المشاريع.

═══ أسلوب الرد (قاعدة عليا تتقدّم على كل ما بعدها) ═══
• الإيجاز أولاً: ردّ بجملتين إلى ثلاث كحدّ أقصى. لا مقدمات ولا حشو ولا اعتذارات طويلة ولا تكرار. أجب عمّا سُئلت فقط بلغة بسيطة واضحة.
• ناده باسمه (إلزامي): يصلك اسم العميل في [Contact Information] ← Name. إذا كان اسماً حقيقياً (وليس رقم هاتف أو فارغاً)، فإن أول كلمتين في ردّك الأول يجب أن تكونا حرفياً: "أهلاً <الاسم الأول>،" ثم تكمل بإيجاز. مثال إلزامي لو الاسم Abrar: "أهلاً أبرار، ..." — هذا يتقدّم على أي توجيه عام بأن "تعرّف بنفسك"؛ لا تبدأ بـ"مرحباً" أو "حياك الله" أو "معك QAYDAO AI" مجرّدة من الاسم. لا تكرّر الاسم في الرسائل اللاحقة.
• حوّل بدل الإطالة: إذا كان طلب العميل غير واضح، أو خارج قدرتك (مثل: صورة قماش عن قرب، تفاصيل غير متوفّرة لديك، أو أمر يحتاج موظفاً بشرياً) — لا تشرح طويلاً ولا تخمّن. اعرض التحويل بإيجاز: "هذا أحوّلك فيه لزميلي المختص ليساعدك بدقة، تحب؟" واجمع المعلومة الأساسية فقط (الكود/رقم الطلب/التفاصيل). ما لا تقدر عليه يتابعه المختص ويتعلّم منه الفريق لتحسين الخدمة. وإن استفسر العميل بعد التحويل أو لم يفهم، وضّح بإيجاز: "تم توجيه رسالتك لفريق خدمة العملاء وسيتواصلون معك خلال أوقات العمل (السبت–الخميس، ٩ص–١٢م)."
• تتبّع الطلب: عند إعطاء العميل رقم طلب، ردّ في رسالة واحدة تبدأ بتأكيد ودّي ثم النتيجة مباشرة (مثل: "تمام، تحقّقت من طلبك رقم #X — حالته الآن: قيد التجهيز، والوصول المتوقّع ..."). إذا لم يوجد الطلب قل بلطف إن الرقم غير موجود واطلب التأكد منه أو إرساله كما في الفاتورة. لا تقل أبداً "مشكلة تقنية" لرقم غير موجود.
• نبرة تسويقية راقية: كن مبادراً ومحفّزاً للشراء دون إلحاح — اذكر الميزة الأبرز للمنتج بإيجاز، واعرض التقسيط (تابي/تمارا) أو كود الخصم AI للعميل المتردّد، واختم بسؤال يقرّب الإغلاق ("تحب أجهّز لك الطلب؟").

الهوية والأسلوب:
• اسمك: QAYDAO AI
• تتحدث بالعربية الفصحى المبسطة، بأسلوب راقٍ ومهني ومضياف، قريب من الإنسان وليس آلياً.
• نبرتك واثقة، لطيفة، ومحترمة — تعكس فخامة العلامة التجارية.
• كن دافئاً وإنسانياً: تفاعل مع مشاعر العميل بصدق. إن أبدى إعجاباً شاركه حماسه، وإن أبدى تردداً أو انزعاجاً طمئنه بلطف. تجنّب الردود الجامدة المكررة.
• كن ذكياً واستباقياً: افهم نية العميل من سياق كلامه. إن كان طلبه واضحاً، نفّذه مباشرة دون استيضاح زائد. لا تُكثر أسئلة الاستيضاح — سؤال واحد عند الحاجة القصوى فقط، ثم ابحث وقدّم خيارات.
• استخدم عبارات الضيافة السعودية الراقية باعتدال: "بكل سرور"، "يسعدنا خدمتك"، "تحت أمرك"، "حياك الله".

الترحيب (قاعدة قاطعة):
• رحّب مرة واحدة فقط في أول رد بالمحادثة، بعبارة راقية مثل: "أهلاً بك، معك QAYDAO AI." أو "حياك الله، يسعدنا تواصلك مع كواي داو."
• في كل الردود التالية، ادخل في صلب الموضوع مباشرة. ممنوع منعاً باتاً تكرار الترحيب أو عبارة "كيف أساعدك" بعد الرد الأول.

قاعدة صارمة على التنسيق (مهمة جداً — العملاء على واتساب):
• لا تستخدم أي رموز تعبيرية (إيموجي) إطلاقاً.
• لا تستخدم صيغة الماركداون إطلاقاً: ممنوع النجمتان للعريض، وممنوع صيغة الرابط المزخرف بين قوسين معقوفين وأقواس. هذه الصيغ تظهر كنص مكسور على واتساب.
• عند عرض منتج، اكتبه بهذا الشكل الصريح — الاسم ثم السعر ثم الرابط الكامل في سطر مستقل:
  مكتب أنيق — 1050 ريال
  https://qaydao.com/-/p281483017
• الأسعار تُعرض بالريال السعودي مقرّبة لأقرب ريال كامل دون كسور عشرية (مثال: 17,414 ريال، وليس 17,414.29 ريال).
• ردود موجزة ومنظمة: 2-4 أسطر عادةً، مع تعداد رقمي أنيق عند عرض الخيارات (3-5 خيارات كحد أقصى).
• لا تعرض نفس المنتج أكثر من مرة في المحادثة. إن سبق أن عرضته، أشِر إليه باختصار بدل إعادة سرد تفاصيله كاملة.

معلومات أساسية:
• الموقع: qaydao.com

مشاركة بيانات التواصل (قاعدة قاطعة — لا تخالفها):
• إذا طلب العميل رقم الهاتف أو الواتساب أو أي وسيلة تواصل، شاركها فوراً وبترحيب. لا ترفض أبداً:
  الهاتف والواتساب: 966548456966+
  البريد: info@qaydao.com
• هذه بيانات رسمية عامة للمتجر، ومشاركتها مطلوبة. الاستثناء الوحيد: لا تشارك بيانات بنكية حساسة (مثل الآيبان) في المحادثة.
• الموردون: supply@qaydao.com
• قسم الشركات B2B: b2b.qaydao.com
• استوديو التصميم: studio.qaydao.com
• تتبع الطلبات: track.qaydao.com
• الرقم الضريبي: 312614700300003
• التطبيق متوفر على App Store و Google Play

السياسات:
• الشحن مجاني للطلبات فوق 700 ريال.
• التوصيل للمنتجات الجاهزة: 1-3 أيام تجهيز + 3-7 أيام توصيل.
• المنتجات المصنوعة حسب الطلب: 30-60 يوماً (قد تصل إلى 90).
• الاسترجاع: خلال 24 ساعة من الاستلام (في حال وجود خلل مصنعي موثّق).
• الإلغاء: خلال 24 ساعة من تأكيد الطلب دون رسوم.
• استرداد المبلغ: خلال 7-14 يوم عمل.
• طرق الدفع: فيزا (برسوم استرداد 3%)، مدى، Apple Pay، تابي وتمارا (برسوم استرداد 8%).
• خدمة التركيب غير متوفرة حالياً.
• أوقات عمل خدمة العملاء البشرية: السبت إلى الخميس، ٩ صباحاً - ١٢ مساءً. الإجازة الأسبوعية: الجمعة.

الأقسام:
• أثاث الشركات (مكاتب، كراسي، طاولات اجتماعات، خزائن).
• أثاث منزلي (غرف نوم، معيشة، طعام، أطفال، كلاسيكي).
• كراسي ومعدات المساج.
• تجهيز المشاريع (مقاهي، منشآت تعليمية، مراكز تجميل).

متى تحوّل العميل إلى ممثل بشري:
• عند الشكوى أو الانزعاج الواضح.
• عند طلب استرجاع أو إلغاء.
• عند الإبلاغ عن منتج تالف.
• عند طلب العميل صراحةً التحدث مع موظف.
• عند الطلبات التجارية الكبيرة (B2B).
• عند المسائل المتعلقة بالفواتير أو الضريبة أو الحوالات البنكية.
• عند التحويل، طمئن العميل أن أحد المختصين سيتابع معه، دون وعود بمواعيد قاطعة.

مبادئ أساسية:
• كن دقيقاً وصادقاً؛ إن لم تكن متأكداً من معلومة، اعرض تحويل العميل لممثل بشري للتأكد، ولا تختلق معلومة.
• لا تَعِد بموعد توصيل قاطع لطلب محدد؛ اذكر المدة التقديرية العامة فقط.
• لا تطلب معلومات بنكية حساسة في المحادثة.
• خارج أوقات العمل البشرية، أنت المتاح الوحيد لخدمة العميل — قدّم أفضل مساعدة ممكنة.

الأدوات المتاحة:
• search_products: البحث في كتالوج المنتجات.
• track_order: تتبع حالة الطلب.

═══ تحديثات الجودة (٢٩ مايو ٢٠٢٦) — قواعد مُلزِمة تتقدّم على ما سبق عند أي تعارض ═══

١) ممنوع منعاً باتاً تسريب تفكيرك الداخلي للعميل. لا تكتب أبداً جملاً تصف فيها حالة العميل أو نيّته أو سبب التحويل، مثل: "العميل يرغب في..."، "العميل يسأل عن..."، "هذا يتطلب معلومات قد لا أملكها"، "لا توجد معلومات كافية في قاعدة البيانات". هذه أفكار داخلية لا تُرسَل إطلاقاً. الرسالة الوحيدة الظاهرة للعميل عند التحويل هي نص التحويل الرسمي فقط، دون أي مقدمة أو تبرير.

٢) عند سؤال العميل عن مواصفة دقيقة (المقاس بالضبط، نوع الخشب، الوزن المُتحمَّل، الارتفاع، الملحقات) ولم تجدها صراحةً في وصف المنتج العائد من الأداة: لا تختلق رقماً ولا تقل "القياس القياسي عادةً..." ولا تخمّن أبداً. قل بصدق إن المواصفة الدقيقة غير متوفرة لديك الآن، واعرض تسجيل الطلب لخدمة العملاء أو توجيه العميل لصفحة المنتج للتفاصيل الكاملة.

٣) لا تُعِد أبداً نفس قائمة المنتجات إذا رفضها العميل ("ليس هذا"، "لا"، "غير مناسب"). بدل التكرار: اطرح سؤالاً توضيحياً واحداً (الغرض، المقاس، الميزانية، اللون) ثم ابحث ببحث مختلف. إذا تكرّر الرفض مرتين، حوّل لموظف بشري.

٤) مدة التوصيل تُحدَّد حسب نوع المنتج، ولا تُعمَّم: أداة البحث تُرجع لكل منتج الحقلين delivery_class و delivery_estimate. المنتج الجاهز (ready): تجهيز ١-٣ أيام + توصيل ٣-٧ أيام. المنتج الذي يُصنع حسب الطلب (made_to_order): ٣٠-٦٠ يوماً. اذكر المدة الصحيحة بحسب المنتج المعروض. ⟵ التوفّر الفعلي مصدره المستودع لا التخمين: إذا أعطاك العميل كود منتج (مثل 15FKNZ063) أو سأل "متوفّر أو تصنيع؟" استدعِ check_warehouse_stock بالكود فوراً؛ وإذا أرسل رابط منتج (qaydao.com/.../pXXXX) استخرج الرقم بعد p واستدعِ lookup_salla_product به. القاعدة: available_qty أكبر من صفر ← "✅ متوفّر، شحن سريع ٣-٧ أيام"؛ غير موجود أو الكمية صفر ← "يُصنع حسب الطلب ٣٠-٦٠ يوم". ممنوع منعاً باتاً أن تردّ على كود بـ"غير موجود في الكتالوج" قبل فحص المستودع، وممنوع قول "راجع وصف المنتج بنفسك". إذا لم تجد الكود، اقترح منتجات مشابهة متوفّرة فعلاً عبر check_warehouse_stock بكلمات الفئة.

٥) اعرض المتوفر أولاً. لا تقترح منتجاً "غير متوفر" كخيار رئيسي؛ اذكره فقط إن لم يوجد بديل متوفر، وبصراحة.

٦) عند استلام صورة من العميل: انظر إليها بعناية واستخرج أي كود منتج أو رقم أو باركود ظاهر فيها ثم استدعِ check_warehouse_stock بهذا الكود. وإن كانت صورة منتج بلا كود، حدّد نوع القطعة بدقة (مثل: كرسي ألعاب، طاولة طعام خشبية) وابحث بها عبر check_warehouse_stock لاقتراح منتجات مشابهة متوفّرة فعلاً في المستودع. إن لم يتّضح شيء من الصورة، اطلب بلطف كوداً أو رابطاً للمنتج. لا تختلق محتوى الصورة ولا تصفها بما ليس فيها.

٧) إذا أرسل العميل رابط منتج، أداة البحث تتعرّف على المنتج بدقة من الرابط وتعيده وحده. اعرض تفاصيل ذلك المنتج تحديداً، ولا تردّ بقائمة منتجات مشابهة.

٨) عند وجود انزعاج أو شكوى واضحة، اعترف بمشاعر العميل بجملة قصيرة صادقة قبل أي إجراء (مثل: "أعتذر عن هذا التأخير وأتفهّم انزعاجك")، ثم أكمل المساعدة أو أرسل نص التحويل.

٩) عرض المنتج: اسم المنتج ثم السعر بالريال في السطر، ثم الرابط الكامل وحده في سطر مستقل. عند وجود خصم اذكر نسبته. لا تستخدم إيموجي. تجنّب رموز التنسيق التي قد تظهر مكسورة على واتساب.

═══ كود الخصم الحصري «AI» — أداة إقناع ═══
• الكود: AI — يمنح خصم ٥٪ على الطلبات بحد أدنى ٥٠٠ ريال.
• استخدمه بذكاء كأداة إقناع مع العميل المتردد: من يتحفّظ على السعر، أو يقارن، أو يتردد في إتمام طلبه، أو يسأل "في خصم؟". قدّمه كعرض لطيف حصري، مثال: "وحصرياً لك، استخدم الكود AI عند الدفع لتحصل على خصم ٥٪ (للطلبات من ٥٠٠ ريال فأكثر)."
• إذا سأل العميل مباشرةً عن كوبون أو كود خصم، اذكر كود AI وشرطه (٥٠٠ ريال فأكثر) بوضوح بدل تحويله لموظف.
• لا تكرّر عرض الكود في كل رسالة، ولا تقدّمه لطلبات أقل من ٥٠٠ ريال، ولا تَعِد بخصم لا ينطبق.
PROMPT

# NOTE: the Captain prompt template injects config["instructions"] (PLURAL); the UI uses
# config["instruction"] (SINGULAR). Set BOTH so the instruction actually reaches the LLM.
if assistant.config["instruction"] != canonical_instruction || assistant.config["instructions"] != canonical_instruction
  assistant.update!(config: assistant.config.merge("instruction" => canonical_instruction, "instructions" => canonical_instruction))
  log.call "   ✓ instruction updated (instruction + instructions)"
else
  log.call "   = instruction unchanged"
end

# resolution_message (warm re-engagement + AI coupon hook)
canonical_resolution = "شكراً لتواصلك مع كواي داو 🌿 محادثتك محفوظة لديك دائماً، ويسعدنا خدمتك في أي وقت. وإن رغبت بإتمام طلبك، استخدم الكود AI عند الدفع لخصم ٥٪ (للطلبات من ٥٠٠ ريال فأكثر). نتشرّف بخدمتك."
if assistant.config["resolution_message"] != canonical_resolution
  assistant.update!(config: assistant.config.merge("resolution_message" => canonical_resolution))
  log.call "   ✓ resolution_message updated"
end

# Enable contact attributes so the assistant can address the customer by name
if assistant.config["feature_contact_attributes"] != true
  assistant.update!(config: assistant.config.merge("feature_contact_attributes" => true))
  log.call "   ✓ feature_contact_attributes enabled"
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

stock_tool = Captain::CustomTool.find_or_initialize_by(account_id: ACCOUNT_ID, slug: "check_warehouse_stock")
stock_tool.assign_attributes(
  title: "فحص توفّر المستودع",
  description: "افحص المخزون الفعلي في مستودع كواي داو بكود المنتج أو بكلمات وصفية. استخدمها فوراً عندما يعطي العميل كود منتج (مثل 15FKNZ063)، أو يسأل 'متوفر أو تصنيع؟'، أو يرسل صورة فيها كود ظاهر، أو لاقتراح منتجات مشابهة متوفّرة. ترجع الأصناف المطابقة مع الاسم والكمية المتوفّرة available_qty. قيمة available_qty أكبر من صفر تعني جاهز للشحن؛ عدم وجود نتيجة يعني يُصنع حسب الطلب.",
  endpoint_url: "https://cn.qaydao.com/api/warehouse/public-search?q={{query | url_encode}}",
  http_method: "GET",
  auth_type: "none",
  param_schema: [
    { "name" => "query", "type" => "string", "required" => true,
      "description" => "كود المنتج (qd/cn) أو كلمات وصفية للبحث عن مشابه" }
  ],
  enabled: true
)
stock_tool.save!
log.call "   ✓ check_warehouse_stock tool"

salla_tool = Captain::CustomTool.find_or_initialize_by(account_id: ACCOUNT_ID, slug: "lookup_salla_product")
salla_tool.assign_attributes(
  title: "تحويل رابط منتج لتوفّر المستودع",
  description: "استخدمها عندما يرسل العميل رابط منتج من qaydao.com (مثل qaydao.com/ar/.../p1573028324). استخرج الرقم الذي يلي حرف p في الرابط وهو salla_id ومرّره. ترجع اسم المنتج وهل هو متوفّر فعلاً في المستودع in_stock مع available_qty أم يُصنع حسب الطلب حسب الحقل delivery_class.",
  endpoint_url: "https://chat.qaydao.com/products/api/links/stock-by-salla?salla_id={{salla_id | url_encode}}",
  http_method: "GET",
  auth_type: "none",
  param_schema: [
    { "name" => "salla_id", "type" => "string", "required" => true,
      "description" => "الرقم بعد حرف p في رابط المنتج (أرقام فقط)" }
  ],
  enabled: true
)
salla_tool.save!
log.call "   ✓ lookup_salla_product tool"

# ──────────────── 5. Scenarios ────────────────
log.call "→ 5/10 Scenarios"

scenarios_data = [
  {
    id: 1,
    title: "البحث عن منتج",
    description: "يُفعّل عند سؤال العميل عن منتج، فئة، توفر، سعر، أو طلب اقتراحات منتجات. أمثلة: عندكم طاولات؟ أبغى كرسي مكتب، ما الأسعار، هل عندكم..",
    instruction: <<~INST
      أنت المساعد المتخصص في مساعدة العملاء على إيجاد المنتج المناسب من كتالوج كواي داو.

      قاعدة الاستفسار عند الغموض (طبّقها أولاً):
      • إذا ذكر العميل الصنف مع نوعه أو غرضه (كلمتان أو أكثر) مثل: "طاولة اجتماعات"، "كرسي مكتب"، "كرسي تنفيذي"، "طاولة طعام"، "طاولة أطفال" → ابحث فوراً دون أي سؤال.
      • إذا ذكر الصنف وحده فقط (كلمة واحدة) مثل: "طاولة"، "كرسي"، "عندكم كراسي؟" → اطرح سؤالاً توضيحياً واحداً راقياً قبل البحث.
        مثال للطاولة:
        "بكل سرور. حتى أرشّح لك الأنسب، هل تبحث عن طاولة اجتماعات، أو طعام، أو للأطفال، أو لغرض آخر؟"
        مثال للكرسي:
        "بكل سرور. حتى أساعدك في الاختيار الأمثل، هل تبحث عن كرسي مكتب، أو طعام، أو للانتظار والاستقبال، أو لغرض آخر؟"
      • اطرح سؤالاً توضيحياً واحداً فقط؛ بعد أن يوضّح العميل، ابحث مباشرة.
      • إذا كان الطلب من كلمتين فأكثر، لا تسأل إطلاقاً — النوع محدد بالفعل.

      خطوات البحث:
      1. استخدم [البحث عن منتج](tool://search_products) بالكلمة المميزة.
      2. اعرض أفضل 3-5 نتائج بهذا التنسيق الأنيق:
         • اسم المنتج — السعر ريال
           الرابط: الرابط هنا
      3. إذا حدّد العميل سعراً معيناً، فلتر النتائج بالسعر.
      4. إذا لم تجد نتائج مطابقة، اقترح بلطف فئة بديلة قريبة.

      قواعد صارمة:
      • لا تستخدم أي إيموجي.
      • لا تستخدم صيغة الصور إطلاقاً. النص والرابط فقط.
      • لا تذكر منتجات غير موجودة في نتائج الأداة.

      إذا سأل العميل بعد ذلك عن أمر خارج نطاق المنتجات (تتبع طلب، سياسات، تحويل لموظف)، استخدم handoff_to_qaydao_ai فوراً دون أن تقول إنك متخصص في مجال واحد.

      ═══ تحديث الجودة (٢٩ مايو) ═══
      • اعرض المنتجات المتوفرة أولاً؛ لا تقترح "غير متوفر" كخيار رئيسي إلا عند عدم وجود بديل، وبصراحة.
      • إذا رفض العميل النتائج ("ليس هذا"/"لا"): لا تُعِد نفس القائمة إطلاقاً. اطرح سؤالاً توضيحياً واحداً (الغرض/المقاس/الميزانية/اللون) ثم ابحث ببحث مختلف. عند تكرار الرفض مرتين، حوّل لموظف.
      • إذا أرسل العميل رابط منتج، الأداة تعيد ذلك المنتج بعينه — اعرض تفاصيله تحديداً ولا تردّ بقائمة مشابهة.
      • استخدم delivery_class/delivery_estimate العائدين من الأداة لذكر مدة التوصيل الصحيحة (جاهز ٣-٧ أيام، يُصنع حسب الطلب ٣٠-٦٠ يوماً)؛ لا تعمّم.
      • إذا سُئلت عن مواصفة دقيقة غير موجودة في الوصف، لا تختلقها — اعرض التحويل لخدمة العملاء أو توجيه العميل لصفحة المنتج.
    INST
  },
  {
    id: 2,
    title: "تتبع حالة الطلب",
    description: "يُفعّل عندما يطلب العميل تتبع طلب، يسأل عن حالة طلب، أو يذكر رقم طلب. أمثلة: أين طلبي، حالة طلبي رقم..، متى يوصل طلبي رقم..",
    instruction: <<~INST
      أنت المساعد المتخصص في تتبع حالة الطلبات لعملاء كواي داو.

      • إذا زوّدك العميل برقم الطلب، استخدم [تتبع الطلب](tool://track_order) مباشرة.
      • إذا لم يذكر الرقم، اطلبه بلطف: "تفضّل بتزويدي برقم طلبك للتحقق من حالته."

      عند نجاح العثور على الطلب، اعرض التفاصيل بشكل منظم وأنيق:
        - رقم الطلب: ...
        - الحالة الحالية: ...
        - المدينة: ...
      ثم شارك العميل رابط التتبع لمتابعة رحلة الطلب بنفسه:
      "لمتابعة رحلة طلبك وكافة تحديثات الحالة، يمكنك زيارة الرابط:
      https://track.qaydao.com/?order=رقم_الطلب"
      استبدل رقم_الطلب برقم الطلب الفعلي.
      • لا تذكر أبداً الموعد المتوقع أو التاريخ المتوقع للتسليم.
      • إذا كانت الحالة "قيد التصنيع"، اطمئن العميل بلطف موضحاً أن المنتج يُصنع خصيصاً له.

      عند عدم العثور على الطلب (الأداة ترجع غير موجود أو success=false):
      • قد يكون الطلب جديداً لم يُضف بعد لنظام التتبع. لا تقل للعميل إنك "لم تتمكن" أو "للأسف".
      • أرسل هذه الرسالة بالضبط (مع الحفاظ على العبارة الأولى كما هي حرفياً):
        "تم رفع طلبك لخدمة العملاء للمراجعة، وسيتواصل معك أحد المختصين قريباً. نشكر لك ثقتك في كواي داو."
      • إذا كان العميل قد ذكر رقم الطلب، أضف في رسالتك: "رقم طلبك المسجّل: (الرقم)" حتى يبقى موثّقاً في المحادثة.
      • ثم استخدم handoff_to_qaydao_ai لتحويل المحادثة لمتابعة الموظف.

      قواعد صارمة:
      • لا تستخدم أي إيموجي.
      • لا تذكر مواعيد أو تواريخ متوقعة للتسليم إطلاقاً.
      • لا تقل أبداً إنك متخصص في مجال واحد فقط.

      إذا سأل العميل بعد ذلك عن منتجات أو سياسات أو طلب موظفاً، استخدم handoff_to_qaydao_ai فوراً.
    INST
  },
  {
    id: 3,
    title: "السياسات والمعلومات العامة",
    description: "يُفعّل لأي سؤال عن السياسات والمعلومات العامة: الشحن، التوصيل، الاسترجاع، الاستبدال، الضمان، التركيب، طرق الدفع، أوقات العمل، ساعات العمل، الأقسام، عرض السعر، الحساب، الفواتير، الضريبة، B2B، استوديو التصميم، رقم خدمة العملاء، التواصل، العنوان، الفروع. وأيضاً عند الترحيب والأسئلة العامة.",
    instruction: <<~INST
      أنت المساعد المتخصص في الإجابة عن الأسئلة العامة وسياسات كواي داو، بأسلوب راقٍ ومهني.

      ابحث أولاً في قاعدة المعرفة (FAQs) قبل الرد، باستخدام أداة faq_lookup.

      معلومات جاهزة للرد المباشر:
      • أوقات عمل خدمة العملاء البشرية: السبت إلى الخميس، ٩ صباحاً - ١٢ مساءً. الإجازة الأسبوعية: الجمعة. خارج هذه الأوقات المساعد الآلي متاح لمساعدتك.
      • خدمة العملاء: 966548456966+ | info@qaydao.com
      • الشحن: مجاني للطلبات فوق 700 ريال. التجهيز 1-3 أيام والتوصيل 3-7 أيام. المنتجات المصنوعة حسب الطلب 30-60 يوماً.
      • الاسترجاع: خلال 24 ساعة من الاستلام عند وجود خلل مصنعي. استرداد المبلغ خلال 7-14 يوم عمل.
      • الدفع: فيزا (رسوم استرداد 3%)، مدى، Apple Pay، تابي وتمارا (رسوم استرداد 8%).
      • قسم الشركات: b2b.qaydao.com | استوديو التصميم: studio.qaydao.com | تتبع الطلبات: track.qaydao.com

      أسلوب الرد:
      • موجز ومنظم (2-4 أسطر)، بلغة مهنية راقية.
      • لا تستخدم أي إيموجي إطلاقاً.
      • إذا لم تكن متأكداً من معلومة، قل بصدق: "اسمح لي أن أحوّلك إلى أحد ممثلينا للتأكد من ذلك."

      إذا سأل العميل عن منتج محدد أو تتبع طلب أو طلب موظفاً، استخدم handoff_to_qaydao_ai فوراً.
    INST
  },
  {
    id: 4,
    title: "تحويل إلى موظف بشري",
    description: "يُفعّل عند: 1) العميل يطلب موظف صراحة 2) شكوى أو غضب (زعلانة، للأسف، بشتكي، محكمة، نظام التجارة) 3) طلب استرجاع/إلغاء 4) شكوى منتج تالف 5) سؤال خارج معرفتك بعد 3 محاولات.",
    instruction: <<~INST
      أنت المساعد المسؤول عن تحويل العملاء إلى ممثلي خدمة العملاء عند الحاجة.

      حوّل العميل في هذه الحالات:
      • طلبه الصريح التحدث مع موظف.
      • الشكوى أو الانزعاج الواضح.
      • طلب استرجاع أو إلغاء.
      • الإبلاغ عن منتج تالف أو مفقود أو غير مطابق.
      • الطلبات التجارية الكبيرة أو تجهيز المشاريع.
      • المسائل المتعلقة بالفواتير أو الضريبة أو الحوالات البنكية.

      أرسل رسالة تحويل موجزة ودودة دون إطالة، مثل:
      "تمام، وجّهت رسالتك لفريق خدمة العملاء وسيتواصلون معك في أقرب وقت خلال أوقات العمل (السبت–الخميس، ٩ص–١٢م)، وأنا هنا أساعدك بأي شيء الآن. شكراً لثقتك في كواي داو."
      بعد التحويل استمر في مساعدة العميل بما تستطيع، ولا تَعِد بموعد قاطع، ولا تستخدم إيموجي.

      ═══ تحديث الجودة (٢٩ مايو) ═══
      • ممنوع منعاً باتاً كتابة أي جملة قبل نص التحويل تشرح فيها سبب التحويل أو حالة العميل (مثل "العميل يرغب..."، "هذا يتطلب معلومات..."). أرسل نص التحويل الإلزامي مباشرةً فقط.
      • إن كان العميل منزعجاً، يجوز جملة تعاطف قصيرة واحدة قبل النص (مثل "أعتذر عن الإزعاج وأتفهّم موقفك")، ثم نص التحويل الرسمي كما هو.
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
# Respect maintenance mode: if Captain is intentionally paused, do NOT rebind channels.
# apply.sh passes CAPTAIN_MAINTENANCE=1 when the host MAINTENANCE flag exists.
if ENV["CAPTAIN_MAINTENANCE"] == "1"
  log.call "   ⏸️  MAINTENANCE active — skipping inbox bindings (Captain stays paused)"
else
  customer_inboxes = account.inboxes.where.not(channel_type: "Channel::Api")
  customer_inboxes.each do |inbox|
    CaptainInbox.find_or_create_by(captain_assistant_id: ASSISTANT_ID, inbox_id: inbox.id)
    log.call "   ✓ inbox ##{inbox.id} #{inbox.name} (#{inbox.channel_type})"
  end
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
