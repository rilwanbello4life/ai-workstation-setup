#!/usr/bin/env bash
# Phase 16 - containerised game servers (optional).
#
# Game servers are the one workload in this kit that directly competes with
# the model for RAM, and the competition is not subtle: 4 GB of Minecraft is
# 4 GB of Strata experts you can no longer hold. This script therefore refuses
# to deploy anything it cannot fit, and installs a 'games' command that makes
# the trade visible before you make it.
#
# Nothing here is started by default. Run with --minecraft or --valheim.
#
# Player access is over Tailscale. The firewall from 01-server-base.sh denies
# inbound on every interface except tailscale0, so a LoadBalancer service is
# reachable by your tailnet and not by the internet. Opening a port to the
# world is a separate, deliberate act - see the warning at the end.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root
require_k3s

DEPLOY_MINECRAFT=0
DEPLOY_VALHEIM=0

while (( $# )); do
    case "$1" in
        --minecraft) DEPLOY_MINECRAFT=1; shift ;;
        --valheim)   DEPLOY_VALHEIM=1;   shift ;;
        -y|--yes)    shift ;;
        -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
section "Memory budget"

TOTAL_GB="$(ram_gb)"
# MemAvailable is the honest number: it accounts for Strata's mlocked pages,
# which free(1) will happily report as "used" without saying by what.
AVAIL_GB=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024 / 1024 ))

info "Installed: ${TOTAL_GB} GB    Available right now: ${AVAIL_GB} GB"

if pgrep -f 'strata|llama-server' >/dev/null 2>&1; then
    warn "A model server is running. Memory it has locked is not available here."
    warn "If a game fails to schedule, 'ai-pause' frees it."
fi

REQUESTED_GB=0
(( DEPLOY_MINECRAFT )) && REQUESTED_GB=$(( REQUESTED_GB + 4 ))
(( DEPLOY_VALHEIM ))   && REQUESTED_GB=$(( REQUESTED_GB + 4 ))

if (( REQUESTED_GB == 0 )); then
    cat <<EOF

  Nothing selected. Available servers:

      ./05-game-servers.sh --minecraft    Paper, 10 players, 4 GB
      ./05-game-servers.sh --valheim      dedicated, 4-6 GB

  Both together use the entire 8Gi games quota, which costs Strata enough to
  drop it from the IQ2_XS pack to Q2_0. Pick one unless you have paused the
  model.

  For anything else, copy the template:

      cp $K8S_DIR/39-game-template.yaml $K8S_DIR/32-mygame.yaml

EOF
    exit 0
fi

if (( AVAIL_GB < REQUESTED_GB + 6 )); then
    warn "Requesting ${REQUESTED_GB} GB with only ${AVAIL_GB} GB available."
    warn "The pod will likely sit Pending. Free memory first with 'ai-pause'."
    confirm "Deploy anyway?" || exit 0
fi

# ---------------------------------------------------------------------------
if (( DEPLOY_MINECRAFT )); then
    section "Minecraft"

    # Generated once and kept. Regenerating it on every run would break any
    # RCON client you had already configured.
    RCON_PW="$(secret_file "$SECRETS/minecraft-rcon-password" 16)"
    kubectl -n "$GAMES_NS" create secret generic minecraft-rcon \
        --from-literal=password="$RCON_PW" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "RCON password stored ($PLATFORM_DIR/secrets/minecraft-rcon-password)."

    kubectl apply -f "$K8S_DIR/30-minecraft.yaml" >/dev/null
    ok "Applied manifest."

    info "First boot generates the world; this can take several minutes."
    wait_for_deploy minecraft "$GAMES_NS" 600 || \
        warn "Not ready yet. Watch: kubectl -n $GAMES_NS logs -f deploy/minecraft"
fi

# ---------------------------------------------------------------------------
if (( DEPLOY_VALHEIM )); then
    section "Valheim"

    VAL_PW="$(secret_file "$SECRETS/valheim-password" 8)"
    # Valheim rejects passwords under 5 characters and refuses any password
    # that appears in the server name - worth knowing before you debug a
    # server that starts and immediately exits.
    kubectl -n "$GAMES_NS" create secret generic valheim-password \
        --from-literal=password="$VAL_PW" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "Server password stored ($PLATFORM_DIR/secrets/valheim-password)."

    kubectl apply -f "$K8S_DIR/31-valheim.yaml" >/dev/null
    ok "Applied manifest."

    info "First boot downloads the server through SteamCMD; allow ~10 minutes."
    wait_for_deploy valheim "$GAMES_NS" 900 || \
        warn "Not ready yet. Watch: kubectl -n $GAMES_NS logs -f deploy/valheim"
fi

# ---------------------------------------------------------------------------
section "games command"

sudo tee /usr/local/bin/games >/dev/null <<'GAMES_EOF'
#!/usr/bin/env bash
# Start, stop and inspect game servers, with the memory cost shown.
#
#   games list              what exists and what is running
#   games start <name>      scale to 1
#   games stop <name>       scale to 0, world preserved
#   games stop-all          stop everything in the games namespace
#   games logs <name>       follow logs
#   games rcon              Minecraft console
#   games address           how players connect
set -euo pipefail

NS="${GAMES_NS:-games}"

case "${1:-list}" in
  list)
    kubectl -n "$NS" get deploy -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas,MEM:.spec.template.spec.containers[0].resources.requests.memory'
    echo
    avail=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
    echo "Memory available: ${avail} GB"
    ;;
  start)
    [[ $# -ge 2 ]] || { echo "usage: games start <name>" >&2; exit 1; }
    kubectl -n "$NS" scale deploy "$2" --replicas=1
    echo "Starting $2. 'games logs $2' to watch."
    ;;
  stop)
    [[ $# -ge 2 ]] || { echo "usage: games stop <name>" >&2; exit 1; }
    kubectl -n "$NS" scale deploy "$2" --replicas=0
    echo "Stopped $2. The world directory under /srv/games is untouched."
    ;;
  stop-all)
    kubectl -n "$NS" scale deploy --all --replicas=0
    echo "All game servers stopped."
    ;;
  logs)
    [[ $# -ge 2 ]] || { echo "usage: games logs <name>" >&2; exit 1; }
    kubectl -n "$NS" logs -f "deploy/$2" --tail=100
    ;;
  rcon)
    kubectl -n "$NS" exec -it deploy/minecraft -- rcon-cli
    ;;
  address)
    ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    name="$(tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
    echo "Players connect over Tailscale. Share your tailnet with them first."
    echo
    [[ -n "$name" ]] && echo "  Hostname: $name"
    [[ -n "$ip"   ]] && echo "  IP:       $ip"
    echo
    kubectl -n "$NS" get svc -o custom-columns=\
'SERVICE:.metadata.name,PORT:.spec.ports[*].port,PROTO:.spec.ports[*].protocol,TYPE:.spec.type'
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
GAMES_EOF
sudo chmod +x /usr/local/bin/games

ok "Installed 'games'."

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
      games list            what is running and what it costs
      games address         what to send your players
      games stop-all        reclaim the memory for the model

  Two things that will otherwise surprise you:

  * A game server running during a dual boot into Windows is a game server
    that is off. There is no migration and no warning to players; the box
    simply stops being a host. If people depend on a world, stay on Ubuntu.

  * 'ai-pause --games' stops game servers without touching the platform, and
    'ai-resume' brings back exactly what was running. Use it before loading a
    larger Strata pack rather than discovering the shortfall at load time.

  Worlds live in /srv/games and are included in the backup target from
  reference/server-architecture.md. Back up before any version upgrade: a
  world opened by a newer server version cannot be opened by the older one.

  Next: ./06-friends.sh
EOF
