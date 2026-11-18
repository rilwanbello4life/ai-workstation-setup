"""Batch GPU work: ComfyUI renders, one at a time.

Inference is interactive and someone is waiting for it, so it holds an HTTP
connection. Batch work is not: a video render can take many minutes, and
nobody should keep a socket open for it. So it goes to Postgres, returns an
id immediately, and this worker runs it when the card is free.

The serialisation here is the whole point. ComfyUI will happily accept ten
queued workflows and try to keep the GPU saturated, which on a 16 GB card
shared with a resident language model means an allocation failure rather
than a queue. One job at a time, admitted through the same scheduler as
everything else, is the behaviour that actually works.
"""

import asyncio
import json
import logging
import os
import time

import httpx

from .config import settings
from .scheduler import Ticket, scheduler
from .store import store

log = logging.getLogger("jobs")

POLL_SECONDS = 3
# A single render that has not finished in this long is stuck. ComfyUI does
# not reliably report failure for an out-of-memory node, so a ceiling is the
# only thing that stops one bad workflow occupying the queue forever.
MAX_RUN_SECONDS = 3600


async def _run_comfyui(client: httpx.AsyncClient, job: dict) -> dict:
    payload = job.get("payload") or {}
    if isinstance(payload, str):
        payload = json.loads(payload)

    workflow = payload.get("workflow") or payload.get("prompt")
    if not workflow:
        raise ValueError("No 'workflow' in the job payload.")

    r = await client.post(
        f"{settings.comfyui_base}/prompt",
        json={"prompt": workflow}, timeout=60,
    )
    r.raise_for_status()
    prompt_id = (r.json() or {}).get("prompt_id")
    if not prompt_id:
        raise ValueError(f"ComfyUI did not return a prompt_id: {r.text[:200]}")

    log.info("job %s -> comfyui prompt %s", job["id"], prompt_id)
    deadline = time.time() + MAX_RUN_SECONDS

    while time.time() < deadline:
        await asyncio.sleep(POLL_SECONDS)
        try:
            h = await client.get(
                f"{settings.comfyui_base}/history/{prompt_id}", timeout=30
            )
            if h.status_code != 200:
                continue
            hist = h.json() or {}
        except Exception as exc:                               # noqa: BLE001
            log.debug("history poll failed: %s", exc)
            continue

        entry = hist.get(prompt_id)
        if not entry:
            continue

        status = (entry.get("status") or {})
        if status.get("status_str") == "error" or status.get("completed") is False:
            raise RuntimeError(
                f"ComfyUI reported an error: {json.dumps(status)[:300]}"
            )

        outputs = entry.get("outputs")
        if outputs:
            files = []
            for node in outputs.values():
                for group in ("images", "gifs", "videos"):
                    for item in node.get(group, []) or []:
                        if item.get("filename"):
                            files.append(item["filename"])
            # ComfyUI writes into its own output directory on the host,
            # which is where the files actually are. Recording the names is
            # enough; copying tens of gigabytes of video through this pod
            # would be pointless.
            manifest = {
                "prompt_id": prompt_id,
                "files": files,
                "comfyui_output_dir": "~/ai/comfyui/output",
            }
            try:
                os.makedirs(settings.output_dir, exist_ok=True)
                with open(
                    os.path.join(settings.output_dir, f"job-{job['id']}.json"), "w"
                ) as fh:
                    json.dump(manifest, fh, indent=2)
            except OSError as exc:
                log.warning("could not write job manifest: %s", exc)
            return manifest

    raise TimeoutError(f"No result after {MAX_RUN_SECONDS}s.")


async def batch_worker(client: httpx.AsyncClient) -> None:
    """Pick up queued batch jobs and run them through the scheduler."""
    while True:
        await asyncio.sleep(POLL_SECONDS)
        if scheduler.draining or not store.ready:
            continue

        try:
            pending = await store.jobs_pending_batch()
        except Exception as exc:                               # noqa: BLE001
            log.warning("could not read pending jobs: %s", exc)
            continue

        if not pending:
            continue

        job = pending[0]

        # Batch work takes a ticket like anything else, so it queues behind
        # an in-flight heavy generation instead of racing it.
        t = Ticket(
            key_alias=job["key_alias"] or "owner",
            weight="heavy",
            priority=job["priority"],
            job_id=job["id"],
        )
        scheduler.enqueue(t)

        try:
            await asyncio.wait_for(t.admitted.wait(), timeout=settings.queue_timeout)
        except asyncio.TimeoutError:
            scheduler.abandon(t)
            continue

        started = time.time()
        await store.job_started(job["id"], t.wait_ms)
        try:
            result = await _run_comfyui(client, job)
            await store.job_finished(
                job["id"], "done", int((time.time() - started) * 1000), None, result
            )
            log.info("job %s done in %.0fs", job["id"], time.time() - started)
        except Exception as exc:                               # noqa: BLE001
            await store.job_finished(
                job["id"], "failed", int((time.time() - started) * 1000), str(exc)[:500]
            )
            log.warning("job %s failed: %s", job["id"], exc)
        finally:
            scheduler.release(t)
