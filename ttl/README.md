# Azure Speech Free(F0) Portal

## Quick start (Docker)

1. Copy `.env.example` to `.env` and fill `SPEECH_KEY` / `SPEECH_REGION` (optional: `OPENAI_TTS_API_KEY` for OpenAI TTS–compatible headers).
2. Start:

```bash
docker compose up -d --build
```

Open:

- http://YOUR_SERVER:8000

## One-liner install (clone + run)

```bash
git clone https://gist.github.com/<YOUR_GIST_ID>.git speech-portal && cd speech-portal && cp .env.example .env && docker compose up -d --build
```

## Notes about quota

Azure Speech Free(F0) does not provide a universal API to query “remaining free quota” directly.
This project shows quota by local metering:

- STT: sum of audio duration seconds.
- TTS: sum of input text chars.
- Pronunciation assessment: sum of audio duration seconds.

You can adjust monthly limits in `.env`.
