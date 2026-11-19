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
# shellcheck source=/dev/null
[[ -r "$HOME/.config/ai-workstation/paths.sh" ]] && source "$HOME/.config/ai-workstation/paths.sh"
AI_ROOT="${2:-${AI_ROOT:-${AI_HOME:-$HOME/ai}}}"
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

# A record of what has already been fetched, in the same tab-separated format
# ubuntu/common.sh writes. Deliberately reimplemented here in a few lines
# rather than sourced, because this script has to keep running standalone
# beside its PowerShell twin.
#
# It is not just a speed-up. hf contacts the hub for every entry even when
# the file is cached, so a re-run of a finished manifest still spends a long
# time on the network before doing nothing. A recorded entry is not attempted
# at all.
LEDGER="${DOWNLOAD_LEDGER:-$AI_ROOT/.downloads.tsv}"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
[[ -f "$LEDGER" ]] || printf '# kind\tid\tstatus\twhen\tnote\n' > "$LEDGER"

ledger_status() {
    awk -F'\t' -v i="$1" \
        '$1 == "file" && $2 == i { s = $3 } END { if (s != "") print s }' \
        "$LEDGER" 2>/dev/null || true
}

ledger_mark() {
    local id="$1" status="$2" note="${3:-}" tmp
    tmp="$(mktemp)" || return 0
    awk -F'\t' -v i="$id" '!($1 == "file" && $2 == i)' "$LEDGER" > "$tmp" 2>/dev/null || true
    printf 'file\t%s\t%s\t%s\t%s\n' \
        "$id" "$status" "$(date -Is 2>/dev/null || date)" "$note" >> "$tmp"
    cat "$tmp" > "$LEDGER" 2>/dev/null || true
    rm -f "$tmp"
}

# Reprint the whole manifest with each entry's state after every change, so
# "what is left" never has to be worked out by hand.
progress() {
    local g repo file dest id st mark label done_n=0 fail_n=0 todo_n=0
    printf '\n\033[1m  Manifest: %s\033[0m\n' "$GROUP"
    while IFS=$'\t' read -r g repo file dest; do
        [[ -z "${g// }" || "$g" == \#* ]] && continue
        [[ "$GROUP" == "all" || "$GROUP" == "$g" ]] || continue
        id="$repo::$file"
        st="$(ledger_status "$id")"
        case "$st" in
            ok)     mark='\033[32m[done]\033[0m'; done_n=$((done_n + 1)) ;;
            failed) mark='\033[31m[fail]\033[0m'; fail_n=$((fail_n + 1)) ;;
            *)      mark='[    ]';                todo_n=$((todo_n + 1)) ;;
        esac
        # A whole-repo row has "*" for the file, which basename renders as a
        # bare asterisk; name it by its repository instead.
        if [[ "$file" == "*" ]]; then label="$repo"; else label="$(basename "$file")"; fi
        printf "    $mark %-6s %s\n" "$g" "$label"
    done < "$MANIFEST"
    printf '\033[1m  %d done, %d failed, %d to go\033[0m\n\n' "$done_n" "$fail_n" "$todo_n"
}

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

    id="$repo::$file"
    prior="$(ledger_status "$id")"
    if [[ "$file" == "*" ]]; then shown="$repo"; else shown="$(basename "$file")"; fi

    # Recorded as done: skip without touching the hub or the filesystem.
    # No progress table here on purpose - on a finished manifest that would
    # print the same table once per entry and bury the summary.
    if [[ "$prior" == ok ]]; then
        bold "$shown"
        ok "already recorded as downloaded"
        skipped=$((skipped + 1))
        continue
    fi
    if [[ "$prior" == failed && "${SKIP_FAILED:-no}" == yes ]]; then
        bold "$shown"
        warn "previously failed; skipping because SKIP_FAILED=yes"
        failed=$((failed + 1))
        continue
    fi

    if [[ "$file" == "*" ]]; then
        bold "$repo (whole repository)"
        if [[ -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
            ok "already populated: $target_dir"
            ledger_mark "$id" ok "found populated on disk"
            skipped=$((skipped + 1))
            progress
            continue
        fi
        if "${HF[@]}" "$repo" --local-dir "$target_dir"; then
            ok "$repo -> $target_dir"
            ledger_mark "$id" ok "whole repo"
            downloaded=$((downloaded + 1))
        else
            warn "failed: $repo"
            ledger_mark "$id" failed "hf download failed"
            failed=$((failed + 1))
        fi
        progress
        continue
    fi

    base="$(basename "$file")"
    final="$target_dir/$base"

    bold "$base"
    if [[ -f "$final" ]]; then
        size=$(du -h "$final" | cut -f1)
        ok "already present ($size)"
        # Record it, so the next run does not even stat the disk for this one.
        ledger_mark "$id" ok "found on disk ($size)"
        skipped=$((skipped + 1))
        progress
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
            ledger_mark "$id" ok "$(du -h "$final" | cut -f1)"
            downloaded=$((downloaded + 1))
        else
            warn "downloaded but could not locate $base in staging"
            ledger_mark "$id" failed "not found in staging"
            failed=$((failed + 1))
        fi
    else
        warn "failed: $repo :: $file"
        warn "the repository may have been renamed - check with: hf search ${repo##*/}"
        ledger_mark "$id" failed "hf download failed"
        failed=$((failed + 1))
    fi
    progress
done < "$MANIFEST"

progress
bold "Summary: $downloaded downloaded, $skipped already present, $failed failed"
echo "  Ledger: $LEDGER"
[[ $failed -eq 0 ]] || exit 1
