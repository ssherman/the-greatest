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
  brings it back. A launch that runs out of budget counts toward the three
  only if it was given at least 10 s: one given less was starved of budget,
  not hung. The health check restarts nothing: Docker only restarts on exit.

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
| 422 | FastAPI's body | Unknown field, bad `wait_until`, `timeout_ms` outside 1000–`FETCHER_MAX_TIMEOUT_MS` (default 60000) |
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
| `ClientError` | any 4xx: a bad URL, selector or body (`error_code` says which) | no |
| `UpstreamError` | `upstream_unreachable`, `html_too_large` | no |
| `ServerError` | `browser_error`, `browser_unavailable`, `navigation_timeout`, any other 5xx | yes |
| `HttpError` | any other status (e.g. a 3xx -- Faraday does not follow redirects) | yes |
| `TimeoutError`, `NetworkError` | the service did not answer | yes |
| `ParseError` | a 200 that is not a fetch response | yes |
| `CircuitOpenError` | five counted failures in a row; 60 s cooldown | — |

The read timeout is `timeout_ms / 1000 + 10`, so the service always answers
first. The breaker is `Books::OpenLibrary::CircuitBreaker` under the key
`page_fetcher`.

## Measured

Launch cost in the built image (`CAMOUFOX_BROWSER=official/stable/152.0.4-beta.31`,
Camoufox 0.5.6), on the development machine, 2026-09-26:

| What | Seconds |
|---|---|
| Launch + first page, median of runs 2–6 | 0.94 |
| Launch + first page, run 1 (cold) | 1.25 |
| Goodreads book page, launch included | 6.15 (status 200, title "The Great Gatsby by F. Scott Fitzgerald \| Goodreads") |
| Goodreads book page, Task 10 smoke check | 7.55 (status 200, title "The Great Gatsby by F. Scott Fitzgerald \| Goodreads", `selector_found` true for `h1`) |
| bookshop.org book page, Task 10 smoke check | 2.19 (status 200, title "The Great Gatsby a book by F. Scott Fitzgerald - Bookshop.org US" -- the Cloudflare challenge cleared) |

The spec's per-fetch design (§3) holds while the median stays well under the
30-second default budget. Re-measure after any browser or package bump.

The built image (`docker images the-greatest/page-fetcher`) is about 3.7 GB on
disk (1.1 GB content), against the spec's "roughly 1GB" estimate; the browser
alone is about 1.2 GB.
