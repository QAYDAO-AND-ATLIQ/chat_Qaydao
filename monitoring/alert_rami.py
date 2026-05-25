#!/usr/bin/env python3
"""
QAYDAO Alert — sends critical alerts to Rami via Email (+ optional Telegram).
Reused by monitor.py for critical conditions (key down, captain down, backlog).

Email: reuses Chatwoot's Gmail SMTP from /root/chat-qaydao/.env
Telegram: set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID in /root/chat-qaydao/alert.env

Usage:
  python3 alert_rami.py "العنوان" "النص"
  echo "النص" | python3 alert_rami.py "العنوان"
"""
import sys, os, smtplib, ssl, urllib.request, urllib.parse, json
from email.mime.text import MIMEText
from email.header import Header
from email.utils import formataddr

CHATWOOT_ENV = "/root/chat-qaydao/.env"
ALERT_ENV = "/root/chat-qaydao/alert.env"
RAMI_EMAIL = "rami@qaydao.com"


def load_env(path):
    env = {}
    if not os.path.exists(path):
        return env
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def send_email(subject, body):
    env = load_env(CHATWOOT_ENV)
    host = env.get("SMTP_ADDRESS", "smtp.gmail.com")
    port = int(env.get("SMTP_PORT", "587"))
    user = env.get("SMTP_USERNAME", "")
    pw = env.get("SMTP_PASSWORD", "")
    sender = env.get("MAILER_SENDER_EMAIL", user)
    if not user or not pw:
        return False, "SMTP credentials missing"
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = formataddr((str(Header("QAYDAO تنبيهات", "utf-8")), sender))
    msg["To"] = RAMI_EMAIL
    try:
        ctx = ssl.create_default_context()
        with smtplib.SMTP(host, port, timeout=20) as s:
            s.starttls(context=ctx)
            s.login(user, pw)
            s.sendmail(sender, [RAMI_EMAIL], msg.as_string())
        return True, "sent"
    except Exception as e:
        return False, str(e)


def send_telegram(subject, body):
    env = load_env(ALERT_ENV)
    token = env.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = env.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        return None, "telegram not configured"
    text = f"\U0001F6A8 {subject}\n\n{body}"
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
    try:
        req = urllib.request.Request(url, data=data)
        with urllib.request.urlopen(req, timeout=15) as r:
            ok = json.load(r).get("ok", False)
        return ok, "sent" if ok else "telegram api error"
    except Exception as e:
        return False, str(e)


def main():
    if len(sys.argv) < 2:
        print("usage: alert_rami.py <subject> [body]")
        sys.exit(1)
    subject = sys.argv[1]
    body = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()

    results = []
    ok_e, msg_e = send_email(subject, body)
    results.append(f"email: {'OK' if ok_e else 'FAIL ('+msg_e+')'}")
    ok_t, msg_t = send_telegram(subject, body)
    if ok_t is not None:
        results.append(f"telegram: {'OK' if ok_t else 'FAIL ('+msg_t+')'}")
    print(" | ".join(results))
    # success if at least one channel delivered
    sys.exit(0 if (ok_e or ok_t) else 2)


if __name__ == "__main__":
    main()
