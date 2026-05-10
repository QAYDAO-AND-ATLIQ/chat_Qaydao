"""Async client wrapping the Chatwoot REST API endpoints we need."""
import logging
import httpx
from typing import Any
from config import settings

log = logging.getLogger("chatwoot")


class ChatwootClient:
    def __init__(self):
        self.base = settings.CHATWOOT_BASE_URL.rstrip("/")
        self.account = settings.CHATWOOT_ACCOUNT_ID
        self.headers = {
            "api_access_token": settings.CHATWOOT_API_TOKEN,
            "Content-Type": "application/json",
        }
        self._http: httpx.AsyncClient | None = None

    async def http(self) -> httpx.AsyncClient:
        if self._http is None or self._http.is_closed:
            self._http = httpx.AsyncClient(timeout=15.0, headers=self.headers)
        return self._http

    async def aclose(self):
        if self._http is not None and not self._http.is_closed:
            await self._http.aclose()

    # ---------- Contacts ----------
    async def search_contact_by_phone(self, phone: str) -> dict | None:
        """Find a Chatwoot contact by phone number."""
        h = await self.http()
        url = f"{self.base}/api/v1/accounts/{self.account}/contacts/search"
        r = await h.get(url, params={"q": phone, "include": "contact_inboxes"})
        r.raise_for_status()
        data = r.json()
        for c in data.get("payload", []):
            if c.get("phone_number") == phone:
                return c
        return None

    async def get_contact(self, contact_id: int) -> dict:
        h = await self.http()
        url = f"{self.base}/api/v1/accounts/{self.account}/contacts/{contact_id}"
        r = await h.get(url)
        r.raise_for_status()
        return r.json().get("payload", {})

    async def get_or_create_contact_inbox(
        self, contact_id: int, inbox_id: int, source_id: str
    ) -> dict:
        """Ensure contact has a contact_inbox row in target inbox; return it."""
        contact = await self.get_contact(contact_id)
        for ci in contact.get("contact_inboxes", []):
            if ci.get("inbox", {}).get("id") == inbox_id:
                return ci
        h = await self.http()
        url = (
            f"{self.base}/api/v1/accounts/{self.account}/"
            f"contacts/{contact_id}/contact_inboxes"
        )
        r = await h.post(url, json={"inbox_id": inbox_id, "source_id": source_id})
        r.raise_for_status()
        return r.json()

    # ---------- Conversations ----------
    async def create_conversation(
        self, inbox_id: int, contact_id: int, source_id: str
    ) -> dict:
        h = await self.http()
        url = f"{self.base}/api/v1/accounts/{self.account}/conversations"
        r = await h.post(
            url,
            json={
                "inbox_id": inbox_id,
                "contact_id": contact_id,
                "source_id": source_id,
                "status": "open",
            },
        )
        r.raise_for_status()
        return r.json()

    async def send_template_message(
        self,
        conversation_id: int,
        template_name: str,
        language: str,
        category: str,
        rendered_text: str,
        processed_params: dict | None = None,
    ) -> dict:
        h = await self.http()
        url = (
            f"{self.base}/api/v1/accounts/{self.account}/"
            f"conversations/{conversation_id}/messages"
        )
        payload: dict[str, Any] = {
            "content": rendered_text,
            "message_type": "outgoing",
            "template_params": {
                "name": template_name,
                "category": category,
                "language": language,
                "namespace": "",
                "processed_params": processed_params or {},
            },
        }
        r = await h.post(url, json=payload)
        r.raise_for_status()
        return r.json()

    async def add_internal_note(self, conversation_id: int, content: str) -> dict:
        h = await self.http()
        url = (
            f"{self.base}/api/v1/accounts/{self.account}/"
            f"conversations/{conversation_id}/messages"
        )
        r = await h.post(
            url,
            json={
                "content": content,
                "message_type": "outgoing",
                "private": True,
            },
        )
        r.raise_for_status()
        return r.json()

    async def add_label(self, conversation_id: int, label: str) -> dict:
        h = await self.http()
        url = (
            f"{self.base}/api/v1/accounts/{self.account}/"
            f"conversations/{conversation_id}/labels"
        )
        r = await h.post(url, json={"labels": [label]})
        r.raise_for_status()
        return r.json()

    # ---------- WhatsApp template lookup ----------
    async def get_whatsapp_template(self, name: str, language: str) -> dict | None:
        """Fetch the template definition from the WhatsApp inbox config."""
        h = await self.http()
        url = (
            f"{self.base}/api/v1/accounts/{self.account}/"
            f"inboxes/{settings.WHATSAPP_INBOX_ID}"
        )
        r = await h.get(url)
        r.raise_for_status()
        data = r.json()
        for tpl in (data.get("message_templates") or []):
            if tpl.get("name") == name and tpl.get("language") == language:
                return tpl
        return None


chatwoot = ChatwootClient()


def render_template(template: dict, params: dict | None = None) -> str:
    """Render template components into plain text for the Chatwoot UI / log."""
    parts = []
    for comp in template.get("components", []):
        text = comp.get("text") or ""
        if not text:
            continue
        if params:
            for k, v in params.items():
                text = text.replace("{{" + str(k) + "}}", str(v))
        parts.append(text)
    return "\n\n".join(parts)
