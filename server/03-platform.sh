#!/usr/bin/env bash
# Phase 14 - the platform: Postgres, the LiteLLM gateway, n8n and Open WebUI.
#
# LiteLLM is the important one. It is the only place per-user identity exists,
# and it turns "expose my models" from handing out an unauthenticated GPU into
# handing out a revocable key with a spend ceiling and a rate limit.
#
# Everything speaks to models through it, including n8n and Open WebUI, so one
# config change switches what the whole platform talks to.
#
# Open WebUI moves here from the user systemd unit that
# ubuntu/08-remote-access.sh created; user units stop at logout.
#
# Background: reference/server-architecture.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root
require_k3s
require_platform_storage

while (( $# )); do
    case "$1" in
        -y|--yes)  shift ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

have envsubst || { info "Installing gettext-base for envsubst."; sudo apt-get install -y gettext-base >/dev/null; }

# ---------------------------------------------------------------------------
section "Credentials"

# Secrets are generated once and persisted to /srv so re-running this script
# does not invalidate keys already handed to clients, and so the n8n
# encryption key - which decrypts every stored credential - is never rotated
# by accident.
PG_PASSWORD="$(secret_file "$SECRETS/postgres-password" 24)"
N8N_DB_PASSWORD="$(secret_file "$SECRETS/n8n-db-password" 24)"
N8N_ENCRYPTION_KEY="$(secret_file "$SECRETS/n8n-encryption-key" 32)"
LITELLM_MASTER_KEY="sk-$(secret_file "$SECRETS/litellm-master-key" 24)"
LITELLM_SALT_KEY="$(secret_file "$SECRETS/litellm-salt-key" 32)"
WEBUI_SECRET_KEY="$(secret_file "$SECRETS/openwebui-secret-key" 32)"

ok "Credentials loaded from $SECRETS (created on first run)."
warn "Back up $SECRETS/n8n-encryption-key. Losing it makes every stored"
warn "n8n credential permanently unreadable."

kubectl -n "$K8S_NS" create secret generic postgres-credentials \
    --from-literal=password="$PG_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$K8S_NS" create secret generic n8n-credentials \
    --from-literal=db-password="$N8N_DB_PASSWORD" \
    --from-literal=encryption-key="$N8N_ENCRYPTION_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$K8S_NS" create secret generic litellm-credentials \
    --from-literal=master-key="$LITELLM_MASTER_KEY" \
    --from-literal=salt-key="$LITELLM_SALT_KEY" \
    --from-literal=database-url="postgresql://litellm:${PG_PASSWORD}@postgres:5432/litellm" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$K8S_NS" create secret generic openwebui-credentials \
    --from-literal=secret-key="$WEBUI_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

ok "Secrets applied to the cluster."

# ---------------------------------------------------------------------------
section "Postgres"

apply_manifest "$K8S_DIR/10-postgres.yaml"
# 360s, not 180s. The pod's own startupProbe allows 300s for a first boot
# that has to run initdb, so a 180s wait here reports a failure while the
# cluster is still legitimately starting - and the scripts that follow then
# refuse to run against a database that was about to be fine.
wait_for_deploy postgres "$K8S_NS" 360 || die "Postgres did not start."

# Three logical databases in one server. LiteLLM and n8n each get their own
# role; the agent prompt store lives in the litellm database alongside its
# own tables, since the two are always queried together.
info "Creating databases and roles."
kubectl -n "$K8S_NS" exec deploy/postgres -- psql -U postgres -v ON_ERROR_STOP=0 -c "
    DO \$\$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'litellm') THEN
            CREATE ROLE litellm LOGIN PASSWORD '${PG_PASSWORD}';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'n8n') THEN
            CREATE ROLE n8n LOGIN PASSWORD '${N8N_DB_PASSWORD}';
        END IF;
    END \$\$;
" >/dev/null 2>&1 || warn "Role creation reported an issue; continuing."

for db in litellm n8n; do
    if kubectl -n "$K8S_NS" exec deploy/postgres -- \
         psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null | grep -q 1; then
        ok "Database '$db' exists."
    else
        kubectl -n "$K8S_NS" exec deploy/postgres -- \
            psql -U postgres -c "CREATE DATABASE $db OWNER $db" >/dev/null 2>&1 \
            && ok "Created database '$db'." \
            || warn "Could not create database '$db'."
    fi
done

# ---------------------------------------------------------------------------
section "LiteLLM gateway"

apply_manifest "$K8S_DIR/11-litellm.yaml"
wait_for_deploy litellm "$K8S_NS" 240 || \
    warn "LiteLLM is not ready. It may still be running database migrations."

# ---------------------------------------------------------------------------
section "n8n"

apply_manifest "$K8S_DIR/12-n8n.yaml"
wait_for_deploy n8n "$K8S_NS" 240 || \
    warn "n8n is not ready. Check: kubectl -n $K8S_NS logs deploy/n8n"

# ---------------------------------------------------------------------------
section "Open WebUI"

# Retire the user unit from ubuntu/08-remote-access.sh so the two do not both
# answer on port 3000.
if systemctl --user is-enabled open-webui.service >/dev/null 2>&1; then
    info "Disabling the old user-level Open WebUI unit."
    systemctl --user disable --now open-webui.service 2>/dev/null || true
    ok "Disabled; the cluster now serves port 3000."
fi

apply_manifest "$K8S_DIR/13-open-webui.yaml"
wait_for_deploy open-webui "$K8S_NS" 240 || \
    warn "Open WebUI is not ready. Check: kubectl -n $K8S_NS logs deploy/open-webui"

# ---------------------------------------------------------------------------
section "Loopback access"

# Services are ClusterIP only. Rather than an ingress for each, a single
# systemd unit port-forwards the three that humans use to 127.0.0.1, which
# keeps them compatible with the existing tailscale serve mapping.
FWD_UNIT=/etc/systemd/system/platform-forward.service
if [[ -f "$FWD_UNIT" ]]; then
    ok "platform-forward already installed."
else
    sudo tee "$FWD_UNIT" >/dev/null <<EOF
[Unit]
Description=Expose platform services on loopback
After=k3s.service
Wants=k3s.service

[Service]
Type=simple
User=$USER
Environment=KUBECONFIG=$HOME/.kube/config
# Three forwards in one unit. --address 127.0.0.1 is the default but stated
# explicitly: binding 0.0.0.0 here would put an unauthenticated gateway on
# the LAN.
ExecStart=/bin/sh -c '\
  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/litellm 4000:4000 & \
  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/n8n 5678:5678 & \
  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/open-webui 3000:3000 & \
  wait'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now platform-forward.service
    ok "Forwarding 4000, 5678 and 3000 to loopback."
fi

sleep 3

# ---------------------------------------------------------------------------
section "Verification"

kubectl -n "$K8S_NS" get pods -o wide --no-headers | sed 's/^/    /'

echo
for svc in "LiteLLM:4000/health/liveliness" "n8n:5678/healthz" "Open WebUI:3000/health"; do
    name="${svc%%:*}"; path="${svc#*:}"
    if curl -fsS --max-time 5 "http://127.0.0.1:${path}" >/dev/null 2>&1; then
        ok "$name responding."
    else
        warn "$name not responding yet on 127.0.0.1:${path%%/*}."
    fi
done

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
  Gateway master key (admin; do not give this to anyone):

      ${LITELLM_MASTER_KEY}

  Stored at $SECRETS/litellm-master-key

  URLs:

      LiteLLM admin     http://127.0.0.1:4000/ui
      LiteLLM API       http://127.0.0.1:4000/v1
      n8n               http://127.0.0.1:5678
      Open WebUI        http://127.0.0.1:3000

  First steps:

      1. Open n8n and create the owner account.
      2. Open Open WebUI and create the admin account (first account wins).
      3. Test the gateway:

         curl http://127.0.0.1:4000/v1/models \\
           -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

  The gateway exposes role aliases rather than separate models, because Strata
  serves one pack at a time:

      brain     the resident pack at reasoning_effort xhigh
      worker    the same pack at reasoning_effort low
      checker   the small GGUF on llama.cpp - a genuinely different model
      strata    passthrough
      local     passthrough to llama.cpp

  Start a model before expecting any of them to answer:

      strata launch --preset <name>

  Next: ./04-agents.sh
EOF
