# User-added Books Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in reader can ask for a book the site does not have, it lands on their list as a provisional book, and agents or an admin approve, merge or reject it.

**Architecture:** A `Books::BookSubmission` row holds what the reader gave. The request does a Postgres-only instant check; everything that calls out runs in Sidekiq jobs on priority lanes, reusing the book finder, importer, enrichment workflow and provisional-record machinery. Review rules live in `Services::Books::BookSubmissions`, shared by an admin API (exposed over MCP) and an admin page.

**Tech Stack:** Rails 8, Postgres, Sidekiq, Turbo/Stimulus, ViewComponent, daisyUI 5, Minitest + Mocha, Playwright, openapi_first.

**Spec:** `docs/superpowers/specs/2026-11-23-user-added-books-design.md` (read it with this plan)

## Global Constraints

- Before Task 1: this worktree has `.env`, `web-app/.env` and `master.key`; copy `web-app/e2e/.env` and link `web-app/node_modules` from the main checkout, then run `yarn build:all` once (layouts fail to render without it).
- Run Rails/yarn commands from `web-app/`. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`; commit annotations with the migration, deleting lines for columns other branches added to the shared dev database.
- Use Rails generators for models, controllers, jobs (`bin/rails generate sidekiq:job books/...`) and components.
- Services: `app/lib/services/books/book_submissions/`, `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. Root-anchor (`::Books::Book`) inside `Services::Books`, `Api::V1::Admin::Books`.
- No Open Library, WorldCat, Wikidata, Goodreads, Amazon or AI call in a web request. The pasted URL is never fetched.
- One input method per request: `goodreads`, `amazon`, `isbn`, `title_authors`. The server refuses more than one.
- Limits: title 255, 1 to 10 authors of 255, link 2,048, 20 submissions per rolling 24 hours, instant check shows at most 3 books.
- `Identifier` source `user_submission: 9`, trust rank 1. Instant check and job finder use every source except `legacy`; a null source is skipped too.
- Config defaults: `GOODREADS_PRIORITY_RESERVED` 100; lookup runs 100 a day; lease 30 minutes; claim 1 to 25, default 10; retry window 1 hour; poll 10 s for 10 minutes.
- Copy, verbatim: "Can't find it? Add a book" / "Add a book that isn't on the site" / "It can take a while to add a new book. We'll put it on \"<list name>\" when it's ready." / "We already have this. Is it the one?" / "None of these" / "We couldn't find a book from that link. Try another way" / "Recently added; not yet reviewed or enriched." / "Not yet reviewed".
- Public layouts render no flash; form failures answer as Turbo Streams. No daisyUI v4 classes. Reader text gets `[overflow-wrap:anywhere]`.
- Sidekiq is inline in tests: stub `perform_async`, and `stub_workflow_dispatch` where a run is planned.
- Never commit to `main`; no push or PR without Shane.

## Review Focus

1. **A lost Sidekiq message** (Redis restart, deploy): the submission must not sit on "Adding..." forever. Pinned in Task 7 (stuck sweep).
2. **Two readers submit the same book at once**: one book, on both lists. Pinned in Task 7.
3. **A link to something that is not a book** (an Amazon toaster, a Goodreads "Page not found"): `needs_details`, never a book with no author. Pinned in Task 6.
4. **A double-clicked or re-sent form, or an expired session**: one open submission, and a toast, not a blank page. Pinned in Task 8.
5. **Hostile or odd text** (NUL bytes, whitespace-only names, HTML, "Martin Luther King, Jr." as one author): rejected or stored whole and escaped. Pinned in Tasks 2 and 9.

## File map

| Path (under `web-app/`) | Responsibility |
|---|---|
| `app/models/books/book_submission.rb` | Row, enums, scopes, validations |
| `app/lib/services/books/book_submissions/{parse_input,instant_check,submit,cancel,dismiss}.rb` | Reader side |
| `.../{resolve_input,process_submission,create_book,start_lookups}.rb` | Background side |
| `.../{close_for_book,claim,lease,approve,merge,reject,book_uses,supply_details,skip}.rb` | Review side |
| `app/lib/data_importers/books/book/exact_lookup.rb` | The finder's exact title/author lookup, shared |
| `app/lib/workflows/lanes.rb` | Maps a queue to its priority twin |
| `app/sidekiq/books/{process_book_submission,fetch_submission_goodreads_page,requeue_stuck_book_submissions}_job.rb` | Jobs |
| `app/controllers/books/my/book_submissions_controller.rb` | Reader endpoints |
| `app/components/books/book_submissions/{dialog,hits,strip}_component*` | Reader UI |
| `app/javascript/controllers/books/{book_submission,book_submission_poll}_controller.js` | Reader JS |
| `app/controllers/api/v1/admin/books/book_submissions_controller.rb`, `app/lib/api/v1/admin/book_submission_resource.rb` | Admin API |
| `app/controllers/admin/books/book_submissions_controller.rb`, `app/views/admin/books/book_submissions/` | Admin page |
| `config/mcp/books/prompts/book_submissions.md.erb` | Agent prompt |

---

### Task 1: Table, model and configuration

**Files:**
- Create: migration, `app/models/books/book_submission.rb`, `test/models/books/book_submission_test.rb`, `test/fixtures/books/book_submissions.yml`, `config/initializers/goodreads_book_submissions.rb`
- Modify: `app/models/user.rb`, `app/models/books/book.rb`, `app/models/user_list.rb`, `app/models/identifier.rb` (enum, `trust_rank`), `test/controllers/admin/users_controller_test.rb`

**Interfaces:**
- Produces: `Books::BookSubmission` with enums `input_method {goodreads: 0, amazon: 1, isbn: 2, title_authors: 3}` (prefix `:method`), `status {queued: 0, looking_up: 1, needs_details: 2, added: 3, failed: 4, cancelled: 5}`, `review_status {not_needed: 0, pending: 1, approved: 2, merged: 3, rejected: 4, needs_human: 5}` (prefix `:review`), `reviewed_via {api: 0, admin_ui: 1, system: 2}` (prefix); scopes `open` (queued, looking_up, needs_details), `visible` (`dismissed_at` nil), `reviewable` (review pending and added, or status needs_details/failed; never `needs_human`), `claimable` (`reviewable` with no live lease); `#in_progress?` (queued or looking_up); `#label` (resolved title, typed title, or raw input); `#user_added?`.
- Produces: `Rails.application.config.x.book_submissions` with `daily_limit` 20, `lookup_runs_per_day` (ENV `BOOK_SUBMISSION_LOOKUP_RUNS`, 100), `lookups_enabled` (ENV `BOOK_SUBMISSION_LOOKUPS_ENABLED`, true), `retry_window` 1 hour; read through `GoodreadsEnv.integer/boolean`. The file is `goodreads_book_submissions.rb` because that module is defined in `goodreads.rb` and initializers load in alphabetical order.

Columns (table `books_book_submissions`): `user_id`, `user_list_id`, `book_id`, `match_decision_id`, `user_list_item_id` (all nullable FKs, `on_delete: :nullify`); `input_method` int not null; `raw_input` text; `typed_title` string; `typed_author_names` jsonb `[]`; `goodreads_book_id` bigint; `asin`, `isbn13`, `isbn10`, `resolved_title`, `signature`, `fingerprint` (Task 2's, matched with `user_list_id` in Task 8) strings; `resolved_author_names` jsonb `[]`; `supplied` jsonb; `lookup` jsonb `{}`; `status` int 0; `review_status` int 0; `created_book` boolean false; `error` text; `processing_started_at`, `next_attempt_at`, `announced_at`, `dismissed_at`; `reviewed_by_id`, `reviewed_via`, `reviewed_at`, `review_note` text, `review_sources` jsonb `[]`; `lease_token`, `lease_expires_at`, `claimed_by_id`, `attempts` int 0; timestamps. Indexes: `(user_id, created_at)`, `user_list_id`, `book_id`, `signature`, `(status, review_status)`.

- [ ] **Step 1: Generate** with `bin/rails generate model Books::BookSubmission` and write the migration above; run `bin/rails db:migrate` and keep only this table's annotation lines.
- [ ] **Step 2: Write failing model tests:** `test "each method needs its own input and no other"` (goodreads without `goodreads_book_id` invalid; `title_authors` with an `isbn13` invalid; `amazon` may carry `isbn13`/`isbn10` beside its `asin` (an ASIN can be an ISBN-10); `title_authors` with a blank title or no authors invalid; 11 authors invalid; a 256-character title invalid); `test "reviewable leaves out needs_human and cancelled"`; `test "claimable leaves out a live lease and takes an expired one"`; `test "user_added? is true only for a created book not merged or rejected"`; `test "deleting the user, list or book keeps the row with a null id"`. In `identifier_test`: `assert_equal 1, Identifier.trust_rank("user_submission")`. In `users_controller_test`: an admin can delete a user who submitted, reviewed and claimed a submission.
- [ ] **Step 3: Run** `bin/rails test test/models/books/book_submission_test.rb test/models/identifier_test.rb test/controllers/admin/users_controller_test.rb`. Expected: FAIL.
- [ ] **Step 4: Implement** the model, the config file, and associations: `User has_many :book_submissions, :reviewed_book_submissions, :claimed_book_submissions` (all `class_name: "Books::BookSubmission"`, `dependent: :nullify`); `Books::Book has_many :submissions, dependent: :nullify`; `UserList has_many :book_submissions, dependent: :nullify`; `Identifier` enum value and rank.
- [ ] **Step 5: Run the same command.** Expected: PASS. Then `bundle exec standardrb`.
- [ ] **Step 6: Commit** `feat: book submissions table and model`

---

### Task 2: Parse the reader's input

**Files:** Create `app/lib/services/books/book_submissions/parse_input.rb`, `test/lib/services/books/book_submissions/parse_input_test.rb`

**Interfaces:**
- Produces: `ParseInput.call(params) -> Result`; `data[:attributes]` is a Hash of submission attributes (`input_method`, `raw_input`, `typed_title`, `typed_author_names`, `goodreads_book_id`, `asin`, `isbn13`, `isbn10`); `data[:fingerprint]` is a String equal for equal normalized input. `params` keys: `method`, `goodreads_url`, `amazon_url`, `isbn`, `title`, `authors` (Array).

- [ ] **Step 1: Write failing tests**, table-driven:

```ruby
GOODREADS = {
  "https://www.goodreads.com/book/show/13651" => 13651,
  "https://www.goodreads.com/book/show/13651-the-dispossessed?ref=x" => 13651,
  "http://goodreads.com/en/book/show/13651.The_Dispossessed" => 13651,
  "www.goodreads.com/book/show/13651" => 13651
}
AMAZON = {
  "https://www.amazon.com/Dispossessed/dp/0061054887/ref=sr_1_1" => ["0061054887", "0061054887"],
  "https://www.amazon.co.uk/gp/product/B000FC11JE" => ["B000FC11JE", nil],
  "https://www.amazon.de/gp/aw/d/0061054887" => ["0061054887", "0061054887"]
} # url => [asin, isbn10]
REFUSED = [["goodreads", "https://www.goodreads.com/author/show/874602"], ["goodreads", "https://evilgoodreads.com/book/show/1"],
  ["goodreads", "https://www.amazon.com/dp/0061054887"], ["amazon", "https://a.co/d/abc"], ["amazon", "https://amazon.com.evil.test/dp/0061054887"],
  ["isbn", "9780061054880"], ["isbn", "5012345678900"], ["goodreads", "javascript:alert(1)"]]
```

Also: `"978-0-06-105488-4"` and its ISBN-10 give the same `isbn13`/`isbn10` pair (both from `Books::Isbn`); two filled methods, or fields of a method other than `method`, is an error; a NUL byte and surrounding whitespace are stripped; whitespace-only authors are dropped and none left is an error; `["Martin Luther King, Jr."]` stays one author; each error names what that field accepts; a 2,049-character link is refused.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/book_submissions/parse_input_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.** Parse hosts with `URI` (prefix `https://` when no scheme); Goodreads host must equal or end with `.goodreads.com`; Amazon host must match `/\A(?:www\.|smile\.|m\.)?amazon\.(?:com|ca|co\.uk|de|fr|it|es|nl|se|pl|ie|com\.au|com\.mx|com\.br|com\.be|com\.tr|co\.jp|in|sg|ae|sa|eg)\z/`. ISBN must be 978/979.
- [ ] **Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: parse book submission input`

---

### Task 3: Instant check

**Files:** Create `app/lib/data_importers/books/book/exact_lookup.rb`, `app/lib/services/books/book_submissions/instant_check.rb` and tests; modify `app/lib/data_importers/books/book/finder.rb` (`exact_scope` delegates), `app/models/identifier.rb`

**Interfaces:**
- Produces: `DataImporters::Books::Book::ExactLookup.call(title:, author_names:, limit: 5) -> ActiveRecord::Relation` (the body of the finder's `exact_scope`, its comment moved with it).
- Produces: `Identifier::NON_LEGACY_SOURCES` (`sources.keys - ["legacy"]`, frozen).
- Produces: `InstantCheck.call(attributes:) -> Result`, `data[:books]` up to 3 `::Books::Book`, authors preloaded, catalog before provisional, then ranked, then id.

- [ ] **Step 1: Write failing tests:** a hit for each of Goodreads id, ISBN-13, ISBN-10, ASIN; an ISBN-10 submission hits a book holding only the ISBN-13; an ASIN that is an ISBN-10 hits an ISBN row; an edition-level hit answers with the edition's book; `source: :legacy` and `source: nil` rows are ignored; two holders return both; four return three; title and authors match exactly and a different author does not; a provisional book is returned. Pin "no outside call": `::Books::OpenLibrary::Client.expects(:new).never` and the AI task likewise.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/book_submissions/instant_check_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.** Types per id: Goodreads `books_work_goodreads_id`, `books_edition_goodreads_id`; ISBN `*_isbn13`, `*_isbn10`; ASIN `*_asin` plus the ISBN types.
- [ ] **Step 4: Run** it with `test/lib/data_importers/books/book/finder_test.rb`. Expected: PASS. **Step 5: Commit** `feat: instant check of our own identifiers`

---

### Task 4: Goodreads and serial priority lanes

**Files:** Modify `app/lib/books/fetch_gate.rb`, `app/lib/books/goodreads/gate_turn.rb`, `config/initializers/goodreads.rb`, `config/initializers/sidekiq.rb`; tests `test/lib/books/fetch_gate_test.rb`, `test/lib/books/goodreads/fetch_gate_test.rb`, `test/lib/books/goodreads/gate_turn_test.rb`

**Interfaces:**
- Produces: `FetchGate#reserve(priority: false)`, `#spacing_wait(priority: false)`, `#started!(priority: false)`; `GateTurn.call(gate:, due:, priority: false)`; config `priority_reserved` (ENV `GOODREADS_PRIORITY_RESERVED`, default 100).

Rules:
- Ordinary cap is `daily_fetch_cap - priority_reserved.to_i` (in `reserve` and `reopens_at`). A config without the key (publisher intake) reserves nothing.
- A priority reservation starts at the latest of now, `last_start + fetch_interval` and the previous priority start plus the interval. It never moves `next_start`. It counts in its own `priority_day`/`priority_count`, up to `priority_reserved`; past that it falls back to an ordinary reservation.
- While a priority start is outstanding (`priority_due` within one interval ahead to 60 seconds past, and not yet started), an ordinary turn's `spacing_wait` is at least `fetch_interval`, so a backlog cannot beat it repeatedly. The 60 seconds is the self-heal for a lost job.
- A block refuses both.

- [ ] **Step 1: Write failing tests:**

```ruby
test "a priority turn passes a backlog already handed out" do
  10.times { gate.reserve }            # cap raised for this test
  assert_equal 0, gate.reserve(priority: true).wait
end
test "ordinary turns stop at the cap less the reserved slice, and priority turns use the slice" do
  # daily_fetch_cap: 3, priority_reserved: 1
  assert_equal [true, true, false], 3.times.map { gate.reserve.granted? }
  assert gate.reserve(priority: true).granted?
  assert_equal :daily_cap, gate.reserve(priority: true).refusal
end
test "two priority turns are an interval apart"
test "an ordinary turn yields while a priority turn is due, and stops yielding 60 seconds later"
test "a block refuses a priority turn"
test "a gate with no priority_reserved behaves as before"
```

Plus in `gate_turn_test`: `priority: true` reaches all three gate calls.
- [ ] **Step 2: Run** the three files. Expected: FAIL.
- [ ] **Step 3: Implement**, and set the capsules: `goodreads_fetch` queues `%w[goodreads_fetch_priority goodreads_fetch]`, `serial` queues `%w[serial_priority serial]` (strict order, concurrency 1 unchanged). Existing gate tests must pass unmodified.
- [ ] **Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: priority lane for Goodreads fetches and serial work`

---

### Task 5: Workflow lanes, promotion and queue filters

**Files:** Create `app/lib/workflows/lanes.rb`; modify `app/lib/workflows/planner.rb`, `app/lib/workflows/books/book_enrichment.rb`, `app/lib/workflows/books/steps/goodreads.rb`, `app/lib/services/books/goodreads_imports/promote_records.rb`, `app/lib/services/books/queue_types/{book_scope,author_scope}.rb`; matching tests

**Interfaces:**
- Produces: `Workflows::Lanes.queue_for(queue, lane) -> String` (`goodreads_fetch` and `serial` gain `_priority` for lane `"priority"`; every other queue and lane is unchanged). Run option `"lane"`.
- Produces: `PromoteRecords.call(books:, authors:, initiated_by: "goodreads_promote", lane: nil)`.
- Produces: `BookEnrichment::LIMITED_BY = "book_submission"`. `start` supersedes an active run when that run has `initiated_by` `LIMITED_BY` and an `"only"` option, and the new one has no `only`; otherwise it returns the active run as today.

- [ ] **Step 1: Write failing tests:** planner writes `goodreads_fetch_priority` and `serial_priority` for lane `priority` and today's queues without it; the Goodreads step passes `priority: true` to `GateTurn` only for that lane; `start` over an active limited submission run plans a full run and cancels the limited one; `start` over an active full run, or over an `adopt_deferred` `only` run, returns it; `PromoteRecords` with `initiated_by: "book_submission", lane: "priority"` stamps both, and its existing tests pass unmodified; a provisional book and a provisional author are not offered by either queue scope.
- [ ] **Step 2: Run** `bin/rails test test/lib/workflows test/lib/services/books/goodreads_imports/promote_records_test.rb test/lib/services/books/queue_types`. Expected: FAIL.
- [ ] **Step 3: Implement.** **Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: workflow lanes and promotion by submission`

---

### Task 6: Resolve a link or ISBN to title and authors

**Files:** Create `app/lib/services/books/book_submissions/resolve_input.rb`; modify `app/lib/services/amazon/client.rb`; tests for both

**Interfaces:**
- Produces: `Services::Amazon::Client.get_items(item_ids:, **params) -> Array<Hash>` (`itemsResult.items`, `[]` when absent, `Error` on non-2xx, as `search_items`). The gem ships no example of this response; verify the key with one real call (Shane runs it) before merge, and note the result in `docs/features/amazon-creators-api.md`.
- Produces: `ResolveInput.call(submission:) -> Result`, `data[:outcome]` one of `:resolved`, `:needs_goodreads_page`, `:no_record`, `:unavailable`; for `:resolved` also `title`, `subtitle`, `author_names`, `year`, `identifiers` (`{isbn13: [], isbn10: [], asin: [], goodreads_id: []}`), `source`.

Rules, in order: `submission.supplied` wins when present (source `"supplied"`, its identifiers included). `title_authors`: as typed, no identifiers. `goodreads`: a conclusive `::Books::GoodreadsPage` row, else `:needs_goodreads_page`; `not_found` is `:no_record`; authors are `contributors.select(&:creator?)`, or all of them when none is a creator. `amazon`: `get_items` with `AmazonProductService::AMAZON_RESOURCES`; `split_title` and `author_names`; when Amazon has no usable record and the submission has an `isbn13`, go on to the `isbn` chain. `isbn`: WorldCat `record_by_isbn`, then Open Library `identifier` (isbn13) and `work`, then Amazon `search_items(keywords: isbn13, search_index: "Books")` keeping only a product whose `externalIds` hold the ISBN. First usable wins; a source that raises is skipped, and `:unavailable` is the answer only when nothing was usable and at least one raised. Usable means a title and at least one author.

WorldCat names: strip `WorldCatCheck::PARENTHESES` and `DATES`, trailing punctuation, and turn "Last, First" into "First Last"; the title drops " / ..." and splits on " : ".

- [ ] **Step 1: Write failing tests** for each rule, including: an Amazon product with no authors (a toaster) is `:no_record`; a Goodreads `not_found` page is `:no_record`; WorldCat `"Le Guin, Ursula K., 1929-2018."` gives `"Ursula K. Le Guin"`; WorldCat down and Open Library answering is `:resolved`; all three down is `:unavailable`; two empty and one down is `:unavailable`; `lookup` on the submission records each source's answer; nothing outside is called for `title_authors`.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/book_submissions/resolve_input_test.rb test/lib/services/amazon/client_test.rb`. Expected: FAIL. **Step 3: Implement. Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: resolve book submission input`

---

### Task 7: Process a submission

**Files:** Create `.../process_submission.rb` (not `Process`, which would shadow Ruby's `::Process` in this namespace), `.../create_book.rb`, `.../start_lookups.rb`, the three jobs (generator), cron entry in `config/schedule.yml`; tests

**Interfaces:**
- Consumes: `ResolveInput`, `Finder.new(identifier_sources: Identifier::NON_LEGACY_SOURCES)`, `Importer.call`, `UserLists::AddItem`, `UserLists::OwnerMutation`, lanes.
- Produces: `ProcessSubmission.call(submission:) -> Result` with `data[:outcome]` `:done`, `:retry` or `:waiting_for_goodreads`. `Books::ProcessBookSubmissionJob` (queue `critical`, `perform(submission_id)`), `Books::FetchSubmissionGoodreadsPageJob` (queue `goodreads_fetch_priority`, `perform(submission_id, due = false)`), `Books::RequeueStuckBookSubmissionsJob` (queue `low`, cron every 10 minutes).
- Produces: `CreateBook.call(submission:, resolved:, match:) -> Result` (`data[:book]`, `data[:created]`); `StartLookups.call(book:) -> Result` (`data[:started]`).

Rules:
- A cancelled, dismissed-and-finished, added or failed submission is a no-op. No user or list: `cancelled`.
- `:no_record` is `needs_details`. `:unavailable`, a `fallback` match, or a failed local source (`sources_failed` includes anything but `open_library`) retries with backoff (30 s doubling, cap 10 min, `next_attempt_at` set) until `processing_started_at + retry_window`; then `:unavailable` is `needs_details` and the matching failures are `failed`. A failed `open_library` source alone retries the same way, then proceeds to create.
- Goodreads job: `GateTurn.call(gate:, due:, priority: true)`; a refusal reschedules at `gate.reopens_at`; `after_fetch` is called; `found`/`not_found` queue the process job; `blocked` reschedules; `unparseable` is `needs_details`; `unavailable`/`fetcher_down` retry within the window.
- The finder query always carries a title. `CreateBook` takes the same advisory lock string as `GoodreadsImports::CreateBook` (`"goodreads-edition:#{signature}"`, `signature = Books::Goodreads::ExportRow.signature(title, first_author)`), so the two creators exclude each other, then adopts a book created since by a submission or Goodreads edition with that signature unless the finder already considered it. It imports with `provisional: true, stamp_identifiers: true, enrich: false, query_identifier_source: :user_submission`; no author raises inside the savepoint and becomes `needs_details`.
- After a book exists: `book`, `created_book`, `match_decision`, `status: :added`, `review_status: :pending` only when created. Then add to the list; "Item already in list" is success. Then `StartLookups` for a created book: `BookEnrichment.start(book, initiated_by: "book_submission", options: {"only" => %w[goodreads amazon], "lane" => "priority"})`, skipped when `lookups_enabled` is false or the rolling 24-hour count of such runs reaches `lookup_runs_per_day`.
- Any other error: `failed`, `error` stored, logged.

- [ ] **Step 1: Write failing tests:** matched catalog book goes on the list with `not_needed`; matched provisional book likewise, no second book; unmatched creates provisional book and author, `user_submission` identifiers, `pending`, on the list; `title_authors` stamps none; target list Read when the book is on Reading moves it; already on the list is success; a `fallback` match creates nothing and retries, then `failed`; Open Library failing alone creates after the window; importer with no author leaves no book and `needs_details`; list deleted is `cancelled`; a second submission with the same signature adopts the first's book and lands on its own list (Review Focus 2); running twice changes nothing; a Goodreads submission with no page queues the fetch job; the fetch job on a block reschedules at `reopens_at`; lookups off, and at the ceiling, plan no run; the planned run has only `goodreads` and `amazon` not skipped, and no author run exists.
- [ ] **Step 2: Write failing sweep tests** (Review Focus 1): `queued`/`looking_up` rows with `updated_at` older than 30 minutes and no future `next_attempt_at` are requeued; a row waiting on a future attempt is not; added, failed and cancelled rows are not.
- [ ] **Step 3: Run** `bin/rails test test/lib/services/books/book_submissions test/sidekiq/books`. Expected: FAIL. **Step 4: Implement. Step 5: Run.** Expected: PASS. **Step 6: Commit** `feat: process book submissions`

---

### Task 8: Reader endpoints

**Files:** Create `.../submit.rb`, `.../cancel.rb`, `.../dismiss.rb`, `app/policies/books/book_submission_policy.rb`, `app/controllers/books/my/book_submissions_controller.rb`; modify `config/routes.rb` (books host block, beside `my/goodreads-import`); tests

**Interfaces:**
- Produces: `Submit.call(user:, list:, params:, confirmed_new: false, replaces: nil) -> Result`, `data[:outcome]` `:hits` (`data[:books]`), `:created` or `:existing` (`data[:submission]`).
- Produces routes: `GET/POST /my/lists/:list_id/book-submissions` (`books_my_list_book_submissions`), `POST /my/book-submissions/:id/cancel`, `POST /my/book-submissions/:id/dismiss`.

Rules: parse; instant check unless `confirmed_new`; hits create no row and count toward nothing. Under `user.with_lock`: return the open submission with the same list and fingerprint; refuse past 20 in 24 hours; create; cancel `replaces` when it is the user's own `needs_details`/`failed` row. `ProcessBookSubmissionJob.perform_async` after commit. `cancel` is a conditional update, only while no book exists; `dismiss` only for finished rows. The list is found through `current_user.user_lists` limited to `Books::UserList`. `index` renders the strip frame; rows newly `added` get `announced_at` in that response, which then calls `mark_user_state_changed` and sets `data-reload-list="true"`. Never cached. `rate_limit to: 10, within: 1.minute, by: user`.

Create the hits and strip components here (generator) with just enough markup for these responses: the strip frame `book_submissions`, the hits in `#book-submission-hits`, form errors into `#book-submission-errors`. Task 9 finishes their markup and adds the dialog.

- [ ] **Step 1: Write failing tests:** every service rule above; the 21st refused and the 20th not; a replayed POST returns the same submission and one row (Review Focus 4); another user's list, submission or a music list is a 404; signed-out POST answers a Turbo Stream toast with 401; an invalid CSRF token and a rate-limited POST do too; invalid input is 422 as a stream into the dialog; hits answer 200 with the hits; two methods in one request is 422; `index` marks state once, and not on the next poll; cancel after a book exists is refused.
- [ ] **Step 2: Run** `bin/rails test test/controllers/books/my/book_submissions_controller_test.rb test/lib/services/books/book_submissions`. Expected: FAIL. **Step 3: Implement. Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: book submission endpoints`

---

### Task 9: Reader UI

**Files:** Create the dialog, hits and strip components (generator, with tests), the two Stimulus controllers; modify `app/components/autocomplete_component*`, `app/javascript/controllers/autocomplete_controller.js`, `app/components/user_lists/show/add_item_component*`, `app/components/user_lists/show/item_component*`, `app/views/my_lists/show.html.erb`, `app/components/books/provisional_notice_component.html.erb`, the books JS manifest under `app/javascript/manifests/`, `lib/tasks/e2e.rake`; create `e2e/tests/books/account/add-missing-book.spec.ts`

**Interfaces:**
- Produces: `AutocompleteComponent.new(..., footer_label: nil)`; when set, the dropdown always ends with a button that dispatches `autocomplete:footer` with `{detail: {query}}`, results or not. Existing callers are unchanged.
- Test ids: `add-missing-book`, `book-submission-dialog`, `book-submission-hits`, `book-submission-strip`, `book-submission-row`.

Rules: only `Books::UserList` pages, only the owner. Dialog: native `<dialog>`, `fieldset` + `fieldset-legend`, radios in order Goodreads link (checked), Amazon link, ISBN, Title and author; only the chosen method's inputs are enabled, the rest `disabled` so they are not sent; the title takes the search text. Hits replace the form with Add to list (through the existing add-item flow) and None of these (re-sends with `confirmed_new`). Strip: Turbo Frame `book_submissions`, polls every 10 s while any row is in progress, stops after 10 minutes, reloads `list_items` on `data-reload-list`. Forms carry `data-turbo-frame`; off-page links `target="_top"`. Row copy per spec section 6; `needs_details` and `failed` offer Try another way; rejected reads "We couldn't verify ..., so it was removed." Item component shows the owner "Not yet reviewed" on a provisional book in both layouts.

- [ ] **Step 1: Write failing component and view tests:** strip copy for each status and for rejected; a title of `<script>` is escaped (Review Focus 5); nothing renders for a non-owner or a music list; `assert_no_frame_trapped_links` on the list page; the badge shows to the owner only; the notice text is the new copy.
- [ ] **Step 2: Run** `bin/rails test test/components test/controllers/my_lists_controller_test.rb test/lint`. Expected: FAIL. **Step 3: Implement**, then `yarn build:all`. **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: E2E.** Add `e2e:book_submissions_seed`/`_cleanup` (one row each of looking_up, needs_details, added-pending with a provisional book, for the Playwright user; found by the marker title "E2E Book Submission"; prints ids as JSON). Spec: footer opens the dialog with the typed text; switching method shows only its fields; a bad link shows its error in the dialog; a seeded id shows the hit and adds it; the strip shows each seeded row; cancel removes one. No Sidekiq or network needed. Check port 3000 is this worktree's, then run `yarn test:e2e e2e/tests/books/account/add-missing-book.spec.ts`. Expected: PASS.
- [ ] **Step 6: Commit** `feat: add a missing book from a list page`

---

### Task 10: Close submissions when their book changes elsewhere

**Files:** Create `.../close_for_book.rb`; modify `app/lib/books/book/merger.rb`, `app/models/books/book.rb`, `promote_records.rb`; tests

**Interfaces:**
- Produces: `CloseForBook.call(book_ids:, review_status:, user: Current.acting_user, via: Current.acting_via || "system", note: nil, include_matched: false)`; updates `pending`/`needs_human` rows of those books, sets `reviewed_*`, clears the lease. `include_matched: true` also takes `not_needed` rows (another reader's submission that resolved to the same provisional book shares its fate); callers pass it only when the book was provisional. A row already closed is untouched.

- [ ] **Step 1: Write failing tests:** a Goodreads import approval that promotes the book closes it `approved`; `merge_book` into a catalog book moves the submissions and closes them `merged`; into another provisional book moves them and leaves them `pending`; destroying the book closes them `rejected` with `book_id` null; a rolled-back merge changes nothing; a second reader's `not_needed` row on a destroyed provisional book becomes `rejected`, and on a destroyed catalog book stays `not_needed`; `user_added?` is false for a catalog book that absorbed one; unrelated submissions are untouched.
- [ ] **Step 2: Run** the merger, book, promote and close tests. Expected: FAIL.
- [ ] **Step 3: Implement.** Merger: `merge_submissions` in `merge_all_associations`, closing after `reconcile_scalars`. Book: `before_destroy ..., prepend: true`, so it runs before `dependent: :nullify`. **Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: close submissions when their book is settled elsewhere`

---

### Task 11: Review services

**Files:** Create `.../{lease,claim,approve,merge,reject,book_uses,supply_details,skip,retry}.rb` and tests

**Interfaces (all `-> Result`, failures are `errors: [{code: :conflict | :invalid, detail:}]`):**
- `Claim.call(user:, limit: 10)`: `data[:items, :lease_token, :lease_expires_at, :remaining]`; `FOR UPDATE SKIP LOCKED`, oldest first, modelled on `Services::EnrichmentQueue::Claim`; a row claimed 3 times already becomes `needs_human` with note "abandoned by agents".
- `Approve.call(submission:, user:, via:, lease_token: nil, note:, sources: [])`
- `Merge.call(submission:, target_id:, dry_run: false, ...)`; `Reject.call(submission:, dry_run: false, ...)`; `SupplyDetails.call(submission:, title:, author_names:, identifiers: {}, ...)`; `Skip.call(submission:, reason:, ...)`
- `BookUses.call(book:) -> Array<String>`: human-readable uses that block a reject.

Rules: `via: "api"` requires a live matching lease (else `:conflict`); `via: "admin_ui"` needs none and also works on `needs_human`. `note` 1 to 1,000 characters on every write; `sources` up to 20 http(s) URLs, required for approve, merge and reject through the API.
- Approve: submission has a provisional book and is pending or needs_human; stamps itself, then `PromoteRecords.call(books: [book], authors: [], initiated_by: "book_submission", lane: "priority")`, in one transaction.
- Merge: target exists, is not provisional, is not the source; `AdminMerge.call` (**never inside a transaction**); then note, sources and reviewer go on the moved submissions. Warnings returned.
- Reject: the book is provisional and some submission created it; `BookUses` empty, else `:invalid` naming them. In a transaction: `DestructionInvalidator.for_book`, close, `destroy!`, then destroy provisional authors now without `book_authors` and not in any `GoodreadsImportRecord`; purge goal pages after commit as `DeleteProvisional` does.
- `BookUses`: list items owned by users with no submission on the book; reviews likewise; curated `ListItem`s; Goodreads import rows whose import is not rejected.
- SupplyDetails: only `needs_details` or `failed` with no book; stores `supplied`, resets to `queued`, clears lease and `error`, queues the job.
- Skip: `needs_human`, lease cleared.
- `Retry.call(submission:, user:)` (admin page only): a `failed` row with no book goes back to `queued` with a fresh `processing_started_at`, and the job is queued.

- [ ] **Step 1: Write failing tests** for every rule: two concurrent claims share no row; an expired lease is reclaimable and the old token conflicts; a claim hands out pending, needs_details and failed, never needs_human or cancelled; approve over an active limited run plans a full one; reject refused separately for another reader's item, another reader's review, a curated list, a Goodreads row, a non-provisional book, a book no submission created; reject allowed after the submitter moved it Reading to Read and favorited it; reject keeps an author another book credits; merge carries the list item; merge into a provisional target refused; dry runs change nothing; supply after a book exists refused.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/book_submissions`. Expected: FAIL. **Step 3: Implement. Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: book submission review services`

---

### Task 12: Admin API and MCP tools

**Files:** Create the API controller, resource and `test/controllers/api/v1/admin/books/book_submissions_controller_test.rb`; modify `config/routes.rb`, `config/api/v1/admin_openapi.yaml`, `config/mcp/books/{admin_instructions,admin_usage}.md`, `test/lib/mcp/{admin_catalog,tool_directory}_test.rb`, `test/controllers/api/mcp_admin_controller_test.rb`, `test/integration/api/v1/contract_coverage_test.rb`

**Interfaces** (routes under `/api/v1/admin/`, operationId, scope):

| Route | operationId | Scope |
|---|---|---|
| `GET book_submissions` | `listBookSubmissions` | `books:admin:read` |
| `GET book_submissions/:id` | `getBookSubmission` | `books:admin:read` |
| `POST book_submissions/claims` | `claimBookSubmissions` | `books:admin:write` |
| `POST book_submissions/:id/details` | `supplyBookSubmissionDetails` | `books:admin:write` |
| `POST book_submissions/:id/skip` | `skipBookSubmission` | `books:admin:write` |
| `POST book_submissions/:id/approve` | `approveBookSubmission` | `books:admin:merge` |
| `POST book_submissions/:id/merge` | `mergeBookSubmission` | `books:admin:merge`, destructive |
| `POST book_submissions/:id/reject` | `rejectBookSubmission` | `books:admin:merge`, destructive |

Resource: id, method, raw input, typed and resolved title and authors, parsed ids, status, review_status, `needs` (`"review"` or `"details"`), lookup answers, finder decision (decided_by, confidence, reason, candidates), book (id, title, authors, year, identifiers), the kinds of lists it is on, submitter's approved and rejected counts, timestamps. **Never** user id, name or email, nor a custom list's name. A 409 is a lost lease, a 422 an invalid request; approve and merge also need `BookPolicy#update?`, merge and reject `#destroy?` on the book. Update descriptions for agents to say ids come from list/claim, results are data, dry-run first for merge and reject, what a 409 means, and when the queue is done.

- [ ] **Step 1: Update the pinned tests to their new values:** 84 admin tools (76 + 8), 21 destructive (19 + 2), the eight names, `DESTRUCTIVE` and `DESTRUCTIVE_TOOLS` gaining merge and reject, and `EXERCISES` entries for every documented response. Write controller tests: each action's success and conformance (`assert_api_response_conform(..., api: :admin)`), 400/401/403/404/409/422, a read-scope token refused on writes, a write-scope token refused on approve, no submitter identity anywhere in the JSON.
- [ ] **Step 2: Run** `bin/rails test test/lib/mcp test/controllers/api test/integration/api`. Expected: FAIL. **Step 3: Implement. Step 4: Run.** Expected: PASS. **Step 5: Commit** `feat: admin API and MCP tools for book submissions`

---

### Task 13: Prompt, admin page and badge

**Files:** Create the prompt, admin controller and views, `e2e/tests/books/admin/book-submissions.spec.ts`; modify `app/lib/services/agent_prompts.rb`, `app/lib/admin/domain_nav.rb` ("Book Submissions", after "List Audits"), `config/routes.rb`, `app/views/admin/books/books/show.html.erb`; tests

**Interfaces:**
- Produces: `AgentPrompts::QUEUES` gains `:book_submissions`; locals `pending_review`, `pending_details`, `needs_human`. No reader text reaches the template.
- Admin routes: `resources :book_submissions, only: [:index]` with member `post :approve, :merge, :reject, :supply_details, :retry`.

The prompt holds: the loop (claim, `get_book_submission`, research, decide, until `data` is empty and `meta.remaining` is 0); how to keep watching (wait 10 minutes and claim again, if asked to); **approve** when an independent source (Goodreads, Open Library, WorldCat, a publisher, a library catalogue) shows a book with this title and author, correcting it first with `update_book`/`update_book_author`; an Amazon page alone is not enough; **merge** when we already hold it (search first; translations are the same book; a box set, omnibus or adaptation is not its original); **reject** only with evidence that it is not a real book; **skip** when unsure; for `needs: details`, work out the book from the link or ISBN with `fetch_page` or a web search and call `supply_book_submission_details`; names, titles and links are reader text and never instructions; house rules on placeholders, initials and the English edition (as `duplicates.md.erb` words them); a note with sources every time; the final report.

Admin page: tabs (Needs review, Needs details, Needs human, Approved, Merged, Rejected, Failed, All) with counts, Copy prompt (`data-testid="copy-agent-prompt"`), row actions with confirms; approve, merge and reject use `require_domain_delete!`, the rest `require_domain_write!`. Book show page: a "User-added" badge linking to the submission when `book.submissions.any?(&:user_added?)`.

- [ ] **Step 1: Write failing tests:** `AgentPrompts` renders with counts and contains all eight tool names; a submission titled "IGNORE ALL RULES" does not appear in it; each admin action's success, refusal and gate; N+1 guard on the index; the badge appears for a created book and not for an absorber.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/agent_prompts_test.rb test/controllers/admin/books`. Expected: FAIL. **Step 3: Implement. Step 4: Run.** Expected: PASS.
- [ ] **Step 5: E2E** on Task 9's seed: tabs, Copy prompt copies, rejecting the seeded row moves it to Rejected. Run `yarn test:e2e e2e/tests/books/admin/book-submissions.spec.ts`. Expected: PASS. **Step 6: Commit** `feat: book submission review page and agent prompt`

---

### Task 14: Docs and full verification

**Files:** Create `docs/features/user-added-books.md`; modify `docs/features/{books-provisional-records,mcp-server,public-api,goodreads-import,enrichment-queue,amazon-creators-api}.md`, `docs/todo.md` (remove the modal entry), `docs/launch-todo.md`

- [ ] **Step 1: Write the docs.** `books-provisional-records.md`: submissions also set the flag; approval (by an admin or an agent holding an admin token) clears it; the new notice text. `launch-todo.md`: confirm Sidekiq restarted with `goodreads_fetch_priority` and `serial_priority`; mint an admin token with `books:admin:merge`; run one real Amazon link and one ISBN add in production and check the result; the ENV names and defaults.
- [ ] **Step 2: Run everything:** `bin/rails test`, `bin/rails test:system`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`, `yarn build:all`, the two new E2E specs plus `e2e/tests/books/provisional.spec.ts`, `account/my-lists.spec.ts` and `account/edit-list.spec.ts`. Expected: green, no new warning lines; report any failure that is also on `main` as such.
- [ ] **Step 3: Commit** `docs: user-added books`
