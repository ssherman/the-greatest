"""A fetch's time budget (spec §2): every stage draws on one deadline."""

from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable


class StageTimeout(Exception):
    """The budget ran out during `stage`. Maps to 504 navigation_timeout."""

    def __init__(self, stage: str) -> None:
        super().__init__(stage)
        self.stage = stage


class Budget:
    def __init__(self, seconds: float, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._deadline = clock() + seconds

    def remaining(self) -> float:
        return max(0.0, self._deadline - self._clock())

    async def run[T](self, awaitable: Awaitable[T], stage: str) -> T:
        """Await `awaitable` within what is left; StageTimeout(stage) when it runs out."""
        try:
            return await asyncio.wait_for(awaitable, timeout=self.remaining())
        except TimeoutError:
            raise StageTimeout(stage) from None
