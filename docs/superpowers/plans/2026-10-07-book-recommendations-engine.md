# Book Recommendations Engine Implementation Plan (increments 1–2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the preferences store, the legacy config migration, and the recommendation engine (taste-profile signal, fusion, re-ranking, explanations) with a read-only evaluation harness — no pages yet.

**Architecture:** Generic pipeline in `app/lib/recommendations/` (engine, profile builder, signals, fusion, re-ranker passes, explainer) that never names a domain; a books adapter in `app/lib/recommendations/books/` supplies interactions, category facts, item facts, and the one OpenSearch query. Preferences live in a new `recommendation_configs` STI table whose JSON criteria reuse the saved-search criteria readers and clause builders. Every knob sits in `config/initializers/recommendations.rb` and is overridable per call.

**Tech Stack:** Rails 8, Minitest + Mocha, OpenSearch 2.x via `opensearch-ruby` (`Search::Shared::Client.instance`), Postgres, rake.

**Spec:** `docs/superpowers/specs/2026-10-07-book-recommendations-design.md` (§4–§9, §11 increments 1–2). Increments 3–4 (pages, wizard, gating UI) are a second plan, written after the §9.2 gate passes.

## Global Constraints

- Run every Rails command from `web-app/` inside the worktree `.claude/worktrees/recommendations`.
- Use generators for models (`bin/rails generate model ...`); never hand-create model files. Jobs are not needed in this plan.
- Namespacing: generic code is `Recommendations::*`; books code is `Recommendations::Books::*` and `Search::Books::Search::BookRecommendations`. Inside any `Books`-containing namespace write `::Books::Book`, `::Books::Category`, `::Books::UserList` (root-anchored) — a bare `Books::` resolves to the wrong module.
- Rails 8 enum syntax (`enum :status, {...}`). Result pattern `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- The criteria JSON uses the saved-search key names verbatim: `included_category_ids`, `excluded_category_ids`, `genre_match_mode` ("any"/"all"), `book_length` (array of enum ints), `first_year_published_gt`, `first_year_published_lt`, `max_ranked_position`. (Spec §4 already uses these names so `BookAdvanced`'s clause builders reuse unchanged.)
- Candidate pool is `ranked: true` and non-provisional (`Search::Books::BookIndex::EXCLUDE_PROVISIONAL` in `must_not`).
- Fiction/Nonfiction are resolved **by name** (`::Books::Book::BOOK_TYPE_CATEGORY_NAMES`), never hardcoded ids, and never scored.
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`. No `require "sidekiq/testing"`.
- A clean `bin/rails test` emits no new warnings. `bundle exec standardrb` must pass. After creating `app/lib/recommendations/`, run `CI=1 bin/rails zeitwerk:check`.
- Tests never open the legacy database: migrator tests stub `legacy_each`.
- OpenSearch tests create and delete the books index in `setup`/`teardown` as `test/lib/search/books/search/book_similar_test.rb` does, and index synthetic documents directly.
- Commit after every task with the attribution line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. **A user with only want-to-read books** (no favorites, no read, no ratings): the profile is empty. Expected: the engine still returns a page — the rank-only fallback signal, with reasons of type `:ranked` — not an empty result. Pinned in Task 10 ("falls back to rank-only when the profile is empty").
2. **A criteria JSON written by hand with an unparseable value** (`max_ranked_position: "abc"`): expected to match nothing rather than silently broaden to the whole corpus, exactly as saved searches do. Pinned in Task 7 ("an unparseable criterion matches nothing").
3. **A book on the user's want-to-read list that is also a strong candidate**: expected to be excluded from results (it is shelved), while still contributing its +0.2 to the profile. Pinned in Task 5 (adapter: `shelved_item_ids` includes want-to-read) and Task 10 (engine passes `excluded_ids` to every signal).
4. **A series book whose predecessor the user has only on want-to-read**: expected to be dropped by the series rule (only favorites/read/reading unlock a sequel). Pinned in Task 9.
5. **OpenSearch down**: expected: the engine logs and returns an empty successful result with `signals_used: []`, never raises. Pinned in Task 10 ("a signal that raises is dropped, not fatal").

## File structure

```
web-app/
  db/migrate/<ts>_create_recommendation_configs.rb        (Task 1, generated)
  app/models/recommendation_config.rb                      (Task 1, generated) STI base + DOMAIN_SUBCLASSES
  app/models/books/recommendation_config.rb                (Task 1, generated --parent) criteria_class
  app/lib/books/recommendation_criteria.rb                 (Task 2) typed readers; wraps SavedSearchCriteria
  app/lib/books/recommendation_criteria_params.rb          (Task 2) form params -> stored hash
  app/lib/search/books/search/criteria_clauses.rb          (Task 3) filter/must_not builders extracted from BookAdvanced
  app/models/legacy_books/recommendation_config.rb         (Task 4) read-only legacy model
  app/lib/services/books_migration/recommendation_config_migrator.rb (Task 4)
  lib/tasks/data_migration.rake                            (Task 4, modify) new task + in :all
  config/initializers/recommendations.rb                   (Task 5) knobs
  app/lib/recommendations/interaction.rb                   (Task 5) value structs: Interaction, CategoryFact, ItemFact, Candidate, Reason
  app/lib/recommendations/registry.rb                      (Task 5)
  app/lib/recommendations/books/adapter.rb                 (Task 5) interactions, shelved ids, facts, catalog size, type ids
  app/lib/recommendations/profile.rb                       (Task 6) Profile struct
  app/lib/recommendations/profile_builder.rb               (Task 6) lift math
  app/lib/search/books/search/book_recommendations.rb      (Task 7) the OpenSearch query
  app/lib/recommendations/signals/taste_profile.rb         (Task 8)
  app/lib/recommendations/signals/rank_only.rb             (Task 8)
  app/lib/recommendations/signals/collaborative.rb         (Task 8) stub: available? false
  app/lib/recommendations/fusion.rb                        (Task 8)
  app/lib/recommendations/reranker/author_cap.rb           (Task 9)
  app/lib/recommendations/reranker/series_rule.rb          (Task 9)
  app/lib/recommendations/reranker/genre_calibration.rb    (Task 9)
  app/lib/recommendations/explainer.rb                     (Task 10)
  app/lib/recommendations/engine.rb                        (Task 10)
  lib/tasks/recommendations.rake                           (Task 11) show + eval
  docs/features/recommendations.md                         (Task 12)
  docs/launch-todo.md                                      (Task 4, modify)
```

---

### Task 1: `recommendation_configs` table and STI models

**Files:**
- Create (generated): `db/migrate/<ts>_create_recommendation_configs.rb`, `app/models/recommendation_config.rb`, `app/models/books/recommendation_config.rb`, `test/models/recommendation_config_test.rb`, `test/models/books/recommendation_config_test.rb`, `test/fixtures/recommendation_configs.yml`
- Modify: `app/models/user.rb:52` (add `has_many :recommendation_configs, dependent: :destroy` after `has_many :saved_searches`)

**Interfaces:**
- Produces: `RecommendationConfig` (columns `user_id`, `type`, `criteria` jsonb default `{}`), `RecommendationConfig::DOMAIN_SUBCLASSES`, `RecommendationConfig.subclass_for(domain)`, `RecommendationConfig#criteria_object`, `Books::RecommendationConfig.criteria_class` → `Books::RecommendationCriteria` (Task 2), `Books::RecommendationConfig.for_user(user)` (find or initialize).

- [ ] **Step 1: Generate the base model and migration**

```bash
bin/rails generate model RecommendationConfig user:references type:string criteria:jsonb
bin/rails generate model Books::RecommendationConfig --parent=RecommendationConfig
```

The second generator creates no migration (`--parent`). Delete the empty fixture it may create at `test/fixtures/books/recommendation_configs.yml` if present; keep `test/fixtures/recommendation_configs.yml` and replace its contents with:

```yaml
# Semantic names, as users.yml. One row per (user, type).
regular_user_books:
  user: regular_user
  type: Books::RecommendationConfig
  criteria: {"max_ranked_position": 500, "book_length": [1, 2]}
```

- [ ] **Step 2: Edit the migration**

```ruby
class CreateRecommendationConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :recommendation_configs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :type, null: false
      t.jsonb :criteria, null: false, default: {}
      t.timestamps
    end
    add_index :recommendation_configs, [:user_id, :type], unique: true
  end
end
```

Run `bin/rails db:migrate` (development) then `bin/rails db:test:prepare`.

- [ ] **Step 3: Write the failing model tests**

`test/models/recommendation_config_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class RecommendationConfigTest < ActiveSupport::TestCase
  test "subclass_for resolves books and nothing else" do
    assert_equal ::Books::RecommendationConfig, RecommendationConfig.subclass_for("books")
    assert_equal ::Books::RecommendationConfig, RecommendationConfig.subclass_for(:books)
    assert_nil RecommendationConfig.subclass_for("music")
  end

  test "one config per user per type" do
    existing = recommendation_configs(:regular_user_books)
    dup = ::Books::RecommendationConfig.new(user: existing.user, criteria: {})
    assert_not dup.valid?
    assert_includes dup.errors[:user_id], "has already been taken"
  end

  test "criteria_object is typed and resets when criteria is reassigned" do
    config = recommendation_configs(:regular_user_books)
    assert_equal 500, config.criteria_object.max_ranked_position
    config.criteria = {"max_ranked_position" => "40"}
    assert_equal 40, config.criteria_object.max_ranked_position
  end

  test "destroying a user destroys its configs" do
    user = recommendation_configs(:regular_user_books).user
    assert_difference("RecommendationConfig.count", -1) { user.destroy! }
  end
end
```

`test/models/books/recommendation_config_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class RecommendationConfigTest < ActiveSupport::TestCase
    test "for_user returns the existing row" do
      existing = recommendation_configs(:regular_user_books)
      assert_equal existing, ::Books::RecommendationConfig.for_user(existing.user)
    end

    test "for_user initializes an unsaved row with empty criteria when none exists" do
      config = ::Books::RecommendationConfig.for_user(users(:editor_user))
      assert config.new_record?
      assert_equal({}, config.criteria)
      assert_equal [], config.criteria_object.excluded_category_ids
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/models/recommendation_config_test.rb test/models/books/recommendation_config_test.rb`
Expected: FAIL — `subclass_for` undefined, `for_user` undefined, `criteria_object` undefined.

- [ ] **Step 5: Implement the models**

`app/models/recommendation_config.rb` (replace the generated body; keep the annotate header the generator/annotaterb adds):

```ruby
# One row per user per domain: the preferences the recommendation engine applies
# as hard constraints (spec §4). STI mirrors SavedSearch: the host picks the
# subclass, the subclass names its criteria class.
class RecommendationConfig < ApplicationRecord
  belongs_to :user

  DOMAIN_SUBCLASSES = {"books" => "Books::RecommendationConfig"}.freeze

  def self.subclass_for(domain)
    DOMAIN_SUBCLASSES[domain.to_s]&.constantize
  end

  validates :user_id, uniqueness: {scope: :type}

  def self.criteria_class
    raise NotImplementedError, "#{name} must override .criteria_class"
  end

  # Find-or-initialize, never find-or-create: a GET must not write a row.
  def self.for_user(user)
    find_or_initialize_by(user: user)
  end

  def criteria_object
    @criteria_object ||= self.class.criteria_class.new(criteria)
  end

  def criteria=(value)
    @criteria_object = nil
    super
  end
end
```

`app/models/books/recommendation_config.rb`:

```ruby
module Books
  class RecommendationConfig < ::RecommendationConfig
    def self.criteria_class
      ::Books::RecommendationCriteria
    end
  end
end
```

Add to `app/models/user.rb` directly below `has_many :saved_searches, dependent: :destroy`:

```ruby
  has_many :recommendation_configs, dependent: :destroy
```

Task 2 supplies `Books::RecommendationCriteria`; until then the two `criteria_object` tests fail with `NameError`. Proceed to Task 2 before committing if you prefer green commits, or commit the model with those two tests pending — either is acceptable, but the commit at the end of Task 2 must be fully green.

- [ ] **Step 6: Spec wording**

Already applied in the planning commit: spec §4 lists the criteria keys with the saved-search names. Nothing to do; verify by reading the spec's §4 bullet.

- [ ] **Step 7: Commit (after Task 2 is green)**

```bash
git add db/migrate db/schema.rb app/models/recommendation_config.rb app/models/books/recommendation_config.rb app/models/user.rb test/models/recommendation_config_test.rb test/models/books/recommendation_config_test.rb test/fixtures/recommendation_configs.yml
git commit -m "Add recommendation_configs STI table and models"
```

---

### Task 2: `Books::RecommendationCriteria` and its params writer

**Files:**
- Create: `app/lib/books/recommendation_criteria.rb`, `app/lib/books/recommendation_criteria_params.rb`
- Test: `test/lib/books/recommendation_criteria_test.rb`, `test/lib/books/recommendation_criteria_params_test.rb`

**Interfaces:**
- Produces: `Books::RecommendationCriteria::KEYS`, `Books::RecommendationCriteria.new(raw_hash)` with readers `included_category_ids`, `excluded_category_ids`, `genre_match_mode` (`:any`/`:all`), `book_length`, `first_year_published_gt`, `first_year_published_lt`, `max_ranked_position`, `unparseable?(key)`, and `to_search_criteria` → a `Books::SavedSearchCriteria` whose `ranked` is `:ranked` and `hide_read` is false (consumed by Task 3's clause builders). `Books::RecommendationCriteriaParams.call(raw)` → stored hash containing only `KEYS`.

- [ ] **Step 1: Write the failing tests**

`test/lib/books/recommendation_criteria_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class RecommendationCriteriaTest < ActiveSupport::TestCase
    test "reads every stored key through the saved-search readers" do
      c = ::Books::RecommendationCriteria.new(
        "included_category_ids" => ["3", 4], "excluded_category_ids" => [9],
        "genre_match_mode" => "all", "book_length" => ["1", 7],
        "first_year_published_gt" => "1900", "first_year_published_lt" => 2000,
        "max_ranked_position" => "250"
      )
      assert_equal [3, 4], c.included_category_ids
      assert_equal [9], c.excluded_category_ids
      assert_equal :all, c.genre_match_mode
      assert_equal [1], c.book_length, "7 is not a book_length enum value and must be dropped"
      assert_equal 1900, c.first_year_published_gt
      assert_equal 2000, c.first_year_published_lt
      assert_equal 250, c.max_ranked_position
    end

    test "defaults when raw is nil or empty" do
      c = ::Books::RecommendationCriteria.new(nil)
      assert_equal [], c.included_category_ids
      assert_equal :any, c.genre_match_mode
      assert_nil c.max_ranked_position
    end

    test "ignores keys outside KEYS even if stored" do
      c = ::Books::RecommendationCriteria.new("hide_read" => true, "ranked" => "false", "included_language_ids" => [1])
      search = c.to_search_criteria
      assert_equal :ranked, search.ranked, "the candidate pool is always ranked"
      assert_equal false, search.hide_read
      assert_equal [], search.included_language_ids
    end

    test "unparseable? mirrors the saved-search rule" do
      c = ::Books::RecommendationCriteria.new("max_ranked_position" => "abc", "excluded_category_ids" => ["x"])
      assert c.unparseable?("max_ranked_position")
      assert c.unparseable?("excluded_category_ids")
      assert_not ::Books::RecommendationCriteria.new({}).unparseable?("max_ranked_position")
    end
  end
end
```

`test/lib/books/recommendation_criteria_params_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class RecommendationCriteriaParamsTest < ActiveSupport::TestCase
    test "stores only the recommendation keys, normalized" do
      out = ::Books::RecommendationCriteriaParams.call(
        "included_category_ids" => ["3", "", "3"], "excluded_category_ids" => ["9"],
        "genre_match_mode" => "all", "book_length" => ["1", "9"],
        "first_year_published_gt" => "1900", "max_ranked_position" => "250",
        "hide_read" => "1", "ranked" => "false", "included_language_ids" => ["2"]
      )
      assert_equal(
        {"included_category_ids" => [3], "excluded_category_ids" => [9], "genre_match_mode" => "all",
         "book_length" => [1], "first_year_published_gt" => 1900, "max_ranked_position" => 250},
        out
      )
    end

    test "accepts permitted ActionController::Parameters" do
      params = ActionController::Parameters.new(max_ranked_position: "10").permit(:max_ranked_position)
      assert_equal({"max_ranked_position" => 10}, ::Books::RecommendationCriteriaParams.call(params))
    end

    test "blank input stores an empty hash" do
      assert_equal({}, ::Books::RecommendationCriteriaParams.call(nil))
      assert_equal({}, ::Books::RecommendationCriteriaParams.call({"max_ranked_position" => ""}))
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/books/recommendation_criteria_test.rb test/lib/books/recommendation_criteria_params_test.rb`
Expected: FAIL with `NameError: uninitialized constant Books::RecommendationCriteria`.

- [ ] **Step 3: Implement**

`app/lib/books/recommendation_criteria.rb`:

```ruby
# frozen_string_literal: true

module Books
  # Typed readers over a RecommendationConfig's criteria hash. The stored keys are
  # a strict subset of SavedSearchCriteria's, with the same names, so the readers
  # and the OpenSearch clause builders are reused rather than copied: this class
  # composes a SavedSearchCriteria over the permitted keys and pins `ranked` to
  # "true" (the candidate pool is ranked books only, spec §7) and hide_read off
  # (the engine excludes every shelved book itself, spec §5).
  class RecommendationCriteria
    KEYS = %w[
      included_category_ids excluded_category_ids genre_match_mode book_length
      first_year_published_gt first_year_published_lt max_ranked_position
    ].freeze

    READERS = %i[
      included_category_ids excluded_category_ids genre_match_mode book_length
      first_year_published_gt first_year_published_lt max_ranked_position
    ].freeze

    def initialize(raw)
      stored = (raw || {}).to_h.stringify_keys.slice(*KEYS)
      @search = ::Books::SavedSearchCriteria.new(stored.merge("ranked" => "true"))
    end

    READERS.each do |reader|
      define_method(reader) { @search.public_send(reader) }
    end

    def unparseable?(key)
      @search.unparseable?(key)
    end

    # The object the clause builders (Search::Books::Search::CriteriaClauses) take.
    def to_search_criteria
      @search
    end
  end
end
```

`app/lib/books/recommendation_criteria_params.rb`:

```ruby
# frozen_string_literal: true

module Books
  # Form params -> the criteria hash RecommendationConfig stores. Delegates the
  # normalization to SavedSearchCriteriaParams and keeps only the recommendation
  # keys, so `ranked`/`hide_read`/language/country never enter the column.
  class RecommendationCriteriaParams
    def self.call(raw)
      ::Books::SavedSearchCriteriaParams.call(raw).slice(*::Books::RecommendationCriteria::KEYS)
    end
  end
end
```

- [ ] **Step 4: Run the tests (Task 1's too) to verify they pass**

Run: `bin/rails test test/lib/books/recommendation_criteria_test.rb test/lib/books/recommendation_criteria_params_test.rb test/models/recommendation_config_test.rb test/models/books/recommendation_config_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/books/recommendation_criteria.rb app/lib/books/recommendation_criteria_params.rb test/lib/books/recommendation_criteria_test.rb test/lib/books/recommendation_criteria_params_test.rb
git commit -m "Add Books::RecommendationCriteria readers and params writer"
```

---

### Task 3: Extract `CriteriaClauses` from `BookAdvanced`

**Files:**
- Create: `app/lib/search/books/search/criteria_clauses.rb`
- Modify: `app/lib/search/books/search/book_advanced.rb:96-180` (the five private class methods move; `BookAdvanced` delegates)
- Test: `test/lib/search/books/search/criteria_clauses_test.rb`; existing `test/lib/search/books/search/book_advanced_test.rb` must stay green unchanged

**Interfaces:**
- Produces: `Search::Books::Search::CriteriaClauses.filter_clauses(criteria)` and `.must_not_clauses(criteria, excluded_book_ids)` — both take a `Books::SavedSearchCriteria` (or anything with its readers) and return arrays of OpenSearch clause hashes. `CriteriaClauses::MATCH_NOTHING_CLAUSE` is the shared match-nothing constant. Consumed by Task 7.

- [ ] **Step 1: Write the failing test**

`test/lib/search/books/search/criteria_clauses_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class CriteriaClausesTest < ActiveSupport::TestCase
        def criteria(raw)
          ::Books::SavedSearchCriteria.new(raw)
        end

        test "filter clauses cover categories, length, year, ranked and max position" do
          clauses = CriteriaClauses.filter_clauses(criteria(
            "included_category_ids" => [1, 2], "book_length" => [1],
            "first_year_published_gt" => 1900, "first_year_published_lt" => 1950,
            "ranked" => "true", "max_ranked_position" => 100
          ))
          assert_includes clauses, {terms: {category_ids: [1, 2]}}
          assert_includes clauses, {terms: {book_length: [1]}}
          assert_includes clauses, {range: {first_published_year: {gte: 1900, lte: 1950}}}
          assert_includes clauses, {exists: {field: "ranked_position"}}
          assert_includes clauses, {range: {ranked_position: {lte: 100}}}
        end

        test "genre_match_mode all emits one term per category" do
          clauses = CriteriaClauses.filter_clauses(criteria("included_category_ids" => [1, 2], "genre_match_mode" => "all"))
          assert_includes clauses, {term: {category_ids: 1}}
          assert_includes clauses, {term: {category_ids: 2}}
        end

        test "an unparseable criterion yields the match-nothing clause" do
          clauses = CriteriaClauses.filter_clauses(criteria("max_ranked_position" => "abc"))
          assert_includes clauses, CriteriaClauses::MATCH_NOTHING_CLAUSE
        end

        test "must_not clauses cover excluded categories, excluded ids and provisional" do
          clauses = CriteriaClauses.must_not_clauses(criteria("excluded_category_ids" => [7]), [11, 12])
          assert_includes clauses, {terms: {category_ids: [7]}}
          assert_includes clauses, {ids: {values: [11, 12]}}
          assert_includes clauses, ::Search::Books::BookIndex::EXCLUDE_PROVISIONAL
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/search/books/search/criteria_clauses_test.rb`
Expected: FAIL with `NameError: uninitialized constant Search::Books::Search::CriteriaClauses`.

- [ ] **Step 3: Create the module and make `BookAdvanced` delegate**

`app/lib/search/books/search/criteria_clauses.rb` — move the bodies of `filter_clauses`, `category_clauses`, `unparseable_clauses`, `year_range`, and `must_not_clauses` out of `BookAdvanced` **verbatim**, together with `MATCH_NOTHING_CLAUSE` and every comment attached to them:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      # The OpenSearch filter and must_not clauses a Books::SavedSearchCriteria
      # implies. Shared by BookAdvanced (saved searches) and BookRecommendations
      # (the recommendation engine) so the two can never disagree about what a
      # criterion means. Pure: no database, no OpenSearch.
      module CriteriaClauses
        MATCH_NOTHING_CLAUSE = {terms: {category_ids: []}}.freeze

        module_function

        def filter_clauses(criteria)
          # cut from BookAdvanced.filter_clauses, unchanged
        end

        def category_clauses(criteria)
          # cut from BookAdvanced.category_clauses, unchanged
        end

        def unparseable_clauses(criteria)
          # cut from BookAdvanced.unparseable_clauses, unchanged
        end

        def year_range(criteria)
          # cut from BookAdvanced.year_range, unchanged
        end

        def must_not_clauses(criteria, excluded_book_ids)
          # cut from BookAdvanced.must_not_clauses, unchanged
        end
      end
    end
  end
end
```

("cut … unchanged" means: move the exact method bodies and their comments from `book_advanced.rb`; the only edit is removing `self.` from the method names because `module_function` is used.)

In `BookAdvanced`: delete those five methods and the `MATCH_NOTHING_CLAUSE` constant, add `MATCH_NOTHING_CLAUSE = CriteriaClauses::MATCH_NOTHING_CLAUSE` (grep for `BookAdvanced::MATCH_NOTHING_CLAUSE` and keep it resolving), and change `build_query_definition` to call `CriteriaClauses.filter_clauses(criteria)` and `CriteriaClauses.must_not_clauses(criteria, excluded_book_ids)`. Remove the now-empty `private_class_method` line.

- [ ] **Step 4: Run both test files to verify they pass**

Run: `bin/rails test test/lib/search/books/search/criteria_clauses_test.rb test/lib/search/books/search/book_advanced_test.rb test/lib/books/`
Expected: PASS, same count as before for `book_advanced_test.rb`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/search/books/search/criteria_clauses.rb app/lib/search/books/search/book_advanced.rb test/lib/search/books/search/criteria_clauses_test.rb
git commit -m "Extract saved-search criteria clause builders for reuse"
```

---

### Task 4: Legacy `recommendation_configs` migration

**Files:**
- Create: `app/models/legacy_books/recommendation_config.rb`, `app/lib/services/books_migration/recommendation_config_migrator.rb`
- Modify: `lib/tasks/data_migration.rake` (new task after `saved_searches`; add `:recommendation_configs` to `task all:` right after `:saved_searches`)
- Modify: `docs/launch-todo.md` §2 (one line under the `data_migration:all` item)
- Test: `test/lib/services/books_migration/recommendation_config_migrator_test.rb`

**Interfaces:**
- Consumes: `Books::RecommendationConfig` (Task 1), `LegacyIdMap` (`model: "Books::Category"`), `Services::BooksMigration::Migrator` base.
- Produces: `Services::BooksMigration::RecommendationConfigMigrator.call` → `{success:, data: {model:, count:, dropped_category_ids:}}`.

Legacy columns: `user_id`, `book_lengths` (int array), `exclude_locations`, `excluded_category_ids` (int array), `included_category_all` (bool), `included_category_ids` (int array), `published_year_start`, `published_year_end`, `ranked_limit`, timestamps. Legacy and new `book_length` enums are both `very_short 0 … very_long 5` (verified 2026-10-07 against `the-greatest-books/admin/app/models/book.rb:108`); the migrator still asserts it.

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::RecommendationConfigMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::RecommendationConfigMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_row(overrides = {})
    {
      "id" => 7,
      "user_id" => users(:editor_user).id,
      "book_lengths" => [1, 2],
      "exclude_locations" => true,
      "excluded_category_ids" => [55_555],
      "included_category_all" => true,
      "included_category_ids" => [55_555, 99_999],
      "published_year_start" => 1900,
      "published_year_end" => nil,
      "ranked_limit" => 300,
      "created_at" => Time.zone.parse("2025-01-01 00:00:00"),
      "updated_at" => Time.zone.parse("2026-03-01 12:00:00")
    }.merge(overrides)
  end

  setup do
    @category = ::Books::Category.create!(name: "Migrated Genre", category_type: :genre)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 55_555, new_id: @category.id)
  end

  test "creates a Books::RecommendationConfig with translated criteria" do
    result = run_migrator([legacy_row])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]

    config = ::Books::RecommendationConfig.find_by!(user: users(:editor_user))
    assert_equal(
      {"book_length" => [1, 2], "excluded_category_ids" => [@category.id], "genre_match_mode" => "all",
       "included_category_ids" => [@category.id], "first_year_published_gt" => 1900, "max_ranked_position" => 300},
      config.criteria
    )
  end

  test "drops unmapped category ids and reports them" do
    result = run_migrator([legacy_row])
    assert_equal [99_999], result[:data][:dropped_category_ids]
  end

  test "is idempotent: a second run updates the same row" do
    run_migrator([legacy_row])
    run_migrator([legacy_row("ranked_limit" => 50)])
    assert_equal 1, ::Books::RecommendationConfig.where(user: users(:editor_user)).count
    assert_equal 50, ::Books::RecommendationConfig.find_by!(user: users(:editor_user)).criteria["max_ranked_position"]
  end

  test "omits absent values rather than storing nulls" do
    run_migrator([legacy_row("book_lengths" => nil, "excluded_category_ids" => nil, "included_category_ids" => [],
      "included_category_all" => false, "published_year_start" => nil, "ranked_limit" => nil)])
    assert_equal({}, ::Books::RecommendationConfig.find_by!(user: users(:editor_user)).criteria)
  end

  test "fails loudly if the book_length enums disagree" do
    ::Books::Book.stubs(:book_lengths).returns({"very_short" => 0, "short" => 9})
    result = run_migrator([legacy_row])
    assert_not result[:success]
    assert_match(/book_length enum/, result[:error])
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/recommendation_config_migrator_test.rb`
Expected: FAIL with `NameError` for the migrator.

- [ ] **Step 3: Implement**

`app/models/legacy_books/recommendation_config.rb`:

```ruby
module LegacyBooks
  class RecommendationConfig < Record
    self.table_name = "recommendation_configs"
  end
end
```

`app/lib/services/books_migration/recommendation_config_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy recommendation_configs -> Books::RecommendationConfig, keyed on the
    # (preserved) user id. Legacy stored each preference in its own column; the
    # new row stores one criteria hash with the saved-search key names (spec §4.1).
    # exclude_locations has no equivalent and is dropped: the engine down-weights
    # locations instead of switching them off.
    class RecommendationConfigMigrator < Migrator
      LEGACY_BOOK_LENGTHS = {
        "very_short" => 0, "short" => 1, "medium" => 2, "moderate" => 3, "long" => 4, "very_long" => 5
      }.freeze

      def call
        @dropped_category_ids = []
        assert_book_length_enum!
        super
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count || 0}}
      end

      private

      def legacy_model
        LegacyBooks::RecommendationConfig
      end

      def model_key
        "Books::RecommendationConfig"
      end

      def assert_book_length_enum!
        return if ::Books::Book.book_lengths == LEGACY_BOOK_LENGTHS

        raise "book_length enum differs from legacy (#{::Books::Book.book_lengths.inspect}); " \
              "book_lengths cannot be copied by value"
      end

      def upsert_row(attrs)
        config = ::Books::RecommendationConfig.find_or_initialize_by(user_id: attrs["user_id"])
        config.criteria = transform_criteria(attrs)
        config.save!
      end

      def transform_criteria(attrs)
        out = {}
        lengths = Array(attrs["book_lengths"]).compact
        out["book_length"] = lengths if lengths.any?

        excluded = remap_category_ids(attrs["excluded_category_ids"])
        out["excluded_category_ids"] = excluded if excluded.any?

        included = remap_category_ids(attrs["included_category_ids"])
        out["included_category_ids"] = included if included.any?
        out["genre_match_mode"] = "all" if attrs["included_category_all"] && included.any?

        out["first_year_published_gt"] = attrs["published_year_start"] if attrs["published_year_start"]
        out["first_year_published_lt"] = attrs["published_year_end"] if attrs["published_year_end"]
        out["max_ranked_position"] = attrs["ranked_limit"] if attrs["ranked_limit"]
        out
      end

      def remap_category_ids(value)
        Array(value).compact.filter_map do |legacy_id|
          new_id = category_map[legacy_id.to_i]
          @dropped_category_ids << legacy_id.to_i if new_id.nil?
          new_id
        end
      end

      def category_map
        @category_map ||= LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id, :new_id).to_h
      end

      def extra_result_data
        {dropped_category_ids: @dropped_category_ids.uniq}
      end
    end
  end
end
```

Add to `lib/tasks/data_migration.rake` after the `saved_searches` task:

```ruby
  desc "Migrate legacy recommendation_configs into Books::RecommendationConfig (keyed on user; remaps categories; drops exclude_locations)"
  task recommendation_configs: :environment do
    pp Services::BooksMigration::RecommendationConfigMigrator.call
  end
```

and insert `:recommendation_configs` into `task all:` immediately after `:saved_searches`.

In `docs/launch-todo.md`, under the `bin/rails data_migration:all` item in §2, add:

```
   It now also includes `recommendation_configs` (the 33 legacy recommendation settings, 9 of
   them paid users'). It re-runs safely on every rehearsal pass; `exclude_locations` is dropped
   on purpose.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/recommendation_config_migrator_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/legacy_books/recommendation_config.rb app/lib/services/books_migration/recommendation_config_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/recommendation_config_migrator_test.rb ../docs/launch-todo.md
git commit -m "Migrate legacy recommendation configs"
```

---

### Task 5: Knobs, value objects, registry, and the books adapter

**Files:**
- Create: `config/initializers/recommendations.rb`, `app/lib/recommendations/config.rb`, `app/lib/recommendations/interaction.rb`, `app/lib/recommendations/category_fact.rb`, `app/lib/recommendations/item_fact.rb`, `app/lib/recommendations/candidate.rb`, `app/lib/recommendations/reason.rb`, `app/lib/recommendations/registry.rb`, `app/lib/recommendations/books/adapter.rb`
- Test: `test/lib/recommendations/config_test.rb`, `test/lib/recommendations/registry_test.rb`, `test/lib/recommendations/books/adapter_test.rb`

**Interfaces:**
- Produces:
  - `Recommendations::Config.resolve(overrides = {})` → `ActiveSupport::OrderedOptions` (initializer defaults merged with overrides).
  - `Recommendations::Interaction = Struct.new(:item_id, :weight, :kind, :rating, keyword_init: true)`; `kind` ∈ `:favorite, :read, :reading, :want_to_read, :review`; `rating` is a Numeric or nil.
  - `Recommendations::CategoryFact = Struct.new(:id, :category_type, :item_count, keyword_init: true)` (`category_type` is a String: "genre"/"subject"/"location").
  - `Recommendations::ItemFact = Struct.new(:author_ids, :genre_ids, :series_predecessor_id, :rank_position, keyword_init: true)`.
  - `Recommendations::Candidate = Struct.new(:item_id, :score, :rank_position, :evidence, keyword_init: true)`.
  - `Recommendations::Reason = Struct.new(:type, :ids, keyword_init: true)`.
  - `Recommendations::Registry.adapter_class_for(domain)` → class or nil.
  - `Recommendations::Books::Adapter.new(config:)` with `interactions(user)`, `shelved_item_ids(user)`, `categories_for(item_ids)` → `{item_id => [CategoryFact]}`, `catalog_size`, `type_category_ids` → `{"Fiction" => id, "Nonfiction" => id}`, `criteria_for(user)` → `Books::RecommendationCriteria`, `item_facts(item_ids)` → `{item_id => ItemFact}`, `load_items(item_ids)` → `{id => Books::Book}`. (`search_candidates` and `rank_ordered_candidates` are added in Task 7.)

- [ ] **Step 1: Write the initializer**

`config/initializers/recommendations.rb`:

```ruby
# frozen_string_literal: true

# Tuning knobs for the recommendation engine (spec §9.3). Defaults only: every
# key is overridable per call through Recommendations::Config.resolve(overrides),
# which is how the harness sweeps values in one process and how tests pin
# behaviour without touching global state. Change production behaviour by
# editing this file and deploying.
Rails.application.config.x.recommendations = ActiveSupport::OrderedOptions.new.merge(
  free_limit: 10,
  member_limit: 50,
  candidate_size: 300,

  # Interaction weights (spec §6.1)
  favorite_weight: 2.0,
  top_favorite_bonus: 0.5,
  top_favorite_count: 10,
  read_weight: 0.4,
  want_to_read_weight: 0.2,
  rating_slope: 0.75,

  # Profile (spec §6.2-6.4)
  lift: true,
  pseudo_books: 10,
  min_support: 2,
  min_support_history: 5,
  negative_gamma: 0.5,
  demote_threshold: 1.0,
  negative_boost: 0.3,
  max_genres: 8,
  max_subjects: 25,
  max_locations: 5,
  genre_multiplier: 1.0,
  subject_multiplier: 0.8,
  location_multiplier: 0.4,
  fiction_share_high: 0.9,
  fiction_share_low: 0.1,

  # Query (spec §7)
  normalization_floor: 10,
  min_score: 1.0,

  # Fusion (spec §5.4)
  rrf_k: 60,
  taste_weight: 1.0,
  collaborative_half_point: 10,
  rank_prior_weight: 0.3,

  # Re-ranking and explanations (spec §8)
  max_per_author: 2,
  calibrate_genres: true,
  calibration_lambda: 0.3,
  calibration_alpha: 0.01,
  explain_threshold: 1.0
)
```

- [ ] **Step 2: Write the failing tests**

`test/lib/recommendations/config_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ConfigTest < ActiveSupport::TestCase
    test "resolve returns the defaults with overrides applied and leaves globals untouched" do
      resolved = Config.resolve(max_per_author: 1)
      assert_equal 1, resolved[:max_per_author]
      assert_equal 10, resolved[:free_limit]
      assert_equal 2, Rails.application.config.x.recommendations[:max_per_author]
    end
  end
end
```

`test/lib/recommendations/registry_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class RegistryTest < ActiveSupport::TestCase
    test "books resolves to the books adapter and unknown domains to nil" do
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for("books")
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for(:books)
      assert_nil Registry.adapter_class_for("music")
    end
  end
end
```

`test/lib/recommendations/books/adapter_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  module Books
    class AdapterTest < ActiveSupport::TestCase
      # Fixtures: regular_user favorites = war_and_peace (pos 1), got (pos 2);
      # read = clash; reviews = war_and_peace ★5, crime_and_punishment ★3.
      def setup
        @user = users(:regular_user)
        @adapter = Adapter.new(config: Config.resolve)
        @want = ::Books::UserList.create!(user: @user, list_type: :want_to_read, name: "Want")
        @want.user_list_items.create!(listable: books_books(:of_mice_and_men))
        Review.create!(user: @user, reviewable: books_books(:cannery_row), rating: 1)
      end

      def interaction(book)
        @adapter.interactions(@user).find { |i| i.item_id == books_books(book).id }
      end

      test "favorites take the favorite weight plus the rating weight" do
        assert_in_delta 2.0 + 0.75 * 2, interaction(:war_and_peace).weight, 0.001
        assert_equal :favorite, interaction(:war_and_peace).kind
        assert_equal 5, interaction(:war_and_peace).rating
      end

      test "an unordered favorites list earns no top-favorite bonus" do
        assert_in_delta 2.0, interaction(:got).weight, 0.001
      end

      test "a manually ordered favorites list adds the bonus to its top entries" do
        user_lists(:regular_user_books_favorites).update!(manually_ordered: true)
        assert_in_delta 2.5, interaction(:got).weight, 0.001
      end

      test "read, want-to-read, and ratings map to their weights" do
        assert_in_delta 0.4, interaction(:clash).weight, 0.001
        assert_equal :read, interaction(:clash).kind
        assert_in_delta 0.2, interaction(:of_mice_and_men).weight, 0.001
        assert_equal :want_to_read, interaction(:of_mice_and_men).kind
        assert_in_delta(-1.5, interaction(:cannery_row).weight, 0.001)
        assert_equal :review, interaction(:cannery_row).kind
        assert_in_delta 0.0, interaction(:crime_and_punishment).weight, 0.001
      end

      test "a text-only review counts as read" do
        Review.create!(user: @user, reviewable: books_books(:combo_steinbeck), body: "Fine.")
        assert_in_delta 0.4, interaction(:combo_steinbeck).weight, 0.001
        assert_nil interaction(:combo_steinbeck).rating
      end

      test "custom lists contribute no interaction" do
        custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Shelf")
        custom.user_list_items.create!(listable: books_books(:combo_steinbeck))
        assert_nil interaction(:combo_steinbeck)
      end

      test "shelved ids include every list (custom and want-to-read) and every review" do
        custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Shelf")
        custom.user_list_items.create!(listable: books_books(:combo_steinbeck))
        expected = %i[war_and_peace got clash of_mice_and_men cannery_row crime_and_punishment combo_steinbeck]
          .map { |k| books_books(k).id }.sort
        assert_equal expected, @adapter.shelved_item_ids(@user).sort
      end

      test "categories_for returns scoring categories with type and item_count" do
        facts = @adapter.categories_for([books_books(:crime_and_punishment).id])[books_books(:crime_and_punishment).id]
        by_name = facts.index_by { |f| ::Books::Category.find(f.id).name }
        assert_equal "genre", by_name["Novels"].category_type
        assert_equal 300, by_name["Novels"].item_count
        assert_equal "subject", by_name["Politics"].category_type
        assert_equal "location", by_name["France"].category_type
      end

      test "categories_for skips soft-deleted categories" do
        CategoryItem.create!(category: categories(:books_deleted_genre), item: books_books(:got))
        ids = @adapter.categories_for([books_books(:got).id]).fetch(books_books(:got).id).map(&:id)
        assert_not_includes ids, categories(:books_deleted_genre).id
      end

      test "type_category_ids resolves Fiction and Nonfiction by name" do
        ids = @adapter.type_category_ids
        assert_equal categories(:books_fiction_genre).id, ids["Fiction"]
        assert_equal categories(:books_nonfiction_genre).id, ids["Nonfiction"]
      end

      test "item_facts carry authors, genres, series predecessor and rank" do
        facts = @adapter.item_facts([books_books(:got).id, books_books(:clash).id])
        got = facts[books_books(:got).id]
        clash = facts[books_books(:clash).id]
        assert_equal [books_authors(:king).id], got.author_ids
        assert_includes got.genre_ids, categories(:books_novels_genre).id
        assert_nil got.series_predecessor_id, "position 1 has no predecessor"
        assert_equal books_books(:got).id, clash.series_predecessor_id, "the unnumbered novella at 1.5 is skipped"
        assert_nil got.rank_position
      end

      test "criteria_for returns the stored criteria or an empty one" do
        assert_equal 500, @adapter.criteria_for(@user).max_ranked_position
        assert_nil @adapter.criteria_for(users(:editor_user)).max_ranked_position
      end

      test "catalog_size counts non-provisional books" do
        assert_equal ::Books::Book.catalog.count, @adapter.catalog_size
      end
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/lib/recommendations/`
Expected: FAIL with `NameError: uninitialized constant Recommendations`.

- [ ] **Step 4: Implement the value objects, config and registry**

`app/lib/recommendations/config.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Config
    def self.resolve(overrides = {})
      Rails.application.config.x.recommendations.merge(overrides || {})
    end
  end
end
```

`app/lib/recommendations/interaction.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # One book the user has touched. kind is the strongest LIST relationship
  # (:favorite > :reading/:read > :want_to_read) or :review when the book is only
  # reviewed; rating is the numeric star rating or nil. weight is already signed
  # (spec §6.1), so consumers never recompute it.
  Interaction = Struct.new(:item_id, :weight, :kind, :rating, keyword_init: true) do
    def positive? = weight.positive?

    def negative? = weight.negative?
  end
end
```

`app/lib/recommendations/category_fact.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  CategoryFact = Struct.new(:id, :category_type, :item_count, keyword_init: true)
end
```

`app/lib/recommendations/item_fact.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  ItemFact = Struct.new(:author_ids, :genre_ids, :series_predecessor_id, :rank_position, keyword_init: true)
end
```

`app/lib/recommendations/candidate.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # A scored item from one signal. evidence is a Hash the explainer reads:
  # {categories: [id, ...]} from the taste signal, {because_of: item_id} from
  # the collaborative signal, {} from the rank-only fallback.
  Candidate = Struct.new(:item_id, :score, :rank_position, :evidence, keyword_init: true)
end
```

`app/lib/recommendations/reason.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # type is :because_of (ids = [item_id]), :interests (ids = category ids), or
  # :ranked (ids = [rank_position]). Structured so a later API can return it.
  Reason = Struct.new(:type, :ids, keyword_init: true)
end
```

`app/lib/recommendations/registry.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # Which adapter serves which domain. Mirrors SavedSearch::DOMAIN_SUBCLASSES.
  # A domain absent here has no recommendations.
  module Registry
    DOMAIN_ADAPTERS = {"books" => "Recommendations::Books::Adapter"}.freeze

    def self.adapter_class_for(domain)
      DOMAIN_ADAPTERS[domain.to_s]&.constantize
    end
  end
end
```

- [ ] **Step 5: Implement the books adapter**

`app/lib/recommendations/books/adapter.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Books
    # Everything the engine needs to know about books: the user's interactions
    # and shelf, category and item facts, and (Task 7) the two OpenSearch
    # candidate queries. The only place in the engine that names a books model.
    # Root-anchored constants throughout: inside Recommendations::Books a bare
    # `Books::Book` resolves to Recommendations::Books::Book.
    class Adapter
      SCORING_TYPES = ::Books::Book::SIMILARITY_CATEGORY_TYPES
      LIST_KINDS = {"favorites" => :favorite, "read" => :read, "reading" => :reading, "want_to_read" => :want_to_read}.freeze

      attr_reader :config

      def initialize(config:)
        @config = config
      end

      def interactions(user)
        list_weights, kinds = list_weights_for(user)
        reviews = user.reviews.where(reviewable_type: "Books::Book").pluck(:reviewable_id, :rating).to_h

        (list_weights.keys | reviews.keys).map do |item_id|
          rating = reviews[item_id]
          base = list_weights[item_id]
          base = config[:read_weight] if base.nil? && reviews.key?(item_id) && rating.nil?
          weight = (base || 0.0) + (rating ? config[:rating_slope] * (rating - 3) : 0.0)
          Interaction.new(item_id: item_id, weight: weight.to_f, kind: kinds[item_id] || :review, rating: rating)
        end
      end

      def shelved_item_ids(user)
        list_ids = ::UserListItem.joins(:user_list)
          .where(user_lists: {user_id: user.id, type: "Books::UserList"}, listable_type: "Books::Book")
          .distinct.pluck(:listable_id)
        review_ids = user.reviews.where(reviewable_type: "Books::Book").pluck(:reviewable_id)
        list_ids | review_ids
      end

      def categories_for(item_ids)
        return {} if item_ids.empty?

        rows = ::CategoryItem.joins(:category)
          .where(item_type: "Books::Book", item_id: item_ids)
          .where(categories: {deleted: false, category_type: SCORING_TYPES})
          .pluck(:item_id, "categories.id", "categories.category_type", "categories.item_count")

        rows.group_by(&:first).transform_values do |group|
          group.map do |_, id, type, count|
            CategoryFact.new(id: id, category_type: type_name(type), item_count: count.to_i)
          end
        end
      end

      def catalog_size
        @catalog_size ||= ::Books::Book.catalog.count
      end

      def type_category_ids
        @type_category_ids ||= ::Books::Category
          .where(name: ::Books::Book::BOOK_TYPE_CATEGORY_NAMES, category_type: :genre)
          .pluck(:name, :id).to_h
      end

      def criteria_for(user)
        ::Books::RecommendationConfig.for_user(user).criteria_object
      end

      def item_facts(item_ids)
        return {} if item_ids.empty?

        authors = ::Books::BookAuthor.where(book_id: item_ids).pluck(:book_id, :author_id).group_by(&:first)
        genres = ::CategoryItem.joins(:category)
          .where(item_type: "Books::Book", item_id: item_ids)
          .where(categories: {deleted: false, category_type: :genre})
          .pluck(:item_id, :category_id).group_by(&:first)
        predecessors = series_predecessors(item_ids)
        ranks = ::RankedItem.where(item_type: "Books::Book", item_id: item_ids,
          ranking_configuration_id: ::Books::RankingConfiguration.default_primary&.id).pluck(:item_id, :rank).to_h

        item_ids.index_with do |id|
          ItemFact.new(
            author_ids: authors.fetch(id, []).map(&:last),
            genre_ids: genres.fetch(id, []).map(&:last),
            series_predecessor_id: predecessors[id],
            rank_position: ranks[id]
          )
        end
      end

      # The cards' preload chain (Books::CardComponent needs authors + cover).
      def load_items(item_ids)
        ::Books::Book.where(id: item_ids)
          .includes(book_authors: :author)
          .includes(primary_image: {file_attachment: :blob})
          .index_by(&:id)
      end

      private

      def list_weights_for(user)
        rows = ::UserListItem.joins(:user_list)
          .where(user_lists: {user_id: user.id, type: "Books::UserList"}, listable_type: "Books::Book")
          .where.not(user_lists: {list_type: ::Books::UserList.list_types["custom"]})
          .pluck(:listable_id, "user_lists.list_type", "user_lists.manually_ordered", :position)

        weights = {}
        kinds = {}
        rows.each do |item_id, list_type, manual, position|
          name = ::Books::UserList.list_types.key(list_type) || list_type.to_s
          weight = list_weight(name, manual, position)
          next if weights[item_id] && weights[item_id] >= weight

          weights[item_id] = weight
          kinds[item_id] = LIST_KINDS.fetch(name)
        end
        [weights, kinds]
      end

      def list_weight(name, manual, position)
        case name
        when "favorites"
          bonus = (manual && position.to_i <= config[:top_favorite_count]) ? config[:top_favorite_bonus] : 0.0
          config[:favorite_weight] + bonus
        when "read", "reading" then config[:read_weight]
        when "want_to_read" then config[:want_to_read_weight]
        else 0.0
        end
      end

      # pluck through a join returns the enum's integer on some adapters and its
      # name on others; normalise to the name.
      def type_name(value)
        value.is_a?(Integer) ? ::Category.category_types.key(value) : value.to_s
      end

      # The nearest NUMBERED entry with a lower position in each of the item's
      # series. Unnumbered entries (novellas at 1.5) never count as predecessors.
      def series_predecessors(item_ids)
        own = ::Books::SeriesBook.where(book_id: item_ids, numbered: true).where.not(position: nil)
          .pluck(:book_id, :series_id, :position)
        return {} if own.empty?

        all = ::Books::SeriesBook.where(series_id: own.map { |_, s, _| s }.uniq, numbered: true)
          .where.not(position: nil).pluck(:series_id, :book_id, :position).group_by(&:first)

        own.each_with_object({}) do |(book_id, series_id, position), out|
          earlier = all.fetch(series_id, []).select { |_, _, p| p < position }.max_by { |_, _, p| p }
          out[book_id] = earlier&.at(1) if out[book_id].nil?
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests and the Zeitwerk check**

Run: `bin/rails test test/lib/recommendations/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; "All is good!".

- [ ] **Step 7: Commit**

```bash
git add config/initializers/recommendations.rb app/lib/recommendations test/lib/recommendations
git commit -m "Add recommendation engine knobs, value objects, registry and books adapter"
```

---

### Task 6: `Profile` and `ProfileBuilder` (the lift math)

**Files:**
- Create: `app/lib/recommendations/profile.rb`, `app/lib/recommendations/profile_builder.rb`
- Test: `test/lib/recommendations/profile_builder_test.rb`

**Interfaces:**
- Consumes: `Interaction`, `CategoryFact`, `Config` (Task 5).
- Produces: `Recommendations::Profile = Struct.new(:genres, :subjects, :locations, :demoted, :fiction_share, :genre_distribution, :counts, keyword_init: true)` where `genres`/`subjects`/`locations` are `[[category_id, weight], ...]` sorted by weight desc, `demoted` is `[category_id, ...]`, `fiction_share` is Float or nil, `genre_distribution` is `{genre_id => share}` summing to 1 (includes Fiction/Nonfiction), `counts` is `{favorites:, read:, rated:, positive:, negative:}`. Methods: `empty?`, `weight_for(category_id)`, `scored_ids`. `Recommendations::ProfileBuilder.call(interactions:, categories:, catalog_size:, type_category_ids:, config:)` → `Profile`.

- [ ] **Step 1: Write the failing tests**

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ProfileBuilderTest < ActiveSupport::TestCase
    FICTION = 1
    NONFICTION = 2
    COMMON = 10    # genre on 55% of the catalog
    RARE = 11      # genre on 0.6%
    SUBJ = 20
    LOC = 30
    HATED = 40     # subject only on the disliked book

    def fact(id, type, count)
      CategoryFact.new(id: id, category_type: type, item_count: count)
    end

    # 20 positive books, every one Fiction + COMMON; books 1-3 also RARE; book 1 also SUBJ + LOC.
    def positive_categories
      (1..20).to_h do |i|
        cats = [fact(FICTION, "genre", 550), fact(COMMON, "genre", 550)]
        cats << fact(RARE, "genre", 6) if i <= 3
        cats += [fact(SUBJ, "subject", 40), fact(LOC, "location", 30)] if i == 1
        [i, cats]
      end
    end

    def positives
      (1..20).map { |i| Interaction.new(item_id: i, weight: 1.0, kind: :read, rating: nil) }
    end

    def build(interactions:, categories:, **overrides)
      ProfileBuilder.call(
        interactions: interactions, categories: categories, catalog_size: 1000,
        type_category_ids: {"Fiction" => FICTION, "Nonfiction" => NONFICTION},
        config: Config.resolve(overrides)
      )
    end

    def weight(profile, id)
      profile.weight_for(id)
    end

    test "a ubiquitous category scores near zero and a rare one scores high" do
      profile = build(interactions: positives, categories: positive_categories)
      assert_operator weight(profile, COMMON), :<, 0.5
      assert_operator weight(profile, RARE), :>, 2.5
      assert_equal RARE, profile.genres.first.first
    end

    test "with lift off the profile is a raw frequency share, so the common category wins" do
      profile = build(interactions: positives, categories: positive_categories, lift: false)
      assert_operator weight(profile, COMMON), :>, weight(profile, RARE)
    end

    test "a category needs min_support positive books once the history is big enough" do
      profile = build(interactions: positives, categories: positive_categories)
      assert_nil weight(profile, SUBJ), "SUBJ appears on one book of twenty"
      small = build(interactions: positives.first(2), categories: positive_categories.slice(1, 2))
      assert_not_nil weight(small, SUBJ), "a tiny history keeps single-book categories"
    end

    test "Fiction and Nonfiction are never scored but set fiction_share and the genre distribution" do
      profile = build(interactions: positives, categories: positive_categories)
      assert_nil weight(profile, FICTION)
      assert_in_delta 1.0, profile.fiction_share, 0.001
      assert_in_delta 1.0, profile.genre_distribution.values.sum, 0.0001
      assert_in_delta profile.genre_distribution[FICTION], profile.genre_distribution[COMMON], 0.05
    end

    test "fiction_share is nil when no positive book carries a type" do
      cats = {1 => [fact(COMMON, "genre", 550)]}
      profile = build(interactions: positives.first(1), categories: cats)
      assert_nil profile.fiction_share
    end

    test "a disliked category with no positive weight is demoted, not scored" do
      hated = Interaction.new(item_id: 99, weight: -1.5, kind: :review, rating: 1)
      cats = positive_categories.merge(99 => [fact(FICTION, "genre", 550), fact(HATED, "subject", 20)])
      profile = build(interactions: positives + [hated], categories: cats)
      assert_includes profile.demoted, HATED
      assert_nil weight(profile, HATED)
    end

    test "a disliked category that is also liked is reduced by gamma, not demoted" do
      hated = Interaction.new(item_id: 99, weight: -1.5, kind: :review, rating: 1)
      cats = positive_categories.merge(99 => [fact(RARE, "genre", 6)])
      with = build(interactions: positives + [hated], categories: cats)
      without = build(interactions: positives, categories: positive_categories)
      assert_operator weight(with, RARE), :<, weight(without, RARE)
      assert_not_includes with.demoted, RARE
    end

    test "caps each type" do
      cats = (1..20).to_h { |i| [i, (100..110).map { |g| fact(g, "genre", 5) }] }
      profile = build(interactions: positives, categories: cats, max_genres: 3)
      assert_equal 3, profile.genres.size
    end

    test "an empty history yields an empty profile" do
      profile = build(interactions: [], categories: {})
      assert profile.empty?
      assert_equal({favorites: 0, read: 0, rated: 0, positive: 0, negative: 0}, profile.counts)
    end

    test "counts reflect kinds and ratings" do
      ints = [
        Interaction.new(item_id: 1, weight: 3.5, kind: :favorite, rating: 5),
        Interaction.new(item_id: 2, weight: 0.4, kind: :read, rating: nil),
        Interaction.new(item_id: 3, weight: -1.5, kind: :review, rating: 1)
      ]
      profile = build(interactions: ints, categories: positive_categories)
      assert_equal({favorites: 1, read: 1, rated: 2, positive: 2, negative: 1}, profile.counts)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/recommendations/profile_builder_test.rb`
Expected: FAIL with `NameError: uninitialized constant Recommendations::ProfileBuilder`.

- [ ] **Step 3: Implement**

`app/lib/recommendations/profile.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  Profile = Struct.new(:genres, :subjects, :locations, :demoted, :fiction_share, :genre_distribution, :counts,
    keyword_init: true) do
    def empty? = genres.empty? && subjects.empty? && locations.empty?

    def weight_for(category_id)
      weights[category_id]
    end

    def scored_ids
      weights.keys
    end

    private

    def weights
      @weights ||= (genres + subjects + locations).to_h
    end
  end
end
```

`app/lib/recommendations/profile_builder.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # The taste profile (spec §6): per category, how much the user's positively
  # weighted books over-index on it versus the catalog, minus a share of how much
  # the negatively weighted ones do. Pure Ruby -- no database, no OpenSearch --
  # so every number here is unit-testable.
  class ProfileBuilder
    TYPE_LIMITS = {"genre" => :max_genres, "subject" => :max_subjects, "location" => :max_locations}.freeze

    def self.call(**args)
      new(**args).call
    end

    def initialize(interactions:, categories:, catalog_size:, type_category_ids:, config:)
      @interactions = interactions
      @categories = categories
      @catalog_size = [catalog_size.to_i, 1].max
      @type_ids = type_category_ids.values.to_set
      @fiction_id = type_category_ids["Fiction"]
      @nonfiction_id = type_category_ids["Nonfiction"]
      @config = config
    end

    def call
      positives = @interactions.select(&:positive?)
      negatives = @interactions.select(&:negative?)

      pos = lift_weights(positives)
      neg = lift_weights(negatives)
      net = pos.to_h { |id, w| [id, w - @config[:negative_gamma] * neg.fetch(id, 0.0)] }
        .select { |_, w| w.positive? }
      demoted = neg.select { |id, w| !pos.key?(id) && w >= @config[:demote_threshold] }.keys

      Profile.new(
        genres: select_type(net, "genre"),
        subjects: select_type(net, "subject"),
        locations: select_type(net, "location"),
        demoted: demoted,
        fiction_share: fiction_share(positives),
        genre_distribution: genre_distribution(positives),
        counts: counts(positives, negatives)
      )
    end

    private

    # {category_id => weight}. With lift on: max(0, ln(s_c / p_c)); off: the raw
    # share n_c / W, which reproduces the legacy frequency behaviour for the
    # harness baseline.
    def lift_weights(interactions)
      total = interactions.sum { |i| i.weight.abs }
      return {} if total <= 0

      mass = Hash.new(0.0)
      support = Hash.new(0)
      interactions.each do |interaction|
        facts_for(interaction.item_id).each do |fact|
          mass[fact.id] += interaction.weight.abs
          support[fact.id] += 1
        end
      end

      min_support = (interactions.size >= @config[:min_support_history]) ? @config[:min_support] : 1
      m = @config[:pseudo_books].to_f

      mass.each_with_object({}) do |(id, n), out|
        next if support[id] < min_support

        p = [fact_by_id[id].item_count.to_f / @catalog_size, 1.0 / @catalog_size].max
        weight = if @config[:lift]
          s = (n + m * p) / (total + m)
          [0.0, Math.log(s / p)].max
        else
          n / total
        end
        out[id] = weight if weight.positive?
      end
    end

    def select_type(net, type)
      limit = @config[TYPE_LIMITS.fetch(type)]
      net.select { |id, _| fact_by_id[id].category_type == type }
        .sort_by { |id, w| [-w, id] }
        .first(limit)
    end

    # Type categories are excluded from scoring here, once, so no caller can
    # readmit them by raising a ceiling.
    def facts_for(item_id)
      @categories.fetch(item_id, []).reject { |f| @type_ids.include?(f.id) }
    end

    def fact_by_id
      @fact_by_id ||= @categories.values.flatten.index_by(&:id)
    end

    def fiction_share(positives)
      fiction = 0.0
      typed = 0.0
      positives.each do |interaction|
        ids = @categories.fetch(interaction.item_id, []).map(&:id)
        is_fiction = ids.include?(@fiction_id)
        is_nonfiction = ids.include?(@nonfiction_id)
        next unless is_fiction || is_nonfiction

        typed += interaction.weight
        fiction += interaction.weight if is_fiction
      end
      typed.positive? ? fiction / typed : nil
    end

    # Each positive book spreads its weight evenly over its genres, type genres
    # included: this is the distribution calibration (spec §8.1) matches.
    def genre_distribution(positives)
      dist = Hash.new(0.0)
      positives.each do |interaction|
        genres = @categories.fetch(interaction.item_id, []).select { |f| f.category_type == "genre" }
        next if genres.empty?

        genres.each { |g| dist[g.id] += interaction.weight / genres.size }
      end
      total = dist.values.sum
      return {} if total <= 0

      dist.transform_values { |v| v / total }
    end

    def counts(positives, negatives)
      {
        favorites: @interactions.count { |i| i.kind == :favorite },
        read: @interactions.count { |i| %i[read reading].include?(i.kind) },
        rated: @interactions.count { |i| !i.rating.nil? },
        positive: positives.size,
        negative: negatives.size
      }
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/recommendations/profile_builder_test.rb`
Expected: PASS (10 tests). If "a disliked category with no positive weight is demoted" fails on the threshold, note that one 1.5-weight book out of a negative total of 1.5 gives `s = (1.5 + 10·0.02)/(1.5 + 10) = 0.148`, `ln(0.148/0.02) = 2.0 ≥ 1.0` — the test data is chosen so it passes; do not lower `demote_threshold` to make it pass.

- [ ] **Step 5: Commit**

```bash
git add app/lib/recommendations/profile.rb app/lib/recommendations/profile_builder.rb test/lib/recommendations/profile_builder_test.rb
git commit -m "Add the lift-weighted taste profile builder"
```

---

### Task 7: The OpenSearch query (`BookRecommendations`) and the adapter's two candidate methods

**Files:**
- Create: `app/lib/search/books/search/book_recommendations.rb`
- Modify: `app/lib/recommendations/books/adapter.rb` (add `search_candidates`, `rank_ordered_candidates`)
- Test: `test/lib/search/books/search/book_recommendations_test.rb`, add two tests to `test/lib/recommendations/books/adapter_test.rb`

**Interfaces:**
- Consumes: `CriteriaClauses` (Task 3), `Books::RecommendationCriteria#to_search_criteria` (Task 2), `Profile` (Task 6), `Candidate` (Task 5).
- Produces: `Search::Books::Search::BookRecommendations.call(profile:, criteria:, excluded_ids:, type_category_ids:, options: {})` → `[{id: Integer, score: Float, rank_position: Integer|nil}]` best first; `.ranked_only(criteria:, excluded_ids:, options: {})` → same shape, ordered by rank; `.build_query_definition(...)` for tests. Adapter: `search_candidates(profile:, criteria:, excluded_ids:, size:)` → `[Candidate]` with `evidence: {taste: true}`; `rank_ordered_candidates(criteria:, excluded_ids:, size:)` → `[Candidate]` with `evidence: {}`.

- [ ] **Step 1: Write the failing query tests**

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookRecommendationsTest < ActiveSupport::TestCase
        G1 = "9101"
        G2 = "9102"
        S1 = "9201"
        FICTION = "9301"
        NONFICTION = "9302"
        TYPE_IDS = {"Fiction" => 9301, "Nonfiction" => 9302}.freeze

        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end

        def index_book(id, attrs = {})
          genres = attrs.fetch(:genre_category_ids, [])
          subjects = attrs.fetch(:subject_category_ids, [])
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name, id: id, refresh: true,
            body: {
              title: "Book #{id}",
              category_ids: genres + subjects,
              genre_category_ids: genres,
              subject_category_ids: subjects,
              location_category_ids: [],
              similarity_category_count: attrs.fetch(:similarity_category_count, 10),
              author_ids: [], original_language_id: nil, country_ids: [],
              book_length: attrs[:book_length], first_published_year: attrs[:first_published_year],
              ranked: true,
              ranked_position: attrs.fetch(:ranked_position, id),
              provisional: attrs.fetch(:provisional, false)
            }
          )
        end

        def profile(genres: [[9101, 2.0], [9102, 1.0]], subjects: [], demoted: [], fiction_share: nil)
          Recommendations::Profile.new(genres: genres, subjects: subjects, locations: [], demoted: demoted,
            fiction_share: fiction_share, genre_distribution: {}, counts: {})
        end

        def criteria(raw = {})
          ::Books::RecommendationCriteria.new(raw)
        end

        def ids(profile: self.profile, criteria: self.criteria, excluded_ids: [], **options)
          BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: excluded_ids,
            type_category_ids: TYPE_IDS, options: {min_score: 0}.merge(options)).map { |h| h[:id] }
        end

        test "shared categories add up: two matches outrank one" do
          index_book(1, genre_category_ids: [G1])
          index_book(2, genre_category_ids: [G1, G2])
          assert_equal [2, 1], ids
        end

        test "boosts scale with profile weight and type multiplier" do
          index_book(1, genre_category_ids: [G1])            # 2.0 * 1.0
          index_book(2, subject_category_ids: [S1])          # 3.0 * 0.8 = 2.4
          assert_equal [2, 1], ids(profile: profile(genres: [[9101, 2.0]], subjects: [[9201, 3.0]]))
        end

        test "excluded ids and provisional books never return" do
          index_book(1, genre_category_ids: [G1])
          index_book(2, genre_category_ids: [G1])
          index_book(3, genre_category_ids: [G1], provisional: true)
          assert_equal [1], ids(excluded_ids: [2])
        end

        test "criteria apply as hard filters" do
          index_book(1, genre_category_ids: [G1], ranked_position: 10, book_length: 1, first_published_year: 1950)
          index_book(2, genre_category_ids: [G1], ranked_position: 900, book_length: 1, first_published_year: 1950)
          index_book(3, genre_category_ids: [G1], ranked_position: 20, book_length: 4, first_published_year: 1950)
          index_book(4, genre_category_ids: [G1], ranked_position: 30, book_length: 1, first_published_year: 1800)
          index_book(5, genre_category_ids: [G1, S1], ranked_position: 40, book_length: 1, first_published_year: 1950)
          assert_equal [1], ids(criteria: criteria("max_ranked_position" => 100, "book_length" => [1],
            "first_year_published_gt" => 1900, "excluded_category_ids" => [9201]))
        end

        test "an unparseable criterion matches nothing" do
          index_book(1, genre_category_ids: [G1])
          assert_equal [], ids(criteria: criteria("max_ranked_position" => "abc"))
        end

        test "a demoted category scales the score down instead of excluding" do
          index_book(1, genre_category_ids: [G1])
          index_book(2, genre_category_ids: [G1], subject_category_ids: [S1])
          result = BookRecommendations.call(profile: profile(demoted: [9201]), criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0})
          assert_equal [1, 2], result.map { |h| h[:id] }
          assert_in_delta result[0][:score] * 0.3, result[1][:score], 0.01
        end

        test "a high fiction share demotes nonfiction-only books but not books tagged both" do
          index_book(1, genre_category_ids: [G1, NONFICTION])
          index_book(2, genre_category_ids: [G1, FICTION, NONFICTION])
          index_book(3, genre_category_ids: [G1, FICTION])
          result = ids(profile: profile(fiction_share: 0.95))
          assert_equal 1, result.last, "the nonfiction-only book sinks"
          assert_includes result.first(2), 2
        end

        test "normalization divides by sqrt(count) above the floor" do
          index_book(1, genre_category_ids: [G1], similarity_category_count: 10)
          index_book(2, genre_category_ids: [G1], similarity_category_count: 40)
          index_book(3, genre_category_ids: [G1], similarity_category_count: 3)
          result = BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0})
          scores = result.to_h { |h| [h[:id], h[:score]] }
          assert_in_delta scores[1], scores[3], 0.001, "the floor clamps the thin book to the same denominator"
          assert_in_delta scores[1] / 2, scores[2], 0.001
        end

        test "returns the rank position from doc values" do
          index_book(1, genre_category_ids: [G1], ranked_position: 37)
          hit = BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0}).first
          assert_equal 37, hit[:rank_position]
        end

        test "an empty profile sends no query" do
          BookRecommendations.expects(:search).never
          assert_equal [], BookRecommendations.call(profile: profile(genres: []), criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS)
        end

        test "min_score drops weak matches" do
          index_book(1, genre_category_ids: [G1])
          assert_equal [], ids(min_score: 100)
        end

        test "ranked_only returns the filtered pool in rank order" do
          index_book(1, ranked_position: 30)
          index_book(2, ranked_position: 10)
          index_book(3, ranked_position: 20, provisional: true)
          index_book(4, ranked_position: 5)
          result = BookRecommendations.ranked_only(criteria: criteria, excluded_ids: [4], options: {candidate_size: 10})
          assert_equal [2, 1], result.map { |h| h[:id] }
          assert_equal 10, result.first[:rank_position]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/search/books/search/book_recommendations_test.rb`
Expected: FAIL with `NameError: uninitialized constant Search::Books::Search::BookRecommendations`.

- [ ] **Step 3: Implement the query class**

`app/lib/search/books/search/book_recommendations.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      # One OpenSearch query scoring ranked books against a user's taste profile
      # (spec §7). Hard constraints (the user's criteria, their shelf, provisional
      # books) live in filter/must_not and contribute no score; the profile's
      # categories are one boosted `term` clause EACH so shared categories add up
      # (a single `terms` clause would score once -- see BookSimilar for the
      # measurement); disliked categories and the opposite book type sit in a
      # `boosting` query's negative half so they scale a score down rather than
      # remove the book; and the sum is divided by sqrt(category count) with a
      # floor, exactly as BookSimilar does, so a heavily tagged book cannot win
      # by volume.
      class BookRecommendations < ::Search::Base::Search
        FIELDS = {"genre" => :genre_category_ids, "subject" => :subject_category_ids, "location" => :location_category_ids}.freeze
        MULTIPLIERS = {"genre" => :genre_multiplier, "subject" => :subject_multiplier, "location" => :location_multiplier}.freeze
        RANK_SORT = [{ranked_position: {order: "asc", missing: "_last"}}, {_id: {order: "asc"}}].freeze

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(profile:, criteria:, excluded_ids:, type_category_ids:, options: {})
          return [] if profile.empty?

          opts = Rails.application.config.x.recommendations.merge(options)
          extract(search(build_query_definition(profile: profile, criteria: criteria, excluded_ids: excluded_ids,
            type_category_ids: type_category_ids, opts: opts)))
        end

        # The same pool and constraints with no taste applied: the cold-start
        # fallback and the harness's rank baseline.
        def self.ranked_only(criteria:, excluded_ids:, options: {})
          opts = Rails.application.config.x.recommendations.merge(options)
          search_criteria = criteria.to_search_criteria
          extract(search({
            size: opts[:candidate_size],
            _source: false,
            docvalue_fields: ["ranked_position"],
            sort: RANK_SORT,
            query: {bool: {
              filter: CriteriaClauses.filter_clauses(search_criteria),
              must_not: CriteriaClauses.must_not_clauses(search_criteria, excluded_ids)
            }}
          }))
        end

        def self.build_query_definition(profile:, criteria:, excluded_ids:, type_category_ids:, opts:)
          search_criteria = criteria.to_search_criteria
          positive = {bool: {
            filter: CriteriaClauses.filter_clauses(search_criteria),
            must_not: CriteriaClauses.must_not_clauses(search_criteria, excluded_ids),
            should: should_clauses(profile, opts),
            # Explicit: a bool carrying a `filter` defaults its should-minimum to 0.
            minimum_should_match: 1
          }}

          negatives = negative_clauses(profile, type_category_ids, opts)
          query = if negatives.any?
            {boosting: {positive: positive, negative: {bool: {should: negatives, minimum_should_match: 1}},
                        negative_boost: opts[:negative_boost]}}
          else
            positive
          end

          {
            size: opts[:candidate_size],
            min_score: opts[:min_score],
            _source: false,
            docvalue_fields: ["ranked_position"],
            query: wrap_in_normalization(query, opts)
          }
        end

        def self.should_clauses(profile, opts)
          {"genre" => profile.genres, "subject" => profile.subjects, "location" => profile.locations}
            .flat_map do |type, pairs|
              pairs.map do |id, weight|
                {term: {FIELDS.fetch(type) => {value: id.to_s, boost: (weight * opts[MULTIPLIERS.fetch(type)]).round(4)}}}
              end
            end
        end

        # Demoted categories, plus the opposite book type when the reader's fiction
        # share is extreme. "Opposite AND not also ours" so books tagged both are
        # untouched -- the same shape as BookSimilar.opposite_type_clause.
        def self.negative_clauses(profile, type_category_ids, opts)
          clauses = profile.demoted.map { |id| {term: {category_ids: id.to_s}} }
          fiction = type_category_ids["Fiction"]
          nonfiction = type_category_ids["Nonfiction"]
          share = profile.fiction_share
          if fiction && nonfiction && share
            same, opposite = if share >= opts[:fiction_share_high]
              [fiction, nonfiction]
            elsif share <= opts[:fiction_share_low]
              [nonfiction, fiction]
            end
            if same
              clauses << {bool: {must: [{term: {genre_category_ids: opposite.to_s}}],
                                 must_not: [{term: {genre_category_ids: same.to_s}}]}}
            end
          end
          clauses
        end

        # Identical script to BookSimilar.wrap_in_normalization, including its
        # guards: a missing or zero count divides by 1, never by sqrt(0).
        def self.wrap_in_normalization(query, opts)
          {
            function_score: {
              query: query,
              script_score: {
                script: {
                  source: "def count = doc['similarity_category_count'].size() == 0 ? 1 : doc['similarity_category_count'].value; if (count < params.floor) { count = params.floor; } return _score / Math.sqrt(count < 1 ? 1 : count);",
                  params: {floor: opts[:normalization_floor].to_i}
                }
              },
              boost_mode: "replace"
            }
          }
        end

        def self.extract(response)
          response["hits"]["hits"].map do |hit|
            {id: hit["_id"].to_i, score: hit["_score"].to_f, rank_position: hit.dig("fields", "ranked_position")&.first}
          end
        end

        private_class_method :should_clauses, :negative_clauses, :wrap_in_normalization, :extract
      end
    end
  end
end
```

- [ ] **Step 4: Add the two adapter methods and their tests**

Append to `test/lib/recommendations/books/adapter_test.rb` (inside the class):

```ruby
      test "search_candidates maps hits to candidates with taste evidence" do
        ::Search::Books::Search::BookRecommendations.stubs(:call).returns([{id: 5, score: 2.5, rank_position: 12}])
        profile = Recommendations::Profile.new(genres: [[1, 1.0]], subjects: [], locations: [], demoted: [],
          fiction_share: nil, genre_distribution: {}, counts: {})
        candidates = @adapter.search_candidates(profile: profile, criteria: @adapter.criteria_for(@user), excluded_ids: [], size: 10)
        assert_equal [Recommendations::Candidate.new(item_id: 5, score: 2.5, rank_position: 12, evidence: {taste: true})], candidates
      end

      test "rank_ordered_candidates maps hits to candidates with empty evidence" do
        ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).returns([{id: 5, score: 0.0, rank_position: 1}])
        candidates = @adapter.rank_ordered_candidates(criteria: @adapter.criteria_for(@user), excluded_ids: [], size: 10)
        assert_equal({}, candidates.first.evidence)
        assert_equal 1, candidates.first.rank_position
      end
```

Add to the adapter (public section):

```ruby
      def search_candidates(profile:, criteria:, excluded_ids:, size:)
        ::Search::Books::Search::BookRecommendations.call(
          profile: profile, criteria: criteria, excluded_ids: excluded_ids, type_category_ids: type_category_ids,
          options: config.merge(candidate_size: size)
        ).map { |hit| Candidate.new(item_id: hit[:id], score: hit[:score], rank_position: hit[:rank_position], evidence: {taste: true}) }
      end

      def rank_ordered_candidates(criteria:, excluded_ids:, size:)
        ::Search::Books::Search::BookRecommendations.ranked_only(
          criteria: criteria, excluded_ids: excluded_ids, options: config.merge(candidate_size: size)
        ).map { |hit| Candidate.new(item_id: hit[:id], score: hit[:score], rank_position: hit[:rank_position], evidence: {}) }
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/search/books/search/book_recommendations_test.rb test/lib/recommendations/books/adapter_test.rb`
Expected: PASS. If "a high fiction share" fails because book 2 ties with book 3, that is fine as long as book 1 is last — the assertion only pins the demotion.

- [ ] **Step 6: Commit**

```bash
git add app/lib/search/books/search/book_recommendations.rb app/lib/recommendations/books/adapter.rb test/lib/search/books/search/book_recommendations_test.rb test/lib/recommendations/books/adapter_test.rb
git commit -m "Add the taste-profile OpenSearch query and adapter candidate methods"
```

---

### Task 8: Signals and fusion

**Files:**
- Create: `app/lib/recommendations/signals/base.rb`, `app/lib/recommendations/signals/taste_profile.rb`, `app/lib/recommendations/signals/rank_only.rb`, `app/lib/recommendations/signals/collaborative.rb`, `app/lib/recommendations/fusion.rb`
- Test: `test/lib/recommendations/signals_test.rb`, `test/lib/recommendations/fusion_test.rb`

**Interfaces:**
- Consumes: adapter (Task 5/7), `Profile`, `Candidate`, `Config`.
- Produces: every signal is `Signals::Base` with `initialize(adapter:, config:)`, `name` (Symbol), `available?`, `weight(positive_count)` → Float, `call(profile:, interactions:, criteria:, excluded_ids:, size:)` → `[Candidate]`. `Recommendations::Fusion.call(lists:, config:)` where `lists` is `[{weight: Float, candidates: [Candidate]}]` → `[Candidate]` sorted best first with `score` = fused score and `evidence` merged across lists.

- [ ] **Step 1: Write the failing tests**

`test/lib/recommendations/signals_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class SignalsTest < ActiveSupport::TestCase
    def setup
      @adapter = mock("adapter")
      @config = Config.resolve
      @criteria = ::Books::RecommendationCriteria.new({})
      @profile = Profile.new(genres: [[1, 2.0]], subjects: [], locations: [], demoted: [], fiction_share: nil,
        genre_distribution: {}, counts: {})
      @empty = Profile.new(genres: [], subjects: [], locations: [], demoted: [], fiction_share: nil,
        genre_distribution: {}, counts: {})
    end

    def call(signal, profile: @profile)
      signal.call(profile: profile, interactions: [], criteria: @criteria, excluded_ids: [7], size: 50)
    end

    test "taste profile delegates to the adapter and is empty for an empty profile" do
      signal = Signals::TasteProfile.new(adapter: @adapter, config: @config)
      @adapter.expects(:search_candidates).with(profile: @profile, criteria: @criteria, excluded_ids: [7], size: 50)
        .returns([Candidate.new(item_id: 1, score: 1.0, rank_position: nil, evidence: {taste: true})])
      assert_equal [1], call(signal).map(&:item_id)
      assert_equal [], call(signal, profile: @empty)
      assert signal.available?
      assert_equal 1.0, signal.weight(3)
      assert_equal :taste_profile, signal.name
    end

    test "rank only delegates to the adapter regardless of profile" do
      signal = Signals::RankOnly.new(adapter: @adapter, config: @config)
      @adapter.expects(:rank_ordered_candidates).with(criteria: @criteria, excluded_ids: [7], size: 50)
        .returns([Candidate.new(item_id: 2, score: 0.0, rank_position: 1, evidence: {})])
      assert_equal [2], call(signal, profile: @empty).map(&:item_id)
    end

    test "collaborative is unavailable, returns nothing, and its weight ramps with history" do
      signal = Signals::Collaborative.new(adapter: @adapter, config: @config)
      assert_not signal.available?
      assert_equal [], call(signal)
      assert_in_delta 0.0, signal.weight(0), 0.001
      assert_in_delta 0.5, signal.weight(10), 0.001
      assert_in_delta 200.0 / 210, signal.weight(200), 0.001
    end
  end
end
```

`test/lib/recommendations/fusion_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class FusionTest < ActiveSupport::TestCase
    def cand(id, rank: nil, evidence: {})
      Candidate.new(item_id: id, score: 1.0, rank_position: rank, evidence: evidence)
    end

    def fuse(lists, **overrides)
      Fusion.call(lists: lists, config: Config.resolve({rank_prior_weight: 0.0}.merge(overrides)))
    end

    test "reciprocal rank fusion sums weight over k plus rank" do
      fused = fuse([
        {weight: 1.0, candidates: [cand(1), cand(2)]},
        {weight: 0.5, candidates: [cand(2), cand(3)]}
      ])
      assert_equal [2, 1, 3], fused.map(&:item_id)
      assert_in_delta 1.0 / 62 + 0.5 / 61, fused.first.score, 1e-9
    end

    test "a zero-weight list contributes nothing" do
      fused = fuse([{weight: 1.0, candidates: [cand(1)]}, {weight: 0.0, candidates: [cand(2), cand(3)]}])
      assert_equal [1, 2, 3], fused.map(&:item_id)
      assert_in_delta 0.0, fused.last.score, 1e-12
    end

    test "the rank prior re-orders ties toward the better global rank" do
      fused = fuse([{weight: 1.0, candidates: [cand(1, rank: 500)]}, {weight: 1.0, candidates: [cand(2, rank: 5)]}],
        rank_prior_weight: 0.3)
      assert_equal [2, 1], fused.map(&:item_id)
    end

    test "the rank prior never outweighs a clear personalized preference" do
      fused = fuse([{weight: 1.0, candidates: [cand(1, rank: 9000), cand(3), cand(4), cand(2, rank: 1)]}], rank_prior_weight: 0.3)
      assert_equal 1, fused.first.item_id, "three places of taste ordering beat a 0.3-weight prior"
    end

    test "evidence is merged across lists" do
      fused = fuse([
        {weight: 1.0, candidates: [cand(1, evidence: {taste: true})]},
        {weight: 1.0, candidates: [cand(1, evidence: {because_of: 9})]}
      ])
      assert_equal({taste: true, because_of: 9}, fused.first.evidence)
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/recommendations/signals_test.rb test/lib/recommendations/fusion_test.rb`
Expected: FAIL with `NameError` for `Signals` and `Fusion`.

- [ ] **Step 3: Implement the signals**

`app/lib/recommendations/signals/base.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Signals
    # The contract every candidate source honours (spec §5.3). Signals never see
    # each other; fusion is the only place their lists meet.
    class Base
      attr_reader :adapter, :config

      def initialize(adapter:, config:)
        @adapter = adapter
        @config = config
      end

      def name
        self.class.name.demodulize.underscore.to_sym
      end

      def available?
        true
      end

      def weight(_positive_count)
        raise NotImplementedError
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        raise NotImplementedError
      end
    end
  end
end
```

`app/lib/recommendations/signals/taste_profile.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Signals
    class TasteProfile < Base
      def weight(_positive_count)
        config[:taste_weight].to_f
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        return [] if profile.empty?

        adapter.search_candidates(profile: profile, criteria: criteria, excluded_ids: excluded_ids, size: size)
      end
    end
  end
end
```

`app/lib/recommendations/signals/rank_only.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Signals
    # The candidate pool in global-rank order: the engine's fallback when the
    # profile is empty, and the harness's rank baseline. Never fused with the
    # personalized signals -- the rank prior inside Fusion is how rank enters
    # a personalized page.
    class RankOnly < Base
      def weight(_positive_count)
        1.0
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        adapter.rank_ordered_candidates(criteria: criteria, excluded_ids: excluded_ids, size: size)
      end
    end
  end
end
```

`app/lib/recommendations/signals/collaborative.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Signals
    # Readers-like-you. Spec 2 fills this in from the home-server model tables;
    # until then it is unavailable and contributes nothing. The weight ramp is
    # defined here already so fusion needs no change when it arrives.
    class Collaborative < Base
      def available?
        false
      end

      def weight(positive_count)
        n = positive_count.to_f
        n / (n + config[:collaborative_half_point])
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        []
      end
    end
  end
end
```

- [ ] **Step 4: Implement fusion**

`app/lib/recommendations/fusion.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # Weighted reciprocal-rank fusion (spec §5.4): fused = Σ w / (k + rank), rank
  # 1-based within each list. Rank-based on purpose so the OpenSearch scale and
  # (later) the collaborative scale never need reconciling. The global rank is a
  # third list built from the fused items themselves, so it can re-order what the
  # personalized signals surfaced but never introduce a book.
  class Fusion
    def self.call(lists:, config:)
      new(lists: lists, config: config).call
    end

    def initialize(lists:, config:)
      @lists = lists
      @k = config[:rrf_k].to_f
      @prior_weight = config[:rank_prior_weight].to_f
    end

    def call
      scores = Hash.new(0.0)
      merged = {}

      @lists.each do |list|
        weight = list[:weight].to_f
        list[:candidates].each_with_index do |candidate, index|
          merged[candidate.item_id] ||= Candidate.new(item_id: candidate.item_id, score: 0.0,
            rank_position: candidate.rank_position, evidence: {})
          merged[candidate.item_id].rank_position ||= candidate.rank_position
          merged[candidate.item_id].evidence.merge!(candidate.evidence || {})
          scores[candidate.item_id] += weight / (@k + index + 1) if weight.positive?
        end
      end

      apply_rank_prior(merged, scores) if @prior_weight.positive?

      merged.values.each { |c| c.score = scores[c.item_id] }
        .sort_by { |c| [-c.score, c.item_id] }
    end

    private

    def apply_rank_prior(merged, scores)
      merged.values.reject { |c| c.rank_position.nil? }
        .sort_by { |c| [c.rank_position, c.item_id] }
        .each_with_index { |c, index| scores[c.item_id] += @prior_weight / (@k + index + 1) }
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/recommendations/signals_test.rb test/lib/recommendations/fusion_test.rb`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add app/lib/recommendations/signals app/lib/recommendations/fusion.rb test/lib/recommendations/signals_test.rb test/lib/recommendations/fusion_test.rb
git commit -m "Add recommendation signals and rank fusion"
```

---

### Task 9: Re-ranker passes

**Files:**
- Create: `app/lib/recommendations/reranker/author_cap.rb`, `app/lib/recommendations/reranker/series_rule.rb`, `app/lib/recommendations/reranker/genre_calibration.rb`
- Test: `test/lib/recommendations/reranker_test.rb`

**Interfaces:**
- Consumes: `Candidate`, `ItemFact`, `Interaction`, `Config`.
- Produces: `Reranker::AuthorCap.call(candidates, facts:, config:)` → `[Candidate]`; `Reranker::SeriesRule.call(candidates, facts:, interactions:)` → `[Candidate]`; `Reranker::GenreCalibration.call(candidates, facts:, history:, limit:, config:)` → `[Candidate]` of at most `limit`. `facts` is `{item_id => ItemFact}`; `history` is `Profile#genre_distribution`.

- [ ] **Step 1: Write the failing tests**

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class RerankerTest < ActiveSupport::TestCase
    def cand(id, score: 1.0)
      Candidate.new(item_id: id, score: score, rank_position: nil, evidence: {})
    end

    def fact(authors: [], genres: [], predecessor: nil)
      ItemFact.new(author_ids: authors, genre_ids: genres, series_predecessor_id: predecessor, rank_position: nil)
    end

    test "author cap keeps the first max_per_author books per author and skips the rest" do
      facts = {1 => fact(authors: [7]), 2 => fact(authors: [7]), 3 => fact(authors: [8]), 4 => fact(authors: [7, 8])}
      kept = Reranker::AuthorCap.call([cand(1), cand(2), cand(3), cand(4)], facts: facts, config: Config.resolve(max_per_author: 1))
      assert_equal [1, 3], kept.map(&:item_id), "4 is skipped because both its authors are already at the cap"
    end

    test "author cap passes books with no known author" do
      kept = Reranker::AuthorCap.call([cand(1), cand(2)], facts: {1 => fact, 2 => fact}, config: Config.resolve(max_per_author: 1))
      assert_equal [1, 2], kept.map(&:item_id)
    end

    test "series rule drops a sequel unless the predecessor is a favorite, read, reading, or rated book" do
      facts = {10 => fact(predecessor: 1), 11 => fact(predecessor: 2), 12 => fact(predecessor: 3), 13 => fact(predecessor: 4), 14 => fact}
      interactions = [
        Interaction.new(item_id: 1, weight: 2.0, kind: :favorite, rating: nil),
        Interaction.new(item_id: 2, weight: 0.2, kind: :want_to_read, rating: nil),
        Interaction.new(item_id: 3, weight: 0.0, kind: :review, rating: 3)
      ]
      kept = Reranker::SeriesRule.call([cand(10), cand(11), cand(12), cand(13), cand(14)], facts: facts, interactions: interactions)
      assert_equal [10, 12, 14], kept.map(&:item_id), "11's predecessor is only wanted; 13's is unknown"
    end

    test "genre calibration pulls an under-represented genre into the page" do
      a_books = (1..10).map { |i| cand(i, score: 11 - i) }
      b_books = (11..15).map { |i| cand(i, score: (16 - i) / 10.0) }
      facts = (1..10).to_h { |i| [i, fact(genres: [100])] }.merge((11..15).to_h { |i| [i, fact(genres: [200])] })
      history = {100 => 0.7, 200 => 0.3}

      page = Reranker::GenreCalibration.call(a_books + b_books, facts: facts, history: history, limit: 10, config: Config.resolve)
      assert_equal 10, page.size
      assert_equal 1, page.first.item_id, "the strongest book still leads"
      assert_operator page.count { |c| c.item_id > 10 }, :>=, 1

      off = Reranker::GenreCalibration.call(a_books + b_books, facts: facts, history: history, limit: 10, config: Config.resolve(calibrate_genres: false))
      assert_equal (1..10).to_a, off.map(&:item_id)
    end

    test "genre calibration is a no-op for an empty history and returns at most limit" do
      page = Reranker::GenreCalibration.call([cand(1), cand(2), cand(3)], facts: {}, history: {}, limit: 2, config: Config.resolve)
      assert_equal [1, 2], page.map(&:item_id)
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/recommendations/reranker_test.rb`
Expected: FAIL with `NameError: uninitialized constant Recommendations::Reranker`.

- [ ] **Step 3: Implement the three passes**

`app/lib/recommendations/reranker/author_cap.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Reranker
    # At most max_per_author books per author, in fused order. Skipped, not
    # demoted: an author's other books genuinely score well, and only a cap
    # stops them filling the page (same reasoning as Services::Books::SimilarBooks).
    module AuthorCap
      def self.call(candidates, facts:, config:)
        max = config[:max_per_author].to_i
        counts = Hash.new(0)
        candidates.select do |candidate|
          authors = facts[candidate.item_id]&.author_ids || []
          next true if authors.empty?
          next false if authors.any? { |id| counts[id] >= max }

          authors.each { |id| counts[id] += 1 }
          true
        end
      end
    end
  end
end
```

`app/lib/recommendations/reranker/series_rule.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Reranker
    # A sequel is recommended only to someone who has the preceding book as a
    # favorite, read, reading, or rated (spec §8.1). Want-to-read does not unlock
    # it: intent is not experience. Dropping the sequel leaves the series opener
    # in place when it is itself a candidate.
    module SeriesRule
      UNLOCKING_KINDS = %i[favorite read reading].freeze

      def self.call(candidates, facts:, interactions:)
        unlocked = interactions.select { |i| UNLOCKING_KINDS.include?(i.kind) || !i.rating.nil? }
          .map(&:item_id).to_set

        candidates.select do |candidate|
          predecessor = facts[candidate.item_id]&.series_predecessor_id
          predecessor.nil? || unlocked.include?(predecessor)
        end
      end
    end
  end
end
```

`app/lib/recommendations/reranker/genre_calibration.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  module Reranker
    # Greedy calibrated selection (Steck 2018; spec §8.1): pick the next book that
    # maximises (1 - λ) · relevance - λ · KL(history ‖ page), where both
    # distributions are over genre ids and each book spreads 1 evenly over its
    # genres. The page distribution is smoothed toward the history by α so KL is
    # finite for a genre the page does not yet carry. Relevance is the fused
    # score divided by the best fused score, so λ means the same thing whatever
    # scale fusion produced.
    module GenreCalibration
      def self.call(candidates, facts:, history:, limit:, config:)
        return candidates.first(limit) if !config[:calibrate_genres] || history.empty? || candidates.empty?

        lambda_ = config[:calibration_lambda].to_f
        alpha = config[:calibration_alpha].to_f
        best = candidates.map(&:score).max
        best = 1.0 unless best&.positive?

        remaining = candidates.dup
        selected = []
        page_mass = Hash.new(0.0)

        while selected.size < limit && remaining.any?
          pick = remaining.max_by.with_index do |candidate, index|
            relevance = candidate.score / best
            kl = kl_after_adding(page_mass, selected.size, genres_of(candidate, facts), history, alpha)
            [(1 - lambda_) * relevance - lambda_ * kl, -index]
          end
          selected << pick
          remaining.delete(pick)
          add_genres(page_mass, genres_of(pick, facts))
        end
        selected
      end

      def self.genres_of(candidate, facts)
        facts[candidate.item_id]&.genre_ids || []
      end

      def self.add_genres(page_mass, genres)
        return if genres.empty?

        genres.each { |g| page_mass[g] += 1.0 / genres.size }
      end

      # KL(history ‖ smoothed page) if `genres` were added to the page.
      def self.kl_after_adding(page_mass, selected_count, genres, history, alpha)
        trial = page_mass.dup
        genres.each { |g| trial[g] += 1.0 / genres.size } if genres.any?
        total = trial.values.sum
        return 0.0 if total <= 0

        history.sum do |genre, p|
          q = trial.fetch(genre, 0.0) / total
          q_smoothed = (1 - alpha) * q + alpha * p
          p * Math.log(p / q_smoothed)
        end
      end

      private_class_method :genres_of, :add_genres, :kl_after_adding
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/recommendations/reranker_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/recommendations/reranker test/lib/recommendations/reranker_test.rb
git commit -m "Add author cap, series rule and genre calibration re-ranking"
```

---

### Task 10: Explainer and Engine

**Files:**
- Create: `app/lib/recommendations/explainer.rb`, `app/lib/recommendations/engine.rb`
- Test: `test/lib/recommendations/explainer_test.rb`, `test/lib/recommendations/engine_test.rb`

**Interfaces:**
- Consumes: everything above.
- Produces: `Recommendations::Explainer.call(candidate:, profile:, categories:, config:)` → `Reason` (`categories` is the `[CategoryFact]` for that item). `Recommendations::Engine.call(user:, domain:, limit:, overrides: {}, adapter: nil, interactions: nil, excluded_ids: nil)` → `Result(success?, data, errors)` with `data = {items: [{item:, item_id:, rank:, score:, reason:}], profile: Profile, signals_used: [Symbol], fallback: Boolean}`. `Engine::Result` is the Result struct. The `adapter:`, `interactions:`, `excluded_ids:` keywords exist for tests and the harness (hold-out evaluation injects a reduced interaction set without hiding the held-out books from the candidate pool).

- [ ] **Step 1: Write the failing explainer test**

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ExplainerTest < ActiveSupport::TestCase
    def setup
      @profile = Profile.new(genres: [[10, 2.5], [11, 0.4]], subjects: [[20, 1.8]], locations: [], demoted: [],
        fiction_share: nil, genre_distribution: {}, counts: {})
      @config = Config.resolve
    end

    def fact(id, type = "genre")
      CategoryFact.new(id: id, category_type: type, item_count: 1)
    end

    def explain(evidence: {taste: true}, categories: [], rank: 37)
      Explainer.call(candidate: Candidate.new(item_id: 1, score: 1.0, rank_position: rank, evidence: evidence),
        profile: @profile, categories: categories, config: @config)
    end

    test "because_of wins when the collaborative evidence names a book" do
      assert_equal Reason.new(type: :because_of, ids: [99]), explain(evidence: {because_of: 99}, categories: [fact(10)])
    end

    test "interests names the two strongest profile categories above the threshold" do
      reason = explain(categories: [fact(11), fact(20, "subject"), fact(10), fact(30)])
      assert_equal Reason.new(type: :interests, ids: [10, 20]), reason, "11 is below explain_threshold; 30 is not in the profile"
    end

    test "falls back to the rank when no category clears the threshold" do
      assert_equal Reason.new(type: :ranked, ids: [37]), explain(categories: [fact(11)])
      assert_equal Reason.new(type: :ranked, ids: []), explain(categories: [], rank: nil)
    end
  end
end
```

- [ ] **Step 2: Write the failing engine test**

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class EngineTest < ActiveSupport::TestCase
    Item = Struct.new(:id)

    # A complete in-memory adapter so the engine's orchestration is tested
    # without Postgres or OpenSearch. Every public adapter method is here.
    class FakeAdapter
      attr_reader :calls

      def initialize(config:, interactions: [], categories: {}, candidates: [], ranked: [], facts: {}, raise_search: false, raise_ranked: false)
        @config = config
        @interactions = interactions
        @categories = categories
        @candidates = candidates
        @ranked = ranked
        @facts = facts
        @raise_search = raise_search
        @raise_ranked = raise_ranked
        @calls = []
      end

      def interactions(_user) = @interactions

      def shelved_item_ids(_user) = @interactions.map(&:item_id)

      def categories_for(ids) = @categories.slice(*ids)

      def catalog_size = 1000

      def type_category_ids = {"Fiction" => 1, "Nonfiction" => 2}

      def criteria_for(_user) = ::Books::RecommendationCriteria.new({})

      def search_candidates(**args)
        @calls << [:search, args]
        raise "opensearch down" if @raise_search

        @candidates
      end

      def rank_ordered_candidates(**args)
        @calls << [:ranked, args]
        raise "opensearch down" if @raise_ranked

        @ranked
      end

      def item_facts(ids)
        ids.index_with { |id| @facts[id] || ItemFact.new(author_ids: [], genre_ids: [], series_predecessor_id: nil, rank_position: nil) }
      end

      def load_items(ids) = ids.index_with { |id| Item.new(id) }
    end

    RARE = 50

    def fact(id, type = "genre", count = 6)
      CategoryFact.new(id: id, category_type: type, item_count: count)
    end

    def setup
      @user = users(:regular_user)
      @interactions = (1..6).map { |i| Interaction.new(item_id: i, weight: 2.0, kind: :favorite, rating: nil) }
      @categories = (1..6).to_h { |i| [i, [fact(RARE)]] }.merge(101 => [fact(RARE)], 102 => [fact(RARE)], 103 => [fact(60)])
      @candidates = [101, 102, 103].map { |id| Candidate.new(item_id: id, score: 3.0 - id % 100 / 10.0, rank_position: id, evidence: {taste: true}) }
    end

    def engine(limit: 10, overrides: {}, **adapter_args)
      adapter = FakeAdapter.new(config: Config.resolve(overrides),
        **{interactions: @interactions, categories: @categories, candidates: @candidates}.merge(adapter_args))
      [Engine.call(user: @user, domain: :books, limit: limit, overrides: overrides, adapter: adapter), adapter]
    end

    test "returns fused candidates in order with reasons and the profile" do
      result, = engine
      assert result.success?
      assert_equal [101, 102, 103], result.data[:items].map { |i| i[:item_id] }
      assert_equal [1, 2, 3], result.data[:items].map { |i| i[:rank] }
      assert_equal :interests, result.data[:items].first[:reason].type
      assert_equal [RARE], result.data[:items].first[:reason].ids
      assert_equal :ranked, result.data[:items].last[:reason].type
      assert_equal [:taste_profile], result.data[:signals_used]
      assert_not result.data[:fallback]
      assert_operator result.data[:profile].weight_for(RARE), :>, 0
      assert_kind_of Item, result.data[:items].first[:item]
    end

    test "respects the limit" do
      result, = engine(limit: 2)
      assert_equal 2, result.data[:items].size
    end

    test "passes the shelved ids as exclusions to the signal" do
      _, adapter = engine
      assert_equal (1..6).to_a, adapter.calls.find { |name, _| name == :search }.last[:excluded_ids]
    end

    test "falls back to rank-only when the profile is empty" do
      wanted = [Interaction.new(item_id: 1, weight: 0.2, kind: :want_to_read, rating: nil)]
      ranked = [Candidate.new(item_id: 7, score: 0.0, rank_position: 1, evidence: {})]
      result, adapter = engine(interactions: wanted, categories: {}, ranked: ranked)
      assert_equal [7], result.data[:items].map { |i| i[:item_id] }
      assert_equal Reason.new(type: :ranked, ids: [1]), result.data[:items].first[:reason]
      assert result.data[:fallback]
      assert_equal [], result.data[:signals_used]
      assert_nil adapter.calls.find { |name, _| name == :search }, "an empty profile sends no taste query"
    end

    test "a signal that raises is dropped, not fatal" do
      ranked = [Candidate.new(item_id: 7, score: 0.0, rank_position: 1, evidence: {})]
      result, = engine(raise_search: true, ranked: ranked)
      assert result.success?
      assert result.data[:fallback]
      assert_equal [7], result.data[:items].map { |i| i[:item_id] }
    end

    test "returns an empty success when every signal and the fallback fail" do
      result, = engine(raise_search: true, raise_ranked: true)
      assert result.success?
      assert_equal [], result.data[:items]
      assert_equal [], result.data[:signals_used]
    end

    test "applies the author cap and series rule" do
      facts = {101 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: nil, rank_position: 101),
               102 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: nil, rank_position: 102),
               103 => ItemFact.new(author_ids: [], genre_ids: [], series_predecessor_id: 999, rank_position: 103)}
      result, = engine(overrides: {max_per_author: 1}, facts: facts)
      assert_equal [101], result.data[:items].map { |i| i[:item_id] }
    end

    test "injected interactions and exclusions replace the adapter's (harness hold-out)" do
      held_out = Interaction.new(item_id: 101, weight: 2.0, kind: :favorite, rating: nil)
      adapter = FakeAdapter.new(config: Config.resolve, interactions: @interactions + [held_out],
        categories: @categories, candidates: @candidates)
      Engine.call(user: @user, domain: :books, limit: 10, adapter: adapter,
        interactions: @interactions, excluded_ids: (1..6).to_a)
      assert_equal (1..6).to_a, adapter.calls.find { |name, _| name == :search }.last[:excluded_ids]
    end

    test "an unregistered domain is a failure" do
      result = Engine.call(user: @user, domain: :music, limit: 10)
      assert_not result.success?
      assert_includes result.errors.first, "music"
    end
  end
end
```

- [ ] **Step 3: Run both to verify they fail**

Run: `bin/rails test test/lib/recommendations/explainer_test.rb test/lib/recommendations/engine_test.rb`
Expected: FAIL with `NameError` for `Explainer` and `Engine`.

- [ ] **Step 4: Implement the explainer**

`app/lib/recommendations/explainer.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # One reason per recommended item (spec §8.3), most persuasive first:
  # because_of (collaborative evidence), interests (the two strongest profile
  # categories the item carries, above explain_threshold so "Fiction" is never
  # the reason), then the global rank.
  module Explainer
    def self.call(candidate:, profile:, categories:, config:)
      because_of = candidate.evidence&.dig(:because_of)
      return Reason.new(type: :because_of, ids: [because_of]) if because_of

      threshold = config[:explain_threshold].to_f
      interests = categories
        .filter_map { |fact| (w = profile.weight_for(fact.id)) && w >= threshold ? [fact.id, w] : nil }
        .sort_by { |id, w| [-w, id] }
        .first(2)
        .map(&:first)
      return Reason.new(type: :interests, ids: interests) if interests.any?

      Reason.new(type: :ranked, ids: [candidate.rank_position].compact)
    end
  end
end
```

- [ ] **Step 5: Implement the engine**

`app/lib/recommendations/engine.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # The pipeline (spec §5): interactions -> profile -> signals -> fusion ->
  # re-ranking -> explanations. Domain-agnostic: every domain fact comes through
  # the adapter the registry resolves. A signal that raises is logged and
  # dropped; if nothing is left, the rank-only fallback fills the page; if that
  # fails too, the result is an empty success (the page shows "unavailable",
  # never a 500).
  class Engine
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    PERSONALIZED_SIGNALS = [Signals::TasteProfile, Signals::Collaborative].freeze

    def self.call(**args)
      new(**args).call
    end

    def initialize(user:, domain:, limit:, overrides: {}, adapter: nil, interactions: nil, excluded_ids: nil)
      @user = user
      @domain = domain
      @limit = limit.to_i
      @config = Config.resolve(overrides)
      @adapter = adapter
      @interactions_override = interactions
      @excluded_override = excluded_ids
    end

    def call
      adapter = resolve_adapter
      return Result.new(success?: false, data: nil, errors: ["no recommendation adapter for domain #{@domain}"]) if adapter.nil?

      interactions = @interactions_override || adapter.interactions(@user)
      excluded_ids = @excluded_override || adapter.shelved_item_ids(@user)
      criteria = adapter.criteria_for(@user)
      profile = build_profile(adapter, interactions)
      size = @config[:candidate_size]

      lists, signals_used = run_signals(adapter, profile, interactions, criteria, excluded_ids, size)
      fallback = lists.empty?
      fused = if fallback
        run_fallback(adapter, profile, interactions, criteria, excluded_ids, size)
      else
        Fusion.call(lists: lists, config: @config)
      end

      page = rerank(adapter, fused, interactions, profile)
      Result.new(success?: true, errors: [], data: {
        items: build_items(adapter, page, profile),
        profile: profile,
        signals_used: signals_used,
        fallback: fallback
      })
    end

    private

    def resolve_adapter
      return @adapter if @adapter

      klass = Registry.adapter_class_for(@domain)
      klass&.new(config: @config)
    end

    def build_profile(adapter, interactions)
      ProfileBuilder.call(
        interactions: interactions,
        categories: adapter.categories_for(interactions.map(&:item_id)),
        catalog_size: adapter.catalog_size,
        type_category_ids: adapter.type_category_ids,
        config: @config
      )
    end

    def run_signals(adapter, profile, interactions, criteria, excluded_ids, size)
      positive_count = profile.counts[:positive].to_i
      lists = []
      used = []
      PERSONALIZED_SIGNALS.each do |klass|
        signal = klass.new(adapter: adapter, config: @config)
        next unless signal.available?

        candidates = guarded(signal.name) do
          signal.call(profile: profile, interactions: interactions, criteria: criteria, excluded_ids: excluded_ids, size: size)
        end
        next if candidates.blank?

        lists << {weight: signal.weight(positive_count), candidates: candidates}
        used << signal.name
      end
      [lists, used]
    end

    def run_fallback(adapter, profile, interactions, criteria, excluded_ids, size)
      signal = Signals::RankOnly.new(adapter: adapter, config: @config)
      guarded(signal.name) do
        signal.call(profile: profile, interactions: interactions, criteria: criteria, excluded_ids: excluded_ids, size: size)
      end || []
    end

    def rerank(adapter, fused, interactions, profile)
      return [] if fused.empty?

      facts = adapter.item_facts(fused.map(&:item_id))
      page = Reranker::AuthorCap.call(fused, facts: facts, config: @config)
      page = Reranker::SeriesRule.call(page, facts: facts, interactions: interactions)
      Reranker::GenreCalibration.call(page, facts: facts, history: profile.genre_distribution, limit: @limit, config: @config)
    end

    def build_items(adapter, page, profile)
      return [] if page.empty?

      ids = page.map(&:item_id)
      items = adapter.load_items(ids)
      categories = adapter.categories_for(ids)
      page.filter_map.with_index do |candidate, index|
        item = items[candidate.item_id]
        next if item.nil?

        {
          item: item,
          item_id: candidate.item_id,
          rank: index + 1,
          score: candidate.score,
          reason: Explainer.call(candidate: candidate, profile: profile, categories: categories.fetch(candidate.item_id, []), config: @config)
        }
      end
    end

    # Class and a short backtrace, as SimilarBooks logs, so a genuine bug in a
    # signal is distinguishable from an OpenSearch outage.
    def guarded(signal_name)
      yield
    rescue => e
      Rails.logger.error "Recommendations signal #{signal_name} failed for user #{@user&.id}: #{e.class}: #{e.message} #{e.backtrace&.first(5)&.join(" | ")}"
      nil
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/recommendations/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; "All is good!". The `rank` after `build_items` is the page position (1-based), which the first engine test pins as `[1, 2, 3]`; `item_fact.rank_position` is the global rank and lives on the candidate.

- [ ] **Step 7: Commit**

```bash
git add app/lib/recommendations/explainer.rb app/lib/recommendations/engine.rb test/lib/recommendations/explainer_test.rb test/lib/recommendations/engine_test.rb
git commit -m "Add the recommendation engine and explainer"
```

---

### Task 11: The harness — `recommendations:show` and `recommendations:eval`

**Files:**
- Create: `lib/tasks/recommendations.rake`, `app/lib/recommendations/evaluation.rb`
- Test: `test/lib/recommendations/evaluation_test.rb`

**Interfaces:**
- Consumes: `Engine`, `Registry`, `Config`, adapter.
- Produces: `Recommendations::Evaluation` with pure, testable pieces: `Evaluation.split(interactions, fraction:, random:)` → `[train, held_out]`; `Evaluation.metrics(page_ids:, held_out_ids:, k_hit: 10, k_recall: 50)` → `{hit: 0|1, recall: Float, ndcg: Float}`; `Evaluation.genre_kl(history:, page_genres:, alpha:)` → Float; `Evaluation.sample_user_ids(domain:, per_segment:, random:)` → `{segment_label => [user_id]}`. The rake tasks print; they contain no logic of their own beyond formatting.

- [ ] **Step 1: Write the failing tests for the pure pieces**

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class EvaluationTest < ActiveSupport::TestCase
    def interaction(id, kind: :favorite, rating: nil, weight: 2.0)
      Interaction.new(item_id: id, weight: weight, kind: kind, rating: rating)
    end

    test "split holds out a fifth of favorites and 4-plus ratings, never read-only books" do
      ints = (1..10).map { |i| interaction(i) } + [interaction(11, kind: :read, weight: 0.4), interaction(12, kind: :review, rating: 3, weight: 0.0)]
      train, held = Evaluation.split(ints, fraction: 0.2, random: Random.new(1))
      assert_equal 2, held.size
      assert held.all? { |i| i.kind == :favorite }
      assert_equal ints.size - 2, train.size
      assert_empty train.map(&:item_id) & held.map(&:item_id)
    end

    test "split is deterministic for a seed" do
      ints = (1..10).map { |i| interaction(i) }
      a = Evaluation.split(ints, fraction: 0.2, random: Random.new(7)).last.map(&:item_id)
      b = Evaluation.split(ints, fraction: 0.2, random: Random.new(7)).last.map(&:item_id)
      assert_equal a, b
    end

    test "metrics: hit, recall and ndcg" do
      m = Evaluation.metrics(page_ids: [5, 1, 9, 2] + (20..70).to_a, held_out_ids: [1, 2, 3])
      assert_equal 1, m[:hit]
      assert_in_delta 2.0 / 3, m[:recall], 1e-9
      dcg = 1 / Math.log2(3) + 1 / Math.log2(5)
      idcg = 1 / Math.log2(2) + 1 / Math.log2(3) + 1 / Math.log2(4)
      assert_in_delta dcg / idcg, m[:ndcg], 1e-9
    end

    test "metrics: no hits" do
      m = Evaluation.metrics(page_ids: [5, 6], held_out_ids: [1])
      assert_equal({hit: 0, recall: 0.0, ndcg: 0.0}, m)
    end

    test "genre_kl is zero for a matching mix and positive for a skewed one" do
      history = {1 => 0.5, 2 => 0.5}
      assert_in_delta 0.0, Evaluation.genre_kl(history: history, page_genres: [[1], [2]], alpha: 0.01), 1e-9
      assert_operator Evaluation.genre_kl(history: history, page_genres: [[1], [1], [1]], alpha: 0.01), :>, 0.5
    end

    test "sample_user_ids buckets books users by positive list items" do
      # regular_user has 3 books items in the fixtures (2 favorites, 1 read) -> below every segment.
      user = User.create!(email: "heavy@example.com")
      list = user.default_user_list_for(::Books::UserList, :read)
      5.times { |i| list.user_list_items.create!(listable: ::Books::Book.create!(title: "B#{i}")) }
      sample = Evaluation.sample_user_ids(domain: :books, per_segment: 10, random: Random.new(1))
      assert_equal [user.id], sample["5-19"]
      assert_equal [], sample["20-99"]
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/recommendations/evaluation_test.rb`
Expected: FAIL with `NameError: uninitialized constant Recommendations::Evaluation`.

- [ ] **Step 3: Implement `Evaluation`**

`app/lib/recommendations/evaluation.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # The offline evaluation's arithmetic (spec §9.1), kept out of the rake task
  # so it is unit-tested. Hold-out: hide a fraction of the user's favorites and
  # 4-plus ratings, recommend from the rest, and see whether the hidden books
  # come back. The rake task owns sampling at scale, timing, and printing.
  module Evaluation
    SEGMENTS = {"5-19" => (5..19), "20-99" => (20..99), "100+" => (100..)}.freeze
    HOLD_OUT_RATING = 4

    module_function

    def eligible?(interaction)
      interaction.kind == :favorite || (interaction.rating && interaction.rating >= HOLD_OUT_RATING)
    end

    def split(interactions, fraction:, random:)
      eligible = interactions.select { |i| eligible?(i) }
      count = (eligible.size * fraction).ceil
      held = eligible.sort_by(&:item_id).shuffle(random: random).first(count)
      held_ids = held.map(&:item_id).to_set
      [interactions.reject { |i| held_ids.include?(i.item_id) }, held]
    end

    def metrics(page_ids:, held_out_ids:, k_hit: 10, k_recall: 50)
      held = held_out_ids.to_set
      top = page_ids.first(k_recall)
      hits = top.each_index.select { |i| held.include?(top[i]) }
      dcg = hits.sum { |i| 1.0 / Math.log2(i + 2) }
      ideal = [held.size, k_recall].min
      idcg = (0...ideal).sum { |i| 1.0 / Math.log2(i + 2) }
      {
        hit: page_ids.first(k_hit).any? { |id| held.include?(id) } ? 1 : 0,
        recall: held.empty? ? 0.0 : hits.size.to_f / held.size,
        ndcg: idcg.zero? ? 0.0 : dcg / idcg
      }
    end

    # KL(history ‖ smoothed page) over genre ids; page_genres is one array of
    # genre ids per recommended item. Same smoothing as GenreCalibration.
    def genre_kl(history:, page_genres:, alpha:)
      mass = Hash.new(0.0)
      page_genres.each { |genres| genres.each { |g| mass[g] += 1.0 / genres.size } if genres.any? }
      total = mass.values.sum
      return 0.0 if total <= 0 || history.empty?

      history.sum do |genre, p|
        q = mass.fetch(genre, 0.0) / total
        p * Math.log(p / ((1 - alpha) * q + alpha * p))
      end
    end

    # Users bucketed by how many favorites/read/reading list items they have in
    # the domain -- a cheap proxy for positive-interaction count that needs one
    # GROUP BY instead of building every user's interactions.
    def sample_user_ids(domain:, per_segment:, random:)
      klass = ::UserList.subclasses_for(domain).first or raise ArgumentError, "no user lists for domain #{domain}"
      positive_types = klass.list_types.slice("favorites", "read", "reading").values
      counts = ::UserListItem.joins(:user_list)
        .where(user_lists: {type: klass.name, list_type: positive_types})
        .group("user_lists.user_id").count

      SEGMENTS.to_h do |label, range|
        ids = counts.select { |_, n| range.cover?(n) }.keys.sort
        [label, ids.shuffle(random: random).first(per_segment)]
      end
    end
  end
end
```

`::UserList.subclasses_for(domain)` is the existing helper over `UserList::DOMAIN_SUBCLASSES` (`app/models/user_list.rb:99`); books has exactly one subclass, so `.first` is the whole list.

- [ ] **Step 4: Write the rake tasks**

`lib/tasks/recommendations.rake`:

```ruby
# frozen_string_literal: true

# Read-only development harness for the recommendation engine (spec §9). Never
# writes to the database or the index. Every knob is a per-call override, so one
# process sweeps a range:
#
#   bin/rails recommendations:show USER=123 [LIMIT=50] [VARIANTS="lift=false; calibrate_genres=false"]
#   bin/rails recommendations:eval [USERS=500] [SEED=42] [LIMIT=50] [FRACTION=0.2] [VARIANTS="lift=false"]
#
# eval always reports two baselines beside the variants: `rank` (the filtered
# pool in global-rank order) and `lift=false` (raw frequency share, which is
# the legacy engine's behaviour).
module RecommendationsHarness
  module_function

  def parse_variants(raw)
    specs = [{}]
    return specs if raw.blank?

    raw.split(";").each do |chunk|
      overrides = chunk.split(",").each_with_object({}) do |pair, acc|
        key, value = pair.split("=", 2).map(&:strip)
        acc[key.to_sym] = cast(value) if key.present? && !value.nil?
      end
      specs << overrides if overrides.any?
    end
    specs
  end

  def cast(value)
    case value
    when /\A-?\d+\z/ then value.to_i
    when /\A-?\d*\.\d+\z/ then value.to_f
    when "true" then true
    when "false" then false
    else value
    end
  end

  def label(overrides)
    overrides.empty? ? "shipped defaults" : overrides.map { |k, v| "#{k}=#{v}" }.join("  ")
  end

  def reason_text(reason, names)
    case reason.type
    when :because_of then "because you loved #{names[reason.ids.first] || reason.ids.first}"
    when :interests then "matches #{reason.ids.map { |id| names[id] || id }.join(" + ")}"
    else "ranked ##{reason.ids.first || "?"}"
    end
  end

  def category_names(ids)
    ::Category.where(id: ids).pluck(:id, :name).to_h
  end

  def mean(values)
    values.empty? ? 0.0 : values.sum.to_f / values.size
  end

  def fmt(value)
    format("%.3f", value)
  end
end

namespace :recommendations do
  desc "Print one user's profile and recommendations with reasons (USER=id, LIMIT, VARIANTS)"
  task show: :environment do
    user = User.find(ENV.fetch("USER"))
    limit = ENV.fetch("LIMIT", "50").to_i
    variants = RecommendationsHarness.parse_variants(ENV["VARIANTS"])

    variants.each do |overrides|
      puts "=" * 100
      puts "#{user.display_name || user.email} (#{user.id}) -- #{RecommendationsHarness.label(overrides)}"
      result = Recommendations::Engine.call(user: user, domain: :books, limit: limit, overrides: overrides)
      abort result.errors.join(", ") unless result.success?

      profile = result.data[:profile]
      names = RecommendationsHarness.category_names(profile.scored_ids + profile.demoted)
      puts "  counts: #{profile.counts}  fiction_share: #{profile.fiction_share&.round(2).inspect}  signals: #{result.data[:signals_used]}#{" FALLBACK" if result.data[:fallback]}"
      {genres: profile.genres, subjects: profile.subjects, locations: profile.locations}.each do |type, pairs|
        puts "  #{type}: " + pairs.map { |id, w| "#{names[id]}(#{w.round(2)})" }.join(", ")
      end
      puts "  demoted: " + profile.demoted.map { |id| names[id] }.join(", ") if profile.demoted.any?
      puts

      page_names = RecommendationsHarness.category_names(result.data[:items].flat_map { |i| i[:reason].ids if i[:reason].type == :interests }.compact)
      result.data[:items].each do |entry|
        book = entry[:item]
        authors = book.book_authors.filter_map { |ba| ba.author&.name }.join(", ")
        puts format("  %3d. %-55s %-25s rank %-6s %s", entry[:rank], book.title[0, 55], authors[0, 25],
          book.primary_ranked_item&.rank || "-", RecommendationsHarness.reason_text(entry[:reason], page_names))
      end
      puts
    end
  end

  desc "Offline hold-out evaluation across user segments (USERS, SEED, LIMIT, FRACTION, VARIANTS)"
  task eval: :environment do
    users_total = ENV.fetch("USERS", "500").to_i
    seed = ENV.fetch("SEED", "42").to_i
    limit = ENV.fetch("LIMIT", "50").to_i
    fraction = ENV.fetch("FRACTION", "0.2").to_f
    variants = RecommendationsHarness.parse_variants(ENV["VARIANTS"])
    variants << {lift: false} unless variants.any? { |v| v[:lift] == false }

    random = Random.new(seed)
    segments = Recommendations::Evaluation.sample_user_ids(domain: :books, per_segment: users_total / 3, random: random)
    config = Recommendations::Config.resolve
    adapter = Recommendations::Books::Adapter.new(config: config)
    pool_size = ::RankedItem.where(item_type: "Books::Book", ranking_configuration_id: ::Books::RankingConfiguration.default_primary&.id).count

    puts "Recommendations evaluation  users=#{segments.values.sum(&:size)}  seed=#{seed}  hold-out=#{fraction}  limit=#{limit}"
    puts "variants: rank baseline | " + variants.map { |v| RecommendationsHarness.label(v) }.join(" | ")
    puts

    segments.each do |segment, user_ids|
      rows = Hash.new { |h, k| h[k] = {hit: [], recall: [], ndcg: [], mean_rank: [], author_repeats: [], kl: [], ms: [], ids: Set.new} }
      evaluated = 0

      user_ids.each do |user_id|
        user = User.find(user_id)
        interactions = adapter.interactions(user)
        train, held = Recommendations::Evaluation.split(interactions, fraction: fraction, random: Random.new(seed + user_id))
        next if held.size < 1 || interactions.count { |i| Recommendations::Evaluation.eligible?(i) } < 5

        evaluated += 1
        held_ids = held.map(&:item_id)
        excluded = adapter.shelved_item_ids(user) - held_ids
        criteria = adapter.criteria_for(user)

        # Baseline: the filtered pool in global rank order.
        rank_ids = adapter.rank_ordered_candidates(criteria: criteria, excluded_ids: excluded, size: limit).map(&:item_id)
        m = Recommendations::Evaluation.metrics(page_ids: rank_ids, held_out_ids: held_ids)
        rows["rank"][:hit] << m[:hit]
        rows["rank"][:recall] << m[:recall]
        rows["rank"][:ndcg] << m[:ndcg]

        variants.each do |overrides|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = Recommendations::Engine.call(user: user, domain: :books, limit: limit, overrides: overrides,
            interactions: train, excluded_ids: excluded)
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          next unless result.success?

          items = result.data[:items]
          page_ids = items.map { |i| i[:item_id] }
          facts = adapter.item_facts(page_ids)
          m = Recommendations::Evaluation.metrics(page_ids: page_ids, held_out_ids: held_ids)
          row = rows[RecommendationsHarness.label(overrides)]
          row[:hit] << m[:hit]
          row[:recall] << m[:recall]
          row[:ndcg] << m[:ndcg]
          row[:ms] << ms
          row[:ids].merge(page_ids)
          ranks = page_ids.filter_map { |id| facts[id]&.rank_position }
          row[:mean_rank] << RecommendationsHarness.mean(ranks) if ranks.any?
          author_counts = page_ids.flat_map { |id| facts[id]&.author_ids || [] }.tally.values
          row[:author_repeats] << author_counts.sum { |c| c - 1 }
          row[:kl] << Recommendations::Evaluation.genre_kl(history: result.data[:profile].genre_distribution,
            page_genres: page_ids.map { |id| facts[id]&.genre_ids || [] }, alpha: config[:calibration_alpha])
        end
      end

      puts "-- segment #{segment}: #{evaluated} of #{user_ids.size} sampled users evaluated"
      puts format("   %-36s %7s %9s %8s %9s %8s %7s %9s %6s", "variant", "hit@10", "recall@50", "ndcg@50", "mean_rank", "au_rep", "kl", "coverage", "ms")
      rows.each do |name, r|
        puts format("   %-36s %7s %9s %8s %9s %8s %7s %9s %6s", name[0, 36],
          RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:hit])),
          RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:recall])),
          RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:ndcg])),
          r[:mean_rank].empty? ? "-" : RecommendationsHarness.mean(r[:mean_rank]).round,
          r[:author_repeats].empty? ? "-" : RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:author_repeats])),
          r[:kl].empty? ? "-" : RecommendationsHarness.fmt(RecommendationsHarness.mean(r[:kl])),
          pool_size.zero? ? "-" : RecommendationsHarness.fmt(r[:ids].size.to_f / pool_size),
          r[:ms].empty? ? "-" : RecommendationsHarness.mean(r[:ms]).round)
      end
      puts
    end
  end
end
```

- [ ] **Step 5: Run the evaluation unit tests, then smoke the tasks against the dev database**

Run: `bin/rails test test/lib/recommendations/evaluation_test.rb`
Expected: PASS (6 tests).

Then (dev database, read-only; needs OpenSearch running and the books index populated — see `docs/features/search.md`):

```bash
bin/rails recommendations:show USER=<a user id with favorites>
bin/rails recommendations:eval USERS=30 SEED=1
```

Expected: `show` prints a profile and a numbered page with reasons; `eval` prints three segment tables with `rank`, `shipped defaults`, and `lift=false` rows. Paste one `show` output and the `eval` table into the task's handback.

- [ ] **Step 6: Commit**

```bash
git add app/lib/recommendations/evaluation.rb lib/tasks/recommendations.rake test/lib/recommendations/evaluation_test.rb
git commit -m "Add the recommendations evaluation harness"
```

---

### Task 12: Feature doc, full gate, and the first measured tuning pass

**Files:**
- Create: `docs/features/recommendations.md`, `docs/data-quality/recommendations-<YYYY-MM-DD>.md`
- Modify: `config/initializers/recommendations.rb` only if the tuning pass changes a value (record why beside it, as `book_similarity.rb` does)

- [ ] **Step 1: Write `docs/features/recommendations.md`**

Cover, in this order, each in a short section: what the feature is and where it lives (`app/lib/recommendations/`, `app/lib/recommendations/books/`, `Search::Books::Search::BookRecommendations`, `config/initializers/recommendations.rb`); the pipeline diagram from spec §5 with the class names; the adapter contract (the method list from Task 5's Interfaces plus the two from Task 7); the signal contract (Task 8's Interfaces) and the note that `Signals::Collaborative` is a stub until spec 2; the profile math (copy spec §6.1–6.4 formulas); the query shape (spec §7 list); re-ranking order and explanation precedence; the preferences store (`recommendation_configs`, key names, `Books::RecommendationCriteria`, the migration task); the harness commands with the environment variables; and the knob table from spec §9.3 with a pointer to the data-quality doc for measured values. Do not describe classes file by file — code is the source of truth (`docs/documentation.md`).

- [ ] **Step 2: Run the full gate**

```bash
bin/rails test 2>&1 | tail -20
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: 0 failures, 0 errors; standardrb clean; "All is good!". Scan the test output for warning lines beyond the two known upstream sources (`weighted_list_rank` position `puts`, npm/yarn during `test:prepare`); a new one is a regression to fix.

- [ ] **Step 3: Run the measured tuning pass and record it**

```bash
bin/rails recommendations:eval USERS=500 SEED=42 > /tmp/claude-1001/-home-shane-dev-the-greatest/277a0802-3534-46d6-b091-5c1813320aa9/scratchpad/eval-defaults.txt
bin/rails recommendations:eval USERS=500 SEED=42 VARIANTS="calibrate_genres=false; pseudo_books=5; pseudo_books=20; negative_gamma=1.0; rank_prior_weight=0.0; rank_prior_weight=0.6; min_score=0.5; min_score=2.0" > .../eval-sweep.txt
```

Write `docs/data-quality/recommendations-<date>.md` with: the exact commands, the dev database's counts (books, ranked pool, sampled users per segment), the segment tables verbatim, and a short reading of them. The §9.2 gate: on the 20–99 segment, the shipped defaults must beat **both** `rank` and `lift=false` on hit@10 and recall@50, with `kl` at or below `lift=false`. If a single knob change clears the gate where the defaults do not, change the initializer value, note the measurement beside it, and re-run the defaults. If no single change clears it, **stop and report** the tables in the handback rather than tuning further — spec §9.2 says to revisit §6 with Shane, not to keep turning knobs.

- [ ] **Step 4: Commit**

```bash
git add ../docs/features/recommendations.md ../docs/data-quality/ config/initializers/recommendations.rb
git commit -m "Document the recommendation engine and record the first tuning pass"
```

---

## Self-review (done while writing)

- **Spec coverage, increments 1–2:** §4 table and models → Task 1; criteria → Task 2 (key-name deviation recorded); §4.1 migration → Task 4; §5 pipeline, adapter and signal contracts, fusion, failure → Tasks 5, 8, 10; §6 profile → Task 6; §7 query → Task 7; §8 re-ranking and explanations → Tasks 9, 10; §9 harness, knobs, gate → Tasks 5, 11, 12; §11 docs → Task 12. §2, §3 (controller/registry route behaviour), §8.3 component, and §10's controller/E2E tests are increments 3–4 and belong to the next plan; `Recommendations::Registry` (Task 5) is the piece of §3 that increment 2 needs.
- **Review Focus pins:** 1 → Task 10 "falls back to rank-only when the profile is empty"; 2 → Task 7 "an unparseable criterion matches nothing"; 3 → Task 5 "shelved ids include every list (custom and want-to-read)" + Task 10 "passes the shelved ids as exclusions"; 4 → Task 9 "series rule drops a sequel unless…"; 5 → Task 10 "a signal that raises is dropped" and "returns an empty success when every signal and the fallback fail".
- **Type consistency:** `Candidate(item_id:, score:, rank_position:, evidence:)`, `ItemFact(author_ids:, genre_ids:, series_predecessor_id:, rank_position:)`, `Interaction(item_id:, weight:, kind:, rating:)`, `Reason(type:, ids:)` are used with those exact keywords in Tasks 5–11. Signal `call(profile:, interactions:, criteria:, excluded_ids:, size:)` is identical in Tasks 8, 10. `Engine.call` keywords match between Task 10 and Task 11.
- **Known soft spots for the reviewer:** the genre-calibration test in Task 9 relies on the greedy arithmetic worked in the plan's margin (B1 enters at about position 6 with λ = 0.3); if it fails, print the page and check the KL step before touching λ.
