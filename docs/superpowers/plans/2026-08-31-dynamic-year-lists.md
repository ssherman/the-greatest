# Dynamic Year Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual assembly around year-scoped ranking configurations with one action that builds the configuration and one that generates and wires its two output lists in the correct order.

**Architecture:** A year-scoped `RankingConfiguration` ranks that year's lists in isolation. `Services::Lists::GenerateDynamicLists` reads its `ranked_items` and writes two generated `List` records — a top-N and an overflow — which feed the domain's primary configuration like any other list. The generator owns the lists' items and every weight-affecting field, re-asserting them on each run, modelled directly on `Services::Lists::GenerateUserFavorites`.

**Tech Stack:** Rails 8.1, Ruby 4.0.6, PostgreSQL 17.4, Minitest + fixtures + Mocha, Sidekiq, DaisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-31-dynamic-year-lists-design.md`

## Global Constraints

- Run all Rails commands from `web-app/`. Docs live at the project root, not `web-app/docs/`.
- Use Rails generators for new models/jobs; never hand-create them. Jobs: `bin/rails generate sidekiq:job <name>`.
- Services live in `app/lib/services/<domain>/`, **not** `app/services/`. Jobs in `app/sidekiq/`, **not** `app/jobs/`.
- Result pattern: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Rails 8 enum syntax: `enum :status, {active: 0}` — colon prefix.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). Do not run brakeman.
- Minitest 6: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Sidekiq test mode is `Sidekiq.testing!(:inline)`, set globally. Never `require "sidekiq/testing"`.
- Fixture names are semantic (`books_global`, `basic_list`), never `one`/`two`.
- Controller tests assert behaviour only — status codes, params, effects. Never HTML, CSS, or copy.
- DaisyUI 5: use bare `input` / `label` / `select`. The classes `input-bordered`, `label-text`, `form-control` and seven others are removed and fail silently; `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence.
- A clean `bin/rails test` emits no new warnings. A new warning line is a regression.
- **This worktree shares the development database with every other checkout.** After `db:migrate`, diff `db/schema.rb` and revert any change belonging to a sibling worktree's migration before committing.
- Never run destructive commands against development. `ActiveRecord::FixtureSet.create_fixtures` truncates.

---

## File Structure

**Created:**
- `db/migrate/<ts>_add_year_and_secondary_cutoff_to_ranking_configurations.rb`
- `db/migrate/<ts>_add_auto_generated_year_to_lists.rb`
- `app/lib/services/lists/generate_dynamic_lists.rb` — the generator
- `app/sidekiq/generate_dynamic_lists_job.rb`
- `app/lib/actions/admin/create_next_year_configuration.rb`
- `app/lib/actions/admin/generate_dynamic_lists.rb`
- `lib/tasks/dynamic_lists.rake`
- Matching tests under `test/`, plus `e2e/tests/books/admin/dynamic-year-lists.spec.ts`

**Modified:**
- `app/models/ranking_configuration.rb` — validations, `supports_year_rollups?`, `generated_list_class`, `generated_list_noun`, `one_year_penalty_name`
- `app/models/{books,games}/ranking_configuration.rb`, `app/models/music/{albums,songs}/ranking_configuration.rb` — the four overrides
- `app/models/list.rb` — enum values
- `app/controllers/admin/ranking_configurations_controller.rb` — permitted params, `allowed_action_names`
- `app/views/admin/ranking_configurations/_form.html.erb` — two new fields
- `app/views/admin/ranking_configurations/show.html.erb` — mapped-lists card, two dropdown entries
- `test/fixtures/{lists,ranking_configurations,penalties}.yml`

---

### Task 1: Schema and model validations

**Files:**
- Create: `db/migrate/<ts>_add_year_and_secondary_cutoff_to_ranking_configurations.rb`
- Create: `db/migrate/<ts>_add_auto_generated_year_to_lists.rb`
- Modify: `app/models/ranking_configuration.rb`
- Modify: `app/models/list.rb`
- Test: `test/models/ranking_configuration_test.rb`, `test/models/list_test.rb`

**Interfaces:**
- Produces: `ranking_configurations.year` (integer, nullable), `ranking_configurations.secondary_mapped_list_cutoff_limit` (integer, nullable), `lists.auto_generated_year` (integer, nullable), and `List` enum values `year_top: 1` / `year_honorable_mention: 2` with the `generated_` prefix (predicates `generated_year_top?`, `generated_year_honorable_mention?`).

- [ ] **Step 1: Write the failing model tests**

Append to `test/models/ranking_configuration_test.rb`, inside the existing class:

```ruby
test "year accepts nil" do
  config = ranking_configurations(:books_global)
  config.year = nil
  assert config.valid?
end

test "year rejects zero and non-integers" do
  config = ranking_configurations(:books_global)
  config.year = 0
  assert_not config.valid?
  assert_includes config.errors[:year], "must be greater than 0"
end

test "secondary_mapped_list_cutoff_limit rejects zero" do
  config = ranking_configurations(:books_global)
  config.secondary_mapped_list_cutoff_limit = 0
  assert_not config.valid?
end

test "secondary_mapped_list_cutoff_limit accepts nil meaning uncapped" do
  config = ranking_configurations(:books_global)
  config.secondary_mapped_list_cutoff_limit = nil
  assert config.valid?
end
```

Append to `test/models/list_test.rb`, inside the existing class:

```ruby
test "auto_generated_kind carries the two year rollup values" do
  list = Books::List.new(name: "x", auto_generated_kind: :year_top, auto_generated_year: 2025)
  assert list.generated_year_top?
  assert list.auto_generated?

  list.auto_generated_kind = :year_honorable_mention
  assert list.generated_year_honorable_mention?
end

test "one generated list of each kind per type per year" do
  Books::List.create!(name: "Top 2025", status: :active,
    auto_generated_kind: :year_top, auto_generated_year: 2025)

  assert_raises(ActiveRecord::RecordNotUnique) do
    Books::List.insert!({name: "Dupe", status: 3, type: "Books::List",
      auto_generated_kind: 1, auto_generated_year: 2025})
  end
end

test "different years of the same kind coexist" do
  Books::List.create!(name: "Top 2025", status: :active,
    auto_generated_kind: :year_top, auto_generated_year: 2025)
  other = Books::List.create!(name: "Top 2024", status: :active,
    auto_generated_kind: :year_top, auto_generated_year: 2024)

  assert other.persisted?
end

test "user_favorites still collapses to one per type despite a null year" do
  Books::List.create!(name: "Favs", status: :active, auto_generated_kind: :user_favorites)

  assert_raises(ActiveRecord::RecordNotUnique) do
    Books::List.insert!({name: "Dupe favs", status: 3, type: "Books::List",
      auto_generated_kind: 0})
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/ranking_configuration_test.rb test/models/list_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'year='` and `ArgumentError: 'year_top' is not a valid auto_generated_kind`.

- [ ] **Step 3: Write both migrations**

`db/migrate/<ts>_add_year_and_secondary_cutoff_to_ranking_configurations.rb`:

```ruby
class AddYearAndSecondaryCutoffToRankingConfigurations < ActiveRecord::Migration[8.1]
  def change
    # The year a configuration scopes to; NULL on an all-time configuration.
    # Until now the year existed only inside the name string, which neither the
    # generator (which stamps year_published on its output lists) nor the
    # clone action (which computes year + 1) can read reliably.
    add_column :ranking_configurations, :year, :integer

    # A COUNT, matching primary_mapped_list_cutoff_limit, which legacy applied as
    # limit(n) then offset(n). Read as offset(primary).limit(secondary).
    # NULL means uncapped.
    add_column :ranking_configurations, :secondary_mapped_list_cutoff_limit, :integer
  end
end
```

`db/migrate/<ts>_add_auto_generated_year_to_lists.rb`:

```ruby
class AddAutoGeneratedYearToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :auto_generated_year, :integer

    remove_index :lists, name: "index_lists_on_type_and_auto_generated_kind"

    # NULLS NOT DISTINCT keeps user_favorites rows -- whose year is NULL --
    # collapsed to one per domain exactly as the old index did, while allowing
    # one year_top and one year_honorable_mention per year per domain.
    # PostgreSQL is 17.4 and Rails 8.1 round-trips this through the schema
    # dumper, so one index replaces what would otherwise be two partial ones.
    add_index :lists, [:type, :auto_generated_kind, :auto_generated_year],
      unique: true,
      nulls_not_distinct: true,
      where: "auto_generated_kind IS NOT NULL",
      name: "index_lists_on_type_and_auto_generated_kind_and_year"
  end
end
```

- [ ] **Step 4: Run the migrations and check for sibling drift**

```bash
bin/rails db:migrate
git diff db/schema.rb
```

Confirm `db/schema.rb` shows **only** the three new columns and the index swap. This worktree shares the development database, so a sibling's migration can land in your dump — revert any hunk you did not author before committing. Verify the index dumped with `nulls_not_distinct: true`; if it did not, replace the single index with two partial ones (`... WHERE auto_generated_kind IS NOT NULL AND auto_generated_year IS NULL` and `... WHERE auto_generated_year IS NOT NULL`) and note the change.

- [ ] **Step 5: Add the model validations and enum values**

In `app/models/ranking_configuration.rb`, after the `primary_mapped_list_cutoff_limit` validation:

```ruby
  validates :secondary_mapped_list_cutoff_limit, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :year, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
```

In `app/models/list.rb`, replace the `auto_generated_kind` enum:

```ruby
  # Set on lists whose items are written by a generator rather than curated by
  # hand. Identifies the generated list durably across renames -- the legacy
  # implementation looked its lists up by name, which broke on any edit.
  # year_top and year_honorable_mention pair with auto_generated_year; a
  # user_favorites list leaves that column NULL.
  enum :auto_generated_kind,
    {user_favorites: 0, year_top: 1, year_honorable_mention: 2},
    prefix: :generated
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/ranking_configuration_test.rb test/models/list_test.rb`
Expected: PASS

- [ ] **Step 7: Refresh annotations, lint, run the full suite**

```bash
bundle exec annotaterb models
bundle exec standardrb --fix
bin/rails test
```

Expected: all green, no new warning lines.

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb app/models/ranking_configuration.rb app/models/list.rb test/models
git commit -m "Add year, secondary cutoff, and per-year generated list identity"
```

---

### Task 2: Per-domain year rollup capability on RankingConfiguration

**Files:**
- Modify: `app/models/ranking_configuration.rb`
- Modify: `app/models/books/ranking_configuration.rb`, `app/models/games/ranking_configuration.rb`, `app/models/music/albums/ranking_configuration.rb`, `app/models/music/songs/ranking_configuration.rb`
- Test: `test/models/ranking_configuration_test.rb`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the migrated columns.
- Produces, all **instance** methods on `RankingConfiguration`:
  - `supports_year_rollups?` → `Boolean`, `false` on the base class
  - `generated_list_class` → the domain's `List` subclass; raises `NotImplementedError` on the base
  - `generated_list_noun` → `String`, e.g. `"Books"`
  - `one_year_penalty_name` → `String` or `nil`

- [ ] **Step 1: Write the failing tests**

Append to `test/models/ranking_configuration_test.rb`:

```ruby
test "the four item domains support year rollups" do
  {
    books_global: ::Books::List,
    games_global: ::Games::List,
    music_albums_global: ::Music::Albums::List,
    music_songs_global: ::Music::Songs::List
  }.each do |fixture, list_class|
    config = ranking_configurations(fixture)
    assert config.supports_year_rollups?, "#{fixture} should support year rollups"
    assert_equal list_class, config.generated_list_class
  end
end

test "creator configurations do not support year rollups" do
  assert_not ranking_configurations(:books_authors_global).supports_year_rollups?
  assert_not ranking_configurations(:music_artists_global).supports_year_rollups?
end

test "generated_list_noun capitalises the media noun" do
  assert_equal "Books", ranking_configurations(:books_global).generated_list_noun
  assert_equal "Games", ranking_configurations(:games_global).generated_list_noun
  assert_equal "Albums", ranking_configurations(:music_albums_global).generated_list_noun
  assert_equal "Songs", ranking_configurations(:music_songs_global).generated_list_noun
end

test "only books names a static one-year penalty" do
  assert_equal "List: only covers 1 year (yearly book awards, best of the year, etc)",
    ranking_configurations(:books_global).one_year_penalty_name
  assert_nil ranking_configurations(:games_global).one_year_penalty_name
  assert_nil ranking_configurations(:music_albums_global).one_year_penalty_name
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/ranking_configuration_test.rb -n "/year_rollups|generated_list_noun|one_year_penalty/"`
Expected: FAIL with `NoMethodError: undefined method 'supports_year_rollups?'`.

- [ ] **Step 3: Add the base implementations**

In `app/models/ranking_configuration.rb`, next to `media_noun_plural`:

```ruby
  # Whether this configuration can produce year rollup lists. Tested instead of
  # respond_to?(:generated_list_class), which would answer true everywhere --
  # the base class defines that method in order to raise from it.
  def supports_year_rollups?
    false
  end

  # The List subclass this configuration's generated year rollups belong to.
  def generated_list_class
    raise NotImplementedError, "#{self.class.name} must define #generated_list_class"
  end

  # Display noun for generated list names: "The 100 Greatest Books of 2025".
  def generated_list_noun
    media_noun_plural.capitalize
  end

  # The static one-year penalty this domain tags its year rollups with, or nil
  # when the domain penalises time scope dynamically instead. Books is the only
  # domain with a static penalty; games, albums and songs apply the dynamic
  # Global::Penalty "List: number of years covered", which reads
  # list.num_years_covered and therefore needs no tag.
  def one_year_penalty_name
    nil
  end
```

- [ ] **Step 4: Add the four subclass overrides**

`app/models/books/ranking_configuration.rb`:

```ruby
    def media_noun_plural = "books"

    def supports_year_rollups? = true

    def generated_list_class = ::Books::List

    def one_year_penalty_name = "List: only covers 1 year (yearly book awards, best of the year, etc)"
```

`app/models/games/ranking_configuration.rb`:

```ruby
    def media_noun_plural = "games"

    def supports_year_rollups? = true

    def generated_list_class = ::Games::List
```

`app/models/music/albums/ranking_configuration.rb`:

```ruby
      def media_noun_plural = "albums"

      def supports_year_rollups? = true

      def generated_list_class = ::Music::Albums::List
```

`app/models/music/songs/ranking_configuration.rb`:

```ruby
      def media_noun_plural = "songs"

      def supports_year_rollups? = true

      def generated_list_class = ::Music::Songs::List
```

Root-anchor every constant (`::Books::List`, not `Books::List`) — nested namespace shadowing has bitten this codebase repeatedly and presents as a `NameError` only in some load orders.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/ranking_configuration_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/models test/models/ranking_configuration_test.rb
git commit -m "Declare year rollup support per ranking configuration domain"
```

---

### Task 3: Generator — list identity and item windows

**Files:**
- Create: `app/lib/services/lists/generate_dynamic_lists.rb`
- Create: `test/lib/services/lists/generate_dynamic_lists_test.rb`
- Modify: `test/fixtures/ranking_configurations.yml`

**Interfaces:**
- Consumes: `RankingConfiguration#supports_year_rollups?`, `#generated_list_class`, `#generated_list_noun`, `#year`, `#primary_mapped_list_cutoff_limit`, `#secondary_mapped_list_cutoff_limit` from Task 2.
- Produces: `Services::Lists::GenerateDynamicLists.call(ranking_configuration:, recalculate_primary: true)` → `Result` with `data: {top_list:, overflow_list:, top_count:, overflow_count:, source_list_count:}`.

This task builds the guards, list creation, and item writing. Field assertion and wiring land in Task 4; the ranking pipeline lands in Task 5.

- [ ] **Step 1: Add the year configuration fixture**

Append to `test/fixtures/ranking_configurations.yml`:

```yaml
books_year_2025:
  type: Books::RankingConfiguration
  name: "The Best Books of 2025"
  description: "Year-scoped configuration for 2025 books"
  global: true
  primary: false
  archived: false
  algorithm_version: 1
  exponent: 3.0
  bonus_pool_percentage: 6.0
  min_list_weight: 1
  year: 2025
  primary_mapped_list_cutoff_limit: 2
  secondary_mapped_list_cutoff_limit: 2
  apply_list_dates_penalty: false
  inherit_penalties: false
```

Cutoffs are deliberately tiny so the window tests need only a handful of ranked items.

- [ ] **Step 2: Write the failing tests**

`test/lib/services/lists/generate_dynamic_lists_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class GenerateDynamicListsTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_year_2025)
        @books = [
          books_books(:war_and_peace),
          books_books(:crime_and_punishment),
          books_books(:combo_steinbeck),
          books_books(:got),
          books_books(:clash)
        ]
      end

      # Ranks the given books 1..N on the year configuration. The generator
      # reads ranked_items, so this stands in for a real ranking run.
      def rank(books)
        books.each_with_index do |book, index|
          ::RankedItem.create!(ranking_configuration: @config, item: book,
            rank: index + 1, score: (100 - index).to_d)
        end
      end

      def generate(**options)
        GenerateDynamicLists.call(ranking_configuration: @config,
          recalculate_primary: false, **options)
      end

      test "fails when the configuration has no year" do
        @config.update_column(:year, nil)

        result = generate

        assert_not result.success?
        assert_match(/no year/, result.errors.first)
      end

      test "fails when the domain does not support year rollups" do
        config = ranking_configurations(:books_authors_global)
        config.update_columns(year: 2025, primary_mapped_list_cutoff_limit: 10)

        result = GenerateDynamicLists.call(ranking_configuration: config,
          recalculate_primary: false)

        assert_not result.success?
        assert_match(/does not support year rollups/, result.errors.first)
      end

      test "fails when the primary cutoff is unset" do
        @config.update_column(:primary_mapped_list_cutoff_limit, nil)

        result = generate

        assert_not result.success?
        assert_match(/primary cutoff/, result.errors.first)
      end

      test "creates both lists active on first run, named from year and cutoff" do
        rank(@books)

        result = generate

        assert result.success?, result.errors.inspect
        top = result.data[:top_list]
        overflow = result.data[:overflow_list]

        assert_equal "The 2 Greatest Books of 2025", top.name
        assert_equal "The Greatest Books of 2025 - Honorable Mention", overflow.name
        assert_equal "active", top.status
        assert_equal "active", overflow.status
        assert top.generated_year_top?
        assert overflow.generated_year_honorable_mention?
        assert_equal 2025, top.auto_generated_year
        assert_instance_of ::Books::List, top
      end

      test "writes the top window in rank order starting at position 1" do
        rank(@books)

        top = generate.data[:top_list]

        items = top.list_items.order(:position)
        assert_equal [1, 2], items.map(&:position)
        assert_equal @books.first(2).map(&:id), items.map(&:listable_id)
        assert_equal ["Books::Book", "Books::Book"], items.map(&:listable_type)
        assert items.all?(&:verified?)
      end

      test "the overflow window starts after the primary cutoff and renumbers from 1" do
        rank(@books)

        overflow = generate.data[:overflow_list]

        items = overflow.list_items.order(:position)
        assert_equal [1, 2], items.map(&:position)
        assert_equal @books[2, 2].map(&:id), items.map(&:listable_id)
      end

      test "the secondary cutoff drops the tail" do
        rank(@books)

        assert_equal 2, generate.data[:overflow_count]
        assert_equal 5, @config.ranked_items.count
      end

      test "a nil secondary cutoff means uncapped" do
        rank(@books)
        @config.update_column(:secondary_mapped_list_cutoff_limit, nil)

        assert_equal 3, generate.data[:overflow_count]
      end

      test "carries the source rank and score in item metadata" do
        rank(@books)

        item = generate.data[:top_list].list_items.order(:position).first

        assert_equal 1, item.metadata["source_rank"]
        assert_equal 100.0, item.metadata["source_score"]
      end

      test "rewrites items rather than appending on a second run" do
        rank(@books)
        generate

        ::RankedItem.where(ranking_configuration: @config).delete_all
        rank(@books.reverse)
        result = generate

        top = result.data[:top_list]
        assert_equal 2, top.list_items.count
        assert_equal @books.reverse.first(2).map(&:id),
          top.list_items.order(:position).map(&:listable_id)
      end

      test "finds the same lists on a second run rather than creating new ones" do
        rank(@books)
        first = generate.data[:top_list]

        second = generate.data[:top_list]

        assert_equal first.id, second.id
        assert_equal 1, ::Books::List.where(auto_generated_kind: :year_top,
          auto_generated_year: 2025).count
      end

      test "finds a renamed list by kind and year, not by name" do
        rank(@books)
        top = generate.data[:top_list]
        top.update!(name: "Something Else Entirely")

        assert_equal top.id, generate.data[:top_list].id
      end

      test "points the configuration at the lists it generated" do
        rank(@books)

        result = generate

        @config.reload
        assert_equal result.data[:top_list].id, @config.primary_mapped_list_id
        assert_equal result.data[:overflow_list].id, @config.secondary_mapped_list_id
      end

      test "leaves name and description alone on a second run" do
        rank(@books)
        top = generate.data[:top_list]
        top.update!(name: "Curated Name", description: "Curated description")

        generate

        top.reload
        assert_equal "Curated Name", top.name
        assert_equal "Curated description", top.description
      end

      test "leaves status alone on a second run" do
        rank(@books)
        top = generate.data[:top_list]
        top.update!(status: :unapproved)

        generate

        assert_equal "unapproved", top.reload.status
      end
    end
  end
end
```

Those five fixture names are verified against `test/fixtures/books/books.yml`. The others available there are `of_mice_and_men` and `cannery_row`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Lists::GenerateDynamicLists`.

- [ ] **Step 4: Write the service**

`app/lib/services/lists/generate_dynamic_lists.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    # Writes a year-scoped ranking configuration's results into two generated
    # Lists -- a top-N and an overflow -- which then feed the domain's primary
    # configuration like any other list.
    #
    # Modelled on GenerateUserFavorites: the lists are found by
    # (type, auto_generated_kind, auto_generated_year) rather than by name, so a
    # rename cannot orphan one, and everything that affects their weight is
    # re-asserted on every run rather than set once by hand.
    class GenerateDynamicLists
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(ranking_configuration:, recalculate_primary: true)
        new(ranking_configuration: ranking_configuration,
          recalculate_primary: recalculate_primary).call
      end

      def initialize(ranking_configuration:, recalculate_primary: true)
        @config = ranking_configuration
        @recalculate_primary = recalculate_primary
      end

      def call
        failure = guard_failure
        return Result.new(success?: false, data: nil, errors: [failure]) if failure

        top_list = nil
        overflow_list = nil

        ::List.transaction do
          top_list = write_list(:year_top, top_items)
          overflow_list = write_list(:year_honorable_mention, overflow_items)
          @config.update!(
            primary_mapped_list_id: top_list.id,
            secondary_mapped_list_id: overflow_list.id
          )
        end

        Result.new(
          success?: true,
          data: {
            top_list: top_list,
            overflow_list: overflow_list,
            top_count: top_list.list_items.count,
            overflow_count: overflow_list.list_items.count,
            source_list_count: source_list_count
          },
          errors: []
        )
      rescue => error
        # full_message, not message: the Result carries only the message, and
        # GenerateDynamicListsJob raises one of its own, so Sidekiq records that
        # job's backtrace and the original is gone unless written down here.
        Rails.logger.error {
          "#{self.class.name} failed for configuration #{@config.id}: " \
            "#{error.full_message(highlight: false, order: :top)}"
        }
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def guard_failure
        return "#{@config.name} has no year set" if @config.year.blank?
        unless @config.supports_year_rollups?
          return "#{@config.class.name} does not support year rollups"
        end
        if @config.primary_mapped_list_cutoff_limit.blank?
          # Legacy dumped every ranked item into the primary list in this case,
          # which is never what anyone wants and is silent when it happens.
          return "#{@config.name} has no primary cutoff limit set"
        end
        nil
      end

      def top_items
        @config.ranked_items.order(:rank).limit(@config.primary_mapped_list_cutoff_limit)
      end

      def overflow_items
        scope = @config.ranked_items.order(:rank).offset(@config.primary_mapped_list_cutoff_limit)
        limit = @config.secondary_mapped_list_cutoff_limit
        limit.present? ? scope.limit(limit) : scope
      end

      def write_list(kind, ranked_items)
        list = find_or_create_list(kind)

        # delete_all / insert_all skip the ListItem callbacks and validations on
        # purpose: the guards there exist to stop humans editing generated rows,
        # and this class is the generator they defer to.
        list.list_items.delete_all
        rows = item_rows(list, ranked_items.to_a)
        ::ListItem.insert_all(rows) if rows.any?

        list
      end

      def find_or_create_list(kind)
        # STI scopes find_or_create_by! to the domain's own List subclass via the
        # type column, which is what makes the unique index on
        # (type, auto_generated_kind, auto_generated_year) mean what it says.
        @config.generated_list_class.find_or_create_by!(
          auto_generated_kind: kind,
          auto_generated_year: @config.year
        ) do |list|
          list.name = default_name(kind)
          list.description = default_description(kind)
          list.source = "The Greatest"
          # Active from birth. A configuration with no rankings yet produces an
          # EMPTY list, which contributes nothing whatever its status, so there
          # is nothing to protect against by starting it switched off.
          list.status = :active
        end
      end

      def default_name(kind)
        noun = @config.generated_list_noun
        if kind == :year_top
          "The #{@config.primary_mapped_list_cutoff_limit} Greatest #{noun} of #{@config.year}"
        else
          "The Greatest #{noun} of #{@config.year} - Honorable Mention"
        end
      end

      def default_description(kind)
        noun = @config.generated_list_noun.downcase
        if kind == :year_top
          "The best #{noun} of #{@config.year}, aggregated from every #{@config.year} " \
            "year-end list on the site."
        else
          "The best #{noun} of #{@config.year} beyond the top " \
            "#{@config.primary_mapped_list_cutoff_limit}, aggregated from every " \
            "#{@config.year} year-end list on the site."
        end
      end

      def item_rows(list, ranked_items)
        now = Time.current

        ranked_items.each_with_index.map do |ranked_item, index|
          {
            list_id: list.id,
            listable_id: ranked_item.item_id,
            listable_type: ranked_item.item_type,
            position: index + 1,
            verified: true,
            metadata: {source_rank: ranked_item.rank, source_score: ranked_item.score.to_f},
            created_at: now,
            updated_at: now
          }
        end
      end

      # Only active lists, matching ItemRankings::Calculator#prepare_lists, which
      # reads `status: :active` -- so deactivating a source self-corrects this on
      # the next run.
      def source_list_count
        @config.ranked_lists.joins(:list).where(lists: {status: :active}).count
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb`
Expected: PASS

- [ ] **Step 6: Verify the identity tests are not vacuous**

Temporarily change `find_or_create_list` to look the list up by name instead:

```ruby
@config.generated_list_class.find_or_create_by!(name: default_name(kind)) do |list|
```

Run the suite. The "finds a renamed list by kind and year" test **must** fail. Revert the change. This codebase has shipped assertions that passed against deleted features; confirming red is how you know the test binds.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/lib/services/lists test/lib/services/lists test/fixtures/ranking_configurations.yml
git commit -m "Generate year rollup lists from a year configuration's rankings"
```

---

### Task 4: Generator — weight-affecting fields, penalties, and wiring

**Files:**
- Modify: `app/lib/services/lists/generate_dynamic_lists.rb`
- Modify: `test/lib/services/lists/generate_dynamic_lists_test.rb`
- Modify: `test/fixtures/penalties.yml`

**Interfaces:**
- Consumes: `RankingConfiguration#one_year_penalty_name` from Task 2; the service from Task 3.
- Produces: on every run, both lists carry `num_years_covered: 1`, `number_of_voters` = active source list count, `voter_count_unknown: false`, `voter_count_estimated: false`, `voter_names_unknown: true`, `high_quality_source: true`, `year_published` = the configuration's year, all three `*_specific` flags false, the domain's one-year penalty where named, the honorable-mention penalty on the overflow list, and a `RankedList` joining each to `default_primary`.

- [ ] **Step 1: Add the two penalty fixtures**

Append to `test/fixtures/penalties.yml`:

```yaml
books_one_year_penalty:
  type: Books::Penalty
  name: "List: only covers 1 year (yearly book awards, best of the year, etc)"
  description: "Covers a single year"
  category: 2 # list_time_scope

honorable_mention_penalty:
  type: Global::Penalty
  name: "List: is a follow up/honorable mention to a different list"
  description: "A follow-up to another list"
  category: 4 # list_integrity
```

- [ ] **Step 2: Write the failing tests**

Append inside `GenerateDynamicListsTest`:

```ruby
test "asserts every weight-affecting field on both lists" do
  rank(@books)

  result = generate

  [result.data[:top_list], result.data[:overflow_list]].each do |list|
    assert_equal 1, list.num_years_covered
    assert_equal 2025, list.year_published
    assert_equal false, list.voter_count_unknown
    assert_equal false, list.voter_count_estimated
    assert_equal true, list.voter_names_unknown
    assert_equal true, list.high_quality_source
    assert_equal false, list.category_specific
    assert_equal false, list.location_specific
    assert_equal false, list.creator_specific
  end
end

test "number_of_voters counts active source lists only" do
  rank(@books)
  active = lists(:basic_list)
  active.update!(status: :active)
  inactive = lists(:another_list)
  inactive.update!(status: :unapproved)
  ::RankedList.create!(list: active, ranking_configuration: @config)
  ::RankedList.create!(list: inactive, ranking_configuration: @config)

  result = generate

  assert_equal 1, result.data[:source_list_count]
  assert_equal 1, result.data[:top_list].number_of_voters
end

# This is the 2024/2023 shape from production: penalties totalled 190%, capped
# at 100%, and the list weighed 0 while holding 1,114 items.
test "repairs a list left with unknown voter count and no quality flag" do
  rank(@books)
  broken = ::Books::List.create!(
    name: "Hand-made overflow", status: :active,
    auto_generated_kind: :year_honorable_mention, auto_generated_year: 2025,
    voter_count_unknown: true, high_quality_source: false
  )

  generate

  broken.reload
  assert_equal false, broken.voter_count_unknown
  assert_equal true, broken.high_quality_source
end

test "tags both lists with the domain's one-year penalty" do
  rank(@books)
  penalty = penalties(:books_one_year_penalty)

  result = generate

  assert_includes result.data[:top_list].penalties, penalty
  assert_includes result.data[:overflow_list].penalties, penalty
end

test "tags only the overflow list as an honorable mention" do
  rank(@books)
  penalty = penalties(:honorable_mention_penalty)

  result = generate

  assert_includes result.data[:overflow_list].penalties, penalty
  assert_not_includes result.data[:top_list].penalties, penalty
end

test "does not duplicate penalty tags across runs" do
  rank(@books)
  generate

  overflow = generate.data[:overflow_list]

  assert_equal overflow.penalties.count, overflow.penalties.distinct.count
end

test "warns and continues when the domain's one-year penalty is missing" do
  rank(@books)
  penalties(:books_one_year_penalty).destroy!

  result = generate

  assert result.success?, result.errors.inspect
  assert_empty result.data[:top_list].penalties.where(type: "Books::Penalty")
end

# Attaching the tag is a fact about the list. Choosing what it is worth is an
# editorial judgement, so the generator never creates a PenaltyApplication.
test "never creates a penalty application" do
  rank(@books)
  before = ::PenaltyApplication.count

  generate

  assert_equal before, ::PenaltyApplication.count
end

test "joins both lists to the domain's primary configuration" do
  rank(@books)

  result = generate

  main = ::Books::RankingConfiguration.default_primary
  [result.data[:top_list], result.data[:overflow_list]].each do |list|
    assert_equal main, list.ranked_lists.sole.ranking_configuration
  end
end

test "repairs a missing ranked list on a later run" do
  rank(@books)
  top = generate.data[:top_list]
  top.ranked_lists.delete_all

  generate

  assert_equal 1, top.reload.ranked_lists.count
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb`
Expected: FAIL — `num_years_covered` is nil, no penalties attached, no ranked lists.

- [ ] **Step 4: Extend the service**

In `call`, inside the transaction, after `write_list` for both kinds and before the `@config.update!`:

```ruby
          assert_fields(top_list)
          assert_fields(overflow_list)
          assert_penalties(top_list, overflow_list)
          ensure_ranked_list(top_list)
          ensure_ranked_list(overflow_list)
```

Add these private methods:

```ruby
      # Every field here changes the list's weight in the primary configuration.
      # Re-asserted on every run rather than set once by hand: the two lists this
      # replaces were hand-created a year apart and drifted, leaving 2023's and
      # 2024's overflow lists at weight 0 with 1,837 items between them.
      def assert_fields(list)
        list.update!(
          num_years_covered: 1,
          number_of_voters: source_list_count,
          voter_count_unknown: false,
          voter_count_estimated: false,
          # The contributing publications are known, but not enumerated as named
          # voters. Costs 5% and is true.
          voter_names_unknown: true,
          high_quality_source: true,
          year_published: @config.year,
          category_specific: false,
          location_specific: false,
          creator_specific: false
        )
      end

      # Attaches tags only. The value of a tag is a per-configuration editorial
      # judgement, so this never creates a PenaltyApplication -- the same division
      # of labour GenerateUserFavorites settled on.
      def assert_penalties(top_list, overflow_list)
        one_year = one_year_penalty
        if one_year
          [top_list, overflow_list].each do |list|
            list.list_penalties.find_or_create_by!(penalty: one_year)
          end
        end

        honorable_mention = ::Global::Penalty.find_by(name: HONORABLE_MENTION_PENALTY_NAME)
        if honorable_mention
          overflow_list.list_penalties.find_or_create_by!(penalty: honorable_mention)
        else
          Rails.logger.warn {
            "#{self.class.name}: no Global::Penalty named " \
              "#{HONORABLE_MENTION_PENALTY_NAME.inspect}; list #{overflow_list.id} " \
              "will not be penalised as an honorable mention"
          }
        end
      end

      def one_year_penalty
        name = @config.one_year_penalty_name
        # Games, albums and songs penalise time scope with the dynamic
        # Global::Penalty "List: number of years covered", which fires off the
        # num_years_covered value assert_fields sets. No tag needed, and no warning.
        return nil if name.blank?

        penalty = ::Penalty.find_by(name: name)
        if penalty.nil?
          Rails.logger.warn {
            "#{self.class.name}: no Penalty named #{name.inspect}; the #{@config.year} " \
              "#{@config.generated_list_noun} rollups will not carry a one-year penalty"
          }
        end
        penalty
      end

      def ensure_ranked_list(list)
        main = @config.class.default_primary
        # A domain with no primary configuration is not set up for ranking yet.
        # Legitimate, and not this class's problem to fix.
        return if main.nil?

        ::RankedList.find_or_create_by!(list: list, ranking_configuration: main)
      end
```

And the constant, below `Result`:

```ruby
      # Global, so it works in all four domains. Applied in every primary
      # configuration today: books 50, games 40, albums 50, songs 50.
      HONORABLE_MENTION_PENALTY_NAME = "List: is a follow up/honorable mention to a different list"
```

Memoise `source_list_count` so `assert_fields` does not re-query per list:

```ruby
      def source_list_count
        @source_list_count ||= @config.ranked_lists.joins(:list).where(lists: {status: :active}).count
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb`
Expected: PASS

- [ ] **Step 6: Verify the repair test is not vacuous**

Delete the `voter_count_unknown: false` line from `assert_fields` and re-run. The "repairs a list left with unknown voter count" test **must** fail. Restore the line.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/lib/services/lists test/lib/services/lists test/fixtures/penalties.yml
git commit -m "Own the weight-affecting fields, penalties and wiring on year rollups"
```

---

### Task 5: The ordered pipeline and its job

**Files:**
- Modify: `app/lib/services/lists/generate_dynamic_lists.rb`
- Create: `app/sidekiq/generate_dynamic_lists_job.rb`
- Modify: `test/lib/services/lists/generate_dynamic_lists_test.rb`
- Create: `test/sidekiq/generate_dynamic_lists_job_test.rb`

**Interfaces:**
- Consumes: the service from Tasks 3–4.
- Produces: `GenerateDynamicListsJob#perform(ranking_configuration_id, recalculate_primary = true)`.

The order is the whole point: the year configuration's weights, then its rankings, then the lists, then the two affected rows on the primary, then the primary's rankings. Steps 1–2 cost 0.3–0.6s on real data; step 5 is the same job the existing Refresh Rankings button already queues.

- [ ] **Step 1: Write the failing tests**

Append inside `GenerateDynamicListsTest`:

```ruby
test "recalculates the year configuration's weights and rankings before reading them" do
  sequence = Mocha::Sequence.new("pipeline")
  bulk = mock("bulk")
  bulk.expects(:call).in_sequence(sequence)
  Rankings::BulkWeightCalculator.expects(:new).with(@config).returns(bulk).in_sequence(sequence)
  @config.expects(:calculate_rankings).in_sequence(sequence).returns(
    ItemRankings::Calculator::Result.new(success?: true, data: [], errors: [])
  )

  GenerateDynamicLists.call(ranking_configuration: @config, recalculate_primary: false)
end

test "fails when the year ranking calculation fails" do
  @config.stubs(:calculate_rankings).returns(
    ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["boom"])
  )

  result = GenerateDynamicLists.call(ranking_configuration: @config, recalculate_primary: false)

  assert_not result.success?
  assert_match(/boom/, result.errors.first)
end

test "recalculates only the two affected rows on the primary configuration" do
  rank(@books)
  captured = nil
  Rankings::BulkWeightCalculator.any_instance.stubs(:call_for_ids).with { |ids| captured = ids; true }

  result = GenerateDynamicLists.call(ranking_configuration: @config, recalculate_primary: false)

  expected = [result.data[:top_list], result.data[:overflow_list]]
    .flat_map { |list| list.ranked_lists.pluck(:id) }
  assert_equal expected.sort, captured.sort
end

test "queues the primary configuration's ranking recalculation" do
  rank(@books)
  main = ::Books::RankingConfiguration.default_primary
  CalculateRankingsJob.expects(:perform_async).with(main.id).once

  GenerateDynamicLists.call(ranking_configuration: @config)
end

test "skips the primary recalculation when asked to" do
  rank(@books)
  CalculateRankingsJob.expects(:perform_async).never

  GenerateDynamicLists.call(ranking_configuration: @config, recalculate_primary: false)
end
```

The `rank` helper writes `ranked_items` directly, and step 2 of the pipeline would delete them — so the tests that assert on written items stub `calculate_rankings`. Add to `setup`:

```ruby
        # rank() seeds ranked_items directly; the real calculation would wipe them,
        # since prepare_lists finds no weighted lists on this fixture configuration.
        @config.stubs(:calculate_rankings).returns(
          ItemRankings::Calculator::Result.new(success?: true, data: [], errors: [])
        )
        Rankings::BulkWeightCalculator.any_instance.stubs(:call)
```

and change `generate` to pass the same instance:

```ruby
      def generate(**options)
        GenerateDynamicLists.call(ranking_configuration: @config,
          recalculate_primary: false, **options)
      end
```

For the stubs to apply, the service must use the `@config` instance it is handed rather than re-finding it — which it does.

`test/sidekiq/generate_dynamic_lists_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class GenerateDynamicListsJobTest < ActiveSupport::TestCase
  setup do
    @config = ranking_configurations(:books_year_2025)
  end

  test "calls the service for the given configuration" do
    Services::Lists::GenerateDynamicLists
      .expects(:call)
      .with(ranking_configuration: @config, recalculate_primary: true)
      .returns(Services::Lists::GenerateDynamicLists::Result.new(
        success?: true,
        data: {top_count: 2, overflow_count: 2, source_list_count: 1},
        errors: []
      ))

    GenerateDynamicListsJob.new.perform(@config.id)
  end

  test "passes recalculate_primary through" do
    Services::Lists::GenerateDynamicLists
      .expects(:call)
      .with(ranking_configuration: @config, recalculate_primary: false)
      .returns(Services::Lists::GenerateDynamicLists::Result.new(
        success?: true, data: {top_count: 0, overflow_count: 0, source_list_count: 0}, errors: []
      ))

    GenerateDynamicListsJob.new.perform(@config.id, false)
  end

  test "raises when the service fails so Sidekiq retries" do
    Services::Lists::GenerateDynamicLists
      .expects(:call)
      .returns(Services::Lists::GenerateDynamicLists::Result.new(
        success?: false, data: nil, errors: ["no year set"]
      ))

    error = assert_raises(RuntimeError) { GenerateDynamicListsJob.new.perform(@config.id) }
    assert_match(/no year set/, error.message)
  end

  test "raises when the configuration does not exist" do
    assert_raises(ActiveRecord::RecordNotFound) { GenerateDynamicListsJob.new.perform(-1) }
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb test/sidekiq/generate_dynamic_lists_job_test.rb`
Expected: FAIL — no pipeline calls, and `NameError: uninitialized constant GenerateDynamicListsJob`.

- [ ] **Step 3: Add the pipeline to the service**

In `call`, immediately after the guard check and before the transaction:

```ruby
        refresh_year_rankings
```

After the transaction, before building the `Result`:

```ruby
        recalculate_primary([top_list, overflow_list])
```

Add the private methods:

```ruby
      # Order is load-bearing. The generator reads ranked_items, so both the
      # weights and the rankings behind them must be current first, and
      # calculate_rankings runs synchronously for exactly that reason. Measured on
      # real data: 0.3-0.6s for a 43-60 list year configuration.
      def refresh_year_rankings
        ::Rankings::BulkWeightCalculator.new(@config).call

        result = @config.calculate_rankings
        return if result.success?

        raise "Ranking calculation failed for #{@config.name}: #{result.errors.join(", ")}"
      end

      # Only the two rows this run touched, not the primary's whole corpus -- for
      # books that is 623 lists, and the two generated lists are the only ones
      # whose weight inputs changed.
      #
      # The ranking recalculation is safe as perform_async because the lists are
      # fully written and re-weighted by the time it is enqueued. It is the same
      # job the Refresh Rankings button queues, so this adds no new load to a
      # queue that is already a throughput bottleneck.
      def recalculate_primary(lists)
        main = @config.class.default_primary
        return if main.nil?

        ranked_list_ids = ::RankedList.where(ranking_configuration: main, list: lists).pluck(:id)
        ::Rankings::BulkWeightCalculator.new(main).call_for_ids(ranked_list_ids) if ranked_list_ids.any?

        ::CalculateRankingsJob.perform_async(main.id) if @recalculate_primary
      end
```

- [ ] **Step 4: Generate and write the job**

```bash
bin/rails generate sidekiq:job generate_dynamic_lists
```

Replace `app/sidekiq/generate_dynamic_lists_job.rb`:

```ruby
# frozen_string_literal: true

# Regenerates one year configuration's two rollup lists, in the order that makes
# the result correct. Queued by Actions::Admin::GenerateDynamicLists and by the
# dynamic_lists rake tasks.
#
# Deliberately has no cron entry. Regeneration reshuffles the primary
# configuration, and that stays a deliberate act.
class GenerateDynamicListsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id, recalculate_primary = true)
    ranking_configuration = RankingConfiguration.find(ranking_configuration_id)

    result = Services::Lists::GenerateDynamicLists.call(
      ranking_configuration: ranking_configuration,
      recalculate_primary: recalculate_primary
    )

    unless result.success?
      raise "Dynamic list generation failed for configuration " \
        "#{ranking_configuration_id}: #{result.errors.join(", ")}"
    end

    Rails.logger.info {
      "Generated dynamic lists for #{ranking_configuration.name}: " \
        "#{result.data[:top_count]} top items, #{result.data[:overflow_count]} overflow items, " \
        "from #{result.data[:source_list_count]} source lists"
    }

    result
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb test/sidekiq/generate_dynamic_lists_job_test.rb`
Expected: PASS

- [ ] **Step 6: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb --fix
```

Expected: green, no new warnings.

- [ ] **Step 7: Commit**

```bash
git add app/lib/services/lists app/sidekiq/generate_dynamic_lists_job.rb test
git commit -m "Enforce the recalculation order and add the generation job"
```

---

### Task 6: Create Next Year's Configuration action

**Files:**
- Create: `app/lib/actions/admin/create_next_year_configuration.rb`
- Create: `test/lib/actions/admin/create_next_year_configuration_test.rb`

**Interfaces:**
- Consumes: `RankingConfiguration#supports_year_rollups?`, `#generated_list_noun`, `#year` from Task 2.
- Produces: `Actions::Admin::CreateNextYearConfiguration.call(user:, models: [config])` → `BaseAction::ActionResult` with `data: {ranking_configuration:, copied:, added:, skipped:}`.

- [ ] **Step 1: Write the failing tests**

`test/lib/actions/admin/create_next_year_configuration_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class CreateNextYearConfigurationTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @main = ranking_configurations(:books_global)
        @year_2025 = ranking_configurations(:books_year_2025)
      end

      def run_action(config)
        CreateNextYearConfiguration.call(user: @user, models: [config])
      end

      test "name and message" do
        assert_equal "Create Next Year's Configuration", CreateNextYearConfiguration.name
        assert_not_empty CreateNextYearConfiguration.message
      end

      test "visible only on the show view" do
        assert CreateNextYearConfiguration.visible?(view: :show)
        assert_not CreateNextYearConfiguration.visible?(view: :index)
        assert_not CreateNextYearConfiguration.visible?({})
      end

      test "errors on multiple models" do
        result = CreateNextYearConfiguration.call(user: @user, models: [@main, @year_2025])
        assert result.error?
      end

      test "errors on a domain that does not support year rollups" do
        result = run_action(ranking_configurations(:books_authors_global))
        assert result.error?
        assert_match(/does not support year rollups/, result.message)
      end

      test "creates the year after the latest year configuration" do
        result = run_action(@main)

        assert result.success?, result.message
        created = result.data[:ranking_configuration]
        assert_equal 2026, created.year
        assert_equal "The Best Books of 2026", created.name
        assert_instance_of ::Books::RankingConfiguration, created
      end

      test "uses the current year when the domain has no year configuration" do
        @year_2025.destroy!

        created = run_action(@main).data[:ranking_configuration]

        assert_equal Date.current.year, created.year
      end

      test "copies tuned settings from the previous year, not from main" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal @year_2025.exponent, created.exponent
        assert_equal @year_2025.bonus_pool_percentage, created.bonus_pool_percentage
        assert_not_equal @main.bonus_pool_percentage, created.bonus_pool_percentage
      end

      test "forces the date penalty off and clears its bounds" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal false, created.apply_list_dates_penalty
        assert_nil created.max_list_dates_penalty_age
        assert_nil created.max_list_dates_penalty_percentage
      end

      # The first-year case is where this bites: cloning from main would inherit
      # apply_list_dates_penalty true and penalise 2026 books for being on 2026 lists.
      test "forces the date penalty off when cloning from main" do
        @year_2025.destroy!

        created = run_action(@main).data[:ranking_configuration]

        assert_equal true, @main.apply_list_dates_penalty
        assert_equal false, created.apply_list_dates_penalty
      end

      test "creates a non-primary, unpublished, global configuration" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal false, created.primary
        assert_equal true, created.global
        assert_equal false, created.archived
        assert_nil created.published_at
        assert_nil created.inherited_from_id
        assert_nil created.primary_mapped_list_id
        assert_nil created.secondary_mapped_list_id
      end

      test "defaults the cutoffs to 100 and 400 when the source has none" do
        @year_2025.destroy!

        created = run_action(@main).data[:ranking_configuration]

        assert_equal 100, created.primary_mapped_list_cutoff_limit
        assert_equal 400, created.secondary_mapped_list_cutoff_limit
      end

      test "copies cutoffs from the previous year when set" do
        created = run_action(@main).data[:ranking_configuration]

        assert_equal @year_2025.primary_mapped_list_cutoff_limit,
          created.primary_mapped_list_cutoff_limit
        assert_equal @year_2025.secondary_mapped_list_cutoff_limit,
          created.secondary_mapped_list_cutoff_limit
      end

      test "excludes every list_time_scope penalty" do
        time_penalty = penalties(:books_one_year_penalty)
        ::PenaltyApplication.create!(penalty: time_penalty, ranking_configuration: @main, value: 50)

        created = run_action(@main).data[:ranking_configuration]

        assert_not_includes created.penalties, time_penalty
      end

      test "excludes a num_years_covered penalty whatever its category" do
        uncategorized = ::Global::Penalty.create!(
          name: "Uncategorized years", dynamic_type: :num_years_covered, category: nil
        )
        ::PenaltyApplication.create!(penalty: uncategorized, ranking_configuration: @main, value: 30)

        created = run_action(@main).data[:ranking_configuration]

        assert_not_includes created.penalties, uncategorized
      end

      test "adds penalties main applies that the previous year lacks" do
        gap = penalties(:cross_media_penalty)
        ::PenaltyApplication.create!(penalty: gap, ranking_configuration: @main, value: 25)

        created = run_action(@main).data[:ranking_configuration]

        assert_equal 25, created.penalty_applications.find_by(penalty: gap).value
      end

      test "the previous year's tuned value wins over main's" do
        shared = penalties(:cross_media_penalty)
        ::PenaltyApplication.create!(penalty: shared, ranking_configuration: @main, value: 60)
        ::PenaltyApplication.create!(penalty: shared, ranking_configuration: @year_2025, value: 70)

        created = run_action(@main).data[:ranking_configuration]

        assert_equal 70, created.penalty_applications.find_by(penalty: shared).value
      end

      test "reports what it copied, added and skipped" do
        result = run_action(@main)

        assert_kind_of Integer, result.data[:copied]
        assert_kind_of Integer, result.data[:added]
        assert_kind_of Integer, result.data[:skipped]
        assert_match(/2026/, result.message)
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/actions/admin/create_next_year_configuration_test.rb`
Expected: FAIL with `NameError: uninitialized constant Actions::Admin::CreateNextYearConfiguration`.

- [ ] **Step 3: Write the action**

`app/lib/actions/admin/create_next_year_configuration.rb`:

```ruby
# frozen_string_literal: true

module Actions
  module Admin
    # Builds the next year's ranking configuration for a domain, fully set up.
    #
    # Replaces hand-assembly that had already drifted three years running: 2023
    # and 2024 use exponent 1.5 while 2025 uses 3.0, and their penalty sets differ
    # by more than the tuning justifies.
    class CreateNextYearConfiguration < Actions::Admin::BaseAction
      # Inside a single-year configuration every list covers the same one year, so
      # a time-scope penalty fires on everything or nothing and carries no signal
      # either way. All 7 of these were already absent from all three existing year
      # configurations -- the rule was being applied by hand, just never written down.
      EXCLUDED_CATEGORY = "list_time_scope"
      EXCLUDED_DYNAMIC_TYPE = "num_years_covered"

      DEFAULT_PRIMARY_CUTOFF = 100
      # Ranks 101-500. Under the primary configuration's "contains over 500 items"
      # threshold, so a generated overflow list never trips it.
      DEFAULT_SECONDARY_CUTOFF = 400

      def self.name
        "Create Next Year's Configuration"
      end

      def self.message
        "Create the next year's configuration, copying settings and penalties forward."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        return error("#{config.class.name} does not support year rollups.") unless config.supports_year_rollups?

        config_class = config.class
        previous = config_class.where.not(year: nil).order(year: :desc).first
        main = config_class.default_primary
        source = previous || main

        return error("#{config_class.name} has no configuration to copy from.") if source.nil?

        target_year = previous ? previous.year + 1 : Date.current.year

        from_previous = previous ? applicable_values(previous) : {}
        from_main = main ? applicable_values(main) : {}
        merged = from_main.merge(from_previous)
        added = (from_main.keys - from_previous.keys).size

        new_config = build_configuration(config_class, source, target_year)
        merged.each do |penalty_id, value|
          new_config.penalty_applications.build(penalty_id: penalty_id, value: value)
        end

        return error("Could not create the #{target_year} configuration: #{new_config.errors.full_messages.join(", ")}") unless new_config.save

        succeed(
          "Created #{new_config.name}: #{from_previous.size} penalties copied forward, " \
            "#{added} added from #{main&.name || "the primary configuration"}, " \
            "#{skipped_count(previous, main)} time-scope penalties skipped. " \
            "Attach this year's lists to it, then generate.",
          data: {
            ranking_configuration: new_config,
            copied: from_previous.size,
            added: added,
            skipped: skipped_count(previous, main)
          }
        )
      end

      private

      def build_configuration(config_class, source, target_year)
        config_class.new(
          name: "The Best #{source.generated_list_noun} of #{target_year}",
          description: "Year-scoped ranking configuration for #{target_year} " \
            "#{source.generated_list_noun.downcase}.",
          year: target_year,
          global: true,
          primary: false,
          archived: false,
          published_at: nil,
          algorithm_version: source.algorithm_version,
          exponent: source.exponent,
          bonus_pool_percentage: source.bonus_pool_percentage,
          min_list_weight: source.min_list_weight,
          inherit_penalties: source.inherit_penalties,
          # Forced, not copied. Every list in a year configuration is from that
          # year, so the date penalty has nothing to discriminate -- and cloning
          # from the primary configuration would inherit `true` and penalise a
          # 2026 book for appearing on a 2026 list.
          apply_list_dates_penalty: false,
          max_list_dates_penalty_age: nil,
          max_list_dates_penalty_percentage: nil,
          primary_mapped_list_cutoff_limit:
            source.primary_mapped_list_cutoff_limit || DEFAULT_PRIMARY_CUTOFF,
          secondary_mapped_list_cutoff_limit:
            source.secondary_mapped_list_cutoff_limit || DEFAULT_SECONDARY_CUTOFF
        )
      end

      def applicable_values(config)
        config.penalty_applications.includes(:penalty)
          .reject { |application| excluded?(application.penalty) }
          .to_h { |application| [application.penalty_id, application.value] }
      end

      # The dynamic_type clause is belt-and-braces. Today every penalty carries a
      # category and the one dynamic time penalty is categorised correctly, but
      # `category` is nullable and a penalty created in admin can arrive without one.
      def excluded?(penalty)
        penalty.category == EXCLUDED_CATEGORY || penalty.dynamic_type == EXCLUDED_DYNAMIC_TYPE
      end

      def skipped_count(previous, main)
        [previous, main].compact.flat_map { |config|
          config.penalty_applications.includes(:penalty)
            .select { |application| excluded?(application.penalty) }
            .map(&:penalty_id)
        }.uniq.size
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/actions/admin/create_next_year_configuration_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the exclusion test is not vacuous**

Change `excluded?` to `false`. The two exclusion tests **must** fail. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/lib/actions/admin/create_next_year_configuration.rb test/lib/actions/admin/create_next_year_configuration_test.rb
git commit -m "Add the one-click next-year configuration action"
```

---

### Task 7: Generate action, controller wiring, and admin views

**Files:**
- Create: `app/lib/actions/admin/generate_dynamic_lists.rb`
- Create: `test/lib/actions/admin/generate_dynamic_lists_test.rb`
- Modify: `app/controllers/admin/ranking_configurations_controller.rb`
- Modify: `app/views/admin/ranking_configurations/_form.html.erb`
- Modify: `app/views/admin/ranking_configurations/show.html.erb`
- Test: `test/controllers/admin/books/ranking_configurations_controller_test.rb`

**Interfaces:**
- Consumes: `GenerateDynamicListsJob` from Task 5, `CreateNextYearConfiguration` from Task 6.
- Produces: `Actions::Admin::GenerateDynamicLists`, both names in `allowed_action_names`, and `year` / `secondary_mapped_list_cutoff_limit` as permitted params.

- [ ] **Step 1: Write the failing action test**

`test/lib/actions/admin/generate_dynamic_lists_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class GenerateDynamicListsTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @year_config = ranking_configurations(:books_year_2025)
      end

      test "name and message" do
        assert_equal "Generate Dynamic Lists", GenerateDynamicLists.name
        assert_not_empty GenerateDynamicLists.message
      end

      test "visible only on the show view" do
        assert GenerateDynamicLists.visible?(view: :show)
        assert_not GenerateDynamicLists.visible?(view: :index)
      end

      test "errors unless exactly one configuration is given" do
        assert GenerateDynamicLists.call(user: @user, models: []).error?
      end

      test "errors on a configuration with no year" do
        result = GenerateDynamicLists.call(user: @user, models: [ranking_configurations(:books_global)])

        assert result.error?
        assert_match(/no year/, result.message)
      end

      test "queues the job for a year configuration" do
        GenerateDynamicListsJob.expects(:perform_async).with(@year_config.id).once

        result = GenerateDynamicLists.call(user: @user, models: [@year_config])

        assert result.success?
        assert_match(/2025/, result.message)
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/actions/admin/generate_dynamic_lists_test.rb`
Expected: FAIL with `NameError: uninitialized constant Actions::Admin::GenerateDynamicLists`.

- [ ] **Step 3: Write the action**

`app/lib/actions/admin/generate_dynamic_lists.rb`:

```ruby
# frozen_string_literal: true

module Actions
  module Admin
    # Regenerates a year configuration's two rollup lists. The job it queues runs
    # the whole chain in the one order that produces a correct result, which is
    # why this exists rather than a bare "refresh" the operator has to sequence.
    class GenerateDynamicLists < Actions::Admin::BaseAction
      def self.name
        "Generate Dynamic Lists"
      end

      def self.message
        "Rebuild this year's top and honorable mention lists, then refresh the main rankings."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        return error("#{config.name} has no year set, so it produces no dynamic lists.") if config.year.blank?
        return error("#{config.class.name} does not support year rollups.") unless config.supports_year_rollups?

        GenerateDynamicListsJob.perform_async(config.id)

        succeed "Dynamic list generation queued for #{config.year}. " \
          "The main rankings will refresh when it finishes."
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/actions/admin/generate_dynamic_lists_test.rb`
Expected: PASS

- [ ] **Step 5: Write the failing controller test**

Append to `test/controllers/admin/books/ranking_configurations_controller_test.rb`, inside the existing class:

```ruby
test "permits year and secondary cutoff on update" do
  config = ranking_configurations(:books_year_2025)
  sign_in_as(@admin_user, stub_auth: true)

  patch admin_books_ranking_configuration_path(config), params: {
    ranking_configuration: {year: 2026, secondary_mapped_list_cutoff_limit: 250}
  }

  config.reload
  assert_equal 2026, config.year
  assert_equal 250, config.secondary_mapped_list_cutoff_limit
end

test "ignores mapped list ids on update since the generator owns them" do
  config = ranking_configurations(:books_year_2025)
  other = lists(:basic_list)
  sign_in_as(@admin_user, stub_auth: true)

  patch admin_books_ranking_configuration_path(config), params: {
    ranking_configuration: {primary_mapped_list_id: other.id}
  }

  assert_nil config.reload.primary_mapped_list_id
end

test "accepts the two new action names" do
  config = ranking_configurations(:books_year_2025)
  sign_in_as(@admin_user, stub_auth: true)
  GenerateDynamicListsJob.stubs(:perform_async)

  post execute_action_admin_books_ranking_configuration_path(config),
    params: {action_name: "GenerateDynamicLists"}
  assert_response :redirect

  post execute_action_admin_books_ranking_configuration_path(config),
    params: {action_name: "CreateNextYearConfiguration"}
  assert_response :redirect
end
```

The setup block already supplies `@admin_user` and calls `host! Rails.application.config.domains[:books]`; the admin route helpers are domain-namespaced, hence `admin_books_ranking_configuration_path` rather than `admin_ranking_configuration_path`.

- [ ] **Step 6: Run to verify it fails**

Run: `bin/rails test test/controllers/admin/books/ranking_configurations_controller_test.rb`
Expected: FAIL — `year` stays nil, and the action names raise `ActionController::BadRequest`.

- [ ] **Step 7: Update the controller**

In `app/controllers/admin/ranking_configurations_controller.rb`, replace the mapped-list keys in `ranking_configuration_params`:

```ruby
      :year,
      :primary_mapped_list_cutoff_limit,
      :secondary_mapped_list_cutoff_limit
```

Delete `:primary_mapped_list_id` and `:secondary_mapped_list_id`. The form never rendered fields for them — the values arrived only via migration — and the generator now owns them, so leaving them permitted only allows the two sources of truth to diverge.

Replace `allowed_action_names`:

```ruby
  def allowed_action_names
    %w[RefreshRankings BulkCalculateWeights GenerateDynamicLists CreateNextYearConfiguration]
  end
```

- [ ] **Step 8: Run to verify it passes**

Run: `bin/rails test test/controllers/admin/books/ranking_configurations_controller_test.rb`
Expected: PASS

- [ ] **Step 9: Add the two form fields**

In `app/views/admin/ranking_configurations/_form.html.erb`, after the `list_limit` block and inside the same grid `<div>`:

```erb
        <div>
          <%= f.label :year, class: "label" do %>
            <span class="font-semibold">Year</span>
          <% end %>
          <%= f.number_field :year,
              class: "input w-full #{@ranking_configuration.errors[:year].any? ? 'input-error' : ''}",
              min: 1,
              placeholder: "All-time" %>
          <label class="label">
            <span>Set this to scope the configuration to one year (optional)</span>
          </label>
          <% if @ranking_configuration.errors[:year].any? %>
            <label class="label">
              <span class="text-error"><%= @ranking_configuration.errors[:year].first %></span>
            </label>
          <% end %>
        </div>

        <div>
          <%= f.label :primary_mapped_list_cutoff_limit, class: "label" do %>
            <span class="font-semibold">Top List Size</span>
          <% end %>
          <%= f.number_field :primary_mapped_list_cutoff_limit,
              class: "input w-full #{@ranking_configuration.errors[:primary_mapped_list_cutoff_limit].any? ? 'input-error' : ''}",
              min: 1,
              placeholder: "100" %>
          <label class="label">
            <span>How many items the generated top list holds</span>
          </label>
          <% if @ranking_configuration.errors[:primary_mapped_list_cutoff_limit].any? %>
            <label class="label">
              <span class="text-error"><%= @ranking_configuration.errors[:primary_mapped_list_cutoff_limit].first %></span>
            </label>
          <% end %>
        </div>

        <div>
          <%= f.label :secondary_mapped_list_cutoff_limit, class: "label" do %>
            <span class="font-semibold">Honorable Mention Size</span>
          <% end %>
          <%= f.number_field :secondary_mapped_list_cutoff_limit,
              class: "input w-full #{@ranking_configuration.errors[:secondary_mapped_list_cutoff_limit].any? ? 'input-error' : ''}",
              min: 1,
              placeholder: "400" %>
          <label class="label">
            <span>How many items follow the top list; blank means no limit</span>
          </label>
          <% if @ranking_configuration.errors[:secondary_mapped_list_cutoff_limit].any? %>
            <label class="label">
              <span class="text-error"><%= @ranking_configuration.errors[:secondary_mapped_list_cutoff_limit].first %></span>
            </label>
          <% end %>
        </div>
```

Bare `input` and `label` only — `input-bordered`, `label-text` and `form-control` were removed in daisyUI 5 and compile to nothing, and `test/lint/daisyui_v4_classes_test.rb` fails on them.

- [ ] **Step 10: Extend the mapped-lists card and the actions dropdown**

In `app/views/admin/ranking_configurations/show.html.erb`, replace the whole `Mapped Lists` card (the `<% if @ranking_configuration.primary_mapped_list.present? || ... %>` block) with:

```erb
      <% if @ranking_configuration.year.present? %>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Dynamic Lists for <%= @ranking_configuration.year %></h2>
            <div class="space-y-4">
              <p class="text-sm text-base-content/70">
                Top list holds <%= @ranking_configuration.primary_mapped_list_cutoff_limit || "an unset number of" %> items;
                honorable mention holds <%= @ranking_configuration.secondary_mapped_list_cutoff_limit || "every remaining" %> item(s).
              </p>

              <% [["Top List", @ranking_configuration.primary_mapped_list],
                  ["Honorable Mention", @ranking_configuration.secondary_mapped_list]].each do |label, list| %>
                <div>
                  <label class="label">
                    <span class="font-semibold"><%= label %></span>
                  </label>
                  <% if list.present? %>
                    <p><%= list.name %></p>
                    <p class="text-sm text-base-content/70">
                      <%= pluralize(list.list_items.count, "item") %> ·
                      generated <%= time_ago_in_words(list.updated_at) %> ago
                    </p>
                  <% else %>
                    <p class="text-sm text-base-content/70">Not generated yet.</p>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
```

The list names are plain text, deliberately not links. This view is shared across all four domains, and the admin list route is namespaced per domain (`admin_books_list_path`, `admin_games_list_path`, …) with no shared equivalent — linking would mean threading a fifth `helper_method` through the base controller and all four subclasses for a convenience. The card is informational; the lists are one click away in the domain's own list index.

In the Actions dropdown, after the `Refresh Rankings` `<li>`:

```erb
            <li>
              <%= button_to "Create Next Year's Configuration",
                  execute_action_ranking_configuration_path(@ranking_configuration, action_name: "CreateNextYearConfiguration"),
                  method: :post,
                  class: "text-left",
                  data: { turbo_confirm: "Create the next year's configuration, copying settings and penalties forward?" } %>
            </li>
            <% if @ranking_configuration.year.present? %>
              <li>
                <%= button_to "Generate Dynamic Lists",
                    execute_action_ranking_configuration_path(@ranking_configuration, action_name: "GenerateDynamicLists"),
                    method: :post,
                    class: "text-left",
                    data: { turbo_confirm: "Rebuild this year's two lists and refresh the main rankings?" } %>
              </li>
            <% end %>
```

- [ ] **Step 11: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb --fix
```

Expected: green, including `test/lint/daisyui_v4_classes_test.rb`.

- [ ] **Step 12: Commit**

```bash
git add app/lib/actions/admin/generate_dynamic_lists.rb app/controllers app/views test
git commit -m "Wire both dynamic list actions into the ranking configuration admin"
```

---

### Task 8: Adoption and batch regeneration rake tasks

**Files:**
- Create: `lib/tasks/dynamic_lists.rake`
- Create: `test/lib/tasks/dynamic_lists_rake_test.rb`

**Interfaces:**
- Consumes: `GenerateDynamicListsJob` from Task 5.
- Produces: `dynamic_lists:adopt` and `dynamic_lists:regenerate[type]`.

Adoption must run before the first generate, or the generator creates fresh lists while the six existing ones keep their items attached to the primary configuration — double-counting every 2023–2025 book.

- [ ] **Step 1: Write the failing tests**

`test/lib/tasks/dynamic_lists_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class DynamicListsRakeTest < ActiveSupport::TestCase
  setup do
    Rake::Task.clear
    Rails.application.load_tasks

    @config = ranking_configurations(:books_year_2025)
    @top = ::Books::List.create!(name: "Legacy Top 2025", status: :active, year_published: 2025)
    @overflow = ::Books::List.create!(name: "Legacy Overflow 2025", status: :active, year_published: 2025)
    @config.update_columns(
      year: nil,
      secondary_mapped_list_cutoff_limit: nil,
      primary_mapped_list_id: @top.id,
      secondary_mapped_list_id: @overflow.id
    )
  end

  teardown { Rake::Task.clear }

  def run_task(name, *args)
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke(*args) }
  end

  test "adopt stamps kind and year on both lists from year_published" do
    run_task("dynamic_lists:adopt")

    assert @top.reload.generated_year_top?
    assert_equal 2025, @top.auto_generated_year
    assert @overflow.reload.generated_year_honorable_mention?
    assert_equal 2025, @overflow.auto_generated_year
  end

  test "adopt sets the configuration's year from the primary list" do
    run_task("dynamic_lists:adopt")

    assert_equal 2025, @config.reload.year
  end

  test "adopt defaults the secondary cutoff to 400" do
    run_task("dynamic_lists:adopt")

    assert_equal 400, @config.reload.secondary_mapped_list_cutoff_limit
  end

  test "adopt leaves an already-set secondary cutoff alone" do
    @config.update_column(:secondary_mapped_list_cutoff_limit, 250)

    run_task("dynamic_lists:adopt")

    assert_equal 250, @config.reload.secondary_mapped_list_cutoff_limit
  end

  test "adopt is idempotent" do
    run_task("dynamic_lists:adopt")
    run_task("dynamic_lists:adopt")

    assert_equal 2025, @top.reload.auto_generated_year
    assert_equal 1, ::Books::List.where(auto_generated_kind: :year_top, auto_generated_year: 2025).count
  end

  test "adopt skips a configuration whose primary list has no year_published" do
    @top.update_column(:year_published, nil)

    run_task("dynamic_lists:adopt")

    assert_nil @top.reload.auto_generated_kind
    assert_nil @config.reload.year
  end

  test "regenerate queues one job per year configuration and suppresses their primary refresh" do
    @config.update_column(:year, 2025)
    GenerateDynamicListsJob.expects(:perform_async).with(@config.id, false).once
    CalculateRankingsJob.expects(:perform_async).with(::Books::RankingConfiguration.default_primary.id).once

    run_task("dynamic_lists:regenerate", "Books::RankingConfiguration")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/tasks/dynamic_lists_rake_test.rb`
Expected: FAIL — `Don't know how to build task 'dynamic_lists:adopt'`.

- [ ] **Step 3: Write the rake tasks**

`lib/tasks/dynamic_lists.rake`:

```ruby
# frozen_string_literal: true

namespace :dynamic_lists do
  # Brings hand-created year rollup lists under the generator's ownership.
  #
  # MUST run before the first generate. Without it the generator finds no list at
  # (type, kind, year), creates a new pair, and the originals keep their items
  # attached to the primary configuration -- double-counting every item in them.
  #
  # Bridges via primary_mapped_list_id rather than by name: the pointers already
  # identify the right lists, and the year comes from the primary list's
  # year_published, which is data rather than a string parsed out of a title.
  desc "Adopt existing mapped lists as generator-owned year rollups (idempotent)"
  task adopt: :environment do
    adopted = 0

    RankingConfiguration.where.not(primary_mapped_list_id: nil).find_each do |config|
      top = config.primary_mapped_list
      overflow = config.secondary_mapped_list
      year = top&.year_published

      if year.blank?
        puts "SKIP #{config.id} #{config.name.inspect}: primary mapped list has no year_published."
        next
      end

      config.update!(year: year) if config.year.blank?
      config.update!(secondary_mapped_list_cutoff_limit: 400) if config.secondary_mapped_list_cutoff_limit.blank?

      top.update!(auto_generated_kind: :year_top, auto_generated_year: year)
      puts "ADOPT list #{top.id} #{top.name.inspect} as year_top #{year} (#{top.list_items.count} items)."

      if overflow
        overflow.update!(auto_generated_kind: :year_honorable_mention, auto_generated_year: year)
        puts "ADOPT list #{overflow.id} #{overflow.name.inspect} as year_honorable_mention #{year} " \
          "(#{overflow.list_items.count} items)."
      else
        puts "NOTE  #{config.name.inspect} has no secondary mapped list; only the top list was adopted."
      end

      adopted += 1
    end

    puts "Done. Adopted #{adopted} configuration(s)."
  end

  # Rebuilds every year configuration of a type, then refreshes the primary
  # configuration ONCE rather than once per year -- for books that is the
  # difference between one pass over 623 lists and three.
  desc "Regenerate every year configuration of a type, e.g. Books::RankingConfiguration"
  task :regenerate, [:type] => :environment do |_task, args|
    type = args[:type]
    raise ArgumentError, "Pass a ranking configuration type, e.g. Books::RankingConfiguration" if type.blank?

    config_class = type.constantize
    configs = config_class.where.not(year: nil).order(:year)

    if configs.empty?
      puts "No year configurations found for #{type}."
      next
    end

    configs.each do |config|
      puts "Queueing #{config.name.inspect} (#{config.year})."
      GenerateDynamicListsJob.perform_async(config.id, false)
    end

    main = config_class.default_primary
    if main
      puts "Queueing one ranking refresh for #{main.name.inspect}."
      CalculateRankingsJob.perform_async(main.id)
    end

    puts "Done. Queued #{configs.count} configuration(s)."
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/tasks/dynamic_lists_rake_test.rb`
Expected: PASS

Sidekiq test mode is `:inline`, so `perform_async` runs the job synchronously — that is why the regenerate test stubs it rather than letting it run.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix
git add lib/tasks/dynamic_lists.rake test/lib/tasks/dynamic_lists_rake_test.rb
git commit -m "Add adoption and batch regeneration tasks for year rollups"
```

---

### Task 9: E2E coverage

**Files:**
- Create: `e2e/tests/books/admin/dynamic-year-lists.spec.ts`

**Interfaces:**
- Consumes: the admin surface from Task 7.

- [ ] **Step 1: Confirm the port is yours**

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If it prints another checkout, **stop and tell the user.** Caddy proxies every dev hostname to `localhost:3000` regardless of which worktree is listening, so an E2E run against someone else's server reports their result as yours, with nothing in the output to reveal it. Do not kill their server and do not switch ports — routes are host-constrained, so `localhost:<port>` 404s everywhere.

- [ ] **Step 2: Start the app**

```bash
yarn build:all
bin/rails server
```

Not `bin/dev` — it needs a TTY.

- [ ] **Step 3: Write the spec**

`e2e/tests/books/admin/dynamic-year-lists.spec.ts`:

```typescript
import { test, expect } from "@playwright/test";

test.describe("Books admin — dynamic year lists", () => {
  async function createConfiguration(page, name: string, year?: string) {
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    if (year) {
      await page.locator('input[name="ranking_configuration[year]"]').fill(year);
    }
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  }

  test("the form offers year and both cutoff fields", async ({ page }) => {
    await page.goto("/admin/ranking_configurations/new");

    await expect(page.locator('input[name="ranking_configuration[year]"]')).toBeVisible();
    await expect(
      page.locator('input[name="ranking_configuration[primary_mapped_list_cutoff_limit]"]')
    ).toBeVisible();
    await expect(
      page.locator('input[name="ranking_configuration[secondary_mapped_list_cutoff_limit]"]')
    ).toBeVisible();
  });

  test("a year configuration shows its dynamic lists card", async ({ page }) => {
    await createConfiguration(page, `E2E Year RC ${Date.now()}`, "2031");

    await expect(page.getByText("Dynamic Lists for 2031")).toBeVisible();
    await expect(page.getByText("Not generated yet.").first()).toBeVisible();
  });

  test("Generate Dynamic Lists appears only on a year configuration", async ({ page }) => {
    await createConfiguration(page, `E2E No Year RC ${Date.now()}`);
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await expect(page.getByRole("button", { name: /Create Next Year/ })).toBeVisible();
    await expect(page.getByRole("button", { name: /Generate Dynamic Lists/ })).toHaveCount(0);

    await createConfiguration(page, `E2E Year Action RC ${Date.now()}`, "2032");
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await expect(page.getByRole("button", { name: /Generate Dynamic Lists/ })).toBeVisible();
  });

  test("creating next year's configuration reports what it copied", async ({ page }) => {
    await createConfiguration(page, `E2E Source RC ${Date.now()}`, "2033");
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await page.getByRole("button", { name: /Create Next Year/ }).click();

    await expect(page.getByText(/penalties copied forward/)).toBeVisible();
  });
});
```

Years 2031–2033 are chosen to sit above any real data so repeated runs cannot collide with the adopted 2023–2025 configurations.

- [ ] **Step 4: Run the E2E suite**

```bash
yarn test:e2e e2e/tests/books/admin/dynamic-year-lists.spec.ts
```

Expected: PASS. If the books suite has been run within the hour, `contact.spec` rate limiting can make unrelated books specs look broken — scope the run to this file.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/admin/dynamic-year-lists.spec.ts
git commit -m "Add E2E coverage for the dynamic year lists admin flow"
```

---

### Task 10: Adopt and regenerate the real books data

**Files:** none — this task runs commands and inspects results.

This is the rollout from the spec. It changes development data. Books data exists **only** in development and takes hours to rebuild, so snapshot first.

- [ ] **Step 1: Snapshot the development database**

```bash
bin/snapshot-dev-db.sh --label pre-dynamic-year-lists
```

- [ ] **Step 2: Run adoption and read the report**

```bash
bin/rails dynamic_lists:adopt
```

Expected: six ADOPT lines — lists 746/747 at 2024, 1041/1042 at 2023, 1088/1089 at 2025.

- [ ] **Step 3: Verify the stamps landed**

```bash
bin/rails runner 'RankingConfiguration.where.not(year: nil).order(:year).each { |rc| puts [rc.id, rc.name, "year=#{rc.year}", "cut=#{rc.primary_mapped_list_cutoff_limit}/#{rc.secondary_mapped_list_cutoff_limit}", "top=#{rc.primary_mapped_list&.auto_generated_kind}", "hm=#{rc.secondary_mapped_list&.auto_generated_kind}"].join(" | ") }'
```

Expected: three books rows with `year` set, cutoffs `100/400`, and kinds `year_top` / `year_honorable_mention`.

- [ ] **Step 4: Generate 2023 only, then look**

```bash
bin/rails runner 'GenerateDynamicListsJob.new.perform(RankingConfiguration.find_by(type: "Books::RankingConfiguration", year: 2023).id)'
```

Then inspect:

```bash
bin/rails runner 'rc = RankingConfiguration.find_by(type: "Books::RankingConfiguration", year: 2023); [rc.primary_mapped_list, rc.secondary_mapped_list].each { |l| rl = RankedList.find_by(list: l, ranking_configuration: Books::RankingConfiguration.default_primary); puts [l.id, l.name, "items=#{l.list_items.count}", "weight=#{rl&.weight}", "voters=#{l.number_of_voters}", "hq=#{l.high_quality_source}"].join(" | ") }'
```

Expected: top list 100 items, overflow 400 items, both with `voters` set to the active source count and `hq=true`. The overflow list's weight should be roughly 30 — it is 0 today, and that repair is the point.

**Stop and report the before/after books top 100 to the user before continuing.** Regenerating moves live rankings: 2023 and 2024 go from 0 contributing overflow items to 400 each, while 2025 sheds its 390-item tail.

- [ ] **Step 5: Generate the remaining years**

Only after the user has reviewed step 4:

```bash
bin/rails 'dynamic_lists:regenerate[Books::RankingConfiguration]'
```

- [ ] **Step 6: Final verification**

```bash
bin/rails test
bundle exec standardrb
```

Expected: green.

---

## Self-Review

**Spec coverage.** Every design section maps to a task: data model → Task 1; per-domain capability → Task 2; the generator's identity, windows, fields, penalties and wiring → Tasks 3–4; the ordered pipeline and job → Task 5; `CreateNextYearConfiguration` and the union penalty rule → Task 6; admin surface → Task 7; adoption and batch regeneration → Task 8; testing → distributed through every task plus Task 9; rollout → Task 10.

**Type consistency.** `Result` carries `data[:top_list]`, `data[:overflow_list]`, `data[:top_count]`, `data[:overflow_count]`, `data[:source_list_count]` and is consumed with those exact keys in Tasks 5, 7 and 10. `supports_year_rollups?`, `generated_list_class`, `generated_list_noun` and `one_year_penalty_name` are defined in Task 2 and used under those names in Tasks 3, 4, 6 and 7. `GenerateDynamicListsJob#perform(id, recalculate_primary = true)` is defined in Task 5 and called with both arities in Tasks 7 and 8.

**Verified against the codebase while writing, not assumed:** the books fixture names
(`war_and_peace`, `crime_and_punishment`, `combo_steinbeck`, `got`, `clash`), the controller
test's `@admin_user` and `host!` setup, the domain-namespaced route helpers
(`admin_books_ranking_configuration_path`, `execute_action_admin_books_ranking_configuration_path`),
`BulkWeightCalculator#call_for_ids`, `Rails 8.1`'s `nulls_not_distinct` schema-dumper support,
and the absence of any shared `admin_list_path`.

**One thing to confirm at implementation time:** that `db/schema.rb` dumps the new index with
`nulls_not_distinct: true` (Task 1, Step 4). The fallback — two partial indexes — is spelled out
in that step.
