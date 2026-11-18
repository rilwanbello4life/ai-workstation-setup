# Services and ports

The AI stack's port map applies on both systems. Windows and Ubuntu each run their own copy and are never booted at once, so there is nothing to deconflict. The **server platform ports exist only on Ubuntu** — nothing from phases 12–21 is duplicated on the Windows side.

Everything binds to loopback only. None of these services has authentication, so none of them should ever be exposed to the network. For occasional remote access, an SSH tunnel is enough:

```bash
ssh -L 8188:localhost:8188 user@workstation
```

For routine access from a phone or laptop, see [remote-access.md](remote-access.md) — Tailscale plus `tailscale serve` publishes these as private HTTPS URLs without rebinding anything or opening a port.

| Service | Port | API | Compatible with |
|---|---|---|---|
| **Strata** | 8080 | `http://127.0.0.1:8080/v1` | OpenAI + Anthropic |
| **llama.cpp server** | 8081 | `http://127.0.0.1:8081/v1` | OpenAI |
| **LM Studio** | 1234 | `http://127.0.0.1:1234/v1` | OpenAI |
| **Voice server** | 8100 | `http://127.0.0.1:8100/v1` | OpenAI audio endpoints |
| **ComfyUI** | 8188 | web UI + `/prompt` | its own JSON graph API |
| **Open WebUI** (optional) | 3000 | web UI | front-end for the others |
| **Ollama** (if installed) | 11434 | `http://127.0.0.1:11434/v1` | OpenAI |

Open WebUI defaults to **8080**, which collides with Strata, so always start it with `--port 3000`.

### Server platform — Ubuntu only

| Service | Port | API | Notes |
|---|---|---|---|
| **GPU queue** | 4100 | `http://127.0.0.1:4100/v1` | OpenAI-compatible; the front door for shared access |
| **LiteLLM gateway** | 4000 | `http://127.0.0.1:4000/v1` | OpenAI-compatible; needs a key |
| **n8n** | 5678 | web UI + `/api/v1` | Workflow editor and REST API |
| **Argo CD** | 8090 | web UI + API | GitOps; loopback only |
| **GPU probe** | 8101 | `http://127.0.0.1:8101/gpu` | Host process, not a pod; read-only JSON |
| **git daemon** | 9418 | `git://` | Host process; serves `/srv/gitops.git` read-only to the cluster |
| **Postgres** | 5432 | — | ClusterIP only; not forwarded to loopback |

These run as pods, except the GPU probe and the git daemon, which are host systemd units that the cluster reaches through the cni0 bridge. `platform-forward.service` port-forwards 4000, 4100, 5678, 3000 and 8090 to `127.0.0.1`, which is what keeps them compatible with the `tailscale serve` map below. Postgres is deliberately not forwarded — reach it with `kubectl -n platform exec -it deploy/postgres -- psql`.

**Ports 4000 and 4100 are the ones that change the security model.** Everything else on this page is unauthenticated and therefore loopback-only forever. LiteLLM has real keys with budgets and rate limits; the queue forwards those same keys to it rather than replacing them, so both are safe to share. See [sharing-with-friends.md](sharing-with-friends.md).

**4100 and 4000 do the same job differently.** Both speak the OpenAI API and both accept the same keys. The difference is what happens when the GPU is busy: LiteLLM returns `429` once `max_parallel_requests` is reached, while the queue holds the request and admits it when there is room. Send shared traffic to 4100 and keep 4000 for your own local tools, where a refusal is easier to notice than a wait. See [gpu-queue.md](gpu-queue.md).

### Reserved, not yet built

| Service | Port | Phase |
|---|---|---|
| **MCP gateway** | 4200 | 22 — Gmail, Drive and Calendar as agent tools |
| **Dictation router** | 4300 | 23 — speech in, dispatched action out |
| **Dashboard** | 4400 | 25 — Grafana over the whole platform |

Nothing listens on these yet. They are written down so that a later phase does not pick one by accident, and because the 4xxx block keeps platform services together. [roadmap.md](roadmap.md) specifies all three.

### Game servers — Ubuntu only, Tailscale-reachable

| Service | Port | Protocol |
|---|---|---|
| Minecraft | 25565 | TCP |
| Minecraft RCON | 25575 | TCP, ClusterIP only |
| Valheim | 2456–2457 | UDP |

These use `LoadBalancer` services, so k3s binds them on the host rather than on loopback. The firewall from `01-server-base.sh` denies inbound on everything except `tailscale0`, so in practice they are reachable by your tailnet and not from the internet.

### Internal names

Pods address the host-run model servers by DNS rather than by IP:

```
http://strata.platform.svc.cluster.local:8080/v1
http://llamacpp.platform.svc.cluster.local:8081/v1
http://voice.platform.svc.cluster.local:8100/v1
http://gpu-probe.platform.svc.cluster.local:8101/gpu
http://comfyui.platform.svc.cluster.local:8188
http://litellm.platform.svc.cluster.local:4000/v1
http://gpu-queue.platform.svc.cluster.local:4100/v1
http://postgres.platform.svc.cluster.local:5432
git://gitops.platform.svc.cluster.local:9418/gitops.git
```

Everything above that points at a host process — the model servers, the probe, ComfyUI and the git daemon — is a selector-less Service backed by a hand-written EndpointSlice pointing at the cni0 gateway, with `ai-model-bridge.service` forwarding that address into loopback. Strata itself never leaves `127.0.0.1`. The mechanism is explained in [kubernetes.md](kubernetes.md).

`gpu-queue` and `litellm` are ordinary Services with pod selectors, because both actually run in the cluster.

## Pointing clients at them

### Pi

`~/.pi/agent/models.json`:

```json
{
  "providers": {
    "strata": {
      "type": "openai",
      "baseUrl": "http://127.0.0.1:8080/v1",
      "apiKey": "local",
      "models": [{ "id": "strata", "name": "Strata (whichever pack is loaded)" }]
    },
    "llamacpp": {
      "type": "openai",
      "baseUrl": "http://127.0.0.1:8081/v1",
      "apiKey": "local",
      "models": [{ "id": "local", "name": "llama.cpp GGUF" }]
    }
  }
}
```

Switch between them mid-session with `/model`.

The `strata` provider points at whichever pack is currently serving — Strata runs one at a time on port 8080. Change which one with `strata launch --preset <name>`; the Pi config does not need editing.

### Any OpenAI client

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="local")
```

### LM Studio Bionic

Add a custom OpenAI-compatible endpoint in settings pointing at `http://127.0.0.1:8080/v1`. You can then switch between a fast VRAM-resident small model and the 125B MoE inside one conversation.

## What can run at the same time

16 GB of VRAM does not stretch far. Rough guide:

| Combination | Works? |
|---|---|
| Strata + voice server (Whisper on CPU) | yes |
| Strata + Kokoro speech | yes, Kokoro is CPU-only |
| Strata + the server platform | yes, up to the IQ2_XS pack |
| Strata + a small GGUF on llama.cpp | yes, at the cost of Strata's hot-expert VRAM |
| Strata + ComfyUI image generation | no |
| ComfyUI + voice server | yes, if Whisper is on CPU |
| Strata + a game server | yes for one light server, at ~4 GB |
| Strata + gaming | no, and RAM is the limit before VRAM is |

Strata pins 25–40 GB of system RAM depending on the pack. Expect the desktop to be sluggish for 1–3 minutes while it loads.

The llama.cpp row changed with the agent layer. Co-residency costs Strata roughly 9 GB of VRAM and therefore some generation speed, and it is worth it because the `checker` role needs a model with failure modes uncorrelated with the `worker`. If you are not running agents, do not pay for it.

Before anything heavy:

```sh
ai-status      # what is holding memory and VRAM right now
ai-pause       # free the platform's ~15 GB
```

A simple discipline that avoids all of this: stop one service before starting another. The launcher scripts run in the foreground, so Ctrl+C is enough.

On Ubuntu, `ai-console-mode off` buys back the 1–1.5 GB of VRAM the desktop holds. Every service above is a loopback listener rather than a desktop app, so they keep running and stay reachable over SSH from another machine.
