#!/usr/bin/env bash
# Switch the one heavy workload the GPU can hold.
#
#   ./switch.sh strata <preset>     a Strata MoE pack on 8080
#   ./switch.sh llamacpp <file>     a GGUF on llama.cpp, 8081
#   ./switch.sh comfyui             image and video, 8188
#   ./switch.sh none                stop all three, free everything
#   ./switch.sh status              what holds the GPU right now
#
# 16 GB of VRAM holds one of these at a time, and a Strata pack also pins
# 25-62 GB of system RAM. Starting a second one does not fail cleanly - it
# either refuses deep inside a library or makes the desktop unusable while
# the kernel pages - so the useful operation is "stop whatever is running,
# then start this", which is what this does.
#
# --pause-cluster frees the platform's ~15 GB as well, which the largest
# packs need. ops/up.sh or 'ai-resume' brings it back.
#
# Background: reference/ports.md ("What can run at the same time")

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../server" && pwd)/common.sh"
require_not_root

PAUSE_CLUSTER=no
args=()
for a in "$@"; do
    case "$a" in
        --pause-cluster) PAUSE_CLUSTER=yes ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) args+=("$a") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

[[ "$(uname -s)" == "Linux" ]] || die "This is for the Ubuntu side, not $(uname -s)."

TARGET="${1:-status}"
ARG="${2:-}"

# ---------------------------------------------------------------------------
gpu_holders() {
    # Processes with the card open, by name. nvidia-smi is authoritative here;
    # pgrep would miss a pack that Strata launched under another name.
    have nvidia-smi || return 0
    nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null
}

stop_everything() {
    local stopped=0

    if have strata && strata launch --status >/dev/null 2>&1; then
        info "Stopping Strata."
        strata launch --stop >/dev/null 2>&1 || true
        stopped=$(( stopped + 1 ))
    fi

    if pgrep -f 'llama-server' >/dev/null 2>&1; then
        info "Stopping llama.cpp."
        pkill -f 'llama-server' 2>/dev/null || true
        stopped=$(( stopped + 1 ))
    fi

    if pgrep -f 'ComfyUI/main.py' >/dev/null 2>&1; then
        info "Stopping ComfyUI."
        pkill -f 'ComfyUI/main.py' 2>/dev/null || true
        stopped=$(( stopped + 1 ))
    fi

    # Give the driver a moment to actually release the memory; starting the
    # next workload against a card that is still freeing looks like an OOM.
    (( stopped )) && sleep 3
    ok "Stopped $stopped model server(s)."
}

show_status() {
    section "What holds the GPU"
    # The '|| true' matters: without it, set -e kills the script here on any
    # machine where nvidia-smi exists but fails, and the only thing on screen
    # is the section header.
    local apps; apps="$(gpu_holders || true)"
    if [[ -n "$apps" ]]; then
        printf '%s\n' "$apps" | sed 's/^/    /'
    else
        info "Nothing is using the GPU."
    fi

    if have strata; then
        strata launch --status 2>/dev/null | sed 's/^/    /' || true
    fi

    echo
    if have nvidia-smi; then
        nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader \
            2>/dev/null | sed 's/^/    VRAM: /' || true
    fi
    free -g 2>/dev/null | awk 'NR<=2 {print "    " $0}' || true
}

# ---------------------------------------------------------------------------
case "$TARGET" in
status)
    show_status
    ;;

none)
    section "Stopping everything"
    stop_everything
    show_status
    ;;

strata)
    [[ -n "$ARG" ]] || {
        have strata && strata launch --list-presets 2>/dev/null | sed 's/^/    /'
        die "Which preset? ./switch.sh strata <preset>"
    }
    have strata || die "strata is not installed. Run ubuntu/07-strata.sh --install."

    section "Switching to Strata: $ARG"
    stop_everything

    if [[ "$PAUSE_CLUSTER" == yes ]]; then
        have ai-pause || die "ai-pause is missing - run server/01-server-base.sh --apply."
        info "Pausing the cluster to free ~15 GB."
        ai-pause --cluster || ai-pause || true
    fi

    # Set here as well as in the generated shell environment, because this
    # is the one that cannot go stale. The shell file is only rewritten when
    # a setup script runs, so a machine installed before that value existed
    # keeps launching Strata without it - and the symptom appears three hops
    # away, as a provider error in n8n or Open WebUI rather than as Strata
    # declining a Host header. Exported, not assumed: Strata reads it once,
    # at startup, so a value added to the shell later does nothing until the
    # pack is restarted.
    export STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-localhost,127.0.0.1,strata.platform.svc.cluster.local,strata.platform.svc,strata,10.42.0.1}"

    info "Loading. The desktop will be sluggish for 1-3 minutes."
    strata launch --preset "$ARG" --yes --no-tui \
        || die "Strata failed to launch. Try: strata launch --preset $ARG"
    ok "Serving on http://127.0.0.1:8080/v1"
    ;;

llamacpp)
    launcher="$APPS/start-llama-server.sh"
    [[ -x "$launcher" ]] || die "Not found: $launcher. Run ubuntu/04-llamacpp.sh."
    [[ -n "$ARG" ]] || {
        info "Available GGUFs in $AI_ROOT/gguf:"
        ls -1 "$AI_ROOT/gguf" 2>/dev/null | sed 's/^/    /' || info "    (none - run ubuntu/10-models.sh text)"
        die "Which model? ./switch.sh llamacpp <file.gguf>"
    }

    section "Switching to llama.cpp: $ARG"
    stop_everything
    info "Starting in the background; log: /tmp/llama-server.log"
    nohup "$launcher" "$ARG" >/tmp/llama-server.log 2>&1 &
    sleep 5
    if pgrep -f 'llama-server' >/dev/null 2>&1; then
        ok "Serving on http://127.0.0.1:8081/v1"
    else
        err "It did not stay up. Last lines:"
        tail -n 20 /tmp/llama-server.log | sed 's/^/    /'
        exit 1
    fi
    ;;

comfyui)
    launcher="$APPS/start-comfyui.sh"
    [[ -x "$launcher" ]] || die "Not found: $launcher. Run ubuntu/05-comfyui.sh."

    section "Switching to ComfyUI"
    stop_everything
    info "Starting in the background; log: /tmp/comfyui.log"
    nohup "$launcher" >/tmp/comfyui.log 2>&1 &
    sleep 5
    if pgrep -f 'ComfyUI/main.py' >/dev/null 2>&1; then
        ok "Web UI on http://127.0.0.1:8188"
    else
        err "It did not stay up. Last lines:"
        tail -n 20 /tmp/comfyui.log | sed 's/^/    /'
        exit 1
    fi
    ;;

*)
    die "Unknown target '$TARGET'. One of: strata, llamacpp, comfyui, none, status."
    ;;
esac
