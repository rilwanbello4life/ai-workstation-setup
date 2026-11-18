#!/usr/bin/env bash
# Phase 15 - the agent orchestration layer.
#
# Creates the prompt store, seeds the brain / worker / checker / updater roles,
# installs the agent-roles and agent-runs management commands, and exports
# starter n8n workflows.
#
# The design decision that matters, restated because it is counter-intuitive:
# roles are PROMPTS, not pods and not separate models. Strata serves one pack
# at a time and swapping costs 1-3 minutes, so brain and worker share the
# resident pack and differ only in reasoning_effort. The checker is the one
# genuinely different model - a small GGUF on llama.cpp - because a validator
# sharing weights with the worker shares its blind spots.
#
# Background: reference/agent-orchestration.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root
require_k3s

while (( $# )); do
    case "$1" in
        -y|--yes)  shift ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

kubectl -n "$K8S_NS" get deploy postgres >/dev/null 2>&1 || \
    die "Postgres not found. Run ./03-platform.sh first."

WORKFLOW_DIR="$PLATFORM_DIR/n8n-workflows"

# ---------------------------------------------------------------------------
section "Prompt store"

info "Applying the schema to the 'litellm' database."
if kubectl -n "$K8S_NS" exec -i deploy/postgres -- \
     psql -U postgres -d litellm -v ON_ERROR_STOP=1 < "$K8S_DIR/20-agent-schema.sql" >/dev/null 2>&1; then
    ok "Schema applied and roles seeded."
else
    warn "Schema application reported errors. Re-run with output visible:"
    warn "  kubectl -n $K8S_NS exec -i deploy/postgres -- psql -U postgres -d litellm < $K8S_DIR/20-agent-schema.sql"
fi

echo
kubectl -n "$K8S_NS" exec deploy/postgres -- \
    psql -U postgres -d litellm -c \
    "SELECT name, model_alias, version, temperature, top_p FROM agent_roles ORDER BY name" \
    2>/dev/null | sed 's/^/    /' || warn "Could not list roles."

# ---------------------------------------------------------------------------
section "Management commands"

# A thin psql wrapper. Deliberately not a Python CLI: fewer moving parts, and
# everything it does is a query you could run by hand.
sudo tee /usr/local/bin/agent-roles >/dev/null <<'ROLES_EOF'
#!/usr/bin/env bash
# Inspect and promote agent role prompts.
#
#   agent-roles list                 roles, live versions and pass rates
#   agent-roles show <role>          the live prompt
#   agent-roles history <role>       every version, promoted or not
#   agent-roles diff <role> [ver]    proposed version against live
#   agent-roles promote <role> <ver> make a version live
#   agent-roles rollback <role>      revert to the previous promoted version
#
# The instruction updater writes proposals to agent_role_history and never to
# agent_roles. Promotion is always a human act - an agent with unreviewed write
# access to its own instructions has no diff to review and no way back.
set -euo pipefail

NS="${K8S_NS:-platform}"
q() { kubectl -n "$NS" exec -i deploy/postgres -- psql -U postgres -d litellm "$@"; }

cmd="${1:-list}"
case "$cmd" in
  list)
    echo "=== Live roles ==="
    q -c "SELECT name, model_alias, version, updated_by,
                 to_char(updated_at,'YYYY-MM-DD HH24:MI') AS updated
          FROM agent_roles ORDER BY name"
    echo "=== Measured performance ==="
    q -c "SELECT * FROM agent_role_performance"
    echo "=== Unpromoted proposals ==="
    q -c "SELECT name, version, changed_by,
                 to_char(changed_at,'YYYY-MM-DD HH24:MI') AS proposed,
                 left(rationale, 70) AS rationale
          FROM agent_role_history
          WHERE promoted = FALSE ORDER BY changed_at DESC"
    ;;
  show)
    [[ $# -ge 2 ]] || { echo "usage: agent-roles show <role>" >&2; exit 1; }
    q -tA -c "SELECT system_prompt FROM agent_roles WHERE name='$2'"
    ;;
  history)
    [[ $# -ge 2 ]] || { echo "usage: agent-roles history <role>" >&2; exit 1; }
    q -c "SELECT version, changed_by, promoted,
                 to_char(changed_at,'YYYY-MM-DD HH24:MI') AS changed,
                 left(rationale, 60) AS rationale
          FROM agent_role_history WHERE name='$2' ORDER BY version DESC"
    ;;
  diff)
    [[ $# -ge 2 ]] || { echo "usage: agent-roles diff <role> [version]" >&2; exit 1; }
    role="$2"
    ver="${3:-}"
    if [[ -z "$ver" ]]; then
      ver="$(q -tA -c "SELECT max(version) FROM agent_role_history
                       WHERE name='$role' AND promoted=FALSE" | tr -d '[:space:]')"
      [[ -n "$ver" && "$ver" != "" ]] || { echo "No unpromoted proposal for $role."; exit 0; }
    fi
    live="$(mktemp)"; prop="$(mktemp)"
    q -tA -c "SELECT system_prompt FROM agent_roles WHERE name='$role'" > "$live"
    q -tA -c "SELECT system_prompt FROM agent_role_history
              WHERE name='$role' AND version=$ver" > "$prop"
    echo "--- live"
    echo "+++ proposed version $ver"
    diff -u "$live" "$prop" || true
    echo
    echo "Rationale:"
    q -tA -c "SELECT rationale FROM agent_role_history
              WHERE name='$role' AND version=$ver" | sed 's/^/  /'
    rm -f "$live" "$prop"
    ;;
  promote)
    [[ $# -ge 3 ]] || { echo "usage: agent-roles promote <role> <version>" >&2; exit 1; }
    role="$2"; ver="$3"
    q -c "UPDATE agent_roles r
          SET system_prompt = h.system_prompt,
              temperature   = COALESCE(h.temperature, r.temperature),
              top_p         = COALESCE(h.top_p, r.top_p),
              version       = h.version,
              updated_at    = now(),
              updated_by    = 'promoted:' || h.changed_by
          FROM agent_role_history h
          WHERE h.name = r.name AND r.name = '$role' AND h.version = $ver"
    q -c "UPDATE agent_role_history SET promoted = TRUE
          WHERE name='$role' AND version=$ver"
    echo "Promoted $role to version $ver."
    ;;
  rollback)
    [[ $# -ge 2 ]] || { echo "usage: agent-roles rollback <role>" >&2; exit 1; }
    role="$2"
    prev="$(q -tA -c "SELECT version FROM agent_role_history
                      WHERE name='$role' AND promoted=TRUE
                        AND version < (SELECT version FROM agent_roles WHERE name='$role')
                      ORDER BY version DESC LIMIT 1" | tr -d '[:space:]')"
    [[ -n "$prev" ]] || { echo "No earlier promoted version for $role." >&2; exit 1; }
    exec "$0" promote "$role" "$prev"
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
ROLES_EOF
sudo chmod +x /usr/local/bin/agent-roles

sudo tee /usr/local/bin/agent-runs >/dev/null <<'RUNS_EOF'
#!/usr/bin/env bash
# Inspect the agent run log.
#
#   agent-runs tail [n]        most recent runs
#   agent-runs stats           pass rate per role per prompt version
#   agent-runs failures [n]    recent failures with checker notes
#   agent-runs task <id>       every step of one task, in order
#   agent-runs prune [days]    delete runs older than N days (default 90)
set -euo pipefail

NS="${K8S_NS:-platform}"
q() { kubectl -n "$NS" exec -i deploy/postgres -- psql -U postgres -d litellm "$@"; }

case "${1:-tail}" in
  tail)
    q -c "SELECT to_char(created_at,'MM-DD HH24:MI:SS') AS at, task_id,
                 role, role_version AS v, status, duration_ms AS ms
          FROM agent_runs ORDER BY created_at DESC LIMIT ${2:-25}"
    ;;
  stats)
    q -c "SELECT * FROM agent_role_performance"
    ;;
  failures)
    q -c "SELECT to_char(created_at,'MM-DD HH24:MI') AS at, task_id, role,
                 role_version AS v, left(checker_notes, 90) AS notes
          FROM agent_runs WHERE status IN ('fail','error')
          ORDER BY created_at DESC LIMIT ${2:-20}"
    ;;
  task)
    [[ $# -ge 2 ]] || { echo "usage: agent-runs task <id>" >&2; exit 1; }
    q -c "SELECT id, role, role_version AS v, status, duration_ms AS ms,
                 left(checker_notes, 70) AS notes
          FROM agent_runs WHERE task_id='$2' ORDER BY created_at"
    ;;
  prune)
    days="${2:-90}"
    q -c "DELETE FROM agent_runs WHERE created_at < now() - interval '$days days'"
    echo "Pruned runs older than $days days."
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
RUNS_EOF
sudo chmod +x /usr/local/bin/agent-runs

ok "Installed agent-roles and agent-runs."

# ---------------------------------------------------------------------------
section "Starter workflows"

mkdir -p "$WORKFLOW_DIR"

# Exported rather than imported via the API: n8n needs an owner account and an
# API key first, neither of which exists on a fresh install. Importing by hand
# also means you read the workflow before running it.
cat > "$WORKFLOW_DIR/01-brain-worker-checker.json" <<'WF_EOF'
{
  "name": "Agent loop: brain, worker, checker",
  "nodes": [
    {
      "parameters": {
        "httpMethod": "POST",
        "path": "agent-task",
        "responseMode": "lastNode"
      },
      "name": "Task in",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [-640, 300],
      "webhookId": "agent-task"
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT name, model_alias, system_prompt, temperature, top_p, version FROM agent_roles WHERE name = ANY(ARRAY['brain','worker','checker'])"
      },
      "name": "Load roles",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.4,
      "position": [-420, 300],
      "notesInFlow": true,
      "notes": "Prompts come from the database, never hardcoded here"
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://litellm.platform.svc.cluster.local:4000/v1/chat/completions",
        "sendHeaders": true,
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ model: 'brain', temperature: 1.0, top_p: 0.95, messages: [ { role: 'system', content: $('Load roles').all().find(r => r.json.name === 'brain').json.system_prompt }, { role: 'user', content: $('Task in').first().json.body.task } ] }) }}",
        "options": { "timeout": 900000 }
      },
      "name": "Brain: plan",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [-200, 300],
      "notesInFlow": true,
      "notes": "reasoning_effort xhigh is set on the gateway alias"
    },
    {
      "parameters": {
        "jsCode": "// Split the plan into one item per step so the loop can walk them.\n// Strict parse: a brain that returns prose instead of JSON is a bug worth\n// surfacing immediately rather than papering over.\nconst raw = $input.first().json.choices[0].message.content;\nlet plan;\ntry {\n  plan = JSON.parse(raw.replace(/^```json\\n?|```$/g, '').trim());\n} catch (e) {\n  throw new Error('Brain did not return valid JSON: ' + raw.slice(0, 200));\n}\nconst taskId = $('Task in').first().json.body.task_id || `task-${Date.now()}`;\nreturn (plan.steps || []).map(s => ({ json: { ...s, task_id: taskId } }));"
      },
      "name": "Split steps",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [20, 300]
    },
    {
      "parameters": { "options": { "reset": false } },
      "name": "For each step",
      "type": "n8n-nodes-base.splitInBatches",
      "typeVersion": 3,
      "position": [240, 300],
      "notesInFlow": true,
      "notes": "Batch size 1: one GPU, so steps run in sequence regardless"
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://litellm.platform.svc.cluster.local:4000/v1/chat/completions",
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ model: 'worker', temperature: 0.7, top_p: 0.80, presence_penalty: 1.5, messages: [ { role: 'system', content: $('Load roles').all().find(r => r.json.name === 'worker').json.system_prompt }, { role: 'user', content: `Goal: ${$json.goal}\\nDone when: ${$json.done_when}` } ] }) }}",
        "options": { "timeout": 300000 }
      },
      "name": "Worker: execute",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [460, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://litellm.platform.svc.cluster.local:4000/v1/chat/completions",
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ model: 'checker', temperature: 0.7, top_p: 0.80, messages: [ { role: 'system', content: $('Load roles').all().find(r => r.json.name === 'checker').json.system_prompt }, { role: 'user', content: `Step: ${$('For each step').first().json.goal}\\nDone when: ${$('For each step').first().json.done_when}\\n\\nWorker output:\\n${$json.choices[0].message.content}` } ] }) }}",
        "options": { "timeout": 180000 }
      },
      "name": "Checker: verify",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [680, 300],
      "notesInFlow": true,
      "notes": "Different model from the worker - independent failure modes"
    },
    {
      "parameters": {
        "operation": "insert",
        "schema": { "__rl": true, "mode": "name", "value": "public" },
        "table": { "__rl": true, "mode": "name", "value": "agent_runs" },
        "columns": {
          "mappingMode": "defineBelow",
          "value": {
            "task_id": "={{ $('For each step').first().json.task_id }}",
            "role": "worker",
            "role_version": "={{ $('Load roles').all().find(r => r.json.name === 'worker').json.version }}",
            "status": "={{ $json.choices[0].message.content.includes('\"pass\"') ? 'pass' : 'fail' }}",
            "checker_notes": "={{ $json.choices[0].message.content.slice(0, 2000) }}"
          }
        }
      },
      "name": "Log run",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.4,
      "position": [900, 300],
      "notesInFlow": true,
      "notes": "role_version is what makes prompt changes measurable later"
    }
  ],
  "connections": {
    "Task in":          { "main": [[{ "node": "Load roles",      "type": "main", "index": 0 }]] },
    "Load roles":       { "main": [[{ "node": "Brain: plan",     "type": "main", "index": 0 }]] },
    "Brain: plan":      { "main": [[{ "node": "Split steps",     "type": "main", "index": 0 }]] },
    "Split steps":      { "main": [[{ "node": "For each step",   "type": "main", "index": 0 }]] },
    "For each step":    { "main": [[], [{ "node": "Worker: execute", "type": "main", "index": 0 }]] },
    "Worker: execute":  { "main": [[{ "node": "Checker: verify", "type": "main", "index": 0 }]] },
    "Checker: verify":  { "main": [[{ "node": "Log run",         "type": "main", "index": 0 }]] },
    "Log run":          { "main": [[{ "node": "For each step",   "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1" }
}
WF_EOF

cat > "$WORKFLOW_DIR/02-instruction-updater.json" <<'WF_EOF'
{
  "name": "Instruction updater (weekly, proposes only)",
  "nodes": [
    {
      "parameters": {
        "rule": { "interval": [{ "field": "weeks", "triggerAtDay": [1], "triggerAtHour": 4 }] }
      },
      "name": "Weekly",
      "type": "n8n-nodes-base.scheduleTrigger",
      "typeVersion": 1.2,
      "position": [-640, 300],
      "notesInFlow": true,
      "notes": "Out of band, not in the loop: an agent rewriting prompts mid-task makes failures unattributable"
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT role, role_version, runs, failed, pass_pct FROM agent_role_performance WHERE runs >= 20 AND pass_pct < 85 AND role <> 'updater'"
      },
      "name": "Find weak roles",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.4,
      "position": [-420, 300],
      "notesInFlow": true,
      "notes": "At least 20 runs: below that a low pass rate is noise, not signal"
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT input, output, checker_notes FROM agent_runs WHERE role = '{{ $json.role }}' AND status IN ('fail','error') ORDER BY created_at DESC LIMIT 15"
      },
      "name": "Fetch failures",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.4,
      "position": [-200, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "http://litellm.platform.svc.cluster.local:4000/v1/chat/completions",
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ model: 'brain', temperature: 1.0, top_p: 0.95, messages: [ { role: 'system', content: $('Load updater role').first().json.system_prompt }, { role: 'user', content: 'Current prompt:\\n' + $('Load updater role').first().json.target_prompt + '\\n\\nFailures:\\n' + JSON.stringify($input.all().map(i => i.json)).slice(0, 12000) } ] }) }}",
        "options": { "timeout": 900000 }
      },
      "name": "Propose revision",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [240, 300]
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT system_prompt FROM agent_roles WHERE name = 'updater'"
      },
      "name": "Load updater role",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.4,
      "position": [20, 300]
    },
    {
      "parameters": {
        "jsCode": "// Write the proposal to history ONLY. Never to agent_roles.\n// Promotion is a human act via `agent-roles promote`.\nconst raw = $input.first().json.choices[0].message.content;\nlet p;\ntry {\n  p = JSON.parse(raw.replace(/^```json\\n?|```$/g, '').trim());\n} catch (e) {\n  return [{ json: { skip: true, reason: 'updater returned non-JSON' } }];\n}\nif (!p.proposed_prompt) {\n  return [{ json: { skip: true, reason: p.rationale || 'no change proposed' } }];\n}\nreturn [{ json: { proposed_prompt: p.proposed_prompt, rationale: p.rationale, failure_pattern: p.failure_pattern } }];"
      },
      "name": "Parse proposal",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [460, 300]
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "INSERT INTO agent_role_history (name, system_prompt, version, changed_by, rationale, promoted) SELECT '{{ $('Find weak roles').first().json.role }}', $1, COALESCE(max(version),0)+1, 'updater', $2, FALSE FROM agent_role_history WHERE name = '{{ $('Find weak roles').first().json.role }}'",
        "options": { "queryReplacement": "={{ $json.proposed_prompt }},={{ $json.rationale }}" }
      },
      "name": "Store proposal",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.4,
      "position": [680, 300],
      "notesInFlow": true,
      "notes": "promoted = FALSE. Review with: agent-roles diff <role>"
    }
  ],
  "connections": {
    "Weekly":            { "main": [[{ "node": "Find weak roles",    "type": "main", "index": 0 }]] },
    "Find weak roles":   { "main": [[{ "node": "Fetch failures",     "type": "main", "index": 0 }]] },
    "Fetch failures":    { "main": [[{ "node": "Load updater role",  "type": "main", "index": 0 }]] },
    "Load updater role": { "main": [[{ "node": "Propose revision",   "type": "main", "index": 0 }]] },
    "Propose revision":  { "main": [[{ "node": "Parse proposal",     "type": "main", "index": 0 }]] },
    "Parse proposal":    { "main": [[{ "node": "Store proposal",     "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1" }
}
WF_EOF

ok "Wrote starter workflows to $WORKFLOW_DIR"

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
  Roles seeded: brain, worker, checker, updater

      agent-roles list          versions and measured pass rates
      agent-roles show brain    read a live prompt
      agent-runs tail           watch role calls as they happen
      agent-runs failures       what went wrong, with checker notes

  Importing the starter workflows:

      1. Open n8n at http://127.0.0.1:5678 and create the owner account.
      2. Add a Postgres credential:
             host     postgres
             database litellm
             user     postgres
             password  (see $PLATFORM_DIR/secrets/postgres-password)
      3. Workflows > Import from file, from:
             $WORKFLOW_DIR
      4. Read them before activating. They are starting points, not products.

  Trigger the agent loop once imported:

      curl -X POST http://127.0.0.1:5678/webhook/agent-task \\
        -H 'Content-Type: application/json' \\
        -d '{"task":"Summarise what changed in this repo this week"}'

  Two things worth knowing before you build on this:

  * "Parallel workers" means queued. One GPU, and Strata holds ~1.5 GB of KV
    cache per slot at 32K context, so a 16 GB card supports about 2 slots.
    Fan-out costs the sum of the calls, not the maximum.

  * The updater proposes and never deploys. It writes to agent_role_history
    with promoted = FALSE. Review with 'agent-roles diff <role>' and promote
    deliberately. An agent with unreviewed write access to its own
    instructions leaves you no diff to read and no way back.

  Next: ./05-game-servers.sh, or ./06-friends.sh
EOF
