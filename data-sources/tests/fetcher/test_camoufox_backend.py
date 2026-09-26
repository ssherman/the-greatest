import asyncio
import gc
import importlib.metadata
import json
import logging

import pytest

from fetcher.api.main import create_app
from fetcher.browser import CamoufoxBrowser, LaunchFailed


def test_create_app_without_a_fetcher_uses_camoufox_and_the_environment(monkeypatch):
    monkeypatch.setenv("FETCHER_LOCALE", "en-GB")
    monkeypatch.setenv("CAMOUFOX_BROWSER", "official/stable/152.0.4-beta.31")

    app = create_app()  # no lifespan: nothing starts, nothing launches

    service = app.state.fetcher
    assert service.settings.locale == "en-GB"
    health = service.health()
    assert health["camoufox_version"] == importlib.metadata.version("camoufox")
    assert health["browser_build"] == "official/stable/152.0.4-beta.31"


def test_describe_says_unknown_when_the_build_is_not_set(monkeypatch):
    monkeypatch.delenv("CAMOUFOX_BROWSER", raising=False)
    assert CamoufoxBrowser("en-US").describe()["browser_build"] == "unknown"


@pytest.mark.anyio
async def test_launching_before_start_is_a_launch_failure():
    async def allow_all(url, resource_type, is_navigation):
        return True

    with pytest.raises(LaunchFailed, match="not been started"):
        await CamoufoxBrowser("en-US").launch(allow_all, 5.0)


async def _allow_all(url, resource_type, is_navigation):
    return True


def _started_browser(**kwargs) -> CamoufoxBrowser:
    """A `CamoufoxBrowser` with `start()`'s effects stood in for, so `launch`
    believes it is ready without touching camoufox or playwright. `kwargs` are
    forwarded to `__init__` (`on_close_hang`, `close_limit_s`)."""
    browser = CamoufoxBrowser("en-US", **kwargs)
    browser._playwright = object()
    browser._options = {}
    return browser


class _FakePage:
    async def route(self, pattern, handler):
        pass

    def on(self, event, handler):
        pass


@pytest.mark.anyio
async def test_cancelling_during_the_browser_launch_closes_it_once_it_lands(monkeypatch):
    """Addendum B, case 1: cancel `launch(...)` while the fake `AsyncNewBrowser`
    is still sleeping; let it finish; the fake browser must end up closed."""

    closed = asyncio.Event()

    class _FakeBrowser:
        def __init__(self) -> None:
            self.closed = False

        async def close(self) -> None:
            self.closed = True
            closed.set()

    fake_browser = _FakeBrowser()
    entered = asyncio.Event()

    async def fake_async_new_browser(playwright, from_options):
        entered.set()
        await asyncio.sleep(0.1)
        return fake_browser

    monkeypatch.setattr("camoufox.async_api.AsyncNewBrowser", fake_async_new_browser)

    browser = _started_browser()
    task = asyncio.ensure_future(browser.launch(_allow_all, 5.0))
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    # The launch task keeps running in the background (it was shielded); wait
    # for its done-callback to close the fake browser (fix round 1, Minor 3:
    # a fixed sleep here can flake under load).
    await asyncio.wait_for(closed.wait(), 5)
    assert fake_browser.closed


@pytest.mark.anyio
async def test_cancelling_during_new_page_closes_the_browser_in_the_background(monkeypatch):
    """Addendum B, case 2: make the fake browser's `new_page` sleep, cancel
    `launch(...)` during it; the fake browser must end up closed."""

    entered = asyncio.Event()

    class _FakeBrowser:
        def __init__(self) -> None:
            self.closed = False

        async def new_page(self, **kwargs):
            entered.set()
            await asyncio.sleep(0.1)
            return _FakePage()

        async def close(self) -> None:
            self.closed = True

    fake_browser = _FakeBrowser()

    async def fake_async_new_browser(playwright, from_options):
        return fake_browser

    monkeypatch.setattr("camoufox.async_api.AsyncNewBrowser", fake_async_new_browser)

    browser = _started_browser()
    task = asyncio.ensure_future(browser.launch(_allow_all, 5.0))
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    await asyncio.sleep(0.3)
    assert fake_browser.closed


@pytest.mark.anyio
async def test_a_background_close_that_hangs_calls_on_close_hang_and_logs_it(monkeypatch, caplog):
    """Important 1 (fix round 1): a background close obeys the same close
    limit as the Fetcher's own foreground close. On a timeout it logs
    `close_hung` on the `fetcher` logger and calls the fatal hook."""

    entered = asyncio.Event()

    class _FakeBrowser:
        async def new_page(self, **kwargs):
            entered.set()
            await asyncio.sleep(0.2)
            return _FakePage()

        async def close(self) -> None:
            await asyncio.sleep(0.2)

    fake_browser = _FakeBrowser()

    async def fake_async_new_browser(playwright, from_options):
        return fake_browser

    monkeypatch.setattr("camoufox.async_api.AsyncNewBrowser", fake_async_new_browser)

    hangs: list[str] = []
    hang_seen = asyncio.Event()

    def record_hang(reason: str) -> None:
        hangs.append(reason)
        hang_seen.set()

    browser = _started_browser(on_close_hang=record_hang, close_limit_s=0.05)

    with caplog.at_level(logging.CRITICAL, logger="fetcher"):
        task = asyncio.ensure_future(browser.launch(_allow_all, 5.0))
        await entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        await asyncio.wait_for(hang_seen.wait(), 5)

    assert len(hangs) == 1
    assert "did not finish within" in hangs[0]
    lines = [json.loads(r.getMessage()) for r in caplog.records if r.name == "fetcher"]
    assert any(line.get("event") == "close_hung" for line in lines)
    assert all("<html" not in r.getMessage() for r in caplog.records)


@pytest.mark.anyio
async def test_a_launch_that_fails_after_a_cancel_never_logs_an_unretrieved_exception(monkeypatch):
    """Minor 4 (fix round 1): if the shielded launch task goes on to FAIL
    (not succeed) after the fetch awaiting it was cancelled, the done-callback
    must retrieve its exception -- otherwise asyncio logs "exception was never
    retrieved" through the loop's exception handler once the task is garbage
    collected. `-W always` cannot show this: it is not a `warnings`-module
    warning, so this test installs its own exception handler instead."""

    entered = asyncio.Event()

    async def fake_async_new_browser(playwright, from_options):
        entered.set()
        await asyncio.sleep(0.1)
        raise RuntimeError("the fake browser process crashed on startup")

    monkeypatch.setattr("camoufox.async_api.AsyncNewBrowser", fake_async_new_browser)

    browser = _started_browser()
    task = asyncio.ensure_future(browser.launch(_allow_all, 5.0))
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    reports: list[dict] = []
    loop = asyncio.get_running_loop()
    previous_handler = loop.get_exception_handler()
    loop.set_exception_handler(lambda loop, context: reports.append(context))
    try:
        # Let the fake AsyncNewBrowser's sleep finish and its exception land,
        # then force collection of the now-unreferenced launch task.
        await asyncio.sleep(0.2)
        gc.collect()
        # A __del__-triggered report reaches the handler on a later loop turn.
        await asyncio.sleep(0)
    finally:
        loop.set_exception_handler(previous_handler)

    assert reports == []
