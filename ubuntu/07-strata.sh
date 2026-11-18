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
#
# Tier F exists only in the 96 GB "add" configuration from phase 11. It is in
# the table rather than fetched by hand because at 96 GB it is the best pack
# that still loads with the cluster running.
#
# NVFP4 and UD-Q4_K_XL stay out of the tier system deliberately. Taking both
# F-class packs overruns the drive, and NVFP4 publishes no download size to
# guard against - so these two remain a manual, deliberate choice. See
# reference/strata-models.md.
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
  ./07-strata.sh --tier all --install everything this machine allows

Options:
  --tier LETTERS   any combination of a b c d e f, or "all"  (default: a)
  --install        actually download, instead of printing the plan
  -y, --yes        do not ask before each model

EOF
}

while (( $# )); do
    case "$1" in
        --tier)    TIERS="${2:-a}"; shift 2 ;;
        --install) DO_INSTALL=yes; shift ;;
        -y|--yes)  ASSUME_YES=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done
TIERS="$(tr '[:upper:]' '[:lower:]' <<<"$TIERS")"
if [[ "$TIERS" == "all" ]]; then TIERS="abcdef"; fi
# Without this, --tier bogus silently matches tier B.
[[ "$TIERS" =~ ^[abcdef]+$ ]] || die "Tier must be letters a-f, or 'all'. Got: $TIERS"

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
    vram_mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9')"
    vram_gb=$(( ${vram_mb:-0} / 1024 ))
    info "VRAM: ${vram_gb} GB"
    (( vram_gb >= 12 )) || die "Strata needs 12 GB of VRAM or more."
else
    warn "nvidia-smi not found; run ./01-nvidia.sh first."
fi

(( ram_gb >= 30 )) || die "Strata needs a 32 GB machine; this one reports ${ram_gb} GB usable."

ensure_ai_dirs
avail_gb="$(df -BG --output=avail "$AI_ROOT" 2>/dev/null | tail -n1 | tr -dc '0-9')"
avail_gb="${avail_gb:-0}"
size_gb="$(df -BG --output=size "$AI_ROOT" 2>/dev/null | tail -n1 | tr -dc '0-9')"
size_gb="${size_gb:-0}"

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
info "Download total: ~${total} GB (plus ~6 GB MTP draft layer, shared)"
info "Spendable:      ${spendable_gb} GB"

if (( total + 6 > spendable_gb )); then
    warn "This plan does not fit."
    warn "It wants ~$(( total + 6 )) GB; ${spendable_gb} GB is spendable."
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
    warn "Tier F (UD-IQ4_XS, ~111 GB) needs ~96 GB of RAM; this machine reports ${ram_gb} GB."
    warn "It will download and install, but cannot load until phase 11 is fitted."
    warn "Use --tier abcde to leave it out."
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

  Tiers A-E are ~677 GB and budgeted for on this drive. Tier F adds the one
  pack that only this memory configuration reaches:

    UD-IQ4_XS   ~62 GB experts, ~111 GB download  - cluster up, 6 GB margin

  '--tier all' now means A-F, ~788 GB, which leaves roughly 431 GB for the
  Steam library instead of 542 GB. That trade is the reason it is called out
  here rather than buried in the total.

  Two more packs reach this tier and are deliberately not in '--tier all':

    NVFP4       ~70 GB experts                    - after 'ai-pause'
    UD-Q4_K_XL  ~78 GB experts, ~130 GB download  - after 'ai-pause'

  Disk, not memory, is the constraint up here: A-F plus either of those
  overruns the Steam allocation entirely. Take one only if you have decided
  what it displaces, or see reference/4tb-upgrade.md.

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
    used_mb="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9')"
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

EOF

installed=()
failed=()

for entry in "${selected[@]}"; do
    IFS='|' read -r fam mod tier gb desc <<<"$entry"
    preset="$(tr '[:upper:]' '[:lower:]' <<<"${fam}-${mod}")"

    section "${fam} / ${mod}  (~${gb} GB)"
    info "$desc"

    if [[ "$ASSUME_YES" != yes ]] && ! confirm "Install this one?"; then
        warn "Skipped."
        continue
    fi

    # --yes skips prompts, --no-tui serves and returns instead of opening the
    # monitor, --save-preset makes switching to it a one-liner later.
    if strata launch --family "$fam" --model "$mod" \
                     --yes --no-tui --save-preset "$preset"; then
        ok "${fam}/${mod} installed and serving."
        strata launch --stop >/dev/null 2>&1 || true
        info "Stopped; VRAM released."
        installed+=("$preset")
    else
        err "${fam}/${mod} failed."
        warn "Retry on its own:  strata launch --family $fam --model $mod"
        failed+=("$fam/$mod")
    fi
done

# ---------------------------------------------------------------------------
section "Summary"

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
