import dataclasses

import pytest

from fetcher.settings import MIN_TIMEOUT_MS, ConfigurationError, Settings

INT_VARIABLES = [
    "FETCHER_MAX_CONCURRENCY",
    "FETCHER_HOST_INTERVAL_MS",
    "FETCHER_MAX_LAUNCH_FAILURES",
    "FETCHER_MAX_HTML_BYTES",
    "FETCHER_DEFAULT_TIMEOUT_MS",
    "FETCHER_MAX_TIMEOUT_MS",
]


def test_defaults_match_the_spec_when_nothing_is_set():
    assert Settings.from_env({}) == Settings(
        max_concurrency=2,
        host_interval_ms=2000,
        max_launch_failures=3,
        max_html_bytes=5_242_880,
        default_timeout_ms=30_000,
        max_timeout_ms=60_000,
        locale="en-US",
    )


def test_every_variable_is_read():
    env = {
        "FETCHER_MAX_CONCURRENCY": "4",
        "FETCHER_HOST_INTERVAL_MS": "0",
        "FETCHER_MAX_LAUNCH_FAILURES": "5",
        "FETCHER_MAX_HTML_BYTES": "1024",
        "FETCHER_DEFAULT_TIMEOUT_MS": "20000",
        "FETCHER_MAX_TIMEOUT_MS": "45000",
        "FETCHER_LOCALE": "en-GB",
    }
    assert Settings.from_env(env) == Settings(
        max_concurrency=4,
        host_interval_ms=0,
        max_launch_failures=5,
        max_html_bytes=1024,
        default_timeout_ms=20_000,
        max_timeout_ms=45_000,
        locale="en-GB",
    )


def test_a_blank_variable_falls_back_to_its_default():
    assert Settings.from_env({"FETCHER_MAX_CONCURRENCY": "  "}).max_concurrency == 2


@pytest.mark.parametrize("name", INT_VARIABLES)
def test_a_non_integer_fails_startup_naming_the_variable(name):
    with pytest.raises(ConfigurationError, match=name):
        Settings.from_env({name: "lots"})


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("FETCHER_MAX_CONCURRENCY", "0"),
        ("FETCHER_HOST_INTERVAL_MS", "-1"),
        ("FETCHER_MAX_LAUNCH_FAILURES", "0"),
        ("FETCHER_MAX_HTML_BYTES", "0"),
        ("FETCHER_DEFAULT_TIMEOUT_MS", str(MIN_TIMEOUT_MS - 1)),
        ("FETCHER_MAX_TIMEOUT_MS", str(MIN_TIMEOUT_MS - 1)),
    ],
)
def test_a_value_below_its_minimum_fails_startup(name, value):
    with pytest.raises(ConfigurationError, match=name):
        Settings.from_env({name: value})


def test_a_default_timeout_above_the_maximum_fails_startup():
    env = {"FETCHER_DEFAULT_TIMEOUT_MS": "50000", "FETCHER_MAX_TIMEOUT_MS": "40000"}
    with pytest.raises(ConfigurationError, match="FETCHER_DEFAULT_TIMEOUT_MS"):
        Settings.from_env(env)


@pytest.mark.parametrize("locale", ["en", "english", "en_US", "EN-us"])
def test_a_locale_without_a_region_fails_startup(locale):
    with pytest.raises(ConfigurationError, match="FETCHER_LOCALE"):
        Settings.from_env({"FETCHER_LOCALE": locale})


def test_settings_are_frozen():
    with pytest.raises(dataclasses.FrozenInstanceError):
        Settings().max_concurrency = 3


def test_reads_the_process_environment_by_default(monkeypatch):
    monkeypatch.setenv("FETCHER_MAX_CONCURRENCY", "3")
    assert Settings.from_env().max_concurrency == 3
