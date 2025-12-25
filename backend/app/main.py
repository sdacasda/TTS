from __future__ import annotations

import math
import os
import secrets
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv
from contextlib import asynccontextmanager

import aiosqlite
import httpx
from fastapi import FastAPI, Depends, File, Form, HTTPException, Response, Request, UploadFile
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from .speech import client_from_env
from . import audio, db, identity, rate_limit, usage

load_dotenv()

logger = logging.getLogger(__name__)

API_KEY_ADMIN = os.getenv("API_KEY")
if not API_KEY_ADMIN:
    raise RuntimeError("API_KEY environment variable is required for authenticated access")

security = HTTPBearer(auto_error=False)


@asynccontextmanager
async def lifespan(app: FastAPI):
    http_client = httpx.AsyncClient(timeout=60)
    usage_conn = None
    try:
        _ensure_db()
        usage_conn = await usage.open_usage_db()
        await usage.init_db(usage_conn)
        app.state.usage_db_healthy = True
    except Exception:
        app.state.usage_db_healthy = False
        logger.exception("Failed to initialize resources during startup")
    app.state.http_client = http_client
    app.state.usage_conn = usage_conn
    yield
    try:
        if usage_conn:
            await usage_conn.close()
    except Exception:
        logger.warning("Failed to close usage DB connection", exc_info=True)
    await http_client.aclose()


app = FastAPI(docs_url=None, redoc_url=None, lifespan=lifespan)
app.state.api_db_healthy = True
app.state.usage_db_healthy = True

# Mount static files and templates
static_dir = Path(__file__).parent / "static"
templates_dir = Path(__file__).parent / "templates"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
templates = Jinja2Templates(directory=str(templates_dir))


def _ensure_db():
    try:
        db.init_db()
        app.state.api_db_healthy = True
    except Exception:
        app.state.api_db_healthy = False
        logger.warning("Failed to initialize API key database", exc_info=True)


async def verify_api_key(creds: Optional[HTTPAuthorizationCredentials] = Depends(security)):
    token = None
    if creds:
        token = creds.credentials
    if token:
        if token == API_KEY_ADMIN:
            return
        if db.verify_key(token):
            return
    if API_KEY_ADMIN:
        raise HTTPException(status_code=401, detail="Invalid token")
    return


@app.get("/api/health")
def health():
    status = {
        "ok": app.state.api_db_healthy and app.state.usage_db_healthy,
        "api_db": app.state.api_db_healthy,
        "usage_db": app.state.usage_db_healthy,
    }
    if not status["ok"]:
        return JSONResponse(status_code=503, content=status)
    return status


@app.get("/api/tts/voices")
def tts_voices(neural_only: bool = False, lang: Optional[str] = None):
    try:
        client = client_from_env(app.state.http_client)
    except Exception:
        return {"voices": []}
    try:
        voices = client.list_voices(neural_only=neural_only, lang=lang)
        return {"voices": voices}
    except Exception:
        return {"voices": []}


@app.get("/")
def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})


def _validate_wav_file(upload: UploadFile):
    if upload.content_type not in {"audio/wav", "audio/x-wav", "audio/wave"}:
        raise HTTPException(status_code=400, detail="Only WAV audio is supported")


@app.post("/api/stt/recognize", dependencies=[Depends(verify_api_key)])
async def stt_recognize(
    request: Request,
    audio_file: UploadFile = File(...),
    language: str = Form("zh-CN"),
):
    _validate_wav_file(audio_file)
    wav_bytes = await audio_file.read()
    key = None
    auth = request.headers.get("authorization")
    if auth and auth.lower().startswith("bearer "):
        key = auth.split(None, 1)[1]
    client_id = _client_identifier(request, key)
    await rate_limit.enforce_rate_limit(client_id, rate_limit.tier_for_token(key))
    try:
        client = client_from_env(app.state.http_client)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
    try:
        result = await client.speech_to_text(wav_bytes=wav_bytes, language=language)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"STT error: {e}")
    duration = audio.wav_duration_seconds(wav_bytes)
    if duration:
        try:
            if app.state.usage_conn:
                await usage.record_usage(app.state.usage_conn, "stt_seconds", math.ceil(duration))
        except Exception:
            logger.warning("Failed to record STT usage", exc_info=True)
    return result


@app.post("/api/pronunciation/assess", dependencies=[Depends(verify_api_key)])
async def pronunciation_assess(
    request: Request,
    audio_file: UploadFile = File(...),
    reference_text: str = Form(...),
    language: str = Form("en-US"),
):
    _validate_wav_file(audio_file)
    wav_bytes = await audio_file.read()
    key = None
    auth = request.headers.get("authorization")
    if auth and auth.lower().startswith("bearer "):
        key = auth.split(None, 1)[1]
    client_id = _client_identifier(request, key)
    await rate_limit.enforce_rate_limit(client_id, rate_limit.tier_for_token(key))
    try:
        client = client_from_env(app.state.http_client)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
    try:
        result = await client.pronunciation_assessment(
            wav_bytes=wav_bytes,
            language=language,
            reference_text=reference_text,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Pronunciation error: {e}")
    duration = audio.wav_duration_seconds(wav_bytes)
    if duration:
        try:
            if app.state.usage_conn:
                await usage.record_usage(app.state.usage_conn, "pron_seconds", math.ceil(duration))
        except Exception:
            logger.warning("Failed to record pronunciation usage", exc_info=True)
    return result


@app.get("/api/apikeys", dependencies=[Depends(verify_api_key)])
def list_keys():
    _ensure_db()
    items = db.list_keys()
    return {"keys": items}


@app.post("/api/apikeys", dependencies=[Depends(verify_api_key)])
def create_key():
    _ensure_db()
    new_key = secrets.token_urlsafe(32)
    rec = db.add_key(new_key)
    return JSONResponse({"id": rec["id"], "key": new_key})


@app.delete("/api/apikeys/{key_id}", dependencies=[Depends(verify_api_key)])
def delete_key(key_id: str):
    _ensure_db()
    ok = db.delete_key(key_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Key not found")
    return {"ok": True}


@app.get("/api/settings", dependencies=[Depends(verify_api_key)])
def get_settings():
    val = os.getenv("OPENAI_TTS_API_KEY")
    if val:
        return {"openai_tts_api_key": val}
    env_path = Path("/root/TTS/ttl/.env")
    if env_path.exists():
        for ln in env_path.read_text(encoding="utf-8").splitlines():
            if ln.startswith("OPENAI_TTS_API_KEY="):
                return {"openai_tts_api_key": ln.split("=", 1)[1]}
    return {"openai_tts_api_key": None}


@app.post("/api/settings", dependencies=[Depends(verify_api_key)])
async def set_settings(request: Request, openai_key: Optional[str] = Form(None)):
    if request.headers.get("content-type", "").startswith("application/json"):
        body = await request.json()
        openai_key = body.get("openai_tts_api_key") or body.get("openai_key") or openai_key
    if openai_key is None:
        raise HTTPException(status_code=400, detail="Missing openai_tts_api_key")
    env_path = Path("/root/TTS/ttl/.env")
    lines = []
    if env_path.exists():
        lines = env_path.read_text(encoding="utf-8").splitlines()
    found = False
    key_line = f"OPENAI_TTS_API_KEY={openai_key}"
    out_lines = []
    for ln in lines:
        if ln.startswith("OPENAI_TTS_API_KEY="):
            out_lines.append(key_line)
            found = True
        else:
            out_lines.append(ln)
    if not found:
        out_lines.append(key_line)
    env_path.parent.mkdir(parents=True, exist_ok=True)
    env_path.write_text("\n".join(out_lines), encoding="utf-8")
    try:
        os.environ["OPENAI_TTS_API_KEY"] = openai_key
    except Exception:
        pass
    return {"ok": True}


@app.post("/api/tts", dependencies=[Depends(verify_api_key)])
async def tts_synthesize(
    request: Request,
    text: Optional[str] = Form(None),
    voice: str = Form("zh-CN-XiaoxiaoNeural"),
    output_format: str = Form("audio-16khz-32kbitrate-mono-mp3"),
    lang: str = Form("zh-CN"),
    style: str = Form(""),
    role: str = Form(""),
    style_degree: float = Form(0),
    rate: int = Form(0),
    pitch: int = Form(0),
    volume: int = Form(0),
    pause_ms: int = Form(0),
):
    if request.headers.get("content-type", "").startswith("application/json"):
        body = await request.json()
        text = text or body.get("text")
        voice = body.get("voice", voice)
        output_format = body.get("output_format", output_format)
        lang = body.get("lang", lang)
        style = body.get("style", style)
        role = body.get("role", role)
        try:
            style_degree = float(body.get("style_degree", style_degree))
        except Exception:
            style_degree = style_degree
    if not text:
        raise HTTPException(status_code=400, detail="Missing text parameter")
    key = None
    auth = request.headers.get("authorization")
    if auth and auth.lower().startswith("bearer "):
        key = auth.split(None, 1)[1]
    client_id = _client_identifier(request, key)
    await rate_limit.enforce_rate_limit(client_id, rate_limit.tier_for_token(key))
    try:
        client = client_from_env(app.state.http_client)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
    try:
        audio = await client.text_to_speech(
            text=text,
            voice=voice,
            output_format=output_format,
            lang=lang,
            style=style or None,
            style_degree=style_degree or None,
            role=role or None,
            rate=rate or None,
            pitch=pitch or None,
            volume=volume or None,
            pause_ms=pause_ms or None,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"TTS error: {e}")
    try:
        if app.state.usage_conn:
            await usage.record_usage(app.state.usage_conn, "tts_chars", len(text))
    except Exception:
        logger.warning("Failed to record TTS usage", exc_info=True)
    return Response(content=audio, media_type="audio/mpeg")


@app.post("/api/tts/synthesize", dependencies=[Depends(verify_api_key)])
def tts_synthesize_alias():
    return RedirectResponse(url="/api/tts", status_code=307)


@app.get("/api/usage/overview")
async def usage_overview():
    try:
        if app.state.usage_conn is None:
            raise RuntimeError("Usage DB unavailable")
        await usage.init_db(app.state.usage_conn)
        app.state.usage_db_healthy = True
        return await usage.get_usage_overview(app.state.usage_conn)
    except Exception:
        app.state.usage_db_healthy = False
        logger.warning("Falling back to static usage overview", exc_info=True)
        limits = {"tts_chars": 500000}
        data = {
            "limits": limits,
            "all_time": {"tts_chars": 0, "stt_seconds": 0, "pron_seconds": 0},
            "month_key": datetime.utcnow().strftime("%Y-%m"),
            "month": {"tts_chars": 0, "stt_seconds": 0, "pron_seconds": 0},
            "today": {"tts_chars": 0, "stt_seconds": 0, "pron_seconds": 0},
        }
        return data


def _client_identifier(request: Request, token: Optional[str]) -> str:
    if token:
        return f"tk:{token}"
    ip = identity.client_ip(request)
    return f"ip:{ip}"
