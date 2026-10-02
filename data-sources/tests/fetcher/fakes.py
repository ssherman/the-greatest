"""Test stand-ins for the fetcher's two external dependencies: DNS and the browser.

No test launches a real browser (spec §9); `FakeBrowser` implements the
`fetcher.browser.Browser` protocol from a list of scripts.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

from fetcher.browser import DocumentResponse, RequestFilter

PUBLIC_ADDRESS = "93.184.215.14"
PAGE_URL = "https://books.example/book/1"
PAGE_HTML = "<html><head><title>A Book</title></head><body><h1>A Book</h1></body></html>"


def resolver(table: dict[str, list[str] | BaseException]):
    """A fake DNS. `table` maps a host to its addresses or to an exception to
    raise; any other host resolves to one public address. `.calls` records
    every host asked for, in order."""
    calls: list[str] = []

    async def resolve(host: str) -> list[str]:
        calls.append(host)
        answer = table.get(host, [PUBLIC_ADDRESS])
        if isinstance(answer, BaseException):
            raise answer
        return answer

    resolve.calls = calls  # type: ignore[attr-defined]
    return resolve


@dataclass
class Script:
    """What one fake launch does. The defaults are a clean 200 page."""

    launch_error: BaseException | None = None
    launch_delay_s: float = 0.0
    # Requests the page "makes" during goto, as (url, resource_type,
    # is_navigation); each goes through the fetcher's request filter.
    requests: list[tuple[str, str, bool]] = field(default_factory=list)
    goto_error: BaseException | None = None
    goto_delay_s: float = 0.0
    responses: list[DocumentResponse] = field(
        default_factory=lambda: [DocumentResponse(PAGE_URL, 200)]
    )
    selector_result: bool | BaseException = True
    html: str = PAGE_HTML
    title: str = "A Book"
    content_error: BaseException | None = None
    content_delay_s: float = 0.0
    close_delay_s: float = 0.0


class FakeSession:
    def __init__(self, script: Script, request_filter: RequestFilter) -> None:
        self.script = script
        self.request_filter = request_filter
        self.goto_calls: list[tuple[str, str, float]] = []
        self.selector_calls: list[tuple[str, float]] = []
        self.filter_decisions: list[tuple[str, bool]] = []
        self.closed = False

    async def goto(self, url: str, wait_until: str, timeout_s: float) -> None:
        self.goto_calls.append((url, wait_until, timeout_s))
        for request_url, resource_type, is_navigation in self.script.requests:
            allowed = await self.request_filter(request_url, resource_type, is_navigation)
            self.filter_decisions.append((request_url, allowed))
        if self.script.goto_delay_s:
            await asyncio.sleep(self.script.goto_delay_s)
        if self.script.goto_error is not None:
            raise self.script.goto_error

    async def wait_for_selector(self, selector: str, timeout_s: float) -> bool:
        self.selector_calls.append((selector, timeout_s))
        if isinstance(self.script.selector_result, BaseException):
            raise self.script.selector_result
        return self.script.selector_result

    async def content(self) -> str:
        if self.script.content_delay_s:
            await asyncio.sleep(self.script.content_delay_s)
        if self.script.content_error is not None:
            raise self.script.content_error
        return self.script.html

    async def title(self) -> str:
        return self.script.title

    def document_responses(self) -> list[DocumentResponse]:
        return list(self.script.responses)

    async def close(self) -> None:
        if self.script.close_delay_s:
            await asyncio.sleep(self.script.close_delay_s)
        self.closed = True


class FakeBrowser:
    """Each launch takes the next script; when they run out, `default` (a clean page)."""

    def __init__(self, *scripts: Script, default: Script | None = None) -> None:
        self._scripts = list(scripts)
        self._default = default or Script()
        self.sessions: list[FakeSession] = []
        self.launch_timeouts: list[float] = []
        self.started = False
        self.stopped = False

    async def start(self) -> None:
        self.started = True

    async def stop(self) -> None:
        self.stopped = True

    async def launch(self, request_filter: RequestFilter, timeout_s: float) -> FakeSession:
        script = self._scripts.pop(0) if self._scripts else self._default
        self.launch_timeouts.append(timeout_s)
        if script.launch_delay_s:
            await asyncio.sleep(script.launch_delay_s)
        if script.launch_error is not None:
            raise script.launch_error
        session = FakeSession(script, request_filter)
        self.sessions.append(session)
        return session

    def describe(self) -> dict[str, str]:
        return {"camoufox_version": "fake", "browser_build": "fake/stable/0-beta.0"}
