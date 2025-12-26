from __future__ import annotations

import os
import aiosqlite
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Literal

UsageKind = Literal["stt_seconds", "tts_chars", "pron_seconds"]


@dataclass(frozen=True)
class UsageLimits:
    stt_seconds_limit: int
    tts_chars_limit: int
    pron_seconds_limit: int


def _db_path() -> str:
    db_path = os.getenv("USAGE_DB_PATH", os.path.join("data", "usage.db"))
    directory = os.path.dirname(db_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    return db_path


async def init_db() -> None:
    async with aiosqlite.connect(_db_path()) as conn:
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts_utc TEXT NOT NULL,
                kind TEXT NOT NULL,
                amount INTEGER NOT NULL
            )
            """
        )
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage(ts_utc)")
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_kind ON usage(kind)")
        await conn.commit()


def limits_from_env() -> UsageLimits:
    return UsageLimits(
        stt_seconds_limit=int(os.getenv("FREE_STT_SECONDS_LIMIT", "18000")),
        tts_chars_limit=int(os.getenv("FREE_TTS_CHARS_LIMIT", "500000")),
        pron_seconds_limit=int(os.getenv("FREE_PRON_SECONDS_LIMIT", "18000")),
    )


async def record_usage(kind: UsageKind, amount: int) -> None:
    if amount <= 0:
        return
    ts = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    async with aiosqlite.connect(_db_path()) as conn:
        await conn.execute(
            "INSERT INTO usage(ts_utc, kind, amount) VALUES (?, ?, ?)",
            (ts, kind, int(amount)),
        )
        await conn.commit()


def month_key(dt: datetime) -> str:
    return dt.strftime("%Y-%m")


async def get_monthly_totals(month: str) -> dict[str, int]:
    start = f"{month}-01T00:00:00+00:00"
    y, m = month.split("-")
    y_i = int(y)
    m_i = int(m)
    if m_i == 12:
        end = f"{y_i + 1}-01-01T00:00:00+00:00"
    else:
        end = f"{y_i}-{m_i + 1:02d}-01T00:00:00+00:00"

    totals: dict[str, int] = {"stt_seconds": 0, "tts_chars": 0, "pron_seconds": 0}
    async with aiosqlite.connect(_db_path()) as conn:
        async with conn.execute(
            """
            SELECT kind, COALESCE(SUM(amount), 0)
            FROM usage
            WHERE ts_utc >= ? AND ts_utc < ?
            GROUP BY kind
            """,
            (start, end),
        ) as cursor:
            rows = await cursor.fetchall()

    for kind, total in rows:
        totals[str(kind)] = int(total)
    return totals


async def _get_range_totals(start: str, end: str) -> dict[str, int]:
    totals: dict[str, int] = {"stt_seconds": 0, "tts_chars": 0, "pron_seconds": 0}
    async with aiosqlite.connect(_db_path()) as conn:
        async with conn.execute(
            """
            SELECT kind, COALESCE(SUM(amount), 0)
            FROM usage
            WHERE ts_utc >= ? AND ts_utc < ?
            GROUP BY kind
            """,
            (start, end),
        ) as cursor:
            rows = await cursor.fetchall()

    for kind, total in rows:
        totals[str(kind)] = int(total)
    return totals


async def get_today_totals(now_utc: datetime | None = None) -> dict[str, int]:
    if now_utc is None:
        now_utc = datetime.now(timezone.utc)
    start_dt = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    end_dt = start_dt + timedelta(days=1)
    return await _get_range_totals(start_dt.isoformat(), end_dt.isoformat())


async def get_all_time_totals() -> dict[str, int]:
    totals: dict[str, int] = {"stt_seconds": 0, "tts_chars": 0, "pron_seconds": 0}
    async with aiosqlite.connect(_db_path()) as conn:
        async with conn.execute(
            """
            SELECT kind, COALESCE(SUM(amount), 0)
            FROM usage
            GROUP BY kind
            """
        ) as cursor:
            rows = await cursor.fetchall()

    for kind, total in rows:
        totals[str(kind)] = int(total)
    return totals


async def get_usage_summary(month: str) -> dict:
    totals = await get_monthly_totals(month)
    limits = limits_from_env()

    stt_used = totals.get("stt_seconds", 0)
    tts_used = totals.get("tts_chars", 0)
    pron_used = totals.get("pron_seconds", 0)

    return {
        "month": month,
        "limits": {
            "stt_seconds": limits.stt_seconds_limit,
            "tts_chars": limits.tts_chars_limit,
            "pron_seconds": limits.pron_seconds_limit,
        },
        "used": {
            "stt_seconds": stt_used,
            "tts_chars": tts_used,
            "pron_seconds": pron_used,
        },
        "remaining": {
            "stt_seconds": max(limits.stt_seconds_limit - stt_used, 0),
            "tts_chars": max(limits.tts_chars_limit - tts_used, 0),
            "pron_seconds": max(limits.pron_seconds_limit - pron_used, 0),
        },
    }


async def get_usage_overview() -> dict:
    now = datetime.now(timezone.utc)
    month = month_key(now)
    limits = limits_from_env()
    return {
        "today": await get_today_totals(now),
        "month": await get_monthly_totals(month),
        "all_time": await get_all_time_totals(),
        "limits": {
            "stt_seconds": limits.stt_seconds_limit,
            "tts_chars": limits.tts_chars_limit,
            "pron_seconds": limits.pron_seconds_limit,
        },
        "month_key": month,
    }
