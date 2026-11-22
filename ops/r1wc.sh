#!/usr/bin/env bash
# R1WC - the R1 workstation operations console.
#
#   r1wc                  the menu: everything, with live status, on one page
#   r1wc list             the same list, printed and exited
#   r1wc status           every item's state, for a script or a glance
#   r1wc docs strata      what a thing is and how to operate it
#   r1wc start strata     start it, doing whatever has to happen first
#   r1wc stop  strata     stop it
#   r1wc ui argocd        open its interface
#   r1wc --install        put 'r1wc' on PATH
#
# This starts and stops nothing by itself. Every action below runs the
# command you would have run by hand - ops/switch.sh, systemctl, kubectl,
# ai-pause - so there is one implementation of each operation and this is a
# way of finding it rather than a second copy of it. 'docs' on any entry
# prints the underlying command, so the console teaches its own replacement.
#
# The one piece of real logic is the GPU rule. Strata, llama.cpp and ComfyUI
# cannot coexist: 16 GB of VRAM holds one, and a Strata pack pins 25-62 GB of
# system RAM on top. Starting a second does not fail cleanly - it refuses
# somewhere deep in a CUDA library, or the desktop locks up while the kernel
# pages. So anything marked [gpu] is started through ops/switch.sh, which
# stops the incumbent and waits for the driver to release the memory first.
# Anything marked [cpu] skips all of that, because it genuinely can run
# alongside.
#
# Background: ../reference/ports.md, ../reference/troubleshooting.md

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../server" && pwd)/common.sh"
require_not_root

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SWITCH="$HERE/switch.sh"

# Strata ships a terminal monitor rather than a web interface. If you have a
# desktop app or a local page for it, point this at the file or URL and the
# 'ui' action will open that instead.
R1WC_STRATA_UI="${R1WC_STRATA_UI:-}"

# ---------------------------------------------------------------------------
# The registry. id, group, label, kind, port, ui-url
#
# kind drives behaviour, not just the label:
#   gpu  exclusive - started through switch.sh so the incumbent is stopped
#   cpu  a host service that coexists with whatever holds the GPU
#   k8s  a workload in the cluster, scaled rather than started
#   sys  a plain systemd unit
#   act  an action rather than a service - no running state to report
#
# Real tabs between fields.
read -r -d '' ITEMS <<'EOF' || true
strata	models	Strata (MoE packs)	gpu	8080	-
llamacpp	models	llama.cpp (GGUF)	gpu	8081	-
comfyui	models	ComfyUI (image, video)	gpu	8188	http://127.0.0.1:8188
voice	models	Voice server (Whisper, Kokoro)	cpu	8100	-
cluster	platform	k3s cluster	sys	-	-
postgres	platform	Postgres	k8s	-	-
n8n	platform	n8n (workflows)	k8s	5678	http://127.0.0.1:5678
openwebui	platform	Open WebUI (chat)	k8s	3000	http://127.0.0.1:3000
litellm	platform	LiteLLM gateway	k8s	4000	-
queue	platform	GPU queue	k8s	4100	-
argocd	platform	Argo CD (GitOps)	k8s	8090	http://127.0.0.1:8090
sandbox	platform	Code sandbox (n8n Assistant)	vm	8080	-
searxng	platform	Web search (n8n Assistant)	k8s	-	-
tailscale	access	Tailscale VPN	sys	-	-
forwards	access	Loopback port forwards	sys	-	-
friends	access	Friends access (keys, limits)	act	-	-
games	games	Game servers	act	-	-
secrets	maintain	Passwords, keys and accounts	act	-	-
pause	maintain	Pause the cluster (~15 GB)	act	-	-
backup	maintain	Backup now	act	-	-
boot	maintain	Whole machine up / down	act	-	-
report	maintain	Full status report	act	-	-
EOF

group_title() {
    case "$1" in
        models)   printf 'MODELS - one at a time on the GPU' ;;
        platform) printf 'PLATFORM - the cluster' ;;
        access)   printf 'ACCESS - network and sharing' ;;
        games)    printf 'GAMES' ;;
        maintain) printf 'MAINTENANCE' ;;
        *)        printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Status. Every one of these has to answer on a half-built machine without
# failing: no kubectl, no cluster, no nvidia-smi. They are called in a loop
# under 'set -e', so each ends in a definite success.

port_open() {
    [[ "$1" == "-" ]] && return 1
    if have ss; then
        ss -ltn 2>/dev/null | grep -q ":$1 " && return 0
    fi
    return 1
}

unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Asked once per redraw, not once per row.
#
# The first version called this for each of the seven cluster entries, and
# every call pays the full connection timeout when the API is not answering
# - which is exactly when you are most likely to be looking at this screen.
# That turned a menu into a ten-second wait. The timeout is explicit for the
# same reason: kubectl's default is long enough to feel like a hang.
KUBE_OK=""
kube_up() {
    case "$KUBE_OK" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac
    if have kubectl && kubectl --request-timeout=3s get --raw='/readyz' >/dev/null 2>&1
    then KUBE_OK=yes; return 0
    else KUBE_OK=no;  return 1
    fi
}

# Ready replicas for a deployment, or empty when it cannot be asked.
deploy_ready() {
    kube_up || { printf ''; return 0; }
    kubectl --request-timeout=3s -n "${2:-$K8S_NS}" get deploy "$1" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || printf ''
}

item_status() {
    local id="$1" r
    case "$id" in
        strata)
            if have strata && strata launch --status >/dev/null 2>&1; then
                printf 'running'; else printf 'stopped'; fi ;;
        llamacpp)
            if pgrep -f 'llama-server' >/dev/null 2>&1; then
                printf 'running'; else printf 'stopped'; fi ;;
        comfyui)
            if pgrep -f 'ComfyUI/main.py' >/dev/null 2>&1; then
                printf 'running'; else printf 'stopped'; fi ;;
        voice)
            if unit_active voice-server.service || port_open 8100; then
                printf 'running'; else printf 'stopped'; fi ;;
        cluster)
            if kube_up; then printf 'running'
            elif unit_active k3s.service; then printf 'starting'
            else printf 'stopped'; fi ;;
        postgres|n8n|openwebui|litellm|searxng)
            r="$(deploy_ready "$id")"
            if [[ -n "$r" && "$r" != 0 ]]; then printf 'running'
            elif kube_up; then printf 'stopped'
            else printf '-'; fi ;;
        queue)
            r="$(deploy_ready gpu-queue)"
            if [[ -n "$r" && "$r" != 0 ]]; then printf 'running'
            elif kube_up; then printf 'stopped'
            else printf '-'; fi ;;
        argocd)
            r="$(deploy_ready argocd-server argocd)"
            if [[ -n "$r" && "$r" != 0 ]]; then printf 'running'
            elif kube_up; then printf 'stopped'
            else printf '-'; fi ;;
        tailscale)
            if have tailscale && tailscale status >/dev/null 2>&1; then
                printf 'running'; else printf 'stopped'; fi ;;
        forwards)
            if unit_active platform-forward.service; then printf 'running'
            else printf 'stopped'; fi ;;
        sandbox)
            # A VM, not a unit and not a pod. 'not built' and 'stopped' are
            # different answers worth distinguishing: the first needs
            # 10-sandbox.sh --apply, the second needs multipass start.
            #
            # A booted guest whose containers have not come up looks
            # identical to a working one from the outside, so the running
            # state is the API answering rather than the VM existing.
            if ! have multipass; then printf -- '-'
            elif ! multipass info n8n-sandbox >/dev/null 2>&1; then printf 'not built'
            else
                sb_ip="$(multipass info n8n-sandbox --format csv 2>/dev/null |
                         awk -F, '
                             NR==1 { for (i=1;i<=NF;i++) {
                                         if ($i=="State") s=i
                                         if ($i=="IPv4")  p=i }; next }
                             NR==2 { if (s && $s=="Running" && p) print $p }' |
                         cut -d\; -f1)"
                if [[ -z "$sb_ip" ]]; then printf 'stopped'
                elif curl -fsS --max-time 2 "http://$sb_ip:8080/healthz" \
                     >/dev/null 2>&1; then printf 'running'
                else printf 'no api'; fi
            fi ;;
        pause)
            # ai-pause records what it scaled down; the directory existing
            # and being non-empty is what "currently paused" means.
            if [[ -d /var/lib/ai-pause ]] && \
               [[ -n "$(ls -A /var/lib/ai-pause 2>/dev/null)" ]]; then
                printf 'PAUSED'; else printf 'unpaused'; fi ;;
        *) printf '-' ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Actions. Each one runs the command a person would run, and says which.

say_running() { printf '\n  %s> %s%s\n\n' "$_C_CYAN" "$*" "$_C_RESET"; }

run_it() { say_running "$*"; "$@"; }

item_start() {
    local id="$1" arg="${2:-}"
    case "$id" in
        strata)
            if [[ -z "$arg" ]]; then
                info "Strata needs a preset. The ones installed here:"
                have strata && strata launch --list-presets 2>/dev/null | sed 's/^/      /' || true
                read -r -p "  Preset (blank to cancel): " arg || return 0
                [[ -n "$arg" ]] || { warn "Cancelled."; return 0; }
            fi
            run_it "$SWITCH" strata "$arg" ;;
        llamacpp)
            if [[ -z "$arg" ]]; then
                info "Available GGUF files:"
                ls -1 "$AI_ROOT/gguf" 2>/dev/null | sed 's/^/      /' || true
                read -r -p "  File (blank to cancel): " arg || return 0
                [[ -n "$arg" ]] || { warn "Cancelled."; return 0; }
            fi
            run_it "$SWITCH" llamacpp "$arg" ;;
        comfyui)   run_it "$SWITCH" comfyui ;;
        voice)     run_it sudo systemctl start voice-server.service ;;
        cluster)   run_it sudo systemctl start k3s.service ;;
        postgres|n8n|openwebui|litellm|searxng)
            run_it kubectl -n "$K8S_NS" scale deploy "$id" --replicas=1 ;;
        queue)     run_it kubectl -n "$K8S_NS" scale deploy gpu-queue --replicas=1 ;;
        argocd)    run_it kubectl -n argocd scale deploy argocd-server --replicas=1 ;;
        tailscale) run_it sudo tailscale up ;;
        forwards)  run_it sudo systemctl start platform-forward.service ;;
        sandbox)   run_it multipass start n8n-sandbox ;;
        friends)   run_it friends ;;
        games)     run_it games ;;
        pause)     run_it ai-resume ;;
        backup)    run_it platform-backup ;;
        boot)      run_it "$HERE/up.sh" ;;
        report)    run_it "$KIT/status.sh" ;;
        *) warn "Nothing to start for '$id'." ;;
    esac
    return 0
}

item_stop() {
    local id="$1"
    case "$id" in
        strata|llamacpp|comfyui)
            # switch.sh none stops all three and waits for the driver to
            # hand the memory back, which is the part worth not skipping.
            run_it "$SWITCH" none ;;
        voice)     run_it sudo systemctl stop voice-server.service ;;
        cluster)   run_it sudo systemctl stop k3s.service ;;
        postgres|n8n|openwebui|litellm|searxng)
            run_it kubectl -n "$K8S_NS" scale deploy "$id" --replicas=0 ;;
        queue)     run_it kubectl -n "$K8S_NS" scale deploy gpu-queue --replicas=0 ;;
        argocd)    run_it kubectl -n argocd scale deploy argocd-server --replicas=0 ;;
        tailscale) run_it sudo tailscale down ;;
        forwards)  run_it sudo systemctl stop platform-forward.service ;;
        sandbox)   run_it multipass stop n8n-sandbox ;;
        pause)     run_it ai-pause --cluster ;;
        boot)      run_it "$HERE/down.sh" ;;
        games)     run_it games stop ;;
        *) warn "Nothing to stop for '$id'." ;;
    esac
    return 0
}

item_ui() {
    local id="$1" url
    url="$(awk -F'\t' -v i="$id" '$1 == i { print $6 }' <<<"$ITEMS")"

    if [[ "$id" == strata ]]; then
        if [[ -n "$R1WC_STRATA_UI" ]]; then
            url="$R1WC_STRATA_UI"
        else
            cat <<'EOF'

  If something calling through LiteLLM reports "Host ... is not allowed
  (DNS rebinding protection)", Strata is refusing the cluster's name for
  it, not rejecting a key. STRATA_ALLOWED_HOSTS in the generated shell
  environment covers it, and must be set in the shell that launches
  Strata. See reference/troubleshooting.md.

  Strata has no web interface of its own. Two ways to drive it:

      strata launch --preset <name>    the terminal monitor, which is
                                       Strata's real UI - live tokens per
                                       second, memory and the loaded pack
      Open WebUI on :3000              a chat front-end that talks to
                                       Strata's API. 'r1wc ui openwebui'

  If you have a Strata desktop app or a local page, point R1WC_STRATA_UI at
  it - a file path or a URL - and this action will open that instead:

      export R1WC_STRATA_UI=/path/to/the/file

EOF
            return 0
        fi
    fi

    [[ -n "$url" && "$url" != "-" ]] || { warn "$id has no interface to open."; return 0; }

    # Opening the URL is pointless if nothing is listening, and "the browser
    # showed a connection error" is a worse message than this one.
    #
    # Only gate when the target really is this service's own loopback port.
    # A file path or an external URL - which is what R1WC_STRATA_UI is for,
    # since Strata's interface may be a local app rather than a server -
    # has nothing to do with whether the port is up, and refusing to open
    # it would be nonsense.
    local port
    port="$(awk -F'\t' -v i="$id" '$1 == i { print $5 }' <<<"$ITEMS")"
    if [[ "$port" != "-" && "$url" == *"127.0.0.1:$port"* ]] && ! port_open "$port"; then
        warn "Nothing is listening on $port, so $id is not up yet."
        info "Start it first, then open the interface."
        return 0
    fi

    info "Opening $url"
    if have xdg-open; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        info "No xdg-open here. Open it yourself: $url"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Documentation. One entry each: what it is, how to run it by hand, what it
# collides with, and where the long version lives.

item_docs() {
    local id="$1"
    case "$id" in
    strata) cat <<'EOF'
Strata - the MoE packs, the main local model server.

  Port 8080, OpenAI- and Anthropic-compatible at http://127.0.0.1:8080/v1

  Start        r1wc start strata, or  ops/switch.sh strata <preset>
  Stop         ops/switch.sh none
  Which packs  strata models list  /  strata launch --list-presets
  Live monitor strata launch --preset <name>     (this is Strata's UI)

  [gpu] Exclusive. Starting it stops llama.cpp and ComfyUI first and waits
  for the driver to release the VRAM. That wait is the step people skip by
  hand, and the out-of-memory error it causes looks like a bug in the pack.

  The largest packs need the cluster's ~15 GB as well:

      ops/switch.sh strata unsloth-ud-iq4_xs --pause-cluster

  Remember that leaves the cluster scaled to zero - 'ai-resume' or
  'r1wc start pause' brings it back, and the state survives a reboot.

  Expect the desktop to be unresponsive for one to three minutes while a
  pack loads: 35-62 GB is read into RAM and partly pinned for the GPU.

  If STRATA_ALLOWED_HOSTS is empty in your shell, the generated env file
  predates it. ops/switch.sh exports it regardless, so starting Strata
  from here is already correct, but to fix the shell too:

      ubuntu/11-shell-env.sh      rewrites ~/.config/ai-workstation/env.sh

  Then open a new terminal and restart the pack - Strata reads the value
  once, at startup, so setting it in a shell later changes nothing until
  the pack is reloaded.

  Full catalogue and quality numbers: reference/strata-models.md
EOF
    ;;
    llamacpp) cat <<'EOF'
llama.cpp - a single GGUF file, served on port 8081.

  Start   r1wc start llamacpp, or  ops/switch.sh llamacpp <file.gguf>
  Stop    ops/switch.sh none
  Files   ls ~/ai/models/gguf
  API     http://127.0.0.1:8081/v1   (OpenAI-compatible)

  [gpu] Exclusive with Strata and ComfyUI by default. The exception worth
  knowing: a small GGUF can run alongside Strata, costing Strata about 9 GB
  of VRAM and some speed. That is deliberate when you want a second model
  whose mistakes are uncorrelated with the first - the agent 'checker' role
  depends on exactly that. If you are not running agents, do not pay for it.

  Rebuild after moving it: ubuntu/04-llamacpp.sh
EOF
    ;;
    comfyui) cat <<'EOF'
ComfyUI - image and video generation. Web interface on 8188.

  Start   r1wc start comfyui, or  ops/switch.sh comfyui
  Stop    ops/switch.sh none
  Open    r1wc ui comfyui          http://127.0.0.1:8188

  [gpu] Exclusive with the language models - this one genuinely will not
  share. It will run alongside the voice server, since Whisper is on CPU.

  Models live under ~/ai/models/comfyui. Outputs are written to
  ~/ai/output, not inside the application directory, so a reinstall of
  ComfyUI cannot take your generations with it.

  Full notes: reference/troubleshooting.md, the ComfyUI section.
EOF
    ;;
    voice) cat <<'EOF'
Voice server - speech to text (Whisper) and text to speech (Kokoro).

  Port 8100, OpenAI audio endpoints at http://127.0.0.1:8100/v1

  Start   sudo systemctl start voice-server
  Stop    sudo systemctl stop voice-server
  Logs    journalctl -u voice-server -f
  Status  systemctl status voice-server

  [cpu] Runs alongside anything. Both models are on the CPU on purpose: it
  keeps the card free for the language model, and neither is fast enough on
  a GPU to be worth the VRAM. This is why dictation works while a 60 GB
  pack is loaded.

  It is a systemd unit, so it comes back after a reboot on its own.
EOF
    ;;
    cluster) cat <<'EOF'
k3s - the Kubernetes cluster everything in PLATFORM runs on.

  Start   sudo systemctl start k3s
  Stop    sudo systemctl stop k3s
  Health  kubectl get nodes -o wide  /  kubectl get pods -A
  Logs    sudo journalctl -u k3s -f

  Holds about 1.5 GB before any workload. It starts at boot and takes
  30-60 seconds to answer - anything asked sooner fails in a way that reads
  as broken rather than early.

  To free its memory without stopping it permanently, use the pause entry
  rather than stopping k3s: pausing records what was running so it can be
  put back, and stopping k3s does not.

  Note the node address is pinned in /etc/rancher/k3s/config.yaml. If
  'kubectl logs' ever fails with an x509 error naming an IP, that pin and
  the kubelet certificate have diverged - see reference/troubleshooting.md.
EOF
    ;;
    postgres) cat <<'EOF'
Postgres - shared state for LiteLLM, n8n and the agent prompt store.

  Start   kubectl -n platform scale deploy postgres --replicas=1
  Stop    kubectl -n platform scale deploy postgres --replicas=0
  Shell   kubectl -n platform exec -it deploy/postgres -- psql -U postgres
  Logs    kubectl -n platform logs deploy/postgres -f

  Not forwarded to loopback - reach it through kubectl exec. Data lives on
  the host at /srv/platform/postgres and is backed up nightly.

  The superuser password was generated at install; you did not miss a
  step. 'psql -U postgres' from inside the pod needs no password at all,
  which is why the shell command above just works.

      sudo cat /srv/platform/secrets/postgres-password

  You need it when adding the Postgres credential inside n8n, and nowhere
  else day to day. To change it, see 'r1wc docs secrets'.

  One database server with three logical databases rather than three
  servers: at ~2 GB resident it is already a real slice of the memory
  budget, and three would cost triple for no isolation on a single node.

  It runs as uid 70 deliberately. Do not "fix" that to root - the entrypoint
  would then drop privileges with gosu, which AppArmor blocks on this
  release, and the container hangs with no log output at all.
EOF
    ;;
    n8n) cat <<'EOF'
n8n - the workflow editor. This is where the agent loop is wired together.

  Open    r1wc ui n8n             http://127.0.0.1:5678
  Start   kubectl -n platform scale deploy n8n --replicas=1
  Stop    kubectl -n platform scale deploy n8n --replicas=0
  Logs    kubectl -n platform logs deploy/n8n -f

  There is no password to look up. The FIRST person to open it creates
  the owner account, so claim it before anything else can. It is bound to
  loopback and Tailscale, so that is your own devices, not the internet.

  Inside n8n, do NOT use 127.0.0.1. n8n runs in the cluster, so loopback
  there means the n8n container itself and you get ECONNREFUSED. That
  applies to the AI Assistant settings and to any HTTP Request node
  pointing at something on this machine:

      from your desktop     http://127.0.0.1:4000/v1
      from inside n8n       http://litellm.platform.svc.cluster.local:4000/v1

  For the built-in AI Assistant: an OpenAI-compatible provider, the
  cluster URL above, model 'strata', and 'sk-' followed by
  /srv/platform/secrets/litellm-master-key. It only answers while a pack
  is actually loaded - 'strata' passes through to whatever is on 8080.

  Starter workflows were written to /srv/platform/n8n-workflows. Import
  them with Workflows > Import from file. Read them before activating -
  they are starting points, not products.

  The Postgres credential it needs:
      host postgres   database litellm   user postgres
      password: /srv/platform/secrets/postgres-password

  /srv/platform/secrets/n8n-encryption-key is what makes every credential
  n8n stores readable. Lose it and they are all permanently unreadable, and
  no backup of the database alone will save you.
EOF
    ;;
    openwebui) cat <<'EOF'
Open WebUI - a chat interface in front of the local models.

  Open    r1wc ui openwebui       http://127.0.0.1:3000
  Start   kubectl -n platform scale deploy openwebui --replicas=1
  Stop    kubectl -n platform scale deploy openwebui --replicas=0

  This is the closest thing to a UI for Strata: point it at the LiteLLM
  gateway and it talks to whichever pack is loaded on 8080.

  It defaults to port 8080 upstream, which collides with Strata, so it is
  always run on 3000 here. If you ever deploy it yourself, keep that.

  There is no password to look up. The FIRST account created becomes the
  administrator, so until you open it and register, anyone who can reach
  3000 can claim it. It is bound to loopback and Tailscale, so that means
  your own devices rather than the internet - but claim it now anyway.

  Connect it to the gateway: Settings > Connections > OpenAI API,
  base URL http://litellm.platform.svc.cluster.local:4000/v1, and a key
  from 'sudo cat /srv/platform/secrets/litellm-master-key' with sk- in
  front. The models brain, worker, checker, strata and local then appear
  in the model picker.
EOF
    ;;
    litellm) cat <<'EOF'
LiteLLM - the API gateway. One OpenAI-compatible endpoint, real keys.

  API     http://127.0.0.1:4000/v1   (needs a key)
  Start   kubectl -n platform scale deploy litellm --replicas=1
  Stop    kubectl -n platform scale deploy litellm --replicas=0
  Keys    friends

  Use 4000 for your own tools, where being refused is easy to notice. Send
  shared traffic to the GPU queue on 4100 instead: LiteLLM returns 429 once
  max_parallel_requests is hit, while the queue holds the request until
  there is room. Same keys, different behaviour under load.

  Ports 4000 and 4100 are the only two here with authentication, which is
  what makes them the only two safe to share. See reference/ports.md.

  The master key is the gateway admin - it can mint and revoke every other
  key, so use it for administration and give nobody else a copy:

      sudo cat /srv/platform/secrets/litellm-master-key

      curl http://127.0.0.1:4000/v1/models \
        -H "Authorization: Bearer sk-PASTE-THE-KEY-HERE"

  Note the sk- prefix: the file holds the key without it. The admin
  interface is at http://127.0.0.1:4000/ui, same key as the password.

  For anyone else, issue a scoped key with 'friends' rather than sharing
  this one. Those carry their own budget and rate limit and can be
  revoked individually.
EOF
    ;;
    queue) cat <<'EOF'
GPU queue - the front door for shared access.

  API     http://127.0.0.1:4100/v1
  Start   kubectl -n platform scale deploy gpu-queue --replicas=1
  Stop    kubectl -n platform scale deploy gpu-queue --replicas=0
  Watch   queue

  Admits one heavy request at a time and holds the rest, instead of
  refusing them. This is what makes one GPU usable by several people
  without anyone seeing an error - they see a wait, which is honest.

  Full behaviour: reference/gpu-queue.md
EOF
    ;;
    argocd) cat <<'EOF'
Argo CD - GitOps. What is in the repository is what runs.

  Open    r1wc ui argocd          http://127.0.0.1:8090
  Start   kubectl -n argocd scale deploy argocd-server --replicas=1
  Stop    kubectl -n argocd scale deploy argocd-server --replicas=0
  Deploy  gitops commit -m "message"

  The repository is /srv/gitops, pushed to the bare /srv/gitops.git which
  the cluster reads over git://. Edit under source/, then 'gitops commit'
  renders, commits, pushes and lets Argo apply it.

  Do not kubectl apply by hand into namespaces Argo manages - it will
  revert you, which is the point, but it is confusing the first time.

  Log in as user 'admin'. 08-gitops.sh copies the generated password into
  the secrets directory with everything else:

      sudo cat /srv/platform/secrets/argocd-admin-password

  If that file is missing, read it from the Secret Argo CD generated:

      kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d; echo

  Argo CD treats that Secret as disposable and expects you to set your own
  password and delete it. Do change it - then write the new one to
  /srv/platform/secrets/argocd-admin-password so the backup has it:

      argocd account update-password

  Full notes: reference/troubleshooting.md, the GitOps section.
EOF
    ;;
    tailscale) cat <<'EOF'
Tailscale - how this machine is reachable from anywhere, privately.

  Up      sudo tailscale up
  Down    sudo tailscale down
  Who     tailscale status
  IP      tailscale ip -4

  The firewall denies inbound on everything except the tailscale0
  interface, so your tailnet can reach the game servers and the forwarded
  ports and the public internet cannot.

  'tailscale serve' publishes a loopback service as a private HTTPS URL
  inside the tailnet. 'tailscale funnel' publishes it to the entire
  internet - this kit never uses funnel, and neither should you here,
  because almost nothing in the stack has authentication.

  Check which you have. These are not alternatives to each other: serve
  is what makes you reachable remotely, funnel is what makes you
  reachable publicly, and turning funnel off costs you nothing.

      tailscale serve status       expect :8447 -> 127.0.0.1:4000
      tailscale funnel status      expect nothing
      sudo tailscale funnel off    if it says otherwise

  They share one configuration, so 'funnel off' can take the serve
  mapping with it. Put it back by re-running server/06-friends.sh.

  To limit who on the tailnet can reach what, and how to narrow the
  firewall from "any port on tailscale0" to just the gateway, see the
  lock-down section of reference/remote-access.md. It has a policy you
  can paste into the admin console.

  Full notes: reference/remote-access.md
EOF
    ;;
    forwards) cat <<'EOF'
Loopback port forwards - what makes the cluster's services reachable.

  Start   sudo systemctl start platform-forward
  Stop    sudo systemctl stop platform-forward
  Status  systemctl status platform-forward

  Forwards 4000, 4100, 5678, 3000 and 8090 from the cluster onto
  127.0.0.1. Without this, n8n, Open WebUI and Argo CD are running but
  nothing on the host can reach them - which looks exactly like them being
  down, and is the first thing to check when a UI will not open.

  Postgres is deliberately not forwarded.
EOF
    ;;
    sandbox) cat <<'EOF'
Code sandbox - where n8n's Assistant runs the code it writes.

  Build    server/10-sandbox.sh --apply     safe to re-run at any time
  Check    server/10-sandbox.sh --status
  Shell    server/10-sandbox.sh --shell     a shell inside the guest
  Logs     server/10-sandbox.sh --logs      follow the containers
  Restart  server/10-sandbox.sh --restart   containers only, keep the VM
  Remove   server/10-sandbox.sh --destroy
  Start    multipass start n8n-sandbox      costs 6 GB of RAM
  Stop     multipass stop n8n-sandbox       gives it back

  Re-running --apply never builds a second sandbox. The VM is addressed
  by name, so an existing one is started rather than duplicated; the
  containers are one named compose project, so they are reconciled rather
  than added to; and a lock file stops two copies of the script running at
  once. Re-running is in fact the intended repair for a half-built
  sandbox - it picks up wherever the last attempt stopped.

  Status here means the API answered, not that the VM booted. A guest
  whose containers failed to start looks identical from the outside, so
  this row shows 'no api' for that case rather than 'running'.

  Getting inside it:

      server/10-sandbox.sh --shell      most of the time
      multipass shell n8n-sandbox       the same thing, directly
      ssh ubuntu@<ip>                   only after adding your own key

  multipass manages the guest's SSH credentials itself and does not place
  your key in it, so plain ssh does not work until you add one. There is
  rarely a reason to - the service lives in /home/ubuntu/sandbox and the
  shell above is already root-capable through sudo.

  There is no password for the ubuntu user, and nothing is hiding one.
  multipass authenticates with its own key and grants passwordless sudo,
  so no password was ever generated. If something inside the guest asks
  for one anyway, it wanted a terminal rather than a credential - run it
  as 'sudo <command>' instead. To set one for real:

      server/10-sandbox.sh --password

  This is the only part of the stack that exists to run code a model wrote
  rather than code you chose, which is why it lives in a virtual machine
  instead of a pod.

  n8n recommends Sysbox runners on a dedicated Kubernetes node pool. That
  is not available here: Sysbox supports Ubuntu up to 24.04 and this is
  26.04, k3s is not among the distributions it is tested on, and its
  installer can replace containerd with CRI-O and restart the kubelet -
  which on a single node means Postgres, LiteLLM and Argo CD all at once.

  The VM is the better answer rather than the fallback. Code runs in a
  Sysbox container inside an Ubuntu 24.04 guest, so an escape reaches a
  disposable image holding nothing but this service. It never reaches
  /srv, the secrets, the models or the GPU.

  It does NOT start at boot. At 32 GB you cannot have the sandbox, the
  cluster and a Strata pack at the same time, so starting it is a decision
  you make when you want the Assistant to write code.

  n8n finds it through environment variables, so there is normally nothing
  to type. If it asks:

      Service URL   http://sandbox.platform.svc.cluster.local:8080
      API key       sudo cat /srv/platform/secrets/sandbox-api-key

  Use that name, not the VM's address - n8n is in the cluster, and the VM
  address changes whenever the guest is rebuilt.
EOF
    ;;
    searxng) cat <<'EOF'
Web search - how the n8n Assistant reads current documentation.

  Start   r1wc start searxng        (scales the deployment to 1)
  Stop    r1wc stop searxng
  Apply   server/03-platform.sh --apply
  Test    kubectl -n platform exec deploy/n8n -- \
            wget -qO- 'http://searxng.platform.svc.cluster.local:8080/search?q=test&format=json'

  A metasearch proxy: it forwards your query to Google, Bing, DuckDuckGo
  and others, strips the identifying parts and returns the results. The
  Assistant's searches describe whatever you are building, which is why
  this is self-hosted rather than Brave Search - with Brave those queries
  would be one more account's history held by someone else.

  The honest cost: free engines rate-limit, so a long Assistant session
  can start coming back empty. If that becomes a nuisance, get a Brave
  Search key and add it to the n8n deployment as

      INSTANCE_AI_BRAVE_SEARCH_API_KEY

  with no N8N_ prefix - that is upstream's spelling, not a typo. Brave
  takes priority over SearXNG, so nothing needs removing.

  Not reachable outside the cluster, and deliberately not forwarded to
  127.0.0.1. Only n8n has any use for it, and an open search proxy is
  the kind of thing other people find and use.

  The secret key is at /srv/platform/secrets/searxng-secret. SearXNG
  refuses to start on the upstream default, so it is generated at apply
  time and substituted into the settings.
EOF
    ;;
    friends) cat <<'EOF'
Friends access - giving someone else a key to the models.

  Manage  friends
  Keys are LiteLLM keys with their own budget and rate limit, so a guest
  cannot spend the machine for everyone.

  Point them at the queue on 4100 rather than LiteLLM on 4000: under load
  the queue makes them wait and LiteLLM refuses them.

  How the traffic reaches them is a separate decision and is deliberately
  not automated here - the options and their trade-offs are in
  reference/sharing-with-friends.md. Nothing in this kit exposes a port to
  the public internet on your behalf.
EOF
    ;;
    games) cat <<'EOF'
Game servers - Minecraft and Valheim.

  Manage  games
  Start   games start minecraft   /   games start valheim
  Stop    games stop minecraft
  Status  games status

  Reachable over the tailnet, not the internet, because of the firewall.

  Both together use the whole 8Gi games quota, which costs Strata enough to
  drop it from IQ2_XS to Q2_0. Run one unless the model is paused.

  Worlds live in /srv/games and are backed up nightly.
EOF
    ;;
    secrets) cat <<'EOF'
Passwords, keys and accounts - everything that controls access here.

  Nothing below needs choosing. Every password on this machine was
  generated at install time into /srv/platform/secrets, mode 600, owned by
  root. There is no step you skipped. Read one with:

      sudo cat /srv/platform/secrets/postgres-password

  THE FILES

      postgres-password         the postgres superuser. All three
                                databases, full rights.
      n8n-db-password           n8n's own database login
      n8n-encryption-key        decrypts every credential n8n stores
      litellm-master-key        gateway admin; mints and revokes keys
      litellm-salt-key          hashes the keys LiteLLM issues
      openwebui-secret-key      signs Open WebUI session cookies
      argocd-admin-password     the Argo CD web interface
      restic-password           decrypts the backups themselves
      backup.env                offsite credentials; empty until set
      minecraft-rcon-password   Minecraft remote console
      valheim-password          the join password for the server

  TWO OF THOSE ARE IRREPLACEABLE

  n8n-encryption-key and restic-password are not passwords you can reset.
  They are keys that decrypt data you already have.

      Lose n8n-encryption-key   every credential n8n holds becomes
                                permanently unreadable. Restoring the
                                database does not help - the rows are
                                ciphertext and the key is gone.
      Lose restic-password      the backups still exist and can never be
                                read again.

  restic-password lives inside the backup it protects, so a copy on this
  machine alone is not a copy. Put both somewhere off this machine - a
  password manager is fine. Do it before you need it:

      sudo cat /srv/platform/secrets/n8n-encryption-key
      sudo cat /srv/platform/secrets/restic-password

  ACCOUNTS THAT ARE NOT PASSWORDS

  Three services do not read a file - they wait for someone to claim them,
  and the FIRST person to open the page becomes the administrator. Until
  you claim them, anyone who can reach the port can.

      n8n          http://127.0.0.1:5678   creates the owner account
      Open WebUI   http://127.0.0.1:3000   first account becomes admin
      Argo CD      http://127.0.0.1:8090   user 'admin', password in
                                           argocd-admin-password

  Both n8n and Open WebUI are bound to loopback and reachable over
  Tailscale, so the exposure is to your own devices rather than the
  internet. That is a reason not to panic, not a reason to leave them.
  Claim all three now:

      r1wc ui n8n
      r1wc ui openwebui
      r1wc ui argocd

  Argo CD's generated password should be changed once you are in - its own
  documentation treats argocd-initial-admin-secret as disposable, so do not
  leave it as the only copy:

      argocd account update-password

  Then update the stored copy so the two do not drift:

      sudo tee /srv/platform/secrets/argocd-admin-password

  WHAT IS NOT PROTECTED BY ANY OF THIS

  Strata on 8080, llama.cpp on 8081, ComfyUI on 8188 and the voice server
  on 8100 have no authentication at all. They are bound to loopback for
  exactly that reason. Only LiteLLM on 4000 and the queue on 4100 check a
  key, which is why they are the only two safe to let anyone else reach.
  See reference/ports.md.

  CHANGING A PASSWORD

  Editing the file is not enough - the running service already has the old
  one. Postgres, as the worked example:

      sudo tee /srv/platform/secrets/postgres-password
      kubectl -n platform exec -it deploy/postgres -- \
        psql -U postgres -c "ALTER USER postgres PASSWORD 'the-new-one';"
      ./server/03-platform.sh

  The script re-reads the files, rewrites the Kubernetes Secrets and
  restarts what depends on them. Re-running it never regenerates an
  existing password - secret_file only writes when the file is absent -
  so it is safe at any time.

  For a LiteLLM key belonging to someone else, revoke rather than rotate:

      friends revoke <name>
EOF
    ;;
    pause) cat <<'EOF'
Pause and resume - free the cluster's memory without losing its state.

  Pause   ai-pause --cluster        scales everything to zero
  Resume  ai-resume                 puts back exactly what was running
  Check   ai-status

  Pausing records the replica counts in /var/lib/ai-pause, which is what
  lets resume restore them rather than guess.

  That directory survives a reboot. This is the single most confusing state
  the machine can be in: you pause, shut down, boot again, and the cluster
  comes back healthy and completely empty with nothing on screen saying
  why. ops/up.sh checks for it and resumes - which is the main reason to
  run up.sh at all.

  Frees about 15 GB. The largest Strata packs need it; most do not.
EOF
    ;;
    backup) cat <<'EOF'
Backups - nightly at 03:30, and on demand.

  Now      platform-backup
  List     platform-restore local   /   platform-restore list
  Verify   platform-restore check
  Restore  platform-restore

  Covers Postgres, the n8n workflows as JSON, /srv/platform/secrets, the
  game worlds and the k8s manifests. Model files are not backed up - about
  1 006 GB and all re-downloadable.

  Two things that are worth more than the backup itself, because both are
  stored inside it and are therefore worthless there alone:

      /srv/platform/secrets/restic-password
      /srv/platform/secrets/n8n-encryption-key

  Keep both somewhere that is not this machine.

  Run 'platform-restore check' monthly and actually restore something once.
  An untested backup is a hope. Full walkthrough: reference/backups.md
EOF
    ;;
    boot) cat <<'EOF'
Whole machine - starting up and shutting down cleanly.

  Up      ops/up.sh               after every boot
  Down    ops/down.sh             before a planned shutdown
          ops/down.sh --poweroff

  up.sh is mostly verification, since most of the stack is enabled systemd
  units. It exists for three things: undoing a leftover ai-pause, waiting
  out the 30-60 seconds k3s needs before it answers, and telling you no
  model is loaded rather than picking one for you.

  down.sh snapshots Postgres first, because backups run nightly and an
  unplanned shutdown at 23:00 costs a day of agent runs and n8n history.
  It also stops things in order, since k3s killed mid-write leaves
  containerd state to repair on the next boot.

  down.sh deliberately does not pause the cluster - pause state outlives a
  reboot, so that would mean booting into an empty cluster.
EOF
    ;;
    report) cat <<'EOF'
Full status report.

  Run     status.sh
  Quick   ai-status

  status.sh walks the whole machine: disk, memory, VRAM, which models are
  downloaded, which services answer, cluster health and what is listening.
  It changes nothing and is the right thing to paste when asking for help.

  ai-status is the fast version - memory, VRAM, model ports, cluster state.
EOF
    ;;
    *) warn "No documentation for '$id'." ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Presentation.

headline() {
    local ram vram=""
    ram="$(free -g 2>/dev/null | awk '/^Mem:/ { printf "%d/%d GB", $3, $2 }')" || ram=""
    if have nvidia-smi; then
        vram="$(nvidia-smi --query-gpu=memory.used,memory.total \
                --format=csv,noheader,nounits 2>/dev/null | head -n1 \
                | awk -F', ' '{ printf "  VRAM %d/%d GB", $1/1024, $2/1024 }')" || vram=""
    fi
    printf '%s  R1 workstation - operations console%s     RAM %s%s\n' \
           "$_C_BOLD" "$_C_RESET" "${ram:-?}" "$vram"
}

# Fills MENU_IDS with the ids in display order, so the number the user types
# maps to the same row they read.
MENU_IDS=()
draw_menu() {
    local id group label kind port ui last="" n=0 st colour tail

    MENU_IDS=()
    KUBE_OK=""          # re-ask on every redraw; 'r' is how you refresh it
    printf '\n'
    headline
    while IFS=$'\t' read -r id group label kind port ui; do
        [[ -n "$id" ]] || continue
        if [[ "$group" != "$last" ]]; then
            printf '\n  %s%s%s\n' "$_C_CYAN" "$(group_title "$group")" "$_C_RESET"
            last="$group"
        fi
        n=$(( n + 1 ))
        MENU_IDS+=("$id")
        st="$(item_status "$id")"
        case "$st" in
            running)  colour="$_C_GREEN" ;;
            PAUSED|no\ api) colour="$_C_YELLOW" ;;
            *)       colour="$_C_RESET" ;;
        esac
        # Built rather than padded, so rows without a port or a [gpu] tag do
        # not trail invisible spaces.
        tail=""
        [[ "$port" != "-" ]] && tail=":$port"
        [[ "$kind" == gpu ]] && tail="${tail}${tail:+  }[gpu]"
        printf '   %2d  %-30s %s%-9s%s %s\n' \
               "$n" "$label" "$colour" "$st" "$_C_RESET" "$tail"
    done <<<"$ITEMS"

    printf '\n  %sNumber%s to act on one   %sr%s refresh   %sq%s quit\n' \
           "$_C_BOLD" "$_C_RESET" "$_C_BOLD" "$_C_RESET" "$_C_BOLD" "$_C_RESET"
}

action_menu() {
    local id="$1" label kind choice
    label="$(awk -F'\t' -v i="$id" '$1 == i { print $3 }' <<<"$ITEMS")"
    kind="$(awk -F'\t' -v i="$id" '$1 == i { print $4 }' <<<"$ITEMS")"

    while :; do
        printf '\n  %s%s%s   -   currently %s\n' \
               "$_C_BOLD" "$label" "$_C_RESET" "$(item_status "$id")"
        if [[ "$kind" == gpu ]]; then
            printf '  %s[gpu]%s starting this stops whatever else holds the card first.\n' \
                   "$_C_YELLOW" "$_C_RESET"
        fi
        printf '\n    d  documentation - what it is and how to operate it\n'
        printf '    s  start\n'
        printf '    x  stop\n'
        printf '    o  open the interface\n'
        printf '    b  back\n\n'
        read -r -p "  > " choice || return 0
        case "$choice" in
            d) item_docs "$id" ;;
            s) item_start "$id" ;;
            x) item_stop "$id" ;;
            o) item_ui "$id" ;;
            b|q|"") return 0 ;;
            *) warn "Not an option." ;;
        esac
    done
}

menu_loop() {
    local choice
    while :; do
        draw_menu
        read -r -p "  > " choice || return 0
        case "$choice" in
            q|Q) return 0 ;;
            r|R|"") continue ;;
            *[!0-9]*) warn "Type a number, r or q." ;;
            *)
                if (( choice >= 1 && choice <= ${#MENU_IDS[@]} )); then
                    action_menu "${MENU_IDS[$(( choice - 1 ))]}"
                else
                    warn "There is no $choice."
                fi ;;
        esac
    done
}

# ---------------------------------------------------------------------------
valid_id() { awk -F'\t' -v i="$1" '$1 == i { f = 1 } END { exit !f }' <<<"$ITEMS"; }

install_self() {
    sudo ln -sfn "$HERE/r1wc.sh" /usr/local/bin/r1wc
    ok "Installed. Type 'r1wc' from anywhere."
    info "It is a symlink to $HERE/r1wc.sh, so 'git pull' updates it."
}

case "${1:-}" in
    "")        menu_loop ;;
    list)      draw_menu ;;
    status)
        while IFS=$'\t' read -r id group label kind port ui; do
            [[ -n "$id" ]] || continue
            printf '%-12s %-32s %s\n' "$id" "$label" "$(item_status "$id")"
        done <<<"$ITEMS" ;;
    docs)      valid_id "${2:-}" || die "Unknown item: ${2:-<none>}. Try 'r1wc list'."
               item_docs "$2" ;;
    start)     valid_id "${2:-}" || die "Unknown item: ${2:-<none>}. Try 'r1wc list'."
               item_start "$2" "${3:-}" ;;
    stop)      valid_id "${2:-}" || die "Unknown item: ${2:-<none>}. Try 'r1wc list'."
               item_stop "$2" ;;
    ui)        valid_id "${2:-}" || die "Unknown item: ${2:-<none>}. Try 'r1wc list'."
               item_ui "$2" ;;
    --install) install_self ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)         die "Unknown command: $1 (try --help)" ;;
esac
