import hmac
import hashlib
import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import List, Optional

DB_PATH = Path(__file__).parent.parent.parent / "api_keys.db"
JSON_LEGACY = Path("/repo/ttl/api_keys.json")


def _get_secret() -> bytes:
    s = os.getenv("API_KEYS_SECRET")
    if not s:
        # generate ephemeral secret if none provided
        s = os.urandom(32).hex()
        os.environ["API_KEYS_SECRET"] = s
    return s.encode("utf-8")


def _hmac(key: str) -> str:
    return hmac.new(_get_secret(), key.encode("utf-8"), hashlib.sha256).hexdigest()


def init_db(path: Optional[Path] = None):
    p = DB_PATH if path is None else Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(p))
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS api_keys (
            id TEXT PRIMARY KEY,
            key_hash TEXT NOT NULL,
            masked TEXT,
            created_at TEXT NOT NULL
        )
        """
    )
    conn.commit()
    conn.close()
    # migrate legacy json if present
    if JSON_LEGACY.exists():
        try:
            items = json.loads(JSON_LEGACY.read_text(encoding="utf-8") or "[]")
            for it in items:
                add_key(it.get("key"), it.get("id"), it.get("created_at"))
            # optional: rename/move legacy file
            JSON_LEGACY.rename(JSON_LEGACY.with_suffix(".json.migrated"))
        except Exception:
            pass


def _conn():
    return sqlite3.connect(str(DB_PATH))


def mask_key(k: str) -> str:
    if not k:
        return ""
    if len(k) <= 8:
        return k[:2] + "****"
    return k[:4] + "..." + k[-4:]


def add_key(plain_key: str, id: Optional[str] = None, created_at: Optional[str] = None) -> dict:
    if not plain_key:
        raise ValueError("empty key")
    kid = id or os.urandom(16).hex()
    ch = _hmac(plain_key)
    masked = mask_key(plain_key)
    created = created_at or datetime.utcnow().isoformat()
    conn = _conn()
    cur = conn.cursor()
    cur.execute(
        "INSERT OR REPLACE INTO api_keys (id, key_hash, masked, created_at) VALUES (?, ?, ?, ?)",
        (kid, ch, masked, created),
    )
    conn.commit()
    conn.close()
    return {"id": kid, "created_at": created, "masked": masked}


def list_keys() -> List[dict]:
    conn = _conn()
    cur = conn.cursor()
    cur.execute("SELECT id, masked, created_at FROM api_keys ORDER BY created_at DESC")
    rows = cur.fetchall()
    conn.close()
    return [{"id": r[0], "masked": r[1], "created_at": r[2]} for r in rows]


def delete_key(key_id: str) -> bool:
    conn = _conn()
    cur = conn.cursor()
    cur.execute("DELETE FROM api_keys WHERE id = ?", (key_id,))
    changed = cur.rowcount
    conn.commit()
    conn.close()
    return changed > 0


def verify_key(token: str) -> bool:
    if not token:
        return False
    h = _hmac(token)
    conn = _conn()
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM api_keys WHERE key_hash = ? LIMIT 1", (h,))
    ok = cur.fetchone() is not None
    conn.close()
    return ok
