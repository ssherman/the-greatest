import subprocess
import sys

import pytest
from playwright.async_api import Error as PlaywrightError
from playwright.async_api import TimeoutError as PlaywrightTimeoutError

from fetcher.browser import (
    BrowserError,
    InvalidSelector,
    NavigationTimeout,
    UpstreamUnreachable,
    playwright_ms,
    translate_playwright_error,
)


def test_a_playwright_timeout_is_a_navigation_timeout_reported_by_its_first_line():
    failure = translate_playwright_error(
        PlaywrightTimeoutError("page.goto: Timeout 30000ms exceeded.\nCall log:\n  - navigating")
    )
    assert isinstance(failure, NavigationTimeout)
    assert str(failure) == "page.goto: Timeout 30000ms exceeded."


@pytest.mark.parametrize(
    "first_line",
    [
        "page.goto: NS_ERROR_UNKNOWN_HOST",
        "page.goto: NS_ERROR_CONNECTION_REFUSED",
        "page.goto: NS_ERROR_NET_RESET",
        "page.goto: NS_ERROR_NET_INTERRUPT",
        "page.goto: NS_ERROR_NET_TIMEOUT",
        "page.goto: NS_ERROR_OFFLINE",
        "page.goto: SSL_ERROR_BAD_CERT_DOMAIN",
        "page.goto: SEC_ERROR_UNKNOWN_ISSUER",
        "page.goto: MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT",
    ],
)
def test_a_network_failure_is_upstream_unreachable(first_line):
    failure = translate_playwright_error(
        PlaywrightError(first_line + "\nCall log:\n  - navigating")
    )
    assert isinstance(failure, UpstreamUnreachable)


@pytest.mark.parametrize(
    "message",
    [
        'page.wait_for_selector: Unexpected token "" while parsing css selector "div[[". '
        "Did you mean to CSS.escape it?",
        'page.wait_for_selector: Unknown engine "nope" while parsing selector nope=x',
        "page.wait_for_selector: Malformed selector: near=foo",
        'page.wait_for_selector: "nth" selector cannot be first',
        "page.wait_for_selector: SyntaxError: Document.querySelectorAll: "
        "'div:first' is not a valid selector",
        "page.wait_for_selector: SyntaxError: The expression is not a legal expression.",
    ],
)
def test_an_unparseable_selector_is_invalid_selector(message):
    assert isinstance(translate_playwright_error(PlaywrightError(message)), InvalidSelector)


def test_anything_else_is_a_browser_error():
    closed = PlaywrightError("Target page, context or browser has been closed")
    assert isinstance(translate_playwright_error(closed), BrowserError)
    assert isinstance(translate_playwright_error(RuntimeError("boom")), BrowserError)


def test_an_empty_message_still_names_something():
    assert str(translate_playwright_error(PlaywrightError(""))) == "Error"


@pytest.mark.parametrize(
    ("seconds", "ms"), [(30, 30000), (1.25, 1250), (0.0004, 1), (0, 1), (-1, 1)]
)
def test_playwright_ms_never_returns_zero_which_playwright_reads_as_no_timeout(seconds, ms):
    assert playwright_ms(seconds) == ms


def test_no_fetcher_module_imports_camoufox_or_playwright_at_import_time():
    # Spec §8: every module but browser.py's function bodies imports without the
    # extra. Walks the whole package, so modules added later are covered too.
    code = (
        "import importlib, pkgutil, sys\n"
        "import fetcher\n"
        "for module in pkgutil.walk_packages(fetcher.__path__, 'fetcher.'):\n"
        "    importlib.import_module(module.name)\n"
        "leaked = sorted(n for n in sys.modules if n.split('.')[0] in ('camoufox', 'playwright'))\n"
        "assert not leaked, leaked\n"
    )
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
