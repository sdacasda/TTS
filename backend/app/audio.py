from __future__ import annotations

import io
import wave
from typing import Optional


def wav_duration_seconds(wav_bytes: bytes) -> Optional[float]:
    bio = io.BytesIO(wav_bytes)
    try:
        with wave.open(bio, "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate() or 1
            return frames / float(rate)
    except Exception:
        return None
