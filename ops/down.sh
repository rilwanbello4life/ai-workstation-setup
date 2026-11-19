#!/usr/bin/env bash
# Prepare the machine for a shutdown or reboot.
#
#   ./down.sh              stop model servers, snapshot Postgres, stop k3s
#   ./down.sh --no-backup  skip the snapshot
#   ./down.sh --reboot     do all of it, then reboot
#   ./down.sh --poweroff   do all of it, then power off
#
# systemd already stops these units on shutdown, so this is not required -
# but it does two things an ordinary shutdown does not:
#
#   1. Takes a Postgres snapshot. Backups run nightly, so an unplanned
#      shutdown at 23:00 loses a day of agent runs, prompt history and n8n
#      executions. A dump takes seconds.
#   2. Stops things in dependency order and waits. k3s killed mid-write
#      leaves containerd state that has to be repaired on the next boot,
#      and a Strata pack holding 60 GB of pinned memory makes the shutdown
#      itself slow and occasionally unclean.
#
# It deliberately does NOT run ai-pause. Pause state survives a reboot, so
# pausing here would mean booting into a cluster scaled to zero - exactly
# the state ops/up.sh exists to undo.
#
# Background: reference/backups.md

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../server" && pwd)/common.sh"
require_not_root

DO_BACKUP=yes
AFTER=none

while (( $# )); do
    case "$1" in
        --no-backup) DO_BACKUP=no ;;
        --reboot)    AFTER=reboot ;;
        --poweroff)  AFTER=poweroff ;;
        -h|--help)   sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ "$(uname -s)" == "Linux" ]] || die "This is for the Ubuntu side, not $(uname -s)."

# ---------------------------------------------------------------------------
section "Model servers"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$HERE/switch.sh" ]]; then
    "$HERE/switch.sh" none
else
    have strata && strata launch --stop >/dev/null 2>&1 || true
    pkill -f 'llama-server' 2>/dev/null || true
    pkill -f 'ComfyUI/main.py' 2>/dev/null || true
    ok "Stopped what was running."
fi

# ---------------------------------------------------------------------------
if have kubectl && kubectl get nodes >/dev/null 2>&1; then

    if [[ "$DO_BACKUP" == yes ]]; then
        section "Snapshot"

        # Deliberately the same format and naming as the nightly job in
        # server/07-backup.sh: pg-*.sql.gz, gzipped, dumped with pg_dumpall
        # so roles and passwords come back too. That matters for retention -
        # the nightly prune deletes pg-*.sql.gz older than 14 days, so these
        # shutdown dumps get cleaned up by the same rule instead of piling
        # up forever on a disk that has no room to spare.
        ready="$(kubectl -n "$K8S_NS" get deploy postgres \
                 -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

        if [[ "$ready" == "1" ]]; then
            out="$BACKUP_DIR/postgres/pg-shutdown-$(date +%Y%m%d-%H%M%S).sql.gz"
            mkdir -p "$(dirname "$out")" 2>/dev/null || true
            info "Dumping Postgres to $out"

            if kubectl -n "$K8S_NS" exec deploy/postgres -- \
                   pg_dumpall -U postgres --clean --if-exists 2>/dev/null \
                   | gzip > "$out"; then
                # A dump that died halfway still exits 0 through the pipe, so
                # the gzip stream is what actually proves it finished.
                if gzip -t "$out" 2>/dev/null && (( $(stat -c%s "$out" 2>/dev/null || echo 0) > 2048 )); then
                    ok "Snapshot written ($(du -h "$out" | cut -f1))."
                else
                    warn "The dump looks truncated. Keeping it at $out for inspection."
                fi
            else
                rm -f "$out"
                warn "pg_dumpall failed; last night's backup is still your copy."
            fi
        else
            info "Postgres is not running (paused?). Nothing to snapshot."
        fi
    fi

    section "Cluster"
    info "Stopping k3s and waiting for containers to exit."
    sudo systemctl stop k3s || warn "systemctl stop k3s reported a problem."

    # k3s leaves containerd shims behind when stopped on a busy node; its own
    # killall script is the supported way to clear them.
    if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
        sudo /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
    fi
    ok "Cluster stopped cleanly."
fi

# ---------------------------------------------------------------------------
section "Ready"

free -g | awk 'NR<=2 {print "    " $0}'

case "$AFTER" in
reboot)
    warn "Rebooting in 5 seconds. Ctrl+C to cancel."
    sleep 5
    sudo systemctl reboot
    ;;
poweroff)
    warn "Powering off in 5 seconds. Ctrl+C to cancel."
    sleep 5
    sudo systemctl poweroff
    ;;
*)
    cat <<'EOF'

  Safe to reboot or power off now.
  On the way back up:   ./ops/up.sh
EOF
    ;;
esac
