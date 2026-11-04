# Books category and origin enrichment, stage 1 (evidence) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every book gets a stored, auditable evidence record (its Wikidata work, the Wikipedia article reached through it, and identity-checked WorldCat records). WorldCat category links become distinguishable and are limited to verified ISBNs.

**Architecture:** Three small source readers (Wikidata work resolution, Wikipedia article, WorldCat section) feed one `Gather` service. It writes one `enrichments` row of kind `books.evidence` per run. That row is what stages 2 and 3 (origin, categories) read. A new `evidence` step in `books.book_enrichment` (version 3) runs `Gather` on every import. Separately, `ApplyCategories` labels its links `worldcat`, and `worldcat:backfill` only ever reads verified ISBNs.

**Tech Stack:** Rails 8, Minitest + Mocha + WebMock, Sidekiq, the existing `Wikimedia::Http` / `Wikidata::Client` / `Wikipedia::Client` / `Books::WorldCat::Client`.

**Spec:** `docs/superpowers/specs/2026-11-02-books-category-origin-enrichment-design.md` (§4.2 dossier, §4.3 Wikidata work, §4.9 WorldCat backfill and workflow, §5 increment 1). Stages 2 (origin) and 3 (categories) get their own plans after this merges.

## Global Constraints

- Run Rails commands from `web-app/` inside the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-category-origin-enrichment`.
- Wikipedia is reached **only** through a confirmed Wikidata item's `enwiki` sitelink. Never call `Wikidata::Client#search` or any text search from this code.
- Every external call is stubbed in tests (WebMock for HTTP, Mocha for clients). Tests mirror the namespace (`module Services; module Books; module Evidence; class GatherTest`).
- Minitest 6: `assert_nil`, never `assert_equal nil, x`.
- No new warnings in `bin/rails test` output.
- `bundle exec standardrb` clean; `CI=1 bin/rails zeitwerk:check` clean.
- No migrations in this stage (enum values only). If one becomes necessary, run annotaterb with it; never set `ANNOTATERB_SKIP_ON_DB_TASKS`.
- Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Budgets (fixed here; the spec left them to the builder): Wikipedia lead ≤ 2,000 chars, plot ≤ 6,000 chars; WorldCat summary ≤ 1,500 chars, subjects top 40 by record count; at most 50 ISBN-13s per book looked up, at most 5 unverified ISBNs identity-checked, at most 3 extra full records fetched for text fields.
- The evidence row's `facts` carries `"schema_version" => 1`.

## Review Focus

1. **A book with no authors yet** (an import before `book_authors` exist): a Wikidata hit that lists authors (P50) cannot be confirmed and must be rejected (`author_mismatch`), not accepted. Pinned in Task 5.
2. **A Wikimedia rate limit partway through `Gather`** must not write a half-filled evidence row; the step waits and reruns. A **WorldCat outage** (circuit open, 5xx, timeout) must not fail the step: the row is written with `"worldcat"` in `sources_failed`. Pinned in Tasks 7 and 8.
3. **A QID already stored on another book** is stored on neither, flags the pair once, and re-running does not raise a second flag or store the QID. Pinned in Task 5.
4. **An ISBN with a bad check digit** among a book's ISBNs is dropped before `/lookup` (the service 422s the whole batch otherwise). Pinned in Task 6.
5. **A Wikipedia sitelink whose page is missing, a redirect, or a disambiguation page** yields no Wikipedia section and no error. Pinned in Task 4/7.

---

### Task 1: WorldCat links carry their own source

**Files:**
- Modify: `web-app/app/models/category_item.rb:31` (enum)
- Modify: `web-app/app/lib/services/books/world_cat/apply_categories.rb` (`link`)
- Test: `web-app/test/lib/services/books/world_cat/apply_categories_test.rb`, `web-app/test/models/category_item_test.rb`

**Interfaces:**
- Produces: `CategoryItem` source `worldcat` (value 4) with `source_worldcat?`. Stage 3 adds `ai` (value 5); do not add it here.

- [ ] **Step 1: Write the failing tests**

In `apply_categories_test.rb`:
```ruby
test "a new link is recorded as a worldcat link" do
  ApplyCategories.call(book: @book, records: [record(1, genre: "Romans")], map: @map)
  link = CategoryItem.joins(:category).find_by!(item: @book, categories: {name: "Fiction"})
  assert link.source_worldcat?
end

test "an existing link keeps its source" do
  fiction = ::Books::Category.active.genre.by_name("Fiction").first
  existing = CategoryItem.find_or_create_by!(category: fiction, item: @book) { |l| l.source = :admin }
  ApplyCategories.call(book: @book, records: [record(1, genre: "Romans")], map: @map)
  assert existing.reload.source_admin?
end
```
In `category_item_test.rb`: `assert_equal 4, CategoryItem.sources["worldcat"]`.

- [ ] **Step 2: Run them, expect failures** — `bin/rails test test/lib/services/books/world_cat/apply_categories_test.rb test/models/category_item_test.rb` → FAIL (`source_worldcat?` undefined).

- [ ] **Step 3: Implement.** Enum becomes `{legacy: 0, admin: 1, inherited: 2, goodreads: 3, worldcat: 4}`. `link` uses `find_or_create_by!(category:, item: @book) { |item| item.source = :worldcat }`. Grep the app for code that lists sources or treats "not admin/goodreads" as legacy (`grep -rn 'source_legacy?\|source: :legacy\|sources\[' app lib`) and confirm a `worldcat` link behaves like a `goodreads` link there (direct, not inherited). The book merger and `AncestorReconciler` copy or recompute sources and need no change; confirm by reading them.

- [ ] **Step 4: Run them, expect PASS**, plus `bin/rails test test/lib/categories test/lib/books/book/merger_test.rb`.

- [ ] **Step 5: Commit** — `git commit -m "WorldCat category links record source worldcat"`.

---

### Task 2: `worldcat:backfill` reads verified ISBNs only

**Files:**
- Modify: `web-app/app/lib/services/books/world_cat/backfill.rb` (`books_with_isbns` default scope)
- Modify: `web-app/lib/tasks/worldcat.rake` (`backfill` task arguments)
- Modify: `docs/launch-todo.md` (§9 step 15; section 4 step 7), `docs/todo.md` ("Books data quality" entry), `docs/features/worldcat-data-service.md` (lines ~324, ~367-410)
- Test: `web-app/test/lib/services/books/world_cat/backfill_test.rb`, `web-app/test/lib/tasks/worldcat_rake_test.rb`

**Interfaces:**
- Produces: `Backfill.call(limit:, run_id:, ..., scope: nil)`. When `scope` is nil it now uses `Identifier.verified` ISBN-13 rows. `Books::WorldCatBackfillJob#perform(limit, run_id)` is unchanged (nil limit = every verified book).

- [ ] **Step 1: Write the failing tests**

`backfill_test.rb`:
```ruby
test "a book whose only ISBN-13 is unverified is not looked up" do
  # one book with a verified (open_library) ISBN-13, one with only a legacy ISBN-13
  # assert the fake client's lookup received only the verified ISBN, and stats[:processed] == 1
end
```
`worldcat_rake_test.rb` (replace "backfill queues one run with a count or all"):
```ruby
test "backfill[verified] queues one run over every verified book" do
  Books::WorldCatBackfillJob.expects(:perform_async).with(nil, instance_of(String))
  assert_output(/queued WorldCat backfill run .*: every book with a verified ISBN-13/) { Rake::Task["worldcat:backfill"].invoke("verified") }
end

test "backfill[<count>] queues a limited run" do
  Books::WorldCatBackfillJob.expects(:perform_async).with(100, instance_of(String))
  assert_output(/: 100 books/) { Rake::Task["worldcat:backfill"].invoke("100") }
end

test "backfill[all] is refused and points at verified" do
  Books::WorldCatBackfillJob.expects(:perform_async).never
  err = assert_raises(SystemExit) { capture_io { Rake::Task["worldcat:backfill"].invoke("all") } }
  # abort message names worldcat:backfill[verified]
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** Default scope adds `.verified`. Rake usage becomes `worldcat:backfill[verified|<count>]`. `all` aborts with: `worldcat:backfill[all] is retired: unverified ISBNs can point at another book. Use worldcat:backfill[verified].` Update the job's header comment ("every book with a verified ISBN-13").

- [ ] **Step 4: Docs, same commit.**
  - launch-todo §9 step 15: `bin/rails "worldcat:backfill[verified]"`. It no longer waits on the ISBN cleanup; it needs this branch deployed.
  - launch-todo section 4 (the weekly post-sync list): step 7 becomes `worldcat:backfill[verified]` and moves **after** the `books:verify[all,recheck]` step. The sync's new books have no verified ISBNs until the recheck verifies them. Renumber.
  - `docs/todo.md`: remove the `worldcat:backfill[all]` bullet.
  - `worldcat-data-service.md`: the command, the verified-only rule and why, and that links are recorded as source `worldcat`.

- [ ] **Step 5: Run** `bin/rails test test/lib/services/books/world_cat test/lib/tasks/worldcat_rake_test.rb test/sidekiq/books` → PASS.

- [ ] **Step 6: Commit** — `"worldcat:backfill reads verified ISBNs only; [all] retired"`.

---

### Task 3: Wikidata work items and a work view

**Files:**
- Modify: `web-app/app/lib/wikidata/client.rb` (add `work_items`)
- Create: `web-app/app/lib/wikidata/work_distiller.rb`, `web-app/app/lib/wikidata/work.rb`
- Test: `web-app/test/lib/wikidata/client_test.rb`, `web-app/test/lib/wikidata/work_distiller_test.rb`, `web-app/test/lib/wikidata/work_test.rb`; fixtures under `test/fixtures/files/wikidata/` (a novel such as Q161531 *Lolita*, an edition item, a film)

**Interfaces:**
- Produces:
  - `Wikidata::Client#work_items(author_ids) -> Hash{String => Array<Hash{"id" => String, "label" => String}>}`: the same P50/P800 query and exclusions as `#works`, selecting `?work` as well as its English label, keyed by author QID. Same row limit and warning.
  - `Wikidata::WorkDistiller.call(entity) -> Hash` with keys `id label description instance_of authors edition_of countries languages genres main_subjects narrative_locations set_in_periods forms publication_years identifiers enwiki_title`. Item-valued keys are QID arrays (best rank only, via `Wikidata::Distiller.item_ids`). `publication_years` is an array of integers from P577 at year precision or finer. `identifiers` is `{"goodreads_book" => P2969, "openlibrary" => P648, "oclc" => P243}`. Properties: P31, P50, P629, P495, P407, P136, P921, P840, P2408, P7937, P577.
  - `Wikidata::Work.from_payload(hash)`, with readers for each key and `written_work? -> Boolean`, `edition? -> Boolean`.
  - `Wikidata::Work::WRITTEN_WORK_TYPES`: Q7725634 literary work, Q47461344 written work, Q571 book, Q8261 novel, Q5185279 poem, Q25379 play, Q35760 essay, Q49084 short story, Q1279564 short story collection, Q12106333 poetry collection, Q725377 graphic novel, Q8274 manga, Q1004 comics, Q7725310 series of creative works. `EDITION_TYPE = "Q3331189"`. `written_work?` is true when `instance_of` or `forms` intersects the list. `edition?` is true when `instance_of` includes `EDITION_TYPE`.

- [ ] **Step 1: Failing tests.**
  - `work_items` sends one SPARQL request and returns `{"Q42" => [{"id" => "Q25169", "label" => "The Hitchhiker's Guide to the Galaxy"}]}` from a stubbed bindings body. Empty input makes no request and returns `{}`.
  - The distiller on the novel fixture: `countries` includes the P495 QID; `languages` the P407 QID; `enwiki_title` the sitelink; deprecated statements are absent.
  - `Work#written_work?` is true for the novel and false for a film (`instance_of: ["Q11424"]`). `edition?` is true for the edition fixture, and `edition_of` holds its P629 work.

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** to the interfaces above. Reuse `Wikidata::Distiller`'s module functions (`item_ids`, `values`, `times`, `name`, `english`); do not copy them.
- [ ] **Step 4: Run** `bin/rails test test/lib/wikidata` → PASS.
- [ ] **Step 5: Commit** — `"Wikidata: work items by author and a work distiller"`.

---

### Task 4: Wikipedia article (lead, infobox, plot)

**Files:**
- Modify: `web-app/app/lib/wikipedia/client.rb` (add `article`)
- Create: `web-app/app/lib/wikipedia/article.rb`, `web-app/app/lib/wikipedia/infobox.rb`
- Modify: `docs/features/wikimedia-clients.md` (the new method, and why it exists: book evidence)
- Test: `web-app/test/lib/wikipedia/client_test.rb`, `web-app/test/lib/wikipedia/infobox_test.rb`; fixtures `test/fixtures/files/wikipedia/article_*.json`

**Interfaces:**
- Produces:
  - `Wikipedia::Article = Data.define(:title, :url, :page_id, :lead, :plot, :infobox)`. `infobox` is a Hash of String keys.
  - `Wikipedia::Client#article(language:, title:) -> Wikipedia::Article | nil`. nil when the page is missing, invalid, or a disambiguation page. Same argument validation as `#lead`.
  - `Wikipedia::Infobox.fields(wikitext) -> Hash{String => String}` with keys from `country language genre subject set_in` (only those present). Parameter names are matched case-insensitively, with `_` and space equivalent (`set in`, `set_in`).
- Requests (two, through the same `Wikimedia::Http`):
  1. `action=query prop=extracts|pageprops|info inprop=url explaintext=1 exsectionformat=wiki redirects=1 titles=<title>` (the full article as plain text, headings as `== Plot ==`).
  2. `action=parse page=<resolved title> prop=wikitext section=0 redirects=1` (the infobox lives in section 0).
- Lead = text before the first heading, ≤ 2,000 chars. Plot = the text under the first heading at any level whose name matches `/\A(plot|plot summary|synopsis|summary|story|content|contents|overview)\z/i`, up to the next heading of the same or higher level, ≤ 6,000 chars; nil when there is none.
- Infobox value cleanup, in order: drop `<ref …>…</ref>` and `<ref …/>`; `[[a|b]]` → `b`, `[[a]]` → `a`; `<br>` variants → `, `; `{{plainlist|…}}` / `{{ubl|…}}` / `{{hlist|…}}` → their `*`/`|` items joined by `, `; any other `{{…}}` removed; collapse whitespace. Nested templates in an infobox value are rare; the parser only has to find the top-level `{{Infobox …}}` block by brace counting.

- [ ] **Step 1: Failing tests.**
  - `Infobox.fields` on a *Lolita*-style snippet (`| country = United States`, `| language = English`, `| genre = [[Novel]]<ref>x</ref>`, `| set_in = {{plainlist|* [[New England]]\n* [[Ramsdale]]}}`) returns `{"country" => "United States", "language" => "English", "genre" => "Novel", "set_in" => "New England, Ramsdale"}`.
  - `article` returns lead, plot and infobox from two stubbed responses. A missing page returns nil and makes no parse request. A disambiguation page returns nil. A redirect uses the resolved title for the parse request.
  - The plot budget truncates at 6,000 chars.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bin/rails test test/lib/wikipedia` → PASS.
- [ ] **Step 5: Commit** — `"Wikipedia: article lead, plot and infobox fields"`.

---

### Task 5: Resolve a book's Wikidata work

**Files:**
- Create: `web-app/app/lib/services/books/evidence/resolve_wikidata_work.rb`
- Test: `web-app/test/lib/services/books/evidence/resolve_wikidata_work_test.rb`

**Interfaces:**
- Consumes: `Wikidata::Client#entities`, `#by_statements`, `#work_items`, `#labels`; `Wikidata::WorkDistiller`, `Wikidata::Work` (Task 3); `Services::Books::Verification::Check.titles_agree?` / `.authors_agree?` with `Services::Books::Verification::WorldCatCheck::WorkLike`; `Services::DuplicateCandidates::Flag`.
- Produces: `Services::Books::Evidence::ResolveWikidataWork.call(book:, client: ::Wikidata::Client.new) -> Result` with `data: {qid: String|nil, via: "stored"|"statements"|"author_works"|nil, work: Wikidata::Work|nil, conflict_book_id: Integer|nil, rejected: Array<Hash{"id","reason"}>}`. Reasons: `not_written_work`, `author_mismatch`, `ambiguous_edition`, `ambiguous_statements`, `ambiguous_title`. Never raises except `Wikimedia::Exceptions::RateLimited` (and network errors, which `Gather` catches).

Order (spec §4.3; ISBN statements are **dropped** from this stage because Wikidata stores P212 hyphenated and `haswbstatement` needs the exact string; record this deviation in the spec's §4.3 in this task's commit):
1. Stored `books_work_wikidata_qid`: fetch it. If the entity comes back under a different id (a merge), the surviving id is the candidate. If it's missing, continue to 2.
2. `by_statements` with every pair the book holds: `["P2969", goodreads_id]`, `["P648", ol_work_id]`, `["P243", oclc]` (from `books_work_goodreads_id`, `books_work_openlibrary_id`, `books_work_oclc_id`).
3. `work_items` for the QIDs of the book's authors (`books_author_wikidata_qid`), keeping items whose label `titles_agree?` with the book (title or alternate titles).

Accepting a candidate: fetch and distill it. An edition with exactly one `edition_of` is replaced by that work (one hop); with several, it is rejected (`ambiguous_edition`). It must be `written_work?`. If it lists authors, either one of them is among the book's author QIDs, or their labels (via `#labels`) pass `Check.authors_agree?`. A book with no authors fails a work that lists authors. Within a strategy, more than one distinct accepted QID means none (`ambiguous_statements` / `ambiguous_title`), and resolution falls through to the next strategy.

Storing: if another `Books::Book` holds the QID (any source), call `Flag.call(item_type: "Books::Book", ids: [book.id, other_id], source: :identifier_collision, evidence: {"wikidata_qid" => qid, "via" => via})`, store nothing, and return `qid: nil, work: nil, conflict_book_id: other_id`. Otherwise write or replace the book's `books_work_wikidata_qid` row with source `:wikidata`. A stored QID that still resolves to itself is not rewritten.

- [ ] **Step 1: Failing tests** (stub the client with Mocha; build `Wikidata::Work` payloads inline):
  - stored QID is used without `by_statements` being called.
  - a Goodreads-id statement hit on a novel by our author (P50 = the author's stored QID) is accepted, stored with source `wikidata`, `via == "statements"`.
  - an edition hit with one P629 resolves to the work's QID.
  - a film hit is rejected `not_written_work`; with no other hit, `qid` is nil.
  - author-works match on the title stores the QID with `via == "author_works"`; two distinct works with the same title → nil with `ambiguous_title`.
  - **(Review Focus 1)** a book with no `book_authors` and a hit that lists authors → rejected `author_mismatch`.
  - **(Review Focus 3)** a QID held by another book → nothing stored on either, one `DuplicateCandidate` pending for the pair; calling again stores nothing and still leaves exactly one candidate row.
  - a stored QID that now answers under a new id is replaced by the new id.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file → PASS.
- [ ] **Step 5: Commit** — `"Evidence: resolve a book's Wikidata work by id, never by search"`.

---

### Task 6: WorldCat section with an identity check

**Files:**
- Create: `web-app/app/lib/services/books/evidence/world_cat_section.rb`
- Test: `web-app/test/lib/services/books/evidence/world_cat_section_test.rb`

**Interfaces:**
- Consumes: `Books::WorldCat::Client#lookup`, `#record_by_oclc`; `Books::WorldCat::GenreMap.load#targets_for`; `Services::Books::Verification::WorldCatCheck.agrees?(book, record)`; `Books::Isbn.normalize`.
- Produces: `Services::Books::Evidence::WorldCatSection.call(book:, client: ::Books::WorldCat::Client.new, map: ::Books::WorldCat::GenreMap.load) -> Hash | nil`. nil when no record is accepted. Keys:
  `"records"` (Integer), `"isbns_accepted"`, `"isbns_rejected"` (Arrays of ISBN-13), `"genre_terms"` (`{term => count}`), `"mapped_genres"` (`{"<kind>:<name>" => count}` from the map's targets), `"subjects"` (top 40 `{heading => count}`, full LCSH strings), `"summary"` (String|nil, ≤ 1,500 chars), `"publication_places"` (Array), `"earliest_year"` (Integer|nil), `"cataloging_languages"` (`{code => count}`).
  Lets `Books::WorldCat::Exceptions::Error` propagate (`Gather` records it).

Algorithm:
1. ISBN-13s from `books_work_isbn13` and `books_work_isbn10` identifiers, normalised with `Books::Isbn.normalize(...)&.isbn13`, invalid dropped, verified ones first, unique, first 50.
2. `client.lookup(isbns)`.
3. Every verified ISBN with records is accepted. Unverified ISBNs with records, at most 5 (most records first): fetch the first record's full form with `record_by_oclc`. The ISBN is accepted when `WorldCatCheck.agrees?(book, full_record)`, otherwise rejected. A `ServerError` with status 504 on that fetch rejects the ISBN (same handling as `ConfirmWithWorldCat#lookup`).
4. Records = the accepted ISBNs' lookup records, unique by `oclc`, minus merged duplicates (same rule as `ApplyCategories#without_merged_duplicates`; extract that into a shared helper rather than copying it).
5. Text fields come from the full records already fetched in step 3. If fewer than 3 were fetched, fetch up to 3 more accepted records by `oclc`. `summary` = the longest summary among full records whose `cataloging_language` is `eng` or nil. `publication_places` = their unique places.

- [ ] **Step 1: Failing tests** (fake client object as in `backfill_test.rb`):
  - a verified ISBN's records are accepted without any `record_by_oclc` call for identity (only for text fields).
  - an unverified ISBN whose full record has another title and creator is rejected, and its genres do not appear.
  - an unverified ISBN whose full record agrees is accepted.
  - **(Review Focus 4)** an ISBN with a bad check digit is never sent to `lookup`.
  - `subjects` keeps the full subdivided heading ("World War, 1939-1945 -- France -- Paris -- Fiction") and is capped at 40.
  - no records → nil.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file and `test/lib/services/books/world_cat` → PASS.
- [ ] **Step 5: Commit** — `"Evidence: WorldCat section with a title/author identity check"`.

---

### Task 7: Gather evidence into one ledger row

**Files:**
- Create: `web-app/app/lib/services/books/evidence/gather.rb`
- Test: `web-app/test/lib/services/books/evidence/gather_test.rb`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces: `Services::Books::Evidence::Gather.call(book:, wikidata: ::Wikidata::Client.new, wikipedia: ::Wikipedia::Client.new, worldcat: ::Books::WorldCat::Client.new) -> Result` with `data: {enrichment: Enrichment}`. It writes one `book.enrichments` row: `kind: "books.evidence"`, `outcome: :applied` when any section is non-nil (else `:nothing_to_apply`), and `facts`:
  ```
  {"schema_version" => 1,
   "wikidata"  => nil | {"qid","via","label","description","countries","languages","genres","main_subjects",
                          "narrative_locations","set_in_periods","forms","publication_years","enwiki_title"},
   "wikipedia" => nil | {"title","url","lead","plot","infobox"},
   "worldcat"  => nil | <WorldCatSection hash>,
   "wikidata_rejected" => [...], "wikidata_conflict_book_id" => nil | Integer,
   "sources_failed" => ["wikidata"|"wikipedia"|"worldcat", ...]}
  ```
  In the wikidata section, every item-valued list holds English labels (one `#labels` call for all ids), not QIDs, except `qid` itself. Stage 2 reads countries and languages by label.
- `Wikimedia::Exceptions::RateLimited` propagates **before any row is written**: compute every section first, then write the row. Any other `Wikimedia::Exceptions::Error`, or a `Books::WorldCat::Exceptions::Error`, marks that source failed and the run continues. Wikipedia is skipped (not failed) when there is no `enwiki_title`.

- [ ] **Step 1: Failing tests** (stub the three section producers with Mocha):
  - a full hit writes one row with all three sections, `outcome: applied`, `schema_version` 1, and country labels such as `["United States"]`.
  - nothing found → `nothing_to_apply`, all sections nil.
  - **(Review Focus 2)** `ResolveWikidataWork` raising `RateLimited` → raises, and `book.enrichments.for_kind("books.evidence").count` is unchanged. `WorldCatSection` raising `CircuitOpenError` → a row is written with `"worldcat"` in `sources_failed` and the Wikidata/Wikipedia sections filled.
  - **(Review Focus 5)** `Wikipedia::Client#article` returning nil → `"wikipedia" => nil`, not a failure.
  - when called inside a workflow step (`Current.workflow_step_id` set), the row links to the step.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/evidence` → PASS.
- [ ] **Step 5: Commit** — `"Evidence: gather Wikidata, Wikipedia and WorldCat into a books.evidence row"`.

---

### Task 8: The `evidence` workflow step and a dev rake

**Files:**
- Create: `web-app/app/lib/workflows/books/steps/evidence.rb`
- Modify: `web-app/app/lib/workflows/books/book_enrichment.rb` (version 3, `add_step :evidence`, header comment)
- Modify: `web-app/lib/tasks/books/enrich.rake` (add `books:evidence[book_id]`)
- Modify: `docs/features/enrichment-workflows.md`, `docs/features/books_enrichment.md` (the step, its ledger row, what stages 2–3 will read)
- Test: `web-app/test/lib/workflows/books/steps/evidence_test.rb`, `web-app/test/lib/workflows/books/book_enrichment_test.rb`, `web-app/test/lib/tasks/books_enrich_rake_test.rb`

**Interfaces:**
- Consumes: `Gather.call(book:)` (Task 7).
- Produces: step key `evidence` on `books.book_enrichment` v3: `queue: :low, lease: 10.minutes, waits_on: {goodreads: :finish}`. Nothing waits on it in this stage; stage 2's `categorize` will. The adapter returns `Outcome.succeeded(enrichment.outcome, {"enrichment_id" => id, "qid" => qid_or_nil})`. A `RateLimited` becomes `Outcome.wait(Time.current + e.retry_after.to_i + rand(0..30))`, the same as `Steps::Wikidata`.
- `books:evidence[book_id]` runs `Gather` inline for one book (dev inspection only; it is one book, so not a long-running job) and prints the QID, via, which sections are present, and `sources_failed`.

- [ ] **Step 1: Failing tests.**
  - adapter: succeeded outcome carries the enrichment id; `RateLimited` → `:wait` with a future `run_after` and no row.
  - workflow: a new book run plans `goodreads`, `evidence`, `book_facts`, `amazon`; `evidence` is ready once `goodreads` finishes, whether goodreads succeeded or was skipped (`no_authors`). A run planned under version 2 (no `evidence` step) still completes. Follow the existing version-1 test pattern in `book_enrichment_test.rb`.
  - rake: prints the QID line for a stubbed `Gather` result.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**, and update the docs.
- [ ] **Step 4: Run** `bin/rails test test/lib/workflows test/lib/tasks` → PASS.
- [ ] **Step 5: Commit** — `"books.book_enrichment v3: evidence step"`.

---

### Task 9: Full checks and a dev measurement

No code unless something below fails.

- [ ] **Step 1:** `bin/rails test` → 0 failures, 0 errors, no new warning lines. `bundle exec standardrb` → clean. `CI=1 bin/rails zeitwerk:check` → "All is good!".
- [ ] **Step 2: Dev measurement** (the dev database is shared and not disposable; this only adds `books_work_wikidata_qid` identifiers and `books.evidence` rows, so no snapshot is required). The local WorldCat container must be up (`curl -s localhost:8082/version`). Pick 20 ranked books (primary config 8: 10 from the top 200, 10 from ranks 5,000–15,000) and 20 unranked books, including at least 5 non-English-origin titles. Run `bin/rails "books:evidence[<id>]"` for each, from a small loop script in the session scratchpad.
- [ ] **Step 3: Report to the owner** (in the PR description, not a doc): Wikidata work found (by `via`), Wikipedia article found, infobox fields present, plot found, WorldCat records accepted vs ISBNs rejected, ranked vs unranked, and median wall time per book. Flag any wrong QID found by hand-checking 10 of them. These numbers feed stage 2's plan.
- [ ] **Step 4:** Ask the owner before pushing or opening a PR.

---

## Self-review notes

- Spec §4.3 step 3 (ISBN → edition → work) is deliberately dropped in Task 5 (hyphenated P212 values); Task 5's commit records the deviation in the spec.
- Spec §4.2 "Our record", Goodreads and Open Library sections are read live by stage 2's dossier builder and are not stored here; the evidence row holds only the external, slow-to-fetch sections.
- The `/lookup` route returns no title, creator, summary or place (`LookupRecord`), which is why Task 6 fetches a bounded number of full records by OCLC number.
- `ai` source, prompt versions, the judges, the backfill, the admin action and the `categorize` step belong to stages 2–3.
