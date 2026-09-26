# Page Fetcher Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Camoufox-backed page fetcher in `data-sources/`: a FastAPI service that launches one Firefox per fetch and returns the rendered HTML. Add a `PageFetcher::Client` in Rails that calls it.

**Architecture:** A second uv-managed source (`src/fetcher/`) beside `src/openlibrary/`, with its own image (`fetcher.Dockerfile`) and compose service on port 8081. Every decision lives in `fetcher.py` and `guards.py`, written against a thin `Browser` protocol, so the whole service is tested with a fake browser. `browser.py` is the only module that touches Camoufox or Playwright. Rails gets a thin Faraday client that reuses the Open Library circuit breaker under its own key.

**Tech Stack:**
- Python side: Python 3.12, uv 0.11.17, FastAPI, pydantic 2, Camoufox 0.5.6 (Playwright < 1.63), pytest with anyio's bundled plugin, ruff 0.16, Docker Compose.
- Rails side: Rails 8 (Ruby 4.0.6), Faraday, Minitest 6 + WebMock + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md`. Read it before starting any task.

**Layout additions beyond spec §8:**
- `budget.py`: the per-fetch deadline, shared by the limiter and the fetcher.
- `guards.py`: the §6 address checks. They are decisions, so they stay out of `browser.py` and testable.
- `install_check.py`: the image-build verification from §4.
- `tests/fetcher/fakes.py`: the fake browser and fake DNS.

## Global Constraints

- **Working directories:** run Python commands from `data-sources/` and Rails commands from `web-app/`. `pwd` first when unsure.
- **Installing:** every Python install is `uv sync --locked --extra fetcher`, which fails on lockfile drift. The fetcher image uses `uv sync --locked --no-dev --extra fetcher`.
- **Leave the Open Library image alone:** `data-sources/Dockerfile` and the `api`/`build` compose services are not modified.
- **Dependencies:**
  - The extra is exactly `fetcher = ["camoufox>=0.5.6,<0.6"]`.
  - Never add Camoufox's `geoip` extra.
- **Browser build pin:** `CAMOUFOX_BROWSER=official/stable/152.0.4-beta.30`. With Playwright 1.61 or later, which the lock resolves, beta.30 is the lowest browser build that works (`PLAYWRIGHT_BROWSER_FLOORS` in `camoufox/__version__.py`).
- **Import boundary:** `fetcher/browser.py` is the only module that imports `camoufox` or `playwright`, and only inside functions. A test enforces this (Task 6).
- **Port and exposure:** port 8081, published on `${FETCHER_BIND:-127.0.0.1}`. Never on a public request path.
- **Settings:** `FETCHER_MAX_CONCURRENCY` 2, `FETCHER_HOST_INTERVAL_MS` 2000, `FETCHER_MAX_LAUNCH_FAILURES` 3, `FETCHER_MAX_HTML_BYTES` 5242880, `FETCHER_DEFAULT_TIMEOUT_MS` 30000, `FETCHER_MAX_TIMEOUT_MS` 60000, `FETCHER_LOCALE` en-US. Compose also sets `TZ: "${FETCHER_TZ:-America/Chicago}"`.
- **Error codes and HTTP statuses:**

  | Code | Status |
  |---|---|
  | `invalid_url` | 400 |
  | `invalid_selector` | 400 |
  | `upstream_unreachable` | 502 |
  | `html_too_large` | 502 |
  | `browser_error` | 502 |
  | `browser_unavailable` | 503 |
  | `navigation_timeout` | 504 |

  Every error body is `{"error": code, "detail": text}`. Validation failures are FastAPI's own 422 body.
- **Time limits:**
  - `timeout_ms`: default 30000, minimum 1000, maximum 60000.
  - The selector wait stops 2 s before the deadline.
  - Browser close has a 5 s limit.
  - The redirect check has a 2 s limit, outside the budget.
  - Rails' read timeout is `timeout_ms / 1000 + 10`.
- **Rails breaker:** `Books::OpenLibrary::CircuitBreaker.new(key: "page_fetcher", failure_threshold: 5, cooldown: 60)`.
- **No real browser in tests:** no automated test launches a browser. No Playwright E2E test either, since this adds no user-facing page.
- **Linting:**
  - Python: `uv run ruff check .` and `uv run ruff format --check .`.
  - Ruby: `bundle exec standardrb`. Never `bin/rubocop`, and never brakeman.
- **HTML handling:** never logged, cached or stored anywhere.
- **Rails test conventions:**
  - The WebMock base URL is `http://page-fetcher.test:8081`, because WebMock allows localhost through.
  - The breaker uses `Books::OpenLibrary::FakeRedis`.
  - Use `assert_nil`, never `assert_equal nil` (Minitest 6).
- **Branch and commits:** work in the worktree from `EnterWorktree`, branched from `page-fetcher-spec`. Never commit to `main`. Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Worktree files:** the worktree tool copies the five gitignored files (`.env`, `web-app/.env`, `web-app/config/master.key`, `web-app/e2e/.env`, `web-app/node_modules`) only some of the time. Check that they exist before Task 11. Copy any that are missing from the main checkout.

## Review Focus

The five inputs most likely to bite a user that the spec's own test list does not cover. Each has its test in the task that owns the code:

1. **A malformed `wait_for_selector`** (for example `div[[`) must be `400 invalid_selector`, never `browser_error`. A `browser_error` would count against the Rails breaker and stop every other fetch.
   - Tests: Task 6 (translation), Task 8 (mapping), Task 9 (API), Task 10 (real browser, smoke check).
2. **A nearly spent budget must never reach Playwright as `timeout=0`,** because to Playwright 0 means "wait forever". `playwright_ms()` floors at 1.
   - Test: Task 6.
3. **The HTML cap counts bytes, not characters.** Six `é` characters are 12 bytes, which is over a 10-byte cap.
   - Test: Task 8.
4. **IP literals and alternate IP encodings** are `invalid_url`: `http://[::1]/`, `http://2130706433/`, `http://0x7f.1/`, `[::ffff:127.0.0.1]`, and 6to4 `2002:7f00:1::`.
   - Test: Task 4, using the real system resolver. Numeric hosts need no network.
5. **Unusual but valid hosts must pass, and unusable ones must fail cleanly.** `HTTPS://Example.COM./` and `http://bücher.example/` are accepted. A host that cannot be IDNA-encoded (a 64-character label) is `400 invalid_url`, not a 500.
   - Test: Task 4.

---

### Task 1: Fetcher package, `fetcher` extra and CI

**Files:**
- Modify: `data-sources/pyproject.toml`
- Modify: `data-sources/uv.lock` (regenerated by `uv lock`, never hand-edited)
- Create: `data-sources/src/fetcher/__init__.py`
- Create: `data-sources/tests/fetcher/__init__.py` (empty)
- Create: `data-sources/tests/fetcher/conftest.py`
- Modify: `data-sources/tests/test_packaging.py`
- Modify: `.github/workflows/ci.yml` (the `python` job's install step, around line 117)

**Interfaces:**
- Produces: the importable package `fetcher` with `fetcher.__version__ == "0.1.0"`, the `fetcher` extra, and an `anyio_backend` fixture for every test under `tests/fetcher/`.

- [ ] **Step 1: Write the failing test.** Replace `data-sources/tests/test_packaging.py` with:

```python
import common
import fetcher
import openlibrary


def test_packages_are_importable_and_versioned():
    assert common.__version__
    assert openlibrary.__version__
    assert fetcher.__version__


def test_common_is_not_nested_inside_openlibrary():
    # common/ is a sibling of the sources on purpose: shared code must not
    # quietly become Open Library code that a second source works around.
    assert "openlibrary" not in common.__file__


def test_fetcher_is_a_sibling_source_not_part_of_openlibrary():
    assert "openlibrary" not in fetcher.__file__
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `uv run pytest tests/test_packaging.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher'`.

- [ ] **Step 3: Create the package and the extra.**

`data-sources/src/fetcher/__init__.py`:

```python
"""The page fetcher: URL in, rendered HTML out, one browser per fetch.

Design: docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md
"""

__version__ = "0.1.0"
```

In `data-sources/pyproject.toml`, add the extra under the existing `calibration` one and add the package to the wheel:

```toml
[project.optional-dependencies]
calibration = ["splink>=4.0,<5"]
# Camoufox pulls Playwright. Only the fetcher image and CI install it; the
# Open Library image never does.
fetcher = ["camoufox>=0.5.6,<0.6"]
```

```toml
[tool.hatch.build.targets.wheel]
packages = ["src/common", "src/openlibrary", "src/fetcher"]
```

`data-sources/tests/fetcher/__init__.py`: an empty file.

`data-sources/tests/fetcher/conftest.py`:

```python
import pytest


@pytest.fixture
def anyio_backend():
    # The service runs on asyncio under uvicorn; async tests run there only.
    return "asyncio"
```

- [ ] **Step 4: Lock and install.**

Run: `uv lock && uv sync --locked --extra fetcher`
Expected: the lock gains `camoufox` 0.5.6 and `playwright` 1.62.x, plus their dependencies. The sync succeeds.

Run: `uv run python -c "import camoufox, playwright; print('ok')"`
Expected: `ok`. No browser is downloaded: installing the package never fetches Firefox.

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `uv run pytest tests/test_packaging.py -v && uv run pytest`
Expected: PASS, and the full suite stays green.

Run: `uv run ruff check . && uv run ruff format --check .`
Expected: clean.

- [ ] **Step 6: Install the extra in CI.** In `.github/workflows/ci.yml`, in the `python` job, replace:

```yaml
      - name: Install dependencies (fails on lockfile drift)
        run: uv sync --locked
```

with:

```yaml
      # The fetcher extra brings Playwright's Python package so the browser
      # layer's error translation is tested against its real exception
      # classes. No browser is ever downloaded.
      - name: Install dependencies (fails on lockfile drift)
        run: uv sync --locked --extra fetcher
```

- [ ] **Step 7: Commit.**

```bash
git add data-sources/pyproject.toml data-sources/uv.lock data-sources/src/fetcher/__init__.py \
  data-sources/tests/fetcher/__init__.py data-sources/tests/fetcher/conftest.py \
  data-sources/tests/test_packaging.py .github/workflows/ci.yml
git commit -m "Add the fetcher package and its camoufox extra

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Fetcher image, install check and launch-time measurement (a gate)

This task answers the spec's one open question before any service code is written: how long does a browser launch take? **If the median launch is over 10 seconds, stop after Step 9 and report to Shane.** The per-fetch design (spec §3) is then back on the table.

**Files:**
- Create: `data-sources/src/fetcher/install_check.py`
- Create: `data-sources/tests/fetcher/test_install_check.py`
- Create: `data-sources/fetcher.Dockerfile`
- Create: `docs/features/page-fetcher-service.md` (the measurement section only; Task 10 writes the rest)
- Throwaway, never committed: a measurement script in a scratch file outside the repository

**Interfaces:**
- Consumes: the `fetcher` extra (Task 1).
- Produces: `fetcher.install_check.expected_build(spec: str) -> str`, `fetcher.install_check.missing_libraries(ldd_output: str) -> list[str]` and `fetcher.install_check.main() -> int`. Also an image tagged `the-greatest/page-fetcher:dev` whose `CMD` runs `uvicorn --factory fetcher.api.main:factory` on port 8081. That module arrives in Task 9.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_install_check.py`:

```python
import pytest

from fetcher.install_check import expected_build, missing_libraries


@pytest.mark.parametrize(
    ("spec", "build"),
    [
        ("official/stable/152.0.4-beta.30", "152.0.4-beta.30"),
        ("official/152.0.4-beta.30", "152.0.4-beta.30"),
        ("152.0.4-beta.30", "152.0.4-beta.30"),
        ("official/stable/v152.0.4-beta.30/", "152.0.4-beta.30"),
    ],
)
def test_expected_build_drops_the_repo_and_channel(spec, build):
    assert expected_build(spec) == build


def test_missing_libraries_lists_only_what_ldd_could_not_find():
    output = (
        "\tlinux-vdso.so.1 (0x00007ffd)\n"
        "\tlibgtk-3.so.0 => /lib/x86_64-linux-gnu/libgtk-3.so.0 (0x00007f)\n"
        "\tlibdbus-glib-1.so.2 => not found\n"
        "\tlibXt.so.6 => not found\n"
    )
    assert missing_libraries(output) == ["libdbus-glib-1.so.2", "libXt.so.6"]


def test_missing_libraries_is_empty_when_everything_resolves():
    assert missing_libraries("\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f)\n") == []
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_install_check.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.install_check'`.

- [ ] **Step 3: Implement the check.** `data-sources/src/fetcher/install_check.py`:

```python
"""Build-time check that the pinned Camoufox browser really is installed (spec §4).

`camoufox fetch` prints an error and exits 0 when a download fails, so the
image build runs `python -m fetcher.install_check` straight after it and fails
on anything missing: the pinned build, the bundled uBlock Origin add-on, or a
shared library Firefox needs.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def expected_build(spec: str) -> str:
    """`official/stable/152.0.4-beta.30` -> `152.0.4-beta.30`."""
    return spec.rstrip("/").rsplit("/", 1)[-1].removeprefix("v")


def missing_libraries(ldd_output: str) -> list[str]:
    """Library names `ldd` reports as `not found`."""
    return [
        line.split("=>", 1)[0].strip() for line in ldd_output.splitlines() if "not found" in line
    ]


def main() -> int:
    from camoufox.addons import ADDONS_DIR
    from camoufox.pkgman import camoufox_path, installed_verstr, launch_path

    spec = os.environ.get("CAMOUFOX_BROWSER", "")
    if not spec:
        print("CAMOUFOX_BROWSER is not set", file=sys.stderr)
        return 1
    try:
        # download_if_missing=False: this check must never fetch anything itself.
        executable = Path(launch_path(camoufox_path(download_if_missing=False)))
        installed = installed_verstr()
    except Exception as exc:  # camoufox raises its own types for a missing install
        print(f"the Camoufox browser is not installed: {exc}", file=sys.stderr)
        return 1
    if installed != expected_build(spec):
        print(f"installed build {installed} is not the pinned {spec}", file=sys.stderr)
        return 1
    if not (ADDONS_DIR / "UBO" / "manifest.json").exists():
        print(f"the uBlock Origin add-on is missing from {ADDONS_DIR}", file=sys.stderr)
        return 1
    # libxul.so is where Firefox's GTK, X11 and audio dependencies live; the
    # launcher binary itself links almost nothing.
    missing: list[str] = []
    for binary in (executable, executable.parent / "libxul.so"):
        result = subprocess.run(["ldd", str(binary)], capture_output=True, text=True, check=False)
        missing += missing_libraries(result.stdout)
    if missing:
        print(
            "Firefox needs libraries the image lacks: " + ", ".join(sorted(set(missing))),
            file=sys.stderr,
        )
        return 1
    print(f"Camoufox {installed} installed at {executable}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher/test_install_check.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Write the image.** `data-sources/fetcher.Dockerfile`:

```dockerfile
# The page fetcher image (docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md).
# Separate from the Open Library image (./Dockerfile) so that one never carries Firefox.
#
# bookworm, not the floating slim tag: the apt package names below are Debian 12's.
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/

# Xvfb, fonts, and Firefox's runtime libraries: Playwright's Debian 12 list for
# Firefox, plus libxt6, libpci3 and Mesa for the software GL that Camoufox's Xvfb
# display uses. fetcher.install_check fails the build if Firefox still lacks one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xvfb xfonts-scalable fontconfig fonts-liberation fonts-noto-color-emoji fonts-dejavu-core \
      ca-certificates \
      libasound2 libatk1.0-0 libcairo-gobject2 libcairo2 libdbus-1-3 libdbus-glib-1-2 \
      libfontconfig1 libfreetype6 libgdk-pixbuf-2.0-0 libglib2.0-0 libgtk-3-0 libharfbuzz0b \
      libpango-1.0-0 libpangocairo-1.0-0 libx11-6 libx11-xcb1 libxcb-shm0 libxcb1 \
      libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 \
      libxrender1 libxtst6 libxt6 libpci3 libgl1 libegl1 libgl1-mesa-dri \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Lockfile-only layer, as in the Open Library image: --locked fails the build on drift.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --extra fetcher --no-install-project

COPY src/ ./src/
RUN uv sync --locked --no-dev --extra fetcher

ENV PATH="/app/.venv/bin:$PATH"

# Firefox and Xvfb run as this user, never root (spec §6).
RUN useradd --create-home --uid 10001 fetcher
USER fetcher

# One named browser build (spec §4). The package does not pin the browser: a
# bare `camoufox fetch` takes the newest build on GitHub. `camoufox set` pins,
# `camoufox fetch` installs the pin, and install_check verifies, because fetch
# exits 0 when a download fails. The browser lands in ~fetcher/.cache/camoufox.
ARG CAMOUFOX_BROWSER=official/stable/152.0.4-beta.30
ENV CAMOUFOX_BROWSER=${CAMOUFOX_BROWSER}
RUN camoufox set "$CAMOUFOX_BROWSER" \
 && camoufox fetch \
 && python -m fetcher.install_check

EXPOSE 8081
CMD ["uvicorn", "--factory", "fetcher.api.main:factory", \
     "--host", "0.0.0.0", "--port", "8081"]
```

- [ ] **Step 6: Build it.**

Run (from `data-sources/`): `docker build -f fetcher.Dockerfile -t the-greatest/page-fetcher:dev .`
Expected: the last `RUN` prints `Camoufox 152.0.4-beta.30 installed at /home/fetcher/.cache/camoufox/.../camoufox-bin`, and the build succeeds.

If it fails, fix the cause and rebuild. Never weaken the check.
- **`install_check` names missing libraries:** add the Debian 12 package that ships each one to the `apt-get install` line. Look them up by file name at packages.debian.org, "Search the contents of packages", suite `bookworm`.
- **`camoufox set` says the version is not found:** list what exists with
  `(export XDG_CACHE_HOME="$(mktemp -d)"; uv run camoufox sync && uv run camoufox list all)`.
  Pick the newest `official` stable build of 152.0.4 at beta.30 or later, and change the `ARG` default and the Global Constraints line to match.
- **The GitHub API rate-limits the build** (HTTP 403 from `api.github.com`): wait and rebuild. There are 60 unauthenticated calls an hour.

- [ ] **Step 7: Write the measurement script** to a scratch file outside the repository, for example `$TMPDIR/measure_launch.py`. It is throwaway and never committed:

```python
import asyncio
import statistics
import time

from camoufox.async_api import AsyncNewBrowser
from camoufox.pkgman import camoufox_path, launch_path
from camoufox.utils import launch_options
from camoufox.virtdisplay import VirtualDisplay
from playwright.async_api import async_playwright


async def main():
    display = VirtualDisplay()
    options = launch_options(
        executable_path=launch_path(camoufox_path(download_if_missing=False)),
        headless=False,
        virtual_display=display.get(),
        locale="en-US",
        humanize=False,
        geoip=False,
    )
    async with async_playwright() as playwright:
        launches = []
        for _ in range(6):
            started = time.monotonic()
            browser = await AsyncNewBrowser(playwright, from_options=options)
            await browser.new_page()
            launches.append(time.monotonic() - started)
            await browser.close()
        print("launch + page, seconds:", [round(s, 2) for s in launches])
        print("run 1 (cold):", round(launches[0], 2))
        print("median of runs 2-6:", round(statistics.median(launches[1:]), 2))

        started = time.monotonic()
        browser = await AsyncNewBrowser(playwright, from_options=options)
        page = await browser.new_page()
        response = await page.goto(
            "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
            wait_until="load",
            timeout=30000,
        )
        print("goodreads:", response.status if response else None, repr(await page.title()),
              round(time.monotonic() - started, 2), "s including launch")
        await browser.close()
    display.kill()


asyncio.run(main())
```

- [ ] **Step 8: Run it in the image.**

Run: `docker run --rm -i --shm-size=1g the-greatest/page-fetcher:dev python - < "$TMPDIR/measure_launch.py"`
Expected: three timing lines and a Goodreads line with status 200 and a title containing "Great Gatsby". Copy the output into your task report.

- [ ] **Step 9: The gate.** If "median of runs 2-6" is **over 10 seconds**, stop here. Report the numbers to Shane and do not start Task 3. Otherwise continue.

If Goodreads served a bot wall (a status other than 200, or a title without "Gatsby"), say so prominently in the report and continue. That is the spec's Camoufox-drift risk, and Shane decides what to do about it.

- [ ] **Step 10: Record the numbers.** Create `docs/features/page-fetcher-service.md` containing exactly the block below. Fill each angle-bracketed value from Step 8's output and today's date. These values are measurements, not placeholders:

```markdown
# Page Fetcher Service

Design: `docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md`
Plan: `docs/superpowers/plans/2026-09-26-page-fetcher-service.md`

## Measured

Launch cost in the built image (`CAMOUFOX_BROWSER=official/stable/152.0.4-beta.30`,
Camoufox 0.5.6), on the development machine, <date>:

| What | Seconds |
|---|---|
| Launch + first page, median of runs 2–6 | <median> |
| Launch + first page, run 1 (cold) | <run 1> |
| Goodreads book page, launch included | <goodreads seconds> (status <status>, title "<title>") |

The spec's per-fetch design (§3) holds while the median stays well under the
30-second default budget. Re-measure after any browser or package bump.
```

- [ ] **Step 11: Lint and commit.**

Run: `uv run ruff check . && uv run ruff format --check . && uv run pytest tests/fetcher -v`
Expected: clean and PASS.

```bash
git add data-sources/src/fetcher/install_check.py data-sources/tests/fetcher/test_install_check.py \
  data-sources/fetcher.Dockerfile docs/features/page-fetcher-service.md
git commit -m "Add the fetcher image with a pinned, verified Camoufox build

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Settings

**Files:**
- Create: `data-sources/src/fetcher/settings.py`
- Create: `data-sources/tests/fetcher/test_settings.py`

**Interfaces:**
- Produces:
  - `fetcher.settings.Settings`: a frozen dataclass with `max_concurrency: int = 2`, `host_interval_ms: int = 2000`, `max_launch_failures: int = 3`, `max_html_bytes: int = 5_242_880`, `default_timeout_ms: int = 30_000`, `max_timeout_ms: int = 60_000` and `locale: str = "en-US"`.
  - `Settings.from_env(env: Mapping[str, str] | None = None) -> Settings`.
  - `fetcher.settings.MIN_TIMEOUT_MS = 1000` and `fetcher.settings.ConfigurationError`.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_settings.py`:

```python
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
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_settings.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.settings'`.

- [ ] **Step 3: Implement.** `data-sources/src/fetcher/settings.py`:

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher/test_settings.py -v`
Expected: PASS.

- [ ] **Step 5: Lint and commit.**

Run: `uv run ruff check . && uv run ruff format --check .`

```bash
git add data-sources/src/fetcher/settings.py data-sources/tests/fetcher/test_settings.py
git commit -m "Add fetcher settings read once from the environment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: URL and address checks

**Files:**
- Create: `data-sources/src/fetcher/urlcheck.py`
- Create: `data-sources/tests/fetcher/fakes.py` (the fake DNS only; Task 6 adds the fake browser)
- Create: `data-sources/tests/fetcher/test_urlcheck.py`

**Interfaces:**
- Produces:
  - Types: `Resolver = Callable[[str], Awaitable[list[str]]]`; the exceptions `InvalidUrl(ValueError)` (maps to 400) and `Unresolvable(RuntimeError)` (maps to 502); `Target(url: str, host: str)`, a frozen dataclass.
  - Functions: `async system_resolver(host) -> list[str]`, `parse(url) -> Target` and `is_public(address: str) -> bool`.
  - `HostChecker(resolver=system_resolver)`, with `async non_public_address(host) -> str | None` and `async check(url) -> Target`. `non_public_address` returns the first non-public address, or None when all are public. It raises `Unresolvable` when the lookup fails and `InvalidUrl` when the host cannot be a hostname.
  - Test helper `tests.fetcher.fakes.resolver(table)`: a fake DNS. Unknown hosts resolve to the public `93.184.215.14`, and a table value that is an exception is raised. `.calls` lists the hosts asked for.

- [ ] **Step 1: Write the fake DNS.** `data-sources/tests/fetcher/fakes.py`:

```python
"""Test stand-ins for the fetcher's two external dependencies: DNS and the browser."""

from __future__ import annotations

PUBLIC_ADDRESS = "93.184.215.14"


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
```

- [ ] **Step 2: Write the failing tests.** `data-sources/tests/fetcher/test_urlcheck.py`:

```python
import socket

import pytest

from fetcher.urlcheck import (
    HostChecker,
    InvalidUrl,
    Unresolvable,
    is_public,
    parse,
    system_resolver,
)
from tests.fetcher.fakes import PUBLIC_ADDRESS, resolver

# ------------------------------------------------------------------ parse


@pytest.mark.parametrize(
    ("url", "host"),
    [
        ("https://www.goodreads.com/book/show/4671", "www.goodreads.com"),
        ("http://books.example/", "books.example"),
        ("HTTPS://Example.COM./path", "example.com."),
        ("https://books.example:8443/x#reviews", "books.example"),
        ("http://bücher.example/", "bücher.example"),
    ],
)
def test_parse_accepts_http_and_https(url, host):
    assert parse(url).host == host


@pytest.mark.parametrize(
    "url",
    [
        "ftp://books.example/",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,hi",
        "books.example/no-scheme",
        "http:///no-host",
        "http://user:secret@books.example/",
        "http://user@books.example/",
        "http://books.example:99999/",
        "http://[::1/",
    ],
)
def test_parse_rejects_what_the_service_will_not_fetch(url):
    with pytest.raises(InvalidUrl):
        parse(url)


# -------------------------------------------------------------- is_public


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "10.1.2.3",
        "172.16.0.1",
        "192.168.1.1",
        "169.254.169.254",  # cloud metadata
        "100.64.0.1",  # carrier-grade NAT
        "0.0.0.0",
        "224.0.0.1",  # multicast
        "240.0.0.1",  # reserved
        "::1",
        "fe80::1",
        "fe80::1%eth0",
        "fc00::1",
        "::ffff:127.0.0.1",
        "2002:7f00:1::",  # 6to4 wrapping 127.0.0.1
    ],
)
def test_non_public_addresses(address):
    assert is_public(address) is False


@pytest.mark.parametrize("address", ["8.8.8.8", PUBLIC_ADDRESS, "2606:4700::1111"])
def test_public_addresses(address):
    assert is_public(address) is True


# ----------------------------------------------------------- HostChecker


@pytest.mark.anyio
async def test_a_public_host_passes_the_check():
    target = await HostChecker(resolver({})).check("https://books.example/b/1")
    assert (target.url, target.host) == ("https://books.example/b/1", "books.example")


@pytest.mark.anyio
async def test_a_private_host_is_invalid_naming_host_and_address():
    checker = HostChecker(resolver({"intranet.example": ["10.0.0.7"]}))
    with pytest.raises(InvalidUrl, match=r"intranet\.example.*10\.0\.0\.7"):
        await checker.check("http://intranet.example/")


@pytest.mark.anyio
async def test_one_private_address_among_public_ones_is_enough_to_refuse():
    checker = HostChecker(resolver({"mixed.example": [PUBLIC_ADDRESS, "192.168.0.10"]}))
    with pytest.raises(InvalidUrl, match="192.168.0.10"):
        await checker.check("https://mixed.example/")


@pytest.mark.anyio
@pytest.mark.parametrize(
    "answer",
    [OSError("boom"), socket.gaierror(socket.EAI_NONAME, "Name or service not known"), []],
)
async def test_a_failed_or_empty_lookup_is_unresolvable(answer):
    with pytest.raises(Unresolvable):
        await HostChecker(resolver({"gone.example": answer})).check("https://gone.example/")


@pytest.mark.anyio
async def test_a_host_the_resolver_cannot_encode_is_invalid_not_a_crash():
    checker = HostChecker(resolver({"bad.example": UnicodeError("label too long")}))
    with pytest.raises(InvalidUrl):
        await checker.check("https://bad.example/")


@pytest.mark.anyio
async def test_each_host_is_resolved_once_per_checker():
    dns = resolver({})
    checker = HostChecker(dns)
    await checker.check("https://books.example/a")
    await checker.check("https://books.example/b")
    assert await checker.non_public_address("books.example") is None
    assert dns.calls == ["books.example"]


@pytest.mark.anyio
async def test_separate_checkers_do_not_share_answers():
    dns = resolver({})
    await HostChecker(dns).check("https://books.example/")
    await HostChecker(dns).check("https://books.example/")
    assert dns.calls == ["books.example", "books.example"]


# ----------------------------- the real resolver, on hosts that need no DNS


@pytest.mark.anyio
@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/",
        "http://[::1]/",
        "http://2130706433/",  # 127.0.0.1 as one decimal number
        "http://0x7f.1/",  # 127.0.0.1 in hex shorthand
        "http://[::ffff:127.0.0.1]/",
        "http://169.254.169.254/latest/meta-data/",
        "http://10.0.0.1:6379/",
    ],
)
async def test_ip_literals_in_any_encoding_are_refused(url):
    with pytest.raises(InvalidUrl):
        await HostChecker(system_resolver).check(url)


@pytest.mark.anyio
async def test_a_label_too_long_to_encode_is_invalid_without_any_lookup():
    with pytest.raises(InvalidUrl):
        await HostChecker(system_resolver).check("http://" + "a" * 64 + ".example/")
```

- [ ] **Step 3: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_urlcheck.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.urlcheck'`.

- [ ] **Step 4: Implement.** `data-sources/src/fetcher/urlcheck.py`:

```python
"""Which URLs the service will fetch (spec §6): http or https, no embedded
credentials, and a host that resolves only to public addresses.

`HostChecker` caches each host's answer for its own lifetime. The fetcher makes
one per fetch, so the cache covers exactly one page load's requests and a DNS
change between fetches is always seen.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

Resolver = Callable[[str], Awaitable[list[str]]]


class InvalidUrl(ValueError):
    """Not a URL the service will fetch. Maps to 400 invalid_url."""


class Unresolvable(RuntimeError):
    """The host's lookup failed or returned nothing. Maps to 502 upstream_unreachable."""


@dataclass(frozen=True)
class Target:
    url: str
    host: str


async def system_resolver(host: str) -> list[str]:
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    return [info[4][0] for info in infos]


def parse(url: str) -> Target:
    try:
        parts = urlsplit(url)
        _ = parts.port  # raises ValueError on a malformed or out-of-range port
    except ValueError as exc:
        raise InvalidUrl(f"not a valid URL: {exc}") from None
    if parts.scheme not in ("http", "https"):
        raise InvalidUrl(f"the scheme must be http or https, not {parts.scheme or 'missing'}")
    if parts.username is not None or parts.password is not None:
        raise InvalidUrl("the URL must not embed credentials")
    if not parts.hostname:
        raise InvalidUrl("the URL has no host")
    return Target(url=url, host=parts.hostname)


def is_public(address: str) -> bool:
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    if isinstance(ip, ipaddress.IPv6Address):
        # An IPv6 form can carry an IPv4 address inside it; judge that too.
        for embedded in (ip.ipv4_mapped, ip.sixtofour):
            if embedded is not None and not is_public(str(embedded)):
                return False
    return ip.is_global and not (
        ip.is_multicast or ip.is_reserved or ip.is_loopback or ip.is_link_local or ip.is_unspecified
    )


class HostChecker:
    def __init__(self, resolver: Resolver = system_resolver) -> None:
        self._resolver = resolver
        self._answers: dict[str, str | None] = {}

    async def non_public_address(self, host: str) -> str | None:
        """The first address `host` resolves to that is not public, or None when
        all are. Raises Unresolvable when the lookup fails, InvalidUrl when the
        host cannot be a hostname at all."""
        if host in self._answers:
            return self._answers[host]
        try:
            addresses = await self._resolver(host)
        except UnicodeError:
            # getaddrinfo IDNA-encodes the host first; a label over 63
            # characters fails here, before any lookup.
            raise InvalidUrl(f"{host!r} is not a valid hostname") from None
        except OSError as exc:  # socket.gaierror is an OSError
            raise Unresolvable(f"{host} did not resolve: {exc}") from None
        if not addresses:
            raise Unresolvable(f"{host} resolved to no addresses")
        answer = next((address for address in addresses if not is_public(address)), None)
        self._answers[host] = answer
        return answer

    async def check(self, url: str) -> Target:
        target = parse(url)
        bad = await self.non_public_address(target.host)
        if bad is not None:
            raise InvalidUrl(f"{target.host} resolves to non-public address {bad}")
        return target
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher/test_urlcheck.py -v`
Expected: PASS. The IP-literal tests pass offline, because glibc parses numeric hosts, including `2130706433` and `0x7f.1`, without DNS.

- [ ] **Step 6: Lint and commit.**

Run: `uv run ruff check . && uv run ruff format --check .`

```bash
git add data-sources/src/fetcher/urlcheck.py data-sources/tests/fetcher/fakes.py \
  data-sources/tests/fetcher/test_urlcheck.py
git commit -m "Add the fetcher's URL and public-address checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The budget and the limiter

**Files:**
- Create: `data-sources/src/fetcher/budget.py`
- Create: `data-sources/src/fetcher/limiter.py`
- Create: `data-sources/tests/fetcher/test_budget.py`
- Create: `data-sources/tests/fetcher/test_limiter.py`

**Interfaces:**
- Produces:
  - `StageTimeout(stage: str)`, an exception whose `.stage` is a human phrase such as `"waiting for a slot"`.
  - `Budget(seconds, clock=time.monotonic)`, with `.remaining() -> float` (never negative) and `async .run(awaitable, stage) -> T`, which raises `StageTimeout(stage)`.
  - `Limiter(max_concurrency, host_interval_s)`, with `slot(host, budget)`: an async context manager that yields `waited: bool`. The stage phrases it uses are `"waiting for host spacing"` and `"waiting for a slot"`.

- [ ] **Step 1: Write the failing tests.**

`data-sources/tests/fetcher/test_budget.py`:

```python
import asyncio

import pytest

from fetcher.budget import Budget, StageTimeout


def test_remaining_counts_down_and_never_goes_negative():
    now = [100.0]
    budget = Budget(2.0, clock=lambda: now[0])
    assert budget.remaining() == 2.0
    now[0] = 101.5
    assert budget.remaining() == pytest.approx(0.5)
    now[0] = 105.0
    assert budget.remaining() == 0.0


@pytest.mark.anyio
async def test_run_returns_the_result_within_the_budget():
    async def work():
        return 42

    assert await Budget(1).run(work(), "working") == 42


@pytest.mark.anyio
async def test_run_raises_a_stage_timeout_naming_the_stage():
    with pytest.raises(StageTimeout) as caught:
        await Budget(0.05).run(asyncio.sleep(1), "loading the page")
    assert caught.value.stage == "loading the page"


@pytest.mark.anyio
async def test_a_spent_budget_times_out_without_running_the_work():
    ran = False

    async def work():
        nonlocal ran
        ran = True

    now = [0.0]
    budget = Budget(1, clock=lambda: now[0])
    now[0] = 5.0
    with pytest.raises(StageTimeout):
        await budget.run(work(), "launching the browser")
    assert ran is False
```

`data-sources/tests/fetcher/test_limiter.py`:

```python
import asyncio
import time

import pytest

from fetcher.budget import Budget, StageTimeout
from fetcher.limiter import Limiter

pytestmark = pytest.mark.anyio


async def test_no_more_than_max_concurrency_slots_are_held_at_once():
    limiter = Limiter(max_concurrency=2, host_interval_s=0)
    holding = 0
    peak = 0

    async def fetch(host):
        nonlocal holding, peak
        async with limiter.slot(host, Budget(5)):
            holding += 1
            peak = max(peak, holding)
            await asyncio.sleep(0.05)
            holding -= 1

    await asyncio.gather(*(fetch(f"h{i}.example") for i in range(5)))
    assert peak == 2


async def test_starts_to_the_same_host_are_spaced_by_the_interval():
    limiter = Limiter(max_concurrency=2, host_interval_s=0.2)
    starts = []

    async def fetch():
        async with limiter.slot("a.example", Budget(5)):
            starts.append(time.monotonic())

    await asyncio.gather(fetch(), fetch(), fetch())
    gaps = [later - earlier for earlier, later in zip(starts, starts[1:], strict=False)]
    assert all(gap >= 0.19 for gap in gaps), gaps


async def test_different_hosts_are_not_spaced_from_each_other():
    limiter = Limiter(max_concurrency=2, host_interval_s=1.0)
    started = time.monotonic()
    async with limiter.slot("a.example", Budget(5)):
        pass
    async with limiter.slot("b.example", Budget(5)):
        pass
    assert time.monotonic() - started < 0.1


async def test_a_spacing_wait_longer_than_the_budget_times_out_at_once():
    limiter = Limiter(max_concurrency=2, host_interval_s=10.0)
    async with limiter.slot("a.example", Budget(5)):
        pass
    started = time.monotonic()
    with pytest.raises(StageTimeout) as caught:
        async with limiter.slot("a.example", Budget(0.5)):
            pass
    assert caught.value.stage == "waiting for host spacing"
    assert time.monotonic() - started < 0.1  # did not sleep the budget out first


async def test_a_slot_wait_longer_than_the_budget_times_out_and_leaks_no_slot():
    limiter = Limiter(max_concurrency=1, host_interval_s=0)
    release = asyncio.Event()

    async def holder():
        async with limiter.slot("a.example", Budget(5)):
            await release.wait()

    task = asyncio.create_task(holder())
    await asyncio.sleep(0.01)
    with pytest.raises(StageTimeout) as caught:
        async with limiter.slot("b.example", Budget(0.1)):
            pass
    assert caught.value.stage == "waiting for a slot"
    release.set()
    await task
    async with limiter.slot("c.example", Budget(0.1)):  # the slot came back
        pass


async def test_yields_whether_the_fetch_had_to_wait():
    limiter = Limiter(max_concurrency=2, host_interval_s=0.05)
    async with limiter.slot("a.example", Budget(5)) as waited:
        assert waited is False
    async with limiter.slot("a.example", Budget(5)) as waited:
        assert waited is True
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_budget.py tests/fetcher/test_limiter.py -v`
Expected: FAIL, `ModuleNotFoundError`.

- [ ] **Step 3: Implement.**

`data-sources/src/fetcher/budget.py`:

```python
"""A fetch's time budget (spec §2): every stage draws on one deadline."""

from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable


class StageTimeout(Exception):
    """The budget ran out during `stage`. Maps to 504 navigation_timeout."""

    def __init__(self, stage: str) -> None:
        super().__init__(stage)
        self.stage = stage


class Budget:
    def __init__(self, seconds: float, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._deadline = clock() + seconds

    def remaining(self) -> float:
        return max(0.0, self._deadline - self._clock())

    async def run[T](self, awaitable: Awaitable[T], stage: str) -> T:
        """Await `awaitable` within what is left; StageTimeout(stage) when it runs out."""
        try:
            return await asyncio.wait_for(awaitable, timeout=self.remaining())
        except TimeoutError:
            raise StageTimeout(stage) from None
```

`data-sources/src/fetcher/limiter.py`:

```python
"""The concurrency cap and per-host politeness (spec §3).

Same-host fetches queue on a per-host lock, so their starts are at least
`host_interval_s` apart. A fetch waiting on its host holds no global slot, so a
burst to one site never starves the others.
"""

from __future__ import annotations

import asyncio
import contextlib
import math
import time
from collections.abc import AsyncIterator, Callable

from fetcher.budget import Budget, StageTimeout


class Limiter:
    def __init__(
        self,
        max_concurrency: int,
        host_interval_s: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._slots = asyncio.Semaphore(max_concurrency)
        self._interval = host_interval_s
        self._clock = clock
        self._host_locks: dict[str, asyncio.Lock] = {}
        self._last_start: dict[str, float] = {}

    @contextlib.asynccontextmanager
    async def slot(self, host: str, budget: Budget) -> AsyncIterator[bool]:
        """Hold one browser slot for a fetch to `host`, yielding whether the
        fetch had to wait. Raises StageTimeout naming the wait that ran out."""
        lock = self._host_locks.setdefault(host, asyncio.Lock())
        waited = lock.locked()
        await budget.run(lock.acquire(), "waiting for host spacing")
        try:
            gap = self._last_start.get(host, -math.inf) + self._interval - self._clock()
            if gap > 0:
                waited = True
                if gap >= budget.remaining():
                    raise StageTimeout("waiting for host spacing")
                await asyncio.sleep(gap)
            waited = waited or self._slots.locked()
            await budget.run(self._slots.acquire(), "waiting for a slot")
            self._last_start[host] = self._clock()
        finally:
            lock.release()
        try:
            yield waited
        finally:
            self._slots.release()
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher/test_budget.py tests/fetcher/test_limiter.py -v`
Expected: PASS.

- [ ] **Step 5: Lint and commit.** Ruff 0.16 wants the PEP 695 `run[T]` form shown above. Keep it.

Run: `uv run ruff check . && uv run ruff format --check .`

```bash
git add data-sources/src/fetcher/budget.py data-sources/src/fetcher/limiter.py \
  data-sources/tests/fetcher/test_budget.py data-sources/tests/fetcher/test_limiter.py
git commit -m "Add the fetch budget and the concurrency and host-spacing limiter

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The browser boundary and the fake browser

**Files:**
- Create: `data-sources/src/fetcher/browser.py` (the protocols, the exceptions and the translation; Task 10 appends the Camoufox classes)
- Modify: `data-sources/tests/fetcher/fakes.py` (replace it with the full version below)
- Create: `data-sources/tests/fetcher/test_browser.py`

**Interfaces:**
- Produces, in `fetcher.browser`:
  - `WaitUntil = Literal["domcontentloaded", "load", "networkidle"]`.
  - `RequestFilter = Callable[[str, str, bool], Awaitable[bool]]`: called with `(url, resource_type, is_navigation)` and returning whether the request may go out.
  - Exceptions: `BrowserFailure` and its subclasses `LaunchFailed`, `NavigationTimeout`, `UpstreamUnreachable`, `InvalidSelector` and `BrowserError`.
  - `DocumentResponse(url: str, status: int, redirect_chain: tuple[str, ...] = ())`, a frozen dataclass.
  - The `BrowserSession` protocol:
    - `async goto(url, wait_until, timeout_s) -> None`
    - `async wait_for_selector(selector, timeout_s) -> bool`
    - `async content() -> str`
    - `async title() -> str`
    - `document_responses() -> list[DocumentResponse]`
    - `async close() -> None`
  - The `Browser` protocol:
    - `async start()`
    - `async stop()`
    - `async launch(request_filter, timeout_s) -> BrowserSession`
    - `describe() -> dict[str, str]`, whose keys are `camoufox_version` and `browser_build`
  - `playwright_ms(seconds: float) -> int` and `translate_playwright_error(exc) -> BrowserFailure`.
- Produces, in `tests.fetcher.fakes`: `PAGE_URL`, `PAGE_HTML`, `Script`, `FakeSession`, `FakeBrowser(*scripts, default=None)` and `resolver`.
  - `FakeBrowser` records `.sessions`, `.launch_timeouts`, `.started` and `.stopped`.
  - Each `FakeSession` records `.goto_calls`, `.selector_calls`, `.filter_decisions` and `.closed`.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_browser.py`:

```python
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
        "page.goto: NS_ERROR_NET_TIMEOUT",
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
        'page.wait_for_selector: Unexpected token "[" while parsing css selector "div[[". '
        "Did you mean to CSS.escape it?",
        'page.wait_for_selector: Unknown engine "nope" while parsing selector nope=x',
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
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_browser.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.browser'`.

- [ ] **Step 3: Implement the boundary.** `data-sources/src/fetcher/browser.py`:

```python
"""The browser boundary (spec §8).

`Fetcher` depends on the thin `Browser` and `BrowserSession` protocols below and
makes every decision itself. This module only drives a browser and reports what
happened in the service's own exception types. It is the only module that
imports camoufox or playwright, and only inside functions, so every other module
imports without the `fetcher` extra installed.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Literal, Protocol

WaitUntil = Literal["domcontentloaded", "load", "networkidle"]

# Called for every request the page makes, as (url, resource_type,
# is_navigation); returns whether it may go out. Built per fetch by
# `fetcher.guards.RequestFilter`.
RequestFilter = Callable[[str, str, bool], Awaitable[bool]]


class BrowserFailure(Exception):
    """A failure the browser layer reports, in the service's own terms."""


class LaunchFailed(BrowserFailure):
    """The browser did not start."""


class NavigationTimeout(BrowserFailure):
    """Playwright's own timeout fired."""


class UpstreamUnreachable(BrowserFailure):
    """The site could not be reached: DNS, a refused or reset connection, or TLS."""


class InvalidSelector(BrowserFailure):
    """`wait_for_selector` is not a selector Playwright can parse."""


class BrowserError(BrowserFailure):
    """Anything else the browser raised."""


@dataclass(frozen=True)
class DocumentResponse:
    """One main-frame document response. `redirect_chain` holds the URLs of the
    HTTP redirect hops that led to it, oldest first."""

    url: str
    status: int
    redirect_chain: tuple[str, ...] = ()


class BrowserSession(Protocol):
    """One launched browser with one page. Every coroutine but `close` raises
    only BrowserFailure subclasses."""

    async def goto(self, url: str, wait_until: WaitUntil, timeout_s: float) -> None: ...

    async def wait_for_selector(self, selector: str, timeout_s: float) -> bool: ...

    async def content(self) -> str: ...

    async def title(self) -> str: ...

    def document_responses(self) -> list[DocumentResponse]: ...

    async def close(self) -> None: ...


class Browser(Protocol):
    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def launch(self, request_filter: RequestFilter, timeout_s: float) -> BrowserSession: ...

    def describe(self) -> dict[str, str]: ...


# Firefox error names that mean the site could not be reached, as opposed to
# the browser failing.
UPSTREAM_ERROR_MARKERS = (
    "NS_ERROR_UNKNOWN_HOST",
    "NS_ERROR_CONNECTION_REFUSED",
    "NS_ERROR_NET_RESET",
    "NS_ERROR_NET_INTERRUPT",
    "NS_ERROR_NET_TIMEOUT",
    "NS_ERROR_OFFLINE",
    "SSL_ERROR_",
    "SEC_ERROR_",
    "MOZILLA_PKIX_ERROR_",
)


def playwright_ms(seconds: float) -> int:
    """Seconds as a Playwright timeout in ms. Never 0: to Playwright a timeout
    of 0 means "no timeout", so a nearly spent budget must round up to 1."""
    return max(1, round(seconds * 1000))


def _first_line(exc: BaseException) -> str:
    text = str(exc).strip()
    return text.splitlines()[0] if text else type(exc).__name__


def translate_playwright_error(exc: BaseException) -> BrowserFailure:
    """Map anything Playwright raised onto the service's own failure types."""
    from playwright.async_api import Error as PlaywrightError
    from playwright.async_api import TimeoutError as PlaywrightTimeoutError

    text = str(exc)
    if isinstance(exc, PlaywrightTimeoutError):
        return NavigationTimeout(_first_line(exc))
    if isinstance(exc, PlaywrightError):
        if "while parsing" in text and "selector" in text:
            return InvalidSelector(_first_line(exc))
        if any(marker in text for marker in UPSTREAM_ERROR_MARKERS):
            return UpstreamUnreachable(_first_line(exc))
    return BrowserError(_first_line(exc))
```

- [ ] **Step 4: Add the fake browser.** Replace `data-sources/tests/fetcher/fakes.py` with:

```python
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
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher -v`
Expected: PASS. That includes the import-isolation test and the Task 4 tests, which still use `resolver` from the rewritten `fakes.py`.

- [ ] **Step 6: Lint and commit.**

Run: `uv run ruff check . && uv run ruff format --check .`

```bash
git add data-sources/src/fetcher/browser.py data-sources/tests/fetcher/fakes.py \
  data-sources/tests/fetcher/test_browser.py
git commit -m "Add the browser protocol, Playwright error translation and a fake browser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Address guards during and after a fetch

**Files:**
- Create: `data-sources/src/fetcher/guards.py`
- Create: `data-sources/tests/fetcher/test_guards.py`

**Interfaces:**
- Consumes: `HostChecker`, `InvalidUrl` and `Unresolvable` (Task 4); `DocumentResponse` (Task 6).
- Produces:
  - `BLOCKED_RESOURCE_TYPES = frozenset({"image", "font", "media", "stylesheet"})`.
  - `RequestFilter(hosts: HostChecker)`. It is awaitable as `await f(url, resource_type, is_navigation) -> bool`, and `.blocked_navigations: list[str]` holds the hosts of refused navigations.
  - `async first_non_public_hop(responses, hosts) -> tuple[str, str] | None`, returning `(host, reason)`. `reason` is `"resolves to non-public address <ip>"` or `"no longer resolves"`.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_guards.py`:

```python
import pytest

from fetcher.browser import DocumentResponse
from fetcher.guards import BLOCKED_RESOURCE_TYPES, RequestFilter, first_non_public_hop
from fetcher.urlcheck import HostChecker
from tests.fetcher.fakes import resolver

pytestmark = pytest.mark.anyio

DNS = {
    "intranet.example": ["10.0.0.7"],
    "gone.example": OSError("Name or service not known"),
    "bad.example": UnicodeError("label too long"),
}


def a_filter():
    return RequestFilter(HostChecker(resolver(DNS)))


@pytest.mark.parametrize("resource_type", sorted(BLOCKED_RESOURCE_TYPES))
async def test_assets_are_blocked_even_from_a_public_host(resource_type):
    assert await a_filter()("https://books.example/x", resource_type, False) is False


@pytest.mark.parametrize("resource_type", ["document", "script", "xhr", "fetch"])
async def test_requests_to_a_public_host_go_out(resource_type):
    is_navigation = resource_type == "document"
    assert await a_filter()("https://books.example/x", resource_type, is_navigation) is True


async def test_a_private_host_is_refused_and_only_a_refused_navigation_is_remembered():
    request_filter = a_filter()
    assert await request_filter("http://intranet.example/api", "xhr", False) is False
    assert request_filter.blocked_navigations == []
    assert await request_filter("http://intranet.example/", "document", True) is False
    assert request_filter.blocked_navigations == ["intranet.example"]


async def test_hosts_that_do_not_resolve_or_cannot_be_hostnames_are_refused():
    request_filter = a_filter()
    assert await request_filter("https://gone.example/", "script", False) is False
    assert await request_filter("https://bad.example/", "script", False) is False


@pytest.mark.parametrize(
    "url", ["data:text/html,hi", "blob:https://books.example/1", "about:blank"]
)
async def test_urls_that_never_touch_the_network_are_allowed(url):
    assert await a_filter()(url, "document", True) is True


async def test_each_host_is_resolved_once_per_filter():
    dns = resolver(DNS)
    request_filter = RequestFilter(HostChecker(dns))
    for path in ("a.js", "b.js", "c.js"):
        await request_filter(f"https://books.example/{path}", "script", False)
    assert dns.calls == ["books.example"]


async def test_a_clean_redirect_chain_has_no_non_public_hop():
    responses = [
        DocumentResponse(
            "https://books.example/b", 200, redirect_chain=("https://books.example/a",)
        )
    ]
    assert await first_non_public_hop(responses, HostChecker(resolver(DNS))) is None


async def test_a_private_hop_inside_a_redirect_chain_is_found():
    chain = ("https://books.example/a", "http://intranet.example/x")
    responses = [DocumentResponse("https://books.example/b", 200, redirect_chain=chain)]
    assert await first_non_public_hop(responses, HostChecker(resolver(DNS))) == (
        "intranet.example",
        "resolves to non-public address 10.0.0.7",
    )


async def test_a_private_final_url_is_found():
    responses = [
        DocumentResponse("https://books.example/", 403),
        DocumentResponse("http://intranet.example/", 200),
    ]
    hop = await first_non_public_hop(responses, HostChecker(resolver(DNS)))
    assert hop == ("intranet.example", "resolves to non-public address 10.0.0.7")


async def test_a_hop_that_no_longer_resolves_fails_closed():
    responses = [DocumentResponse("https://gone.example/", 200)]
    hop = await first_non_public_hop(responses, HostChecker(resolver(DNS)))
    assert hop == ("gone.example", "no longer resolves")


async def test_hops_without_a_host_are_skipped():
    responses = [DocumentResponse("about:blank", 200)]
    assert await first_non_public_hop(responses, HostChecker(resolver(DNS))) is None
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_guards.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.guards'`.

- [ ] **Step 3: Implement.** `data-sources/src/fetcher/guards.py`:

```python
"""The address checks that run during and after a fetch (spec §6).

`RequestFilter` goes to the browser and decides, for every request the page
makes, whether it goes out. `first_non_public_hop` is the backstop for what the
filter cannot see: Playwright calls a route handler only for the first URL of a
redirect chain, and Firefox repeats the DNS lookup after the filter's check, so
every main-frame hop is checked again after navigation.
"""

from __future__ import annotations

from urllib.parse import urlsplit

from fetcher.browser import DocumentResponse
from fetcher.urlcheck import HostChecker, InvalidUrl, Unresolvable

# Only the HTML matters; blocking these roughly halves page time (spec §2).
BLOCKED_RESOURCE_TYPES = frozenset({"image", "font", "media", "stylesheet"})


class RequestFilter:
    def __init__(self, hosts: HostChecker) -> None:
        self._hosts = hosts
        # Hosts of navigations refused for being non-public, so a navigation
        # failure they caused reads as invalid_url rather than browser_error.
        self.blocked_navigations: list[str] = []

    async def __call__(self, url: str, resource_type: str, is_navigation: bool) -> bool:
        if resource_type in BLOCKED_RESOURCE_TYPES:
            return False
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            return True  # data:, blob:, about: -- nothing goes over the network
        if not parts.hostname:
            return False
        try:
            bad = await self._hosts.non_public_address(parts.hostname)
        except (InvalidUrl, Unresolvable):
            return False
        if bad is None:
            return True
        if is_navigation:
            self.blocked_navigations.append(parts.hostname)
        return False


async def first_non_public_hop(
    responses: list[DocumentResponse], hosts: HostChecker
) -> tuple[str, str] | None:
    """`(host, reason)` for the first hop, across every main-frame response and
    its redirect chain, whose host is not public; None when all are. A hop
    whose host no longer resolves counts: this check fails closed."""
    for response in responses:
        for hop in (*response.redirect_chain, response.url):
            host = urlsplit(hop).hostname
            if not host:
                continue
            try:
                bad = await hosts.non_public_address(host)
            except (InvalidUrl, Unresolvable):
                return host, "no longer resolves"
            if bad is not None:
                return host, f"resolves to non-public address {bad}"
    return None
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher/test_guards.py -v`
Expected: PASS.

- [ ] **Step 5: Lint and commit.**

Run: `uv run ruff check . && uv run ruff format --check .`

```bash
git add data-sources/src/fetcher/guards.py data-sources/tests/fetcher/test_guards.py
git commit -m "Add the request filter and the redirect-chain address backstop

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The Fetcher

**Files:**
- Create: `data-sources/src/fetcher/fetcher.py`
- Create: `data-sources/tests/fetcher/test_fetcher.py`

**Interfaces:**
- Consumes: `Settings` (Task 3); `HostChecker`, `InvalidUrl`, `Unresolvable`, `Resolver` and `system_resolver` (Task 4); `Budget`, `StageTimeout` and `Limiter` (Task 5); the `fetcher.browser` protocols and exceptions (Task 6); `RequestFilter` and `first_non_public_hop` (Task 7).
- Produces:
  - `FetchRequest(url, wait_until="load", wait_for_selector=None, timeout_ms=30_000)`, a frozen dataclass.
  - `FetchResult(url, final_url, status, title, html, selector_found, elapsed_ms, fetched_at)`, a frozen dataclass. `fetched_at` is formatted `YYYY-MM-DDTHH:MM:SSZ`.
  - `FetchError(code, http_status, detail)`.
  - `Fetcher(settings, browser, *, resolver=system_resolver, on_fatal=exit_process, close_limit_s=5.0)`, with `.settings`, `async start()`, `async stop()`, `health() -> dict` and `async fetch(FetchRequest) -> FetchResult`.
  - The constants `SELECTOR_RESERVE_S = 2.0`, `CLOSE_LIMIT_S = 5.0` and `REDIRECT_CHECK_LIMIT_S = 2.0`.
  - Logging: one JSON log line per fetch on the `"fetcher"` logger.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_fetcher.py`:

```python
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
from fetcher.fetcher import Fetcher, FetchError, FetchRequest
from fetcher.settings import Settings
from tests.fetcher.fakes import PAGE_HTML, PAGE_URL, FakeBrowser, Script, resolver

pytestmark = pytest.mark.anyio

DNS = {"intranet.example": ["10.0.0.7"], "gone.example": OSError("Name or service not known")}


def build(*scripts, settings=None, default=None, close_limit_s=0.2):
    fatal: list[str] = []
    browser = FakeBrowser(*scripts, default=default)
    fetcher = Fetcher(
        settings or Settings(host_interval_ms=0),
        browser,
        resolver=resolver(DNS),
        on_fatal=fatal.append,
        close_limit_s=close_limit_s,
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
    fetcher, _, fatal = build(*[Script(launch_delay_s=1) for _ in range(3)])
    for _ in range(3):
        assert (await fetch_error(fetcher, timeout_ms=50)).code == "navigation_timeout"
    assert len(fatal) == 1


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
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_fetcher.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.fetcher'`.

- [ ] **Step 3: Implement.** `data-sources/src/fetcher/fetcher.py`:

```python
"""One fetch, end to end (spec §2, §3, §6): check the URL, wait for a slot,
launch a fresh browser, load the page, and decide what the caller gets back.

Every decision is made here against the thin `Browser` protocol, so all of it is
tested with a fake browser.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
from collections.abc import Callable, Iterator
from dataclasses import asdict, dataclass
from datetime import UTC, datetime

from fetcher.browser import (
    Browser,
    BrowserError,
    BrowserFailure,
    BrowserSession,
    InvalidSelector,
    LaunchFailed,
    NavigationTimeout,
    UpstreamUnreachable,
    WaitUntil,
)
from fetcher.budget import Budget, StageTimeout
from fetcher.guards import RequestFilter, first_non_public_hop
from fetcher.limiter import Limiter
from fetcher.settings import Settings
from fetcher.urlcheck import HostChecker, InvalidUrl, Resolver, Unresolvable, system_resolver

log = logging.getLogger("fetcher")

# The selector wait stops this long before the deadline, so the HTML can still be read.
SELECTOR_RESERVE_S = 2.0
# A browser that takes longer than this to close is a leaked process (spec §3).
CLOSE_LIMIT_S = 5.0
# The redirect backstop's own limit, outside the budget: a page already read
# must not become a timeout because its redirect hops needed a DNS lookup.
REDIRECT_CHECK_LIMIT_S = 2.0


@dataclass(frozen=True)
class FetchRequest:
    url: str
    wait_until: WaitUntil = "load"
    wait_for_selector: str | None = None
    timeout_ms: int = 30_000


@dataclass(frozen=True)
class FetchResult:
    url: str
    final_url: str
    status: int
    title: str
    html: str
    selector_found: bool | None
    elapsed_ms: int
    fetched_at: str


class FetchError(Exception):
    """A fetch that ends in the error body `{"error": code, "detail": detail}` (spec §2)."""

    def __init__(self, code: str, http_status: int, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.http_status = http_status
        self.detail = detail


@dataclass
class _LogLine:
    """One structured line per fetch (spec §9). Never the HTML."""

    event: str = "fetch"
    host: str | None = None
    outcome: str | None = None
    status: int | None = None
    elapsed_ms: int | None = None
    launch_ms: int | None = None
    waited: bool = False


def exit_process(reason: str) -> None:
    """The default fatal hook: log, then exit a second later so the current
    response still goes out. Compose's restart policy brings the container back
    with a new driver, display and fingerprint (spec §3)."""
    log.critical(json.dumps({"event": "exiting", "reason": reason}))
    asyncio.get_running_loop().call_later(1.0, os._exit, 1)


def _ms_since(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


class Fetcher:
    def __init__(
        self,
        settings: Settings,
        browser: Browser,
        *,
        resolver: Resolver = system_resolver,
        on_fatal: Callable[[str], None] = exit_process,
        close_limit_s: float = CLOSE_LIMIT_S,
    ) -> None:
        self.settings = settings
        self._browser = browser
        self._resolver = resolver
        self._on_fatal = on_fatal
        self._close_limit_s = close_limit_s
        self._limiter = Limiter(settings.max_concurrency, settings.host_interval_ms / 1000)
        self._launch_failures = 0
        self._started_at = time.monotonic()
        self._counts = {"ok": 0, "failed": 0, "in_flight": 0}

    async def start(self) -> None:
        await self._browser.start()

    async def stop(self) -> None:
        await self._browser.stop()

    def health(self) -> dict:
        return {
            **self._browser.describe(),
            "uptime_s": int(time.monotonic() - self._started_at),
            "fetches": dict(self._counts),
            "launch_failures_in_a_row": self._launch_failures,
        }

    async def fetch(self, request: FetchRequest) -> FetchResult:
        started = time.monotonic()
        line = _LogLine()
        self._counts["in_flight"] += 1
        try:
            result = await self._fetch(request, started, line)
        except FetchError as exc:
            self._counts["failed"] += 1
            line.outcome = exc.code
            raise
        except Exception:
            self._counts["failed"] += 1
            line.outcome = "internal_error"
            raise
        else:
            self._counts["ok"] += 1
            line.outcome = "ok"
            line.status = result.status
            return result
        finally:
            self._counts["in_flight"] -= 1
            line.elapsed_ms = _ms_since(started)
            log.info(json.dumps(asdict(line)))

    async def _fetch(self, request: FetchRequest, started: float, line: _LogLine) -> FetchResult:
        budget = Budget(request.timeout_ms / 1000)
        hosts = HostChecker(self._resolver)
        try:
            try:
                target = await budget.run(hosts.check(request.url), "resolving the host")
            except InvalidUrl as exc:
                raise FetchError("invalid_url", 400, str(exc)) from None
            except Unresolvable as exc:
                raise FetchError("upstream_unreachable", 502, str(exc)) from None
            line.host = target.host
            async with self._limiter.slot(target.host, budget) as waited:
                line.waited = waited
                return await self._in_browser(request, budget, hosts, started, line)
        except StageTimeout as exc:
            detail = f"the budget ran out while {exc.stage}"
            raise FetchError("navigation_timeout", 504, detail) from None

    async def _in_browser(
        self,
        request: FetchRequest,
        budget: Budget,
        hosts: HostChecker,
        started: float,
        line: _LogLine,
    ) -> FetchResult:
        request_filter = RequestFilter(hosts)
        launch_started = time.monotonic()
        try:
            session = await budget.run(
                self._browser.launch(request_filter, budget.remaining()), "launching the browser"
            )
        except StageTimeout:
            self._launch_failed()
            raise
        except LaunchFailed as exc:
            self._launch_failed()
            raise FetchError("browser_unavailable", 503, str(exc)) from None
        self._launch_failures = 0
        line.launch_ms = _ms_since(launch_started)
        try:
            return await self._read(session, request, budget, hosts, request_filter, started)
        finally:
            await self._close(session)

    async def _read(
        self,
        session: BrowserSession,
        request: FetchRequest,
        budget: Budget,
        hosts: HostChecker,
        request_filter: RequestFilter,
        started: float,
    ) -> FetchResult:
        with self._mapped("loading the page", request_filter):
            await budget.run(
                session.goto(request.url, request.wait_until, budget.remaining()),
                "loading the page",
            )

        selector_found = None
        if request.wait_for_selector is not None:
            selector_found = await self._wait_for_selector(
                session, request.wait_for_selector, budget, request_filter
            )

        with self._mapped("reading the HTML", request_filter):
            html = await budget.run(session.content(), "reading the HTML")
            title = await budget.run(session.title(), "reading the HTML")

        responses = session.document_responses()
        try:
            hop = await asyncio.wait_for(
                first_non_public_hop(responses, hosts), timeout=REDIRECT_CHECK_LIMIT_S
            )
        except TimeoutError:
            hop = ("the page's redirect hops", "could not be checked in time")
        if hop is not None:
            host, reason = hop
            raise FetchError("invalid_url", 400, f"the page went through {host}, which {reason}")
        if not responses:
            raise FetchError("browser_error", 502, "navigation produced no document response")

        size = len(html.encode("utf-8"))
        cap = self.settings.max_html_bytes
        if size > cap:
            raise FetchError(
                "html_too_large", 502, f"the HTML is {size} bytes, over the {cap}-byte cap"
            )

        last = responses[-1]
        return FetchResult(
            url=request.url,
            final_url=last.url,
            status=last.status,
            title=title,
            html=html,
            selector_found=selector_found,
            elapsed_ms=_ms_since(started),
            fetched_at=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        )

    async def _wait_for_selector(
        self,
        session: BrowserSession,
        selector: str,
        budget: Budget,
        request_filter: RequestFilter,
    ) -> bool:
        wait_s = budget.remaining() - SELECTOR_RESERVE_S
        if wait_s <= 0:
            return False
        with self._mapped("waiting for the selector", request_filter):
            return await budget.run(
                session.wait_for_selector(selector, wait_s), "waiting for the selector"
            )

    @contextlib.contextmanager
    def _mapped(self, stage: str, request_filter: RequestFilter) -> Iterator[None]:
        """Translate a browser failure during `stage` into the caller's answer (spec §2)."""
        try:
            yield
        except NavigationTimeout:
            raise StageTimeout(stage) from None
        except UpstreamUnreachable as exc:
            raise FetchError("upstream_unreachable", 502, str(exc)) from None
        except InvalidSelector as exc:
            raise FetchError("invalid_selector", 400, str(exc)) from None
        except BrowserError as exc:
            if request_filter.blocked_navigations:
                host = request_filter.blocked_navigations[0]
                detail = f"navigation to {host} was blocked: it resolves to a non-public address"
                raise FetchError("invalid_url", 400, detail) from None
            raise FetchError("browser_error", 502, str(exc)) from None
        except BrowserFailure as exc:
            raise FetchError("browser_error", 502, str(exc)) from None

    async def _close(self, session: BrowserSession) -> None:
        try:
            await asyncio.wait_for(session.close(), timeout=self._close_limit_s)
        except TimeoutError:
            # A Firefox that will not close is a leaked process (spec §3).
            self._on_fatal(f"a browser did not close within {self._close_limit_s:g}s")
        except Exception:  # an already-crashed browser can fail to close; it is gone anyway
            log.warning(json.dumps({"event": "close_failed"}))

    def _launch_failed(self) -> None:
        self._launch_failures += 1
        if self._launch_failures == self.settings.max_launch_failures:
            self._on_fatal(f"{self._launch_failures} browser launches failed in a row")
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher/test_fetcher.py -v`
Expected: PASS. The whole file runs in a few seconds; the longest waits are 0.5 s.

- [ ] **Step 5: Run the whole fetcher suite, then lint.** Line length is 100; fix any E501 that `ruff format` leaves in strings by splitting them.

Run: `uv run pytest tests/fetcher -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS and clean.

- [ ] **Step 6: Commit.**

```bash
git add data-sources/src/fetcher/fetcher.py data-sources/tests/fetcher/test_fetcher.py
git commit -m "Add the Fetcher: budget stages, error mapping, launch and close limits

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The HTTP API

**Files:**
- Create: `data-sources/src/fetcher/api/__init__.py` (empty)
- Create: `data-sources/src/fetcher/api/schemas.py`
- Create: `data-sources/src/fetcher/api/routes.py`
- Create: `data-sources/src/fetcher/api/main.py`
- Create: `data-sources/tests/fetcher/test_api.py`

**Interfaces:**
- Consumes: `Fetcher`, `FetchRequest` and `FetchError` (Task 8); `Settings` and `MIN_TIMEOUT_MS` (Task 3).
- Produces:
  - `fetcher.api.main.create_app(fetcher: Fetcher | None = None) -> FastAPI`. With no argument it builds `Fetcher(Settings.from_env(), CamoufoxBrowser(locale=...))`; `CamoufoxBrowser` arrives in Task 10.
  - `fetcher.api.main.factory() -> FastAPI`, the uvicorn entry point.
  - `app.state.fetcher`.
  - The routes `POST /fetch` and `GET /health`. There is no `/version`.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_api.py`:

```python
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
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_api.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'fetcher.api'`.

- [ ] **Step 3: Implement the API.**

`data-sources/src/fetcher/api/__init__.py`: an empty file.

`data-sources/src/fetcher/api/schemas.py`:

```python
"""Request and response bodies for POST /fetch (spec §2).

No `from __future__ import annotations` here or in routes.py: FastAPI must see
real classes, and the request model is built per app so that its timeout
bounds come from Settings.
"""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from fetcher.settings import MIN_TIMEOUT_MS, Settings


def fetch_request_model(settings: Settings) -> type[BaseModel]:
    class FetchRequestBody(BaseModel):
        # Unknown fields are a 422 naming the field, the same rule as /resolve.
        model_config = ConfigDict(extra="forbid")

        url: str = Field(min_length=1, max_length=8192)
        wait_until: Literal["domcontentloaded", "load", "networkidle"] = "load"
        wait_for_selector: str | None = Field(default=None, min_length=1, max_length=1000)
        timeout_ms: int = Field(
            default=settings.default_timeout_ms, ge=MIN_TIMEOUT_MS, le=settings.max_timeout_ms
        )

    return FetchRequestBody


class FetchResponseBody(BaseModel):
    url: str
    final_url: str
    status: int
    title: str
    html: str
    selector_found: bool | None
    elapsed_ms: int
    fetched_at: str


class ErrorBody(BaseModel):
    error: str
    detail: str
```

`data-sources/src/fetcher/api/routes.py`:

```python
"""POST /fetch and GET /health (spec §2).

No `from __future__ import annotations`: the request body's class is built at
runtime from Settings, and FastAPI must see that real class in the signature.
"""

from dataclasses import asdict

from fastapi import APIRouter

from fetcher.api.schemas import ErrorBody, FetchResponseBody, fetch_request_model
from fetcher.fetcher import Fetcher, FetchRequest

ERROR_RESPONSES = {status: {"model": ErrorBody} for status in (400, 502, 503, 504)}


def build_router(fetcher: Fetcher) -> APIRouter:
    router = APIRouter()
    FetchRequestBody = fetch_request_model(fetcher.settings)

    @router.post("/fetch", response_model=FetchResponseBody, responses=ERROR_RESPONSES)
    async def fetch(body: FetchRequestBody) -> FetchResponseBody:
        result = await fetcher.fetch(FetchRequest(**body.model_dump()))
        return FetchResponseBody(**asdict(result))

    @router.get("/health")
    def health() -> dict:
        return fetcher.health()

    return router
```

`data-sources/src/fetcher/api/main.py`:

```python
"""The page fetcher service (spec: 2026-09-26-page-fetcher-service-design.md).

URL in, rendered HTML out. A pure function of the request: no cache, no state
between calls, one fresh browser per fetch.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from fetcher import __version__
from fetcher.api.routes import build_router
from fetcher.fetcher import Fetcher, FetchError
from fetcher.settings import Settings


def create_app(fetcher: Fetcher | None = None) -> FastAPI:
    if fetcher is None:
        from fetcher.browser import CamoufoxBrowser

        settings = Settings.from_env()
        fetcher = Fetcher(settings, CamoufoxBrowser(locale=settings.locale))
    service = fetcher

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await service.start()
        try:
            yield
        finally:
            await service.stop()

    app = FastAPI(title="Page fetcher", version=__version__, lifespan=lifespan)
    app.state.fetcher = service
    app.include_router(build_router(service))

    @app.exception_handler(FetchError)
    async def fetch_error(request: Request, exc: FetchError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.http_status, content={"error": exc.code, "detail": exc.detail}
        )

    return app


def factory() -> FastAPI:
    # uvicorn configures only its own loggers; the one-line-per-fetch log
    # (spec §9) needs the "fetcher" logger to reach stdout as well.
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    return create_app()
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher -v`
Expected: PASS. The Task 6 import-isolation test now also walks `fetcher.api.*` and must stay green.

- [ ] **Step 5: Lint and commit.**

Run: `uv run ruff check . && uv run ruff format --check .`

```bash
git add data-sources/src/fetcher/api data-sources/tests/fetcher/test_api.py
git commit -m "Add the fetcher's HTTP API: POST /fetch and GET /health

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The Camoufox backend, the compose service and the smoke check

**Files:**
- Modify: `data-sources/src/fetcher/browser.py` (append the Camoufox classes; add imports at the top)
- Create: `data-sources/tests/fetcher/test_camoufox_backend.py`
- Modify: `data-sources/docker-compose.yml` (add the `fetcher` service; `api` and `build` untouched)
- Modify: `docs/features/page-fetcher-service.md` (write the full doc around Task 2's "Measured" section)
- Modify: `data-sources/README.md`
- Modify: `AGENTS.md` (one paragraph in "The Python data service")

**Interfaces:**
- Consumes: everything from Tasks 6 and 9.
- Produces: `fetcher.browser.CamoufoxBrowser(locale: str)`, which implements `Browser`, and `fetcher.browser.CamoufoxSession`, which implements `BrowserSession`. `describe()` returns `{"camoufox_version": <installed package version>, "browser_build": $CAMOUFOX_BROWSER or "unknown"}`.

- [ ] **Step 1: Write the failing tests.** `data-sources/tests/fetcher/test_camoufox_backend.py`:

```python
import importlib.metadata

import pytest

from fetcher.api.main import create_app
from fetcher.browser import CamoufoxBrowser, LaunchFailed


def test_create_app_without_a_fetcher_uses_camoufox_and_the_environment(monkeypatch):
    monkeypatch.setenv("FETCHER_LOCALE", "en-GB")
    monkeypatch.setenv("CAMOUFOX_BROWSER", "official/stable/152.0.4-beta.30")

    app = create_app()  # no lifespan: nothing starts, nothing launches

    service = app.state.fetcher
    assert service.settings.locale == "en-GB"
    health = service.health()
    assert health["camoufox_version"] == importlib.metadata.version("camoufox")
    assert health["browser_build"] == "official/stable/152.0.4-beta.30"


def test_describe_says_unknown_when_the_build_is_not_set(monkeypatch):
    monkeypatch.delenv("CAMOUFOX_BROWSER", raising=False)
    assert CamoufoxBrowser("en-US").describe()["browser_build"] == "unknown"


@pytest.mark.anyio
async def test_launching_before_start_is_a_launch_failure():
    async def allow_all(url, resource_type, is_navigation):
        return True

    with pytest.raises(LaunchFailed, match="not been started"):
        await CamoufoxBrowser("en-US").launch(allow_all, 5.0)
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `uv run pytest tests/fetcher/test_camoufox_backend.py -v`
Expected: FAIL, `ImportError: cannot import name 'CamoufoxBrowser'`.

- [ ] **Step 3: Implement the backend.** In `data-sources/src/fetcher/browser.py`, extend the imports at the top to:

```python
from __future__ import annotations

import asyncio
import contextlib
import functools
import importlib.metadata
import logging
import os
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, Literal, Protocol
```

and append to the end of the file:

```python
log = logging.getLogger("fetcher")


class CamoufoxBrowser:
    """The real backend (spec §3). One Playwright driver, one Xvfb display and
    one set of launch options, and so one fingerprint, for the life of the
    process; a fresh Firefox for every fetch."""

    def __init__(self, locale: str) -> None:
        self._locale = locale
        self._playwright: Any = None
        self._display: Any = None
        self._options: dict[str, Any] | None = None

    async def start(self) -> None:
        from camoufox.pkgman import camoufox_path, launch_path
        from camoufox.utils import launch_options
        from camoufox.virtdisplay import VirtualDisplay
        from playwright.async_api import async_playwright

        # The image bakes the browser in (spec §4). download_if_missing=False
        # turns a missing browser into a startup failure, never a download.
        executable = launch_path(camoufox_path(download_if_missing=False))
        self._display = VirtualDisplay()
        display = await asyncio.to_thread(self._display.get)
        self._options = await asyncio.to_thread(
            functools.partial(
                launch_options,
                executable_path=executable,
                headless=False,
                virtual_display=display,
                locale=self._locale,
                humanize=False,
                geoip=False,
            )
        )
        self._playwright = await async_playwright().start()

    async def stop(self) -> None:
        if self._playwright is not None:
            await self._playwright.stop()
            self._playwright = None
        if self._display is not None:
            self._display.kill()
            self._display = None

    async def launch(self, request_filter: RequestFilter, timeout_s: float) -> BrowserSession:
        if self._playwright is None or self._options is None:
            raise LaunchFailed("the browser backend has not been started")
        from camoufox.async_api import AsyncNewBrowser

        options = {**self._options, "timeout": playwright_ms(timeout_s)}
        try:
            browser = await AsyncNewBrowser(self._playwright, from_options=options)
        except Exception as exc:
            raise LaunchFailed(_first_line(exc)) from exc
        try:
            # A service worker could answer requests the route never sees.
            page = await browser.new_page(service_workers="block")
            session = CamoufoxSession(browser, page)
            await page.route("**/*", _route_handler(request_filter))
            page.on("response", session.record_response)
        except Exception as exc:
            await _close_quietly(browser)
            raise LaunchFailed(_first_line(exc)) from exc
        return session

    def describe(self) -> dict[str, str]:
        try:
            version = importlib.metadata.version("camoufox")
        except importlib.metadata.PackageNotFoundError:
            version = "not installed"
        return {
            "camoufox_version": version,
            "browser_build": os.environ.get("CAMOUFOX_BROWSER", "unknown"),
        }


class CamoufoxSession:
    def __init__(self, browser: Any, page: Any) -> None:
        self._browser = browser
        self._page = page
        self._responses: list[DocumentResponse] = []

    def record_response(self, response: Any) -> None:
        """Keep every main-frame document response with its redirect chain; the
        fetcher takes `status` from the last one (spec §2)."""
        try:
            request = response.request
            if not request.is_navigation_request() or response.frame != self._page.main_frame:
                return
            chain: list[str] = []
            earlier = request.redirected_from
            while earlier is not None:
                chain.append(earlier.url)
                earlier = earlier.redirected_from
            self._responses.append(
                DocumentResponse(
                    url=response.url, status=response.status, redirect_chain=tuple(reversed(chain))
                )
            )
        except Exception:
            # A response for a frame being torn down; there is nothing to record.
            log.debug("response skipped", exc_info=True)

    async def goto(self, url: str, wait_until: WaitUntil, timeout_s: float) -> None:
        try:
            await self._page.goto(url, wait_until=wait_until, timeout=playwright_ms(timeout_s))
        except Exception as exc:
            raise translate_playwright_error(exc) from exc

    async def wait_for_selector(self, selector: str, timeout_s: float) -> bool:
        from playwright.async_api import TimeoutError as PlaywrightTimeoutError

        try:
            # attached, not visible: the service returns HTML, and visibility
            # depends on the stylesheets it blocks (spec §2).
            await self._page.wait_for_selector(
                selector, state="attached", timeout=playwright_ms(timeout_s)
            )
        except PlaywrightTimeoutError:
            return False
        except Exception as exc:
            raise translate_playwright_error(exc) from exc
        return True

    async def content(self) -> str:
        try:
            return await self._page.content()
        except Exception as exc:
            raise translate_playwright_error(exc) from exc

    async def title(self) -> str:
        try:
            return await self._page.title()
        except Exception as exc:
            raise translate_playwright_error(exc) from exc

    def document_responses(self) -> list[DocumentResponse]:
        return list(self._responses)

    async def close(self) -> None:
        await _close_quietly(self._browser)


def _route_handler(request_filter: RequestFilter) -> Callable[[Any, Any], Awaitable[None]]:
    async def handle(route: Any, request: Any) -> None:
        try:
            allowed = await request_filter(
                request.url, request.resource_type, request.is_navigation_request()
            )
        except Exception:
            allowed = False
        # The page can close under a pending route; then there is nothing left to decide.
        with contextlib.suppress(Exception):
            if allowed:
                await route.continue_()
            else:
                await route.abort("blockedbyclient")

    return handle


async def _close_quietly(browser: Any) -> None:
    # An already-crashed browser can fail to close; it is gone either way.
    with contextlib.suppress(Exception):
        await browser.close()
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `uv run pytest tests/fetcher -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS and clean. The import-isolation test must stay green: every Camoufox and Playwright import in the new code is inside a function.

- [ ] **Step 5: Add the compose service.** Append to `data-sources/docker-compose.yml`, under `services:` after the `build` service:

```yaml
  # The page fetcher (docs/features/page-fetcher-service.md). Its own image, so
  # the Open Library image never carries Firefox; a fresh browser per fetch.
  fetcher:
    build:
      context: .
      dockerfile: fetcher.Dockerfile
    image: the-greatest/page-fetcher:latest
    restart: unless-stopped
    ports:
      # Loopback by default, the same rule as `api`: set FETCHER_BIND=0.0.0.0
      # only where Rails is not on this host, and never on a public request path.
      - "${FETCHER_BIND:-127.0.0.1}:8081:8081"
    shm_size: 1g
    mem_limit: 2g
    environment:
      # Every variable the service reads, forwarded with its default. Compose
      # does not pass through a host variable that is not listed here.
      FETCHER_MAX_CONCURRENCY: "${FETCHER_MAX_CONCURRENCY:-2}"
      FETCHER_HOST_INTERVAL_MS: "${FETCHER_HOST_INTERVAL_MS:-2000}"
      FETCHER_MAX_LAUNCH_FAILURES: "${FETCHER_MAX_LAUNCH_FAILURES:-3}"
      FETCHER_MAX_HTML_BYTES: "${FETCHER_MAX_HTML_BYTES:-5242880}"
      FETCHER_DEFAULT_TIMEOUT_MS: "${FETCHER_DEFAULT_TIMEOUT_MS:-30000}"
      FETCHER_MAX_TIMEOUT_MS: "${FETCHER_MAX_TIMEOUT_MS:-60000}"
      FETCHER_LOCALE: "${FETCHER_LOCALE:-en-US}"
      # Firefox takes its timezone from TZ. Without it the container is UTC,
      # which does not match a US residential IP with an en-US locale.
      # America/Chicago is the development machine's zone; set FETCHER_TZ to
      # the home server's zone if it differs.
      TZ: "${FETCHER_TZ:-America/Chicago}"
    healthcheck:
      # Marks a process that stops answering as unhealthy in `docker ps`.
      # Docker restarts only on exit, so this restarts nothing (spec §3).
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8081/health').status == 200 else 1)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

Run: `docker compose config --quiet`
Expected: no output. The file is valid.

- [ ] **Step 6: Check nothing else holds port 8081, then start it.**

Run: `ss -ltnpH 'sport = :8081'`
Expected: no output. If something is listening, stop and tell Shane. Do not kill it.

Run (from `data-sources/`): `docker compose up -d --build fetcher`
Then poll `docker compose ps fetcher` until its STATUS shows `(healthy)`, which takes about 30–60 s. Use an until-loop or a Monitor, not a bare `sleep`.

- [ ] **Step 7: The smoke check** (spec §9). Run each command and paste its output into the task report:

```bash
curl -s localhost:8081/health
```
Expected: `camoufox_version` is `0.5.6`, `browser_build` is `official/stable/152.0.4-beta.30`, and `launch_failures_in_a_row` is 0.

```bash
curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' \
  -d '{"url":"https://www.goodreads.com/book/show/4671.The_Great_Gatsby","wait_for_selector":"h1"}' \
  | python -c "import json,sys; b=json.load(sys.stdin); b.pop('html',None); print(b)"
```
Expected: `status` 200, a `title` containing "Great Gatsby", `selector_found` true, and `elapsed_ms` of a few thousand.

```bash
curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' \
  -d '{"url":"https://bookshop.org/book/9780743273565","wait_until":"networkidle","timeout_ms":45000}' \
  | python -c "import json,sys; b=json.load(sys.stdin); b.pop('html',None); print(b)"
```
This is a probe, not a gate. Record what happened. A book title means the Cloudflare challenge cleared; "Just a moment…" with `status` 403 means it did not. Either way the service answered correctly, and Shane needs to know which.

```bash
curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' \
  -d '{"url":"https://www.goodreads.com/book/show/4671.The_Great_Gatsby","wait_for_selector":"div[["}'
```
Expected: HTTP 400 `{"error":"invalid_selector",...}` (Review Focus 1). If it answers `browser_error` instead:
- Copy the real `detail` text into `test_an_unparseable_selector_is_invalid_selector` in `test_browser.py` as a third case.
- Adjust the `"while parsing"` check in `translate_playwright_error` until that test passes.
- Rebuild with `docker compose up -d --build fetcher` and re-run this command.

```bash
curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' -d '{"url":"http://127.0.0.1:8081/health"}'
docker compose exec fetcher id -u
docker compose logs fetcher | tail -5
```
Expected, in order:
- `{"error":"invalid_url",...}`
- `10001`
- JSON log lines of the form `{"event": "fetch", "host": ..., "outcome": ...}`, with no HTML in them.

Run: `docker compose stop fetcher`. Stopping it leaves no surprise container running.

- [ ] **Step 8: Write the feature doc.** Rewrite `docs/features/page-fetcher-service.md` as the text below.
  - The final `## Measured` heading and its one parenthetical line are a marker, not content. In their place, keep Task 2's whole "Measured" section as it stands.
  - Add two rows to that table: the smoke check's Goodreads result and its bookshop.org result (status and title).

````markdown
# Page Fetcher Service

Design: `docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md`
Plan: `docs/superpowers/plans/2026-09-26-page-fetcher-service.md`

URL in, rendered HTML out, for sites that reject plain HTTP clients (Goodreads,
bookshop.org, publisher pages). A second service in `data-sources/`, next to the
Open Library API, built on Camoufox, an anti-detection Firefox driven through
Playwright. It never parses pages: a caller's parser decides whether the HTML is
a book page or a bot wall.

## How it works

- **A browser per fetch.** Each fetch launches its own Firefox, loads one page
  and closes it. A crash, hang or leak costs that one fetch. The Playwright
  driver, one Xvfb display and the launch options (and so one browser
  fingerprint) are shared for the life of the process.
- **Two at once, spaced per host.** `FETCHER_MAX_CONCURRENCY` browsers at most;
  starts to the same host at least `FETCHER_HOST_INTERVAL_MS` apart.
- **One budget.** `timeout_ms` covers the slot wait, the launch, the page load,
  the selector wait and reading the HTML. The selector wait stops 2 s early so
  the HTML can still be read.
- **Self-healing by exit.** Three failed launches in a row, or a browser that
  will not close within 5 s, exit the process; `restart: unless-stopped`
  brings it back. The health check restarts nothing: Docker only restarts on
  exit.

## Where it runs

On the development machine today. Neither this nor the Open Library service is
deployed: both go to the headless home server behind a Cloudflare Tunnel, and
**both hostnames need Cloudflare Access in front before they go live**. Neither
service authenticates, and an open fetcher would be a proxy on a home IP.

## Running it

    cd data-sources
    docker compose up -d --build fetcher        # serves 127.0.0.1:8081
    curl -s localhost:8081/health

## API

`POST /fetch`:

    {"url": "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
     "wait_until": "load", "wait_for_selector": null, "timeout_ms": 30000}

returns `url`, `final_url`, `status` (the site's status), `title`, `html`,
`selector_found` (null when no selector was asked for), `elapsed_ms` and
`fetched_at`. A 403 bot wall is a 200 from the service with `status: 403`.

| HTTP | `error` | When |
|---|---|---|
| 400 | `invalid_url` | Bad scheme, embedded credentials, or a non-public address anywhere on the way |
| 400 | `invalid_selector` | `wait_for_selector` does not parse |
| 422 | FastAPI's body | Unknown field, bad `wait_until`, `timeout_ms` outside 1000–60000 |
| 502 | `upstream_unreachable` | DNS, a refused or reset connection, TLS |
| 502 | `html_too_large` | Over 5 MB of HTML |
| 502 | `browser_error` | Anything else the browser raised |
| 503 | `browser_unavailable` | The browser failed to launch |
| 504 | `navigation_timeout` | The budget ran out; `detail` names the stage |

`GET /health` reports `camoufox_version`, `browser_build`, `uptime_s`,
`fetches` (`ok`, `failed`, `in_flight`) and `launch_failures_in_a_row`.

## Configuration

`FETCHER_MAX_CONCURRENCY` (2), `FETCHER_HOST_INTERVAL_MS` (2000),
`FETCHER_MAX_LAUNCH_FAILURES` (3), `FETCHER_MAX_HTML_BYTES` (5242880),
`FETCHER_DEFAULT_TIMEOUT_MS` (30000), `FETCHER_MAX_TIMEOUT_MS` (60000),
`FETCHER_LOCALE` (en-US). Compose also sets `TZ` from `FETCHER_TZ` (default
`America/Chicago`) so the browser's clock matches the egress IP, and
`FETCHER_BIND` (default `127.0.0.1`) for the published port. A bad value fails
startup naming the variable.

## Upgrading the browser

The Python package does not pin the browser. The build arg does:
`CAMOUFOX_BROWSER` in `fetcher.Dockerfile`. To upgrade, change that default (or
the `camoufox` range in `pyproject.toml` plus `uv lock`), rebuild, and run the
smoke check below. `python -m fetcher.install_check` fails the build if the
pinned build, the uBlock Origin add-on or a system library is missing.

## Smoke check

The only place a real browser runs; there is deliberately no automated
real-browser test. Run it after any browser or package bump:

    docker compose up -d --build fetcher
    curl -s localhost:8081/health
    curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' \
      -d '{"url":"https://www.goodreads.com/book/show/4671.The_Great_Gatsby"}' | head -c 400

Also fetch a bookshop.org page with `"wait_until":"networkidle"` and read the
`title`: "Just a moment…" with `status` 403 means Cloudflare's challenge did not clear.

## Measured

(Task 2's table, plus the smoke check's Goodreads and bookshop.org results.)
````

- [ ] **Step 9: Update the README and AGENTS.md.**

In `data-sources/README.md`, add to the source list:

```markdown
- `src/fetcher/` — the page fetcher: URL in, rendered HTML out, one Camoufox browser per fetch.
```

Add this section after "Running the API":

```markdown
## Running the page fetcher

Its own image (`fetcher.Dockerfile`) and compose service, so the Open Library
image never carries Firefox. Full doc: `docs/features/page-fetcher-service.md`.

    docker compose up -d --build fetcher        # serves 127.0.0.1:8081
    curl -s localhost:8081/health

Tests need the extra (`uv sync --locked --extra fetcher`) but never a browser.
The port binds to loopback by default (`FETCHER_BIND`): the same rule as the
API above.
```

In `AGENTS.md`, at the end of the "The Python data service (`data-sources/`)" section, add:

```markdown
`data-sources/` now holds two services with separate images: the Open Library API
and the **page fetcher** (`docs/features/page-fetcher-service.md`), which returns
rendered HTML through one Camoufox browser per fetch. Its dependencies are the
`fetcher` extra: `uv sync --locked --extra fetcher`, which CI also runs.
```

- [ ] **Step 10: Commit.**

```bash
git add data-sources/src/fetcher/browser.py data-sources/tests/fetcher/test_camoufox_backend.py \
  data-sources/docker-compose.yml docs/features/page-fetcher-service.md data-sources/README.md AGENTS.md
git commit -m "Add the Camoufox backend and the fetcher compose service, smoke-checked

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Rails configuration, exceptions and the Page value object

**Files:**
- Create: `web-app/app/lib/page_fetcher/configuration.rb`
- Create: `web-app/app/lib/page_fetcher/exceptions.rb`
- Create: `web-app/app/lib/page_fetcher/page.rb`
- Create: `web-app/test/lib/page_fetcher/configuration_test.rb`
- Create: `web-app/test/lib/page_fetcher/exceptions_test.rb`
- Create: `web-app/test/lib/page_fetcher/page_test.rb`

These are plain Ruby objects under `app/lib`; no generator applies.

**Interfaces:**
- Produces:
  - `PageFetcher::Configuration.new(base_url: nil, open_timeout: nil, user_agent: nil, logger: nil)`, with readers `base_url`, `open_timeout` (default 3), `user_agent` and `logger`. `DEFAULT_URL` is `"http://127.0.0.1:8081"`, and the URL is read from `PAGE_FETCHER_SERVICE_URL`.
  - The exceptions, all under `PageFetcher::Exceptions`:
    - `Error`, with `ConfigurationError`, `NetworkError` (`original_error`) and its subclass `TimeoutError`, and `ParseError` (`response_body`).
    - `HttpError` (`status_code`, `response_body`, `error_code:`), with subclasses `ClientError`, `ServerError` and `UpstreamError`.
    - `CircuitOpenError < Error`.
  - `PageFetcher::Page`: `Data` with `url`, `final_url`, `status`, `title`, `html`, `selector_found`, `elapsed_ms` and `fetched_at` (a `Time`), and `.from_response(hash)`. Its `#inspect`/`#to_s` never include the HTML.

- [ ] **Step 1: Write the failing tests.**

`web-app/test/lib/page_fetcher/configuration_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class ConfigurationTest < ActiveSupport::TestCase
    def setup
      @original_env = ENV["PAGE_FETCHER_SERVICE_URL"]
    end

    def teardown
      ENV["PAGE_FETCHER_SERVICE_URL"] = @original_env
    end

    test "defaults to the docker-published loopback address" do
      ENV.delete("PAGE_FETCHER_SERVICE_URL")

      assert_equal "http://127.0.0.1:8081", PageFetcher::Configuration.new.base_url
    end

    test "reads the base url from the environment" do
      ENV["PAGE_FETCHER_SERVICE_URL"] = "https://fetcher.example.test"

      assert_equal "https://fetcher.example.test", PageFetcher::Configuration.new.base_url
    end

    test "an explicit base_url wins over the environment variable" do
      ENV["PAGE_FETCHER_SERVICE_URL"] = "https://fetcher.example.test"

      assert_equal "http://override.test", PageFetcher::Configuration.new(base_url: "http://override.test").base_url
    end

    test "defaults the open timeout to three seconds" do
      assert_equal 3, PageFetcher::Configuration.new.open_timeout
    end

    test "sets a descriptive user agent by default" do
      assert_match(/TheGreatest/, PageFetcher::Configuration.new.user_agent)
    end

    test "defaults the logger to the Rails logger" do
      assert_equal Rails.logger, PageFetcher::Configuration.new.logger
    end

    test "rejects a blank base url" do
      ENV["PAGE_FETCHER_SERVICE_URL"] = ""

      assert_raises(PageFetcher::Exceptions::ConfigurationError) { PageFetcher::Configuration.new }
    end

    test "rejects a non-http base url" do
      assert_raises(PageFetcher::Exceptions::ConfigurationError) do
        PageFetcher::Configuration.new(base_url: "ftp://fetcher.example.test")
      end
    end

    test "rejects a malformed base url" do
      assert_raises(PageFetcher::Exceptions::ConfigurationError) do
        PageFetcher::Configuration.new(base_url: "http://bad host")
      end
    end
  end
end
```

`web-app/test/lib/page_fetcher/exceptions_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class ExceptionsTest < ActiveSupport::TestCase
    test "every client failure, a tripped breaker included, is a PageFetcher::Exceptions::Error" do
      [
        Exceptions::ConfigurationError, Exceptions::NetworkError, Exceptions::TimeoutError,
        Exceptions::HttpError, Exceptions::ClientError, Exceptions::ServerError,
        Exceptions::UpstreamError, Exceptions::ParseError, Exceptions::CircuitOpenError
      ].each { |error_class| assert_operator error_class, :<, Exceptions::Error }
    end

    test "the circuit-open error is not the Open Library one" do
      assert_not_equal Books::OpenLibrary::Exceptions::CircuitOpenError, Exceptions::CircuitOpenError
    end

    test "an HTTP error carries the status, the body and the service's error code" do
      error = Exceptions::UpstreamError.new("upstream_unreachable: gone", 502, "{}", error_code: "upstream_unreachable")

      assert_equal [502, "{}", "upstream_unreachable"], [error.status_code, error.response_body, error.error_code]
    end

    test "the error code is optional" do
      assert_nil Exceptions::ClientError.new("HTTP 422", 422).error_code
    end
  end
end
```

`web-app/test/lib/page_fetcher/page_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class PageTest < ActiveSupport::TestCase
    BODY = {
      "url" => "https://www.goodreads.com/book/show/4671",
      "final_url" => "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
      "status" => 403,
      "title" => "Just a moment...",
      "html" => "<html>#{"x" * 5000}</html>",
      "selector_found" => nil,
      "elapsed_ms" => 4120,
      "fetched_at" => "2026-09-26T18:02:11Z"
    }.freeze

    test "maps every field of a fetch response" do
      page = PageFetcher::Page.from_response(BODY)

      assert_equal BODY["url"], page.url
      assert_equal BODY["final_url"], page.final_url
      assert_equal 403, page.status
      assert_equal "Just a moment...", page.title
      assert_equal BODY["html"], page.html
      assert_nil page.selector_found
      assert_equal 4120, page.elapsed_ms
      assert_equal Time.utc(2026, 9, 26, 18, 2, 11), page.fetched_at
    end

    test "a missing field raises KeyError" do
      assert_raises(KeyError) { PageFetcher::Page.from_response(BODY.except("html")) }
    end

    test "an unparseable timestamp raises ArgumentError" do
      assert_raises(ArgumentError) { PageFetcher::Page.from_response(BODY.merge("fetched_at" => "yesterday")) }
    end

    test "inspect and to_s never include the html" do
      page = PageFetcher::Page.from_response(BODY)

      [page.inspect, page.to_s].each do |text|
        assert_no_match(/xxxxx/, text)
        assert_includes text, "bytes"
        assert_includes text, "403"
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `bin/rails test test/lib/page_fetcher/`
Expected: FAIL, `NameError: uninitialized constant PageFetcher`.

- [ ] **Step 3: Implement.**

`web-app/app/lib/page_fetcher/configuration.rb`:

```ruby
# frozen_string_literal: true

module PageFetcher
  class Configuration
    # 127.0.0.1, not localhost: data-sources' compose file publishes exactly
    # 127.0.0.1:8081, and "localhost" can resolve to ::1 first.
    DEFAULT_URL = "http://127.0.0.1:8081"
    DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
    DEFAULT_OPEN_TIMEOUT = 3

    attr_accessor :base_url, :open_timeout, :user_agent, :logger

    def initialize(base_url: nil, open_timeout: nil, user_agent: nil, logger: nil)
      @base_url = base_url.nil? ? ENV.fetch("PAGE_FETCHER_SERVICE_URL", DEFAULT_URL) : base_url
      @open_timeout = open_timeout.nil? ? DEFAULT_OPEN_TIMEOUT : open_timeout
      @user_agent = user_agent.nil? ? DEFAULT_USER_AGENT : user_agent
      @logger = logger.nil? ? Rails.logger : logger

      validate_configuration!
    end

    private

    def validate_configuration!
      raise Exceptions::ConfigurationError, "PAGE_FETCHER_SERVICE_URL cannot be blank" if base_url.blank?

      uri = URI.parse(base_url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise Exceptions::ConfigurationError, "PAGE_FETCHER_SERVICE_URL must be a valid HTTP/HTTPS URL"
      end
    rescue URI::InvalidURIError
      raise Exceptions::ConfigurationError, "PAGE_FETCHER_SERVICE_URL must be a valid URL"
    end
  end
end
```

`web-app/app/lib/page_fetcher/exceptions.rb`:

```ruby
# frozen_string_literal: true

module PageFetcher
  module Exceptions
    class Error < StandardError; end

    class ConfigurationError < Error; end

    class NetworkError < Error
      attr_reader :original_error

      def initialize(message, original_error = nil)
        super(message)
        @original_error = original_error
      end
    end

    class TimeoutError < NetworkError; end

    # A non-2xx answer from the service. `error_code` is its stable `error`
    # field (invalid_url, browser_error, ...) when the body carried one.
    class HttpError < Error
      attr_reader :status_code, :response_body, :error_code

      def initialize(message, status_code, response_body = nil, error_code: nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
        @error_code = error_code
      end
    end

    # 4xx: the caller asked for something the service will not fetch. Never
    # counts against the breaker.
    class ClientError < HttpError; end

    # 5xx meaning the service is unhealthy. Counts against the breaker.
    class ServerError < HttpError; end

    # 5xx describing the site, not the service (upstream_unreachable,
    # html_too_large). Never counts against the breaker: one dead publisher
    # domain must not stop fetches to every other site.
    class UpstreamError < HttpError; end

    class ParseError < Error
      attr_reader :response_body

      def initialize(message, response_body = nil)
        super(message)
        @response_body = response_body
      end
    end

    # Raised in place of the breaker's own Books::OpenLibrary one, so that
    # `rescue PageFetcher::Exceptions::Error` catches a tripped breaker too.
    class CircuitOpenError < Error; end
  end
end
```

`web-app/app/lib/page_fetcher/page.rb`:

```ruby
# frozen_string_literal: true

module PageFetcher
  # One fetched page (spec §2). `status` is the SITE's HTTP status: a 403 bot
  # wall is a successful fetch, and the caller's parser decides what it is.
  # `selector_found` is nil when no selector was asked for.
  class Page < Data.define(:url, :final_url, :status, :title, :html, :selector_found, :elapsed_ms, :fetched_at)
    # Raises KeyError for a missing field and ArgumentError for an unparseable
    # timestamp; the client turns both into Exceptions::ParseError.
    def self.from_response(body)
      new(
        url: body.fetch("url"),
        final_url: body.fetch("final_url"),
        status: body.fetch("status"),
        title: body.fetch("title"),
        html: body.fetch("html"),
        selector_found: body.fetch("selector_found"),
        elapsed_ms: body.fetch("elapsed_ms"),
        fetched_at: Time.iso8601(body.fetch("fetched_at"))
      )
    end

    # The HTML can be megabytes; it must never reach a log line through #inspect.
    def inspect
      "#<#{self.class.name} status=#{status} url=#{url.inspect} final_url=#{final_url.inspect} " \
        "title=#{title.inspect} html=(#{html.bytesize} bytes)>"
    end
    alias_method :to_s, :inspect
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `bin/rails test test/lib/page_fetcher/`
Expected: PASS.

Run: `CI=1 bin/rails zeitwerk:check`
Expected: it ends with `Otherwise, all is good!`. The warning above that line, about `test/mailers/previews`, is pre-existing. `eager_load` is off in the test environment, so a naming mistake in a new `app/lib` directory only shows up here.

- [ ] **Step 5: Lint and commit.**

Run: `bundle exec standardrb app/lib/page_fetcher test/lib/page_fetcher`
Expected: no offenses. Use `--fix` for layout-only complaints.

```bash
git add web-app/app/lib/page_fetcher web-app/test/lib/page_fetcher
git commit -m "Add PageFetcher configuration, exceptions and the Page value object

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: The Rails client, `.env.example` and final verification

**Files:**
- Create: `web-app/app/lib/page_fetcher/client.rb`
- Create: `web-app/test/lib/page_fetcher/client_test.rb`
- Modify: `.env.example` (project root, the Open Library block at lines 21–23)
- Modify: `docs/features/page-fetcher-service.md` (add a "Rails client" section)

**Interfaces:**
- Consumes: `PageFetcher::Configuration`, `Exceptions` and `Page` (Task 11); `Books::OpenLibrary::CircuitBreaker` and `Books::OpenLibrary::Exceptions::CircuitOpenError` (existing).
- Produces:
  - `PageFetcher::Client.new(config: nil, breaker: nil)`, with `#fetch(url, wait_until: "load", wait_for_selector: nil, timeout_ms: 30_000) -> PageFetcher::Page`.
  - Readers `config`, `breaker` and `connection`.
  - The constants `UPSTREAM_ERROR_CODES` and `READ_TIMEOUT_PADDING = 10`.

- [ ] **Step 1: Write the failing tests.** `web-app/test/lib/page_fetcher/client_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "ostruct"

module PageFetcher
  class ClientTest < ActiveSupport::TestCase
    BASE_URL = "http://page-fetcher.test:8081"
    FETCH_URL = "#{BASE_URL}/fetch"
    PAGE_URL = "https://www.goodreads.com/book/show/4671.The_Great_Gatsby"

    # WebMock cannot observe Faraday's per-request read timeout (a Net::HTTP
    # socket setting), so that test stubs the connection instead, as the Open
    # Library base client test does.
    class FakeFaradayRequest
      attr_accessor :headers, :body, :options

      def initialize
        @headers = {}
        @options = OpenStruct.new
      end
    end

    FakeFaradayResponse = Struct.new(:status, :body)

    def setup
      @config = PageFetcher::Configuration.new(base_url: BASE_URL)
      @breaker = Books::OpenLibrary::CircuitBreaker.new(
        key: "test:page_fetcher", failure_threshold: 5, cooldown: 60, redis: Books::OpenLibrary::FakeRedis.new
      )
      @client = PageFetcher::Client.new(config: @config, breaker: @breaker)
    end

    def page_body(**overrides)
      {
        url: PAGE_URL, final_url: PAGE_URL, status: 200, title: "The Great Gatsby",
        html: "<html>Gatsby</html>", selector_found: nil, elapsed_ms: 4120, fetched_at: "2026-09-26T18:02:11Z"
      }.merge(overrides).to_json
    end

    def error_body(code, detail = "what happened")
      {error: code, detail: detail}.to_json
    end

    test "a 200 returns the page" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      page = @client.fetch(PAGE_URL)

      assert_instance_of PageFetcher::Page, page
      assert_equal [200, "The Great Gatsby", "<html>Gatsby</html>"], [page.status, page.title, page.html]
      assert_equal Time.utc(2026, 9, 26, 18, 2, 11), page.fetched_at
    end

    test "posts the url, wait condition and timeout and omits a missing selector" do
      stub_request(:post, FETCH_URL)
        .with(body: {"url" => PAGE_URL, "wait_until" => "load", "timeout_ms" => 30_000},
          headers: {"Content-Type" => "application/json"})
        .to_return(status: 200, body: page_body)

      @client.fetch(PAGE_URL)

      # An exact body hash: a stray wait_for_selector key would not match the stub.
      assert_requested :post, FETCH_URL, times: 1
    end

    test "sends the selector when one is given and never a blank one" do
      stub_request(:post, FETCH_URL)
        .with(body: {"url" => PAGE_URL, "wait_until" => "networkidle", "wait_for_selector" => "h1", "timeout_ms" => 45_000})
        .to_return(status: 200, body: page_body(selector_found: true))

      assert @client.fetch(PAGE_URL, wait_until: "networkidle", wait_for_selector: "h1", timeout_ms: 45_000).selector_found

      blank_stub = stub_request(:post, FETCH_URL)
        .with(body: {"url" => PAGE_URL, "wait_until" => "load", "timeout_ms" => 30_000})
        .to_return(status: 200, body: page_body)

      @client.fetch(PAGE_URL, wait_for_selector: "")

      assert_requested blank_stub
    end

    test "sends the configured User-Agent and a JSON Accept header" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      @client.fetch(PAGE_URL)

      assert_requested :post, FETCH_URL, headers: {"User-Agent" => @config.user_agent, "Accept" => "application/json"}
    end

    test "an upstream 403 and a selector that never appeared are successful fetches" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body(status: 403, selector_found: false))

      page = @client.fetch(PAGE_URL, wait_for_selector: "h1")

      assert_equal [403, false], [page.status, page.selector_found]
    end

    test "a 422 raises ClientError and five of them leave the breaker closed" do
      stub_request(:post, FETCH_URL).to_return(status: 422, body: '{"detail":[{"loc":["body","wait"]}]}')

      6.times do
        error = assert_raises(PageFetcher::Exceptions::ClientError) { @client.fetch(PAGE_URL) }
        assert_equal 422, error.status_code
      end

      assert_not @breaker.open?
      assert_requested :post, FETCH_URL, times: 6
    end

    test "a 400 carries the service's error code" do
      stub_request(:post, FETCH_URL).to_return(status: 400, body: error_body("invalid_selector", "Unexpected token"))

      error = assert_raises(PageFetcher::Exceptions::ClientError) { @client.fetch(PAGE_URL, wait_for_selector: "div[[") }

      assert_equal "invalid_selector", error.error_code
      assert_match(/Unexpected token/, error.message)
    end

    test "upstream failures raise UpstreamError and never trip the breaker" do
      %w[upstream_unreachable html_too_large].each do |code|
        stub_request(:post, FETCH_URL).to_return(status: 502, body: error_body(code))

        6.times do
          error = assert_raises(PageFetcher::Exceptions::UpstreamError) { @client.fetch(PAGE_URL) }
          assert_equal code, error.error_code
        end

        assert_not @breaker.open?
      end
    end

    test "service failures raise ServerError" do
      {502 => "browser_error", 503 => "browser_unavailable", 504 => "navigation_timeout"}.each do |status, code|
        stub_request(:post, FETCH_URL).to_return(status: status, body: error_body(code))

        error = assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch(PAGE_URL) }

        assert_equal [status, code], [error.status_code, error.error_code]
        @breaker.reset!
      end
    end

    test "a 502 whose body is not the service's is a ServerError" do
      stub_request(:post, FETCH_URL).to_return(status: 502, body: "<html>Bad Gateway</html>")

      error = assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch(PAGE_URL) }

      assert_nil error.error_code
    end

    test "five browser errors open the circuit; the sixth call raises PageFetcher's CircuitOpenError and makes no request" do
      stub_request(:post, FETCH_URL).to_return(status: 502, body: error_body("browser_error"))

      5.times { assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch(PAGE_URL) } }
      assert @breaker.open?

      error = assert_raises(PageFetcher::Exceptions::CircuitOpenError) { @client.fetch(PAGE_URL) }

      assert_kind_of PageFetcher::Exceptions::Error, error
      assert_requested :post, FETCH_URL, times: 5
    end

    test "a timeout raises TimeoutError and counts against the breaker" do
      stub_request(:post, FETCH_URL).to_raise(Faraday::TimeoutError)

      5.times { assert_raises(PageFetcher::Exceptions::TimeoutError) { @client.fetch(PAGE_URL) } }

      assert @breaker.open?
    end

    test "a connection failure raises NetworkError" do
      stub_request(:post, FETCH_URL).to_raise(Faraday::ConnectionFailed)

      assert_raises(PageFetcher::Exceptions::NetworkError) { @client.fetch(PAGE_URL) }
    end

    test "an unparseable 200 raises ParseError and counts against the breaker" do
      # Five bodies, so the fifth ParseError is the one that opens the circuit.
      bodies = ["not json", "null", "[1, 2]", page_body.sub('"html"', '"body"'), page_body(fetched_at: "yesterday")]
      bodies.each do |body|
        stub_request(:post, FETCH_URL).to_return(status: 200, body: body)

        assert_raises(PageFetcher::Exceptions::ParseError) { @client.fetch(PAGE_URL) }
      end

      assert @breaker.open?
    end

    test "the read timeout is the budget plus the padding" do
      fake_request = FakeFaradayRequest.new
      @client.connection.expects(:post).with("/fetch").yields(fake_request).returns(FakeFaradayResponse.new(200, page_body))

      @client.fetch(PAGE_URL, timeout_ms: 45_000)

      assert_in_delta 55.0, fake_request.options.timeout
    end

    test "the connection uses the configured open timeout" do
      assert_equal 3, @client.connection.options.open_timeout
    end

    test "builds a default configuration and breaker when none is given" do
      client = PageFetcher::Client.new

      assert_instance_of PageFetcher::Configuration, client.config
      assert_instance_of Books::OpenLibrary::CircuitBreaker, client.breaker
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail.**

Run: `bin/rails test test/lib/page_fetcher/client_test.rb`
Expected: FAIL, `NameError: uninitialized constant PageFetcher::Client`.

- [ ] **Step 3: Implement.** `web-app/app/lib/page_fetcher/client.rb`:

```ruby
# frozen_string_literal: true

require "faraday"
require "json"

module PageFetcher
  # HTTP client for the page fetcher service in data-sources/ (spec:
  # docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md, §5).
  # One endpoint, so one class holds the HTTP, the breaker and the error
  # mapping. Nothing here knows a browser exists.
  class Client
    # Service error codes that describe the site, not the service (spec §2).
    UPSTREAM_ERROR_CODES = %w[upstream_unreachable html_too_large].freeze
    # The service answers within the fetch budget plus its 5 s browser-close
    # limit; the rest is margin, so Rails never abandons a fetch in progress.
    READ_TIMEOUT_PADDING = 10

    attr_reader :config, :breaker, :connection

    def initialize(config: nil, breaker: nil)
      @config = config || Configuration.new
      # Books::OpenLibrary::CircuitBreaker is generic (Redis-backed, keyed);
      # moving it to a shared namespace is a spec §12 carry-forward.
      @breaker = breaker || Books::OpenLibrary::CircuitBreaker.new(key: "page_fetcher", failure_threshold: 5, cooldown: 60)
      @connection = build_connection
    end

    # @return [PageFetcher::Page]
    # @raise [PageFetcher::Exceptions::Error] or a subclass, and nothing else
    def fetch(url, wait_until: "load", wait_for_selector: nil, timeout_ms: 30_000)
      body = {url: url, wait_until: wait_until, timeout_ms: timeout_ms}
      body[:wait_for_selector] = wait_for_selector if wait_for_selector.present?
      read_timeout = timeout_ms / 1000.0 + READ_TIMEOUT_PADDING

      outcome = nil
      breaker.call { outcome = classify(post(body, read_timeout)) }
      raise outcome[:error] if outcome[:error]

      outcome[:page]
    rescue Books::OpenLibrary::Exceptions::CircuitOpenError => e
      raise Exceptions::CircuitOpenError, e.message
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
    end

    private

    def build_connection
      Faraday.new(url: config.base_url) do |conn|
        conn.options.open_timeout = config.open_timeout
        conn.headers["User-Agent"] = config.user_agent
        conn.headers["Accept"] = "application/json"
        # bodies: false -- a response body is a whole page of HTML (spec §6).
        conn.response :logger, config.logger, bodies: false if config.logger
        conn.adapter Faraday.default_adapter
      end
    end

    def post(body, read_timeout)
      connection.post("/fetch") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = body.to_json
        req.options.timeout = read_timeout
      end
    end

    # Runs inside breaker.call. Raises what means "the service is unhealthy"
    # (a 5xx other than an upstream code, an unparseable body); returns
    # everything else, so a caller bug (4xx) or a dead site (UpstreamError)
    # finishes the block normally and never trips the breaker.
    def classify(response)
      case response.status
      when 200..299
        {page: parse_page(response.body)}
      when 400..499
        {error: http_error(Exceptions::ClientError, response)}
      when 500..599
        code, = error_fields(response.body)
        return {error: http_error(Exceptions::UpstreamError, response)} if UPSTREAM_ERROR_CODES.include?(code)

        raise http_error(Exceptions::ServerError, response)
      else
        raise Exceptions::HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
      end
    end

    def http_error(error_class, response)
      code, detail = error_fields(response.body)
      message = [code, detail].compact.join(": ").presence || "HTTP #{response.status}"
      error_class.new(message, response.status, response.body, error_code: code)
    end

    # The service's {"error": code, "detail": text} body (spec §2), or
    # [nil, nil] for anything else; FastAPI's 422 body has no "error" key.
    def error_fields(body)
      parsed = JSON.parse(body.to_s)
      return [nil, nil] unless parsed.is_a?(Hash)

      [parsed["error"], (parsed["detail"] if parsed["detail"].is_a?(String))]
    rescue JSON::ParserError
      [nil, nil]
    end

    def parse_page(body)
      parsed = JSON.parse(body)
      raise Exceptions::ParseError.new("The fetch response is not a JSON object", body) unless parsed.is_a?(Hash)

      Page.from_response(parsed)
    rescue JSON::ParserError, KeyError, ArgumentError => e
      raise Exceptions::ParseError.new("Failed to parse the fetch response: #{e.message}", body)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `bin/rails test test/lib/page_fetcher/`
Expected: PASS.

- [ ] **Step 5: Correct and extend `.env.example`.** In the project-root `.env.example`, replace:

```
# Open Library data service (data-sources/). Backend only -- never on a public
# request path. Runs on the headless home server behind the Cloudflare Tunnel.
OPEN_LIBRARY_SERVICE_URL=http://127.0.0.1:8080
```

with:

```
# Open Library data service (data-sources/). Backend only -- never on a public
# request path. Not deployed yet: it runs on the development machine until the
# headless home server and its Cloudflare Tunnel (with Cloudflare Access in
# front) are ready.
OPEN_LIBRARY_SERVICE_URL=http://127.0.0.1:8080

# Page fetcher service (data-sources/, docs/features/page-fetcher-service.md).
# Same posture and the same future home as the Open Library service above.
PAGE_FETCHER_SERVICE_URL=http://127.0.0.1:8081
```

- [ ] **Step 6: Document the client.** In `docs/features/page-fetcher-service.md`, add this section before "Measured":

````markdown
## Rails client

`PageFetcher::Client` (`web-app/app/lib/page_fetcher/`) posts to `/fetch` and
returns a `PageFetcher::Page`. Configure it with `PAGE_FETCHER_SERVICE_URL`
(default `http://127.0.0.1:8081`).

```ruby
page = PageFetcher::Client.new.fetch(
  "https://bookshop.org/book/9780743273565",
  wait_until: "networkidle",
  wait_for_selector: "h1",
  timeout_ms: 45_000
)
page.status          # the SITE's status: a 403 is still a successful fetch
page.selector_found  # false when the selector never appeared
page.html            # never logged, and never stored -- store what you parse
```

Every failure is a `PageFetcher::Exceptions::Error`:

| Raised | When | Counts against the breaker |
|---|---|---|
| `ClientError` | 400 or 422: a bad URL, selector or body (`error_code` says which) | no |
| `UpstreamError` | `upstream_unreachable`, `html_too_large` | no |
| `ServerError` | `browser_error`, `browser_unavailable`, `navigation_timeout`, any other 5xx | yes |
| `TimeoutError`, `NetworkError` | the service did not answer | yes |
| `ParseError` | a 200 that is not a fetch response | yes |
| `CircuitOpenError` | five counted failures in a row; 60 s cooldown | — |

The read timeout is `timeout_ms / 1000 + 10`, so the service always answers
first. The breaker is `Books::OpenLibrary::CircuitBreaker` under the key
`page_fetcher`.
````

- [ ] **Step 7: Full verification.** Every command must pass before the commit.

Run (from `web-app/`): `CI=1 bin/rails zeitwerk:check`
Expected: it ends with `Otherwise, all is good!`. The `test/mailers/previews` warning is pre-existing.

Run (from `web-app/`): `bin/rails test`
Expected: 0 failures, 0 errors, and no new warning lines. Known noise that predates this work: `weighted_list_rank`'s `puts`, yarn during `test:prepare`, and "The MultiJson constant is deprecated", which the Open Library tests print too.

Run (from `web-app/`): `bundle exec standardrb`
Expected: no offenses.

Run (from `data-sources/`): `uv sync --locked --extra fetcher && uv run pytest && uv run ruff check . && uv run ruff format --check .`
Expected: PASS and clean.

- [ ] **Step 8: Commit.**

```bash
git add web-app/app/lib/page_fetcher/client.rb web-app/test/lib/page_fetcher/client_test.rb \
  .env.example docs/features/page-fetcher-service.md
git commit -m "Add PageFetcher::Client with its own breaker key and upstream-error split

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
