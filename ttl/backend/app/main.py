from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional
import logging
from dotenv import load_dotenv

from fastapi import FastAPI, File, Form, HTTPException, UploadFile, Security, Depends, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import HTMLResponse, Response, StreamingResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request
from pydantic import BaseModel

from .emotion import classify, EMOTION_STYLE_MAP
from .speech import client_from_env
from .usage import get_usage_overview, get_usage_summary, init_db, month_key, record_usage

load_dotenv()
logger = logging.getLogger("uvicorn.error")

# Security scheme
security = HTTPBearer(auto_error=False)

async def verify_api_key(
    credentials: Optional[HTTPAuthorizationCredentials] = Security(security),
):
    """
    Verify API Key if configured in environment variables.
    If API_KEY is set, requests must provide it via Bearer token.
    If API_KEY is not set, authentication is skipped.
    """
    expected_api_key = os.getenv("API_KEY")
    
    # If no API key is configured on the server, allow access without auth
    if not expected_api_key:
        return None
        
    # If API key is configured, client must provide it
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing authentication token",
            headers={"WWW-Authenticate": "Bearer"},
        )
        
    if credentials.credentials != expected_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API Key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    return credentials.credentials


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(
    docs_url=None,
    redoc_url=None,
    lifespan=lifespan
)

app.mount("/static", StaticFiles(directory="app/static"), name="static")

templates = Jinja2Templates(directory="app/templates")


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "version": "2025-12-25-v2"}


@app.get("/api/debug/env", dependencies=[Depends(verify_api_key)])
def debug_env() -> dict:
    """Debug endpoint to check environment"""
    return {
        "has_speech_key": bool(os.getenv("SPEECH_KEY")),
        "speech_region": os.getenv("SPEECH_REGION"),
        "key_length": len(os.getenv("SPEECH_KEY", "")),
    }


@app.post("/api/update", dependencies=[Depends(verify_api_key)])
def update_app() -> dict:
    """Update application code online"""
    try:
        # Find git repository root
        current_path = Path(__file__).resolve()
        git_dir = None
        
        for parent in current_path.parents:
            if (parent / ".git").exists():
                git_dir = parent
                break
        
        if not git_dir:
            # Fallback to /repo if not found (Docker default)
            if Path("/repo/.git").exists():
                git_dir = Path("/repo")
            else:
                logger.error("Update failed: Could not find .git directory")
                raise HTTPException(
                    status_code=500,
                    detail="Update failed: Could not find git repository root."
                )
        
        logger.info(f"Starting git pull in {git_dir}")
        result = subprocess.run(
            ["git", "pull", "origin", "main"],
            cwd=str(git_dir),
            capture_output=True,
            text=True,
            timeout=30
        )
        
        logger.info(f"Git pull output: {result.stdout}")
        if result.stderr:
            logger.warning(f"Git pull stderr: {result.stderr}")
        
        if result.returncode != 0:
            logger.error(f"Git pull failed with code {result.returncode}")
            raise HTTPException(
                status_code=500,
                detail=f"Update failed: {result.stderr}"
            )
        
        logger.info("Code updated successfully, restarting application...")
        
        def restart():
            time.sleep(2)
            # In Docker, PID 1 is usually the entrypoint
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


@app.get("/api/usage/summary", dependencies=[Depends(verify_api_key)])
async def usage_summary(month: str | None = None) -> dict:
    if not month:
        month = month_key(datetime.now(timezone.utc))
    return await get_usage_summary(month)


@app.get("/api/usage/overview", dependencies=[Depends(verify_api_key)])
async def usage_overview() -> dict:
    return await get_usage_overview()


@app.get("/api/tts/voices", dependencies=[Depends(verify_api_key)])
async def tts_voices(locale: str | None = None, neural_only: bool = True) -> dict:
    try:
        c = client_from_env()
        logger.info(f"Fetching voices from Azure, region: {c.region}")
        voices = await c.list_voices()
        logger.info(f"Successfully fetched {len(voices)} voices")
    except Exception as e:
        error_msg = f"Failed to fetch voices: {type(e).__name__}: {str(e)}"
        logger.error(error_msg)
        raise HTTPException(status_code=502, detail=error_msg)

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


@app.post("/api/stt/recognize", dependencies=[Depends(verify_api_key)])
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
        result = await c.speech_to_text(wav_bytes=wav_bytes, language=language)
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    if seconds > 0:
        await record_usage("stt_seconds", seconds)

    return result


@app.post("/api/pronunciation/assess", dependencies=[Depends(verify_api_key)])
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
        result = await c.pronunciation_assessment(
            wav_bytes=wav_bytes,
            language=language,
            reference_text=reference_text,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    if seconds > 0:
        await record_usage("pron_seconds", seconds)

    return result


@app.post("/api/tts/synthesize", dependencies=[Depends(verify_api_key)])
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
        audio_bytes = await c.text_to_speech(
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

    await record_usage("tts_chars", len(text))
    return Response(content=audio_bytes, media_type="audio/mpeg")


# ==================== OpenAI Compatible TTS API ====================

class OpenAITTSRequest(BaseModel):
    """OpenAI compatible TTS request model"""
    model: str
    input: str
    voice: str
    response_format: Optional[str] = "mp3"
    speed: Optional[float] = 1.0
    gain: Optional[float] = 0.0
    sample_rate: Optional[int] = None


@app.post("/v1/audio/speech", dependencies=[Depends(verify_api_key)])
async def openai_tts_speech(request: OpenAITTSRequest) -> Response:
    """
    OpenAI compatible TTS API endpoint.
    
    Compatible with: https://platform.openai.com/docs/api-reference/audio/createSpeech
    
    Request body:
    - model: TTS model (mapped to Azure voice)
    - input: Text to synthesize
    - voice: Voice identifier (Azure voice name)
    - response_format: Audio format (mp3, wav, opus, etc.)
    - speed: Speech speed (0.25-4.0, default 1.0)
    - gain: Volume gain in dB (optional, for compatibility)
    - sample_rate: Sample rate in Hz (optional, for compatibility)
    """
    if not request.input.strip():
        raise HTTPException(status_code=400, detail="Empty input text")
    
    # Speed mapping: OpenAI uses 0.25-4.0, Azure uses percentage
    # Convert OpenAI speed to Azure rate: speed 1.0 = 0%, speed 2.0 = +100%
    rate = int((request.speed - 1.0) * 100) if request.speed else 0
    rate = max(-50, min(200, rate))  # Clamp to Azure limits
    
    # Map response format to Azure output format
    format_mapping = {
        "mp3": "audio-16khz-32kbitrate-mono-mp3",
        "opus": "audio-16khz-32kbitrate-mono-opus",
        "aac": "audio-16khz-32kbitrate-mono-mp3",  # Fallback to mp3
        "flac": "audio-16khz-32kbitrate-mono-mp3",  # Fallback to mp3
        "wav": "riff-16khz-16bit-mono-pcm",
        "pcm": "raw-16khz-16bit-mono-pcm",
    }
    
    output_format = format_mapping.get(
        request.response_format.lower(), 
        "audio-16khz-32kbitrate-mono-mp3"
    )
    
    # Map OpenAI voices to Azure voices
    openai_voice_map = {
        "alloy": "en-US-AvaNeural",
        "echo": "en-US-AndrewNeural",
        "fable": "en-GB-SoniaNeural",
        "onyx": "en-US-BrianNeural",
        "nova": "en-US-EmmaNeural",
        "shimmer": "en-US-JennyNeural",
    }
    
    # Use mapped voice if available, otherwise use the provided voice (assuming it's an Azure voice name)
    voice = openai_voice_map.get(request.voice.lower(), request.voice)
    
    # Determine language from voice name
    # Azure voice names are typically "Locale-VoiceNameNeural" (e.g. "en-US-JennyNeural")
    # We extract the first two parts to get the locale (e.g. "en-US")
    parts = voice.split("-")
    if len(parts) >= 3: # e.g. en-US-JennyNeural
        lang = f"{parts[0]}-{parts[1]}"
    else:
        # If we can't determine language from voice, default to en-US for OpenAI mapped voices,
        # or zh-CN if it looks like a custom request that failed parsing
        lang = "en-US" if request.voice.lower() in openai_voice_map else "zh-CN"
    
    mood = classify(request.input)
    azure_style = EMOTION_STYLE_MAP.get(mood, "chat")
    logger.info(f"Emotion analysis: {mood} -> {azure_style}")

    logger.info(f"OpenAI TTS: input_voice={request.voice}, mapped_voice={voice}, lang={lang}, speed={request.speed}, rate={rate}, format={request.response_format}")
    
    try:
        c = client_from_env()
        audio_bytes = await c.text_to_speech(
            text=request.input,
            voice=voice,
            output_format=output_format,
            lang=lang,
            style=azure_style,
            role=None,
            style_degree=None,
            rate=rate,
            pitch=0,
            volume=0,
            pause_ms=0,
        )
    except Exception as e:
        logger.error(f"TTS synthesis failed: {e}")
        raise HTTPException(status_code=502, detail=f"Speech synthesis failed: {str(e)}")
    
    # Record usage
    await record_usage("tts_chars", len(request.input))
    
    # Determine media type
    media_type_mapping = {
        "mp3": "audio/mpeg",
        "opus": "audio/opus",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "pcm": "audio/pcm",
    }
    media_type = media_type_mapping.get(request.response_format.lower(), "audio/mpeg")
    
    return Response(content=audio_bytes, media_type=media_type)


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("index.html", {"request": request})


@app.get("/favicon.ico")
def favicon():
    favicon_path = os.path.join("app", "static", "favicon.ico")
    if os.path.exists(favicon_path):
        return FileResponse(favicon_path)
    return Response(status_code=204)
