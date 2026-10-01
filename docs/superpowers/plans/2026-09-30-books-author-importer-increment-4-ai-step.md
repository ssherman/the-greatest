# Books Author Importer — Increment 4 (AI step and book hand-off) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every author the chain reaches gets an AI step that writes a house-style description and fills the facts the authority steps left blank. A book whose import created its author waits for that step and is handed on to book enrichment when it finishes. The race that let a new author's Wikidata step run before its book was saved is closed.

**Architecture:**
- **The AI step.** `Services::Ai::Tasks::Books::AuthorFactsTask` asks for facts and a description in one call. Its input is what we hold plus the records the author steps matched, which `MatchedRecords` reads from the ledger.
- **Checks and apply.** `DescriptionCheck` gains a copy check against the Wikipedia lead. `AuthorDescriptionReviewTask` reviews the draft and rewrites it once. `ApplyAuthorFacts` fills blanks through the shared `FactSheet`.
- **Runner and job.** `EnrichAuthor` runs knowledge, then research, and writes one `books.author_facts` row per run. `Books::Authors::EnrichJob` runs it, then hands on the books that were waiting for this author.
- **The chain.** `WikidataJob` and `ViafJob` now end in `EnrichJob`.
- **The book importer.** It runs the author importer without that importer's async provider and starts the chain itself, once the book and its `book_authors` rows are saved. It records that a book's enrichment is waiting for its new authors instead of enqueueing it at once.

**Tech Stack:** Rails 8, PostgreSQL (jsonb), Sidekiq, OpenAI via `Services::Ai::Tasks` (model roles in `config/initializers/ai.rb`), Minitest + Mocha.

**Spec:** `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`. This plan implements §9, §10, the `EnrichJob` rows of §11, the AI and chain parts of §15, and §16 item 4. Increment 3's plan is `docs/superpowers/plans/2026-09-28-books-author-importer-increment-3-viaf.md`. The book enrichment this hands off to is `docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md` / `docs/features/books_enrichment.md`.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in the repository root's `docs/`.
- Tests: `bin/rails test`. Lint: `bundle exec standardrb` (never `bin/rubocop`). Never run brakeman.
- Use generators. For jobs, run `bin/rails generate sidekiq:job <path>` (never `generate job`).
- Services live under `app/lib/services/`, never `app/services/`.
- **Root-anchor constants.**
  - Inside `Services::Books::…`, write `::Books::Author`, `::Enrichment`, `::MatchDecision`.
  - Inside `Services::Ai::Tasks::Books`, the name `Books` means `Services::Ai::Tasks::Books`, so write `::Services::Books::Authors::AuthorProfile` and `::Books::Author`.
- Service results use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Minitest 6: `assert_nil` for nil, never `assert_equal nil, x`.
- A clean `bin/rails test` prints no new warning lines.
- **Fills blanks only.** Nothing overwrites a populated field. `name` and `kind` are never written. A disagreement is recorded, never applied.
- **Model roles, never model ids.**
  - `AuthorFactsTask` runs on `standard` for knowledge and `research` (web search) for research.
  - `AuthorDescriptionReviewTask` runs on `fast`.
  - Research runs count against the shared `config.x.ai.research_daily_cap` (50 a day, all kinds).
- **The Wikipedia lead is evidence only.** It is never displayed, and it is never a description's `source_url`.
- **No live AI calls in tests.**
  - Stub the task class's `new` with Mocha, returning a mock whose `call` returns a `Services::Ai::Result`.
  - A task's own test calls its private prompt methods with `send`, as `book_facts_task_test.rb` does.
- **Sidekiq runs inline in tests** (`Sidekiq.testing!(:inline)`). A test that makes a job or provider enqueue the next job must stub or expect that job's `perform_async`. Otherwise the chain runs on, all the way to the AI.
- **No migration in this increment.** `enrichments`, `match_decisions` and `descriptions` need nothing new.
- **No new page or flow, so no Playwright spec.** The first E2E for this feature is the Reject link's, in increment 5.
- Jobs run on the `low` queue with `retry: 3`.
- Ledger kind `books.author_facts`. `mode` is `knowledge` or `research`, and `provider`/`model` come from the chat, as in `EnrichBook`.
- Commit after each task on the worktree branch. Never commit to `main`. Never push.
- Commit message trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Rulings made while planning

1. **The hand-off takes only the books that were waiting (Shane, 2026-09-30).**
   - **The spec's rule.** §10 says `EnrichJob` hands off "each of the author's books that has no `books.book_facts` ledger row". In development that is 158,208 of 158,210 books. Increment 6's backfill of 71k authors would then queue AI enrichment for nearly the whole catalogue, without anyone deciding to.
   - **Shane's ruling.** An author is created because a book is being added. Only that book should be handed on.
   - **The marker.** When a book's import created one of its linked authors, `Providers::AiEnrichment` writes a skipped `books.book_facts` row with reason `deferred_to_authors` (`Services::Books::DeferredEnrichment`).
   - **The hand-off.** `EnrichJob` queues the author's books whose *latest* `books.book_facts` row is that deferral.
   - **The sweep.** `books:enrich_missing` treats a book whose only rows are deferrals as missing. Its reason test is NULL-safe (`IS DISTINCT FROM`), because a plain `where.not(reason:)` also drops every row whose reason is NULL.
   - **Not built.** An option to import all of an author's other books is a separate feature.
2. **Closing the race (the hard gate recorded after increment 2).**
   - **What goes wrong.** The author importer's `Providers::Enrichment` enqueues `WikidataJob` while the book import is still running, before the book and its `book_authors` row are saved. `ResolveWikidata` then sees none of the author's titles.
   - **No async provider inside a book import.** The book importer's two author steps call the author importer with `providers: Author::Importer::BOOK_STEP_PROVIDERS` (`[:open_library]`). The author importer's own `Providers::Enrichment` stays for direct author imports.
   - **The chain starts after the save.** The steps collect the ids of authors the import created (`ImportResult#created?`) into an array the book importer hands to its providers. A new `Providers::AuthorEnrichment`, placed after `Providers::Authors`, enqueues `WikidataJob` for each id. `ImporterBase` has saved the book after `Authors` succeeded, so the rows exist by then.
3. **A book defers only to a new author linked to it.** An author the import created but did not link (a duplicate link) would never hand this book on. So `AiEnrichment` defers only when a created author is among the book's `book_authors`.
4. **Every Wikidata run that does not go to VIAF goes to `EnrichJob`: matched, failed, skipped, or unmatched with `via_viaf`.** So every chain reaches the hand-off, including a placeholder author, whose AI step then skips too.
5. **A VIAF pause hands off; a busy pace does not.**
   - `Viaf::Exceptions::Paused < RateLimited` is raised for a closed gate, a Cloudflare block and a 429. These pauses last an hour or more.
   - A busy pace clears in seconds and stays a plain `RateLimited`.
   - §8's "a paused or out-of-budget `ViafJob` enqueues `EnrichJob` at once" applies only to `Paused`. Handing off on every busy pace would run the AI without VIAF's evidence for almost every author in a bulk import.
   - **`ViafJob(author_id, refresh = false, enrich_queued = false)`.** The flag stops a job rescheduled after a pause from queueing `EnrichJob` again.
   - **Accepted second run.** When VIAF answers later and sends the author back to Wikidata, `EnrichJob` runs a second time. That run only fills blanks and can't replace the first description. It can only happen after a pause.
6. **`EnrichJob` retries a failed AI run and hands off exactly once.**
   - Like `EnrichBookJob`, a failed run raises, so Sidekiq retries it (up to 3 times).
   - The hand-off happens after a successful run, or in `sidekiq_retries_exhausted` after the last failure.
   - So a passing model error is retried, and the waiting books are still handed on.
7. **Skip rules.**
   - `EnrichAuthor` skips a placeholder author (`exclude_from_rankings`), as every author step does.
   - It also skips a "complete" one (§9): an AI or manual description, a `birth_year`, a known gender and at least one country. `unspecified` is the legacy AI's "don't know", so it does not count as a known gender.
   - There is no ledger-based "already processed" skip. Repeat runs are rare (a new author, or a forced re-run), and the data rule already stops one that has nothing left to fill.
   - So there is no third copy of the `processed?`/`write` pair to consolidate, which the increment 3 review asked about.
   - **Known limit for increment 5.** A deprecated AI description still counts as present, both in the skip rule and in the applier's `already_set`. When increment 5's Reject link deprecates one and re-runs the chain, it must change both.
8. **Low confidence is never applied.**
   - Each fact the model marks `low` is recorded with reason `low_confidence` and not written. That includes the description.
   - As in `EnrichBook`, a knowledge answer that is low overall is recorded as `deferred` when research will follow.
   - Research follows only for an author nothing matched, with research allowed and budget left.
9. **The AI's evidence comes from decisions, not identifiers (`MatchedRecords`).**
   - It reads the latest processed ledger row of each step, newer than the author row, and the candidate that row's decision selected. The candidate's snapshot already holds labelled evidence: occupations, citizenships and works.
   - A held id is only what a source calls the author; the decision is what says the record is this author. A row whose held id conflicted (`held_qid_conflict`, `held_viaf_conflict`) contributes nothing.
   - The Wikipedia lead is the page that row's Wikipedia fact names (`facts["wikipedia"]["page"]`). The link step stores only a page that names the same item back and is not a disambiguation page.
10. **The ledger names its evidence.**
    - Each `books.author_facts` row that called the model carries a `sources` fact listing the records in its input: `{"value" => [{"source" => "wikidata", "source_id" => "Q7243"}, …], "applied" => false, "reason" => "input"}`.
    - It has the same shape as every other fact entry, so code that walks `facts` needs no special case. Increment 5 queries it to find descriptions a rejected record influenced (§12).
11. **The copy check, and one rewrite for every failure.**
    - `DescriptionCheck.call(text, source_text:)` adds `copied` when the draft shares any run of 8 consecutive words with the source. Words are letters and digits, case-folded, so punctuation and case do not hide a copy.
    - `EnrichAuthor` runs the check *before* the review too, and passes what it found to the reviewer. A draft that fails only the code check therefore still gets §9's one rewrite.
    - The rewrite is checked again, and a second failure records the description as `rejected`.
12. **The Wikipedia lead in a prompt is capped at 8,000 characters.** It is a runaway guard: an introduction is a few paragraphs. Development holds no stored leads, so there was nothing to measure.
13. **The book prompt's author lines (§10).**
    - One line per stored author, in position order, from what we hold: `Author: Leo Tolstoy (1828–1910; Russian)`.
    - An author with only a birth year reads `born 1947`, only a death year `died 1910`, and neither the name alone.
    - Stored authors replace the importer's names, which remain the fallback for a book with no authors yet.
14. **A failed VIAF run is not retried in this increment (increment 3's I4).**
    - The author still gets the AI step, since `ViafJob` now ends in `EnrichJob` whatever its outcome.
    - Retrying VIAF itself belongs in increment 6's backfill selection: authors whose latest Wikidata row is `unrecognized` and who have no processed VIAF row.
15. **`allow_research` is threaded only as far as `EnrichJob`.** Its only other caller is increment 6's backfill, which adds the argument to `WikidataJob` and `ViafJob` when it needs it.
16. **A description's `source_url` is the first research citation, as for books, or nil.** The text is our own, so it never points at Wikipedia.

## Review Focus

These are the failure modes most likely to bite that no task's main path exercises. Each is pinned by a test in the named task.

1. **`books:enrich_missing` must not re-queue enriched books.** A `where.not(reason: "deferred_to_authors")` exclusion silently drops every row whose reason is NULL, so every applied book would look missing. Task 7.
2. **The race.** A new author's `WikidataJob` must be enqueued only after its `book_authors` row exists. Task 10 checks this at the moment of the enqueue.
3. **A repeated VIAF pause must never queue `EnrichJob` twice, and a busy pace must never queue it.** Task 8.
4. **Copy-check boundaries.** Seven shared words pass, eight fail, and punctuation or case does not hide a copy. A rewrite that still copies is rejected. Tasks 1 and 6.
5. **The hand-off takes only books whose latest `books.book_facts` row is the deferral.** It skips a book enriched since then and a book of the author's that never waited. Task 7.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/services/books/description_check.rb` | `source_text:` and the `copied` check |
| `app/lib/services/books/authors/author_profile.rb` | `ranked_books(limit)`: titles with years, ranked first |
| `app/lib/services/books/authors/matched_records.rb` | The matched Wikidata item, Wikipedia lead and VIAF cluster, from the ledger |
| `app/lib/services/ai/tasks/books/author_facts_task.rb` | Prompt and schema for the author's facts and description |
| `app/lib/services/ai/tasks/books/author_description_review_task.rb` | Reviews and rewrites an author description once |
| `app/lib/services/books/authors/apply_author_facts.rb` | Fills years, gender, countries and the description |
| `app/lib/services/books/authors/enrich_author.rb` | One AI step: skip, knowledge, research, review; one row per run |
| `app/lib/services/books/deferred_enrichment.rb` | The `deferred_to_authors` marker and the waiting books |
| `app/sidekiq/books/authors/enrich_job.rb` | Runs `EnrichAuthor`, then hands on the waiting books |
| `lib/tasks/books/enrich.rake` | `enrich_missing` counts a deferral-only book as missing |
| `app/lib/viaf/exceptions.rb`, `app/lib/viaf/client.rb` | `Paused` for a closed gate, a block or a 429 |
| `app/sidekiq/books/authors/wikidata_job.rb` | Ends in `EnrichJob` unless a miss goes to VIAF |
| `app/sidekiq/books/authors/viaf_job.rb` | Ends in `EnrichJob`; a pause hands off at once, once |
| `app/lib/services/ai/tasks/books/book_facts_task.rb` | One line per stored author with years and countries |
| `app/lib/data_importers/books/author/importer.rb` | `BOOK_STEP_PROVIDERS` |
| `app/lib/data_importers/books/book/importer.rb` | Shares the new-author ids; adds `AuthorEnrichment` |
| `app/lib/data_importers/books/book/providers/open_library.rb`, `authors.rb` | Import authors without the async provider; collect created ids |
| `app/lib/data_importers/books/book/providers/author_enrichment.rb` | Starts the author chain after the save |
| `app/lib/data_importers/books/book/providers/ai_enrichment.rb` | Defers to new linked authors |
| `docs/features/*.md`, the spec | The AI step, the hand-off, the pause, the provider order |

Task order follows dependencies: 1–2 are the pieces the AI step reads, 3–6 build it, 7 wraps it in a job with the hand-off, 8 wires the chain to it, 9–10 change the book side, and 11 documents.

---

### Task 1: `DescriptionCheck` copy check

**Files:**
- Modify: `app/lib/services/books/description_check.rb`
- Test: `test/lib/services/books/description_check_test.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Services::Books::DescriptionCheck.call(text, source_text: nil)`, the same `Result` as before. Its `errors` gain `"copied"` when `text` shares a run of `COPY_RUN` (8) consecutive words with `source_text`. With no `source_text` the behaviour is unchanged, so `EnrichBook`'s calls need no edit.

- [ ] **Step 1: Write the failing tests**

Append inside `DescriptionCheckTest`, after the existing tests:

```ruby
      SOURCE = "Ernest Miller Hemingway was an American novelist, short-story writer and journalist. " \
        "Known for an economical, understated style, he influenced later twentieth-century fiction."

      test "a draft sharing eight consecutive words with its source fails as copied" do
        draft = "#{CLEAN} He was an American novelist, short-story writer and journalist from Illinois."

        result = DescriptionCheck.call(draft, source_text: SOURCE)

        refute result.success?
        assert_includes result.errors, "copied"
      end

      test "seven shared words in a row are not a copy" do
        draft = "#{CLEAN} Hemingway became an American novelist, short-story writer and editor in Paris."

        assert_not_includes DescriptionCheck.call(draft, source_text: SOURCE).errors, "copied"
      end

      test "case and punctuation do not hide a copy" do
        draft = "#{CLEAN} WAS AN AMERICAN NOVELIST; SHORT STORY WRITER, AND JOURNALIST."

        assert_includes DescriptionCheck.call(draft, source_text: SOURCE).errors, "copied"
      end

      test "without source text there is no copy check" do
        assert_not_includes DescriptionCheck.call("#{CLEAN} #{SOURCE}").errors, "copied"
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/description_check_test.rb`
Expected: FAIL. `call` does not accept `source_text:` (ArgumentError: unknown keyword).

- [ ] **Step 3: Implement**

In `app/lib/services/books/description_check.rb`, add the constant after `MAX_WORDS`, change `call`'s signature, add the check before the `Result`, and add the two private class methods after `call`:

```ruby
      MIN_WORDS = 40
      MAX_WORDS = 140
      # A draft that shares this many consecutive words with the text it was
      # written from is a close paraphrase of CC BY-SA text (spec §9), not a
      # description in our own words.
      COPY_RUN = 8

      def self.call(text, source_text: nil)
        cleaned = text.to_s.gsub(MARKDOWN_CITATION, "").strip
        errors = []
        # An em dash is always flagged. An en dash only counts as the same
        # violation when it is being used as a dash (spaced on at least one
        # side) rather than as a hyphen in a year range like "1939-1945".
        errors << "em_dash" if cleaned.include?("—") || cleaned.match?(/ – | –|– /)
        errors << "double_hyphen" if cleaned.include?("--")
        errors << "url" if cleaned.match?(%r{https?://})
        errors << "markdown_link" if cleaned.include?("](")
        words = cleaned.split(/[[:space:]]+/).size
        errors << "too_short" if words < MIN_WORDS
        errors << "too_long" if words > MAX_WORDS
        errors << "copied" if copied?(cleaned, source_text)

        Result.new(success?: errors.empty?, data: {text: cleaned}, errors: errors)
      end

      def self.copied?(text, source_text)
        return false if source_text.blank?

        word_runs(text).intersect?(word_runs(source_text))
      end

      # Every run of COPY_RUN consecutive words, compared on letters and
      # digits only, so case, punctuation and quote styles cannot hide a copy.
      def self.word_runs(text)
        text.to_s.unicode_normalize(:nfkc).downcase.scan(/[\p{L}\p{N}]+/)
          .each_cons(COPY_RUN).map { |run| run.join(" ") }.to_set
      end
      private_class_method :copied?, :word_runs
```

Also add one sentence to the class comment, after the paragraph about titles:

```ruby
    #
    # With source_text (an author's Wikipedia lead), a draft that repeats
    # COPY_RUN consecutive words of it fails as "copied".
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/description_check_test.rb test/lib/services/books/enrich_book_test.rb`
Expected: PASS. `EnrichBook`'s calls are unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/description_check.rb test/lib/services/books/description_check_test.rb
git commit -m "DescriptionCheck: fail a draft that copies eight words of its source

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `AuthorProfile#ranked_books` and `MatchedRecords`

**Files:**
- Modify: `app/lib/services/books/authors/author_profile.rb`
- Create: `app/lib/services/books/authors/matched_records.rb`
- Test: `test/lib/services/books/authors/author_profile_test.rb`, `test/lib/services/books/authors/matched_records_test.rb`

**Interfaces:**
- Consumes:
  - The ledger rows `EnrichFromWikidata` and `EnrichFromViaf` write. Their kinds are `EnrichFromWikidata::KIND` / `EnrichFromViaf::KIND`, the "done" outcomes are `PROCESSED`, and each row has a `match_decision`.
  - `MatchDecision#candidates`: 1-based `selected_index`, each candidate with `"external_key"` and `"evidence"`.
  - `ExternalRecord` rows of source `wikipedia`, and `Wikipedia::Lead.from_payload`.
- Produces:
  - `AuthorProfile#ranked_books(limit)` → `[[title, first_published_year], …]`, ranked first under the default primary configuration, then by id.
  - `Services::Books::Authors::MatchedRecords.new(author)` with:
    - `#wikidata` → `MatchedRecords::Match(source_id:, evidence:)` or nil
    - `#viaf` → `Match` or nil
    - `#lead` → `Wikipedia::Lead` or nil
    - `#matched?` → true when either match exists
    - `#sources` → `[{"source" => "wikidata"|"wikipedia"|"viaf", "source_id" => String}]`

- [ ] **Step 1: Write the failing tests**

Add to `AuthorProfileTest`:

```ruby
        test "ranked books are title and first published year, ranked first, up to the limit" do
          author = ::Books::Author.create!(name: "Profile Author")
          unranked = ::Books::Book.create!(title: "Unranked Book", first_published_year: 2001)
          ranked = ::Books::Book.create!(title: "Ranked Book")
          author.book_authors.create!(book: unranked, position: 1)
          author.book_authors.create!(book: ranked, position: 2)
          RankedItem.create!(item: ranked, ranking_configuration: ranking_configurations(:books_global), rank: 1)
          profile = AuthorProfile.new(author)

          assert_equal [["Ranked Book", nil], ["Unranked Book", 2001]], profile.ranked_books(10)
          assert_equal [["Ranked Book", nil]], profile.ranked_books(1)
        end
```

Create `test/lib/services/books/authors/matched_records_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class MatchedRecordsTest < ActiveSupport::TestCase
        WIKIDATA_EVIDENCE = {"description" => "American writer", "occupations" => ["novelist"]}.freeze

        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham")
        end

        # The decision's second candidate is the selected one, so a wrong
        # index would pick "someone-else".
        def decision(finder, key:, evidence:, outcome: :matched)
          ::MatchDecision.create!(
            finder: finder, subject: @author, outcome: outcome, confidence: :high, decided_by: :rule,
            candidates: [{"external_key" => "someone-else", "evidence" => {}}, {"external_key" => key, "evidence" => evidence}],
            selected_index: (outcome == :matched) ? 2 : nil
          )
        end

        def ledger_row(kind, decision:, outcome: :applied, reason: "matched", facts: {})
          @author.enrichments.create!(kind: kind, provider: "test", outcome: outcome, reason: reason, facts: facts,
            match_decision: decision)
        end

        def wikidata_match(facts: {}, **options)
          ledger_row(EnrichFromWikidata::KIND, decision: decision(ResolveWikidata.name, key: "Q1", evidence: WIKIDATA_EVIDENCE),
            facts: facts, **options)
        end

        def store_lead(item:)
          ::ExternalRecord.create!(source: :wikipedia, source_id: "en:9", fetched_at: Time.current, payload: {
            "language" => "en", "page_id" => 9, "title" => "Stacy Willingham",
            "url" => "https://en.wikipedia.org/wiki/Stacy_Willingham", "extract" => "Stacy Willingham is an American author.",
            "wikibase_item" => item, "disambiguation" => false
          })
        end

        def linked_page
          {"wikipedia" => {"value" => "https://en.wikipedia.org/wiki/Stacy_Willingham", "applied" => true, "reason" => "linked",
                           "page" => "en:9"}}
        end

        test "the Wikidata match is the candidate the latest processed row's decision selected" do
          wikidata_match
          records = MatchedRecords.new(@author)

          assert_equal ["Q1", WIKIDATA_EVIDENCE], [records.wikidata.source_id, records.wikidata.evidence]
          assert records.matched?
          assert_nil records.viaf
        end

        test "a later run that matched nothing replaces an earlier match" do
          wikidata_match
          ledger_row(EnrichFromWikidata::KIND, decision: decision(ResolveWikidata.name, key: nil, evidence: {}, outcome: :unmatched),
            outcome: :unrecognized, reason: "no_match")

          assert_nil MatchedRecords.new(@author).wikidata
          refute MatchedRecords.new(@author).matched?
        end

        test "a failed or skipped row is not processed, so an earlier match stands" do
          wikidata_match
          ledger_row(EnrichFromWikidata::KIND, decision: nil, outcome: :failed, reason: "wikimedia_error")
          ledger_row(EnrichFromWikidata::KIND, decision: nil, outcome: :skipped, reason: "already_processed")

          assert_equal "Q1", MatchedRecords.new(@author).wikidata.source_id
        end

        test "a held id that conflicted with the match contributes nothing" do
          wikidata_match(outcome: :nothing_to_apply, reason: "held_qid_conflict")

          assert_nil MatchedRecords.new(@author).wikidata
        end

        test "a row older than the author row does not count" do
          wikidata_match.update_columns(created_at: @author.created_at - 1.minute)

          assert_nil MatchedRecords.new(@author).wikidata
        end

        test "the VIAF match comes from the VIAF step's rows" do
          ledger_row(EnrichFromViaf::KIND, decision: decision(ResolveViaf.name, key: "5391", evidence: {"agency_count" => 20}))
          records = MatchedRecords.new(@author)

          assert_equal ["5391", {"agency_count" => 20}], [records.viaf.source_id, records.viaf.evidence]
          assert_nil records.wikidata
          assert records.matched?
        end

        test "the lead is the page the matched Wikidata run linked, and it is listed in the sources" do
          store_lead(item: "Q1")
          wikidata_match(facts: linked_page)
          records = MatchedRecords.new(@author)

          assert_equal "Stacy Willingham is an American author.", records.lead.extract
          assert_equal [{"source" => "wikidata", "source_id" => "Q1"}, {"source" => "wikipedia", "source_id" => "en:9"}],
            records.sources
        end

        test "a stored page that names another item is not the lead" do
          store_lead(item: "Q2")
          wikidata_match(facts: linked_page)

          assert_nil MatchedRecords.new(@author).lead
        end

        test "an author nothing matched has no lead and no sources" do
          records = MatchedRecords.new(@author)

          assert_nil records.lead
          assert_equal [], records.sources
          refute records.matched?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/author_profile_test.rb test/lib/services/books/authors/matched_records_test.rb`
Expected: FAIL. `ranked_books` is undefined, and `MatchedRecords` is an uninitialized constant.

- [ ] **Step 3: Implement**

In `app/lib/services/books/authors/author_profile.rb`, move the ranked scope into a private method both public methods use. Replace `titles` and add `ranked_books`:

```ruby
        def titles
          @titles ||= ranked_books_scope.limit(TITLE_LIMIT).pluck(:title, :alternate_titles)
            .flat_map { |title, alternates| [title, *Array(alternates)] }
            .compact_blank.uniq.first(TITLE_LIMIT)
        end

        # Our books by this author, ranked first: [[title, first_published_year], ...].
        def ranked_books(limit)
          ranked_books_scope.limit(limit).pluck(:title, :first_published_year)
        end
```

and, under `private`, after `attr_reader :author`:

```ruby
        # The author's books, ranked first under the default primary
        # configuration, then by id.
        def ranked_books_scope
          configuration = ::Books::RankingConfiguration.default_primary
          return author.books.order("books_books.id") unless configuration

          join = ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Book' " \
            "AND ranked_items.item_id = books_books.id AND ranked_items.ranking_configuration_id = ?",
            configuration.id
          ])
          author.books.joins(join).order(Arel.sql("ranked_items.rank ASC NULLS LAST"), "books_books.id")
        end
```

Create `app/lib/services/books/authors/matched_records.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The records the author steps matched this author to, as the AI step's
      # evidence (spec §9): the Wikidata item, its English Wikipedia lead,
      # and the VIAF cluster. Each comes from the latest processed ledger row
      # of its step, newer than the author row, and from the candidate that
      # row's decision selected, whose snapshot already carries labelled
      # evidence. A row whose decision matched nothing, or whose held id
      # conflicted with the match (nothing was applied), contributes nothing.
      # Identifiers alone are not used: an id is what a source calls the
      # author, and only a decision says the record is this author.
      class MatchedRecords
        Match = Struct.new(:source_id, :evidence, keyword_init: true)

        # The same "done" outcomes for both steps.
        PROCESSED = EnrichFromWikidata::PROCESSED
        CONFLICTS = {
          EnrichFromWikidata::KIND => "held_qid_conflict",
          EnrichFromViaf::KIND => "held_viaf_conflict"
        }.freeze

        def initialize(author)
          @author = author
          @rows = {}
          @matches = {}
        end

        def wikidata = match(EnrichFromWikidata::KIND)

        def viaf = match(EnrichFromViaf::KIND)

        def matched? = wikidata.present? || viaf.present?

        # The lead of the article the matched Wikidata run linked. The link
        # step stores only a page that names the same item back and is not a
        # disambiguation page; the item is compared again here in case the
        # stored page was refreshed since.
        def lead
          return @lead if defined?(@lead)

          page = wikidata && row(EnrichFromWikidata::KIND).facts.dig("wikipedia", "page")
          record = page && ::ExternalRecord.find_by(source: :wikipedia, source_id: page)
          found = record && ::Wikipedia::Lead.from_payload(record.payload)
          @lead = (found if found && found.wikibase_item == wikidata.source_id)
        end

        # What went into the AI step's input, for its ledger row (spec §9, §12).
        def sources
          list = []
          list << {"source" => "wikidata", "source_id" => wikidata.source_id} if wikidata
          list << {"source" => "wikipedia", "source_id" => lead.source_id} if lead
          list << {"source" => "viaf", "source_id" => viaf.source_id} if viaf
          list
        end

        private

        attr_reader :author

        def match(kind)
          return @matches[kind] if @matches.key?(kind)

          latest = row(kind)
          decision = latest&.match_decision
          candidate = decision&.matched? && decision.selected_index && Array(decision.candidates)[decision.selected_index - 1]
          @matches[kind] = if candidate && latest.reason != CONFLICTS.fetch(kind)
            Match.new(source_id: candidate["external_key"], evidence: candidate["evidence"].to_h)
          end
        end

        def row(kind)
          return @rows[kind] if @rows.key?(kind)

          @rows[kind] = author.enrichments.for_kind(kind).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at)
            .includes(:match_decision).order(created_at: :desc, id: :desc).first
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/`
Expected: PASS, including the unchanged `AuthorProfile#titles` and `ResolveWikidata`/`ResolveViaf` tests.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/authors/author_profile.rb app/lib/services/books/authors/matched_records.rb \
  test/lib/services/books/authors/author_profile_test.rb test/lib/services/books/authors/matched_records_test.rb
git commit -m "Author AI evidence: ranked books with years, and the records the author steps matched

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `AuthorFactsTask`

**Files:**
- Create: `app/lib/services/ai/tasks/books/author_facts_task.rb`
- Test: `test/lib/services/ai/tasks/books/author_facts_task_test.rb`

**Interfaces:**
- Consumes:
  - `EnrichmentTask`: `mode:` is `:knowledge` or `:research`, the result carries `data[:facts]` (a symbol-keyed Hash) and `data[:citations]`, and the fact types are `IntegerFact`, `StringFact` and `StringListFact`.
  - `AuthorProfile#ranked_books` and `AuthorProfile.lifespan`.
  - `MatchedRecords#wikidata`/`#viaf`/`#lead` (Task 2).
- Produces:
  - `Services::Ai::Tasks::Books::AuthorFactsTask.new(parent: author, records:, mode: :knowledge)`, where `records` responds to `wikidata`, `viaf` and `lead`.
  - The schema keys: `recognized`, `confidence`, `birth_year`, `death_year`, `gender`, `nationalities`, `description`.
  - `AuthorFactsTask::LEAD_LIMIT` (8,000).

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/ai/tasks/books/author_facts_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AuthorFactsTaskTest < ActiveSupport::TestCase
          MATCH = ::Services::Books::Authors::MatchedRecords::Match

          def setup
            @author = books_authors(:tolstoy)
          end

          def records(wikidata: nil, viaf: nil, lead: nil)
            stub(wikidata: wikidata, viaf: viaf, lead: lead)
          end

          def task(mode: :knowledge, **sources)
            AuthorFactsTask.new(parent: @author, records: records(**sources), mode: mode)
          end

          def prompt(**sources) = task(**sources).send(:user_prompt)

          def lead(extract)
            ::Wikipedia::Lead.new(language: "en", page_id: 9, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
              extract: extract, wikibase_item: "Q7243", disambiguation: false)
          end

          test "runs on openai as an analysis chat with json mode and its own schema" do
            subject = task

            assert_equal :openai, subject.send(:provider).provider_key
            assert_equal :analysis, subject.send(:chat_type)
            assert_equal({type: "json_object"}, subject.send(:response_format))
            assert_equal AuthorFactsTask::ResponseSchema, subject.send(:response_schema)
          end

          test "the schema is a class-level json schema with every fact" do
            keys = AuthorFactsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)

            assert_equal %w[birth_year confidence death_year description gender nationalities recognized], keys.sort
          end

          test "knowledge runs on the standard role and research on the research role" do
            assert_equal [:standard, :research], [task.send(:task_role), task(mode: :research).send(:task_role)]
          end

          test "the prompt names the author, the other names and what we already hold" do
            @author.author_countries.create!(country: books_countries(:french))

            text = prompt

            assert_includes text, "Author: Leo Tolstoy"
            assert_includes text, "Also known as: Lev Tolstoy; Lev Nikolayevich Tolstoy"
            assert_includes text, "Already on record: born 1828; died 1910; nationality French"
          end

          test "the prompt lists our books with their years" do
            assert_includes prompt, "Books by this author in our catalog, best known first:\n- War and Peace (1869)"
          end

          test "a Wikidata match becomes one line of its evidence" do
            evidence = {"description" => "Russian writer", "birth_year" => 1828, "death_year" => 1910,
                        "occupations" => ["novelist", "philosopher"], "citizenships" => ["Russian Empire"],
                        "matching_titles" => ["War and Peace"], "other_titles" => ["Anna Karenina"]}

            text = prompt(wikidata: MATCH.new(source_id: "Q7243", evidence: evidence))

            assert_includes text, "Wikidata: Russian writer | 1828–1910 | occupations: novelist, philosopher | " \
              "citizenship: Russian Empire | notable works: War and Peace; Anna Karenina"
            refute_includes text, "No Wikidata, library or Wikipedia record"
          end

          test "a VIAF match becomes one line of its evidence" do
            evidence = {"headings" => ["Tolstoy, Leo, graf, 1828-1910"], "birth_year" => 1828, "death_year" => 1910,
                        "date_type" => "lived", "nationality" => ["RU"], "occupations" => ["Novelists"],
                        "matching_titles" => ["War and peace"], "other_titles" => [], "agency_count" => 30}

            text = prompt(viaf: MATCH.new(source_id: "27068555", evidence: evidence))

            assert_includes text, "Library authority record (VIAF): headings: Tolstoy, Leo, graf, 1828-1910 | 1828–1910 | " \
              "nationality: RU | occupations: Novelists | works: War and peace | 30 contributing libraries"
          end

          test "a VIAF span that is not a life span is marked as active years" do
            evidence = {"external_title" => "Anna Brenner", "birth_year" => 1920, "death_year" => 1950, "date_type" => "flourished"}

            assert_includes prompt(viaf: MATCH.new(source_id: "1", evidence: evidence)),
              "Library authority record (VIAF): headings: Anna Brenner | active 1920–1950"
          end

          test "the Wikipedia lead is given for facts only, capped" do
            long = "Tolstoy wrote novels. " * 1_000

            text = prompt(wikidata: MATCH.new(source_id: "Q7243", evidence: {}), lead: lead(long))

            assert_includes text, "Wikipedia lead, for facts only; do not reuse its wording:\nTolstoy wrote novels."
            assert_includes text, long.strip.first(AuthorFactsTask::LEAD_LIMIT)
            refute_includes text, long.strip.first(AuthorFactsTask::LEAD_LIMIT + 1)
          end

          test "with nothing matched the prompt says so and has no source lines" do
            text = prompt

            assert_includes text, "No Wikidata, library or Wikipedia record was matched to this author."
            refute_includes text, "Wikidata:"
            refute_includes text, "Wikipedia lead"
          end

          test "the system message carries the author description rules" do
            message = task.send(:system_message)

            assert_includes message, "60 to 110 words"
            assert_includes message, "Do not open with the author's name"
            assert_includes message, "At most one major prize"
            assert_includes message, "never a death year"
            assert_includes message, "never reuse its phrases"
          end

          test "research mode tells the model to verify with web search" do
            refute_includes task.send(:system_message), "web search"
            assert_includes task(mode: :research).send(:system_message), "web search"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/author_facts_task_test.rb`
Expected: FAIL (uninitialized constant `AuthorFactsTask`).

- [ ] **Step 3: Implement**

Create `app/lib/services/ai/tasks/books/author_facts_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      module Books
        # Facts and a description for one Books::Author in a single call
        # (spec §9), grounded in what we hold and in the records the author
        # steps matched (Services::Books::Authors::MatchedRecords): the
        # Wikidata item, its English Wikipedia lead, and the VIAF cluster.
        # Applied by Services::Books::Authors::ApplyAuthorFacts. Inside this
        # module `Books` is Services::Ai::Tasks::Books, so model and service
        # constants are root-anchored.
        class AuthorFactsTask < EnrichmentTask
          BOOK_LIMIT = 10
          WORK_LIMIT = 10
          LIST_LIMIT = 5
          # A runaway guard, not a summary: a lead is a few paragraphs.
          LEAD_LIMIT = 8_000

          def initialize(parent:, records:, mode: :knowledge, provider: nil, model: nil)
            @records = records
            super(parent: parent, mode: mode, provider: provider, model: model)
          end

          private

          attr_reader :records

          def system_message
            <<~SYSTEM_MESSAGE
              You are a bibliographic researcher for a book catalog. You report facts about one author and write one short description of them.#{research_instruction}

              Facts. For every fact give a value and a confidence of high, medium or low. Use null (or an empty list) when you do not know; never guess. Set "recognized" to false if neither the sources given nor your own knowledge tell you who this specific author is, and give an overall "confidence" for how well you know them. The Wikidata, library and Wikipedia sources below were matched to this author; prefer them to memory. When no source is given, the name may belong to several people: describe only the person who wrote the books listed. birth_year and death_year are years of the Common Era; death_year is null for a living person. gender is male, female or non_binary. nationalities are English nationality adjectives such as "French" or "Japanese", one for each country the author was a citizen of.

              Description rules.
              - One paragraph, 60 to 110 words, sentences of varied length.
              - Say who the author is or was, when and where they lived and worked, what they write or wrote, and their best-known works named plainly. Name a literary movement only if one clearly applies.
              - At most one major prize, stated plainly, such as "won the 1954 Nobel Prize in Literature". No other awards.
              - Do not open with the author's name; the page shows it.
              - For a living author, nothing about their personal life beyond what the sources state, and never a death year.
              - No em dashes or double hyphens, no semicolons, no lists, no emoji, no quotation marks around titles.
              - No marketing or judgment: no acclaimed, bestselling, masterpiece, beloved, celebrated, legendary, one of the greatest, must-read, no sales figures.
              - No meta narration such as "This author" or "Readers will". Open on the person.
              - Plain words. Do not use: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, or "explores themes of".
              - No "not X but Y" constructions. No ornamental triads of adjectives.
              - Write in your own words and your own sentence structure. Use the Wikipedia text for facts only; never reuse its phrases.
              - Only what you are sure of. Say less rather than guess. If you do not know who this author is well enough to describe them, set description to null.
              - No citations, URLs, footnotes, or bracketed references inside any text field.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def research_instruction
            return "" unless research?

            " Use web search to verify every fact before reporting it; prefer library, publisher and encyclopedia sources. Report what the sources say, not what you remember."
          end

          def user_prompt
            lines = ["Author: #{parent.name}"]
            alternates = Array(parent.alternate_names).first(10)
            lines << "Also known as: #{alternates.join("; ")}" if alternates.any?
            stored = stored_facts
            lines << "Already on record: #{stored.join("; ")}" if stored.any?
            lines.concat(book_lines)
            lines.concat(source_lines)
            lines << ""
            lines << "Report the facts and write the description as JSON matching the schema."
            lines.join("\n")
          end

          def stored_facts
            facts = []
            facts << "born #{parent.birth_year}" if parent.birth_year
            facts << "died #{parent.death_year}" if parent.death_year
            facts << "gender #{parent.gender.tr("_", "-")}" if parent.gender.present? && parent.gender != "unspecified"
            countries = parent.countries.map(&:name).sort
            facts << "nationality #{countries.join(", ")}" if countries.any?
            facts
          end

          def book_lines
            books = ::Services::Books::Authors::AuthorProfile.new(parent).ranked_books(BOOK_LIMIT)
            return [] if books.empty?

            ["Books by this author in our catalog, best known first:"] +
              books.map { |title, year| year ? "- #{title} (#{year})" : "- #{title}" }
          end

          def source_lines
            lines = []
            wikidata = records.wikidata && describe_wikidata(records.wikidata.evidence)
            lines << "Wikidata: #{wikidata}" if wikidata.present?
            viaf = records.viaf && describe_viaf(records.viaf.evidence)
            lines << "Library authority record (VIAF): #{viaf}" if viaf.present?
            extract = records.lead ? records.lead.extract.to_s.strip : ""
            if extract.present?
              lines << ""
              lines << "Wikipedia lead, for facts only; do not reuse its wording:"
              lines << extract.first(LEAD_LIMIT)
            end
            if records.wikidata.nil? && records.viaf.nil?
              lines << "No Wikidata, library or Wikipedia record was matched to this author."
            end
            lines
          end

          def describe_wikidata(evidence)
            parts = []
            parts << evidence["description"] if evidence["description"].present?
            span = ::Services::Books::Authors::AuthorProfile.lifespan(evidence["birth_year"], evidence["death_year"])
            parts << span if span
            listed(parts, "occupations", evidence["occupations"])
            listed(parts, "citizenship", evidence["citizenships"])
            works = works(evidence)
            parts << "notable works: #{works.join("; ")}" if works.any?
            parts.join(" | ")
          end

          def describe_viaf(evidence)
            parts = []
            headings = Array(evidence["headings"]).presence || Array(evidence["external_title"])
            parts << "headings: #{headings.first(LIST_LIMIT).join("; ")}" if headings.any?
            span = ::Services::Books::Authors::AuthorProfile.lifespan(evidence["birth_year"], evidence["death_year"])
            if span
              lived = evidence["date_type"].blank? || evidence["date_type"].to_s.casecmp?("lived")
              parts << (lived ? span : "active #{span}")
            end
            listed(parts, "nationality", evidence["nationality"])
            listed(parts, "occupations", evidence["occupations"])
            works = works(evidence)
            parts << "works: #{works.join("; ")}" if works.any?
            parts << "#{evidence["agency_count"]} contributing libraries" if evidence["agency_count"]
            parts.join(" | ")
          end

          def listed(parts, label, values)
            values = Array(values).compact_blank.first(LIST_LIMIT)
            parts << "#{label}: #{values.join(", ")}" if values.any?
          end

          def works(evidence)
            (Array(evidence["matching_titles"]) + Array(evidence["other_titles"])).compact_blank.uniq.first(WORK_LIMIT)
          end

          def response_schema = ResponseSchema

          class ResponseSchema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean, doc: "false if neither the sources nor your knowledge tell you who this author is"
            required :confidence, String, doc: "high, medium or low: how well you know this specific author"
            required :birth_year, EnrichmentTask::IntegerFact
            required :death_year, EnrichmentTask::IntegerFact, doc: "null for a living person"
            required :gender, EnrichmentTask::StringFact, doc: "male, female or non_binary"
            required :nationalities, EnrichmentTask::StringListFact, doc: "English nationality adjectives"
            required :description, EnrichmentTask::StringFact, doc: "One paragraph following the rules"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/books/author_facts_task_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/ai/tasks/books/author_facts_task.rb test/lib/services/ai/tasks/books/author_facts_task_test.rb
git commit -m "AuthorFactsTask: an author's facts and description in one call, grounded in the matched records

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `AuthorDescriptionReviewTask`

**Files:**
- Create: `app/lib/services/ai/tasks/books/author_description_review_task.rb`
- Test: `test/lib/services/ai/tasks/books/author_description_review_task_test.rb`

**Interfaces:**
- Consumes: `BaseTask`, and `AuthorFactsTask::LEAD_LIMIT` (Task 3).
- Produces:
  - `Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.new(parent: author, description:, source_text: nil, flagged: [])`.
  - `flagged` is the list of `DescriptionCheck` error codes.
  - `#call` returns a `Services::Ai::Result` whose `data` is `{style_violations: [String], rewritten: String | nil}`, symbol-keyed, or `{}` for an empty reply.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/ai/tasks/books/author_description_review_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AuthorDescriptionReviewTaskTest < ActiveSupport::TestCase
          def setup
            @author = books_authors(:tolstoy)
          end

          def task(**options) = AuthorDescriptionReviewTask.new(parent: @author, description: "A Russian novelist.", **options)

          test "runs on the fast role with json mode and its own schema" do
            subject = task

            assert_equal :fast, subject.send(:task_role)
            assert_equal({type: "json_object"}, subject.send(:response_format))
            keys = AuthorDescriptionReviewTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[rewritten style_violations], keys.sort
          end

          test "the rules judge copied phrasing and an opening name, not spoilers" do
            message = task.send(:system_message)

            assert_includes message, "copied_phrasing"
            assert_includes message, "names_author_at_start"
            refute_includes message, "spoiler"
          end

          test "the prompt carries the author, the draft and the source text" do
            prompt = task(source_text: "Lead text here.").send(:user_prompt)

            assert_includes prompt, "Author: Leo Tolstoy"
            assert_includes prompt, "Description to review:\nA Russian novelist."
            assert_includes prompt, "Source text the description was written from, for comparison only:\nLead text here."
          end

          test "without source text there is no source section" do
            refute_includes task.send(:user_prompt), "Source text"
          end

          test "problems the code found reach the reviewer in words" do
            prompt = task(flagged: %w[copied too_long]).send(:user_prompt)

            assert_includes prompt, "Automated checks found that the description repeats eight or more consecutive " \
              "words of the source text; is over 140 words."
          end

          test "a parsed reply becomes a symbol-keyed hash, and an empty one an empty hash" do
            parsed = task.send(:process_and_persist, {parsed: {"style_violations" => ["semicolon"], "rewritten" => "Fixed."}})
            empty = task.send(:process_and_persist, {parsed: nil})

            assert_equal({style_violations: ["semicolon"], rewritten: "Fixed."}, parsed.data)
            assert_equal({}, empty.data)
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/author_description_review_task_test.rb`
Expected: FAIL (uninitialized constant).

- [ ] **Step 3: Implement**

Create `app/lib/services/ai/tasks/books/author_description_review_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      module Books
        # Second opinion on a generated author description, on the cheap role
        # (spec §9). The book reviewer's spoiler judgment becomes two author
        # judgments: copied phrasing, against the Wikipedia lead the draft was
        # written from, and opening with the author's name. What the code
        # already found (Services::Books::DescriptionCheck) is passed in, so
        # the one rewrite fixes that too.
        class AuthorDescriptionReviewTask < BaseTask
          VIOLATIONS = %w[copied_phrasing names_author_at_start em_dash semicolon marketing meta_narration banned_word
            not_but triad too_long too_short citation].freeze
          CHECK_NOTES = {
            "copied" => "repeats eight or more consecutive words of the source text",
            "em_dash" => "contains an em dash",
            "double_hyphen" => "contains a double hyphen",
            "url" => "contains a URL",
            "markdown_link" => "contains a markdown link",
            "too_short" => "is under 40 words",
            "too_long" => "is over 140 words"
          }.freeze

          def initialize(parent:, description:, source_text: nil, flagged: [], provider: nil, model: nil)
            @description = description.to_s
            @source_text = source_text.to_s.strip
            @flagged = Array(flagged)
            super(parent: parent, provider: provider, model: model)
          end

          private

          attr_reader :description, :source_text, :flagged

          def task_role = :fast

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM_MESSAGE
              You review one short description of an author against these rules and fix it if needed.

              Violations, reported as codes in "style_violations" (empty list when clean):
              - copied_phrasing: reuses a phrase or a sentence structure from the source text instead of saying it in new words
              - names_author_at_start: opens with the author's name
              - em_dash: an em dash (—) or double hyphen (--)
              - semicolon: a semicolon
              - marketing: praise or sales language such as acclaimed, bestselling, masterpiece, beloved, celebrated, legendary, "one of the greatest", sales figures, or more than one award
              - meta_narration: "This author", "Readers will", or similar
              - banned_word: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, "explores themes of"
              - not_but: a "not X but Y" construction
              - triad: an ornamental run of three adjectives or phrases
              - too_long: more than 110 words
              - too_short: fewer than 60 words
              - citation: a URL, bracketed reference, footnote, or citation

              If "style_violations" is not empty, or the automated checks found a problem, put a corrected version in "rewritten": one paragraph, 60 to 110 words, plain words, varied sentence length, not opening with the author's name, in wording of your own rather than the source's, same facts, nothing invented. Otherwise set "rewritten" to null.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def user_prompt
            lines = ["Author: #{parent.name}"]
            if flagged.any?
              notes = flagged.map { |code| CHECK_NOTES.fetch(code, code) }
              lines << "Automated checks found that the description #{notes.join("; ")}."
            end
            lines << ""
            lines << "Description to review:"
            lines << description
            if source_text.present?
              lines << ""
              lines << "Source text the description was written from, for comparison only:"
              lines << source_text.first(AuthorFactsTask::LEAD_LIMIT)
            end
            lines.join("\n")
          end

          # A JSON round trip: the SDK's parsed schema object is a BaseModel,
          # whose #to_h is shallow.
          def process_and_persist(provider_response)
            parsed = provider_response[:parsed]
            data = parsed.nil? ? {} : JSON.parse(parsed.to_json, symbolize_names: true)
            Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :style_violations, OpenAI::ArrayOf[String], doc: "Violation codes from the list, empty when clean"
            required :rewritten, String, nil?: true, doc: "Corrected description, or null when nothing needed changing"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/books/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/ai/tasks/books/author_description_review_task.rb test/lib/services/ai/tasks/books/author_description_review_task_test.rb
git commit -m "AuthorDescriptionReviewTask: review an author description for copying and an opening name

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 5: `ApplyAuthorFacts`

**Files:**
- Create: `app/lib/services/books/authors/apply_author_facts.rb`
- Test: `test/lib/services/books/authors/apply_author_facts_test.rb`

**Interfaces:**
- Consumes:
  - `FactSheet`: `#record(name, value, applied:, reason:, **extra)`, `#year(name, value)`, `#gender(value, **source)`, `#countries(values, **source) { |values| CountryLookup::Result }`, and `#facts` / `#applied`.
  - `Services::Books::CountryLookup.from_text(names)`.
  - `Describable#assign_description`.
- Produces:
  - `Services::Books::Authors::ApplyAuthorFacts.call(author:, facts:, citations: [], description: nil)`.
    - `facts` is the task's symbol-keyed hash.
    - `description` is nil or `{text:, review:, reason:}`; a non-nil `reason` means "do not write".
    - Returns `Result` with `data[:facts]` (the ledger facts, string keys) and `data[:applied]` (names).
    - Saves the author.
  - Ledger names: `birth_year`, `death_year`, `gender`, `countries` (from `nationalities`), `description`. Each entry carries the model's `"confidence"`.
  - `ApplyAuthorFacts::GENDERS` = `%w[male female non_binary]`.
  - `ApplyAuthorFacts::LEDGER_NAMES`, mapping each reported fact (a symbol) to its ledger name.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/books/authors/apply_author_facts_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ApplyAuthorFactsTest < ActiveSupport::TestCase
        DESCRIPTION = ("Her poems and essays followed Paris between the wars, and she edited a small review that printed young writers. " * 3).strip

        def setup
          @author = ::Books::Author.create!(name: "Anna Brenner")
        end

        def facts(overrides = {})
          {
            recognized: true, confidence: "high",
            birth_year: {value: 1901, confidence: "high"},
            death_year: {value: 1980, confidence: "high"},
            gender: {value: "female", confidence: "high"},
            nationalities: {value: ["French"], confidence: "high"},
            description: {value: DESCRIPTION, confidence: "high"}
          }.deep_merge(overrides)
        end

        def apply(reviewed: {text: DESCRIPTION, review: nil, reason: nil}, citations: [], **overrides)
          ApplyAuthorFacts.call(author: @author, facts: facts(overrides), citations: citations, description: reviewed)
        end

        # A fresh author per call, so each value is judged on its own.
        def reason_for(name, value)
          @author = ::Books::Author.create!(name: "Anna Brenner")
          apply(name => {value: value}).data[:facts][ApplyAuthorFacts::LEDGER_NAMES.fetch(name)]["reason"]
        end

        test "fills every blank and records each fact with its confidence" do
          result = apply

          @author.reload
          assert_equal [1901, 1980, "female", ["French"]], [@author.birth_year, @author.death_year, @author.gender, @author.countries.map(&:name)]
          assert_equal [DESCRIPTION, "ai_generated"], [@author.descriptions.sole.content, @author.descriptions.sole.source]
          assert_equal({"value" => 1901, "applied" => true, "reason" => "filled", "confidence" => "high"}, result.data[:facts]["birth_year"])
          assert_equal %w[birth_year death_year gender countries description], result.data[:applied]
        end

        test "a stored value is never overwritten, and a different one is a conflict" do
          @author.update!(birth_year: 1900, gender: :male)

          result = apply

          @author.reload
          assert_equal [1900, "male", "Anna Brenner"], [@author.birth_year, @author.gender, @author.name]
          assert_equal ["conflict", 1900], result.data[:facts]["birth_year"].values_at("reason", "stored")
          assert_equal "conflict", result.data[:facts]["gender"]["reason"]
        end

        test "an unspecified gender counts as blank" do
          @author.update!(gender: :unspecified)

          apply

          assert_equal "female", @author.reload.gender
        end

        test "a fact the model gave low confidence is recorded, not applied" do
          result = apply(birth_year: {confidence: "low"}, description: {confidence: "low"})

          @author.reload
          assert_nil @author.birth_year
          assert_equal 1980, @author.death_year
          assert_equal ["low_confidence", "low"], result.data[:facts]["birth_year"].values_at("reason", "confidence")
          assert_equal ["low_confidence", false], result.data[:facts]["description"].values_at("reason", "applied")
          assert_equal 0, @author.descriptions.count
        end

        test "years are Common Era, no later than this year, and a death is no earlier than the birth" do
          reasons = [
            reason_for(:birth_year, Date.current.year + 1), reason_for(:birth_year, 0), reason_for(:birth_year, -50),
            reason_for(:birth_year, "1901"), reason_for(:death_year, 1850)
          ]

          assert_equal %w[invalid invalid invalid invalid invalid], reasons
        end

        test "gender is male, female or non_binary, in any spelling; anything else is invalid" do
          assert_equal "invalid", reason_for(:gender, "other")

          reason_for(:gender, "Non-binary")

          assert_equal "non_binary", @author.reload.gender
        end

        test "nationalities fill countries only when the author has none, and an unknown one is recorded" do
          first = apply(nationalities: {value: ["French", "Martian"]})

          assert_equal [["French"], ["Martian"]], [@author.reload.countries.map(&:name), first.data[:facts]["countries"]["unmatched"]]

          again = apply(nationalities: {value: ["Japanese"]})

          assert_equal ["already_set", ["French"]], [again.data[:facts]["countries"]["reason"], @author.reload.countries.map(&:name)]
        end

        test "no nationalities record null" do
          assert_equal "null", apply(nationalities: {value: []}).data[:facts]["countries"]["reason"]
        end

        test "the runner's verdict on the description is recorded, and nothing is written" do
          result = apply(reviewed: {text: DESCRIPTION, review: {"style_violations" => ["semicolon"]}, reason: "rejected"})

          entry = result.data[:facts]["description"]
          assert_equal ["rejected", false, {"style_violations" => ["semicolon"]}], entry.values_at("reason", "applied", "review")
          assert_equal 0, @author.reload.descriptions.count
        end

        test "an existing AI description is kept" do
          @author.assign_description(source: :ai_generated, content: "An earlier AI description.")
          @author.save!

          result = apply

          assert_equal "already_set", result.data[:facts]["description"]["reason"]
          assert_equal "An earlier AI description.", @author.reload.descriptions.sole.content
        end

        test "a written description cites the first research citation" do
          apply(citations: ["https://example.org/a", "https://example.org/b"])

          assert_equal "https://example.org/a", @author.reload.descriptions.sole.source_url
        end

        test "no description from the runner records null" do
          assert_equal "null", apply(reviewed: nil).data[:facts]["description"]["reason"]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/apply_author_facts_test.rb`
Expected: FAIL (uninitialized constant `ApplyAuthorFacts`).

- [ ] **Step 3: Implement**

Create `app/lib/services/books/authors/apply_author_facts.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Writes what the AI step reported about an author (spec §9), filling
      # blanks only through the FactSheet every author step shares. A fact
      # the model gave low confidence is recorded, not applied. Nationalities
      # become countries through CountryLookup, and only when the author has
      # none. The description is written only when the author has no AI
      # description yet: the legacy ones are kept. Whether a run is applied
      # at all is EnrichAuthor's decision; this class saves the author.
      class ApplyAuthorFacts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        GENDERS = %w[male female non_binary].freeze
        # The ledger name each reported fact is recorded under.
        LEDGER_NAMES = {
          birth_year: "birth_year", death_year: "death_year", gender: "gender",
          nationalities: "countries", description: "description"
        }.freeze

        def self.call(author:, facts:, citations: [], description: nil)
          new(author: author, facts: facts, citations: citations, description: description).call
        end

        def initialize(author:, facts:, citations:, description:)
          @author = author
          @facts = facts.deep_symbolize_keys
          @citations = Array(citations)
          @description = description
          @sheet = FactSheet.new(author)
        end

        def call
          apply_year(:birth_year)
          apply_year(:death_year)
          apply_gender
          apply_countries
          apply_description
          LEDGER_NAMES.each { |name, key| sheet.facts[key]&.merge!("confidence" => fact(name)[:confidence]) }

          author.save!
          Result.new(success?: true, data: {facts: sheet.facts, applied: sheet.applied}, errors: [])
        end

        private

        attr_reader :author, :facts, :citations, :description, :sheet

        def fact(name) = facts[name] || {}

        def low?(entry) = entry[:confidence].to_s.strip.casecmp?("low")

        def apply_year(name)
          entry = fact(name)
          value = entry[:value]
          key = LEDGER_NAMES.fetch(name)
          return sheet.record(key, nil, applied: false, reason: "null") if value.nil?
          return sheet.record(key, value, applied: false, reason: "invalid") unless valid_year?(name, value)
          return sheet.record(key, value, applied: false, reason: "low_confidence") if low?(entry)

          sheet.year(key, value)
        end

        # A Common Era year no later than this one; a death no earlier than
        # the birth we hold, or, failing that, the birth the model reported.
        def valid_year?(name, value)
          return false unless value.is_a?(Integer) && value.positive? && value <= Date.current.year
          return true unless name == :death_year

          reported = fact(:birth_year)[:value]
          birth = author.birth_year || (reported if reported.is_a?(Integer))
          birth.nil? || value >= birth
        end

        def apply_gender
          entry = fact(:gender)
          value = entry[:value].to_s.strip.downcase.tr(" -", "__").presence
          return sheet.record("gender", nil, applied: false, reason: "null") if value.nil?
          return sheet.record("gender", value, applied: false, reason: "invalid") unless GENDERS.include?(value)
          return sheet.record("gender", value, applied: false, reason: "low_confidence") if low?(entry)

          sheet.gender(value)
        end

        def apply_countries
          entry = fact(:nationalities)
          names = Array(entry[:value]).map { |name| name.to_s.squish }.reject(&:blank?).uniq(&:downcase)
          if names.any? && low?(entry)
            return sheet.record("countries", names, applied: false, reason: "low_confidence", unmatched: [])
          end

          sheet.countries(names, nationalities: names) { |values| ::Services::Books::CountryLookup.from_text(values) }
        end

        def apply_description
          return sheet.record("description", nil, applied: false, reason: "null") if description.nil?

          text = description[:text]
          review = {review: description[:review]}.compact
          if description[:reason].present?
            return sheet.record("description", text, applied: false, reason: description[:reason], **review)
          end
          return sheet.record("description", text, applied: false, reason: "low_confidence", **review) if low?(fact(:description))
          if author.descriptions.any? { |row| row.source == "ai_generated" }
            return sheet.record("description", text, applied: false, reason: "already_set", **review)
          end

          row = author.assign_description(source: :ai_generated, content: text, source_url: citations.first)
          sheet.record("description", text, applied: row.present?, reason: row ? "filled" : "null", **review)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/apply_author_facts_test.rb test/lib/services/books/authors/fact_sheet_test.rb`
Expected: PASS. `FactSheet` is unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/authors/apply_author_facts.rb test/lib/services/books/authors/apply_author_facts_test.rb
git commit -m "ApplyAuthorFacts: fill an author's blanks from the AI step, never on low confidence

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `EnrichAuthor`, one AI step and one ledger row per run

**Files:**
- Create: `app/lib/services/books/authors/enrich_author.rb`
- Test: `test/lib/services/books/authors/enrich_author_test.rb`

**Interfaces:**
- Consumes:
  - `MatchedRecords` (Task 2), `AuthorFactsTask` (Task 3), `AuthorDescriptionReviewTask` (Task 4) and `ApplyAuthorFacts` (Task 5).
  - `DescriptionCheck.call(text, source_text:)` (Task 1).
  - `Services::Ai::Roles.resolve(role)` (`.provider`, `.model`), `Enrichment.research.today`, and `Rails.application.config.x.ai.research_daily_cap`.
- Produces:
  - `Services::Books::Authors::EnrichAuthor.call(author:, allow_research: true)` → `Result`.
    - `success?` is false when any row failed.
    - `data[:enrichments]` holds the rows written.
    - `errors` holds their error messages.
  - `EnrichAuthor::KIND` = `"books.author_facts"`.
  - Every row that called the model carries the `sources` fact (Ruling 10).

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/books/authors/enrich_author_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class EnrichAuthorTest < ActiveSupport::TestCase
        DESCRIPTION = ("Her poems and essays followed Paris between the wars, and she edited a small review that printed young writers. " * 3).strip
        LEAD = "Anna Brenner was a French poet and critic who wrote about Paris between the two world wars."
        # Shares "was a french poet and critic who wrote about paris" with LEAD.
        COPYING = "#{DESCRIPTION} She was a French poet and critic who wrote about Paris."
        REWRITE = ("She wrote poems and criticism about Paris in the years between two wars and ran a small review. " * 3).strip

        def setup
          @author = ::Books::Author.create!(name: "Anna Brenner")
          @chat = AiChat.create!(parent: @author, chat_type: :analysis, model: "gpt-6-sol", provider: :openai)
          stub_records(matched: false)
          stub_review(style_violations: [], rewritten: nil)
        end

        def stub_records(matched:, lead: nil)
          wikidata = matched ? MatchedRecords::Match.new(source_id: "Q1", evidence: {}) : nil
          page = lead && ::Wikipedia::Lead.new(language: "en", page_id: 9, title: "Anna Brenner",
            url: "https://en.wikipedia.org/wiki/Anna_Brenner", extract: lead, wikibase_item: "Q1", disambiguation: false)
          sources = matched ? [{"source" => "wikidata", "source_id" => "Q1"}] : []
          @records = stub(wikidata: wikidata, viaf: nil, lead: page, matched?: matched, sources: sources)
          MatchedRecords.stubs(:new).returns(@records)
        end

        def facts(overrides = {})
          {
            recognized: true, confidence: "high",
            birth_year: {value: 1901, confidence: "high"},
            death_year: {value: nil, confidence: "low"},
            gender: {value: "female", confidence: "high"},
            nationalities: {value: ["French"], confidence: "high"},
            description: {value: DESCRIPTION, confidence: "high"}
          }.deep_merge(overrides)
        end

        def success_result(facts_hash, citations: [])
          ::Services::Ai::Result.new(success: true, data: {facts: facts_hash, citations: citations}, ai_chat: @chat)
        end

        def failure_result(message) = ::Services::Ai::Result.new(success: false, error: message)

        # Expects AuthorFactsTask to be built once per listed mode, with the
        # author and its matched records, and returns the given results.
        def expect_runs(*runs)
          runs.each do |mode, result|
            task = mock
            task.stubs(:call).returns(result)
            ::Services::Ai::Tasks::Books::AuthorFactsTask.expects(:new)
              .with { |args| args[:parent] == @author && args[:mode] == mode && args[:records] == @records }
              .returns(task)
          end
        end

        def review_result(style_violations:, rewritten:)
          ::Services::Ai::Result.new(success: true, data: {style_violations: style_violations, rewritten: rewritten}, ai_chat: @chat)
        end

        def stub_review(style_violations:, rewritten:, success: true)
          review = mock
          review.stubs(:call).returns(success ? review_result(style_violations: style_violations, rewritten: rewritten) :
            ::Services::Ai::Result.new(success: false, error: "review down"))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.stubs(:new).returns(review)
        end

        def rows = @author.enrichments.for_kind(EnrichAuthor::KIND).order(:id)

        test "a placeholder author is skipped without a model call" do
          ::Services::Ai::Tasks::Books::AuthorFactsTask.expects(:new).never
          author = books_authors(:excluded_placeholder)

          result = EnrichAuthor.call(author: author)

          assert result.success?
          assert_equal [["skipped", "placeholder"]], author.enrichments.for_kind(EnrichAuthor::KIND).pluck(:outcome, :reason)
        end

        test "an author with nothing left to fill is skipped" do
          ::Services::Ai::Tasks::Books::AuthorFactsTask.expects(:new).never
          @author.update!(birth_year: 1901, gender: :female)
          @author.author_countries.create!(country: books_countries(:french))
          @author.assign_description(source: :manual, content: "Written by hand.")
          @author.save!

          EnrichAuthor.call(author: @author)

          assert_equal [["skipped", "complete"]], rows.pluck(:outcome, :reason)
        end

        test "an unspecified gender leaves the author incomplete" do
          @author.update!(birth_year: 1901, gender: :unspecified)
          @author.author_countries.create!(country: books_countries(:french))
          @author.assign_description(source: :ai_generated, content: "Written before.")
          @author.save!
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "female", @author.reload.gender
        end

        test "a recognized knowledge run applies and writes one row naming its sources" do
          stub_records(matched: true)
          expect_runs([:knowledge, success_result(facts)])

          result = EnrichAuthor.call(author: @author)

          assert result.success?
          row = rows.sole
          assert_equal ["books.author_facts", "knowledge", "applied", true, "high"], [row.kind, row.mode, row.outcome, row.recognized, row.confidence]
          assert_equal [@chat, "gpt-6-sol", "openai"], [row.ai_chat, row.model, row.provider]
          assert_equal({"value" => [{"source" => "wikidata", "source_id" => "Q1"}], "applied" => false, "reason" => "input"}, row.facts["sources"])
          assert_equal [1901, DESCRIPTION], [@author.reload.birth_year, @author.descriptions.sole.content]
        end

        test "an unmatched author the model does not know is researched" do
          expect_runs([:knowledge, success_result(facts(recognized: false))], [:research, success_result(facts(confidence: "medium"))])

          result = EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge unrecognized], %w[research applied]], rows.pluck(:mode, :outcome)
          assert_equal "unrecognized", rows.first.facts["birth_year"]["reason"]
          assert_equal 1901, @author.reload.birth_year
          assert_equal 2, result.data[:enrichments].size
        end

        test "an author an authority matched is never researched" do
          stub_records(matched: true)
          expect_runs([:knowledge, success_result(facts(recognized: false))])

          EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge unrecognized]], rows.pluck(:mode, :outcome)
        end

        test "allow_research false never researches" do
          expect_runs([:knowledge, success_result(facts(recognized: false))])

          EnrichAuthor.call(author: @author, allow_research: false)

          assert_equal [%w[knowledge unrecognized]], rows.pluck(:mode, :outcome)
        end

        test "an exhausted research budget writes a skipped research row" do
          Rails.application.config.x.ai.stubs(:research_daily_cap).returns(0)
          expect_runs([:knowledge, success_result(facts(recognized: false))])

          EnrichAuthor.call(author: @author)

          assert_equal [%w[knowledge unrecognized], %w[research skipped]], rows.pluck(:mode, :outcome)
          assert_equal "budget_exhausted", rows.last.reason
        end

        test "a low-confidence knowledge answer is deferred to research, which applies" do
          expect_runs([:knowledge, success_result(facts(confidence: "low"))], [:research, success_result(facts)])

          EnrichAuthor.call(author: @author)

          deferred, researched = rows.to_a
          assert_equal ["nothing_to_apply", "deferred"], [deferred.outcome, deferred.facts["birth_year"]["reason"]]
          assert_equal "deferred", deferred.facts["countries"]["reason"]
          assert_equal "applied", researched.outcome
          assert_equal 1901, @author.reload.birth_year
        end

        test "a low-confidence answer about a matched author applies what it is sure of" do
          stub_records(matched: true)
          expect_runs([:knowledge, success_result(facts(confidence: "low", birth_year: {confidence: "low"}))])

          EnrichAuthor.call(author: @author)

          row = rows.sole
          assert_equal ["applied", "low_confidence"], [row.outcome, row.facts["birth_year"]["reason"]]
          assert_equal "female", @author.reload.gender
          assert_nil @author.birth_year
        end

        test "a failed task writes a failed row on the standard role and does not research" do
          expect_runs([:knowledge, failure_result("timeout")])

          result = EnrichAuthor.call(author: @author)

          refute result.success?
          assert_equal ["timeout"], result.errors
          row = rows.sole
          assert_equal ["failed", "timeout", "gpt-6-sol", "openai"], [row.outcome, row.error, row.model, row.provider]
        end

        test "an empty answer is a failure" do
          expect_runs([:knowledge, success_result({})])

          refute EnrichAuthor.call(author: @author).success?
          assert_equal "empty response", rows.sole.error
        end

        test "an error while applying still leaves one failed row" do
          expect_runs([:knowledge, success_result(facts)])
          ApplyAuthorFacts.stubs(:call).raises(StandardError, "boom")

          EnrichAuthor.call(author: @author)

          assert_equal [["failed", "boom"]], rows.pluck(:outcome, :error)
        end

        test "the reviewer sees the draft, the lead and the code's findings; a clean draft is written" do
          stub_records(matched: true, lead: LEAD)
          review = mock
          review.stubs(:call).returns(review_result(style_violations: [], rewritten: nil))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new)
            .with { |args| args[:parent] == @author && args[:description] == DESCRIPTION && args[:source_text] == LEAD && args[:flagged] == [] }
            .returns(review)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal DESCRIPTION, @author.reload.descriptions.sole.content
        end

        test "a draft that copies the lead goes to the reviewer flagged, and its clean rewrite is written" do
          stub_records(matched: true, lead: LEAD)
          review = mock
          review.stubs(:call).returns(review_result(style_violations: ["copied_phrasing"], rewritten: REWRITE))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).with { |args| args[:flagged] == ["copied"] }.returns(review)
          expect_runs([:knowledge, success_result(facts(description: {value: COPYING}))])

          EnrichAuthor.call(author: @author)

          assert_equal REWRITE, @author.reload.descriptions.sole.content
          assert_equal ["copied"], rows.sole.facts["description"]["review"]["check_errors"]
        end

        test "a rewrite that still copies the lead is rejected" do
          stub_records(matched: true, lead: LEAD)
          stub_review(style_violations: ["copied_phrasing"], rewritten: COPYING)
          expect_runs([:knowledge, success_result(facts(description: {value: COPYING}))])

          EnrichAuthor.call(author: @author)

          assert_equal ["rejected", false], rows.sole.facts["description"].values_at("reason", "applied")
          assert_equal 0, @author.reload.descriptions.count
        end

        test "violations with no rewrite are rejected" do
          stub_review(style_violations: ["names_author_at_start"], rewritten: nil)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "rejected", rows.sole.facts["description"]["reason"]
        end

        test "a failed or empty review keeps the description out" do
          stub_review(style_violations: [], rewritten: nil, success: false)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "review_failed", rows.sole.facts["description"]["reason"]

          empty = mock
          empty.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {}, ai_chat: @chat))
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.stubs(:new).returns(empty)
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "review_failed", rows.last.facts["description"]["reason"]
        end

        test "an author with an AI description keeps it and the review is skipped" do
          @author.assign_description(source: :ai_generated, content: "Written before.")
          @author.save!
          ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.expects(:new).never
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          assert_equal "already_set", rows.sole.facts["description"]["reason"]
          assert_equal "Written before.", @author.reload.descriptions.sole.content
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/enrich_author_test.rb`
Expected: FAIL (uninitialized constant `EnrichAuthor`).

- [ ] **Step 3: Implement**

Create `app/lib/services/books/authors/enrich_author.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The AI step for one author (spec §9). The facts task runs on the
      # standard role, grounded in the records the author steps matched
      # (MatchedRecords). Web research follows only for an author no
      # authority matched whom the model did not know or knew poorly, within
      # the shared daily cap. The description is checked in code, reviewed
      # on the fast role, and rewritten at most once. One books.author_facts
      # ledger row per task run, skips and failures included; each row that
      # called the model names the records in its input.
      class EnrichAuthor
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.author_facts"
        HUMAN_SOURCES = %w[ai_generated manual].freeze

        def self.call(author:, allow_research: true)
          new(author: author, allow_research: allow_research).call
        end

        def initialize(author:, allow_research:)
          @author = author
          @allow_research = allow_research
          @records = MatchedRecords.new(author)
          @rows = []
        end

        def call
          return skipped("placeholder") if author.exclude_from_rankings?
          return skipped("complete") if complete?

          rows << run(:knowledge)
          return result if rows.last.failed?

          if research_wanted?(rows.last)
            rows << (budget_exhausted? ? skip("budget_exhausted", mode: :research) : run(:research))
          end
          result
        end

        private

        attr_reader :author, :allow_research, :records, :rows

        def skipped(reason)
          rows << skip(reason, mode: :knowledge)
          result
        end

        # Nothing left to fill (spec §9). death_year is left out because a
        # living author has none; "unspecified" is the legacy AI's "don't
        # know", so it counts as blank.
        def complete?
          author.birth_year.present? && ApplyAuthorFacts::GENDERS.include?(author.gender) &&
            author.author_countries.exists? && author.descriptions.any? { |row| HUMAN_SOURCES.include?(row.source) }
        end

        def research_allowed? = allow_research && !records.matched?

        def research_wanted?(row)
          research_allowed? && (row.recognized == false || (row.recognized && row.confidence_low?))
        end

        def budget_exhausted?
          ::Enrichment.research.today.count >= Rails.application.config.x.ai.research_daily_cap
        end

        def run(mode)
          task_result = ::Services::Ai::Tasks::Books::AuthorFactsTask.new(parent: author, records: records, mode: mode).call
          return failed_row(mode, task_result) unless task_result.success?

          facts = task_result.data[:facts].deep_symbolize_keys
          # An empty reply parses to {}; without :recognized there is nothing to act on.
          return failed_row(mode, task_result, error: "empty response") unless facts.key?(:recognized)

          chat = task_result.ai_chat
          citations = Array(task_result.data[:citations])
          confidence = confidence_for(facts[:confidence])

          if facts[:recognized] == false
            return write(mode, chat, outcome: :unrecognized, recognized: false, confidence: confidence,
              facts: unapplied_facts(facts, reason: "unrecognized"), citations: citations)
          end

          # A low-confidence answer about to be checked by research is
          # recorded, not applied, as EnrichBook does: applied first, it would
          # leave research only blanks to fill.
          if mode == :knowledge && confidence == "low" && research_allowed? && !budget_exhausted?
            return write(mode, chat, outcome: :nothing_to_apply, recognized: true, confidence: confidence,
              facts: unapplied_facts(facts, reason: "deferred"), citations: citations)
          end

          description = description_for(facts.dig(:description, :value))
          applied = ApplyAuthorFacts.call(author: author, facts: facts, citations: citations, description: description)
          write(mode, chat, outcome: applied.data[:applied].any? ? :applied : :nothing_to_apply, recognized: true,
            confidence: confidence, facts: applied.data[:facts], citations: citations)
        rescue => e
          # Whatever raises past the task call (a bug in the applier, a
          # constraint) still leaves exactly one row, and the job sees a failure.
          author.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message, facts: sources_fact))
        end

        # nil when there is nothing to review or apply. An author who already
        # has an AI description would get already_set from the applier, so
        # the review call is skipped and that reason is reported directly.
        def description_for(text)
          return nil if text.blank?
          return {text: text, review: nil, reason: "already_set"} if author.descriptions.any? { |row| row.source == "ai_generated" }

          review_description(text)
        end

        # {text:, review:, reason:}; a reason means "do not write". The code
        # check runs first and its findings go to the reviewer, so a draft
        # that fails only the code check still gets its one rewrite (spec
        # §9). The rewrite is checked again; a second failure is rejected. A
        # reply with no style_violations at all is an empty answer, the same
        # as a failed call.
        def review_description(text)
          source = records.lead&.extract
          first = ::Services::Books::DescriptionCheck.call(text, source_text: source)
          review = ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.new(
            parent: author, description: first.data[:text], source_text: source, flagged: first.errors
          ).call
          return {text: first.data[:text], review: nil, reason: "review_failed"} unless review.success?

          data = review.data.to_h.deep_symbolize_keys
          return {text: first.data[:text], review: nil, reason: "review_failed"} if data[:style_violations].nil?

          if (data[:style_violations].any? || first.errors.any?) && data[:rewritten].blank?
            return {text: first.data[:text], review: verdict(data, first), reason: "rejected"}
          end

          final = ::Services::Books::DescriptionCheck.call(data[:rewritten].presence || first.data[:text], source_text: source)
          {text: final.data[:text], review: verdict(data, first, final), reason: final.success? ? nil : "rejected"}
        end

        def verdict(data, first, final = nil)
          {
            "style_violations" => Array(data[:style_violations]),
            "rewritten" => data[:rewritten].present?,
            "check_errors" => first.errors,
            "final_check_errors" => final&.errors
          }.compact
        end

        def write(mode, chat, facts:, **attributes)
          author.enrichments.create!(row_attributes(mode, chat).merge(attributes).merge(facts: facts.merge(sources_fact)))
        end

        # The records whose content went into the task's input (spec §9), so
        # a rejected link can find what it influenced (§12).
        def sources_fact
          {"sources" => {"value" => records.sources, "applied" => false, "reason" => "input"}}
        end

        def row_attributes(mode, chat)
          {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
        end

        def failed_row(mode, task_result, error: task_result.error)
          role = ::Services::Ai::Roles.resolve((mode == :research) ? :research : :standard)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :failed, error: error, provider: role.provider.to_s,
            model: role.model, ai_chat: task_result.ai_chat, facts: sources_fact)
        end

        def skip(reason, mode:)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :skipped, reason: reason)
        end

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          ::Enrichment.confidences.key?(normalized) ? normalized : nil
        end

        # Every fact recorded under its ledger name, none applied.
        def unapplied_facts(facts, reason:)
          facts.except(:recognized, :confidence).to_h do |name, fact|
            entry = fact.is_a?(Hash) ? {"value" => fact[:value], "confidence" => fact[:confidence]} : {"value" => fact, "confidence" => nil}
            [ApplyAuthorFacts::LEDGER_NAMES.fetch(name, name).to_s, entry.merge("applied" => false, "reason" => reason)]
          end
        end

        def result
          failures = rows.select(&:failed?)
          Result.new(success?: failures.empty?, data: {enrichments: rows}, errors: failures.map(&:error))
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/enrich_author_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/authors/enrich_author.rb test/lib/services/books/authors/enrich_author_test.rb
git commit -m "EnrichAuthor: the author AI step, research only for unmatched authors, one ledger row per run

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The deferral marker, `EnrichJob` and its hand-off, and `books:enrich_missing`

**Files:**
- Create: `app/lib/services/books/deferred_enrichment.rb`
- Create (generator): `app/sidekiq/books/authors/enrich_job.rb`, `test/sidekiq/books/authors/enrich_job_test.rb`
- Modify: `lib/tasks/books/enrich.rake`
- Test: `test/lib/services/books/deferred_enrichment_test.rb`, `test/lib/tasks/books_enrich_rake_test.rb`

**Interfaces:**
- Consumes: `EnrichAuthor.call(author:, allow_research:)` (Task 6), `Services::Books::EnrichBook::KIND`, and `Books::EnrichBookJob.perform_async(book_id)`.
- Produces:
  - `Services::Books::DeferredEnrichment`:
    - `.defer!(book)` writes a skipped `books.book_facts` row with reason `REASON`.
    - `.waiting_book_ids(author)` returns the `[Integer]` ids of the author's books whose latest `books.book_facts` row is that deferral.
    - `REASON` = `"deferred_to_authors"`.
  - `Books::Authors::EnrichJob.perform_async(author_id, allow_research = true)` and `Books::Authors::EnrichJob.hand_off(author_id)`.

- [ ] **Step 1: Generate the job**

Run: `bin/rails generate sidekiq:job books/authors/enrich`
Expected: creates `app/sidekiq/books/authors/enrich_job.rb` and `test/sidekiq/books/authors/enrich_job_test.rb`. Both are replaced below.

- [ ] **Step 2: Write the failing tests**

Create `test/lib/services/books/deferred_enrichment_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class DeferredEnrichmentTest < ActiveSupport::TestCase
      def setup
        @author = ::Books::Author.create!(name: "Anna Brenner")
      end

      def book_by_author(title)
        ::Books::Book.create!(title: title).tap { |book| book.book_authors.create!(author: @author, position: 1) }
      end

      test "defer! writes a skipped book facts row with the deferral reason" do
        row = DeferredEnrichment.defer!(book_by_author("The Quiet Year"))

        assert_equal ["books.book_facts", "skipped", "deferred_to_authors"], [row.kind, row.outcome, row.reason]
      end

      test "the waiting books are the author's books whose latest book facts row is the deferral" do
        waiting = book_by_author("The Quiet Year")
        DeferredEnrichment.defer!(waiting)
        enriched_since = book_by_author("Enriched Since")
        DeferredEnrichment.defer!(enriched_since)
        enriched_since.enrichments.create!(kind: EnrichBook::KIND, outcome: :applied)
        book_by_author("Never Waited")
        DeferredEnrichment.defer!(::Books::Book.create!(title: "Someone Else's"))

        assert_equal [waiting.id], DeferredEnrichment.waiting_book_ids(@author)
      end

      test "an author with no books has none waiting" do
        assert_equal [], DeferredEnrichment.waiting_book_ids(@author)
      end
    end
  end
end
```

Replace `test/sidekiq/books/authors/enrich_job_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Authors::EnrichJobTest < ActiveSupport::TestCase
  def setup
    @author = ::Books::Author.create!(name: "Anna Brenner")
    @waiting = ::Books::Book.create!(title: "The Quiet Year")
    @waiting.book_authors.create!(author: @author, position: 1)
    ::Services::Books::DeferredEnrichment.defer!(@waiting)
    @never_waited = ::Books::Book.create!(title: "Never Waited")
    @never_waited.book_authors.create!(author: @author, position: 1)
  end

  def outcome(success)
    ::Services::Books::Authors::EnrichAuthor::Result.new(success?: success, data: {enrichments: []}, errors: success ? [] : ["timeout"])
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::EnrichJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the AI step, then hands on only the books that were waiting" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: true).returns(outcome(true))
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(@never_waited.id).never

    Books::Authors::EnrichJob.new.perform(@author.id)
  end

  test "passes allow_research through" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: false).returns(outcome(true))
    ::Books::EnrichBookJob.stubs(:perform_async)

    Books::Authors::EnrichJob.new.perform(@author.id, false)
  end

  test "a failed run raises so Sidekiq retries it, and hands nothing on yet" do
    ::Services::Books::Authors::EnrichAuthor.stubs(:call).returns(outcome(false))
    ::Books::EnrichBookJob.expects(:perform_async).never

    error = assert_raises(StandardError) { Books::Authors::EnrichJob.new.perform(@author.id) }

    assert_includes error.message, "timeout"
  end

  test "when the retries run out, the waiting books are handed on anyway" do
    ::Books::EnrichBookJob.expects(:perform_async).with(@waiting.id).once

    Books::Authors::EnrichJob.sidekiq_retries_exhausted_block.call({"args" => [@author.id, true]}, StandardError.new("timeout"))
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichAuthor.expects(:call).never
    ::Books::EnrichBookJob.expects(:perform_async).never

    Books::Authors::EnrichJob.new.perform(0)
  end
end
```

Create `test/lib/tasks/books_enrich_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksEnrichRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:enrich_missing")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/enrich.rake").to_s }
    end
    @task = Rake::Task["books:enrich_missing"]
    @task.reenable
  end

  test "a book whose only ledger row defers to its authors is still missing; an enriched one is not" do
    deferred = ::Books::Book.create!(title: "Deferred Book")
    ::Services::Books::DeferredEnrichment.defer!(deferred)
    # An applied run has no reason. A reason filter that is not NULL-safe
    # would drop this row and queue the book again.
    enriched = ::Books::Book.create!(title: "Enriched Book")
    enriched.enrichments.create!(kind: "books.book_facts", outcome: :applied)
    ::Books::EnrichBookJob.stubs(:perform_async)
    ::Books::EnrichBookJob.expects(:perform_async).with(deferred.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(enriched.id).never

    assert_output(/Enqueued/) { @task.invoke("100000") }
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/deferred_enrichment_test.rb test/sidekiq/books/authors/enrich_job_test.rb test/lib/tasks/books_enrich_rake_test.rb`
Expected: FAIL.
- `DeferredEnrichment` is an uninitialized constant.
- The generated job has no hand-off.
- The rake test fails on the deferred book (its deferral row hides it).

- [ ] **Step 4: Implement**

Create `app/lib/services/books/deferred_enrichment.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # A book whose enrichment waits for the authors its import created (spec
    # §10): their countries do not exist yet, and the book's origin country
    # should come from them. The wait is a skipped books.book_facts ledger
    # row; the author chain's last step (Books::Authors::EnrichJob) hands the
    # book on once the author is enriched. Only a book that waited is handed
    # on, never the author's other books (Shane, 2026-09-30).
    class DeferredEnrichment
      REASON = "deferred_to_authors"

      def self.defer!(book)
        book.enrichments.create!(kind: EnrichBook::KIND, outcome: :skipped, reason: REASON)
      end

      # The author's books whose latest books.book_facts row is the
      # deferral: a book enriched since has a newer row.
      def self.waiting_book_ids(author)
        book_ids = author.book_authors.pluck(:book_id)
        return [] if book_ids.empty?

        ::Enrichment.where(enrichable_type: "Books::Book", enrichable_id: book_ids, kind: EnrichBook::KIND)
          .select("DISTINCT ON (enrichable_id) enrichable_id, reason")
          .order(:enrichable_id, created_at: :desc, id: :desc)
          .filter_map { |row| row.enrichable_id if row.reason == REASON }
      end
    end
  end
end
```

Replace `app/sidekiq/books/authors/enrich_job.rb` with:

```ruby
# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichAuthor (spec §9-§11),
# the chain's last step, on the low queue. A failed AI run raises, so
# Sidekiq retries it as it does a book's. The books whose enrichment waited
# for this author (Services::Books::DeferredEnrichment) are then handed on
# to Books::EnrichBookJob: after a successful run, or once the retries are
# exhausted, so the hand-off happens once either way.
class Books::Authors::EnrichJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  sidekiq_retries_exhausted do |job, _exception|
    hand_off(job["args"].first)
  end

  def self.hand_off(author_id)
    author = ::Books::Author.find_by(id: author_id)
    return if author.nil?

    ::Services::Books::DeferredEnrichment.waiting_book_ids(author).each { |book_id| ::Books::EnrichBookJob.perform_async(book_id) }
  end

  def perform(author_id, allow_research = true)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichAuthor.call(author: author, allow_research: allow_research)
    raise StandardError, "Author enrichment failed for author #{author_id}: #{result.errors.join("; ")}" unless result.success?

    self.class.hand_off(author_id)
  end
end
```

In `lib/tasks/books/enrich.rake`, change `enrich_missing`'s description and scope:

```ruby
  desc "Enqueue enrichment for books with no ledger row (a deferral to new authors does not count) and no description: bin/rails books:enrich_missing[100]"
  task :enrich_missing, [:limit] => :environment do |_task, args|
    limit = args[:limit].to_i
    abort "Usage: bin/rails books:enrich_missing[limit] -- a limit is required; running wide is a decision" unless limit.positive?

    # A book whose only rows defer to its new authors (spec §10) is still
    # missing: its author chain may never have reached it. The reason test
    # is NULL-safe on purpose -- where.not(reason:) would also drop every row
    # with no reason, which is most applied runs, and queue those books again.
    ledgered = Enrichment.where(enrichable_type: "Books::Book")
      .where("enrichments.reason IS DISTINCT FROM ?", ::Services::Books::DeferredEnrichment::REASON)
    scope = ::Books::Book
      .where.not(id: ledgered.select(:enrichable_id))
      .where.not(id: Description.where(describable_type: "Books::Book").select(:describable_id))
      .order(:id)
      .limit(limit)
```

The rest of the task (the `pluck`, the enqueue loop and the `puts`) is unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/deferred_enrichment_test.rb test/sidekiq/books/authors/enrich_job_test.rb test/lib/tasks/books_enrich_rake_test.rb`
Expected: PASS.

Mutation check: change the rake's reason test to `.where.not(reason: ::Services::Books::DeferredEnrichment::REASON)`. The rake test must fail on the enriched book. Revert.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/deferred_enrichment.rb app/sidekiq/books/authors/enrich_job.rb lib/tasks/books/enrich.rake \
  test/lib/services/books/deferred_enrichment_test.rb test/sidekiq/books/authors/enrich_job_test.rb test/lib/tasks/books_enrich_rake_test.rb
git commit -m "EnrichJob: run the author AI step, then hand on only the books that waited for it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 8: The chain ends in `EnrichJob`; a VIAF pause hands off at once

**Files:**
- Modify: `app/lib/viaf/exceptions.rb`, `app/lib/viaf/client.rb`
- Modify: `app/sidekiq/books/authors/wikidata_job.rb`, `app/sidekiq/books/authors/viaf_job.rb`
- Test: `test/lib/viaf/client_test.rb`, `test/sidekiq/books/authors/wikidata_job_test.rb`, `test/sidekiq/books/authors/viaf_job_test.rb`

**Interfaces:**
- Consumes: `Books::Authors::EnrichJob.perform_async(author_id)` (Task 7).
- Produces:
  - `Viaf::Exceptions::Paused < RateLimited`, raised for a closed gate, a Cloudflare block and a 429. A busy pace still raises plain `RateLimited`.
  - `WikidataJob` enqueues `EnrichJob` for every outcome except an unmatched run without `via_viaf`, which still goes to `ViafJob`.
  - `ViafJob#perform(author_id, refresh = false, enrich_queued = false)`:
    - A Wikidata hop, when it applies, replaces the `EnrichJob` enqueue.
    - A `Paused` enqueues `EnrichJob` once and reschedules with `enrich_queued = true`.
    - A busy pace only reschedules.

- [ ] **Step 1: Write the failing tests**

In `test/lib/viaf/client_test.rb`:
- In "asks nothing of VIAF while the gate is closed, and carries the wait", change the asserted class to `Viaf::Exceptions::Paused`.
- In "a Cloudflare block closes the gate and becomes RateLimited for the whole pause" and "a 429 pauses every VIAF call through the gate and becomes RateLimited for that pause", do the same, and change "becomes RateLimited" in their names to "becomes Paused".
- In "a busy pace becomes RateLimited with its wait, rounded up", add after the `retry_after` assertion:

```ruby
    assert_not_kind_of Viaf::Exceptions::Paused, error
```

Then add:

```ruby
  test "a pause is a RateLimited, so every rescue of RateLimited still catches it" do
    assert_kind_of Viaf::Exceptions::RateLimited, Viaf::Exceptions::Paused.new("paused", retry_after: 1)
  end
```

Replace `test/sidekiq/books/authors/wikidata_job_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Authors::WikidataJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:tolstoy)
    # Sidekiq runs inline in tests: a real enqueue would run the next step.
    Books::Authors::EnrichJob.stubs(:perform_async)
    Books::Authors::ViafJob.stubs(:perform_async)
  end

  def outcome(value)
    ::Services::Books::Authors::EnrichFromWikidata::Result.new(success?: value != :failed, data: {outcome: value}, errors: [])
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::WikidataJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the Wikidata step for the author" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: @author, refresh: true).returns(outcome(:matched))

    Books::Authors::WikidataJob.new.perform(@author.id, true)
  end

  test "a miss goes on to VIAF, passing refresh through, and not yet to the AI step" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).with(@author.id, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::WikidataJob.new.perform(@author.id, true)
  end

  test "a match, a failure or a skip goes on to the AI step, not VIAF" do
    Books::Authors::ViafJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id).times(3)

    %i[matched failed skipped].each do |value|
      ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(value))
      Books::Authors::WikidataJob.new.perform(@author.id)
    end
  end

  test "a miss on a run VIAF sent here goes to the AI step, never back to VIAF" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id)

    Books::Authors::WikidataJob.new.perform(@author.id, true, true)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::WikidataJob.new.perform(0)
  end

  test "reschedules itself after the wait a rate limit carries, plus jitter, keeping via_viaf" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 120))
    job = Books::Authors::WikidataJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::WikidataJob.expects(:perform_in).with(127, @author.id, true, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    job.perform(@author.id, true, true)
  end
end
```

Replace `test/sidekiq/books/authors/viaf_job_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Authors::ViafJobTest < ActiveSupport::TestCase
  def setup
    @author = books_authors(:tolstoy)
    # Sidekiq runs inline in tests: a real enqueue would run the next step.
    Books::Authors::EnrichJob.stubs(:perform_async)
    Books::Authors::WikidataJob.stubs(:perform_async)
  end

  def outcome(wikidata_qid: nil, needs_review: false)
    decision = stub(needs_review: needs_review)
    ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true,
      data: {outcome: :matched, wikidata_qid: wikidata_qid, decision: decision}, errors: [])
  end

  def job_with_jitter(seconds)
    Books::Authors::ViafJob.new.tap { |job| job.stubs(:rand).returns(seconds) }
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::ViafJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the VIAF step, passing refresh through, then the AI step" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: @author, refresh: true).returns(outcome)
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id)

    Books::Authors::ViafJob.new.perform(@author.id, true)
  end

  test "a newly found Wikidata id sends the author back to Wikidata once, forced, and the AI step waits for that run" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "a Wikidata id from a decision that needs review goes straight to the AI step" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243", needs_review: true))
    Books::Authors::WikidataJob.expects(:perform_async).never
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id)

    Books::Authors::ViafJob.new.perform(@author.id)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(0)
  end

  test "a VIAF pause queues the AI step at once and reschedules itself, remembering that it did" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id).once
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true)

    job_with_jitter(7).perform(@author.id)
  end

  test "a pause on a rescheduled run does not queue the AI step again" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::Paused.new("paused", retry_after: 3600))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(3607, @author.id, false, true)

    job_with_jitter(7).perform(@author.id, false, true)
  end

  test "a busy pace only reschedules, keeping refresh and what was already queued" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(37, @author.id, true, false)

    job_with_jitter(7).perform(@author.id, true)
  end

  test "a rescheduled run that finishes does not queue the AI step a second time" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome)
    Books::Authors::EnrichJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(@author.id, false, true)
  end

  test "a rescheduled run that finds a Wikidata id still sends the author back to Wikidata" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true)

    Books::Authors::ViafJob.new.perform(@author.id, false, true)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/viaf/client_test.rb test/sidekiq/books/authors/`
Expected: FAIL.
- `Viaf::Exceptions::Paused` is an uninitialized constant.
- The jobs never enqueue `EnrichJob`.
- `ViafJob` reschedules with three arguments.

- [ ] **Step 3: Implement**

In `app/lib/viaf/exceptions.rb`, add after `RateLimited`:

```ruby
    # VIAF itself is paused, for every caller: a Cloudflare block, VIAF's
    # own 429, or the day's budget running low (Viaf::Gate). An hour or
    # more, unlike a busy pace (a plain RateLimited), which clears in
    # seconds. The author chain hands off to the AI step on a pause rather
    # than wait for it.
    class Paused < RateLimited; end
```

In `app/lib/viaf/client.rb`:
- Change the three raises of `Exceptions::RateLimited` in `get` that come from the gate: a closed gate, `BlockedError` and a 429. Each now raises `Exceptions::Paused`, keeping its message and `retry_after`.
- The busy-pace rescue (`DistributedRateLimiter::RateLimitExceeded`) keeps raising `Exceptions::RateLimited`.
- Add to the class comment's first paragraph: "A closed gate, a Cloudflare block or a 429 raises Paused, a RateLimited that tells the job VIAF is out for an hour or more; a busy pace raises plain RateLimited."

Replace the body of `app/sidekiq/books/authors/wikidata_job.rb` with:

```ruby
# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromWikidata (spec §11).
# On the low queue: it has no latency requirement, and low is last in the
# strict queue order. Expected failures write a failed ledger row inside the
# runner and do not raise. A rate limit (a 429, maxlag, or our own pace busy
# for longer than the inline wait) reschedules this job rather than holding
# a worker thread. A miss goes on to Books::Authors::ViafJob, unless VIAF sent
# this author here (via_viaf), which would loop. Every other outcome --
# matched, failed, skipped, or a via_viaf miss -- goes on to the AI step,
# Books::Authors::EnrichJob, so every chain ends there.
class Books::Authors::WikidataJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false, via_viaf = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromWikidata.call(author: author, refresh: refresh)
    if result.data[:outcome] == :unmatched && !via_viaf
      ::Books::Authors::ViafJob.perform_async(author_id, refresh)
    else
      ::Books::Authors::EnrichJob.perform_async(author_id)
    end
  rescue ::Wikimedia::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, via_viaf)
  end
end
```

Replace the body of `app/sidekiq/books/authors/viaf_job.rb` with:

```ruby
# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromViaf (spec §8,
# §11), only after a Wikidata miss. On the low queue, not serial.
#
# When the matched cluster named a Wikidata item this run stamped, and the
# VIAF decision itself does not need review, Wikidata runs once more for it
# -- forced, since the earlier miss counts as processed, and with via_viaf,
# so a second miss cannot send the author back here. That run goes on to
# the AI step itself. A decision flagged needs_review is not sent back: the
# Wikidata run's held-id path would treat the stamped id as independent
# evidence and record a certain match, turning an uncertain VIAF pick into
# a certain Wikidata one. Every other run goes on to Books::Authors::EnrichJob.
#
# The chain never waits on VIAF (spec §8). A pause (Viaf::Exceptions::Paused:
# a Cloudflare block, a 429, or the day's budget running low; an hour or
# more) sends the author to the AI step at once and reschedules this job
# with enrich_queued, so later attempts neither queue the AI step again nor
# queue it when they finish. A busy pace clears in seconds, so it only
# reschedules. Facts a late VIAF run finds land as fills.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false, enrich_queued = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromViaf.call(author: author, refresh: refresh)
    if result.data[:wikidata_qid] && !result.data[:decision].needs_review
      ::Books::Authors::WikidataJob.perform_async(author_id, true, true)
    elsif !enrich_queued
      ::Books::Authors::EnrichJob.perform_async(author_id)
    end
  rescue ::Viaf::Exceptions::Paused => e
    ::Books::Authors::EnrichJob.perform_async(author_id) unless enrich_queued
    reschedule(e, author_id, refresh, true)
  rescue ::Viaf::Exceptions::RateLimited => e
    reschedule(e, author_id, refresh, enrich_queued)
  end

  private

  def reschedule(error, author_id, refresh, enrich_queued)
    self.class.perform_in(error.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, enrich_queued)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/viaf/ test/sidekiq/books/authors/ test/lib/services/books/authors/`
Expected: PASS. `EnrichFromViaf`'s own tests still pass, since `Paused` is a `RateLimited` and propagates the same way.

Mutation check: delete `unless enrich_queued` from the `Paused` rescue. "a pause on a rescheduled run does not queue the AI step again" must fail. Revert.

- [ ] **Step 5: Commit**

```bash
git add app/lib/viaf/exceptions.rb app/lib/viaf/client.rb app/sidekiq/books/authors/wikidata_job.rb app/sidekiq/books/authors/viaf_job.rb \
  test/lib/viaf/client_test.rb test/sidekiq/books/authors/wikidata_job_test.rb test/sidekiq/books/authors/viaf_job_test.rb
git commit -m "Author chain: every run ends in EnrichJob; a VIAF pause hands off at once, once

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The book prompt names each author with years and countries

**Files:**
- Modify: `app/lib/services/ai/tasks/books/book_facts_task.rb`
- Test: `test/lib/services/ai/tasks/books/book_facts_task_test.rb`

**Interfaces:**
- Consumes: `Books::Book#book_authors` (`position`), and `Books::Author#birth_year`, `#death_year` and `#countries`.
- Produces: `BookFactsTask`'s user prompt, with one `Author: …` line per stored author in position order. A book with no authors keeps the `Author(s): …` line from the passed names.

- [ ] **Step 1: Write the failing tests**

Add to `BookFactsTaskTest`:

```ruby
          test "each stored author gets a line with the years and countries we hold" do
            books_authors(:tolstoy).author_countries.create!(country: books_countries(:french))

            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "Author: Leo Tolstoy (1828–1910; French)"
            refute_includes prompt, "Author(s):"
          end

          test "authors come in position order, with only the years we know" do
            book = ::Books::Book.create!(title: "Three Hands")
            book.book_authors.create!(author: books_authors(:garnett), position: 2)
            book.book_authors.create!(author: books_authors(:king), position: 1)
            book.book_authors.create!(author: ::Books::Author.create!(name: "Old Anon", death_year: 1500), position: 3)

            prompt = BookFactsTask.new(parent: book).send(:user_prompt)

            assert_includes prompt, "Author: Stephen King (born 1947)\nAuthor: Constance Garnett\nAuthor: Old Anon (died 1500)"
          end

          test "stored authors win over the names the importer passed" do
            prompt = BookFactsTask.new(parent: @book, author_names: ["Someone Else"]).send(:user_prompt)

            assert_includes prompt, "Author: Leo Tolstoy (1828–1910)"
            refute_includes prompt, "Someone Else"
          end
```

The existing "user prompt uses passed author names when the book has none" test must keep passing unchanged.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/book_facts_task_test.rb`
Expected: FAIL. The prompt still reads `Author(s): Leo Tolstoy`.

- [ ] **Step 3: Implement**

In `app/lib/services/ai/tasks/books/book_facts_task.rb`, replace the line in `user_prompt`:

```ruby
            lines << "Author(s): #{author_names.join(", ")}" if author_names.any?
```

with:

```ruby
            lines.concat(author_lines)
```

and add these private methods after `user_prompt`:

```ruby
          # One line per stored author, from what we hold about them (spec
          # §10), so the book's origin countries can follow its authors':
          # "Author: Ernest Hemingway (1899–1961; American)". A book with no
          # authors yet falls back to the names the importer passed.
          def author_lines
            links = parent.book_authors.includes(author: :countries).order(:position, :id).to_a
            return links.map { |link| "Author: #{author_line(link.author)}" } if links.any?
            return ["Author(s): #{author_names.join(", ")}"] if author_names.any?

            []
          end

          def author_line(author)
            details = [life_years(author), author.countries.map(&:name).sort.join(", ").presence].compact
            details.any? ? "#{author.name} (#{details.join("; ")})" : author.name
          end

          def life_years(author)
            birth = author.birth_year
            death = author.death_year
            if birth && death
              "#{birth}–#{death}"
            elsif birth
              "born #{birth}"
            elsif death
              "died #{death}"
            end
          end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/books/ test/lib/services/books/enrich_book_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/ai/tasks/books/book_facts_task.rb test/lib/services/ai/tasks/books/book_facts_task_test.rb
git commit -m "BookFactsTask: one line per stored author with their years and countries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The book importer starts the author chain after the save, and defers to new authors

**Files:**
- Modify: `app/lib/data_importers/books/author/importer.rb`
- Modify: `app/lib/data_importers/books/book/importer.rb`
- Modify: `app/lib/data_importers/books/book/providers/open_library.rb`, `authors.rb`, `ai_enrichment.rb`
- Create: `app/lib/data_importers/books/book/providers/author_enrichment.rb`
- Test: `test/lib/data_importers/books/book/providers/author_enrichment_test.rb` (new), and in the same directory `ai_enrichment_test.rb`, `authors_test.rb`, `open_library_test.rb`; `test/lib/data_importers/books/book/importer_test.rb`

**Interfaces:**
- Consumes: `ImportResult#created?`, `Services::Books::DeferredEnrichment.defer!` (Task 7), and `Books::Authors::WikidataJob.perform_async(author_id)`.
- Produces:
  - `DataImporters::Books::Author::Importer::BOOK_STEP_PROVIDERS` = `%i[open_library]`.
  - `Providers::OpenLibrary.new(client: nil, new_author_ids: [])`, `Providers::Authors.new(new_author_ids: [])` and `Providers::AiEnrichment.new(new_author_ids: [])`.
  - `Providers::AuthorEnrichment.new(new_author_ids: [])`, returning `[:author_enrichment_queued]` or `[]`.
  - `AiEnrichment` reports `[:ai_enrichment_deferred_to_authors]` when it defers.
  - The book importer's providers run in the order OpenLibrary, Authors, AuthorEnrichment, AiEnrichment, sharing one `new_author_ids` array.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/data_importers/books/book/providers/author_enrichment_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AuthorEnrichmentTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @tolstoy = books_authors(:tolstoy)
            @king = books_authors(:king)
          end

          test "queues the Wikidata step once for each author the import created" do
            ::Books::Authors::WikidataJob.expects(:perform_async).with(@tolstoy.id).once
            ::Books::Authors::WikidataJob.expects(:perform_async).with(@king.id).once

            result = AuthorEnrichment.new(new_author_ids: [@tolstoy.id, @king.id, @tolstoy.id]).populate(@book, query: nil)

            assert result.success?
            assert_equal [:author_enrichment_queued], result.data_populated
          end

          test "an import that created no author queues nothing" do
            ::Books::Authors::WikidataJob.expects(:perform_async).never

            result = AuthorEnrichment.new.populate(@book, query: nil)

            assert result.success?
            assert_equal [], result.data_populated
          end

          test "turns an enqueue error into a failure result" do
            ::Books::Authors::WikidataJob.stubs(:perform_async).raises(RedisClient::CannotConnectError, "down")

            result = AuthorEnrichment.new(new_author_ids: [@tolstoy.id]).populate(@book, query: nil)

            refute result.success?
            assert_includes result.errors.first, "Author enrichment provider error"
          end
        end
      end
    end
  end
end
```

Add to `ai_enrichment_test.rb`:

```ruby
          test "defers to a new author this import linked, and records the wait" do
            provider = AiEnrichment.new(new_author_ids: [books_authors(:tolstoy).id])
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = provider.populate(@book, query: @query)

            assert result.success?
            assert_equal [:ai_enrichment_deferred_to_authors], result.data_populated
            assert_equal ["skipped"], @book.enrichments.where(reason: "deferred_to_authors").pluck(:outcome)
          end

          test "a new author not linked to this book does not hold it back" do
            provider = AiEnrichment.new(new_author_ids: [books_authors(:king).id])
            ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false, ["Leo Tolstoy"])

            assert_equal [:ai_enrichment_queued], provider.populate(@book, query: @query).data_populated
          end
```

In `authors_test.rb`:
- Change `result_for` to accept the created flag:

```ruby
          def result_for(author, created: false)
            DataImporters::ImportResult.new(item: author, provider_results: [], success: true, created: created)
          end
```

- Add `providers: [:open_library]` to the two `IMPORTER.expects(:call).with(name: …, work_titles: …)` expectations in "imports each query name by name and links the authors in the query's order".
- Then add:

```ruby
          test "imports without the author's async step and remembers the authors it created, not the ones it matched" do
            ids = []
            created = ::Books::Author.create!(name: "Anna Brenner")
            IMPORTER.expects(:call).with(name: "Anna Brenner", work_titles: ["Hadji Murat"], providers: [:open_library])
              .returns(result_for(created, created: true))
            IMPORTER.expects(:call).with(name: "Leo Tolstoy", work_titles: ["Hadji Murat"], providers: [:open_library])
              .returns(result_for(@tolstoy))

            Providers::Authors.new(new_author_ids: ids).populate(::Books::Book.new(title: "Hadji Murat"), query: query(["Anna Brenner", "Leo Tolstoy"]))

            assert_equal [created.id], ids
          end
```

In `open_library_test.rb`:
- Change `author_result` the same way, to `author_result(author, created: false)` passing `created: created`.
- Add `providers: [:open_library]` to the three `::DataImporters::Books::Author::Importer.expects(:call).with(name: …, open_library_author_key: …, work_titles: …)` expectations.
- Then add:

```ruby
          test "an accept remembers the work authors this import created" do
            ids = []
            provider = Providers::OpenLibrary.new(client: @client, new_author_ids: ids)
            created = ::Books::Author.create!(name: "Anna Brenner")
            stub_resolve(resolve_response(verdict: "accept", record: work_with_authors([["OL77A", "Anna Brenner"], ["OL1A", "Leo Tolstoy"]])))
            ::DataImporters::Books::Author::Importer.expects(:call)
              .with(name: "Anna Brenner", open_library_author_key: "OL77A", work_titles: ["Hadji Murat"], providers: [:open_library])
              .returns(author_result(created, created: true))
            ::DataImporters::Books::Author::Importer.expects(:call)
              .with(name: "Leo Tolstoy", open_library_author_key: "OL1A", work_titles: ["Hadji Murat"], providers: [:open_library])
              .returns(author_result(books_authors(:tolstoy)))

            provider.populate(::Books::Book.new(title: "Hadji Murat"), query: nil)

            assert_equal [created.id], ids
          end
```

In `importer_test.rb`:

1. In "creates and persists a new Books::Book end to end when nothing is found", F. Scott Fitzgerald is a new author, so the book now waits for him.
   - Replace the comment and the `EnrichBookJob.expects(:perform_async).with(instance_of(Integer), false, ["F. Scott Fitzgerald"])` line with:

```ruby
          # F. Scott Fitzgerald is new, so the book waits for his chain
          # instead of being enriched now (spec §10).
          ::Books::EnrichBookJob.expects(:perform_async).never
```

   - Add at the end of that test:

```ruby
          assert_equal [["skipped", "deferred_to_authors"]], result.item.enrichments.pluck(:outcome, :reason)
```

2. Replace "providers run Open Library first, then Authors, then AI enrichment" with:

```ruby
        test "providers run Open Library, Authors, the new authors' chain, then AI enrichment" do
          providers = Importer.new.send(:providers)

          assert_equal [Providers::OpenLibrary, Providers::Authors, Providers::AuthorEnrichment, Providers::AiEnrichment],
            providers.map(&:class)
        end
```

3. Add:

```ruby
        # The race closed by spec §10: the Wikidata step for a new author must
        # see the book among the author's titles, so it is queued only once
        # the book_authors row exists -- and exactly once, not also from the
        # author importer's own async provider.
        test "a new author's chain starts once, after the book and its link are saved, and the book waits for it" do
          stub_resolve_down
          ::Books::EnrichBookJob.expects(:perform_async).never
          ::Books::Authors::WikidataJob.expects(:perform_async)
            .with { |author_id| ::Books::BookAuthor.exists?(author_id: author_id) }.once
          ::Books::Authors::WikidataJob.expects(:perform_async)
            .with { |author_id| !::Books::BookAuthor.exists?(author_id: author_id) }.never

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"])

          assert_includes result.summary[:data_populated], :ai_enrichment_deferred_to_authors
          assert_equal [["skipped", "deferred_to_authors"]], result.item.enrichments.pluck(:outcome, :reason)
        end

        test "a book whose authors all exist is enriched at once, and no author chain starts" do
          stub_resolve_down
          ::Books::Authors::WikidataJob.expects(:perform_async).never
          ::Books::EnrichBookJob.expects(:perform_async).with(anything, false, ["Leo Tolstoy"])

          result = Importer.call(title: "Hadji Murat", author_names: ["Lev Tolstoy"])

          assert_includes result.summary[:data_populated], :ai_enrichment_queued
        end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/`
Expected: FAIL.
- `AuthorEnrichment` is an uninitialized constant.
- The providers do not accept `new_author_ids:`.
- The race test sees `WikidataJob` enqueued before the link exists.

- [ ] **Step 3: Implement**

In `app/lib/data_importers/books/author/importer.rb`, add at the top of the class:

```ruby
        # The providers a book import runs for an author it creates: all but
        # the async Enrichment, which the book importer starts itself once
        # the book and its book_authors rows are saved, so the Wikidata step
        # sees the book among the author's titles (spec §10).
        BOOK_STEP_PROVIDERS = %i[open_library].freeze
```

In `app/lib/data_importers/books/book/providers/open_library.rb`:
- Change `initialize`:

```ruby
          def initialize(client: nil, new_author_ids: [])
            @client = client
            @new_author_ids = new_author_ids
          end
```

- Change the loop in `link_open_library_authors`, and add to its comment: "Each author is imported without its async enrichment; one this import created is remembered in new_author_ids for the providers after this one (spec §10)."

```ruby
            work.author_keys.zip(work.author_names).each_with_index do |(key, name), index|
              imported = ::DataImporters::Books::Author::Importer.call(
                name: name, open_library_author_key: key, work_titles: [book.title].compact_blank,
                providers: ::DataImporters::Books::Author::Importer::BOOK_STEP_PROVIDERS
              )
              author = imported.item
              next unless author&.persisted?

              @new_author_ids << author.id if imported.created?
              next if book.book_authors.any? { |existing| existing.author_id == author.id }

              book.book_authors.build(author: author, position: index + 1)
              linked = true
            end
```

In `app/lib/data_importers/books/book/providers/authors.rb`:
- Add the constructor.
- Change the loop.
- Add to the class comment: "Authors are imported without their async enrichment; one this import created is remembered in new_author_ids."

```ruby
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end
```

```ruby
            names.each_with_index do |name, index|
              imported = ::DataImporters::Books::Author::Importer.call(
                name: name, work_titles: [book.title].compact_blank,
                providers: ::DataImporters::Books::Author::Importer::BOOK_STEP_PROVIDERS
              )
              author = imported.item
              next unless author&.persisted?

              @new_author_ids << author.id if imported.created?
              link(book, author, index + 1)
              linked += 1
            end
```

Create `app/lib/data_importers/books/book/providers/author_enrichment.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Async provider (spec §10): starts the author chain for each author
        # this import created. It runs after Providers::Authors, and the
        # importer saves the book after each successful provider, so the book
        # and its book_authors rows exist when the Wikidata step reads the
        # author's titles. The author importer's own async provider is left
        # out of a book import for that reason (Author::Importer::BOOK_STEP_PROVIDERS).
        class AuthorEnrichment < DataImporters::ProviderBase
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end

          def populate(book, query:, match: nil)
            ids = @new_author_ids.uniq
            return success_result(data_populated: []) if ids.empty?

            ids.each { |author_id| ::Books::Authors::WikidataJob.perform_async(author_id) }
            success_result(data_populated: [:author_enrichment_queued])
          rescue => e
            failure_result(errors: ["Author enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
```

In `app/lib/data_importers/books/book/providers/ai_enrichment.rb`:
- Add the constructor.
- Add the deferral branch after the persisted check.
- Add the private predicate.
- Extend the class comment with: "When a linked author was created by this import, the book waits for that author's chain instead (spec §10): a skipped books.book_facts row records the wait, and Books::Authors::EnrichJob hands the book on."

```ruby
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end

          def populate(book, query:, match: nil)
            return failure_result(errors: ["Book title required for AI enrichment"]) if book.title.blank?

            author_names = book.authors.map(&:name)
            author_names = Array(query&.author_names).map(&:to_s).reject(&:blank?) if author_names.empty?
            return failure_result(errors: ["Book must have an author for AI enrichment"]) if author_names.empty?
            return failure_result(errors: ["Book must be persisted before queuing AI enrichment"]) unless book.persisted?

            if waits_for_new_authors?(book)
              ::Services::Books::DeferredEnrichment.defer!(book)
              return success_result(data_populated: [:ai_enrichment_deferred_to_authors])
            end

            ::Books::EnrichBookJob.perform_async(book.id, false, author_names)

            success_result(data_populated: [:ai_enrichment_queued])
          rescue => e
            failure_result(errors: ["AI enrichment provider error: #{e.message}"])
          end

          private

          # A linked author this import created has no countries yet. An
          # author it created but did not link never hands this book on, so
          # it does not hold the book back.
          def waits_for_new_authors?(book)
            @new_author_ids.intersect?(book.book_authors.map(&:author_id))
          end
```

In `app/lib/data_importers/books/book/importer.rb`, replace `providers` (and its comment) with:

```ruby
        # OpenLibrary first: its fills are free and licensed, and on accept it
        # links the work's authors. Authors next: the query's author names
        # when the book still has none (an abstain, a reject, or the service
        # unreachable). AuthorEnrichment then starts the chain for the
        # authors this import created, after the save that follows Authors,
        # so the chain sees this book among their titles (spec §10).
        # AiEnrichment last, so the AI fills fewer blanks; it defers the book
        # to its new authors' chain when one is linked.
        def providers
          @providers ||= [
            Providers::OpenLibrary.new(new_author_ids: new_author_ids),
            Providers::Authors.new(new_author_ids: new_author_ids),
            Providers::AuthorEnrichment.new(new_author_ids: new_author_ids),
            Providers::AiEnrichment.new(new_author_ids: new_author_ids)
          ]
        end

        # The authors this import created: the author steps add to it, and
        # the providers after them read it.
        def new_author_ids
          @new_author_ids ||= []
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/ test/lib/services/books/ test/sidekiq/books/`
Expected: PASS.

Mutation check: in `Providers::Authors`, drop `providers: …BOOK_STEP_PROVIDERS` from the importer call. The race test must fail on its `never` expectation. Revert.

- [ ] **Step 5: Commit**

```bash
git add app/lib/data_importers/books/ test/lib/data_importers/books/
git commit -m "Book importer: start a new author's chain after the book is saved, and defer the book to it

Closes the race where the author's Wikidata step ran before the book and
its book_authors row existed.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Docs, the spec's amendments, and the full suite

**Files:**
- Modify: `docs/features/books-author-enrichment.md`, `docs/features/books_enrichment.md`, `docs/features/data_importers.md`, `docs/features/viaf-api-client.md`
- Modify: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`

**Interfaces:** documentation only.

- [ ] **Step 1: `docs/features/books-author-enrichment.md`**

1. In the opening paragraph, after "a Wikipedia link,", insert "and a house-style AI description," and change the spec pointer to `§3-§10, §13, §14`.
2. Replace the whole "## The chain today" section, from its heading up to "## Resolution", with:

````markdown
## The chain today

```
Book import (DataImporters::Books::Book::Importer)
  Providers::OpenLibrary, Providers::Authors
      each author through the author importer with BOOK_STEP_PROVIDERS ([:open_library]);
      the ids of authors this import created are collected
  (the book and its book_authors rows are saved)
  Providers::AuthorEnrichment   WikidataJob for each author this import created
  Providers::AiEnrichment       a created author is linked? -> a deferral row, no EnrichBookJob
                                otherwise                 -> EnrichBookJob now
Direct author import (DataImporters::Books::Author::Importer)
  Providers::OpenLibrary, then Providers::Enrichment (enqueues WikidataJob)

Books::Authors::WikidataJob     EnrichFromWikidata
  unmatched, not via_viaf ->    ViafJob
  anything else ->              EnrichJob
Books::Authors::ViafJob         EnrichFromViaf
  new Wikidata id, decision
  doesn't need review ->        WikidataJob(author_id, true, true), which ends in EnrichJob
  otherwise ->                  EnrichJob (unless a pause already queued it)
  VIAF paused ->                EnrichJob at once (once), then reschedule
  VIAF pace busy ->             reschedule only
Books::Authors::EnrichJob       EnrichAuthor, then EnrichBookJob for each book that waited
```

Every chain ends at `EnrichJob`, whatever the Wikidata or VIAF outcome, so a book waiting on its
new author is always handed on. All three jobs run on the `low` queue with `retry: 3`.

**The book importer starts the chain itself.** A book import runs the author importer without its
async provider, collects the authors it created (`ImportResult#created?`), and queues their
`WikidataJob`s from `Providers::AuthorEnrichment`, which runs after the importer has saved the book
and its `book_authors` rows. The Wikidata and VIAF steps therefore always see the book among the
author's titles. (Before increment 4 the author importer's own provider queued the job mid-import,
before that save.) A direct author import still queues `WikidataJob` from
`Providers::Enrichment`.

A VIAF match flagged `needs_review` never sends the author back to Wikidata: the stamped id stays
as VIAF's own, flagged fact rather than evidence for a certain Wikidata match. A VIAF *pause* (a
Cloudflare block, VIAF's 429, or the day's budget running low: `Viaf::Exceptions::Paused`) sends
the author to the AI step at once and reschedules the VIAF job; a busy pace (seconds) only
reschedules. If VIAF answers later with a new Wikidata id, the `via_viaf` Wikidata run ends in a
second `EnrichJob`, which fills only what the first left blank.

An author an admin has flagged `exclude_from_rankings` is skipped by every step without an
external or model call: a `skipped` ledger row with reason `placeholder`.
````

3. Insert before "## Countries":

```markdown
## The AI step

`Services::Books::Authors::EnrichAuthor.call(author:, allow_research: true)` (spec §9), run by
`Books::Authors::EnrichJob`.

**Skips.** A placeholder author, and an author with nothing left to fill: an AI or manual
description, a birth year, a gender other than `unspecified`, and at least one country. There is
no "already processed" check; the data rule already stops a run that could fill nothing.

**Input.** `Services::Ai::Tasks::Books::AuthorFactsTask` (the `standard` role) gets the name,
alternate names, what we already hold, up to 10 of our books (ranked first, with years), and the
records the author steps matched, read by `MatchedRecords` from the latest processed ledger row of
each step and its decision's selected candidate:
- Wikidata: description line, years, occupations, citizenships, works
- VIAF: headings, years (marked "active" when not a life span), nationality codes, occupations,
  works, contributing libraries
- the matched item's English Wikipedia lead (up to 8,000 characters), for facts only

A held identifier alone is never evidence; only a decision is. An author nothing matched gets a
line saying so, telling the model not to assume a better-known namesake.

**Research.** Web search (the `research` role) runs only when neither Wikidata nor VIAF matched,
`allow_research` is true, and the model did not recognize the author or knew them poorly. It
counts against the shared `config.x.ai.research_daily_cap`. A low-confidence knowledge answer
about to be researched is recorded as `deferred`, not applied.

**Applying** (`ApplyAuthorFacts`, fills blanks only through `FactSheet`):
- `birth_year`, `death_year`: Common Era, no later than this year, death no earlier than birth
- `gender`: male, female or non_binary; `unspecified` counts as blank
- countries, from the reported nationalities through `CountryLookup.from_text`, only when the
  author has none
- the description, as `ai_generated`, only when the author has no AI description yet
- any fact the model gave `low` confidence is recorded as `low_confidence`, not applied

**The description.** One paragraph of 60 to 110 words in the house style, not opening with the
author's name, at most one major prize. `Services::Books::DescriptionCheck` checks the draft,
including a copy check against the Wikipedia lead (8 consecutive words in common fails as
`copied`). `AuthorDescriptionReviewTask` (the `fast` role) reviews it for copied phrasing, an
opening name, marketing and the style flags, is told what the code check found, and rewrites it
once. The rewrite is checked again; a second failure is recorded as `rejected` and not written.

## Handing books on

When a book import creates an author and links it, `Providers::AiEnrichment` does not queue
`EnrichBookJob`. It writes a skipped `books.book_facts` row with reason `deferred_to_authors`
(`Services::Books::DeferredEnrichment`) and reports `[:ai_enrichment_deferred_to_authors]`, so
the book's origin country can come from its author's stored nationality.

`EnrichJob` ends by queuing `EnrichBookJob` for each of the author's books whose latest
`books.book_facts` row is that deferral, after a successful run or once its retries are exhausted.
Only books that waited are handed on; the author's other books never are (Shane, 2026-09-30), so a
bulk author run does not become a catalogue-wide book enrichment. `books:enrich_missing` counts a
book whose only rows are deferrals as missing, and picks up any book a chain never reached.
```

4. In "## The ledger", add a paragraph at the end:

```markdown
**The AI step writes `books.author_facts`.** One row per task run (knowledge, then research when it
runs), skips included, with `mode`, `model`, `provider` and `ai_chat` from the chat, as
`books.book_facts` does. Each fact records its value, confidence, whether it was applied and why.
Every row that called the model carries a `sources` fact listing the records in its input
(`[{"source" => "wikidata", "source_id" => "Q7243"}, {"source" => "wikipedia", "source_id" =>
"en:12345"}, {"source" => "viaf", "source_id" => "…"}]`), so a rejected link can find the
descriptions it influenced.
```

5. In "## Operating", add after the VIAF commands:

````markdown
Run the AI step by hand (writes a ledger row; a real model call):

```ruby
Services::Books::Authors::EnrichAuthor.call(author: Books::Author.find(id))
# or, through the job, which also hands on any books waiting for this author:
Books::Authors::EnrichJob.new.perform(author_id)
```
````

and replace the sentence "There is no backfill rake task and no admin button yet -- both are increment 6. Today the only way an author reaches this chain is through the author importer's async provider." with "There is no backfill rake task and no admin button yet -- both are increment 6. Today an author reaches this chain through a book import (`Providers::AuthorEnrichment`) or a direct author import (`Providers::Enrichment`)."

- [ ] **Step 2: `docs/features/books_enrichment.md`**

1. In "## How a book gets enriched", step 1, replace the `Providers::AiEnrichment` bullet with:

```markdown
   - `DataImporters::Books::Book::Providers::AiEnrichment`, last in the importer's provider
     chain. When the import created one of the book's linked authors, it queues nothing: it writes
     a skipped `deferred_to_authors` row, and the author chain's last step
     (`Books::Authors::EnrichJob`) queues the book once the author is enriched, so the book's
     origin country can come from the author's stored nationality. See
     `docs/features/books-author-enrichment.md`, "Handing books on".
```

2. In the same step, change the `books:enrich_missing` description to: "(enqueues books with no ledger row and no description; a `deferred_to_authors` row does not count as a row)".
3. In step 2, after "One call returns `recognized`, …", add: "The prompt carries one line per stored author, from what we hold: `Author: Ernest Hemingway (1899–1961; American)`."

- [ ] **Step 3: `docs/features/data_importers.md`**

1. In the table row for Books / Book, change "OpenLibrary, Authors, AiEnrichment" to "OpenLibrary, Authors, AuthorEnrichment, AiEnrichment".
2. Replace the "#### AI Enrichment (Async)" paragraph with:

```markdown
#### AI Enrichment (Async)
Queues `Books::EnrichBookJob` and returns `[:ai_enrichment_queued]`. Runs last, so the AI fills
fewer blanks. Requires a title and either `book.authors` names (the usual case, since the author
steps run first) or the query's `author_names` when the book still has no authors. When the import
created one of the book's linked authors, it queues nothing: it writes a skipped
`deferred_to_authors` ledger row and returns `[:ai_enrichment_deferred_to_authors]`, and the
author chain hands the book on when the author is enriched. See
`docs/features/books_enrichment.md` and `docs/features/books-author-enrichment.md`.

#### Author Enrichment (Async)
`Providers::AuthorEnrichment` runs after Authors and queues `Books::Authors::WikidataJob` for each
author this import created, returning `[:author_enrichment_queued]`. It runs after the importer
has saved the book and its `book_authors` rows, so the author chain sees the book among the
author's titles.
```

3. In "#### Authors (Sync)", append: "Both author steps call the author importer with `providers: Author::Importer::BOOK_STEP_PROVIDERS` (`[:open_library]`), leaving out its async `Providers::Enrichment`, and collect the ids of the authors the import created for the providers after them."

- [ ] **Step 4: `docs/features/viaf-api-client.md`**

Replace the sentence "A closed gate, a busy pace, or a Cloudflare block all surface the same way: `Viaf::Exceptions::RateLimited`, carrying `retry_after`, which the calling job turns into a reschedule." with:

"A closed gate, a busy pace, a Cloudflare block or a 429 all surface as `Viaf::Exceptions::RateLimited`, carrying `retry_after`, which the calling job turns into a reschedule. The ones that pause VIAF for every caller (the gate, a block, a 429) are raised as its subclass `Viaf::Exceptions::Paused`, so a job can tell an hour-long pause from a pace that clears in seconds: `Books::Authors::ViafJob` hands the author to the AI step at once on a pause."

- [ ] **Step 5: Amend the spec**

In `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`:

1. In §8 "Pacing and failure", replace the last bullet with:

```markdown
- **The chain never waits on VIAF.** A paused `ViafJob` (`Viaf::Exceptions::Paused`: a Cloudflare
  block, a 429, or the day's budget running low) enqueues `EnrichJob` at once, once, and
  reschedules itself. A busy pace only reschedules: it clears in seconds. Facts it finds later land
  as fills only. *(Amended in increment 4.)*
```

2. In §10 "Ordering", replace the first two bullets with:

```markdown
- The book importer runs the author importer without its async provider, collects the authors
  this import created, and enqueues their `WikidataJob`s from `Providers::AuthorEnrichment` after
  the book and its `book_authors` rows are saved, so the chain sees the book's title.
- The book's `Providers::AiEnrichment` checks whether any of the book's linked authors were created
  by this import. If so, it does not enqueue `EnrichBookJob`: it writes a skipped `books.book_facts`
  row with reason `deferred_to_authors` and reports `[:ai_enrichment_deferred_to_authors]`.
- `EnrichJob` ends, after a successful run or once its retries are exhausted, by enqueuing
  `EnrichBookJob` for each of the author's books whose latest `books.book_facts` row is that
  deferral. Only books that waited are handed on, never the author's other books (Shane,
  2026-09-30: an author is created because a book is being added). Every chain reaches `EnrichJob`,
  including after Wikidata or VIAF failures. *(Amended in increment 4.)*
```

   and change the last bullet to: "`books:enrich_missing` catches any book the chain never reached; a deferral row does not count as a ledger row there."

3. In §11's table, change the `ViafJob` row to `(author_id, refresh = false, enrich_queued = false)` with "Enqueues" = "`EnrichJob` (immediately, once, when paused), or `WikidataJob(author_id, true, true)` for a new Wikidata id". Change the `EnrichJob` row's "Enqueues" to "`EnrichBookJob` for the author's books that waited for it".

- [ ] **Step 6: Run the full suite, lint and the Zeitwerk check**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. No new warning lines.

Run: `bundle exec standardrb`
Expected: no offenses. (`--fix` for autocorrectable ones, then re-run.)

Run: `CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

- [ ] **Step 7: Commit**

```bash
git add ../docs/features/books-author-enrichment.md ../docs/features/books_enrichment.md ../docs/features/data_importers.md \
  ../docs/features/viaf-api-client.md ../docs/superpowers/specs/2026-09-27-books-author-importer-design.md
git commit -m "Docs: the author AI step, the book hand-off, and the VIAF pause

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Carried forward to later increments

- **Increment 5 (Reject link):**
  - The `sources` fact on `books.author_facts` rows is how a reject finds the AI descriptions a record influenced.
  - A deprecated AI description still counts as present in `EnrichAuthor`'s skip rule and in `ApplyAuthorFacts`' `already_set`. The reject flow's re-run must let the AI step write a new one.
  - Still open from increment 3: a VIAF reject should cascade to the Wikidata decision it led to.
- **Increment 6 (backfill):**
  - Thread `allow_research: false` through `WikidataJob` and `ViafJob` to `EnrichJob`.
  - Select authors whose latest Wikidata row is `unrecognized` and who have no processed VIAF row, so failed VIAF runs are retried.
  - Size the rescheduling of many paused `ViafJob`s.
  - The backfill hands on no books (Ruling 1), so it costs author AI calls only.
- **Before any production caller of the book importer:** Task 10 closes the race gate. Two decisions recorded after increment 2 remain open: production's `cache_store` (the 30-day Wikidata cache is wiped on every deploy), and a production re-migration losing stamped Wikidata and VIAF ids.

## After the final review: the real-API smoke run (Shane's go-ahead required)

Spec §15 asks for a console smoke run before an API increment merges. This one calls OpenAI: a few cents per author on the `standard` role, about 15 cents per research run. It also writes to the development database. Run it only when Shane says so.

1. Snapshot the dev DB: `bin/snapshot-dev-db.sh --label pre-author-ai-smoke`.
2. Pick about ten authors:
   - three that Wikidata matches with an English Wikipedia article (run `Books::Authors::WikidataJob.new.perform(id)` first if they have no Wikidata row);
   - two that only VIAF matches;
   - three unmatched long-tail authors, which should research;
   - one complete author, which should skip;
   - the placeholder "Unknown" author.
3. For each, run `Services::Books::Authors::EnrichAuthor.call(author: author)`. Print each row's mode, outcome and facts, and the description text.
4. One book import end to end, with Sidekiq stopped:
   - `DataImporters::Books::Book::Importer.call(title: "<a real book>", author_names: ["<an author not in the database>"])`.
   - Check the book's `deferred_to_authors` row, and that `Sidekiq::Queue.new("low")` holds one `WikidataJob` for the new author.
   - Then run the chain's `perform` methods by hand in order, ending with `Books::Authors::EnrichJob.new.perform(author_id)` and the `Books::EnrichBookJob` it queued.
5. Report, for each author:
   - skip, knowledge or research;
   - what was applied, and any conflict;
   - the description, and whether the copy check or the reviewer changed or rejected it;
   - the cost, from `ai_chats`.
