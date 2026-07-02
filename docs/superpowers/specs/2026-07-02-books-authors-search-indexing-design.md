# Books & Authors Search Indexing — Design

## Status
- **Status**: Design approved; implementation plan pending
- **Priority**: High
- **Created**: 2026-07-02
- **Developer**: Shane Sherman

## 1. Overview

Build the OpenSearch **search backend** for the books domain — index definitions, the
indexing pipeline, and query classes — for `Books::Book` and `Books::Author`. This completes
**deferred item #6** of the books object-model spec
(`docs/superpowers/specs/2026-06-29-books-object-model-design.md` §12).

The books models already define `as_indexed_json` but intentionally do **not** include
`SearchIndexable` yet (so they don't enqueue rows nothing processes). This spec turns the
backend on and adds the query classes for the two short-term uses: **general-purpose search**
(books and authors) and **book autocomplete**.

Everything mirrors the **music domain** as the reference implementation (`Music::Album` ≈
`Books::Book`, `Music::Artist` ≈ `Books::Author`). The existing search infrastructure
(`Search::Base::Index`, `Search::Base::Search`, `Search::Shared::Utils`, the
`SearchIndexRequest` outbox queue, `Search::IndexerJob` cron) is reused unchanged; see
`docs/features/search.md`.

## 2. Scope

**In scope:**
- Index classes: `Search::Books::BookIndex`, `Search::Books::AuthorIndex`.
- Turn on the indexing pipeline for `Books::Book` and `Books::Author`.
- Query classes: `Search::Books::Search::BookGeneral`, `Search::Books::Search::AuthorGeneral`,
  `Search::Books::Search::BookAutocomplete`.
- Freshness triggers so book documents stay correct when authorship links or author names change.
- Rake tasks (`search:books:*`).
- Full test coverage (real OpenSearch, mirroring the existing search tests).
- Doc updates.

**Out of scope (explicitly not built here):**
- Any user-facing surface: no public search page, no `Books::SearchesController`, no views,
  no ViewComponents, no E2E tests.
- No `ListableAutocomplete` (add-item typeahead) wiring — books is not registered as a
  searchable listable type in this spec.
- No admin book/author select endpoints.
- `Books::Series` is **not** indexed (skipping extra index types for now). `Books::Series`
  retains its placeholder `as_indexed_json`; no `Search::Books::SeriesIndex` is created.
- No strict "by title and authors" dedup query class (dedup/import matching is deferred to
  its own spec and is identifier-based, not search-based).

## 3. Indexing pipeline wiring

The pipeline (model save → `SearchIndexRequest` outbox → `Search::IndexerJob` cron → bulk
index) already exists and is generic. Changes required:

### 3.1 Turn on `SearchIndexable`
- Add `include SearchIndexable` to `Books::Book` and `Books::Author`. Their `after_commit`
  hooks then enqueue `SearchIndexRequest` rows on create/update (`index_item`) and destroy
  (`unindex_item`).

### 3.2 Register the model types in `Search::IndexerJob`
- Add `"Books::Book"` and `"Books::Author"` to the model-type array in
  `Search::IndexerJob#perform`. The job already resolves the index class dynamically
  (`"Search::#{domain}::#{model_name}Index".constantize` → `Search::Books::BookIndex` /
  `Search::Books::AuthorIndex`), deduplicates by `[parent_type, parent_id, action]`, and
  bulk indexes/unindexes. No other job changes.

### 3.3 Category changes (free)
- `CategoryItem` already reindexes any item whose `as_indexed_json` includes a `:category_ids`
  key. Both book and author documents include it, so genre/subject/location category changes
  keep both indexes in sync with no new code.

### 3.4 Keep book documents fresh when embedded author data changes
The book document embeds `author_names` / `author_ids` (from `book.authors`, via
`Books::BookAuthor`). Because `Search::IndexerJob` deduplicates enqueued requests, enqueuing
liberally is safe (redundant requests collapse to a single op). Two triggers:

- **`Books::BookAuthor` `after_commit`** (create/update/destroy) → enqueue its `book` for
  reindex (`SearchIndexRequest` with `action: :index_item`, `parent_type: "Books::Book"`,
  `parent_id: book_id`). Covers adding, removing, reordering, and reassigning authorship.
- **`Books::Author` `after_commit`, guarded by `saved_change_to_name?`** → enqueue every one
  of the author's books for reindex. Covers author renames propagating into `author_names`.
  (`alternate_names` is not embedded in the book document, so only `name` changes need to
  cascade.)

**Destroyed-parent handling:** when a `Books::Book` is destroyed, its dependent
`book_authors` are destroyed too, and the `BookAuthor` trigger fires (`after_commit`) after
the book row is already gone. The trigger **must guard on book existence**
(`return unless Books::Book.exists?(book_id)`) before enqueuing — otherwise
`SearchIndexRequest.create!(parent_id: book_id, …)` raises `ActiveRecord::RecordInvalid`
("Parent must exist"), because `SearchIndexRequest belongs_to :parent` is presence-validated
(`belongs_to_required_by_default`). An earlier draft of this spec wrongly assumed the enqueue
could dangle and be skipped later by `Search::IndexerJob`'s `find_by(id:)` — but the enqueue
fails first, so the guard is required. (The `CategoryItem` precedent sidesteps this by passing
`parent: <in-memory object>`, which passes the presence check; this trigger passes a raw
`parent_id:`, so it needs the explicit `exists?` guard.) When the book is destroyed, the guard
skips the stale `index_item`; the book's own `SearchIndexable` `after_commit on: :destroy`
still enqueues the `unindex_item`, so the index stays consistent. This uses `after_commit`
(only enqueue if the transaction committed), which is more correct than `CategoryItem`'s
`after_save`/`after_destroy`.

## 4. Document shape (`as_indexed_json`)

### 4.1 `Books::Book` — extend the existing payload
```ruby
{
  title: title,
  subtitle: subtitle,               # ADDED (searchable; the legacy app searched sub_title)
  alternate_titles: alternate_titles,
  author_names: authors.map(&:name),
  author_ids: authors.map(&:id),
  category_ids: categories.active.pluck(:id),
  book_kind: book_kind              # ADDED (string enum value, e.g. "standalone") for filtering
}
```
- `book_kind` is the Rails enum's string value (`"standalone"` / `"collection"`), indexed as a
  `keyword` so queries can filter collections out.

### 4.2 `Books::Author` — unchanged
```ruby
{
  name: name,
  alternate_names: alternate_names,
  category_ids: categories.active.pluck(:id)
}
```

## 5. Index definitions

Two classes subclassing `Search::Base::Index`, each defining the shared analyzer block used
across all domains (`folding`, `autocomplete`, `autocomplete_search`) plus `model_klass`,
`model_includes`, and `index_definition`.

### 5.1 `Search::Books::BookIndex`
- `model_klass` → `::Books::Book`
- `model_includes` → `[:authors]` (mirrors `AlbumIndex`; `categories.active.pluck` queries
  regardless)

| Field | Type / analyzer | Subfields |
|---|---|---|
| `title` | text / folding | `.keyword` (keyword, lowercase normalizer), `.autocomplete` (autocomplete / autocomplete_search) |
| `subtitle` | text / folding | — |
| `alternate_titles` | text / folding | — |
| `author_names` | text / folding | `.keyword` |
| `author_ids` | keyword | — |
| `category_ids` | keyword | — |
| `book_kind` | keyword | — |

### 5.2 `Search::Books::AuthorIndex`
- `model_klass` → `::Books::Author`
- `model_includes` → `[]` (mirrors `ArtistIndex`)

| Field | Type / analyzer | Subfields |
|---|---|---|
| `name` | text / folding | `.keyword`, `.autocomplete` |
| `alternate_names` | text / folding | — |
| `category_ids` | keyword | — |

Index names auto-derive from the class (`Search::Books::BookIndex` → `books_books_{env}`,
`Search::Books::AuthorIndex` → `books_authors_{env}`; test appends `_{pid}`).

## 6. Query classes

All under `Search::Books::Search::`, subclassing `Search::Base::Search`, using
`Search::Shared::Utils` builders, and returning the standard
`[{ id:, score:, source: }]` via `extract_hits_with_scores`. Each has a `.call(text, options = {})`
that returns `[]` for blank text.

### 6.1 `BookGeneral` (general-purpose book search)
`should` clauses (boost), `minimum_should_match: 1`, plus a `filter` restricting to standalone:

| Clause | Field | Boost | Operator |
|---|---|---|---|
| match_phrase | `title` | 10.0 | — |
| term | `title.keyword` | 9.0 | — |
| match | `title` | 8.0 | and |
| match | `alternate_titles` | 7.0 | or |
| match_phrase | `author_names` | 6.0 | — |
| match | `author_names` | 5.0 | and |
| match | `subtitle` | 4.0 | and |

- `filter`: `term book_kind = "standalone"` → collections excluded.
- Defaults: `min_score: 1`, `size: 10`, `from: 0`.

### 6.2 `AuthorGeneral` (general-purpose author search) — mirrors `ArtistGeneral`
| Clause | Field | Boost | Operator |
|---|---|---|---|
| match_phrase | `name` | 10.0 | — |
| term | `name.keyword` | 8.0 | — |
| match | `name` | 5.0 | and |
| match | `alternate_names` | 3.0 | or |

- `minimum_should_match: 1`. Defaults: `min_score: 1`, `size: 10`, `from: 0`.

### 6.3 `BookAutocomplete` (book autocomplete) — mirrors `AlbumAutocomplete`
| Clause | Field | Boost |
|---|---|---|
| match | `title.autocomplete` | 10.0 |
| match_phrase | `title` | 8.0 |
| term | `title.keyword` | 6.0 |

- `filter`: `term book_kind = "standalone"` → collections excluded.
- `minimum_should_match: 1`. Defaults: `min_score: 0.1`, `size: 20`, `from: 0`.

Note: `Search::Shared::Utils.build_bool_query` already supports `should:` + `filter:` +
`minimum_should_match:` together.

## 7. Rake tasks

Add a `search:books:` namespace to `lib/tasks/search.rake`, mirroring `search:music:`:
- `search:books:recreate_and_reindex_all` — drop + recreate + reindex Books and Authors.
- `search:books:recreate_books` — reindex books only.
- `search:books:recreate_authors` — reindex authors only.

Each delegates to `IndexClass.reindex_all` (delete + create + `find_in_batches(1000)` bulk index).

## 8. Testing

Tests hit a real OpenSearch instance with PID-suffixed index names for isolation (the
established pattern). `setup`/`teardown` create/delete the test index; `sleep(0.1)` after
indexing to let OpenSearch refresh.

- **Index tests** — `test/lib/search/books/book_index_test.rb`,
  `test/lib/search/books/author_index_test.rb`: index_name includes env, `index_definition`
  mapping structure (analyzers, field types, subfields including `book_kind`), create/delete,
  index-and-find.
- **Query tests** — `test/lib/search/books/search/`:
  - `book_general_test.rb`: blank → `[]`; find by title; find by author name; find by
    alternate title; **collection book excluded**; relevance ordering; custom options.
  - `author_general_test.rb`: blank → `[]`; find by name; find by alternate name; ordering.
  - `book_autocomplete_test.rb`: blank → `[]`; prefix match on title; **collection book
    excluded**; custom options.
- **Model tests** — assert `Books::Book` and `Books::Author` enqueue a `SearchIndexRequest`
  on create/update and destroy; assert the `Books::BookAuthor` trigger enqueues an
  `index_item` for its book; assert `Books::Author` name-change enqueues its books (and a
  non-name change does not).
- **IndexerJob test** — extend `test/sidekiq/search/indexer_job_test.rb` to cover processing
  `Books::Book` and `Books::Author` requests.
- **Fixtures** — ensure `test/fixtures/books/books.yml` has ≥2 `standalone` books with linked
  authors (via `book_authors.yml`) and ≥1 `collection` book, so exclusion is provable; confirm
  `authors.yml` supports name/alternate-name assertions.

## 9. Documentation

- Update `docs/features/search.md`: add books to the indexed-domains list, the two new
  document shapes, the `Search::Books::*` index and query classes, the `search:books:` rake
  tasks, and the freshness triggers (BookAuthor / Author-name cascade).
- Update per-model docs for `Books::Book`, `Books::Author`, and `Books::BookAuthor` to note
  `SearchIndexable` / `as_indexed_json` / reindex triggers (per the `docs/documentation.md`
  workflow).

## 10. File inventory

**New files:**
- `app/lib/search/books/book_index.rb`
- `app/lib/search/books/author_index.rb`
- `app/lib/search/books/search/book_general.rb`
- `app/lib/search/books/search/author_general.rb`
- `app/lib/search/books/search/book_autocomplete.rb`
- `test/lib/search/books/book_index_test.rb`
- `test/lib/search/books/author_index_test.rb`
- `test/lib/search/books/search/book_general_test.rb`
- `test/lib/search/books/search/author_general_test.rb`
- `test/lib/search/books/search/book_autocomplete_test.rb`

**Modified files:**
- `app/models/books/book.rb` — `include SearchIndexable`; extend `as_indexed_json` (`subtitle`,
  `book_kind`).
- `app/models/books/author.rb` — `include SearchIndexable`; `after_commit` books-reindex
  cascade guarded by `saved_change_to_name?`.
- `app/models/books/book_author.rb` — `after_commit` book-reindex trigger.
- `app/sidekiq/search/indexer_job.rb` — add `"Books::Book"`, `"Books::Author"`.
- `lib/tasks/search.rake` — add `search:books:` namespace.
- `test/sidekiq/search/indexer_job_test.rb` — cover the new types.
- `test/fixtures/books/*.yml` — as needed for query assertions.
- `docs/features/search.md` and per-model docs.

The `Search::Books::*` classes are plain Ruby under `app/lib` (no Rails generator applies, matching
how `Search::Music::*` / `Search::Games::*` were created); their test files are hand-created to
mirror the existing search tests.

## 11. Conventions & constraints

- All new media code namespaced under `Books::` / `Search::Books::`; shared infra
  (`SearchIndexRequest`, `Search::Base::*`, `Search::Shared::*`) reused unchanged.
- Skinny models: query logic lives in the `Search::Books::Search::*` classes, not the models.
- Rails 8 enum syntax already in place on the models.
- CI green: `bin/rails db:test:prepare test test:system`, `bin/rubocop -f github`,
  `bin/brakeman --no-pager`. Search tests require a running OpenSearch (`OPENSEARCH_URL`).

## 12. Known boundaries (accepted)

- `Books::Series` is not searchable yet.
- Import/dedup "find existing record" matching is identifier-based and deferred (its own spec);
  no strict search-based dedup query class is built here.
- Author `alternate_names` changes do not cascade into book documents (book docs embed only
  the author's primary `name`); this is intentional, not an oversight.
