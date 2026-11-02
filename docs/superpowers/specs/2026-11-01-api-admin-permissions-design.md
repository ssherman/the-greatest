# API admin permissions — design

Date: 2026-11-01. Builds on `docs/superpowers/specs/2026-09-12-public-api-framework-design.md`
(the public read API: `ApiToken`, `Api::Scopes`, `Services::Api::Authenticator`, `Api::Principal`,
`Api::V1::BaseController`). Read that spec and `docs/features/public-api.md` first.

## Intent

The public API is read-only and is a membership benefit. Shane wants to grow it into an API he can
drive admin work through (search, lookups, merges), eventually from an MCP server. Before any of
that can be built, the API needs a permission model where an **admin can reach every endpoint and
a paying member reaches only the base public API**.

This spec delivers that permission model plus two endpoint groups that prove it end to end:
**admin search** (books, authors) and **admin merge** (book into book, author into author).

## Goals

- A token's power is decided by two things: the scopes on the token, and what its owner is
  allowed to hold **right now**.
- Members keep exactly what they have today: the `*:read` scopes and the public endpoints.
  Nothing about membership, billing or the member token UI changes for them.
- Admins can mint tokens carrying admin scopes and use them without holding a membership.
- Demoting a user (or a lapsed membership) takes effect on their existing tokens on the next
  request, with no token cleanup step.
- The API and the admin UI never disagree about who may merge: both go through the same policy.
- Four working endpoints: book search, author search, book merge, author merge.

## Non-goals

- The MCP server, OAuth/Doorkeeper. (Scope strings stay OAuth-shaped so that remains additive.)
  The MCP authorization spec is OAuth 2.1 (PKCE, protected-resource metadata, client
  registration), and it applies only to a *remote* HTTP MCP server. If Rails becomes that OAuth
  server later, the authenticator builds the same `Api::Principal` from an OAuth access token, and
  the scope registry, eligibility rules and effective-scope intersection here apply unchanged. A
  local MCP server needs no OAuth at all: it sends a personal admin token as a bearer.
- Any other admin endpoints: identifier lookup, category/genre search or merge, record editing.
  They come later on top of this model.
- A separate paid API product or usage tiers. Membership = base public API, full stop.
- Music and games admin endpoints. The model must not be books-specific, but only books ships.
- Changing the public `/developers` pages beyond what minting admin scopes requires.

## Anti-goals (would be a failure even if it works)

- An admin endpoint or scope appearing in the **public** OpenAPI document or `/developers` page.
- A token that keeps admin power after its owner loses the role.
- A second, parallel definition of "who may merge" that can drift from `Books::BookPolicy` /
  `Books::AuthorPolicy` and `MergeBook`/`MergeAuthor`'s `destructive?` gate.
- A merge endpoint that wraps the merger in an outer transaction (see the warning on
  `Books::Book::Merger#call`: a joined transaction fires post-commit Sidekiq jobs before commit).

## The permission model

Three checks, in order, on every API request.

### 1. Token scopes (what the token may do)

`Api::Scopes::ALL` stays the single registry. New scopes:

| Scope | Covers | Eligible holders |
|---|---|---|
| `books:read` (exists) | public read endpoints | any member, admins, service accounts |
| `books:admin:read` | admin search (and future admin lookups) | users who may read the books admin |
| `books:admin:merge` | book and author merges | users who may destroy books records |

`books:admin:merge` implies `books:admin:read`; `books:admin:read` implies `books:read`. The
existing `implies:` mechanism already handles this.

The boolean `member_mintable` is replaced by an **eligibility rule** per scope: a callable taking
a user and answering "may this user hold this scope right now?". Rules:

- `*:read` → `user.member? || staff for that domain || user.service?` (today's behaviour: members,
  plus service accounts, plus — new — anyone eligible for an admin scope on that domain).
- `books:admin:read` → `Books::BookPolicy.new(user, Books::Book).index?` (global admin/editor, or a
  books `DomainRole` with read).
- `books:admin:merge` → `Books::BookPolicy.new(user, Books::Book).destroy?` (global admin/editor, or
  a books `DomainRole` that `can_delete?`). This is the same gate the admin UI's merge actions use.

Eligibility is expressed through the existing policies, not re-derived from roles, so there is one
definition of each permission.

`Api::Scopes.mintable_by(user)` becomes "all scopes whose eligibility rule passes for this user".

**Service accounts are not eligible for admin scopes.** They keep every *read* scope (today's
behaviour). Service users are created with `role: :user` and no `DomainRole`
(`Services::Api::ServiceAccounts`), so the policy-based rules already exclude them; the read rule
keeps its explicit `user.service?` clause. Admin API work uses an admin's personal token. The
`api:service_account:*` rake tasks are unchanged.

### 2. Effective scopes (what the owner may hold right now)

`Services::Api::Authenticator` builds `Api::Principal#scopes` as **the token's scopes expanded
through `implies:`, intersected with the scopes the user is currently eligible for**. Expansion
comes first: a token minted with only `books:admin:merge` whose owner is demoted to a books viewer
must keep `books:admin:read` and `books:read`, not drop to nothing. A token whose owner was demoted keeps working for whatever it is still
eligible for and gets `insufficient_scope` (403) on the rest.

The membership check changes accordingly: today a `person` without `member?` is refused outright
with `membership_required`. New rule: refuse with `membership_required` only when the effective
scope set is **empty and** the user is not a member. An admin without a membership authenticates;
a lapsed member with only read scopes still gets today's `membership_required`.

### 3. Record-level policy (on write endpoints)

Merge endpoints also call the policy against the actual records: `destroy?` on the target, which
is what the admin `execute_action` controller does for destructive actions
(`admin/books/books_controller.rb`, `authors_controller.rb`), **and** `destroy?` on the source,
since the source is the record that gets deleted. Checking the source is stricter than the UI; the
policies are class-level today so the answers match. The scope is the coarse gate; the policy is
the fine one.

### Principal tier and rate limits

`Api::Principal#tier` gains `:admin` for a principal holding any `*:admin:*` scope. Rate limits get
an `admin:` entry in `config/initializers/api.rb`; the builder picks numbers (the `system` tier's
are a sensible starting point).

### Minting admin tokens

`/developers/tokens` already renders its scope checkboxes from `Api::Scopes.mintable_by(current_user)`
and validates with the same method in `ApiToken`. With eligibility rules, admins see the admin
scopes there automatically. The page's `require_membership!(:api)` gate must let in a user who is
eligible for any admin scope, so an admin without a membership can reach it.

Tokens carrying any admin scope **must have an expiry** (refuse "never" for them, enforced in the
`ApiToken` validation, not only the form). Note that validation runs on every save, so a demoted
user's token would fail it if ever re-saved; today nothing re-saves a token (`record_use` uses
`update_column`, revoke uses `destroy!`), so this is fine but must not regress. Each scope's description makes clear what it can do;
merge's says it permanently deletes records.

## Endpoints

All under the books host, JSON only, inheriting `Api::V1::BaseController`. Admin endpoints live in
an `admin` path segment and controller namespace:

| Method & path | Scope | Purpose |
|---|---|---|
| `GET /api/v1/admin/books?q=` | `books:admin:read` | full-text book search |
| `GET /api/v1/admin/authors?q=` | `books:admin:read` | full-text author search |
| `POST /api/v1/admin/books/{id}/merge` | `books:admin:merge` | merge `source_id` into book `{id}` |
| `POST /api/v1/admin/authors/{id}/merge` | `books:admin:merge` | merge `source_id` into author `{id}` |

**Identifiers are numeric ids, not slugs.** Admin work is about specific rows (duplicates often
share a near-identical slug), and ids don't change when a merge renames anything. Search results
include both `id` and `slug`.

**Search** uses the existing `Search::Books::Search::BookGeneral` and `AuthorGeneral`, called with
the admin UI's options (`book_kind: nil, include_provisional: true`, as in
`Admin::Books::BooksController`), so collections and provisional imports, a main source of
duplicates, are findable. `q` is
required (400 if blank). Results are the standard collection envelope (`data`, `meta`, `links`),
hydrated from the database in the search's relevance order. Each result carries enough to tell
duplicates apart: for books, id, slug, title, author names, first publication year, and whether it
is ranked; for authors, id, slug, name, birth/death years, book count. The builder may add fields.

**Merge** body: `{"source_id": <int>, "dry_run": <bool, default false>}`.
- Runs the same steps as `Actions::Admin::Books::MergeBook` / `MergeAuthor` (the merger plus any
  post-merge work those actions do). Extract the shared part rather than duplicating it if the
  actions hold logic beyond calling the merger.
- `dry_run: true` validates everything a real merge would (both exist, not the same record,
  policy passes) and returns both records' summaries with what will survive and what will be
  deleted, then stops. It does not compute the merger's transfer stats.
- Success (200) returns the surviving record's summary plus a `warnings` array. Warnings carry
  what the admin actions already surface: `stats[:post_commit_error]` (reindex, ranking
  recalculation and favorites rebuild were not scheduled and need re-running) and, for books,
  `book_authors_not_transferred` / `credits_not_transferred`. The merge committed, so it is not
  an error status, but the caller must be told. The extracted shared service returns these to
  both the admin actions and the API. Merger failures map to a 422 problem response
  carrying the merger's error messages; missing records are 404; same id is 422.
- Runs synchronously in the request, like the admin UI.
- Every merge (not dry runs) logs one structured line: token id, user id, record type, source id,
  target id. No new audit table.

## Documentation and discovery

- The admin endpoints are **not** in the public `config/api/v1/openapi.yaml`. They get their own
  contract file (e.g. `config/api/v1/admin_openapi.yaml`) served at
  `GET /api/v1/admin/openapi.json`, which requires `books:admin:read`. It is never edge-cached.
- The contract tests (`openapi_first`, `contract_coverage_test.rb`) cover the admin document too.
  `test/support/api_conformance.rb` hard-codes `OpenapiFirst::Test[:default]`, so the admin
  document needs its own registered definition, selected per request.
- `/developers` is unchanged. `docs/features/public-api.md` gains a section on the permission model
  and admin scopes.

## Testing

- Unit: scope eligibility per role (member, lapsed member, global admin, global editor, books
  `DomainRole` viewer/editor/moderator/admin, music-only `DomainRole`, service account); effective
  scope intersection; demotion takes effect on the next request; admin without membership
  authenticates; lapsed member still gets `membership_required`; admin-scope token without expiry
  is invalid.
- Integration: each endpoint with no token / read-only member token / admin token; dry run changes
  nothing; real merge moves data and deletes the source; public OpenAPI doc contains no admin path.
- E2E (Playwright): an admin sees admin scopes on `/developers/tokens` and a member does not.

## Decided

- Membership grants the base public API only (Shane).
- No MCP or OAuth in this spec (Shane).
- First endpoints: book/author search and book/author merge (Shane).

## Builder's calls (stated so they can be checked)

- Ids not slugs on admin endpoints; `/api/v1/admin/` namespace; separate admin OpenAPI doc.
- Eligibility via existing policies; merge eligibility = `destroy?`, matching the admin UI.
- Admin tokens must expire; `admin` rate-limit tier; one log line per merge, no audit table.
- Service accounts get read scopes only, never admin scopes.
- Effective scopes = expand implied scopes, then intersect with eligibility.
- Merge warnings ride on a 200 as a `warnings` array; merge checks `destroy?` on source and target.
- Admin search uses the admin UI's search options (collections and provisional imports included).
- `dry_run` validates and previews but does not simulate the merge.
- Left to the builder: rate-limit numbers, exact search result fields beyond the minimum above,
  per-page limits for search, how the eligibility callables are shaped in `Api::Scopes`.
