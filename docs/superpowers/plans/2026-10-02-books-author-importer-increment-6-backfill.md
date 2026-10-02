# Books Author Importer — Increment 6: Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Walk the ~71k existing books authors through the Wikidata → VIAF → AI chain with one rake task, after hardening the chain for a run that lasts days.

**Architecture:** Part A (Tasks 1–7) hardens what a 71k-author run leans on:
- one shared ledger module for the two record steps, and a failed row for any unexpected error after a decision;
- cheaper and better-recorded Wikidata resolution;
- an index for stored Wikipedia leads;
- restoring a legacy description that a later match confirms;
- BCE years and one banned-word list in the prompts;
- a Redis cache for the API clients that survives deploys.

Part B (Tasks 8–13) adds the run itself:
- `allow_research` passed down the chain;
- a VIAF start-time line, so a VIAF backlog runs once per job instead of every job retrying together;
- putting back the ids earlier decisions found (after a re-migration);
- `books:authors:enrich[limit]` and `books:authors:enrich_report[since]`.

Part A has no dependency on Part B and can merge as its own PR.

**Tech Stack:** Rails 8.1, Sidekiq 8.1 (low queue), Redis (`REDIS_POOL`, `ActiveSupport::Cache::RedisCacheStore`), PostgreSQL (partial expression index), Minitest 6 + Mocha + WebMock.

**Spec:** `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`. The sections that matter here:
- §13: the backfill and the legacy Wikipedia cleanup.
- §14: re-runs after the re-migration.
- §8: VIAF never holds up the chain.
- §11: jobs and queues.
- §12: rejected runs.
- §16 item 6.

## Global Constraints

- **Working directory.** Run every Rails command from `web-app/`. Docs live in `docs/` at the repo root.
- **Lint and tests.**
  - Lint is `bundle exec standardrb`: never `bin/rubocop`, never brakeman.
  - A clean `bin/rails test` prints no new warning lines.
  - **CI has no Redis.** No test may touch `REDIS_POOL`. Use `Books::OpenLibrary::FakeRedis` (`test/support/books/open_library/fake_redis.rb`), as `Viaf::GateTest` does.
  - Minitest 6: `assert_nil`, never `assert_equal nil, x`.
- **Code style.**
  - Root-anchor `::Books::...` inside `Services::Books::Authors`.
  - Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **External services.**
  - Never text-search Wikipedia.
  - Tests stub every external call. Real Wikidata, VIAF and OpenAI calls happen only in the gated 100-author run after the branch is green, with Shane's go-ahead.
- **Paces** (spec §13, §8). Wikidata: about one author per 6 seconds. VIAF: 2 requests a minute and about 1,000 a day.
- **Sidekiq job args** stay positional JSON scalars. A new arg is appended with a default, so a job already queued under the old arity still runs.
- **Git.** Never `git stash`: set work aside with a WIP commit. Never commit to main.
- **Docs.** No class-level doc files. The feature doc is `docs/features/books-author-enrichment.md`.
- **Generators.** There are no new models, controllers, jobs or components. The one migration comes from `bin/rails generate migration`.
- **E2E.** No Playwright spec: no page or flow changes. The new surface is two rake tasks.

## Decisions beyond the spec

Shane said "let's do increment 6" after these were recommended. They are listed so the plan review can overturn any of them.

1. **The Wikidata and VIAF clients get a Redis cache of their own.** It's `config.x.external_api_cache`: a `RedisCacheStore`, namespace `external-api`, on `REDIS_URL`.
   - **Why not a global `config.cache_store`:** music and games are live, and `Rails.cache` has other users, such as the Amazon client. This mirrors `config.x.rate_limit_store`.
   - **Why a namespace and not a separate database number:** `REDIS_URL` already carries the database number. The namespace also keeps `#clear` from running `flushdb`.
   - **Test:** a `NullStore`, the same as `Rails.cache` there.
2. **Ids are put back per run, not by a separate rake step** (`RestoreIdentifier`, Task 10). Both record steps call it before resolving, so a launch sequence has no extra step to forget.
   - It only carries over a decision that is matched, older than the author row, the latest for that step, not rejected, and either not flagged or reviewed since.
   - It saves almost every API call on a re-run: the stored record answers the held-id stage.
3. **VIAF jobs that must wait take a start time from a line** (`Viaf::Schedule`, Task 9). Start times are 90 seconds apart.
   - A start time more than 10 minutes away hands the AI step on now, the way a pause already does. This keeps spec §8's "the chain never waits on VIAF".
   - Sizing, measured 2026-10-02:
     - VIAF serves 200–300 authors a day.
     - The backfill's Wikidata step produces misses at about 10 authors a minute times the miss rate.
     - At a 30% miss rate the backlog passes 10,000 within two days.
   - Under the current reschedule (retry after about 30–60 seconds), that backlog would fill the low queue with hundreds of jobs a second that cannot run.
4. **The rank before a legacy description was deprecated is not recorded.**
   - All 8,218 legacy Wikipedia author descriptions in dev are at normal rank (measured 2026-10-02).
   - Restoring "preferred" could also collide with `index_descriptions_one_preferred_per_key`.
   - So a restore goes to normal, as `RevertFacts` already does.
   - The inc 3 review note "record the previous rank" is answered by this measurement.
5. **The backfill leaves out authors that already have a chain job waiting in Sidekiq** (scheduled, retrying, or on the low queue). A second run while the first is still scheduled would otherwise queue them twice. The duplicate would write a skipped Wikidata row and then run the AI step again, doubling its cost.
6. **VIAF retries.** An author whose Wikidata step missed and whose VIAF step never finished gets `ViafJob` again. That covers a failure or a lost job. It runs with `enrich_queued = true`, because that author's AI step already ran.
7. **An unexpected error in a record step** (a bug, a constraint) writes one `failed` row (reason `unexpected_error`), tied to the decision if one exists, and the chain goes on.
   - Today it raises, leaving the decision with no ledger row.
   - Each Sidekiq retry would then record yet another decision.
   - There is no error tracker, so the row and the log line are the record.
8. **Prices in the report** are list prices from a 2026-09 research pass, labelled as an estimate. The OpenAI usage page has the bill.
9. **Not in this increment:**
   - stamping deprecated P648 values (open decision 4);
   - un-reject;
   - the two low-severity follow-ups from increment 5;
   - a Wikidata works-truncation flag on the decision (the client only logs it, Task 3).

## Review Focus

1. **A second `books:authors:enrich` while the first is still scheduled** must queue no author twice. Task 11 test: "an author with a chain job already waiting is left out".
2. **A long VIAF backlog must not hold up the AI step,** and must not leave every waiting job retrying on the same short delay. Task 9 tests: the long-line hand-off, and the spacing in `Viaf::ScheduleTest`.
3. **VIAF's `RateLimited` and `Paused` must still propagate** through the new catch-all rescue in `EnrichFromViaf`. They are not `Viaf::Exceptions::Error` subclasses. Task 1 test.
4. **A restored identifier must never come from** a rejected decision, one awaiting review, a decision from this era, or an id another author holds. Task 10 tests.
5. **A legacy description a match restored** must go back to deprecated when that match is rejected. Task 5 test.

---

# Part A — Hardening

### Task 1: One ledger module for the record steps; an unexpected error leaves a failed row

`EnrichFromWikidata` and `EnrichFromViaf` each carry the same `PROCESSED`, `LEDGER_CONFIDENCE`, `processed?` and `write`. The backfill (Task 11) needs the same "processed" rule over every author at once. Move all of it into one module, and add a catch-all that writes a failed row.

**Files:**
- Create: `web-app/app/lib/services/books/authors/ledger_run.rb`
- Modify: `web-app/app/lib/services/books/authors/enrich_from_wikidata.rb`
- Modify: `web-app/app/lib/services/books/authors/enrich_from_viaf.rb`
- Modify: `web-app/app/lib/services/books/authors/matched_records.rb:20-21`
- Test (create): `web-app/test/lib/services/books/authors/ledger_run_test.rb`
- Test (modify): `web-app/test/lib/services/books/authors/enrich_from_wikidata_test.rb`, `web-app/test/lib/services/books/authors/enrich_from_viaf_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::Authors::LedgerRun::PROCESSED` (`%w[applied nothing_to_apply unrecognized]`).
  - `LedgerRun::CONFIDENCE`.
  - `LedgerRun.processed(kind) → ActiveRecord::Relation<Enrichment>`: every author's done rows of that kind.
  - Private instance methods, for a class that includes the module and defines `KIND`, `PROVIDER`, `author` and `@decision`:
    - `processed? → Boolean`;
    - `write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil) → Enrichment`;
    - `unexpected(error, facts: {}) → Enrichment`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing module test**

Create `web-app/test/lib/services/books/authors/ledger_run_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class LedgerRunTest < ActiveSupport::TestCase
        KIND = EnrichFromWikidata::KIND

        def author(name) = ::Books::Author.create!(name: name)

        def row(author, outcome, kind: KIND, at: author.created_at + 1.minute, decision: nil)
          author.enrichments.create!(kind: kind, outcome: outcome, match_decision: decision, created_at: at)
        end

        def processed_ids(kind = KIND) = LedgerRun.processed(kind).pluck(:enrichable_id).sort

        test "a done outcome counts; a failed or skipped row does not" do
          done = author("Done").tap { |a| row(a, :unrecognized) }
          failed = author("Failed").tap { |a| row(a, :failed) }
          skipped = author("Skipped").tap { |a| row(a, :skipped) }

          assert_equal [done.id], processed_ids & [done.id, failed.id, skipped.id]
        end

        test "only a row newer than its own author row counts (a re-migrated author starts again)" do
          remigrated = author("Re-migrated").tap { |a| row(a, :applied, at: a.created_at - 1.day) }
          current = author("Current").tap { |a| row(a, :applied) }

          assert_equal [current.id], processed_ids & [remigrated.id, current.id]
        end

        test "a row whose decision a person rejected does not count; a row with no decision does" do
          rejected = author("Rejected")
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: rejected, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q1"}], selected_index: 1)
          row(rejected, :applied, decision: decision)
          undecided = author("No decision").tap { |a| row(a, :unrecognized) }

          assert_equal [undecided.id], processed_ids & [rejected.id, undecided.id]
        end

        test "only rows of the kind asked for" do
          wikidata = author("Wikidata").tap { |a| row(a, :applied) }
          viaf = author("VIAF").tap { |a| row(a, :applied, kind: EnrichFromViaf::KIND) }

          assert_equal [[wikidata.id], [viaf.id]],
            [processed_ids & [wikidata.id, viaf.id], processed_ids(EnrichFromViaf::KIND) & [wikidata.id, viaf.id]]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Add the failing runner tests**

In `web-app/test/lib/services/books/authors/enrich_from_wikidata_test.rb`, add before the final `end`s:

```ruby
        test "an unexpected error after the decision writes one failed row tied to it, and does not raise" do
          ApplyWikidata.stubs(:call).raises(RuntimeError, "boom")

          result = enrich

          row = rows.sole
          assert_equal [:failed, false], [result.data[:outcome], result.success?]
          assert_equal ["failed", "unexpected_error", "RuntimeError: boom"], [row.outcome, row.reason, row.error]
          assert_equal result.data[:decision], row.match_decision
          assert result.data[:decision].persisted?
        end
```

In `web-app/test/lib/services/books/authors/enrich_from_viaf_test.rb`, add:

```ruby
        test "an unexpected error after the decision writes one failed row tied to it, and does not raise" do
          ApplyViaf.stubs(:call).raises(RuntimeError, "boom")

          result = run_viaf

          row = rows.sole
          assert_equal [:failed, false], [result.data[:outcome], result.success?]
          assert_equal ["failed", "unexpected_error", "RuntimeError: boom"], [row.outcome, row.reason, row.error]
          assert_equal result.data[:decision], row.match_decision
        end

        # Viaf::Exceptions::RateLimited (and Paused, its subclass) are not
        # Viaf::Exceptions::Error: they are requests to wait, and ViafJob
        # turns them into a reschedule. The catch-all must not swallow them.
        test "a pause propagates past the catch-all and writes nothing" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::Paused.new("paused", retry_after: 3600)})

          assert_raises(::Viaf::Exceptions::Paused) { run_viaf(client: client) }
          assert_empty rows
        end
```

The existing test "a rate limit propagates and writes nothing, so the rescheduled run starts clean" already covers plain `RateLimited`, and must stay green.

- [ ] **Step 3: Run the tests to see them fail**

Run: `bin/rails test test/lib/services/books/authors/ledger_run_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb test/lib/services/books/authors/enrich_from_viaf_test.rb`

Expected:
- `ledger_run_test.rb` errors with `NameError: uninitialized constant Services::Books::Authors::LedgerRun`.
- Both "unexpected error" tests error with `RuntimeError: boom`.

- [ ] **Step 4: Create the module**

Create `web-app/app/lib/services/books/authors/ledger_run.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # What the Wikidata and VIAF steps share about their ledger rows (spec
      # §11, §12, §14). A run writes at most one row of its class's KIND,
      # tied to the run's decision (@decision) once one exists.
      #
      # "Processed" is a row with a done outcome, newer than the author row
      # (after the production re-migration an author is re-created with its
      # id and starts again), whose decision no person rejected. A row with
      # no decision counts, so the verdict comparison is NULL-safe.
      #
      # An including class defines KIND, PROVIDER and `author`, and sets
      # @decision when its resolver records one.
      module LedgerRun
        PROCESSED = %w[applied nothing_to_apply unrecognized].freeze
        CONFIDENCE = {"certain" => "high", "high" => "high", "medium" => "medium", "low" => "low"}.freeze

        # Every author's done rows of this kind: the backfill's selection
        # (Backfill) and one author's own check (#processed?) read the same rule.
        def self.processed(kind)
          ::Enrichment.for_kind(kind).where(enrichable_type: "Books::Author", outcome: PROCESSED)
            .joins("INNER JOIN books_authors ON books_authors.id = enrichments.enrichable_id")
            .where("enrichments.created_at > books_authors.created_at")
            .left_joins(:match_decision)
            .where("match_decisions.verdict IS DISTINCT FROM ?", ::MatchDecision.verdicts[:rejected])
        end

        private

        def processed? = LedgerRun.processed(self.class::KIND).where(enrichable_id: author.id).exists?

        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          author.enrichments.create!(
            kind: self.class::KIND, provider: self.class::PROVIDER, outcome: outcome, reason: reason, recognized: recognized,
            confidence: CONFIDENCE[@decision&.confidence], facts: facts, citations: citations,
            error: error, match_decision: @decision
          )
        end

        # An error no rescue above expected (a bug, a constraint): one failed
        # row, tied to the decision if one was recorded, so no decision is
        # left without its run, and the author is tried again next time.
        # Raising instead would have Sidekiq retry the whole run, recording a
        # new decision each time.
        def unexpected(error, facts: {})
          Rails.logger.error("#{self.class.name}: author #{author.id}: #{error.class.name}: #{error.message}")
          write(outcome: :failed, reason: "unexpected_error", error: "#{error.class.name}: #{error.message}", facts: facts)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Use it in `EnrichFromWikidata`**

In `web-app/app/lib/services/books/authors/enrich_from_wikidata.rb`:

1. Add `include LedgerRun` as the first line inside `class EnrichFromWikidata`.
2. Delete the `PROCESSED` and `LEDGER_CONFIDENCE` constants.
3. Delete the private `processed?` method and its comment, and the private `write` method.
4. Add a final rescue to `call`, after the `rescue ::Wikimedia::Exceptions::Error => e` clause:

```ruby
        rescue => e
          finish(:failed, unexpected(e, facts: @facts || {}))
        end
```

5. In the class comment, after "A Wikimedia failure writes a failed row and returns.", add the sentence: "So does any other error once the run has started (LedgerRun#unexpected)."

`rescue ::Wikimedia::Exceptions::RateLimited` re-raises inside its own clause. A raise from one rescue clause is never caught by a sibling clause, so the rate limit still reaches the job.

- [ ] **Step 6: Use it in `EnrichFromViaf`**

In `web-app/app/lib/services/books/authors/enrich_from_viaf.rb`:

1. Add `include LedgerRun` as the first line inside `class EnrichFromViaf`.
2. Delete `PROCESSED`, `LEDGER_CONFIDENCE`, the private `processed?` with its comment, and `write`.
3. Replace the single `rescue ::Viaf::Exceptions::Error => e` clause with:

```ruby
        rescue ::Viaf::Exceptions::RateLimited
          # A busy pace or a pause (Paused is a RateLimited) is a request to
          # wait, not a failure, and neither is a Viaf::Exceptions::Error:
          # without this clause the catch-all below would swallow it.
          raise
        rescue ::Viaf::Exceptions::Error => e
          finish(:failed, write(outcome: :failed, reason: "viaf_error", error: "#{e.class.name.demodulize}: #{e.message}"))
        rescue => e
          finish(:failed, unexpected(e))
        end
```

- [ ] **Step 7: Point `MatchedRecords` at the module**

In `web-app/app/lib/services/books/authors/matched_records.rb`, replace:

```ruby
        # The same "done" outcomes for both steps.
        PROCESSED = EnrichFromWikidata::PROCESSED
```

with:

```ruby
        # The same "done" outcomes for both steps.
        PROCESSED = LedgerRun::PROCESSED
```

- [ ] **Step 8: Run the tests**

Run:

```bash
bin/rails test test/lib/services/books/authors/
bin/rails test test/sidekiq/books/authors/
```

Expected: all pass.

Then:

```bash
grep -rn "PROCESSED\|LEDGER_CONFIDENCE" app test | grep -v ledger_run
```

Expected: only `matched_records.rb`.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/ test/lib/services/books/authors/
git add app/lib/services/books/authors/ledger_run.rb app/lib/services/books/authors/enrich_from_wikidata.rb app/lib/services/books/authors/enrich_from_viaf.rb app/lib/services/books/authors/matched_records.rb test/lib/services/books/authors/ledger_run_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb test/lib/services/books/authors/enrich_from_viaf_test.rb
git commit -m "Author steps: one ledger module; an unexpected error leaves a failed row

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Fold the letters NFD leaves whole (ł ø æ œ ß đ ð þ ı)

Name keys drop diacritics through NFD. Some letters are not composed characters, so they survive it. Today "Stanislaw Lem" never matches the Wikidata label "Stanisław Lem" by name, and a held id with that label falls through to search and the AI.

**Files:**
- Create: `web-app/app/lib/services/text/name_folder.rb`
- Modify: `web-app/app/lib/services/books/authors/resolve_wikidata.rb` (`name_key`)
- Modify: `web-app/app/lib/services/books/authors/viaf_names.rb` (`words`)
- Modify: `web-app/app/lib/services/books/authors/resolve_viaf.rb` (`title_key`)
- Test (create): `web-app/test/lib/services/text/name_folder_test.rb`
- Test (modify): `web-app/test/lib/services/books/authors/resolve_wikidata_test.rb`, `web-app/test/lib/services/books/authors/viaf_names_test.rb`

**Interfaces:**
- Produces: `Services::Text::NameFolder.call(text) → String`. The result is lowercased, with marks removed and the letters in `NameFolder::LETTERS` transliterated. `nil` gives `""`.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/services/text/name_folder_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Text
    class NameFolderTest < ActiveSupport::TestCase
      test "drops case and diacritics" do
        assert_equal "gabriel garcia marquez", NameFolder.call("Gabriel García Márquez")
      end

      test "transliterates the letters NFD leaves whole" do
        {
          "Stanisław Lem" => "stanislaw lem",
          "Søren Kierkegaard" => "soren kierkegaard",
          "Ærø" => "aero",
          "Œuvres" => "oeuvres",
          "Straße" => "strasse",
          "Þórbergur Þórðarson" => "thorbergur thordarson",
          "Đorđe" => "dorde",
          "Işık" => "isik"
        }.each { |text, folded| assert_equal folded, NameFolder.call(text), text }
      end

      test "nil folds to an empty string" do
        assert_equal "", NameFolder.call(nil)
      end
    end
  end
end
```

In `web-app/test/lib/services/books/authors/resolve_wikidata_test.rb`, add after "names are compared with case and diacritics folded":

```ruby
        test "names are compared with the letters NFD leaves whole transliterated" do
          author = ::Books::Author.create!(name: "Stanislaw Lem")
          author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q6530")
          client = FakeWikidataClient.new(entities: {"Q6530" => wikidata_entity("Q6530", label: "Stanisław Lem")})
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.expects(:new).never

          result = ResolveWikidata.call(author: author, client: client)

          assert_equal ["matched", "identifier"], [result.data[:decision].outcome, result.data[:decision].decided_by]
        end
```

In `web-app/test/lib/services/books/authors/viaf_names_test.rb`, add:

```ruby
      test "a name written with ł is the same name written with l" do
        assert ViafNames.same?("Stanislaw Lem", "Lem, Stanisław")
      end
```

Match the enclosing module nesting of that file: open it first and add the test inside its test class.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/text/name_folder_test.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/services/books/authors/viaf_names_test.rb`

Expected:
- `NameFolderTest` errors with `NameError` (uninitialized constant).
- The resolver test fails with an unexpected invocation of `SelectExternalRecordTask.new`.
- The `ViafNames` test fails.

- [ ] **Step 3: Create the folder**

Create `web-app/app/lib/services/text/name_folder.rb`:

```ruby
module Services
  module Text
    # Folds a name or title to the key its spellings share: case and
    # diacritics dropped ("García" is "garcia"), and the letters Unicode
    # does not compose from a base letter and a mark transliterated the way
    # plain-Latin labels spell them. NFD alone leaves "Stanisław" and
    # "Stanislaw" different.
    class NameFolder
      LETTERS = {
        "ł" => "l", "ø" => "o", "æ" => "ae", "œ" => "oe", "ß" => "ss",
        "đ" => "d", "ð" => "d", "þ" => "th", "ı" => "i"
      }.freeze
      PATTERN = Regexp.union(LETTERS.keys)

      def self.call(text)
        text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(PATTERN, LETTERS)
      end
    end
  end
end
```

`downcase` runs before the transliteration, so capitals (Ł Ø Æ Œ ẞ Đ Ð Þ) are covered by the lowercase keys.

- [ ] **Step 4: Use it in the three callers**

In `resolve_wikidata.rb`, replace the body of `name_key`:

```ruby
        # Case, diacritics and the letters NFD leaves whole folded:
        # "Gabriel Garcia Marquez" meets "Gabriel García Márquez", "Stanislaw" meets "Stanisław".
        def name_key(text)
          ::Services::Text::NameFolder.call(normalized(text))
        end
```

In `viaf_names.rb`, in `words`, replace:

```ruby
          normalized.gsub(PARENTHESISED, " ").unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.scan(/\p{L}+/)
```

with:

```ruby
          ::Services::Text::NameFolder.call(normalized.gsub(PARENTHESISED, " ")).scan(/\p{L}+/)
```

In `resolve_viaf.rb`, in `title_key`, replace:

```ruby
          ::Services::Text::QuoteNormalizer.call(main).to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.squish
```

with:

```ruby
          ::Services::Text::NameFolder.call(::Services::Text::QuoteNormalizer.call(main)).squish
```

Also update the `words` comment in `viaf_names.rb` from "Letters-only words, case and diacritics folded, in order." to "Letters-only words, folded by Services::Text::NameFolder, in order."

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/services/text/ test/lib/services/books/authors/`

Expected: all pass.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/services/text/name_folder.rb app/lib/services/books/authors/ test/lib/services/text/ test/lib/services/books/authors/
git add app/lib/services/text/name_folder.rb app/lib/services/books/authors/resolve_wikidata.rb app/lib/services/books/authors/viaf_names.rb app/lib/services/books/authors/resolve_viaf.rb test/lib/services/text/name_folder_test.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/services/books/authors/viaf_names_test.rb
git commit -m "Author matching: transliterate the letters NFD leaves whole

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Wikidata resolution — one entities call for every name, a labels failure recorded, a truncated works query logged

**Files:**
- Modify: `web-app/app/lib/services/books/authors/resolve_wikidata.rb` (`search_stage`, `labels`, `record`)
- Modify: `web-app/app/lib/wikidata/client.rb` (`works`)
- Modify: `web-app/test/support/fake_wikidata_client.rb` (a `labels_error:` option)
- Test (modify): `web-app/test/lib/services/books/authors/resolve_wikidata_test.rb`, `web-app/test/lib/wikidata/client_test.rb`

**Interfaces:**
- Produces:
  - `FakeWikidataClient.new(labels_error: exception)`. `#labels` raises it after recording the call.
  - A decision's `sources_failed` can now hold `"wikidata_labels"`.

- [ ] **Step 1: Give the fake a labels failure**

In `web-app/test/support/fake_wikidata_client.rb`, add `labels_error: nil` to `FakeWikidataClient#initialize`'s keyword list. Store it with `@labels_error = labels_error`, and change `labels` to:

```ruby
  def labels(ids)
    @calls << [:labels, ids]
    raise @labels_error if @labels_error

    @labels.slice(*ids)
  end
```

- [ ] **Step 2: Write the failing resolver tests**

In `resolve_wikidata_test.rb`, add:

```ruby
        test "searches each name but fetches every hit in one entities call" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"], "Lev Tolstoy" => ["Q7243", "Q1"], "Lev Nikolayevich Tolstoy" => ["Q2"]},
            entities: {
              "Q7243" => wikidata_entity("Q7243", **TOLSTOY),
              "Q1" => wikidata_entity("Q1", label: "Lev Tolstoy", types: ["Q11424"]),
              "Q2" => wikidata_entity("Q2", label: "Lev Nikolayevich Tolstoy", types: ["Q11424"])
            },
            works: {"Q7243" => ["War and Peace"]}
          )

          resolve(client)

          assert_equal [[:entities, ["Q7243", "Q1", "Q2"]]], client.calls.select { |call| call.first == :entities }
          assert_equal 3, client.calls.count { |call| call.first == :search }
        end

        test "a labels failure the AI saw is recorded and lowers a high answer to medium" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"]},
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, occupations: ["Q36180"])},
            labels_error: ::Wikimedia::Exceptions::HttpError.new("boom", 500)
          )
          ai_selects(1, confidence: "high")

          decision = resolve(client).data[:decision]

          assert_equal ["wikidata_labels"], decision.sources_failed
          assert_equal ["ai", "medium", true], [decision.decided_by, decision.confidence, decision.needs_review]
        end

        test "a labels failure after a rule decided is recorded without lowering the rule's confidence" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"]},
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, occupations: ["Q36180"])},
            works: {"Q7243" => ["War and Peace"]},
            labels_error: ::Wikimedia::Exceptions::HttpError.new("boom", 500)
          )

          decision = resolve(client).data[:decision]

          assert_equal ["wikidata_labels"], decision.sources_failed
          assert_equal ["rule", "high", false], [decision.decided_by, decision.confidence, decision.needs_review]
        end
```

The fixture author `tolstoy` holds no Wikidata or Open Library id, so these runs reach the search stage. Its three names are "Leo Tolstoy" and the alternates "Lev Tolstoy" and "Lev Nikolayevich Tolstoy".

- [ ] **Step 3: Write the failing client test**

In `web-app/test/lib/wikidata/client_test.rb`, add:

```ruby
    test "works logs a warning when the answer fills the row limit, since titles were cut" do
      rows = Array.new(Client::WORKS_ROW_LIMIT) do |index|
        {"author" => {"value" => "http://www.wikidata.org/entity/Q7243"}, "workLabel" => {"value" => "Work #{index}"}}
      end
      stub_request(:post, SPARQL).to_return(json_response({results: {bindings: rows}}.to_json))
      Rails.logger.expects(:warn).with { |message| message.include?("#{Client::WORKS_ROW_LIMIT}-row limit") }.once

      assert_equal Client::WORKS_ROW_LIMIT, @client.works(["Q7243"])["Q7243"].size
    end

    test "works logs nothing when the answer is under the row limit" do
      stub_request(:post, SPARQL).to_return(json_response(fixture("sparql_works_Q7243.json")))
      Rails.logger.expects(:warn).never

      @client.works(["Q7243"])
    end
```

- [ ] **Step 4: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/wikidata/client_test.rb`

Expected:
- The entities test fails: three entities calls are recorded.
- Both labels tests fail: `sources_failed` is `[]`.
- The row-limit test fails: `warn` is not called.

- [ ] **Step 5: Implement**

In `resolve_wikidata.rb`:

1. Replace the first line of `search_stage`:

```ruby
          search_names.each { |name| gather(@client.search(name).map { |hit| hit["id"] }, "name_search") }
```

with:

```ruby
          # One search per name, then every hit's entity in one call.
          gather(search_names.flat_map { |name| @client.search(name).map { |hit| hit["id"] } }, "name_search")
```

2. In `labels`, inside the `rescue ::Wikimedia::Exceptions::Error => e` branch, add `@sources_failed << "wikidata_labels"` before the `{}`. Then update the comment above `labels` to: "Evidence labels only: a failure leaves them out, never the run, and is recorded in sources_failed."

3. In `record`, settle the confidence before the snapshots are built, and build them once. Replace the start of `record` up to `decision = ::MatchDecision.create!(`:

```ruby
        def record(verdict)
          ordered = ordered_persons + (@candidates.values - persons)
          confidence = verdict.confidence
          confidence = :medium if confidence == :high && @sources_failed.any?
          decision = ::MatchDecision.create!(
```

with:

```ruby
        def record(verdict)
          ordered = ordered_persons + (@candidates.values - persons)
          # Settled before the snapshots read labels: a labels failure there
          # only blanks evidence shown on the audit page, which no rule used.
          # One the AI saw (describe) is already in @sources_failed by now.
          confidence = verdict.confidence
          confidence = :medium if confidence == :high && @sources_failed.any?
          snapshots = ordered.map { |candidate| snapshot(candidate) }
          decision = ::MatchDecision.create!(
```

Then change `candidates: ordered.map { |candidate| snapshot(candidate) },` inside the `create!` to `candidates: snapshots,`.

In `web-app/app/lib/wikidata/client.rb`, in `works`, replace:

```ruby
      bindings(@http.sparql(SPARQL_URL, query)).each_with_object({}) do |row, found|
```

with:

```ruby
      rows = bindings(@http.sparql(SPARQL_URL, query))
      if rows.size >= WORKS_ROW_LIMIT
        Rails.logger.warn("Wikidata::Client#works: #{rows.size} rows filled the #{WORKS_ROW_LIMIT}-row limit for " \
          "#{ids.join(", ")}; titles past it were cut")
      end
      rows.each_with_object({}) do |row, found|
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/books/authors/ test/lib/wikidata/`

Expected: all pass.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/resolve_wikidata.rb app/lib/wikidata/client.rb test/support/fake_wikidata_client.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/wikidata/client_test.rb
git add app/lib/services/books/authors/resolve_wikidata.rb app/lib/wikidata/client.rb test/support/fake_wikidata_client.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/wikidata/client_test.rb
git commit -m "Wikidata resolution: one entities call per search, labels failures recorded, cut works logged

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Index stored Wikipedia leads by language and title

`WikipediaLead.fetch` finds a stored lead with `payload->>'language' = ? AND payload->>'title' = ?`, so today every lookup scans every stored lead. The backfill adds about one lead per matched author.

**Files:**
- Create: `web-app/db/migrate/<timestamp>_add_wikipedia_title_index_to_external_records.rb`, generated
- Modify: `web-app/db/schema.rb`, by `db:migrate`
- Modify: `web-app/app/models/external_record.rb` (annotation block, by annotaterb)
- Test (modify): `web-app/test/models/external_record_test.rb`

**Interfaces:** none.

- [ ] **Step 1: Write the failing test**

In `web-app/test/models/external_record_test.rb`, add inside the test class:

```ruby
  # WikipediaLead.fetch reads stored leads by language and title. The
  # index's WHERE names the wikipedia source by its enum value, so a
  # renumbered enum would leave it indexing the wrong rows.
  test "stored Wikipedia leads are indexed by language and title" do
    index = ActiveRecord::Base.connection.indexes(:external_records)
      .find { |candidate| candidate.name == "index_external_records_on_wikipedia_language_and_title" }

    assert index, "the index is missing"
    assert_equal "(source = 2)", index.where
    assert_equal 2, ExternalRecord.sources["wikipedia"]
  end
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/models/external_record_test.rb`

Expected: FAIL with "the index is missing".

- [ ] **Step 3: Generate and write the migration**

Run: `bin/rails generate migration AddWikipediaTitleIndexToExternalRecords`

Replace the generated file's body with:

```ruby
class AddWikipediaTitleIndexToExternalRecords < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction. Every author step reads
  # and writes external_records, so a plain CREATE INDEX would block them
  # for the build.
  disable_ddl_transaction!

  # Services::Books::Authors::WikipediaLead finds a stored lead by the
  # language and title inside its payload; without this every lookup scans
  # every stored lead. Partial: only wikipedia rows (source 2) carry those
  # keys. Raw SQL, because add_index has no form for two expressions.
  def up
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS index_external_records_on_wikipedia_language_and_title
      ON external_records ((payload ->> 'language'), (payload ->> 'title'))
      WHERE source = 2
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_external_records_on_wikipedia_language_and_title"
  end
end
```

- [ ] **Step 4: Migrate**

Run: `bin/rails db:migrate`

This migrates the shared development database (additive, an index only) and dumps `db/schema.rb`. Check that the `external_records` block of `db/schema.rb` gained a line like:

```ruby
    t.index "((payload ->> 'language'::text)), ((payload ->> 'title'::text))", name: "index_external_records_on_wikipedia_language_and_title", where: "(source = 2)"
```

If annotaterb errors on the legacy database connection, re-run with `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`. Then check that the schema dump still happened. Revert any `db/schema.rb` hunk unrelated to this index; the dev database is shared with other worktrees.

- [ ] **Step 5: Run the test**

Run: `bin/rails test test/models/external_record_test.rb test/lib/services/books/authors/`

Expected: all pass. The test database is rebuilt from the schema.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb db/migrate/ test/models/external_record_test.rb
git add db/migrate/*_add_wikipedia_title_index_to_external_records.rb db/schema.rb app/models/external_record.rb test/models/external_record_test.rb
git commit -m "Index stored Wikipedia leads by language and title

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(`app/models/external_record.rb` only if annotaterb changed its annotation.)

---

### Task 5: A later match restores a legacy description an earlier miss deprecated

When an author's first Wikidata run misses, `CleanLegacyWikipedia` deprecates every legacy Wikipedia description (`author_unmatched`). When a later run matches, such as the forced Wikidata run after VIAF found the item, it only judges rows still active. A description that was the matched person's article all along stays deprecated forever (inc 3 review, I3).

**Files:**
- Modify: `web-app/app/lib/services/books/authors/clean_legacy_wikipedia.rb`
- Modify: `web-app/app/lib/services/books/authors/revert_facts.rb` (`restore_legacy` becomes `undo_legacy`)
- Test (modify): `web-app/test/lib/services/books/authors/clean_legacy_wikipedia_test.rb`, `web-app/test/lib/services/books/authors/revert_facts_test.rb`, `web-app/test/lib/services/books/authors/enrich_from_wikidata_test.rb`

**Interfaces:**
- Produces two new verdicts in a `legacy_wikipedia` fact's `value` entries:
  - `"restored"`: the row went back to normal rank;
  - `"left_deprecated"`: it was judged again and stays deprecated.
- The fact's `reason` is `"deprecated"` if any row was deprecated, else `"restored"` if any was restored, else `"kept"`. `applied` is true when any row changed.

- [ ] **Step 1: Write the failing cleanup tests**

In `clean_legacy_wikipedia_test.rb`, add a helper below `clean`:

```ruby
        def unmatched_run(fact) = @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :unrecognized, facts: {"legacy_wikipedia" => fact})
```

Then add these tests:

```ruby
        test "a description deprecated because no one matched is restored when a later run matches its item" do
          row = legacy("https://en.wikipedia.org/wiki/Michael_Harriot")
          unmatched_run(clean(nil))
          assert row.reload.deprecated?

          fact = clean(@entity)

          assert row.reload.normal?
          assert_equal ["restored", "sitelink"], fact["value"].sole.values_at("verdict", "why")
          assert_equal ["restored", true], fact.values_at("reason", "applied")
        end

        test "one deprecated because no one matched stays deprecated when the match is a different page's item" do
          row = legacy("https://en.wikipedia.org/wiki/Ainsley_Harriott")
          unmatched_run(clean(nil))

          fact = clean(@entity, FakeWikipediaClient.new({["en", "Ainsley Harriott"] => lead("Ainsley Harriott", "Q4697012")}))

          assert row.reload.deprecated?
          assert_equal "left_deprecated", fact["value"].sole["verdict"]
          assert_equal ["kept", false], fact.values_at("reason", "applied")
        end

        test "a description deprecated for another reason, or by a run older than the author row, is not judged again" do
          other_reason = legacy("https://en.wikipedia.org/wiki/Ainsley_Harriott")
          other_reason.update!(rank: :deprecated)
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :applied, facts: {"legacy_wikipedia" => {
            "value" => [{"description_id" => other_reason.id, "verdict" => "deprecated", "why" => "different_item"}]
          }})
          old_era = @author.descriptions.create!(source: :wikipedia, kind: :long, content: "Old.",
            source_url: "https://en.wikipedia.org/wiki/Michael_Harriot", rank: :deprecated)
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :unrecognized, created_at: @author.created_at - 1.day,
            facts: {"legacy_wikipedia" => {"value" => [{"description_id" => old_era.id, "verdict" => "deprecated", "why" => "author_unmatched"}]}})

          assert_nil clean(@entity)
          assert [other_reason, old_era].all? { |row| row.reload.deprecated? }
        end

        test "a rate limit on the second description leaves the first, already judged, untouched" do
          unreadable = legacy("https://example.com/somewhere")
          @author.descriptions.create!(source: :wikipedia, kind: :long, content: "Legacy text.",
            source_url: "https://en.wikipedia.org/wiki/Ainsley_Harriott")
          client = FakeWikipediaClient.new({["en", "Ainsley Harriott"] => ::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30)})

          assert_raises(::Wikimedia::Exceptions::RateLimited) { clean(@entity, client) }

          assert unreadable.reload.normal?
        end
```

The last test pins the two-phase rule with two rows. Descriptions load in id order (`Describable`), so the unreadable row is judged first. Its verdict is "deprecated" without any fetch, and it must still be normal after the second row's fetch raises.

- [ ] **Step 2: Write the failing revert and integration tests**

In `revert_facts_test.rb`, add:

```ruby
        test "a legacy description the run restored is deprecated again" do
          row = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/X")
          facts = {"legacy_wikipedia" => {"applied" => true, "reason" => "restored",
            "value" => [{"description_id" => row.id, "verdict" => "restored", "why" => "sitelink"}]}}

          result = revert(facts)

          assert row.reload.deprecated?
          assert_equal ["legacy_wikipedia"], result.data[:reverted]
        end

        test "a legacy description the run left deprecated is not touched" do
          row = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/X", rank: :deprecated)
          facts = {"legacy_wikipedia" => {"applied" => true, "reason" => "deprecated",
            "value" => [{"description_id" => row.id, "verdict" => "left_deprecated", "why" => "different_item"}]}}

          assert_empty revert(facts).data[:reverted]
          assert row.reload.deprecated?
        end
```

In `enrich_from_wikidata_test.rb`, add:

```ruby
        test "a later match restores a legacy description an earlier miss deprecated" do
          @author.identifiers.destroy_all
          legacy = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")
          enrich(wikidata: FakeWikidataClient.new)
          assert legacy.reload.deprecated?

          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q7243")
          enrich(refresh: true)

          assert legacy.reload.normal?
          assert_equal "restored", rows.last.facts.dig("legacy_wikipedia", "reason")
        end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/clean_legacy_wikipedia_test.rb test/lib/services/books/authors/revert_facts_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb`

Expected:
- The restore tests fail: the row stays deprecated, or `clean` returns nil.
- The "restored is deprecated again" revert test fails.
- The two-row test passes already: it pins existing behaviour that the rewrite must keep.

- [ ] **Step 4: Rewrite `CleanLegacyWikipedia#call` and add the re-judging**

In `clean_legacy_wikipedia.rb`, replace `call` with:

```ruby
        def call
          active = @author.descriptions.select { |description| description.source == "wikipedia" && !description.deprecated? }
          revisit = @entity ? unmatched_deprecations : []
          return nil if active.empty? && revisit.empty?

          # Two phases: every verdict is decided (including any WikipediaLead
          # fetches) before any row changes, so a raise partway through (a
          # rate limit) leaves no untraced change.
          judged = active.map { |description| [description, verdict_for(description)] } +
            revisit.map { |description| [description, rejudged(verdict_for(description))] }
          judged.each do |description, verdict|
            case verdict["verdict"]
            when "deprecated" then description.update!(rank: :deprecated)
            when "restored" then description.update!(rank: :normal)
            end
          end

          verdicts = judged.map(&:last)
          # Array#& keeps the receiver's order, so "deprecated" wins the reason over "restored".
          changes = %w[deprecated restored] & verdicts.map { |verdict| verdict["verdict"] }
          {"value" => verdicts, "applied" => changes.any?, "reason" => changes.first || "kept"}
        end
```

Add these private methods below `verdict_for`:

```ruby
        # A description deprecated only because an earlier run matched no one
        # (author_unmatched) is judged again once a run matches: kept now
        # means it is the matched item's article after all.
        def rejudged(verdict)
          verdict.merge("verdict" => (verdict["verdict"] == "kept") ? "restored" : "left_deprecated")
        end

        # This author's Wikipedia descriptions that a Wikidata run of this
        # era (newer than the author row, spec §14) deprecated as
        # author_unmatched, and that are deprecated still.
        def unmatched_deprecations
          ids = @author.enrichments.for_kind(EnrichFromWikidata::KIND).where("enrichments.created_at > ?", @author.created_at)
            .flat_map { |row| Array(row.facts.dig("legacy_wikipedia", "value")) }
            .select { |verdict| verdict["verdict"] == "deprecated" && verdict["why"] == "author_unmatched" }
            .map { |verdict| verdict["description_id"] }.to_set
          @author.descriptions.select { |description| description.source == "wikipedia" && description.deprecated? && ids.include?(description.id) }
        end
```

Update the class comment's last two sentences ("Deprecated, not deleted, so it can be undone. Exercised by the backfill: imports create no legacy descriptions.") to:

"Deprecated, not deleted, so it can be undone, and one deprecated only because no one matched is restored when a later run (the forced one after VIAF found the item, say) matches its page. Exercised by the backfill: imports create no legacy descriptions."

- [ ] **Step 5: Undo both directions in `RevertFacts`**

In `revert_facts.rb`:
- In `revert`, change `when "legacy_wikipedia" then restore_legacy(Array(fact["value"]))` to `when "legacy_wikipedia" then undo_legacy(Array(fact["value"]))`.
- Replace `restore_legacy` and its comment with:

```ruby
        # A description the run deprecated goes back to normal (every legacy
        # Wikipedia description was migrated at normal rank, and normal never
        # collides with the one-preferred index); one it restored is
        # deprecated again. The next Wikidata run judges them afresh.
        def undo_legacy(verdicts)
          deprecated = description_ids(verdicts, "deprecated")
          restored = description_ids(verdicts, "restored")
          rows = author.descriptions.select do |row|
            (deprecated.include?(row.id) && row.deprecated?) || (restored.include?(row.id) && !row.deprecated?)
          end
          rows.each { |row| row.update!(rank: row.deprecated? ? :normal : :deprecated) }
          rows.any?
        end

        def description_ids(verdicts, verdict) = verdicts.select { |entry| entry["verdict"] == verdict }.map { |entry| entry["description_id"] }
```

Update the class comment's list "the legacy Wikipedia descriptions it deprecated" to "the legacy Wikipedia descriptions it deprecated or restored".

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/books/authors/`

Expected: all pass, including the existing reject tests in `reject_external_link_test.rb`.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/clean_legacy_wikipedia.rb app/lib/services/books/authors/revert_facts.rb test/lib/services/books/authors/
git add app/lib/services/books/authors/clean_legacy_wikipedia.rb app/lib/services/books/authors/revert_facts.rb test/lib/services/books/authors/clean_legacy_wikipedia_test.rb test/lib/services/books/authors/revert_facts_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb
git commit -m "Legacy Wikipedia: a later match restores a description a miss deprecated

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Prompts — BCE years read as BCE, one banned-word list

79 dev authors store BCE years as negative numbers (Euripides −480 to −406), and books can too. Today the prompts print "born -480", "-480–-406" and "Medea (-431)". The banned-word list is also copied into four prompts.

**Files:**
- Create: `web-app/app/lib/services/books/year_label.rb`
- Create: `web-app/app/lib/services/ai/tasks/books/banned_words.rb`
- Modify: `web-app/app/lib/services/books/authors/author_profile.rb` (`lifespan`)
- Modify: `web-app/app/lib/services/ai/tasks/books/author_facts_task.rb` (`stored_facts`, `book_lines`, system message)
- Modify: `web-app/app/lib/services/ai/tasks/books/book_facts_task.rb` (`user_prompt`, `life_years`, system message)
- Modify: `web-app/app/lib/services/ai/tasks/books/author_description_review_task.rb`, `web-app/app/lib/services/ai/tasks/books/description_review_task.rb` (system messages)
- Test (create): `web-app/test/lib/services/books/year_label_test.rb`, `web-app/test/lib/services/ai/tasks/books/banned_words_test.rb`
- Test (modify): `web-app/test/lib/services/ai/tasks/books/author_facts_task_test.rb`, `web-app/test/lib/services/ai/tasks/books/book_facts_task_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::YearLabel.call(year) → String | nil`: `"1828"`, `"480 BCE"`, or nil for nil.
  - `Services::Ai::Tasks::Books::BannedWords.prose → String` and `.list → String`.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/services/books/year_label_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class YearLabelTest < ActiveSupport::TestCase
      test "a Common Era year is the number, a year before it is marked BCE, and nil stays nil" do
        assert_equal ["1828", "480 BCE", nil], [YearLabel.call(1828), YearLabel.call(-480), YearLabel.call(nil)]
      end

      test "lifespans mark BCE years too" do
        assert_equal ["480 BCE–406 BCE", "?–406 BCE", "1828–1910"],
          [Authors::AuthorProfile.lifespan(-480, -406), Authors::AuthorProfile.lifespan(nil, -406), Authors::AuthorProfile.lifespan(1828, 1910)]
      end
    end
  end
end
```

In `author_facts_task_test.rb`, add:

```ruby
          test "BCE years read as BCE in the author's facts and book list" do
            author = ::Books::Author.create!(name: "Euripides", birth_year: -480, death_year: -406)
            author.book_authors.create!(book: ::Books::Book.create!(title: "Medea", first_published_year: -431), position: 1)

            text = AuthorFactsTask.new(parent: author, records: records, mode: :knowledge).send(:user_prompt)

            assert_includes text, "Already on record: born 480 BCE; died 406 BCE"
            assert_includes text, "- Medea (431 BCE)"
          end
```

In `book_facts_task_test.rb`, add:

```ruby
          test "BCE years read as BCE for the book and its author" do
            author = ::Books::Author.create!(name: "Euripides", birth_year: -480, death_year: -406)
            book = ::Books::Book.create!(title: "Medea", first_published_year: -431)
            book.book_authors.create!(author: author, position: 1)

            text = BookFactsTask.new(parent: book).send(:user_prompt)

            assert_includes text, "Author: Euripides (480 BCE–406 BCE)"
            assert_includes text, "First published (our record): 431 BCE"
          end
```

Create `web-app/test/lib/services/ai/tasks/books/banned_words_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        # The prompts' wording before the list moved into one constant, pinned
        # so the move changed no prompt.
        class BannedWordsTest < ActiveSupport::TestCase
          PROSE = 'delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, ' \
            'navigate, resonate, profound, haunting, luminous, or "explores themes of"'
          LIST = PROSE.sub(', or "', ', "')

          test "one list, in a writing rule's form and a review code's form" do
            assert_equal [PROSE, LIST], [BannedWords.prose, BannedWords.list]
          end

          test "both writing prompts and both review prompts carry it" do
            author = books_authors(:tolstoy)
            book = books_books(:war_and_peace)
            writers = [
              AuthorFactsTask.new(parent: author, records: stub(wikidata: nil, viaf: nil, lead: nil)),
              BookFactsTask.new(parent: book)
            ]
            reviewers = [
              AuthorDescriptionReviewTask.new(parent: author, description: "A novelist."),
              DescriptionReviewTask.new(parent: book, description: "A novel.")
            ]

            writers.each { |task| assert_includes task.send(:system_message), "Plain words. Do not use: #{PROSE}." }
            reviewers.each { |task| assert_includes task.send(:system_message), "- banned_word: #{LIST}\n" }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/year_label_test.rb test/lib/services/ai/tasks/books/`

Expected:
- `YearLabel` and `BannedWords` error with `NameError`.
- The BCE prompt tests fail on "born -480".
- The reviewers' assertion in "both writing prompts…" passes already: it pins the current text.

- [ ] **Step 3: Create the two helpers**

Create `web-app/app/lib/services/books/year_label.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # A year as a prompt shows it: "1828", or "480 BCE" for a year before
    # the Common Era, which the books data stores as a negative number
    # (Euripides is -480). A bare "-480" reads as a typo, and "born -480"
    # invites the model to report it back as a Common Era year.
    class YearLabel
      def self.call(year)
        return nil if year.nil?

        year.to_i.negative? ? "#{-year.to_i} BCE" : year.to_s
      end
    end
  end
end
```

Create `web-app/app/lib/services/ai/tasks/books/banned_words.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # The words every description prompt bans and every description
        # review looks for, in one place so the writer and the reviewer never
        # disagree about the list.
        module BannedWords
          WORDS = %w[delve tapestry testament poignant seminal groundbreaking timeless gripping compelling journey
            navigate resonate profound haunting luminous].freeze
          PHRASE = '"explores themes of"'

          # A writing rule's form: '..., luminous, or "explores themes of"'.
          def self.prose = "#{WORDS.join(", ")}, or #{PHRASE}"

          # A review code's form: '..., luminous, "explores themes of"'.
          def self.list = (WORDS + [PHRASE]).join(", ")
        end
      end
    end
  end
end
```

- [ ] **Step 4: Use them**

- **`author_profile.rb`, `self.lifespan`:** replace the last line with `"#{::Services::Books::YearLabel.call(birth) || "?"}–#{::Services::Books::YearLabel.call(death)}"`.
- **`author_facts_task.rb`:**
  - In `stored_facts`, use `"born #{::Services::Books::YearLabel.call(parent.birth_year)}"` and `"died #{::Services::Books::YearLabel.call(parent.death_year)}"`.
  - In `book_lines`, use `"- #{title} (#{::Services::Books::YearLabel.call(year)})"`.
  - In the system message, replace the literal list in the "Plain words." line with `#{BannedWords.prose}`. The line becomes `- Plain words. Do not use: #{BannedWords.prose}.`
- **`book_facts_task.rb`:**
  - In `user_prompt`, use `"First published (our record): #{::Services::Books::YearLabel.call(parent.first_published_year)}"`.
  - In `life_years`, first set `birth = ::Services::Books::YearLabel.call(author.birth_year)` and `death = ::Services::Books::YearLabel.call(author.death_year)`. The rest of the method is unchanged.
  - In the system message, make the same `#{BannedWords.prose}` replacement as in `author_facts_task.rb`.
- **`author_description_review_task.rb` and `description_review_task.rb`:** in the system message, change the `banned_word:` line to `- banned_word: #{BannedWords.list}`.

All four files sit inside `module Services; module Ai; module Tasks; module Books`, so `BannedWords` resolves lexically. Check each heredoc is a plain `<<~` (interpolating), not `<<~'...'`.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/services/books/ test/lib/services/ai/tasks/books/`

Expected: all pass.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/year_label.rb app/lib/services/ai/tasks/books/ app/lib/services/books/authors/author_profile.rb test/lib/services/books/year_label_test.rb test/lib/services/ai/tasks/books/
git add app/lib/services/books/year_label.rb app/lib/services/ai/tasks/books/ app/lib/services/books/authors/author_profile.rb test/lib/services/books/year_label_test.rb test/lib/services/ai/tasks/books/
git commit -m "Prompts: BCE years read as BCE; one banned-word list

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: A Redis cache for the Wikidata and VIAF clients

Production sets no `cache_store`, so `Rails.cache` is a per-container file store wiped on every deploy. A four-day backfill spans deploys, and the Sidekiq container's cache would not be shared with any other.

**Files:**
- Create: `web-app/config/initializers/external_api_cache.rb`
- Modify: `web-app/app/lib/wikidata/client.rb` (constructor and three `Rails.cache` uses)
- Modify: `web-app/app/lib/viaf/client.rb` (constructor default)
- Test (modify): `web-app/test/lib/wikidata/client_test.rb`, `web-app/test/lib/viaf/client_test.rb`

**Interfaces:**
- Produces:
  - `Rails.application.config.x.external_api_cache`, an `ActiveSupport::Cache::Store`.
  - `Wikidata::Client.new(http: nil, cache: nil)`.
  - `Viaf::Client.new(base_client: nil, gate: nil, cache: nil)`. A nil cache means `config.x.external_api_cache`.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/wikidata/client_test.rb`:
1. In the two existing tests that call `Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)`, delete that line.
2. Pass the store to a fresh client instead: replace `@client.` with `client.` in those tests, and add at the top of each:

```ruby
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter), cache: ActiveSupport::Cache::MemoryStore.new)
```

3. Add:

```ruby
    test "a client given no cache uses the external API cache" do
      Rails.application.config.x.stubs(:external_api_cache).returns(ActiveSupport::Cache::MemoryStore.new)
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter))
      body = {entities: {"Q36180" => {"id" => "Q36180", "labels" => {"en" => {"language" => "en", "value" => "writer"}}}}}.to_json
      stub = stub_request(:get, API).with(query: hash_including(action: "wbgetentities", props: "labels")).to_return(json_response(body))

      2.times { client.labels(["Q36180"]) }

      assert_requested stub, times: 1
    end
```

In `web-app/test/lib/viaf/client_test.rb`, the setup already passes `cache:` explicitly, so the existing tests stay as they are. Add:

```ruby
  test "a client given no cache uses the external API cache" do
    Rails.application.config.x.stubs(:external_api_cache).returns(ActiveSupport::Cache::MemoryStore.new)
    client = Viaf::Client.new(base_client: @base, gate: @gate)
    @base.expects(:get).with("viaf/AutoSuggest", {query: "Stacy Willingham"}).once.returns(suggest_response)

    2.times { client.suggest("Stacy Willingham") }
  end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/wikidata/client_test.rb test/lib/viaf/client_test.rb`

Expected:
- The "given no cache" tests fail: there are two requests, because the client still reads `Rails.cache`, a null store in test.
- The edited cache tests error with `ArgumentError: unknown keyword: :cache` for `Wikidata::Client`.

- [ ] **Step 3: Create the initializer**

Create `web-app/config/initializers/external_api_cache.rb`:

```ruby
# The cache the Wikidata and VIAF clients keep lookups in: labels and
# country codes for 30 days, VIAF AutoSuggest answers for a day.
#
# Not Rails.cache: production configures no cache_store, so Rails.cache is
# a per-container file store wiped on every deploy, and the author backfill
# runs for days across deploys. Redis is already running for Sidekiq.
# Switching the global cache_store instead would change music and games,
# which are live.
#
# namespace is load-bearing, as in rate_limit_store.rb: RedisCacheStore#clear
# runs a bare flushdb without one, and this is Sidekiq's database.
#
# Test: a null store, as Rails.cache is there, so no lookup leaks between tests.
Rails.application.config.x.external_api_cache =
  if Rails.env.test?
    ActiveSupport::Cache::NullStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
      namespace: "external-api"
    )
  end
```

- [ ] **Step 4: Inject it into the clients**

In `web-app/app/lib/wikidata/client.rb`:
- Change `initialize` to:

```ruby
    def initialize(http: nil, cache: nil)
      @http = http || ::Wikimedia::Http.new
      @cache = cache || Rails.application.config.x.external_api_cache
    end
```

- Replace the three `Rails.cache` calls (`write` in `country_codes`, `write` in `labels`, `read_multi` in `read_cached`) with `@cache`.
- In the class comment, change "are cached for 30 days" to "are cached for 30 days in config.x.external_api_cache".

In `web-app/app/lib/viaf/client.rb`, change the signature and assignment to:

```ruby
    def initialize(base_client: nil, gate: nil, cache: nil)
      ...
      @cache = cache || Rails.application.config.x.external_api_cache
```

Keep the existing `@base_client` and `@gate` lines as they are.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/wikidata/ test/lib/viaf/ test/lib/services/books/authors/`

Expected: all pass.

Then check development reads the Redis store:

```bash
bin/rails runner 'p Rails.application.config.x.external_api_cache.class'
```

Expected: `ActiveSupport::Cache::RedisCacheStore`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb config/initializers/external_api_cache.rb app/lib/wikidata/client.rb app/lib/viaf/client.rb test/lib/wikidata/client_test.rb test/lib/viaf/client_test.rb
git add config/initializers/external_api_cache.rb app/lib/wikidata/client.rb app/lib/viaf/client.rb test/lib/wikidata/client_test.rb test/lib/viaf/client_test.rb
git commit -m "Wikidata and VIAF clients cache in Redis, not the per-container file store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

# Part B — The backfill

### Task 8: Pass `allow_research` down the whole chain

`EnrichJob` takes `allow_research`, but nothing upstream passes it. The backfill turns research off (spec §13), and that has to survive the VIAF step and VIAF's forced Wikidata hop.

**Files:**
- Modify: `web-app/app/sidekiq/books/authors/wikidata_job.rb`, `web-app/app/sidekiq/books/authors/viaf_job.rb`
- Test (modify): `web-app/test/sidekiq/books/authors/wikidata_job_test.rb`, `web-app/test/sidekiq/books/authors/viaf_job_test.rb`

**Interfaces:**
- Produces:
  - `Books::Authors::WikidataJob#perform(author_id, refresh = false, via_viaf = false, allow_research = true)`
  - `Books::Authors::ViafJob#perform(author_id, refresh = false, enrich_queued = false, allow_research = true)`
- Every next step receives `allow_research`:
  - `ViafJob.perform_async(author_id, refresh, false, allow_research)`;
  - `EnrichJob.perform_async(author_id, allow_research)`;
  - `WikidataJob.perform_async(author_id, true, true, allow_research)`.
- Reschedules carry it as the last argument.

- [ ] **Step 1: Write the failing tests**

In `wikidata_job_test.rb`, add:

```ruby
  test "research off reaches the VIAF step on a miss" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).with(@author.id, false, false, false)

    Books::Authors::WikidataJob.new.perform(@author.id, false, false, false)
  end

  test "research off reaches the AI step on a match" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:matched))
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, false)

    Books::Authors::WikidataJob.new.perform(@author.id, false, false, false)
  end

  test "a rate limit reschedules with research still off" do
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))
    Books::Authors::WikidataJob.expects(:perform_in).with(30, @author.id, false, false, false)
    job = Books::Authors::WikidataJob.new
    job.stubs(:rand).returns(0)

    job.perform(@author.id, false, false, false)
  end
```

In `viaf_job_test.rb`, add:

```ruby
  test "research off reaches the AI step and the forced Wikidata hop" do
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome)
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, false)
    Books::Authors::ViafJob.new.perform(@author.id, false, false, false)

    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true, true, false)
    Books::Authors::ViafJob.new.perform(@author.id, false, false, false)
  end
```

Update the existing expectations in both files to the new arities. Each enqueue of the next step and each reschedule now carries the research flag; with no flag passed it is `true`:
- `EnrichJob.perform_async` gets `(@author.id, true)`.
- `ViafJob.perform_async` gets `(@author.id, true, false, true)` in "a miss goes on to VIAF".
- `WikidataJob.perform_async` gets `(@author.id, true, true, true)`.
- The `perform_in` expectations gain a trailing `true`.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/sidekiq/books/authors/`

Expected: FAIL on the new tests and on the updated expectations, with "unexpected invocation" or "not all expectations were satisfied".

- [ ] **Step 3: Implement**

`wikidata_job.rb`:
- Signature: `def perform(author_id, refresh = false, via_viaf = false, allow_research = true)`.
- The two enqueues become `::Books::Authors::ViafJob.perform_async(author_id, refresh, false, allow_research)` and `::Books::Authors::EnrichJob.perform_async(author_id, allow_research)`.
- The reschedule becomes `self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, via_viaf, allow_research)`.
- Add to the class comment: "allow_research (false for the backfill, spec §13) travels with the author to every later step."

`viaf_job.rb`:
- Signature: `def perform(author_id, refresh = false, enrich_queued = false, allow_research = true)`.
- `::Books::Authors::WikidataJob.perform_async(author_id, true, true, allow_research)`.
- Both `EnrichJob.perform_async(author_id)` calls become `EnrichJob.perform_async(author_id, allow_research)`.
- `reschedule` takes and passes `allow_research` as the last argument of `perform_in`. Both rescue clauses call `reschedule(e, author_id, refresh, <enrich_queued value as today>, allow_research)`.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/sidekiq/books/authors/ test/lib/services/books/authors/ test/lib/data_importers/books/`

Expected: all pass. The importer providers still enqueue `WikidataJob.perform_async(author.id)`, so research defaults to on for imports.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/sidekiq/books/authors/ test/sidekiq/books/authors/
git add app/sidekiq/books/authors/wikidata_job.rb app/sidekiq/books/authors/viaf_job.rb test/sidekiq/books/authors/wikidata_job_test.rb test/sidekiq/books/authors/viaf_job_test.rb
git commit -m "Author chain: allow_research travels with the author to every step

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: VIAF jobs that must wait take a start time from a line

VIAF allows 2 requests a minute and about 1,000 a day, which is 200–300 authors a day. During the backfill, Wikidata misses arrive far faster. Today every waiting `ViafJob` comes back after the same short wait (retry_after plus 0–30 s). A backlog of thousands would therefore fill the low queue with jobs that cannot run, ahead of the Wikidata and AI jobs behind them. A long wait must also not hold up the AI step (spec §8).

**Files:**
- Create: `web-app/app/lib/viaf/schedule.rb`
- Modify: `web-app/app/sidekiq/books/authors/viaf_job.rb`
- Test (create): `web-app/test/lib/viaf/schedule_test.rb`
- Test (modify): `web-app/test/sidekiq/books/authors/viaf_job_test.rb`

**Interfaces:**
- Produces:
  - `Viaf::Schedule.new(redis: nil)`.
  - `#reserve(not_before:) → Integer`: seconds from now.
  - `#horizon → ActiveSupport::TimeWithZone | nil`.
  - `Viaf::Schedule::SLOT_SECONDS = 90`.
  - `Books::Authors::ViafJob::CHAIN_PATIENCE = 600`.

- [ ] **Step 1: Write the failing schedule test**

Create `web-app/test/lib/viaf/schedule_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::ScheduleTest < ActiveSupport::TestCase
  # CI has no Redis; FakeRedis models the hash commands and expiry.
  def setup
    freeze_time
    @schedule = Viaf::Schedule.new(redis: Books::OpenLibrary::FakeRedis.new)
  end

  test "an empty line starts a job after the wait it asked for" do
    assert_equal 30, @schedule.reserve(not_before: 30)
  end

  test "each waiting job starts one slot after the one before" do
    assert_equal [30, 120, 210], 3.times.map { @schedule.reserve(not_before: 30) }
  end

  test "a pause pushes the line to the end of the pause, and the next job queues behind it" do
    @schedule.reserve(not_before: 30)

    assert_equal [3600, 3690], [@schedule.reserve(not_before: 3600), @schedule.reserve(not_before: 30)]
  end

  test "once the line has run, the next job waits only its own wait" do
    2.times { @schedule.reserve(not_before: 30) }
    travel 1.hour

    assert_equal 30, @schedule.reserve(not_before: 30)
  end

  test "the horizon is the last start given out, and nil once it has passed" do
    assert_nil @schedule.horizon
    2.times { @schedule.reserve(not_before: 30) }
    assert_equal Time.current + 120.seconds, @schedule.horizon

    travel 121.seconds
    assert_nil @schedule.horizon
  end
end
```

- [ ] **Step 2: Write the failing job tests**

In `viaf_job_test.rb`'s `setup`, add:

```ruby
    # CI has no Redis: every job reserves its start time in a fake. The
    # clock is frozen so a second passing mid-reservation cannot shift a wait.
    freeze_time
    @schedule = Viaf::Schedule.new(redis: Books::OpenLibrary::FakeRedis.new)
    Viaf::Schedule.stubs(:new).returns(@schedule)
```

The existing pause and busy-pace tests keep their expected delays (3607 and 37 with jitter 7), because an empty line returns exactly the wait asked for.

Add:

```ruby
  test "a busy pace behind a long VIAF line queues the AI step now and waits its turn" do
    8.times { @schedule.reserve(not_before: 30) }
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).with(@author.id, false).once
    Books::Authors::ViafJob.expects(:perform_in).with(30 + (8 * 90) + 7, @author.id, false, true, false)

    job_with_jitter(7).perform(@author.id, false, false, false)
  end

  test "a busy pace behind a short line only waits its turn" do
    2.times { @schedule.reserve(not_before: 30) }
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("VIAF pace busy", retry_after: 30))
    Books::Authors::EnrichJob.expects(:perform_async).never
    Books::Authors::ViafJob.expects(:perform_in).with(30 + (2 * 90) + 7, @author.id, false, false, true)

    job_with_jitter(7).perform(@author.id)
  end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/viaf/schedule_test.rb test/sidekiq/books/authors/viaf_job_test.rb`

Expected: `NameError: uninitialized constant Viaf::Schedule`.

- [ ] **Step 4: Create the schedule**

Create `web-app/app/lib/viaf/schedule.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # Start times for VIAF jobs that have to wait (spec §8, sized for the
  # increment-6 backfill). VIAF serves two requests a minute and about a
  # thousand a day, while a backfill's Wikidata misses arrive several a
  # minute. Sent back after the same short wait, a backlog of thousands
  # would retry together every half minute and fill the low queue with
  # jobs that cannot run. Each waiting job takes the next free start time
  # instead, SLOT_SECONDS after the last one given out, so a backlog of N
  # runs once each, in turn.
  #
  # Held in Redis so every worker shares one line. HINCRBY then HSET is
  # not atomic: two jobs reserving at the same moment on an empty line can
  # get the same start, and the second simply waits again.
  class Schedule
    KEY = "viaf:schedule"
    FIELD = "last"
    # An author costs one to four requests at two a minute.
    SLOT_SECONDS = 90

    def initialize(redis: nil)
      @redis = redis || REDIS_POOL
    end

    # Seconds from now until this job's start: at least not_before, and one
    # slot after every start already given out.
    def reserve(not_before:)
      floor = now + not_before.to_i
      with_redis do |redis|
        slot = redis.hincrby(KEY, FIELD, SLOT_SECONDS)
        if slot < floor
          slot = floor
          redis.hset(KEY, FIELD, slot)
        end
        redis.expire(KEY, slot - now + SLOT_SECONDS)
        slot - now
      end
    end

    # The last start given out, or nil once it has passed (no one waiting).
    def horizon
      last = with_redis { |redis| redis.hgetall(KEY)[FIELD] }.to_i
      (last > now) ? Time.zone.at(last) : nil
    end

    private

    def now = Time.current.to_i

    def with_redis(&block)
      @redis.respond_to?(:with) ? @redis.with(&block) : yield(@redis)
    end
  end
end
```

- [ ] **Step 5: Use it in `ViafJob`**

In `viaf_job.rb`:

1. Replace both rescue clauses and the `reschedule` method with:

```ruby
  rescue ::Viaf::Exceptions::RateLimited => e
    # Paused is a RateLimited: VIAF is out for an hour or more. Either way
    # the job takes its turn in the line, and the AI step is queued now when
    # VIAF is paused or the turn is more than CHAIN_PATIENCE away.
    wait = ::Viaf::Schedule.new.reserve(not_before: e.retry_after)
    hand_off = !enrich_queued && (e.is_a?(::Viaf::Exceptions::Paused) || wait > CHAIN_PATIENCE)
    ::Books::Authors::EnrichJob.perform_async(author_id, allow_research) if hand_off
    self.class.perform_in(wait + rand(RESCHEDULE_JITTER), author_id, refresh, enrich_queued || hand_off, allow_research)
  end
```

2. Add the constant below `RESCHEDULE_JITTER`:

```ruby
  # The longest the AI step waits for VIAF. A turn further off than this
  # queues the AI step now, as a pause does; VIAF's facts land as fills
  # when its turn comes.
  CHAIN_PATIENCE = 600
```

3. Replace the class comment's last paragraph, "The chain never waits on VIAF … land as fills.", with:

```ruby
# The chain never waits on VIAF (spec §8). A job VIAF cannot serve now
# -- a pause (Viaf::Exceptions::Paused: a Cloudflare block, a 429, the
# day's budget running low; an hour or more) or a busy pace -- takes the
# next start time in Viaf::Schedule's line rather than retrying on a fixed
# short delay. When VIAF is paused, or that start is more than
# CHAIN_PATIENCE away, the author goes on to the AI step at once and the
# job is rescheduled with enrich_queued, so later attempts neither queue
# the AI step again nor queue it when they finish. Facts a late VIAF run
# finds land as fills.
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/viaf/ test/sidekiq/books/authors/`

Expected: all pass.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/viaf/schedule.rb app/sidekiq/books/authors/viaf_job.rb test/lib/viaf/schedule_test.rb test/sidekiq/books/authors/viaf_job_test.rb
git add app/lib/viaf/schedule.rb app/sidekiq/books/authors/viaf_job.rb test/lib/viaf/schedule_test.rb test/sidekiq/books/authors/viaf_job_test.rb
git commit -m "VIAF: waiting jobs take a start time from a line; a long wait hands the AI step on

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Put back the ids earlier decisions found, before resolving

After the pre-launch re-migration, every author row is re-created with its id. The migrator brings back only the Open Library keys; the Wikidata and VIAF ids earlier runs stamped are gone. Their decisions survive, and so do the stored records (spec §14). Putting the id back before a run lets the held-id stage find it and the stored record answer: no search, no AI selection, and for VIAF none of the day's budget.

**Files:**
- Create: `web-app/app/lib/services/books/authors/restore_identifier.rb`
- Modify: `web-app/app/lib/services/books/authors/ledger_run.rb` (`write` records `@restored`)
- Modify: `web-app/app/lib/services/books/authors/enrich_from_wikidata.rb`, `web-app/app/lib/services/books/authors/enrich_from_viaf.rb`
- Test (create): `web-app/test/lib/services/books/authors/restore_identifier_test.rb`
- Test (modify): `web-app/test/lib/services/books/authors/enrich_from_wikidata_test.rb`, `web-app/test/lib/services/books/authors/enrich_from_viaf_test.rb`

**Interfaces:**
- Consumes:
  - `RejectedRecords#identifier?(type, value)`;
  - `MatchDecision#selected_candidate`;
  - `LedgerRun#write` (Task 1).
- Produces:
  - `Services::Books::Authors::RestoreIdentifier.call(author:, finder:) → Hash | nil`. `finder` is the resolver class or its name.
  - The hash is `{"value" => "Q7243", "applied" => true, "reason" => "earlier_decision", "decision_id" => 12}`.
  - A run's ledger rows carry it as the fact `"restored_identifier"`.

- [ ] **Step 1: Write the failing service test**

Create `web-app/test/lib/services/books/authors/restore_identifier_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RestoreIdentifierTest < ActiveSupport::TestCase
        QID = "books_author_wikidata_qid"

        def setup
          @author = ::Books::Author.create!(name: "Restored Author")
        end

        def decide(key, finder: ResolveWikidata, outcome: :matched, at: @author.created_at - 1.day, **attributes)
          ::MatchDecision.create!(finder: finder.name, subject: @author, outcome: outcome, confidence: :high, decided_by: :ai,
            candidates: [{"external_key" => key}], selected_index: (outcome == :matched) ? 1 : nil, created_at: at, **attributes)
        end

        def restore(finder = ResolveWikidata) = RestoreIdentifier.call(author: @author, finder: finder)

        def held(type = QID) = @author.identifiers.where(identifier_type: type).pluck(:value)

        test "puts back the id the latest earlier-era match chose, and returns the fact" do
          decide("Q1", at: @author.created_at - 2.days)
          decision = decide("Q7243")

          assert_equal({"value" => "Q7243", "applied" => true, "reason" => "earlier_decision", "decision_id" => decision.id}, restore)
          assert_equal ["Q7243"], held
        end

        test "a VIAF decision puts back the VIAF id" do
          decide("5391", finder: ResolveViaf)

          assert_equal "5391", restore(ResolveViaf)["value"]
          assert_equal ["5391"], held("books_author_viaf")
        end

        test "a decision from this era, even one that matched nothing, stops an older match coming back" do
          decide("Q7243")
          decide(nil, outcome: :unmatched, at: @author.created_at + 1.minute)

          assert_nil restore
          assert_empty held
        end

        test "a rejected latest decision puts nothing back, even with an older match behind it" do
          decide("Q1", at: @author.created_at - 2.days)
          decide("Q7243", verdict: :rejected)

          assert_nil restore
          assert_empty held
        end

        test "an id rejected through another decision is not put back" do
          decide("Q7243", at: @author.created_at - 2.days, verdict: :rejected)
          decide("Q7243")

          assert_nil restore
        end

        test "a decision flagged for review comes back only once a person reviewed it" do
          decision = decide("Q7243", needs_review: true)
          assert_nil restore

          decision.update!(reviewed_at: Time.current)
          assert_equal "Q7243", restore["value"]
        end

        test "an author already holding an id of that type, or an id another author holds, gets nothing" do
          decide("Q7243")
          other = ::Books::Author.create!(name: "Holder")
          other.identifiers.create!(identifier_type: QID, value: "Q7243")
          assert_nil restore

          other.identifiers.destroy_all
          @author.identifiers.create!(identifier_type: QID, value: "Q9")
          assert_nil restore
          assert_equal ["Q9"], held
        end
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing runner tests**

In `enrich_from_wikidata_test.rb`, add:

```ruby
        test "a re-migrated author gets back the Wikidata id its earlier match chose, and resolves without searching" do
          @author.identifiers.destroy_all
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :ai, candidates: [{"external_source" => "wikidata", "external_key" => "Q7243"}], selected_index: 1,
            created_at: @author.created_at - 1.day)

          result = enrich

          assert_equal ["identifier", "certain"], [result.data[:decision].decided_by, result.data[:decision].confidence]
          assert_not @wikidata.called?(:search)
          assert_equal ["Q7243", decision.id], rows.sole.facts["restored_identifier"].values_at("value", "decision_id")
        end
```

In `enrich_from_viaf_test.rb`, add:

```ruby
        test "a re-migrated author gets back the VIAF id its earlier match chose, and resolves without AutoSuggest" do
          ::MatchDecision.create!(finder: ResolveViaf.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :rule, candidates: [{"external_source" => "viaf", "external_key" => "5391"}], selected_index: 1,
            created_at: @author.created_at - 1.day)

          result = run_viaf

          assert_equal "identifier", result.data[:decision].decided_by
          assert_not @client.called?(:suggest)
          assert_equal "5391", rows.sole.facts.dig("restored_identifier", "value")
        end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/restore_identifier_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb test/lib/services/books/authors/enrich_from_viaf_test.rb`

Expected:
- The service test errors with `NameError`.
- The runner tests fail: a search or suggest call happens, and `restored_identifier` is nil.

- [ ] **Step 4: Create the service**

Create `web-app/app/lib/services/books/authors/restore_identifier.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # After the pre-launch re-migration an author row is re-created with
      # its id, and the Wikidata and VIAF ids earlier runs stamped are gone:
      # the migrator brings back only Open Library keys. Their decisions and
      # stored records survive (spec §14). Before a run resolves, this puts
      # back the id its step's latest decision chose, so the resolver's
      # held-id stage finds it and the stored record answers, with no search
      # and no AI selection.
      #
      # Only a decision a person would stand behind comes back: the step's
      # latest, older than the author row, matched, not rejected, and either
      # never flagged for review or reviewed since. An author already
      # holding an id of that type, an id rejected for this author, or one
      # another author holds gets nothing. Returns the ledger fact, or nil.
      class RestoreIdentifier
        TYPES = {
          "Services::Books::Authors::ResolveWikidata" => "books_author_wikidata_qid",
          "Services::Books::Authors::ResolveViaf" => "books_author_viaf"
        }.freeze

        def self.call(author:, finder:)
          new(author: author, finder: finder.to_s).call
        end

        def initialize(author:, finder:)
          @author = author
          @finder = finder
          @type = TYPES.fetch(finder)
        end

        def call
          return nil if @author.identifiers.any? { |identifier| identifier.identifier_type == @type }

          decision = ::MatchDecision.where(subject: @author, finder: @finder).order(created_at: :desc, id: :desc).first
          return nil unless carried_over?(decision)

          value = decision.selected_candidate&.dig("external_key").to_s
          return nil if value.blank? || RejectedRecords.new(@author).identifier?(@type, value)
          return nil if ::Identifier.where(identifiable_type: "Books::Author", identifier_type: @type, value: value).exists?

          @author.identifiers.create!(identifier_type: @type, value: value)
          {"value" => value, "applied" => true, "reason" => "earlier_decision", "decision_id" => decision.id}
        end

        private

        def carried_over?(decision)
          decision.present? && decision.matched? && !decision.verdict_rejected? &&
            decision.created_at < @author.created_at && (!decision.needs_review || decision.reviewed_at.present?)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Record it, and call it from both runners**

In `ledger_run.rb`:
- Change the first line of `write` to:

```ruby
        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          facts = facts.merge("restored_identifier" => @restored) if @restored
          author.enrichments.create!(
```

- Add to the module comment: "@restored, when a run put back an earlier decision's id (RestoreIdentifier), is recorded on its row."

In `enrich_from_wikidata.rb`, in `call`, add this line between the `already_processed` skip and `resolved = ResolveWikidata.call(...)`:

```ruby
          @restored = RestoreIdentifier.call(author: author, finder: ResolveWikidata)
```

In `enrich_from_viaf.rb`, add the same line, with `ResolveViaf`, between the skip and `resolved = ResolveViaf.call(...)`.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/books/authors/ test/sidekiq/books/authors/`

Expected: all pass.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/ test/lib/services/books/authors/
git add app/lib/services/books/authors/restore_identifier.rb app/lib/services/books/authors/ledger_run.rb app/lib/services/books/authors/enrich_from_wikidata.rb app/lib/services/books/authors/enrich_from_viaf.rb test/lib/services/books/authors/restore_identifier_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb test/lib/services/books/authors/enrich_from_viaf_test.rb
git commit -m "Author steps: put back the id an earlier era's trusted decision found

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: `books:authors:enrich[limit]`

**Files:**
- Create: `web-app/app/lib/services/books/authors/queued_chain.rb`
- Create: `web-app/app/lib/services/books/authors/backfill.rb`
- Create: `web-app/lib/tasks/books/authors.rake`
- Test (create): `web-app/test/lib/services/books/authors/queued_chain_test.rb`, `web-app/test/lib/services/books/authors/backfill_test.rb`, `web-app/test/lib/tasks/books_authors_rake_test.rb`

**Interfaces:**
- Consumes:
  - `LedgerRun.processed(kind)` (Task 1);
  - `WikidataJob` and `ViafJob` with `allow_research` (Task 8);
  - `EnrichFromWikidata::KIND`, `EnrichFromViaf::KIND`.
- Produces:
  - `QueuedChain.by_job → {"Books::Authors::WikidataJob" => [ids], "Books::Authors::ViafJob" => [ids], "Books::Authors::EnrichJob" => [ids]}`.
  - `QueuedChain.author_ids → Set<Integer>`.
  - `Backfill.call(limit:, queued: nil) → Result`, where `limit` is an Integer or nil for all. Its data is `{wikidata:, viaf:, left_out:, wikidata_done_at:}`.
  - `Backfill.unprocessed → ActiveRecord::Relation<Books::Author>`.
  - `Backfill::SPACING = 6`.

- [ ] **Step 1: Write the failing `QueuedChain` test**

Create `web-app/test/lib/services/books/authors/queued_chain_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class QueuedChainTest < ActiveSupport::TestCase
        # CI has no Redis: the Sidekiq sets are stubbed with plain lists.
        def job(klass, *args) = stub(klass: klass, args: args)

        def setup
          ::Sidekiq::ScheduledSet.stubs(:new).returns([job("Books::Authors::WikidataJob", 1, false, false, false), job("Books::EnrichBookJob", 2)])
          ::Sidekiq::RetrySet.stubs(:new).returns([job("Books::Authors::EnrichJob", 3, false)])
          ::Sidekiq::Queue.stubs(:new).with("low").returns([job("Books::Authors::ViafJob", 4, false, true, false)])
        end

        test "collects the authors of chain jobs scheduled, retrying or enqueued on the low queue" do
          assert_equal({"Books::Authors::WikidataJob" => [1], "Books::Authors::ViafJob" => [4], "Books::Authors::EnrichJob" => [3]},
            QueuedChain.by_job)
          assert_equal Set[1, 3, 4], QueuedChain.author_ids
        end
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing `Backfill` test**

Create `web-app/test/lib/services/books/authors/backfill_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class BackfillTest < ActiveSupport::TestCase
        def setup
          # Sidekiq runs inline in tests: record the enqueues instead.
          @wikidata_calls = []
          @viaf_calls = []
          ::Books::Authors::WikidataJob.stubs(:perform_in).with { |*args| @wikidata_calls << args }
          ::Books::Authors::ViafJob.stubs(:perform_async).with { |*args| @viaf_calls << args }
        end

        def author(name, books: 0, rank: nil)
          created = ::Books::Author.create!(name: name)
          books.times { |index| created.book_authors.create!(book: ::Books::Book.create!(title: "#{name} book #{index}"), position: 1) }
          if rank
            RankedItem.create!(item: created, ranking_configuration: ranking_configurations(:books_authors_global), rank: rank, score: 100 - rank)
          end
          created
        end

        def done(author, kind: EnrichFromWikidata::KIND, outcome: :applied, decision: nil)
          author.enrichments.create!(kind: kind, outcome: outcome, match_decision: decision, created_at: author.created_at + 1.minute)
        end

        def queued_ids = @wikidata_calls.map { |args| args[1] }

        def backfill(limit: nil, queued: Set.new) = Backfill.call(limit: limit, queued: queued)

        test "queues unprocessed authors ranked first by rank, then by books written, at the Wikidata pace with research off" do
          second = author("Second Ranked", rank: 2)
          first = author("First Ranked", rank: 1)
          prolific = author("Prolific", books: 3)
          single = author("Single", books: 1)

          backfill

          assert_equal [first.id, second.id, prolific.id, single.id], queued_ids & [first.id, second.id, prolific.id, single.id]
          assert_equal (0...@wikidata_calls.size).map { |index| index * Backfill::SPACING }, @wikidata_calls.map(&:first)
          assert(@wikidata_calls.all? { |args| args[2..] == [false, false, false] })
        end

        test "leaves out processed authors and placeholders; a failed run or a rejected one leaves an author in" do
          processed = author("Processed").tap { |a| done(a) }
          placeholder = ::Books::Author.create!(name: "Placeholder", exclude_from_rankings: true)
          failed = author("Failed").tap { |a| done(a, outcome: :failed) }
          rejected = author("Rejected")
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: rejected, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q1"}], selected_index: 1)
          done(rejected, decision: decision)

          backfill

          assert_equal [failed.id, rejected.id].sort, (queued_ids & [processed.id, placeholder.id, failed.id, rejected.id]).sort
        end

        test "an author with a chain job already waiting is left out and counted, and the limit counts only the rest" do
          waiting = author("Waiting", rank: 1)
          next_up = author("Next", rank: 2)
          author("After", rank: 3)

          result = backfill(limit: 1, queued: Set[waiting.id])

          assert_equal [next_up.id], queued_ids
          assert_equal [1, 1], result.data.values_at(:wikidata, :left_out)
        end

        test "a Wikidata miss whose VIAF step never finished gets the VIAF step again, with the AI step marked already queued" do
          missed = author("Missed").tap { |a| done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :failed) }
          viaf_done = author("VIAF Done").tap { |a| done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :unrecognized) }
          matched_later = author("Matched Later").tap { |a| done(a, outcome: :unrecognized) && done(a, outcome: :applied) }

          backfill

          ours = @viaf_calls.select { |args| [missed.id, viaf_done.id, matched_later.id].include?(args.first) }
          assert_equal [[missed.id, false, true, false]], ours
          assert_not_includes queued_ids, missed.id
        end

        test "unprocessed counts the authors a full run would queue for the Wikidata step" do
          fresh = author("Fresh")
          processed = author("Processed").tap { |a| done(a) }

          ids = Backfill.unprocessed.pluck(:id)

          assert_includes ids, fresh.id
          assert_not_includes ids, processed.id
        end
      end
    end
  end
end
```

- [ ] **Step 3: Write the failing rake test**

Create `web-app/test/lib/tasks/books_authors_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksAuthorsRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:authors:enrich")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/authors.rake").to_s }
    end
    @task = Rake::Task["books:authors:enrich"]
    @task.reenable
  end

  def result(**data)
    ::Services::Books::Authors::Backfill::Result.new(success?: true, errors: [],
      data: {wikidata: 2, viaf: 1, left_out: 0, wikidata_done_at: Time.utc(2026, 10, 2, 12)}.merge(data))
  end

  test "a limit is required: none, zero and junk abort without queuing anything" do
    ::Services::Books::Authors::Backfill.expects(:call).never

    ["", "0", "lots"].each do |limit|
      @task.reenable
      assert_raises(SystemExit) { capture_io { @task.invoke(limit) } }
    end
  end

  test "a number is the limit and all is every author" do
    ::Services::Books::Authors::Backfill.expects(:call).with(limit: 100).returns(result)
    ::Services::Books::Authors::Backfill.expects(:call).with(limit: nil).returns(result)

    assert_output(/Queued 2 author\(s\) for the Wikidata step/) { @task.invoke("100") }
    @task.reenable
    assert_output(/books:authors:enrich_report\[/) { @task.invoke("all") }
  end
end
```

- [ ] **Step 4: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/queued_chain_test.rb test/lib/services/books/authors/backfill_test.rb test/lib/tasks/books_authors_rake_test.rb`

Expected:
- The service tests error with `NameError`.
- The rake test errors because `lib/tasks/books/authors.rake` does not exist.

- [ ] **Step 5: Create `QueuedChain`**

Create `web-app/app/lib/services/books/authors/queued_chain.rb`:

```ruby
# frozen_string_literal: true

require "sidekiq/api"

module Services
  module Books
    module Authors
      # The authors with an author-chain job waiting in Sidekiq: scheduled,
      # waiting to retry, or enqueued on the low queue. A job running at this
      # moment is in none of these and is missed; the backfill accepts that.
      # Reads each set whole, so a pass costs about a second per ten thousand
      # jobs.
      class QueuedChain
        JOBS = %w[Books::Authors::WikidataJob Books::Authors::ViafJob Books::Authors::EnrichJob].freeze
        QUEUE = "low"

        def self.by_job
          found = JOBS.index_with { [] }
          [::Sidekiq::ScheduledSet.new, ::Sidekiq::RetrySet.new, ::Sidekiq::Queue.new(QUEUE)].each do |source|
            source.each { |job| found[job.klass] << job.args.first.to_i if found.key?(job.klass) }
          end
          found
        end

        def self.author_ids = by_job.values.flatten.to_set
      end
    end
  end
end
```

- [ ] **Step 6: Create `Backfill`**

Create `web-app/app/lib/services/books/authors/backfill.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The backfill (spec §13). Queues the author chain for every author the
      # Wikidata step has not processed (LedgerRun.processed; a placeholder
      # never is, so placeholders are left out): ranked authors first by
      # rank, then the rest by how many books they wrote. Each WikidataJob
      # starts SPACING seconds after the one before, the Wikidata pace, with
      # research off for the whole chain.
      #
      # An author whose Wikidata step missed and whose VIAF step never
      # finished (a failure, or a job lost) gets the VIAF step again. Its AI
      # step already ran, so the job is told so (enrich_queued) and queues
      # it again only through the Wikidata hop, when VIAF finds an item.
      #
      # An author with a chain job already waiting in Sidekiq is left out,
      # so a second run while the first is still scheduled queues no one
      # twice: a duplicate would skip the Wikidata step and pay for the AI
      # step again. The limit applies to each kind after that.
      class Backfill
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        SPACING = 6

        def self.call(limit:, queued: nil)
          new(limit: limit, queued: queued).call
        end

        def self.unprocessed
          ::Books::Author.where(exclude_from_rankings: false)
            .where.not(id: LedgerRun.processed(EnrichFromWikidata::KIND).select(:enrichable_id))
        end

        def initialize(limit:, queued:)
          @limit = limit
          @queued = queued
          @left_out = 0
        end

        def call
          waiting = @queued || QueuedChain.author_ids
          wikidata = take(ranked(self.class.unprocessed).pluck(:id), waiting)
          viaf = take(viaf_retries.order(:id).pluck(:id), waiting)

          wikidata.each_with_index do |id, index|
            ::Books::Authors::WikidataJob.perform_in(index * SPACING, id, false, false, false)
          end
          viaf.each { |id| ::Books::Authors::ViafJob.perform_async(id, false, true, false) }

          Result.new(success?: true, errors: [], data: {
            wikidata: wikidata.size, viaf: viaf.size, left_out: @left_out,
            wikidata_done_at: Time.current + (wikidata.size * SPACING).seconds
          })
        end

        private

        def take(ids, waiting)
          fresh = ids.reject { |id| waiting.include?(id) }
          @left_out += ids.size - fresh.size
          @limit ? fresh.first(@limit) : fresh
        end

        def ranked(scope)
          configuration = ::Books::Authors::RankingConfiguration.default_primary
          rank_join = ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Author' " \
            "AND ranked_items.item_id = books_authors.id AND ranked_items.ranking_configuration_id = ?",
            configuration&.id
          ])
          counts = ::Books::BookAuthor.where(role: :author).group(:author_id).select("author_id, COUNT(*) AS books")
          scope.joins(rank_join)
            .joins("LEFT JOIN (#{counts.to_sql}) book_counts ON book_counts.author_id = books_authors.id")
            .order(Arel.sql("ranked_items.rank ASC NULLS LAST, COALESCE(book_counts.books, 0) DESC, books_authors.id ASC"))
        end

        def viaf_retries
          wikidata = LedgerRun.processed(EnrichFromWikidata::KIND)
          ::Books::Author.where(exclude_from_rankings: false)
            .where(id: wikidata.where(outcome: :unrecognized).select(:enrichable_id))
            .where.not(id: wikidata.where(outcome: %w[applied nothing_to_apply]).select(:enrichable_id))
            .where.not(id: LedgerRun.processed(EnrichFromViaf::KIND).select(:enrichable_id))
        end
      end
    end
  end
end
```

- [ ] **Step 7: Create the rake task**

Create `web-app/lib/tasks/books/authors.rake`:

```ruby
namespace :books do
  namespace :authors do
    desc "Queue the author chain (Wikidata, VIAF on a miss, then AI with research off) for authors the Wikidata step " \
      "has not processed, ranked authors first: bin/rails \"books:authors:enrich[100]\" or [all]"
    task :enrich, [:limit] => :environment do |_task, args|
      raw = args[:limit].to_s.strip
      limit = (raw == "all") ? nil : Integer(raw, exception: false)
      unless raw == "all" || limit&.positive?
        abort "Usage: bin/rails \"books:authors:enrich[limit]\" -- a number, or all. A limit is required: a wide run is a decision."
      end

      started = Time.current
      data = ::Services::Books::Authors::Backfill.call(limit: limit).data
      spacing = ::Services::Books::Authors::Backfill::SPACING
      puts "Queued #{data[:wikidata]} author(s) for the Wikidata step, one every #{spacing}s; " \
        "the last starts about #{data[:wikidata_done_at].utc.iso8601}."
      puts "Queued #{data[:viaf]} author(s) to retry the VIAF step." if data[:viaf].positive?
      puts "Left out #{data[:left_out]} author(s) with a chain job already waiting in Sidekiq." if data[:left_out].positive?
      puts "Wikidata misses go on to VIAF at about two requests a minute; each author's AI step follows its last record step."
      puts "Report: bin/rails \"books:authors:enrich_report[#{started.utc.iso8601}]\""
    end
  end
end
```

- [ ] **Step 8: Run the tests**

Run: `bin/rails test test/lib/services/books/authors/ test/lib/tasks/books_authors_rake_test.rb`

Expected: all pass.

Then check it loads in development without queuing anything:

```bash
CI=1 bin/rails zeitwerk:check
bin/rails runner 'p Services::Books::Authors::Backfill.unprocessed.count'
```

Expected: zeitwerk is clean, and the count is about 71,000. Nothing is queued: `unprocessed` is a read.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/ lib/tasks/books/authors.rake test/lib/services/books/authors/ test/lib/tasks/books_authors_rake_test.rb
git add app/lib/services/books/authors/queued_chain.rb app/lib/services/books/authors/backfill.rb lib/tasks/books/authors.rake test/lib/services/books/authors/queued_chain_test.rb test/lib/services/books/authors/backfill_test.rb test/lib/tasks/books_authors_rake_test.rb
git commit -m "books:authors:enrich: the author backfill

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `books:authors:enrich_report[since]`

Spec §13: after `[100]`, report these before anyone runs `[all]`:
- the match rate;
- how decisions split across rules, AI and unmatched;
- how many need review;
- the real AI cost from `ai_chats`.

**Files:**
- Create: `web-app/app/lib/services/books/authors/backfill_report.rb`
- Modify: `web-app/lib/tasks/books/authors.rake`
- Test (create): `web-app/test/lib/services/books/authors/backfill_report_test.rb`
- Test (modify): `web-app/test/lib/tasks/books_authors_rake_test.rb`

**Interfaces:**
- Consumes:
  - `Backfill.unprocessed`, `Backfill::SPACING`;
  - `QueuedChain.by_job`;
  - `Viaf::Schedule#horizon`.
- Produces `BackfillReport.call(since:) → Result`. Its data:
  - `authors: Integer, matched: Integer, per_hour: Float | nil`;
  - `decisions: {"Wikidata" => {split: {"matched rule" => n, ...}, needs_review: n}, "VIAF" => {...}}`;
  - `outcomes: {kind => {"applied" => n, ...}}`, `failures: {kind => {reason => n}}`;
  - `ai: {by_model: {model => {chats:, input:, output:, web_searches:, cost:}}, cost: Float}`;
  - `remaining: Integer, waiting: {job => n}, viaf_line_ends: Time | nil`;
  - `lines: [String]`.

- [ ] **Step 1: Write the failing report test**

Create `web-app/test/lib/services/books/authors/backfill_report_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class BackfillReportTest < ActiveSupport::TestCase
        def setup
          QueuedChain.stubs(:by_job).returns({"Books::Authors::ViafJob" => [1, 2]})
          ::Viaf::Schedule.stubs(:new).returns(::Viaf::Schedule.new(redis: ::Books::OpenLibrary::FakeRedis.new))
          @since = Time.current
          travel 1.second
          @author = ::Books::Author.create!(name: "Report Author")
          @other = ::Books::Author.create!(name: "Report Other")
        end

        def decide(finder, outcome, decided_by, needs_review: false, at: Time.current)
          ::MatchDecision.create!(finder: finder.name, subject: @author, outcome: outcome, confidence: :high, decided_by: decided_by,
            needs_review: needs_review, candidates: [], created_at: at)
        end

        def ledger(author, kind, outcome, recognized: nil, reason: nil, at: Time.current)
          author.enrichments.create!(kind: kind, outcome: outcome, recognized: recognized, reason: reason, created_at: at)
        end

        def chat(model, input:, output:, web_searches: 0)
          AiChat.create!(parent: @author, model: model, provider: :openai, chat_type: :analysis,
            raw_responses: [{"usage" => {"input_tokens" => input, "output_tokens" => output}, "web_search_calls" => web_searches}])
        end

        def report = BackfillReport.call(since: @since).data

        test "splits each step's decisions by outcome and how they were decided, and counts those needing review" do
          decide(ResolveWikidata, :matched, :rule)
          decide(ResolveWikidata, :unmatched, :ai, needs_review: true)
          decide(ResolveViaf, :matched, :identifier)
          decide(ResolveWikidata, :matched, :identifier, at: @since - 1.hour)

          data = report

          assert_equal({"matched rule" => 1, "unmatched ai" => 1}, data[:decisions]["Wikidata"][:split])
          assert_equal [1, 0], [data[:decisions]["Wikidata"][:needs_review], data[:decisions]["VIAF"][:needs_review]]
          assert_equal({"matched identifier" => 1}, data[:decisions]["VIAF"][:split])
        end

        test "counts the authors the Wikidata step ran and matched, and the ledger outcomes with failure reasons" do
          ledger(@author, EnrichFromWikidata::KIND, :applied, recognized: true, at: Time.current)
          ledger(@other, EnrichFromWikidata::KIND, :unrecognized, recognized: false, at: Time.current + 1.hour)
          ledger(@other, EnrichFromViaf::KIND, :failed, reason: "viaf_error")

          data = report

          assert_equal [2, 1], data.values_at(:authors, :matched)
          assert_in_delta 2.0, data[:per_hour], 0.01
          assert_equal({"applied" => 1, "unrecognized" => 1}, data[:outcomes][EnrichFromWikidata::KIND])
          assert_equal({"viaf_error" => 1}, data[:failures][EnrichFromViaf::KIND])
        end

        test "adds up the AI calls' tokens and prices them per model" do
          chat("gpt-6-sol", input: 1_000_000, output: 100_000)
          chat("gpt-6-astra", input: 0, output: 0, web_searches: 3)
          chat("unpriced-model", input: 10, output: 10)

          ai = report[:ai]

          assert_equal({chats: 1, input: 1_000_000, output: 100_000, web_searches: 0, cost: 3.0}, ai[:by_model]["gpt-6-sol"])
          assert_in_delta 0.03, ai[:by_model]["gpt-6-astra"][:cost], 0.0001
          assert_nil ai[:by_model]["unpriced-model"][:cost]
          assert_in_delta 3.03, ai[:cost], 0.0001
        end

        test "reports what is still waiting and what remains, and says it all in lines" do
          data = report

          assert_equal({"Books::Authors::ViafJob" => 2}, data[:waiting])
          assert_operator data[:remaining], :>=, 2
          assert(data[:lines].any? { |line| line.include?("list prices") })
        end
      end
    end
  end
end
```

- [ ] **Step 2: Add the failing rake test**

In `books_authors_rake_test.rb`, change the setup's guard to load the file when `books:authors:enrich_report` is not yet defined either:

```ruby
    unless Rake::Task.task_defined?("books:authors:enrich") && Rake::Task.task_defined?("books:authors:enrich_report")
```

Then add:

```ruby
  test "the report needs a time, and prints the report's lines" do
    report = Rake::Task["books:authors:enrich_report"]
    ::Services::Books::Authors::BackfillReport.expects(:call).with(since: Time.utc(2026, 10, 2, 12))
      .returns(::Services::Books::Authors::BackfillReport::Result.new(success?: true, errors: [], data: {lines: ["one", "two"]}))

    report.reenable
    assert_raises(SystemExit) { capture_io { report.invoke("") } }
    report.reenable
    assert_output("one\ntwo\n") { report.invoke("2026-10-02T12:00:00Z") }
  end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/backfill_report_test.rb test/lib/tasks/books_authors_rake_test.rb`

Expected:
- The report tests error with `NameError`.
- The rake test fails: `Don't know how to build task 'books:authors:enrich_report'`.

- [ ] **Step 4: Create the report**

Create `web-app/app/lib/services/books/authors/backfill_report.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # What the author steps did since a time (spec §13), read after a
      # backfill batch and before a wider one: how many authors the
      # Wikidata step ran and matched and how fast, how each step's
      # decisions split and how many need review, how the ledger rows ended,
      # what the AI calls cost, and what is still waiting.
      #
      # Prices are list prices per million tokens from a 2026-09 research
      # pass, and cached input is priced in full, so the dollar figure is an
      # estimate and an upper bound; the OpenAI usage page has the bill.
      class BackfillReport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        PRICES = {
          "gpt-6-luna" => {input: 0.10, output: 0.50},
          "gpt-6-sol" => {input: 2.00, output: 10.00},
          "gpt-6-astra" => {input: 10.00, output: 50.00}
        }.freeze
        WEB_SEARCH = 0.01
        FINDERS = {
          "Wikidata" => "Services::Books::Authors::ResolveWikidata",
          "VIAF" => "Services::Books::Authors::ResolveViaf"
        }.freeze
        KINDS = %w[books.author_wikidata books.author_viaf books.author_facts].freeze

        def self.call(since:) = new(since: since).call

        def initialize(since:)
          @since = since
        end

        def call
          data = {
            authors: wikidata_rows.distinct.count(:enrichable_id),
            matched: wikidata_rows.where(recognized: true).distinct.count(:enrichable_id),
            per_hour: per_hour,
            decisions: FINDERS.transform_values { |finder| decision_numbers(finder) },
            outcomes: KINDS.index_with { |kind| rows(kind).group(:outcome).count },
            failures: KINDS.index_with { |kind| rows(kind).where(outcome: :failed).group(:reason).count },
            ai: ai_numbers,
            remaining: Backfill.unprocessed.count,
            waiting: QueuedChain.by_job.transform_values(&:size).select { |_job, count| count.positive? },
            viaf_line_ends: ::Viaf::Schedule.new.horizon
          }
          Result.new(success?: true, data: data.merge(lines: lines(data)), errors: [])
        end

        private

        def rows(kind) = ::Enrichment.for_kind(kind).where(enrichable_type: "Books::Author", created_at: @since..)

        def wikidata_rows = rows(EnrichFromWikidata::KIND)

        def per_hour
          first, last = wikidata_rows.pick(Arel.sql("MIN(created_at)"), Arel.sql("MAX(created_at)"))
          return nil if first.nil? || last <= first

          wikidata_rows.distinct.count(:enrichable_id) / ((last - first) / 3600.0)
        end

        def decision_numbers(finder)
          scope = ::MatchDecision.where(finder: finder, subject_type: "Books::Author", created_at: @since..)
          {
            split: scope.group(:outcome, :decided_by).count.transform_keys { |outcome, decided_by| "#{outcome} #{decided_by}" },
            needs_review: scope.where(needs_review: true).count
          }
        end

        def ai_numbers
          by_model = {}
          ::AiChat.where(parent_type: "Books::Author", created_at: @since..).find_each do |chat|
            totals = (by_model[chat.model] ||= {chats: 0, input: 0, output: 0, web_searches: 0})
            totals[:chats] += 1
            Array(chat.raw_responses).each do |response|
              next unless response.is_a?(Hash)

              totals[:input] += response.dig("usage", "input_tokens").to_i
              totals[:output] += response.dig("usage", "output_tokens").to_i
              totals[:web_searches] += response["web_search_calls"].to_i
            end
          end
          by_model.each { |model, totals| totals[:cost] = cost(model, totals) }
          {by_model: by_model, cost: by_model.values.sum { |totals| totals[:cost].to_f }}
        end

        def cost(model, totals)
          price = PRICES[model]
          return nil unless price

          ((totals[:input] * price[:input]) + (totals[:output] * price[:output])) / 1_000_000.0 + (totals[:web_searches] * WEB_SEARCH)
        end

        def lines(data)
          authors = data[:authors]
          rate = authors.positive? ? (100.0 * data[:matched] / authors).round : 0
          per_author = authors.positive? ? data[:ai][:cost] / authors : nil
          out = ["Since #{@since.utc.iso8601}"]
          out << "Wikidata step: #{authors} author(s), #{data[:matched]} matched (#{rate}%)" \
            "#{", #{data[:per_hour].round(1)} an hour" if data[:per_hour]}"
          data[:decisions].each do |label, numbers|
            split = numbers[:split].map { |key, count| "#{key} #{count}" }.join(", ").presence || "none"
            out << "#{label} decisions: #{split}; #{numbers[:needs_review]} need review"
          end
          data[:outcomes].each do |kind, counts|
            failed = data[:failures][kind].map { |reason, count| "#{reason || "no reason"} #{count}" }.join(", ")
            out << "#{kind}: #{counts.map { |outcome, count| "#{outcome} #{count}" }.join(", ").presence || "none"}" \
              "#{"; failed: #{failed}" if failed.present?}"
          end
          data[:ai][:by_model].each do |model, totals|
            price = totals[:cost] ? format("$%.2f", totals[:cost]) : "no list price"
            out << "AI #{model}: #{totals[:chats]} call(s), #{totals[:input]} in / #{totals[:output]} out tokens, " \
              "#{totals[:web_searches]} web search(es), #{price}"
          end
          out << format("AI total: about $%.2f at list prices (cached input priced in full; the OpenAI usage page has the bill)", data[:ai][:cost])
          if per_author
            out << format("Per author: about $%.4f. The %d author(s) the Wikidata step has not processed would cost about $%.0f, " \
              "and take about %.1f hours for the Wikidata step at one every %ds.",
              per_author, data[:remaining], per_author * data[:remaining], data[:remaining] * Backfill::SPACING / 3600.0, Backfill::SPACING)
          end
          waiting = data[:waiting].map { |job, count| "#{job.demodulize} #{count}" }.join(", ").presence || "nothing"
          out << "Waiting in Sidekiq: #{waiting}#{"; the VIAF line runs until about #{data[:viaf_line_ends].utc.iso8601}" if data[:viaf_line_ends]}"
          out
        end
      end
    end
  end
end
```

- [ ] **Step 5: Add the rake task**

In `web-app/lib/tasks/books/authors.rake`, inside `namespace :authors`, after the `enrich` task, add:

```ruby
    desc "Report what the author steps did since a time, before a wider backfill: " \
      "bin/rails \"books:authors:enrich_report[2026-10-02T12:00:00Z]\""
    task :enrich_report, [:since] => :environment do |_task, args|
      since = begin
        Time.zone.parse(args[:since].to_s)
      rescue ArgumentError
        nil
      end
      abort "Usage: bin/rails \"books:authors:enrich_report[ISO-8601 time]\" -- the time the batch was queued" if since.nil?

      puts ::Services::Books::Authors::BackfillReport.call(since: since).data[:lines]
    end
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/books/authors/ test/lib/tasks/books_authors_rake_test.rb`

Expected: all pass.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/backfill_report.rb lib/tasks/books/authors.rake test/lib/services/books/authors/backfill_report_test.rb test/lib/tasks/books_authors_rake_test.rb
git add app/lib/services/books/authors/backfill_report.rb lib/tasks/books/authors.rake test/lib/services/books/authors/backfill_report_test.rb test/lib/tasks/books_authors_rake_test.rb
git commit -m "books:authors:enrich_report: what a backfill batch did and what it cost

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Docs, the spec amendment, and the whole-suite check

**Files:**
- Modify: `docs/features/books-author-enrichment.md`
- Modify: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` (an increment-6 amendment at the end of §13)

- [ ] **Step 1: Update the feature doc**

In `docs/features/books-author-enrichment.md`:

1. **"The chain today"** (line 15 on): add one sentence saying `allow_research` travels with the author through every job. Imports leave it on; the backfill turns it off.

2. **"Legacy Wikipedia cleanup"** (line 199 on): add a paragraph: "A description deprecated only because an earlier run matched no one (`author_unmatched`) is judged again when a later run matches. That later run is usually the forced one after VIAF found the item. If the page is the matched item's article, the description goes back to normal rank (verdict `restored`); otherwise it stays (`left_deprecated`). Rejecting that match deprecates a restored description again."

3. **"VIAF" → "Pacing"** (line 284 on):
   - Replace the sentence beginning "Either way `Viaf::Client#get` raises `Viaf::Exceptions::RateLimited`, and `Books::Authors::ViafJob` reschedules itself for the wait plus jitter rather than blocking a worker thread" with:

     "Either way `Viaf::Client#get` raises `Viaf::Exceptions::RateLimited`. `Books::Authors::ViafJob` then takes the next start time in `Viaf::Schedule`'s line rather than blocking a worker thread. The line is a Redis hash shared by every worker. Start times are `SLOT_SECONDS` (90) apart, and none is earlier than the wait VIAF asked for. A backlog of N waiting authors therefore runs once each, in turn, instead of every job retrying on the same short delay. When VIAF is paused, or the start is more than `ViafJob::CHAIN_PATIENCE` (10 minutes) away, the author goes on to the AI step at once and VIAF's facts land as fills later."
   - Keep the remaining sentences about 429s and redirect hops.

4. **"The ledger":**
   - After the "Processed" paragraph, add: "The rule lives in one place, `Services::Books::Authors::LedgerRun`. Both record steps include it, and the backfill selects with `LedgerRun.processed(kind)`. An error none of a step's rescues expected (a bug, a constraint) writes one `failed` row with reason `unexpected_error`. It's tied to the decision if one was recorded, and the chain goes on to the AI step. Before increment 6 such an error raised and left the decision with no ledger row."
   - In the paragraph beginning "**A re-run is only cheap in the cases that decide early.**", change "every candidate the search turns up is fetched again" to "every candidate the searches turn up is fetched again, in one entities call for all of the author's search names".

5. **"Operating":**
   - Replace the paragraph "There is no backfill rake task and no admin button yet -- both are increment 6. …" with a new subsection:

```markdown
### The backfill

`bin/rails "books:authors:enrich[100]"` (or `[all]`) queues the chain for authors the Wikidata step has
not processed (`LedgerRun.processed`; placeholders never are): ranked authors first by rank under
the primary authors configuration, then the rest by how many books they wrote. Each `WikidataJob`
starts `Backfill::SPACING` (6) seconds after the one before, with research off for the whole chain.
A limit is required; `all` is the decision to run wide.

It also re-queues the VIAF step for any author whose Wikidata step missed and whose VIAF step never
finished, with `enrich_queued` set because that author's AI step already ran. It leaves out every
author with a `Books::Authors::*` job already scheduled, retrying, or on the low queue
(`QueuedChain`), so a second run while the first is still going queues no one twice.

It prints the counts, when the last Wikidata job starts, and the report command:
`bin/rails "books:authors:enrich_report[<time the batch was queued>]"`. The report gives:
- how many authors the Wikidata step ran and matched, and how many an hour;
- each step's decisions split by outcome and how they were decided, and how many need review;
- the ledger outcomes and failure reasons;
- AI tokens and an estimated cost per model, at list prices;
- the cost and Wikidata time extrapolated to the authors still unprocessed;
- what is still waiting in Sidekiq, and when the VIAF line runs out.

Run `[100]` first and read the report before `[all]` (spec §13). Wikidata alone for ~71k authors is
about five days at this pace. VIAF serves 200–300 authors a day, so its share of the misses runs on
for weeks after that; the AI step does not wait for it.

The Wikidata and VIAF clients cache labels, country codes and AutoSuggest answers in
`config.x.external_api_cache`, a Redis store (namespace `external-api`). It survives deploys, which
a multi-day run spans; `Rails.cache` in production is a per-container file store.
```

   - In the "Launch sequence" subsection, after the paragraph that ends "…the bridge stage can still fire for the authors it reaches.", add:

```markdown
**Ids come back from the decisions.** Before resolving, each record step calls
`RestoreIdentifier`. When the author holds no Wikidata (or VIAF) id, it puts back the id its step's
latest decision chose, provided that decision:
- is older than the author row (an earlier era);
- matched;
- is not rejected;
- was never flagged for review, or was reviewed since.

The id must also be neither rejected for this author nor held by another author. The held-id
stage then finds it and the stored record answers, so a re-migrated author whose earlier match
stands costs no search, no AI selection and none of VIAF's daily budget. The run's ledger row
records it as the fact `restored_identifier`.

The launch order after the final data migration is: `data_migration:all` (which runs
`:author_countries`), then `bin/rails "books:authors:enrich[all]"`.
```

   - Then edit the two paragraphs that say the re-run pushes "*more* authors into the name-search path" and that the held-id stage "cannot fire on the first pass after a re-migration". They should now say this is what happens for an author with no carried-over decision, and point to the paragraph above for the rest.

- [ ] **Step 2: Amend the spec**

At the end of §13 in `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`, after its last bullet, add:

```markdown
**Increment 6 amendment (2026-10-02).** As built:

- **The task.** `books:authors:enrich[limit|all]` with the selection above. Placeholders are left
  out. A rejected run does not count as processed.
- **Duplicates.** Authors already waiting in Sidekiq are left out, so a second run never doubles
  the AI cost.
- **VIAF retries.** Authors whose Wikidata step missed and whose VIAF step never finished get the
  VIAF step again, with the AI step marked already queued.
- **The report.** `books:authors:enrich_report[since]` gives the report §13 asks for, plus
  throughput, ledger failure reasons, and the extrapolation to the remaining authors.
- **VIAF scale.**
  - VIAF serves 200–300 authors a day, far below the backfill's Wikidata misses.
  - Waiting VIAF jobs take start times 90 seconds apart from a shared line (`Viaf::Schedule`)
    instead of all retrying on a short delay.
  - A start more than ten minutes off sends the author to the AI step at once, as a pause does
    (§8: the chain never waits on VIAF).
- **Ids after a re-migration** (§14). Each record step puts back the id its latest earlier-era,
  matched, unrejected and trusted decision chose, so a re-migration re-run costs no search and no
  AI selection for those authors.
- **Legacy descriptions.** A description deprecated as `author_unmatched` is restored when a later
  run matches its page's item.
- **Cache.** The Wikidata and VIAF clients cache in Redis (`config.x.external_api_cache`), not the
  per-container file store, because a backfill spans deploys.
```

- [ ] **Step 3: Run the whole suite, lint, and the load check**

Run, from `web-app/`:

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected:
- the suite has 0 failures, 0 errors, and no new warning lines;
- standardrb has no offenses;
- zeitwerk says "All is good!".

- [ ] **Step 4: Commit**

```bash
git add docs/features/books-author-enrichment.md docs/superpowers/specs/2026-09-27-books-author-importer-design.md
git commit -m "Docs: the author backfill, the VIAF line, restored ids

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the branch is green: the 100-author run (needs Shane's go-ahead)

This makes real Wikidata, VIAF and OpenAI calls against the development database. Do not start it without Shane's explicit go-ahead. Expect about $1–3 of AI.

1. **Snapshot first:** `bin/snapshot-dev-db.sh --label pre-author-backfill-100`.
2. **Load the author countries.** Development has 6 `books_author_countries` rows. Without them nearly every author looks incomplete to the AI step, and the cost figure would overstate production.
   - The legacy books database has to be present.
   - Run `bin/rails data_migration:author_countries`. It's additive.
3. **Start Sidekiq for this checkout** with the low queue. Shane runs `bin/dev`, or the agent runs `bundle exec sidekiq` in the background, with Shane's go-ahead.
4. **Queue the batch:** `bin/rails "books:authors:enrich[100]"`.
5. **Wait.** The Wikidata step takes about 10 minutes; the VIAF share continues at about one author every 90 seconds.
6. **Run the printed `books:authors:enrich_report[...]`** once the Wikidata step is through, and again after an hour for the VIAF tail.
7. **Bring Shane the report's lines, plus:**
   - three or four decisions to spot-check on the audit pages: one AI-decided match, one unmatched, one needing review;
   - the cost and time extrapolation for `[all]`.

`[all]` in production belongs to the launch sequence after the final data migration. It is Shane's decision, made after he reads this report.
