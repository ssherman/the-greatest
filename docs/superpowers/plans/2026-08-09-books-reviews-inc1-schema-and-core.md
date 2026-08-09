# Books Reviews — Increment 1: Schema and Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `Review` and `ReviewSummary` models, the body sanitizer, and the aggregate recalculator — the complete data layer for reviews, with no UI and no migrated data.

**Architecture:** `Review` is a global (root-namespace) model polymorphic on `reviewable`, matching `Description` / `ExternalLink` / `ListItem`. `ReviewSummary` denormalizes the rating aggregate (count, sum, per-star histogram) one row per reviewable, so a book page never aggregates over the full reviews table. `Services::Reviews::BodySanitizer` is the single implementation of body cleaning, called from `Review`'s `before_validation` and later (increment 2) directly by the migrator, which bulk-inserts and bypasses callbacks. `Services::Reviews::SummaryRecalculator` is the only writer of `review_summaries` and offers both a single-row incremental path (fired from `after_commit`) and a full set-based rebuild.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest + fixtures + Mocha, `rails-html-sanitizer` 1.7.1 (`Rails::HTML5::SafeListSanitizer`), Standard (standardrb).

**Spec:** `docs/superpowers/specs/2026-08-09-books-reviews-design.md` (commit `648cacd7`)

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Working branch is `worktree-books-reviews` in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-reviews`.
- Use Rails generators — never hand-create models. Generators create the matching test file and fixture.
- `Review` and `ReviewSummary` are **global**, root-namespace models (like `List`, `Description`, `ExternalLink`). Do not namespace them under `Books::`.
- Services live in `app/lib/services/reviews/`, **not** `app/services/`. Tests mirror at `test/lib/services/reviews/`.
- Lint with `bundle exec standardrb`. **Not** `bin/rubocop` (omakase, conflicting style). Never run brakeman.
- New migrations are `ActiveRecord::Migration[8.1]`.
- **Never run a destructive DB command against development.** A PreToolUse hook blocks `create_fixtures`, `db:drop`/`db:reset`/`db:schema:load`, and bulk deletes unless `RAILS_ENV=test` is explicit. Increment 1 adds no data to development.
- Fixture names are semantic. The ones this plan uses already exist: users `admin_user`, `regular_user`, `editor_user`; books `war_and_peace`, `crime_and_punishment`.
- Polymorphic fixtures use the `reviewable: war_and_peace (Books::Book)` form. Never set `_type` manually.
- `MAX_BODY_LENGTH` is **25,000** characters, enforced as a model validation. The sanitizer does **not** truncate — a user pasting 30,000 characters must get a validation error, not silent data loss. (Increment 2's migrator applies the cap by dropping the body, because there is no user to show an error to.)
- Sanitizer allowlist, exactly: tags `p br a i b em strong blockquote`, attributes `href title`.
- Run `bundle exec annotaterb models` after any migration so schema annotations stay current.

---

### Task 1: `Services::Reviews::BodySanitizer`

A pure service with no database access. Cleans a review body: strips unsafe markup, converts `<spoiler>` tags to safe markup, and normalizes anything that ends up blank to `nil`.

**Files:**
- Create: `web-app/app/lib/services/reviews/body_sanitizer.rb`
- Test: `web-app/test/lib/services/reviews/body_sanitizer_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Services::Reviews::BodySanitizer.call(body) -> String | nil`. Returns `nil` for nil, blank, or any input that sanitizes down to nothing. Returns sanitized HTML otherwise. Never truncates.

> **Do not use string tokenization for spoilers.** An earlier revision of this plan tokenized `<spoiler>...</spoiler>` into a random alphanumeric marker, sanitized, then string-substituted the marker back into `<span class="review-spoiler">`. It is broken, and the Task 1 reviewer reproduced it: the marker is plain alphanumerics precisely so that it survives sanitizing, and that same property lets it survive **inside an attribute value**, where the restore step splices raw markup into a quoted string.
>
> `<a href="<spoiler>evil</spoiler>">click</a>` came out as `<a href="<span class="review-spoiler">evil</span>">click</a>` -- malformed HTML that a browser re-parses into a bogus `href`, a spurious `review-spoiler""` attribute, and visible link text of `evil">click`. Do not reintroduce this approach.

> **Let the HTML parser decide what a real `<spoiler>` element is.** Allowlist `spoiler` as a tag for the sanitize pass, then walk the resulting fragment and rename those nodes to `span.review-spoiler`. Text that merely *looks* like a spoiler tag inside an attribute value is escaped by the parser and never becomes a node, which closes the injection hole at its root. Verified: the attack strings above survive as inert escaped text with `href` and link text intact.
>
> Renaming after sanitizing is also what stops a user supplying their own `class` -- `span` is not in `ALLOWED_TAGS`, so a user-written `<span class="review-spoiler">` is stripped, and a `class` on their own `<spoiler>` is replaced with ours. `.presence` must still come last, because `<img src=...>` is non-blank going in but sanitizes to `""`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/reviews/body_sanitizer_test.rb`:

```ruby
require "test_helper"

module Services
  module Reviews
    class BodySanitizerTest < ActiveSupport::TestCase
      test ".call returns nil for nil" do
        assert_nil BodySanitizer.call(nil)
      end

      test ".call returns nil for an empty string" do
        assert_nil BodySanitizer.call("")
      end

      test ".call returns nil for a whitespace-only body" do
        assert_nil BodySanitizer.call("   \n\t  ")
      end

      test ".call keeps allowed formatting tags" do
        body = "<p>A <i>great</i> <b>book</b>, <strong>truly</strong>.</p><blockquote>Quoted.</blockquote>"
        assert_equal body, BodySanitizer.call(body)
      end

      test ".call normalizes br tags and keeps them" do
        assert_equal "one<br>two", BodySanitizer.call("one<br/>two")
      end

      test ".call strips script tags" do
        result = BodySanitizer.call("safe <script>alert('xss')</script>")
        assert_not_includes result, "<script"
      end

      test ".call strips iframe, style and input tags" do
        result = BodySanitizer.call(
          "<iframe src='https://evil.test'></iframe><style>body{}</style><input value='x'>text"
        )
        assert_not_includes result, "<iframe"
        assert_not_includes result, "<style"
        assert_not_includes result, "<input"
        assert_includes result, "text"
      end

      test ".call returns nil when the body is only an image" do
        assert_nil BodySanitizer.call(%(<img src="https://example.test/cover.png">))
      end

      test ".call scrubs a javascript href but keeps a real link" do
        result = BodySanitizer.call(
          %(<a href="javascript:alert(1)">bad</a> <a href="https://example.test" title="t">good</a>)
        )
        assert_not_includes result, "javascript:"
        assert_includes result, %(<a href="https://example.test" title="t">good</a>)
      end

      test ".call strips a user-supplied span and its class" do
        result = BodySanitizer.call(%(<span class="review-spoiler">not really a spoiler</span>))
        assert_not_includes result, "<span"
        assert_includes result, "not really a spoiler"
      end

      test ".call converts a spoiler tag to a safe span" do
        assert_equal %(before <span class="review-spoiler">the butler did it</span> after),
          BodySanitizer.call("before <spoiler>the butler did it</spoiler> after")
      end

      test ".call converts multiple spoiler tags" do
        assert_equal %(<span class="review-spoiler">one</span> and <span class="review-spoiler">two</span>),
          BodySanitizer.call("<spoiler>one</spoiler> and <spoiler>two</spoiler>")
      end

      test ".call ignores attributes on a spoiler tag" do
        assert_equal %(<span class="review-spoiler">y</span>),
          BodySanitizer.call(%(<spoiler onclick="bad()">y</spoiler>))
      end

      test ".call closes an unclosed spoiler tag" do
        assert_equal %(<span class="review-spoiler">never closed</span>),
          BodySanitizer.call("<spoiler>never closed")
      end

      test ".call converts nested spoiler tags" do
        assert_equal %(<span class="review-spoiler">a<span class="review-spoiler">b</span>c</span>),
          BodySanitizer.call("<spoiler>a<spoiler>b</spoiler>c</spoiler>")
      end

      test ".call replaces a class supplied on a spoiler tag" do
        assert_equal %(<span class="review-spoiler">x</span>),
          BodySanitizer.call(%(<spoiler class="evil">x</spoiler>))
      end

      # Regression: a string-tokenizing implementation spliced raw markup into the
      # quoted attribute value here, producing malformed HTML.
      test ".call does not splice markup into an href attribute value" do
        result = BodySanitizer.call(%(<a href="<spoiler>evil</spoiler>">click</a>))
        assert_not_includes result, "<span"

        anchor = Nokogiri::HTML5.fragment(result).at_css("a")
        assert_equal "<spoiler>evil</spoiler>", anchor["href"]
        assert_equal "click", anchor.text
        assert_equal ["href"], anchor.attributes.keys
      end

      test ".call does not splice markup into a title attribute value" do
        result = BodySanitizer.call(%(<a title="<spoiler>y</spoiler>">link</a>))
        assert_not_includes result, "<span"

        anchor = Nokogiri::HTML5.fragment(result).at_css("a")
        assert_equal "<spoiler>y</spoiler>", anchor["title"]
        assert_equal "link", anchor.text
      end

      test ".call strips an event handler smuggled past a spoiler tag" do
        result = BodySanitizer.call(
          %(<a title="<spoiler>x" onmouseover="alert(1)" y="</spoiler>">link</a>)
        )
        assert_not_includes result, "onmouseover"
        assert_not_includes result, "alert(1)"
      end

      test ".call does not truncate long bodies" do
        body = "a" * 30_000
        assert_equal 30_000, BodySanitizer.call(body).length
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Reviews::BodySanitizer`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/reviews/body_sanitizer.rb`:

```ruby
module Services
  module Reviews
    # Single implementation of review-body cleaning. Called from Review's
    # before_validation and directly by the increment-2 migrator, which bulk-inserts
    # and so bypasses callbacks.
    #
    # Spoilers are resolved by the HTML parser, never by string substitution. `spoiler`
    # is allowlisted for the sanitize pass so a genuine <spoiler> becomes a real node,
    # then those nodes are renamed. Text that merely looks like a spoiler tag inside an
    # attribute value is escaped by the parser and never becomes a node.
    #
    # Do NOT go back to tokenizing the string and substituting after sanitizing. Any
    # marker robust enough to survive sanitizing also survives inside an attribute
    # value, so the substitution splices raw markup into a quoted string:
    # `<a href="<spoiler>evil</spoiler>">click</a>` became
    # `<a href="<span class="review-spoiler">evil</span>">click</a>`, which a browser
    # re-parses into a bogus href and visible link text of `evil">click`.
    #
    # Renaming after sanitizing is also what stops a user supplying their own class:
    # `span` is not in ALLOWED_TAGS, so a user-written <span class="review-spoiler"> is
    # stripped, and a class on their own <spoiler> is replaced with ours.
    #
    # .presence comes last -- an <img>-only body is non-blank on input but sanitizes
    # to "".
    #
    # Does not truncate. Length is a Review validation, so an over-long paste raises a
    # user-visible error instead of losing text.
    class BodySanitizer
      ALLOWED_TAGS = %w[p br a i b em strong blockquote].freeze
      ALLOWED_ATTRIBUTES = %w[href title].freeze
      SPOILER_TAG = "spoiler".freeze
      SPOILER_CLASS = "review-spoiler".freeze

      def self.call(body)
        new(body).call
      end

      def initialize(body)
        @body = body
      end

      def call
        return nil if @body.blank?

        sanitized = sanitizer.sanitize(
          @body.to_s,
          tags: ALLOWED_TAGS + [SPOILER_TAG],
          attributes: ALLOWED_ATTRIBUTES
        ).to_s

        convert_spoilers(sanitized).presence
      end

      private

      def sanitizer
        @sanitizer ||= Rails::HTML5::SafeListSanitizer.new
      end

      def convert_spoilers(html)
        fragment = Nokogiri::HTML5.fragment(html)
        fragment.css(SPOILER_TAG).each do |node|
          node.name = "span"
          node.remove_attribute("class")
          node["class"] = SPOILER_CLASS
        end
        fragment.to_html
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/reviews/body_sanitizer_test.rb`
Expected: PASS, 20 runs, 0 failures

- [ ] **Step 5: Lint**

Run: `bundle exec standardrb app/lib/services/reviews/body_sanitizer.rb test/lib/services/reviews/body_sanitizer_test.rb`
Expected: no offenses. If any, run the same command with `--fix`.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/services/reviews/body_sanitizer.rb web-app/test/lib/services/reviews/body_sanitizer_test.rb
git commit -m "Add Services::Reviews::BodySanitizer"
```

---

### Task 2: `reviews` table and `Review` model

**Files:**
- Create: `web-app/db/migrate/<timestamp>_create_reviews.rb` (generated)
- Create: `web-app/app/models/review.rb` (generated, then rewritten)
- Create: `web-app/test/models/review_test.rb` (generated, then rewritten)
- Create: `web-app/test/fixtures/reviews.yml` (generated, then rewritten)
- Modify: `web-app/app/models/books/book.rb` — add two associations after the existing `has_many :external_links` line
- Modify: `web-app/app/models/user.rb` — add one association after the existing `has_many :saved_searches` line
- Modify: `web-app/db/schema.rb` (by migration)

**Interfaces:**
- Consumes: `Services::Reviews::BodySanitizer.call(body)` from Task 1.
- Produces:
  - `Review::MAX_BODY_LENGTH = 25_000`
  - `Review` with `belongs_to :user`, `belongs_to :reviewable, polymorphic: true`
  - scopes `Review.with_body`, `Review.by_rating`, `Review.recent`
  - `Books::Book#reviews`, `User#reviews`
  - fixtures `reviews(:regular_user_war_and_peace)`, `reviews(:editor_user_war_and_peace)`, `reviews(:admin_user_war_and_peace)`, `reviews(:regular_user_crime_and_punishment)`

> **Fixture arithmetic that Task 3 and Task 4 depend on.** `war_and_peace`: 3 ratings, sum 13, 2 with text, one ★5 and two ★4. `crime_and_punishment`: 1 rating, sum 3, 0 with text, one ★3. Task 3's `review_summaries.yml` must match these exactly.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Review user:references 'reviewable:references{polymorphic}' title:string body:text rating:integer
```

This creates the migration, `app/models/review.rb`, `test/models/review_test.rb` and `test/fixtures/reviews.yml`.

- [ ] **Step 2: Rewrite the generated migration**

Replace the generated `db/migrate/<timestamp>_create_reviews.rb` with:

```ruby
class CreateReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :reviews do |t|
      # index: false -- the composite unique index below and the [user_id, created_at]
      # index both lead with user_id, so a standalone user_id index is redundant.
      t.references :user, null: false, foreign_key: true, index: false
      t.references :reviewable, polymorphic: true, null: false
      t.string :title
      t.text :body
      t.integer :rating, null: false

      t.timestamps
    end

    # One review per user per item. Also the ON CONFLICT arbiter candidate for the
    # increment-2 migrator -- see that plan, which must use an UNTARGETED
    # ON CONFLICT DO NOTHING because preserved ids make the primary key a second
    # colliding constraint.
    add_index :reviews, [:user_id, :reviewable_type, :reviewable_id],
      unique: true, name: "index_reviews_on_user_and_reviewable"

    # The book page lists only reviews that have text (12.6% of rows), so the
    # partial index is a fraction of the size of a full one.
    add_index :reviews, [:reviewable_type, :reviewable_id],
      where: "body IS NOT NULL", name: "index_reviews_on_reviewable_with_body"

    # /my/reviews default sort (increment 5).
    add_index :reviews, [:user_id, :created_at]

    add_check_constraint :reviews, "rating BETWEEN 1 AND 5", name: "reviews_rating_range"

    # Legacy stored 5,177 empty-string bodies that slipped through
    # `where.not(body: nil)` and rendered as blank review cards. This makes an empty
    # body unrepresentable, so `with_body` means what it says. Multi-arg btrim because
    # single-arg btrim only trims ASCII spaces, leaving "\t\n" satisfying the check
    # while being .blank? in Ruby.
    add_check_constraint :reviews,
      "body IS NULL OR length(btrim(body, E' \\t\\n\\r\\f\\v')) > 0",
      name: "reviews_body_not_blank"
  end
end
```

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
bundle exec annotaterb models
```

Expected: `db/schema.rb` gains a `reviews` table; `app/models/review.rb` gains a schema annotation comment.

- [ ] **Step 4: Write the fixtures**

Replace `web-app/test/fixtures/reviews.yml` with:

```yaml
# war_and_peace: 3 ratings, sum 13, 2 with text (one ★5, two ★4).
# crime_and_punishment: 1 rating, sum 3, 0 with text (one ★3).
# review_summaries.yml mirrors these numbers exactly -- keep them in step.

regular_user_war_and_peace:
  user: regular_user
  reviewable: war_and_peace (Books::Book)
  rating: 5
  title: A monumental achievement
  body: <p>Worth every one of its twelve hundred pages.</p>

editor_user_war_and_peace:
  user: editor_user
  reviewable: war_and_peace (Books::Book)
  rating: 4
  body: <p>Skip the philosophy chapters on a first read.</p>

admin_user_war_and_peace:
  user: admin_user
  reviewable: war_and_peace (Books::Book)
  rating: 4

regular_user_crime_and_punishment:
  user: regular_user
  reviewable: crime_and_punishment (Books::Book)
  rating: 3
```

- [ ] **Step 5: Write the failing test**

Replace `web-app/test/models/review_test.rb` with:

```ruby
require "test_helper"

class ReviewTest < ActiveSupport::TestCase
  test "belongs to a polymorphic reviewable" do
    assert_equal Books::Book, reviews(:regular_user_war_and_peace).reviewable.class
  end

  test "belongs to a user" do
    assert_equal users(:regular_user), reviews(:regular_user_war_and_peace).user
  end

  test "requires a rating" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got))
    assert_not review.valid?
    assert_includes review.errors[:rating], "can't be blank"
  end

  test "rejects a rating below 1" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 0)
    assert_not review.valid?
  end

  test "rejects a rating above 5" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 6)
    assert_not review.valid?
  end

  test "accepts a rating with no body or title" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4)
    assert review.valid?
  end

  test "sanitizes the body before validation" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: "good <script>alert('xss')</script>"
    )
    review.valid?
    assert_not_includes review.body, "<script"
  end

  test "normalizes a whitespace-only body to nil" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: "   "
    )
    review.valid?
    assert_nil review.body
  end

  test "normalizes an image-only body to nil" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: %(<img src="https://example.test/x.png">)
    )
    review.valid?
    assert_nil review.body
  end

  test "normalizes a blank title to nil" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4, title: "  "
    )
    review.valid?
    assert_nil review.title
  end

  test "rejects a body longer than MAX_BODY_LENGTH" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: "a" * (Review::MAX_BODY_LENGTH + 1)
    )
    assert_not review.valid?
    assert_includes review.errors[:body], "is too long (maximum is 25000 characters)"
  end

  test "allows a body exactly at MAX_BODY_LENGTH" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: "a" * Review::MAX_BODY_LENGTH
    )
    assert review.valid?
  end

  test "allows one review per user per reviewable" do
    duplicate = Review.new(
      user: users(:regular_user),
      reviewable: reviews(:regular_user_war_and_peace).reviewable,
      rating: 2
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "allows the same user to review a different book" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 2)
    assert review.valid?
  end

  test "with_body returns only reviews that have text" do
    book = books_books(:war_and_peace)
    assert_equal 2, Review.where(reviewable: book).with_body.count
  end

  test "by_rating orders highest first" do
    ratings = Review.where(reviewable: books_books(:war_and_peace)).by_rating.pluck(:rating)
    assert_equal [5, 4, 4], ratings
  end

  test "recent orders newest first" do
    book = books_books(:got)
    older = Review.create!(user: users(:regular_user), reviewable: book, rating: 3,
      created_at: 2.days.ago)
    newer = Review.create!(user: users(:admin_user), reviewable: book, rating: 4,
      created_at: 1.hour.ago)

    assert_equal [newer.id, older.id], Review.where(reviewable: book).recent.pluck(:id)
  end

  test "the database rejects an empty-string body" do
    review = reviews(:admin_user_war_and_peace)
    assert_raises(ActiveRecord::StatementInvalid) do
      Review.where(id: review.id).update_all(body: "")
    end
  end

  test "the database rejects an out-of-range rating" do
    review = reviews(:admin_user_war_and_peace)
    assert_raises(ActiveRecord::StatementInvalid) do
      Review.where(id: review.id).update_all(rating: 9)
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/review_test.rb`
Expected: FAIL — `NameError: uninitialized constant Review::MAX_BODY_LENGTH` and validation failures.

- [ ] **Step 7: Write the model**

Replace the body of `web-app/app/models/review.rb` (keep the schema annotation block that `annotaterb` added above the class):

```ruby
class Review < ApplicationRecord
  # Generous enough that no legitimate legacy review is affected -- the longest is
  # 20,030 characters -- while catching the one 462KB XSS-fuzz paste. Enforced as a
  # validation, not by the sanitizer, so an over-long paste is a user-visible error
  # rather than silent data loss.
  MAX_BODY_LENGTH = 25_000

  belongs_to :user
  belongs_to :reviewable, polymorphic: true

  normalizes :title, with: ->(value) { value.presence }

  before_validation :sanitize_body

  validates :rating, presence: true, numericality: {
    only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5
  }
  validates :body, length: {maximum: MAX_BODY_LENGTH}
  validates :user_id, uniqueness: {scope: [:reviewable_type, :reviewable_id]}

  # Honest only because the sanitizer and the reviews_body_not_blank check constraint
  # make an empty-string body unrepresentable. Legacy's identical scope returned 5,177
  # empty-string bodies that rendered as blank review cards.
  scope :with_body, -> { where.not(body: nil) }
  scope :by_rating, -> { order(rating: :desc) }
  scope :recent, -> { order(created_at: :desc) }

  private

  def sanitize_body
    self.body = Services::Reviews::BodySanitizer.call(body)
  end
end
```

- [ ] **Step 8: Add the associations**

In `web-app/app/models/books/book.rb`, immediately after the `has_many :external_links, as: :parent, dependent: :destroy` line:

```ruby
  has_many :reviews, as: :reviewable, dependent: :destroy
```

In `web-app/app/models/user.rb`, immediately after the `has_many :saved_searches, dependent: :destroy` line:

```ruby
  has_many :reviews, dependent: :destroy
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bin/rails test test/models/review_test.rb`
Expected: PASS, 19 runs, 0 failures

- [ ] **Step 10: Run the full suite to check for fixture fallout**

Run: `bin/rails test`
Expected: PASS. Adding `reviews.yml` loads new fixture rows into every test; a failure here means another test counts rows on a table this touches.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb app/models/review.rb app/models/books/book.rb app/models/user.rb test/models/review_test.rb db/migrate
git add web-app/db/migrate web-app/db/schema.rb web-app/app/models/review.rb web-app/app/models/books/book.rb web-app/app/models/user.rb web-app/test/models/review_test.rb web-app/test/fixtures/reviews.yml
git commit -m "Add the reviews table and Review model"
```

---

### Task 3: `review_summaries` table and `ReviewSummary` model

**Files:**
- Create: `web-app/db/migrate/<timestamp>_create_review_summaries.rb` (generated)
- Create: `web-app/app/models/review_summary.rb` (generated, then rewritten)
- Create: `web-app/test/models/review_summary_test.rb` (generated, then rewritten)
- Create: `web-app/test/fixtures/review_summaries.yml` (generated, then rewritten)
- Modify: `web-app/app/models/books/book.rb` — add one association below the `has_many :reviews` line from Task 2

**Interfaces:**
- Consumes: the fixture arithmetic established in Task 2.
- Produces:
  - `ReviewSummary#average_rating -> Float | nil`
  - `ReviewSummary#rating_counts -> Hash{Integer => Integer}` keyed 1..5
  - `ReviewSummary#rating_percentage(rating) -> Float`
  - `Books::Book#review_summary`
  - fixtures `review_summaries(:war_and_peace)`, `review_summaries(:crime_and_punishment)`

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model ReviewSummary 'reviewable:references{polymorphic}' ratings_count:integer ratings_sum:integer text_reviews_count:integer rating_1_count:integer rating_2_count:integer rating_3_count:integer rating_4_count:integer rating_5_count:integer
```

- [ ] **Step 2: Rewrite the generated migration**

Replace `db/migrate/<timestamp>_create_review_summaries.rb` with:

```ruby
class CreateReviewSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :review_summaries do |t|
      # index: false -- the unique index below covers the same columns.
      t.references :reviewable, polymorphic: true, null: false, index: false
      t.integer :ratings_count, null: false, default: 0
      t.integer :ratings_sum, null: false, default: 0
      t.integer :text_reviews_count, null: false, default: 0
      t.integer :rating_1_count, null: false, default: 0
      t.integer :rating_2_count, null: false, default: 0
      t.integer :rating_3_count, null: false, default: 0
      t.integer :rating_4_count, null: false, default: 0
      t.integer :rating_5_count, null: false, default: 0

      t.timestamps
    end

    # Unique, and the ON CONFLICT arbiter for SummaryRecalculator's upserts.
    add_index :review_summaries, [:reviewable_type, :reviewable_id],
      unique: true, name: "index_review_summaries_on_reviewable"
  end
end
```

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
bundle exec annotaterb models
```

- [ ] **Step 4: Write the fixtures**

Replace `web-app/test/fixtures/review_summaries.yml` with:

```yaml
# Mirrors reviews.yml exactly. Fixtures are inserted directly and never fire
# after_commit, so these numbers are maintained by hand -- keep them in step with
# reviews.yml or SummaryRecalculator's tests will disagree with the fixtures.

war_and_peace:
  reviewable: war_and_peace (Books::Book)
  ratings_count: 3
  ratings_sum: 13
  text_reviews_count: 2
  rating_1_count: 0
  rating_2_count: 0
  rating_3_count: 0
  rating_4_count: 2
  rating_5_count: 1

crime_and_punishment:
  reviewable: crime_and_punishment (Books::Book)
  ratings_count: 1
  ratings_sum: 3
  text_reviews_count: 0
  rating_1_count: 0
  rating_2_count: 0
  rating_3_count: 1
  rating_4_count: 0
  rating_5_count: 0
```

- [ ] **Step 5: Write the failing test**

Replace `web-app/test/models/review_summary_test.rb` with:

```ruby
require "test_helper"

class ReviewSummaryTest < ActiveSupport::TestCase
  test "belongs to a polymorphic reviewable" do
    assert_equal Books::Book, review_summaries(:war_and_peace).reviewable.class
  end

  test "average_rating divides the sum by the count" do
    assert_in_delta 4.333, review_summaries(:war_and_peace).average_rating, 0.001
  end

  test "average_rating is nil when there are no ratings" do
    assert_nil ReviewSummary.new(ratings_count: 0, ratings_sum: 0).average_rating
  end

  test "rating_counts returns a hash keyed 1 through 5" do
    assert_equal({1 => 0, 2 => 0, 3 => 0, 4 => 2, 5 => 1},
      review_summaries(:war_and_peace).rating_counts)
  end

  test "rating_percentage returns the share of ratings at that star" do
    assert_in_delta 66.667, review_summaries(:war_and_peace).rating_percentage(4), 0.001
    assert_in_delta 33.333, review_summaries(:war_and_peace).rating_percentage(5), 0.001
    assert_in_delta 0.0, review_summaries(:war_and_peace).rating_percentage(1), 0.001
  end

  test "rating_percentage returns zero when there are no ratings" do
    assert_in_delta 0.0, ReviewSummary.new(ratings_count: 0).rating_percentage(5), 0.001
  end

  test "a book reaches its summary through the association" do
    assert_equal review_summaries(:war_and_peace), books_books(:war_and_peace).review_summary
  end
end
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/review_summary_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'average_rating'`

- [ ] **Step 7: Write the model**

Replace the body of `web-app/app/models/review_summary.rb` (keep the annotation block):

```ruby
# Denormalized rating aggregate, one row per reviewable. Written only by
# Services::Reviews::SummaryRecalculator -- never assign these counters directly.
#
# The average is derived rather than stored, so it can never drift from the counts
# it summarizes.
class ReviewSummary < ApplicationRecord
  belongs_to :reviewable, polymorphic: true

  def average_rating
    return nil if ratings_count.to_i.zero?

    ratings_sum.to_f / ratings_count
  end

  def rating_counts
    {
      1 => rating_1_count,
      2 => rating_2_count,
      3 => rating_3_count,
      4 => rating_4_count,
      5 => rating_5_count
    }
  end

  def rating_percentage(rating)
    return 0.0 if ratings_count.to_i.zero?

    (rating_counts.fetch(rating).to_f / ratings_count) * 100
  end
end
```

- [ ] **Step 8: Add the association**

In `web-app/app/models/books/book.rb`, immediately after the `has_many :reviews, as: :reviewable, dependent: :destroy` line added in Task 2:

```ruby
  has_one :review_summary, as: :reviewable, dependent: :destroy
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bin/rails test test/models/review_summary_test.rb`
Expected: PASS, 7 runs, 0 failures

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb app/models/review_summary.rb app/models/books/book.rb test/models/review_summary_test.rb db/migrate
git add web-app/db/migrate web-app/db/schema.rb web-app/app/models/review_summary.rb web-app/app/models/books/book.rb web-app/test/models/review_summary_test.rb web-app/test/fixtures/review_summaries.yml
git commit -m "Add the review_summaries table and ReviewSummary model"
```

---

### Task 4: `Services::Reviews::SummaryRecalculator` and the `after_commit` wiring

The only writer of `review_summaries`. Two paths — a single-row incremental update fired from `Review`'s `after_commit`, and a full set-based rebuild — that are required to produce identical results.

**Files:**
- Create: `web-app/app/lib/services/reviews/summary_recalculator.rb`
- Create: `web-app/test/lib/services/reviews/summary_recalculator_test.rb`
- Modify: `web-app/app/models/review.rb` — add the `after_commit` callback and its private method
- Modify: `web-app/test/models/review_test.rb` — add one callback test

**Interfaces:**
- Consumes: `Review` (Task 2), `ReviewSummary` (Task 3).
- Produces:
  - `Services::Reviews::SummaryRecalculator.recalculate(reviewable_type, reviewable_id) -> void`
  - `Services::Reviews::SummaryRecalculator.backfill_all! -> Integer` (number of summary rows after the rebuild)

> **The invariant both paths must honour: a summary row exists if and only if at least one review exists for that reviewable.** `recalculate` deletes the row when the last review goes; `backfill_all!` prunes orphans after upserting. Without the prune the two paths disagree the moment a review is destroyed, and the "they agree" test is the thing that catches it.

> **Pass type and id, not the object.** The callback fires on destroy too, where the `reviewable` association may no longer load from a frozen record. `reviewable_type` and `reviewable_id` are plain attributes and always readable.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/reviews/summary_recalculator_test.rb`:

```ruby
require "test_helper"

module Services
  module Reviews
    class SummaryRecalculatorTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:got)
      end

      def summary_for(book)
        ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
      end

      def recalculate(book)
        SummaryRecalculator.recalculate("Books::Book", book.id)
      end

      test ".recalculate creates a summary row from existing reviews" do
        Review.create!(user: users(:regular_user), reviewable: @book, rating: 5, body: "<p>Yes.</p>")
        Review.create!(user: users(:admin_user), reviewable: @book, rating: 3)

        recalculate(@book)
        summary = summary_for(@book)

        assert_equal 2, summary.ratings_count
        assert_equal 8, summary.ratings_sum
        assert_equal 1, summary.text_reviews_count
        assert_equal 1, summary.rating_3_count
        assert_equal 1, summary.rating_5_count
        assert_equal 0, summary.rating_1_count
      end

      test ".recalculate updates an existing summary row" do
        book = books_books(:war_and_peace)
        Review.create!(user: users(:password_user), reviewable: book, rating: 1)

        recalculate(book)
        summary = summary_for(book)

        assert_equal 4, summary.ratings_count
        assert_equal 14, summary.ratings_sum
        assert_equal 1, summary.rating_1_count
      end

      test ".recalculate deletes the row when the last review is gone" do
        review = Review.create!(user: users(:regular_user), reviewable: @book, rating: 4)
        recalculate(@book)
        assert_not_nil summary_for(@book)

        review.destroy!
        recalculate(@book)
        assert_nil summary_for(@book)
      end

      test ".recalculate is idempotent" do
        Review.create!(user: users(:regular_user), reviewable: @book, rating: 4)
        recalculate(@book)
        recalculate(@book)

        assert_equal 1, ReviewSummary.where(reviewable_type: "Books::Book", reviewable_id: @book.id).count
        assert_equal 1, summary_for(@book).ratings_count
      end

      test ".backfill_all! rebuilds every summary from the reviews table" do
        ReviewSummary.delete_all
        SummaryRecalculator.backfill_all!

        summary = summary_for(books_books(:war_and_peace))
        assert_equal 3, summary.ratings_count
        assert_equal 13, summary.ratings_sum
        assert_equal 2, summary.text_reviews_count
        assert_equal 2, summary.rating_4_count
        assert_equal 1, summary.rating_5_count
      end

      test ".backfill_all! prunes summaries whose reviews are gone" do
        Review.where(reviewable: books_books(:crime_and_punishment)).delete_all
        SummaryRecalculator.backfill_all!

        assert_nil summary_for(books_books(:crime_and_punishment))
      end

      test ".backfill_all! returns the number of summary rows" do
        ReviewSummary.delete_all
        assert_equal 2, SummaryRecalculator.backfill_all!
      end

      test "incremental recalculation and a full backfill agree" do
        Review.create!(user: users(:password_user), reviewable: @book, rating: 2, body: "<p>No.</p>")
        Review.create!(user: users(:google_user), reviewable: @book, rating: 5)
        Review.where(reviewable: books_books(:crime_and_punishment)).delete_all

        columns = %w[reviewable_type reviewable_id ratings_count ratings_sum text_reviews_count
          rating_1_count rating_2_count rating_3_count rating_4_count rating_5_count]

        ReviewSummary.delete_all
        Review.distinct.pluck(:reviewable_type, :reviewable_id).each do |type, id|
          SummaryRecalculator.recalculate(type, id)
        end
        incremental = ReviewSummary.order(:reviewable_type, :reviewable_id).pluck(*columns)

        ReviewSummary.delete_all
        SummaryRecalculator.backfill_all!
        backfilled = ReviewSummary.order(:reviewable_type, :reviewable_id).pluck(*columns)

        assert_equal incremental, backfilled
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/reviews/summary_recalculator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Reviews::SummaryRecalculator`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/reviews/summary_recalculator.rb`:

```ruby
module Services
  module Reviews
    # The only writer of review_summaries. Two paths that must agree:
    #
    #   .recalculate(type, id) -- one row, fired from Review#after_commit.
    #   .backfill_all!         -- full set-based rebuild, used after the increment-2
    #                             migration (which bulk-inserts and so never fires the
    #                             callback) and exposed as a rake task.
    #
    # Invariant: a summary row exists iff at least one review exists for that
    # reviewable. recalculate deletes when the last review goes; backfill_all! prunes
    # orphans after upserting. Drop either half and the two paths diverge.
    class SummaryRecalculator
      AGGREGATES = <<~SQL.freeze
        COUNT(*),
        COALESCE(SUM(rating), 0),
        COUNT(*) FILTER (WHERE body IS NOT NULL),
        COUNT(*) FILTER (WHERE rating = 1),
        COUNT(*) FILTER (WHERE rating = 2),
        COUNT(*) FILTER (WHERE rating = 3),
        COUNT(*) FILTER (WHERE rating = 4),
        COUNT(*) FILTER (WHERE rating = 5),
        NOW(), NOW()
      SQL

      COLUMNS = <<~SQL.freeze
        reviewable_type, reviewable_id,
        ratings_count, ratings_sum, text_reviews_count,
        rating_1_count, rating_2_count, rating_3_count, rating_4_count, rating_5_count,
        created_at, updated_at
      SQL

      ON_CONFLICT = <<~SQL.freeze
        ON CONFLICT (reviewable_type, reviewable_id) DO UPDATE SET
          ratings_count      = EXCLUDED.ratings_count,
          ratings_sum        = EXCLUDED.ratings_sum,
          text_reviews_count = EXCLUDED.text_reviews_count,
          rating_1_count     = EXCLUDED.rating_1_count,
          rating_2_count     = EXCLUDED.rating_2_count,
          rating_3_count     = EXCLUDED.rating_3_count,
          rating_4_count     = EXCLUDED.rating_4_count,
          rating_5_count     = EXCLUDED.rating_5_count,
          updated_at         = NOW()
      SQL

      def self.recalculate(reviewable_type, reviewable_id)
        new.recalculate(reviewable_type, reviewable_id)
      end

      def self.backfill_all!
        new.backfill_all!
      end

      def recalculate(reviewable_type, reviewable_id)
        scope = ReviewSummary.where(reviewable_type: reviewable_type, reviewable_id: reviewable_id)

        ReviewSummary.transaction do
          if Review.where(reviewable_type: reviewable_type, reviewable_id: reviewable_id).exists?
            connection.execute(upsert_one_sql(reviewable_type, reviewable_id))
          else
            scope.delete_all
          end
        end
      end

      def backfill_all!
        ReviewSummary.transaction do
          connection.execute(upsert_all_sql)
          connection.execute(prune_sql)
        end

        ReviewSummary.count
      end

      private

      def connection
        ReviewSummary.connection
      end

      def upsert_one_sql(reviewable_type, reviewable_id)
        ReviewSummary.sanitize_sql_array([<<~SQL, type: reviewable_type, id: reviewable_id])
          INSERT INTO review_summaries (#{COLUMNS})
          SELECT :type, :id, #{AGGREGATES}
          FROM reviews
          WHERE reviewable_type = :type AND reviewable_id = :id
          #{ON_CONFLICT}
        SQL
      end

      def upsert_all_sql
        <<~SQL
          INSERT INTO review_summaries (#{COLUMNS})
          SELECT reviewable_type, reviewable_id, #{AGGREGATES}
          FROM reviews
          GROUP BY reviewable_type, reviewable_id
          #{ON_CONFLICT}
        SQL
      end

      def prune_sql
        <<~SQL
          DELETE FROM review_summaries s
          WHERE NOT EXISTS (
            SELECT 1 FROM reviews r
            WHERE r.reviewable_type = s.reviewable_type
              AND r.reviewable_id = s.reviewable_id
          )
        SQL
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/reviews/summary_recalculator_test.rb`
Expected: PASS, 8 runs, 0 failures

- [ ] **Step 5: Wire the callback into `Review`**

In `web-app/app/models/review.rb`, add below the `scope :recent` line:

```ruby
  # Bulk paths (the increment-2 migrator) bypass this by design and call
  # SummaryRecalculator.backfill_all! once at the end instead.
  after_commit :recalculate_summary
```

and add to the `private` section, below `sanitize_body`:

```ruby
  # Type and id rather than the object: this fires on destroy too, where the
  # association may no longer load from a frozen record.
  def recalculate_summary
    Services::Reviews::SummaryRecalculator.recalculate(reviewable_type, reviewable_id)
  end
```

- [ ] **Step 6: Add the callback test**

Append to `web-app/test/models/review_test.rb`, inside the class:

```ruby
  test "creating a review refreshes the summary" do
    book = books_books(:got)
    Review.create!(user: users(:regular_user), reviewable: book, rating: 5)

    summary = ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
    assert_equal 1, summary.ratings_count
    assert_equal 5, summary.ratings_sum
  end

  test "destroying a review refreshes the summary" do
    review = reviews(:admin_user_war_and_peace)
    book = review.reviewable
    review.destroy!

    summary = ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
    assert_equal 2, summary.ratings_count
    assert_equal 9, summary.ratings_sum
    assert_equal 1, summary.rating_4_count
  end
```

- [ ] **Step 7: Run both test files**

Run: `bin/rails test test/models/review_test.rb test/lib/services/reviews/summary_recalculator_test.rb`
Expected: PASS, 29 runs, 0 failures

- [ ] **Step 8: Run the full suite**

Run: `bin/rails test`
Expected: PASS. The `after_commit` now fires for every `Review` written anywhere in the suite.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/lib/services/reviews app/models/review.rb test/lib/services/reviews test/models/review_test.rb
git add web-app/app/lib/services/reviews/summary_recalculator.rb web-app/app/models/review.rb web-app/test/lib/services/reviews/summary_recalculator_test.rb web-app/test/models/review_test.rb
git commit -m "Add Services::Reviews::SummaryRecalculator and wire it to Review"
```

---

## Increment 1 Definition of Done

- [ ] `bin/rails test` passes with no failures
- [ ] `bundle exec standardrb` reports no offenses across the repo
- [ ] `db/schema.rb` contains `reviews` and `review_summaries` with every index and check constraint listed above
- [ ] No development data was created or destroyed — increment 1 touches the test database only

## What increment 1 deliberately leaves out

Carried into later increments, each of which gets its own plan:

- **Increment 2** — `LegacyBooks::Review`, `Services::BooksMigration::ReviewMigrator`, the `data_migration:reviews` rake task, and the `backfill_all!` run. Note for that plan: the migrator must call `BodySanitizer` explicitly (bulk insert bypasses `before_validation`), must apply the 25,000-char cap by dropping the body, and **must use an untargeted `ON CONFLICT DO NOTHING`** — with ids preserved, the primary key is a second colliding constraint that a natural-key arbiter will not suppress.
- **Increment 3** — book page read surface: summary line, histogram, paginated text reviews. Needs a `.review-spoiler` CSS rule in the books stylesheet and a Stimulus controller to reveal it, plus a decision on rendering the stored (already-sanitized) body as HTML.
- **Increment 4** — the write flow: cacheable widget, `ReviewStateController` including its `csrf_token`, the modal, `ReviewsController`, `ReviewPolicy`.
- **Increment 5** — `/my/reviews`, the `/reviews` 301s, and the admin index.
