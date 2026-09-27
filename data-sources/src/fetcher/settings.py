"""Service settings, read once at startup (spec §7).

Follows `openlibrary.api.deps.Settings`: a frozen object, and a bad value is a
boot failure naming the variable, never a 500 on every request.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass

# The smallest budget a request may ask for. Launching Firefox alone takes
# longer, so a smaller budget could only ever time out.
MIN_TIMEOUT_MS = 1000

# language-REGION. Camoufox warns that a locale without a region invites one
# that does not match the egress IP.
_LOCALE = re.compile(r"^[a-z]{2,3}-[A-Z]{2}$")


class ConfigurationError(RuntimeError):
    """An environment variable holds a value the service cannot run with."""


@dataclass(frozen=True)
class Settings:
    max_concurrency: int = 2
    host_interval_ms: int = 2000
    max_launch_failures: int = 3
    max_html_bytes: int = 5_242_880
    default_timeout_ms: int = 30_000
    max_timeout_ms: int = 60_000
    locale: str = "en-US"

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        locale = (env.get("FETCHER_LOCALE") or "").strip() or cls.locale
        if not _LOCALE.match(locale):
            raise ConfigurationError(f"FETCHER_LOCALE={locale!r} must look like en-US")
        settings = cls(
            max_concurrency=_int(env, "FETCHER_MAX_CONCURRENCY", cls.max_concurrency, 1),
            host_interval_ms=_int(env, "FETCHER_HOST_INTERVAL_MS", cls.host_interval_ms, 0),
            max_launch_failures=_int(
                env, "FETCHER_MAX_LAUNCH_FAILURES", cls.max_launch_failures, 1
            ),
            max_html_bytes=_int(env, "FETCHER_MAX_HTML_BYTES", cls.max_html_bytes, 1),
            default_timeout_ms=_int(
                env, "FETCHER_DEFAULT_TIMEOUT_MS", cls.default_timeout_ms, MIN_TIMEOUT_MS
            ),
            max_timeout_ms=_int(env, "FETCHER_MAX_TIMEOUT_MS", cls.max_timeout_ms, MIN_TIMEOUT_MS),
            locale=locale,
        )
        if settings.default_timeout_ms > settings.max_timeout_ms:
            raise ConfigurationError(
                f"FETCHER_DEFAULT_TIMEOUT_MS={settings.default_timeout_ms} exceeds "
                f"FETCHER_MAX_TIMEOUT_MS={settings.max_timeout_ms}"
            )
        return settings


def _int(env: Mapping[str, str], name: str, default: int, minimum: int) -> int:
    raw = env.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ConfigurationError(f"{name}={raw!r} is not an integer") from None
    if value < minimum:
        raise ConfigurationError(f"{name}={value} is below the minimum of {minimum}")
    return value
