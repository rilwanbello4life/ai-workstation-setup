#!/usr/bin/env bash
# Phase 8 - run the whole Ubuntu setup in order.
#
# Each step is a standalone, re-runnable script. This wrapper just sequences
# them and stops at the reboot the NVIDIA driver needs.
#
#   ./setup-all.sh            run every remaining step, prompting before each
#   ./setup-all.sh -y         no prompts, and no questions inside the steps
#   ./setup-all.sh 04 05      run only those steps
#
#   --tier <spec>   which Strata packs to install: a (default) .. abcdef, or
#                   "all" for the whole 998 GB catalogue
#   --no-models     skip the ComfyUI, voice and GGUF downloads
#
# The unattended overnight run, which downloads everything and asks nothing:
#
#   ./setup-all.sh -y --tier all

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO=no
TIER=a
WANT_MODELS=yes

args=()
while (( $# )); do
    case "$1" in
        -y|--yes)    AUTO=yes ;;
        --tier)      TIER="${2:?--tier needs a value}"; shift ;;
        --tier=*)    TIER="${1#*=}" ;;
        --no-models) WANT_MODELS=no ;;
        -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           args+=("$1") ;;
    esac
    shift
done

# -y has to reach the prompts inside the phase scripts, not just this
# wrapper's own "run this step?" question, or an unattended run still stops
# at the governor prompt in 02 and the per-model prompt in 07.
if [[ "$AUTO" == yes ]]; then
    export AI_ASSUME_YES=1
fi

STEPS=(
    "01-nvidia.sh:NVIDIA open kernel modules (reboot required after)"
    "02-tune-linux.sh:Performance tuning: memlock, swappiness, governor"
    "03-python-cuda.sh:Python toolchain and PyTorch sm_120 check"
    "04-llamacpp.sh:Build llama.cpp with CUDA"
    "05-comfyui.sh:ComfyUI for image and video"
    "06-voice.sh:Whisper and Kokoro voice server"
    "07-strata.sh:Strata model packs - tier ${TIER}"
    "08-remote-access.sh:Tailscale and Open WebUI (optional)"
    "09-gaming.sh:Steam, Proton, GameMode and MangoHud (optional)"
    # Last on purpose: it is the longest step by hours and the only one that
    # never asks anything, so every prompt is answered before it starts and
    # you can leave the machine to it.
    "10-models.sh:ComfyUI, voice and GGUF models (~100 GB)"
)

section "Plan"
for entry in "${STEPS[@]}"; do
    script="${entry%%:*}"; desc="${entry#*:}"
    num="${script%%-*}"
    if (( ${#args[@]} )) && [[ ! " ${args[*]} " == *" $num "* ]]; then
        printf '  %-22s %s (skipped)\n' "$script" "$desc"
    else
        printf '  %-22s %s\n' "$script" "$desc"
    fi
done
echo

# Authenticate sudo once, up front, and hold the timestamp for the whole run.
# Without this the password prompt lands in the middle of the night, after a
# long compile or download has let the 15-minute cache expire.
if [[ "$AUTO" == yes ]]; then
    section "sudo"
    sudo_keepalive
    ok "Authenticated; the timestamp will be refreshed until this run ends."
fi

# If the driver is already working, there is no reason to redo step 1 and the
# reboot that follows it.
driver_ready=no
if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    driver_ready=yes
    ok "NVIDIA driver already working - step 01 will be skipped."
fi

for entry in "${STEPS[@]}"; do
    script="${entry%%:*}"; desc="${entry#*:}"
    num="${script%%-*}"

    if (( ${#args[@]} )) && [[ ! " ${args[*]} " == *" $num "* ]]; then
        continue
    fi
    if [[ "$script" == "01-nvidia.sh" && "$driver_ready" == yes ]] && (( ${#args[@]} == 0 )); then
        continue
    fi
    if [[ "$script" == "10-models.sh" && "$WANT_MODELS" != yes ]]; then
        warn "Skipped: --no-models."
        continue
    fi
    # Remote access signs you into a Tailscale account in a browser, so it is
    # never run unattended. Ask for it explicitly:  ./setup-all.sh 08
    if [[ "$script" == "08-remote-access.sh" && "$AUTO" == yes ]] && (( ${#args[@]} == 0 )); then
        warn "Skipped in --yes mode; run it on its own with: ./setup-all.sh 08"
        continue
    fi
    # Gaming is optional and adds several GB of 32-bit libraries. Not part of
    # an unattended build:  ./setup-all.sh 09
    if [[ "$script" == "09-gaming.sh" && "$AUTO" == yes ]] && (( ${#args[@]} == 0 )); then
        warn "Skipped in --yes mode; run it on its own with: ./setup-all.sh 09"
        continue
    fi

    section "$script - $desc"

    if [[ "$AUTO" != yes ]]; then
        if ! confirm "Run $script?"; then
            warn "Skipped."
            continue
        fi
    fi

    # 07 prints a plan and downloads nothing unless asked, because even the
    # default tier is 150 GB. In the orchestrated run we do want the download.
    step_args=()
    if [[ "$script" == "07-strata.sh" ]]; then
        step_args+=(--tier "$TIER" --install)
        if [[ "$AUTO" == yes ]]; then step_args+=(--yes); fi
    fi

    chmod +x "$HERE/$script"
    if "$HERE/$script" ${step_args[@]+"${step_args[@]}"}; then
        ok "$script finished."
    else
        err "$script failed (exit $?)."
        warn "Fix the problem and re-run just this step:  ./$script"
        exit 1
    fi

    if [[ "$script" == "01-nvidia.sh" ]]; then
        echo
        warn "Reboot now, complete the MOK enrollment if prompted, then run:"
        warn "    ./setup-all.sh"
        exit 0
    fi
done

section "Done"
cat <<EOF
  Services and ports:

    Strata        http://127.0.0.1:8080/v1   OpenAI + Anthropic compatible
    llama.cpp     http://127.0.0.1:8081/v1   any GGUF from $AI_ROOT/gguf
    voice         http://127.0.0.1:8100/v1   transcription and speech
    ComfyUI       http://127.0.0.1:8188      image and video

  Launchers in $APPS:
    start-llama-server.sh   start-comfyui.sh   start-voice.sh

  Switching Strata models (one serves at a time):

    strata launch --list-presets
    strata launch --preset coder-iq1_m
    strata launch --stop

  More models, and what each memory tier reaches:
    ./07-strata.sh --tier abc      see what else fits today
    reference/strata-models.md     the full catalogue

  Only one heavy workload at a time on 16 GB of VRAM. Stop Strata before
  running video generation, and vice versa.

  To reach any of this from a phone or laptop:  ./08-remote-access.sh
EOF
