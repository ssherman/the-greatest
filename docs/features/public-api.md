# Public API

Spec: `docs/superpowers/specs/2026-09-12-public-api-framework-design.md`. Code is the source of truth; this page is the map.

## Shape

- Per-site path, JSON only: `https://thegreatestbooks.org/api/v1/books`, `/api/v1/books/{slug}`. The domain comes from the host. Music and games resources are later increments.
- Contract: `web-app/config/api/v1/openapi.yaml`, served at `GET /api/v1/openapi.json` (public, cached an hour). Path items carry `x-domain`, and the served document keeps only the paths routed on the host it was fetched from — the music host's copy does not advertise `/api/v1/books`. Every API integration test validates against it (`assert_api_conform`), and `test/integration/api/v1/contract_coverage_test.rb` fails if a documented response is not exercised.
- Envelope `{"data": …}`; collections add `meta` and `links`. Errors are RFC 9457 `application/problem+json` with a stable `code` (`Api::Problem`).

## Authentication

`Authorization: Bearer tg_…`. Tokens are `ApiToken` rows storing only a SHA-256 digest; the secret is shown once (`Services::Api::Tokens.generate`, which with `authenticate` and `record_use` owns the token lifecycle; the model holds only validations). `Services::Api::Authenticator` is the only code that inspects a token; it yields an `Api::Principal` (user, token, scopes, tier). A person needs an active membership (`User#member?`); a service account (`User#account_kind == service`) does not and gets the `system` tier.

Failures follow RFC 6750: 401 `WWW-Authenticate: Bearer` / `Bearer error="invalid_token"`; 403 `membership_required` (no challenge); 403 `Bearer error="insufficient_scope", scope="…"`.

## Scopes

`Api::Scopes` — `books:read`, `music:read`, `games:read`. Members may mint the three reads; service accounts get whatever an admin assigns. `Api::V1::<Domain>::BaseController` declares `require_scope`. Hierarchy (`x:write` implies `x:read`) is already honoured for when write scopes exist.

## Rate limits

`config/initializers/api.rb`. Keyed on the account, two fixed windows (calendar minute, UTC day), counted by `Services::Api::RateLimiter` on `config.x.rate_limit_store`. Headers on every authenticated response: `X-RateLimit-Limit/Remaining/Reset` and `X-RateLimit-Daily-Limit/Remaining/Reset`; 429 adds `Retry-After`. Unauthenticated failures count per visitor IP (minute window only).

## Service accounts

```
bin/rails api:service_account:create NAME=agent-runner SCOPES=books:read,music:read,games:read
bin/rails api:service_account:token  NAME=agent-runner TOKEN_NAME=prod-2 SCOPES=books:read
bin/rails api:token:revoke ID=42
```

Each prints only the secret. `Services::UserAuthenticationService` scopes every lookup to `User.person`, so a service account can never sign in or be linked.

## Edge (Cloudflare)

The rules live in the `the-greatest-cloudflare` repo (managed with `cfrules`) — that is the
source of truth; this section only records what they must do and why.

- **Skip Super Bot Fight Mode AND Cloudflare rate limiting** for
  `starts_with(http.request.uri.path, "/api/")`. SBFM alone is not enough: the books zone
  has an edge rate limit of 20 requests per 30 s with a managed challenge, below the API's own
  60/min (member) and 600/min (system) — Cloudflare would challenge a member at their
  permitted rate, and a challenge is a block for an API client. The rule also skips the
  bad-ASN and country challenge rules (`ruleset: current`) for the same reason; auth plus the
  per-IP 401 window (`Services::Api::RateLimiter`) gate the API instead.
- **Scoped to the API-serving host.** The books zone also fronts the legacy site (apex,
  `www`), which has no `/api/`; the rule applies to `new.thegreatestbooks.org` only. Music and
  games are zone-wide, and answer Rails' 404 on `/api/` until their resources ship.
- A skip rule has no log mode and `starts_with("/api/")` cannot over-match, so there is no
  log-first step.
- **Verified 2026-09-14** with a scripted user agent through Cloudflare: `GET
  https://new.thegreatestbooks.org/api/v1/books` → 401 with `WWW-Authenticate: Bearer` and
  `X-RateLimit-Limit: 60`.
- **Caching:** API responses are `private, no-store`, so nothing edge-caches them.
  `/api/v1/openapi.json` sends `public, max-age=3600` but is served `DYNAMIC` today because
  `new.thegreatestbooks.org` has no Cloudflare cache rule at all (books' cache-everything
  covers apex and `www` only). Pre-existing, affects the new site's HTML too, and worth fixing
  before books launches — not an app bug.

## Not yet

`/developers` and `/developers/tokens` (increment 3), authors (increment 2), search, filters, music/games, OAuth/MCP.
