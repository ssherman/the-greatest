"""One fetch, end to end (spec §2, §3, §6): check the URL, wait for a slot,
launch a fresh browser, load the page, and decide what the caller gets back.

Every decision is made here against the thin `Browser` protocol, so all of it is
tested with a fake browser.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
from collections.abc import Callable, Iterator
from dataclasses import asdict, dataclass
from datetime import UTC, datetime

from fetcher.browser import (
    Browser,
    BrowserError,
    BrowserFailure,
    BrowserSession,
    InvalidSelector,
    LaunchFailed,
    NavigationTimeout,
    UpstreamUnreachable,
    WaitUntil,
)
from fetcher.budget import Budget, StageTimeout
from fetcher.guards import RequestFilter, first_non_public_hop
from fetcher.limiter import Limiter
from fetcher.settings import Settings
from fetcher.urlcheck import HostChecker, InvalidUrl, Resolver, Unresolvable, system_resolver

log = logging.getLogger("fetcher")

# The selector wait stops this long before the deadline, so the HTML can still be read.
SELECTOR_RESERVE_S = 2.0
# A browser that takes longer than this to close is a leaked process (spec §3).
CLOSE_LIMIT_S = 5.0
# The redirect backstop's own limit, outside the budget: a page already read
# must not become a timeout because its redirect hops needed a DNS lookup.
REDIRECT_CHECK_LIMIT_S = 2.0


@dataclass(frozen=True)
class FetchRequest:
    url: str
    wait_until: WaitUntil = "load"
    wait_for_selector: str | None = None
    timeout_ms: int = 30_000


@dataclass(frozen=True)
class FetchResult:
    url: str
    final_url: str
    status: int
    title: str
    html: str
    selector_found: bool | None
    elapsed_ms: int
    fetched_at: str


class FetchError(Exception):
    """A fetch that ends in the error body `{"error": code, "detail": detail}` (spec §2)."""

    def __init__(self, code: str, http_status: int, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.http_status = http_status
        self.detail = detail


@dataclass
class _LogLine:
    """One structured line per fetch (spec §9). Never the HTML."""

    event: str = "fetch"
    host: str | None = None
    outcome: str | None = None
    status: int | None = None
    elapsed_ms: int | None = None
    launch_ms: int | None = None
    waited: bool = False


def exit_process(reason: str) -> None:
    """The default fatal hook: log, then exit a second later so the current
    response still goes out. Compose's restart policy brings the container back
    with a new driver, display and fingerprint (spec §3)."""
    log.critical(json.dumps({"event": "exiting", "reason": reason}))
    asyncio.get_running_loop().call_later(1.0, os._exit, 1)


def _ms_since(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


class Fetcher:
    def __init__(
        self,
        settings: Settings,
        browser: Browser,
        *,
        resolver: Resolver = system_resolver,
        on_fatal: Callable[[str], None] = exit_process,
        close_limit_s: float = CLOSE_LIMIT_S,
    ) -> None:
        self.settings = settings
        self._browser = browser
        self._resolver = resolver
        self._on_fatal = on_fatal
        self._close_limit_s = close_limit_s
        self._limiter = Limiter(settings.max_concurrency, settings.host_interval_ms / 1000)
        self._launch_failures = 0
        self._started_at = time.monotonic()
        self._counts = {"ok": 0, "failed": 0, "in_flight": 0}

    async def start(self) -> None:
        await self._browser.start()

    async def stop(self) -> None:
        await self._browser.stop()

    def health(self) -> dict:
        return {
            **self._browser.describe(),
            "uptime_s": int(time.monotonic() - self._started_at),
            "fetches": dict(self._counts),
            "launch_failures_in_a_row": self._launch_failures,
        }

    async def fetch(self, request: FetchRequest) -> FetchResult:
        started = time.monotonic()
        line = _LogLine()
        self._counts["in_flight"] += 1
        try:
            result = await self._fetch(request, started, line)
        except FetchError as exc:
            self._counts["failed"] += 1
            line.outcome = exc.code
            raise
        except Exception:
            self._counts["failed"] += 1
            line.outcome = "internal_error"
            raise
        else:
            self._counts["ok"] += 1
            line.outcome = "ok"
            line.status = result.status
            return result
        finally:
            self._counts["in_flight"] -= 1
            line.elapsed_ms = _ms_since(started)
            log.info(json.dumps(asdict(line)))

    async def _fetch(self, request: FetchRequest, started: float, line: _LogLine) -> FetchResult:
        budget = Budget(request.timeout_ms / 1000)
        hosts = HostChecker(self._resolver)
        try:
            try:
                target = await budget.run(hosts.check(request.url), "resolving the host")
            except InvalidUrl as exc:
                raise FetchError("invalid_url", 400, str(exc)) from None
            except Unresolvable as exc:
                raise FetchError("upstream_unreachable", 502, str(exc)) from None
            line.host = target.host
            async with self._limiter.slot(target.host, budget) as waited:
                line.waited = waited
                return await self._in_browser(request, budget, hosts, started, line)
        except StageTimeout as exc:
            detail = f"the budget ran out while {exc.stage}"
            raise FetchError("navigation_timeout", 504, detail) from None

    async def _in_browser(
        self,
        request: FetchRequest,
        budget: Budget,
        hosts: HostChecker,
        started: float,
        line: _LogLine,
    ) -> FetchResult:
        request_filter = RequestFilter(hosts)
        launch_started = time.monotonic()
        try:
            session = await budget.run(
                self._browser.launch(request_filter, budget.remaining()), "launching the browser"
            )
        except StageTimeout:
            self._launch_failed()
            raise
        except LaunchFailed as exc:
            self._launch_failed()
            raise FetchError("browser_unavailable", 503, str(exc)) from None
        self._launch_failures = 0
        line.launch_ms = _ms_since(launch_started)
        try:
            return await self._read(session, request, budget, hosts, request_filter, started)
        finally:
            await self._close(session)

    async def _read(
        self,
        session: BrowserSession,
        request: FetchRequest,
        budget: Budget,
        hosts: HostChecker,
        request_filter: RequestFilter,
        started: float,
    ) -> FetchResult:
        with self._mapped("loading the page", request_filter):
            await budget.run(
                session.goto(request.url, request.wait_until, budget.remaining()),
                "loading the page",
            )

        selector_found = None
        if request.wait_for_selector is not None:
            selector_found = await self._wait_for_selector(
                session, request.wait_for_selector, budget, request_filter
            )

        with self._mapped("reading the HTML", request_filter):
            html = await budget.run(session.content(), "reading the HTML")
            title = await budget.run(session.title(), "reading the HTML")

        responses = session.document_responses()
        try:
            hop = await asyncio.wait_for(
                first_non_public_hop(responses, self._resolver), timeout=REDIRECT_CHECK_LIMIT_S
            )
        except TimeoutError:
            hop = ("the page's redirect hops", "could not be checked in time")
        if hop is not None:
            host, reason = hop
            raise FetchError("invalid_url", 400, f"the page went through {host}, which {reason}")
        if not responses:
            raise FetchError("browser_error", 502, "navigation produced no document response")

        size = len(html.encode("utf-8"))
        cap = self.settings.max_html_bytes
        if size > cap:
            raise FetchError(
                "html_too_large", 502, f"the HTML is {size} bytes, over the {cap}-byte cap"
            )

        last = responses[-1]
        return FetchResult(
            url=request.url,
            final_url=last.url,
            status=last.status,
            title=title,
            html=html,
            selector_found=selector_found,
            elapsed_ms=_ms_since(started),
            fetched_at=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        )

    async def _wait_for_selector(
        self,
        session: BrowserSession,
        selector: str,
        budget: Budget,
        request_filter: RequestFilter,
    ) -> bool:
        wait_s = budget.remaining() - SELECTOR_RESERVE_S
        if wait_s <= 0:
            return False
        with self._mapped("waiting for the selector", request_filter):
            return await budget.run(
                session.wait_for_selector(selector, wait_s), "waiting for the selector"
            )

    @contextlib.contextmanager
    def _mapped(self, stage: str, request_filter: RequestFilter) -> Iterator[None]:
        """Translate a browser failure during `stage` into the caller's answer (spec §2)."""
        try:
            yield
        except NavigationTimeout:
            raise StageTimeout(stage) from None
        except UpstreamUnreachable as exc:
            raise FetchError("upstream_unreachable", 502, str(exc)) from None
        except InvalidSelector as exc:
            raise FetchError("invalid_selector", 400, str(exc)) from None
        except BrowserError as exc:
            if request_filter.blocked_navigations:
                host = request_filter.blocked_navigations[0]
                detail = f"navigation to {host} was blocked: it resolves to a non-public address"
                raise FetchError("invalid_url", 400, detail) from None
            raise FetchError("browser_error", 502, str(exc)) from None
        except BrowserFailure as exc:
            raise FetchError("browser_error", 502, str(exc)) from None

    async def _close(self, session: BrowserSession) -> None:
        try:
            await asyncio.wait_for(session.close(), timeout=self._close_limit_s)
        except TimeoutError:
            # A Firefox that will not close is a leaked process (spec §3).
            self._on_fatal(f"a browser did not close within {self._close_limit_s:g}s")
        except Exception:  # an already-crashed browser can fail to close; it is gone anyway
            log.warning(json.dumps({"event": "close_failed"}))

    def _launch_failed(self) -> None:
        self._launch_failures += 1
        if self._launch_failures == self.settings.max_launch_failures:
            self._on_fatal(f"{self._launch_failures} browser launches failed in a row")
