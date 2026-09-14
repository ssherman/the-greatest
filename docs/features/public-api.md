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

## Deploy prerequisites (edge)

Per zone: a Cloudflare custom rule `starts_with(http.request.uri.path, "/api/")` → Skip Super Bot Fight Mode, above the comma/`/rc/`/`.csv` challenge rules, created as Log first. Confirm no cache-everything rule covers `/api/`. Verify from outside with a non-browser user agent: `GET /api/v1/books` must be a 401 with `WWW-Authenticate`, not a challenge page.

## Not yet

`/developers` and `/developers/tokens` (increment 3), authors (increment 2), search, filters, music/games, OAuth/MCP.
