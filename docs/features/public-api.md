# Public API

Spec: `docs/superpowers/specs/2026-09-12-public-api-framework-design.md`. Code is the source of truth; this page is the map.

MCP: `docs/features/mcp-server.md`. Every operation with an `x-mcp` block is also an MCP tool.

## Shape

- Per-site path, JSON only: `https://<books host>/api/v1/books` (`/developers` prints the real host), `/api/v1/books/{slug}`, `/api/v1/authors`, `/api/v1/authors/{slug}`. The domain comes from the host. Indexes are the site's primary ranking, best first; when there is no primary author ranking yet `/api/v1/authors` is a 200 with empty `data`. Lookup is by slug only, and author show does not embed books; an author's books are `/api/v1/authors/{slug}/books` (below). Music and games resources are later increments. `/api/v1/ranking_configurations` lists the global book rankings (primary first; `kind` is `books` for all of them today), `/api/v1/ranking_configurations/{id}` shows one, and `/api/v1/ranking_configurations/{id}/books` is `/api/v1/books` on that configuration — the same action, resolved from the path, with `rank` relative to it. Only global, unarchived book configurations are addressable; a member's own, an archived one, or the authors configuration is a 404. Configurations are the first resource looked up by integer id (lists have no slug either); a non-numeric id is a routing 404, an unknown one the `not_found` problem. `/api/v1/lists` is the primary configuration's active lists, heaviest first unless `sort=newest` (it also takes `q`; see "Discovery, lists and configuration reads"), and `/api/v1/ranking_configurations/{id}/lists` the same rows on the named configuration — `weight` is always relative to the configuration the row was read through; `/api/v1/lists/{id}` answers for any active list with its weight on the primary or `null`. `/api/v1/lists/{id}/items` is the list's books in the site's order (`position` ascending, unpositioned rows last, then id), restricted to rows that resolve to a book so `total_count` matches the rows and equals the list's `item_count`; `/api/v1/books/{slug}/lists` is the other side, every active list a book is on with its `position`, weighted lists first. Lists have no slug and are addressed by integer id. The list payload carries no editorial flags and no weight breakdown; a list's `source_url` is the original list on the web and is not validated as a URI (a few hold more than one address). Spec: `docs/superpowers/specs/2026-09-20-public-api-lists-and-rankings-design.md`.
- Contract: `web-app/config/api/v1/openapi.yaml`, served at `GET /api/v1/openapi.json` (public, cached an hour). Path items carry `x-domain`, and the served document keeps only the paths routed on the host it was fetched from — the music host's copy does not advertise `/api/v1/books`. Every API integration test validates against it (`assert_api_conform`), and `test/integration/api/v1/contract_coverage_test.rb` fails if a documented response is not exercised.
- Pages: `GET /developers` is the documentation, on every site, edge-cached for a day and rendered from the host's OpenAPI document (so it lists only that host's endpoints; every `Api::Problem` code has an `#errors-<code>` anchor there, which is what a problem's `type` URI points at). `GET /developers/tokens` is where a member creates and revokes tokens (`MembershipGate[:api]`, never cached). Create answers with a Turbo Stream that carries the secret exactly once; a revoke refreshes the list and form but never the secret panel. The two write actions answer only in Turbo Streams, by design; there is no JS-off fallback. Links in: the `/members` card and each footer's "API" entry. There is no header nav item, on purpose. `/developers` is cached for a day and `/api/v1/openapi.json` for an hour, so after a contract change the docs page can trail the served contract by up to about 25 hours.
- Envelope `{"data": …}`; collections add `meta` and `links`. Errors are RFC 9457 `application/problem+json` with a stable `code` (`Api::Problem`).

## Author books and similar books

Plan: `docs/superpowers/plans/2026-11-06-public-api-web-parity-increment-2.md` (increment 2).

- **Author books.** `GET /api/v1/authors/{slug}/books` (`Api::V1::Books::AuthorBooksController`) and `GET /api/v1/ranking_configurations/{id}/authors/{slug}/books` (the same action with `rank` relative to that configuration). Both go through `Books::AuthorBooksQuery`, which the web author page and all-books page also use, so the three cannot disagree. Authored role only (books the author only edited are left out) and catalog books only. Ranked books come first in rank order, then unranked ones (`rank` null) by first publication year, then title. Normal paginated envelope. An unknown or provisional author is a 404; so is an archived, member-owned, authors or unknown configuration.
- **Similar books.** `GET /api/v1/books/{slug}/similar?limit=` (`Api::V1::Books::SimilarBooksController`, over `Services::Books::SimilarBooks`). `limit` is 1 to 25, default 10. It is a top-N, not a paginated list: the body is `{data, meta: {more_available}}` with no `links`. Most similar first, at most two books per author, each with its primary-ranking `rank`. `meta.more_available` is true when more similar books may exist beyond this response (the code is `qualified.size > limit || hits.size >= requested_hit_count`, so at `limit=25` it can be true even though the site would not show more).
- **`raise_on_failure`.** `SimilarBooks.call(book, raise_on_failure: true)` re-raises a failed search instead of answering an empty success. The API passes it so a search outage is a 503 `search_unavailable`, not an empty list; the book page leaves it off and keeps its silent empty card. It is the service's own option and never reaches the similarity query.
- **`.catalog` in `load_books`.** `SimilarBooks` loads only catalog books, so a stale index entry can no longer surface a provisional book. This applies to the book page as well as the API.
- **Author search.** `GET /api/v1/search/authors?q=` (`Api::V1::Books::AuthorSearchesController`). Catalog authors only, best match first, with `rank` from the primary author ranking (null when unranked), at most 100 hits. Book and author search share one `q` parser and the 503 mapping in `Api::SearchBacked` (`app/controllers/concerns/api/search_backed.rb`).
- **MCP.** These are the tools `search_authors`, `list_author_books`, `list_ranking_configuration_author_books` and `list_similar_books`; the order rules in the MCP usage copy name them.

## Discovery, lists and configuration reads

Plan: `docs/superpowers/plans/2026-11-06-public-api-web-parity-increment-3.md` (increment 3). It closes the gap between the website's browse pages and the API: finding the slugs the filters take, searching and ordering lists, and reading a book or a list through a ranking configuration.

- **Category search.** `GET /api/v1/search/categories?q=&type=` (`Api::V1::Books::CategorySearchesController`, over `Books::BrowseQuery.search`, the site's category search). `q` is required, 2 to 100 characters once stripped; missing, blank, too short, too long or sent as an array is a 400. Matches are categories of every type by name or alternative name, ordered first by name-match quality (exact name, name prefix, a word in the name starts with it, name contains it, alternative name only; `Books::BrowseQuery.name_match_quality_sql`). Within each tier `type` (`genre`, `audience`, `location`, `subject`) puts that type's matches first and does not filter the rest out, so with `type=subject&q=war` a genre named exactly "War" still comes before a subject "War crimes"; without `type`, genre comes first within each tier, as on the site, then more ranked books, then name. Only categories with ranked books on the primary ranking come back, and `book_count` counts those ranked books. Subjects and locations with only a handful of ranked books (`browse_min_category_books`, 5 today) are left out, as on `/api/v1/categories`, so a small subject can legitimately return nothing. A query yields at most 60 matches: the controller loads them first and pages that fixed set, so `total_count` never exceeds 60 and paging stops there. The paging links carry `q` and `type`. With no primary ranking the answer is empty.
- **Countries.** `GET /api/v1/countries?sort=` (`Api::V1::Books::CountriesController`). The countries that have ranked books on the primary ranking, with the slug that `country_id` accepts. `sort` is `book_count` (most books first, the default) or `name`; anything else is a 400. A country with no ranked books is left out, and so is "unknown". Each row has exactly `slug`, `name`, `book_count` (ranked books on the primary) and `url`, the site's ranked page for that country. With no primary ranking, `data` is empty.
- **Lists: `sort` and `q`.** Both apply to `GET /api/v1/lists` and `GET /api/v1/ranking_configurations/{id}/lists`. `sort` is `weight` (the default: heaviest first, a list with no weight yet last, id as the tiebreak) or `newest` (by activation date, newest first); any other value is a 400. `q` matches the list's name, source or URL, case-insensitively, and is at most 200 characters once stripped. A `q` that is sent but empty or only whitespace is a 400 naming `q`, never the unfiltered list; leaving `q` out gives the unfiltered list. Without either parameter the response is what it was before.
- **A book on one configuration.** `GET /api/v1/ranking_configurations/{id}/books/{slug}` is the record `GET /api/v1/books/{slug}` returns, with `rank` taken from the named configuration. A book that configuration does not rank has `rank: null`, not its primary rank. For the primary configuration the two endpoints give the same `rank`.
- **A book's lists on one configuration.** `GET /api/v1/ranking_configurations/{id}/books/{slug}/lists` returns only the active lists the book is on that the named configuration feeds, with that configuration's `weight` and the book's `position`. Heaviest first, a fed list with no weight yet last. Lists that configuration does not feed are absent, and `total_count` matches the rows.
- **A list on one configuration.** `GET /api/v1/ranking_configurations/{id}/lists/{list_id}` is the `/api/v1/lists/{id}` record with `weight` taken from the named configuration. A list that configuration does not feed is a 200 with `weight: null`, as `/api/v1/lists/{id}` is off the primary and as the site's `/rc/:id/list/:id` shows it.
- **Under a configuration the configuration wins.** In every `/ranking_configurations/{id}/…` path, an unknown, archived or member-owned configuration is a 404 before any parameter is checked, so a bad `sort` on a missing configuration is the 404, not a 400.
- **Where `sort`, `q` and `type` go.** They ride on the paging `links` (`self`, `first`, `prev`, `next`, `last`), so following `next` gives the next page of the same ordering. `meta` gets no echo of them, as on `/api/v1/categories` and the search endpoints; `meta.filters` stays the ranked-book filters' key.
- **One text parser, one enum parser.** `text_param!` and `enum_param!` on `Api::V1::BaseController` are the single place a text parameter is bounded (required or optional, minimum and maximum length, array and hash values refused) and an enum parameter is checked. Book search, author search, category search and the lists `q` all use them, so each rejects the same inputs the same way with `invalid_parameter` and a `detail` naming the parameter.
- **MCP.** The tools are `search_categories`, `list_countries`, `get_ranking_configuration_book`, `list_ranking_configuration_book_lists` and `get_ranking_configuration_list` (whose `id` is the configuration and `list_id` the list), and `list_lists` and `list_ranking_configuration_lists` take `sort` and `q`. The MCP usage copy names the order rules (category search name matches first, countries most books first, `sort=newest` newest first) and tells the agent to find slugs with `search_categories` and `list_countries` instead of guessing.

## Filters and search

Spec: `docs/superpowers/specs/2026-11-02-public-api-web-parity-design.md` (increment 1). The website's book filters, as API parameters, plus a search endpoint.

- **Where filters apply.** The ranked book collections: `GET /api/v1/books`, `/api/v1/ranking_configurations/{id}/books`, `/api/v1/categories/{slug}/books`, and `/api/v1/ranking_configurations/{id}/categories/{slug}/books` (the category books on a named configuration, `rank` relative to it). Parsing and the limits are the website's (`Books::FilterParams`); `Api::RankedBookFilters` adds the API-only rules and the error mapping.
- **Parameters.** Slugs are comma-separated; repeats and empty entries are dropped.
  - `category_id`: up to 6 slugs, and a book must carry every one. A merged or renamed slug resolves to the live category.
  - `country_id`: up to 10 slugs, and a book from any of them matches. It cannot be sent with `collection`.
  - `year`: books first published that year. It cannot be sent with `published_start` or `published_end`.
  - `published_start`, `published_end`: books first published in or after, or in or before, a year. Years run from -4000 to the current year plus 5.
  - `collection`: one of `women`, `africa`, `asia`, `latin-america`, `western`, `non-western`, the site's curated collections.
- **On category books the path category counts.** It is one more category filter, so `category_id` on `/categories/{slug}/books` intersects with it, and the limit of 6 applies to the union. Passing the path category's own slug adds nothing, but a merged or old slug of it still counts toward the 6 (the results are unaffected).
- **400 versus 404.** Malformed input is a 400 `invalid_parameter` whose `detail` names the parameter: a blank value (`category_id=`) or one made only of separators (`country_id=,`), an array or hash value (`category_id[]=x`), too many slugs, a non-integer or out-of-range year, an unknown `collection`, and the forbidden combinations above. A blank value is an error, not "unfiltered". A well-formed slug that names nothing is a 404 `not_found` whose `detail` names the parameter and the slug (`No category_id matches "x"`). A missing path resource (ranking configuration, then path category) is answered before any filter, and a bad filter before a bad page.
- **`meta.filters`.** Echoes only the filters that were sent, in canonical form: slugs sorted with merged ones replaced by the live slug, years as integers, `collection` as its slug. On category books the path category is left out of `category_id`. An unfiltered request has no `meta.filters` key, so existing responses are unchanged. `links.first/prev/next/last` carry the same filters, so following `next` gives the next page of the same filtered list.
- **Search.** `GET /api/v1/search/books?q=` (`Api::V1::Books::BookSearchesController`; same OpenSearch query as the site's search, `Books::BookSearchQuery.hit_ids`). Catalog books only (standalone, not provisional), best match first, in the normal collection envelope with `rank` from the primary ranking (null when unranked). A query yields at most 100 hits, so `total_count` is at most 100 and paging stops there; the count and pages come from the books that exist in Postgres, so a stale index id never makes a page shorter than its meta promises. `q` is required and at most 200 characters (after stripping): missing, blank, over the limit, or sent as an array is a 400. Paging links carry `q`. Search takes no filter parameters. Authors have their own search, `GET /api/v1/search/authors?q=` (see "Author books and similar books").
- **503 `search_unavailable`.** OpenSearch being unreachable, timing out, or answering 5xx/429 (`Search::Shared::Client::UNAVAILABLE_ERRORS`) is a documented 503, not a generic 500; a 4xx from the cluster is not in that list and surfaces as a 500; the client should retry shortly. It has an `#errors-search_unavailable` anchor on `/developers` like every other problem code.

## Authentication

`Authorization: Bearer tg_…`. Tokens are `ApiToken` rows storing only a SHA-256 digest; the secret is shown once (`Services::Api::Tokens.generate`, which with `authenticate` and `record_use` owns the token lifecycle; the model holds only validations). `Services::Api::Authenticator` is the only code that inspects a token; it yields an `Api::Principal` (user, token, scopes, tier). A person needs an active membership (`User#member?`); a service account (`User#account_kind == service`) does not and gets the `system` tier.

Failures follow RFC 6750: 401 `WWW-Authenticate: Bearer` / `Bearer error="invalid_token"`; 403 `membership_required` (no challenge); 403 `Bearer error="insufficient_scope", scope="…"`.

Members mint tokens at `/developers/tokens`: a name (≤60 chars), any of the three read scopes, and an expiry of never, 30, 90 or 365 days. Ten per account.

## Scopes

`Api::Scopes` — `books:read`, `music:read`, `games:read` (plus the admin scopes under "Admin permissions"). Members may mint the three reads; service accounts get the read scopes only (never an admin scope, even if the account holds an admin role). `Api::V1::<Domain>::BaseController` declares `require_scope`. Hierarchy (`x:write` implies `x:read`) is already honoured for when write scopes exist.

## Admin permissions

Spec: `docs/superpowers/specs/2026-11-01-api-admin-permissions-design.md`. A token may now carry admin scopes, and an admin needs no membership.

- **Three checks, every request.** (1) The token's granted scopes are expanded through `implies:` and intersected with what the owner is eligible for right now (`Api::Scopes.effective`); (2) the endpoint's `require_scope` must be satisfied by that set; (3) the Books policy behind the action (`destroy?` on the source and the target for a merge) must allow the user. A demoted owner's token shrinks on the next request; nothing is cached on the token.
- **Eligibility** lives on each scope in `Api::Scopes::ALL` (`eligible`, `->(user, member)`):

  | Scope | Who may hold it |
  |---|---|
  | `books:read`, `music:read`, `games:read` | an active member, or a service account |
  | `books:admin:read` | `Books::BookPolicy#index?`; implies `books:read` |
  | `books:admin:write` | `Books::BookPolicy#update?`; implies `books:admin:read` |
  | `books:admin:merge` | `Books::BookPolicy#destroy?`; implies `books:admin:write` (so it implies read too) |

  `eligible_for(user)` is the passing scopes plus everything they imply; `mintable_by(user)` is the same set. `/developers/tokens` is open to anyone who can mint at least one scope, and never pre-ticks an admin scope.
- **Must expire.** `ApiToken` rejects a token with any admin scope and no `expires_at`.
- **Authenticator.** Scopes on the `Api::Principal` are the effective ones. A person with no effective scope and no active membership gets 403 `membership_required`. A person whose token holds any admin scope gets the `admin` rate-limit tier (`config/initializers/api.rb`, 600/min and 200,000/day); service accounts stay on `system` (and cannot hold admin scopes). The tier selects only the limits: counters are keyed on the account, as for every tier.
- **Endpoints** (`Api::V1::Admin::Books::*`, business logic in `Services::Books::AdminMerge`; bearer auth, same envelope and problem format):
  - `GET /api/v1/admin/books?q=` and `GET /api/v1/admin/authors?q=` need `books:admin:read`. `q` is required; pagination links carry it.
  - `POST /api/v1/admin/books/{id}/merge` and `POST /api/v1/admin/authors/{id}/merge` need `books:admin:merge`. `{id}` is the target. Body `{"source_id": …, "dry_run": false}`; `source_id` is a JSON integer or a string of plain decimal digits, at least 1 (`"010"` is 10, not octal; 0 and negatives are 400 `invalid_parameter`). A dry run validates and reports without changing anything, but it runs after authorization, so it enforces the same scope and policy checks. A real merge writes one `event=api_admin_merge` log line (token, user, record type, source, target). The 200 carries `warnings` for follow-up work that could not complete after the commit; a refusal says which record was refused.
- **Category endpoints** (`Api::V1::Admin::Books::CategoriesController`, `BookCategoriesController`, `AuthorCategoriesController`; spec `docs/superpowers/specs/2026-11-02-categories-api-design.md`). Ids are numeric and parsed strictly, as for merge. Every write also passes `Books::CategoryPolicy` (and `Books::BookPolicy`/`AuthorPolicy#update?` for tagging).
  - `GET /api/v1/admin/categories?q=&type=&status=` and `GET /api/v1/admin/categories/{id}` need `books:admin:read`. `status` is `active` (default), `deleted` (deleted without a merge), `merged` or `all`; `type` is `genre`, `location`, `subject`, `theme` or `audience`; `q` is optional (without it the list is by name) and matches name or alias. Detail answers for a category in any status.
  - `POST /api/v1/admin/categories` and `PATCH /api/v1/admin/categories/{id}` need `books:admin:write`. Body keys `name`, `description`, `category_type`, `alternative_names`, `parent_id` (null clears it); names are stripped, unknown keys ignored. Both go through `Categories::Editor`, the same service as the admin UI. A name that another active category of the same type already uses, as a name or an alias, is a 422 (`Categories::NameGuard`); a case-only rename of the category itself is not. A deleted or merged category cannot be edited (422). Moving a location or retyping into or out of location queues the ancestor reconcile in the background.
  - `POST /api/v1/admin/books/{id}/categories` and `POST /api/v1/admin/authors/{id}/categories` (body `{"category_id": …}`) tag; `DELETE …/categories/{category_id}` untags. Both need `books:admin:write` and run through `Categories::ItemLinker`, shared with the admin UI. Tagging a category the item already has is a 200 no-op. A deleted or merged category, or one from another site, is a 422. Untagging a category the item lacks is a 404; untagging an inherited ancestor location is a 422 naming the more specific location to remove instead. The 200 body lists the item's categories with their `source`.
  - `POST /api/v1/admin/categories/{id}/merge` needs `books:admin:merge`. `{id}` is the target; body `{"source_ids": [1 to 50 distinct ids, not the target], "dry_run": false}`. `dry_run` must be `true` or `false` (a JSON boolean or the string), anything else is a 400. Nothing merges until every record exists, the policy allows each one and `Categories::Merger.refusal` accepts each pair (422 naming the refused sources); a dry run reports each source's book and author link counts. Merges then run one at a time, each in its own transaction. If one fails, the 422 lists `merged`, `failed` and `not_attempted`. If only the work after commit fails (reindex queueing, ancestor reconcile) the source counts as merged and appears under `post_commit_errors`.
  - `DELETE /api/v1/admin/categories/{id}` needs `books:admin:merge` and soft deletes. **Warning:** it removes every book and author link to the category, and restoring the category does not bring the links back. Child places of a deleted location keep pointing at it. `?dry_run=true` returns the link counts it would remove (`book_links_removed`, `author_links_removed`) without changing anything; the four protected categories (Fiction, Nonfiction, Poetry, Religion & Spirituality) and an already deleted category are 422. Prefer a merge when the links should survive.
  - Each successful write logs one `event=api_admin_category_*` line (`create`, `update`, `merge`, `delete`, and `api_admin_category_link` for tagging) with the token and user; update lists the changed attribute names, never values. Refused writes log nothing, except a failed merge, which logs `outcome=failed`.
- **Public category endpoints** (any `books:read` token, in the public `openapi.yaml`): `GET /api/v1/categories?type=&sort=` lists categories with ranked books on the primary ranking (`type` is `genre` (default), `location`, `subject` or `audience`; the site's word "settings" is a 400; `sort` is `book_count` or `name`), `GET /api/v1/categories/{slug}` shows one, and `GET /api/v1/categories/{slug}/books` is the primary ranking filtered to it, best first, in the `/api/v1/books` shape (and takes the filters under "Filters and search"). Show accepts any active books category, and an old or merged slug resolves to the live category; a slug naming a category that was deleted without a merge is a 404. `parent` is the live parent, or null. `book_count` counts ranked books, not all links.
- **Contract.** `web-app/config/api/v1/admin_openapi.yaml`, served at `GET /api/v1/admin/openapi.json`. Admin paths are not in the public `openapi.yaml`, so `/developers` and `/api/v1/openapi.json` never advertise them.

## Rate limits

`config/initializers/api.rb`. Keyed on the account, two fixed windows (calendar minute, UTC day), counted by `Services::Api::RateLimiter` on `config.x.rate_limit_store`. Headers on every authenticated response: `X-RateLimit-Limit/Remaining/Reset` and `X-RateLimit-Daily-Limit/Remaining/Reset`; 429 adds `Retry-After`. Unauthenticated failures count per visitor IP (minute window only).

## Service accounts

```
bin/rails api:service_account:create NAME=agent-runner SCOPES=books:read,music:read,games:read
bin/rails api:service_account:token  NAME=agent-runner TOKEN_NAME=prod-2 SCOPES=books:read
bin/rails api:token:revoke ID=42
```

Each prints only the secret. `Services::UserAuthenticationService` scopes every lookup to `User.person`, so a service account can never sign in or be linked.

## Testing the pages

`test/controllers/developers_controller_test.rb` compares `/developers` signed out and signed in
(it is edge-cached, so any per-visitor byte would leak) and pins an anchor per problem code.
`test/controllers/developers/tokens_controller_test.rb` covers the gate, the cap, the once-only
secret and the Turbo Stream shapes. Playwright: `e2e/tests/books/developers.spec.ts` (anonymous),
`books/account/developers.spec.ts` (signed-in non-member), `books/member/developers-tokens.spec.ts`
(the member account, see `docs/features/e2e-testing.md`).

## Edge

API paths sit under `/api/` because the edge treats that prefix as the API. The edge rules live in the
private `the-greatest-cloudflare` repo, which is the source of truth; this public repo records none of
their details. What gates `/api/` inside the app:

- Auth on every endpoint but one, then the per-account rate limit (see "Rate limits").
- `Services::Api::RateLimiter`'s per-IP window for unauthenticated failures, and that same per-IP window
  on `/api/v1/openapi.json`, the one unauthenticated route.

Caching: API responses are `private, no-store`. `/api/v1/openapi.json` sends `public, max-age=3600` and
no rate-limit headers, so a cached copy cannot mislead.

## Not yet

music/games resources; OAuth sign-in
(`docs/superpowers/specs/2026-11-02-mcp-oauth-design.md`). The MCP server is shipped; see
`docs/features/mcp-server.md`.
