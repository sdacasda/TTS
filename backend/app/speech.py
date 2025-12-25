from __future__ import annotations

import base64
import json
import os
import re
import xml.etree.ElementTree as ET
from typing import Any, Optional

import httpx


class SpeechClient:
    def __init__(self, key: str, region: str, http_client: Optional[httpx.AsyncClient] = None):
        self.key = (key or "").strip()
        self.region = region
        self.http_client = http_client

    def _get_auth_headers(self) -> dict[str, str]:
        if not self.key:
            return {}
        if self.key.startswith("Bearer "):
            return {"Authorization": self.key}
        if self.key.count('.') == 2:
            return {"Authorization": f"Bearer {self.key}"}
        return {"Ocp-Apim-Subscription-Key": self.key}

    def _stt_url(self, language: str) -> str:
        return (
            f"https://{self.region}.stt.speech.microsoft.com/"
            f"speech/recognition/conversation/cognitiveservices/v1?language={language}"
        )

    def _tts_url(self) -> str:
        return f"https://{self.region}.tts.speech.microsoft.com/cognitiveservices/v1"

    def _tts_voices_url(self) -> str:
        return f"https://{self.region}.tts.speech.microsoft.com/cognitiveservices/voices/list"

    def _tts_headers(self) -> dict[str, str]:
        headers = self._get_auth_headers()
        headers["User-Agent"] = "speech-portal"
        return headers

    async def list_voices(self) -> list[dict[str, Any]]:
        headers = self._tts_headers()
        headers["Accept"] = "application/json"
        client = self.http_client or httpx.AsyncClient()
        r = await client.get(self._tts_voices_url(), headers=headers, timeout=60)
        r.raise_for_status()
        if self.http_client is None:
            await client.aclose()
        return r.json()

    async def speech_to_text(self, wav_bytes: bytes, language: str) -> dict[str, Any]:
        headers = self._get_auth_headers()
        headers.update({
            "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
            "Accept": "application/json",
        })
        client = self.http_client or httpx.AsyncClient()
        r = await client.post(self._stt_url(language), headers=headers, content=wav_bytes, timeout=60)
        r.raise_for_status()
        if self.http_client is None:
            await client.aclose()
        return r.json()

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
        headers.update({
            "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
            "Accept": "application/json",
            "Pronunciation-Assessment": pa_b64,
        })
        client = self.http_client or httpx.AsyncClient()
        r = await client.post(self._stt_url(language), headers=headers, content=wav_bytes, timeout=60)
        r.raise_for_status()
        if self.http_client is None:
            await client.aclose()
        return r.json()

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
        client = self.http_client or httpx.AsyncClient()
        r = await client.post(self._tts_url(), headers=headers, content=ssml.encode("utf-8"), timeout=60)
        r.raise_for_status()
        if self.http_client is None:
            await client.aclose()
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


def _append_inner(parent: ET.Element, inner_ssml: str) -> None:
    # Wrap the string inside a temporary root so we can parse fragments
    wrapper = ET.fromstring(f"<root>{inner_ssml}</root>")
    parent.text = wrapper.text
    for child in list(wrapper):
        wrapper.remove(child)
        parent.append(child)


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

    ET.register_namespace("", "http://www.w3.org/2001/10/synthesis")
    ET.register_namespace("mstts", "https://www.w3.org/2001/mstts")
    speak = ET.Element(
        "speak",
        {
            "version": "1.0",
            "xmlns": "http://www.w3.org/2001/10/synthesis",
            "xmlns:mstts": "https://www.w3.org/2001/mstts",
            "xml:lang": lang,
        },
    )
    voice_el = ET.SubElement(speak, "voice", {"name": voice})

    target_parent = voice_el
    if style or role:
        attrs: dict[str, str] = {}
        if style:
            attrs["style"] = style
        if style and style_degree is not None:
            attrs["styledegree"] = f"{style_degree:.2f}"
        if role:
            attrs["role"] = role
        target_parent = ET.SubElement(voice_el, "{https://www.w3.org/2001/mstts}express-as", attrs)

    prosody_el = None
    prosody_attrs: dict[str, str] = {}
    if rate is not None:
        prosody_attrs["rate"] = f"{rate}%"
    if pitch is not None:
        prosody_attrs["pitch"] = f"{pitch}%"
    if volume is not None:
        prosody_attrs["volume"] = f"{volume}%"
    if prosody_attrs:
        prosody_el = ET.SubElement(target_parent, "prosody", prosody_attrs)
        _append_inner(prosody_el, inner)
    else:
        _append_inner(target_parent, inner)

    return ET.tostring(speak, encoding="utf-8").decode("utf-8")


def client_from_env(http_client: Optional[httpx.AsyncClient] = None) -> SpeechClient:
    key = os.getenv("SPEECH_KEY")
    region = os.getenv("SPEECH_REGION")
    if not key or not region:
        raise RuntimeError("Missing SPEECH_KEY or SPEECH_REGION")
    return SpeechClient(key=key, region=region, http_client=http_client)
