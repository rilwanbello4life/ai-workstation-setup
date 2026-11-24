# Manual setup — server platform

Everything the `server/` scripts do, as commands you run yourself, with the reasoning for each. Follow this instead of `server/setup-all.sh` if you would rather understand each change than trust a script.

Assumes the Ubuntu AI stack from [manual-ubuntu.md](manual-ubuntu.md) is already working — the driver, Strata and at least one model. This phase turns that workstation into something that stays up and runs a platform on top of it.

Run everything as **your normal user**. Steps needing elevation call `sudo` explicitly.

| Section | Replaces | Phase |
|---|---|---|
| [1. Always-on base](#1-always-on-base) | `01-server-base.sh` | 12 |
| [2. k3s](#2-k3s) | `02-k3s.sh` | 13 |
| [3. Platform services](#3-platform-services) | `03-platform.sh` | 14 |
| [4. Agent layer](#4-agent-layer) | `04-agents.sh` | 15 |
| [5. Game servers](#5-game-servers-optional) | `05-game-servers.sh` | 16 |
| [6. Friends](#6-friends-optional) | `06-friends.sh` | 17 |
| [7. Backups](#7-backups) | `07-backup.sh` | 18 |

Paths used throughout:

```bash
export SRV_ROOT=/srv
export PLATFORM_DIR=/srv/platform
export GAMES_DIR=/srv/games
export SECRETS=/srv/platform/secrets
export K8S_NS=platform
```

Before starting, read [server-architecture.md](server-architecture.md). The memory arithmetic there is what makes the rest of this make sense: the platform takes about 15 GB, which caps the Strata pack you can hold at IQ2_XS on a 64 GB machine or UD-IQ4_XS on a 96 GB one.

---

## 1. Always-on base

The `ubuntu/` stack assumes someone is logged in. Four of its assumptions break when nobody is.

### 1.1 Stop the machine sleeping

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Masking is stronger than a logind setting: nothing can request these targets, including the desktop idle timer and the power button. **The power button will no longer suspend** — shut down with `systemctl poweroff`.

GNOME keeps its own idle timer that logind does not control:

```bash
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.desktop.session idle-delay 0
```

### 1.2 Enable lingering

```bash
sudo loginctl enable-linger "$USER"
```

Without this, every `systemctl --user` unit stops at logout — including the voice server.

### 1.3 Promote the voice server to a system unit

Lingering is not quite enough: a user unit still dies if the user manager restarts. Bind it to the machine instead.

```bash
sudo tee /etc/systemd/system/voice-server.service >/dev/null <<EOF
[Unit]
Description=Whisper + Kokoro voice server (OpenAI-compatible)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$HOME/apps/voice
Environment=HF_HOME=$HOME/ai/hf-cache
Environment=HUGGINGFACE_HUB_CACHE=$HOME/ai/hf-cache/hub
ExecStart=$HOME/apps/voice/.venv/bin/python $HOME/apps/voice/server.py --host 127.0.0.1 --port 8100
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

Retire the old user unit first, or both will fight over port 8100:

```bash
systemctl --user disable --now voice-server.service
mv ~/.config/systemd/user/voice-server.service{,.replaced-by-system-unit}

sudo systemctl daemon-reload
sudo systemctl enable --now voice-server.service
```

### 1.4 A swapfile, as insurance only

The kit deliberately ran without swap at 32 GB, because Strata `mlock`s its weights and swap could only hurt. With a cluster on top the calculus changes: an OOM kill with no swap takes whichever process the kernel picks, and that is often k3s rather than whatever actually overcommitted.

```bash
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

`vm.swappiness` is already 10 from `02-tune-linux.sh`. **mlocked pages are never swapped**, so Strata's performance is unaffected either way — this is insurance, not a memory extension.

### 1.5 Unattended security updates

```bash
sudo apt-get install -y unattended-upgrades

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

sudo tee /etc/apt/apt.conf.d/51-ai-server >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
```

`Automatic-Reboot "false"` matters. An unannounced reboot takes the cluster, any running game server and every in-flight generation with it.

### 1.6 Firewall

Everything binds to loopback and reaches the outside through Tailscale, so this is defence in depth rather than the primary control. k3s needs its own networks exempted or pod networking fails in genuinely confusing ways.

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw allow in on cni0
sudo ufw allow from 10.42.0.0/16     # pods
sudo ufw allow from 10.43.0.0/16     # services
sudo ufw enable
```

### 1.7 Directories

```bash
sudo mkdir -p /srv/platform /srv/games /srv/backups
sudo chown -R "$USER:$USER" /srv
```

### 1.8 ai-pause, ai-resume, ai-status

These are the levers everything later depends on. Rather than reproduce three scripts here, extract them from the kit:

```bash
cd ~/Projects/ai-workstation-setup/server
./01-server-base.sh --apply
```

Run with no arguments first — it reports what it would change and modifies nothing. If you want to write them by hand, the full text is in `01-server-base.sh` between `write_helpers()` and the closing `}`.

What they do:

| Command | Effect |
|---|---|
| `ai-pause` | Records replica counts, scales platform and games to zero, stops Strata and llama.cpp |
| `ai-pause --cluster` | Also stops k3s, freeing its ~1.5 GB |
| `ai-pause --games` | Only game servers |
| `ai-resume` | Restores exactly the recorded replicas; does **not** relaunch Strata |
| `ai-status` | Memory, VRAM, which model ports are listening, cluster state |

---

## 2. k3s

### 2.1 Install

```bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable-cloud-controller \
  '--kubelet-arg=eviction-hard=memory.available<1Gi' \
  '--kubelet-arg=system-reserved=memory=2Gi'
```

**Quote the kubelet arguments.** The `<` is part of the flag value; unquoted, your shell treats it as a redirect from a file named `1Gi`.

Those two flags are the most important thing in this section. Default eviction thresholds are generous, and on a box where Strata can claim 45 GB within a minute the kubelet must give memory up early. Without them the kernel OOM killer runs instead, and it frequently picks k3s.

Traefik and servicelb stay enabled: Traefik is the ingress for apps, and servicelb is how game servers get real ports.

### 2.2 kubectl

```bash
mkdir -p ~/.kube
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
chmod 600 ~/.kube/config
echo 'export KUBECONFIG="$HOME/.kube/config"' >> ~/.profile
export KUBECONFIG="$HOME/.kube/config"

kubectl get nodes      # wait for Ready
```

### 2.3 GPU support

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

sudo systemctl restart k3s      # so k3s's own containerd detects the runtime
sudo grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

k3s ships its own containerd, which is why a restart is needed rather than editing `/etc/containerd`.

```bash
kubectl apply -f server/k8s/00-runtimeclass.yaml
```

**This does not make the GPU shareable.** The device plugin assigns the whole card to one pod. Request `nvidia.com/gpu` only for batch work, after `ai-pause`.

### 2.4 Namespaces and storage

```bash
kubectl apply -f server/k8s/01-namespaces.yaml
mkdir -p /srv/platform/{postgres,n8n,litellm,openwebui}
kubectl apply -f server/k8s/02-storage.yaml
```

The ResourceQuotas in the first file are not decoration. Without them a runaway container takes the memory Strata needs and the kubelet evicts the wrong things trying to recover. The sharp edge: **every pod in these namespaces must declare requests and limits**, or it will be rejected.

Volumes live on `/srv` rather than under k3s's own storage directory, so there is one backup target and the data survives a cluster rebuild.

### 2.5 The host model bridge

Pods need a stable name for services running on the host. Strata cannot move into the cluster — it `mlock`s 25–30 GB, owns the GPU and takes minutes to load.

Nothing here involves an address any more. The cluster side is plain YAML — no `envsubst`, no `${HOST_IP}`, nothing that a rebuilt pod CIDR could stale:

```bash
kubectl label node "$(kubectl get nodes -o name | head -n1)" \
    ai.workstation/host-models=true --overwrite
kubectl apply -f server/k8s/03-host-models.yaml
```

That creates the `host-model-proxy` DaemonSet — one `socat` container per host service, dialing a unix socket in `/run/ai-model-bridge` — and ordinary selector Services for `strata`, `llamacpp`, `voice`, `gpu-probe`, `comfyui` and `gitops`, all on the same port numbers as before.

The sockets come from a host unit. Strata binds only to `127.0.0.1` and will go on doing so — rebinding it to `0.0.0.0` would expose an unauthenticated model server to your LAN — and a pod cannot dial a host loopback address, but it can dial a socket file the host publishes where the pod can see it:

```bash
sudo apt-get install -y socat
sudo mkdir -p /etc/ai-model-bridge
sudo tee /etc/ai-model-bridge/services >/dev/null <<'LIST'
strata 8080
llamacpp 8081
voice 8100
gpu-probe 8101
comfyui 8188
gitops 9418
LIST
sudo tee /etc/systemd/system/ai-model-bridge.service >/dev/null <<'EOF'
[Unit]
# ai-model-bridge v2
Description=Expose host loopback services to the cluster over unix sockets
After=k3s.service
Wants=k3s.service

[Service]
Type=simple
RuntimeDirectory=ai-model-bridge
RuntimeDirectoryMode=0755
ExecStart=/bin/bash -c 'while read -r name port; do socat "UNIX-LISTEN:/run/ai-model-bridge/${name}.sock,fork,reuseaddr,mode=0660" "TCP:127.0.0.1:${port}" & done < <(grep -Ev "^[[:space:]]*(#|$)" /etc/ai-model-bridge/services); wait -n; exit 1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ai-model-bridge.service
```

Do not revive the old `Type=oneshot` unit: its shell exited 0 even when every `socat` failed to bind, so systemd reported a dead bridge as healthy — that silent failure is what this unit exists to replace. `Type=simple` plus `wait -n` means the unit dies when its forwarders do and `Restart=always` repairs it.

This is exactly what `host_model_bridge_add` and `host_model_node_label` in `server/common.sh` do; running `./02-k3s.sh` does it for you and appends `gitops 9418` arrives via `./08-gitops.sh`.

Pods can now reach `http://strata.platform.svc.cluster.local:8080/v1` and friends. If a name fails: `ls /run/ai-model-bridge` (is the forwarder there), `kubectl -n platform get ds host-model-proxy` (is the proxy pod ready), then `curl http://127.0.0.1:8080/v1/models` (is the service itself up).

---

## 3. Platform services

### 3.1 Credentials

Generate once and persist, so re-running anything does not invalidate keys already issued:

```bash
sudo mkdir -p /srv/platform/secrets
gen() { [[ -f "$1" ]] || { openssl rand -hex "$2" | sudo tee "$1" >/dev/null; sudo chmod 600 "$1"; }; sudo cat "$1"; }

PG_PASSWORD="$(gen /srv/platform/secrets/postgres-password 24)"
N8N_DB_PASSWORD="$(gen /srv/platform/secrets/n8n-db-password 24)"
N8N_ENCRYPTION_KEY="$(gen /srv/platform/secrets/n8n-encryption-key 32)"
LITELLM_MASTER_KEY="sk-$(gen /srv/platform/secrets/litellm-master-key 24)"
LITELLM_SALT_KEY="$(gen /srv/platform/secrets/litellm-salt-key 32)"
WEBUI_SECRET_KEY="$(gen /srv/platform/secrets/openwebui-secret-key 32)"
```

**Back up `n8n-encryption-key` somewhere off this machine.** It decrypts every credential n8n stores. Lose it and they are all permanently unreadable, with no recovery.

```bash
kubectl -n platform create secret generic postgres-credentials \
  --from-literal=password="$PG_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n platform create secret generic n8n-credentials \
  --from-literal=db-password="$N8N_DB_PASSWORD" \
  --from-literal=encryption-key="$N8N_ENCRYPTION_KEY" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n platform create secret generic litellm-credentials \
  --from-literal=master-key="$LITELLM_MASTER_KEY" \
  --from-literal=salt-key="$LITELLM_SALT_KEY" \
  --from-literal=database-url="postgresql://litellm:${PG_PASSWORD}@postgres:5432/litellm" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n platform create secret generic openwebui-credentials \
  --from-literal=secret-key="$WEBUI_SECRET_KEY" --dry-run=client -o yaml | kubectl apply -f -
```

### 3.2 Postgres

```bash
kubectl apply -f server/k8s/10-postgres.yaml
kubectl -n platform rollout status deploy/postgres --timeout=180s
```

Note `strategy: Recreate` in that manifest. Two Postgres pods cannot share one hostPath volume, and a RollingUpdate would start the second before stopping the first.

Three logical databases in one server:

```bash
kubectl -n platform exec -i deploy/postgres -- psql -U postgres <<SQL
CREATE ROLE litellm LOGIN PASSWORD '${PG_PASSWORD}';
CREATE ROLE n8n     LOGIN PASSWORD '${N8N_DB_PASSWORD}';
CREATE DATABASE litellm OWNER litellm;
CREATE DATABASE n8n     OWNER n8n;
SQL
```

### 3.3 LiteLLM

```bash
kubectl apply -f server/k8s/11-litellm.yaml
kubectl -n platform rollout status deploy/litellm --timeout=240s
```

This is the piece that turns "expose my models" from handing out an unauthenticated GPU into handing out a revocable key with a spend ceiling and a rate limit. Read the ConfigMap in that file — the role aliases are defined there, and they are the contract the agent layer depends on:

| Alias | Backend | Notes |
|---|---|---|
| `brain` | Strata | `reasoning_effort: xhigh` |
| `worker` | Strata, same pack | `reasoning_effort: low` |
| `checker` | llama.cpp | A genuinely different model |
| `strata`, `local` | passthrough | |

Two settings worth understanding before you change them. `max_parallel_requests: 4` reflects Strata holding ~1.5 GB of KV cache per slot at 32K context against a 16 GB card. `num_retries: 0` is deliberate — a timeout here means the model is loading or the queue is deep, and retrying makes both worse.

### 3.4 n8n and Open WebUI

```bash
kubectl apply -f server/k8s/12-n8n.yaml
kubectl -n platform rollout status deploy/n8n --timeout=240s
```

Postgres-backed rather than the default SQLite, because SQLite on a hostPath volume under concurrent executions is a corruption story waiting to happen.

Retire the user-level Open WebUI from `08-remote-access.sh` before deploying the cluster copy, or they will both answer on port 3000:

```bash
systemctl --user disable --now open-webui.service
kubectl apply -f server/k8s/13-open-webui.yaml
kubectl -n platform rollout status deploy/open-webui --timeout=240s
```

### 3.5 Loopback access

Services are ClusterIP only. One systemd unit forwards the three humans use, which keeps them compatible with the existing `tailscale serve` mapping:

```bash
sudo tee /etc/systemd/system/platform-forward.service >/dev/null <<EOF
[Unit]
Description=Expose platform services on loopback
After=k3s.service
Wants=k3s.service

[Service]
Type=simple
User=$USER
Environment=KUBECONFIG=$HOME/.kube/config
ExecStart=/bin/sh -c '\\
  kubectl -n platform port-forward --address 127.0.0.1 svc/litellm 4000:4000 & \\
  kubectl -n platform port-forward --address 127.0.0.1 svc/n8n 5678:5678 & \\
  kubectl -n platform port-forward --address 127.0.0.1 svc/open-webui 3000:3000 & \\
  wait'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now platform-forward.service
```

`--address 127.0.0.1` is the default, stated explicitly because binding `0.0.0.0` here would put an unauthenticated gateway on your LAN.

Verify:

```bash
curl -s http://127.0.0.1:4000/health/readiness
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
curl -sI http://127.0.0.1:5678 | head -1
```

---

## 4. Agent layer

### 4.1 Prompt store

```bash
kubectl -n platform exec -i deploy/postgres -- \
  psql -U postgres -d litellm -v ON_ERROR_STOP=1 < server/k8s/20-agent-schema.sql
```

That creates `agent_roles`, `agent_role_history`, `agent_runs` and the `agent_role_performance` view, and seeds the four roles. Read the file before running it — the seeded system prompts are the actual behaviour of your agent system, and they are written to be edited.

```bash
kubectl -n platform exec deploy/postgres -- \
  psql -U postgres -d litellm -c 'SELECT name, model_alias, version FROM agent_roles'
```

### 4.2 Management commands

`agent-roles` and `agent-runs` are psql wrappers; their full text is in `04-agents.sh`. Install them with:

```bash
./04-agents.sh
```

### 4.3 Workflows

```bash
mkdir -p /srv/platform/n8n-workflows
```

Two starter workflows are written there by the script. Import them by hand through the n8n UI (**Workflows → Import from file**) after creating the owner account and a Postgres credential pointing at database `litellm`.

They are not imported through the API because a fresh n8n has no owner and no API key, and because importing by hand means you read them first.

The design constraint to keep in mind while building your own: **roles are prompts, not pods.** Swapping a Strata pack costs 1–3 minutes, so `brain` and `worker` must share the resident pack and differ only in `reasoning_effort`. The full reasoning is in [agent-orchestration.md](agent-orchestration.md).

---

## 5. Game servers (optional)

Every gigabyte here is a gigabyte Strata cannot hold. Check first:

```bash
ai-status
```

Minecraft:

```bash
kubectl -n games create secret generic minecraft-rcon \
  --from-literal=password="$(openssl rand -hex 16)" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f server/k8s/30-minecraft.yaml
kubectl -n games rollout status deploy/minecraft --timeout=600s
```

First boot generates the world and is slow. Valheim is `31-valheim.yaml` and slower still — SteamCMD downloads the server on first run.

Anything else: copy `server/k8s/39-game-template.yaml`. The four things to get right are listed in its header, and the one that silently produces a server nobody can join is declaring a UDP game's port as TCP.

Players connect over Tailscale. The firewall denies inbound on everything except `tailscale0`, so a LoadBalancer service is reachable by your tailnet and not by the internet.

---

## 6. Friends (optional)

Two independent decisions. **Authorisation** is settled — LiteLLM virtual keys. **Transport** is still open; see [sharing-with-friends.md](sharing-with-friends.md) for the trade-off between Tailscale node sharing and Cloudflare Tunnel.

The Tailscale path:

```bash
sudo tailscale serve --bg --https=8447 http://127.0.0.1:4000
tailscale serve status
```

Then share the machine with one person at a time from the Tailscale admin console under **Machines → this host → Share**.

Create a key:

```bash
MASTER="sk-$(sudo cat /srv/platform/secrets/litellm-master-key)"
curl -s -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d '{"key_alias":"alice","models":["worker","local","checker"],
       "max_budget":50,"rpm_limit":10,"tpm_limit":100000}'
```

`brain` is excluded on purpose: one `xhigh` call can hold the GPU for minutes, and a friend looping them takes your own assistant offline.

The `friends` command wraps all of this — install it with `./06-friends.sh`. Before handing out the first key, read the liability section of [sharing-with-friends.md](sharing-with-friends.md).

**Never run `tailscale funnel`.** It publishes a serve endpoint to the public internet with none of the authentication that would make that acceptable.

---

## 7. Backups

Not optional, whatever else you skipped. Until this runs nothing is backed up, and the smallest file on the machine — `secrets/n8n-encryption-key` — is the one whose loss cannot be undone.

```bash
sudo apt-get install -y restic
mkdir -p /srv/backups/{postgres,workflows,manifests}
```

A nightly dump, by hand:

```bash
kubectl -n platform exec deploy/postgres -- \
  pg_dumpall -U postgres --clean --if-exists | gzip > /srv/backups/postgres/pg-$(date +%F).sql.gz

kubectl -n platform exec deploy/n8n -- n8n export:workflow --all --pretty --output=/tmp/wf.json
kubectl -n platform exec deploy/n8n -- cat /tmp/wf.json > /srv/backups/workflows/wf-$(date +%F).json
```

`pg_dumpall` rather than `pg_dump` because it captures roles and their passwords; without those a restore produces databases nothing can log into. The JSON export duplicates what is already in the dump, deliberately — it is readable by hand, which is what helps when the database restore is the broken part.

Offsite, encrypted before it leaves the house:

```bash
export RESTIC_REPOSITORY="b2:your-bucket:ai-workstation"
export B2_ACCOUNT_ID="..." B2_ACCOUNT_KEY="..."
export RESTIC_PASSWORD_FILE=/srv/platform/secrets/restic-password

restic init
restic backup /srv/backups /srv/platform/secrets /srv/games
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

**Write the restic password down somewhere that is not this machine**, along with `secrets/n8n-encryption-key`. Both live inside the backup, which makes them worthless on their own: losing the machine would leave you with a repository you cannot decrypt. This is the single step that decides whether any of the above is a backup or a decoration.

`./07-backup.sh` does all of this, adds a 03:30 systemd timer with `Persistent=true` so a night in Windows is caught rather than skipped, flushes Minecraft writes during the world copy, and installs `platform-backup` and `platform-restore`. The reasoning and a full disaster-recovery order are in [backups.md](backups.md).

---

## Verifying the whole thing

```bash
ai-status                        # memory, VRAM, ports, cluster
kubectl get pods -A              # everything running
agent-roles list                 # prompt versions and pass rates
games list                       # game servers and their memory cost
friends list                     # issued keys and spend
platform-restore local           # that last night's backup actually exists
```

An end-to-end check that exercises the whole chain — gateway, routing, host bridge and the model:

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $(echo sk-$(sudo cat /srv/platform/secrets/litellm-master-key))" \
  -H 'Content-Type: application/json' \
  -d '{"model":"worker","messages":[{"role":"user","content":"Reply with the single word: working"}]}'
```

If that returns text, every layer in this document is wired correctly.

## If something is wrong

| Symptom | Likely cause |
|---|---|
| Pods `Pending` | ResourceQuota, or no memory. `kubectl -n platform describe pod <name>` |
| Pod cannot reach a model | Strata not loaded, or no socket in `/run/ai-model-bridge` (bridge unit down) |
| `kubectl` permission denied | `KUBECONFIG` unset in this shell |
| LiteLLM 500s on start | Still running database migrations; wait and check the logs |
| n8n credentials unreadable | The encryption key changed. This is unrecoverable |
| Everything died at once | Check `dmesg -T | grep -i oom` |

Deeper diagnosis is in [kubernetes.md](kubernetes.md) and [troubleshooting.md](troubleshooting.md).
