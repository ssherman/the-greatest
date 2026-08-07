# Cloudflare challenge hand-off for Turbo fetches

**Date:** 2026-08-07
**Status:** approved, ready for planning

## Problem

Applying a second genre in the books filter modal did nothing. The console showed:

```
GET https://new.thegreatestbooks.org/the-greatest/fantasy,science-fiction/books 403 (Forbidden)
  fetchWithTurboHeaders -> perform -> start -> submitForm -> formSubmitted
```

The 403 is not ours. Response headers on that URL:

```
HTTP/2 403
cf-mitigated: challenge
server: cloudflare
<title>Just a moment...</title>
```

It is a Cloudflare managed challenge. Confirmed by hand: navigating to the same URL in Chrome produced
the "confirm you are human" interstitial, and after solving it multi-genre filtering worked correctly.

The books filter feature is not defective. `Books::FilterPath#slugs` sorts and joins slugs correctly,
the `the-greatest/:category_id/books` route matches a comma, `Books::FilterParams#resolve` splits on
`,` and resolves both slugs, and `test/controllers/books/ranked_items_controller_test.rb:151` already
asserts a 200 for a two-genre path. Nothing in Rails returns 403 here.

What turns a solvable challenge into a dead button is that Apply is a Turbo form submission, so it
travels over `fetch()`:

```erb
<%# app/components/books/filter_facets_component.html.erb:1 %>
<%= form_with url: books_filters_path, method: :get, data: {turbo_frame: "_top"} do %>
```

A challenge page has to be rendered and solved by the browser. It cannot be delivered to a `fetch()`,
so Cloudflare answers with a bare 403 and Turbo silently discards it — no error, no navigation, no
feedback. A real navigation gets the interstitial and succeeds.

Cloudflare documents this failure mode explicitly: "Challenge Pages interrupt the request flow by
returning a full HTML page for the user's browser to render and solve, but this mechanism fails when
the browser expects a non-HTML response, such as an AJAX or XHR (fetch) request."

The comma was a coincidence of timing. Challenges are issued per visitor and hostname, not per path,
so this is not a multi-select bug — it can strike any async request. Strict challenges are applied
deliberately to certain countries and service providers, so the challenge itself stays; the client has
to cope with it.

## Prior art

- [Detect a Challenge Page response](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/)
  — Cloudflare's official detection signal is `cf-mitigated: challenge`, checked exactly as we intend to.
- [Integrating Turnstile with the Cloudflare WAF to challenge fetch requests](https://blog.cloudflare.com/integrating-turnstile-with-the-cloudflare-waf-to-challenge-fetch-requests/)
  — the heavyweight remedy: a Turnstile widget with pre-clearance resolves the challenge in an overlay
  and retries the original request in place. Rejected below.
- [Handle WAF challenge response to AJAX request via client-side](https://community.cloudflare.com/t/handle-waf-challenge-response-to-ajax-request-via-client-side/575105)
  — the lightweight remedy the community converges on: hand off to a real navigation so the
  interstitial renders. This is the approach taken here.

No Turbo-specific solution has been published, so the wiring is ours.

Two adjacent Hotwire/Cloudflare landmines, noted but explicitly **out of scope**:
[Rocket Loader is incompatible with Turbo](https://github.com/hotwired/turbo/issues/1104), and
[Cloudflare strips 4xx response bodies](https://jetthoughts.com/blog/why-your-form-submission-fails-hotwire-cloudflare-missing-validation-messages-rails/),
which breaks 422 form-validation rendering.

## Verified facts

Checked against the installed `@hotwired/turbo-rails` 8.0.16, not from memory:

- `FetchResponse#header(name)` exists — `node_modules/@hotwired/turbo/dist/turbo.es2017-esm.js:639`.
- `turbo:before-fetch-response` is `cancelable`, and `preventDefault()` genuinely stops Turbo handling
  the response — `:823`.
- Turbo's `dispatch` sets `bubbles: true`, so one document-level listener would see every event — `:245`.
- `cf-mitigated` is readable from page JS. Verified empirically with a headless Chromium probe against
  production: a same-origin page-context `fetch()` read `cf-mitigated: challenge`. Same-origin
  responses expose all headers, so no CORS exposure problem.
- Turbo reaches the global by property lookup **at call time** — `return window.fetch(url, {...})` at
  `:668` — so patching `window.fetch` after `import "@hotwired/turbo-rails"` still intercepts Turbo.
  Nothing captures a bare `fetch` reference at module-evaluation time.
- Turbo's `FetchMethod` values are **lowercase** (`get`, `post`, `put`, `patch`, `delete`) — `:689`.
  Case-insensitive method comparison is therefore load-bearing, not merely defensive: a `===  "GET"`
  check would misroute every Turbo GET into the reload branch.
- Every domain layout loads `application.js`, and books loads *only* that bundle
  (`app/views/layouts/books/application.html.erb:19`). One import there reaches all four sites.
- Playwright is the only JS test harness in the repo. There is no jest/vitest.

## Approach

**Wrap `window.fetch` globally.** Turbo calls `window.fetch`, so a single wrapper sits upstream of
Turbo Drive visits, form submissions, and lazy frame loads — and also covers the eleven hand-rolled
`fetch()` calls in the user-list modals, autocomplete, and auth services, all of which have the
identical silent-death bug today. One chokepoint, no call sites touched.

Rejected alternatives:

- **A `turbo:before-fetch-response` listener.** Uses a supported public API rather than patching a
  global, but covers only Turbo traffic. The hand-rolled fetches would keep failing silently and need
  a second mechanism later.
- **Turnstile pre-clearance.** The only option that preserves in-flight form state, but it needs a
  third-party widget on every public page, dashboard configuration, and retry logic. Overkill for a
  filter navigation.

## Design

### Scope

No changes to application Ruby, and no Cloudflare configuration changes — the country and
service-provider challenge rules stay as they are. `Books::FilterPath`, `Books::FilterParams`, the 80
filter routes, and `Books::FilterFacetsComponent` are untouched; they were never wrong. The fix is one
new JS module. Everything else in this spec is test coverage, including one new Ruby controller test.

### The module

New `app/javascript/services/cloudflare_challenge.js`, imported from `app/javascript/application.js`
immediately after `import "@hotwired/turbo-rails"` so it is installed before Turbo issues any request.

```js
const originalFetch = window.fetch.bind(window)

window.fetch = async (input, init) => {
  const response = await originalFetch(input, init)
  if (response.headers.get("cf-mitigated") !== "challenge") return response

  if (handOffToNavigation(response.url, methodOf(input, init))) {
    return new Promise(() => {})   // the document is being replaced
  }
  return response
}
```

`methodOf(input, init)` reads `init?.method` first, then `input.method` when `input` is a `Request`,
and defaults to `GET`. It compares case-insensitively.

`handOffToNavigation(url, method)` returns whether it took over:

- **GET or HEAD** → `window.location.assign(url)`. Cloudflare renders the interstitial for a real
  navigation and, once solved, serves the URL the visitor actually asked for. For the reported bug
  that means Apply lands on `/the-greatest/fantasy,science-fiction/books` after verification, so the
  flow completes rather than restarting.
- **Any other method** → `window.location.reload()`. A POST endpoint cannot be replayed as a GET
  navigation, so clearance is obtained on the page the visitor is already on and they retry. Unsaved
  form input is lost; this is an accepted cost, given challenges are rare and the alternative
  (a notification UI the public books site does not have) is more machinery than the case warrants.

Returning a never-settling promise is deliberate. Turbo's `FetchRequest#perform` awaits it, so
`turbo:before-fetch-response` never fires and Turbo never gets the chance to discard a 403 or render
challenge HTML under a mismatched CSP nonce. Turbo's progress bar stays up while the browser
navigates, which reads correctly as loading. `requestFinished` is skipped, which is harmless because
the document is being replaced.

### Loop guard

An unsolvable challenge — a blocked clearance cookie, a privacy extension, a misconfigured rule —
would otherwise reload forever, which presents as a dead site and burns requests.
`handOffToNavigation` records `{url, at}` in `sessionStorage` and declines to navigate (returning
`false`, letting the response through to fail exactly as it does today) when the **same URL** was
already handed off within **30 seconds**.

Keying on URL rather than on time alone is load-bearing. Solving a challenge and then immediately
having a *different* request challenged — landing on a page, then its lazy `/filters/options` frame —
is legitimate and must still hand off. Only the same URL repeating within the window is a loop.

## Testing

Challenges are synthesized with `page.route()` rather than depending on Cloudflare's live behavior,
which is both deterministic and faster. The `books` Playwright project runs unauthenticated against
`dev-new.thegreatestbooks.org` and matches `books/(?!admin/)(?!account/).*`, so the new spec needs no
auth setup.

New `e2e/tests/books/cloudflare-challenge.spec.ts`:

1. **A challenged GET navigates to the challenged URL.** Open the filter modal, intercept the filter
   navigation and fulfill it with `status: 403`, `headers: {"cf-mitigated": "challenge"}`, and a stub
   interstitial body. Assert the browser performs a top-level navigation to the challenged URL and the
   stub renders — the visitor sees the challenge instead of a dead button.
2. **The same URL does not hand off twice inside the window.** Seed `sessionStorage` with a hand-off
   record for the target URL stamped a few seconds ago, then trigger the same challenged GET. Assert
   the page URL does not change — the guard declined, and the response fell through.
3. **A challenged POST reloads the current URL** instead of GETting the POST endpoint. Inject a
   synthetic Turbo form with `page.evaluate`, intercept its endpoint, and assert the reload. This
   avoids needing an authenticated user-list flow.

Extended `e2e/tests/books/filters.spec.ts` — **the coverage gap that let this reach production.** The
suite covers applying a *first* genre (`filters.spec.ts:32`) but never adds a second on top of an
applied one, which is exactly the motion that surfaced the bug:

4. **Applying a second genre keeps the first.** Go to `/the-greatest/novels/books`, open the modal,
   check a second genre, Apply, and assert the URL is the sorted two-slug path with two chips.

Extended `test/controllers/books/ranked_items_controller_test.rb`:

5. **A two-genre path renders both chips.** `Books::FilterFacetsComponent#preserved_categories` and
   `#genre_options` can each emit a field for the same slug, and today only `FilterParams`' `.uniq`
   prevents a duplicate reaching the path builder. Pin it.

`bin/rails test` and `bundle exec standardrb` must pass. `yarn build:all` must be run, since the JS
bundle is committed to `app/assets/builds/`.

## Out of scope

- Any Cloudflare dashboard change.
- Turnstile, pre-clearance, and in-place request retry.
- Preserving form state across a challenge.
- Converting the eleven hand-rolled `fetch()` call sites to a shared helper. The global wrapper
  already covers them; refactoring them is unrelated cleanup.
- Rocket Loader and the stripped-4xx-body 422 issue linked above.
