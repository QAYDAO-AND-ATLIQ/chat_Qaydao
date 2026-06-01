#!/usr/bin/env python3
"""
QAYDAO — Captain Suggestions Triage Digest (every 48h).

READ-ONLY: never modifies the DB. It classifies the current `pending`
(status=0) Captain knowledge-base suggestions into SAFE / REVIEW / REJECT
using the SAME heuristic Rami approved on 2026-06-01, then emails Rami a
single Arabic-RTL digest with one-click links to the Captain FAQs page so he
can approve/delete from the existing Chatwoot UI.

Why this exists: `extract_learning_suggestions.js` (cron 03,15) keeps
generating pending suggestions from real conversations. With no triage they
pile up (reached 880 before the first manual cleanup). This digest surfaces
them every 2 days so they never silently accumulate again.

SMTP creds are read at runtime from chat-qaydao/.env (no secrets in this file).

Usage:
  python3 captain_triage_digest.py --dry-run        # classify + print, NO email
  python3 captain_triage_digest.py --test EMAIL     # send preview to one addr
  python3 captain_triage_digest.py                  # send to DEFAULT_TO
"""
import subprocess, smtplib, sys, argparse, html, re, json
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr
from datetime import datetime
from zoneinfo import ZoneInfo

RIYADH = ZoneInfo("Asia/Riyadh")
ENV_FILE = "/root/chat-qaydao/.env"
FAQS_URL = "https://chat.qaydao.com/app/accounts/1/captain/1/faqs"
DEFAULT_TO = ["rami@qaydao.com"]
ASSISTANT_ID = 1
PG = ["docker", "exec", "chatwoot_postgres", "psql", "-U", "chatwoot_user",
      "-d", "chatwoot_production", "-t", "-A", "-c"]

# ── The approved heuristic (single source of truth) ──────────────────────────
#  REJECT_short        : answer < 15 chars (truncated / meaningless)
#  REJECT_expiry_month : answer mentions a month name (likely time-bound / stale)
#  REJECT_hard_date    : answer contains a 20xx year (customer-specific date)
#  REVIEW_personal     : question is about a specific personal order
#  REVIEW_promo        : answer mentions a discount code / promo (may expire)
#  SAFE_generic        : everything else — generic FAQ, safe to approve
BUCKET_SQL = """
  CASE
    WHEN length(trim(answer)) < 15 THEN 'REJECT_short'
    WHEN answer ~ '(يناير|فبراير|مارس|أبريل|إبريل|مايو|يونيو|يوليو|أغسطس|سبتمبر|أكتوبر|نوفمبر|ديسمبر)' THEN 'REJECT_expiry_month'
    WHEN answer ~ '20[0-9][0-9]' THEN 'REJECT_hard_date'
    WHEN question ~ '(طلبي|طلبك|طلبه|الطلب الثاني|شحنتي|شحنتك|شحنته)' THEN 'REVIEW_personal'
    WHEN answer ~ '(كود|كوبون|delivery|خصم [0-9])' THEN 'REVIEW_promo'
    ELSE 'SAFE_generic'
  END
"""

REASON_AR = {
    "REJECT_short": "إجابة قصيرة/مبتورة",
    "REJECT_expiry_month": "تذكر شهراً (صلاحية منتهية محتملة)",
    "REJECT_hard_date": "تاريخ صريح (خاص بطلب)",
    "REVIEW_personal": "سؤال طلب شخصي",
    "REVIEW_promo": "كود خصم (قد ينتهي)",
}

def q_json(sql):
    """Run a query that returns a single JSON value; parse to Python."""
    try:
        r = subprocess.run(PG + [sql], capture_output=True, text=True, timeout=60)
        out = r.stdout.strip()
        if not out or out.lower() == "null":
            return []
        return json.loads(out)
    except Exception as e:
        print(f"query failed: {e}", file=sys.stderr)
        return []

def scalar(sql):
    try:
        r = subprocess.run(PG + [sql], capture_output=True, text=True, timeout=40)
        v = r.stdout.strip().splitlines()
        return (v[0].strip() if v else "0") or "0"
    except Exception:
        return "0"

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
        print(f"env read failed: {e}", file=sys.stderr)
    return env

def gather():
    rows = q_json(f"""
      SELECT COALESCE(json_agg(t), '[]'::json) FROM (
        SELECT id,
               left(question, 110) AS q,
               left(answer, 140)   AS a,
               {BUCKET_SQL} AS bucket
        FROM captain_assistant_responses
        WHERE status = 0 AND assistant_id = {ASSISTANT_ID}
        ORDER BY id
      ) t;
    """)
    buckets = {"SAFE": [], "REVIEW": [], "REJECT": []}
    for r in rows:
        b = r["bucket"]
        group = "SAFE" if b.startswith("SAFE") else ("REVIEW" if b.startswith("REVIEW") else "REJECT")
        r["reason"] = REASON_AR.get(b, "")
        buckets[group].append(r)
    approved_total = scalar(f"SELECT count(*) FROM captain_assistant_responses WHERE status=1 AND assistant_id={ASSISTANT_ID};")
    return buckets, int(approved_total), len(rows)

def esc(x): return html.escape(str(x))

def _card(label, val, color):
    return (f'<td style="padding:8px;"><div style="background:{color};border-radius:12px;padding:14px 10px;text-align:center;">'
            f'<div style="font-size:26px;font-weight:700;color:#1a1a1a;">{esc(val)}</div>'
            f'<div style="font-size:13px;color:#555;margin-top:4px;">{esc(label)}</div></div></td>')

def _rows_table(items, show_reason):
    if not items:
        return "<p style='font-size:14px;color:#2e7d32;margin:6px 0 18px;'>لا يوجد ✅</p>"
    body = ""
    for it in items:
        reason_cell = (f"<td style='padding:8px 10px;border-bottom:1px solid #eee;font-size:12px;color:#b26a00;'>{esc(it['reason'])}</td>"
                       if show_reason else "")
        body += (f"<tr>"
                 f"<td style='padding:8px 10px;border-bottom:1px solid #eee;font-size:13px;'>{esc(it['q'])}</td>"
                 f"<td style='padding:8px 10px;border-bottom:1px solid #eee;font-size:13px;color:#444;'>{esc(it['a'])}</td>"
                 f"{reason_cell}</tr>")
    reason_h = "<th style='padding:8px 10px;text-align:right;font-size:12px;color:#888;'>السبب</th>" if show_reason else ""
    return ("<table width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;background:#fff;border:1px solid #eee;border-radius:10px;overflow:hidden;margin-bottom:18px;'>"
            "<tr style='background:#fafafa;'>"
            "<th style='padding:8px 10px;text-align:right;font-size:12px;color:#888;'>السؤال</th>"
            "<th style='padding:8px 10px;text-align:right;font-size:12px;color:#888;'>الإجابة</th>"
            f"{reason_h}</tr>{body}</table>")

def build_html(buckets, approved_total, total_pending, day_label):
    nsafe, nrev, nrej = len(buckets["SAFE"]), len(buckets["REVIEW"]), len(buckets["REJECT"])
    cards = ("<table width='100%' cellpadding='0' cellspacing='0'><tr>"
             + _card("معلّقة (إجمالي)", total_pending, "#eef4ff")
             + _card("🟢 جاهزة للاعتماد", nsafe, "#e9f9ee")
             + _card("معتمدة حالياً", approved_total, "#eef7f7")
             + "</tr><tr>"
             + _card("🟡 تحتاج مراجعة", nrev, "#fff4e5")
             + _card("🔴 مرفوضة (تبقى معلّقة)", nrej, "#fdeeee")
             + _card("", "", "#ffffff")
             + "</tr></table>")
    cta = (f"<div style='text-align:center;margin:20px 0 26px;'>"
           f"<a href='{FAQS_URL}' style='background:#5a6b4d;color:#fff;text-decoration:none;"
           f"padding:13px 28px;border-radius:10px;font-size:15px;font-weight:700;display:inline-block;'>"
           f"افتح صفحة الردود لاعتمادها بضغطة ↗</a></div>")
    safe_preview = buckets["SAFE"][:20]
    more_safe = (f"<p style='font-size:13px;color:#777;'>… و{nsafe-20} ردّ إضافي جاهز (افتح الصفحة لرؤية الكل).</p>"
                 if nsafe > 20 else "")
    sections = (
        f"<p style='font-size:16px;font-weight:700;margin:24px 0 6px;color:#2e7d32;'>🟢 جاهزة للاعتماد ({nsafe})</p>"
        f"{_rows_table(safe_preview, False)}{more_safe}"
        f"<p style='font-size:16px;font-weight:700;margin:24px 0 6px;color:#b26a00;'>🟡 تحتاج مراجعتك ({nrev})</p>"
        f"{_rows_table(buckets['REVIEW'], True)}"
        f"<p style='font-size:16px;font-weight:700;margin:24px 0 6px;color:#c0392b;'>🔴 مرفوضة — تبقى معلّقة ({nrej})</p>"
        f"{_rows_table(buckets['REJECT'], True)}"
    )
    return (f"<!DOCTYPE html><html dir='rtl' lang='ar'><body style='margin:0;background:#f4f5f7;font-family:Tahoma,\"Segoe UI\",Arial,sans-serif;'>"
            "<div style='max-width:680px;margin:0 auto;padding:24px;'>"
            "<div style='background:#5a6b4d;border-radius:14px 14px 0 0;padding:22px 24px;'>"
            "<div style='color:#fff;font-size:20px;font-weight:700;'>كواي داو — مراجعة معرفة المساعد الذكي</div>"
            f"<div style='color:#d9e0d0;font-size:13px;margin-top:4px;'>{esc(day_label)} · تصنيف تلقائي كل ٤٨ ساعة</div></div>"
            "<div style='background:#fff;border-radius:0 0 14px 14px;padding:20px 18px;'>"
            f"{cards}{cta}{sections}"
            "<p style='font-size:12px;color:#999;margin-top:20px;border-top:1px solid #eee;padding-top:12px;'>"
            "هذا التقرير لا يعدّل أي بيانات — يصنّف فقط المقترحات المعلّقة ويعرضها لك. "
            "الاعتماد والحذف يتمّان يدوياً من صفحة الردود في Chatwoot. "
            "التصنيف heuristic: قد يحتاج بند في «جاهزة» مراجعة سريعة.</p>"
            "</div></div></body></html>")

def build_text(buckets, approved_total, total_pending):
    L = [f"كواي داو — مراجعة معرفة المساعد الذكي",
         f"معلّقة: {total_pending} | جاهزة: {len(buckets['SAFE'])} | مراجعة: {len(buckets['REVIEW'])} | مرفوضة: {len(buckets['REJECT'])} | معتمدة حالياً: {approved_total}",
         f"اعتمد بضغطة: {FAQS_URL}", ""]
    for grp, lbl in [("SAFE","جاهزة"),("REVIEW","مراجعة"),("REJECT","مرفوضة")]:
        L.append(f"== {lbl} ({len(buckets[grp])}) ==")
        for it in buckets[grp][:30]:
            extra = f" [{it['reason']}]" if it.get("reason") and grp != "SAFE" else ""
            L.append(f"- #{it['id']} {it['q']}{extra}")
        L.append("")
    return "\n".join(L)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="classify + print, no email")
    ap.add_argument("--test", help="send only to this single address")
    ap.add_argument("--to", help="comma-separated recipients")
    args = ap.parse_args()

    buckets, approved_total, total_pending = gather()
    day_label = datetime.now(tz=RIYADH).strftime("%Y-%m-%d")

    if args.dry_run:
        print(build_text(buckets, approved_total, total_pending))
        print(f"\n[dry-run] classified {total_pending} pending. No email sent.")
        return

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
    subj = f"مراجعة معرفة المساعد الذكي — {day_label} ({total_pending} معلّقة، {len(buckets['SAFE'])} جاهزة)"
    if args.test: subj = "[تجريبي] " + subj
    msg["Subject"] = subj
    msg["From"] = formataddr(("كواي داو - المساعد الذكي", from_addr))
    msg["To"] = ", ".join(recipients)
    msg.attach(MIMEText(build_text(buckets, approved_total, total_pending), "plain", "utf-8"))
    msg.attach(MIMEText(build_html(buckets, approved_total, total_pending, day_label), "html", "utf-8"))
    try:
        srv = smtplib.SMTP(host, port, timeout=30); srv.starttls(); srv.login(user, pwd)
        srv.sendmail(from_addr, recipients, msg.as_string()); srv.quit()
        print(f"SENT ok -> {recipients} | pending={total_pending} safe={len(buckets['SAFE'])}")
    except Exception as e:
        print(f"SEND FAILED: {e}"); sys.exit(1)

if __name__ == "__main__":
    main()
