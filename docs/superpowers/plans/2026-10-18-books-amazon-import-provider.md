# Books Amazon Import Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every new book from the books importer, and every promoted Goodreads book, is queued for
the existing Amazon enrichment. Set products (box sets, omnibuses, collections) never become editions.
An accepted product that is exactly this book also writes its ISBN-13, ISBN-10 and ASIN to the book,
with source `amazon`.

**Architecture:** A new async importer provider queues `Books::AmazonProductEnrichmentJob` after
commit. `Services::Books::AmazonBookCheck` holds the two deterministic tests: "is this a set" and "is
this exactly the book". `Services::Books::AmazonProductService#persist_match` uses the set test to
skip products before the edition upsert. It then hands exact matches to a new
`Services::Books::AmazonBookIdentifiers`, which writes the book-level identifiers. On a collision with
a verified identifier on another book, it writes nothing and raises a `DuplicateCandidate` instead.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, WebMock, Sidekiq 8 (inline in tests).

**Spec:** `docs/superpowers/specs/2026-10-18-books-amazon-import-provider-design.md`

## Global Constraints

- Run every Rails command from `web-app/` in this worktree:
  `/home/shane/dev/the-greatest/.claude/worktrees/books-amazon-import-provider/web-app`.
- Book-level identifier types: `books_work_isbn13`, `books_work_isbn10`, `books_work_asin`. Source is
  `:amazon`, set only on a new row and never changed on an existing one.
- Writes use `find_or_initialize_by`, never `build`.
- Verified sources are `Identifier::VERIFIED_SOURCES` (`open_library`, `worldcat`). Every other source,
  nil included, counts as unverified.
- Duplicate flag: `Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [book.id,
  holder_id], source: :identifier_collision, evidence: {...})`.
- Set words: `Services::Books::Verification::EditionCheck::SET_WORDS`. Reuse it; never copy the regex.
- Inside `module Services; module Books`, root-anchor every model: `::Books::Book`, `::Identifier`,
  `::DuplicateCandidate`.
- Never hit the network in tests. Stub `::Services::Amazon::Client.search_items` and
  `AmazonBookMatchTask#call` with Mocha, and images with `stub_request`.
- `assert_equal nil, x` is a hard failure in Minitest 6. Use `assert_nil`.
- The Amazon job stays on `queue: :serial`. No throttle and no bulk opt-out.
- Lint is `bundle exec standardrb`, never `bin/rubocop`. Do not run brakeman.

## Review Focus

1. **A missing or odd Amazon title.** A product with a nil `itemInfo.title.displayValue`, or one that
   is only brackets ("(Boxed Set)"), must make `same_book?` false and `set?` decide on the binding
   alone. It must never raise. Tested in Task 1.
2. **A bad ISBN checksum.** An ISBN or EAN Amazon returns that fails `::Books::Isbn.normalize` is not
   written to the book. Tested in Task 3.
3. **A book whose own title carries a set word** (Calvino's *Collection of Sand*). Its own Amazon
   editions are not treated as sets. Tested in Task 1.
4. **The value is already on this book** (legacy source, or a re-run). No second row is created and
   the existing source is unchanged. Tested in Task 3.
5. **No usable contributors.** `byLineInfo.contributors` is nil, or holds only a Translator. Then
   `same_book?` is false; the edition is still written, but no book-level identifiers. Tested in
   Tasks 1 and 3.

---

### Task 1: `Services::Books::AmazonBookCheck`

**Files:**
- Create: `app/lib/services/books/amazon_book_check.rb`
- Modify: `app/lib/services/books/amazon_edition_upserter.rb`: delete the private `split_title` and
  call `AmazonBookCheck.split_title` from `apply_descriptive`.
- Test: `test/lib/services/books/amazon_book_check_test.rb`

**Interfaces:**
- Consumes: `Verification::EditionCheck.title_agrees?(book, work, edition)`, `.year_ok?(book, year)`,
  `::SET_WORDS`; `Verification::Check.authors_agree?(book, work, ol_authors: [])` (reads
  `work.author_names` and `work.author_keys`) and `Check.normalize(text)`.
- Produces (module functions, `module_function`):
  - `AmazonBookCheck.split_title(raw) -> [title_or_nil, subtitle_or_nil]`. Moved verbatim from the
    upserter, with its comment.
  - `AmazonBookCheck.set?(book, product) -> Boolean`
  - `AmazonBookCheck.same_book?(book, product) -> Boolean`
  - `AmazonBookCheck.author_names(product) -> Array<String>`: the names of contributors whose `role`
    is `"Author"`.

**Rules for `set?`:**
1. True when `product.dig("itemInfo", "classifications", "binding", "displayValue")` matches `/\bbox/i`.
2. Take the raw title `product.dig("itemInfo", "title", "displayValue")`. Remove every bracketed part,
   `(...)` or `[...]`, that contains a single-book marker. The marker regex is
   `/\b(?:book|vol(?:ume)?\.?|#)\s*\d+\b(?!\s*(?:-|–|to|through|and|&)\s*\d)/i`.
3. Collect the `SET_WORDS` matches in what remains, downcased: `text.to_enum(:scan, SET_WORDS).map {
   Regexp.last_match(0).downcase }`.
4. Collect the same from `book.title` and each of `book.alternate_titles`.
5. True when the product holds a match the book does not.

**Rules for `same_book?`:** all of the following.
- `set?` is false.
- `EditionCheck.title_agrees?(book, nil, Data.define(:title, :subtitle).new(*split_title(raw)))` is
  true. Define that small Data class once as a constant.
- `EditionCheck.year_ok?(book, year)`, where year is the first 4 digits of
  `itemInfo.contentInfo.publicationDate.displayValue`, or nil.
- `author_names(product)` is present, and `Check.authors_agree?(book, Data.define(:author_names,
  :author_keys).new(names, []))` is true.

- [ ] **Step 1: Write the failing tests**

Book: `books_books(:war_and_peace)` (author Leo Tolstoy via `war_and_peace_tolstoy`,
`first_published_year: 1869`). Use a helper `product(title:, binding: "Paperback", date:
"2008-10-14T00:00:01Z", authors: ["Leo Tolstoy"], roles: nil)`. It builds the Creators API hash shape
from `amazon_product_service_test.rb`, with `byLineInfo.contributors = [{"name" => n, "role" =>
"Author"}]`.

```ruby
test "split_title strips packaging and splits on the first colon" do
  assert_equal ["War and Peace", "A Novel"], AmazonBookCheck.split_title("War and Peace: A Novel (Vintage Classics) [Paperback]")
  assert_equal [nil, nil], AmazonBookCheck.split_title(nil)
end

test "set? is true for a set word in brackets, a set subtitle, a set head title, or a box binding" do
  book = books_books(:war_and_peace)
  assert AmazonBookCheck.set?(book, product(title: "War and Peace (Boxed Set)"))
  assert AmazonBookCheck.set?(book, product(title: "War and Peace (4-Book Boxed Set)"))
  assert AmazonBookCheck.set?(book, product(title: "War and Peace: Books 1-3"))
  assert AmazonBookCheck.set?(book, product(title: "The Tolstoy Collection"))
  assert AmazonBookCheck.set?(book, product(title: "War and Peace", binding: "Boxed Set"))
end

test "set? is false for a single-book series marker and a plain edition" do
  book = books_books(:war_and_peace)
  refute AmazonBookCheck.set?(book, product(title: "War and Peace (Tolstoy Trilogy, Book 1)"))
  refute AmazonBookCheck.set?(book, product(title: "War and Peace (Vintage Classics)"))
end

test "set? ignores a set word the book's own title carries" do
  book = ::Books::Book.create!(title: "Collection of Sand")
  refute AmazonBookCheck.set?(book, product(title: "Collection of Sand: Essays (Penguin Modern Classics)"))
  assert AmazonBookCheck.set?(book, product(title: "Collection of Sand (Boxed Set)"))
end

test "same_book? accepts an exact title, a dropped subtitle and an alternate title" do
  book = books_books(:war_and_peace)
  assert AmazonBookCheck.same_book?(book, product(title: "War and Peace (Vintage Classics)"))
  assert AmazonBookCheck.same_book?(book, product(title: "War and Peace: A Novel"))
  book.update!(alternate_titles: ["Voina i mir"])
  assert AmazonBookCheck.same_book?(book, product(title: "Voina i mir"))
end

test "same_book? rejects a set, another title, an earlier year, another author, or no author" do
  book = books_books(:war_and_peace)
  refute AmazonBookCheck.same_book?(book, product(title: "War and Peace (Boxed Set)"))
  refute AmazonBookCheck.same_book?(book, product(title: "Anna Karenina"))
  refute AmazonBookCheck.same_book?(book, product(title: "War and Peace", date: "1801-01-01"))
  refute AmazonBookCheck.same_book?(book, product(title: "War and Peace", authors: ["Someone Else"]))
  refute AmazonBookCheck.same_book?(book, product(title: "War and Peace", authors: []))
end

test "same_book? ignores contributors who are not authors" do
  book = books_books(:war_and_peace)
  translator_only = product(title: "War and Peace", authors: ["Leo Tolstoy"], roles: ["Translator"])
  refute AmazonBookCheck.same_book?(book, translator_only)
end

test "a missing or bracket-only title never raises" do
  book = books_books(:war_and_peace)
  untitled = product(title: nil)
  refute AmazonBookCheck.same_book?(book, untitled)
  refute AmazonBookCheck.set?(book, untitled)
  assert AmazonBookCheck.set?(book, product(title: "(Boxed Set)"))
end
```

- [ ] **Step 2: Run them and see them fail**

Run: `bin/rails test test/lib/services/books/amazon_book_check_test.rb`
Expected: errors with `NameError: uninitialized constant Services::Books::AmazonBookCheck`.

- [ ] **Step 3: Implement `Services::Books::AmazonBookCheck` per the rules above, and switch the upserter to `AmazonBookCheck.split_title`.**

- [ ] **Step 4: Run the new tests and the upserter's own tests**

Run: `bin/rails test test/lib/services/books/amazon_book_check_test.rb test/lib/services/books/amazon_edition_upserter_test.rb`
Expected: all pass. The upserter tests are unchanged and prove the move kept behavior.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/amazon_book_check.rb app/lib/services/books/amazon_edition_upserter.rb test/lib/services/books/amazon_book_check_test.rb
git add app/lib/services/books/amazon_book_check.rb app/lib/services/books/amazon_edition_upserter.rb test/lib/services/books/amazon_book_check_test.rb
git commit -m "Books Amazon: set and same-book checks for Amazon products"
```

---

### Task 2: Set products never become editions

**Files:**
- Modify: `app/lib/services/ai/tasks/books/amazon_book_match_task.rb` (`non_match_criteria`)
- Modify: `app/lib/services/books/amazon_product_service.rb` (`persist_match`)
- Test: `test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb`,
  `test/lib/services/books/amazon_product_service_test.rb`

**Interfaces:**
- Consumes: `AmazonBookCheck.set?(book, product)` (Task 1).
- Produces: `persist_match` returns nil and writes nothing when `set?` is true.

- [ ] **Step 1: Write the failing tests**

In the match task test, assert the rendered prompt contains the new criteria. Use however that file
already reaches the prompt text:

```ruby
test "non-match criteria exclude box sets, omnibus editions and collections" do
  # prompt = <the existing way this test file renders the system/user prompt>
  assert_match(/box sets/i, prompt)
  assert_match(/omnibus/i, prompt)
  assert_match(/collections, anthologies or bundles that contain this book together with others/i, prompt)
end
```

In the service test, add these. Use the existing `amazon_product`, `stub_ai_match` and `stub_image`
helpers; build a variant with `amazon_product.deep_merge("itemInfo" => {"title" => {"displayValue" =>
"War and Peace (Boxed Set)"}})`.

```ruby
test "an AI-accepted box set writes no edition, link or cover" do
  ::Services::Amazon::Client.stubs(:search_items).returns([boxed])   # boxed = the variant above
  stub_ai_match
  stub_image

  assert_no_difference ["::Books::Edition.count", "ExternalLink.count", "Image.count"] do
    AmazonProductService.call(book: @book)
  end
end

test "a single-book series marker still becomes an edition" do
  # title "War and Peace (Tolstoy Trilogy, Book 1)"
  ::Services::Amazon::Client.stubs(:search_items).returns([marker])
  stub_ai_match
  stub_image

  assert_difference "::Books::Edition.count", 1 do
    AmazonProductService.call(book: @book)
  end
end
```

- [ ] **Step 2: Run them and see them fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb test/lib/services/books/amazon_product_service_test.rb`
Expected: the three new tests fail. The box set creates an edition, and the prompt lacks the words.

- [ ] **Step 3: Implement**

- Append to `non_match_criteria`, exact copy:
  - `- Box sets, omnibus editions, or multi-book bundles`
  - `- Collections, anthologies or bundles that contain this book together with others`
- At the top of `persist_match`, add `if ::Services::Books::AmazonBookCheck.set?(book, product)`.
  When it's true, log `"Skipping set product #{product["asin"]} for book #{book.id}"` and return nil.

- [ ] **Step 4: Run the tests again and see them pass**

Same command as Step 2. Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/ai/tasks/books/amazon_book_match_task.rb app/lib/services/books/amazon_product_service.rb test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb test/lib/services/books/amazon_product_service_test.rb
git add -A app/lib/services test/lib/services
git commit -m "Books Amazon: box sets, omnibuses and collections never become editions"
```

---

### Task 3: Book-level identifiers from exact matches

**Files:**
- Create: `app/lib/services/books/amazon_book_identifiers.rb`
- Modify: `app/lib/services/books/amazon_product_service.rb` (`persist_match`)
- Test: `test/lib/services/books/amazon_book_identifiers_test.rb`,
  `test/lib/services/books/amazon_product_service_test.rb`

**Interfaces:**
- Consumes: `AmazonBookCheck.same_book?` (Task 1); `::Books::Isbn.normalize(raw) ->
  Normalized(isbn13, isbn10) | nil`; `Services::DuplicateCandidates::Flag.call`.
- Produces: `Services::Books::AmazonBookIdentifiers.call(book:, product:) -> Result`, where `Result =
  Struct.new(:written, :flagged_book_ids, keyword_init: true)`.
  - `written` is an `Array<[identifier_type_string, value]>` of the rows this call created or found
    on the book.
  - `flagged_book_ids` is an `Array<Integer>`.
  - It does **not** call `same_book?`; the caller decides.

**Values.** Build the `[type, value]` pairs, deduped:
- `"books_work_asin"` from `product["asin"]`, when present.
- Each `itemInfo.externalIds.isbns.displayValues` through `::Books::Isbn.normalize`. A 13-character
  raw value gives `"books_work_isbn13"` with `normalized.isbn13`. A 10-character raw value gives
  `"books_work_isbn10"` with `normalized.isbn10`. If `normalize` returns nil, skip the value.
- Each `itemInfo.externalIds.eans.displayValues` that normalizes and starts with `978` or `979` gives
  `"books_work_isbn13"`. Every other EAN is skipped.

**Collision.** Run `::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value:
value).where.not(identifiable_id: book.id).verified` across all the pairs.
- If any rows come back, write **nothing**.
- Call `Flag` once per distinct holder book id, with evidence `{"amazon_asin" => asin, "amazon_title"
  => raw_title, "conflicts" => [{"identifier_type", "value", "holder_book_id", "holder_source"}, ...]}`
  (only that holder's conflicts), and `match_decision: nil`.
- Return `Result.new(written: [], flagged_book_ids: ids)`.

**Write.** Otherwise, inside one transaction, for each pair:
`book.identifiers.find_or_initialize_by(identifier_type: type, value: value)`, set `source = :amazon`
only when it's a new record, then `save!`.

- [ ] **Step 1: Write the failing tests**

`amazon_book_identifiers_test.rb`. The product helper takes `asin:`, `isbns:` and `eans:`. Use real,
checksum-valid values: ISBN-13 `9780140447934` (already on war_and_peace as the fixture
`war_and_peace_isbn13`, source nil), `9781400079988` and its ISBN-10 `1400079985`. For an invalid
checksum, use `9781400079980`.

```ruby
test "writes ASIN, ISBN-13 and ISBN-10 to the book with source amazon" do
  book = books_books(:war_and_peace)
  AmazonBookIdentifiers.call(book: book, product: product(asin: "B000FC0PDA", isbns: ["9781400079988", "1400079985"]))
  rows = book.identifiers.where(identifier_type: %w[books_work_asin books_work_isbn13 books_work_isbn10], source: :amazon)
  assert_equal [["books_work_asin", "B000FC0PDA"], ["books_work_isbn10", "1400079985"], ["books_work_isbn13", "9781400079988"]],
    rows.pluck(:identifier_type, :value).sort
end

test "a 978 EAN is written as ISBN-13; any other EAN and any bad checksum are not" do
  book = books_books(:war_and_peace)
  AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079980"], eans: ["9781400079988", "4006381333931"]))
  assert book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988", source: :amazon)
  refute book.identifiers.exists?(value: "9781400079980")
  refute ::Identifier.exists?(value: "4006381333931", identifiable_type: "Books::Book")
end

test "a value already on the book keeps its row and its source; a re-run adds nothing" do
  book = books_books(:war_and_peace)
  existing = identifiers(:war_and_peace_isbn13)
  assert_no_difference "::Identifier.count" do
    2.times { AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9780140447934"])) }
  end
  assert_nil existing.reload.source
end

test "a value held by another book with an unverified source is still written" do
  other = ::Books::Book.create!(title: "Other")
  other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :legacy)
  book = books_books(:war_and_peace)
  result = AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079988"]))
  assert book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988")
  assert_empty result.flagged_book_ids
  assert_equal 0, ::DuplicateCandidate.count
end

test "a value held verified by another book writes none of the product's values and flags the pair once" do
  other = ::Books::Book.create!(title: "Other")
  other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :worldcat)
  book = books_books(:war_and_peace)
  p = product(asin: "B000FC0PDA", isbns: ["9781400079988", "1400079985"])

  assert_no_difference "book.identifiers.count" do
    2.times { AmazonBookIdentifiers.call(book: book, product: p) }
  end
  candidate = ::DuplicateCandidate.sole
  assert_equal ["Books::Book", "identifier_collision", "pending", 2],
    [candidate.item_type, candidate.source, candidate.status, candidate.occurrences]
  assert_equal [book.id, other.id].sort, [candidate.item_a_id, candidate.item_b_id]
  assert_equal "B000FC0PDA", candidate.evidence["amazon_asin"]
end

test "a pair already marked not_duplicate stays closed" do
  other = ::Books::Book.create!(title: "Other")
  other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :open_library)
  book = books_books(:war_and_peace)
  a, b = [book.id, other.id].minmax
  ::DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: a, item_b_id: b, source: :identifier_collision, status: :not_duplicate, evidence: {})
  AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079988"]))
  assert ::DuplicateCandidate.sole.not_duplicate?
end
```

In `amazon_product_service_test.rb`, the existing `amazon_product` has no `externalIds` or
contributors. Give the variants `"itemInfo" => {"externalIds" => {"isbns" => {"displayValues" =>
["9781400079988"]}}, "byLineInfo" => {"contributors" => [{"name" => "Leo Tolstoy", "role" =>
"Author"}]}}`, using `deep_merge`.

```ruby
test "an exact match also writes its identifiers to the book" do
  # variant: title "War and Peace (Vintage Classics)", Leo Tolstoy as Author, ISBN 9781400079988
  ::Services::Amazon::Client.stubs(:search_items).returns([exact])
  stub_ai_match
  stub_image
  AmazonProductService.call(book: @book)
  assert @book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988", source: :amazon)
  assert @book.identifiers.exists?(identifier_type: :books_work_asin, value: "1400079985", source: :amazon)
end

test "an accepted product that is not exactly the book still becomes an edition but writes no book identifiers" do
  # variant: same, but contributors [] (no author)
  ::Services::Amazon::Client.stubs(:search_items).returns([no_author])
  stub_ai_match
  stub_image
  assert_difference "::Books::Edition.count", 1 do
    AmazonProductService.call(book: @book)
  end
  refute @book.identifiers.exists?(source: :amazon)
end

test "a failure writing book identifiers is reported but the run still succeeds" do
  ::Services::Amazon::Client.stubs(:search_items).returns([exact])
  stub_ai_match
  stub_image
  ::Services::Books::AmazonBookIdentifiers.stubs(:call).raises(StandardError, "boom")
  result = AmazonProductService.call(book: @book)
  assert result[:success]
  assert_equal 1, @book.editions.joins(:identifiers).where(identifiers: {value: "1400079985"}).count
  assert(result[:errors].any? { |e| e.include?("boom") })
end
```

- [ ] **Step 2: Run them and see them fail**

Run: `bin/rails test test/lib/services/books/amazon_book_identifiers_test.rb test/lib/services/books/amazon_product_service_test.rb`
Expected: NameError for `AmazonBookIdentifiers`; the service tests fail on the missing book-level rows.

- [ ] **Step 3: Implement `AmazonBookIdentifiers` per the rules above.**

In `persist_match`, after the edition upsert and before the link and cover, call a private
`write_book_identifiers(product)`. It calls `AmazonBookIdentifiers.call(book:, product:)` only when
`AmazonBookCheck.same_book?(book, product)`. It rescues `=> e` by appending `"Failed to write book
identifiers for ASIN #{product["asin"]}: #{e.message}"` to `@errors` and logging, the same way
`attach_book_affiliate_link` does.

- [ ] **Step 4: Run the tests again and see them pass**

Same command as Step 2. Expected: all pass.

- [ ] **Step 5: Prove each guard matters**

Delete one guard at a time, run the identifiers test file, confirm a test goes red, and restore it:
- the verified-collision branch;
- `same_book?` in the service;
- the 978/979 EAN prefix check;
- the `new_record?` source guard.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books test/lib/services/books
git add app/lib/services/books/amazon_book_identifiers.rb app/lib/services/books/amazon_product_service.rb test/lib/services/books/amazon_book_identifiers_test.rb test/lib/services/books/amazon_product_service_test.rb
git commit -m "Books Amazon: exact matches write book-level identifiers; verified collisions flag a duplicate"
```

---

### Task 4: Importer provider, wizard wiring, global test stub

**Files:**
- Create: `app/lib/data_importers/books/book/providers/amazon.rb`
- Modify: `app/lib/data_importers/books/book/importer.rb`: append `Providers::Amazon.new` as the
  **last** provider inside `if @enrich`, and add one sentence to the `providers` comment.
- Modify: `app/lib/services/lists/wizard/books/adapter.rb`: `TEXT_PROVIDERS = %i[authors ai_enrichment
  author_enrichment amazon].freeze`.
- Modify: `test/test_helper.rb`: in the existing `ActiveSupport::TestCase` `setup do` block, add
  `::Books::AmazonProductEnrichmentJob.stubs(:perform_async)`, with a comment. The comment should say
  that Sidekiq runs jobs inline in tests, so any test that imports a new book would otherwise run the
  real Amazon job against WebMock or missing credentials, and that a test that cares overrides this
  with `expects`.
- Test: `test/lib/data_importers/books/book/providers/amazon_test.rb`,
  `test/lib/data_importers/books/book/importer_test.rb`,
  `test/lib/services/lists/wizard/books/adapter_test.rb`

**Interfaces:**
- Produces: `DataImporters::Books::Book::Providers::Amazon#populate(book, query:, match: nil) ->
  ProviderResult`.
  - Fails with `"Book title required for Amazon enrichment"` when the title is blank.
  - Fails with `"Book must have an author for Amazon enrichment"` when `book.authors` is empty. Without
    this, the job would fail and retry indefinitely.
  - Fails with `"Book must be persisted before queuing Amazon enrichment"` when not persisted.
  - Otherwise queues `::Books::AmazonProductEnrichmentJob.perform_async(book.id)` inside
    `::ActiveRecord.after_all_transactions_commit`, and returns `success_result(data_populated:
    [:amazon_enrichment_queued])`.
  - Rescues `=> e` into `failure_result(errors: ["Amazon provider error: #{e.message}"])`.
  - Model it on `providers/ai_enrichment.rb`, including its after-commit comment.

- [ ] **Step 1: Write the failing tests**

`amazon_test.rb`:

```ruby
test "queues the Amazon job for a persisted book with an author" do
  book = books_books(:war_and_peace)
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).with(book.id)
  result = Amazon.new.populate(book, query: nil)
  assert result.success?
  assert_equal [:amazon_enrichment_queued], result.data_populated
end

test "queues nothing when the surrounding transaction rolls back" do
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).never
  ActiveRecord::Base.transaction(requires_new: true) do
    book = ::Books::Book.create!(title: "Rolled Back")
    book.book_authors.create!(author: books_authors(:tolstoy), position: 1)
    Amazon.new.populate(book, query: nil)
    raise ActiveRecord::Rollback
  end
end

test "fails without a title, without an author, or unsaved, and queues nothing" do
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).never
  assert_includes Amazon.new.populate(::Books::Book.new(title: ""), query: nil).errors, "Book title required for Amazon enrichment"
  assert_includes Amazon.new.populate(::Books::Book.create!(title: "No Author"), query: nil).errors, "Book must have an author for Amazon enrichment"
  unsaved = ::Books::Book.new(title: "Unsaved")
  unsaved.stubs(:authors).returns([books_authors(:tolstoy)])
  assert_includes Amazon.new.populate(unsaved, query: nil).errors, "Book must be persisted before queuing Amazon enrichment"
end
```

In `importer_test.rb`:
- Update `"providers run Open Library, Authors, AI enrichment, then the new authors' chain"` to expect
  `[Providers::OpenLibrary, Providers::Authors, Providers::AiEnrichment, Providers::AuthorEnrichment,
  Providers::Amazon]`, and rename it to add ", then Amazon".
- Add:

```ruby
test "a new book with enrichment on queues Amazon once" do
  stub_resolve_down
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).once
  result = Importer.call(title: "Hadji Murat", author_names: ["Leo Tolstoy"])
  assert_includes result.summary[:data_populated], :amazon_enrichment_queued
end

test "enrich: false does not queue Amazon" do
  stub_resolve_down
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).never
  Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], enrich: false)
end
```

In `adapter_test.rb`, add an end-to-end test with the **real** importer, no mock. Nothing today proves
the wizard queues anything:

```ruby
test "creating a text row with the real importer queues AI enrichment and Amazon" do
  row = wizard_row(@list, position: 1, title: "A Brand New Tolstoy Book", authors: ["Leo Tolstoy"], wizard: {bucket: "create"})
  ::Books::EnrichBookJob.expects(:perform_async).once
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).once
  book = @adapter.create(row)
  assert book.persisted?
end
```

- [ ] **Step 2: Run them and see them fail**

Run: `bin/rails test test/lib/data_importers/books/book/providers/amazon_test.rb test/lib/data_importers/books/book/importer_test.rb test/lib/services/lists/wizard/books/adapter_test.rb`
Expected: NameError for `Providers::Amazon`; the order test and the queueing tests fail.

- [ ] **Step 3: Implement the provider and the wiring, and add the global stub to `test_helper.rb`.**

- [ ] **Step 4: Run the tests again and see them pass**

Same command as Step 2. Expected: all pass.

- [ ] **Step 5: Run the whole suite**

Before the global stub existed, any test importing a new book ran the real Amazon job inline. Confirm
nothing still does.

Run: `bin/rails test`
Expected: 0 failures, 0 errors, and no new warning lines.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/books app/lib/services/lists test/lib/data_importers/books test/lib/services/lists test/test_helper.rb
git add app/lib/data_importers/books app/lib/services/lists/wizard/books/adapter.rb test/lib/data_importers/books test/lib/services/lists/wizard/books/adapter_test.rb test/test_helper.rb
git commit -m "Books importer: queue Amazon enrichment for new books, list wizard included"
```

---

### Task 5: Goodreads promotion queues Amazon

**Files:**
- Modify: `app/lib/services/books/goodreads_imports/promote_records.rb`
- Modify: `test/support/goodreads_import_helper.rb`: next to its `EnrichBookJob` stub, add
  `::Books::AmazonProductEnrichmentJob.stubs(:perform_async)`. This only spells out what the global
  stub already does, but keeps that helper's list of stubbed jobs complete.
- Test: `test/lib/services/books/goodreads_imports/promote_records_test.rb`

**Interfaces:**
- Consumes: the existing `ActiveRecord.after_all_transactions_commit` block in `PromoteRecords#call`.
- Produces: `::Books::AmazonProductEnrichmentJob.perform_async(id)` for every id in `@books`, including
  books whose AI enrichment was deferred to the author chain.

- [ ] **Step 1: Write the failing test**

```ruby
test "every promoted book queues Amazon, including one waiting on its author's chain" do
  ::Books::Authors::WikidataJob.stubs(:perform_async)
  ::Books::EnrichBookJob.stubs(:perform_async)
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).with(@book.id)
  ::Books::AmazonProductEnrichmentJob.expects(:perform_async).with(@plain.id)

  PromoteRecords.call(books: [@book, @plain], authors: [])
end
```

Also, in `"an already promoted record is left alone and queues nothing"`, add
`::Books::AmazonProductEnrichmentJob.expects(:perform_async).never`.

- [ ] **Step 2: Run it and see it fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/promote_records_test.rb`
Expected: the new test fails on unsatisfied expectations.

- [ ] **Step 3: Implement**

Inside the existing after-commit block, add `@books.each { |book|
::Books::AmazonProductEnrichmentJob.perform_async(book.id) }`.

- [ ] **Step 4: Run the Goodreads tests and see them pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/ test/controllers/admin/books/goodreads_imports_controller_test.rb`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/goodreads_imports/promote_records.rb test/lib/services/books/goodreads_imports/promote_records_test.rb test/support/goodreads_import_helper.rb
git add app/lib/services/books/goodreads_imports/promote_records.rb test/lib/services/books/goodreads_imports/promote_records_test.rb test/support/goodreads_import_helper.rb
git commit -m "Goodreads import: promoting a book queues Amazon enrichment"
```

---

### Task 6: Docs and final gate

**Files** (all paths from the project root, `docs/` is a sibling of `web-app/`):
- Modify: `docs/features/data_importers.md`
  - In the "Supported Media Types" table, change the Books Book row's providers to `OpenLibrary,
    Authors, AiEnrichment, AuthorEnrichment, Amazon`.
  - Add a "#### Amazon (Async)" section under "### Books Providers". Cover:
    - it queues `Books::AmazonProductEnrichmentJob` after commit, on `serial`;
    - it is gated by `enrich:`, so Goodreads imports get it at promotion;
    - list-wizard text rows include it through `TEXT_PROVIDERS`;
    - set products never become editions;
    - an exact match writes `books_work_*` identifiers with source `amazon`;
    - a verified collision raises an `identifier_collision` duplicate candidate instead;
    - locally it needs a running Sidekiq.
- Modify: `docs/features/goodreads-import.md`: promotion also queues Amazon enrichment.
- Modify: `docs/features/books_enrichment.md` *only if* it lists what runs on import. Otherwise leave
  it alone.

- [ ] **Step 1: Write the doc changes above.** Plain prose, matching each file's voice. No per-class
  doc files.

- [ ] **Step 2: Run the final gate**

Run, from `web-app/`:
```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```
Expected:
- `bin/rails test`: 0 failures and 0 errors, with no warning lines beyond the two known upstream
  sources;
- `standardrb`: no offenses;
- `zeitwerk:check`: "All is good!".

- [ ] **Step 3: Commit**

```bash
git add ../docs/features/data_importers.md ../docs/features/goodreads-import.md
git commit -m "Docs: books Amazon importer provider, set filtering and book-level identifiers"
```
