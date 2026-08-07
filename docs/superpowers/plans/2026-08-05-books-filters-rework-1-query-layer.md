# Books Filters Rework — Increment 1: Query Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the four query-layer pieces the drill-down filter modal needs — per-axis facet queries capped at 24, a category search across all three types, a country search, and selection caps — with nothing rendered yet.

**Architecture:** Two new single-responsibility query objects (`Books::CategorySearchQuery`, `Books::CountrySearchQuery`) mirroring the existing `app/lib/books/` query style. `Books::FilterFacetsQuery` gains two per-axis class methods so a pane fetch runs one query instead of two, while its existing `.call` keeps returning the two-axis `Result` so the still-live increment-4 component does not break. `Books::FilterParams` gains two constants and one guard.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, Postgres, Standard (standardrb). Design spec: `docs/superpowers/specs/2026-08-05-books-filters-rework-design.md` §6, §8, §11, §12.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**, not `web-app/docs/`.
- Work in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-filters-typeahead` on branch **`worktree-books-filters-typeahead`**. Never `main`. Do not `cd` to the original repo root.
- Baseline recorded by the superseded plan: **5569 runs, 0 failures**. Task 0 re-establishes it.
- The worktree shares the test database `the_greatest_test` with the main checkout — do not run tests concurrently with another worktree.
- Namespace media code under `Books::`; tests mirror the namespace (`module Books; class FooTest`).
- **No code comments** unless recording a genuine landmine.
- Services/query objects live in `app/lib/books/`, **not** `app/services/`.
- Rails 8 enum syntax is `enum :category_type, {genre: 0}` — already defined on `Category`, do not redeclare.
- **THE DEVELOPMENT DATABASE IS NOT DISPOSABLE.** A `PreToolUse` hook blocks destructive commands. Never run `db:drop` / `db:reset` / `db:schema:load`, and never `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES). **This increment needs no migration and no schema change.**
- Lint with `bundle exec standardrb`, **not** `bin/rubocop`. Never run brakeman.
- **Gate before "done":** `bundle exec standardrb` clean and `bin/rails test` passing, compared against the 5569 baseline **by runs count**, not just failures.
- Every git commit message ends with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## Existing interfaces you will use (do not recreate)

```ruby
# app/models/category.rb  — Books::Category < Category, STI-scoped by `type`
scope :active,          -> { where(deleted: false) }
scope :search_by_name,  ->(name) { where("name ILIKE ?", "%" + sanitize_sql_like(name) + "%") }
scope :sorted_by_name,  -> { order(:name) }
enum :category_type, {genre: 0, location: 1, subject: 2, theme: 3, game_mode: 4, player_perspective: 5}
# columns: name, slug, item_count, deleted, category_type, type

# app/models/books/country.rb
scope :filterable,     -> { where.not(slug: "unknown") }   # drops the 34k "Unknown" bucket
scope :sorted_by_name, -> { order(:name) }
# columns: name, slug, book_count, labels

# app/lib/books/filter_params.rb
Books::FilterParams.call(params) # => Result(categories:, countries:, year_start:, year_end:)
# raises ActiveRecord::RecordNotFound on an unknown slug or a bad year

# app/lib/books/filter_facets_query.rb
Books::FilterFacetsQuery.call(ranking_configuration:, categories:, countries:, year_start:, year_end:, limit:)
# => Result(genres:, countries:) where each is [{record:, count:}]
```

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/books/category_search_query.rb` *(new)* | query string → matching `Books::Category` records, all types |
| `app/lib/books/country_search_query.rb` *(new)* | query string → matching `Books::Country` records |
| `app/lib/books/filter_facets_query.rb` *(modify)* | add `.genres` / `.countries` class methods; `DEFAULT_LIMIT` 500 → 24 |
| `app/lib/books/filter_params.rb` *(modify)* | enforce 6-category / 10-country caps |
| `test/fixtures/categories.yml` *(modify)* | distinct `item_count` values on the six books rows so ordering is assertable |
| `e2e/tests/books/filters.spec.ts` *(modify)* | delete the test that depends on the 500 limit |
| Tests mirroring each Ruby file under `test/lib/books/` | |

**Task order:** 0 (baseline) → 1 (fixtures) → 2 (`CategorySearchQuery`) → 3 (`CountrySearchQuery`) → 4 (facets split) → 5 (caps) → 6 (E2E cleanup + gate).

Task 1 comes before Tasks 2–4 because all three assert on ordering by count, and every books category fixture currently has `item_count: 0`.

---

### Task 0: Establish the baseline

**Files:** none — verification only.

**Interfaces:**
- Consumes: nothing.
- Produces: a confirmed runs count that every later task compares against.

- [ ] **Step 1: Confirm the branch and worktree**

```bash
pwd    # must end in .claude/worktrees/books-filters-typeahead
git branch --show-current    # must print worktree-books-filters-typeahead
```

- [ ] **Step 2: Run the full suite**

Run: `bin/rails test`
Expected: `5569 runs, 0 failures, 0 errors, 0 skips`. If the runs count differs, record the real number and use **that** as the baseline for the rest of this plan — do not treat a mismatch as a failure to fix.

- [ ] **Step 3: Confirm lint is clean**

Run: `bundle exec standardrb`
Expected: no offenses.

---

### Task 1: Give the books category fixtures distinct item counts

**Files:**
- Modify: `test/fixtures/categories.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: fixture `item_count` values that Tasks 2 and 4 assert ordering against. No test currently asserts a specific `item_count` on any books category fixture, so this is safe — `category_item_migrator_test.rb` asserts only post-`finalize` recomputed values.

- [ ] **Step 1: Set the item counts**

Edit the six `Books::Category` entries in `test/fixtures/categories.yml`, changing **only** the `item_count:` line in each. Leave every other attribute untouched.

| Fixture | `item_count` | Why this value |
|---|---|---|
| `books_fiction_genre` | `500` | highest — must sort first |
| `books_novels_genre` | `300` | second |
| `books_politics_subject` | `200` | a non-genre outranking a genre, so type-agnostic ordering is provable |
| `books_classics_genre` | `100` | fourth |
| `books_france_location` | `50` | lowest live row |
| `books_deleted_genre` | `9999` | highest of all, but `deleted: true` — proves `active` filters before ordering |

- [ ] **Step 2: Run the tests most likely to depend on category fixtures**

Run: `bin/rails test test/lib/categories/ test/models/category_test.rb test/models/books/category_test.rb test/lib/services/books_migration/category_item_migrator_test.rb`
Expected: all pass. If anything fails, it asserted an `item_count` value that this task changed — fix that assertion to read the value rather than hardcode it, and note it in the commit.

- [ ] **Step 3: Commit**

```bash
git add test/fixtures/categories.yml
git commit -m "$(cat <<'EOF'
Give books category fixtures distinct item counts

Every books category fixture had item_count: 0, so no test could assert
popularity ordering. books_deleted_genre gets the highest count of all so
that active-scoping is provable independently of ordering.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Books::CategorySearchQuery`

**Files:**
- Create: `app/lib/books/category_search_query.rb`
- Test: `test/lib/books/category_search_query_test.rb`

**Interfaces:**
- Consumes: `Books::Category.active`, `.search_by_name`, `item_count` (Task 1 fixtures).
- Produces: `Books::CategorySearchQuery.call(query, limit: 10)` → `Array<Books::Category>`, all active, name-matching, ordered `item_count DESC, name ASC`, capped at `limit`. Returns `[]` for a blank query. Increment 2's `Books::FiltersController#categories` calls this.

**Reference behaviour.** Legacy's `CategoriesController#search` is `Category.active.search_by_name(query).order(book_count: :desc)` then `.sorted_by_name.limit(10)`. That trailing `.sorted_by_name` re-sorts the entire relation *before* limiting, which throws away the popularity ordering it just applied. **That is a legacy bug — do not port it.** The new app's count column is `item_count`, not `book_count`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/category_search_query_test.rb`:

```ruby
require "test_helper"

module Books
  class CategorySearchQueryTest < ActiveSupport::TestCase
    test "returns nothing for a blank query" do
      assert_empty Books::CategorySearchQuery.call("")
      assert_empty Books::CategorySearchQuery.call(nil)
      assert_empty Books::CategorySearchQuery.call("   ")
    end

    test "matches on a name substring" do
      assert_includes Books::CategorySearchQuery.call("fict"), categories(:books_fiction_genre)
    end

    test "matches regardless of case" do
      assert_includes Books::CategorySearchQuery.call("FICT"), categories(:books_fiction_genre)
    end

    test "returns every category type, not just genres" do
      results = Books::CategorySearchQuery.call("c", limit: 100)

      assert_includes results, categories(:books_fiction_genre)
      assert_includes results, categories(:books_politics_subject)
      assert_includes results, categories(:books_france_location)
    end

    test "excludes soft-deleted categories" do
      assert_not_includes Books::CategorySearchQuery.call("Retired"), categories(:books_deleted_genre)
    end

    test "excludes other media types" do
      assert_not_includes Books::CategorySearchQuery.call("Rock", limit: 100), categories(:music_rock_genre)
    end

    test "orders by item_count descending, then name" do
      results = Books::CategorySearchQuery.call("c", limit: 100)
      counts = results.map(&:item_count)

      assert_equal counts.sort.reverse, counts
    end

    test "applies the limit after ordering, so the most-used win" do
      results = Books::CategorySearchQuery.call("c", limit: 1)

      assert_equal [categories(:books_fiction_genre)], results
    end

    test "escapes LIKE wildcards in the query" do
      assert_empty Books::CategorySearchQuery.call("%zzz")
    end
  end
end
```

**The query letter is load-bearing.** `"c"` matches `Fiction` (500), `Politics` (200), `Classics` (100), and `France` (50) — one genre, one subject, one location, in strictly descending count order, with a deterministic winner at `limit: 1`. It does **not** match `Novels` or `Retired Genre`. Do not substitute another letter without re-checking all six fixture names: `"i"` looks equivalent but `France` contains no `i`, which silently breaks the every-type assertion.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/books/category_search_query_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::CategorySearchQuery`

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/books/category_search_query.rb`:

```ruby
module Books
  class CategorySearchQuery
    DEFAULT_LIMIT = 10

    def self.call(query, limit: DEFAULT_LIMIT)
      new(query, limit: limit).call
    end

    def initialize(query, limit:)
      @query = query.to_s.strip
      @limit = limit
    end

    def call
      return [] if @query.blank?

      Books::Category
        .active
        .search_by_name(@query)
        .order(item_count: :desc, name: :asc)
        .limit(@limit)
        .to_a
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/books/category_search_query_test.rb`
Expected: `9 runs, 0 failures`

If `escapes LIKE wildcards in the query` fails, the `search_by_name` scope's `sanitize_sql_like` is doing its job but `%` still matches everything — in that case assert on a query of `"%zzz"` instead, which cannot match any fixture name.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/category_search_query.rb test/lib/books/category_search_query_test.rb
git add app/lib/books/category_search_query.rb test/lib/books/category_search_query_test.rb
git commit -m "$(cat <<'EOF'
Add Books::CategorySearchQuery

Searches every active books category type by name, ordered by item_count so
the most-used surface first. Legacy re-sorts by name before limiting, which
discards the popularity ordering; that is a bug and is not ported.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `Books::CountrySearchQuery`

**Files:**
- Create: `app/lib/books/country_search_query.rb`
- Test: `test/lib/books/country_search_query_test.rb`

**Interfaces:**
- Consumes: `Books::Country.filterable`, `book_count`. Note `Books::Country` has **no** `search_by_name` scope — `Category` has it, `Country` does not. Write the `ILIKE` inline with `sanitize_sql_like`.
- Produces: `Books::CountrySearchQuery.call(query, limit: 10)` → `Array<Books::Country>`, `unknown` excluded, ordered `book_count DESC, name ASC`, capped at `limit`. `[]` for a blank query. Increment 2's `Books::FiltersController#countries` calls this.

Fixture counts already differ (`french: 2`, `japanese: 1`, `unknown: 0`, `algerian: 0`), so no fixture change is needed here.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/country_search_query_test.rb`:

```ruby
require "test_helper"

module Books
  class CountrySearchQueryTest < ActiveSupport::TestCase
    test "returns nothing for a blank query" do
      assert_empty Books::CountrySearchQuery.call("")
      assert_empty Books::CountrySearchQuery.call(nil)
      assert_empty Books::CountrySearchQuery.call("   ")
    end

    test "matches on a name substring" do
      assert_includes Books::CountrySearchQuery.call("fren"), books_countries(:french)
    end

    test "matches regardless of case" do
      assert_includes Books::CountrySearchQuery.call("FREN"), books_countries(:french)
    end

    test "excludes the unknown bucket" do
      assert_not_includes Books::CountrySearchQuery.call("n", limit: 100), books_countries(:unknown)
    end

    test "orders by book_count descending, then name" do
      results = Books::CountrySearchQuery.call("n", limit: 100)
      counts = results.map(&:book_count)

      assert_equal counts.sort.reverse, counts
    end

    test "applies the limit after ordering" do
      results = Books::CountrySearchQuery.call("n", limit: 1)

      assert_equal [books_countries(:french)], results
    end

    test "escapes LIKE wildcards in the query" do
      assert_empty Books::CountrySearchQuery.call("%", limit: 100)
    end
  end
end
```

**The wildcard test must use a bare `"%"`, not `"%zzz"`.** `sanitize_sql_like("%")` yields `\%`, so the pattern becomes `%\%%`, which matches only names containing a literal percent sign — none — and the assertion passes. Without escaping the pattern is `%%%`, which matches every country and the assertion fails. `"%zzz"` would pass either way, since no fixture name contains `zzz`, so it asserts nothing.

**The query letter is load-bearing here too.** `"n"` matches `French` (2), `Japanese` (1), `Algerian` (0) **and** `Unknown` (0) — so the same query proves descending order, a deterministic `limit: 1` winner, and that `filterable` drops `Unknown` even when it matches. `"a"` looks equivalent but `French` contains no `a`, which would make `limit: 1` yield `Japanese` instead.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/books/country_search_query_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::CountrySearchQuery`

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/books/country_search_query.rb`:

```ruby
module Books
  class CountrySearchQuery
    DEFAULT_LIMIT = 10

    def self.call(query, limit: DEFAULT_LIMIT)
      new(query, limit: limit).call
    end

    def initialize(query, limit:)
      @query = query.to_s.strip
      @limit = limit
    end

    def call
      return [] if @query.blank?

      Books::Country
        .filterable
        .where("name ILIKE ?", "%#{Books::Country.sanitize_sql_like(@query)}%")
        .order(book_count: :desc, name: :asc)
        .limit(@limit)
        .to_a
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/books/country_search_query_test.rb`
Expected: `7 runs, 0 failures`

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/country_search_query.rb test/lib/books/country_search_query_test.rb
git add app/lib/books/country_search_query.rb test/lib/books/country_search_query_test.rb
git commit -m "$(cat <<'EOF'
Add Books::CountrySearchQuery

Mirrors CategorySearchQuery for the Origin axis. Books::Country has no
search_by_name scope of its own, so the ILIKE is inline with sanitize_sql_like.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Split `Books::FilterFacetsQuery` per axis and cap it at 24

**Files:**
- Modify: `app/lib/books/filter_facets_query.rb`
- Test: `test/lib/books/filter_facets_query_test.rb` (add to it; **every existing test must keep passing**)

**Interfaces:**
- Consumes: `Books::RankedBooksQuery` (untouched).
- Produces: two new class methods alongside the existing `.call`:

```ruby
Books::FilterFacetsQuery.genres(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
# => [{record: Books::Category, count: Integer}]

Books::FilterFacetsQuery.countries(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
# => [{record: Books::Country, count: Integer}]

Books::FilterFacetsQuery.call(...)  # unchanged — still returns Result(genres:, countries:)
```

Increment 2's pane actions call `.genres` and `.countries` so each pane fetch runs **one** query. `.call` stays because `Books::FilterFacetsComponent` still uses it and is not deleted until increment 2.

**`DEFAULT_LIMIT` changes from 500 to 24.** The 500 was introduced by commit `25b7c560` so a client-side search box could reach the whole taxonomy; increment 2 replaces that with server-side search, and 500 is what makes the current modal 345 rows tall.

The genre/country asymmetry documented in the class header is deliberate and must survive the refactor: the genre facet keeps the category filter applied (AND semantics — it reports the intersection you would get by drilling down), while the country facet drops the country filter (OR semantics — it reports alternatives).

- [ ] **Step 1: Write the failing tests**

Append inside `module Books ... class FilterFacetsQueryTest` in `test/lib/books/filter_facets_query_test.rb`, before the final `end end`:

```ruby
    test "DEFAULT_LIMIT is small enough for a phone-sized pane" do
      assert_equal 24, Books::FilterFacetsQuery::DEFAULT_LIMIT
    end

    test "genres can be queried on their own" do
      rows = Books::FilterFacetsQuery.genres(ranking_configuration: @rc)
      counts = rows.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["novels"]
      assert_equal 1, counts["classics"]
    end

    test "countries can be queried on their own" do
      rows = Books::FilterFacetsQuery.countries(ranking_configuration: @rc)
      counts = rows.to_h { |row| [row[:record].slug, row[:count]] }

      assert_equal 2, counts["french"]
    end

    test "the per-axis methods match what call returns" do
      result = facets

      assert_equal result.genres, Books::FilterFacetsQuery.genres(ranking_configuration: @rc)
      assert_equal result.countries, Books::FilterFacetsQuery.countries(ranking_configuration: @rc)
    end

    test "the per-axis genre method keeps the category filter applied" do
      rows = Books::FilterFacetsQuery.genres(
        ranking_configuration: @rc,
        categories: [categories(:books_novels_genre)]
      )
      slugs = rows.map { |row| row[:record].slug }

      assert_includes slugs, "classics"
      assert_not_includes slugs, "novels"
    end

    test "the per-axis country method drops its own filter" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:japanese))

      rows = Books::FilterFacetsQuery.countries(
        ranking_configuration: @rc,
        countries: [books_countries(:french)]
      )
      slugs = rows.map { |row| row[:record].slug }

      assert_includes slugs, "japanese"
      assert_not_includes slugs, "french"
    end

    test "the per-axis methods respect the limit" do
      assert_operator Books::FilterFacetsQuery.genres(ranking_configuration: @rc, limit: 1).size, :<=, 1
      assert_operator Books::FilterFacetsQuery.countries(ranking_configuration: @rc, limit: 1).size, :<=, 1
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/books/filter_facets_query_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'genres' for Books::FilterFacetsQuery` and an assertion failure on `DEFAULT_LIMIT` (`500` vs `24`).

- [ ] **Step 3: Write the implementation**

Replace `app/lib/books/filter_facets_query.rb` with:

```ruby
module Books
  # Facet counts for the filter modal. The two axes are asymmetric on purpose:
  # genres AND, so their facet keeps the category filter applied and reports the
  # intersection you would actually get by drilling down; countries OR, so their
  # facet drops the country filter and reports alternatives. Each axis omits
  # what is already selected. Mirrors the legacy site's behaviour.
  class FilterFacetsQuery
    # One pane's worth. The modal searches the server rather than filtering a
    # pre-rendered list, so this bounds what a pane shows, not what is reachable.
    DEFAULT_LIMIT = 24

    Result = Struct.new(:genres, :countries, keyword_init: true)

    def self.call(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
      query = build(ranking_configuration, categories, countries, year_start, year_end, limit)
      Result.new(genres: query.genre_facet, countries: query.country_facet)
    end

    def self.genres(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
      build(ranking_configuration, categories, countries, year_start, year_end, limit).genre_facet
    end

    def self.countries(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
      build(ranking_configuration, categories, countries, year_start, year_end, limit).country_facet
    end

    def self.build(ranking_configuration, categories, countries, year_start, year_end, limit)
      new(
        ranking_configuration: ranking_configuration,
        categories: Array(categories),
        countries: Array(countries),
        year_start: year_start,
        year_end: year_end,
        limit: limit
      )
    end
    private_class_method :build

    def initialize(ranking_configuration:, categories:, countries:, year_start:, year_end:, limit:)
      @ranking_configuration = ranking_configuration
      @categories = categories
      @countries = countries
      @year_start = year_start
      @year_end = year_end
      @limit = limit
    end

    def genre_facet
      counts = CategoryItem
        .where(item_type: "Books::Book", item_id: book_ids(countries: @countries, categories: @categories))
        .joins(:category)
        .where(categories: {deleted: false, category_type: Category.category_types[:genre], type: "Books::Category"})
        .where.not(category_id: @categories.map(&:id))
        .group(:category_id)
        .order(count_all: :desc, category_id: :asc)
        .limit(@limit)
        .count

      rows_for(Books::Category.where(id: counts.keys), counts)
    end

    def country_facet
      counts = Books::BookCountry
        .where(book_id: book_ids(countries: [], categories: @categories))
        .where.not(country_id: @countries.map(&:id))
        .where(country_id: Books::Country.filterable.select(:id))
        .group(:country_id)
        .order(count_all: :desc, country_id: :asc)
        .limit(@limit)
        .count

      rows_for(Books::Country.where(id: counts.keys), counts)
    end

    private

    # RankedBooksQuery returns a relation carrying includes(...) and order(:rank)
    # for rendering. Both are wrong inside a subquery -- eager-load joins change
    # the shape, and ordering an IN (...) subquery is meaningless -- so strip them.
    def book_ids(countries:, categories:)
      RankedBooksQuery.call(
        ranking_configuration: @ranking_configuration,
        categories: categories,
        countries: countries,
        year_start: @year_start,
        year_end: @year_end
      ).except(:includes).reorder(nil).reselect(:item_id)
    end

    def rows_for(scope, counts)
      by_id = scope.index_by(&:id)
      counts.map { |id, count| {record: by_id[id], count: count} }.reject { |row| row[:record].nil? }
    end
  end
end
```

`genre_facet` and `country_facet` move from `private` to public because the class methods call them on the instance. Their bodies are unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/books/filter_facets_query_test.rb`
Expected: `17 runs, 0 failures` — the 10 pre-existing tests plus the 7 new ones, all green. **If any pre-existing test now fails, the refactor changed behaviour and must be corrected, not the test.**

- [ ] **Step 5: Confirm the still-live component did not break**

Run: `bin/rails test test/components/books/ test/controllers/books/`
Expected: all pass. `Books::FilterFacetsComponent` reads `.call(...)` and is untouched by this task.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/filter_facets_query.rb test/lib/books/filter_facets_query_test.rb
git add app/lib/books/filter_facets_query.rb test/lib/books/filter_facets_query_test.rb
git commit -m "$(cat <<'EOF'
Query each filter facet axis independently, capped at 24

The drill-down modal shows one axis at a time, so opening a pane should run
one query rather than both. .call keeps returning the two-axis Result while
FilterFacetsComponent still exists.

DEFAULT_LIMIT drops 500 -> 24. The 500 existed so a client-side search box
could reach the whole taxonomy; server-side search replaces that.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Selection caps in `Books::FilterParams`

**Files:**
- Modify: `app/lib/books/filter_params.rb`
- Test: `test/lib/books/filter_params_test.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Books::FilterParams::MAX_CATEGORIES = 6` and `MAX_COUNTRIES = 10`. Exceeding either raises `ActiveRecord::RecordNotFound`, which the controllers already render as a 404 — the same seam and same failure mode as an unknown slug, so there is one error path rather than two. Increment 2 reads these constants to disable checkboxes at the cap.

Ported from legacy, which enforces both. Categories are ANDed as one subquery each, so the cap bounds query cost as well as URL length.

- [ ] **Step 1: Write the failing test**

Append inside `module Books ... class FilterParamsTest` in `test/lib/books/filter_params_test.rb`, before the final `end end`:

```ruby
    test "caps categories at MAX_CATEGORIES" do
      assert_equal 6, Books::FilterParams::MAX_CATEGORIES

      slugs = (1..7).map { |n|
        Books::Category.create!(name: "Generated Genre #{n}", category_type: :genre).slug
      }

      assert_nothing_raised do
        Books::FilterParams.call(ActionController::Parameters.new(category_id: slugs.first(6).join(",")))
      end

      assert_raises ActiveRecord::RecordNotFound do
        Books::FilterParams.call(ActionController::Parameters.new(category_id: slugs.join(",")))
      end
    end

    test "caps countries at MAX_COUNTRIES" do
      assert_equal 10, Books::FilterParams::MAX_COUNTRIES

      slugs = (1..11).map { |n|
        Books::Country.create!(name: "Generated Country #{n}").slug
      }

      assert_nothing_raised do
        Books::FilterParams.call(ActionController::Parameters.new(country_id: slugs.first(10).join(",")))
      end

      assert_raises ActiveRecord::RecordNotFound do
        Books::FilterParams.call(ActionController::Parameters.new(country_id: slugs.join(",")))
      end
    end

    test "the cap counts unique slugs, not repeats" do
      repeated = (["fiction"] * 20).join(",")

      assert_nothing_raised do
        Books::FilterParams.call(ActionController::Parameters.new(category_id: repeated))
      end
    end
```

The last test matters because `resolve` already calls `.uniq`; the cap must be applied **after** deduplication or `/the-greatest/fiction,fiction,fiction,fiction,fiction,fiction,fiction/books` would 404 despite naming one category.

**Read the slug back off the created record — do not pass `slug:` to `create!`.** `Category#should_generate_new_friendly_id?` is overridden to `slug.blank? || name_changed?`, and `name_changed?` is true on create, so FriendlyId **overwrites** any slug you supply. A test that passes `slug: "genre-1"` and then filters on `"genre-1"` fails with `RecordNotFound` from the wrong branch and looks like a cap bug. (`Books::Country` does not override the method and would honour an explicit slug, but reading it back keeps both tests identical.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/books/filter_params_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::FilterParams::MAX_CATEGORIES`

- [ ] **Step 3: Write minimal implementation**

In `app/lib/books/filter_params.rb`, add the two constants below `YEAR_RANGE`:

```ruby
    MAX_CATEGORIES = 6
    MAX_COUNTRIES = 10
```

Change `call` to pass a cap into `resolve`:

```ruby
    def call
      year = validated_year(@params[:year])

      Result.new(
        categories: resolve(Books::Category.active, @params[:category_id], MAX_CATEGORIES),
        countries: resolve(Books::Country.all, @params[:country_id], MAX_COUNTRIES),
        year_start: year || validated_year(@params[:published_start]),
        year_end: year || validated_year(@params[:published_end])
      )
    end
```

And change `resolve` to enforce it after `.uniq`:

```ruby
    def resolve(scope, raw, max)
      slugs = raw.to_s.split(",").map(&:strip).reject(&:blank?).uniq
      return [] if slugs.empty?
      raise ActiveRecord::RecordNotFound if slugs.size > max

      records = scope.where(slug: slugs).sort_by(&:slug)
      raise ActiveRecord::RecordNotFound if records.size != slugs.size

      records
    end
```

The cap check goes **before** the database query, so an over-long URL costs no query.

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/books/filter_params_test.rb`
Expected: all pass, including every pre-existing test in the file.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/filter_params.rb test/lib/books/filter_params_test.rb
git add app/lib/books/filter_params.rb test/lib/books/filter_params_test.rb
git commit -m "$(cat <<'EOF'
Cap filter selections at 6 categories and 10 countries

Ported from legacy, which enforces both. Categories are ANDed as one
subquery each, so the cap bounds query cost as well as URL length. Reuses
the existing RecordNotFound -> 404 seam, and is checked after .uniq so
repeated slugs do not trip it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Retire the E2E test that depends on the 500 limit, then gate

**Files:**
- Modify: `e2e/tests/books/filters.spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: an E2E suite consistent with a 24-row facet limit. Increment 2 rewrites this file wholesale.

`e2e/tests/books/filters.spec.ts` → **`'search reaches genres and countries outside the most-common ones'`** asserts `surreal`, `absurdist`, and `peruvian` are present in the DOM. That is only true while every facet row is rendered, i.e. while `DEFAULT_LIMIT` is 500. Task 4 removed that. Delete the test rather than relax it: it asserts a capability this increment deliberately removes, and increment 2 restores that capability server-side with a different mechanism and a different assertion.

Leave `'genre search filters the visible options'` alone — it only asserts that filtering reduces the visible count, which still holds at 24 rows. Increment 2 replaces it when the placeholder text changes.

- [ ] **Step 1: Delete the obsolete test**

Remove this entire block from `e2e/tests/books/filters.spec.ts`:

```ts
  test('search reaches genres and countries outside the most-common ones', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    const search = page.getByPlaceholder('Filter genres and countries');

    await search.fill('sur');
    await expect(page.locator('label[data-filter-label="surreal"]')).toBeVisible();

    await search.fill('ab');
    await expect(page.locator('label[data-filter-label="absurdist"]')).toBeVisible();

    await search.fill('peruv');
    await expect(page.locator('label[data-filter-label="peruvian"]')).toBeVisible();
  });
```

- [ ] **Step 2: Run the full Ruby suite**

Run: `bin/rails test`
Expected: `0 failures, 0 errors`. Runs count should be the Task 0 baseline **+ 26** (9 from Task 2, 7 from Task 3, 7 from Task 4, 3 from Task 5). Against the recorded baseline that is **5595 runs**. If the total differs, find out why before continuing — a lower count means tests silently stopped loading.

- [ ] **Step 3: Run lint across the whole project**

Run: `bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 4: Run the books E2E specs**

`bin/dev` self-terminates in a non-TTY shell — the Tailwind watcher exits and takes foreman with it. Build and serve separately, and confirm port 3000 is *this* worktree's server before trusting a run. Caddy proxies `dev-new.thegreatestbooks.org` → `localhost:3000`; the books routes are hostname-constrained, so hitting `localhost:3000` directly will **not** match them.

```bash
yarn build:all
bin/rails server &
yarn test:e2e e2e/tests/books/filters.spec.ts
```

Expected: all remaining tests pass. If every admin spec times out on the public homepage, the e2e user lost its role in a dev-DB reseed — fix with `bin/rails e2e:admin`, not by debugging login.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/filters.spec.ts
git commit -m "$(cat <<'EOF'
Drop the E2E test that required every facet row to be rendered

It asserted surreal/absurdist/peruvian were in the DOM, which only held
while DEFAULT_LIMIT was 500. Increment 2 restores that reach through the
server-side per-axis search with a different assertion.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done when

- [ ] `bin/rails test` → 0 failures, runs count = baseline + 26
- [ ] `bundle exec standardrb` → no offenses
- [ ] `yarn test:e2e e2e/tests/books/filters.spec.ts` → passing
- [ ] `Books::CategorySearchQuery`, `Books::CountrySearchQuery`, `FilterFacetsQuery.genres`, `FilterFacetsQuery.countries`, `FilterParams::MAX_CATEGORIES`, `FilterParams::MAX_COUNTRIES` all exist with the signatures in this plan — increment 2 calls every one of them
- [ ] Nothing in `app/views/`, `app/components/`, or `app/javascript/` was modified

## Landmines

- **Do not delete `FilterFacetsQuery.call`.** `Books::FilterFacetsComponent` still calls it and is not deleted until increment 2. Removing it turns the live modal into a 500.
- **`genre_facet` / `country_facet` must become public** for the class methods to reach them. Leaving them private raises `NoMethodError` only at runtime, not at load.
- **Apply the selection cap after `.uniq`**, or a URL repeating one slug seven times 404s.
- **`Category#should_generate_new_friendly_id?` is `slug.blank? || name_changed?`**, so an explicit `slug:` passed to `Books::Category.create!` is silently overwritten on create. Read the slug back off the record instead. `Books::Country` does not override this and behaves the other way — do not assume they match.
- **Fixture-derived search letters are load-bearing** in Tasks 2 and 3 (`"c"` and `"n"`). Both were chosen against all six category and all four country fixture names. Changing either silently weakens or breaks an assertion rather than failing loudly.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** To inspect a fixture, read the YAML: `sed -n '/^name:/,/^$/p' test/fixtures/<file>.yml`. The books data exists only in development and takes hours to rebuild.
- **Inside `Services::BooksMigration`, a bare `Music::` resolves to `Services::Music`.** Not touched by this increment, but the same root-anchoring habit applies anywhere a bare `Books::` constant is written inside a `Books`-named module.
- The worktree shares `the_greatest_test` with the main checkout — do not run tests concurrently with another worktree.
