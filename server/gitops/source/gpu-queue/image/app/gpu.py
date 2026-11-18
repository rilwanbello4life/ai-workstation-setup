"""Live GPU state, polled from the host probe.

Everything here is best effort. If the probe is unreachable the queue must
keep working on static limits rather than refusing traffic, so `available`
is false and the scheduler falls back to its floor values.
"""

import asyncio
import logging
import time

import httpx

from .config import settings

log = logging.getLogger("gpu")


class GpuState:
    def __init__(self) -> None:
        self.available = False
        self.utilization_pct = 0
        self.memory_free_mb = 0
        self.memory_total_mb = 0
        self.memory_used_mb = 0
        self.updated_at = 0.0
        self.reason = "not polled yet"
        self._task: asyncio.Task | None = None

    @property
    def stale(self) -> bool:
        # Three missed polls. Acting on a minute-old reading is worse than
        # admitting we do not know.
        return time.time() - self.updated_at > settings.gpu_poll_interval * 3

    def snapshot(self) -> dict:
        return {
            "available": self.available and not self.stale,
            "utilization_pct": self.utilization_pct,
            "memory_free_mb": self.memory_free_mb,
            "memory_used_mb": self.memory_used_mb,
            "memory_total_mb": self.memory_total_mb,
            "age_s": round(time.time() - self.updated_at, 1) if self.updated_at else None,
            "reason": None if self.available else self.reason,
        }

    async def _poll_once(self, client: httpx.AsyncClient) -> None:
        try:
            r = await client.get(f"{settings.gpu_probe_base}/gpu", timeout=5)
            r.raise_for_status()
            data = r.json()
        except Exception as exc:                               # noqa: BLE001
            self.available = False
            self.reason = f"probe unreachable: {type(exc).__name__}"
            return

        if not data.get("available"):
            self.available = False
            self.reason = data.get("reason", "probe reports no GPU")
            self.updated_at = time.time()
            return

        self.available = True
        self.reason = ""
        self.utilization_pct = int(data.get("utilization_pct", 0))
        self.memory_free_mb = int(data.get("memory_free_mb", 0))
        self.memory_used_mb = int(data.get("memory_used_mb", 0))
        self.memory_total_mb = int(data.get("memory_total_mb", 0))
        self.updated_at = time.time()

    async def run(self) -> None:
        async with httpx.AsyncClient() as client:
            while True:
                await self._poll_once(client)
                await asyncio.sleep(settings.gpu_poll_interval)

    def start(self) -> None:
        self._task = asyncio.create_task(self.run())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass


gpu = GpuState()
