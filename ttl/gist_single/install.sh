#!/usr/bin/env bash
set -euo pipefail

APP_DIR=${APP_DIR:-speech-portal}
SPEECH_KEY=${SPEECH_KEY:-}
SPEECH_REGION=${SPEECH_REGION:-}
OPENAI_TTS_API_KEY=${OPENAI_TTS_API_KEY:-}
HOST_PORT=${HOST_PORT:-}
FREE_STT_SECONDS_LIMIT=${FREE_STT_SECONDS_LIMIT:-18000}
FREE_TTS_CHARS_LIMIT=${FREE_TTS_CHARS_LIMIT:-500000}
FREE_PRON_SECONDS_LIMIT=${FREE_PRON_SECONDS_LIMIT:-18000}

usage() {
  echo "Usage: ./install.sh [--app-dir DIR] [--speech-key KEY] [--speech-region REGION] [--openai-tts-api-key KEY] [--port HOST_PORT]" >&2
}

is_port_free() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ! ss -ltn "sport = :${p}" 2>/dev/null | grep -q ":${p} "
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  (echo >/dev/tcp/127.0.0.1/"${p}") >/dev/null 2>&1 && return 1 || return 0
}

pick_free_port() {
  local start="$1"
  local end="$2"
  local p
  for p in $(seq "${start}" "${end}"); do
    if is_port_free "${p}"; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      APP_DIR="$2"; shift 2 ;;
    --speech-key)
      SPEECH_KEY="$2"; shift 2 ;;
    --speech-region)
      SPEECH_REGION="$2"; shift 2 ;;
    --openai-tts-api-key)
      OPENAI_TTS_API_KEY="$2"; shift 2 ;;
    --port)
      HOST_PORT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${SPEECH_KEY}" ]]; then
  read -r -p "Enter SPEECH_KEY: " SPEECH_KEY
fi
if [[ -z "${SPEECH_REGION}" ]]; then
  read -r -p "Enter SPEECH_REGION (e.g. eastus): " SPEECH_REGION
fi
if [[ -z "${OPENAI_TTS_API_KEY}" ]]; then
  read -r -p "Enter OPENAI_TTS_API_KEY for OpenAI-compatible TTS (optional, press Enter to skip): " OPENAI_TTS_API_KEY
fi

if [[ -n "${HOST_PORT}" ]]; then
  if ! is_port_free "${HOST_PORT}"; then
    echo "Port ${HOST_PORT} is already in use." >&2
    read -r -p "Enter another HOST_PORT (or empty to auto-detect): " _p
    if [[ -n "${_p}" ]]; then
      HOST_PORT="${_p}"
    else
      HOST_PORT=""
    fi
  fi
fi

if [[ -z "${HOST_PORT}" ]]; then
  HOST_PORT="$(pick_free_port 8000 8100 || true)"
  if [[ -z "${HOST_PORT}" ]]; then
    echo "Failed to find a free port in range 8000-8100" >&2
    exit 1
  fi
fi

mkdir -p "${APP_DIR}/backend/app/static" "${APP_DIR}/backend/app/templates" "${APP_DIR}/data"

cat > "${APP_DIR}/docker-compose.yml" <<YAML
services:
  speech-portal:
    build:
      context: ./backend
    ports:
      - "${HOST_PORT}:8000"
    env_file:
      - ./.env
    volumes:
      - ./data:/app/data
    restart: unless-stopped
YAML

cat > "${APP_DIR}/backend/Dockerfile" <<'DOCKER'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCKER

cat > "${APP_DIR}/backend/requirements.txt" <<'REQ'
fastapi==0.115.6
uvicorn[standard]==0.32.1
jinja2==3.1.4
python-multipart==0.0.12
requests==2.32.3
REQ

cat > "${APP_DIR}/backend/app/main.py" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

from .speech import client_from_env
from .usage import get_usage_overview, get_usage_summary, init_db, month_key, record_usage

app = FastAPI()

app.mount("/static", StaticFiles(directory="app/static"), name="static")

templates = Jinja2Templates(directory="app/templates")


@app.on_event("startup")
def _startup() -> None:
    init_db()


@app.get("/api/health")
def health() -> dict:
    return {"ok": True}


@app.get("/api/usage/summary")
def usage_summary(month: str | None = None) -> dict:
    if not month:
        month = month_key(datetime.now(timezone.utc))
    return get_usage_summary(month)


@app.get("/api/usage/overview")
def usage_overview() -> dict:
    return get_usage_overview()


@app.get("/api/tts/voices")
def tts_voices(locale: str | None = None, neural_only: bool = True) -> dict:
    try:
        c = client_from_env()
        voices = c.list_voices()
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    filtered: list[dict] = []
    for v in voices:
        if not isinstance(v, dict):
            continue
        if neural_only and str(v.get("VoiceType", "")).lower() != "neural":
            continue
        if locale and not str(v.get("Locale", "")).startswith(locale):
            continue
        filtered.append(v)

    return {"voices": filtered}


@app.post("/api/stt/recognize")
async def stt_recognize(
    audio: UploadFile = File(...),
    language: str = Form("zh-CN"),
    seconds: int = Form(0),
) -> dict:
    if audio.content_type not in {"audio/wav", "audio/x-wav", "audio/wave"}:
        raise HTTPException(status_code=400, detail="Only WAV is supported in this demo")
    wav_bytes = await audio.read()
    try:
        c = client_from_env()
        result = c.speech_to_text(wav_bytes=wav_bytes, language=language)
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    if seconds > 0:
        record_usage("stt_seconds", seconds)

    return result


@app.post("/api/pronunciation/assess")
async def pronunciation_assess(
    audio: UploadFile = File(...),
    reference_text: str = Form(...),
    language: str = Form("en-US"),
    seconds: int = Form(0),
) -> dict:
    if audio.content_type not in {"audio/wav", "audio/x-wav", "audio/wave"}:
        raise HTTPException(status_code=400, detail="Only WAV is supported in this demo")
    wav_bytes = await audio.read()
    try:
        c = client_from_env()
        result = c.pronunciation_assessment(
            wav_bytes=wav_bytes,
            language=language,
            reference_text=reference_text,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    if seconds > 0:
        record_usage("pron_seconds", seconds)

    return result


@app.post("/api/tts/synthesize")
async def tts_synthesize(
    text: str = Form(...),
    voice: str = Form("zh-CN-XiaoxiaoNeural"),
    output_format: str = Form("audio-16khz-32kbitrate-mono-mp3"),
    lang: str = Form("zh-CN"),
    style: str = Form(""),
    style_degree: float = Form(0.0),
    role: str = Form(""),
    rate: int = Form(0),
    pitch: int = Form(0),
    volume: int = Form(0),
    pause_ms: int = Form(0),
) -> Response:
    if not text.strip():
        raise HTTPException(status_code=400, detail="Empty text")

    try:
        c = client_from_env()
        audio_bytes = c.text_to_speech(
            text=text,
            voice=voice,
            output_format=output_format,
            lang=lang,
            style=style or None,
            style_degree=style_degree if style_degree and style_degree > 0 else None,
            role=role or None,
            rate=rate,
            pitch=pitch,
            volume=volume,
            pause_ms=pause_ms,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    record_usage("tts_chars", len(text))
    return Response(content=audio_bytes, media_type="audio/mpeg")


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("index.html", {"request": request})
PY

cat > "${APP_DIR}/backend/app/speech.py" <<'PY'
from __future__ import annotations

import base64
import json
import os
import re
from typing import Any

import requests


class SpeechClient:
    def __init__(self, key: str, region: str, openai_tts_api_key: str | None = None):
        self.key = key
        self.region = region
        self.openai_tts_api_key = openai_tts_api_key

    def _stt_url(self, language: str) -> str:
        return (
            f"https://{self.region}.stt.speech.microsoft.com/speech/recognition/"
            f"conversation/cognitiveservices/v1?language={language}"
        )

    def _tts_url(self) -> str:
        return f"https://{self.region}.tts.speech.microsoft.com/cognitiveservices/v1"

    def _tts_voices_url(self) -> str:
        return f"https://{self.region}.tts.speech.microsoft.com/cognitiveservices/voices/list"

    def _tts_headers(self) -> dict[str, str]:
        headers = {
            "Ocp-Apim-Subscription-Key": self.key,
            "User-Agent": "speech-portal",
        }
        if self.openai_tts_api_key:
            headers["api-key"] = self.openai_tts_api_key
        return headers

    def list_voices(self) -> list[dict[str, Any]]:
        headers = self._tts_headers()
        headers["Accept"] = "application/json"
        r = requests.get(self._tts_voices_url(), headers=headers, timeout=60)
        r.raise_for_status()
        data = r.json()
        if not isinstance(data, list):
            raise RuntimeError("Unexpected voices list response")
        return data

    def speech_to_text(self, wav_bytes: bytes, language: str) -> dict[str, Any]:
        headers = {
            "Ocp-Apim-Subscription-Key": self.key,
            "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
            "Accept": "application/json",
        }
        r = requests.post(self._stt_url(language), headers=headers, data=wav_bytes, timeout=60)
        r.raise_for_status()
        return r.json()

    def pronunciation_assessment(
        self,
        wav_bytes: bytes,
        language: str,
        reference_text: str,
        grading_system: str = "HundredMark",
        granularity: str = "Phoneme",
    ) -> dict[str, Any]:
        pa = {
            "ReferenceText": reference_text,
            "GradingSystem": grading_system,
            "Granularity": granularity,
            "Dimension": "Comprehensive",
            "EnableMiscue": True,
        }
        pa_b64 = base64.b64encode(json.dumps(pa).encode("utf-8")).decode("utf-8")

        headers = {
            "Ocp-Apim-Subscription-Key": self.key,
            "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
            "Accept": "application/json",
            "Pronunciation-Assessment": pa_b64,
        }
        r = requests.post(self._stt_url(language), headers=headers, data=wav_bytes, timeout=60)
        r.raise_for_status()
        return r.json()

    def text_to_speech(
        self,
        text: str,
        voice: str,
        output_format: str,
        *,
        lang: str = "en-US",
        style: str | None = None,
        style_degree: float | None = None,
        role: str | None = None,
        rate: int | None = None,
        pitch: int | None = None,
        volume: int | None = None,
        pause_ms: int | None = None,
    ) -> bytes:
        ssml = build_ssml(
            text=text,
            voice=voice,
            lang=lang,
            style=style,
            style_degree=style_degree,
            role=role,
            rate=rate,
            pitch=pitch,
            volume=volume,
            pause_ms=pause_ms,
        )

        headers = self._tts_headers()
        headers["Content-Type"] = "application/ssml+xml"
        headers["X-Microsoft-OutputFormat"] = output_format
        r = requests.post(self._tts_url(), headers=headers, data=ssml.encode("utf-8"), timeout=60)
        r.raise_for_status()
        return r.content


def _escape_xml(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def _clamp_int(v: int | None, lo: int, hi: int) -> int | None:
    if v is None:
        return None
    return max(lo, min(hi, int(v)))


def _clamp_float(v: float | None, lo: float, hi: float) -> float | None:
    if v is None:
        return None
    try:
        f = float(v)
    except Exception:
        return None
    return max(lo, min(hi, f))


def _ssml_inner_with_breaks(text: str, pause_ms: int | None) -> str:
    pause_ms_i = _clamp_int(pause_ms, 0, 5000)
    if not pause_ms_i:
        return _escape_xml(text)

    parts = re.split(r"([。！？!?\n])", text)
    out: list[str] = []
    for p in parts:
        if not p:
            continue
        if p == "\n":
            out.append(f"<break time='{pause_ms_i}ms' />")
            continue
        out.append(_escape_xml(p))
        if p in ("。", "！", "？", "!", "?"):
            out.append(f"<break time='{pause_ms_i}ms' />")
    return "".join(out)


def build_ssml(
    *,
    text: str,
    voice: str,
    lang: str,
    style: str | None,
    style_degree: float | None,
    role: str | None,
    rate: int | None,
    pitch: int | None,
    volume: int | None,
    pause_ms: int | None,
) -> str:
    rate = _clamp_int(rate, -100, 200)
    pitch = _clamp_int(pitch, -50, 50)
    volume = _clamp_int(volume, -100, 100)
    style_degree = _clamp_float(style_degree, 0.1, 2.0)

    inner = _ssml_inner_with_breaks(text, pause_ms)

    prosody_attrs: list[str] = []
    if rate is not None:
        prosody_attrs.append(f"rate='{rate}%'" )
    if pitch is not None:
        prosody_attrs.append(f"pitch='{pitch}%'" )
    if volume is not None:
        prosody_attrs.append(f"volume='{volume}%'" )
    if prosody_attrs:
        inner = f"<prosody {' '.join(prosody_attrs)}>{inner}</prosody>"

    if style or role:
        attrs: list[str] = []
        if style:
            attrs.append(f"style='{_escape_xml(style)}'")
        if style and style_degree is not None:
            attrs.append(f"styledegree='{style_degree:.2f}'")
        if role:
            attrs.append(f"role='{_escape_xml(role)}'")
        inner = f"<mstts:express-as {' '.join(attrs)}>{inner}</mstts:express-as>"

    return (
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xmlns:mstts='https://www.w3.org/2001/mstts' "
        f"xml:lang='{_escape_xml(lang)}'>"
        f"<voice name='{_escape_xml(voice)}'>"
        f"{inner}"
        "</voice></speak>"
    )


def client_from_env() -> SpeechClient:
    key = os.getenv("SPEECH_KEY")
    region = os.getenv("SPEECH_REGION")
    openai_tts_api_key = os.getenv("OPENAI_TTS_API_KEY")
    if not key or not region:
        raise RuntimeError("Missing SPEECH_KEY or SPEECH_REGION")
    return SpeechClient(key=key, region=region, openai_tts_api_key=openai_tts_api_key)
PY

cat > "${APP_DIR}/backend/app/usage.py" <<'PY'
from __future__ import annotations

import os
import sqlite3
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
    os.makedirs("data", exist_ok=True)
    return os.path.join("data", "usage.db")


def init_db() -> None:
    with sqlite3.connect(_db_path()) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts_utc TEXT NOT NULL,
                kind TEXT NOT NULL,
                amount INTEGER NOT NULL
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage(ts_utc)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_kind ON usage(kind)")
        conn.commit()


def limits_from_env() -> UsageLimits:
    return UsageLimits(
        stt_seconds_limit=int(os.getenv("FREE_STT_SECONDS_LIMIT", "18000")),
        tts_chars_limit=int(os.getenv("FREE_TTS_CHARS_LIMIT", "500000")),
        pron_seconds_limit=int(os.getenv("FREE_PRON_SECONDS_LIMIT", "18000")),
    )


def record_usage(kind: UsageKind, amount: int) -> None:
    if amount <= 0:
        return
    ts = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    with sqlite3.connect(_db_path()) as conn:
        conn.execute(
            "INSERT INTO usage(ts_utc, kind, amount) VALUES (?, ?, ?)",
            (ts, kind, int(amount)),
        )
        conn.commit()


def month_key(dt: datetime) -> str:
    return dt.strftime("%Y-%m")


def get_monthly_totals(month: str) -> dict[str, int]:
    start = f"{month}-01T00:00:00+00:00"
    y, m = month.split("-")
    y_i = int(y)
    m_i = int(m)
    if m_i == 12:
        end = f"{y_i + 1}-01-01T00:00:00+00:00"
    else:
        end = f"{y_i}-{m_i + 1:02d}-01T00:00:00+00:00"

    totals: dict[str, int] = {"stt_seconds": 0, "tts_chars": 0, "pron_seconds": 0}
    with sqlite3.connect(_db_path()) as conn:
        rows = conn.execute(
            """
            SELECT kind, COALESCE(SUM(amount), 0)
            FROM usage
            WHERE ts_utc >= ? AND ts_utc < ?
            GROUP BY kind
            """,
            (start, end),
        ).fetchall()
    for kind, total in rows:
        totals[str(kind)] = int(total)
    return totals


def _get_range_totals(start: str, end: str) -> dict[str, int]:
    totals: dict[str, int] = {"stt_seconds": 0, "tts_chars": 0, "pron_seconds": 0}
    with sqlite3.connect(_db_path()) as conn:
        rows = conn.execute(
            """
            SELECT kind, COALESCE(SUM(amount), 0)
            FROM usage
            WHERE ts_utc >= ? AND ts_utc < ?
            GROUP BY kind
            """,
            (start, end),
        ).fetchall()
    for kind, total in rows:
        totals[str(kind)] = int(total)
    return totals


def get_today_totals(now_utc: datetime | None = None) -> dict[str, int]:
    if now_utc is None:
        now_utc = datetime.now(timezone.utc)
    start_dt = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    end_dt = start_dt + timedelta(days=1)
    return _get_range_totals(start_dt.isoformat(), end_dt.isoformat())


def get_all_time_totals() -> dict[str, int]:
    totals: dict[str, int] = {"stt_seconds": 0, "tts_chars": 0, "pron_seconds": 0}
    with sqlite3.connect(_db_path()) as conn:
        rows = conn.execute(
            """
            SELECT kind, COALESCE(SUM(amount), 0)
            FROM usage
            GROUP BY kind
            """
        ).fetchall()
    for kind, total in rows:
        totals[str(kind)] = int(total)
    return totals


def get_usage_summary(month: str) -> dict:
    totals = get_monthly_totals(month)
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


def get_usage_overview() -> dict:
    now = datetime.now(timezone.utc)
    month = month_key(now)
    limits = limits_from_env()
    return {
        "today": get_today_totals(now),
        "month": get_monthly_totals(month),
        "all_time": get_all_time_totals(),
        "limits": {
            "stt_seconds": limits.stt_seconds_limit,
            "tts_chars": limits.tts_chars_limit,
            "pron_seconds": limits.pron_seconds_limit,
        },
        "month_key": month,
    }
PY

 cat > "${APP_DIR}/backend/app/templates/index.html" <<'HTML'
<!doctype html>
<html lang="zh">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Azure 语音门户</title>
    <style>
      :root {
        --border: #e7e5e4;
        --muted: #78716c;
        --bg: rgba(255, 255, 255, .88);
        --panel: rgba(250, 250, 249, .92);
        --brand: #16a34a;
        --shadow: 0 1px 2px rgba(0,0,0,.05);
      }
      body { font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; margin: 0; background: radial-gradient(1200px 600px at 20% 0%, #ecfdf5 0%, rgba(236,253,245,0) 60%), radial-gradient(1000px 600px at 90% 10%, #fef3c7 0%, rgba(254,243,199,0) 55%), #f5f5f4; }
      .wrap { padding: 12px; max-width: 1320px; margin: 0 auto; }
      .bar { background: #fff; border: 1px solid var(--border); border-radius: 10px; box-shadow: var(--shadow); }
      .usage { display:flex; align-items:center; justify-content:space-between; gap: 12px; padding: 10px 12px; font-size: 13px; }
      .usage .left { display:flex; gap: 14px; flex-wrap: wrap; }
      .usage strong { font-weight: 700; }
      .toolbar { display:flex; align-items:center; justify-content:flex-end; gap: 8px; padding: 10px 12px; border-top: 1px solid var(--border); flex-wrap: wrap; }
      .toolbar .spacer { display:none; }
      .layout { display:grid; grid-template-columns: 1fr 380px; gap: 12px; margin-top: 12px; }
      .panel { background: var(--bg); border: 1px solid var(--border); border-radius: 10px; box-shadow: var(--shadow); overflow: hidden; }
      .editorHead { display:flex; align-items:center; justify-content:space-between; padding: 10px 12px; border-bottom: 1px solid var(--border); background: #fff; }
      .editorHead .muted { font-size: 12px; color: var(--muted); }
      .editor { padding: 10px; background: #fff; }
      textarea { width: 100%; height: calc(100vh - 270px); min-height: 420px; resize: none; border: 1px solid var(--border); border-radius: 10px; padding: 12px; box-sizing: border-box; font-size: 14px; line-height: 1.55; }
      .actions { display:flex; gap: 8px; flex-wrap: wrap; padding: 10px 12px; border-top: 1px solid var(--border); background: #fff; }
      button { padding: 8px 12px; cursor: pointer; border-radius: 10px; border: 1px solid var(--border); background: #fff; transition: background .15s, border-color .15s, transform .05s; }
      button:hover { background: #f9fafb; }
      button:active { transform: translateY(1px); }
      button:disabled { opacity: .6; cursor: not-allowed; }
      button.primary { background: var(--brand); border-color: var(--brand); color: #fff; }
      button.primary:hover { background: #15803d; border-color: #15803d; }
      button.danger { background: #ef4444; border-color: #ef4444; color: #fff; }
      button.danger:hover { background: #dc2626; border-color: #dc2626; }
      .pill { display:flex; align-items:center; gap: 8px; padding: 8px; border: 1px solid var(--border); border-radius: 10px; background: #fff; }
      .switch { display:inline-flex; align-items:center; gap: 6px; user-select:none; }
      .switch input { width: 16px; height: 16px; }

      .toolbox { display:flex; flex-wrap: wrap; gap: 8px; margin: 6px 0 12px; }
      .toolbox .switch { padding: 7px 10px; border: 1px solid var(--border); border-radius: 10px; background: #fff; }
      .right { background: var(--panel); }
      .right .section { padding: 10px 12px; border-bottom: 1px solid var(--border); }
      .right .title { font-weight: 700; font-size: 13px; margin-bottom: 10px; }
      .row { display:grid; grid-template-columns: 78px 1fr; gap: 10px; align-items:center; margin-bottom: 10px; }
      .row label { font-size: 12px; color:#374151; }
      input, select { width: 100%; padding: 8px; border: 1px solid var(--border); border-radius: 10px; box-sizing: border-box; background: #fff; }
      input:focus, select:focus, textarea:focus { outline: none; border-color: rgba(22, 163, 74, .55); box-shadow: 0 0 0 4px rgba(22, 163, 74, .12); }
      input[type=range] { width: 100%; }
      .inline { display:flex; gap: 8px; }
      .inline > * { flex: 1; }
      .slider { display:flex; align-items:center; gap: 8px; }
      .slider .val { width: 56px; text-align: right; color: var(--muted); font-size: 12px; }
      .muted { color: var(--muted); font-size: 12px; }
      .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
      dialog { border: 1px solid var(--border); border-radius: 12px; padding: 0; box-shadow: 0 10px 25px rgba(0,0,0,.15); }
      dialog .dlg { width: min(560px, 94vw); background: #fff; }
      dialog .dlgHead { padding: 12px; font-weight: 700; border-bottom: 1px solid var(--border); }
      dialog .dlgBody { padding: 12px; }
      dialog .dlgFoot { padding: 12px; border-top: 1px solid var(--border); display:flex; justify-content:flex-end; gap: 8px; }

      details { background: #fff; border: 1px solid var(--border); border-radius: 10px; padding: 10px; }
      details summary { cursor: pointer; font-weight: 700; font-size: 12px; color:#111827; }
      details[open] summary { margin-bottom: 10px; }

      @media (max-width: 980px) {
        .layout { grid-template-columns: 1fr; }
        textarea { height: 46vh; min-height: 260px; }
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="bar">
        <div class="usage" id="topbar">
          <div class="left" id="usageBar">
            <div><strong>累计</strong>：TTS 0 字符 / STT 0 秒 / 发音 0 秒</div>
            <div><strong>本月</strong>：TTS 0 字符 / STT 0 秒 / 发音 0 秒</div>
            <div><strong>今日</strong>：TTS 0 字符 / STT 0 秒 / 发音 0 秒</div>
          </div>
          <div class="muted" id="quotaHint">字数：0/500000</div>
        </div>
      </div>

      <div class="layout">
        <div class="panel">
          <div class="editorHead">
            <div class="muted">一次生成一条语音：改完文本后再次点击生成即可</div>
            <div class="muted" id="charCount">0 字符</div>
          </div>
          <div class="editor">
            <textarea id="ttsText">你好，我是 Azure Speech。</textarea>
          </div>
          <div class="actions">
            <button class="primary" id="ttsBtn">生成</button>
            <button id="ttsStop">停止</button>
            <button id="btnDownload" disabled>下载音频</button>
            <button id="btnDownloadSrt" disabled>下载字幕</button>
            <div class="pill" style="flex:1;">
              <audio id="ttsAudio" controls style="width:100%"></audio>
            </div>
          </div>
        </div>

        <div class="panel right">
          <div class="section">
            <div class="title">参数</div>

            <div class="toolbox">
              <button id="btnFormat">整理</button>
              <button id="btnReplace">替换</button>
              <button class="danger" id="btnClear">清除</button>
              <label class="switch"><input type="checkbox" id="toggleBeep" /> 关闭提示音</label>
              <label class="switch"><input type="checkbox" id="toggleAutoDownload" /> 开启自动下载</label>
              <button id="btnGenSrt">生成字幕（SRT）</button>
              <button id="refreshUsage">刷新用量</button>
            </div>

            <div class="row">
              <label>语言</label>
              <div style="display:flex; flex-direction:column; gap:8px;">
                <input id="langSearch" placeholder="搜索语言（中文/代码）" />
                <select id="ttsLang"></select>
              </div>
            </div>
            <div class="row">
              <label>语音</label>
              <div class="inline">
                <select id="ttsVoice"></select>
                <button id="btnPreview">试听</button>
              </div>
            </div>
            <div class="row">
              <label>质量</label>
              <select id="ttsFormat">
                <option value="audio-16khz-32kbitrate-mono-mp3">mp3 16k 32kbps</option>
                <option value="audio-24khz-48kbitrate-mono-mp3">mp3 24k 48kbps</option>
                <option value="audio-24khz-160kbitrate-mono-mp3" selected>mp3 24k 160kbps</option>
                <option value="riff-16khz-16bit-mono-pcm">wav 16k pcm</option>
              </select>
            </div>
            <div class="row">
              <label>情绪</label>
              <select id="ttsStyle"></select>
            </div>
            <div class="muted" id="styleHint" style="margin:-6px 0 10px; padding-left:78px;">选择“情绪”后这里会显示说明（不选则为默认语气）</div>
            <div class="row">
              <label>模仿</label>
              <select id="ttsRole"></select>
            </div>

            <div class="row">
              <label>句间停顿</label>
              <input id="ttsPauseMs" type="number" min="0" max="5000" step="50" value="250" />
            </div>
            <div class="muted" style="margin:-6px 0 10px; padding-left:78px;">单位毫秒(ms)。会在句号/问号/感叹号/换行后自动插入停顿；建议 150~400。</div>

            <details id="advPanel" style="margin-top:10px;">
              <summary>高级参数（可选）</summary>
              <div class="row">
                <label>强度</label>
                <div class="slider">
                  <input id="ttsStyleDegree" type="range" min="0" max="200" value="0" />
                  <div class="val" id="styleDegreeVal">0</div>
                </div>
              </div>
              <div class="muted" style="margin:-6px 0 10px; padding-left:78px;">调节“情绪/风格”的强弱。0 表示不启用；建议 0.8~1.2（过高可能夸张）。</div>
              <div class="row">
                <label>语速</label>
                <div class="slider">
                  <input id="ttsRate" type="range" min="-100" max="200" value="0" />
                  <div class="val" id="rateVal">0%</div>
                </div>
              </div>
              <div class="muted" style="margin:-6px 0 10px; padding-left:78px;">说话速度。负值更慢、正值更快；建议 -10%~+20%。</div>
              <div class="row">
                <label>音调</label>
                <div class="slider">
                  <input id="ttsPitch" type="range" min="-50" max="50" value="0" />
                  <div class="val" id="pitchVal">0%</div>
                </div>
              </div>
              <div class="muted" style="margin:-6px 0 10px; padding-left:78px;">声音更低沉或更清亮；建议 -5%~+5%。</div>
              <div class="row" style="margin-bottom:0;">
                <label>音量</label>
                <div class="slider">
                  <input id="ttsVolume" type="range" min="-100" max="100" value="0" />
                  <div class="val" id="volVal">0 dB</div>
                </div>
              </div>
              <div class="muted" style="margin:6px 0 0; padding-left:78px;">整体响度（dB）。一般 0 dB 最自然；太大可能失真。这里显示为 dB，提交时仍使用内部百分比参数。</div>
            </details>
          </div>

          <div class="section" style="border-bottom:0;">
            <div class="title">当前结果</div>
            <div class="muted">生成后可在左侧播放器播放；也可点击“下载音频/下载字幕”。</div>
          </div>
        </div>
      </div>
    </div>

    <dialog id="replaceDlg">
      <div class="dlg">
        <div class="dlgHead">替换</div>
        <div class="dlgBody">
          <div class="row">
            <label>查找</label>
            <input id="findText" />
          </div>
          <div class="row" style="margin-bottom:0;">
            <label>替换</label>
            <input id="replaceText" />
          </div>
          <div class="muted" style="margin-top:10px;">仅做纯文本替换（区分大小写）</div>
        </div>
        <div class="dlgFoot">
          <button id="btnReplaceCancel">关闭</button>
          <button class="primary" id="btnReplaceApply">替换全部</button>
        </div>
      </div>
    </dialog>

    <script src="/static/app.js"></script>
  </body>
</html>
HTML

cat > "${APP_DIR}/backend/app/static/app.js" <<'JS'
async function fetchJson(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(await r.text());
  return await r.json();
}

function fmt(n) {
  return new Intl.NumberFormat().format(n);
}

async function refreshUsage() {
  const u = await fetchJson('/api/usage/overview');
  const bar = document.getElementById('usageBar');
  const limit = Number(u?.limits?.tts_chars);
  if (Number.isFinite(limit) && limit > 0) state.ttsCharsLimit = limit;
  bar.innerHTML = `
    <div><b>累计</b>：TTS ${fmt(u.all_time.tts_chars)} 字符 / STT ${fmt(u.all_time.stt_seconds)} 秒 / 发音 ${fmt(u.all_time.pron_seconds)} 秒</div>
    <div><b>本月(${u.month_key})</b>：TTS ${fmt(u.month.tts_chars)} 字符 / STT ${fmt(u.month.stt_seconds)} 秒 / 发音 ${fmt(u.month.pron_seconds)} 秒</div>
    <div><b>今日</b>：TTS ${fmt(u.today.tts_chars)} 字符 / STT ${fmt(u.today.stt_seconds)} 秒 / 发音 ${fmt(u.today.pron_seconds)} 秒</div>
  `;
  updateCharCount();
}

document.getElementById('refreshUsage').addEventListener('click', () => {
  refreshUsage().catch(e => alert(`刷新失败：${e.message}`));
});

const state = {
  voices: [],
  voicesByLocale: new Map(),
  abort: null,
  currentItem: null,
  langQuery: '',
  langGroups: [],
  ttsCharsLimit: 500000,
};

const STYLE_ZH = {
  advertisement_upbeat: '广告（欢快）',
  affectionate: '深情',
  angry: '愤怒',
  assistant: '助理',
  calm: '平静',
  chat: '聊天',
  cheerful: '欢快',
  customerservice: '客服',
  depressed: '沮丧',
  disgruntled: '不满',
  documentary_narration: '纪录片旁白',
  embarrassed: '尴尬',
  empathetic: '共情',
  excited: '兴奋',
  fearful: '害怕',
  friendly: '友好',
  gentle: '温柔',
  hopeful: '充满希望',
  lyrical: '抒情',
  narration: '旁白',
  newscast: '新闻播报',
  newscast_casual: '新闻播报（随和）',
  newscast_formal: '新闻播报（正式）',
  poetry_reading: '诗歌朗诵',
  sad: '悲伤',
  serious: '严肃',
  shouting: '喊叫',
  terrified: '恐惧',
  unfriendly: '不友好',
  whispering: '耳语',
};

const STYLE_DESC_SHORT_ZH = {
  advertisement_upbeat: '带劲、有感染力',
  affectionate: '温柔深情',
  angry: '生气、冲突',
  assistant: '中性提示音',
  calm: '舒缓、稳定',
  chat: '自然口语',
  cheerful: '轻松明快',
  customerservice: '耐心礼貌',
  depressed: '低落',
  disgruntled: '抱怨、不满',
  documentary_narration: '纪录片口吻',
  embarrassed: '尴尬',
  empathetic: '共情安慰',
  excited: '兴奋',
  fearful: '紧张害怕',
  friendly: '亲切',
  gentle: '柔和',
  hopeful: '积极',
  lyrical: '抒情',
  narration: '讲述/旁白',
  newscast: '新闻口吻',
  newscast_casual: '新闻口吻（随和）',
  newscast_formal: '新闻口吻（正式）',
  poetry_reading: '朗诵腔',
  sad: '伤感',
  serious: '正式严肃',
  shouting: '大声',
  terrified: '恐惧',
  unfriendly: '冷淡',
  whispering: '轻声',
};

const STYLE_DESC_ZH = {
  advertisement_upbeat: '适合广告口播、带货、宣传文案，更有精气神。',
  affectionate: '适合情感类文案、告白、温柔叙述。',
  angry: '适合抱怨、争执、冲突台词。',
  assistant: '偏“智能助手/系统提示”的语气，清晰、中性。',
  calm: '适合讲解、冥想、舒缓叙述，整体更平稳。',
  chat: '更像日常聊天的口语表达。',
  cheerful: '轻松愉快、明亮的语气，适合娱乐/日常口播。',
  customerservice: '耐心礼貌的客服语气，适合售前售后。',
  depressed: '低落、无力的语气，适合情绪低谷场景。',
  disgruntled: '带点不耐烦/不满，适合吐槽类台词。',
  documentary_narration: '纪录片/旁白口吻，偏客观叙述。',
  embarrassed: '略尴尬、局促的感觉。',
  empathetic: '更有同理心，适合安慰/共情表达。',
  excited: '兴奋、期待，适合宣布/惊喜内容。',
  fearful: '紧张害怕，适合悬疑/惊悚台词。',
  friendly: '更亲切友好，适合服务/引导文案。',
  gentle: '更温柔轻声，适合睡前故事、抚慰类内容。',
  hopeful: '积极向上、有希望的语气。',
  lyrical: '偏抒情，有一点文学感。',
  narration: '标准旁白/讲述口吻。',
  newscast: '新闻播报腔，信息感更强。',
  newscast_casual: '新闻播报但更随和、口语化。',
  newscast_formal: '更正式的新闻播报腔。',
  poetry_reading: '诗歌/文章朗诵腔，节奏感更明显。',
  sad: '伤感、低沉，适合告别/回忆类文案。',
  serious: '正式严肃，适合公告/政策/严谨说明。',
  shouting: '提高音量与情绪强度，适合喊话/强调。',
  terrified: '更强烈的恐惧感，适合紧急/惊吓场景。',
  unfriendly: '冷淡、不太友好，适合对立/疏离台词。',
  whispering: '耳语/轻声，适合秘密/ASMR 风格。',
};

function normalizeStyleKey(s) {
  return String(s || '').trim().toLowerCase().replace(/[-\s]+/g, '_');
}

function styleLabel(s) {
  const raw = String(s || '').trim();
  if (!raw) return raw;
  const key = normalizeStyleKey(raw);
  const zh = STYLE_ZH[key];
  const short = STYLE_DESC_SHORT_ZH[key];
  return zh ? `${zh}（${raw}）${short ? ` - ${short}` : ''}` : raw;
}

function styleDesc(s) {
  const raw = String(s || '').trim();
  if (!raw) return '';
  const key = normalizeStyleKey(raw);
  return STYLE_DESC_ZH[key] || '';
}

function genderZh(gender) {
  const g = String(gender || '').toLowerCase();
  if (g === 'female') return '女';
  if (g === 'male') return '男';
  return '';
}

function localeLabel(locale) {
  const raw = String(locale || '').trim();
  if (!raw) return raw;
  try {
    if (typeof Intl !== 'undefined' && Intl.DisplayNames) {
      const parts = raw.split('-').filter(Boolean);
      const lang = parts[0] || '';
      const p2 = parts[1] || '';
      const p3 = parts[2] || '';

      const dnLang = new Intl.DisplayNames(['zh'], { type: 'language' });
      const dnReg = new Intl.DisplayNames(['zh'], { type: 'region' });
      const dnScript = new Intl.DisplayNames(['zh'], { type: 'script' });

      const langName = lang ? (dnLang.of(lang) || lang) : raw;

      const isScript = p2 && p2.length === 4;
      const script = isScript ? p2 : '';
      const region = isScript ? p3 : p2;

      const scriptName = script ? (dnScript.of(script) || script) : '';
      const regionName = region ? (dnReg.of(region) || region) : '';

      if (scriptName && regionName) return `${langName}（${scriptName}，${regionName}） (${raw})`;
      if (scriptName) return `${langName}（${scriptName}） (${raw})`;
      if (regionName) return `${langName}（${regionName}） (${raw})`;
      return `${langName} (${raw})`;
    }
  } catch (_) {}
  return raw;
}

let lastAudioUrl = null;

function beep(kind) {
  const off = document.getElementById('toggleBeep').checked;
  if (off) return;
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.type = 'sine';
    o.frequency.value = kind === 'ok' ? 880 : 220;
    g.gain.value = 0.02;
    o.connect(g);
    g.connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + 0.08);
    o.onended = () => ctx.close().catch(() => {});
  } catch (_) {}
}

function updateCharCount() {
  const t = document.getElementById('ttsText').value || '';
  document.getElementById('charCount').textContent = `${t.length} 字符`;
  const limit = Number(state.ttsCharsLimit) || 0;
  document.getElementById('quotaHint').textContent = limit > 0
    ? `字数：${t.length}/${fmt(limit)}`
    : `字数：${t.length}`;
}

function _pad2(n) {
  return String(n).padStart(2, '0');
}

function _pad3(n) {
  return String(n).padStart(3, '0');
}

function formatSrtTime(seconds) {
  const s = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  const ms = Math.round((s % 1) * 1000);
  const total = Math.floor(s);
  const hh = Math.floor(total / 3600);
  const mm = Math.floor((total % 3600) / 60);
  const ss = total % 60;
  return `${_pad2(hh)}:${_pad2(mm)}:${_pad2(ss)},${_pad3(ms)}`;
}

async function getAudioDurationSeconds(url) {
  return await new Promise((resolve, reject) => {
    const audio = new Audio();
    audio.preload = 'metadata';
    audio.onloadedmetadata = () => {
      const d = Number(audio.duration);
      resolve(Number.isFinite(d) ? d : 0);
    };
    audio.onerror = () => reject(new Error('无法读取音频时长'));
    audio.src = url;
  });
}

function buildSingleCueSrt(text, durationSeconds) {
  const end = Math.max(0.2, Number.isFinite(durationSeconds) ? durationSeconds : 0);
  return `1\n${formatSrtTime(0)} --> ${formatSrtTime(end)}\n${String(text || '').trim()}\n`;
}

async function ensureSrtForItem(it) {
  if (!it || it.srtText) return;
  try {
    const duration = await getAudioDurationSeconds(it.url);
    it.srtText = buildSingleCueSrt(it.text, duration);
  } catch (_) {
    it.srtText = buildSingleCueSrt(it.text, 1.0);
  }
}

function downloadTextFile(filename, content) {
  const blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

function downloadBlobUrl(filename, url) {
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

function extFromOutputFormat(outputFormat) {
  const f = String(outputFormat || '').toLowerCase();
  if (f.startsWith('riff-') || f.includes('pcm')) return 'wav';
  if (f.includes('mp3')) return 'mp3';
  return 'mp3';
}

function setSliderPercent(id, outId) {
  const el = document.getElementById(id);
  const out = document.getElementById(outId);
  const sync = () => (out.textContent = `${el.value}%`);
  el.addEventListener('input', sync);
  sync();
}

function setSliderVolumeDb() {
  const el = document.getElementById('ttsVolume');
  const out = document.getElementById('volVal');
  const sync = () => {
    const v = Number(el.value);
    const db = (v / 100) * 12;
    const sign = db > 0 ? '+' : '';
    out.textContent = `${sign}${db.toFixed(1)} dB`;
  };
  el.addEventListener('input', sync);
  sync();
}

function setSliderStyleDegree() {
  const el = document.getElementById('ttsStyleDegree');
  const out = document.getElementById('styleDegreeVal');
  const sync = () => {
    const v = Number(el.value);
    out.textContent = v === 0 ? '0' : (v / 100).toFixed(2);
  };
  el.addEventListener('input', sync);
  sync();
}

setSliderPercent('ttsRate', 'rateVal');
setSliderPercent('ttsPitch', 'pitchVal');
setSliderVolumeDb();
setSliderStyleDegree();

document.getElementById('ttsText').addEventListener('input', updateCharCount);
updateCharCount();

function uniq(arr) {
  return Array.from(new Set(arr));
}

function setOptions(selectEl, options, value, includeEmpty) {
  selectEl.innerHTML = '';
  if (includeEmpty) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '（无）';
    selectEl.appendChild(opt);
  }
  for (const o of options) {
    const opt = document.createElement('option');
    opt.value = o.value;
    opt.textContent = o.label;
    selectEl.appendChild(opt);
  }
  if (value != null) selectEl.value = value;
}

async function loadVoices(locale) {
  const key = locale || '';
  if (state.voicesByLocale.has(key)) return state.voicesByLocale.get(key);
  const q = new URLSearchParams();
  if (locale) q.set('locale', locale);
  q.set('neural_only', 'true');
  const data = await fetchJson(`/api/tts/voices?${q.toString()}`);
  const voices = Array.isArray(data.voices) ? data.voices : [];
  state.voicesByLocale.set(key, voices);
  return voices;
}

function normalizeLocaleGroup(locale) {
  if (!locale) return 'unknown';
  const parts = String(locale).split('-');
  return parts.length >= 2 ? `${parts[0]}-${parts[1]}` : String(locale);
}

function getVoiceMetaByName(name) {
  for (const v of state.voices) {
    if (v && v.ShortName === name) return v;
  }
  return null;
}

function updateStyleRoleOptions() {
  const voiceName = document.getElementById('ttsVoice').value;
  const v = getVoiceMetaByName(voiceName);
  const styles = v && Array.isArray(v.StyleList) ? v.StyleList : [];
  const roles = v && Array.isArray(v.RolePlayList) ? v.RolePlayList : [];
  const styleSel = document.getElementById('ttsStyle');
  const roleSel = document.getElementById('ttsRole');
  const hint = document.getElementById('styleHint');

  if (!styles.length) {
    styleSel.innerHTML = '';
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '该语音不支持';
    styleSel.appendChild(opt);
    styleSel.disabled = true;
    if (hint) hint.textContent = '该语音不支持“情绪/风格”。';
  } else {
    styleSel.disabled = false;
    setOptions(
      styleSel,
      styles.map(s => ({ value: s, label: styleLabel(s) })),
      '',
      true
    );
  }

  if (!roles.length) {
    roleSel.innerHTML = '';
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '该语音不支持';
    roleSel.appendChild(opt);
    roleSel.disabled = true;
  } else {
    roleSel.disabled = false;
    setOptions(
      roleSel,
      roles.map(r => ({ value: r, label: r })),
      '',
      true
    );
  }

  document.getElementById('ttsStyleDegree').value = '0';
  setSliderStyleDegree();

  updateStyleHint();
}

function updateStyleHint() {
  const hint = document.getElementById('styleHint');
  const styleSel = document.getElementById('ttsStyle');
  if (!hint || !styleSel) return;

  if (styleSel.disabled) {
    hint.textContent = '该语音不支持“情绪/风格”。';
    return;
  }

  const v = String(styleSel.value || '').trim();
  if (!v) {
    hint.textContent = '不选则使用默认语气（无情绪）。';
    return;
  }

  const desc = styleDesc(v);
  hint.textContent = desc ? `说明：${desc}` : '说明：该情绪暂无预设说明（可直接试听确认效果）。';
}

async function initLanguagesAndVoices() {
  const voices = await loadVoices(null);
  state.voices = voices;

  const locales = uniq(voices.map(v => v && v.Locale).filter(Boolean)).sort();
  const groups = uniq(locales.map(normalizeLocaleGroup)).sort();
  state.langGroups = groups.map(g => ({ value: g, label: localeLabel(g) }));

  const langSel = document.getElementById('ttsLang');
  setOptions(langSel, state.langGroups, 'zh-CN', false);

  await refreshVoicesByLocale(langSel.value);
}

async function refreshVoicesByLocale(locale) {
  const voices = await loadVoices(locale);
  state.voices = voices;

  const voiceSel = document.getElementById('ttsVoice');
  const opts = voices
    .map(v => ({
      value: v.ShortName,
      label: `${genderZh(v.Gender) ? (genderZh(v.Gender) + ' ') : ''}${v.LocalName || v.DisplayName || v.ShortName} (${v.ShortName})`,
    }))
    .sort((a, b) => a.label.localeCompare(b.label, 'zh'));

  const current = voiceSel.value;
  const preferred = current && opts.some(o => o.value === current)
    ? current
    : (opts.find(o => o.value === 'zh-CN-XiaoxiaoNeural')
        ? 'zh-CN-XiaoxiaoNeural'
        : (opts[0] ? opts[0].value : ''));

  setOptions(voiceSel, opts, preferred, false);
  updateStyleRoleOptions();
}

document.getElementById('ttsLang').addEventListener('change', () => {
  refreshVoicesByLocale(document.getElementById('ttsLang').value).catch(e => alert(`加载语音失败：${e.message}`));
});

document.getElementById('langSearch')?.addEventListener('input', () => {
  const q = String(document.getElementById('langSearch')?.value || '').trim().toLowerCase();
  state.langQuery = q;
  const langSel = document.getElementById('ttsLang');
  const current = langSel.value;
  const filtered = q
    ? state.langGroups.filter(x => `${x.value} ${x.label}`.toLowerCase().includes(q))
    : state.langGroups;
  const preferred = current && filtered.some(x => x.value === current)
    ? current
    : (filtered[0] ? filtered[0].value : '');
  setOptions(langSel, filtered, preferred, false);
  refreshVoicesByLocale(langSel.value).catch(() => {});
});

document.getElementById('ttsVoice').addEventListener('change', () => {
  updateStyleRoleOptions();
});

document.getElementById('ttsStyle')?.addEventListener('change', () => {
  updateStyleHint();
});

function currentParams() {
  const styleDegreeRaw = Number(document.getElementById('ttsStyleDegree').value);
  const styleDegree = styleDegreeRaw === 0 ? 0 : styleDegreeRaw / 100;
  return {
    voice: document.getElementById('ttsVoice').value,
    output_format: document.getElementById('ttsFormat').value,
    lang: document.getElementById('ttsLang').value,
    style: document.getElementById('ttsStyle').value,
    role: document.getElementById('ttsRole').value,
    style_degree: styleDegree,
    rate: Number(document.getElementById('ttsRate').value),
    pitch: Number(document.getElementById('ttsPitch').value),
    volume: Number(document.getElementById('ttsVolume').value),
    pause_ms: Number(document.getElementById('ttsPauseMs')?.value || 0),
  };
}

async function synthesizeOne(text, params, signal) {
  const fd = new FormData();
  fd.append('text', text);
  fd.append('voice', params.voice);
  fd.append('output_format', params.output_format);
  fd.append('lang', params.lang);
  fd.append('style', params.style || '');
  fd.append('role', params.role || '');
  fd.append('style_degree', String(params.style_degree || 0));
  fd.append('rate', String(params.rate || 0));
  fd.append('pitch', String(params.pitch || 0));
  fd.append('volume', String(params.volume || 0));
  fd.append('pause_ms', String(params.pause_ms || 0));

  const r = await fetch('/api/tts/synthesize', { method: 'POST', body: fd, signal });
  if (!r.ok) throw new Error(await r.text());
  return await r.blob();
}

function setCurrentItem(it) {
  state.currentItem = it;
  const btnDown = document.getElementById('btnDownload');
  const btnSrt = document.getElementById('btnDownloadSrt');
  if (btnDown) btnDown.disabled = !it;
  if (btnSrt) btnSrt.disabled = !it;
}

async function runSingleSynthesis() {
  const raw = document.getElementById('ttsText').value;
  const text = String(raw || '').trim();
  if (!text) return alert('请输入文本');

  if (state.abort) state.abort.abort();
  state.abort = new AbortController();

  const params = currentParams();
  const blob = await synthesizeOne(text, params, state.abort.signal);

  const url = URL.createObjectURL(blob);
  const ts = Date.now();
  const base = `tts_${ts}`;
  const ext = extFromOutputFormat(params.output_format);
  const filename = `${base}.${ext}`;
  const srtFilename = `${base}.srt`;
  const item = {
    text,
    url,
    filename,
    srtFilename,
    srtText: '',
    label: `${params.voice} | ${params.lang}`,
  };

  const audio = document.getElementById('ttsAudio');
  audio.src = url;

  if (lastAudioUrl) URL.revokeObjectURL(lastAudioUrl);
  lastAudioUrl = url;

  setCurrentItem(item);

  if (document.getElementById('toggleAutoDownload').checked) {
    downloadBlobUrl(filename, url);
  }

  beep('ok');
  await refreshUsage();
}

document.getElementById('ttsBtn').addEventListener('click', () => {
  runSingleSynthesis().catch(e => {
    beep('err');
    alert(`生成失败：${e.message}`);
  });
});

document.getElementById('ttsStop').addEventListener('click', () => {
  if (state.abort) state.abort.abort();
  const audio = document.getElementById('ttsAudio');
  audio.pause();
  audio.currentTime = 0;
});

document.getElementById('btnPreview').addEventListener('click', () => {
  const old = document.getElementById('ttsText').value;
  const sample = old.trim() ? old.trim().slice(0, 60) : '你好，我是 Azure Speech。';
  const params = currentParams();
  if (state.abort) state.abort.abort();
  state.abort = new AbortController();
  synthesizeOne(sample, params, state.abort.signal)
    .then(blob => {
      const url = URL.createObjectURL(blob);
      const audio = document.getElementById('ttsAudio');
      audio.src = url;
      audio.play().catch(() => {});
      beep('ok');
    })
    .catch(e => {
      beep('err');
      alert(`试听失败：${e.message}`);
    });
});

document.getElementById('btnClear').addEventListener('click', () => {
  document.getElementById('ttsText').value = '';
  updateCharCount();
  setCurrentItem(null);
});

document.getElementById('btnFormat').addEventListener('click', () => {
  const t = String(document.getElementById('ttsText').value || '');
  const lines = t
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);
  document.getElementById('ttsText').value = lines.join('\n');
  updateCharCount();
});

const dlg = document.getElementById('replaceDlg');
document.getElementById('btnReplace').addEventListener('click', () => {
  dlg.showModal();
});
document.getElementById('btnReplaceCancel').addEventListener('click', () => {
  dlg.close();
});

document.getElementById('btnDownload')?.addEventListener('click', () => {
  const it = state.currentItem;
  if (!it) return alert('尚未生成音频');
  downloadBlobUrl(it.filename, it.url);
});

document.getElementById('btnDownloadSrt')?.addEventListener('click', async () => {
  const it = state.currentItem;
  if (!it) return alert('尚未生成音频');
  if (!it.srtText) await ensureSrtForItem(it);
  if (!it.srtText) return alert('字幕尚未生成，请稍后再试');
  downloadTextFile(it.srtFilename, it.srtText);
});
document.getElementById('btnReplaceApply').addEventListener('click', () => {
  const find = document.getElementById('findText').value || '';
  const rep = document.getElementById('replaceText').value || '';
  if (!find) return;
  const t = String(document.getElementById('ttsText').value || '');
  document.getElementById('ttsText').value = t.split(find).join(rep);
  updateCharCount();
  dlg.close();
});

refreshUsage().catch(() => {});
initLanguagesAndVoices().catch(e => alert(`初始化失败：${e.message}`));

document.getElementById('btnGenSrt').addEventListener('click', () => {
  const btn = document.getElementById('btnGenSrt');
  const it = state.currentItem;
  if (!it) return alert('请先生成一条音频');
  btn.disabled = true;
  const oldText = btn.textContent;
  btn.textContent = '正在生成字幕...';
  Promise.resolve()
    .then(async () => {
      await ensureSrtForItem(it);
      if (!it.srtText) throw new Error('字幕生成失败');
      downloadTextFile(it.srtFilename, it.srtText);
    })
    .then(() => {
      btn.textContent = '字幕已下载';
    })
    .catch(e => {
      btn.disabled = false;
      btn.textContent = oldText;
      alert(`生成字幕失败：${e.message}`);
    });
});
JS

touch "${APP_DIR}/data/.gitkeep" || true

cat > "${APP_DIR}/.env" <<ENV
SPEECH_KEY=${SPEECH_KEY}
SPEECH_REGION=${SPEECH_REGION}
OPENAI_TTS_API_KEY=${OPENAI_TTS_API_KEY}
FREE_STT_SECONDS_LIMIT=${FREE_STT_SECONDS_LIMIT}
FREE_TTS_CHARS_LIMIT=${FREE_TTS_CHARS_LIMIT}
FREE_PRON_SECONDS_LIMIT=${FREE_PRON_SECONDS_LIMIT}
ENV

if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    (cd "${APP_DIR}" && docker compose up -d --build)
  elif command -v docker-compose >/dev/null 2>&1; then
    (cd "${APP_DIR}" && docker-compose up -d --build)
  else
    echo "Docker is installed but docker compose is not available. Install Docker Compose plugin." >&2
    exit 1
  fi
else
  echo "Docker is not installed. Install Docker first." >&2
  exit 1
fi

echo "OK. Open: http://<SERVER_IP>:${HOST_PORT}"
