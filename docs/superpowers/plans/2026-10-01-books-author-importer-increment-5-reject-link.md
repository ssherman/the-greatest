# Books author importer, increment 5: the Reject link — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An admin can reject a wrong Wikidata or VIAF link from its decision page; the reject undoes what the link wrote on the author, deprecates the AI description written from it, marks the decision rejected, and runs the author's steps again without ever choosing that record for that author.

**Architecture:** A `verdict` column on `match_decisions` records the rejection. `RejectedRecords` reads an author's rejected records, and the two resolvers and `FactSheet#stamp` consult it, so a rejected record is never considered or stamped again. `RevertFacts` undoes one run from its ledger facts. `RejectExternalLink` decides what to reject (the decision, its same-record siblings, and the Wikidata decision a VIAF run led to), reverts each run and the AI runs that used the record, deprecates the AI description, marks the decisions, and queues `WikidataJob(author_id, true)`. The audit page gets a Reject link button behind the merge action's delete gate.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + Mocha, Sidekiq, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §12 (also §5.1 step 4, §8, §9, §16 item 5).

## Global Constraints

- Run every Rails command from `web-app/` in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-author-importer-inc5`.
- Lint is `bundle exec standardrb` (never `bin/rubocop`, never brakeman). Tests: `bin/rails test <path>`.
- Minitest 6: `assert_equal nil, x` is a hard failure; use `assert_nil`, or compare tuples.
- Sidekiq runs inline in tests (`Sidekiq.testing!(:inline)`): every test that reaches `WikidataJob.perform_async` must stub it (`::Books::Authors::WikidataJob.expects(:perform_async)...`), or the real chain runs.
- No test calls Wikidata, Wikipedia, VIAF or OpenAI. Use `FakeWikidataClient`, `FakeViafClient` and Mocha stubs.
- Inside `Services::Books::Authors`, `Books` resolves to `Services::Books`: write model constants root-anchored (`::Books::Author`, `::MatchDecision`, `::Enrichment`).
- Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Migrations come from the generator (`bin/rails generate migration ...`). All worktrees share one development database: after `db:migrate`, diff `db/schema.rb` and keep only the `define(version:)` bump and this migration's column; revert annotate changes to models other than `MatchDecision`.
- Never run a destructive command against the development database. Adding a nullable column is not destructive.
- Commit messages end with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (an implementer subagent uses its own model name).
- Class comments follow the surrounding files: a short comment block above each new class, the spec section in it; no separate class docs.

## Decisions beyond the spec (for Shane's review)

The spec says what a reject removes; implementing it raised these, each decided here:

1. **A reject is about the record, not one decision.** Every decision of the same finder that selected the same record for this author, and isn't rejected yet, is rejected with it. Otherwise an older or newer decision for the same record would keep feeding it to the AI step as evidence.
2. **A rejected VIAF run takes its Wikidata follow-up with it.** When the VIAF run stamped a Wikidata id, the Wikidata decisions that matched that id at or after the VIAF decision are rejected and reverted too (the carry-forward from increment 3's review). Rejecting a Wikidata decision does not reject the VIAF decision; a VIAF re-run cannot bring the Wikidata id back (decision 5).
3. **The record's own id and its Wikipedia article link are removed whoever added them.** The QID (for Wikidata) or VIAF id (for VIAF), and the Wikipedia link of the rejected item, name the rejected record, so they go even when the run found them already set. Every other value goes only if the rejected run applied it.
4. **An AI run that used the record as evidence is reverted too.** Its applied years, gender and countries are removed when unchanged since, not only its description. Those values came from the wrong person's records. The re-run fills them again from the right evidence.
5. **A rejected record's id is never stamped on that author again**, by any step: `FactSheet#stamp` returns `"rejected"`. Without this, a VIAF cluster naming the rejected QID would re-stamp it on the re-run.
6. **A run whose decision was rejected stops counting.** `MatchedRecords` ignores it (no rejected evidence reaches the AI step), and the Wikidata and VIAF steps' `processed?` checks skip it, so a failed re-run doesn't strand the author as "already processed".
7. **A deprecated AI description no longer counts as present.** The AI step's completeness check and both "already set" checks ignore it, and the applier writes the new description over it and sets it back to normal rank.
8. **Legacy Wikipedia descriptions the rejected run deprecated go back to normal rank.** The rank before isn't recorded; normal never collides with the one-preferred index. The re-run judges them again.
9. **Authorization is the merge action's delete gate** (`require_domain_delete!` / `current_user_can_delete?`): a reject removes data.
10. **`verdict` has `confirmed` and `rejected` as the spec says; nothing sets `confirmed` yet.**

## Review Focus

1. **A value a person changed after the run survives the reject** (a corrected birth year, a gender set by hand). Pinned in Task 4 and Task 5.
2. **Rejecting twice (a double click, two tabs) undoes once and queues one job.** Pinned in Task 5.
3. **A run that applied nothing** (a held-id conflict, or every fact already set) **loses only the record's own id and link.** Pinned in Task 5.
4. **Another author holding the same identifier value keeps it.** Identifier values are not unique across authors in legacy data. Pinned in Task 4.
5. **Ledger rows written before country ids were recorded** (every row from increments 2–4, production included) **still have their countries removed, by name.** Pinned in Task 4.

---

## File map

- Create `web-app/db/migrate/<timestamp>_add_verdict_to_match_decisions.rb` — the nullable `verdict` integer.
- Modify `web-app/app/models/match_decision.rb` — `verdict` enum, `selected_candidate`.
- Create `web-app/app/lib/services/books/authors/rejected_records.rb` — an author's rejected records by source.
- Modify `web-app/app/lib/services/books/authors/fact_sheet.rb` — `stamp` refuses rejected ids; `countries` records `country_ids`.
- Modify `web-app/app/lib/services/books/authors/resolve_wikidata.rb`, `resolve_viaf.rb` — drop rejected records.
- Modify `web-app/app/lib/services/books/authors/matched_records.rb`, `enrich_from_wikidata.rb`, `enrich_from_viaf.rb` — rejected decisions stop counting.
- Modify `web-app/app/lib/services/books/authors/enrich_author.rb`, `apply_author_facts.rb` — a deprecated AI description stops counting.
- Create `web-app/app/lib/services/books/authors/revert_facts.rb` — undo one run from its facts.
- Create `web-app/app/lib/services/books/authors/reject_external_link.rb` — the reject.
- Modify `web-app/app/lib/data_importers/finder_registry.rb` — `reject_service` on entries.
- Modify `web-app/app/controllers/admin/match_decisions_base_controller.rb`, `web-app/config/routes.rb` (books block), `web-app/app/views/admin/match_decisions_base/_actions.html.erb`, `show.html.erb` — the action, button and verdict.
- Modify `web-app/lib/tasks/e2e.rake`; create `web-app/e2e/tests/books/admin/reject-link.spec.ts`.
- Docs: `docs/features/books-author-enrichment.md`, `docs/features/import-finder.md`, `docs/features/e2e-testing.md`, the spec's §12.
- Tests mirror each file under `web-app/test/`.

---

### Task 1: The verdict column, rejected records, and a FactSheet that refuses them

**Files:**
- Create: `web-app/db/migrate/<timestamp>_add_verdict_to_match_decisions.rb` (generator)
- Modify: `web-app/app/models/match_decision.rb`, `web-app/db/schema.rb`
- Create: `web-app/app/lib/services/books/authors/rejected_records.rb`
- Modify: `web-app/app/lib/services/books/authors/fact_sheet.rb`
- Test: `web-app/test/models/match_decision_test.rb`, `web-app/test/lib/services/books/authors/rejected_records_test.rb` (create), `web-app/test/lib/services/books/authors/fact_sheet_test.rb`

**Interfaces:**
- Produces: `MatchDecision#verdict` (enum `confirmed: 0, rejected: 1`, `prefix: true`, nullable) giving `verdict_rejected?`, `MatchDecision.verdict_rejected`, `MatchDecision.verdicts[:rejected] == 1`.
- Produces: `MatchDecision#selected_candidate` → the candidate Hash `selected_index` names (1-based), or nil.
- Produces: `Services::Books::Authors::RejectedRecords.new(author)` with `#ids(source) → Set<String>`, `#include?(source, key) → Boolean`, `#identifier?(type, value) → Boolean`; `RejectedRecords::FINDERS` (`{"Services::Books::Authors::ResolveWikidata" => "wikidata", "Services::Books::Authors::ResolveViaf" => "viaf"}`). `source` may be a String or Symbol.
- Produces: `FactSheet#stamp` may return `"rejected"`; `FactSheet#countries` records `"country_ids"` on a filled fact.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration AddVerdictToMatchDecisions verdict:integer`

The generated file must read (adjust the version only if the generator wrote another):

```ruby
class AddVerdictToMatchDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :match_decisions, :verdict, :integer
  end
end
```

Check the bracketed version matches the other migrations in `db/migrate` (`head -1` of the newest one) and use that.

- [ ] **Step 2: Migrate and clean the schema dump**

Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`
Then: `git diff db/schema.rb`
Expected: the `define(version: ...)` bump and `t.integer "verdict"` inside `create_table "match_decisions"`. Remove any other hunk (another worktree's migrations) with an editor; never commit them. `git status` must show no other model files changed; revert any that are (`git checkout -- <file>`).

- [ ] **Step 3: Write the failing model tests**

Append to `web-app/test/models/match_decision_test.rb` inside the test class:

```ruby
  test "selected_candidate is the candidate selected_index names, counting from one" do
    decision = MatchDecision.new(finder: "X", candidates: [{"external_key" => "a"}, {"external_key" => "b"}], selected_index: 2)
    assert_equal "b", decision.selected_candidate["external_key"]

    decision.selected_index = nil
    assert_nil decision.selected_candidate

    decision.selected_index = 0
    assert_nil decision.selected_candidate
  end

  test "verdict is unset until a person rejects the decision" do
    decision = MatchDecision.create!(finder: "X", outcome: :matched, confidence: :high, decided_by: :rule)
    assert_nil decision.verdict

    decision.update!(verdict: :rejected)
    assert decision.reload.verdict_rejected?
    assert_includes MatchDecision.verdict_rejected, decision
  end
```

- [ ] **Step 4: Run them to see them fail**

Run: `bin/rails test test/models/match_decision_test.rb`
Expected: FAIL — `undefined method 'selected_candidate'` and `unknown attribute 'verdict'` or `undefined method 'verdict_rejected?'`.

- [ ] **Step 5: Add the enum and helper**

In `web-app/app/models/match_decision.rb`, after the `decided_by` enum:

```ruby
  # A person's verdict, set from the audit page. Only `rejected` is set today
  # (Services::Books::Authors::RejectExternalLink, spec §12).
  enum :verdict, {confirmed: 0, rejected: 1}, prefix: true
```

and after `review!`:

```ruby
  # The candidate snapshot this decision chose (selected_index counts from
  # one), or nil.
  def selected_candidate
    return nil unless selected_index&.positive?

    Array(candidates)[selected_index - 1]
  end
```

- [ ] **Step 6: Run the model tests**

Run: `bin/rails test test/models/match_decision_test.rb`
Expected: PASS.

- [ ] **Step 7: Write the failing RejectedRecords test**

Create `web-app/test/lib/services/books/authors/rejected_records_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RejectedRecordsTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Rejected Records Author")
        end

        def decision(finder, key, author: @author, verdict: :rejected, outcome: :matched)
          ::MatchDecision.create!(
            finder: finder, subject: author, outcome: outcome, confidence: :high, decided_by: :rule, verdict: verdict,
            candidates: [{"external_key" => "other"}, {"external_key" => key}], selected_index: (outcome == :matched) ? 2 : nil
          )
        end

        test "the records a person rejected for this author, by source" do
          decision(ResolveWikidata.name, "Q1")
          decision(ResolveViaf.name, "5391")
          decision(ResolveWikidata.name, "Q2", verdict: nil)
          decision(ResolveWikidata.name, "Q3", author: ::Books::Author.create!(name: "Someone Else"))
          decision("DataImporters::Books::Author::Finder", "Q4")

          rejected = RejectedRecords.new(@author)

          assert_equal [Set["Q1"], Set["5391"]], [rejected.ids(:wikidata), rejected.ids("viaf")]
          assert rejected.include?(:wikidata, "Q1")
          assert_not rejected.include?(:wikidata, "Q2")
        end

        test "an identifier is rejected when it names a rejected record of its source" do
          decision(ResolveWikidata.name, "Q1")
          rejected = RejectedRecords.new(@author)

          assert rejected.identifier?("books_author_wikidata_qid", "Q1")
          assert rejected.identifier?(:books_author_wikidata_qid, "Q1")
          assert_not rejected.identifier?("books_author_viaf", "Q1")
          assert_not rejected.identifier?("books_author_isni", "Q1")
        end

        test "a rejected decision that selected nothing rejects nothing" do
          decision(ResolveWikidata.name, nil, outcome: :unmatched)

          assert_equal Set.new, RejectedRecords.new(@author).ids(:wikidata)
        end
      end
    end
  end
end
```

- [ ] **Step 8: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/authors/rejected_records_test.rb`
Expected: FAIL — `uninitialized constant Services::Books::Authors::RejectedRecords`.

- [ ] **Step 9: Write RejectedRecords**

Create `web-app/app/lib/services/books/authors/rejected_records.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The external records a person rejected for one author (spec §12): the
      # candidate each rejected Wikidata or VIAF decision selected. The
      # resolvers never consider them again, and FactSheet#stamp never puts
      # their ids back on the author. One query, on first use.
      class RejectedRecords
        FINDERS = {
          "Services::Books::Authors::ResolveWikidata" => "wikidata",
          "Services::Books::Authors::ResolveViaf" => "viaf"
        }.freeze
        IDENTIFIER_SOURCES = {
          "books_author_wikidata_qid" => "wikidata",
          "books_author_viaf" => "viaf"
        }.freeze

        def initialize(author)
          @author = author
        end

        # External keys ("Q42", "96987389").
        def ids(source) = by_source.fetch(source.to_s, Set.new)

        def include?(source, key) = ids(source).include?(key.to_s)

        # Whether stamping this identifier would bring a rejected record back.
        def identifier?(type, value)
          source = IDENTIFIER_SOURCES[type.to_s]
          source.present? && include?(source, value)
        end

        private

        def by_source
          @by_source ||= ::MatchDecision.verdict_rejected.where(subject: @author, finder: FINDERS.keys)
            .each_with_object({}) do |decision, sets|
              key = decision.selected_candidate&.dig("external_key")
              (sets[FINDERS.fetch(decision.finder)] ||= Set.new) << key.to_s if key.present?
            end
        end
      end
    end
  end
end
```

- [ ] **Step 10: Run it**

Run: `bin/rails test test/lib/services/books/authors/rejected_records_test.rb`
Expected: PASS.

- [ ] **Step 11: Write the failing FactSheet tests**

Append to `web-app/test/lib/services/books/authors/fact_sheet_test.rb` inside the class:

```ruby
        def reject_for(author, finder, key)
          ::MatchDecision.create!(finder: finder, subject: author, outcome: :matched, confidence: :high, decided_by: :rule,
            verdict: :rejected, candidates: [{"external_key" => key}], selected_index: 1)
        end

        test "an id of a record rejected for this author is never stamped" do
          reject_for(@author, ResolveViaf.name, "5391")

          @sheet.single_identifier("viaf", "books_author_viaf", "5391")

          assert_equal ["rejected", false], @sheet.facts["viaf"].values_at("reason", "applied")
          assert_not @author.identifiers.exists?(identifier_type: "books_author_viaf")
        end

        test "a record rejected for another author does not stop the stamp here" do
          reject_for(::Books::Author.create!(name: "Another Author"), ResolveWikidata.name, "Q1")

          @sheet.single_identifier("wikidata_qid", "books_author_wikidata_qid", "Q1")
          @author.save!

          assert_equal "filled", @sheet.facts["wikidata_qid"]["reason"]
          assert @author.identifiers.exists?(identifier_type: "books_author_wikidata_qid", value: "Q1")
        end

        test "a filled countries fact records the country ids, for a reject to remove" do
          country = ::Books::Country.create!(name: "Fact Sheet Country")

          @sheet.countries(["FS"]) { lookup([country]) }

          assert_equal [country.id], @sheet.facts["countries"]["country_ids"]
        end
```

- [ ] **Step 12: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/fact_sheet_test.rb`
Expected: FAIL — the first gets `"filled"` (or a stamped row), the third gets nil `country_ids`.

- [ ] **Step 13: Change FactSheet**

In `web-app/app/lib/services/books/authors/fact_sheet.rb`, replace `stamp`'s comment and first line:

```ruby
        # "filled", "already_set", "held_by_other" or "rejected": the id of a
        # record a person rejected for this author is never stamped (spec §12).
        def stamp(type, value)
          return "rejected" if rejected.identifier?(type, value)
          return "already_set" if identifier_values(type).include?(value)
```

(the rest of `stamp` unchanged). In `countries`, change the filled record line to:

```ruby
          record("countries", lookup.countries.map(&:name), applied: true, reason: "filled", unmatched: lookup.unmatched,
            country_ids: lookup.countries.map(&:id), **source)
```

and add under `private`:

```ruby
        def rejected = (@rejected ||= RejectedRecords.new(author))
```

- [ ] **Step 14: Run the FactSheet tests and the applier tests that use it**

Run: `bin/rails test test/lib/services/books/authors/fact_sheet_test.rb test/lib/services/books/authors/apply_wikidata_test.rb test/lib/services/books/authors/apply_viaf_test.rb test/lib/services/books/authors/apply_author_facts_test.rb`
Expected: PASS. If an existing test compares a whole filled `countries` fact Hash, add `"country_ids" => [...]` to its expectation; don't loosen it.

- [ ] **Step 15: Lint and commit**

Run: `bundle exec standardrb app/models/match_decision.rb app/lib/services/books/authors/rejected_records.rb app/lib/services/books/authors/fact_sheet.rb test/models/match_decision_test.rb test/lib/services/books/authors/rejected_records_test.rb test/lib/services/books/authors/fact_sheet_test.rb`

```bash
git add db/migrate db/schema.rb app/models/match_decision.rb app/lib/services/books/authors/rejected_records.rb app/lib/services/books/authors/fact_sheet.rb test/models/match_decision_test.rb test/lib/services/books/authors/rejected_records_test.rb test/lib/services/books/authors/fact_sheet_test.rb
git commit -m "Reject link: a verdict on decisions, and rejected records are never stamped again"
```

---

### Task 2: The resolvers never consider a rejected record

**Files:**
- Modify: `web-app/app/lib/services/books/authors/resolve_wikidata.rb`, `web-app/app/lib/services/books/authors/resolve_viaf.rb`
- Test: `web-app/test/lib/services/books/authors/resolve_wikidata_test.rb`, `web-app/test/lib/services/books/authors/resolve_viaf_test.rb`

**Interfaces:**
- Consumes: `RejectedRecords.new(author)`, `#include?(source, key)`, `#ids(source)` (Task 1).
- Produces: a decision's `query` carries `"rejected" => [sorted keys]` when the author has rejected records of that source (absent otherwise).

- [ ] **Step 1: Write the failing Wikidata tests**

Append inside `ResolveWikidataTest`:

```ruby
        def reject_for(author, key)
          ::MatchDecision.create!(finder: ResolveWikidata.name, subject: author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => key}], selected_index: 1)
        end

        test "a record rejected for this author is never fetched, and the run decides without it" do
          reject_for(@author, "Q7243")
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal [:unmatched, "rule"], [result.data[:outcome], result.data[:decision].decided_by]
          assert_equal [], result.data[:decision].candidates
          assert_equal ["Q7243"], result.data[:decision].query["rejected"]
          assert_not client.calls.any? { |call| call.first == :entities && call.last.include?("Q7243") }
        end

        test "an old id Wikidata merged into a rejected item is dropped too" do
          reject_for(@author, "Q7243")
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q999"]}, entities: {"Q999" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal :unmatched, result.data[:outcome]
          assert_equal [], result.data[:decision].candidates
        end

        test "a record rejected for another author is still a candidate here" do
          reject_for(::Books::Author.create!(name: "Someone Else"), "Q7243")
          hold(:books_author_wikidata_qid, "Q7243")
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal [:matched, "Q7243"], [result.data[:outcome], result.data[:entity].id]
          assert_nil result.data[:decision].query["rejected"]
        end
```

(`books_authors(:tolstoy)`'s name is "Leo Tolstoy"; if the fixture's name differs, use `@author.name` as the search key.)

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/resolve_wikidata_test.rb`
Expected: the first two FAIL (the rejected item is matched by rule or sent to the AI).

- [ ] **Step 3: Change ResolveWikidata**

In `initialize`, add `@rejected = RejectedRecords.new(author)`. Replace `gather` (keep the method's place and its comment's first two sentences):

```ruby
        # Adds the entities for these ids as candidates reached by `source`.
        # A merged item arrives under the surviving id, so two requested ids
        # can land on one candidate. A record rejected for this author (spec
        # §5.1, §12) is never fetched, and one reached through an old id is
        # dropped.
        def gather(ids, source)
          wanted = Array(ids).map(&:to_s).uniq.reject { |id| @rejected.include?(:wikidata, id) }
          load_entities(wanted).each do |entity|
            next if @rejected.include?(:wikidata, entity.id)

            candidate = (@candidates[entity.id] ||= Candidate.new(entity: entity, sources: [], titles: [], matching_titles: []))
            candidate.sources |= [source]
          end
        end
```

Change `author_snapshot` to end with `.merge(rejected_snapshot)` after its Hash literal's closing brace, and add beside it:

```ruby
        def rejected_snapshot
          ids = @rejected.ids(:wikidata)
          ids.any? ? {"rejected" => ids.to_a.sort} : {}
        end
```

- [ ] **Step 4: Run the Wikidata tests**

Run: `bin/rails test test/lib/services/books/authors/resolve_wikidata_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing VIAF tests**

Append inside `ResolveViafTest`:

```ruby
        def reject_for(author, key)
          ::MatchDecision.create!(finder: ResolveViaf.name, subject: author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => key}], selected_index: 1)
        end

        test "a suggestion of a record rejected for this author is never a candidate" do
          reject_for(@author, "5391")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => willingham}
          )

          result = resolve(client)

          assert_equal [:unmatched, "rule"], [result.data[:outcome], result.data[:decision].decided_by]
          assert_equal ["5391"], result.data[:decision].query["rejected"]
          assert_not client.called?(:cluster)
        end

        test "a held VIAF id that was rejected is not read" do
          reject_for(@author, "5391")
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          client = FakeViafClient.new(people: {"5391" => willingham})

          resolve(client)

          assert_not_includes client.clusters, "5391"
        end

        test "a cluster that comes back under a rejected id is dropped" do
          reject_for(@author, "5391")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("777", "Stacy Willingham 1991–")]},
            people: {"777" => willingham("5391")}
          )

          result = resolve(client)

          assert_equal :unmatched, result.data[:outcome]
        end
```

(The third relies on `FakeViafClient#cluster("777")` returning the person built as `willingham("5391")`, whose `viaf_id` is "5391". Read `test/support/fake_viaf_client.rb` first; if `people:` is keyed differently, key it so cluster "777" answers with that person.)

- [ ] **Step 6: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/resolve_viaf_test.rb`
Expected: the three new tests FAIL.

- [ ] **Step 7: Change ResolveViaf**

In `initialize`, add `@rejected = RejectedRecords.new(author)`.

In `held_stage`, change the first line to:

```ruby
          ids = identifier_values(VIAF).reject { |id| @rejected.include?(:viaf, id) }
```

In `search_stage`, change the suggest line to:

```ruby
          @client.suggest(author.name).each do |suggestion|
            next if @rejected.include?(:viaf, suggestion.viaf_id)

            add(suggestion.viaf_id, "name_search").suggestions << suggestion
          end
```

In `fetch`, after `candidate.person = @client.cluster(candidate.viaf_id, refresh: @refresh)`:

```ruby
          # A redirect can land on a cluster rejected for this author (spec §12).
          candidate.unavailable = "rejected" if @rejected.include?(:viaf, candidate.person.viaf_id)
```

Update the class comment's last sentence to: "Every run records one MatchDecision. A record rejected for this author is never a candidate (spec §12)." Change `author_snapshot` like ResolveWikidata's (`.merge(rejected_snapshot)` and the same helper with `:viaf`).

- [ ] **Step 8: Run both resolver suites**

Run: `bin/rails test test/lib/services/books/authors/resolve_viaf_test.rb test/lib/services/books/authors/resolve_wikidata_test.rb`
Expected: PASS.

- [ ] **Step 9: Lint and commit**

Run: `bundle exec standardrb app/lib/services/books/authors/resolve_wikidata.rb app/lib/services/books/authors/resolve_viaf.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/services/books/authors/resolve_viaf_test.rb`

```bash
git add app/lib/services/books/authors/resolve_wikidata.rb app/lib/services/books/authors/resolve_viaf.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/services/books/authors/resolve_viaf_test.rb
git commit -m "Reject link: the resolvers never consider a record rejected for the author"
```

---

### Task 3: A rejected decision and a deprecated AI description stop counting

**Files:**
- Modify: `web-app/app/lib/services/books/authors/matched_records.rb`, `enrich_from_wikidata.rb`, `enrich_from_viaf.rb`, `enrich_author.rb`, `apply_author_facts.rb`
- Test: the matching files under `web-app/test/lib/services/books/authors/`

**Interfaces:**
- Consumes: `MatchDecision#verdict_rejected?`, `#selected_candidate`, `MatchDecision.verdicts` (Task 1).
- Produces: `MatchedRecords` ignores a row whose decision is rejected; `EnrichFromWikidata#processed?` / `EnrichFromViaf#processed?` ignore such rows; `EnrichAuthor` and `ApplyAuthorFacts` treat a deprecated AI description as absent, and the applier writes over it at normal rank.

- [ ] **Step 1: Write the failing tests**

Append inside `MatchedRecordsTest`:

```ruby
        test "a decision a person rejected contributes nothing" do
          row = wikidata_match
          row.match_decision.update!(verdict: :rejected)

          records = MatchedRecords.new(@author)

          assert_nil records.wikidata
          assert_not records.matched?
          assert_equal [], records.sources
        end
```

Append inside `EnrichFromWikidataTest`:

```ruby
        test "a run whose decision a person rejected does not count as processed" do
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q1"}], selected_index: 1)
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :applied, reason: "matched Q1", match_decision: decision)

          result = EnrichFromWikidata.call(author: @author, client: FakeWikidataClient.new)

          assert_equal :unmatched, result.data[:outcome]
          assert_equal "no_match", result.data[:enrichment].reason
        end
```

Append inside `EnrichFromViafTest`:

```ruby
        test "a run whose decision a person rejected does not count as processed" do
          decision = ::MatchDecision.create!(finder: ResolveViaf.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "5391"}], selected_index: 1)
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :applied, reason: "matched 5391", match_decision: decision)

          result = EnrichFromViaf.call(author: @author, client: FakeViafClient.new)

          assert_equal :unmatched, result.data[:outcome]
        end
```

Append inside `EnrichAuthorTest`:

```ruby
        test "a deprecated AI description leaves the author incomplete, and the new one is written over it" do
          @author.update!(birth_year: 1901, gender: :female)
          @author.author_countries.create!(country: books_countries(:french))
          @author.assign_description(source: :ai_generated, content: "Written from a rejected record.").rank = :deprecated
          @author.save!
          expect_runs([:knowledge, success_result(facts)])

          EnrichAuthor.call(author: @author)

          row = @author.reload.descriptions.sole
          assert_equal [DESCRIPTION, "normal"], [row.content, row.rank]
          assert_equal "filled", rows.sole.facts["description"]["reason"]
        end
```

Append inside `ApplyAuthorFactsTest`:

```ruby
        test "a deprecated AI description is written over and returns to normal rank" do
          @author.assign_description(source: :ai_generated, content: "Written from a rejected record.").rank = :deprecated
          @author.save!

          result = apply

          row = @author.reload.descriptions.sole
          assert_equal [DESCRIPTION, "normal"], [row.content, row.rank]
          assert_equal ["filled", true], result.data[:facts]["description"].values_at("reason", "applied")
        end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/authors/matched_records_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb test/lib/services/books/authors/enrich_from_viaf_test.rb test/lib/services/books/authors/enrich_author_test.rb test/lib/services/books/authors/apply_author_facts_test.rb`
Expected: the five new tests FAIL (rejected evidence used; `skipped`/`already_processed`; `complete` or `already_set`).

- [ ] **Step 3: MatchedRecords**

In `match`, replace the `candidate =` line with:

```ruby
          candidate = decision&.matched? && !decision.verdict_rejected? && decision.selected_candidate
```

and add to the class comment, after "contributes nothing.": " Nor does one a person rejected (spec §12): the latest row stands, so an older decision is not brought back in its place."

- [ ] **Step 4: Both runners' `processed?`**

In `enrich_from_wikidata.rb` and `enrich_from_viaf.rb`, replace `processed?` with:

```ruby
        # "Newer than the author row": after the production re-migration an
        # author is re-created with its id, and the old rows no longer count.
        # Neither does a run whose decision a person rejected (spec §12). A
        # row with no decision counts, so the comparison is NULL-safe.
        def processed?
          author.enrichments.for_kind(KIND).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at)
            .left_joins(:match_decision)
            .where("match_decisions.verdict IS DISTINCT FROM ?", ::MatchDecision.verdicts[:rejected])
            .exists?
        end
```

- [ ] **Step 5: EnrichAuthor**

In `complete?`, change the descriptions clause to:

```ruby
            author.descriptions.any? { |row| HUMAN_SOURCES.include?(row.source) && !row.deprecated? }
```

and in its comment add: "A deprecated description (a rejected link's, spec §12) does not count." In `description_for`, change the `already_set` line's condition to:

```ruby
          return {text: text, review: nil, reason: "already_set"} if author.descriptions.any? { |row| row.source == "ai_generated" && !row.deprecated? }
```

- [ ] **Step 6: ApplyAuthorFacts**

In `apply_description`, change the `already_set` condition to `author.descriptions.any? { |row| row.source == "ai_generated" && !row.deprecated? }`, and after the `row = author.assign_description(...)` line add:

```ruby
          # assign_description never sets a rank. A row a rejected link
          # deprecated (spec §12) gets new text from new evidence, so it is
          # shown again.
          row.rank = :normal if row&.deprecated?
```

Update the class comment's "only when the author has no AI description yet" to "only when the author has no AI description yet, or only a deprecated one".

- [ ] **Step 7: Run the five suites**

Run the command from Step 2.
Expected: PASS.

- [ ] **Step 8: Lint and commit**

Run: `bundle exec standardrb app/lib/services/books/authors test/lib/services/books/authors`

```bash
git add app/lib/services/books/authors test/lib/services/books/authors
git commit -m "Reject link: rejected decisions and deprecated AI descriptions stop counting"
```

---

### Task 4: RevertFacts — undo one run from its ledger facts

**Files:**
- Create: `web-app/app/lib/services/books/authors/revert_facts.rb`
- Test: `web-app/test/lib/services/books/authors/revert_facts_test.rb`

**Interfaces:**
- Consumes: the facts Hash shapes the appliers write (`FactSheet#record`, `LinkWikipedia`, `CleanLegacyWikipedia`): `{"value", "applied", "reason", ...}`; `openlibrary_ids` carries `"added"`; `countries` carries `"country_ids"` (from Task 1) or only names; `legacy_wikipedia`'s value is a list of `{"description_id", "verdict", ...}`.
- Produces: `Services::Books::Authors::RevertFacts.call(author:, facts:)` → `Result` with `data[:reverted]` (Array of fact names undone). Saves the author.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books/authors/revert_facts_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RevertFactsTest < ActiveSupport::TestCase
        URL = "https://en.wikipedia.org/wiki/Revert_Facts_Author"

        def setup
          @author = ::Books::Author.create!(name: "Revert Facts Author")
        end

        def revert(facts) = RevertFacts.call(author: @author, facts: facts)

        def filled(value, **extra) = {"value" => value, "applied" => true, "reason" => "filled"}.merge(extra.stringify_keys)

        def hold(type, value, author: @author) = author.identifiers.create!(identifier_type: type, value: value)

        test "removes the identifiers the run stamped and keeps those it found already set" do
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          hold(:books_author_openlibrary_id, "OL1A")
          hold(:books_author_openlibrary_id, "OL2A")

          result = revert(
            "wikidata_qid" => filled("Q1"),
            "isni" => {"value" => "0000000121", "applied" => false, "reason" => "already_set"},
            "openlibrary_ids" => filled(["OL1A", "OL2A"], added: ["OL2A"])
          )

          assert_equal [["books_author_isni", "0000000121"], ["books_author_openlibrary_id", "OL1A"]],
            @author.identifiers.reload.pluck(:identifier_type, :value).sort
          assert_equal %w[wikidata_qid openlibrary_ids], result.data[:reverted]
        end

        test "another author holding the same value keeps it" do
          other = ::Books::Author.create!(name: "Other Author")
          hold(:books_author_viaf, "5391", author: other)
          hold(:books_author_viaf, "5391")

          revert("viaf" => filled("5391"))

          assert other.identifiers.exists?(identifier_type: "books_author_viaf", value: "5391")
          assert_not @author.identifiers.exists?(identifier_type: "books_author_viaf")
        end

        test "clears a year or gender the run wrote, and keeps one a person changed since" do
          @author.update!(birth_year: 1901, death_year: 1975, gender: :female)

          result = revert("birth_year" => filled(1901), "death_year" => filled(1980), "gender" => filled("female"))

          @author.reload
          assert_equal [nil, 1975, nil], [@author.birth_year, @author.death_year, @author.gender]
          assert_equal %w[birth_year gender], result.data[:reverted]
        end

        test "removes only the alternate names the run added" do
          @author.update!(alternate_names: ["Kept Name", "Added Name"])

          revert("alternate_names" => filled(["Added Name"]))

          assert_equal ["Kept Name"], @author.reload.alternate_names
        end

        test "removes the countries the run added, by id" do
          added = ::Books::Country.create!(name: "Revert Added")
          kept = ::Books::Country.create!(name: "Revert Kept")
          @author.author_countries.create!(country: added)
          @author.author_countries.create!(country: kept)

          revert("countries" => filled(["Revert Added"], country_ids: [added.id]))

          assert_equal [kept], @author.reload.countries.to_a
        end

        test "a ledger row from before country ids were recorded removes its countries by name" do
          added = ::Books::Country.create!(name: "Revert Named")
          @author.author_countries.create!(country: added)

          revert("countries" => filled(["Revert Named"]))

          assert_not @author.author_countries.exists?
        end

        test "removes the Wikipedia link the run added" do
          @author.external_links.create!(url: URL, name: "Wikipedia", source: :wikipedia, link_category: :information)

          revert("wikipedia" => {"value" => URL, "applied" => true, "reason" => "linked", "page" => "en:9"})

          assert_not @author.external_links.exists?
        end

        test "legacy Wikipedia descriptions the run deprecated return to normal rank" do
          row = @author.assign_description(source: :wikipedia, content: "A legacy lead.", source_url: URL)
          row.rank = :deprecated
          @author.save!

          revert("legacy_wikipedia" => {"value" => [{"description_id" => row.id, "verdict" => "deprecated", "why" => "different_item"}],
                                        "applied" => true, "reason" => "deprecated"})

          assert_equal "normal", row.reload.rank
        end

        test "facts not applied, and facts it does not know, are left alone" do
          @author.update!(birth_year: 1901)

          result = revert("birth_year" => {"value" => 1901, "applied" => false, "reason" => "conflict"},
            "description" => filled("Text"), "sources" => {"value" => [], "applied" => false, "reason" => "input"})

          assert_equal 1901, @author.reload.birth_year
          assert_equal [], result.data[:reverted]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/authors/revert_facts_test.rb`
Expected: FAIL — `uninitialized constant Services::Books::Authors::RevertFacts`.

- [ ] **Step 3: Write RevertFacts**

Create `web-app/app/lib/services/books/authors/revert_facts.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Undoes what one author-step run applied, from the facts its ledger
      # row recorded (spec §12): the identifiers it stamped, the Wikipedia
      # link it added, the alternate names and countries it added, the legacy
      # Wikipedia descriptions it deprecated, and each year or gender it wrote
      # that still holds the value written. A value changed since is a
      # person's, and stays. Only facts marked applied are touched, and only
      # this author's rows. Saves the author.
      class RevertFacts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        IDENTIFIERS = {
          "wikidata_qid" => "books_author_wikidata_qid",
          "viaf" => "books_author_viaf",
          "isni" => "books_author_isni",
          "lcnaf" => "books_author_lcnaf",
          "goodreads_id" => "books_author_goodreads_id",
          "librarything_id" => "books_author_librarything_id"
        }.freeze
        OPEN_LIBRARY = "books_author_openlibrary_id"
        SCALARS = %w[birth_year death_year gender].freeze

        def self.call(author:, facts:)
          new(author: author, facts: facts).call
        end

        def initialize(author:, facts:)
          @author = author
          @facts = facts.to_h
        end

        def call
          reverted = @facts.filter_map do |name, fact|
            name if fact.is_a?(Hash) && fact["applied"] == true && revert(name, fact)
          end
          author.identifiers.reset
          author.author_countries.reset
          author.external_links.reset
          author.save!
          Result.new(success?: true, data: {reverted: reverted}, errors: [])
        end

        private

        attr_reader :author

        # true when something was undone.
        def revert(name, fact)
          case name
          when *IDENTIFIERS.keys then destroy(author.identifiers.where(identifier_type: IDENTIFIERS.fetch(name), value: fact["value"].to_s))
          when "openlibrary_ids" then destroy(author.identifiers.where(identifier_type: OPEN_LIBRARY, value: Array(fact["added"]).map(&:to_s)))
          when *SCALARS then clear(name, fact["value"])
          when "alternate_names" then remove_alternate_names(Array(fact["value"]))
          when "countries" then destroy(added_countries(fact))
          when "wikipedia" then destroy(author.external_links.where(url: fact["value"].to_s))
          when "legacy_wikipedia" then restore_legacy(Array(fact["value"]))
          else false
          end
        end

        def destroy(scope)
          rows = scope.to_a
          rows.each(&:destroy!)
          rows.any?
        end

        def clear(name, value)
          return false if value.nil? || author.public_send(name).to_s != value.to_s

          author.public_send(:"#{name}=", nil)
          true
        end

        def remove_alternate_names(names)
          keys = names.map { |name| name_key(name) }.to_set
          current = Array(author.alternate_names)
          kept = current.reject { |name| keys.include?(name_key(name)) }
          return false if kept.size == current.size

          author.alternate_names = kept
          true
        end

        # Ledger rows written before country ids were recorded name the countries.
        def added_countries(fact)
          return author.author_countries.where(country_id: Array(fact["country_ids"])) if fact.key?("country_ids")

          author.author_countries.joins(:country).where(books_countries: {name: Array(fact["value"])})
        end

        # The rank before is not recorded; normal never collides with the
        # one-preferred index. The next Wikidata run judges them again.
        def restore_legacy(verdicts)
          ids = verdicts.select { |verdict| verdict["verdict"] == "deprecated" }.map { |verdict| verdict["description_id"] }
          rows = author.descriptions.select { |row| ids.include?(row.id) && row.deprecated? }
          rows.each { |row| row.update!(rank: :normal) }
          rows.any?
        end

        def name_key(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s.downcase
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it**

Run: `bin/rails test test/lib/services/books/authors/revert_facts_test.rb`
Expected: PASS. If `assign_description(source: :wikipedia, ...)` needs a license or other attribute to save, set what the `Description` validations require; don't weaken the assertion.

- [ ] **Step 5: Lint and commit**

Run: `bundle exec standardrb app/lib/services/books/authors/revert_facts.rb test/lib/services/books/authors/revert_facts_test.rb`

```bash
git add app/lib/services/books/authors/revert_facts.rb test/lib/services/books/authors/revert_facts_test.rb
git commit -m "Reject link: RevertFacts undoes one run from its ledger facts"
```

---

### Task 5: RejectExternalLink

**Files:**
- Create: `web-app/app/lib/services/books/authors/reject_external_link.rb`
- Test: `web-app/test/lib/services/books/authors/reject_external_link_test.rb`
- Docs: `docs/features/books-author-enrichment.md`, `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §12

**Interfaces:**
- Consumes: `RejectedRecords::FINDERS` (Task 1), `MatchDecision#selected_candidate` / `#verdict_rejected?` / `#review!(by:, note:)`, `RevertFacts.call(author:, facts:)` (Task 4), `EnrichAuthor::KIND` (`"books.author_facts"`), `ResolveWikidata.name`, `::Books::Authors::WikidataJob.perform_async(author_id, refresh)`.
- Produces: `Services::Books::Authors::RejectExternalLink.call(decision:, user:)` → `Result`. On success `data` is `{decisions: [MatchDecision, ...] (the given one first), reverted: [String, ...] (fact names, unique), descriptions_deprecated: Integer}`. On refusal `success?` is false and `errors` holds one sentence; nothing changes and nothing is queued.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books/authors/reject_external_link_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RejectExternalLinkTest < ActiveSupport::TestCase
        URL = "https://en.wikipedia.org/wiki/Reject_Link_Author"

        def setup
          @author = ::Books::Author.create!(name: "Reject Link Author")
          @user = users(:admin_user)
        end

        def decision(finder, key, outcome: :matched, created_at: Time.current)
          ::MatchDecision.create!(
            finder: finder, subject: @author, outcome: outcome, confidence: :medium, decided_by: :ai, needs_review: true,
            candidates: [{"external_source" => "x", "external_key" => key}], selected_index: (outcome == :matched) ? 1 : nil,
            created_at: created_at
          )
        end

        def ledger(kind, decision, facts)
          @author.enrichments.create!(kind: kind, provider: "test", outcome: :applied, reason: "matched", facts: facts,
            match_decision: decision)
        end

        def ai_run(sources:, facts: {})
          @author.enrichments.create!(kind: EnrichAuthor::KIND, outcome: :applied,
            facts: facts.merge("sources" => {"value" => sources, "applied" => false, "reason" => "input"}))
        end

        def filled(value, **extra) = {"value" => value, "applied" => true, "reason" => "filled"}.merge(extra.stringify_keys)

        def hold(type, value) = @author.identifiers.create!(identifier_type: type, value: value)

        def expect_rerun(times: 1)
          ::Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true).times(times)
        end

        def reject(target) = RejectExternalLink.call(decision: target, user: @user)

        test "reverts what the run applied, removes the record's own id and link, rejects and reviews, and runs Wikidata again" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          @author.update!(birth_year: 1901)
          @author.external_links.create!(url: URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
          ledger(EnrichFromWikidata::KIND, wikidata, "wikidata_qid" => filled("Q1"), "isni" => filled("0000000121"),
            "birth_year" => filled(1901), "wikipedia" => {"value" => URL, "applied" => true, "reason" => "linked"})
          expect_rerun

          result = reject(wikidata)

          assert result.success?
          @author.reload
          assert_not @author.identifiers.exists?
          assert_nil @author.birth_year
          assert_not @author.external_links.exists?
          wikidata.reload
          assert wikidata.verdict_rejected?
          assert_equal [@user, "Link rejected."], [wikidata.reviewed_by, wikidata.review_note]
          assert_equal [wikidata], result.data[:decisions]
          assert_includes result.data[:reverted], "birth_year"
        end

        test "a run that applied nothing loses only the record's own id and its Wikipedia link" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          @author.update!(birth_year: 1901)
          @author.external_links.create!(url: URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
          already = ->(value) { {"value" => value, "applied" => false, "reason" => "already_set"} }
          ledger(EnrichFromWikidata::KIND, wikidata, "wikidata_qid" => already.call("Q1"), "isni" => already.call("0000000121"),
            "birth_year" => already.call(1901), "wikipedia" => already.call(URL))
          expect_rerun

          reject(wikidata)

          @author.reload
          assert_equal [["books_author_isni", "0000000121"]], @author.identifiers.pluck(:identifier_type, :value)
          assert_equal 1901, @author.birth_year
          assert_not @author.external_links.exists?
        end

        test "a value a person changed after the run stays" do
          viaf = decision(ResolveViaf.name, "5391")
          @author.update!(birth_year: 1950)
          ledger(EnrichFromViaf::KIND, viaf, "birth_year" => filled(1948))
          expect_rerun

          reject(viaf)

          assert_equal 1950, @author.reload.birth_year
        end

        test "every decision of the same finder that selected the record is rejected with it" do
          first = decision(ResolveWikidata.name, "Q1", created_at: 2.days.ago)
          second = decision(ResolveWikidata.name, "Q1")
          other = decision(ResolveWikidata.name, "Q2")
          expect_rerun

          result = reject(second)

          assert_equal [second, first], result.data[:decisions]
          assert first.reload.verdict_rejected?
          assert_nil other.reload.verdict
        end

        test "a rejected VIAF run takes the Wikidata decision its stamped id led to" do
          viaf = decision(ResolveViaf.name, "5391", created_at: 1.hour.ago)
          ledger(EnrichFromViaf::KIND, viaf, "wikidata_qid" => filled("Q9"), "viaf" => filled("5391"))
          earlier = decision(ResolveWikidata.name, "Q9", created_at: 2.hours.ago)
          follow_up = decision(ResolveWikidata.name, "Q9")
          @author.update!(death_year: 2013)
          ledger(EnrichFromWikidata::KIND, follow_up, "wikidata_qid" => {"value" => "Q9", "applied" => false, "reason" => "already_set"},
            "death_year" => filled(2013))
          hold(:books_author_wikidata_qid, "Q9")
          hold(:books_author_viaf, "5391")
          expect_rerun

          result = reject(viaf)

          assert_equal [viaf, follow_up], result.data[:decisions]
          assert follow_up.reload.verdict_rejected?
          assert_nil earlier.reload.verdict
          @author.reload
          assert_not @author.identifiers.exists?
          assert_nil @author.death_year
        end

        test "an AI run that used the record is reverted and its description deprecated; one that did not is left alone" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          @author.update!(gender: :female, death_year: 1980)
          @author.assign_description(source: :ai_generated, content: "Written from Q1.")
          @author.save!
          ai_run(sources: [], facts: {"death_year" => filled(1980)})
          ai_run(sources: [{"source" => "wikidata", "source_id" => "Q1"}],
            facts: {"gender" => filled("female"), "description" => filled("Written from Q1.")})
          expect_rerun

          result = reject(wikidata)

          @author.reload
          assert_equal [nil, 1980], [@author.gender, @author.death_year]
          assert_equal "deprecated", @author.descriptions.sole.rank
          assert_equal 1, result.data[:descriptions_deprecated]
        end

        test "an AI description written by a run that did not use the record stays" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          @author.assign_description(source: :ai_generated, content: "Written without Q1.")
          @author.save!
          ai_run(sources: [{"source" => "wikidata", "source_id" => "Q1"}], facts: {"description" => {"value" => "x", "applied" => false, "reason" => "already_set"}})
          ai_run(sources: [], facts: {"description" => filled("Written without Q1.")})
          expect_rerun

          reject(wikidata)

          assert_equal "normal", @author.descriptions.reload.sole.rank
        end

        test "a decision with no ledger row is still rejected and its record's id removed" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          hold(:books_author_wikidata_qid, "Q1")
          expect_rerun

          assert reject(wikidata).success?

          assert wikidata.reload.verdict_rejected?
          assert_not @author.identifiers.exists?
        end

        test "refuses an unmatched decision, a finder's decision, and one already rejected, changing and queuing nothing" do
          ::Books::Authors::WikidataJob.expects(:perform_async).never
          unmatched = decision(ResolveWikidata.name, nil, outcome: :unmatched)
          finder = decision("DataImporters::Books::Author::Finder", "Q1")
          rejected = decision(ResolveWikidata.name, "Q1")
          rejected.update!(verdict: :rejected)

          [unmatched, finder, rejected].each do |target|
            result = reject(target)
            assert_not result.success?
            assert_equal 1, result.errors.size
          end
          assert_nil unmatched.reload.verdict
          assert_nil finder.reload.verdict
        end

        test "a second reject of the same decision is refused and queues nothing more" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          expect_rerun(times: 1)

          assert reject(wikidata).success?
          assert_not reject(::MatchDecision.find(wikidata.id)).success?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/lib/services/books/authors/reject_external_link_test.rb`
Expected: FAIL — `uninitialized constant Services::Books::Authors::RejectExternalLink`.

- [ ] **Step 3: Write RejectExternalLink**

Create `web-app/app/lib/services/books/authors/reject_external_link.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The Reject link action on the audit page (spec §12): a person says a
      # Wikidata or VIAF record is not this author. Rejected together: this
      # decision, every other decision of its finder that selected the same
      # record for the author, and, for a VIAF record, the Wikidata decisions
      # that matched the Wikidata id its run stamped. For each, what its run
      # applied is reverted (RevertFacts) and the record's own id and
      # Wikipedia link are removed, whoever added them. The AI runs that used
      # a rejected record are reverted too, and the AI description is
      # deprecated when one of them wrote it. The decisions are marked
      # rejected and reviewed, and the Wikidata step runs again, forced. No
      # step considers or stamps a rejected record again (RejectedRecords).
      class RejectExternalLink
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        OWN_IDENTIFIER = {"wikidata" => "books_author_wikidata_qid", "viaf" => "books_author_viaf"}.freeze
        OWN_IDENTIFIER_FACT = {"wikidata" => "wikidata_qid", "viaf" => "viaf"}.freeze
        AI_FACTS = %w[birth_year death_year gender countries].freeze

        def self.call(decision:, user:)
          new(decision: decision, user: user).call
        end

        def initialize(decision:, user:)
          @decision = decision
          @user = user
          @author = decision.subject
          @reverted = []
          @deprecated = 0
        end

        def call
          refusal = refusal_reason
          return refused(refusal) if refusal

          rejected = ::ActiveRecord::Base.transaction do
            decision.lock!
            next nil if decision.verdict_rejected?

            targets.tap { |list| reject_all(list) }
          end
          return refused("This link was already rejected.") if rejected.nil?

          ::Books::Authors::WikidataJob.perform_async(author.id, true)
          Result.new(success?: true,
            data: {decisions: rejected.map(&:first), reverted: @reverted.uniq, descriptions_deprecated: @deprecated}, errors: [])
        end

        private

        attr_reader :decision, :user, :author

        def refusal_reason
          return "Only a Wikidata or VIAF link decision can be rejected." unless RejectedRecords::FINDERS.key?(decision.finder)
          return "Only a decision that matched a record can be rejected." unless decision.matched? && key_of(decision).present?
          return "This link was already rejected." if decision.verdict_rejected?
          return "The author is gone." unless author.is_a?(::Books::Author)

          nil
        end

        def refused(message) = Result.new(success?: false, data: {}, errors: [message])

        # [[decision, source, key], ...], this decision first.
        def targets
          source = RejectedRecords::FINDERS.fetch(decision.finder)
          list = same_record(decision.finder, key_of(decision)).map { |target| [target, source, key_of(target)] }
          return list unless source == "viaf"

          follow_ups = list.flat_map do |target, _source, _key|
            stamped_qids(target).flat_map { |qid| same_record(ResolveWikidata.name, qid, since: target.created_at) }
          end
          list + follow_ups.uniq.map { |target| [target, "wikidata", key_of(target)] }
        end

        def same_record(finder, key, since: nil)
          scope = ::MatchDecision.where(subject: author, finder: finder, outcome: :matched)
          scope = scope.where(created_at: since..) if since
          found = scope.order(:created_at, :id).reject(&:verdict_rejected?).select { |target| key_of(target) == key }
          found.include?(decision) ? [decision] + (found - [decision]) : found
        end

        def stamped_qids(viaf_decision)
          ::Enrichment.where(match_decision: viaf_decision).filter_map do |row|
            fact = row.facts["wikidata_qid"]
            fact["value"] if fact.is_a?(Hash) && fact["applied"] == true
          end.uniq
        end

        def key_of(target) = target.selected_candidate&.dig("external_key").presence

        def reject_all(list)
          list.each { |target, source, key| revert_run(target, source, key) }
          influenced = influenced_ai_runs(list.map { |_target, source, key| {"source" => source, "source_id" => key} })
          influenced.each { |row| @reverted.concat(RevertFacts.call(author: author, facts: row.facts.slice(*AI_FACTS)).data[:reverted]) }
          deprecate_ai_description(influenced)
          list.each { |target, _source, _key| mark_rejected(target) }
        end

        def revert_run(target, source, key)
          ::Enrichment.where(match_decision: target).find_each do |row|
            @reverted.concat(RevertFacts.call(author: author, facts: row.facts).data[:reverted])
            wikipedia = row.facts["wikipedia"]
            remove_links(wikipedia["value"]) if source == "wikidata" && wikipedia.is_a?(Hash) && wikipedia["reason"] == "already_set"
          end
          identifiers = author.identifiers.where(identifier_type: OWN_IDENTIFIER.fetch(source), value: key).to_a
          identifiers.each(&:destroy!)
          @reverted << OWN_IDENTIFIER_FACT.fetch(source) if identifiers.any?
          author.identifiers.reset
        end

        # The item's article, linked before this run: it names the rejected record too.
        def remove_links(url)
          links = author.external_links.where(url: url.to_s).to_a
          links.each(&:destroy!)
          @reverted << "wikipedia" if links.any?
          author.external_links.reset
        end

        # The AI step's runs whose input included a rejected record (its
        # "sources" fact, spec §9).
        def influenced_ai_runs(records)
          author.enrichments.for_kind(EnrichAuthor::KIND).order(:created_at, :id).select do |row|
            Array(row.facts.dig("sources", "value")).intersect?(records)
          end
        end

        # The applier writes a description only over a missing or deprecated
        # one, so the latest run that applied a description wrote the
        # current text.
        def deprecate_ai_description(influenced)
          writer = author.enrichments.for_kind(EnrichAuthor::KIND).order(created_at: :desc, id: :desc)
            .find { |row| row.facts.dig("description", "applied") == true }
          return unless writer && influenced.include?(writer)

          author.descriptions.reload.select { |row| row.source == "ai_generated" && !row.deprecated? }.each do |row|
            row.update!(rank: :deprecated)
            @deprecated += 1
          end
        end

        def mark_rejected(target)
          target.update!(verdict: :rejected)
          target.review!(by: user, note: target.review_note.presence || "Link rejected.")
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it**

Run: `bin/rails test test/lib/services/books/authors/reject_external_link_test.rb`
Expected: PASS. Then run the whole directory to catch interactions: `bin/rails test test/lib/services/books/authors`.

- [ ] **Step 5: Document it**

In `docs/features/books-author-enrichment.md`, add a section `## Rejecting a link` before `## The ledger`, in the file's voice, covering: who can (the merge action's delete gate); what is rejected together (decision 1 and 2 above); what is removed (decision 3, and RevertFacts' list: applied identifiers, years and gender still unchanged, added alternate names and countries, the Wikipedia link, legacy Wikipedia descriptions back to normal); the AI runs that used the record (decision 4) and the description; the re-run (`WikidataJob(author_id, true)`, refresh carried down to VIAF); and that a rejected record is never a candidate or stamped again (decisions 5 and 6), with a deprecated AI description no longer counting (decision 7). Add `§12` to the Spec line at the top (`§3-§10, §12, §13, §14`). In `## The ledger`, add one sentence that a filled `countries` fact now carries `country_ids`.

In the spec, append to §12 an italic amendment in the style of §8's: *(Amended in increment 5: ...)* listing decisions 1–8 in one short paragraph each sentence.

- [ ] **Step 6: Lint and commit**

Run: `bundle exec standardrb app/lib/services/books/authors/reject_external_link.rb test/lib/services/books/authors/reject_external_link_test.rb`

```bash
git add app/lib/services/books/authors/reject_external_link.rb test/lib/services/books/authors/reject_external_link_test.rb ../docs/features/books-author-enrichment.md ../docs/superpowers/specs/2026-09-27-books-author-importer-design.md
git commit -m "Reject link: RejectExternalLink reverts a wrong link and runs the author again"
```

---

### Task 6: The Reject link on the audit page

**Files:**
- Modify: `web-app/app/lib/data_importers/finder_registry.rb`
- Modify: `web-app/app/controllers/admin/match_decisions_base_controller.rb`
- Modify: `web-app/config/routes.rb` (the books block only: the `resources :match_decisions` inside `constraints DomainConstraint.new(Rails.application.config.domains[:books])`, near line 759)
- Modify: `web-app/app/views/admin/match_decisions_base/_actions.html.erb`, `web-app/app/views/admin/match_decisions_base/show.html.erb`
- Test: `web-app/test/lib/data_importers/finder_registry_test.rb`, `web-app/test/controllers/admin/books/match_decisions_controller_test.rb`
- Docs: `docs/features/import-finder.md`

**Interfaces:**
- Consumes: `RejectExternalLink.call(decision:, user:)` and its Result (Task 5); `MatchDecision#verdict_rejected?`, `#selected_candidate` (Task 1); `require_domain_delete!`, `current_user_can_delete?` (existing).
- Produces: `FinderRegistry::Entry#reject_service` (String or nil), `#rejectable?`, `#reject_service_class`; route `reject_admin_books_match_decision_path(decision)` (POST); controller helper `reject_decision_path`; testids `reject-form` (the button's form) and `decision-verdict` (the show page's verdict).

- [ ] **Step 1: Write the failing registry test**

Append inside the registry test class:

```ruby
  test "the two author link entries can reject; no finder can" do
    rejectable = DataImporters::FinderRegistry::ENTRIES.select(&:rejectable?)

    assert_equal ["Services::Books::Authors::ResolveViaf", "Services::Books::Authors::ResolveWikidata"], rejectable.map(&:finder).sort
    assert_equal [Services::Books::Authors::RejectExternalLink], rejectable.map(&:reject_service_class).uniq
  end
```

- [ ] **Step 2: Write the failing controller tests**

Append inside `MatchDecisionsControllerTest`, before its last two `end`s:

```ruby
      # ---- reject link --------------------------------------------------------

      def link_decision(finder: "Services::Books::Authors::ResolveWikidata", outcome: :matched)
        ::MatchDecision.create!(
          finder: finder, subject: books_authors(:tolstoy), record: nil, outcome: outcome, confidence: :medium,
          decided_by: :ai, needs_review: true, query: {"name" => "Leo Tolstoy"},
          candidates: [{"record_type" => nil, "record_id" => nil, "external_source" => "wikidata", "external_key" => "Q7243",
                        "sources" => ["name_search"], "scores" => {}, "evidence" => {"external_title" => "Leo Tolstoy"}}],
          selected_index: (outcome == :matched) ? 1 : nil, reason: "Works match."
        )
      end

      test "an admin rejects a link: the decision is rejected and the author's Wikidata step queued again" do
        decision = link_decision
        ::Books::Authors::WikidataJob.expects(:perform_async).with(books_authors(:tolstoy).id, true)
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_match_decision_path(decision)

        assert_redirected_to admin_books_match_decision_path(decision)
        assert decision.reload.verdict_rejected?
        assert_equal @admin, decision.reviewed_by
      end

      test "show offers Reject link only on a matched, unrejected link decision" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decision_path(link_decision)
        assert_select "[data-testid=reject-form]", count: 1

        rejected = link_decision.tap { |decision| decision.update!(verdict: :rejected) }
        get admin_books_match_decision_path(rejected)
        assert_select "[data-testid=reject-form]", count: 0

        get admin_books_match_decision_path(link_decision(outcome: :unmatched))
        assert_select "[data-testid=reject-form]", count: 0

        get admin_books_match_decision_path(@pending)
        assert_select "[data-testid=reject-form]", count: 0
      end

      test "a books editor, who can write but not delete, cannot reject and is not offered it" do
        editor = users(:regular_user)
        DomainRole.create!(user: editor, domain: :books, permission_level: :editor)
        decision = link_decision
        ::Books::Authors::WikidataJob.expects(:perform_async).never
        sign_in_as(editor, stub_auth: true)

        get admin_books_match_decision_path(decision)
        assert_select "[data-testid=reject-form]", count: 0

        post reject_admin_books_match_decision_path(decision)
        assert_redirected_to books_root_path
        assert_nil decision.reload.verdict
      end

      test "a viewer cannot reject" do
        decision = link_decision
        sign_in_as(@viewer, stub_auth: true)

        post reject_admin_books_match_decision_path(decision)

        assert_redirected_to books_root_path
        assert_nil decision.reload.verdict
      end

      test "rejecting a book finder's decision is refused and changes nothing" do
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_match_decision_path(@pending)

        assert_redirected_to admin_books_match_decision_path(@pending)
        assert_nil @pending.reload.verdict
        assert flash[:alert].present?
      end

      test "a refused reject (already rejected) redirects with an alert" do
        decision = link_decision.tap { |link| link.update!(verdict: :rejected) }
        ::Books::Authors::WikidataJob.expects(:perform_async).never
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_match_decision_path(decision)

        assert_redirected_to admin_books_match_decision_path(decision)
        assert flash[:alert].present?
      end
```

If `sign_in_as` for a user with only a books domain role behaves differently (the existing viewer test shows how a domain-role user is signed in), follow that test.

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb`
Expected: FAIL — `undefined method 'rejectable?'`, `undefined method 'reject_admin_books_match_decision_path'`.

- [ ] **Step 4: The registry**

In `finder_registry.rb`, add `:reject_service` to the `Entry` members (after `:kind`) and inside its block:

```ruby
      # Whether the audit page offers Reject link (spec §12): the service
      # that rejects one of this entry's decisions.
      def rejectable? = reject_service.present?

      def reject_service_class = reject_service.constantize
```

Give both external-link entries `reject_service: "Services::Books::Authors::RejectExternalLink"`. Add one sentence to the module comment: "An external-link entry may name a reject service, which puts Reject link on its decisions."

- [ ] **Step 5: The route**

In the books block's `resources :match_decisions ... member do`, add `post :reject` after `post :recheck`. Leave the music and games blocks alone.

- [ ] **Step 6: The controller**

In `match_decisions_base_controller.rb`:

```ruby
  before_action :set_decision, only: [:show, :review, :recheck, :reject]
  before_action :require_domain_write!, only: [:review, :recheck]
  # A reject removes what a link wrote, so it takes the merge action's gate.
  before_action :require_domain_delete!, only: [:reject]
```

Add `:reject_decision_path` to `helper_method`. Add the action after `recheck`:

```ruby
  # Reject link (spec §12), offered where the registry names a reject
  # service. Synchronous: it reverts database rows and queues the author's
  # Wikidata step again. Only the books routes define it.
  def reject
    entry = entry_for(@decision)
    unless entry&.rejectable?
      redirect_to decision_path(@decision), alert: "Reject is not available for #{entry&.label&.downcase || @decision.finder} decisions."
      return
    end

    result = entry.reject_service_class.call(decision: @decision, user: current_user)
    if result.success?
      redirect_to decision_path(@decision), notice: reject_notice(result.data)
    else
      redirect_to decision_path(@decision), alert: result.errors.to_sentence
    end
  end
```

and under `private`:

```ruby
  def reject_notice(data)
    parts = ["Link rejected."]
    others = data[:decisions].size - 1
    parts << "#{others} more decision(s) for the same record rejected with it." if others.positive?
    parts << "Removed: #{data[:reverted].join(", ")}." if data[:reverted].any?
    parts << "#{data[:descriptions_deprecated]} AI description(s) deprecated." if data[:descriptions_deprecated].positive?
    parts << "The author's Wikidata step runs again."
    parts.join(" ")
  end

  def reject_decision_path(decision)
    public_send(:"reject_#{route_prefix}match_decision_path", decision)
  end
```

- [ ] **Step 7: The views**

In `_actions.html.erb`, after the Re-check block:

```erb
    <% if entry&.rejectable? && current_user_can_delete? && decision.matched? && decision.selected_candidate && !decision.verdict_rejected? %>
      <%= button_to "Reject link", reject_decision_path(decision), method: :post, class: "btn btn-error btn-sm",
            form: {data: {testid: "reject-form", turbo_confirm: "Reject this link? What it wrote on the author is removed, any AI description written from it is deprecated, and the author's Wikidata step runs again."}} %>
    <% end %>
```

In `show.html.erb`'s `<dl>`, after the Review `<div>`:

```erb
        <div>
          <dt class="font-semibold">Verdict</dt>
          <dd data-testid="decision-verdict">
            <% if @decision.verdict %>
              <span class="badge badge-sm <%= @decision.verdict_rejected? ? "badge-error" : "badge-success" %>"><%= @decision.verdict %></span>
            <% else %>
              —
            <% end %>
          </dd>
        </div>
```

- [ ] **Step 8: Run the tests**

Run: `bin/rails test test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb test/controllers/admin`
Expected: PASS (the wider `test/controllers/admin` run catches the music and games subclasses of the base controller).

- [ ] **Step 9: Document it**

In `docs/features/import-finder.md`, extend the external-link paragraph with the VIAF entry ("and `Services::Books::Authors::ResolveViaf` ("VIAF link")") and one sentence that an entry naming a `reject_service` gets Reject link; in the "Actions for writers" sentence add: **Reject link**, for a matched Wikidata or VIAF link decision, to users who can delete in the domain (the merge action's gate), asking for confirmation; it undoes what the link wrote and runs the author's steps again (see `docs/features/books-author-enrichment.md`). Mention the show page's Verdict.

- [ ] **Step 10: Lint and commit**

Run: `bundle exec standardrb app/lib/data_importers/finder_registry.rb app/controllers/admin/match_decisions_base_controller.rb config/routes.rb test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb`

```bash
git add app/lib/data_importers/finder_registry.rb app/controllers/admin/match_decisions_base_controller.rb config/routes.rb app/views/admin/match_decisions_base test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb ../docs/features/import-finder.md
git commit -m "Reject link: the action on the books audit page, behind the delete gate"
```

---

### Task 7: The Playwright test

**Files:**
- Modify: `web-app/lib/tasks/e2e.rake`
- Create: `web-app/e2e/tests/books/admin/reject-link.spec.ts`
- Docs: `docs/features/e2e-testing.md`

**Interfaces:**
- Consumes: the Reject link button (label "Reject link"), the confirm dialog, the `decision-verdict` testid, the notice beginning "Link rejected." (Task 6).
- Produces: rake tasks `e2e:reject_link_seed` (prints `{"decision_id":…, "author_id":…}`), `e2e:reject_link_state` (prints `{"wikidata_qids":[…], "birth_year":…, "links":[…]}`), `e2e:reject_link_cleanup`.

- [ ] **Step 1: The rake tasks**

At the top of `e2e.rake`, beside `IMPORT_FINDER_MARKER`:

```ruby
# The placeholder author e2e:reject_link_seed owns, found by name. The QID is
# the Wikidata sandbox item, so a stray row names nobody real.
REJECT_LINK_AUTHOR = "E2E Reject Link Seed"
REJECT_LINK_QID = "Q4115189"
REJECT_LINK_URL = "https://en.wikipedia.org/wiki/Wikipedia:Sandbox"
```

Inside `namespace :e2e`, after `import_finder_cleanup`:

```ruby
  desc "Seed a placeholder author with one matched Wikidata link for e2e/tests/books/admin/reject-link.spec.ts"
  task reject_link_seed: :environment do
    # A placeholder (exclude_from_rankings), so the Wikidata run the reject
    # queues skips it without calling Wikidata, VIAF or a model. Idempotent:
    # a rerun resets the author's link rows and its decision.
    author = Books::Author.find_or_initialize_by(name: REJECT_LINK_AUTHOR)
    author.update!(exclude_from_rankings: true, birth_year: 1901)
    author.identifiers.each(&:destroy!)
    author.external_links.each(&:destroy!)
    author.enrichments.each(&:destroy!)
    MatchDecision.where(subject: author).each(&:destroy!)

    author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: REJECT_LINK_QID)
    author.external_links.create!(url: REJECT_LINK_URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
    decision = MatchDecision.create!(
      finder: "Services::Books::Authors::ResolveWikidata", subject: author, record: nil, outcome: :matched,
      confidence: :medium, decided_by: :ai, verify: false, needs_review: true, reason: "E2E reject link seed",
      query: {"name" => author.name},
      candidates: [{"record_type" => nil, "record_id" => nil, "external_source" => "wikidata", "external_key" => REJECT_LINK_QID,
                    "sources" => ["name_search"], "scores" => {}, "evidence" => {"external_title" => "Wikidata Sandbox"}}],
      selected_index: 1
    )
    author.enrichments.create!(
      kind: "books.author_wikidata", provider: "wikidata", outcome: :applied, reason: "matched #{REJECT_LINK_QID}",
      recognized: true, match_decision: decision, facts: {
        "wikidata_qid" => {"value" => REJECT_LINK_QID, "applied" => true, "reason" => "filled"},
        "birth_year" => {"value" => 1901, "applied" => true, "reason" => "filled"},
        "wikipedia" => {"value" => REJECT_LINK_URL, "applied" => true, "reason" => "linked"}
      }
    )

    puts({decision_id: decision.id, author_id: author.id}.to_json)
  end

  desc "Print the e2e:reject_link_seed author's link state as JSON"
  task reject_link_state: :environment do
    author = Books::Author.find_by!(name: REJECT_LINK_AUTHOR)
    puts({
      wikidata_qids: author.identifiers.where(identifier_type: :books_author_wikidata_qid).pluck(:value),
      birth_year: author.birth_year,
      links: author.external_links.pluck(:url)
    }.to_json)
  end

  desc "Remove the author e2e:reject_link_seed created, with its decisions"
  task reject_link_cleanup: :environment do
    author = Books::Author.find_by(name: REJECT_LINK_AUTHOR)
    decisions = author ? MatchDecision.where(subject: author).to_a : []
    decisions.each(&:destroy!)
    author&.destroy!
    puts "removed #{author ? 1 : 0} author and #{decisions.size} decision(s)"
  end
```

Run, from `web-app/`: `bin/rails e2e:reject_link_seed`, then `bin/rails e2e:reject_link_state`, then `bin/rails e2e:reject_link_cleanup`.
Expected: the seed prints the ids; the state prints `{"wikidata_qids":["Q4115189"],"birth_year":1901,"links":["https://en.wikipedia.org/wiki/Wikipedia:Sandbox"]}`; the cleanup removes 1 author and 1 decision. These write to the development database (one placeholder author); that is what the tasks are for.

- [ ] **Step 2: The spec**

Create `web-app/e2e/tests/books/admin/reject-link.spec.ts`:

```ts
import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Spec §12: seed a placeholder author holding one Wikidata link, reject the
// link from its decision page, and check what the reject removed. The author
// is a placeholder (exclude_from_rankings), so the Wikidata run the reject
// queues skips it without calling Wikidata, VIAF or a model. The rake tasks
// run from web-app, like import-finder-audit.spec.ts; the seed is idempotent.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });
const lastJson = (output: string) => {
  const lines = output.trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
};

let decisionId: number;

test.describe("Books admin — reject a Wikidata link", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    decisionId = lastJson(rails("e2e:reject_link_seed")).decision_id;
  });

  test.afterAll(() => {
    rails("e2e:reject_link_cleanup");
  });

  test("rejecting the link removes what it wrote and marks the decision rejected", async ({ page }) => {
    expect(lastJson(rails("e2e:reject_link_state"))).toEqual({
      wikidata_qids: ["Q4115189"],
      birth_year: 1901,
      links: ["https://en.wikipedia.org/wiki/Wikipedia:Sandbox"],
    });

    await page.goto(`/admin/match_decisions/${decisionId}`);
    const reject = page.getByRole("button", { name: "Reject link" });
    await expect(reject).toBeVisible();

    page.once("dialog", (dialog) => dialog.accept());
    await reject.click();

    await expect(page.getByRole("alert")).toContainText("Link rejected.");
    await expect(page.getByTestId("decision-verdict")).toContainText("rejected");
    await expect(page.getByRole("button", { name: "Reject link" })).toHaveCount(0);

    expect(lastJson(rails("e2e:reject_link_state"))).toEqual({ wikidata_qids: [], birth_year: null, links: [] });
  });
});
```

- [ ] **Step 3: Run it**

Build and serve this worktree first: `yarn build:all`, then `bin/rails server` (in the background). Before running, confirm port 3000 is this worktree's:

```bash
ss -ltnpH 'sport = :3000'
```

then `readlink /proc/<pid>/cwd` for the pid it prints; it must be this worktree's `web-app`. If another checkout holds the port, stop and report it; don't kill it or use another port.

Run: `npx playwright test --config=e2e/playwright.config.ts tests/books/admin/reject-link.spec.ts`
Expected: 1 passed. Stop the server afterwards.

- [ ] **Step 4: Document it**

In `docs/features/e2e-testing.md`, beside the import-finder seed paragraph, add that `reject-link.spec.ts` seeds a placeholder author through `e2e:reject_link_seed`, reads it back with `e2e:reject_link_state`, and removes it with `e2e:reject_link_cleanup`; the author is a placeholder so the Wikidata run the reject queues makes no external or model call.

- [ ] **Step 5: Lint and commit**

Run: `bundle exec standardrb lib/tasks/e2e.rake`

```bash
git add lib/tasks/e2e.rake e2e/tests/books/admin/reject-link.spec.ts ../docs/features/e2e-testing.md
git commit -m "Reject link: Playwright test with its own placeholder author"
```

---

### Finish

- [ ] `bin/rails test` — the whole suite, green, with no new warning lines.
- [ ] `bundle exec standardrb` — clean.
- [ ] `CI=1 bin/rails zeitwerk:check` — clean (no new directory, but three new files under `app/lib`).
- [ ] `git diff main --stat -- db/schema.rb` shows only the version bump and the `verdict` column.
- [ ] Update `memory/books-author-importer.md`: increment 5 status, and the carry-forwards it closes (VIAF reject cascade, country ids in the ledger, deprecated AI description counting as present).
