-- GPU queue: per-user profiles, skills and the job table.
--
-- Numbered 21 rather than 30 because 30 and 31 are already the game server
-- manifests. This belongs immediately after 20-agent-schema.sql, which it
-- deliberately mirrors: same database, same versioned-history convention,
-- same principle that anything which edits itself keeps an audit trail.
--
-- Applied by server/09-gpu-queue.sh into the 'litellm' database, where the
-- spend tables and the agent prompt store already live. All three are
-- queried together often enough that separating them would mean joining
-- across databases to answer "what did this person actually cost me".
--
-- The key that ties it together is LiteLLM's key_alias - the name you typed
-- in `friends add alice`. The queue never invents its own identities, so
-- revoking a LiteLLM key revokes everything, with no second place to forget.

-- ---------------------------------------------------------------------------
-- Skills: named, reusable prompt fragments.
--
-- A skill is not a tool and does not execute anything. It is text appended
-- to a user's system message when they ask for it, which makes "give Alice
-- the SQL helper" a row rather than a copy-pasted paragraph that drifts.
CREATE TABLE IF NOT EXISTS skills (
    name        TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    content     TEXT NOT NULL,
    version     INT         DEFAULT 1,
    updated_at  TIMESTAMPTZ DEFAULT now(),
    updated_by  TEXT        DEFAULT 'human'
);

-- ---------------------------------------------------------------------------
-- One row per person who has a LiteLLM key.
--
-- max_concurrent is the fairness lever and the reason one person looping
-- requests cannot starve everyone else: the dispatcher will not admit a
-- user's second job until their first finishes, however deep their queue.
--
-- allow_heavy is separate from the LiteLLM model allowlist on purpose. The
-- allowlist says which models you may name; this says whether you may hold
-- the whole GPU for minutes at a time doing it.
CREATE TABLE IF NOT EXISTS user_profiles (
    key_alias       TEXT PRIMARY KEY,
    display_name    TEXT,
    system_prompt   TEXT        NOT NULL DEFAULT '',
    -- Skills this person may select. A request naming a skill outside this
    -- list is served without it rather than rejected: a missing prompt
    -- fragment should degrade an answer, not fail a call.
    skills          JSONB       NOT NULL DEFAULT '[]'::jsonb,
    default_model   TEXT,
    max_concurrent  INT         NOT NULL DEFAULT 1,
    max_queue_depth INT         NOT NULL DEFAULT 10,
    -- Lower runs sooner. 100 is the default band; the owner sits at 10.
    priority        INT         NOT NULL DEFAULT 100,
    allow_heavy     BOOLEAN     NOT NULL DEFAULT FALSE,
    version         INT         NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now(),
    updated_by      TEXT        DEFAULT 'human'
);

-- Every version ever, including ones that were edited away. Same reasoning
-- as agent_role_history: a prompt change that made things worse needs to be
-- visible and revertible.
CREATE TABLE IF NOT EXISTS user_profile_history (
    id            BIGSERIAL PRIMARY KEY,
    key_alias     TEXT NOT NULL,
    system_prompt TEXT,
    skills        JSONB,
    version       INT  NOT NULL,
    changed_at    TIMESTAMPTZ DEFAULT now(),
    changed_by    TEXT,
    rationale     TEXT,
    UNIQUE (key_alias, version)
);

-- ---------------------------------------------------------------------------
-- One row per admitted unit of GPU work, inference or batch.
--
-- wait_ms is the number that tells you whether the queue is doing its job or
-- just adding latency. If it is consistently near zero the limits are too
-- loose to ever bind; if it is minutes, the machine is oversubscribed and no
-- amount of scheduling will fix that.
CREATE TABLE IF NOT EXISTS gpu_jobs (
    id           BIGSERIAL PRIMARY KEY,
    key_alias    TEXT,
    kind         TEXT NOT NULL CHECK (kind IN ('chat', 'comfyui', 'batch')),
    weight       TEXT NOT NULL CHECK (weight IN ('light', 'heavy')),
    status       TEXT NOT NULL CHECK (status IN
                     ('queued', 'running', 'done', 'failed', 'cancelled')),
    model        TEXT,
    -- The priority this job was admitted with, copied from the profile at
    -- enqueue time rather than joined at dispatch time. A job keeps the
    -- standing it had when it arrived, so raising someone's priority does
    -- not reorder work already waiting behind them.
    priority     INT  NOT NULL DEFAULT 100,
    payload      JSONB,
    result       JSONB,
    error        TEXT,
    queued_at    TIMESTAMPTZ DEFAULT now(),
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    wait_ms      INT,
    duration_ms  INT
);

-- The dispatcher's index: it asks "what is the next queued job" on every
-- tick, ordered exactly this way.
CREATE INDEX IF NOT EXISTS gpu_jobs_pending
    ON gpu_jobs (priority, queued_at)
    WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS gpu_jobs_queued_at
    ON gpu_jobs (status, queued_at);

CREATE INDEX IF NOT EXISTS gpu_jobs_user_active
    ON gpu_jobs (key_alias, status)
    WHERE status IN ('queued', 'running');

CREATE INDEX IF NOT EXISTS gpu_jobs_recent
    ON gpu_jobs (queued_at DESC);

-- ---------------------------------------------------------------------------
-- What the last day actually looked like, per person. This is the view to
-- read before changing anyone's limits.
CREATE OR REPLACE VIEW gpu_queue_usage AS
SELECT
    COALESCE(j.key_alias, '(none)')                          AS key_alias,
    count(*)                                                 AS jobs,
    count(*) FILTER (WHERE j.status = 'done')                AS completed,
    count(*) FILTER (WHERE j.status IN ('failed', 'cancelled')) AS unfinished,
    count(*) FILTER (WHERE j.weight = 'heavy')               AS heavy,
    round(avg(j.wait_ms))                                    AS avg_wait_ms,
    max(j.wait_ms)                                           AS worst_wait_ms,
    round(avg(j.duration_ms))                                AS avg_run_ms,
    max(j.queued_at)                                         AS last_seen
FROM gpu_jobs j
WHERE j.queued_at > now() - interval '24 hours'
GROUP BY 1
ORDER BY jobs DESC;

-- ---------------------------------------------------------------------------
-- Seeded skills.
--
-- Deliberately few and deliberately short. A skill that runs to a page
-- dilutes attention the same way an overlong system prompt does, and the
-- point of having them as rows is that adding one is cheap.

INSERT INTO skills (name, description, content) VALUES
('concise',
 'Shorter answers, no preamble',
 'Answer directly. No preamble, no restating the question, no summary of
what you are about to do. If the answer is one sentence, write one sentence.'),

('sql',
 'Postgres query help',
 'When writing SQL, target PostgreSQL 16. Prefer explicit column lists over
SELECT *, and say plainly when a query will perform a sequential scan on a
table large enough for it to matter.'),

('k8s',
 'Kubernetes on a single node',
 'Kubernetes answers here target a single-node k3s cluster. Do not suggest
multi-node solutions, node affinity or pod anti-affinity. Every pod must
declare resource requests and limits, because the namespaces have quotas and
admission fails without them.'),

('shell',
 'Bash that survives review',
 'Shell answers target bash on Ubuntu. Quote expansions, prefer [[ ]] over
[ ], and set -euo pipefail in scripts unless there is a stated reason not to.
Say when a command is destructive before showing it.')
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- The owner's own profile.
--
-- priority 10 and a higher concurrency than a guest, because the person who
-- paid for the GPU should not wait behind it. 'owner' is not a LiteLLM key
-- alias - it is the profile applied to the master key.
INSERT INTO user_profiles
    (key_alias, display_name, system_prompt, skills,
     max_concurrent, max_queue_depth, priority, allow_heavy)
VALUES
('owner', 'Owner (master key)', '', '["concise"]'::jsonb, 3, 50, 10, TRUE)
ON CONFLICT (key_alias) DO NOTHING;

INSERT INTO user_profile_history
    (key_alias, system_prompt, skills, version, changed_by, rationale)
SELECT key_alias, system_prompt, skills, version, 'human', 'initial seed'
FROM user_profiles
ON CONFLICT (key_alias, version) DO NOTHING;
