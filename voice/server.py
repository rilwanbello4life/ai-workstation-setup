"""OpenAI-compatible local voice server: Whisper transcription + Kokoro speech.

Exposes the two endpoints the OpenAI client libraries already know about, so
anything that can be pointed at a custom base URL works unchanged:

    POST /v1/audio/transcriptions   faster-whisper large-v3-turbo
    POST /v1/audio/speech           Kokoro-82M

Models load lazily on first request, so starting the server is instant and an
unused engine never occupies VRAM.

Run:
    python server.py
    python server.py --host 127.0.0.1 --port 8100 --whisper-device cpu
"""

from __future__ import annotations

import argparse
import io
import logging
import os
import tempfile
import threading
from typing import Iterator

import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)-7s %(message)s")
log = logging.getLogger("voice")

# Kokoro is fixed at 24 kHz.
KOKORO_SAMPLE_RATE = 24_000

# OpenAI voice names mapped onto Kokoro's voice pack, so clients written against
# the OpenAI API keep working without knowing anything about Kokoro.
OPENAI_VOICE_ALIASES = {
    "alloy": "af_heart",
    "echo": "am_michael",
    "fable": "bf_emma",
    "onyx": "am_adam",
    "nova": "af_bella",
    "shimmer": "af_sarah",
}

app = FastAPI(title="Local Voice Server", version="1.0")

_whisper = None
_whisper_lock = threading.Lock()
_kokoro = None
_kokoro_lock = threading.Lock()

config = argparse.Namespace(
    whisper_model="large-v3-turbo",
    whisper_device="cuda",
    whisper_compute_type="int8_float16",
    kokoro_lang="a",
)


def get_whisper():
    """Load faster-whisper on first use, falling back to CPU if CUDA is absent."""
    global _whisper
    if _whisper is not None:
        return _whisper

    with _whisper_lock:
        if _whisper is not None:
            return _whisper

        from faster_whisper import WhisperModel

        device = config.whisper_device
        compute_type = config.whisper_compute_type
        try:
            log.info("Loading Whisper %s on %s (%s)", config.whisper_model, device, compute_type)
            _whisper = WhisperModel(config.whisper_model, device=device, compute_type=compute_type)
        except Exception as exc:  # noqa: BLE001 - any CUDA/driver failure should degrade, not crash
            if device == "cuda":
                log.warning("CUDA load failed (%s); falling back to CPU int8", exc)
                _whisper = WhisperModel(config.whisper_model, device="cpu", compute_type="int8")
            else:
                raise
        log.info("Whisper ready")
        return _whisper


def get_kokoro():
    """Load Kokoro on first use. It runs fine on CPU, so it never competes for VRAM."""
    global _kokoro
    if _kokoro is not None:
        return _kokoro

    with _kokoro_lock:
        if _kokoro is not None:
            return _kokoro

        from kokoro import KPipeline

        log.info("Loading Kokoro-82M (lang_code=%s)", config.kokoro_lang)
        _kokoro = KPipeline(lang_code=config.kokoro_lang)
        log.info("Kokoro ready")
        return _kokoro


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "whisper_loaded": _whisper is not None,
        "kokoro_loaded": _kokoro is not None,
        "whisper_model": config.whisper_model,
    }


@app.get("/v1/models")
def list_models() -> dict:
    """Minimal OpenAI-style model list so generic clients can discover what exists."""
    return {
        "object": "list",
        "data": [
            {"id": config.whisper_model, "object": "model", "owned_by": "local"},
            {"id": "kokoro-82m", "object": "model", "owned_by": "local"},
        ],
    }


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(default=""),
    language: str | None = Form(default=None),
    prompt: str | None = Form(default=None),
    response_format: str = Form(default="json"),
    temperature: float = Form(default=0.0),
):
    """OpenAI-compatible transcription endpoint."""
    del model  # accepted for compatibility; the loaded model is fixed at startup

    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty audio file")

    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(data)
            tmp_path = tmp.name

        segments, info = get_whisper().transcribe(
            tmp_path,
            language=language,
            initial_prompt=prompt,
            temperature=temperature,
            beam_size=5,
            vad_filter=True,
        )
        collected = list(segments)
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    text = "".join(s.text for s in collected).strip()

    if response_format == "text":
        return Response(content=text, media_type="text/plain")

    if response_format in ("verbose_json", "json"):
        payload: dict = {"text": text}
        if response_format == "verbose_json":
            payload.update(
                {
                    "language": info.language,
                    "duration": info.duration,
                    "segments": [
                        {"id": i, "start": s.start, "end": s.end, "text": s.text}
                        for i, s in enumerate(collected)
                    ],
                }
            )
        return JSONResponse(payload)

    raise HTTPException(status_code=400, detail=f"unsupported response_format: {response_format}")


class SpeechRequest(BaseModel):
    model: str = "kokoro-82m"
    input: str
    voice: str = "af_heart"
    response_format: str = "wav"
    speed: float = 1.0


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest):
    """OpenAI-compatible text-to-speech endpoint."""
    if not req.input.strip():
        raise HTTPException(status_code=400, detail="input is empty")

    voice = OPENAI_VOICE_ALIASES.get(req.voice, req.voice)

    try:
        generator: Iterator = get_kokoro()(req.input, voice=voice, speed=req.speed)
        chunks = [np.asarray(item[2], dtype=np.float32) for item in generator]
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"synthesis failed: {exc}") from exc

    if not chunks:
        raise HTTPException(status_code=500, detail="synthesis produced no audio")

    audio = np.concatenate(chunks)

    fmt = req.response_format.lower()
    # soundfile covers wav/flac/ogg natively. mp3 needs libsndfile 1.1+, which
    # ships with recent wheels; wav is the safe default for local use.
    sf_format = {"wav": "WAV", "flac": "FLAC", "ogg": "OGG", "opus": "OGG", "mp3": "MP3"}.get(fmt)
    if sf_format is None:
        raise HTTPException(status_code=400, detail=f"unsupported response_format: {fmt}")

    buf = io.BytesIO()
    try:
        sf.write(buf, audio, KOKORO_SAMPLE_RATE, format=sf_format)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=400,
            detail=f"could not encode {fmt} ({exc}); try response_format=wav",
        ) from exc

    media_types = {
        "WAV": "audio/wav",
        "FLAC": "audio/flac",
        "OGG": "audio/ogg",
        "MP3": "audio/mpeg",
    }
    return Response(content=buf.getvalue(), media_type=media_types[sf_format])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="bind address (keep on loopback)")
    parser.add_argument("--port", type=int, default=8100)
    parser.add_argument("--whisper-model", default="large-v3-turbo")
    parser.add_argument("--whisper-device", default="cuda", choices=["cuda", "cpu", "auto"])
    parser.add_argument("--whisper-compute-type", default="int8_float16")
    parser.add_argument(
        "--kokoro-lang",
        default="a",
        help="Kokoro language code: a=American English, b=British English, etc.",
    )
    args = parser.parse_args()

    config.whisper_model = args.whisper_model
    config.whisper_device = args.whisper_device
    config.whisper_compute_type = args.whisper_compute_type
    config.kokoro_lang = args.kokoro_lang

    import uvicorn

    log.info("Listening on http://%s:%d", args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
