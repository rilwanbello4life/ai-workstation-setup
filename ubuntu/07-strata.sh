#!/usr/bin/env bash
# Phase 8.7 - Strata: install every model this machine can run.
#
# Strata groups its models into seven families. A family is a base model plus
# the people who quantised it, and the "model" within a family is a precision,
# not a different network. Verified against this install with --catalogue:
#
#   qwen     Qwen3.8-Flash-Next            Q2_0, IQ2_XS, IQ3_XXS, IQ3_S
#   unsloth  Qwen3.8-Flash-Next (Unsloth)  12 sizes, UD-IQ1_M up to Q8_0
#   nvfp4    Qwen3.8-Flash-Next (NVFP4)    NVFP4, NVFP4-NVIDIA, NVFP4-QAD
#   gyro     Qwen3.8-Flash-Next (Gyro)     Gyro-S, Gyro-M
#   coder    Qwen3.8-Flash-Next Coder      IQ1_M
#   swift    Swift 1.5                     IQ2_XS, IQ3_XXS, IQ3_S
#   qwen36   Qwen3.6-35B-A3B               UD-Q4_K_XL, UD-Q6_K_XL, Q8_0
#
# Flash-Next is a 125B MoE, 512 experts per layer, 10 routed + 1 shared active
# per token. The ~2% activation rate is why it runs on a 16 GB card at all:
# hot experts in VRAM, the rest in RAM, a 29 GB n-gram table on the SSD.
# Qwen3.6-35B-A3B is 35B MoE, 3B active, Apache 2.0 - the general-purpose
# companion to Coder, which is weak outside code.
#
# The family matters. UD-Q4_K_XL exists in both 'unsloth' and 'qwen36' and is
# a different model in each; asking 'qwen' for a UD- size is rejected, because
# the Unsloth quants are their own family. Get it wrong and Strata answers
# "<Family> has no size <Model>", which is what --catalogue is for.
#
# Tiers, by what this machine can actually do:
#
#   A  runs well            Coder, Qwen3.6 UD-Q4_K_XL, Gyro-S      ~150 GB
#   B  tight but viable     Gyro-M, Qwen3.6 UD-Q6_K_XL            ~125 GB
#   C  SSD-streamed, slow   Flash-Next Q2_0, IQ2_XS               ~142 GB
#   D  needs 64 GB RAM      Q2_0, IQ2_XS, IQ3_XXS, Swift, Q8_0    ~322 GB
#   E  needs 64 GB, tight   IQ3_S                                  ~76 GB
#   F  needs 96 GB          Unsloth UD-IQ4_XS                      ~94 GB
#   G  96 GB + 'ai-pause'   Unsloth UD-Q4_K_XL, NVFP4             ~239 GB
#
# Tiers F and G exist only in the 96 GB "add" configuration from phase 11.
# F is the best pack that still loads with the cluster running; G needs the
# cluster stopped with 'ai-pause' first, which is why it is a separate letter
# rather than more of F.
#
# Every size above is measured, not estimated - each one is the "About N GB to
# download" line from 'strata launch --plan' for that exact family and model.
# Re-measure at any time with --catalogue, which asks Strata rather than
# trusting this table.
#
# '--tier all' is all seven letters, about 1006 GB. That leaves roughly 213 GB
# for a Steam library on the 2 TB drive - the trade is deliberate and
# documented in reference/partition-layout.md. '--tier abcdef' stops at
# 767 GB and keeps about 452 GB of games.
#
# What '--tier all' is NOT is the whole catalogue. Strata offers 28 family and
# model combinations; the table below installs 14 of them. The other 14 are
# mostly larger Unsloth quants and the two remaining NVFP4 variants, and they
# would need well over another terabyte. The drive, not Strata, is the limit.
# '--catalogue' lists all 28 with their real download sizes so the choice can
# be made on numbers.
#
# Prints a plan and changes nothing unless you pass --install.
#
# Full catalogue, quality numbers and the thinking notes:
#   reference/strata-models.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

TIERS="a"
DO_INSTALL=no
ASSUME_YES=no

usage() {
    sed -n '2,57p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Usage:
  ./07-strata.sh                      show the plan for tier A
  ./07-strata.sh --tier ab            plan tiers A and B
  ./07-strata.sh --tier a --install   download and install tier A
  ./07-strata.sh --tier de --install  after the phase 11 memory upgrade
  ./07-strata.sh --tier f --install   the 96 GB pack, on four DIMMs only
  ./07-strata.sh --tier g --install   the two that also need 'ai-pause'
  ./07-strata.sh --tier all --install everything this machine allows
  ./07-strata.sh --tier all --install --download-only
                                      fetch every pack without loading any
  ./07-strata.sh --status             what is downloaded, what is left
  ./07-strata.sh --tier all --reconcile
                                      record packs Strata already has
  ./07-strata.sh --catalogue          every family and size Strata offers,
                                      with measured download sizes
  ./07-strata.sh --remove Gyro-S Gyro-M
                                      delete packs, asking first. Resolves
                                      each path through 'strata models
                                      explain' rather than guessing it

Options:
  --tier LETTERS   any combination of a b c d e f g, or "all"  (default: a)
  --install        actually download, instead of printing the plan
  --download-only  fetch each pack but do not keep it loaded. Strata has no
                   such mode of its own, so this caps the load step's memory
                   hard and lets it be killed the moment it starts. The pack
                   is already on disk by then. This is how you fill the drive
                   on a machine that cannot yet run what it is downloading.
  --retry-failed   re-attempt entries the ledger records as failed (default)
  --skip-failed    leave previously failed entries alone
  --status         print the ledger and exit, changing nothing
  --remove NAMES   delete one or more packs and their run configs. Takes the
                   SIZE name as Strata spells it - 'Gyro-S', not the folder
                   tag 'gyro-gyro-s' - and 'family/Size' where a size exists
                   in more than one family. Asks before each unless -y.
                   Must be the last option; everything after it is a name.
  --catalogue      ask Strata for every family and size it offers, measure
                   each one with --plan, and show which tier installs it.
                   Read-only: it downloads nothing and changes nothing.
                   This is the authority; the table in this script is a copy.
  -y, --yes        do not ask before each model

Anything recorded as downloaded is skipped outright on the next run - not
re-checked, not re-verified, not handed to Strata at all. The record lives in
$AI_ROOT/.downloads.tsv and is the source of truth.

EOF
}

DOWNLOAD_ONLY=no
SKIP_FAILED=no
SHOW_STATUS=no
RECONCILE=no
CATALOGUE=no
REMOVE=no
REMOVE_NAMES=()

while (( $# )); do
    case "$1" in
        --tier)          TIERS="${2:-a}"; shift 2 ;;
        --install)       DO_INSTALL=yes; shift ;;
        --download-only) DOWNLOAD_ONLY=yes; DO_INSTALL=yes; shift ;;
        --retry-failed)  SKIP_FAILED=no; shift ;;
        --skip-failed)   SKIP_FAILED=yes; shift ;;
        --status)        SHOW_STATUS=yes; shift ;;
        --reconcile)     RECONCILE=yes; shift ;;
        --catalogue)     CATALOGUE=yes; shift ;;
        --remove)        REMOVE=yes; shift; REMOVE_NAMES=("$@"); break ;;
        -y|--yes)        ASSUME_YES=yes; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done
TIERS="$(tr '[:upper:]' '[:lower:]' <<<"$TIERS")"
if [[ "$TIERS" == "all" ]]; then TIERS="abcdefg"; fi
# Without this, --tier bogus silently matches tier B.
[[ "$TIERS" =~ ^[abcdefg]+$ ]] || die "Tier must be letters a-g, or 'all'. Got: $TIERS"

# A model's tier field may hold several letters - Q2_0 and IQ2_XS are both
# "usable now but SSD-bound" (C) and "first-class after the upgrade" (D).
# Match if any of them was asked for, so each model is listed exactly once.
want_tier() {
    local letter i
    for (( i = 0; i < ${#1}; i++ )); do
        letter="${1:i:1}"
        if [[ "$TIERS" == *"$letter"* ]]; then return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Removal. Strata has no remove verb - 'strata models' offers list, inspect,
# explain, import and move - so this does it, and does it by asking Strata
# where the files are rather than constructing a path.
#
# That matters more than it sounds. The folder spellings are not consistent:
# qwen/IQ3_XXS lives in models/IQ3_XXS with no prefix, gyro/Gyro-S lives in
# models/gyro-Gyro-S with one, and swift/IQ2_XS is in an entirely different
# data directory from both. A constructed path would be wrong often enough to
# be dangerous, and wrong in the direction of deleting nothing while
# reporting success.
#
# Note what is NOT reclaimed. A Flash-Next pack's second shard is the ~29 GB
# Engram n-gram table, shared across every pack of that base model and stored
# once. 'explain' counts it against each pack that uses it, so removing three
# packs that each report 70 GB returns about 116 GiB rather than 210 GB. The
# figure printed below is the unique part, which is what you actually get.
if [[ "$REMOVE" == yes ]]; then
    section "Removing model packs"
    (( ${#REMOVE_NAMES[@]} )) || die "Nothing named. Try: --remove Gyro-S Gyro-M"
    have strata || die "strata is not installed."

    for name in "${REMOVE_NAMES[@]}"; do
        echo
        info "Asking Strata about $name"

        # explain takes the SIZE name, not the folder tag that 'models list'
        # prints. 'Gyro-S' works; 'gyro-gyro-s' is rejected. Where a size
        # exists in two families - UD-Q4_K_XL and Q8_0 both do - pass it as
        # "family/Size" and this splits it.
        fam=""; size="$name"
        if [[ "$name" == */* ]]; then fam="${name%%/*}"; size="${name##*/}"; fi

        if [[ -n "$fam" ]]; then
            exp="$(strata models explain "$size" --family "$fam" 2>&1)" || true
        else
            exp="$(strata models explain "$size" 2>&1)" || true
        fi

        if ! grep -q '^Uses: ' <<<"$exp"; then
            warn "Strata could not resolve '$name'. It said:"
            sed 's/^/    /' <<<"$exp" | head -n 4
            warn "Sizes are case-sensitive, and a size in two families needs family/Size."
            continue
        fi

        # "Uses: /path (setup's spelling)" - take the path, drop the comment.
        dir="$(sed -n 's/^Uses: //p' <<<"$exp" | head -n1 | sed 's/ ([^)]*)$//')"
        [[ -d "$dir" ]] || { warn "Resolved to '$dir', which is not a directory."; continue; }

        tag="$(sed -n 's/.*folder tag \([^)]*\)).*/\1/p' <<<"$exp" | head -n1)"
        real="$(du -sh "$dir" 2>/dev/null | cut -f1)"

        echo "    directory   $dir"
        echo "    on disk     ${real:-unknown} (excludes shared shards)"
        [[ -n "$tag" ]] && echo "    folder tag  $tag"

        if [[ "$ASSUME_YES" != yes ]]; then
            confirm "Delete $name?" || { info "Left alone."; continue; }
        fi

        rm -rf "$dir" || { oops "Could not remove $dir"; continue; }

        # The run config, not the weights, is what makes a pack report as
        # 'present'. Removing one without the other leaves 'models list'
        # naming a pack whose files are gone.
        if [[ -n "$tag" ]]; then
            rm -f "$HOME/.local/share/strata/install/strata-${tag}.json"
            rm -f "$HOME/.config/strata/launch-presets/${tag}.json"
        fi
        ok "Removed $name."
    done

    echo
    section "What is left"
    strata models list 2>/dev/null | sed 's/^/  /' || true
    df -h / | sed 's/^/  /'
    exit 0
fi

# ---------------------------------------------------------------------------
section "This machine"

# MemTotal is in KiB and excludes what the firmware reserves, so a 32 GB kit
# reports about 31, a 64 GB kit about 62 and a 96 GB fill about 93. Every
# threshold below allows for that - comparing against a literal 32 or 96 would
# reject the intended hardware.
ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
info "System RAM: ${ram_gb} GB usable"

vram_gb=0
if have nvidia-smi; then
    vram_mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9' || true)"
    vram_gb=$(( ${vram_mb:-0} / 1024 ))
    info "VRAM: ${vram_gb} GB"
    (( vram_gb >= 12 )) || die "Strata needs 12 GB of VRAM or more."
else
    warn "nvidia-smi not found; run ./01-nvidia.sh first."
fi

(( ram_gb >= 30 )) || die "Strata needs a 32 GB machine; this one reports ${ram_gb} GB usable."

ensure_ai_dirs
avail_gb="$(disk_avail_gb "$AI_ROOT")"
size_gb="$(disk_size_gb "$AI_ROOT")"

# A DRAM-less NVMe shrinks its SLC write cache as the drive fills, so the last
# tenth of the disk costs sustained write speed, not just comfort. On a 2 TB
# drive that is the difference between Postgres committing promptly and not.
reserve_gb=$(( size_gb / 10 ))
spendable_gb=$(( avail_gb - reserve_gb ))
info "Free space on $AI_ROOT: ${avail_gb} GB of ${size_gb} GB"
info "Holding ${reserve_gb} GB in reserve, so ${spendable_gb} GB is spendable."

# Strata pins tens of gigabytes. Without a raised memlock limit it either fails
# outright or quietly falls back to unpinned memory and pages during
# generation.
memlock="$(ulimit -l)"
if [[ "$memlock" == "unlimited" ]]; then
    ok "memlock is unlimited."
else
    warn "memlock limit is ${memlock} KB - too low for a 25-30 GB pinned model."
    warn "Run ./02-tune-linux.sh, then log out and back in."
fi

# ---------------------------------------------------------------------------
section "The model plan"

# family | model | tier | GB | description
#
# The family column is load-bearing and is the one thing here that cannot be
# guessed. Strata validates the model name before the family, so a wrong
# family does not fail until the launch itself, with a message that reads
# like the model is missing rather than misfiled. The Unsloth UD- quants and
# the NVFP4 variants are their own families, not sizes of 'qwen'.
#
# GB is the measured download size from 'strata launch --plan', not an
# estimate. Re-check the whole table against Strata with --catalogue.
MODELS=(
    "coder|IQ1_M|a|68|Flash-Next Coder - coding instrument, 55 tok/s"
    "qwen36|UD-Q4_K_XL|a|23|Qwen3.6-35B-A3B 4-bit - general purpose, Apache 2.0"
    "gyro|Gyro-S|a|59|Gyro-S - smallest full-expert Flash-Next"
    "gyro|Gyro-M|b|92|Gyro-M - ~IQ3_XXS quality, 35 GB across VRAM and RAM"
    "qwen36|UD-Q6_K_XL|b|33|Qwen3.6 6-bit - wants 44 GB RAM"
    "qwen|q2_0|cd|70|Flash-Next Q2_0 - 94 tok/s, needs 44 GB RAM"
    "qwen|iq2_xs|cd|72|Flash-Next IQ2_XS - the default; largest that fits with the cluster up"
    "qwen|iq3_xxs|d|74|Flash-Next IQ3_XXS - needs 53 GB RAM"
    "swift|IQ2_XS|d|68|Swift 1.5 - IQ2_XS quality, much shorter thinking"
    "qwen36|Q8_0|d|38|Qwen3.6 8-bit - closest to the full 35B"
    "qwen|iq3_s|e|76|Flash-Next IQ3_S - 50 GB of experts, 53 tok/s"
    "unsloth|UD-IQ4_XS|f|94|Unsloth UD-IQ4_XS - 62 GB of experts, 96 GB only"
    "unsloth|UD-Q4_K_XL|g|111|Unsloth UD-Q4_K_XL - 78 GB of experts, needs ai-pause"
    "nvfp4|NVFP4|g|128|NVFP4 - 70 GB of experts, FP4 tensor cores"
)

# ---------------------------------------------------------------------------
# --catalogue: ask Strata what it offers and what each pack costs, rather
# than trusting the table above.
#
# Strata has no "list everything" command, but its error messages are exact
# and cost nothing to produce:
#
#   --family <nonsense>         "There is no model family called 'x'.
#                                Families: ..."
#   --model  <nonsense>         "There is no model called 'x'. Models: ..."
#   valid model, wrong family   "<Family> has no size <M>. It offers: ..."
#
# Only the third gives a per-family list, and it needs a model the family
# does not have - so each family is probed with names from the global list
# until one is rejected. No two families share an identical size list, so
# this always terminates, usually on the first probe.
#
# Every pair then gets --plan, which downloads nothing, changes nothing and
# states the exact transfer size. That is where the GB column in MODELS came
# from. Three of those numbers were estimates once, and all three were wrong
# by 17 to 48 GB, so the table is now derived from this and not from reading.

# "<prefix>: a, b, c." on stdin -> "a b c"
_csv_after() {
    sed -n "s/.*$1: \(.*\)\./\1/p" | tr -d ' ' | tr ',' ' '
}

# Which tier, if any, installs this pair.
_kit_tier() {
    local want f m t g d e
    want="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
    for e in "${MODELS[@]}"; do
        IFS='|' read -r f m t g d <<<"$e"
        if [[ "$(tr '[:upper:]' '[:lower:]' <<<"${f}/${m}")" == "$want" ]]; then
            printf 'tier %s' "${t^^}"
            return 0
        fi
    done
    printf -- '-'
}

catalogue() {
    local families all_models fam mod probe out offers pack dl tier
    local n=0 kept=0 sum=0

    have strata || die "strata is not installed, so there is nothing to ask."

    # Capture, then parse. Strata exits non-zero when it rejects a name, and
    # piping it straight into the parser puts that failure at the head of a
    # pipeline under 'set -o pipefail' - which aborts the whole script with
    # no message at all, since the error text went into the substitution.
    info "Reading Strata's family list."
    out="$(strata launch --family __catalogue__ --model Q2_0 --plan 2>&1 || true)"
    families="$(_csv_after 'Families' <<<"$out")"
    [[ -n "$families" ]] || die "Could not read the family list from Strata."

    info "Reading Strata's model list."
    out="$(strata launch --family qwen --model __catalogue__ --plan 2>&1 || true)"
    all_models="$(_csv_after 'Models' <<<"$out")"
    [[ -n "$all_models" ]] || die "Could not read the model list from Strata."

    info "Measuring each pack with --plan. Nothing is downloaded."
    echo
    printf '  %-8s %-15s %7s %11s  %s\n' FAMILY MODEL PACK DOWNLOAD 'INSTALLED BY'
    printf '  %-8s %-15s %7s %11s  %s\n' -------- --------------- ------- ----------- ------------

    for fam in $families; do
        offers=""
        for probe in $all_models; do
            out="$(strata launch --family "$fam" --model "$probe" --plan 2>&1 || true)"
            if [[ "$out" == *"has no size"* ]]; then
                offers="$(_csv_after 'It offers' <<<"$out")"
                break
            fi
        done
        if [[ -z "$offers" ]]; then
            warn "$fam: could not determine its size list; skipped."
            continue
        fi

        for mod in $offers; do
            out="$(strata launch --family "$fam" --model "$mod" --plan 2>&1 || true)"
            # awk with an explicit exit, rather than sed piped through head.
            # Under 'set -o pipefail' a head that finishes first can SIGPIPE
            # the sed feeding it and fail the whole substitution - a failure
            # that depends on scheduling, so it would pass in testing and
            # break later. awk stops itself and needs no pipeline.
            #
            #   model     Qwen3.8-Flash-Next (Unsloth) UD-IQ4_XS, 94 GB
            pack="$(awk -F', ' '/^ *model / {
                        split($NF, a, " ")
                        if (a[2] == "GB") { print a[1]; exit }
                    }' <<<"$out")"
            if [[ "$out" == *"Nothing to download"* ]]; then
                dl="on disk"
                kept=$(( kept + 1 ))
            else
                #   download  About 93.7 GB to download: the model (93.7 GB).
                dl="$(awk '/About .* GB to download/ {
                          for (i = 1; i < NF; i++)
                              if ($i == "About") { print $(i+1); exit }
                      }' <<<"$out")"
                if [[ -n "$dl" ]]; then
                    sum="$(awk -v a="$sum" -v b="$dl" 'BEGIN { printf "%.0f", a + b }')"
                    dl="${dl} GB"
                else
                    dl="?"
                fi
            fi
            tier="$(_kit_tier "${fam}/${mod}")"
            printf '  %-8s %-15s %6sG %11s  %s\n' \
                   "$fam" "$mod" "${pack:-?}" "$dl" "$tier"
            n=$(( n + 1 ))
        done
    done

    echo
    info "$n family/model combinations, $kept already on this computer."
    info "Fetching every one of the rest would transfer about ${sum} GB."
    cat <<EOF

  A dash in the last column means no tier installs it. That is a disk
  decision, not an oversight: this drive cannot hold the whole catalogue,
  and '--tier all' is already ~1006 GB of it. Add one deliberately with

      strata launch --family FAMILY --model MODEL --yes --no-tui

  and it will be picked up by '--tier all --reconcile' afterwards.

  Where PACK and DOWNLOAD differ, DOWNLOAD is what crosses the network and
  PACK is what Strata reports as the loaded size. Budget on DOWNLOAD.
EOF
}

if [[ "$CATALOGUE" == yes ]]; then
    section "Strata's real catalogue"
    catalogue
    exit 0
fi

selected=()
total=0
for entry in "${MODELS[@]}"; do
    IFS='|' read -r fam mod tier gb desc <<<"$entry"
    want_tier "$tier" || continue
    selected+=("$entry")
    total=$(( total + gb ))
done

if (( ${#selected[@]} == 0 )); then
    die "No models selected for tier '$TIERS'. Try --tier a."
fi

# Packs that a 96 GB machine holds something strictly better than. Every one
# is outclassed by qwen/IQ3_S or qwen36/Q8_0, both of which fit here with the
# cluster running - so on this machine they are disk spent on a worse answer.
# They stay in the tiers because the tiers describe 32 and 64 GB machines too,
# where several of them are the best available. The marker is advisory; it
# changes what is printed, never what is installed.
# One line deliberately. Wrapping it put a newline where the membership test
# expects a space, and the entry beside the break silently stopped matching.
SUPERSEDED_96="qwen/q2_0 qwen/iq2_xs qwen/iq3_xxs gyro/Gyro-S gyro/Gyro-M swift/IQ2_XS qwen36/UD-Q4_K_XL qwen36/UD-Q6_K_XL"

# 85, not 90. This machine fills four DIMMs to 96 GB and MemTotal reports
# 89 - lower than the ~93 the comment at the top of this file predicted,
# because what the firmware reserves varies with how the slots are populated.
# A threshold of 90 would have excluded the exact hardware it was written for.
superseded_here() {
    (( ram_gb >= 85 )) || return 1
    [[ " ${SUPERSEDED_96} " == *" $1/$2 "* ]]
}

printf '  %-5s %-7s %-11s %5s  %s\n' TIER FAMILY MODEL SIZE DESCRIPTION
sup_count=0
sup_gb=0
for entry in "${selected[@]}"; do
    IFS='|' read -r fam mod tier gb desc <<<"$entry"
    mark=""
    if superseded_here "$fam" "$mod"; then
        mark="  <- outclassed on this machine"
        sup_count=$(( sup_count + 1 ))
        sup_gb=$(( sup_gb + gb ))
    fi
    printf '  %-5s %-7s %-11s %4sG  %s%s\n' "${tier^^}" "$fam" "$mod" "$gb" "$desc" "$mark"
done
echo

if (( sup_count > 0 )); then
    warn "${sup_count} of these are outclassed at ${ram_gb} GB - about ${sup_gb} GB."
    warn "Each is beaten by qwen/IQ3_S or qwen36/Q8_0, which fit with the cluster up."
    warn "Remove with --remove, or see reference/strata-models.md for the argument."
    echo
fi

# The plan rows, as the ledger sees them. Built once and reused for every
# progress print so the list cannot drift from what is actually being done.
strata_rows() {
    local e f m t g d
    for e in "${selected[@]}"; do
        IFS='|' read -r f m t g d <<<"$e"
        printf '%s/%s\t%-5s %-7s %-11s %4sG\n' "$f" "$m" "${t^^}" "$f" "$m" "$g"
    done
}

# ---------------------------------------------------------------------------
# Ask Strata what it already has, and believe it.
#
# Strata downloads into its own store - ~/.local/share/strata - and the kit
# has never told it where to put anything, so there is no directory the
# ledger can look in. The only authority on what has been fetched is Strata
# itself, and "strata models list" is a read-only question with no load and
# no download behind it.
#
# Without this, the cheapest way to find out whether a pack was already
# downloaded would be to launch it and see, which on a 32 GB machine means
# loading tens of gigabytes before being killed - per pack, every run.
#
# Matching needs two rules because Strata names a pack after its model alone
# when it belongs to the default family, and after family and model
# otherwise: Coder appears as coder-iq1_m, but plain Flash-Next IQ2_XS is
# just iq2_xs rather than qwen-iq2_xs. Preset first, then the bare model name
# but only when exactly one pack claims it - so unsloth/UD-Q4_K_XL is not
# matched by qwen36-ud-q4_k_xl, which is a genuinely different model that
# happens to carry the same size name. Two families offering UD-Q4_K_XL is
# not hypothetical; it is why the bare-name rule needs the uniqueness test.
strata_present() {
    local preset="$1" bare="$2" listing="$3" hit

    hit="$(awk -v p="$preset" '$2 == "present" && $1 == p { print $3; exit }' <<<"$listing")"
    if [[ -n "$hit" ]]; then printf '%s' "$hit"; return 0; fi

    if (( $(awk -v b="$bare" '$2 == "present" && $1 == b' <<<"$listing" | wc -l) == 1 )); then
        awk -v b="$bare" '$2 == "present" && $1 == b { print $3; exit }' <<<"$listing"
        return 0
    fi
    return 1
}

# Sets RECONCILED_N to the number of packs newly recorded. A count returned
# on stdout would be interleaved with the per-pack lines below, which is
# exactly the sort of thing that reads as a formatting glitch and hides a
# real number. Quiet unless asked, so an install run can call it without
# burying the output it is about to produce.
RECONCILED_N=0
reconcile_ledger() {
    local verbose="${1:-no}" listing entry fam mod tier gb desc preset bare id found n=0

    RECONCILED_N=0

    have strata || return 0
    listing="$(strata models list 2>/dev/null || true)"
    [[ -n "$listing" ]] || return 0
    ledger_init

    for entry in "${selected[@]}"; do
        IFS='|' read -r fam mod tier gb desc <<<"$entry"
        id="${fam}/${mod}"
        [[ "$(ledger_status strata "$id")" == ok ]] && continue

        preset="$(tr '[:upper:]' '[:lower:]' <<<"${fam}-${mod}")"
        bare="$(tr '[:upper:]' '[:lower:]' <<<"$mod")"

        if found="$(strata_present "$preset" "$bare" "$listing")"; then
            ledger_mark strata "$id" ok "already in the Strata store as $found"
            [[ "$verbose" == yes ]] && ok "  $id  <-  $found"
            n=$(( n + 1 ))
        fi
    done

    RECONCILED_N="$n"
}

if [[ "$RECONCILE" == yes ]]; then
    section "Checking what Strata already has"
    have strata || die "strata is not installed - nothing to reconcile against."
    reconcile_ledger yes
    echo
    info "Recorded $RECONCILED_N pack(s) that were already downloaded."
    strata_rows | ledger_progress strata "Strata packs - tier ${TIERS}"
    echo
    info "Ledger: $DOWNLOAD_LEDGER"
    exit 0
fi

# Record what Strata already has before any decision depends on it. Both
# things below need it: --status would otherwise report a pack as
# outstanding when it is sitting on the disk, and the size check further
# down has to measure what is still missing rather than the whole plan.
reconcile_ledger

# What is actually left to fetch. Sizing the check by the full plan is what
# the first version did, and on this machine that reads as 1006 GB wanted
# against 615 GB spendable - so it refuses to start a download that is
# really 321 GB and fits with room to spare.
remaining=0
for entry in "${selected[@]}"; do
    IFS='|' read -r fam mod tier gb desc <<<"$entry"
    [[ "$(ledger_status strata "${fam}/${mod}")" == ok ]] && continue
    remaining=$(( remaining + gb ))
done

if [[ "$SHOW_STATUS" == yes ]]; then
    strata_rows | ledger_progress strata "Strata packs - tier ${TIERS}"
    echo
    info "Ledger: $DOWNLOAD_LEDGER"
    exit 0
fi
info "Plan total:     ~${total} GB across ${#selected[@]} pack(s)"
if (( remaining != total )); then
    info "Already have:   ~$(( total - remaining )) GB"
fi
info "Still to fetch: ~${remaining} GB (plus ~6 GB MTP draft layer, shared)"
info "Spendable:      ${spendable_gb} GB"

if (( remaining + 6 > spendable_gb )); then
    warn "What is left does not fit."
    warn "It wants ~$(( remaining + 6 )) GB; ${spendable_gb} GB is spendable."
    warn "Drop a tier, use --tier a, or free space elsewhere."
    # In plan mode this is advice. In install mode it is a wall, because the
    # failure arrives 600 GB into a download rather than here.
    [[ "$DO_INSTALL" == yes ]] && die "Refusing to start a download that cannot finish."
fi

# Tier F needs the 96 GB configuration. Downloading it on less is legitimate
# - packs are fetched once and the memory upgrade is phase 11 - but it should
# be a choice rather than a surprise, because it is 94 GB that cannot load
# until the DIMMs are in. This warns and continues; it does not block, since
# pre-downloading before the RAM arrives is the normal reason to be here.
if [[ "$TIERS" == *f* ]] && (( ram_gb < 90 )); then
    warn "Tier F (Unsloth UD-IQ4_XS, ~94 GB) needs ~72 GB of RAM; this machine reports ${ram_gb} GB."
    warn "The download will complete and is kept. The verify step that follows"
    warn "it will then be killed for running out of memory - that is expected"
    warn "here, and is reported as a failure at the end rather than hidden."
    warn "Use --tier abcde to leave it out."
fi

# Tier G is the same argument one step further out: 96 GB is necessary but not
# sufficient, because these two only fit once the platform's ~15 GB is gone.
# Downloading them early is still the right call - they are fetched once - so
# this warns rather than blocks, exactly as tier F does.
if [[ "$TIERS" == *g* ]]; then
    if (( ram_gb < 90 )); then
        warn "Tier G (UD-Q4_K_XL and NVFP4, ~239 GB) needs 80-88 GB; this machine reports ${ram_gb} GB."
        warn "Both will download and the downloads are kept, but the verify step"
        warn "after each one will be killed for running out of memory until the"
        warn "memory upgrade is fitted."
    fi
    warn "Tier G does not load with the cluster running, at any memory size."
    warn "Stop it first with 'ai-pause --cluster', then launch the pack."
fi

# ---------------------------------------------------------------------------
section "What this machine can actually run"

if (( ram_gb < 42 )); then
    cat <<EOF
  At ${ram_gb} GB of RAM with a ${vram_gb} GB card:

    Runs well        Qwen3.6 UD-Q4_K_XL                       (tier A)
    Marginal         Coder, Gyro-S                            (tier A)
    Tight            Gyro-M                                   (tier B)
    SSD-streamed     Flash-Next Q2_0 and IQ2_XS - much slower (tier C)
    Will not run     IQ3_XXS, IQ3_S, Swift, Unsloth, NVFP4

  The fit rule for Flash-Next is: RAM must hold the experts plus about 10 GB
  for the OS. Coder needs 23 GB of experts, Q2_0 needs 34 GB, IQ3_S needs 50.
  A bigger card does not lower that - low-RAM mode needs a 24 GB GPU to help.

  Coder is listed as marginal rather than comfortable on purpose: 23 GB of
  experts plus 10 GB for the OS is 33 GB against the ${ram_gb} GB you have, so
  it fits only with nothing else running, and not at all with the cluster up.
  Gyro-S has no published memory figure - its 59 GB is on-disk size, not RAM -
  so treat it as unmeasured here rather than known good.

  Tier C is 142 GB of download for a degraded experience. Both packs become
  first-class the day you fit the 2x32 GB kit. Installing them now is
  supported, but the honest advice is to wait.

EOF
elif (( ram_gb < 60 )); then
    info "At ${ram_gb} GB, Q2_0 and IQ2_XS fit properly. IQ3_XXS and IQ3_S do not."
elif (( ram_gb < 90 )); then
    cat <<EOF
  At ${ram_gb} GB of RAM every ISTA-DASLab size fits (IQ3_S with little else
  open). IQ2_XS is Strata's recommended default at this tier.

  This is the 'swap' memory configuration: the 2x32 GB kit on its own, two
  modules at the full DDR5-6000. You trade the top of the catalogue for about
  a fifth more memory bandwidth than the four-DIMM alternative.

  Tiers A-E are ~673 GB and budgeted for on this drive - install them with
  '--tier abcde'. Tier F needs 96 GB and will not load in this configuration,
  so '--tier all' would spend 94 GB on a pack you cannot use yet.

  Memory, not disk, is what decides which of them you can run: IQ2_XS is
  the largest that works with the cluster up, and the rest need
  'ai-pause --cluster' first. Having them all resident is what makes
  switching modes a relaunch instead of a 76 GB download.

  Still out of reach: the Unsloth family needs 72-136 GB of RAM and NVFP4
  about 80 GB. Both are their own families rather than sizes of Flash-Next -
  see '--catalogue'.

EOF
else
    cat <<EOF
  At ${ram_gb} GB of RAM the server stack is no longer what limits your model.
  About 68 GB is left for experts with the cluster up and 83 GB after
  'ai-pause', so IQ3_S becomes the daily driver rather than a deliberate mode.

  This is the 'add' configuration: four DIMMs at roughly DDR5-3600. Confirm
  it passed a full memtest86+ pass before trusting Postgres to it - mixed
  ranks are the least forgiving thing AM5 does, and marginal memory corrupts
  data quietly rather than failing visibly.

  Tiers A-E are ~673 GB. Three more packs need this memory configuration,
  and all three are now installed by '--tier all':

    F  unsloth/UD-IQ4_XS   ~62 GB experts,  94 GB download - cluster up
    G  unsloth/UD-Q4_K_XL  ~78 GB experts, 111 GB download - after 'ai-pause'
    G  nvfp4/NVFP4         ~70 GB experts, 128 GB download - after 'ai-pause'

  Note the families. These are not sizes of Flash-Next: the Unsloth quants
  and the NVFP4 variants are separate families, and asking 'qwen' for them
  is rejected. The download figures are measured with 'strata launch --plan',
  which is what '--catalogue' does for the whole catalogue.

  F and G differ only in whether the platform has to be stopped first. At
  96 GB, tier F loads alongside the cluster; tier G needs its ~15 GB back.

  '--tier all' is therefore ~1006 GB, every pack this machine can execute.
  That leaves roughly 213 GB for the Steam library instead of 546 GB, which
  is a real trade and the reason it is spelled out here rather than buried
  in the total. '--tier abcdef' stops at 767 GB and keeps 452 GB of games.

  Still out of reach on memory: the Qwen3.6 Q8_0 class at ~136 GB, and the
  larger Unsloth quants above UD-Q4_K_XL.

  Out of reach on disk: the other 14 of Strata's 28 family/model pairs.
  '--tier all' is everything this drive can hold, not everything Strata
  offers. Run '--catalogue' to see the rest with their real sizes.

EOF
fi

# ---------------------------------------------------------------------------
section "Strata"

# The terminal CLI is what gives model management: strata launch, presets,
# strata models list and strata connect. The source checkout in the repo does
# not.
if have strata; then
    ok "Already installed ($(strata --version 2>/dev/null | head -n1 || echo present))"
elif [[ "$DO_INSTALL" == yes ]]; then
    info "Installing the Strata terminal."
    curl -fsSL --connect-timeout 15 --max-time 120 \
        https://github.com/Niko1221/Strata/releases/latest/download/install.sh -o /tmp/strata-install.sh
    sh /tmp/strata-install.sh
    export PATH="$HOME/.local/bin:$PATH"
    have strata || die "strata not on PATH. Open a new shell and re-run."
    ok "Installed."
else
    todo "Not installed yet. Re-run with --install."
fi

if [[ "$DO_INSTALL" != yes ]]; then
    section "Nothing was changed"
    cat <<EOF
  This was a plan. To act on it:

      ./07-strata.sh --tier ${TIERS} --install

  To preview a single model without downloading anything:

      strata launch --plan --family coder --model IQ1_M

  Catalogue, quality numbers and the thinking notes:
      reference/strata-models.md
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
section "Freeing VRAM"

# The desktop session holds 1-1.5 GB. On a 16 GB card that is the difference
# between more experts staying resident and spilling to system RAM.
if have nvidia-smi; then
    used_mb="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9' || true)"
    info "VRAM currently in use: ${used_mb:-0} MB"
    if (( ${used_mb:-0} > 800 )); then
        info "Free most of it with: ai-console-mode off"
    fi
fi

# ---------------------------------------------------------------------------
section "Installing models"

cat <<EOF
  Each model is downloaded, started once to prove it works, then stopped.
  Expect the machine to freeze for 1-3 minutes the first time a Flash-Next
  pack loads: 35-55 GB is read into RAM and partly pinned for the GPU.

  Downloads resume if interrupted. Re-running skips what is already present.

  Run this from a plain console or tmux, not from an editor's built-in
  terminal. The load step is what exhausts memory, and an editor is usually
  the largest thing on the machine for the kernel to kill - which also kills
  the download, because the terminal is its parent.

EOF

# Confine the load step to its own memory cgroup.
#
# Strata downloads a pack and then loads it, and 02-tune-linux.sh grants
# memlock unlimited so it can pin expert tensors. Pinned pages cannot be
# reclaimed, so when a pack is larger than RAM the kernel cannot take the
# memory back from Strata - it kills the next largest thing instead, which on
# a desktop is the editor or the browser, not the process at fault.
#
# A scope with MemoryMax reverses that: the kill lands on Strata. The pack is
# already fully downloaded by then, so the bytes are kept and a later run
# after the memory upgrade just loads them. The cap is generous on purpose -
# on a 96 GB machine it never binds, and it is only the small-memory case it
# is protecting.
#
# --download-only turns the same mechanism into the download-only mode
# Strata does not have. Downloading needs very little memory; loading needs
# tens of gigabytes. Setting the cap just above what a download needs means
# the fetch runs to completion and the load is killed the instant it begins,
# which is precisely the behaviour wanted on a machine that cannot yet run
# what it is filling the drive with.
MEM_GUARD=()
CAP_GB=0
if (( ram_gb > 12 )) && have systemd-run; then
    # User scopes only accept MemoryMax where systemd delegates the memory
    # controller. Probe rather than assume: without delegation the flag is
    # rejected and every launch below would fail for the wrong reason.
    if systemd-run --user --scope --quiet -p MemoryMax=1G true >/dev/null 2>&1; then
        if [[ "$DOWNLOAD_ONLY" == yes ]]; then
            CAP_GB=12
        else
            CAP_GB=$(( ram_gb - 6 ))
        fi
        MEM_GUARD=(systemd-run --user --scope --quiet
                   -p MemoryMax="${CAP_GB}G" --)
    else
        warn "systemd cannot cap memory for user scopes here."
        warn "A pack larger than RAM may get your desktop killed instead of Strata."
        [[ "$DOWNLOAD_ONLY" == yes ]] && \
            warn "--download-only cannot stop the load either; expect heavy paging."
    fi
fi

if [[ "$DOWNLOAD_ONLY" == yes ]]; then
    cat <<EOF
  Download-only. Each pack is fetched in full, then the load that Strata
  always does next is killed at ${CAP_GB:-?} GB. A pack recorded as downloaded is
  skipped entirely next time - not re-checked, not handed to Strata at all.

  "load killed" below is the expected, successful outcome here.

EOF
elif (( CAP_GB > 0 )); then
    info "Loads are capped at ${CAP_GB} GB so an overrun kills Strata, not your session."
fi

ledger_init
info "Ledger: $DOWNLOAD_LEDGER"

# Before launching anything, record what Strata already has. Skipping a pack
# costs one line; discovering it the hard way costs a load that gets killed.
reconcile_ledger
if (( RECONCILED_N > 0 )); then
    ok "$RECONCILED_N pack(s) are already in the Strata store; they will be skipped."
fi

installed=()
failed=()

for entry in "${selected[@]}"; do
    IFS='|' read -r fam mod tier gb desc <<<"$entry"
    preset="$(tr '[:upper:]' '[:lower:]' <<<"${fam}-${mod}")"
    id="${fam}/${mod}"
    prior="$(ledger_status strata "$id")"

    section "${fam} / ${mod}  (~${gb} GB)"

    # The whole point of the ledger: no network call, no disk scan, no Strata
    # invocation. An entry already recorded costs nothing to pass over.
    # No progress table on the skip paths: a finished run would otherwise
    # print the same table once per model. The summary prints it once.
    if [[ "$prior" == ok ]]; then
        ok "Already downloaded. Skipping."
        installed+=("$preset")
        continue
    fi
    if [[ "$prior" == failed && "$SKIP_FAILED" == yes ]]; then
        warn "Previously failed and --skip-failed is set. Leaving it."
        failed+=("$id")
        continue
    fi
    [[ "$prior" == failed ]] && info "Previously failed; retrying."
    info "$desc"

    if [[ "$ASSUME_YES" != yes ]] && ! confirm "Install this one?"; then
        warn "Skipped."
        strata_rows | ledger_progress strata "Tier ${TIERS}"
        continue
    fi

    # --yes skips prompts, --no-tui serves and returns instead of opening the
    # monitor, --save-preset makes switching to it a one-liner later.
    rc=0
    "${MEM_GUARD[@]}" strata launch --family "$fam" --model "$mod" \
                     --yes --no-tui --save-preset "$preset" || rc=$?

    if (( rc == 0 )); then
        ok "${fam}/${mod} downloaded and loaded."
        ledger_mark strata "$id" ok "downloaded and verified"

        # Checked, not assumed. This used to discard the result and print
        # "Stopped" either way, so a stop that failed left the pack resident
        # and the next one loaded on top of it - on a machine that usually
        # has room for exactly one.
        if strata launch --stop >/dev/null 2>&1; then
            info "Stopped; memory and VRAM released."
        else
            warn "Could not confirm Strata stopped. Check 'strata launch --status'."
            warn "If it is still serving, the next pack will load on top of it."
        fi
        installed+=("$preset")

    elif (( rc == 137 )); then
        # 137 is SIGKILL, which here means the cgroup hit MemoryMax. Strata
        # downloads before it loads, so reaching the point of being killed
        # for memory proves the download finished - a network failure exits
        # long before anything large is resident. That distinction is what
        # lets the ledger record a download as complete on a machine that
        # cannot load it.
        if (( CAP_GB > 0 )); then
            ok "${fam}/${mod} downloaded; load killed at ${CAP_GB} GB as intended."
        else
            # No cap was available, so this kill came from the kernel or
            # systemd-oomd. Same conclusion: the download had to finish for
            # the load to start and be killed.
            ok "${fam}/${mod} downloaded; the load was killed for memory."
        fi
        ledger_mark strata "$id" ok "downloaded, load not verified"
        installed+=("$preset")

    else
        err "${fam}/${mod} failed (exit $rc)."
        if [[ "$DOWNLOAD_ONLY" == yes ]]; then
            warn "This is not the memory cap - the download itself did not finish."
        elif (( ram_gb < 42 )); then
            info "On ${ram_gb} GB the larger packs cannot load. Use --download-only"
            info "to fetch them now and verify after the memory upgrade."
        fi
        ledger_mark strata "$id" failed "exit $rc"
        warn "Retry on its own:  strata launch --family $fam --model $mod"
        failed+=("$id")
    fi

    strata_rows | ledger_progress strata "Tier ${TIERS}"
done

# ---------------------------------------------------------------------------
section "Summary"

strata_rows | ledger_progress strata "Tier ${TIERS}"
info "Ledger: $DOWNLOAD_LEDGER"
echo

if (( ${#installed[@]} )); then
    ok "Installed ${#installed[@]} model(s). Switch between them with:"
    for p in "${installed[@]}"; do
        printf '      strata launch --preset %s\n' "$p"
    done
else
    warn "No models were installed."
fi

if (( ${#failed[@]} )); then
    echo
    warn "Failed: ${failed[*]}"
    info "Retry just those:    $0 --tier $TIERS --install -y"
    info "Leave them alone:    $0 --tier $TIERS --install -y --skip-failed"
fi

cat <<'EOF'

  Useful commands:

      strata models list            what is installed
      strata launch --list-presets  saved configurations
      strata launch --status        what is serving now
      strata launch --stop          unload and free VRAM
      strata connect pi             wire up a coding agent

  The API is OpenAI- and Anthropic-compatible on http://127.0.0.1:8080/v1

      curl http://127.0.0.1:8080/v1/models

  One heavy workload at a time: 16 GB of VRAM will not hold two large models,
  and a Flash-Next pack pins 25-30 GB of system RAM while loaded.

  A note on speed. Both Qwen models think by default, and Flash-Next's own
  default is 'xhigh', the longest tier. A model rated 55 tok/s can spend a
  long stretch on reasoning you never see before the answer starts. Pass
  reasoning_effort (none|low|medium|xhigh) to control it, and remember that
  thinking and instruct modes want different sampling parameters. Details in
  reference/strata-models.md.

  Next: ./08-remote-access.sh to reach this from your phone or laptop.
EOF
