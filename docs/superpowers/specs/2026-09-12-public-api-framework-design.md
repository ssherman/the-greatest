# Public API framework — design

**Date:** 2026-09-12
**Status:** Approved
**Branch:** `worktree-public-api-framework`
**Builds on:** `docs/specs/membership-and-stripe-billing.md` (the paywall this sits behind),
`docs/features/domain-scoped-authorization.md` (roles the write scopes will later use)

## Summary

A versioned, JSON-only read API served on every site under `/api/v1/`, sold as a membership
benefit. This document designs the **framework** — bearer tokens, scopes, rate limits,
serialization, error format, the OpenAPI contract, service accounts for internal agents, and
the two member-facing pages — and ships the first two resources through it: books and authors,
index (rank order) and show. Search, filters, and the music and games resources follow in their
own specs on the same framework.

Three things shaped the design more than any other:

1. **The MCP server that follows will be a Python app calling this API.** Its authorization
   story is fixed by the MCP spec (OAuth 2.1), so the API's token handling, scope strings and
   error headers are chosen so that adding OAuth later is an addition, not a rewrite.
2. **Membership is single-tier and already the paywall** (`User#member?`, `MembershipGate`).
   "Pays for API access" therefore means "is a member"; nothing new is sold.
3. **The app is open source.** Token storage is designed on the assumption that the scheme, the
   code and a copy of the database are all in an attacker's hands.

## Context

### What exists

| Piece | Where | Reused as |
|---|---|---|
| Single-tier membership, `member?` | `Membership`, `MembershipGate`, `MembershipGated` | the paywall; new feature key `:api` |
| Redis-backed counter store | `config.x.rate_limit_store` | the rate limiter's store |
| Rank-ordered relations | `Books::RankedBooksQuery`, `Books::RankedAuthorsQuery` | the index queries |
| Primary ranking config | `Books::RankingConfiguration.default_primary`, `Books::Authors::RankingConfiguration.default_primary` | source of `rank` |
| CDN image URL | `direct :rails_public_blob` in `config/routes.rb` | `cover_url` / `image_url` |
| Per-domain layouts on global routes | `DomainLayout`, used by `/membership`, `/members`, `/news` | the two UI pages |
| Visitor IP behind Cloudflare | `VisitorIp` | keying the unauthenticated limiter |
| Host-constrained routing | `DomainConstraint`, `config.domains` | domain from the host |
| JSON error shape for site JS | `JsonErrorResponses` | **not** reused — the API is a separate contract (D8) |

There is no serializer layer. `jbuilder` is in the Gemfile for the site's own JSON views and
stays there.

### What is not there

- No token model of any kind; the only credential is the Firebase session cookie.
- No way for a non-browser client to authenticate: every endpoint is `ActionController::Base`
  with `allow_browser versions: :modern`, which answers `curl` with 406.
- No concept of a non-human account. `User` rows are people.
- Super Bot Fight Mode is on for all three zones and challenges "definitely automated"
  clients — a Python script is exactly that. See Rollout.

## Findings

### The MCP authorization spec constrains the API, but only lightly

Read on 2026-09-12 from the current draft
(`modelcontextprotocol.io/specification/draft/basic/authorization`):

- An MCP server over HTTP is an OAuth 2.1 **resource server**. It MUST publish RFC 9728
  Protected Resource Metadata pointing at an **authorization server**, which "may be hosted
  with the resource server or a separate entity".
- Clients MUST do authorization-code + PKCE with an RFC 8707 `resource` parameter; tokens are
  audience-bound to the MCP server. Client registration is by Client ID Metadata Documents
  (SHOULD) or Dynamic Client Registration (now deprecated, MAY).
- Bearer tokens go in `Authorization: Bearer`, never the query string. 401 carries
  `WWW-Authenticate: Bearer resource_metadata="…"` and SHOULD carry `scope="…"`; insufficient
  scope is 403 with `error="insufficient_scope"`.
- **"MCP servers MUST NOT accept or transit any other tokens."** An MCP server cannot forward
  the MCP client's token to a REST API with a different audience.

With the MCP server as a separate Python app, the compliant shape is FastMCP's `OAuthProxy`
pattern: the MCP server issues its own tokens to MCP clients and holds, per user, a token that
**Rails issued for the API**. That requires Rails to become an OAuth 2.1 authorization server
(Doorkeeper plus a small metadata controller) with one pre-registered confidential client — no
DCR, no CIMD on the Rails side. None of that is built now. What is built now so it can be
added without touching a controller:

| Requirement | Satisfied by |
|---|---|
| OAuth access tokens accepted later, same user, same scopes, same tier | one authenticator seam returning a `Principal` (D3) |
| Scope strings that become OAuth scopes | `books:read` etc. from day one (D5) |
| RFC 6750 challenge headers | 401/403 `WWW-Authenticate` shapes (D4) |
| Bearer-only, stateless | `ActionController::API`, no cookies, no CSRF (D2) |
| A contract the Python side can build from | OpenAPI 3.1 at `/api/v1/openapi.json` (D9); `FastMCP.from_openapi()` consumes it directly |

### Serializer

Current benchmarks (`cookpad/JSONSerializerBenchmarks`, Alba's own suite) put Alba and Panko
roughly tied for fastest, Blueprinter ~8% behind, jbuilder ~50% behind. Alba and Blueprinter
have near-identical DSLs and both are actively maintained; Panko is a C extension. **Alba**
(D7): fastest pure-Ruby option, traits cover the compact/full split, nothing to compile.

### Rate-limit headers

The IETF `RateLimit` / `RateLimit-Policy` fields are still an Internet-Draft (v11, May 2026;
the previous version's directorate review came back "not ready"). The de-facto
`X-RateLimit-Limit` / `-Remaining` / `-Reset` triple is what every client library understands,
and X's `x-user-limit-24hour-*` shows the established way to advertise a second, daily window
(D6).

### Contract testing

`committee` was the first choice and is ruled out: 5.6.3 pins `minitest ~> 5.3` and this suite is
on Minitest 6, so Bundler refuses it. **`openapi_first`** (3.4.x) has no Minitest pin, validates
OpenAPI 3.1 through `json_schemer`, ships `assert_api_conform` for Minitest, and reports which
documented operations no test exercised (D9).

### Token storage

GitHub PATs, GitLab tokens and Discourse API keys are all stored as SHA-256 digests and shown
once; two of the three are open source. Rails' own `has_secure_token` stores plaintext and is
not used. bcrypt is for low-entropy secrets and would add ~100 ms per API request for nothing
against a 238-bit random token (D10).

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Per-site path**: `https://thegreatestbooks.org/api/v1/books`, `…music.org/api/v1/albums`. Domain from the host. Version in the path; additive-only evolution; `v2` reserved for a redesign we hope never to do. | Composes with `DomainConstraint`, Cloudflare path rules and `Current.domain`. One token works on every site. Date-header versioning is for APIs shipping breaking changes continuously; not this one. |
| D2 | `Api::V1::BaseController < ActionController::API`. No session, no cookies, no CSRF, no `allow_browser`. | Bearer auth is stateless by definition; `allow_browser` would 406 every non-browser client. |
| D3 | One authenticator seam: `Services::Api::Authenticator.call(request)` → `Api::Principal(user, token, scopes, tier)` or a failure code. Controllers never inspect a token. | The only place that knows what a token is; Doorkeeper access tokens plug in here later. |
| D4 | RFC 6750 challenges: 401 `WWW-Authenticate: Bearer error="invalid_token"` (bare `Bearer` when no header was sent); 403 `error="insufficient_scope", scope="books:read"`. | What Python clients and MCP tooling already handle; mandatory once OAuth exists. |
| D5 | Scopes are OAuth scope strings in a registry (`Api::Scopes`): `books:read`, `music:read`, `games:read`. Hierarchy-aware (`x:write` implies `x:read`). Members may mint the three reads only. | Same strings become OAuth scopes later; a registry a reviewer can read in full, like `MembershipGate`. |
| D6 | Rate limits keyed on the **account**, two fixed windows per tier, tuned in `config/initializers/api.rb`. `X-RateLimit-*` (minute) and `X-RateLimit-Daily-*` (UTC day) on every response; `Retry-After` on 429. | Minting tokens must not multiply quota. Config, not an admin UI. The IETF header is still a draft. |
| D7 | Alba for serialization, resources under `app/lib/api/v1/<domain>/`. | See Findings. |
| D8 | Successes are `{"data": …}` (+ `meta`, `links` on collections); errors are RFC 9457 `application/problem+json` with a `code` extension. The site's `JsonErrorResponses` shape is not reused. | The public API is a separate, documented contract; RFC 9457 is the standard for it. |
| D9 | The contract is a hand-written OpenAPI 3.1 file, served at `GET /api/v1/openapi.json`, validated in every integration test by `openapi_first`; a test asserts no documented operation is untested. | Code cannot generate a good spec; tests can keep a written one honest. The Python side builds clients and the MCP server from it. |
| D10 | Secrets are `tg_` + 40 random alphanumerics; only the SHA-256 digest and a 12-character display prefix are stored; shown once; revoke is destroy. | See "Token storage and threat model". |
| D11 | A service account is a `User` with `account_kind: :service`. Sign-in cannot find it; it skips the membership check; it gets the `system` tier and admin-assigned scopes. Created by rake task. | Pundit, domain roles and (later) Doorkeeper's resource owner are all `User`; a second model means a second branch through every authorization path. |
| D12 | Lookup by slug only (`/api/v1/books/{slug}`); payloads carry `id` and `slug`. | 137 books have purely numeric slugs, so an id-or-slug route is ambiguous. |
| D13 | Author show does not embed books. `GET /api/v1/authors/{slug}/books` is the first follow-up. | An unbounded array in a show payload is the wrong shape; a paginated sub-collection is the right one. |
| D14 | Two UI pages: `/developers` (public docs, edge-cacheable) and `/developers/tokens` (members only). Linked from a card on `/members` and each site's footer. **No header nav item.** | The header is full; footer is where GitHub and Stripe keep "API"; every eligible user sees `/members`. |
| D15 | No OAuth, no `/.well-known/`, no DCR, no MCP server now. | They belong to the MCP spec and are additive to this design. |

## Design

### 1. Routing and controllers

Inside each site's existing `DomainConstraint` block, a JSON-only namespace. Books, this spec:

```ruby
namespace :api, defaults: {format: :json}, constraints: {format: :json} do
  namespace :v1, module: "api/v1/books" do
    resources :books,   only: [:index, :show], param: :slug
    resources :authors, only: [:index, :show], param: :slug
  end
end
```

Music and games later add `albums`, `artists`, `songs`, `games` in their own blocks. The
format constraint means `/api/v1/books.xml` matches no route: a routing 404 with Rails'
public 404 body, not a problem document, and not a 406. `GET /api/v1/openapi.json` is routed
for all three hosts and served by `Api::V1::OpenapiController < ActionController::API`
**outside** the authenticated base: no token, `Cache-Control: public, max-age=3600`.

**`Api::V1::BaseController < ActionController::API`** includes, in this order:

1. `CurrentDomain` — `set_current_domain` and `detect_current_domain`, **extracted from
   `ApplicationController`** into `app/controllers/concerns/current_domain.rb` and included by
   both bases. Behaviour unchanged for the site.
2. `ActionController::HttpAuthentication::Token::ControllerMethods` (not in the API base by
   default) for `authenticate_with_http_token`.
3. `Api::Authentication` — `before_action :authenticate!`; sets `current_principal`.
4. `Api::RateLimited` — `before_action :enforce_rate_limit!` after authentication; sets the
   six headers in an `after_action` on every response, including errors.
5. `Api::ErrorRendering` — `rescue_from` for the exceptions the API expects (§4). Unexpected
   exceptions are **not** swallowed: they reach Rails' handler, which answers a JSON request
   with a generic JSON 500, and they fail tests instead of hiding behind a friendly body.
6. `Cache-Control: private, no-store` on every response from this base, success or error — no
   edge or proxy ever serves a paid response to the next caller.

**`Api::V1::Books::BaseController`** declares `required_scope "books:read"`. Inside
`module Api::V1::Books` every model and query reference is root-anchored (`::Books::Book`,
`::Books::RankedBooksQuery`): a bare `Books::` resolves to `Api::V1::Books::` and raises
`NameError`. This has bitten the repo three times; the plan's controller tests exercise every
reference.

### 2. Authentication and tokens

**Header.** `Authorization: Bearer tg_…`. Nothing else is looked at: not a query parameter,
not a cookie, not a session. A request with a valid session cookie and no bearer token is
unauthenticated.

**`api_tokens`**

| column | type | notes |
|---|---|---|
| `user_id` | bigint, FK, not null, indexed | `User has_many :api_tokens, dependent: :destroy` — every user FK needs its `has_many` or admin delete-user 500s |
| `name` | string, not null | 1–60 chars, member-chosen label |
| `token_digest` | string, not null, unique | `Digest::SHA256.hexdigest(secret)` |
| `token_prefix` | string, not null | first 12 characters of the secret (`tg_` + 9), for display |
| `scopes` | string[], not null, default `[]` | validated against `Api::Scopes` and against what the owner may mint |
| `expires_at` | datetime, null | null = never |
| `last_used_at` | datetime, null | written at most once per 5 minutes via `update_column` |
| timestamps | | |

**`ApiToken`** (global namespace, like `User` and `List`):

- `ApiToken.generate(user:, name:, scopes:, expires_at: nil)` → `[record, secret]`. The secret
  is `"tg_" + SecureRandom.alphanumeric(40)` (~238 bits) and exists only in that return value.
- `ApiToken.authenticate(secret)` → record or nil. Rejects anything not matching
  `/\Atg_[A-Za-z0-9]{40}\z/` before touching the database; finds by digest; re-checks the digest
  with `ActiveSupport::SecurityUtils.secure_compare`; returns nil when expired.
- `touch_last_used!` — no-op if `last_used_at` is within the last 5 minutes.
- Validation: name presence/length; scopes non-empty, every scope known, every scope mintable
  by `user`; at most **10** tokens per user.
- Revoke = `destroy`.

**`Services::Api::Authenticator.call(request)`** returns a `Result` whose `data` is an
`Api::Principal` (`user`, `token`, `scopes`, `tier`) or whose `errors` carry one code:

| code | status | condition |
|---|---|---|
| `unauthenticated` | 401, `WWW-Authenticate: Bearer` | no `Authorization` header |
| `invalid_token` | 401, `Bearer error="invalid_token"` | malformed, unknown, or expired secret |
| `membership_required` | 403 (no challenge — re-auth would not help) | person account without `member?` |

Tier: `user.service? ? :system : :member`. The membership check runs only for `person`
accounts and only after the token resolved, so a revoked-membership token is a 403 with a
body that says why, not a 401 that looks like a typo.

**Unauthenticated failures (401) and `membership_required` (403)** are counted per visitor IP
(`VisitorIp`) in the rate limiter, 60 per minute; beyond that the answer is 429 before the
database is consulted. This bounds load from junk; it is not a defence against guessing, which
238 bits already makes futile — and that is also why the known origin-bypass hole that defeats
every IP-keyed limit in this app does not matter here.

### 3. Service accounts and scopes

**`users.account_kind`** — `enum :account_kind, {person: 0, service: 1}`, integer, not null,
default 0. A service account has:

- email `"#{name}@service-accounts.thegreatest.invalid"` — `name` matches `/\A[a-z0-9-]+\z/`,
  and `.invalid` (RFC 2606) can never resolve, so no provider can ever vouch for it;
- `role: :user`, `display_name: name`, no `auth_uid`, no `external_provider`, no membership.

It differs from a person in exactly four places, each with its own test:

1. **Sign-in cannot find it.** `Services::UserAuthenticationService#find_user` scopes both
   lookups (`auth_uid`, then trusted email) to `User.person`. This is the guard that matters: the
   email-linking path is the documented takeover route, and this makes a service account
   invisible to it rather than merely unlikely to match.
2. **`Authenticator` skips the membership check** and resolves the `system` tier.
3. **`create_default_user_lists` is skipped** — no seventeen phantom user lists.
4. **Scopes are whatever an admin assigns** — `Api::Scopes.mintable_by(user)` returns every
   scope for a service account and only the member-mintable ones for a person.

**Rake tasks** (`lib/tasks/api.rake`). Each prints the new secret and nothing else to stdout,
so the output pipes straight into the Python framework's secrets:

```
bin/rails api:service_account:create NAME=agent-runner SCOPES=books:read,music:read,games:read
bin/rails api:service_account:token  NAME=agent-runner TOKEN_NAME=prod-2 SCOPES=books:read
bin/rails api:token:revoke ID=42
```

`create` is find-or-create on the account (re-running never makes a second account) and mints
exactly one token named `TOKEN_NAME` (default `default`). `token` mints another for rotation.
An admin page for service accounts is a later increment if wanted.

**`Api::Scopes`** — one frozen hash, in the `MembershipGate` style:

| scope | grants | member-mintable |
|---|---|---|
| `books:read` | every read endpoint on the books host | yes |
| `music:read` | every read endpoint on the music host | yes |
| `games:read` | every read endpoint on the games host | yes |

`Api::Scopes.satisfies?(granted, required)` honours hierarchy so a future `books:write`
implies `books:read` with no controller change. Write scopes are not defined now; this hash is
where they land. An admin's *personal* token follows the member rules — personal tokens never
carry admin power (the GitHub convention), so write endpoints stay an explicit later decision.

A books token on the music host is a 403 `insufficient_scope` with
`WWW-Authenticate: Bearer error="insufficient_scope", scope="music:read"`. The host decides
the scope an endpoint needs; cross-site tokens work exactly as far as their scopes say.

### 4. Rate limiting

`config/initializers/api.rb`:

```ruby
Rails.application.config.x.api.rate_limits = {
  member: {per_minute: 60,  per_day: 5_000},
  system: {per_minute: 600, per_day: 200_000}
}
Rails.application.config.x.api.max_tokens_per_user = 10
```

Starting numbers, to be tuned. 5,000/day lets a member pull the whole ranked catalogue
(~1,600 pages of 100) in about a day and a half. The `system` cap is deliberately finite: it
protects Postgres from a runaway agent loop.

**`Services::Api::RateLimiter`**

- `hit(principal)` — two `increment(key, 1, expires_in:)` calls on
  `config.x.rate_limit_store`: `api:rl:<user_id>:m:<minute_start>` (60 s) and
  `api:rl:<user_id>:d:<utc_date>` (to midnight UTC). Returns limit/remaining/reset for both
  windows and whether either is exceeded. A rejected request still counts.
- `hit_unauthenticated(ip)` — `api:rl:anon:<ip>:m:<minute_start>`, 60/min.
- Keyed on the **user**, never the token.

**Headers on every API response**, success or error:

```
X-RateLimit-Limit: 60
X-RateLimit-Remaining: 57
X-RateLimit-Reset: 1789564860            # unix time the minute window resets
X-RateLimit-Daily-Limit: 5000
X-RateLimit-Daily-Remaining: 4931
X-RateLimit-Daily-Reset: 1789603200      # next 00:00 UTC
```

A 429 adds `Retry-After: <seconds>` and a problem body naming the exhausted window.

An **unauthenticated** response (401, the `membership_required` 403, or the 429 from the IP
window) has no principal and therefore no daily window: it carries only the minute triple,
describing the IP window (limit 60).

### 5. Response format

**Envelope.** `{"data": …}` on success; collections add `meta` and `links`. Keys `snake_case`,
timestamps ISO 8601 UTC, ids integers. Every URL is absolute and built from
`Rails.application.config.domains[Current.domain]` (first host if comma-separated) with
`port: nil` — never from `request.host`, which is attacker-supplied in production.

```json
{
  "data": [ … ],
  "meta":  {"page": 2, "per_page": 50, "total_count": 24810, "total_pages": 497},
  "links": {"self": "…/api/v1/books?page=2", "next": "…?page=3", "prev": "…?page=1",
            "first": "…/api/v1/books", "last": "…?page=497"}
}
```

**Pagination.** `page` (integer ≥ 1, default 1), `per_page` (1–100, default 50). Non-integer or
out-of-range → 400 `invalid_parameter`. A page past the last returns 200 with `data: []` and
truthful `meta` — what an iterating client expects, and the same empty-page behaviour Pagy
gives the site. The API does its own parsing (`Api::Page`) rather than going through Pagy's
controller helper, which reads the page from the request and cannot answer 400.

**Errors.** RFC 9457, `Content-Type: application/problem+json`, built in one place
(`Api::Problem`):

```json
{"type": "https://thegreatestbooks.org/developers#errors-rate_limited",
 "title": "Rate limit exceeded", "status": 429, "code": "rate_limited",
 "detail": "Per-minute limit of 60 requests reached. Retry after 23 seconds."}
```

| `code` | status | raised by |
|---|---|---|
| `unauthenticated` | 401 | no header |
| `invalid_token` | 401 | malformed / unknown / expired |
| `membership_required` | 403 | person account, no active membership |
| `insufficient_scope` | 403 | scope check |
| `not_found` | 404 | `ActiveRecord::RecordNotFound`, i.e. an unknown slug (a wrong format never reaches a controller — see §1) |
| `invalid_parameter` | 400 | pagination params, `ActionController::ParameterMissing` |
| `rate_limited` | 429 | either window, or the unauthenticated IP window |

`type` points at the anchor on this host's `/developers` page. Anything else is Rails' generic
JSON 500 and a failing test.

**Serialization.** Alba resources in `app/lib/api/v1/books/`: `Api::V1::Books::BookResource`
and `AuthorResource`, each with a `:full` trait for show. `rank` comes from the site's default
primary ranking configuration (`primary_ranked_item` on show; the `RankedItem` row on index)
and is `null` for an unranked record reached via show.

### 6. The v1 resources

**`GET /api/v1/books`** — `::Books::RankedBooksQuery.call(ranking_configuration: default_primary)`,
paginated, with the includes the compact resource needs (`item: [{book_authors: :author},
{primary_image: {file_attachment: :blob}}]`). Query count pinned with `assert_queries_count`.

**`GET /api/v1/books/{slug}`** — `::Books::Book.find_by!(slug:)` (never `friendly.find`), with
the includes the full resource needs.

Book, compact (index): `id`, `slug`, `title`, `subtitle`, `first_published_year`, `rank`,
`authors[{id, slug, name}]`, `cover_url` (CDN via `rails_public_blob_url`, `null` if none),
`url` (`https://<host>/book/<slug>`), `api_url`.

Book, full (show) adds: `sort_title`, `alternate_titles`, `book_kind`, `book_length`,
`page_range`, `word_count`, `description` (`primary_description(kind: :summary)&.content`),
`original_language{id, slug, name}`, `categories[{id, slug, name, category_type}]`,
`countries[{id, slug, name}]`.

**`GET /api/v1/authors`** — `::Books::RankedAuthorsQuery` on
`::Books::Authors::RankingConfiguration.default_primary`; when that is nil (no author ranking
yet) the index is a 200 with empty `data` and `total_count: 0`, matching the site.

**`GET /api/v1/authors/{slug}`** — `::Books::Author.find_by!(slug:)`.

Author, compact: `id`, `slug`, `name`, `sort_name`, `birth_year`, `death_year`, `rank`,
`image_url`, `url` (`https://<host>/author/<slug>`), `api_url`.
Author, full adds: `alternate_names`, `kind`, `description`.

### 7. The OpenAPI contract

`web-app/config/api/v1/openapi.yaml`, OpenAPI 3.1, hand-written, committed. Served as JSON at
`GET /api/v1/openapi.json` on every host with `servers` set to that host. It documents
`securitySchemes.bearerAuth`, all four operations, `Book`/`BookFull`/`Author`/`AuthorFull`,
`Problem`, the pagination parameters, and the six rate-limit headers as response headers.

`openapi_first` in the `:test` group. Every API integration test ends in
`assert_api_conform(status: …)`, which validates request and response against the document:
an undocumented field, a wrong type, a `null` the schema forbids, or an error body in the wrong
shape fails the test. One test asserts the coverage report lists no unexercised operation, so
a new endpoint cannot land without both a doc entry and a test.

### 8. The member-facing pages

Both are global routes constrained to the three real hosts (the `/news` pattern), rendered in
the host's layout through `DomainLayout`.

**`GET /developers` — public documentation.** Identical HTML for every visitor; edge-cacheable
like any content page. Sections in order: what the API is and that it is a membership benefit
(link to `/membership`); a quick start with a working `curl` and a six-line Python `requests`
example; authentication (create a token, shown once, keep it in an environment variable,
revoke if leaked, works on all three sites); the rate-limit table and the six headers; the
endpoint reference for *this* host, rendered in ERB from the OpenAPI document so it cannot
drift, with a link to `/api/v1/openapi.json`; pagination; the error table with
`#errors-<code>` anchors; the versioning promise (additive-only, `v1` stays). Copy goes
through the `avoid-ai-writing` pass before it ships.

**`GET /developers/tokens` — manage tokens.** `require_membership!(:api)` with a new
`MembershipGate::FEATURES[:api]` entry; never cached. A non-member is redirected to
`/membership` with the existing message. The page lists the member's tokens — name, prefix,
scopes, created, last used, expires — with a revoke button per row, and a create form: name,
the three scope checkboxes (all checked), an expiry select (never / 30 / 90 / 365 days).

- `POST /developers/tokens` answers with a **Turbo Stream in both outcomes** — Turbo Drive
  rejects a 200 HTML page as a form response, and a redirect would put the secret in a URL or
  the flash, so the page is never re-rendered on success. Success: a stream that replaces the
  form with the new secret in a panel that says in words and with an icon, not by colour
  alone, that this is the only time it will be shown, plus a copy button, and appends the
  token's row to the list. Failure: a stream that replaces the form with its errors. Public
  layouts render no flash, so every message lives in the page.
- `DELETE /developers/tokens/:id` → destroy, Turbo Stream removes the row.
- Every input has a real label or `aria-label`; a fieldset legend does not label an input.

**Links in:** a card on `/members`; an "API" entry in each site's footer. The header nav is
untouched (D14).

### 9. Token storage and threat model

Only the SHA-256 digest of a secret is stored. This is the scheme GitHub, GitLab and Discourse
use, and its security does not depend on the scheme being private: what an attacker learns
from the source is that they need a SHA-256 preimage of a 238-bit random string.

| Vector | Mitigation |
|---|---|
| Database copy | Names, prefixes, scopes, digests. No digest reverses; no forged digest is insertable without write access, at which point the database is already theirs. |
| Brute force | 40 alphanumerics ≈ 238 bits. Fast hashing is correct for this; bcrypt would add ~100 ms per request for nothing. |
| Logs | Rails does not log request headers; `token` is already in `filter_parameters`; the rake tasks print only the secret; the create flow returns the secret in a Turbo Stream body, never in a URL or the flash. |
| Display prefix in plaintext | `tg_` + 9 known of 43 leaves ~184 bits unknown. |
| Timing | A B-tree lookup on a 256-bit digest is not a practical oracle; `secure_compare` on the found digest costs nothing and is in. |
| Transport | Bearer tokens are as safe as TLS; all three hosts are HTTPS-only behind Cloudflare. |
| Blast radius | A token cannot sign in to the site; a member's scopes are read-only. A leaked member token reads public data on someone else's quota. Service accounts with broader scopes are why `expires_at` and the rotation task exist from day one. |

Not done, deliberately: HMAC with a server-side pepper (GitLab). It only helps if the RNG is
weaker than believed, and rotating the pepper invalidates every token.

## Testing

All Minitest + fixtures + Mocha, mirroring `app/`. Fixtures need a member with a token, a
member with an expired token, a non-member with a token, and a service account — a corpus
with a negative class, not just the happy path.

- **Models.** `ApiToken`: `generate` returns the secret once and stores only the digest;
  `authenticate` rejects unknown, expired and malformed secrets and never queries on a malformed
  one; scope validation against the registry and against `mintable_by`; the 10-token cap;
  `touch_last_used!` throttling. `User`: `account_kind`, the skipped default-lists callback,
  service email shape.
- **Services.** `Authenticator`: one test per failure code; service-account membership bypass;
  tier resolution. `RateLimiter`: both windows, the boundary, reset timestamps, a rejected request
  still counting, tiers read from config, the unauthenticated IP window. `Scopes`: hierarchy,
  unknown scope, `mintable_by` for person and service.
- **Sign-in guard.** A service account is invisible to `UserAuthenticationService#find_user`
  by uid and by trusted email; a person with the same values is found.
- **Controllers / integration.** 200 shapes for all four endpoints; 401/403/404/400/429 shapes
  and headers; `WWW-Authenticate` on 401 and 403; the six rate headers on every authenticated
  response including errors, the minute triple alone on 401; `Cache-Control: private, no-store`; a books token on the music host → 403;
  a session cookie without a bearer token → 401; pagination edges (0, 101, `abc`, past the
  end); `.xml` → 404; `assert_queries_count` on both indexes; `openapi.json` is public and
  cacheable; `assert_api_conform` on every one of these; coverage report empty.
- **Rake tasks.** Each creates what it says, prints exactly one line, and `create` is
  find-or-create on the account.
- **UI.** Integration tests for both pages: redirect for anonymous and non-member;
  create/revoke status codes and effects; the cap; no HTML, CSS or copy assertions.
- **E2E (Playwright, `e2e/tests/books/`).** Anonymous sees `/developers`. The E2E member
  creates a token, sees the secret exactly once, calls `GET /api/v1/books` with it through the
  `request` fixture and gets 200 with rate headers, revokes it, and the same call gets 401. The
  E2E account needs a membership in the seed; a rake task alongside `e2e:admin` provides it.
- `CI=1 bin/rails zeitwerk:check` for the new `app/lib/api` tree; `bundle exec standardrb`;
  a clean run adds no warning lines.

## Rollout

**Edge, per zone (books, music, games) — Shane, before the first production call:**

1. A custom rule matching `starts_with(http.request.uri.path, "/api/")` with action
   *Skip → Super Bot Fight Mode*, placed **above** the comma / `/rc/` / `.csv` challenge rules
   so a future filter parameter containing a comma is not challenged. Log-first: create it as
   *Log* for a day and confirm it matches only `/api/` traffic before switching to Skip. Rule
   changes here have cost real revenue before.
2. Confirm no host-scoped cache rule that overrides origin headers covers `/api/`. Responses are
   `private, no-store`, which Cloudflare honours by default. `/api/v1/openapi.json` is the one
   path that should cache.
3. After deploy, from outside: `curl -A python-requests/2.32 https://thegreatestbooks.org/api/v1/books`
   must be a 401 with `WWW-Authenticate: Bearer`, not a challenge page.

**Migrations.** `api_tokens` (new table) and `users.account_kind integer NOT NULL DEFAULT 0`
(non-rewriting on Postgres 11+). Both run against a production snapshot first: a failing
migration is an outage on live music and games.

**Secrets.** None added to SOPS. Service-account tokens live in the Python framework's own
secrets.

## Increments

Each is its own PR, green on `bin/rails test` and `standardrb` before the next starts.

1. **Framework + books + service accounts.** Migrations; `ApiToken`; `account_kind` and the
   sign-in guard; `Authenticator`, `Scopes`, `RateLimiter`, `Problem`; `CurrentDomain`
   extraction; base controllers; Alba resources; `GET /api/v1/books` and `/books/{slug}`;
   `openapi.yaml` + `openapi_first` + coverage test; the three rake tasks. Books is here
   because the framework must be tested through a real endpoint.
2. **Authors.** Index and show, doc entries, tests.
3. **Pages.** `/developers`, `/developers/tokens`, `MembershipGate[:api]`, the `/members`
   card, footer links, the E2E membership seed, the Playwright spec.

## Out of scope (own specs, likely order)

- `GET /api/v1/authors/{slug}/books` (D13).
- Search — `GET /api/v1/books/search?q=` on `Books::BookSearchQuery`.
- Filters on the index — `category`, `country`, `year_start`, `year_end`; `RankedBooksQuery`
  already takes them.
- Music and games resources.
- An admin page for service accounts.
- Doorkeeper, RFC 8414 / 9728 metadata, the pre-registered MCP client — when the Python MCP
  server needs OAuth.
- Write and admin scopes.

## Open items

- The exact member numbers in `config.x.api.rate_limits` are a product call; the defaults above
  are a starting point.
- Whether `/membership`'s benefits copy mentions the API is a copy call.
