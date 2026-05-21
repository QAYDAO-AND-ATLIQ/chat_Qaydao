"""
QAYDAO Chat — Monitoring & Alert Configuration (v2 — Internal Inbox)
=====================================================================
Alerts are posted to a dedicated Chatwoot API inbox (id=7).
All admins are members → alerts appear in their dashboard immediately.
No external WhatsApp number required.
"""
import os
from pathlib import Path

# ───────── Chatwoot connection ─────────
CHATWOOT_BASE_URL = "https://chat.qaydao.com"
CHATWOOT_API_TOKEN = os.getenv("CHATWOOT_API_TOKEN", "")  # admin@qaydao.com access_token
CHATWOOT_ACCOUNT_ID = 1

# ───────── Alert inbox (API channel) — created via setup ─────────
ALERT_INBOX_ID = 7
ALERT_CONTACT_ID = 38583
ALERT_SOURCE_ID = "38489192-1d39-4cd2-9c14-2b55d96e624b"

# Used to reference original inboxes in alert messages
WIDGET_INBOX_ID = 3
WHATSAPP_INBOX_ID = 5

# ───────── Monitoring thresholds ─────────
WIDGET_BRIDGE_CONTAINER = "widget_bridge"

EXPECT_CAPTAIN_OPEN_AI_API_KEY = True

# Error rate
ERROR_THRESHOLD_COUNT = 3
ERROR_WINDOW_MINUTES = 15

# Silence detector — only during peak hours
SILENCE_HOURS_THRESHOLD = 6
PEAK_HOUR_START = 10
PEAK_HOUR_END = 22

# Captain runtime errors
CAPTAIN_ERROR_THRESHOLD = 5
CAPTAIN_ERROR_WINDOW_MIN = 10

# Auto-resolve guard
EXPECT_AUTO_RESOLVE_DISABLED = True

# ───────── Dedup ─────────
ALERT_DEDUP_MINUTES = 60
DEDUP_REDIS_URL = "redis://chatwoot-redis:6379/4"

# ───────── State + logs ─────────
STATE_FILE = Path("/root/chat-qaydao/monitoring/active_alerts.json")
LOG_FILE = Path("/var/log/widget-bridge-monitor.log")

# ───────── Behavior ─────────
DRY_RUN = os.getenv("MONITOR_DRY_RUN", "false").lower() == "true"
SEND_RECOVERY_MESSAGES = True

# When a NEW alert posts, also assign it to a specific admin so they get notified.
# Set to None to leave unassigned (still visible in tab "All").
ALERT_ASSIGNEE_EMAIL = "rami@qaydao.com"
