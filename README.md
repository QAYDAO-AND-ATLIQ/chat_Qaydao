# QAYDAO Customer Support System

نظام خدمة العملاء المتكامل لـ QAYDAO — يجمع بين Chatwoot (إدارة المحادثات) و Tiledesk (البوت الذكي).

## المكونات

### 1. Chatwoot (chat.qaydao.com)
- نظام إدارة المحادثات والتذاكر
- 16 تصنيف عربي + 7 حقول مخصصة + 4 أقسام + 3 SLA
- Captain AI مع OpenAI
- CSAT تقييم رضا العملاء

### 2. Tiledesk (ai.qaydao.com)
- بوت ذكي يستقبل العملاء ويحل الأسئلة الشائعة تلقائياً
- Visual Designer لبناء Flows بدون كود
- RAG Knowledge Base مع Qdrant + OpenAI
- يحوّل المحادثات المعقدة لـ Chatwoot

### 3. دليل الموظفين (chat.qaydao.com/guide/)
- 17 قسم مفصّل بالعربي
- شرح كلا النظامين خطوة بخطوة

### 4. صفحة تجربة العميل (chat.qaydao.com/guide/test.html)
- صفحة تجريبية بـ Widget الشات
- 7 سيناريوهات جاهزة للتجربة

### 4. Widget Bridge (widget-bridge/) 🆕
خدمة Python تستعيد العملاء الذين يتواصلون عبر widget الموقع **خارج أوقات العمل**.

عند إنشاء محادثة في widget خارج الدوام (السبت-الخميس قبل 9ص أو بعد 12م، والجمعة كاملاً):
1. Webhook من Chatwoot → خدمة `widget_bridge` تلتقطه
2. تتحقق من ساعات العمل (Asia/Riyadh) + dedup 24 ساعة
3. ترسل قالب واتساب معتمد من Meta لرقم العميل
4. تضيف internal note للفريق ليلاحقه صباحاً

**النتيجة:** صفر عملاء ضائعين خارج الدوام. كل واحد يصبح عنده ثريد واتساب دائم مع QAYDAO.

📖 [التوثيق الكامل في widget-bridge/README.md](widget-bridge/README.md)


## الهيكل
```
├── docker-compose.yml          # Chatwoot Docker Compose
├── .env                        # Chatwoot environment
├── nginx-chat.qaydao.com.conf  # Nginx config for Chatwoot
├── guide/
│   ├── index.html              # دليل الموظفين الشامل
│   └── test.html               # صفحة تجربة العميل
├── tiledesk/
│   ├── docker-compose-qaydao.yml  # Tiledesk Docker Compose
│   ├── .env.example               # Tiledesk env template
│   ├── nginx-proxy.conf           # Internal proxy config
│   ├── nginx-ai.qaydao.com.conf   # External Nginx config
│   └── README.md                  # Tiledesk docs
└── custom-theme/               # Chatwoot branding
```

## آخر تحديث
مارس 2026 — الإصدار 2.0
