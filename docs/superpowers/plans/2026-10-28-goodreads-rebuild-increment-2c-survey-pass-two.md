# Goodreads Rebuild Increment 2c: Survey Pass 2 (local evidence) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Look up every derived book's Goodreads editions by ISBN in WorldCat and Open Library, store what they say, copy that table from dev to production, and re-run the survey with it so lumps use the Open Library work merge.

**Architecture:**
- **Results table:** `books_rebuild_edition_evidences`, one row per Goodreads edition, keyed by the edition's natural key `(goodreads_book_id, signature)`, which is the same in dev and production.
- **Gathering:** `GatherEvidence` checks one edition. `EvidenceRun` works through the derived books' editions with no evidence, using N threads, each with its own clients.
- **Where it runs:** on Shane's PC in dev, against a local Open Library and WorldCat instance (spec §4.2). The shared home-server services stay with production.
- **Moving the results:** `EvidenceTransfer` exports the table to a gzipped JSON-lines file and imports it in production.
- **Using them:** `SurveyBook` passes the evidence to `GroupEditions`, whose Open Library merge step exists already but has been idle. The report adds WorldCat agreement counts.

**Tech Stack:** Rails 8, PostgreSQL, Ruby threads, Minitest + Mocha, standardrb. The Python services run unchanged, started locally with uvicorn.

**Spec:** `docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md`, §4.2 (pass 2 runs locally and is copied to production), §7 (evidence services) and §12 call 4 (WorldCat alone never auto-merges).

## Global Constraints

- **Read-only for the catalog.** Write only `books_rebuild_edition_evidences`, plus the existing `books_rebuild_book_surveys` on a re-survey.
- **The services:** only `Books::WorldCat::Client#record_by_isbn(isbn13)` and `Books::OpenLibrary::Client#identifier("isbn13", isbn13)`. Never `/resolve`, and never the batch routes.
- **The local services must serve the home server's versions:** Open Library `2026-09-30`, WorldCat `2025-09-04`. The Rails clients are pointed at them by env only, `OPEN_LIBRARY_SERVICE_URL` and `WORLDCAT_SERVICE_URL`, for the run's process. No code default changes.
- **Never run the evidence run against the home-server services:**
  - `EvidenceRun` refuses to start unless both base URLs are `http://localhost` or `http://127.0.0.1`, or `force: true` is passed;
  - the rake task never passes `force`.
- **Agreement rule:** a WorldCat record agrees when `Check.titles_agree?(edition_like, work)` and `Check.authors_agree?(edition_like, work)` both hold, with `work = WorldCatCheck.work_like(record)`.
  - It disagrees when neither holds. Anything else is `unclear`.
  - Several records: `agrees` if any agrees, else `disagrees` if any disagrees, else `unclear`.
  - (`Check` and `WorldCatCheck` are in `Services::Books::Verification`.)
- **ISBNs:** `Books::Isbn.normalize(edition.isbn13)`, falling back to `normalize(edition.isbn10)`, and use `.isbn13`. No valid ISBN means `no_isbn`, with no calls.
- **Errors:** an `::Books::OpenLibrary::Exceptions::Error` or `::Books::WorldCat::Exceptions::Error` stops that thread and the run reports `stopped`. Rows already written stay, and a re-run skips them.
- **Code conventions:**
  - Services in `app/lib/services/books/goodreads_rebuild/` return the `Result` struct.
  - Migrations come from generators, and annotaterb runs.
  - Strip foreign tables from `schema.rb`.
  - `bundle exec standardrb`, and a green `bin/rails test`.

## Review Focus

1. **The run is pointed at the home-server services by mistake.** It refuses before any lookup. Test in Task 3.
2. **Two threads take the same edition.** The unique index on the natural key holds, and the second write is an upsert, not an error. Test in Task 3.
3. **An import in production when a few editions are missing there** (dev and production loaded the same 803 imports, but a later weekly load adds more). Rows for editions production lacks are kept, keyed only by the natural key, and counted as `no_edition_here`. Rows production already has are updated. Test in Task 4.
4. **A re-survey with evidence.** Two editions on one Open Library work merge, and a lump becomes coherent. Test in Task 5.
5. **Bad ISBNs from legacy rows** (a checksum fails, or text like "Twelfth Night"). These give `no_isbn` with no call, never a 422 from a service. Test in Task 2.

---

### Task 1: The evidence table

**Files:** Create (generator) `web-app/app/models/books/rebuild_edition_evidence.rb`, its migration, test and fixture.

**Interfaces:**
- Produces `Books::RebuildEditionEvidence` (table `books_rebuild_edition_evidences`):
  - `goodreads_book_id` (bigint, not null);
  - `signature` (string, not null), with a unique index on `[goodreads_book_id, signature]`;
  - `isbn13` (string);
  - `world_cat` (integer, not null; enum `no_isbn: 0, no_record: 1, agrees: 2, disagrees: 3, unclear: 4`);
  - `world_cat_title`, `world_cat_creator` (string);
  - `world_cat_year` (integer);
  - `ol_work_keys` (string array, not null, default `[]`);
  - `checked_at` (datetime, not null).
  - No foreign key: production may hold rows for editions it doesn't have yet.
  - `Books::RebuildEditionEvidence.for_editions(editions) -> Hash{edition_id => evidence}` matches on the natural key.

- [ ] **Step 1: Generate.** `bin/rails generate model books/rebuild_edition_evidence goodreads_book_id:bigint signature:string isbn13:string world_cat:integer world_cat_title:string world_cat_creator:string world_cat_year:integer ol_work_keys:string checked_at:datetime`. Then edit the migration: nulls, `array: true, default: []`, and the unique index.
- [ ] **Step 2: Write the failing tests.**
  - `test "the natural key is unique"`
  - `test "world_cat enum"`
  - `test "for_editions matches on goodreads id and signature"`: two editions, evidence for one → a Hash with that edition's id only.
- [ ] **Step 3: Run them to see them fail. Then migrate, strip foreign tables from `schema.rb`, and load the test schema.**
- [ ] **Step 4: Implement the model.** Its class comment says why it has no foreign key: it's copied from dev to production by natural key.
- [ ] **Step 5: Run them to see them pass, then commit.** Message: "Goodreads rebuild: edition evidence table keyed by Goodreads id and signature".

### Task 2: `EditionLike` and `GatherEvidence`

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/edition_like.rb` and `gather_evidence.rb`. Test `gather_evidence_test.rb`.

**Interfaces:**
- Produces `EditionLike.from(edition) -> Data(title:, alternate_titles: [], authors:, first_published_year:)`. `authors` holds `Data(name:, alternate_names: [], id: nil)` for `primary_author` and each of `additional_authors`.
- Produces `GatherEvidence.call(edition:, world_cat:, open_library:) -> Books::RebuildEditionEvidence`. It upserts by natural key.
  - Look up WorldCat first, then Open Library, then write, so a raised error writes nothing.
  - `world_cat_title`, `world_cat_creator` and `world_cat_year` come from the first agreeing record, else the first record.

- [ ] **Step 1: Write the failing tests.** Stub `world_cat.stubs(:record_by_isbn)` and `open_library.stubs(:identifier)`, using `Books::WorldCat::Record.from_hash` and `Books::OpenLibrary::IdentifierHit.new(...)`.
  - `test "an agreeing record and an Open Library work"`:
    - Edition: "The Remains of the Day", Kazuo Ishiguro, `isbn13: "9780679731726"`.
    - Record: title "The remains of the day /", creator "Ishiguro, Kazuo".
    - OL hit: `work_key: "OL15936W"`.
    - Expect `agrees`, `["OL15936W"]`, with the title and creator stored.
  - `test "a record for another book disagrees"`: "Cooking for one /" by "Smith, Jane".
  - `test "no record"`: `[]` → `no_record`.
  - `test "no ISBN, a bad checksum or text makes no call"`: ISBNs nil, `"9780679731727"` and `"Twelfth Night"` → `no_isbn`, with `.never` on both stubs.
  - `test "ISBN-10 only is looked up as ISBN-13"`: `isbn10: "0679731725"` → called with `"9780679731726"`.
  - `test "a service error writes nothing"`
  - `test "a second call updates the row"`
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass, then commit.** Message: "Goodreads rebuild: GatherEvidence checks an edition's ISBN against WorldCat and Open Library".

### Task 3: `EvidenceRun` and its rake task

**Files:**
- Create `web-app/app/lib/services/books/goodreads_rebuild/evidence_run.rb`.
- Modify `web-app/lib/tasks/books/goodreads_rebuild.rake`.
- Tests: `evidence_run_test.rb` and the rake test.

**Interfaces:**
- Produces `EvidenceRun.call(threads: 4, limit: nil, force: false) -> Result`, with `data` = `{looked_up: Integer, stopped: Boolean, error: String|nil}`.
  - **Editions:** those of rows whose `legacy_book_id` is in `LegacyBookMap.build.all_legacy_ids_for(Cohort.derived.ids)` and that have no evidence row, ordered by id, with `limit` editions at most.
  - **Threads:** a queue of edition ids, and `threads` threads. Each thread wraps its work in `ActiveRecord::Base.connection_pool.with_connection` and builds its own `Books::WorldCat::Client.new` and `Books::OpenLibrary::Client.new`.
  - **Errors:** the first service error sets `stopped` and drains the queue.
  - **Progress:** logged every 1,000 lookups.
  - **Guard:** before anything, refuse with `error: "point OPEN_LIBRARY_SERVICE_URL and WORLDCAT_SERVICE_URL at local instances"` unless both client configs' `base_url` hosts are `localhost` or `127.0.0.1`, or `force:` is true.
- Rake: `books:goodreads_rebuild:gather_evidence[threads]` (default 4) prints the result. It runs in the foreground, with no Sidekiq.

- [ ] **Step 1: Write the failing tests.**
  - `test "refuses when a service is not local"`: base URLs come from the configs. Stub `Books::OpenLibrary::Configuration.new` to return one with `base_url: "https://ol-api.example.org"`, or pass `force: false` and stub ENV with `ClimateControl`-free `ENV.stubs(:fetch)`, whichever the configs read. Expect `stopped`, the error message, and no lookups.
  - `test "gathers evidence for derived editions without it"`: stub `GatherEvidence.call` to record the editions it saw, with `threads: 2`. Expect every derived edition once, and none already holding evidence.
  - `test "two threads on one edition upsert"`: call `GatherEvidence` twice for one edition with stubbed clients → one row.
  - `test "a service error stops the run"`
  - Rake test: `test "gather_evidence passes the thread count"`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass, then commit.** Message: "Goodreads rebuild: threaded evidence run, local services only".

### Task 4: `EvidenceTransfer` export and import

**Files:**
- Create `web-app/app/lib/services/books/goodreads_rebuild/evidence_transfer.rb`.
- Modify the rake file.
- Test `evidence_transfer_test.rb` and the rake test.

**Interfaces:**
- Produces `EvidenceTransfer.export(path) -> Integer`, the rows written. It writes gzip JSON lines, one object per row, with every column except `id`, `created_at` and `updated_at`.
- Produces `EvidenceTransfer.import(path) -> Hash{"imported" => Integer, "no_edition_here" => Integer}`.
  - It upserts in slices of 1,000 with `upsert_all(unique_by: [:goodreads_book_id, :signature])`.
  - `no_edition_here` counts rows whose natural key matches no `Books::GoodreadsEdition` in this database. Those rows are still imported.
- Rake tasks:
  - `books:goodreads_rebuild:export_evidence[path]` (default `tmp/rebuild_edition_evidence.jsonl.gz`);
  - `books:goodreads_rebuild:import_evidence[path]`.

- [ ] **Step 1: Write the failing tests.**
  - `test "export then import round-trips"`: two rows, export to a tmp path, delete them, import → identical attributes.
  - `test "import updates an existing row"`
  - `test "import counts rows for editions this database lacks"`
  - Rake tests for both tasks.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement**, with `Zlib::GzipWriter` and `GzipReader`.
- [ ] **Step 4: Run them to see them pass, then commit.** Message: "Goodreads rebuild: export and import edition evidence between dev and production".

### Task 5: The survey uses the evidence

**Files:**
- Modify `web-app/app/lib/services/books/goodreads_rebuild/survey_book.rb` and `survey.rb` (preload evidence per batch), plus `survey_report.rb`.
- Tests: `survey_book_test.rb` and `survey_report_test.rb`.

**Interfaces:**
- Consumes `RebuildEditionEvidence.for_editions` (Task 1) and `GroupEditions.call(..., evidence:)`, which exists already.
- `SurveyBook.call(book:, rows:, evidence: nil)`. When `evidence` is nil, it loads `RebuildEditionEvidence.for_editions(editions)` itself. `Survey` passes a batch-loaded Hash.
- The report gains:
  - a line `editions with evidence: N of M; WorldCat agrees A, disagrees D, unclear U, no record R, no ISBN I; with an Open Library work W`;
  - a lump count line that says whether evidence was used for every surveyed book.

- [ ] **Step 1: Write the failing tests.**
  - `test "a shared Open Library work makes a transliterated pair coherent"`: "Leo Tolstoy" and "Lev Tolstoy" editions, 1869, evidence rows with the same work key → `coherent`. Without evidence → `lump`.
  - `test "report shows evidence counts"`
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass, then commit.** Message: "Goodreads rebuild: the survey groups with Open Library evidence; report shows WorldCat agreement".

### Task 6: Docs, launch steps and the local run

**Files:** Modify `docs/features/goodreads-rebuild.md` (a "Survey pass 2" section with the local-run recipe) and `docs/launch-todo.md` §11.

- [ ] **Step 1: The recipe in the feature doc.** Everything runs from `data-sources/`.
  1. **Copy the data.** Copy the Open Library `2026-09-30` version from the `ol` VM (`/srv/ol-data/versions/2026-09-30`) to `/home/shane/ol-data/versions/2026-09-30` with `rsync`. That's about 14 GB.
  2. **Start Open Library.** `OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-09-30 OL_API_MEMORY_LIMIT=8GB uv run uvicorn --factory openlibrary.api.main:factory --port 8101 --workers 4`
  3. **Start WorldCat.** `WC_DATA_ROOT=/home/shane/wc-data WC_DATA_VERSION=2025-09-04 uv run uvicorn --factory worldcat.api.main:factory --port 8102 --workers 4`
  4. **Run the lookups** from `web-app/`: `OPEN_LIBRARY_SERVICE_URL=http://localhost:8101 WORLDCAT_SERVICE_URL=http://localhost:8102 bin/rails "books:goodreads_rebuild:gather_evidence[8]"`
  5. **Export** with `bin/rails books:goodreads_rebuild:export_evidence`, and copy the file to production.
  6. **Import in production** with `bin/rails "books:goodreads_rebuild:import_evidence[<path>]"`.
  7. **Re-survey and report:** `bin/rails "books:goodreads_rebuild:survey[all,redo]"`, then `survey_report`.

  The Cloudflare Access headers are only sent when configured, and local URLs don't need them. Check `Books::OpenLibrary::Configuration#access`. If it raises for http, note the env needed.
- [ ] **Step 2: The launch-todo step, in plain words.** Production only needs steps 6 and 7. Steps 1–5 are done on Shane's PC.
- [ ] **Step 3: The local run, with Shane's go-ahead to copy 14 GB from the `ol` VM.** Start both services, run `gather_evidence[8]` over all derived editions, then the dev re-survey and report. Record the runtime and counts for the PR. If the uvicorn command or env differs from the recipe, fix the recipe.
- [ ] **Step 4: Verify.** `bin/rails test` and `bundle exec standardrb`. Commit with the message "Docs: Goodreads rebuild survey pass 2".
