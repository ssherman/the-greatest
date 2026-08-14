# Reviews Increment 5 Implementation Plan — `/my/reviews`, admin index, domain-generic contract

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the signed-in personal ratings library at `/my/reviews`, a minimal admin index, and the two items increment 4 deferred (write rate limit, purge-on-admin-destroy) — with every generic piece written against a reviewable contract rather than against books.

**Architecture:** A `Reviewable` concern declares what generic review code needs from a reviewable class; a `Reviews::Registry` owns the domain-to-type mapping and becomes the single allowlist for the three controllers that need one. `Reviews::MyReviewsQuery` does all filtering and sorting in SQL against exactly one reviewable table. The page is plain server-rendered HTML with no Turbo Frame; writing reuses the existing dialog and reloads.

**Tech Stack:** Rails 8.1.3.1, Minitest + fixtures + Mocha, ViewComponent, Stimulus (Rollup, no transpilation), Tailwind CSS 4 + DaisyUI 5, Pagy, Pundit, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-13-my-reviews-design.md`

## Global Constraints

- Run all Rails/yarn commands from `web-app/`.
- Lint with `bundle exec standardrb` — **not** `bin/rubocop`. Do not run brakeman.
- Namespace all media code (`Books::`, `Music::`, `Games::`); shared models stay global. Tests mirror the namespace.
- Inside a nested namespace, root-anchor constants: `::Books::Book`, never bare `Books::Book`.
- Rails 8 enum syntax: `enum :status, {active: 0}`.
- **Never run a destructive command against the development database.** A hook blocks most; `create_fixtures` TRUNCATES.
- Services use the Result pattern under `app/lib/services/<domain>/`. Query objects live under `app/lib/<domain>/` or `app/lib/reviews/`.
- Controller tests assert **behavior only** — status codes, redirect targets, params. Never HTML, CSS or copy.
- **daisyUI 5 is installed, not 4.** `form-control`, `label-text` and `*-bordered` are removed and fail silently.
- Capybara: `text:` is a substring match and `default_normalize_ws` is false. Use `normalize_ws: true` and anchor with regexes or testids, or the assertion is vacuous.
- Every new user-facing page needs a Playwright E2E test in `web-app/e2e/tests/`.
- Before claiming done: `bin/rails test` and `bundle exec standardrb` both green.

## File Structure

| File | Responsibility |
| --- | --- |
| `app/models/concerns/reviewable.rb` | Associations + the four-method contract every reviewable implements |
| `app/models/books/book.rb` | Includes the concern, supplies the books implementations |
| `app/lib/reviews/registry.rb` | Domain → reviewable types; the single type allowlist |
| `app/lib/reviews/my_reviews_query.rb` | Filtering and sorting, all in SQL |
| `app/lib/reviews/my_reviews_stats.rb` | Profile-strip numbers |
| `app/controllers/my_reviews_controller.rb` | The page |
| `app/components/reviews/my/profile_strip_component.*` | Average, bar chart (which is the filter), counts |
| `app/components/reviews/my/row_component.*` | One review row |
| `app/views/my_reviews/index.html.erb` | Strip + controls + rows + pagination |
| `app/javascript/controllers/reviews/my_reviews_controller.js` | Opens the shared dialog, reloads on success |
| `app/controllers/admin/reviews_base_controller.rb` | Generic admin index/destroy |
| `app/controllers/admin/books/reviews_controller.rb` | Books specifics |
| `config/initializers/rate_limit_store.rb` | The counter store for the write limit |

---

### Task 1: `Reviewable` concern and the books implementation

**Files:**
- Create: `web-app/app/models/concerns/reviewable.rb`
- Modify: `web-app/app/models/books/book.rb` (associations at lines 71–72 move into the concern)
- Test: `web-app/test/models/concerns/reviewable_test.rb`

**Interfaces:**
- Produces: `Reviewable` concern providing `has_many :reviews, as: :reviewable` and `has_one :review_summary, as: :reviewable`, plus class methods `.review_row_includes`, `.review_title_order`, `.review_text_search(scope, term)`, `.ranking_configuration_class`.
- `Books::Book.review_row_includes` → `[:primary_image, {book_authors: :author}]`
- `Books::Book.review_title_order` → `"COALESCE(books_books.sort_title, books_books.title)"`
- `Books::Book.review_text_search(scope, term)` → an `ActiveRecord::Relation`
- `Books::Book.ranking_configuration_class` → `::Books::RankingConfiguration`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class ReviewableTest < ActiveSupport::TestCase
  # A stand-in reviewable that includes the concern but implements none of it,
  # so the contract's own failure mode is pinned rather than assumed.
  class UnimplementedReviewable < ApplicationRecord
    self.table_name = "books_books"
    include Reviewable
  end

  test "the contract raises until a reviewable implements it" do
    %i[review_row_includes review_title_order ranking_configuration_class].each do |method|
      assert_raises(NotImplementedError) { UnimplementedReviewable.public_send(method) }
    end
    assert_raises(NotImplementedError) { UnimplementedReviewable.review_text_search(Review.all, "x") }
  end

  test "Books::Book implements the whole contract" do
    assert_equal [:primary_image, {book_authors: :author}], ::Books::Book.review_row_includes
    assert_equal "COALESCE(books_books.sort_title, books_books.title)", ::Books::Book.review_title_order
    assert_equal ::Books::RankingConfiguration, ::Books::Book.ranking_configuration_class
  end

  test "the concern supplies the review associations" do
    book = books_books(:war_and_peace)
    assert_equal 3, book.reviews.count
    assert book.review_summary.present?
  end

  test "review_text_search matches a book title" do
    scope = Review.joins("INNER JOIN books_books ON books_books.id = reviews.reviewable_id")
      .where(reviewable_type: "Books::Book")
    assert_includes ::Books::Book.review_text_search(scope, "war and peace").map(&:reviewable_id),
      books_books(:war_and_peace).id
  end

  test "review_text_search matches an author name without duplicating rows" do
    book = books_books(:war_and_peace)
    author_name = book.authors.first.name
    scope = Review.joins("INNER JOIN books_books ON books_books.id = reviews.reviewable_id")
      .where(reviewable_type: "Books::Book", reviewable_id: book.id)
    results = ::Books::Book.review_text_search(scope, author_name).to_a
    assert_equal results.map(&:id).uniq.size, results.size, "author join must not multiply rows"
    assert_equal 3, results.size
  end

  test "review_text_search escapes LIKE wildcards in the term" do
    scope = Review.joins("INNER JOIN books_books ON books_books.id = reviews.reviewable_id")
      .where(reviewable_type: "Books::Book")
    assert_empty ::Books::Book.review_text_search(scope, "%").to_a
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/models/concerns/reviewable_test.rb`
Expected: FAIL — `uninitialized constant Reviewable`.

- [ ] **Step 3: Write the concern**

```ruby
# frozen_string_literal: true

# The contract generic review code depends on. Reviews are polymorphic through
# `reviewable` and there is no per-domain Review subclass to hang behaviour on,
# so each reviewable class declares what the shared code needs from it.
#
# Every method raises on the base: a reviewable that half-implements the contract
# must fail loudly at the first call rather than render a page with no covers or
# an unsortable column.
module Reviewable
  extend ActiveSupport::Concern

  included do
    has_many :reviews, as: :reviewable, dependent: :destroy
    has_one :review_summary, as: :reviewable, dependent: :destroy
  end

  class_methods do
    # Associations to eager-load on each row of /my/reviews, so a 25-row page
    # rendering a cover and a creator each stays N+1-free.
    def review_row_includes
      raise NotImplementedError, "#{name} must override .review_row_includes"
    end

    # SQL expression the A-Z sort orders by. An expression rather than a column
    # name because a sort title is usually nullable and has to fall back.
    def review_title_order
      raise NotImplementedError, "#{name} must override .review_title_order"
    end

    # Applies a free-text filter to a Review scope already joined to this class's
    # table. Implementations MUST NOT add a join that can multiply rows -- use an
    # EXISTS subquery for has_many sides, or one book with three reviews and two
    # authors returns six rows.
    def review_text_search(scope, term)
      raise NotImplementedError, "#{name} must override .review_text_search"
    end

    # Supplies default_primary for the "site rank" sort. An implementation may
    # return nil to declare it has no site ranking -- that is an explicit answer,
    # and the sort is then not offered at all.
    def ranking_configuration_class
      raise NotImplementedError, "#{name} must override .ranking_configuration_class"
    end
  end
end
```

- [ ] **Step 4: Wire up `Books::Book`**

Replace the two hand-written associations (currently `book.rb:71-72`) with the include, and add the four implementations near the other class methods:

```ruby
  include Reviewable
```

```ruby
  def self.review_row_includes
    [:primary_image, {book_authors: :author}]
  end

  def self.review_title_order
    "COALESCE(books_books.sort_title, books_books.title)"
  end

  # EXISTS rather than a join to books_authors: a book with three reviews and two
  # authors would otherwise come back three times over, which silently inflates
  # both the page and its count.
  def self.review_text_search(scope, term)
    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    scope.where(
      "books_books.title ILIKE :pattern OR EXISTS (
         SELECT 1 FROM books_book_authors
         INNER JOIN books_authors ON books_authors.id = books_book_authors.author_id
         WHERE books_book_authors.book_id = books_books.id
           AND books_authors.name ILIKE :pattern
       )",
      pattern: pattern
    )
  end

  def self.ranking_configuration_class
    ::Books::RankingConfiguration
  end
```

Delete the now-duplicated `has_many :reviews, as: :reviewable, dependent: :destroy` and `has_one :review_summary, as: :reviewable, dependent: :destroy` lines.

- [ ] **Step 5: Run the tests and the wider model suite**

Run: `cd web-app && bin/rails test test/models/concerns/reviewable_test.rb test/models/books/book_test.rb test/models/review_test.rb`
Expected: PASS. If `book_test.rb` fails on a missing association, the include was placed after the associations were deleted but before the concern loaded — confirm `include Reviewable` sits with the other includes at the top of the class.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/models/concerns/reviewable.rb app/models/books/book.rb test/models/concerns/reviewable_test.rb
git add app/models/concerns/reviewable.rb app/models/books/book.rb test/models/concerns/reviewable_test.rb
git commit -m "Add a Reviewable contract so review code is not scoped to books"
```

---

### Task 2: `Reviews::Registry` and retiring the duplicated allowlists

**Files:**
- Create: `web-app/app/lib/reviews/registry.rb`
- Modify: `web-app/app/controllers/reviews_controller.rb` (`REVIEWABLE_TYPES` and `find_reviewable`)
- Modify: `web-app/app/controllers/review_state_controller.rb` (its own `REVIEWABLE_TYPES`)
- Test: `web-app/test/lib/reviews/registry_test.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Reviews::Registry.types_for(domain)` → `Array<String>`; `.classes_for(domain)` → `Array<Class>`; `.allowed?(type)` → `Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Reviews
  class RegistryTest < ActiveSupport::TestCase
    test "resolves the books domain to its reviewable types" do
      assert_equal ["Books::Book"], Registry.types_for(:books)
      assert_equal [::Books::Book], Registry.classes_for(:books)
    end

    test "a domain with no reviewable types resolves to empty" do
      assert_empty Registry.types_for(:music)
      assert_empty Registry.classes_for(:nope)
    end

    test "accepts a string domain as well as a symbol" do
      assert_equal ["Books::Book"], Registry.types_for("books")
    end

    test "allowed? gates arbitrary user-supplied types" do
      assert Registry.allowed?("Books::Book")
      refute Registry.allowed?("User")
      refute Registry.allowed?(nil)
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/lib/reviews/registry_test.rb`
Expected: FAIL — `uninitialized constant Reviews::Registry`.

- [ ] **Step 3: Write the registry**

```ruby
# frozen_string_literal: true

module Reviews
  # Single source of truth for which classes are reviewable, and which domain
  # each belongs to.
  #
  # This is security-relevant, not just organisational: reviewable_type arrives
  # from the browser, and without an allowlist a visitor could attach a review to
  # an arbitrary class. That allowlist previously existed as a private constant in
  # two separate controllers, which meant adding a domain silently half-worked.
  class Registry
    DOMAIN_TYPES = {
      "books" => ["Books::Book"].freeze
    }.freeze

    def self.types_for(domain)
      DOMAIN_TYPES[domain.to_s] || []
    end

    def self.classes_for(domain)
      types_for(domain).map(&:constantize)
    end

    def self.allowed?(type)
      DOMAIN_TYPES.each_value.any? { |types| types.include?(type.to_s) }
    end
  end
end
```

- [ ] **Step 4: Point both controllers at it**

In `reviews_controller.rb`, delete the `REVIEWABLE_TYPES` constant and its comment, and change `find_reviewable`:

```ruby
  # reviewable_type is user input; Reviews::Registry is the allowlist that stops a
  # visitor attaching a review to an arbitrary class.
  def find_reviewable(type, id)
    return nil unless Reviews::Registry.allowed?(type)

    type.to_s.constantize.find_by(id: id)
  end
```

Make the identical substitution in `review_state_controller.rb`. Read that file first — match its own method name and structure rather than assuming it mirrors `ReviewsController` exactly.

- [ ] **Step 5: Run the affected suites**

Run: `cd web-app && bin/rails test test/lib/reviews/registry_test.rb test/controllers/reviews_controller_test.rb test/controllers/review_state_controller_test.rb`
Expected: PASS, including the existing tests that a bogus `reviewable_type` is rejected. If one of those tests passes trivially, check it asserts a `400`/`bad_request` and not merely "no review created".

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/reviews/registry.rb app/controllers/reviews_controller.rb app/controllers/review_state_controller.rb test/lib/reviews/registry_test.rb
git add -A
git commit -m "Replace two duplicated reviewable allowlists with one registry"
```

---

### Task 3: `Reviews::MyReviewsQuery`

**Files:**
- Create: `web-app/app/lib/reviews/my_reviews_query.rb`
- Test: `web-app/test/lib/reviews/my_reviews_query_test.rb`

**Interfaces:**
- Consumes: `Books::Book.review_title_order`, `.review_text_search`, `.ranking_configuration_class` (Task 1).
- Produces: `Reviews::MyReviewsQuery.new(user:, reviewable_class:, params:)` with `#call` → `ActiveRecord::Relation` of `Review`, `#sort` → `String`, `#available_sorts` → `Array<String>`, `#rating` → `Integer|nil`, `#kind` → `String|nil`, `#term` → `String|nil`.
- Sort keys: `"recent"` (default), `"rating_high"`, `"rating_low"`, `"rank"`, `"title"`.
- Kind filter values: `"written"`, `"rating_only"`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Reviews
  class MyReviewsQueryTest < ActiveSupport::TestCase
    setup do
      @user = users(:regular_user)
      @war_and_peace = books_books(:war_and_peace)
      @crime = books_books(:crime_and_punishment)
    end

    def query(params = {})
      MyReviewsQuery.new(user: @user, reviewable_class: ::Books::Book, params: params)
    end

    test "returns only this user's reviews of this reviewable type" do
      results = query.call.to_a
      assert_equal @user.reviews.count, results.size
      assert results.all? { |review| review.user_id == @user.id }
      assert results.all? { |review| review.reviewable_type == "Books::Book" }
    end

    test "defaults to newest first" do
      assert_equal "recent", query.sort
      created = query.call.map(&:created_at)
      assert_equal created.sort.reverse, created
    end

    test "filters to a single rating" do
      results = query(rating: "5").call.to_a
      assert results.any?
      assert results.all? { |review| review.rating == 5 }
    end

    test "ignores an out-of-range rating rather than returning nothing" do
      assert_equal query.call.count, query(rating: "9").call.count
      assert_nil query(rating: "9").rating
    end

    test "filters to written and to rating-only" do
      assert query(kind: "written").call.all? { |review| review.body.present? }
      assert query(kind: "rating_only").call.all? { |review| review.body.nil? }
    end

    test "sorts by the user's own rating in both directions" do
      high = query(sort: "rating_high").call.map(&:rating)
      assert_equal high.sort.reverse, high
      low = query(sort: "rating_low").call.map(&:rating)
      assert_equal low.sort, low
    end

    test "sorts A-Z by the reviewable's title" do
      titles = query(sort: "title").call.map { |review| review.reviewable.title }
      assert_equal titles.sort_by(&:downcase), titles
    end

    test "sorts by site rank with unranked last" do
      config = ::Books::RankingConfiguration.default_primary
      RankedItem.create!(item: @crime, ranking_configuration: config, rank: 1)
      ranked_first = query(sort: "rank").call.first
      assert_equal @crime.id, ranked_first.reviewable_id
    end

    test "offers the rank sort only when a default primary configuration exists" do
      assert_includes query.available_sorts, "rank"
      ::Books::Book.stubs(:ranking_configuration_class).returns(nil)
      refute_includes query.available_sorts, "rank"
      assert_equal "recent", query(sort: "rank").sort, "an unavailable sort falls back, never raises"
    end

    test "an unknown sort falls back to the default" do
      assert_equal "recent", query(sort: "; DROP TABLE reviews").sort
    end

    test "text search matches title or author" do
      results = query(q: "war and peace").call.to_a
      assert results.any?
      assert results.all? { |review| review.reviewable_id == @war_and_peace.id }
    end

    test "a blank search term is ignored" do
      assert_equal query.call.count, query(q: "   ").call.count
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/lib/reviews/my_reviews_query_test.rb`
Expected: FAIL — `uninitialized constant Reviews::MyReviewsQuery`.

- [ ] **Step 3: Write the query object**

```ruby
# frozen_string_literal: true

module Reviews
  # Filtering and sorting for /my/reviews.
  #
  # Everything happens in SQL. MyListsController#ranking_sorted loads a whole
  # collection and sorts it in Ruby, which is fine for a list but not here: the
  # measured ceiling is 2,331 reviews for one user, with p90 at 241. Sorting in
  # Ruby would mean loading a user's entire history to render 25 rows.
  #
  # Scoped to exactly ONE reviewable class. A domain with several reviewable types
  # (music will have albums and songs) renders a type switcher instead of widening
  # this query, because sorting by title or rank across two tables means a UNION
  # that pages and counts badly.
  class MyReviewsQuery
    DEFAULT_SORT = "recent"
    SORTS = %w[recent rating_high rating_low rank title].freeze
    KINDS = %w[written rating_only].freeze
    RATINGS = (1..5).freeze

    attr_reader :user, :reviewable_class, :params

    def initialize(user:, reviewable_class:, params: {})
      @user = user
      @reviewable_class = reviewable_class
      @params = params
    end

    def call
      scope = base_scope
      scope = scope.where(rating: rating) if rating
      scope = scope.where.not(body: nil) if kind == "written"
      scope = scope.where(body: nil) if kind == "rating_only"
      scope = reviewable_class.review_text_search(scope, term) if term
      apply_sort(scope)
    end

    def available_sorts
      ranking_configuration ? SORTS : SORTS - ["rank"]
    end

    def sort
      requested = params[:sort].to_s
      available_sorts.include?(requested) ? requested : DEFAULT_SORT
    end

    def rating
      value = params[:rating].to_i
      RATINGS.include?(value) ? value : nil
    end

    def kind
      KINDS.include?(params[:kind].to_s) ? params[:kind].to_s : nil
    end

    def term
      params[:q].to_s.strip.presence
    end

    private

    def base_scope
      table = reviewable_class.table_name
      user.reviews
        .where(reviewable_type: reviewable_class.name)
        .joins("INNER JOIN #{table} ON #{table}.id = reviews.reviewable_id")
    end

    def apply_sort(scope)
      case sort
      when "rating_high" then scope.order(rating: :desc, id: :desc)
      when "rating_low" then scope.order(rating: :asc, id: :desc)
      when "title" then scope.order(Arel.sql("#{reviewable_class.review_title_order} ASC"), id: :desc)
      when "rank" then scope.joins(rank_join).order(Arel.sql("ranked_items.rank ASC NULLS LAST"), id: :desc)
      else scope.order(created_at: :desc, id: :desc)
      end
    end

    # LEFT OUTER so an unranked item still appears -- an INNER JOIN here would
    # silently drop every review of something the site has not ranked, which on a
    # personal history reads as data loss.
    def rank_join
      config = ranking_configuration
      <<~SQL.squish
        LEFT OUTER JOIN ranked_items
          ON ranked_items.item_id = reviews.reviewable_id
         AND ranked_items.item_type = #{ActiveRecord::Base.connection.quote(reviewable_class.name)}
         AND ranked_items.ranking_configuration_id = #{config.id.to_i}
      SQL
    end

    def ranking_configuration
      return @ranking_configuration if defined?(@ranking_configuration)

      @ranking_configuration = reviewable_class.ranking_configuration_class&.default_primary
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd web-app && bin/rails test test/lib/reviews/my_reviews_query_test.rb`
Expected: PASS.

- [ ] **Step 5: Prove the sort tests are not vacuous**

Temporarily change `apply_sort`'s `"rating_high"` branch to `scope.order(rating: :asc)` and re-run. The `sorts by the user's own rating in both directions` test MUST fail. Revert the change. If the fixture set has too few distinct ratings for the assertion to bite, add a fixture rather than accept a test that cannot fail.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/reviews/my_reviews_query.rb test/lib/reviews/my_reviews_query_test.rb
git add app/lib/reviews/my_reviews_query.rb test/lib/reviews/my_reviews_query_test.rb
git commit -m "Add MyReviewsQuery, filtering and sorting entirely in SQL"
```

---

### Task 4: `Reviews::MyReviewsStats`

**Files:**
- Create: `web-app/app/lib/reviews/my_reviews_stats.rb`
- Test: `web-app/test/lib/reviews/my_reviews_stats_test.rb`

**Interfaces:**
- Produces: `Reviews::MyReviewsStats.new(user:, reviewable_class:)` with `#counts_by_rating` → `Hash{1..5 => Integer}` (every key present, zero-filled), `#total` → `Integer`, `#written` → `Integer`, `#rating_only` → `Integer`, `#average` → `Float|nil` (one decimal), `#percentage_for(rating)` → `Integer`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Reviews
  class MyReviewsStatsTest < ActiveSupport::TestCase
    setup do
      @stats = MyReviewsStats.new(user: users(:regular_user), reviewable_class: ::Books::Book)
    end

    test "counts_by_rating always has all five keys, zero-filled" do
      assert_equal (1..5).to_a, @stats.counts_by_rating.keys.sort
      assert @stats.counts_by_rating.values.all? { |value| value.is_a?(Integer) }
    end

    test "totals split into written and rating-only" do
      assert_equal @stats.total, @stats.written + @stats.rating_only
      assert_equal users(:regular_user).reviews.count, @stats.total
    end

    test "average is rounded to one decimal and is a Float" do
      assert_instance_of Float, @stats.average
      assert_equal @stats.average.round(1), @stats.average
    end

    test "average is nil for a user with no reviews" do
      stats = MyReviewsStats.new(user: users(:user_with_no_reviews), reviewable_class: ::Books::Book)
      assert_nil stats.average
      assert_equal 0, stats.total
      assert_equal 0, stats.percentage_for(5)
    end

    test "percentage_for is a whole number out of the largest bar" do
      assert_includes 0..100, @stats.percentage_for(5)
    end
  end
end
```

Check `test/fixtures/users.yml` for a user with no reviews before writing that test; if none exists, add one rather than reusing a user that has them.

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/lib/reviews/my_reviews_stats_test.rb`
Expected: FAIL — `uninitialized constant Reviews::MyReviewsStats`.

- [ ] **Step 3: Write it**

```ruby
# frozen_string_literal: true

module Reviews
  # The numbers behind the /my/reviews profile strip. Two grouped queries, no
  # per-row work -- the strip re-renders on every filter click.
  class MyReviewsStats
    RATINGS = (1..5).freeze

    def initialize(user:, reviewable_class:)
      @user = user
      @reviewable_class = reviewable_class
    end

    def counts_by_rating
      @counts_by_rating ||= RATINGS.index_with { |rating| raw_counts[rating].to_i }
    end

    def total
      @total ||= counts_by_rating.values.sum
    end

    def written
      @written ||= scope.where.not(body: nil).count
    end

    def rating_only
      total - written
    end

    # Explicit Float bounds, and Float on the way out. Integer#/ would floor, and
    # a bare round can hand back an Integer -- both break the one-decimal contract
    # the view formats against.
    def average
      return nil if total.zero?

      sum = counts_by_rating.sum { |rating, count| rating * count }
      (sum.to_f / total).round(1)
    end

    # Relative to the tallest bar, so a spread of 3/1/1 still reads as a chart
    # rather than three near-identical stubs.
    def percentage_for(rating)
      tallest = counts_by_rating.values.max.to_i
      return 0 if tallest.zero?

      ((counts_by_rating[rating].to_f / tallest) * 100).round
    end

    private

    def scope
      @user.reviews.where(reviewable_type: @reviewable_class.name)
    end

    def raw_counts
      @raw_counts ||= scope.group(:rating).count
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd web-app && bin/rails test test/lib/reviews/my_reviews_stats_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/reviews/my_reviews_stats.rb test/lib/reviews/my_reviews_stats_test.rb
git add app/lib/reviews/my_reviews_stats.rb test/lib/reviews/my_reviews_stats_test.rb
git commit -m "Add MyReviewsStats for the profile strip"
```

---

### Task 5: `MyReviewsController`, routes and the legacy redirects

**Files:**
- Create: `web-app/app/controllers/my_reviews_controller.rb`
- Create: `web-app/app/views/my_reviews/index.html.erb` (placeholder markup; Task 7 fills it in)
- Modify: `web-app/config/routes.rb` (beside the `my/lists` routes, around line 288)
- Test: `web-app/test/controllers/my_reviews_controller_test.rb`

**Interfaces:**
- Consumes: `Reviews::Registry.classes_for` (Task 2), `Reviews::MyReviewsQuery` (Task 3), `Reviews::MyReviewsStats` (Task 4), `Books::Book.review_row_includes` (Task 1).
- Produces: `@reviewable_class`, `@reviewable_classes`, `@query`, `@stats`, `@pagy`, `@reviews` for the view; route helpers `my_reviews_path`, `my_reviews_page_path`.

- [ ] **Step 1: Add the routes**

```ruby
  get "my/reviews", to: "my_reviews#index", as: :my_reviews
  get "my/reviews/page/:page", to: "my_reviews#index", as: :my_reviews_page, constraints: {page: /\d+/}
```

and, beside the existing `user_lists` redirects:

```ruby
  get "reviews", to: redirect("/my/reviews", status: 301)
  get "reviews/account_required", to: redirect("/my/reviews", status: 301)
```

`get "reviews"` does not collide with the existing `post "reviews"` — different verbs.

- [ ] **Step 2: Write the failing test**

```ruby
require "test_helper"

class MyReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:books]
    @user = users(:regular_user)
  end

  test "requires sign in" do
    get my_reviews_path
    assert_response :redirect
  end

  test "renders for a signed-in user on a domain with reviewable types" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_response :success
  end

  test "404s on a domain with no reviewable types" do
    host! Rails.application.config.domains[:music]
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_response :not_found
  end

  test "is never cached" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_match(/no-store/, response.headers["Cache-Control"].to_s)
  end

  test "a page past the last one 404s rather than serving an empty 200" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_page_path(page: 999)
    assert_response :not_found
  end

  test "legacy review URLs redirect permanently" do
    get "/reviews"
    assert_response :moved_permanently
    assert_redirected_to "/my/reviews"

    get "/reviews/account_required"
    assert_response :moved_permanently
    assert_redirected_to "/my/reviews"
  end

  test "an unknown reviewable param falls back instead of erroring" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path(reviewable: "User")
    assert_response :success
  end
end
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/controllers/my_reviews_controller_test.rb`
Expected: FAIL — undefined method `my_reviews_path` (routes not yet loaded if Step 1 was skipped) or missing controller.

- [ ] **Step 4: Write the controller**

```ruby
# Personal ratings library. Global route like MyListsController: one path serves
# every host and the layout comes from Current.domain at request time.
class MyReviewsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include DomainLayout

  layout :resolve_layout

  before_action :require_signed_in!
  before_action :prevent_caching

  PER_PAGE = 25

  def index
    @reviewable_classes = Reviews::Registry.classes_for(Current.domain)
    # Not an empty state: a domain with no reviewable types has no such page at
    # all, and rendering one would ship a permanently blank /my/reviews on the
    # music and games hosts.
    raise ActiveRecord::RecordNotFound if @reviewable_classes.empty?

    @reviewable_class = resolve_reviewable_class
    @query = Reviews::MyReviewsQuery.new(user: current_user, reviewable_class: @reviewable_class, params: params)
    @stats = Reviews::MyReviewsStats.new(user: current_user, reviewable_class: @reviewable_class)

    # preload, NOT includes: the query carries string joins, and includes would
    # let Rails choose eager_load, which raises EagerLoadPolymorphicError on a
    # polymorphic association. Every row here is one reviewable type, so a
    # grouped preload is both valid and cheaper.
    @pagy, @reviews = pagy_path(
      @query.call.preload(reviewable: @reviewable_class.review_row_includes),
      limit: PER_PAGE
    )
  end

  private

  # The requested type must be one this domain actually offers; anything else
  # falls back to the first rather than 404ing, so a stale bookmark still lands
  # somewhere useful.
  def resolve_reviewable_class
    requested = params[:reviewable].to_s
    @reviewable_classes.find { |klass| klass.name == requested } || @reviewable_classes.first
  end
end
```

- [ ] **Step 5: Add a placeholder view**

`app/views/my_reviews/index.html.erb`:

```erb
<div class="container mx-auto px-4 py-8">
  <h1 class="text-3xl font-bold">My Reviews</h1>
  <p class="mt-2"><%= @stats.total %> rated</p>
</div>
```

- [ ] **Step 6: Run the tests**

Run: `cd web-app && bin/rails test test/controllers/my_reviews_controller_test.rb`
Expected: PASS. If `is never cached` fails, read `Cacheable#prevent_caching` and assert against the header it actually sets rather than changing the concern.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/controllers/my_reviews_controller.rb test/controllers/my_reviews_controller_test.rb
git add -A
git commit -m "Add MyReviewsController, its routes and the legacy /reviews redirects"
```

---

### Task 6: Profile strip component

**Files:**
- Create: `web-app/app/components/reviews/my/profile_strip_component.rb`
- Create: `web-app/app/components/reviews/my/profile_strip_component.html.erb`
- Test: `web-app/test/components/reviews/my/profile_strip_component_test.rb`

**Interfaces:**
- Consumes: `Reviews::MyReviewsStats` (Task 4), `Reviews::MyReviewsQuery#rating` (Task 3).
- Produces: `Reviews::My::ProfileStripComponent.new(stats:, selected_rating:, path_for_rating:)` where `path_for_rating` is a callable taking a rating (or `nil` for "all") and returning a URL.

Generate with `bin/rails generate component Reviews::My::ProfileStrip` — never hand-create.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Reviews
  module My
    class ProfileStripComponentTest < ViewComponent::TestCase
      def stats_for(user)
        Reviews::MyReviewsStats.new(user: user, reviewable_class: ::Books::Book)
      end

      def render_strip(user: users(:regular_user), selected_rating: nil)
        render_inline(described_class.new(
          stats: stats_for(user),
          selected_rating: selected_rating,
          path_for_rating: ->(rating) { rating ? "/my/reviews?rating=#{rating}" : "/my/reviews" }
        ))
      end

      test "renders the average and the counts" do
        stats = stats_for(users(:regular_user))
        render_strip
        assert_text stats.average.to_s, normalize_ws: true
        assert_selector "[data-testid='my-reviews-total']", text: /\A#{stats.total}\z/
        assert_selector "[data-testid='my-reviews-written']", text: /\A#{stats.written}\z/
      end

      test "every rating is a link that filters, including empty ones" do
        render_strip
        (1..5).each do |rating|
          assert_selector "a[href='/my/reviews?rating=#{rating}']"
        end
      end

      test "the selected rating is marked and offers a way back to all" do
        render_strip(selected_rating: 5)
        assert_selector "[data-testid='rating-bar-5'][aria-current='true']"
        assert_selector "a[href='/my/reviews']"
      end

      test "renders a zero state without dividing by zero" do
        render_strip(user: users(:user_with_no_reviews))
        assert_selector "[data-testid='my-reviews-total']", text: /\A0\z/
      end
    end
  end
end
```

Note the anchored regexes: Capybara's `text:` is a substring match with whitespace normalization off, so `text: "3"` would pass against "13" and against " 3 ".

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/components/reviews/my/profile_strip_component_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement the component**

```ruby
# frozen_string_literal: true

module Reviews
  module My
    # The /my/reviews header: average, the rating spread, and the counts. The bars
    # ARE the rating filter, which is what earns the strip its space.
    class ProfileStripComponent < ViewComponent::Base
      RATINGS = (1..5).to_a.reverse.freeze

      def initialize(stats:, selected_rating: nil, path_for_rating:)
        @stats = stats
        @selected_rating = selected_rating
        @path_for_rating = path_for_rating
      end

      private

      attr_reader :stats, :selected_rating, :path_for_rating

      def ratings = RATINGS

      def selected?(rating) = selected_rating == rating

      def path_for(rating) = path_for_rating.call(rating)
    end
  end
end
```

Template — DaisyUI 5, so no `form-control` / `label-text` / `*-bordered`:

```erb
<section class="card bg-base-100 shadow-sm mb-6">
  <div class="card-body gap-4">
    <div class="flex flex-wrap items-baseline gap-6">
      <div>
        <span class="text-4xl font-bold"><%= stats.average || "—" %></span>
        <span class="text-base-content/70">average</span>
      </div>
      <div>
        <span class="text-2xl font-semibold" data-testid="my-reviews-total"><%= stats.total %></span>
        <span class="text-base-content/70">rated</span>
      </div>
      <div>
        <span class="text-2xl font-semibold" data-testid="my-reviews-written"><%= stats.written %></span>
        <span class="text-base-content/70">written</span>
      </div>
      <div>
        <span class="text-2xl font-semibold" data-testid="my-reviews-rating-only"><%= stats.rating_only %></span>
        <span class="text-base-content/70">rated without a review</span>
      </div>
    </div>

    <ul class="flex flex-col gap-1">
      <% ratings.each do |rating| %>
        <li>
          <a href="<%= path_for(rating) %>"
             data-testid="rating-bar-<%= rating %>"
             aria-current="<%= selected?(rating) %>"
             class="flex items-center gap-3 hover:bg-base-200 rounded px-2 py-1 <%= "bg-base-200 font-semibold" if selected?(rating) %>">
            <span class="w-12 shrink-0"><%= rating %> ★</span>
            <span class="flex-1 h-3 bg-base-300 rounded overflow-hidden">
              <span class="block h-full bg-primary" style="width: <%= stats.percentage_for(rating) %>%"></span>
            </span>
            <span class="w-12 shrink-0 text-right tabular-nums"><%= stats.counts_by_rating[rating] %></span>
          </a>
        </li>
      <% end %>
    </ul>

    <% if selected_rating %>
      <a href="<%= path_for(nil) %>" class="link link-hover text-sm">Show all ratings</a>
    <% end %>
  </div>
</section>
```

- [ ] **Step 4: Run the tests, then prove they bite**

Run: `cd web-app && bin/rails test test/components/reviews/my/profile_strip_component_test.rb`
Expected: PASS.

Then delete the `data-testid="my-reviews-written"` element from the template and re-run. The test MUST fail. Restore it. This project has had four vacuous component assertions in one increment; do not skip this step.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/components/reviews/my/ test/components/reviews/my/
git add -A
git commit -m "Add the /my/reviews profile strip, whose bars are the rating filter"
```

---

### Task 7: Row component, the index view, and the N+1 pin

**Files:**
- Create: `web-app/app/components/reviews/my/row_component.rb` + `.html.erb`
- Modify: `web-app/app/views/my_reviews/index.html.erb` (replace the Task 5 placeholder)
- Test: `web-app/test/components/reviews/my/row_component_test.rb`
- Test: `web-app/test/controllers/my_reviews_controller_test.rb` (add the query-count test)

**Interfaces:**
- Consumes: `Reviews::My::ProfileStripComponent` (Task 6), `Reviews::MyReviewsQuery#available_sorts`/`#sort`/`#kind`/`#term` (Task 3).
- Produces: `Reviews::My::RowComponent.new(review:)`.

Generate with `bin/rails generate component Reviews::My::Row`.

- [ ] **Step 1: Write the failing row test**

```ruby
require "test_helper"

module Reviews
  module My
    class RowComponentTest < ViewComponent::TestCase
      test "a written review shows its snippet and links to the item" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(described_class.new(review: review))
        assert_selector "a[href*='#{review.reviewable.slug}']"
        assert_text "Worth every one of its twelve hundred pages", normalize_ws: true
      end

      test "a rating-only review offers writing one instead of a snippet" do
        render_inline(described_class.new(review: reviews(:regular_user_crime_and_punishment)))
        assert_selector "[data-testid='write-review']"
        assert_no_selector "[data-testid='review-snippet']"
      end

      test "the snippet renders stored markup as markup, not escaped text" do
        review = reviews(:regular_user_war_and_peace)
        render_inline(described_class.new(review: review))
        assert_no_text "<p>", normalize_ws: true
      end

      test "a long unbroken token cannot widen the row" do
        review = reviews(:regular_user_war_and_peace)
        review.update!(body: "a" * 300)
        render_inline(described_class.new(review: review))
        assert_selector "[data-testid='review-snippet'].\\[overflow-wrap\\:anywhere\\]"
      end
    end
  end
end
```

The last test pins the lesson that a long unbroken token makes the whole page scroll sideways and that Tailwind's `break-words` does not fix it — the row needs `overflow-wrap: anywhere`. Adjust the selector to however the class is expressed, but assert it is present.

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/components/reviews/my/row_component_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement the row**

```ruby
# frozen_string_literal: true

module Reviews
  module My
    # One row of /my/reviews. Written reviews show a clamped snippet; rating-only
    # rows collapse to a single line offering to write one.
    class RowComponent < ViewComponent::Base
      def initialize(review:)
        @review = review
      end

      private

      attr_reader :review

      def reviewable = review.reviewable

      def written? = review.body.present?

      # Rendered, not stored: markup is generated at render time so what is stored
      # stays exactly what the author typed. Never call BodySanitizer.call here.
      def snippet
        Services::Reviews::BodySanitizer.render(review.body)
      end

      def creators
        return [] unless reviewable.respond_to?(:book_authors)

        reviewable.book_authors.map { |book_author| book_author.author.name }
      end
    end
  end
end
```

The `creators` method is a stopgap: it asks the reviewable directly rather than going through the contract. If a second reviewable type is added before this is revisited, promote it to a `.review_creator_names(record)` contract method on `Reviewable`.

Template `row_component.html.erb`:

```erb
<li class="flex gap-4 py-4 border-b border-base-300">
  <% if reviewable.primary_image.present? %>
    <%= link_to books_book_path(reviewable), class: "shrink-0" do %>
      <%= image_tag reviewable.primary_image.variant_url(:small),
            alt: reviewable.title, class: "w-16 rounded shadow-sm", loading: "lazy" %>
    <% end %>
  <% end %>

  <div class="flex-1 min-w-0">
    <%= link_to reviewable.title, books_book_path(reviewable), class: "font-semibold link link-hover" %>
    <% if creators.any? %>
      <p class="text-sm text-base-content/70"><%= creators.join(", ") %></p>
    <% end %>

    <div class="flex items-center gap-2 mt-1 text-sm">
      <%= render Reviews::StarsComponent.new(rating: review.rating) %>
      <span class="text-base-content/60"><%= time_ago_in_words(review.created_at) %> ago</span>
    </div>

    <% if written? %>
      <div class="mt-2 text-sm line-clamp-2 [overflow-wrap:anywhere]" data-testid="review-snippet">
        <%= snippet %>
      </div>
    <% end %>
  </div>

  <div class="shrink-0 self-center">
    <button type="button"
            class="btn btn-sm <%= written? ? "btn-ghost" : "btn-primary" %>"
            data-testid="<%= written? ? "edit-review" : "write-review" %>"
            data-action="click->reviews--my-reviews#open"
            data-review-id="<%= review.id %>"
            data-reviewable-type="<%= review.reviewable_type %>"
            data-reviewable-id="<%= review.reviewable_id %>"
            data-rating="<%= review.rating %>"
            data-title="<%= review.title %>"
            data-body="<%= review.body %>">
      <%= written? ? "Edit" : "Write a review" %>
    </button>
  </div>
</li>
```

`[overflow-wrap:anywhere]` is load-bearing, not decoration: a single long unbroken token in a review body makes the **whole page** scroll sideways, because DaisyUI's `.card` has no `overflow: hidden` and `min-width` defaults to `auto`. Tailwind's `break-words` does **not** fix it. This affected 1,272 book pages before it was found.

Check `primary_image.variant_url(:small)` against how the book page renders covers and match it — the variant names are not guessable.

- [ ] **Step 4: Build the index view**

Replace the placeholder entirely:

```erb
<% content_for :title, "My Reviews" %>

<div class="container mx-auto px-4 py-8"
     data-controller="reviews--my-reviews"
     data-action="turbo:submit-end@document->reviews--my-reviews#submitted">
  <h1 class="text-3xl font-bold mb-6">My Reviews</h1>

  <%= render Reviews::My::ProfileStripComponent.new(
        stats: @stats,
        selected_rating: @query.rating,
        path_for_rating: ->(rating) { my_reviews_path(filter_params(rating: rating)) }
      ) %>

  <% if @reviewable_classes.size > 1 %>
    <div role="tablist" class="tabs tabs-box mb-4">
      <% @reviewable_classes.each do |klass| %>
        <%= link_to klass.model_name.human.pluralize,
              my_reviews_path(filter_params(reviewable: klass.name)),
              role: "tab",
              class: "tab #{"tab-active" if klass == @reviewable_class}" %>
      <% end %>
    </div>
  <% end %>

  <div class="flex flex-wrap items-end gap-4 mb-4">
    <%= form_with url: my_reviews_path, method: :get, class: "flex gap-2" do |form| %>
      <% hidden_filter_params.each do |key, value| %>
        <%= hidden_field_tag key, value %>
      <% end %>
      <%= form.search_field :q, value: @query.term, placeholder: "Search your reviews",
            class: "input w-64", "aria-label": "Search your reviews" %>
      <%= form.submit "Search", class: "btn" %>
    <% end %>

    <div class="join">
      <%= link_to "All", my_reviews_path(filter_params(kind: nil)),
            class: "btn join-item #{"btn-active" if @query.kind.nil?}" %>
      <%= link_to "Written", my_reviews_path(filter_params(kind: "written")),
            class: "btn join-item #{"btn-active" if @query.kind == "written"}" %>
      <%= link_to "Rating only", my_reviews_path(filter_params(kind: "rating_only")),
            class: "btn join-item #{"btn-active" if @query.kind == "rating_only"}" %>
    </div>

    <label class="flex items-center gap-2">
      <span class="text-sm">Sort</span>
      <select class="select w-56"
              onchange="window.location = this.value"
              aria-label="Sort your reviews">
        <% @query.available_sorts.each do |sort_key| %>
          <option value="<%= my_reviews_path(filter_params(sort: sort_key)) %>"
                  <%= "selected" if @query.sort == sort_key %>>
            <%= SORT_LABELS.fetch(sort_key) %>
          </option>
        <% end %>
      </select>
    </label>
  </div>

  <% if @reviews.any? %>
    <ul class="mb-6">
      <% @reviews.each do |review| %>
        <%= render Reviews::My::RowComponent.new(review: review) %>
      <% end %>
    </ul>
    <%== @pagy.series_nav %>
  <% else %>
    <p class="py-12 text-center text-base-content/70">
      Nothing here yet. Rate a book and it will show up on this page.
    </p>
  <% end %>
</div>

<%= render Reviews::ModalComponent.new %>
```

Add `SORT_LABELS` to the controller as a frozen hash (`"recent" => "Recently rated"`, `"rating_high" => "My rating: high to low"`, `"rating_low" => "My rating: low to high"`, `"rank" => "Site rank"`, `"title" => "Title A–Z"`) and expose it plus these two helpers with `helper_method`:

```ruby
  # Every control must preserve the OTHER filters -- a sort link inside a rating
  # filter has to keep the rating. `page` is always dropped: a user on page 7 who
  # filters to 5-star would otherwise land on an empty page 7, which
  # PathBasedPagination turns into a 404.
  def filter_params(overrides = {})
    request.query_parameters.except("page").merge(overrides.stringify_keys).compact
  end

  def hidden_filter_params
    filter_params.except("q")
  end
```

**No Turbo Frame anywhere in this view.** Every row links off-page to a book; the frame the original spec called for would trap those links.

The sort `<select>` uses an inline `onchange` rather than a Stimulus controller because it is a one-line navigation with no state. If the project's CSP forbids inline handlers, move it into `my_reviews_controller.js` as a `change->` action — check `config/initializers/content_security_policy.rb` before deciding.

- [ ] **Step 5: Pin the query count**

Add to `my_reviews_controller_test.rb`:

```ruby
  test "renders a page of rows without an N+1" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path # warm any per-request memoization
    assert_queries_count(EXPECTED) do
      get my_reviews_path
    end
    assert_response :success
  end
```

Run it once to learn the real number, substitute it for `EXPECTED`, then **delete one association from `Books::Book.review_row_includes` and re-run** — the count must go up and the test must fail. Restore it. A query-count test that never moves is worthless.

- [ ] **Step 6: Run everything and check the frame guard**

Run: `cd web-app && bin/rails test test/components/reviews/my/ test/controllers/my_reviews_controller_test.rb`
Expected: PASS, including `assert_no_frame_trapped_links` if the integration test includes it.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/components/reviews/my/ app/controllers/ test/
git add -A
git commit -m "Render the /my/reviews rows, filters and sorts with no Turbo Frame"
```

---

### Task 8: Writing from the page

**Files:**
- Create: `web-app/app/javascript/controllers/reviews/my_reviews_controller.js`
- Modify: `web-app/app/javascript/controllers/index.js` (or wherever controllers register — check first)
- Modify: `web-app/app/views/my_reviews/index.html.erb` (render the shared dialog, attach the controller)
- Modify: `web-app/app/views/layouts/books/application.html.erb` only if the dialog is not already global — check before editing.

**Interfaces:**
- Consumes: the existing `reviews-modal:open` window event contract — `{reviewableType, reviewableId, review: {id, rating, title, body}|null, csrfToken}`.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Read the existing contract before writing anything**

Read `app/javascript/controllers/reviews/modal_controller.js` and `app/components/reviews/modal_component.html.erb` in full. Confirm the event name, the exact detail keys, and how `widget_controller.js` obtains its CSRF token. Do not guess at these.

- [ ] **Step 2: Write the controller**

```javascript
import { Controller } from "@hotwired/stimulus"

// Opens the shared review dialog from a /my/reviews row.
//
// Unlike the book page, this page is never cached (MyReviewsController calls
// prevent_caching), so the CSRF token in the page's own <meta> is real and there
// is nothing to fetch from /review_state.
export default class extends Controller {
  open(event) {
    const row = event.currentTarget.dataset
    const reviewId = row.reviewId

    window.dispatchEvent(new CustomEvent("reviews-modal:open", {
      detail: {
        reviewableType: row.reviewableType,
        reviewableId: row.reviewableId,
        csrfToken: document.querySelector('meta[name="csrf-token"]')?.content || "",
        review: reviewId
          ? { id: reviewId, rating: Number(row.rating), title: row.title, body: row.body }
          : null
      }
    }))
  }

  // ReviewsController answers with turbo streams aimed at review_widget,
  // review_summary_line and review_card -- all book-page ids that do not exist
  // here, and Turbo no-ops silently on a missing target. So reload instead:
  // it also recomputes the row, the bar chart and the counts server-side, which
  // means nothing on this page can drift out of step with the write.
  submitted(event) {
    if (!event.detail?.success) return
    window.location.reload()
  }
}
```

- [ ] **Step 3: Wire the view**

Render `Reviews::ModalComponent` on the page if it is not already in the layout. Attach `data-controller="reviews--my-reviews"` to the results container, `data-action="click->reviews--my-reviews#open"` on each row's rate/edit trigger, and `data-action="turbo:submit-end@document->reviews--my-reviews#submitted"` on the container.

Verify the Stimulus identifier against how other nested controllers are registered in this app before assuming the `reviews--` prefix.

- [ ] **Step 4: Build and check by hand**

```bash
cd web-app && yarn build:all
```

There is no transpilation step, so the bundle carries exactly what you wrote — a syntax error surfaces only at runtime in the browser console. Load `/my/reviews`, open the dialog from a row, save, and confirm the page reloads with the change visible.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Let /my/reviews drive the shared review dialog, reloading on success"
```

---

### Task 9: Admin index and destroy

**Files:**
- Create: `web-app/app/controllers/admin/reviews_base_controller.rb`
- Create: `web-app/app/controllers/admin/books/reviews_controller.rb`
- Create: `web-app/app/views/admin/books/reviews/index.html.erb`
- Modify: `web-app/config/routes.rb` (inside the books admin namespace)
- Modify: `web-app/app/lib/admin/domain_nav.rb` (add a Reviews entry to the books nav, around line 84)
- Test: `web-app/test/controllers/admin/books/reviews_controller_test.rb`

**Interfaces:**
- Consumes: `Reviews::Registry` (Task 2).
- Produces: `admin_books_reviews_path`, `admin_books_review_path(review)`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Admin
  module Books
    class ReviewsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @review = reviews(:regular_user_war_and_peace)
      end

      test "index redirects unauthenticated users" do
        get admin_books_reviews_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_reviews_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_reviews_path
        assert_response :success
      end

      test "destroy removes the review and purges the cached page" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Reviews::PurgeCachedPageJob.expects(:perform_async).with("Books::Book", @review.reviewable_id).once
        assert_difference("Review.count", -1) do
          delete admin_books_review_path(@review)
        end
      end

      test "destroy is refused for a domain user without write access" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("Review.count") do
          delete admin_books_review_path(@review)
        end
      end
    end
  end
end
```

Check `test/fixtures/users.yml` and the `domain_roles` enum for the real viewer level name before writing that last test.

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/controllers/admin/books/reviews_controller_test.rb`
Expected: FAIL — no route matches.

- [ ] **Step 3: Write the base controller**

```ruby
# Generic admin surface for reviews: index and destroy only. No approval queue --
# nothing gates publishing.
class Admin::ReviewsBaseController < Admin::BaseController
  before_action :require_domain_write!, only: [:destroy]

  def index
    scope = Review.where(reviewable_type: reviewable_class.name)
      .includes(:user)
      .preload(reviewable: reviewable_includes)

    # Written reviews by default: of ~128,000 rows only ~16,000 carry text, so an
    # unfiltered index is overwhelmingly rating-only noise.
    @written_only = params[:written] != "all"
    scope = scope.where.not(body: nil) if @written_only

    @search_query = params[:q].presence
    scope = apply_search(scope, @search_query) if @search_query

    @pagy, @reviews = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end

  def destroy
    review = Review.find(params[:id])
    reviewable_type = review.reviewable_type
    reviewable_id = review.reviewable_id
    review.destroy!

    # Explicit, exactly as in ReviewsController: an after_commit making an
    # external HTTP call would be invisible to its callers and would fire from
    # rake tasks and importers. This is the write path that comment predicted.
    ::Reviews::PurgeCachedPageJob.perform_async(reviewable_type, reviewable_id)

    redirect_to reviews_path, notice: "Review deleted."
  end

  private

  def apply_search(scope, term)
    reviewable_class.review_text_search(
      scope.joins("INNER JOIN #{reviewable_class.table_name} ON #{reviewable_class.table_name}.id = reviews.reviewable_id"),
      term
    ).or(
      scope.where(user_id: User.where("email ILIKE :p OR display_name ILIKE :p", p: "%#{User.sanitize_sql_like(term)}%"))
    )
  end
end
```

`.or` requires structurally compatible relations; if Rails rejects it, split into two explicit branches driven by a `search_by` param rather than fighting it. Verify `User` has a `display_name` column before referencing it.

Authorization note: **do not extend `ReviewPolicy`.** It is owner-only by design — its own comment says domain-role logic does not apply, because a review belongs to the person who wrote it. Teaching it about admins would also hand admins edit rights on the public write flow. `require_domain_write!` is the documented path for admin controllers with no Pundit layer, which is exactly this.

- [ ] **Step 4: Write the books subclass, route and nav entry**

```ruby
class Admin::Books::ReviewsController < Admin::ReviewsBaseController
  include Admin::DomainScopedAuth

  private

  def reviewable_class = ::Books::Book

  def reviewable_includes = [{book_authors: :author}]

  def reviews_path = admin_books_reviews_path
end
```

Route, inside the existing books admin namespace: `resources :reviews, only: [:index, :destroy]`.

Nav entry, beside the others in `domain_nav.rb`: `{label: "Reviews", icon: :star, path: -> { URL_HELPERS.admin_books_reviews_path }}`. Check the available icon names first — an unknown icon may render nothing rather than raise.

- [ ] **Step 5: Build the index view**

```erb
<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold">Reviews</h1>
  <div class="flex gap-2">
    <%= link_to "Written", admin_books_reviews_path(request.query_parameters.except("written", "page")),
          class: "btn btn-sm #{"btn-active" if @written_only}" %>
    <%= link_to "All", admin_books_reviews_path(request.query_parameters.except("page").merge("written" => "all")),
          class: "btn btn-sm #{"btn-active" unless @written_only}" %>
  </div>
</div>

<%= form_with url: admin_books_reviews_path, method: :get, class: "flex gap-2 mb-4" do |form| %>
  <%= hidden_field_tag :written, params[:written] if params[:written].present? %>
  <%= form.search_field :q, value: @search_query, placeholder: "Reviewer or book",
        class: "input w-72", "aria-label": "Search reviews" %>
  <%= form.submit "Search", class: "btn" %>
<% end %>

<div class="overflow-x-auto">
  <table class="table">
    <thead>
      <tr><th>Reviewer</th><th>Book</th><th>Rating</th><th>Review</th><th>Date</th><th></th></tr>
    </thead>
    <tbody>
      <% @reviews.each do |review| %>
        <tr>
          <td><%= review.user.email %></td>
          <td><%= review.reviewable.title %></td>
          <td class="tabular-nums"><%= review.rating %></td>
          <td class="max-w-md truncate [overflow-wrap:anywhere]"><%= review.title.presence || review.body&.truncate(80) %></td>
          <td><%= review.created_at.to_date.iso8601 %></td>
          <td>
            <%= button_to "Delete", admin_books_review_path(review), method: :delete,
                  class: "btn btn-sm btn-error",
                  form: {data: {turbo_confirm: "Delete this review permanently?"}} %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

<%== @pagy.series_nav %>
```

Two things to verify rather than assume: that `.table` and `.stats` render with a background in this app (they have no background by default in this DaisyUI setup — if it looks wrong, fix it in the **domain stylesheet** with `@layer components`, never in the view), and that `review.user.email` is the column the other admin screens display for a user.

- [ ] **Step 6: Run the tests**

Run: `cd web-app && bin/rails test test/controllers/admin/books/reviews_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/controllers/admin/ app/lib/admin/domain_nav.rb test/controllers/admin/
git add -A
git commit -m "Add the admin reviews index, whose destroy purges the cached page itself"
```

---

### Task 10: Rate limit on the write endpoints

**Files:**
- Create: `web-app/config/initializers/rate_limit_store.rb`
- Modify: `web-app/app/controllers/reviews_controller.rb`
- Test: `web-app/test/controllers/reviews_controller_test.rb`

**Interfaces:**
- Produces: `Rails.application.config.x.rate_limit_store`.

- [ ] **Step 1: Write the initializer**

```ruby
# The counter store for ActionController rate limits.
#
# Not Rails.cache: production configures no cache_store at all, so it falls back
# to Rails' file-store default, which is per-container and wiped on every deploy.
# Redis is already running for Sidekiq.
#
# Test uses a real in-memory store rather than the environment's :null_store,
# whose #increment returns nil -- and rate_limiting only acts `if count && count > to`,
# so against a null store the limit never fires and a test for it passes without
# ever tripping.
Rails.application.config.x.rate_limit_store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
  end
```

- [ ] **Step 2: Write the failing test**

```ruby
  test "the write endpoints are rate limited and answer as a turbo stream" do
    Rails.application.config.x.rate_limit_store.clear
    sign_in_as(@user, stub_auth: true)

    21.times do |index|
      book = ::Books::Book.create!(title: "Rate limit probe #{index}")
      post reviews_path, params: valid_params(reviewable_id: book.id), as: :turbo_stream
    end

    assert_response :too_many_requests
    assert_equal "text/vnd.turbo-stream.html", response.media_type,
      "a non-2xx without a turbo-stream body replaces the whole page"
  end

  test "the limit is per user, not global" do
    Rails.application.config.x.rate_limit_store.clear
    sign_in_as(@user, stub_auth: true)
    20.times do |index|
      book = ::Books::Book.create!(title: "Probe #{index}")
      post reviews_path, params: valid_params(reviewable_id: book.id), as: :turbo_stream
    end

    sign_in_as(users(:editor_user), stub_auth: true)
    post reviews_path, params: valid_params(reviewable_id: @book.id), as: :turbo_stream
    assert_response :success
  end
```

Add `Rails.application.config.x.rate_limit_store.clear` to the existing `setup` block so the counter cannot leak between tests — the store is a single long-lived object per process.

`Books::Book.create!` may require more attributes; check the model's validations and supply what it needs.

- [ ] **Step 3: Run it and confirm it fails**

Run: `cd web-app && bin/rails test test/controllers/reviews_controller_test.rb -n "/rate limit/"`
Expected: FAIL — the 21st request returns 200 or 422, not 429.

- [ ] **Step 4: Add the limit**

In `reviews_controller.rb`, **after** the existing `before_action :require_signed_in!` so the unauthenticated case is already resolved:

```ruby
  # 20 saves a minute is far above any human clicking through book pages, and it
  # caps a runaway script at 1,200/hour rather than unbounded -- which matters
  # because every write enqueues a Cloudflare purge, and an unbounded loop would
  # drain the purge budget and silently starve everyone else's.
  #
  # `with:` is not optional. Rails' default raises TooManyRequests, which renders
  # an HTML error body on a non-2xx status -- and a Turbo-submitted form receiving
  # that replaces the user's whole page with it. This is the same failure the four
  # rescue_from handlers above exist to avoid; the rate limit is the fifth door.
  rate_limit to: 20, within: 1.minute,
    by: -> { current_user&.id },
    with: -> { render turbo_stream: [], status: :too_many_requests },
    store: Rails.application.config.x.rate_limit_store,
    only: [:create, :update, :destroy]
```

- [ ] **Step 5: Run the tests**

Run: `cd web-app && bin/rails test test/controllers/reviews_controller_test.rb`
Expected: PASS, all of them — confirm the 20 earlier tests still pass, since each now increments a shared counter.

- [ ] **Step 6: Prove the store choice matters**

Temporarily change the initializer's test branch to `ActiveSupport::Cache::NullStore.new` and re-run the rate-limit tests. They MUST fail. Revert. This is the exact trap the spec calls out: without this check, a limit that never fires looks identical to one that works.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix config/initializers/rate_limit_store.rb app/controllers/reviews_controller.rb test/controllers/reviews_controller_test.rb
git add -A
git commit -m "Rate limit review writes, counted in Redis and answered as a turbo stream"
```

---

### Task 11: Playwright E2E

**Files:**
- Create: `web-app/e2e/tests/my-reviews.spec.ts` (match the existing naming convention — check the directory first)

- [ ] **Step 1: Read two existing specs**

Read the reviews spec from increment 4 and one other. Reuse their sign-in helper and their selector conventions. Do not invent a new fixture or auth approach.

- [ ] **Step 2: Write the spec**

Cover, as separate assertions in one signed-in session:
1. `/my/reviews` renders and shows a total count.
2. Clicking a rating bar filters, and the URL carries the rating.
3. Changing the sort re-orders the rows.
4. Paging forward works when the account has more than 25 reviews — if the E2E account does not, seed enough or skip this assertion explicitly with a comment rather than writing one that cannot fail.
5. Opening the dialog from a row, changing the rating, saving, and seeing the row show the new rating after the reload.

- [ ] **Step 3: Run it**

```bash
cd web-app && yarn test:e2e
```

Requires a local dev server and `e2e/.env`. If the admin or e2e user misbehaves, `bin/rails e2e:admin` repairs the role.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "E2E: filter, sort, page and edit from /my/reviews"
```

---

### Task 12: Full verification

- [ ] **Step 1: Whole suite**

Run: `cd web-app && bin/rails db:test:prepare test`
Expected: 0 failures, 0 errors. Compare the **runs count** against the 6,395 baseline — a drop means tests stopped being collected, which a green run hides.

- [ ] **Step 2: Lint**

Run: `cd web-app && bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 3: Manual pass**

With `yarn build:all && bin/rails server` (not `bin/dev` — foreman self-terminates without a TTY), check `/my/reviews` as a user with many reviews and as one with none, the admin index, and that `/reviews` 301s.

- [ ] **Step 4: Commit anything outstanding**

---

## Self-Review Notes

**Spec coverage.** `Reviewable` concern → Task 1. Registry and allowlist retirement → Task 2. `MyReviewsQuery`, filters, SQL sorting, rank-sort availability → Task 3. Profile-strip numbers → Task 4. Controller, 404 on a typeless domain, routes, 301s, type resolution → Task 5. Strip → Task 6. Rows, no Turbo Frame, N+1 pin → Task 7. Dialog reuse and reload → Task 8. Admin base + books subclass + purge on destroy → Task 9. Rate limit, Redis store, turbo-stream 429 → Task 10. E2E → Task 11.

**Deliberately deferred, and why.** The type switcher has no test of its own because books has exactly one reviewable type — there is nothing to switch between, and a test asserting "renders nothing" would pass against a switcher that is broken for two types. Task 5 covers the fallback path (`?reviewable=User` still renders), which is the part that is reachable today.

**Known soft spot.** `RowComponent#creators` reaches for `book_authors` directly rather than going through the contract. Flagged inline in Task 7: the moment a second reviewable type appears, that becomes a `.review_creator_names` contract method.
