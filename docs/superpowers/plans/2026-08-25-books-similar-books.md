# Similar Books Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a "Similar Books" card of five titles on every book page, backed by a live
OpenSearch category-similarity query, with a "Show more" link to a 25-result grid page.

**Architecture:** `Books::Book#as_indexed_json` gains genre/subject/location id arrays and a
category count. `Search::Books::Search::BookSimilar` builds one OpenSearch query from those
fields, with four accuracy behaviors switchable from a Rails initializer.
`Services::Books::SimilarBooks` wraps it, caps results per author, loads records with the
right preloads, and returns a `Result`. Two views consume it: a card on `show` and a grid on
a new `similar` action.

**Tech Stack:** Rails 8.1, Ruby 4.0.6, OpenSearch, Minitest + Mocha + fixtures, ViewComponents,
daisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-25-books-similar-books-design.md`

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Lint with `bundle exec standardrb` (`--fix` autocorrects). **Never** `bin/rubocop`. Never brakeman.
- The test database for this worktree is already created. Use `bin/rails test`.
- **Root-anchor `::Books::Book`.** Inside `module Services; module Books` and
  `module Search; module Books`, a bare `Books::Book` resolves to the enclosing nested module
  and raises a confusing `NameError`. This has bitten this codebase 3+ times. Root-anchor in
  **tests too**.
- **`as_indexed_json` must keep the `:category_ids` key.** `CategoryItem#item_supports_category_indexing?`
  (`app/models/category_item.rb:49`) gates reindexing on that exact key. Removing it silently
  stops category edits from reindexing books.
- **Never `friendly.find` for books.** 137 books have purely numeric slugs and friendly_id
  resolves slugs before primary keys. Use `find_by!(slug: params[:slug])`.
- **Minitest is 6.x.** `assert_equal nil, x` is a hard failure — use `assert_nil`.
- **daisyUI 5.** These fail silently: `form-control`, `label-text`, `label-text-alt`,
  `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`,
  `input-disabled`, `table-hover`, `tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any.
- Use `class: "link"`, never `link link-hover` — the latter computes identically to plain text.
- Public layouts render **no flash**. Do not add `notice:`/`alert:`.
- Page titles use `content_for :page_title` and `content_for :meta_description`.
- Controller tests assert **behavior only** — status codes, params, no errors. Never HTML or copy.
- Commit after each task.

---

### Task 1: Index category types and the similarity count

Adds the four fields the similarity query reads. Nothing consumes them yet — this task is
complete when the index and the model agree and the full suite is green.

**Files:**
- Modify: `app/models/books/book.rb` (`as_indexed_json`, around line 178)
- Modify: `app/lib/search/books/book_index.rb` (mappings)
- Test: `test/models/books/book_test.rb`
- Test: `test/lib/search/books/book_index_test.rb`
- Modify: `test/fixtures/category_items.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: index fields `genre_category_ids`, `subject_category_ids`, `location_category_ids`
  (all `keyword`, values are **stringified** ids in OpenSearch) and `similarity_category_count`
  (`integer`). Model constant `::Books::Book::SIMILARITY_CATEGORY_TYPES = %w[genre subject location]`.

- [ ] **Step 1: Add fixtures giving one book all three category types**

Existing fixtures only attach genres to books. `crime_and_punishment` currently has no
category items at all, so it is the safe place to add a full spread.

Append to `test/fixtures/category_items.yml`:

```yaml
crime_and_punishment_novels:
  category: books_novels_genre
  item: crime_and_punishment (Books::Book)

crime_and_punishment_politics:
  category: books_politics_subject
  item: crime_and_punishment (Books::Book)

crime_and_punishment_france:
  category: books_france_location
  item: crime_and_punishment (Books::Book)
```

- [ ] **Step 2: Write the failing model tests**

Add to `test/models/books/book_test.rb`:

```ruby
test "as_indexed_json splits categories by type" do
  book = books_books(:crime_and_punishment)
  json = book.as_indexed_json

  assert_equal [categories(:books_novels_genre).id], json[:genre_category_ids]
  assert_equal [categories(:books_politics_subject).id], json[:subject_category_ids]
  assert_equal [categories(:books_france_location).id], json[:location_category_ids]
end

test "as_indexed_json counts only the categories that score" do
  assert_equal 3, books_books(:crime_and_punishment).as_indexed_json[:similarity_category_count]
end

test "as_indexed_json still exposes category_ids" do
  # CategoryItem#item_supports_category_indexing? gates reindexing on this exact
  # key. Without it, editing a book's categories silently stops reindexing it.
  assert books_books(:crime_and_punishment).as_indexed_json.key?(:category_ids)
end

test "as_indexed_json excludes soft-deleted categories from the split fields" do
  book = books_books(:crime_and_punishment)
  categories(:books_novels_genre).update!(deleted: true)
  book.reload

  assert_empty book.as_indexed_json[:genre_category_ids]
  assert_equal 2, book.as_indexed_json[:similarity_category_count]
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: FAIL — `genre_category_ids` is nil, so `assert_equal [id], nil` fails.

- [ ] **Step 4: Implement the model change**

In `app/models/books/book.rb`, add the constant near the top of the class (beside the other
constants) and rewrite `as_indexed_json`:

```ruby
  # The category types that participate in similarity scoring. Books carry no
  # `theme` categories today; counting only the scoring types keeps
  # similarity_category_count honest if that changes.
  SIMILARITY_CATEGORY_TYPES = %w[genre subject location].freeze
```

```ruby
  def as_indexed_json
    active = categories.select { |c| c.deleted == false }
    scored = active.select { |c| SIMILARITY_CATEGORY_TYPES.include?(c.category_type) }

    {
      title: title,
      subtitle: subtitle,
      alternate_titles: alternate_titles,
      author_names: authors.map(&:name),
      author_ids: authors.map(&:id),
      category_ids: active.map(&:id),
      genre_category_ids: scored.select { |c| c.category_type == "genre" }.map(&:id),
      subject_category_ids: scored.select { |c| c.category_type == "subject" }.map(&:id),
      location_category_ids: scored.select { |c| c.category_type == "location" }.map(&:id),
      similarity_category_count: scored.size,
      book_kind: book_kind,
      first_published_year: first_published_year,
      original_language_id: original_language_id,
      country_ids: countries.map(&:id),
      book_length: self.class.book_lengths[book_length],
      ranked: list_items.any?,
      ranked_position: primary_ranked_item&.rank
    }
  end
```

- [ ] **Step 5: Run the model tests to verify they pass**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: PASS

- [ ] **Step 6: Write the failing index mapping test**

Add to `test/lib/search/books/book_index_test.rb`:

```ruby
test "index definition maps the similarity fields" do
  properties = ::Search::Books::BookIndex.index_definition[:mappings][:properties]

  assert_equal "keyword", properties[:genre_category_ids][:type]
  assert_equal "keyword", properties[:subject_category_ids][:type]
  assert_equal "keyword", properties[:location_category_ids][:type]
  assert_equal "integer", properties[:similarity_category_count][:type]
end
```

- [ ] **Step 7: Run it to verify it fails**

Run: `bin/rails test test/lib/search/books/book_index_test.rb`
Expected: FAIL — `NoMethodError: undefined method '[]' for nil`.

- [ ] **Step 8: Add the mappings**

In `app/lib/search/books/book_index.rb`, inside `mappings.properties`, replace the existing
`category_ids` entry with these five:

```ruby
              category_ids: {
                type: "keyword"
              },
              genre_category_ids: {
                type: "keyword"
              },
              subject_category_ids: {
                type: "keyword"
              },
              location_category_ids: {
                type: "keyword"
              },
              similarity_category_count: {
                type: "integer"
              },
```

- [ ] **Step 9: Run the index test**

Run: `bin/rails test test/lib/search/books/book_index_test.rb`
Expected: PASS

- [ ] **Step 10: Run the full suite**

Run: `bin/rails test`
Expected: PASS, 0 failures, 0 errors.

The new fixtures are the risk here — a test elsewhere may assert a category count, or use
`crime_and_punishment` as its "book with no categories" case. If something fails, fix the
assertion in that test rather than removing the fixtures; Task 2 depends on them.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb --fix
bin/rails test
git add app/models/books/book.rb app/lib/search/books/book_index.rb test/models/books/book_test.rb test/lib/search/books/book_index_test.rb test/fixtures/category_items.yml
git commit -m "Index book categories split by type for similarity"
```

---

### Task 2: The similarity query and its configuration

**Files:**
- Create: `config/initializers/book_similarity.rb`
- Create: `app/lib/search/books/search/book_similar.rb`
- Test: `test/lib/search/books/search/book_similar_test.rb`

**Interfaces:**
- Consumes: the index fields from Task 1, and the constant
  `::Books::Book::SIMILARITY_CATEGORY_TYPES` it also defines.
- Produces:
  - `Rails.application.config.x.book_similarity` — an `ActiveSupport::OrderedOptions` read with `[]`.
  - `::Search::Books::Search::BookSimilar.call(book, options = {}) -> [{id: String, score: Float, source: nil}]`,
    ordered by score descending. `options` keys override config keys. Returns `[]` when the
    book has no scoring categories.

- [ ] **Step 1: Create the configuration initializer**

Create `config/initializers/book_similarity.rb`:

```ruby
# frozen_string_literal: true

# Tuning knobs for Services::Books::SimilarBooks and its OpenSearch query.
#
# These are defaults. Every key is overridable per call by keyword, which is how
# tests pin behaviour without mutating global state. Changing production
# behaviour means editing this file and deploying -- deliberate, because tuning
# is a development activity done against real data.
#
# min_score is 0 (disabled) on purpose. The legacy site used 5, but that was
# tuned against an unnormalised score scale; normalize_by_category_count divides
# every score by sqrt(tag count), so the whole scale shifts and the old number
# means nothing here.
Rails.application.config.x.book_similarity = ActiveSupport::OrderedOptions.new.merge(
  limit: 5,
  page_limit: 25,
  over_fetch: 3,
  min_score: 0,

  # The four accuracy behaviours, each independently switchable.
  require_genre_match: true,
  normalize_by_category_count: true,
  drop_common_categories: true,
  exclude_same_series: true,

  max_categories_per_type: 8,
  max_category_item_count: 25_000,
  max_per_author: 2,

  genre_boost: 5.0,
  subject_boost: 3.0,
  location_boost: 1.0,
  language_boost: 0.5,
  era_boost: 0.3,
  era_years: 50,
  author_boost: 0.1
)
```

- [ ] **Step 2: Write the failing query tests**

Create `test/lib/search/books/search/book_similar_test.rb`. The `index_book` helper indexes
documents directly, exactly as `book_advanced_test.rb` does, so each test controls every
field without touching fixtures.

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookSimilarTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
          @book = ::books_books(:crime_and_punishment)
          @novels = ::categories(:books_novels_genre).id.to_s      # item_count 300
          @politics = ::categories(:books_politics_subject).id.to_s # item_count 200
          @france = ::categories(:books_france_location).id.to_s    # item_count 50
        end

        def teardown
          cleanup_test_index
        end

        # Indexes a document directly so a test controls every field, rather than
        # depending on a fixture book's associations.
        def index_book(id, attrs = {})
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name,
            id: id,
            body: {
              title: "Book #{id}",
              category_ids: [],
              genre_category_ids: [],
              subject_category_ids: [],
              location_category_ids: [],
              similarity_category_count: 0,
              author_ids: [],
              original_language_id: nil,
              country_ids: [],
              book_length: nil,
              first_published_year: nil,
              ranked: true,
              ranked_position: nil
            }.merge(attrs),
            refresh: true
          )
        end

        def ids_for(**options)
          ::Search::Books::Search::BookSimilar.call(@book, options).map { |hit| hit[:id] }
        end

        test "returns nothing when the book has no scoring categories" do
          # of_mice_and_men carries no category items in the fixtures.
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_empty ::Search::Books::Search::BookSimilar.call(::books_books(:of_mice_and_men))
        end

        test "excludes the book itself" do
          index_book(@book.id, genre_category_ids: [@novels], similarity_category_count: 1)
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal ["9001"], ids_for
        end

        test "excludes unranked books" do
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1, ranked: false)

          assert_empty ids_for
        end

        test "normalizing by category count ranks a tight match above a bloated one" do
          # 9001 shares one genre out of two tags -- most of what it is.
          # 9002 shares two categories but carries forty tags -- a grab bag.
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 2)
          index_book(9002,
            genre_category_ids: [@novels],
            subject_category_ids: [@politics],
            similarity_category_count: 40)

          assert_equal ["9002", "9001"], ids_for(normalize_by_category_count: false)
          assert_equal ["9001", "9002"], ids_for(normalize_by_category_count: true)
        end

        test "requiring a genre match drops a book that shares only a location" do
          index_book(9001, location_category_ids: [@france], similarity_category_count: 1)

          assert_equal ["9001"], ids_for(require_genre_match: false)
          assert_empty ids_for(require_genre_match: true)
        end

        test "dropping common categories ignores a match on an over-common genre" do
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal ["9001"], ids_for(drop_common_categories: false)
          # books_novels_genre has item_count 300, so a ceiling of 150 removes it.
          assert_empty ids_for(drop_common_categories: true, max_category_item_count: 150)
        end

        test "keeps the rarest genre when the ceiling would remove every one of them" do
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          # A ceiling of 1 is below every genre's item_count. Without the guard the
          # book would have no genres left and require_genre_match would match nothing.
          assert_equal ["9001"], ids_for(drop_common_categories: true, max_category_item_count: 1)
        end

        test "excludes books sharing a series with the source book" do
          sibling = ::books_books(:got)
          series = ::Books::Series.create!(name: "Similarity Test Series")
          ::Books::SeriesBook.create!(series: series, book: @book)
          ::Books::SeriesBook.create!(series: series, book: sibling)
          index_book(sibling.id, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal [sibling.id.to_s], ids_for(exclude_same_series: false)
          assert_empty ids_for(exclude_same_series: true)
        end

        test "size is limit times over_fetch" do
          6.times { |i| index_book(9000 + i, genre_category_ids: [@novels], similarity_category_count: 1) }

          assert_equal 6, ids_for(limit: 2, over_fetch: 3).size
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

If `Books::Series` requires attributes beyond `name`, check the model and supply them —
`sed -n '/^class/,/^end/p' app/models/books/series.rb`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/lib/search/books/search/book_similar_test.rb`
Expected: FAIL — `NameError: uninitialized constant Search::Books::Search::BookSimilar`.

- [ ] **Step 4: Implement the search class**

Create `app/lib/search/books/search/book_similar.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      # One OpenSearch query returning books similar to a given book, scored from
      # shared genre, subject and location categories.
      #
      # Every category match is its own `term` clause rather than one `terms`
      # clause, and that is load-bearing: per-term clauses are scored by IDF, so
      # sharing a rare category ("Existentialist fiction") outweighs sharing a
      # common one ("Fiction"). A `terms` query is constant-score and throws that
      # away. Do not "simplify" these into a terms query.
      class BookSimilar < ::Search::Base::Search
        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(book, options = {})
          opts = Rails.application.config.x.book_similarity.merge(options)
          categories = categories_by_type(book, opts)
          return [] if categories.values.all?(&:empty?)

          response = search(build_query_definition(book, categories, opts))
          extract_hits_with_scores(response)
        end

        # => {"genre" => [Category, ...], "subject" => [...], "location" => [...]}
        def self.categories_by_type(book, opts)
          active = book.categories.select { |c| c.deleted == false }

          # The model's constant, not a copy: if the two lists drift, the model
          # indexes a category type this query never asks about, silently.
          ::Books::Book::SIMILARITY_CATEGORY_TYPES.index_with do |type|
            select_categories(active.select { |c| c.category_type == type }, opts)
          end
        end

        # Rarest first, because a rare category says more about a book than a
        # common one. The `c.id` tie-break is explicit so ordering is deterministic.
        def self.select_categories(scoped, opts)
          by_rarity = scoped.sort_by { |c| [c.item_count.to_i, c.id] }
          return by_rarity.first(opts[:max_categories_per_type]) unless opts[:drop_common_categories]

          kept = by_rarity.reject { |c| c.item_count.to_i > opts[:max_category_item_count] }
          # Load-bearing guard: a book tagged only "Fiction" would otherwise end up
          # with no genres, and require_genre_match would then match nothing at all.
          kept = by_rarity.first(1) if kept.empty? && by_rarity.any?
          kept.first(opts[:max_categories_per_type])
        end

        def self.build_query_definition(book, categories, opts)
          filter = [{term: {ranked: true}}]

          # The genre clauses appear twice on purpose. `filter` clauses contribute
          # no score, so requiring a genre match needs its own unscored bool here,
          # while the scored genre clauses stay in `should` with their boost.
          if opts[:require_genre_match] && categories["genre"].any?
            filter << {
              bool: {
                should: categories["genre"].map { |c| {term: {genre_category_ids: c.id.to_s}} },
                minimum_should_match: 1
              }
            }
          end

          should = boosted_terms(categories["genre"], :genre_category_ids, opts[:genre_boost]) +
            boosted_terms(categories["subject"], :subject_category_ids, opts[:subject_boost]) +
            boosted_terms(categories["location"], :location_category_ids, opts[:location_boost])

          if book.original_language_id.present?
            should << {term: {original_language_id: {value: book.original_language_id.to_s, boost: opts[:language_boost]}}}
          end

          if book.first_published_year.present?
            should << {
              range: {
                first_published_year: {
                  gte: book.first_published_year - opts[:era_years],
                  lte: book.first_published_year + opts[:era_years],
                  boost: opts[:era_boost]
                }
              }
            }
          end

          book.authors.each do |author|
            should << {term: {author_ids: {value: author.id.to_s, boost: opts[:author_boost]}}}
          end

          excluded = [book.id.to_s]
          excluded.concat(same_series_book_ids(book)) if opts[:exclude_same_series]

          bool = {
            filter: filter,
            must_not: [{ids: {values: excluded}}],
            should: should,
            # Explicit because a bool carrying a `filter` defaults its should-minimum to 0.
            minimum_should_match: 1
          }

          {
            size: opts[:limit] * opts[:over_fetch],
            min_score: opts[:min_score],
            _source: false,
            query: wrap_in_normalization(bool, opts)
          }
        end

        # Turns the raw sum into something closer to cosine similarity: without it
        # a book tagged with 40 categories has 40 chances to score and outranks a
        # tighter match with 6. `missing: 1` means documents indexed before the
        # similarity fields existed divide by 1 rather than erroring.
        def self.wrap_in_normalization(bool, opts)
          return {bool: bool} unless opts[:normalize_by_category_count]

          {
            function_score: {
              query: {bool: bool},
              field_value_factor: {
                field: "similarity_category_count",
                modifier: "sqrt",
                missing: 1
              },
              boost_mode: "divide"
            }
          }
        end

        def self.boosted_terms(categories, field, boost)
          categories.map { |c| {term: {field => {value: c.id.to_s, boost: boost}}} }
        end

        def self.same_series_book_ids(book)
          ::Books::SeriesBook
            .where(series_id: ::Books::SeriesBook.where(book_id: book.id).select(:series_id))
            .where.not(book_id: book.id)
            .pluck(:book_id)
            .map(&:to_s)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/search/books/search/book_similar_test.rb`
Expected: PASS

If "normalizing by category count ranks a tight match above a bloated one" fails, do **not**
adjust the assertion to match the output. That test is the only proof the `function_score`
wrapper is wired; a version that asserts whatever the code currently returns is worthless.

- [ ] **Step 6: Prove the flag tests are not vacuous**

Sort tests in this codebase have passed against deleted code before, because fixture id order
happened to match. Verify each flag test actually discriminates:

Temporarily change `wrap_in_normalization` to `return {bool: bool}` unconditionally.
Run: `bin/rails test test/lib/search/books/search/book_similar_test.rb`
Expected: the normalization test FAILS. Revert the change.

Then temporarily make `select_categories` return `by_rarity` unconditionally.
Run: `bin/rails test test/lib/search/books/search/book_similar_test.rb`
Expected: the "dropping common categories" test FAILS. Revert.

- [ ] **Step 7: Verify Zeitwerk can still boot**

`eager_load` is off in test, so a green suite does not prove autoloading works.

Run: `CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix
bin/rails test
git add config/initializers/book_similarity.rb app/lib/search/books/search/book_similar.rb test/lib/search/books/search/book_similar_test.rb
git commit -m "Add BookSimilar search with configurable accuracy flags"
```

---

### Task 3: The SimilarBooks service

**Files:**
- Create: `app/lib/services/books/similar_books.rb`
- Test: `test/lib/services/books/similar_books_test.rb`

**Interfaces:**
- Consumes: `::Search::Books::Search::BookSimilar.call(book, options)` from Task 2.
- Produces: `::Services::Books::SimilarBooks.call(book, **options) -> Result` where
  `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` and
  `data == {books: [::Books::Book], more_available: Boolean}`.

- [ ] **Step 1: Write the failing service tests**

Create `test/lib/services/books/similar_books_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class SimilarBooksTest < ActiveSupport::TestCase
      def setup
        @book = ::books_books(:crime_and_punishment)
        # got and clash are both by `king`; war_and_peace is by `tolstoy`.
        @got = ::books_books(:got)
        @clash = ::books_books(:clash)
        @war_and_peace = ::books_books(:war_and_peace)
      end

      def stub_hits(books)
        hits = books.each_with_index.map do |book, i|
          {id: book.id.to_s, score: 10.0 - i, source: nil}
        end
        ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits)
      end

      test "returns books in the order the search returned them" do
        stub_hits([@war_and_peace, @got])

        result = ::Services::Books::SimilarBooks.call(@book)

        assert result.success?
        assert_equal [@war_and_peace.id, @got.id], result.data[:books].map(&:id)
      end

      test "caps books per author" do
        stub_hits([@got, @clash, @war_and_peace])

        result = ::Services::Books::SimilarBooks.call(@book, max_per_author: 1)

        assert_equal [@got.id, @war_and_peace.id], result.data[:books].map(&:id)
      end

      test "allows two books by one author at the default cap" do
        stub_hits([@got, @clash, @war_and_peace])

        result = ::Services::Books::SimilarBooks.call(@book, max_per_author: 2)

        assert_equal [@got.id, @clash.id, @war_and_peace.id], result.data[:books].map(&:id)
      end

      test "truncates to the limit" do
        stub_hits([@war_and_peace, @got, @clash])

        result = ::Services::Books::SimilarBooks.call(@book, limit: 2)

        assert_equal 2, result.data[:books].size
      end

      test "reports more_available when the cap left more than the limit" do
        stub_hits([@war_and_peace, @got, @clash])

        assert ::Services::Books::SimilarBooks.call(@book, limit: 2).data[:more_available]
      end

      test "does not report more_available when it returned everything" do
        stub_hits([@war_and_peace, @got])

        refute ::Services::Books::SimilarBooks.call(@book, limit: 5).data[:more_available]
      end

      test "skips a hit whose database row is gone" do
        ::Search::Books::Search::BookSimilar.stubs(:call).returns([
          {id: "99999999", score: 10.0, source: nil},
          {id: @war_and_peace.id.to_s, score: 9.0, source: nil}
        ])

        result = ::Services::Books::SimilarBooks.call(@book)

        assert_equal [@war_and_peace.id], result.data[:books].map(&:id)
      end

      test "returns an empty success when the search returns nothing" do
        ::Search::Books::Search::BookSimilar.stubs(:call).returns([])

        result = ::Services::Books::SimilarBooks.call(@book)

        assert result.success?
        assert_empty result.data[:books]
        refute result.data[:more_available]
      end

      test "returns an empty success when the search raises" do
        ::Search::Books::Search::BookSimilar.stubs(:call).raises(StandardError, "opensearch down")

        result = ::Services::Books::SimilarBooks.call(@book)

        assert result.success?
        assert_empty result.data[:books]
      end

      test "preloads authors so rendering does not query per book" do
        stub_hits([@war_and_peace, @got])
        books = ::Services::Books::SimilarBooks.call(@book).data[:books]

        assert_queries_count(0) do
          books.each { |book| book.book_authors.map { |ba| ba.author.name } }
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/similar_books_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Books::SimilarBooks`.

- [ ] **Step 3: Implement the service**

Create `app/lib/services/books/similar_books.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Books similar to a given book: runs the OpenSearch similarity query, caps
    # how many can share an author, and loads the records the views need.
    class SimilarBooks
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(book, **options)
        new(book, **options).call
      end

      def initialize(book, **options)
        @book = book
        @options = options
        @config = Rails.application.config.x.book_similarity.merge(options)
      end

      def call
        hits = ::Search::Books::Search::BookSimilar.call(@book, @options)
        return empty if hits.empty?

        qualified = apply_author_cap(hits, load_books(hits))

        Result.new(
          success?: true,
          data: {books: qualified.first(limit), more_available: qualified.size > limit},
          errors: []
        )
      rescue => e
        # A search outage costs the card, not the page.
        Rails.logger.error "SimilarBooks failed for book #{@book.id}: #{e.message}"
        empty
      end

      private

      def limit
        @config[:limit]
      end

      # Root-anchored: inside Services::Books a bare `Books::Book` resolves to
      # Services::Books::Book and raises a confusing NameError.
      #
      # The image chain matters -- the similar page renders 25 CardComponents and
      # each one reads primary_image. Without it that is a 25-query N+1.
      def load_books(hits)
        ::Books::Book
          .where(id: hits.map { |hit| hit[:id].to_i })
          .includes(book_authors: :author)
          .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
          .index_by(&:id)
      end

      # An author's other books genuinely share nearly all the same categories, so
      # they win on merit and can fill the whole panel. Only a cap changes that --
      # the tiny same-author boost in the query is not what causes the domination.
      #
      # Deliberately does not stop at `limit`: running the cap across every
      # over-fetched hit is what makes more_available a fact rather than a guess.
      def apply_author_cap(hits, books_by_id)
        max = @config[:max_per_author]
        counts = Hash.new(0)

        hits.filter_map do |hit|
          book = books_by_id[hit[:id].to_i]
          next unless book

          author_ids = book.book_authors.map(&:author_id)
          next if author_ids.any? { |id| counts[id] >= max }

          author_ids.each { |id| counts[id] += 1 }
          book
        end
      end

      def empty
        Result.new(success?: true, data: {books: [], more_available: false}, errors: [])
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/similar_books_test.rb`
Expected: PASS

- [ ] **Step 5: Prove the author-cap test is not vacuous**

Temporarily delete the `next if author_ids.any? { |id| counts[id] >= max }` line.
Run: `bin/rails test test/lib/services/books/similar_books_test.rb`
Expected: "caps books per author" FAILS. Revert the change.

- [ ] **Step 6: Verify Zeitwerk**

Run: `CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
bin/rails test
git add app/lib/services/books/similar_books.rb test/lib/services/books/similar_books_test.rb
git commit -m "Add SimilarBooks service with per-author cap"
```

---

### Task 4: The Similar Books card on the show page

**Files:**
- Modify: `app/controllers/books/books_controller.rb` (`show`)
- Modify: `app/views/books/books/show.html.erb`
- Test: `test/controllers/books/books_controller_test.rb`

**Interfaces:**
- Consumes: `::Services::Books::SimilarBooks.call(book) -> Result` from Task 3.
- Produces: `@similar_books` (Array of `::Books::Book`) and `@more_similar_available` (Boolean)
  assigned in `show`. The "Show more" link that reads `@more_similar_available` is added in
  Task 5, because it needs the route Task 5 creates.

- [ ] **Step 1: Write the failing controller test**

Add to `test/controllers/books/books_controller_test.rb`:

```ruby
test "show assigns similar books" do
  ::Services::Books::SimilarBooks.stubs(:call).returns(
    ::Services::Books::SimilarBooks::Result.new(
      success?: true,
      data: {books: [books_books(:war_and_peace)], more_available: false},
      errors: []
    )
  )

  get book_url(slug: books_books(:crime_and_punishment).slug)

  assert_response :success
  assert_equal [books_books(:war_and_peace).id], assigns(:similar_books).map(&:id)
end

test "show renders when the similarity search fails" do
  ::Search::Books::Search::BookSimilar.stubs(:call).raises(StandardError, "opensearch down")

  get book_url(slug: books_books(:crime_and_punishment).slug)

  assert_response :success
  assert_empty assigns(:similar_books)
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: FAIL — `assigns(:similar_books)` is nil.

- [ ] **Step 3: Wire the controller**

In `app/controllers/books/books_controller.rb`, at the end of `show`, after the `@reviews` line:

```ruby
    # Rescued into an empty success inside the service, so an OpenSearch outage
    # costs this card rather than the whole page.
    similar = ::Services::Books::SimilarBooks.call(@book)
    @similar_books = similar.data[:books]
    @more_similar_available = similar.data[:more_available]
```

- [ ] **Step 4: Run the controller test**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: PASS

- [ ] **Step 5: Add the card to the view**

In `app/views/books/books/show.html.erb`, immediately after the Categories card's closing
`<% end %>` and before the `@list_items` block:

```erb
    <% if @similar_books.any? %>
      <div class="card bg-base-100 shadow-md" data-testid="similar-books">
        <div class="card-body">
          <h2 class="card-title text-xl">Similar Books</h2>
          <ul class="space-y-1">
            <% @similar_books.each do |similar_book| %>
              <li>
                <%= link_to similar_book.title,
                      book_path(slug: similar_book.slug, ranking_configuration_id: params[:ranking_configuration_id]),
                      class: "link" %>
                <% names = similar_book.book_authors.map { |ba| ba.author.name }.join(", ") %>
                <% if names.present? %>
                  <span class="text-base-content/70">by <%= names %></span>
                <% end %>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    <% end %>
```

- [ ] **Step 6: Run the full suite**

Run: `bin/rails test`
Expected: PASS. `test/lint/daisyui_v4_classes_test.rb` scans `app/views/**` and fails on any
removed daisyUI v4 class; the markup above uses none.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
bin/rails test
git add app/controllers/books/books_controller.rb app/views/books/books/show.html.erb test/controllers/books/books_controller_test.rb
git commit -m "Show a Similar Books card on the book page"
```

---

### Task 5: The full similar-books page

**Files:**
- Modify: `config/routes.rb` (books domain block, beside `get "book/:slug"`)
- Modify: `app/controllers/books/books_controller.rb` (add `similar`, extend `before_action`s)
- Create: `app/views/books/books/similar.html.erb`
- Modify: `app/views/books/books/show.html.erb` (add the "Show more" link)
- Test: `test/controllers/books/books_controller_test.rb`

**Interfaces:**
- Consumes: `::Services::Books::SimilarBooks` (Task 3), `@more_similar_available` (Task 4).
- Produces: route helper `book_similar_path(slug:, ranking_configuration_id: nil)` — the
  optional rc segment is omitted when the value is nil.

- [ ] **Step 1: Write the failing route and controller tests**

Add to `test/controllers/books/books_controller_test.rb`:

```ruby
test "similar responds successfully" do
  get book_similar_url(slug: books_books(:crime_and_punishment).slug)

  assert_response :success
end

test "similar 404s for an unknown slug" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get book_similar_url(slug: "no-such-book")
  end
end

# The corrections DDoS came from a route inside scope "(/rc/:ranking_configuration_id)"
# whose controller never read the segment: every distinct value returned 200 with a
# 24h public cache, so each one was a fresh cache key and a full render. This action
# calls load_ranking_configuration, so garbage 404s instead of being cached.
test "similar 404s for an unknown ranking configuration id" do
  assert_raises(ActiveRecord::RecordNotFound) do
    get book_similar_url(slug: books_books(:crime_and_punishment).slug, ranking_configuration_id: 999_999)
  end
end

test "similar requests the page limit rather than the card limit" do
  ::Services::Books::SimilarBooks
    .expects(:call)
    .with(anything, limit: Rails.application.config.x.book_similarity[:page_limit])
    .returns(::Services::Books::SimilarBooks::Result.new(
      success?: true, data: {books: [], more_available: false}, errors: []
    ))

  get book_similar_url(slug: books_books(:crime_and_punishment).slug)

  assert_response :success
end
```

Then add the route-shape and N+1 guards. `assert_unroutable` is a private method defined
inside `test/controllers/corrections_controller_test.rb:49`, **not** a shared module — copy it
into this test class:

```ruby
  # Asserts both halves of the corrections fix at once: the 404 proves nothing was
  # rendered, and the absent Cache-Control proves Cloudflare has nothing to key on.
  # A 200 that merely forgot to cache would pass on the header check alone.
  def assert_unroutable(path)
    get path

    assert_response :not_found
    assert_nil response.headers["Cache-Control"],
      "#{path} still answers with a cache header, so it is still a cacheable origin hit"
  end

test "similar is not routable with a non-html format" do
  assert_unroutable "/book/crime-and-punishment/similar.json"
end

test "similar does not N+1 across the grid" do
  books = ::Books::Book
    .where(id: [books_books(:war_and_peace).id, books_books(:got).id])
    .includes(book_authors: :author)
    .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
    .to_a

  ::Services::Books::SimilarBooks.stubs(:call).returns(
    ::Services::Books::SimilarBooks::Result.new(
      success?: true, data: {books: books, more_available: false}, errors: []
    )
  )

  # Warm any per-process caching first so the measured run is representative.
  get book_similar_url(slug: books_books(:crime_and_punishment).slug)

  assert_queries_count(15) do
    get book_similar_url(slug: books_books(:crime_and_punishment).slug)
  end
end
```

If `assert_queries_count(15)` fails on the exact count, replace 15 with the number the failure
reports **only after confirming it does not scale with the number of books** — add a third book
to the stub and check the count does not move. A count that grows per book is the N+1 this test
exists to catch.

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'book_similar_url'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the books domain block, in the scope that already holds
`get "book/:slug"`:

```ruby
    scope "(/rc/:ranking_configuration_id)" do
      get "book/:slug", to: "books/books#show", as: :book
      # Inside the rc scope deliberately: BooksController#similar calls
      # load_ranking_configuration, so an unrecognised id raises RecordNotFound
      # instead of returning a cacheable 200 under an unbounded set of URLs.
      # constraints closes the (.:format) axis the same way the corrections routes do.
      get "book/:slug/similar", to: "books/books#similar", as: :book_similar,
        constraints: {format: /html/}
    end
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/books/books_controller.rb`, extend both `before_action` lines and add the action:

```ruby
  before_action :load_ranking_configuration, only: [:show, :similar]
  before_action :cache_for_show_page, only: [:show, :similar]
```

```ruby
  def similar
    # find_by!(slug:), never friendly.find -- 137 books have purely numeric slugs
    # and friendly_id resolves slugs before primary keys.
    @book = ::Books::Book.find_by!(slug: params[:slug])

    @ranked_item = if @ranking_configuration
      @ranking_configuration.ranked_items.where.not(rank: nil).find_by(item: @book)
    end
    @indexable = @ranked_item.present?

    @similar_books = ::Services::Books::SimilarBooks
      .call(@book, limit: Rails.application.config.x.book_similarity[:page_limit])
      .data[:books]
  end
```

`books_robots_content` already returns `noindex, follow` for any `/rc/`-prefixed URL, so
setting `@indexable` is all this action needs to do about search engines.

- [ ] **Step 5: Create the view**

Create `app/views/books/books/similar.html.erb`:

```erb
<%
  authors = @book.book_authors.map(&:author)
  author_names = authors.map(&:name).join(", ")
  content_for :page_title, "Books similar to #{@book.title} | The Greatest Books"
  content_for :meta_description, "Books similar to #{@book.title}#{" by #{author_names}" if author_names.present?}, ranked by shared genres, subjects and settings."
%>

<div class="mb-6">
  <h1 class="text-3xl font-bold">Books similar to <%= @book.title %></h1>
  <p class="mt-2">
    <%= link_to "Back to #{@book.title}",
          book_path(slug: @book.slug, ranking_configuration_id: params[:ranking_configuration_id]),
          class: "link" %>
  </p>
</div>

<% if @similar_books.any? %>
  <div class="<%= Books::CardComponent::GRID_CONTAINER_CLASS %>">
    <% @similar_books.each_with_index do |similar_book, index| %>
      <%= render Books::CardComponent.new(book: similar_book, index: index) %>
    <% end %>
  </div>
<% else %>
  <p class="text-base-content/70">No similar books found for this title.</p>
<% end %>
```

- [ ] **Step 6: Add the "Show more" link to the card**

In `app/views/books/books/show.html.erb`, inside the Similar Books card added in Task 4,
directly after the closing `</ul>`:

```erb
          <% if @more_similar_available %>
            <p class="mt-2">
              <%= link_to "Show more",
                    book_similar_path(slug: @book.slug, ranking_configuration_id: params[:ranking_configuration_id]),
                    class: "link",
                    data: {testid: "similar-books-show-more"} %>
            </p>
          <% end %>
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: PASS

- [ ] **Step 8: Run the full suite**

Run: `bin/rails test`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb --fix
bin/rails test
git add config/routes.rb app/controllers/books/books_controller.rb app/views/books/books/similar.html.erb app/views/books/books/show.html.erb test/controllers/books/books_controller_test.rb
git commit -m "Add the full similar books page"
```

---

### Task 6: Playwright E2E coverage

**Files:**
- Create: `e2e/tests/books/similar-books.spec.ts`

**Interfaces:**
- Consumes: the rendered card (`[data-testid="similar-books"]`) and link
  (`[data-testid="similar-books-show-more"]`) from Tasks 4 and 5.

- [ ] **Step 1: Reindex development so the similarity fields exist locally**

E2E runs against the local development app and its real OpenSearch index. The new fields do
not exist there until the index is rebuilt.

Run: `bin/rails search:books:recreate_books`
Expected: "✓ Books index recreated and reindexed". This takes a while — 126K books.

- [ ] **Step 2: Start the development server**

`bin/dev` self-terminates without a TTY: `Procfile.dev`'s css line ends in a foreground
Tailwind watcher that exits on closed stdin, and foreman then SIGTERMs everything else.
Assets are already built, so run the web process only:

```bash
setsid bin/rails server -p 3000 </dev/null &
```

- [ ] **Step 3: Pick a book that actually has similar books**

```bash
bin/rails runner 'b = Books::Book.joins(:list_items).distinct.first; puts b.slug'
```

Use that slug throughout the spec below if `war-and-peace` turns out to have no results.

- [ ] **Step 4: Write the E2E test**

Create `e2e/tests/books/similar-books.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Similar books', () => {
  test('a book page shows similar books that link through', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const card = page.getByTestId('similar-books');
    await expect(card).toBeVisible();

    const firstLink = card.locator('a').first();
    const title = (await firstLink.textContent())?.trim() ?? '';
    await firstLink.click();

    await expect(page).toHaveURL(/\/book\//);
    await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible();
  });

  test('show more opens the full similar books grid', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    await page.getByTestId('similar-books-show-more').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace\/similar$/);
    await expect(
      page.getByRole('heading', { level: 1, name: /Books similar to/ })
    ).toBeVisible();
    await expect(page.locator('.card').first()).toBeVisible();
  });

  test('the similar page links back to the book', async ({ page }) => {
    await page.goto('/book/war-and-peace/similar');

    await page.getByRole('link', { name: /Back to/ }).click();

    await expect(page).toHaveURL(/\/book\/war-and-peace$/);
  });
});
```

- [ ] **Step 5: Run the E2E test**

Run: `yarn test:e2e --grep "Similar books"`
Expected: 3 passed.

If every test fails at the auth-setup step, `e2e/.env` is missing its
`PLAYWRIGHT_ADMIN_EMAIL`/`PLAYWRIGHT_ADMIN_PASSWORD` — it is symlinked into this worktree from
the main checkout. If the admin user itself is gone, run `bin/rails e2e:admin`.

- [ ] **Step 6: Commit**

```bash
git add e2e/tests/books/similar-books.spec.ts
git commit -m "Add similar books E2E coverage"
```

---

### Task 7: Tuning pass (manual, no test cycle)

The four flags all default on and the thresholds are placeholders. This task settles them
against real development data. It produces a config change and an update to the spec — no
application code and no new tests.

**Files:**
- Modify: `config/initializers/book_similarity.rb`
- Modify: `docs/superpowers/specs/2026-08-25-books-similar-books-design.md` ("Deferred / open")

- [ ] **Step 1: Confirm the index is current**

If Task 6 was skipped, run `bin/rails search:books:recreate_books` now. Every knob below reads
the similarity fields; without the reindex every result is empty.

- [ ] **Step 2: Pick a spread of books to judge**

Choose at least six by hand across different shapes: a famous ranked novel, an obscure ranked
one, a nonfiction title, a book by a prolific author, a book with very few categories, and a
book you know has a duplicate in the corpus. Record the slugs.

- [ ] **Step 3: Establish the baseline**

With all four flags on and the shipped thresholds, visit `/book/<slug>/similar` for each and
note whether the results look right. Duplicates appearing is expected and deliberate.

- [ ] **Step 4: Tune `min_score`**

`min_score: 0` returns anything with a genre match, so weak tails appear on obscure books.
Raise it a little at a time, restarting the server after each edit, until weak results vanish
without emptying the page for obscure books. Legacy's `5` is meaningless here — normalization
changed the scale.

- [ ] **Step 5: Tune `max_category_item_count`**

25,000 cuts `Fiction` (68,333 books), `Nonfiction` (56,222), `Fictional Location` (36,656),
`Identity` (31,658) and `United States` (29,274). Lower it if results still feel generic;
raise it if pages come back sparse. Check an obscure book after each change — this is the knob
most likely to empty a page.

- [ ] **Step 6: Tune `max_per_author` for the page**

The default of 2 across 25 slots forces at least 13 distinct authors. If the full page feels
too fragmented, raise it. It is one value shared by the card and the page, so a change affects
both.

- [ ] **Step 7: Try each accuracy flag off, one at a time**

Turn one off, restart, compare the same book, turn it back on. This is the point of the flags:
confirm each earns its place rather than trusting the defaults.

- [ ] **Step 8: Record the chosen values and commit**

Replace the "Deferred / open" bullets in the spec that name these as placeholders with the
values you settled on and a sentence on why.

```bash
bundle exec standardrb --fix
bin/rails test
git add config/initializers/book_similarity.rb docs/superpowers/specs/2026-08-25-books-similar-books-design.md
git commit -m "Settle similar books tuning values"
```

---

## Deployment note (not a task)

Merging to `main` deploys to production. After the deploy, run
`bin/rails search:books:recreate_books` **in production, deliberately, at low traffic** —
`reindex_all` deletes the index before rebuilding, so book search on the live site is down for
the duration of the 126K-book rebuild.

Between deploy and reindex the similarity fields are absent, `require_genre_match` matches
nothing, the service returns empty, the card does not render, and the page shows its empty
state. Fails quiet, not broken.
