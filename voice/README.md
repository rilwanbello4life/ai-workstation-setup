# Local voice server

One process exposing both halves of the voice stack on the two endpoints the OpenAI client libraries already speak:

| Endpoint | Engine | Notes |
|---|---|---|
| `POST /v1/audio/transcriptions` | faster-whisper `large-v3-turbo` | MIT, 809M params, ~1.5 GB at int8 |
| `POST /v1/audio/speech` | Kokoro-82M | Apache-2.0, commercial use allowed, CPU-only is fine |

Models load lazily on first request, so an engine you never call costs nothing. Kokoro running on CPU means text-to-speech never competes with the GPU while a model is loaded.

## Install

Both platforms need PyTorch from the cu128 index first — Blackwell is sm_120 and there are no sm_120 kernels in cu124 or earlier.

### Windows

Handled automatically by [`../windows/05-install-ai-stack.ps1`](../windows/05-install-ai-stack.ps1), which installs into `C:\AI\voice` and writes a `start-voice.ps1` launcher. To install only this part:

```powershell
.\05-install-ai-stack.ps1 -Only Voice
```

To do it by hand instead:

```powershell
cd <this folder>
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install torch --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```

### Ubuntu

Handled automatically by [`../ubuntu/setup-all.sh`](../ubuntu/setup-all.sh). To do it by hand:

```bash
uv venv .venv --python 3.12 && source .venv/bin/activate
uv pip install torch --index-url https://download.pytorch.org/whl/cu128
uv pip install -r requirements.txt
```

## Run

```bash
python server.py                      # http://127.0.0.1:8100
python server.py --whisper-device cpu # if the GPU is busy with Strata or ComfyUI
```

Keep it on loopback. There is no authentication.

Check it is alive:

```bash
curl http://127.0.0.1:8100/health
```

## Use

### Transcription

```bash
curl -s http://127.0.0.1:8100/v1/audio/transcriptions \
  -F file=@recording.m4a \
  -F response_format=json
```

### Speech

```bash
curl -s http://127.0.0.1:8100/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"input": "The workstation is ready.", "voice": "af_heart"}' \
  --output speech.wav
```

### From the OpenAI Python client

Because the endpoints are OpenAI-shaped, existing code works by changing only the base URL:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8100/v1", api_key="local")

with open("recording.m4a", "rb") as f:
    print(client.audio.transcriptions.create(model="whisper-1", file=f).text)

client.audio.speech.create(
    model="kokoro-82m", voice="nova", input="Hello from the workstation."
).stream_to_file("out.wav")
```

The six OpenAI voice names (`alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`) are mapped onto Kokoro voices, so unmodified OpenAI client code gets sensible output. You can also pass a Kokoro voice name directly, for example `af_heart` or `bm_george`.

## Options

| Flag | Default | Purpose |
|---|---|---|
| `--whisper-model` | `large-v3-turbo` | Any faster-whisper size string |
| `--whisper-device` | `cuda` | Falls back to CPU automatically if CUDA fails |
| `--whisper-compute-type` | `int8_float16` | `int8` on CPU, `float16` for maximum accuracy |
| `--kokoro-lang` | `a` | `a` American English, `b` British English |
| `--port` | `8100` | Chosen to avoid Strata (8080), LM Studio (1234), ComfyUI (8188) |

## Alternatives worth knowing

- **Parakeet TDT 0.6B v3** (`nvidia/parakeet-tdt-0.6b-v3`, CC-BY-4.0) is faster than Whisper for English and 25 European languages. Swap it in if transcription latency ever matters more than language coverage.
- **Chatterbox** (`ResembleAI/chatterbox`, MIT) clones a voice from about 10 seconds of reference audio and needs ~6 GB of VRAM. Kokoro cannot clone.
- **LM Studio Bionic** has its own built-in local voice transcription, so for dictation inside Bionic you do not need this server at all. It is here for everything else.

Avoid XTTS-v2 and F5-TTS for anything commercial. Both carry non-commercial licences, and in the XTTS case there is no longer anyone to buy a commercial licence from.
