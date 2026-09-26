"""The browser boundary (spec §8).

`Fetcher` depends on the thin `Browser` and `BrowserSession` protocols below and
makes every decision itself. This module only drives a browser and reports what
happened in the service's own exception types. It is the only module that
imports camoufox or playwright, and only inside functions, so every other module
imports without the `fetcher` extra installed.
"""

from __future__ import annotations

import asyncio
import contextlib
import functools
import importlib.metadata
import logging
import os
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, Literal, Protocol

WaitUntil = Literal["domcontentloaded", "load", "networkidle"]

# Called for every request the page makes, as (url, resource_type,
# is_navigation); returns whether it may go out. Built per fetch by
# `fetcher.guards.RequestFilter`.
RequestFilter = Callable[[str, str, bool], Awaitable[bool]]


class BrowserFailure(Exception):
    """A failure the browser layer reports, in the service's own terms."""


class LaunchFailed(BrowserFailure):
    """The browser did not start."""


class NavigationTimeout(BrowserFailure):
    """Playwright's own timeout fired."""


class UpstreamUnreachable(BrowserFailure):
    """The site could not be reached: DNS, a refused or reset connection, or TLS."""


class InvalidSelector(BrowserFailure):
    """`wait_for_selector` is not a selector Playwright can parse."""


class BrowserError(BrowserFailure):
    """Anything else the browser raised."""


@dataclass(frozen=True)
class DocumentResponse:
    """One main-frame document response. `redirect_chain` holds the URLs of the
    HTTP redirect hops that led to it, oldest first."""

    url: str
    status: int
    redirect_chain: tuple[str, ...] = ()


class BrowserSession(Protocol):
    """One launched browser with one page. Every coroutine but `close` raises
    only BrowserFailure subclasses."""

    async def goto(self, url: str, wait_until: WaitUntil, timeout_s: float) -> None: ...

    async def wait_for_selector(self, selector: str, timeout_s: float) -> bool: ...

    async def content(self) -> str: ...

    async def title(self) -> str: ...

    def document_responses(self) -> list[DocumentResponse]: ...

    async def close(self) -> None: ...


class Browser(Protocol):
    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def launch(self, request_filter: RequestFilter, timeout_s: float) -> BrowserSession: ...

    def describe(self) -> dict[str, str]: ...


# Substrings that mean Playwright (or the browser it forwarded the selector to)
# could not parse the selector at all, as opposed to the browser failing.
INVALID_SELECTOR_MARKERS = (
    "while parsing",
    "Malformed selector",
    "selector cannot be first",
    "is not a valid selector",
    "is not a legal expression",
)

# Firefox error names that mean the site could not be reached, as opposed to
# the browser failing.
UPSTREAM_ERROR_MARKERS = (
    "NS_ERROR_UNKNOWN_HOST",
    "NS_ERROR_CONNECTION_REFUSED",
    "NS_ERROR_NET_RESET",
    "NS_ERROR_NET_INTERRUPT",
    "NS_ERROR_NET_TIMEOUT",
    "NS_ERROR_OFFLINE",
    "SSL_ERROR_",
    "SEC_ERROR_",
    "MOZILLA_PKIX_ERROR_",
)


def playwright_ms(seconds: float) -> int:
    """Seconds as a Playwright timeout in ms. Never 0: to Playwright a timeout
    of 0 means "no timeout", so a nearly spent budget must round up to 1."""
    return max(1, round(seconds * 1000))


def _first_line(exc: BaseException) -> str:
    text = str(exc).strip()
    return text.splitlines()[0] if text else type(exc).__name__


def translate_playwright_error(exc: BaseException) -> BrowserFailure:
    """Map anything Playwright raised onto the service's own failure types."""
    from playwright.async_api import Error as PlaywrightError
    from playwright.async_api import TimeoutError as PlaywrightTimeoutError

    text = str(exc)
    if isinstance(exc, PlaywrightTimeoutError):
        return NavigationTimeout(_first_line(exc))
    if isinstance(exc, PlaywrightError):
        if any(marker in text for marker in INVALID_SELECTOR_MARKERS):
            return InvalidSelector(_first_line(exc))
        if any(marker in text for marker in UPSTREAM_ERROR_MARKERS):
            return UpstreamUnreachable(_first_line(exc))
    return BrowserError(_first_line(exc))


log = logging.getLogger("fetcher")


class CamoufoxBrowser:
    """The real backend (spec §3). One Playwright driver, one Xvfb display and
    one set of launch options, and so one fingerprint, for the life of the
    process; a fresh Firefox for every fetch."""

    def __init__(self, locale: str) -> None:
        self._locale = locale
        self._playwright: Any = None
        self._display: Any = None
        self._options: dict[str, Any] | None = None
        # Background browser closes started on cancellation (Addendum B): kept
        # here so the task is not garbage-collected mid-flight, discarded once
        # it is done.
        self._background_closes: set[asyncio.Task[None]] = set()

    async def start(self) -> None:
        from camoufox.pkgman import camoufox_path, launch_path
        from camoufox.utils import launch_options
        from camoufox.virtdisplay import VirtualDisplay
        from playwright.async_api import async_playwright

        # The image bakes the browser in (spec §4). download_if_missing=False
        # turns a missing browser into a startup failure, never a download.
        executable = launch_path(camoufox_path(download_if_missing=False))
        self._display = VirtualDisplay()
        display = await asyncio.to_thread(self._display.get)
        self._options = await asyncio.to_thread(
            functools.partial(
                launch_options,
                executable_path=executable,
                headless=False,
                virtual_display=display,
                locale=self._locale,
                humanize=False,
                geoip=False,
            )
        )
        self._playwright = await async_playwright().start()

    async def stop(self) -> None:
        if self._playwright is not None:
            await self._playwright.stop()
            self._playwright = None
        if self._display is not None:
            self._display.kill()
            self._display = None

    async def launch(self, request_filter: RequestFilter, timeout_s: float) -> BrowserSession:
        if self._playwright is None or self._options is None:
            raise LaunchFailed("the browser backend has not been started")
        from camoufox.async_api import AsyncNewBrowser

        options = {**self._options, "timeout": playwright_ms(timeout_s)}
        # Started as its own task and awaited through shield (Addendum B): a
        # cancellation landing here must not leave a Firefox nobody holds. The
        # shield keeps the task itself running so it can still be closed once
        # it lands; the done-callback does that closing.
        launch_task: asyncio.Task[Any] = asyncio.ensure_future(
            AsyncNewBrowser(self._playwright, from_options=options)
        )
        try:
            browser = await asyncio.shield(launch_task)
        except asyncio.CancelledError:
            launch_task.add_done_callback(self._close_if_launched)
            raise
        except Exception as exc:
            raise LaunchFailed(_first_line(exc)) from exc
        try:
            # A service worker could answer requests the route never sees.
            page = await browser.new_page(service_workers="block")
            session = CamoufoxSession(browser, page)
            await page.route("**/*", _route_handler(request_filter))
            page.on("response", session.record_response)
        except asyncio.CancelledError:
            # Never await a close inside a cancelled fetch: start it in the
            # background and let the cancellation propagate immediately.
            self._close_in_background(browser)
            raise
        except Exception as exc:
            await _close_quietly(browser)
            raise LaunchFailed(_first_line(exc)) from exc
        return session

    def _close_if_launched(self, task: asyncio.Task[Any]) -> None:
        """Done-callback for a launch task shielded from a cancellation. If the
        launch went on to succeed, nobody else holds the browser it produced;
        close it. If it failed, retrieve the exception so asyncio never logs
        "exception was never retrieved"; there is nothing to close."""
        if task.cancelled():
            return
        if task.exception() is not None:
            return
        self._close_in_background(task.result())

    def _close_in_background(self, browser: Any) -> None:
        close_task = asyncio.ensure_future(_close_quietly(browser))
        self._background_closes.add(close_task)
        close_task.add_done_callback(self._background_closes.discard)

    def describe(self) -> dict[str, str]:
        try:
            version = importlib.metadata.version("camoufox")
        except importlib.metadata.PackageNotFoundError:
            version = "not installed"
        return {
            "camoufox_version": version,
            "browser_build": os.environ.get("CAMOUFOX_BROWSER", "unknown"),
        }


class CamoufoxSession:
    def __init__(self, browser: Any, page: Any) -> None:
        self._browser = browser
        self._page = page
        self._responses: list[DocumentResponse] = []

    def record_response(self, response: Any) -> None:
        """Keep every main-frame document response with its redirect chain; the
        fetcher takes `status` from the last one (spec §2)."""
        try:
            request = response.request
            if not request.is_navigation_request() or response.frame != self._page.main_frame:
                return
            chain: list[str] = []
            earlier = request.redirected_from
            while earlier is not None:
                chain.append(earlier.url)
                earlier = earlier.redirected_from
            self._responses.append(
                DocumentResponse(
                    url=response.url, status=response.status, redirect_chain=tuple(reversed(chain))
                )
            )
        except Exception:
            # A response for a frame being torn down; there is nothing to record.
            log.debug("response skipped", exc_info=True)

    async def goto(self, url: str, wait_until: WaitUntil, timeout_s: float) -> None:
        try:
            await self._page.goto(url, wait_until=wait_until, timeout=playwright_ms(timeout_s))
        except Exception as exc:
            raise translate_playwright_error(exc) from exc

    async def wait_for_selector(self, selector: str, timeout_s: float) -> bool:
        from playwright.async_api import TimeoutError as PlaywrightTimeoutError

        try:
            # attached, not visible: the service returns HTML, and visibility
            # depends on the stylesheets it blocks (spec §2).
            await self._page.wait_for_selector(
                selector, state="attached", timeout=playwright_ms(timeout_s)
            )
        except PlaywrightTimeoutError:
            return False
        except Exception as exc:
            raise translate_playwright_error(exc) from exc
        return True

    async def content(self) -> str:
        try:
            return await self._page.content()
        except Exception as exc:
            raise translate_playwright_error(exc) from exc

    async def title(self) -> str:
        try:
            return await self._page.title()
        except Exception as exc:
            raise translate_playwright_error(exc) from exc

    def document_responses(self) -> list[DocumentResponse]:
        return list(self._responses)

    async def close(self) -> None:
        await _close_quietly(self._browser)


def _route_handler(request_filter: RequestFilter) -> Callable[[Any, Any], Awaitable[None]]:
    async def handle(route: Any, request: Any) -> None:
        try:
            allowed = await request_filter(
                request.url, request.resource_type, request.is_navigation_request()
            )
        except Exception:
            allowed = False
        # The page can close under a pending route; then there is nothing left to decide.
        with contextlib.suppress(Exception):
            if allowed:
                await route.continue_()
            else:
                await route.abort("blockedbyclient")

    return handle


async def _close_quietly(browser: Any) -> None:
    # An already-crashed browser can fail to close; it is gone either way.
    with contextlib.suppress(Exception):
        await browser.close()
