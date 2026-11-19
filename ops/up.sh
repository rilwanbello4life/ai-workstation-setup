#!/usr/bin/env bash
# Bring the machine back to a working state after a reboot.
#
#   ./up.sh                        verify everything, resume a leftover pause
#   ./up.sh --model coder-iq1_m    and load that Strata preset
#   ./up.sh --wait 180             allow longer for a slow first boot
#
# Most of what this touches is a systemd unit that is already enabled, so the
# script is mostly verification. Three things genuinely need doing after a
# boot, and they are the reason it exists:
#
#   1. A leftover ai-pause. The recorded replica counts live in
#      /var/lib/ai-pause and survive a reboot, so if you paused before
#      shutting down, k3s comes back with every workload scaled to zero and
#      nothing on screen says why. This is the single most confusing state
#      the machine can boot into.
#   2. Waiting for the API. k3s needs 30-60 seconds after boot before it
#      answers, and anything that asks sooner fails in a way that reads as
#      broken rather than early.
#   3. The model servers. Strata, llama.cpp and ComfyUI have no units on
#      purpose: 16 GB of VRAM holds one of them at a time, so which one runs
#      is a decision, not a default. This script will not pick for you.
#
# Safe to run at any time, as often as you like. It starts nothing that is
# already running.
#
# Background: reference/filesystem-map.md, reference/ports.md

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../server" && pwd)/common.sh"
require_not_root

MODEL=""
WAIT_SECS=120

while (( $# )); do
    case "$1" in
        --model)   MODEL="${2:?--model needs a preset name}"; shift 2 ;;
        --model=*) MODEL="${1#*=}"; shift ;;
        --wait)    WAIT_SECS="${2:?--wait needs seconds}"; shift 2 ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ "$(uname -s)" == "Linux" ]] || die "This is for the Ubuntu side, not $(uname -s)."

problems=0

# ---------------------------------------------------------------------------
section "Host services"

# These are all 'enable --now' units from phases 8 and 12-21, so after a clean
# boot they should already be active. Starting one here means something went
# wrong earlier, which is worth saying rather than silently fixing.
check_unit() {
    local unit="$1" what="$2"
    systemctl list-unit-files "$unit" >/dev/null 2>&1 || return 0
    systemctl cat "$unit" >/dev/null 2>&1 || return 0

    if systemctl is-active --quiet "$unit"; then
        ok "$what"
    elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        warn "$what is enabled but not running - starting it."
        sudo systemctl start "$unit" && ok "$what started." || {
            err "$what failed to start: systemctl status $unit"
            problems=$(( problems + 1 ))
        }
    else
        info "$what is installed but not enabled; leaving it alone."
    fi
}

check_unit k3s.service                 "k3s"
check_unit ai-model-bridge.service     "host-model bridge"
check_unit platform-forward.service    "loopback port forwarding"
check_unit gpu-probe.service           "GPU probe"
check_unit gitops-git-daemon.service   "GitOps git daemon"
check_unit gitops-watch.path           "GitOps file watch"
# Type=oneshot but RemainAfterExit=yes, so is-active is meaningful here.
check_unit cpu-performance.service     "CPU governor"
check_unit nvidia-persistenced.service "NVIDIA persistence daemon"

for unit in voice-server.service open-webui.service; do
    if systemctl --user list-unit-files "$unit" >/dev/null 2>&1 && \
       systemctl --user cat "$unit" >/dev/null 2>&1; then
        if systemctl --user is-active --quiet "$unit"; then
            ok "${unit%.service} (user unit)"
        else
            warn "${unit%.service} not running - starting it."
            systemctl --user start "$unit" 2>/dev/null \
                && ok "${unit%.service} started." \
                || warn "Could not start ${unit%.service}: systemctl --user status $unit"
        fi
    fi
done

# ---------------------------------------------------------------------------
if ! have kubectl || ! systemctl list-unit-files k3s.service >/dev/null 2>&1; then
    section "Done"
    info "No cluster on this machine - phases 12-21 have not been run."
    info "Host model servers are started by hand; see ops/switch.sh."
    exit 0
fi

section "Cluster"

info "Waiting up to ${WAIT_SECS}s for the Kubernetes API."
api_up=no
for (( i = 0; i < WAIT_SECS; i += 3 )); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then api_up=yes; break; fi
    sleep 3
done

if [[ "$api_up" != yes ]]; then
    err "The API did not answer within ${WAIT_SECS}s."
    err "  systemctl status k3s"
    err "  sudo journalctl -u k3s -n 50 --no-pager"
    exit 1
fi
ok "API is answering."

kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null 2>&1 \
    && ok "Node is Ready." \
    || warn "Node is not Ready yet; workloads may stay Pending."

# ---------------------------------------------------------------------------
section "Paused workloads"

# Test the symptom, not the state file. ai-resume does not delete
# /var/lib/ai-pause/*.replicas when it runs, so those files are still there
# long after a pause has been undone - keying off them would print a scary
# warning on every boot forever, which is the fastest way to teach someone to
# ignore it. A deployment whose desired replica count is zero is the thing
# that actually makes the machine look broken, and it catches a hand-scaled
# workload too.
zeroed=0
for ns in "$K8S_NS" "$GAMES_NS"; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
    n="$(kubectl -n "$ns" get deploy -o \
        'jsonpath={range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
        | grep -cx 0 || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    zeroed=$(( zeroed + n ))
done

if (( zeroed )); then
    warn "$zeroed deployment(s) are scaled to zero - this looks like a pause"
    warn "that was still in effect when the machine went down."
    if have ai-resume; then
        info "Running ai-resume to restore the recorded replica counts."
        ai-resume || warn "ai-resume reported a problem."
    else
        warn "ai-resume is missing - run server/01-server-base.sh --apply."
    fi
else
    ok "Nothing was left paused."
fi

# ---------------------------------------------------------------------------
section "Platform workloads"

for d in postgres litellm n8n open-webui; do
    kubectl -n "$K8S_NS" get deploy "$d" >/dev/null 2>&1 || continue
    if kubectl -n "$K8S_NS" wait --for=condition=Available \
           "deploy/$d" --timeout=90s >/dev/null 2>&1; then
        ok "$d"
    else
        err "$d is not available."
        err "  kubectl -n $K8S_NS describe pod -l app=$d"
        problems=$(( problems + 1 ))
    fi
done

kubectl -n "$K8S_NS" get deploy gpu-queue >/dev/null 2>&1 && {
    kubectl -n "$K8S_NS" wait --for=condition=Available deploy/gpu-queue \
        --timeout=60s >/dev/null 2>&1 && ok "gpu-queue" || warn "gpu-queue is not available."
}

# ---------------------------------------------------------------------------
section "Models"

# Nothing above holds the GPU. This is where it gets decided.
if [[ -n "$MODEL" ]]; then
    have strata || die "strata is not installed. Run ubuntu/07-strata.sh --install."
    info "Launching Strata preset '$MODEL'."
    info "Expect the machine to be sluggish for 1-3 minutes while it loads."
    if strata launch --preset "$MODEL" --yes --no-tui; then
        ok "Strata is serving on http://127.0.0.1:8080/v1"
    else
        err "Strata failed to launch. Check the preset name:"
        err "  strata launch --list-presets"
        problems=$(( problems + 1 ))
    fi
elif have strata && strata launch --status >/dev/null 2>&1; then
    ok "Strata is already serving."
else
    info "No model server is running. One heavy workload at a time:"
    info "    ./ops/switch.sh strata <preset>     the big MoE packs"
    info "    ./ops/switch.sh llamacpp <file>     a small fast GGUF"
    info "    ./ops/switch.sh comfyui             image and video"
fi

# ---------------------------------------------------------------------------
section "Summary"

if (( problems )); then
    err "$problems component(s) need attention. Full report: ./status.sh"
    exit 1
fi

ok "Everything that should be running is running."
cat <<EOF

  LiteLLM gateway   http://127.0.0.1:4000/v1
  GPU queue         http://127.0.0.1:4100/v1
  n8n               http://127.0.0.1:5678
  Open WebUI        http://127.0.0.1:3000
  Voice             http://127.0.0.1:8100/v1

  ai-status         memory, VRAM and services at a glance
  ./status.sh       the full phase-by-phase report
EOF
