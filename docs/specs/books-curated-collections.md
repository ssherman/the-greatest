# Books Curated Collections (Lists nav menu)

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-08-16
- **Started**: 2026-08-16
- **Completed**: 2026-08-16
- **Developer**: Shane Sherman

## Overview

Migrate the legacy site's curated "Lists" nav menu to the new app: six filtered collection
pages (`/women`, `/africa`, `/asia`, `/latin-america`, `/western`, `/non-western`) on their
legacy URLs, plus the nav menu itself. The collection machinery is built domain-neutral so
music can adopt it later, but **books is the only domain that registers collections here**.

**Non-goals.** The Global Canon (`/global-canon`) is a separate spec — different query,
different filters, its own page. Country/Origin filtering on collection pages is out of
scope (genre + year only, matching legacy). Movies is not in scope.

## Context & Links

- Legacy source: `/home/shane/dev/the-greatest-books/admin`
  - `app/controllers/default_controller.rb` — the six collection actions
  - `app/views/shared/_navbar.html.erb` — the nav menu being migrated
  - `app/lib/default_title_generator.rb` — title grammar (already ported as `Books::FilterTitle`)
  - `app/services/book_list_query.rb` — gender semantics (`included_author_ids`)
- New app (authoritative):
  - `web-app/app/controllers/books/ranked_items_controller.rb`
  - `web-app/app/lib/books/{filter_path,filter_title,filter_params,ranked_books_query,filter_facets_query}.rb`
  - `web-app/config/routes.rb` — existing `filter_bases` / `filter_dates` loop
  - `web-app/app/views/layouts/books/application.html.erb` — nav (two copies)
- Related: `docs/features/books-public-filters`, `books-western-canon-penalty` (source of the
  `Books::Country#labels` data this spec consumes)

### Two nav entries need no backend work

| Nav entry | URL | Status |
|---|---|---|
| The Greatest Books of the 21st Century | `/the-greatest-books/since/2000` | **Already routes** — legacy filter grammar is ported verbatim |
| Our Users' Favorite Books of All Time | `/lists/463` | **Already routes** — list 463 migrated with its id intact |

## Interfaces & Contracts

### Domain Model (diffs only)

**`books_authors`** — add gender. Legacy `authors.gender` was never migrated; `/women`
cannot be built without it.

- `add_column :books_authors, :gender, :integer`
- `add_index :books_authors, :gender`
- Migration: `bin/rails generate migration AddGenderToBooksAuthors gender:integer:index`
- `Books::Author`: `enum :gender, {male: 0, female: 1, non_binary: 2, unspecified: 3}`

Ordinals match legacy exactly — legacy's `enum :gender, [:male, :female, :non_binary,
:unspecified]` is a positional array, so raw integers copy across unchanged.

Legacy coverage (verified 2026-08-16 against the live legacy DB): 36,437 male / 17,532
female / 143 non_binary / 284 unspecified / 3,797 null out of 58,193 authors.

**No other schema change.** `Books::Country#labels` is already populated (african 53,
asian 33, western 24, latin_american 23) with `with_label` / `without_label` scopes.

**Migration durability is a non-concern here.** At cutover the legacy site goes offline, the
data is truncated, and `data_migration:all` runs from scratch. There are no post-migration
author edits to preserve and there never will be — the new app's author rows are test data
until then. Pick the simplest correct thing.

### New classes

| Path | Purpose |
|---|---|
| `app/lib/collections/collection.rb` | Domain-neutral value object |
| `app/lib/collections/registry.rb` | `Registry.for(domain)`, `Registry.find(domain, slug)` |
| `app/lib/books/collections_registry.rb` | The six books entries |

`Collection` is `Struct.new(..., keyword_init: true)` — house style; there is no
`Data.define` anywhere in this codebase.

```ruby
Collection = Struct.new(:domain, :slug, :name, :title_prefix, :title_suffix, :filter,
                        keyword_init: true)
```

**Naming constraint (load-bearing):** the books file defines `Books::CollectionsRegistry`,
**not** `Books::Collections`. A nested `Collections` module inside `Books::` would shadow
the shared top-level `::Collections` and produce the confusing `NameError` this codebase has
hit repeatedly. Any reference to `::Books::` from inside `Collections::` must be
root-anchored for the same reason.

### The seam

`filter` is an **opaque hash the shared layer never reads**. Only the owning domain's query
object interprets it. This is what lets music register collections later with a completely
different vocabulary and no changes to shared code.

| slug | nav name | title_prefix | title_suffix | filter |
|---|---|---|---|---|
| `women` | Greatest Books Written by Women | — | `Written by Women` | `{author_gender: :female}` |
| `africa` | Greatest African Books | `African` | — | `{country_label: "african"}` |
| `asia` | Greatest Asian Books | `Asian` | — | `{country_label: "asian"}` |
| `latin-america` | Greatest Latin American Books | `Latin American` | — | `{country_label: "latin_american"}` |
| `western` | Greatest Western Canon Books | `Western` | — | `{country_label: "western"}` |
| `non-western` | Greatest Non-Western Canon Books | `Non-Western` | — | `{country_label: "western", exclude: true}` |

### Endpoints

Generated by one constrained `:collection` segment rather than six copies of the grammar —
roughly 48 routes instead of 288. Source of truth: `config/routes.rb`.

| Verb | Path | Purpose |
|---|---|---|
| GET | `/:collection` | Canonical collection page |
| GET | `/:collection/page/:page` | Pagination |
| GET | `/:collection/the-greatest-books/<date>` | Date-filtered |
| GET | `/:collection/the-greatest/:category_id/books<date>` | Genre (+ date) filtered |
| GET | `/rc/:ranking_configuration_id/:collection…` | Same set under an rc prefix (noindex) |

`<date>` reuses the existing `filter_dates` array verbatim: `""`, `/of/:year`,
`/since/:published_start`, `/to/:published_end`, `/from/:published_start/to/:published_end`.
Every form also has a `/page/:page` variant.

**The `collection` regex constraint is load-bearing, not cosmetic.** `Regexp.union` of the
six slugs is what stops `/:collection` from matching arbitrary single segments and minting an
unbounded space of indexable soft-duplicates — the same reasoning already documented in
`routes.rb` for `/genres/sorted-by/:sort`.

~~The slug list stays a **literal in `routes.rb`** (matching how `filter_bases` is already
written there) rather than being read from the registry — autoloading in the router is a
reloading hazard. A test asserts the literal equals the registry.~~

**NOT IMPLEMENTED — this paragraph is wrong.** The reloading-hazard premise was disproven:
`DomainConstraint` lives in `app/lib/` and is already referenced at the top of
`config/routes.rb`. Routes read `Collections::Registry.slugs(:books)` directly, so there is no
duplicate literal and no drift to test for. See **Deviations From Spec**.

#### Redirects (301)

| From | To |
|---|---|
| `/:collection/the-greatest-books` | `/:collection` |
| `/:collection/the-greatest/books` (legacy oddity) | `/:collection` |
| `/v/:view_type/:collection(/*rest)` | `/:collection` |

Precedent: `get "the-greatest-books", to: redirect("/", status: 301)` and the existing
`v/:view_type` handling for `/lists` and `/searches`.

### Behaviors (pre/postconditions)

**Preconditions.** `params[:collection]` is regex-constrained to a known slug;
`Collections::Registry.find(:books, slug)` returning nil raises `RecordNotFound` (defensive —
the constraint should make it unreachable).

**Postconditions.**
- `Books::RankedBooksQuery.call(..., collection:)` narrows the relation by `collection.filter`:

```ruby
case collection&.filter
in {country_label:, exclude: true}
  relation.where(item_id: Books::BookCountry.where(
    country_id: Books::Country.without_label(country_label).select(:id)).select(:book_id))
in {country_label:}
  relation.where(item_id: Books::BookCountry.where(
    country_id: Books::Country.with_label(country_label).select(:id)).select(:book_id))
in {author_gender:}
  relation.where(item_id: Books::BookAuthor.where(
    author_id: Books::Author.where(gender: author_gender).select(:id)).select(:book_id))
else
  relation
end
```

- `Books::FilterPath.call(..., collection:)` prefixes `/:slug`; `unfiltered_path` returns
  `/:slug` (or `/:slug/page/N`) instead of `/`.
- `Books::FilterTitle` inserts `title_prefix` directly after `"The Greatest"` (legacy order,
  before countries) and appends `title_suffix` last.
- `Books::FilterFacetsQuery.genres` narrows by the collection, so the genre pane shows
  collection-scoped counts.
- `Books::FiltersController#show` (the Apply endpoint) resolves `params[:collection]` and
  passes it to `FilterPath`, so Apply redirects back **into** the collection.
- `@show_hero` gains `&& @collection.nil?` — the hero is site-level marketing copy.
- Meta description needs no new field: `index.html.erb` already derives it from `@page_title`.

**Edge cases & failure modes.**
- `/women` matches books where **any** author is female, mirroring legacy's
  `included_author_ids`. Co-authored works count.
- ~~**27% of books have no usable origin** (`Unknown` or no country row), so they appear in
  neither `/western` nor `/non-western`.~~ **WRONG — corrected during implementation.** A book
  with an `Unknown` or unlabelled country **does** appear in `/non-western`:
  `Books::Country.without_label` is a verbatim port of the legacy scope and includes its
  `.or(where(labels: []))` clause, so unlabelled countries count as non-western. This matches the
  live legacy site exactly. Only a book with **no country row at all** falls out of both pages.
  Do not "fix" either behaviour. See **Deviations From Spec**.
- `indexable?` needs no change: countries are always empty on a collection page, so the
  existing `≤1 category && ≤1 country` rule already covers it.
- `/rc/` URLs stay noindex with no canonical at all (existing D4 rule).
- Filtered-with-zero-results stays noindex (existing rule).

### Non-Functionals

- No N+1 on the collection index — it renders books in a loop. Pin with
  `assert_queries_count`.
- Collection pages are edge-cached by the existing `cache_for_index_page` (6h).
- Path-based pagination is inherited free: `Pagination::PathBuilder.from_request` is fully
  generic, so `/africa` → `/africa/page/2` with no new code.
- Public, unauthenticated; no role changes.

## Acceptance Criteria

- [x] `books_authors.gender` exists, enum ordinals match legacy, `AuthorTransformer` carries
      gender, and re-running `data_migration:authors` sets 17,532 female authors in development.
- [x] All six collection pages return 200 on their bare slug and render collection-scoped books.
- [x] Legacy filtered URLs resolve without redirect, e.g.
      `/africa/the-greatest/fiction/books/since/2000/page/2`.
- [x] The three 301 families redirect as tabled above.
- [x] `/africa/page/2` paginates; page past the last raises `RecordNotFound`.
- [x] Page titles match legacy exactly (see Golden Examples).
- [x] Canonical tag present on non-rc pages; absent on `/rc/` pages; noindex rules hold.
- [x] The filter bar on a collection page offers genre + year only — no Origin pane.
- [x] Apply from the filter modal returns to a collection-scoped path.
- [~] ~~The routes.rb slug literal equals `Collections::Registry.for(:books).map(&:slug)`.~~
      **Void by design** — there is no literal to compare; routes read the registry directly, so
      this test would compare a value to itself. Replaced by assertions that every registered slug
      recognizes. See **Deviations From Spec**.
- [x] Nav "Lists" menu renders 9 items — "All Lists", a divider, then the 8 collections — in
      both the desktop and narrow-screen copies.
- [x] `assert_queries_count` pins the index query count; `assert_no_frame_trapped_links` passes.
- [x] `bin/rails test` and `bundle exec standardrb` green; Playwright spec added.

### Golden Examples

```text
GET /africa
  title: The Greatest African Books of All Time
  canonical: /africa

GET /women
  title: The Greatest Books of All Time Written by Women

GET /africa/the-greatest/fiction/books/since/2000
  title: The Greatest African Fiction Books Since 2000
  canonical: /africa/the-greatest/fiction/books/since/2000

GET /africa/the-greatest-books  ->  301  /africa
GET /v/grid/africa             ->  301  /africa
```

---

## Agent Hand-Off

### Constraints

- Follow existing project patterns; the collection is **one more narrowing alongside genre
  and year**, not a new subsystem. No new controller, no new view.
- Rails generators for the migration. Rails 8 enum syntax (`enum :gender, {...}`).
- `standardrb`, not rubocop. Do not run brakeman.
- daisyUI 5: the nav menu must avoid the ten removed v4 classes; the lint test guards it.

### Increments

| # | Scope |
|---|---|
| 1 | Gender column + enum + `AuthorTransformer` gains `gender:` (re-run `data_migration:authors` in dev) |
| 2 | `Collections::Collection` + `Registry` + `Books::CollectionsRegistry` |
| 3 | `collection:` through `RankedBooksQuery`, `FilterPath`, `FilterTitle`, `FilterFacetsQuery` |
| 4 | Routes, redirects, controller, view, filter bar/modal/Apply |
| 5 | Nav menu (9 items) + Playwright |

### Nav menu contents

`<li><details><summary>Lists</summary><ul>…</ul></details></li>` — the documented daisyUI 5
nested-menu pattern, no JS. `<summary>` does not navigate, so "All Lists" is the first item,
exactly as legacy. Both copies in the layout (desktop and narrow-screen) need it.

1. All Lists → `/lists`
2. *(divider)*
3. The Greatest Books of the 21st Century → `/the-greatest-books/since/2000`
4. Greatest Books Written by Women → `/women`
5. Greatest African Books → `/africa`
6. Greatest Asian Books → `/asia`
7. Greatest Latin American Books → `/latin-america`
8. Greatest Non-Western Canon Books → `/non-western`
9. Greatest Western Canon Books → `/western`
10. Our Users' Favorite Books of All Time → `/lists/463`

That is 9 items (the divider is not an entry). Spec B inserts The Global Canon at position 3,
making 10 — matching legacy exactly.

### Backfill: add gender to AuthorTransformer and re-run `data_migration:authors`

No bespoke migrator. `AuthorTransformer` gains `gender: attrs["gender"]` — that single line
is the whole production path, because the real cutover truncates and re-runs
`data_migration:all` from scratch against an offline legacy site.

Re-running `data_migration:authors` on the current development database is then just a
convenience so `/women` can be built and eyeballed. `AuthorMigrator` is idempotent
(`find_or_initialize_by(id:)` + `save!`), and there have been no post-migration author edits
to clobber — the new app's author rows are test data until cutover.

### Test Seed / Fixtures

**No fixture-file edits are needed.** Existing fixtures already cover three of the six
collections, and the remaining three are set up inline per test — the same style the existing
`RankedItemsControllerTest` already uses for `RankedItem.create!`. This keeps blast radius at
zero, which matters because mutating `algerian`'s labels in the shared YAML would silently
change what `without_label("western")` returns for every other test.

Covered by existing fixtures:

| Collection | Path through fixtures |
|---|---|
| `/western` | `french` (`labels: [western]`) ← `war_and_peace`, `got` |
| `/asia` | `japanese` (`labels: [asian]`) ← `of_mice_and_men` |
| `/non-western` | `japanese`, `unknown`, `algerian` are all non-western ← `of_mice_and_men` |

Set up inline in the test that needs it:

| Collection | Inline setup |
|---|---|
| `/africa` | `books_countries(:algerian).update!(labels: ["african"])` + a `Books::BookCountry` link |
| `/latin-america` | `Books::Country.create!(name: "Argentine", labels: ["latin_american"])` + a link |
| `/women` | `books_authors(:garnett).update!(gender: :female)` + a `Books::BookAuthor` link |

Other relevant fixture names — books: `war_and_peace`, `crime_and_punishment`,
`combo_steinbeck`, `got`, `clash`, `of_mice_and_men`, `cannery_row`. Authors: `tolstoy`,
`king`, `bachman`, `garnett`, `excluded_placeholder`. `ranking_configurations(:books_global)`
is `primary: true`, so `FilterPath` emits no `/rc/` prefix for it.

`ActiveRecord::FixtureSet.create_fixtures` TRUNCATES — read fixture YAML, never load it.

### Environment hazards

- **The worktree shares `the_greatest_test` with the main checkout.** This spec adds a column
  to `books_authors`; if anything runs from the main checkout mid-run, the column vanishes.
  Coordinate before running the suite.
- A fresh worktree is missing gitignored `web-app/.env` and `web-app/config/master.key` —
  symlink them from the main checkout.
- The development database is not disposable. Books data exists **only** in development and
  takes hours to rebuild. Snapshot with `bin/snapshot-dev-db.sh` before the backfill.

---

## Implementation Notes (living)

- **Approach taken:** six increments, each TDD'd and independently reviewed, on branch
  `worktree-books-collections`. A collection is one more *narrowing* alongside genre and year —
  no new controller, no new view.
- **The seam works.** `filter` is interpreted in exactly one place in the whole application
  (`Books::RankedBooksQuery.with_collection`). A second domain really is one registry file plus
  one routes line; the final review verified this rather than taking it on faith.
- **`assert_empty` is this project's most dangerous assertion.** Seven assertions written during
  this work passed against code with the feature deleted — an empty expectation, a bare
  `assert_response :success`, and a `^`-anchored Playwright regex among them. Every one was caught
  by a reviewer or by execution, none by the author. Prefer
  `assert_equal [expected_id], actual` and prove a new test can fail before trusting it.

## Deviations From Spec

Two statements in this spec turned out to be **wrong** and were deliberately not implemented.
Do not "restore" them later.

1. **The `/non-western` Unknown-origin note (above) is incorrect.** It claims books with `Unknown`
   or no origin "appear in neither `/western` nor `/non-western`". In fact `Books::Country.without_label`
   is a verbatim port of the legacy scope, including its `.or(where(labels: []))` clause, so
   unlabelled countries **are** non-western — matching the live legacy site exactly. The
   implementation is right; this spec's prose was wrong. The test-seed table further down the spec
   contradicts the prose and is the accurate half.

2. **The routes.rb slug list is NOT a literal, and the route-consistency test does not exist.**
   The spec prescribed duplicating the six slugs into `config/routes.rb` plus a test asserting the
   literal matches the registry, on the assumption that autoloading from the router was unsafe.
   That assumption was disproven during pre-flight: `DomainConstraint` lives in `app/lib/` and is
   already referenced at the top of `config/routes.rb`. Routes now read
   `Collections::Registry.slugs(:books)` directly, so no duplicate exists and drift is structurally
   impossible — which also means the prescribed test would have compared a value to itself, the
   vacuous-assertion defect the review rubric flags. Acceptance criterion "the routes.rb slug
   literal equals the registry" is therefore **void by design**, replaced with assertions that every
   registered slug actually recognizes.

Smaller, intentional departures:

3. **No bespoke gender backfill migrator.** The spec's caution about `AuthorMigrator` overwriting
   edited fields is moot: the owner confirmed there are no post-migration author edits and that
   cutover truncates and re-runs `data_migration:all` from scratch. `AuthorTransformer` gained one
   line; the existing migrator did the rest.
4. **No fixture-file edits, as specced** — but the mechanism differs. Collections not covered by
   existing fixtures are seeded inline per test rather than via new YAML, which held blast radius
   at zero. An attempt to add a category to shared fixture YAML during increment 3 broke an
   unrelated `Books::BookTest`, confirming the spec's reasoning the hard way.
5. **The nav "divider" is a `menu-title` group label**, not a visible rule — better for screen
   readers, visually different from what was specced.

### Key Files Touched (paths only)
- `app/lib/collections/collection.rb`
- `app/lib/collections/registry.rb`
- `app/lib/books/collections_registry.rb`
- `app/lib/books/{filter_path,filter_title,ranked_books_query,filter_facets_query}.rb`
- `app/lib/services/books_migration/author_transformer.rb`
- `app/controllers/books/{ranked_items_controller,filters_controller}.rb`
- `app/components/books/{filter_bar_component,filter_modal_component}.rb`
- `app/views/books/ranked_items/index.html.erb`
- `app/views/layouts/books/application.html.erb`
- `config/routes.rb`
- `db/migrate/*_add_gender_to_books_authors.rb`

### Challenges & Resolutions
- …

### Deviations From Plan
- See **Deviations From Spec** above — the substantive ones are recorded there.
- Two defects originated in the plan's own test code and were fixed during review: a pagination
  test that asserted a 404, and a "composes with a year bound" test that asserted an empty result
  a broken implementation would also produce.

## Acceptance Results

Verified 2026-08-16 on branch `worktree-books-collections`.

- **Minitest:** 6647 runs, 159,641 assertions, 0 errors. 3 failures, all pre-existing
  `Webhooks::StripeControllerTest` (Stripe webhook signing) and unrelated to this branch.
- **`bundle exec standardrb`:** clean.
- **Playwright:** `e2e/tests/books/collections.spec.ts` 3/3; `e2e/tests/books/lists.spec.ts` 9/9
  (the latter regressed on the nav rewrite and was fixed — "Lists" is now a `<summary>`, and the
  link inside is "All Lists").
- **Manual, against real backfilled data:** `/women` renders "The Greatest Books of All Time
  Written by Women" with a full page of 100 books.
- **Development database migrated and backfilled:** 58,193 authors; gender now
  male 36,437 / female 17,532 / non_binary 143 / unspecified 284 — an exact match to the legacy
  counts. Snapshot taken first: `tmp/db-snapshots/dev-20260816-180830-pre-author-gender.dump`.
- **Not yet run:** the production author-gender backfill. Cutover re-runs `data_migration:all`
  from scratch, so no separate production step is required.

## Future Improvements
- Origin filtering scoped to a collection (`/africa/…/written-by/nigerian/authors`) — a new
  URL shape legacy never had. Deliberately deferred.
- Music collections: one `Music::CollectionsRegistry` + one routes line, no shared changes.

## Related PRs
- #…

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
