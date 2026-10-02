# Books Penalty Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the books penalty migration reuse the two globals it duplicated, move books from seven static year-span penalties to the `num_years_covered` dynamic global (with a reviewed per-list value and a books curve that actually discriminates), and let already-migrated databases self-heal through an idempotent reconcile step.

**Architecture:** `PenaltyResolver` is the single place legacy names become new penalties; two aliases and a year-span map there make the existing migrators do the right thing on a fresh run. One new migrator writes `Books::List#num_years_covered` from legacy join rows plus a checked-in YAML of reviewed values. `Rankings::WeightCalculatorV1` gains one extracted temporal method with a books-only log branch. `PenaltyReconciler` repairs a database migrated before those changes, by name, idempotently.

**Tech Stack:** Rails 8.1, Minitest 6 + Mocha + fixtures, Rake, PostgreSQL (dev has a second `legacy_books` connection; tests stub every legacy read).

**Spec:** `docs/superpowers/specs/2026-09-15-books-penalty-reconciliation-design.md`

## Global Constraints

- Run every command from `web-app/` inside this worktree: `/home/shane/dev/the-greatest/.claude/worktrees/books-penalty-reconciliation/web-app`. Never `cd` to the main checkout.
- Lint is `bundle exec standardrb` (never `bin/rubocop`). Each task ends green on its own test files and on standardrb for the files it touched.
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`. Never test private methods — the calculator is exercised through `call` and the persisted `calculated_weight_details`.
- Tests never open the legacy connection: migrators stub `legacy_each`, the deriver is pure, the rake tests stub the service classes.
- Music/games/authors behaviour is unchanged. Any test that pins the quadratic must keep passing with the same numbers.
- Never mention or plan for movies.
- Books curve: `BOOKS_FULL_COVERAGE_YEARS = 200`; `max × (1 − ln(years)/ln(200))`, clamped to `0..max`, 0 at ≥ 200 years.
- The reconcile step locates penalties by **name** (`user_id: nil`), never by id.
- Commit after each task on the current branch (`worktree-books-penalty-reconciliation`). Do not push and do not open a PR without asking Shane. Commit messages end with the attribution trailer given in the session.
- Development database: never run a destructive command; Task 9 snapshots first. `RAILS_ENV=test` only for tests.

---

### Task 1: Books log curve in `WeightCalculatorV1`

**Files:**
- Modify: `app/lib/rankings/weight_calculator_v1.rb` (constant at line 5; methods at lines 283–348 and 539–579)
- Test: `test/lib/rankings/weight_calculator_v1_test.rb`

**Interfaces:**
- Consumes: `List#num_years_covered` (integer ≥ 1 or nil), `PenaltyApplication#value`, `Penalty.by_dynamic_type(:num_years_covered)`.
- Produces: `Rankings::WeightCalculatorV1::BOOKS_FULL_COVERAGE_YEARS` (= 200); `calculated_weight_details["penalties"]` entries with `"source" => "dynamic_temporal"` whose `"calculation"` hash carries `"full_coverage_years"` (books) or `"max_year_range"`/`"ratio"`/`"exponent"` (other domains).

- [ ] **Step 1: Write the failing tests**

Append inside the class in `test/lib/rankings/weight_calculator_v1_test.rb`, before the final `end`s:

```ruby
    # --- Books temporal coverage: log curve ---------------------------------

    def books_temporal_config(max_value)
      config = Books::RankingConfiguration.create!(
        name: "Books Temporal #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )
      penalty = Global::Penalty.create!(
        name: "Years covered #{SecureRandom.hex(4)}",
        dynamic_type: :num_years_covered
      )
      PenaltyApplication.create!(penalty: penalty, ranking_configuration: config, value: max_value)
      config
    end

    def temporal_entry(ranked_list)
      ranked_list.reload.calculated_weight_details["penalties"].find { |p| p["source"] == "dynamic_temporal" }
    end

    test "books temporal penalty follows the log curve at the legacy bucket points" do
      config = books_temporal_config(50)
      one_decimal = {1 => 50.0, 5 => 34.8, 10 => 28.3, 25 => 19.6, 50 => 13.1, 75 => 9.3, 100 => 6.5}

      one_decimal.each do |years, expected|
        list = Books::List.create!(name: "Covers #{years} years", status: :approved, num_years_covered: years)
        ranked = RankedList.create!(list: list, ranking_configuration: config)
        WeightCalculatorV1.new(ranked).call

        entry = temporal_entry(ranked)
        exact = 50 * (1.0 - Math.log(years) / Math.log(WeightCalculatorV1::BOOKS_FULL_COVERAGE_YEARS))
        assert_in_delta expected, entry["value"], 0.05, "#{years} years (one decimal)"
        assert_in_delta exact, entry["value"], 1e-9, "#{years} years (exact)"
        assert_equal 200, entry["calculation"]["full_coverage_years"]
        assert_equal "Books::List", entry["calculation"]["media_type"]
        assert_equal (100 - exact).round, ranked.reload.weight, "#{years} years weight"
      end
    end

    test "books temporal penalty is zero at and beyond full coverage" do
      config = books_temporal_config(50)

      [200, 500].each do |years|
        list = Books::List.create!(name: "Covers #{years} years", status: :approved, num_years_covered: years)
        ranked = RankedList.create!(list: list, ranking_configuration: config)
        weight = WeightCalculatorV1.new(ranked).call

        assert_equal 100, weight, "#{years} years should carry no temporal penalty"
        assert_nil temporal_entry(ranked), "#{years} years should record no dynamic_temporal entry"
      end
    end

    test "books temporal penalty never exceeds the application value" do
      config = books_temporal_config(30)
      list = Books::List.create!(name: "Covers 1 year", status: :approved, num_years_covered: 1)
      ranked = RankedList.create!(list: list, ranking_configuration: config)
      WeightCalculatorV1.new(ranked).call

      assert_in_delta 30.0, temporal_entry(ranked)["value"], 1e-9
      assert_equal 70, ranked.reload.weight
    end

    # The extraction must be behaviour-preserving for every other domain: the
    # quadratic, its exponent and its details keys are exactly what they were.
    test "music temporal penalty keeps the quadratic curve and its details" do
      config = Music::Albums::RankingConfiguration.create!(
        name: "Music Temporal #{SecureRandom.hex(4)}",
        global: true,
        min_list_weight: 1
      )
      penalty = Global::Penalty.create!(name: "Years covered #{SecureRandom.hex(4)}", dynamic_type: :num_years_covered)
      PenaltyApplication.create!(penalty: penalty, ranking_configuration: config, value: 40)
      list = Music::Albums::List.create!(name: "Best of the 1990s", status: :approved, num_years_covered: 10)
      ranked = RankedList.create!(list: list, ranking_configuration: config)
      WeightCalculatorV1.new(ranked).call

      entry = temporal_entry(ranked)
      calc = entry["calculation"]
      assert_equal "max_value * ((1.0 - ratio) ** exponent)", calc["formula"]
      assert_equal 2.0, calc["exponent"]
      assert_equal "Music::Albums::List", calc["media_type"]
      assert_nil calc["full_coverage_years"]
      assert_in_delta 40 * ((1.0 - 10.0 / calc["max_year_range"])**2), entry["value"], 1e-9
      assert_equal (100 - entry["value"]).round, ranked.reload.weight
    end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bin/rails test test/lib/rankings/weight_calculator_v1_test.rb -n "/temporal/"`
Expected: the three books tests FAIL (the books value comes out ≈ 48–50 for every bucket because the quadratic is flat over 5027 years; `full_coverage_years` is nil). The music test PASSES already — that is the point: it pins current behaviour.

- [ ] **Step 3: Implement the extraction and the books branch**

In `app/lib/rankings/weight_calculator_v1.rb`:

1. Add the constant under `PERCENTAGE_WESTERN_THRESHOLD` (line 5):

```ruby
    PERCENTAGE_WESTERN_THRESHOLD = 90.0
    # Books lists reach "no temporal penalty" at this many years covered. Chosen so
    # the log curve below lands within a few points of the legacy static ladder
    # (50/40/30/20/10/7/5 at 1/5/10/25/50/75/100 years) when the application is 50.
    BOOKS_FULL_COVERAGE_YEARS = 200
```

2. Replace the body of `calculate_temporal_coverage_penalty_with_details` line 298 so it calls the shared method:

```ruby
        penalty_value, calculation_details = temporal_coverage_penalty(list.num_years_covered, penalty_application.value)
```

3. Replace the whole of `calculate_temporal_coverage_penalty_with_calculation_details` (lines 318–348) with:

```ruby
    # One curve per media type, shared by the details and non-details paths.
    # Books get a log curve: the quadratic is flat for them (calculate_books_year_range
    # is ~5000 years, so a 100-year list would keep 96% of the max), while ln-scaling
    # reproduces the legacy static ladder within a few points. Every other domain keeps
    # the quadratic exactly as it was.
    # => [penalty_value, calculation_details]
    def temporal_coverage_penalty(years_covered, max_penalty, exponent: 2.0)
      return books_temporal_coverage_penalty(years_covered, max_penalty) if list.class.name.start_with?("Books::")

      max_year_range = calculate_media_year_range

      if years_covered >= max_year_range
        return [0, {
          "years_covered" => years_covered,
          "max_year_range" => max_year_range,
          "media_type" => list.class.name,
          "formula" => "0 (full coverage)"
        }]
      end

      ratio = years_covered.to_f / max_year_range.to_f
      penalty_value = max_penalty * ((1.0 - ratio)**exponent)
      penalty_value = penalty_value.clamp(0, max_penalty)

      calculation_details = {
        "years_covered" => years_covered,
        "max_year_range" => max_year_range,
        "media_type" => list.class.name,
        "ratio" => ratio,
        "exponent" => exponent,
        "formula" => "max_value * ((1.0 - ratio) ** exponent)"
      }

      [penalty_value, calculation_details]
    end

    def books_temporal_coverage_penalty(years_covered, max_penalty)
      if years_covered >= BOOKS_FULL_COVERAGE_YEARS
        return [0, {
          "years_covered" => years_covered,
          "full_coverage_years" => BOOKS_FULL_COVERAGE_YEARS,
          "media_type" => list.class.name,
          "formula" => "0 (full coverage)"
        }]
      end

      log_ratio = Math.log(years_covered) / Math.log(BOOKS_FULL_COVERAGE_YEARS)
      penalty_value = (max_penalty * (1.0 - log_ratio)).clamp(0, max_penalty)

      [penalty_value, {
        "years_covered" => years_covered,
        "full_coverage_years" => BOOKS_FULL_COVERAGE_YEARS,
        "media_type" => list.class.name,
        "log_ratio" => log_ratio,
        "formula" => "max_value * (1.0 - ln(years_covered) / ln(full_coverage_years))"
      }]
    end
```

4. Replace `calculate_temporal_coverage_penalty_for_penalty` (lines 559–579) with:

```ruby
    def calculate_temporal_coverage_penalty_for_penalty(penalty)
      years_covered = list.num_years_covered
      return 0 unless years_covered.present?

      penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
      return 0 unless penalty_application

      temporal_coverage_penalty(years_covered, penalty_application.value).first
    end
```

Leave `calculate_media_year_range` and `calculate_books_year_range` in place; nothing else changes.

- [ ] **Step 4: Run the calculator tests and lint**

Run: `bin/rails test test/lib/rankings/ && bundle exec standardrb app/lib/rankings/weight_calculator_v1.rb test/lib/rankings/weight_calculator_v1_test.rb`
Expected: all pass, no offenses. The pre-existing temporal tests (music relative ordering, nil skip, combined penalties) still pass.

- [ ] **Step 5: Commit**

```bash
git add app/lib/rankings/weight_calculator_v1.rb test/lib/rankings/weight_calculator_v1_test.rb
git commit -m "Give books lists a log temporal-coverage curve

The shared quadratic is flat for books (the books year range is ~5000
years, so a 100-year list kept 96% of the max). Extract one temporal
method for both calculator paths and branch books onto
max * (1 - ln(years)/ln(200)), which lands within a few points of the
legacy static ladder. Music and games keep the quadratic byte-for-byte."
```

---

### Task 2: Resolver aliases and the year-span map

**Files:**
- Modify: `app/lib/services/books_migration/penalty_resolver.rb`
- Test: `test/lib/services/books_migration/penalty_resolver_test.rb`

**Interfaces:**
- Produces: `Services::BooksMigration::PenaltyResolver::YEAR_SPAN_BUCKETS` — frozen `Hash{String => Integer}` of the seven legacy year-span names → bucket years. Tasks 5, 7 and 8 read it.
- `call(attrs)` now returns `[:reuse, <num_years_covered global>]` for those seven names and `[:reuse, <global>]` for the two new aliases.

- [ ] **Step 1: Write the failing tests**

In `test/lib/services/books_migration/penalty_resolver_test.rb`:

1. Add a `num_years_covered` global to `globals`:

```ruby
      Global::Penalty.new(name: "List: number of years covered", dynamic_type: :num_years_covered),
      Global::Penalty.new(name: "List: is a follow up/honorable mention to a different list", dynamic_type: nil),
      Global::Penalty.new(name: "List: only covers items with a weird criteria", dynamic_type: nil),
```

2. Change the example in `"unmatched static creates a Books penalty with nil dynamic_type"` from `"List: only covers 75 years"` to `"List: Podcast/Etc that covers 1 book a week/month"` (both occurrences in that test) — 75 years is about to become a global.

3. Add:

```ruby
  test "honorable mention alias reuses the follow-up global" do
    strategy, penalty = resolver.call(lc("name" => "List: honorable mention"))
    assert_equal :reuse, strategy
    assert_equal "List: is a follow up/honorable mention to a different list", penalty.name
  end

  test "weird criteria alias (books, with the parenthetical) reuses the items global" do
    legacy = "List: only covers books with a weird criteria(books to help you survive the digital age, etc)"
    strategy, penalty = resolver.call(lc("name" => legacy))
    assert_equal :reuse, strategy
    assert_equal "List: only covers items with a weird criteria", penalty.name
  end

  test "every year-span static reuses the num_years_covered global" do
    assert_equal 7, R::YEAR_SPAN_BUCKETS.size
    R::YEAR_SPAN_BUCKETS.each do |legacy_name, bucket|
      strategy, penalty = resolver.call(lc("name" => legacy_name))
      assert_equal :reuse, strategy, legacy_name
      assert_equal "num_years_covered", penalty.dynamic_type, legacy_name
      assert_kind_of Integer, bucket
      assert_operator bucket, :>, 0
    end
  end

  test "year-span buckets carry the legacy years" do
    assert_equal 1, R::YEAR_SPAN_BUCKETS["List: only covers 1 year (yearly book awards, best of the year, etc)"]
    assert_equal 5, R::YEAR_SPAN_BUCKETS["List: only covers 5 years"]
    assert_equal 10, R::YEAR_SPAN_BUCKETS["List: only covers 10 years"]
    assert_equal 25, R::YEAR_SPAN_BUCKETS["List: only covers 25 years"]
    assert_equal 50, R::YEAR_SPAN_BUCKETS["List: only covers 50 years"]
    assert_equal 75, R::YEAR_SPAN_BUCKETS["List: only covers 75 years"]
    assert_equal 100, R::YEAR_SPAN_BUCKETS["List: only covers 100 years"]
  end

  test "raises when a year-span static has no num_years_covered global to reuse" do
    bare = R.new(globals_by_name: {}, globals_by_dynamic_type: {})
    assert_raises(KeyError) { bare.call(lc("name" => "List: only covers 10 years")) }
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/penalty_resolver_test.rb`
Expected: the new tests FAIL (`NameError: uninitialized constant ... YEAR_SPAN_BUCKETS`, and the aliases return `:create_books`).

- [ ] **Step 3: Implement**

In `app/lib/services/books_migration/penalty_resolver.rb`, extend the header comment and the constants, then the static branch of `call`:

```ruby
    # Pure decision: legacy list_con attrs -> reuse an existing Global::Penalty or
    # create a Books::Penalty. Dynamic list_cons resolve by dynamic_type (the legacy
    # name is ignored — it can be mistyped); percentage_western has no seeded global
    # (owner: book-specific) so it always creates. Static list_cons reuse a Global by
    # exact name or via GLOBAL_ALIASES (books->items / quote-only rewrites), else create.
    # The seven legacy year-span statics ("only covers N years") reuse the
    # num_years_covered dynamic global instead: the per-list fact they carried lands on
    # Books::List#num_years_covered (NumYearsCoveredMigrator), keyed by YEAR_SPAN_BUCKETS.
    class PenaltyResolver
      LEGACY_DYNAMIC_TYPE = {
        0 => "number_of_voters",
        1 => "percentage_western",
        2 => "voter_names_unknown",
        3 => "voter_count_unknown",
        4 => "category_specific"
      }.freeze

      GLOBAL_ALIASES = {
        "List: contains over 500 books(Quantity over Quality)" => "List: contains over 500 items(Quantity over Quality)",
        "List: Creator of the list, sells the books on the list" => "List: Creator of the list, sells the items on the list",
        'List: criteria is not just "best/favorite"' => "List: criteria is not just best/favorite",
        "List: only covers books with a weird criteria(books to help you survive the digital age, etc)" => "List: only covers items with a weird criteria",
        "List: honorable mention" => "List: is a follow up/honorable mention to a different list"
      }.freeze

      # Legacy static name -> the number of years that static stood for.
      YEAR_SPAN_BUCKETS = {
        "List: only covers 1 year (yearly book awards, best of the year, etc)" => 1,
        "List: only covers 5 years" => 5,
        "List: only covers 10 years" => 10,
        "List: only covers 25 years" => 25,
        "List: only covers 50 years" => 50,
        "List: only covers 75 years" => 75,
        "List: only covers 100 years" => 100
      }.freeze
```

and in `call`, replace the `else` branch:

```ruby
        else
          return [:reuse, @globals_by_dynamic_type.fetch("num_years_covered")] if YEAR_SPAN_BUCKETS.key?(name)

          global = @globals_by_name[GLOBAL_ALIASES.fetch(name, name)]
          global ? [:reuse, global] : [:create_books, {name: name, dynamic_type: nil}]
        end
```

- [ ] **Step 4: Run resolver + penalty migrator tests and lint**

Run: `bin/rails test test/lib/services/books_migration/penalty_resolver_test.rb test/lib/services/books_migration/penalty_migrator_test.rb test/lib/services/books_migration/penalty_application_migrator_test.rb && bundle exec standardrb app/lib/services/books_migration/penalty_resolver.rb test/lib/services/books_migration/penalty_resolver_test.rb`
Expected: all pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/penalty_resolver.rb test/lib/services/books_migration/penalty_resolver_test.rb
git commit -m "Resolve honorable-mention, weird-criteria and year-span statics to globals

Two more GLOBAL_ALIASES so RC 63's 'List: honorable mention' and the
parenthetical books 'weird criteria' name reuse Global::Penalty rows
instead of minting Books duplicates. The seven 'only covers N years'
statics now resolve to the num_years_covered dynamic global; their
bucket years live in YEAR_SPAN_BUCKETS for the list-side migrator."
```

---

### Task 3: Remove the static one-year tag from dynamic year lists

**Files:**
- Modify: `app/models/ranking_configuration.rb:155-163` (remove `one_year_penalty_name` and its comment)
- Modify: `app/models/books/ranking_configuration.rb:63` (remove the override)
- Modify: `app/lib/services/lists/generate_dynamic_lists.rb:253-262, 276-289`
- Test: `test/models/ranking_configuration_test.rb:502-507`, `test/lib/services/lists/generate_dynamic_lists_test.rb:379-386, 408-416`

**Interfaces:**
- Consumes: nothing new. `GenerateDynamicLists#assert_fields` already sets `num_years_covered: 1` on both rollups (line 237), which is what the dynamic global reads.
- Produces: `RankingConfiguration#one_year_penalty_name` no longer exists.

- [ ] **Step 1: Write the failing test and delete the ones that pin the tag**

In `test/lib/services/lists/generate_dynamic_lists_test.rb`:

1. Delete the test `"tags both lists with the domain's one-year penalty"` (lines 379–386) and the test `"warns and continues when the domain's one-year penalty is missing"` (lines 408–416).
2. Add in their place:

```ruby
      # Time scope is the dynamic num_years_covered global's job in every domain now;
      # the books static that used to be tagged here is gone. assert_fields already
      # sets num_years_covered: 1, which is all the dynamic penalty reads.
      test "does not tag the rollups with a static time-scope penalty" do
        rank(@books)

        result = generate

        [result.data[:top_list], result.data[:overflow_list]].each do |list|
          assert_empty list.penalties.static.where(category: :list_time_scope),
            "#{list.name} carries a static time-scope tag"
          assert_equal 1, list.num_years_covered
        end
      end
```

In `test/models/ranking_configuration_test.rb`, delete the test `"only books names a static one-year penalty"` (lines 502–507) and add:

```ruby
  test "no configuration names a static one-year penalty" do
    refute_respond_to ranking_configurations(:books_global), :one_year_penalty_name
  end
```

- [ ] **Step 2: Run to verify the new test fails**

Run: `bin/rails test test/lib/services/lists/generate_dynamic_lists_test.rb -n "/static time-scope/" test/models/ranking_configuration_test.rb -n "/one-year/"`
Expected: FAIL — the books rollups still carry the `books_one_year_penalty` fixture tag, and `one_year_penalty_name` still responds.

- [ ] **Step 3: Remove the hook and the tagging branch**

`app/models/ranking_configuration.rb`: delete lines 155–163 (the comment block and `def one_year_penalty_name; nil; end`).

`app/models/books/ranking_configuration.rb`: delete line 63 (`def one_year_penalty_name = ...`).

`app/lib/services/lists/generate_dynamic_lists.rb`: replace `assert_penalties` and delete `one_year_penalty`:

```ruby
      # Attaches tags only. The value of a tag is a per-configuration editorial
      # judgement, so this never creates a PenaltyApplication -- the same division
      # of labour GenerateUserFavorites settled on. Time scope needs no tag in any
      # domain: the dynamic Global::Penalty "List: number of years covered" reads
      # the num_years_covered value assert_fields sets.
      def assert_penalties(top_list, overflow_list)
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
```

(Keep the existing `honorable_mention` block verbatim; only the `one_year = one_year_penalty` block at the top and the `one_year_penalty` method at lines 276–289 go.)

- [ ] **Step 4: Run the affected suites and lint**

Run: `bin/rails test test/lib/services/lists/ test/models/ranking_configuration_test.rb test/lib/actions/admin/create_next_year_configuration_test.rb && grep -rn "one_year_penalty" app lib test; bundle exec standardrb app/models/ranking_configuration.rb app/models/books/ranking_configuration.rb app/lib/services/lists/generate_dynamic_lists.rb test/lib/services/lists/generate_dynamic_lists_test.rb test/models/ranking_configuration_test.rb`
Expected: tests pass; the grep prints nothing; no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/models/ranking_configuration.rb app/models/books/ranking_configuration.rb app/lib/services/lists/generate_dynamic_lists.rb test/lib/services/lists/generate_dynamic_lists_test.rb test/models/ranking_configuration_test.rb
git commit -m "Drop the static one-year tag from dynamic year lists

Books was the only domain naming a static one-year penalty, and that
static is being replaced by the num_years_covered dynamic global. The
rollups already carry num_years_covered: 1, which is all the dynamic
penalty reads, so the hook, the books override and the tagging branch
are removed rather than left returning nil for nobody."
```

---

### Task 4: `NumYearsCoveredDeriver` (pure first-pass parser)

**Files:**
- Create: `app/lib/services/books_migration/num_years_covered_deriver.rb`
- Test: `test/lib/services/books_migration/num_years_covered_deriver_test.rb`

**Interfaces:**
- Consumes: rows `{id: Integer, name: String, description: String|nil, year_published: Integer|nil, bucket: Integer, buckets: [Integer]}`.
- Produces: `Services::BooksMigration::NumYearsCoveredDeriver.call(rows, current_year: Date.current.year)` → `Array<Entry>`; `Entry` responds to `id`, `years`, `name`, `bucket`, `reason`, `flags`, `to_line`. Task 5 writes `to_line` output to the file.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/books_migration/num_years_covered_deriver_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::NumYearsCoveredDeriverTest < ActiveSupport::TestCase
  D = Services::BooksMigration::NumYearsCoveredDeriver

  def row(overrides = {})
    {id: 1, name: "x", description: nil, year_published: 2020, bucket: 25, buckets: [25]}.merge(overrides)
  end

  def derive(overrides = {})
    D.call([row(overrides)], current_year: 2026).first
  end

  test "one-year bucket is never parsed, whatever the name says" do
    e = derive(name: "Pulitzer Prize for Fiction 1918-2026", bucket: 1, buckets: [1])
    assert_equal 1, e.years
    assert_match(/never parsed/, e.reason)
  end

  test "explicit range is end minus start plus one" do
    assert_equal 101, derive(name: "The 100 Greatest American Novels, 1893 – 1993").years
    assert_equal 21, derive(name: "Top 20 South African Books, 1994-2014").years
    assert_equal 26, derive(name: "Top 10 Novels from 1980 to 2005").years
  end

  test "range beats past-N-years when both appear" do
    e = derive(name: "The 101 GREATEST PLAYS of the Past 100 Years (1920-2020)")
    assert_equal 101, e.years
    assert_match(/range 1920-2020/, e.reason)
  end

  test "past, last and previous N years" do
    assert_equal 30, derive(name: "The 30 best fiction books of the last 30 years").years
    assert_equal 20, derive(name: "Most Influential Book of the Past 20 Years").years
    assert_equal 90, derive(name: "Works of the previous 90 years").years
  end

  test "half and quarter century" do
    assert_equal 50, derive(name: "Best of the last half-century").years
    assert_equal 25, derive(name: "100 Best Books of the Quarter Century").years
  end

  test "since a year counts up to the publication year" do
    e = derive(name: "The Two Hundred Best Novels in English Since 1950", year_published: 2011)
    assert_equal 62, e.years
    assert_match(/since 1950/, e.reason)
    assert_empty e.flags
  end

  test "since a year with no publication year uses the current year and flags it" do
    e = derive(name: "The Best Since 1945", year_published: nil)
    assert_equal 82, e.years
    assert_includes e.flags, "NO year_published (used 2026)"
  end

  test "since a year later than publication falls through" do
    e = derive(name: "Since 2025", year_published: 2020, bucket: 10, buckets: [10])
    assert_equal 10, e.years
    assert_equal "unparsed", e.reason
  end

  test "decade patterns yield ten" do
    assert_equal 10, derive(name: "The Best Of The 1980s").years
    assert_equal 10, derive(name: "PEOPLE Picks the Best Books From the 80s").years
    assert_equal 10, derive(name: "The 24 Best Books of the Decade").years
  end

  test "21st century is publication year minus 2000" do
    assert_equal 24, derive(name: "100 Best Books of the 21st Century", year_published: 2024).years
    assert_equal 15, derive(name: "The 21st Century's 12 Greatest Novels", year_published: 2015).years
    assert_equal 19, derive(name: "21 books for the XXI century", year_published: 2019).years
  end

  test "21st century with no publication year uses the current year and flags it" do
    e = derive(name: "Best of the 21st century", year_published: nil)
    assert_equal 26, e.years
    assert_includes e.flags, "NO year_published (used 2026)"
  end

  test "20th century and century yield one hundred" do
    assert_equal 100, derive(name: "100 Best 20th-Century American Books").years
    assert_equal 100, derive(name: "Waterstone's Books of the Century").years
    assert_equal 100, derive(name: "Kanon na koniec wieku").years
  end

  test "millennium yields no value and is left to the reviewer" do
    e = derive(name: "The Best Fiction of the Millennium", bucket: 10, buckets: [10])
    assert_equal 10, e.years
    assert_match(/millennium/, e.reason)
  end

  test "name beats description" do
    e = derive(name: "Africa's 100 Best Books of the 20th Century",
      description: "Compiled early in the 21st century.", year_published: 2002, bucket: 100, buckets: [100])
    assert_equal 100, e.years
    assert_empty e.flags
  end

  test "description is used only when the name yields nothing, and is flagged" do
    e = derive(name: "The New Vanguard", description: "Novels of the 21st century.", year_published: 2018)
    assert_equal 18, e.years
    assert_includes e.flags, "FROM DESCRIPTION"
  end

  test "unparsed keeps the bucket" do
    e = derive(name: "50 Books That Defined Their Era", bucket: 100, buckets: [100])
    assert_equal 100, e.years
    assert_equal "unparsed", e.reason
  end

  test "conflicting legacy buckets are flagged" do
    e = derive(name: "The 10 Best Books Through Time", bucket: 25, buckets: [1, 25])
    assert_includes e.flags, "CONFLICT 1/25, highest RC wins"
  end

  test "to_line is a YAML entry with the reviewer's context in a comment" do
    e = derive(name: "100 Best Books of the 21st Century", year_published: 2024)
    assert_equal "1: 24   # 100 Best Books of the 21st Century  (25 -> 21st century so far, published 2024)", e.to_line
    assert_equal({1 => 24}, YAML.safe_load(e.to_line))
  end

  test "to_line appends flags after the reason" do
    e = derive(name: "The New Vanguard", description: "Novels of the 21st century.", year_published: nil)
    assert_match(/\(25 -> 21st century so far, published 2026; FROM DESCRIPTION; NO year_published \(used 2026\)\)\z/, e.to_line)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/num_years_covered_deriver_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::NumYearsCoveredDeriver`.

- [ ] **Step 3: Implement the deriver**

Create `app/lib/services/books_migration/num_years_covered_deriver.rb`:

```ruby
module Services
  module BooksMigration
    # First pass at Books::List#num_years_covered for the review file: how many
    # publication years the list's scope allowed. Pure -- takes rows and returns
    # Entry structs; the rake task does the legacy reads and the file write.
    # The name is parsed first and the description only when the name yields
    # nothing (description matches are the false positives, so they are flagged).
    # The one-year bucket is never parsed: legacy meant "each pick is best of one
    # year", however many years a yearly award spans. Every entry says why, so the
    # reviewer can find the wrong ones fast.
    class NumYearsCoveredDeriver
      Entry = Struct.new(:id, :years, :name, :bucket, :reason, :flags, keyword_init: true) do
        def to_line
          note = flags.any? ? "; #{flags.join("; ")}" : ""
          "#{id}: #{years}   # #{name}  (#{bucket} -> #{reason}#{note})"
        end
      end

      YEAR = "(1[5-9]\\d\\d|20[0-2]\\d)"
      RANGE = /\b#{YEAR}\s*(?:-|to|through|until)\s*#{YEAR}\b/i
      PAST_N = /\b(?:past|last|previous)\s+(\d{1,3})\s+years\b/i
      HALF_CENTURY = /\bhalf[- ]century\b/i
      QUARTER_CENTURY = /\bquarter[- ]century\b/i
      SINCE = /\b(?:since|from)\s+#{YEAR}\b/i
      DECADE = /\b(?:19|20)\d0s\b|\b[2-9]0s\b|\bdecade\b/i
      TWENTY_FIRST = /\b21st[- ]century\b|\bXXI\b/i
      CENTURY = /\b(?:20th|twentieth)[- ]century\b|\bcentury\b|\b100 years\b|\bwieku\b/i
      MILLENNIUM = /\bmillenni/i

      def self.call(rows, current_year: Date.current.year)
        rows.map { |row| new(row, current_year).entry }
      end

      def initialize(row, current_year)
        @row = row
        @current_year = current_year
        @flags = []
      end

      def entry
        buckets = @row[:buckets].uniq
        @flags << "CONFLICT #{buckets.sort.join("/")}, highest RC wins" if buckets.size > 1
        return build(1, "one-year bucket, never parsed") if @row[:bucket] == 1

        years, reason = parse(@row[:name])
        if years.nil? && reason.nil? && @row[:description].present?
          years, reason = parse(@row[:description])
          @flags.unshift("FROM DESCRIPTION") if reason
        end

        return build(@row[:bucket], reason || "unparsed") if years.nil?

        build(years, reason)
      end

      private

      def build(years, reason)
        Entry.new(id: @row[:id], years: years, name: @row[:name], bucket: @row[:bucket], reason: reason, flags: @flags)
      end

      # => [years, reason] on a match, [nil, reason] on a match that yields no
      # number (millennium), nil when nothing matched.
      def parse(text)
        text = text.to_s.tr("–—", "--")

        if (m = text.match(RANGE))
          from, to = m[1].to_i, m[2].to_i
          return [to - from + 1, "range #{from}-#{to}"] if to >= from && to - from < 400
        end
        if (m = text.match(PAST_N))
          return [m[1].to_i, "past #{m[1]} years"]
        end
        return [50, "half century"] if text.match?(HALF_CENTURY)
        return [25, "quarter century"] if text.match?(QUARTER_CENTURY)
        if (m = text.match(SINCE))
          from = m[1].to_i
          published = publication_year
          return [published - from + 1, "since #{from}, published #{published}"] if published > from
        end
        return [10, "decade"] if text.match?(DECADE)
        if text.match?(TWENTY_FIRST)
          published = publication_year
          return [published - 2000, "21st century so far, published #{published}"] if published > 2000
        end
        return [100, "century"] if text.match?(CENTURY)
        return [nil, "millennium: left to the reviewer"] if text.match?(MILLENNIUM)

        nil
      end

      def publication_year
        return @row[:year_published] if @row[:year_published]

        flag = "NO year_published (used #{@current_year})"
        @flags << flag unless @flags.include?(flag)
        @current_year
      end
    end
  end
end
```

Note on flag order: `FROM DESCRIPTION` is `unshift`ed so it precedes `NO year_published` when both apply, matching the `to_line` test; a `CONFLICT` flag added first stays first because `unshift` only runs on description matches — if a row has all three, the order is `FROM DESCRIPTION; CONFLICT …; NO year_published …`, which no test pins.

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/services/books_migration/num_years_covered_deriver_test.rb && bundle exec standardrb app/lib/services/books_migration/num_years_covered_deriver.rb test/lib/services/books_migration/num_years_covered_deriver_test.rb`
Expected: all pass, no offenses. If a regex case fails, fix the regex, not the expectation — the expectations are the spec's §4.2 table.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/num_years_covered_deriver.rb test/lib/services/books_migration/num_years_covered_deriver_test.rb
git commit -m "Add the num_years_covered first-pass deriver

Pure parser for the review file: explicit ranges, past-N-years, since
YYYY and 21st-century against the publication year, decades and
centuries. Name first, description only as a flagged fallback; the
one-year bucket is never parsed; millennium is left to the reviewer."
```

---

### Task 5: `NumYearsCoveredFile` and the `derive` rake task

**Files:**
- Create: `app/lib/services/books_migration/num_years_covered_file.rb`
- Modify: `app/lib/services/books_migration/num_years_covered_deriver.rb` (add `self.legacy_rows`)
- Modify: `lib/tasks/data_migration.rake` (new `num_years_covered:derive` task inside the `data_migration` namespace, before the `all` task)
- Test: `test/lib/services/books_migration/num_years_covered_file_test.rb`, `test/lib/tasks/data_migration_test.rb`

**Interfaces:**
- Produces: `Services::BooksMigration::NumYearsCoveredFile::PATH` (`Rails.root.join("config/books_migration/num_years_covered.yml")`); `.load(path = PATH)` → `Hash{Integer => Integer}` (`{}` when the file is absent; raises `ArgumentError` on a non-positive-integer entry); `.append(entries, path = PATH)` → `{kept: Integer, added: Integer}`.
- Produces: `NumYearsCoveredDeriver.legacy_rows` → the row hashes Task 4 consumes, read from the legacy database (active configurations only).
- Produces: rake task `data_migration:num_years_covered:derive`.

- [ ] **Step 1: Write the failing file tests**

Create `test/lib/services/books_migration/num_years_covered_file_test.rb`:

```ruby
require "test_helper"
require "tmpdir"

class Services::BooksMigration::NumYearsCoveredFileTest < ActiveSupport::TestCase
  F = Services::BooksMigration::NumYearsCoveredFile
  Entry = Services::BooksMigration::NumYearsCoveredDeriver::Entry

  setup do
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "num_years_covered.yml")
  end

  teardown { FileUtils.remove_entry(@dir) }

  def entry(id, years, name = "List #{id}")
    Entry.new(id: id, years: years, name: name, bucket: 25, reason: "unparsed", flags: [])
  end

  test "load returns an empty hash when the file does not exist" do
    assert_equal({}, F.load(@path))
  end

  test "load returns integer ids to integer years, ignoring comments" do
    File.write(@path, "# header\n1893: 24   # a list  (25 -> reason)\n42: 100\n")
    assert_equal({1893 => 24, 42 => 100}, F.load(@path))
  end

  test "load raises naming a non-positive-integer entry" do
    File.write(@path, "1893: 0\n")
    error = assert_raises(ArgumentError) { F.load(@path) }
    assert_match(/1893/, error.message)

    File.write(@path, "1893: twenty\n")
    assert_raises(ArgumentError) { F.load(@path) }
  end

  test "append creates the file with the header and the entries" do
    result = F.append([entry(1, 10), entry(2, 20)], @path)

    assert_equal({kept: 0, added: 2}, result)
    content = File.read(@path)
    assert content.start_with?("# Books lists: number of publication years"), content
    assert_equal({1 => 10, 2 => 20}, F.load(@path))
  end

  test "append keeps existing lines verbatim and adds only new ids" do
    F.append([entry(1, 10)], @path)
    File.write(@path, File.read(@path).sub("1: 10", "1: 12   # reviewed by hand"))

    result = F.append([entry(1, 99), entry(3, 30)], @path)

    assert_equal({kept: 1, added: 1}, result)
    assert_includes File.read(@path), "1: 12   # reviewed by hand"
    assert_equal({1 => 12, 3 => 30}, F.load(@path))
  end

  test "append with nothing new leaves the file byte-identical" do
    F.append([entry(1, 10)], @path)
    before = File.read(@path)

    assert_equal({kept: 1, added: 0}, F.append([entry(1, 10)], @path))
    assert_equal before, File.read(@path)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/num_years_covered_file_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::NumYearsCoveredFile`.

- [ ] **Step 3: Implement the file class**

Create `app/lib/services/books_migration/num_years_covered_file.rb`:

```ruby
module Services
  module BooksMigration
    # The reviewed per-list num_years_covered values: a plain `id: years` YAML
    # mapping written as text so the reviewer's comments survive. `load` returns
    # the values only; `append` adds entries for ids the file does not already
    # carry and never rewrites an existing line, so hand edits are safe across
    # regenerations. Delete the file to start over.
    class NumYearsCoveredFile
      PATH = Rails.root.join("config/books_migration/num_years_covered.yml")

      HEADER = <<~YAML
        # Books lists: number of publication years the list's scope allowed.
        # Generated by `bin/rails data_migration:num_years_covered:derive` from the LEGACY
        # database. Edit values freely; existing entries are never rewritten. Delete the
        # file to regenerate from scratch. Read by NumYearsCoveredMigrator (values only).
        #
        # id: years   # list name  (legacy bucket -> how the number was derived)
      YAML

      def self.load(path = PATH)
        return {} unless File.exist?(path)

        data = YAML.safe_load(File.read(path)) || {}
        data.each do |id, years|
          next if id.is_a?(Integer) && years.is_a?(Integer) && years.positive?

          raise ArgumentError, "#{path}: entry #{id.inspect}: #{years.inspect} is not a positive integer"
        end
        data
      end

      # entries: objects responding to #id and #to_line (NumYearsCoveredDeriver::Entry).
      def self.append(entries, path = PATH)
        known = load(path).keys.to_set
        fresh = entries.reject { |entry| known.include?(entry.id) }
        return {kept: known.size, added: 0} if fresh.empty?

        existing = File.exist?(path) ? File.read(path) : HEADER
        existing += "\n" unless existing.end_with?("\n")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, existing + fresh.map(&:to_line).join("\n") + "\n")
        {kept: known.size, added: fresh.size}
      end
    end
  end
end
```

- [ ] **Step 4: Run the file tests**

Run: `bin/rails test test/lib/services/books_migration/num_years_covered_file_test.rb`
Expected: all pass.

- [ ] **Step 5: Add `legacy_rows` to the deriver**

In `app/lib/services/books_migration/num_years_covered_deriver.rb`, add below `self.call`:

```ruby
      # The rows `call` wants, read from the legacy database: every list carrying a
      # year-span static on an ACTIVE legacy configuration (the same set the
      # migration maps), with its bucket from the highest configuration id and every
      # bucket it carries for the CONFLICT flag. Legacy-only on purpose: the file can
      # be regenerated before, after, or without a migration run.
      def self.legacy_rows
        buckets = PenaltyResolver::YEAR_SPAN_BUCKETS
        active_ids = LegacyBooks::RankingConfiguration.where(archived: false).pluck(:id)
        cons = LegacyBooks::ListCon
          .where(name: buckets.keys, ranking_configuration_id: active_ids)
          .pluck(:id, :name, :ranking_configuration_id)
          .to_h { |id, name, rc_id| [id, [rc_id, buckets.fetch(name)]] }
        pairs = LegacyBooks::ListConList
          .where(list_con_id: cons.keys)
          .joins("JOIN ranked_lists ON ranked_lists.id = list_con_lists.ranked_list_id")
          .pluck(Arel.sql("ranked_lists.list_id"), :list_con_id)
        by_list = pairs.group_by(&:first).transform_values { |ps| ps.map { |_, con_id| cons.fetch(con_id) } }

        LegacyBooks::List.where(id: by_list.keys).order(:id).map do |list|
          hits = by_list.fetch(list.id)
          {
            id: list.id,
            name: list.name,
            description: list.description,
            year_published: list.year_published,
            bucket: hits.max_by(&:first).last,
            buckets: hits.map(&:last).uniq
          }
        end
      end
```

- [ ] **Step 6: Write the failing rake test**

In `test/lib/tasks/data_migration_test.rb`, add `data_migration:num_years_covered:derive` to the `%w[...]` reenable list in `setup`, and add:

```ruby
  test "num_years_covered:derive derives from legacy rows and appends to the review file" do
    rows = [{id: 7, name: "Best of the 1990s", description: nil, year_published: 2001, bucket: 10, buckets: [10]}]
    Services::BooksMigration::NumYearsCoveredDeriver.expects(:legacy_rows).once.returns(rows)
    Services::BooksMigration::NumYearsCoveredFile.expects(:append).once.with { |entries|
      entries.size == 1 && entries.first.id == 7 && entries.first.years == 10
    }.returns(kept: 3, added: 1)

    out, _err = capture_io { Rake::Task["data_migration:num_years_covered:derive"].invoke }
    assert_match(/kept 3 existing entries, added 1/, out)
  end
```

- [ ] **Step 7: Run to verify it fails**

Run: `bin/rails test test/lib/tasks/data_migration_test.rb -n "/derive/"`
Expected: FAIL — `Don't know how to build task 'data_migration:num_years_covered:derive'`.

- [ ] **Step 8: Add the rake task**

In `lib/tasks/data_migration.rake`, inside `namespace :data_migration do`, directly after the `list_penalties` task (around line 121):

```ruby
  namespace :num_years_covered do
    desc "Write/append config/books_migration/num_years_covered.yml from legacy year-span list_cons (active RCs); existing entries are kept"
    task derive: :environment do
      rows = Services::BooksMigration::NumYearsCoveredDeriver.legacy_rows
      entries = Services::BooksMigration::NumYearsCoveredDeriver.call(rows)
      result = Services::BooksMigration::NumYearsCoveredFile.append(entries)
      puts "#{Services::BooksMigration::NumYearsCoveredFile::PATH}: kept #{result[:kept]} existing entries, added #{result[:added]} (#{entries.size} lists derived)"
    end
  end
```

- [ ] **Step 9: Run the rake tests, file tests and lint**

Run: `bin/rails test test/lib/tasks/data_migration_test.rb test/lib/services/books_migration/num_years_covered_file_test.rb test/lib/services/books_migration/num_years_covered_deriver_test.rb && bundle exec standardrb app/lib/services/books_migration/num_years_covered_file.rb app/lib/services/books_migration/num_years_covered_deriver.rb lib/tasks/data_migration.rake test/lib/services/books_migration/num_years_covered_file_test.rb test/lib/tasks/data_migration_test.rb`
Expected: all pass, no offenses.

- [ ] **Step 10: Commit**

```bash
git add app/lib/services/books_migration/num_years_covered_file.rb app/lib/services/books_migration/num_years_covered_deriver.rb lib/tasks/data_migration.rake test/lib/services/books_migration/num_years_covered_file_test.rb test/lib/tasks/data_migration_test.rb
git commit -m "Add the num_years_covered review file and its derive task

config/books_migration/num_years_covered.yml is a plain id: years
mapping written as text so the reviewer's comments survive; append
never rewrites an existing line. data_migration:num_years_covered:derive
reads the active legacy configurations only, so the file can be
regenerated before, after or without a migration run."
```

---

### Task 6: Generate the review file (dev) and hand it to Shane

**Files:**
- Create: `config/books_migration/num_years_covered.yml` (generated)

**Interfaces:**
- Consumes: the `legacy_books` development connection (`the_greatest_books_legacy`, refreshed from production on 2026-09-13).
- Produces: the committed review file Task 7's migrator reads.

- [ ] **Step 1: Confirm the legacy connection is reachable**

Run: `bin/rails runner 'puts LegacyBooks::RankingConfiguration.where(archived: false).count' 2>&1 | grep -v warning`
Expected: `4`.

- [ ] **Step 2: Generate the file**

Run: `bin/rails data_migration:num_years_covered:derive 2>&1 | grep -v warning`
Expected: one line ending `kept 0 existing entries, added 205 (205 lists derived)`. If the count is not 205, stop and report — the spec sized the review on 205.

- [ ] **Step 3: Sanity-check the output**

Run:
```bash
head -8 config/books_migration/num_years_covered.yml
grep -c "FROM DESCRIPTION" config/books_migration/num_years_covered.yml
grep -c "NO year_published" config/books_migration/num_years_covered.yml
grep -c "unparsed" config/books_migration/num_years_covered.yml
grep -c "CONFLICT" config/books_migration/num_years_covered.yml
bin/rails runner 'h = Services::BooksMigration::NumYearsCoveredFile.load; puts "#{h.size} entries, all positive: #{h.values.all?(&:positive?)}"' 2>&1 | grep -v warning
```
Expected: header present; a handful of `FROM DESCRIPTION` (roughly 5–15), some `NO year_published`, about 8 `unparsed`, 0 `CONFLICT`; `205 entries, all positive: true`. Report the four counts.

- [ ] **Step 4: Produce the reviewer's shortlist**

Run:
```bash
ruby -ne 'if $_ =~ /\A(\d+): (\d+)\s+#.*\((\d+) -> (.*)\)\s*\z/ then puts $_ if $2.to_i != $3.to_i || $4 =~ /FROM DESCRIPTION|unparsed|NO year_published|millennium/ end' config/books_migration/num_years_covered.yml | tee /dev/stderr | wc -l
```
Expected: roughly 60–75 lines — the entries whose value differs from the bucket or carry a flag — printed to the terminal with the count last. Paste them into the task report so Shane sees the shortlist without opening the file.

- [ ] **Step 5: Commit the generated file**

```bash
git add config/books_migration/num_years_covered.yml
git commit -m "Generate the num_years_covered review file from legacy

First pass over the 205 books lists that carry a year-span static on
an active legacy configuration. Values are the parser's; Shane reviews
the entries that differ from the legacy bucket or carry a flag."
```

- [ ] **Step 6: Stop for review**

Tell Shane the file is committed, paste the shortlist, and say the remaining tasks continue in parallel with his review; whatever the file holds when Task 9 runs is what dev gets, and it can be re-applied any time by re-running `data_migration:list_penalties`.

---

### Task 7: `NumYearsCoveredMigrator` and the `list_penalties` wiring

**Files:**
- Modify: `app/lib/services/books_migration/migrator.rb` (add an `extra_result_data` hook)
- Create: `app/lib/services/books_migration/num_years_covered_migrator.rb`
- Modify: `lib/tasks/data_migration.rake` (`list_penalties` task, lines 118–121)
- Test: `test/lib/services/books_migration/num_years_covered_migrator_test.rb`, `test/lib/tasks/data_migration_test.rb`

**Interfaces:**
- Consumes: `PenaltyResolver::YEAR_SPAN_BUCKETS` (Task 2), `NumYearsCoveredFile.load` (Task 5), `ListMigrator.superseded_legacy_list_ids`, `LegacyIdMap "Books::RankingConfiguration"`.
- Produces: `Services::BooksMigration::NumYearsCoveredMigrator.call` → `{success: true, data: {model: "Books::List#num_years_covered", count: <legacy rows>, lists_updated:, overrides_applied:, unknown_override_ids: [...]}}`; `legacy_each` yields `{"id", "list_id", "list_con_name", "ranking_configuration_id"}`.
- Produces: `Migrator#extra_result_data` (private, default `{}`), merged into the success result's `data`.

- [ ] **Step 1: Write the failing migrator tests**

Create `test/lib/services/books_migration/num_years_covered_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::NumYearsCoveredMigratorTest < ActiveSupport::TestCase
  ONE_YEAR = "List: only covers 1 year (yearly book awards, best of the year, etc)"

  setup do
    @list = ::Books::List.create!(name: "Years List")
    # The migrator calls NumYearsCoveredFile.load with no arguments; tests never
    # touch the real config file.
    Services::BooksMigration::NumYearsCoveredFile.stubs(:load).with.returns({})
  end

  def overrides(hash)
    Services::BooksMigration::NumYearsCoveredFile.stubs(:load).with.returns(hash)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::NumYearsCoveredMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def row(id, overrides = {})
    {
      "id" => id,
      "list_id" => @list.id,
      "list_con_name" => "List: only covers 25 years",
      "ranking_configuration_id" => 68
    }.merge(overrides)
  end

  test "sets the legacy bucket when there is no override" do
    result = run_migrator([row(1)])
    assert result[:success], result[:error]
    assert_equal 25, @list.reload.num_years_covered
    assert_equal 1, result[:data][:lists_updated]
    assert_equal 0, result[:data][:overrides_applied]
  end

  test "an override beats the bucket" do
    overrides(@list.id => 21)
    result = run_migrator([row(1)])
    assert result[:success], result[:error]
    assert_equal 21, @list.reload.num_years_covered
    assert_equal 1, result[:data][:overrides_applied]
  end

  test "the one-year bucket maps to 1" do
    run_migrator([row(1, "list_con_name" => ONE_YEAR)])
    assert_equal 1, @list.reload.num_years_covered
  end

  test "the highest legacy ranking configuration wins a conflict, whatever the row order" do
    run_migrator([row(1, "ranking_configuration_id" => 68, "list_con_name" => "List: only covers 25 years"),
      row(2, "ranking_configuration_id" => 48, "list_con_name" => ONE_YEAR)])
    assert_equal 25, @list.reload.num_years_covered

    run_migrator([row(3, "ranking_configuration_id" => 48, "list_con_name" => ONE_YEAR),
      row(4, "ranking_configuration_id" => 68, "list_con_name" => "List: only covers 10 years")])
    assert_equal 10, @list.reload.num_years_covered
  end

  test "overwrites a stale value on re-run (idempotent)" do
    @list.update!(num_years_covered: 99)
    run_migrator([row(1)])
    assert_equal 25, @list.reload.num_years_covered
    run_migrator([row(1)])
    assert_equal 25, @list.reload.num_years_covered
  end

  test "leaves a list with no year-span row untouched" do
    other = ::Books::List.create!(name: "All time", num_years_covered: 137)
    run_migrator([row(1)])
    assert_equal 137, other.reload.num_years_covered
  end

  test "reports override ids that match no list without failing" do
    ghost = List.maximum(:id).to_i + 999_999
    overrides(ghost => 5)
    result = run_migrator([row(1)])
    assert result[:success], result[:error]
    assert_equal [ghost], result[:data][:unknown_override_ids]
    assert_equal 25, @list.reload.num_years_covered
  end

  test "skips a row belonging to a superseded users' favorites list" do
    missing = List.maximum(:id).to_i + 999_999
    Services::BooksMigration::ListMigrator.stubs(:superseded_legacy_list_ids).returns(Set[missing])
    result = run_migrator([row(1, "list_id" => missing)])
    assert result[:success], result[:error]
    assert_equal 0, result[:data][:lists_updated]
  end

  test "fails loud when the parent list is missing for any other reason" do
    missing = List.maximum(:id).to_i + 999_999
    result = run_migrator([row(9, "list_id" => missing)])
    refute result[:success]
    assert_match(/#{missing}/, result[:error])
  end

  test "fails loud on an unknown year-span name" do
    result = run_migrator([row(1, "list_con_name" => "List: only covers 12 years")])
    refute result[:success]
    assert_match(/12 years/, result[:error])
  end

  test "fails loud when no Books::List has been migrated at all" do
    ::Books::List.stubs(:exists?).returns(false)
    result = run_migrator([row(1)])
    refute result[:success]
    assert_match(/data_migration:lists/, result[:error])
  end

  test "surfaces a malformed override file as a failure" do
    Services::BooksMigration::NumYearsCoveredFile.stubs(:load).with.raises(ArgumentError, "entry 5: 0 is not a positive integer")
    result = run_migrator([row(1)])
    refute result[:success]
    assert_match(/not a positive integer/, result[:error])
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/num_years_covered_migrator_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::NumYearsCoveredMigrator`.

- [ ] **Step 3: Add the base-class hook**

In `app/lib/services/books_migration/migrator.rb`, change the success result and add the hook:

```ruby
        finalize
        {success: true, data: {model: model_key, count: @count}.merge(extra_result_data)}
```

and under `def finalize; end`:

```ruby
      # Extra keys a subclass wants in the success result's data (counts it kept
      # during finalize, for instance). Default: none.
      def extra_result_data
        {}
      end
```

- [ ] **Step 4: Implement the migrator**

Create `app/lib/services/books_migration/num_years_covered_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy year-span list_cons (the seven "List: only covers N years" statics) ->
    # Books::List#num_years_covered. Those statics resolve to the num_years_covered
    # dynamic global (PenaltyResolver::YEAR_SPAN_BUCKETS), so the per-list fact they
    # carried has to land on the list. Value = the reviewed override in
    # config/books_migration/num_years_covered.yml when present, else the legacy
    # bucket. One value per list; the highest legacy ranking_configuration_id wins a
    # conflict. Plain overwrite (update_all), so it is idempotent and a re-run
    # re-applies an edited file. Lists with no year-span row are never touched.
    # Scoped to active legacy configurations via the "Books::RankingConfiguration"
    # map, like every other penalty-side migrator.
    class NumYearsCoveredMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ListConList
      end

      def model_key
        "Books::List#num_years_covered"
      end

      def legacy_each(&block)
        rc_ids = active_rc_legacy_ids
        legacy_model
          .joins("JOIN ranked_lists ON ranked_lists.id = list_con_lists.ranked_list_id")
          .joins("JOIN list_cons ON list_cons.id = list_con_lists.list_con_id")
          .where("list_cons.name IN (?) AND list_cons.ranking_configuration_id IN (?)", PenaltyResolver::YEAR_SPAN_BUCKETS.keys, rc_ids)
          .select("list_con_lists.id, ranked_lists.list_id AS list_id, list_cons.name AS list_con_name, list_cons.ranking_configuration_id AS ranking_configuration_id")
          .find_each(batch_size: BATCH_SIZE) do |record|
            block.call(
              "id" => record.id,
              "list_id" => record.list_id,
              "list_con_name" => record.list_con_name,
              "ranking_configuration_id" => record.ranking_configuration_id
            )
          end
      end

      # Collects only; the writes happen once per list in finalize.
      def upsert_row(attrs)
        bucket = PenaltyResolver::YEAR_SPAN_BUCKETS.fetch(attrs["list_con_name"]) do
          raise "unknown year-span list_con name #{attrs["list_con_name"].inspect}"
        end
        rc_id = attrs["ranking_configuration_id"]
        current = best[attrs["list_id"]]
        best[attrs["list_id"]] = [rc_id, bucket] if current.nil? || rc_id > current.first
      end

      def finalize
        raise "no migrated Books::List; run data_migration:lists first" unless ::Books::List.exists?

        overrides = NumYearsCoveredFile.load
        present = ::Books::List.where(id: best.keys).pluck(:id).to_set
        superseded = ListMigrator.superseded_legacy_list_ids
        @lists_updated = 0
        @overrides_applied = 0

        best.each do |list_id, (_rc_id, bucket)|
          unless present.include?(list_id)
            next if superseded.include?(list_id)

            raise "no migrated Books::List for legacy list id=#{list_id}"
          end

          if overrides.key?(list_id)
            value = overrides.fetch(list_id)
            @overrides_applied += 1
          else
            value = bucket
          end
          ::Books::List.where(id: list_id).update_all(num_years_covered: value)
          @lists_updated += 1
        end

        @unknown_override_ids = (overrides.keys - ::Books::List.where(id: overrides.keys).pluck(:id)).sort
      end

      def extra_result_data
        {
          lists_updated: @lists_updated,
          overrides_applied: @overrides_applied,
          unknown_override_ids: @unknown_override_ids
        }
      end

      def best
        @best ||= {}
      end

      def active_rc_legacy_ids
        ids = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id)
        raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if ids.empty?
        ids
      end
    end
  end
end
```

- [ ] **Step 5: Run the migrator tests**

Run: `bin/rails test test/lib/services/books_migration/num_years_covered_migrator_test.rb test/lib/services/books_migration/`
Expected: the new tests pass and every other migrator test still passes (the base-class change is additive).

- [ ] **Step 6: Write the failing rake test**

In `test/lib/tasks/data_migration_test.rb`, add `data_migration:list_penalties` to the reenable list and:

```ruby
  test "list_penalties runs the num_years_covered migrator after the list-penalty migrator" do
    order = sequence("list_penalties")
    Services::BooksMigration::ListPenaltyMigrator.expects(:call).once.in_sequence(order)
      .returns(success: true, data: {model: "ListPenalty", count: 1})
    Services::BooksMigration::NumYearsCoveredMigrator.expects(:call).once.in_sequence(order)
      .returns(success: true, data: {model: "Books::List#num_years_covered", count: 1})

    capture_io { Rake::Task["data_migration:list_penalties"].invoke }
  end

  test "list_penalties aborts when the num_years_covered migrator fails" do
    Services::BooksMigration::ListPenaltyMigrator.stubs(:call).returns(success: true, data: {model: "ListPenalty", count: 1})
    Services::BooksMigration::NumYearsCoveredMigrator.stubs(:call).returns(success: false, error: "entry 5: 0 is not a positive integer")

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:list_penalties"].invoke }
    end
    assert_match(/num_years_covered migration failed: entry 5/, err)
  end
```

- [ ] **Step 7: Run to verify the rake tests fail**

Run: `bin/rails test test/lib/tasks/data_migration_test.rb -n "/list_penalties/"`
Expected: FAIL — `NumYearsCoveredMigrator.call` never invoked; no abort.

- [ ] **Step 8: Wire the task**

In `lib/tasks/data_migration.rake`, replace the `list_penalties` task:

```ruby
  desc "Migrate legacy list_con_lists into list_penalties (static penalties only) and set Books::List#num_years_covered from the year-span statics + config/books_migration/num_years_covered.yml"
  task list_penalties: :environment do
    pp Services::BooksMigration::ListPenaltyMigrator.call
    result = Services::BooksMigration::NumYearsCoveredMigrator.call
    pp result
    abort "num_years_covered migration failed: #{result[:error]}" unless result[:success]
  end
```

- [ ] **Step 9: Run tests, lint, zeitwerk**

Run: `bin/rails test test/lib/tasks/data_migration_test.rb test/lib/services/books_migration/ && bundle exec standardrb app/lib/services/books_migration/migrator.rb app/lib/services/books_migration/num_years_covered_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/num_years_covered_migrator_test.rb test/lib/tasks/data_migration_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: all pass, no offenses, `All is good!`.

- [ ] **Step 10: Commit**

```bash
git add app/lib/services/books_migration/migrator.rb app/lib/services/books_migration/num_years_covered_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/num_years_covered_migrator_test.rb test/lib/tasks/data_migration_test.rb
git commit -m "Migrate legacy year-span statics onto Books::List#num_years_covered

New NumYearsCoveredMigrator: legacy list_con_lists for the seven
'only covers N years' statics (active configurations) -> the reviewed
override from config/books_migration/num_years_covered.yml, else the
legacy bucket; highest legacy configuration wins a conflict. Runs
inside data_migration:list_penalties after the list-penalty migrator."
```

---

### Task 8: `PenaltyReconciler`, the `penalties:reconcile` task, and the dead backfill entries

**Files:**
- Create: `app/lib/services/books_migration/penalty_reconciler.rb`
- Modify: `lib/tasks/data_migration.rake` (new `penalties:reconcile` task; `all` prerequisites at lines 288–293)
- Modify: `lib/tasks/penalties.rake` (delete the entries at lines 61–81 for ids 28, 29, 30, 33, 35, 40, 41; lines 141–143 for id 48; lines 158–160 for id 24)
- Test: `test/lib/services/books_migration/penalty_reconciler_test.rb`, `test/lib/tasks/data_migration_test.rb`, `test/lib/tasks/penalties_rake_test.rb` (must still pass unchanged)

**Interfaces:**
- Consumes: `PenaltyResolver::YEAR_SPAN_BUCKETS` (Task 2); fixtures `penalties(:honorable_mention_penalty)` (the `Global::Penalty` follow-up name) and `users(:regular_user)`. The `books_one_year_penalty` fixture is a `Books::Penalty` named exactly like the one-year static, so the test setup destroys it and creates sources explicitly.
- Produces: `Services::BooksMigration::PenaltyReconciler.call` → `{success: true, data: {list_penalties_repointed:, list_penalties_dropped:, applications_repointed:, applications_merged:, dynamic_applications_upserted:, year_list_penalties_dropped:, id_map_repointed:, penalties_destroyed:}}` (every key present, integers, all zero on a no-op); rake task `data_migration:penalties:reconcile`.

- [ ] **Step 1: Write the failing reconciler tests**

Create `test/lib/services/books_migration/penalty_reconciler_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::PenaltyReconcilerTest < ActiveSupport::TestCase
  R = Services::BooksMigration::PenaltyReconciler
  ZERO = {
    list_penalties_repointed: 0, list_penalties_dropped: 0,
    applications_repointed: 0, applications_merged: 0,
    dynamic_applications_upserted: 0, year_list_penalties_dropped: 0,
    id_map_repointed: 0, penalties_destroyed: 0
  }.freeze

  setup do
    @rc = ranking_configurations(:books_global)
    @other_rc = ranking_configurations(:books_year_2025)
    @list_a = ::Books::List.create!(name: "A")
    @list_b = ::Books::List.create!(name: "B")
    @follow_up = penalties(:honorable_mention_penalty) # Global target, by its seed name
    @weird_global = Global::Penalty.create!(name: "List: only covers items with a weird criteria")
    @years_global = Global::Penalty.create!(name: "List: number of years covered", dynamic_type: :num_years_covered)
    # The fixture is a Books::Penalty named exactly like the one-year static, so the
    # reconciler would find it by name in every test. Remove it (nothing in the join
    # fixtures references it) and let each test create the sources it needs.
    penalties(:books_one_year_penalty).destroy!
  end

  ONE_YEAR = "List: only covers 1 year (yearly book awards, best of the year, etc)"

  def honorable_source
    ::Books::Penalty.create!(name: "List: honorable mention")
  end

  def weird_source
    ::Books::Penalty.create!(name: "List: only covers books with a weird criteria(books to help you survive the digital age, etc)")
  end

  def year_source(name)
    ::Books::Penalty.create!(name: name)
  end

  test "is a no-op with all-zero counts when nothing needs reconciling" do
    result = R.call
    assert result[:success], result[:error]
    assert_equal ZERO, result[:data]
  end

  test "repoints list_penalties and applications from the honorable-mention duplicate to the global" do
    source = honorable_source
    ListPenalty.create!(list: @list_a, penalty: source)
    PenaltyApplication.create!(penalty: source, ranking_configuration: @other_rc, value: 50)

    result = R.call

    assert result[:success], result[:error]
    assert ListPenalty.exists?(list: @list_a, penalty: @follow_up)
    assert_equal 50, PenaltyApplication.find_by(penalty: @follow_up, ranking_configuration: @other_rc).value
    assert_nil ::Books::Penalty.find_by(name: "List: honorable mention")
    assert_equal 1, result[:data][:list_penalties_repointed]
    assert_equal 1, result[:data][:applications_repointed]
    assert_equal 1, result[:data][:penalties_destroyed]
  end

  test "drops a colliding list_penalty and merges a colliding application at MAX" do
    source = weird_source
    ListPenalty.create!(list: @list_a, penalty: source)
    ListPenalty.create!(list: @list_a, penalty: @weird_global)
    PenaltyApplication.create!(penalty: source, ranking_configuration: @rc, value: 60)
    PenaltyApplication.create!(penalty: @weird_global, ranking_configuration: @rc, value: 40)

    result = R.call

    assert result[:success], result[:error]
    assert_equal 1, ListPenalty.where(list: @list_a).count
    assert_equal 60, PenaltyApplication.find_by(penalty: @weird_global, ranking_configuration: @rc).value
    assert_equal 1, result[:data][:list_penalties_dropped]
    assert_equal 1, result[:data][:applications_merged]
  end

  test "a colliding application keeps the larger existing value" do
    source = weird_source
    PenaltyApplication.create!(penalty: source, ranking_configuration: @rc, value: 20)
    PenaltyApplication.create!(penalty: @weird_global, ranking_configuration: @rc, value: 40)

    R.call

    assert_equal 40, PenaltyApplication.find_by(penalty: @weird_global, ranking_configuration: @rc).value
  end

  test "repoints the legacy id map for a merged duplicate" do
    source = honorable_source
    LegacyIdMap.record(model: "Penalty", legacy_id: 2804, new_id: source.id)

    result = R.call

    assert_equal @follow_up.id, LegacyIdMap.lookup(model: "Penalty", legacy_id: 2804)
    assert_equal 1, result[:data][:id_map_repointed]
  end

  test "gives every configuration that applied a year-span static the dynamic global at its own MAX" do
    one_year = year_source(ONE_YEAR)
    ten_years = year_source("List: only covers 10 years")
    PenaltyApplication.create!(penalty: one_year, ranking_configuration: @rc, value: 50)
    PenaltyApplication.create!(penalty: ten_years, ranking_configuration: @rc, value: 30)
    PenaltyApplication.create!(penalty: ten_years, ranking_configuration: @other_rc, value: 25)
    ListPenalty.create!(list: @list_a, penalty: one_year)
    ListPenalty.create!(list: @list_b, penalty: ten_years)
    LegacyIdMap.record(model: "Penalty", legacy_id: 2970, new_id: ten_years.id)

    result = R.call

    assert result[:success], result[:error]
    assert_equal 50, PenaltyApplication.find_by(penalty: @years_global, ranking_configuration: @rc).value
    assert_equal 25, PenaltyApplication.find_by(penalty: @years_global, ranking_configuration: @other_rc).value
    assert_nil ::Books::Penalty.find_by(name: "List: only covers 10 years")
    assert_nil ::Books::Penalty.find_by(name: ONE_YEAR)
    assert_empty ListPenalty.where(list: [@list_a, @list_b])
    assert_equal @years_global.id, LegacyIdMap.lookup(model: "Penalty", legacy_id: 2970)
    assert_equal 2, result[:data][:dynamic_applications_upserted]
    assert_equal 2, result[:data][:year_list_penalties_dropped]
    assert_equal 2, result[:data][:penalties_destroyed]
  end

  test "an existing dynamic application is raised to MAX, never lowered" do
    PenaltyApplication.create!(penalty: year_source(ONE_YEAR), ranking_configuration: @rc, value: 30)
    PenaltyApplication.create!(penalty: @years_global, ranking_configuration: @rc, value: 45)

    R.call

    assert_equal 45, PenaltyApplication.find_by(penalty: @years_global, ranking_configuration: @rc).value
  end

  test "ignores user-authored penalties that share a name" do
    user = users(:regular_user)
    mine = ::Books::Penalty.create!(name: "List: honorable mention", user: user)

    result = R.call

    assert ::Books::Penalty.exists?(mine.id)
    assert_equal ZERO, result[:data]
  end

  test "running twice leaves the database identical and reports zeros" do
    source = honorable_source
    ListPenalty.create!(list: @list_a, penalty: source)
    PenaltyApplication.create!(penalty: year_source(ONE_YEAR), ranking_configuration: @rc, value: 50)
    R.call
    snapshot = [Penalty.count, ListPenalty.count, PenaltyApplication.count,
      PenaltyApplication.order(:id).pluck(:penalty_id, :ranking_configuration_id, :value),
      LegacyIdMap.where(model: "Penalty").order(:legacy_id).pluck(:legacy_id, :new_id)]

    result = R.call

    assert_equal ZERO, result[:data]
    assert_equal snapshot, [Penalty.count, ListPenalty.count, PenaltyApplication.count,
      PenaltyApplication.order(:id).pluck(:penalty_id, :ranking_configuration_id, :value),
      LegacyIdMap.where(model: "Penalty").order(:legacy_id).pluck(:legacy_id, :new_id)]
  end

  test "fails loud when a year-span static exists but no num_years_covered global is seeded" do
    @years_global.destroy!
    one_year = year_source(ONE_YEAR)
    PenaltyApplication.create!(penalty: one_year, ranking_configuration: @rc, value: 50)

    result = R.call

    refute result[:success]
    assert_match(/num_years_covered/, result[:error])
    assert ::Books::Penalty.exists?(one_year.id), "the transaction must roll back"
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/penalty_reconciler_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::PenaltyReconciler`.

- [ ] **Step 3: Implement the reconciler**

Create `app/lib/services/books_migration/penalty_reconciler.rb`:

```ruby
module Services
  module BooksMigration
    # Repairs a database migrated before PenaltyResolver learned the honorable-
    # mention and weird-criteria aliases and the year-span -> num_years_covered
    # mapping. Merges each Books duplicate into its global (list_penalties,
    # penalty_applications and the LegacyIdMap "Penalty" rows repointed; MAX wins a
    # collision), gives every configuration that applied a year-span static the
    # dynamic global at MAX(value) -- user-owned clones included -- and destroys the
    # now-unused Books penalties. Everything is located by NAME with user_id nil:
    # ids differ between environments. Idempotent: on a database migrated with the
    # new resolver nothing matches and every count is zero. One transaction.
    #
    # Ordered after NumYearsCoveredMigrator in data_migration:all so the per-list
    # values exist before the statics (and their list_penalties) vanish.
    class PenaltyReconciler
      MERGES = {
        "List: honorable mention" => "List: is a follow up/honorable mention to a different list",
        "List: only covers books with a weird criteria(books to help you survive the digital age, etc)" => "List: only covers items with a weird criteria"
      }.freeze

      COUNTS = %i[
        list_penalties_repointed list_penalties_dropped
        applications_repointed applications_merged
        dynamic_applications_upserted year_list_penalties_dropped
        id_map_repointed penalties_destroyed
      ].freeze

      def self.call
        new.call
      end

      def initialize
        @counts = COUNTS.index_with { 0 }
      end

      def call
        Penalty.transaction do
          MERGES.each do |source_name, target_name|
            source = books_penalty(source_name)
            next if source.nil?

            merge(source, Global::Penalty.find_by!(name: target_name, user_id: nil))
          end

          sources = PenaltyResolver::YEAR_SPAN_BUCKETS.keys.filter_map { |name| books_penalty(name) }
          convert_year_statics(sources) if sources.any?
        end
        {success: true, data: @counts}
      rescue => e
        {success: false, error: e.message, data: @counts}
      end

      private

      def books_penalty(name)
        ::Books::Penalty.find_by(name: name, user_id: nil)
      end

      def merge(source, target)
        source.list_penalties.find_each do |list_penalty|
          if ListPenalty.exists?(list_id: list_penalty.list_id, penalty_id: target.id)
            list_penalty.destroy!
            @counts[:list_penalties_dropped] += 1
          else
            list_penalty.update!(penalty: target)
            @counts[:list_penalties_repointed] += 1
          end
        end

        source.penalty_applications.find_each do |application|
          existing = PenaltyApplication.find_by(penalty_id: target.id, ranking_configuration_id: application.ranking_configuration_id)
          if existing
            existing.update!(value: application.value) if application.value > existing.value
            application.destroy!
            @counts[:applications_merged] += 1
          else
            application.update!(penalty: target)
            @counts[:applications_repointed] += 1
          end
        end

        repoint_id_map([source.id], target.id)
        source.reload.destroy!
        @counts[:penalties_destroyed] += 1
      end

      def convert_year_statics(sources)
        target = Global::Penalty.find_by(dynamic_type: :num_years_covered, user_id: nil)
        raise "no num_years_covered Global::Penalty seeded; run db:seed first" if target.nil?

        source_ids = sources.map(&:id)
        PenaltyApplication.where(penalty_id: source_ids).group(:ranking_configuration_id).maximum(:value).each do |rc_id, max_value|
          application = PenaltyApplication.find_or_initialize_by(penalty_id: target.id, ranking_configuration_id: rc_id)
          application.value = [application.value || 0, max_value].max
          application.save!
          @counts[:dynamic_applications_upserted] += 1
        end

        repoint_id_map(source_ids, target.id)
        sources.each do |source|
          @counts[:year_list_penalties_dropped] += source.list_penalties.count
          source.destroy! # dependent: :destroy takes its list_penalties and applications
          @counts[:penalties_destroyed] += 1
        end
      end

      def repoint_id_map(source_ids, target_id)
        @counts[:id_map_repointed] += LegacyIdMap.where(model: "Penalty", new_id: source_ids).update_all(new_id: target_id)
      end
    end
  end
end
```

- [ ] **Step 4: Run the reconciler tests**

Run: `bin/rails test test/lib/services/books_migration/penalty_reconciler_test.rb`
Expected: all pass. If `find_by(dynamic_type: :num_years_covered)` fails to match, the enum is being passed as a symbol to `where` on an integer column — Rails maps enum symbols in `where`, so it should work; if not, use `Penalty.dynamic_types[:num_years_covered]`.

- [ ] **Step 5: Write the failing rake tests**

In `test/lib/tasks/data_migration_test.rb`, add `data_migration:penalties:reconcile` to the reenable list and:

```ruby
  test "penalties:reconcile invokes the reconciler" do
    Services::BooksMigration::PenaltyReconciler.expects(:call).once.returns(success: true, data: {penalties_destroyed: 0})
    capture_io { Rake::Task["data_migration:penalties:reconcile"].invoke }
  end

  test "penalties:reconcile aborts when the reconciler fails" do
    Services::BooksMigration::PenaltyReconciler.stubs(:call).returns(success: false, error: "no num_years_covered Global::Penalty seeded")
    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["data_migration:penalties:reconcile"].invoke }
    end
    assert_match(/penalties:reconcile failed: no num_years_covered/, err)
  end

  test "penalties:reconcile runs immediately after list_penalties in the all task" do
    prerequisites = Rake::Task["data_migration:all"].prerequisites
    assert_equal prerequisites.index("list_penalties") + 1, prerequisites.index("penalties:reconcile")
    assert_operator prerequisites.index("penalties"), :<, prerequisites.index("list_penalties")
  end
```

- [ ] **Step 6: Run to verify they fail**

Run: `bin/rails test test/lib/tasks/data_migration_test.rb -n "/reconcile/"`
Expected: FAIL — task not defined; `prerequisites.index("penalties:reconcile")` is nil.

- [ ] **Step 7: Add the task and the `all` ordering**

In `lib/tasks/data_migration.rake`, directly after the `penalties` task (line 116):

```ruby
  namespace :penalties do
    desc "Merge duplicate Books penalties into their globals and year-span statics into num_years_covered (idempotent; repairs a DB migrated before the resolver changes)"
    task reconcile: :environment do
      result = Services::BooksMigration::PenaltyReconciler.call
      pp result
      abort "penalties:reconcile failed: #{result[:error]}" unless result[:success]
    end
  end
```

and in the `all` task change `:penalties, :list_penalties, :user_lists,` to `:penalties, :list_penalties, "penalties:reconcile", :user_lists,`.

- [ ] **Step 8: Delete the nine dead backfill entries**

In `lib/tasks/penalties.rake` delete, each as its three-line hash entry: `28 =>` … `41 =>` (lines 61–81, the seven year-span statics), `48 =>` (lines 141–143), `24 =>` (lines 158–160). Leave `17 =>`, `7 =>` and `4 =>` in place. Verify:

```bash
grep -cE "^      (24|28|29|30|33|35|40|41|48) =>" lib/tasks/penalties.rake
```
Expected: `0`.

- [ ] **Step 9: Run tests, lint, zeitwerk**

Run: `bin/rails test test/lib/tasks/ test/lib/services/books_migration/ && bundle exec standardrb app/lib/services/books_migration/penalty_reconciler.rb lib/tasks/data_migration.rake lib/tasks/penalties.rake test/lib/services/books_migration/penalty_reconciler_test.rb test/lib/tasks/data_migration_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: all pass (including `penalties_rake_test.rb`, which does not pin the entry count), no offenses, `All is good!`.

- [ ] **Step 10: Run the full suite once**

Run: `bin/rails test 2>&1 | tail -15`
Expected: green, and no new warning lines beyond the two known upstream sources (`weighted_list_rank` position `puts`, npm/yarn during prepare). Fix anything red before committing.

- [ ] **Step 11: Commit**

```bash
git add app/lib/services/books_migration/penalty_reconciler.rb lib/tasks/data_migration.rake lib/tasks/penalties.rake test/lib/services/books_migration/penalty_reconciler_test.rb test/lib/tasks/data_migration_test.rb
git commit -m "Add data_migration:penalties:reconcile for already-migrated databases

By name, never by id: merges the honorable-mention and weird-criteria
Books duplicates into their globals (list_penalties, applications and
the legacy id map repointed, MAX on a collision), gives every
configuration that applied a year-span static the num_years_covered
global at its own MAX, and destroys the nine unused Books penalties.
Idempotent; ordered after list_penalties in data_migration:all so the
per-list values exist before the statics go. Removes the nine backfill
entries those penalties made dead."
```

---

### Task 9: Run it in development on a snapshot, recalculate, show before/after

**Files:**
- No source changes. Outputs go to the scratchpad directory named in the session (`/tmp/claude-1001/.../scratchpad/`); nothing under the repo.

**Interfaces:**
- Consumes: the development database (a production restore, refreshed 2026-09-13) and its `legacy_books` connection; `Services::RankingConfiguration::CalculateWeights.call(rc)`; `RankingConfiguration#calculate_rankings`.
- Produces: a before/after report for Shane. Nothing is scheduled against production.

- [ ] **Step 1: Snapshot the development database**

From the worktree **root** (not `web-app/`):

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/books-penalty-reconciliation && COMPOSE_PROJECT_NAME=the-greatest bin/snapshot-dev-db.sh --label pre-penalty-reconcile && cd web-app
```
Expected: a dump written under `tmp/db-snapshots/`; the script prints its path. If it cannot find the Postgres container, stop and report — do not proceed without a snapshot.

- [ ] **Step 2: Capture the "before" state**

Write `$SCRATCH/before_after.rb` (replace `$SCRATCH` with the session's scratchpad path) and run it with `bin/rails runner $SCRATCH/before_after.rb before`:

```ruby
label = ARGV[0] or abort "usage: before|after"
rc = Books::RankingConfiguration.find_by!(primary: true, global: true)
year_names = Services::BooksMigration::PenaltyResolver::YEAR_SPAN_BUCKETS.keys
year_ids = Penalty.where(name: year_names, user_id: nil).pluck(:id)
affected = if year_ids.any?
  Books::List.joins(:list_penalties).where(list_penalties: {penalty_id: year_ids}).distinct.pluck(:id).sort
else
  Books::List.where.not(num_years_covered: nil).pluck(:id).sort
end
weights = RankedList.where(ranking_configuration: rc, list_id: affected).pluck(:list_id, :weight).to_h
top = RankedItem.where(ranking_configuration: rc).order(:rank).limit(25).pluck(:rank, :item_id, :score)
snapshot = {
  "rc_id" => rc.id,
  "affected_list_ids" => affected,
  "weights" => weights,
  "top_25" => top,
  "penalty_names" => rc.penalties.order(:name).pluck(:name),
  "num_years_covered_set" => Books::List.where.not(num_years_covered: nil).count
}
path = File.join(File.dirname(__FILE__), "#{label}.json")
File.write(path, JSON.pretty_generate(snapshot))
puts "#{label}: rc=#{rc.id} affected=#{affected.size} weights=#{weights.size} top25=#{top.size} penalties=#{snapshot["penalty_names"].size} num_years_set=#{snapshot["num_years_covered_set"]} -> #{path}"
```
Expected: `before: rc=8 affected=205 weights=<n> top25=25 penalties=41 num_years_set=0`, where `<n>` ≤ 205 is how many of the 205 lists are ranked in RC 8 (623 of 758 active books lists are). Note `<n>` — "after" must report the same number.

- [ ] **Step 3: Run the three migration steps in the `all` order**

```bash
bin/rails data_migration:penalties 2>&1 | grep -v warning
bin/rails data_migration:list_penalties 2>&1 | grep -v warning
bin/rails data_migration:penalties:reconcile 2>&1 | grep -v warning
```
Expected:
- `penalties`: both migrators `success: true` (the map rows for the seven year list_cons and the two aliases are repointed by `LegacyIdMap.record`'s upsert; a `(num_years_covered, RC 8)` application at 50 appears).
- `list_penalties`: `ListPenalty` success; `Books::List#num_years_covered` success with `lists_updated: 205`, `overrides_applied: 205` (every list is in the file), `unknown_override_ids: []`.
- `reconcile`: success with `penalties_destroyed: 9`, `dynamic_applications_upserted: 2` (RC 8 and RC 10), `year_list_penalties_dropped: 205`, and `id_map_repointed: 0` (the `penalties` re-run already repointed the map — if it reports > 0 that is also fine; report the number).

Paste the three result hashes into the task report.

- [ ] **Step 4: Verify the penalty catalogue**

```bash
bin/rails runner '
rc = Books::RankingConfiguration.find(8)
puts "RC 8 applications: #{rc.penalty_applications.count} (expect 35 = 41 - 7 statics + 1 dynamic)"
puts "Books duplicates left: #{Books::Penalty.where(name: ["List: honorable mention", "List: only covers books with a weird criteria(books to help you survive the digital age, etc)"] + Services::BooksMigration::PenaltyResolver::YEAR_SPAN_BUCKETS.keys, user_id: nil).count} (expect 0)"
g = Global::Penalty.find_by!(dynamic_type: :num_years_covered)
puts "num_years_covered on RC 8: #{PenaltyApplication.find_by(penalty: g, ranking_configuration_id: 8)&.value.inspect} (expect 50); on RC 10: #{PenaltyApplication.find_by(penalty: g, ranking_configuration_id: 10)&.value.inspect}"
puts "honorable mention global on RC 7: #{PenaltyApplication.find_by(penalty: Global::Penalty.find_by!(name: "List: is a follow up/honorable mention to a different list"), ranking_configuration_id: 7)&.value.inspect} (expect 50)"
puts "weird criteria global on RC 8: #{PenaltyApplication.find_by(penalty: Global::Penalty.find_by!(name: "List: only covers items with a weird criteria"), ranking_configuration_id: 8)&.value.inspect} (expect 60)"
puts "books lists with num_years_covered: #{Books::List.where.not(num_years_covered: nil).count} (expect 205)"
puts "stale Penalty map rows: #{LegacyIdMap.where(model: "Penalty").where.not(new_id: Penalty.select(:id)).count} (expect 0)"
' 2>&1 | grep -v warning
```
Expected: every `(expect …)` matches. Stop and report on any mismatch.

- [ ] **Step 5: Recalculate weights and verify they persisted**

```bash
bin/rails runner '
[8, 10].each do |id|
  rc = RankingConfiguration.find(id)
  result = Services::RankingConfiguration::CalculateWeights.call(rc)
  puts "RC #{id}: #{result.inspect[0, 200]}"
  stale = rc.ranked_lists.count { |r| r.calculated_weight_details.to_h.dig("final_calculation", "final_weight") != r.weight }
  puts "RC #{id}: ranked_lists whose stored weight disagrees with their own details: #{stale} (must be 0)"
end
' 2>&1 | grep -v warning
```
Expected: `must be 0` is 0 for both. If it is not, run `CalculateWeights.call` for that RC once more and re-check (see the memory `books-weights-drifted-2x`: a run can report success without persisting). Do not proceed to rankings until it is 0.

- [ ] **Step 6: Recalculate rankings for RC 8 and capture "after"**

```bash
bin/rails runner 'r = Books::RankingConfiguration.find(8).calculate_rankings; puts r.inspect[0, 300]' 2>&1 | grep -v warning
bin/rails runner $SCRATCH/before_after.rb after 2>&1 | grep -v warning
```
Expected: rankings succeed; `after: rc=8 affected=205 weights=<n> top25=25 penalties=35 num_years_set=205` with the same `<n>` as before.

- [ ] **Step 7: Build the report**

Write and run `$SCRATCH/report.rb` with `bin/rails runner`:

```ruby
dir = File.dirname(__FILE__)
before = JSON.parse(File.read(File.join(dir, "before.json")))
after = JSON.parse(File.read(File.join(dir, "after.json")))
overrides = Services::BooksMigration::NumYearsCoveredFile.load

puts "## Weights of the 205 lists that moved from static year buckets to num_years_covered"
rows = before["weights"].filter_map do |list_id, w0|
  w1 = after["weights"][list_id]
  next if w1.nil? # not ranked in RC 8 after the run -- reported separately below
  list = Books::List.find(list_id.to_i)
  [list_id.to_i, list.name[0, 60], overrides[list_id.to_i], w0, w1, w1 - w0]
end
missing_after = before["weights"].keys - after["weights"].keys
puts "lists ranked before but not after: #{missing_after.inspect}" if missing_after.any?
puts "| id | list | years | before | after | delta |"
puts "|---|---|---|---|---|---|"
rows.sort_by { |r| -r.last.abs }.first(30).each { |r| puts "| #{r.join(" | ")} |" }
deltas = rows.map(&:last)
puts "\nmoved up: #{deltas.count(&:positive?)}, moved down: #{deltas.count(&:negative?)}, unchanged: #{deltas.count(&:zero?)}; mean delta #{(deltas.sum.to_f / deltas.size).round(2)}"

puts "\n## Top 25 books, before -> after"
b = before["top_25"].map { |rank, item, _| [item, rank] }.to_h
after["top_25"].each do |rank, item, score|
  book = Books::Book.find(item)
  was = b[item] ? "was ##{b[item]}" : "new to top 25"
  puts "#{rank.to_s.rjust(2)}. #{book.title[0, 50].ljust(50)} #{was}"
end

puts "\n## Penalty catalogue on RC 8: #{before["penalty_names"].size} -> #{after["penalty_names"].size}"
puts "removed: #{(before["penalty_names"] - after["penalty_names"]).inspect}"
puts "added:   #{(after["penalty_names"] - before["penalty_names"]).inspect}"
```
Expected: a markdown report. Save its output to `$SCRATCH/report.md` as well (`> $SCRATCH/report.md`).

- [ ] **Step 8: Report to Shane and stop**

Present: the three migration result hashes, the catalogue checks, the persistence check result, the 30 biggest weight moves, the top-25 comparison, and the removed/added penalty names. State plainly that this ran against development only, that `tmp/db-snapshots/` holds the pre-run snapshot (`bin/snapshot-dev-db.sh --restore` reverts it), and that nothing has been pushed. Ask whether the ranking movement is what he expects before anything is scheduled for production.
