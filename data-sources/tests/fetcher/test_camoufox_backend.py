import asyncio
import base64
import gc
import importlib.metadata
import json
import logging

import pytest
from playwright.async_api import Error as PlaywrightError

from fetcher.api.main import create_app
from fetcher.browser import (
    FILE_FETCH_SCRIPT,
    BrowserError,
    CamoufoxBrowser,
    CamoufoxSession,
    DocumentResponse,
    FileResult,
    LaunchFailed,
    UpstreamUnreachable,
    _route_handler,
)
from fetcher.fetcher import exit_process


def test_create_app_without_a_fetcher_uses_camoufox_and_the_environment(monkeypatch):
    monkeypatch.setenv("FETCHER_LOCALE", "en-GB")
    monkeypatch.setenv("CAMOUFOX_BROWSER", "official/stable/152.0.4-beta.31")

    app = create_app()  # no lifespan: nothing starts, nothing launches

    service = app.state.fetcher
    assert service.settings.locale == "en-GB"
    health = service.health()
    assert health["camoufox_version"] == importlib.metadata.version("camoufox")
    assert health["browser_build"] == "official/stable/152.0.4-beta.31"
    # A background close that hangs must exit the process the same way a
    # foreground one would (browser.py's `_close_with_limit`).
    assert service._browser._on_close_hang is exit_process


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
    closed = asyncio.Event()

    class _FakeBrowser:
        def __init__(self) -> None:
            self.closed = False

        async def new_page(self, **kwargs):
            entered.set()
            await asyncio.sleep(0.1)
            return _FakePage()

        async def close(self) -> None:
            self.closed = True
            closed.set()

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

    # The launch task keeps running in the background (it was shielded); wait
    # for its done-callback to close the fake browser (a fixed sleep here can
    # flake under load, as test 1 above already fixed).
    await asyncio.wait_for(closed.wait(), 5)
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


class _StreamingPage:
    """Replays the lifecycle order Firefox showed on a bookshop.org product page
    (2026-09-26): Playwright marks the main document finished when its headers
    arrive, so `networkidle` fires while the rest of the HTML is still
    streaming, before `domcontentloaded` and `load`."""

    ORDER = (("networkidle", 0.05), ("domcontentloaded", 0.2), ("load", 0.25))

    def __init__(self) -> None:
        self.reached = {state: asyncio.Event() for state, _ in self.ORDER}
        self.timeouts: list[float] = []
        self._clock: asyncio.Task | None = None

    async def _run_clock(self) -> None:
        started = asyncio.get_running_loop().time()
        for state, at in self.ORDER:
            await asyncio.sleep(max(0.0, started + at - asyncio.get_running_loop().time()))
            self.reached[state].set()

    async def goto(self, url, wait_until, timeout):
        self.timeouts.append(timeout)
        self._clock = asyncio.create_task(self._run_clock())
        await self.reached[wait_until].wait()

    async def wait_for_load_state(self, state, timeout):
        self.timeouts.append(timeout)
        await self.reached[state].wait()


@pytest.mark.anyio
async def test_networkidle_never_returns_a_half_parsed_page():
    page = _StreamingPage()
    session = CamoufoxSession(object(), page)

    await session.goto("https://bookshop.org/p/books/x/1", "networkidle", 5.0)

    assert page.reached["load"].is_set()
    # Every wait draws on the one navigation budget.
    assert all(1 <= t <= 5000 for t in page.timeouts)


class _Route:
    def __init__(self) -> None:
        self.outcome = None

    async def continue_(self):
        self.outcome = "continued"

    async def abort(self, reason):
        self.outcome = "aborted"


class _Frame:
    def __init__(self, parent_frame) -> None:
        self.parent_frame = parent_frame


class _Request:
    url = "https://books.example/"
    resource_type = "document"

    def __init__(self, navigation: bool, frame) -> None:
        self._navigation = navigation
        self._frame = frame

    def is_navigation_request(self) -> bool:
        return self._navigation

    @property
    def frame(self):
        if isinstance(self._frame, BaseException):
            raise self._frame
        return self._frame


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("navigation", "frame", "main_frame_navigation"),
    [
        pytest.param(True, _Frame(parent_frame=None), True, id="main-frame navigation"),
        pytest.param(True, _Frame(parent_frame=object()), False, id="iframe navigation"),
        pytest.param(False, _Frame(parent_frame=None), False, id="subresource"),
        pytest.param(True, RuntimeError("service worker request"), False, id="no frame"),
    ],
)
async def test_the_filter_hears_only_main_frame_navigations_as_navigations(
    navigation, frame, main_frame_navigation
):
    """Only the page's own navigations decide the fetch's error code; an ad
    iframe refused for its host must not. Working out which is which must never
    change whether the request goes out."""
    heard = []

    async def request_filter(url, resource_type, is_navigation):
        heard.append(is_navigation)
        return True

    route = _Route()
    await _route_handler(request_filter)(route, _Request(navigation, frame))

    assert heard == [main_frame_navigation]
    assert route.outcome == "continued"


FILE = "https://books.example/sitemaps/products.1.xml.gz"
FINAL = "https://cdn.books.example/sitemaps/products.1.xml.gz"


class _EvaluatingPage:
    """A page whose `evaluate` records its arguments and returns a canned answer
    (or raises it); `during` runs first, as the browser's events would."""

    main_frame = object()

    def __init__(self, answer, during=None, canonical=None) -> None:
        self.answer = answer
        self.during = during
        self.canonical = canonical  # the canonicalizing evaluate's answer (or error)
        self.calls: list[tuple] = []  # the file script's calls only

    async def evaluate(self, script, arg):
        if script is not FILE_FETCH_SCRIPT:  # the canonicalizing call
            if isinstance(self.canonical, BaseException):
                raise self.canonical
            return self.canonical or arg
        self.calls.append((script, arg))
        if self.during is not None:
            self.during()
        if isinstance(self.answer, BaseException):
            raise self.answer
        return self.answer


def _ok(body: bytes, **extra):
    return {
        "outcome": "ok",
        "status": 200,
        "final_url": FILE,
        "content_type": None,
        "size_bytes": len(body),
        "body_base64": base64.b64encode(body).decode(),
        **extra,
    }


@pytest.mark.anyio
async def test_fetch_file_decodes_the_page_scripts_answer():
    page = _EvaluatingPage(_ok(b"hello"))
    result = await CamoufoxSession(object(), page).fetch_file(FILE, 1024)
    assert result == FileResult(
        outcome="ok", status=200, final_url=FILE, content_type=None, body=b"hello", size_bytes=5
    )
    assert page.calls[0][1] == [FILE, 1024]  # the url and the cap, in that order


@pytest.mark.anyio
async def test_fetch_file_decodes_an_empty_file():
    page = _EvaluatingPage(_ok(b""))
    result = await CamoufoxSession(object(), page).fetch_file(FILE, 1024)
    assert (result.outcome, result.body, result.size_bytes) == ("ok", b"", 0)


@pytest.mark.anyio
async def test_fetch_file_reports_too_large_and_rejected_without_a_body():
    big = _EvaluatingPage(
        {
            "outcome": "too_large",
            "status": 200,
            "final_url": FILE,
            "content_type": "x",
            "size_bytes": 9999,
        }
    )
    result = await CamoufoxSession(object(), big).fetch_file(FILE, 10)
    assert result == FileResult(
        outcome="too_large",
        status=200,
        final_url=FILE,
        content_type="x",
        body=b"",
        size_bytes=9999,
    )

    message = "NetworkError when attempting to fetch resource."
    rejected = _EvaluatingPage({"outcome": "rejected", "detail": message})
    result = await CamoufoxSession(object(), rejected).fetch_file(FILE, 10)
    assert result == FileResult(outcome="rejected", detail=message)


@pytest.mark.anyio
async def test_the_page_script_uses_the_variant_that_works_in_camoufox():
    page = _EvaluatingPage(_ok(b"x"))
    await CamoufoxSession(object(), page).fetch_file(FILE, 1024)
    script = page.calls[0][0]
    assert script is FILE_FETCH_SCRIPT
    assert "readAsDataURL" in script
    assert "credentials" in script
    assert 'lastIndexOf(",")' in script
    for banned in ("Uint8Array", "fromCharCode", "btoa"):
        assert banned not in script


@pytest.mark.anyio
async def test_a_failing_page_script_is_a_browser_error():
    page = _EvaluatingPage(PlaywrightError("Page.evaluate: boom"))
    with pytest.raises(BrowserError):
        await CamoufoxSession(object(), page).fetch_file(FILE, 1024)


@pytest.mark.anyio
@pytest.mark.parametrize(
    "answer",
    [
        None,
        {"outcome": "ok"},
        _ok(b"x", body_base64="!!not base64!!"),
        _ok(b"x", body_base64="é"),
        {"outcome": "weird"},
    ],
)
async def test_an_answer_that_is_not_the_scripts_shape_is_a_browser_error(answer):
    page = _EvaluatingPage(answer)
    with pytest.raises(BrowserError):
        await CamoufoxSession(object(), page).fetch_file(FILE, 1024)


class _Req:
    def __init__(self, url, *, navigation=False, redirected_from=None) -> None:
        self.url = url
        self.redirected_from = redirected_from
        self._navigation = navigation

    def is_navigation_request(self):
        return self._navigation


class _Resp:
    def __init__(self, request, status, frame) -> None:
        self.request = request
        self.url = request.url
        self.status = status
        self.frame = frame


@pytest.mark.anyio
async def test_file_responses_keeps_each_hop_of_the_file_request_with_its_chain():
    page = _EvaluatingPage(_ok(b"x"))
    session = CamoufoxSession(object(), page)
    first = _Req(FILE)
    last = _Req(FINAL, redirected_from=first)

    def during():
        session.record_response(
            _Resp(_Req("https://books.example/robots.txt", navigation=True), 200, page.main_frame)
        )
        session.record_response(_Resp(_Req("https://books.example/app.js"), 200, object()))
        session.record_response(_Resp(first, 302, page.main_frame))
        session.record_response(_Resp(last, 200, page.main_frame))

    page.during = during
    await session.fetch_file(FILE, 1024)

    assert session.file_responses() == [
        DocumentResponse(FILE, 302),
        DocumentResponse(FINAL, 200, redirect_chain=(FILE,)),
    ]
    assert session.document_responses() == [
        DocumentResponse("https://books.example/robots.txt", 200)
    ]


@pytest.mark.anyio
async def test_file_responses_match_the_browsers_canonical_spelling_of_the_url():
    spelled = "https://Books.example:443/sitemaps/products.1.xml.gz#frag"
    canonical = "https://books.example/sitemaps/products.1.xml.gz"
    page = _EvaluatingPage(_ok(b"x"), canonical=canonical)
    session = CamoufoxSession(object(), page)
    page.during = lambda: session.record_response(_Resp(_Req(canonical), 200, page.main_frame))

    await session.fetch_file(spelled, 1024)

    assert session.file_responses() == [DocumentResponse(canonical, 200)]
    assert page.calls[0][1] == [spelled, 1024]  # the script still gets the caller's spelling


@pytest.mark.anyio
@pytest.mark.parametrize(
    "marker",
    [
        "Execution context was destroyed, most likely because of a navigation",
        "Page.evaluate: most likely because of a navigation",
        "Frame was detached",
    ],
)
@pytest.mark.parametrize("stage", ["canonicalizing", "file script"])
async def test_a_page_that_navigates_during_the_file_request_is_upstream_unreachable(marker, stage):
    error = PlaywrightError(marker)
    if stage == "canonicalizing":
        page = _EvaluatingPage(_ok(b"x"), canonical=error)
    else:
        page = _EvaluatingPage(error)
    with pytest.raises(UpstreamUnreachable):
        await CamoufoxSession(object(), page).fetch_file(FILE, 1024)


@pytest.mark.anyio
async def test_a_failing_canonicalization_is_a_browser_error():
    page = _EvaluatingPage(_ok(b"x"), canonical=PlaywrightError("Page.evaluate: boom"))
    with pytest.raises(BrowserError):
        await CamoufoxSession(object(), page).fetch_file(FILE, 1024)
    assert page.calls == []
