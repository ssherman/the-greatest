# Goodreads rebuild, increment 2b: the fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For every derived book whose title or authors disagree with its Goodreads export rows (47,387 on dev, 2026-10-29), decide whether the right book already exists. If it does, record a merge into it. If not, record a reset and re-import of the book in place. `apply` carries both out, and the fixed books are enriched nonstop at the Goodreads fetch cap, most-listed first.

**Architecture:**
- **Decide.** A per-book service builds the export facts from the survey's main edition group and its pass-2 evidence. It runs the importer's finder in a new *blinded* configuration: no Open Library, only trusted-source identifiers, the book itself excluded. It records one `Books::RepairVerdict`: `merge_books` (with `reset_source`) when an eligible book is found, otherwise the new kind `fix_identity`.
- **Apply.** The existing `books:goodreads_replay:apply` gains a `FixIdentity` handler. It wipes the book's legacy-derived data, sets title, subtitle and year from the export, and re-imports authors and identifiers through `DataImporters::Books::Book::Importer`. The `MergeBooks` handler resets the source first when the verdict says so.
- **Enrich.** A job every 10 minutes keeps up to 300 fixed books in the existing book-enrichment workflow, most-listed first.

**Tech Stack:** Rails 8, Sidekiq + sidekiq-cron, Minitest + Mocha, PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md`. §4.1 is the authority for this increment; also §3, §6, §6a and §12 calls 2, 4 and 7.

## Global Constraints

- Never touch a trusted book's title, authors or data. Trusted is `Services::Books::GoodreadsRebuild::Cohort.trusted?(id)`. Re-check at apply time, not only at decide time (§12 call 2).
- A trusted book always survives a merge. A derived book is never the merge target if it is itself in the fix set.
- **Never judge on legacy evidence.** In the blinded finder, an identifier whose `source` is `legacy` or nil counts for nothing. Trusted identifier sources: `Identifier::VERIFIED_SOURCES + ["goodreads_import"]`.
- **Zero wrong merges.** A merge is automatic only when all three hold:
  - the target holds a verified (`source: open_library`) `books_work_openlibrary_id` that is in the main group's evidence `ol_work_keys`;
  - the target's title agrees exactly (`Check.title_key`) with one of the group's export titles;
  - the group has no volume.

  Everything else is proposed (§12 call 4).
- **A `fix_identity` is automatic only when a main-group edition's evidence has `world_cat == "agrees"`.** Otherwise it is proposed (§4.1 step 2). On a 3,000-book dev sample, 1,618 qualify.
- **Never surname matching.** Authors come from the export's full names through the author importer.
- **Reset keeps:**
  - id, slug, `provisional`, `book_kind`;
  - list items, user list items, reviews, reading goals, ranked items, `goodreads_editions`, ai_chats, enrichments, match_decisions.
- **Reset clears:**
  - associations: `book_authors`, `credits`, `descriptions`, `category_items`, `images`, `editions`, `identifiers`, `alternate_title_records`, `series_books`, `book_countries`, `external_links`;
  - columns: `description`, `subtitle`, `sort_title`, `first_published_year`, `original_language_id`, `default_edition_id`, `book_length`, `page_range`, `word_count`, `amazon_enriched_at`, and `alternate_titles` (to `[]`).
- **The importer's Open Library provider never runs here** (§4.1). Enrichment never runs inside `apply`; it is queued by the 10-minute top-up job.
- Rails 8 enum syntax; services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`; jobs via `bin/rails generate sidekiq:job`; `bundle exec standardrb`; ALWAYS run annotaterb, and never set `ANNOTATERB_SKIP_ON_DB_TASKS`.
- **No destructive commands against development.** The dev rehearsal in Task 8 is Shane's call, and a snapshot goes first.

## Review Focus

1. **A book added to a real list between decide and apply** is trusted now. `apply` must leave it untouched: no wipe and no merge. Pinned in Task 5.
2. **`apply` runs again after the book was enriched.** Every pass re-applies all approved verdicts, and a second `fix_identity` must not wipe the enriched data. Pinned in Task 5.
3. **The finder lands on a book that is itself in the fix set,** or on one whose only link is a legacy identifier. The result must be a `fix_identity`, never a merge. Pinned in Tasks 1 and 4.
4. **The author import fails at apply** (for example, the author importer raises). The verdict carries the error, `applied_at` stays nil, the next `apply` retries, and the book keeps its export title. Pinned in Task 5.
5. **Shane rejects a proposed merge.** The next decide run records a `fix_identity` for that book instead of leaving it broken. Pinned in Task 4.

---

## Rulings made while planning (Claude's calls; each with its cost if wrong)

1. **Lumps:** only the main group is fixed. The other groups' editions are left for stage two, which finds or creates a book per edition anyway (§5 step 2).
   *If wrong:* lumps' secondary works stay on the lump book until stage two. This changes when they move, not whether.
2. **Authors on re-import:** the main group's distinct `primary_author` values only, never `additional_authors`. The export doesn't say whether an additional author is a translator.
   *If wrong:* co-authored books lose their second author until a page check adds it.
3. **`goodreads_import` counts as trusted in the blinded finder.** It is the rebuild's own stamp from the export rows, so book B's rows can find book A once A's fix is applied.
   *If wrong:* a member-import stamp could match. No member imports exist yet.
4. **`fix_identity` applies once:** the handler no-ops when `applied_at` is set. A re-wipe would destroy enrichment. A later sync's legacy identifiers are the weekly catch-up's job.
   *If wrong:* a sync-undone fix is not re-done automatically.
5. **Pending duplicate pairs** (834 touch the fix set) are left alone. The merger re-keys pairs on merge, and stage two re-judges every pair fresh (§5 step 3).
6. **First published year** is set from the main group's export original year, because the importer's Open Library provider is skipped.
7. **Enrichment runs continuously** (Shane, 2026-10-29: "enrich nonstop until it's done"). Every 10 minutes a job tops up the rebuild's books waiting for a Goodreads fetch to `config.x.goodreads_rebuild.in_flight` (default 300). The Goodreads fetch cap paces it, so the whole cap is used and priority order holds.
   - A new book from anywhere else joins a short line, not a line of 45,000.
   - The cap and the spacing become ENV-overridable, so Shane can raise 1,500 a day after a day or two with no failures, without a deploy.
   - *If wrong:* the rebuild books get fewer fetches than the cap allows; raise `in_flight`.

## File structure

| File | Responsibility |
|---|---|
| `app/lib/data_importers/sources/identifiers.rb` (modify) | optional `sources:` filter on identifier hits |
| `app/lib/data_importers/books/book/finder.rb` (modify) | `open_library: :none` mode; `identifier_sources:` passed to the source |
| `app/models/books/repair_verdict.rb` (modify) | kind `fix_identity: 5`; `book_ids`, `summary` |
| `app/lib/services/books/goodreads_rebuild/export_facts.rb` (create) | export facts for a survey's main group |
| `app/lib/services/books/goodreads_rebuild/reset_book.rb` (create) | wipe a book's legacy-derived data |
| `app/lib/services/books/goodreads_rebuild/decide_fix.rb` (create) | per-book decision: merge or fix verdict |
| `app/lib/services/books/goodreads_rebuild/decide_fixes.rb` (create) | which books, in what order; enqueue batches |
| `app/lib/services/books/goodreads_rebuild/fixes_report.rb` (create) | counts and samples |
| `app/lib/services/books/goodreads_replay/apply/fix_identity.rb` (create) | apply handler |
| `app/lib/services/books/goodreads_replay/apply/merge_books.rb` (modify) | reset the source first when `reset_source` |
| `app/lib/services/books/goodreads_replay/apply_verdicts.rb` (modify) | `fix_identity` first in `HANDLERS` |
| `app/lib/services/books/goodreads_rebuild/queue_enrichment.rb` (create) | start enrichment workflows by priority |
| `app/sidekiq/books/goodreads_rebuild/decide_fixes_job.rb` (create) | one batch of book ids |
| `app/sidekiq/books/goodreads_rebuild/queue_enrichment_job.rb` (create) | 10-minute top-up driver |
| `config/initializers/goodreads_rebuild.rb` (create), `config/schedule.yml` (modify) | in-flight setting, cron entry; ENV fetch cap in `config/initializers/goodreads.rb` |
| `lib/tasks/books/goodreads_rebuild.rake` (modify) | `decide_fixes`, `fixes_report`, `queue_enrichment` |
| `docs/features/goodreads-rebuild.md`, `docs/launch-todo.md` §11 (modify) | docs and production steps |

---

### Task 1: The blinded finder

**Files:**
- Modify: `web-app/app/lib/data_importers/sources/identifiers.rb`, `web-app/app/lib/data_importers/books/book/finder.rb`
- Test: `web-app/test/lib/data_importers/sources/identifiers_test.rb`, `web-app/test/lib/data_importers/books/book/finder_test.rb` (add to existing files; create the first if absent)

**Interfaces:**
- Produces:
  - `DataImporters::Sources::Identifiers.new(model_class:, lookups:, sources: nil)`. `sources` is an array of `Identifier.sources` keys (strings). nil means every row, as today.
  - `DataImporters::Books::Book::Finder.new(open_library_client: nil, open_library: :resolve, identifier_sources: nil)`. `OPEN_LIBRARY_MODES` gains `:none`, which adds no Open Library source.
  - `Finder::TRUSTED_IDENTIFIER_SOURCES = (Identifier::VERIFIED_SOURCES + ["goodreads_import"]).freeze`.

- [ ] **Step 1: Write the failing tests**
  - `identifiers_test`: "sources filter drops identifier rows from other sources". Two books hold isbn13 `9780000000001`: one with `source: :legacy`, one with `source: :open_library`. With `sources: ["open_library"]`, only the second book comes back. With `sources: nil`, both do.
  - `finder_test`: "blinded finder ignores a legacy-held ISBN".
    - Setup: `Finder.new(open_library: :none, identifier_sources: Finder::TRUSTED_IDENTIFIER_SOURCES)`. The query's title and author match no book, and its ISBN is held by a fixture book with `source: :legacy`.
    - Assert `match.unmatched?`.
    - Assert no Open Library client method is called: inject a mock with `expects(:resolve).never` and `expects(:identifier).never`.
  - `finder_test`: "unknown open_library mode still raises". `Finder.new(open_library: :bogus)` raises `ArgumentError`.

- [ ] **Step 2: Run them**
  - Run: `bin/rails test test/lib/data_importers/sources/identifiers_test.rb test/lib/data_importers/books/book/finder_test.rb`
  - Expected: FAIL with `ArgumentError` (unknown keyword `sources` / unknown mode `:none`).
- [ ] **Step 3: Implement**
  - In `Identifiers#call`, add `.where(source: @sources)` when `@sources`.
  - `Finder#candidate_sources` passes `sources: @identifier_sources`.
  - `open_library_sources` returns `[]` for `:none`.
  - Update the class comment's list of modes.
- [ ] **Step 4: Run the two files plus every other finder caller's tests**
  - Run: `bin/rails test test/lib/data_importers test/lib/services/books/find_duplicates_test.rb test/lib/services/books/goodreads_replay`
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Book finder: blinded mode (no Open Library, trusted identifier sources only)"`

### Task 2: `ExportFacts`

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/export_facts.rb`
- Test: `web-app/test/lib/services/books/goodreads_rebuild/export_facts_test.rb`

**Interfaces:**
- Consumes:
  - `Books::RebuildBookSurvey#groups`: an array of hashes ordered biggest-first, with keys `edition_ids`, `goodreads_book_ids`, `titles`, `authors`, `year`, `volume`, `row_count`.
  - `Books::RebuildEditionEvidence.for_editions(editions)`, which returns `{edition_id => evidence}`.
- Produces: `Services::Books::GoodreadsRebuild::ExportFacts.call(survey:)` returns a `Facts` struct with these members:
  - `title`, `subtitle`, `full_title`
  - `author_names` (Array)
  - `year` (Integer or nil), `volume`
  - `series_name`: the main edition's `series_name`, kept on the verdict for the later series pass (§4); the title suffix is dropped
  - `isbn13`, `isbn10`, `goodreads_ids` (Arrays of String)
  - `ol_work_keys` (Array, most frequent first)
  - `edition_ids`
  - `world_cat_agrees` (Boolean)

  It also has `#to_query`, which returns a `DataImporters::Books::Book::ImportQuery` built from `title`, `subtitle`, `author_names`, `year`, `isbn13`, `isbn10`, `goodreads_ids` (as `goodreads_id:`), `ol_work_keys.first` (as `open_library_work_key:`), and `series_number: volume`. It has `#to_payload`, which returns a string-keyed Hash of every member.

  The main group is `survey.groups.first`.

- [ ] **Step 1: Write the failing tests** (build editions and evidence with `create!` in the test; check the fixture names first)
  - "full title comes from the main group's most-rowed edition, split at the first colon". The edition title is `"How to Work with (Almost) Anyone: Five Questions for Building the Best Possible Relationships"`.
    - `title == "How to Work with (Almost) Anyone"`
    - `subtitle == "Five Questions for Building the Best Possible Relationships"`
    - `full_title` is the whole string.
  - "a trailing Goodreads series suffix is dropped from the title". `"The Crossroads of Time (Crosstime (aka) Blake Walker #1)"` gives `title == "The Crossroads of Time"`. The rule is a final parenthetical containing `#<number>`.
  - "author_names are the distinct primary authors of the group's editions, most rows first; additional_authors are never included".
  - "isbn and goodreads ids cover every edition in the main group only". A second group's ISBN is absent.
  - "world_cat_agrees is true when any main-group edition's evidence agrees, false when none do or there is no evidence".
  - "ol_work_keys are ordered by how many main-group editions name them".
- [ ] **Step 2: Run them.**
  - Run: `bin/rails test test/lib/services/books/goodreads_rebuild/export_facts_test.rb`
  - Expected: FAIL (`NameError`).
- [ ] **Step 3: Implement `ExportFacts`.** Load the group's editions in one query and choose the main edition by row count:
  - read row counts from `Books::GoodreadsImportRow` grouped by `goodreads_edition_id` over the group's edition ids;
  - break ties on the lowest `goodreads_book_id`.
- [ ] **Step 4: Run them.**
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Goodreads rebuild: export facts for a book's main edition group"`

### Task 3: `ResetBook`

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/reset_book.rb`
- Test: `web-app/test/lib/services/books/goodreads_rebuild/reset_book_test.rb`

**Interfaces:**
- Produces: `Services::Books::GoodreadsRebuild::ResetBook.call(book:)`, which returns a Result. `data` is `{book:}`.
  - It clears exactly the Reset clears list in Global Constraints, in one transaction.
  - It does not save a new title; callers set the title after.
  - It raises `ArgumentError` when `Cohort.trusted?(book.id)`.

- [ ] **Step 1: Write the failing tests**
  - "clears every legacy-derived association and column". Give a derived book (id inside `Cohort.post_import_range`, on no list) one row of each association in the clears list and a value in each column. Assert each association `count == 0` and each column is nil (`alternate_titles == []`).
  - "keeps the book's id, slug, user list items, reviews and goodreads editions". Each is unchanged after the call.
  - "refuses a trusted book". A pre-import id raises `ArgumentError`, and nothing is deleted.
  - "running it twice is harmless". The second call succeeds with nothing left to clear.
- [ ] **Step 2: Run them.**
  - Expected: FAIL (`NameError`).
- [ ] **Step 3: Implement.**
  - Use `destroy_all` for the associations, so images and editions clean up their own children.
  - Use one `update_columns` for the scalars, then `book.reload`.
  - Queue `SearchIndexRequest.create!(parent: book, action: :index_item)`.
- [ ] **Step 4: Run them.**
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Goodreads rebuild: ResetBook clears a derived book's legacy data"`

### Task 4: `DecideFix` and the `fix_identity` kind

**Files:**
- Modify: `web-app/app/models/books/repair_verdict.rb` (enum and `book_ids`/`summary` branches)
- Create: `web-app/app/lib/services/books/goodreads_rebuild/decide_fix.rb`
- Test: `web-app/test/lib/services/books/goodreads_rebuild/decide_fix_test.rb`, `web-app/test/models/books/repair_verdict_test.rb`

**Interfaces:**
- Consumes: `ExportFacts` (Task 2); the blinded `Finder` (Task 1); `Services::Books::GoodreadsReplay::RecordVerdict.call(kind:, subject_key:, payload:, decided_by:, confidence:, reason:, auto:, replace_superseded: true)`.
- Produces:
  - `RepairVerdict` `kind` gains `fix_identity: 5`. For both new payloads, `book_ids` returns `[payload["book_id"]]` for `fix_identity`, and `[source_id, target_id]` for `merge_books` as now.
  - `summary` for `fix_identity` is `"Fix ##{book_id}: \"#{payload["full_title"]}\" by #{payload["author_names"].join(", ")}"`.
  - `Services::Books::GoodreadsRebuild::DecideFix.call(book:, survey:, finder: nil)` returns a Result. `data[:outcome]` is one of `:skipped`, `:merge`, `:fix` or `:kept`; `data[:verdict]` holds the verdict.
  - Subject key for both kinds: `"rebuild:#{book.id}"`.
  - Merge payload: `ExportFacts#to_payload` plus `source_id`, `target_id`, `reset_source: true`, `match_decision_id`.
  - Fix payload: `ExportFacts#to_payload` plus `book_id`.

**Decision order** (the algorithm; write it as these guard clauses):
1. Skip (`:skipped`) when any of these holds:
   - `Cohort.trusted?(book.id)`;
   - the survey is not `coherent` or `lump`;
   - `survey.title_agrees && survey.authors_agree && !survey.wrong_book`.
2. Keep (`:kept`, no change) when either holds:
   - a `fix_identity` verdict with this key exists that is not rejected;
   - a `merge_books` verdict with this key exists with status `proposed` or `approved`.
3. If a `merge_books` verdict with this key is `rejected`, go straight to step 5.
4. Run the finder: `finder.call(query: facts.to_query, verify: true, subject: book, exclude: book)`. The default finder is `Finder.new(open_library: :none, identifier_sources: Finder::TRUSTED_IDENTIFIER_SOURCES)`. A match is **eligible** when it is `matched?` and its record:
   - is not provisional;
   - and is either trusted, or derived with a survey whose `title_agrees && authors_agree && !wrong_book`.

   If the match is eligible, record `merge_books`:
   - automatic (`decided_by: :rule`, `confidence: :certain`, `auto: true`) under the Global Constraints merge rule;
   - otherwise `auto: false`, with `decided_by` taken from the match: `:ai` stays `:ai`, and everything else becomes `:rule`. Confidence is the match's.
5. Record `fix_identity`: `decided_by: :rule`, `auto: facts.world_cat_agrees`, and confidence `:high` when that holds, otherwise `:medium`.

- [ ] **Step 1: Write the failing tests** (stub the finder with Mocha, returning `DataImporters::Match` structs; build surveys with `create!`)
  - "records an automatic fix when nothing is found and WorldCat agrees": the result is `:fix`, the verdict is `fix_identity`, `approved`, `high`, and `payload["title"]` is the export title.
  - "records a proposed fix when WorldCat does not agree": status is `proposed`, confidence `medium`.
  - "records an automatic merge into a trusted book that holds the group's verified Open Library work and the same title": the verdict is `merge_books`, `approved`, `certain`, `payload["reset_source"] == true` and `target_id` is the trusted book.
  - "proposes the merge when the target holds the work key only from a legacy source". The payload is the same as above, but the status is `proposed`.
  - "proposes the merge when the main group has a volume".
  - "a match that is itself in the fix set gives a fix, not a merge" (Review Focus 3).
  - "a rejected merge gives a fix on the next run, without calling the finder" (Review Focus 5). Assert `finder.expects(:call).never`.
  - "a trusted book is skipped"; "a book whose title and authors agree is skipped".
  - "a second run keeps an existing proposed fix" (`:kept`, no new row).
  - `repair_verdict_test`: "fix_identity summary and book_ids".
- [ ] **Step 2: Run them.**
  - Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them, plus the repair-verdict controller test.**
  - Run: `bin/rails test test/lib/services/books/goodreads_rebuild/decide_fix_test.rb test/models/books/repair_verdict_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb`
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Goodreads rebuild: decide merge or fix per book (fix_identity kind)"`

### Task 5: Apply `fix_identity`, and reset before a rebuild merge

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/fix_identity.rb`
- Modify: `web-app/app/lib/services/books/goodreads_replay/apply/merge_books.rb`, `web-app/app/lib/services/books/goodreads_replay/apply_verdicts.rb`
- Test: `web-app/test/lib/services/books/goodreads_replay/apply/fix_identity_test.rb`, `.../apply/merge_books_test.rb`, `.../apply_verdicts_test.rb`

**Interfaces:**
- Consumes: `ResetBook` (Task 3); `DataImporters::Books::Book::Importer.call(..., match:, force_providers: true, providers: %i[authors query_identifiers], stamp_identifiers: true, enrich: false, query_identifier_source: :goodreads_import)`.
  - `match:` is a `DataImporters::Match` built here with `outcome: :matched, record: book, confidence: :certain, decided_by: :rule, reason: "goodreads rebuild fix_identity", candidates: []`.
  - The query comes from the payload: rebuild `ExportFacts` fields with `ImportQuery.new`, where the payload's `goodreads_ids` maps to `goodreads_id:`.
- Produces: `Apply::FixIdentity.call(verdict:)`, which returns a Result with `data[:outcome]` of `:applied` or `:noop`.
  - On `:applied` it writes `payload["created_author_ids"]` (from `ImportResult#created_author_ids`) onto the verdict with `update_columns`.
  - It raises `Apply::Failed` when the Authors provider fails, so the error is recorded and `applied_at` stays nil.
- `ApplyVerdicts::HANDLERS` gains `"fix_identity" => Apply::FixIdentity` as its first entry.

**Handler order:**
1. No-op when any of these holds:
   - `verdict.applied_at` is present (Ruling 4);
   - the book is gone;
   - `Cohort.trusted?` is true now (Review Focus 1).
2. Run `ResetBook`.
3. Use `update!` to set `title`, `subtitle` and `first_published_year` from the payload.
4. Run the importer.

Steps 2 and 3 run in one transaction; the import runs after it.

`MergeBooks`: when `payload["reset_source"]`:
- a trusted source raises `Apply::Failed`, with "source is trusted now";
- otherwise run `ResetBook` on the source, then the existing merger.

- [ ] **Step 1: Write the failing tests**
  - "applies: the book has the export title, subtitle and year; its old authors, identifiers and categories are gone; it has the export author and the export ISBN and Goodreads id with source goodreads_import". Stub `Books::Author::Importer` so no network is called.
  - "keeps the book's id, slug, user list items and reviews".
  - "never runs the Open Library provider or enrichment". Use `DataImporters::Books::Book::Providers::OpenLibrary.any_instance.expects(:populate).never`, and `Workflows::Books::BookEnrichment.expects(:start).never`. Check the provider's public method name first.
  - "a second apply is a no-op and leaves data added since in place" (Review Focus 2): apply, add a description, apply again; the description is still there and the outcome is `:noop`.
  - "a book that became trusted is left alone" (Review Focus 1): put it on a non-favorites list after recording, then apply. The outcome is `:noop` and the title is unchanged.
  - "an author import failure records the error and retries" (Review Focus 4). Stub the author importer to raise. Through `ApplyVerdicts.call(auto_apply: true)`:
    - `verdict.error` is present and `applied_at` is nil;
    - the book's title is the export title;
    - a second `ApplyVerdicts` call with the stub removed applies it.
  - `merge_books_test`:
    - "a reset_source merge clears the source's legacy data before merging": the target does not gain the source's legacy identifiers or categories, but does gain its user list items.
    - "refuses a reset_source merge from a trusted source".
  - `apply_verdicts_test`: "fix_identity applies before merge_books".
- [ ] **Step 2: Run them.**
  - Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole replay and rebuild test directories.**
  - Run: `bin/rails test test/lib/services/books/goodreads_replay test/lib/services/books/goodreads_rebuild`
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Goodreads rebuild: apply fix_identity; reset the source before a rebuild merge"`

### Task 6: The decide run, its job, report and rake tasks

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/decide_fixes.rb`, `.../fixes_report.rb`
- Create via generator: `bin/rails generate sidekiq:job books/goodreads_rebuild/decide_fixes`
- Modify: `web-app/lib/tasks/books/goodreads_rebuild.rake`
- Test: `.../decide_fixes_test.rb`, `.../fixes_report_test.rb`, `web-app/test/sidekiq/books/goodreads_rebuild/decide_fixes_job_test.rb`

**Interfaces:**
- Consumes: `DecideFix` (Task 4).
- Produces:
  - `DecideFixes.candidates`: a relation of book ids. These are derived books whose survey is coherent or lump and disagrees (Task 4's step 1, inverted), ordered by user-list-item count descending, then id.
  - `DecideFixes.enqueue(limit:)`, where `limit` is an Integer or nil for all. It slices candidate ids into batches of `BATCH_SIZE = 100` and calls `Books::GoodreadsRebuild::DecideFixesJob.perform_async(ids)` for each. It returns the count enqueued.
  - The job's `perform(book_ids)` calls `DecideFix` for each book that still exists and still has a survey. Per-book errors are logged and do not stop the batch. The job is on the `low` queue, with `retry: 3`.
  - `FixesReport.call` returns a String with these lines:
    - counts of `rebuild:` verdicts by kind × status × confidence;
    - applied counts;
    - 10 sample merges, as `book #id "our title" -> #target "target title" | export: "full_title"`;
    - 10 sample fixes, as `#id "our title" by our authors -> "full_title" by export authors`.
  - Rake: `books:goodreads_rebuild:decide_fixes[limit]` (`limit` is a number or `all`, and is required); `books:goodreads_rebuild:fixes_report`.

- [ ] **Step 1: Write the failing tests**
  - "candidates order the most-listed book first and leave out trusted, agreeing and unsupported books".
  - "enqueue slices into batches of 100 and respects limit". Use `Sidekiq::Testing.fake!` and assert job count and args.
  - "the job decides each book and survives one book raising". Stub `DecideFix` to raise for one id; the others are still decided.
  - "the report counts verdicts by kind and status and prints the export title beside ours".
- [ ] **Step 2: Run them.**
  - Expected: FAIL.
- [ ] **Step 3: Implement.** The rake task's `decide_fixes` prints `"queued N books in M batches"` and aborts without a limit argument.
- [ ] **Step 4: Run them.**
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Goodreads rebuild: decide_fixes run, job and fixes_report"`

### Task 7: Continuous enrichment of fixed books

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/queue_enrichment.rb`, `web-app/config/initializers/goodreads_rebuild.rb`
- Create via generator: `bin/rails generate sidekiq:job books/goodreads_rebuild/queue_enrichment`
- Modify: `web-app/config/initializers/goodreads.rb`, `web-app/config/schedule.yml`, `web-app/lib/tasks/books/goodreads_rebuild.rake`, `web-app/app/lib/services/books/goodreads_rebuild/fixes_report.rb` (from Task 6)
- Test: `.../queue_enrichment_test.rb`, `web-app/test/sidekiq/books/goodreads_rebuild/queue_enrichment_job_test.rb`, `.../fixes_report_test.rb`

**Interfaces:**
- Consumes: `Workflows::Books::BookEnrichment.start(book, initiated_by:, new_author_ids: [], author_names: [], options: {})`.
- Produces:
  - `QueueEnrichment.call(in_flight:)` returns a Result. `data` is `{started:, in_flight:, waiting:}`.
    - **In flight** means `WorkflowRun`s with `workflow: "books.book_enrichment"`, `initiated_by: "goodreads_rebuild"` and status running, whose `goodreads` step is not finished.
    - It starts `in_flight - current` more. They are taken from books with an applied `fix_identity` verdict that have no `books.book_enrichment` run created at or after the verdict's `applied_at`, ordered by user-list-item count descending, then id.
    - Each is started with `initiated_by: "goodreads_rebuild"`, `new_author_ids: payload["created_author_ids"] || []` and `author_names: payload["author_names"]`.
    - It does nothing while `Books::Goodreads::FetchGate.new.blocked?`: a block means Goodreads refused us, so no new books join until it clears.
  - `config.x.goodreads_rebuild.in_flight`, default `300`, overridable with ENV `GOODREADS_REBUILD_IN_FLIGHT`.
  - `config.x.goodreads.daily_fetch_cap` and `fetch_interval` read ENV `GOODREADS_DAILY_FETCH_CAP` and `GOODREADS_FETCH_INTERVAL`, falling back to 1,500 and 15. The initializer comment says the interval bounds the cap: 86,400 ÷ interval is the most a day can hold, 5,760 at 15 s.
  - The job's `perform` calls `QueueEnrichment.call(in_flight: config)`.
  - In `schedule.yml`: `goodreads_rebuild_enrichment`, cron `"*/10 * * * *"`.
  - Rake: `books:goodreads_rebuild:queue_enrichment` runs one top-up now.
  - `FixesReport` gains an enrichment section, so Shane can tell whether it's safe to raise the cap. It shows:
    - rebuild runs started, finished and failed;
    - Goodreads step outcomes (found, missed, failed), today and in total;
    - today's fetch count against the cap;
    - whether the gate is blocked, and until when.
- [ ] **Step 1: Write the failing tests**
  - "tops up to in_flight, most-listed applied fix first".
  - "starts nothing when already at in_flight".
  - "skips a book already enriched since its fix, and an unapplied fix".
  - "passes the fix's created author ids".
  - "starts nothing while the fetch gate is blocked".
  - "the fetch cap and interval read ENV, falling back to 1,500 and 15". Reload the initializer in the test with `load`, restoring the config after.
  - `fixes_report_test`: "reports the gate's daily count and a block".
- [ ] **Step 2: Run them.**
  - Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.**
  - Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Goodreads rebuild: continuous enrichment of fixed books, most-listed first; ENV fetch cap"`

### Task 8: Docs, launch steps and the full suite

**Files:**
- Modify: `docs/features/goodreads-rebuild.md`, `docs/launch-todo.md` §11 (step 5, "The fixes")

- [ ] **Step 1: Write the "Fixes (increment 2b)" section of `docs/features/goodreads-rebuild.md`.** It covers:
  - which books are fixed;
  - the blinded finder;
  - merge versus fix, and when each is automatic;
  - what a reset clears and keeps;
  - the rulings above;
  - the three rake tasks and the cron job.
- [ ] **Step 2: Fill in launch-todo §11 step 5, in production order:**
  1. `bin/rails "books:goodreads_rebuild:decide_fixes[200]"` then `fixes_report`, and hand-check the samples;
  2. `[all]` (it calls the AI on undecided books; about 47k books, on Sidekiq `low`);
  3. review and bulk-approve proposals in Admin → Repair verdicts (kind `fix_identity`, then `merge_books`);
  4. `bin/rails books:goodreads_replay:apply` then `books:goodreads_replay:repair_ratings`;
  5. from then on, the 10-minute job enriches nonstop at the Goodreads fetch cap;
  6. after a day or two, read `fixes_report`'s enrichment section. If nothing failed and the gate never blocked, raise `GOODREADS_DAILY_FETCH_CAP` in the production env (SOPS) and restart the worker. Above 5,760, lower `GOODREADS_FETCH_INTERVAL` too.

  Note that `apply` re-applies every pass, but a fix only once.
- [ ] **Step 3: Run the full suite and lint.**
  - Run: `bin/rails test` and `bundle exec standardrb`.
  - Expected: 0 failures and 0 errors, no new warning lines, and standardrb clean.
- [ ] **Step 4: Commit.** `git commit -m "Docs and launch steps for the Goodreads rebuild fixes"`
- [ ] **Step 5: Dev rehearsal. Ask Shane first.** It writes to the dev catalog. Snapshot with `bin/snapshot-dev-db.sh --label pre-rebuild-fixes`, run `decide_fixes[200]` with Sidekiq running, `fixes_report`, and hand-check 30 merges and 30 fixes against the export. Then `apply` on dev only after Shane agrees.
