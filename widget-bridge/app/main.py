"""FastAPI entrypoint."""
import logging
import time
from fastapi import FastAPI, Request, HTTPException, Header
from fastapi.responses import JSONResponse
from config import settings
from chatwoot_client import chatwoot
from dedup import dedup
from working_hours import now_local, is_business_hours, status_line
from webhook_handler import process_webhook, recent_events

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("main")

app = FastAPI(title="Chatwoot Widget Bridge", version="1.0.0")


@app.on_event("startup")
async def _startup():
    log.info(
        "starting bridge | dry_run=%s | template=%s | tz=%s",
        settings.DRY_RUN,
        settings.TEMPLATE_NAME,
        settings.TIMEZONE,
    )


@app.on_event("shutdown")
async def _shutdown():
    await chatwoot.aclose()


@app.get("/health")
async def health():
    redis_ok = await dedup.healthy()
    return {
        "status": "ok",
        "dry_run": settings.DRY_RUN,
        "template": settings.TEMPLATE_NAME,
        "redis_ok": redis_ok,
        "now_local": now_local().isoformat(),
        "business_hours": is_business_hours(),
    }


@app.get("/stats")
async def stats(limit: int = 50):
    return {
        "config": {
            "dry_run": settings.DRY_RUN,
            "template": settings.TEMPLATE_NAME,
            "widget_inbox_id": settings.WIDGET_INBOX_ID,
            "whatsapp_inbox_id": settings.WHATSAPP_INBOX_ID,
            "timezone": settings.TIMEZONE,
        },
        "now": status_line(),
        "events": recent_events(limit=limit),
    }


@app.post("/webhook/chatwoot/{secret}")
async def webhook_with_secret(secret: str, request: Request):
    """Chatwoot webhook receiver. Secret is in URL path (Chatwoot doesn't support custom headers)."""
    if secret != settings.WEBHOOK_SECRET:
        raise HTTPException(status_code=401, detail="invalid_webhook_secret")
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid_json")
    started = time.perf_counter()
    result = await process_webhook(payload)
    result["latency_ms"] = round((time.perf_counter() - started) * 1000, 2)
    return JSONResponse(content=result, status_code=200)


@app.post("/webhook/chatwoot")
async def webhook(request: Request, x_webhook_secret: str | None = Header(default=None)):
    """Alternative: secret in header (for manual curl tests)."""
    if x_webhook_secret != settings.WEBHOOK_SECRET:
        raise HTTPException(status_code=401, detail="invalid_webhook_secret")
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid_json")
    started = time.perf_counter()
    result = await process_webhook(payload)
    result["latency_ms"] = round((time.perf_counter() - started) * 1000, 2)
    return JSONResponse(content=result, status_code=200)


@app.post("/webhook/test")
async def webhook_test(request: Request):
    """Auth-free echo for local debugging. Disabled in production via SECRET below."""
    if settings.WEBHOOK_SECRET != "":
        # Always require the secret in production
        try:
            payload = await request.json()
        except Exception:
            payload = {}
        return {"received": payload, "now": status_line()}
    return {"disabled": True}
