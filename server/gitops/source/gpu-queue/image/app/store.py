"""Postgres access: user profiles, skills and the job table.

Every function here degrades rather than raises. A database that is down
should cost personalisation and bookkeeping, not model access - the person
on the other end of the connection did nothing wrong and should still get an
answer. The one place that is not true is `queue list`, which has nothing to
show without it.
"""

import json
import logging
from dataclasses import dataclass, field

import asyncpg

from .config import settings

log = logging.getLogger("store")


@dataclass
class Profile:
    key_alias: str
    display_name: str = ""
    system_prompt: str = ""
    skills: list = field(default_factory=list)
    default_model: str | None = None
    max_concurrent: int = settings.fallback_max_concurrent
    max_queue_depth: int = settings.fallback_queue_depth
    priority: int = 100
    allow_heavy: bool = False
    # True when this came from a fallback rather than a real row, which the
    # /queue/status endpoint surfaces so "why is nobody's prompt applying"
    # has a visible answer.
    synthetic: bool = False


class Store:
    def __init__(self) -> None:
        self.pool: asyncpg.Pool | None = None

    async def connect(self) -> None:
        if not settings.database_url:
            log.warning("No DATABASE_URL; running without profiles or job history.")
            return
        try:
            self.pool = await asyncpg.create_pool(
                settings.database_url, min_size=1, max_size=5, command_timeout=10
            )
            log.info("Connected to Postgres.")
        except Exception as exc:                               # noqa: BLE001
            log.error("Postgres unavailable (%s). Serving without profiles.", exc)
            self.pool = None

    async def close(self) -> None:
        if self.pool:
            await self.pool.close()

    @property
    def ready(self) -> bool:
        return self.pool is not None

    # -- profiles -----------------------------------------------------------

    async def profile(self, key_alias: str) -> Profile:
        if not self.pool:
            return Profile(key_alias=key_alias, synthetic=True)
        try:
            row = await self.pool.fetchrow(
                """SELECT key_alias, display_name, system_prompt, skills,
                          default_model, max_concurrent, max_queue_depth,
                          priority, allow_heavy
                   FROM user_profiles WHERE key_alias = $1""",
                key_alias,
            )
        except Exception as exc:                               # noqa: BLE001
            log.warning("profile lookup failed for %s: %s", key_alias, exc)
            return Profile(key_alias=key_alias, synthetic=True)

        if not row:
            # A key that exists in LiteLLM but has no profile yet. Give it
            # the conservative defaults rather than refusing it: `friends
            # add` and `friends profile` are separate steps on purpose.
            return Profile(key_alias=key_alias, synthetic=True)

        skills = row["skills"]
        if isinstance(skills, str):
            try:
                skills = json.loads(skills)
            except ValueError:
                skills = []

        return Profile(
            key_alias=row["key_alias"],
            display_name=row["display_name"] or "",
            system_prompt=row["system_prompt"] or "",
            skills=list(skills or []),
            default_model=row["default_model"],
            max_concurrent=row["max_concurrent"],
            max_queue_depth=row["max_queue_depth"],
            priority=row["priority"],
            allow_heavy=row["allow_heavy"],
        )

    async def skill_contents(self, names: list[str]) -> list[tuple[str, str]]:
        """Return (name, content) for the named skills, in the order given."""
        if not self.pool or not names:
            return []
        try:
            rows = await self.pool.fetch(
                "SELECT name, content FROM skills WHERE name = ANY($1::text[])", names
            )
        except Exception as exc:                               # noqa: BLE001
            log.warning("skill lookup failed: %s", exc)
            return []
        by_name = {r["name"]: r["content"] for r in rows}
        return [(n, by_name[n]) for n in names if n in by_name]

    # -- jobs ---------------------------------------------------------------

    async def job_create(
        self, key_alias: str, kind: str, weight: str, model: str | None,
        priority: int, payload: dict | None = None,
    ) -> int | None:
        if not self.pool:
            return None
        try:
            return await self.pool.fetchval(
                """INSERT INTO gpu_jobs
                       (key_alias, kind, weight, status, model, priority, payload)
                   VALUES ($1, $2, $3, 'queued', $4, $5, $6)
                   RETURNING id""",
                key_alias, kind, weight, model, priority,
                json.dumps(payload) if payload is not None else None,
            )
        except Exception as exc:                               # noqa: BLE001
            log.warning("job_create failed: %s", exc)
            return None

    async def job_started(self, job_id: int | None, wait_ms: int) -> None:
        if not self.pool or job_id is None:
            return
        try:
            await self.pool.execute(
                """UPDATE gpu_jobs
                   SET status='running', started_at=now(), wait_ms=$2
                   WHERE id=$1""",
                job_id, wait_ms,
            )
        except Exception as exc:                               # noqa: BLE001
            log.warning("job_started failed: %s", exc)

    async def job_finished(
        self, job_id: int | None, status: str, duration_ms: int,
        error: str | None = None, result: dict | None = None,
    ) -> None:
        if not self.pool or job_id is None:
            return
        try:
            await self.pool.execute(
                """UPDATE gpu_jobs
                   SET status=$2, finished_at=now(), duration_ms=$3,
                       error=$4, result=$5
                   WHERE id=$1""",
                job_id, status, duration_ms, error,
                json.dumps(result) if result is not None else None,
            )
        except Exception as exc:                               # noqa: BLE001
            log.warning("job_finished failed: %s", exc)

    async def job_get(self, job_id: int) -> dict | None:
        if not self.pool:
            return None
        row = await self.pool.fetchrow("SELECT * FROM gpu_jobs WHERE id=$1", job_id)
        return dict(row) if row else None

    async def jobs_recent(self, limit: int = 50) -> list[dict]:
        if not self.pool:
            return []
        rows = await self.pool.fetch(
            """SELECT id, key_alias, kind, weight, status, model,
                      queued_at, started_at, finished_at, wait_ms, duration_ms, error
               FROM gpu_jobs ORDER BY queued_at DESC LIMIT $1""",
            limit,
        )
        return [dict(r) for r in rows]

    async def jobs_pending_batch(self) -> list[dict]:
        """Queued batch work, in dispatch order."""
        if not self.pool:
            return []
        rows = await self.pool.fetch(
            """SELECT id, key_alias, kind, weight, model, payload, priority
               FROM gpu_jobs
               WHERE status = 'queued' AND kind <> 'chat'
               ORDER BY priority ASC, queued_at ASC"""
        )
        return [dict(r) for r in rows]

    async def job_cancel(self, job_id: int) -> bool:
        if not self.pool:
            return False
        # Only a job that has not started. A running render is on the GPU and
        # stopping it is ComfyUI's business, not a database update's.
        result = await self.pool.execute(
            """UPDATE gpu_jobs SET status='cancelled', finished_at=now()
               WHERE id=$1 AND status='queued'""",
            job_id,
        )
        return result.endswith("1")


store = Store()
