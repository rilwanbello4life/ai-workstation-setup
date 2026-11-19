# Filesystem map — where everything ends up

Absolute paths for everything the kit installs on the Ubuntu side, so you can find a model, a log, a secret or a launcher without reading a script to work out where it went.

Paths are shown for the user `rilwan`. Three variables decide them, all set in [`../ubuntu/common.sh`](../ubuntu/common.sh) and all overridable by exporting them before you run anything:

| Variable | Default | Holds |
|---|---|---|
| `AI_ROOT` | `/home/rilwan/ai` | Models and generated output — the big directory |
| `APPS` | `/home/rilwan/apps` | Application checkouts and their virtualenvs |
| `SRV_ROOT` | `/srv` | Platform state: databases, secrets, backups, game worlds |

The split is deliberate. `AI_ROOT` is large and re-downloadable, so it is never backed up. `SRV_ROOT` is small and irreplaceable, so all of it is. `APPS` is rebuildable from Git.

## Models — the terabyte

```
/home/rilwan/ai/
├── strata/                                    Strata model packs       see caveat below
├── gguf/
│   └── Qwen2.5-14B-Instruct-Q4_K_M.gguf       llama.cpp default        ~9 GB
├── comfyui/
│   ├── models/
│   │   ├── diffusion_models/
│   │   │   ├── z_image_turbo_bf16.safetensors         image            ~16 GB
│   │   │   └── wan2.2_ti2v_5B_fp16.safetensors        video            ~10 GB
│   │   ├── text_encoders/
│   │   │   ├── qwen_3_4b.safetensors
│   │   │   └── umt5_xxl_fp8_e4m3fn_scaled.safetensors
│   │   └── vae/
│   │       ├── ae.safetensors
│   │       └── wan2.2_vae.safetensors
│   └── output/                                generated images and video
├── voice/
│   ├── kokoro/                                speech synthesis         ~0.4 GB
│   └── whisper/                               faster-whisper CT2       ~1.5 GB
└── hf-cache/
    └── hub/                                   Hugging Face cache; HF_HOME points here
```

Everything except `strata/` is placed by [`../models/manifest.tsv`](../models/manifest.tsv) through `ubuntu/10-models.sh`. What each entry is and why it was chosen: [`../models/MANIFEST.md`](../models/MANIFEST.md).

**The one path to verify yourself is `strata/`.** The kit creates `/home/rilwan/ai/strata` and `status.sh` measures it, but nothing in the scripts tells the Strata CLI to use it — Strata is installed by its own `install.sh` and manages its own storage. On a machine where packs have been installed, find out where they actually went:

```sh
strata models list
du -sh /home/rilwan/ai/strata ~/.cache/strata ~/.strata 2>/dev/null
```

This matters because the packs are the largest thing on the drive by an order of magnitude. Both candidate locations are under `/home`, so they land on the Ubuntu drive either way and the disk budget in [partition-layout.md](partition-layout.md) holds — but if you ever move `AI_ROOT` to another disk, check that Strata followed.

## Applications

```
/home/rilwan/apps/
├── llama.cpp/
│   └── build/bin/
│       ├── llama-server                       the OpenAI-compatible server on 8081
│       ├── llama-cli
│       ├── llama-bench
│       └── llama-quantize
├── ComfyUI/
│   ├── .venv/                                 its own Python environment
│   └── custom_nodes/                          ComfyUI Manager and anything you add
├── voice/
│   ├── .venv/
│   ├── server.py                              copied from the kit, not symlinked
│   └── requirements.txt
├── open-webui/
├── start-llama-server.sh                      serve a GGUF from ai/gguf
├── start-comfyui.sh
└── start-voice.sh
```

The launchers run in the foreground, so `Ctrl+C` stops them. `voice/server.py` is a **copy** — editing the kit does not change the installed server until you re-run `ubuntu/06-voice.sh`.

## Platform state — the part worth backing up

```
/srv/
├── platform/
│   ├── postgres/                              the database: agent runs, prompts, n8n history
│   ├── n8n/
│   ├── litellm/
│   ├── openwebui/
│   ├── gpu-queue/
│   │   └── outputs/                           batch job results
│   ├── n8n-workflows/                         starter workflows exported by 04-agents.sh
│   └── secrets/                               mode 600, generated once, never regenerated
│       ├── postgres-password
│       ├── n8n-db-password
│       ├── n8n-encryption-key
│       ├── litellm-master-key
│       ├── litellm-salt-key
│       ├── openwebui-secret-key
│       ├── minecraft-rcon-password
│       └── valheim-password
├── games/                                     game-server worlds
├── backups/
│   ├── postgres/                              pg-<timestamp>.sql.zst
│   ├── workflows/                             workflows-<timestamp>.json
│   └── manifests/
├── gitops/                                    phase 20 working tree
│   ├── source/                                Helm charts you edit
│   └── rendered/                              what Argo CD actually applies
└── gitops.git                                 the bare repo the cluster reads over git://
```

`/srv` is created and chowned to you by `server/01-server-base.sh --apply`. **Nothing else in the server sequence works until that has run** — see [troubleshooting.md](troubleshooting.md).

Secrets are generated once and persisted, so re-running the platform scripts does not invalidate existing credentials. Losing `/srv/platform/secrets` means losing access to the database.

## Commands on PATH

All in `/usr/local/bin/`, installed by the phase in brackets:

| Command | Phase | Does |
|---|---|---|
| `ai-status` | 12 | memory, VRAM, services and cluster at a glance |
| `ai-pause` / `ai-resume` | 12 | free or restore the platform's ~15 GB |
| `ai-console-mode` | 8.2 | drop the desktop to reclaim 1–1.5 GB of VRAM |
| `agent-roles` | 15 | inspect, diff and promote agent prompts |
| `agent-runs` | 15 | live view and pass rates per role |
| `games` | 16 | start, stop and check game servers |
| `friends` | 17 | per-person keys and quotas |
| `platform-backup` / `platform-restore` | 18 | run a backup now, or restore one |
| `gitops` | 20 | render, commit and sync |
| `queue` | 21 | submit and watch GPU batch jobs |
| `gpu-probe` | 21 | the host JSON endpoint on 8101 |
| `gaming-check` | 19 | Proton and anti-cheat readiness |

`strata`, `hf` and `uv` install to `/home/rilwan/.local/bin`. That directory is put on `PATH` by `/home/rilwan/.config/ai-workstation/env.sh`, the single generated file that both `~/.profile` and `~/.bashrc` source — see [the user guide](user-guide.md#make-the-helpers-reachable-from-anywhere). `ubuntu/10-models.sh` also adds it explicitly, because a script run by path is a non-interactive shell and reads neither file. `k3s`, `kubectl`, `crictl` and `ctr` are in `/usr/local/bin`, installed by the k3s installer.

Not on PATH, run from the kit by path — these are the day-to-day ones, documented in [../ops/README.md](../ops/README.md):

| Script | Does |
|---|---|
| `ops/up.sh` | after a boot: wait for k3s, undo a leftover pause, report what is not running |
| `ops/switch.sh` | swap the one heavy workload the 16 GB card can hold |
| `ops/down.sh` | snapshot Postgres and stop the cluster cleanly before a shutdown |

## systemd units

System-wide, in `/etc/systemd/system/`:

| Unit | Phase | Purpose |
|---|---|---|
| `k3s.service` | 13 | the cluster |
| `ai-model-bridge.service` | 13 | socat from the cni0 address to loopback, so pods reach host models |
| `platform-forward.service` | 14 | forwards 4000, 4100, 5678, 3000 and 8090 to `127.0.0.1` |
| `cpu-performance.service` | 8.2 | pins the governor across reboots |
| `gpu-probe.service` | 21 | the GPU JSON endpoint |
| `platform-backup.service` / `.timer` | 18 | nightly backups |
| `gitops-git-daemon.service` | 20 | serves `/srv/gitops.git` read-only to the cluster |
| `gitops-watch.service` / `.path` | 20 | re-renders when the source tree changes |

One user unit, in `/home/rilwan/.config/systemd/user/`:

| Unit | Phase | Purpose |
|---|---|---|
| `voice-server.service` | 8.6 | Whisper and Kokoro on 8100 |

User units need `systemctl --user`, and only run while you are logged in unless lingering is enabled.

## Configuration and cluster data

| Path | What |
|---|---|
| `/home/rilwan/.kube/config` | kubectl credentials, copied from the root-only k3s file |
| `/home/rilwan/.config/ai-workstation/env.sh` | **generated.** The one place `AI_ROOT`, `HF_HOME`, `SRV_ROOT`, `PLATFORM_DIR`, `BACKUP_DIR`, `KUBECONFIG` and `~/.local/bin` on `PATH` are defined |
| `/home/rilwan/.profile` | sources `env.sh` — login shells and `ssh` |
| `/home/rilwan/.bashrc` | sources `env.sh` — terminals opened on the desktop |
| `/home/rilwan/.profile.bak-*` | the pre-migration copy, if the old inline exports were there |
| `/var/lib/ai-pause/*.replicas` | replica counts recorded by `ai-pause`. **Survives a reboot**, which is why `ops/up.sh` checks for workloads stuck at zero |
| `/etc/rancher/k3s/k3s.yaml` | the original k3s kubeconfig, root-only |
| `/var/lib/rancher/k3s/` | k3s state, container images and the local-path provisioner |
| `/var/lib/rancher/k3s/storage/` | PersistentVolume data for anything not pinned to `/srv` |
| `/etc/systemd/system/k3s.service.env` | k3s environment overrides |
| `/etc/apt/sources.list.d/` | the NVIDIA CUDA and container-toolkit repositories |

`/var/lib/rancher` belongs to root and k3s creates what it needs — you should never have to make a directory in there by hand.

## Finding things

```sh
ai-status                                   # the fast answer for "is it running"
./status.sh                                 # the full phase-by-phase report

du -sh /home/rilwan/ai/*                    # where the disk actually went
du -sh /srv/*
df -h /home /srv

systemctl list-units 'ai-*' 'platform-*' 'gitops-*' 'k3s*'
systemctl --user status voice-server

ss -tlnp | grep 127.0.0.1                   # what is listening, and what owns it
kubectl -n platform get pods,pvc,svc
```

The port each service answers on is in [ports.md](ports.md); the disk budget and why the reserve exists is in [partition-layout.md](partition-layout.md).
