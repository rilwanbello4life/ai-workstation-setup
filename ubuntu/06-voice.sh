#!/usr/bin/env bash
# Phase 8.6 - Local voice server: Whisper transcription + Kokoro speech.
#
# Installs the server from ../voice/ into its own virtualenv on ext4 and
# registers an optional systemd user service.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$KIT_ROOT/voice"
APP="${APPS}/voice"

[[ -f "$SRC/server.py" ]] || die "Cannot find $SRC/server.py - run this from inside the kit."

section "Installing to $APP"

mkdir -p "$APP"
cp "$SRC/server.py" "$SRC/requirements.txt" "$APP/"
ok "Copied server.py and requirements.txt"

section "Virtual environment"

VENV="$APP/.venv"
if have uv; then
    [[ -d "$VENV" ]] || uv venv "$VENV" --python 3.12
    PY="$VENV/bin/python"
    PIP=(uv pip install --python "$PY")
else
    [[ -d "$VENV" ]] || python3 -m venv "$VENV"
    PY="$VENV/bin/python"
    PIP=("$PY" -m pip install)
fi
ok "venv at $VENV"

section "Dependencies"

info "PyTorch from the cu128 index (Blackwell sm_120)."
"${PIP[@]}" torch --index-url https://download.pytorch.org/whl/cu128

info "Server dependencies."
"${PIP[@]}" -r "$APP/requirements.txt"
ok "Installed."

section "Launcher"

launcher="$APPS/start-voice.sh"
cat > "$launcher" <<EOF
#!/usr/bin/env bash
# Loopback only - the server has no authentication.
set -euo pipefail
exec "$PY" "$APP/server.py" --host 127.0.0.1 --port 8100 "\$@"
EOF
chmod +x "$launcher"
ok "Wrote $launcher"

section "systemd user service (optional)"

unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir"
cat > "$unit_dir/voice-server.service" <<EOF
[Unit]
Description=Local voice server (Whisper + Kokoro)
After=network.target

[Service]
Type=simple
ExecStart=$PY $APP/server.py --host 127.0.0.1 --port 8100
Environment=HF_HOME=$AI_ROOT/hf-cache
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
ok "Unit written: $unit_dir/voice-server.service"

cat <<EOF

  Models download on first request, not now, so the first call is slow and
  every later one is instant.

  Run it in the foreground:
      $launcher

  Or as a background service:
      systemctl --user enable --now voice-server
      systemctl --user status voice-server

  Check it:
      curl http://127.0.0.1:8100/health

  Transcribe:
      curl -s http://127.0.0.1:8100/v1/audio/transcriptions \\
           -F file=@recording.m4a -F response_format=json

  Speak:
      curl -s http://127.0.0.1:8100/v1/audio/speech \\
           -H 'Content-Type: application/json' \\
           -d '{"input":"Workstation ready.","voice":"af_heart"}' \\
           --output speech.wav

  Kokoro runs on CPU, so speech never competes with the GPU. If Whisper needs
  the GPU while Strata holds it, start with --whisper-device cpu.

  Next: ./07-strata.sh
EOF
