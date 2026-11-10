"""Process Chatwoot webhook events for the widget inbox."""
import asyncio
import logging
import time
from collections import deque
from datetime import datetime
from typing import Any
from config import settings
from chatwoot_client import chatwoot, render_template
from dedup import dedup
from working_hours import is_after_hours, now_local

log = logging.getLogger("handler")

# In-memory rolling stats
_events: deque[dict] = deque(maxlen=settings.STATS_BUFFER_SIZE)

# Background tasks (keep refs so they aren't GC'd mid-flight)
_bg_tasks: set = set()


def _spawn(coro) -> None:
    t = asyncio.create_task(coro)
    _bg_tasks.add(t)
    t.add_done_callback(_bg_tasks.discard)


def _mtype(m: dict) -> int:
    v = m.get("message_type")
    if isinstance(v, str):
        return {"incoming": 0, "outgoing": 1, "activity": 2, "template": 3}.get(v, -1)
    return v if isinstance(v, int) else -1


def record(entry: dict) -> None:
    entry["ts"] = datetime.utcnow().isoformat() + "Z"
    _events.appendleft(entry)


def recent_events(limit: int = 50) -> list[dict]:
    return list(_events)[:limit]


def _normalize_phone(raw: str) -> str | None:
    if not raw:
        return None
    p = raw.strip().replace(" ", "").replace("-", "")
    if not p:
        return None
    # Accept +966XXXXXXXXX, 966XXXXXXXXX, 05XXXXXXXX, 5XXXXXXXX
    if p.startswith("+"):
        digits = p[1:]
    else:
        digits = p
    if not digits.isdigit():
        return None
    if digits.startswith("00"):
        digits = digits[2:]
    if digits.startswith("966"):
        return "+" + digits
    if digits.startswith("0") and len(digits) == 10:
        return "+966" + digits[1:]
    if digits.startswith("5") and len(digits) == 9:
        return "+966" + digits
    if digits.startswith("+966"):
        return digits
    # Already E.164 with another country code — let it pass
    if len(digits) >= 10 and len(digits) <= 15:
        return "+" + digits
    return None


_TITLE_PREFIXES = {
    "eng", "eng.", "dr", "dr.", "mr", "mr.", "mrs", "mrs.", "ms", "ms.",
    "prof", "prof.", "م", "م.", "د", "د.", "أ", "أ.", "الأستاذ",
    "المهندس", "الدكتور", "الأخ", "الأخت", "الاستاذ", "أ/", "م/", "د/",
}

def _extract_first_name(full_name: str | None) -> str:
    if not full_name:
        return "عميلنا"
    parts = full_name.strip().split()
    if not parts:
        return "عميلنا"
    first = parts[0]
    if first.lower().rstrip(".:/") in _TITLE_PREFIXES and len(parts) > 1:
        return parts[1]
    return first


async def process_webhook(payload: dict[str, Any]) -> dict:
    """Main pipeline. Returns a result dict (always — never raises)."""
    out: dict[str, Any] = {
        "decision": "skip",
        "reason": None,
        "actions": [],
        "dry_run": settings.DRY_RUN,
    }

    try:
        event = payload.get("event") or payload.get("event_name")
        out["event"] = event

        if event != "conversation_created":
            out["reason"] = "not_conversation_created"
            record(out)
            return out

        # Locate conversation + contact data — Chatwoot payload shapes vary by version
        conv = payload if "id" in payload and "inbox_id" in payload else payload.get("conversation") or {}
        inbox_id = conv.get("inbox_id") or payload.get("inbox_id")
        conv_id = conv.get("id") or payload.get("id")
        out["conversation_id"] = conv_id
        out["inbox_id"] = inbox_id

        if inbox_id != settings.WIDGET_INBOX_ID:
            out["reason"] = f"wrong_inbox_{inbox_id}"
            record(out)
            return out

        # Extract contact
        meta = payload.get("meta") or {}
        contact = (
            payload.get("contact_inbox", {}).get("contact")
            or meta.get("sender")
            or {}
        )
        if not contact:
            # Last-resort: fetch the conversation and pull contact via API
            if conv_id:
                # We can't easily fetch without the contact_id, so we trust the payload
                pass

        contact_id = contact.get("id")
        contact_name = contact.get("name", "")
        raw_phone = contact.get("phone_number") or ""
        phone = _normalize_phone(raw_phone)
        out["contact_id"] = contact_id
        out["raw_phone"] = raw_phone
        out["normalized_phone"] = phone
        out["contact_name"] = contact_name

        if not phone:
            out["reason"] = "no_valid_phone"
            record(out)
            return out

        in_business = not is_after_hours()
        out["business_hours"] = in_business
        out["local_time"] = now_local().strftime("%Y-%m-%d %H:%M:%S %Z")

        # Add label always (gives the team a quick filter)
        if settings.ADD_TAG and conv_id:
            label = settings.TAG_NAME if in_business else settings.OOH_LABEL
            try:
                if not settings.DRY_RUN:
                    await chatwoot.add_label(conv_id, label)
                out["actions"].append({"add_label": label})
            except Exception as e:
                out["actions"].append({"add_label_failed": str(e)})

        if in_business:
            out["decision"] = "in_hours_no_send"
            out["reason"] = "agent_will_reply_in_widget"
            record(out)
            return out

        # ---------- After hours path ----------
        # Dedup: same phone in last 24h
        allowed = await dedup.claim(phone)
        if not allowed:
            out["decision"] = "skip_dedup"
            out["reason"] = "phone_already_pushed_within_24h"
            record(out)
            return out

        # Look up template
        template = await chatwoot.get_whatsapp_template(
            settings.TEMPLATE_NAME, settings.TEMPLATE_LANGUAGE
        )
        if not template:
            out["decision"] = "error"
            out["reason"] = f"template_not_found:{settings.TEMPLATE_NAME}"
            await dedup.release(phone)
            record(out)
            return out

        first_name = _extract_first_name(contact_name)
        # Detect templates that have {{1}} param
        body_text = next(
            (c.get("text", "") for c in template.get("components", []) if c.get("type") == "BODY"),
            "",
        )
        processed_params = {}
        if "{{1}}" in body_text:
            processed_params = {"1": first_name}
        rendered = render_template(template, processed_params if processed_params else None)
        out["template_used"] = settings.TEMPLATE_NAME
        out["rendered_preview"] = rendered[:200]

        if settings.DRY_RUN:
            out["decision"] = "would_send_dry_run"
            out["actions"].append({"would_send_template": settings.TEMPLATE_NAME})
            record(out)
            return out

        # ---------- Defer the actual send (option B) ----------
        _spawn(_deferred_ooh_send(
            widget_conv_id=conv_id, phone=phone, contact_name=contact_name,
            rendered=rendered, processed_params=processed_params,
        ))
        out["decision"] = "scheduled_ooh_send"
        out["reason"] = f"send_after_{settings.OOH_GRACE_SECONDS}s_unless_replied"
        record(out)
        return out

    except Exception as fatal:
        out["decision"] = "error"
        out["reason"] = f"fatal: {fatal}"
        log.exception("process_webhook fatal")
        record(out)
        return out


async def _deferred_ooh_send(*, widget_conv_id, phone, contact_name,
                             rendered, processed_params) -> None:
    """After-hours: wait grace, skip if replied (B), else create WA conv with
    the customer's original inquiry as a private note (A) + send template."""
    ev: dict[str, Any] = {
        "decision": "deferred", "widget_conversation_id": widget_conv_id,
        "phone": phone, "actions": [],
    }
    try:
        await asyncio.sleep(settings.OOH_GRACE_SECONDS)
        msgs = await chatwoot.get_messages(widget_conv_id)

        # B: skip if AI/agent already replied (public outgoing message)
        if settings.OOH_SKIP_IF_REPLIED and any(
            _mtype(m) == 1 and not m.get("private", False) for m in msgs
        ):
            ev["decision"] = "skipped_replied"
            ev["reason"] = "ai_or_agent_replied_within_grace"
            if settings.SEND_INTERNAL_NOTE:
                try:
                    await chatwoot.add_internal_note(
                        widget_conv_id,
                        "⏭️ تم تجاوز رسالة الواتساب التلقائية — تم الرد على العميل "
                        f"خلال {settings.OOH_GRACE_SECONDS} ثانية.")
                except Exception:
                    pass
            record(ev)
            return  # keep dedup claim (no resend within 24h)

        # A: capture the customer's original inquiry
        inquiry = next(
            ((m.get("content") or "").strip() for m in
             sorted(msgs, key=lambda x: x.get("created_at") or 0)
             if _mtype(m) == 0 and (m.get("content") or "").strip()), None)

        # create WA conversation + send template
        wa = await chatwoot.search_contact_by_phone(phone)
        if not wa or not wa.get("id"):
            ev["decision"] = "error"
            ev["reason"] = "wa_contact_not_found_in_chatwoot"
            await dedup.release(phone)
            record(ev)
            return
        await chatwoot.get_or_create_contact_inbox(
            wa["id"], settings.WHATSAPP_INBOX_ID, phone.replace("+", ""))
        wa_conv = await chatwoot.create_conversation(
            settings.WHATSAPP_INBOX_ID, wa["id"], phone.replace("+", ""))
        wa_conv_id = wa_conv.get("id")
        ev["wa_conversation_id"] = wa_conv_id

        # A: inject inquiry as a private note INSIDE the WhatsApp conversation
        note_a = (f"📩 استفسار العميل (من شات الموقع #{widget_conv_id}):\n«{inquiry}»"
                  if inquiry else
                  f"📩 العميل بدأ محادثة على شات الموقع #{widget_conv_id} (بدون نص).")
        try:
            await chatwoot.add_internal_note(wa_conv_id, note_a)
            ev["actions"].append({"inquiry_note": "added"})
        except Exception as e:
            ev["actions"].append({"inquiry_note_failed": str(e)})

        send_result = await chatwoot.send_template_message(
            wa_conv_id, settings.TEMPLATE_NAME, settings.TEMPLATE_LANGUAGE,
            settings.TEMPLATE_CATEGORY, rendered, processed_params)
        ev["actions"].append({"sent_template": settings.TEMPLATE_NAME,
                              "wa_msg_id": send_result.get("id")})

        if settings.SEND_INTERNAL_NOTE:
            try:
                await chatwoot.add_internal_note(
                    widget_conv_id,
                    "📲 تم إرسال رسالة واتساب تلقائية (خارج الدوام).\n"
                    f"القالب: {settings.TEMPLATE_NAME} | محادثة واتساب: #{wa_conv_id}")
                ev["actions"].append({"internal_note": "added"})
            except Exception as ne:
                ev["actions"].append({"internal_note_failed": str(ne)})

        ev["decision"] = "sent"
    except Exception as err:
        ev["decision"] = "error"
        ev["reason"] = f"deferred_failed: {err}"
        try:
            await dedup.release(phone)
        except Exception:
            pass
    record(ev)
