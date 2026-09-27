import pytest
from fastapi.testclient import TestClient

from fetcher.api.main import create_app
from fetcher.browser import (
    BrowserError,
    InvalidSelector,
    LaunchFailed,
    NavigationTimeout,
    UpstreamUnreachable,
)
from fetcher.fetcher import Fetcher
from fetcher.settings import Settings
from tests.fetcher.fakes import PAGE_HTML, PAGE_URL, FakeBrowser, Script, resolver

RESPONSE_KEYS = {
    "url",
    "final_url",
    "status",
    "title",
    "html",
    "selector_found",
    "elapsed_ms",
    "fetched_at",
}


def make_client(*scripts, settings=None, dns=None):
    browser = FakeBrowser(*scripts)
    fetcher = Fetcher(
        settings or Settings(host_interval_ms=0),
        browser,
        resolver=resolver(dns or {}),
        on_fatal=lambda reason: None,
    )
    return TestClient(create_app(fetcher)), browser


def test_fetch_returns_the_page():
    client, _ = make_client()
    with client:
        response = client.post("/fetch", json={"url": PAGE_URL})
    assert response.status_code == 200
    body = response.json()
    assert set(body) == RESPONSE_KEYS
    assert (body["status"], body["html"], body["selector_found"]) == (200, PAGE_HTML, None)


def test_an_unknown_field_is_a_422_naming_it_and_launches_nothing():
    client, browser = make_client()
    with client:
        response = client.post("/fetch", json={"url": PAGE_URL, "wait": "load"})
    assert response.status_code == 422
    assert response.json()["detail"][0]["loc"] == ["body", "wait"]
    assert browser.launch_timeouts == []


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"url": ""},
        {"url": PAGE_URL, "wait_until": "idle"},
        {"url": PAGE_URL, "timeout_ms": 999},
        {"url": PAGE_URL, "timeout_ms": 60_001},
        {"url": PAGE_URL, "wait_for_selector": ""},
    ],
)
def test_invalid_bodies_are_422(body):
    client, _ = make_client()
    with client:
        assert client.post("/fetch", json=body).status_code == 422


def test_timeout_bounds_and_default_come_from_settings():
    settings = Settings(host_interval_ms=0, default_timeout_ms=20_000, max_timeout_ms=45_000)
    client, browser = make_client(settings=settings)
    with client:
        assert (
            client.post("/fetch", json={"url": PAGE_URL, "timeout_ms": 45_001}).status_code == 422
        )
        assert client.post("/fetch", json={"url": PAGE_URL}).status_code == 200
    [(_, _, timeout_s)] = browser.sessions[0].goto_calls
    assert 19.5 < timeout_s <= 20.0


@pytest.mark.parametrize(
    ("script", "extra", "status", "code"),
    [
        (Script(), {"url": "http://127.0.0.1/"}, 400, "invalid_url"),
        (
            Script(selector_result=InvalidSelector("while parsing selector")),
            {"wait_for_selector": "div[["},
            400,
            "invalid_selector",
        ),
        (
            Script(goto_error=UpstreamUnreachable("NS_ERROR_UNKNOWN_HOST")),
            {},
            502,
            "upstream_unreachable",
        ),
        (Script(html="x" * 11), {}, 502, "html_too_large"),
        (Script(goto_error=BrowserError("boom")), {}, 502, "browser_error"),
        (Script(launch_error=LaunchFailed("no display")), {}, 503, "browser_unavailable"),
        (Script(goto_error=NavigationTimeout("Timeout")), {}, 504, "navigation_timeout"),
    ],
)
def test_errors_use_the_stable_error_body(script, extra, status, code):
    client, _ = make_client(
        script,
        settings=Settings(host_interval_ms=0, max_html_bytes=10),
        dns={"127.0.0.1": ["127.0.0.1"]},
    )
    with client:
        response = client.post("/fetch", json={"url": PAGE_URL, **extra})
    assert response.status_code == status
    body = response.json()
    assert set(body) == {"error", "detail"}
    assert body["error"] == code
    assert isinstance(body["detail"], str) and body["detail"]


def test_health_reports_versions_and_counters():
    client, _ = make_client()
    with client:
        client.post("/fetch", json={"url": PAGE_URL})
        response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert (body["camoufox_version"], body["browser_build"]) == ("fake", "fake/stable/0-beta.0")
    assert body["fetches"] == {"ok": 1, "failed": 0, "in_flight": 0}
    assert body["launch_failures_in_a_row"] == 0
    assert isinstance(body["uptime_s"], int)


def test_the_lifespan_starts_and_stops_the_browser_backend():
    client, browser = make_client()
    with client:
        assert browser.started and not browser.stopped
    assert browser.stopped


def test_there_is_no_version_endpoint():
    client, _ = make_client()
    with client:
        assert client.get("/version").status_code == 404
