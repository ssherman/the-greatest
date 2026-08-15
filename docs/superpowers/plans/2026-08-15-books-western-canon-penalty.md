# Books Western-Canon Penalty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Penalise a books list in the weight calculation when at least 90% of its books come from Western countries, unless the list declares a location focus.

**Architecture:** `Books::List#percentage_western` computes the share of the list's books whose country of origin carries the `western` label, using two indexed count queries. `Rankings::WeightCalculatorV1` reads that value in a new private method and, when it is at or above 90.0, adds the value already configured on the existing `Books::Penalty` record. `::List#percentage_western` returns `nil` so non-books media skip the branch. No new tables, columns, migrations, jobs, or UI.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + fixtures + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-08-15-books-western-canon-penalty-design.md`

## Global Constraints

- Run every command from `web-app/`. Docs live in `docs/` at the **project root**, not `web-app/docs/`.
- Lint with `bundle exec standardrb`, **not** `bin/rubocop`.
- Namespace all books code under `Books::`; tests mirror the namespace (`module Books; class ListTest`).
- Skinny models: this is a read-only query method, which is allowed on the model. Do not add an `app/presenters` directory — there isn't one.
- Threshold value: **90.0**, as a frozen constant named `PERCENTAGE_WESTERN_THRESHOLD` on `Rankings::WeightCalculatorV1`. The comparison is **inclusive** — exactly 90.0 is penalised.
- The penalty amount is **never hardcoded**. It comes from `penalty_applications.value` via the existing `find_penalty_details_by_dynamic_type` helper.
- Do not create a `lists.percentage_western` column, a refresh job, or any migration.
- Do not run destructive database commands. The development database is not disposable; `bin/rails test` against `RAILS_ENV=test` is safe and is what these tasks use.

## Context an implementer needs before starting

The migration already created everything except the calculation. In development: `Books::Penalty` #23 (`dynamic_type: percentage_western`) exists and is applied to books ranking configurations 5, 7 and 8 with value 10; `Books::Country` has 253 rows, 24 carrying the `western` label; `books_book_countries` has 126,007 rows. **You are adding one model method, one base method, and one calculator branch. Nothing else.**

Two facts about the test fixtures that will otherwise confuse you:

1. `test/fixtures/penalty_applications.yml` already applies `books_penalty` (a `Books::Penalty` with `dynamic_type: 1`, i.e. `percentage_western`) to the `books_global` configuration with `value: 20`. So the moment Task 2 lands, the new branch starts evaluating for `ranked_lists(:books_ranked_list)`.
2. `list_items(:books_item)` points `listable` at `one (Books::Book)`, and **there is no `one` book fixture** — books are `war_and_peace`, `crime_and_punishment`, `combo_steinbeck`, `got`, `clash`, `of_mice_and_men`, `cannery_row`. Rails hashes the label into an id anyway, so the row loads with a dangling `listable_id`. That makes `lists(:books_list)` compute `0.0` (one item, zero western), which is below the threshold, so existing tests stay green. Do not "fix" that fixture.

The same file applies `movies_penalty` and `music_penalty` — also `dynamic_type: 1` — to `movies_global` and `music_albums_global`. This is why the `::List` base method in Task 1 is required rather than defensive: without it, Task 2 raises `NoMethodError` on a `Movies::List`.

**Deliberate deviation from the spec.** The spec's Testing section proposes adding list and list-item fixtures. This plan adds **no new fixtures**: Task 1 builds its list and items inline from the existing `books_books` and `books_countries` fixtures, and Task 2 builds its own ranking configuration, penalty and list. Same coverage, and it avoids two known traps — new shared fixtures perturbing the 6565-test baseline, and `ActiveRecord::FixtureSet.create_fixtures` truncating tables. Do not add fixtures for these tasks.

## File Structure

| File | Responsibility |
| --- | --- |
| `app/models/list.rb` (modify) | `percentage_western` returning `nil` — the contract for non-books media |
| `app/models/books/list.rb` (modify) | `percentage_western` computing the real value |
| `app/lib/rankings/weight_calculator_v1.rb` (modify) | threshold constant, the penalty branch, and its call site |
| `test/models/list_test.rb` (modify) | base method returns nil |
| `test/models/books/list_test.rb` (**create**) | the computation, including empty and unresolved-item cases |
| `test/lib/rankings/weight_calculator_v1_test.rb` (modify) | threshold, exemption, and not-configured behaviour |

---

### Task 1: The list reports its western percentage

**Files:**
- Modify: `app/models/list.rb` — add `percentage_western` near the other public instance methods
- Modify: `app/models/books/list.rb` — currently just `# Books-specific logic can be added here`
- Test: `test/models/books/list_test.rb` (create)
- Test: `test/models/list_test.rb` (modify)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `List#percentage_western → nil` and `Books::List#percentage_western → Float | nil`. The Float is `0.0`–`100.0` rounded to two decimal places; `nil` means the list has no resolved book items. Task 2 depends on both the name and the `nil` case.

- [ ] **Step 1: Write the failing tests for `Books::List#percentage_western`**

Create `test/models/books/list_test.rb`:

```ruby
require "test_helper"

module Books
  class ListTest < ActiveSupport::TestCase
    # books_countries(:french) carries labels: [western]
    # books_countries(:japanese) carries labels: [asian]
    # books_books(:crime_and_punishment) has no books_book_countries row at all
    def setup
      @list = Books::List.create!(name: "Western Percentage Test List", status: :approved)
    end

    def add_book(book, position)
      ListItem.create!(list: @list, listable: book, position: position)
    end

    test "returns 100.0 when every book is western" do
      add_book(books_books(:war_and_peace), 1)
      add_book(books_books(:got), 2)

      assert_in_delta 100.0, @list.percentage_western, 0.001
    end

    test "returns the western share rounded to two places" do
      add_book(books_books(:war_and_peace), 1)   # french -> western
      add_book(books_books(:got), 2)             # french -> western
      add_book(books_books(:of_mice_and_men), 3) # japanese -> not western

      # 2 of 3 = 66.666... -> 66.67
      assert_in_delta 66.67, @list.percentage_western, 0.001
    end

    test "counts a book with no country as not western" do
      add_book(books_books(:war_and_peace), 1)         # western
      add_book(books_books(:crime_and_punishment), 2)  # no country row

      assert_in_delta 50.0, @list.percentage_western, 0.001
    end

    test "returns 0.0 when no book is western" do
      add_book(books_books(:of_mice_and_men), 1)

      assert_in_delta 0.0, @list.percentage_western, 0.001
    end

    test "returns nil when the list has no items" do
      assert_nil @list.percentage_western
    end

    test "ignores items with no resolved book" do
      add_book(books_books(:war_and_peace), 1)
      ListItem.create!(list: @list, listable_type: "Books::Book", listable_id: nil, position: 2)

      # The unresolved item is excluded from both numerator and denominator.
      assert_in_delta 100.0, @list.percentage_western, 0.001
    end
  end
end
```

Add to `test/models/list_test.rb`, inside `class ListTest`:

```ruby
test "percentage_western is nil for media that carry no country data" do
  assert_nil lists(:movies_list).percentage_western
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/books/list_test.rb test/models/list_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'percentage_western'`.

- [ ] **Step 3: Add the base method**

In `app/models/list.rb`, add as a public instance method:

```ruby
# Only books carry country-of-origin data, so every other media type answers
# nil and the weight calculator skips the western-canon penalty.
def percentage_western
  nil
end
```

- [ ] **Step 4: Add the books implementation**

Replace the body of `app/models/books/list.rb`:

```ruby
module Books
  class List < ::List
    # Percentage of the list's books whose country of origin carries the
    # "western" label, 0.0-100.0, or nil when the list has no resolved book
    # items -- an empty list cannot be western-biased.
    #
    # The listable_type filter is redundant against ListItem's validation but
    # not against rows written by importers and migrations, and it lets the
    # query use index_list_items_on_listable.
    def percentage_western
      items = list_items.where(listable_type: "Books::Book").where.not(listable_id: nil)
      total = items.count
      return nil if total.zero?

      western_book_ids = Books::BookCountry
        .joins(:country)
        .merge(Books::Country.with_label("western"))
        .select(:book_id)

      ((items.where(listable_id: western_book_ids).count.to_f / total) * 100).round(2)
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/list_test.rb test/models/list_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 6: Prove the tests are not vacuous**

This codebase has twice shipped tests that passed against broken or deleted code. Confirm each guard actually bites, reverting after each check:

Temporarily change `.round(2)` to `.round(0)` in `Books::List#percentage_western`.
Run: `bin/rails test test/models/books/list_test.rb`
Expected: FAIL on "returns the western share rounded to two places" (67.0 vs 66.67). **Revert.**

Temporarily delete `.where.not(listable_id: nil)`.
Run: `bin/rails test test/models/books/list_test.rb`
Expected: FAIL on "ignores items with no resolved book" (50.0 vs 100.0). **Revert.**

Temporarily change `return nil if total.zero?` to `return 0.0 if total.zero?`.
Run: `bin/rails test test/models/books/list_test.rb`
Expected: FAIL on "returns nil when the list has no items". **Revert.**

- [ ] **Step 7: Run the full suite and the linter**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. Baseline for this branch is 6565 runs.

Run: `bundle exec standardrb`
Expected: no offenses. If it reports any, run `bundle exec standardrb --fix` and re-run the tests.

- [ ] **Step 8: Commit**

```bash
git add app/models/list.rb app/models/books/list.rb test/models/list_test.rb test/models/books/list_test.rb
git commit -m "Add Books::List#percentage_western"
```

---

### Task 2: The weight calculator applies the penalty

**Files:**
- Modify: `app/lib/rankings/weight_calculator_v1.rb` — add the constant near the top of the class, the private method next to `calculate_bias_penalties_with_details`, and the call site inside that method
- Test: `test/lib/rankings/weight_calculator_v1_test.rb`

**Interfaces:**
- Consumes: `List#percentage_western` and `Books::List#percentage_western` from Task 1.
- Produces: `Rankings::WeightCalculatorV1::PERCENTAGE_WESTERN_THRESHOLD = 90.0` and a private `calculate_percentage_western_penalty_with_details(details)` returning an Integer penalty contribution. Nothing later depends on these.

- [ ] **Step 1: Write the failing tests**

Add to `test/lib/rankings/weight_calculator_v1_test.rb`, inside `class WeightCalculatorV1Test`. Each test builds its own configuration and list so fixture penalties on `books_global` cannot skew the totals — the same approach the existing tests in this file already take.

```ruby
# --- western canon penalty -------------------------------------------------

# Builds a books configuration carrying only the western-canon penalty, so the
# calculated weight is 100 minus that penalty and nothing else.
def western_canon_setup(percentage_western:, location_specific: false, apply_penalty: true)
  config = Books::RankingConfiguration.create!(
    name: "Western Canon Config #{SecureRandom.hex(4)}",
    global: true,
    min_list_weight: 1
  )

  if apply_penalty
    penalty = Books::Penalty.create!(
      name: "Western Canon #{SecureRandom.hex(4)}",
      dynamic_type: :percentage_western
    )
    PenaltyApplication.create!(penalty: penalty, ranking_configuration: config, value: 10)
  end

  list = Books::List.create!(
    name: "Western Canon List #{SecureRandom.hex(4)}",
    status: :approved,
    location_specific: location_specific,
    high_quality_source: false
  )
  list.stubs(:percentage_western).returns(percentage_western)

  ranked_list = RankedList.create!(list: list, ranking_configuration: config)
  # The calculator memoises the list from the ranked_list, so hand it the
  # stubbed instance rather than letting it load a fresh one.
  ranked_list.stubs(:list).returns(list)

  WeightCalculatorV1.new(ranked_list)
end

test "penalises a list at or above the western canon threshold" do
  calculator = western_canon_setup(percentage_western: 94.68)

  assert_equal 90, calculator.call
end

test "records the actual percentage in the calculated weight details" do
  calculator = western_canon_setup(percentage_western: 94.68)
  calculator.call

  entry = calculator.ranked_list.calculated_weight_details["penalties"]
    .find { |p| p["dynamic_type"] == "percentage_western" }

  assert_not_nil entry, "expected a percentage_western penalty entry"
  assert_equal "dynamic_attribute", entry["source"]
  assert_in_delta 94.68, entry["attribute_value"], 0.001
  assert_equal 10, entry["value"]
end

test "penalises a list exactly at the western canon threshold" do
  calculator = western_canon_setup(percentage_western: 90.0)

  assert_equal 90, calculator.call
end

test "does not penalise a list below the western canon threshold" do
  calculator = western_canon_setup(percentage_western: 89.99)

  assert_equal 100, calculator.call
end

test "exempts a location specific list from the western canon penalty" do
  calculator = western_canon_setup(percentage_western: 100.0, location_specific: true)

  assert_equal 100, calculator.call
end

test "does not penalise when the configuration has no western canon penalty" do
  calculator = western_canon_setup(percentage_western: 100.0, apply_penalty: false)

  assert_equal 100, calculator.call
end

test "does not penalise a list with no items" do
  calculator = western_canon_setup(percentage_western: nil)

  assert_equal 100, calculator.call
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/rankings/weight_calculator_v1_test.rb`
Expected: FAIL — the threshold, boundary and details tests each expect `90` (or a details entry) but get `100` (or `nil`), because no branch exists yet. The exemption, not-configured and no-items tests may already pass; they are regression guards and must stay green.

- [ ] **Step 3: Add the threshold constant**

In `app/lib/rankings/weight_calculator_v1.rb`, immediately after `class WeightCalculatorV1 < WeightCalculator` and **before** the existing `private`:

```ruby
PERCENTAGE_WESTERN_THRESHOLD = 90.0
```

- [ ] **Step 4: Add the branch and its call site**

Still in `app/lib/rankings/weight_calculator_v1.rb`, add this private method directly after `calculate_bias_penalties_with_details`:

```ruby
# Lists that declare a location focus up front ("30 Best Australian Books")
# are exempt: their western tilt is the stated premise, not unexamined bias.
#
# Checks run cheapest-first. find_penalty_details_by_dynamic_type returns 0
# when the configuration carries no such penalty, so percentage_western --
# the only query-backed step -- never runs for music, games or movies.
def calculate_percentage_western_penalty_with_details(details)
  return 0 if list.location_specific?

  penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:percentage_western)
  return 0 unless penalty_value > 0

  percentage = list.percentage_western
  return 0 if percentage.nil? || percentage < PERCENTAGE_WESTERN_THRESHOLD

  details["penalties"] << penalty_info.merge(
    "source" => "dynamic_attribute",
    "dynamic_type" => "percentage_western",
    "attribute_value" => percentage,
    "value" => penalty_value
  )
  penalty_value
end
```

Then wire it into `calculate_bias_penalties_with_details`. That method currently ends:

```ruby
      end

      penalty
    end
```

Change the ending to:

```ruby
      end

      penalty += calculate_percentage_western_penalty_with_details(details)

      penalty
    end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/rankings/weight_calculator_v1_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 6: Prove the tests are not vacuous**

Revert after each check:

Temporarily delete the `return 0 if list.location_specific?` line.
Run: `bin/rails test test/lib/rankings/weight_calculator_v1_test.rb`
Expected: FAIL on "exempts a location specific list" (90 vs 100). **Revert.**

Temporarily change `percentage < PERCENTAGE_WESTERN_THRESHOLD` to `percentage <= PERCENTAGE_WESTERN_THRESHOLD`.
Run: `bin/rails test test/lib/rankings/weight_calculator_v1_test.rb`
Expected: FAIL on "penalises a list exactly at the western canon threshold" (100 vs 90). **Revert.**

Temporarily change `return 0 if percentage.nil? || ...` to drop the `percentage.nil?` clause.
Run: `bin/rails test test/lib/rankings/weight_calculator_v1_test.rb`
Expected: FAIL on "does not penalise a list with no items" — a `NoMethodError` comparing `nil` with `<` is an acceptable failure here. **Revert.**

- [ ] **Step 7: Run the full suite and the linter**

Run: `bin/rails test`
Expected: 0 failures, 0 errors.

If anything outside this file fails, the likely cause is the fixture situation described in the Context section — `books_penalty` is applied to `books_global` at value 20, and `movies_penalty` / `music_penalty` to their configurations. Check that `List#percentage_western` from Task 1 is present before assuming the branch is wrong.

Run: `bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 8: Verify against real data**

The unit tests stub the percentage. Confirm the real query agrees with the measurements in the spec, using the development database read-only:

```bash
bin/rails runner 'rc = Books::RankingConfiguration.find_by(primary: true); \
  lists = Books::List.where(status: :active); \
  vals = lists.map { |l| [l, l.percentage_western] }.reject { |_, p| p.nil? }; \
  over = vals.select { |_, p| p >= 90.0 }; \
  puts "active with items: #{vals.size}"; \
  puts ">= 90%: #{over.size}"; \
  puts "exempt: #{over.count { |l, _| l.location_specific? }}"; \
  puts "penalised: #{over.count { |l, _| !l.location_specific? }}"'
```

Expected, matching the spec's Rollout table: 759 active lists with items, 373 at or above 90%, 65 exempt, **308 penalised**. Small drift is fine if the development data has changed; an order-of-magnitude difference means the query is wrong.

- [ ] **Step 9: Commit**

```bash
git add app/lib/rankings/weight_calculator_v1.rb test/lib/rankings/weight_calculator_v1_test.rb
git commit -m "Apply the western canon penalty in WeightCalculatorV1"
```

---

## Done criteria

- `bin/rails test` green (baseline 6565 runs, plus the new tests).
- `bundle exec standardrb` clean.
- No migration, no new column, no new job, no view changes in the diff.
- Step 8 of Task 2 reports roughly 308 penalised lists.

No Playwright test and no system test: this adds no user-facing page or flow.

## Not part of this plan

Recorded in the spec's Rollout section, to be done by the owner after merge:

1. Confirm in **production** that the `Books::Penalty` with `dynamic_type: percentage_western` has a `penalty_application` on the primary books ranking configuration. Without it the branch is a silent no-op.
2. Run `BulkCalculateWeightsJob` for the books ranking configurations, then `CalculateRankingsJob`. Nothing recalculates on merge, and 308 lists losing 10 points of weight will visibly reorder the public books rankings.
