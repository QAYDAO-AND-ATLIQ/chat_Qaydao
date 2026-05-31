#!/usr/bin/env python3
"""
QAYDAO — Daily Customer-Service Digest (one aggregated email each morning).
Replaces per-event Chatwoot email notifications with a single morning summary.
Run via cron ~08:00 Asia/Riyadh. SMTP creds are read at runtime from chat-qaydao/.env
(no secrets stored in this file).
"""
import subprocess, smtplib, sys, argparse, html, re
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr
from datetime import datetime
from zoneinfo import ZoneInfo

RIYADH = ZoneInfo("Asia/Riyadh")
ENV_FILE = "/root/chat-qaydao/.env"
CONV_URL = "https://chat.qaydao.com/app/accounts/1/conversations"
DEFAULT_TO = ["fay@qaydao.com", "marwa@qaydao.com", "amira@qaydao.com", "omar@qaydao.com"]
PG = ["docker", "exec", "chatwoot_postgres", "psql", "-U", "chatwoot_user",
      "-d", "chatwoot_production", "-t", "-A", "-F", "|", "-c"]

def q(sql):
    try:
        r = subprocess.run(PG + [sql], capture_output=True, text=True, timeout=40)
        return r.stdout.strip()
    except Exception:
        return ""

def scalar(sql):
    out = q(sql)
    return (out.splitlines()[0].strip() if out else "0") or "0"

def load_env():
    env = {}
    try:
        for line in open(ENV_FILE, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    except Exception as e:
        print(f"env read failed: {e}")
    return env

def gather():
    s = "NOW() - INTERVAL '24 hours'"
    d = {}
    d["new"]      = scalar(f"SELECT COUNT(*) FROM conversations WHERE account_id=1 AND created_at > {s};")
    d["resolved"] = scalar(f"SELECT COUNT(*) FROM conversations WHERE account_id=1 AND status=1 AND last_activity_at > {s};")
    d["open"]     = scalar("SELECT COUNT(*) FROM conversations WHERE account_id=1 AND status=0;")
    d["pending"]  = scalar("SELECT COUNT(*) FROM conversations WHERE account_id=1 AND status=2;")
    d["handoffs"] = scalar(f"SELECT COUNT(DISTINCT conversation_id) FROM messages WHERE sender_type='Captain::Assistant' AND content LIKE 'Auto-handoff:%' AND created_at > {s};")
    d["inbound"]  = scalar(f"SELECT COUNT(*) FROM messages WHERE account_id=1 AND message_type=0 AND created_at > {s};")
    d["outbound"] = scalar(f"SELECT COUNT(*) FROM messages WHERE account_id=1 AND message_type=1 AND created_at > {s};")
    waiting_sql = (
        "SELECT c.display_id, COALESCE(NULLIF(ct.name,''),'عميل'), "
        "to_char(c.last_activity_at AT TIME ZONE 'Asia/Riyadh','MM-DD HH24:MI'), "
        "CASE c.status WHEN 0 THEN 'مفتوحة' WHEN 2 THEN 'معلّقة' ELSE '' END "
        "FROM conversations c LEFT JOIN contacts ct ON ct.id=c.contact_id "
        "WHERE c.account_id=1 AND c.status IN (0,2) AND c.last_activity_at > NOW()-INTERVAL '24 hours' "
        "AND (SELECT m.sender_type FROM messages m WHERE m.conversation_id=c.id AND m.message_type IN (0,1) ORDER BY m.id DESC LIMIT 1)='Contact' "
        "ORDER BY c.last_activity_at DESC LIMIT 30;"
    )
    rows = []
    for ln in q(waiting_sql).splitlines():
        parts = ln.split("|")
        if len(parts) >= 4:
            rows.append(parts)
    d["waiting"] = rows
    return d

def esc(x): return html.escape(str(x))

def build_html(d, day_label):
    def card(label, val, color):
        return (f'<td style="padding:8px;"><div style="background:{color};border-radius:12px;padding:14px 10px;text-align:center;">'
                f'<div style="font-size:26px;font-weight:700;color:#1a1a1a;">{esc(val)}</div>'
                f'<div style="font-size:13px;color:#555;margin-top:4px;">{esc(label)}</div></div></td>')
    cards = ("<table width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;'><tr>"
             + card("محادثات جديدة", d["new"], "#eef4ff")
             + card("تم حلّها", d["resolved"], "#e9f9ee")
             + card("تحويلات للفريق", d["handoffs"], "#fff4e5")
             + "</tr><tr>"
             + card("مفتوحة الآن", d["open"], "#fdeeee")
             + card("معلّقة", d["pending"], "#f3eefd")
             + card("رسائل (وارد/صادر)", f'{d["inbound"]}/{d["outbound"]}', "#eef7f7")
             + "</tr></table>")
    if d["waiting"]:
        body = ""
        for did, name, when, status in d["waiting"]:
            link = f"{CONV_URL}/{esc(did.strip())}"
            body += (f"<tr>"
                     f"<td style='padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;'>{esc(name.strip())}</td>"
                     f"<td style='padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;color:#777;'>{esc(when.strip())}</td>"
                     f"<td style='padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;'>{esc(status.strip())}</td>"
                     f"<td style='padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;'><a href='{link}' style='color:#2b6cb0;text-decoration:none;'>فتح #{esc(did.strip())} ↗</a></td>"
                     f"</tr>")
        waiting_tbl = (f"<p style='font-size:16px;font-weight:700;margin:26px 0 8px;'>⏳ محادثات تنتظر ردّ الفريق ({len(d['waiting'])})</p>"
                       "<table width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;background:#fff;border:1px solid #eee;border-radius:10px;overflow:hidden;'>"
                       "<tr style='background:#fafafa;'>"
                       "<th style='padding:9px 10px;text-align:right;font-size:12px;color:#888;'>العميل</th>"
                       "<th style='padding:9px 10px;text-align:right;font-size:12px;color:#888;'>آخر نشاط</th>"
                       "<th style='padding:9px 10px;text-align:right;font-size:12px;color:#888;'>الحالة</th>"
                       "<th style='padding:9px 10px;text-align:right;font-size:12px;color:#888;'>الرابط</th>"
                       f"</tr>{body}</table>")
    else:
        waiting_tbl = "<p style='font-size:15px;color:#2e7d32;margin:26px 0;'>✅ لا توجد محادثات تنتظر ردّ الفريق حالياً — عمل رائع!</p>"
    return (f"<!DOCTYPE html><html dir='rtl' lang='ar'><body style='margin:0;background:#f4f5f7;font-family:Tahoma,\"Segoe UI\",Arial,sans-serif;'>"
            "<div style='max-width:640px;margin:0 auto;padding:24px;'>"
            "<div style='background:#5a6b4d;border-radius:14px 14px 0 0;padding:22px 24px;'>"
            "<div style='color:#fff;font-size:20px;font-weight:700;'>كواي داو — ملخّص خدمة العملاء اليومي</div>"
            f"<div style='color:#d9e0d0;font-size:13px;margin-top:4px;'>{esc(day_label)} · آخر ٢٤ ساعة</div></div>"
            "<div style='background:#fff;border-radius:0 0 14px 14px;padding:20px 18px;'>"
            f"{cards}{waiting_tbl}"
            "<p style='font-size:12px;color:#999;margin-top:26px;border-top:1px solid #eee;padding-top:12px;'>"
            "هذا الملخّص يصلك مرة واحدة كل صباح بدلاً من إشعارات الإيميل الفورية. كل المحادثات متاحة لحظياً في لوحة Chatwoot.</p>"
            "</div></div></body></html>")

def build_text(d):
    lines = [f"كواي داو — ملخّص خدمة العملاء (آخر ٢٤ ساعة)", "",
             f"محادثات جديدة: {d['new']} | تم حلّها: {d['resolved']} | تحويلات: {d['handoffs']}",
             f"مفتوحة الآن: {d['open']} | معلّقة: {d['pending']} | رسائل وارد/صادر: {d['inbound']}/{d['outbound']}", "",
             f"محادثات تنتظر ردّ الفريق ({len(d['waiting'])}):"]
    for did, name, when, status in d["waiting"]:
        lines.append(f"- {name.strip()} ({status.strip()}, {when.strip()}): {CONV_URL}/{did.strip()}")
    if not d["waiting"]:
        lines.append("لا شيء — عمل رائع!")
    return "\n".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", help="send only to this single address (preview)")
    ap.add_argument("--to", help="comma-separated recipients (overrides default)")
    args = ap.parse_args()
    env = load_env()
    host = env.get("SMTP_ADDRESS"); port = int(env.get("SMTP_PORT", "587"))
    user = env.get("SMTP_USERNAME"); pwd = env.get("SMTP_PASSWORD")
    sender_raw = env.get("MAILER_SENDER_EMAIL", "QAYDAO <support@qaydao.com>")
    m = re.search(r"<([^>]+)>", sender_raw); from_addr = m.group(1) if m else sender_raw
    if not (host and user and pwd):
        print("SMTP config missing in .env"); sys.exit(1)
    recipients = [args.test] if args.test else (args.to.split(",") if args.to else DEFAULT_TO)
    recipients = [r.strip() for r in recipients if r.strip()]
    day_label = datetime.now(tz=RIYADH).strftime("%Y-%m-%d")
    d = gather()
    msg = MIMEMultipart("alternative")
    subj = f"ملخّص خدمة العملاء — {day_label}"
    if args.test: subj = "[تجريبي] " + subj
    msg["Subject"] = subj
    msg["From"] = formataddr(("كواي داو - خدمة العملاء", from_addr))
    msg["To"] = ", ".join(recipients)
    msg.attach(MIMEText(build_text(d), "plain", "utf-8"))
    msg.attach(MIMEText(build_html(d, day_label), "html", "utf-8"))
    try:
        srv = smtplib.SMTP(host, port, timeout=30); srv.starttls(); srv.login(user, pwd)
        srv.sendmail(from_addr, recipients, msg.as_string()); srv.quit()
        print(f"SENT ok -> {recipients}")
        print("--- TEXT PREVIEW ---"); print(build_text(d))
    except Exception as e:
        print(f"SEND FAILED: {e}"); sys.exit(1)

if __name__ == "__main__":
    main()
