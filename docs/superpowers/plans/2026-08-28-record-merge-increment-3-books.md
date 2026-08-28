# Book Merge (Record Merge, Increment 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin fold a duplicate `Books::Book` into a surviving one, transferring its associations and user-owned data, then destroying it.

**Architecture:** A `::Books::Book::Merger` service returning the project's `Result` struct, doing every mutation inside one `ActiveRecord::Base.transaction` and every fallible follow-up (search reindex, ranking jobs, generated-list rebuild) after that transaction commits. A thin `Actions::Admin::Books::MergeBook` action dispatches to it from the book's admin show page via the existing shared `execute_action` endpoint pattern. Increments 1 (games) and 2 (authors) shipped this exact shape; this increment ports it to the hardest model.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + Mocha + fixtures, Sidekiq (inline in test), OpenSearch via `SearchIndexRequest`, ViewComponents + DaisyUI 5, Playwright for E2E.

**Spec:** `docs/superpowers/specs/2026-08-23-record-merge-design.md` (revised 2026-08-28, commit `5d66b8ae`). Read the `Books::Book` merger table, "Ordering constraints", "Transaction boundary", "Failure handling", and "Admin plumbing" before starting.

## Global Constraints

- **Run all commands from `web-app/`.** `cd web-app` first. Docs live in `docs/` at the project root.
- **Root-anchor every constant** as `::Books::Book`, `::Books::Series`, `::Books::BookAuthor` — in production code **and** in tests. Inside `module Books`, a bare `Books::Book` resolves to the nested module and raises a confusing `NameError`. This has bitten the codebase 3+ times.
- **Never run `ActiveRecord::FixtureSet.create_fixtures`** — it truncates every table it names, and the books data exists only in development and takes hours to rebuild.
- **`ps aux | grep "[r]ails test"` before running the suite** if you are in the main checkout, to avoid concurrent runs truncating each other's fixtures.
- **Minitest is 6.x:** `assert_nil`, never `assert_equal nil`.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. `--fix` autocorrects.
- **Services use the Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. `keyword_init` is kept on purpose.
- **`success?` means "the merge committed"** — not "reindexing and ranking also succeeded".
- Reference implementations to follow: `app/lib/games/game/merger.rb` and `app/lib/books/author/merger.rb`.
- The merger file is `app/lib/books/book/merger.rb`, opening `module Books` → `class Book` → `class Merger`. This reopens the `Books::Book` model class, exactly as the author merger reopens `Books::Author`.
- Every test assertion must be verified by deleting the line under test and confirming it goes red. Merger assertions pass against dead code unusually easily — "the survivor now has category X" is true whether the merge moved it or the fixture already had it.

**Fixture pair used throughout the merger test:** source `books_books(:crime_and_punishment)` (1866, no authors, no editions, no countries, one `series_books` row), target `books_books(:war_and_peace)` (1869, `alternate_titles: ["Voyna i mir"]`, one author `tolstoy`, three editions, one country). The source's earlier year and the target's existing alternates exercise scalar reconciliation naturally.

**There are no `Books::Book` rows in `test/fixtures/ranked_items.yml`**, so unlike the games merger test there is nothing to clear in `setup`. Ranking tests create their own `RankedItem` rows.

---

### Task 1: Merger skeleton — guards, locking, transaction, failure handling

**Files:**
- Create: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `::Books::Book::Merger.call(source:, target:)` → `Result` with `success?`, `data` (the target book or nil), `errors` (array of strings). Also `::Books::Book::Merger.new(source:, target:)` with a public `#call` and a public `#stats` hash, which Task 11's action class reads for `stats[:post_commit_error]`. Private hook methods `#merge_all_associations` and `#reconcile_scalars` exist from this task on as empty no-ops so later tasks fill them in and so this task's rollback tests can stub them.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/books/book/merger_test.rb`:

```ruby
require "test_helper"

module Books
  class Book
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = books_books(:crime_and_punishment)
        @target = books_books(:war_and_peace)
      end

      test "merges successfully and returns the target book" do
        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source book" do
        source_id = @source.id

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::Book.exists?(source_id)
      end

      test "refuses to merge a book with itself" do
        result = ::Books::Book::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge a book with itself"], result.errors
        assert ::Books::Book.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Books::Book::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Books::Book.exists?(@source.id), "source must survive a failed merge"
      end

      test "rolls back writes already made when a later step raises" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_book_isbn10, value: "0140449132"
        )
        ::Books::Book::Merger.any_instance.stubs(:reconcile_scalars)
          .raises(StandardError.new("boom"))

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_equal @source.id, identifier.reload.identifiable_id,
          "the identifier move must have rolled back"
        assert ::Books::Book.exists?(@source.id)
      end
    end
  end
end
```

Note: the last test asserts a rollback of an identifier move that Task 3 implements. Until then it passes vacuously (the identifier never moved). Re-verify it after Task 3 by confirming it goes red when `merge_identifiers` is removed from the rescue's reach.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::Book::Merger`

- [ ] **Step 3: Write the minimal implementation**

Create `web-app/app/lib/books/book/merger.rb`:

```ruby
module Books
  class Book
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_book, :target_book, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_book = source
        @target_book = target
        @source_book_id = source.id
        @stats = {}
        @affected_ranking_configurations = []
        @transaction_body_completed = false
      end

      # Must not be called from inside a caller-supplied transaction.
      # ActiveRecord::Base.transaction joins an already-open transaction rather
      # than nesting one, so the block below would close without committing and
      # run_post_commit_steps would fire perform_async before the real commit --
      # if the outer transaction then rolled back, a Sidekiq job would wake up
      # describing a merge that never happened.
      def call
        if source_book.id == target_book.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge a book with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          lock_books
          collect_affected_ranking_configurations
          merge_all_associations
          reconcile_scalars
          target_book.save! if target_book.changed?
          destroy_source_book
          @transaction_body_completed = true
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_book, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        result_for_raised(error, error.message)
      rescue ActiveRecord::RecordNotUnique => error
        result_for_raised(error, "Constraint violation: #{error.message}")
      rescue => error
        result_for_raised(error, error.message)
      end

      private

      # Locks both rows FOR UPDATE before anything moves. Without it two admins
      # merging the same duplicate can both pass the guard above, and the loser's
      # destroy! silently affects zero rows -- books_books has no lock_version, so
      # Rails never checks the affected count -- reporting a completed merge that
      # moved nothing. Ascending id order is what stops two merges with swapped
      # source and target from deadlocking each other. Taking the lock here, before
      # reconcile_scalars dirties target_book, also keeps lock!'s
      # no-unsaved-changes requirement satisfied.
      def lock_books
        [source_book, target_book].sort_by(&:id).each(&:lock!)
      end

      # SearchIndexable's after_commit callbacks -- the target's save! and the
      # source's destroy! -- fire as the transaction block exits, which is AFTER
      # the commit, and Rails propagates anything they raise out of that block
      # straight into the rescues above. Reporting success?: false there would tell
      # the admin a merge failed when the source is already permanently deleted,
      # and their retry would then fail with "not found". So a raise arriving after
      # a successful commit is treated as post-commit fallout.
      #
      # Both halves of merge_committed? are load-bearing. The flag alone would
      # misread a COMMIT that itself failed (a deferred constraint) as success. The
      # missing row alone would misread a merge that never started because a
      # concurrent merge had already consumed the source -- which is precisely what
      # lock_books raises on.
      def result_for_raised(error, message)
        return Result.new(success?: false, data: nil, errors: [message]) unless merge_committed?

        Rails.logger.error(
          "Books::Book::Merger: merge of #{@source_book_id} into #{target_book.id} " \
          "committed, but a commit callback failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
        Result.new(success?: true, data: target_book, errors: [])
      end

      def merge_committed?
        @transaction_body_completed && !::Books::Book.exists?(@source_book_id)
      end

      # Filled in by later tasks.
      def merge_all_associations
      end

      def reconcile_scalars
      end

      def collect_affected_ranking_configurations
      end

      def run_post_commit_steps
      end

      def destroy_source_book
        source_book.destroy!
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS, 5 runs, 0 failures

- [ ] **Step 5: Verify the assertions are not vacuous**

Temporarily comment out `destroy_source_book` in `call` and re-run. Expected: "destroys the source book" FAILS. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Add Books::Book::Merger skeleton with locking and failure handling"
```

---

### Task 2: Plain repoints — editions, external_links, ai_chats, images

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 1's `#merge_all_associations` hook.
- Produces: private `#merge_editions`, `#merge_external_links`, `#merge_ai_chats`, `#merge_images`. `stats[:editions]`, `stats[:external_links]`, `stats[:ai_chats]`, `stats[:images]` are integer counts.

`books_editions` carries no unique index on `book_id`, so editions are a plain repoint with no collision case. **Editions must move before `default_edition_id` is blank-filled in Task 9**, or the survivor's default-edition FK would point at a row owned by the record about to be deleted.

- [ ] **Step 1: Write the failing tests**

Append inside the `MergerTest` class in `web-app/test/lib/books/book/merger_test.rb`:

```ruby
      test "moves editions to the target" do
        edition = ::Books::Edition.create!(book: @source, title: "Pevear translation")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, edition.reload.book_id
      end

      test "moves external links to the target" do
        link = ExternalLink.create!(
          parent: @source, name: "Wikipedia", url: "https://example.com/cp", source: :other
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.parent_id
      end

      test "moves ai chats to the target" do
        chat = AiChat.create!(parent: @source, chat_type: :general, model: "gpt-4", provider: :openai)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, chat.reload.parent_id
      end

      test "moves images to the target" do
        image = Image.create!(parent: @source, primary: false)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, image.reload.parent_id
      end

      test "demotes a moved primary image when the target already has one" do
        Image.create!(parent: @target, primary: true)
        moved = Image.create!(parent: @source, primary: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        moved.reload
        assert_equal @target.id, moved.parent_id
        assert_not moved.primary, "two primary images on one book is the bug this prevents"
      end

      test "keeps a moved primary image when the target has none" do
        moved = Image.create!(parent: @source, primary: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert moved.reload.primary
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL on all six — the rows stay on the source.

If `ExternalLink`, `AiChat`, or `Image` reject these attributes, read the model and adjust the fixture-building call only; do not change the assertions.

- [ ] **Step 3: Write the implementation**

In `merger.rb`, replace the empty `merge_all_associations` with:

```ruby
      def merge_all_associations
        merge_editions
        merge_external_links
        merge_ai_chats
        merge_images
      end

      # books_editions has no unique index on book_id, so there is no collision
      # case. MUST run before reconcile_scalars fills default_edition_id, or the
      # survivor's FK points at a row owned by the record about to be deleted.
      def merge_editions
        @stats[:editions] = source_book.editions.update_all(book_id: target_book.id)
      end

      def merge_external_links
        @stats[:external_links] = source_book.external_links.update_all(parent_id: target_book.id)
      end

      def merge_ai_chats
        @stats[:ai_chats] = source_book.ai_chats.update_all(parent_id: target_book.id)
      end

      def merge_images
        has_target_primary = target_book.primary_image.present?
        count = 0

        source_book.images.find_each do |image|
          image.update!(
            parent_id: target_book.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the assertions are not vacuous**

Delete the `primary: has_target_primary ? false : image.primary` line (leaving only `parent_id`) and re-run. Expected: "demotes a moved primary image" FAILS. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Move editions, links, chats and images in the book merger"
```

---

### Task 3: Repoint-or-drop — identifiers, book_countries, series_books, category_items

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 2's `#merge_all_associations`.
- Produces: private `#merge_identifiers`, `#merge_book_countries`, `#merge_series_books`, `#merge_category_items`, setting the integer counts `stats[:identifiers]`, `stats[:book_countries]`, `stats[:series_books]`, `stats[:category_items]`.

Unique indexes in play: `identifiers` on `(identifiable_type, identifier_type, value, identifiable_id)`, `books_book_countries` on `(book_id, country_id)`, `books_series_books` on `(series_id, book_id)`, `category_items` on `(category_id, item_type, item_id)`.

**`Books::BookCountry` declares `counter_cache: :book_count` on `country`.** The drop branch must use `destroy!`, never `delete_all` — a raw delete leaves `books_countries.book_count` overcounting forever.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "moves an identifier the target does not already have" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_book_isbn10, value: "0140449132"
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, identifier.reload.identifiable_id
      end

      test "drops a source identifier the target already has" do
        Identifier.create!(
          identifiable: @target, identifier_type: :books_book_isbn10, value: "0140449132"
        )
        duplicate = Identifier.create!(
          identifiable: @source, identifier_type: :books_book_isbn10, value: "0140449132"
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Identifier.exists?(duplicate.id)
        assert_equal 1, Identifier.where(
          identifiable_type: "Books::Book", identifiable_id: @target.id,
          identifier_type: "books_book_isbn10", value: "0140449132"
        ).count
      end

      test "moves a country the target does not already have" do
        link = ::Books::BookCountry.create!(book: @source, country: books_countries(:japanese))

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.book_id
      end

      test "drops a source country the target already has and keeps the counter honest" do
        country = books_countries(:french) # war_and_peace already links to this
        duplicate = ::Books::BookCountry.create!(book: @source, country: country)
        before = country.reload.book_count

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::BookCountry.exists?(duplicate.id)
        assert_equal before - 1, country.reload.book_count,
          "the drop must go through destroy! so the counter_cache decrements"
      end

      test "moves a series link the target does not already have" do
        link = books_series_books(:asoiaf_novella) # belongs to crime_and_punishment

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.book_id
      end

      test "drops a source series link the target already has" do
        series = books_series(:asoiaf)
        ::Books::SeriesBook.create!(series: series, book: @target, position: 9)
        duplicate = books_series_books(:asoiaf_novella)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::SeriesBook.exists?(duplicate.id)
        assert_equal 1, ::Books::SeriesBook.where(series: series, book: @target).count
      end

      test "copies a category the target does not already have" do
        category = ::Books::Category.create!(name: "Russian Realism", category_type: :genre)
        CategoryItem.create!(category: category, item: @source)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert CategoryItem.exists?(category_id: category.id, item: @target)
      end

      test "does not duplicate a category the target already has" do
        category = ::Books::Category.create!(name: "Russian Realism", category_type: :genre)
        CategoryItem.create!(category: category, item: @target)
        CategoryItem.create!(category: category, item: @source)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1, CategoryItem.where(category_id: category.id, item_type: "Books::Book",
          item_id: @target.id).count
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL on the eight new tests.

If `books_countries(:japanese)` or `books_series(:asoiaf)` are not the fixture labels, confirm with `sed -n '/^name:/,/^$/p' test/fixtures/books/countries.yml` — read the YAML, never `create_fixtures`.

- [ ] **Step 3: Write the implementation**

Add the four calls to `merge_all_associations` (after `merge_images`) and add the methods:

```ruby
      def merge_identifiers
        count = 0
        source_book.identifiers.find_each do |identifier|
          existing = target_book.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_book.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      # destroy!, never delete_all: Books::BookCountry declares
      # counter_cache: :book_count on country, and a raw delete leaves
      # books_countries.book_count overcounting permanently.
      def merge_book_countries
        count = 0
        source_book.book_countries.find_each do |link|
          if target_book.book_countries.exists?(country_id: link.country_id)
            link.destroy!
          else
            link.update!(book_id: target_book.id)
            count += 1
          end
        end
        @stats[:book_countries] = count
      end

      def merge_series_books
        count = 0
        source_book.series_books.find_each do |link|
          if target_book.series_books.exists?(series_id: link.series_id)
            link.destroy!
          else
            link.update!(book_id: target_book.id)
            count += 1
          end
        end
        @stats[:series_books] = count
      end

      # Copy-or-skip rather than move: a CategoryItem carries no state worth
      # preserving beyond the link itself, so the source's own row simply dies
      # with it. This is the music pattern.
      def merge_category_items
        count = 0
        source_book.category_items.find_each do |category_item|
          target_book.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the drop branches are real**

In `merge_book_countries`, replace the whole `if/else` with just `link.update!(book_id: target_book.id)` and re-run. Expected: "drops a source country the target already has" FAILS with a uniqueness error — proving the collision branch is load-bearing rather than decorative. Restore it. Repeat for `merge_series_books` and `merge_identifiers`.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Move identifiers, countries, series links and categories in the book merger"
```

---

### Task 4: Descriptions

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 3's `#merge_all_associations`.
- Produces: private `#merge_descriptions`, `stats[:descriptions]`.

Two unique indexes apply: one on `(describable_type, describable_id, kind, locale, source, source_name)` with `nulls_not_distinct`, and a partial one allowing a single `rank = 1` row per `(describable_type, describable_id, kind, locale)`. A moved row that would become a second preferred row for a kind+locale the target already holds is forced to `rank: :normal`.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "moves a description the target does not already have" do
        description = Description.create!(
          describable: @source, kind: :summary, locale: "en", source: :ai, content: "A summary."
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, description.reload.describable_id
      end

      test "drops a source description that collides on kind, locale, source and source_name" do
        Description.create!(
          describable: @target, kind: :summary, locale: "en", source: :ai, content: "Target's."
        )
        duplicate = Description.create!(
          describable: @source, kind: :summary, locale: "en", source: :ai, content: "Source's."
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Description.exists?(duplicate.id)
      end

      test "demotes a moved preferred description when the target already has one for that key" do
        Description.create!(
          describable: @target, kind: :summary, locale: "en", source: :ai,
          content: "Target's.", rank: :preferred
        )
        moved = Description.create!(
          describable: @source, kind: :summary, locale: "en", source: :manual,
          content: "Source's.", rank: :preferred
        )

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        moved.reload
        assert_equal @target.id, moved.describable_id
        assert_not moved.preferred?, "two preferred rows for one kind+locale violates the index"
      end
```

If `Description`'s `rank` enum values are not `:preferred` / `:normal`, read `app/models/description.rb` and use the real names in both the test and the implementation.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL — the third test fails with a `RecordNotUnique` on the partial index, which is exactly the bug this guards.

- [ ] **Step 3: Write the implementation**

Add `merge_descriptions` to `merge_all_associations` and add:

```ruby
      # Two unique indexes apply: one on
      # (describable, kind, locale, source, source_name) with nulls_not_distinct,
      # and a partial one allowing a single rank=1 row per (describable, kind, locale).
      def merge_descriptions
        preferred_keys = target_book.descriptions.select(&:preferred?)
          .map { |description| [description.kind, description.locale] }
          .to_set
        count = 0

        source_book.descriptions.find_each do |description|
          collides = target_book.descriptions.exists?(
            kind: description.kind,
            locale: description.locale,
            source: description.source,
            source_name: description.source_name
          )

          if collides
            description.destroy!
            next
          end

          attrs = {describable_id: target_book.id}
          if description.preferred? &&
              preferred_keys.include?([description.kind, description.locale])
            attrs[:rank] = :normal
          end

          description.update!(attrs)
          count += 1
        end
        @stats[:descriptions] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Move descriptions in the book merger, respecting both unique indexes"
```

---

### Task 5: List items and personal list entries

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 4's `#merge_all_associations`.
- Produces: private `#merge_list_items`, `#merge_user_list_items`, `stats[:list_items]`, `stats[:user_list_items]`.

Two rules, both learned after increments 1 and 2 shipped and both already live in the games and music mergers:

**Auto-generated lists are skipped entirely.** `merge_list_items` writes through `update!`/`create!`, which `ListItem`'s validation rejects once the list is `auto_generated?` — a 500 in live admin the first time a merged book sits on the generated favorites list. Nothing is lost directly: the generator rewrites that list from the user favorites the merge has already repointed. Task 10 queues the rebuild.

**`user_list_items` are personal saved-list entries belonging to real users.** `position` is scoped to the `user_list`, which does not change, so a moved row keeps a valid position.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "moves a list item to the target" do
        list = lists(:basic_list)
        item = ListItem.create!(list: list, listable: @source, position: 3)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, item.reload.listable_id
      end

      test "promotes verified when the target is already on the list unverified" do
        list = lists(:basic_list)
        survivor = ListItem.create!(list: list, listable: @target, position: 1, verified: false)
        dropped = ListItem.create!(list: list, listable: @source, position: 2, verified: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert survivor.reload.verified, "verified must survive the collision"
        assert_not ListItem.exists?(dropped.id)
      end

      # merge_list_items writes through update!/create!, which the ListItem
      # validation rejects once the list is auto_generated. Without the skip this
      # is a 500 in production admin the first time a merged book happens to sit
      # on that list.
      test "merges a book that sits on an auto-generated list without touching that list" do
        list = lists(:basic_list)
        item = ListItem.create!(list: list, listable: @source, position: 3)
        list.update!(auto_generated_kind: :user_favorites)

        # This test hand-crafts the auto-generated-list scenario without going
        # through the real generator; stub the merger's own regeneration call so a
        # real rebuild from live user_list_items can't blow away this row.
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        # The row was left where it was and died with the source's cascade; the
        # merger never wrote a row of its own onto the generated list.
        assert_not ListItem.exists?(item.id)
        assert_nil ListItem.find_by(list: list, listable: @target)
      end

      test "does not promote verified on an auto-generated list" do
        list = lists(:basic_list)
        ListItem.create!(list: list, listable: @target, position: 1, verified: false)
        ListItem.create!(list: list, listable: @source, position: 2, verified: true)
        list.update!(auto_generated_kind: :user_favorites)

        GenerateUserFavoritesListsJob.stubs(:perform_async)

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        survivor = ListItem.find_by(list: list, listable: @target)
        assert_not survivor.verified, "the generator owns this row; the merger must not edit it"
      end

      test "moves a personal list entry to the target" do
        user_list = user_lists(:regular_user_books_favorites)
        entry = UserListItem.create!(user_list: user_list, listable: @source, position: 5)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, entry.reload.listable_id
      end

      test "drops a personal list entry when the target is already in that list" do
        user_list = user_lists(:regular_user_books_favorites)
        UserListItem.create!(user_list: user_list, listable: @target, position: 1)
        duplicate = UserListItem.create!(user_list: user_list, listable: @source, position: 2)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not UserListItem.exists?(duplicate.id)
        assert_equal 1, UserListItem.where(user_list: user_list, listable: @target).count
      end
```

If `user_lists(:regular_user_books_favorites)` already holds a row for either book, destroy it at the top of the test so each branch is exercised deliberately — the games merger test does exactly this for `regular_user_fav_game_1`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL on all six.

- [ ] **Step 3: Write the implementation**

Add both calls to `merge_all_associations` and add:

```ruby
      def merge_list_items
        count = 0
        source_book.list_items.find_each do |list_item|
          # An auto-generated list's rows belong to the generator, which rewrites
          # them nightly from the underlying user favorites -- and this merge has
          # already moved those. Writing here would raise against the ListItem
          # guard and turn an admin merge into a 500.
          next if list_item.list.auto_generated?

          existing = target_book.list_items.find_by(list_id: list_item.list_id)

          if existing
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            list_item.update!(listable_id: target_book.id)
          end
          count += 1
        end
        @stats[:list_items] = count
      end

      # position is scoped to the user_list, which does not change, so a moved row
      # keeps a valid position.
      def merge_user_list_items
        count = 0
        source_book.user_list_items.find_each do |entry|
          if UserListItem.exists?(user_list_id: entry.user_list_id, listable: target_book)
            entry.destroy!
          else
            entry.update!(listable_id: target_book.id)
            count += 1
          end
        end
        @stats[:user_list_items] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the skip is load-bearing**

Delete the `next if list_item.list.auto_generated?` line and re-run. Expected: "merges a book that sits on an auto-generated list" FAILS with a validation error — the exact 500 this prevents. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Move list items and personal list entries in the book merger"
```

---

### Task 6: Reviews and the review summary

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 5's `#merge_all_associations`.
- Produces: private `#merge_reviews`, `stats[:reviews]`, `stats[:reviews_dropped]`.

`Review` has `after_commit :recalculate_summary`, so a per-record `update!` would fire N recalculations. Bulk operations skip it, and the merger recalculates once explicitly. A subquery rather than a plucked id list: this codebase has already hit PostgreSQL's 65,535 bind-parameter cap with a large `IN`. `Services::Reviews::SummaryRecalculator` is the only writer of `review_summaries`, and the recalculation runs inside the transaction. The source's own `review_summary` dies with it via `dependent: :destroy`.

Unique index: `reviews` on `(user_id, reviewable_type, reviewable_id)` — a user who reviewed both books keeps the target's review and loses the source's.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "moves a review to the target" do
        review = Review.create!(user: users(:regular_user), reviewable: @source, rating: 8)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, review.reload.reviewable_id
      end

      test "drops a source review when the same user already reviewed the target" do
        user = users(:regular_user)
        kept = Review.create!(user: user, reviewable: @target, rating: 9)
        dropped = Review.create!(user: user, reviewable: @source, rating: 3)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Review.exists?(dropped.id)
        assert Review.exists?(kept.id)
        assert_equal 1, Review.where(user: user, reviewable: @target).count
      end

      test "recalculates the target's review summary once after moving reviews" do
        Review.create!(user: users(:regular_user), reviewable: @source, rating: 8)

        Services::Reviews::SummaryRecalculator.expects(:recalculate)
          .with("Books::Book", @target.id)
          .at_least_once

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
      end

      # DELIBERATE, not an oversight. Books::Book includes Correctable, whose
      # `dependent: :destroy` lets the duplicate's corrections die with it, and the
      # merger adds no code to move them. A correction on a duplicate is very often
      # "this is a dupe of X" -- the merge IS the resolution -- and repointing would
      # leave stale duplicate reports in the pending admin queue for a book that is
      # no longer a duplicate of anything. Measured at decision time: 29 of 455 book
      # corrections (6.4%) mention duplication, and that understates it at merge
      # time. The accepted cost is that substantive corrections on the duplicate are
      # lost. Music and games behave identically and are correct.
      #
      # This test exists so the decision cannot be silently reversed, and so a
      # reviewer who spots the missing merge_corrections finds the reasoning here.
      # See docs/superpowers/specs/2026-08-23-record-merge-design.md.
      test "lets the source's corrections die with it rather than moving them" do
        correction = Correction.create!(correctable: @source, notes: "Same as 10369")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Correction.exists?(correction.id)
        assert_equal 0, Correction.where(correctable: @target).count
      end
```

If `Review` or `Correction` reject these attributes, read the model and adjust the construction call only; never weaken an assertion to make a test pass.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL — reviews stay on the source; the second test fails on the leftover row.

- [ ] **Step 3: Write the implementation**

Add `merge_reviews` to `merge_all_associations` and add:

```ruby
      # Review has an after_commit :recalculate_summary, so a per-record update!
      # would fire N recalculations. delete_all/update_all skip it and the merger
      # recalculates once, explicitly, inside the transaction.
      #
      # A subquery, not a plucked id list: this codebase has already hit
      # PostgreSQL's 65,535 bind-parameter cap with a large IN.
      def merge_reviews
        dropped = Review.where(reviewable: source_book)
          .where(user_id: Review.where(reviewable: target_book).select(:user_id))
          .delete_all

        moved = Review.where(reviewable: source_book)
          .update_all(reviewable_id: target_book.id)

        @stats[:reviews] = moved
        @stats[:reviews_dropped] = dropped

        Services::Reviews::SummaryRecalculator.recalculate("Books::Book", target_book.id)
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the drop branch is real**

Delete the `delete_all` statement and re-run. Expected: "drops a source review when the same user already reviewed the target" FAILS with a uniqueness violation. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Move reviews and recalculate the review summary in the book merger"
```

---

### Task 7: Book relationships and the series representative

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 6's `#merge_all_associations`.
- Produces: private `#merge_book_relationships`, `#merge_inverse_book_relationships`, `#repoint_series_representative`, with `stats[:book_relationships]`, `stats[:inverse_book_relationships]`, `stats[:series_representative]`.

`Books::BookRelationship` validates `no_self_reference` and has a unique index on `(book_id, related_book_id, relation_type)`. Two rows must be dropped rather than repointed: one that already points **at** the survivor (repointing makes it relate to itself, which the validation rejects — and since that raise happens inside the transaction, leaving it in place rolls the entire merge back), and one the survivor already holds.

`books_series.representative_book_id` is an **inbound** FK with `on_delete: nullify`. Do nothing and it silently blanks instead of following the merge. `Books::Book` declares no inverse association for it, so the merger queries `::Books::Series` directly.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "moves a book relationship to the target" do
        relationship = ::Books::BookRelationship.create!(
          book: @source, related_book: books_books(:got), relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.book_id
      end

      test "drops a relationship that would make the target relate to itself" do
        relationship = ::Books::BookRelationship.create!(
          book: @source, related_book: @target, relation_type: :related_to
        )

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "a self-relation must be dropped, not roll the merge back"
        assert_not ::Books::BookRelationship.exists?(relationship.id)
      end

      test "drops a relationship the target already holds" do
        other = books_books(:got)
        ::Books::BookRelationship.create!(
          book: @target, related_book: other, relation_type: :related_to
        )
        duplicate = ::Books::BookRelationship.create!(
          book: @source, related_book: other, relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::BookRelationship.exists?(duplicate.id)
      end

      test "moves an inverse book relationship to the target" do
        relationship = ::Books::BookRelationship.create!(
          book: books_books(:got), related_book: @source, relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.related_book_id
      end

      test "drops an inverse relationship that would make the target relate to itself" do
        relationship = ::Books::BookRelationship.create!(
          book: @target, related_book: @source, relation_type: :related_to
        )

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "a self-relation must be dropped, not roll the merge back"
        assert_not ::Books::BookRelationship.exists?(relationship.id)
      end

      test "drops an inverse relationship the target already holds" do
        other = books_books(:got)
        ::Books::BookRelationship.create!(
          book: other, related_book: @target, relation_type: :related_to
        )
        duplicate = ::Books::BookRelationship.create!(
          book: other, related_book: @source, relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::BookRelationship.exists?(duplicate.id)
      end

      # books_series.representative_book_id is on_delete: nullify. Without an
      # explicit repoint the merge silently blanks the series' representative
      # instead of pointing it at the survivor.
      test "repoints a series whose representative book was the source" do
        series = books_series(:asoiaf)
        series.update!(representative_book: @source)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, series.reload.representative_book_id
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL. The two self-relation tests fail by rolling the whole merge back — exactly the failure mode the drops prevent. The series test fails with `nil`.

- [ ] **Step 3: Write the implementation**

Add all three to `merge_all_associations` and add:

```ruby
      # Repoints book_id. Two rows must be dropped instead: one that already points
      # AT the target (repointing it makes the survivor relate to itself, which
      # no_self_reference rejects and the whole merge would roll back on), and one
      # the target already holds, which the (book_id, related_book_id,
      # relation_type) unique index would reject.
      def merge_book_relationships
        count = 0
        source_book.book_relationships.find_each do |relationship|
          if relationship.related_book_id == target_book.id
            relationship.destroy!
            next
          end

          collides = ::Books::BookRelationship.exists?(
            book_id: target_book.id,
            related_book_id: relationship.related_book_id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(book_id: target_book.id)
            count += 1
          end
        end
        @stats[:book_relationships] = count
      end

      # The mirror image: repoints related_book_id, with the same two drops.
      # Direction is meaningful, so a relationship that survives in one direction
      # is not a duplicate of one in the other and both are kept.
      def merge_inverse_book_relationships
        count = 0
        source_book.inverse_book_relationships.find_each do |relationship|
          if relationship.book_id == target_book.id
            relationship.destroy!
            next
          end

          collides = ::Books::BookRelationship.exists?(
            book_id: relationship.book_id,
            related_book_id: target_book.id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(related_book_id: target_book.id)
            count += 1
          end
        end
        @stats[:inverse_book_relationships] = count
      end

      # An INBOUND foreign key with on_delete: nullify. Books::Book declares no
      # inverse association for it, so it is queried directly -- and if the merger
      # does nothing, source.destroy! silently blanks the series' representative
      # instead of following the merge.
      def repoint_series_representative
        @stats[:series_representative] = ::Books::Series
          .where(representative_book_id: source_book.id)
          .update_all(representative_book_id: target_book.id)
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Move book relationships and repoint the series representative"
```

---

### Task 8: The authors and credits gate

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 7's `#merge_all_associations`.
- Produces: private `#capture_gate_state`, `#merge_book_authors`, `#merge_credits`. Public reader `#stats` gains `:book_authors`, `:book_authors_not_transferred`, `:credits`, `:credits_not_transferred`. Task 11's action class reads the two `not_transferred` counts to build the admin's success message.

**The rule (spec departure 4):** duplicate books are usually bad imports, and a bad import's `book_authors` usually point at duplicate *author* rows. Transferring them leaves the survivor showing two rows for the same person — visible on the public page, in `author_names` in the search index, and in author rankings. So `book_authors` transfer **only if the survivor has zero authors**, and `credits` transfer **only if the survivor has zero credits**, evaluated independently. Either way the counts of what was left behind are reported.

**Ordering constraint 4:** "did the survivor have authors/credits?" must be captured **before any writes**, so the gate decision and the report read the same state.

`Books::BookAuthor#queue_book_for_reindexing` fires on `book_id` change and guards each id with `Books::Book.exists?`. Per-record `update!` is fine here (a book has a handful of authors, not thousands) — it queues a redundant `index_item` for the target, which Task 10 queues anyway, and one for the source, which the source's own `unindex_item` supersedes on destroy.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "transfers authors when the target has none, renumbering position from 1" do
        target = books_books(:crime_and_punishment) # has no authors
        source = books_books(:got)                  # has king at position 1
        ::Books::BookAuthor.create!(
          book: source, author: books_authors(:tolstoy), position: 7
        )

        result = ::Books::Book::Merger.call(source: source, target: target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        positions = target.reload.book_authors.order(:position).pluck(:position)
        assert_equal [1, 2], positions, "positions must be renumbered 1..n"
        assert_equal 2, target.authors.count
      end

      test "does not transfer authors when the target already has one" do
        # @target (war_and_peace) already has tolstoy.
        ::Books::BookAuthor.create!(
          book: @source, author: books_authors(:king), position: 1
        )

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal [books_authors(:tolstoy)], @target.reload.authors.to_a
        assert_equal 1, merger.stats[:book_authors_not_transferred]
      end

      test "transfers credits when the target has none" do
        target = books_books(:crime_and_punishment)
        source = books_books(:got)
        credit = ::Books::Credit.create!(
          author: books_authors(:garnett), creditable: source, role: :translator
        )

        result = ::Books::Book::Merger.call(source: source, target: target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal target.id, credit.reload.creditable_id
      end

      test "does not transfer credits when the target already has one" do
        ::Books::Credit.create!(
          author: books_authors(:garnett), creditable: @target, role: :translator
        )
        ::Books::Credit.create!(
          author: books_authors(:tolstoy), creditable: @source, role: :editor
        )

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal 1, @target.reload.credits.count
        assert_equal 1, merger.stats[:credits_not_transferred]
      end

      test "gates authors and credits independently" do
        # Target has an author but no credits: authors stay, credits move.
        credit = ::Books::Credit.create!(
          author: books_authors(:garnett), creditable: @source, role: :translator
        )
        ::Books::BookAuthor.create!(book: @source, author: books_authors(:king), position: 1)

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal 1, merger.stats[:book_authors_not_transferred]
        assert_equal @target.id, credit.reload.creditable_id
      end
```

If `::Books::Credit`'s `role` enum lacks `:translator` or `:editor`, read `app/models/books/credit.rb` and use real values.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL on all five.

- [ ] **Step 3: Write the implementation**

Add `capture_gate_state` as the **first** line of `merge_all_associations`, then `merge_book_authors` and `merge_credits` at the end:

```ruby
      # Ordering constraint: captured BEFORE any write, so the gate decision and
      # the report of what was not transferred read the same state.
      def capture_gate_state
        @target_had_authors = target_book.book_authors.exists?
        @target_had_credits = target_book.credits.exists?
      end

      # Duplicate books are usually bad imports, and a bad import's book_authors
      # usually point at duplicate AUTHOR rows. Transferring them leaves the
      # survivor showing two rows for the same person -- on the public page, in
      # author_names in the search index, and in author rankings, which derive from
      # an author's books. So the transfer happens only onto a book that has no
      # authors at all. Merging the duplicate AUTHOR first makes this moot, because
      # book_authors then dedupe on author_id automatically.
      def merge_book_authors
        if @target_had_authors
          @stats[:book_authors] = 0
          @stats[:book_authors_not_transferred] = source_book.book_authors.count
          return
        end

        moved = 0
        source_book.book_authors.order(:position).each.with_index(1) do |book_author, position|
          book_author.update!(book_id: target_book.id, position: position)
          moved += 1
        end

        @stats[:book_authors] = moved
        @stats[:book_authors_not_transferred] = 0
      end

      # Gated independently of authors: a book can legitimately have authors but no
      # credits, or the reverse.
      def merge_credits
        if @target_had_credits
          @stats[:credits] = 0
          @stats[:credits_not_transferred] = source_book.credits.count
          return
        end

        @stats[:credits] = source_book.credits.update_all(creditable_id: target_book.id)
        @stats[:credits_not_transferred] = 0
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the gate is load-bearing**

Delete the `if @target_had_authors ... return ... end` block and re-run. Expected: "does not transfer authors when the target already has one" FAILS. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Gate author and credit transfer on the survivor having none"
```

---

### Task 9: Scalar reconciliation

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 1's `#reconcile_scalars` hook; runs after Task 2's `#merge_editions`.
- Produces: private `#fill_blank_fields`, `#reconcile_first_published_year`, `#absorb_alternate_titles`; constant `BLANK_FILLABLE`; `stats[:filled_fields]` (array of symbols), `stats[:alternate_titles_added]` (array of strings).

Blank-filled: `subtitle`, `sort_title`, `book_length`, `page_range`, `word_count`, `description`, `original_language_id`, `default_edition_id`. Earliest wins: `first_published_year`. Absorbed: `alternate_titles`.

**Deliberately excluded, per the spec.** `book_kind` is a NOT NULL enum with a default, so it is never blank — the same reasoning that keeps `kind` out of the author merger. `amazon_enriched_at` marks that the Amazon lookup already ran: the survivor keeps its own value, because the merge hands it a batch of newly absorbed editions Amazon has never seen, and filling a blank stamp would let the enrichment sweep skip exactly the book that most needs it. `slug` is never touched.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`:

```ruby
      test "fills a blank field on the target from the source" do
        @source.update!(subtitle: "A Novel in Six Parts")

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        merger.call

        assert_equal "A Novel in Six Parts", @target.reload.subtitle
        assert_includes merger.stats[:filled_fields], :subtitle
      end

      test "never overwrites a non-blank field on the target" do
        @target.update!(subtitle: "The survivor's own subtitle")
        @source.update!(subtitle: "The duplicate's subtitle")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal "The survivor's own subtitle", @target.reload.subtitle
      end

      test "takes the earlier first_published_year" do
        # crime_and_punishment is 1866, war_and_peace is 1869.
        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1866, @target.reload.first_published_year
      end

      test "keeps the target's year when the source's is later" do
        @source.update!(first_published_year: 1999)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1869, @target.reload.first_published_year
      end

      test "keeps the target's year when the source has none" do
        @source.update!(first_published_year: nil)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1869, @target.reload.first_published_year
      end

      test "absorbs the source title and its alternates into the target's alternate titles" do
        @source.update!(alternate_titles: ["Prestuplenie i nakazanie"])

        ::Books::Book::Merger.call(source: @source, target: @target)

        titles = @target.reload.alternate_titles
        assert_includes titles, "Crime and Punishment"
        assert_includes titles, "Prestuplenie i nakazanie"
        assert_includes titles, "Voyna i mir", "the target's own alternates must survive"
      end

      test "never lists the target's own title among its alternate titles" do
        @source.update!(title: "War and Peace", slug: "war-and-peace-duplicate")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not_includes @target.reload.alternate_titles, "War and Peace"
      end

      test "does not blank-fill amazon_enriched_at" do
        @source.update!(amazon_enriched_at: Time.current)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_nil @target.reload.amazon_enriched_at,
          "filling this would let the enrichment sweep skip a book carrying " \
          "newly absorbed editions Amazon has never seen"
      end

      test "fills default_edition_id only after the source's editions have moved" do
        edition = ::Books::Edition.create!(book: @source, title: "Pevear translation")
        @source.update!(default_edition: edition)
        @target.update!(default_edition: nil)

        ::Books::Book::Merger.call(source: @source, target: @target)

        @target.reload
        assert_equal edition.id, @target.default_edition_id
        assert_equal @target.id, edition.reload.book_id,
          "the default edition must belong to the survivor, not to a deleted book"
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL on the reconciliation tests. "does not blank-fill amazon_enriched_at" passes vacuously right now — it is a regression guard for a later editor, which is why it is written.

- [ ] **Step 3: Write the implementation**

Add the constant near the top of the class, below `Result`:

```ruby
      # The survivor's own non-blank value always wins; these are only filled when
      # it has none.
      #
      # book_kind is deliberately absent: it is a NOT NULL enum with a default, so
      # it is never blank. amazon_enriched_at is deliberately absent too -- it
      # marks that the Amazon lookup already ran, and the merge hands the survivor
      # a batch of newly absorbed editions Amazon has never seen. Filling a blank
      # stamp would mark the survivor "done" and let the enrichment sweep skip
      # exactly the book that most needs it.
      #
      # When descriptions-subsystem step D7 drops books_books.description, remove
      # :description from this list or fill_blank_fields raises inside the
      # transaction.
      BLANK_FILLABLE = %i[
        subtitle sort_title book_length page_range word_count
        description original_language_id default_edition_id
      ].freeze
```

Replace the empty `reconcile_scalars` with:

```ruby
      def reconcile_scalars
        fill_blank_fields
        reconcile_first_published_year
        absorb_alternate_titles
      end

      # default_edition_id is in BLANK_FILLABLE, which is why merge_editions must
      # already have run: otherwise the survivor's FK points at a row owned by the
      # record about to be deleted.
      def fill_blank_fields
        filled = []

        BLANK_FILLABLE.each do |field|
          next if target_book.public_send(field).present?

          value = source_book.public_send(field)
          next if value.blank?

          target_book.public_send(:"#{field}=", value)
          filled << field
        end

        @stats[:filled_fields] = filled
      end

      def reconcile_first_published_year
        source_year = source_book.first_published_year
        return if source_year.blank?

        target_year = target_book.first_published_year
        return if target_year.present? && target_year <= source_year

        target_book.first_published_year = source_year
      end

      # Absorbing the duplicate's title is often the whole point of the merge: the
      # deleted spelling should stay findable. alternate_titles is GIN-indexed and
      # feeds as_indexed_json, so the search index picks this up on the target's
      # post-commit reindex.
      def absorb_alternate_titles
        existing = Array(target_book.alternate_titles)
        incoming = ([source_book.title] + Array(source_book.alternate_titles))
          .map { |value| value.to_s.strip }
          .compact_blank

        merged = (existing + incoming).uniq - [target_book.title]
        return if merged == existing

        @stats[:alternate_titles_added] = merged - existing
        target_book.alternate_titles = merged
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the ordering constraint is real**

In `call`, temporarily swap the order so `reconcile_scalars` runs **before** `merge_all_associations`, and re-run. Expected: "fills default_edition_id only after the source's editions have moved" FAILS — the survivor's `default_edition_id` points at a row still owned by the book about to be deleted, and the FK's `on_delete: nullify` then blanks it. Restore the original order.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Reconcile scalars and absorb alternate titles in the book merger"
```

---

### Task 10: Post-commit — reindex, ranking recalculation, favorites rebuild

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb`
- Test: `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 1's `#collect_affected_ranking_configurations` and `#run_post_commit_steps` hooks.
- Produces: private `#reindex_target_book`, `#schedule_ranking_recalculation`, `#regenerate_user_favorites_list`; `stats[:post_commit_error]` on failure.

**Ordering constraint 1:** ranking configuration ids are collected **first**, before anything else in the transaction. Once `source.destroy!` cascades its `ranked_items`, the affected set is unrecoverable.

**Book merge fans out no reindex requests beyond the survivor's own.** Author merge needs a fan-out because `Books::Book#as_indexed_json` embeds `author_names` and `author_ids`. The converse does not hold: `Books::Author#as_indexed_json` carries only `name`, `alternate_names` and `category_ids`, so a book merge changes no author document. Author *rankings* still recalculate for free — `CalculateRankingsJob` already cascades into `Books::CalculateAuthorRankingsJob` for any `Books::RankingConfiguration`.

**The reindex tests need the scalar confound neutralised.** Scalar reconciliation nearly always dirties the survivor — absorbing the duplicate's title alone does it — and the resulting `target.save!` fires `SearchIndexable`'s own `after_commit`, creating exactly the `index_item` row these tests mean to attribute to the merger's explicit reindex. Without the helper they pass against a merger that does no reindexing at all.

- [ ] **Step 1: Write the failing tests**

Append inside `MergerTest`, and add the helper as a `private` method at the bottom of the class:

```ruby
      test "queues a reindex for the target after the merge commits" do
        neutralize_scalar_confound

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error]
        assert SearchIndexRequest.exists?(
          parent_type: "Books::Book", parent_id: @target.id, action: "index_item"
        )
      end

      test "does not queue indexing while migration suppression is on" do
        neutralize_scalar_confound
        Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not SearchIndexRequest.exists?(
          parent_type: "Books::Book", parent_id: @target.id, action: "index_item"
        )
      end

      test "schedules ranking recalculation for every affected configuration" do
        config = ranking_configurations(:books_global)
        RankedItem.create!(item: @source, ranking_configuration: config, rank: 5)

        BulkCalculateWeightsJob.expects(:perform_async).with(config.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
      end

      test "collects the source's ranking configurations before the destroy cascade" do
        config = ranking_configurations(:books_global)
        # Only the SOURCE is ranked. If the ids were collected after the destroy,
        # its ranked_items would already be gone and this job would never fire.
        RankedItem.create!(item: @source, ranking_configuration: config, rank: 5)

        BulkCalculateWeightsJob.expects(:perform_async).with(config.id).once
        CalculateRankingsJob.stubs(:perform_in)
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        ::Books::Book::Merger.call(source: @source, target: @target)
      end

      test "rebuilds the generated favorites list after the merge commits" do
        GenerateUserFavoritesListsJob.expects(:perform_async).with("Books::UserList")

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
      end

      test "a post-commit failure is recorded but does not fail the merge" do
        source_id = @source.id
        GenerateUserFavoritesListsJob.stubs(:perform_async)
          .raises(StandardError.new("redis is down"))

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "the merge committed; reporting failure would be a lie"
        assert_equal "redis is down", merger.stats[:post_commit_error]
        assert_not ::Books::Book.exists?(source_id)
      end
```

And at the bottom of the class, before the final three `end`s.

**The `private` keyword below must be the last thing in the class — nothing may be appended after it.** Minitest's `test "..."` DSL defines each test with `define_method`, which respects the current default visibility, so any `test` block written after this `private` becomes a private method and **silently stops running**. No failure, no warning: the tests just vanish from the count. If a later change needs another test in this file, put it above the `private` line, and check the run count.

```ruby
      private

      # Scalar reconciliation nearly always dirties the target -- absorbing the
      # duplicate's title alone does it -- and the resulting target.save! fires
      # SearchIndexable's own after_commit, creating exactly the index_item row the
      # reindex tests mean to attribute to the merger's explicit reindex. Pre-set
      # the two scalars the merge would otherwise change so target.changed? stays
      # false and the only index request can be the merger's own.
      def neutralize_scalar_confound
        @target.update_columns(
          alternate_titles: [@source.title],
          first_published_year: @source.first_published_year
        )
        @target.reload
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: FAIL — no index request is created, no jobs are scheduled.

- [ ] **Step 3: Write the implementation**

Replace the empty `collect_affected_ranking_configurations` and `run_post_commit_steps`:

```ruby
      # Ordering constraint 1: runs first, before any association is touched. Once
      # source.destroy! cascades its ranked_items there is no way to recover which
      # ranking configurations the source used to belong to.
      def collect_affected_ranking_configurations
        source_configs = RankedItem.where(item_type: "Books::Book", item_id: source_book.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Books::Book", item_id: target_book.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
      end

      # The merge is committed by this point. Reindexing, ranking recalculation and
      # the generated-list rebuild are follow-up work: if they fail, the merge still
      # happened, so a failure here must not be reported as a failed merge.
      # `success?` means "the merge committed", and that is what the admin UI
      # reports.
      def run_post_commit_steps
        reindex_target_book
        schedule_ranking_recalculation
        regenerate_user_favorites_list
      rescue => error
        Rails.logger.error(
          "Books::Book::Merger: merge of #{@source_book_id} into #{target_book.id} " \
          "committed, but post-commit follow-up failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
      end

      # SearchIndexable already respects this flag on its own callbacks; the merger
      # matches it rather than writing requests during a bulk migration.
      #
      # No fan-out beyond this one request. Author merge reindexes its books
      # because Books::Book#as_indexed_json embeds author_names and author_ids; the
      # converse does not hold, since Books::Author#as_indexed_json carries no book
      # data. Unindexing the source is automatic -- SearchIndexable fires
      # unindex_item on destroy.
      def reindex_target_book
        return if Services::BooksMigration.search_indexing_suppressed?

        SearchIndexRequest.create!(parent: target_book, action: :index_item)
      end

      # perform_async writes to Redis, which a rollback cannot undo -- hence
      # post-commit, never inside the transaction. Author rankings come along for
      # free: CalculateRankingsJob already cascades into
      # Books::CalculateAuthorRankingsJob for any Books::RankingConfiguration.
      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          BulkCalculateWeightsJob.perform_async(config_id)
          CalculateRankingsJob.perform_in(5.minutes, config_id)
        end
      end

      # merge_list_items deliberately skips (rather than repoints) a source row on
      # the auto-generated favorites list, so that row is destroyed along with the
      # source and the generated list falls one item short. Only a full rebuild
      # produces the correct combined score, voter_count and position for the
      # survivor. Queuing it now runs it comfortably inside the 5 minutes before
      # CalculateRankingsJob would otherwise read that short list.
      def regenerate_user_favorites_list
        GenerateUserFavoritesListsJob.perform_async("Books::UserList")
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS

- [ ] **Step 5: Verify the confound helper is load-bearing**

Comment out the body of `reindex_target_book` and re-run. Expected: "queues a reindex for the target after the merge commits" FAILS. If it still passes, the confound is not neutralised — fix the helper before continuing, because the test is worthless otherwise. Restore the method.

- [ ] **Step 6: Run the whole merger file and lint**

Run: `cd web-app && bin/rails test test/lib/books/book/merger_test.rb`
Expected: PASS, all tests.

```bash
cd web-app && bundle exec standardrb --fix app/lib/books/book/merger.rb test/lib/books/book/merger_test.rb
git add web-app/app/lib/books/book/merger.rb web-app/test/lib/books/book/merger_test.rb
git commit -m "Reindex, recalculate rankings and rebuild favorites after a book merge"
```

---

### Task 11: The MergeBook action class

**Files:**
- Create: `web-app/app/lib/actions/admin/books/merge_book.rb`
- Test: `web-app/test/lib/actions/admin/books/merge_book_test.rb`

**Interfaces:**
- Consumes: `::Books::Book::Merger.new(source:, target:)` with `#call` and `#stats` from Task 10.
- Produces: `Actions::Admin::Books::MergeBook`, a subclass of `Actions::Admin::BaseAction`, with class methods `.name`, `.message`, `.confirm_button_label`, `.visible?(context)`, `.destructive?` (returns `true`), and an instance `#call` returning the base class's `succeed` / `warn` / `error` results. Reads `fields[:source_book_id]` and `fields[:confirm_merge]`.

**`destructive?` must return `true`.** Every controller's `execute_action` calls `authorize @record, :destroy? if action_class.destructive?` — that is the **only** place the merge permission gate is enforced. An action that forgets the override leaves the gate silently inert, with no failing test and no lint, and the only symptom is a domain editor being able to delete a record by merging it. `test/lint/merge_actions_destructive_test.rb` discovers this class by filesystem glob and will catch a missing override.

Model this file on `app/lib/actions/admin/books/merge_author.rb`. Every `Books::` constant is root-anchored: inside `Actions::Admin::Books`, a bare `Books::Book` resolves to `Actions::Admin::Books::Book`.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/actions/admin/books/merge_book_test.rb`:

```ruby
require "test_helper"

module Actions
  module Admin
    module Books
      class MergeBookTest < ActiveSupport::TestCase
        def setup
          @target = books_books(:war_and_peace)
          @source = books_books(:crime_and_punishment)
          @user = users(:admin_user)
          GenerateUserFavoritesListsJob.stubs(:perform_async)
        end

        def call_with(fields)
          Actions::Admin::Books::MergeBook.call(
            user: @user, models: [@target], fields: fields
          )
        end

        test "declares itself destructive so the controller's delete gate runs" do
          assert Actions::Admin::Books::MergeBook.destructive?
        end

        test "merges and reports success" do
          result = call_with(source_book_id: @source.id.to_s, confirm_merge: "1")

          assert result.success?
          assert_not ::Books::Book.exists?(@source.id)
          assert_match(/Crime and Punishment/, result.message)
        end

        test "refuses when no source is selected" do
          result = call_with(confirm_merge: "1")

          assert_not result.success?
          assert_match(/select a book/i, result.message)
          assert ::Books::Book.exists?(@source.id)
        end

        test "refuses when the confirmation checkbox is not ticked" do
          result = call_with(source_book_id: @source.id.to_s)

          assert_not result.success?
          assert_match(/confirm/i, result.message)
          assert ::Books::Book.exists?(@source.id)
        end

        test "refuses a source id that does not exist" do
          result = call_with(source_book_id: "0", confirm_merge: "1")

          assert_not result.success?
          assert_match(/not found/i, result.message)
        end

        test "refuses a self-merge" do
          result = call_with(source_book_id: @target.id.to_s, confirm_merge: "1")

          assert_not result.success?
          assert_match(/itself/i, result.message)
          assert ::Books::Book.exists?(@target.id)
        end

        test "refuses when given more than one model" do
          result = Actions::Admin::Books::MergeBook.call(
            user: @user,
            models: [@target, @source],
            fields: {source_book_id: @source.id.to_s, confirm_merge: "1"}
          )

          assert_not result.success?
          assert_match(/single book/i, result.message)
        end

        test "names what the authors gate left behind" do
          # war_and_peace already has tolstoy, so the source's author stays put.
          ::Books::BookAuthor.create!(
            book: @source, author: books_authors(:king), position: 1
          )

          result = call_with(source_book_id: @source.id.to_s, confirm_merge: "1")

          assert result.success?
          assert_match(/author/i, result.message)
        end

        test "warns rather than failing when a post-commit step fails" do
          GenerateUserFavoritesListsJob.stubs(:perform_async)
            .raises(StandardError.new("redis is down"))

          result = call_with(source_book_id: @source.id.to_s, confirm_merge: "1")

          assert_not ::Books::Book.exists?(@source.id), "the merge did commit"
          assert_match(/redis is down/, result.message)
        end
      end
    end
  end
end
```

Read `app/lib/actions/admin/base_action.rb` to confirm whether `warn` produces `success? == true` or a third state, and assert accordingly in the last test.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/actions/admin/books/merge_book_test.rb`
Expected: FAIL — `NameError: uninitialized constant Actions::Admin::Books::MergeBook`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/actions/admin/books/merge_book.rb`:

```ruby
module Actions
  module Admin
    module Books
      # Every Books:: constant in here is root-anchored. Inside
      # Actions::Admin::Books, a bare `Books::Book` resolves to
      # Actions::Admin::Books::Book and raises a confusing NameError.
      class MergeBook < Actions::Admin::BaseAction
        def self.name
          "Merge Another Book Into This One"
        end

        def self.message
          "Search for a duplicate book to merge into the current book. The source book will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Book"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        # The ONLY place the merge permission gate is enforced is the controller's
        # `authorize @record, :destroy? if action_class.destructive?`. Omitting this
        # override leaves that gate silently inert and lets a domain editor delete a
        # record by merging it. Guarded by test/lint/merge_actions_destructive_test.rb.
        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single book.") if models.count != 1

          target_book = models.first

          source_book_id = fields[:source_book_id] || fields["source_book_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_book_id.present?
            return error("Please select a book to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_book = ::Books::Book.find_by(id: source_book_id)

          unless source_book
            return error("Book with ID #{source_book_id} not found.")
          end

          if source_book.id == target_book.id
            return error("Cannot merge a book with itself. Please select a different book.")
          end

          source_title = source_book.title
          source_id = source_book.id

          merger = ::Books::Book::Merger.new(source: source_book, target: target_book)
          result = merger.call

          if result.success?
            succeed_or_warn(merger, source_title, source_id, target_book)
          else
            error "Failed to merge books: #{result.errors.join(", ")}"
          end
        end

        private

        def succeed_or_warn(merger, source_title, source_id, target_book)
          message = "Successfully merged '#{source_title}' (ID: #{source_id}) into " \
            "'#{target_book.title}'. The source book has been deleted."

          message += " #{not_transferred_note(merger)}" if not_transferred_note(merger).present?

          if merger.stats[:post_commit_error].present?
            warn "#{message} Note: search reindexing, ranking recalculation and the " \
              "generated favorites rebuild could not be scheduled " \
              "(#{merger.stats[:post_commit_error]}); they will need to be re-run."
          else
            succeed message
          end
        end

        # The authors/credits gate declines to transfer onto a book that already has
        # its own, to avoid two rows for the same person on the survivor. Say so, or
        # the admin has no way to know the duplicate's authors were left behind.
        def not_transferred_note(merger)
          parts = []
          authors = merger.stats[:book_authors_not_transferred].to_i
          credits = merger.stats[:credits_not_transferred].to_i

          parts << "#{authors} author#{"s" unless authors == 1}" if authors.positive?
          parts << "#{credits} credit#{"s" unless credits == 1}" if credits.positive?
          return "" if parts.empty?

          "The duplicate's #{parts.join(" and ")} were not transferred, because this book " \
            "already has its own."
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/actions/admin/books/merge_book_test.rb`
Expected: PASS

- [ ] **Step 5: Run the destructive-action lint**

Run: `cd web-app && bin/rails test test/lint/merge_actions_destructive_test.rb`
Expected: PASS. Temporarily change `destructive?` to return `false` and re-run — expected FAIL naming `Actions::Admin::Books::MergeBook`. Restore it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/actions/admin/books/merge_book.rb test/lib/actions/admin/books/merge_book_test.rb
git add web-app/app/lib/actions/admin/books/merge_book.rb web-app/test/lib/actions/admin/books/merge_book_test.rb
git commit -m "Add Actions::Admin::Books::MergeBook"
```

---

### Task 12: Route, controller and policy

**Files:**
- Modify: `web-app/config/routes.rb` (inside `resources :books` in the `admin/books` namespace, around line 514)
- Modify: `web-app/app/controllers/admin/books/books_controller.rb`
- Modify: `web-app/app/policies/books/book_policy.rb`
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb`

**Interfaces:**
- Consumes: `Actions::Admin::Books::MergeBook` from Task 11.
- Produces: the route helper `execute_action_admin_books_book_path(book)`, used by Task 13's view.

**Read spec departure 3 before writing the policy.** `execute_action?` is `global_role? || domain_role&.can_write?` — write access is the floor for a shared endpoint. It is **not** gated on `can_delete?`; the original design said that and increment 1 established it was wrong, because `execute_action` is shared with non-destructive actions on other domains. The delete gate lives in the controller as `authorize @record, :destroy? if action_class.destructive?`. `Books::BookPolicy` currently inherits nothing named `execute_action?`, so omitting it raises `NoMethodError` rather than failing open.

`validate_action_name!` is already inherited from `Admin::BaseController`; the controller only overrides `allowed_action_names`.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/controllers/admin/books/books_controller_test.rb`, inside its existing class:

```ruby
      test "an admin can merge a book via execute_action" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        sign_in_as(@admin_user, stub_auth: true)
        target = books_books(:war_and_peace)
        source = books_books(:crime_and_punishment)

        post execute_action_admin_books_book_path(target), params: {
          action_name: "MergeBook",
          source_book_id: source.id.to_s,
          confirm_merge: "1"
        }

        assert_redirected_to admin_books_book_path(target)
        assert_not ::Books::Book.exists?(source.id)
      end

      test "merge via turbo_stream replaces the flash target and still performs the merge" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        sign_in_as(@admin_user, stub_auth: true)
        target = books_books(:war_and_peace)
        source = books_books(:crime_and_punishment)

        post execute_action_admin_books_book_path(target), params: {
          action_name: "MergeBook",
          source_book_id: source.id.to_s,
          confirm_merge: "1"
        }, as: :turbo_stream

        assert_response :success
        assert_match(/turbo-stream/, response.content_type)
        assert_includes response.body, 'target="flash"'
        assert_not ::Books::Book.exists?(source.id)
      end

      # This is the entire point of the destructive? gate, and it is invisible if
      # only the happy path is covered.
      test "a books domain editor cannot merge" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        target = books_books(:war_and_peace)
        source = books_books(:crime_and_punishment)

        post execute_action_admin_books_book_path(target), params: {
          action_name: "MergeBook",
          source_book_id: source.id.to_s,
          confirm_merge: "1"
        }

        assert_redirected_to books_root_path
        assert ::Books::Book.exists?(source.id), "an editor must not be able to delete via merge"
      end

      test "a books domain moderator can merge" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        @regular_user.domain_roles.create!(domain: :books, permission_level: :moderator)
        sign_in_as(@regular_user, stub_auth: true)
        target = books_books(:war_and_peace)
        source = books_books(:crime_and_punishment)

        post execute_action_admin_books_book_path(target), params: {
          action_name: "MergeBook",
          source_book_id: source.id.to_s,
          confirm_merge: "1"
        }

        assert_not ::Books::Book.exists?(source.id)
      end

      test "execute_action rejects an action name outside the allowlist" do
        sign_in_as(@admin_user, stub_auth: true)

        post execute_action_admin_books_book_path(books_books(:war_and_peace)),
          params: {action_name: "Object"}

        assert_response :bad_request
      end
```

Check the existing file's `setup` for the real ivar names (`@admin_user`, `@regular_user`) and the redirect target the other authorization tests assert; mirror `test/controllers/admin/books/authors_controller_test.rb` if they differ.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'execute_action_admin_books_book_path'`

- [ ] **Step 3: Add the route**

In `web-app/config/routes.rb`, inside `resources :books` in the `admin/books` namespace, beside the existing `collection do get :search end` block:

```ruby
        member do
          post :execute_action
        end
```

- [ ] **Step 4: Add the policy method**

In `web-app/app/policies/books/book_policy.rb`, inside `class BookPolicy`:

```ruby
    # execute_action is a shared admin endpoint: write access is the floor to
    # reach it at all. The controller additionally requires destroy? for any
    # action that declares itself destructive (currently only MergeBook), so a
    # domain-scoped editor (can_write? but not can_delete?) still cannot merge,
    # even though this policy method returns true for them. Gating this method
    # itself on can_delete? would break non-destructive actions on the shared
    # endpoint -- see departure 3 in the design doc.
    def execute_action?
      global_role? || domain_role&.can_write?
    end
```

- [ ] **Step 5: Add the controller action**

In `web-app/app/controllers/admin/books/books_controller.rb`, add `:execute_action` to **both** `before_action` lists:

```ruby
  before_action :set_book, only: [:show, :edit, :update, :destroy, :execute_action]
  before_action :authorize_book, only: [:show, :edit, :update, :destroy, :execute_action]
```

Add the public action (after `destroy`, before `private`):

```ruby
  def execute_action
    fields_hash = params.except(:controller, :action, :id, :action_name)

    validate_action_name!
    action_class = "Actions::Admin::Books::#{params[:action_name]}".constantize
    # The delete gate for destructive actions. execute_action? itself only
    # requires write access, because this endpoint is shared.
    authorize @book, :destroy? if action_class.destructive?
    result = action_class.call(
      user: current_user,
      models: [@book],
      fields: fields_hash
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: {result: result}
        )
      end
      format.html { redirect_to admin_books_book_path(@book), notice: result.message }
    end
  end
```

And in the `private` section:

```ruby
  def allowed_action_names
    %w[MergeBook]
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: PASS

- [ ] **Step 7: Verify the delete gate is load-bearing**

Delete the `authorize @book, :destroy? if action_class.destructive?` line and re-run. Expected: "a books domain editor cannot merge" FAILS — the editor successfully deletes a book by merging it. Restore the line.

- [ ] **Step 8: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix config/routes.rb app/controllers/admin/books/books_controller.rb app/policies/books/book_policy.rb test/controllers/admin/books/books_controller_test.rb
git add web-app/config/routes.rb web-app/app/controllers/admin/books/books_controller.rb web-app/app/policies/books/book_policy.rb web-app/test/controllers/admin/books/books_controller_test.rb
git commit -m "Wire the book merge execute_action route, controller and policy"
```

---

### Task 13: Merge button and modal on the book show page

**Files:**
- Modify: `web-app/app/views/admin/books/books/show.html.erb`

**Interfaces:**
- Consumes: `execute_action_admin_books_book_path` from Task 12, `search_admin_books_books_path` (already exists and already honours `exclude_id`), `AutocompleteComponent`, and `current_user_can_delete?` (a `helper_method` on `Admin::BaseController`).
- Produces: `data-testid="merge-book-button"` and the dialog id `merge-book-modal`, both consumed by Task 14's E2E spec.

Port from `app/views/admin/books/authors/show.html.erb` (button at lines 14–20, modal at 183–245). **DaisyUI is v5:** do not use `form-control`, `label-text`, `input-bordered` or the other removed classes — they fail silently. `test/lint/daisyui_v4_classes_test.rb` will catch them.

The copy needs two things the games and authors wording has no equivalent for: that a **review** by a user who reviewed both books keeps the survivor's and discards the duplicate's, and that **authors and credits transfer only onto a book that has none**. Both are book-specific rules an admin has to know before pressing the button.

- [ ] **Step 1: Add the Merge button to the show header**

In `web-app/app/views/admin/books/books/show.html.erb`, between the Edit link and the Delete button (around lines 14–17):

```erb
      <% if current_user_can_delete? %>
        <button type="button"
                class="btn btn-warning btn-outline"
                data-testid="merge-book-button"
                onclick="document.getElementById('merge-book-modal').showModal()">
          <span>Merge</span>
        </button>
      <% end %>
```

- [ ] **Step 2: Add the modal at the end of the file**

```erb
<!-- Merge Book Modal -->
<dialog id="merge-book-modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Merge Another Book Into This One</h3>
    <p class="py-4">
      Search for a duplicate book to merge into <strong><%= @book.title %></strong>.
      Editions, identifiers, countries, series, categories, list entries, readers'
      personal list entries, reviews, images, links, descriptions and AI chats move
      across.
    </p>
    <p class="pb-4">
      Where <strong><%= @book.title %></strong> already has its own equivalent
      &mdash; the same identifier, the same series, the same kind of description, a
      review by the same reader &mdash; the duplicate's copy is discarded rather
      than kept alongside it. <strong><%= @book.title %></strong> may also take
      details from the duplicate: any field it was missing, the earlier publication
      year, and the duplicate's title and alternate titles, which are added to its
      own alternate titles.
    </p>
    <p class="pb-4">
      <strong>Authors and credits are the exception.</strong> They move across only
      if <strong><%= @book.title %></strong> has none of its own, because a
      duplicate's authors are usually duplicate author records and merging them in
      would show the same person twice. If they are left behind you will be told so.
      Merge the duplicate <em>author</em> first if you want them combined.
      The duplicate book will be permanently deleted.
    </p>

    <%= form_with url: execute_action_admin_books_book_path(@book),
                  method: :post,
                  class: "space-y-4",
                  data: {
                    controller: "modal-form",
                    modal_form_modal_id_value: "merge-book-modal"
                  } do |f| %>
      <%= f.hidden_field :action_name, value: "MergeBook" %>

      <div>
        <%= f.label :source_book_id, class: "label" do %>
          <span class="font-semibold">Source Book <span class="text-error">*</span></span>
        <% end %>
        <%= render AutocompleteComponent.new(
          name: "source_book_id",
          url: search_admin_books_books_path(exclude_id: @book.id),
          placeholder: "Search for book to merge...",
          required: true
        ) %>
        <label class="label">
          <span>Search for the duplicate book you want to merge into this one</span>
        </label>
      </div>

      <div>
        <label class="label cursor-pointer justify-start gap-2">
          <%= f.check_box :confirm_merge, class: "checkbox", required: true %>
          <span>I understand this action cannot be undone</span>
        </label>
        <label class="label">
          <span class="text-warning">The source book will be permanently deleted after merging</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="document.getElementById('merge-book-modal').close()">Cancel</button>
        <%= f.submit "Merge Book", class: "btn btn-warning" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

- [ ] **Step 3: Run the view-adjacent tests**

Run: `cd web-app && bin/rails test test/controllers/admin/books/books_controller_test.rb test/lint/daisyui_v4_classes_test.rb`
Expected: PASS. The controller's `show` test renders this view, so a syntax error or a bad route helper surfaces here.

- [ ] **Step 4: Check for trapped links**

Run: `cd web-app && bin/rails test test/controllers/admin/books/`
Expected: PASS, including `assert_no_frame_trapped_links` if the show page is covered by it.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/views/admin/books/books/show.html.erb
git add web-app/app/views/admin/books/books/show.html.erb
git commit -m "Add the merge button and modal to the book admin show page"
```

---

### Task 14: Playwright E2E spec

**Files:**
- Create: `web-app/e2e/tests/books/admin/books-merge.spec.ts`

**Interfaces:**
- Consumes: `data-testid="merge-book-button"` and the "Merge Book" submit button from Task 13.
- Produces: nothing consumed elsewhere.

**Deliberate constraint, not an omission: the spec does not perform a real merge.** E2E runs against the **development** database — the one with irreversible, hours-to-rebuild books data — and a merge destroys a row with no undo. The spec drives the modal up to but not past submission, exactly as `authors-merge.spec.ts` and `games-merge.spec.ts` do. Local only; CI does not run Playwright.

Requires a running dev server and `e2e/.env`. If the admin user is missing, run `bin/rails e2e:admin`.

- [ ] **Step 1: Write the spec**

Create `web-app/e2e/tests/books/admin/books-merge.spec.ts`:

```typescript
import { test, expect } from "@playwright/test";

// Deliberately does NOT perform a real merge. E2E runs against the development
// database, whose books data is irreversible and takes hours to rebuild, and a
// merge destroys a row with no undo. These drive the modal up to but not past
// submission, exactly as authors-merge.spec.ts does.
test.describe("Books admin — book merge", () => {
  test("merge button opens the modal on a book show page", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("merge-book-button").click();

    await expect(page.getByRole("heading", { name: "Merge Another Book Into This One" }))
      .toBeVisible();
    await expect(page.getByRole("button", { name: "Merge Book" })).toBeVisible();
  });

  test("merge requires the confirmation checkbox", async ({ page }) => {
    await page.goto("/admin/books");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/books\/[^/]+$/);

    await page.getByTestId("merge-book-button").click();
    await page.getByRole("button", { name: "Merge Book" }).click();

    // The checkbox is `required`, so the browser blocks submission and the modal stays open.
    await expect(page.getByRole("heading", { name: "Merge Another Book Into This One" }))
      .toBeVisible();
  });
});
```

- [ ] **Step 2: Run the spec**

Start the dev server in a separate terminal (`yarn build:all && bin/rails server` — `bin/dev` needs a TTY), then:

Run: `cd web-app && yarn test:e2e e2e/tests/books/admin/books-merge.spec.ts`
Expected: PASS, 2 tests.

If the run fails on authentication rather than on the assertions, run `bin/rails e2e:admin` and retry — the E2E admin user does not survive a reseed.

- [ ] **Step 3: Commit**

```bash
git add web-app/e2e/tests/books/admin/books-merge.spec.ts
git commit -m "Add a Playwright spec for the book merge modal"
```

---

### Task 15: Documentation and full-suite verification

**Files:**
- Modify: `docs/features/record-merge.md`

**Interfaces:** none.

`docs/features/record-merge.md` currently says books are "not yet built" in two places (the Overview paragraph and the "Related documentation" section) and is scoped to "games and authors, which is what exists today". Both statements become false with this increment. Per the documentation convention, features go in `docs/features/` and there are no class-level docs.

- [ ] **Step 1: Update the feature doc**

In `docs/features/record-merge.md`:

- In the Overview, replace the "Books are planned as increment 3 … **this doc covers games and authors**" sentence with a statement that all three exist, naming `::Books::Book::Merger` at `app/lib/books/book/merger.rb`.
- Add a **Books-specific rules** section covering: the authors/credits gate and why (a duplicate's `book_authors` usually point at duplicate author rows, so transferring shows the same person twice); reviews using `delete_all` + `update_all` + one explicit `SummaryRecalculator.recalculate` to avoid an N-recalculation callback storm; editions moving before `default_edition_id` is blank-filled; `books_series.representative_book_id` being an inbound `on_delete: nullify` FK that must be repointed explicitly; `Books::BookCountry`'s `counter_cache` requiring `destroy!` rather than `delete_all` on the drop branch; title absorption into `alternate_titles`; and `book_kind` and `amazon_enriched_at` being deliberately excluded from blank-fill.
- Add a short paragraph recording that **corrections are deliberately dropped**, with the measured rationale (6.4% of book corrections are duplicate reports; a merge is the admin actioning them; the cost is that substantive corrections on the duplicate are lost) and noting that music and games behave identically and are correct.
- Add a paragraph noting that book merge queues **no author reindex fan-out**, because `Books::Author#as_indexed_json` embeds no book data — the converse of the author merger's fan-out — and that author *rankings* still recalculate via `CalculateRankingsJob`'s cascade.
- Update "Related documentation" to drop "(not yet built)".

- [ ] **Step 2: Run the full test suite**

Run: `cd web-app && bin/rails db:test:prepare test`
Expected: PASS, 0 failures, 0 errors. This is what CI runs.

A clean run emits no warnings beyond the two known upstream sources (`weighted_list_rank`'s position `puts`, and npm/yarn during `test:prepare`). **A new warning line is a regression — fix the cause, do not filter the output.**

- [ ] **Step 3: Run the linter over everything**

Run: `cd web-app && bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 4: Verify Zeitwerk can eager-load the new directory**

`eager_load` is off in test, so a green suite never proves Zeitwerk can boot. `app/lib/books/book/` is a new directory.

Run: `cd web-app && CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

- [ ] **Step 5: Commit**

```bash
git add docs/features/record-merge.md
git commit -m "Document the book merger in the record-merge feature doc"
```

---

## Verification Checklist

Before opening a PR, confirm each of these ran and passed — evidence, not assertion:

- [ ] `bin/rails db:test:prepare test` — full suite green, no new warning lines
- [ ] `bundle exec standardrb` — no offenses
- [ ] `CI=1 bin/rails zeitwerk:check` — all is good
- [ ] `bin/rails test test/lint/merge_actions_destructive_test.rb` — `MergeBook` discovered and destructive
- [ ] `bin/rails test test/lint/daisyui_v4_classes_test.rb` — no removed classes in the new modal
- [ ] `yarn test:e2e e2e/tests/books/admin/books-merge.spec.ts` — 2 passing, local only
- [ ] The delete gate was verified by deleting `authorize @book, :destroy? if action_class.destructive?` and watching "a books domain editor cannot merge" go red
- [ ] Every repoint-or-drop rule was verified by deleting its collision branch and watching the drop test go red

Do **not** run brakeman — the owner does not use it. The gate is `bin/rails test` + `standardrb` + Playwright.
