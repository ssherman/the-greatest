# Books author importer — Increment 1 (core importer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `DataImporters::Books::Author` importer (query, finder, Open Library provider) and the book importer's author step, so a book import creates or reuses its authors and a title-plus-author re-import is idempotent.

**Architecture:** The authors finder follows the import-finder redesign's four-stage `FinderBase` pipeline with four sources: identifiers, exact name, OpenSearch `AuthorByName`, and the Open Library author record by key. Its Open Library provider fills blanks from that record. The book importer gains the author step:
- The book's Open Library provider links the accepted work's authors through the author importer.
- A new `Providers::Authors` step imports the query's author names whenever the book still has no authors, including when the Open Library service is unreachable, which is always the case in production today.

**Tech Stack:** Rails 8, Minitest 6 + Mocha + WebMock, OpenSearch (real index in search tests), the Open Library Rails client (`Books::OpenLibrary::Client`).

**Spec:** `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §2 and §16 item 1. §2 builds `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` §8 (the book provider's author step) and §9 (Authors). Read all three sections.

## Global Constraints

- Run every Rails command from `web-app/`. The spec and plan live in `docs/` at the repo root.
- Services, importers and search classes live under `app/lib/`, never `app/services/`.
- Inside `DataImporters::Books::…`, write model constants root-anchored: `::Books::Author`, `::Books::Book`, `::Books::BookAuthor`. Inside `DataImporters::Books::Book::Providers`, write the author importer as `::DataImporters::Books::Author::Importer`.
- Minitest 6: `assert_equal nil, x` is a hard failure; use `assert_nil`, or compare tuples.
- WebMock allows localhost, so Open Library test base URLs are non-loopback: `http://open-library.test:8080`.
- Sidekiq runs inline in tests. Any test that runs the book importer stubs `::Books::EnrichBookJob.stubs(:perform_async)`.
- Any test that runs the author finder without a real OpenSearch index stubs `::Search::Books::Search::AuthorByName.stubs(:call).returns([])`. That includes every book importer and book provider test, because they now reach the author importer.
- Fixture names are semantic: `books_authors(:tolstoy)` (Leo Tolstoy, 1828–1910, alternates "Lev Tolstoy", "Lev Nikolayevich Tolstoy"), `books_authors(:king)` (Stephen King, 1947), `books_books(:war_and_peace)` (linked to tolstoy), `ai_chats(:general_chat)`.
- Lint with `bundle exec standardrb`, never `bin/rubocop`. A clean `bin/rails test` prints no new warning lines.
- No class-level doc *files*. Short header comments in the class, matching the surrounding files, are the norm.
- Never run a destructive command against the development database.
- End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Names that differ only by Unicode spacing, curly quotes or case** ("O’Brien" vs "O'Brien", a U+202F space, all caps) must still hit the exact rule. The models normalize on save and the finder must normalize the query the same way. Test in Task 5.
2. **Two query author names that resolve to the same author** ("Leo Tolstoy" and "Lev Tolstoy" on one book) must produce one `book_authors` row, not a uniqueness error or a duplicate. Test in Task 7.
3. **An Open Library work author with a key but no name** must still import (the author importer takes the name from Open Library) and link. Test in Task 7.
4. **OpenSearch unavailable during an author import.** The finder records the source as failed, the exact source still decides, and the author is still matched or created. Test in Task 5.
5. **A persisted book that already has authors, re-imported with `force_providers`,** must not be touched by either author step. Test in Task 7.

---

### Task 1: Save-first importers and `ImportResult#created?`

A name alone is a complete author, but `ImporterBase` only saves a new item after a provider succeeds. The Open Library service is not deployed to production, so an author import there would persist nothing. This task adds an opt-in hook that saves a valid new item before providers run. It also adds a flag saying the import created the record, which the book's author step and increment 4 read.

**Files:**
- Modify: `web-app/app/lib/data_importers/import_result.rb`
- Modify: `web-app/app/lib/data_importers/importer_base.rb`
- Test: `web-app/test/lib/data_importers/importer_base_test.rb`
- Create: `web-app/test/lib/data_importers/import_result_test.rb` (no such test file exists yet)

**Interfaces:**
- Produces: `DataImporters::ImportResult.new(item:, provider_results:, success:, match: nil, created: false)`, `ImportResult#created?` (Boolean), and `summary[:item_created]`.
- Produces: `DataImporters::ImporterBase#save_before_providers?` (protected, default `false`). When `true`, a new, valid item is saved before any provider runs.

- [ ] **Step 1: Write the failing tests**

Add to `web-app/test/lib/data_importers/importer_base_test.rb`, inside `class ImporterBaseTest`, after the existing `TestImporter` class definition:

```ruby
    class FailingProvider < DataImporters::ProviderBase
      def populate(item, query:, match: nil)
        failure_result(errors: ["service down"])
      end
    end

    class FailingImporter < TestImporter
      def initialize(match:)
        super
        @provider = FailingProvider.new
      end
    end

    class SaveFirstImporter < FailingImporter
      protected

      def save_before_providers? = true
    end

    def unmatched_match
      match = Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule)
      match.decision = decision_for(match)
      match
    end
```

and these tests at the end of the class:

```ruby
    test "a save-first importer keeps a new record when every provider fails, and points the decision at it" do
      match = unmatched_match

      result = SaveFirstImporter.new(match: match).call(query: FakeQuery.new("Kept"))

      assert result.item.persisted?
      assert result.created?
      assert_not result.success?
      assert_equal result.item, match.decision.reload.record
    end

    test "a default importer does not save a new record when its only provider fails" do
      result = FailingImporter.new(match: unmatched_match).call(query: FakeQuery.new("Dropped"))

      assert_not result.item.persisted?
      assert_not result.created?
    end

    test "a save-first importer does not save an invalid new item" do
      result = SaveFirstImporter.new(match: unmatched_match).call(query: FakeQuery.new(nil))

      assert_not result.item.persisted?
      assert_not result.created?
    end

    test "created? is true for a new record a provider saved and false for a matched one" do
      created = TestImporter.new(match: unmatched_match).call(query: @query)
      matched = TestImporter.new(match: Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)).call(query: @query)
      forced = TestImporter.new(match: Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)).call(query: @query, force_providers: true)

      assert created.created?
      assert_not matched.created?
      assert_not forced.created?
    end

    test "an item-based import is never created" do
      result = TestImporter.new(match: nil).call(item: @existing)

      assert_not result.created?
    end
```

Create `web-app/test/lib/data_importers/import_result_test.rb` with the usual `# frozen_string_literal: true` / `require "test_helper"` / `module DataImporters` / `class ImportResultTest < ActiveSupport::TestCase` wrapper, containing:

```ruby
    test "created defaults to false and is reported in the summary" do
      result = ImportResult.new(item: nil, provider_results: [], success: true)
      created = ImportResult.new(item: nil, provider_results: [], success: true, created: true)

      assert_not result.created?
      assert created.created?
      assert_equal [false, true], [result.summary[:item_created], created.summary[:item_created]]
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/data_importers/importer_base_test.rb test/lib/data_importers/import_result_test.rb`
Expected: FAIL. The failures are `unknown keyword: :created` and `undefined method 'created?'`.

- [ ] **Step 3: Implement**

In `web-app/app/lib/data_importers/import_result.rb`:

```ruby
    attr_reader :item, :provider_results, :success, :match

    def initialize(item:, provider_results:, success:, match: nil, created: false)
      @item = item
      @provider_results = Array(provider_results)
      @success = success
      @match = match
      @created = created
    end

    def success?
      @success
    end

    # True when this call made the record: a query-based import whose finder
    # matched nothing, and whose new item was saved. The book importer's
    # author step reads it to know which of a book's authors are new.
    def created?
      @created == true
    end
```

and add `item_created: created?,` to the `summary` hash after `item_saved: item_saved?,`.

In `web-app/app/lib/data_importers/importer_base.rb`, replace:

```ruby
          # Use existing item or create new one
          target_item = existing || initialize_item(query)
          is_existing_item = existing.present?
        end
```

with:

```ruby
          # Use existing item or create new one
          target_item = existing || initialize_item(query)
          is_existing_item = existing.present?
          save_new_item(target_item) unless is_existing_item
        end
```

Replace the final `ImportResult.new(...)` in the single-item branch with:

```ruby
        ImportResult.new(
          item: target_item,
          provider_results: provider_results,
          success: success,
          match: match,
          created: match.present? && !is_existing_item && target_item.persisted?
        )
```

Add to the `protected` section, after `multi_item_import?`:

```ruby
    # Override to persist a new record before any provider runs. For a model
    # whose query alone is a complete record (an author's name), the record
    # then survives every provider failing -- the Open Library service is
    # not deployed to production -- and an async provider has an id to
    # enqueue with.
    def save_before_providers?
      false
    end

    def save_new_item(item)
      item.save! if save_before_providers? && item.valid?
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/data_importers/`
Expected: PASS, including every existing importer test.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/data_importers/import_result.rb web-app/app/lib/data_importers/importer_base.rb web-app/test/lib/data_importers/importer_base_test.rb web-app/test/lib/data_importers/import_result_test.rb
git commit -m "ImporterBase: opt-in save before providers; ImportResult#created?

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `Search::Books::Search::AuthorByName`

The authors finder's OpenSearch source.

**Files:**
- Create: `web-app/app/lib/search/books/search/author_by_name.rb`
- Test: `web-app/test/lib/search/books/search/author_by_name_test.rb`

**Interfaces:**
- Produces: `Search::Books::Search::AuthorByName.call(name:, alternate_names: [], **options)` returns an Array of `{id: String, score: Float, source: Hash}` (the `extract_hits_with_scores` shape). The options are `size` (default 10), `from` (default 0) and `min_score` (default `MIN_SCORE = 5.0`). It returns `[]` without searching when `name` is blank or normalizes to nothing.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/search/books/search/author_by_name_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class AuthorByNameTest < ActiveSupport::TestCase
        SEARCH = ::Search::Books::Search::AuthorByName

        def setup
          cleanup_test_index
          ::Search::Books::AuthorIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def index(*authors)
          authors.each { |author| ::Search::Books::AuthorIndex.index(author) }
          sleep(0.1)
        end

        test "index_name delegates to AuthorIndex" do
          assert_equal ::Search::Books::AuthorIndex.index_name, SEARCH.index_name
        end

        test "returns an empty array for a blank name without searching" do
          SEARCH.expects(:search).never

          assert_equal [], SEARCH.call(name: "")
          assert_equal [], SEARCH.call(name: nil)
        end

        test "returns an empty array without searching when the name normalizes to nothing" do
          SEARCH.expects(:search).never

          assert_equal [], SEARCH.call(name: "***")
        end

        test "finds an author by name and not an unrelated one" do
          tolstoy = books_authors(:tolstoy)
          index(tolstoy, books_authors(:king))

          results = SEARCH.call(name: "Leo Tolstoy")

          assert_equal [tolstoy.id.to_s], results.map { |hit| hit[:id] }
          assert results[0][:score] > 0
        end

        test "finds an author whose alternate name is the query name" do
          tolstoy = books_authors(:tolstoy)
          index(tolstoy)

          assert_equal [tolstoy.id.to_s], SEARCH.call(name: "Lev Tolstoy").map { |hit| hit[:id] }
        end

        test "finds an author from an inverted name" do
          tolstoy = books_authors(:tolstoy)
          index(tolstoy)

          assert_equal [tolstoy.id.to_s], SEARCH.call(name: "Tolstoy, Leo").map { |hit| hit[:id] }
        end

        test "an ASCII spelling finds the accented name" do
          author = ::Books::Author.create!(name: "Gabriel García Márquez")
          index(author)

          assert_equal [author.id.to_s], SEARCH.call(name: "Gabriel Garcia Marquez").map { |hit| hit[:id] }
        end

        test "the query's alternate names rank an author carrying them first" do
          plain = ::Books::Author.create!(name: "Mary Shelley")
          known = ::Books::Author.create!(name: "Mary Shelley", alternate_names: ["Mary Wollstonecraft Godwin"])
          index(plain, known)

          results = SEARCH.call(name: "Mary Shelley", alternate_names: ["Mary Wollstonecraft Godwin"])

          assert_equal known.id.to_s, results.first[:id]
          assert_equal 2, results.size
        end

        private

        def cleanup_test_index
          ::Search::Books::AuthorIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/search/books/search/author_by_name_test.rb`
Expected: FAIL with `uninitialized constant Search::Books::Search::AuthorByName`.

- [ ] **Step 3: Implement**

Create `web-app/app/lib/search/books/search/author_by_name.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      # The authors finder's OpenSearch source: candidates for "is this
      # person already in the catalog?". The name, or an alternate name, is
      # required; the query's own alternate names are boosts.
      # alternate_names sits inside the required group because the merger
      # folds a merged-away name into it, so the deleted spelling stays
      # findable here (the same reasoning as BookByTitleAndAuthors).
      class AuthorByName < ::Search::Base::Search
        MIN_SCORE = 5.0

        def self.index_name
          ::Search::Books::AuthorIndex.index_name
        end

        def self.call(name:, alternate_names: [], **options)
          return empty_response if name.blank?

          cleaned_name = ::Search::Shared::Utils.normalize_search_text(name)
          return empty_response if cleaned_name.blank?

          size = options[:size] || 10
          from = options[:from] || 0
          min_score = options[:min_score] || MIN_SCORE

          query_definition = build_query_definition(cleaned_name, Array(alternate_names), min_score, size, from)

          Rails.logger.info "Author by name search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(cleaned_name, alternate_names, min_score, size, from)
          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              must: [
                ::Search::Shared::Utils.build_bool_query(
                  should: build_name_clauses(cleaned_name),
                  minimum_should_match: 1
                )
              ],
              should: build_alternate_clauses(alternate_names)
            )
          }
        end

        def self.build_name_clauses(cleaned_name)
          [
            ::Search::Shared::Utils.build_match_phrase_query("name", cleaned_name, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("name.keyword", cleaned_name.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("name", cleaned_name, boost: 8.0, operator: "and"),
            ::Search::Shared::Utils.build_match_phrase_query("alternate_names", cleaned_name, boost: 7.0),
            ::Search::Shared::Utils.build_match_query("alternate_names", cleaned_name, boost: 6.0, operator: "and")
          ]
        end

        def self.build_alternate_clauses(alternate_names)
          alternate_names.flat_map do |alternate|
            cleaned = ::Search::Shared::Utils.normalize_search_text(alternate)
            next [] if cleaned.blank?

            [
              ::Search::Shared::Utils.build_match_phrase_query("name", cleaned, boost: 4.0),
              ::Search::Shared::Utils.build_match_phrase_query("alternate_names", cleaned, boost: 3.0)
            ]
          end
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_name_clauses, :build_alternate_clauses
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/search/books/search/author_by_name_test.rb`
Expected: PASS. If "finds an author from an inverted name" fails because the hit scores under `MIN_SCORE`, do not lower `MIN_SCORE` to make it pass. Stop and report the measured score; `MIN_SCORE` is shared with every production query.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/search/books/search/author_by_name.rb web-app/test/lib/search/books/search/author_by_name_test.rb
git commit -m "Search: AuthorByName, the authors finder's OpenSearch source

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `DataImporters::Books::Author::ImportQuery`

**Files:**
- Create: `web-app/app/lib/data_importers/books/author/import_query.rb`
- Test: `web-app/test/lib/data_importers/books/author/import_query_test.rb`

**Interfaces:**
- Produces: `DataImporters::Books::Author::ImportQuery.new(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [])`, with readers of the same names, plus `#valid?`, `#validate!` (raises `ArgumentError`) and `.from_snapshot(hash)`. `alternate_names` and `work_titles` are arrays of non-blank unique strings. `open_library_author_key` is `nil` when blank.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/data_importers/books/author/import_query_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class ImportQueryTest < ActiveSupport::TestCase
        test "a name alone is valid" do
          assert ImportQuery.new(name: "Leo Tolstoy").valid?
        end

        test "an Open Library key alone is valid: the name comes from Open Library" do
          assert ImportQuery.new(open_library_author_key: "OL26783A").valid?
        end

        test "neither a name nor a key is invalid, and validate! raises" do
          query = ImportQuery.new(name: " ")

          assert_not query.valid?
          error = assert_raises(ArgumentError) { query.validate! }
          assert_match(/Name is required/, error.message)
        end

        test "a non-string name and non-integer years are invalid" do
          assert_not ImportQuery.new(name: 42).valid?
          assert_not ImportQuery.new(name: "Leo Tolstoy", birth_year: "1828").valid?
          assert_not ImportQuery.new(name: "Leo Tolstoy", death_year: 1910.5).valid?
        end

        test "alternate names and work titles drop blanks and duplicates; a blank key is nil" do
          query = ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "", alternate_names: ["Lev Tolstoy", "", "Lev Tolstoy", nil],
            work_titles: ["War and Peace", " ", "War and Peace"])

          assert_equal [["Lev Tolstoy"], ["War and Peace"]], [query.alternate_names, query.work_titles]
          assert_nil query.open_library_author_key
        end

        test "from_snapshot rebuilds the query a match decision stored and drops unknown keys" do
          original = ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A", birth_year: 1828, death_year: 1910,
            alternate_names: ["Lev Tolstoy"], work_titles: ["War and Peace"])
          snapshot = original.instance_variables.to_h { |ivar| [ivar.to_s.delete("@"), original.instance_variable_get(ivar)] }

          rebuilt = ImportQuery.from_snapshot(snapshot.merge("retired_field" => "x"))

          assert_equal [original.name, original.open_library_author_key, original.birth_year, original.death_year, original.alternate_names, original.work_titles],
            [rebuilt.name, rebuilt.open_library_author_key, rebuilt.birth_year, rebuilt.death_year, rebuilt.alternate_names, rebuilt.work_titles]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/import_query_test.rb`
Expected: FAIL with `uninitialized constant DataImporters::Books::Author`.

- [ ] **Step 3: Implement**

Create `web-app/app/lib/data_importers/books/author/import_query.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # Query object for ::Books::Author imports. `name` is required unless an
      # Open Library author key is given (a key-only import takes its name
      # from Open Library). `work_titles` is context for the AI prompt and
      # the audit pages; it is never matched on.
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :name, :open_library_author_key, :birth_year, :death_year, :alternate_names, :work_titles

        SNAPSHOT_KEYS = %i[name open_library_author_key birth_year death_year alternate_names work_titles].freeze

        # Rebuilds a query from the hash FinderBase#query_snapshot stored on
        # match_decisions.query. Unknown keys are dropped so an older row
        # still loads. The audit page's Re-check is the caller.
        def self.from_snapshot(snapshot)
          new(**snapshot.to_h.symbolize_keys.slice(*SNAPSHOT_KEYS))
        end

        def initialize(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [])
          @name = name
          @open_library_author_key = open_library_author_key.presence
          @birth_year = birth_year
          @death_year = death_year
          @alternate_names = Array(alternate_names).compact_blank.map(&:to_s).uniq
          @work_titles = Array(work_titles).compact_blank.map(&:to_s).uniq
        end

        def valid?
          validation_errors.empty?
        end

        def validate!
          errors = validation_errors
          raise ArgumentError, errors.join(", ") if errors.any?
        end

        private

        def validation_errors
          errors = []
          errors << "Name is required when no Open Library author key is provided" if name.blank? && open_library_author_key.blank?
          errors << "Name must be a string" if name.present? && !name.is_a?(String)
          errors << "Birth year must be an integer" if birth_year.present? && !birth_year.is_a?(Integer)
          errors << "Death year must be an integer" if death_year.present? && !death_year.is_a?(Integer)
          errors
        end
      end
    end
  end
end
```

Note: `" ".blank?` is true, so the "neither" test's `name: " "` is treated as absent. `42.present?` is true and `42.is_a?(String)` is false, so a non-string name is caught.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/import_query_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/data_importers/books/author/import_query.rb web-app/test/lib/data_importers/books/author/import_query_test.rb
git commit -m "DataImporters::Books::Author::ImportQuery

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The authors finder's Open Library source

**Files:**
- Create: `web-app/app/lib/data_importers/books/author/open_library_source.rb`
- Test: `web-app/test/lib/data_importers/books/author/open_library_source_test.rb`

**Interfaces:**
- Consumes: `ImportQuery#open_library_author_key` (Task 3); `Books::OpenLibrary::Client#author(key)`, which returns `Books::OpenLibrary::Author` (`key`, `name`, `alternate_names`, `birth_year`, `death_year`, `redirected_from`) and raises `Books::OpenLibrary::Exceptions::NotFoundError` on a 404.
- Produces: `DataImporters::Books::Author::OpenLibrarySource.new(query:, client: nil)`, with `#name` returning `:open_library` and `#call` returning an Array of `DataImporters::Candidate`.
  - Every candidate has `external_source: :open_library`, `external_key:` set to the author's canonical key, `external_record:` set to the `Books::OpenLibrary::Author`, `sources: [:open_library]` and `evidence[:external_verdict] == "accept"`.
  - With no local holder, there is one external-only candidate whose evidence is `title:` (the OL name), `year:` (the birth year), `alternate_names:`, `birth_year:` and `death_year:`.
  - With holders, there is one candidate per holder, `record:` set to the local author. Its evidence uses `external_title`, `external_year`, `external_alternate_names`, `external_birth_year` and `external_death_year`, so the local evidence the finder merges in is not overwritten.
  - `[]` when the query has no key or Open Library answers 404. Other client errors propagate, and the finder records the source as failed.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/data_importers/books/author/open_library_source_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class OpenLibrarySourceTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          @client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:author_source:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @tolstoy = books_authors(:tolstoy)
        end

        def source(key)
          OpenLibrarySource.new(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: key), client: @client)
        end

        def stub_author(key, record_key: key, redirected_from: [], name: "Leo Tolstoy", status: 200)
          body = {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "key" => {"source" => "openlibrary", "key" => record_key},
              "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} },
              "name" => name, "alternate_names" => ["Lev Nikolayevich Tolstoy"], "birth_year" => 1828, "death_year" => 1910
            }
          }
          stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
        end

        test "a query without a key contributes nothing and makes no request" do
          assert_equal [], OpenLibrarySource.new(query: ImportQuery.new(name: "Leo Tolstoy"), client: @client).call
          assert_not_requested(:get, %r{#{BASE_URL}/authors/})
        end

        test "an unheld key is one external-only accepted candidate carrying the Open Library record" do
          stub_author("OL26783A")

          candidates = source("OL26783A").call

          assert_equal 1, candidates.size
          candidate = candidates.first
          assert_nil candidate.record
          assert_equal ["OL26783A", :open_library, [:open_library]], [candidate.external_key, candidate.external_source, candidate.sources]
          assert candidate.external_accepted?
          assert_instance_of ::Books::OpenLibrary::Author, candidate.external_record
          assert_equal ["Leo Tolstoy", 1828, 1910, ["Lev Nikolayevich Tolstoy"]],
            candidate.evidence.values_at(:title, :birth_year, :death_year, :alternate_names)
        end

        test "a local author holding the key, or a key it redirects from, is a holder candidate with external_ evidence" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL1A")
          stub_author("OL2A", record_key: "OL2A", redirected_from: ["OL1A"])

          candidates = source("OL2A").call

          assert_equal [@tolstoy], candidates.map(&:record)
          assert_equal "OL2A", candidates.first.external_key
          assert_nil candidates.first.evidence[:title]
          assert_equal ["Leo Tolstoy", 1828], candidates.first.evidence.values_at(:external_title, :external_birth_year)
        end

        test "a 404 is no candidates, not a failure" do
          stub_author("OL404A", status: 404)

          assert_equal [], source("OL404A").call
        end

        test "a server error propagates so the finder records a failed source" do
          stub_author("OL500A", status: 500)

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { source("OL500A").call }
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/open_library_source_test.rb`
Expected: FAIL with `uninitialized constant DataImporters::Books::Author::OpenLibrarySource`.

- [ ] **Step 3: Implement**

Create `web-app/app/lib/data_importers/books/author/open_library_source.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # The authors finder's external source: the Open Library author record
      # for the query's own key (GET /authors/{key}; the service resolves
      # redirects). The service has no author name search, so a query without
      # a key contributes nothing.
      #
      # Fetching by the caller's own key is treated as an accept: the rules
      # still require a local holder's name to agree with the query before it
      # matches (FinderBase#corroborated?), and with no local holder, rule 5
      # hands the record to the provider through match.external.
      #
      # Not a `Sources` module on purpose: DataImporters::Sources is the
      # shared one and a nested module of the same name would shadow it.
      class OpenLibrarySource
        def initialize(query:, client: nil)
          @query = query
          @client = client
        end

        def name
          :open_library
        end

        # Raises whatever the client raises except a 404 (circuit open,
        # timeout, 5xx, parse): the finder records that as a failed source.
        def call
          key = @query.open_library_author_key
          return [] if key.blank?

          author = client.author(key)
          holders = local_holders(([author.key, key] + Array(author.redirected_from)).compact_blank.uniq)
          return [build(author, plain_evidence(author))] if holders.empty?

          holders.map { |holder| build(author, external_evidence(author), record: holder) }
        rescue ::Books::OpenLibrary::Exceptions::NotFoundError
          []
        end

        # Lazy: building the default client constructs a CircuitBreaker
        # against REDIS_POOL, and a test that injects its own must never
        # trigger that.
        def client
          @client ||= ::Books::OpenLibrary::Client.new
        end

        private

        def plain_evidence(author)
          {
            external_verdict: "accept", title: author.name, year: author.birth_year,
            alternate_names: author.alternate_names, birth_year: author.birth_year, death_year: author.death_year
          }
        end

        # Holder candidates carry the Open Library values under external_
        # keys: FinderBase merges the local record's own evidence underneath,
        # and a plain key here would overwrite the local value.
        def external_evidence(author)
          {
            external_verdict: "accept", external_title: author.name, external_year: author.birth_year,
            external_alternate_names: author.alternate_names, external_birth_year: author.birth_year,
            external_death_year: author.death_year
          }
        end

        def build(author, evidence, record: nil)
          Candidate.new(
            record: record,
            external_key: author.key,
            external_source: :open_library,
            external_record: author,
            sources: [:open_library],
            evidence: evidence
          )
        end

        def local_holders(keys)
          ::Books::Author
            .joins(:identifiers)
            .where(identifiers: {identifier_type: ::Identifier.identifier_types[:books_author_openlibrary_id], value: keys})
            .distinct
            .order(:id)
            .to_a
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/open_library_source_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/data_importers/books/author/open_library_source.rb web-app/test/lib/data_importers/books/author/open_library_source_test.rb
git commit -m "Authors finder: Open Library author source by key

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `DataImporters::Books::Author::Finder` and its registry entry

**Files:**
- Create: `web-app/app/lib/data_importers/books/author/finder.rb`
- Modify: `web-app/app/lib/data_importers/finder_registry.rb`
- Test: `web-app/test/lib/data_importers/books/author/finder_test.rb`
- Test: `web-app/test/lib/data_importers/finder_registry_test.rb`

**Interfaces:**
- Consumes: Task 2's `AuthorByName.call(name:, alternate_names:, size:)`, Task 3's `ImportQuery`, and Task 4's `OpenLibrarySource`.
- Produces: `DataImporters::Books::Author::Finder.new(open_library_client: nil)` and `#call(query:, verify: false, subject: nil, exclude: nil)`, which returns a `DataImporters::Match`. It records a `MatchDecision` with `finder: "DataImporters::Books::Author::Finder"`. `#exact_match?(query, candidate)` adds a death-year conflict check. `#describe_query` and `#describe_candidate` print life spans, alternate names and book titles. `#summarize(record)` includes `book_titles:`.
- Produces: a `FinderRegistry` entry for `Books::Author` (merge `MergeAuthor` / `source_author_id`, `recheck: true`).

- [ ] **Step 1: Write the failing finder test**

Create `web-app/test/lib/data_importers/books/author/finder_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class FinderTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"
        SEARCH = ::Search::Books::Search::AuthorByName
        TASK = ::Services::Ai::Tasks::Matching::SelectCandidateTask

        def setup
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:author_finder:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @finder = Finder.new(open_library_client: client)
          @tolstoy = books_authors(:tolstoy)
          @task = stub("select_candidate_task")
          SEARCH.stubs(:call).returns([])
        end

        # ---- helpers ----------------------------------------------------------

        def hit(author, score = 9.0)
          {id: author.id.to_s, score: score, source: {}}
        end

        def stub_ai(data)
          TASK.stubs(:new).returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: data, ai_chat: ai_chats(:general_chat)))
        end

        def expect_no_ai
          TASK.expects(:new).never
        end

        def stub_author(key, record_key: key, redirected_from: [], name: "Leo Tolstoy", status: 200)
          body = {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "key" => {"source" => "openlibrary", "key" => record_key},
              "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} },
              "name" => name, "alternate_names" => [], "birth_year" => 1828, "death_year" => 1910
            }
          }
          stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
        end

        # ---- identifiers (rule 1) ---------------------------------------------

        test "a held Open Library key whose name agrees is a certain identifier match and stops gathering" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")
          SEARCH.expects(:call).never
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"))

          assert_equal [@tolstoy, :certain, :identifier], [match.record, match.confidence, match.decided_by]
          assert_not_requested(:get, %r{#{BASE_URL}/authors/})
        end

        test "a key-only query is corroborated by definition" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")

          assert_equal @tolstoy, @finder.call(query: ImportQuery.new(open_library_author_key: "OL26783A")).record
        end

        test "a held key on an author with a different name is not decisive: the AI decides" do
          king = books_authors(:king)
          king.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")
          stub_author("OL26783A")
          TASK.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 2, confidence: "medium", reasoning: "Name and dates fit Tolstoy.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"))

          assert_equal [:ai, :medium], [match.decided_by, match.confidence]
          assert match.needs_review?
        end

        # ---- exact (rule 4) ---------------------------------------------------

        test "an exact name match, case-insensitively, is a high-confidence rule match" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "LEO TOLSTOY"))

          assert_equal [@tolstoy, :high, :rule], [match.record, match.confidence, match.decided_by]
          assert_includes match.candidates.first.sources, :exact
        end

        test "a query name equal to a stored alternate name is an exact match" do
          expect_no_ai

          assert_equal [@tolstoy, :rule], @finder.call(query: ImportQuery.new(name: "Lev Tolstoy")).then { |m| [m.record, m.decided_by] }
        end

        test "curly quotes, exotic spaces and case are normalized the way the model stores names" do
          author = ::Books::Author.create!(name: "Flann O'Brien")
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "FLANN O’BRIEN"))

          assert_equal [author, :rule], [match.record, match.decided_by]
        end

        test "a birth-year conflict blocks the exact rule: the AI decides" do
          stub_ai(selected_index: 0, confidence: "high", reasoning: "Different century.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", birth_year: 1950))

          assert_equal [nil, :unmatched, :ai], [match.record, match.outcome, match.decided_by]
        end

        test "a death-year conflict blocks the exact rule too" do
          stub_ai(selected_index: 0, confidence: "high", reasoning: "Different person.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", death_year: 1990))

          assert_equal [:unmatched, :ai], [match.outcome, match.decided_by]
        end

        test "two authors with the same exact name go to the AI" do
          twin = ::Books::Author.create!(name: "Leo Tolstoy")
          TASK.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "medium", reasoning: "Same person twice.", same_entity_groups: [[1, 2]]}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy"))

          assert_includes [@tolstoy, twin], match.record
          assert DuplicateCandidate.exists?(item_type: "Books::Author", item_a_id: [@tolstoy.id, twin.id].min, item_b_id: [@tolstoy.id, twin.id].max)
        end

        test "a surname-only OpenSearch neighbour never matches by rule" do
          SEARCH.stubs(:call).returns([hit(@tolstoy)])
          stub_ai(selected_index: 0, confidence: "high", reasoning: "A different Tolstoy.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Aleksey Tolstoy"))

          assert_equal [nil, :ai], [match.record, match.decided_by]
        end

        # ---- no candidates (rule 3) -------------------------------------------

        test "no candidates is unmatched by rule without the AI" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Nobody Anybody"))

          assert_equal [nil, :unmatched, :high, :rule], [match.record, match.outcome, match.confidence, match.decided_by]
        end

        # ---- Open Library -----------------------------------------------------

        test "an unheld key is unmatched with the Open Library record on match.external (rule 5)" do
          stub_author("OL99A", name: "Nobody Anybody")
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Nobody Anybody", open_library_author_key: "OL99A"))

          assert_equal [:unmatched, :rule], [match.outcome, match.decided_by]
          assert_equal "OL99A", match.external.external_key
          assert_instance_of ::Books::OpenLibrary::Author, match.external.external_record
        end

        test "a local author holding a key the service redirects from matches (rule 2)" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL1A")
          stub_author("OL2A", redirected_from: ["OL1A"])
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL2A"))

          assert_equal [@tolstoy, :certain, :identifier], [match.record, match.confidence, match.decided_by]
        end

        test "an Open Library 404 is not a failed source" do
          stub_author("OL404A", status: 404)

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL404A"))

          assert_equal [@tolstoy, :high], [match.record, match.confidence]
          assert_empty match.sources_failed
        end

        test "an Open Library outage is a failed source and demotes a high rule match to medium" do
          stub_author("OL500A", status: 500)

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL500A"))

          assert_equal [@tolstoy, :medium], [match.record, match.confidence]
          assert_equal ["open_library"], match.sources_failed
        end

        test "an OpenSearch outage is a failed source; the exact source still decides" do
          SEARCH.stubs(:call).raises(Faraday::ConnectionFailed.new("down"))

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy"))

          assert_equal [@tolstoy, :rule], [match.record, match.decided_by]
          assert_equal ["opensearch"], match.sources_failed
        end

        # ---- the AI prompt and the audit summary ------------------------------

        test "the AI sees life spans, other names and book titles on both sides" do
          ::Books::Author.create!(name: "Leo Tolstoy")
          TASK.expects(:new).with { |args|
            args[:entity_noun] == "author" &&
              args[:query_line].include?("1828-1910") && args[:query_line].include?("wrote War and Peace") &&
              args[:candidate_lines].any? { |line| line.include?("wrote War and Peace") && line.include?("also known as Lev Tolstoy") }
          }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "high", reasoning: "Same dates.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", birth_year: 1828, death_year: 1910, work_titles: ["War and Peace"]))
        end

        test "summarize includes the author's book titles and years" do
          summary = @finder.summarize(@tolstoy)

          assert_includes summary[:book_titles], books_books(:war_and_peace).title
          assert_equal [1828, 1910, "Leo Tolstoy"], summary.values_at(:birth_year, :death_year, :title)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/finder_test.rb`
Expected: FAIL with `uninitialized constant DataImporters::Books::Author::Finder`.

- [ ] **Step 3: Implement the finder**

Create `web-app/app/lib/data_importers/books/author/finder.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # Finds an existing ::Books::Author before import and answers with a
      # Match (see FinderBase). Four sources, in order: the query's Open
      # Library author key, an exact normalized name-or-alternate-name
      # lookup, the OpenSearch AuthorByName query, and the Open Library
      # author record for the key.
      #
      # Rule 4 for authors is an equal normalized name (or alternate name)
      # with no birth- or death-year conflict. Two different people with the
      # same exact name and no dates on either side are therefore matched:
      # the accepted trade-off against a new author row on every re-import
      # (import-finder redesign §9).
      class Finder < DataImporters::FinderBase
        OPENSEARCH_SIZE = 5
        EXACT_LIMIT = 5
        EVIDENCE_BOOK_TITLES = 5

        # open_library_client: injected by tests; nil builds the real client
        # lazily inside OpenLibrarySource.
        def initialize(open_library_client: nil)
          @open_library_client = open_library_client
        end

        def exact_match?(query, candidate)
          super && !year_conflict?(query.death_year, candidate.record.death_year)
        end

        def describe_query(query)
          parts = [query.name.presence || query.open_library_author_key]
          span = life_span(query.birth_year, query.death_year)
          parts << span if span
          parts << "also known as #{query.alternate_names.join(", ")}" if query.alternate_names.any?
          parts << "wrote #{query.work_titles.first(EVIDENCE_BOOK_TITLES).join("; ")}" if query.work_titles.any?
          parts.join(" | ")
        end

        def describe_candidate(candidate)
          evidence = candidate.evidence
          parts = [evidence[:title].presence || evidence[:external_title].presence || candidate.external_key.to_s]
          span = life_span(evidence[:birth_year], evidence[:death_year])
          parts << span if span
          alternates = Array(evidence[:alternate_names]).first(5)
          parts << "also known as #{alternates.join(", ")}" if alternates.any?
          titles = Array(evidence[:book_titles])
          parts << "wrote #{titles.join("; ")}" if titles.any?
          parts << evidence[:kind].to_s if evidence[:kind].present? && evidence[:kind].to_s != "person"
          parts << "ranked ##{evidence[:ranked_position]}" if evidence[:ranked_position].present?
          parts << "in catalog" if candidate.local?
          parts << "#{candidate.external_source} #{candidate.external_key}" if candidate.external?
          parts << "shares #{evidence.dig(:matched_identifier, :type)}" if evidence[:matched_identifier]
          parts.join(" | ")
        end

        protected

        def model_class = ::Books::Author

        def ranking_configuration_class = ::Books::Authors::RankingConfiguration

        def candidate_sources(query)
          [
            DataImporters::Sources::Identifiers.new(model_class: ::Books::Author, lookups: identifier_lookups(query)),
            DataImporters::Sources::Exact.new(scope: exact_scope(query), limit: EXACT_LIMIT),
            DataImporters::Sources::OpenSearch.new(
              model_class: ::Books::Author,
              search_class: ::Search::Books::Search::AuthorByName,
              params: search_params(query),
              size: OPENSEARCH_SIZE,
              includes: [:identifiers]
            ),
            OpenLibrarySource.new(query: query, client: @open_library_client)
          ]
        end

        def domain_guidance
          "Two people with the same name are different authors unless their dates or their books connect them; a shared name alone is not enough. " \
            "A transliteration, a spelling variant, initials or a fuller form of the same person's name is the same author. " \
            "A pen name is a separate author from the person who used it."
        end

        def query_year(query) = query.birth_year

        def record_year(record) = record.birth_year

        def record_extra_evidence(record)
          {
            alternate_names: Array(record.alternate_names),
            birth_year: record.birth_year,
            death_year: record.death_year,
            kind: record.kind,
            book_titles: record.books.order(:id).limit(EVIDENCE_BOOK_TITLES).pluck(:title)
          }
        end

        private

        def identifier_lookups(query)
          return [] if query.open_library_author_key.blank?

          [[:books_author_openlibrary_id, query.open_library_author_key]]
        end

        # The query's name and alternate names against every stored name and
        # alternate name. Measured on the 71k development authors
        # (2026-09-27): the name half uses the lower(name) index (1 ms); the
        # alternate-name half scans (50 ms). Accepted: the finder mostly runs
        # inside slow list imports. Ids are plucked first, as in the books
        # finder, so no ORDER BY + LIMIT steers the planner.
        def exact_scope(query)
          names = ([query.name] + query.alternate_names).map { |name| normalize(name) }.compact_blank.uniq
          return ::Books::Author.none if names.empty?

          ids = ::Books::Author.where(
            "LOWER(books_authors.name) IN (:names) OR EXISTS (SELECT 1 FROM unnest(books_authors.alternate_names) AS alternate WHERE LOWER(alternate) IN (:names))",
            names: names
          ).pluck(:id).sort.first(EXACT_LIMIT)
          ::Books::Author.where(id: ids).includes(:identifiers).order(:id)
        end

        def search_params(query)
          return nil if query.name.blank?

          {name: query.name, alternate_names: query.alternate_names}
        end

        def life_span(birth_year, death_year)
          return nil if birth_year.blank? && death_year.blank?

          "#{birth_year || "?"}-#{death_year}"
        end
      end
    end
  end
end
```

Note: `year_conflict?` and `normalize` are private in `FinderBase`. A subclass instance can call them without a receiver.

- [ ] **Step 4: Run the finder test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/finder_test.rb`
Expected: PASS.

If "an OpenSearch outage is a failed source" raises a different error class than `Faraday::ConnectionFailed` from the stub, keep the stub. The finder rescues any non-ActiveRecord error, so the failure is somewhere else and needs reading, not a changed test.

- [ ] **Step 5: Write the failing registry test changes**

In `web-app/test/lib/data_importers/finder_registry_test.rb`:
- In "a mergeable entry names…", add `"Books::Author" => books_authors(:tolstoy),` to `records`, and change the expected list to `%w[Books::Author Books::Book Games::Game Music::Album Music::Artist Music::Song]`.
- In "for_domain groups entries by admin domain", change the two books lines to:

```ruby
      assert_equal %w[Books::Author Books::Book], FinderRegistry.models_for(:books).sort
      assert_equal %w[DataImporters::Books::Author::Finder DataImporters::Books::Book::Finder], FinderRegistry.finders_for(:books).sort
```

- Replace the "only the books finder offers re-check" test with:

```ruby
    test "only the books and authors finders offer re-check" do
      assert_equal %w[DataImporters::Books::Author::Finder DataImporters::Books::Book::Finder],
        FinderRegistry::ENTRIES.select(&:recheck?).map(&:finder).sort
    end
```

(Keep any remaining lines of the original test body that are not about the recheck list. Read the full original test before replacing it.)

- [ ] **Step 6: Run the registry test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/finder_registry_test.rb`
Expected: FAIL. "every finder class … has exactly one entry" now finds the new `finder.rb` without an entry.

- [ ] **Step 7: Add the registry entry**

In `web-app/app/lib/data_importers/finder_registry.rb`, add after the `Books::Book` entry:

```ruby
      Entry.new(
        finder: "DataImporters::Books::Author::Finder", domain: :books, model: "Books::Author", label: "Author",
        query: "DataImporters::Books::Author::ImportQuery", preloads: [],
        merge_action: "MergeAuthor", source_field: "source_author_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_books_author_path(record) },
        recheck: true
      ),
```

- [ ] **Step 8: Run the registry, finder and audit-page tests**

Run: `cd web-app && bin/rails test test/lib/data_importers/ test/controllers/admin/`
Expected: PASS. If an admin controller test hard-codes the books registry contents, update its expectation to include the authors entry and say so in the commit message.

- [ ] **Step 9: Commit**

```bash
git add web-app/app/lib/data_importers/books/author/finder.rb web-app/app/lib/data_importers/finder_registry.rb web-app/test/lib/data_importers/books/author/finder_test.rb web-app/test/lib/data_importers/finder_registry_test.rb
git commit -m "Authors finder: identifiers, exact name, AuthorByName, Open Library; registry entry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The author Open Library provider and `DataImporters::Books::Author::Importer`

**Files:**
- Create: `web-app/app/lib/data_importers/books/author/providers/open_library.rb`
- Create: `web-app/app/lib/data_importers/books/author/importer.rb`
- Test: `web-app/test/lib/data_importers/books/author/providers/open_library_test.rb`
- Test: `web-app/test/lib/data_importers/books/author/importer_test.rb`

**Interfaces:**
- Consumes: Task 1 (`save_before_providers?`, `created?`) and Task 5 (`Finder`). From Task 4, `match.external.external_record` is a `Books::OpenLibrary::Author` when `match.external.external_source == :open_library`.
- Produces: `DataImporters::Books::Author::Importer.call(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [], item: nil, force_providers: false, providers: nil, subject: nil, verify: false)`, which returns an `ImportResult`. `result.item` is a persisted `::Books::Author` whenever the query had a usable name or Open Library supplied one. `result.created?` is true when the import made the author.
- Produces: `DataImporters::Books::Author::Providers::OpenLibrary.new(client: nil)` and `#populate(author, query:, match: nil)`, which returns a `ProviderResult`. Its `data_populated` is a subset of `%w[name birth_year death_year alternate_names]`. It always stamps `books_author_openlibrary_id`, set to the record's canonical key.

- [ ] **Step 1: Write the failing provider test**

Create `web-app/test/lib/data_importers/books/author/providers/open_library_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      module Providers
        class OpenLibraryTest < ActiveSupport::TestCase
          BASE_URL = "http://open-library.test:8080"

          def setup
            @client = ::Books::OpenLibrary::Client.new(
              config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
              breaker: ::Books::OpenLibrary::CircuitBreaker.new(
                key: "test:author_provider:open_library", failure_threshold: 5, cooldown: 60,
                redis: ::Books::OpenLibrary::FakeRedis.new
              )
            )
            @provider = Providers::OpenLibrary.new(client: @client)
          end

          def ol_author(key: "OL26783A", name: "Leo Tolstoy", alternate_names: ["Lev Nikolayevich Tolstoy", "Leo Tolstoï"], birth_year: 1828, death_year: 1910)
            ::Books::OpenLibrary::Author.new(key: key, source: "openlibrary", name: name, alternate_names: alternate_names,
              birth_year: birth_year, death_year: death_year, redirected_from: [], source_version: nil)
          end

          def stub_author(key, status: 200)
            body = {"source_version" => nil, "data" => {"key" => {"source" => "openlibrary", "key" => key}, "redirected_from" => [],
                                                        "name" => "Leo Tolstoy", "alternate_names" => [], "birth_year" => 1828, "death_year" => 1910}}
            stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
          end

          def match_with(record)
            DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule,
              external: DataImporters::Candidate.new(external_key: record.key, external_source: :open_library, external_record: record))
          end

          test "fills blank years, unions alternate names and stamps the key, reusing match.external without a request" do
            author = ::Books::Author.new(name: "Lev Tolstoy")

            result = @provider.populate(author, query: ImportQuery.new(name: "Lev Tolstoy", open_library_author_key: "OL26783A"), match: match_with(ol_author))

            assert result.success?
            assert_equal %w[birth_year death_year alternate_names], result.data_populated
            assert_equal [1828, 1910], [author.birth_year, author.death_year]
            assert_equal ["Leo Tolstoy", "Lev Nikolayevich Tolstoy", "Leo Tolstoï"], author.alternate_names
            assert_equal ["OL26783A"], author.identifiers.select { |i| i.identifier_type == "books_author_openlibrary_id" }.map(&:value)
            assert_not_requested(:get, %r{#{BASE_URL}/authors/})
          end

          test "never overwrites a populated name or year, and skips alternate names it already holds" do
            author = books_authors(:tolstoy)
            author.update!(birth_year: 1827)

            result = @provider.populate(author, query: ImportQuery.new(name: "Leo Tolstoy"), match: match_with(ol_author(alternate_names: ["LEV TOLSTOY"])))

            assert_equal [], result.data_populated
            assert_equal ["Leo Tolstoy", 1827, 1910], [author.name, author.birth_year, author.death_year]
          end

          test "writes the name only when it is blank (a key-only import)" do
            author = ::Books::Author.new

            result = @provider.populate(author, query: ImportQuery.new(open_library_author_key: "OL26783A"), match: match_with(ol_author))

            assert_equal "Leo Tolstoy", author.name
            assert_includes result.data_populated, "name"
          end

          test "fetches by the query key when the match carries no Open Library record" do
            stub_author("OL26783A")
            author = ::Books::Author.new(name: "Leo Tolstoy")

            assert @provider.populate(author, query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"), match: nil).success?
            assert_requested(:get, "#{BASE_URL}/authors/OL26783A", times: 1)
          end

          test "an item-based run fetches by the author's held key" do
            author = books_authors(:tolstoy)
            author.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")
            stub_author("OL26783A")

            assert @provider.populate(author, query: nil, match: nil).success?
            assert_requested(:get, "#{BASE_URL}/authors/OL26783A", times: 1)
          end

          test "an author with no key has nothing to look up: success with nothing populated and no request" do
            result = @provider.populate(::Books::Author.new(name: "Nobody Anybody"), query: ImportQuery.new(name: "Nobody Anybody"), match: nil)

            assert result.success?
            assert_equal [], result.data_populated
            assert_not_requested(:get, %r{#{BASE_URL}/authors/})
          end

          test "a service error is a failure result, never an exception" do
            stub_author("OL26783A", status: 500)

            result = @provider.populate(::Books::Author.new(name: "Leo Tolstoy"), query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"), match: nil)

            assert_not result.success?
            assert_match(/Open Library ServerError/, result.errors.first)
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the provider test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/providers/open_library_test.rb`
Expected: FAIL with `uninitialized constant DataImporters::Books::Author::Providers`.

- [ ] **Step 3: Implement the provider**

Create `web-app/app/lib/data_importers/books/author/providers/open_library.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      module Providers
        # Fills a ::Books::Author from its Open Library author record: blank
        # birth_year and death_year, alternate_names unioned (Open Library's
        # own name included when it differs), and the canonical key stamped as
        # books_author_openlibrary_id. `name` is written only when blank (a
        # key-only import); a populated name is never touched.
        #
        # The record comes from the finder's match when it already fetched one
        # (rule 5, or the AI choosing the Open Library candidate), else from
        # the query's key, else from the author's held key. An author with no
        # key has nothing to look up: success with nothing populated.
        class OpenLibrary < DataImporters::ProviderBase
          FILLABLE_YEARS = %w[birth_year death_year].freeze

          def initialize(client: nil)
            @client = client
          end

          # Lazy: building the default client constructs a CircuitBreaker
          # against REDIS_POOL, and a test that injects its own client should
          # never trigger that.
          def client
            @client ||= ::Books::OpenLibrary::Client.new
          end

          def populate(author, query:, match: nil)
            record = reusable_record(match) || fetch(author, query)
            return success_result(data_populated: []) if record.nil?

            success_result(data_populated: apply(author, record))
          rescue => e
            failure_result(errors: ["Open Library #{e.class.name.demodulize}: #{e.message}"])
          end

          private

          def reusable_record(match)
            external = match&.external
            return nil unless external&.external_source == :open_library

            external.external_record
          end

          def fetch(author, query)
            key = query&.open_library_author_key || held_key(author)
            return nil if key.blank?

            client.author(key)
          end

          def held_key(author)
            author.identifiers.find { |identifier| identifier.identifier_type == "books_author_openlibrary_id" }&.value
          end

          def apply(author, record)
            populated = []

            if author.name.blank? && record.name.present?
              author.name = record.name
              populated << "name"
            end

            FILLABLE_YEARS.each do |field|
              value = record.public_send(field)
              next if value.nil? || author[field].present?

              author[field] = value
              populated << field
            end

            added = new_alternate_names(author, record)
            if added.any?
              author.alternate_names = Array(author.alternate_names) + added
              populated << "alternate_names"
            end

            author.identifiers.find_or_initialize_by(identifier_type: :books_author_openlibrary_id, value: record.key)
            populated
          end

          def new_alternate_names(author, record)
            held = ([author.name] + Array(author.alternate_names)).map { |name| normalize(name) }
            ([record.name] + Array(record.alternate_names))
              .map(&:to_s).compact_blank
              .reject { |name| held.include?(normalize(name)) }
              .uniq { |name| normalize(name) }
          end

          def normalize(text)
            ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the provider test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/providers/open_library_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing importer test**

Create `web-app/test/lib/data_importers/books/author/importer_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class ImporterTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:author_importer:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          ::Books::OpenLibrary::Client.stubs(:new).returns(client)
        end

        def stub_author(key, name: "Anna Brenner", status: 200)
          body = {"source_version" => nil, "data" => {"key" => {"source" => "openlibrary", "key" => key}, "redirected_from" => [],
                                                      "name" => name, "alternate_names" => ["A. Brenner"], "birth_year" => 1901, "death_year" => 1970}}
          stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
        end

        test "an exact name match returns the existing author without running a provider" do
          Providers::OpenLibrary.any_instance.expects(:populate).never

          result = Importer.call(name: "Leo Tolstoy")

          assert_equal books_authors(:tolstoy), result.item
          assert_not result.created?
          assert result.match.matched?
        end

        test "a name-only import creates and persists the author with no Open Library request" do
          result = Importer.call(name: "Anna Brenner", work_titles: ["The Quiet Year"])

          assert result.item.persisted?
          assert result.created?
          assert_equal "Anna Brenner", result.item.name
          assert_equal result.item, result.match.decision.reload.record
          assert_not_requested(:get, %r{#{BASE_URL}/authors/})
        end

        test "a keyed import makes one Open Library request: the provider reuses the finder's record" do
          stub_author("OL77A")

          result = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A")

          author = result.item.reload
          assert_equal [1901, 1970, ["A. Brenner"]], [author.birth_year, author.death_year, author.alternate_names]
          assert author.identifiers.exists?(identifier_type: :books_author_openlibrary_id, value: "OL77A")
          assert_requested(:get, "#{BASE_URL}/authors/OL77A", times: 1)
        end

        test "a key-only import takes the name from Open Library" do
          stub_author("OL77A")

          result = Importer.call(open_library_author_key: "OL77A")

          assert result.item.persisted?
          assert_equal "Anna Brenner", result.item.name
        end

        test "an Open Library outage still creates the author from the name" do
          stub_author("OL77A", status: 500)

          result = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A")

          assert result.item.persisted?
          assert result.created?
          assert_not result.success?
        end

        test "re-importing by name or by key is idempotent" do
          stub_author("OL77A")
          first = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A").item

          by_name = Importer.call(name: "Anna Brenner")
          by_key = Importer.call(open_library_author_key: "OL77A")

          assert_equal [first, first], [by_name.item, by_key.item]
          assert_equal 1, ::Books::Author.where(name: "Anna Brenner").count
        end

        test "the query's alternate names seed a new author, without its own name" do
          result = Importer.call(name: "Anna Brenner", alternate_names: ["Anna Brenner", "Anya Brenner"])

          assert_equal ["Anya Brenner"], result.item.alternate_names
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the importer test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/importer_test.rb`
Expected: FAIL with `uninitialized constant DataImporters::Books::Author::Importer`.

- [ ] **Step 7: Implement the importer**

Create `web-app/app/lib/data_importers/books/author/importer.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # Main importer for single ::Books::Author records. The book importer's
      # author step is the first caller.
      class Importer < DataImporters::ImporterBase
        def self.call(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [],
          item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
          if item.present?
            super(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              name: name,
              open_library_author_key: open_library_author_key,
              birth_year: birth_year,
              death_year: death_year,
              alternate_names: alternate_names,
              work_titles: work_titles
            )
            super(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [Providers::OpenLibrary.new]
        end

        # A name alone is a complete author: keep it even when Open Library is
        # unreachable (the service is not deployed to production), so the book
        # importer's author step always gets a record to link.
        def save_before_providers? = true

        def initialize_item(query)
          ::Books::Author.new(
            name: query.name,
            birth_year: query.birth_year,
            death_year: query.death_year,
            alternate_names: query.alternate_names.reject { |alternate| alternate == query.name }
          )
        end
      end
    end
  end
end
```

- [ ] **Step 8: Run both tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/author/`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add web-app/app/lib/data_importers/books/author/providers/open_library.rb web-app/app/lib/data_importers/books/author/importer.rb web-app/test/lib/data_importers/books/author/providers/open_library_test.rb web-app/test/lib/data_importers/books/author/importer_test.rb
git commit -m "Authors importer and its Open Library provider

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The book importer's author step

Two parts:

1. **Accept path.** On an Open Library accept, `DataImporters::Books::Book::Providers::OpenLibrary` links the accepted work's authors, in Open Library's order, through the author importer (key and name).
2. **Name path.** A new book provider, `Providers::Authors`, runs next. Whenever the book still has no authors, it imports the query's `author_names` by name. So the book gets its authors on an abstain, a reject, or an unreachable service, which is every import in production today.

A book that already has authors is left alone by both.

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/providers/open_library.rb`
- Create: `web-app/app/lib/data_importers/books/book/providers/authors.rb`
- Modify: `web-app/app/lib/data_importers/books/book/importer.rb`
- Test: `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb`
- Test: `web-app/test/lib/data_importers/books/book/providers/authors_test.rb`
- Test: `web-app/test/lib/data_importers/books/book/importer_test.rb`

**Interfaces:**
- Consumes: Task 6's `::DataImporters::Books::Author::Importer.call(name:, open_library_author_key:, work_titles:)`, which returns an `ImportResult` with `.item`. From the Open Library client, `resolution.accepted.record` is a `Books::OpenLibrary::Work` (or nil) carrying `author_keys` and `author_names`.
- Produces: `DataImporters::Books::Book::Providers::Authors#populate(book, query:, match: nil)`. On linking it returns success with `data_populated: [:authors]`. If the book already has authors it returns success with `[]`. It fails when there are no names, or when no name could be imported. The Open Library provider's `data_populated` gains `"authors"` when it linked any. `Book::Importer#providers` becomes `[Providers::OpenLibrary, Providers::Authors, Providers::AiEnrichment]`.

- [ ] **Step 1: Write the failing `Providers::Authors` test**

Create `web-app/test/lib/data_importers/books/book/providers/authors_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AuthorsTest < ActiveSupport::TestCase
          IMPORTER = ::DataImporters::Books::Author::Importer

          def setup
            @provider = Providers::Authors.new
            @tolstoy = books_authors(:tolstoy)
            @king = books_authors(:king)
          end

          def result_for(author)
            DataImporters::ImportResult.new(item: author, provider_results: [], success: true)
          end

          def query(names)
            DataImporters::Books::Book::ImportQuery.new(title: "Hadji Murat", author_names: names)
          end

          test "imports each query name by name and links the authors in the query's order" do
            book = ::Books::Book.new(title: "Hadji Murat")
            IMPORTER.expects(:call).with(name: "Stephen King", work_titles: ["Hadji Murat"]).returns(result_for(@king))
            IMPORTER.expects(:call).with(name: "Leo Tolstoy", work_titles: ["Hadji Murat"]).returns(result_for(@tolstoy))

            result = @provider.populate(book, query: query(["Stephen King", "Leo Tolstoy"]))

            assert result.success?
            assert_equal [:authors], result.data_populated
            assert_equal [[@king, 1], [@tolstoy, 2]], book.book_authors.map { |link| [link.author, link.position] }
          end

          test "two names resolving to the same author make one link" do
            book = ::Books::Book.new(title: "Hadji Murat")
            IMPORTER.stubs(:call).returns(result_for(@tolstoy))

            @provider.populate(book, query: query(["Leo Tolstoy", "Lev Tolstoy"]))

            assert_equal [@tolstoy], book.book_authors.map(&:author)
          end

          test "a book that already has authors is left alone" do
            book = books_books(:war_and_peace)
            IMPORTER.expects(:call).never

            result = @provider.populate(book, query: query(["Stephen King"]))

            assert result.success?
            assert_equal [], result.data_populated
          end

          test "no names is a failure" do
            IMPORTER.expects(:call).never

            assert_not @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: query([])).success?
            assert_not @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: nil).success?
          end

          test "an author the importer could not persist is skipped; none at all is a failure" do
            IMPORTER.stubs(:call).returns(result_for(::Books::Author.new))

            result = @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: query(["???"]))

            assert_not result.success?
          end

          test "an error inside the author importer is a failure result" do
            IMPORTER.stubs(:call).raises(StandardError, "boom")

            result = @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: query(["Leo Tolstoy"]))

            assert_not result.success?
            assert_match(/boom/, result.errors.first)
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/providers/authors_test.rb`
Expected: FAIL with `uninitialized constant DataImporters::Books::Book::Providers::Authors`.

- [ ] **Step 3: Implement `Providers::Authors`**

Create `web-app/app/lib/data_importers/books/book/providers/authors.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # The book's author step when Open Library gave it no authors: each of
        # the query's author names goes through the author importer by name,
        # linked in the query's order. Runs after Providers::OpenLibrary, so
        # it also covers an abstain, a reject and an unreachable service (the
        # service is not deployed to production). A book that already has
        # authors -- from Open Library just now, or from before -- is left
        # alone, the same ruling as the merger.
        class Authors < DataImporters::ProviderBase
          def populate(book, query:, match: nil)
            return success_result(data_populated: []) if book.book_authors.any?

            names = Array(query&.author_names).map(&:to_s).compact_blank
            return failure_result(errors: ["No author names to import"]) if names.empty?

            linked = 0
            names.each_with_index do |name, index|
              author = ::DataImporters::Books::Author::Importer.call(name: name, work_titles: [book.title].compact_blank).item
              next unless author&.persisted?

              link(book, author, index + 1)
              linked += 1
            end

            return failure_result(errors: ["No author could be imported"]) if linked.zero?

            success_result(data_populated: [:authors])
          rescue => e
            failure_result(errors: ["Author step error: #{e.message}"])
          end

          private

          # Two names can resolve to one author ("Leo Tolstoy", "Lev Tolstoy");
          # book_authors is unique per (book, author).
          def link(book, author, position)
            return if book.book_authors.any? { |existing| existing.author_id == author.id }

            book.book_authors.build(author: author, position: position)
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/providers/authors_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing Open Library provider tests**

In `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb`:
- Add a `record:` parameter (default `nil`) to the `candidate_hash` helper and put it in `"record" => record`.
- Add a `record: nil` parameter to `resolve_response` and pass it through to `candidate_hash`.
- Add this helper and these tests:

```ruby
          def work_with_authors(authors)
            {
              "key" => {"source" => "openlibrary", "key" => "OL468431W"}, "redirected_from" => [], "title" => "Hadji Murat",
              "subtitle" => nil, "description" => nil, "subjects" => [], "year_evidence" => nil, "popularity" => nil,
              "authors" => authors.map { |key, name| {"key" => {"source" => "openlibrary", "key" => key}, "name" => name} }
            }
          end

          def author_result(author)
            DataImporters::ImportResult.new(item: author, provider_results: [], success: true)
          end

          test "an accept links the work's authors through the author importer, by key and name, in Open Library's order" do
            book = ::Books::Book.new(title: "Hadji Murat")
            stub_resolve(resolve_response(verdict: "accept", record: work_with_authors([["OL2A", "Stephen King"], ["OL1A", "Leo Tolstoy"]])))
            ::DataImporters::Books::Author::Importer.expects(:call)
              .with(name: "Stephen King", open_library_author_key: "OL2A", work_titles: ["Hadji Murat"]).returns(author_result(books_authors(:king)))
            ::DataImporters::Books::Author::Importer.expects(:call)
              .with(name: "Leo Tolstoy", open_library_author_key: "OL1A", work_titles: ["Hadji Murat"]).returns(author_result(books_authors(:tolstoy)))

            result = @provider.populate(book, query: nil)

            assert_includes result.data_populated, "authors"
            assert_equal [[books_authors(:king), 1], [books_authors(:tolstoy), 2]], book.book_authors.map { |l| [l.author, l.position] }
          end

          test "a work author with a key but no name is imported by key" do
            book = ::Books::Book.new(title: "Hadji Murat")
            stub_resolve(resolve_response(verdict: "accept", record: work_with_authors([["OL1A", nil]])))
            ::DataImporters::Books::Author::Importer.expects(:call)
              .with(name: nil, open_library_author_key: "OL1A", work_titles: ["Hadji Murat"]).returns(author_result(books_authors(:tolstoy)))

            @provider.populate(book, query: nil)

            assert_equal [books_authors(:tolstoy)], book.book_authors.map(&:author)
          end

          test "an accept for a book that already has authors leaves them alone" do
            book = books_books(:war_and_peace)
            stub_resolve(resolve_response(verdict: "accept", record: work_with_authors([["OL2A", "Stephen King"]])))
            ::DataImporters::Books::Author::Importer.expects(:call).never

            result = @provider.populate(book, query: nil)

            assert_not_includes result.data_populated, "authors"
          end

          test "an accept whose candidate carries no work record links nothing and still succeeds" do
            ::DataImporters::Books::Author::Importer.expects(:call).never
            stub_resolve(resolve_response(verdict: "accept"))

            assert @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: nil).success?
          end
```

Before relying on `resolve_response(record:)`, read the existing helper. If its accept branch builds `candidate_hash(key: key, diff: diff)`, change that call to `candidate_hash(key: key, diff: diff, record: record)`.

- [ ] **Step 6: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/providers/open_library_test.rb`
Expected: the first two new tests FAIL (`expected exactly once, invoked never`). The last two may already pass.

- [ ] **Step 7: Implement the accept-path author step**

In `web-app/app/lib/data_importers/books/book/providers/open_library.rb`:

1. Update the class comment's closing lines. Replace "authors/subjects also appear in the diff, but creating authors or categories from them belongs to the reconciliation spec." (on `FILLABLE_FIELDS`) with:

```ruby
          # The Books::Book scalar columns the service's work-level diff covers.
          # Authors are not a diff fill: on accept, a book with no authors gets
          # the accepted work's authors through the author importer
          # (link_open_library_authors). Subjects stay the categories spec's.
```

2. In `apply_accept`, after `persist_query_identifiers(book, query)`, add:

```ruby
            data_populated << "authors" if link_open_library_authors(book, candidate)
```

3. Add this private method after `persist_query_identifiers`:

```ruby
          # Import-finder redesign §8: on accept, a book with no authors gets
          # the accepted work's authors, each through the author importer by
          # key and name, linked in Open Library's order. A book that already
          # has authors is left alone (the merger's ruling).
          def link_open_library_authors(book, candidate)
            return false if book.book_authors.any?

            work = candidate.record
            return false if work.nil? || work.author_keys.empty?

            linked = false
            work.author_keys.zip(work.author_names).each_with_index do |(key, name), index|
              author = ::DataImporters::Books::Author::Importer.call(
                name: name, open_library_author_key: key, work_titles: [book.title].compact_blank
              ).item
              next unless author&.persisted?
              next if book.book_authors.any? { |existing| existing.author_id == author.id }

              book.book_authors.build(author: author, position: index + 1)
              linked = true
            end
            linked
          end
```

- [ ] **Step 8: Run the provider tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/providers/`
Expected: PASS. Existing tests whose accept has `"record" => nil` are unaffected.

- [ ] **Step 9: Write the failing end-to-end importer tests**

In `web-app/test/lib/data_importers/books/book/importer_test.rb`, add to `setup`:

```ruby
          ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
```

and add these tests:

```ruby
        def stub_resolve_down
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "{}")
        end

        test "with Open Library unreachable, a title-and-author import creates the book and links an existing author" do
          stub_resolve_down

          result = Importer.call(title: "Hadji Murat", author_names: ["Leo Tolstoy"])

          book = result.item.reload
          assert book.persisted?
          assert_equal [books_authors(:tolstoy)], book.authors.to_a
        end

        test "with Open Library unreachable, a new author name becomes a new author" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"]).item.reload

          assert_equal ["Anna Brenner"], book.authors.map(&:name)
        end

        test "a title-and-author re-import is idempotent" do
          stub_resolve_down
          first = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"]).item

          second = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"])

          assert_equal first, second.item
          assert_equal 1, ::Books::Book.where(title: "The Quiet Year").count
          assert_equal 1, ::Books::Author.where(name: "Anna Brenner").count
        end

        test "an Open Library accept links the work's authors, creating one by its key" do
          stub_open_library_client
          record = work_record_hash(title: "The Quiet Year").merge(
            "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL77A"}, "name" => "Anna Brenner"}]
          )
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: [], record: record).to_json)
          stub_request(:get, "#{BASE_URL}/authors/OL77A").to_return(status: 200, body: {
            "source_version" => nil,
            "data" => {"key" => {"source" => "openlibrary", "key" => "OL77A"}, "redirected_from" => [], "name" => "Anna Brenner",
                       "alternate_names" => [], "birth_year" => 1901, "death_year" => nil}
          }.to_json)

          book = Importer.call(title: "The Quiet Year", author_names: ["A. Brenner"]).item.reload

          author = book.authors.sole
          assert_equal ["Anna Brenner", 1901], [author.name, author.birth_year]
          assert author.identifiers.exists?(identifier_type: :books_author_openlibrary_id, value: "OL77A")
        end

        test "a forced re-import of a book that has authors touches neither author step" do
          stub_resolve_down
          ::DataImporters::Books::Author::Importer.expects(:call).never

          Importer.call(item: books_books(:war_and_peace), force_providers: true)

          assert_equal [books_authors(:tolstoy)], books_books(:war_and_peace).reload.authors.to_a
        end
```

- [ ] **Step 10: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/importer_test.rb`
Expected: the new tests FAIL (the book has no authors, or is not persisted, because `Providers::Authors` is not in the importer yet).

- [ ] **Step 11: Wire the provider into the book importer**

In `web-app/app/lib/data_importers/books/book/importer.rb`, replace the `providers` method and its comment with:

```ruby
        # OpenLibrary first: its fills are free and licensed, and on accept it
        # links the work's authors. Authors next: the query's author names
        # when the book still has none (an abstain, a reject, or the service
        # unreachable). AiEnrichment last, so the AI fills fewer blanks.
        def providers
          @providers ||= [Providers::OpenLibrary.new, Providers::Authors.new, Providers::AiEnrichment.new]
        end
```

- [ ] **Step 12: Run the book importer tests**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/`
Expected: PASS. Existing importer tests that count provider results (2 before, 3 now) or expect a book with no `author_names` to succeed will need their expectations updated. `Providers::Authors` fails when there are no names, but `OpenLibrary` still succeeding keeps the book saved. Update only the count or expectation, never the behaviour under test, and list each changed test in the commit message.

- [ ] **Step 13: Commit**

```bash
git add web-app/app/lib/data_importers/books/book/ web-app/test/lib/data_importers/books/book/
git commit -m "Book importer: author step (Open Library accept by key, else query names)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Documentation, spec amendments, and verification

**Files:**
- Modify: `docs/features/data_importers.md`
- Modify: `docs/features/import-finder.md`
- Modify: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`

**Interfaces:** none (documentation and verification).

- [ ] **Step 1: Update `docs/features/data_importers.md`**

- In the "Supported Media Types" table, change the Books row's providers to `OpenLibrary, Authors, AiEnrichment` and add:

```markdown
| Books | Author | OpenLibrary | Increment 1 (Wikidata, VIAF, AI follow) |
```

- In "Books Providers → Open Library", replace the sentence "Authors and subjects are never applied from this provider -- creating authors or categories from them belongs to a separate reconciliation effort." with: "On accept, a book with no authors gets the accepted work's authors through the author importer, by key and name, in Open Library's order. Subjects are never applied."
- Replace the paragraph's last sentences, from "A title+author-only import is NOT idempotent by rule yet…" to "…the AI decides.", with: "A title+author import is idempotent: the author step links the authors, so the exact source finds the book by title joined to an author name on the next run."
- Add a new subsection after "AI Enrichment (Async)":

```markdown
#### Authors (Sync)
`Providers::Authors` runs after Open Library. When the book still has no authors (Open Library abstained,
rejected, or was unreachable -- the service is not deployed to production), each of the query's
`author_names` goes through `DataImporters::Books::Author::Importer` by name and is linked in the query's
order. A book that already has authors is left alone.

### Books Author importer
`DataImporters::Books::Author::Importer.call(name:, open_library_author_key:, birth_year:, death_year:,
alternate_names:, work_titles:)`. `name` is required unless a key is given. The finder's sources are the
Open Library author key, an exact normalized name-or-alternate-name lookup, OpenSearch
`Search::Books::Search::AuthorByName`, and the Open Library author record for the key; rule 4 is an equal
normalized name with no birth- or death-year conflict. The importer saves the new author before providers
run (`save_before_providers?`), so a name alone always persists; `ImportResult#created?` says whether it
made the author. The Open Library provider fills blank years, unions alternate names, stamps
`books_author_openlibrary_id`, and writes `name` only when blank. Wikidata, VIAF and AI providers follow in
later increments (`docs/superpowers/specs/2026-09-27-books-author-importer-design.md`).
```

- [ ] **Step 2: Update `docs/features/import-finder.md`**

In "State by increment", replace "the authors importer and the book provider's author step are increment 4, games is increment 5 and music is increment 6." with:

```markdown
**Increment 4 (authors)** added `DataImporters::Books::Author::Finder`: `Sources::Identifiers` (the
query's Open Library author key), `Sources::Exact` (normalized name or alternate name against stored
names and alternate names), `Sources::OpenSearch` over `Search::Books::Search::AuthorByName` (name or
alternate name required; the query's alternate names as boosts), and
`DataImporters::Books::Author::OpenLibrarySource` (`GET /authors/{key}`, treated as an accept; one
candidate per local holder of the key or a key it redirects from; a 404 is no candidates). Rule 4 adds
a death-year conflict check to the birth-year one. The book importer's author step links authors on an
Open Library accept and otherwise imports the query's names (`Providers::Authors`). Games is increment
5 and music is increment 6.
```

- [ ] **Step 3: Amend the spec**

In `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`:

1. In §2's bullet list, replace the `Providers::Enrichment` bullet with:

```markdown
- **A second provider, `Providers::Enrichment`** (async), enqueues `WikidataJob` and returns
  `[:author_enrichment_queued]`. It lands in increment 2 with `WikidataJob`; a provider enqueuing a job
  that does not exist yet would be dead code.
```

2. Append to §2's bullet list:

```markdown
- **Declared while planning increment 1:** the author importer saves a new author before providers run
  (`ImporterBase#save_before_providers?`), and the book importer's name path is its own provider
  (`DataImporters::Books::Book::Providers::Authors`, after Open Library). Both exist because the Open
  Library service is not deployed to production: without them a production author import would persist
  nothing, and a production book import would link no authors (the redesign's §8 only reached the name
  path on an abstain or reject, not on an unreachable service).
```

3. In §16 item 1, replace "the `Enrichment` provider stub, the created-author signal" with "the created-author signal (`ImportResult#created?`), save-before-providers".

- [ ] **Step 4: Verify Zeitwerk, lint and the full suite**

Run, from `web-app/`:

```bash
CI=1 bin/rails zeitwerk:check
bundle exec standardrb
bin/rails test
```

Expected: `All is good!` from Zeitwerk, no offenses from standardrb, and 0 failures and 0 errors from the suite, with no new warning lines beyond the known upstream sources (the `weighted_list_rank` position `puts`, npm/yarn during `test:prepare`, and the openapi_first `MultiJson` boot warning). If standardrb reports offenses, run `bundle exec standardrb --fix`, review the diff, and re-run the suite.

- [ ] **Step 5: Commit**

```bash
git add docs/features/data_importers.md docs/features/import-finder.md docs/superpowers/specs/2026-09-27-books-author-importer-design.md
git commit -m "Docs: authors importer and the book author step; spec amendments from planning

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(Include any files `standardrb --fix` touched, as a separate commit if they belong to earlier tasks.)
