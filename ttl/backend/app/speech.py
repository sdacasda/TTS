from __future__ import annotations

import base64
import json
import os
import re
from datetime import datetime, timezone
from typing import Any, Optional

import httpx


class SpeechClient:
    def __init__(self, key: str, region: str):
        self.key = key.strip()
        self.region = region.strip()
        self._token: Optional[str] = None
        self._token_exp: Optional[datetime] = None

    def _tts_base(self) -> str:
        # 允许通过环境变量覆盖基础域名（例如 Foundry 项目可能需要 api.cognitive.microsoft.com）
        override = os.getenv("SPEECH_TTS_ENDPOINT_BASE", "").strip()
        if override:
            return override.rstrip("/")
        return f"https://{self.region}.tts.speech.microsoft.com"

    def _stt_base(self) -> str:
        override = os.getenv("SPEECH_STT_ENDPOINT_BASE", "").strip()
        if override:
            return override.rstrip("/")
        return f"https://{self.region}.stt.speech.microsoft.com"

    def _api_base(self) -> str:
        # Cognitive Services 通用域（部分订阅密钥/Foundry 项目可能要求）
        return f"https://{self.region}.api.cognitive.microsoft.com"

    async def _fetch_token(self) -> str:
        # 使用订阅密钥换取 bearer token
        now = datetime.now(timezone.utc)
        if self._token and self._token_exp and self._token_exp > now:
            return self._token
        url = f"{self._api_base()}/sts/v1.0/issueToken"
        headers = {
            "Ocp-Apim-Subscription-Key": self.key,
            "User-Agent": "speech-portal",
        }
        async with httpx.AsyncClient() as client:
            r = await client.post(url, headers=headers, timeout=30)
            r.raise_for_status()
            token = r.text.strip()

        # 解析 exp 以便缓存，失败则设置 8 分钟
        exp_dt: Optional[datetime] = None
        try:
            parts = token.split(".")
            if len(parts) >= 2:
                payload_b64 = parts[1] + "=" * (-len(parts[1]) % 4)
                payload = json.loads(base64.urlsafe_b64decode(payload_b64.encode()))
                exp_ts = int(payload.get("exp", 0))
                if exp_ts:
                    exp_dt = datetime.fromtimestamp(exp_ts, tz=timezone.utc)
        except Exception:
            exp_dt = None

        if exp_dt is None:
            exp_dt = now.replace(microsecond=0) + timedelta(minutes=8)

        self._token = token
        self._token_exp = exp_dt
        return token

    def _stt_url(self, language: str, *, use_api_base: bool = False) -> str:
        base = self._api_base() if use_api_base else self._stt_base()
        return (
            f"{base}/speech/recognition/conversation/cognitiveservices/v1"
            f"?language={language}"
        )

    def _tts_url(self, *, use_api_base: bool = False) -> str:
        base = self._api_base() if use_api_base else self._tts_base()
        return f"{base}/cognitiveservices/v1"

    def _tts_voices_url(self, *, use_api_base: bool = False) -> str:
        base = self._api_base() if use_api_base else self._tts_base()
        return f"{base}/cognitiveservices/voices/list"

    def _tts_headers(self) -> dict[str, str]:
        headers = {}
        headers["User-Agent"] = "speech-portal"
        return headers

    @staticmethod
    def _fallback_voices() -> list[dict[str, Any]]:
        # 最小可用的静态语音列表，避免上游失败时前端完全不可用
        return [
            {"ShortName": "zh-CN-XiaoxiaoNeural", "Locale": "zh-CN", "Gender": "Female"},
            {"ShortName": "en-US-JennyNeural", "Locale": "en-US", "Gender": "Female"},
            {"ShortName": "en-US-GuyNeural", "Locale": "en-US", "Gender": "Male"},
            {"ShortName": "en-US-EmmaNeural", "Locale": "en-US", "Gender": "Female"},
            {"ShortName": "en-US-AndrewNeural", "Locale": "en-US", "Gender": "Male"},
            {"ShortName": "en-GB-SoniaNeural", "Locale": "en-GB", "Gender": "Female"},
        ]

    async def list_voices(self) -> list[dict[str, Any]]:
        headers = self._tts_headers()
        headers["Accept"] = "application/json"
        async def _fetch(use_api_base: bool) -> list[dict[str, Any]]:
            async with httpx.AsyncClient() as client:
                r = await client.get(
                    self._tts_voices_url(use_api_base=use_api_base),
                    headers=headers,
                    timeout=60,
                )
                r.raise_for_status()
                data = r.json()
            if not isinstance(data, list):
                raise RuntimeError("Unexpected voices list response")
            return data

        # 先尝试标准 tts 域名，若 401/403 再尝试 api.cognitive 域名（适配部分长密钥/Foundry 项目）
        try:
            return await _fetch(use_api_base=False)
        except httpx.HTTPStatusError as e:
            if e.response.status_code in (401, 403):
                try:
                    return await _fetch(use_api_base=True)
                except Exception:
                    pass
            status_code = e.response.status_code
            try:
                error_text = (e.response.text or "")[:200].replace("\n", " ")
            except Exception:
                error_text = "unable to read response text"
            raise RuntimeError(f"Azure API HTTP {status_code}: {error_text}")
        except httpx.RequestError as e:
            try:
                error_msg = str(e)
            except Exception:
                error_msg = "request error"
            raise RuntimeError(f"Network error: {error_msg}")
        # 若上游返回空列表，提供静态兜底，保证前端可用
        try:
            voices = await _fetch(use_api_base=False)
        except Exception:
            voices = []
        if not voices:
            return self._fallback_voices()
        return voices

    async def speech_to_text(self, wav_bytes: bytes, language: str) -> dict[str, Any]:
        headers = self._get_auth_headers()
        headers.update(
            {
                "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
                "Accept": "application/json",
            }
        )
        async def _post(use_api_base: bool) -> dict[str, Any]:
            async with httpx.AsyncClient() as client:
                r = await client.post(
                    self._stt_url(language, use_api_base=use_api_base),
                    headers=headers,
                    content=wav_bytes,
                    timeout=60,
                )
                r.raise_for_status()
                return r.json()

        try:
            return await _post(use_api_base=False)
        except httpx.HTTPStatusError as e:
            if e.response.status_code in (401, 403):
                try:
                    return await _post(use_api_base=True)
                except Exception:
                    pass
            raise

    async def pronunciation_assessment(
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

        headers = self._get_auth_headers()
        headers.update(
            {
                "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
                "Accept": "application/json",
                "Pronunciation-Assessment": pa_b64,
            }
        )
        async def _post(use_api_base: bool) -> dict[str, Any]:
            async with httpx.AsyncClient() as client:
                r = await client.post(
                    self._stt_url(language, use_api_base=use_api_base),
                    headers=headers,
                    content=wav_bytes,
                    timeout=60,
                )
                r.raise_for_status()
                return r.json()

        try:
            return await _post(use_api_base=False)
        except httpx.HTTPStatusError as e:
            if e.response.status_code in (401, 403):
                try:
                    return await _post(use_api_base=True)
                except Exception:
                    pass
            raise

    async def text_to_speech(
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
        async def _post(use_api_base: bool) -> bytes:
            async with httpx.AsyncClient() as client:
                r = await client.post(
                    self._tts_url(use_api_base=use_api_base),
                    headers=headers,
                    content=ssml.encode("utf-8"),
                    timeout=60,
                )
                r.raise_for_status()
                return r.content

        try:
            return await _post(use_api_base=False)
        except httpx.HTTPStatusError as e:
            if e.response.status_code in (401, 403):
                try:
                    return await _post(use_api_base=True)
                except Exception:
                    pass
            raise


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

    parts = re.split(r"([，。！？；\n])", text)
    out: list[str] = []
    for p in parts:
        if not p:
            continue
        if p == "\n":
            out.append(f"<break time='{pause_ms_i}ms' />")
            continue
        out.append(_escape_xml(p))
        if p in ("，", "。", "；", "！", "？"):
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
    key = os.getenv("SPEECH_KEY", "").strip()
    region = os.getenv("SPEECH_REGION", "").strip()
    if not key or not region:
        raise RuntimeError("Missing SPEECH_KEY or SPEECH_REGION")
    return SpeechClient(key=key, region=region)
