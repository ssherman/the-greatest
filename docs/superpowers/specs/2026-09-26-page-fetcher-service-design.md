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
- The service runs from the `data-sources/` compose file, bound to loopback, with its own image,
  memory limit and health check. Every fetch gets its own Firefox process, so a crash, hang or
  leak costs that one fetch and nothing else.
- `uv run pytest` covers the fetch logic and API without a browser; CI stays green without ever
  downloading Firefox.

Non-goals are in §10.

## Context

### Why a browser

The books AI enrichment framework (`2026-09-24-books-ai-enrichment-framework-design.md`) fills
unknown books through a `research` run that uses OpenAI web search at about 15 cents a book.
Goodreads pages hold genres, descriptions and edition data directly, and 96% of books carry a
Goodreads work ID (152,336 of 158,210 in the development database, 2026-09-26). No book carries
a bookshop.org identifier, but bookshop.org product pages are addressed by ISBN-13, and the
legacy database holds 76,688 AI-confirmed bookshop.org links (`books.primary_bookshop_org_url`)
that were never migrated. Importing those belongs to the bookshop.org spec, not this one.

Reading these pages costs nothing per page, but both sites reject plain HTTP clients.
bookshop.org sits behind Cloudflare bot protection. The legacy scraper drove plain Puppeteer with
stealth plugins that had stopped being updated; it failed on about 1% of searches from March 2025
to June 2026, and from July 2026 nearly every search came back empty. Camoufox spoofs a
consistent browser fingerprint at the C++ level, which is the standard answer to that class of
protection without paying for a hosted scraping API.

### Volume

Import-driven, one book at a time. The importer (`docs/features/data_importers.md`) runs when a
list adds books the site does not have, and each new book would trigger a handful of fetches.
Occasional backfills over a few thousand books are plausible; a pass over all 158k books is not
planned and is not designed for. That rules out a job queue, a proxy pool and multi-browser
scaling: a browser per fetch, a small concurrency cap and per-host spacing are enough.

### Camoufox in September 2026

Version 0.5.6 (PyPI, 2026-09-06), Python 3.10 or later. The original author stepped down in
January 2026 and Clover Labs maintains it now; the README warns that detection resistance fell
during a year-long maintenance gap.

**The Python package does not pin the browser.** `camoufox fetch` with no argument downloads the
newest stable build on GitHub that the package accepts (0.5.6 accepts anything from `beta.19`
up), so two image builds from one lockfile can ship different Firefoxes.
`camoufox fetch official/<version>-<build>` installs one named build, and that is what the image
uses (§4). The command also prints an error and exits 0 when a download fails, so the build has to
check the install itself.

Each browser process costs about 200MB idle and more per open page. True headless mode is more
detectable than a real display; Camoufox's `VirtualDisplay` runs Firefox under an Xvfb display it
manages itself. The project also offers a `camoufox server` websocket mode, rejected in §3.

### Where it runs

The Open Library service is not deployed anywhere yet. It was kept off the production web box on
2026-09-23 because of CPU, and the plan is a headless home server reached through a Cloudflare
Tunnel. That tunnel is being set up and is not ready. `.env.example` says the Open Library service
already runs there; that line describes the plan, and this work corrects it (§5).

The fetcher will run on the same home server: it is one compose file and one deploy story, and a
residential egress IP is treated far more kindly by Goodreads and bookshop.org than a datacenter
address. Until then it runs where Rails does, on a development machine. Nothing in the design
depends on the host, and the separate image means the fetcher can move to its own server later.

**Reaching either service from production is not this spec.** It belongs with the tunnel, and it
has one hard requirement. A tunnel hostname is public and neither service authenticates, so
Cloudflare Access (a service token Cloudflare checks before a request reaches the tunnel) must sit
in front of both hostnames before either goes live, and both Rails clients must send its headers.
For the Open Library API an open hostname leaks read-only book data; for the fetcher it would be
an open proxy on a home IP that runs any page's JavaScript.

## 1. Placement

**One uv project, two processes, two images.**

- Code lives in `data-sources/src/fetcher/`, a sibling of `src/openlibrary/`, sharing
  `pyproject.toml`, `uv.lock`, ruff, pytest and `src/common/` where useful. The hatch
  `packages` list gains `src/fetcher`. AGENTS.md already says Python lives in `data-sources/`;
  this adds a second source to a layout that was built for several.
- The fetcher is its own FastAPI process and its own Docker image. The Open Library API is a
  pure function of request plus a read-only artifact with an 8GB DuckDB budget; Firefox is
  memory-hungry and occasionally hangs. A browser failure must never take down book resolution,
  and the slim Open Library image must not grow by a gigabyte of Firefox, Xvfb and fonts.
- Camoufox is an optional extra, `fetcher = ["camoufox>=0.5.6,<0.6"]`, alongside the existing
  `calibration` extra, so the Open Library image never installs it. The `geoip` extra is not
  used. It looks up the egress IP's location to set the browser's timezone and locale, which
  matters when the IP moves, as it does behind a proxy. Here the IP is fixed, so the container's
  `TZ` is set to match it instead (§4).

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
| `wait_for_selector` | Optional CSS selector waited for after `wait_until`, for pages that render client-side or sit behind a challenge. The wait is for the element to be in the DOM (Playwright's `state="attached"`), not visible: the service returns HTML, and visibility depends on the stylesheets it blocks. If it never appears, the fetch still returns what the page holds, with `selector_found: false`. |
| `timeout_ms` | Default 30000, maximum 60000. The whole budget: waiting for a slot and for host spacing, launching the browser, navigation, the selector wait and reading the HTML all draw on it. The selector wait stops 2 seconds before the budget ends so the HTML can still be read. |

Response, `200`, on any completed navigation regardless of what the site answered:

```json
{
  "url": "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
  "final_url": "https://www.goodreads.com/book/show/4671.The_Great_Gatsby",
  "status": 200,
  "title": "The Great Gatsby by F. Scott Fitzgerald | Goodreads",
  "html": "<!DOCTYPE html>…",
  "selector_found": null,
  "elapsed_ms": 4120,
  "fetched_at": "2026-09-26T18:02:11Z"
}
```

`status` and `final_url` come from the **last main-frame document response when the fetch ends**,
not from the response `goto` returned. `selector_found` is `null` when no selector was requested.
A Goodreads 403 or a Cloudflare challenge interstitial is still a `200` from the service, with
`status: 403` and whatever HTML the browser rendered. The service reports what it saw and never
judges content: deciding "this is a bot wall, not a book page" belongs to the caller's parser,
which knows what a real page holds.

A Cloudflare managed challenge, which bookshop.org uses, serves a "Just a moment" page with a
403, runs its JavaScript for a few seconds and then navigates to the real page on its own. That
is why `status` must come from the last response: `goto`'s response is the interstitial's 403,
even when the real page arrives. `wait_until` alone returns the interstitial.
`wait_for_selector` is the tool for that case: Playwright's selector wait works across
navigations, so a caller that names an element only the real page has (a product title, say) gets
the real page with `selector_found: true`, or, if the challenge never clears, the interstitial
with `status: 403` and `selector_found: false`. The bookshop.org parser spec should pick that
selector; this service has no site-specific defaults.

Errors are JSON `{"error": "<code>", "detail": "<human text>"}` with a stable code:

| HTTP | `error` | When |
|---|---|---|
| 400 | `invalid_url` | Syntax, scheme or credentials fail, or an address rule in §6 fails |
| 400 | `invalid_selector` | `wait_for_selector` is not a selector Playwright can parse. A caller bug, so it must not count against the breaker the way a `browser_error` would. |
| 422 | (FastAPI's validation body) | Unknown field, bad enum, `timeout_ms` out of range |
| 502 | `upstream_unreachable` | The site could not be reached: the DNS lookup failed, the connection was refused or reset, or TLS failed |
| 502 | `html_too_large` | The document's HTML is over the cap (5MB) |
| 502 | `browser_error` | Playwright raised anything else, or navigation produced no document response |
| 503 | `browser_unavailable` | The browser failed to launch |
| 504 | `navigation_timeout` | The budget ran out before the page was read: waiting for a slot or host spacing, launching, loading, or reading the HTML. `detail` names the stage. A selector that never appears is not a timeout (see `selector_found`). |

`upstream_unreachable` and `html_too_large` describe the site, not the service. The split matters
to the Rails circuit breaker (§5): one dead publisher domain must not stop fetches to every other
site.

Inside every fetch a Playwright route aborts image, font, media and stylesheet requests. Only the
HTML matters, and blocking roughly halves page time. The same route runs the address check in §6
on every request it lets through.

### `GET /health`

```json
{
  "camoufox_version": "0.5.6",
  "browser_build": "official/…",
  "uptime_s": 86123,
  "fetches": {"ok": 412, "failed": 7, "in_flight": 1},
  "launch_failures_in_a_row": 0
}
```

`200` whenever the process answers. There is no browser state to report, because no browser
outlives a fetch. The compose health check turns a process that stops answering into `unhealthy`
in `docker ps`; it does not restart anything (§3).

There is no `/version`. The Open Library service's `/version` reports artifact provenance, which
the fetcher has none of; `/health` carries the versions.

## 3. Browser lifecycle and concurrency

**A browser per fetch.** Each fetch launches its own Firefox, opens one page, navigates, waits,
reads the HTML and title, and closes the browser in a `finally`. Nothing outlives a fetch, so
there is no restart counter, crash recovery or browser health state to manage, and cookies and
storage never carry between fetches.

**Shared for the life of the process**, because they are stable and cheap to keep:

- the Playwright driver (`async_playwright()`), started in the FastAPI lifespan;
- one Xvfb display (Camoufox's `VirtualDisplay`), so Firefox runs under a real display rather
  than true headless;
- the launch options, computed once at startup by Camoufox's `launch_options(...)` with
  `locale="en-US"`, `humanize=False`, `geoip=False` and the display, and passed to every launch.
  The options carry the generated fingerprint, so every fetch presents the same browser identity
  until the process restarts. No `os` or fingerprint options are pinned. A fresh fingerprint per
  fetch would look like a different computer on the same home IP every few seconds.

Uvicorn runs a single worker, since the driver, display and counters are per process.

**Launch cost.** The price of this design is one Firefox start per fetch. It is estimated at 1 to
3 seconds and has not been measured. At the volume in Context it does not matter. The plan's first
task measures it in the built image; only a launch that takes a large share of the 30-second
budget would reopen the decision.

Rejected: one long-lived browser with a fresh context per fetch. It saves the launch, but it needs
a restart counter against Firefox's slow leaks, crash detection and relaunch, deduplication when
two in-flight fetches see the same crash, a retry for the fetch a crash killed, draining in-flight
fetches before a planned restart, and hang detection. Most of that is timing-dependent and hard to
test. Camoufox's `camoufox server` websocket mode is the same long-lived browser behind a network
hop, rejected for the same reason.

**Concurrency and politeness.** Two environment settings:

| Setting | Default | Effect |
|---|---|---|
| `FETCHER_MAX_CONCURRENCY` | 2 | Browsers open at once across all hosts (an `asyncio.Semaphore`). This is also the memory bound. |
| `FETCHER_HOST_INTERVAL_MS` | 2000 | Minimum gap between the start of two fetches to the same host |

Slot acquisition uses `asyncio.wait_for` against the remaining budget, so a burst from a backfill
queues politely and every caller still gets a bounded answer. Host spacing is keyed on the
request URL's host (not the final URL) and tracked in memory; it is a courtesy, not a guarantee
across restarts.

**Failure handling.**

- A launch that fails returns `503 browser_unavailable` for that request; the next request tries
  again. A launch that runs out the budget is a `navigation_timeout` for the caller, and counts as
  a failed launch below only when the launch was given at least 10 seconds of budget: launch plus
  page takes about a second, so a launch given less was starved of budget, not hung, while one
  given 10 seconds or more and still not back is the likeliest sign of a dead driver.
- After `FETCHER_MAX_LAUNCH_FAILURES` (default 3) failed launches in a row, the process exits
  non-zero. That covers a dead Playwright driver or Xvfb, which retrying cannot fix. Compose's
  restart policy then brings the container back with a new driver, display and fingerprint. A
  successful launch resets the count.
- Closing the browser has a 5-second limit. A Firefox that will not close is a leaked process, so
  the service logs it and exits, and the restart clears it.

**Process supervision** is compose's job: `restart: unless-stopped`, a 2GB memory limit and
`shm_size: 1g` (Firefox needs a real `/dev/shm`). Docker restarts a container only when its
process exits. A failing health check marks it `unhealthy` and nothing more (only Swarm acts on
health), so every failure the service cannot recover from must end in the process exiting, as
above. If the kernel kills a Firefox for memory, that fetch fails with `browser_error`; if it
kills the service itself, the container restarts.

## 4. Image and compose

```
data-sources/
  Dockerfile              # the Open Library image, unchanged
  fetcher.Dockerfile      # new
  docker-compose.yml      # gains the fetcher service; api and build are untouched
```

`fetcher.Dockerfile`:

1. `FROM python:3.12-slim`, the same uv binary and lockfile-first layering as the Open Library
   image, but `uv sync --locked --no-dev --extra fetcher --no-install-project` then the source.
2. `apt-get install` Xvfb and Firefox's runtime libraries (GTK 3, dbus-glib, libXt, ALSA, a
   basic font set). The list is fixed in the Dockerfile, not discovered at runtime; the plan
   settles it by building the image and launching the browser in it.
3. Create a non-root user and switch to it. `ARG CAMOUFOX_BROWSER=official/<version>-<build>`
   names one browser build; the plan picks it (the newest stable build 0.5.6 accepts on the day).
   `python -m camoufox fetch "$CAMOUFOX_BROWSER"` installs it under that user's cache directory,
   and the same `RUN` checks that the browser is installed and fails the build if not, because
   `camoufox fetch` exits 0 on a failed download. The build arg is also set as an environment
   variable so `/health` can report it. The container never downloads anything at start.
4. `EXPOSE 8081`, `CMD uvicorn --factory fetcher.api.main:factory --host 0.0.0.0 --port 8081`.

Expect roughly 1GB. Upgrading the browser is a change to `CAMOUFOX_BROWSER`; upgrading the
package is a lockfile change. Either is followed by the smoke check in §9.

Compose service:

```yaml
fetcher:
  build:
    context: .
    dockerfile: fetcher.Dockerfile
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
    FETCHER_MAX_LAUNCH_FAILURES: "${FETCHER_MAX_LAUNCH_FAILURES:-3}"
    FETCHER_MAX_HTML_BYTES: "${FETCHER_MAX_HTML_BYTES:-5242880}"
    FETCHER_DEFAULT_TIMEOUT_MS: "${FETCHER_DEFAULT_TIMEOUT_MS:-30000}"
    FETCHER_MAX_TIMEOUT_MS: "${FETCHER_MAX_TIMEOUT_MS:-60000}"
    FETCHER_LOCALE: "${FETCHER_LOCALE:-en-US}"
    # Firefox takes its timezone from TZ. Without it the container is UTC,
    # which does not match a US residential IP with an en-US locale.
    # America/Chicago is the development machine's zone; set FETCHER_TZ to the
    # home server's zone if it differs.
    TZ: "${FETCHER_TZ:-America/Chicago}"
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
  Validated on construction. `.env.example` gains the variable next to
  `OPEN_LIBRARY_SERVICE_URL`, and the Open Library comment there is corrected to say the service
  is not deployed yet. `deployment/ENV.md` is untouched: neither service is in production.
- `Exceptions`: `Error`, `ConfigurationError`, `NetworkError`, `TimeoutError`, `HttpError`,
  `ClientError`, `ServerError`, `ParseError`, mirroring the Open Library module, plus
  `UpstreamError < Error` (carrying the service's `error` code) and `CircuitOpenError < Error`.
  The breaker raises `Books::OpenLibrary::Exceptions::CircuitOpenError`; the client rescues it and
  raises `PageFetcher::Exceptions::CircuitOpenError` instead, so `rescue
  PageFetcher::Exceptions::Error` catches every failure the client produces. A constant alias
  would not: its superclass is the Open Library `Error`.
- `Page`: an immutable value object with `url`, `final_url`, `status`, `title`, `html`,
  `selector_found`, `elapsed_ms` and `fetched_at`. It exists for the same reason the Open Library
  `Client` returns value objects: callers never come to depend on JSON key names.
- `Client#fetch(url, wait_until: "load", wait_for_selector: nil, timeout_ms: 30_000)` posts to
  `/fetch` and returns a `Page`. There is one endpoint, so one class holds the HTTP, breaker and
  error mapping; the Open Library `BaseClient`/`Client` split is not needed.

Rules:

- **Timeouts derive from the request.** Faraday's read timeout is `timeout_ms / 1000 + 10`: the
  budget, the browser's 5-second close limit (§3) and a margin, so the service always answers
  first and Rails never abandons a fetch the browser is still running.
- **Breaker.** Reuses `Books::OpenLibrary::CircuitBreaker` (it is generic: Redis-backed, keyed)
  with key `page_fetcher`, threshold 5, cooldown 60s. These raise from inside `breaker.call` and
  count: timeouts, network errors, unparseable bodies, and the service's `browser_error`,
  `browser_unavailable` and `navigation_timeout`. These raise outside the counted block and never
  trip it: a service `400` or `422` as `ClientError`, because that is a caller bug, exactly as the
  Open Library client treats 4xx; and `upstream_unreachable` or `html_too_large` as
  `UpstreamError`, because they describe one site. A `502` is classified by its `error` code; one
  whose body cannot be parsed is a `ServerError` and counts.
- **Upstream status is data.** A `200` whose `status` is 403 or 404, or whose `selector_found` is
  false, is a successful call. The caller decides.
- **No caching, no persistence.** A future parser stores what it extracts, never the HTML.

Because the client is generic and the service is loopback-only, nothing in Rails ever knows
Camoufox exists. Swapping the container for another fetcher changes no Ruby.

## 6. Security

- **Address checks.** Before launching, the service resolves the URL's host and rejects the
  request with `400 invalid_url` if any resolved address is loopback, private (RFC 1918),
  link-local, unique-local or otherwise non-global. A lookup that fails is
  `upstream_unreachable`. During the fetch, the route handler runs the same check on every request
  the page makes that it does not abort (documents, scripts, XHR), caching the answer per host for
  that fetch, and aborts any that fail.
- **What the route cannot see, and the backstop.** Playwright calls a route handler only for the
  first URL of a redirect chain, so an HTTP redirect to a private address is followed without the
  handler seeing it. Firefox also does its own DNS lookup after the check, so a hostname that
  answers differently the second time gets through. After navigation, the service therefore walks
  the redirect chain of every main-frame document response and, if any hop's host is non-public,
  discards the page and returns `400 invalid_url` naming the hop. The request to the private
  address has already gone out by then; what the check guarantees is that its response never
  comes back to the caller as the page. A subresource redirected to a private address is not
  caught. Both gaps are acceptable for a loopback service whose URLs come from our own jobs; a
  fetcher that will hit anything it is told to is still a footgun worth narrowing.
- **No authentication.** Same posture as the Open Library API: a private backend, never on a
  public request path. On one machine the compose bind address enforces that; behind a tunnel,
  Cloudflare Access must (Context).
- **Non-root container**, browser and Xvfb included.
- **Nothing sensitive in logs.** HTML is never logged.

## 7. Configuration

All settings are environment variables read once at startup into a frozen `Settings` object,
following `openlibrary.api.deps.Settings`:

| Variable | Default | Meaning |
|---|---|---|
| `FETCHER_MAX_CONCURRENCY` | `2` | Browsers open at once |
| `FETCHER_HOST_INTERVAL_MS` | `2000` | Per-host spacing |
| `FETCHER_MAX_LAUNCH_FAILURES` | `3` | Failed launches in a row before the process exits |
| `FETCHER_MAX_HTML_BYTES` | `5242880` | HTML size cap (5MB) |
| `FETCHER_DEFAULT_TIMEOUT_MS` | `30000` | Used when a request omits `timeout_ms` |
| `FETCHER_MAX_TIMEOUT_MS` | `60000` | Upper bound on `timeout_ms` |
| `FETCHER_LOCALE` | `en-US` | Browser locale |

An unparseable value fails startup with a `ConfigurationError` naming the variable. Two more
values reach the container but not `Settings`: `TZ`, which Firefox reads (§4), and
`CAMOUFOX_BROWSER`, baked in at build time and reported by `/health`.

## 8. Code layout

```
data-sources/src/fetcher/
  __init__.py          # __version__
  settings.py          # Settings.from_env()
  urlcheck.py          # scheme/credential/address validation, resolve-and-classify
  browser.py           # Browser protocol + CamoufoxBrowser: shared driver, display and
                       #   launch options; one browser per fetch
  limiter.py           # concurrency semaphore + per-host spacing, budget-aware acquire
  fetcher.py           # Fetcher: limiter, budget, launch-failure count, route and redirect
                       #   decisions, error mapping
  api/
    __init__.py
    main.py            # create_app(fetcher=None) / factory(); lifespan starts and stops
                       #   the shared driver and display
    schemas.py         # pydantic request/response models, extra="forbid"
    routes.py          # /fetch, /health
```

The `Browser` protocol is deliberately thin: launch a browser with a request filter, open a page,
navigate, wait for a selector, read the content and title, list the main-frame document responses
with their redirect chains, close. Every decision lives in `fetcher.py`, where a fake can
exercise it: which requests to abort, which response supplies `status`, whether a redirect hop was
private, and what a failure maps to.

`browser.py` is the only module that imports `camoufox` or `playwright`, and it imports them
lazily inside `CamoufoxBrowser`. It also translates Playwright's exceptions into the service's own
(`NavigationTimeout`, `UpstreamUnreachable`, `InvalidSelector`, `LaunchFailed`, `BrowserError`), so `fetcher.py`
never sees a Playwright type. Together these let every other module import without the extra
installed. `Fetcher` depends on the protocol, not the concrete class; that is what makes the
service testable without a browser and what would let a plain-HTTP or hosted backend slot in
later.

## 9. Testing and observability

**Python.** No test launches a browser. A `FakeBrowser` implementing the protocol records calls
and returns scripted results: HTML, a sequence of main-frame responses with redirect chains, a
raised timeout, a failed launch, a slow close. Against it:

- `urlcheck`: schemes, credentials, every private range, DNS resolving to a mix of public and
  private addresses, a lookup that fails (resolver injected).
- `limiter`: concurrency cap holds; per-host spacing enforced across hosts independently; a slot
  wait that exceeds the budget raises the timeout.
- `fetcher`: happy path shape; upstream 403 returned as data; `status` and `final_url` come from
  the last main-frame response (a scripted 403 interstitial followed by a 200 page returns 200); a
  selector that never appears returns 200 with `selector_found: false` and the HTML; a timeout at
  each stage maps to `navigation_timeout` naming the stage; a failed launch is
  `browser_unavailable`; three failed launches in a row call the exit hook (injected, never a
  real `sys.exit`) and a successful launch resets the count; a close over its limit calls the
  exit hook; the route filter aborts blocked resource types and private hosts; a redirect hop to a
  private address is `invalid_url` with no HTML returned; HTML over the cap is `html_too_large`;
  an unreachable host is `upstream_unreachable`; the browser is closed on every path.
- `browser`: exception translation against Playwright's real exception classes, without
  launching anything.
- `api` via FastAPI's test client with the fake injected through `create_app`: response shapes,
  `422` on an unknown field and an out-of-range timeout, `400` on a bad URL, each error body,
  `/health`.

These run in `uv run pytest` and in the existing CI job. CI's `uv sync --locked` becomes
`uv sync --locked --extra fetcher`, so the `browser` tests can import Playwright's exception
classes; the browser is never fetched. `test_packaging.py` gains the new package.

**Docker smoke check**, documented in a new `docs/features/page-fetcher-service.md` and run by
hand after any browser or package bump. Its first run is the plan's launch-time measurement.

```
docker compose up -d --build fetcher
curl -s localhost:8081/health
curl -s -X POST localhost:8081/fetch -H 'content-type: application/json' \
  -d '{"url":"https://www.goodreads.com/book/show/4671.The_Great_Gatsby"}' | head -c 400
```

It also fetches one bookshop.org product page with `wait_until: "networkidle"` and reads `status`
and `title`: a cleared challenge shows the book's title, an uncleared one "Just a moment". This
is the only place the real browser is exercised. There is deliberately no automated
real-browser test.

**Rails.** Minitest for `PageFetcher::Client` in the style of the Open Library client tests
(WebMock for responses, a `FakeRedis`-backed breaker): success returns a `Page`; upstream 403 and
`selector_found: false` are successes; `422` raises `ClientError` and leaves the breaker closed;
`upstream_unreachable` raises `UpstreamError` and leaves it closed; `browser_error` raises
`ServerError` and counts; a timeout raises `TimeoutError` and counts; five failures open the
circuit; an open circuit raises `PageFetcher::Exceptions::CircuitOpenError`, which
`rescue PageFetcher::Exceptions::Error` catches; Faraday's read timeout is derived from
`timeout_ms` (through a fake connection, as the Open Library base client test does, because
WebMock cannot observe it). `Configuration` tests mirror the Open Library ones.

**Observability.** One structured log line per fetch: host, upstream status, elapsed ms, launch
ms, outcome code, whether a slot wait occurred. `/health` carries the counters. No metrics stack
exists to feed, so nothing more.

## 10. Non-goals

- Parsing any site. Goodreads, bookshop.org and publisher parsers, and the importer providers or
  jobs that use them, are their own specs.
- Reaching the service from production. The tunnel, Cloudflare Access in front of it, and the
  Access headers in both Rails clients are their own work (Context).
- Proxies, proxy rotation, geolocation spoofing, or any handling of an IP ban beyond reporting the
  page the site served.
- A "plain HTTP first, browser as fallback" ladder. At this volume the browser cost is irrelevant,
  and recognising a bot wall served with a `200` is exactly what such a ladder gets wrong. Rails
  can fetch a friendly site directly with its own HTTP client.
- Caching or storing HTML anywhere.
- Screenshots, PDF rendering, form interaction, clicking, scrolling, or returning anything but the
  document's HTML.
- Authentication inside the service.
- A bulk backfill over the whole catalogue, and any throughput target above a few pages a minute.
- Running on the Linode production box. The service goes where the Open Library API runs.

## 11. Risks

- **Camoufox drift.** The project changed hands in January 2026 and its README says detection
  resistance dropped during the gap. Mitigations: the browser build is pinned by a build arg and
  the package by the lockfile; the `Browser` protocol isolates the dependency to one module; and
  the Docker smoke check is the regression test for a bump. If Camoufox stops working against
  Goodreads, the next candidates are another anti-detection browser behind the same protocol or a
  hosted fetching API behind the same Rails client.
- **bookshop.org's Cloudflare protection may still hold.** It defeated the legacy scraper's
  outdated Puppeteer stealth setup in July 2026. An up-to-date Camoufox plus a residential egress
  IP is the best available shot, and `wait_for_selector` covers the managed-challenge redirect
  (§2). If a challenge still fails to clear, the caller gets the interstitial with `status: 403`
  and `selector_found: false`, and the parser reports "no data", nothing more.
- **Launch cost is unmeasured.** The per-fetch design assumes a Firefox start of a few seconds.
  The plan measures it first (§3).
- **One fingerprint per process.** Between restarts every fetch presents the same identity with no
  cookies, like a browser that clears its cookies on every visit. If a site starts keying on that,
  computing launch options per fetch is a small change.
- **Memory on a shared host.** At most two browsers with one page each, typically 400 to 700MB.
  The 2GB compose limit bounds it; the Open Library API's own 8GB DuckDB budget is unaffected
  because they are separate containers.
- **Host spacing is in-memory.** A container restart forgets it. Acceptable for a courtesy delay
  at this volume.

## 12. Carry-forwards

- `Books::OpenLibrary::CircuitBreaker` is generic but namespaced under Open Library, and raises
  the Open Library `CircuitOpenError`, which this client has to translate. When a third client
  needs it, move it (and `CircuitOpenError`) to a shared namespace. Not done here to keep this
  change out of the Open Library code.
- The `data-sources/README.md` and its "Running the API" section are Open Library specific; they
  get a fetcher section in this work, and a later pass could split the README per source.
- If a plain-HTTP backend or a hosted API is ever wanted, it is a second `Browser` implementation
  selected by an `engine` field on `/fetch`, not a ladder inside the service.
- The bookshop.org spec should import the legacy database's 76,688 confirmed links
  (`books.primary_bookshop_org_url`, `https://bookshop.org/a/105133/<isbn13>`) before scraping
  anything.
- Production reach, with the tunnel: Cloudflare Access in front of both service hostnames, and the
  Access headers in both `Books::OpenLibrary::Configuration` and `PageFetcher::Configuration`.
