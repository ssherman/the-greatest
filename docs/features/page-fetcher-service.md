# Page Fetcher Service

Design: `docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md`
Plan: `docs/superpowers/plans/2026-09-26-page-fetcher-service.md`

URL in, rendered HTML out, for sites that reject plain HTTP clients (Goodreads,
bookshop.org, publisher pages). A second service in `data-sources/`, next to the
Open Library API, built on Camoufox, an anti-detection Firefox driven through
Playwright. It never parses pages: a caller's parser decides whether the HTML is
a book page or a bot wall. `POST /fetch_file` does the same for a public file
(a gzipped sitemap, XML, JSON) and returns its bytes.
Design: `docs/superpowers/specs/2026-11-16-page-fetcher-file-fetch-design.md`.

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
- **The concurrency cap is soft for a second or two.** A launch cancelled
  because its fetch's budget ran out keeps running in the background and is
  closed there once it lands, after its limiter slot has already been
  released -- so briefly, one extra Firefox can run alongside the fetch that
  took the freed slot. Bounded by the launch timeout (budget + 1 s) plus the
  5 s close limit.
- **A file fetch is page first, then a request from inside the page.** It
  launches its own browser (same request filter, same blocked resource types),
  loads a small page on the file's own site (`/robots.txt` by default), checks
  the page landed on the file's origin, then runs `fetch(url, {credentials:
  "include"})` inside that page and reads the body as a `Blob` through
  `FileReader.readAsDataURL`. The browser's own network stack makes the request,
  so the site sees an ordinary same-origin request. One file fetch takes one
  slot and counts as one start against the host interval, although it makes two
  requests to the host. The same one budget covers both.

## What the address checks do not cover

The pre-flight and in-page address checks (design spec §6) narrow SSRF risk;
they do not close it:

- **A subresource redirected to a private address is not caught** -- only the
  main-frame document's own redirect chain is re-checked after navigation.
- **DNS rebinding is narrowed, not closed** -- a host that resolves publicly
  at check time and privately moments later can still get through.
- **WebSockets, WebRTC and popups are invisible to the request route
  entirely.** A WebSocket has no CORS, so a hostile page's script can open one
  to a private service, read its replies, and forward them out. WebRTC can
  reach a private address outside the page's HTTP stack altogether. Popups
  are unchecked too: the route is scoped to one page, and it is unverified
  whether the profile even allows a popup to open. No in-page fix was taken
  for any of these -- a `window.WebSocket` wrapper, for instance, cannot be
  verified against Camoufox's isolated worlds, and installing one would
  itself be a fingerprinting signal.
- **A file fetch's redirect chain is checked the same way as a page's.** The
  session records the file request's response and its `redirected_from` chain,
  and every hop gets the address check afterwards, whether or not the request
  succeeded. A non-public hop is `400 invalid_url` (and wins over a network
  failure); a hop that no longer resolves, or a check that times out, is
  `502 upstream_unreachable`. Only the file request's own chain is covered:
  a subresource of the page load is no better covered than on `/fetch`.

The fix that actually closes all of the above is a network-level egress
block on the fetcher's network: drop destinations in RFC 1918,
loopback, link-local and CGNAT ranges, and allow DNS. The home server has
it; see "Where it runs".

## Where it runs

It is deployed to the home server's `fetcher` VM
(`docs/features/home-server.md`) and goes live behind Cloudflare Access, once
Access is in place and the tunnels are switched on. The network-level egress
block the address checks call for is in place there. It is enforced on the Proxmox host (`/etc/pve/firewall/120.fw`),
outside the VM, and also drops the house's own public IPv4, which the router
answers on itself. `provision --verify` tests it from inside both the VM and
the container. Development still runs it from `data-sources/`.

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

**Which wait to use.** Use the default `load`, and add `wait_for_selector` for
the element you are going to parse. Selectors need no ids: Playwright's
`td:has-text("EAN/UPC")`, `h1` or `xpath=//table` all work. Avoid
`networkidle`: it waits for `load` and then for 500 ms with nothing in flight,
and on ad-supported pages some blocked ad and analytics scripts never settle in
Playwright's view (bookshop.org: `gpt.js`, `gtm.js`), so it usually never
arrives and the fetch times out. Playwright's raw `networkidle` is worse: under
Firefox it can fire while a slowly streamed page is still arriving, which
returned half a bookshop.org page (`<head>` only) before the service started
waiting for `load` first.

| HTTP | `error` | When |
|---|---|---|
| 400 | `invalid_url` | Bad scheme, embedded credentials, or a non-public address the checks catch (see "What the address checks do not cover") |
| 400 | `invalid_selector` | `wait_for_selector` does not parse |
| 422 | FastAPI's body | Unknown field, bad `wait_until`, `timeout_ms` outside 1000–`FETCHER_MAX_TIMEOUT_MS` (default 60000) |
| 502 | `upstream_unreachable` | DNS, a refused/reset connection, TLS or its security level, a redirect loop, an empty/partial/corrupted response, a redirect hop that no longer resolves or could not be checked in time, or the page navigating itself (script or meta refresh) to a host that does not resolve |
| 502 | `html_too_large` | Over 5 MB of HTML |
| 502 | `browser_error` | Anything else the browser raised |
| 503 | `browser_unavailable` | The browser failed to launch |
| 504 | `navigation_timeout` | The budget ran out; `detail` names the stage |

`POST /fetch_file`:

    {"url": "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz",
     "page_url": null, "timeout_ms": 30000}

- `url` follows `/fetch`'s rules (`http` or `https`, no credentials, public
  addresses only).
- `page_url` is the page loaded before the file is requested. Default:
  `/robots.txt` on `url`'s origin. It must have the same origin as `url`, or the
  answer is `400 invalid_url`.
- `timeout_ms` has `/fetch`'s bounds and default. Unknown fields are a 422.

It returns `url`, `final_url` (after redirects, as the browser reports it for
that request), `status` (the site's status for the file request),
`content_type` (the `Content-Type` header, null if none), `body_base64`,
`size_bytes` (before base64), `elapsed_ms` and `fetched_at`.

- A `.gz` file arrives **still gzipped**: the browser removes only transport
  compression (`Content-Encoding`). The service never unzips.
- A site 403 or a challenge page is a 200 from the service with `status: 403`
  and the challenge page's bytes. The caller classifies it, as for pages.
- The status of the `page_url` load is not reported and does not matter: a 404
  for `/robots.txt` still gives the browser a document on the right origin.
- If the page load ends on a different origin from `url` (`/robots.txt` often
  redirects to another host), the in-page request would be cross-origin, so the
  answer is `400 invalid_url`, and `detail` names the origin it landed on. Pass
  a `page_url` on `url`'s origin, or request the file from the origin the site
  redirects to. A page load that turns into a download is also `400
  invalid_url` (`page_url` is not a displayable page): it must not reach the
  Rails breaker as a `browser_error`.

| HTTP | `error` | When, on `/fetch_file` |
|---|---|---|
| 400 | `invalid_url` | Bad `url` or `page_url`, a non-public address, `page_url` on another origin, the page load landing on another origin or becoming a download |
| 422 | FastAPI's body | Unknown field, `timeout_ms` out of bounds |
| 502 | `upstream_unreachable` | The page load could not reach the site, or the in-page request was rejected; `detail` says which stage |
| 502 | `file_too_large` | The body is over `FETCHER_MAX_FILE_BYTES`. Describes the site, not the service |
| 502 | `browser_error` | Anything else the browser raised, including a failure of the in-page script itself |
| 503 | `browser_unavailable` | The browser failed to launch |
| 504 | `navigation_timeout` | The budget ran out; the new stage is "downloading the file" |

`html_too_large` and `invalid_selector` cannot occur here.

**Why every rejected in-page request is `upstream_unreachable`.** Firefox
rejects a failed `fetch()` with one generic `TypeError: NetworkError when
attempting to fetch resource.`, with none of the `NS_ERROR_*` names the service
uses to recognise an unreachable site. It is the same error for a DNS or TLS
failure, a CORS block after a cross-origin redirect, and the service's own
request filter refusing the request, so they cannot be told apart and all
become `upstream_unreachable`. That includes a host that passed the pre-flight
check but resolved to a non-public address by request time: `/fetch` reports
that as `invalid_url` for a navigation, here it reads as `upstream_unreachable`.
The request is refused either way, and neither code counts against the Rails
breaker. The in-page script catches the rejection itself and returns it as
data, so it never surfaces as a failed `page.evaluate` (which would be a
`browser_error` and a breaker failure).

`GET /health` reports `camoufox_version`, `browser_build`, `uptime_s`,
`fetches` (`ok`, `failed`, `in_flight`) and `launch_failures_in_a_row`.

## Configuration

`FETCHER_MAX_CONCURRENCY` (2), `FETCHER_HOST_INTERVAL_MS` (2000),
`FETCHER_MAX_LAUNCH_FAILURES` (3), `FETCHER_MAX_HTML_BYTES` (5242880),
`FETCHER_MAX_FILE_BYTES` (10485760, minimum 1, counted on the body bytes before
base64), `FETCHER_DEFAULT_TIMEOUT_MS` (30000), `FETCHER_MAX_TIMEOUT_MS` (60000),
`FETCHER_LOCALE` (en-US). Compose also sets `TZ` from `FETCHER_TZ` (default
`America/Chicago`) so the browser's clock matches the egress IP, and
`FETCHER_BIND` (default `127.0.0.1`) for the published port. A bad value fails
startup naming the variable.

**What `FETCHER_MAX_FILE_BYTES` protects.** The cap is enforced inside the page,
before the bytes are encoded, so an oversized body is never copied into the
service or sent to Rails. It protects the browser only partly. A declared
`Content-Length` over the cap stops the request before the body is read. A body
with no `Content-Length`, or one sent with `Content-Encoding: gzip` that expands
past the cap, is read into the browser in full before `blob.size` is checked.
The container has a 2 GB memory limit and runs up to two fetches at once, and
encoding needs about 2.7 times the file's size inside the page, so a very large
or hostile file could get the container killed, taking the other fetch in flight
with it (compose restarts it). This is accepted: URLs come from our own jobs
and name known publisher files, and `timeout_ms` bounds how long a body can
keep arriving. A streaming read that aborts at the cap would close the gap, but
it handles `Uint8Array` chunks, the type that fails in Camoufox's isolated
world, so it is unproven. For scale: a Macmillan sitemap file is 15 KB, a
HarperCollins product sitemap about 500 KB, an uncompressed 25,000-URL sitemap
about 5 MB.

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

Also fetch a bookshop.org page with `"wait_for_selector":"td:has-text(\"EAN/UPC\")"`
and read the `title` and `selector_found`: "Just a moment…" with `status` 403
means Cloudflare's challenge did not clear.

Then fetch one file (`/fetch_file` needs the same running container):

    curl -s localhost:8081/fetch_file -H 'content-type: application/json' \
      -d '{"url":"https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz"}' -o ff.json
    python3 -I -c "
    import json,base64,gzip,re
    r=json.load(open('ff.json')); b=base64.b64decode(r.get('body_base64',''))
    print({k:v for k,v in r.items() if k!='body_base64'})
    print('gzip' if b[:2]==b'\x1f\x8b' else 'NOT GZIP', len(re.findall(rb'<loc>', gzip.decompress(b))) if b[:2]==b'\x1f\x8b' else b[:120])"

Expected: `status` 200, `gzip`, 1000 `<loc>` entries, `size_bytes` about 15,000.
A `status` of 403 with a "Just a moment" body means the page load had not
cleared the challenge: retry with `"page_url":"https://us.macmillan.com/"`.
Delete `ff.json` afterwards. A failure here after a Camoufox bump means in-page
`fetch()` broke; the download-event method (below) is the fallback.

## Rails client

`PageFetcher::Client` (`web-app/app/lib/page_fetcher/`) posts to `/fetch` and
returns a `PageFetcher::Page`; `fetch_file` posts to `/fetch_file` and returns a
`PageFetcher::FileResponse`. Both share one connection, one breaker and one error mapping. Configure it with `PAGE_FETCHER_SERVICE_URL`
(default `http://127.0.0.1:8081`).

```ruby
page = PageFetcher::Client.new.fetch(
  "https://bookshop.org/book/9780743273565",
  wait_for_selector: 'td:has-text("EAN/UPC")'  # an element on the real page
)
page.status          # the SITE's status: a 403 is still a successful fetch
page.selector_found  # false when the selector never appeared
page.html            # never logged; store what you parse (one exception below)
```

The one exception is Goodreads book pages. The Goodreads import keeps each page's HTML gzipped in
private storage, so a parser fix can re-read it without fetching again. These are public pages,
stored for internal parsing and never served (`docs/features/goodreads-import.md`, "Goodreads
verification").

```ruby
file = PageFetcher::Client.new.fetch_file(
  "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz",
  page_url: "https://us.macmillan.com/"  # optional: opened first, to pass the site's bot check
)
file.status         # the SITE's status, as on Page
file.content_type   # nil when the site sent none
file.body           # the bytes exactly as sent: a .gz arrives still gzipped
file.inflated       # the body unzipped when it starts with the gzip magic bytes, else the body;
                    # raises InflatedTooLargeError past `limit:` (default 100 MiB) bytes of output
```

`FileResponse` carries `url`, `final_url`, `status`, `content_type`, `body`, `elapsed_ms` and
`fetched_at`. The file body is never logged, never put on an exception and never stored by the
client. `fetch_file` does not pace or retry: both stay the caller's job, as for `fetch`.

Every failure is a `PageFetcher::Exceptions::Error`:

| Raised | When | Counts against the breaker |
|---|---|---|
| `ClientError` | any 4xx: a bad URL, selector or body (`error_code` says which) | no |
| `UpstreamError` | `upstream_unreachable`, `html_too_large`, `file_too_large` | no |
| `ServerError` | `browser_error`, `browser_unavailable`, `navigation_timeout`, any other 5xx | yes |
| `HttpError` | any other status (e.g. a 3xx -- Faraday does not follow redirects) | yes |
| `TimeoutError`, `NetworkError` | the service did not answer | yes |
| `ParseError` | a 200 that is not a fetch (or fetch_file) response | yes |
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

### File fetch

Measured on the development machine, 2026-11-17, through the built service
(Camoufox 0.5.6, browser build `official/stable/152.0.4-beta.31`). Bodies are
described by size and kind only.

| Request `url` | `status` | `final_url` | `size_bytes` | `elapsed_ms` | Body |
|---|---|---|---|---|---|
| `us.macmillan.com/sitemaps/sitemap-products.1.xml.gz` | 200 | same as `url` | 14943 | 2124 | gzip, 1000 `<loc>` entries |
| `https://US.Macmillan.com:443/sitemaps/sitemap-products.2.xml.gz` (spelled differently from how the browser writes it) | 200 | `https://us.macmillan.com/sitemaps/sitemap-products.2.xml.gz` | 14077 | 1603 | gzip, 1000 `<loc>` entries |
| `us.macmillan.com/sitemap.xml` (redirects on the same site) | 200 | `https://us.macmillan.com/sitemap_index.xml` | 13296 | 2297 | XML, starts `<?xml`, `content_type` `text/xml; charset=UTF-8` |
| `www.harpercollins.com/sitemap.xml` | 200 | same as `url` | 26830 | 2170 | XML, starts `<?xml`, `content_type` `application/xml; charset=utf-8` |

The first row's `content_type` was `application/octet-stream`. The default
`/robots.txt` page load cleared the challenge on every request, so no
`page_url` override was needed. The mixed-case URL matched the request the
service made, and the redirect case matched a redirected request, so neither
produced "the file request produced no recorded response". After these
requests `/fetch` was unharmed: Goodreads book 4671 with `wait_for_selector:
"h1"` returned `status` 200, `selector_found` true, 11099 ms.

The method choice, measured on 2026-11-16 against Macmillan's
`sitemap-products.69.xml.gz` and `.70.xml.gz` with a bare Camoufox page (the
service's route handler and blocked resource types were not in play):

| Method | Result |
|---|---|
| Playwright's `APIRequestContext` (`page.context.request.get(url)`) | **Blocked.** 403, body is Cloudflare's "Just a moment..." page. It does not go through Firefox's network stack. Do not re-try it. |
| Navigate to the file and catch the browser's download (`page.expect_download`) | Worked, with and without a page loaded first: 15,716 bytes, valid gzip, 1,000 `<loc>` entries. **The documented fallback** if in-page `fetch()` breaks. It fires only for content the browser will not display, so XML and JSON would need a second path. Not built. |
| In-page `fetch()` from a page on the same site, bytes read with `Blob` + `FileReader.readAsDataURL` | Worked: status 200, the same 15,716 bytes. **The method the service uses.** |
| The same `fetch()`, bytes read with `Uint8Array` + `String.fromCharCode.apply` + `btoa` | **Failed**: `Permission denied to access property "constructor"`. Camoufox runs `page.evaluate` in an isolated world and refuses a typed array across that boundary. |

Not measured: the in-page method against a site other than Macmillan and
HarperCollins; a first page load that itself lands on a challenge that takes a
moment to clear (the caller would see `status: 403` and retry); a page whose
Content Security Policy forbids `connect-src 'self'`.
