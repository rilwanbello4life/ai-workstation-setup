"""Admission control and fair queueing.

The problem this solves: several people share one 16 GB card, and the
failure mode is not that requests are slow, it is that five arriving at once
each try to allocate KV cache and some of them fail outright partway through
a generation.

Three rules, in order of how often they bind:

  1. One heavy job at a time. Heavy means xhigh reasoning or a batch render,
     either of which can hold the card for minutes.
  2. Light jobs up to a limit that MOVES. It starts at the floor and rises
     while the card looks underused, which is the "accept another job if the
     GPU is not busy" behaviour - a quiet card earns concurrency rather than
     being limited by a number someone guessed once.
  3. Each person gets at most max_concurrent at a time, so one caller in a
     loop queues behind themselves instead of in front of everyone else.

Fairness between people is priority first, then arrival. Within one person
it is strictly arrival order.

Single replica by design: the counters are in memory. Two replicas would
each admit up to the limit and the card would see twice what either thinks.
The Deployment says replicas: 1 and should stay that way.
"""

import asyncio
import itertools
import logging
import time
from dataclasses import dataclass, field

from .config import settings
from .gpu import gpu

log = logging.getLogger("sched")

_seq = itertools.count()


@dataclass(order=True)
class Ticket:
    # Ordering tuple first: priority, then arrival. The sequence number
    # breaks ties deterministically so two requests in the same millisecond
    # cannot swap places between dispatcher passes.
    sort_key: tuple = field(init=False, repr=False)

    key_alias: str = ""
    weight: str = "light"
    priority: int = 100
    job_id: int | None = None
    queued_at: float = field(default_factory=time.time)
    admitted: asyncio.Event = field(default_factory=asyncio.Event)
    cancelled: bool = False
    seq: int = field(default_factory=lambda: next(_seq))

    def __post_init__(self):
        self.sort_key = (self.priority, self.seq)

    @property
    def wait_ms(self) -> int:
        return int((time.time() - self.queued_at) * 1000)


class Scheduler:
    def __init__(self) -> None:
        self.waiting: list[Ticket] = []
        self.inflight_heavy = 0
        self.inflight_light = 0
        self.per_user: dict[str, int] = {}
        self.draining = False
        self._task: asyncio.Task | None = None
        self._wake = asyncio.Event()
        self.admitted_total = 0
        self.rejected_total = 0

    # -- classification -----------------------------------------------------

    @staticmethod
    def classify(model: str | None, body: dict) -> str:
        """Heavy or light, from the request alone.

        Conservative on purpose: a request that looks expensive is treated as
        expensive. Being wrong in this direction costs some concurrency;
        being wrong in the other costs a failed generation on a full card.
        """
        if model and model in settings.heavy_models:
            return "heavy"
        effort = str(body.get("reasoning_effort", "") or "").lower()
        if effort in settings.heavy_reasoning:
            return "heavy"
        for key in ("max_tokens", "max_completion_tokens"):
            try:
                if int(body.get(key) or 0) > settings.heavy_max_tokens:
                    return "heavy"
            except (TypeError, ValueError):
                pass
        return "light"

    # -- capacity -----------------------------------------------------------

    def light_limit(self) -> int:
        """How many light jobs may run right now.

        Rises above the floor only when the card is demonstrably quiet: low
        utilisation AND free VRAM comfortably beyond the reserve. Both
        conditions matter - utilisation alone goes to zero between tokens,
        and free memory alone says nothing about whether the SMs are busy.
        """
        state = gpu.snapshot()
        if not state["available"]:
            return settings.light_floor
        quiet = state["utilization_pct"] < settings.idle_util_pct
        roomy = state["memory_free_mb"] > settings.vram_reserve_mb + settings.growth_headroom_mb
        return settings.light_ceiling if (quiet and roomy) else settings.light_floor

    def _vram_ok(self) -> bool:
        state = gpu.snapshot()
        if not state["available"]:
            # No reading. Fall back to the static limits rather than
            # blocking everything on a probe outage.
            return True
        return state["memory_free_mb"] >= settings.vram_reserve_mb

    def can_admit(self, t: Ticket, profile_max: int) -> bool:
        if self.draining:
            return False
        if self.per_user.get(t.key_alias, 0) >= max(profile_max, 1):
            return False
        if not self._vram_ok():
            return False
        if t.weight == "heavy":
            # A heavy job also waits for light work to drain. Starting an
            # xhigh generation on top of three in-flight chats is how the
            # KV cache overcommits.
            return self.inflight_heavy < settings.max_heavy and self.inflight_light == 0
        if self.inflight_heavy > 0:
            return False
        return self.inflight_light < self.light_limit()

    # -- queue --------------------------------------------------------------

    def depth_for(self, key_alias: str) -> int:
        return sum(1 for t in self.waiting if t.key_alias == key_alias)

    def enqueue(self, t: Ticket) -> int:
        self.waiting.append(t)
        self.waiting.sort(key=lambda x: x.sort_key)
        self._wake.set()
        return self.waiting.index(t) + 1

    def position(self, t: Ticket) -> int:
        try:
            return self.waiting.index(t) + 1
        except ValueError:
            return 0

    def _occupy(self, t: Ticket) -> None:
        if t.weight == "heavy":
            self.inflight_heavy += 1
        else:
            self.inflight_light += 1
        self.per_user[t.key_alias] = self.per_user.get(t.key_alias, 0) + 1
        self.admitted_total += 1

    def release(self, t: Ticket) -> None:
        if t.weight == "heavy":
            self.inflight_heavy = max(0, self.inflight_heavy - 1)
        else:
            self.inflight_light = max(0, self.inflight_light - 1)
        left = self.per_user.get(t.key_alias, 1) - 1
        if left > 0:
            self.per_user[t.key_alias] = left
        else:
            self.per_user.pop(t.key_alias, None)
        self._wake.set()

    def abandon(self, t: Ticket) -> None:
        """A caller gave up or disconnected before being admitted."""
        t.cancelled = True
        if t in self.waiting:
            self.waiting.remove(t)
        self._wake.set()

    # -- dispatcher ---------------------------------------------------------

    async def _pass(self, profile_limit) -> None:
        # Walk the queue in order and admit everything that fits. Skipping
        # a blocked ticket and trying the next is what stops one person at
        # their concurrency limit from blocking the whole line.
        for t in list(self.waiting):
            if t.cancelled:
                self.waiting.remove(t)
                continue
            limit = await profile_limit(t.key_alias)
            if self.can_admit(t, limit):
                self.waiting.remove(t)
                self._occupy(t)
                t.admitted.set()

    async def run(self, profile_limit) -> None:
        while True:
            try:
                await asyncio.wait_for(
                    self._wake.wait(), timeout=settings.dispatch_interval
                )
            except asyncio.TimeoutError:
                pass
            self._wake.clear()
            try:
                await self._pass(profile_limit)
            except Exception:                                  # noqa: BLE001
                log.exception("dispatcher pass failed")

    def start(self, profile_limit) -> None:
        self._task = asyncio.create_task(self.run(profile_limit))

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    # -- reporting ----------------------------------------------------------

    def snapshot(self) -> dict:
        return {
            "draining": self.draining,
            "inflight": {
                "heavy": self.inflight_heavy,
                "light": self.inflight_light,
                "by_user": dict(self.per_user),
            },
            "limits": {
                "heavy": settings.max_heavy,
                "light_now": self.light_limit(),
                "light_floor": settings.light_floor,
                "light_ceiling": settings.light_ceiling,
            },
            "queued": len(self.waiting),
            "queued_by_user": {
                a: sum(1 for t in self.waiting if t.key_alias == a)
                for a in {t.key_alias for t in self.waiting}
            },
            "oldest_wait_ms": max((t.wait_ms for t in self.waiting), default=0),
            "totals": {
                "admitted": self.admitted_total,
                "rejected": self.rejected_total,
            },
            "gpu": gpu.snapshot(),
        }


scheduler = Scheduler()
