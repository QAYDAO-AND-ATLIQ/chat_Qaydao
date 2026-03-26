# Tiledesk — QAYDAO AI Bot

البوت الذكي لنظام خدمة عملاء QAYDAO.

## الملفات
- `docker-compose-qaydao.yml` — Docker Compose معدّل بشبكة معزولة (15 حاوية)
- `.env.example` — متغيرات البيئة (انسخه لـ .env وعدّل القيم)
- `nginx-proxy.conf` — Nginx config داخلي للـ proxy
- `nginx-ai.qaydao.com.conf` — Nginx config خارجي مع SSL

## التشغيل
```bash
cd /opt/tiledesk/docker-compose
cp .env.example .env
# عدّل .env بالقيم الصحيحة
docker-compose -f docker-compose-qaydao.yml up -d
```

## الروابط
- Dashboard: https://ai.qaydao.com/dashboard/
- API: https://ai.qaydao.com/api/
