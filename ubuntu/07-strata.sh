#!/usr/bin/env bash
# Phase 8.7 - Strata: install every model this machine can run.
#
# Strata serves three base models. Most of what looks like a long model list is
# one model at different precision:
#
#   Qwen3.8-Flash-Next   125B MoE, 512 experts per layer, 10 routed + 1 shared
#                        active per token. The ~2% activation rate is why a
#                        125B model runs on a 16 GB card: hot experts in VRAM,
#                        the rest in RAM, a 29 GB n-gram table on the SSD.
#   Qwen3.6-35B-A3B      35B MoE, 3B active, Apache 2.0. The general-purpose
#                        companion to Coder, which is weak outside code.
#   DeepSeek V4.1-Flash  needs 46 GB RAM and 257 GB of disk. Not for 32 GB.
#
# Tiers, by what this machine can actually do:
#
#   A  runs well            Coder, Qwen3.6 UD-Q4_K_XL, Gyro-S      ~150 GB
#   B  tight but viable     Gyro-M, Qwen3.6 UD-Q6_K_XL            ~125 GB
#   C  SSD-streamed, slow   Flash-Next Q2_0, IQ2_XS               ~142 GB
#   D  needs 64 GB RAM      Q2_0, IQ2_XS, IQ3_XXS, Swift, Q8_0    ~326 GB
#   E  needs 64 GB, tight   IQ3_S                                  ~76 GB
#   F  needs 96 GB          UD-IQ4_XS                             ~111 GB
#   G  96 GB + 'ai-pause'    UD-Q4_K_XL, NVFP4                     ~210 GB
#
# Tiers F and G exist only in the 96 GB "add" configuration from phase 11.
# F is the best pack that still loads with the cluster running; G needs the
# cluster stopped with 'ai-pause' first, which is why it is a separate letter
# rather than more of F.
#
# '--tier all' is now all seven letters, about 998 GB, which is everything
# this machine can run. That leaves roughly 220 GB for a Steam library on the
# 2 TB drive - the trade is deliberate and documented in
# reference/partition-layout.md. Use '--tier abcdef' to stop at 788 GB.
#
# NVFP4's download size is not published; the 80 GB in the table is an
# estimate used for the disk guard. Confirm the exact pack names on your
# install with 'strata models list' before relying on tier G.
#
# Deliberately absent at any tier: DeepSeek V4.1-Flash. It runs - memory is
# not the problem - but it is 257 GB for about 5 tok/s with an 8K context
# cap, and it does not fit alongside tier G on a 2 TB drive. See
# reference/4tb-upgrade.md.
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
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

while (( $# )); do
    case "$1" in
        --tier)          TIERS="${2:-a}"; shift 2 ;;
        --install)       DO_INSTALL=yes; shift ;;
        --download-only) DOWNLOAD_ONLY=yes; DO_INSTALL=yes; shift ;;
        --retry-failed)  SKIP_FAILED=no; shift ;;
        --skip-failed)   SKIP_FAILED=yes; shift ;;
        --status)        SHOW_STATUS=yes; shift ;;
        --reconcile)     RECONCILE=yes; shift ;;
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
MODELS=(
    "coder|IQ1_M|a|68|Flash-Next Coder - coding instrument, 55 tok/s"
    "qwen36|UD-Q4_K_XL|a|23|Qwen3.6-35B-A3B 4-bit - general purpose, Apache 2.0"
    "gyro|Gyro-S|a|59|Gyro-S - smallest full-expert Flash-Next"
    "gyro|Gyro-M|b|92|Gyro-M - ~IQ3_XXS quality, 35 GB across VRAM and RAM"
    "qwen36|UD-Q6_K_XL|b|33|Qwen3.6 6-bit - wants 44 GB RAM"
    "qwen|q2_0|cd|70|Flash-Next Q2_0 - 94 tok/s, needs 44 GB RAM"
    "qwen|iq2_xs|cd|72|Flash-Next IQ2_XS - the default; largest that fits with the cluster up"
    "qwen|iq3_xxs|d|74|Flash-Next IQ3_XXS - needs 53 GB RAM"
    "swift|IQ2_XS|d|72|Swift 1.5 - IQ2_XS quality, much shorter thinking"
    "qwen36|Q8_0|d|38|Qwen3.6 8-bit - closest to the full 35B"
    "qwen|iq3_s|e|76|Flash-Next IQ3_S - 50 GB of experts, 53 tok/s"
    "qwen|UD-IQ4_XS|f|111|Unsloth UD-IQ4_XS - 62 GB of experts, 96 GB only"
    "qwen|UD-Q4_K_XL|g|130|Unsloth UD-Q4_K_XL - 78 GB of experts, needs ai-pause"
    "qwen|NVFP4|g|80|NVFP4 - 70 GB of experts, FP4 tensor cores; size estimated"
)

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

printf '  %-5s %-7s %-11s %5s  %s\n' TIER FAMILY MODEL SIZE DESCRIPTION
for entry in "${selected[@]}"; do
    IFS='|' read -r fam mod tier gb desc <<<"$entry"
    printf '  %-5s %-7s %-11s %4sG  %s\n' "${tier^^}" "$fam" "$mod" "$gb" "$desc"
done
echo

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
# but only when exactly one pack claims it - so qwen/UD-Q4_K_XL is not
# matched by qwen36-ud-q4_k_xl, which is a different model of the same name.
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
# the first version did, and on this machine that reads as 1004 GB wanted
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
# be a choice rather than a surprise, because it is 111 GB that cannot load
# until the DIMMs are in. This warns and continues; it does not block, since
# pre-downloading before the RAM arrives is the normal reason to be here.
if [[ "$TIERS" == *f* ]] && (( ram_gb < 90 )); then
    warn "Tier F (UD-IQ4_XS, ~111 GB) needs ~72 GB of RAM; this machine reports ${ram_gb} GB."
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
        warn "Tier G (UD-Q4_K_XL and NVFP4, ~210 GB) needs 80-88 GB; this machine reports ${ram_gb} GB."
        warn "Both will download and the downloads are kept, but the verify step"
        warn "after each one will be killed for running out of memory until the"
        warn "memory upgrade is fitted."
    fi
    warn "Tier G does not load with the cluster running, at any memory size."
    warn "Stop it first with 'ai-pause --cluster', then launch the pack."
    warn "NVFP4's download size is an estimate; check 'strata models list' if it fails."
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
    Will not run     IQ3_XXS, IQ3_S, Swift, Unsloth, NVFP4, DeepSeek

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

  Tiers A-E are ~677 GB and budgeted for on this drive - install them with
  '--tier abcde'. Tier F needs 96 GB and will not load in this configuration,
  so '--tier all' would spend 111 GB on a pack you cannot use yet.

  Memory, not disk, is what decides which of them you can run: IQ2_XS is
  the largest that works with the cluster up, and the rest need
  'ai-pause --cluster' first. Having them all resident is what makes
  switching modes a relaunch instead of a 76 GB download.

  Still out of reach: Unsloth needs 72-136 GB, NVFP4 about 80 GB. DeepSeek
  V4.1-Flash will start, but measures ~5 tok/s on this class of card and
  wants 257 GB of disk.

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

  Tiers A-E are ~677 GB. Three more packs need this memory configuration,
  and all three are now installed by '--tier all':

    F  UD-IQ4_XS   ~62 GB experts, ~111 GB download  - cluster up, 6 GB margin
    G  UD-Q4_K_XL  ~78 GB experts, ~130 GB download  - after 'ai-pause'
    G  NVFP4       ~70 GB experts, ~80 GB estimated  - after 'ai-pause'

  F and G differ only in whether the platform has to be stopped first. At
  96 GB, tier F loads alongside the cluster; tier G needs its ~15 GB back.

  '--tier all' is therefore ~998 GB, every pack this machine can execute.
  That leaves roughly 221 GB for the Steam library instead of 542 GB, which
  is a real trade and the reason it is spelled out here rather than buried
  in the total. '--tier abcdef' stops at 788 GB and keeps 431 GB of games.

  NVFP4 publishes no download size; the 80 GB above is an estimate for the
  disk guard. Check 'strata models list' if the install cannot find it.

  Not included at any tier: DeepSeek V4.1-Flash. Memory is not the problem -
  it is 257 GB for about 5 tok/s with an 8K context cap, and it no longer
  fits beside tier G on this drive. See reference/4tb-upgrade.md.

  Still out of reach: Qwen3.6 Q8_0 class at ~136 GB. DeepSeek V4.1-Flash fits
  in memory but measures ~5 tok/s on this card and wants 257 GB of disk.

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
