from __future__ import annotations

from datetime import datetime, timezone

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

from .speech import client_from_env
from .usage import get_usage_summary, init_db, month_key, record_usage

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
) -> Response:
    if not text.strip():
        raise HTTPException(status_code=400, detail="Empty text")

    try:
        c = client_from_env()
        audio_bytes = c.text_to_speech(text=text, voice=voice, output_format=output_format)
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    record_usage("tts_chars", len(text))
    return Response(content=audio_bytes, media_type="audio/mpeg")


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("index.html", {"request": request})
