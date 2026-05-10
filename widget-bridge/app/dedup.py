"""Redis-based deduplication: prevent the same phone receiving multiple WA pushes within 24h."""
import logging
import redis.asyncio as redis
from config import settings

log = logging.getLogger("dedup")


class Dedup:
    def __init__(self):
        self._client: redis.Redis | None = None

    async def client(self) -> redis.Redis:
        if self._client is None:
            self._client = redis.from_url(
                settings.REDIS_URL,
                decode_responses=True,
                socket_timeout=3,
                socket_connect_timeout=3,
            )
        return self._client

    async def claim(self, phone: str) -> bool:
        """Return True if this phone was NOT processed in the last 24h.

        Returns False (already processed) if dedup key exists.
        Returns True (allowed to process) if it didn't exist before this call.
        """
        try:
            c = await self.client()
            key = f"widget_bridge:dedup:{phone}"
            ok = await c.set(key, "1", nx=True, ex=settings.DEDUP_TTL_SECONDS)
            return bool(ok)
        except Exception as e:
            log.warning("dedup.claim failed (%s) — failing OPEN (will allow send): %s", phone, e)
            # Fail-open: if Redis is down, allow the send. We'd rather risk a duplicate
            # than miss a customer.
            return True

    async def release(self, phone: str) -> None:
        try:
            c = await self.client()
            await c.delete(f"widget_bridge:dedup:{phone}")
        except Exception as e:
            log.warning("dedup.release failed (%s): %s", phone, e)

    async def healthy(self) -> bool:
        try:
            c = await self.client()
            return bool(await c.ping())
        except Exception:
            return False


dedup = Dedup()
