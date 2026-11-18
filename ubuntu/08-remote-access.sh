#!/usr/bin/env bash
# Phase 8.8 - Remote access over Tailscale.
#
# None of the AI services has authentication, so nothing here ever binds them
# to a public interface. Instead:
#
#   1. Tailscale builds a private WireGuard network between your own devices.
#   2. Open WebUI gives phones a real chat UI with its own user accounts.
#   3. 'tailscale serve' publishes loopback services as HTTPS URLs that only
#      your tailnet can reach. The services themselves stay on 127.0.0.1.
#
# Never use 'tailscale funnel' here - that is the public internet.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

WEBUI_PORT="${WEBUI_PORT:-3000}"   # 8080 is Strata; Open WebUI must move
APP="$APPS/open-webui"

# ---------------------------------------------------------------------------
section "Tailscale"

if have tailscale; then
    ok "Already installed ($(tailscale version | head -n1))"
else
    info "Installing from tailscale.com."
    curl -fsSL https://tailscale.com/install.sh | sh
    have tailscale || die "Tailscale install failed."
    ok "Installed."
fi

if tailscale status >/dev/null 2>&1; then
    ok "Already signed in."
else
    info "A browser will open to sign in. Use the same account on every device."
    # --ssh enables Tailscale SSH, which authenticates with your tailnet
    # identity instead of key files. Linux-only; Windows uses OpenSSH.
    sudo tailscale up --ssh
fi

ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
ts_name="$(tailscale status --json 2>/dev/null | grep -oP '"DNSName":\s*"\K[^".]+' | head -n1 || true)"
[[ -n "$ts_ip" ]] && ok "Tailnet IP: $ts_ip"
[[ -n "$ts_name" ]] && ok "MagicDNS name: $ts_name"

# ---------------------------------------------------------------------------
section "Open WebUI"

# Open WebUI supports Python 3.11 and 3.12 only - 3.13 has no compatible
# release of some dependencies and fails at runtime.
mkdir -p "$APP"
VENV="$APP/.venv"
if have uv; then
    [[ -d "$VENV" ]] || uv venv "$VENV" --python 3.12
    PY="$VENV/bin/python"
    uv pip install --python "$PY" open-webui
else
    [[ -d "$VENV" ]] || python3.12 -m venv "$VENV" || python3 -m venv "$VENV"
    PY="$VENV/bin/python"
    "$PY" -m pip install --upgrade pip --quiet
    "$PY" -m pip install open-webui
fi
ok "Installed at $APP"

# The session signing key must be stable, or every restart logs everyone out.
secret_file="$APP/.webui_secret_key"
if [[ -f "$secret_file" ]]; then
    ok "Session key already generated."
else
    openssl rand -hex 32 > "$secret_file"
    chmod 600 "$secret_file"
    ok "Generated a persistent session key."
fi

unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir"
cat > "$unit_dir/open-webui.service" <<EOF
[Unit]
Description=Open WebUI
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP
Environment=DATA_DIR=$APP/data
Environment=HF_HOME=$AI_ROOT/hf-cache
Environment=WEBUI_AUTH=True
EnvironmentFile=-$APP/env
ExecStart=$VENV/bin/open-webui serve --host 127.0.0.1 --port $WEBUI_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

printf 'WEBUI_SECRET_KEY=%s\n' "$(cat "$secret_file")" > "$APP/env"
chmod 600 "$APP/env"

systemctl --user daemon-reload
ok "Wrote $unit_dir/open-webui.service"

if confirm "Start Open WebUI now and enable it at login?"; then
    systemctl --user enable --now open-webui
    sleep 3
    systemctl --user is-active --quiet open-webui && ok "Running on 127.0.0.1:$WEBUI_PORT" \
        || warn "Did not start. Check: journalctl --user -u open-webui -n 50"
else
    todo "Start it later: systemctl --user enable --now open-webui"
fi

# ---------------------------------------------------------------------------
section "Publishing to the tailnet"

# Each service gets its own HTTPS port on the same MagicDNS hostname. The
# listener binds to the Tailscale interface only - the service stays on
# loopback and is still invisible to the LAN.
cat <<EOF
  The first 'tailscale serve' prompts you to enable HTTPS certificates for
  your tailnet. That is a one-time consent in the browser.

  Planned mapping:
      443   ->  Open WebUI    127.0.0.1:$WEBUI_PORT
      8443  ->  ComfyUI       127.0.0.1:8188
      8444  ->  Strata API    127.0.0.1:8080
      8445  ->  llama.cpp API 127.0.0.1:8081
      8446  ->  Voice API     127.0.0.1:8100

EOF

if confirm "Publish these now?"; then
    sudo tailscale serve --bg "$WEBUI_PORT"           || warn "Open WebUI serve failed."
    sudo tailscale serve --bg --https=8443 8188       || warn "ComfyUI serve failed."
    sudo tailscale serve --bg --https=8444 8080       || warn "Strata serve failed."
    sudo tailscale serve --bg --https=8445 8081       || warn "llama.cpp serve failed."
    sudo tailscale serve --bg --https=8446 8100       || warn "Voice serve failed."
    echo
    tailscale serve status || true
    ok "Published. These URLs resolve only for devices on your tailnet."
else
    todo "Publish later with the commands in reference/remote-access.md"
fi

# ---------------------------------------------------------------------------
section "Summary"

host="${ts_name:-<your-device>}"
cat <<EOF
  Install Tailscale on your phone and laptop, sign in with the same account,
  and these become reachable:

      https://$host.<tailnet>.ts.net          Open WebUI  (start here on a phone)
      https://$host.<tailnet>.ts.net:8443     ComfyUI
      https://$host.<tailnet>.ts.net:8444/v1  Strata API
      https://$host.<tailnet>.ts.net:8445/v1  llama.cpp API
      https://$host.<tailnet>.ts.net:8446/v1  Voice API

      ssh $USER@$host                          Tailscale SSH, no keys to manage

  Run 'tailscale status' to see the exact hostname.

  First time in Open WebUI: the first account you create becomes the admin.
  Then Settings > Admin > Connections > Manage OpenAI API Connections, and add

      http://127.0.0.1:8080/v1   Strata      (API key: anything)
      http://127.0.0.1:8081/v1   llama.cpp

  Open WebUI reaches those over loopback because it runs on this machine.

  Two things to remember:
    * This machine must be awake, and booted into THIS operating system.
      Windows and Ubuntu are independent - whichever is running is what you
      can reach.
    * Never run 'tailscale funnel'. That publishes to the public internet,
      and ComfyUI can execute arbitrary code.

  Details and troubleshooting: reference/remote-access.md
EOF
