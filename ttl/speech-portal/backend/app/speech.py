from __future__ import annotations

import base64
import json
import os
from typing import Any

import requests


class SpeechClient:
    def __init__(self, key: str, region: str):
        self.key = key
        self.region = region

    def _stt_url(self, language: str) -> str:
        return (
            f"https://{self.region}.stt.speech.microsoft.com/speech/recognition/"
            f"conversation/cognitiveservices/v1?language={language}"
        )

    def _tts_url(self) -> str:
        return f"https://{self.region}.tts.speech.microsoft.com/cognitiveservices/v1"

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

    def text_to_speech(self, text: str, voice: str, output_format: str) -> bytes:
        ssml = (
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            f"<voice name='{voice}'>"
            f"{_escape_xml(text)}"
            "</voice></speak>"
        )

        headers = {
            "Ocp-Apim-Subscription-Key": self.key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": output_format,
            "User-Agent": "speech-portal",
        }
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


def client_from_env() -> SpeechClient:
    key = os.getenv("SPEECH_KEY")
    region = os.getenv("SPEECH_REGION")
    if not key or not region:
        raise RuntimeError("Missing SPEECH_KEY or SPEECH_REGION")
    return SpeechClient(key=key, region=region)
