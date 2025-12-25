from __future__ import annotations

import re
from ipaddress import ip_address
from typing import Optional

from fastapi import Request

from . import config


def _normalize_ip(raw: str) -> Optional[str]:
    candidate = raw.strip().strip('"').strip("[]")
    try:
        ip_address(candidate)
        return candidate
    except ValueError:
        pass
    if "]" in raw:
        # Handle IPv6 with port: [2001:db8::1]:1234
        before_bracket = raw.split("]", 1)[0].lstrip("[").strip()
        try:
            ip_address(before_bracket)
            return before_bracket
        except ValueError:
            return None
    if ":" in raw:
        no_port = raw.rsplit(":", 1)[0]
        try:
            ip_address(no_port)
            return no_port
        except ValueError:
            return None
    return None


def _parse_forwarded_for(forwarded: str) -> Optional[str]:
    # RFC 7239 style header: Forwarded: for=1.2.3.4;proto=https
    for part in forwarded.split(","):
        match = re.search(r"for=([^;]+)", part, re.IGNORECASE)
        if not match:
            continue
        raw = match.group(1).strip()
        # strip possible obfuscated identifier
        if raw.startswith("_"):
            continue
        candidate = _normalize_ip(raw)
        if candidate:
            return candidate
    return None


def _is_trusted_proxy(ip_str: str) -> bool:
    try:
        ip_obj = ip_address(ip_str)
    except ValueError:
        return False
    for net in config.trusted_proxies():
        if ip_obj in net:
            return True
    return False


def _first_ip_from_header(header_value: str | None) -> Optional[str]:
    if not header_value:
        return None
    candidate_raw = header_value.split(",")[0].strip()
    return _normalize_ip(candidate_raw)


def client_ip(request: Request) -> str:
    remote_ip = request.client.host if request.client else None
    if remote_ip and _is_trusted_proxy(remote_ip):
        forwarded = request.headers.get("forwarded", "")
        forwarded_ip = _parse_forwarded_for(forwarded) if forwarded else None
        if forwarded_ip:
            return forwarded_ip
        xff_ip = _first_ip_from_header(request.headers.get("x-forwarded-for"))
        if xff_ip:
            return xff_ip
    if remote_ip:
        return remote_ip
    return "unknown"
