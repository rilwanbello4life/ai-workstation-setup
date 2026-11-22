# Remote access — reaching your models from a phone or laptop

## The problem this has to solve

Every service in this kit binds to `127.0.0.1` and **none of them has authentication switched on by default**. That is not an oversight. An exposed llama.cpp or Strata endpoint is a free GPU for whoever finds it, and an exposed ComfyUI is worse than that — it can install custom nodes and execute arbitrary Python, which is remote code execution on your workstation by design.

So "expose my models" needs to mean *my devices can reach them*, not *they are on the internet*. The approach below never binds a service to a public interface and never opens a port on your router.

## The design

Three pieces:

1. **Tailscale** — a WireGuard mesh VPN. Install it on the workstation, your laptop and your phone, sign in with the same account, and those devices get a private encrypted network. Works on cellular, works behind CGNAT, no port forwarding, no router configuration.
2. **`tailscale serve`** — publishes a loopback service as an HTTPS URL that only your tailnet can reach. The listener binds to the Tailscale interface alone, so the service stays on `127.0.0.1` and remains invisible to your LAN and the internet. You get a real TLS certificate under `*.ts.net`.
3. **Open WebUI** — a chat interface with its own user accounts, pointed at Strata and llama.cpp. The native UIs are not mobile-friendly; this one is, and it handles voice too.

Nothing about how the AI services are started changes. No `--listen`, no `--host 0.0.0.0`, no firewall holes.

## Install

Scripted: [`../ubuntu/08-remote-access.sh`](../ubuntu/08-remote-access.sh) or [`../windows/06-remote-access.ps1`](../windows/06-remote-access.ps1). By hand, read on.

### 1. Tailscale on the workstation

```bash
# Ubuntu
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

```powershell
# Windows
winget install --id tailscale.tailscale --exact
tailscale up
```

`--ssh` enables Tailscale SSH, which authenticates with your tailnet identity instead of key files. It is **Linux and macOS only** — on Windows, enable the built-in OpenSSH server instead (the script does this, scoped by firewall rule to the Tailscale range `100.64.0.0/10`).

Check what you got:

```bash
tailscale status
tailscale ip -4
```

### 2. Tailscale on your phone and laptop

Install the app from the App Store or Play Store, sign in with the **same account**. That is the entire client setup. The workstation now appears under a MagicDNS name like `workstation.tailnet-name.ts.net`.

### 3. Open WebUI on the workstation

Open WebUI supports **Python 3.11 and 3.12 only** — 3.13 has no compatible release of some dependencies and fails at runtime. It also defaults to **port 8080, which collides with Strata**, so it has to move.

```bash
uv venv ~/apps/open-webui/.venv --python 3.12
uv pip install --python ~/apps/open-webui/.venv/bin/python open-webui

export WEBUI_SECRET_KEY=$(openssl rand -hex 32)   # keep this stable
export DATA_DIR=~/apps/open-webui/data
~/apps/open-webui/.venv/bin/open-webui serve --host 127.0.0.1 --port 3000
```

`WEBUI_SECRET_KEY` signs sessions. If it changes, everyone gets logged out — generate it once and persist it. The setup scripts write it to a file and load it from a systemd unit (Linux) or launcher script (Windows).

### 4. Publish to the tailnet

Each service gets its own HTTPS port on the same hostname:

```bash
sudo tailscale serve --bg 3000              # Open WebUI, on 443
sudo tailscale serve --bg --https=8443 8188 # ComfyUI
sudo tailscale serve --bg --https=8444 8080 # Strata API
sudo tailscale serve --bg --https=8445 8081 # llama.cpp API (1234 on Windows)
sudo tailscale serve --bg --https=8446 8100 # Voice API
sudo tailscale serve --bg --https=8447 4000 # LiteLLM gateway (Ubuntu only)
```

Port 8447 is added by `server/06-friends.sh`. It is the only one of these that is safe to share with another person, because LiteLLM is the only one with authentication, budgets and rate limits — see [sharing-with-friends.md](sharing-with-friends.md). Do not add n8n on 5678 to this list: it has an account system, but a workflow editor with filesystem and credential access is not something to publish even inside a tailnet.

`--bg` persists the mapping across reboots. The first command prompts you to enable HTTPS certificates for your tailnet — a one-time browser consent.

Check and undo:

```bash
tailscale serve status
tailscale serve --https=8443 off     # the off form needs the same flags
```

## What you end up with

| URL | Service | Use it for |
|---|---|---|
| `https://<host>.<tailnet>.ts.net` | Open WebUI | chat from a phone — start here |
| `https://<host>.<tailnet>.ts.net:8443` | ComfyUI | image and video generation |
| `https://<host>.<tailnet>.ts.net:8444/v1` | Strata | OpenAI/Anthropic API |
| `https://<host>.<tailnet>.ts.net:8445/v1` | llama.cpp / LM Studio | OpenAI API |
| `https://<host>.<tailnet>.ts.net:8446/v1` | Voice | transcription and speech |
| `https://<host>.<tailnet>.ts.net:8447/v1` | LiteLLM gateway | keyed API access, the one shareable endpoint |
| `ssh you@<host>` | Tailscale SSH (Linux) | terminal access, no keys to manage |

Run `tailscale status` for your actual hostname.

## Wiring Open WebUI to your models

First account you create becomes the admin. Then **Settings > Admin > Connections > Manage OpenAI API Connections > Add Connection**:

| URL | API key |
|---|---|
| `http://127.0.0.1:8080/v1` | anything, or whatever you set with Strata's `--api-key` |
| `http://127.0.0.1:8081/v1` | anything, or whatever you set with `--api-key` |

Strata serves one model at a time, so this single connection covers whichever pack you last launched. If the model ID changes when you switch, set **Model IDs** by hand rather than relying on auto-detection.

Use `127.0.0.1` here, not the tailnet name: Open WebUI runs *on* the workstation, so it reaches the models over loopback.

If "Verify Connection" fails but chat works, the backend does not implement `GET /v1/models`. Add the model IDs by hand under **Model IDs** in the connection settings.

### Voice on the phone

Open WebUI consumes `/v1/audio/speech` and `/v1/audio/transcriptions`, which is exactly what our voice server provides. Point its audio settings at `http://127.0.0.1:8100/v1` and you get push-to-talk and spoken replies on mobile. Kokoro runs on CPU, so speech never competes with whatever is holding the GPU.

## Using the API from a laptop

For Cursor, scripts, or anything speaking the OpenAI API, two options.

**Through the served HTTPS port** — simplest, nothing to keep running:

```python
from openai import OpenAI
client = OpenAI(base_url="https://workstation.tailnet-name.ts.net:8444/v1", api_key="local")
```

**Through an SSH tunnel** — if you would rather not publish the port at all:

```bash
ssh -L 8080:localhost:8080 you@workstation
# now http://127.0.0.1:8080/v1 on the laptop is the workstation's Strata
```

Over Tailscale, that `ssh` works from anywhere with no key management.

## Hardening worth doing

**Add an API key to llama.cpp.** It supports one natively, and it costs nothing:

```bash
llama-server --model ... --port 8081 --api-key "$(openssl rand -hex 24)"
```

**Add one to Strata too.** It takes the same flag, and can bind for remote access itself rather than going through `tailscale serve`:

```bash
strata launch --preset coder --api-key "$(openssl rand -hex 24)" --access tailscale
```

`--access` takes `local`, `lan`, `cloudflare` or `tailscale`. Using `--access tailscale` is an alternative to the `tailscale serve` mapping below, not an addition to it — pick one. Keep `--access local` plus `serve` if you want every service exposed the same way.

Clients then send `Authorization: Bearer <key>`. ComfyUI has no equivalent, which is why keeping it inside the tailnet matters more than for the others.

**Lock down the tailnet with ACLs.** By default a tailnet with no `acls` section allows everything between your devices, which is usually fine for a personal setup. If you share the tailnet with anyone, restrict it — ACLs are deny-by-default once defined. See [Tailscale's ACL documentation](https://tailscale.com/docs/features/access-control/acls).

### A policy that keeps remote access and removes the risk

Three independent layers, each of which works on its own. Ordered by how much they buy for the effort.

**1. Use `serve`, never `funnel`.** This is the whole difference between private and public, and it is one word:

| | Reachable by | Needs |
|---|---|---|
| `tailscale serve` | your tailnet only | Tailscale installed and logged in |
| `tailscale funnel` | **the entire internet** | a browser |

Turning Funnel off does not reduce your remote access at all, because `serve` is what makes the endpoint reachable from your phone and laptop. Check which you have:

```bash
tailscale serve status      # should list :8447
tailscale funnel status     # should say no funnel
```

If `funnel off` also clears the serve mapping — they share one config — put it back with `server/06-friends.sh`.

**2. Restrict who on the tailnet can reach what.** Paste this into **Access controls** in the Tailscale admin console. It tags this machine as a server, lets your own devices reach everything, and lets anyone you have shared the tailnet with reach *only* the authenticated gateway on 8447:

```jsonc
{
  "tagOwners": { "tag:workstation": ["autogroup:admin"] },
  "acls": [
    // Your own devices: full access to the workstation.
    { "action": "accept", "src": ["autogroup:member"],
      "dst": ["tag:workstation:*"] },

    // Guests: the gateway and nothing else. 8447 is the only port that
    // checks an API key, which is what makes it the only one safe to
    // offer. ComfyUI on 8188 would be arbitrary code execution.
    { "action": "accept", "src": ["autogroup:shared"],
      "dst": ["tag:workstation:8447"] }
  ],
  "ssh": []
}
```

Then tag the machine, which also stops its key expiring every 180 days and silently dropping you:

```bash
sudo tailscale up --advertise-tags=tag:workstation
```

ACLs are deny-by-default once the section exists, so anything not listed is refused. Test a rule before relying on it — the admin console has a preview, and `tailscale ping <device>` tells you whether a path is permitted.

**3. Tighten the host firewall.** `01-server-base.sh` sets `ufw allow in on tailscale0`, which permits every port to every tailnet device. That is deliberately permissive so the first setup works. Narrowing it is a one-liner per port, and it is the layer that still protects you if an ACL is edited wrongly:

```bash
sudo ufw delete allow in on tailscale0
sudo ufw allow in on tailscale0 to any port 8447 proto tcp   # gateway
sudo ufw allow in on tailscale0 to any port 22   proto tcp   # ssh, if used
sudo ufw status verbose
```

Do this **last and from a local session**, not over SSH — if you get it wrong you have locked yourself out of the machine you are editing it on.

Worth being clear about what the firewall cannot do here: the loopback forwards bind to `127.0.0.1`, so `ufw` never sees that traffic. Reaching n8n or Open WebUI remotely needs `tailscale serve` to publish them, and publishing an unauthenticated service to the tailnet is a decision to make deliberately rather than by default.

**Think twice about ComfyUI.** Even on a private tailnet it is the one service that can run arbitrary code. If you do not need it remotely, leave `--https=8443` unpublished.

## Things that will catch you out

**Only one OS is reachable at a time.** This is the direct consequence of the two-independent-systems design: Windows and Ubuntu never run simultaneously. Boot into Windows to game and the Ubuntu AI stack disappears from your phone. Install remote access on both sides — the scripts do — and accept that what answers depends on what is booted.

This matters more once the server platform exists. **Booting into Windows is a planned outage** for the cluster, every scheduled n8n workflow, every game server and every friend holding a key. There is no handover and no notice. If other people depend on something here, stay on Ubuntu; that is the whole reason phase 19 makes Ubuntu a gaming machine too.

**The machine has to be awake.** Sleep drops the tunnel. For a workstation you intend to reach remotely, set the sleep timeout generously or disable it. Wake-on-LAN does not traverse a VPN without a second always-on device on the LAN to send the magic packet.

**Never run `tailscale funnel`.** Same command family, but it publishes to the **public internet**. In front of an unauthenticated ComfyUI that is a straightforward compromise of your workstation.

**Open WebUI on 8080 collides with Strata.** Always pass `--port 3000`.

**The first HTTPS request is slow.** The certificate for your node's name is fetched from Let's Encrypt on first connection, then cached.

## Troubleshooting

**`tailscale serve` says HTTPS is not enabled.** Follow the URL it prints and consent in the browser. One-time, per tailnet.

**The URL resolves but times out.** The service behind it is not running. Check with `curl http://127.0.0.1:<port>/` on the workstation first, then `tailscale serve status` for the mapping.

**Phone cannot reach anything.** Confirm the Tailscale app is connected and both devices appear in `tailscale status`. On iOS the VPN toggle sometimes drops on network changes.

**Open WebUI shows an empty model list.** The connection URL is wrong, or the backend has no `/v1/models`. Add model IDs manually in the connection settings.

**Everyone gets logged out of Open WebUI after a restart.** `WEBUI_SECRET_KEY` is not persisted. Set it from a file rather than regenerating it.

**Tailscale SSH does not work on Windows.** Expected — the server component is Linux and macOS only. Use the OpenSSH server over the tailnet IP instead.
