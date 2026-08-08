# Books Saved Searches — Design

**Date:** 2026-08-08
**Status:** Approved, not yet implemented

Port the legacy site's saved-search feature to the new app: 4,391 user-owned searches whose
stored criteria must keep returning the same books, reachable at the same URLs.

---

## 1. Summary

The legacy site lets a signed-in user save a set of book filters, name it, optionally make it
public, and revisit it at `/searches/:id`. There are **4,391 saved searches across 1,152
users**, 50 of them public, and roughly 300 are executed each month. The feature does not
exist in the new app at all.

Legacy executes them with OpenSearch: `Search::Books.advanced_search` builds a bool query,
returns matching book ids, and Postgres then sorts by rank and pages. This design keeps that
split. Postgres alone cannot express the criteria comfortably — the filters mix AND and OR
with include *and* exclude across three independent taxonomies (categories, languages,
countries) — which is why OpenSearch was chosen originally and why it is chosen again here.

The public-filters feature (spec `2026-08-03-books-filters-design.md`) runs on Postgres via
`Books::RankedBooksQuery`. That stays as it is. The two share a **return contract**, not an
engine: both hand back a paginatable `RankedItem` relation ordered by `:rank`, so the same
grid components and `pagy_path` render both. When main-page filtering eventually moves to
OpenSearch, this design is the thing it moves toward.

The model is built generically from day one — `SavedSearch` STI on a shared table, with
global routes resolving `Current.domain` — so games and music can be added later without
reshaping anything. **Only books is in scope here.**

---

## 2. Scope

**In scope:** the `SavedSearch` model and its migration; the three book columns the criteria
depend on; the OpenSearch index fields; the advanced-search query layer; index/show/new/edit
with full CRUD; legacy URL compatibility including the `/v/:view_type` prefix.

**Out of scope:**

- **Games and music.** Games is greenfield (no migration, no legacy URLs) and its index is
  missing much of the data it would need; it gets its own spec. Music needs two subclasses
  against two indexes (`Music::Albums::` and `Music::Songs::`) and is deferred further. §10
  records the seam both will use.
- **A `book_type` column.** Resolved to categories at query time — see §4.
- **Populating `books_editions.page_count`.** No source data exists; see §4.
- **`rc/:id` prefixed saved-search URLs.** Legacy never passes `ranking_configuration:` to
  `advanced_search` from the saved-search controller, so it always uses the default RC.
  Adding the prefix would be new behavior, not a port.

---

## 3. Background: what the legacy feature actually does

```ruby
# app/controllers/saved_searches_controller.rb
@books = execute_search(page: @page, per_page: @limit)     # OpenSearch -> ids -> PG
@search.update(last_executed_at: Time.current, result_count: @books.count)
@books = @books.page(@page).per(@limit)
```

`advanced_search` builds a `bool` query, pulls up to 10,000 ids (scrolling beyond that), then
runs `Book.where(id: book_ids).sorted_by_rank(RankingConfiguration.default)`.

**`sorted_by_rank` inner-joins `ranked_books` and requires a non-nil score.** Verified against
the legacy database: the primary RC (68, "May 2026") has 123,826 `ranked_books` rows but only
**24,249 with a score**. So a saved search never returns unranked books, regardless of its
criteria. This is the single most important fact in the design — it means results are always a
subset of the ranked set, which is exactly what `RankedItem` already models.

### Criteria in use

All fourteen keys are live. Counts are searches, out of 4,391:

| Key | Searches | Shape |
|---|---|---|
| `genre_match_mode` | 4,391 | `"any"` (4,240) / `"all"` (151) |
| `first_year_published_gt` | 1,624 | string |
| `first_year_published_lt` | 1,263 | string |
| `book_length` | 1,069 | array of ints |
| `book_type` | 909 | int |
| `included_language_ids` | 816 | array of id strings |
| `included_category_ids` | 718 | array of id strings |
| `included_country_ids` | 666 | array of id strings |
| `max_ranked_position` | 579 | int |
| `hide_read` | 565 | `true` |
| `ranked` | 437 | `"true"` (424) / `"false"` (13) |
| `excluded_category_ids` | 186 | array of id strings |
| `excluded_language_ids` | 79 | array of id strings |
| `excluded_country_ids` | 40 | array of id strings |

142 searches carry **only** `genre_match_mode` — effectively unfiltered, matching the whole
corpus. That drives the narrowing decision in §5.

### Known fidelity limits

Two deviations are unavoidable and are recorded here rather than discovered later.

1. **`max_ranked_position` (579 searches) cannot be byte-exact.** Legacy filters on
   `ranked_books.combined_position`, which disagrees with score ordering for 16,914 of 24,249
   books and tops out at 17,159 (it has ties). That column was never migrated, and the new app
   recomputes rankings from scratch anyway. `RankedItem.rank` — a dense 1..24,242 — is the only
   sane target, and is arguably closer to what "Top 500" means to a user.
2. **`book_type: religious` (16 searches) broadens ~8.8×.** See §4.

Every other criterion maps exactly.

---

## 4. Data prerequisites

### 4.1 Id spaces

Three of the four id spaces the criteria reference need no translation:

| Id space | Status | Evidence |
|---|---|---|
| Languages | **identity** | 201 rows both sides; `legacy_id_maps` has 201 rows, all `legacy_id = new_id` |
| Countries | **preserved** | `Books::Country` migration (PR #201) preserved ids; no map entry needed |
| Categories | **remapped** | 73,913 `Books::Category` map rows, **zero** identity |
| Users | **preserved** | 0 saved searches reference a missing user |

So the migrator must remap `included_category_ids` / `excluded_category_ids` through
`legacy_id_maps` (`model: 'Books::Category'`) and nothing else. Measured: **531 distinct
category ids** are referenced across all saved searches, **all 531 present in legacy and
covered by the map**. Fourteen are `deleted` — they will match nothing, which is exactly what
legacy does, since both index only `categories.active`.

### 4.2 No `book_type` column

`book_type` (fiction / nonfiction / religious / poetry) is dead weight going forward — the
values are already represented as categories. Rather than migrate a column nobody will
maintain, `BookAdvanced` resolves it at query time through a four-entry constant:

| Criterion value | Category | New id |
|---|---|---|
| `0` fiction | Fiction | 2683 |
| `1` nonfiction | Nonfiction | 3348 |
| `2` religious | Religion & Spirituality | 9343 |
| `3` poetry | Poetry | 3211 |

**It is applied as its own AND `filter` clause, never merged into `included_category_ids`.**
This is load-bearing: 224 searches carry both keys and **183 of those use
`genre_match_mode: "any"` (OR)**. Merging fiction into the OR'd category list would turn
"Novels AND fiction" into "Novels OR Fiction" and silently corrupt all 183.

Fidelity of the mapping, measured on the ranked set:

| Value | Searches | Ranked via `book_type` | Via category | Lost | Gained |
|---|---|---|---|---|---|
| fiction | 656 | 15,420 | 15,881 | 206 (1.3%) | 667 |
| nonfiction | 195 | 7,508 | 7,540 | 156 (2.1%) | 188 |
| poetry | 42 | 1,179 | 1,590 | 34 (2.9%) | 445 |
| religious | 16 | 142 | 1,249 | 9 (6.3%) | 1,116 |

`religious` maps to **Religion & Spirituality** (the genre, 11,181 items), not the near-empty
`Religious` subject category (9 items, 8 of them ranked), which would have destroyed those
searches outright — it retains 1 of 142.
The trade is retention for breadth: those 16 searches will return roughly 8.8× more books.
Results stay topically correct, just broader. **This is an accepted deviation**, taken over
carrying a dead column through the schema, the index mapping, a 126k reindex, and the admin.

A one-time **category backfill migrator** links every typed book to its category so retention
reaches 100%:

| Category | Backfill rows |
|---|---|
| Fiction | 3,260 |
| Nonfiction | 3,218 |
| Religion & Spirituality | 139 |
| Poetry | 109 |
| **Total** | **6,726** |

These books also begin appearing on the corresponding public filter pages, which is correct —
they are fiction/nonfiction/religious/poetry books.

### 4.3 Three columns on `books_books`

Unlike `book_type`, `book_length` has no category equivalent, is used by 1,069 searches, and
stays useful.

| Column | Type | Rows |
|---|---|---|
| `book_length` | integer enum `{very_short:0, short:1, medium:2, moderate:3, long:4, very_long:5}` | 84,108 |
| `page_range` | string | 85,211 |
| `word_count` | integer | 17,370 |

All three are copied **verbatim**, nullable, no defaults. `book_length` is copied rather than
recomputed so migrated searches match legacy exactly — including the 1,136 books that have a
source but no stored length, and the 3 whose length came from neither source.

`page_range` stays a string rather than being split into min/max integers: 1,885 of its values
contain letters, and the parser must reproduce legacy's `extract_max_pages` rejection behavior
regardless. Shapes are 17,380 plain numbers, 66,783 ranges (`"250-350"`), 1,885 with letters.

**`page_range` and `word_count` are explicitly transitional.** The right long-term home for
page data is edition-level `books_editions.page_count`, which already exists but is **empty
for all 126,282 books**; legacy's `editions` table has no page or word columns at all, so
there is nothing to migrate into it. These two work-level columns exist to keep `book_length`
derivable until a real per-edition source arrives, at which point they should go away.

`Books::BookLength` — a PORO, not a callback — ports both legacy rules behind one call:

- `extract_max_pages(page_range)`: nil if the string contains any letter; a bare number is
  used as-is when positive (nil otherwise); a hyphenated range is split, and is nil if any
  part converts to zero, otherwise **`((min + max) / 2.0).round`**.
  **The method name lies** — despite being called `extract_max_pages` it returns the
  *midpoint*, not the max. 66,783 of 85,211 values are ranges, so getting this wrong
  mis-classifies most of the corpus.
- `word_count / 275.0`, rounded, when no page range resolves.
- Thresholds: `0..149` very_short, `150..250` short, `251..350` medium, `351..500` moderate,
  `501..1000` long, else very_long.

Being pure, it is table-testable without touching a record. It is invoked on write for new
books; it is **not** used to backfill migrated rows.

### 4.4 `BookAttributesMigrator`

This is the first migrator in the suite that **updates existing rows** rather than inserting,
so it cannot use `BulkUpsertMigrator`: `upsert_all` would have to supply a full valid tuple
satisfying `books_books`' NOT NULL `title` and `slug` on its INSERT arm. Instead it batches:

```sql
UPDATE books_books
   SET book_length = v.book_length, page_range = v.page_range, word_count = v.word_count
  FROM (VALUES ...) AS v(id, book_length, page_range, word_count)
 WHERE books_books.id = v.id
```

Ids are preserved on both sides, so there is no remapping. Idempotent by construction. Wired
into the `data_migration:*` rake namespace alongside the category backfill.

---

## 5. OpenSearch index

### 5.1 New fields on `Search::Books::BookIndex`

`category_ids` and `author_ids` already exist and are already `keyword`, so the new id fields
match them.

| Field | Type | Source | Serves |
|---|---|---|---|
| `first_published_year` | integer | column | `_gt` / `_lt` |
| `original_language_id` | keyword | column | languages ± |
| `country_ids` | keyword | `countries.pluck(:id)` | countries ± |
| `book_length` | integer | new column | `book_length` |
| `ranked` | boolean | `list_items.any?` | the `ranked` criterion |
| `ranked_position` | integer | `RankedItem` rank, primary RC | coarse narrowing |

### 5.2 Why `ranked_position` is the narrowing filter

Every advanced-search query carries `filter: {exists: {field: "ranked_position"}}`. This cuts
candidates from 126,282 to 24,242 — necessary, because the 142 filter-less searches would
otherwise pull the entire corpus on every page view.

It must be `ranked_position` and not `ranked`. The two are close but not equal: 24,362 books
have list items while 24,249 are scored, and 7 scored books have no list items. `exists` on
`ranked_position` **is** the `RankedItem` set by construction, so the narrowing is
result-preserving; narrowing on `ranked` would silently drop those 7 from every search.

`max_ranked_position` is deliberately **not** applied here. It resolves in Postgres against
live `RankedItem.rank`, so the one rank filter users actually see can never be stale. The
indexed copy is only ever asked "does this exist", where a stale entry is either harmless (the
Postgres join drops it) or self-correcting on the next reindex.

### 5.3 Rank without a cache

Legacy used a 24-hour `Rails.cache` hash to avoid an N+1 on rank lookup. This design uses a
scoped association instead — no Redis, no TTL, and the value is read live every time:

```ruby
has_one :primary_ranked_item,
  -> { where(ranking_configuration_id: Books::RankingConfiguration.default_primary&.id) },
  as: :item, class_name: "RankedItem"
```

```ruby
def self.model_includes
  [:authors, :categories, :countries, :list_items, :original_language, :primary_ranked_item]
end

def as_indexed_json
  { ..., ranked: list_items.any?, ranked_position: primary_ranked_item&.rank }
end
```

The scope lambda evaluates **once per preload**, not once per record, so a 1,000-book batch
costs one extra query. `list_items.any?` reads the preloaded association in memory during bulk
indexing and falls back to an `EXISTS` query for a single record. `SearchIndexable` enqueues a
`SearchIndexRequest` rather than indexing inline, so every path goes through this batch
framework.

**The rank fields stay inside `as_indexed_json` on purpose.** Owning them solely in a partial
update pass would be cheaper, but `index_item` does a full document replace — so a book edited
in admin would have its `ranked_position` wiped and vanish from every saved search until the
next recalc.

The partial bulk update still exists, for the case that actually needs it: after a ranking
recalculation, when 24k ranks change and no book row does. It chains off the books recalc — the
same hook the authors recalc already uses — and updates only `ranked` and `ranked_position`
via the bulk `update` action. Both paths write the same two fields.

### 5.4 Fetching ids past the result window

Even narrowed to 24,242, loose searches exceed the 10,000 result window. Ids are pulled with
**`search_after` on `_doc` in 10k batches** — at most 3 round trips at current scale. Legacy
used the scroll API; `search_after` is the modern equivalent and needs no server-side context
cleanup.

Adding these fields requires recreating the index and reindexing all 126,282 books. One-time,
via the existing `reindex_all`.

---

## 6. Query layer

Three objects, each testable in isolation.

**`Books::SavedSearchCriteria`** — a PORO over the raw hash owning every legacy coercion:
`ranked` arrives as the string `"true"`, years as `"1980"`, `book_length` as an array of ints,
`book_type` as a bare int. Typed readers out; no database, no OpenSearch.

**`Search::Books::Search::BookAdvanced`** — criteria → bool query → ids.

| Criterion | Clause |
|---|---|
| `included_category_ids`, mode `any` | `filter: {terms: {category_ids: ids}}` |
| `included_category_ids`, mode `all` | one `filter: {term: {category_ids: id}}` per id |
| `excluded_category_ids` | `must_not: {terms: {category_ids: ids}}` |
| `book_type` | `filter: {term: {category_ids: BOOK_TYPE_CATEGORY[v]}}` |
| `included_language_ids` | `filter: {terms: {original_language_id: ids}}` |
| `excluded_language_ids` | `must_not: {terms: {original_language_id: ids}}` |
| `included_country_ids` | `filter: {terms: {country_ids: ids}}` |
| `excluded_country_ids` | `must_not: {terms: {country_ids: ids}}` |
| `book_length` | `filter: {terms: {book_length: values}}` |
| `first_year_published_gt` / `_lt` | `filter: {range: {first_published_year: {gte:, lte:}}}` |
| `ranked` | `filter: {term: {ranked: bool}}` |
| *always* | `filter: {exists: {field: ranked_position}}` |

**`Books::SavedSearchQuery`** — criteria + ranking configuration + viewer → the `RankedItem`
relation. It applies `max_ranked_position` as `where(rank: ..n)`, `hide_read` as an exclusion
of the read list, then `.order(:rank)`. Same return contract as `Books::RankedBooksQuery`, so
the existing grid components and `pagy_path` are untouched.

### Preserved behaviors, deliberate not accidental

- **`hide_read` filters against the search's owner, not the viewer.** Legacy passes
  `@search.user` as `current_user`. A public search with `hide_read` therefore hides books
  *its owner* has read. Preserving this keeps results stable for the owner, which is the point
  of a saved search.
- **Unknown category/language/country ids match nothing rather than 404.** The opposite of the
  public-filters spec's choice, and correctly so: a saved search is private user data, not an
  indexable URL space.
- **`result_count` and `last_executed_at` are written on every view** — a write on a read
  request. It is what the index page's "N results / last run X ago" reads, and 4,356 of 4,391
  rows have it set.

### Performance item to verify

The id set handed to Postgres can reach 24,242 entries, and pagy issues a `COUNT` over it. If
`WHERE item_id IN (…)` is slow at that width, the fallback is `= ANY(VALUES …)`. The number to
beat is the filters spec's measured 195 ms count.

---

## 7. Model & migration

### 7.1 `SavedSearch` STI

A shared `saved_searches` table with STI, mirroring `UserList` — the closest analogue in the
app for user-owned, per-domain, public/private content. Per-domain differences live entirely
in the `criteria` jsonb, so the envelope genuinely is shared.

```
saved_searches
  id, type (null: false), user_id (FK users, null: false)
  name (string), description (text), criteria (jsonb, null: false)
  public (boolean, default false, null: false)
  last_executed_at (datetime), result_count (integer)
  timestamps
  index user_id, index (type, user_id)
```

```ruby
class SavedSearch < ApplicationRecord
  belongs_to :user
  validates :criteria, presence: true
  scope :public_searches, -> { where(public: true) }
  scope :by_last_executed, -> { order(last_executed_at: :desc) }
  scope :by_created,       -> { order(created_at: :desc) }
  def self.visible_to(user) = ...      # public OR owner
  def display_name = name.presence || "Search #{id}"
  def execute(viewer:)     = self.class.query_class.call(...)
end

class Books::SavedSearch < ::SavedSearch
  def self.criteria_class              = Books::SavedSearchCriteria
  def self.query_class                 = Books::SavedSearchQuery
  def self.ranking_configuration_class = Books::RankingConfiguration
  def self.excluded_list_type          = :read
end
```

`summary` ports from legacy for the index page, reading `book_type` through the same §4.2
constant.

Ids are preserved with a reserved sequence ceiling — the pattern the `user_lists` migration
already used — because `/searches/:id` must keep resolving.

### 7.2 `SavedSearchMigrator`

4,391 rows via `BulkUpsertMigrator`, ids preserved. Two transformations, both load-bearing:

1. **`criteria` is double-encoded.** The legacy jsonb column holds a JSON *string*, not an
   object — `jsonb_typeof` returns `string` for all 4,391 rows. Unwrap on read
   (`(criteria #>> '{}')::jsonb`), store real jsonb. Skipping this stores an unqueryable
   string and every migrated search silently matches everything.
2. **Category ids remap** through `legacy_id_maps` (`model: 'Books::Category'`). Languages and
   countries pass through untouched.

Id arrays normalize to integers; scalar values copy verbatim and `SavedSearchCriteria` coerces
them at read time.

**e2e assertion with exact counts**, in the established style: 4,391 rows, 50 public, 4,356
with `last_executed_at`, 1,152 distinct users, all 531 category ids resolving, idempotent on
re-run.

---

## 8. Routes & legacy URL compatibility

Routes are **global, not inside the books `DomainConstraint`**, mirroring `my_lists`.
`Current.domain` picks the STI subclass, so books works now and games later gets `/searches`
on its own host with no new routes.

```ruby
get    "searches",                to: "saved_searches#index",   as: :saved_searches
get    "searches/new",            to: "saved_searches#new",     as: :new_saved_search
post   "searches",                to: "saved_searches#create"
get    "searches/:id",            to: "saved_searches#show",    as: :saved_search
get    "searches/:id/page/:page", to: "saved_searches#show",    as: :saved_search_page
get    "searches/:id/edit",       to: "saved_searches#edit",    as: :edit_saved_search
patch  "searches/:id",            to: "saved_searches#update"
put    "searches/:id",            to: "saved_searches#update"
delete "searches/:id",            to: "saved_searches#destroy"

get "v/:view_type/searches",                to: redirect("/searches", status: 301)
get "v/:view_type/searches/:id",            to: "saved_searches#show"
get "v/:view_type/searches/:id/page/:page", to: "saved_searches#show"
```

`:id` and `:page` are constrained to `/\d+/`; `:view_type` to `/grid|table|list/`.

**`/v/:view_type/searches/:id` renders for real rather than 301ing.** A redirect to
`/searches/:id` would silently discard the view the user bookmarked. Legacy drove the view
entirely from the URL segment and so does this — no `view_mode` column, no schema change. The
show page's view switcher emits these same paths, as legacy's `BookListViewComponent` did.

**The `view_type` constraint is load-bearing**, the same reasoning the browse routes
documented for `sort`/`filter`: unconstrained, `/v/anything/searches/1` becomes an unbounded
space of indexable soft-duplicates.

**Private searches 404 rather than 403** — `visible_to` mirrors `UserList.visible_to`. A 403
would confirm the id exists.

`require_signed_in!` guards index/new/create/edit/update/destroy; `show` is
anonymous-reachable for public searches. `Cacheable` + `prevent_caching` throughout: these
pages are per-user *and* write `last_executed_at` on read, so they must never reach the edge
cache. `/searches` gets a robots.txt `Disallow`, consistent with user lists.

Legacy `?page=N` links should keep resolving, since `pagy_path_request` merges
`request.query_parameters` — to be confirmed during implementation, not assumed.

---

## 9. UI

**`index`** lists the user's searches: display name, description, `summary`, result count,
public badge, last-run time.

**`show`** renders the active-filters card, a view switcher emitting
`/v/grid|table|list/searches/:id`, and results through the existing books grid components and
`pagy_path`.

**`new` / `edit`** share one form. Legacy's 10KB partial simplifies substantially: it used
server-backed autocomplete for all three taxonomies, but only categories need it. **201
languages and 253 countries are plain multi-selects**, no round trip. Categories reuse
`Books::CategorySearchQuery` plus one Stimulus chips controller modeled on the filter modal's
genre search.

Legacy's mutual-exclusion JavaScript — which disabled "exclude" once "include" had values for
languages and countries — is **dropped**. Including French while excluding German is coherent;
the guard only ever prevented redundancy, never incorrectness.

The domain seam is the form body: a shared shell renders
`saved_searches/books/_criteria_fields`, so another domain adds a partial and nothing else.

---

## 10. Extending to other domains

The generic pieces are: the `SavedSearch` root model and its policy, the global routes and
`Current.domain` resolution, the controller base, the OpenSearch → ids → `RankedItem` →
`pagy_path` pipeline, and the index/show/new/edit views. What is genuinely per-domain is the
criteria schema, the `BookAdvanced` equivalent, and the form's field partial.

**Games** is the natural next domain and needs its own spec. It has no migration and no legacy
URLs, and `Games::Game` already indexes `category_ids`, `platform_ids`, and `developer_ids` —
but its index is missing much of what filtering would need, `release_year`, `ranked`, and
`ranked_position` among them. `Games::UserList` has `played`, the `hide_read` analogue.

**Music** is deferred further: it needs `Music::Albums::SavedSearch` *and*
`Music::Songs::SavedSearch` against two separate indexes.

---

## 11. Testing

**Unit.** `SavedSearchCriteria` and `Books::BookLength` are pure functions — table-driven
against legacy's thresholds, letter rejection, and the `word_count / 275.0` rule.
`BookAdvanced` asserts the **built query hash**, covering every criterion→clause mapping with
no OpenSearch running. `SavedSearchQuery` covers the rank filter, `hide_read` exclusion, and
ordering.

**Model & policy.** Validations, `display_name`, `summary`, `visible_to`; policy cases for
owner, public, other, anonymous.

**Migration.** Migrator unit tests plus the §7.2 e2e exact-count assertion.

**Controller / integration.** Search classes are stubbed, per house style
(`AlbumAutocomplete.stubs(:call)`). Cases: owner 200, public + anonymous 200, private + other
404, past-last-page 404, `require_signed_in!` on the write actions, `/v/grid` rendering,
create/update/destroy. **`assert_queries_count` on `show`** — the results grid renders authors
and covers in a loop, exactly the N+1 shape.

**E2E (Playwright).** One spec: create a search → apply filters → assert results → edit →
delete.

---

## 12. Increments

Each is its own PR. Gate before each: `bin/rails test` + `bundle exec standardrb`.

| # | Scope | Verifiable by |
|---|---|---|
| 1 | `book_length` / `page_range` / `word_count` columns, `Books::BookLength`, `BookAttributesMigrator`, category backfill, rake wiring | e2e exact counts |
| 2 | Index fields, `primary_ranked_item`, `as_indexed_json`, reindex, post-recalc partial update | index document assertions |
| 3 | `SavedSearch` STI + policy + `SavedSearchMigrator` | e2e exact counts (4,391 / 50 / 1,152) |
| 4 | `SavedSearchCriteria`, `BookAdvanced`, `SavedSearchQuery` | unit tests; nothing user-visible |
| 5 | Routes, controller, index + show, view switcher, legacy URLs | hand-typed legacy URLs |
| 6 | new/edit form, Stimulus picker, create/update/destroy | Playwright |
| 7 | E2E + docs | CI |

Increments 1–4 are invisible to users; the feature turns on at 5.

---

## 13. Landmines

- **`criteria` is double-encoded jsonb** — a JSON string, not an object, for all 4,391 rows
  (§7.2). The highest-consequence trap in this spec.
- **Category ids are remapped, not preserved** — 73,913 map rows, zero identity. Languages are
  identity and countries are preserved, which makes it easy to assume categories are too
  (§4.1).
- **Never merge `book_type` into `included_category_ids`** — 183 searches use OR mode and would
  be silently corrupted (§4.2).
- **Narrow on `exists: ranked_position`, not `ranked`** — the latter drops 7 scored books from
  every search (§5.2).
- **Rank fields must stay in `as_indexed_json`** — `index_item` is a full document replace, so
  a partial-update-only design loses them whenever a book is edited (§5.3).
- **`upsert_all` cannot update `books_books`** — its INSERT arm must satisfy NOT NULL `title`
  and `slug`. Use `UPDATE … FROM (VALUES …)` (§4.4).
- **`rails g model` for an STI subclass needs `--no-fixture`** — a `saved_searches` fixture for
  the subclass takes down the whole suite, as `Books::UserList` proved.
- **A route `constraints:` inside `scope "(/rc/...)"`** disables the optimized url helper and
  binds the positional arg to the rc segment. Not applicable here (§2 rules out `rc/`), but it
  is the reason no `rc/` prefix appears.
- **Inside `Services::BooksMigration`, a bare `Music::` resolves to `Services::Music`.**
  Root-anchor constants in migrator code.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** Read fixture
  YAML directly; never run it against development.
