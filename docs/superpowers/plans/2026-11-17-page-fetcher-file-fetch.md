# Page Fetcher File Fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `POST /fetch_file` to the page fetcher service and `PageFetcher::Client#fetch_file` to Rails, so Rails can get the raw bytes of a public file from a site that blocks plain HTTP clients.

**Architecture:** A file fetch is a page fetch with a different last step. The service launches a fresh browser, loads a small page on the file's own origin (`/robots.txt` by default), then runs a `fetch()` from inside that page and returns the bytes as base64. `Fetcher` makes every decision against the `BrowserSession` protocol, so the logic is tested with the fake browser; `CamoufoxSession` only drives the page. The Rails client gains one method and one value object, sharing the existing breaker and error mapping.

**Tech Stack:** Python 3 / FastAPI / Pydantic / Playwright + Camoufox (`data-sources/src/fetcher`), pytest with anyio; Ruby on Rails 8 / Faraday / Minitest + WebMock (`web-app/app/lib/page_fetcher`).

**Spec:** `docs/superpowers/specs/2026-11-16-page-fetcher-file-fetch-design.md` ("the spec"). It extends `docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md` ("the service spec"). Read both.

## Global Constraints

- Work on branch `worktree-page-fetcher-file-fetch` in `.claude/worktrees/page-fetcher-file-fetch`. Never commit to `main`. Do not push or open a PR without being asked.
- `POST /fetch`, its request and response, its log line's keys and every existing test stay as they are. Existing tests may gain neighbours; none is edited to pass, except where a task says so.
- The file body is never logged, never put on an exception, never stored.
- No new Python or Ruby dependency. `uv sync --locked --extra fetcher --extra recommender --extra worldcat --extra wikidata` must still succeed unchanged.
- `browser.py` stays the only runtime module that imports `playwright` or `camoufox`, and only inside functions.
- `api/schemas.py` and `api/routes.py` must not gain `from __future__ import annotations`.
- Python commands run from `data-sources/`: `uv run pytest tests/fetcher`, `uv run ruff check .`, `uv run ruff format --check .`. All three must pass at the end of every Python task.
- Rails commands run from `web-app/`: `bin/rails test test/lib/page_fetcher`, `bundle exec standardrb`. Before the final commit, run the full `bin/rails test`. Do not run brakeman.
- Size cap: setting `FETCHER_MAX_FILE_BYTES`, default `10485760`, minimum `1`, counted on body bytes before base64.
- New error code `file_too_large` is HTTP 502. A rejected in-page request is `502 upstream_unreachable`. A page load that lands on another origin, or turns into a download, is `400 invalid_url`.
- The in-page script uses `Blob` + `FileReader.readAsDataURL`. It must not use `Uint8Array`, `String.fromCharCode` or `btoa`: that variant fails in Camoufox's isolated world (spec, "What was measured").

## Review Focus

Inputs the spec implies but does not list as tests. Each has a test in the task named.

1. **A file URL with a query string** (HarperCollins: `sitemap_products_1.xml?from=1&to=2`). The default page must be `<origin>/robots.txt` with no query, and the file URL must reach the browser intact. Task 3.
2. **An empty file** (status 200, zero bytes). It is a successful fetch with an empty body, not an error. A data URL for an empty blob has no payload after the comma. Tasks 2 and 3.
3. **Origins that differ only in spelling**: uppercase host, explicit default port (`https://Example.com:443/a.gz` with page `https://example.com/robots.txt`). These are the same origin and must not be refused. Task 3.
4. **A response with no `Content-Type`.** `content_type` is `null` end to end, not `""` and not a crash. Tasks 4 and 6.
5. **A body that starts with the gzip magic bytes but is truncated or corrupt.** The Rails helper raises a `PageFetcher` error, not a bare `Zlib` one, so a caller's `rescue PageFetcher::Exceptions::Error` holds. Task 6.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `data-sources/src/fetcher/settings.py` | modify | `max_file_bytes` |
| `data-sources/docker-compose.yml` | modify | forward `FETCHER_MAX_FILE_BYTES` |
| `data-sources/src/fetcher/browser.py` | modify | `FileResult`, `DownloadStarted`, protocol methods, `CamoufoxSession.fetch_file` / `file_responses` |
| `data-sources/src/fetcher/urlcheck.py` | modify | `origin()` |
| `data-sources/src/fetcher/fetcher.py` | modify | `FileFetchRequest`, `FileFetchResult`, `Fetcher.fetch_file` |
| `data-sources/src/fetcher/api/schemas.py`, `api/routes.py` | modify | `POST /fetch_file` |
| `data-sources/tests/fetcher/fakes.py` | modify | script fields and fake methods for the file path |
| `data-sources/tests/fetcher/test_*.py` | modify | new tests beside the existing ones |
| `docs/features/page-fetcher-service.md` | modify | endpoint, errors, setting, smoke check, measurement |
| `web-app/app/lib/page_fetcher/file_response.rb` | create | value object holding the bytes |
| `web-app/app/lib/page_fetcher/exceptions.rb` | modify | `InflatedTooLargeError` |
| `web-app/app/lib/page_fetcher/client.rb` | modify | `fetch_file` |
| `web-app/test/lib/page_fetcher/file_response_test.rb` | create | value object tests |
| `web-app/test/lib/page_fetcher/client_test.rb` | modify | `fetch_file` tests |

---

### Task 1: The size-cap setting

**Files:**
- Modify: `data-sources/src/fetcher/settings.py`
- Modify: `data-sources/docker-compose.yml` (the fetcher service's `environment:` block, beside `FETCHER_MAX_HTML_BYTES`)
- Test: `data-sources/tests/fetcher/test_settings.py`

**Interfaces:**
- Produces: `Settings.max_file_bytes: int` (default `10_485_760`), read from `FETCHER_MAX_FILE_BYTES`, minimum 1.

- [ ] **Step 1: Write the failing tests.** In `test_settings.py`, extend the existing tests rather than adding parallel ones: the defaults test asserts `Settings.from_env({}).max_file_bytes == 10_485_760`; the every-variable test sets `FETCHER_MAX_FILE_BYTES` to `"2048"` and asserts `max_file_bytes == 2048`; add `"FETCHER_MAX_FILE_BYTES"` to the non-integer parametrize list and `("FETCHER_MAX_FILE_BYTES", "0")` to the below-minimum list.
- [ ] **Step 2: Run** `uv run pytest tests/fetcher/test_settings.py`. Expected: FAIL, `Settings` has no `max_file_bytes`.
- [ ] **Step 3: Add the field and its `_int(env, "FETCHER_MAX_FILE_BYTES", cls.max_file_bytes, 1)` line** to `Settings` and `from_env`. Add `FETCHER_MAX_FILE_BYTES: "${FETCHER_MAX_FILE_BYTES:-10485760}"` to the compose `environment:` block.
- [ ] **Step 4: Run** `uv run pytest tests/fetcher/test_settings.py && uv run ruff check . && uv run ruff format --check .`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Fetcher: FETCHER_MAX_FILE_BYTES setting"`.

---

### Task 2: The browser boundary

**Files:**
- Modify: `data-sources/src/fetcher/browser.py`
- Modify: `data-sources/tests/fetcher/fakes.py`
- Test: `data-sources/tests/fetcher/test_browser.py`, `data-sources/tests/fetcher/test_camoufox_backend.py`

**Interfaces:**
- Produces, all in `fetcher.browser`:

```python
class DownloadStarted(BrowserError):
    """Navigation turned into a download: the URL is not a displayable page."""

@dataclass(frozen=True)
class FileResult:
    """What the in-page request for a file came to."""
    outcome: Literal["ok", "too_large", "rejected"]
    status: int | None = None          # the site's status; None when rejected
    final_url: str | None = None       # None when rejected
    content_type: str | None = None    # None when the site sent no Content-Type
    body: bytes = b""                  # filled only when outcome == "ok"
    size_bytes: int | None = None      # actual size (ok), declared or actual size (too_large)
    detail: str = ""                   # the rejection's message (rejected)

class BrowserSession(Protocol):
    ...
    async def fetch_file(self, url: str, max_bytes: int) -> FileResult: ...
    def file_responses(self) -> list[DocumentResponse]: ...
```

- `fetch_file` raises only `BrowserFailure` subclasses. It has no timeout argument: the caller wraps it in `Budget.run`, as it does `content()`.
- `file_responses()` returns one `DocumentResponse` per response received for the file request, including the 3xx hops, each with its `redirect_chain`; empty until `fetch_file` has run.
- `translate_playwright_error` returns `DownloadStarted` when the Playwright error text contains `"Download is starting"`. Because `DownloadStarted` subclasses `BrowserError`, `/fetch` still reports it as `browser_error`.
- Fakes: `Script` gains `file_result: FileResult | BaseException` (default: `FileResult(outcome="ok", status=200, final_url=FILE_URL, content_type="application/octet-stream", body=FILE_BODY, size_bytes=len(FILE_BODY))`), `file_delay_s: float = 0.0`, `file_requests: list[tuple[str, str, bool]]` (default: `[(FILE_URL, "fetch", False)]`, each sent through the request filter like `requests`), and `file_responses: list[DocumentResponse]` (default: `[DocumentResponse(FILE_URL, 200)]`). `FakeSession` records `file_calls: list[tuple[str, int]]`. New constants in `fakes.py`: `FILE_URL = "https://books.example/sitemaps/products.1.xml.gz"`, `ROBOTS_URL = "https://books.example/robots.txt"`, `FILE_BODY = b"\x1f\x8b fake gzip bytes"`.

- [ ] **Step 1: Write the failing tests.**

`test_browser.py`:

```python
def test_a_navigation_that_becomes_a_download_is_its_own_browser_error():
    failure = translate_playwright_error(PlaywrightError("Page.goto: Download is starting"))
    assert isinstance(failure, DownloadStarted)
    assert isinstance(failure, BrowserError)  # so /fetch still calls it browser_error
```

`test_camoufox_backend.py`, using a small fake page whose `evaluate(script, arg)` records its arguments and returns a canned dict (follow `_StreamingPage`'s style; mark each `@pytest.mark.anyio`):

```python
async def test_fetch_file_decodes_the_page_scripts_answer():
    page = _EvaluatingPage({"outcome": "ok", "status": 200, "final_url": FILE, "content_type": None,
                            "size_bytes": 5, "body_base64": base64.b64encode(b"hello").decode()})
    result = await CamoufoxSession(object(), page).fetch_file(FILE, 1024)
    assert result == FileResult(outcome="ok", status=200, final_url=FILE, content_type=None,
                                body=b"hello", size_bytes=5)
    assert page.calls[0][1] == [FILE, 1024]   # the url and the cap, in that order

async def test_fetch_file_decodes_an_empty_file():          # Review Focus 2
    # body_base64 "" -> body b"", size_bytes 0, outcome "ok"

async def test_fetch_file_reports_too_large_and_rejected_without_a_body():
    # {"outcome": "too_large", "status": 200, "final_url": FILE, "content_type": "x", "size_bytes": 9999}
    #   -> FileResult(outcome="too_large", ..., body=b"", size_bytes=9999)
    # {"outcome": "rejected", "detail": "NetworkError when attempting to fetch resource."}
    #   -> FileResult(outcome="rejected", detail="NetworkError when attempting to fetch resource.")

async def test_the_page_script_uses_the_variant_that_works_in_camoufox():
    # the script string passed to evaluate contains "readAsDataURL" and "credentials"
    # and none of "Uint8Array", "fromCharCode", "btoa"

async def test_a_failing_page_script_is_a_browser_error():
    # evaluate raises PlaywrightError("Page.evaluate: boom") -> BrowserError

async def test_an_answer_that_is_not_the_scripts_shape_is_a_browser_error():
    # evaluate returns None, or {"outcome": "ok"} with no body_base64, or invalid base64 -> BrowserError

async def test_file_responses_keeps_each_hop_of_the_file_request_with_its_chain():
    # The fake page's evaluate() feeds session.record_response while it runs, as the
    # browser would during the request: a main-frame navigation response for the page
    # (goes to document_responses only), an unrelated subresource response, a 302 for
    # FILE, then a 200 whose request.redirected_from is the FILE request.
    # After `await session.fetch_file(FILE, 1024)`:
    #   session.file_responses() == [DocumentResponse(FILE, 302),
    #                                DocumentResponse(FINAL, 200, redirect_chain=(FILE,))]
    #   and an unrelated subresource response is in neither list.
```

- [ ] **Step 2: Run** `uv run pytest tests/fetcher/test_browser.py tests/fetcher/test_camoufox_backend.py`. Expected: FAIL on the missing names.
- [ ] **Step 3: Implement in `browser.py`.** `DownloadStarted`, `FileResult`, the two protocol methods, the `"Download is starting"` branch in `translate_playwright_error` (checked before the generic `BrowserError` return), and on `CamoufoxSession`: `fetch_file`, `file_responses`, and an extension of `record_response` that, for a response that is not a main-frame navigation, walks `request.redirected_from` back to the first request and records the response in the file list when that first request's URL equals the URL passed to `fetch_file`. `fetch_file` stores the URL before evaluating, so responses arriving during the evaluate are matched. The page script, verbatim, as a module constant:

```js
async ([url, maxBytes]) => {
  let response;
  try {
    response = await fetch(url, {credentials: "include"});
  } catch (error) {
    return {outcome: "rejected", detail: String((error && error.message) || error)};
  }
  const meta = {
    status: response.status,
    final_url: response.url,
    content_type: response.headers.get("content-type"),
  };
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    return {...meta, outcome: "too_large", size_bytes: declared};
  }
  let blob;
  try {
    blob = await response.blob();
  } catch (error) {
    return {outcome: "rejected", detail: String((error && error.message) || error)};
  }
  if (blob.size > maxBytes) {
    return {...meta, outcome: "too_large", size_bytes: blob.size};
  }
  const dataUrl = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
  return {...meta, outcome: "ok", size_bytes: blob.size, body_base64: String(dataUrl).split(",")[1] || ""};
}
```

A missing `Content-Length` makes `Number(null)` 0, which is not over any cap. Call it as `page.evaluate(SCRIPT, [url, max_bytes])`. Any exception from `evaluate`, and any answer that does not decode into a `FileResult`, becomes a `BrowserFailure` through `translate_playwright_error` or a plain `BrowserError`.

- [ ] **Step 4: Extend `fakes.py`** as listed under Interfaces. `FakeSession.fetch_file` records the call, sends `file_requests` through the request filter (appending to `filter_decisions`), sleeps `file_delay_s`, then raises or returns `file_result`.
- [ ] **Step 5: Run** `uv run pytest tests/fetcher && uv run ruff check . && uv run ruff format --check .`. Expected: PASS, including every pre-existing test.
- [ ] **Step 6: Commit** `git commit -m "Fetcher: in-page file request on the browser session"`.

---

### Task 3: `Fetcher.fetch_file`

**Files:**
- Modify: `data-sources/src/fetcher/urlcheck.py`
- Modify: `data-sources/src/fetcher/fetcher.py`
- Test: `data-sources/tests/fetcher/test_urlcheck.py`, `data-sources/tests/fetcher/test_fetcher.py`

**Interfaces:**
- Consumes: Task 1 `Settings.max_file_bytes`; Task 2 `FileResult`, `DownloadStarted`, `BrowserSession.fetch_file`, `BrowserSession.file_responses`, the fake `Script` fields and constants.
- Produces:

```python
# urlcheck.py
def origin(url: str) -> tuple[str, str, int]:
    """(scheme, lowercased host, effective port). Raises InvalidUrl as parse() does."""

# fetcher.py
@dataclass(frozen=True)
class FileFetchRequest:
    url: str
    page_url: str | None = None
    timeout_ms: int = 30_000

@dataclass(frozen=True)
class FileFetchResult:
    url: str
    final_url: str
    status: int
    content_type: str | None
    body: bytes
    size_bytes: int
    elapsed_ms: int
    fetched_at: str

class Fetcher:
    async def fetch_file(self, request: FileFetchRequest) -> FileFetchResult: ...
```

**Behaviour, in order** (spec §1, §2, §4). Each failure is a `FetchError(code, http_status, detail)`:

1. `hosts.check(request.url)`: `InvalidUrl` → `invalid_url` 400; `Unresolvable` → `upstream_unreachable` 502. Same as `fetch`.
2. Page URL: `request.page_url`, or `f"{scheme}://{netloc}/robots.txt"` built from `request.url` (no path, query or fragment carried over). A given `page_url` is parsed with `urlcheck.parse`; if `origin(page_url) != origin(url)` → `invalid_url` 400, detail `"page_url must have the same origin as url"`.
3. Limiter slot on the file's host, then launch, exactly as `fetch` (same launch-failure accounting and fatal hook). Reuse the existing launch/close code rather than copying it.
4. `session.goto(page_url, "load", budget.remaining())`, stage `"loading the page"`, with the existing error mapping, plus: `DownloadStarted` → `invalid_url` 400, detail `"page_url is not a displayable page: loading it started a download; pass a different page_url"`.
5. `session.document_responses()`: none → `browser_error` 502 (existing wording). Run the existing redirect backstop over them (same codes as `fetch`). Then, if `origin(last.url) != origin(request.url)` → `invalid_url` 400, detail `f"the page load landed on {scheme}://{host}, not url's origin; pass a page_url on url's origin, or request the file from the origin the site redirects to"`.
6. `session.fetch_file(request.url, settings.max_file_bytes)` under `budget.run(..., "downloading the file")` and the existing `_mapped` translation.
7. Run the redirect backstop over `session.file_responses()`, **whatever the outcome**. A non-public hop is `invalid_url` 400 and wins over everything below.
8. By outcome: `rejected` → `upstream_unreachable` 502, detail `f"the in-page request for the file was rejected: {detail}"`. `too_large` → `file_too_large` 502, detail `f"the file is {size} bytes, over the {cap}-byte cap"`. `ok` with `len(body) > cap` → the same `file_too_large`. `ok` with no recorded file response → `browser_error` 502, detail `"the file request produced no recorded response"` (fail closed: without it the backstop checked nothing).
9. Otherwise return the result. `status`, `final_url`, `content_type` come from the `FileResult`; a non-2xx status is data, not an error.

Counting and logging: a file fetch moves the same `ok` / `failed` / `in_flight` counters and logs one line with `event: "fetch_file"`, the existing keys, and `size_bytes` on success. The page-fetch line keeps exactly its current keys.

- [ ] **Step 1: Write the failing tests.**

`test_urlcheck.py`:

```python
@pytest.mark.parametrize(("a", "b"), [
    ("https://Example.com:443/a.gz", "https://example.com/robots.txt"),   # Review Focus 3
    ("http://example.com:80/x", "http://EXAMPLE.com/"),
])
def test_origin_ignores_case_and_default_ports(a, b):
    assert origin(a) == origin(b)

@pytest.mark.parametrize(("a", "b"), [
    ("https://example.com/", "http://example.com/"),
    ("https://example.com/", "https://www.example.com/"),
    ("https://example.com/", "https://example.com:8443/"),
])
def test_origin_tells_scheme_host_and_port_apart(a, b):
    assert origin(a) != origin(b)
```

`test_fetcher.py`, a new section after the existing tests, using `build(...)` and a `file_error(fetcher, url=FILE_URL, **kwargs) -> FetchError` helper beside `fetch_error`. The default `Script` needs `responses=[DocumentResponse(ROBOTS_URL, 200)]` for these; add a `file_script(**overrides)` helper that sets it. One test per line; each name states the behaviour:

| Test | Arrange | Assert |
|---|---|---|
| `test_a_file_fetch_returns_the_bytes_and_closes_its_browser` | `file_script()` | `(url, final_url, status, content_type, body, size_bytes) == (FILE_URL, FILE_URL, 200, "application/octet-stream", FILE_BODY, len(FILE_BODY))`; `fetched_at` matches the existing timestamp regex; session closed |
| `test_the_page_loaded_first_defaults_to_robots_txt_on_the_files_origin` | url `https://books.example/sitemap_products_1.xml?from=1&to=2#x` (Review Focus 1) | `session.goto_calls[0][:2] == ("https://books.example/robots.txt", "load")`; `session.file_calls == [(that url unchanged, 10_485_760)]` |
| `test_a_given_page_url_is_loaded_instead` | `page_url="https://books.example/about"` | first goto is that URL |
| `test_a_page_url_on_another_origin_is_refused_before_any_launch` | `page_url="https://other.example/robots.txt"` | `invalid_url`, 400; `browser.sessions == []` |
| `test_a_page_url_spelled_differently_is_the_same_origin` | url `https://Books.example:443/a.gz`, `page_url="https://books.example/robots.txt"`, `responses` on `https://books.example/robots.txt`, `file_result`/`file_responses` on the url (Review Focus 3) | succeeds |
| `test_a_page_load_that_lands_on_another_origin_is_invalid_url` | `responses=[DocumentResponse("https://www.books.example/robots.txt", 200, redirect_chain=(ROBOTS_URL,))]` | `invalid_url`, 400; detail contains `"https://www.books.example"`; `session.file_calls == []` |
| `test_a_page_load_that_becomes_a_download_is_invalid_url` | `goto_error=DownloadStarted("Download is starting")` | `invalid_url`, 400; detail contains `"page_url"` |
| `test_a_404_for_the_page_does_not_stop_the_file_fetch` | `responses=[DocumentResponse(ROBOTS_URL, 404)]` | succeeds |
| `test_a_site_403_for_the_file_is_data_not_an_error` | `file_result` with status 403 and a challenge body | result status 403, body returned |
| `test_an_empty_file_is_a_successful_fetch` | `file_result` ok, `body=b""`, `size_bytes=0` (Review Focus 2) | `body == b""`, `size_bytes == 0` |
| `test_a_declared_or_actual_size_over_the_cap_is_file_too_large` | parametrize: `FileResult(outcome="too_large", ..., size_bytes=11_000_000)`; and outcome ok with a body one byte over a `Settings(max_file_bytes=8, host_interval_ms=0)` cap | `file_too_large`, 502; detail names both numbers |
| `test_a_rejected_request_is_upstream_unreachable` | `FileResult(outcome="rejected", detail="NetworkError when attempting to fetch resource.")`, `file_responses=[]` | `upstream_unreachable`, 502; detail contains the message |
| `test_a_file_redirect_through_a_private_address_returns_no_bytes` | `file_responses=[DocumentResponse(FILE_URL, 200, redirect_chain=("http://intranet.example/x",))]` | `invalid_url`, 400 |
| `test_a_private_hop_wins_over_a_rejected_request` | rejected outcome, with the same private hop recorded | `invalid_url`, 400 |
| `test_a_file_hop_that_no_longer_resolves_is_upstream_unreachable` | hop on `gone.example` | `upstream_unreachable`, 502 |
| `test_a_success_with_no_recorded_file_response_fails_closed` | ok outcome, `file_responses=[]` | `browser_error`, 502 |
| `test_the_file_request_goes_through_the_address_filter` | `file_requests=[("http://intranet.example/a.gz", "fetch", False)]` | `session.filter_decisions` holds `("http://intranet.example/a.gz", False)` |
| `test_the_budget_running_out_during_the_download_names_the_stage` | `file_delay_s=5`, `timeout_ms=1000` | `navigation_timeout`, 504; detail ends `"downloading the file"` |
| `test_a_failing_page_script_is_a_browser_error_for_the_file` | `file_result=BrowserError("boom")` | `browser_error`, 502 |
| `test_the_browser_is_closed_on_every_file_failure_path` | parametrize over the failing scripts above | every session `closed` |
| `test_file_fetches_share_the_health_counters` | one success, one failure | `health()["fetches"] == {"ok": 1, "failed": 1, "in_flight": 0}` |
| `test_a_file_fetch_logs_one_line_and_never_the_body` | success with `FILE_BODY` | one line with `event == "fetch_file"`, `outcome == "ok"`, `size_bytes == len(FILE_BODY)`; no record contains `FILE_BODY`'s text or its base64 |
| `test_a_page_fetch_log_line_keeps_its_keys` | `fetcher.fetch(...)` | `set(line) == {"event", "host", "outcome", "status", "elapsed_ms", "launch_ms", "waited"}` |

- [ ] **Step 2: Run** `uv run pytest tests/fetcher/test_urlcheck.py tests/fetcher/test_fetcher.py`. Expected: FAIL on the missing names.
- [ ] **Step 3: Implement `origin`** in `urlcheck.py` (default ports 80 and 443 filled in; host lowercased).
- [ ] **Step 4: Implement `FileFetchRequest`, `FileFetchResult` and `Fetcher.fetch_file`** per "Behaviour, in order". Factor the parts `fetch` and `fetch_file` share (the counting-and-logging wrapper, resolve + slot + launch + close, the redirect backstop over a list of `DocumentResponse`) into private helpers both call. `fetch`'s behaviour must not change: every existing test in `test_fetcher.py` passes untouched.
- [ ] **Step 5: Run** `uv run pytest tests/fetcher && uv run ruff check . && uv run ruff format --check .`. Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "Fetcher: fetch_file decides what a file fetch returns"`.

---

### Task 4: `POST /fetch_file`

**Files:**
- Modify: `data-sources/src/fetcher/api/schemas.py`, `data-sources/src/fetcher/api/routes.py`
- Modify: `data-sources/src/fetcher/api/main.py` (module docstring only: it says "URL in, rendered HTML out")
- Test: `data-sources/tests/fetcher/test_api.py`

**Interfaces:**
- Consumes: Task 3 `Fetcher.fetch_file`, `FileFetchRequest`, `FileFetchResult`.
- Produces: `POST /fetch_file`. Request model built per app like `fetch_request_model` (`extra="forbid"`; `url: str` 1–8192 chars; `page_url: str | None = None`, 1–8192 chars when given; `timeout_ms` with the same default and bounds as `/fetch`). Response model fields, exactly: `url`, `final_url`, `status`, `content_type` (`str | None`), `body_base64`, `size_bytes`, `elapsed_ms`, `fetched_at`. `body_base64` is standard base64 with padding (`base64.b64encode`). Error responses documented with the same `ERROR_RESPONSES`.

- [ ] **Step 1: Write the failing tests** in `test_api.py`, using `make_client` with `file_script`-style scripts:

```python
FILE_RESPONSE_KEYS = {"url", "final_url", "status", "content_type", "body_base64",
                      "size_bytes", "elapsed_ms", "fetched_at"}

def test_fetch_file_returns_the_bytes_as_base64():
    # POST {"url": FILE_URL} -> 200; set(body) == FILE_RESPONSE_KEYS;
    # base64.b64decode(body["body_base64"], validate=True) == FILE_BODY;
    # (body["status"], body["size_bytes"], body["content_type"]) == (200, len(FILE_BODY), "application/octet-stream")

def test_fetch_file_passes_a_missing_content_type_through_as_null():   # Review Focus 4
    # file_result with content_type=None -> body["content_type"] is None

def test_fetch_file_takes_a_page_url_and_a_timeout():
    # POST {"url": FILE_URL, "page_url": "https://books.example/about", "timeout_ms": 5000} -> 200;
    # browser.sessions[0].goto_calls[0][0] == "https://books.example/about"

@pytest.mark.parametrize("body", [
    {"url": FILE_URL, "wait_until": "load"},     # a /fetch field is unknown here
    {"url": FILE_URL, "page_url": ""},
    {"url": ""},
    {"page_url": ROBOTS_URL},
    {"url": FILE_URL, "timeout_ms": 999},
])
def test_invalid_fetch_file_bodies_are_422_and_launch_nothing(body): ...

@pytest.mark.parametrize(("script", "extra", "status", "code"), [
    # rejected request -> 502 upstream_unreachable; too_large -> 502 file_too_large;
    # page_url on another origin -> 400 invalid_url; launch failure -> 503 browser_unavailable;
    # file_delay_s over the budget -> 504 navigation_timeout
])
def test_fetch_file_errors_use_the_stable_error_body(script, extra, status, code):
    # response.json() == {"error": code, "detail": <a non-empty string>}
```

- [ ] **Step 2: Run** `uv run pytest tests/fetcher/test_api.py`. Expected: FAIL with 404s.
- [ ] **Step 3: Implement** the request-model factory and response model in `schemas.py` and the route in `routes.py`. Update `main.py`'s docstring to name both endpoints.
- [ ] **Step 4: Run** `uv run pytest && uv run ruff check . && uv run ruff format --check .` (the whole `data-sources` suite, as CI does). Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Fetcher: POST /fetch_file"`.

---

### Task 5: Real-browser check and the feature doc

This is the only place the mechanism meets a real browser inside the service: the spec's measurement ran a bare Camoufox page, without the service's route handler or blocked resource types. **If the check fails, stop and report; do not go on to the Rails tasks.**

**Files:**
- Modify: `docs/features/page-fetcher-service.md`

- [ ] **Step 1: Confirm port 8081 is free or already this checkout's fetcher** (`docker ps --format '{{.Names}} {{.Ports}}' | grep 8081`). If another checkout's fetcher holds it, stop and tell the user.
- [ ] **Step 2: Build and start** from `data-sources/`: `docker compose up -d --build --wait fetcher`, then `curl -s localhost:8081/health`. Expected: JSON with `camoufox_version`.
- [ ] **Step 3: Fetch one Macmillan sitemap file:**

```bash
curl -s localhost:8081/fetch_file -H 'content-type: application/json' \
  -d '{"url":"https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz"}' -o /tmp/ff.json
python3 -I -c "
import json,base64,gzip,re
r=json.load(open('/tmp/ff.json')); b=base64.b64decode(r.get('body_base64',''))
print({k:v for k,v in r.items() if k!='body_base64'})
print('gzip' if b[:2]==b'\x1f\x8b' else 'NOT GZIP', len(re.findall(rb'<loc>', gzip.decompress(b))) if b[:2]==b'\x1f\x8b' else b[:120])"
```

Expected: `status` 200, `gzip`, 1000 `<loc>` entries, `size_bytes` about 15,000. A `status` of 403 with a "Just a moment" body means the page load had not cleared the challenge: repeat once with `"page_url":"https://us.macmillan.com/"`, and record which one worked.
- [ ] **Step 4: Fetch one file the browser would display**, to cover XML: `{"url":"https://www.harpercollins.com/sitemap.xml"}`. Expected: `status` 200 and a body starting `<?xml`. Then confirm `/fetch` is unharmed: `curl -s localhost:8081/fetch -H 'content-type: application/json' -d '{"url":"https://www.goodreads.com/book/show/4671","wait_for_selector":"h1"}'` returns `status` 200 and `selector_found` true.
- [ ] **Step 5: Stop the container** (`docker compose stop fetcher`) unless it was already running before Step 2, and delete `/tmp/ff.json`.
- [ ] **Step 6: Update `docs/features/page-fetcher-service.md`:**
  - **API:** `POST /fetch_file` with its request fields, response fields and error table (spec §1), including why every rejected in-page request is `upstream_unreachable`.
  - **How it works:** the page-first, in-page-request sequence; one browser per file; the same slot and host spacing.
  - **Configuration:** `FETCHER_MAX_FILE_BYTES` (10485760) and what the cap does and does not protect (spec §3).
  - **Smoke check:** the Step 3 command with its expected result.
  - **Measured:** today's numbers from Steps 3 and 4 (elapsed_ms, sizes), and the spec's method table: `APIRequestContext` is blocked by Cloudflare, the browser download works and is the fallback, the `Uint8Array` variant fails in the isolated world.
  - **What the address checks do not cover:** the file request's redirect chain is checked the same way as a page's.
- [ ] **Step 7: Commit** `git commit -m "Docs: page fetcher file fetch, with the real-browser check"`.

---

### Task 6: `PageFetcher::FileResponse`

**Files:**
- Create: `web-app/app/lib/page_fetcher/file_response.rb`
- Modify: `web-app/app/lib/page_fetcher/exceptions.rb`
- Test: `web-app/test/lib/page_fetcher/file_response_test.rb`

**Interfaces:**
- Produces:

```ruby
module PageFetcher
  class FileResponse < Data.define(:url, :final_url, :status, :content_type, :body, :elapsed_ms, :fetched_at)
    MAX_INFLATED_BYTES = 100 * 1024 * 1024

    # Raises KeyError for a missing field and ArgumentError for a wrong type,
    # invalid base64, a size_bytes that is not body.bytesize, or a bad timestamp.
    def self.from_response(body) = ...

    # The body unzipped when it starts with the gzip magic bytes ("\x1F\x8B"), the body itself otherwise.
    # Raises Exceptions::InflatedTooLargeError past `limit` bytes of output, and
    # Exceptions::ParseError for a corrupt or truncated gzip stream.
    def inflated(limit: MAX_INFLATED_BYTES) = ...
  end

  module Exceptions
    class InflatedTooLargeError < Error; end
  end
end
```

- `body` is a binary (`ASCII-8BIT`) `String`, decoded with `Base64.strict_decode64`. `fetched_at` is a `Time`. `content_type` may be `nil`.
- `inspect`, `to_s` and `pretty_print` show `body=(N bytes)` and never the bytes, as `Page` does for `html`.
- `inflated` reads the gzip stream in chunks and stops at the limit; it never inflates the whole stream first. The `ParseError` it raises carries no response body.

- [ ] **Step 1: Write the failing tests** in `file_response_test.rb` (`module PageFetcher; class FileResponseTest < ActiveSupport::TestCase`), with a `response_hash(**overrides)` helper returning string-keyed fields for a gzipped `"<urlset>…</urlset>"` body:

```ruby
test "maps every field and decodes the body to binary" do
  # body == the gzip bytes; body.encoding == Encoding::BINARY; fetched_at == Time.utc(2026, 11, 16, 21, 10, 42)
end
test "a null content type stays nil"                       # Review Focus 4
test "an empty body is an empty binary string"             # body_base64 "", size_bytes 0
test "a missing field raises KeyError"
test "invalid base64 raises ArgumentError"                  # "not base64!!"
test "a size_bytes that disagrees with the body raises ArgumentError"
test "an unparseable timestamp raises ArgumentError"
test "inflated unzips a gzip body"                          # == the XML text's bytes
test "inflated returns a body that is not gzip unchanged"   # "<?xml …" plain
test "inflated stops at the limit" do
  # gzip of 4_096 zero bytes, inflated(limit: 1_024) raises Exceptions::InflatedTooLargeError
end
test "a truncated gzip body raises ParseError, not a Zlib error" do   # Review Focus 5
  # the gzip bytes with the last 8 removed -> Exceptions::ParseError; error.response_body is nil
end
test "inspect, to_s and pretty_inspect never include the body" do
  # none contains the body's bytes; inspect includes "body=(#{bytesize} bytes)"
end
```

- [ ] **Step 2: Run** `bin/rails test test/lib/page_fetcher/file_response_test.rb`. Expected: FAIL, uninitialized constant.
- [ ] **Step 3: Implement** the class and the exception.
- [ ] **Step 4: Run** `bin/rails test test/lib/page_fetcher && bundle exec standardrb`. Expected: PASS, no offenses.
- [ ] **Step 5: Commit** `git commit -m "PageFetcher::FileResponse: the bytes of a fetched file"`.

---

### Task 7: `PageFetcher::Client#fetch_file`

**Files:**
- Modify: `web-app/app/lib/page_fetcher/client.rb`
- Modify: `docs/features/page-fetcher-service.md` ("Rails client" section)
- Test: `web-app/test/lib/page_fetcher/client_test.rb`

**Interfaces:**
- Consumes: Task 6 `PageFetcher::FileResponse.from_response`.
- Produces:

```ruby
# @return [PageFetcher::FileResponse]
# @raise [PageFetcher::Exceptions::Error] or a subclass, as #fetch
def fetch_file(url, page_url: nil, timeout_ms: 30_000)
```

- Posts to `/fetch_file` with body `{url:, timeout_ms:}` plus `page_url` only when present. Same read timeout (`timeout_ms / 1000.0 + READ_TIMEOUT_PADDING`), same breaker, same rescue list as `fetch`.
- `UPSTREAM_ERROR_CODES` becomes `%w[upstream_unreachable html_too_large file_too_large]`.
- A 200 that does not parse into a `FileResponse` (`JSON::ParserError`, `KeyError`, `ArgumentError`) raises `Exceptions::ParseError` with a `nil` response body, inside the breaker block, as for pages.
- Share the HTTP, classification and error code between `fetch` and `fetch_file`; do not copy `fetch`'s body.

- [ ] **Step 1: Write the failing tests** in `client_test.rb`, beside the existing ones, with `FILE_FETCH_URL = "#{BASE_URL}/fetch_file"`, `FILE_URL = "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz"` and a `file_body(**overrides)` helper:

```ruby
test "fetch_file returns the file's bytes" do
  # 200 -> FileResponse; [status, content_type, body] == [200, "application/octet-stream", <the bytes>]
end
test "fetch_file posts the url and timeout and omits a missing page_url" do
  # exact body {"url" => FILE_URL, "timeout_ms" => 30_000}
end
test "fetch_file sends page_url when given and never a blank one" do
  # page_url: "https://us.macmillan.com/" is sent; page_url: "" is omitted
end
test "a site 403 for the file is a successful fetch"            # status 403, body returned
test "file_too_large raises UpstreamError and never trips the breaker" do
  # 502 {"error":"file_too_large"} six times -> UpstreamError each time, error_code "file_too_large"; breaker still closed
end
test "fetch_file maps 4xx and 5xx like fetch" do
  # 400 invalid_url -> ClientError; 502 browser_error -> ServerError; 503 browser_unavailable -> ServerError
end
test "five browser errors on fetch_file open the circuit that fetch shares" do
  # after five ServerErrors from fetch_file, @client.fetch raises CircuitOpenError and makes no request
end
test "an unparseable fetch_file 200 is a ParseError with no response body" do
  # non-JSON; JSON missing body_base64; invalid base64 -> ParseError, response_body nil,
  # and the message never contains the body
end
test "the fetch_file read timeout is the budget plus the padding" do
  # stub the connection as the existing read-timeout test does; timeout_ms: 45_000 -> 55.0
end
test "the file body never reaches the Faraday logger" do
  # as the existing HTML logger test, with a recognisable base64 body
end
```

- [ ] **Step 2: Run** `bin/rails test test/lib/page_fetcher/client_test.rb`. Expected: FAIL, undefined method `fetch_file`.
- [ ] **Step 3: Implement `fetch_file`** and the shared private helpers. Update the class header comment, which says the client has one endpoint.
- [ ] **Step 4: Update the "Rails client" section** of `docs/features/page-fetcher-service.md`: `fetch_file`'s signature, `FileResponse`'s fields and `inflated`, `file_too_large` as an upstream code, and that pacing and retries remain the caller's job.
- [ ] **Step 5: Run** `bin/rails test && bundle exec standardrb`, then from `data-sources/` `uv run pytest && uv run ruff check . && uv run ruff format --check .`. Expected: all PASS, and no new warning lines in the Rails output.
- [ ] **Step 6: Commit** `git commit -m "PageFetcher::Client#fetch_file"`.
