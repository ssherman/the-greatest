# Page fetcher service — design

Date: 2026-09-26 · Branch: `page-fetcher-spec`

## Goal

Give Rails a way to get the rendered HTML of a public web page from sites that block plain HTTP
clients, so book metadata (genres, descriptions, identifiers, buy links) can be read from
Goodreads, bookshop.org and publisher pages. The fetcher is a second process in `data-sources/`,
next to the Open Library service, built on [Camoufox](https://github.com/daijro/camoufox), an
anti-detection Firefox fork driven through Playwright.

Success:

- `POST /fetch` with a Goodreads book URL returns that page's HTML, the upstream HTTP status and
  the final URL after redirects, in a few seconds, with no proxy and no site-specific code.
- Rails has a `PageFetcher::Client` that calls it with the same timeout and circuit-breaker
  discipline as the Open Library client, and a Sidekiq job can depend on it without knowing that
  a browser exists.
- The service runs from the `data-sources/` compose file on the same host as the Open Library
  API, bound to loopback, with its own image, memory limit and health check, and a browser crash
  or leak restarts the container rather than affecting anything else.
- `uv run pytest` covers the fetch logic and API without a browser; CI stays green without ever
  downloading Firefox.

Non-goals are in §10.

## Context

### Why a browser

The books AI enrichment framework (`2026-09-24-books-ai-enrichment-framework-design.md`) fills
unknown books through a `research` run that uses OpenAI web search at about 15 cents a book. Most
books already carry Goodreads and bookshop.org identifiers, and those pages hold genres,
descriptions and edition data directly. Reading them costs nothing per page but both sites reject
plain HTTP clients: the enrichment spec records that bookshop.org blocked the legacy scraper
outright. Camoufox spoofs a consistent browser fingerprint at the C++ level, which is the
standard answer to that class of blocking without paying for a hosted scraping API.

### Volume

Import-driven, one book at a time. The importer (`docs/features/data_importers.md`) runs when a
list adds books the site does not have, and each new book would trigger a handful of fetches.
Occasional backfills over a few thousand books are plausible; a pass over all 157k books is not
planned and is not designed for. That rules out a job queue, a proxy pool and multi-browser
scaling: one long-lived browser with a small concurrency cap and per-host spacing is enough.

### Camoufox in September 2026

Version 0.5.6 (PyPI, 2026-09-06), Python 3.10 to 3.14. The original author stepped down in
January 2026 and Clover Labs maintains it now; the README warns that detection resistance fell
during a year-long maintenance gap. The Python package pins the Firefox build it downloads, so
pinning the package pins the browser. Each browser process costs about 200MB idle and more per
open page. True headless mode is more detectable than a real display; the package's
`headless="virtual"` runs Firefox under an Xvfb display it manages itself. The project offers a
`camoufox server` websocket mode, considered and rejected in §3.

### Where the Open Library service actually runs

`.env.example` says the Open Library service runs on the headless home server behind the
Cloudflare Tunnel, not on the Linode production box. The fetcher goes on the same host for three
reasons: it is one compose file and one deploy story; Rails already reaches that host; and a
residential egress IP is treated far more kindly by Goodreads and bookshop.org than a datacenter
address. Nothing in the design depends on this, and the separate image means it can move to its
own server later.

## 1. Placement

**One uv project, two processes, two images.**

- Code lives in `data-sources/src/fetcher/`, a sibling of `src/openlibrary/`, sharing
  `pyproject.toml`, `uv.lock`, ruff, pytest and `src/common/` where useful. AGENTS.md already
  says Python lives in `data-sources/`; this adds a second source to a layout that was built for
  several.
- The fetcher is its own FastAPI process and its own Docker image. The Open Library API is a
  pure function of request plus a read-only artifact with an 8GB DuckDB budget; a Firefox process
  is stateful, memory-hungry and occasionally hangs. A browser crash must never take down book
  resolution, and the slim Open Library image must not grow by a gigabyte of Firefox, Xvfb and
  fonts.
- Camoufox is an optional extra, `fetcher = ["camoufox>=0.5.6,<0.6"]`, alongside the existing
  `calibration` extra, so the Open Library image never installs it. The `geoip` extra is not
  used: it only matters with a proxy.

Rejected: a separate repository. The tool is generic (URL in, HTML out, no site logic), so
open-sourcing it inside the-greatest costs nothing, and a second repo would need its own CI,
registry and version to track.

## 2. API contract

The service is a pure function of the request: no cache, no state between calls, strict bodies.
Unknown fields are a 422 naming the field, the same rule as `/resolve`.

### `POST /fetch`

Request:

```json
{
  "url": "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
  "wait_until": "load",
  "wait_for_selector": null,
  "timeout_ms": 30000
}
```

| Field | Rules |
|---|---|
| `url` | Required. `http` or `https`, no embedded credentials, host must resolve only to public addresses (see §6). |
| `wait_until` | `domcontentloaded`, `load` (default) or `networkidle`. Passed straight to Playwright. |
| `wait_for_selector` | Optional CSS selector waited for after `wait_until`, for pages that render client-side. |
| `timeout_ms` | Default 30000, maximum 60000. The whole budget: waiting for a browser slot, navigation, selector wait and HTML extraction all draw on it. |

Response, `200`, on any completed navigation regardless of what the site answered:

```json
{
  "url": "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
  "final_url": "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
  "status": 200,
  "title": "The Great Gatsby by F. Scott Fitzgerald | Goodreads",
  "html": "<!DOCTYPE html>…",
  "elapsed_ms": 4120,
  "fetched_at": "2026-09-26T18:02:11Z"
}
```

`status` is the HTTP status of the main document response. A Goodreads 403 or a captcha
interstitial is still a `200` from the service with `status: 403` (or `200`) and whatever HTML
the browser rendered. The service reports what it saw and never judges content: deciding "this is
a bot wall, not a book page" belongs to the caller's parser, which knows what a real page holds.

Errors are JSON `{"error": "<code>", "detail": "<human text>"}` with a stable code:

| HTTP | `error` | When |
|---|---|---|
| 400 | `invalid_url` | Scheme, credentials or address rules in §6 fail |
| 422 | (FastAPI's validation body) | Unknown field, bad enum, `timeout_ms` out of range |
| 502 | `browser_error` | Playwright raised anything other than a timeout; HTML over the 5MB cap; navigation produced no document response |
| 503 | `browser_unavailable` | The browser is not running and the relaunch failed |
| 504 | `navigation_timeout` | The budget ran out at any stage |

Inside every fetch the browser aborts image, font, media and stylesheet requests via a Playwright
route. Only the HTML matters, and blocking roughly halves page time.

### `GET /health`

```json
{
  "browser": "running",
  "browser_generation": 3,
  "camoufox_version": "0.5.6",
  "firefox_version": "…",
  "uptime_s": 86123,
  "fetches": {"ok": 412, "failed": 7, "in_flight": 1}
}
```

`browser` is `running`, `relaunching` or `failed`. The compose health check calls this endpoint
and treats anything but a `200` as unhealthy; `failed` returns `503`.

### `GET /version`

Package version and git SHA if available, matching the Open Library service's endpoint shape.

## 3. Browser lifecycle and concurrency

**One browser per process.** On startup the service launches one `AsyncCamoufox` with
`headless="virtual"`, `block_images=True`, `locale="en-US"`, `humanize=False`, `geoip=False`.
Uvicorn runs a single worker; a worker per browser is the only sane mapping and one browser is
enough for the volume in Context. Camoufox picks a fresh fingerprint per launch; no `os` or
fingerprint options are pinned.

**One isolated context per fetch.** Each request opens a new browser context, a page in it,
navigates, waits, reads `page.content()`, and closes the context in a `finally`. Cookies and
storage never carry between fetches.

**Concurrency and politeness.** Two environment settings:

| Setting | Default | Effect |
|---|---|---|
| `FETCHER_MAX_CONCURRENCY` | 2 | Pages open at once across all hosts (an `asyncio.Semaphore`) |
| `FETCHER_HOST_INTERVAL_MS` | 2000 | Minimum gap between the start of two fetches to the same host |

Slot acquisition uses `asyncio.wait_for` against the remaining budget, so a burst from a backfill
queues politely and every caller still gets a bounded answer. Host spacing is keyed on the
request URL's host (not the final URL) and tracked in memory; it is a courtesy, not a guarantee
across restarts.

**Recycling.** `FETCHER_BROWSER_MAX_FETCHES` (default 200): after that many fetches the browser is
closed and relaunched, because Firefox leaks slowly. Any Playwright error whose message says the
browser or target is closed or crashed triggers the same relaunch. Relaunch runs under a lock;
requests arriving during it wait inside their own budget; `browser_generation` in `/health`
increments. Only a launch that itself fails yields `503 browser_unavailable`, and the service
retries the launch on the next request rather than exiting, so compose's restart policy is the
last resort, not the first.

**Process supervision** is compose's job: `restart: unless-stopped`, the `/health` check, a 2GB
memory limit and `shm_size: 1g` (Firefox needs a real `/dev/shm`). A leak or wedge restarts the
container instead of starving the host.

## 4. Image and compose

```
data-sources/
  docker/
    openlibrary.Dockerfile    # the existing Dockerfile, moved, contents unchanged
    fetcher.Dockerfile
  docker-compose.yml          # gains the fetcher service; api's build context updated
```

`fetcher.Dockerfile`:

1. `FROM python:3.12-slim`, the same uv binary and lockfile-first layering as the Open Library
   image, but `uv sync --locked --no-dev --extra fetcher --no-install-project` then the source.
2. `apt-get install` Xvfb and Firefox's runtime libraries (GTK 3, dbus-glib, libXt, ALSA, a
   basic font set). The exact package list comes from Camoufox's own Docker example and is fixed
   in the Dockerfile, not discovered at runtime.
3. Create a non-root user, switch to it, and run `python -m camoufox fetch` so the browser is
   baked into the image under that user's cache directory. The container never downloads
   anything at start.
4. `EXPOSE 8081`, `CMD uvicorn --factory fetcher.api.main:factory --host 0.0.0.0 --port 8081`.

Expect roughly 1GB. A Camoufox version bump is a lockfile change plus an image rebuild.

Compose service:

```yaml
fetcher:
  build:
    context: .
    dockerfile: docker/fetcher.Dockerfile
  image: the-greatest/page-fetcher:latest
  restart: unless-stopped
  ports:
    - "${FETCHER_BIND:-127.0.0.1}:8081:8081"
  shm_size: 1g
  mem_limit: 2g
  environment:
    # Every variable in section 7, forwarded with its default. Compose does not
    # pass through a host variable that is not listed here.
    FETCHER_MAX_CONCURRENCY: "${FETCHER_MAX_CONCURRENCY:-2}"
    FETCHER_HOST_INTERVAL_MS: "${FETCHER_HOST_INTERVAL_MS:-2000}"
    FETCHER_BROWSER_MAX_FETCHES: "${FETCHER_BROWSER_MAX_FETCHES:-200}"
    # ... and the remaining four from section 7
  healthcheck:
    test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8081/health').status == 200 else 1)"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 30s
```

The same loopback rule as `api` applies: `FETCHER_BIND=0.0.0.0` only where Rails is not on the
host, and never on a public request path.

## 5. Rails client

Scope: a thin client only. Parsing Goodreads or bookshop.org pages, and any importer provider or
job that uses them, is separate work that lands with the fields it fills (the enrichment spec
already parks Goodreads as its own spec). This client is what those pieces will call.

`web-app/app/lib/page_fetcher/`, a top-level namespace like `Cloudflare::` and `Viaf::` because
the service is not book-specific:

- `Configuration`: `PAGE_FETCHER_SERVICE_URL` (default `http://127.0.0.1:8081`, same
  127.0.0.1-not-localhost reasoning as the Open Library one), `open_timeout` 3s, user agent.
  Validated on construction; `.env.example` and `deployment/ENV.md` gain the variable next to
  `OPEN_LIBRARY_SERVICE_URL`.
- `Exceptions`: `Error`, `ConfigurationError`, `NetworkError`, `TimeoutError`, `HttpError`,
  `ClientError`, `ServerError`, `ParseError`, mirroring the Open Library module.
  `CircuitOpenError` is `Books::OpenLibrary::Exceptions::CircuitOpenError` itself (a constant
  alias), because the breaker below raises that class.
- `Client#fetch(url, wait_until: "load", wait_for_selector: nil, timeout_ms: 30_000)` posts to
  `/fetch` and returns `{success: true, data: {html:, status:, final_url:, title:, elapsed_ms:},
  errors: [], metadata: {}}` on a `200`.

Rules:

- **Timeouts derive from the request.** Faraday's read timeout is `timeout_ms / 1000 + 5`, so
  the service always answers first and Rails never abandons a fetch the browser is still
  running.
- **Breaker.** Reuses `Books::OpenLibrary::CircuitBreaker` (it is generic: Redis-backed, keyed)
  with key `page_fetcher`, threshold 5, cooldown 60s. Timeouts, network errors, unparseable
  bodies and service 5xx (`502`, `503`, `504`) raise from inside `breaker.call` and count. A
  service `400` or `422` is a caller bug: it raises `ClientError` outside the counted block and
  never trips the breaker, exactly as the Open Library client treats 4xx.
- **Upstream status is data.** A `200` whose `status` is 403 or 404 is a successful call. The
  caller decides.
- **No caching, no persistence.** A future parser stores what it extracts, never the HTML.

Because the client is generic and the service is loopback-only, nothing in Rails ever knows
Camoufox exists. Swapping the container for another fetcher changes no Ruby.

## 6. Security

- **Private-address guard.** Before navigating, the service resolves the URL's host and rejects
  the request with `400 invalid_url` if any resolved address is loopback, private (RFC 1918),
  link-local, unique-local or otherwise non-global. The same check runs in the Playwright route
  handler for document requests, so a redirect to `http://redis:6379` or a metadata endpoint is
  aborted rather than followed. The service is loopback-only, but a fetcher that will hit anything
  it is told to is a footgun worth closing.
- **No authentication.** Same posture as the Open Library API: private backend on trusted
  infrastructure, never on a public request path, enforced by the compose bind address.
- **Non-root container**, browser and Xvfb included.
- **Nothing sensitive in logs.** HTML is never logged.

## 7. Configuration

All settings are environment variables read once at startup into a frozen `Settings` object,
following `openlibrary.api.deps.Settings`:

| Variable | Default | Meaning |
|---|---|---|
| `FETCHER_MAX_CONCURRENCY` | `2` | Concurrent pages |
| `FETCHER_HOST_INTERVAL_MS` | `2000` | Per-host spacing |
| `FETCHER_BROWSER_MAX_FETCHES` | `200` | Fetches before a planned relaunch |
| `FETCHER_MAX_HTML_BYTES` | `5242880` | HTML size cap (5MB) |
| `FETCHER_DEFAULT_TIMEOUT_MS` | `30000` | Used when a request omits `timeout_ms` |
| `FETCHER_MAX_TIMEOUT_MS` | `60000` | Upper bound on `timeout_ms` |
| `FETCHER_LOCALE` | `en-US` | Browser locale |

An unparseable value fails startup with a `ConfigurationError` naming the variable.

## 8. Code layout

```
data-sources/src/fetcher/
  __init__.py
  settings.py          # Settings.from_env()
  urlcheck.py          # scheme/credential/address validation, resolve-and-classify
  browser.py           # Browser protocol + CamoufoxBrowser: launch, new_context, close, is_alive
  limiter.py           # concurrency semaphore + per-host spacing, budget-aware acquire
  fetcher.py           # Fetcher: orchestrates limiter, browser, page, recycle, error mapping
  api/
    __init__.py
    main.py            # create_app(fetcher=None) / factory(), lifespan launches and closes
    schemas.py         # pydantic request/response models, extra="forbid"
    routes.py          # /fetch, /health, /version
```

`browser.py` is the only module that imports `camoufox` or `playwright`, and it imports them
lazily inside `CamoufoxBrowser` so every other module imports without the extra installed.
`Fetcher` depends on the `Browser` protocol, not the concrete class; that is what makes the
service testable without a browser and what would let a plain-HTTP or hosted backend slot in
later.

## 9. Testing and observability

**Python.** No test launches a browser. A `FakeBrowser` implementing the protocol records calls
and returns scripted results (HTML, status, final URL, a raised timeout, a raised "target
closed", a slow response). Against it:

- `urlcheck`: schemes, credentials, every private range, DNS resolving to a mix of public and
  private addresses (resolver injected).
- `limiter`: concurrency cap holds; per-host spacing enforced across hosts independently; a slot
  wait that exceeds the budget raises the timeout.
- `fetcher`: happy path shape; upstream 403 returned as data; timeout at each stage maps to
  `navigation_timeout`; "target closed" triggers relaunch and the request is retried once on the
  new generation; recycle after N fetches; HTML over the cap is `browser_error`; a failed relaunch
  is `browser_unavailable`; the context is closed on every path.
- `api` via FastAPI's test client with the fake injected through `create_app`: response shapes,
  `422` on an unknown field and an out-of-range timeout, `400` on a bad URL, `/health` in each
  browser state.

These run in `uv run pytest` and in the existing CI job. CI's `uv sync --locked` becomes
`uv sync --locked --extra fetcher` so the extra's modules import; the browser is never fetched.
`test_packaging.py` gains the new package.

**Docker smoke check**, documented in the feature doc and run by hand after any Camoufox bump:

```
docker compose up -d --build fetcher
curl -s localhost:8081/health
curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' \
  -d '{"url":"https://www.goodreads.com/book/show/4671.The_Great_Gatsby"}' | head -c 400
```

This is the only place the real browser is exercised. There is deliberately no automated
real-browser test.

**Rails.** Minitest for `PageFetcher::Client` in the style of the Open Library client tests
(WebMock for responses, a `FakeRedis`-backed breaker): success returns data; upstream 403 is
success; `422` raises `ClientError` and leaves the breaker closed; a timeout raises
`TimeoutError` and counts; five failures open the circuit; Faraday's timeout is derived from
`timeout_ms`. `Configuration` tests mirror the Open Library ones.

**Observability.** One structured log line per fetch: host, upstream status, elapsed ms, outcome
code, browser generation, whether a slot wait occurred. `/health` carries the counters. No metrics
stack exists to feed, so nothing more.

## 10. Non-goals

- Parsing any site. Goodreads, bookshop.org and publisher parsers, and the importer providers or
  jobs that use them, are their own specs.
- Proxies, proxy rotation, geolocation spoofing, or any handling of an IP ban beyond reporting the
  page the site served.
- A "plain HTTP first, browser as fallback" ladder. At this volume the browser cost is irrelevant,
  and recognising a bot wall served with a `200` is exactly what such a ladder gets wrong. Rails
  can fetch a friendly site directly with its own HTTP client.
- Caching or storing HTML anywhere.
- Screenshots, PDF rendering, form interaction, clicking, scrolling, or returning anything but the
  document's HTML.
- Authentication on the service, or exposing it beyond loopback.
- A bulk backfill over the whole catalogue, and any throughput target above a few pages a minute.
- Running on the Linode production box. The service goes where the Open Library API runs.

## 11. Risks

- **Camoufox drift.** The project changed hands in January 2026 and its README says detection
  resistance dropped during the gap. Mitigations: the browser is pinned by package version; the
  `Browser` protocol isolates the dependency to one module; and the Docker smoke check is the
  regression test for a bump. If Camoufox stops working against Goodreads, the next candidates are
  another anti-detection browser behind the same protocol or a hosted fetching API behind the
  same Rails client.
- **bookshop.org may still block.** It blocked the legacy scraper. Camoufox plus a residential
  egress IP is the best available shot; if it fails, the caller sees the blocked page's HTML and
  status and the parser reports "no data", nothing more.
- **Memory on a shared host.** One browser with two pages is typically 400 to 700MB. The 2GB
  compose limit and the recycle counter bound it; the Open Library API's own 8GB DuckDB budget is
  unaffected because they are separate containers.
- **Host spacing is in-memory.** A container restart forgets it. Acceptable for a courtesy delay
  at this volume.

## 12. Carry-forwards

- `Books::OpenLibrary::CircuitBreaker` is generic but namespaced under Open Library. When a third
  client needs it, move it (and `CircuitOpenError`) to a shared namespace. Not done here to keep
  this change out of the Open Library code.
- The `data-sources/README.md` and its "Running the API" section are Open Library specific; they
  get a fetcher section in this work, and a later pass could split the README per source.
- If a plain-HTTP backend or a hosted API is ever wanted, it is a second `Browser` implementation
  selected by an `engine` field on `/fetch`, not a ladder inside the service.
