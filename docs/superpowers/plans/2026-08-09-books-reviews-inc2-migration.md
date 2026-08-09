# Books Reviews — Increment 2: Legacy Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all 128,969 legacy reviews into the `reviews` table built in increment 1, preserving ids and timestamps, then rebuild every `review_summaries` row from the loaded data.

**Architecture:** A read-only `LegacyBooks::Review` model plus `Services::BooksMigration::ReviewMigrator`, an `InsertOnlyMigrator` subclass that streams legacy rows newest-first, skips duplicate `(user_id, book_id)` pairs, and bulk-inserts with an **untargeted** `ON CONFLICT DO NOTHING`. A `data_migration:reviews` rake task runs the migrator then `Services::Reviews::SummaryRecalculator.backfill_all!`, because `insert_all` bypasses the `after_commit` that normally maintains summaries.

**Tech Stack:** Rails 8.1.3.1, PostgreSQL, Minitest + fixtures + Mocha, Standard (standardrb).

**Spec:** `docs/superpowers/specs/2026-08-09-books-reviews-design.md`
**Builds on:** increment 1 (merged as PR #213), which shipped `Review`, `ReviewSummary`, `Services::Reviews::BodySanitizer` and `Services::Reviews::SummaryRecalculator`.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Working branch is `worktree-books-reviews-inc2` in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-reviews-inc2`.
- Migration services live in `app/lib/services/books_migration/`; tests mirror at `test/lib/services/books_migration/`.
- Legacy read-only models live in `app/models/legacy_books/` and inherit `LegacyBooks::Record`.
- **Inside `Services::BooksMigration` a bare `Books::X` resolves to `Services::BooksMigration::Books::X`.** Root-anchor every reference: `::Books::Book`, `::Review`, `::ReviewSummary`. This has bitten this codebase three times and presents as a confusing `NameError`.
- Lint with `bundle exec standardrb`. **Not** `bin/rubocop`. Never run brakeman.
- **This increment adds no migration.** Do not create one; the schema shipped in increment 1.
- `Review::MAX_BODY_LENGTH` is **25,000**. The cap is applied **after** sanitizing, and an over-cap body is dropped to `nil` while the rating is kept — there is no user to show a validation error to.
- No test uses the legacy database. Every migrator test stubs `legacy_each`, per the existing pattern in `test/lib/services/books_migration/`.

## Legacy data shape (measured 2026-08-09, dev legacy DB)

| Metric | Value |
|---|---|
| Total legacy reviews | 128,969 |
| Duplicate `(user_id, book_id)` pairs | 123 (max 2 rows each, none with body text) |
| Rows expected after dedup | **128,846** |
| `body IS NULL` | 107,523 |
| Empty-string bodies | 5,177 |
| Bodies that sanitize to nothing (`<img>`-only) | 2 |
| Genuine text reviews after sanitizing | **16,267** |
| Bodies over 25,000 chars after sanitizing | 1 (review **101561**, a 462KB XSS-polyglot paste) |
| Rows with a title | 404 (longest 100 chars) |
| Distinct raters / books | 1,399 / 53,630 |
| Orphaned `user_id` / `book_id` | 0 / 0 |
| Rating distribution | 1:2,458 · 2:9,593 · 3:32,627 · 4:49,087 · 5:35,204 · null:0 |

All raters and books already exist in the new database with legacy ids preserved, verified against the new DB. No id remapping, no `LegacyIdMap`.

---

### Task 1: `LegacyBooks::Review` and `ReviewMigrator`

**Files:**
- Create: `web-app/app/models/legacy_books/review.rb`
- Create: `web-app/app/lib/services/books_migration/review_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/review_migrator_test.rb`

**Interfaces:**
- Consumes: `Services::Reviews::BodySanitizer.call(body) -> String | nil` (increment 1) — sanitizes to an allowlist, converts `<spoiler>` tags, and returns `nil` for nil, blank, or anything whose rendered text is blank. Never truncates. Also `Review::MAX_BODY_LENGTH == 25_000`.
- Produces: `Services::BooksMigration::ReviewMigrator.call -> {success: true, data: {model: "Review", count: Integer}}` on success, `{success: false, error: String, data: {...}}` on failure. Task 2 calls it from a rake task.

> **Landmine — `unique_by` MUST be `nil`, and this is verified, not theoretical.** Legacy ids are preserved, so a re-run collides on **two** unique constraints: `reviews_pkey` and `index_reviews_on_user_and_reviewable`. An arbiter naming only the natural key does **not** suppress the primary-key violation. Measured against this schema:
>
> | case | `unique_by: nil` | `unique_by: :index_reviews_on_user_and_reviewable` |
> |---|---|---|
> | identical row re-run | 0 inserted, no error | — |
> | same natural key, different id | 0 inserted | — |
> | same id, different natural key | 0 inserted | — |
> | PK collision | absorbed | **raises `PG::UniqueViolation` on `reviews_pkey`**, aborting the batch |
>
> `InsertOnlyMigrator#flush` passes `unique_by` straight through to `insert_all`, and `nil` yields an untargeted `ON CONFLICT DO NOTHING` that absorbs a conflict on *any* constraint. That is what idempotency requires here.

> **Dedup deviates from the spec, deliberately.** The spec proposes pre-filtering with `DISTINCT ON (user_id, book_id) … ORDER BY id DESC` in SQL. That works, but it lives in the legacy query — and every migrator test in this codebase stubs `legacy_each`, so a SQL-level filter would be **completely untestable**. Instead: read newest-first with `find_each(order: :desc)` (verified working on Rails 8.1.3.1) and skip natural keys already emitted using a `Set`. Same outcome — the newer row wins — and a stubbed-`legacy_each` test can prove it. This mirrors `ListPenaltyMigrator`'s existing `@seen` pattern.

> **Do not rely on `ON CONFLICT DO NOTHING` to do the dedup.** It would silently keep whichever row Postgres happens to insert first within the batch, which is an ordering detail rather than a stated rule. The 41 duplicate pairs whose two rows disagree on rating would resolve arbitrarily.

- [ ] **Step 1: Create the legacy model**

Create `web-app/app/models/legacy_books/review.rb`:

```ruby
# == Schema Information
#
# Table name: reviews
#
#  id         :bigint           not null, primary key
#  body       :string
#  rating     :integer
#  title      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  book_id    :bigint           not null
#  user_id    :bigint           not null
#
module LegacyBooks
  class Review < Record
    self.table_name = "reviews"
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `web-app/test/lib/services/books_migration/review_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::ReviewMigratorTest < ActiveSupport::TestCase
  # Rows are yielded NEWEST FIRST, matching find_each(order: :desc) in the real
  # legacy_each. Order is load-bearing for the dedup rule.
  def run_migrator(rows)
    m = Services::BooksMigration::ReviewMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy reviews row as the migrator yields it: String keys.
  def legacy_review(id, overrides = {})
    {
      "id" => id,
      "user_id" => users(:regular_user).id,
      "book_id" => books_books(:got).id,
      "title" => nil,
      "body" => nil,
      "rating" => 4,
      "created_at" => Time.utc(2025, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2025, 6, 7, 8, 9, 10)
    }.merge(overrides)
  end

  setup do
    # reviews.yml ships four fixture rows; clear them so counts in this file are
    # about the migrator's own output. Test-transactional, rolled back after each test.
    ::Review.delete_all
    ::ReviewSummary.delete_all
  end

  test "preserves the legacy id, ids, rating and timestamps" do
    result = run_migrator([legacy_review(900_001, "rating" => 5)])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]

    review = ::Review.find(900_001)
    assert_equal users(:regular_user).id, review.user_id
    assert_equal "Books::Book", review.reviewable_type
    assert_equal books_books(:got).id, review.reviewable_id
    assert_equal 5, review.rating
    assert_equal Time.utc(2025, 1, 2, 3, 4, 5), review.created_at
    assert_equal Time.utc(2025, 6, 7, 8, 9, 10), review.updated_at
  end

  test "sanitizes the body" do
    run_migrator([legacy_review(900_001, "body" => "good <script>alert('xss')</script>")])

    body = ::Review.find(900_001).body
    assert_not_includes body, "<script"
    assert_includes body, "good"
  end

  test "normalizes an empty-string body to nil" do
    run_migrator([legacy_review(900_001, "body" => "")])
    assert_nil ::Review.find(900_001).body
  end

  test "normalizes a whitespace-only body to nil" do
    run_migrator([legacy_review(900_001, "body" => "   \n\t ")])
    assert_nil ::Review.find(900_001).body
  end

  test "normalizes an image-only body to nil" do
    run_migrator([legacy_review(900_001, "body" => %(<img src="https://x.test/a.png">))])
    assert_nil ::Review.find(900_001).body
  end

  test "drops a body that exceeds MAX_BODY_LENGTH after sanitizing, keeping the rating" do
    oversized = "<p>#{"a" * (::Review::MAX_BODY_LENGTH + 100)}</p>"
    run_migrator([legacy_review(900_001, "body" => oversized, "rating" => 3)])

    review = ::Review.find(900_001)
    assert_nil review.body
    assert_equal 3, review.rating
  end

  test "keeps a body exactly at MAX_BODY_LENGTH" do
    exact = "a" * ::Review::MAX_BODY_LENGTH
    run_migrator([legacy_review(900_001, "body" => exact)])

    assert_equal ::Review::MAX_BODY_LENGTH, ::Review.find(900_001).body.length
  end

  test "normalizes a blank title to nil and strips a real one" do
    run_migrator([
      legacy_review(900_001, "title" => "   "),
      legacy_review(900_002, "title" => "  A great read  ", "book_id" => books_books(:war_and_peace).id)
    ])

    assert_nil ::Review.find(900_001).title
    assert_equal "A great read", ::Review.find(900_002).title
  end

  test "keeps the newer row when a user reviewed the same book twice" do
    # Yielded newest-first, as find_each(order: :desc) does.
    result = run_migrator([
      legacy_review(900_002, "rating" => 2),
      legacy_review(900_001, "rating" => 5)
    ])

    assert_equal 1, result[:data][:count]
    assert_equal 2, ::Review.find(900_002).rating
    assert_not ::Review.exists?(900_001)
  end

  test "keeps both rows when the same user reviews different books" do
    result = run_migrator([
      legacy_review(900_002, "book_id" => books_books(:war_and_peace).id),
      legacy_review(900_001)
    ])

    assert_equal 2, result[:data][:count]
  end

  test "is idempotent across runs" do
    rows = [legacy_review(900_001), legacy_review(900_002, "book_id" => books_books(:war_and_peace).id)]

    assert_equal 2, run_migrator(rows)[:data][:count]
    assert_equal 0, run_migrator(rows)[:data][:count]
    assert_equal 2, ::Review.count
  end

  test "fails loudly when the legacy book was never migrated" do
    result = run_migrator([legacy_review(900_001, "book_id" => 999_999_999)])

    assert_not result[:success]
    assert_includes result[:error], "999999999"
  end

  test "does not maintain review_summaries" do
    run_migrator([legacy_review(900_001)])

    assert_equal 0, ::ReviewSummary.count,
      "insert_all bypasses after_commit by design; the rake task calls backfill_all!"
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::ReviewMigrator`

- [ ] **Step 4: Write the migrator**

Create `web-app/app/lib/services/books_migration/review_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `reviews` -> the global polymorphic `reviews` table (reviewable =
    # ::Books::Book, which preserves its legacy id, so no LegacyIdMap lookup is needed).
    # Legacy review ids and timestamps are preserved too.
    #
    # unique_by is nil ON PURPOSE. Preserved ids mean a re-run collides on BOTH
    # reviews_pkey and index_reviews_on_user_and_reviewable, and an arbiter naming only
    # one of them lets the other raise and abort the batch. Untargeted
    # ON CONFLICT DO NOTHING absorbs either.
    #
    # Dedup is done here in Ruby rather than with DISTINCT ON in the legacy query: every
    # migrator test stubs legacy_each, so a SQL-level filter could not be tested at all.
    # Rows arrive newest-first and @seen keeps the first occurrence of each natural key,
    # which is the newer row. 123 legacy pairs are affected; none has body text on either
    # side, and 41 disagree on rating, so "newer wins" has to be a stated rule rather
    # than whatever ON CONFLICT happens to keep.
    #
    # insert_all bypasses Review's before_validation AND its after_commit, so the body is
    # sanitized explicitly here and review_summaries is rebuilt afterwards by
    # SummaryRecalculator.backfill_all! (see the data_migration:reviews rake task).
    class ReviewMigrator < InsertOnlyMigrator
      private

      def legacy_model
        LegacyBooks::Review
      end

      def model_key
        "Review"
      end

      def target_model
        ::Review
      end

      # See the class comment. Not a mistake, not an omission.
      def unique_by
        nil
      end

      # Legacy created_at/updated_at are supplied in build_rows and must survive.
      def record_timestamps?
        false
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @seen = Set.new
      end

      # Newest-first so the dedup below keeps the newer of a duplicated pair.
      def legacy_each(&block)
        legacy_model.find_each(batch_size: BATCH_SIZE, order: :desc) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated ::Books::Book for legacy reviews.book_id=#{book_id.inspect}"
        end

        # First occurrence wins, and rows arrive newest-first.
        return [] unless @seen.add?([attrs["user_id"], book_id])

        [{
          id: attrs["id"],
          user_id: attrs["user_id"],
          reviewable_type: "Books::Book",
          reviewable_id: book_id,
          title: attrs["title"]&.strip.presence,
          body: body_for(attrs),
          rating: attrs["rating"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      # The cap runs AFTER sanitizing: <script> contents survive sanitizing as visible
      # text, so the 462KB fuzz paste is only over-length once cleaned. One legacy row
      # (101561) is affected; it imports as rating-only.
      def body_for(attrs)
        body = Services::Reviews::BodySanitizer.call(attrs["body"])
        return nil if body.nil?

        if body.length > ::Review::MAX_BODY_LENGTH
          Rails.logger.warn(
            "ReviewMigrator: dropped body of legacy review id=#{attrs["id"]} " \
            "(#{body.length} chars after sanitizing, cap #{::Review::MAX_BODY_LENGTH})"
          )
          return nil
        end

        body
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_test.rb`
Expected: PASS, 13 runs, 0 failures

- [ ] **Step 6: Run the full suite**

Run: `bin/rails test`
Expected: PASS. The `setup` block's `Review.delete_all` is transactional and must not leak into other files.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/models/legacy_books/review.rb app/lib/services/books_migration/review_migrator.rb test/lib/services/books_migration/review_migrator_test.rb
git add web-app/app/models/legacy_books/review.rb web-app/app/lib/services/books_migration/review_migrator.rb web-app/test/lib/services/books_migration/review_migrator_test.rb
git commit -m "Add ReviewMigrator for the legacy reviews table"
```

---

### Task 2: Sequence reset and the `data_migration:reviews` rake task

**Files:**
- Modify: `web-app/app/lib/services/books_migration/review_migrator.rb` — add `finalize`
- Modify: `web-app/lib/tasks/data_migration.rake` — add the `reviews` task and extend `all`
- Test: `web-app/test/lib/services/books_migration/review_migrator_test.rb` — add the finalize test

**Interfaces:**
- Consumes: `Services::BooksMigration::ReviewMigrator.call` (Task 1); `Services::Reviews::SummaryRecalculator.backfill_all! -> Integer` (increment 1), which rebuilds every summary row from the reviews table and returns the resulting row count.
- Produces: `rake data_migration:reviews`, which Task 3 runs against development.

> **Why the sequence reset matters.** `insert_all` with explicit ids does not advance the `reviews_id_seq`. Without a reset, the first review a real user writes after the migration gets id 1 and collides with a migrated row — a `PG::UniqueViolation` on `reviews_pkey` in production, on the very first write. `reset_pk_sequence!` is the idiom already used by `SavedSearchMigrator` and `CountryMigrator`.

- [ ] **Step 1: Write the failing test**

Append inside the class in `web-app/test/lib/services/books_migration/review_migrator_test.rb`:

```ruby
  test "advances the id sequence past the migrated ids" do
    run_migrator([legacy_review(900_001)])

    # Without the reset this would return 1 and collide with the migrated row.
    next_id = ::Review.connection.select_value("SELECT nextval('reviews_id_seq')").to_i
    assert_operator next_id, :>, 900_001
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_test.rb -n "/advances the id sequence/"`
Expected: FAIL — `nextval` returns a small number, not greater than 900,001.

- [ ] **Step 3: Add `finalize` to the migrator**

In `web-app/app/lib/services/books_migration/review_migrator.rb`, add below `preload_context`:

```ruby
      # insert_all with explicit ids never advances the sequence, so without this the
      # first review a real user writes gets id 1 and collides with a migrated row.
      # finalize runs outside without_search_indexing, so keep it callback-free.
      def finalize
        target_model.connection.reset_pk_sequence!("reviews")
      end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_test.rb`
Expected: PASS, 14 runs, 0 failures

- [ ] **Step 5: Add the rake task**

In `web-app/lib/tasks/data_migration.rake`, add immediately before the `desc "Run all Phase-1 migrators in dependency order"` line:

```ruby
  desc "Migrate legacy reviews into reviews (preserves ids; then rebuilds review_summaries)"
  task reviews: :environment do
    result = Services::BooksMigration::ReviewMigrator.call
    pp result
    abort "reviews migration failed: #{result[:error]}" unless result[:success]

    # insert_all bypassed every after_commit, so the summaries are stale by definition.
    pp({review_summaries: Services::Reviews::SummaryRecalculator.backfill_all!})
  end
```

Then add `:reviews` to the end of the `all` task's dependency list, so it reads:

```ruby
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers,
    :categories, :category_items, :book_attributes, :book_type_categories, :countries,
    :book_countries, :external_links, :lists, :list_items, :ranking_configurations,
    :ranked_lists, :penalties, :list_penalties, :user_lists, :user_list_items,
    :saved_searches, :reviews]
```

- [ ] **Step 6: Verify the task is wired up**

Run: `bin/rails -T data_migration:reviews`
Expected: the task is listed with its description. **Do not run it yet** — Task 3 runs it, after a snapshot.

- [ ] **Step 7: Run the full suite, lint and commit**

```bash
bin/rails test
bundle exec standardrb app/lib/services/books_migration/review_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/review_migrator_test.rb
git add web-app/app/lib/services/books_migration/review_migrator.rb web-app/lib/tasks/data_migration.rake web-app/test/lib/services/books_migration/review_migrator_test.rb
git commit -m "Add the data_migration:reviews rake task and reset the id sequence"
```

---

### Task 3: Run against development and verify

**Files:**
- Create: `web-app/lib/tasks/verify_reviews_migration.rake` — a throwaway verification task, deleted in the final step
- Modify: `docs/superpowers/plans/2026-08-09-books-reviews-inc2-migration.md` — record the measured results

**Interfaces:**
- Consumes: `rake data_migration:reviews` (Task 2).
- Produces: measured row counts confirming the migration, recorded in this plan.

> **Snapshot first. This is not optional.** The books data exists only in development and takes hours to rebuild. `reviews` and `review_summaries` are empty, so the blast radius is those two tables — but snapshot anyway, because a mistake in a rake task is not always confined to the table you intended.

> **Development only.** Production is a separate manual run by the owner after merge, exactly as the saved-searches and descriptions migrations were done. Do not attempt it.

- [ ] **Step 1: Snapshot the development database**

```bash
COMPOSE_PROJECT_NAME=the-greatest bin/snapshot-dev-db.sh --label pre-reviews-migration
```

(The `COMPOSE_PROJECT_NAME` prefix is required from a worktree — the worktree's directory name would otherwise become its own Compose project, which does not own the running dev Postgres container.)

- [ ] **Step 2: Confirm the starting state is empty**

```bash
bin/rails runner 'puts "reviews=#{Review.count} review_summaries=#{ReviewSummary.count}"'
```

Expected: `reviews=0 review_summaries=0`. If either is non-zero, STOP and report — the migration has already been run and re-running proves nothing about a cold load.

- [ ] **Step 3: Run the migration**

```bash
time bin/rails data_migration:reviews
```

Expected: `{success: true, data: {model: "Review", count: 128846}}` followed by `{review_summaries: 53630}`.

- [ ] **Step 4: Write the verification task**

Create `web-app/lib/tasks/verify_reviews_migration.rake`:

```ruby
namespace :verify do
  desc "Verify the reviews migration against the measured legacy expectations"
  task reviews: :environment do
    legacy = LegacyBooks::Record.connection

    checks = {
      "rows after dedup" => [Review.count, 128_846],
      "all rows are books" => [Review.where(reviewable_type: "Books::Book").count, 128_846],
      "text reviews" => [Review.with_body.count, 16_267],
      "ratings out of range" => [Review.where.not(rating: 1..5).count, 0],
      "null ratings" => [Review.where(rating: nil).count, 0],
      "bodies over the cap" => [Review.where("length(body) > ?", Review::MAX_BODY_LENGTH).count, 0],
      "empty-string bodies" => [Review.where(body: "").count, 0],
      "distinct books" => [Review.distinct.count(:reviewable_id), 53_630],
      "distinct raters" => [Review.distinct.count(:user_id), 1_399],
      "summary rows" => [ReviewSummary.count, 53_630],
      "legacy rows minus dupes" => [
        legacy.select_value("select count(*) from reviews").to_i - 123, 128_846
      ]
    }

    failures = checks.reject { |_, (actual, expected)| actual == expected }
    checks.each { |name, (a, e)| puts format("  %-26s %8d  expected %8d  %s", name, a, e, (a == e) ? "OK" : "MISMATCH") }

    puts "\nRating distribution (expect 1:2458 2:9593 3:32627 4:49087 5:35204 minus dupes):"
    pp Review.group(:rating).count.sort.to_h

    puts "\nThe 462KB fuzz row (101561) imports as rating-only:"
    fuzz = Review.find_by(id: 101_561)
    puts "  present=#{!fuzz.nil?} body_nil=#{fuzz&.body.nil?} rating=#{fuzz&.rating.inspect}"

    puts "\nSummary totals agree with the reviews table:"
    puts "  sum(ratings_count)=#{ReviewSummary.sum(:ratings_count)} (expect #{Review.count})"
    puts "  sum(text_reviews_count)=#{ReviewSummary.sum(:text_reviews_count)} (expect #{Review.with_body.count})"
    puts "  sum(ratings_sum)=#{ReviewSummary.sum(:ratings_sum)} (expect #{Review.sum(:rating)})"

    abort "\n#{failures.size} check(s) MISMATCHED" if failures.any?
    puts "\nAll checks OK"
  end
end
```

- [ ] **Step 5: Run the verification**

```bash
bin/rails verify:reviews
```

Expected: every check `OK`, the fuzz row present with `body_nil=true`, and all three summary totals matching. If any check mismatches, STOP and report the numbers rather than adjusting the expectations to fit.

- [ ] **Step 6: Prove idempotency**

```bash
bin/rails data_migration:reviews
bin/rails verify:reviews
```

Expected: the second migrator run reports `count: 0`, `backfill_all!` returns `53630` again, and every check still passes. A non-zero count on the second run means the untargeted `ON CONFLICT` is not doing its job.

- [ ] **Step 7: Record the results in this plan**

Replace the "Measured results" placeholder section at the bottom of this file with the actual numbers from Steps 3, 5 and 6, including the wall-clock time from Step 3.

- [ ] **Step 8: Delete the verification task and commit**

The verification task is scaffolding for this increment, not something to carry in the repo:

```bash
rm web-app/lib/tasks/verify_reviews_migration.rake
bundle exec standardrb
bin/rails test
git add -A
git commit -m "Record the measured results of the development reviews migration"
```

---

## Measured results

Filled in by Task 3, Step 7. Until then this section reads "not yet run".

- Migrator: not yet run
- Backfill: not yet run
- Wall clock: not yet run
- Idempotent re-run: not yet run

## Definition of Done

- [ ] `bin/rails test` passes with no failures
- [ ] `bundle exec standardrb` reports no offenses
- [ ] `bin/rails verify:reviews` passed on a cold load, and again after a re-run
- [ ] The development snapshot from Task 3 Step 1 still exists
- [ ] `lib/tasks/verify_reviews_migration.rake` is deleted

## Carried forward

- **Production run.** A separate manual step for the owner after merge, matching how saved searches and descriptions were done. Production's legacy DB is larger than development, so the absolute numbers above will not match — verify the *invariants* (zero out-of-range ratings, zero empty-string bodies, summary totals equal to the reviews table) rather than the counts.
- **Increment 3** — book page read surface: summary line, histogram, paginated text reviews. `title` is NOT sanitized (only `body` is), so it must never be rendered with `raw` or `html_safe`. `by_rating` and `recent` carry an `id` tiebreaker, so paging over them is stable.
- The deferred findings from increment 1 remain open; see `2026-08-09-books-reviews-inc1-schema-and-core.md`.
