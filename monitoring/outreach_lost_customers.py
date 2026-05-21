"""
QAYDAO Chat — Outreach to Lost Customers
==========================================
Targets:
  A) Widget conversations (inbox 3) from last 7 days with ZERO agent reply
  B) Conversations auto-resolved in last 7 days (last activity != human close)

Excludes:
  - Chinese (+86) numbers (likely suppliers)
  - Phones that already received this outreach (label idempotency)

Sends WhatsApp template "ticket" (UTILITY, APPROVED, ar) via Chatwoot inbox 5.

Safe behavior:
  - 5s pause between each send (rate limit safety)
  - Labels both source + new conv with "outreach_lost_7d_v1" → no double send on rerun
  - Internal note on source conversation
  - Per-customer audit log to ./outreach_run_<timestamp>.log
"""
import json
import logging
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

# ─────────────── Config ───────────────
CHATWOOT_BASE = "https://chat.qaydao.com"
ACCOUNT_ID = 1
WIDGET_INBOX_ID = 3
WHATSAPP_INBOX_ID = 5

TEMPLATE_NAME = "ticket"
TEMPLATE_LANG = "ar"
TEMPLATE_CATEGORY = "UTILITY"
# Template body (for Chatwoot's content field - it MUST match the actual template body)
TEMPLATE_BODY = (
    "عميلنا العزيز،\n"
    "تم التواصل معك من خلال فريق خدمة العملاء بخصوص تذكرتك ولم نتلق أي استجابة حتى الآن.\n"
    "نود تذكيرك بضرورة التواصل مع خدمة العملاء خلال 24 ساعة القادمة لإتمام الإجراءات.\n"
    "في حالة عدم التواصل خلال هذه الفترة، سيتم إغلاق التذكرة تلقائيًا.\n\n"
    "نشكرك على تفهمك وتعاونك، ونسعد بخدمتك دائمًا."
)

OUTREACH_LABEL = "outreach_lost_7d_v1"
EXCLUDED_COUNTRY_CODES = ["86"]   # China

PAUSE_BETWEEN_SENDS_SEC = 5
LOOKBACK_DAYS = 7

# Token
import os
API_TOKEN = os.environ.get("CHATWOOT_API_TOKEN", "")

# Logging
ts = datetime.now().strftime("%Y%m%d_%H%M%S")
LOG_FILE = Path(f"/root/chat-qaydao/monitoring/outreach_run_{ts}.log")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("outreach")


# ─────────────── DB helper ───────────────
def db(sql):
    out = subprocess.check_output(
        ["docker", "exec", "chatwoot_postgres",
         "psql", "-U", "chatwoot_user", "-d", "chatwoot_production",
         "-t", "-A", "-F|", "-c", sql],
        text=True, timeout=30
    )
    rows = []
    for line in out.strip().splitlines():
        if line.strip():
            rows.append(line.split("|"))
    return rows


# ─────────────── API helper ───────────────
def api(method, path, body=None):
    url = f"{CHATWOOT_BASE}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Content-Type": "application/json", "api_access_token": API_TOKEN}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            txt = r.read()
            return json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        log.warning(f"API {method} {path} HTTP {e.code}: {e.read().decode(errors='ignore')[:200]}")
        return None
    except Exception as e:
        log.warning(f"API {method} {path} error: {e}")
        return None


# ─────────────── Phone normalization ───────────────
def normalize_phone(raw: str) -> str | None:
    if not raw:
        return None
    p = raw.strip().replace(" ", "").replace("-", "")
    if p.startswith("+"):
        p = p[1:]
    if not p.isdigit():
        return None
    # Fix double country code: +9660XXXXXXXXX → +966XXXXXXXXX
    if p.startswith("9660") and len(p) >= 13:
        p = "966" + p[4:]
    if p.startswith("00"):
        p = p[2:]
    if p.startswith("05") and len(p) == 10:
        p = "966" + p[1:]
    if p.startswith("5") and len(p) == 9:
        p = "966" + p
    return "+" + p


def country_code(phone_e164: str) -> str:
    """Extract first 1-3 digits as rough country code."""
    if not phone_e164.startswith("+"):
        return ""
    digits = phone_e164[1:]
    # Match by length conventions
    if digits.startswith(("966", "971", "974", "973", "965", "968", "967")):  # GCC
        return digits[:3]
    if digits.startswith(("20", "86")):
        return digits[:2]
    return digits[:3]


# ─────────────── Per-customer flow ───────────────
def find_or_create_contact_inbox(contact_id: int, phone_no_plus: str) -> bool:
    """Ensure contact has a contact_inbox in WhatsApp inbox 5 with phone as source_id."""
    res = api("GET", f"/api/v1/accounts/{ACCOUNT_ID}/contacts/{contact_id}/contactable_inboxes")
    if res:
        inboxes = res.get("payload", res) if isinstance(res, dict) else res
        for entry in inboxes if isinstance(inboxes, list) else []:
            inbox = entry.get("inbox", {})
            if inbox.get("id") == WHATSAPP_INBOX_ID:
                return True
    # Create
    r = api(
        "POST",
        f"/api/v1/accounts/{ACCOUNT_ID}/contacts/{contact_id}/contact_inboxes",
        {"inbox_id": WHATSAPP_INBOX_ID, "source_id": phone_no_plus}
    )
    return r is not None


def get_or_create_wa_conversation(contact_id: int, phone_no_plus: str) -> int | None:
    """Find open WhatsApp conv for this contact, or create one."""
    res = api("GET", f"/api/v1/accounts/{ACCOUNT_ID}/contacts/{contact_id}/conversations")
    if res:
        convs = res.get("payload", res) if isinstance(res, dict) else res
        if isinstance(convs, list):
            for c in convs:
                if c.get("inbox_id") == WHATSAPP_INBOX_ID and c.get("status") in ("open", "pending"):
                    return c["id"]
    # Create new
    r = api(
        "POST",
        f"/api/v1/accounts/{ACCOUNT_ID}/conversations",
        {"source_id": phone_no_plus, "inbox_id": WHATSAPP_INBOX_ID, "contact_id": contact_id}
    )
    return r.get("id") if r else None


def send_template_message(conv_id: int) -> dict | None:
    body = {
        "content": TEMPLATE_BODY,
        "template_params": {
            "name": TEMPLATE_NAME,
            "category": TEMPLATE_CATEGORY,
            "language": TEMPLATE_LANG,
            "processed_params": {},
        },
    }
    return api("POST", f"/api/v1/accounts/{ACCOUNT_ID}/conversations/{conv_id}/messages", body)


def add_label(conv_id: int, label: str):
    api("POST", f"/api/v1/accounts/{ACCOUNT_ID}/conversations/{conv_id}/labels",
        {"labels": [label]})


def add_internal_note(conv_id: int, content: str):
    api("POST", f"/api/v1/accounts/{ACCOUNT_ID}/conversations/{conv_id}/messages",
        {"content": content, "message_type": "outgoing", "private": True})


def conversation_has_label(conv_id: int, label: str) -> bool:
    res = api("GET", f"/api/v1/accounts/{ACCOUNT_ID}/conversations/{conv_id}/labels")
    if not res:
        return False
    labels = res.get("payload", res) if isinstance(res, dict) else res
    return label in labels if isinstance(labels, list) else False


# ─────────────── Main ───────────────
def fetch_lost_customers():
    sql = f"""
WITH widget_unanswered AS (
  SELECT c.id AS conv_id, c.contact_id, c.created_at, 'widget'::text AS reason,
         co.phone_number, COALESCE(co.name,'') AS contact_name
  FROM conversations c JOIN contacts co ON co.id = c.contact_id
  WHERE c.account_id = 1 AND c.inbox_id = {WIDGET_INBOX_ID}
    AND c.created_at >= NOW() - INTERVAL '{LOOKBACK_DAYS} days'
    AND co.phone_number IS NOT NULL AND co.phone_number <> ''
    AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id=c.id AND m.message_type=1 AND m.sender_type='User')
),
auto_resolved AS (
  SELECT c.id AS conv_id, c.contact_id, c.updated_at AS created_at, 'auto_close'::text AS reason,
         co.phone_number, COALESCE(co.name,'') AS contact_name
  FROM conversations c JOIN contacts co ON co.id = c.contact_id
  WHERE c.account_id = 1 AND c.status = 1
    AND c.updated_at >= NOW() - INTERVAL '{LOOKBACK_DAYS} days'
    AND co.phone_number IS NOT NULL AND co.phone_number <> ''
    AND NOT EXISTS (
      SELECT 1 FROM messages m WHERE m.conversation_id=c.id AND m.message_type=2
        AND m.created_at=(SELECT MAX(created_at) FROM messages WHERE conversation_id=c.id AND message_type=2)
        AND (m.content ILIKE '%مغلقة%' OR m.content ILIKE '%resolved%' OR m.content ILIKE '%حل المحادثة%'))
),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY phone_number ORDER BY created_at DESC) AS rn
  FROM (SELECT * FROM widget_unanswered UNION ALL SELECT * FROM auto_resolved) c
)
SELECT conv_id, contact_id, reason, phone_number, contact_name
FROM ranked WHERE rn=1 ORDER BY created_at DESC;
"""
    rows = db(sql)
    customers = []
    for r in rows:
        conv_id, contact_id, reason, phone, name = r
        customers.append({
            "source_conv_id": int(conv_id),
            "contact_id": int(contact_id),
            "reason": reason,
            "phone_raw": phone,
            "phone": normalize_phone(phone),
            "name": name.strip(),
        })
    return customers


def main():
    if not API_TOKEN:
        log.error("CHATWOOT_API_TOKEN env var not set")
        sys.exit(2)

    log.info(f"=== Outreach run started — log: {LOG_FILE} ===")
    log.info(f"Template: {TEMPLATE_NAME} (UTILITY) | Lookback: {LOOKBACK_DAYS}d")

    customers = fetch_lost_customers()
    log.info(f"Total candidates from DB: {len(customers)}")

    # Filter exclusions
    eligible = []
    for c in customers:
        if not c["phone"]:
            log.warning(f"  SKIP: {c['name']} — invalid phone {c['phone_raw']}")
            continue
        cc = country_code(c["phone"])
        if cc in EXCLUDED_COUNTRY_CODES:
            log.info(f"  SKIP: {c['name']} ({c['phone']}) — country code {cc} excluded")
            continue
        eligible.append(c)

    log.info(f"Eligible after exclusions: {len(eligible)}")
    log.info("─" * 60)

    sent = 0
    failed = 0
    skipped_dup = 0

    for i, cust in enumerate(eligible, 1):
        phone_no_plus = cust["phone"][1:]  # remove +
        name = cust["name"] or "عميلنا"
        prefix = f"[{i}/{len(eligible)}] {name[:20]} ({cust['phone']})"

        log.info(f"{prefix} — reason: {cust['reason']}, src_conv: #{cust['source_conv_id']}")

        # Idempotency: skip if source conv already has the outreach label
        if conversation_has_label(cust['source_conv_id'], OUTREACH_LABEL):
            log.info(f"  ↪ already labeled '{OUTREACH_LABEL}' on source — SKIP")
            skipped_dup += 1
            continue

        # Ensure contact_inbox for WhatsApp inbox 5
        if not find_or_create_contact_inbox(cust["contact_id"], phone_no_plus):
            log.error(f"  ✗ failed to create contact_inbox")
            failed += 1
            continue

        # Get/create WhatsApp conversation
        wa_conv = get_or_create_wa_conversation(cust["contact_id"], phone_no_plus)
        if not wa_conv:
            log.error(f"  ✗ failed to create WA conversation")
            failed += 1
            continue

        # Send template
        send_res = send_template_message(wa_conv)
        if not send_res or not send_res.get("id"):
            log.error(f"  ✗ template send failed (wa_conv #{wa_conv})")
            failed += 1
            continue

        msg_id = send_res.get("id")
        log.info(f"  ✓ template sent — wa_conv #{wa_conv}, msg #{msg_id}")

        # Label both conversations
        add_label(cust["source_conv_id"], OUTREACH_LABEL)
        add_label(wa_conv, OUTREACH_LABEL)

        # Internal note on source
        add_internal_note(
            cust["source_conv_id"],
            f"📲 تم إرسال outreach تلقائي عبر واتساب\n"
            f"القالب: {TEMPLATE_NAME}\n"
            f"محادثة الواتساب: #{wa_conv}\n"
            f"السبب: {cust['reason']}"
        )
        sent += 1

        if i < len(eligible):
            time.sleep(PAUSE_BETWEEN_SENDS_SEC)

    log.info("─" * 60)
    log.info(f"=== DONE — sent: {sent} | failed: {failed} | skipped_dup: {skipped_dup} ===")
    log.info(f"Full log: {LOG_FILE}")


if __name__ == "__main__":
    main()
