"""gpu-queue: the fair-share front door for shared model access.

Sits in front of LiteLLM and forwards the caller's own key to it unchanged,
so LiteLLM remains the single authority on budgets, rate limits, model
allowlists and spend. This service adds only the three things LiteLLM has no
view of:

  * a real queue, instead of a 429 when parallelism is exceeded
  * per-user identity beyond the key: a system prompt and granted skills
  * admission that looks at what the GPU is actually doing

Request path:
    friend -> tailscale :8447 -> gpu-queue :4100 -> LiteLLM :4000 -> Strata

Everything degrades. A missing profile serves a plain request; an unreachable
Postgres serves everyone with defaults; an unreachable GPU probe falls back
to static limits. None of those should stop someone getting an answer.
"""

import asyncio
import hashlib
import json
import logging
import os
import time

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

from .config import settings
from .gpu import gpu
from .jobs import batch_worker
from .scheduler import Ticket, scheduler
from .store import Profile, store

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)-7s %(name)-6s %(message)s",
)
log = logging.getLogger("queue")

app = FastAPI(title="gpu-queue", docs_url=None, redoc_url=None)

_key_cache: dict[str, tuple[float, str]] = {}
_client: httpx.AsyncClient | None = None


# ---------------------------------------------------------------------------
# Identity


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Missing bearer token.")
    return authorization.split(None, 1)[1].strip()


async def resolve_alias(token: str) -> str:
    """Map an API key to the name it was issued under.

    LiteLLM already knows this - it is the key_alias from `friends add` - so
    asking it keeps one source of truth for identity. The answer is cached
    briefly because it is on the hot path of every request, and a revoked
    key is still rejected downstream by LiteLLM itself within the same
    second, so the cache cannot grant access that has been taken away.
    """
    if settings.master_key and token == settings.master_key:
        return "owner"

    digest = hashlib.sha256(token.encode()).hexdigest()[:16]
    hit = _key_cache.get(digest)
    now = time.time()
    if hit and now - hit[0] < settings.key_cache_seconds:
        return hit[1]

    alias = f"key-{digest[:8]}"
    try:
        r = await _client.get(
            f"{settings.litellm_base}/key/info",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        if r.status_code == 200:
            info = (r.json() or {}).get("info") or {}
            alias = info.get("key_alias") or alias
    except Exception as exc:                                   # noqa: BLE001
        # Identity is a nicety; authorisation happens downstream regardless.
        log.debug("key/info lookup failed: %s", exc)

    _key_cache[digest] = (now, alias)
    return alias


# ---------------------------------------------------------------------------
# Profile application


def _merge_system(body: dict, prefix: str) -> None:
    msgs = list(body.get("messages") or [])
    if not prefix:
        return
    if msgs and msgs[0].get("role") == "system":
        existing = msgs[0].get("content")
        if isinstance(existing, str):
            msgs[0] = {**msgs[0], "content": f"{prefix}\n\n{existing}"}
        else:
            # Multimodal or structured content: prepend a separate message
            # rather than trying to splice into a content array.
            msgs.insert(0, {"role": "system", "content": prefix})
    else:
        msgs.insert(0, {"role": "system", "content": prefix})
    body["messages"] = msgs


async def apply_profile(body: dict, profile: Profile) -> list[str]:
    """Prepend the user's system prompt and any skills they asked for.

    `skills` is an extension to the OpenAI body and is stripped before the
    request is forwarded, because LiteLLM would reject an unknown field.
    """
    requested = body.pop("skills", None)
    granted = set(profile.skills or [])

    if requested is None:
        wanted = list(profile.skills or [])
    elif isinstance(requested, list):
        # Silently drop anything not granted. A missing prompt fragment
        # should make an answer worse, not turn a call into an error.
        wanted = [s for s in requested if s in granted]
    else:
        wanted = []

    parts = []
    if profile.system_prompt:
        parts.append(profile.system_prompt)
    applied = []
    for name, content in await store.skill_contents(wanted):
        parts.append(content)
        applied.append(name)

    _merge_system(body, "\n\n".join(parts))

    if profile.default_model and not body.get("model"):
        body["model"] = profile.default_model
    return applied


# ---------------------------------------------------------------------------
# Admission


class Admission:
    """Hold a queue slot for the duration of a request, then release it.

    A context manager because the release must happen on every path out,
    including a client that disconnects mid-stream. Leaking a slot is worse
    than almost any other bug here: the limit is small, so two leaks and the
    queue stops admitting anything.
    """

    def __init__(self, ticket: Ticket):
        self.t = ticket
        self.started = 0.0

    async def __aenter__(self):
        try:
            await asyncio.wait_for(
                self.t.admitted.wait(), timeout=settings.queue_timeout
            )
        except asyncio.TimeoutError:
            scheduler.abandon(self.t)
            await store.job_finished(self.t.job_id, "cancelled", 0, "queue timeout")
            raise HTTPException(
                503,
                detail={
                    "error": "Timed out waiting for the GPU.",
                    "waited_s": settings.queue_timeout,
                    "hint": "The machine is busy or a large model is loading.",
                },
            )
        self.started = time.time()
        await store.job_started(self.t.job_id, self.t.wait_ms)
        return self

    async def __aexit__(self, exc_type, exc, tb):
        scheduler.release(self.t)
        ms = int((time.time() - self.started) * 1000)
        status = "done" if exc_type is None else "failed"
        await store.job_finished(
            self.t.job_id, status, ms, str(exc) if exc else None
        )
        return False


async def _profile_limit(key_alias: str) -> int:
    return (await store.profile(key_alias)).max_concurrent


async def take_ticket(key_alias: str, profile: Profile, weight: str,
                      model: str | None, kind: str = "chat") -> Ticket:
    if weight == "heavy" and not profile.allow_heavy:
        scheduler.rejected_total += 1
        raise HTTPException(
            403,
            detail={
                "error": "This key may not run heavy jobs.",
                "reason": "xhigh reasoning or a long generation can hold the "
                          "GPU for minutes.",
                "hint": "Use reasoning_effort 'low' or 'medium', or ask for "
                        "allow_heavy on your profile.",
            },
        )

    depth = scheduler.depth_for(key_alias)
    if depth >= profile.max_queue_depth:
        scheduler.rejected_total += 1
        raise HTTPException(
            429,
            detail={
                "error": "Your queue is full.",
                "queued": depth,
                "max_queue_depth": profile.max_queue_depth,
            },
            headers={"Retry-After": "30"},
        )

    job_id = await store.job_create(
        key_alias, kind, weight, model, profile.priority
    )
    t = Ticket(
        key_alias=key_alias, weight=weight,
        priority=profile.priority, job_id=job_id,
    )
    scheduler.enqueue(t)
    return t


# ---------------------------------------------------------------------------
# Lifecycle


@app.on_event("startup")
async def startup():
    global _client
    _client = httpx.AsyncClient(timeout=httpx.Timeout(settings.upstream_timeout))
    await store.connect()
    gpu.start()
    scheduler.start(_profile_limit)
    asyncio.create_task(batch_worker(_client))
    os.makedirs(settings.output_dir, exist_ok=True)
    log.info("gpu-queue ready. Upstream: %s", settings.litellm_base)


@app.on_event("shutdown")
async def shutdown():
    await scheduler.stop()
    await gpu.stop()
    await store.close()
    if _client:
        await _client.aclose()


# ---------------------------------------------------------------------------
# OpenAI surface


@app.post("/v1/chat/completions")
async def chat_completions(request: Request, authorization: str = Header(None)):
    token = _bearer(authorization)
    alias = await resolve_alias(token)
    profile = await store.profile(alias)

    try:
        body = await request.json()
    except Exception:                                          # noqa: BLE001
        raise HTTPException(400, "Body must be JSON.")

    applied = await apply_profile(body, profile)
    model = body.get("model")
    weight = scheduler.classify(model, body)

    t = await take_ticket(alias, profile, weight, model)
    position = scheduler.position(t)

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    stream = bool(body.get("stream"))

    adm = Admission(t)
    await adm.__aenter__()

    info = {
        "X-Queue-Position": str(position),
        "X-Queue-Wait-Ms": str(t.wait_ms),
        "X-Queue-Weight": weight,
        "X-Queue-User": alias,
        "X-Queue-Skills": ",".join(applied),
    }

    if not stream:
        try:
            r = await _client.post(
                f"{settings.litellm_base}/v1/chat/completions",
                json=body, headers=headers,
            )
            content = r.content
            media = r.headers.get("content-type", "application/json")
        except Exception as exc:                               # noqa: BLE001
            await adm.__aexit__(type(exc), exc, None)
            raise HTTPException(502, f"Upstream failed: {exc}")
        await adm.__aexit__(None, None, None)
        return StreamingResponse(
            iter([content]), status_code=r.status_code,
            media_type=media, headers=info,
        )

    async def relay():
        # The slot is held until the last byte. Releasing when the upstream
        # call returns would free it while the model is still generating.
        try:
            async with _client.stream(
                "POST", f"{settings.litellm_base}/v1/chat/completions",
                json=body, headers=headers,
            ) as r:
                async for chunk in r.aiter_raw():
                    yield chunk
        except Exception as exc:                               # noqa: BLE001
            log.warning("stream to upstream failed: %s", exc)
            yield b'data: {"error":"upstream failed"}\n\n'
        finally:
            await adm.__aexit__(None, None, None)

    return StreamingResponse(
        relay(), media_type="text/event-stream",
        headers={**info, "Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/v1/models")
async def models(authorization: str = Header(None)):
    token = _bearer(authorization)
    r = await _client.get(
        f"{settings.litellm_base}/v1/models",
        headers={"Authorization": f"Bearer {token}"},
    )
    return JSONResponse(r.json(), status_code=r.status_code)


# Audio and embeddings are cheap and short. They pass straight through: it
# costs more to queue them than to run them.
@app.post("/v1/embeddings")
async def embeddings(request: Request, authorization: str = Header(None)):
    token = _bearer(authorization)
    r = await _client.post(
        f"{settings.litellm_base}/v1/embeddings",
        json=await request.json(),
        headers={"Authorization": f"Bearer {token}"},
    )
    return JSONResponse(r.json(), status_code=r.status_code)


# ---------------------------------------------------------------------------
# Batch jobs


@app.post("/v1/jobs")
async def create_job(request: Request, authorization: str = Header(None)):
    token = _bearer(authorization)
    alias = await resolve_alias(token)
    profile = await store.profile(alias)

    body = await request.json()
    kind = body.get("kind", "comfyui")
    if kind not in ("comfyui", "batch"):
        raise HTTPException(400, "kind must be 'comfyui' or 'batch'.")
    if not profile.allow_heavy:
        raise HTTPException(403, "This key may not submit batch jobs.")
    if not store.ready:
        raise HTTPException(
            503, "Job storage is unavailable; batch jobs need Postgres."
        )

    job_id = await store.job_create(
        alias, kind, "heavy", body.get("model"), profile.priority, body
    )
    return {"id": job_id, "status": "queued",
            "poll": f"/v1/jobs/{job_id}"}


@app.get("/v1/jobs/{job_id}")
async def get_job(job_id: int, authorization: str = Header(None)):
    token = _bearer(authorization)
    alias = await resolve_alias(token)
    job = await store.job_get(job_id)
    if not job:
        raise HTTPException(404, "No such job.")
    if alias != "owner" and job["key_alias"] != alias:
        raise HTTPException(404, "No such job.")
    return json.loads(json.dumps(job, default=str))


@app.delete("/v1/jobs/{job_id}")
async def cancel_job(job_id: int, authorization: str = Header(None)):
    token = _bearer(authorization)
    alias = await resolve_alias(token)
    job = await store.job_get(job_id)
    if not job or (alias != "owner" and job["key_alias"] != alias):
        raise HTTPException(404, "No such job.")
    ok = await store.job_cancel(job_id)
    return {"id": job_id, "cancelled": ok,
            "note": None if ok else "Already running or finished."}


# ---------------------------------------------------------------------------
# Operations


def _require_master(authorization: str | None) -> None:
    token = _bearer(authorization)
    if not settings.master_key or token != settings.master_key:
        raise HTTPException(403, "Master key required.")


@app.get("/queue/status")
async def queue_status(authorization: str = Header(None)):
    _bearer(authorization)                     # any valid-looking key may look
    snap = scheduler.snapshot()
    snap["store"] = "connected" if store.ready else "unavailable"
    return snap


@app.get("/queue/jobs")
async def queue_jobs(limit: int = 50, authorization: str = Header(None)):
    _require_master(authorization)
    return json.loads(json.dumps(await store.jobs_recent(limit), default=str))


@app.post("/queue/drain")
async def drain(authorization: str = Header(None)):
    _require_master(authorization)
    scheduler.draining = True
    return {"draining": True, "inflight": scheduler.inflight_heavy + scheduler.inflight_light,
            "queued": len(scheduler.waiting)}


@app.post("/queue/resume")
async def resume(authorization: str = Header(None)):
    _require_master(authorization)
    scheduler.draining = False
    scheduler._wake.set()
    return {"draining": False}


@app.get("/healthz")
async def healthz():
    return {"ok": True, "store": store.ready, "gpu": gpu.snapshot()["available"]}
