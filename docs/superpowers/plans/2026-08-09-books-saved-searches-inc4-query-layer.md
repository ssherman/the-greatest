# Books Saved Searches — Increment 4: Query Layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a stored `criteria` hash into a page of books — the layer that makes the 4,727 migrated saved searches executable.

**Architecture:** Four objects with one job each. `Books::BookType` is the single source for the four legacy `book_type` values. `Books::SavedSearchCriteria` wraps the raw jsonb with tolerant typed readers, so migrated rows (Integer `book_type`, String `ranked`) and future form params (all strings) are indistinguishable downstream. `Search::Books::Search::BookAdvanced` turns criteria into a bool query and returns one page of ids plus a total — it owns **every** filter, including `max_ranked_position` and `hide_read`, because a filter applied after OpenSearch sizes the page returns short pages. `Books::SavedSearchQuery` orchestrates: resolves the read list, calls the search, hydrates one page from Postgres, re-applies OpenSearch's order.

**Tech Stack:** Rails 8.1, PostgreSQL, OpenSearch, Minitest + fixtures + Mocha, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-08-08-books-saved-searches-design.md` §5.2, §5.4, §6 (all amended 2026-08-09 for this increment — read the amended text, not memory of the original).

**Depends on:** increments 1–3, all merged and deployed. Increment 2 indexed `ranked_position`; increment 3 built `SavedSearch`, `Books::SavedSearch` and its four class hooks.

## Global Constraints

- Run **all** commands from `web-app/`.
- Business logic lives in `app/lib/`, never `app/services/`. POROs and query objects go in `app/lib/books/`; search classes in `app/lib/search/books/search/`.
- Lint with `bundle exec standardrb`, **never** `bin/rubocop`. Do **not** run `bin/brakeman`.
- Tests mirror the namespace and path: `app/lib/books/foo.rb` → `test/lib/books/foo_test.rb`.
- **Inside any `module Search`, and inside `Services::BooksMigration`, a bare domain constant resolves to the nested module.** Root-anchor every top-level model: `::Books::Book`, `::Books::BookType`, `::Books::RankingConfiguration`. This landmine has bitten this project three times.
- **This increment is read-only.** No writes, anywhere. `last_executed_at` belongs to increment 5's controller; `result_count` is not written at all.
- **The development database is not disposable.** The books data exists ONLY there and takes hours to rebuild. No `db:drop`/`db:reset`/`db:schema:load`, no `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES every table it names — read fixture YAML with Read), no bulk `delete_all`/`destroy_all`/`update_all`.
- Search tests run against a **real OpenSearch test index**. The pattern is `setup { cleanup_test_index; Index.create_index }` / `teardown { cleanup_test_index }`, with a private `cleanup_test_index` rescuing `OpenSearch::Transport::Transport::Errors::NotFound`. Copy it from `test/lib/search/books/search/book_general_test.rb:102-105`. Indexing is not instant — existing tests `sleep(0.1)` after indexing before asserting.
- Before any commit that finishes a task: `bin/rails test` and `bundle exec standardrb` must both pass.

## Baseline

`bin/rails test` at the branch point: **5,874 runs, 0 failures.**

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/books/book_type.rb` | The four legacy `book_type` values: label, legacy category id, and this database's category id |
| `app/lib/books/saved_search_criteria.rb` | Tolerant typed readers over the raw criteria hash. No DB, no OpenSearch |
| `app/lib/search/books/search/book_advanced.rb` | criteria → bool query → one page of ids + total. Owns every filter. No DB |
| `app/lib/books/saved_search_query.rb` | Orchestration: read list → search → hydrate → re-order |
| `app/models/saved_search.rb` | Gains `#criteria_object`, using the existing `criteria_class` hook |
| `app/models/books/saved_search.rb` | `#summary` reads through the criteria object; `BOOK_TYPE_LABELS` removed |
| `app/lib/services/books_migration/book_type_category_migrator.rb` | `LEGACY_CATEGORY_IDS` becomes an alias of `Books::BookType`'s |

---

### Task 1: `Books::BookType`

**Files:**
- Create: `app/lib/books/book_type.rb`
- Create: `test/lib/books/book_type_test.rb`
- Modify: `app/models/books/saved_search.rb` (remove `BOOK_TYPE_LABELS`, delegate the label lookup)
- Modify: `app/lib/services/books_migration/book_type_category_migrator.rb` (alias its constant)

**Interfaces:**
- Consumes: `LegacyIdMap` (`model: "Books::Category"`), `Books::Category`.
- Produces: `Books::BookType.label(v) => String|nil`, `.legacy_category_id(v) => Integer|nil`, `.category_id(v) => Integer|nil`, `.reset_category_ids!`, and the constants `LABELS` / `LEGACY_CATEGORY_IDS`. Tasks 3 and 4 consume `.label` and `.category_id`.

**Why a value object:** `book_type` has no column — the four legacy values are category data resolved at query time. Its label map lives in `Books::SavedSearch::BOOK_TYPE_LABELS` and its legacy-id map in `BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS`, both keyed on the same 0–3 integers. Task 4 needs a **third** view of the same thing (this database's category ids). Consolidate before adding, not after.

**Why runtime resolution, not hardcoded new ids:** `categories` is shared across domains and its ids were **not** preserved by the migration, so the new id is a per-database fact. Measured 2026-08-09: dev and production both resolve to `{0=>2683, 1=>3348, 2=>9343, 3=>3211}`, so hardcoding would work *today*. Runtime resolution is preferred because it costs nothing, matches what `BookTypeCategoryMigrator` already does, and does not depend on that agreement holding.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/book_type_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class BookTypeTest < ActiveSupport::TestCase
    setup do
      ::Books::BookType.reset_category_ids!
    end

    teardown do
      ::Books::BookType.reset_category_ids!
    end

    test "labels every legacy book_type value" do
      assert_equal "Fiction", ::Books::BookType.label(0)
      assert_equal "Nonfiction", ::Books::BookType.label(1)
      assert_equal "Religion & Spirituality", ::Books::BookType.label(2)
      assert_equal "Poetry", ::Books::BookType.label(3)
    end

    test "labels an unknown value as nil" do
      assert_nil ::Books::BookType.label(9)
      assert_nil ::Books::BookType.label(nil)
    end

    test "exposes the legacy category id" do
      assert_equal 40348, ::Books::BookType.legacy_category_id(0)
      assert_equal 47008, ::Books::BookType.legacy_category_id(2)
      assert_nil ::Books::BookType.legacy_category_id(9)
    end

    test "resolves this database's category id through LegacyIdMap" do
      category = ::Books::Category.create!(name: "BookType Target Genre", category_type: :genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 40348, new_id: category.id)
      ::Books::BookType.reset_category_ids!

      assert_equal category.id, ::Books::BookType.category_id(0)
    end

    test "returns nil when the legacy category has no mapping" do
      assert_nil ::Books::BookType.category_id(3)
    end

    test "returns nil for an unknown book_type without touching the map" do
      assert_nil ::Books::BookType.category_id(9)
    end

    test "memoizes the map so repeated lookups issue one query" do
      category = ::Books::Category.create!(name: "BookType Memo Genre", category_type: :genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 41013, new_id: category.id)
      ::Books::BookType.reset_category_ids!

      ::Books::BookType.category_id(1)

      assert_queries_count(0) do
        3.times { ::Books::BookType.category_id(1) }
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/books/book_type_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::BookType`

- [ ] **Step 3: Write the value object**

Create `app/lib/books/book_type.rb`:

```ruby
# frozen_string_literal: true

module Books
  # The four legacy book_type values (fiction/nonfiction/religious/poetry).
  # book_type has no column of its own: the values are category data, so a
  # criterion resolves to a category at query time.
  #
  # Single source for all three things the app asks of a book_type -- its
  # display label, its LEGACY category id, and its category id in THIS
  # database. Before this class the first two lived in two unrelated constants
  # keyed on the same 0-3 integers, and the query layer was about to add a third.
  #
  # The current-database id is resolved through LegacyIdMap rather than
  # hardcoded: `categories` is shared across domains and its ids were NOT
  # preserved by the migration, so the new id is a per-database fact. (Measured
  # 2026-08-09: dev and production happen to agree, which is exactly what would
  # make a hardcoded id look correct and stay fragile.)
  class BookType
    LABELS = {
      0 => "Fiction",
      1 => "Nonfiction",
      2 => "Religion & Spirituality",
      3 => "Poetry"
    }.freeze

    # Legacy `categories` ids. religious (2) maps to the "Religion &
    # Spirituality" GENRE, not the near-empty "Religious" subject category,
    # which held 9 items against 1,899 typed books.
    LEGACY_CATEGORY_IDS = {
      0 => 40348,
      1 => 41013,
      2 => 47008,
      3 => 40876
    }.freeze

    # "Religion & Spirituality" is a deliberate copy change from legacy's
    # "Religious"; the underlying value (2) is unchanged.
    def self.label(value)
      LABELS[value]
    end

    def self.legacy_category_id(value)
      LEGACY_CATEGORY_IDS[value]
    end

    # This database's category id, or nil when the value is unknown or the
    # categories migration has not run here. Memoized per process because the
    # mapping is immutable once that migration has run; reset_category_ids!
    # exists for tests, which create mappings after boot.
    def self.category_id(value)
      legacy_id = LEGACY_CATEGORY_IDS[value]
      return nil if legacy_id.nil?

      category_ids[legacy_id]
    end

    def self.reset_category_ids!
      @category_ids = nil
    end

    def self.category_ids
      @category_ids ||= LegacyIdMap
        .where(model: "Books::Category", legacy_id: LEGACY_CATEGORY_IDS.values)
        .pluck(:legacy_id, :new_id)
        .to_h
    end
    private_class_method :category_ids
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/books/book_type_test.rb`
Expected: PASS

- [ ] **Step 5: Point the model at it**

In `app/models/books/saved_search.rb`, delete the `BOOK_TYPE_LABELS` constant **and its comment block entirely**, and change the label lookup inside `summary` from:

```ruby
        BOOK_TYPE_LABELS[criteria["book_type"]],
```

to:

```ruby
        ::Books::BookType.label(criteria["book_type"]),
```

Leave the rest of `summary` alone — Task 3 rewrites it.

- [ ] **Step 6: Point the migrator at it**

In `app/lib/services/books_migration/book_type_category_migrator.rb`, replace the literal hash with an alias so any existing reference to `BookTypeCategoryMigrator::LEGACY_CATEGORY_IDS` keeps resolving:

```ruby
      # Canonical map lives in ::Books::BookType -- the query layer and the
      # saved-search summary read the same one.
      LEGACY_CATEGORY_IDS = ::Books::BookType::LEGACY_CATEGORY_IDS
```

Delete the four-line literal hash and the comment above it that duplicates what `BookType` now documents, but **keep** the class-level comment explaining the religious→"Religion & Spirituality" decision.

- [ ] **Step 7: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass, with **7 more runs** than the 5,874 baseline and zero failures. The migrator's own tests are the guard that Step 6 didn't break the constant.

- [ ] **Step 8: Commit**

```bash
git add app/lib/books/book_type.rb test/lib/books/book_type_test.rb \
        app/models/books/saved_search.rb \
        app/lib/services/books_migration/book_type_category_migrator.rb
git commit -m "Add Books::BookType as the single book_type map"
```

---

### Task 2: `Books::SavedSearchCriteria`

**Files:**
- Create: `app/lib/books/saved_search_criteria.rb`
- Create: `test/lib/books/saved_search_criteria_test.rb`

**Interfaces:**
- Consumes: `Books::Book.book_lengths` (an in-memory enum hash — no query).
- Produces: `Books::SavedSearchCriteria.new(raw_hash)` with readers `included_category_ids`, `excluded_category_ids`, `included_language_ids`, `excluded_language_ids`, `included_country_ids`, `excluded_country_ids` (all `[Integer]`), `book_type` (`Integer|nil`), `book_length` (`[Integer]`), `first_year_published_gt` / `first_year_published_lt` (`Integer|nil`), `ranked` (`:ranked|:unranked|nil`), `genre_match_mode` (`:any|:all`), `hide_read` (boolean), `max_ranked_position` (`Integer|nil`). Tasks 3, 4 and 5 consume these.

**The whole point is tolerance.** Two populations of criteria must be indistinguishable downstream: the 4,727 migrated rows (`book_type` stored as Integer `0`, `ranked` as String `"true"`) and future form-created rows (params arrive as strings). Normalizing on write is the alternative, and it is worse — it is a step a future writer can forget, and it would need a data migration for rows already stored. Every reader accepting both shapes is the version that cannot rot.

**`ranked` is a tri-state, and nil is not false.** Absent means "the whole corpus"; `:unranked` means "unranked only". A boolean reader collapses the two and silently changes what 437 stored searches return. Legacy's "All Books" option submits `""`, which must read as nil.

**Parse with `Integer(v, exception: false)`, never `to_i`.** `"abc".to_i` is `0`, which is a *valid* `book_type` (Fiction) and a valid `book_length`. Silent corruption; `Integer(…, exception: false)` returns nil instead.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/saved_search_criteria_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class SavedSearchCriteriaTest < ActiveSupport::TestCase
    def criteria(hash)
      ::Books::SavedSearchCriteria.new(hash)
    end

    test "tolerates a nil raw hash" do
      c = criteria(nil)

      assert_nil c.book_type
      assert_equal [], c.included_category_ids
      assert_equal :any, c.genre_match_mode
      refute c.hide_read
    end

    test "reads id arrays as integers from either shape" do
      from_strings = criteria({"included_category_ids" => ["12", "34"]})
      from_ints = criteria({"included_category_ids" => [12, 34]})

      assert_equal [12, 34], from_strings.included_category_ids
      assert_equal [12, 34], from_ints.included_category_ids
    end

    test "drops blank entries from id arrays rather than reading them as zero" do
      c = criteria({"included_language_ids" => ["12", "", nil]})

      assert_equal [12], c.included_language_ids
    end

    test "reads every id array" do
      c = criteria({
        "included_category_ids" => ["1"], "excluded_category_ids" => ["2"],
        "included_language_ids" => ["3"], "excluded_language_ids" => ["4"],
        "included_country_ids" => ["5"], "excluded_country_ids" => ["6"]
      })

      assert_equal [1], c.included_category_ids
      assert_equal [2], c.excluded_category_ids
      assert_equal [3], c.included_language_ids
      assert_equal [4], c.excluded_language_ids
      assert_equal [5], c.included_country_ids
      assert_equal [6], c.excluded_country_ids
    end

    test "reads book_type from either shape" do
      assert_equal 0, criteria({"book_type" => 0}).book_type
      assert_equal 0, criteria({"book_type" => "0"}).book_type
      assert_nil criteria({}).book_type
      assert_nil criteria({"book_type" => ""}).book_type
    end

    test "reads book_type of nonsense as nil, not zero" do
      assert_nil criteria({"book_type" => "abc"}).book_type
    end

    test "reads book_length as integers, filtering values outside the enum" do
      c = criteria({"book_length" => [1, 2, 99]})

      assert_equal [1, 2], c.book_length
    end

    test "tolerates a scalar book_length" do
      assert_equal [3], criteria({"book_length" => 3}).book_length
      assert_equal [3], criteria({"book_length" => "3"}).book_length
    end

    test "reads publication years from either shape" do
      c = criteria({"first_year_published_gt" => "1980", "first_year_published_lt" => 1990})

      assert_equal 1980, c.first_year_published_gt
      assert_equal 1990, c.first_year_published_lt
    end

    test "reads ranked as a tri-state" do
      assert_equal :ranked, criteria({"ranked" => "true"}).ranked
      assert_equal :ranked, criteria({"ranked" => true}).ranked
      assert_equal :unranked, criteria({"ranked" => "false"}).ranked
      assert_equal :unranked, criteria({"ranked" => false}).ranked
    end

    test "reads an absent or empty ranked as nil, which is not unranked" do
      assert_nil criteria({}).ranked
      assert_nil criteria({"ranked" => ""}).ranked
      assert_nil criteria({"ranked" => nil}).ranked
    end

    test "reads genre_match_mode, defaulting to any" do
      assert_equal :all, criteria({"genre_match_mode" => "all"}).genre_match_mode
      assert_equal :any, criteria({"genre_match_mode" => "any"}).genre_match_mode
      assert_equal :any, criteria({}).genre_match_mode
    end

    test "reads hide_read from either shape" do
      assert criteria({"hide_read" => true}).hide_read
      assert criteria({"hide_read" => "true"}).hide_read
      refute criteria({"hide_read" => false}).hide_read
      refute criteria({}).hide_read
    end

    test "reads max_ranked_position from either shape" do
      assert_equal 100, criteria({"max_ranked_position" => 100}).max_ranked_position
      assert_equal 100, criteria({"max_ranked_position" => "100"}).max_ranked_position
      assert_nil criteria({}).max_ranked_position
    end

    test "reads without touching the database" do
      c = criteria({"book_length" => [1], "book_type" => "0"})
      ::Books::Book.book_lengths # warm the class so its first-touch schema load isn't counted

      assert_queries_count(0) do
        c.book_length
        c.book_type
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/books/saved_search_criteria_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::SavedSearchCriteria`

- [ ] **Step 3: Write the PORO**

Create `app/lib/books/saved_search_criteria.rb`:

```ruby
# frozen_string_literal: true

module Books
  # Typed readers over a saved search's raw criteria hash. No database, no
  # OpenSearch -- everything here is a pure read of the stored jsonb.
  #
  # Every reader accepts BOTH storage shapes on purpose. Migrated rows store
  # book_type as an Integer and ranked as the string "true"; a form POSTs "0"
  # and "true" as strings. Normalizing on write was the alternative and is
  # worse: it is a step a future writer can forget, and it would need a data
  # migration for the 4,727 rows already stored.
  class SavedSearchCriteria
    ID_ARRAY_KEYS = %w[
      included_category_ids excluded_category_ids
      included_language_ids excluded_language_ids
      included_country_ids excluded_country_ids
    ].freeze

    def initialize(raw)
      @raw = raw || {}
    end

    ID_ARRAY_KEYS.each do |key|
      define_method(key) { int_array(key) }
    end

    def book_type
      int_or_nil("book_type")
    end

    # Values outside the enum are dropped rather than rendered or queried:
    # Books::Book.book_lengths is an in-memory hash, so this costs no query.
    def book_length
      int_array("book_length").select { |value| ::Books::Book.book_lengths.value?(value) }
    end

    def first_year_published_gt
      int_or_nil("first_year_published_gt")
    end

    def first_year_published_lt
      int_or_nil("first_year_published_lt")
    end

    # Tri-state, deliberately not a boolean: nil means "the whole corpus" and
    # :unranked means "unranked only". Legacy's "All Books" option submits "",
    # which reads as nil. Collapsing nil and :unranked would silently change
    # what 437 stored searches return.
    def ranked
      case @raw["ranked"]
      when "true", true then :ranked
      when "false", false then :unranked
      end
    end

    def genre_match_mode
      (@raw["genre_match_mode"].to_s == "all") ? :all : :any
    end

    def hide_read
      value = @raw["hide_read"]
      value == true || value.to_s == "true"
    end

    def max_ranked_position
      int_or_nil("max_ranked_position")
    end

    private

    # Integer(…, exception: false) rather than to_i: "abc".to_i is 0, which is
    # a valid book_type (Fiction) and a valid book_length. Silent corruption.
    def int_or_nil(key)
      value = @raw[key]
      return nil if value.nil?

      Integer(value, exception: false)
    end

    def int_array(key)
      Array(@raw[key]).filter_map { |value| Integer(value, exception: false) }
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/books/saved_search_criteria_test.rb`
Expected: PASS

- [ ] **Step 5: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass, with **15 more runs** than after Task 1, and zero failures.

- [ ] **Step 6: Commit**

```bash
git add app/lib/books/saved_search_criteria.rb test/lib/books/saved_search_criteria_test.rb
git commit -m "Add Books::SavedSearchCriteria with tolerant typed readers"
```

---

### Task 3: `#summary` reads through the criteria object

**Files:**
- Modify: `app/models/saved_search.rb` (add `#criteria_object`)
- Modify: `app/models/books/saved_search.rb` (`#summary` and its four private helpers)
- Modify: `test/models/books/saved_search_test.rb` (add String-shape cases)

**Interfaces:**
- Consumes: `Books::SavedSearchCriteria` (Task 2), `Books::BookType.label` (Task 1), the existing `SavedSearch.criteria_class` hook.
- Produces: `SavedSearch#criteria_object`, memoized. Increment 5's controller will use it too.

**Why:** `summary` currently reads `criteria["book_type"]` directly against `BOOK_TYPE_LABELS`' Integer keys. A form-created search storing `"0"` renders with no label and no error. Reading through the criteria object removes the duplicated coercion instead of patching it, and it is the first consumer of increment 3's `criteria_class` seam.

- [ ] **Step 1: Write the failing test**

Add these to `test/models/books/saved_search_test.rb`, inside the existing `module Books; class SavedSearchTest`, keeping every existing test:

```ruby
    test "criteria_object wraps the raw hash in the declared criteria class" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {"book_type" => "0"})

      assert_instance_of Books::SavedSearchCriteria, search.criteria_object
      assert_equal 0, search.criteria_object.book_type
    end

    test "criteria_object is memoized" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {})

      assert_same search.criteria_object, search.criteria_object
    end

    test "summary names the book_type category when stored as a string" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {"book_type" => "0"})

      assert_includes search.summary, "Fiction"
    end

    test "summary describes the ranked criterion when stored as a boolean" do
      base = {user: users(:regular_user)}

      assert_includes Books::SavedSearch.new(**base, criteria: {"ranked" => true}).summary, "Ranked"
      assert_includes Books::SavedSearch.new(**base, criteria: {"ranked" => false}).summary, "Unranked"
    end

    test "summary describes a year range stored as integers" do
      search = Books::SavedSearch.new(
        user: users(:regular_user),
        criteria: {"first_year_published_gt" => 1980, "first_year_published_lt" => 1990}
      )

      assert_includes search.summary, "1980"
      assert_includes search.summary, "1990"
    end

    test "summary describes max_ranked_position on its own" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {"max_ranked_position" => "100"})

      assert_equal "Top 100 Ranked Books", search.summary
    end

    test "summary omits a book_length outside the enum instead of rendering a bare label" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {"book_length" => [99]})

      assert_equal "", search.summary
    end

    test "summary renders a book_length stored as strings" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {"book_length" => ["1", "2"]})

      assert_includes search.summary, "Short, Medium Length"
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/books/saved_search_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'criteria_object'`, and the `book_length => [99]` case renders `" Length"` rather than `""`.

- [ ] **Step 3: Add `#criteria_object` to the root model**

In `app/models/saved_search.rb`, add below `display_name`:

```ruby
  # The typed view of `criteria`, built through the subclass's declared
  # criteria_class. Memoized because summary reads several values from it and
  # increment 5's controller will hand the same object to the query layer.
  def criteria_object
    @criteria_object ||= self.class.criteria_class.new(criteria)
  end
```

- [ ] **Step 4: Rewrite `#summary` and its helpers**

In `app/models/books/saved_search.rb`, replace `summary` and all four private helpers with:

```ruby
    # category, language, and country criteria are omitted: naming them requires
    # a database lookup, and the index page renders this for every one of a
    # user's searches, so keeping it lookup-free avoids an N+1 there. book_type
    # and book_length don't need that tradeoff -- both are plain enums.
    #
    # Every value is read through criteria_object rather than the raw hash, so
    # a form-created search storing "0" renders the same as a migrated row
    # storing 0.
    def summary
      parts = [
        ::Books::BookType.label(criteria_object.book_type),
        book_length_summary,
        year_summary,
        ranked_summary,
        max_position_summary
      ]
      parts.compact.join(" · ")
    end

    private

    def book_length_summary
      lengths = criteria_object.book_length
      return nil if lengths.empty?

      labels = lengths.map { |length| ::Books::Book.book_lengths.key(length).to_s.titleize }
      "#{labels.join(", ")} Length"
    end

    def year_summary
      gt = criteria_object.first_year_published_gt
      lt = criteria_object.first_year_published_lt
      return nil if gt.nil? && lt.nil?
      return "Published between #{gt} and #{lt}" if gt && lt
      return "Published after #{gt}" if gt

      "Published before #{lt}"
    end

    def ranked_summary
      case criteria_object.ranked
      when :ranked then "Ranked Books Only"
      when :unranked then "Unranked Books Only"
      end
    end

    def max_position_summary
      position = criteria_object.max_ranked_position
      return nil if position.nil?

      "Top #{position} Ranked Books"
    end
```

The `return "" if criteria.blank?` guard is gone deliberately: every reader returns nil or empty for a blank hash, so `parts.compact.join` already yields `""`. The existing "renders an empty string for blank criteria" test still passes and now covers that.

- [ ] **Step 5: Run it to verify it passes**

Run: `bin/rails test test/models/books/saved_search_test.rb test/models/saved_search_test.rb`
Expected: PASS, including every pre-existing test.

- [ ] **Step 6: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass, with **8 more runs** than after Task 2, and zero failures. No pre-existing test may change — this task rewrites `summary`'s internals, not its output.

- [ ] **Step 7: Commit**

```bash
git add app/models/saved_search.rb app/models/books/saved_search.rb \
        test/models/books/saved_search_test.rb
git commit -m "Read summary through the criteria object instead of the raw hash"
```

---

### Task 4: `Search::Books::Search::BookAdvanced`

**Files:**
- Create: `app/lib/search/books/search/book_advanced.rb`
- Create: `test/lib/search/books/search/book_advanced_test.rb`

**Interfaces:**
- Consumes: `Books::SavedSearchCriteria` (Task 2), `Books::BookType.category_id` (Task 1), `Search::Base::Search` (`search`, `extract_ids`), `Search::Shared::Utils.build_bool_query`, `Search::Books::BookIndex`.
- Produces: `Search::Books::Search::BookAdvanced.call(criteria, page:, per_page:, excluded_book_ids:) => {ids: [Integer], total: Integer}` and `.build_query_definition(...) => Hash`. Task 5 calls `.call`.

**This class owns every filter.** `max_ranked_position` and `hide_read` are here, not in Postgres, because OpenSearch sizes the page: a filter applied afterwards removes rows from a page already counted, giving short pages under an overstated total.

**It does no database work.** `hide_read`'s book ids arrive as the `excluded_book_ids:` argument; Task 5 looks them up. That keeps this class a pure criteria→query function, matching every other search class in the app.

**Paging and sorting** follow spec §5.4: sort by `ranked_position` asc (missing last), then `first_published_year` asc (missing last), then `title.keyword`. `track_total_hits` is left at OpenSearch's default of 10,000 — `from + size` cannot exceed `index.max_result_window` (also 10,000), so result 10,001 is unreachable and counting past it buys pagination nothing.

**`max_ranked_position` implies ranked-only** by construction — unranked books have no `ranked_position`, so the range filter excludes them. Combined with `ranked: :unranked` it is self-contradictory and returns nothing. Both are correct.

- [ ] **Step 1: Write the failing test**

Create `test/lib/search/books/search/book_advanced_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookAdvancedTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def criteria(hash)
          ::Books::SavedSearchCriteria.new(hash)
        end

        # Indexes a document directly so a test controls every field, rather
        # than depending on a fixture book's associations.
        def index_book(id, attrs = {})
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name,
            id: id,
            body: {
              title: "Book #{id}",
              category_ids: [],
              original_language_id: nil,
              country_ids: [],
              book_length: nil,
              first_published_year: nil,
              ranked: false,
              ranked_position: nil
            }.merge(attrs),
            refresh: true
          )
        end

        def ids_for(hash, **options)
          ::Search::Books::Search::BookAdvanced.call(criteria(hash), **options)[:ids]
        end

        test "returns every book when the criteria carry no filters" do
          index_book(1)
          index_book(2)

          result = ::Search::Books::Search::BookAdvanced.call(criteria({"genre_match_mode" => "any"}))

          assert_equal [1, 2], result[:ids].sort
          assert_equal 2, result[:total]
        end

        test "filters included categories in any mode" do
          index_book(1, category_ids: [10])
          index_book(2, category_ids: [20])

          assert_equal [1], ids_for({"included_category_ids" => ["10"]})
        end

        test "requires every category in all mode" do
          index_book(1, category_ids: [10, 20])
          index_book(2, category_ids: [10])

          assert_equal [1], ids_for({"included_category_ids" => ["10", "20"], "genre_match_mode" => "all"})
        end

        test "excludes categories" do
          index_book(1, category_ids: [10])
          index_book(2, category_ids: [20])

          assert_equal [2], ids_for({"excluded_category_ids" => ["10"]})
        end

        test "filters and excludes languages" do
          index_book(1, original_language_id: 5)
          index_book(2, original_language_id: 6)

          assert_equal [1], ids_for({"included_language_ids" => ["5"]})
          assert_equal [2], ids_for({"excluded_language_ids" => ["5"]})
        end

        test "filters and excludes countries" do
          index_book(1, country_ids: [7])
          index_book(2, country_ids: [8])

          assert_equal [1], ids_for({"included_country_ids" => ["7"]})
          assert_equal [2], ids_for({"excluded_country_ids" => ["7"]})
        end

        test "filters book_length" do
          index_book(1, book_length: 1)
          index_book(2, book_length: 4)

          assert_equal [1], ids_for({"book_length" => [1]})
        end

        test "filters a publication year range on either bound" do
          index_book(1, first_published_year: 1975)
          index_book(2, first_published_year: 1985)
          index_book(3, first_published_year: 1995)

          assert_equal [2, 3], ids_for({"first_year_published_gt" => "1980"}).sort
          assert_equal [1, 2], ids_for({"first_year_published_lt" => "1990"}).sort
          assert_equal [2], ids_for({"first_year_published_gt" => "1980", "first_year_published_lt" => "1990"})
        end

        test "resolves book_type to a category id" do
          category = ::Books::Category.create!(name: "Advanced Fiction Genre", category_type: :genre)
          LegacyIdMap.record(model: "Books::Category", legacy_id: 40348, new_id: category.id)
          ::Books::BookType.reset_category_ids!
          index_book(1, category_ids: [category.id])
          index_book(2, category_ids: [999])

          assert_equal [1], ids_for({"book_type" => 0})
        ensure
          ::Books::BookType.reset_category_ids!
        end

        test "ranked true keeps only books carrying a ranked_position" do
          index_book(1, ranked_position: 5)
          index_book(2, ranked_position: nil)

          assert_equal [1], ids_for({"ranked" => "true"})
        end

        test "ranked false keeps only books without a ranked_position" do
          index_book(1, ranked_position: 5)
          index_book(2, ranked_position: nil)

          assert_equal [2], ids_for({"ranked" => "false"})
        end

        test "an absent ranked criterion keeps both" do
          index_book(1, ranked_position: 5)
          index_book(2, ranked_position: nil)

          assert_equal [1, 2], ids_for({}).sort
        end

        test "max_ranked_position bounds the rank and excludes unranked books" do
          index_book(1, ranked_position: 50)
          index_book(2, ranked_position: 150)
          index_book(3, ranked_position: nil)

          assert_equal [1], ids_for({"max_ranked_position" => 100})
        end

        test "max_ranked_position with ranked false returns nothing" do
          index_book(1, ranked_position: 50)

          assert_equal [], ids_for({"max_ranked_position" => 100, "ranked" => "false"})
        end

        # Spec §6: unknown ids match nothing rather than 404. A saved search is
        # private user data, not an indexable URL space -- the opposite of the
        # public-filters spec's choice, and deliberately so.
        test "an unknown category id matches nothing rather than raising" do
          index_book(1, category_ids: [10])

          result = ::Search::Books::Search::BookAdvanced.call(criteria({"included_category_ids" => ["999999"]}))

          assert_equal [], result[:ids]
          assert_equal 0, result[:total]
        end

        test "excluded_book_ids removes those books" do
          index_book(1)
          index_book(2)

          assert_equal [2], ids_for({}, excluded_book_ids: [1])
        end

        test "an empty excluded_book_ids excludes nothing" do
          index_book(1)

          assert_equal [1], ids_for({}, excluded_book_ids: [])
        end

        test "sorts ranked books first by position, then unranked by year" do
          index_book(1, ranked_position: 200, first_published_year: 1900)
          index_book(2, ranked_position: 10, first_published_year: 2000)
          index_book(3, ranked_position: nil, first_published_year: 1950)

          assert_equal [2, 1, 3], ids_for({})
        end

        test "pages through results" do
          index_book(1, ranked_position: 1)
          index_book(2, ranked_position: 2)
          index_book(3, ranked_position: 3)

          assert_equal [1, 2], ids_for({}, page: 1, per_page: 2)
          assert_equal [3], ids_for({}, page: 2, per_page: 2)
        end

        test "total counts every match, not just the page" do
          index_book(1, ranked_position: 1)
          index_book(2, ranked_position: 2)
          index_book(3, ranked_position: 3)

          result = ::Search::Books::Search::BookAdvanced.call(criteria({}), page: 1, per_page: 2)

          assert_equal 2, result[:ids].size
          assert_equal 3, result[:total]
        end

        # The `all` mode is the one clause whose SHAPE matters rather than its
        # effect: it must build one term filter per id, not a single terms.
        test "all mode builds one term filter per category id" do
          definition = ::Search::Books::Search::BookAdvanced.build_query_definition(
            criteria({"included_category_ids" => ["10", "20"], "genre_match_mode" => "all"})
          )
          filters = definition[:query][:bool][:filter]

          assert_includes filters, {term: {category_ids: 10}}
          assert_includes filters, {term: {category_ids: 20}}
        end

        private

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/search/books/search/book_advanced_test.rb`
Expected: FAIL — `NameError: uninitialized constant Search::Books::Search::BookAdvanced`

- [ ] **Step 3: Write the search class**

Create `app/lib/search/books/search/book_advanced.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      # A saved search's criteria as an OpenSearch bool query, returning one
      # page of book ids and the total match count.
      #
      # This class owns EVERY filter, including max_ranked_position and
      # hide_read. OpenSearch sizes the page here, so a filter applied
      # downstream in Postgres would remove rows from a page already counted --
      # short pages under an overstated total.
      #
      # It does no database work: hide_read's ids arrive as excluded_book_ids,
      # looked up by ::Books::SavedSearchQuery.
      class BookAdvanced < ::Search::Base::Search
        # Ranked books first in rank order, then unranked. Mirrors the SQL
        # ordering ::Books::AuthorsController#all_books_relation already ships.
        SORT = [
          {ranked_position: {order: "asc", missing: "_last"}},
          {first_published_year: {order: "asc", missing: "_last"}},
          {"title.keyword" => {order: "asc"}}
        ].freeze

        DEFAULT_PER_PAGE = 50

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(criteria, page: 1, per_page: DEFAULT_PER_PAGE, excluded_book_ids: [])
          definition = build_query_definition(
            criteria, page: page, per_page: per_page, excluded_book_ids: excluded_book_ids
          )
          response = search(definition)

          {
            ids: extract_ids(response).map(&:to_i),
            total: response["hits"]["total"]["value"]
          }
        end

        def self.build_query_definition(criteria, page: 1, per_page: DEFAULT_PER_PAGE, excluded_book_ids: [])
          {
            query: ::Search::Shared::Utils.build_bool_query(
              filter: filter_clauses(criteria),
              must_not: must_not_clauses(criteria, excluded_book_ids)
            ),
            sort: SORT,
            from: (page - 1) * per_page,
            size: per_page
          }
        end

        def self.filter_clauses(criteria)
          clauses = []
          clauses.concat(category_clauses(criteria))

          book_type_category_id = ::Books::BookType.category_id(criteria.book_type)
          clauses << {term: {category_ids: book_type_category_id}} if book_type_category_id

          languages = criteria.included_language_ids
          clauses << {terms: {original_language_id: languages}} if languages.any?

          countries = criteria.included_country_ids
          clauses << {terms: {country_ids: countries}} if countries.any?

          lengths = criteria.book_length
          clauses << {terms: {book_length: lengths}} if lengths.any?

          year = year_range(criteria)
          clauses << {range: {first_published_year: year}} if year.any?

          clauses << {exists: {field: "ranked_position"}} if criteria.ranked == :ranked

          max_position = criteria.max_ranked_position
          clauses << {range: {ranked_position: {lte: max_position}}} if max_position

          clauses
        end

        # `all` means a book must carry every category, which one terms clause
        # cannot express -- terms is an OR. One term filter per id is the AND.
        def self.category_clauses(criteria)
          ids = criteria.included_category_ids
          return [] if ids.empty?
          return [{terms: {category_ids: ids}}] if criteria.genre_match_mode == :any

          ids.map { |id| {term: {category_ids: id}} }
        end

        def self.year_range(criteria)
          range = {}
          gt = criteria.first_year_published_gt
          lt = criteria.first_year_published_lt
          range[:gte] = gt if gt
          range[:lte] = lt if lt
          range
        end

        def self.must_not_clauses(criteria, excluded_book_ids)
          clauses = []

          categories = criteria.excluded_category_ids
          clauses << {terms: {category_ids: categories}} if categories.any?

          languages = criteria.excluded_language_ids
          clauses << {terms: {original_language_id: languages}} if languages.any?

          countries = criteria.excluded_country_ids
          clauses << {terms: {country_ids: countries}} if countries.any?

          clauses << {exists: {field: "ranked_position"}} if criteria.ranked == :unranked

          clauses << {ids: {values: excluded_book_ids}} if excluded_book_ids.any?

          clauses
        end

        private_class_method :filter_clauses, :category_clauses, :year_range, :must_not_clauses
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/search/books/search/book_advanced_test.rb`
Expected: PASS

If the category/language/country term filters return nothing, that is the mapping mismatch these tests exist to catch: those fields are `keyword` in `BookIndex`, and the documents are indexed with integer values. Report it rather than casting blindly — the fix belongs wherever the mismatch actually is.

- [ ] **Step 5: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass, with **21 more runs** than after Task 3, and zero failures.

- [ ] **Step 6: Commit**

```bash
git add app/lib/search/books/search/book_advanced.rb \
        test/lib/search/books/search/book_advanced_test.rb
git commit -m "Add BookAdvanced, the saved-search OpenSearch query"
```

---

### Task 5: `Books::SavedSearchQuery`

**Files:**
- Create: `app/lib/books/saved_search_query.rb`
- Create: `test/lib/books/saved_search_query_test.rb`

**Interfaces:**
- Consumes: `Books::SavedSearchCriteria` (Task 2), `Search::Books::Search::BookAdvanced` (Task 4), `Books::RankingConfiguration.default_primary`, `Books::UserList`, `SavedSearch.excluded_list_type` (increment 3).
- Produces: `Books::SavedSearchQuery.call(criteria:, owner:, ranking_configuration: nil, page: 1, per_page: 50) => Result(books:, total:)`. Increment 5's controller calls this.

**Its only jobs** are resolving the read list, calling the search, hydrating one page, and re-applying the order. It applies **no filter of its own** — see Task 4.

**`hide_read` uses the search's owner, not the viewer.** Legacy passes `@search.user` as `current_user`, so a public search with `hide_read` hides books *its owner* has read. That keeps results stable for the owner, which is the point of a saved search.

**Ordering is re-applied in Ruby.** Postgres cannot reproduce OpenSearch's ranked-then-unranked interleaving from an `IN` clause, so the query returns an **array**, not a relation.

**The ranking configuration is a parameter but only the default primary works.** The index carries only the default primary's `ranked_position`, so any other configuration would silently return the wrong ranks. It raises instead. Increment 5+ can build the real path without changing this signature.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/saved_search_query_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class SavedSearchQueryTest < ActiveSupport::TestCase
    def criteria(hash = {})
      ::Books::SavedSearchCriteria.new(hash)
    end

    def stub_search(ids:, total: nil)
      ::Search::Books::Search::BookAdvanced
        .stubs(:call)
        .returns({ids: ids, total: total || ids.size})
    end

    # Verified 2026-08-09: these are real fixture labels, `books_global` is the
    # default primary (global: true, primary: true), and ranked_items.yml
    # contains NO books rows -- only movies/music/games -- so creating one here
    # cannot collide with index_ranked_items_on_item_and_ranking_config_unique.
    setup do
      @owner = users(:regular_user)
      @rc = ::Books::RankingConfiguration.default_primary
      @book_a = books_books(:war_and_peace)
      @book_b = books_books(:crime_and_punishment)
    end

    test "hydrates the ids the search returned" do
      stub_search(ids: [@book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [@book_a.id], result.books.map(&:id)
      assert_equal 1, result.total
    end

    test "preserves the order OpenSearch returned rather than the database's" do
      stub_search(ids: [@book_b.id, @book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [@book_b.id, @book_a.id], result.books.map(&:id)
    end

    test "returns the total even when it exceeds the page" do
      stub_search(ids: [@book_a.id], total: 4391)

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal 4391, result.total
    end

    test "returns no books when the search matched nothing" do
      stub_search(ids: [], total: 0)

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [], result.books
      assert_equal 0, result.total
    end

    test "drops an id with no matching book rather than raising" do
      stub_search(ids: [@book_a.id, 999_999_999], total: 2)

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [@book_a.id], result.books.map(&:id)
    end

    test "carries ranked_position from the ranking configuration" do
      RankedItem.create!(
        item: @book_a, ranking_configuration: @rc, rank: 7, score: 99.0
      )
      stub_search(ids: [@book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal 7, result.books.first.ranked_position.to_i
    end

    test "leaves ranked_position nil for an unranked book" do
      stub_search(ids: [@book_b.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_nil result.books.first.ranked_position
    end

    test "passes the owner's read books to the search when hide_read is set" do
      list = ::Books::UserList.create!(user: @owner, name: "Read", list_type: :read)
      list.user_list_items.create!(listable: @book_a, position: 1)

      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:excluded_book_ids] == [@book_a.id] }
        .returns({ids: [@book_b.id], total: 1})

      ::Books::SavedSearchQuery.call(criteria: criteria({"hide_read" => true}), owner: @owner)
    end

    test "passes no exclusions when hide_read is not set" do
      list = ::Books::UserList.create!(user: @owner, name: "Read", list_type: :read)
      list.user_list_items.create!(listable: @book_a, position: 1)

      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:excluded_book_ids] == [] }
        .returns({ids: [], total: 0})

      ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)
    end

    test "passes no exclusions when hide_read is set but there is no owner" do
      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:excluded_book_ids] == [] }
        .returns({ids: [], total: 0})

      ::Books::SavedSearchQuery.call(criteria: criteria({"hide_read" => true}), owner: nil)
    end

    test "forwards paging to the search" do
      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:page] == 3 && options[:per_page] == 25 }
        .returns({ids: [], total: 0})

      ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner, page: 3, per_page: 25)
    end

    test "defaults to the default primary ranking configuration" do
      stub_search(ids: [])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal 0, result.total
    end

    test "raises for a ranking configuration other than the default primary" do
      other = ranking_configurations(:books_user)
      stub_search(ids: [])

      error = assert_raises(ArgumentError) do
        ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner, ranking_configuration: other)
      end

      assert_match(/default primary/i, error.message)
    end

    test "preloads authors so a caller rendering a grid does not N+1" do
      stub_search(ids: [@book_a.id, @book_b.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_queries_count(0) do
        result.books.each { |book| book.book_authors.map(&:author) }
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/books/saved_search_query_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::SavedSearchQuery`

- [ ] **Step 3: Write the query object**

Create `app/lib/books/saved_search_query.rb`:

```ruby
# frozen_string_literal: true

module Books
  # Executes a saved search: resolves the owner's read list, runs the
  # OpenSearch query, hydrates one page from Postgres, and re-applies the
  # order OpenSearch returned.
  #
  # It applies NO filter of its own. OpenSearch sizes the page, so a filter
  # here would remove rows from a page already counted -- short pages under an
  # overstated total. Every criterion lives in BookAdvanced.
  #
  # Returns an array rather than a relation because Postgres cannot reproduce
  # the ranked-then-unranked interleaving from an IN clause.
  class SavedSearchQuery
    Result = Struct.new(:books, :total, keyword_init: true)

    def self.call(criteria:, owner:, ranking_configuration: nil, page: 1, per_page: 50)
      rc = ranking_configuration || ::Books::RankingConfiguration.default_primary
      ensure_default_primary!(rc)

      response = ::Search::Books::Search::BookAdvanced.call(
        criteria,
        page: page,
        per_page: per_page,
        excluded_book_ids: criteria.hide_read ? read_book_ids(owner) : []
      )

      Result.new(books: hydrate(response[:ids], rc), total: response[:total])
    end

    # The index carries only the default primary's ranked_position, so any
    # other configuration would return ranks that silently do not belong to it.
    # The parameter exists so a later increment can build that path without
    # changing this signature.
    def self.ensure_default_primary!(rc)
      default = ::Books::RankingConfiguration.default_primary
      return if default && rc && rc.id == default.id

      raise ArgumentError,
        "SavedSearchQuery supports only the default primary ranking configuration " \
        "(got #{rc&.id.inspect}, default is #{default&.id.inspect})"
    end

    # hide_read excludes what the search's OWNER has read, not the viewer --
    # legacy passes @search.user as current_user, which keeps a public search's
    # results stable for the person who saved it.
    def self.read_book_ids(owner)
      return [] if owner.nil?

      ::Books::UserList
        .where(user_id: owner.id, list_type: ::Books::SavedSearch.excluded_list_type)
        .joins(:user_list_items)
        .where(user_list_items: {listable_type: "Books::Book"})
        .pluck("user_list_items.listable_id")
    end

    def self.hydrate(ids, rc)
      return [] if ids.empty?

      books = ::Books::Book
        .where(id: ids)
        .select("books_books.*, ranked_items.rank AS ranked_position")
        .joins(
          "LEFT OUTER JOIN ranked_items ON ranked_items.item_id = books_books.id " \
          "AND ranked_items.item_type = 'Books::Book' " \
          "AND ranked_items.ranking_configuration_id = #{rc.id.to_i}"
        )
        .preload(book_authors: :author, primary_image: {file_attachment: :blob})
        .index_by(&:id)

      ids.filter_map { |id| books[id] }
    end

    private_class_method :ensure_default_primary!, :read_book_ids, :hydrate
  end
end
```

`preload` rather than `includes`: `includes` may decide to `eager_load`, which builds its own SELECT and would drop the `ranked_position` alias. `preload` always issues separate queries and leaves the custom select intact.

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/books/saved_search_query_test.rb`
Expected: PASS

- [ ] **Step 5: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass, with **14 more runs** than after Task 4, and zero failures.

- [ ] **Step 6: Commit**

```bash
git add app/lib/books/saved_search_query.rb test/lib/books/saved_search_query_test.rb
git commit -m "Add Books::SavedSearchQuery to execute a saved search"
```

---

## Done When

- [ ] `bin/rails test` passes with zero failures; `bundle exec standardrb` reports no offenses.
- [ ] `Books::BookType` is the only place the four `book_type` values are defined; `BOOK_TYPE_LABELS` is gone and the migrator's constant is an alias.
- [ ] `Books::SavedSearchCriteria` reads every criterion in **both** storage shapes, with `ranked` as a tri-state.
- [ ] `Books::SavedSearch#summary` reads through `criteria_object`, and a `book_type` of `"0"` renders "Fiction".
- [ ] `BookAdvanced` covers every clause in spec §6's table, including `max_ranked_position` and `hide_read`, verified against a real index.
- [ ] `Books::SavedSearchQuery` returns a page in OpenSearch's order with `ranked_position` populated, and raises for a non-default ranking configuration.
- [ ] Nothing in the increment writes to the database.

**Not in this increment** (spec §12): routes, controller, views, the `last_executed_at` write, and anything user-facing. The feature turns on at increment 5.

## Landmines

- **No criterion may be applied in Postgres.** OpenSearch sizes the page; a filter applied downstream removes rows from a page already counted, giving short pages under an overstated total. This is why `max_ranked_position` and `hide_read` are in `BookAdvanced`.
- **`ranked` is a tri-state and nil is not false.** Absent means the whole corpus; `:unranked` means unranked only. A boolean collapses them and changes what 437 stored searches return.
- **`"abc".to_i` is `0`, a valid `book_type` and `book_length`.** Parse with `Integer(value, exception: false)`.
- **Criteria arrive in two storage shapes** — migrated rows store `book_type` as Integer and `ranked` as String; form params are all strings. Anything reading `criteria[...]` directly breaks on one of them.
- **`includes` can become `eager_load` and drop a custom `select` alias.** Use `preload` when the relation carries `ranked_position`.
- **Inside `module Search`, a bare `Books::X` resolves to `Search::Books::X`.** Root-anchor everything.
- **`Books::BookType.category_ids` is memoized per process**, so a test creating a `LegacyIdMap` row after first call sees a stale map. Call `reset_category_ids!` in setup and teardown.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** Read fixture YAML directly; never run it against development.
- **`bin/dev` needs a TTY** and self-terminates in a backgrounded agent shell. Not needed for this increment — there is nothing to look at — but do not reach for it.
