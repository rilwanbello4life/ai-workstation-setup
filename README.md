# AI Workstation Setup Kit

Runbook and scripts for building **two independent systems on one machine**: Windows 11 for gaming and Ubuntu 24.04 LTS for AI work and as an always-on server, each on its own drive, each with its own complete AI stack.

**Target machine:** Mission SG G700 — Ryzen 7 9800X3D, RTX 5070 Ti 16 GB, 32 GB DDR5-6000 as shipped (96 GB at ~DDR5-3600 after phase 11, or 64 GB at 6000 if the four-DIMM fill proves unstable), 1 TB Kingston NV3 + 2 TB NVMe, ASUS TUF GAMING B850-PLUS WIFI.

## The architecture

Two drives, two operating systems, nothing shared.

- **1 TB (M.2_1)** — Windows 11, games, and the Windows AI stack under `C:\AI`
- **2 TB (M.2_2)** — Ubuntu 24.04, applications under `~/apps`, AI models under `~/ai`, server platform under `/srv`

Each drive carries its own EFI System Partition, so neither OS can break the other's boot chain. You pick which to boot with **F8** at power-on.

Neither can read the other's filesystem, which is the point. Dual boot never divides RAM or VRAM — whichever OS you are in gets every gigabyte of both. Only disk is split, and each side has enough.

### Ubuntu is also the server

Phases 12–18 build a platform on top of the Ubuntu AI stack: a k3s cluster running n8n, a LiteLLM gateway, Postgres and Open WebUI, plus an agent layer and optional game servers. That makes Ubuntu the side that stays on, with Windows kept bootable as a rarely-used fallback.

Two consequences worth internalising before you start:

- **Booting into Windows is a planned outage.** Every service, every scheduled workflow and every game server stops, with no warning to anyone depending on them.
- **The platform costs about 15 GB of RAM**, which caps the Strata pack you can hold while it runs — at **IQ2_XS** on 64 GB, or **UD-IQ4_XS** on 96 GB. `ai-pause` frees it when you want a larger model or a game.

The layering, the memory arithmetic and why the models deliberately stay *outside* the cluster are in [reference/server-architecture.md](reference/server-architecture.md).

## How to use this kit

Copy this whole folder onto a USB stick alongside the Ubuntu ISO. Each phase below is one script plus a short manual step. Run them in order. Nothing here is destructive without an explicit confirmation prompt.

```
ai-workstation-setup/
├── 00-shopping-list.md          What to buy, live prices, part numbers
├── status.sh                    Audit every phase 0-19 and report what is missing
├── windows/                     Phases 1, 2, 4, 5, 6
│   ├── 01-preflight.ps1         BitLocker key, Fast Startup, firmware checks
│   ├── 02-verify-hardware.ps1   Read-only inventory: DIMM slots, EXPO, GPU, M.2
│   ├── 03-tune-windows.ps1      Resizable BAR, HAGS, power plan, disk budget
│   ├── 04-install-base.ps1      Git, Python, Node, uv, diagnostics
│   ├── 05-install-ai-stack.ps1  Strata, LM Studio, Pi, ComfyUI, voice server
│   └── 06-remote-access.ps1     Tailscale, Open WebUI, OpenSSH (optional)
├── ubuntu/                      Phases 8 and 18
│   ├── setup-all.sh             Runs every step below, in order
│   ├── 01-nvidia.sh             nvidia-open + MOK enrollment
│   ├── 02-tune-linux.sh         memlock, swappiness, governor, ai-console-mode
│   ├── 03-python-cuda.sh        Toolchain + PyTorch sm_120 probe
│   ├── 04-llamacpp.sh           Build llama.cpp with CUDA
│   ├── 05-comfyui.sh            Image and video generation
│   ├── 06-voice.sh              Installs the voice server
│   ├── 07-strata.sh             Every Strata model this machine can run
│   ├── 08-remote-access.sh      Tailscale and Open WebUI (optional)
│   ├── 09-gaming.sh             Steam, Proton, GameMode, MangoHud (optional)
│   ├── 10-models.sh             ComfyUI, voice and GGUF downloads
│   └── 11-shell-env.sh          One env file, sourced by .profile and .bashrc
├── server/                      Phases 12-21 — the always-on platform
│   ├── setup-all.sh             Runs every step below, in order
│   ├── common.sh                Shared paths and cluster helpers
│   ├── 01-server-base.sh        No sleep, system units, swap, firewall, ai-pause
│   ├── 02-k3s.sh                k3s, GPU runtime, storage, host-model bridge
│   ├── 03-platform.sh           Postgres, LiteLLM gateway, n8n, Open WebUI
│   ├── 04-agents.sh             Prompt store, agent roles, starter workflows
│   ├── 05-game-servers.sh       Containerised game servers (optional)
│   ├── 06-friends.sh            Per-person model access keys (optional)
│   ├── 07-backup.sh             Nightly local + encrypted offsite backups
│   ├── 08-gitops.sh             Argo CD and the render-commit-sync pipeline
│   ├── 09-gpu-queue.sh          Fair GPU sharing, per-person profiles, batch jobs
│   ├── 10-sandbox.sh            Isolated VM where the n8n Assistant runs code
│   ├── gitops/                  Helm charts and Argo CD Applications
│   ├── gpu-probe/               Host GPU reporter the queue reads
│   └── k8s/                     Manifests, applied in numeric order
├── voice/                       Self-contained OpenAI-compatible voice server
│   ├── server.py                Whisper transcription + Kokoro speech
│   └── README.md                Endpoints, options, client examples
├── models/
│   ├── MANIFEST.md              What to download and why
│   ├── manifest.tsv             Machine-readable download list
│   └── download-models.{sh,ps1} Fetch and place model files
├── ops/                         Day-to-day running, not building
│   ├── up.sh                    After a boot: wait for k3s, undo a leftover pause
│   ├── switch.sh                Swap the one heavy model the GPU can hold
│   ├── down.sh                  Snapshot Postgres and stop cleanly
│   └── README.md                What comes back by itself, and what does not
└── reference/
    ├── user-guide.md            Living with the machine once it is built
    ├── using-the-stack.md       Per component: run it, first run, daily use
    ├── manual-windows.md        Every Windows step by hand, with reasoning
    ├── manual-ubuntu.md         Every Ubuntu step by hand, with reasoning
    ├── manual-server.md         Every server step by hand, with reasoning
    ├── partition-layout.md      Drive layout, M.2 slot choice, disk budget
    ├── ubuntu-install-walkthrough.md   The risky phase, step by step
    ├── server-architecture.md   The layering, and the RAM and VRAM budgets
    ├── kubernetes.md            Why k3s, what one node changes, GPU limits
    ├── agent-orchestration.md   Brains, workers, checkers — and why not pods
    ├── gitops.md                Argo CD, the render-commit-sync loop, ai-pause
    ├── gpu-queue.md             Fair GPU sharing, profiles, skills, batch jobs
    ├── sharing-with-friends.md  Keys, transports, and the liability
    ├── backups.md               What is at risk, and disaster recovery
    ├── linux-gaming.md          Proton, anti-cheat, and the memory conflict
    ├── ports.md                 Every service, port and client config
    ├── filesystem-map.md        Absolute paths: models, apps, state, units
    ├── remote-access.md         Reaching the models from a phone or laptop
    ├── strata-models.md         Full model catalogue, 64 GB and 96 GB tiers
    ├── ram-upgrade-decision.md  Phase 11: add or swap, and what each costs
    ├── roadmap.md               Phases 23-27: MCP, dictation, authoring, dashboard
    ├── 4tb-upgrade.md           What a bigger drive buys, and the cherry-pick list
    └── troubleshooting.md       Symptom-indexed fixes
```

### Prefer not to run scripts you have not read?

Every script has a hand-written equivalent: [reference/manual-windows.md](reference/manual-windows.md), [reference/manual-ubuntu.md](reference/manual-ubuntu.md) and [reference/manual-server.md](reference/manual-server.md). They give the same commands in the same order, with the reasoning for each one and how to verify it worked. The scripts are a convenience, not the source of truth — you can mix and match, doing some phases by hand and others with the script.

## Phase order

| Phase | What | Where | Script |
|---|---|---|---|
| 0 | Order parts, write Ubuntu USB | before delivery | [00-shopping-list.md](00-shopping-list.md) |
| 1 | Windows baseline + safety | Windows | [windows/01-preflight.ps1](windows/01-preflight.ps1) |
| 2 | Hardware inventory + verification | Windows | [windows/02-verify-hardware.ps1](windows/02-verify-hardware.ps1) |
| 3 | Fit the 2 TB NVMe in M.2_2 and the 2×32 GB RAM kit | physical | [reference/partition-layout.md](reference/partition-layout.md) |
| 4 | Windows performance pass | Windows | [windows/03-tune-windows.ps1](windows/03-tune-windows.ps1) |
| 5 | Base developer tooling | Windows | [windows/04-install-base.ps1](windows/04-install-base.ps1) |
| 6 | Windows AI stack: Strata, LM Studio, ComfyUI, Pi, voice | Windows | [windows/05-install-ai-stack.ps1](windows/05-install-ai-stack.ps1) |
| 7 | Install Ubuntu on its own drive | physical + Linux | [reference/ubuntu-install-walkthrough.md](reference/ubuntu-install-walkthrough.md) |
| 8 | Ubuntu AI stack | Linux | [ubuntu/setup-all.sh](ubuntu/setup-all.sh) |
| 9 | Download models — on each OS separately | both | [ubuntu/10-models.sh](ubuntu/10-models.sh), [models/MANIFEST.md](models/MANIFEST.md) |
| 10 | Remote access from phone/laptop *(optional)* | both | [reference/remote-access.md](reference/remote-access.md) |
| 11 | Prove the RAM with `memtest86+`, then pick a Strata pack to match | Linux | [reference/ram-upgrade-decision.md](reference/ram-upgrade-decision.md) |

Phases 12 onward turn the Ubuntu side into the always-on server. They are independent of the Windows side entirely. Phases 20 and 21 are additions rather than foundations: 20 changes how you deploy, 21 changes how the GPU is shared. The platform runs without either.

| Phase | What | Where | Script |
|---|---|---|---|
| 12 | Always-on base: no sleep, system units, swap, firewall | Linux | [server/01-server-base.sh](server/01-server-base.sh) |
| 13 | k3s cluster, GPU runtime, host-model bridge | Linux | [server/02-k3s.sh](server/02-k3s.sh) |
| 14 | Platform: Postgres, LiteLLM, n8n, Open WebUI | Linux | [server/03-platform.sh](server/03-platform.sh) |
| 15 | Agent layer: prompt store, roles, workflows | Linux | [server/04-agents.sh](server/04-agents.sh) |
| 16 | Game servers *(optional)* | Linux | [server/05-game-servers.sh](server/05-game-servers.sh) |
| 17 | Share model access with friends *(optional)* | Linux | [server/06-friends.sh](server/06-friends.sh) |
| 18 | Backups: nightly, local and encrypted offsite | Linux | [server/07-backup.sh](server/07-backup.sh) |
| 19 | Gaming on Ubuntu *(optional)* | Linux | [ubuntu/09-gaming.sh](ubuntu/09-gaming.sh) |
| 20 | GitOps: Argo CD watching a local repo *(optional)* | Linux | [server/08-gitops.sh](server/08-gitops.sh) |
| 21 | GPU queue: fair sharing and per-person profiles *(optional)* | Linux | [server/09-gpu-queue.sh](server/09-gpu-queue.sh) |
| 22 | Code sandbox for the n8n Assistant *(optional)* | Linux | [server/10-sandbox.sh](server/10-sandbox.sh) |

**Phases 23 to 27 are specified but not built**: an MCP gateway putting Gmail, Drive and Calendar in reach of the agents, a dictation front door that decides what to do with what you said, an agent that writes n8n workflows, a dashboard over all of it, and a read-only medic that diagnoses the machine from `status.sh` and the logs. [reference/roadmap.md](reference/roadmap.md) gives each one its files, its port and the decisions already taken, so building them is implementation rather than design. Nothing in phases 1 to 22 depends on them.

Most scripted phases have a manual equivalent — Windows phases 1, 2, 4, 5, 6 and 10 in [reference/manual-windows.md](reference/manual-windows.md), phase 8 in [reference/manual-ubuntu.md](reference/manual-ubuntu.md), and phases 12–18 in [reference/manual-server.md](reference/manual-server.md). Phases 20 and 21 do not have one; they are documented by behaviour instead, in [reference/gitops.md](reference/gitops.md) and [reference/gpu-queue.md](reference/gpu-queue.md).

Two references worth reading before you need them: [reference/ports.md](reference/ports.md) for what runs where and what can run simultaneously, and [reference/troubleshooting.md](reference/troubleshooting.md) when something misbehaves. [reference/filesystem-map.md](reference/filesystem-map.md) is the absolute-path map of where every model, launcher, secret and unit ends up. If you run phases 20 or 21, add [reference/gitops.md](reference/gitops.md) and [reference/gpu-queue.md](reference/gpu-queue.md).

### Running it unattended

Every script is re-runnable: each one checks what is already in place, leaves it alone, and does only what is missing. Re-running after a failure, a reboot or a half-finished download is the expected way to use them, not a recovery procedure.

The downloads are the long part — the full catalogue is most of a terabyte — so the sequence is built to be started and left:

```sh
./ubuntu/setup-all.sh -y --tier all      # everything, nothing to answer
```

`-y` authenticates `sudo` once and refreshes the timestamp for the whole run, suppresses package configuration dialogs, and answers the questions *inside* each phase rather than only the wrapper's own. `--tier all` takes the whole 1 006 GB Strata catalogue - every pack this machine can run - instead of the 150 GB default. The model downloads run last, after every prompt has been dealt with.

Two phases are left out of `-y` deliberately and must be asked for by name: `./setup-all.sh 08` signs into Tailscale in a browser, and `./setup-all.sh 09` installs several GB of 32-bit gaming libraries.

If a single model fails to download, the run carries on and reports it at the end; re-running fetches only what is missing. The one thing that will stop it early is a plan that cannot fit on the disk, which is checked before the first byte rather than discovered 600 GB in.

## Once it is built

[reference/user-guide.md](reference/user-guide.md) is the operator's manual: what every component is for, the commands you will actually type, the setup worth doing that is not in any phase, and a maintenance cadence. [reference/using-the-stack.md](reference/using-the-stack.md) then takes each component in turn — how to run it, what to do the first time you open its interface, and what to avoid.

To find out where you are, or what a half-finished build is missing, run the audit. It is read-only, needs no arguments, and covers every phase from the disk layout to the backup timer:

```bash
./status.sh                # full report
./status.sh > report.txt   # or save it
```

Markers are `[ok]` present and correct, `[--]` not done yet, `[!!]` done but wrong — look at those first — and `[??]` needs sudo to tell.

The numbered phases build the machine and are run once. The scripts in [ops/](ops/README.md) are the ones you run forever after: `ops/up.sh` after every boot, `ops/switch.sh` to change which model holds the GPU, and `ops/down.sh` before a planned shutdown. Most of the stack is enabled systemd units and comes back on its own, so `up.sh` is mostly verification — it exists for the parts that do not, chiefly a leftover `ai-pause`, whose recorded replica counts survive a reboot and otherwise leave you staring at a healthy, completely empty cluster.

## The non-negotiable safety rules

Read these before touching anything. They are the difference between two working systems and a bricked new PC.

1. **Export the BitLocker recovery key first.** Windows 11 Home turns on device encryption automatically when you sign in with a Microsoft account. Phase 1 does this for you, but verify the file exists before continuing.
2. **Disable Fast Startup and hibernation.** Phase 1 runs `powercfg /H off`, which also frees ~32 GB of `hiberfil.sys` on a drive that needs it.
3. **Unplug the 1 TB Windows drive before installing Ubuntu.** An installer cannot touch a disk that is not connected. This is what makes Phase 7 safe, and it is why "Erase disk and install Ubuntu" is the correct choice there.
4. **Full shutdown, not reboot**, before booting the Ubuntu installer.
5. **Never let Windows format the 2 TB drive.** It has no ext4 driver, so Disk Management shows the Ubuntu partition as unformatted and offers to fix it. Declining is always correct.
6. **Do not use M.2_3** for the new drive. It shares bandwidth with the second PCIe x16 slot and disables it.

## What each tool in the stack does

The five recommendations you collected are one stack, not five alternatives.

- **Hugging Face** — the model library. Everything downloads from here.
- **llama.cpp** (`ggml-org/llama.cpp`) — the inference engine almost everything else wraps. Runs GGUF, splits work across CPU and GPU.
- **Strata** (`Niko1221/Strata`, MIT) — a runner specialised in large sparse mixture-of-experts models. It serves three base models, of which two run here: **Qwen3.8-Flash-Next** (125B, ~10 of 512 experts per layer active) and **Qwen3.6-35B-A3B** (35B, Apache 2.0). Caches hot experts in VRAM, keeps the rest in RAM, streams the remainder off SSD. Beats a plain Ollama install because Ollama splits by layer, which is the wrong strategy for sparse MoE. Install several and switch with `strata launch --preset` — see [reference/strata-models.md](reference/strata-models.md).
- **LM Studio Bionic** — GUI agent app over the LM Studio runtime. Chat, coding projects with inline diffs, document work, local voice transcription, MCP.
- **Pi** (`earendil-works/pi`) — minimal terminal coding agent. Connects to any OpenAI-compatible endpoint.
- **vLLM** — high-throughput server that assumes the whole model fits in VRAM. Skip it on 16 GB.

### Interchangeability

- Run **exactly one** general engine: llama.cpp server, Ollama, or the LM Studio runtime. They are redundant with each other.
- **Strata is not a substitute for any of them**, and none of them substitute for it. Run Strata *and* one general engine.
- **Agent front-ends are fully interchangeable** and can run simultaneously against the same endpoint: LM Studio Bionic, Pi, Cursor, Open WebUI.

## Expectations on this hardware

16 GB of VRAM means **one heavy workload at a time**, with the platform as the one thing that runs continuously alongside it. RAM decides which model that workload can be.

- Strata locks 25–40 GB of RAM while loaded. The machine will be unresponsive for 1–3 minutes during load, and you cannot game while it runs.
- **The server platform takes ~15 GB off the top.** With it running, the largest pack that fits is IQ2_XS (~35.5 GB of experts) at 64 GB, or UD-IQ4_XS (~62 GB) at 96 GB. `ai-pause` frees the platform for the tier above. The full table is in [reference/strata-models.md](reference/strata-models.md).
- **Four DIMMs run at roughly DDR5-3600, not 5600.** AMD rates the 9800X3D for 5600 with two modules only. Strata computes cold experts on the CPU, so generation speed is memory-bandwidth-bound and published tok/s figures will not be reached. That is the price of 96 GB; the 64 GB configuration keeps the full 6000. The delivered loss is nearer a fifth than the 40% the headline implies, because a single-CCD part cannot consume 6000 anyway — see [reference/ram-upgrade-decision.md](reference/ram-upgrade-decision.md).
- Only **one Strata model serves at a time**. Installing several is a disk-space question, not a memory one; switching is `strata launch --preset <name>`, and it costs 1–3 minutes.
- Image generation and LLM inference compete for the same VRAM. Stop one before starting the other. The one deliberate exception is Strata plus a small model on llama.cpp, which gives the agent layer two independent runtimes for cross-checking.
- On Ubuntu, `ai-console-mode off` drops to a text console and frees the 1–1.5 GB the desktop holds. On a 16 GB card that is the difference between experts staying resident and spilling to system RAM.

### The three commands you will use most

| Command | What it does |
|---|---|
| `ai-status` | Memory, VRAM, which model ports are live, what the cluster is running |
| `ai-pause` | Frees the platform's ~15 GB for a larger model or a game |
| `ai-resume` | Restores exactly what was running before |

After a reboot, `./ops/up.sh` wraps all three: it waits for the cluster, undoes a pause that was still in effect when the machine went down, and tells you which model servers are not running and why.

### Which side to run what on

Both systems get the full stack — text, image, video and voice — so this is preference rather than necessity:

- **Ubuntu** is the better AI side, and the only server side. Native ext4, no desktop compositor to shed, `ai-console-mode` to reclaim VRAM, and room for the **entire Strata catalogue** plus the cluster and backups, with about 213 GB left for games. With phase 19 it is also a capable gaming machine — subject to one hard limit, covered in [reference/linux-gaming.md](reference/linux-gaming.md): kernel-level anti-cheat titles do not run on Linux at all, and no configuration changes that.
- **Windows** is full AI *plus* gaming. After Windows and the full stack there is roughly 690 GB left for games, which is four to six modern titles. That is the only thing the Windows side is short on, and a larger drive later fixes it.

If space pinches before that upgrade, **drop the ComfyUI video models from Windows first** — 55 GB back, and Wan 2.2 is the slowest thing on a 16 GB card anyway. [windows/03-tune-windows.ps1](windows/03-tune-windows.ps1) reports the budget against your actual free space.
