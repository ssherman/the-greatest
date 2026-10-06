"""How much /resolve work the service takes on at once, and for how long.

A resolve is a chain of Parquet scans that can use every core and the whole
DuckDB memory pool, and both are shared by every query in the process. The
service also never learns that a client gave up: Uvicorn does not cancel a
sync route when the connection closes. Without these two limits, each request
a client abandoned kept running beside the next one (2026-10-06: four imports
left `/resolve` timing out for 25 minutes, until the API was restarted).

  * `ResolveSlots`: at most N resolves run; the next one is refused at once
    (503) rather than queued, so a caller can count it and move on.
  * `Deadline`: a resolve still running after its deadline is interrupted,
    so the work stops when the client stops waiting.
"""

from __future__ import annotations

import contextlib
import threading
from collections.abc import Iterator

import duckdb


class Busy(Exception):
    """Every resolve slot is taken."""


class ResolveSlots:
    def __init__(self, limit: int) -> None:
        self.limit = limit
        self._semaphore = threading.BoundedSemaphore(limit)

    @contextlib.contextmanager
    def hold(self) -> Iterator[None]:
        """Hold one slot for the block, or raise `Busy` without waiting."""
        if not self._semaphore.acquire(blocking=False):
            raise Busy(f"busy: {self.limit} resolve(s) already running")
        try:
            yield
        finally:
            self._semaphore.release()


class Deadline:
    """Interrupts `cursor` from a timer thread once `seconds` have passed.

    It keeps interrupting every `interval` seconds until the block exits:
    DuckDB's interrupt stops only the statement running at that moment (one
    sent between statements is a no-op), and a resolve runs a chain of them.
    `expired` says whether the deadline passed, so the caller can tell its
    own interrupt from any other failure.
    """

    def __init__(
        self, cursor: duckdb.DuckDBPyConnection, seconds: float, interval: float = 0.25
    ) -> None:
        self.cursor = cursor
        self.seconds = seconds
        self.interval = interval
        self.expired = False
        self._done = threading.Event()
        self._thread = threading.Thread(target=self._watch, name="resolve-deadline", daemon=True)

    def __enter__(self) -> Deadline:
        self._thread.start()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self._done.set()
        self._thread.join()

    def _watch(self) -> None:
        if self._done.wait(self.seconds):
            return
        self.expired = True
        while not self._done.is_set():
            self.cursor.interrupt()
            self._done.wait(self.interval)
