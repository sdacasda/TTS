from __future__ import annotations

import os
from functools import lru_cache
from ipaddress import ip_network
from typing import Iterable


def _split_env_list(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


@lru_cache()
def rate_limit_tiers() -> dict[str, int]:
    default_limit = int(os.getenv("RATE_LIMIT_PER_MIN", "30"))
    vip_limit = int(os.getenv("RATE_LIMIT_PER_MIN_VIP", str(default_limit)))
    return {"standard": default_limit, "vip": vip_limit}


@lru_cache()
def redis_url() -> str | None:
    return os.getenv("RATE_LIMIT_REDIS_URL")


@lru_cache()
def trusted_proxies() -> tuple:
    nets = []
    for entry in _split_env_list(os.getenv("TRUSTED_PROXIES")):
        try:
            nets.append(ip_network(entry, strict=False))
        except ValueError:
            # Silently ignore invalid entries to avoid startup failure.
            continue
    return tuple(nets)


@lru_cache()
def vip_tokens() -> set[str]:
    return set(_split_env_list(os.getenv("VIP_API_KEYS")))


def is_token_vip(token: str | None) -> bool:
    if not token:
        return False
    return token in vip_tokens() or token == os.getenv("API_KEY")
