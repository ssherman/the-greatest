"""The browser boundary (spec §8).

`Fetcher` depends on the thin `Browser` and `BrowserSession` protocols below and
makes every decision itself. This module only drives a browser and reports what
happened in the service's own exception types. It is the only module that
imports camoufox or playwright, and only inside functions, so every other module
imports without the `fetcher` extra installed.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Literal, Protocol

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
