# Books Global Canon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the legacy site's `/global-canon` page — an algorithmically balanced literary canon drawn from the ranked books — to the new app, keeping its visitor-facing customisation, extending the non-fiction share to 0–100%, and adding visitor-selectable genre exclusions.

**Architecture:** Four plain Ruby objects in `app/lib/books/` (params → settings, settings → selection, settings → canonical path) behind one controller. All settings live in the URL **path**, never a query string, so every variant is its own Cloudflare edge-cache entry. The selection algorithm is a faithful port of `GlobalCanonGenerator` from the legacy app, with its two load-bearing behaviours (fiction pass first, country counter shared across passes) pinned by tests.

**Tech Stack:** Rails 8.1, Minitest + Mocha + fixtures, ViewComponents, Stimulus, daisyUI 5 / Tailwind 4, Pagy (not used here — the canon is single-page), Playwright for E2E.

**Spec:** `docs/superpowers/specs/2026-08-18-books-global-canon-design.md` — read it alongside this plan.

## Global Constraints

- **Run every command from `web-app/`.** `cd web-app` first. Docs live at the project root, not `web-app/docs/`.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. `--fix` autocorrects.
- **Never run destructive DB commands.** The development database holds books data that exists nowhere else and takes hours to rebuild. Never run `create_fixtures`, `db:drop`, `db:reset`, `db:schema:load`, or bulk `delete_all`/`destroy_all` outside `RAILS_ENV=test`. To inspect a fixture, read the YAML.
- **Do not run brakeman.** The gate is `bin/rails test` + `standardrb` + Playwright.
- **Do not touch the movies domain**, and do not raise movies issues.
- **Root-anchor cross-namespace constants.** Inside `module Books`, write `::Books::Category`, `::CategoryItem`, `::RankedItem` — never bare `Books::Category`. A bare nested reference has produced confusing `NameError`s in this repo more than once.
- **daisyUI is 5.7.x.** These classes were removed in v5 and fail silently: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`. `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence; the fix is to remove the class, never to add an allowlist entry.
- **Test honesty rule.** No `assert_empty` as a primary assertion, no bare `assert_response :success` standing alone. For every test written, **delete the line of production code it covers and confirm the test goes red** before moving on. Tests in this repo have passed against deleted code more than once.
- **Rails 8 enum syntax:** `enum :status, {active: 0}`.
- Commit after every task. Branch is `books-global-canon`, already created. Do not push or open a PR without asking.

---

## File Structure

**Increment 1 — core canon**

| File | Responsibility |
| --- | --- |
| `app/lib/books/global_canon_params.rb` | Raw params → validated `Settings` value object. 404s on unroutable values. |
| `app/lib/books/global_canon_query.rb` | The selection algorithm. Settings + RC → `Result` (ranked items + counts). |
| `app/lib/books/global_canon_path.rb` | `Settings` → canonical path string. The only place URL shape lives. |
| `app/controllers/books/global_canon_controller.rb` | `show` and `settings`. Canonicalisation, caching, indexability. |
| `app/views/books/global_canon/show.html.erb` | Header, settings form, short-list note, card grid. |
| `config/routes.rb` | Four path shapes + the form target, with constraints. |
| `app/views/books/shared/_nav_links.html.erb` | Nav entry. |
| `test/fixtures/categories.yml` | Adds `books_nonfiction_genre`. |

**Increment 2 — genre exclusion**

| File | Responsibility |
| --- | --- |
| `app/lib/books/global_canon_params.rb` | Extended: resolves `excluded_genres` slugs. |
| `app/lib/books/global_canon_path.rb` | Extended: emits the `/excluding/` segment. |
| `app/controllers/books/global_canon_controller.rb` | Adds `genres` (JSON for the picker). |
| `app/views/books/global_canon/show.html.erb` | Adds the picker fieldset. |
| `config/routes.rb` | Adds the `/excluding/` shape and the `genres` endpoint. |

`GlobalCanonQuery` already accepts and applies `excluded_genres` from Task 2 — the algorithm is where exclusion belongs, and it is unit-tested from the start. Increment 2 wires the URL and UI to it.

---

## Increment 1: Core canon

### Task 1: `Books::GlobalCanonParams`

**Files:**
- Create: `app/lib/books/global_canon_params.rb`
- Test: `test/lib/books/global_canon_params_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::GlobalCanonParams.call(params) -> Settings`. `Settings` is a `Struct` with members `total_books` (Integer), `nonfiction_percentage` (Integer), `max_books_per_country` (Integer), `excluded_genres` (Array of `Books::Category`, always `[]` until Task 6), and an instance method `default?` returning Boolean. Raises `ActiveRecord::RecordNotFound` on any unroutable value. Constants: `TOTALS`, `DEFAULT_TOTAL`, `DEFAULT_PERCENTAGE`, `DEFAULT_COUNTRY_CAP`, `MAX_EXCLUDED_GENRES`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/global_canon_params_test.rb`:

```ruby
require "test_helper"

module Books
  class GlobalCanonParamsTest < ActiveSupport::TestCase
    test "returns the defaults when no segments are given" do
      settings = Books::GlobalCanonParams.call({})

      assert_equal 150, settings.total_books
      assert_equal 20, settings.nonfiction_percentage
      assert_equal 3, settings.max_books_per_country
      assert_equal [], settings.excluded_genres
    end

    test "default? is true only for the exact default triple" do
      assert Books::GlobalCanonParams.call({}).default?
      refute Books::GlobalCanonParams.call(total_books: "250").default?
      refute Books::GlobalCanonParams.call(nonfiction_percentage: "0").default?
      refute Books::GlobalCanonParams.call(max_books_per_country: "1").default?
    end

    test "reads each setting from the params" do
      settings = Books::GlobalCanonParams.call(
        total_books: "250", nonfiction_percentage: "100", max_books_per_country: "1"
      )

      assert_equal 250, settings.total_books
      assert_equal 100, settings.nonfiction_percentage
      assert_equal 1, settings.max_books_per_country
    end

    test "accepts a non-fiction percentage the menu does not offer" do
      # The menu offers multiples of five; the route accepts any integer 0..100
      # so a hand-typed or bookmarked value still resolves.
      assert_equal 37, Books::GlobalCanonParams.call(nonfiction_percentage: "37").nonfiction_percentage
    end

    test "accepts both ends of the non-fiction range" do
      assert_equal 0, Books::GlobalCanonParams.call(nonfiction_percentage: "0").nonfiction_percentage
      assert_equal 100, Books::GlobalCanonParams.call(nonfiction_percentage: "100").nonfiction_percentage
    end

    test "404s on a total the menu does not offer" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(total_books: "175") }
    end

    test "404s on a percentage above 100" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(nonfiction_percentage: "101") }
    end

    test "404s on a country cap outside 1..10" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(max_books_per_country: "0") }
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(max_books_per_country: "11") }
    end

    test "404s on a non-numeric value" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(total_books: "many") }
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/books/global_canon_params_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Books::GlobalCanonParams`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/books/global_canon_params.rb`:

```ruby
module Books
  # Raw params -> validated canon settings.
  #
  # Mirrors Books::FilterParams: an unroutable value raises RecordNotFound
  # rather than falling back to a default, so a hand-edited URL 404s instead of
  # quietly serving a different canon under an address that promised another.
  #
  # The route constraints already reject these values. This is the defensive
  # half, and the only thing standing between a future-loosened constraint and
  # a page that lies about what it is showing.
  class GlobalCanonParams
    TOTALS = [50, 100, 150, 200, 250].freeze
    PERCENTAGES = (0..100)
    COUNTRY_CAPS = (1..10)
    MAX_EXCLUDED_GENRES = 6

    DEFAULT_TOTAL = 150
    DEFAULT_PERCENTAGE = 20
    DEFAULT_COUNTRY_CAP = 3

    INTEGER_FORMAT = /\A\d+\z/

    # Constants inside this block resolve against the lexical scope where the
    # block is written -- i.e. Books::GlobalCanonParams -- not against the
    # anonymous Struct class.
    Settings = Struct.new(
      :total_books, :nonfiction_percentage, :max_books_per_country, :excluded_genres,
      keyword_init: true
    ) do
      def default?
        total_books == DEFAULT_TOTAL &&
          nonfiction_percentage == DEFAULT_PERCENTAGE &&
          max_books_per_country == DEFAULT_COUNTRY_CAP &&
          excluded_genres.empty?
      end
    end

    def self.call(params)
      new(params).call
    end

    def initialize(params)
      @params = params
    end

    def call
      Settings.new(
        total_books: integer(@params[:total_books], DEFAULT_TOTAL) { |v| TOTALS.include?(v) },
        nonfiction_percentage: integer(@params[:nonfiction_percentage], DEFAULT_PERCENTAGE) { |v| PERCENTAGES.cover?(v) },
        max_books_per_country: integer(@params[:max_books_per_country], DEFAULT_COUNTRY_CAP) { |v| COUNTRY_CAPS.cover?(v) },
        excluded_genres: []
      )
    end

    private

    def integer(raw, default)
      return default if raw.blank?
      raise ActiveRecord::RecordNotFound unless raw.to_s.match?(INTEGER_FORMAT)

      value = raw.to_i
      raise ActiveRecord::RecordNotFound unless yield(value)

      value
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/books/global_canon_params_test.rb
```

Expected: PASS, 9 runs, 0 failures.

- [ ] **Step 5: Verify the tests are not vacuous**

Temporarily change `raise ActiveRecord::RecordNotFound unless yield(value)` to `value`, re-run, and confirm the three 404 tests fail. Restore the line.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/global_canon_params.rb test/lib/books/global_canon_params_test.rb
git add app/lib/books/global_canon_params.rb test/lib/books/global_canon_params_test.rb
git commit -m "feat(books): validated settings object for the global canon"
```

---

### Task 2: `Books::GlobalCanonQuery`

**Files:**
- Create: `app/lib/books/global_canon_query.rb`
- Test: `test/lib/books/global_canon_query_test.rb`
- Modify: `test/fixtures/categories.yml` (append one fixture)

**Interfaces:**
- Consumes: `Books::GlobalCanonParams::Settings` from Task 1.
- Produces: `Books::GlobalCanonQuery.call(ranking_configuration:, settings:) -> Result`. `Result` is a `Struct` with members `ranked_items` (an ordered `RankedItem` relation), `requested` (Integer), `delivered` (Integer), `blocked_by_country` (Integer), `blocked_by_author` (Integer). Constant `BLOCKED_BOOK_IDS`.

**Background the implementer needs:**

The legacy algorithm (`/home/shane/dev/the-greatest-books/admin/app/lib/global_canon_generator.rb`) walks the ranked books **twice** — fiction first, then non-fiction — taking a book only if its country is under the cap and its author is unused. Two details are load-bearing and must not be "cleaned up":

1. **Fiction runs first**, and
2. **the country and author counters are shared across both passes**, so fiction consumes country slots before non-fiction runs.

A third detail is easy to miss: a book with no country lands in the `nil` country bucket, and that bucket is capped like any other. Legacy does this (`book.countries.first&.id`) and it is preserved. Same for authors.

- [ ] **Step 1: Add the missing fixture**

`test/fixtures/categories.yml` has `books_fiction_genre` but no non-fiction counterpart. Append this after the `books_fiction_genre` block:

```yaml
books_nonfiction_genre:
  type: "Books::Category"
  name: "Nonfiction"
  slug: "nonfiction"
  description: "Nonfiction books"
  category_type: 0  # genre
  import_source: 1  # open_library
  alternative_names: []
  item_count: 0
  deleted: false
  parent:
```

- [ ] **Step 2: Write the failing test**

Create `test/lib/books/global_canon_query_test.rb`:

```ruby
require "test_helper"

module Books
  class GlobalCanonQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @fiction = categories(:books_fiction_genre)
      @nonfiction = categories(:books_nonfiction_genre)
      @next_rank = 0
    end

    test "orders the result by rank" do
      a = rank_book(kind: :fiction)
      b = rank_book(kind: :fiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [a.id, b.id], result.ranked_items.map(&:item_id)
    end

    test "takes at most max_books_per_country from one country" do
      france = country("France")
      4.times { rank_book(kind: :fiction, country: france) }

      result = call(total_books: 10, nonfiction_percentage: 0, max_books_per_country: 3)

      assert_equal 3, result.delivered
      assert_equal 1, result.blocked_by_country
    end

    test "takes at most one book per author" do
      author = author("Repeat Author")
      3.times { rank_book(kind: :fiction, author: author) }

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal 1, result.delivered
      assert_equal 2, result.blocked_by_author
    end

    test "caps books with no country in a single bucket, as legacy does" do
      4.times { rank_book(kind: :fiction, country: nil) }

      result = call(total_books: 10, nonfiction_percentage: 0, max_books_per_country: 2)

      assert_equal 2, result.delivered
    end

    test "fiction consumes country slots before the non-fiction pass runs" do
      # Both fiction books outrank both non-fiction books, and all four share a
      # country whose cap is 1. Fiction-first means the fiction book wins the
      # slot and the non-fiction quota goes unfilled. If the passes were
      # reordered, the non-fiction book would take it instead -- so this test
      # fails against a flipped implementation rather than passing either way.
      japan = country("Japan")
      fiction_book = rank_book(kind: :fiction, country: japan)
      rank_book(kind: :nonfiction, country: japan)

      result = call(total_books: 2, nonfiction_percentage: 50, max_books_per_country: 1)

      assert_equal [fiction_book.id], result.ranked_items.map(&:item_id)
    end

    test "never returns a blocked book" do
      blocked = rank_book(kind: :fiction, id: Books::GlobalCanonQuery::BLOCKED_BOOK_IDS.first)
      allowed = rank_book(kind: :fiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [allowed.id], result.ranked_items.map(&:item_id)
      refute_includes result.ranked_items.map(&:item_id), blocked.id
    end

    test "0 percent yields no non-fiction" do
      fiction_book = rank_book(kind: :fiction)
      rank_book(kind: :nonfiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [fiction_book.id], result.ranked_items.map(&:item_id)
    end

    test "100 percent yields no fiction" do
      rank_book(kind: :fiction)
      nonfiction_book = rank_book(kind: :nonfiction)

      result = call(total_books: 10, nonfiction_percentage: 100)

      assert_equal [nonfiction_book.id], result.ranked_items.map(&:item_id)
    end

    test "a book in neither category never appears, at either extreme" do
      uncategorised = rank_book(kind: nil)

      [0, 50, 100].each do |percentage|
        result = call(total_books: 10, nonfiction_percentage: percentage)
        refute_includes result.ranked_items.map(&:item_id), uncategorised.id,
          "uncategorised book appeared at #{percentage}% non-fiction"
      end
    end

    test "an excluded genre removes its books" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      excluded = rank_book(kind: :fiction)
      ::CategoryItem.create!(category: poetry, item: excluded)
      kept = rank_book(kind: :fiction)

      result = call(total_books: 10, nonfiction_percentage: 0, excluded_genres: [poetry])

      assert_equal [kept.id], result.ranked_items.map(&:item_id)
    end

    test "reports the requested and delivered counts" do
      rank_book(kind: :fiction)

      result = call(total_books: 50, nonfiction_percentage: 0)

      assert_equal 50, result.requested
      assert_equal 1, result.delivered
    end

    test "returns nothing when the fiction category is missing" do
      # A public page must not 500 on a data problem. The short-list note
      # explains the empty result instead.
      @fiction.destroy!
      rank_book(kind: :nonfiction)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal 0, result.delivered
    end

    test "spends the lowest-position author, not the first-created one" do
      first_author = author("First Author")
      second_author = author("Second Author")

      book_a = rank_book(kind: :fiction, author: nil)
      # The position-2 join row is created FIRST, so it has the lower id. Only
      # `order(:position, :id)` picks first_author here; `order(:id)` would pick
      # second_author and book_b below would then be selected.
      ::Books::BookAuthor.create!(book: book_a, author: second_author, position: 2, role: :author)
      ::Books::BookAuthor.create!(book: book_a, author: first_author, position: 1, role: :author)

      book_b = rank_book(kind: :fiction, author: first_author)

      result = call(total_books: 10, nonfiction_percentage: 0)

      assert_equal [book_a.id], result.ranked_items.map(&:item_id)
      refute_includes result.ranked_items.map(&:item_id), book_b.id
    end

    test "spends the lowest-id country when a book has two" do
      first_country = country("First Country")
      second_country = country("Second Country")

      book_a = rank_book(kind: :fiction, country: first_country)
      ::Books::BookCountry.create!(book: book_a, country: second_country)

      # book_b shares first_country under a cap of 1. It is blocked ONLY if
      # book_a spent first_country; had book_a spent second_country, first_country
      # would still be free and book_b would be selected.
      book_b = rank_book(kind: :fiction, country: first_country)

      result = call(total_books: 10, nonfiction_percentage: 0, max_books_per_country: 1)

      assert_equal [book_a.id], result.ranked_items.map(&:item_id)
      refute_includes result.ranked_items.map(&:item_id), book_b.id
    end

    private

    def call(total_books:, nonfiction_percentage:, max_books_per_country: 10, excluded_genres: [])
      settings = ::Books::GlobalCanonParams::Settings.new(
        total_books: total_books,
        nonfiction_percentage: nonfiction_percentage,
        max_books_per_country: max_books_per_country,
        excluded_genres: excluded_genres
      )
      ::Books::GlobalCanonQuery.call(ranking_configuration: @rc, settings: settings)
    end

    def rank_book(kind:, country: :auto, author: :auto, id: nil)
      @next_rank += 1
      book = ::Books::Book.create!(id: id, title: "Canon Book #{@next_rank}")

      resolved_country = (country == :auto) ? country("Country #{@next_rank}") : country
      ::Books::BookCountry.create!(book: book, country: resolved_country) if resolved_country

      resolved_author = (author == :auto) ? author("Author #{@next_rank}") : author
      ::Books::BookAuthor.create!(book: book, author: resolved_author, position: 1, role: :author) if resolved_author

      category = {fiction: @fiction, nonfiction: @nonfiction}[kind]
      ::CategoryItem.create!(category: category, item: book) if category

      ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      book
    end

    def country(name)
      ::Books::Country.create!(name: name, slug: name.parameterize, labels: [])
    end

    def author(name)
      ::Books::Author.create!(name: name)
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/lib/books/global_canon_query_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Books::GlobalCanonQuery`.

- [ ] **Step 4: Write the implementation**

Create `app/lib/books/global_canon_query.rb`:

```ruby
module Books
  # The global canon selection algorithm, ported from the legacy site's
  # GlobalCanonGenerator.
  #
  # Walks the ranked books twice -- fiction first, then non-fiction -- taking a
  # book only when its country is under the cap and its author is unused. TWO
  # DETAILS ARE LOAD-BEARING and must not be tidied:
  #
  #   1. Fiction runs FIRST.
  #   2. The country and author counters are SHARED across both passes.
  #
  # Together they are why the non-fiction tail is more geographically
  # constrained than the fiction head: fiction has already spent the slots.
  # Reordering the passes produces a different canon, and a test pins it.
  #
  # A book with no country falls into the `nil` bucket, which is capped like any
  # other country. Legacy does this (`book.countries.first&.id`) and it is
  # deliberately preserved. Same for authors.
  class GlobalCanonQuery
    # Four books excluded by hand on the legacy site. The migration preserved
    # book ids, so these resolve 1:1 in this app.
    #
    #   2526  The Protocols of the Elders of Zion  antisemitic forgery
    #   1974  Mein Kampf
    #  15365  Revolt Against The Modern World      fascist esotericism
    #    705  The Elements of Style                a style manual, not literature
    BLOCKED_BOOK_IDS = [2526, 1974, 15365, 705].freeze

    FICTION_SLUG = "fiction".freeze
    NONFICTION_SLUG = "nonfiction".freeze

    Result = Struct.new(
      :ranked_items, :requested, :delivered, :blocked_by_country, :blocked_by_author,
      keyword_init: true
    )

    def self.call(ranking_configuration:, settings:)
      new(ranking_configuration: ranking_configuration, settings: settings).call
    end

    def initialize(ranking_configuration:, settings:)
      @ranking_configuration = ranking_configuration
      @settings = settings
      @country_used = Hash.new(0)
      @author_used = Hash.new(0)
      @blocked_by_country = 0
      @blocked_by_author = 0
    end

    def call
      nonfiction_quota = (@settings.total_books * @settings.nonfiction_percentage / 100.0).round
      fiction_quota = @settings.total_books - nonfiction_quota

      selected = select_pass(candidates_in(FICTION_SLUG), fiction_quota)
      selected += select_pass(candidates_in(NONFICTION_SLUG), nonfiction_quota)

      Result.new(
        ranked_items: ranked_items_for(selected),
        requested: @settings.total_books,
        delivered: selected.size,
        blocked_by_country: @blocked_by_country,
        blocked_by_author: @blocked_by_author
      )
    end

    private

    def select_pass(candidate_ids, quota)
      return [] if quota <= 0

      picked = []
      candidate_ids.each do |id|
        if @country_used[country_by_book[id]] >= @settings.max_books_per_country
          @blocked_by_country += 1
          next
        end
        if @author_used[author_by_book[id]] >= 1
          @blocked_by_author += 1
          next
        end

        picked << id
        @country_used[country_by_book[id]] += 1
        @author_used[author_by_book[id]] += 1
        break if picked.size >= quota
      end
      picked
    end

    # Rank-ordered book ids carrying the given genre. Legacy loaded every ranked
    # book as an AR object with two associations preloaded to answer a question
    # about integers; measured against production data that costs ~0.4s where
    # plucking costs a fraction of it, and most settings scan nearly the whole
    # ranked set anyway (250 books at 50% non-fiction reaches position 21,374 of
    # 24,242), so there is nothing to gain from batching with an early exit.
    def candidates_in(slug)
      category = ::Books::Category.active.find_by(slug: slug)
      return [] if category.nil?

      member_ids = ::CategoryItem
        .where(category_id: category.id, item_type: "Books::Book")
        .pluck(:item_id)
        .to_set

      ranked_ids.select { |id| member_ids.include?(id) }
    end

    def ranked_ids
      @ranked_ids ||= begin
        ids = ::RankedItem
          .where(ranking_configuration_id: @ranking_configuration.id, item_type: "Books::Book")
          .where.not(rank: nil)
          .where.not(item_id: BLOCKED_BOOK_IDS)
          .order(:rank)
          .pluck(:item_id)

        ids - excluded_book_ids
      end
    end

    def excluded_book_ids
      return [] if @settings.excluded_genres.blank?

      ::CategoryItem
        .where(category_id: @settings.excluded_genres.map(&:id), item_type: "Books::Book")
        .pluck(:item_id)
    end

    # `order(:id)` reproduces legacy's `book.countries.first`, which had no
    # explicit order and followed join-row insertion order in practice. Which row
    # wins is not cosmetic -- it decides which country bucket the book spends --
    # so it is pinned by a test.
    def country_by_book
      @country_by_book ||= first_per_book(
        ::Books::BookCountry.where(book_id: ranked_ids).order(:id).pluck(:book_id, :country_id)
      )
    end

    # `order(:position, :id)` reproduces `book.authors.first`, which follows the
    # `has_many :book_authors, -> { order(:position) }` association order.
    def author_by_book
      @author_by_book ||= first_per_book(
        ::Books::BookAuthor.where(book_id: ranked_ids).order(:position, :id).pluck(:book_id, :author_id)
      )
    end

    def first_per_book(pairs)
      pairs.each_with_object({}) { |(book_id, value), map| map[book_id] ||= value }
    end

    def ranked_items_for(ids)
      ::RankedItem
        .where(ranking_configuration_id: @ranking_configuration.id, item_type: "Books::Book", item_id: ids)
        .includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(:rank)
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/lib/books/global_canon_query_test.rb
```

Expected: PASS, 14 runs, 0 failures.

- [ ] **Step 6: Verify the load-bearing tests are not vacuous**

Run each of these three mutations, confirm the named test goes red, then restore:

1. Swap the two `select_pass` lines in `#call` (non-fiction first) → `"fiction consumes country slots before the non-fiction pass runs"` must fail.
2. Move `@country_used`/`@author_used` initialisation into `select_pass` so each pass gets fresh counters → the same test must fail.
3. Delete `.where.not(item_id: BLOCKED_BOOK_IDS)` → `"never returns a blocked book"` must fail.

- [ ] **Step 7: Run the full suite, lint and commit**

The new `books_nonfiction_genre` fixture is visible to every test. Run the whole suite, not just this file.

```bash
bin/rails db:test:prepare test
bundle exec standardrb app/lib/books/global_canon_query.rb test/lib/books/global_canon_query_test.rb
git add app/lib/books/global_canon_query.rb test/lib/books/global_canon_query_test.rb test/fixtures/categories.yml
git commit -m "feat(books): global canon selection algorithm"
```

---

### Task 3: `Books::GlobalCanonPath`

**Files:**
- Create: `app/lib/books/global_canon_path.rb`
- Test: `test/lib/books/global_canon_path_test.rb`

**Interfaces:**
- Consumes: `Books::GlobalCanonParams::Settings` from Task 1.
- Produces: `Books::GlobalCanonPath.call(settings) -> String`. Returns `"/global-canon"` when `settings.default?`, otherwise the full three-segment path. Constant `BASE`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/global_canon_path_test.rb`:

```ruby
require "test_helper"

module Books
  class GlobalCanonPathTest < ActiveSupport::TestCase
    test "returns the bare path for the defaults" do
      assert_equal "/global-canon", ::Books::GlobalCanonPath.call(settings)
    end

    test "spells out all three settings when any of them differs" do
      assert_equal "/global-canon/total_books/250/nonfiction/20/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(total_books: 250))
    end

    test "spells out a zero non-fiction share" do
      assert_equal "/global-canon/total_books/150/nonfiction/0/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(nonfiction_percentage: 0))
    end

    test "spells out a full non-fiction share" do
      assert_equal "/global-canon/total_books/150/nonfiction/100/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(nonfiction_percentage: 100))
    end

    private

    def settings(total_books: 150, nonfiction_percentage: 20, max_books_per_country: 3, excluded_genres: [])
      ::Books::GlobalCanonParams::Settings.new(
        total_books: total_books,
        nonfiction_percentage: nonfiction_percentage,
        max_books_per_country: max_books_per_country,
        excluded_genres: excluded_genres
      )
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/books/global_canon_path_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Books::GlobalCanonPath`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/books/global_canon_path.rb`:

```ruby
module Books
  # Settings -> canonical path. The ONLY place the canon's URL shape lives,
  # mirroring Books::FilterPath.
  #
  # The defaults collapse to the bare path so /global-canon never acquires a
  # spelled-out twin, and the controller uses that to 301 away from one.
  class GlobalCanonPath
    BASE = "/global-canon".freeze

    def self.call(settings)
      return BASE if settings.default?

      "#{BASE}/total_books/#{settings.total_books}" \
        "/nonfiction/#{settings.nonfiction_percentage}" \
        "/max_per_country/#{settings.max_books_per_country}"
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/books/global_canon_path_test.rb
```

Expected: PASS, 4 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/global_canon_path.rb test/lib/books/global_canon_path_test.rb
git add app/lib/books/global_canon_path.rb test/lib/books/global_canon_path_test.rb
git commit -m "feat(books): canonical path builder for the global canon"
```

---

### Task 4: Controller, routes, view and nav

**Files:**
- Create: `app/controllers/books/global_canon_controller.rb`
- Create: `app/views/books/global_canon/show.html.erb`
- Modify: `config/routes.rb` (books domain block, after the `filters/...` routes near line 526)
- Modify: `app/views/books/shared/_nav_links.html.erb`
- Test: `test/controllers/books/global_canon_controller_test.rb`

**Interfaces:**
- Consumes: `Books::GlobalCanonParams.call`, `Books::GlobalCanonQuery.call`, `Books::GlobalCanonPath.call` from Tasks 1–3.
- Produces: routes `/global-canon`, `/global-canon/total_books/:total_books`, `/global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage`, `/global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage/max_per_country/:max_books_per_country`, and `/global-canon/settings`. Named helper `books_global_canon_path`. Controller sets `@settings`, `@result`, `@page_title`, `@indexable`, `@canonical_path`.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the books domain block, immediately after the three `filters/...` routes (around line 526), insert:

```ruby
    # The Global Canon. Settings live in the PATH, never a query string, so each
    # variant is its own Cloudflare edge-cache entry.
    #
    # The segment constraints are LOAD-BEARING for the same reason collection_re
    # is: an unconstrained segment mints an unbounded space of soft-duplicates of
    # a page that ranks. Anchors (\A, \z) raise ArgumentError in a segment
    # constraint -- Rails anchors them itself.
    #
    # canon_pct admits any integer 0..100 even though the menu offers only
    # multiples of five, so a hand-typed or bookmarked value still resolves.
    #
    # `settings` is declared FIRST: the day a shorter canon shape is added, a
    # route above this one could otherwise swallow it.
    canon_total = /(?:50|100|150|200|250)/
    canon_pct = /(?:100|[1-9]?\d)/
    canon_country = /(?:10|[1-9])/

    get "global-canon/settings", to: "books/global_canon#settings", as: :books_global_canon_settings
    get "global-canon", to: "books/global_canon#show", as: :books_global_canon
    get "global-canon/total_books/:total_books",
      to: "books/global_canon#show", constraints: {total_books: canon_total}
    get "global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage",
      to: "books/global_canon#show",
      constraints: {total_books: canon_total, nonfiction_percentage: canon_pct}
    get "global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage/max_per_country/:max_books_per_country",
      to: "books/global_canon#show",
      constraints: {total_books: canon_total, nonfiction_percentage: canon_pct, max_books_per_country: canon_country}
```

- [ ] **Step 2: Write the failing test**

Create `test/controllers/books/global_canon_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class GlobalCanonControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @fiction = categories(:books_fiction_genre)
      @next_rank = 0
      3.times { rank_fiction_book }
    end

    test "renders the canon" do
      get "/global-canon"

      assert_response :success
      assert_equal 3, @controller.view_assigns["result"].delivered
    end

    test "the bare path is indexable and carries a canonical" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/global-canon"

      assert_select "meta[name=robots][content=?]", "index, follow"
      assert_select "link[rel=canonical][href=?]", "http://dev-new.thegreatestbooks.org/global-canon"
    end

    test "a customised path is noindex and carries NO canonical" do
      # A canonical pointing away from a noindexed page risks propagating the
      # noindex to the target -- the rule Books::RankedItemsController states
      # for /rc/ URLs.
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/global-canon/total_books/250/nonfiction/40/max_per_country/2"

      assert_response :success
      assert_select "meta[name=robots][content=?]", "noindex, follow"
      assert_select "link[rel=canonical]", false
    end

    test "spelled-out defaults 301 to the bare path" do
      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3"

      assert_redirected_to "/global-canon"
      assert_equal 301, response.status
    end

    test "a partial path 301s to the full form" do
      # The two shorter route shapes exist so a legacy URL resolves, but the
      # canonical is always the full three-segment form.
      get "/global-canon/total_books/250"

      assert_redirected_to "/global-canon/total_books/250/nonfiction/20/max_per_country/3"
      assert_equal 301, response.status
    end

    test "a query string 301s into the path form" do
      get "/global-canon?total_books=250"

      assert_redirected_to "/global-canon/total_books/250/nonfiction/20/max_per_country/3"
      assert_equal 301, response.status
    end

    test "the settings form 303s to the canonical path" do
      get "/global-canon/settings", params: {
        total_books: "250", nonfiction_percentage: "40", max_books_per_country: "2"
      }

      assert_redirected_to "/global-canon/total_books/250/nonfiction/40/max_per_country/2"
      assert_equal 303, response.status
    end

    test "an unroutable total 404s" do
      get "/global-canon/total_books/175"

      assert_response :not_found
    end

    test "an out-of-range country cap 404s" do
      get "/global-canon/total_books/250/nonfiction/40/max_per_country/11"

      assert_response :not_found
    end

    test "show carries public edge-cache headers" do
      get "/global-canon"

      assert_match "public", response.headers["Cache-Control"]
      assert_match "max-age=21600", response.headers["Cache-Control"]
    end

    test "the settings redirect is never cached" do
      get "/global-canon/settings", params: {total_books: "250"}

      assert_match "no-store", response.headers["Cache-Control"]
    end

    test "the short-list note names the binding constraint" do
      france = ::Books::Country.create!(name: "France", slug: "france", labels: [])
      3.times { rank_fiction_book(country: france) }

      get "/global-canon/total_books/250/nonfiction/0/max_per_country/1"

      assert_response :success
      assert_select "[data-testid=canon-short-list-note]", /of the 250 requested/
    end

    test "no note is shown when the canon is filled" do
      # 50 is the smallest selectable total, so the canon can only be "filled"
      # with at least 50 eligible books. Each gets its own country so the cap of
      # 10 never binds; setup's three country-less books share the nil bucket.
      seed_canon_books(50)

      get "/global-canon/total_books/50/nonfiction/0/max_per_country/10"

      assert_response :success
      assert_equal 50, @controller.view_assigns["result"].delivered
      assert_select "[data-testid=canon-short-list-note]", false
    end

    test "does not trap links in a turbo frame" do
      assert_no_frame_trapped_links "/global-canon"
    end

    test "renders the grid without an N+1" do
      get "/global-canon"  # warm the schema cache and any first-request lazy loads
      baseline = query_count_for("/global-canon")

      10.times { rank_fiction_book }

      # The grid preloads authors and cover images, so thirteen cards must cost
      # exactly what three did. `assert_queries_count` takes an ABSOLUTE number,
      # which churns on every unrelated query change; comparing the page to
      # itself at a different size is what actually detects an N+1. Note the
      # rank_fiction_book calls sit OUTSIDE both measurements -- inside, their
      # own INSERTs would be counted and the test would pass on anything.
      assert_equal baseline, query_count_for("/global-canon")
    end

    private

    def query_count_for(path)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
      count
    end

    def seed_canon_books(count)
      count.times do |i|
        rank_fiction_book(country: ::Books::Country.create!(
          name: "Seed Country #{i}", slug: "seed-country-#{i}", labels: []
        ))
      end
    end

    def rank_fiction_book(country: nil)
      @next_rank += 1
      book = ::Books::Book.create!(title: "Canon Book #{@next_rank}")
      ::Books::BookCountry.create!(book: book, country: country) if country
      ::Books::BookAuthor.create!(
        book: book, author: ::Books::Author.create!(name: "Author #{@next_rank}"),
        position: 1, role: :author
      )
      ::CategoryItem.create!(category: @fiction, item: book)
      ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      book
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/controllers/books/global_canon_controller_test.rb
```

Expected: FAIL — uninitialized constant `Books::GlobalCanonController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/books/global_canon_controller.rb`:

```ruby
class Books::GlobalCanonController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :find_ranking_configuration
  # Above the cache filter on purpose: a 301 must not be decorated with 6-hour
  # public edge-cache headers.
  before_action :redirect_to_canonical_form, only: [:show]
  before_action :cache_for_index_page, only: [:show]
  before_action :prevent_caching, only: [:settings]

  def show
    @settings = Books::GlobalCanonParams.call(params)
    @result = Books::GlobalCanonQuery.call(
      ranking_configuration: @ranking_configuration,
      settings: @settings
    )
    @page_title = "The Global Literary Canon"
    @indexable = @settings.default?
    # No canonical at all on a customised variant. One pointing back at
    # /global-canon would pair noindex with a canonical whose noindex can
    # propagate to the real page -- the rule Books::RankedItemsController
    # states for /rc/ URLs.
    @canonical_path = Books::GlobalCanonPath.call(@settings) if @indexable
  end

  # The settings form's target. Resolves the submitted values and sends the
  # visitor to the canonical path, so the URL grammar lives only in
  # Books::GlobalCanonPath. Mirrors Books::FiltersController#show.
  def settings
    redirect_to Books::GlobalCanonPath.call(Books::GlobalCanonParams.call(params)),
      status: :see_other
  end

  private

  # One rule collapses two non-canonical shapes: a spelled-out set of defaults,
  # and a query string reaching #show. Both compute a canonical path that differs
  # from the request path, so both 301. Comparing against the COMPUTED path
  # rather than testing for query keys means a shape added later is covered for
  # free.
  def redirect_to_canonical_form
    canonical = Books::GlobalCanonPath.call(Books::GlobalCanonParams.call(params))
    return if canonical == request.path

    redirect_to canonical, status: :moved_permanently
  end

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end
end
```

- [ ] **Step 5: Write the view**

Two traps in this file. **`Books::List.active`, not `List.active`** — legacy is a books-only app so its `List.active.count` was implicitly scoped; here it spans every domain and would print 834 where the books figure is 759. And `.active` is generated by the `status` enum (`active: 3`), so grepping for `scope :active` finds nothing — it exists anyway.

Create `app/views/books/global_canon/show.html.erb`:

```erb
<%
  content_for :page_title, "#{@page_title} | The Greatest Books"
  content_for :meta_description, "Discover 'The Global Literary Canon,' a balanced and inclusive collection of global literary masterpieces, with a fair representation of the world's finest literature."
  content_for :canonical_url, request.base_url + @canonical_path if @canonical_path
%>

<div class="space-y-8">
  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance"><%= @page_title %></h1>

  <div class="bg-base-100 border border-base-300 rounded-xl p-6 md:p-10">
    <div class="max-w-3xl mx-auto space-y-4 text-base sm:text-lg leading-relaxed text-base-content/80">
      <p>
        An algorithmically generated collection that brings balance and inclusivity to the world of
        literature, built from <%= number_with_delimiter(Books::List.active.count) %> aggregated lists.
      </p>
      <p>
        To keep the selection balanced this list is <%= @settings.nonfiction_percentage %>% non-fiction,
        takes no more than <%= @settings.max_books_per_country %>
        <%= "book".pluralize(@settings.max_books_per_country) %> from any single country, and includes
        only one book per author.
      </p>
    </div>
  </div>

  <%= form_with url: books_global_canon_settings_path, method: :get, class: "space-y-4" do %>
    <div class="grid gap-4 sm:grid-cols-3">
      <fieldset class="fieldset">
        <legend class="fieldset-legend">Total books</legend>
        <%= select_tag :total_books,
              options_for_select(Books::GlobalCanonParams::TOTALS, @settings.total_books),
              class: "select w-full" %>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Non-fiction</legend>
        <%# The menu offers multiples of five; the route accepts any integer
            0..100, so a hand-typed value still resolves and is preselected. %>
        <%= select_tag :nonfiction_percentage,
              options_for_select(
                (0..100).step(5).map { |p| ["#{p}%", p] },
                @settings.nonfiction_percentage
              ),
              class: "select w-full" %>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Max books per country</legend>
        <%= select_tag :max_books_per_country,
              options_for_select((1..10).to_a, @settings.max_books_per_country),
              class: "select w-full" %>
      </fieldset>
    </div>

    <%= submit_tag "Update list", class: "btn btn-primary", data: {testid: "canon-update"} %>
  <% end %>

  <% if @result.delivered < @result.requested %>
    <div role="status" class="alert" data-testid="canon-short-list-note">
      <span>
        Showing <strong><%= @result.delivered %></strong> of the <%= @result.requested %> requested.
        <% if @result.blocked_by_country >= @result.blocked_by_author %>
          The limit of <%= @settings.max_books_per_country %>
          <%= "book".pluralize(@settings.max_books_per_country) %> per country is the binding
          constraint — raise it to get more.
        <% else %>
          The limit of one book per author is the binding constraint.
        <% end %>
      </span>
    </div>
  <% end %>

  <%# Numbered by canon position, not global rank: showing #1, #3, #9, #14 makes
      the diversity filter's gaps look like errors. %>
  <div class="<%= Books::CardComponent::GRID_CONTAINER_CLASS %>">
    <% @result.ranked_items.each_with_index do |ranked_item, index| %>
      <%= render Books::CardComponent.new(book: ranked_item.item, rank: index + 1, index: index) %>
    <% end %>
  </div>
</div>
```

- [ ] **Step 6: Add the nav entry**

In `app/views/books/shared/_nav_links.html.erb`, insert directly after the `menu-title` line and **before** the 21st Century link, matching legacy menu order:

```erb
      <li><%= link_to "The Global Canon", books_global_canon_path %></li>
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/books/global_canon_controller_test.rb
```

Expected: PASS, 15 runs, 0 failures.

- [ ] **Step 8: Verify the tests are not vacuous**

1. Delete the `@canonical_path = ... if @indexable` line → `"a customised path is noindex and carries NO canonical"` still passes but `"the bare path is indexable and carries a canonical"` must fail.
2. Change `@indexable = @settings.default?` to `@indexable = true` → the noindex test must fail.
3. Delete the `before_action :redirect_to_canonical_form` line → both 301 tests must fail.
4. Delete the `if @result.delivered < @result.requested` guard → `"no note is shown when the canon is filled"` must fail.

Restore each after confirming.

- [ ] **Step 9: Run the full suite, lint and commit**

```bash
bin/rails db:test:prepare test
bundle exec standardrb
git add app/controllers/books/global_canon_controller.rb app/views/books/global_canon/show.html.erb config/routes.rb app/views/books/shared/_nav_links.html.erb test/controllers/books/global_canon_controller_test.rb
git commit -m "feat(books): global canon page, routes and nav entry"
```

---

### Task 5: E2E spec for the core canon

**Files:**
- Create: `web-app/e2e/tests/books/global-canon.spec.ts`

**Interfaces:**
- Consumes: the routes, view and nav entry from Task 4. Relies on `data-testid="canon-update"` on the submit button, and on `Books::CardComponent`'s existing `data-listable-type="Books::Book"` root attribute to count cards. Do NOT add a `data-testid` to the card component — an existing attribute already targets it, and CLAUDE.md reserves `data-testid` for elements role/text/label cannot reach.

**Setup the implementer needs:** Playwright needs a running dev server and `e2e/.env`. `bin/dev` self-terminates in a non-TTY agent shell — use `yarn build:all` then `bin/rails server`, and confirm what is actually serving port 3000 before trusting a result.

- [ ] **Step 1: Write the spec**

Create `web-app/e2e/tests/books/global-canon.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('The Global Canon', () => {
  test('loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/global-canon');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'The Global Literary Canon', level: 1 })).toBeVisible();
  });

  test('is reachable from the Lists nav menu', async ({ page }) => {
    await page.goto('/');

    await page.locator('.menu-horizontal summary', { hasText: 'Lists' }).click();
    await page.locator('.menu-horizontal').getByRole('link', { name: 'The Global Canon', exact: true }).click();

    await expect(page).toHaveURL(/\/global-canon$/);
  });

  test('changing a setting rewrites the URL into the path form', async ({ page }) => {
    await page.goto('/global-canon');

    await page.getByLabel('Total books').selectOption('50');
    await page.getByTestId('canon-update').click();

    await expect(page).toHaveURL('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
  });

  test('a smaller total returns fewer books', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
    const fifty = await page.locator('[data-listable-type="Books::Book"]').count();

    await page.goto('/global-canon/total_books/250/nonfiction/20/max_per_country/3');
    const twoFifty = await page.locator('[data-listable-type="Books::Book"]').count();

    expect(twoFifty).toBeGreaterThan(fifty);
  });

  test('an all-fiction canon and an all-nonfiction canon differ', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/0/max_per_country/3');
    const fictionFirst = await page.locator('[data-listable-type="Books::Book"]').first().innerText();

    await page.goto('/global-canon/total_books/50/nonfiction/100/max_per_country/3');
    const nonfictionFirst = await page.locator('[data-listable-type="Books::Book"]').first().innerText();

    expect(fictionFirst).not.toEqual(nonfictionFirst);
  });

  test('spelled-out defaults redirect to the bare path', async ({ page }) => {
    await page.goto('/global-canon/total_books/150/nonfiction/20/max_per_country/3');

    await expect(page).toHaveURL('/global-canon');
  });
});
```

- [ ] **Step 2: Run the spec**

```bash
yarn build:all
bin/rails server   # separate shell; confirm port 3000 is THIS checkout
yarn test:e2e e2e/tests/books/global-canon.spec.ts
```

Expected: 6 passed.

- [ ] **Step 3: Commit**

```bash
git add web-app/e2e/tests/books/global-canon.spec.ts
git commit -m "test(books): e2e coverage for the global canon page"
```

---

## Increment 2: Genre exclusion

### Task 6: Excluded genres in params and path

**Files:**
- Modify: `app/lib/books/global_canon_params.rb`
- Modify: `app/lib/books/global_canon_path.rb`
- Test: `test/lib/books/global_canon_params_test.rb`, `test/lib/books/global_canon_path_test.rb`

**Interfaces:**
- Consumes: `Settings` and `MAX_EXCLUDED_GENRES` from Task 1.
- Produces: `Settings#excluded_genres` now returns resolved `Books::Category` records sorted by slug. `GlobalCanonPath.call` appends `/excluding/<comma-joined sorted slugs>` when any are present.

- [ ] **Step 1: Write the failing params tests**

Append to `test/lib/books/global_canon_params_test.rb`, inside the class:

```ruby
    test "resolves excluded genre slugs from a comma-joined path segment" do
      poetry = genre("Poetry")
      fantasy = genre("Fantasy")

      settings = Books::GlobalCanonParams.call(excluded_genres: "poetry,fantasy")

      assert_equal [fantasy, poetry], settings.excluded_genres
    end

    test "resolves excluded genres from the form's array parameter" do
      poetry = genre("Poetry")

      settings = Books::GlobalCanonParams.call(excluded_genres: ["poetry"])

      assert_equal [poetry], settings.excluded_genres
    end

    test "sorts excluded genres by slug so one ordering is canonical" do
      genre("Poetry")
      genre("Fantasy")

      assert_equal %w[fantasy poetry],
        Books::GlobalCanonParams.call(excluded_genres: "poetry,fantasy").excluded_genres.map(&:slug)
    end

    test "404s on an unknown genre slug" do
      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: "not-a-genre")
      end
    end

    test "404s on a subject slug -- the picker is genres only" do
      subject = categories(:books_politics_subject)

      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: subject.slug)
      end
    end

    test "404s on a soft-deleted genre" do
      deleted = categories(:books_deleted_genre)

      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: deleted.slug)
      end
    end

    test "404s on more than the maximum number of exclusions" do
      slugs = (1..7).map { |i| genre("Genre #{i}").slug }

      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: slugs.join(","))
      end
    end

    test "default? is false once a genre is excluded" do
      genre("Poetry")

      refute Books::GlobalCanonParams.call(excluded_genres: "poetry").default?
    end

    private

    def genre(name)
      ::Books::Category.create!(name: name, slug: name.parameterize, category_type: :genre)
    end
```

`books_deleted_genre` is already a `Books::Category` with `deleted: true` and slug `retired-genre` — verified, no fixture change needed.

- [ ] **Step 2: Write the failing path test**

Append to `test/lib/books/global_canon_path_test.rb`, inside the class, before `private`:

```ruby
    test "appends excluded genres as comma-joined sorted slugs" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      fantasy = ::Books::Category.create!(name: "Fantasy", slug: "fantasy", category_type: :genre)

      assert_equal "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/fantasy,poetry",
        ::Books::GlobalCanonPath.call(settings(excluded_genres: [poetry, fantasy]))
    end

    test "the excluding segment only ever follows the full form" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      path = ::Books::GlobalCanonPath.call(settings(total_books: 250, excluded_genres: [poetry]))

      assert_match %r{\A/global-canon/total_books/250/nonfiction/20/max_per_country/3/excluding/poetry\z}, path
    end
```

- [ ] **Step 3: Run both test files to verify they fail**

```bash
bin/rails test test/lib/books/global_canon_params_test.rb test/lib/books/global_canon_path_test.rb
```

Expected: FAIL — the new tests get `[]` back from `excluded_genres` and a path with no `excluding` segment.

- [ ] **Step 4: Implement the params change**

In `app/lib/books/global_canon_params.rb`, replace `excluded_genres: []` in `#call` with `excluded_genres: genres(@params[:excluded_genres])` and add this private method:

```ruby
    # Accepts BOTH shapes the two entry points produce: a comma-joined string
    # from the path segment, and an array from the picker's `name="...[]"`
    # hidden inputs. Resolution semantics match Books::FilterParams#resolve --
    # a count mismatch 404s rather than silently dropping a slug, because a URL
    # promising two exclusions must not quietly apply one.
    #
    # Genres only. A subject or setting slug 404s rather than filtering, so the
    # URL space stays exactly what the picker can produce.
    def genres(raw)
      slugs = Array(raw).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?).uniq
      return [] if slugs.empty?
      raise ActiveRecord::RecordNotFound if slugs.size > MAX_EXCLUDED_GENRES

      records = ::Books::Category.active.where(category_type: :genre, slug: slugs).sort_by(&:slug)
      raise ActiveRecord::RecordNotFound if records.size != slugs.size

      records
    end
```

- [ ] **Step 5: Implement the path change**

In `app/lib/books/global_canon_path.rb`, replace the body of `.call` with:

```ruby
    def self.call(settings)
      return BASE if settings.default?

      path = "#{BASE}/total_books/#{settings.total_books}" \
        "/nonfiction/#{settings.nonfiction_percentage}" \
        "/max_per_country/#{settings.max_books_per_country}"
      return path if settings.excluded_genres.empty?

      # Sorted so `poetry,fantasy` and `fantasy,poetry` cannot both exist as
      # separate cache entries and separate crawlable URLs.
      "#{path}/excluding/#{settings.excluded_genres.map(&:slug).sort.join(",")}"
    end
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/global_canon_params_test.rb test/lib/books/global_canon_path_test.rb
```

Expected: PASS.

- [ ] **Step 7: Verify the tests are not vacuous**

Delete `raise ActiveRecord::RecordNotFound if records.size != slugs.size` → `"404s on an unknown genre slug"`, `"404s on a subject slug"` and `"404s on a soft-deleted genre"` must all fail. Restore.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb app/lib/books/ test/lib/books/
git add app/lib/books/global_canon_params.rb app/lib/books/global_canon_path.rb test/lib/books/global_canon_params_test.rb test/lib/books/global_canon_path_test.rb
git commit -m "feat(books): excluded genres in the global canon params and path"
```

---

### Task 7: The exclusion route, JSON endpoint and picker

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/books/global_canon_controller.rb`
- Modify: `app/views/books/global_canon/show.html.erb`
- Test: `test/controllers/books/global_canon_controller_test.rb`

**Interfaces:**
- Consumes: `Books::GlobalCanonParams` genre resolution from Task 6; `CategorySearchQuery.call(query, scope:, types:, limit:)` which returns an Array of `Books::Category`.
- Produces: route `/global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage/max_per_country/:max_books_per_country/excluding/:excluded_genres`, route `/global-canon/genres` (named `books_global_canon_genres`), controller action `genres` rendering JSON `[{value: <slug>, text: <name>}]`.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, add `canon_genres` alongside the other canon constraints:

```ruby
    # Up to MAX_EXCLUDED_GENRES slugs. The cap lives here as well as in
    # GlobalCanonParams so an over-long list never reaches the app at all.
    canon_genres = /[a-z0-9\-]+(?:,[a-z0-9\-]+){0,5}/
```

Add the `genres` endpoint immediately after the `settings` route:

```ruby
    get "global-canon/genres", to: "books/global_canon#genres", as: :books_global_canon_genres
```

And add the exclusion shape after the existing three-segment route:

```ruby
    get "global-canon/total_books/:total_books/nonfiction/:nonfiction_percentage/max_per_country/:max_books_per_country/excluding/:excluded_genres",
      to: "books/global_canon#show",
      constraints: {
        total_books: canon_total, nonfiction_percentage: canon_pct,
        max_books_per_country: canon_country, excluded_genres: canon_genres
      }
```

- [ ] **Step 2: Write the failing controller tests**

Append to `test/controllers/books/global_canon_controller_test.rb`, inside the class before `private`:

```ruby
    test "an excluded genre removes its books from the canon" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      excluded_book = ::Books::Book.where(title: "Canon Book 1").first
      ::CategoryItem.create!(category: poetry, item: excluded_book)

      get "/global-canon/total_books/50/nonfiction/0/max_per_country/10/excluding/poetry"

      assert_response :success
      ids = @controller.view_assigns["result"].ranked_items.map(&:item_id)
      refute_includes ids, excluded_book.id
      assert_equal 2, ids.size
    end

    test "an excluded genre path is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry"

      assert_select "meta[name=robots][content=?]", "noindex, follow"
    end

    test "an unsorted exclusion list 301s to the sorted one" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      ::Books::Category.create!(name: "Fantasy", slug: "fantasy", category_type: :genre)

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry,fantasy"

      assert_redirected_to "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/fantasy,poetry"
      assert_equal 301, response.status
    end

    test "the settings form carries exclusions into the canonical path" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/settings", params: {
        total_books: "150", nonfiction_percentage: "20",
        max_books_per_country: "3", excluded_genres: ["poetry"]
      }

      assert_redirected_to "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry"
    end

    test "an unknown genre slug 404s" do
      # The route regex admits any lowercase slug, so this reaches the app and
      # GlobalCanonParams is what rejects it. That is the whole reason the
      # validator duplicates the constraint.
      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/not-a-genre"

      assert_response :not_found
    end

    test "more than six exclusions never reaches the app" do
      slugs = (1..7).map { |i| ::Books::Category.create!(name: "Genre #{i}", slug: "genre-#{i}", category_type: :genre).slug }

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/#{slugs.join(",")}"

      assert_response :not_found
    end

    test "the genres endpoint returns matching genres as slug and name" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/genres", params: {q: "poet"}, as: :json

      assert_response :success
      assert_equal [{"value" => "poetry", "text" => "Poetry"}], response.parsed_body
    end

    test "the genres endpoint excludes subjects and settings" do
      subject = categories(:books_politics_subject)

      get "/global-canon/genres", params: {q: subject.name}, as: :json

      assert_response :success
      refute_includes response.parsed_body.map { |row| row["value"] }, subject.slug
    end

    test "the genres endpoint is never cached" do
      get "/global-canon/genres", params: {q: "poet"}, as: :json

      assert_match "no-store", response.headers["Cache-Control"]
    end
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/books/global_canon_controller_test.rb
```

Expected: FAIL — no `genres` action, and the exclusion route does not exist.

- [ ] **Step 4: Implement the controller change**

In `app/controllers/books/global_canon_controller.rb`, add `:genres` to the `prevent_caching` filter:

```ruby
  before_action :prevent_caching, only: [:settings, :genres]
```

and add the action after `#settings`:

```ruby
  # Search-as-you-type source for the exclusion picker.
  #
  # `{value: slug}`, not the `{value: id}` the saved-search picker uses: this URL
  # grammar is slug-based, and translating ids to slugs in JS would put URL
  # knowledge in two places.
  #
  # types: [:genre] is deliberate and narrower than the books filter modal, which
  # searches genres, subjects AND settings. Excluding "Paris" from a global canon
  # is not a thing this page offers, and GlobalCanonParams 404s such a slug --
  # the endpoint and the validator have to agree.
  def genres
    rows = CategorySearchQuery.call(params[:q], scope: ::Books::Category, types: [:genre])
    render json: rows.map { |category| {value: category.slug, text: category.name} }
  end
```

- [ ] **Step 5: Add the picker to the view**

In `app/views/books/global_canon/show.html.erb`, inside the `form_with` block and after the `grid gap-4 sm:grid-cols-3` div, insert:

```erb
    <%# Same picker shape as the saved-search form: type-to-search against a JSON
        endpoint, chosen genres held as hidden inputs. Progressive enhancement --
        without JavaScript the three menus above still submit. There is no
        <select multiple> fallback: daisyUI 5 renders one as an unreadable
        single row. %>
    <fieldset class="fieldset" data-controller="saved-search-picker"
              data-saved-search-picker-url-value="<%= books_global_canon_genres_path %>"
              data-saved-search-picker-name-value="excluded_genres[]">
      <legend class="fieldset-legend">Genres to exclude</legend>
      <div class="relative">
        <input type="search"
               class="input w-full"
               placeholder="Search genres"
               aria-label="Genres to exclude"
               autocomplete="off"
               data-testid="canon-genre-search"
               data-saved-search-picker-target="query"
               data-action="input->saved-search-picker#search keydown->saved-search-picker#suppressEnter">
        <%# Hidden until the controller has at least one result to show -- an
            empty absolutely-positioned panel would float over the page as a
            small blank box. %>
        <div class="hidden absolute dropdown-content p-2 shadow-lg bg-base-100 rounded-box w-full mt-1 max-h-80 overflow-y-auto z-[9999] left-0 top-full flex flex-col gap-1"
             data-saved-search-picker-target="results"></div>
      </div>
      <div class="flex flex-wrap gap-2 mt-2" data-saved-search-picker-target="chips">
        <% @settings.excluded_genres.each do |genre| %>
          <span class="badge badge-outline gap-1" data-chip="<%= genre.slug %>">
            <%= hidden_field_tag "excluded_genres[]", genre.slug, id: nil %>
            <span><%= genre.name %></span>
            <button type="button" class="btn btn-ghost btn-xs px-1"
                    aria-label="Remove <%= genre.name %>"
                    data-action="saved-search-picker#remove">×</button>
          </span>
        <% end %>
      </div>
    </fieldset>
```

Also update the description paragraph to mention active exclusions. Replace the second `<p>` with:

```erb
      <p>
        To keep the selection balanced this list is <%= @settings.nonfiction_percentage %>% non-fiction,
        takes no more than <%= @settings.max_books_per_country %>
        <%= "book".pluralize(@settings.max_books_per_country) %> from any single country, and includes
        only one book per author.
        <% if @settings.excluded_genres.any? %>
          Excluding <%= @settings.excluded_genres.map(&:name).to_sentence %>.
        <% end %>
      </p>
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/books/global_canon_controller_test.rb
```

Expected: PASS, 24 runs, 0 failures.

- [ ] **Step 7: Verify the tests are not vacuous**

1. Change `types: [:genre]` to `types: []` → `"the genres endpoint excludes subjects and settings"` must fail.
2. Change the JSON to `{value: category.id, text: category.name}` → `"the genres endpoint returns matching genres as slug and name"` must fail.

Restore both.

- [ ] **Step 8: Run the daisyUI guard, full suite, lint and commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bin/rails db:test:prepare test
bundle exec standardrb
git add config/routes.rb app/controllers/books/global_canon_controller.rb app/views/books/global_canon/show.html.erb test/controllers/books/global_canon_controller_test.rb
git commit -m "feat(books): exclude genres from the global canon"
```

---

### Task 8: E2E for the picker

**Files:**
- Modify: `web-app/e2e/tests/books/global-canon.spec.ts`

**Interfaces:**
- Consumes: `data-testid="canon-genre-search"` on the picker input and `data-testid="canon-update"` on the submit button from Tasks 4 and 7.

**`lists.spec.ts` needs no change.** Its nav test targets `getByRole('link', { name: 'All Lists', exact: true })`, which the new entry cannot collide with, and it asserts nothing about the menu's length or order. Verified before this plan was written — do not modify it. The new nav entry is covered by the "is reachable from the Lists nav menu" test added in Task 5.

- [ ] **Step 1: Add the picker spec**

Append to `web-app/e2e/tests/books/global-canon.spec.ts`, inside the `test.describe`:

```typescript
  test('excluding a genre adds it to the URL and drops its books', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');
    const before = await page.locator('[data-listable-type="Books::Book"]').allInnerTexts();

    await page.getByTestId('canon-genre-search').fill('literary fiction');
    await page.getByRole('button', { name: /Literary Fiction/ }).first().click();
    await page.getByTestId('canon-update').click();

    await expect(page).toHaveURL(/\/excluding\/[a-z0-9,-]+$/);

    const after = await page.locator('[data-listable-type="Books::Book"]').allInnerTexts();
    expect(after).not.toEqual(before);
  });

  test('an active exclusion is shown back on the page', async ({ page }) => {
    await page.goto('/global-canon/total_books/50/nonfiction/20/max_per_country/3');

    await page.getByTestId('canon-genre-search').fill('literary fiction');
    await page.getByRole('button', { name: /Literary Fiction/ }).first().click();
    await page.getByTestId('canon-update').click();

    await expect(page.locator('[data-chip]')).toHaveCount(1);
  });
```

These specs run against the development database, so the genre has to be one that exists there and that actually moves the result. **"Literary Fiction"** (slug `literary-fiction`) was chosen deliberately: it covers 392 of the top 600 ranked books, so excluding it visibly reshuffles a 50-book canon. A rarer genre would let the "results changed" assertion pass or fail on noise.

- [ ] **Step 2: Run the specs**

```bash
yarn build:all
bin/rails server   # separate shell; confirm port 3000 is THIS checkout
yarn test:e2e e2e/tests/books/global-canon.spec.ts e2e/tests/books/lists.spec.ts
```

Expected: all pass. `lists.spec.ts` runs here to prove the new nav entry did not break it, not because it changed.

- [ ] **Step 3: Commit**

```bash
git add web-app/e2e/tests/books/global-canon.spec.ts
git commit -m "test(books): e2e coverage for global canon genre exclusion"
```

---

## Final verification

- [ ] `bin/rails db:test:prepare test` — full suite green.
- [ ] `bundle exec standardrb` — clean.
- [ ] `yarn test:e2e` — books specs green.
- [ ] `bin/rails test test/lint/daisyui_v4_classes_test.rb` — no removed daisyUI classes.
- [ ] Write the feature doc: `docs/features/` gets an entry for the global canon, per `docs/documentation.md`.
- [ ] Do **not** push or open a PR without asking.

## Rollout notes for the reviewer

No migration, no backfill, no job — the page is derived entirely from data that already exists, so deploying is the whole rollout. Two visible changes for existing visitors:

1. `/global-canon` no longer excludes children's books, so the default list differs from what production shows today.
2. The non-fiction menu now reaches 100%.

Legacy `/global-canon` URLs need no redirect: the grammar is ported verbatim.
