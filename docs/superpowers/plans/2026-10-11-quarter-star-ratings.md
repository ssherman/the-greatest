# Quarter-Star Ratings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reviews take fractional star ratings (entered in quarter steps, the way Goodreads does), and the Goodreads import carries them across exactly, including repairing ratings the legacy site truncated.

**Architecture:** `reviews.rating` becomes `decimal(3,2)`, `0 < rating <= 5`. Two class methods on `Review` own the shared rules: `rating_bucket` (Goodreads' five-bar rounding) and `format_rating` (display text). Every bucketed or printed rating goes through them. The star display fills each star separately. A new Stimulus controller, `reviews--star-input`, turns pointer and key events into a quarter-step value inside the existing review dialog.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest + fixtures + Mocha, ViewComponent, Stimulus (Rollup IIFE bundles), Tailwind 4 / daisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-10-quarter-star-ratings-design.md`

## Global Constraints

- **Working directory:** run all Rails and yarn commands from `web-app/` inside the worktree `/home/shane/dev/the-greatest/.claude/worktrees/quarter-star-ratings`.
- **Storage:** `decimal(3,2)`, `rating > 0 AND rating <= 5`. **No quarter-step constraint.** `0` is never stored on a review (Goodreads uses 0 for "not rated").
- **Breakdown bars:** five bars. Round to the nearest whole star, ties round **down**, floor 1. SQL: `GREATEST(1, CEIL(rating - 0.5))`.
- **Display text:** drop trailing zeros (`4`, `3.5`, `3.75`). Never interpolate a raw `BigDecimal`, which prints as `0.375e1`. Averages keep one decimal place.
- **JSON:** sends ratings as numbers (`rating&.to_f`), never Rails' decimal strings.
- **Rating input:** quarter steps from 0.25 to 5. Mouse hover previews and click commits. Touch: the touch point sets the value and dragging adjusts it. Keys: arrows ±0.25, PageUp/PageDown ±1, Home/End 0.25/5.
- **Recommendation thresholds:** values unchanged, compared against the exact decimal.
- **Legacy repair** fires only when all four §5.4 conditions hold.
- **Linting:** `bundle exec standardrb` (not `bin/rubocop`). Do not run brakeman.
- **Minitest 6:** use `assert_nil`, never `assert_equal nil, x`.
- **Tests:** never assert copy or CSS in controller tests. Use `data-testid` (kebab-case) only where role, text or label cannot target the element.
- **Removed daisyUI v4 classes** (`form-control`, `label-text`, `input-bordered`, ...) must not appear.
- **Never commit to `main`.** All commits go on `worktree-quarter-star-ratings`.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A raw decimal reaches the page.** Any surface that interpolates `review.rating` prints `0.375e1` once the column is decimal. The expected result is `3.75` everywhere. Task 3 adds a `3.75` render test to every surface that prints a rating: review card, widget, My Reviews row `data-rating`, admin index/show and the wizard row.
2. **A stale hover preview.** Moving off the stars, or reopening the dialog for a different book, must show the committed value, not the last hover. Task 8's E2E covers both.
3. **Server and JS paths disagree after hydration.** The cached book page fills the widget in JS. A saved 3.75 must look identical after a reload (JS path) and straight after saving (server Turbo Stream path). Task 8's E2E checks the fourth star at 75% on both paths.
4. **A current-format file end to end.** The new header (no `Average Rating`) with `4.0`, `3.75` and `0` must flow file → `ExportFile` → `ParseRows` → import rows → reviews. Task 5 adds a `ParseRows` test reading the real-shaped fixture file.
5. **The repair against the weekly sync.** The sync overwrites the repaired rating back to the truncated value, so the next replay has to fix it again, and a second replay must change nothing. Task 6 tests repair → simulated sync revert → repair → no-op.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `db/migrate/<ts>_allow_fractional_review_ratings.rb` (create) | Column types and the `reviews_rating_range` constraint | 1 |
| `app/models/review.rb` | Validation, `RATING_BUCKET_SQL`, `rating_bucket`, `format_rating`, `#formatted_rating` | 1 |
| `app/models/books/goodreads_import_row.rb` | Decimal rating validation | 1 |
| `app/lib/services/reviews/summary_recalculator.rb` | Bucketed counts | 2 |
| `app/lib/reviews/my_reviews_query.rb`, `app/lib/reviews/my_reviews_stats.rb` | Bucket filter, bucket counts, true average | 2 |
| `app/components/reviews/stars_component.{rb,html.erb}` | Per-star fill, exact vs average label | 3 |
| `app/javascript/controllers/reviews/star_rating.js` (create) | Shared JS `starFills` / `formatRating` | 3 |
| `app/javascript/controllers/reviews/widget_controller.js` | Per-star hydration | 3 |
| `review_component.rb`, `widget_component.rb`, `my/row_component.html.erb`, admin views, `_step_3.html.erb`, `review_state_controller.rb` | Formatted text and numeric JSON | 3 |
| `app/javascript/controllers/reviews/star_input_controller.js` (create) | Pointer/key → value | 4 |
| `app/components/reviews/modal_component.{rb,html.erb}`, `modal_controller.js`, `manifests/web_shared.js` | Host the control | 4 |
| `app/lib/books/goodreads/export_row.rb` | Decimal `My Rating` | 5 |
| `app/lib/services/books/goodreads_imports/write_library.rb` | `positive?` fix (Task 5), legacy repair (Task 6) | 5, 6 |
| `test/fixtures/files/goodreads/quarter_star_export.csv` (create) | Current-format export | 5 |
| `app/lib/recommendations/books/positive_pairs.rb`, `adapter.rb` | Decimal threshold, float rating | 7 |
| `e2e/helpers/star-rating.ts` (create), `e2e/tests/books/**`, `lib/tasks/e2e.rake` | E2E | 8 |
| `docs/features/goodreads-import.md`, `docs/features/recommendations.md` | Docs | 8 |

---

### Task 1: Decimal ratings in the schema and the shared rating rules

**Files:**
- Create: `web-app/db/migrate/<timestamp>_allow_fractional_review_ratings.rb`
- Modify: `web-app/app/models/review.rb` (validation near line 22; add constants and methods)
- Modify: `web-app/app/models/books/goodreads_import_row.rb:61`
- Test: `web-app/test/models/review_test.rb`, `web-app/test/models/books/goodreads_import_row_test.rb`

**Interfaces:**
- Produces:
  - `Review::RATING_BUCKET_SQL` (String): `"GREATEST(1, CEIL(reviews.rating - 0.5))::integer"`
  - `Review.rating_bucket(value) -> Integer (1..5) | nil`
  - `Review.format_rating(value) -> String | nil`
  - `Review#formatted_rating -> String | nil`
  - `reviews.rating`, `books_goodreads_import_rows.rating`: `BigDecimal`
  - `review_summaries.ratings_sum`: `BigDecimal`

- [ ] **Step 1: Write the failing tests** in `test/models/review_test.rb`, inside the existing class. Keep the existing "rejects a rating below 1" test but rename it and change its value, as below.

```ruby
  test "rejects a rating of zero" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 0)
    assert_not review.valid?
  end

  test "accepts quarter, half and arbitrary two-place ratings" do
    [0.25, 3.5, 3.75, 3.33, 5].each do |value|
      review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: value)
      assert review.valid?, "expected #{value} to be valid: #{review.errors.full_messages}"
    end
  end

  test "rejects a rating above five even by a hundredth" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 5.01)
    assert_not review.valid?
  end

  test "stores a fractional rating exactly and rounds to two places" do
    review = Review.create!(user: users(:regular_user), reviewable: books_books(:got), rating: "3.333")
    assert_equal BigDecimal("3.33"), review.reload.rating
  end

  test "the database rejects zero and above five" do
    review = Review.create!(user: users(:contractor_user), reviewable: books_books(:got), rating: 4)
    assert_raises(ActiveRecord::StatementInvalid) { review.update_columns(rating: 0) }
  end

  test "the database rejects a rating above five" do
    review = Review.create!(user: users(:contractor_user), reviewable: books_books(:got), rating: 4)
    assert_raises(ActiveRecord::StatementInvalid) { review.update_columns(rating: 5.01) }
  end

  test "the database accepts a quarter rating" do
    review = Review.create!(user: users(:contractor_user), reviewable: books_books(:got), rating: 4)
    review.update_columns(rating: 0.25)
    assert_equal BigDecimal("0.25"), review.reload.rating
  end

  test "rating_bucket follows Goodreads: ties round down, floor of one" do
    expected = {0.25 => 1, 1.5 => 1, 1.75 => 2, 2.4 => 2, 2.5 => 2, 2.6 => 3, 2.75 => 3, 4.5 => 4, 4.75 => 5, 5 => 5}
    expected.each { |value, bucket| assert_equal bucket, Review.rating_bucket(BigDecimal(value.to_s)), "bucket for #{value}" }
    assert_nil Review.rating_bucket(nil)
  end

  test "RATING_BUCKET_SQL agrees with rating_bucket" do
    book = books_books(:got)
    users = [users(:regular_user), users(:admin_user), users(:editor_user), users(:contractor_user)]
    values = %w[1.5 1.75 2.5 2.75]
    users.zip(values).each { |user, value| Review.create!(user: user, reviewable: book, rating: value) }

    from_sql = Review.where(reviewable: book).order(:rating).pluck(Arel.sql(Review::RATING_BUCKET_SQL))
    assert_equal values.map { |v| Review.rating_bucket(BigDecimal(v)) }, from_sql
  end

  test "format_rating drops trailing zeros and never uses exponent notation" do
    assert_equal "4", Review.format_rating(BigDecimal("4"))
    assert_equal "4", Review.format_rating(BigDecimal("4.00"))
    assert_equal "3.5", Review.format_rating(BigDecimal("3.50"))
    assert_equal "3.75", Review.format_rating(BigDecimal("3.75"))
    assert_equal "0.25", Review.format_rating(BigDecimal("0.25"))
    assert_equal "10", Review.format_rating(10)
    assert_equal "4", Review.format_rating(4)
    assert_nil Review.format_rating(nil)
  end

  test "formatted_rating formats the review's own rating" do
    assert_equal "3.75", Review.new(rating: "3.75").formatted_rating
    assert_nil Review.new(rating: nil).formatted_rating
  end
```

In `test/models/books/goodreads_import_row_test.rb`, add the following. If the file has no import or row helper, build them as the existing tests do. Check the top of the file first.

```ruby
      test "a fractional rating is valid, zero means unrated, above five is not" do
        import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :parsing)
        assert import.rows.new(row_number: 1, rating: "3.75").valid?
        assert import.rows.new(row_number: 2, rating: 0).valid?
        assert_not import.rows.new(row_number: 3, rating: "5.5").valid?
        assert_not import.rows.new(row_number: 4, rating: "-1").valid?
      end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bin/rails test test/models/review_test.rb test/models/books/goodreads_import_row_test.rb`
Expected: FAIL. The fractional ratings fail `only_integer`, `rating_bucket` and `format_rating` are undefined, and the database rejects 0.25.

- [ ] **Step 3: Generate and write the migration**

Run: `bin/rails generate migration AllowFractionalReviewRatings`. Then replace the body:

```ruby
class AllowFractionalReviewRatings < ActiveRecord::Migration[8.1]
  # Goodreads rates in quarter stars since 2026-10-05, and its export writes
  # "3.75" (and "4.0" for a whole star). Every existing rating is an integer
  # 1..5, which satisfies the new range, so nothing is rewritten beyond the
  # type change. Only books has reviews, and books has not launched.
  #
  # No quarter-step constraint on purpose: the five-bar rounding and the star
  # display work for any decimal, so a stray 3.3 from an import is just 3.3.
  def up
    remove_check_constraint :reviews, name: "reviews_rating_range"
    change_column :reviews, :rating, :decimal, precision: 3, scale: 2
    add_check_constraint :reviews, "rating > 0 AND rating <= 5", name: "reviews_rating_range"

    change_column :review_summaries, :ratings_sum, :decimal, precision: 10, scale: 2, default: 0, null: false
    change_column :books_goodreads_import_rows, :rating, :decimal, precision: 3, scale: 2
  end

  # Refuses rather than truncating: a fractional rating cast back to integer
  # would silently lose what the reader entered.
  def down
    fractional = select_value("SELECT COUNT(*) FROM reviews WHERE rating <> TRUNC(rating)").to_i +
      select_value("SELECT COUNT(*) FROM books_goodreads_import_rows WHERE rating <> TRUNC(rating)").to_i
    raise ActiveRecord::IrreversibleMigration, "#{fractional} fractional ratings would be truncated" if fractional.positive?

    remove_check_constraint :reviews, name: "reviews_rating_range"
    change_column :reviews, :rating, :integer
    add_check_constraint :reviews, "rating >= 1 AND rating <= 5", name: "reviews_rating_range"

    change_column :review_summaries, :ratings_sum, :integer, default: 0, null: false
    change_column :books_goodreads_import_rows, :rating, :integer
  end
end
```

Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `db/schema.rb` shows `t.decimal "rating", precision: 3, scale: 2` on `reviews` and `books_goodreads_import_rows`, `ratings_sum` as decimal(10,2), and `check_constraint "(rating > (0)::numeric) AND (rating <= (5)::numeric)"` or similar. This migrates the development database. The change is additive and reversible, and existing rows already satisfy it.

- [ ] **Step 4: Update the models**

In `app/models/review.rb`, replace the rating validation:

```ruby
  # Optional: Goodreads, and so an import, allows a written review with no stars.
  # rating_or_body_present is what stops an empty review. Fractional since
  # Goodreads went to quarter stars; 0 is Goodreads' "not rated", never a rating.
  validates :rating, numericality: {greater_than: 0, less_than_or_equal_to: 5}, allow_nil: true
```

Below `MAX_TITLE_LENGTH`, add:

```ruby
  # Goodreads' five-bar rule: round to the nearest whole star, ties round down,
  # and everything up to 1.5 is a 1. Integer-cast so grouped counts key on
  # Integers. Every bucketed consumer (summaries, the My Reviews filter and
  # stats) uses this or rating_bucket, never its own rounding.
  RATING_BUCKET_SQL = "GREATEST(1, CEIL(reviews.rating - 0.5))::integer"

  def self.rating_bucket(value)
    return nil if value.nil?

    [1, (value.to_d - BigDecimal("0.5")).ceil].max
  end

  # The one way a rating becomes text. BigDecimal#to_s is "0.375e1", so a raw
  # interpolation is a bug, not a style choice.
  def self.format_rating(value)
    return nil if value.nil?

    text = value.to_d.round(2).to_s("F")
    text.sub(/0+\z/, "").sub(/\.\z/, "")
  end
```

Below `after_commit`, before `private`, add:

```ruby
  def formatted_rating
    self.class.format_rating(rating)
  end
```

Note that `"10.0".sub(/0+\z/, "")` gives `"10."`, and then `.sub(/\.\z/, "")` gives `"10"`. That is correct. `to_s("F")` always includes a decimal point, so the first `sub` only strips fractional zeros.

In `app/models/books/goodreads_import_row.rb:61`, replace the inclusion validation:

```ruby
    # 0 is Goodreads' "not rated"; anything else is a (possibly fractional) rating.
    validates :rating, numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 5}, allow_nil: true
```

- [ ] **Step 5: Run the model tests**

Run: `bin/rails test test/models/review_test.rb test/models/books/goodreads_import_row_test.rb test/models/review_summary_test.rb`
Expected: PASS. If an existing test asserts `assert_equal 4, review.rating`, it still passes, because `BigDecimal("4") == 4`.

- [ ] **Step 6: Run the whole suite to find integer assumptions**

Run: `bin/rails test`
Expected: failures, if any, are only in places later tasks change: summary buckets (Task 2), labels (Task 3), import parsing (Task 5). Note them, then move on. If anything else fails, fix it in this task.

- [ ] **Step 7: Commit**

```bash
git add web-app/db/migrate web-app/db/schema.rb web-app/app/models/review.rb web-app/app/models/books/goodreads_import_row.rb web-app/app/models/books/goodreads_import.rb web-app/test/models
git commit -m "Reviews: store fractional ratings; shared bucket and format rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(annotaterb may have rewritten model annotations, so add whichever model files changed.)

---

### Task 2: Count ratings into Goodreads' five buckets

**Files:**
- Modify: `web-app/app/lib/services/reviews/summary_recalculator.rb` (`AGGREGATES`)
- Modify: `web-app/app/lib/reviews/my_reviews_query.rb:31` (filter)
- Modify: `web-app/app/lib/reviews/my_reviews_stats.rb` (`average`, `raw_counts`)
- Test: `web-app/test/lib/services/reviews/summary_recalculator_test.rb`, `web-app/test/lib/reviews/my_reviews_query_test.rb`, `web-app/test/lib/reviews/my_reviews_stats_test.rb`

**Interfaces:**
- Consumes: `Review::RATING_BUCKET_SQL` (Task 1)
- Produces: `ReviewSummary#rating_counts` keys 1..5 now hold bucketed counts; `MyReviewsStats#average` is the true mean (Float, one decimal)

- [ ] **Step 1: Write the failing tests**

In `summary_recalculator_test.rb`:

```ruby
      test ".recalculate buckets fractional ratings by Goodreads' rule and sums exactly" do
        [[users(:regular_user), "1.5"], [users(:admin_user), "1.75"], [users(:editor_user), "2.5"],
          [users(:contractor_user), "4.75"]].each do |user, rating|
          Review.create!(user: user, reviewable: @book, rating: rating)
        end

        recalculate(@book)
        summary = summary_for(@book)

        assert_equal [1, 2, 0, 0, 1], summary.rating_counts.values
        assert_equal BigDecimal("10.5"), summary.ratings_sum
        assert_in_delta 2.625, summary.average_rating, 0.0001
      end
```

In `my_reviews_query_test.rb` (check the file's setup for its user and helpers first, and reuse them):

```ruby
    test "the rating filter is a bucket: 4 holds 3.75 through 4.5, not 3.5 or 4.75" do
      user = User.create!(email: "buckets@example.com", role: :user, email_verified: false)
      books = %i[got war_and_peace clash crime_and_punishment].map { |name| books_books(name) }
      ratings = %w[3.5 3.75 4.5 4.75]
      books.zip(ratings).each { |book, rating| Review.create!(user: user, reviewable: book, rating: rating) }

      query = Reviews::MyReviewsQuery.new(user: user, reviewable_class: ::Books::Book, params: {rating: "4"})

      assert_equal [BigDecimal("3.75"), BigDecimal("4.5")], query.call.map(&:rating).sort
    end
```

In `my_reviews_stats_test.rb`:

```ruby
    test "counts by bucket and averages the exact ratings" do
      user = User.create!(email: "stats-buckets@example.com", role: :user, email_verified: false)
      books = %i[got war_and_peace clash].map { |name| books_books(name) }
      books.zip(%w[3.75 4.5 1.25]).each { |book, rating| Review.create!(user: user, reviewable: book, rating: rating) }

      stats = Reviews::MyReviewsStats.new(user: user, reviewable_class: ::Books::Book)

      assert_equal({1 => 1, 2 => 0, 3 => 0, 4 => 2, 5 => 0}, stats.counts_by_rating)
      assert_equal 3.2, stats.average
    end
```

(3.75 + 4.5 + 1.25 = 9.5, and 9.5 / 3 = 3.1667, which rounds to 3.2. A bucket-weighted average would give (4+4+1)/3 = 3.0, so this test separates the two.)

- [ ] **Step 2: Run them to confirm they fail**

Run: `bin/rails test test/lib/services/reviews/summary_recalculator_test.rb test/lib/reviews/my_reviews_query_test.rb test/lib/reviews/my_reviews_stats_test.rb`
Expected: FAIL. The summary counts `[0,0,0,0,0]`-ish (no exact matches), the query filters `rating = 4` and returns `[]`, and the stats keys on raw decimals.

- [ ] **Step 3: Implement**

In `summary_recalculator.rb`, replace the five `FILTER (WHERE rating = n)` lines in `AGGREGATES`:

```ruby
      AGGREGATES = <<~SQL.freeze
        COUNT(rating),
        COALESCE(SUM(rating), 0),
        COUNT(*) FILTER (WHERE body IS NOT NULL),
        COUNT(*) FILTER (WHERE #{Review::RATING_BUCKET_SQL} = 1),
        COUNT(*) FILTER (WHERE #{Review::RATING_BUCKET_SQL} = 2),
        COUNT(*) FILTER (WHERE #{Review::RATING_BUCKET_SQL} = 3),
        COUNT(*) FILTER (WHERE #{Review::RATING_BUCKET_SQL} = 4),
        COUNT(*) FILTER (WHERE #{Review::RATING_BUCKET_SQL} = 5),
        NOW(), NOW()
      SQL
```

Add a line to the class comment: `# Buckets are Review::RATING_BUCKET_SQL (Goodreads' rule), so a 3.75 counts as a 4.` The upsert reads `FROM reviews`, so the qualified `reviews.rating` in the constant resolves.

In `my_reviews_query.rb#call`, change the filter line:

```ruby
      scope = scope.where("#{Review::RATING_BUCKET_SQL} = ?", rating) if rating
```

Then update the `rating` method's comment: the value is a **bucket** 1..5, not an exact rating.

In `my_reviews_stats.rb`:

```ruby
    # The exact mean, not a bucket-weighted one: with fractional ratings the
    # buckets are a rounding, and averaging the rounding drifts.
    def average
      return nil if total.zero?

      scope.average(:rating).to_f.round(1)
    end
```

and

```ruby
    def raw_counts
      @raw_counts ||= scope.group(Arel.sql(Review::RATING_BUCKET_SQL)).count
    end
```

(`scope.average` ignores NULL ratings, matching `total`, which counts rated reviews only.)

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/reviews test/lib/reviews test/components/reviews/histogram_component_test.rb test/components/reviews/my`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/reviews/summary_recalculator.rb web-app/app/lib/reviews web-app/test/lib
git commit -m "Reviews: bucket fractional ratings by Goodreads' five-bar rule

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Per-star display and formatted rating text everywhere

**Files:**
- Modify: `web-app/app/components/reviews/stars_component.rb`, `stars_component.html.erb`
- Create: `web-app/app/javascript/controllers/reviews/star_rating.js`
- Modify: `web-app/app/javascript/controllers/reviews/widget_controller.js` (`renderStars`, `starsLabel`)
- Modify: `web-app/app/components/reviews/review_component.rb:28`, `web-app/app/components/reviews/widget_component.rb:41`
- Modify: `web-app/app/components/reviews/my/row_component.html.erb:24,47`
- Modify: `web-app/app/views/admin/reviews_base/show.html.erb:14-16`, `web-app/app/views/admin/reviews_base/index.html.erb:31`, `web-app/app/views/admin/users/show.html.erb:208`, `web-app/app/views/recommendations/books/_step_3.html.erb:30`
- Modify: `web-app/app/controllers/review_state_controller.rb:44`
- Test: `web-app/test/components/reviews/stars_component_test.rb` (rewrite), `review_component_test.rb`, `widget_component_test.rb:29,36`, `my/row_component_test.rb`, `web-app/test/controllers/review_state_controller_test.rb`, `web-app/test/controllers/books/books_controller_test.rb:181`, and the admin reviews controller test (find it with `grep -rln "admin/reviews\|admin_books_reviews" test/controllers`)

**Interfaces:**
- Consumes: `Review.format_rating`, `Review#formatted_rating` (Task 1)
- Produces:
  - `Reviews::StarsComponent.new(rating:, size: "size-4", label: nil, exact: false)`. Markup: a `role="img"` wrapper holding five `[data-testid="star"]` spans, each with a `[data-testid="star-track"]` and a `[data-testid="star-fill"][style="width: N%"]`.
  - JS module `star_rating.js` exports `MAX_RATING`, `starFills(rating) -> number[5]` (percentages, one decimal) and `formatRating(rating) -> string`.

- [ ] **Step 1: Rewrite the StarsComponent tests** (replace the whole file body):

```ruby
# frozen_string_literal: true

require "test_helper"

module Reviews
  class StarsComponentTest < ViewComponent::TestCase
    def fills
      page.all("[data-testid='star-fill']", visible: :all).map { |el| el[:style] }
    end

    test "fills each star separately: 3.75 is three full, three quarters, empty" do
      render_inline(Reviews::StarsComponent.new(rating: BigDecimal("3.75")))

      assert_equal ["width: 100.0%", "width: 100.0%", "width: 100.0%", "width: 75.0%", "width: 0.0%"], fills
    end

    test "a fractional average fills its partial star proportionally" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96))

      assert_equal "width: 96.0%", fills[3]
      assert_equal "width: 0.0%", fills[4]
    end

    test "renders a track and a filled star for each of five stars" do
      render_inline(Reviews::StarsComponent.new(rating: 5))

      assert_selector "[data-testid='star']", count: 5
      assert_selector "[data-testid='star-track'] svg", count: 5
      assert_selector "[data-testid='star-fill'] svg.fill-current", count: 5
      assert_no_selector "[data-testid='star-track'] svg.fill-current"
    end

    test "an average label keeps one decimal" do
      render_inline(Reviews::StarsComponent.new(rating: 4.25))

      assert_selector "[role='img'][aria-label='4.3 out of 5 stars']"
      assert_selector "[data-testid='star'][aria-hidden='true']", count: 5
    end

    test "an exact label reads a single rating as entered" do
      render_inline(Reviews::StarsComponent.new(rating: BigDecimal("3.75"), exact: true))

      assert_selector "[role='img'][aria-label='3.75 out of 5 stars']"
    end

    test "accepts a caller-supplied label" do
      render_inline(Reviews::StarsComponent.new(rating: 3.96, label: "Average rating 4.0 out of 5"))

      assert_selector "[role='img'][aria-label='Average rating 4.0 out of 5']"
    end

    test "a nil rating renders empty stars and says so" do
      render_inline(Reviews::StarsComponent.new(rating: nil))

      assert_equal ["width: 0.0%"] * 5, fills
      assert_selector "[role='img'][aria-label='Not yet rated']"
    end

    test "clamps a rating above five, and the label matches the fill" do
      render_inline(Reviews::StarsComponent.new(rating: 9))

      assert_equal ["width: 100.0%"] * 5, fills
      assert_selector "[role='img'][aria-label='5.0 out of 5 stars']"
    end

    test "applies a caller-supplied size class to every star" do
      render_inline(Reviews::StarsComponent.new(rating: 2, size: "size-3"))

      assert_selector "svg.size-3", count: 10
      assert_no_selector "svg.size-4"
    end
  end
end
```

- [ ] **Step 2: Write the failing surface tests** (Review Focus 1)

In `review_component_test.rb`:

```ruby
    test "a fractional rating reads as entered, never in exponent notation" do
      review = Review.new(id: 1, rating: BigDecimal("3.75"), body: "<p>Close.</p>", created_at: 1.day.ago)
      render_inline(Reviews::ReviewComponent.new(review: review))

      assert_selector "[role='img'][aria-label='Rated 3.75 out of 5 stars']"
      assert_no_text "e1"
    end
```

In `widget_component_test.rb`, change line 29's selector to `"[data-testid='review-widget-stars'] [data-testid='star-fill'][style='width: 0.0%']", count: 5`, and add:

```ruby
    test "a fractional rating labels and fills exactly" do
      review = Review.new(id: 1, rating: BigDecimal("4.25"))
      render_inline(Reviews::WidgetComponent.new(reviewable: books_books(:got), review: review))

      assert_selector "[role='img'][aria-label='Your rating: 4.25 out of 5 stars']"
      assert_selector "[data-testid='star-fill'][style='width: 25.0%']", count: 1
    end
```

In `my/row_component_test.rb` (copy its existing setup to construct a row):

```ruby
    test "the edit trigger carries the formatted rating" do
      # build `review` as the file's other tests do, with rating: BigDecimal("3.75")
      render_inline(Reviews::My::RowComponent.new(review: review)) # match the existing constructor
      assert_selector "[data-rating='3.75']"
    end
```

(Open the file first and use its exact constructor arguments and review builder. The assertion is the part that matters.)

In `review_state_controller_test.rb`, next to the line-19 test:

```ruby
  test "returns a fractional rating as a JSON number" do
    # sign in and create the review as the line-19 test does, with rating: "3.75"
    # then:
    assert_equal 3.75, body["review"]["rating"]
  end
```

(Copy the setup of the existing test that asserts `assert_equal 5, body["review"]["rating"]`, and change only the rating and the expected value. `3.75` must be a Float, not `"3.75"`.)

In `books_controller_test.rb:181`, change the selector to `"#review_widget [data-testid='review-widget-stars'] [data-testid='star-fill'][style='width: 0.0%']", count: 5`.

In the admin reviews controller test, add a test that signs in as an admin, creates a review with `rating: "3.75"`, gets the index and the show page, and asserts `response.body` includes `3.75` and does not include `0.375e1`. Copy the sign-in and path helpers from that file's existing tests. Do the same for the admin users show page if it has a controller test. If it has none, the index test covers the shared helper.

- [ ] **Step 3: Run them to confirm they fail**

Run: `bin/rails test test/components/reviews test/controllers/review_state_controller_test.rb test/controllers/books/books_controller_test.rb`
Expected: FAIL. The markup still uses `stars-fill`, labels print `0.375e1`, and the JSON returns `"3.75"`.

- [ ] **Step 4: Implement StarsComponent**

`stars_component.rb` (replace the class body and keep the header comment, updated):

```ruby
module Reviews
  # Five stars, each filled separately to clamp(rating - i, 0, 1) -- the way
  # Goodreads draws them. A per-star fill (rather than one strip clipped across
  # the row) keeps the inter-star gaps from shifting the cut: at size-4 the old
  # strip filled ~49% of the fourth star for a 3.5.
  #
  # Fill is a single colour throughout. The information is carried by how far the fill
  # extends and by the number printed beside it, never by hue.
  #
  # `exact:` is for a single reader's rating (3.75 reads "3.75"); the default
  # is an average, rounded to one decimal.
  class StarsComponent < ViewComponent::Base
    MAX_RATING = 5

    def initialize(rating:, size: "size-4", label: nil, exact: false)
      @rating = rating
      @size = size
      @label = label
      @exact = exact
    end

    private

    attr_reader :rating, :size

    # One decimal, so 79.2% survives instead of collapsing to 79%.
    def star_fills
      Array.new(MAX_RATING) { |index| ((clamped_rating - index).clamp(0.0, 1.0) * 100).round(1) }
    end

    def label
      return @label if @label
      return "Not yet rated" if rating.nil?

      value = @exact ? Review.format_rating(clamped_rating) : clamped_rating.round(1)
      "#{value} out of #{MAX_RATING} stars"
    end

    # Shared by star_fills and label so the visual fill and the accessible
    # name never disagree -- an out-of-range rating (e.g. 9) must read as
    # "5.0 out of 5 stars", not the raw, unclamped input.
    def clamped_rating
      rating.to_f.clamp(0.0, MAX_RATING.to_f)
    end

    # `fill-current` is a CSS declaration and so beats the `fill="none"` presentation
    # attribute baked into the vendored Lucide source.
    def star(filled:)
      classes = filled ? "#{size} shrink-0 fill-current" : "#{size} shrink-0"
      helpers.icon("star", library: "lucide", class: classes)
    end
  end
end
```

`stars_component.html.erb`:

```erb
<span class="inline-flex gap-px align-middle leading-none" role="img" aria-label="<%= label %>">
  <% star_fills.each do |fill| %>
    <span class="relative inline-block shrink-0" aria-hidden="true" data-testid="star">
      <span class="flex text-base-content/30" data-testid="star-track"><%= star(filled: false) %></span>
      <span class="absolute inset-y-0 start-0 flex overflow-hidden text-warning" style="width: <%= fill %>%" data-testid="star-fill"><%= star(filled: true) %></span>
    </span>
  <% end %>
</span>
```

- [ ] **Step 5: Implement the text and JSON fixes**

- `review_component.rb:28`: `"Rated #{review.formatted_rating} out of 5 stars"`
- `widget_component.rb:41`: `"Your rating: #{review.formatted_rating} out of 5 stars"`
- `my/row_component.html.erb:24`: `render Reviews::StarsComponent.new(rating: review.rating, exact: true)`. Line 47: `data-rating="<%= review.formatted_rating %>"`
- `admin/reviews_base/show.html.erb:15-16`: the label `"Rated #{@review.formatted_rating} out of 5 stars"` and the span `<%= @review.formatted_rating %> / 5`
- `admin/reviews_base/index.html.erb:31` and `admin/users/show.html.erb:208`: `<%= review.formatted_rating || "—" %>`
- `recommendations/books/_step_3.html.erb:30`: `label: "#{review.formatted_rating} stars"`
- `review_state_controller.rb:44`: `rating: review.rating&.to_f,` with the comment `# A number, not Rails' BigDecimal string: the dialog does arithmetic on it.`

- [ ] **Step 6: Implement the shared JS and widget hydration**

Create `app/javascript/controllers/reviews/star_rating.js`:

```js
// Shared by reviews--widget and reviews--star-input. Mirrors
// Reviews::StarsComponent#star_fills and Review.format_rating, so a rating
// looks the same whether the server rendered it or JavaScript hydrated it.
export const MAX_RATING = 5

// Percent fill of each of the five stars, one decimal.
export function starFills(rating) {
  const value = Math.max(0, Math.min(MAX_RATING, Number(rating) || 0))
  return Array.from({ length: MAX_RATING }, (_, index) =>
    Math.round(Math.max(0, Math.min(1, value - index)) * 1000) / 10
  )
}

// 4 -> "4", 3.5 -> "3.5", 3.75 -> "3.75".
export function formatRating(rating) {
  return String(Number(Number(rating).toFixed(2)))
}
```

In `widget_controller.js`, add `import { starFills, formatRating } from "./star_rating"` under the Stimulus import. Replace the body of `renderStars()` after its guard:

```js
    const rating = this.review && this.review.rating != null ? this.review.rating : 0
    const fills = starFills(rating)
    this.starsTarget.querySelectorAll('[data-testid="star-fill"]').forEach((fill, index) => {
      fill.style.width = `${fills[index]}%`
    })

    const img = this.starsTarget.querySelector('[role="img"]')
    if (img) img.setAttribute("aria-label", this.starsLabel())
```

In `starsLabel()`, change the last line to `return \`Your rating: ${formatRating(this.review.rating)} out of 5 stars\``. Update the comment above `renderStars()`: hydration now widens five per-star fills, not one.

- [ ] **Step 7: Run the tests and lint**

Run: `bin/rails test test/components test/controllers/review_state_controller_test.rb test/controllers/books/books_controller_test.rb test/controllers/admin && yarn build:all && bundle exec standardrb`
Expected: PASS, and the build succeeds (the import resolves).

- [ ] **Step 8: Commit**

```bash
git add web-app/app/components/reviews web-app/app/javascript/controllers/reviews web-app/app/views web-app/app/controllers/review_state_controller.rb web-app/test
git commit -m "Reviews: per-star fill and formatted fractional ratings on every surface

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The quarter-star rating control

**Files:**
- Create: `web-app/app/javascript/controllers/reviews/star_input_controller.js`
- Modify: `web-app/app/javascript/manifests/web_shared.js` (register `reviews--star-input`)
- Modify: `web-app/app/components/reviews/modal_component.rb`, `modal_component.html.erb:13-35`
- Modify: `web-app/app/javascript/controllers/reviews/modal_controller.js` (targets, `setRating`/`setRatingValue`, `clearRating`)
- Test: `web-app/test/components/reviews/modal_component_test.rb`

**Interfaces:**
- Consumes: `starFills`, `formatRating`, `MAX_RATING` from `star_rating.js` (Task 3)
- Produces:
  - DOM contract: a wrapper `[data-controller="reviews--star-input"]` holding a `[role="slider"][data-testid="review-star-input"]` of five `[data-reviews--star-input-target="star"]`, a readout `[data-testid="review-rating-readout"]` and the hidden `input[name="review[rating]"]`.
  - Events: the wrapper listens for `star-input:set` (`detail.value`: a number or null) and dispatches `reviews--star-input:change` (`detail.value`).

- [ ] **Step 1: Update the ModalComponent tests.** Replace the "renders five star buttons..." test with:

```ruby
    test "renders a quarter-step slider of five stars with a readout" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "[data-controller='reviews--star-input'] [role='slider'][data-testid='review-star-input']" \
        "[aria-valuemin='0.25'][aria-valuemax='5'][aria-valuetext='Not rated'][tabindex='0']"
      assert_selector "[data-testid='review-star-input'] [data-reviews--star-input-target='star']", count: 5
      assert_selector "[data-testid='review-rating-readout']", text: "Not rated"
    end

    test "the hidden rating field lives inside the star input so it can write it" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "[data-controller='reviews--star-input'] input[type='hidden'][name='review[rating]']" \
        "[data-reviews--star-input-target='input'][data-reviews--modal-target='rating']", visible: :all
    end
```

- [ ] **Step 2: Run to confirm failure**

Run: `bin/rails test test/components/reviews/modal_component_test.rb`
Expected: FAIL (no slider).

- [ ] **Step 3: Replace the fieldset markup** in `modal_component.html.erb`. Remove the standalone hidden `review[rating]` input (line 13) and replace the `<fieldset class="mt-4">…</fieldset>` block:

```erb
      <fieldset class="mt-4">
        <legend class="text-sm font-semibold" id="review_rating_legend">Your rating</legend>
        <div class="mt-2 flex items-center gap-3"
             data-controller="reviews--star-input"
             data-action="star-input:set->reviews--star-input#set reviews--star-input:change->reviews--modal#ratingChanged">
          <input type="hidden" name="review[rating]" value=""
                 data-reviews--modal-target="rating" data-reviews--star-input-target="input">
          <div class="inline-flex cursor-pointer touch-pan-y select-none gap-1 rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
               role="slider" tabindex="0"
               aria-labelledby="review_rating_legend"
               aria-valuemin="0.25" aria-valuemax="5" aria-valuetext="Not rated"
               data-testid="review-star-input"
               data-reviews--star-input-target="slider"
               data-reviews--modal-target="ratingSlider"
               data-action="pointerdown->reviews--star-input#press pointermove->reviews--star-input#move pointerup->reviews--star-input#release pointercancel->reviews--star-input#release pointerleave->reviews--star-input#leave keydown->reviews--star-input#key">
            <% stars.each do %>
              <span class="relative inline-block shrink-0" data-reviews--star-input-target="star">
                <span class="flex text-base-content/30"><%= helpers.icon "star", library: "lucide", class: "size-10 shrink-0", aria_hidden: "true" %></span>
                <span class="absolute inset-y-0 start-0 flex overflow-hidden text-warning" style="width: 0%" data-reviews--star-input-target="fill"><%= helpers.icon "star", library: "lucide", class: "size-10 shrink-0 fill-current", aria_hidden: "true" %></span>
              </span>
            <% end %>
          </div>
          <span class="tabular-nums" aria-hidden="true" data-testid="review-rating-readout" data-reviews--star-input-target="readout">Not rated</span>
        </div>
        <button type="button"
                class="btn btn-ghost btn-xs mt-1 hidden"
                data-testid="review-clear-rating"
                data-reviews--modal-target="clearRating"
                data-action="click->reviews--modal#clearRating">Clear rating</button>
      </fieldset>
```

In `modal_component.rb`, replace `ratings` with:

```ruby
    def stars
      1..MAX_RATING
    end
```

- [ ] **Step 4: Write the controller.** Create `star_input_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import { MAX_RATING, starFills, formatRating } from "./star_rating"

const STEP = 0.25
const KEY_DELTAS = { ArrowRight: STEP, ArrowUp: STEP, ArrowLeft: -STEP, ArrowDown: -STEP, PageUp: 1, PageDown: -1 }

// Quarter-star rating input (spec §5.1). One control for mouse, touch and
// keyboard: a mouse previews on hover and commits on press; a finger or pen
// commits where it lands and adjusts as it drags; keys step by a quarter.
// Writes the hidden review[rating] field and dispatches
// "reviews--star-input:change". The host sets a value with a "star-input:set"
// event on this element.
export default class extends Controller {
  static targets = ["slider", "star", "fill", "readout", "input"]

  connect() {
    this.committed = this.inputTarget.value === "" ? null : Number(this.inputTarget.value)
    this.dragging = false
    this.commit(this.committed, { silent: true })
  }

  set(event) {
    const value = event.detail?.value
    this.commit(value == null || value === "" ? null : Number(value))
  }

  press(event) {
    if (event.pointerType === "mouse" && event.button !== 0) return
    this.dragging = true
    // Keeps a drag that wanders off the row attached to it. Throws
    // NotFoundError for a pointer the browser no longer tracks; the drag
    // still works without capture, so that is not worth failing over.
    try {
      this.sliderTarget.setPointerCapture(event.pointerId)
    } catch {}
    this.commit(this.valueAt(event.clientX))
  }

  move(event) {
    if (this.dragging) {
      this.commit(this.valueAt(event.clientX))
    } else if (event.pointerType === "mouse") {
      this.paint(this.valueAt(event.clientX))
    }
  }

  release() {
    this.dragging = false
  }

  leave() {
    if (!this.dragging) this.paint(this.committed)
  }

  key(event) {
    let value
    if (event.key === "Home") value = STEP
    else if (event.key === "End") value = MAX_RATING
    else if (event.key in KEY_DELTAS) value = (this.committed ?? 0) + KEY_DELTAS[event.key]
    else return

    event.preventDefault()
    this.commit(Math.min(MAX_RATING, Math.max(STEP, value)))
  }

  // Star under the pointer, then the quarter of it, rounded up. A pointer in a
  // gap snaps to the end of the star before it; past either end clamps.
  valueAt(clientX) {
    const rects = this.starTargets.map((star) => star.getBoundingClientRect())
    for (let index = 0; index < rects.length; index++) {
      const rect = rects[index]
      if (clientX < rect.left) return index === 0 ? STEP : index
      if (clientX <= rect.right) {
        const quarters = Math.ceil(((clientX - rect.left) / rect.width) * 4)
        return index + Math.max(1, quarters) * STEP
      }
    }
    return MAX_RATING
  }

  commit(value, { silent = false } = {}) {
    this.committed = value
    this.inputTarget.value = value == null ? "" : formatRating(value)
    if (value == null) {
      this.sliderTarget.removeAttribute("aria-valuenow")
    } else {
      this.sliderTarget.setAttribute("aria-valuenow", String(value))
    }
    this.sliderTarget.setAttribute("aria-valuetext", value == null ? "Not rated" : `${formatRating(value)} stars`)
    this.paint(value)
    if (!silent) this.dispatch("change", { detail: { value } })
  }

  // Visual only: a hover preview must not change what a screen reader hears.
  paint(value) {
    const fills = starFills(value ?? 0)
    this.fillTargets.forEach((fill, index) => {
      fill.style.width = `${fills[index]}%`
    })
    this.readoutTarget.textContent = value == null ? "Not rated" : formatRating(value)
  }
}
```

- [ ] **Step 5: Register it.** In `manifests/web_shared.js`, next to the other reviews registrations:

```js
import Reviews__StarInputController from "../controllers/reviews/star_input_controller"
application.register("reviews--star-input", Reviews__StarInputController)
```

- [ ] **Step 6: Rewire `modal_controller.js`**

- In `static targets`, replace `"star"` with `"ratingSlider"`.
- Delete `setRating(event)`.
- Replace `setRatingValue(value)` with:

```js
  // The star input owns the hidden field and the drawing; this only hands it
  // a value. It answers with reviews--star-input:change, which ratingChanged
  // uses to show or hide "Clear rating".
  setRatingValue(value) {
    this.ratingTarget.closest('[data-controller~="reviews--star-input"]')
      .dispatchEvent(new CustomEvent("star-input:set", { detail: { value: value ?? null } }))
  }

  ratingChanged(event) {
    const value = event.detail?.value
    if (this.hasClearRatingTarget) this.clearRatingTarget.classList.toggle("hidden", value == null)
  }
```

- In `clearRating()`, change the focus line to `this.ratingSliderTarget.focus()` and keep its comment.

`_onOpen` already calls `this.setRatingValue(review.rating)` and `this.setRatingValue(null)`. `review.rating` is now a JSON number (Task 3) or `Number(row.rating)` from My Reviews. `validate()` still reads `this.ratingTarget.value`.

- [ ] **Step 7: Run the tests, lint and build**

Run: `bin/rails test test/components/reviews test/lint && yarn build:all && bundle exec standardrb`
Expected: PASS. In particular `test/lint/stimulus_manifest_test.rb` finds `reviews--star-input` referenced and registered, and `untrusted_text_dom_test.rb` passes because the controller only uses `textContent`.

- [ ] **Step 8: Check it by hand in a browser.** Port 3000 is shared between worktrees, so check who owns it first:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If it prints another checkout, stop and tell the user. If the port is free: `yarn build:all && bin/rails server`. Open a book page, then open "Rate this book":
- Hover moves through ¼ steps.
- A click commits.
- Moving off the stars restores the committed value.
- The arrow keys step.
- "Clear rating" appears and disappears.

Leave the E2E for Task 8.

- [ ] **Step 9: Commit**

```bash
git add web-app/app/javascript web-app/app/components/reviews/modal_component.rb web-app/app/components/reviews/modal_component.html.erb web-app/test/components/reviews/modal_component_test.rb
git commit -m "Reviews: quarter-star rating control (hover, drag, keys)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Read fractional ratings from Goodreads exports

**Files:**
- Modify: `web-app/app/lib/books/goodreads/export_row.rb:104` and the private helpers near `integer` (line ~157)
- Modify: `web-app/app/lib/services/books/goodreads_imports/write_library.rb:215-223`
- Create: `web-app/test/fixtures/files/goodreads/quarter_star_export.csv`
- Test: `web-app/test/lib/books/goodreads/export_row_test.rb`, `web-app/test/lib/services/books/goodreads_imports/parse_rows_test.rb`, `web-app/test/lib/services/books/goodreads_imports/write_library_test.rb`

**Interfaces:**
- Consumes: decimal `books_goodreads_import_rows.rating` (Task 1)
- Produces: `ExportRow#rating -> BigDecimal | nil` (0 means unrated). Task 6 relies on `row.rating&.positive?` and `row.rating.frac`.

- [ ] **Step 1: Create the fixture**, copying the header of the owner's real 2026-10-10 export exactly (no `Average Rating`):

```csv
Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,Publisher,Binding,Number of Pages,Year Published,Original Publication Year,Date Read,Date Added,Bookshelves,Bookshelves with positions,Exclusive Shelf,My Review,Spoiler,Private Notes,Read Count,Owned Copies
4934,The Brothers Karamazov,Fyodor Dostoevsky,"Dostoevsky, Fyodor",,"=""""","=""""",3.75,,,,,1880,,2026/10/10,,,read,,,,1,0
117833,The Master and Margarita,Mikhail Bulgakov,"Bulgakov, Mikhail",,"=""""","=""""",4.25,,,,,1967,,2026/10/10,currently-reading,currently-reading (#1),currently-reading,,,,0,0
106569,Codependent No More,Melody Beattie,"Beattie, Melody",,"=""""","=""""",4.0,,,,,1986,2024/09/08,2026/10/10,,,read,,,,1,0
2767052,The Hunger Games,Suzanne Collins,"Collins, Suzanne",,"=""""","=""""",0,,,,,2008,,2026/10/10,,,to-read,,,,0,0
```

- [ ] **Step 2: Write the failing tests**

In `export_row_test.rb`, replace the zero / out-of-range test with:

```ruby
      test "My Rating reads whole, '.0' and fractional values as decimals; zero means unrated" do
        assert_equal BigDecimal("4"), row("My Rating" => "4").rating
        assert_equal BigDecimal("4"), row("My Rating" => "4.0").rating
        assert_equal BigDecimal("3.75"), row("My Rating" => "3.75").rating
        assert_equal BigDecimal("0.25"), row("My Rating" => "0.25").rating
        assert_equal BigDecimal("3.33"), row("My Rating" => "3.333").rating
        assert_equal BigDecimal("0"), row("My Rating" => "0").rating
        assert_nil row("My Rating" => "").rating
      end

      test "an out-of-range or unreadable My Rating is dropped and noted" do
        %w[7 5.5 -1 NaN Infinity abc 1e2 4,5 1_0].each do |value|
          parsed = row("My Rating" => value)

          assert_nil parsed.rating, "expected #{value.inspect} to be dropped"
          assert_includes parsed.notes, "unreadable My Rating dropped: #{value}"
        end
      end
```

In `parse_rows_test.rb` (Review Focus 4):

```ruby
        test "a current-format export (no Average Rating column) keeps fractional ratings" do
          rows = ::Books::Goodreads::ExportFile.parse(file_fixture("goodreads/quarter_star_export.csv").read).data[:rows]

          ParseRows.call(import: @import, rows: rows)

          assert_equal [BigDecimal("3.75"), BigDecimal("4.25"), BigDecimal("4"), BigDecimal("0")],
            @import.rows.order(:row_number).pluck(:rating)
        end
```

(Check how `goodreads_rows` in `test/support/goodreads_import_helper.rb` calls `ExportFile.parse`, and pass the file contents the same way: string or bytes.)

In `write_library_test.rb`:

```ruby
        test "a quarter-star rating becomes a review, not an unrated row" do
          row(@book, rating: BigDecimal("0.25"))
          row(@other, rating: BigDecimal("3.75"), review_body: "Nearly.")

          WriteLibrary.call(import: @import)

          assert_equal BigDecimal("0.25"), ::Review.find_by!(user: @user, reviewable: @book).rating
          assert_equal BigDecimal("3.75"), ::Review.find_by!(user: @user, reviewable: @other).rating
        end

        test "a rated row beats a text-only row even when the rating is under one" do
          row(@book, number: 1, rating: 0, review_body: "Text only.", date_read: Date.new(2025, 1, 1))
          row(@book, number: 2, rating: BigDecimal("0.5"), review_body: "Half a star.", date_read: Date.new(2020, 1, 1))

          WriteLibrary.call(import: @import)

          assert_equal [BigDecimal("0.5"), "Half a star."], ::Review.find_by!(user: @user, reviewable: @book).then { |r| [r.rating, r.body] }
        end
```

- [ ] **Step 3: Run to confirm failure**

Run: `bin/rails test test/lib/books/goodreads/export_row_test.rb test/lib/services/books/goodreads_imports/parse_rows_test.rb test/lib/services/books/goodreads_imports/write_library_test.rb`
Expected: FAIL. `Integer()` drops `4.0`, `3.75` and `0.25`, and `to_i.positive?` discards 0.25 and 0.5.

- [ ] **Step 4: Implement the parser.** In `export_row.rb`, change line 104 to:

```ruby
        @rating = rating("My Rating")
```

Add a constant near the other constants at the top of the class:

```ruby
      # Plain digits with an optional fraction. Stricter than BigDecimal(),
      # which also accepts "NaN", "Infinity", "1e2" and "1_0".
      RATING = /\A\d+(\.\d+)?\z/
```

Add a private method next to `integer`:

```ruby
      # Goodreads rates in quarter stars since 2026-10-05 and writes "3.75",
      # and "4.0" for a whole star. 0 is its "not rated". Rounded to the
      # column's two places; anything else is dropped with a note, like every
      # other unreadable field.
      def rating(header)
        value = field(header).strip
        return nil if value.empty?

        number = BigDecimal(value) if value.match?(RATING)
        return number.round(2) if number && number <= 5

        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end
```

- [ ] **Step 5: Fix `WriteLibrary`.** In `write_library.rb`, change lines 215-216 and 223:

```ruby
            winner = rows.select { |row| row.rating&.positive? || row.review_body.present? }
              .min_by { |row| [row.rating&.positive? ? 0 : 1, -(row.date_read&.jd || 0), row.row_number] }
```

```ruby
            rating: (row.rating if row.rating&.positive?), body: row.review_body&.gsub(REVIEW_BREAK, "\n"))
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/books/goodreads test/lib/services/books/goodreads_imports test/lib/services/books/goodreads_replay test/lib/tasks/books_goodreads_rake_test.rb`
Expected: PASS. The old `small_export.csv` (integer ratings, with `Average Rating`) still imports.

- [ ] **Step 7: Commit**

```bash
git add web-app/app/lib/books/goodreads/export_row.rb web-app/app/lib/services/books/goodreads_imports/write_library.rb web-app/test/fixtures/files/goodreads/quarter_star_export.csv web-app/test/lib
git commit -m "Goodreads import: read quarter-star ratings; a 0.25 is a rating, not unrated

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Repair ratings the legacy site truncated

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_imports/write_library.rb` (`write_reviews`, new private `repair_truncated_rating`)
- Test: `web-app/test/lib/services/books/goodreads_imports/write_library_test.rb`

**Interfaces:**
- Consumes: `row.rating` as `BigDecimal` (Task 5), `@import.legacy_replay?` (existing enum), `Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews")` (250,000)
- Produces: nothing new for later tasks

- [ ] **Step 1: Write the failing tests** in `write_library_test.rb`. Add a helper and six tests:

```ruby
        LEGACY_REVIEW_ID = 4242

        def legacy_replay!
          @import.update!(source: :legacy_replay)
        end

        def legacy_review(book, rating:, id: LEGACY_REVIEW_ID, body: "From legacy.")
          ::Review.create!(id: id, user: @user, reviewable: book, rating: rating, body: body)
        end

        test "a legacy replay restores a rating the legacy site truncated" do
          legacy_replay!
          review = legacy_review(@book, rating: 3)
          row(@book, rating: BigDecimal("3.75"), review_body: "Imported.")

          WriteLibrary.call(import: @import)

          review.reload
          assert_equal [BigDecimal("3.75"), "From legacy."], [review.rating, review.body]
          assert_equal BigDecimal("3.75"), ReviewSummary.find_by!(reviewable_type: "Books::Book", reviewable_id: @book.id).ratings_sum
        end

        test "a member's own import never repairs" do
          review = legacy_review(@book, rating: 3)
          row(@book, rating: BigDecimal("3.75"))

          WriteLibrary.call(import: @import)

          assert_equal BigDecimal("3"), review.reload.rating
        end

        test "a review made on the new site is never repaired" do
          legacy_replay!
          review = legacy_review(@book, rating: 3, id: ::Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews"))
          row(@book, rating: BigDecimal("3.75"))

          WriteLibrary.call(import: @import)

          assert_equal BigDecimal("3"), review.reload.rating
        end

        test "a whole-star CSV rating repairs nothing" do
          legacy_replay!
          review = legacy_review(@book, rating: 3)
          row(@book, rating: BigDecimal("4"))

          WriteLibrary.call(import: @import)

          assert_equal BigDecimal("3"), review.reload.rating
        end

        test "a rating that is not the truncation of the CSV value is the reader's own and is kept" do
          legacy_replay!
          review = legacy_review(@book, rating: 2)
          row(@book, rating: BigDecimal("3.75"))

          WriteLibrary.call(import: @import)

          assert_equal BigDecimal("2"), review.reload.rating
        end

        # A replay pass in production is a fresh import, so each pass here is a
        # new import on the same edition -- the pattern of "running the same
        # import twice changes nothing" above.
        def replay_pass(book, rating:)
          @import.update!(status: :complete) unless @import.complete?
          edition = @import.rows.first.goodreads_edition
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :writing, source: :legacy_replay)
          @import.rows.create!(row_number: 1, goodreads_edition: edition, exclusive_shelf: "read", rating: rating)
          WriteLibrary.call(import: @import)
        end

        test "repair survives the weekly sync's revert and a pass with nothing to fix is a no-op" do
          legacy_replay!
          review = legacy_review(@book, rating: 3)
          row(@book, rating: BigDecimal("3.75"))
          WriteLibrary.call(import: @import)
          assert_equal BigDecimal("3.75"), review.reload.rating

          # The weekly sync upserts legacy's integer back over the repair.
          review.update_columns(rating: 3)
          replay_pass(@book, rating: BigDecimal("3.75"))
          assert_equal BigDecimal("3.75"), review.reload.rating

          updated_at = review.updated_at
          replay_pass(@book, rating: BigDecimal("3.75"))
          assert_equal [BigDecimal("3.75"), updated_at], [review.reload.rating, review.updated_at]
        end
```

- [ ] **Step 2: Run to confirm failure**

Run: `bin/rails test test/lib/services/books/goodreads_imports/write_library_test.rb`
Expected: the first and last new tests FAIL (the rating stays 3). The four "does not fire" tests pass already. That is expected, since they pin today's behaviour.

- [ ] **Step 3: Implement.** Replace `write_reviews` and add the repair method:

```ruby
        # One deterministic review per book (spec §7): the row with a rating,
        # then the latest Date Read, then the lowest row number. Rating 0 with
        # text is an unrated review; rating 0 and no text is nothing. An
        # existing review by the user is left as it is, except for the one
        # repair below. Validated as a model (the sanitizer and the length rule
        # run) and inserted in bulk, so the per-review summary callback does not
        # fire; `call` recalculates once per book instead.
        def write_reviews(by_book)
          existing = ::Review.where(user: @user, reviewable_type: "Books::Book", reviewable_id: by_book.keys)
            .pluck(:reviewable_id, :id, :rating).to_h { |book_id, id, rating| [book_id, [id, rating]] }
          by_book.each do |book_id, rows|
            winner = rows.select { |row| row.rating&.positive? || row.review_body.present? }
              .min_by { |row| [row.rating&.positive? ? 0 : 1, -(row.date_read&.jd || 0), row.row_number] }
            next unless winner

            if existing.key?(book_id)
              repair_truncated_rating(book_id, *existing.fetch(book_id), winner)
            else
              write_review(book_id, winner)
            end
          end
        end

        # Quarter-star spec §5.4. The legacy site's importer did "3.75".to_i, so
        # a legacy review copied here says 3 where the reader's CSV says 3.75.
        # Repaired only when the match is that exact, so a rating the reader
        # changed is never touched. The weekly sync puts legacy's 3 back, and the
        # next replay pass (which runs after it) restores 3.75; a pass with
        # nothing to fix writes nothing. Timestamps are left alone on purpose.
        def repair_truncated_rating(book_id, review_id, stored, row)
          return unless @import.legacy_replay?
          return unless review_id < ::Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews")

          imported = row.rating
          return if imported.nil? || imported.frac.zero? || stored.nil? || stored != imported.floor

          ::Review.where(id: review_id).update_all(rating: imported)
          @touched_book_ids << book_id
        end
```

(`update_all` skips the `after_commit` summary callback on purpose. The book joins `@touched_book_ids`, and `call` recalculates it once. That is the same pattern `write_review` uses.)

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/books/goodreads_imports test/lib/services/books/goodreads_replay`
Expected: PASS, including the existing "an existing review is left untouched" test (a member import).

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books/goodreads_imports/write_library.rb web-app/test/lib/services/books/goodreads_imports/write_library_test.rb
git commit -m "Goodreads replay: restore quarter-star ratings the legacy site truncated

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Recommendations compare the exact rating

**Files:**
- Modify: `web-app/app/lib/recommendations/books/positive_pairs.rb:13-15,48`
- Modify: `web-app/app/lib/recommendations/books/adapter.rb:26-34`
- Test: `web-app/test/lib/recommendations/books/positive_pairs_test.rb`, `web-app/test/lib/recommendations/books/adapter_test.rb`

**Interfaces:**
- Consumes: decimal `reviews.rating` (Task 1)
- Produces: `Interaction#rating` is a Float (or nil), as before conceptually, but no longer always integral

- [ ] **Step 1: Write the failing tests**

`positive_pairs_test.rb`:

```ruby
      test "the floor compares the exact rating, so a decimal floor works" do
        Review.create!(user: @user, reviewable: books_books(:of_mice_and_men), rating: "3.75")
        Review.create!(user: @user, reviewable: books_books(:combo_steinbeck), rating: "3.25")
        above = books_books(:of_mice_and_men).id
        below = books_books(:combo_steinbeck).id

        at_three_and_a_half = pairs(min_rating: 3.5).select { |u, _| u == @user.id }.map(&:last)
        assert_includes at_three_and_a_half, above
        assert_not_includes at_three_and_a_half, below
        assert_not_includes pairs(min_rating: 4).select { |u, _| u == @user.id }.map(&:last), above
      end
```

(Both books sit only on lists `PositivePairs` never counts: want-to-read and custom, from `setup`. So only the review can include either. The 3.25 case is what fails today: `3.5.to_i` is 3, and 3.25 >= 3.)

`adapter_test.rb` (follow the file's existing `interaction(:name)` helper and setup):

```ruby
      test "a fractional rating weighs continuously and stays a plain number" do
        Review.create!(user: @user, reviewable: books_books(:of_mice_and_men), rating: "3.75")

        found = interaction(:of_mice_and_men)

        assert_equal 3.75, found.rating
        assert_kind_of Float, found.rating
        assert_in_delta 0.4 + 0.75 * 0.75, found.weight, 0.001, "unlisted review: read weight 0.4 plus 0.75 x (3.75 - 3)"
      end
```

(Confirm in the adapter test that `of_mice_and_men` is on none of `@user`'s lists. If it is, pick a book from `books_books` the setup does not shelve, and adjust the read-weight term to match the file's existing "unlisted review" test.)

- [ ] **Step 2: Run to confirm failure**

Run: `bin/rails test test/lib/recommendations`
Expected: FAIL. `min_rating.to_i` turns 3.5 into 3, so the 3.25 review is wrongly included, and `found.rating` is a `BigDecimal`, not a `Float`.

- [ ] **Step 3: Implement**

`positive_pairs.rb`:

```ruby
      # A decimal, so a fractional floor (3.5) can be configured; ratings are
      # quarter stars and are compared exactly.
      def initialize(min_rating:)
        @min_rating = BigDecimal(min_rating.to_s)
      end
```

and in the SQL: `AND rating >= #{@min_rating.to_s("F")}`.

`adapter.rb`, in `interactions`:

```ruby
        reviews = user.reviews.where(reviewable_type: "Books::Book").pluck(:reviewable_id, :rating)
          .to_h { |item_id, rating| [item_id, rating&.to_f] }
```

Leave the weight line as it is. Then read `interaction.rb:17-18`, `evaluation.rb:17,94`, `signals/collaborative.rb:25,33` and `reranker/series_rule.rb:13`, and confirm each compares (`>=`) or nil-checks without `to_i`. They do as of this plan, so no change is expected. If any casts, remove the cast.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/recommendations`
Expected: PASS, including "agrees with Interaction#trainable? on the adapter's view of the same user".

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/recommendations web-app/test/lib/recommendations
git commit -m "Recommendations: compare exact fractional ratings against thresholds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: E2E, seed data, docs and full verification

**Files:**
- Create: `web-app/e2e/helpers/star-rating.ts`
- Create: `web-app/e2e/tests/books/account/quarter-star-rating.spec.ts`
- Modify: `web-app/e2e/tests/books/account/reviews-write.spec.ts`, `account/my-reviews.spec.ts`, `admin/reviews.spec.ts`, `member/recommendations.spec.ts`
- Modify: `web-app/lib/tasks/e2e.rake:177-185`
- Modify: `docs/features/goodreads-import.md`, `docs/features/recommendations.md`

**Interfaces:**
- Consumes: the DOM contract from Task 4 (`review-star-input`, `review-rating-readout`, `review-clear-rating`), and `star-fill` from Task 3
- Produces: `rateStars(page: Page, value: number): Promise<void>`

- [ ] **Step 1: Write the helper** `e2e/helpers/star-rating.ts`:

```ts
import { expect, Page } from '@playwright/test';

// Clicks the review dialog's star input at the x position that yields `value`
// (a multiple of 0.25). Aims at the middle of the target quarter of the star,
// so rounding up lands exactly on the value.
export async function rateStars(page: Page, value: number) {
  const index = Math.ceil(value) - 1;
  const quarter = Math.round((value - index) * 4); // 1..4
  const star = page.getByTestId('review-star-input').locator('[data-reviews--star-input-target="star"]').nth(index);
  const box = await star.boundingBox();
  if (!box) throw new Error('star input is not visible');
  await star.click({ position: { x: (box.width * (quarter - 0.5)) / 4, y: box.height / 2 } });
  await expect(page.getByTestId('review-rating-readout')).toHaveText(String(value));
}
```

Check that `e2e/tsconfig.json` includes `e2e/helpers`. If its `include` lists only `tests`, add `helpers`.

- [ ] **Step 2: Update the existing specs** to use `rateStars`:
- `reviews-write.spec.ts`: `.nth(3)` becomes `rateStars(page, 4)`, `.nth(4)` becomes `rateStars(page, 5)` and `.nth(2)` becomes `rateStars(page, 3)`. The focus assertion at line 157 becomes `await expect(page.getByTestId('review-star-input')).toBeFocused();`
- `admin/reviews.spec.ts:53` and `member/recommendations.spec.ts:105`: use `rateStars(page, 3)` and `rateStars(page, 4)`.
- `my-reviews.spec.ts:136-151`: seed ratings are now fractional (Step 4), so work in quarters:

```ts
    const currentRating = Number(await trigger.getAttribute('data-rating'));
    const newRating = (currentRating % 5) + 1; // always different; 4.75 -> 5.75 is out of range, so:
```

Replace those two lines with:

```ts
    const currentRating = Number(await trigger.getAttribute('data-rating'));
    const newRating = currentRating >= 5 ? 0.25 : currentRating + 0.25; // always different, stays in range
```

Then use `await rateStars(page, newRating);` and keep the `toHaveAttribute('data-rating', String(newRating))` assertion. `String(4.5)` is `"4.5"`, which matches `formatted_rating`.

Also replace the other `.nth(2)` calls in that file (lines 191 and 230) with `rateStars(page, 3)`.

Import the helper at the top of each file: `import { rateStars } from '../../../helpers/star-rating';` (adjust the `../` depth per file).

- [ ] **Step 3: Write the new spec** `e2e/tests/books/account/quarter-star-rating.spec.ts`. Copy the `BOOK` constant and the `removeExistingReview` cleanup from `reviews-write.spec.ts`, so the spec runs on the same no-reviews book and cleans up after itself.

```ts
import { test, expect } from '@playwright/test';
import { rateStars } from '../../../helpers/star-rating';

const BOOK = '/book/headlong-hall';

// removeExistingReview: copy verbatim from reviews-write.spec.ts

test.describe('Quarter-star ratings', () => {
  test.afterEach(async ({ page }) => {
    await page.goto(BOOK);
    await removeExistingReview(page);
  });

  test('hovering previews quarter steps; leaving restores the committed value', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal')).toBeVisible();

    const star = page.getByTestId('review-star-input').locator('[data-reviews--star-input-target="star"]').nth(2);
    const box = (await star.boundingBox())!;
    const readout = page.getByTestId('review-rating-readout');
    for (const [quarter, text] of [[1, '2.25'], [2, '2.5'], [3, '2.75'], [4, '3']] as const) {
      await page.mouse.move(box.x + (box.width * (quarter - 0.5)) / 4, box.y + box.height / 2);
      await expect(readout).toHaveText(text);
    }

    await page.mouse.move(box.x - 200, box.y - 200);
    await expect(readout).toHaveText('Not rated');

    await rateStars(page, 3.75);
    await page.mouse.move(box.x - 200, box.y - 200);
    await expect(readout).toHaveText('3.75');
  });

  test('arrow keys step by a quarter', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').click();
    const slider = page.getByTestId('review-star-input');
    await slider.focus();
    await page.keyboard.press('End');
    await page.keyboard.press('ArrowLeft');
    await expect(slider).toHaveAttribute('aria-valuetext', '4.75 stars');
    await page.keyboard.press('PageDown');
    await expect(slider).toHaveAttribute('aria-valuetext', '3.75 stars');
  });

  test('a saved 3.75 shows exactly after saving, after reload, and when reopened', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').click();
    await rateStars(page, 3.75);
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    const fourth = page.getByTestId('review-widget-stars').getByTestId('star-fill').nth(3);
    await expect(fourth).toHaveAttribute('style', /width: 75(\.0)?%/); // server-rendered Turbo Stream path

    await page.reload();
    await expect(fourth).toHaveAttribute('style', /width: 75(\.0)?%/); // JS hydration path
    await expect(page.getByTestId('review-widget-stars').getByRole('img')).toHaveAttribute('aria-label', 'Your rating: 3.75 out of 5 stars');

    await page.getByTestId('review-widget-label').click();
    await expect(page.getByTestId('review-rating-readout')).toHaveText('3.75');
  });
});

test.describe('Quarter-star ratings on a touch screen', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test.afterEach(async ({ page }) => {
    await page.goto(BOOK);
    await removeExistingReview(page);
  });

  test('a tap sets a value and a drag adjusts it', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').tap();
    await expect(page.locator('#review_modal')).toBeVisible();

    const stars = page.getByTestId('review-star-input').locator('[data-reviews--star-input-target="star"]');
    const first = (await stars.nth(1).boundingBox())!;
    await stars.nth(1).tap({ position: { x: first.width * 0.375, y: first.height / 2 } });
    await expect(page.getByTestId('review-rating-readout')).toHaveText('1.5');

    // Drag: dispatch touch-type pointer events along the row.
    const slider = page.getByTestId('review-star-input');
    const last = (await stars.nth(3).boundingBox())!;
    const y = first.y + first.height / 2;
    await slider.dispatchEvent('pointerdown', { pointerType: 'touch', pointerId: 7, clientX: first.x + 2, clientY: y, button: 0 });
    await slider.dispatchEvent('pointermove', { pointerType: 'touch', pointerId: 7, clientX: last.x + last.width * 0.9, clientY: y });
    await slider.dispatchEvent('pointerup', { pointerType: 'touch', pointerId: 7, clientX: last.x + last.width * 0.9, clientY: y });
    await expect(page.getByTestId('review-rating-readout')).toHaveText('4');
  });
});
```

The member auth state comes from the project config, the same way `reviews-write.spec.ts` gets signed in. Check `e2e/playwright.config.ts` for which project picks up `tests/books/account/**`, and confirm the new file lands in it.

- [ ] **Step 4: Seed fractional ratings.** In `lib/tasks/e2e.rake`, change the rating line and its comment:

```ruby
      # Rating cycles 1..5 so the finished set always has exactly 6 reviews per
      # rating bucket -- e2e/tests/books/account/my-reviews.spec.ts's rating-bar-filter
      # test depends on every bucket having at least one row. Every third review is
      # a quarter under its whole star (4.75, 0.75, ...): that stays in the same
      # bucket (Review.rating_bucket) and makes the pages render fractional ratings.
      ...
        rating = (n % 5) + 1
        rating -= 0.25 if (n % 3).zero?
```

Keep the rest of the comment that is still true (resumed runs, the "Animal Farm" anchor).

- [ ] **Step 5: Update the docs**
- `docs/features/goodreads-import.md`: where `My Rating` is described, say it is read as a decimal (quarter stars since 2026-10-05; `4.0` and `3.75` both parse; 0 means unrated; unreadable values are dropped with a note). Add a short "Legacy truncation repair" paragraph: the four conditions from spec §5.4, why the weekly sync reverts it, and why the replay order makes the result correct.
- `docs/features/recommendations.md`: wherever rating thresholds are described, say they compare the exact (possibly fractional) rating, so 3.75 does not meet a threshold of 4.

- [ ] **Step 6: Full verification**

Run, from `web-app/`:

```bash
bin/rails test
bin/rails test:system
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: all green, and **no new warning lines** in the test output (AGENTS.md).

Then E2E. Confirm port 3000 belongs to this worktree (command in Task 4 Step 8), then run `yarn build:all`, `bin/rails server` and `bin/rails e2e:<the seed task that owns line 177>`. Find the task name with `grep -n "task " lib/tasks/e2e.rake`. Re-seeding rewrites only that E2E user's reviews.

```bash
yarn test:e2e e2e/tests/books/account/quarter-star-rating.spec.ts e2e/tests/books/account/reviews-write.spec.ts e2e/tests/books/account/my-reviews.spec.ts e2e/tests/books/admin/reviews.spec.ts e2e/tests/books/member/recommendations.spec.ts
```

Expected: all pass. If the member recommendations spec skips because `e2e/.env` lacks `PLAYWRIGHT_MEMBER_*` (a known gap), report that it skipped. Do not call it passing.

- [ ] **Step 7: Commit**

```bash
git add web-app/e2e web-app/lib/tasks/e2e.rake docs/features/goodreads-import.md docs/features/recommendations.md
git commit -m "Quarter-star ratings: E2E coverage, fractional seed data, docs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the plan

- The branch stays local until the owner asks for a push or a PR.
- **Merging deploys.** The migration rewrites `reviews` under a brief exclusive lock (~151k rows). Books has not launched and music/games do not read `reviews`, so the lock is safe at any hour.
- No production data step is needed for whole-number reviews. The legacy repair happens automatically on the next legacy replay pass, which already runs after each sync and in the final launch sequence.
