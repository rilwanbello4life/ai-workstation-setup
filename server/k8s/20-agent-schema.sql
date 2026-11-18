-- Agent prompt store and run log.
--
-- Roles live in the database rather than inside workflow JSON for two reasons:
-- the instruction updater needs somewhere to write proposals, and you need a
-- diff to review before any of them go live.
--
-- Applied by server/04-agents.sh into the 'litellm' database, which is where
-- spend data already lives - the two are almost always queried together.

CREATE TABLE IF NOT EXISTS agent_roles (
    name          TEXT PRIMARY KEY,
    model_alias   TEXT NOT NULL,
    system_prompt TEXT NOT NULL,
    temperature   REAL        DEFAULT 1.0,
    top_p         REAL        DEFAULT 0.95,
    version       INT         DEFAULT 1,
    updated_at    TIMESTAMPTZ DEFAULT now(),
    updated_by    TEXT        DEFAULT 'human'
);

-- Every version ever, including proposals that were never promoted. Nothing
-- is deleted: the history is the audit trail for a system that edits itself.
CREATE TABLE IF NOT EXISTS agent_role_history (
    id            BIGSERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    system_prompt TEXT NOT NULL,
    temperature   REAL,
    top_p         REAL,
    version       INT  NOT NULL,
    changed_at    TIMESTAMPTZ DEFAULT now(),
    changed_by    TEXT,
    rationale     TEXT,
    promoted      BOOLEAN DEFAULT FALSE,
    UNIQUE (name, version)
);

-- One row per role invocation. role_version is what makes the feedback loop
-- measurable - without it you cannot tell whether a prompt change helped.
CREATE TABLE IF NOT EXISTS agent_runs (
    id            BIGSERIAL PRIMARY KEY,
    task_id       TEXT,
    role          TEXT,
    role_version  INT,
    status        TEXT CHECK (status IN ('pass', 'fail', 'error', 'pending')),
    input         JSONB,
    output        JSONB,
    checker_notes TEXT,
    duration_ms   INT,
    created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_runs_role_created
    ON agent_runs (role, created_at DESC);
CREATE INDEX IF NOT EXISTS agent_runs_task
    ON agent_runs (task_id);
CREATE INDEX IF NOT EXISTS agent_runs_status
    ON agent_runs (status) WHERE status IN ('fail', 'error');

-- Pass rate per role per prompt version. This is the view the instruction
-- updater reads, and the one to check before promoting anything.
CREATE OR REPLACE VIEW agent_role_performance AS
SELECT
    role,
    role_version,
    count(*)                                             AS runs,
    count(*) FILTER (WHERE status = 'pass')              AS passed,
    count(*) FILTER (WHERE status IN ('fail', 'error'))  AS failed,
    round(100.0 * count(*) FILTER (WHERE status = 'pass')
          / NULLIF(count(*), 0), 1)                      AS pass_pct,
    round(avg(duration_ms))                              AS avg_ms,
    max(created_at)                                      AS last_run
FROM agent_runs
GROUP BY role, role_version
ORDER BY role, role_version DESC;

-- ---------------------------------------------------------------------------
-- Seeded roles.
--
-- brain and worker deliberately share the resident Strata pack and differ only
-- in reasoning_effort and prompt. Swapping Strata packs costs 1-3 minutes, so
-- giving each role its own model would spend most of the wall clock loading
-- weights. See reference/agent-orchestration.md.
--
-- Sampling differs by mode and is not cosmetic: thinking wants temperature 1.0
-- and top_p 0.95, instruct wants 0.7 and 0.80.

INSERT INTO agent_roles (name, model_alias, system_prompt, temperature, top_p, updated_by)
VALUES
('brain', 'brain',
'You decompose tasks. You do not execute them.

Given a task, produce an ordered list of concrete steps. Each step must be:
- independently verifiable, so a checker can judge it without re-reading the whole task
- small enough for one worker call
- stated with enough context to be understood on its own, because the worker
  does not see this conversation

Output JSON only: {"steps": [{"id": 1, "goal": "...", "done_when": "..."}]}

If the task needs no decomposition, return a single step. Do not invent work.
State assumptions explicitly in a "notes" field rather than silently resolving
ambiguity - the human reads these.',
 1.0, 0.95, 'human'),

('worker', 'worker',
'You execute exactly one step of a plan someone else made.

You receive a goal and its done_when condition. Do that, and only that.
Do not improve the plan, do not do the next step, do not question the
decomposition - another role owns those.

If the step cannot be completed as written, say so plainly and explain what
blocks it. A clear refusal is more useful than a plausible guess.

Output JSON only: {"result": "...", "confidence": "high|medium|low",
"blocked_by": null}',
 0.7, 0.80, 'human'),

('checker', 'checker',
'You verify a worker''s output against the step it was given.

You are deliberately a different model from the worker, so that its mistakes
are not automatically yours. Use that: check the claim, do not pattern-match
whether it sounds right.

Judge only: does the output satisfy done_when? Not whether you would have
done it differently, not whether the plan was good.

Be specific about failures. "Incorrect" is useless; "claims the API accepts a
limit parameter, which is not in the referenced documentation" is actionable
and is what the instruction updater learns from.

Output JSON only: {"verdict": "pass|fail", "reason": "...",
"suggested_fix": "..."}',
 0.7, 0.80, 'human'),

('updater', 'brain',
'You propose improvements to another agent role''s system prompt, based on
evidence of how it actually failed.

You receive: the current prompt, and a sample of failed runs with their
inputs, outputs and checker notes.

Look for patterns across failures, not single bad runs. One bad output is
noise; the same misunderstanding five times is a prompt problem.

Your proposal must:
- change as little as possible, so the effect is attributable
- address a failure mode visible in the evidence, not one you imagine
- not add length for its own sake - long prompts dilute attention

If the failures look like task difficulty rather than prompt deficiency, say
so and propose nothing. That is a valid and useful answer.

Output JSON only: {"proposed_prompt": "...", "rationale": "...",
"failure_pattern": "...", "confidence": "high|medium|low"}',
 1.0, 0.95, 'human')
ON CONFLICT (name) DO NOTHING;

-- Mirror the seed into history as version 1, so diffs have a baseline.
INSERT INTO agent_role_history (name, system_prompt, temperature, top_p, version, changed_by, rationale, promoted)
SELECT name, system_prompt, temperature, top_p, version, 'human', 'initial seed', TRUE
FROM agent_roles
ON CONFLICT (name, version) DO NOTHING;
