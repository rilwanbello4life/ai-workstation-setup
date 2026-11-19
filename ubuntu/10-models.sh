#!/usr/bin/env bash
# Phase 8.9 - download the models that are not Strata packs.
#
# Strata fetches its own packs in 07-strata.sh. Everything else - the ComfyUI
# image and video models, the voice models and the default GGUF chat model -
# comes from ../models/manifest.tsv, and nothing in the setup sequence used to
# fetch it. The result was an installed stack with empty model directories:
# ComfyUI with no checkpoints, and llama.cpp serving nothing while LiteLLM's
# 'local' and 'checker' aliases pointed at it.
#
#   ./10-models.sh              every group (image, video, voice, text)
#   ./10-models.sh image voice  only those groups
#   ./10-models.sh --status     what is downloaded and what is left
#
# Re-running is cheap, and after the first run it is close to free: every
# confirmed download is recorded in $AI_ROOT/.downloads.tsv and a recorded
# entry is not handed to the Hugging Face CLI at all. That matters because
# the CLI contacts the hub for each entry even when the file is already
# cached, so a re-run of a finished manifest used to spend a long time on
# the network to do nothing. Nothing here prompts.
#
# Set SKIP_FAILED=yes to leave previously-failed entries alone instead of
# retrying them.
#
# Background: models/MANIFEST.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOADER="$KIT_ROOT/models/download-models.sh"

[[ -f "$DOWNLOADER" ]] || die "Cannot find $DOWNLOADER - run this from inside the kit."

# Not GROUPS: that is a special bash variable holding the caller's Unix group
# IDs, and assigning to it is silently ignored. Using it here made the loop
# below iterate over group numbers like 1000 and 27, which match no row in
# manifest.tsv, so the script reported success having downloaded nothing.
WANT_GROUPS=()
SHOW_STATUS=no
for arg in "$@"; do
    case "$arg" in
        --status) SHOW_STATUS=yes ;;
        *)        WANT_GROUPS+=("$arg") ;;
    esac
done
(( ${#WANT_GROUPS[@]} )) || WANT_GROUPS=(all)

if [[ "$SHOW_STATUS" == yes ]]; then
    ledger_init
    for g in "${WANT_GROUPS[@]}"; do
        awk -F'\t' -v g="$g" \
            '$1 !~ /^#/ && NF >= 4 && (g == "all" || $1 == g) {
                 label = ($3 == "*") ? $2 : $3
                 sub(/.*\//, "", label)
                 printf "%s::%s\t%-6s %s\n", $2, $3, $1, label
             }' "$KIT_ROOT/models/manifest.tsv" \
            | ledger_progress file "Manifest - group '$g'"
    done
    info "Ledger: $DOWNLOAD_LEDGER"
    exit 0
fi

# ---------------------------------------------------------------------------
section "Prerequisites"

ensure_ai_dirs

# The downloader needs the Hugging Face CLI. Installing it here rather than
# failing keeps an unattended run going; 03-python-cuda.sh may not have run.
#
# Both installers put the binary in ~/.local/bin, which is not on PATH in a
# non-login shell, so put it there before looking. Without this the install
# reports success and the downloader then exits with "Hugging Face CLI not
# found", which looks like the download simply did nothing.
export PATH="$HOME/.local/bin:$PATH"

if ! have hf && ! have huggingface-cli; then
    if have uv; then
        info "Installing huggingface_hub with uv."
        uv tool install "huggingface_hub[cli]" >/dev/null 2>&1 || true
    else
        info "Installing huggingface_hub with pip."
        # Ubuntu marks the system Python externally managed, so a plain
        # --user install is refused; the override is correct here because
        # the target is ~/.local, not site-packages.
        python3 -m pip install --user --quiet --break-system-packages \
            "huggingface_hub[cli]" >/dev/null 2>&1 || true
    fi
    hash -r
fi

if have hf || have huggingface-cli; then
    ok "Hugging Face CLI present: $(command -v hf || command -v huggingface-cli)"
else
    err "The Hugging Face CLI is not installed and could not be installed here."
    err "Install it yourself, then re-run this script:"
    die "    pip install --user --break-system-packages 'huggingface_hub[cli]'"
fi

# ---------------------------------------------------------------------------
section "Disk"

avail_gb="$(disk_avail_gb "$AI_ROOT")"
info "Free on $AI_ROOT: ${avail_gb} GB"

# The full manifest is roughly 100 GB: ~20 for Z-Image, ~38 for Wan 2.2, ~9
# for the GGUF and ~3 for the voice models, plus the staging copy each file
# passes through before it is moved into place.
need_gb=110
if (( avail_gb < need_gb )); then
    warn "Less than ${need_gb} GB free. The download may not complete."
    warn "See reference/partition-layout.md for the disk budget."
fi

# ---------------------------------------------------------------------------
for g in "${WANT_GROUPS[@]}"; do
    section "Downloading group '$g'"
    if SKIP_FAILED="${SKIP_FAILED:-no}" bash "$DOWNLOADER" "$g"; then
        ok "Group '$g' complete."
    else
        # One unreachable repository should not abandon the other groups
        # overnight. The downloader prints which entry failed.
        err "Group '$g' had failures."
        warn "Re-run to retry only what is missing:  ./10-models.sh $g"
        warn "Leave the failures alone:              SKIP_FAILED=yes ./10-models.sh $g"
        failed=yes
    fi
done

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
  Models are under $AI_ROOT:

    comfyui/models/   image and video checkpoints, encoders and VAEs
    gguf/             Qwen2.5-14B-Instruct-Q4_K_M.gguf for llama.cpp
    voice/kokoro/     speech synthesis
    voice/whisper/    transcription, used in preference to downloading at runtime

  Serve the GGUF:
      $APPS/start-llama-server.sh Qwen2.5-14B-Instruct-Q4_K_M.gguf

  What has been downloaded so far:  ./10-models.sh --status
  Ledger (the source of truth):     $DOWNLOAD_LEDGER

  Strata packs are separate and much larger - see ./07-strata.sh --help.
  What each entry is and why it was chosen: models/MANIFEST.md
EOF

[[ "${failed:-no}" == yes ]] && exit 1
exit 0
