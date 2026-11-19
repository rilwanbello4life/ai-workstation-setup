#!/usr/bin/env bash
# Phase 21 - the GPU queue: fair sharing, per-user profiles, batch jobs.
#
# The problem: several people share one 16 GB card. The failure mode is not
# that requests are slow, it is that five arriving at once each allocate KV
# cache and some fail partway through a generation. LiteLLM's
# max_parallel_requests caps concurrency but REJECTS the overflow with a 429
# rather than holding it, and it has no idea what the GPU is doing.
#
# This adds a queue in front that does three things LiteLLM cannot:
#
#   * holds a request instead of refusing it, with per-person fairness
#   * gives each person a system prompt and a set of skills
#   * admits work based on live GPU state, so a quiet card takes more
#
# LiteLLM stays the authority on authorisation. The queue forwards the
# caller's own key to it untouched, so budgets, rate limits, model
# allowlists and spend logging are unchanged, and 'friends add' still works
# exactly as before.
#
# Background: reference/gpu-queue.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root
require_k3s

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="${GITOPS_DIR:-/srv/gitops}"
QUEUE_DIR="$PLATFORM_DIR/gpu-queue"
SKIP_BUILD=no

while (( $# )); do
    case "$1" in
        --skip-build) SKIP_BUILD=yes; shift ;;
        -y|--yes)     shift ;;
        -h|--help)    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

kubectl -n "$K8S_NS" get deploy litellm >/dev/null 2>&1 || \
    die "LiteLLM not found. Run ./03-platform.sh first."
[[ -d "$GITOPS_DIR/source" ]] || \
    die "No GitOps repo at $GITOPS_DIR. Run ./08-gitops.sh --apply first."

HOST_IP="$(ip -4 addr show cni0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
[[ -n "$HOST_IP" ]] || HOST_IP="10.42.0.1"
export HOST_IP

# ---------------------------------------------------------------------------
section "Schema"

info "Applying the queue schema to the 'litellm' database."
if kubectl -n "$K8S_NS" exec -i deploy/postgres -- \
     psql -U postgres -d litellm -v ON_ERROR_STOP=1 \
     < "$K8S_DIR/21-queue-schema.sql" >/dev/null 2>&1; then
    ok "Profiles, skills and the job table are in place."
else
    warn "Schema application reported errors. Re-run with output visible:"
    warn "  kubectl -n $K8S_NS exec -i deploy/postgres -- \\"
    warn "    psql -U postgres -d litellm < $K8S_DIR/21-queue-schema.sql"
fi

# ---------------------------------------------------------------------------
section "GPU probe"

# The queue runs in a pod and has to know what the card is doing. There is no
# device plugin here - Strata owns the GPU directly on the host - so the
# answer has to come from something running outside the cluster.
sudo install -m 755 "$HERE/gpu-probe/gpu-probe.py" /usr/local/bin/gpu-probe

PROBE_UNIT=/etc/systemd/system/gpu-probe.service
if [[ -f "$PROBE_UNIT" ]]; then
    ok "gpu-probe.service already installed."
else
    sudo tee "$PROBE_UNIT" >/dev/null <<EOF
[Unit]
Description=Report GPU utilisation and free VRAM as JSON on 127.0.0.1:8101
After=multi-user.target

[Service]
Type=simple
User=$USER
ExecStart=/usr/bin/python3 /usr/local/bin/gpu-probe
Restart=always
RestartSec=5
# Read-only by construction: it shells out to nvidia-smi and serves the
# result. Nothing it can be asked to do changes anything.
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now gpu-probe.service
    ok "gpu-probe serving on 127.0.0.1:8101"
fi

if curl -fsS --max-time 5 http://127.0.0.1:8101/gpu >/dev/null 2>&1; then
    PROBE_SAY="$(curl -fsS http://127.0.0.1:8101/gpu | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("available"):
    print(str(d.get("memory_free_mb", 0)) + " MB free, "
          + str(d.get("utilization_pct", 0)) + "% busy")
else:
    print(str(d.get("reason", "unavailable")))
' 2>/dev/null)"
    ok "Probe responding: ${PROBE_SAY:-ok}"
else
    warn "Probe not responding. The queue will fall back to static limits."
fi

# ---------------------------------------------------------------------------
section "Host bridges"

# ai-model-bridge forwards the cni0 address into loopback for the model
# servers. The queue needs two more: the probe it just started, and ComfyUI
# for batch renders.
BRIDGE_UNIT=/etc/systemd/system/ai-model-bridge.service
if grep -q 'TCP-LISTEN:8101' "$BRIDGE_UNIT" 2>/dev/null; then
    ok "Bridge already covers 8101 and 8188."
else
    sudo tee "$BRIDGE_UNIT" >/dev/null <<EOF
[Unit]
Description=Forward cluster-facing ports to loopback model servers
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
# One socat per port. Binding only to the cni0 address keeps these services
# invisible to the LAN while letting pods reach them.
#   8080 Strata   8081 llama.cpp   8100 voice
#   8101 gpu-probe (admission)     8188 ComfyUI (batch jobs)
ExecStart=/bin/sh -c '\\
  socat TCP-LISTEN:8080,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8080 & \\
  socat TCP-LISTEN:8081,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8081 & \\
  socat TCP-LISTEN:8100,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8100 & \\
  socat TCP-LISTEN:8101,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8101 & \\
  socat TCP-LISTEN:8188,bind=$HOST_IP,fork,reuseaddr TCP:127.0.0.1:8188 & \\
  wait'
ExecStop=/usr/bin/pkill -f "socat TCP-LISTEN:(8080|8081|8100|8101|8188)"

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart ai-model-bridge.service
    ok "Bridge now covers 8080, 8081, 8100, 8101 and 8188."
fi

apply_manifest "$K8S_DIR/06-gpu-probe.yaml"
ok "Cluster names: gpu-probe and comfyui on $K8S_NS"

sudo mkdir -p "$QUEUE_DIR/outputs"
sudo chown -R "$USER:$USER" "$QUEUE_DIR"
ok "Job output directory: $QUEUE_DIR/outputs"

# ---------------------------------------------------------------------------
section "Build and deploy"

# The chart ships with the kit; copy it into the GitOps repo if it is not
# there yet, then let the pipeline from phase 20 do the deploying. This is
# the first component in the build that is delivered the way everything
# after it should be.
if [[ ! -d "$GITOPS_DIR/source/gpu-queue" ]]; then
    cp -r "$HERE/gitops/source/gpu-queue" "$GITOPS_DIR/source/"
    ok "Copied the gpu-queue chart into the GitOps repo."
fi
if [[ ! -f "$GITOPS_DIR/apps/gpu-queue.yaml" ]]; then
    cp "$HERE/gitops/apps/gpu-queue.yaml" "$GITOPS_DIR/apps/"
    ok "Copied the gpu-queue Application."
fi

if [[ "$SKIP_BUILD" == yes ]]; then
    warn "Skipping the image build as asked."
else
    have gitops || die "The 'gitops' command is missing. Re-run ./08-gitops.sh --apply."
    info "Building the image and importing it into k3s."
    gitops build gpu-queue || die "Build failed."
    gitops commit -m "gpu-queue: initial deploy" || warn "Commit reported a problem."
fi

# The root Application applies apps/gpu-queue.yaml, which has auto-sync on,
# so normally nothing more is needed. Nudge it rather than waiting 30s.
gitops sync root >/dev/null 2>&1 || true
sleep 5
gitops sync gpu-queue >/dev/null 2>&1 || true

wait_for_deploy gpu-queue "$K8S_NS" 180 || \
    warn "gpu-queue is not ready. kubectl -n $K8S_NS logs deploy/gpu-queue"

# ---------------------------------------------------------------------------
section "Loopback access"

FWD_UNIT=/etc/systemd/system/platform-forward.service
if grep -q '4100:4100' "$FWD_UNIT" 2>/dev/null; then
    ok "platform-forward already publishes 4100."
else
    sudo sed -i \
      "s|  wait'|  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/gpu-queue 4100:4100 \& \\\\\n  wait'|" \
      "$FWD_UNIT"
    sudo systemctl daemon-reload
    sudo systemctl restart platform-forward.service
    ok "Forwarding 4100 to loopback."
fi
sleep 3

# ---------------------------------------------------------------------------
section "The queue command"

sudo tee /usr/local/bin/queue >/dev/null <<'QUEUE_EOF'
#!/usr/bin/env bash
# Inspect and steer the GPU queue.
#
#   queue status [--brief]    depth, in-flight work and live GPU state
#   queue list [n]            recent jobs, newest first
#   queue cancel <id>         cancel a job that has not started
#   queue drain               finish in-flight work, admit nothing new
#   queue resume              start admitting again
#   queue watch               status, refreshed every 2s
#
# ai-pause calls 'queue drain' first, so a friend mid-request gets an answer
# rather than a dropped connection.
set -uo pipefail

GATEWAY="${QUEUE_GATEWAY:-http://127.0.0.1:4100}"
SECRETS="${SECRETS:-/srv/platform/secrets}"
MASTER="sk-$(sudo cat "$SECRETS/litellm-master-key" 2>/dev/null)"

api() {
  local method="$1" path="$2"; shift 2
  curl -fsS --max-time 15 -X "$method" "${GATEWAY}${path}" \
    -H "Authorization: Bearer ${MASTER}" \
    -H "Content-Type: application/json" "$@"
}

# Every embedded Python block below builds strings by concatenation rather
# than with f-strings. Inside a single-quoted shell heredoc a nested quote
# has to be backslash-escaped, and an escaped quote inside an f-string
# expression is a syntax error. Concatenation sidesteps the whole problem,
# and matches how 06-friends.sh already does this.
show_status() {
  api GET /queue/status | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  queue not responding"); sys.exit(1)

g   = d.get("gpu") or {}
lim = d.get("limits") or {}
fl  = d.get("inflight") or {}

if d.get("draining"):
    print("  DRAINING - no new work is being admitted")

heavy = fl.get("heavy", 0)
light = fl.get("light", 0)
print("  in flight    " + str(heavy) + " heavy, " + str(light) + " light"
      + "   (limits: " + str(lim.get("heavy")) + " heavy, "
      + str(lim.get("light_now")) + " light ["
      + str(lim.get("light_floor")) + "-" + str(lim.get("light_ceiling")) + "])")

queued = d.get("queued", 0)
line = "  queued       " + str(queued)
if queued:
    line += ", oldest waiting " + str(round(d.get("oldest_wait_ms", 0) / 1000)) + "s"
print(line)

if g.get("available"):
    print("  gpu          " + str(g.get("utilization_pct")) + "% busy, "
          + str(g.get("memory_free_mb")) + " MB free of "
          + str(g.get("memory_total_mb")) + " MB")
else:
    print("  gpu          unavailable (" + str(g.get("reason"))
          + ") - using static limits")

print("  profiles     " + str(d.get("store")))

by = fl.get("by_user") or {}
qb = d.get("queued_by_user") or {}
for who in sorted(set(by) | set(qb)):
    print("    " + who.ljust(14) + " " + str(by.get(who, 0)) + " running, "
          + str(qb.get(who, 0)) + " queued")
'
}

case "${1:-status}" in
  status)
    [[ "${2-}" == "--brief" ]] || echo "=== GPU queue ==="
    show_status
    ;;

  watch)
    while true; do
      clear; echo "=== GPU queue ===  $(date '+%H:%M:%S')"
      show_status; sleep 2
    done
    ;;

  list)
    api GET "/queue/jobs?limit=${2:-25}" | python3 -c '
import json, sys

rows = json.load(sys.stdin)
if not rows:
    print("  No jobs recorded yet."); sys.exit(0)

def secs(v):
    return "-" if v is None else str(round(v / 1000.0, 1)) + "s"

print("  " + "ID".rjust(6) + "  " + "WHO".ljust(12) + " " + "KIND".ljust(8)
      + " " + "W".ljust(6) + " " + "STATUS".ljust(10) + " "
      + "WAIT".rjust(7) + " " + "RAN".rjust(8))

for r in rows:
    print("  " + str(r.get("id", "")).rjust(6) + "  "
          + str(r.get("key_alias") or "-")[:12].ljust(12) + " "
          + str(r.get("kind", ""))[:8].ljust(8) + " "
          + str(r.get("weight", ""))[:6].ljust(6) + " "
          + str(r.get("status", ""))[:10].ljust(10) + " "
          + secs(r.get("wait_ms")).rjust(7) + " "
          + secs(r.get("duration_ms")).rjust(8))
    if r.get("error"):
        print("          " + str(r.get("error"))[:88])
'
    ;;

  cancel)
    [[ $# -ge 2 ]] || { echo "usage: queue cancel <id>" >&2; exit 1; }
    api DELETE "/v1/jobs/$2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("cancelled"):
    print("  cancelled")
else:
    print("  not cancelled: " + str(d.get("note")))
'
    ;;

  drain)
    api POST /queue/drain | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  draining. " + str(d.get("inflight", 0)) + " in flight, "
      + str(d.get("queued", 0)) + " still queued.")
print("  Those will finish; nothing new is admitted until: queue resume")
'
    ;;

  resume)
    api POST /queue/resume >/dev/null && echo "  admitting again."
    ;;

  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
QUEUE_EOF
sudo chmod +x /usr/local/bin/queue
ok "Installed 'queue'."

# ---------------------------------------------------------------------------
section "Tailnet endpoint"

# 8447 was pointed at LiteLLM by 06-friends.sh. Move it to the queue so
# shared access gets the queueing behaviour. The address friends already
# have does not change, so no key has to be reissued and nothing they have
# configured breaks - only what answers behind it moves.
if ! have tailscale || ! tailscale status >/dev/null 2>&1; then
    info "Tailscale not connected; nothing to repoint."
elif ! curl -fsS --max-time 5 http://127.0.0.1:4100/healthz >/dev/null 2>&1; then
    warn "Queue is not answering on 4100. Leaving 8447 pointed at LiteLLM."
    warn "Re-run this script once 'kubectl -n $K8S_NS get deploy gpu-queue' is ready."
elif tailscale serve status 2>/dev/null | grep -q '127.0.0.1:4100'; then
    ok "8447 already points at the queue."
else
    sudo tailscale serve --bg --https=8447 http://127.0.0.1:4100 >/dev/null 2>&1 \
        && ok "8447 now points at the queue instead of LiteLLM." \
        || warn "tailscale serve failed. Check: tailscale serve status"
fi

TS_HOST="$(tailscale status --json 2>/dev/null \
           | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[[ -n "$TS_HOST" ]] && info "Endpoint: https://${TS_HOST}:8447/v1"

# ---------------------------------------------------------------------------
section "Verification"

if curl -fsS --max-time 10 http://127.0.0.1:4100/healthz >/dev/null 2>&1; then
    ok "Queue responding on 127.0.0.1:4100"
    queue status 2>/dev/null || true
else
    warn "Queue not responding yet on 4100. Check:"
    warn "  kubectl -n $K8S_NS logs deploy/gpu-queue --tail=50"
fi

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
  The queue is the front door now. LiteLLM is still the authority on who may
  do what - the queue forwards each caller's own key to it - but requests
  wait their turn instead of being refused.

      queue status          depth, in-flight work, live GPU state
      queue watch           the same, refreshed
      queue list            recent jobs with wait and run times
      queue drain           finish current work, stop admitting

  Per-person configuration, through the command you already use:

      friends profile alice               show it
      friends profile alice --edit        edit the system prompt
      friends profile alice --concurrent 2 --priority 50
      friends skills list                 what exists
      friends skills grant alice sql      give someone a skill

  How admission actually behaves:

      one heavy job at a time     xhigh reasoning, or a batch render
      light jobs 2 to 4           rises while the card is under 50% busy
                                  with VRAM to spare, falls back when not
      per person                  max_concurrent, default 1

  So a quiet GPU accepts more work and a loaded one does not, which is the
  behaviour you wanted: nobody waits unnecessarily, and nothing piles onto
  a card that is already full.

  Batch jobs do not hold a connection:

      curl -X POST http://127.0.0.1:4100/v1/jobs \\
        -H "Authorization: Bearer \$KEY" \\
        -d '{"kind":"comfyui","workflow":{...}}'

  Next: ./06-friends.sh if you have not run it, to point tailscale at 4100
  and issue keys.
EOF
