# Goodreads Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every new book a `goodreads` workflow step. When Goodreads confirms the book, the step
fills the year, page count, genres, series and identifiers, and it hands the cached page to book AI.
Book AI then writes a house-style description and skips the research run.

**Architecture:** The step is resumable and lives in `books.book_enrichment` (version 2), on the
concurrency-1 `goodreads_fetch` capsule. Each execution makes at most one gated fetch, and progress is
kept in the step's `result`. Finding a match and applying a page are separate services, so a later
backfill can call apply alone. The parsers read Apollo state and search markup from cached HTML.

**Tech Stack:** Rails 8, Postgres, Sidekiq, Minitest + Mocha, Nokogiri, `PageFetcher::Client`, and
the `Workflows::*` engine.

**Spec:** `docs/superpowers/specs/2026-10-25-books-goodreads-enrichment-design.md`. Read §4, §5, §6
and §10 before any task.

## Global Constraints

- Run Rails commands from `web-app/`. Lint with `bundle exec standardrb`, never rubocop. Never run brakeman.
- Use generators: `bin/rails generate migration …`, `bin/rails generate model …`. **Always run annotaterb.**
  `bin/rails db:migrate` does it. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`.
- Reference model constants under the `::Books::` prefix inside `Services::Books::*` and `Workflows::Books::*`.
  Nested namespaces shadow them.
- Minitest 6: `assert_nil`, never `assert_equal nil`. Stub every external call with Mocha: the page
  fetcher, AI tasks, Redis-backed `FetchGate`. No network in tests.
- Identifiers use `find_or_initialize_by`, never `build`.
- Fetching: every Goodreads fetch takes a `FetchGate` turn. Spacing is `fetch_interval` 15 s, the cap
  is `daily_fetch_cap` 1,500 per UTC day, and a block holds for `block_cooldown` 6 h. The step runs
  only on queue `goodreads_fetch`.
- Never write Goodreads' description text to `descriptions`. Never create a `Books::Category`. Fill blanks only.
  Never refill a human-cleared field.
- A clean `bin/rails test` prints no new warnings.

## Review Focus

1. **A step that re-enters after a granted reservation reserves again.** That double-counts the daily
   cap and sends the book to the back of the line. The expectation is that `"due" => true` in the
   step result skips `reserve`. Test in Task 10.
2. **Goodreads redesigns the search page.** Rows are gone and there is no "no results" text. The
   expectation is `:unparseable` (gate blocks, step waits), never `:no_results`. Test in Task 3.
3. **Two pages name each other as `best_book_id`, or a page names a not-found best book.** The
   expectation is that the step follows the main edition at most once, then uses what it has. Test in
   Task 10.
4. **Apply runs twice on the same book and page** (backfill re-run). The expectation is that the
   second run writes nothing and the ledger says `already_set` everywhere. Test in Task 8.
5. **A version-1 book run is in flight at deploy**, with no `goodreads` step. The expectation is that
   `book_facts` and `amazon` run as before. Test in Task 10.

---

## File map

| File | Responsibility |
|---|---|
| `app/lib/workflows/definition.rb` | `add_step` validation |
| `app/lib/books/goodreads/book_page.rb` | parser v2: description, genres, page_count, format, best_book_id |
| `app/lib/books/goodreads/search_page.rb` (new) | search results parser |
| `app/lib/books/goodreads/gate_turn.rb` (new) | the gate sequence shared by `FetchPageJob` and the step |
| `app/models/books/goodreads_search.rb` (new) | search cache |
| `app/lib/services/books/goodreads_pages/fetch_page.rb` | stores v2 columns; `refresh:` |
| `app/lib/services/books/goodreads_pages/fetch_search.rb` (new) | fetch + parse + store a search |
| `app/lib/services/books/goodreads_pages/reparse.rb` (new) | re-read a stored page's HTML under the current parser |
| `app/lib/services/books/book_identifier_writer.rb` (new) | verified-collision check + write, shared with Amazon |
| `app/lib/services/books/human_cleared_fields.rb` (new) | shared "a human blanked this" rule |
| `app/lib/services/books/goodreads_enrichment/genre_matcher.rb` (new) | genre names → existing categories |
| `app/lib/services/books/goodreads_enrichment/apply_series.rb` (new) | series find/create + link |
| `app/lib/services/books/goodreads_enrichment/apply.rb` (new) | book + page → every write + one ledger row |
| `app/lib/services/books/goodreads_enrichment/candidate_filter.rb` (new) | free filters + ranking of search rows |
| `app/lib/services/books/goodreads_enrichment/pick_candidate.rb` (new) | cheap-model pick |
| `app/lib/services/books/goodreads_enrichment/page_check.rb` (new) | re-check of a fetched page |
| `app/lib/services/books/goodreads_enrichment/ledger.rb` (new) | non-match ledger rows |
| `app/lib/workflows/books/steps/goodreads.rb` (new) | the resumable step |
| `app/lib/workflows/books/book_enrichment.rb` | version 2, step + edges + skip |
| `app/lib/workflows/books/steps/book_facts.rb` | passes the matched page |
| `app/lib/services/books/enrich_book.rb`, `app/lib/services/ai/tasks/enrichment_task.rb`, `app/lib/services/ai/tasks/books/book_facts_task.rb` | `sourced` mode |
| `app/lib/services/books/amazon_product_service.rb` | ISBN-first search |

---

### Task 1: Validate `add_step`

**Files:**
- Modify: `app/lib/workflows/definition.rb`
- Test: `test/lib/workflows/definition_test.rb` (add to it, or create it if it does not exist)

**Interfaces:**
- Produces: `add_step` raises `ArgumentError` on a duplicate key. A definition whose `waits_on` names an
  undeclared key raises `ArgumentError` from `Definition.validate!`, which `Workflows::Registry`
  calls when it registers a definition. If the registry has no such hook, call it at the end of each
  definition class body.

- [ ] **Step 1: Write failing tests**
  - `test "add_step refuses a duplicate key"`: an anonymous subclass declares `:a` twice, and the test
    asserts `ArgumentError` with a message matching `/duplicate step key a/`.
  - `test "validate! refuses a waits_on key that names no step"`: `:b` has `waits_on: {nope: :finish}`.
    Assert `ArgumentError`, `/unknown step nope/`.
  - `test "the shipped definitions validate"`: call `validate!` on `Workflows::Books::AuthorEnrichment`
    and on `BookEnrichment`, with no raise.
- [ ] **Step 2:** `bin/rails test test/lib/workflows/definition_test.rb`, which should FAIL.
- [ ] **Step 3:** Implement. A waits_on key is checked against all declared keys, not only earlier ones.
- [ ] **Step 4:** Run the test file, then `bin/rails test test/lib/workflows`. Expect PASS.
- [ ] **Step 5:** Commit: `Workflow definitions refuse duplicate step keys and unknown waits_on keys`.

---

### Task 2: Book page parser v2, page columns, refresh, re-parse

**Files:**
- Migration: `bin/rails generate migration AddEnrichmentFieldsToBooksGoodreadsPages description:text page_count:integer format:string best_book_id:bigint`.
  Then edit the migration to add `add_column :books_goodreads_pages, :genres, :jsonb, default: [], null: false`.
- Modify: `app/lib/books/goodreads/book_page.rb`, `app/lib/services/books/goodreads_pages/fetch_page.rb`
- Create: `app/lib/services/books/goodreads_pages/reparse.rb`
- Test: `test/lib/books/goodreads/book_page_test.rb`, `test/lib/services/books/goodreads_pages/fetch_page_test.rb`,
  `test/lib/services/books/goodreads_pages/reparse_test.rb`
- Fixture (already committed): `test/fixtures/files/goodreads/pages/catch_22_stray_edition_147719920.html.gz`

**Interfaces:**
- Produces:
  - `BookPage::VERSION = 2`.
  - `BookPage::Facts` gains `:description, :genres, :page_count, :format, :best_book_id`. The markup
    fallback sets them to `nil, [], nil, nil, nil`.
  - `Books::GoodreadsPage` gains columns `description`, `genres` (array of strings), `page_count`,
    `format` and `best_book_id`.
  - `FetchPage.call(goodreads_book_id:, client: nil, refresh: false)`.
  - `Services::Books::GoodreadsPages::Reparse.call(page:) -> Books::GoodreadsPage` re-parses the attached
    HTML under the current `VERSION`, updates the row, and returns it. A page with no HTML, or one
    already at `VERSION`, is returned untouched.

- [ ] **Step 1: Write failing parser tests.** These use the stray-edition fixture (gunzip it in the
  test, with status 200):
  - `description` is present, is plain text (no `<` characters), and runs to 400 or more characters.
    The HTML description was 493 chars.
  - `genres == ["Classics", "Fiction", "Historical Fiction", "War", "Humor", "Literature", "Novels", "Satire", "Book Club", "Historical"]`
  - `page_count` is nil (`numPages` 0 becomes nil), `format == "Paperback"`, `best_book_id == 168668`
  - `goodreads_book_id == 147719920`
  - The existing fixtures still parse. `war_and_peace_656` gets a non-empty `genres` and an integer
    `page_count`. `no_next_data_129650` gets `genres == []` and a nil `description`.
- [ ] **Step 2:** Run `bin/rails test test/lib/books/goodreads/book_page_test.rb`, which should FAIL.
- [ ] **Step 3:** Implement the parser.
  - `description` comes from the Book record's `description` (the key may carry arguments, e.g.
    `description({"stripped":true})`; take the first key starting with `description`), with HTML
    stripped through Nokogiri text and whitespace squeezed.
  - `genres` is `bookGenres[].genre.name`.
  - `best_book_id` is the work record's `bestBook.__ref` resolved to its `legacyId`.
  - Rewrite the header comment: say which fields are read now, and remove the "never read" sentence.
- [ ] **Step 4:** Run `bin/rails db:migrate` (annotaterb updates `app/models/books/goodreads_page.rb`).
  Check the annotation diff, and delete only lines for columns this branch's `schema.rb` lacks.
- [ ] **Step 5: Write failing FetchPage and Reparse tests.**
  - `FetchPage` stores the five new columns on a new row, and `parser_version == 2`.
  - `refresh: true` on an existing `found` row with no HTML (`source: :legacy`):
    - attaches the HTML;
    - fills the new columns;
    - keeps `outcome`, `title`, `authors` and `isbn13` as they were;
    - never turns `found` into `not_found`: a refetch that parses `not_found` leaves the row
      unchanged and returns outcome `:found`.
  - Without `refresh`, a conclusive row is still returned untouched (the existing test stays green).
  - `Reparse` on a version-1 row with HTML fills the new columns and sets `parser_version` 2. A row
    with no HTML is unchanged.
- [ ] **Step 6:** Implement. `store` writes the new columns. Under `refresh:` it updates only the
  version-2 columns, the HTML and `parser_version`.
- [ ] **Step 7:** Run `bin/rails test test/lib/books/goodreads test/lib/services/books/goodreads_pages test/lib/services/books/goodreads_imports test/sidekiq/books/goodreads`.
  Expect PASS: the import's readers are unaffected.
- [ ] **Step 8:** Commit: `Goodreads page parser reads description, genres, page count, format and main edition`.

---

### Task 3: Search parser, search cache, FetchSearch

**Files:**
- Model: `bin/rails generate model Books::GoodreadsSearch query:string:uniq outcome:integer fetched_at:datetime http_status:integer parser_version:integer`.
  Then edit the migration: `null: false` on `query`, `outcome` and `fetched_at`, plus
  `t.jsonb :rows, default: [], null: false`.
- Create: `app/lib/books/goodreads/search_page.rb`, `app/lib/services/books/goodreads_pages/fetch_search.rb`
- Test: `test/lib/books/goodreads/search_page_test.rb`, `test/lib/services/books/goodreads_pages/fetch_search_test.rb`, `test/models/books/goodreads_search_test.rb`
- Fixtures: the two committed searches under `test/fixtures/files/goodreads/searches/`. Capture two
  more with plain `curl`, one request each, at least 15 s apart, using a Firefox user agent, and save
  them gzipped:
  - `no_results.html.gz`: `https://www.goodreads.com/search?q=zzqxjv+wplkrtq`;
  - `beloved_title_only.html.gz`: `?q=beloved`.
  - Also add a synthetic `redesigned.html`: a 200 page with a `<title>` and no result rows and no
    no-results text.

**Interfaces:**
- Produces:
  - `Books::Goodreads::SearchPage.parse(html:, status:) -> Parsed(outcome, rows)`, with `VERSION = 1`.
  - Outcome is one of `:found`, `:no_results`, `:blocked` (401/403/429), `:unavailable` (5xx) or
    `:unparseable`.
  - `SearchPage::Row = Data.define(:goodreads_book_id, :title, :author_names, :year, :ratings_count, :editions_count)`
  - `Books::GoodreadsSearch`:
    - `enum :outcome, {found: 0, no_results: 1, blocked: 2, unparseable: 3}, prefix: true`;
    - `has_one_attached :html, service: :private_imports`;
    - `normalizes :query` to downcased, squeezed and stripped;
    - `FRESH_FOR = 30.days`;
    - `scope :fresh` (`fetched_at > FRESH_FOR.ago`, and outcome `found` or `no_results`);
    - `#candidate_rows -> [SearchPage::Row]`.
  - `Services::Books::GoodreadsPages::FetchSearch.call(query:, client: nil) -> Result(success?: true, data: {outcome:, search:})`.
    The outcomes and the error mapping are `FetchPage`'s (`FETCHER_DOWN` → `:fetcher_down`, any other
    fetcher error → `:unavailable`). The URL is `https://www.goodreads.com/search?q=<CGI.escape(query)>`.
    It stores a row for every outcome except unavailable and fetcher_down, gzipping the HTML as
    `FetchPage` does, and it replaces an older row for the same query.

- [ ] **Step 1: Write failing parser tests.**
  - `catch_22_title_and_author`: 20 rows.
    - Row 1 is `goodreads_book_id 6860652`, `author_names ["Novel Units, Inc."]`, `ratings_count 169`,
      `editions_count 1`, `year 2008`.
    - Row 3 is `147719920`, `["Joseph Heller"]`, `907_547`, `521`, `1961`.
    - Row 2's `year` is nil (no "published").
  - `catch_22_title_only`:
    - row 1 is `168668`, title `"Catch-22"`, `["Joseph Heller"]`, `907_547`;
    - row 2's title is `"Closing Time (Catch-22, #2)"`.
  - `no_results` gives `:no_results` with `rows == []`.
  - `redesigned.html` gives `:unparseable`.
  - Status 403 gives `:blocked`, and 503 gives `:unavailable`.
- [ ] **Step 2:** Run the test, which should FAIL.
- [ ] **Step 3:** Implement against the rows: `tr[itemtype="http://schema.org/Book"]`, the id from
  `a.bookTitle[href]` (`/book/show/(\d+)`), `a.authorName` names through
  `Services::Text::NameNormalizer`, and the counts from the grey line ("N ratings", "published Y",
  "N editions" or "1 edition"; commas stripped). `:no_results` requires the no-results text the
  fixture shows. Zero rows without it is `:unparseable`.
- [ ] **Step 4:** Run `bin/rails db:migrate`, with annotaterb.
- [ ] **Step 5: Write failing FetchSearch and model tests.**
  - FetchSearch:
    - stubs `PageFetcher::Client#fetch` to return the fixture;
    - stores outcome, rows, `parser_version` and HTML;
    - stores nothing on `PageFetcher::Exceptions::TimeoutError`, returning `:unavailable`;
    - returns `:fetcher_down` on `CircuitOpenError`;
    - a second call for the same query updates the row in place.
  - Model: `fresh` excludes a 31-day-old row and a `blocked` row, and `normalizes` makes
    `"  Catch-22 "` equal `"catch-22"`.
- [ ] **Step 6:** Implement.
- [ ] **Step 7:** Run the new test files. Expect PASS.
- [ ] **Step 8:** Commit: `Goodreads search parser and search cache`.

---

### Task 4: Shared gate turn

**Files:**
- Create: `app/lib/books/goodreads/gate_turn.rb`
- Modify: `app/lib/books/goodreads/fetch_gate.rb` (add `#blocked_until`), `app/sidekiq/books/goodreads/fetch_page_job.rb`
- Test: `test/lib/books/goodreads/gate_turn_test.rb`. The existing `fetch_page_job_test.rb` must pass unchanged.

**Interfaces:**
- Produces:
  - `FetchGate#blocked_until -> Time | nil`.
  - `Books::Goodreads::GateTurn.call(gate:, due:) -> Decision`, where
    `Decision = Data.define(:action, :wait, :refusal)`:
    - `action :fetch`: `started!` was called, so fetch now;
    - `action :wait`: `wait` seconds, then call again with `due: true`;
    - `action :refused`: `refusal` is `:blocked` or `:daily_cap`.
    It reproduces `FetchPageJob`'s order exactly: reserve unless due, refuse, wait for the reservation,
    refuse if blocked, wait for spacing, `started!`.
  - `Books::Goodreads::GateTurn.after_fetch(gate:, outcome:)` calls `block!` when `outcome` is
    `:blocked` or `:unparseable`.

- [ ] **Step 1: Write failing tests,** one per branch, with a stubbed gate:
  - not due and reserve refused → `:refused`;
  - not due, granted, wait 12 → `:wait, 12`;
  - due → `reserve` never called (`gate.expects(:reserve).never`);
  - blocked → `:refused, :blocked`;
  - spacing 4 → `:wait, 4`;
  - otherwise → `started!` called and `:fetch`;
  - `after_fetch` blocks on `:unparseable`, and not on `:found`.
- [ ] **Step 2:** Run, which should FAIL.
- [ ] **Step 3:** Implement, and rewrite `FetchPageJob#perform` on top of it with identical behavior.
- [ ] **Step 4:** Run `bin/rails test test/lib/books/goodreads test/sidekiq/books/goodreads`. Expect PASS.
- [ ] **Step 5:** Commit: `Extract the Goodreads gate sequence from FetchPageJob`.

---

### Task 5: Shared identifier writer, new enum values

**Files:**
- Create: `app/lib/services/books/book_identifier_writer.rb`
- Modify: `app/lib/services/books/amazon_book_identifiers.rb`, `app/models/identifier.rb`, `app/models/category_item.rb`, `app/models/enrichment.rb`
- Test: `test/lib/services/books/book_identifier_writer_test.rb`. The existing `amazon_book_identifiers_test.rb` must pass unchanged.

**Interfaces:**
- Produces:
  - `Identifier` source `goodreads: 7`, and type `books_series_goodreads_id: 40` under a
    `# Books - Series level (Books::Series)` comment.
  - `CategoryItem` source `goodreads: 3`.
  - `Enrichment` mode `sourced: 2`.
  - `Services::Books::BookIdentifierWriter.call(book:, pairs:, source:, evidence: {}) -> Result(written:, flagged_book_ids:)`.
    `pairs` is `[[type_string, value], …]`. The writer checks verified conflicts across equivalent
    forms. On any conflict it writes nothing and flags each holder through
    `DuplicateCandidates::Flag`, with `evidence.merge("conflicts" => …)`. Otherwise it writes with
    `find_or_initialize_by`, setting `source` on new rows. This is today's `AmazonBookIdentifiers`
    logic, moved.
  - `AmazonBookIdentifiers` keeps its signature and builds its own pairs. It calls the writer with
    `source: :amazon` and `evidence: {"amazon_asin" => …, "amazon_title" => …}`.

- [ ] **Step 1: Write failing writer tests,** each mirroring an Amazon case:
  - a write sets the source;
  - a verified conflict in the ISBN-10 form of a given ISBN-13 flags and writes nothing;
  - an unverified holder does not block;
  - a re-run creates no duplicates.
- [ ] **Step 2:** Run, which should FAIL.
- [ ] **Step 3:** Implement. Add the enum values, then grep `app/` for exhaustive uses of
  `Enrichment.modes` or `mode ==` (admin views, cost reports) and make each one handle `sourced`.
- [ ] **Step 4:** Run `bin/rails test test/lib/services/books/book_identifier_writer_test.rb test/lib/services/books/amazon_book_identifiers_test.rb test/lib/services/books/amazon_product_service_test.rb test/models`. Expect PASS.
- [ ] **Step 5:** Commit: `Shared book identifier writer; Goodreads identifier, category and enrichment enum values`.

---

### Task 6: Genre matcher

**Files:**
- Create: `app/lib/services/books/goodreads_enrichment/genre_matcher.rb`
- Test: `test/lib/services/books/goodreads_enrichment/genre_matcher_test.rb`

**Interfaces:**
- Produces: `Services::Books::GoodreadsEnrichment::GenreMatcher.new.match(name) -> ::Books::Category | nil`.
  - It considers types `genre`, `subject` and `audience`, never `location`.
  - The order is: active `by_name`, then active `by_alternative_name`, then a
    `Services::CategoryCleanup::NameNormalizer.twin_key` match over active rows. A merged row matched
    by any of these resolves through `#canonical`, and a nil canonical is no match.
  - When several types match one name, the order is `genre`, then `subject`, then `audience`.
  - The candidate rows are loaded once per instance.

- [ ] **Step 1: Write failing tests,** with categories built in the test, not from fixtures:
  - "historical fiction" matches the active genre "Historical Fiction";
  - an alternative name matches;
  - "Sci-Fi" twin-matches "Sci Fi" when that is the normalizer's behavior (check `twin_key` first and
    pick a pair it actually folds);
  - "Literary Fiction", merged into "Literary", returns "Literary";
  - a name matching only a location returns nil;
  - an unknown name returns nil;
  - nothing creates a category: `assert_no_difference "Category.count"` around all of the above.
- [ ] **Step 2:** Run, which should FAIL. **Step 3:** Implement. **Step 4:** Run, which should PASS.
- [ ] **Step 5:** Commit: `Match Goodreads genre names to existing book categories`.

---

### Task 7: Series

**Files:**
- Create: `app/lib/services/books/goodreads_enrichment/apply_series.rb`
- Test: `test/lib/services/books/goodreads_enrichment/apply_series_test.rb`

**Interfaces:**
- Consumes: `Identifier` type `books_series_goodreads_id`, source `goodreads` (Task 5).
- Produces: `Services::Books::GoodreadsEnrichment::ApplySeries.call(book:, entries:) -> [Hash]`.
  `entries` are the page's `series` hashes (`"goodreads_series_id"`, `"title"`, `"position"`). It
  returns one fact hash per entry: `{"series" => title, "goodreads_series_id" => id, "position" => label, "applied" => bool, "reason" => "created" | "linked" | "already_set" | "invalid"}`.
  - The series is found by its identifier and created with the identifier if missing. Titles are
    never matched.
  - An entry with no `goodreads_series_id` is `invalid`.
  - The link uses `find_or_initialize_by(series:, book:)`:
    - a plain-number label sets `position` (decimal) and `numbered: true`;
    - any other label sets `numbered: false` and a nil `position`;
    - `position_label` is the label;
    - an existing link is `already_set` and left alone.
  - Callers run this only on the `goodreads_fetch` capsule (concurrency 1). Say so in the class
    comment: the find-then-create has no lock.

- [ ] **Step 1: Write failing tests:**
  - the first book creates the series and its identifier (`created`);
  - a second book with the same Goodreads series id links to the same series (`linked`, with
    `Books::Series.count` unchanged);
  - "0.5" gives position 0.5 and `numbered` true;
  - a blank position gives `numbered` false;
  - two entries give two links;
  - a re-run reports `already_set` and changes nothing;
  - two series with the same title but different ids stay two series.
- [ ] **Step 2–4:** Run (FAIL), implement, run (PASS).
- [ ] **Step 5:** Commit: `Create and link book series from Goodreads series data`.

---

### Task 8: Apply a matched page

**Files:**
- Create: `app/lib/services/books/human_cleared_fields.rb`, `app/lib/services/books/goodreads_enrichment/apply.rb`
- Modify: `app/lib/services/books/apply_book_facts.rb` (use `HumanClearedFields`; same behavior)
- Test: `test/lib/services/books/human_cleared_fields_test.rb`, `test/lib/services/books/goodreads_enrichment/apply_test.rb`

**Interfaces:**
- Consumes: `GenreMatcher` (Task 6), `ApplySeries` (Task 7), `BookIdentifierWriter` (Task 5), and the
  page columns (Task 2).
- Produces:
  - `Services::Books::HumanClearedFields.for(book) -> Set[String]`, which is today's
    `ApplyBookFacts#human_cleared_fields`, moved.
  - `Services::Books::GoodreadsEnrichment::Apply.call(book:, page:) -> Result(success?, data: {enrichment:, applied: [String]}, errors:)`.
    It runs in one transaction and writes exactly one `Enrichment` with `kind: "books.goodreads"`,
    `provider: "goodreads"`, `citations: ["https://www.goodreads.com/book/show/<id>"]`,
    `recognized: true`, and outcome `applied` when anything was written, `nothing_to_apply` otherwise.
    `facts` has one key per field:
    - `first_published_year`: from `original_publication_year`, filled when blank.
    - `page_range`: `page_count.to_s` when `page_range` is blank and `format` does not match
      `/audio|kindle|ebook|e-book/i`. The default edition's `page_count` is filled under the same
      condition when it is blank.
    - `genres`: per name `{"value", "applied", "reason"}`, where the reason is `filled`,
      `already_set`, `no_match` or `type_conflict`. An `"unmatched"` list is included. Links use
      `CategoryItem.find_or_create_by!(category:, item: book)` with `source: :goodreads` on create.
    - **Fiction/Nonfiction.** `Books::Book::BOOK_TYPE_CATEGORY_NAMES`: skip one when the book has
      the other. Skip both when the page maps to both and the book has neither.
    - `series`: from `ApplySeries`.
    - `identifiers`: see the identifier rules below.
    - A human-cleared column is `human_cleared`. A failing ISBN is `invalid`.
  - **Identifier rules (spec §5.3).**
    - Write `books_work_goodreads_id` (`page.goodreads_book_id`), the ISBN-13 and its ISBN-10 form
      (via `Books::Isbn.normalize`), and the ASIN: all-digit means checksum as ISBN-10, otherwise
      `/\A[A-Z0-9]{10}\z/`.
    - Call the writer twice: first the Goodreads id alone, then the ISBN and ASIN pairs.
    - If another book already holds this Goodreads id, from any source, skip **both** calls and
      flag the two books (`source: :identifier_collision`).
    - An ISBN conflict blocks only the ISBN and ASIN call.
  - **Never** writes the description anywhere.

- [ ] **Step 1: Write failing tests** for `HumanClearedFields` (moved behavior), and for `Apply`:
  - full apply on a blank book from a page row built in the test: year, `page_range`, linked
    categories with source `goodreads`, series, the identifiers, and one ledger row with `applied`;
  - a set year is `already_set` and unchanged;
  - a human-cleared `page_range` stays blank (`human_cleared`);
  - format "Kindle Edition" writes no `page_range`;
  - a bad ISBN-13 checksum is `invalid` and the rest is written;
  - an ISBN that Open Library gives another book: no ISBN written, Goodreads id written, both flagged;
  - a Goodreads id held by another book: no identifiers, flagged, and year and genres still written;
  - a page listing Fiction and Nonfiction for a book with neither: neither linked, both `type_conflict`;
  - `assert_no_difference "Description.count"`;
  - **idempotence (Review Focus 4):** `Apply` twice, and the second ledger row is `nothing_to_apply`
    with every fact `already_set`. The counts of `Identifier`, `CategoryItem`, `Books::SeriesBook` and
    `Books::Series` do not change on the second run.
- [ ] **Step 2–4:** Run (FAIL), implement, run with `test/lib/services/books/apply_book_facts_test.rb` (PASS).
- [ ] **Step 5:** Commit: `Apply a matched Goodreads page: year, page count, genres, series, identifiers`.

---

### Task 9: Finding the match: filter, pick, re-check, ledger

**Files:**
- Create: `app/lib/services/books/goodreads_enrichment/{candidate_filter,pick_candidate,page_check,ledger}.rb`
- Test: one test file each under `test/lib/services/books/goodreads_enrichment/`

**Interfaces:**
- Produces:
  - `CandidateFilter.call(book:, rows:) -> [SearchPage::Row]`: the survivors, sorted by
    `ratings_count` desc then `editions_count` desc, with nil counted as 0.
    - The author must agree: `Verification::Check.authors_agree?(book, AmazonBookCheck::Contributors.new(row.author_names, []))`.
    - The row title must not carry derivative or set words beyond the book's own
      (`AmazonBookCheck.derivative_words`, `set_words`, `own_words`).
    - The title check is loose: the book's main title (before ":"), normalized with
      `Verification::Check.normalize`, must appear inside the row title, normalized the same way,
      after the trailing series parenthetical is stripped (`BookPage::SERIES_SUFFIX`).
  - `PickCandidate.call(book:, rows:) -> SearchPage::Row | nil`.
    - It uses `Services::Ai::Tasks::Matching::SelectCandidateTask` with `entity_noun: "book"`, the
      top 5 rows, and `parent: book`.
    - `query_line` holds the title, authors and year. Each candidate line holds the title, authors,
      year, ratings and editions.
    - `guidance` holds the spec's non-match list: omnibus, box set, study guide, summary, single volume
      of a multi-volume work, abridged edition, adaptation such as a graphic novel or screenplay.
    - It returns the row only when `selected_index` is between 1 and the row count and `confidence == "high"`.
    - An AI failure returns nil and logs.
  - `PageCheck.call(book:, page:) -> Verdict = Data.define(:ok, :reason)`.
    - The page's title and contributor names (creators) go through the same three filters.
    - It also rejects:
      - genres matching `/study (guide|aid)s?|summar(y|ies)/i`;
      - any series position with a range (`/\d\s*[-–]\s*\d/`);
      - a title carrying set words.
    - The reasons are `author_mismatch`, `title_mismatch`, `derivative`, `set` and `study_aid`.
  - `Ledger.record(book:, outcome:, reason: nil, facts: {}, error: nil) -> Enrichment` writes a
    `books.goodreads` row with provider `goodreads`, for outcomes other than a match.
    A plan-time skip (`no_authors`) never runs the adapter, and a final failure ends in a raise. Both
    are recorded on the workflow step (`outcome`, `last_error`), not in the ledger. The spec's §5
    wording was amended to say so.

- [ ] **Step 1: Write failing tests.**
  - CandidateFilter, with real rows parsed from the fixtures:
    - on `catch_22_title_and_author`, a book "Catch-22" by Joseph Heller keeps exactly one row,
      `147719920`;
    - on `catch_22_title_only`, row `168668` is first and "Closing Time" is excluded.
  - PickCandidate, with `SelectCandidateTask#call` stubbed:
    - index 2 at high confidence returns row 2;
    - medium confidence returns nil;
    - index 0 returns nil;
    - index 9 returns nil.
  - PageCheck:
    - the stray-edition page passes for Catch-22;
    - a page whose genres include "Study Guides" gives `study_aid`;
    - series position "1-3" gives `set`.
  - Ledger: writes kind, provider, outcome and reason.
- [ ] **Step 2–4:** Run (FAIL), implement, run (PASS).
- [ ] **Step 5:** Commit: `Goodreads candidate filter, cheap-model pick, page re-check`.

---

### Task 10: The `goodreads` step and the version-2 book workflow

**Files:**
- Create: `app/lib/workflows/books/steps/goodreads.rb`
- Modify: `app/lib/workflows/books/book_enrichment.rb`, `app/lib/workflows/books/steps/book_facts.rb`, `app/lib/workflows/books/steps/amazon.rb` (only if it reads the run)
- Test: `test/lib/workflows/books/steps/goodreads_test.rb`, `test/lib/workflows/books/book_enrichment_test.rb`

**Interfaces:**
- Consumes: Tasks 2–4, 8 and 9.
- Produces:
  - `BookEnrichment`:
    - `version 2`;
    - `add_step key: :goodreads, queue: :goodreads_fetch, lease: 10.minutes, adapter: Steps::Goodreads.new`, declared first;
    - `book_facts` and `amazon` gain `waits_on: {goodreads: :finish}`;
    - `start` adds `goodreads: "no_authors"` to `skips` under the same condition as `amazon`.
    - Update the header comment.
  - `Steps::Goodreads#call(step:, run:, target:) -> Workflows::Outcome`. Progress lives in
    `step.result["progress"]`, which is merged on every wait: `{"phase", "query", "goodreads_book_id", "origin", "due", "followed_best", "searched_retry"}`.
  - **Phases** (spec §4):
    1. **Start.** With a `books_work_goodreads_id` on the book, go to `page` with `origin: "known"`.
       Otherwise go to `search`.
    2. **`search`.**
       - Use the fresh `Books::GoodreadsSearch` for the query, or take a gate turn and call `FetchSearch`.
       - Filter.
       - If none survive, retry once with `"<main title> <primary author surname>"`, then give up:
         `Ledger` outcome `unrecognized`, reason `no_match`.
       - Otherwise pick. No pick is `no_match`. A pick moves to `page` with `origin: "search"`.
    3. **`page`.**
       - Use the row when it is `found`, has HTML and is at `parser_version` 2. Run `Reparse` first
         when it has HTML at version 1.
       - Otherwise take a gate turn and call `FetchPage`, with `refresh: true` when the row exists
         without HTML.
       - If `best_book_id` is present, differs from the page's id, and `followed_best` is unset, set
         `followed_best` and go to `page` with the best id.
       - A best page that comes back `not_found` falls back to the page already held.
       - Then `PageCheck`. On failure, an `origin: "known"` page goes back to `search` (once). An
         `origin: "search"` page is `Ledger` outcome `unrecognized`, reason `rejected`.
       - On a pass, call `Apply`.
  - **Gate handling** (spec §4.1a):
    - `:wait` returns `Outcome.wait(Time.current + wait, result: {"progress" => progress.merge("due" => true)})`.
    - `:refused` with `:daily_cap` waits until the next UTC midnight, with `"due" => false`.
    - `:refused` with `:blocked` waits until `gate.blocked_until`, with `"due" => false`.
    - After a fetch, set `"due" => false` and call `GateTurn.after_fetch`.
    - `:blocked` or `:unparseable` returns a wait until `blocked_until`, keeping the phase.
    - `:unavailable` or `:fetcher_down` raises, so the coordinator retries.
  - **Finish:**
    - a match returns `Outcome.succeeded("matched", {"matched" => true, "goodreads_book_id" => id, "page_id" => page.id})`;
    - no match returns `Outcome.succeeded("no_match" | "rejected", {"matched" => false})`;
    - a raise from `Apply` propagates.
  - `Steps::BookFacts` reads `run.steps.find_by(key: "goodreads")`. When it succeeded with
    `result["matched"]`, it loads `::Books::GoodreadsPage.find_by(id: result["page_id"])` and passes
    it as `goodreads_page:` to `EnrichBook` (Task 11). Otherwise it passes nil.

- [ ] **Step 1: Write failing step tests.** Stub `GateTurn.call`, `FetchSearch`, `FetchPage` and
  `PickCandidate` with Mocha. Build page and search rows from the fixtures.
  - The happy path from no data:
    - search wait (due) → search fetch → page wait → stray page fetch (`147719920`, `best_book_id` 168668);
    - → page wait → main page → apply → `matched`, with `page_id` naming the 168668 row.
    - Assert that `FetchSearch` and `FetchPage` are each called only inside a `:fetch` decision.
  - **Review Focus 1:** after a `:wait` outcome, re-calling with the merged result calls
    `GateTurn.call(gate:, due: true)`.
  - A cached fresh search and a cached v2 page give zero fetches and a match in one execution.
  - A known id whose page fails the check falls back to search.
  - The daily cap gives a wait until the next UTC midnight (freeze time with `travel_to`).
  - `:unparseable` gives a wait until `blocked_until`. `:fetcher_down` raises.
  - **Review Focus 3:**
    - a best page whose own `best_book_id` names the first page is not followed again;
    - a best id that comes back `not_found` applies the first page.
  - No survivors after the retry gives `no_match`, one `unrecognized` ledger row, and
    `{"matched" => false}`.
- [ ] **Step 2: Write failing workflow tests.**
  - `start` plans three steps: `goodreads` ready, `book_facts` and `amazon` blocked on it.
  - A book with no authors plans `goodreads` skipped with `no_authors`.
  - **Review Focus 5:** a run created under the old shape (create the run with only `book_facts`
    and `amazon` step rows) runs `BookFacts` with `goodreads_page: nil` and no error.
  - `BookFacts` passes the page when the step matched.
- [ ] **Step 3:** Run, which should FAIL. **Step 4:** Implement. **Step 5:** Run
  `bin/rails test test/lib/workflows test/sidekiq/workflow_step_job_test.rb`, which should PASS.
- [ ] **Step 6:** Commit: `Goodreads step in the book enrichment workflow`.

---

### Task 11: Book AI `sourced` mode

**Files:**
- Modify: `app/lib/services/ai/tasks/enrichment_task.rb`, `app/lib/services/ai/tasks/books/book_facts_task.rb`, `app/lib/services/books/enrich_book.rb`
- Test: `test/lib/services/books/enrich_book_test.rb`, `test/lib/services/ai/tasks/books/book_facts_task_test.rb`

**Interfaces:**
- Consumes: `Enrichment` mode `sourced` (Task 5), and `goodreads_page:` from `BookFacts` (Task 10).
- Produces:
  - `EnrichmentTask::MODES = %i[knowledge research sourced]`; `sourced` uses `knowledge_role` and no tool.
  - `BookFactsTask.new(parent:, mode:, author_names:, source: nil, …)`, where `source` is a
    `Books::GoodreadsPage`.
    - In `sourced` mode, `user_prompt` adds a block: "Source material (Goodreads):" followed by the
      title, authors, first published, pages and genres. The page's `description` goes under the
      label `Publisher copy: use it for the premise only; write your own text and never copy its sentences:`.
      A page with a blank `description` omits that line. The run is still `sourced` (spec §4.5: a
      match without a description still skips research).
    - The system message adds: "Source material identifies the book: set recognized to true when it
      does, even if you did not know the book."
  - `EnrichBook.call(book:, force_research: false, author_names: nil, goodreads_page: nil)`:
    - The first mode is `force_research ? :research : (goodreads_page ? :sourced : (past_cutoff? ? :research : :knowledge))`.
    - The research fallback and the low-confidence deferral apply to `knowledge` only.
    - In `sourced` mode, `review_description` runs `DescriptionCheck.call(reviewed, source_text: goodreads_page.description, exempt_phrases: [book.title, *author_names])`.
      A `copied` error rejects the description.

- [ ] **Step 1: Write failing tests,** with `BookFactsTask#call` stubbed, as `enrich_book_test.rb` already does:
  - with a page on a 2026 book, one row with mode `sourced` and no `research` row
    (`assert_equal 0, Enrichment.research.count`);
  - `recognized: false` in sourced mode is not rewritten. The row is `unrecognized` and research still
    does not run;
  - a sourced description that copies 8 consecutive words from the page description gives a
    `rejected` description fact, and no `Description` is written;
  - with `force_research: true` and a page, the mode is `research`;
  - with no page, behavior is today's: the existing tests stay green;
  - `BookFactsTask` user prompt in sourced mode contains "Publisher copy:" and the genres. Knowledge
    mode does not.
- [ ] **Step 2–4:** Run (FAIL), implement, run `test/lib/services/books test/lib/services/ai` (PASS).
- [ ] **Step 5:** Commit: `Book AI sourced mode: Goodreads source material, no research run`.

---

### Task 12: Amazon searches by ISBN first

**Files:**
- Modify: `app/lib/services/books/amazon_product_service.rb` (`search_param_sets`)
- Test: `test/lib/services/books/amazon_product_service_test.rb`

**Interfaces:**
- Produces: when the book holds a `books_work_isbn13` from source `open_library`, `worldcat` or
  `goodreads`, the first param set is `{keywords: <isbn13>, search_index: "Books"}`.
  - Use one ISBN: the best by `Identifier.trust_rank`. Check its signature before use.
  - The existing keyword sets follow, unchanged.
  - A legacy-only ISBN adds nothing.

- [ ] **Step 1:** Failing tests:
  - a Goodreads ISBN comes first;
  - with an Open Library ISBN and a Goodreads ISBN, the higher trust rank is used;
  - a legacy ISBN alone leaves the sets unchanged.
- [ ] **Step 2–4:** Run (FAIL), implement, run the file (PASS).
- [ ] **Step 5:** Commit: `Amazon product search tries a trusted ISBN first`.

---

### Task 13: End-to-end test, docs, full suite

**Files:**
- Test: `test/integration/books/goodreads_enrichment_flow_test.rb`
- Docs: `docs/features/enrichment-workflows.md` (book workflow table, the Goodreads step, version
  tolerance), `docs/features/books_enrichment.md` (sourced mode, the `books.goodreads` ledger kind),
  `docs/features/goodreads-import.md` (parser v2, the shared gate turn, the search cache, enrichment
  sharing the daily cap), `docs/features/data_importers.md` (what a new book gets).

- [ ] **Step 1: Write the integration test** (spec acceptance scenario 1).
  - Set it up:
    - `Workflows::Books::BookEnrichment.start` on a new book "Catch-22" by a new author "Joseph Heller";
    - stub the page fetcher with the fixtures (title search → `168668`, which needs a captured or
      constructed v2 page for 168668; build it by editing the stray fixture's ids if no capture exists);
    - stub `SelectCandidateTask` to high confidence on candidate 1, `BookFactsTask` and
      `DescriptionReviewTask` to fixed replies, and `GateTurn.call` to `:fetch`.
  - Drive `WorkflowStepJob` until the run closes.
  - Assert:
    - the year, `page_range`, at least one `CategoryItem` with source `goodreads`, and
      `books_work_goodreads_id` 168668 are written;
    - a `books.book_facts` row has mode `sourced`, and there is no research row;
    - an `ai_generated` description exists;
    - the run is closed, with `amazon` run after `goodreads`.
- [ ] **Step 2:** Run it, and fix wiring gaps until it passes.
- [ ] **Step 3:** Update the four docs: what the step does, the find/apply split (spec §10), and the shared budget.
- [ ] **Step 4:** Run `bin/rails db:test:prepare test` and `bundle exec standardrb`. Expect both
  green with no new warnings. Then `CI=1 bin/rails zeitwerk:check`.
- [ ] **Step 5:** Commit: `Goodreads enrichment end-to-end test and docs`.

No Playwright test: the change adds no user-facing page. The admin "Enrichment runs" card already
renders any step.
