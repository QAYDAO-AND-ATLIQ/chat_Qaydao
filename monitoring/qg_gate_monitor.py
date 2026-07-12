#!/usr/bin/env python3
"""
QAYDAO — Quality Guard gate monitor (weekly email).
Watches the qg_alert_types enforcement gate: cap violations (= gate failed to
suppress), disabled types, unlimited types that show flooding, and a 7-day
per-type summary with week-over-week trend.
Run via cron Sundays ~09:00 Asia/Riyadh. SMTP creds are read at runtime from
chat-qaydao/.env (no secrets stored in this file). READ-ONLY — never writes to DB.
"""
import subprocess, smtplib, sys, argparse, html, re
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr
from datetime import datetime
from zoneinfo import ZoneInfo

RIYADH = ZoneInfo("Asia/Riyadh")
ENV_FILE = "/root/chat-qaydao/.env"
SETTINGS_URL = "https://chat.qaydao.com/quality-guard/"
# When the enforcement gate + repeat caps went live. Alerts stored before this
# moment never passed through the gate, so they can't count as gate failures.
GATE_ACTIVE_SINCE = "2026-07-12 07:37+00"
DEFAULT_TO = ["rami@qaydao.com"]
PG = ["docker", "exec", "quality_guard_db", "psql", "-U", "qguard",
      "-d", "quality_guard", "-t", "-A", "-F", "|", "-c"]

def q(sql):
    try:
        r = subprocess.run(PG + [sql], capture_output=True, text=True, timeout=40)
        return r.stdout.strip()
    except Exception:
        return ""

def rows(sql):
    out = []
    for ln in q(sql).splitlines():
        parts = ln.split("|")
        if parts and parts[0].strip():
            out.append([p.strip() for p in parts])
    return out

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
    d = {}
    # 1) cap violations: replicate the gate's own insert-time check retroactively.
    #    A stored alert is a real gate failure iff it was inserted AFTER the gate
    #    went live while its conversation already held >= cap alerts of the same
    #    type (exactly the `seen >= cap` condition the gate evaluates).
    #    Pre-gate flooding therefore never false-positives, and caps with 0
    #    (unlimited) are excluded entirely.
    d["violations"] = rows(
        "SELECT t.alert_type, t.name_ar, t.max_per_conversation, a.conversation_id, "
        "       count(*) AS leaked "
        "FROM qg_alerts a JOIN qg_alert_types t USING (alert_type) "
        f"WHERE a.created_at > '{GATE_ACTIVE_SINCE}' "
        "  AND a.created_at > now() - interval '7 days' "
        "  AND t.max_per_conversation > 0 "
        "  AND (SELECT count(*) FROM qg_alerts b "
        "       WHERE b.conversation_id = a.conversation_id "
        "         AND b.alert_type = a.alert_type "
        "         AND b.created_at < a.created_at) >= t.max_per_conversation "
        "GROUP BY 1,2,3,4 ORDER BY leaked DESC LIMIT 30;")
    # 2) disabled types (so the manager knows what the team switched off)
    d["disabled"] = rows(
        "SELECT alert_type, name_ar, "
        "to_char(updated_at AT TIME ZONE 'Asia/Riyadh','YYYY-MM-DD HH24:MI') "
        "FROM qg_alert_types WHERE NOT is_enabled ORDER BY sort_order;")
    # 3) unlimited types (cap=0) showing flooding (worst_conv >= 3) -> suggest a cap
    d["flooding"] = rows(
        "SELECT t.alert_type, t.name_ar, max(x.c) AS worst, "
        "count(*) FILTER (WHERE x.c >= 3) AS convs "
        "FROM (SELECT alert_type, conversation_id, count(*) c FROM qg_alerts "
        "      WHERE created_at > now() - interval '7 days' GROUP BY 1,2) x "
        "JOIN qg_alert_types t USING (alert_type) "
        "WHERE t.max_per_conversation = 0 "
        "GROUP BY 1,2 HAVING max(x.c) >= 3 ORDER BY worst DESC;")
    # 4) 7-day summary per type + trend vs the previous week
    d["summary"] = rows(
        "SELECT t.alert_type, t.name_ar, t.max_per_conversation, "
        "count(a.id) FILTER (WHERE a.created_at > now() - interval '7 days') AS cur, "
        "count(a.id) FILTER (WHERE a.created_at <= now() - interval '7 days' "
        "                     AND a.created_at > now() - interval '14 days') AS prev "
        "FROM qg_alert_types t LEFT JOIN qg_alerts a USING (alert_type) "
        "GROUP BY 1,2,3,t.sort_order "
        "HAVING count(a.id) FILTER (WHERE a.created_at > now() - interval '14 days') > 0 "
        "ORDER BY cur DESC, t.sort_order;")
    return d

def esc(x): return html.escape(str(x))

def trend_label(cur, prev):
    cur, prev = int(cur), int(prev)
    if prev == 0:
        return ("جديد", "#b45309") if cur > 0 else ("—", "#999")
    delta = (cur - prev) * 100 // prev
    if delta > 10:  return (f"▲ {delta}%", "#c62828")
    if delta < -10: return (f"▼ {abs(delta)}%", "#2e7d32")
    return ("≈ ثابت", "#777")

def th(label):
    return f"<th style='padding:9px 10px;text-align:right;font-size:12px;color:#888;'>{esc(label)}</th>"

def td(val, extra=""):
    return f"<td style='padding:9px 10px;border-bottom:1px solid #eee;font-size:13px;{extra}'>{val}</td>"

def tbl(header_cells, body):
    return ("<table width='100%' cellpadding='0' cellspacing='0' "
            "style='border-collapse:collapse;background:#fff;border:1px solid #eee;border-radius:10px;overflow:hidden;'>"
            f"<tr style='background:#fafafa;'>{header_cells}</tr>{body}</table>")

def section(title, inner):
    return f"<p style='font-size:16px;font-weight:700;margin:26px 0 8px;'>{title}</p>{inner}"

def build_html(d, day_label):
    parts = []
    # 1) violations — the only true failure signal
    if d["violations"]:
        body = ""
        for atype, name, cap, conv, leaked in d["violations"]:
            body += ("<tr style='background:#fdeeee;'>"
                     + td(f"<b>{esc(name)}</b><br><span style='font-size:11px;color:#999;direction:ltr;unicode-bidi:isolate;'>{esc(atype)}</span>")
                     + td(esc(cap)) + td(f"<b style='color:#c62828;'>{esc(leaked)}</b>")
                     + td(f"<a href='https://chat.qaydao.com/app/accounts/1/conversations/{esc(conv)}' style='color:#2b6cb0;text-decoration:none;'>#{esc(conv)} ↗</a>")
                     + "</tr>")
        parts.append(section("🔴 تجاوزات الحد — البوابة لم تقمع (خلل حقيقي يستدعي فحصاً)",
                     tbl(th("النوع")+th("الحد")+th("تنبيهات تسرّبت")+th("المحادثة"), body)))
    else:
        parts.append("<p style='font-size:15px;color:#2e7d32;margin:26px 0 8px;'>✅ لا تجاوزات للحدود — البوابة تقمع كما يجب.</p>")
    # 2) disabled types
    if d["disabled"]:
        body = ""
        for atype, name, when in d["disabled"]:
            body += ("<tr>" + td(f"<b>{esc(name)}</b><br><span style='font-size:11px;color:#999;direction:ltr;unicode-bidi:isolate;'>{esc(atype)}</span>")
                     + td(esc(when), "color:#777;") + "</tr>")
        parts.append(section("⏸️ أنواع موقوفة حالياً (أوقفها الفريق من اللوحة)",
                     tbl(th("النوع")+th("آخر تعديل (الرياض)"), body)))
    else:
        parts.append("<p style='font-size:14px;color:#555;margin:20px 0 8px;'>كل الأنواع مفعّلة — لا شيء موقوف.</p>")
    # 3) flooding on unlimited types
    if d["flooding"]:
        body = ""
        for atype, name, worst, convs in d["flooding"]:
            body += ("<tr style='background:#fff8e6;'>"
                     + td(f"<b>{esc(name)}</b><br><span style='font-size:11px;color:#999;direction:ltr;unicode-bidi:isolate;'>{esc(atype)}</span>")
                     + td(f"<b>{esc(worst)}</b> في محادثة واحدة") + td(esc(convs)) + "</tr>")
        parts.append(section("🟠 أنواع بلا حد أظهرت إغراقاً — يُقترح ضبط حد لها من اللوحة",
                     tbl(th("النوع")+th("الأسوأ")+th("محادثات ≥3"), body)))
    # 4) summary + trend
    if d["summary"]:
        body = ""
        for atype, name, cap, cur, prev in d["summary"]:
            t_label, t_color = trend_label(cur, prev)
            cap_label = "بلا حد" if cap == "0" else cap
            body += ("<tr>" + td(f"<b>{esc(name)}</b>")
                     + td(esc(cur)) + td(esc(prev), "color:#777;")
                     + td(f"<b style='color:{t_color};'>{t_label}</b>") + td(esc(cap_label), "color:#777;") + "</tr>")
        parts.append(section("📊 ملخص آخر ٧ أيام حسب النوع",
                     tbl(th("النوع")+th("هذا الأسبوع")+th("الأسبوع السابق")+th("الاتجاه")+th("الحد"), body)))
    button = (f"<div style='text-align:center;margin:30px 0 6px;'>"
              f"<a href='{SETTINGS_URL}' style='background:#1f6feb;color:#fff;text-decoration:none;"
              f"padding:12px 28px;border-radius:10px;font-size:14px;font-weight:700;display:inline-block;'>"
              f"فتح إعدادات الجودة — قواعد التنبيهات ↗</a></div>")
    return (f"<!DOCTYPE html><html dir='rtl' lang='ar'><body style='margin:0;background:#f4f5f7;font-family:Tahoma,\"Segoe UI\",Arial,sans-serif;'>"
            "<div style='max-width:640px;margin:0 auto;padding:24px;'>"
            "<div style='background:#31485e;border-radius:14px 14px 0 0;padding:22px 24px;'>"
            "<div style='color:#fff;font-size:20px;font-weight:700;'>🛡️ كواي داو — مراقبة بوابة Quality Guard</div>"
            f"<div style='color:#c9d6e2;font-size:13px;margin-top:4px;'>{esc(day_label)} · تقرير أسبوعي · كل الأوقات بتوقيت الرياض</div></div>"
            "<div style='background:#fff;border-radius:0 0 14px 14px;padding:20px 18px;'>"
            + "".join(parts) + button +
            "<p style='font-size:12px;color:#999;margin-top:26px;border-top:1px solid #eee;padding-top:12px;'>"
            "تقرير قراءة فقط — لا يعدّل أي بيانات. فحص التجاوز يستنسخ شرط البوابة نفسه "
            "ولا يحتسب إلا التنبيهات المخزّنة بعد تفعيل الحدود (2026-07-12) — "
            "الإغراق الأقدم لا يظهر هنا كخلل.</p>"
            "</div></div></body></html>")

def build_text(d):
    lines = ["كواي داو — مراقبة بوابة Quality Guard (آخر ٧ أيام)", ""]
    if d["violations"]:
        lines.append(f"🔴 تجاوزات الحد ({len(d['violations'])}) — البوابة لم تقمع:")
        for atype, name, cap, conv, leaked in d["violations"]:
            lines.append(f"- {name} [{atype}]: الحد {cap} لكن تسرّب {leaked} تنبيه في المحادثة #{conv}")
    else:
        lines.append("✅ لا تجاوزات للحدود — البوابة تقمع كما يجب.")
    lines.append("")
    if d["disabled"]:
        lines.append(f"⏸️ أنواع موقوفة ({len(d['disabled'])}):")
        for atype, name, when in d["disabled"]:
            lines.append(f"- {name} [{atype}] — آخر تعديل {when}")
    else:
        lines.append("كل الأنواع مفعّلة.")
    lines.append("")
    if d["flooding"]:
        lines.append("🟠 أنواع بلا حد أظهرت إغراقاً (يُقترح ضبط حد):")
        for atype, name, worst, convs in d["flooding"]:
            lines.append(f"- {name} [{atype}]: الأسوأ {worst} في محادثة واحدة ({convs} محادثات ≥3)")
        lines.append("")
    if d["summary"]:
        lines.append("📊 ملخص آخر ٧ أيام (النوع: هذا الأسبوع / السابق):")
        for atype, name, cap, cur, prev in d["summary"]:
            lines.append(f"- {name}: {cur} / {prev} (حد: {'بلا حد' if cap=='0' else cap})")
    lines.append("")
    lines.append(f"الإعدادات: {SETTINGS_URL}")
    return "\n".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="print report, no email")
    ap.add_argument("--test", help="send only to this single address (preview)")
    ap.add_argument("--to", help="comma-separated recipients (overrides default)")
    args = ap.parse_args()
    day_label = datetime.now(tz=RIYADH).strftime("%Y-%m-%d")
    d = gather()
    if args.dry_run:
        print(build_text(d)); return
    env = load_env()
    host = env.get("SMTP_ADDRESS"); port = int(env.get("SMTP_PORT", "587"))
    user = env.get("SMTP_USERNAME"); pwd = env.get("SMTP_PASSWORD")
    sender_raw = env.get("MAILER_SENDER_EMAIL", "QAYDAO <support@qaydao.com>")
    m = re.search(r"<([^>]+)>", sender_raw); from_addr = m.group(1) if m else sender_raw
    if not (host and user and pwd):
        print("SMTP config missing in .env"); sys.exit(1)
    recipients = [args.test] if args.test else (args.to.split(",") if args.to else DEFAULT_TO)
    recipients = [r.strip() for r in recipients if r.strip()]
    msg = MIMEMultipart("alternative")
    subj = f"مراقبة بوابة Quality Guard — {day_label}"
    if d["violations"]: subj = "🔴 " + subj + f" — {len(d['violations'])} تجاوز"
    if args.test: subj = "[تجريبي] " + subj
    msg["Subject"] = subj
    msg["From"] = formataddr(("كواي داو - مراقبة الجودة", from_addr))
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
