# Import finder redesign, increment 2 (books) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the books finder its real candidate sources (identifiers, exact, OpenSearch, the Open Library resolve service), let the Open Library provider reuse the finder's resolution, ship the duplicate sweep job, and normalize the stored titles and author names the save-time normalizer would change anyway.

**Architecture:** Increment 1 shipped the `FinderBase` pipeline (gather → rules → AI → record) with every finder's old lookup wrapped as a single decisive `Sources::Legacy` source. This increment replaces the books finder's `candidate_sources` with four real sources — the shared `Sources::Identifiers`, `Sources::Exact` and `Sources::OpenSearch` (over a new `Search::Books::Search::BookByTitleAndAuthors` query) plus a books-only `OpenLibrarySource` that calls `POST /resolve`, keeps the whole `Resolution` for the provider, and reports which local books already hold each returned work key. The rules and the AI step are untouched except for one reading of rule 4 (below). A `Books::FindDuplicatesJob` on the `serial` queue resolves each ranked book against the rest of the catalog with `verify: true, exclude: book` and flags matches as `bulk_verify` pairs. A one-off service normalizes stored names in place and flags the collisions that fall out.

**Tech Stack:** Rails 8 (`web-app/`), Postgres, OpenSearch (`Search::Base::Search` subclasses), the Open Library data service via `Books::OpenLibrary::Client` (Faraday, WebMock in tests), Sidekiq (`serial` capsule), Minitest 6 + fixtures + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` — §1 contract, §2 sources, §3 rules, §8 books, §14 failures, §15 testing, §16 the duplicate sweep, plus "Decisions made during brainstorming". The feature doc `docs/features/import-finder.md` describes what increment 1 built; `docs/features/open-library-data-service.md` ("Rails client (Increment 5)") describes the client this increment calls.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **The finder never creates or mutates catalog records and is not transactional** (spec §1). Only the provider, the importer, the sweep's `Flag` call and the one-off service write.
- **Identifiers are evidence, not verdicts** (spec §3): rules 0–2 never fire under `verify: true`, and every source runs under `verify`.
- **Postgres and OpenSearch, no tsvector** (spec decisions). The `lower(title)` / `lower(name)` expression indexes from increment 1 serve the exact source; every exact comparison is `LOWER(column) = <normalized, downcased query>`.
- **Sources expose `#name` and `#call` with no arguments** and return `[DataImporters::Candidate]`. A source that responds to `#resolution` after `#call` has it copied onto the match. A source that raises is a failed source (the finder rescues it and caps `high` at `medium`); an `ActiveRecord::ActiveRecordError` propagates.
- **Never define a module named `Sources` under `DataImporters::Books::Book`.** `DataImporters::Sources` is the shared module; a nested one would shadow it (nested-namespace shadowing). The books-only source is `DataImporters::Books::Book::OpenLibrarySource`, and every reference to a shared source is fully qualified (`DataImporters::Sources::Exact`).
- **Rules are decided in `DataImporters::Decider`; evidence is described in `FinderBase#describe_candidate`.** Domain finders override hooks (`query_creators`, `record_creators`, `record_creator_alternate_names`, `record_year`, `creators_required?`, `domain_guidance`, `describe_candidate`), never the stages.
- **Skinny models, fat services.** New logic goes under `app/lib/services/books/`, `app/lib/data_importers/books/book/` or `app/sidekiq/books/`; rake tasks are thin wrappers that print. Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Bulk Open Library calls are serialized:** the sweep job carries `sidekiq_options queue: :serial` (one `/resolve` at a time saturates the service).
- **The one-off normalization writes to the shared development database.** Implementers and reviewers run only its tests and its `report` (read-only) task; nobody runs `apply` against development. Shane runs `apply` himself.
- **Tests:** Minitest 6 (`assert_nil`, never `assert_equal nil`), fixtures by semantic name (`books_books(:war_and_peace)`, `books_authors(:tolstoy)`, `identifiers(:crime_and_punishment_openlibrary)`), Mocha for stubs, WebMock `stub_request` for the Open Library service (the pattern in `test/lib/data_importers/books/book/providers/open_library_test.rb`), `Sidekiq.testing!(:inline)` globally with `Sidekiq::Testing.fake! { }` to assert enqueues. Never test private methods. A clean `bin/rails test` emits no new warning lines.
- After every task: `bundle exec standardrb <changed files>` clean, the task's tests green, and `CI=1 bin/rails zeitwerk:check` clean whenever a new directory appears under `app/lib`.
- Commit after every task with a message that ends in `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never commit to `main`.

## Rulings this plan makes (spec readings the implementer must follow)

1. **Rule 4 counts exact-matching locals, not all locals.** Spec §3 rule 4 reads "exactly one local candidate with equal normalized title, agreeing creators, and no year conflict". Increment 1 implemented "exactly one local candidate, and it matches exactly". With fuzzy sources on, OpenSearch returns neighbours on nearly every query, so that reading would send almost every import to the AI. Task 2 changes `Decider#exact_decision` to "exactly one local candidate satisfies `exact_match?`, and no other local candidate carries an identifier hit"; two exact locals still go to the AI (they are the duplicate case), and so does the wrong-identifier case spec §15 names (an identifier hit on a record whose title and creators both disagree must reach the AI, never a rule).
2. **`alternate_titles` sits inside the title `must` group** of `BookByTitleAndAuthors`, not among the optional boosts. Spec §7 says the merger folds a merged-away title into `alternate_titles` "which is what makes a merged-away wrong 'new' findable by OpenSearch next time"; that only holds if an alternate-title hit can satisfy the title requirement.
3. **The Open Library source looks up local holders of a work key and of every key in the work's `redirected_from` list.** Spec "Deferred" keeps the *backfill* of stale keys out of scope; using the redirect list the service already returns on each candidate costs one `IN` clause and finds a local book that holds a superseded key.
4. **The one-off normalization covers every row the save-time normalizer would change**, not only the 365 books with exotic spaces the spec names. Measured on the development database on 2026-09-23 (Task 8 records the numbers): 1,965 of 158,220 titles and 3,436 of 71,083 author names change, almost all whitespace folds (runs, trailing and zero-width spaces) or NFC accent composition. The exact source compares the *normalized* query against the *stored* value, so an unnormalized stored row is invisible to it until it is saved once.
5. **`U+00B4` (acute accent used as an apostrophe) joins `QuoteNormalizer`.** NFKC maps it to a space plus a combining accent, turning `O´Hanlon` into `O ́Hanlon`; two rows hit it. Mapping it to `'` first is the fix (Task 1).
6. **The sweep is one job per book**, enqueued in rank order by a class method, not one job that loops for days: a Sidekiq restart then loses at most one book, and a re-run is idempotent for pairs (never re-raise) even though it writes a fresh `match_decisions` row per book.
7. **Pairs the one-off raises use source `bulk_verify`** with an evidence `reason` naming the normalization; no new enum value.
8. **The provider reuses `match.external_resolution` only for a new book** (`!book.persisted?`); a persisted book under `force_providers` resolves from its own state as today (spec §8).

## File structure

| File | Responsibility |
|---|---|
| `web-app/app/lib/services/text/quote_normalizer.rb` (modify) | adds `U+00B4` → `'` |
| `web-app/app/lib/data_importers/decider.rb` (modify) | rule 4 counts exact-matching locals |
| `web-app/app/lib/data_importers/finder_base.rb` (modify) | `record_extra_evidence` hook merged into candidate evidence |
| `web-app/app/lib/search/books/search/book_by_title_and_authors.rb` (create) | the OpenSearch dedup query |
| `web-app/app/lib/data_importers/books/book/open_library_source.rb` (create) | `/resolve` as a candidate source; keeps the `Resolution`; local holders |
| `web-app/app/lib/data_importers/books/book/finder.rb` (rewrite) | four real sources, the hooks, no legacy lookup |
| `web-app/app/lib/data_importers/books/book/providers/open_library.rb` (modify) | reuse `match.external_resolution` for a new book |
| `web-app/app/lib/services/duplicate_candidates/flag.rb` (modify) | nil-id guard; one retry on `RecordNotUnique` |
| `web-app/app/sidekiq/books/find_duplicates_job.rb` (create, via generator) | one book per job on `serial`; `enqueue_ranked` |
| `web-app/lib/tasks/books/duplicates.rake` (create) | `books:find_duplicates[limit]` |
| `web-app/app/lib/services/books/normalize_stored_names.rb` (create) | report and apply the normalization; flag collisions |
| `web-app/lib/tasks/books/normalize_names.rake` (create) | `books:normalize_names:report`, `books:normalize_names:apply` |
| `docs/data-quality/books-normalizer-effect.md` (create) | the measurement |
| `docs/features/import-finder.md`, `docs/features/data_importers.md`, `docs/features/open-library-data-service.md`, the spec (modify) | Task 9 |

---

### Task 1: `QuoteNormalizer` folds the acute accent used as an apostrophe

**Files:**
- Modify: `web-app/app/lib/services/text/quote_normalizer.rb`
- Test: `web-app/test/lib/services/text/quote_normalizer_test.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Services::Text::QuoteNormalizer.call("O´Hanlon") == "O'Hanlon"`. `Books::Book#normalize_title` and `Books::Author#normalize_name` already chain `NameNormalizer.call(QuoteNormalizer.call(x))`, so the fix reaches every save and the finder's `normalize`.

- [ ] **Step 1: Write the failing tests**

Open `web-app/test/lib/services/text/quote_normalizer_test.rb` (it exists; keep its module/class shape) and add:

```ruby
    test "folds the acute accent used as an apostrophe to a straight apostrophe" do
      assert_equal "Ardal O'Hanlon", Services::Text::QuoteNormalizer.call("Ardal O´Hanlon")
      assert_equal "Nobody's Children", Services::Text::QuoteNormalizer.call("Nobody´s Children")
    end

    test "the acute accent is folded before NFKC would split it into a space and a combining mark" do
      normalized = Services::Text::NameNormalizer.call(Services::Text::QuoteNormalizer.call("Ardal O´Hanlon"))

      assert_equal "Ardal O'Hanlon", normalized
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/text/quote_normalizer_test.rb`
Expected: the two new tests FAIL (`O´Hanlon` comes back unchanged; the second yields `"Ardal O ́Hanlon"`).

- [ ] **Step 3: Add the constant and the substitution**

In `web-app/app/lib/services/text/quote_normalizer.rb`:

```ruby
      LEFT_SINGLE_QUOTE = "‘"
      RIGHT_SINGLE_QUOTE = "’"
      # U+00B4 ACUTE ACCENT is used as an apostrophe in a few stored names
      # ("Ardal O´Hanlon"). NFKC turns it into a space plus a combining acute
      # accent ("O ́Hanlon"), so it must be folded before NameNormalizer runs.
      ACUTE_ACCENT = "´"
      LEFT_DOUBLE_QUOTE = "“"
```

and in `call`, after the two single-quote substitutions:

```ruby
          .gsub(ACUTE_ACCENT, STRAIGHT_APOSTROPHE)
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/text/ test/models/books/`
Expected: PASS, no new warnings.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/text/quote_normalizer.rb test/lib/services/text/quote_normalizer_test.rb
git add app/lib/services/text/quote_normalizer.rb test/lib/services/text/quote_normalizer_test.rb
git commit -m "QuoteNormalizer folds the acute accent used as an apostrophe" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Rule 4 counts exact-matching local candidates

**Files:**
- Modify: `web-app/app/lib/data_importers/decider.rb` (`exact_decision`)
- Test: `web-app/test/lib/data_importers/decider_test.rb`
- Modify: `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` ("Decisions made during brainstorming")

**Interfaces:**
- Consumes: `finder.exact_match?(query, candidate)` (unchanged).
- Produces: rule 4 fires when exactly one local candidate satisfies `exact_match?`, whatever else is in the candidate list.

- [ ] **Step 1: Write the failing test**

In `web-app/test/lib/data_importers/decider_test.rb`, replace the test named `"rule 4 does not fire for two local candidates, or for one that is not exact"` with these two:

```ruby
    test "rule 4 fires when exactly one of several local candidates matches exactly" do
      finder = FakeFinder.new(exact: ->(candidate) { candidate.record == @book })

      decision = decide([Candidate.new(record: @other, sources: [:opensearch]), Candidate.new(record: @book, sources: [:exact])], finder: finder)

      assert_equal [:matched, @book, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
    end

    test "rule 4 does not fire for two exact local candidates, or for one that is not exact" do
      assert_nil decide([Candidate.new(record: @book, sources: [:exact]), Candidate.new(record: @other, sources: [:exact])], finder: FakeFinder.new(exact: true))
      assert_nil decide([Candidate.new(record: @book, sources: [:opensearch])], finder: FakeFinder.new(exact: false))
    end

    test "rule 4 does not fire while another local candidate carries an uncorroborated identifier hit: the AI decides" do
      finder = FakeFinder.new(corroborated: false, exact: ->(candidate) { candidate.record == @book })

      assert_nil decide([identifier_candidate(@other), Candidate.new(record: @book, sources: [:exact])], finder: finder)
    end
```

- [ ] **Step 2: Run to verify the first and third fail**

Run: `bin/rails test test/lib/data_importers/decider_test.rb`
Expected: `rule 4 fires when exactly one of several local candidates matches exactly` FAILS (`nil` decision); the uncorroborated-identifier test passes for the wrong reason today (two locals); it must still pass after Step 3.

- [ ] **Step 3: Change the rule**

In `web-app/app/lib/data_importers/decider.rb` replace `exact_decision` with:

```ruby
    # Rule 4: exactly one local candidate matches exactly (equal normalized
    # title, agreeing creators where the domain has them, no year conflict).
    # Other, non-exact locals do not block it; two exact locals do, because
    # that is the duplicate case and the AI flags the pair. So does an
    # identifier hit on some other local record: a wrong identifier must
    # reach the AI, never be settled by a rule (spec §15).
    def exact_decision
      exact = @candidates.select { |c| c.local? && @finder.exact_match?(@query, c) }
      return nil unless exact.size == 1

      candidate = exact.first
      return nil if @candidates.any? { |c| c.local? && c.sources.include?(:identifier) && !c.equal?(candidate) }

      matched(candidate.record, :high, :rule, "exact title and creator match on #{label(candidate)}",
        external: (candidate.external? ? candidate : nil))
    end
```

- [ ] **Step 4: Run the Decider, FinderBase and every finder test**

Run: `bin/rails test test/lib/data_importers`
Expected: PASS. (Increment 1's finders route everything through the legacy source, so nothing else moves.)

- [ ] **Step 5: Record the reading in the spec**

Append to the "Decisions made during brainstorming" list at the end of `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md`:

```markdown
- **Rule 4 counts exact-matching locals** (declared in increment 2): the rule fires when exactly one local candidate passes the exact test, whatever else the fuzzy sources returned; two exact locals go to the AI. Increment 1 had read it as "exactly one local candidate, and it is exact", which would have sent nearly every import with an OpenSearch neighbour to the AI.
```

Also update `docs/features/import-finder.md`, stage 2, item 4, from `4 one local candidate that matches exactly → matched high` to `4 exactly one local candidate that matches exactly (other, non-exact locals do not block it) → matched high`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/decider.rb test/lib/data_importers/decider_test.rb
git add app/lib/data_importers/decider.rb test/lib/data_importers/decider_test.rb docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md docs/features/import-finder.md
git commit -m "Rule 4 fires on the one exact local candidate, not on a lone local" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 3: `Search::Books::Search::BookByTitleAndAuthors`

**Files:**
- Create: `web-app/app/lib/search/books/search/book_by_title_and_authors.rb`
- Test: `web-app/test/lib/search/books/search/book_by_title_and_authors_test.rb`

**Interfaces:**
- Consumes: `Search::Books::BookIndex` (fields `title`, `title.keyword`, `alternate_titles`, `author_names`, `first_published_year`); `Search::Shared::Utils` builders.
- Produces: `Search::Books::Search::BookByTitleAndAuthors.call(title:, authors: [], year: nil, **options) -> [{id:, score:, source:}]`. `options[:size]`, `options[:from]`, `options[:min_score]` as the other dedup queries. Default `min_score` is `5.0` with authors and `8.0` without.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/search/books/search/book_by_title_and_authors_test.rb`, following `book_general_test.rb` (real index, `cleanup_test_index`, `sleep(0.1)` after indexing):

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookByTitleAndAuthorsTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def index(*books)
          books.each { |book| ::Search::Books::BookIndex.index(book) }
          sleep(0.1)
        end

        test "index_name delegates to BookIndex" do
          assert_equal ::Search::Books::BookIndex.index_name, ::Search::Books::Search::BookByTitleAndAuthors.index_name
        end

        test "returns an empty array for a blank title without searching" do
          ::Search::Books::Search::BookByTitleAndAuthors.expects(:search).never

          assert_equal [], ::Search::Books::Search::BookByTitleAndAuthors.call(title: "", authors: ["Leo Tolstoy"])
          assert_equal [], ::Search::Books::Search::BookByTitleAndAuthors.call(title: nil)
        end

        test "finds a book by title and author" do
          book = books_books(:war_and_peace)
          index(book, books_books(:crime_and_punishment))

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace", authors: ["Leo Tolstoy"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
          assert results[0][:score] > 0
        end

        test "finds a book whose alternate title is the query title" do
          book = books_books(:war_and_peace)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Voyna i mir", authors: ["Leo Tolstoy"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end

        test "authors are optional: a title-only query still finds the book" do
          book = books_books(:war_and_peace)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace")

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end

        test "a title-only query uses a higher minimum score than a title-plus-authors query" do
          definition = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", [], nil, nil, 5, 0)
          with_authors = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", ["Leo Tolstoy"], nil, nil, 5, 0)

          assert_equal 8.0, definition[:min_score]
          assert_equal 5.0, with_authors[:min_score]
        end

        test "an explicit min_score overrides the default" do
          definition = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", [], nil, 2.5, 5, 0)

          assert_equal 2.5, definition[:min_score]
        end

        test "a year within one of the query year ranks first among same-titled books" do
          old = ::Books::Book.create!(title: "Dune", first_published_year: 1965)
          reissue = ::Books::Book.create!(title: "Dune", first_published_year: 2021)
          index(old, reissue)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Dune", year: 2020)

          assert_equal [reissue.id.to_s, old.id.to_s], results.map { |hit| hit[:id] }
        end

        test "a wrong author does not exclude a title match" do
          book = books_books(:war_and_peace)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace", authors: ["Someone Else"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end

        test "respects size" do
          index(books_books(:got), books_books(:clash))

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "A Game of Thrones", authors: ["Stephen King"], size: 1)

          assert_equal 1, results.size
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/search/books/search/book_by_title_and_authors_test.rb`
Expected: FAIL with `NameError: uninitialized constant Search::Books::Search::BookByTitleAndAuthors`.

- [ ] **Step 3: Write the query class**

Create `web-app/app/lib/search/books/search/book_by_title_and_authors.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      # The books finder's OpenSearch source: candidates for "is this
      # title (by these authors, from this year) already in the catalog?".
      # The title, or an alternate title, is required; authors and year are
      # boosts. A title-only query is held to a higher minimum score because
      # a bare title is ambiguous in books.
      class BookByTitleAndAuthors < ::Search::Base::Search
        MIN_SCORE_WITH_AUTHORS = 5.0
        MIN_SCORE_TITLE_ONLY = 8.0

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(title:, authors: [], year: nil, **options)
          return empty_response if title.blank?

          authors = Array(authors).compact_blank
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(title, authors, year, options[:min_score], size, from)

          Rails.logger.info "Book title+authors search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(title, authors, year, min_score, size, from)
          cleaned_title = ::Search::Shared::Utils.normalize_search_text(title)
          min_score ||= authors.any? ? MIN_SCORE_WITH_AUTHORS : MIN_SCORE_TITLE_ONLY

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              must: [
                ::Search::Shared::Utils.build_bool_query(
                  should: build_title_clauses(cleaned_title),
                  minimum_should_match: 1
                )
              ],
              should: build_author_clauses(authors) + build_year_clauses(year)
            )
          }
        end

        # alternate_titles is inside the required group on purpose: the
        # merger folds a merged-away title into it so the deleted spelling
        # stays findable here.
        def self.build_title_clauses(cleaned_title)
          [
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_title, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_title.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("title", cleaned_title, boost: 8.0, operator: "and"),
            ::Search::Shared::Utils.build_match_phrase_query("alternate_titles", cleaned_title, boost: 7.0),
            ::Search::Shared::Utils.build_match_query("alternate_titles", cleaned_title, boost: 6.0, operator: "and")
          ]
        end

        def self.build_author_clauses(authors)
          authors.flat_map do |author_name|
            cleaned_author = ::Search::Shared::Utils.normalize_search_text(author_name)
            next [] if cleaned_author.blank?

            [
              ::Search::Shared::Utils.build_match_phrase_query("author_names", cleaned_author, boost: 6.0),
              ::Search::Shared::Utils.build_match_query("author_names", cleaned_author, boost: 5.0, operator: "and")
            ]
          end
        end

        def self.build_year_clauses(year)
          return [] if year.blank?

          [{range: {first_published_year: {gte: year.to_i - 1, lte: year.to_i + 1, boost: 2.0}}}]
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_title_clauses, :build_author_clauses, :build_year_clauses
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/search/books/search/book_by_title_and_authors_test.rb`
Expected: PASS. If the year test's order is not deterministic, add `sleep(0.1)` is not the fix — check that both books indexed (`::Search::Books::BookIndex` requires `authors` etc. via `model_includes`; `create!` books have none, which is fine) and that the range boost is in the outer `should`.

- [ ] **Step 5: Lint, zeitwerk, commit**

```bash
bundle exec standardrb app/lib/search/books/search/book_by_title_and_authors.rb test/lib/search/books/search/book_by_title_and_authors_test.rb
CI=1 bin/rails zeitwerk:check
git add app/lib/search/books/search/book_by_title_and_authors.rb test/lib/search/books/search/book_by_title_and_authors_test.rb
git commit -m "Search: BookByTitleAndAuthors, the books finder's OpenSearch query" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `DataImporters::Books::Book::OpenLibrarySource`

**Files:**
- Create: `web-app/app/lib/data_importers/books/book/open_library_source.rb`
- Test: `web-app/test/lib/data_importers/books/book/open_library_source_test.rb`

**Interfaces:**
- Consumes: `Books::OpenLibrary::Client#resolve(title:, author_names:, year:, isbn13:, isbn10:, asin:, goodreads_id:, existing_ol_key:, limit:) -> Resolution`; `Resolution#candidates -> [Books::OpenLibrary::Candidate]` (`work_key`, `score`, `margin`, `rules`, `verdict`, `record -> Work | nil`); `Work#title`, `#author_names`, `#year_evidence` (symbol keys `declared_year`, `min_edition_year`, …), `#redirected_from`; `DataImporters::Candidate`; `Identifier` rows of type `books_work_openlibrary_id`.
- Produces: `OpenLibrarySource.new(query:, client: nil, limit: 5)`; `#name -> :open_library`; `#call -> [Candidate]`; `#resolution -> Books::OpenLibrary::Resolution | nil` (set by `#call`). One `Candidate` per local book holding the work key (or a key it redirects from), each carrying both halves; an external-only `Candidate` when no local book holds it. Evidence keys: external-only candidates carry `title`, `creators`, `year`; holder candidates carry `external_title`, `external_creators`, `external_year` instead (the finder fills `title`/`creators`/`year` from the local record); every candidate carries `external_verdict`, `external_score`, `external_margin`, `external_rules`.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/data_importers/books/book/open_library_source_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class OpenLibrarySourceTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          @client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:sources:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @held_key = identifiers(:crime_and_punishment_openlibrary).value # "OL262758W", held by crime_and_punishment
        end

        def source(query, limit: 5)
          OpenLibrarySource.new(query: query, client: @client, limit: limit)
        end

        def query(**attributes)
          ImportQuery.new(**{title: "Crime and Punishment", author_names: ["Fyodor Dostoevsky"]}.merge(attributes))
        end

        def work_record(key:, title:, authors: ["Fyodor Dostoevsky"], declared_year: 1866, redirected_from: [])
          {
            "key" => {"source" => "openlibrary", "key" => key},
            "title" => title,
            "subtitle" => nil,
            "description" => nil,
            "authors" => authors.each_with_index.map { |name, i| {"key" => {"source" => "openlibrary", "key" => "OL#{i}A"}, "name" => name} },
            "subjects" => [],
            "year_evidence" => {"declared_year" => declared_year, "min_edition_year" => 1917},
            "popularity" => nil,
            "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} }
          }
        end

        def candidate_hash(key:, verdict:, score:, record:, rules: ["title_author"], margin: 0.2)
          {"key" => {"source" => "openlibrary", "key" => key}, "score" => score, "rules" => rules, "margin" => margin,
           "verdict" => verdict, "evidence" => {}, "conflicts" => [], "diff" => [], "record" => record}
        end

        def resolve_response(verdict:, key: nil, candidates: [], reason: "test")
          {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "decision" => {"verdict" => verdict, "key" => (key && {"source" => "openlibrary", "key" => key}), "score" => 0.9, "margin" => 0.3, "reason" => reason},
              "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => candidates
            }
          }
        end

        def stub_resolve(body, &request_check)
          stub = stub_request(:post, "#{BASE_URL}/resolve")
          stub = stub.with(&request_check) if request_check
          stub.to_return(status: 200, body: body.to_json)
        end

        test "name is :open_library" do
          assert_equal :open_library, source(query).name
        end

        test "sends the query's fields, the work key as existing_ol_key and the limit" do
          stub_resolve(resolve_response(verdict: "abstain")) do |request|
            body = JSON.parse(request.body)
            body == {"title" => "Crime and Punishment", "author_names" => ["Fyodor Dostoevsky"], "year" => 1866,
                     "isbn13" => ["9780140449136"], "existing_ol_key" => "OL262758W", "limit" => 5}
          end

          candidates = source(query(year: 1866, isbn13: ["9780140449136"], open_library_work_key: "OL262758W")).call

          assert_equal [], candidates
        end

        test "a blank title is sent as an empty string for an identifier-only query" do
          stub_resolve(resolve_response(verdict: "abstain")) { |request| JSON.parse(request.body)["title"] == "" }

          source(ImportQuery.new(title: nil, isbn13: ["9780140449136"])).call

          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "a work nobody holds locally is one external-only candidate with the work's title, authors and year as evidence" do
          record = work_record(key: "OL999W", title: "Crime & Punishment", declared_year: nil)
          stub_resolve(resolve_response(verdict: "abstain", candidates: [candidate_hash(key: "OL999W", verdict: "abstain", score: 0.55, record: record)]))

          candidates = source(query).call

          assert_equal 1, candidates.size
          candidate = candidates.first
          assert_not candidate.local?
          assert_equal ["OL999W", :open_library, [:open_library], {open_library: 0.55}],
            [candidate.external_key, candidate.external_source, candidate.sources, candidate.scores]
          assert_equal "Crime & Punishment", candidate.evidence[:title]
          assert_equal ["Fyodor Dostoevsky"], candidate.evidence[:creators]
          assert_equal 1917, candidate.evidence[:year], "falls back to min_edition_year when declared_year is absent"
          assert_equal ["abstain", 0.55, 0.2, ["title_author"]],
            candidate.evidence.values_at(:external_verdict, :external_score, :external_margin, :external_rules)
          assert_instance_of ::Books::OpenLibrary::Candidate, candidate.external_record
        end

        test "a work a local book holds becomes one candidate carrying both halves, with the external facts under external_ keys" do
          record = work_record(key: @held_key, title: "Crime and Punishment")
          stub_resolve(resolve_response(verdict: "accept", key: @held_key, candidates: [candidate_hash(key: @held_key, verdict: "accept", score: 0.93, record: record)]))

          candidates = source(query).call

          assert_equal 1, candidates.size
          candidate = candidates.first
          assert_equal books_books(:crime_and_punishment), candidate.record
          assert_equal @held_key, candidate.external_key
          assert candidate.external_accepted?
          assert_equal "Crime and Punishment", candidate.evidence[:external_title]
          assert_equal 1866, candidate.evidence[:external_year]
          assert_nil candidate.evidence[:title], "the finder fills title from the local record"
        end

        test "two local books holding the same key are two candidates, in id order" do
          other = books_books(:war_and_peace)
          other.identifiers.create!(identifier_type: :books_work_openlibrary_id, value: @held_key)
          record = work_record(key: @held_key, title: "Crime and Punishment")
          stub_resolve(resolve_response(verdict: "accept", key: @held_key, candidates: [candidate_hash(key: @held_key, verdict: "accept", score: 0.93, record: record)]))

          candidates = source(query).call

          assert_equal [books_books(:crime_and_punishment), other].sort_by(&:id), candidates.map(&:record)
          assert_equal [@held_key, @held_key], candidates.map(&:external_key)
        end

        test "a local book holding a key the work redirects from is a holder of the work" do
          record = work_record(key: "OL1000W", title: "Crime and Punishment", redirected_from: [@held_key])
          stub_resolve(resolve_response(verdict: "abstain", candidates: [candidate_hash(key: "OL1000W", verdict: "abstain", score: 0.6, record: record)]))

          candidates = source(query).call

          assert_equal [books_books(:crime_and_punishment)], candidates.map(&:record)
          assert_equal ["OL1000W"], candidates.map(&:external_key)
        end

        test "keeps the whole resolution for the provider" do
          stub_resolve(resolve_response(verdict: "reject", reason: "no candidate"))
          s = source(query)

          assert_nil s.resolution
          s.call

          assert s.resolution.reject?
          assert_equal "no candidate", s.resolution.decision.reason
        end

        test "returns at most the candidates the service returned, in the service's order" do
          records = [["OL1W", 0.9], ["OL2W", 0.7]].map { |key, score| candidate_hash(key: key, verdict: "abstain", score: score, record: work_record(key: key, title: "Crime and Punishment")) }
          stub_resolve(resolve_response(verdict: "abstain", candidates: records))

          assert_equal %w[OL1W OL2W], source(query).call.map(&:external_key)
        end

        test "a service error propagates so the finder records the source as failed" do
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "boom")

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { source(query).call }
        end
      end
    end
  end
end
```

Check the fixture ISBN literal against `test/fixtures/identifiers.yml` before running (the value above is illustrative for the request body; any string works because the service is stubbed).

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/open_library_source_test.rb`
Expected: FAIL with `NameError: uninitialized constant DataImporters::Books::Book::OpenLibrarySource`.

- [ ] **Step 3: Write the source**

Create `web-app/app/lib/data_importers/books/book/open_library_source.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # The books finder's external source: one POST /resolve on the Open
      # Library data service. Every returned work becomes a candidate with
      # the service's verdict, score, margin and rules as evidence; a work
      # whose key (or a key it redirects from) a local book already holds
      # becomes one candidate per holder, carrying both halves, so the
      # rules can treat "the service accepted a key we hold" as identity
      # evidence and two holders as a suspected pair. The whole Resolution
      # is kept for the provider (FinderBase copies it onto the match).
      #
      # Not a `Sources` module on purpose: DataImporters::Sources is the
      # shared one and a nested module of the same name would shadow it.
      class OpenLibrarySource
        attr_reader :resolution

        def initialize(query:, client: nil, limit: 5)
          @query = query
          @client = client
          @limit = limit
          @resolution = nil
        end

        def name
          :open_library
        end

        # Raises whatever the client raises (circuit open, timeout, HTTP,
        # parse): the finder records that as a failed source.
        def call
          @resolution = client.resolve(**resolve_args)
          @resolution.candidates.flat_map { |candidate| candidates_for(candidate) }
        end

        # Lazy: building the default client constructs a CircuitBreaker
        # against REDIS_POOL, and a test that injects its own must never
        # trigger that.
        def client
          @client ||= ::Books::OpenLibrary::Client.new
        end

        private

        def resolve_args
          {
            title: @query.title.to_s,
            author_names: @query.author_names,
            year: @query.year,
            isbn13: @query.isbn13,
            isbn10: @query.isbn10,
            asin: @query.asin,
            goodreads_id: @query.goodreads_id,
            existing_ol_key: @query.open_library_work_key,
            limit: @limit
          }
        end

        def candidates_for(ol_candidate)
          work = ol_candidate.record
          external = {
            external_verdict: ol_candidate.verdict,
            external_score: ol_candidate.score,
            external_margin: ol_candidate.margin,
            external_rules: ol_candidate.rules
          }
          holders = local_holders(ol_candidate.work_key, work)

          if holders.empty?
            [build(ol_candidate, external.merge(title: work&.title, creators: Array(work&.author_names), year: year_of(work)))]
          else
            evidence = external.merge(external_title: work&.title, external_creators: Array(work&.author_names), external_year: year_of(work))
            holders.map { |book| build(ol_candidate, evidence, record: book) }
          end
        end

        def build(ol_candidate, evidence, record: nil)
          Candidate.new(
            record: record,
            external_key: ol_candidate.work_key,
            external_source: :open_library,
            external_record: ol_candidate,
            sources: [:open_library],
            scores: {open_library: ol_candidate.score},
            evidence: evidence
          )
        end

        # Local books holding this work's key, or a key the service says
        # redirects to it (a stale local key still names the same work).
        def local_holders(work_key, work)
          keys = ([work_key] + Array(work&.redirected_from)).compact_blank.uniq
          ::Books::Book
            .joins(:identifiers)
            .where(identifiers: {identifier_type: ::Identifier.identifier_types[:books_work_openlibrary_id], value: keys})
            .distinct
            .order(:id)
            .to_a
        end

        # 89% of works carry no declared year; the earliest edition year is
        # the next best approximation of first publication.
        def year_of(work)
          evidence = work&.year_evidence || {}
          evidence[:declared_year] || evidence[:min_edition_year]
        end
      end
    end
  end
end
```

If `identifiers.identifier_type` is an integer enum column (check `Identifier.identifier_types`), the `where` above must use the integer as written; if `where(identifiers: {identifier_type: :books_work_openlibrary_id})` works with the enum in this Rails version, either form is acceptable — keep whichever the test proves.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/data_importers/books/book/open_library_source_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint, zeitwerk, commit**

```bash
bundle exec standardrb app/lib/data_importers/books/book/open_library_source.rb test/lib/data_importers/books/book/open_library_source_test.rb
CI=1 bin/rails zeitwerk:check
git add app/lib/data_importers/books/book/open_library_source.rb test/lib/data_importers/books/book/open_library_source_test.rb
git commit -m "Books finder: the Open Library resolve service as a candidate source" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 5: The books finder runs the four real sources

**Files:**
- Modify: `web-app/app/lib/data_importers/finder_base.rb` (add the `record_extra_evidence` hook)
- Rewrite: `web-app/app/lib/data_importers/books/book/finder.rb`
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb` (rewrite), `web-app/test/lib/data_importers/finder_base_test.rb` (one added test)
- Modify: `web-app/test/lib/data_importers/books/book/importer_test.rb` (stub the search class in `setup`)

**Interfaces:**
- Consumes: `DataImporters::Sources::Identifiers.new(model_class:, lookups: [[type_symbol, value], …])`, `DataImporters::Sources::Exact.new(scope:, limit: 5)`, `DataImporters::Sources::OpenSearch.new(model_class:, search_class:, params:, size:, min_score: nil, includes: [])`, `OpenLibrarySource.new(query:, client:, limit:)` (Task 4), `Search::Books::Search::BookByTitleAndAuthors.call(title:, authors:, year:, size:)` (Task 3), `FinderBase#normalize(text)` (private, returns the NFKC-and-quote-normalized, downcased text).
- Produces: `DataImporters::Books::Book::Finder.new(open_library_client: nil)`; `#call(query:, verify:, subject:, exclude:) -> Match` with candidates from all four sources; `FinderBase#record_extra_evidence(record) -> Hash` (protected hook, default `{}`), merged into every local candidate's evidence by `evidence_for`. Books returns `{book_kind:, alternate_titles:}`. `describe_candidate` appends `| collection` for a collection.

- [ ] **Step 1: Add the `record_extra_evidence` hook to FinderBase, with a test**

In `web-app/app/lib/data_importers/finder_base.rb`, in the protected hooks section after `record_identifiers`, add:

```ruby
    # Domain-specific facts worth showing the AI and keeping on the decision
    # (books: book_kind, alternate_titles). Merged into every local
    # candidate's evidence after the shared keys.
    def record_extra_evidence(_record)
      {}
    end
```

and change `evidence_for` to:

```ruby
    def evidence_for(record)
      {
        title: record_title(record),
        creators: record_creators(record),
        year: record_year(record),
        ranked_position: ranked_position(record),
        list_count: list_count(record),
        identifiers: record_identifiers(record)
      }.merge(record_extra_evidence(record))
    end
```

In `web-app/test/lib/data_importers/finder_base_test.rb`, next to the other hook tests, add (the file defines a test finder subclass; add the override on a one-off subclass):

```ruby
    test "record_extra_evidence is merged into a local candidate's evidence" do
      finder_class = Class.new(@finder.class) do
        def record_extra_evidence(record) = {kind: "extra-#{record.id}"}
      end
      finder = finder_class.new
      finder.sources = [FakeSource.new(:exact, candidates: [Candidate.new(record: @book, sources: [:exact])])]

      match = finder.call(query: @query)

      assert_equal "extra-#{@book.id}", match.candidates.first.evidence[:kind]
    end
```

Adapt the construction to however `@finder` and `FakeSource` are set up in that file (read its `setup` first; the test finder exposes `sources=`). Run `bin/rails test test/lib/data_importers/finder_base_test.rb` — green.

- [ ] **Step 2: Rewrite the finder test file**

Replace `web-app/test/lib/data_importers/books/book/finder_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class FinderTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"
        SEARCH = ::Search::Books::Search::BookByTitleAndAuthors

        def setup
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:finder:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @finder = Finder.new(open_library_client: client)
          @war_and_peace = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @task = stub("select_candidate_task")
          SEARCH.stubs(:call).returns([])
          stub_resolve(resolve_response(verdict: "abstain"))
        end

        # ---- helpers ----------------------------------------------------------

        def hit(book, score = 9.0)
          {id: book.id.to_s, score: score, source: {}}
        end

        def stub_ai(data)
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: data, ai_chat: ai_chats(:general_chat)))
        end

        def expect_no_ai
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).never
        end

        def work_record(key:, title:, authors: [], declared_year: nil, redirected_from: [])
          {
            "key" => {"source" => "openlibrary", "key" => key}, "title" => title, "subtitle" => nil, "description" => nil,
            "authors" => authors.each_with_index.map { |name, i| {"key" => {"source" => "openlibrary", "key" => "OL#{i}A"}, "name" => name} },
            "subjects" => [], "year_evidence" => {"declared_year" => declared_year}, "popularity" => nil,
            "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} }
          }
        end

        def ol_candidate(key:, verdict:, score:, record:)
          {"key" => {"source" => "openlibrary", "key" => key}, "score" => score, "rules" => ["title_author"], "margin" => 0.2,
           "verdict" => verdict, "evidence" => {}, "conflicts" => [], "diff" => [], "record" => record}
        end

        def resolve_response(verdict:, key: nil, candidates: [], reason: "test")
          {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "decision" => {"verdict" => verdict, "key" => (key && {"source" => "openlibrary", "key" => key}), "score" => 0.9, "margin" => 0.3, "reason" => reason},
              "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => candidates
            }
          }
        end

        def stub_resolve(body)
          WebMock.reset!
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: body.to_json)
        end

        # ---- identifiers (rule 1) ----------------------------------------------

        test "a corroborated Open Library key hit is a certain identifier match and stops gathering" do
          SEARCH.expects(:call).never
          expect_no_ai
          query = ImportQuery.new(title: "Crime and Punishment", open_library_work_key: identifiers(:crime_and_punishment_openlibrary).value)

          match = @finder.call(query: query)

          assert_equal [@crime, :certain, :identifier], [match.record, match.confidence, match.decided_by]
          assert_equal({type: "books_work_openlibrary_id", value: "OL262758W"}, match.candidates.first.evidence[:matched_identifier])
          assert_not_requested(:post, "#{BASE_URL}/resolve")
        end

        test "an identifier-only query is corroborated by definition: ISBN-13 and Goodreads hits are certain" do
          assert_equal @war_and_peace, @finder.call(query: ImportQuery.new(title: nil, isbn13: [identifiers(:war_and_peace_isbn13).value])).record
          assert_equal books_books(:of_mice_and_men), @finder.call(query: ImportQuery.new(title: nil, goodreads_id: [identifiers(:of_mice_and_men_goodreads).value])).record
        end

        test "an identifier hit whose record disagrees on title and creators is not decisive: gathering continues and the AI decides" do
          query = ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"], open_library_work_key: identifiers(:crime_and_punishment_openlibrary).value)
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "medium", reasoning: "The key is authoritative.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: query)

          assert_equal [@crime, :medium, :ai], [match.record, match.confidence, match.decided_by]
          assert match.needs_review?
          assert_equal [@crime, @war_and_peace], match.candidates.map(&:record)
          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "two books holding the same ISBN are an identifier collision: one is chosen and the pair is flagged" do
          value = identifiers(:war_and_peace_isbn13).value
          @crime.identifiers.create!(identifier_type: :books_work_isbn13, value: value)

          match = @finder.call(query: ImportQuery.new(title: nil, isbn13: [value]))

          assert_includes [@war_and_peace, @crime], match.record
          assert match.decision.certain?
          pair = DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@war_and_peace.id, @crime.id].min, item_b_id: [@war_and_peace.id, @crime.id].max)
          assert pair.raised_by_identifier_collision?
          assert_equal match.decision, pair.match_decision
        end

        # ---- exact (rule 4) ----------------------------------------------------

        test "an exact title and author match, case-insensitively, is a high-confidence rule match" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "war and peace", author_names: ["LEO TOLSTOY"]))

          assert_equal [@war_and_peace, :high, :rule], [match.record, match.confidence, match.decided_by]
          assert_includes match.candidates.first.sources, :exact
          assert_not match.needs_review?
        end

        test "an author's alternate name satisfies the exact source and the creator agreement" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Lev Tolstoy"]))

          assert_equal [@war_and_peace, :rule], [match.record, match.decided_by]
        end

        test "the query is normalized the way the models store titles and names" do
          author = ::Books::Author.create!(name: "Kathleen Alcott")
          book = ::Books::Book.create!(title: "The Secret Lives")
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)

          match = @finder.call(query: ImportQuery.new(title: "The Secret Lives", author_names: ["Kathleen Alcott"]))

          assert_equal book, match.record
        end

        test "a title with no author names is never an exact match: the candidate goes to the AI" do
          stub_ai({selected_index: 0, confidence: "low", reasoning: "Ambiguous.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War and Peace"))

          assert match.unmatched?
          assert_equal [@war_and_peace], match.candidates.map(&:record)
          assert_equal :ai, match.decided_by
        end

        test "the exact source's local candidate carries book_kind and alternate_titles as evidence" do
          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          candidate = match.candidates.first
          assert_equal ["standalone", ["Voyna i mir"]], candidate.evidence.values_at(:book_kind, :alternate_titles)
        end

        test "describe_candidate marks a collection" do
          combo = books_books(:combo_steinbeck)
          candidate = Candidate.new(record: combo, sources: [:exact], evidence: {title: combo.title, book_kind: "collection"})

          assert_match(/\| collection\z/, @finder.describe_candidate(candidate))
        end

        # ---- the negative class -----------------------------------------------

        test "same title, different author: not exact, the AI decides, and 'none' is unmatched" do
          SEARCH.stubs(:call).returns([hit(@war_and_peace)])
          stub_ai({selected_index: 0, confidence: "high", reasoning: "Different author.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Someone Else"]))

          assert match.unmatched?
          assert_equal [@war_and_peace], match.candidates.map(&:record)
          assert_equal :ai, match.decided_by
        end

        test "same author, different title: no candidates from any source is a high-confidence unmatched" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Anna Karenina", author_names: ["Leo Tolstoy"]))

          assert_equal [:unmatched, :high, :rule], [match.outcome, match.confidence, match.decided_by]
          assert_equal [], match.candidates
          assert_match(/4 sources/, match.reason)
        end

        test "a near spelling reaches the AI through OpenSearch and a confident selection is a match" do
          SEARCH.expects(:call).with(title: "War & Peace", authors: ["Leo Tolstoy"], year: nil, size: 5).returns([hit(@war_and_peace, 11.2)])
          stub_ai({selected_index: 1, confidence: "high", reasoning: "Same work.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War & Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :high, :ai], [match.record, match.confidence, match.decided_by]
          assert_equal({opensearch: 11.2}, match.candidates.first.scores)
          assert_not match.needs_review?
        end

        test "a translated alternate title found by OpenSearch is an exact match by rule" do
          SEARCH.stubs(:call).returns([hit(@war_and_peace)])
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Voyna i mir", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :high, :rule], [match.record, match.confidence, match.decided_by]
        end

        test "a year more than two apart blocks the exact rule" do
          stub_ai({selected_index: 0, confidence: "medium", reasoning: "Different year.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"], year: 1990))

          assert match.unmatched?
          assert_equal :ai, match.decided_by
        end

        # ---- Open Library (rules 2 and 5) ---------------------------------------

        test "an Open Library accept on a key a local book holds, corroborated by the title, is a certain match with the resolution kept" do
          key = identifiers(:crime_and_punishment_openlibrary).value
          stub_resolve(resolve_response(verdict: "accept", key: key, candidates: [ol_candidate(key: key, verdict: "accept", score: 0.95, record: work_record(key: key, title: "Crime and Punishment"))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Crime and Punishment", author_names: ["Fyodor Dostoevsky"]))

          assert_equal [@crime, :certain, :identifier], [match.record, match.confidence, match.decided_by]
          assert_equal key, match.external.external_key
          assert match.external_resolution.accept?
          assert_match(/open_library accepted #{key}/, match.reason)
        end

        test "an Open Library accept on a key nobody holds, with no local candidates, is a high-confidence unmatched with the external set" do
          stub_resolve(resolve_response(verdict: "accept", key: "OL999W", candidates: [ol_candidate(key: "OL999W", verdict: "accept", score: 0.95, record: work_record(key: "OL999W", title: "The Brothers Karamazov", authors: ["Fyodor Dostoevsky"], declared_year: 1880))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "The Brothers Karamazov", author_names: ["Fyodor Dostoevsky"]))

          assert_equal [:unmatched, :high, :rule], [match.outcome, match.confidence, match.decided_by]
          assert_equal "OL999W", match.external.external_key
          assert_equal ["The Brothers Karamazov", ["Fyodor Dostoevsky"], 1880], match.external.evidence.values_at(:title, :creators, :year)
          assert match.external_resolution.accept?
          assert_equal "OL999W", match.decision.candidates.first["external_key"]
        end

        test "an Open Library abstain with candidates alongside a local exact match: the exact rule still decides and the externals are recorded" do
          stub_resolve(resolve_response(verdict: "abstain", candidates: [ol_candidate(key: "OL5W", verdict: "abstain", score: 0.4, record: work_record(key: "OL5W", title: "War and Peace"))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :rule], [match.record, match.decided_by]
          assert_equal [@war_and_peace, nil], match.candidates.map(&:record)
          assert_equal "OL5W", match.candidates.last.external_key
        end

        test "the service failing is a failed source: the exact match stands but a high confidence is capped at medium" do
          WebMock.reset!
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "down")

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :medium, :rule], [match.record, match.confidence, match.decided_by]
          assert_equal ["open_library"], match.sources_failed
          assert match.needs_review?
        end

        test "only one HTTP request is made, the resolve" do
          @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_requested(:post, "#{BASE_URL}/resolve", times: 1)
        end

        # ---- verify, exclude, subject ----------------------------------------

        test "verify: true disables the identifier early exit, runs every source and records verify on the decision" do
          key = identifiers(:crime_and_punishment_openlibrary).value
          SEARCH.expects(:call).once.returns([])
          stub_ai({selected_index: 1, confidence: "high", reasoning: "Same key.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "Crime and Punishment", open_library_work_key: key), verify: true)

          assert_equal [@crime, :ai], [match.record, match.decided_by]
          assert match.decision.verify
          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "exclude: drops that record from every source" do
          key = identifiers(:crime_and_punishment_openlibrary).value
          stub_resolve(resolve_response(verdict: "accept", key: key, candidates: [ol_candidate(key: key, verdict: "accept", score: 0.95, record: work_record(key: key, title: "Crime and Punishment"))]))

          match = @finder.call(query: ImportQuery.new(title: "Crime and Punishment", open_library_work_key: key), verify: true, exclude: @crime)

          assert match.unmatched?
          assert_equal [], match.candidates.map(&:record).compact
        end

        test "the subject is recorded on the decision" do
          subject = list_items(:music_albums_item)

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]), subject: subject)

          assert_equal subject, match.decision.subject
        end
      end
    end
  end
end
```

Fixture facts the tests lean on: `war_and_peace` (title "War and Peace", 1869, `alternate_titles: ["Voyna i mir"]`, author `tolstoy` whose `alternate_names` include "Lev Tolstoy", identifiers `war_and_peace_isbn13` and `war_and_peace_asin`); `crime_and_punishment` (no authors, identifier `crime_and_punishment_openlibrary` = "OL262758W"); `of_mice_and_men` (`of_mice_and_men_goodreads`); `combo_steinbeck` (`book_kind: collection`); `list_items(:music_albums_item)` and `ai_chats(:general_chat)` as used by `finder_base_test.rb`. Check `Books::BookAuthor`'s required attributes before relying on `position:`.

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/finder_test.rb`
Expected: many FAIL (the legacy source ignores the search stub and never calls `/resolve`; `Finder.new(open_library_client:)` raises `ArgumentError`).

- [ ] **Step 4: Rewrite the finder**

Replace `web-app/app/lib/data_importers/books/book/finder.rb` with:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Finds an existing ::Books::Book before import and answers with a
      # Match (see FinderBase). Four sources, in order: identifiers (Open
      # Library work key, ISBN-13, ISBN-10, ASIN, Goodreads id), an exact
      # normalized title-plus-author lookup, the OpenSearch title-plus-
      # authors query, and the Open Library resolve service.
      class Finder < DataImporters::FinderBase
        IDENTIFIER_LOOKUPS = [
          [:open_library_work_key, :books_work_openlibrary_id],
          [:isbn13, :books_work_isbn13],
          [:isbn10, :books_work_isbn10],
          [:asin, :books_work_asin],
          [:goodreads_id, :books_work_goodreads_id]
        ].freeze
        OPENSEARCH_SIZE = 5
        OPEN_LIBRARY_LIMIT = 5

        # open_library_client: injected by tests; nil builds the real client
        # lazily inside OpenLibrarySource.
        def initialize(open_library_client: nil)
          @open_library_client = open_library_client
        end

        def describe_candidate(candidate)
          line = super
          line = "#{line} | collection" if candidate.evidence[:book_kind].to_s == "collection"
          line
        end

        protected

        def model_class = ::Books::Book

        def ranking_configuration_class = ::Books::RankingConfiguration

        def creators_required? = true

        def candidate_sources(query)
          [
            DataImporters::Sources::Identifiers.new(model_class: ::Books::Book, lookups: identifier_lookups(query)),
            DataImporters::Sources::Exact.new(scope: exact_scope(query)),
            DataImporters::Sources::OpenSearch.new(
              model_class: ::Books::Book,
              search_class: ::Search::Books::Search::BookByTitleAndAuthors,
              params: search_params(query),
              size: OPENSEARCH_SIZE,
              includes: [:authors, :identifiers]
            ),
            OpenLibrarySource.new(query: query, client: @open_library_client, limit: OPEN_LIBRARY_LIMIT)
          ]
        end

        def domain_guidance
          "A translation, a retitled edition or an alternate spelling of the same work is the same book. " \
            "A collection or omnibus is not the same as one of the works inside it, and one volume of a series is not the series. " \
            "Two books with the same title by different authors are different books."
        end

        def query_creators(query) = query.author_names

        def record_creators(record) = record.authors.map(&:name)

        def record_creator_alternate_names(record) = record.authors.flat_map { |author| Array(author.alternate_names) }

        def record_year(record) = record.first_published_year

        def record_extra_evidence(record)
          {book_kind: record.book_kind, alternate_titles: Array(record.alternate_titles)}
        end

        private

        def identifier_lookups(query)
          IDENTIFIER_LOOKUPS.flat_map do |field, identifier_type|
            Array(query.public_send(field)).map { |value| [identifier_type, value] }
          end
        end

        # Normalized title equality (served by the lower(title) expression
        # index), joined to an author whose name or alternate name matches
        # when the query names authors. A title-only query still yields
        # title matches: they are candidates for the AI, never a rule-4
        # match, because creators_required? is true for books.
        def exact_scope(query)
          return ::Books::Book.none if query.title.blank?

          scope = ::Books::Book.where("LOWER(books_books.title) = ?", normalize(query.title))
          names = query.author_names.map { |name| normalize(name) }.compact_blank
          if names.any?
            scope = scope.joins(book_authors: :author).where(
              "LOWER(books_authors.name) IN (:names) OR EXISTS (SELECT 1 FROM unnest(books_authors.alternate_names) AS alternate WHERE LOWER(alternate) IN (:names))",
              names: names
            )
          end
          scope.includes(:authors, :identifiers).distinct.order(:id)
        end

        def search_params(query)
          return nil if query.title.blank?

          {title: query.title, authors: query.author_names, year: query.year}
        end
      end
    end
  end
end
```

- [ ] **Step 5: Stub the search class in the importer tests and re-run everything that touches the books finder**

In `web-app/test/lib/data_importers/books/book/importer_test.rb`, add to `setup` (create one if the file has none): `::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([])`. Then `grep -rln "Books::Book::Importer\|Books::Book::Finder" test/` and give every other file that runs the books finder the same stub. A test that asserts `/resolve` was requested exactly once will now see two requests (the finder's and the provider's) until Task 6 lands — change such an assertion to `at_least_times: 1` now and note it for Task 6.

Run: `bin/rails test test/lib/data_importers test/lib/services/duplicate_candidates test/models/match_decision_test.rb test/models/duplicate_candidate_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint, zeitwerk, commit**

```bash
bundle exec standardrb app/lib/data_importers/finder_base.rb app/lib/data_importers/books/book/finder.rb test/lib/data_importers/books/book/finder_test.rb test/lib/data_importers/finder_base_test.rb test/lib/data_importers/books/book/importer_test.rb
CI=1 bin/rails zeitwerk:check
git add -A app/lib/data_importers test/lib/data_importers
git commit -m "Books finder: identifiers, exact, OpenSearch and Open Library as real sources" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 6: The Open Library provider reuses the finder's resolution for a new book

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/providers/open_library.rb`
- Test: `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb`, `web-app/test/lib/data_importers/books/book/importer_test.rb`

**Interfaces:**
- Consumes: `DataImporters::Match#external_resolution` (a `Books::OpenLibrary::Resolution` or nil), set by `FinderBase` from `OpenLibrarySource#resolution`.
- Produces: `populate(book, query:, match: nil)` makes no `/resolve` call when `match.external_resolution` is present and `book` is not persisted; everything after the resolution (fills, guards, identifier stamping, verdict-to-result) is unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb` (reuse its `resolve_response`, `diff_entry` and `stub_resolve` helpers):

```ruby
          # ------------------------------------------------------- match reuse

          test "a new book reuses the match's resolution and makes no request" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            resolution = ::Books::OpenLibrary::Resolution.from_response(resolve_response(verdict: "accept", key: "OL468431W", diff: [
              diff_entry(field: "first_published_year", ours: nil, theirs: 1925, kind: "fill")
            ]))
            match = DataImporters::Match.new(outcome: :unmatched, external_resolution: resolution)

            result = @provider.populate(book, query: nil, match: match)

            assert result.success?
            assert_equal 1925, book.first_published_year
            assert_equal "OL468431W", book.identifiers.find { |i| i.identifier_type == "books_work_openlibrary_id" }&.value
            assert_not_requested(:post, "#{BASE_URL}/resolve")
          end

          test "a persisted book resolves from its own state even when the match carries a resolution" do
            book = books_books(:war_and_peace)
            stub_resolve(resolve_response(verdict: "abstain", reason: "own state"))
            match = DataImporters::Match.new(outcome: :matched, record: book,
              external_resolution: ::Books::OpenLibrary::Resolution.from_response(resolve_response(verdict: "accept")))

            result = @provider.populate(book, query: nil, match: match)

            refute result.success?
            assert_includes result.errors.join, "own state"
            assert_requested(:post, "#{BASE_URL}/resolve")
          end

          test "a new book whose match carries no resolution calls the service" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            stub_resolve(resolve_response(verdict: "abstain", reason: "no resolution on the match"))

            result = @provider.populate(book, query: nil, match: DataImporters::Match.new(outcome: :unmatched))

            refute result.success?
            assert_requested(:post, "#{BASE_URL}/resolve")
          end
```

In `web-app/test/lib/data_importers/books/book/importer_test.rb` add one test (and restore any `times: 1` assertion Task 5 loosened):

```ruby
        test "importing a new title resolves once: the finder's resolution feeds the provider" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: []).to_json)

          result = Importer.call(title: "The Great Gatsby", author_names: ["F. Scott Fitzgerald"])

          assert result.success?
          assert result.match.unmatched?
          assert_requested(:post, "#{BASE_URL}/resolve", times: 1)
        end
```

(`accept_response`'s key "OL468431W" is held by no fixture book, so the finder's rule 5 sets `external` and keeps the resolution.)

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/providers/open_library_test.rb test/lib/data_importers/books/book/importer_test.rb`
Expected: the reuse test FAILS (`WebMock::NetConnectNotAllowedError` or an unstubbed request), the importer test FAILS on `times: 1` (two requests).

- [ ] **Step 3: Reuse the resolution**

In `web-app/app/lib/data_importers/books/book/providers/open_library.rb`, change the first line of `populate` to:

```ruby
            resolution = reusable_resolution(book, match) || client.resolve(**resolve_args(book, query))
```

and add, under `private`:

```ruby
          # The finder already asked the service about this query. For a book
          # that does not exist yet, the request the provider would build is
          # the same one (title and year seeded from the query; no authors or
          # identifiers of its own yet), so the answer is reused instead of a
          # second five-second call. A persisted book under force_providers
          # resolves from its own state, as before.
          def reusable_resolution(book, match)
            return nil if book.persisted? || match.nil?

            match.external_resolution
          end
```

Update the class comment's first sentence to mention the reuse.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/data_importers/books/book`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/books/book/providers/open_library.rb test/lib/data_importers/books/book/providers/open_library_test.rb test/lib/data_importers/books/book/importer_test.rb
git add app/lib/data_importers/books/book/providers/open_library.rb test/lib/data_importers/books/book/providers/open_library_test.rb test/lib/data_importers/books/book/importer_test.rb
git commit -m "Open Library provider reuses the finder's resolution for a new book" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `Flag` hardening and the duplicate sweep job

**Files:**
- Modify: `web-app/app/lib/services/duplicate_candidates/flag.rb`
- Test: `web-app/test/lib/services/duplicate_candidates/flag_test.rb`
- Create (generator): `web-app/app/sidekiq/books/find_duplicates_job.rb`, `web-app/test/sidekiq/books/find_duplicates_job_test.rb`
- Create: `web-app/lib/tasks/books/duplicates.rake`

**Interfaces:**
- Consumes: `DataImporters::Books::Book::Finder#call(query:, verify:, subject:, exclude:)` (Task 5), `DataImporters::Books::Book::ImportQuery`, `Services::DuplicateCandidates::Flag.call(item_type:, ids:, source:, evidence:, match_decision:)`, `Books::RankingConfiguration.default_primary`, `RankedItem`.
- Produces: `Flag.call` returns a failure `Result` (no write) when fewer than two ids arrive, and survives a concurrent insert of the same pair by retrying once. `Books::FindDuplicatesJob.perform(book_id)` on queue `serial`; `Books::FindDuplicatesJob.enqueue_ranked(limit: nil) -> Integer`; `bin/rails books:find_duplicates[limit]`.

- [ ] **Step 1: Failing tests for `Flag`**

Add to `web-app/test/lib/services/duplicate_candidates/flag_test.rb`:

```ruby
      test "fails without writing when an id is missing" do
        assert_no_difference("DuplicateCandidate.count") do
          result = Flag.call(item_type: @type, ids: [@a.id, nil], source: :bulk_verify)

          refute result.success?
          assert_nil result.data
          assert_match(/two ids/, result.errors.first)
        end
      end

      test "a concurrent insert of the same pair is retried once and lands on the existing row" do
        existing = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :ai).data
        fresh = ::DuplicateCandidate.new(item_type: @type, item_a_id: [@a.id, @b.id].min, item_b_id: [@a.id, @b.id].max)
        fresh.stubs(:save!).raises(ActiveRecord::RecordNotUnique, "duplicate key")
        ::DuplicateCandidate.expects(:find_or_initialize_by).twice.returns(fresh, existing)

        result = Flag.call(item_type: @type, ids: [@a.id, @b.id], source: :bulk_verify, evidence: {reason: "again"})

        assert result.success?
        assert_equal existing, result.data
        assert_equal 2, existing.reload.occurrences
      end
```

Run: `bin/rails test test/lib/services/duplicate_candidates/flag_test.rb` — both FAIL (a row with `item_a_id` 0 is created; the `RecordNotUnique` propagates).

- [ ] **Step 2: Harden `Flag`**

Replace `call` in `web-app/app/lib/services/duplicate_candidates/flag.rb` with:

```ruby
      # data is the DuplicateCandidate row, or nil when both ids are the same record.
      def call
        ids = @ids.compact.map(&:to_i)
        return Result.new(success?: false, data: nil, errors: ["two ids are required, got #{@ids.inspect}"]) unless ids.size == 2

        a, b = ids.minmax
        return Result.new(success?: true, data: nil, errors: []) if a == b

        attempts = 0
        begin
          attempts += 1
          Result.new(success?: true, data: upsert(a, b), errors: [])
        rescue ActiveRecord::RecordNotUnique
          # Two finders raised the same pair at once; the second insert lost
          # the race, and the row it wanted now exists.
          raise if attempts > 1

          retry
        end
      end

      private

      def upsert(a, b)
        row = ::DuplicateCandidate.find_or_initialize_by(item_type: @item_type, item_a_id: a, item_b_id: b)
        if row.persisted?
          return row unless row.pending?

          row.occurrences += 1
          row.evidence = merge_evidence(row.evidence, @evidence)
          row.save!
          return row
        end

        row.assign_attributes(source: @source, evidence: @evidence.deep_stringify_keys, match_decision: @match_decision, status: :pending, occurrences: 1)
        row.save!
        row
      end
```

(`merge_evidence` stays as it is, below `upsert`.) Run the Flag tests — green. Run `bin/rails test test/lib/data_importers/finder_base_test.rb test/lib/books test/lib/music test/lib/games` — green.

- [ ] **Step 3: Generate the job and write its failing tests**

Run: `bin/rails generate sidekiq:job books/find_duplicates`
Expected: creates `app/sidekiq/books/find_duplicates_job.rb` and `test/sidekiq/books/find_duplicates_job_test.rb`.

Replace the generated test with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::FindDuplicatesJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
    @other = books_books(:crime_and_punishment)
    @decision = match_decisions(:low_confidence_book_match)
  end

  test "runs on the serial queue" do
    assert_equal "serial", Books::FindDuplicatesJob.get_sidekiq_options["queue"].to_s
  end

  test "resolves the book against the rest of the catalog: its own fields as the query, verify, subject and exclude set" do
    isbn = identifiers(:war_and_peace_isbn13).value
    asin = identifiers(:war_and_peace_asin).value
    DataImporters::Books::Book::Finder.any_instance.expects(:call).with do |args|
      query = args[:query]
      query.title == "War and Peace" && query.author_names == ["Leo Tolstoy"] && query.year == 1869 &&
        query.isbn13 == [isbn] && query.asin == [asin] && query.open_library_work_key.nil? &&
        args[:verify] == true && args[:subject] == @book && args[:exclude] == @book
    end.returns(DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule))

    assert_no_difference("DuplicateCandidate.count") { Books::FindDuplicatesJob.new.perform(@book.id) }
  end

  test "the book's Open Library key travels as open_library_work_key" do
    DataImporters::Books::Book::Finder.any_instance.expects(:call).with { |args| args[:query].open_library_work_key == "OL262758W" }
      .returns(DataImporters::Match.new(outcome: :unmatched))

    Books::FindDuplicatesJob.new.perform(@other.id)
  end

  test "a match flags the pair as bulk_verify with the decision's reason and the decision itself" do
    DataImporters::Books::Book::Finder.any_instance.stubs(:call).returns(
      DataImporters::Match.new(outcome: :matched, record: @other, confidence: :high, decided_by: :ai, reason: "Same work, other title.", decision: @decision)
    )

    assert_difference("DuplicateCandidate.count", 1) { Books::FindDuplicatesJob.new.perform(@book.id) }

    pair = DuplicateCandidate.last
    assert_equal ["Books::Book", [@book.id, @other.id].min, [@book.id, @other.id].max], [pair.item_type, pair.item_a_id, pair.item_b_id]
    assert pair.raised_by_bulk_verify?
    assert_equal({"reason" => "Same work, other title.", "decided_by" => "ai", "confidence" => "high"}, pair.evidence)
    assert_equal @decision, pair.match_decision
  end

  test "a missing book is skipped without calling the finder" do
    DataImporters::Books::Book::Finder.any_instance.expects(:call).never

    Books::FindDuplicatesJob.new.perform(0)
  end

  test "enqueue_ranked enqueues one job per book in the primary ranking, best rank first, and returns the count" do
    config = ranking_configurations(:books_global)
    RankedItem.create!(item: @other, ranking_configuration: config, rank: 2, score: 80.0)
    RankedItem.create!(item: @book, ranking_configuration: config, rank: 1, score: 90.0)
    RankedItem.create!(item: books_books(:got), ranking_configuration: config, rank: nil, score: 0.0)

    Sidekiq::Testing.fake! do
      Books::FindDuplicatesJob.clear

      assert_equal 2, Books::FindDuplicatesJob.enqueue_ranked
      assert_equal [@book.id, @other.id], Books::FindDuplicatesJob.jobs.map { |job| job["args"].first }
      assert_equal ["serial"], Books::FindDuplicatesJob.jobs.map { |job| job["queue"] }.uniq
    end
  end

  test "enqueue_ranked honours a limit" do
    config = ranking_configurations(:books_global)
    RankedItem.create!(item: @other, ranking_configuration: config, rank: 2, score: 80.0)
    RankedItem.create!(item: @book, ranking_configuration: config, rank: 1, score: 90.0)

    Sidekiq::Testing.fake! do
      Books::FindDuplicatesJob.clear

      assert_equal 1, Books::FindDuplicatesJob.enqueue_ranked(limit: 1)
      assert_equal [@book.id], Books::FindDuplicatesJob.jobs.map { |job| job["args"].first }
    end
  end

  test "enqueue_ranked raises when there is no primary books ranking configuration" do
    Books::RankingConfiguration.stubs(:default_primary).returns(nil)

    assert_raises(RuntimeError) { Books::FindDuplicatesJob.enqueue_ranked }
  end
end
```

Check `match_decisions(:low_confidence_book_match)` exists in `test/fixtures/match_decisions.yml` (increment 1 added it) and that `RankedItem` accepts `rank: nil` (if a validation forbids it, drop that third row and the test still holds).

Run: `bin/rails test test/sidekiq/books/find_duplicates_job_test.rb` — FAIL (the generated job has an empty `perform`).

- [ ] **Step 4: Write the job**

Replace `web-app/app/sidekiq/books/find_duplicates_job.rb` with:

```ruby
# frozen_string_literal: true

# The duplicate sweep (spec §16): resolve one ranked book against the rest
# of the catalog by calling the finder with the book's own fields, verify on
# (no identifier early exit) and the book itself excluded. A match means
# another local book is the same work; the pair is raised as bulk_verify.
# Nothing else is written and no provider runs.
#
# One book per job on the serial queue: each /resolve saturates the Open
# Library service, and a Sidekiq restart mid-sweep then loses one book, not
# the sweep. Re-running is safe for pairs (a pending pair gains an
# occurrence, a dismissed one is never re-raised); it does write a fresh
# match_decisions row per book.
class Books::FindDuplicatesJob
  include Sidekiq::Job

  sidekiq_options queue: :serial, retry: 3

  QUERY_IDENTIFIERS = {
    isbn13: "books_work_isbn13",
    isbn10: "books_work_isbn10",
    asin: "books_work_asin",
    goodreads_id: "books_work_goodreads_id"
  }.freeze

  # Enqueues one job per book in the primary ranking, best rank first.
  # Returns how many were enqueued.
  def self.enqueue_ranked(limit: nil)
    config = Books::RankingConfiguration.default_primary
    raise "No primary Books::RankingConfiguration; nothing to sweep" if config.nil?

    scope = RankedItem.where(ranking_configuration_id: config.id, item_type: "Books::Book").where.not(rank: nil).order(:rank)
    scope = scope.limit(limit) if limit
    ids = scope.pluck(:item_id)
    ids.each_slice(1000) { |slice| perform_bulk(slice.map { |id| [id] }) }
    ids.size
  end

  def perform(book_id)
    book = Books::Book.includes(:authors, :identifiers).find_by(id: book_id)
    return if book.nil?

    match = DataImporters::Books::Book::Finder.new.call(query: query_for(book), verify: true, subject: book, exclude: book)
    return unless match.matched?

    Services::DuplicateCandidates::Flag.call(
      item_type: "Books::Book",
      ids: [book.id, match.record.id],
      source: :bulk_verify,
      evidence: {reason: match.reason, decided_by: match.decided_by.to_s, confidence: match.confidence.to_s},
      match_decision: match.decision
    )
  end

  private

  def query_for(book)
    by_type = book.identifiers.group_by(&:identifier_type)
    values = ->(type) { Array(by_type[type]).map(&:value) }

    DataImporters::Books::Book::ImportQuery.new(
      title: book.title,
      author_names: book.authors.map(&:name),
      year: book.first_published_year,
      isbn13: values.call(QUERY_IDENTIFIERS[:isbn13]),
      isbn10: values.call(QUERY_IDENTIFIERS[:isbn10]),
      asin: values.call(QUERY_IDENTIFIERS[:asin]),
      goodreads_id: values.call(QUERY_IDENTIFIERS[:goodreads_id]),
      open_library_work_key: values.call("books_work_openlibrary_id").first
    )
  end
end
```

`perform_bulk` is Sidekiq's; under `Sidekiq::Testing.fake!` it pushes onto `jobs` like `perform_async`. If the installed Sidekiq's `perform_bulk` signature differs, use `Sidekiq::Client.push_bulk("class" => self, "args" => slice.map { |id| [id] }, "queue" => "serial")`.

- [ ] **Step 5: The rake task**

Create `web-app/lib/tasks/books/duplicates.rake`:

```ruby
# frozen_string_literal: true

namespace :books do
  desc "Duplicate sweep: enqueue one Books::FindDuplicatesJob per ranked book on the serial queue (optional limit)"
  task :find_duplicates, [:limit] => :environment do |_task, args|
    limit = args[:limit].presence&.to_i
    count = Books::FindDuplicatesJob.enqueue_ranked(limit: limit)
    puts "enqueued #{count} ranked books on the serial queue"
  end
end
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/sidekiq/books/find_duplicates_job_test.rb test/lib/services/duplicate_candidates`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/duplicate_candidates/flag.rb test/lib/services/duplicate_candidates/flag_test.rb app/sidekiq/books/find_duplicates_job.rb test/sidekiq/books/find_duplicates_job_test.rb lib/tasks/books/duplicates.rake
git add app/lib/services/duplicate_candidates/flag.rb test/lib/services/duplicate_candidates/flag_test.rb app/sidekiq/books/find_duplicates_job.rb test/sidekiq/books/find_duplicates_job_test.rb lib/tasks/books/duplicates.rake
git commit -m "Books duplicate sweep: one FindDuplicatesJob per ranked book on the serial queue" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 8: The stored-name normalization one-off, with its measurement

**Files:**
- Create: `web-app/app/lib/services/books/normalize_stored_names.rb`
- Test: `web-app/test/lib/services/books/normalize_stored_names_test.rb`
- Create: `web-app/lib/tasks/books/normalize_names.rake`
- Create: `docs/data-quality/books-normalizer-effect.md`

**Interfaces:**
- Consumes: `Books::Book#normalize_title` and `Books::Author#normalize_name` (before_validation callbacks that apply `NameNormalizer.call(QuoteNormalizer.call(x))`), `Services::DuplicateCandidates::Flag`.
- Produces: `Services::Books::NormalizeStoredNames.call(apply: false) -> Result` whose `data` is `{books: {scanned:, whitespace:, nfkc:, changed:, samples: [...]}, authors: {...}, applied: Boolean, pairs_flagged: Integer}`; `bin/rails books:normalize_names:report` (read-only) and `bin/rails books:normalize_names:apply`.

**Never run `apply` against the development database in this task.** Tests run against the test database only. The report task is read-only and may be run in development to confirm the numbers below.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/services/books/normalize_stored_names_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class NormalizeStoredNamesTest < ActiveSupport::TestCase
      NNBSP = " "

      # Rows are written past the normalizing callbacks with update_columns,
      # the way the migration-era rows in production were.
      def raw_author(name)
        author = ::Books::Author.create!(name: "placeholder #{SecureRandom.hex(4)}")
        author.update_columns(name: name)
        author.reload
      end

      def raw_book(title, authors: [])
        book = ::Books::Book.create!(title: "placeholder #{SecureRandom.hex(4)}")
        book.update_columns(title: title)
        authors.each_with_index { |author, i| ::Books::BookAuthor.create!(book: book, author: author, position: i + 1) }
        book.reload
      end

      test "the report counts whitespace-only and NFKC changes per model and touches nothing" do
        raw_author("Kathleen#{NNBSP}Alcott")
        raw_author("Honorée Jeffers")
        raw_book("House Of X   Powers Of X")

        result = NormalizeStoredNames.call(apply: false)

        assert result.success?
        data = result.data
        assert_equal [1, 1, 2], data[:authors].values_at(:whitespace, :nfkc, :changed)
        assert_equal [1, 0, 1], data[:books].values_at(:whitespace, :nfkc, :changed)
        assert_not data[:applied]
        assert_equal "Kathleen#{NNBSP}Alcott", ::Books::Author.find_by("name LIKE 'Kathleen%'").name
        assert_includes data[:authors][:samples].map { |s| s[:after] }, "Kathleen Alcott"
      end

      test "apply rewrites the changed rows in place through the model callbacks" do
        author = raw_author("Kathleen#{NNBSP}Alcott")
        book = raw_book("Dune   Messiah")

        result = NormalizeStoredNames.call(apply: true)

        assert result.success?
        assert result.data[:applied]
        assert_equal "Kathleen Alcott", author.reload.name
        assert_equal "Dune Messiah", book.reload.title
      end

      test "apply normalizes alternate names and alternate titles too" do
        author = raw_author("Plain Name")
        author.update_columns(alternate_names: ["Plain#{NNBSP}Name", "P. Name"])
        book = raw_book("Plain Title")
        book.update_columns(alternate_titles: ["Plain#{NNBSP}Title"])

        NormalizeStoredNames.call(apply: true)

        assert_equal ["Plain Name", "P. Name"], author.reload.alternate_names
        assert_equal ["Plain Title"], book.reload.alternate_titles
      end

      test "apply flags an author whose normalized name now equals another author's, as a bulk_verify pair" do
        existing = ::Books::Author.create!(name: "Kathleen Alcott")
        stray = raw_author("Kathleen#{NNBSP}Alcott")

        result = NormalizeStoredNames.call(apply: true)

        pair = DuplicateCandidate.find_by(item_type: "Books::Author", item_a_id: [existing.id, stray.id].min, item_b_id: [existing.id, stray.id].max)
        assert pair.raised_by_bulk_verify?
        assert_match(/normaliz/, pair.evidence["reason"])
        assert_equal 1, result.data[:pairs_flagged]
      end

      test "apply flags two books with the same normalized title and a shared author name, and leaves unrelated same titles alone" do
        author_a = ::Books::Author.create!(name: "Kathleen Alcott")
        author_b = raw_author("Kathleen#{NNBSP}Alcott")
        kept = ::Books::Book.create!(title: "The Secret Lives")
        ::Books::BookAuthor.create!(book: kept, author: author_a, position: 1)
        stray = raw_book("The Secret#{NNBSP}Lives", authors: [author_b])
        other_author = ::Books::Author.create!(name: "Someone Else")
        unrelated = raw_book("The Secret#{NNBSP}Lives", authors: [other_author])

        NormalizeStoredNames.call(apply: true)

        assert DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [kept.id, stray.id].min, item_b_id: [kept.id, stray.id].max)
        assert_not DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [kept.id, unrelated.id].min, item_b_id: [kept.id, unrelated.id].max)
      end

      test "a row the normalizer would not change is not saved" do
        author = books_authors(:tolstoy)
        ::Books::Author.any_instance.expects(:save!).never

        NormalizeStoredNames.call(apply: true)

        assert_equal "Leo Tolstoy", author.reload.name
      end
    end
  end
end
```

The last test assumes no fixture row needs normalizing; if the fixtures contain one, the test must instead assert `save!` is called exactly for that row.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books/normalize_stored_names_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::NormalizeStoredNames`.

- [ ] **Step 3: Write the service**

Create `web-app/app/lib/services/books/normalize_stored_names.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Applies the save-time normalization (QuoteNormalizer, then
    # NameNormalizer: NFKC and Unicode-space folding) to every stored book
    # title and author name it would change, in place, and reports what
    # changed. The finder's exact source compares a normalized query with
    # the stored value, so a row written before the normalizer existed is
    # invisible to it until saved once. Collisions that fall out -- an
    # author whose folded name equals another author's, a book whose folded
    # title equals another book's by the same author -- are raised as
    # bulk_verify pairs; nothing is merged.
    #
    # `report` (apply: false) is read-only. `apply` saves through the model
    # callbacks, one row at a time, so slugs, reindex requests and the
    # normalizers behave exactly as on any other save.
    class NormalizeStoredNames
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      SAMPLE_LIMIT = 25
      BATCH_SIZE = 2000

      COLLISION_REASON = "same value after whitespace/NFKC normalization"

      def self.call(apply: false)
        new(apply: apply).call
      end

      def initialize(apply: false)
        @apply = apply
        @pairs_flagged = 0
      end

      def call
        books = scan(::Books::Book, :title)
        authors = scan(::Books::Author, :name)

        if @apply
          apply_authors(authors[:ids])
          apply_books(books[:ids])
        end

        Result.new(
          success?: true,
          data: {books: books.except(:ids), authors: authors.except(:ids), applied: @apply, pairs_flagged: @pairs_flagged},
          errors: []
        )
      end

      private

      # ---- report ---------------------------------------------------------

      def scan(model, column)
        counts = {scanned: 0, whitespace: 0, nfkc: 0, changed: 0, samples: [], ids: []}
        model.select(:id, column).find_each(batch_size: BATCH_SIZE) do |row|
          before = row.public_send(column).to_s
          after = normalize(before)
          counts[:scanned] += 1
          next if after == before

          counts[:changed] += 1
          counts[:ids] << row.id
          if nfkc_changed?(before)
            counts[:nfkc] += 1
          else
            counts[:whitespace] += 1
          end
          counts[:samples] << {id: row.id, before: before, after: after} if counts[:samples].size < SAMPLE_LIMIT
        end
        counts
      end

      def normalize(text)
        ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text))
      end

      # Whitespace folding alone would give the same answer as the full
      # normalizer: then the change is "whitespace only".
      def nfkc_changed?(text)
        quoted = ::Services::Text::QuoteNormalizer.call(text)
        whitespace_only = quoted.gsub(::Services::Text::NameNormalizer::SPACES, " ").squeeze(" ").strip
        normalize(text) != whitespace_only
      end

      # ---- apply ----------------------------------------------------------

      def apply_authors(ids)
        ids.each_slice(BATCH_SIZE) do |slice|
          ::Books::Author.where(id: slice).order(:id).each do |author|
            before = author.name
            after = normalize(before)
            author.alternate_names = normalize_list(author.alternate_names)
            author.save! # the before_validation callback rewrites name
            collision = ::Books::Author.where("LOWER(name) = ?", after.downcase).where.not(id: author.id).order(:id).first
            flag("Books::Author", author, collision, before: before) if collision
          end
        end
      end

      def apply_books(ids)
        ids.each_slice(BATCH_SIZE) do |slice|
          ::Books::Book.where(id: slice).includes(:authors).order(:id).each do |book|
            before = book.title
            after = normalize(before)
            book.alternate_titles = normalize_list(book.alternate_titles)
            book.save! # the before_validation callback rewrites title
            author_names = book.authors.map { |author| normalize(author.name).downcase }
            next if author_names.empty?

            collision = ::Books::Book.joins(book_authors: :author)
              .where("LOWER(books_books.title) = ?", after.downcase)
              .where("LOWER(books_authors.name) IN (?)", author_names)
              .where.not(id: book.id).distinct.order(:id).first
            flag("Books::Book", book, collision, before: before) if collision
          end
        end
      end

      def normalize_list(values)
        Array(values).map { |value| normalize(value.to_s) }.compact_blank.uniq
      end

      def flag(item_type, record, collision, before:)
        result = ::Services::DuplicateCandidates::Flag.call(
          item_type: item_type,
          ids: [record.id, collision.id],
          source: :bulk_verify,
          evidence: {reason: COLLISION_REASON, normalized_from: before}
        )
        @pairs_flagged += 1 if result.success? && result.data
      end
    end
  end
end
```

Run the tests; adjust the collision lookups if `distinct` with `order(:id)` needs `select("books_books.*")`.

- [ ] **Step 4: The rake tasks**

Create `web-app/lib/tasks/books/normalize_names.rake`:

```ruby
# frozen_string_literal: true

namespace :books do
  namespace :normalize_names do
    print_report = lambda do |data|
      %i[books authors].each do |model|
        counts = data[model]
        puts "#{model}: #{counts[:scanned]} scanned, #{counts[:changed]} would change " \
          "(#{counts[:whitespace]} whitespace only, #{counts[:nfkc]} NFKC beyond whitespace)"
        counts[:samples].each { |sample| puts "  #{sample[:id]} | #{sample[:before].inspect} -> #{sample[:after].inspect}" }
      end
    end

    desc "Report how many stored book titles and author names the save-time normalizer would change (read-only)"
    task report: :environment do
      print_report.call(Services::Books::NormalizeStoredNames.call(apply: false).data)
    end

    desc "Normalize every stored book title and author name the normalizer would change, in place, and flag the collisions"
    task apply: :environment do
      data = Services::Books::NormalizeStoredNames.call(apply: true).data
      print_report.call(data)
      puts "flagged #{data[:pairs_flagged]} duplicate pairs"
    end
  end
end
```

- [ ] **Step 5: Run the tests, then the read-only report against development**

Run: `bin/rails test test/lib/services/books/normalize_stored_names_test.rb`
Expected: PASS.

Run: `bin/rails books:normalize_names:report | head -8`
Expected (development, 2026-09-23, from the measurement script this service replicates): books 158,220 scanned, 1,965 would change (1,727 whitespace only, 238 NFKC beyond whitespace); authors 71,083 scanned, 3,436 would change (3,402 whitespace only, 34 NFKC). The service classifies each row once, NFKC first. Record the actual numbers the report prints in the doc below. **Do not run `apply`.**

- [ ] **Step 6: Write the data-quality doc**

Create `docs/data-quality/books-normalizer-effect.md`:

```markdown
# Books: what the save-time normalizer changes in the stored data

**Measured 2026-09-23** against the development database (a restore of
production: 158,220 books, 71,083 authors), with the `report` task below.
Regenerate before acting; the numbers describe a moment.

```bash
cd web-app
bin/rails books:normalize_names:report     # read-only
bin/rails books:normalize_names:apply      # rewrites the rows and flags collisions
```

## Why

Increment 1 of the import finder redesign chained `Services::Text::NameNormalizer`
(NFKC, every Unicode space separator folded to one space, runs collapsed, ends
stripped) after `QuoteNormalizer` in `Books::Book#normalize_title` and
`Books::Author#normalize_name`. Every save since then normalizes; rows written
before it were not. The finder's exact source compares the *normalized* query
against the *stored* value, so a stored `Kathleen Alcott` (U+202F) never equals
a query `Kathleen Alcott` until that row is saved once. `apply` saves those rows.

## What would change

| | Rows | Change | Whitespace only | NFKC beyond whitespace |
|---|---:|---:|---:|---:|
| `books_books.title` | 158,220 | 1,965 (1.2%) | 1,727 | 238 |
| `books_authors.name` | 71,083 | 3,436 (4.8%) | 3,402 | 34 |

(Each row is classified once: NFKC if the full normalizer changes more than
whitespace folding alone would, otherwise whitespace only.)

Whitespace-only changes are runs of spaces (`House Of X   Powers Of X`), trailing
spaces (`Robin Morgan `), zero-width spaces (`Sheridan Keith​`, U+200B) and the
narrow no-break space (U+202F) that produced the 128 duplicate author groups in
`books-duplicate-rows.md`. Far more rows than the 365 that doc counted, because
it counted only exotic separators; a doubled ASCII space defeats the exact
source just the same.

NFKC changes beyond whitespace are, in order of frequency:

- **accent composition** (NFC, which NFKC includes): `Honorée` → `Honorée`,
  `Milanković` with a combining acute → precomposed. The visible string is
  identical; the bytes now match what a keyboard produces.
- **fullwidth to ASCII** in Japanese and Chinese titles: `Zoo〈１〉` → `Zoo〈1〉`,
  `北斗の拳（1）` → `北斗の拳(1)`, `藤子・Ｆ・不二雄` → `藤子・F・不二雄`.
- **compatibility characters**: `…` → `...`, `№7` → `No7`, `Nº 01` → `No 01`,
  `2ª Ed` → `2a Ed`, `E=Mc²` → `E=Mc2`, `ﷺ` → `صلى الله عليه وسلم`, `Ⅱ` → `II`.
  Lossy in the typographic sense, harmless for identity.
- **one regression, now fixed**: NFKC maps U+00B4 ACUTE ACCENT to a space plus a
  combining acute, so `Ardal O´Hanlon` became `Ardal O ́Hanlon`. Two rows.
  `QuoteNormalizer` now folds U+00B4 to `'` first.

## What `apply` does

Saves each changed row through the model callbacks (so slugs are untouched —
FriendlyId only generates a slug when it is blank — and the search index gets a
reindex request as on any save), normalizes `alternate_names` and
`alternate_titles` the same way, and raises a `bulk_verify` duplicate pair for an
author whose folded name equals another author's and for a book whose folded
title equals another book's by an author of the same name. Nothing is merged; the
pairs wait in the duplicates queue.

Idempotent: a second run finds nothing to change.
```

Replace the counts with what the report printed in Step 5 if they differ.

- [ ] **Step 7: Lint, zeitwerk, commit**

```bash
bundle exec standardrb app/lib/services/books/normalize_stored_names.rb test/lib/services/books/normalize_stored_names_test.rb lib/tasks/books/normalize_names.rake
CI=1 bin/rails zeitwerk:check
git add app/lib/services/books/normalize_stored_names.rb test/lib/services/books/normalize_stored_names_test.rb lib/tasks/books/normalize_names.rake ../docs/data-quality/books-normalizer-effect.md
git commit -m "Books: normalize stored titles and author names in place, flagging the collisions" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Documentation and spec amendments

**Files:**
- Modify: `docs/features/import-finder.md`, `docs/features/data_importers.md`, `docs/features/open-library-data-service.md`, `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md`

No code. Every sentence must describe what the branch now does (read the files from Tasks 3–8 first).

- [ ] **Step 1: `docs/features/import-finder.md`**

1. In "The four stages", stage 1, change "A source that raises adds nothing and is named in `sources_failed`." to "A source that raises adds nothing and is named in `sources_failed`; an `ActiveRecord::ActiveRecordError` propagates instead, because our own database failing is not a missing candidate."
2. Replace the "State after increment 1" section with "State by increment": increment 1 wrapped every legacy lookup; **increment 2 (books)** replaced the books finder's sources with `Sources::Identifiers` (Open Library key, ISBN-13, ISBN-10, ASIN, Goodreads), `Sources::Exact` (normalized title, joined to an author's name or alternate name when the query has authors), `Sources::OpenSearch` over `Search::Books::Search::BookByTitleAndAuthors` (title or alternate title required; authors and a year within one as boosts; a higher minimum score without authors), and `DataImporters::Books::Book::OpenLibrarySource` (`POST /resolve`, limit 5; one candidate per local holder of the work key or a key it redirects from; the whole `Resolution` on `match.external_resolution`, which the provider reuses for a new book). Music and games still run their legacy lookups until increments 5 and 6.
3. Add a "The duplicate sweep" section (three or four sentences): `Books::FindDuplicatesJob`, `serial` queue, one job per ranked book, `verify: true, subject: book, exclude: book`, a match raises a `bulk_verify` pair; `bin/rails books:find_duplicates[limit]`.
4. Add a "Stored-name normalization" section pointing at `docs/data-quality/books-normalizer-effect.md` and the two rake tasks.
5. In "Adding a domain", add `record_extra_evidence` to the hook list.

- [ ] **Step 2: `docs/features/data_importers.md`**

Find the books finder description (grep `Finder` and `Books`) and replace the identifiers-then-exact-title text with one sentence pointing at `docs/features/import-finder.md` for the four sources, keeping the provider paragraphs. Where the doc says the provider calls `/resolve` "exactly once per populate", add: "for a new book it reuses the resolution the finder already obtained, so a title import makes one `/resolve` call in total."

- [ ] **Step 3: `docs/features/open-library-data-service.md`**

1. Retitle "The finder rule (R104)" to "The finder rule (R104) — superseded" and replace its body with two sentences: the increment-1/2 finder is described in `docs/features/import-finder.md`; the service is now one of four candidate sources, and the finder does call `/resolve` (the old rule that it never did is gone).
2. In "Bulk guidance", replace "No such job exists yet: Increment 5 ships the importer and provider only; a Sidekiq job driving many imports through them is deferred." with a sentence naming `Books::FindDuplicatesJob` on the `serial` queue as the first bulk caller, and keep the one-at-a-time rule.
3. In "Deferred", drop "a Sidekiq job to drive bulk imports through the `serial` queue".

- [ ] **Step 4: The spec**

Append to "Decisions made during brainstorming" (after Task 2's line):

```markdown
- **Increment 2 readings** (declared at implementation): `alternate_titles` sits inside the required title group of `BookByTitleAndAuthors`, so a merged-away title satisfies the search; the Open Library source treats a local book holding a key in the work's `redirected_from` list as a holder of that work; the one-off normalization covers every row the save-time normalizer would change (1,965 titles, 3,436 author names measured 2026-09-23), not only the 365 with exotic spaces; `U+00B4` joins `QuoteNormalizer`; the sweep is one job per ranked book rather than one looping job; the one-off's collision pairs use source `bulk_verify`.
```

In §8, change "**One-off task:** normalize the 365 books and their authors that carry exotic spaces, in place." to "**One-off task:** normalize every stored title and author name the save-time normalizer would change, in place (`docs/data-quality/books-normalizer-effect.md`)."

- [ ] **Step 5: Check and commit**

Read each edited section once more against the code. Then:

```bash
git add docs/features/import-finder.md docs/features/data_importers.md docs/features/open-library-data-service.md docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md
git commit -m "Docs: the books finder's sources, the duplicate sweep and the normalization one-off" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Deploy and run notes (for Shane, not for the implementers)

1. Merging deploys. The image build and Deploy to Production run on merge; no migration in this increment.
2. After the deploy: `bin/rails books:normalize_names:report`, read it, then `bin/rails books:normalize_names:apply` (roughly 5,400 saves, each queuing a reindex request; the search index queue is built for bulk). Repeat in development so the two stay aligned.
3. Then the sweep: `bin/rails books:find_duplicates[100]` first, watch `match_decisions` and `duplicate_candidates` fill, then without the limit. At ~6 s per book on the `serial` queue, ten thousand ranked books take a couple of days in the background. The Open Library service and Redis must be up.
4. The audit pages (increment 3) are how the pairs and low-confidence decisions get reviewed; until then, `DuplicateCandidate.pending.for_type("Books::Book")` in a console.

