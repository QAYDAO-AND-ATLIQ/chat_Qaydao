#!/usr/bin/env bash
# QAYDAO Chatwoot — Mailjet SMTP Setup (outbound email)
# =====================================================
# Configures Chatwoot to send outbound email via Mailjet from support@qaydao.com.
# Mailjet credentials are reused from /var/www/sales/.env (verified sender:
# support@qaydao.com is Active, plus wildcard *@qaydao.com).
#
# Run after a fresh .env or to restore SMTP settings. Then recreate containers:
#   docker compose up -d --force-recreate chatwoot-web chatwoot-sidekiq
#
# The values written to /root/chat-qaydao/.env:
#   SMTP_ADDRESS=in-v3.mailjet.com
#   SMTP_PORT=587
#   SMTP_USERNAME=<Mailjet API Key>      (from sales .env MAILJET_API_KEY)
#   SMTP_PASSWORD=<Mailjet Secret Key>   (from sales .env MAILJET_SECRET_KEY)
#   SMTP_AUTHENTICATION=login
#   SMTP_ENABLE_STARTTLS_AUTO=true
#   MAILER_SENDER_EMAIL=QAYDAO <support@qaydao.com>
#
# Branded email template: custom-theme/mailer-base.liquid (mounted via
# docker-compose into both web + sidekiq at
# /app/app/views/layouts/mailer/base.liquid).

set -euo pipefail
ENV=/root/chat-qaydao/.env
SRC=/var/www/sales/.env

K=$(grep "MAILJET_API_KEY=" "$SRC" | cut -d= -f2 | tr -d '"'"'"'"')
S=$(grep "MAILJET_SECRET" "$SRC" | cut -d= -f2 | tr -d '"'"'"'"')

python3 - "$K" "$S" <<'PY'
import sys, re
key, sec = sys.argv[1], sys.argv[2]
p = "/root/chat-qaydao/.env"; c = open(p).read()
vals = {
  "SMTP_ADDRESS":"in-v3.mailjet.com", "SMTP_PORT":"587",
  "SMTP_USERNAME":key, "SMTP_PASSWORD":sec,
  "SMTP_AUTHENTICATION":"login", "SMTP_ENABLE_STARTTLS_AUTO":"true",
  "MAILER_SENDER_EMAIL":"QAYDAO <support@qaydao.com>",
}
for k,v in vals.items():
  c = re.sub(rf'^{k}=.*$', f'{k}={v}', c, flags=re.M) if re.search(rf'^{k}=.*$', c, re.M) else c + f'\n{k}={v}'
open(p,"w").write(c)
print("✓ .env updated with Mailjet SMTP")
PY

echo "Now recreate containers:"
echo "  cd /root/chat-qaydao && docker compose up -d --force-recreate chatwoot-web chatwoot-sidekiq"
