# Greatest Authors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rank book authors by aggregating the scores of their ranked books, recalculate the ranking on a daily Sidekiq schedule, and publish it at `/authors` and `/author/:slug`.

**Architecture:** Author scores are derived, never list-ranked. One SQL `GROUP BY` over `ranked_items` joined to `books_book_authors` produces a score per author; a pure formula object damps that sum by how many ranked books the author has. Results are written as `RankedItem` rows with `item_type: "Books::Author"` under a new `Books::Authors::RankingConfiguration` STI subclass, so the existing pagination, caching, and ranked-item machinery is reused unchanged.

**Tech Stack:** Rails 8.1, PostgreSQL, Sidekiq + sidekiq-cron, Pagy, ViewComponent, Tailwind CSS 4 + DaisyUI 5, Minitest + Mocha + fixtures, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-02-greatest-authors-design.md`

## Global Constraints

- Run **all** Rails commands from `web-app/`. Docs live in `docs/` at the project root, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (`--fix` autocorrects). **Never** `bin/rubocop`. **Never** run brakeman.
- Full gate before claiming done: `bin/rails test` and `bundle exec standardrb`.
- **Use Rails generators** — never hand-create models, controllers, jobs, or components. Generators create the matching test file.
- **No code comments** unless the plan shows one. Follow existing patterns; write self-documenting code.
- Rails 8 enum syntax: `enum :status, {active: 0}` (colon prefix).
- Services use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. Never run `create_fixtures`, `db:drop`, `db:reset`, or `db:schema:load`. To inspect a fixture, read the YAML.
- Migration superclass is `ActiveRecord::Migration[8.1]`.
- Controller tests assert **behavior** (status codes, redirect targets, no errors) — never HTML, CSS, or copy.
- **Constant-resolution landmine:** inside `module ItemRankings::Books::Authors`, a bare `Books::Author` resolves to `ItemRankings::Books::Author` (because `ItemRankings::Books` exists) and raises `NameError`. Every reference to an app model from inside that namespace **must** be root-anchored: `::Books::Author`, `::Books::Book`, `::Books::BookAuthor`, `::Books::RankingConfiguration`. This is why `ItemRankings::Music::Artists::Calculator` writes `::Music::Artist`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `db/migrate/*_add_exclude_from_rankings_to_books_authors.rb` | Column + backfill for the placeholder author |
| `db/migrate/*_create_books_authors_ranking_configuration.rb` | Creates the singleton author ranking configuration row |
| `app/models/books/authors/ranking_configuration.rb` | STI subclass, no new table |
| `app/lib/item_rankings/books/authors/score_formula.rb` | Pure scoring rule — no database access |
| `app/lib/item_rankings/books/authors/calculator.rb` | Aggregation query + write, via the inherited upsert |
| `app/sidekiq/books/calculate_author_rankings_job.rb` | Job wrapper, no arguments |
| `config/schedule.yml` | Daily cron entry |
| `app/lib/books/ranked_authors_query.rb` | The single place the ranked-author relation is built |
| `app/lib/books/top_books_for_authors_query.rb` | One query for every author's top books on a page |
| `app/controllers/books/authors/ranked_items_controller.rb` | `/authors` index |
| `app/controllers/books/authors_controller.rb` | `show` and `all_books` |
| `app/controllers/books/legacy_authors_controller.rb` | 301 from `/authors/:id` |
| `app/components/books/author_avatar_component.{rb,html.erb}` | Show page only: image or initials monogram |
| `app/views/books/authors/ranked_items/index.html.erb` | Index view |
| `app/views/books/authors/{show,all_books}.html.erb` | Show and all-books views |

---

## Task 1: Exclude placeholder authors from rankings

Adds the flag that replaces the old site's hardcoded `next if author.id == 10452`.

**Files:**
- Create: `db/migrate/<timestamp>_add_exclude_from_rankings_to_books_authors.rb`
- Modify: `app/views/admin/books/authors/_form.html.erb`
- Modify: `app/controllers/admin/books/authors_controller.rb:94`
- Modify: `test/fixtures/books/authors.yml`
- Test: `test/models/books/author_test.rb`, `test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `books_authors.exclude_from_rankings` (boolean, `null: false`, `default: false`); fixture `books_authors(:excluded_placeholder)`.

- [ ] **Step 1: Generate the migration**

```bash
cd web-app
bin/rails generate migration AddExcludeFromRankingsToBooksAuthors
```

- [ ] **Step 2: Write the migration body**

Replace the generated file's contents. The backfill is scoped to an exact name match; there is exactly one such row in production and dev.

```ruby
class AddExcludeFromRankingsToBooksAuthors < ActiveRecord::Migration[8.1]
  def up
    add_column :books_authors, :exclude_from_rankings, :boolean, null: false, default: false
    Books::Author.reset_column_information
    Books::Author.where(name: "Unknown").update_all(exclude_from_rankings: true)
  end

  def down
    remove_column :books_authors, :exclude_from_rankings
  end
end
```

No index: the ranking query is driven by `ranked_items` and reaches this column only through an already-indexed join, and with one `true` row out of 58,223 an index would never be selected.

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
```

Expected: `books_authors` gains the column, and `db/schema.rb` is updated.

- [ ] **Step 4: Add a fixture for an excluded author**

Append to `test/fixtures/books/authors.yml`:

```yaml
excluded_placeholder:
  name: Unknown
  slug: unknown
  kind: 0
  exclude_from_rankings: true
```

- [ ] **Step 5: Write the failing model test**

Append inside the existing class in `test/models/books/author_test.rb`:

```ruby
test "exclude_from_rankings defaults to false" do
  author = Books::Author.new(name: "Test Author")

  assert_not author.exclude_from_rankings
end

test "exclude_from_rankings can be set" do
  assert books_authors(:excluded_placeholder).exclude_from_rankings
end
```

- [ ] **Step 6: Run the model test**

```bash
bin/rails test test/models/books/author_test.rb
```

Expected: PASS (the column and fixture already exist after steps 2–4).

- [ ] **Step 7: Permit the parameter**

In `app/controllers/admin/books/authors_controller.rb`, change the permit list:

```ruby
params.require(:books_author).permit(:name, :sort_name, :kind, :birth_year, :death_year, :exclude_from_rankings)
```

- [ ] **Step 8: Write the failing admin controller test**

Append inside the existing `Admin::Books::AuthorsControllerTest` class in `test/controllers/admin/books/authors_controller_test.rb`. That file's `setup` block already assigns `@admin_user`, `@regular_user`, `@author` (Tolstoy) and calls `host! Rails.application.config.domains[:books]`, so this test only needs to sign in.

```ruby
test "update sets exclude_from_rankings" do
  sign_in_as(@admin_user, stub_auth: true)

  patch admin_books_author_path(@author), params: {
    books_author: {exclude_from_rankings: "1"}
  }

  assert @author.reload.exclude_from_rankings
end
```

- [ ] **Step 9: Run the admin controller test**

```bash
bin/rails test test/controllers/admin/books/authors_controller_test.rb
```

Expected: PASS.

- [ ] **Step 10: Add the checkbox to the admin form**

In `app/views/admin/books/authors/_form.html.erb`, inside the `Basic Information` card's `grid` div, after the `death_year` field:

```erb
<div class="form-control md:col-span-2">
  <%= f.label :exclude_from_rankings, class: "label cursor-pointer justify-start gap-3" do %>
    <%= f.check_box :exclude_from_rankings, class: "checkbox checkbox-primary" %>
    <span class="label-text font-semibold">Exclude from author rankings</span>
  <% end %>
  <label class="label">
    <span class="label-text-alt">For placeholder records such as "Unknown" that should never appear in The Greatest Authors.</span>
  </label>
</div>
```

- [ ] **Step 11: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

Expected: all green.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "Add exclude_from_rankings flag to Books::Author"
```

---

## Task 2: The scoring formula

A pure object with no database access, so the multiplier ladder is testable without fixtures.

**Files:**
- Create: `app/lib/item_rankings/books/authors/score_formula.rb`
- Test: `test/lib/item_rankings/books/authors/score_formula_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `ItemRankings::Books::Authors::ScoreFormula.call(book_count:, total_score:) -> BigDecimal` and `.count_multiplier(book_count) -> BigDecimal`. Task 3 calls `.call`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/item_rankings/books/authors/score_formula_test.rb`:

```ruby
require "test_helper"

module ItemRankings
  module Books
    module Authors
      class ScoreFormulaTest < ActiveSupport::TestCase
        test "count_multiplier follows the saturating ladder" do
          expected = {
            1 => 0.3056,
            2 => 0.5556,
            3 => 0.7500,
            4 => 0.8889,
            5 => 0.9722,
            6 => 1.0000
          }

          expected.each do |count, multiplier|
            assert_in_delta multiplier,
              ScoreFormula.count_multiplier(count),
              0.0001,
              "multiplier for #{count} book(s)"
          end
        end

        test "count_multiplier saturates above six books" do
          assert_equal ScoreFormula.count_multiplier(6), ScoreFormula.count_multiplier(7)
          assert_equal ScoreFormula.count_multiplier(6), ScoreFormula.count_multiplier(70)
        end

        test "a single ranked book is floored, not zeroed" do
          score = ScoreFormula.call(book_count: 1, total_score: 1000)

          assert score > 0, "a one-book author must not score zero"
          assert_in_delta 305.6, score, 0.1
        end

        test "six or more books keep the full total" do
          assert_in_delta 1000.0, ScoreFormula.call(book_count: 6, total_score: 1000), 0.01
          assert_in_delta 1000.0, ScoreFormula.call(book_count: 20, total_score: 1000), 0.01
        end

        test "the five to six transition is not a cliff" do
          five = ScoreFormula.call(book_count: 5, total_score: 1000)
          six = ScoreFormula.call(book_count: 6, total_score: 1000)

          assert_in_delta 0.0278, (six - five) / six, 0.001,
            "the jump from five to six books must stay near 2.8 percent"
        end

        test "returns zero for a non-positive book count" do
          assert_equal 0, ScoreFormula.call(book_count: 0, total_score: 1000)
        end

        test "returns a BigDecimal" do
          assert_instance_of BigDecimal, ScoreFormula.call(book_count: 3, total_score: 100)
        end

        test "accepts string inputs from a raw SQL result row" do
          assert_in_delta 750.0, ScoreFormula.call(book_count: "3", total_score: "1000.0"), 0.01
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/item_rankings/books/authors/score_formula_test.rb
```

Expected: FAIL with `NameError: uninitialized constant ItemRankings::Books::Authors`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/item_rankings/books/authors/score_formula.rb`:

```ruby
# frozen_string_literal: true

module ItemRankings
  module Books
    module Authors
      class ScoreFormula
        SATURATION_COUNT = 6

        def self.call(book_count:, total_score:)
          count = book_count.to_i
          return BigDecimal(0) if count < 1

          BigDecimal(total_score.to_s) * count_multiplier(count)
        end

        def self.count_multiplier(book_count)
          capped = [book_count.to_i, SATURATION_COUNT].min
          shortfall = 1.0 - (capped.to_f / SATURATION_COUNT)

          BigDecimal((1.0 - (shortfall**2)).to_s)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/item_rankings/books/authors/score_formula_test.rb
```

Expected: PASS, 8 assertions groups green.

- [ ] **Step 5: Lint**

```bash
bundle exec standardrb app/lib/item_rankings/books/authors/score_formula.rb test/lib/item_rankings/books/authors/score_formula_test.rb
```

- [ ] **Step 6: Commit**

```bash
git add app/lib/item_rankings/books/authors/score_formula.rb test/lib/item_rankings/books/authors/score_formula_test.rb
git commit -m "Add author score formula with saturating book-count multiplier"
```

---

## Task 3: The ranking configuration and calculator

**Files:**
- Create: `app/models/books/authors/ranking_configuration.rb`
- Create: `db/migrate/<timestamp>_create_books_authors_ranking_configuration.rb`
- Create: `app/lib/item_rankings/books/authors/calculator.rb`
- Modify: `app/models/ranking_configuration.rb:137-155` (`calculator_service`)
- Modify: `app/models/ranked_item.rb` (`item_type_matches_ranking_configuration`)
- Modify: `test/fixtures/ranking_configurations.yml`
- Test: `test/lib/item_rankings/books/authors/calculator_test.rb`

**Interfaces:**
- Consumes: `ItemRankings::Books::Authors::ScoreFormula.call` (Task 2); `books_authors.exclude_from_rankings` (Task 1).
- Produces: `Books::Authors::RankingConfiguration`; `ItemRankings::Books::Authors::Calculator#call -> Result`; fixture `ranking_configurations(:books_authors_global)`. Tasks 4–6 depend on `Books::Authors::RankingConfiguration.default_primary`.

- [ ] **Step 1: Generate the STI model**

`--no-fixture` is **mandatory**. A generated fixture file for an STI subclass of an existing table breaks the whole suite — this cost a debugging cycle during the `Books::UserList` work.

```bash
cd web-app
bin/rails generate model Books::Authors::RankingConfiguration --parent=RankingConfiguration --no-migration --no-fixture
```

- [ ] **Step 2: Write the model body**

Replace `app/models/books/authors/ranking_configuration.rb` with the nested-module style used by `app/models/music/artists/ranking_configuration.rb`:

```ruby
module Books
  module Authors
    class RankingConfiguration < ::RankingConfiguration
    end
  end
end
```

Note the superclass is `::RankingConfiguration`, **not** `Books::RankingConfiguration`. Task 4 relies on the two being distinct types so the chained job cannot recurse.

- [ ] **Step 3: Add the fixture**

Append to `test/fixtures/ranking_configurations.yml`:

```yaml
books_authors_global:
  type: Books::Authors::RankingConfiguration
  name: "Global Books Authors Ranking"
  description: "The main ranking configuration for book authors"
  global: true
  primary: true
  archived: false
  published_at: 2026-08-02 00:00:00
  algorithm_version: 1
  exponent: 3.0
  bonus_pool_percentage: 3.0
  min_list_weight: 1
  apply_list_dates_penalty: false
  inherit_penalties: false
```

- [ ] **Step 4: Write the failing calculator test**

Create `test/lib/item_rankings/books/authors/calculator_test.rb`. `test/fixtures/ranked_items.yml` deliberately contains only *unranked* items, so this test builds its own ranked books.

```ruby
require "test_helper"

module ItemRankings
  module Books
    module Authors
      class CalculatorTest < ActiveSupport::TestCase
        setup do
          @config = ranking_configurations(:books_authors_global)
          @source = ranking_configurations(:books_global)
          @calculator = ItemRankings::Books::Authors::Calculator.new(@config)

          @source.ranked_items.destroy_all
          @config.ranked_items.destroy_all

          @tolstoy = books_authors(:tolstoy)
          @king = books_authors(:king)
          @placeholder = books_authors(:excluded_placeholder)
        end

        def rank_book(book, score)
          RankedItem.create!(
            item: book,
            ranking_configuration: @source,
            rank: @source.ranked_items.count + 1,
            score: score
          )
        end

        def credit(book, author, role: :author)
          ::Books::BookAuthor.find_or_create_by!(book: book, author: author) do |ba|
            ba.role = role
          end.tap { |ba| ba.update!(role: role) }
        end

        test "item_type returns Books::Author" do
          assert_equal "Books::Author", @calculator.send(:item_type)
        end

        test "list_type raises NotImplementedError" do
          assert_raises(NotImplementedError) { @calculator.send(:list_type) }
        end

        test "writes ranked items ordered by score with sequential ranks" do
          credit(books_books(:war_and_peace), @tolstoy)
          credit(books_books(:crime_and_punishment), @tolstoy)
          credit(books_books(:got), @king)
          rank_book(books_books(:war_and_peace), 100)
          rank_book(books_books(:crime_and_punishment), 100)
          rank_book(books_books(:got), 50)

          result = @calculator.call

          assert result.success?, "expected success, got #{result.errors}"

          items = @config.ranked_items.order(:rank)
          assert_equal [1, 2], items.pluck(:rank)
          assert_equal @tolstoy.id, items.first.item_id
          scores = items.pluck(:score)
          assert_equal scores.sort.reverse, scores
        end

        test "applies the count multiplier" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 1000)

          @calculator.call

          item = @config.ranked_items.find_by(item: @tolstoy)
          assert_in_delta 305.6, item.score, 0.1
        end

        test "excludes editor credits" do
          credit(books_books(:war_and_peace), @king, role: :editor)
          rank_book(books_books(:war_and_peace), 100)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @king)
        end

        test "excludes authors flagged exclude_from_rankings" do
          credit(books_books(:war_and_peace), @placeholder)
          rank_book(books_books(:war_and_peace), 100)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @placeholder)
        end

        test "ignores books with a non-positive score" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 0)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @tolstoy)
        end

        test "deletes ranked items that no longer qualify" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)
          @calculator.call
          assert @config.ranked_items.find_by(item: @tolstoy)

          @source.ranked_items.destroy_all
          credit(books_books(:got), @king)
          rank_book(books_books(:got), 100)
          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @tolstoy)
          assert @config.ranked_items.find_by(item: @king)
        end

        test "is idempotent" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)

          @calculator.call
          first = @config.ranked_items.order(:rank).pluck(:item_id, :rank, :score)
          @calculator.call
          second = @config.ranked_items.order(:rank).pluck(:item_id, :rank, :score)

          assert_equal first, second
        end

        test "fails without writing when there is no primary books configuration" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)
          @source.update!(primary: false)

          result = @calculator.call

          assert_not result.success?
          assert_not_empty result.errors
          assert_equal 0, @config.ranked_items.count
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it fails**

```bash
bin/rails test test/lib/item_rankings/books/authors/calculator_test.rb
```

Expected: FAIL with `NameError: uninitialized constant ItemRankings::Books::Authors::Calculator`.

- [ ] **Step 6: Write the calculator**

Create `app/lib/item_rankings/books/authors/calculator.rb`. Every model reference is root-anchored — see the constant-resolution landmine in Global Constraints.

```ruby
# frozen_string_literal: true

module ItemRankings
  module Books
    module Authors
      class Calculator < ItemRankings::Calculator
        def call
          source = ::Books::RankingConfiguration.default_primary

          if source.nil?
            return Result.new(
              success?: false,
              data: nil,
              errors: ["No primary Books::RankingConfiguration to derive author scores from"]
            )
          end

          ranking_data = author_scores(source)
          update_ranked_items(ranking_data)

          Result.new(success?: true, data: ranking_data, errors: [])
        rescue => error
          Result.new(success?: false, data: nil, errors: [error.message])
        end

        protected

        def list_type
          raise NotImplementedError, "Authors are derived from ranked books, not ranked from lists"
        end

        def item_type
          "Books::Author"
        end

        private

        def author_scores(source)
          rows = ActiveRecord::Base.connection.select_all(aggregation_sql(source.id))

          rows.filter_map { |row|
            score = ScoreFormula.call(
              book_count: row["book_count"],
              total_score: row["total_score"]
            )
            {id: row["author_id"], total_score: score} if score > 0
          }.sort_by { |author| -author[:total_score] }
        end

        def aggregation_sql(source_id)
          <<~SQL
            SELECT ba.author_id AS author_id,
                   COUNT(*) AS book_count,
                   SUM(ri.score) AS total_score
            FROM ranked_items ri
            JOIN books_book_authors ba ON ba.book_id = ri.item_id
            JOIN books_authors a ON a.id = ba.author_id
            WHERE ri.item_type = 'Books::Book'
              AND ri.ranking_configuration_id = #{source_id.to_i}
              AND ri.score > 0
              AND ba.role = #{::Books::BookAuthor.roles[:author].to_i}
              AND a.exclude_from_rankings = FALSE
            GROUP BY ba.author_id
          SQL
        end
      end
    end
  end
end
```

`update_ranked_items` is inherited from `ItemRankings::Calculator`. It takes `[{id:, total_score:}]` already sorted, assigns `rank = index + 1`, upserts on `index_ranked_items_on_item_and_ranking_config_unique`, and deletes rows that dropped out — all in one transaction. Do **not** reimplement it; `ItemRankings::Music::Artists::Calculator` duplicates it and that duplication is the thing being avoided here.

- [ ] **Step 7: Register the calculator**

In `app/models/ranking_configuration.rb`, inside `calculator_service`, add a branch immediately after the `"Books::RankingConfiguration"` branch:

```ruby
when "Books::Authors::RankingConfiguration"
  ItemRankings::Books::Authors::Calculator.new(self)
```

- [ ] **Step 8: Add the RankedItem type validation**

In `app/models/ranked_item.rb`, inside `item_type_matches_ranking_configuration`, add after the `"Books::RankingConfiguration"` branch:

```ruby
when "Books::Authors::RankingConfiguration"
  errors.add(:item, "must be a Books::Author") unless item.is_a?(Books::Author)
```

- [ ] **Step 9: Run the calculator test**

```bash
bin/rails test test/lib/item_rankings/books/authors/calculator_test.rb
```

Expected: PASS.

- [ ] **Step 10: Generate the configuration-row migration**

```bash
bin/rails generate migration CreateBooksAuthorsRankingConfiguration
```

- [ ] **Step 11: Write the migration body**

`db/seeds.rb` seeds only global penalties — no ranking configuration is seeded there for any domain — and the Task 4 job hard-fails without this row, so it is created by migration to guarantee it exists in production.

```ruby
class CreateBooksAuthorsRankingConfiguration < ActiveRecord::Migration[8.1]
  def up
    return if Books::Authors::RankingConfiguration.exists?

    Books::Authors::RankingConfiguration.create!(
      name: "The Greatest Authors",
      description: "Authors ranked by aggregating the scores of their ranked books.",
      global: true,
      primary: true,
      published_at: Time.current,
      apply_list_dates_penalty: false,
      inherit_penalties: false
    )
  end

  def down
    Books::Authors::RankingConfiguration.destroy_all
  end
end
```

- [ ] **Step 12: Run the migration**

```bash
bin/rails db:migrate
```

- [ ] **Step 13: Verify against real development data**

```bash
bin/rails runner 'r = Books::Authors::RankingConfiguration.default_primary.calculate_rankings; puts "success=#{r.success?} errors=#{r.errors}"; puts RankedItem.where(ranking_configuration: Books::Authors::RankingConfiguration.default_primary).order(:rank).limit(10).map { |i| "#{i.rank}. #{i.item.name} #{i.score}" }'
```

Expected: `success=true`, roughly 14,900 rows written, and a top ten led by Dostoevsky, Dickens, and Faulkner — **not** by "Unknown", which the exclusion flag removes.

- [ ] **Step 14: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

- [ ] **Step 15: Commit**

```bash
git add -A
git commit -m "Add Books::Authors ranking configuration and calculator"
```

---

## Task 4: Job and scheduling

**Files:**
- Create: `app/sidekiq/books/calculate_author_rankings_job.rb`
- Modify: `config/schedule.yml`
- Modify: `app/sidekiq/calculate_rankings_job.rb`
- Test: `test/sidekiq/books/calculate_author_rankings_job_test.rb`, `test/sidekiq/calculate_rankings_job_test.rb`

**Interfaces:**
- Consumes: `Books::Authors::RankingConfiguration.default_primary` (Task 3).
- Produces: `Books::CalculateAuthorRankingsJob#perform` (no arguments).

- [ ] **Step 1: Generate the job**

Use the sidekiq generator, never `generate job`.

```bash
cd web-app
bin/rails generate sidekiq:job books/calculate_author_rankings
```

- [ ] **Step 2: Write the failing job test**

Replace `test/sidekiq/books/calculate_author_rankings_job_test.rb`:

```ruby
require "test_helper"

module Books
  class CalculateAuthorRankingsJobTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_authors_global)
    end

    test "calculates rankings for the primary author configuration" do
      Books::Authors::RankingConfiguration.any_instance
        .expects(:calculate_rankings)
        .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))

      Books::CalculateAuthorRankingsJob.new.perform
    end

    test "raises when the calculation fails" do
      Books::Authors::RankingConfiguration.any_instance
        .expects(:calculate_rankings)
        .returns(ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["boom"]))

      assert_raises(RuntimeError) { Books::CalculateAuthorRankingsJob.new.perform }
    end

    test "raises when there is no primary author configuration" do
      @config.update!(primary: false)

      assert_raises(RuntimeError) { Books::CalculateAuthorRankingsJob.new.perform }
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/sidekiq/books/calculate_author_rankings_job_test.rb
```

Expected: FAIL — the generated job's `perform` takes arguments and does nothing.

- [ ] **Step 4: Write the job**

Replace `app/sidekiq/books/calculate_author_rankings_job.rb`:

```ruby
class Books::CalculateAuthorRankingsJob
  include Sidekiq::Job

  def perform
    config = Books::Authors::RankingConfiguration.default_primary

    if config.nil?
      Rails.logger.error "No primary Books::Authors::RankingConfiguration; author rankings not calculated"
      raise "No primary Books::Authors::RankingConfiguration"
    end

    result = config.calculate_rankings

    if result.success?
      Rails.logger.info "Successfully calculated author rankings for configuration #{config.id}"
    else
      Rails.logger.error "Failed to calculate author rankings: #{result.errors}"
      raise "Author ranking calculation failed: #{result.errors.join(", ")}"
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/sidekiq/books/calculate_author_rankings_job_test.rb
```

Expected: PASS.

- [ ] **Step 6: Write the failing chain test**

Append inside the existing class in `test/sidekiq/calculate_rankings_job_test.rb`:

```ruby
test "enqueues the author ranking job after a books configuration succeeds" do
  config = ranking_configurations(:books_global)
  RankingConfiguration.any_instance
    .expects(:calculate_rankings)
    .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))
  Books::CalculateAuthorRankingsJob.expects(:perform_async).once

  CalculateRankingsJob.new.perform(config.id)
end

test "does not enqueue the author ranking job for an author configuration" do
  config = ranking_configurations(:books_authors_global)
  RankingConfiguration.any_instance
    .expects(:calculate_rankings)
    .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))
  Books::CalculateAuthorRankingsJob.expects(:perform_async).never

  CalculateRankingsJob.new.perform(config.id)
end
```

These assert on `perform_async` rather than on a queue size. `test/test_helper.rb` sets `Sidekiq::Testing.inline!` globally, so `perform_async` executes the job immediately and `Books::CalculateAuthorRankingsJob.jobs` is always empty — a queue-size assertion would silently never fire.

That same `inline!` setting means the chain makes any *other* test which drives `CalculateRankingsJob` with a books configuration run the real author calculation inline. Step 12's full-suite run is the check for that; if a previously-passing test slows sharply or starts failing, mock `Books::CalculateAuthorRankingsJob.perform_async` in that test too.

- [ ] **Step 7: Run the chain test to verify it fails**

```bash
bin/rails test test/sidekiq/calculate_rankings_job_test.rb
```

Expected: FAIL — no job is enqueued.

- [ ] **Step 8: Add the chain**

In `app/sidekiq/calculate_rankings_job.rb`, inside the `if result.success?` branch, after the existing log line:

```ruby
Books::CalculateAuthorRankingsJob.perform_async if ranking_configuration.type == "Books::RankingConfiguration"
```

The check is on the exact `type` string, not `is_a?`. `Books::Authors::RankingConfiguration` inherits from `::RankingConfiguration` rather than `Books::RankingConfiguration`, so `is_a?` would be correct today — but an exact match makes it impossible for a later subclass change to make this job enqueue itself in a loop.

- [ ] **Step 9: Run the chain test to verify it passes**

```bash
bin/rails test test/sidekiq/calculate_rankings_job_test.rb
```

Expected: PASS.

- [ ] **Step 10: Add the cron entry**

Append to `config/schedule.yml`. Note the existing file's last line has no trailing newline — add one before appending.

```yaml

books_author_rankings:
  class: Books::CalculateAuthorRankingsJob
  cron: "0 4 * * *"
  description: "Recalculate The Greatest Authors from ranked books"
```

- [ ] **Step 11: Verify the schedule parses**

```bash
bin/rails runner 'puts YAML.load_file(Rails.root.join("config/schedule.yml")).keys.inspect'
```

Expected: `["search_indexing", "books_author_rankings"]`.

- [ ] **Step 12: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "Add daily author ranking job and chain it to books ranking runs"
```

---

## Task 5: The ranked authors index page

**Files:**
- Create: `app/lib/books/ranked_authors_query.rb`
- Create: `app/lib/books/top_books_for_authors_query.rb`
- Create: `app/controllers/books/authors/ranked_items_controller.rb`
- Create: `app/views/books/authors/ranked_items/index.html.erb`
- Modify: `config/routes.rb` (books domain block, near the existing `lists` routes)
- Modify: `app/views/layouts/books/application.html.erb:31,42`
- Test: `test/controllers/books/authors/ranked_items_controller_test.rb`

**Interfaces:**
- Consumes: `Books::Authors::RankingConfiguration.default_primary` (Task 3).
- Produces: `Books::RankedAuthorsQuery.call(ranking_configuration:) -> RankedItem::ActiveRecord_Relation`; `Books::TopBooksForAuthorsQuery.call(author_ids:, ranking_configuration:, limit:) -> Hash[Integer => Array[Books::Book]]`; named routes `books_authors_path`, `books_authors_page_path`.

- [ ] **Step 1: Write the failing controller test**

Both new query objects go in `app/lib/books/`, beside the existing `app/lib/books/ranked_books_query.rb`, and use the same `module Books` nesting.

Create `test/controllers/books/authors/ranked_items_controller_test.rb`:

```ruby
require "test_helper"

module Books
  module Authors
    class RankedItemsControllerTest < ActionDispatch::IntegrationTest
      # Set to the count observed on the first run -- see the note below this
      # test file in the plan for how to determine it.
      EXPECTED_INDEX_QUERIES = 0

      setup do
        host! "dev-new.thegreatestbooks.org"
        @config = ranking_configurations(:books_authors_global)
        @config.ranked_items.destroy_all
        RankedItem.create!(item: books_authors(:tolstoy), ranking_configuration: @config, rank: 1, score: 100)
        RankedItem.create!(item: books_authors(:king), ranking_configuration: @config, rank: 2, score: 90)
      end

      test "renders the ranked author index" do
        get "/authors"

        assert_response :success
      end

      test "page one redirects to the canonical index" do
        get "/authors/page/1"

        assert_redirected_to "/authors"
        assert_response :moved_permanently
      end

      test "path-based pagination resolves the page" do
        seed_ranked_authors(120)

        get "/authors/page/2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "404s past the last page" do
        get "/authors/page/99"

        assert_response :not_found
      end

      test "sets a public cache-control header" do
        get "/authors"

        assert_match(/max-age=21600/, response.headers["Cache-Control"])
        assert_match(/public/, response.headers["Cache-Control"])
      end

      test "index issues a fixed number of queries" do
        seed_ranked_authors(10)

        assert_queries_count(EXPECTED_INDEX_QUERIES) { get "/authors" }
      end

      test "query count does not grow with the number of authors" do
        seed_ranked_authors(10)
        small = count_queries { get "/authors" }

        seed_ranked_authors(60)
        large = count_queries { get "/authors" }

        assert_equal small, large,
          "query count grew from #{small} to #{large} as authors were added -- N+1 in the index"
      end

      private

      def seed_ranked_authors(count)
        start = @config.ranked_items.maximum(:rank).to_i
        count.times do |i|
          author = Books::Author.create!(name: "Seeded Author #{start + i}")
          RankedItem.create!(
            item: author,
            ranking_configuration: @config,
            rank: start + i + 1,
            score: 10
          )
        end
      end

      def count_queries(&block)
        count = 0
        counter = lambda do |_name, _start, _finish, _id, payload|
          count += 1 unless %w[CACHE SCHEMA TRANSACTION].include?(payload[:name])
        end
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
        count
      end
    end
  end
end
```

**Two guards on purpose.** `assert_queries_count` matches the pins in `test/controllers/books/lists_controller_test.rb:80` and catches a silent extra constant-cost query. The growth assertion catches a true N+1, which an exact pin alone would miss if the seed count happened to match.

`EXPECTED_INDEX_QUERIES` starts at `0` so the test fails loudly on the first run. Run it once, read the actual count from the failure message (`Expected: 0, Actual: N`), and set the constant to that N. Then delete the placeholder comment above it. Do **not** leave it at 0, and do **not** guess the value — it must come from an observed run.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/controllers/books/authors/ranked_items_controller_test.rb
```

Expected: FAIL with routing errors — no `/authors` route exists.

- [ ] **Step 3: Write the ranked authors query**

Create `app/lib/books/ranked_authors_query.rb`, mirroring `ranked_books_query.rb`:

```ruby
module Books
  # The single place the ranked-authors relation is built, so a later filtering
  # increment can swap the engine here without touching views.
  class RankedAuthorsQuery
    def self.call(ranking_configuration:)
      RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Author")
        .where.not(rank: nil)
        .includes(item: :descriptions)
        .order(:rank)
    end
  end
end
```

- [ ] **Step 4: Write the top-books query**

Create `app/lib/books/top_books_for_authors_query.rb`. A window function fetches every author's top books in one pass; rendering them per author would be one query per row.

```ruby
module Books
  class TopBooksForAuthorsQuery
    def self.call(author_ids:, ranking_configuration:, limit: 5)
      return {} if author_ids.blank? || ranking_configuration.nil?

      sql = <<~SQL
        SELECT author_id, book_id FROM (
          SELECT ba.author_id AS author_id,
                 ri.item_id AS book_id,
                 ROW_NUMBER() OVER (PARTITION BY ba.author_id ORDER BY ri.rank ASC) AS position
          FROM ranked_items ri
          JOIN books_book_authors ba ON ba.book_id = ri.item_id
          WHERE ri.item_type = 'Books::Book'
            AND ri.ranking_configuration_id = :rc_id
            AND ri.rank IS NOT NULL
            AND ba.role = :role
            AND ba.author_id IN (:author_ids)
        ) ranked
        WHERE position <= :limit
      SQL

      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([
          sql,
          {
            rc_id: ranking_configuration.id,
            role: ::Books::BookAuthor.roles[:author],
            author_ids: author_ids,
            limit: limit
          }
        ])
      ).to_a

      books = ::Books::Book
        .where(id: rows.map { |row| row["book_id"] }.uniq)
        .includes(primary_image: {file_attachment: :blob})
        .index_by(&:id)

      rows.each_with_object({}) do |row, grouped|
        book = books[row["book_id"]]
        next unless book

        (grouped[row["author_id"]] ||= []) << book
      end
    end
  end
end
```

- [ ] **Step 5: Write the controller**

Create `app/controllers/books/authors/ranked_items_controller.rb`:

```ruby
class Books::Authors::RankedItemsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :cache_for_index_page, only: [:index]

  def index
    @indexable = true
    @ranking_configuration = Books::Authors::RankingConfiguration.default_primary

    if @ranking_configuration.nil?
      reject_paged_request!
      @ranked_authors = []
      @pagy = nil
      @top_books = {}
      return
    end

    @pagy, @ranked_authors = pagy_path(
      Books::RankedAuthorsQuery.call(ranking_configuration: @ranking_configuration),
      limit: 100
    )

    @top_books = Books::TopBooksForAuthorsQuery.call(
      author_ids: @ranked_authors.map(&:item_id),
      ranking_configuration: Books::RankingConfiguration.default_primary
    )
  end
end
```

- [ ] **Step 6: Add the routes**

In `config/routes.rb`, inside the books `DomainConstraint` block, immediately before the `get "lists", ...` line:

```ruby
get "authors/page/1", to: redirect("/authors", status: 301)
get "authors", to: "books/authors/ranked_items#index", as: :books_authors
get "authors/page/:page", to: "books/authors/ranked_items#index",
  as: :books_authors_page, constraints: {page: /\d+/}
```

Order matters: `/authors/page/1` must precede the generic `/authors/page/:page`.

- [ ] **Step 7: Write the index view**

Create `app/views/books/authors/ranked_items/index.html.erb`. There is deliberately **no author avatar here** — rows lead with the name, and the book covers carry the visual weight.

```erb
<%
  content_for :page_title, "The Greatest Authors of All Time | The Greatest Books"
  content_for :meta_description, "A ranking of the greatest authors of all time, derived from the ranked books of every author across hundreds of published book lists."
%>

<div class="space-y-8">
  <div class="bg-base-100 border border-base-300 rounded-xl p-6 md:p-10">
    <div class="max-w-3xl mx-auto space-y-3">
      <p class="text-base sm:text-lg leading-relaxed text-base-content/80">
        Authors are not ranked from lists of authors. Each author's score is built from their
        own books: we add up the scores of every book of theirs that appears in our ranking.
      </p>
      <p class="text-base-content/70">
        Writing more than one great book counts for a great deal, so an author's total is scaled
        by how many of their books are ranked, levelling off at six. An author with a single
        ranked book still places, just below those with a body of work behind them.
      </p>
    </div>
  </div>

  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance">The Greatest Authors of All Time</h1>

  <% if @ranked_authors.any? %>
    <ol class="space-y-6">
      <% @ranked_authors.each do |ranked_item| %>
        <% author = ranked_item.item %>
        <li class="border-b border-base-300 pb-6">
          <div class="flex items-baseline gap-3 flex-wrap">
            <span class="text-2xl font-bold text-base-content/50"><%= ranked_item.rank %></span>
            <h2 class="text-xl font-semibold">
              <%= link_to author.name, author_path(author.slug), class: "link link-hover" %>
            </h2>
            <% if author.birth_year %>
              <span class="text-sm text-base-content/60">
                <%= author.birth_year %><%= "–#{author.death_year}" if author.death_year %>
              </span>
            <% end %>
            <span class="badge badge-ghost ml-auto">
              <span class="sr-only">Score </span><%= number_with_delimiter(ranked_item.score.to_i) %>
            </span>
          </div>

          <% if (description = author.primary_description) %>
            <p class="mt-2 text-base-content/80 line-clamp-3"><%= description.content %></p>
          <% end %>

          <% if (books = @top_books[author.id]).present? %>
            <div class="mt-3 flex gap-2 flex-wrap">
              <% books.each do |book| %>
                <%= link_to book_path(book.slug), class: "block w-16 shrink-0" do %>
                  <% if book.primary_image&.file&.attached? %>
                    <%= image_tag rails_public_blob_url(book.primary_image.file),
                        alt: book.title, loading: "lazy", decoding: "async",
                        class: "w-16 h-auto rounded shadow-sm" %>
                  <% else %>
                    <div class="w-16 aspect-[2/3] bg-base-300 rounded flex items-center justify-center" aria-hidden="true">
                      <span class="text-xl opacity-40">📖</span>
                    </div>
                  <% end %>
                <% end %>
              <% end %>
            </div>
          <% end %>
        </li>
      <% end %>
    </ol>

    <div class="flex justify-center">
      <%== @pagy.series_nav(slots: 5) %>
    </div>
    <p class="text-center text-sm text-base-content/70">
      Page <%= number_with_delimiter(@pagy.page) %> of <%= number_with_delimiter(@pagy.last) %>
    </p>
  <% else %>
    <div class="text-center py-16">
      <div class="text-6xl mb-4">✍️</div>
      <h2 class="text-2xl font-bold mb-2">No authors ranked yet</h2>
      <p class="text-base-content/70">Author rankings are calculated daily from ranked books.</p>
    </div>
  <% end %>
</div>
```

`book_path` comes from the existing books routes. `author_path` is added by Step 8 immediately below, and its controller and view stubs by Step 11, so the view renders by the time Step 10 runs the tests.

- [ ] **Step 8: Add the show route needed by the index links**

The index links to `author_path`. Add the show route now (its controller arrives in Task 6):

```ruby
scope "(/rc/:ranking_configuration_id)" do
  get "author/:slug", to: "books/authors#show", as: :author
end
```

Place this alongside the existing `get "book/:slug"` scope block. Do **not** add a `constraints:` option to a route inside a `scope "(/rc/...)"` block — it disables the optimized URL helper and the positional argument binds to the rc segment.

- [ ] **Step 9: Add the nav links**

In `app/views/layouts/books/application.html.erb`, add an Authors entry after each of the two `Lists` entries (lines 31 and 42):

```erb
<li><%= link_to "Authors", books_authors_path %></li>
```

- [ ] **Step 10: Run the controller test**

```bash
bin/rails test test/controllers/books/authors/ranked_items_controller_test.rb
```

Expected: PASS. None of these tests request `/author/:slug`, and Rails resolves controllers lazily, so the show route pointing at a not-yet-written controller does not break the index.

If the query-growth test fails, the top-books lookup is running per author — check that `TopBooksForAuthorsQuery` is called once in the controller and never from inside the view loop.

- [ ] **Step 11: Create a placeholder show controller so the suite is green**

Create `app/controllers/books/authors_controller.rb` with the minimum needed to route; Task 6 fills it in:

```ruby
class Books::AuthorsController < ApplicationController
  layout "books/application"

  def show
    @author = Books::Author.find_by!(slug: params[:slug])
  end
end
```

Create `app/views/books/authors/show.html.erb`:

```erb
<h1 class="text-3xl font-bold"><%= @author.name %></h1>
```

- [ ] **Step 12: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

Expected: all green.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "Add the ranked authors index page"
```

---

## Task 6: Author show page, all-books page, and avatar

**Files:**
- Create: `app/components/books/author_avatar_component.rb`, `app/components/books/author_avatar_component.html.erb`
- Create: `app/controllers/books/legacy_authors_controller.rb`
- Modify: `app/controllers/books/authors_controller.rb` (replace the Task 5 placeholder)
- Modify: `app/views/books/authors/show.html.erb` (replace the Task 5 placeholder)
- Create: `app/views/books/authors/all_books.html.erb`
- Modify: `config/routes.rb`
- Test: `test/components/books/author_avatar_component_test.rb`, `test/controllers/books/authors_controller_test.rb`, `test/controllers/books/legacy_authors_controller_test.rb`

**Interfaces:**
- Consumes: `Books::Authors::RankingConfiguration.default_primary` (Task 3); `author_path` (Task 5).
- Produces: `Books::AuthorAvatarComponent.new(author:, size_classes:)`; routes `author_all_books_path`, `author_all_books_page_path`.

- [ ] **Step 1: Generate the component**

```bash
cd web-app
bin/rails generate component Books::AuthorAvatar author
```

If the generator places files in a subdirectory, move them to `app/components/books/author_avatar_component.{rb,html.erb}` to match the flat style of the existing `app/components/books/card_component.rb`.

- [ ] **Step 2: Write the failing component test**

Replace `test/components/books/author_avatar_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class AuthorAvatarComponentTest < ViewComponent::TestCase
    def initials_for(name)
      author = Books::Author.new(name: name)
      Books::AuthorAvatarComponent.new(author: author).send(:initials)
    end

    test "uses the first and last token" do
      assert_equal "FD", initials_for("Fyodor Dostoevsky")
    end

    test "skips particles because they sit mid-name" do
      assert_equal "PL", initials_for("Pierre Choderlos de Laclos")
      assert_equal "JG", initials_for("Johann Wolfgang von Goethe")
    end

    test "handles dotted initials" do
      assert_equal "WB", initials_for("W. E. B. Du Bois")
      assert_equal "FF", initials_for("F. Scott Fitzgerald")
    end

    test "handles single-token names" do
      assert_equal "H", initials_for("Homer")
      assert_equal "S", initials_for("Stendhal")
    end

    test "handles non-ASCII names" do
      assert_equal "EB", initials_for("Emily Brontë")
      assert_equal "GM", initials_for("Gabriel García Márquez")
      assert_equal "AD", initials_for("Alfred Döblin")
    end

    test "never exceeds two characters" do
      assert_equal 2, initials_for("Jalal al-Din Muhammad Rumi").length
    end

    test "renders the monogram when no image is attached" do
      render_inline(Books::AuthorAvatarComponent.new(author: books_authors(:tolstoy)))

      assert_selector "[aria-hidden='true']", text: "LT"
      assert_no_selector "img"
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/components/books/author_avatar_component_test.rb
```

Expected: FAIL — `initials` is not defined.

- [ ] **Step 4: Write the component**

Replace `app/components/books/author_avatar_component.rb`:

```ruby
# frozen_string_literal: true

class Books::AuthorAvatarComponent < ViewComponent::Base
  def initialize(author:, size_classes: "w-full aspect-square")
    @author = author
    @size_classes = size_classes
  end

  private

  attr_reader :author, :size_classes

  def image
    @image ||= author.primary_image if author.primary_image&.file&.attached?
  end

  def initials
    tokens = author.name.to_s.split(/\s+/).filter_map { |token| token[/[[:alnum:]]/] }
    return "" if tokens.empty?

    chosen = (tokens.size == 1) ? tokens.first(1) : [tokens.first, tokens.last]
    chosen.join.upcase
  end
end
```

The character class is `[[:alnum:]]`, not `[A-Za-z]`: 229 of the 3,000 top-ranked author names are non-ASCII and would otherwise yield blank initials.

- [ ] **Step 5: Write the component template**

Replace `app/components/books/author_avatar_component.html.erb`. One neutral surface tone for every author — never hash the name to a background hue; contrast comes from lightness, not colour.

```erb
<% if image %>
  <%= image_tag rails_public_blob_url(image.file),
      alt: author.name,
      loading: "eager", fetchpriority: "high", decoding: "async",
      class: "#{size_classes} object-cover rounded-xl" %>
<% else %>
  <div class="<%= size_classes %> bg-base-300 rounded-xl flex items-center justify-center" aria-hidden="true">
    <span class="text-5xl font-semibold tracking-wide text-base-content/40"><%= initials %></span>
  </div>
<% end %>
```

The monogram is decorative — the author's name always renders beside it — so `aria-hidden="true"` keeps a screen reader from announcing "LT" before "Leo Tolstoy".

- [ ] **Step 6: Run the component test**

```bash
bin/rails test test/components/books/author_avatar_component_test.rb
```

Expected: PASS.

- [ ] **Step 7: Write the failing controller tests**

Create `test/controllers/books/authors_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class AuthorsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @author = books_authors(:tolstoy)
      @author_config = ranking_configurations(:books_authors_global)
      @books_config = ranking_configurations(:books_global)
      @author_config.ranked_items.destroy_all
      RankedItem.create!(item: @author, ranking_configuration: @author_config, rank: 1, score: 100)
    end

    test "renders the author show page" do
      get "/author/#{@author.slug}"

      assert_response :success
    end

    test "renders an author with no ranked item" do
      @author_config.ranked_items.destroy_all

      get "/author/#{@author.slug}"

      assert_response :success
    end

    test "404s for an unknown slug" do
      get "/author/not-a-real-author"

      assert_response :not_found
    end

    test "sets a public cache-control header on show" do
      get "/author/#{@author.slug}"

      assert_match(/max-age=86400/, response.headers["Cache-Control"])
      assert_match(/public/, response.headers["Cache-Control"])
    end

    test "renders the all-books page" do
      get "/author/#{@author.slug}/all-books"

      assert_response :success
    end

    test "sets a public cache-control header on all-books" do
      get "/author/#{@author.slug}/all-books"

      assert_match(/max-age=86400/, response.headers["Cache-Control"])
    end

    test "404s past the last all-books page" do
      get "/author/#{@author.slug}/all-books/page/99"

      assert_response :not_found
    end

    test "renders show scoped to an explicit ranking configuration" do
      get "/rc/#{@books_config.id}/author/#{@author.slug}"

      assert_response :success
    end
  end
end
```

Create `test/controllers/books/legacy_authors_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class LegacyAuthorsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @author = books_authors(:tolstoy)
    end

    test "redirects the legacy author url to the slug url" do
      get "/authors/#{@author.id}"

      assert_redirected_to "/author/#{@author.slug}"
      assert_response :moved_permanently
    end

    test "redirects the legacy all_books url to the slug url" do
      get "/authors/#{@author.id}/all_books"

      assert_redirected_to "/author/#{@author.slug}"
      assert_response :moved_permanently
    end

    test "redirects legacy view urls to the index" do
      get "/authors/view/condensed"

      assert_redirected_to "/authors"
      assert_response :moved_permanently
    end

    test "404s for an unknown legacy id" do
      get "/authors/999999999"

      assert_response :not_found
    end
  end
end
```

- [ ] **Step 8: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/books/authors_controller_test.rb test/controllers/books/legacy_authors_controller_test.rb
```

Expected: FAIL — routes and actions do not exist.

- [ ] **Step 9: Write the show controller**

Replace `app/controllers/books/authors_controller.rb`:

```ruby
class Books::AuthorsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :load_ranking_configuration
  before_action :load_author
  before_action :cache_for_show_page

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def show
    @ranked_item = author_ranked_item
    @indexable = @ranked_item.present?
    @description = @author.primary_description
    @ranked_books = ranked_books.to_a
  end

  def all_books
    @indexable = false
    @ranked_item = author_ranked_item
    @pagy, @books = pagy_path(all_books_relation, limit: 50)
  end

  private

  # find_by!(slug:), never friendly.find: Books::Author uses friendly_id with
  # :finders, which resolves slugs before primary keys.
  def load_author
    @author = Books::Author.find_by!(slug: params[:slug])
  end

  def author_ranked_item
    config = Books::Authors::RankingConfiguration.default_primary
    return nil if config.nil?

    config.ranked_items.where.not(rank: nil).find_by(item: @author)
  end

  def ranked_books
    return Books::Book.none if @ranking_configuration.nil?

    @author.books
      .joins(
        "JOIN ranked_items ON ranked_items.item_id = books_books.id " \
        "AND ranked_items.item_type = 'Books::Book' " \
        "AND ranked_items.ranking_configuration_id = #{@ranking_configuration.id.to_i}"
      )
      .where.not(ranked_items: {rank: nil})
      .select("books_books.*, ranked_items.rank AS ranked_position")
      .preload(primary_image: {file_attachment: :blob})
      .order(Arel.sql("ranked_items.rank ASC"))
  end

  def all_books_relation
    @author.books
      .preload(primary_image: {file_attachment: :blob})
      .order(Arel.sql("books_books.first_published_year ASC NULLS LAST"), :title)
  end
end
```

`preload`, not `includes`: `includes` combined with a custom `select` and a manual join produces an eager-load join that discards the `ranked_position` alias.

- [ ] **Step 10: Write the legacy controller**

Create `app/controllers/books/legacy_authors_controller.rb`:

```ruby
class Books::LegacyAuthorsController < ApplicationController
  # find_by!(id:), never find: Books::Author uses friendly_id with :finders,
  # which resolves slugs before primary keys.
  def show
    author = Books::Author.find_by!(id: params[:id])

    redirect_to author_path(author.slug), status: :moved_permanently
  end
end
```

- [ ] **Step 11: Add the remaining routes**

In `config/routes.rb`, extend the scope block added in Task 5 Step 8 and add the legacy routes. The legacy routes must come **after** the `/authors` index routes from Task 5, and `authors/view/...` must precede `authors/:id`.

```ruby
scope "(/rc/:ranking_configuration_id)" do
  get "author/:slug", to: "books/authors#show", as: :author
  get "author/:slug/all-books", to: "books/authors#all_books", as: :author_all_books
  get "author/:slug/all-books/page/:page", to: "books/authors#all_books",
    as: :author_all_books_page, constraints: {page: /\d+/}
end

get "authors/view/:view(/page/:page)", to: redirect("/authors", status: 301)
get "authors/:id/all_books", to: "books/legacy_authors#show", constraints: {id: /\d+/}
get "authors/:id", to: "books/legacy_authors#show", constraints: {id: /\d+/}
```

- [ ] **Step 12: Write the show view**

Replace `app/views/books/authors/show.html.erb`:

```erb
<%
  content_for :page_title, "The Greatest Books by #{@author.name} | The Greatest Books"
  content_for :meta_description, "The greatest books written by #{@author.name}, ranked from hundreds of published best-books lists."
%>

<div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
  <div class="lg:col-span-1">
    <div class="card bg-base-100 shadow-xl sticky top-8">
      <figure class="p-4 lg:p-6">
        <%= render Books::AuthorAvatarComponent.new(author: @author, size_classes: "w-full max-w-[240px] mx-auto aspect-square") %>
      </figure>
      <div class="card-body pt-0 gap-2">
        <% if @ranked_item %>
          <div class="badge badge-primary">Ranked #<%= @ranked_item.rank %> of The Greatest Authors</div>
        <% end %>
        <% if @author.birth_year %>
          <div class="text-sm text-base-content/70">
            <%= @author.birth_year %><%= "–#{@author.death_year}" if @author.death_year %>
          </div>
        <% end %>
      </div>
    </div>
  </div>

  <div class="lg:col-span-2 space-y-6">
    <h1 class="text-3xl sm:text-4xl font-bold text-balance"><%= @author.name %></h1>

    <% if @description %>
      <p class="text-base-content/80 leading-relaxed"><%= @description.content %></p>
    <% end %>

    <div class="flex items-center justify-between gap-4 flex-wrap">
      <h2 class="text-2xl font-bold">Ranked books</h2>
      <%= link_to "All books", author_all_books_path(@author.slug), class: "btn btn-sm btn-outline" %>
    </div>

    <p class="text-sm text-base-content/70">
      These are only the books that appear on the lists aggregated by this site. It is not a
      complete bibliography.
    </p>

    <% if @ranked_books.any? %>
      <ol class="space-y-3">
        <% @ranked_books.each do |book| %>
          <li class="flex items-baseline gap-3">
            <span class="text-base-content/50 font-semibold tabular-nums"><%= book.ranked_position %></span>
            <%= link_to book.title, book_path(book.slug), class: "link link-hover" %>
            <% if book.first_published_year %>
              <span class="text-sm text-base-content/60"><%= book.first_published_year %></span>
            <% end %>
          </li>
        <% end %>
      </ol>
    <% else %>
      <p class="text-base-content/70">None of this author's books are ranked yet.</p>
    <% end %>
  </div>
</div>
```

- [ ] **Step 13: Write the all-books view**

Create `app/views/books/authors/all_books.html.erb`:

```erb
<%
  content_for :page_title, "All books by #{@author.name} | The Greatest Books"
%>

<div class="space-y-6">
  <div>
    <h1 class="text-3xl font-bold">All books by <%= @author.name %></h1>
    <%= link_to "Back to #{@author.name}", author_path(@author.slug), class: "link link-hover text-sm" %>
  </div>

  <% if @books.any? %>
    <ul class="space-y-3">
      <% @books.each do |book| %>
        <li class="flex items-baseline gap-3">
          <%= link_to book.title, book_path(book.slug), class: "link link-hover" %>
          <% if book.first_published_year %>
            <span class="text-sm text-base-content/60"><%= book.first_published_year %></span>
          <% end %>
        </li>
      <% end %>
    </ul>

    <div class="flex justify-center">
      <%== @pagy.series_nav(slots: 5) %>
    </div>
  <% else %>
    <p class="text-base-content/70">No books recorded for this author.</p>
  <% end %>
</div>
```

- [ ] **Step 14: Run the controller and component tests**

```bash
bin/rails test test/controllers/books/authors_controller_test.rb test/controllers/books/legacy_authors_controller_test.rb test/components/books/author_avatar_component_test.rb
```

Expected: PASS.

- [ ] **Step 15: Run the full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

- [ ] **Step 16: Commit**

```bash
git add -A
git commit -m "Add author show page, all-books page, and avatar component"
```

---

## Task 7: End-to-end tests

**Files:**
- Create: `web-app/e2e/tests/books/authors.spec.ts`

**Interfaces:**
- Consumes: all routes from Tasks 5 and 6.
- Produces: nothing.

- [ ] **Step 1: Confirm the dev server and author rankings exist**

E2E runs against a local dev server with real development data.

```bash
cd web-app
bin/rails runner 'puts RankedItem.where(ranking_configuration: Books::Authors::RankingConfiguration.default_primary).count'
```

Expected: roughly 14,900. If zero, run the Task 3 Step 13 command first.

Start the dev server in a second terminal with `bin/dev`.

- [ ] **Step 2: Write the E2E spec**

Create `web-app/e2e/tests/books/authors.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Greatest authors', () => {
  test('the index lists ranked authors', async ({ page }) => {
    await page.goto('/authors');

    await expect(page.getByRole('heading', { level: 1, name: /Greatest Authors/i })).toBeVisible();
    await expect(page.locator('ol > li').first()).toBeVisible();
  });

  test('an index row links through to the author page', async ({ page }) => {
    await page.goto('/authors');

    const firstAuthorLink = page.locator('ol > li h2 a').first();
    const name = (await firstAuthorLink.textContent())?.trim() ?? '';
    await firstAuthorLink.click();

    await expect(page).toHaveURL(/\/author\//);
    await expect(page.getByRole('heading', { level: 1, name })).toBeVisible();
  });

  test('the author page shows a rank badge and ranked books', async ({ page }) => {
    await page.goto('/authors');
    await page.locator('ol > li h2 a').first().click();

    await expect(page.locator('.badge', { hasText: 'Ranked #' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 2, name: 'Ranked books' })).toBeVisible();
  });

  test('the all books toggle navigates and back-links', async ({ page }) => {
    await page.goto('/authors');
    await page.locator('ol > li h2 a').first().click();

    await page.getByRole('link', { name: 'All books' }).click();
    await expect(page).toHaveURL(/\/author\/[^/]+\/all-books$/);
    await expect(page.getByRole('heading', { level: 1, name: /^All books by/ })).toBeVisible();

    await page.getByRole('link', { name: /^Back to / }).click();
    await expect(page).toHaveURL(/\/author\/[^/]+$/);
  });

  test('index pagination works', async ({ page }) => {
    await page.goto('/authors/page/2');

    await expect(page.getByRole('heading', { level: 1, name: /Greatest Authors/i })).toBeVisible();
    await expect(page.getByText(/Page 2 of/)).toBeVisible();
  });

  test('page one redirects to the canonical index', async ({ page }) => {
    await page.goto('/authors/page/1');

    await expect(page).toHaveURL(/\/authors$/);
  });

  test('legacy /authors/:id redirects to the slug url', async ({ page }) => {
    await page.goto('/authors/1');

    await expect(page).toHaveURL(/\/author\/[^/]+$/);
  });

  test('the Authors nav link reaches the index', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('navigation', { name: 'Main' })
      .getByRole('link', { name: 'Authors' }).first().click();

    await expect(page).toHaveURL(/\/authors$/);
  });
});
```

- [ ] **Step 3: Run the E2E suite**

```bash
cd web-app
yarn test:e2e
```

Expected: PASS. If every spec times out on the homepage, the e2e admin user lost its role in a dev-DB reseed — run `bin/rails e2e:admin`. That is unrelated to these specs but produces the same symptom.

- [ ] **Step 4: Run the full suite and lint one final time**

```bash
bin/rails test
bundle exec standardrb
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add end-to-end tests for the greatest authors pages"
```

---

## Verification Checklist

Before opening a pull request:

- [ ] `bin/rails test` passes with no failures or errors.
- [ ] `bundle exec standardrb` reports no offences.
- [ ] `yarn test:e2e` passes against a running dev server.
- [ ] `/authors` top ten is led by Dostoevsky, Dickens, and Faulkner — **not** by "Unknown".
- [ ] The author show page renders an initials monogram for an author with no image.
- [ ] `/authors/1` returns a 301 to `/author/<slug>`.
- [ ] `config/schedule.yml` parses and contains `books_author_rankings`.

CI runs `bin/rails test` and `standardrb` on every pull request and blocks the merge if either fails. CI eager-loads (`CI=true`) so it is stricter than a local run, and it has no `.env`.
