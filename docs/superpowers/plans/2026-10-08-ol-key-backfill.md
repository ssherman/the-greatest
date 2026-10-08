# Open Library Key Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A resumable rake-driven backfill that checks or adds an Open Library work key on every book (ranked first), logs one outcome per book, flags duplicate pairs, saves Open Library's duplicate works under a new identifier type, and gives authors keys from confident book matches.

**Architecture:** A per-book service (`Services::Books::OlBackfill::ApplyBook`) asks `Lookup` for the book's work (fast identifier pass, then `/resolve`), applies one of seven outcomes, and writes a row to `books_open_library_backfills`. `Run` walks books in rank order one at a time, retrying Open Library failures in place and stopping the run on an outage; `Books::OpenLibraryBackfillJob` wraps it; rake tasks queue a run, print a report and revert one book. The book finder and the wizard's Import re-check learn the new duplicate-key identifier type.

**Tech Stack:** Rails 8.1, PostgreSQL, Sidekiq, Minitest + Mocha, the existing `Books::OpenLibrary::Client`.

**Spec:** `docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md`

## Global Constraints

- Run all Rails commands from `web-app/`. Docs live in the project root `docs/`.
- Generators only: `bin/rails generate model ...`, `bin/rails generate sidekiq:job ...` (never `generate job`).
- Services live in `app/lib/services/`, jobs in `app/sidekiq/`. Root-anchor model constants inside `Services::Books` (`::Books::Book`, `::Books::OpenLibraryBackfill`): a bare `Books` there resolves to `Services::Books`.
- Rails 8 enum syntax: `enum :outcome, {...}`.
- **No AI calls** anywhere in the backfill.
- **Never merge** records. Pairs go through `Services::DuplicateCandidates::Flag` with `source: :ol_backfill`.
- New identifier type: `books_work_openlibrary_duplicate_id: 9`. New duplicate source: `ol_backfill: 5`.
- Retry waits for a failing Open Library call: `[15, 30, 60, 120, 240, 300]` seconds.
- Job queue `low`, `retry: false`.
- Minitest 6: `assert_nil`, never `assert_equal nil, x`. Sidekiq runs inline in tests: stub `perform_async` where a real run would hit the network.
- Stub every Open Library call. No test touches the network.
- `bundle exec standardrb` (not rubocop). Never run brakeman. A clean `bin/rails test` prints no new warnings.
- After adding `app/lib/services/books/ol_backfill/`, run `CI=1 bin/rails zeitwerk:check`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A book with no authors** (common in legacy data): the author check can never pass, so the book must end `unsure` with its stored key untouched. Pinned in Task 5.
2. **The same work answered for two books in one run:** the first gets the key, the second must be a `duplicate_pair`, never a second holder. Pinned in Task 5.
3. **The answer already held by the book as a duplicate-type key:** it becomes the work key and the duplicate-type copy is removed, never both. Pinned in Task 5.
4. **An Open Library error after keys were already changed** (the redirect check runs inside the transaction): nothing may persist. Pinned in Task 5.
5. **A lost insert race** (two runs on one book): it must not count toward the run's limit, and the run must move on, not loop. Pinned in Task 6.

---

### Task 1: Schema: the log table, the duplicate-key type, the duplicate source

**Files:**
- Create (generator): `web-app/db/migrate/<timestamp>_create_books_open_library_backfills.rb`, `web-app/app/models/books/open_library_backfill.rb`, `web-app/test/models/books/open_library_backfill_test.rb`
- Modify: `web-app/app/models/identifier.rb` (enum), `web-app/app/models/duplicate_candidate.rb:39` (enum)
- Modify: `web-app/db/schema.rb` (by the migration)

**Interfaces:**
- Produces: `::Books::OpenLibraryBackfill` with columns `book_id, outcome, lookup, old_keys (string[]), new_key, duplicate_keys (string[]), pair_book_id, author_changes (jsonb), dump_date, matcher_version, run_id, attempts, error`; enums `outcome` (`confirmed 0, updated 1, replaced 2, keyed 3, duplicate_pair 4, unsure 5, failed 6, reverted 7`) and `lookup` with `prefix: :via` (`identifiers 0, resolve 1`); constant `KEYED_OUTCOMES`. `Identifier.identifier_types["books_work_openlibrary_duplicate_id"] == 9`. `DuplicateCandidate.sources["ol_backfill"] == 5`.
- Ruling: the spec's `method` column is named `lookup` (`method` collides with `Object#method`). There is no `validates :book_id, uniqueness:`; the unique index enforces it, so a lost race raises `ActiveRecord::RecordNotUnique` (Task 5 relies on that).

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model books/open_library_backfill book:references outcome:integer --no-fixture
```

Delete `test/fixtures/books/open_library_backfills.yml` if the generator created it anyway.

- [ ] **Step 2: Replace the generated migration body**

```ruby
class CreateBooksOpenLibraryBackfills < ActiveRecord::Migration[8.1]
  def change
    create_table :books_open_library_backfills do |t|
      t.references :book, null: false, index: {unique: true},
        foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.integer :outcome, null: false
      t.integer :lookup
      t.string :old_keys, array: true, null: false, default: []
      t.string :new_key
      t.string :duplicate_keys, array: true, null: false, default: []
      t.bigint :pair_book_id
      t.jsonb :author_changes, null: false, default: {}
      t.string :dump_date
      t.integer :matcher_version
      t.string :run_id, null: false
      t.integer :attempts, null: false, default: 1
      t.text :error
      t.timestamps
    end
    add_foreign_key :books_open_library_backfills, :books_books, column: :pair_book_id, on_delete: :nullify
    add_index :books_open_library_backfills, :outcome
    add_index :books_open_library_backfills, :run_id
  end
end
```

Keep the `Migration[x.y]` version the generator wrote.

- [ ] **Step 3: Write the failing model test**

`web-app/test/models/books/open_library_backfill_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class OpenLibraryBackfillTest < ActiveSupport::TestCase
    setup do
      @book = books_books(:war_and_peace)
    end

    test "outcome and lookup values are pinned" do
      assert_equal({"confirmed" => 0, "updated" => 1, "replaced" => 2, "keyed" => 3, "duplicate_pair" => 4,
                    "unsure" => 5, "failed" => 6, "reverted" => 7}, OpenLibraryBackfill.outcomes)
      assert_equal({"identifiers" => 0, "resolve" => 1}, OpenLibraryBackfill.lookups)
    end

    test "a row needs a book, an outcome and a run id" do
      row = OpenLibraryBackfill.new
      assert_not row.valid?
      assert_includes row.errors.attribute_names, :book
      assert_includes row.errors.attribute_names, :run_id
    end

    test "defaults: no keys, no author changes, one attempt" do
      row = OpenLibraryBackfill.create!(book: @book, outcome: :keyed, run_id: "run-1")
      assert_equal [[], [], {}, 1], [row.old_keys, row.duplicate_keys, row.author_changes, row.attempts]
    end

    test "one row per book, enforced by the database" do
      OpenLibraryBackfill.create!(book: @book, outcome: :keyed, run_id: "run-1")
      assert_raises(ActiveRecord::RecordNotUnique) { OpenLibraryBackfill.create!(book: @book, outcome: :unsure, run_id: "run-2") }
    end

    test "deleting the book deletes its row; deleting the pair book clears the pair" do
      other = books_books(:crime_and_punishment)
      row = OpenLibraryBackfill.create!(book: @book, outcome: :duplicate_pair, pair_book: other, run_id: "run-1")
      other.destroy!
      assert_nil row.reload.pair_book_id

      @book.destroy!
      assert_not OpenLibraryBackfill.exists?(row.id)
    end

    test "the new identifier type and duplicate source exist" do
      assert_equal 9, ::Identifier.identifier_types["books_work_openlibrary_duplicate_id"]
      assert_equal 5, ::DuplicateCandidate.sources["ol_backfill"]
    end
  end
end
```

- [ ] **Step 4: Run it to see it fail**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:schema:load && bin/rails test test/models/books/open_library_backfill_test.rb`
Expected: failures (no enums, no `pair_book`, unknown identifier type and source). The migration adds a table to the shared development database, which is not destructive. If annotaterb's post-migrate hook errors on a missing legacy database, prefix the migrate with `ANNOTATERB_SKIP_ON_DB_TASKS=1`.

- [ ] **Step 5: Write the model and the enum entries**

`web-app/app/models/books/open_library_backfill.rb` (keep the annotation block annotaterb writes above it):

```ruby
module Books
  # One row per book from the Open Library key backfill (spec
  # docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md, section 3).
  # new_key is Open Library's answer; for a duplicate_pair it was not saved.
  class OpenLibraryBackfill < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"
    belongs_to :pair_book, class_name: "Books::Book", optional: true

    enum :outcome, {confirmed: 0, updated: 1, replaced: 2, keyed: 3, duplicate_pair: 4, unsure: 5, failed: 6, reverted: 7}
    enum :lookup, {identifiers: 0, resolve: 1}, prefix: :via

    # Outcomes that leave the book with a key the backfill trusts.
    KEYED_OUTCOMES = %w[confirmed updated replaced keyed].freeze

    validates :outcome, :run_id, presence: true
  end
end
```

In `web-app/app/models/identifier.rb`, after `books_work_ean13: 8,`:

```ruby
    # A work Open Library lists as a duplicate of this book's work (the OL
    # key backfill). Evidence, never identity: the finder treats a holder as
    # a candidate with no verdict.
    books_work_openlibrary_duplicate_id: 9,
```

In `web-app/app/models/duplicate_candidate.rb`:

```ruby
  enum :source, {identifier_collision: 0, external_key_collision: 1, ai: 2, human: 3, bulk_verify: 4, ol_backfill: 5}, prefix: :raised_by
```

- [ ] **Step 5b: Fix the generated migration's index if needed**

If `schema.rb` shows two indexes on `book_id`, the generator's `t.references` default index survived; the Step 2 body replaces it, so re-check that only `index_books_open_library_backfills_on_book_id` (unique) exists.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/models/books/open_library_backfill_test.rb test/models/identifier_test.rb test/models/duplicate_candidate_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/books/open_library_backfill.rb app/models/identifier.rb app/models/duplicate_candidate.rb test/models/books/open_library_backfill_test.rb
git commit -m "OL backfill: log table, duplicate-key identifier type, ol_backfill pair source"
```

---

### Task 2: The title-and-author check, and the test helpers

**Files:**
- Create: `web-app/app/lib/services/books/ol_backfill/check.rb`
- Create: `web-app/test/support/ol_backfill_helper.rb`
- Modify: `web-app/test/test_helper.rb` (require the helper after `support/list_wizard_helper`)
- Test: `web-app/test/lib/services/books/ol_backfill/check_test.rb`

**Interfaces:**
- Produces: `Services::Books::OlBackfill::Check.agree?(book, work) -> bool`, `.titles_agree?(book, work)`, `.authors_agree?(book, work)`, `.normalize(text) -> String | nil`. `work` is a `::Books::OpenLibrary::Work` (`title`, `subtitle`, `author_names`, `author_keys`).
- Produces (tests): `OlBackfillHelper` with `ol_work`, `ol_hit`, `ol_resolution`, `SOURCE_VERSION`, and `OlBackfillHelper::FakeOlClient`.

- [ ] **Step 1: Write the helper**

`web-app/test/support/ol_backfill_helper.rb`:

```ruby
# frozen_string_literal: true

# Builders for the Open Library key backfill's tests: Work, IdentifierHit and
# Resolution values, and a client stand-in that records its calls.
module OlBackfillHelper
  SOURCE_VERSION = {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                    "pipeline_version" => 1, "matcher_version" => 3}.freeze

  # authors: [[author_key, name], ...]
  def ol_work(key, title:, subtitle: nil, authors: [], redirected_from: [], source_version: SOURCE_VERSION)
    ::Books::OpenLibrary::Work.from_record({
      "key" => {"source" => "openlibrary", "key" => key}, "title" => title, "subtitle" => subtitle,
      "authors" => authors.map { |author_key, name| {"key" => {"source" => "openlibrary", "key" => author_key}, "name" => name} },
      "subjects" => [], "redirected_from" => redirected_from.map { |old| {"source" => "openlibrary", "key" => old} }
    }, source_version: source_version)
  end

  def ol_hit(work_key, id_type: "isbn13", value: "9780140447934")
    ::Books::OpenLibrary::IdentifierHit.new(work_key: work_key, source: "openlibrary", redirected_from: [],
      edition_keys: [], id_type: id_type, value: value)
  end

  # A /resolve answer. With `work`, that work is the only candidate; an
  # "accept" verdict makes it the accepted one.
  def ol_resolution(verdict:, work: nil, duplicates: [], redirect_sources: [], source_version: SOURCE_VERSION)
    candidates = []
    if work
      candidates << ::Books::OpenLibrary::Candidate.new(
        work_key: work.key, source: "openlibrary", score: 0.9, rules: ["title_author"], margin: 0.3, verdict: verdict,
        evidence: {}, conflicting_features: [], diff: [], record: work, redirect_sources: redirect_sources
      )
    end
    ::Books::OpenLibrary::Resolution.new(
      decision: ::Books::OpenLibrary::Resolution::Decision.new(
        verdict: verdict, key: ((verdict == "accept") ? work&.key : nil), score: 0.9, margin: 0.3, reason: "test",
        duplicates: duplicates, duplicate_redirect_sources: []
      ),
      candidates: candidates, guards_tripped: [], volume_guards_tripped: [],
      source_version: source_version.deep_symbolize_keys
    )
  end

  # hits: {[type, value] => [IdentifierHit] or an exception to raise}
  # works: {key => Work or nil}
  # resolution: a Resolution, or a lambda given the resolve arguments
  # errors: one entry per call, in call order, whatever the call; nil means
  #   "no error for this call", an exception is raised by that call.
  class FakeOlClient
    attr_reader :calls

    def initialize(hits: {}, works: {}, resolution: nil, version: nil, errors: [])
      @hits = hits
      @works = works
      @resolution = resolution
      @version = version
      @errors = errors.dup
      @calls = []
    end

    def identifier(type, value)
      @calls << [:identifier, type, value]
      raise_next!
      found = @hits.fetch([type, value], [])
      raise found if found.is_a?(Exception)

      found
    end

    def works_batch(keys)
      @calls << [:works_batch, keys]
      raise_next!
      keys.to_h { |key| [key, @works[key]] }
    end

    def resolve(**args)
      @calls << [:resolve, args]
      raise_next!
      raise "no resolution stubbed" if @resolution.nil?

      @resolution.respond_to?(:call) ? @resolution.call(args) : @resolution
    end

    def version
      @calls << [:version]
      raise_next!
      @version
    end

    private

    def raise_next!
      error = @errors.shift
      raise error if error
    end
  end
end
```

Add to `web-app/test/test_helper.rb` after `require_relative "support/list_wizard_helper"`:

```ruby
require_relative "support/ol_backfill_helper"
```

- [ ] **Step 2: Write the failing test**

`web-app/test/lib/services/books/ol_backfill/check_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class CheckTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # Leo Tolstoy; alternate title "Voyna i mir"
        end

        test "agrees on equal titles and a shared author" do
          assert Check.agree?(@book, ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]]))
        end

        test "a matching title with no shared author does not agree" do
          assert_not Check.agree?(@book, ol_work("OL1W", title: "War and Peace", authors: [["OL2A", "Somebody Else"]]))
        end

        test "titles agree once a subtitle is dropped from one side" do
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "War and Peace: A Novel"))
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "War and Peace", subtitle: "A Novel"))
          @book.title = "War and Peace: The Maude Translation"
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "War and Peace"))
        end

        test "titles never agree on two different subtitles of the same head" do
          @book.title = "Dune: Messiah"
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: "Dune: Part One"))
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: "Dune", subtitle: "Part One"))
        end

        test "an alternate title agrees, a different title does not" do
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "Voyna i mir"))
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: "Anna Karenina"))
        end

        test "authors agree on a name or an alternate name, ignoring case and spacing" do
          assert Check.authors_agree?(@book, ol_work("OL1W", title: "x", authors: [["OL1A", "leo  TOLSTOY"]]))
          books_authors(:tolstoy).update!(alternate_names: ["Lev Tolstoy"])
          assert Check.authors_agree?(@book.reload, ol_work("OL1W", title: "x", authors: [["OL1A", "Lev Tolstoy"]]))
        end

        test "a book with no authors never agrees" do
          book = books_books(:crime_and_punishment)
          assert_empty book.authors
          assert_not Check.agree?(book, ol_work("OL1W", title: "Crime and Punishment", authors: [["OL1A", "Fyodor Dostoevsky"]]))
        end

        test "a work with no title never agrees" do
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: nil))
        end
      end
    end
  end
end
```

- [ ] **Step 3: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/check_test.rb`
Expected: FAIL, `uninitialized constant Services::Books::OlBackfill::Check` (or `OlBackfill`).

- [ ] **Step 4: Write the check**

`web-app/app/lib/services/books/ol_backfill/check.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1, "The title-and-author check": both passes act on an
      # Open Library work only when it agrees with our book on its title and
      # on at least one author.
      module Check
        module_function

        def agree?(book, work)
          titles_agree?(book, work) && authors_agree?(book, work)
        end

        # Equal after normalizing, or equal once a subtitle (text after the
        # first ":") is dropped from ONE side, never both: "Dune: Messiah"
        # and "Dune: Part One" do not agree. The work's own subtitle field,
        # when present, is its subtitle.
        def titles_agree?(book, work)
          ours = ([book.title] + Array(book.alternate_titles)).filter_map { |title| normalize(title) }.uniq
          theirs_full, theirs_short = their_titles(work)
          return false if ours.empty? || theirs_full.nil?

          ours_short = ours.filter_map { |title| short(title) }
          ours.include?(theirs_full) || (!theirs_short.nil? && ours.include?(theirs_short)) || ours_short.include?(theirs_full)
        end

        def authors_agree?(book, work)
          ours = book.authors.flat_map { |author| [author.name, *Array(author.alternate_names)] }.filter_map { |name| normalize(name) }
          theirs = Array(work.author_names).filter_map { |name| normalize(name) }
          ours.intersect?(theirs)
        end

        def normalize(text)
          return nil if text.blank?

          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase.presence
        end

        # [full title, title without its subtitle (nil when there is none)].
        def their_titles(work)
          title = normalize(work.title)
          return [nil, nil] if title.nil?

          subtitle = normalize(work.subtitle)
          subtitle ? ["#{title}: #{subtitle}", title] : [title, short(title)]
        end

        def short(normalized)
          head, separator, = normalized.partition(":")
          head.strip.presence if separator.present?
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests and the loader check**

Run: `bin/rails test test/lib/services/books/ol_backfill/check_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS; "All is good!".

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/ol_backfill/check.rb test/support/ol_backfill_helper.rb test/test_helper.rb test/lib/services/books/ol_backfill/check_test.rb
git commit -m "OL backfill: the title-and-author check and test helpers"
```

---

### Task 3: Lookup: the fast identifier pass, then /resolve

**Files:**
- Create: `web-app/app/lib/services/books/ol_backfill/lookup.rb`
- Test: `web-app/test/lib/services/books/ol_backfill/lookup_test.rb`

**Interfaces:**
- Consumes: `Check.agree?` (Task 2); client methods `identifier(type, value) -> [IdentifierHit]`, `works_batch(keys) -> {key => Work | nil}`, `resolve(**) -> Resolution`.
- Produces: `Services::Books::OlBackfill::Lookup.call(book:, client:) -> Lookup::Answer` where `Answer = Data.define(:work, :lookup, :duplicates, :redirect_sources, :source_version)`. `work` is nil when there is no trusted answer. `lookup` is `:identifiers` or `:resolve`. `source_version` is a symbol-keyed Hash (`:dump_date`, `:matcher_version`) or nil. Raises `Books::OpenLibrary::Exceptions::Error` subclasses (except a 404 on an identifier, which counts as no hit).

- [ ] **Step 1: Write the failing test**

`web-app/test/lib/services/books/ol_backfill/lookup_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class LookupTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # isbn13 9780140447934, Leo Tolstoy
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])
        end

        test "one work behind every identifier, agreeing, is settled by the fast pass" do
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => @work})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :identifiers, []], [answer.work.key, answer.lookup, answer.duplicates]
          assert_equal "2026-07-31", answer.source_version[:dump_date]
          assert_not client.calls.any? { |call| call.first == :resolve }
        end

        test "identifiers pointing at two works go to /resolve with everything we know" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "656"] => [ol_hit("OL2W", id_type: "goodreads", value: "656")]},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :resolve], [answer.work.key, answer.lookup]
          resolve_args = client.calls.find { |call| call.first == :resolve }.last
          assert_equal "War and Peace", resolve_args[:title]
          assert_equal ["Leo Tolstoy"], resolve_args[:author_names]
          assert_equal ["9780140447934"], resolve_args[:isbn13]
          assert_equal ["656"], resolve_args[:goodreads_id]
          assert_nil resolve_args[:existing_ol_key]
        end

        test "a fast hit whose work disagrees on the title goes to /resolve" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL9W")]},
            works: {"OL9W" => ol_work("OL9W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])},
            resolution: ol_resolution(verdict: "abstain")
          )

          answer = Lookup.call(book: @book, client: client)

          assert_nil answer.work
          assert_equal :resolve, answer.lookup
        end

        test "an identifier Open Library does not know (404) is no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::NotFoundError.new("no such isbn", 404)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_equal :resolve, Lookup.call(book: @book, client: client).lookup
        end

        test "a book with no identifiers goes straight to /resolve with its stored key as a hint" do
          book = books_books(:crime_and_punishment) # holds OL262758W, no ISBN, no author
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: ol_work("OL262758W", title: "Crime and Punishment")))

          answer = Lookup.call(book: book, client: client)

          assert_equal "OL262758W", client.calls.last.last[:existing_ol_key]
          assert_nil answer.work, "no author, so the check cannot pass"
        end

        test "an accepted work that fails our check is no answer" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: ol_work("OL5W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "an accepted, agreeing work brings its duplicates (minus itself) and redirect sources" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W", "OL1W"], redirect_sources: ["OL0W"]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal [["OL2W"], ["OL0W"]], [answer.duplicates, answer.redirect_sources]
        end

        test "no more than MAX_FAST_LOOKUPS identifier calls" do
          12.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn10, value: "000000000#{i}") }
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain"))

          Lookup.call(book: @book, client: client)

          assert_equal Lookup::MAX_FAST_LOOKUPS, client.calls.count { |call| call.first == :identifier }
        end

        test "any other Open Library error is raised" do
          client = FakeOlClient.new(errors: [::Books::OpenLibrary::Exceptions::ServerError.new("boom", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { Lookup.call(book: @book, client: client) }
        end
      end
    end
  end
end
```


- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/lookup_test.rb`
Expected: FAIL, `uninitialized constant ...::Lookup`.

- [ ] **Step 3: Write Lookup**

`web-app/app/lib/services/books/ol_backfill/lookup.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1, passes 1 and 2: which Open Library work, if any, this
      # book is. Raises the client's errors (a 404 on an identifier is no
      # hit); Run retries them.
      class Lookup
        Answer = Data.define(:work, :lookup, :duplicates, :redirect_sources, :source_version)

        FAST_TYPES = {
          "books_work_isbn13" => "isbn13",
          "books_work_isbn10" => "isbn10",
          "books_work_goodreads_id" => "goodreads"
        }.freeze
        # Enough lookups to show whether a book's identifiers agree.
        MAX_FAST_LOOKUPS = 10

        def self.call(book:, client:)
          new(book, client).call
        end

        def initialize(book, client)
          @book = book
          @client = client
        end

        def call
          fast || full
        end

        private

        def identifiers
          @identifiers ||= @book.identifiers.where(identifier_type: FAST_TYPES.keys).order(:id).pluck(:identifier_type, :value)
        end

        def values(type) = identifiers.select { |held, _| held == type }.map(&:last)

        def stored_keys
          @book.identifiers.where(identifier_type: :books_work_openlibrary_id).order(:id).pluck(:value)
        end

        def fast
          return nil if identifiers.empty?

          hits = identifiers.first(MAX_FAST_LOOKUPS).flat_map { |type, value| hits_for(FAST_TYPES.fetch(type), value) }
          keys = hits.map(&:work_key).compact.uniq
          return nil unless keys.size == 1

          work = @client.works_batch(keys)[keys.first]
          return nil unless work && Check.agree?(@book, work)

          Answer.new(work: work, lookup: :identifiers, duplicates: [], redirect_sources: [], source_version: work.source_version)
        end

        def hits_for(type, value)
          @client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::NotFoundError
          []
        end

        def full
          resolution = @client.resolve(
            title: @book.title.to_s,
            author_names: @book.authors.map(&:name),
            year: @book.first_published_year,
            isbn13: values("books_work_isbn13"),
            isbn10: values("books_work_isbn10"),
            goodreads_id: values("books_work_goodreads_id"),
            existing_ol_key: stored_keys.first
          )
          accepted = resolution.accepted
          work = accepted&.record
          unless work && Check.agree?(@book, work)
            return Answer.new(work: nil, lookup: :resolve, duplicates: [], redirect_sources: [], source_version: resolution.source_version)
          end

          Answer.new(work: work, lookup: :resolve, duplicates: resolution.decision.duplicates.uniq - [work.key],
            redirect_sources: Array(accepted.redirect_sources), source_version: resolution.source_version)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/books/ol_backfill/lookup_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/ol_backfill/lookup.rb test/lib/services/books/ol_backfill/lookup_test.rb
git commit -m "OL backfill: Lookup, the fast identifier pass then /resolve"
```

---

### Task 4: Author keys from a matched work

**Files:**
- Create: `web-app/app/lib/services/books/ol_backfill/author_keys.rb`
- Test: `web-app/test/lib/services/books/ol_backfill/author_keys_test.rb`

**Interfaces:**
- Consumes: `Check.normalize` (Task 2); `Services::DuplicateCandidates::Flag.call(item_type:, ids:, source:, evidence:)`.
- Produces: `Services::Books::OlBackfill::AuthorKeys.call(book:, work:) -> Hash` shaped `{"added" => [[author_id, key]], "pairs" => [[author_id, other_author_id, key]], "conflicts" => [[author_id, held_key, key]]}`. Creates `books_author_openlibrary_id` identifiers for "added".

- [ ] **Step 1: Write the failing test**

`web-app/test/lib/services/books/ol_backfill/author_keys_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class AuthorKeysTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @tolstoy = books_authors(:tolstoy)
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
        end

        def author_keys(author)
          author.identifiers.where(identifier_type: :books_author_openlibrary_id).pluck(:value)
        end

        test "an author with no key takes the matched work author's key" do
          changes = AuthorKeys.call(book: @book, work: @work)

          assert_equal [["OL26783A"], [[@tolstoy.id, "OL26783A"]]], [author_keys(@tolstoy), changes["added"]]
        end

        test "an author already holding that key is left alone" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")

          assert_equal({"added" => [], "pairs" => [], "conflicts" => []}, AuthorKeys.call(book: @book, work: @work))
        end

        test "an author holding a different key is a conflict and keeps its key" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL9A")

          changes = AuthorKeys.call(book: @book, work: @work)

          assert_equal [["OL9A"], [[@tolstoy.id, "OL9A", "OL26783A"]]], [author_keys(@tolstoy), changes["conflicts"]]
        end

        test "another author holding the key is a flagged pair, and no key is saved" do
          king = books_authors(:king)
          king.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")

          changes = AuthorKeys.call(book: @book, work: @work)

          assert_empty author_keys(@tolstoy)
          assert_equal [[@tolstoy.id, king.id, "OL26783A"]], changes["pairs"]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Author", item_a_id: [@tolstoy.id, king.id].min, item_b_id: [@tolstoy.id, king.id].max)
          assert_equal "ol_backfill", pair.source
        end

        test "an alternate name pairs an author" do
          @tolstoy.update!(alternate_names: ["Lev Tolstoy"])
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Lev Tolstoy"]])

          assert_equal [[@tolstoy.id, "OL26783A"]], AuthorKeys.call(book: @book.reload, work: work)["added"]
        end

        test "no work author with the name, or two with different keys, leaves the author alone" do
          nobody = ol_work("OL1W", title: "War and Peace", authors: [["OL5A", "Somebody Else"]])
          twins = ol_work("OL1W", title: "War and Peace", authors: [["OL5A", "Leo Tolstoy"], ["OL6A", "Leo Tolstoy"]])

          assert_empty AuthorKeys.call(book: @book, work: nobody)["added"]
          assert_empty AuthorKeys.call(book: @book, work: twins)["added"]
          assert_empty author_keys(@tolstoy)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/author_keys_test.rb`
Expected: FAIL, `uninitialized constant ...::AuthorKeys`.

- [ ] **Step 3: Write AuthorKeys**

`web-app/app/lib/services/books/ol_backfill/author_keys.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 2: our book's authors take the matched work's author
      # keys. Only an author with no key gets one; a different key is a
      # conflict left alone (Open Library has many duplicate authors), and a
      # key another author of ours holds is a pair for review.
      class AuthorKeys
        AUTHOR_KEY = "books_author_openlibrary_id"

        def self.call(book:, work:)
          new(book, work).call
        end

        def initialize(book, work)
          @book = book
          @work = work
        end

        def call
          changes = {"added" => [], "pairs" => [], "conflicts" => []}
          @book.authors.each do |author|
            key = key_for(author)
            next if key.nil?

            held = author.identifiers.where(identifier_type: AUTHOR_KEY).order(:id).pluck(:value)
            next if held.include?(key)

            if held.any?
              changes["conflicts"] << [author.id, held.first, key]
            elsif (other = holder_of(key, except: author))
              ::Services::DuplicateCandidates::Flag.call(
                item_type: "Books::Author", ids: [author.id, other], source: :ol_backfill,
                evidence: {reason: "Open Library gives both authors the key #{key}", open_library_key: key}
              )
              changes["pairs"] << [author.id, other, key]
            else
              author.identifiers.create!(identifier_type: AUTHOR_KEY, value: key)
              changes["added"] << [author.id, key]
            end
          end
          changes
        end

        private

        # The key of the one work author whose name agrees, or nil.
        def key_for(author)
          names = [author.name, *Array(author.alternate_names)].filter_map { |name| Check.normalize(name) }
          names_on_work = Array(@work.author_names)
          keys_on_work = Array(@work.author_keys)
          keys = names_on_work.each_index.select { |index| names.include?(Check.normalize(names_on_work[index])) }
            .filter_map { |index| keys_on_work[index] }.uniq
          keys.first if keys.size == 1
        end

        def holder_of(key, except:)
          ::Identifier.where(identifiable_type: "Books::Author", identifier_type: AUTHOR_KEY, value: key)
            .where.not(identifiable_id: except.id).order(:identifiable_id).pick(:identifiable_id)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/books/ol_backfill/author_keys_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/ol_backfill/author_keys.rb test/lib/services/books/ol_backfill/author_keys_test.rb
git commit -m "OL backfill: author keys from a matched work"
```

---

### Task 5: ApplyBook: one book's outcome

**Files:**
- Create: `web-app/app/lib/services/books/ol_backfill/apply_book.rb`
- Test: `web-app/test/lib/services/books/ol_backfill/apply_book_test.rb`

**Interfaces:**
- Consumes: `Lookup.call(book:, client:) -> Answer` (Task 3), `AuthorKeys.call(book:, work:) -> Hash` (Task 4), `::Books::OpenLibraryBackfill` (Task 1), `Flag.call`.
- Produces:
  - `Services::Books::OlBackfill::ApplyBook.call(book:, client:, run_id:) -> Result(success?, data: OpenLibraryBackfill row | nil, errors:)`. `success?: false` only when another run wrote the book's row first (insert race). Open Library errors propagate with nothing written.
  - `ApplyBook.record_failure(book:, run_id:, error:) -> row` (outcome `failed`, attempts incremented).
  - Constants `ApplyBook::WORK_KEY = "books_work_openlibrary_id"`, `ApplyBook::DUPLICATE_KEY = "books_work_openlibrary_duplicate_id"`.

- [ ] **Step 1: Write the failing test**

`web-app/test/lib/services/books/ol_backfill/apply_book_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class ApplyBookTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # isbn13 9780140447934, Leo Tolstoy, no OL key
          @other = books_books(:crime_and_punishment) # holds OL262758W
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
        end

        # The fast pass settles @book on `work`; `works` adds records for the redirect check.
        def fast_client(work = @work, works: {}, errors: [])
          FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit(work.key)]}, works: {work.key => work}.merge(works), errors: errors)
        end

        # No identifier hit: /resolve answers.
        def resolve_client(resolution, works: {})
          FakeOlClient.new(resolution: resolution, works: works)
        end

        def work_keys(book = @book) = book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).order(:id).pluck(:value)

        def duplicate_keys(book = @book) = book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY).order(:id).pluck(:value)

        def add_key(value, book: @book, type: ApplyBook::WORK_KEY) = ::Identifier.create!(identifiable: book, identifier_type: type, value: value)

        test "keyed: a book with no key gets one, its author gets one, and the row says how" do
          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal ["OL1W"], work_keys
          assert_equal ["keyed", "identifiers", [], "OL1W", "run-1", 1, "2026-07-31", 3],
            [row.outcome, row.lookup, row.old_keys, row.new_key, row.run_id, row.attempts, row.dump_date, row.matcher_version]
          assert_equal [[books_authors(:tolstoy).id, "OL26783A"]], row.author_changes["added"]
        end

        test "confirmed: the stored key is the answer; any other stored key is removed and logged" do
          add_key("OL1W")
          add_key("OL9W")

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal [["OL1W"], "confirmed", ["OL1W", "OL9W"]], [work_keys, row.outcome, row.old_keys]
        end

        test "updated: the stored key is one Open Library redirects to the answer (from /resolve)" do
          add_key("OL0W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work, redirect_sources: ["OL0W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL1W"], "updated", ["OL0W"], "resolve"], [work_keys, row.outcome, row.old_keys, row.lookup]
        end

        test "updated: the stored key's record is the answer (from the redirect lookup)" do
          add_key("OL0W")

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL0W" => @work}), run_id: "run-1").data

          assert_equal [["OL1W"], "updated"], [work_keys, row.outcome]
        end

        test "replaced: the stored key is a different work, or dead" do
          add_key("OL5W")
          anna = ol_work("OL5W", title: "Anna Karenina", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL5W" => anna}), run_id: "run-1").data
          assert_equal [["OL1W"], "replaced", ["OL5W"]], [work_keys, row.outcome, row.old_keys]

          book = books_books(:got)
          ::Identifier.create!(identifiable: book, identifier_type: ApplyBook::WORK_KEY, value: "OLDEADW")
          got = ol_work("OL7W", title: book.title, authors: [["OL2A", "Stephen King"]])
          dead = ApplyBook.call(book: book, client: resolve_client(ol_resolution(verdict: "accept", work: got)), run_id: "run-1").data
          assert_equal [["OL7W"], "replaced"], [work_keys(book), dead.outcome]
        end

        test "duplicate_pair: another book holds the answer; nothing on this book changes and the pair is flagged" do
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_empty work_keys
          assert_equal ["duplicate_pair", @other.id, "OL262758W", {}], [row.outcome, row.pair_book_id, row.new_key, row.author_changes]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "ol_backfill", pair.source
          assert_empty books_authors(:tolstoy).identifiers
        end

        test "unsure: no trusted answer leaves the stored key alone" do
          add_key("OL5W")

          row = ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "abstain")), run_id: "run-1").data

          assert_equal [["OL5W"], "unsure", ["OL5W"], nil], [work_keys, row.outcome, row.old_keys, row.new_key]
        end

        test "a book with no authors is unsure and keeps its stored key" do
          work = ol_work("OL262758W", title: "Crime and Punishment", authors: [["OL1A", "Fyodor Dostoevsky"]])

          row = ApplyBook.call(book: @other, client: resolve_client(ol_resolution(verdict: "accept", work: work)), run_id: "run-1").data

          assert_equal [["OL262758W"], "unsure"], [work_keys(@other), row.outcome]
        end

        test "duplicates from /resolve are saved as the duplicate type; one another book holds is a pair instead" do
          add_key("OL3W", book: @other)
          client = resolve_client(ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W", "OL3W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL2W"], ["OL2W"]], [duplicate_keys, row.duplicate_keys]
          assert ::DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "keyed", row.outcome
        end

        test "an answer the book held as a duplicate key becomes its work key, and the duplicate copy goes" do
          add_key("OL1W", type: ApplyBook::DUPLICATE_KEY)

          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_equal [["OL1W"], []], [work_keys, duplicate_keys]
        end

        test "the same work answered for a second book in the run is a duplicate_pair" do
          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")
          got = books_books(:got)
          same = ol_work("OL1W", title: got.title, authors: [["OL2A", "Stephen King"]])

          row = ApplyBook.call(book: got, client: resolve_client(ol_resolution(verdict: "accept", work: same)), run_id: "run-1").data

          assert_equal ["duplicate_pair", @book.id], [row.outcome, row.pair_book_id]
          assert_empty work_keys(got)
        end

        test "an Open Library error after keys changed persists nothing" do
          add_key("OL5W")
          # identifier, works_batch (fast pass), then the redirect check's works_batch raises
          client = fast_client(errors: [nil, nil, ::Books::OpenLibrary::Exceptions::ServerError.new("down", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { ApplyBook.call(book: @book, client: client, run_id: "run-1") }

          assert_equal ["OL5W"], work_keys
          assert_not ::Books::OpenLibraryBackfill.exists?(book: @book)
        end

        test "record_failure writes a failed row, then counts attempts; a later success clears the error" do
          ApplyBook.record_failure(book: @book, run_id: "run-1", error: "down")
          row = ApplyBook.record_failure(book: @book, run_id: "run-2", error: "still down")
          assert_equal ["failed", 2, "still down", "run-2"], [row.outcome, row.attempts, row.error, row.run_id]

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-3").data
          assert_equal ["keyed", 3, nil], [row.outcome, row.attempts, row.error]
        end

        test "losing the insert race to another run is an unsuccessful result, not an error" do
          ::Books::OpenLibraryBackfill.create!(book: @book, outcome: :unsure, run_id: "other-run")
          ::Books::OpenLibraryBackfill.stubs(:find_or_initialize_by).returns(::Books::OpenLibraryBackfill.new(book: @book))

          result = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_not result.success?
          assert_empty work_keys
        end
      end
    end
  end
end
```

`books_books(:got)` is "A Game of Thrones" by `books_authors(:king)` with no identifiers, so it always reaches `/resolve`.

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/apply_book_test.rb`
Expected: FAIL, `uninitialized constant ...::ApplyBook`.

- [ ] **Step 3: Write ApplyBook**

`web-app/app/lib/services/books/ol_backfill/apply_book.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1: one book's outcome. Looks the book up, changes its
      # keys, flags pairs, gives its authors keys and writes its log row, all
      # in one transaction. Open Library errors propagate with nothing
      # written; Run retries them and, giving up, calls record_failure.
      class ApplyBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        WORK_KEY = "books_work_openlibrary_id"
        DUPLICATE_KEY = "books_work_openlibrary_duplicate_id"

        def self.call(book:, client:, run_id:)
          new(book, client, run_id).call
        end

        def self.record_failure(book:, run_id:, error:)
          row = ::Books::OpenLibraryBackfill.find_or_initialize_by(book: book)
          row.assign_attributes(outcome: :failed, run_id: run_id, error: error.to_s.truncate(1000),
            attempts: row.new_record? ? 1 : row.attempts + 1)
          row.save!
          row
        end

        def initialize(book, client, run_id)
          @book = book
          @client = client
          @run_id = run_id
        end

        def call
          answer = Lookup.call(book: @book, client: @client)
          ::ActiveRecord::Base.transaction do
            row = ::Books::OpenLibraryBackfill.find_or_initialize_by(book: @book)
            attempts = row.new_record? ? 1 : row.attempts + 1
            row.assign_attributes(decide(answer).merge(
              lookup: answer.lookup, run_id: @run_id, attempts: attempts, error: nil,
              dump_date: answer.source_version&.dig(:dump_date), matcher_version: answer.source_version&.dig(:matcher_version)
            ))
            row.save!
            Result.new(success?: true, data: row, errors: [])
          end
        rescue ::ActiveRecord::RecordNotUnique
          Result.new(success?: false, data: nil, errors: ["another run wrote book #{@book.id} first"])
        end

        private

        def decide(answer)
          stored = stored_keys
          work = answer.work
          return unchanged(:unsure, stored, nil) if work.nil?

          key = work.key
          if (other = book_holding(key))
            flag_books(other, key)
            return unchanged(:duplicate_pair, stored, key).merge(pair_book_id: other)
          end

          outcome = if stored.include?(key) then :confirmed
          elsif stored.empty? then :keyed
          elsif redirected?(stored, key, answer) then :updated
          else
            :replaced
          end
          set_work_key(stored, key)
          {outcome: outcome, old_keys: stored, new_key: key, pair_book_id: nil,
           duplicate_keys: save_duplicates(answer.duplicates, key),
           author_changes: AuthorKeys.call(book: @book, work: work)}
        end

        def unchanged(outcome, stored, key)
          {outcome: outcome, old_keys: stored, new_key: key, duplicate_keys: [], pair_book_id: nil, author_changes: {}}
        end

        def stored_keys
          @book.identifiers.where(identifier_type: WORK_KEY).order(:id).pluck(:value)
        end

        # Another book holding this key as its work key.
        def book_holding(key)
          ::Identifier.where(identifiable_type: "Books::Book", identifier_type: WORK_KEY, value: key)
            .where.not(identifiable_id: @book.id).order(:identifiable_id).pick(:identifiable_id)
        end

        # updated rather than replaced: an old key Open Library redirects to the answer.
        def redirected?(stored, key, answer)
          return true if stored.intersect?(answer.redirect_sources)

          records = @client.works_batch(stored)
          stored.any? { |old| records[old]&.key == key }
        end

        def set_work_key(stored, key)
          @book.identifiers.where(identifier_type: WORK_KEY).where.not(value: key).destroy_all
          @book.identifiers.where(identifier_type: DUPLICATE_KEY, value: key).destroy_all
          @book.identifiers.create!(identifier_type: WORK_KEY, value: key) unless stored.include?(key)
        end

        # Spec section 1, "Open Library's duplicate works": only /resolve
        # returns them. One another book holds as its work key is a pair.
        def save_duplicates(duplicates, key)
          held = @book.identifiers.where(identifier_type: DUPLICATE_KEY).pluck(:value)
          duplicates.uniq.each_with_object([]) do |duplicate, saved|
            next if duplicate == key || held.include?(duplicate)

            if (other = book_holding(duplicate))
              flag_books(other, duplicate)
            else
              @book.identifiers.create!(identifier_type: DUPLICATE_KEY, value: duplicate)
              saved << duplicate
            end
          end
        end

        def flag_books(other, key)
          ::Services::DuplicateCandidates::Flag.call(
            item_type: "Books::Book", ids: [@book.id, other], source: :ol_backfill,
            evidence: {reason: "Open Library matched both books to #{key}", open_library_key: key}
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/books/ol_backfill/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/ol_backfill/apply_book.rb test/lib/services/books/ol_backfill/apply_book_test.rb
git commit -m "OL backfill: ApplyBook, one book's outcome"
```

---

### Task 6: Run and the job

**Files:**
- Create: `web-app/app/lib/services/books/ol_backfill/run.rb`
- Create (generator): `web-app/app/sidekiq/books/open_library_backfill_job.rb`, `web-app/test/sidekiq/books/open_library_backfill_job_test.rb`
- Test: `web-app/test/lib/services/books/ol_backfill/run_test.rb`

**Interfaces:**
- Consumes: `ApplyBook.call(book:, client:, run_id:) -> Result`, `ApplyBook.record_failure(book:, run_id:, error:)` (Task 5); `client.version -> {dump_date:, matcher_version:, ...}`.
- Produces: `Services::Books::OlBackfill::Run.call(limit:, run_id:, retry_unsure: false, client: nil, sleeper: nil, scope: nil) -> Result(success?, data: {processed: Integer, stopped: Boolean, error: String | nil}, errors:)`. `Run::RETRY_DELAYS`. `Books::OpenLibraryBackfillJob#perform(limit, run_id, retry_unsure = false)`.

- [ ] **Step 1: Generate the job**

```bash
bin/rails generate sidekiq:job books/open_library_backfill
```

- [ ] **Step 2: Write the failing tests**

`web-app/test/lib/services/books/ol_backfill/run_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class RunTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @war = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @got = books_books(:got)
          @clash = books_books(:clash)
          @scope = ::Books::Book.where(id: [@war, @crime, @got, @clash].map(&:id))
          @client = FakeOlClient.new
        end

        def no_sleep = ->(_seconds) { flunk "no wait expected" }

        # ApplyBook stand-in: records the order and writes the row a real one would.
        def record_applies(success: true)
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: success ? run_id : "other-run")
            true
          end.returns(ApplyBook::Result.new(success?: success, data: nil, errors: []))
          order
        end

        def rank(book, position)
          ::RankedItem.create!(item: book, ranking_configuration: ranking_configurations(:books_global), rank: position, score: 100 - position)
        end

        def run(**options)
          Run.call(limit: nil, run_id: "run-1", client: @client, sleeper: no_sleep, scope: @scope, **options)
        end

        test "ranked books come first, by rank, and the run stops after its limit" do
          rank(@got, 2)
          rank(@clash, 1)
          order = record_applies

          result = run(limit: 2)

          assert_equal [@clash.id, @got.id], order
          assert_equal({processed: 2, stopped: false, error: nil}, result.data)
        end

        test "with no limit every book in scope is done once" do
          order = record_applies

          run

          assert_equal [@war, @crime, @got, @clash].map(&:id).sort, order.sort
        end

        test "books already logged are skipped, except failed ones" do
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :confirmed, run_id: "old")
          ::Books::OpenLibraryBackfill.create!(book: @got, outcome: :reverted, run_id: "old")
          ::Books::OpenLibraryBackfill.create!(book: @clash, outcome: :unsure, run_id: "old")
          failed = ::Books::OpenLibraryBackfill.create!(book: @crime, outcome: :failed, run_id: "old")
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            failed.update!(outcome: :keyed, run_id: run_id)
            true
          end.returns(ApplyBook::Result.new(success?: true, data: nil, errors: []))

          run

          assert_equal [@crime.id], order
        end

        test "the same run started again counts the books it already did toward its limit" do
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :keyed, run_id: "run-1")
          order = record_applies

          result = run(limit: 2)

          assert_equal 1, order.size
          assert_equal 2, result.data[:processed]
        end

        test "an Open Library failure waits and tries the book again" do
          error = ::Books::OpenLibrary::Exceptions::ServerError.new("busy", 500)
          calls = 0
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            calls += 1
            raise error if calls == 1

            ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: run_id)
            true
          end.returns(ApplyBook::Result.new(success?: true, data: nil, errors: []))
          waits = []

          run(limit: 1, sleeper: ->(seconds) { waits << seconds })

          assert_equal [Run::RETRY_DELAYS.first], waits
          assert_equal 2, calls
        end

        test "a book that keeps failing is logged failed after the last wait, and the run stops" do
          ApplyBook.stubs(:call).raises(::Books::OpenLibrary::Exceptions::ServerError.new("down", 500))
          waits = []

          result = run(sleeper: ->(seconds) { waits << seconds })

          assert_equal Run::RETRY_DELAYS, waits
          assert_equal true, result.data[:stopped]
          assert_match(/down/, result.data[:error])
          assert_equal 1, ::Books::OpenLibraryBackfill.failed.count
        end

        test "retry_unsure takes unsure books from an older Open Library version only" do
          @client = FakeOlClient.new(version: {dump_date: "2026-09-30", matcher_version: 3})
          [@crime, @got, @clash].each { |book| ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: "old") }
          stale = ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :unsure, run_id: "old", dump_date: "2026-07-31", matcher_version: 3)
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            stale.update!(dump_date: "2026-09-30", run_id: run_id)
            true
          end.returns(ApplyBook::Result.new(success?: true, data: nil, errors: []))

          run(retry_unsure: true)
          assert_equal [@war.id], order

          order.clear
          stale.update!(dump_date: "2026-09-30")
          run(retry_unsure: true)
          assert_empty order
        end

        test "without retry_unsure an unsure book is never taken again" do
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :unsure, run_id: "old", dump_date: "2000-01-01", matcher_version: 1)
          order = record_applies

          run

          assert_not_includes order, @war.id
        end

        test "a lost insert race does not count toward the limit, and the run moves on" do
          order = record_applies(success: false)

          result = run(limit: 2)

          assert_equal 4, order.size
          assert_equal 0, result.data[:processed]
        end
      end
    end
  end
end
```

`web-app/test/sidekiq/books/open_library_backfill_job_test.rb` (replace the generated body):

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::OpenLibraryBackfillJobTest < ActiveSupport::TestCase
  test "runs the backfill with its limit, run id and mode, on the low queue without retries" do
    ::Services::Books::OlBackfill::Run.expects(:call).with(limit: 100, run_id: "run-1", retry_unsure: true)
      .returns(::Services::Books::OlBackfill::Run::Result.new(success?: true, data: {processed: 100, stopped: false, error: nil}, errors: []))

    Books::OpenLibraryBackfillJob.new.perform(100, "run-1", true)

    assert_equal ["low", false], Books::OpenLibraryBackfillJob.get_sidekiq_options.values_at("queue", "retry").map { |value| value.is_a?(Symbol) ? value.to_s : value }
  end
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/run_test.rb test/sidekiq/books/open_library_backfill_job_test.rb`
Expected: FAIL, `uninitialized constant ...::Run`.

- [ ] **Step 4: Write Run and the job**

`web-app/app/lib/services/books/ol_backfill/run.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 4, "The job": books one at a time, ranked first, then by
      # how many lists they are on, then id, stopping after `limit` (nil: all).
      # A book whose Open Library lookup raised waits and is tried again;
      # after the last wait it is logged failed and the run stops, so an
      # outage does not use up the batch.
      class Run
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        RETRY_DELAYS = [15, 30, 60, 120, 240, 300].freeze
        BATCH = 100

        def self.call(limit:, run_id:, retry_unsure: false, client: nil, sleeper: nil, scope: nil)
          new(limit: limit, run_id: run_id, retry_unsure: retry_unsure, client: client, sleeper: sleeper, scope: scope).call
        end

        def initialize(limit:, run_id:, retry_unsure:, client:, sleeper:, scope:)
          @limit = limit
          @run_id = run_id
          @retry_unsure = retry_unsure
          @client = client || ::Books::OpenLibrary::Client.new
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          @scope = scope || ::Books::Book.all
        end

        def call
          version = @retry_unsure ? @client.version : nil
          # A job Sidekiq requeued at a deploy carries its run id: what it
          # already logged counts toward its limit.
          done = ::Books::OpenLibraryBackfill.where(run_id: @run_id).count
          loop do
            break if full?(done)

            ids = next_ids(version, done)
            break if ids.empty?

            ids.each do |id|
              break if full?(done)

              book = ::Books::Book.find_by(id: id)
              next unless book

              case process(book)
              when :done then done += 1
              when :failed then return finish(done, stopped: true)
              end
            end
          end
          finish(done, stopped: false)
        rescue ::Books::OpenLibrary::Exceptions::Error => e
          @error = "#{e.class}: #{e.message}"
          finish(done || 0, stopped: true)
        end

        private

        def full?(done) = !@limit.nil? && done >= @limit

        def finish(done, stopped:)
          Result.new(success?: !stopped, data: {processed: done, stopped: stopped, error: @error}, errors: [@error].compact)
        end

        # :done, :skipped (another run wrote the row) or :failed.
        def process(book)
          attempt = 0
          begin
            ApplyBook.call(book: book, client: @client, run_id: @run_id).success? ? :done : :skipped
          rescue ::Books::OpenLibrary::Exceptions::Error => e
            delay = RETRY_DELAYS[attempt]
            if delay
              attempt += 1
              @sleeper.call(delay)
              retry
            end
            @error = "#{e.class}: #{e.message}"
            ApplyBook.record_failure(book: book, run_id: @run_id, error: @error)
            :failed
          end
        end

        def next_ids(version, done)
          size = @limit.nil? ? BATCH : [BATCH, @limit - done].min
          settled = ::Books::OpenLibraryBackfill.where.not(outcome: :failed)
          settled = settled.where.not(id: retryable_unsure(version)) if version
          config_id = ::Books::RankingConfiguration.default_primary&.id

          @scope
            .where.not(id: settled.select(:book_id))
            .joins(::Books::Book.sanitize_sql_array([
              "LEFT JOIN ranked_items ranked ON ranked.item_type = 'Books::Book' AND ranked.item_id = books_books.id " \
              "AND ranked.ranking_configuration_id = ? AND ranked.rank IS NOT NULL", config_id
            ]))
            .joins("LEFT JOIN (SELECT listable_id, COUNT(*) AS list_count FROM list_items " \
                   "WHERE listable_type = 'Books::Book' GROUP BY listable_id) list_counts ON list_counts.listable_id = books_books.id")
            .order(Arel.sql("ranked.rank ASC NULLS LAST, list_counts.list_count DESC NULLS LAST, books_books.id ASC"))
            .limit(size)
            .pluck("books_books.id")
        end

        def retryable_unsure(version)
          ::Books::OpenLibraryBackfill.unsure
            .where("dump_date < :dump OR matcher_version < :matcher", dump: version[:dump_date].to_s, matcher: version[:matcher_version].to_i)
            .select(:id)
        end
      end
    end
  end
end
```

`web-app/app/sidekiq/books/open_library_backfill_job.rb`:

```ruby
# frozen_string_literal: true

# The Open Library key backfill (docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md).
# Queued by books:ol_backfill. One run works through books one at a time, so
# it can hold a thread for days; `low` keeps it behind members' work.
class Books::OpenLibraryBackfillJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(limit, run_id, retry_unsure = false)
    data = ::Services::Books::OlBackfill::Run.call(limit: limit, run_id: run_id, retry_unsure: retry_unsure).data
    Rails.logger.info("Open Library backfill run #{run_id}: #{data[:processed]} books" \
      "#{" -- stopped: #{data[:error]}" if data[:stopped]}")
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/services/books/ol_backfill/ test/sidekiq/books/open_library_backfill_job_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/ol_backfill/run.rb app/sidekiq/books/open_library_backfill_job.rb test/lib/services/books/ol_backfill/run_test.rb test/sidekiq/books/open_library_backfill_job_test.rb
git commit -m "OL backfill: Run, ranked first and resumable, and its job"
```

---

### Task 7: The finder and the Import re-check learn duplicate keys

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/open_library_source.rb` (`duplicate_holders`, `holdings_of`)
- Modify: `web-app/app/lib/services/lists/wizard/books/adapter.rb` (`book_holding`)
- Modify: `docs/features/open-library-data-service.md` (the holder rules list, near "Rails (`OpenLibrarySource`) treats each kind of holder differently")
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb`, `web-app/test/lib/services/lists/wizard/books/adapter_test.rb`

**Interfaces:**
- Consumes: identifier type `books_work_openlibrary_duplicate_id` (Task 1).
- Produces: a book holding the accepted key (or one of its duplicates) as a duplicate-type key is returned by `OpenLibrarySource` as a candidate with no verdict and `external_duplicate_of` = the accepted key. `Adapter#recheck` finds a book holding a saved key as either type.
- Ruling: the spec says "an accepted or returned key". Only the accepted key and its duplicates are looked up: a returned key that was not accepted gives no verdict to act on, and adding its duplicate-type holders as plain holders would hand them that candidate's verdict.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/data_importers/books/book/finder_test.rb`, in the "Open Library (rules 2 and 5)" section, add:

```ruby
        test "a book holding the accepted work as a duplicate key blocks a create and is a candidate with no verdict" do
          ::Identifier.create!(identifiable: @crime, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL999W")
          stub_resolve(resolve_response(verdict: "accept", key: "OL999W", candidates: [ol_candidate(key: "OL999W", verdict: "accept", score: 0.95, record: work_record(key: "OL999W", title: "The Brothers Karamazov", authors: ["Fyodor Dostoevsky"]))]))
          stub_ai({selected_index: 0, confidence: "high", reasoning: "A different novel.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "The Brothers Karamazov", author_names: ["Fyodor Dostoevsky"]))

          assert_equal [:unmatched, :ai], [match.outcome, match.decided_by]
          holder = match.candidates.find { |candidate| candidate.record == @crime }
          assert_equal ["OL999W", "OL999W"], [holder.external_key, holder.evidence[:external_duplicate_of]]
          assert_nil holder.external_verdict
        end

        test "a duplicate-key holder beside the accepted key's holder is flagged as a pair" do
          ::Identifier.create!(identifiable: @war_and_peace, identifier_type: :books_work_openlibrary_id, value: "OL999W")
          ::Identifier.create!(identifiable: @crime, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL999W")
          stub_resolve(resolve_response(verdict: "accept", key: "OL999W", candidates: [ol_candidate(key: "OL999W", verdict: "accept", score: 0.95, record: work_record(key: "OL999W", title: "War and Peace", authors: ["Leo Tolstoy"]))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :certain], [match.record, match.confidence]
          ids = [@war_and_peace.id, @crime.id]
          assert ::DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: ids.min, item_b_id: ids.max)
        end
```

In `web-app/test/lib/services/lists/wizard/books/adapter_test.rb` (class `Services::Lists::Wizard::Books::AdapterTest`, whose setup builds `@adapter = Adapter.new` and `@list = wizard_list`), add after the `recheck_keys` tests:

```ruby
          test "the Import re-check finds a book holding the chosen work as a duplicate key" do
            book = books_books(:crime_and_punishment)
            ::Identifier.create!(identifiable: book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL777W")
            item = wizard_row(@list, position: 1, title: "Some Novel", wizard: {bucket: "create", ol_work_key: "OL777W", ol_keys: []})

            assert_equal book, @adapter.recheck(item)
          end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/data_importers/books/book/finder_test.rb test/lib/services/lists/wizard/books/adapter_test.rb`
Expected: the three new tests FAIL (the duplicate-type holder is not found).

- [ ] **Step 3: Change `duplicate_holders` and `holdings_of`**

In `open_library_source.rb`, replace the body of `duplicate_holders` from `keys = ...` through the `holdings = holdings_of(keys)` line:

```ruby
          keys = (decision.duplicates + decision.duplicate_redirect_sources).uniq - [accepted.work_key]
          # Work keys of the duplicates, plus duplicate-type keys (the OL key
          # backfill) of the accepted work or its duplicates.
          holdings = holdings_of(keys, work_key_type)
            .merge(holdings_of([accepted.work_key, *keys], duplicate_key_type)) { |_id, ours, theirs| (ours + theirs).uniq }
          return [] if holdings.empty?

          seen = returned.filter_map { |candidate| candidate.record&.id }
          work = accepted.record
          evidence = {
            external_duplicate_of: accepted.work_key, external_score: accepted.score,
            external_title: work&.title, external_creators: Array(work&.author_names), external_year: year_of(work)
          }
```

(The old early `return [] if keys.empty?` goes: the duplicate-type lookup includes the accepted key even when there are no duplicates. Keep the `::Books::Book.where(id: holdings.keys - seen)...` mapping unchanged after it.)

Replace `holdings_of` and add `duplicate_key_type`:

```ruby
        # book id -> the keys (of `keys`) it holds as `type`.
        def holdings_of(keys, type)
          return {} if keys.empty?

          ::Identifier
            .where(identifiable_type: "Books::Book", identifier_type: type, value: keys)
            .pluck(:identifiable_id, :value)
            .group_by(&:first)
            .transform_values { |rows| rows.map(&:last) }
        end

        def duplicate_key_type
          ::Identifier.identifier_types[:books_work_openlibrary_duplicate_id]
        end
```

Update the comment above `duplicate_holders` with one sentence: "So are books holding the accepted work, or one of its duplicates, as a duplicate-type key (saved by the Open Library key backfill)."

- [ ] **Step 4: Change `book_holding` in the wizard adapter**

```ruby
          # A book holding any of these keys as its work key, or as a
          # duplicate-type key (the Open Library key backfill).
          def book_holding(keys)
            return nil if keys.empty?

            types = ::Identifier.identifier_types.values_at("books_work_openlibrary_id", "books_work_openlibrary_duplicate_id")
            ::Books::Book.joins(:identifiers)
              .where(identifiers: {identifier_type: types, value: keys})
              .order(:id).first
          end
```

- [ ] **Step 5: Update the data service doc**

In `docs/features/open-library-data-service.md`, in the list under "Rails (`OpenLibrarySource`) treats each kind of holder differently:", add after the `duplicates` bullet:

```markdown
- A book holding the accepted work, or one of its `duplicates`, as `books_work_openlibrary_duplicate_id`
  (saved by the Open Library key backfill, `docs/features/open-library-backfill.md`) is treated the same
  way: a candidate with no verdict that blocks rule 5 and is flagged with the accepted key's holders.
  The list wizard's Import re-check also finds it.
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/data_importers/ test/lib/services/lists/wizard/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/data_importers/books/book/open_library_source.rb app/lib/services/lists/wizard/books/adapter.rb test/lib/data_importers/books/book/finder_test.rb test/lib/services/lists/wizard/books/adapter_test.rb ../docs/features/open-library-data-service.md
git commit -m "Book finder and wizard re-check: honour duplicate-type Open Library keys"
```

---

### Task 8: Rake tasks, the report, revert, and docs

**Files:**
- Create: `web-app/app/lib/services/books/ol_backfill/report.rb`, `web-app/app/lib/services/books/ol_backfill/revert.rb`
- Create: `web-app/lib/tasks/books/ol_backfill.rake`
- Create: `docs/features/open-library-backfill.md`
- Modify: `docs/launch-todo.md` (section 2)
- Test: `web-app/test/lib/services/books/ol_backfill/report_test.rb`, `web-app/test/lib/services/books/ol_backfill/revert_test.rb`, `web-app/test/lib/tasks/books_ol_backfill_rake_test.rb`

**Interfaces:**
- Consumes: `::Books::OpenLibraryBackfill` (Task 1), `ApplyBook::WORK_KEY`, `ApplyBook::DUPLICATE_KEY` (Task 5), `Books::OpenLibraryBackfillJob.perform_async(limit, run_id, retry_unsure)` (Task 6).
- Produces: `Report.call -> Array<String>`; `Revert.call(book:) -> Result(success?, data: row, errors:)`; rake tasks `books:ol_backfill[limit,mode]`, `books:ol_backfill_report`, `books:ol_backfill_revert[book_id]`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/ol_backfill/revert_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class RevertTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @tolstoy = books_authors(:tolstoy)
        end

        def keys(type) = @book.identifiers.where(identifier_type: type).order(:value).pluck(:value)

        test "a replaced book gets its old keys back; the new key, duplicates and author keys it added go" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL2W")
          ::Identifier.create!(identifiable: @tolstoy, identifier_type: :books_author_openlibrary_id, value: "OL26783A")
          row = ::Books::OpenLibraryBackfill.create!(book: @book, outcome: :replaced, run_id: "run-1", old_keys: ["OL5W", "OL9W"],
            new_key: "OL1W", duplicate_keys: ["OL2W"], author_changes: {"added" => [[@tolstoy.id, "OL26783A"]], "pairs" => [], "conflicts" => []})

          result = Revert.call(book: @book)

          assert result.success?
          assert_equal [["OL5W", "OL9W"], [], "reverted"], [keys(ApplyBook::WORK_KEY), keys(ApplyBook::DUPLICATE_KEY), row.reload.outcome]
          assert_empty @tolstoy.identifiers.where(identifier_type: :books_author_openlibrary_id)
        end

        test "a keyed book loses the key it was given" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Books::OpenLibraryBackfill.create!(book: @book, outcome: :keyed, run_id: "run-1", old_keys: [], new_key: "OL1W")

          Revert.call(book: @book)

          assert_empty keys(ApplyBook::WORK_KEY)
        end

        test "a duplicate key the book had before the backfill stays" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL3W")
          ::Books::OpenLibraryBackfill.create!(book: @book, outcome: :keyed, run_id: "run-1", new_key: "OL1W", duplicate_keys: [])

          Revert.call(book: @book)

          assert_equal ["OL3W"], keys(ApplyBook::DUPLICATE_KEY)
        end

        test "only confirmed, updated, replaced and keyed rows can be reverted" do
          ::Books::OpenLibraryBackfill.create!(book: @book, outcome: :duplicate_pair, run_id: "run-1")

          result = Revert.call(book: @book)

          assert_not result.success?
          assert_match(/duplicate_pair/, result.errors.first)
          assert_not Revert.call(book: books_books(:got)).success?, "no row at all"
        end
      end
    end
  end
end
```

`web-app/test/lib/services/books/ol_backfill/report_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class ReportTest < ActiveSupport::TestCase
        test "counts every outcome, ranked coverage, the latest run, author totals and recent replacements" do
          war = books_books(:war_and_peace)
          crime = books_books(:crime_and_punishment)
          ::RankedItem.create!(item: war, ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 99)
          ::Books::OpenLibraryBackfill.create!(book: war, outcome: :replaced, run_id: "run-1", old_keys: ["OL5W"], new_key: "OL1W",
            author_changes: {"added" => [[1, "OL1A"], [2, "OL2A"]], "pairs" => [[3, 4, "OL3A"]], "conflicts" => []})
          ::Books::OpenLibraryBackfill.create!(book: crime, outcome: :duplicate_pair, run_id: "run-2", new_key: "OL262758W", pair_book: war)

          text = Report.call.join("\n")

          assert_match(/replaced\s+1/, text)
          assert_match(/duplicate_pair\s+1/, text)
          assert_match(/keyed\s+0/, text)
          assert_match(/Ranked books checked: 1 of 1/, text)
          assert_match(/Latest run run-2: 1 books/, text)
          assert_match(/Author keys added: 2, author pairs: 1, author conflicts: 0/, text)
          assert_match(/replaced book #{war.id} "War and Peace": OL5W -> OL1W/, text)
          assert_match(/pair with book #{war.id}/, text)
        end

        test "an empty log reports zeros and no run" do
          text = Report.call.join("\n")

          assert_match(/Latest run: none/, text)
          assert_match(/Ranked books checked: 0 of/, text)
        end
      end
    end
  end
end
```

The "Latest run" line orders by `updated_at`, then `id`, so the row created last (run-2) wins a timestamp tie.

`web-app/test/lib/tasks/books_ol_backfill_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksOlBackfillRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:ol_backfill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/ol_backfill.rake").to_s }
    end
    %w[books:ol_backfill books:ol_backfill_report books:ol_backfill_revert].each { |name| Rake::Task[name].reenable }
  end

  test "a count queues one run of that many books" do
    Books::OpenLibraryBackfillJob.expects(:perform_async).with(100, instance_of(String), false)

    assert_output(/queued Open Library backfill run .*: 100 books/) { Rake::Task["books:ol_backfill"].invoke("100") }
  end

  test "all queues a run with no limit; retry_unsure is passed on" do
    Books::OpenLibraryBackfillJob.expects(:perform_async).with(nil, instance_of(String), true)

    assert_output(/all books \(retrying unsure books\)/) { Rake::Task["books:ol_backfill"].invoke("all", "retry_unsure") }
  end

  test "anything else aborts with usage and queues nothing" do
    Books::OpenLibraryBackfillJob.expects(:perform_async).never

    assert_output(nil, /usage: books:ol_backfill/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill"].invoke("soon") } }
    Rake::Task["books:ol_backfill"].reenable
    assert_output(nil, /usage: books:ol_backfill/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill"].invoke("5", "everything") } }
  end

  test "the report prints the report's lines" do
    Services::Books::OlBackfill::Report.expects(:call).returns(["Open Library backfill", "line two"])

    assert_output(/Open Library backfill\nline two/) { Rake::Task["books:ol_backfill_report"].invoke }
  end

  test "revert reverts one book, and aborts on an unknown book or a refused revert" do
    book = books_books(:war_and_peace)
    row = Books::OpenLibraryBackfill.new(old_keys: ["OL5W"])
    Services::Books::OlBackfill::Revert.expects(:call).with(book: book)
      .returns(Services::Books::OlBackfill::Revert::Result.new(success?: true, data: row, errors: []))
    assert_output(/reverted book #{book.id}/) { Rake::Task["books:ol_backfill_revert"].invoke(book.id.to_s) }

    Rake::Task["books:ol_backfill_revert"].reenable
    assert_output(nil, /no book/) { assert_raises(SystemExit) { Rake::Task["books:ol_backfill_revert"].invoke("0") } }
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/ol_backfill/revert_test.rb test/lib/services/books/ol_backfill/report_test.rb test/lib/tasks/books_ol_backfill_rake_test.rb`
Expected: FAIL (missing constants and rake file).

- [ ] **Step 3: Write Revert, Report and the rake file**

`web-app/app/lib/services/books/ol_backfill/revert.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 4, books:ol_backfill_revert: put a book's keys back the
      # way they were before the backfill. The row becomes `reverted`, which
      # no later run takes again.
      class Revert
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        REVERTIBLE = ::Books::OpenLibraryBackfill::KEYED_OUTCOMES

        def self.call(book:)
          new(book).call
        end

        def initialize(book)
          @book = book
        end

        def call
          row = ::Books::OpenLibraryBackfill.find_by(book: @book)
          return failure("book #{@book.id} has no backfill row") unless row
          unless REVERTIBLE.include?(row.outcome)
            return failure("book #{@book.id} is #{row.outcome}; only #{REVERTIBLE.join(", ")} can be reverted")
          end

          ::ActiveRecord::Base.transaction do
            restore_work_keys(row.old_keys)
            @book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY, value: row.duplicate_keys).destroy_all
            Array(row.author_changes["added"]).each do |author_id, key|
              ::Identifier.where(identifiable_type: "Books::Author", identifiable_id: author_id,
                identifier_type: :books_author_openlibrary_id, value: key).destroy_all
            end
            row.update!(outcome: :reverted)
          end
          Result.new(success?: true, data: row, errors: [])
        end

        private

        def restore_work_keys(old_keys)
          held = @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY)
          held.where.not(value: old_keys).destroy_all
          (old_keys - held.reload.pluck(:value)).each do |key|
            @book.identifiers.create!(identifier_type: ApplyBook::WORK_KEY, value: key)
          end
        end

        def failure(message) = Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
```

`web-app/app/lib/services/books/ol_backfill/report.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 4, books:ol_backfill_report: lines of text the rake task prints.
      class Report
        RECENT = 20

        def self.call
          new.call
        end

        def call
          lines = ["Open Library backfill", "", "Outcomes:"]
          counts = rows.group(:outcome).count
          ::Books::OpenLibraryBackfill.outcomes.each_key { |outcome| lines << format("  %-15s %d", outcome, counts.fetch(outcome, 0)) }
          lines << ""
          lines << ranked_line
          lines << latest_run_line
          lines << author_line
          lines << ""
          lines << "Most recent replaced keys and pairs:"
          lines.concat(recent_lines)
          lines
        end

        private

        def rows = ::Books::OpenLibraryBackfill.all

        def ranked_line
          config = ::Books::RankingConfiguration.default_primary
          ranked = ::RankedItem.where(ranking_configuration_id: config&.id, item_type: "Books::Book").where.not(rank: nil)
          checked = rows.where(book_id: ranked.select(:item_id)).where.not(outcome: :failed).count
          "Ranked books checked: #{checked} of #{ranked.count}"
        end

        def latest_run_line
          latest = rows.order(updated_at: :desc, id: :desc).first
          return "Latest run: none" unless latest

          "Latest run #{latest.run_id}: #{rows.where(run_id: latest.run_id).count} books, last at #{latest.updated_at.iso8601}"
        end

        def author_line
          totals = %w[added pairs conflicts].map do |part|
            rows.sum(Arel.sql("jsonb_array_length(COALESCE(author_changes->'#{part}', '[]'::jsonb))")).to_i
          end
          format("Author keys added: %d, author pairs: %d, author conflicts: %d", *totals)
        end

        def recent_lines
          recent = rows.where(outcome: %i[replaced duplicate_pair]).includes(:book).order(updated_at: :desc, id: :desc).limit(RECENT)
          return ["  none"] if recent.empty?

          recent.map do |row|
            pair = row.pair_book_id ? " (pair with book #{row.pair_book_id})" : ""
            "  #{row.outcome} book #{row.book_id} \"#{row.book.title}\": #{row.old_keys.join(", ").presence || "no key"} -> #{row.new_key}#{pair}"
          end
        end
      end
    end
  end
end
```

`web-app/lib/tasks/books/ol_backfill.rake`:

```ruby
# frozen_string_literal: true

namespace :books do
  desc "Open Library key backfill: queue one run over <count> books (ranked first) or all; add ,retry_unsure to retry unsure books from an older Open Library version"
  task :ol_backfill, [:limit, :mode] => :environment do |_task, args|
    usage = "usage: books:ol_backfill[<count>|all] or books:ol_backfill[<count>|all,retry_unsure]"
    limit = case args[:limit]
    when "all" then nil
    when /\A[1-9]\d*\z/ then args[:limit].to_i
    else abort usage
    end
    retry_unsure = case args[:mode]
    when nil then false
    when "retry_unsure" then true
    else abort usage
    end

    run_id = SecureRandom.uuid
    Books::OpenLibraryBackfillJob.perform_async(limit, run_id, retry_unsure)
    puts "queued Open Library backfill run #{run_id}: #{limit || "all"} books#{" (retrying unsure books)" if retry_unsure}. " \
      "Progress: bin/rails books:ol_backfill_report"
  end

  desc "Open Library key backfill: outcome counts, ranked coverage, the latest run, and the most recent replaced keys and pairs"
  task ol_backfill_report: :environment do
    puts Services::Books::OlBackfill::Report.call
  end

  desc "Open Library key backfill: put one book's keys back the way they were: books:ol_backfill_revert[<book id>]"
  task :ol_backfill_revert, [:book_id] => :environment do |_task, args|
    book = Books::Book.find_by(id: args[:book_id])
    abort "usage: books:ol_backfill_revert[<book id>] -- no book #{args[:book_id].inspect}" unless book

    result = Services::Books::OlBackfill::Revert.call(book: book)
    abort result.errors.join("; ") unless result.success?

    puts "reverted book #{book.id}: work keys back to #{result.data.old_keys.inspect}"
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/books/ol_backfill/ test/lib/tasks/books_ol_backfill_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the feature doc**

`docs/features/open-library-backfill.md`:

````markdown
# Open Library key backfill

Checks or adds an Open Library work key on every book, ranked books first, and gives authors keys
along the way. Spec: `docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md`.

## Running it

```bash
bin/rails "books:ol_backfill[100]"                 # one run of 100 books, ranked first
bin/rails "books:ol_backfill[all]"                 # everything not yet done (about a week)
bin/rails "books:ol_backfill[100,retry_unsure]"    # also retry unsure books from an older OL version
bin/rails books:ol_backfill_report                 # outcome counts, ranked coverage, latest run, recent swaps
bin/rails "books:ol_backfill_revert[123]"          # put book 123's keys back
```

Each run is one `Books::OpenLibraryBackfillJob` on the `low` queue. It works through books one at a
time: ranked books by rank, then by how many lists a book is on, then by id. A book with a log row is
never taken again, except a `failed` one (and an `unsure` one under `retry_unsure`). A deploy
requeues the job with its run id and it carries on. If Open Library fails for about 13 minutes on one
book, that book is logged `failed` and the run stops; run the task again later.

## One book

1. **Fast pass:** look up the book's ISBNs and Goodreads ids (`GET /identifiers`, about 0.16 s each).
   If they all point at one work, and its title and an author agree with ours, that is the answer.
2. **Full match:** otherwise one `POST /resolve` (12-13 s) with title, authors, year, ISBNs and the
   stored key as a hint. Acted on only for an `accept` that passes the same check.

Titles agree when equal after normalizing, or once a subtitle is dropped from one side (never both).
No AI is involved.

| Outcome | Meaning |
|---|---|
| `confirmed` | the stored key was right |
| `updated` | the stored key redirects to the answer; moved to the current key |
| `replaced` | the stored key was another work, or dead; swapped (old key in the log) |
| `keyed` | the book had no key; added |
| `duplicate_pair` | another book holds the answer; nothing saved, pair in Books → Duplicates |
| `unsure` | no confident, agreeing answer; nothing changed |
| `failed` | Open Library failing; retried by the next run |
| `reverted` | undone by `books:ol_backfill_revert`; never redone |

A full match also saves Open Library's duplicate works as `books_work_openlibrary_duplicate_id`. The
book finder treats a book holding the accepted work under that type as a candidate with no verdict.

Authors of a book that ends with a trusted key take the work's author keys: an author with no key
gets one; an author whose key another author holds becomes an author pair; an author with a different
key is left alone and counted as a conflict.

## The log

`books_open_library_backfills` (`Books::OpenLibraryBackfill`), one row per book: outcome, lookup
(`identifiers` or `resolve`), old and new keys, duplicate keys saved, pair book, author changes, the
Open Library dump date and matcher version, run id, attempts and error.

## Reading the report

Check the `replaced` and `duplicate_pair` lines: every replacement is a key the old code assigned and
Open Library contradicted. A wrong one is undone with the revert task. Pairs are reviewed in the
Duplicates queue like any other.
````

- [ ] **Step 6: Add the cutover step to `docs/launch-todo.md`**

In section 2, insert a new item after item 5 ("Stored-name normalization") and renumber the items after it (6 becomes 7, and so on; "see the next item" references stay correct):

```markdown
6. **Open Library key backfill.** Run `bin/rails "books:ol_backfill[100]"`, read
   `bin/rails books:ol_backfill_report`, then `bin/rails "books:ol_backfill[all]"`. It checks or adds an
   Open Library key on every book, ranked first, and takes about a week. It shares Open Library's one
   `/resolve` slot with the wizard and the Goodreads replay, so all of them slow down while it runs;
   none of them fail. Its log is keyed to book ids, so every migration pass starts it from scratch.
   Details: `docs/features/open-library-backfill.md`.
```

- [ ] **Step 7: Lint, loader check, focused tests**

Run: `bundle exec standardrb app/lib/services/books/ol_backfill app/sidekiq/books/open_library_backfill_job.rb app/models/books/open_library_backfill.rb lib/tasks/books/ol_backfill.rake test/lib/services/books/ol_backfill test/lib/tasks/books_ol_backfill_rake_test.rb test/support/ol_backfill_helper.rb && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; "All is good!".

- [ ] **Step 8: Commit**

```bash
git add app/lib/services/books/ol_backfill/report.rb app/lib/services/books/ol_backfill/revert.rb lib/tasks/books/ol_backfill.rake test/lib/services/books/ol_backfill/report_test.rb test/lib/services/books/ol_backfill/revert_test.rb test/lib/tasks/books_ol_backfill_rake_test.rb ../docs/features/open-library-backfill.md ../docs/launch-todo.md
git commit -m "OL backfill: rake tasks, report, revert, docs and the cutover step"
```

---

### After the tasks (controller, not a subagent)

1. Full suite: `bin/rails test` (no failures, no new warnings), `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`.
2. Measure on dev, per spec section 6:
   - `bin/snapshot-dev-db.sh --label pre-ol-backfill`
   - `bin/rails db:migrate` (development) if not already run
   - `bin/rails runner 'p Services::Books::OlBackfill::Run.call(limit: 200, run_id: "dev-measure-1").data'` against the live Open Library service (inline, so no Sidekiq is needed)
   - `bin/rails books:ol_backfill_report`
   - Hand-check every `replaced` and `duplicate_pair` row; record the outcome mix, time taken and hand-check results for the PR.
3. Whole-branch review, then ask before pushing.
