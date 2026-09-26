"""The concurrency cap and per-host politeness (spec §3).

Same-host fetches queue on a per-host lock, so their starts are at least
`host_interval_s` apart. A fetch waiting on its host holds no global slot, so a
burst to one site never starves the others.
"""

from __future__ import annotations

import asyncio
import contextlib
import math
import time
from collections.abc import AsyncIterator, Callable

from fetcher.budget import Budget, StageTimeout


class Limiter:
    def __init__(
        self,
        max_concurrency: int,
        host_interval_s: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._slots = asyncio.Semaphore(max_concurrency)
        self._interval = host_interval_s
        self._clock = clock
        self._host_locks: dict[str, asyncio.Lock] = {}
        self._last_start: dict[str, float] = {}

    @contextlib.asynccontextmanager
    async def slot(self, host: str, budget: Budget) -> AsyncIterator[bool]:
        """Hold one browser slot for a fetch to `host`, yielding whether the
        fetch had to wait. Raises StageTimeout naming the wait that ran out."""
        lock = self._host_locks.setdefault(host, asyncio.Lock())
        waited = lock.locked()
        await budget.run(lock.acquire(), "waiting for host spacing")
        try:
            gap = self._last_start.get(host, -math.inf) + self._interval - self._clock()
            if gap > 0:
                waited = True
                if gap >= budget.remaining():
                    raise StageTimeout("waiting for host spacing")
                await asyncio.sleep(gap)
            waited = waited or self._slots.locked()
            await budget.run(self._slots.acquire(), "waiting for a slot")
            self._last_start[host] = self._clock()
        finally:
            lock.release()
        try:
            yield waited
        finally:
            self._slots.release()
