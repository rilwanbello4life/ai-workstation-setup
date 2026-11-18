# User guide — living with the machine

Everything else in this kit tells you how to *build* the machine. This page is about using it once it is built: what each piece is for, which commands you will actually type, and the setup worth doing that is not part of any phase.

Two companions. [using-the-stack.md](using-the-stack.md) goes component by component — how to run each one, what to do the first time you open it, and the gotchas. And if you want to know where you are in the build rather than how to use it, run [`../status.sh`](../status.sh).

## The mental model

One box, two operating systems, on two separate drives. They share no filesystem and no settings — only hardware.

| | Windows (1 TB) | Ubuntu (2 TB) |
|---|---|---|
| For | Gaming, and AI when you are already in Windows | AI work, and the always-on server |
| AI stack | Complete | Complete, plus the cluster |
| Models | Coder + Qwen3.6, ~91 GB | The entire catalogue, ~788 GB |
| Games | ~690 GB | ~431 GB, minus anti-cheat titles |
| Runs when you are away | No | Yes |

Pick which one boots with **F8** at power-on.

The consequence that matters day to day: **booting Windows is a planned outage.** Every service, scheduled workflow and game server on the Ubuntu side stops, and nobody depending on them gets a warning. If other people use your models or your Minecraft server, Windows is a decision rather than a habit.

### The three layers on Ubuntu

Understanding why the machine is arranged this way makes the commands below obvious rather than arbitrary.

1. **The desktop.** An ordinary Ubuntu GNOME session. Holds 1–1.5 GB of VRAM just by existing.
2. **The host services.** Strata, llama.cpp, ComfyUI and the voice server run as plain processes on the host, *outside* Kubernetes. They need direct, exclusive GPU access, and a container buys nothing for that.
3. **The platform.** k3s running Postgres, LiteLLM, n8n, Open WebUI and any game servers. This is the part that stays up when you walk away.

The models deliberately sit outside the cluster. The reasoning is in [server-architecture.md](server-architecture.md).

## What each piece is for

### Models and runtimes

| Component | What it is for | How you reach it |
|---|---|---|
| **Strata** | The main event. Serves huge sparse mixture-of-experts models by keeping hot experts in VRAM and the rest in RAM, which is why a 125B model runs on a 16 GB card | `strata launch --preset <name>`, API on `127.0.0.1:8080` |
| **llama.cpp** | A second, independent runtime for small GGUF models. Exists so the agent layer can cross-check one model against another | `~/apps/start-llama-server.sh`, port `8081` |
| **ComfyUI** | Image and video generation, node-graph style | `~/apps/start-comfyui.sh`, browser at `127.0.0.1:8188` |
| **Voice server** | Speech-to-text and text-to-speech, OpenAI-compatible so existing client code works unchanged | `~/apps/start-voice.sh`, port `8100` |
| **LM Studio Bionic** | Windows only. GUI chat and coding over the same kinds of model | Desktop app |
| **Pi** | Minimal terminal coding agent. Points at any OpenAI-compatible endpoint, including your own | `strata connect pi`, then `pi` |

### The platform

| Component | What it is for |
|---|---|
| **k3s** | Full Kubernetes in about 1.5 GB. Gives the platform restart-on-failure, resource ceilings and a normal deployment model |
| **Postgres** | State for everything — n8n history, agent runs, Open WebUI accounts |
| **LiteLLM** | One OpenAI-compatible endpoint in front of every model, with per-key quotas. This is what you hand to friends, never Strata directly |
| **n8n** | Scheduled and event-driven automation. The thing that makes the machine useful while you sleep |
| **Open WebUI** | A chat interface over your own models, usable from a phone |
| **GPU queue** | Holds requests when the card is busy instead of refusing them, and gives each person their own prompt and skills. The front door once you share the machine *(phase 21)* |
| **Argo CD** | Deploys what is committed to a local git repo, so "what is supposed to be running" has one readable answer *(phase 20)* |
| **Game servers** | Minecraft, Valheim and anything matching the template, each with its own memory ceiling |

### The helpers

Every one of these is a small script in `/usr/local/bin`, written by the setup phases.

| Command | What it does |
|---|---|
| `ai-status` | Memory, VRAM, which model ports are live, what the cluster is running |
| `ai-pause` | Frees the platform's ~15 GB for a larger model or a game |
| `ai-pause --cluster` | Also stops k3s itself, freeing a further ~1.5 GB |
| `ai-pause --games` | Only the game servers |
| `ai-resume` | Restores exactly what was running before, not a default |
| `ai-console-mode off` | Drops to a text console, returning the desktop's 1–1.5 GB of VRAM |
| `agent-roles` | List and edit the agent prompt store |
| `agent-runs` | Recent agent executions and their outcomes |
| `games` | Start, stop and list game servers |
| `friends` | Issue, revoke and inspect friend API keys |
| `friends profile` | Per-person system prompt, priority and concurrency |
| `friends skills` | Reusable prompt fragments, granted per person |
| `queue` | Queue depth, in-flight work, live GPU state; drain and resume |
| `gitops` | Render charts, diff against the cluster, commit and sync |
| `platform-backup` | Run a backup now rather than waiting for the timer |
| `platform-restore` | Restore from one |
| `gaming-check` | Driver, Vulkan, GameMode and whether anything is holding VRAM |

## Everyday use

### Starting work

```bash
ai-status                      # what is already running
strata launch --preset iq3_s   # bring up a model
```

Expect the machine to be unresponsive for one to three minutes the first time a large pack loads. It is reading tens of gigabytes into RAM and pinning it.

### Switching models

Only one Strata model serves at a time. Switching is cheap in disk terms and costs one to three minutes of loading, which is the entire reason the kit installs the whole catalogue rather than one pack.

```bash
strata models list             # what is installed
strata launch --list-presets   # saved configurations
strata launch --preset coder   # switch
strata launch --stop           # free the VRAM
```

### Running something big

```bash
ai-pause            # frees ~15 GB
ai-console-mode off # frees another 1-1.5 GB of VRAM
# ... work ...
ai-console-mode on
ai-resume
```

At 96 GB you will rarely need the first line. At 64 GB it is routine for anything above IQ2_XS.

### Gaming on Ubuntu

```bash
ai-pause            # the model and the game cannot share the GPU
gaming-check        # confirm nothing is holding VRAM
steam
```

Kernel-level anti-cheat titles do not run on Linux at all, and no configuration changes that. [linux-gaming.md](linux-gaming.md) has the list and the workarounds for everything else.

### Checking on things remotely

With Tailscale up, the services are reachable from your phone or laptop on the tailnet. Open WebUI is the one designed for that. See [remote-access.md](remote-access.md), and note the standing rule: **nothing is exposed to the public internet**, and `tailscale funnel` is never the answer.

## Choosing a model

The full catalogue and quality measurements are in [strata-models.md](strata-models.md). The short version, assuming the platform is running:

| You want | Use |
|---|---|
| Writing or reviewing code | **Coder IQ1_M** — 91% of the full model's SWE-bench score |
| General questions, other languages | **Qwen3.6 UD-Q4_K_XL** — Apache 2.0, 23 GB, good at everything Coder is bad at |
| The best general answer the machine can give | **IQ3_S** at 96 GB, **IQ2_XS** at 64 GB |
| Speed over quality | **Q2_0** — but this is where quality visibly falls off |
| Long agent loops | **Swift 1.5** — same quality, far shorter reasoning, so much less wall-clock time |

Two things that surprise people:

**Thinking is on by default, at the longest setting.** Flash-Next defaults to `reasoning_effort: xhigh`. A model rated 55 tok/s can spend a long time generating reasoning you never see before the answer starts. Pass `"reasoning_effort": "low"` for worker and checker roles — it saves more time than any hardware change in this kit.

**Published tokens-per-second figures assume full-speed memory.** In the 96 GB four-DIMM configuration you will not reach them. Measure once, write the number down, and compare against that instead.

## Additional setup worth doing

None of this is part of a numbered phase. All of it is worth an hour.

### Make the helpers reachable from anywhere

The `AI_ROOT` and `KUBECONFIG` exports live in `~/.profile`, which only applies to login shells. If you use `zsh`, or a terminal that starts non-login shells, source it explicitly from your `~/.bashrc` or `~/.zshrc`.

### Verify a backup actually restores

A backup you have never restored is a hypothesis. Once, soon after phase 18:

```bash
platform-backup                      # take one now
ls -la /srv/backups
platform-restore --list              # confirm it can read what it wrote
```

[backups.md](backups.md) covers the offsite half, which is the half that survives a drive failure.

### Point your editor at your own models

Pi connects to any OpenAI-compatible endpoint, and so do most editor AI plugins:

```bash
strata connect pi
```

Base URL `http://127.0.0.1:8080/v1`, or the LiteLLM endpoint on `4000` if you want quota accounting.

### Decide the VS Code question early

VS Code is Electron, and Electron's GPU process and CUDA workloads coexist badly on this machine — you get a corrupted editor window while everything else renders fine. If you hit it once, turn hardware acceleration off permanently rather than clearing caches repeatedly. The fix is in [troubleshooting.md](troubleshooting.md).

### Keep an eye on the disk

The catalogue through tier F is budgeted at 788 GB, and that already includes UD-IQ4_XS. What is still unbudgeted is UD-Q4_K_XL at a further 130 GB, and NVFP4, which publishes no size at all. Check before downloading either:

```bash
df -h /
du -xh --max-depth=1 ~/ai /srv
```

[partition-layout.md](partition-layout.md) has the full budget and [4tb-upgrade.md](4tb-upgrade.md) covers what a bigger drive buys.

## Routine maintenance

| When | What |
|---|---|
| Weekly | `ai-status`, and glance at `agent-runs` for failures |
| Weekly, if shared | `queue list` — look at `wait_ms`. Near zero means the limits never bind; minutes means the machine is oversubscribed |
| Weekly, if using GitOps | `gitops status` — an Application stuck `OutOfSync` is usually a render that was never committed |
| Monthly | `sudo apt update && sudo apt full-upgrade`, then reboot and confirm `nvidia-smi` still works |
| Monthly | `df -h /` — the drive fills from model downloads faster than from anything else |
| Quarterly | Restore a backup somewhere harmless and confirm the data is really there |
| After any kernel update | `nvidia-smi`. If the GPU vanished, it is DKMS or Secure Boot, not the card |
| After any hardware change | A full `memtest86+` pass before trusting the cluster with it |

Run [`../status.sh`](../status.sh) whenever something feels off. It audits every phase in one pass and prints what is missing.

## When something breaks

Work in this order.

1. **`ai-status`** — is the thing you think is running actually running?
2. **[`../status.sh`](../status.sh)** — did a phase silently not complete?
3. **[troubleshooting.md](troubleshooting.md)** — indexed by symptom, not by component.
4. **[ports.md](ports.md)** — if two things cannot run at once, this explains which and why.
5. **[gpu-queue.md](gpu-queue.md)** and **[gitops.md](gitops.md)** — if the symptom is requests waiting when the GPU looks idle, or a change you made not reaching the cluster.

Two failure modes worth recognising early, because both look like software bugs:

**Marginal memory** presents as random application crashes, container images that will not unpack, and `segfault` in `dmesg` — never as an obvious memory error. If the machine has been opened recently, suspect the RAM before the code.

**A full or slow disk** presents as Postgres commit latency and n8n timeouts. These are DRAM-less NVMe drives whose write cache shrinks as they fill, so the last tenth of the disk costs sustained write speed rather than just comfort.
