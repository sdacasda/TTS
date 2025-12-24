from __future__ import annotations

import os
import subprocess
from datetime import datetime, timezone

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

from .speech import client_from_env
from .usage import get_usage_overview, get_usage_summary, init_db, month_key, record_usage

app = FastAPI(
    docs_url=None,
    redoc_url=None
)

app.mount("/static", StaticFiles(directory="app/static"), name="static")

templates = Jinja2Templates(directory="app/templates")


@app.on_event("startup")
def _startup() -> None:
    init_db()


@app.get("/api/health")
def health() -> dict:
    return {"ok": True}


@app.post("/api/update")
def update_app() -> dict:
    """Update application code online"""
    try:
        result = subprocess.run(
            ["git", "pull", "origin", "main"],
            cwd="/app",
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=f"Update failed: {result.stderr}"
            )
        
        import threading
        def restart():
            import time
            time.sleep(2)
            os.system("kill -TERM 1")
        
        threading.Thread(target=restart, daemon=True).start()
        
        return {
            "ok": True,
            "message": "Update successful, service will restart in 2 seconds",
            "output": result.stdout
        }
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Update timeout")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Update failed: {str(e)}")


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
    role: str = Form(""),
    style_degree: float = Form(0),
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
            role=role or None,
            style_degree=style_degree or None,
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
