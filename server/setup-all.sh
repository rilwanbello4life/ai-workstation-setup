#!/usr/bin/env bash
# Phases 12-21 - run the whole server platform setup in order.
#
# Assumes ubuntu/setup-all.sh has already completed: NVIDIA driver, tuning,
# Python, llama.cpp, ComfyUI, voice and Strata.
#
#   ./setup-all.sh            run every step, prompting before each
#   ./setup-all.sh -y         no prompts
#   ./setup-all.sh 02 03      run only those steps
#
# Each step is standalone and re-runnable. 01 is read-only until --apply, so
# this wrapper passes --apply on its behalf.
#
# Background: reference/server-architecture.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO=no

args=()
for a in "$@"; do
    case "$a" in
        -y|--yes) AUTO=yes ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) args+=("$a") ;;
    esac
done

STEPS=(
    "01-server-base.sh:Always-on base: no sleep, system units, swap, firewall, ai-pause"
    "02-k3s.sh:k3s cluster, GPU runtime, ingress, host-model bridge"
    "03-platform.sh:Postgres, LiteLLM gateway, n8n, Open WebUI"
    "04-agents.sh:Agent orchestration: prompt store, roles, example workflows"
    "05-game-servers.sh:Containerised game servers (optional)"
    "06-friends.sh:Share model access with friends (optional)"
    "07-backup.sh:Nightly backups, local and encrypted offsite"
    "08-gitops.sh:Argo CD and the render-commit-sync pipeline (optional)"
    "09-gpu-queue.sh:Fair GPU sharing, per-person profiles, batch jobs (optional)"
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

ram="$(ram_gb)"
if (( ram < 40 )); then
    warn "This machine reports ${ram} GB of RAM."
    warn "The platform needs ~15 GB before a model loads; at 32 GB it will not"
    warn "fit alongside Strata. Fit the 2x32 GB memory kit first."
    echo
    confirm "Continue anyway?" || exit 1
fi

for entry in "${STEPS[@]}"; do
    script="${entry%%:*}"; desc="${entry#*:}"
    num="${script%%-*}"

    if (( ${#args[@]} )) && [[ ! " ${args[*]} " == *" $num "* ]]; then
        continue
    fi

    # Deliberate choices, not defaults. 06 signs into Tailscale in a browser;
    # 08 changes how everything is deployed from then on; 09 builds a
    # container image and moves the shared endpoint. None unattended.
    if [[ "$AUTO" == yes ]] && (( ${#args[@]} == 0 )) && \
       [[ "$script" == "05-game-servers.sh" || "$script" == "06-friends.sh" || \
          "$script" == "08-gitops.sh"       || "$script" == "09-gpu-queue.sh" ]]; then
        warn "Skipped in --yes mode; run it on its own with: ./setup-all.sh $num"
        continue
    fi

    section "$script - $desc"

    if [[ "$AUTO" != yes ]]; then
        if ! confirm "Run $script?"; then
            warn "Skipped."
            continue
        fi
    fi

    # 01 reports and changes nothing without --apply; in an orchestrated run we
    # do want the changes.
    step_args=()
    if [[ "$script" == "01-server-base.sh" ]]; then
        step_args+=(--apply)
    fi

    chmod +x "$HERE/$script"
    if "$HERE/$script" ${step_args[@]+"${step_args[@]}"}; then
        ok "$script finished."
    else
        err "$script failed (exit $?)."
        warn "Fix the problem and re-run just this step:  ./$script"
        exit 1
    fi
done

section "Done"
cat <<EOF
  Cluster:

    kubectl get pods -A                 everything running
    ai-status                           memory, VRAM and services at a glance

  Platform URLs (loopback; publish them with ubuntu/08-remote-access.sh):

    LiteLLM gateway   http://127.0.0.1:4000/v1    keys, budgets, routing
    GPU queue         http://127.0.0.1:4100/v1    same API, waits instead of refusing
    n8n               http://127.0.0.1:5678       workflows and agents
    Open WebUI        http://127.0.0.1:3000       chat
    Argo CD           http://127.0.0.1:8090       what is deployed, and why

  Models still run on the host, not in the cluster:

    strata launch --preset <name>       one pack at a time
    ai-pause                            free ~15 GB for a larger pack
    ai-resume                           bring the platform back

  The standing constraint on this hardware is unchanged: 16 GB of VRAM means
  one heavy workload at a time. With the platform up, the largest Strata pack
  that fits is IQ2_XS at 64 GB of RAM, or UD-IQ4_XS at 96 GB.

  Next, if you want them:
    ./05-game-servers.sh    game servers in the cluster
    ./06-friends.sh         quota-limited model access for friends
    ./08-gitops.sh          deploy by editing files instead of kubectl apply
    ./09-gpu-queue.sh       share the GPU without everyone arriving at once
    ../ubuntu/09-gaming.sh  Steam and Proton, to stop booting Windows

  Not optional, whatever else you skip:
    ./07-backup.sh          nothing is backed up until this runs
EOF
