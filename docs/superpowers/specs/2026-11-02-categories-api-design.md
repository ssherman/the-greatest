# Categories API — design

Date: 2026-11-02. Builds on the public API (`docs/superpowers/specs/2026-09-12-public-api-framework-design.md`)
and the admin permission layer (`docs/superpowers/specs/2026-11-01-api-admin-permissions-design.md`,
merged as PR #440). Read `docs/features/public-api.md` and `docs/features/books-categories.md` first.

## Intent

Shane wants to manage book categories through the API, so that a future admin MCP server can act on
requests like "merge these categories", "delete these", "tag this book as Gothic". Members should also
be able to read categories through the public API.

## Goals

- A public, read-only categories API for members, matching what the `/categories` page shows.
- Admin endpoints to search, create, update, merge and delete categories.
- Admin endpoints to tag a book or author with a category and to remove that tag.
- Every write goes through the same domain services the admin UI uses, so the API and the UI cannot
  disagree about the rules.

## Non-goals

- Combined filtering on `GET /api/v1/books` (several categories, year, country...). That is a separate
  follow-up spec. This spec only adds the ranked books of one category.
- The MCP server.
- Music and games categories. Only `Books::Category` is exposed. Paths and code should not assume
  books forever, but only books ships.
- Changing what soft delete does (see "Delete" below).
- The category cleanup pipeline (`CategoryCleanupDecision`, runbooks). The API does not touch it.

## Anti-goals

- **Five APIs.** Genres, subjects, locations, audiences and themes are one table (`categories`) with a
  `category_type` column, and `Categories::Merger` allows merging across types ("Fantasy" subject into
  "Fantasy" genre is a normal cleanup). There is one categories resource with a `type` filter.
- A second copy of the rules in `Admin::CategoryItemsController`. The API and the admin UI must share
  one implementation (see "Tagging").
- Admin-only fields, paths or scopes leaking into the public OpenAPI document or `/developers`.
- Wrapping `Categories::Merger` or `Categories::Deleter` in an outer transaction. They manage their own,
  and post-commit work (reindexing, ancestor reconciling) must run after the real commit.

## The model, for the builder

- `Category` (STI, `Books::Category` for books). Columns: `name`, `slug` (friendly_id, scoped by STI
  type, with history), `category_type` (enum: genre, location, subject, theme, game_mode,
  player_perspective, audience — books uses genre, location, subject, theme, audience),
  `alternative_names` (array), `description`, `parent_id` (location tree), `deleted`,
  `merged_into_id`, `item_count`, `import_source`.
- A merged category is `deleted: true` with `merged_into_id` set; `Category#canonical` and
  `Books::CategorySlugResolver` resolve it.
- `CategoryItem` links a category to a `Books::Book` or `Books::Author`, with `source`
  (legacy, admin, inherited, goodreads). Location ancestors are materialised as `inherited` links and
  rebuilt by `Categories::AncestorReconciler`.
- `Books::Category.protected_ids` (Fiction, Nonfiction, Poetry, Religion & Spirituality) cannot be
  merged or deleted; the services raise `Categories::Refused`.

## Permissions

Uses the permission layer from PR #440 unchanged, plus one new scope:

| Scope | Covers | Eligible |
|---|---|---|
| `books:read` (exists) | public category endpoints | members, service accounts, books staff |
| `books:admin:read` (exists) | admin category search and detail | `Books::BookPolicy#index?` |
| `books:admin:write` (new) | create/update categories, tag/untag | `Books::BookPolicy#update?` (global admin/editor, books DomainRole editor and up); never service accounts |
| `books:admin:merge` (exists) | merge and delete categories | `Books::BookPolicy#destroy?` |

`books:admin:write` implies `books:admin:read`. **`books:admin:merge` now implies `books:admin:write`**
(today it implies `books:admin:read`). Every user eligible for merge (`destroy?`) is also eligible for
write (`update?`), so this grants nothing a user can't already hold; it means one merge token covers the
whole admin category surface. Existing merge tokens gain write on the next request.

Record-level checks use `Books::CategoryPolicy` (`update?` for edits and tagging, `destroy?` for merge
and delete, on every category touched) the same way the book merge endpoints use `Books::BookPolicy`.
`books:admin:write` is an admin scope, so tokens carrying it must expire and it is never pre-ticked on
`/developers/tokens` (both already true for any `admin: true` scope).

## Public endpoints (books host, `books:read`)

| Method & path | Purpose |
|---|---|
| `GET /api/v1/categories?type=&sort=` | the categories the site lists, paginated |
| `GET /api/v1/categories/{slug}` | one category |
| `GET /api/v1/categories/{slug}/books` | the category's ranked books on the primary ranking |

- The list uses `Books::BrowseQuery.categories` with the primary ranking configuration, so it returns
  exactly what `/categories` shows: genre, audience, location and subject only (`BrowseQuery::TYPES`),
  only categories with ranked books, and subjects/locations only above `browse_min_category_books`.
- **`type` uses the model's values: `genre`, `location`, `subject`, `audience`** (not the site's URL words
  `settings`/`subjects`/`audiences`). The description tells members the site calls locations
  "settings". Absent `type` means what the page shows by default. Any other value is 400. Responses
  always say `category_type: location`, never "setting".
- `show` and `/books` accept **any active books category**, the same set the site's own category page
  (`/the-greatest/:category_id/books`, `Books::FilterParams#resolve_categories`) accepts, including
  themes and small categories that the list leaves out. So a member can follow any category a book's
  `categories` array names. The slug resolves through `Books::CategorySlugResolver` (old and merged
  slugs answer with the live category); nothing live, or deleted and unmerged, is 404.
- `book_count` is the number of books in the category on the primary ranking, the same number the
  browse cards show; it can be 0 on `show` for a category the list leaves out. Computed for the one
  category on `show`, and taken from the browse query's count on the list.
- `books` uses `Books::RankedBooksQuery` with that one category and renders the same book shape and
  envelope as `GET /api/v1/books`.
- Category shape (public): `id, slug, name, category_type, description, parent` (id/slug/name, null when
  none), `book_count` (the count the site shows). No `alternative_names`, `deleted`, `merged_into`,
  `import_source` or raw `item_count` in the public shape.

## Admin endpoints (books host, under `/api/v1/admin/`)

Ids, not slugs, as in PR #440.

### Read (`books:admin:read`)

| Method & path | Purpose |
|---|---|
| `GET /api/v1/admin/categories?q=&type=&status=` | search |
| `GET /api/v1/admin/categories/{id}` | full detail |

- `q` matches `name` **and** `alternative_names` as substrings, case-insensitive. `q` is optional here
  (unlike book search): without it, the list is every category of the given filters, sorted by name.
  Exact-name matches rank first, then prefix, then the rest. Reuse what exists rather than writing new
  SQL: `CategorySearchQuery::NAME_OR_ALIAS_SQL` (substring on both) and
  `Books::BrowseQuery.name_match_quality_sql` (exact/prefix/word/contains/alias tiers). Not
  `by_alternative_name`, which is exact-match only.
- `status`: `active` (default), `deleted`, `merged`, `all`.
- Admin shape: everything public plus `alternative_names, deleted, merged_into` (id/name or null),
  `item_count`, link counts split by item type (books, authors), `children` count, `import_source`,
  `created_at`, `updated_at`. Detail adds the children (id/slug/name) and the ancestor chain for
  locations.

### Write (`books:admin:write`)

| Method & path | Purpose |
|---|---|
| `POST /api/v1/admin/categories` | create |
| `PATCH /api/v1/admin/categories/{id}` | update |
| `POST /api/v1/admin/books/{id}/categories` | tag a book |
| `DELETE /api/v1/admin/books/{id}/categories/{category_id}` | untag a book |
| `POST /api/v1/admin/authors/{id}/categories` | tag an author |
| `DELETE /api/v1/admin/authors/{id}/categories/{category_id}` | untag an author |

**Create/update** accept `name, category_type, description, alternative_names, parent_id`.
- Update behaves exactly like the books admin edit screen (`Admin::Books::CategoriesController#update`):
  a plain `update`, so a rename keeps the id and friendly_id keeps the old slug; a reparented or retyped
  location enqueues `Categories::ReconcileAncestorsJob`. Extract that "save, then enqueue if a location
  moved" step into a service both the controller and the API call. Do not use `Categories::Updater`
  (its rename path creates a new row).
- Model validation failures (location parent rules, retyping a location with places under it) are a
  422 with the validation messages.
- Create **and rename** refuse a name that matches, case-insensitively, another active books
  category's name **or one of its alternative names** (422, naming that category's id and whether the
  match was its name or an alias), so the API cannot mint twins or near-twins. This guard is API-only:
  the admin UI's create and edit keep their current behaviour. (Builder's call, below.)
- Updating a deleted or merged category is a 422.

**Tagging.** Extract the rules in `Admin::CategoryItemsController#create`/`#destroy` into one service
(`Categories::ItemLinker` or similar, under `app/lib/categories/`) and make the admin controller call
it too. The rules:
- `Admin::CategoryItemsController` serves music, books and games, so the service is cross-domain and
  the rules below apply on every site.
- Adding a category the item holds only as `inherited` upgrades that row to `admin`; otherwise a new
  `admin` link. Adding one it already holds directly succeeds and changes nothing (today the admin UI
  shows a uniqueness error for that; it becomes a no-op success there too).
- A category from another site is refused (the controller's `ensure_category_domain_matches`).
- **New:** a deleted category is refused; a merged one is refused with a 422 that names its
  `canonical` (the caller retries with that id). The admin UI gains these too.
- After an add or a remove on a book, `Categories::AncestorReconciler.call(item_ids: [id])`.
- **New:** removing a link whose `source` is `inherited` is refused (422) with a detail naming every
  direct location on the item it comes from, because the reconcile would re-add it. The rule applies to
  any inherited row (only books have them today). **Admin UI:** the category list stops offering Remove
  on inherited rows and labels them "via <location>" instead, so the UI never reaches the refusal.
- Responses return the item's resulting category list (id, slug, name, category_type, source).
- Request body for add: `{category_id}`. Same strict id parsing as the merge endpoints (decimal digits,
  ≥ 1).

### Destructive (`books:admin:merge`)

| Method & path | Purpose |
|---|---|
| `POST /api/v1/admin/categories/{id}/merge` | merge sources into category `{id}` |
| `DELETE /api/v1/admin/categories/{id}` | soft delete |

**Merge** body: `{"source_ids": [<id>, ...], "dry_run": <bool>}`. `{id}` is the target, as in the book
merge endpoints.
- 1 to 50 sources. Each is merged with `Categories::Merger.new(category: source,
  category_to_merge_with: target).merge`, one at a time, in the order given.
- Every source and the target are loaded and checked (exist, books, policy `destroy?` on each) before
  any merge runs. A missing id is 404 naming it; a policy refusal is 403 naming it.
- Merger refusals (`Categories::Refused`) are not known until the merger runs. To avoid half-done
  batches where possible, run the merger's own preconditions for every source first, and refuse the
  whole request (422, listing each refused source with its message) if any would be refused. The
  builder decides how to share those checks with `Categories::Merger#refuse_invalid!` without
  duplicating them.
- If a merge still fails part way (an exception after earlier sources succeeded), stop, and return a 422 whose
  body lists which sources merged, which failed and why, which were not attempted.
  Earlier merges stay merged.
- `dry_run: true` runs every check above and returns, per source, its name and link counts, plus the
  target. Nothing changes.
- Success returns the target (admin shape, after the merges) and the list of merged sources.
- One structured log line per source merged (and per failure), like `api_admin_merge`.

**Delete** uses `Categories::Deleter.new(category:, soft: true).delete`, unchanged. Soft delete is the
standing behaviour and stays as it is: it marks the category deleted **and removes all its links**, so it
cannot be undone with the links intact. The endpoint's OpenAPI description and the feature doc say so
plainly. `?dry_run=true` returns the category and how many book and author links would be removed.
Protected categories are a 422 (the Deleter's `Refused`). Deleting an already deleted category is a 422.
One log line per delete.

## Documentation

- **Public developer docs must be updated (Shane).** The `/developers` page lists operations straight
  from the host's OpenAPI document (`app/views/developers/show.html.erb`), so the three public
  category operations appear there once they are in `config/api/v1/openapi.yaml`. Write their
  `summary`, `description` and parameter descriptions for members, not for us: what `type` accepts (and
  that the site calls locations "settings"), that old and merged slugs resolve, what `book_count`
  means, and how `/categories/{slug}/books` relates to `/books`. Check the rendered `/developers` page
  reads well, and add a test that the three operations appear on it. If the page has hand-written prose
  that lists the available resources, update it too.
- Public paths go in `config/api/v1/openapi.yaml` (tagged `x-domain: books`); admin paths in
  `config/api/v1/admin_openapi.yaml`. The public document must still contain nothing admin.
- Both contract coverage tests cover the new operations.
- `docs/features/public-api.md` gains the categories endpoints and the new scope;
  `docs/features/books-categories.md` notes that the admin UI and the API share the tagging service.

## Testing

- Scopes: `books:admin:write` eligibility across roles (global admin/editor, books viewer/editor/
  moderator/admin, service account, member) and that merge implies write.
- Public: type filter and 400 on unknown type; list matches `BrowseQuery.categories`; old and merged
  slugs resolve; deleted → 404; category books order.
- Admin search: name vs alternative-name matches, status filter, ordering of exact/prefix matches.
- Tagging service: inherited upgrade, idempotent add, cross-site refusal, deleted/merged refusal,
  inherited removal refusal, reconcile called. The admin UI controller tests stay green using it.
- Merge: batch success, dry run changes nothing, any precondition refusal aborts the whole batch, a
  mid-batch failure reports merged/failed/not-attempted, protected categories refused, policy refusal on
  one source.
- Delete: dry-run counts, links gone after delete, protected refused.
- E2E: the public pages don't change except `/developers` (covered by the test above). The admin
  item-categories list changes (no Remove on inherited rows, "via" label, re-add is a no-op): extend the
  existing admin category E2E/system coverage for that, and keep music/games tagging coverage green.

## Decided

- One categories API with a `type` filter, not one per type (Shane agreed).
- Public read API for members plus admin search/create/update/merge/delete (Shane).
- Tagging books (and authors) through the API (Shane).
- Soft delete keeps its current behaviour (Shane: "it's the default behavior").
- Book filtering by several categories on `/api/v1/books` is a separate spec (Shane).

## Builder's calls (stated so they can be checked)

- New `books:admin:write` scope; `books:admin:merge` implies it.
- Tagging covers authors as well as books, because `CategoryItem` and the admin UI already do.
- Inherited links cannot be removed directly; merged categories are refused for tagging rather than
  silently redirected.
- Batch merge of up to 50 sources with all-or-nothing preconditions.
- Create and API rename refuse a name matching another active category's name or alias; API-only.
- Public `type` uses model values (`location`, not `settings`); `show`/`books` accept any active books
  category, while the list mirrors `/categories`.
- The tagging service is cross-domain; deleted/merged refusals and idempotent re-add apply on all sites.
- The admin UI hides Remove on inherited links and labels them.
- Increments, in order: public reads → admin search + create/update + scope → tagging service + endpoints
  → merge + delete. Each ships on its own.
- Left to the builder: search ranking details, per-page limits, exact response field names beyond the
  lists above, how shared merge preconditions are factored.
