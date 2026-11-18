import base64

import pytest
from fastapi.testclient import TestClient

from fetcher.api.main import create_app
from fetcher.browser import (
    BrowserError,
    DocumentResponse,
    FileResult,
    InvalidSelector,
    LaunchFailed,
    NavigationTimeout,
    UpstreamUnreachable,
)
from fetcher.fetcher import Fetcher
from fetcher.settings import Settings
from tests.fetcher.fakes import (
    FILE_BODY,
    FILE_URL,
    PAGE_HTML,
    PAGE_URL,
    ROBOTS_URL,
    FakeBrowser,
    Script,
    resolver,
)

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


FILE_RESPONSE_KEYS = {
    "url",
    "final_url",
    "status",
    "content_type",
    "body_base64",
    "size_bytes",
    "elapsed_ms",
    "fetched_at",
}


def file_script(**overrides) -> Script:
    overrides.setdefault("responses", [DocumentResponse(ROBOTS_URL, 200)])
    return Script(**overrides)


def test_fetch_file_returns_the_bytes_as_base64():
    client, _ = make_client(file_script())
    with client:
        response = client.post("/fetch_file", json={"url": FILE_URL})
    assert response.status_code == 200
    body = response.json()
    assert set(body) == FILE_RESPONSE_KEYS
    assert base64.b64decode(body["body_base64"], validate=True) == FILE_BODY
    assert (body["status"], body["size_bytes"], body["content_type"]) == (
        200,
        len(FILE_BODY),
        "application/octet-stream",
    )


def test_fetch_file_encodes_with_the_standard_alphabet_and_padding():
    odd = FileResult(outcome="ok", status=200, final_url=FILE_URL, body=b"\xfb\xff", size_bytes=2)
    client, _ = make_client(file_script(file_result=odd))
    with client:
        response = client.post("/fetch_file", json={"url": FILE_URL})
    assert response.json()["body_base64"] == "+/8="


def test_fetch_file_passes_a_missing_content_type_through_as_null():
    no_type = FileResult(
        outcome="ok", status=200, final_url=FILE_URL, body=FILE_BODY, size_bytes=len(FILE_BODY)
    )
    client, _ = make_client(file_script(file_result=no_type))
    with client:
        response = client.post("/fetch_file", json={"url": FILE_URL})
    assert response.status_code == 200
    assert response.json()["content_type"] is None


def test_fetch_file_takes_a_page_url_and_a_timeout():
    client, browser = make_client(file_script())
    with client:
        response = client.post(
            "/fetch_file",
            json={"url": FILE_URL, "page_url": "https://books.example/about", "timeout_ms": 5000},
        )
    assert response.status_code == 200
    assert browser.sessions[0].goto_calls[0][0] == "https://books.example/about"
    assert 0 < browser.launch_timeouts[0] <= 5.0


@pytest.mark.parametrize(
    "body",
    [
        {"url": FILE_URL, "wait_until": "load"},
        {"url": FILE_URL, "page_url": ""},
        {"url": ""},
        {"page_url": ROBOTS_URL},
        {"url": FILE_URL, "timeout_ms": 999},
    ],
)
def test_invalid_fetch_file_bodies_are_422_and_launch_nothing(body):
    client, browser = make_client(file_script())
    with client:
        assert client.post("/fetch_file", json=body).status_code == 422
    assert browser.launch_timeouts == []


@pytest.mark.parametrize(
    ("script", "extra", "status", "code"),
    [
        (
            file_script(file_result=FileResult(outcome="rejected", detail="blocked address")),
            {},
            502,
            "upstream_unreachable",
        ),
        (
            file_script(
                file_result=FileResult(
                    outcome="too_large", status=200, final_url=FILE_URL, size_bytes=11
                )
            ),
            {},
            502,
            "file_too_large",
        ),
        (file_script(), {"page_url": "https://other.example/x"}, 400, "invalid_url"),
        (file_script(launch_error=LaunchFailed("no display")), {}, 503, "browser_unavailable"),
        (file_script(file_delay_s=5), {"timeout_ms": 1000}, 504, "navigation_timeout"),
    ],
)
def test_fetch_file_errors_use_the_stable_error_body(script, extra, status, code):
    client, _ = make_client(script, settings=Settings(host_interval_ms=0, max_file_bytes=10))
    with client:
        response = client.post("/fetch_file", json={"url": FILE_URL, **extra})
    assert response.status_code == status
    body = response.json()
    assert set(body) == {"error", "detail"}
    assert body["error"] == code
    assert isinstance(body["detail"], str) and body["detail"]
