# Page fetcher file fetch — design

Date: 2026-11-16 · Branch: `worktree-page-fetcher-file-fetch`

Extends `2026-09-26-page-fetcher-service-design.md` ("the service spec"). Section references such
as "service spec §6" point there. Everything in that spec still holds unless this document says
otherwise.

## Goal

Give Rails a way to get the **raw bytes of a public file** from a site that blocks plain HTTP
clients. Today the page fetcher only returns the rendered HTML of a page. That cannot carry a
gzipped sitemap, and it carries XML and JSON only as whatever HTML the browser's viewer wraps
them in.

Success:

- `POST /fetch_file` with the URL of a Macmillan sitemap file
  (`https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz`) returns that file's bytes, the
  site's HTTP status, the content type and the final URL, in a few seconds.
- Rails has `PageFetcher::Client#fetch_file`, with the same timeout, circuit-breaker and error
  discipline as `#fetch`, returning a value object that holds the bytes.
- `POST /fetch`, its response and every existing caller are unchanged.
- `uv run pytest` covers the new path with the fake browser; CI still never downloads Firefox.

## Why

The next project is a weekly intake of new and upcoming books from publishers' own sites (its
design follows this one). Three of the five largest publishers can only be discovered by reading
sitemap files and comparing the list of ISBNs week to week, and two of those sit behind a bot
wall:

| Publisher | Discovery source | Reachable by plain HTTP? |
|---|---|---|
| Macmillan US | 70 files `sitemaps/sitemap-products.N.xml.gz`, 1,000 book URLs each | No. Cloudflare challenge. |
| HarperCollins | 73 files `sitemap_products_N.xml?from=…&to=…`, 1,000 products each; also Shopify `.js` product JSON | No. Cloudflare challenge. |
| Simon & Schuster | `sitemaps/us/sitemapN.xml.gz`, 25,000 book URLs each | Yes. Does not need this feature. |

Measured on 2026-11-16 from the development machine.

## What was measured

A throwaway script ran inside the fetcher container against Macmillan's
`sitemap-products.69.xml.gz` and `sitemap-products.70.xml.gz`, using Camoufox launched the way
the service launches it.

| Method | Result |
|---|---|
| Playwright's `APIRequestContext` (`page.context.request.get(url)`) | **Blocked.** 403, body is Cloudflare's "Just a moment..." page. This request does not go through Firefox's network stack. |
| Navigate to the file and catch the browser's download (`page.expect_download`) | Worked, with and without a page loaded first. 15,716 bytes, valid gzip, 1,000 `<loc>` entries. |
| `fetch()` run inside a page already loaded from the same site (`/robots.txt`), bytes read with `Blob` + `FileReader.readAsDataURL` | Worked. Status 200, `application/octet-stream`, the same 15,716 bytes. |
| The same in-page `fetch()`, bytes read with `Uint8Array` + `String.fromCharCode.apply` + `btoa` | **Failed**: `Page.evaluate: Permission denied to access property "constructor"`. Camoufox runs `page.evaluate` in an isolated world, and handing a typed array across that boundary is refused. |

Not measured: the in-page method against any site other than Macmillan; the in-page method on a
URL the browser would display rather than download (XML, JSON), although nothing about `fetch()`
depends on that; behaviour when the first page load itself lands on a challenge page.

## Decisions

Agreed before this was written:

- The fetcher is extended to handle files, rather than routing file downloads some other way.
- The service has no `robots.txt` handling and never did; the caller decides what to fetch.

Calls made while writing, approved with the design:

- **A separate endpoint, `POST /fetch_file`**, not a mode on `/fetch`. The response has a
  different shape, and the existing endpoint and its callers stay untouched.
- **The in-page `fetch()` method**, using the `Blob` + `FileReader.readAsDataURL` variant that
  worked. It serves `.gz`, XML and JSON alike. The download-event method only fires for content
  the browser will not display, so it would need a second path for XML and JSON.
- **Bytes travel as base64 inside the JSON response.** Same response discipline as `/fetch`
  (JSON in, JSON out, one error shape). The cost is 33% size overhead, acceptable at the sizes
  involved.
- **The page loaded first defaults to the site's `/robots.txt`**, with an optional override. It
  is small, has no subresources, and exists on nearly every site.

## 1. API contract

### `POST /fetch_file`

Request:

```json
{
  "url": "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz",
  "page_url": null,
  "timeout_ms": 30000
}
```

| Field | Rules |
|---|---|
| `url` | Required. Same rules as `/fetch`'s `url` (service spec §2, §6): `http` or `https`, no embedded credentials, host must resolve only to public addresses. |
| `page_url` | Optional. The page loaded before the file is requested. Default: `/robots.txt` on `url`'s origin. Must have the same origin (scheme, host, port) as `url`; otherwise `400 invalid_url`. Subject to the same address rules as `url`. |
| `timeout_ms` | Same bounds and default as `/fetch`. One budget covers slot wait, launch, the page load, the file request and reading its bytes. |

Unknown fields are a 422, as on `/fetch`.

Response, 200:

```json
{
  "url": "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz",
  "final_url": "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz",
  "status": 200,
  "content_type": "application/octet-stream",
  "body_base64": "H4sIAAAA…",
  "size_bytes": 14946,
  "elapsed_ms": 4120,
  "fetched_at": "2026-11-16T21:10:42Z"
}
```

- `status` is the site's status for the file request, passed through as on `/fetch`. A 403 or a
  challenge page from the site is a 200 from the service with `status: 403` and the challenge
  page's bytes in `body_base64`. The caller classifies blocked responses, as it does for pages.
- `body_base64` is the response body exactly as the page's `fetch()` saw it. The browser removes
  transport compression (`Content-Encoding`), so a `.gz` *file* arrives still gzipped and an XML
  file served with `Content-Encoding: gzip` arrives as plain XML. The service never unzips.
- `content_type` is the response's `Content-Type` header, or `null` when the site sent none.
- `final_url` is the URL after redirects, as reported by the browser for that request.
- The **status** of the page load (`page_url`) is not reported and does not affect the result. A
  404 for `/robots.txt` still gives the browser a document on the right origin, which is all the
  file request needs.
- **Where the page load ends up does matter.** `/robots.txt` often redirects (http to https, apex
  to `www`, out to a CDN). If the last document response is on a different origin from `url`, the
  in-page request would be cross-origin and fail. The service checks this after the page load and
  answers `400 invalid_url`, with a `detail` that names the origin the page landed on and says to
  pass a `page_url` on `url`'s origin (or to request the file from the origin the site redirects
  to). It does not follow the page to its new origin.
- **A page load that turns into a download** (a `robots.txt` served with a download type or
  `Content-Disposition`) is also `400 invalid_url`, with a `detail` saying `page_url` is not a
  displayable page. Today that Playwright failure would fall through to `browser_error`, which
  the Rails client counts against the shared breaker; one site's quirk must not do that.

Errors use the existing body `{"error": code, "detail": text}` and the existing codes with the
same meanings (service spec §2), plus one new code:

| HTTP | `error` | Meaning here |
|---|---|---|
| 400 | `invalid_url` | Bad `url` or `page_url`; a non-public address; `page_url` on a different origin; the page load landing on a different origin; the page load turning into a download. |
| 502 | `upstream_unreachable` | The page load could not reach the site, **or the in-page request was rejected**. `detail` says which stage. A page navigating away while the file is being requested is reported here too. |
| 502 | `file_too_large` | New. The body is over the size cap (§3). Describes the site, not the service. |
| 502 | `browser_error` | Anything else the browser raised, including a failure of the in-page script itself (as opposed to the request it made). |
| 503 | `browser_unavailable` | As `/fetch`. |
| 504 | `navigation_timeout` | The budget ran out. `detail` names the stage; the new stage is "downloading the file". |

`html_too_large` and `invalid_selector` cannot occur on this endpoint.

**Why every rejected in-page request is `upstream_unreachable`.** Firefox rejects a failed
`fetch()` with one generic `TypeError: NetworkError when attempting to fetch resource.` It
carries none of the `NS_ERROR_*` names the service uses to recognise an unreachable site, and it
is the same error for a DNS or TLS failure, a CORS block after a cross-origin redirect, and the
service's own route filter refusing the request. So:

- The in-page script **catches the rejection itself** and returns it as data. It must not let the
  rejection surface as a failed `page.evaluate`, which the existing translation would turn into
  `browser_error` and so into a breaker failure in Rails.
- All of these become `502 upstream_unreachable`. That includes the rare case where the host
  passed the pre-flight address check but resolved to a non-public address by the time of the
  request and the route filter refused it. `/fetch` reports that as `invalid_url` for a page
  navigation; here it reads as `upstream_unreachable`. The request is refused either way and
  neither code counts against the breaker, so the request filter is not changed to record
  non-navigation refusals.
- The redirect backstop (§4) still runs over whatever responses were recorded before the
  rejection. If it finds a non-public hop, `invalid_url` wins over the network failure.

### `GET /health`

Unchanged in shape. File fetches count in the same `fetches` counters as page fetches.

## 2. How a file fetch runs

1. Check `url` and `page_url` (address rules, same origin). Resolve the host.
2. Wait for a slot from the existing limiter: the global concurrency cap and the per-host
   spacing, exactly as a page fetch. One file fetch takes one slot and counts as one start
   against the host interval, even though it makes two requests to the host (the page, then the
   file) back to back. That is far lighter than an ordinary page load, which makes dozens.
3. Launch a fresh browser, as a page fetch does. Same request filter, same blocked resource
   types.
4. Load `page_url` with `wait_until: "load"`. Check that the page landed on `url`'s origin (§1).
5. Run the in-page script: `fetch(url, {credentials: "include"})`, catching a rejection and
   returning it as data (§1). If the response declares a `Content-Length` over the cap, stop
   there without reading the body. Otherwise read the body as a `Blob`, refuse it if `blob.size`
   is over the cap, and otherwise convert it with `FileReader.readAsDataURL` and return the
   status, content type, final URL and the base64 payload.
6. Run the redirect backstop on the file request (§4), whether or not the request succeeded.
7. Close the browser, as a page fetch does.

This is a new method on the `BrowserSession` protocol (name is the builder's; `fetch_file` is the
obvious one), implemented by `CamoufoxSession` and by the test fake. The decisions about budgets,
error mapping and the size cap stay in `Fetcher`, against the protocol, so they are tested
without a browser (service spec §9).

The download-event method is **not** built. It is the documented fallback if a site or a
Camoufox release breaks in-page `fetch()`: the measurement above shows it works against the same
wall.

## 3. Limits and configuration

- **Size cap.** New setting `FETCHER_MAX_FILE_BYTES`, default 10,485,760 (10 MB), minimum 1,
  counted on the body bytes before base64. Over it: `502 file_too_large`. For scale: a Macmillan
  file is 15 KB, a HarperCollins product sitemap about 500 KB, an uncompressed 25,000-URL sitemap
  about 5 MB.
- **What the cap protects.** It is enforced inside the page before the bytes are encoded, so an
  oversized body is never copied into the service or sent to Rails. It protects the browser only
  partly:
  - A declared `Content-Length` over the cap stops the request before the body is read.
  - A body with no `Content-Length`, or one sent with `Content-Encoding: gzip` that expands past
    the cap, is read into the browser in full before `blob.size` is checked. The container runs
    with a 2 GB memory limit and up to two fetches at once, and encoding needs roughly 2.7 times
    the file's size inside the page, so a very large or hostile file could get the container
    killed, taking the other fetch in flight with it. Compose restarts it.
  - This is accepted. URLs come from our own jobs and name known publisher files, the same trust
    the service already extends to page URLs, and `timeout_ms` bounds how long a body can keep
    arriving.
  - A streaming read that aborts at the cap would close the gap. It handles `Uint8Array` chunks,
    the type that failed across Camoufox's isolated world in the measurement, so it is unproven.
    The builder may adopt it if a real-browser check shows it works; it is not required.
- The setting is added everywhere `FETCHER_MAX_HTML_BYTES` is listed today: `settings.py`, the
  `environment:` block of `data-sources/docker-compose.yml` (compose forwards only the variables
  listed there), `docs/features/page-fetcher-service.md`, and `test_settings.py`.
  `deployment/ENV.md` lists no `FETCHER_*` service setting and is not changed.
- No other new settings. `timeout_ms` bounds, concurrency and host spacing are shared with page
  fetches.

## 4. Security

The service spec's §6 applies. Points specific to file fetches:

- **Address checks.** `url` and `page_url` get the pre-flight check. The file request is an
  ordinary `fetch()` from the page, so the existing route handler sees it and applies the same
  per-request host check.
- **Redirect backstop.** The route handler sees only the first URL of a redirect chain (service
  spec §6). For pages, the service walks the redirect chain of each main-frame document response
  afterwards. A file fetch needs the same treatment for the **file request**: the session records
  that request's response and its `redirected_from` chain (Playwright exposes this for any
  request, not only navigations), and `first_non_public_hop` runs over it. A non-public hop
  discards the result with `400 invalid_url`; a hop that no longer resolves, or a check that
  times out, is `502 upstream_unreachable`, as for pages. The page load's own chain is checked
  the same way it is today.
- **Same origin only.** `page_url` must share `url`'s origin, and a cross-origin redirect of the
  file request fails in the browser. The endpoint cannot be used to read a file from one site
  with another site's cookies.
- **Not a wider door.** Anything this endpoint can reach, `/fetch` could already reach as a page.
  The exposure posture is unchanged: loopback bind on one machine, Cloudflare Access plus the
  host firewall's egress block on the home server.
- **Nothing sensitive in logs.** The body is never logged. The per-fetch log line gains nothing
  but a distinct `event` value (`fetch_file`) and may carry `size_bytes`.

## 5. Rails client

`PageFetcher::Client` gains one public method:

```ruby
# @return [PageFetcher::FileResponse]
def fetch_file(url, page_url: nil, timeout_ms: 30_000)
```

- Same breaker (`page_fetcher`), same read-timeout formula, same exception classes and the same
  rule for what counts against the breaker. `file_too_large` joins `upstream_unreachable` and
  `html_too_large` in `UPSTREAM_ERROR_CODES`: it describes the site, so it raises `UpstreamError`
  and does not trip the breaker.
- `PageFetcher::FileResponse` is a value object beside `PageFetcher::Page`, holding `url`,
  `final_url`, `status`, `content_type`, `body` (the decoded bytes, a binary `String`),
  `elapsed_ms` and `fetched_at`. Its `inspect` hides `body`, as `Page#inspect` hides `html`.
- A helper on it returns the body unzipped when it starts with the gzip magic bytes and the body
  itself otherwise (name is the builder's). Callers reading sitemaps want text and should not
  each re-implement that test. Unzipping must be bounded: a small gzip can expand enormously, so
  the helper stops and raises once the output passes a fixed limit (builder picks it; 100 MB is
  ample for a sitemap).
- The rule that a response body is never kept on an exception (it would reach the error tracker)
  applies to this response as well.

Nothing calls `fetch_file` when this ships. The publisher intake is its first caller. As with
`#fetch`, pacing and retries are the caller's job.

## 6. Testing

- **Python, no browser.** The fake browser session gains the new method. `test_fetcher.py`
  covers: a successful file fetch; a non-2xx site status passed through with its body; the size
  cap, by declared length and by actual size; a rejected in-page request reported as
  `upstream_unreachable`; the budget running out during the download; the redirect backstop on
  the file request (non-public hop, unresolvable hop, and a non-public hop found after a rejected
  request); `page_url` on another origin; the page load landing on another origin; the page load
  turning into a download; the default `page_url`. `test_api.py` covers the request and
  response models and the 422 on unknown fields. `test_settings.py` covers the new setting.
- **Python, real browser.** The feature doc's manual smoke check gains one file fetch against a
  Macmillan sitemap file, with the expected result: status 200, gzip magic bytes, 1,000 `<loc>`
  entries after unzipping. As today, there is no automated real-browser test.
- **Rails.** `client_test.rb` covers `fetch_file` the way it covers `fetch`: success, each error
  class, the breaker rules including `file_too_large`. A test for the value object covers the
  base64 decode, the unzip helper (gzip, not gzip, over the limit) and `inspect`.

## 7. Documentation and deploy

- `docs/features/page-fetcher-service.md`: the new endpoint, its error table, the new setting,
  the smoke check, and a short "why not `APIRequestContext`" note with the measurement, so nobody
  re-tries the blocked method.
- Deploy is the existing path: the image is rebuilt and the home server's `fetcher-deploy` picks
  it up. No Rails configuration changes. The Rails change ships dark, since nothing calls it.

## Non-goals

- Request methods other than GET, request bodies, or caller-supplied headers.
- Streaming, range requests, or files larger than the cap.
- Fetching several files in one browser session. One file per fetch keeps the crash isolation
  the service was built on. If 70 launches a week per publisher ever matters, batching is a
  later change with its own design.
- Caching, storing or logging file bodies in the service.
- Any `robots.txt` handling, allowlist or per-site rule in the service.
- Cross-origin file requests.
- The download-event method (kept as a documented fallback only).
- Any change to `/fetch`.

## Anti-goals

- `/fetch` behaving differently for any existing caller. Goodreads enrichment depends on it.
- A file body appearing in a log line, an exception, or an error tracker.
- The service becoming reachable in any way it is not today.

## Risks

- **Measured against one site.** The in-page method is proven only on Macmillan's Cloudflare
  setup. HarperCollins sitemaps were read through `/fetch` (rendered), not through this method.
  The first real use against a second site is the test.
- **A challenge on the first page load.** If `/robots.txt` itself returns a challenge that takes
  a moment to clear, the in-page request may run before clearance and come back 403. The caller
  sees `status: 403` and retries later, the same as a blocked page fetch. If this proves common,
  the remedy is a `page_url` pointing at a page plus a selector wait, which is a later addition.
  If the challenge navigates the page while the in-page request is pending, the fetch fails as
  `upstream_unreachable` (retryable, not a breaker failure) instead of returning `status: 403`.
- **Camoufox's isolated world.** One of two byte-reading variants failed on a cross-world
  permission error. A Camoufox upgrade could break the other. The smoke check exists to catch
  that at upgrade time; the download-event method is the fallback.
- **Content Security Policy.** A page whose CSP forbids `connect-src 'self'` would block the
  in-page request. `/robots.txt` is a plain text document and normally carries none.

## Left to the builder

- Names of the new protocol method, the response model, the Rails helper, and the log fields.
- The exact in-page script, provided it keeps the `Blob` + `FileReader.readAsDataURL` approach
  and enforces the cap before encoding.
- How the session captures the file request's redirect chain.
- The unzip limit in the Rails helper.
- Section placement inside the existing feature doc.
