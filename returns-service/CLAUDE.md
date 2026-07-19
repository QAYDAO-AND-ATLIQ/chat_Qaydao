# returns-service — QAYDAO Returns (isolated sidecar)

## ما هي الخدمة
خدمة FastAPI مستقلة لإدارة طلبات إرجاع العملاء. تعمل داخل Docker كـ **sidecar منفصل تماماً عن Chatwoot**.
- الكود: ملف واحد `app/app.py`
- قاعدة بيانات خاصة `returns` (حاوية `returns_db`, postgres 16) — **لا علاقة لها بقاعدة Chatwoot إطلاقاً**
- المنفذ الداخلي: `127.0.0.1:8091`
- تخزن `conversation_id` كمرجع فضفاض فقط (لا FK إلى Chatwoot)

## الحاويات
- `returns_service` — تطبيق FastAPI (يُعاد بناؤه عند تغيير الكود)
- `returns_db` — postgres (لا يُعاد إنشاؤها عند تحديث الكود)

⚠️ تنبيه تشغيلي: اسم مشروع compose قد يتعارض (`returns_service` مقابل `returns-service`).
لإعادة نشر الكود بأمان دون لمس الـ DB:
```
docker compose up -d --build returns_service      # يبني الصورة
docker rm -f returns_service                       # يحذف حاوية الخدمة فقط (ليس returns_db)
docker compose up -d --no-deps returns_service     # يعيد الإنشاء من الصورة الجديدة
```
تحقق دائماً: `docker exec returns_service grep -c "<دالة جديدة>" /app/app.py` قبل إعلان النجاح.

## الأدوار والصلاحيات (مفروضة server-side في `allowed_statuses_for`)
- **المحاسبة** `financial@qaydao.com` + **الإدارة** `rami@qaydao.com`: الحالات المالية فقط `will, doing, done, rejected`.
- **النذير (مدير المشتريات)** `pr@qaydao.com`: `done_salla` **فقط**.
- لا تداخل: أي محاولة لإرسال حالة خارج نطاق الدور ترجع **403**.
- تبويب "تم الإرجاع في سلة" ظاهر للجميع كمتابعة، لكن **زر** الإجراء يظهر حسب `canStatus()` (النذير فقط يرسله).

## آلية "تم التواصل" للطلبات المرفوضة
عند رفض المحاسب لطلب، يظهر تنبيه أحمر أعلى صفحة فريق خدمة العملاء (`/returns/team-requests`).
- الموظف يضغط زر **"تم التواصل"** بجانب الطلب المرفوض بعد أن يتواصل مع المحاسب.
- ذلك يستدعي `POST /returns/api/requests/{id}/contacted` الذي يضبط العمود `contacted_at` فقط.
- **حالة الطلب تبقى `rejected`** — لا يتغير أي منطق مالي.
- التنبيه الأحمر يحسب **فقط** الطلبات المرفوضة التي `contacted_at IS NULL`.
  - طلبان مرفوضان + التواصل مع واحد ⇒ التنبيه يعرض 1.
  - التواصل مع الكل ⇒ التنبيه يختفي بالكامل.
- الطلب المتواصَل معه يظهر بشارة هادئة **"مرفوض — تم التواصل"** (رمادية، لا حمراء).

## تعريب الحالات
جميع الحالات تُعرض بالعربية في الواجهة. `done_salla` تظهر للمستخدمين باسم **"تم الإرجاع في سلة"** في:
- backend `STATUS_LABELS` (يغذّي `status_label`)
- صفحة المحاسب `SL`
- صفحة فريق خدمة العملاء `SL` + badge `b-done_salla`
الكلمة الخام `done_salla` لا تظهر للمستخدمين في أي مكان.

## قاعدة البيانات
عمود متعلق بهذه الميزة:
- `contacted_at TIMESTAMPTZ NULL` — وقت تأكيد الموظف للتواصل. `NULL` = لم يتواصل. آمن/اختياري (لا يكسر أي منطق قائم).
موثّق أيضاً في `schema.sql` لتوافق إعادة التهيئة.

## النسخ الاحتياطي والاسترجاع
- `bash backup.sh` — dump قاعدة `returns` + ملفات الرفع، يحتفظ بـ30 يوماً في `/root/backups/returns/`.
- تفاصيل الاسترجاع في `ROLLBACK.md` و `BACKUP.md`.

## حدود صارمة
- ❌ لا تلمس Chatwoot ولا قاعدة بياناته إطلاقاً.
- ❌ لا تحفظ أي أسرار/كلمات مرور في Git (`.env` مستثنى عبر `.gitignore`).
- ✅ أي تعديل داخل `returns-service` وقاعدة `returns` فقط.
