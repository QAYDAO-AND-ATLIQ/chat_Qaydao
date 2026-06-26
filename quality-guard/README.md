# QAYDAO Quality Guard

نظام مراقبة جودة خدمة العملاء داخل Chatwoot — يراقب ردود الموظفين وملاحظاتهم الداخلية،
ويصدر تنبيهات داخلية (Private Notes فقط، لا يراها العميل)، مع تقارير ولوحة إدارة عربية.

يعمل كـ **sidecar معزول** بجانب Chatwoot دون تعديل جوهره (باستثناء سطر حقن واحد في الـ layout
لإظهاره داخل قسم Reports، مربوط للقراءة فقط وقابل للتراجع).

---

## المعمارية

```
Chatwoot (web/sidekiq/postgres/redis)
        │  webhook (message_created, conversation_status_changed)
        ▼
quality_guard (FastAPI, 127.0.0.1:8090)  ──►  quality_guard_db (Postgres معزول)
        │  Private Note عبر Chatwoot API
        ▼
Chatwoot conversation (تنبيه داخلي)

التقارير + الإعدادات:  https://chat.qaydao.com/quality-guard/  (داخل Reports عبر inject.js)
```

- **حاوية `quality_guard`**: FastAPI، مربوطة 127.0.0.1:8090، على شبكة `chatwoot_internal`.
- **حاوية `quality_guard_db`**: Postgres معزول (لا منفذ host).
- النداءات الداخلية لـ Chatwoot تتطلب ترويسة `X-Forwarded-Proto: https`.

---

## المكوّنات (app/)

| الملف | الوظيفة |
|------|---------|
| `app.py` | معالج webhook، تخزين التنبيهات، نشر النوت الخاص، التصعيد التلقائي، استبعاد البوتات |
| `classifier.py` | التطبيع العربي + قواميس العبارات الممنوعة + الترحيب/الختام/التقييم |
| `policy.py` | §1 مطابقة السياسات الرسمية (حتمية، بلا AI) |
| `sla.py` | تنبيه تأخر الرد الأولي (أوقات الدوام + حلقة خلفية) |
| `admin.py` | قواعد قاعدة البيانات + توثيق Chatwoot admin + سجل التدقيق |
| `report_ui.py` | صفحة التقارير + لوحة الإعدادات + مسارات الإدارة + inject.js |
| `static_inject.js` | حقن عنصري Quality Guard داخل قائمة Reports |

---

## الميزات

1. **العبارات الممنوعة**: إساءة، تحميل العميل الخطأ، تهرّب، وعود غير مؤكدة، مخاطرة سعرية/سياسة، نوت غير مهني، جدال داخلي.
2. **معايير الشات**: الترحيب، الختام، رسالة التقييم.
3. **SLA**: تأخر الرد الأولي (السبت–الخميس 9ص–8م الرياض، 5 دقائق افتراضياً).
4. **§1 السياسات الرسمية**: مقارنة ردود الموظفين بالسياسات المخزّنة (إدخال يدوي/Salla).
5. **التصعيد التلقائي**: تكرار نفس النوع 3 مرات خلال 7 أيام → خطورة high.
6. **استبعاد البوتات**: QAYDAO AI (Captain::Assistant)، بوت QG، AgentBot — البشر فقط.
7. **التقارير**: بطاقات + جدول + فلاتر + تصدير CSV/Excel، داخل Reports.
8. **لوحة الإدارة**: تعديل القواعد/السياسات/المقترحات/SLA بلا كود، بصلاحيات Chatwoot admin، مع سجل تدقيق.

---

## النشر

```bash
# 1) جهّز .env من القالب واملأ القيم الحقيقية
cp .env.template .env && nano .env

# 2) أنشئ الشبكة الخارجية إن لم تكن موجودة
docker network create chatwoot_internal 2>/dev/null || true

# 3) ابنِ وشغّل
docker compose -p quality_guard up -d --build quality_guard

# 4) طبّق المخطط
docker exec -i quality_guard_db psql -U qguard -d quality_guard < schema.sql

# 5) الصحة
curl -s http://127.0.0.1:8090/health
```

### حقن Reports
- انسخ `cw-patch/vueapp.html.erb` (يحوي سطر `<script src=".../quality-guard/inject.js">`) واربطه للقراءة فقط في خدمة chatwoot-web.
- أضف موقع `/quality-guard` في nginx → `127.0.0.1:8090`.
- راجع `ROLLBACK_reports_injection.md` لخطة التراجع.

---

## الأمان والخطوط الحمراء

- كل التنبيهات **Private Notes فقط** — لا يراها العميل.
- `chatwoot_production` للقراءة فقط.
- لا تعديل لـ Chatwoot core (سوى سطر الحقن المربوط، قابل للتراجع).
- لا restart شامل · لا حذف بيانات Chatwoot.
- **لا تُرفع الأسرار**: `.env` مستبعد عبر `.gitignore`. استخدم `.env.template`.

---

## قاعدة البيانات (quality_guard_db)

`qg_alerts` · `qg_events` · `qg_seen_conversations` · `qg_pending_response` ·
`qg_policies` · `qg_rules` · `qg_settings` · `qg_audit_log`

المخطط الكامل في `schema.sql`.
