#!/usr/bin/env bash
# Replace the workload of the kind you are starting, not everything else.
#
#   ./switch.sh strata <preset>     a Strata MoE pack on 8080
#   ./switch.sh llamacpp <file>     a GGUF on llama.cpp, 8081
#   ./switch.sh comfyui             image and video, 8188
#   ./switch.sh stop <kind>         one workload down, the rest stay up
#   ./switch.sh none                stop all three, free everything
#   ./switch.sh status              what holds the GPU right now
#
# A target takes over its own kind and leaves the others up: a Strata swap
# stops the pack already serving, a llama.cpp swap stops the server that
# already has 8081, ComfyUI replaces its own process. They do coexist now,
# and the setting that makes that real is Strata keeping --vram-reserve-mib
# of the card free for the others (ubuntu/common.sh) - two GB holds a
# quantised image model or a small GGUF, not a 12 GB one. 16 GB still has
# to hold what you ask of it, and a start that is short does not refuse
# cleanly: it dies deep in a CUDA library, or the desktop locks up while
# the kernel pages. So the question is never "does the launcher allow it",
# it is "does the card hold it" - and 'status' answers that.
#
# Room is what Strata's --vram-reserve-mib leaves, and it is overridable per
# start - STRATA_VRAM_RESERVE_MIB=8192 ./switch.sh strata <preset> hands back
# 8 GiB instead of 2 - but a room big enough for a 9 GB GGUF is not a room
# this card has: with that GGUF up, what is left is under Strata's own floor,
# so the 14B checker the agent layer wants (reference/agent-orchestration.md)
# runs beside a pack on a 32 GB card, not here. Two answers on this box mean
# a smaller GGUF in the room you left, or the 14B while no pack is resident.
# switch.sh status is what shows the room; a start that is short of it dies
# deep in a CUDA library rather than saying so.
#
# --stop-others stops all three first, for when the card really is full.
# --pause-cluster frees the platform's ~15 GB of RAM as well, which the
# largest packs need. ops/up.sh or 'ai-resume' brings that back.
#
# Background: reference/ports.md ("What can run at the same time")

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../server" && pwd)/common.sh"
require_not_root

PAUSE_CLUSTER=no
STOP_OTHERS=no
args=()
for a in "$@"; do
    case "$a" in
        --pause-cluster) PAUSE_CLUSTER=yes ;;
        --stop-others) STOP_OTHERS=yes ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# One function per workload, so a target can name the one it replaces. STOPPED
# is a global rather than a local, because the count is what the caller reports
# after stopping - and stopping is what three of the four branches do.
STOPPED=0

stop_strata() {
    have strata && strata launch --status >/dev/null 2>&1 || return 0
    info "Stopping Strata."
    strata launch --stop >/dev/null 2>&1 || true
    STOPPED=$(( STOPPED + 1 ))
}

stop_llamacpp() {
    pgrep -f 'llama-server' >/dev/null 2>&1 || return 0
    info "Stopping llama.cpp."
    pkill -f 'llama-server' 2>/dev/null || true
    STOPPED=$(( STOPPED + 1 ))
}

stop_comfyui() {
    pgrep -f 'ComfyUI/main.py' >/dev/null 2>&1 || return 0
    info "Stopping ComfyUI."
    pkill -f 'ComfyUI/main.py' 2>/dev/null || true
    STOPPED=$(( STOPPED + 1 ))
}

# One name for one workload, so a caller can say which kind it means without
# knowing which function that kind is. 'all' is what none and --stop-others use.
stop_one() {
    case "$1" in
        strata)   stop_strata ;;
        llamacpp) stop_llamacpp ;;
        comfyui)  stop_comfyui ;;
        all)      stop_strata; stop_llamacpp; stop_comfyui ;;
        *)        return 1 ;;
    esac
}

# What a start stops: the workload of the same kind, unless --stop-others says
# otherwise. Stopping the same kind is never optional. A Strata pack loaded on
# top of the pack already serving keeps both resident, and the second one's KV
# pool has nowhere to go; a llama-server beside the one on 8081 answers from
# the wrong port half the time. What is different is the *other* kinds - they
# stay up, and the card, not this script, decides whether they fit.
stop_for_target() {
    STOPPED=0
    if [[ "$STOP_OTHERS" == yes ]]; then
        stop_one all
    else
        stop_one "$TARGET" || true
    fi
    # Give the driver a moment to actually release the memory; starting the
    # next workload against a card that is still freeing looks like an OOM.
    (( STOPPED )) && sleep 3
    if [[ "$STOP_OTHERS" == yes ]]; then
        ok "Stopped $STOPPED model server(s); the card is free."
    else
        ok "Stopped $STOPPED model server(s). The others are left running."
    fi
}

stop_everything() {
    STOPPED=0
    stop_one all
    (( STOPPED )) && sleep 3
    ok "Stopped $STOPPED model server(s)."
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

stop)
    [[ -n "$ARG" ]] || die "Which kind? ./switch.sh stop <strata|llamacpp|comfyui>"
    section "Stopping $ARG"
    STOPPED=0
    stop_one "$ARG" || die "Unknown kind '$ARG'. One of: strata, llamacpp, comfyui."
    (( STOPPED )) && sleep 3
    if (( STOPPED )); then
        ok "Stopped $STOPPED model server(s). The others are left running."
    else
        info "Nothing of that kind was running."
    fi
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
    stop_for_target

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

    # The engine settings for this card, applied at the start rather than only
    # baked into the preset. ubuntu/07-strata.sh writes them into the presets it
    # installs, but a preset that predates this change has never seen them, and
    # re-stating the same values costs nothing. A --set given on the command
    # line still wins over both, which is user_args.py's merge rule: the
    # person's value sits over whatever was generated.
    strata_args_for "$ARG"
    info "Loading. The desktop will be sluggish for 1-3 minutes."
    strata launch --preset "$ARG" --yes --no-tui "${STRATA_ARGS[@]}" \
        || die "Strata failed to launch. Try: strata launch --preset $ARG"
    ok "Serving on http://127.0.0.1:8080/v1"
    # Saying what stayed up, because it is the card's answer rather than this
    # script's: a workload that kept its process is only useful if the 16 GB
    # still holds it, and 'status' is the one command that shows the cost.
    if gpu_holders | grep -qiE 'llama-server|ComfyUI'; then
        info "Something else still holds the card. ./switch.sh status shows what each of them costs."
    fi
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
    stop_for_target
    info "Starting in the background; log: /tmp/llama-server.log"
    nohup "$launcher" "$ARG" >/tmp/llama-server.log 2>&1 &
    sleep 5
    if pgrep -f 'llama-server' >/dev/null 2>&1; then
        ok "Serving on http://127.0.0.1:8081/v1"
    else
        err "It did not stay up. Last lines:"
        tail -n 20 /tmp/llama-server.log | sed 's/^/    /'
        err "A card that is already full fails inside the loader, which is what these lines are."
        err "To free everything first: ./switch.sh llamacpp \"$ARG\" --stop-others"
        exit 1
    fi
    ;;

comfyui)
    launcher="$APPS/start-comfyui.sh"
    [[ -x "$launcher" ]] || die "Not found: $launcher. Run ubuntu/05-comfyui.sh."

    section "Switching to ComfyUI"
    stop_for_target
    info "Starting in the background; log: /tmp/comfyui.log"
    nohup "$launcher" >/tmp/comfyui.log 2>&1 &
    sleep 5
    if pgrep -f 'ComfyUI/main.py' >/dev/null 2>&1; then
        ok "Web UI on http://127.0.0.1:8188"
    else
        err "It did not stay up. Last lines:"
        tail -n 20 /tmp/comfyui.log | sed 's/^/    /'
        err "A card that is already full fails inside the loader, which is what these lines are."
        err "To free everything first: ./switch.sh comfyui --stop-others"
        exit 1
    fi
    ;;

*)
    die "Unknown target '$TARGET'. One of: strata, llamacpp, comfyui, stop <kind>, none, status."
    ;;
esac
