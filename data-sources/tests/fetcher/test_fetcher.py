import asyncio
import json
import logging
import re

import pytest

from fetcher.browser import (
    BrowserError,
    DocumentResponse,
    InvalidSelector,
    LaunchFailed,
    NavigationTimeout,
    UpstreamUnreachable,
)
from fetcher.fetcher import LAUNCH_HANG_S, Fetcher, FetchError, FetchRequest
from fetcher.settings import Settings
from tests.fetcher.fakes import PAGE_HTML, PAGE_URL, FakeBrowser, Script, resolver

pytestmark = pytest.mark.anyio

DNS = {"intranet.example": ["10.0.0.7"], "gone.example": OSError("Name or service not known")}


def build(*scripts, settings=None, default=None, close_limit_s=0.2, launch_hang_s=LAUNCH_HANG_S):
    fatal: list[str] = []
    browser = FakeBrowser(*scripts, default=default)
    fetcher = Fetcher(
        settings or Settings(host_interval_ms=0),
        browser,
        resolver=resolver(DNS),
        on_fatal=fatal.append,
        close_limit_s=close_limit_s,
        launch_hang_s=launch_hang_s,
    )
    return fetcher, browser, fatal


async def fetch_error(fetcher, url=PAGE_URL, **kwargs) -> FetchError:
    with pytest.raises(FetchError) as caught:
        await fetcher.fetch(FetchRequest(url=url, **kwargs))
    return caught.value


def failing_launch():
    return Script(launch_error=LaunchFailed("the driver is gone"))


# ------------------------------------------------------------------ the page


async def test_a_fetch_returns_the_page_and_closes_its_browser():
    fetcher, browser, _ = build()

    result = await fetcher.fetch(FetchRequest(url=PAGE_URL))

    assert (result.url, result.final_url, result.status) == (PAGE_URL, PAGE_URL, 200)
    assert (result.title, result.html) == ("A Book", PAGE_HTML)
    assert result.selector_found is None
    assert result.elapsed_ms >= 0
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", result.fetched_at)
    [session] = browser.sessions
    assert session.closed


async def test_goto_gets_the_url_the_wait_condition_and_the_remaining_budget():
    fetcher, browser, _ = build()

    await fetcher.fetch(FetchRequest(url=PAGE_URL, wait_until="networkidle", timeout_ms=30_000))

    [(url, wait_until, timeout_s)] = browser.sessions[0].goto_calls
    assert (url, wait_until) == (PAGE_URL, "networkidle")
    assert 29.5 < timeout_s <= 30.0


async def test_an_upstream_403_is_data_not_an_error():
    fetcher, _, _ = build(Script(responses=[DocumentResponse(PAGE_URL, 403)]))
    assert (await fetcher.fetch(FetchRequest(url=PAGE_URL))).status == 403


async def test_status_and_final_url_come_from_the_last_main_frame_response():
    # A Cloudflare challenge: the interstitial is a 403, then the browser
    # navigates to the real page on its own (spec §2).
    real = "https://books.example/book/1?cleared"
    fetcher, _, _ = build(
        Script(responses=[DocumentResponse(PAGE_URL, 403), DocumentResponse(real, 200)])
    )

    result = await fetcher.fetch(FetchRequest(url=PAGE_URL))

    assert (result.status, result.final_url) == (200, real)


# -------------------------------------------------------------- the selector


async def test_the_selector_wait_ends_two_seconds_before_the_deadline():
    fetcher, browser, _ = build()

    result = await fetcher.fetch(
        FetchRequest(url=PAGE_URL, wait_for_selector="h1", timeout_ms=30_000)
    )

    assert result.selector_found is True
    [(selector, timeout_s)] = browser.sessions[0].selector_calls
    assert selector == "h1"
    assert 27.5 < timeout_s <= 28.0


async def test_a_selector_that_never_appears_still_returns_the_page():
    fetcher, _, _ = build(
        Script(selector_result=False, responses=[DocumentResponse(PAGE_URL, 403)])
    )

    result = await fetcher.fetch(FetchRequest(url=PAGE_URL, wait_for_selector="h1.title"))

    assert (result.selector_found, result.status, result.html) == (False, 403, PAGE_HTML)


async def test_there_is_no_selector_wait_when_the_budget_is_inside_the_reserve():
    fetcher, browser, _ = build()

    result = await fetcher.fetch(
        FetchRequest(url=PAGE_URL, wait_for_selector="h1", timeout_ms=1500)
    )

    assert result.selector_found is False
    assert browser.sessions[0].selector_calls == []


async def test_an_unparseable_selector_is_a_400_not_a_browser_error():
    failure = InvalidSelector('Unexpected token "[" while parsing css selector "div[["')
    fetcher, _, _ = build(Script(selector_result=failure))
    error = await fetch_error(fetcher, wait_for_selector="div[[")
    assert (error.code, error.http_status) == ("invalid_selector", 400)


# ------------------------------------------------------------ URLs and hosts


async def test_a_private_address_is_refused_before_any_browser_launches():
    fetcher, browser, _ = build()
    error = await fetch_error(fetcher, url="http://intranet.example/admin")
    assert (error.code, error.http_status) == ("invalid_url", 400)
    assert "10.0.0.7" in error.detail
    assert browser.launch_timeouts == []


async def test_a_host_that_does_not_resolve_is_upstream_unreachable_without_a_launch():
    fetcher, browser, _ = build()
    error = await fetch_error(fetcher, url="https://gone.example/")
    assert (error.code, error.http_status) == ("upstream_unreachable", 502)
    assert browser.launch_timeouts == []


@pytest.mark.parametrize(
    ("failure", "code", "status"),
    [
        (
            UpstreamUnreachable("page.goto: NS_ERROR_CONNECTION_REFUSED"),
            "upstream_unreachable",
            502,
        ),
        (BrowserError("page.goto: Navigation interrupted"), "browser_error", 502),
        (NavigationTimeout("page.goto: Timeout 30000ms exceeded."), "navigation_timeout", 504),
    ],
)
async def test_navigation_failures_map_to_their_error_codes(failure, code, status):
    fetcher, browser, _ = build(Script(goto_error=failure))
    error = await fetch_error(fetcher)
    assert (error.code, error.http_status) == (code, status)
    assert browser.sessions[0].closed


async def test_a_navigation_the_filter_refused_for_a_private_host_is_invalid_url():
    fetcher, _, _ = build(
        Script(
            requests=[("http://intranet.example/", "document", True)],
            goto_error=BrowserError("page.goto: NS_BINDING_ABORTED"),
        )
    )
    error = await fetch_error(fetcher)
    assert (error.code, error.http_status) == ("invalid_url", 400)
    assert "intranet.example" in error.detail


async def test_a_redirect_through_a_private_address_returns_no_page():
    hops = ("https://books.example/go", "http://intranet.example/")
    fetcher, browser, _ = build(
        Script(responses=[DocumentResponse(PAGE_URL, 200, redirect_chain=hops)])
    )
    error = await fetch_error(fetcher)
    assert (error.code, error.http_status) == ("invalid_url", 400)
    assert "intranet.example" in error.detail
    assert browser.sessions[0].closed


async def test_the_session_gets_a_filter_that_blocks_assets_and_private_hosts():
    requests = [
        ("https://cdn.example/cover.jpg", "image", False),
        ("https://books.example/app.js", "script", False),
        ("http://intranet.example/api", "xhr", False),
    ]
    fetcher, browser, _ = build(Script(requests=requests))

    await fetcher.fetch(FetchRequest(url=PAGE_URL))

    assert browser.sessions[0].filter_decisions == [
        ("https://cdn.example/cover.jpg", False),
        ("https://books.example/app.js", True),
        ("http://intranet.example/api", False),
    ]


# -------------------------------------------------------------- the response


async def test_no_document_response_is_a_browser_error():
    fetcher, _, _ = build(Script(responses=[]))
    error = await fetch_error(fetcher)
    assert (error.code, error.http_status) == ("browser_error", 502)


async def test_the_html_cap_counts_bytes_not_characters():
    settings = Settings(host_interval_ms=0, max_html_bytes=10)
    # 5 x "é" is 10 bytes (at the cap); 6 x "é" is 12 bytes but only 6 characters.
    fetcher, _, _ = build(Script(html="é" * 5), Script(html="é" * 6), settings=settings)

    assert (await fetcher.fetch(FetchRequest(url=PAGE_URL))).html == "é" * 5
    error = await fetch_error(fetcher)

    assert (error.code, error.http_status) == ("html_too_large", 502)
    assert "12 bytes" in error.detail


async def test_a_lone_surrogate_in_html_or_title_is_replaced_not_a_crash():
    # A JS slice() cutting an emoji in half, or Playwright's own JSON transport
    # restoring one -- either way this must not reach `.encode("utf-8")` raw.
    fetcher, _, _ = build(Script(html="<p>\ud83d</p>", title="\ud83d"))

    result = await fetcher.fetch(FetchRequest(url=PAGE_URL))

    assert "�" in result.html
    assert "�" in result.title
    result.html.encode("utf-8")  # must not raise


# ------------------------------------------------------------- the budget


async def test_a_slow_dns_lookup_runs_the_budget_out_while_resolving():
    async def slow(host):
        await asyncio.sleep(1)
        return ["93.184.215.14"]

    fetcher = Fetcher(
        Settings(host_interval_ms=0), FakeBrowser(), resolver=slow, on_fatal=[].append
    )
    error = await fetch_error(fetcher, timeout_ms=100)
    assert (error.code, error.http_status) == ("navigation_timeout", 504)
    assert error.detail == "the budget ran out while resolving the host"


@pytest.mark.parametrize(
    ("script", "stage"),
    [
        (Script(launch_delay_s=1), "launching the browser"),
        (Script(goto_delay_s=1), "loading the page"),
        (Script(content_delay_s=1), "reading the HTML"),
    ],
)
async def test_the_budget_running_out_names_the_stage(script, stage):
    fetcher, _, _ = build(script)
    error = await fetch_error(fetcher, timeout_ms=100)
    assert (error.code, error.http_status) == ("navigation_timeout", 504)
    assert error.detail == f"the budget ran out while {stage}"


async def test_a_slot_wait_that_outlasts_the_budget_is_a_navigation_timeout():
    settings = Settings(max_concurrency=1, host_interval_ms=0)
    fetcher, _, _ = build(default=Script(goto_delay_s=0.5), settings=settings)
    first = asyncio.create_task(fetcher.fetch(FetchRequest(url="https://a.example/")))
    await asyncio.sleep(0.05)

    error = await fetch_error(fetcher, url="https://b.example/", timeout_ms=100)

    assert error.detail == "the budget ran out while waiting for a slot"
    await first


async def test_host_spacing_that_outlasts_the_budget_is_a_navigation_timeout():
    fetcher, _, _ = build(settings=Settings(host_interval_ms=5000))
    await fetcher.fetch(FetchRequest(url=PAGE_URL))

    error = await fetch_error(fetcher, timeout_ms=100)

    assert error.detail == "the budget ran out while waiting for host spacing"


# ----------------------------------------------------------- launch failures


async def test_a_failed_launch_is_browser_unavailable():
    fetcher, _, fatal = build(failing_launch())
    error = await fetch_error(fetcher)
    assert (error.code, error.http_status) == ("browser_unavailable", 503)
    assert fetcher.health()["launch_failures_in_a_row"] == 1
    assert fatal == []


async def test_three_failed_launches_in_a_row_exit_the_process():
    fetcher, _, fatal = build(failing_launch(), failing_launch(), failing_launch())
    for _ in range(3):
        await fetch_error(fetcher)
    assert len(fatal) == 1
    assert "3 browser launches failed in a row" in fatal[0]


async def test_a_successful_launch_resets_the_count():
    fetcher, _, fatal = build(
        failing_launch(), failing_launch(), Script(), failing_launch(), failing_launch()
    )
    for _ in range(2):
        await fetch_error(fetcher)
    await fetcher.fetch(FetchRequest(url=PAGE_URL))
    for _ in range(2):
        await fetch_error(fetcher)
    assert fatal == []
    assert fetcher.health()["launch_failures_in_a_row"] == 2


async def test_a_launch_that_runs_the_budget_out_counts_as_a_failed_launch():
    # A launch given at least LAUNCH_HANG_S and still not back is a dead
    # driver; lower the floor so these 50ms launches count as hung.
    fetcher, _, fatal = build(*[Script(launch_delay_s=1) for _ in range(3)], launch_hang_s=0.01)
    for _ in range(3):
        assert (await fetch_error(fetcher, timeout_ms=50)).code == "navigation_timeout"
    assert len(fatal) == 1


async def test_a_launch_starved_of_budget_does_not_count():
    # Launch + page takes about a second; a launch given only 50ms was
    # starved of budget, not hung, and must not count toward the fatal limit.
    fetcher, _, fatal = build(Script(launch_delay_s=1))
    error = await fetch_error(fetcher, timeout_ms=50)
    assert error.code == "navigation_timeout"
    assert fetcher.health()["launch_failures_in_a_row"] == 0
    assert fatal == []


# ------------------------------------------------------------------ closing


async def test_a_browser_that_will_not_close_exits_the_process_after_answering():
    fetcher, _, fatal = build(Script(close_delay_s=1), close_limit_s=0.05)
    result = await fetcher.fetch(FetchRequest(url=PAGE_URL))
    assert result.status == 200
    assert len(fatal) == 1
    assert "did not close" in fatal[0]


@pytest.mark.parametrize(
    "script",
    [
        Script(goto_error=BrowserError("boom")),
        Script(content_error=BrowserError("the page crashed")),
        Script(html="x" * 11),
        Script(selector_result=InvalidSelector("while parsing selector")),
        Script(responses=[DocumentResponse("http://intranet.example/", 200)]),
    ],
)
async def test_the_browser_is_closed_on_every_failure_path(script):
    fetcher, browser, _ = build(script, settings=Settings(host_interval_ms=0, max_html_bytes=10))
    await fetch_error(fetcher, wait_for_selector="h1")
    assert browser.sessions[0].closed


async def test_the_browser_is_closed_when_the_budget_expires_mid_read():
    fetcher, browser, _ = build(Script(goto_delay_s=1))
    error = await fetch_error(fetcher, timeout_ms=100)
    assert error.code == "navigation_timeout"
    assert browser.sessions[0].closed
    assert fetcher.health()["fetches"]["in_flight"] == 0


async def test_the_browser_is_closed_when_the_fetch_is_cancelled_mid_goto():
    fetcher, browser, _ = build(Script(goto_delay_s=1))
    task = asyncio.create_task(fetcher.fetch(FetchRequest(url=PAGE_URL)))
    await asyncio.sleep(0.05)

    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert browser.sessions[0].closed
    assert fetcher.health()["fetches"]["in_flight"] == 0


async def test_a_cancelled_fetch_counts_as_failed_and_logs_cancelled(caplog):
    fetcher, _, _ = build(Script(goto_delay_s=1))
    with caplog.at_level(logging.INFO, logger="fetcher"):
        task = asyncio.create_task(fetcher.fetch(FetchRequest(url=PAGE_URL)))
        await asyncio.sleep(0.05)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    assert fetcher.health()["fetches"] == {"ok": 0, "failed": 1, "in_flight": 0}
    lines = [json.loads(r.getMessage()) for r in caplog.records if r.name == "fetcher"]
    assert lines[-1]["outcome"] == "cancelled"


# ------------------------------------------------------- health and logging


async def test_health_counts_fetches_and_carries_the_browser_versions():
    fetcher, _, _ = build(Script(goto_delay_s=0.2), Script(goto_error=BrowserError("boom")))
    task = asyncio.create_task(fetcher.fetch(FetchRequest(url=PAGE_URL)))
    await asyncio.sleep(0.05)
    assert fetcher.health()["fetches"]["in_flight"] == 1
    await task
    await fetch_error(fetcher)

    health = fetcher.health()

    assert health["fetches"] == {"ok": 1, "failed": 1, "in_flight": 0}
    assert (health["camoufox_version"], health["browser_build"]) == (
        "fake",
        "fake/stable/0-beta.0",
    )
    assert isinstance(health["uptime_s"], int)
    assert health["launch_failures_in_a_row"] == 0


async def test_each_fetch_logs_one_json_line_and_never_the_html(caplog):
    fetcher, _, _ = build()
    with caplog.at_level(logging.INFO, logger="fetcher"):
        await fetcher.fetch(FetchRequest(url=PAGE_URL))
        await fetch_error(fetcher, url="http://intranet.example/")

    lines = [json.loads(r.getMessage()) for r in caplog.records if r.name == "fetcher"]
    assert [line["outcome"] for line in lines] == ["ok", "invalid_url"]
    ok = lines[0]
    assert (ok["host"], ok["status"], ok["waited"]) == ("books.example", 200, False)
    assert isinstance(ok["elapsed_ms"], int) and isinstance(ok["launch_ms"], int)
    assert all("<html" not in r.getMessage() for r in caplog.records)


async def test_start_and_stop_drive_the_browser_backend():
    fetcher, browser, _ = build()
    await fetcher.start()
    assert browser.started
    await fetcher.stop()
    assert browser.stopped
