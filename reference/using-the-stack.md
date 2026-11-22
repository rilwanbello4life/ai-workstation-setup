# Using the stack — one section per component

[user-guide.md](user-guide.md) is the map: what exists and why. This page is the detail: for each component, how to run it, what to do the first time you open it, and the thing you will do most often afterwards.

The build documents ([manual-ubuntu.md](manual-ubuntu.md), [manual-server.md](manual-server.md), [manual-windows.md](manual-windows.md)) cover installation. Nothing here repeats them.

## Before anything else: two kinds of address

Every service binds to **loopback only**. Nothing in this kit listens on a public interface, and that is deliberate rather than incidental.

- **On the machine**, use `127.0.0.1:<port>`.
- **From your phone or laptop**, use the Tailscale hostname. `platform-forward.service` forwards 4000, 5678 and 3000 from the cluster to loopback so `tailscale serve` can reach them; [remote-access.md](remote-access.md) has the mapping.
- **Never** `tailscale funnel`. That is the public internet, and nothing here is built for it.

[ports.md](ports.md) is the full table of what listens where and what can run simultaneously.

---

## Strata — the main model server

**Port 8080, OpenAI-compatible at `/v1`.** One model serves at a time.

### Running it

```bash
strata models list              # what is installed on disk
strata launch --list-presets    # saved configurations
strata launch --preset coder    # start serving one
strata launch --status          # what is serving now
strata launch --stop            # unload and free the VRAM
```

Switching models is `--preset <name>` and costs one to three minutes. You do not need to stop first in the normal case, but under `--no-tui` it refuses rather than prompting, so add `--restart` in scripts.

### Installing a pack you do not have yet

Check the fit before you commit to a download that may be 128 GB:

```bash
strata launch --plan --family coder --model IQ1_M
```

`--plan` reports what it would need and changes nothing. If it fits, install and save a preset in one step:

```bash
strata launch --family coder --model IQ1_M --yes --no-tui --save-preset coder
strata launch --stop
```

An interrupted download resumes — re-run the same command and it continues rather than starting over.

### Using it

It speaks the OpenAI API, so anything that talks to OpenAI talks to this:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"strata","messages":[{"role":"user","content":"hello"}]}'
```

**The setting that matters most is `reasoning_effort`.** Flash-Next defaults to `xhigh`, so a model rated 55 tok/s can spend minutes on reasoning you never see. Pass `"reasoning_effort": "low"` for anything mechanical. This is the single largest speed lever on the machine — larger than any hardware change in this kit.

Model names, quality measurements and the fit tables are in [strata-models.md](strata-models.md).

---

## llama.cpp — the second runtime

**Port 8081, OpenAI-compatible.** Small dense GGUF models, fully on the GPU.

This exists so the agent layer can check one model's work with a genuinely different model. A validator that shares weights with the worker shares its blind spots.

```bash
~/apps/start-llama-server.sh qwen2.5-coder-7b-instruct-q4_k_m.gguf
```

A bare filename is resolved against `~/ai/gguf/`; an absolute path is used as given. Anything after the filename is passed through to `llama-server`, so you can override the defaults:

```bash
~/apps/start-llama-server.sh mymodel.gguf --ctx-size 16384
```

The defaults are `--n-gpu-layers 999` (offload everything that fits), `--ctx-size 8192` and `--flash-attn`.

**Sizing rule on 16 GB of VRAM:** at Q4_K_M a dense model needs roughly `parameters × 0.6 GB`. Stay at or below 14B to keep it resident with room for context. Above that it spills to RAM and the speed advantage over Strata disappears.

---

## LiteLLM — the gateway

**Port 4000.** One OpenAI-compatible endpoint in front of every model, with keys, budgets and rate limits.

Use this rather than Strata directly whenever something other than you is calling — scripts, n8n, friends. It is the only component that can revoke access or cap spend.

### The model aliases

These are names LiteLLM exposes, not models you install. They point at whatever is actually serving:

| Alias | Backed by | For |
|---|---|---|
| `brain` | Strata, high reasoning | Planning and decomposition |
| `worker` | Strata, low reasoning | Executing one step |
| `checker` | llama.cpp | Verifying the worker, with different weights |
| `strata` | Strata, raw | Direct access |
| `local` | llama.cpp, raw | Direct access |

`brain` and `worker` are the **same resident model** at different reasoning efforts. Nothing reloads when you switch between them, which is the whole reason the roles are prompts rather than pods — the reasoning is in [agent-orchestration.md](agent-orchestration.md).

### Using it

```bash
curl http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $(sudo cat /srv/platform/secrets/litellm-master-key)" \
  -H 'Content-Type: application/json' \
  -d '{"model":"worker","messages":[{"role":"user","content":"hello"}]}'
```

The admin UI is at `http://127.0.0.1:4000/ui`, logged in with the master key. It shows spend per key, which is measured in notional dollars against local models — meaningless as money, useful as a proxy for token volume.

Two configured defaults worth knowing before you change them. `max_parallel_requests: 4` reflects Strata holding ~1.5 GB of KV cache per slot against a 16 GB card. `num_retries: 0` is deliberate: a timeout here means the model is loading or the queue is deep, and retrying makes both worse.

To issue a key for another person, use `friends add` rather than the UI — see [sharing-with-friends.md](sharing-with-friends.md), including the liability section.

---

## GPU queue — the front door when the machine is shared

**Port 4100.** Phase 21. Same OpenAI API as LiteLLM, same keys. The difference is what happens when the card is busy: LiteLLM returns `429`, the queue waits.

### Running it

It is a pod, started by `09-gpu-queue.sh` and deployed through Argo CD. Nothing to launch.

```sh
queue status      # depth, in-flight work, live GPU state
queue watch       # the same, refreshed every 2s
queue list        # recent jobs with wait and run times
```

### The first time

Give yourself and each friend a profile. Nobody is required to have one — the queue falls back to sensible defaults — but it is where the per-person behaviour lives:

```sh
friends profile alice --edit                 # their system prompt
friends profile alice --concurrent 2 --priority 50
friends skills list
friends skills grant alice sql
```

Then point clients at 4100 instead of 4000. For friends this already happened: `09-gpu-queue.sh` repoints the `:8447` tailnet endpoint, so the URL they were given keeps working and now gets queueing.

### Daily use

Nothing, normally. It is infrastructure. The two moments it matters:

```sh
queue drain       # finish current work, admit nothing new - before maintenance
queue resume
```

`ai-pause` drains automatically, so taking the GPU for a game does not drop someone's request.

### Gotchas

- **`wait_ms` is the number worth watching.** Near zero all week means the limits never bind and the queue is only adding a hop. Minutes means the machine is genuinely oversubscribed, and scheduling cannot fix that.
- **Calling 4000 directly bypasses all of it.** That is intentional for your own tools, where a `429` is more informative than a silent wait, but it means "the queue did nothing" usually means something is still pointed at 4000.
- **If the GPU probe is down the queue still works**, at the static floor of two light requests and one heavy. Everything waiting while `nvidia-smi` shows an idle card is the signature: check `curl -s http://127.0.0.1:8101/gpu`.
- **One heavy job at a time, and light requests do not run alongside it.** A long `xhigh` reasoning call will make short requests wait. That is the trade that keeps the card from running out of memory mid-generation.
- **Image generation should go through `/v1/jobs`, not a chat call.** It returns an id immediately instead of holding a connection for several minutes.

Full detail, including the admission policy and the batch job API: [gpu-queue.md](gpu-queue.md).

## Argo CD and the GitOps repo

**Port 8090.** Phase 20. You edit files in `/srv/gitops`; the cluster follows.

### Running it

```sh
gitops status     # repo state, Argo CD health, every Application
```

The UI is at `http://127.0.0.1:8090`, password in `/srv/platform/secrets/argocd-admin-password`. You rarely need it — the UI is better than the CLI for seeing *why* a sync failed, and worse for everything else.

### The first time

Confirm adoption was clean. `08-gitops.sh` refuses to enable anything unless the chart renders exactly what is already running, so if it completed, the cluster and the repo already agree.

The platform app starts on **manual sync**, deliberately. Watch it do the right thing once or twice, then:

```sh
gitops automate platform
```

### Daily use

```sh
cd /srv/gitops
$EDITOR source/platform/values.yaml
gitops diff                        # what would change
gitops commit -m "why"             # renders, checks for secrets, commits
gitops sync platform
```

### Gotchas

- **Never edit `rendered/` by hand** except under `rendered/manual/`. Everything else there is generated and `gitops render` will overwrite it.
- **`gitops commit` always renders first.** Committing a stale `rendered/` is the one mistake here that produces a genuinely confusing result, so it is not possible.
- **Nothing is pruned.** Deleting a file leaves the object running and the app `OutOfSync`. Removing something is a deliberate `kubectl delete`.
- **Secrets are refused twice** — by `.gitignore` and by an explicit check on staged paths. Real secrets stay in `/srv/platform/secrets` and are not in git.
- **A locally built image needs `gitops build`.** There is no registry on this machine; the image is imported straight into k3s. An `ImagePullBackOff` on your own image means you skipped it.

Full detail, including the `ai-pause` conflict: [gitops.md](gitops.md).

## Open WebUI — chat, including from your phone

**Port 3000.**

### First run — the part you can only get wrong once

`WEBUI_AUTH` is on, and **the first account that registers becomes the permanent administrator.** There is no "promote a user" path afterwards that does not involve editing the database.

So: open `http://127.0.0.1:3000` yourself, before anyone else can reach it, and create your account. Then, in **Settings → Admin → General**, turn new-user registration off or set new accounts to require approval.

### Already wired for you

You do not need to configure a model connection. The deployment points at LiteLLM, so every alias above appears in the model dropdown on first load. Speech-to-text and text-to-speech are pointed at the voice server, so the microphone button and read-aloud work without setup. The Ollama integration is explicitly disabled — if the UI offers to connect to Ollama, ignore it.

### Using it

Pick a model from the dropdown and type. Worth knowing:

- **Model choice is per-conversation.** Starting a new chat does not inherit the last one's model.
- **A model that is not serving will time out rather than start.** Open WebUI cannot launch Strata. If the dropdown has `brain` but nothing responds, run `strata launch --status` on the machine.
- **Accounts and chat history live in Postgres**, so they survive a cluster rebuild and are covered by the nightly backup.

This is the interface designed for the phone. [remote-access.md](remote-access.md) covers reaching it over the tailnet.

---

## n8n — automation

**Port 5678.** The component that makes the machine useful while you are asleep.

### First run

1. Open `http://127.0.0.1:5678` and create the **owner account**. Same rule as Open WebUI: do it before anyone else can.
2. Create a **Postgres credential**. Host `postgres`, port `5432`, database `litellm`, user `postgres`, password from `sudo cat /srv/platform/secrets/postgres-password`. The agent workflows read the prompt store from that database.
3. Import the starter workflows: **Workflows → Import from File**, from `/srv/platform/n8n-workflows/`.

| File | What it does |
|---|---|
| `01-brain-worker-checker.json` | A webhook takes a task, `brain` plans it, `worker` executes each step, `checker` verifies, and the result is logged to the `agent_runs` table |
| `02-instruction-updater.json` | Weekly. Reviews recent runs and **proposes** prompt improvements. It never applies them |

They are exported to disk rather than imported automatically for two reasons: n8n needs an owner account and an API key before the API works, neither of which exists on a fresh install, and importing by hand means you read a workflow before you run it.

### Using it

Trigger the agent loop by posting to its webhook:

```bash
curl -X POST http://127.0.0.1:5678/webhook/agent-task \
  -H 'Content-Type: application/json' \
  -d '{"task":"summarise the last week of agent runs"}'
```

Note that n8n distinguishes **test** and **production** webhook URLs. The path above is production and only works once the workflow is activated with the toggle in the top right. While editing, use the test URL the editor shows you, which fires once per click of "Listen for test event".

To call a model from a new workflow of your own, use an **HTTP Request** node against `http://litellm.platform.svc.cluster.local:4000/v1/chat/completions` — the in-cluster address, not `127.0.0.1`, because the node runs inside a pod.

### The Assistant and its sandbox

n8n's built-in Assistant writes and runs code, and it will not run any until you give it a sandbox. The sandbox is a service you host yourself — there is no URL to look up and no key to be issued — so `server/10-sandbox.sh --apply` builds one: an Ubuntu 24.04 VM named `n8n-sandbox` running the upstream service with Sysbox runners inside it.

It is a VM rather than a pod because this is the only part of the stack that exists to run code a model wrote rather than code you chose. The boundaries nest — Sysbox inside the guest, the hypervisor around it — so code that breaks out of the sandbox lands in a disposable image holding nothing, instead of on the machine with the secrets, the models and the GPU.

| | |
|---|---|
| Build or repair | `server/10-sandbox.sh --apply` — safe to re-run |
| What is running | `server/10-sandbox.sh --status` |
| A shell inside it | `server/10-sandbox.sh --shell` |
| Container logs | `server/10-sandbox.sh --logs` |
| Give back 6 GB | `multipass stop n8n-sandbox` |

n8n is pointed at it through environment variables in the manifest rather than the settings page, so the Assistant normally finds it with nothing typed. If it does ask, the Service URL is `http://sandbox.platform.svc.cluster.local:8080` and the key is in `/srv/platform/secrets/sandbox-api-key`. Use the cluster name rather than the VM's address: n8n runs inside the cluster, and the guest's address changes when it is rebuilt.

**It does not start at boot.** At 32 GB you cannot run the sandbox, the cluster and a Strata pack together, so starting it stays a decision. `r1wc` has it as an ordinary row with start and stop.

### Web search for the Assistant

The Assistant can also read the live web rather than recalling documentation from training, and n8n offers two providers for it. Brave Search is an API key and a third party in the path. SearXNG is a metasearch proxy you run yourself — it forwards the query to Google, Bing, DuckDuckGo and others, strips the identifying parts, and returns the results.

This kit runs SearXNG, in the cluster, applied by `server/03-platform.sh`. The reason is the same one behind the rest of the stack: the Assistant searches for whatever you happen to be building, and that sequence of queries is a fair description of your work. Through Brave it would accumulate under an account somewhere. There is nothing to configure in the n8n UI — the instance URL is set as an environment variable on the deployment.

The cost is real and worth stating: free engines rate-limit, so a long Assistant session can start returning nothing. If that becomes a nuisance, get a Brave key and add it to the n8n deployment as `INSTANCE_AI_BRAVE_SEARCH_API_KEY` — no `N8N_` prefix, which is upstream's spelling rather than a mistake. Brave takes priority, so SearXNG can stay where it is.

### The thing to back up

`/srv/platform/secrets/n8n-encryption-key` decrypts every credential n8n stores. Lose it and they are all permanently unreadable, with no recovery path — a database restore will not save you. It belongs somewhere off this machine. See [backups.md](backups.md).

### A scheduling caution

A workflow firing while you are gaming will call a model that `ai-pause` stopped, and the run will fail. That is working as designed — the failure is logged and you can re-run — but schedule anything important outside your play time.

---

## ComfyUI — images and video

**Port 8188.** Node-graph generation.

```bash
~/apps/start-comfyui.sh
```

**Loopback only, always.** ComfyUI has no authentication and can execute code through the editor, so never add `--listen`. If you need it remotely, use an SSH tunnel.

### Where things live

The checkout is under `~/apps/ComfyUI` and the models are not, so a `git pull` never has to think about tens of gigabytes of weights. `extra_model_paths.yaml` maps them:

| Put this | Here |
|---|---|
| Checkpoints | `~/ai/comfyui/models/checkpoints/` |
| Diffusion / UNet models | `~/ai/comfyui/models/diffusion_models/`, `.../unet/` |
| Text encoders, CLIP | `~/ai/comfyui/models/text_encoders/` |
| VAE | `~/ai/comfyui/models/vae/` |
| LoRAs | `~/ai/comfyui/models/loras/` |
| Upscalers | `~/ai/comfyui/models/upscale_models/` |

Generated output goes to `~/ai/comfyui/output/`.

Get the models with the kit's downloader rather than by hand — it places them in the right directories:

```bash
cd models
./download-models.sh image
./download-models.sh video
```

### First run

The default graph that loads is a working text-to-image pipeline. Select the checkpoint in the **Load Checkpoint** node — if the dropdown is empty, the models are not where `extra_model_paths.yaml` expects, and restarting ComfyUI is required after adding files because it scans at startup. Type a prompt into the positive **CLIP Text Encode** node and press **Queue Prompt**.

Two custom nodes are installed. **ComfyUI-Manager** adds a Manager button that browses and installs models and nodes from inside the UI, which saves guessing at repository names. **ComfyUI-GGUF** is required for the quantised Wan 2.2 14B video weights — without it those workflows fail to load with an unknown-node error.

### Memory discipline

ComfyUI and Strata both want the whole GPU. Running them together is how you get an out-of-memory error in whichever one asks second. Run `strata launch --stop` before a large video generation.

---

## Voice server — speech in and out

**Port 8100.** Whisper for transcription, Kokoro for speech, both on OpenAI-compatible routes so existing client code works unchanged.

```bash
~/apps/start-voice.sh
```

Open WebUI is already pointed at it. [voice/README.md](../voice/README.md) has every endpoint, the options and client examples.

---

## Postgres — the state underneath everything

**Port 5432, deliberately not forwarded.** n8n history, agent runs, LiteLLM spend and Open WebUI accounts all live here.

You reach it through the pod rather than over the network:

```bash
kubectl -n platform exec -it deploy/postgres -- psql -U postgres
```

Two databases: `litellm` (which also holds the agent schema) and `n8n`. The password is at `/srv/platform/secrets/postgres-password`.

Day to day you should not need this. The exception is reading agent history directly:

```bash
kubectl -n platform exec -it deploy/postgres -- \
  psql -U postgres -d litellm -c 'SELECT name, model_alias, version FROM agent_roles'
```

---

## The agent layer

Roles are **prompts in a database**, not pods and not separate models. Two helpers manage them:

```bash
agent-roles              # list the seeded roles and their versions
agent-runs               # recent executions and their outcomes
```

The seeded roles are `brain`, `worker`, `checker` and `updater`. Editing a role creates a new version rather than overwriting, so a prompt change that makes things worse is revertible.

`agent-runs` is where you look when a workflow "did nothing" — a run that failed its checker stage is recorded as a failure with the reason, not silently dropped.

The full design, including why this is not one pod per agent, is in [agent-orchestration.md](agent-orchestration.md).

---

## Game servers

```bash
games list                # what exists, what is running, and the memory cost
games start minecraft
games stop minecraft      # world preserved, memory returned
games stop-all
games logs valheim        # follow
games rcon                # Minecraft server console
games address             # how players connect
```

`games list` prints available memory underneath the table, which is the number that decides whether starting a second server is a good idea.

Stopping scales the deployment to zero. The world directory under `/srv/games` is untouched, so stopping and starting is free apart from the server's own startup time.

Players connect over Tailscale — `games address` prints the hostname and ports — and you must share your tailnet with them first. To add a game beyond the two provided, copy `server/k8s/39-game-template.yaml`; it must declare resource requests and limits or the namespace quota will reject it.

---

## Pi — terminal coding agent

```bash
strata connect pi    # writes the config
pi                   # start it
```

That points Pi at whichever Strata pack is currently serving on 8080, so switching models with `strata launch --preset` needs no config change. Full configuration, including pointing it at LiteLLM instead for quota accounting, is in [ports.md](ports.md).

---

## LM Studio Bionic — Windows only

A desktop GUI for chat and coding over local models. It is the reason the Windows side is usable without a terminal: download a model from the built-in catalogue, load it, chat.

Two things to know. It defaults to **port 1234**, chosen in this kit to stay clear of everything else, and its server mode is OpenAI-compatible, so the same client configuration that works against Strata works against it with the port changed. And it manages its own model directory, separate from `C:\AI` — the Windows model budget in [partition-layout.md](partition-layout.md) accounts for this.

---

## Backups

```bash
platform-backup          # run one now rather than waiting for the timer
platform-restore --list  # what is available
```

A nightly timer handles this unattended. The part worth doing by hand, once, is confirming a restore actually works — details and the offsite half in [backups.md](backups.md).
