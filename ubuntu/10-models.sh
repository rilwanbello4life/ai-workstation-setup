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
#
# Re-running is cheap: already-present files are skipped by name, and partial
# downloads resume rather than restart. Nothing here prompts.
#
# Background: models/MANIFEST.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOADER="$KIT_ROOT/models/download-models.sh"

[[ -f "$DOWNLOADER" ]] || die "Cannot find $DOWNLOADER - run this from inside the kit."

GROUPS=("$@")
(( ${#GROUPS[@]} )) || GROUPS=(all)

# ---------------------------------------------------------------------------
section "Prerequisites"

ensure_ai_dirs

# The downloader needs the Hugging Face CLI. Installing it here rather than
# failing keeps an unattended run going; 03-python-cuda.sh may not have run.
if have hf || have huggingface-cli; then
    ok "Hugging Face CLI present."
elif have uv; then
    info "Installing huggingface_hub with uv."
    uv tool install "huggingface_hub[cli]" >/dev/null 2>&1 \
        || die "Could not install the Hugging Face CLI."
    ok "Hugging Face CLI installed."
else
    python3 -m pip install --user --quiet "huggingface_hub[cli]" \
        || die "Could not install the Hugging Face CLI. Run ./03-python-cuda.sh first."
    ok "Hugging Face CLI installed."
fi

# ---------------------------------------------------------------------------
section "Disk"

avail_gb="$(df -BG --output=avail "$AI_ROOT" 2>/dev/null | tail -n1 | tr -dc '0-9')"
avail_gb="${avail_gb:-0}"
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
for g in "${GROUPS[@]}"; do
    section "Downloading group '$g'"
    if bash "$DOWNLOADER" "$g"; then
        ok "Group '$g' complete."
    else
        # One unreachable repository should not abandon the other groups
        # overnight. The downloader prints which entry failed.
        err "Group '$g' had failures."
        warn "Re-run to retry just the missing files:  ./10-models.sh $g"
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

  Strata packs are separate and much larger - see ./07-strata.sh --help.
  What each entry is and why it was chosen: models/MANIFEST.md
EOF

[[ "${failed:-no}" == yes ]] && exit 1
exit 0
