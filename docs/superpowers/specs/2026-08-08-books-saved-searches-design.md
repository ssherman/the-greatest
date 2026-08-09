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
`Books::RankedBooksQuery`, over the ranked set only. That stays as it is. Saved searches reach
further — the `ranked` criterion can ask for the whole corpus (§3) — so the two share neither an
engine nor a relation type. What they do share is the **rendering** contract:
`Books::CardComponent` takes a `book:` and an optional `rank:`, so both feed the same grid, as
does the author all-books page. When main-page filtering eventually moves to OpenSearch, this
design is the thing it moves toward.

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
- **CSV export.** Legacy has a `CsvExport` model worth porting close to wholesale: async status
  states (`pending → processing → uploading → completed`), an attached file rather than a
  synchronous stream, `find_matching(name:, url_path:, book_limit:)` to dedup identical requests,
  and a `book_limit` that bounds the row count. That design already answers the "someone exports
  the whole corpus" problem structurally. The limit is settled empirically too: of 1,995 legacy
  exports, **1,771 used `book_limit: 500`** and all completed. It needs the feature to exist
  first (increment 5), so it is a later increment or its own spec — not part of 3–7.

  If it is ever gated behind payment, note the prerequisite: legacy has 115 live subscriptions and
  21 donations, but **nothing subscription-, donation-, or payment-related has been migrated to
  this app**. Paid gating is a much larger piece of work than the export itself.

**Deliberately not limited:** browsing results. `from + size ≤ 10,000` already caps a filter-less
search at 10,000 books through the UI (§5.4). Capping the result *set* on top of that would break
legitimate broad searches — "all fiction since 1900" is a real query with 20k+ matches. The bound
belongs on export, not on browsing.

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
**24,249 with a score**. So a legacy saved search never returns unranked books, regardless of its
criteria — including when the user explicitly asked for them.

That is a **defect, not a design**, and this port does not reproduce it. See "The `ranked`
criterion never worked" below; §5.2 and §5.4 carry the consequences for the query layer.

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

### The `ranked` criterion never worked, and this design fixes it

The legacy form offers three states — `[["All Books", ""], ["Only Ranked Books", "true"],
["Only Unranked Books", "false"]]` — but its pipeline can only deliver one of them.
`advanced_search` ends in `books.sorted_by_rank(...)`, which **inner-joins** `ranked_books` on a
non-nil score, so every result is a ranked book no matter what `ranked` is set to. "All Books" and
"Only Unranked Books" were unreachable by construction.

The 13 stored `ranked: "false"` searches did return results — 16 to 98 of them — but those were
stale-index artifacts: books the index still labelled `ranked: false` after they had joined a list
and been scored, because legacy had no reindex hook on list membership either (the same `ListItem`
gap this app has). Those users, six of them, never saw a genuine unranked-books result set.

**Decision: implement all three states properly.** `true` → the ranked set only; `false` → unranked
books only; absent → the whole corpus. This is the one place this port deliberately diverges from
legacy behaviour, because legacy's behaviour was a defect rather than an intent — the UI promised
three things and delivered one. §5.2 and §5.4 carry the consequences.

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

Legacy's `book_type` column is `NOT NULL DEFAULT 0` (fiction), so "fiction" is partly a column
default rather than a classification — every book nobody typed also reads as fiction. Post-run
dev state is Fiction 68,333 + Nonfiction 56,222 = 124,555 of 126,289 books. A future reader
should not treat Fiction's membership count as a signal of how much of the corpus was
deliberately classified; the incremental harm is small (inherited from legacy verbatim, not
introduced here) and already accepted.

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

These 6,726 books' OpenSearch documents are stale the moment the backfill migrator runs:
`as_indexed_json` includes `category_ids`, but the migrator's `upsert_all` bypasses the
`SearchIndexable` reindex hook entirely, and the whole run is wrapped in
`without_search_indexing` (§4.4) besides. So the new category links exist in Postgres but do not
appear in search results until something reindexes. That something is increment 2's full
`reindex_all` (§5.4) — this increment does not correct the index on its own, and the dependency
is deliberate, not an oversight.

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

### 5.2 `ranked_position` is the narrowing filter — but only for `ranked: true`

**This section was amended after increment 2 shipped.** It originally applied the narrowing filter
to every query, on the assumption that results are always a subset of the ranked set. That
assumption came from legacy's inner join, which §3 establishes was a defect. Now that all three
`ranked` states are implemented, only one of them can be narrowed:

| `ranked` | OpenSearch clause | candidates |
|---|---|---|
| `"true"` | `filter: {exists: {field: "ranked_position"}}` | ~24,242 |
| `"false"` | `must_not: {exists: {field: "ranked_position"}}` | ~102,047 |
| absent | *no rank clause* | 126,289 |

The narrowing filter is therefore an optimisation available to one third of the cases, not a
universal precondition. §5.4 covers how the other two stay tractable.

It must be `ranked_position` and not `ranked`. The two are close but not equal in principle:
`ranked` tracks list membership, `ranked_position` tracks the `RankedItem` set, and nothing
guarantees the two agree. Measured against the rebuilt index, they currently do: 24,362 books
have list items, 24,242 carry a `ranked_position`, and **0** scored books have no list items —
so today, narrowing on either field returns the same result. `exists` on `ranked_position`
**is** the `RankedItem` set by construction, so it remains the correct choice regardless: it is
guaranteed result-preserving, where `ranked` agreeing today is a fact about the current data, not
a fact about the field. (An earlier measurement, before the rebuild, showed 7 scored books
missing list items; the current build shows none.)

**Amended before increment 4.** This section originally kept `max_ranked_position` in Postgres,
against live `RankedItem.rank`, so the one rank filter users see could never be stale. That is no
longer possible: §5.4 moved paging into OpenSearch, and a filter applied after the page is sized
returns short pages. `max_ranked_position` is now `range: {ranked_position: {lte: n}}` against the
indexed copy (§6).

This is more coherent than the original, not merely a concession. §5.4 already **orders** by the
indexed `ranked_position`; filtering by live rank while sorting by the indexed copy could place a
book inside the ordering but outside the filter, or the reverse. Both now read one source.

Staleness is bounded by increment 2's `Books::ReindexRankedFieldsJob`, chained off
`CalculateRankingsJob`, so the indexed rank trails live rank only between a recalculation and its
reindex.

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

**`ranked` has no independent refresh path of its own.** Unlike `CategoryItem` and
`Books::BookAuthor`, `ListItem` carries no `SearchIndexable` reindex hook, so nothing reindexes a
book when it joins or leaves a list. The recalculation job therefore derives `ranked` itself, per
batch, from live `ListItem` membership for that batch's book ids, and writes it in the same
partial update as `ranked_position`. Writing both fields from one source in one request is what
keeps them from disagreeing — computing `ranked` separately (or worse, assuming every newly-scored
book is also listed) would let the two drift apart the moment a book is ranked without being on
any list.

### 5.4 OpenSearch sorts and pages; Postgres hydrates one page

**This section was amended after increment 2 shipped**, for the same reason as §5.2. The original
design pulled *every* matching id — `search_after` on `_doc` in 10k batches — and let Postgres sort
and page them. That was viable only while results were capped at the ~24k ranked set. With the
whole 126,289-book corpus reachable, it would mean a 126k-element `IN` clause per page view, which
is not.

**OpenSearch now does the sorting and paging**, and returns one page of ids:

```
sort: [
  {ranked_position: {order: "asc", missing: "_last"}},
  {first_published_year: {order: "asc", missing: "_last"}},
  {"title.keyword": {order: "asc"}}
]
from: (page - 1) * per_page
size: per_page
```

Ranked books come first in rank order, unranked follow. All three sort fields are already in the
mapping from increment 2. Postgres then hydrates exactly those ids and re-applies the OpenSearch
order.

This is **simpler** than what it replaces — the `search_after` batching disappears entirely — and
it mirrors an ordering the app already ships: `Books::AuthorsController#all_books_relation` sorts
`ranked_items.rank ASC NULLS LAST, first_published_year ASC NULLS LAST, title`, which is the same
shape expressed in SQL.

**The base relation changes accordingly.** It is no longer a `RankedItem` relation but a
`Books::Book` relation left-joined to `ranked_items`, again mirroring `all_books_relation`:

```ruby
Books::Book
  .where(id: page_ids)
  .select("books_books.*, ranked_items.rank AS ranked_position")
  .joins("LEFT OUTER JOIN ranked_items ON ranked_items.item_id = books_books.id
          AND ranked_items.item_type = 'Books::Book'
          AND ranked_items.ranking_configuration_id = #{rc.id.to_i}")
```

`Books::CardComponent` already takes `book:` and an optional `rank:`, so the results grid needs no
component change — an unranked result simply renders without a position badge, exactly as the
author all-books page does today.

**`max_ranked_position` moved into OpenSearch too** (amended before increment 4). This section
originally left it in Postgres on the grounds that it only ever applies to ranked books, so paging
did not disturb it. That was wrong: it filters, and any filter applied after OpenSearch sizes the
page removes rows from a page already counted. It is now a range filter on the same indexed
`ranked_position` this section sorts by (§5.2, §6).

**Deep paging cap.** `from + size` may not exceed `index.max_result_window` (10,000 by default), so
page 200 at 50 per page is the practical limit. Legacy had the same ceiling and nobody reached it;
raise the window or switch that path to `search_after` only if it ever matters.

Adding these fields requires recreating the index and reindexing all 126,282 books. One-time,
via the existing `reindex_all`.

### 5.5 Cutover must recreate the index, not just reindex it

`create_index` is skip-if-exists — it returns immediately whenever the index is already present.
So deploying this increment's code does not, by itself, change the mapping of a books index that
already exists. Between deploying and running the cutover reindex, the live index still has the
old mapping: the six new fields are simply absent from it.

If anything indexes a book in that window — an admin edit, a `CategoryItem` or
`Books::BookAuthor` change, any path that runs a `SearchIndexRequest` through the ordinary
`Search::IndexerJob` — the document it writes now populates `country_ids` and
`original_language_id` for the first time. OpenSearch has no explicit mapping for them yet, so it
dynamically infers a type from the JSON value: both are integer ids, so OpenSearch maps them
`long`, not the `keyword` this design's `terms`/`term` filters require.

Once that dynamic mapping is set, it is permanent for that index, because `create_index`'s
skip-if-exists guard means nothing later re-declares it. **This self-heals only because the
cutover task deletes and recreates the index:** `search:books:recreate_books` calls
`reindex_all`, which is `delete_index` (if present) followed by `create_index`, so any
dynamically-mapped field is wiped along with the rest of the index and rebuilt with the correct
explicit mapping. Re-running the ordinary indexer alone — `Search::IndexerJob`, or any other path
that calls `bulk_index`/`index_item` without first deleting the index — would leave the wrong
types in place silently; neither method checks or corrects an existing mapping.

**Cutover requirement:** deploy this increment and run `search:books:recreate_books` (or
`search:books:recreate_and_reindex_all`) in the same window, before any other book write can
reach the index. Do not rely on the periodic `Search::IndexerJob` to pick the new fields up
gradually — for `country_ids` and `original_language_id`, that path locks in the wrong type
instead.

---

## 6. Query layer

Three objects, each testable in isolation.

**This section was amended before increment 4 was planned.** §5.4's amendment moved sorting and
paging into OpenSearch, but this section still described `max_ranked_position` and `hide_read` as
Postgres-side filters — applied *after* OpenSearch had already sized the page, which returns short
pages under an overstated total. Both now resolve in OpenSearch, which makes it the single source of
filtering, sorting, paging, and the count. The changes are marked below.

**`Books::SavedSearchCriteria`** — a PORO over the raw hash owning every legacy coercion.
Typed readers out; no database, no OpenSearch.

Its readers are **tolerant on input**, because two populations of criteria have to coexist: the
4,727 migrated rows (which store `book_type` as an Integer and `ranked` as the string `"true"`) and
future form-created rows (whose params arrive as strings). Rather than normalizing on write — a step
any future writer can forget — every reader accepts both shapes:

| Reader | Returns | Accepts |
|---|---|---|
| `included_*_ids` / `excluded_*_ids` | `[Integer]` | strings or ints |
| `book_type` | `Integer` or nil | `0` or `"0"` |
| `book_length` | `[Integer]` | filtered to valid enum values 0–5 |
| `first_year_published_gt` / `_lt` | `Integer` or nil | `"1980"` or `1980` |
| `ranked` | `:ranked` / `:unranked` / **nil** | `"true"`, `true`, `"false"`, `false` |
| `genre_match_mode` | `:any` / `:all` | string |
| `hide_read` | boolean | |
| `max_ranked_position` | `Integer` or nil | |

`ranked` returns a **tri-state symbol, not a boolean**: nil (whole corpus) and `:unranked` are
different requests, and a boolean cannot hold three states.

`book_length` filtering at the reader also closes a latent bug in increment 3's `#summary`, where an
out-of-range value rendered a stray `" Length"` with no name.

**`Books::SavedSearch#summary` is refactored to read through this object** rather than the raw hash.
That removes the duplicated coercion and the Integer-vs-String fragility at its source: `summary`'s
`BOOK_TYPE_LABELS` lookup is keyed on Integers today and would silently drop the label for a
form-created search storing `"0"`.

**`Books::BookType`** — one value object mapping `0..3` to its label and its legacy category id,
resolving the current environment's category id through `LegacyIdMap`, memoized. It absorbs both
existing constants: `Books::SavedSearch::BOOK_TYPE_LABELS` and
`BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS`. Without it the query layer would introduce a
*third* independent map keyed on the same legacy 0–3 integers.

Resolution is at runtime, not hardcoded new ids. Measured 2026-08-09: dev and production both
resolve to `{0=>2683, 1=>3348, 2=>9343, 3=>3211}` — so hardcoding would work today. Runtime
resolution is preferred only because it costs nothing, matches what `BookTypeCategoryMigrator`
already does, and does not depend on that agreement holding. Note the agreement itself is worth
knowing: `categories` is a shared cross-domain table whose ids were *not* preserved, and the two
migrations ran independently, so divergent ids is the natural assumption — and it is wrong.

**`Search::Books::Search::BookAdvanced`** — criteria → bool query → one page of ids plus a total.

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
| `ranked: "true"` | `filter: {exists: {field: ranked_position}}` |
| `ranked: "false"` | `must_not: {exists: {field: ranked_position}}` |
| `ranked` absent | *no rank clause — the whole corpus* |
| `max_ranked_position` | `filter: {range: {ranked_position: {lte: n}}}` **(amended — was Postgres)** |
| `hide_read` | `must_not: {ids: {values: owner_read_book_ids}}` **(amended — was Postgres)** |

**`max_ranked_position` means "ranked 1..n in the default global ranking configuration".** It is a
primary filter, not a trim applied to results afterward, and the indexed `ranked_position` answers it
directly because `Books::Book#as_indexed_json` populates it from `primary_ranked_item`, which is
scoped to `Books::RankingConfiguration.default_primary`. Two consequences, both correct: it already
implies ranked-only, so it does not need `ranked: "true"` alongside it; and combined with
`ranked: "false"` it is self-contradictory and returns nothing.

**`hide_read` excludes the search owner's read list**, so its ids come from one Postgres query
before the OpenSearch call, using increment 3's `SavedSearch.excluded_list_type` hook. Measured on
the migrated corpus: read lists run to a median of 20 books, p99 412, max 11,092 — comfortably under
OpenSearch's 65,536-term ceiling, and only one list exceeds 10,000.

**`ranked` resolves against `ranked_position`, not the `ranked` field.** The indexed `ranked`
boolean means "appears on at least one list", which is a different fact: 120 books sit on a list
without being in the ranked set (some on unapproved lists, some on active lists that fall outside
the primary configuration). The criterion means "is in the ranked set", so `ranked_position` is
what answers it. The `ranked` field stays indexed for now but no query reads it — see §13.

**`Books::SavedSearchQuery`** — criteria + ranking configuration + viewer → one hydrated page of
**`Books::Book`** records plus the total. It left-joins `ranked_items` (§5.4) to carry
`ranked_position` in its select, and re-applies OpenSearch's order in Ruby, since Postgres cannot
reproduce the ranked-then-unranked interleaving from an `IN` clause. It therefore returns an array,
not a relation. `Books::CardComponent` takes `book:` and an optional `rank:`, so the grid renders
this directly; unranked results simply carry no position badge.

**It no longer applies any filter of its own** (amended). `max_ranked_position` and `hide_read` moved
into `BookAdvanced` above, because a filter applied after OpenSearch has sized the page removes rows
from a page already counted — yielding short pages under an overstated total.

`ranking_configuration:` is a parameter, defaulting to `Books::RankingConfiguration.default_primary`.
For now only the default primary is supported and anything else **raises**: the index carries only
the default primary's rank, so a non-default configuration cannot be answered from `ranked_position`
and would silently return the wrong ranks. Keeping it a parameter preserves the seam without
building the path.

### Preserved behaviors, deliberate not accidental

- **`hide_read` filters against the search's owner, not the viewer.** Legacy passes
  `@search.user` as `current_user`. A public search with `hide_read` therefore hides books
  *its owner* has read. Preserving this keeps results stable for the owner, which is the point
  of a saved search.
- **Unknown category/language/country ids match nothing rather than 404.** The opposite of the
  public-filters spec's choice, and correctly so: a saved search is private user data, not an
  indexable URL space.
- **A criterion that is present but cannot be resolved matches nothing, never everything.** This is
  the general rule the bullet above is one case of, and it binds beyond ids: `book_type` resolves
  through `LegacyIdMap`, a migration artifact table, so an absent mapping is reachable in a way a
  hardcoded constant never would be. The failure mode to avoid is a filter clause silently dropped
  because it couldn't be built — that reads as "no criterion", which is a match-all, not the
  match-nothing an unresolvable criterion must produce. Every filter in `BookAdvanced` follows this:
  a criterion that is absent contributes no clause; a criterion that is present but unresolvable
  contributes a match-nothing clause (an empty `terms` array, verified against the real index).
- **`last_executed_at` is written on view** — a write on a read request, and the only one. It
  drives `by_last_executed`, the index page's default ordering. That write belongs to increment 5's
  controller; increment 4 is read-only throughout.

**`result_count` is no longer written** (amended). Its only consumer was the index page's "N
results" label, where it exists so a listing can show a number without executing every search. It is
stale by construction — rankings recalc daily and books are added — and for the migrated rows it is
a figure from the legacy site, potentially years old. Nothing acts on it: the summary line is what
distinguishes one saved search from another. The column keeps its migrated legacy values as
historical data, and whether the index page displays counts at all is an increment 5 decision.

### Counting and the paging ceiling

`track_total_hits` stays at OpenSearch's default of 10,000. This is not a compromise: `from + size`
may not exceed `index.max_result_window` (also 10,000, §5.4), so result 10,001 is unreachable and
counting past it buys pagination nothing.

The 10,000 default would only matter for *display* — 419 of 4,356 migrated searches carry a legacy
`result_count` above 10,000, the largest 24,189 — and since `result_count` is no longer written and
the index page's counts are deferred to increment 5, no consumer needs an exact total today. If
increment 5 decides to show one, `track_total_hits: true` is the switch, and it is cheap at this
corpus size.

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

**Ids are preserved outright, with no reserved ceiling** — `/searches/:id` must keep resolving,
and `saved_searches` is created empty by this increment with nothing else writing to it. This is
the `books_countries` case, not the `user_lists` one: `user_lists` needed
`IdRangeReservationService` because it already held new-app rows from the other domains, whereas
here there is no id contention to resolve. `finalize` resets the primary-key sequence past the
migrated maximum so later inserts do not collide, exactly as `CountryMigrator` does.

**Sequencing requirement:** the migration must run before saved searches become creatable in
production. That holds naturally — the books site is not yet serving its production domain, and
no other domain has a `SavedSearch` subclass. The migrator uses `find_or_initialize_by(id:)`,
which finds and overwrites a same-type row already at that id rather than raising — that
overwrite-on-match is exactly what makes a re-run idempotent, verified against all 4,391 rows.
Collision safety therefore comes from sequencing, not a code guard: run before the creation UI
ships, and no other writer can ever be occupying a target id in the first place.

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
`SavedSearchCriteria` asserts every reader in **both** storage shapes — `0` and `"0"`, `"true"` and
`true` — since migrated and form-created rows differ (§6).

`BookAdvanced` is tested against a **real test index**, matching every other search class in this
app (`cleanup_test_index` → `create_index` → index fixtures → assert), with one case per
criterion→clause proving it narrows. Built-query-hash assertions are kept only where a clause's
*shape* is the thing under test rather than its effect — `genre_match_mode: all` generating one term
filter per id. A hash assertion alone cannot catch a clause that is well-formed but mismatched
against the mapping, which is the failure this layer is most exposed to.

`SavedSearchQuery` covers hydration, the re-applied OpenSearch ordering, and the non-default
ranking-configuration guard. The rank filter and `hide_read` exclusion are `BookAdvanced`'s, not
its (§6).

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
| 4 | `SavedSearchCriteria`, `Books::BookType`, `BookAdvanced`, `SavedSearchQuery`, `#summary` refactor | unit tests; nothing user-visible; read-only |
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
- **The `ranked` criterion resolves against `ranked_position`, never the indexed `ranked` field.**
  They answer different questions: `ranked` means "on at least one list", and **120 books are on a
  list without being in the ranked set** (unapproved lists, and active lists outside the primary
  configuration). Only `exists: ranked_position` **is** the `RankedItem` set by construction
  (§5.2, §6).
- **The narrowing filter is not universal.** It applies only to `ranked: "true"`. The other two
  states can match the whole 126,289-book corpus, which is why OpenSearch — not Postgres — does
  the sorting and paging (§5.4). Any change that reintroduces "fetch every matching id" will fall
  over on a filter-less search.
- **No criterion may be applied in Postgres.** Once OpenSearch sizes the page, a filter applied
  downstream removes rows from a page already counted, so the page comes back short under an
  overstated total. This is why `max_ranked_position` and `hide_read` moved into the query (§6). The
  same trap catches any criterion added later.
- **`ranked` is a tri-state, and nil is not false.** Absent means the whole corpus; `:unranked`
  means unranked only. A boolean reader collapses the two and silently changes what a stored search
  returns (§6).
- **Criteria arrive in two storage shapes.** Migrated rows store `book_type` as an Integer and
  `ranked` as the string `"true"`; form params arrive as strings. The criteria readers absorb both —
  anything reading `criteria[...]` directly, as `#summary` originally did, breaks on one of them
  (§6).
- **Rank fields must stay in `as_indexed_json`** — `index_item` is a full document replace, so
  a partial-update-only design loses them whenever a book is edited (§5.3).
- **`ranked` has no reindex hook of its own** — `ListItem` isn't `SearchIndexable`, unlike
  `CategoryItem`/`Books::BookAuthor`. The recalculation job must derive and write `ranked`
  alongside `ranked_position` in the same partial update, or the two fields can drift out of
  sync (§5.3).
- **`create_index` is skip-if-exists, so a deploy alone never fixes a stale mapping** — a book
  indexed through the ordinary `Search::IndexerJob` between deploying this increment and running
  the cutover reindex lets OpenSearch dynamically (and permanently) mistype `country_ids` /
  `original_language_id` as `long`. Only a delete-and-recreate cutover (`search:books:recreate_books`)
  self-heals it (§5.5).
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
