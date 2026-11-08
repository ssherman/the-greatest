# Goodreads Re-import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-match every CSV row of every completed legacy Goodreads import to exactly the book it names. Delete and
re-ingest the mixed books. Fix import-made books' authors. Record every change as a reviewable, reversible audit
entry.

**Architecture:** Four phases of Sidekiq jobs, each writing `Books::RepairVerdict` rows (the audit record) under new
`reimport_*` kinds:
- match each distinct Goodreads edition once (blinded finder plus AI same-work check);
- decide each CSV row against what the user has now;
- apply approved entries in self-requeuing batches;
- check authors.

Mixed books are archived first, kept out of matching, emptied by the apply and deleted last. A config switch gates
every production-changing step and enrichment.

**Tech Stack:** Rails 8, Sidekiq 8, Postgres, Minitest + Mocha + fixtures, `OpenAI::BaseModel` AI schemas via
`Services::Ai::Tasks::BaseTask`.

**Spec:** `docs/superpowers/specs/2026-11-02-goodreads-reimport-design.md` (approved 2026-11-02). Read it and its
§8 calls first.

**Interface reference:** `/tmp/claude-1001/-home-shane-dev-the-greatest--claude-worktrees-goodreads-rebuild-pass-two/504e81a3-c6f5-4a01-85a4-6c379cdee9bf/scratchpad/reimport_interfaces.md`
holds exact signatures of every existing class named below. If that file is gone, the names below are enough to
find them in `web-app/`.

## Global Constraints

- **Rails commands:** run from `web-app/`. Services go in `app/lib/services/books/goodreads_reimport/`
  (`Services::Books::GoodreadsReimport::*`), jobs in `app/sidekiq/books/goodreads_reimport/`
  (`Books::GoodreadsReimport::*Job`). Generate jobs with `bin/rails generate sidekiq:job
  books/goodreads_reimport/<name>`.
- **Return values:** services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Audit record:** `Books::RepairVerdict`, written only through `Services::Books::GoodreadsReplay::RecordVerdict`.
  - Every new kind's payload stores **before**, **after**, **evidence** and the AI answer, enough to reverse the
    change.
  - Subject keys are stable, so a re-run never duplicates an entry.
- **Legacy-source identifiers and legacy/merge alternate titles are never evidence.** Use the blinded finder:
  `identifier_sources: Finder::TRUSTED_IDENTIFIER_SOURCES`,
  `alternate_title_sources: Finder::TRUSTED_ALTERNATE_TITLE_SOURCES`.
- **The row's book** is the edition's work: translations go to the English book when one exists; a combo is itself; a
  different volume, part, adaptation, guide or box set is a different book (spec §4.2).
- **Scope:** rows of `Books::GoodreadsImport.legacy_replay.complete` imports only.
- **Long work runs in Sidekiq jobs, never inline in rake.** Rake tasks only enqueue or print. Jobs are idempotent and
  safe to re-run after a deploy.
- **Gate:** `config.x.goodreads_reimport.enabled` (ENV `GOODREADS_REIMPORT_ENABLED`, default `false`).
  - While off, the match, decide, apply and author-check jobs return immediately without writing.
  - `config.x.goodreads_reimport.enrichment` (ENV `GOODREADS_REIMPORT_ENRICHMENT`, default `false`) separately
    gates enrichment of books this run creates.
- **Created books are not provisional** (spec §8 call 4).
- **Trusted books** (`GoodreadsRebuild::Cohort.trusted?`) never get an automatic author or title change: those are
  proposed only.
- **AI model:** `task_provider :openai`, `task_role :fast`, as in `MatchExportAuthorsTask`.
- **Tests:** never call real APIs; stub AI tasks and the finder with Mocha. A clean run prints no new warnings. Run
  `bundle exec standardrb` and the full `bin/rails test`, including once with `REDIS_URL=redis://localhost:6390/0`,
  because CI has no Redis.
- **Annotations:** any migration ships its annotaterb update in the same commit. Never set
  `ANNOTATERB_SKIP_ON_DB_TASKS`.
- **Never touch the development database** outside the rehearsal steps in Task 15, and those start from
  `bin/snapshot-dev-db.sh --label pre-reimport`.

## Review Focus

1. **A user with two rows (two different editions) that legacy put on one book.** Both destinations get an entry,
   each dated from its own row, and the review goes to the row that has it. Nothing is duplicated or lost. Test in
   Task 8.
2. **A row whose user has the same edition in two completed imports.** Only the newest import's row is decided; the
   older one gets `keep` with `superseded_by` and changes nothing. Test in Task 8.
3. **A row whose `legacy_book_id` is nil but the user already has the destination book** (legacy put it there
   without stamping the id). `add` is a no-op, not a duplicate list item. Test in Task 10.
4. **A mixed book that still holds a hand-added entry when its delete runs.** The delete refuses (outcome `:noop`,
   reason "not empty") until that entry's guess has moved it. Test in Task 11.
5. **The AI check fails (API error) for an edition.** Nothing is recorded, and the next run retries it; it is never
   recorded as "no match". Test in Task 6.

---

## File Structure

```
web-app/config/initializers/goodreads_reimport.rb             gate switches
web-app/app/models/books/repair_verdict.rb                     + kinds, summary/book_ids
web-app/app/components/admin/books/repair_verdict_row_component.rb  + LABELS
web-app/app/controllers/admin/books/repair_verdicts_controller.rb   + "guess" filter
web-app/app/lib/data_importers/books/book/finder.rb            + exclude_ids:
web-app/app/lib/services/books/goodreads_reimport/
  edition_facts.rb        CSV facts for one Goodreads edition (full title, all authors, ISBNs, year)
  mixed_books.rb          which books are mixed; archive verdicts
  match_edition.rb        finder + AI check -> reimport_match verdict
  decide_row.rb           one row -> keep / move / add verdict
  decide_guesses.rb       hand-added entries on mixed books -> reimport_guess verdicts
  check_author.rb         one import-made book -> reimport_author verdict
  apply.rb                one batch of approved verdicts, in phase order
  apply/*.rb              one handler per kind
  report.rb               counts, samples, acceptance queries
web-app/app/lib/services/books/goodreads_imports/library_rules.rb   rules extracted from WriteLibrary
web-app/app/lib/services/ai/tasks/books/same_work_task.rb           AI double-check
web-app/app/sidekiq/books/goodreads_reimport/{match_editions,decide_rows,apply,check_authors}_job.rb
web-app/lib/tasks/books/goodreads_reimport.rake
docs/features/goodreads-reimport.md, docs/launch-todo.md (new section)
```

**New `RepairVerdict` kinds**, appended to the enum after `fix_identity: 5`:

| Kind | Value | Subject key |
|---|---|---|
| `reimport_mixed` | 6 | `reimport:book:<book_id>` |
| `reimport_match` | 7 | `reimport:edition:<goodreads_edition_id>` |
| `reimport_row` | 8 | `reimport:row:<import_id>:<row_number>` |
| `reimport_guess` | 9 | `reimport:guess:<item_type>:<item_id>` |
| `reimport_strip` | 10 | `reimport:strip:<book_id>:<type>:<value>` |
| `reimport_author` | 11 | `reimport:author:<book_id>` |

**Payload contracts** (string keys):

- **`reimport_mixed`:**
  - `book_id`, `title`, `subtitle`, `author_names`;
  - `archive` (identifiers `[[type,value,source]]`, editions with their identifiers, external_links, images
    `[id, …]`, list_items `[[user_list_id, user_id, position, completed_on, created_at]]`, reviews
    `[[user_id, rating, title, body, created_at]]`);
  - `row_keys` `[[import_id,row_number],…]`;
  - `redirect_to_book_id` (written by Task 9).
- **`reimport_match`:**
  - `goodreads_edition_id`, `goodreads_book_id`, `facts` (EditionFacts#to_h);
  - `outcome` `"matched"|"create"`, `book_id` (matched) or nil;
  - `match_decision_id`, `ai` `{answer, confidence, reason}`, `candidate_book_ids`;
  - `created_book_id` (written by apply).
- **`reimport_row`:**
  - `import_id`, `row_number`, `user_id`, `goodreads_edition_id`;
  - `action` `"keep"|"move"|"copy"|"add"`, `from_book_id` (nil for add), `to_book_id`;
  - `review` (bool: this row carries the review), `superseded_by` (row key, for older-import duplicates);
  - `moved` (written by apply: item ids and the review id before and after).
- **`reimport_guess`:** `item_type` (`UserListItem`|`Review`), `item_id`, `user_id`, `from_book_id`, `to_book_id`,
  `guess: true`, `moved`.
- **`reimport_strip`:** `book_id`, `identifier_type`, `value`, `because_row_key`.
- **`reimport_author`:** `book_id`, `before_author_ids`, `row_author_names`, `after` `{name => author_id|nil}`
  (nil = create), `ai`, `created_author_ids` (written by apply).

**Apply phase order:**
1. `reimport_match` (creates);
2. `reimport_row`;
3. `reimport_guess`;
4. `reimport_strip`;
5. `reimport_mixed` (delete when empty);
6. `reimport_author`.

---

### Task 1: Gate switches, verdict kinds and admin display

**Files:**
- Create: `web-app/config/initializers/goodreads_reimport.rb`
- Modify: `web-app/app/models/books/repair_verdict.rb` (enum, `#summary`, `#book_ids`)
- Modify: `web-app/app/components/admin/books/repair_verdict_row_component.rb` (`LABELS`)
- Modify: `web-app/app/controllers/admin/books/repair_verdicts_controller.rb` (`FILTER_KEYS` gains `guess`)
- Test: `web-app/test/models/books/repair_verdict_test.rb`, `web-app/test/components/admin/books/repair_verdict_row_component_test.rb`, `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb`

**Interfaces:**
- Produces:
  - `Rails.configuration.x.goodreads_reimport.enabled` and `.enrichment` (booleans).
  - The six kinds above.
  - `RepairVerdict#book_ids` returns these per kind:
    - mixed: `[book_id]`;
    - match: `[book_id]` compact;
    - row: `[from_book_id, to_book_id]` compact;
    - guess: `[from_book_id, to_book_id]`;
    - strip: `[book_id]`;
    - author: `[book_id]`.
  - `#summary` gives a one-line text per kind.

- [ ] **Step 1: Write failing tests**
  - model: `test "every reimport kind has a summary and book ids"`. Build one verdict of each new kind with the
    payloads above, then `assert_predicate verdict.summary, :present?` and assert `book_ids` equals the expected
    array.
  - component: `test "renders a reimport_row verdict"`. `assert_includes rendered.text.squish, "Re-import row"`.
  - controller: `test "guess filter shows only guesses"`. Two `reimport_guess` verdicts, one with
    `payload["guess"] = true` and one with `false`. `get admin_books_repair_verdicts_path(guess: "true")`, then
    assert 1 `[data-testid=verdict-row]`.
- [ ] **Step 2: Run them and watch them fail.** Run `bin/rails test test/models/books/repair_verdict_test.rb
  test/components/admin/books/repair_verdict_row_component_test.rb
  test/controllers/admin/books/repair_verdicts_controller_test.rb`. Expected: failures on the unknown kind and the
  KeyError from `LABELS`.
- [ ] **Step 3: Implement.**
  - Initializer: copy `config/initializers/goodreads_replay.rb`'s `OrderedOptions` shape, reading ENV via
    `GoodreadsEnv` with a boolean helper (add `GoodreadsEnv.boolean(name, default)` if absent).
  - Labels: `"Re-import: mixed book"`, `"Re-import: edition match"`, `"Re-import row"`,
    `"Re-import: guessed move"`, `"Re-import: legacy identifier"`, `"Re-import: author"`.
  - Filter: `guess` maps to `where("payload->>'guess' = 'true'")`.
- [ ] **Step 4: Run them and watch them pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit** with message `Goodreads re-import: gate switches, audit kinds, admin display`.

### Task 2: Finder `exclude_ids:`

**Files:**
- Modify: `web-app/app/lib/data_importers/finder_base.rb` (the `excluded?` check) and
  `web-app/app/lib/data_importers/books/book/finder.rb` (constructor)
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb`

**Interfaces:**
- Produces: `Finder.new(..., exclude_ids: Set[Integer])`. A candidate whose record id is in the set is dropped from
  every source, exactly as `exclude:` drops one record. Default: empty.

- [ ] **Step 1: Write a failing test.** `test "exclude_ids keeps the listed books out of every source"`. Two books
  with the same exact title and author, one in `exclude_ids`. `finder.call(query:, verify: true)` must never return
  the excluded one, and its `candidates` must not include it.
- [ ] **Step 2: Run it and watch it fail.** Expected: ArgumentError (unknown keyword).
- [ ] **Step 3: Implement.** Store `@exclude_ids`; `excluded?(record)` returns true when
  `record.is_a?(model_class) && @exclude_ids.include?(record.id)`, in addition to the existing single-record check.
- [ ] **Step 4: Run it and watch it pass.** Also run the whole `finder_test.rb`. Expected: PASS.
- [ ] **Step 5: Commit** with message `Finder: exclude_ids keeps a set of books out of every source`.

### Task 3: EditionFacts

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/edition_facts.rb`
- Test: `web-app/test/lib/services/books/goodreads_reimport/edition_facts_test.rb`

**Interfaces:**
- Produces: `EditionFacts.call(edition: Books::GoodreadsEdition) -> EditionFacts::Facts`, a Struct with `full_title`,
  `title`, `subtitle`, `author_names`, `year`, `isbn13`, `isbn10`, `goodreads_book_id`, `series_name`,
  `series_number`, plus `#to_h` (string keys) and `#to_query`. `#to_query` returns a
  `DataImporters::Books::Book::ImportQuery` with `title`, `author_names`, `year`, `isbn13: [..]`, `isbn10: [..]`,
  `goodreads_id: [..]`, `series_name`, `series_number`.

- [ ] **Step 1: Write failing tests.**
  - `test "full title comes from the CSV row, not the edition's cut title"`. An edition titled "Batman" whose row's
    `raw["Title"]` is `"Batman: Year One (Batman #404-407)"`. Assert `full_title == "Batman: Year One (Batman
    #404-407)"`, `title == "Batman"`, `subtitle == "Year One"`.
  - `test "authors are the primary author then additional authors, deduplicated"`.
  - `test "year is original publication year, else year published"`.
- [ ] **Step 2: Run them and watch them fail.** Expected: NameError.
- [ ] **Step 3: Implement.**
  - The full title is the most common `raw["Title"]` across the edition's rows, with ties going to the lowest
    row id. The title and subtitle are `GoodreadsRebuild::ExportFacts.clean_title` of that, split at the first `": "`.
  - Authors: `[primary_author, *additional_authors]`, normalized with `Services::Text::NameNormalizer`, compacted,
    unique.
- [ ] **Step 4: Run them and watch them pass.** Expected: PASS.
- [ ] **Step 5: Commit** with message `Goodreads re-import: EditionFacts from the CSV rows`.

### Task 4: SameWorkTask (the AI double-check)

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/books/same_work_task.rb`
- Test: `web-app/test/lib/services/ai/tasks/books/same_work_task_test.rb`

**Interfaces:**
- Produces: `SameWorkTask.new(facts: EditionFacts::Facts, books: [Books::Book], parent: nil).call ->
  Services::Ai::Result` with `data: {book_id: Integer|nil, confidence: "high"|"medium"|"low", reason: String}`.
  - `book_id` is the candidate that is the same work under the spec §4.2 rules.
  - nil means none is.
  - Candidates are numbered 1..n in the prompt, and the answer's number is mapped back to an id.

- [ ] **Step 1: Write failing tests**, in the style of `match_export_authors_task_test.rb`:
  - `user_prompt` contains the CSV full title, each author, the year, and each candidate's "title: subtitle",
    authors, year and up to 3 edition titles.
  - `system_message` states the §4.2 rules: a translation of the same work is the same; a different volume, part,
    adaptation, guide, summary or box set is not; a combo is only itself.
  - `process_and_persist({parsed: {candidate_number: 2, confidence: "high", reason: "x"}})` returns the second book's
    id.
  - `candidate_number: nil` gives `book_id: nil`.
  - An out-of-range number gives a failed Result.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement** as a `BaseTask` subclass. `ResponseSchema < OpenAI::BaseModel` has
  `required :candidate_number, Integer, nil?: true`, `required :confidence, String` (enum high/medium/low) and
  `required :reason, String`.
- [ ] **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `AI: SameWorkTask double-checks a Goodreads edition against candidate books`.

### Task 5: MixedBooks (the set, and the archive)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/mixed_books.rb`
- Test: `web-app/test/lib/services/books/goodreads_reimport/mixed_books_test.rb`

**Interfaces:**
- Consumes: `Books::RebuildBookSurvey` lump classification (refreshed by `GoodreadsRebuild::Survey` with
  `resurvey: true` before the run; Task 14's rake prints the reminder); `GoodreadsRebuild::Cohort`;
  `GoodreadsRebuild::LegacyBookMap`; `RecordVerdict`.
- Produces:
  - `MixedBooks.ids -> Set[Integer]`: lump-classified books that are `Cohort.derived` and not trusted.
  - `MixedBooks.archive(book) -> RepairVerdict`, a `reimport_mixed` verdict, `decided_by: :rule`,
    `auto: true` (approved). Its payload is per the contract above, and the archive is written only once: a
    re-run never overwrites `archive`.

- [ ] **Step 1: Write failing tests.**
  - `ids` includes a derived lump and excludes a trusted lump, a coherent book, and a lump with no survey row.
  - `archive` stores every identifier (with source), edition, list item and review, plus the row keys.
  - Calling `archive` twice leaves the first `archive` payload unchanged.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement** using `LegacyBookMap.build.legacy_ids_for(book.id)` for the rows.
- [ ] **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: the mixed-book set and its archive`.

### Task 6: MatchEdition and MatchEditionsJob

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/match_edition.rb`,
  `web-app/app/sidekiq/books/goodreads_reimport/match_editions_job.rb`
- Test: `web-app/test/lib/services/books/goodreads_reimport/match_edition_test.rb`,
  `web-app/test/sidekiq/books/goodreads_reimport/match_editions_job_test.rb`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces:
  - `MatchEdition.call(edition:, exclude_ids:, finder: nil, task_class: SameWorkTask) -> Result`, with `data:
    {outcome: :matched|:create|:retry|:kept, verdict:}`.
  - `MatchEdition.default_finder(exclude_ids:)`, the blinded finder with `open_library: :none`.
  - `MatchEditionsJob` with `sidekiq_options queue: :low, retry: 3`: `perform(edition_ids)` runs each id through
    `MatchEdition` and is a no-op while the gate is off.
  - `MatchEditionsJob.enqueue(limit:) -> Integer` (class method on the job): distinct `goodreads_edition_id`s of in-scope rows, most rows first,
    in slices of 100.

Rules for `MatchEdition`:
- **An existing non-rejected `reimport_match` verdict:** `:kept`.
- **The finder:** `finder.call(query: facts.to_query, verify: true, subject: edition)`. A result that is fallback or
  has `sources_failed` gives `:retry`, and nothing is recorded.
- **Candidates for the AI:** the matched record first, then the rest of `match.candidates` with records, up to 6.
  With no candidates at all, the outcome is "create" without an AI call.
- **Approving:**
  - AI picks the finder's match with `high`: `matched`, auto-approved.
  - AI picks another candidate with `high`, or anything at `medium` or `low`: `matched`, proposed.
  - AI says none of them: `create`. Auto-approved only when the finder also returned unmatched; otherwise proposed.
- **An AI failure** gives `:retry`, and nothing is recorded.

- [ ] **Step 1: Write failing tests**, with a mock finder and a mock task class:
  - each approval branch above;
  - `"an AI error records nothing and returns :retry"` (Review Focus 5);
  - `"a mixed book is never offered to the AI"`: the finder is built with `exclude_ids` containing it, so assert
    `default_finder` passes them through;
  - the job test asserts `MatchEdition` is never called while `enabled` is false.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement.** Record verdicts with `RecordVerdict.call(kind: :reimport_match, subject_key:,
  payload:, decided_by: :ai, confidence:, auto:, replace_superseded: true)`. Store `match_decision_id`.
- [ ] **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: match each edition (blinded finder + AI check)`.

### Task 7: LibraryRules, extracted from WriteLibrary

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/library_rules.rb`
- Modify: `web-app/app/lib/services/books/goodreads_imports/write_library.rb`, so it uses `LibraryRules` with no
  behaviour change
- Test: `web-app/test/lib/services/books/goodreads_imports/library_rules_test.rb`. The existing
  `write_library_test.rb` must stay green, unchanged.

**Interfaces:**
- Produces: `LibraryRules.write_row(user:, row: Books::GoodreadsImportRow, book: Books::Book, fallback_created_at:)
  -> {list_item_ids: [...], review_id: Integer|nil}`. It applies WriteLibrary's rules for one row and one book:
  - shelf to list;
  - read drops currently-reading;
  - `completed_on` from Date Read;
  - an existing item only gets a blank date filled;
  - position after the list's max;
  - review only when the user has none on that book;
  - rating 0 with text gives an unrated review.

  It runs under `user.with_lock` and calls `SummaryRecalculator` for the book when a review was written.

- [ ] **Step 1: Write failing tests** for `write_row`:
  - a read row lands on the read list dated from Date Read;
  - a to-read row lands on want to read;
  - a custom shelf lands on its custom list;
  - a second call with the same row and book changes nothing (idempotent);
  - a row with a review writes it once.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement** by moving WriteLibrary's private rules into `LibraryRules` and calling them from both
  places. WriteLibrary's batch `insert_all` path may stay. It must share the shelf-to-list, date and review-choice
  rules.
- [ ] **Step 4: Run** `library_rules_test.rb` and `write_library_test.rb`. Expected: both PASS.
- [ ] **Step 5: Commit** with message `Goodreads imports: extract LibraryRules so one row can be written`.

### Task 8: DecideRow and DecideRowsJob

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/decide_row.rb`,
  `web-app/app/sidekiq/books/goodreads_reimport/decide_rows_job.rb`
- Test: matching `test/lib/...` and `test/sidekiq/...` files

**Interfaces:**
- Consumes: approved, applied `reimport_match` verdicts. The destination is `payload["book_id"]`, or
  `payload["created_book_id"]` once the create applied. `Apply::MergedBook`.
- Produces:
  - `DecideRow.call(row:) -> Result` with `data: {outcome: :recorded|:waiting|:kept, verdict:}`.
  - `DecideRowsJob` with `queue: :low, retry: 3`: `perform(row_ids)`, gated.
  - `DecideRowsJob.enqueue(limit:) -> Integer` (class method on the job).

Rules:
- **No approved, applied match** for the row's edition yet: `:waiting`, nothing recorded.
- **Same edition in a newer completed import of the same user:** `action: "keep"`,
  `superseded_by: "<newer row key>"`, auto-approved. Apply does nothing for it (Review Focus 2).
- **`from` is `MergedBook.call(row.legacy_book_id)`.** Then:
  - nil: `add`;
  - equal to the destination: `keep`;
  - different: `move`. But if another in-scope row of the same user with the same `legacy_book_id` goes to a
    **different** destination, every such row gets `copy`, and the one with the lowest row key also carries the
    review (Review Focus 1).
- **`review: true`** when this row's CSV has My Rating > 0 or My Review present, and it is the user's newest such
  row for this destination.
- Every verdict is `decided_by: :rule`, auto-approved, except when `from` is a trusted book and the action would
  remove the user's only entry on it. Those are proposed.

- [ ] **Step 1: Write failing tests:** one per rule above, including Review Focus 1 and 2, and `:waiting` when the
  match is unapplied.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: decide every row against what the user has now`.

### Task 9: DecideGuesses

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/decide_guesses.rb`
- Test: `web-app/test/lib/services/books/goodreads_reimport/decide_guesses_test.rb`

**Interfaces:**
- Consumes: `reimport_mixed` verdicts, and the `reimport_row` verdicts of their rows.
- Produces: `DecideGuesses.call(mixed_verdict:) -> Result` with `data: {guesses:, redirect_to_book_id:}`.
  - The most-read destination is the `to_book_id` with the most `reimport_row` verdicts among this book's rows.
    Ties go to the lowest book id.
  - Every list item or review on the mixed book that no row of that user explains gets a `reimport_guess` verdict
    (`guess: true`, `decided_by: :rule`, auto-approved), pointing at that destination.
  - Writes `redirect_to_book_id` into the mixed verdict's payload.
  - Returns `:waiting` (nothing written) until every row of the book has a `reimport_row` verdict.

- [ ] **Step 1: Write failing tests:**
  - a hand-added item gets a guess to the most-read destination;
  - an item explained by a row gets none;
  - the method waits while any row is undecided.
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: hand-added entries on mixed books become flagged guesses`.

### Task 10: Apply handlers for creates, rows and guesses

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_imports/create_book.rb`. Add `provisional: true` as a keyword
  argument (default unchanged) and pass it to the importer.
- Create: `web-app/app/lib/services/books/goodreads_reimport/apply/match.rb`, `apply/row.rb`, `apply/guess.rb`
- Test: one file per handler under `test/lib/services/books/goodreads_reimport/apply/`

**Interfaces:**
- Handler contract (the same as `GoodreadsReplay::Apply::*`): `call(verdict:) -> Result` with `data: {outcome:
  :applied|:noop, reason:, follow_ups: [], ranking_configuration_ids: []}`.
- `Apply::Match`:
  - `matched`: write `GoodreadsEdition#book_id` (shared cache: the decision now beats legacy's) and set
    `resolution: :matched`.
  - `create`: `CreateBook.call(edition:, import: <the edition's newest in-scope row's import>,
    match: <a DataImporters::Match unmatched from the payload>, provisional: false)`, then store `created_book_id`.
- `Apply::Row`:
  - `keep`: noop.
  - `add`: `LibraryRules.write_row`. A list that already holds the book is a noop (Review Focus 3).
  - `move` and `copy`: per spec §8 calls 1 and 2.
    - **move:** move the user's items on `from` that this row explains to `to`, as `Apply::Relink` moves them
      (fill a blank date if the list already holds `to`). Move the review only when `review: true`.
    - **copy:** create the item on `to`, dated from this row (`LibraryRules`), and leave `from`'s item. The
      `Apply::Mixed` delete or a later move removes it.
  - Store `moved` with before and after ids. Reuse the deadlock retry.
- `Apply::Guess`: moves the one item or review to `to_book_id`, with the same collision rules as `Relink`.

- [ ] **Step 1: Write failing tests**, one per branch, including:
  - `"create makes a non-provisional book and caches it on the edition"`;
  - `"add is a no-op when the list already holds the book"` (Review Focus 3);
  - `"copy keeps the old item until the mixed book is deleted"`;
  - `"move carries the review only for the review row"`.
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** **Step 4: Run them and watch them pass.**
  Run `create_book_test.rb` too.
- [ ] **Step 5: Commit** with message `Goodreads re-import: apply creates, rows and guesses`.

### Task 11: Apply handlers for legacy identifiers, mixed deletes and authors, plus ApplyJob

**Files:**
- Create: `apply/strip.rb`, `apply/mixed.rb`, `apply/author.rb`,
  `web-app/app/lib/services/books/goodreads_reimport/apply.rb`,
  `web-app/app/sidekiq/books/goodreads_reimport/apply_job.rb`
- Test: matching test files

**Interfaces:**
- `Apply::Strip`: `GoodreadsReplay::Apply::StripIdentifier.change(book:, remove: [[type, value]], add: [])`, only
  when the identifier on that book has `source: "legacy"`. Otherwise noop.
- `Apply::Mixed`:
  - **noop "not empty"** while the book still has any user list item or review that no `reimport_row` `copy` or
    applied guess accounts for (Review Focus 4);
  - **otherwise:** destroy the remaining copied-from items, then `book.destroy!`, then
    `RedirectRecorder.merged(item_type: "Books::Book", from_id:, to_id: redirect_to_book_id)`.
  - All in one transaction, except the redirect, which runs after commit.
- `Apply::Author`:
  - set the book's authors to `after`, creating authors with `DataImporters::Books::Author::Importer` for nil
    entries;
  - store `created_author_ids`;
  - never on a trusted book unless the verdict was admin-approved (`reviewed_at` present).
- `Apply.call(limit: 500) -> Result` with `data: {applied:, noop:, failed:, remaining:}`:
  - takes approved, current, **unapplied** verdicts of the first kind in the phase order that has any;
  - runs up to `limit` of them in id order through their handler;
  - sets `applied_at` on `:applied` and `error` on failure;
  - uses the deadlock retry from `GoodreadsReplay::ApplyVerdicts#call_handler`;
  - batches the follow-ups once per call.
- `ApplyJob` with `queue: :low, retry: 3`: `perform` calls `Apply.call` and re-enqueues itself
  (`self.class.perform_async`) while `remaining > 0`. It is a no-op while the gate is off. A second copy exits
  immediately (advisory lock, as in `GoodreadsRebuild::Survey`).

- [ ] **Step 1: Write failing tests:**
  - strip ignores a non-legacy identifier;
  - mixed refuses while a guess is unapplied and deletes once it applied (Review Focus 4);
  - mixed records the redirect to the most-read book;
  - author is proposed-only for a trusted book;
  - `Apply` runs phases in order and leaves later phases for later calls;
  - `ApplyJob` re-enqueues while `remaining > 0` and stops at 0;
  - two concurrent `ApplyJob`s: the second exits.
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: apply identifiers, mixed deletes, authors; self-requeuing ApplyJob`.

### Task 12: CheckAuthor and CheckAuthorsJob

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/check_author.rb`,
  `web-app/app/sidekiq/books/goodreads_reimport/check_authors_job.rb`
- Test: matching files

**Interfaces:**
- `CheckAuthor.call(book:, author_finder: nil, task_class: ...) -> Result` with `data: {outcome:
  :agrees|:recorded|:kept, verdict:}`.
  - The row author names are the most common `EditionFacts#author_names` across the editions whose applied
    `reimport_row` verdicts point at this book.
  - **Agree** when each name matches a current author by `Services::Text::PersonNameKey` (name or alternate names),
    or by `GoodreadsRebuild::MatchAuthors`' AI same-person check against current authors.
  - **Disagree:**
    - for each unmatched name, search the catalog with `DataImporters::Books::Author::Finder` (its existing call,
      `verify: true`) and accept only an AI-confirmed same person, else nil (create);
    - record `reimport_author`: auto-approved only for import-made books where every name resolved with high
      confidence; proposed otherwise; always proposed for trusted books.
- `CheckAuthorsJob.enqueue(limit:)` (class method on the job): books that are the destination of an applied `reimport_row`, in slices of 100.
- `CheckAuthorsJob`: gated.
- **Wrong alternate names** (spec §4.7, afterwards): `CheckAuthor.stale_alternates(author) -> [String]`, the names
  on `author.alternate_names` that are another existing author's name and that no row of this author's books
  names. Removing them is part of `Apply::Author` for the authors it touches.

- [ ] **Step 1: Write failing tests:**
  - agree by name key;
  - agree by the AI same-person check;
  - disagree, with a catalog author found (linked);
  - disagree, with none found (create);
  - a trusted book is always proposed;
  - stale alternates.
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: check each re-imported book's authors against its rows`.

### Task 13: Enrichment for created books, behind the gate

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_rebuild/queue_enrichment.rb`
- Test: `web-app/test/lib/services/books/goodreads_rebuild/queue_enrichment_test.rb`

**Interfaces:**
- `QueueEnrichment` also selects books from applied `reimport_match` verdicts with `created_book_id`, and books
  whose applied `reimport_author` created authors. Pass `new_author_ids:` the same way.
- These are selected only while `config.x.goodreads_reimport.enrichment` is true. They come after the existing
  `fix_identity` books, under the same in-flight cap.

- [ ] **Step 1: Write failing tests:**
  - `"re-import created books wait while enrichment is off"`;
  - `"they start once it is on, after the rebuild's books"`.
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: enrich created books only once the gate is open`.

### Task 14: Report, acceptance queries, sample check and rake tasks

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_reimport/report.rb`,
  `web-app/lib/tasks/books/goodreads_reimport.rake`
- Test: `web-app/test/lib/services/books/goodreads_reimport/report_test.rb`,
  `web-app/test/tasks/books/goodreads_reimport_rake_test.rb` (if the repo has rake tests; otherwise cover the
  services)

**Interfaces:**
- `Report.call -> String`, in `FixesReport`'s style:
  - verdict counts per kind, status and action;
  - AI agreement rate (`reimport_match` auto-approved ÷ all);
  - proposed count;
  - guesses;
  - errors (first 5);
  - 10 random samples per kind;
  - the acceptance queries from spec §6, each printed with its count (expected 0):
    - in-scope rows whose applied destination's title key differs from the row's full-title key with no approved
      verdict explaining it;
    - users whose list item plus review count dropped. Uses a snapshot written by `snapshot` below.
    - mixed books still present.
- `Report.snapshot -> Integer`: writes per-user counts of list items and reviews on books into
  `tmp/goodreads_reimport_counts.json`, before apply.
- `Report.sample(n: 300, mixed_books: 20) -> String`: picks n random applied rows plus every row of 20 random
  former mixed books, asks `SameWorkTask` (an independent call) whether each row's final book is the CSV row's work,
  and lists every "no".
- Rake (all print, refuse while the gate is off unless noted, and enqueue only):
  - `books:goodreads_reimport:archive_mixed`: archives `MixedBooks.ids` via `Books::GoodreadsReimport::ArchiveMixedJob` (create it in this task, queue :low, gated) in slices of 100;
  - `books:goodreads_reimport:match[limit|all]`;
  - `books:goodreads_reimport:decide[limit|all]`, which also runs `DecideGuesses` for mixed books once their rows
    are decided;
  - `books:goodreads_reimport:apply`, which enqueues `ApplyJob`;
  - `books:goodreads_reimport:check_authors[limit|all]`;
  - `books:goodreads_reimport:report`, which prints and works with the gate off;
  - `books:goodreads_reimport:snapshot`;
  - `books:goodreads_reimport:sample`, which enqueues a job that logs its result.

- [ ] **Step 1: Write failing tests** for `Report.call` (headings and counts on a fixture set), `snapshot`, and
  `sample` with a mocked task listing a "no".
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** **Step 4: Run them and watch them pass.**
- [ ] **Step 5: Commit** with message `Goodreads re-import: report, acceptance queries, sample check, rake tasks`.

### Task 15: Docs and dev rehearsal

**Files:**
- Create: `docs/features/goodreads-reimport.md` (what it does, the order, the gate, the audit kinds, how to review
  guesses)
- Modify: `docs/launch-todo.md`: a new section listing the production run order. Gate on, enrichment off, then:
  1. resurvey;
  2. archive_mixed;
  3. match;
  4. report and review;
  5. decide;
  6. snapshot;
  7. apply;
  8. check_authors and apply;
  9. report;
  10. sample;
  11. enrichment on after the new enrichment steps land.

  Plus a warning line: **do not run `data_migration:sync` until it has been checked against this run** (spec
  §3.9).
- Modify: `docs/features/goodreads-rebuild.md`: stage two now points to this.

- [ ] **Step 1: Write both docs.**
- [ ] **Step 2: Dev rehearsal**, with the controller's go-ahead. Shane restores the dev database himself if
  needed.
  - Snapshot first: `bin/snapshot-dev-db.sh --label pre-reimport`.
  - Set both gate ENV vars for the local Sidekiq, and keep enrichment off.
  - Run the rake steps above, with `[200]` limits first, then `all`.
  - Save `Report.call` and `Report.sample` outputs into the ledger.
  - Any "no" from `sample` is a finding to fix before the branch is finished.
- [ ] **Step 3: Restore** with `bin/snapshot-dev-db.sh --restore`, if the controller asks.
- [ ] **Step 4: Commit the docs** with message `Docs: Goodreads re-import feature doc and launch steps`.

---

## Self-review notes (rulings made while planning)

- **Matching runs with `open_library: :none`.** That is the same as stage one's blinded finder, because `/resolve`
  has capacity 1. The AI check replaces Open Library's tie-break. Cost if wrong: some "create" decisions for books
  Open Library could have matched. These land as proposed when the finder found candidates.
- **The mixed set is the fresh survey's lump classification** (spec §8 call 7). That rule never compares titles, so
  some same-author, same-year mixtures are not in the set. Their rows are still re-matched one by one. Such a record
  keeps the work its matching rows confirm, and the other rows move off it. Only the survey's lumps are deleted.
- **Approved matches write `GoodreadsEdition#book_id`**, the cache shared with member uploads. Members' future
  uploads then land on the re-import's answer instead of legacy's. Cost if wrong: a bad approved match also
  misleads members until fixed.
- **Rows with a nil `legacy_book_id` are `add`.** A wrong entry legacy left on an unidentifiable book stays, because
  no row explains it. That gap is printed by the report as "rows with no current book".
