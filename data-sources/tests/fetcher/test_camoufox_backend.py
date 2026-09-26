import asyncio
import importlib.metadata

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


def _started_browser() -> CamoufoxBrowser:
    """A `CamoufoxBrowser` with `start()`'s effects stood in for, so `launch`
    believes it is ready without touching camoufox or playwright."""
    browser = CamoufoxBrowser("en-US")
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

    class _FakeBrowser:
        def __init__(self) -> None:
            self.closed = False

        async def close(self) -> None:
            self.closed = True

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

    # The launch task keeps running in the background (it was shielded); give
    # it time to finish and its done-callback time to close the browser.
    await asyncio.sleep(0.3)
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
