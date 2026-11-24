# ops/ — running the machine day to day

The numbered scripts in `ubuntu/` and `server/` **build** the machine and are meant to be run once each, re-run only when something needs repairing. These are the ones you run repeatedly, forever.

| Script | When |
|---|---|
| [`r1wc.sh`](r1wc.sh) | **Start here.** The console: everything on one page, with docs on each entry. |
| [`up.sh`](up.sh) | After every boot. Verifies the services, undoes a leftover pause, waits for the cluster. |
| [`switch.sh`](switch.sh) | Whenever you want a different model, or another one beside it — `status` says what the card has left. |
| [`down.sh`](down.sh) | Before a planned shutdown or reboot. Snapshots Postgres first. |

All of them are safe to run when there is nothing to do.

## The console

```sh
./r1wc.sh --install     # once; puts 'r1wc' on PATH
r1wc                    # from anywhere, thereafter
```

One page listing every service in the stack with its live state, grouped into models, platform, access, games and maintenance. Pick a number and you get five choices for that entry: read its documentation, start it, stop it, open its interface, or go back.

It implements almost nothing itself. Each action runs the command you would have run by hand — `ops/switch.sh`, `systemctl`, `kubectl`, `ai-pause`, `platform-backup` — and the documentation for each entry names that command. So there is one implementation of every operation, and the console is a way of finding it rather than a second copy that can drift.

The one piece of real logic is the GPU rule. Entries marked `[gpu]` are started through `switch.sh`, which stops the workload of that same kind and waits for the driver to release the memory that one took; the others stay up, because the card is shared and Strata's `--vram-reserve-mib` is what leaves room in it. Entries without that marker skip all of it, because they genuinely coexist — the voice server runs happily beside a 60 GB pack, since Whisper and Kokoro are both on the CPU.

Non-interactively, for scripts or when you know what you want:

```sh
r1wc status             # every entry's state, one line each
r1wc docs postgres      # just the documentation
r1wc start strata iq2_xs
r1wc stop comfyui
r1wc ui argocd
```

**Strata has no web interface** — its real UI is the terminal monitor you get from `strata launch --preset <name>`, and Open WebUI on port 3000 is the chat front-end that talks to its API. If you have a Strata desktop app or a local page, point `R1WC_STRATA_UI` at the file or URL and `r1wc ui strata` will open that instead:

```sh
echo 'export R1WC_STRATA_UI=/path/to/the/file' >> ~/.bashrc
```

`--install` symlinks rather than copies, so `git pull` updates the installed command too.

## After a reboot

```sh
./ops/up.sh
```

Most of the stack comes back on its own — `k3s`, the port forwards, the host-model bridge, the GPU probe and the voice server are all enabled systemd units, and `loginctl enable-linger` keeps the user units alive without a desktop session. So `up.sh` is mostly a check.

It exists for the cases where that is not enough:

- **A leftover `ai-pause`.** This is the one that will catch you. `ai-pause` records the replica counts in `/var/lib/ai-pause` and scales everything to zero. That directory survives a reboot, so if you paused to free memory and then shut down, the cluster comes back up healthy and completely empty, with nothing on screen explaining why. `up.sh` notices and runs `ai-resume`.
- **Timing.** k3s takes 30–60 seconds after boot to answer. Anything you run before then fails in a way that looks like breakage rather than impatience.
- **Model servers.** Strata, llama.cpp and ComfyUI have no systemd units, deliberately — see below. `up.sh` tells you nothing is loaded rather than guessing.

To bring a model up in the same step:

```sh
./ops/up.sh --model coder-iq1_m
```

## Switching models

```sh
./ops/switch.sh status              # what holds the GPU right now
./ops/switch.sh strata gyro-s
./ops/switch.sh llamacpp Qwen2.5-14B-Instruct-Q4_K_M.gguf
./ops/switch.sh comfyui
./ops/switch.sh none                # free everything
```

**Why there is no "start all models" script.** 16 GB of VRAM holds one serious workload, and a Strata pack pins another 25–62 GB of system RAM on top. Starting a second does not fail cleanly: it either refuses somewhere deep in a CUDA library or makes the desktop unusable while the kernel pages. So the operation that is actually useful is "stop whatever is running, then start this one", and that is all `switch.sh` does. It waits for the driver to release the memory before starting the next one, which is the step people skip by hand and then misread the resulting failure as an out-of-memory bug.

For the largest packs, give it the platform's memory too:

```sh
./ops/switch.sh strata qwen-ud-iq4_xs --pause-cluster
```

That runs `ai-pause`, so remember that `up.sh` or `ai-resume` is what brings the cluster back.

## Before shutting down

```sh
./ops/down.sh              # then shut down yourself
./ops/down.sh --poweroff
```

Not required — systemd stops everything on its own — but it adds two things an ordinary shutdown does not. It takes a Postgres snapshot, because backups run nightly and an unplanned shutdown at 23:00 costs a day of agent runs, prompt history and n8n executions. And it stops things in order and waits, because k3s killed mid-write leaves containerd state to repair on the next boot, and a pack holding 60 GB of pinned memory makes shutdown slow and occasionally unclean.

`down.sh` deliberately does **not** run `ai-pause`. Pause state outlives a reboot, so pausing on the way down means booting into a cluster scaled to zero — the exact state `up.sh` exists to undo.

## What these do not replace

| For | Use |
|---|---|
| Is it healthy right now? | `ai-status`, or `./status.sh` for the full report |
| Free memory without rebooting | `ai-pause` / `ai-resume` |
| Run a backup now | `platform-backup` |
| Restore a backup | `platform-restore` |
| Agent prompts and run history | `agent-roles`, `agent-runs` |
| Game servers | `games` |
| Deploy a change | `gitops` |

Where everything lives on disk: [../reference/filesystem-map.md](../reference/filesystem-map.md). What listens on which port: [../reference/ports.md](../reference/ports.md). When something is broken: [../reference/troubleshooting.md](../reference/troubleshooting.md).
