#!/usr/bin/env bash
# Download models listed in manifest.tsv into the local AI root.
#
# Usage:
#   ./download-models.sh [image|video|voice|text|all] [ai-root]
#
# Defaults to "image" and ~/ai. Already-present files are skipped, so
# re-running is cheap and safe.

set -euo pipefail

GROUP="${1:-image}"
AI_ROOT="${2:-${AI_ROOT:-$HOME/ai}}"
MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifest.tsv"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn()  { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
info()  { printf '  [info] %s\n' "$*"; }

mkdir -p "$AI_ROOT"
[[ -f "$MANIFEST" ]] || { echo "manifest.tsv not found next to this script" >&2; exit 1; }

# The CLI was renamed from huggingface-cli to hf; support both.
if command -v hf >/dev/null 2>&1; then
    HF=(hf download)
elif command -v huggingface-cli >/dev/null 2>&1; then
    HF=(huggingface-cli download)
else
    echo "Hugging Face CLI not found. Install it with: pip install huggingface_hub" >&2
    exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/hfstage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

bold "Downloading group '$GROUP' into $AI_ROOT"
echo

downloaded=0
skipped=0
failed=0

while IFS=$'\t' read -r g repo file dest; do
    [[ -z "${g// }" || "$g" == \#* ]] && continue
    [[ "$GROUP" == "all" || "$GROUP" == "$g" ]] || continue

    target_dir="$AI_ROOT/$dest"
    mkdir -p "$target_dir"

    if [[ "$file" == "*" ]]; then
        bold "$repo (whole repository)"
        if [[ -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
            ok "already populated: $target_dir"
            skipped=$((skipped + 1))
            continue
        fi
        if "${HF[@]}" "$repo" --local-dir "$target_dir"; then
            ok "$repo -> $target_dir"
            downloaded=$((downloaded + 1))
        else
            warn "failed: $repo"
            failed=$((failed + 1))
        fi
        continue
    fi

    base="$(basename "$file")"
    final="$target_dir/$base"

    bold "$base"
    if [[ -f "$final" ]]; then
        size=$(du -h "$final" | cut -f1)
        ok "already present ($size)"
        skipped=$((skipped + 1))
        continue
    fi

    info "$repo :: $file"
    if "${HF[@]}" "$repo" "$file" --local-dir "$STAGING"; then
        # hf download preserves the repo-internal path under --local-dir, so
        # locate the file by name and flatten it into the destination.
        src="$(find "$STAGING" -type f -name "$base" -print -quit)"
        if [[ -n "$src" ]]; then
            mv "$src" "$final"
            ok "-> $final  ($(du -h "$final" | cut -f1))"
            downloaded=$((downloaded + 1))
        else
            warn "downloaded but could not locate $base in staging"
            failed=$((failed + 1))
        fi
    else
        warn "failed: $repo :: $file"
        warn "the repository may have been renamed - check with: hf search ${repo##*/}"
        failed=$((failed + 1))
    fi
    echo
done < "$MANIFEST"

echo
bold "Summary: $downloaded downloaded, $skipped already present, $failed failed"
[[ $failed -eq 0 ]] || exit 1
