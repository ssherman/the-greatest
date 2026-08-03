# Books Public Filters — Design

**Date:** 2026-08-03
**Status:** Approved, not yet implemented

Genre, country, and date-range filtering for the books public UI, reproducing the legacy
site's URL grammar verbatim and replacing its always-visible sidebar with a single modal.

---

## 1. Summary

The legacy site's filter system is one of its most-used features and the source of most of
its indexed long-tail URLs (`The Greatest French Novels of All Time`). The new books UI
currently has no filtering at all — `/` renders an unfiltered ranked list.

This spec adds three orthogonal filters:

| Filter | URL segment | Semantics |
|---|---|---|
| Categories | `/the-greatest/novels,fiction/books` | AND |
| Country | `/written-by/french,german/authors` | OR |
| Dates | `/of/:y` · `/since/:y` · `/to/:y` · `/from/:a/to/:b` | range |

composed in that fixed order, wrapped by an optional `rc/:id` prefix and suffixed by
`/page/:n`. The URL grammar is **ported verbatim** from legacy, so no redirects are needed
for the filter surface.

It also creates the `Books::Country` model, which the migration skipped — see §2.

---

## 2. Background: why country is missing

The legacy site models a book's **national origin** (`Country` / `book_countries`, rendered
as `The Greatest **French** Novels`) separately from where a book is **set** (`Category` of
`category_type: location`, rendered as `... Set in France`). Its title generator puts them in
different grammatical slots:

```ruby
title << @countries.map { |c| c.name.titlecase }   # "The Greatest French Novels"
title << "Set in " + formatted_locations           # "... Set in France"
```

The **2026-06-29 books object model design, §9** decided to collapse these:

> **Origin/nationality** (the "Greatest French / Asian / Roman books" facet): modeled as
> **`location`-type `Books::Category`** records… **No `Country` model** — this unifies what
> the legacy site split into `Category(location)` + `Country`.

The **2026-07-03 old-site data migration design** then listed `countries`/`book_countries`
under *"Out of scope (no new-site equivalent)"* with the note *"(no model yet)"*.

The conversion step was never written. The data was **dropped, not converted** — the
`location` categories in the new app today are the legacy `location` categories verbatim,
and all 126,007 book→country links were lost.

**The unification premise was wrong**, and the legacy data disproves it. Legacy carries both
an "American" location category and an "American" country simultaneously:

| | legacy `location` category "American" | legacy country "American" |
|---|---|---|
| books | **705** | **42,289** |

Sixty-fold apart — not the same fact. Worse, for `british`, `french`, `japanese`, `german`,
and `russian` there is **no location category at all**; the slug collisions for those names
are `genre`-typed junk rows with `item_count: 0`. The origin axis exists *only* in
`countries`/`book_countries`.

This two-axis split is also the industry norm: MARC separates the 008 "country of
publication" from geographic subject headings; Wikidata separates `country of origin (P495)`
from `narrative location (P840)`; IMDb separates "Country of origin" from filming locations.
§9's "duplication" was a duplication of *names*, not of *meaning*.

**Reusing `Category` with a new `category_type: :country` is also ruled out.** `friendly_id`
scopes slug uniqueness by STI `type` only, not by `category_type`, so 69 of the 253 country
slugs (39 genre, 16 location, 14 subject) would slug as `american-<uuid>`, breaking
`/written-by/american/authors`.

**Decision:** `Books::Country` gets its own table.

### Legacy data shape

- 253 countries, 126,007 `book_countries` rows.
- 126,003 books have exactly one country; **4** have two. Effectively single-valued, but the
  join table is kept (see §4).
- Values are **demonyms**, and include non-countries: `Jewish`, `Roman`, `English`, and
  `Unknown` (34,124 books — the second largest). This is a cultural-origin label, not an ISO
  country; the admin surface must be a free-text list, not an ISO picker.
- `labels` is a Postgres array carrying `western` / `asian` / `african` / `latin_american`,
  which powers the legacy `/western`, `/asia`, `/africa`, `/latin-america`, `/non-western`
  pages.
- Populated in legacy by a per-book ChatGPT job (`Openai::Chats::BookNationality`).

---

## 3. Scope

**In scope:** the three filters above, in any combination, with pagination and the `rc/:id`
prefix; the `Books::Country` model and its migration; a single filter modal; the filtered
title/meta/canonical logic.

**Out of scope.** None of the following are routed by this spec; those legacy paths 404 on the
new site until their own increment lands. That is acceptable because the new books host is not
yet serving the legacy domain — but every item below must be routed before cutover, or its
indexed URLs break.

- Legacy regional pages `/western`, `/asia`, `/africa`, `/latin-america`, `/non-western`.
  `labels` is migrated so the hook exists, and `with_label` / `without_label` scopes ship
  with the model.
- `/women` — needs a `gender` field on `Books::Author` that does not exist and was not
  migrated.
- `/condensed`, `/global-canon`, `/that-start-with/:letter`.
- View types `/v/grid`, `/v/table`, and the sortable-header `sort_field` / `sort_direction`
  parameters that exist only to serve them.
- CSV export.
- Porting the AI country-assignment job. See the §4 consequence.

---

## 4. Data model & migration

Two new tables, books-namespaced per house convention (`books_books`, `books_book_authors`):

```
books_countries
  id, name (null: false), slug (null: false), description (text)
  labels (string[], default [], null: false)
  book_count (integer, default 0)              # counter_cache
  index slug UNIQUE, gin index on labels

books_book_countries
  id, book_id (FK -> books_books), country_id (FK -> books_countries)
  index (book_id, country_id) UNIQUE, index country_id
```

**Models**

- `Books::Country` — `friendly_id :name, use: [:slugged, :finders]`; `has_many
  :book_countries` / `:books, through:`; `with_label` / `without_label` scopes ported
  verbatim; `validates :name, presence: true`.
- `Books::BookCountry` — `belongs_to :book` / `:country, counter_cache: :book_count`.
- `Books::Book` — gains `has_many :book_countries` and `has_many :countries, through:`.

The join table is kept rather than a `country_id` column on `books_books`. Origin is
genuinely many-to-many in edge cases (a Russian-American author published in France), every
other book association in this app is a join, and the migration is a verbatim copy either
way. The cost is one small table.

**Migrators** (`Services::BooksMigration`, existing style)

- `CountryMigrator` — 253 rows, **ids preserved**. `books_countries` is a brand-new table
  that nothing else writes to, so unlike the shared `categories` table there is no id
  contention and no `LegacyIdMap` entry is needed. Slug is pinned verbatim via the
  `def record.should_generate_new_friendly_id? = false` per-instance override that
  `CategoryMigrator` already uses — FriendlyId would otherwise regenerate it from `name` on
  insert. `labels` nil → `[]`.
- `BookCountryMigrator` — 126,007 rows via `BulkUpsertMigrator`, `unique_by` the
  `(book_id, country_id)` index. Both ids are already preserved on both sides, so there is
  no remapping at all; this is the simplest migrator in the suite. A dangling `book_id`
  fails loud through the DB foreign key, matching `ExternalLinkMigrator`. `finalize`
  recomputes `book_count` in raw SQL because `upsert_all` bypasses the counter_cache —
  same as `CategoryItemMigrator`.

Both are wired into the `data_migration:*` rake namespace.

**Decisions**

1. **All 253 countries are migrated, including `Unknown`** (34,124 books), for fidelity —
   `/written-by/unknown/authors` may be indexed. But `unknown` is **excluded from the facet
   list** in the modal (`where.not(slug: "unknown")`), or it permanently occupies the #2 slot
   with no information value.
2. **The AI backfill job is not ported.** Consequence: books added after the migration have
   no country until someone sets one. The maintenance surface is a small inline
   `BookCountries` editor in the books admin, mirroring the increment-4c
   `BookAuthors`/`Credits`/`BookRelationships` pattern. This is the one piece beyond the
   literal filter scope and is the designated cut line if the work needs trimming
   (increment 5, §9).

---

## 5. Query layer

`Books::RankedBooksQuery` is **extended in place** rather than joined by a sibling class. It
has exactly one caller (`Books::RankedItemsController#index`) and its own header comment
already designates it as the seam for this change.

```ruby
Books::RankedBooksQuery.call(
  ranking_configuration:,
  categories: [],   # Books::Category records — AND
  countries: [],    # Books::Country records — OR
  year_start: nil,
  year_end: nil
) # => RankedItem relation, ordered by :rank
```

**The return type is the contract.** It stays a paginatable `RankedItem` relation, so
`pagy_path`, the view, and the list component are untouched. Swapping the engine to
OpenSearch later is purely internal — the filter clauses become an id set
(`RankedItem.where(item_id: ids)`) and nothing outside this file learns which engine ran.
Postgres is the engine for now; measurements below show it is comfortably sufficient at
current scale.

**Filter semantics** (matching legacy):

- **Categories → AND** (legacy `genre_match_mode: "all"`). One
  `where(item_id: CategoryItem.where(category_id: c.id, item_type: "Books::Book").select(:item_id))`
  per category. Each clause is a range scan on the existing
  `(category_id, item_type, item_id)` unique index.
- **Countries → OR.** One
  `where(item_id: Books::BookCountry.where(country_id: ids).select(:book_id))`.
- **Years** → join `books_books` on `first_published_year`. `of/:year` is `=`; the others are
  `>=` / `<=` / `BETWEEN`. Books with a NULL year drop out of any year-filtered view, matching
  legacy's OpenSearch range behavior.

**Measured** on the dev set (RC 8 "May 2026", 24,242 ranked books):

| Query | Time |
|---|---|
| Filtered page 1 (1 genre + year range) | 45 ms |
| pagy total count, same filter | 195 ms |
| 3 genres ANDed, page 1 | 119 ms |
| Genre facet, top 36, no filters (widest case) | 279–467 ms |

The pagy count is the slow half of a page render and is the first thing to revisit if this
gets tight.

### `Books::FilterFacetsQuery`

Serves the modal. Returns top-36 genres and top-36 countries with counts.

**Each axis is computed against the result set with its own filter removed.** Legacy does
this deliberately: on `/written-by/french/authors`, the country facet recomputes *without*
the French filter, so German (2,739) and Russian (1,416) appear as alternatives rather than
French being the only row. Already-selected values are excluded from their own list, and
`unknown` is excluded from countries.

Two queries, ~300–500 ms on the widest case — which is why it is Turbo-Frame'd on modal open
rather than run during page render (§7).

---

## 6. Routes & param resolution

**80 routes, generated by a loop** in `routes.rb` — the technique legacy uses for its seven
category prefixes. The grammar is the cross product of:

```
bases (4)      the-greatest-books
               the-greatest-books/written-by/:country_id/authors
               the-greatest/:category_id/books
               the-greatest/:category_id/books/written-by/:country_id/authors

dates (5)      <none> · /of/:year · /since/:published_start
               /to/:published_end · /from/:published_start/to/:published_end

page (2)       <none> · /page/:page
rc prefix (2)  <none> · rc/:ranking_configuration_id/
```

All 80 point at `books/ranked_items#index`, inside the existing books `DomainConstraint`.

Two further routes serve the modal (§7), also inside the books constraint:

```
get "filters",         to: "books/filters#show"      # form target -> 303 to canonical path
get "filters/options", to: "books/filters#options"   # turbo-frame facet content
```

Neither is ever linked publicly; `#show` returns a bodiless 303 and `#options` is frame-only.

**Two deliberate choices:**

1. **The `rc/` prefix is written out literally in the loop, not via `scope "(/rc/...)"`.**
   The `lists-public-ui` landmine: a route `constraints:` inside that scope disables the
   optimized url helper and binds the positional arg to the rc segment. The existing
   `books/lists` routes already dodge this by spelling the prefix out. Following that also
   makes `constraints: {page: /\d+/}` safe.
2. **None of the 80 get an `as:` name.** Naming them is impractical, and legacy never did
   either — it builds these paths with a string helper, as does this design. No url helpers,
   no landmine.

`/the-greatest-books` **bare** keeps its existing 301 → `/`; only the suffixed forms become
real pages. Rails matches exact segments, so there is no conflict, and nothing in the current
books route table (`book/:slug`, `author/:slug`, `authors`, `lists`, `page/:page`, `rc/:id`,
`books/:id`, `items/:id`) collides with `the-greatest/…`.

**Two POROs**, both unit-testable without a request:

- `Books::FilterPath` — the path builder, ported from `BooksHelper#filtered_books_path`, with
  a helper delegate for views. Sorts slugs deterministically, so every link the app emits is
  already canonical.
- `Books::FilterParams` — params → resolved records. Comma-splits, scopes categories to
  `active`, validates years (integers; negatives allowed for BC, as legacy does).

**Deviation from legacy: unknown slugs 404 instead of being silently ignored.** Legacy's
`where(slug: slugs)` simply returns fewer rows, so `/the-greatest/asdf/books` renders the
*unfiltered* list under a wrong title — a soft 404, and an unbounded space of indexable junk
URLs. The legacy `deleted_categories` table is **empty (0 rows)**, so there is no merged-slug
history being discarded by this choice.

**Duplicate content:** `fiction,novels` and `novels,fiction` are the same page. The page emits
`<link rel="canonical">` at the sorted-slug form rather than 301-ing to it — same SEO effect,
no redirect-loop risk. Non-primary `rc` views keep legacy's existing `@no_index`.

---

## 7. UI

The staged-selection modal needs **no custom JavaScript** for its core flow, because the modal
is a plain GET form posting to a redirect endpoint.

```
[Filters] click        native <dialog> (DaisyUI) — no JS
  └─ <turbo-frame src="/filters/options?…" loading="lazy">
        facets render on open; IntersectionObserver does not
        fire while the dialog is closed
        └─ <form method="get" action="/filters" data-turbo-frame="_top">
              checkbox category_slugs[]   (checked = currently applied)
              checkbox country_slugs[]
              number   year_start / year_end
              [Clear]  [Apply ← plain submit]

Books::FiltersController#show
  validates slugs via Books::FilterParams (404 on unknown)
  builds the canonical path via Books::FilterPath
  redirect_to path, status: :see_other
```

Staging is unchecked checkboxes; Apply is a form submit. Critically, **the path grammar lives
in exactly one place — `Books::FilterPath`, in Ruby, unit-tested.** There is no JS
reimplementation to drift out of sync. The `/filters?…` URL is a 303 with no body, so nothing
indexes it.

`data-turbo-frame="_top"` on the form is load-bearing: without it the submission is captured
by the enclosing turbo-frame instead of navigating.

**Components**

- `Books::FilterBarComponent` — the Filters button plus active-filter chips. Each chip's ✕ is
  a plain `<a>` to the same path minus that one filter, so removal works with JS off and gives
  crawlers a natural path through the filter space. These stay followable — the filter
  combinations are the SEO product.
- `Books::FilterModalComponent` — the dialog shell and the lazy frame.
- `Books::FilterFacetsComponent` — renders inside the frame.

**The one piece of JavaScript** is genre search: ~14k active genres against 36 shown. A
server-side search that reloads the frame would wipe staged-but-unapplied checkboxes. One
small Stimulus controller does double duty — instant substring filter over the visible 36,
and, when "search all genres" reloads the frame, it carries the staged selections into the
frame request so nothing is lost.

**Title generation** — `Books::FilterTitle`, ported from `DefaultTitleGenerator`:

```
countries → adjective prefix     "The Greatest French Novels of All Time"
genres    → inline; suppress the word "Books" when the genre already ends in "s"
subjects  → "on Politics"
locations → "Set in France"
dates     → "of 1984" / "Since 1900" / "From 1900 to 2000" / "To 1900" / "of All Time"
```

Meta description ports legacy's form: `"#{title}. This list is generated by aggregating
#{Books::List.active.count} lists from various critics, authors, experts, and readers."`

**The genre/category asymmetry is preserved deliberately.** The modal offers genres only —
legacy's facet method signature is `category_type: :genre` with `.not_location`. But the URL
accepts any active category slug of any type, because book detail pages link into location and
subject filters and the title generator renders each type in its own grammatical slot. Both
behaviors carry over.

The `/` hero (`@show_hero`) hides once any filter is active and the generated title becomes the
H1 — legacy's `@no_filters` flag, same idea.

---

## 8. Testing

**Unit** (Minitest + fixtures + Mocha)

- `Books::FilterPath` — table-driven across the full grammar (4 bases × 5 date forms × page ×
  rc), plus canonical slug ordering.
- `Books::FilterParams` — comma splitting, `active` scoping, `RecordNotFound` on unknown slug,
  year validation, `of/:year` setting both bounds.
- `Books::FilterTitle` — port the cases from legacy `test/lib/default_title_generator_test.rb`,
  plus new country cases.
- `Books::RankedBooksQuery` — categories AND, countries OR, inclusive year bounds, NULL-year
  books excluded when a year filter is active. **The existing test file must keep passing
  untouched** — that is the regression guard on extending it in place.
- `Books::FilterFacetsQuery` — top-N ordering, own-axis exclusion (with French selected, French
  is absent from country facets but German is present), `unknown` excluded, counts correct.

New fixtures: `books/countries.yml`, `books/book_countries.yml`. These are plain models, not
STI, so generator-created fixtures are wanted — the `--no-fixture` landmine from
`Books::UserList` does not apply.

**Migration** — migrator unit tests in the established style, plus an **e2e assertion with
exact counts**: 253 countries, 126,007 `book_countries`, `book_count` correctly recomputed,
idempotent on re-run.

**Controller / routing**

- One table-driven routing test asserting all 80 shapes resolve to `books/ranked_items#index`
  with the right params, rather than 80 integration tests.
- Integration: 200 + correct H1 on a filtered page; 404 on unknown category slug, unknown
  country slug, and garbage year; canonical link present and sorted; `noindex` on non-primary
  rc; `Books::FiltersController#show` redirecting 303 to the canonical path.
- **`assert_queries_count`** on the filtered index. The chips row renders category and country
  names in a loop, which is exactly the shape that regresses into an N+1.

**E2E (Playwright)** — one spec: open the modal → check a genre and a country → Apply → assert
the URL is `/the-greatest/novels/books/written-by/french/authors` and the H1 reads "The
Greatest French Novels of All Time" → remove the country chip → assert the segment drops.

---

## 9. Increments

Each is its own PR. Gate before each: `bin/rails test` + `bundle exec standardrb`.

| # | Scope | Verifiable by |
|---|---|---|
| 1 | Country model + 2 migrators + rake wiring + fixtures + dev data run | exact-count e2e assertion |
| 2 | `RankedBooksQuery` extension + `FilterParams`, `FilterPath`, `FilterTitle`, `FilterFacetsQuery` | unit tests; nothing user-visible |
| 3 | The 80 routes + controller wiring + title/meta/canonical/noindex | every filter URL works, hand-typed |
| 4 | Filter bar, chips, modal, facets frame, `FiltersController`, Stimulus controller | Playwright |
| 5 | Admin inline country editor *(cuttable — see §4)* | admin E2E |

---

## 10. Landmines

- **`scope "(/rc/...)"` + `constraints:`** disables the optimized url helper and binds the
  positional arg to the rc segment. Write the rc prefix out literally (§6).
- **FriendlyId regenerates slugs on insert** when `name_changed?`. `CountryMigrator` must pin
  them with the per-instance `should_generate_new_friendly_id? = false` override (§4).
- **`upsert_all` bypasses counter_cache and callbacks** — `book_count` must be recomputed in
  `finalize` (§4).
- **`data-turbo-frame="_top"`** on the modal form; without it the submit is captured by the
  frame (§7).
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** Read fixture
  YAML directly; never run it against development.
- Inside `Services::BooksMigration`, a bare `Music::` resolves to `Services::Music`.
  Root-anchor constants in migrator code.
