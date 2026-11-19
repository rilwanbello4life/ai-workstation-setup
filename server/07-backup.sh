#!/usr/bin/env bash
# Phase 18 - backups, local and offsite.
#
# Until this runs, the platform has no backup at all. /srv/backups exists and
# nothing writes to it. A drive failure loses the Postgres databases, the n8n
# workflows, the game worlds and - worst of the four - the secrets directory,
# which contains the n8n encryption key. Without that key every credential n8n
# has stored becomes permanently unreadable, and no amount of Postgres
# recovery brings it back.
#
# Two layers, because they fail differently:
#
#   Local   /srv/backups, same drive. Protects against mistakes: a bad
#           migration, a dropped table, an upgrade that ate a world. Fast to
#           restore from. Useless if the drive dies.
#
#   Offsite restic to B2 or S3, encrypted client-side. Protects against drive
#           failure, fire, theft and ransomware. The data worth keeping is
#           small - megabytes to a few GB - so this costs about 50 kr/month.
#
# Models are deliberately NOT backed up. They are ~998 GB and re-downloadable.
#
# Offsite is optional: with no provider configured the script still runs and
# keeps local snapshots, so it is useful on day one. Configure offsite later
# and nothing else changes.
#
# Background: reference/backups.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

LOCAL_ONLY=no
while (( $# )); do
    case "$1" in
        --local-only) LOCAL_ONLY=yes; shift ;;
        -y|--yes)     shift ;;
        -h|--help)    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

BACKUP_ENV="$SECRETS/backup.env"
RESTIC_PW_FILE="$SECRETS/restic-password"

# ---------------------------------------------------------------------------
section "What gets backed up"

cat <<EOF
      Postgres          every database, via pg_dumpall
      n8n workflows     exported as JSON, so they survive losing Postgres
      Secrets           $SECRETS - small and irreplaceable
      Game worlds       $GAMES_DIR
      Manifests         the k8s/ directory, so a rebuild needs no git access

  Not backed up: model files (~998 GB, re-downloadable) and container images.
EOF

# ---------------------------------------------------------------------------
section "restic"

if have restic; then
    ok "restic $(restic version 2>/dev/null | awk '{print $2}') already installed."
else
    info "Installing restic."
    sudo apt-get install -y restic >/dev/null
    have restic || die "restic install failed."
    ok "Installed."
fi

sudo mkdir -p "$BACKUP_DIR"/{postgres,workflows,manifests}
sudo chown -R "$USER:$USER" "$BACKUP_DIR"

# ---------------------------------------------------------------------------
section "Encryption key"

# The circular dependency that makes most home backups worthless: if the only
# copy of the repository password lives on the machine being backed up, then
# losing the machine loses the ability to read the backups. The password is
# generated here and must be recorded somewhere else before this is a backup.
if [[ -f "$RESTIC_PW_FILE" ]]; then
    ok "Repository password already exists."
    FIRST_RUN=no
else
    secret_file "$RESTIC_PW_FILE" 32 >/dev/null
    ok "Generated a repository password."
    FIRST_RUN=yes
fi

RESTIC_PW="$(sudo cat "$RESTIC_PW_FILE")"

# ---------------------------------------------------------------------------
section "Offsite target"

# A provider counts as configured only once RESTIC_REPOSITORY is actually set.
# The template below is written on first run and is all comments, so its mere
# existence proves nothing.
if [[ -f "$BACKUP_ENV" ]] && sudo grep -qE '^\s*export\s+RESTIC_REPOSITORY=' "$BACKUP_ENV"; then
    ok "Offsite provider configured in $BACKUP_ENV"
    OFFSITE=yes
elif [[ "$LOCAL_ONLY" == yes ]]; then
    info "Running local-only, as requested."
    OFFSITE=no
elif [[ -f "$BACKUP_ENV" ]]; then
    OFFSITE=no
    warn "$BACKUP_ENV exists but sets no RESTIC_REPOSITORY."
    warn "Backups stay local until one provider in that file is uncommented."
else
    OFFSITE=no
    sudo tee "$BACKUP_ENV" >/dev/null <<'EOF'
# Offsite backup target. Uncomment and fill in ONE provider, then re-run
# server/07-backup.sh. Until then backups stay local to /srv/backups.
#
# Backblaze B2 - cheapest for this volume, about 6 USD per TB per month.
# Create a bucket and an application key scoped to it, not a master key.
#
# export RESTIC_REPOSITORY="b2:your-bucket-name:ai-workstation"
# export B2_ACCOUNT_ID="your-key-id"
# export B2_ACCOUNT_KEY="your-application-key"
#
# AWS S3 - sensible if you already have an account. Use a dedicated IAM user
# restricted to this one bucket, and enable versioning plus object lock if you
# want protection against a compromised key deleting the backups.
#
# export RESTIC_REPOSITORY="s3:s3.eu-north-1.amazonaws.com/your-bucket/ai-workstation"
# export AWS_ACCESS_KEY_ID="..."
# export AWS_SECRET_ACCESS_KEY="..."
#
# Any SFTP host, including a friend's machine.
#
# export RESTIC_REPOSITORY="sftp:user@host:/backups/ai-workstation"
EOF
    sudo chmod 600 "$BACKUP_ENV"
    warn "No provider configured yet. Wrote a template to:"
    warn "    $BACKUP_ENV"
    warn "Local snapshots work now; offsite starts the moment you fill it in."
fi

# ---------------------------------------------------------------------------
section "Backup commands"

sudo tee /usr/local/bin/platform-backup >/dev/null <<BACKUP_EOF
#!/usr/bin/env bash
# Snapshot the platform: Postgres, n8n workflows, secrets, worlds, manifests.
#
#   platform-backup              full run, local then offsite
#   platform-backup --local      skip the offsite push
#
# Run nightly by platform-backup.timer. Safe to run by hand at any time.
set -uo pipefail

SECRETS="$SECRETS"
BACKUP_DIR="$BACKUP_DIR"
GAMES_DIR="$GAMES_DIR"
K8S_DIR="$K8S_DIR"
K8S_NS="$K8S_NS"
GAMES_NS="$GAMES_NS"
export KUBECONFIG="$KUBECONFIG"
BACKUP_EOF

sudo tee -a /usr/local/bin/platform-backup >/dev/null <<'BACKUP_EOF'

STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_ONLY=no
[[ "${1:-}" == "--local" ]] && LOCAL_ONLY=yes

fail=0
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
oops() { log "ERROR: $*"; fail=1; }

log "Backup $STAMP starting."

# --- Postgres -------------------------------------------------------------
# pg_dumpall rather than pg_dump: it captures roles and their passwords too,
# without which a restore produces databases nothing can log into.
if kubectl -n "$K8S_NS" get deploy postgres >/dev/null 2>&1 &&
   [[ "$(kubectl -n "$K8S_NS" get deploy postgres -o jsonpath='{.status.readyReplicas}')" == "1" ]]; then
    out="$BACKUP_DIR/postgres/pg-$STAMP.sql.gz"
    if kubectl -n "$K8S_NS" exec deploy/postgres -- \
         pg_dumpall -U postgres --clean --if-exists 2>/dev/null | gzip > "$out"; then
        # A dump that errored halfway still exits 0 through the pipe, so verify
        # the gzip stream is complete and the file is not implausibly small.
        if gzip -t "$out" 2>/dev/null && [[ "$(stat -c%s "$out")" -gt 2048 ]]; then
            log "Postgres dumped: $(du -h "$out" | cut -f1)"
        else
            oops "Postgres dump is truncated or empty; keeping it for inspection."
        fi
    else
        oops "pg_dumpall failed."
    fi
else
    # ai-pause scales Postgres to zero. Skipping is correct; failing is not.
    log "Postgres is not running (ai-pause?). Skipping the database dump."
fi

# --- n8n workflows --------------------------------------------------------
# The Postgres dump already contains these, but as encrypted rows in a schema
# only n8n understands. A JSON export is readable and importable by hand, and
# is the thing that saves you when the database restore is the broken part.
if kubectl -n "$K8S_NS" get deploy n8n >/dev/null 2>&1 &&
   [[ "$(kubectl -n "$K8S_NS" get deploy n8n -o jsonpath='{.status.readyReplicas}')" == "1" ]]; then
    if kubectl -n "$K8S_NS" exec deploy/n8n -- \
         n8n export:workflow --all --pretty --output=/tmp/wf.json >/dev/null 2>&1; then
        kubectl -n "$K8S_NS" exec deploy/n8n -- cat /tmp/wf.json \
            > "$BACKUP_DIR/workflows/workflows-$STAMP.json" 2>/dev/null
        kubectl -n "$K8S_NS" exec deploy/n8n -- rm -f /tmp/wf.json >/dev/null 2>&1
        log "Workflows exported."
    else
        oops "n8n workflow export failed."
    fi
else
    log "n8n is not running. Skipping the workflow export."
fi

# --- Game worlds ----------------------------------------------------------
# Copying a live world risks capturing a half-written region file. Minecraft
# can be told to flush and hold writes for the duration, so do that when it
# is running rather than hoping.
mc_paused=no
if kubectl -n "$GAMES_NS" get deploy minecraft >/dev/null 2>&1 &&
   [[ "$(kubectl -n "$GAMES_NS" get deploy minecraft -o jsonpath='{.status.readyReplicas}')" == "1" ]]; then
    if kubectl -n "$GAMES_NS" exec deploy/minecraft -- \
         rcon-cli save-off >/dev/null 2>&1; then
        kubectl -n "$GAMES_NS" exec deploy/minecraft -- rcon-cli save-all >/dev/null 2>&1
        sleep 5
        mc_paused=yes
        log "Minecraft writes flushed and held."
    fi
fi

# --- Manifests ------------------------------------------------------------
# So a rebuild from bare metal needs the backup and nothing else.
cp -r "$K8S_DIR"/. "$BACKUP_DIR/manifests/" 2>/dev/null && log "Manifests copied."

# --- Local retention ------------------------------------------------------
# Fourteen days locally. The offsite copy keeps the long tail; local is only
# there to make a same-week mistake quick to undo.
find "$BACKUP_DIR/postgres"  -name 'pg-*.sql.gz'      -mtime +14 -delete 2>/dev/null
find "$BACKUP_DIR/workflows" -name 'workflows-*.json' -mtime +14 -delete 2>/dev/null

# --- Offsite --------------------------------------------------------------
if [[ "$LOCAL_ONLY" == no && -f "$SECRETS/backup.env" ]]; then
    set -a; . "$SECRETS/backup.env"; set +a
    if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
        export RESTIC_PASSWORD_FILE="$SECRETS/restic-password"

        restic cat config >/dev/null 2>&1 || {
            log "Initialising the repository."
            restic init >/dev/null 2>&1 || oops "restic init failed."
        }

        if restic backup --quiet \
             --tag ai-workstation \
             --exclude-caches \
             "$BACKUP_DIR" "$SECRETS" "$GAMES_DIR" 2>&1 | sed 's/^/    /'; then
            log "Offsite snapshot written."
        else
            oops "restic backup failed."
        fi

        # Retention: enough daily history to catch a slow-burning problem,
        # enough monthly to recover from one noticed late.
        restic forget --quiet --prune \
            --keep-daily 7 --keep-weekly 4 --keep-monthly 6 >/dev/null 2>&1 \
            || log "restic forget reported a problem (not fatal)."
    else
        log "No RESTIC_REPOSITORY set. Local only."
    fi
else
    log "Offsite skipped."
fi

# --- Resume Minecraft -----------------------------------------------------
# Must happen whatever went wrong above, or the world silently stops saving.
if [[ "$mc_paused" == yes ]]; then
    kubectl -n "$GAMES_NS" exec deploy/minecraft -- rcon-cli save-on >/dev/null 2>&1 \
        && log "Minecraft saving resumed." \
        || oops "COULD NOT RE-ENABLE MINECRAFT SAVING. Run: games rcon -> save-on"
fi

if (( fail )); then
    log "Backup finished WITH ERRORS."
    exit 1
fi
log "Backup complete."
BACKUP_EOF
sudo chmod +x /usr/local/bin/platform-backup

sudo tee /usr/local/bin/platform-restore >/dev/null <<RESTORE_EOF
#!/usr/bin/env bash
# Inspect and restore from backups.
#
#   platform-restore list                 offsite snapshots
#   platform-restore local                local dumps
#   platform-restore check                verify repository integrity
#   platform-restore fetch <id> <dir>     restore a snapshot to a directory
#   platform-restore postgres <file.gz>   load a dump back into the cluster
#
# Restoring Postgres is destructive: the dump is taken with --clean, so it
# drops and recreates every object it contains. Read the file first.
set -uo pipefail

SECRETS="$SECRETS"
BACKUP_DIR="$BACKUP_DIR"
K8S_NS="$K8S_NS"
export KUBECONFIG="$KUBECONFIG"
RESTORE_EOF

sudo tee -a /usr/local/bin/platform-restore >/dev/null <<'RESTORE_EOF'

load_env() {
    [[ -f "$SECRETS/backup.env" ]] || { echo "No offsite target configured." >&2; exit 1; }
    set -a; . "$SECRETS/backup.env"; set +a
    export RESTIC_PASSWORD_FILE="$SECRETS/restic-password"
}

case "${1:-list}" in
  list)
    load_env; restic snapshots --compact
    ;;
  local)
    echo "=== Postgres dumps ==="
    ls -lh "$BACKUP_DIR/postgres" 2>/dev/null | tail -n +2 | awk '{print "  " $9, $5, $6, $7}'
    echo "=== Workflow exports ==="
    ls -lh "$BACKUP_DIR/workflows" 2>/dev/null | tail -n +2 | awk '{print "  " $9, $5, $6, $7}'
    ;;
  check)
    # A backup nobody has verified is a hope. This reads a 5% sample of the
    # actual data rather than only checking the metadata.
    load_env; restic check --read-data-subset=5%
    ;;
  fetch)
    [[ $# -ge 3 ]] || { echo "usage: platform-restore fetch <snapshot-id> <target-dir>" >&2; exit 1; }
    load_env; restic restore "$2" --target "$3"
    echo "Restored to $3"
    ;;
  postgres)
    [[ $# -ge 2 ]] || { echo "usage: platform-restore postgres <file.sql.gz>" >&2; exit 1; }
    [[ -f "$2" ]] || { echo "No such file: $2" >&2; exit 1; }
    echo "This DROPS and recreates every database in the dump."
    read -rp "Type RESTORE to continue: " c
    [[ "$c" == "RESTORE" ]] || { echo "Aborted."; exit 1; }
    gunzip -c "$2" | kubectl -n "$K8S_NS" exec -i deploy/postgres -- psql -U postgres
    echo "Restored. Restart the dependents so they reconnect:"
    echo "  kubectl -n $K8S_NS rollout restart deploy/litellm deploy/n8n"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
RESTORE_EOF
sudo chmod +x /usr/local/bin/platform-restore

ok "Installed platform-backup and platform-restore."

# ---------------------------------------------------------------------------
section "Nightly timer"

sudo tee /etc/systemd/system/platform-backup.service >/dev/null <<EOF
[Unit]
Description=Back up the platform
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
User=$USER
Environment=KUBECONFIG=$KUBECONFIG
ExecStart=/usr/local/bin/platform-backup
EOF

sudo tee /etc/systemd/system/platform-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly platform backup

[Timer]
# 03:30, when nothing else is scheduled. RandomizedDelaySec avoids hitting the
# provider at the same second as everyone else's cron job.
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=15m
# If the machine was off or in Windows at 03:30, run at the next opportunity
# rather than skipping the night entirely.
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now platform-backup.timer >/dev/null
ok "Nightly backup enabled at 03:30."
systemctl list-timers platform-backup.timer --no-pager 2>/dev/null | sed -n '1,2p' | sed 's/^/    /'

# ---------------------------------------------------------------------------
section "First run"

if kubectl get nodes >/dev/null 2>&1; then
    info "Running a backup now to prove it works."
    first_run_args=()
    [[ "$OFFSITE" == yes ]] || first_run_args+=(--local)
    /usr/local/bin/platform-backup "${first_run_args[@]}" 2>&1 | sed 's/^/    /' || \
        warn "The first run reported errors; see above."
else
    warn "Cluster unreachable, skipping the first run. Start k3s and run:"
    warn "    platform-backup"
fi

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
      platform-backup           run one now
      platform-restore list     what is in the offsite repository
      platform-restore local    what is on this drive
      platform-restore check    verify the repository actually reads back

EOF

if [[ "$FIRST_RUN" == yes ]]; then
    cat <<EOF
  ============================================================
   WRITE THIS DOWN SOMEWHERE THAT IS NOT THIS MACHINE
  ============================================================

   restic repository password:

       ${RESTIC_PW}

  Everything in the offsite repository is encrypted with that password
  before it leaves the house, which is what makes it safe to keep on
  someone else's storage. It also means the provider cannot help you if
  you lose it, and neither can I.

  The password is stored at $RESTIC_PW_FILE and is itself
  inside the backup - which is circular and therefore worth nothing on
  its own. A password manager on another device, or paper in a drawer,
  breaks the circle. Do it now; it takes a minute.

  The same applies to $SECRETS/n8n-encryption-key,
  which is what makes every credential n8n stores readable.

EOF
fi

if [[ "$OFFSITE" != yes ]]; then
    cat <<EOF
  Offsite is not configured yet, so right now this protects you against
  mistakes but not against the drive failing. Fill in one provider:

      sudoedit $BACKUP_ENV

  Backblaze B2 is the cheapest fit - the data worth keeping here is a few
  GB, so expect well under 50 kr a month. Then re-run this script.

EOF
fi

cat <<'EOF'
  One habit worth forming: run 'platform-restore check' monthly, and
  actually restore something once. An untested backup is a hope, and the
  failure modes that matter only show up on the way back in.

  Details and a full disaster-recovery walkthrough: reference/backups.md
EOF
