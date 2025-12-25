from __future__ import annotations

import asyncio
import logging
import time
from typing import Optional

from fastapi import HTTPException

from . import config

logger = logging.getLogger(__name__)


class RateLimitStore:
    async def increment_and_check(self, key: str, limit: int, window_seconds: int = 60) -> bool:
        raise NotImplementedError


class MemoryRateLimitStore(RateLimitStore):
    def __init__(self):
        self._store: dict[str, list[int]] = {}
        self._lock = asyncio.Lock()

    async def increment_and_check(self, key: str, limit: int, window_seconds: int = 60) -> bool:
        now = int(time.time())
        cutoff = now - window_seconds
        async with self._lock:
            entries = [t for t in self._store.get(key, []) if t > cutoff]
            if len(entries) >= limit:
                self._store[key] = entries
                return False
            entries.append(now)
            self._store[key] = entries
            return True


class RedisRateLimitStore(RateLimitStore):
    def __init__(self, client):
        self._client = client

    async def increment_and_check(self, key: str, limit: int, window_seconds: int = 60) -> bool:
        # Use a rolling window approximation with simple counter + expiry.
        pipe = self._client.pipeline()
        pipe.incr(key, 1)
        pipe.expire(key, window_seconds)
        count, _ = await pipe.execute()
        return int(count) <= limit


def _build_store() -> RateLimitStore:
    redis_url = config.redis_url()
    if redis_url:
        try:
            import redis.asyncio as redis  # type: ignore

            client = redis.from_url(redis_url)
            logger.info("Using Redis rate limit store at %s", redis_url)
            return RedisRateLimitStore(client)
        except Exception:
            logger.warning("Falling back to in-memory rate limits; Redis unavailable", exc_info=True)
    return MemoryRateLimitStore()


STORE: RateLimitStore = _build_store()


def tier_for_token(token: Optional[str]) -> str:
    return "vip" if config.is_token_vip(token) else "standard"


async def enforce_rate_limit(identity: str, tier: str | None = None, window_seconds: int = 60) -> None:
    limits = config.rate_limit_tiers()
    tier_key = tier or "standard"
    limit = limits.get(tier_key, limits.get("standard", 30))
    allowed = await STORE.increment_and_check(identity, limit, window_seconds=window_seconds)
    if not allowed:
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
