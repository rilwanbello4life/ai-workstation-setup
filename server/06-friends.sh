#!/usr/bin/env bash
# Phase 17 - share model access with friends (optional).
#
# Two independent decisions, routinely confused:
#
#   Authorisation - what a request may do once it arrives. Settled: LiteLLM
#                   virtual keys, per person, with a budget, a rate limit and
#                   a model allowlist. This script builds it.
#
#   Transport     - how the request reaches your house. YOUR DECISION, and
#                   deliberately left open. This script sets up the Tailscale
#                   path because it cannot be accidentally world-readable. The
#                   Cloudflare Tunnel path is documented in
#                   reference/sharing-with-friends.md and is NOT installed.
#
# Nothing here exposes anything to the public internet. 'tailscale funnel' is
# never used and should not be added.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root
require_k3s

ASSUME_YES=0
while (( $# )); do
    case "$1" in
        -y|--yes)  ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

kubectl -n "$K8S_NS" get deploy litellm >/dev/null 2>&1 || \
    die "LiteLLM not found. Run ./03-platform.sh first."

# ---------------------------------------------------------------------------
section "Transport"

if ! have tailscale; then
    warn "Tailscale is not installed. Run ubuntu/07-remote-access.sh first."
    warn "Virtual keys will still be created; nobody will be able to reach them."
elif ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale is installed but not connected. Run: sudo tailscale up"
else
    # Port 8447, continuing the map in reference/ports.md. HTTPS terminates at
    # Tailscale using its own certificate, so friends get a real TLS endpoint
    # without any certificate management here.
    #
    # What sits behind 8447 depends on what is installed. Once the GPU queue
    # exists it should be the front door, because it holds a request when the
    # card is busy where LiteLLM would refuse it with a 429. Until then, point
    # straight at LiteLLM. Either way the address friends are given is the
    # same, so moving between them costs nobody a reissued key.
    #
    # This probes rather than assuming, because 06 and 09 can be run in
    # either order, and re-running one must not leave 8447 pointing at
    # something that is not listening.
    if curl -fsS --max-time 3 http://127.0.0.1:4100/healthz >/dev/null 2>&1; then
        UPSTREAM=4100; UPSTREAM_NAME="GPU queue"
    else
        UPSTREAM=4000; UPSTREAM_NAME="LiteLLM gateway"
    fi

    if tailscale serve status 2>/dev/null | grep -q "127.0.0.1:${UPSTREAM}"; then
        ok "Already serving the $UPSTREAM_NAME on :8447."
    else
        info "Publishing the $UPSTREAM_NAME to your tailnet on :8447."
        sudo tailscale serve --bg --https=8447 "http://127.0.0.1:${UPSTREAM}" >/dev/null 2>&1 \
            && ok "Serving." \
            || warn "tailscale serve failed. Check: tailscale serve status"
        [[ "$UPSTREAM" == 4000 ]] && \
            info "Run ./09-gpu-queue.sh to put the queue in front; this repoints itself."
    fi

    TS_HOST="$(tailscale status --json 2>/dev/null \
               | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
    [[ -n "$TS_HOST" ]] && info "Endpoint: https://${TS_HOST}:8447"
fi

cat <<'EOF'

  This is reachable by your tailnet only. To let a specific person in:

      Tailscale admin console > Machines > this host > Share
      Generate an invite link, send it to one person, they accept.

  Revoking is the same screen. Nothing is published to the internet, and
  'tailscale funnel' - which would publish it - is intentionally not used.

  If you would rather friends needed nothing installed, the Cloudflare Tunnel
  plus Access alternative is written up, with its risks, in
  reference/sharing-with-friends.md. It is not installed by this script.
EOF

# ---------------------------------------------------------------------------
section "friends command"

sudo tee /usr/local/bin/friends >/dev/null <<'FRIENDS_EOF'
#!/usr/bin/env bash
# Manage per-person API keys on the LiteLLM gateway.
#
#   friends add <name> [--budget N] [--rpm N] [--models a,b]
#   friends list                 keys, budgets and spend
#   friends spend                usage per person
#   friends disable <name>       revoke, effective immediately
#   friends remove <name>        delete the key
#
#   friends profile <name> [--edit] [--concurrent N] [--priority N]
#                                per-person system prompt and queue limits
#   friends skills list | grant <name> <skill> | revoke <name> <skill>
#                                reusable prompt fragments
#
# Keys are revoked on the next request; LiteLLM does not cache the decision.
# An in-flight generation finishes and nothing new starts.
set -euo pipefail

SECRETS="${SECRETS:-/srv/platform/secrets}"
GATEWAY="${GATEWAY:-http://127.0.0.1:4000}"
MASTER="sk-$(sudo cat "$SECRETS/litellm-master-key")"
K8S_NS="${K8S_NS:-platform}"

# Profiles and skills live in the same 'litellm' database as the keys, but
# they are the queue's tables, not LiteLLM's - LiteLLM has no concept of a
# per-person system prompt. There is no HTTP API for them, so these go
# straight to Postgres.
psql_q() {
  kubectl -n "$K8S_NS" exec -i deploy/postgres -- \
    psql -U postgres -d litellm -v ON_ERROR_STOP=1 "$@"
}

# -A -t gives unaligned, headerless output: one record per line, columns
# separated by the -F string. Easy to read back with while/IFS.
psql_rows() { psql_q -A -t -F '|' -c "$1" 2>/dev/null; }

sql_lit() { printf "%s" "$1" | sed "s/'/''/g"; }

api() {
  local method="$1" path="$2"; shift 2
  curl -fsS -X "$method" "${GATEWAY}${path}" \
    -H "Authorization: Bearer ${MASTER}" \
    -H "Content-Type: application/json" "$@"
}

case "${1:-list}" in
  add)
    [[ $# -ge 2 ]] || { echo "usage: friends add <name> [--budget N] [--rpm N] [--models a,b]" >&2; exit 1; }
    name="$2"; shift 2
    # Defaults chosen for someone experimenting, not working. 'brain' is
    # excluded on purpose: one xhigh reasoning call can hold the GPU for
    # minutes, and a loop of them takes your own assistant offline.
    budget=50; rpm=10; tpm=100000; models='["worker","local","checker"]'
    while (( $# )); do
      case "$1" in
        --budget) budget="$2"; shift 2 ;;
        --rpm)    rpm="$2";    shift 2 ;;
        --tpm)    tpm="$2";    shift 2 ;;
        --models) models="$(printf '%s' "$2" | awk -F, '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"}')"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
      esac
    done
    resp="$(api POST /key/generate -d "{
      \"key_alias\": \"$name\",
      \"models\": $models,
      \"max_budget\": $budget,
      \"rpm_limit\": $rpm,
      \"tpm_limit\": $tpm,
      \"metadata\": {\"friend\": \"$name\"}
    }")"
    key="$(printf '%s' "$resp" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [[ -n "$key" ]] || { echo "Key creation failed:" >&2; echo "$resp" >&2; exit 1; }

    host="$(tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
    base="https://${host:-YOUR-HOST}:8447/v1"
    cat <<MSG

Key created for $name.

  Send them this, and nothing else:

    Base URL:  $base
    API key:   $key
    Models:    $models
    Budget:    $budget    Rate limit: $rpm req/min

    Example:
      curl $base/chat/completions \\
        -H "Authorization: Bearer $key" \\
        -H "Content-Type: application/json" \\
        -d '{"model":"worker","messages":[{"role":"user","content":"hello"}]}'

  It is OpenAI-compatible, so any OpenAI client works by changing base_url.

  Tell them three things up front:
    - It is one GPU. Requests queue behind each other.
    - It disappears without notice - reboots, model swaps, games.
    - Prompts and completions are logged in plaintext and you can read them.

  This key is shown once. Record it now if you need it again; otherwise
  revoke and reissue.

MSG
    ;;

  list)
    api GET "/key/list?return_full_object=true&size=100" \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("Could not parse gateway response."); sys.exit(1)
keys = d.get("keys", d) if isinstance(d, dict) else d
rows = [k for k in keys if isinstance(k, dict) and k.get("key_alias")]
if not rows:
    print("No friend keys yet.  friends add <name>"); sys.exit(0)
header = "NAME".ljust(14) + "SPEND".rjust(9) + "BUDGET".rjust(9)
header += "RPM".rjust(6) + "  " + "MODELS".ljust(28) + "STATUS"
print(header)
for k in sorted(rows, key=lambda r: r.get("key_alias") or ""):
    name = k.get("key_alias") or ""
    models = ",".join(k.get("models") or []) or "all"
    status = "blocked" if k.get("blocked") else "active"
    spend = float(k.get("spend") or 0)
    budget = float(k.get("max_budget") or 0)
    rpm = k.get("rpm_limit") or 0
    line = name.ljust(14) + format(spend, "9.2f") + format(budget, "9.0f")
    line += str(rpm).rjust(6) + "  " + models[:27].ljust(28) + status
    print(line)
'
    ;;

  spend)
    echo "Spend is notional - these are local models. Read it as token volume."
    echo
    kubectl -n "${K8S_NS:-platform}" exec -i deploy/postgres -- \
      psql -U postgres -d litellm -c \
      "SELECT key_alias, round(spend::numeric, 2) AS spend, max_budget,
              to_char(updated_at,'YYYY-MM-DD HH24:MI') AS last_used
       FROM \"LiteLLM_VerificationToken\"
       WHERE key_alias IS NOT NULL ORDER BY spend DESC" 2>/dev/null \
      || echo "Could not read the spend table. Try: friends list"
    ;;

  profile)
    [[ $# -ge 2 ]] || { echo "usage: friends profile <name> [--edit] [--concurrent N] [--priority N] [--allow-heavy yes|no]" >&2; exit 1; }
    name="$2"; shift 2
    esc_name="$(sql_lit "$name")"

    # Create on first touch so there is always a row to edit. The defaults
    # match the schema: one request at a time, no heavy work, ordinary
    # priority. Someone who was never given a profile still works - the
    # queue synthesises these same values - this just makes it editable.
    psql_q -q -c "INSERT INTO user_profiles (key_alias)
                  VALUES ('$esc_name') ON CONFLICT (key_alias) DO NOTHING" >/dev/null 2>&1 \
      || { echo "Could not reach the database. Is Postgres up?" >&2; exit 1; }

    do_edit=no
    while (( $# )); do
      case "$1" in
        --edit)        do_edit=yes; shift ;;
        --concurrent)  psql_q -q -c "UPDATE user_profiles SET max_concurrent=$2, updated_at=now() WHERE key_alias='$esc_name'" >/dev/null; shift 2 ;;
        --priority)    psql_q -q -c "UPDATE user_profiles SET priority=$2, updated_at=now() WHERE key_alias='$esc_name'" >/dev/null; shift 2 ;;
        --max-queued)  psql_q -q -c "UPDATE user_profiles SET max_queue_depth=$2, updated_at=now() WHERE key_alias='$esc_name'" >/dev/null; shift 2 ;;
        --allow-heavy)
          v=FALSE; [[ "$2" == yes || "$2" == true ]] && v=TRUE
          psql_q -q -c "UPDATE user_profiles SET allow_heavy=$v, updated_at=now() WHERE key_alias='$esc_name'" >/dev/null; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
      esac
    done

    if [[ "$do_edit" == yes ]]; then
      tmp="$(mktemp -t friends-profile.XXXXXX)"
      trap 'rm -f "$tmp"' EXIT
      psql_rows "SELECT coalesce(system_prompt,'') FROM user_profiles WHERE key_alias='$esc_name'" > "$tmp"
      before="$(cat "$tmp")"
      "${EDITOR:-nano}" "$tmp"
      after="$(cat "$tmp")"
      if [[ "$before" == "$after" ]]; then
        echo "  Unchanged."
      else
        # Snapshot the outgoing version before overwriting, then bump.
        # Same versioned-history pattern as agent_role_history: a prompt
        # change that made things worse has to be visible and revertible.
        esc_prompt="$(sql_lit "$after")"
        psql_q -q -c "
          INSERT INTO user_profile_history
              (key_alias, system_prompt, skills, version, changed_by, rationale)
            SELECT key_alias, system_prompt, skills, version, 'friends profile --edit',
                   'edited on the host'
            FROM user_profiles WHERE key_alias='$esc_name'
            ON CONFLICT (key_alias, version) DO NOTHING;
          UPDATE user_profiles
             SET system_prompt='$esc_prompt',
                 version = version + 1,
                 updated_at = now(),
                 updated_by = 'friends profile --edit'
           WHERE key_alias='$esc_name';" >/dev/null
        echo "  Updated. The next request picks it up; in-flight ones do not."
      fi
    fi

    echo
    psql_rows "SELECT max_concurrent, priority, max_queue_depth, allow_heavy,
                      coalesce(system_prompt,'')
               FROM user_profiles WHERE key_alias='$esc_name'" \
    | while IFS='|' read -r conc prio depth heavy prompt; do
        echo "  $name"
        echo "    concurrent    $conc at a time"
        echo "    priority      $prio   (lower goes first)"
        echo "    max queued    $depth"
        echo "    heavy work    $heavy   (xhigh reasoning, batch renders)"
        echo "    system prompt ${prompt:-(none)}"
      done

    # Skills are a JSONB array of names on the profile, not a join table.
    granted="$(psql_rows "SELECT string_agg(e, ', ' ORDER BY e)
                          FROM user_profiles p,
                               jsonb_array_elements_text(p.skills) AS e
                          WHERE p.key_alias='$esc_name'")"
    echo "    skills        ${granted:-(none)}"
    echo
    ;;

  skills)
    sub="${2:-list}"
    case "$sub" in
      list)
        echo
        printf "  %-14s %-52s %s\n" NAME DESCRIPTION USED-BY
        # 'p.skills ? s.name' asks whether the name appears as an element of
        # the profile's JSONB array.
        psql_rows "SELECT s.name, coalesce(s.description,''),
                          (SELECT count(*) FROM user_profiles p
                            WHERE p.skills ? s.name)
                   FROM skills s ORDER BY s.name" \
        | while IFS='|' read -r n description used; do
            printf "  %-14s %-52s %s\n" "$n" "${description:0:52}" "$used"
          done
        echo
        echo "  friends skills grant <name> <skill>"
        echo "  friends skills show <skill>"
        echo
        ;;
      show)
        [[ $# -ge 3 ]] || { echo "usage: friends skills show <skill>" >&2; exit 1; }
        body="$(psql_rows "SELECT content FROM skills WHERE name='$(sql_lit "$3")'")"
        [[ -n "$body" ]] || { echo "No skill called '$3'. See: friends skills list" >&2; exit 1; }
        printf '%s\n' "$body" | sed 's/^/  /'
        ;;
      grant|revoke)
        [[ $# -ge 4 ]] || { echo "usage: friends skills $sub <name> <skill>" >&2; exit 1; }
        who="$(sql_lit "$3")"; what="$(sql_lit "$4")"
        exists="$(psql_rows "SELECT 1 FROM skills WHERE name='$what'")"
        [[ -n "$exists" ]] || { echo "No skill called '$4'. See: friends skills list" >&2; exit 1; }
        if [[ "$sub" == grant ]]; then
          # Append only if absent, so granting twice is not an error and
          # does not duplicate the entry.
          psql_q -q -c "
            INSERT INTO user_profiles (key_alias) VALUES ('$who')
              ON CONFLICT (key_alias) DO NOTHING;
            UPDATE user_profiles
               SET skills = skills || to_jsonb('$what'::text), updated_at = now()
             WHERE key_alias='$who' AND NOT (skills ? '$what');" >/dev/null
          echo "  $3 now has '$4'."
        else
          psql_q -q -c "
            UPDATE user_profiles
               SET skills = coalesce(
                     (SELECT jsonb_agg(e) FROM jsonb_array_elements_text(skills) e
                       WHERE e <> '$what'), '[]'::jsonb),
                   updated_at = now()
             WHERE key_alias='$who'" >/dev/null
          echo "  Removed '$4' from $3."
        fi
        ;;
      *) echo "usage: friends skills list|show|grant|revoke" >&2; exit 1 ;;
    esac
    ;;

  disable|remove)
    [[ $# -ge 2 ]] || { echo "usage: friends $1 <name>" >&2; exit 1; }
    action="$1"; name="$2"
    token="$(api GET "/key/list?return_full_object=true&size=100" \
      | python3 -c '
import json, sys
name = sys.argv[1]
d = json.load(sys.stdin)
keys = d.get("keys", d) if isinstance(d, dict) else d
for k in keys:
    if isinstance(k, dict) and k.get("key_alias") == name:
        print(k.get("token") or k.get("key") or ""); break
' "$name")"
    [[ -n "$token" ]] || { echo "No key found for '$name'." >&2; exit 1; }
    if [[ "$action" == "disable" ]]; then
      api POST /key/block -d "{\"key\": \"$token\"}" >/dev/null
      echo "Blocked $name. Re-enable with: friends add $name"
    else
      api POST /key/delete -d "{\"keys\": [\"$token\"]}" >/dev/null
      echo "Deleted the key for $name."
    fi
    ;;

  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
FRIENDS_EOF
sudo chmod +x /usr/local/bin/friends

ok "Installed 'friends'."

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
      friends add alice --budget 50 --rpm 10
      friends list
      friends spend
      friends disable alice

  Defaults give access to worker, checker and local, but not brain. That is
  deliberate: a single xhigh reasoning call can hold the GPU for minutes, and
  a friend looping them takes your own assistant offline. Override with
  --models if you trust someone with it.

  Before you hand out the first key, read the liability section of
  reference/sharing-with-friends.md. The short version: traffic leaving your
  connection is attributable to you, so keep the list short and the people
  known, and check 'friends spend' weekly.

  Transport is still your open decision. What is running now is Tailscale
  only, which requires each friend to install Tailscale and accept a share.
  The alternative - Cloudflare Tunnel with Access, where friends need nothing
  installed but the endpoint is genuinely public - is documented and not
  installed. Switching later costs one evening; closing an accidental leak
  costs rather more.

  That is the last server phase. Linux gaming is ubuntu/09-gaming.sh.
EOF
