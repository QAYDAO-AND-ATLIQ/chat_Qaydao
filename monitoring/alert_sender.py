"""
QAYDAO Chat — Alert Sender (v2 — Chatwoot Internal Inbox)
==========================================================
Posts alerts to a dedicated API-channel inbox in Chatwoot itself.
All admins see them in their dashboard, complete with notifications.

Logic:
  - For each unique check_id, maintain ONE conversation in the alert inbox
  - First failure → create conversation + first message
  - Subsequent failures (after dedup window) → reply on same conversation
  - Recovery → reply with "✅ تعافى" + auto-resolve the conversation

Reuse over re-creation keeps the dashboard clean and gives history per check.
"""
import json
import logging
import urllib.error
import urllib.request

import config as cfg

log = logging.getLogger("alert_sender")


def _api(method: str, path: str, body: dict | None = None) -> dict | None:
    url = f"{cfg.CHATWOOT_BASE_URL}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Content-Type": "application/json",
            "api_access_token": cfg.CHATWOOT_API_TOKEN,
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            text = r.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        body_str = e.read().decode(errors="ignore")[:400]
        log.warning(f"Chatwoot API {method} {path} → HTTP {e.code}: {body_str}")
        return None
    except Exception as e:
        log.warning(f"Chatwoot API {method} {path} → {e}")
        return None


# ──────────────── Conversation lifecycle per check_id ────────────────

def _find_open_conv_for_check(check_id: str) -> int | None:
    """Find existing open/pending conversation in alert inbox tagged with check_id."""
    res = _api(
        "GET",
        f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/conversations"
        f"?inbox_id={cfg.ALERT_INBOX_ID}&status=open&page=1"
    )
    if not res:
        return None
    data = res.get("data") if isinstance(res, dict) else None
    payload = data.get("payload") if data else (res.get("payload") if isinstance(res, dict) else None)
    if not payload:
        return None
    for conv in payload:
        labels = conv.get("labels", []) or []
        if check_id in labels:
            return conv["id"]
    return None


def _create_conversation_for_check(check_id: str, first_message: str) -> int | None:
    """Create a new conversation in the alert inbox."""
    res = _api(
        "POST",
        f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/conversations",
        {
            "source_id": cfg.ALERT_SOURCE_ID,
            "inbox_id": cfg.ALERT_INBOX_ID,
            "contact_id": cfg.ALERT_CONTACT_ID,
            "status": "open",
            "message": {"content": first_message},
            "additional_attributes": {"check_id": check_id, "auto_created": True},
        }
    )
    if not res:
        return None
    conv_id = res.get("id")
    if not conv_id:
        return None

    # Add label = check_id so we can find it next time
    _api(
        "POST",
        f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/conversations/{conv_id}/labels",
        {"labels": [check_id, "auto_monitor"]}
    )

    # Optionally assign to a specific admin
    if cfg.ALERT_ASSIGNEE_EMAIL:
        _assign_to(conv_id, cfg.ALERT_ASSIGNEE_EMAIL)

    return conv_id


def _assign_to(conv_id: int, user_email: str) -> None:
    # Look up agent id
    res = _api("GET", f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/agents")
    if not res:
        return
    agents = res if isinstance(res, list) else res.get("payload", [])
    agent = next((a for a in agents if a.get("email") == user_email), None)
    if not agent:
        return
    _api(
        "POST",
        f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/conversations/{conv_id}/assignments",
        {"assignee_id": agent["id"]}
    )


def _post_message(conv_id: int, content: str) -> bool:
    res = _api(
        "POST",
        f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/conversations/{conv_id}/messages",
        {"content": content, "message_type": "incoming"}
        # message_type=incoming so it visually comes "from" the monitor contact
        # and triggers agent notifications
    )
    return res is not None and res.get("id") is not None


def _resolve_conversation(conv_id: int) -> bool:
    res = _api(
        "POST",
        f"/api/v1/accounts/{cfg.CHATWOOT_ACCOUNT_ID}/conversations/{conv_id}/toggle_status",
        {"status": "resolved"}
    )
    return res is not None


# ──────────────── Public functions used by monitor.py ────────────────

def send_alert(check_id: str, message_ar: str) -> bool:
    if not cfg.CHATWOOT_API_TOKEN:
        log.error("CHATWOOT_API_TOKEN not set — alert dropped")
        return False

    body = f"🚨 *تنبيه نظام QAYDAO Chat*\n\n📍 الفحص: `{check_id}`\n\n{message_ar}\n\n— Auto-monitor"

    # Reuse existing open conversation for this check_id, else create new
    existing = _find_open_conv_for_check(check_id)
    if existing:
        log.info(f"[{check_id}] reusing open conversation #{existing}")
        return _post_message(existing, body)

    new_id = _create_conversation_for_check(check_id, body)
    if new_id:
        log.info(f"[{check_id}] created conversation #{new_id}")
        return True

    log.error(f"[{check_id}] failed to send alert")
    return False


def send_recovery(check_id: str, previous_message: str) -> bool:
    if not cfg.CHATWOOT_API_TOKEN:
        return False

    first_line = previous_message.splitlines()[0] if previous_message else check_id
    body = f"✅ *تعافى:* {check_id}\n\nالمشكلة السابقة: {first_line}\n\n— Auto-monitor"

    conv_id = _find_open_conv_for_check(check_id)
    if not conv_id:
        # No open conversation — recovery before alert? Just log.
        log.info(f"[{check_id}] recovery requested but no open conversation found")
        return True

    posted = _post_message(conv_id, body)
    if posted:
        _resolve_conversation(conv_id)
        log.info(f"[{check_id}] recovery posted + conversation #{conv_id} resolved")
    return posted
