# Goodreads Import Increment 5: Legacy Replay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replay the legacy app's 803 Goodreads imports against the new resolver. The replay loads each upload and resolves every edition in `verify: true`. It compares each row's answer with the book legacy chose and looks for duplicate books and authors and for junk. Every finding goes into a ledger, `Books::RepairVerdict`, keyed by preserved ids. Rule-certain verdicts are approved on their own; the rest go to an admin queue. A report measures the resolver. With `auto_apply` off (the default), nothing is changed.

**Architecture:** Services live under `Services::Books::GoodreadsReplay`.
- **Steps.** Each step is a service and a thin rake task: load, fix slugs, resolve, find duplicates, find junk, apply, report. A full pass runs them in that order.
- **Recording.** Findings go only through `RecordVerdict`. It keeps an admin's review and suppresses a finding the admin rejected.
- **Applying.** Only `ApplyVerdicts` changes catalog data. It works through approved verdicts kind by kind, in the spec's order, and refuses to run while `config.x.goodreads_replay.auto_apply` is false.
- **Passes.** Pass one runs in Sidekiq on `low`. Pass two re-runs the disagreements and unmatched editions with Open Library `/resolve` on `serial`.

**Tech Stack:** Rails 8.1, Minitest 6 + fixtures + Mocha + WebMock, Sidekiq (inline in tests), ActiveStorage `private_imports` service (Disk in test), OpenAI `fast` role through `Services::Ai::Tasks::BaseTask`, ViewComponent-free ERB admin views on DaisyUI 5.

**Spec:** `docs/superpowers/specs/2026-10-03-goodreads-import-design.md` — §12.1–12.7 and §12.9 (increment 5 in §15). §2, §3 (`books_repair_verdicts`), §9 (provisional) and §13 bind too.

## Measurement (2026-10-05, read-only, development database refreshed from production)

Measured before planning: 14 random completed legacy imports, with CSVs downloaded from the legacy R2 bucket into the scratchpad, and 392 rows sampled from their 4,850. Script: the session scratchpad's `measure_replay.rb`. It runs the books finder's gather plus `Decider` in `verify: true`, with Open Library disabled and no AI.

| What | Count |
|---|---:|
| Rows where the verify-mode rules agree with legacy's book | 178 (45%) |
| Rows the rules leave to the AI | 198 (50%) |
| Rows where the rules match a book and legacy has no choice | 16 |
| **Rows where the rules match a different book than legacy** | **0** |
| Rows with no legacy choice (no book holding the id is on the user's lists) | 45 (11%) |
| Of the AI rows: legacy's book agrees on title and author, but 2–7 exact duplicate books exist | 46 |
| Of the AI rows: legacy's book contradicts the row on both title and author | 13 |

Other numbers:
- **Legacy imports:** 757 complete, 23 failed, 23 stuck. Every import has exactly one blob, all on `service_name: cloudflare`: 795 `text/csv` and 8 other types. All 659 users exist in the new app, and 64 of them have more than one completed import.
- **Slug ids:** 543 slug-form Goodreads ids. On 202 of them, the bare id is already on the same book. On 61, it is on another book, which makes an identifier collision.
- **Authorless books:** 37 in all: 12 on curated lists, 22 on user lists.
- **Author groups:** with a loose key (lowercase, everything but letters and digits removed), there are 3,188 groups (7,784 authors). Sizes: 2,751 pairs, 248 triples, the largest 74 ("James Tynion IV"). `lower(name)` alone gives 3,116 groups.
- **Open Library keys:** 31,602 of 160,291 books hold an Open Library work key.

What the numbers decide:
1. **No disagreement is ever decided by a rule.** Legacy's book always holds the row's Goodreads id. Under `verify: true` that identifier hit blocks rule 4 (exact title and author) for every other candidate. So the spec's "disagrees; decided by rule → auto relink" row can never fire, and every relink is AI-decided and queued. The admin queue therefore gets a bulk approve.
2. **About half of all editions need a matching AI call.** At ~188k editions, that is roughly 94k `fast` calls per full replay pass, before pass two. The spec puts no cap on matching AI; the report counts the calls.
3. **Initials miss the author check.** "J.D. Salinger" fails `creators_agree?` against "J. D. Salinger". This is a finder normalization gap and is out of scope here (a follow-up). The author grouping key below removes punctuation and spaces, so those two do group together.

## Rulings made while planning

- **R1.** The legacy bucket credentials are the existing `LEGACY_R2_*` (`Services::BooksMigration::LegacyR2`), not the spec's `LEGACY_STORAGE_*`, because they already exist and the image migration uses them. Production needs all four in SOPS.
- **R2.** The replay never fetches Goodreads pages; it attaches facts from cached pages only. This resolves the carry "don't flood the shared fetch line ahead of member imports". Cost: unmatched findings carry fewer page facts.
- **R3.** An authorless book on a curated list gets a **proposed** `mark_provisional`, never an auto one. Other authorless books are auto. This resolves the curated-page carry: `Books::ListsController#show` stays unfiltered, and nothing auto-hides a book that a curated list shows.
- **R4.** Following measurement 1, relinks are AI-decided and proposed, exactly as the spec's AI row says. The admin index gets "Approve selected".
- **R5.** Author duplicates use one `fast` AI call per name group, which clusters the group into people. This replaces running the author finder per author. The finder's rule 4 would match exact names with no AI, and the spec forbids that as merge evidence. A group also costs one call instead of one per member.
  - Group key: `regexp_replace(lower(name), '[^[:alnum:]]+', '', 'g')`, so "J.D. Vance" groups with "J. D. Vance".
  - Cost if wrong: cross-name duplicates (pen names, transliterations) are not found here and stay with the existing duplicate tooling.
- **R6.** Auto `merge_authors` additionally requires `high` AI confidence. Medium and low are proposed.
- **R7.** For authors, a birth or death year conflicts when both are present and differ. This is stricter than the finder's ±2 years, because a wrong merge is the costlier mistake.
- **R8.** `decided_by` records who made the finding (`rule` or `ai`). An admin's review goes in `decided_by_user_id` plus a new `reviewed_at`. `admin` stays in the enum for a verdict an admin creates.
- **R9.** Replay match decisions come out of the match-decision review queue (`needs_review: false`). The ledger is the replay's review surface; otherwise ~94k AI decisions would flood the audit queue.
- **R10.** A relink carries its identifier strip-and-stamp (spec §12.4) in its own payload, so it is one verdict rather than two.
- **R11.** Admin approval never applies; `books:goodreads_replay:apply` applies every approved verdict, in spec order. The gate covers the slug fix-ups too: "a dry run applies nothing".
- **R12.** An unmatched row produces a proposed `strip_identifier` only when legacy's book contradicts the row on both title and author. Other unmatched rows are counted, not queued. A `strip_identifier` needs no target, and that is the case where legacy's link is almost certainly wrong.
- **R13.** The 46 failed and stuck legacy imports are loaded as `failed`, with the legacy reason, their file and their rows, and their rows are compared too. Increment 7 finishes them.
- **R14.** When legacy's book and the resolver's book are already a duplicate pair, the row's finding is `duplicate` and gets no relink: the merge settles it.
- **R15.** Rejecting an applied `mark_provisional` reverts it, because spec §12.6 calls the action reversible. An applied merge or relink cannot be rejected.
- **R16.** Pass two re-runs the finder with both Open Library sources. Verdicts are recorded only from the final pass for an edition, so pass one never writes a verdict that pass two would overwrite.
- **R17.** `DataImporters::Books::Book::Finder` gets an `open_library:` mode: `:resolve` (default, unchanged), `:identifiers` (pass one) or `:all` (pass two). The Open Library identifier lookup is a new source.
- **R18.** The report rake writes markdown to a given path, or prints it. A separate `sample` rake prints the hand-check samples (spec §12.9).
- **R19.** `books_repair_verdicts` gets three columns beyond the spec's list: `confidence`, because the report breaks findings down by it (§12.9); `reviewed_at` (R8); and `error`, the last apply failure.

## Global Constraints

- **Location:** run Rails commands from `web-app/`. Docs live at the repo root `docs/`.
- **Generators:** create models with `bin/rails generate model`, migrations with `bin/rails generate migration`, and jobs with `bin/rails generate sidekiq:job`. Never hand-create them.
- **Code layout:** services go in `app/lib/services/books/goodreads_replay/` and use the Result pattern `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. Jobs go in `app/sidekiq/`.
- **Enums:** Rails 8 syntax, `enum :kind, {...}`.
- **No foreign keys on `books_repair_verdicts`:** spec §3 says "No foreign keys to books, authors or users, so it survives the launch truncation". `subject_key` is built only from preserved ids.
- **`config.x.goodreads_replay.auto_apply` defaults to `false`** (spec §12.9).
- **The compare-and-repair pass "never creates books or list items"** (spec §12.3).
- **Minitest 6:** never `assert_equal nil, x`. Mocha for stubs; WebMock blocks the network. Sidekiq is `:inline` in tests.
- **Fixtures wipe tables:** never load them against development.
- **Legacy models:** never queried in tests. Use `.allocate` for model assertions and inject the legacy source.
- **New `app/lib` directories:** run `CI=1 bin/rails zeitwerk:check`.
- **Lint and tests:** lint is `bundle exec standardrb`, never `bin/rubocop` and never brakeman. A clean `bin/rails test` prints no new warnings.
- **Admin copy:** short and plain. Display strings live on models.

## Review Focus

1. **Re-running any step leaves the same state.** This covers load, fix slugs, resolve, duplicates, junk and apply. Applying the same approved verdicts twice changes nothing the second time (spec §12.7). Tests: `LoadImports` twice, `ApplyVerdicts` twice, and `RecordVerdict` re-recording.
2. **A verdict whose records vanished before apply** must be a no-op with a reason, never a crash. Examples: a source already merged, a deleted user, a relink whose items already moved. Tests in each `Apply::*`.
3. **Merge chains in one apply run.** Author A→B with B→C, and a book merge whose target was merged earlier in the same run. Each later verdict finds its record gone or moved and does nothing harmful. Test in `ApplyVerdicts`.
4. **One user, two imports, same edition.** This happens for 64 users. It must give one relink verdict and update both imports' rows. Test in `CompareEdition`.
5. **Bad legacy inputs.** A user missing from the new app, a non-CSV upload (never downloaded), a CSV that does not parse, and a Windows-1252 file. Each must be counted and never stop the loader. Tests in `LoadImports`.

---
### Task 1: Verdict ledger and the replay config

**Files:**
- Create (generator): `web-app/db/migrate/<ts>_create_books_repair_verdicts.rb`, `web-app/app/models/books/repair_verdict.rb`, `web-app/test/models/books/repair_verdict_test.rb`, `web-app/test/fixtures/books/repair_verdicts.yml`
- Create: `web-app/config/initializers/goodreads_replay.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/record_verdict.rb`
- Test: `web-app/test/lib/services/books/goodreads_replay/record_verdict_test.rb`

**Interfaces:**
- Produces: `Books::RepairVerdict` with these enums:
  - `kind` {relink, merge_books, merge_authors, strip_identifier, mark_provisional};
  - `decided_by` {rule, ai, admin} with prefix `decided_by_`;
  - `status` {proposed, approved, rejected};
  - `confidence` {certain, high, medium, low} with prefix `confidence_`.
- The model also has: `#reviewed?`, `#summary` (display string), and scopes `unapplied` and `newest_first`.
- Produces: `Services::Books::GoodreadsReplay::RecordVerdict.call(kind:, subject_key:, payload:, decided_by:, confidence: nil, reason: nil, ai_chat_id: nil, auto: false)` returns `Result(data: {verdict:, outcome: :created | :updated | :kept | :suppressed})`.
- Produces: `Rails.configuration.x.goodreads_replay.auto_apply` (false) and `.max_author_group` (80).

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model Books::RepairVerdict kind:integer subject_key:string payload:jsonb \
  decided_by:integer confidence:integer status:integer reason:text ai_chat_id:bigint \
  decided_by_user_id:bigint reviewed_at:datetime applied_at:datetime error:text
```

Expected: it creates the migration, `app/models/books/repair_verdict.rb`, its test and its fixture file. Replace the generated fixture file's contents with a comment line only: `# Tests build verdicts with RecordVerdict or create!; none are shared.`

- [ ] **Step 2: Edit the migration**

Replace the body of the generated migration's `change` with:

```ruby
  def change
    # No foreign keys, on purpose (Goodreads import spec §3): books, authors and
    # users are truncated and re-migrated before launch, and these verdicts must
    # survive that, keyed by preserved ids.
    create_table :books_repair_verdicts do |t|
      t.integer :kind, null: false
      t.string :subject_key, null: false
      t.jsonb :payload, null: false, default: {}
      t.integer :decided_by, null: false
      t.integer :confidence
      t.integer :status, null: false, default: 0
      t.text :reason
      t.bigint :ai_chat_id
      t.bigint :decided_by_user_id
      t.datetime :reviewed_at
      t.datetime :applied_at
      t.text :error
      t.timestamps
    end
    add_index :books_repair_verdicts, [:kind, :subject_key], unique: true
    add_index :books_repair_verdicts, [:status, :kind]
  end
```

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:test:prepare`
Expected: `books_repair_verdicts` appears in `db/schema.rb`, with both indexes and no `add_foreign_key` lines for it.

- [ ] **Step 3: Write the failing model and config tests**

`web-app/test/models/books/repair_verdict_test.rb`:

```ruby
require "test_helper"

module Books
  class RepairVerdictTest < ActiveSupport::TestCase
    def verdict(**attributes)
      RepairVerdict.create!({kind: :relink, subject_key: "user:1:book:2:goodreads:3", decided_by: :ai,
        payload: {"user_id" => 1, "from_book_id" => 2, "to_book_id" => 4, "goodreads_book_id" => 3}}.merge(attributes))
    end

    test "subject keys are unique per kind, not across kinds" do
      verdict
      assert_raises(ActiveRecord::RecordInvalid) { verdict }
      assert_nothing_raised { verdict(kind: :strip_identifier) }
    end

    test "a new verdict is proposed and unreviewed" do
      record = verdict

      assert_predicate record, :proposed?
      refute_predicate record, :reviewed?
    end

    test "summary describes each kind in plain words" do
      assert_equal "Move user 1's list items and review from book #2 to book #4 (Goodreads 3)", verdict.summary
      assert_equal "Merge book #8 into book #9",
        verdict(kind: :merge_books, subject_key: "books:8:9", payload: {"source_id" => 8, "target_id" => 9}).summary
      assert_equal "Merge author #5 into author #6",
        verdict(kind: :merge_authors, subject_key: "authors:5:6", payload: {"source_id" => 5, "target_id" => 6}).summary
      assert_equal "On book #7: remove books_work_goodreads_id 12-slug; add books_work_goodreads_id 12",
        verdict(kind: :strip_identifier, subject_key: "book:7:books_work_goodreads_id:12-slug",
          payload: {"book_id" => 7, "remove" => [["books_work_goodreads_id", "12-slug"]], "add" => [["books_work_goodreads_id", "12"]]}).summary
      assert_equal "Mark book #7 provisional (authorless)",
        verdict(kind: :mark_provisional, subject_key: "book:7", payload: {"book_id" => 7, "reason" => "authorless"}).summary
    end

    test "unapplied excludes applied verdicts" do
      applied = verdict(applied_at: Time.current)
      pending = verdict(kind: :merge_books, subject_key: "books:1:2")

      assert_equal [pending.id], RepairVerdict.unapplied.where(id: [applied.id, pending.id]).pluck(:id)
    end

    test "the replay never applies by default" do
      refute Rails.configuration.x.goodreads_replay.auto_apply
      assert_equal 80, Rails.configuration.x.goodreads_replay.max_author_group
    end
  end
end
```

Run: `bin/rails test test/models/books/repair_verdict_test.rb`
Expected: FAIL. The enums, `summary`, `reviewed?` and the config are undefined.

- [ ] **Step 4: Write the model and the config**

`web-app/app/models/books/repair_verdict.rb` (keep the annotate block the generator wrote, if any, above this):

```ruby
module Books
  # One finding of the legacy Goodreads replay and what was decided about it
  # (Goodreads import spec §12.7). Keyed only by preserved ids, with no
  # foreign keys, so it outlives the books truncation before launch: never
  # truncate this table. decided_by says who made the finding; an admin's
  # review is decided_by_user_id and reviewed_at.
  class RepairVerdict < ApplicationRecord
    enum :kind, {relink: 0, merge_books: 1, merge_authors: 2, strip_identifier: 3, mark_provisional: 4}
    enum :decided_by, {rule: 0, ai: 1, admin: 2}, prefix: true
    enum :status, {proposed: 0, approved: 1, rejected: 2}
    enum :confidence, {certain: 0, high: 1, medium: 2, low: 3}, prefix: true

    validates :subject_key, presence: true, uniqueness: {scope: :kind}

    scope :unapplied, -> { where(applied_at: nil) }
    scope :newest_first, -> { order(updated_at: :desc, id: :desc) }

    def reviewed?
      reviewed_at.present?
    end

    def summary
      case kind
      when "relink"
        "Move user #{payload["user_id"]}'s list items and review from book ##{payload["from_book_id"]} " \
          "to book ##{payload["to_book_id"]} (Goodreads #{payload["goodreads_book_id"]})"
      when "merge_books" then "Merge book ##{payload["source_id"]} into book ##{payload["target_id"]}"
      when "merge_authors" then "Merge author ##{payload["source_id"]} into author ##{payload["target_id"]}"
      when "strip_identifier"
        changes = [["remove", payload["remove"]], ["add", payload["add"]]].filter_map do |verb, pairs|
          "#{verb} #{Array(pairs).map { |type, value| "#{type} #{value}" }.join(", ")}" if Array(pairs).any?
        end
        "On book ##{payload["book_id"]}: #{changes.join("; ")}"
      when "mark_provisional" then "Mark book ##{payload["book_id"]} provisional (#{payload["reason"]})"
      end
    end
  end
end
```

`web-app/config/initializers/goodreads_replay.rb`:

```ruby
# frozen_string_literal: true

# The legacy Goodreads replay (Goodreads import spec §12). Rails config, not
# an admin UI.
Rails.application.config.x.goodreads_replay = ActiveSupport::OrderedOptions.new.merge(
  # Spec §12.9: the first full replay writes verdicts and applies nothing.
  # Switch on only after 50 auto verdicts per kind are hand-checked
  # (books:goodreads_replay:sample).
  auto_apply: false,
  # Name groups larger than this are not sent to the author check; the
  # largest measured group was 74 (2026-10-05).
  max_author_group: 80
)
```

Run: `bin/rails test test/models/books/repair_verdict_test.rb`
Expected: PASS, 5 runs.

- [ ] **Step 5: Write the failing RecordVerdict tests**

`web-app/test/lib/services/books/goodreads_replay/record_verdict_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class RecordVerdictTest < ActiveSupport::TestCase
        def record(**overrides)
          RecordVerdict.call(**{kind: :merge_books, subject_key: "books:1:2", payload: {"source_id" => 2, "target_id" => 1},
            decided_by: :rule, confidence: :certain, reason: "same title, authors and ISBN"}.merge(overrides))
        end

        test "a new finding is proposed, or approved when the rule is certain enough to apply on its own" do
          proposed = record(auto: false)
          assert_equal :created, proposed.data[:outcome]
          assert_predicate proposed.data[:verdict], :proposed?

          auto = record(subject_key: "books:3:4", auto: true)
          assert_predicate auto.data[:verdict], :approved?
          assert_predicate auto.data[:verdict], :decided_by_rule?
        end

        test "an unreviewed verdict found again takes the new evidence" do
          record(auto: true)
          result = record(payload: {"source_id" => 1, "target_id" => 2}, reason: "newer", auto: false)

          verdict = result.data[:verdict]
          assert_equal :updated, result.data[:outcome]
          assert_equal({"source_id" => 1, "target_id" => 2}, verdict.payload)
          assert_equal "newer", verdict.reason
          assert_predicate verdict, :proposed?
          assert_equal 1, ::Books::RepairVerdict.count
        end

        test "a rejected verdict suppresses its finding" do
          verdict = record.data[:verdict]
          verdict.update!(status: :rejected, decided_by_user_id: users(:admin_user).id, reviewed_at: Time.current)

          result = record(payload: {"source_id" => 9, "target_id" => 1}, auto: true)

          assert_equal :suppressed, result.data[:outcome]
          assert_predicate verdict.reload, :rejected?
          assert_equal({"source_id" => 2, "target_id" => 1}, verdict.payload)
        end

        test "an admin's approval is kept as the admin left it" do
          verdict = record.data[:verdict]
          verdict.update!(status: :approved, decided_by_user_id: users(:admin_user).id, reviewed_at: Time.current)

          result = record(payload: {"source_id" => 9, "target_id" => 1}, auto: false)

          assert_equal :kept, result.data[:outcome]
          assert_predicate verdict.reload, :approved?
          assert_equal({"source_id" => 2, "target_id" => 1}, verdict.payload)
        end

        test "the same key under another kind is another verdict" do
          record
          record(kind: :merge_authors)

          assert_equal 2, ::Books::RepairVerdict.where(subject_key: "books:1:2").count
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/record_verdict_test.rb`
Expected: FAIL with `uninitialized constant Services::Books::GoodreadsReplay::RecordVerdict`.

- [ ] **Step 6: Write RecordVerdict**

`web-app/app/lib/services/books/goodreads_replay/record_verdict.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The only way a replay finding reaches the ledger (Goodreads import spec
      # §12.7). Every replay pass re-derives its findings, so most findings are
      # recorded again on each pass:
      # - a verdict an admin rejected suppresses its finding;
      # - one an admin approved is kept exactly as approved;
      # - an unreviewed one takes the newest evidence.
      # auto: a rule-certain (or, for authors, AI-checked) finding is approved
      # on its own; the rest are proposed for the admin queue.
      class RecordVerdict
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(kind:, subject_key:, payload:, decided_by:, confidence: nil, reason: nil, ai_chat_id: nil, auto: false)
          new(kind: kind, subject_key: subject_key, payload: payload, decided_by: decided_by, confidence: confidence,
            reason: reason, ai_chat_id: ai_chat_id, auto: auto).call
        end

        def initialize(kind:, subject_key:, payload:, decided_by:, confidence:, reason:, ai_chat_id:, auto:)
          @kind = kind
          @subject_key = subject_key
          @attributes = {payload: payload.deep_stringify_keys, decided_by: decided_by, confidence: confidence,
                         reason: reason, ai_chat_id: ai_chat_id, status: auto ? :approved : :proposed}
        end

        def call
          verdict = ::Books::RepairVerdict.find_or_initialize_by(kind: @kind, subject_key: @subject_key)
          return done(verdict, :suppressed) if verdict.rejected?
          return done(verdict, :kept) if verdict.reviewed?

          created = verdict.new_record?
          verdict.update!(@attributes)
          done(verdict, created ? :created : :updated)
        rescue ActiveRecord::RecordNotUnique
          # Two jobs recorded the same finding at once; the second reads the first's row.
          retry
        end

        private

        def done(verdict, outcome)
          Result.new(success?: true, data: {verdict: verdict, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/record_verdict_test.rb test/models/books/repair_verdict_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS, 10 runs; `All is good!`

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/books/repair_verdict.rb test/models/books/repair_verdict_test.rb \
  test/fixtures/books/repair_verdicts.yml config/initializers/goodreads_replay.rb \
  app/lib/services/books/goodreads_replay/record_verdict.rb test/lib/services/books/goodreads_replay/record_verdict_test.rb
git commit -m "Goodreads replay: verdict ledger and RecordVerdict"
```

---
### Task 2: Loader (§12.1)

**Files:**
- Create: `web-app/app/models/legacy_books/goodreads_import.rb` (hand-written, like every `LegacyBooks::` model. They are read-only views of a database the app never migrates, so `generate model` would add a migration that must not exist.)
- Modify: `web-app/app/models/books/goodreads_import.rb` (add `has_one_attached :file`)
- Create: `web-app/app/lib/services/books/goodreads_replay/load_imports.rb`
- Create: `web-app/lib/tasks/books/goodreads_replay.rake`
- Test: `web-app/test/models/legacy_books/goodreads_import_test.rb`, `web-app/test/models/books/goodreads_import_test.rb` (add one test), `web-app/test/lib/services/books/goodreads_replay/load_imports_test.rb`, `web-app/test/lib/tasks/books_goodreads_replay_rake_test.rb`

**Interfaces:**
- Consumes: `Books::Goodreads::ExportFile.parse(bytes)`, `Services::Books::GoodreadsImports::ParseRows.call(import:, rows:)`, `Services::BooksMigration::LegacyR2.client` and `.bucket`.
- Produces: `LegacyBooks::GoodreadsImport` (`STATUSES`, `file_attachment`).
- Produces: `Books::GoodreadsImport#file` on `private_imports`.
- Produces: `Services::Books::GoodreadsReplay::LoadImports.call(legacy_imports: LoadImports::LegacyImports.new, download: nil)` returns `Result(data: {tally: Hash})`. Tally keys: `:loaded`, `:not_csv`, `:unreadable`, `:missing_user`, `:missing_file`.
- Produces: `LoadImports::LegacyImport = Data.define(:id, :user_id, :status, :error, :blob_key, :content_type, :filename)`, where `status` is a string.
- Produces: the rake file `lib/tasks/books/goodreads_replay.rake` with `books:goodreads_replay:load`.

- [ ] **Step 1: Write the failing model tests**

`web-app/test/models/legacy_books/goodreads_import_test.rb`:

```ruby
require "test_helper"

module LegacyBooks
  class GoodreadsImportTest < ActiveSupport::TestCase
    # .allocate, not .new: .new introspects a table the test database lacks
    # (see goodreads_book_test.rb).
    test "reads the legacy goodreads_imports table, read-only" do
      assert_equal "goodreads_imports", GoodreadsImport.table_name
      assert_predicate GoodreadsImport.allocate, :readonly?
    end

    test "maps the legacy app's status integers" do
      assert_equal({0 => "not_started", 1 => "pending", 2 => "complete", 3 => "failed"}, GoodreadsImport::STATUSES)
    end

    test "finds its upload through the legacy attachment row" do
      reflection = GoodreadsImport.reflect_on_association(:file_attachment)

      assert_equal "LegacyBooks::ActiveStorageAttachment", reflection.class_name
      assert_equal "record_id", reflection.foreign_key
    end
  end
end
```

Add to `web-app/test/models/books/goodreads_import_test.rb`, inside the class:

```ruby
    test "keeps the upload on the private imports service" do
      assert_equal :private_imports, Books::GoodreadsImport.reflect_on_attachment(:file).options[:service_name]
    end
```

Run: `bin/rails test test/models/legacy_books/goodreads_import_test.rb test/models/books/goodreads_import_test.rb`
Expected: FAIL. `LegacyBooks::GoodreadsImport` is undefined and there is no `file` attachment.

- [ ] **Step 2: Write the models**

`web-app/app/models/legacy_books/goodreads_import.rb`:

```ruby
module LegacyBooks
  # A legacy member's Goodreads upload (the legacy app's GoodreadsImport, with
  # has_one_attached :file). Read by the replay loader (Goodreads import spec
  # §12.1). Status is the legacy enum's integer; STATUSES names it without an
  # enum, which would introspect a table the test database does not have.
  class GoodreadsImport < Record
    self.table_name = "goodreads_imports"

    STATUSES = {0 => "not_started", 1 => "pending", 2 => "complete", 3 => "failed"}.freeze

    has_one :file_attachment, -> { where(record_type: "GoodreadsImport", name: "file") },
      class_name: "LegacyBooks::ActiveStorageAttachment", foreign_key: :record_id
  end
end
```

In `web-app/app/models/books/goodreads_import.rb`, after the `has_many :pending_editions …` declaration, add:

```ruby
    # The upload as received, Private Notes included, so it lives on the
    # private service only (spec §3). Rows store the parsed fields without it.
    has_one_attached :file, service: :private_imports
```

Run: `bin/rails test test/models/legacy_books/goodreads_import_test.rb test/models/books/goodreads_import_test.rb`
Expected: PASS.

- [ ] **Step 3: Write the failing loader tests**

`web-app/test/lib/services/books/goodreads_replay/load_imports_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class LoadImportsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = users(:regular_user)
          @csv = goodreads_csv(
            {"Book Id" => "1001", "Title" => "The Quiet Year", "Author" => "Anna Brenner", "Exclusive Shelf" => "read"},
            {"Book Id" => "1002", "Title" => "Loud Days (Noise, #2)", "Author" => "Bo Lind", "Exclusive Shelf" => "to-read"}
          )
          @downloads = []
        end

        def legacy(**attributes)
          LoadImports::LegacyImport.new(**{id: 501, user_id: @user.id, status: "complete", error: nil,
            blob_key: "legacy-key-501", content_type: "text/csv", filename: "goodreads_library_export.csv"}.merge(attributes))
        end

        def load(*imports, bytes: @csv)
          LoadImports.call(legacy_imports: imports, download: ->(key) { @downloads << key; bytes })
        end

        test "a completed legacy import becomes a complete replay import owned by the same user, with its file and rows" do
          result = load(legacy)

          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({loaded: 1}, result.data[:tally])
          assert_predicate import, :legacy_replay?
          assert_predicate import, :complete?
          assert_equal @user, import.user
          assert_equal @csv, import.file.download
          assert_equal [1, 2], import.rows.order(:row_number).pluck(:row_number)
          assert_equal 2, import.editions_count
        end

        test "loading twice downloads once and writes nothing new" do
          load(legacy)
          load(legacy)

          assert_equal ["legacy-key-501"], @downloads
          assert_equal 1, ::Books::GoodreadsImport.where(legacy_import_id: 501).count
          assert_equal 2, ::Books::GoodreadsImport.find_by!(legacy_import_id: 501).rows.count
        end

        test "after the rows are gone (a re-migration truncated them) the kept file is parsed again" do
          load(legacy)
          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          import.rows.delete_all

          load(legacy)

          assert_equal ["legacy-key-501"], @downloads
          assert_equal 2, import.rows.count
        end

        test "a failed or stuck legacy import is loaded failed, with the legacy reason, its file and its rows" do
          load(legacy(status: "failed", error: "CSV::MalformedCSVError: Illegal quoting"), legacy(id: 502, status: "pending"))

          failed = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          stuck = ::Books::GoodreadsImport.find_by!(legacy_import_id: 502)
          assert_predicate failed, :failed?
          assert_equal "legacy import failed: CSV::MalformedCSVError: Illegal quoting", failed.error
          assert_equal "legacy import never finished (pending)", stuck.error
          assert_equal 2, failed.rows.count
          assert failed.file.attached?
        end

        test "a non-CSV upload is marked failed and never downloaded" do
          result = load(legacy(content_type: "video/mp4", filename: "clip.mp4"))

          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({not_csv: 1}, result.data[:tally])
          assert_predicate import, :failed?
          assert_equal "not a CSV upload: video/mp4", import.error
          assert_empty @downloads
          refute import.file.attached?
        end

        test "a CSV that is not a Goodreads export is kept, failed with the parser's reason, and has no rows" do
          result = load(legacy, bytes: "name,age\nbob,4\n")

          import = ::Books::GoodreadsImport.find_by!(legacy_import_id: 501)
          assert_equal({unreadable: 1}, result.data[:tally])
          assert_predicate import, :failed?
          assert_match(/\Alegacy upload unreadable: missing Goodreads export headers/, import.error)
          assert_equal 0, import.rows.count
        end

        test "a Windows-1252 file loads with its accents" do
          bytes = goodreads_csv({"Book Id" => "1003", "Title" => "Café Society", "Author" => "Zoë Ågren", "Exclusive Shelf" => "read"})
            .encode(Encoding::Windows_1252)

          load(legacy, bytes: bytes)

          assert_equal "Café Society", ::Books::GoodreadsImport.find_by!(legacy_import_id: 501).editions.first.title
        end

        test "an import whose user is gone from the new app is counted and skipped; the rest still load" do
          result = load(legacy(user_id: 0), legacy(id: 502))

          assert_equal({missing_user: 1, loaded: 1}, result.data[:tally])
          assert_nil ::Books::GoodreadsImport.find_by(legacy_import_id: 501)
          assert ::Books::GoodreadsImport.exists?(legacy_import_id: 502)
        end

        test "a legacy import with no blob is counted and left unattached" do
          result = load(legacy(blob_key: nil))

          assert_equal({missing_file: 1}, result.data[:tally])
          assert_empty @downloads
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/load_imports_test.rb`
Expected: FAIL with `uninitialized constant Services::Books::GoodreadsReplay::LoadImports`.

- [ ] **Step 4: Write LoadImports**

`web-app/app/lib/services/books/goodreads_replay/load_imports.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Copies the legacy app's Goodreads imports into replay imports (Goodreads
      # import spec §12.1). Each one keeps its legacy id and the user's preserved
      # id. Its upload is downloaded from the legacy R2 bucket once, onto the
      # private service, and its rows are parsed. Statuses:
      # - a legacy import that completed is complete;
      # - a failed or stuck one is failed, with the legacy reason, and still
      #   gets its file and rows, for increment 7 to finish;
      # - a non-CSV upload is failed and never downloaded.
      #
      # Repeatable: an import already loaded is reused and its file is never
      # downloaded again. ParseRows skips rows already written, so a run after
      # the books re-migration truncated the rows parses the kept file again.
      class LoadImports
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        LegacyImport = Data.define(:id, :user_id, :status, :error, :blob_key, :content_type, :filename)
        CSV_TYPE = "text/csv"

        # The legacy imports, oldest first, each with its upload's blob.
        class LegacyImports
          include Enumerable

          def each
            ::LegacyBooks::GoodreadsImport.includes(file_attachment: :blob).find_each do |import|
              blob = import.file_attachment&.blob
              yield LegacyImport.new(
                id: import.id, user_id: import.user_id, error: import.error,
                status: ::LegacyBooks::GoodreadsImport::STATUSES.fetch(import.status, import.status.to_s),
                blob_key: blob&.key, content_type: blob&.content_type, filename: blob&.filename
              )
            end
          end
        end

        def self.call(legacy_imports: LegacyImports.new, download: nil)
          new(legacy_imports: legacy_imports, download: download).call
        end

        def initialize(legacy_imports:, download:)
          @legacy_imports = legacy_imports
          @download = download || method(:download_from_legacy_r2)
        end

        def call
          tally = Hash.new(0)
          @legacy_imports.each { |legacy| tally[load(legacy)] += 1 }
          Result.new(success?: true, data: {tally: tally.to_h}, errors: [])
        end

        private

        def load(legacy)
          user = ::User.find_by(id: legacy.user_id)
          return :missing_user unless user

          import = ::Books::GoodreadsImport.find_by(legacy_import_id: legacy.id) ||
            ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, legacy_import_id: legacy.id, **initial_state(legacy))
          return :not_csv unless legacy.content_type == CSV_TYPE
          return :missing_file if legacy.blob_key.blank? && !import.file.attached?

          parsed = ::Books::Goodreads::ExportFile.parse(bytes_for(import, legacy))
          unless parsed.success?
            import.update!(status: :failed, error: "legacy upload unreadable: #{parsed.errors.join("; ")}")
            return :unreadable
          end

          ::Services::Books::GoodreadsImports::ParseRows.call(import: import, rows: parsed.data[:rows])
          :loaded
        end

        def initial_state(legacy)
          return {status: :failed, error: "not a CSV upload: #{legacy.content_type}"} unless legacy.content_type == CSV_TYPE

          case legacy.status
          when "complete" then {status: :complete}
          when "failed" then {status: :failed, error: "legacy import failed: #{legacy.error}"}
          else {status: :failed, error: "legacy import never finished (#{legacy.status})"}
          end
        end

        def bytes_for(import, legacy)
          return import.file.download if import.file.attached?

          bytes = @download.call(legacy.blob_key)
          import.file.attach(io: StringIO.new(bytes), filename: legacy.filename.to_s, content_type: CSV_TYPE, identify: false)
          bytes
        end

        def download_from_legacy_r2(key)
          r2 = ::Services::BooksMigration::LegacyR2
          r2.client.get_object(bucket: r2.bucket, key: key).body.read
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/load_imports_test.rb`
Expected: PASS, 9 runs.

- [ ] **Step 5: Write the failing rake test**

`web-app/test/lib/tasks/books_goodreads_replay_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsReplayRakeTest < ActiveSupport::TestCase
  REPLAY = Services::Books::GoodreadsReplay

  setup do
    # Load only this rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:goodreads_replay:load")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads_replay.rake").to_s }
    end
    Rake::Task.tasks.each(&:reenable)
  end

  def result(data)
    Struct.new(:success?, :data, :errors, keyword_init: true).new(success?: true, data: data, errors: [])
  end

  test "load prints the tally" do
    REPLAY::LoadImports.expects(:call).returns(result(tally: {loaded: 795, not_csv: 8}))

    assert_output(/loaded 795, not_csv 8/) { Rake::Task["books:goodreads_replay:load"].invoke }
  end
end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: FAIL. The rake file does not exist (`LoadError`).

- [ ] **Step 6: Write the rake file**

`web-app/lib/tasks/books/goodreads_replay.rake`:

```ruby
# The legacy Goodreads replay (Goodreads import spec §12). A full pass, after
# every books migration pass and in the launch sequence:
#   load -> fix_slugs -> apply -> resolve (wait for the jobs) -> duplicates -> junk -> apply -> report
# apply does nothing while config.x.goodreads_replay.auto_apply is false.
namespace :books do
  namespace :goodreads_replay do
    tally = ->(counts) { counts.map { |key, count| "#{key} #{count}" }.join(", ").presence || "nothing" }

    desc "Copy the legacy app's Goodreads imports, their uploads (legacy R2, LEGACY_R2_* env) and rows into " \
      "replay imports. Idempotent; reads the legacy_books database."
    task load: :environment do
      puts "legacy Goodreads imports: #{tally.call(Services::Books::GoodreadsReplay::LoadImports.call.data[:tally])}"
    end
  end
end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 7: Smoke-run the real loader against development**

The source is read-only; the run writes only replay rows. The blank bucket keeps the uploads on local Disk, which `storage.yml` does in development when the bucket is blank. Without it, they would go to the shared private R2 bucket.

Run from `web-app/`: `PRIVATE_IMPORTS_STORAGE_BUCKET= bin/rails books:goodreads_replay:load`
Expected: roughly `loaded 795, not_csv 8`, with a few `unreadable` folded into the counts. It writes about 388k rows, which takes minutes. Then run `bin/rails runner 'puts Books::GoodreadsImport.legacy_replay.group(:status).count.inspect'`.
Expected: about 750 `complete`, plus the failed ones.

If the legacy DB or `LEGACY_R2_*` is absent, write `Task 2: Ruling: smoke run skipped — <reason>` in the ledger and move on. The tests are the contract.

- [ ] **Step 8: Commit**

```bash
git add app/models/legacy_books/goodreads_import.rb app/models/books/goodreads_import.rb \
  app/lib/services/books/goodreads_replay/load_imports.rb lib/tasks/books/goodreads_replay.rake \
  test/models/legacy_books/goodreads_import_test.rb test/models/books/goodreads_import_test.rb \
  test/lib/services/books/goodreads_replay/load_imports_test.rb test/lib/tasks/books_goodreads_replay_rake_test.rb
git commit -m "Goodreads replay: load legacy imports, uploads and rows"
```

---
### Task 3: Slug fix-ups and applying `strip_identifier` (§12.2)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/fix_slug_identifiers.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/strip_identifier.rb`
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake` (add `fix_slugs`)
- Test: `web-app/test/lib/services/books/goodreads_replay/fix_slug_identifiers_test.rb`, `web-app/test/lib/services/books/goodreads_replay/apply/strip_identifier_test.rb`, the rake test

**Interfaces:**
- Consumes: `RecordVerdict.call(...)` (Task 1), `Services::DuplicateCandidates::Flag.call(item_type:, ids:, source:, evidence:)`.
- Produces: `FixSlugIdentifiers.call` returns `Result(data: {recorded: Integer})`.
  - Subject key: `"book:<book_id>:books_work_goodreads_id:<slug value>"`.
  - Payload: `{"book_id", "remove" => [[type, value]], "add" => [[type, bare]]}`.
  - Recorded with `decided_by: :rule`, `confidence: :certain`, `auto: true`.
- Produces: `Apply::StripIdentifier.call(verdict:)` returns `Result(data: {outcome: :applied | :noop, reason:})`.
- Produces: `Apply::StripIdentifier.change(book:, remove:, add:)` returns `Integer` (rows changed). Relink (Task 7) uses it.
- **Every `Apply::*` handler** has the same shape: `self.call(verdict:)` returns a `Result` with `data[:outcome]` in `:applied` or `:noop`, plus `data[:reason]` on a noop. It raises on failure; `ApplyVerdicts` (Task 11) records the error.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_replay/fix_slug_identifiers_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FixSlugIdentifiersTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @slug = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656-war-and-peace")
        end

        test "each slug-form Goodreads id becomes an approved, rule-certain strip_identifier verdict" do
          assert_equal 1, FixSlugIdentifiers.call.data[:recorded]

          verdict = ::Books::RepairVerdict.strip_identifier.sole
          assert_equal "book:#{@book.id}:books_work_goodreads_id:656-war-and-peace", verdict.subject_key
          assert_equal({"book_id" => @book.id, "remove" => [["books_work_goodreads_id", "656-war-and-peace"]],
                        "add" => [["books_work_goodreads_id", "656"]]}, verdict.payload)
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_rule?
          assert_predicate verdict, :confidence_certain?
        end

        test "bare ids are left alone, and running again records nothing new" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "1234")

          FixSlugIdentifiers.call
          FixSlugIdentifiers.call

          assert_equal 1, ::Books::RepairVerdict.count
        end

        test "changes nothing in the catalog" do
          FixSlugIdentifiers.call

          assert_equal "656-war-and-peace", @slug.reload.value
        end
      end
    end
  end
end
```

`web-app/test/lib/services/books/goodreads_replay/apply/strip_identifier_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class StripIdentifierTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @other = books_books(:crime_and_punishment)
            ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656-war-and-peace")
          end

          def verdict(book_id: @book.id, remove: [["books_work_goodreads_id", "656-war-and-peace"]], add: [["books_work_goodreads_id", "656"]])
            ::Books::RepairVerdict.create!(kind: :strip_identifier, subject_key: "book:#{book_id}:x", decided_by: :rule,
              status: :approved, payload: {"book_id" => book_id, "remove" => remove, "add" => add})
          end

          def goodreads_ids(book)
            book.identifiers.where(identifier_type: :books_work_goodreads_id).pluck(:value).sort
          end

          test "replaces the slug with the bare id" do
            result = StripIdentifier.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal ["656"], goodreads_ids(@book)
          end

          test "drops the slug when the book already holds the bare id" do
            ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")

            StripIdentifier.call(verdict: verdict)

            assert_equal ["656"], goodreads_ids(@book)
          end

          test "applying twice does nothing the second time" do
            StripIdentifier.call(verdict: verdict)
            result = StripIdentifier.call(verdict: verdict)

            assert_equal :noop, result.data[:outcome]
            assert_equal ["656"], goodreads_ids(@book)
          end

          test "a bare id another book already holds is added, and the two books are flagged as a suspected pair" do
            ::Identifier.create!(identifiable: @other, identifier_type: :books_work_goodreads_id, value: "656")

            StripIdentifier.call(verdict: verdict)

            pair = ::DuplicateCandidate.sole
            assert_equal [@book.id, @other.id].minmax, [pair.item_a_id, pair.item_b_id]
            assert_predicate pair, :raised_by_identifier_collision?
          end

          test "a book that no longer exists is a no-op with a reason" do
            result = StripIdentifier.call(verdict: verdict(book_id: 0))

            assert_equal :noop, result.data[:outcome]
            assert_equal "book 0 no longer exists", result.data[:reason]
          end
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/fix_slug_identifiers_test.rb test/lib/services/books/goodreads_replay/apply/strip_identifier_test.rb`
Expected: FAIL. Both constants are undefined.

- [ ] **Step 2: Write FixSlugIdentifiers**

`web-app/app/lib/services/books/goodreads_replay/fix_slug_identifiers.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.2. The legacy app stored 543 Goodreads ids as
      # slugs or URLs (32076670-ball-lightning) and they were migrated as they
      # were, so no identifier lookup of the bare id finds them. Each one
      # becomes a rule-certain strip_identifier verdict that swaps it for the
      # bare id. Applying the verdict (Apply::StripIdentifier) also removes the
      # duplicate that leaves when the book already holds the bare id. Records
      # findings only; changes nothing.
      class FixSlugIdentifiers
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        TYPE = "books_work_goodreads_id"

        def self.call
          new.call
        end

        def call
          recorded = 0
          slugs.find_each do |identifier|
            bare = identifier.value[/\A\d+/]
            next if bare.nil?

            RecordVerdict.call(
              kind: :strip_identifier, subject_key: "book:#{identifier.identifiable_id}:#{TYPE}:#{identifier.value}",
              payload: {book_id: identifier.identifiable_id, remove: [[TYPE, identifier.value]], add: [[TYPE, bare]]},
              decided_by: :rule, confidence: :certain, reason: "slug-form Goodreads id #{identifier.value} is #{bare}", auto: true
            )
            recorded += 1
          end
          Result.new(success?: true, data: {recorded: recorded}, errors: [])
        end

        private

        def slugs
          ::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE).where("value !~ '^[0-9]+$'")
        end
      end
    end
  end
end
```

Note: the second test calls `call` twice and expects one verdict. `RecordVerdict` updates the same row, so `recorded` counts findings, not new rows. That is intended.

- [ ] **Step 3: Write Apply::StripIdentifier**

`web-app/app/lib/services/books/goodreads_replay/apply/strip_identifier.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a strip_identifier verdict: removes the payload's identifiers
        # from the book and adds the ones it lacks (spec §12.2, §12.4). Relink
        # uses .change to move a wrong row's identifiers from one book to
        # another. An added identifier another book already holds flags the two
        # as a suspected duplicate pair, as the finder does for a collision.
        # Idempotent: what is already gone, or already there, is left alone.
        class StripIdentifier
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return noop("book #{verdict.payload["book_id"]} no longer exists") unless book

            changed = change(book: book, remove: verdict.payload["remove"], add: verdict.payload["add"])
            changed.zero? ? noop("already applied") : Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          def self.change(book:, remove:, add:)
            changed = 0
            ActiveRecord::Base.transaction do
              Array(remove).each do |type, value|
                changed += book.identifiers.where(identifier_type: type, value: value).destroy_all.size
              end
              Array(add).each do |type, value|
                next if book.identifiers.exists?(identifier_type: type, value: value)

                ::Identifier.create!(identifiable: book, identifier_type: type, value: value)
                changed += 1
              end
            end
            Array(add).each { |type, value| flag_collisions(book, type, value) }
            changed
          end

          def self.flag_collisions(book, type, value)
            ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: value)
              .where.not(identifiable_id: book.id).pluck(:identifiable_id).each do |other_id|
              ::Services::DuplicateCandidates::Flag.call(
                item_type: "Books::Book", ids: [book.id, other_id], source: :identifier_collision,
                evidence: {reason: "both hold #{type} #{value} after a Goodreads replay identifier fix"}
              )
            end
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :flag_collisions, :noop
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/fix_slug_identifiers_test.rb test/lib/services/books/goodreads_replay/apply/strip_identifier_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS, 8 runs; `All is good!`

- [ ] **Step 4: Add the rake task, test first**

Add to the rake test:

```ruby
  test "fix_slugs prints how many slug ids it recorded" do
    REPLAY::FixSlugIdentifiers.expects(:call).returns(result(recorded: 543))

    assert_output(/slug-form Goodreads ids: 543 verdicts/) { Rake::Task["books:goodreads_replay:fix_slugs"].invoke }
  end
```

Run it. Expected: FAIL, because the task does not exist. Then add inside `namespace :goodreads_replay`:

```ruby
    desc "Record a strip_identifier verdict for every slug-form Goodreads id (applied by books:goodreads_replay:apply)"
    task fix_slugs: :environment do
      puts "slug-form Goodreads ids: #{Services::Books::GoodreadsReplay::FixSlugIdentifiers.call.data[:recorded]} verdicts"
    end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_replay/fix_slug_identifiers.rb app/lib/services/books/goodreads_replay/apply \
  lib/tasks/books/goodreads_replay.rake test/lib/services/books/goodreads_replay test/lib/tasks/books_goodreads_replay_rake_test.rb
git commit -m "Goodreads replay: slug-form Goodreads id fix-ups"
```

---
### Task 4: The finder's Open Library mode and the identifier source (§12.3 pass one)

**Files:**
- Create: `web-app/app/lib/data_importers/books/book/open_library_identifier_source.rb`
- Modify: `web-app/app/lib/data_importers/books/book/finder.rb`
- Test: `web-app/test/lib/data_importers/books/book/open_library_identifier_source_test.rb`, `web-app/test/lib/data_importers/books/book/finder_test.rb` (append)

**Interfaces:**
- Consumes: `Books::OpenLibrary::Client#identifier(type, value)` returns `[IdentifierHit]`, where a hit has `work_key` and `redirected_from`.
- Produces: `DataImporters::Books::Book::Finder.new(open_library_client: nil, open_library: :resolve)`. The mode is one of `:resolve` (default, the current behaviour), `:identifiers` or `:all`; anything else raises `ArgumentError`.
- Produces: `OpenLibraryIdentifierSource.new(query:, client: nil)`, whose `#name` is `:open_library_identifier`. Its candidates are local books holding a work key that the query's ISBN-13, ISBN-10 or Goodreads id maps to. Each has `sources: [:open_library_identifier]` and `evidence[:matched_identifier] = {type: "open_library <type>", value:}`.

Why the source is not decisive and never blocks rule 4: it reports which work Open Library files an ISBN under, not a verdict. The AI sees it as "shares open_library isbn13", strong evidence that is not proof, as the AI's instructions already say.

- [ ] **Step 1: Write the failing source tests**

`web-app/test/lib/data_importers/books/book/open_library_identifier_source_test.rb`:

```ruby
require "test_helper"

module DataImporters
  module Books
    module Book
      class OpenLibraryIdentifierSourceTest < ActiveSupport::TestCase
        setup do
          @holder = books_books(:crime_and_punishment) # holds OL262758W (fixture)
          @client = stub("open_library_client")
        end

        def hit(work_key, redirected_from: [])
          ::Books::OpenLibrary::IdentifierHit.new(work_key: work_key, source: "dump", redirected_from: redirected_from,
            edition_keys: [], id_type: "isbn13", value: "x")
        end

        def query(**attributes)
          ImportQuery.new(title: "Crime and Punishment", **attributes)
        end

        test "a local book holding the work an ISBN maps to becomes a candidate" do
          @client.expects(:identifier).with("isbn13", "9780143058144").returns([hit("OL262758W")])

          candidates = OpenLibraryIdentifierSource.new(query: query(isbn13: ["9780143058144"]), client: @client).call

          assert_equal [@holder], candidates.map(&:record)
          assert_equal [:open_library_identifier], candidates.first.sources
          assert_equal({type: "open_library isbn13", value: "9780143058144"}, candidates.first.evidence[:matched_identifier])
        end

        test "a redirected work key finds the book holding the old key" do
          @client.stubs(:identifier).returns([hit("OL999W", redirected_from: ["OL262758W"])])

          candidates = OpenLibraryIdentifierSource.new(query: query(goodreads_id: ["7144"]), client: @client).call

          assert_equal [@holder], candidates.map(&:record)
        end

        test "an identifier Open Library does not know, or refuses, is no candidate and no failure" do
          @client.stubs(:identifier).with("isbn13", "9780000000002").returns([])
          @client.stubs(:identifier).with("isbn10", "000000000X")
            .raises(::Books::OpenLibrary::Exceptions::ClientError.new("bad", 422))

          source = OpenLibraryIdentifierSource.new(query: query(isbn13: ["9780000000002"], isbn10: ["000000000X"]), client: @client)

          assert_empty source.call
        end

        test "a query with no identifiers asks nothing" do
          @client.expects(:identifier).never

          assert_empty OpenLibraryIdentifierSource.new(query: query, client: @client).call
        end

        test "an outage raises, so the finder records a failed source" do
          @client.stubs(:identifier).raises(::Books::OpenLibrary::Exceptions::NetworkError.new("down"))

          assert_raises(::Books::OpenLibrary::Exceptions::NetworkError) do
            OpenLibraryIdentifierSource.new(query: query(isbn13: ["9780143058144"]), client: @client).call
          end
        end
      end
    end
  end
end
```

Append to `web-app/test/lib/data_importers/books/book/finder_test.rb`, inside the test class:

```ruby
  test "open_library mode chooses which Open Library sources run" do
    query = DataImporters::Books::Book::ImportQuery.new(title: "Dune", author_names: ["Frank Herbert"])
    names = ->(mode) { DataImporters::Books::Book::Finder.new(open_library: mode).send(:candidate_sources, query).map(&:name) }

    assert_equal %i[identifier exact opensearch open_library], DataImporters::Books::Book::Finder.new.send(:candidate_sources, query).map(&:name)
    assert_equal %i[identifier exact opensearch open_library_identifier], names.call(:identifiers)
    assert_equal %i[identifier exact opensearch open_library_identifier open_library], names.call(:all)
    assert_raises(ArgumentError) { DataImporters::Books::Book::Finder.new(open_library: :sometimes) }
  end
```

Before running, check the existing source names: `grep -n "def name" app/lib/data_importers/sources/*.rb`. If `OpenSearch#name` is not `:opensearch`, use its actual symbol in all three assertions and ledger the change.

Run: `bin/rails test test/lib/data_importers/books/book/open_library_identifier_source_test.rb test/lib/data_importers/books/book/finder_test.rb`
Expected: FAIL. `OpenLibraryIdentifierSource` is undefined and `open_library:` is an unknown keyword.

- [ ] **Step 2: Write the source**

`web-app/app/lib/data_importers/books/book/open_library_identifier_source.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Pass one of the Goodreads replay (spec §12.3): the fast Open Library
      # lookup. Asks the data service which work each of the query's ISBN-13s,
      # ISBN-10s and Goodreads ids belongs to (GET /identifiers, milliseconds,
      # unlike /resolve's 5-6 s) and returns the local books holding those
      # works' keys, or a key they redirect from. That is evidence for the
      # rules and the AI, never a verdict: no rule treats it as decisive.
      #
      # An identifier the service does not know is an empty answer; one it
      # refuses (422) is no candidate rather than a failed source. Anything
      # else raises, and the finder records the source as failed.
      class OpenLibraryIdentifierSource
        LOOKUPS = [[:isbn13, "isbn13"], [:isbn10, "isbn10"], [:goodreads_id, "goodreads"]].freeze

        def initialize(query:, client: nil)
          @query = query
          @client = client
        end

        def name
          :open_library_identifier
        end

        def call
          matched = {}
          LOOKUPS.each do |field, type|
            Array(@query.public_send(field)).each do |value|
              hits(type, value).each do |hit|
                [hit.work_key, *hit.redirected_from].compact_blank.each { |key| matched[key] ||= {type: "open_library #{type}", value: value} }
              end
            end
          end
          return [] if matched.empty?

          holders(matched.keys).map do |book, key|
            Candidate.new(record: book, sources: [:open_library_identifier], evidence: {matched_identifier: matched.fetch(key)})
          end
        end

        # Lazy, as in OpenLibrarySource: the default client builds a circuit
        # breaker against REDIS_POOL, which a test that injects its own must
        # never trigger.
        def client
          @client ||= ::Books::OpenLibrary::Client.new
        end

        private

        def hits(type, value)
          client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::ClientError
          []
        end

        def holders(keys)
          rows = ::Identifier.where(identifiable_type: "Books::Book",
            identifier_type: ::Identifier.identifier_types[:books_work_openlibrary_id], value: keys)
            .order(:identifiable_id).pluck(:identifiable_id, :value)
          books = ::Books::Book.where(id: rows.map(&:first)).index_by(&:id)
          rows.uniq(&:first).filter_map { |book_id, key| [books[book_id], key] if books[book_id] }
        end
      end
    end
  end
end
```

- [ ] **Step 3: Add the mode to the finder**

In `web-app/app/lib/data_importers/books/book/finder.rb`:

1. Below `EXACT_LIMIT = 5`, add:
   ```ruby
   # Which Open Library sources run: :resolve (the /resolve service, the
   # default), :identifiers (the fast identifier lookup only; the Goodreads
   # replay's pass one) or :all (both; its pass two).
   OPEN_LIBRARY_MODES = %i[resolve identifiers all].freeze
   ```
2. Replace `initialize` with:
   ```ruby
   # open_library_client: injected by tests; nil builds the real client
   # lazily inside the Open Library sources.
   def initialize(open_library_client: nil, open_library: :resolve)
     raise ArgumentError, "unknown open_library mode: #{open_library.inspect}" unless OPEN_LIBRARY_MODES.include?(open_library)

     @open_library_client = open_library_client
     @open_library = open_library
   end
   ```
3. In `candidate_sources`, replace the final `OpenLibrarySource.new(...)` element and the closing `]` with:
   ```ruby
       ] + open_library_sources(query)
     end

     def open_library_sources(query)
       sources = []
       sources << OpenLibraryIdentifierSource.new(query: query, client: @open_library_client) unless @open_library == :resolve
       sources << OpenLibrarySource.new(query: query, client: @open_library_client, limit: OPEN_LIBRARY_LIMIT) unless @open_library == :identifiers
       sources
   ```
   This keeps `candidate_sources` returning the same array for the default mode. `open_library_sources` belongs among the `private` methods: put it under `private`, and keep `candidate_sources` itself `protected`.
4. Update the class comment's source list: "…and the Open Library resolve service (or, by mode, its identifier lookup, or both)."

Run: `bin/rails test test/lib/data_importers/books/book/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS. Every existing finder test still passes unchanged, because the default mode is the old behaviour.

- [ ] **Step 4: Commit**

```bash
git add app/lib/data_importers/books/book test/lib/data_importers/books/book
git commit -m "Books finder: Open Library identifier source and an open_library mode"
```

---
### Task 5: Legacy's choice and the compare (§12.4)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/edition_query.rb` (extracted from `ResolveEdition#query`)
- Modify: `web-app/app/lib/services/books/goodreads_imports/resolve_edition.rb`
- Create (generator): a migration adding `replay_finding` and `legacy_book_id` to `books_goodreads_import_rows`
- Modify: `web-app/app/models/books/goodreads_import_row.rb` (enum)
- Create: `web-app/app/lib/services/books/goodreads_replay/legacy_choice.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/compare_edition.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/edition_query_test.rb`, `web-app/test/lib/services/books/goodreads_replay/legacy_choice_test.rb`, `web-app/test/lib/services/books/goodreads_replay/compare_edition_test.rb`, `web-app/test/models/books/goodreads_import_row_test.rb` (add one test)

**Interfaces:**
- Consumes: `RecordVerdict` (Task 1), the `DataImporters::Match` struct, and `FinderBase#titles_agree?(query, record)` / `#creators_agree?(query, record)`, which are public.
- Produces: `Services::Books::GoodreadsImports::EditionQuery.call(edition)` returns the `ImportQuery` that member resolution already builds (moved, not changed).
- Produces: the column `Books::GoodreadsImportRow#replay_finding`, an enum with prefix `replay_`: `{agrees: 0, duplicate: 1, disagrees: 2, unmatched: 3, no_legacy_choice: 4, awaiting_full_pass: 5}`.
- Produces: the column `#legacy_book_id` (bigint, no FK: it names a book across re-migrations).
- Produces: `LegacyChoice.call(goodreads_book_id:, user_id:)` returns `Books::Book` or nil. It returns the lowest-id book that holds the Goodreads id, bare or in slug form, and that is on one of the user's lists.
- Produces: `CompareEdition.call(edition:, match:, finder:, query:, final:)` returns `Result(data: {needs_full_pass: Boolean, tally: {finding => rows}})`. It writes every replay row's finding. It records verdicts only when `final`:
  - `relink`, key `"user:<u>:book:<A>:goodreads:<gid>"`;
  - `strip_identifier`, key `"book:<A>:books_work_goodreads_id:<gid>"`.
- Relink payload keys: `user_id`, `from_book_id`, `to_book_id`, `goodreads_book_id`, `rows` (`[[legacy_import_id, row_number], …]`), `match_decision_id`, `strip_identifiers` (`[[type, value], …]`), `row` (`{"title", "author"}`).

- [ ] **Step 1: Extract the edition's finder query (a pure move)**

The replay needs the exact query that member resolution builds. Write the test first:

`web-app/test/lib/services/books/goodreads_imports/edition_query_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class EditionQueryTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        test "builds the finder query from the edition's parsed fields" do
          edition = goodreads_edition(title: "Mistborn", primary_author: "Brandon Sanderson", series_name: "Mistborn",
            series_number: "1", additional_authors: ["Some Narrator"], isbn13: "9780765311788", isbn10: "076531178X",
            original_publication_year: 2006, year_published: 2007)

          query = EditionQuery.call(edition)

          assert_equal "Mistborn", query.title
          assert_equal ["Brandon Sanderson"], query.author_names
          assert_equal 2006, query.year
          assert_equal ["9780765311788"], query.isbn13
          assert_equal ["076531178X"], query.isbn10
          assert_equal [edition.goodreads_book_id.to_s], query.goodreads_id
          assert_equal ["Mistborn", "1"], [query.series_name, query.series_number]
          assert_equal ["Some Narrator"], query.context_author_names
        end

        test "falls back to the edition's own year" do
          edition = goodreads_edition(year_published: 1999)

          assert_equal 1999, EditionQuery.call(edition).year
        end
      end
    end
  end
end
```

Run it. Expected: FAIL (`uninitialized constant ...EditionQuery`). Then create `web-app/app/lib/services/books/goodreads_imports/edition_query.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # The books finder query for a Goodreads edition (Goodreads import spec §5):
      # its title and primary author, year, ISBNs and Goodreads id, with the
      # series and the other credited names as AI context. Shared by member
      # resolution and the legacy replay, so both ask the same question.
      class EditionQuery
        def self.call(edition)
          ::DataImporters::Books::Book::ImportQuery.new(
            title: edition.title,
            author_names: [edition.primary_author],
            year: edition.original_publication_year || edition.year_published,
            isbn13: [edition.isbn13],
            isbn10: [edition.isbn10],
            goodreads_id: [edition.goodreads_book_id.to_s],
            series_name: edition.series_name,
            series_number: edition.series_number,
            context_author_names: edition.additional_authors
          )
        end
      end
    end
  end
end
```

In `resolve_edition.rb`, delete the private `query` method and change the finder call to `@finder.call(query: EditionQuery.call(@edition), subject: @edition)`.

Run: `bin/rails test test/lib/services/books/goodreads_imports/`
Expected: PASS. Every existing resolver test is unchanged.

- [ ] **Step 2: Generate and write the migration**

```bash
bin/rails generate migration AddReplayFindingToBooksGoodreadsImportRows replay_finding:integer legacy_book_id:bigint
```

Edit its `change` to:

```ruby
  def change
    # What the legacy replay found for the row (Goodreads import spec §12.4), and
    # the book legacy chose for it. No FK: the book is named across books
    # re-migrations, which recreate it under the same preserved id.
    add_column :books_goodreads_import_rows, :replay_finding, :integer
    add_column :books_goodreads_import_rows, :legacy_book_id, :bigint
    add_index :books_goodreads_import_rows, :replay_finding
  end
```

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:test:prepare`
Expected: both columns and the index appear in `db/schema.rb`.

- [ ] **Step 3: Write the failing tests**

Add to `web-app/test/models/books/goodreads_import_row_test.rb`, inside the class:

```ruby
    test "replay findings use the replay_ prefix" do
      assert_equal %w[agrees duplicate disagrees unmatched no_legacy_choice awaiting_full_pass],
        Books::GoodreadsImportRow.replay_findings.keys
      assert_respond_to Books::GoodreadsImportRow.new, :replay_agrees?
    end
```

`web-app/test/lib/services/books/goodreads_replay/legacy_choice_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class LegacyChoiceTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @read = user_lists(:regular_user_books_read)
          @book = books_books(:war_and_peace)
        end

        def holds(book, value)
          ::Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: value)
        end

        test "the book holding the id that is on the user's lists" do
          holds(@book, "656")
          UserListItem.create!(user_list: @read, listable: @book)

          assert_equal @book, LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end

        test "a slug-form id is legacy's too" do
          holds(@book, "656-war-and-peace")
          UserListItem.create!(user_list: @read, listable: @book)

          assert_equal @book, LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end

        test "a holder the user does not have is not legacy's choice for that user" do
          holds(@book, "656")

          assert_nil LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end

        test "a longer id sharing the digits is not the same id" do
          holds(@book, "6567")
          UserListItem.create!(user_list: @read, listable: @book)

          assert_nil LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end
      end
    end
  end
end
```

`web-app/test/lib/services/books/goodreads_replay/compare_edition_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class CompareEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = users(:regular_user)
          @legacy = books_books(:war_and_peace)       # legacy's choice
          @resolved = books_books(:crime_and_punishment) # the resolver's answer
          @edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", isbn13: "9780140447934")
          ::Identifier.create!(identifiable: @legacy, identifier_type: :books_work_goodreads_id, value: @edition.goodreads_book_id.to_s)
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @legacy)
          @import = replay_import(legacy_import_id: 501)
          @row = @import.rows.create!(row_number: 3, goodreads_edition: @edition)
          @finder = ::DataImporters::Books::Book::Finder.new
          @query = ::Services::Books::GoodreadsImports::EditionQuery.call(@edition)
        end

        def replay_import(legacy_import_id:, user: @user)
          ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, status: :complete, legacy_import_id: legacy_import_id)
        end

        def match(record, decided_by: :ai, confidence: :high)
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: @edition, record: record,
            outcome: record ? :matched : :unmatched, confidence: confidence, decided_by: decided_by, ai_chat: ai_chats(:general_chat))
          ::DataImporters::Match.new(outcome: record ? :matched : :unmatched, record: record, confidence: confidence,
            decided_by: decided_by, reason: "test reason", candidates: [], decision: decision, sources_failed: [])
        end

        def compare(match, final: true, query: @query)
          CompareEdition.call(edition: @edition, match: match, finder: @finder, query: query, final: final)
        end

        test "the resolver choosing legacy's book is agreement, with no verdict" do
          result = compare(match(@legacy))

          assert_predicate @row.reload, :replay_agrees?
          assert_equal @legacy.id, @row.legacy_book_id
          assert_equal({agrees: 1}, result.data[:tally])
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "a row with no legacy choice is counted as such" do
          UserListItem.where(listable: @legacy).delete_all

          compare(match(@resolved))

          assert_predicate @row.reload, :replay_no_legacy_choice?
          assert_nil @row.legacy_book_id
        end

        test "pass one leaves a disagreement for the full pass and records nothing" do
          result = compare(match(@resolved), final: false)

          assert result.data[:needs_full_pass]
          assert_predicate @row.reload, :replay_awaiting_full_pass?
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "an AI disagreement on the final pass is a proposed relink for that user" do
          decision_match = match(@resolved)
          compare(decision_match)

          verdict = ::Books::RepairVerdict.relink.sole
          assert_predicate @row.reload, :replay_disagrees?
          assert_equal "user:#{@user.id}:book:#{@legacy.id}:goodreads:#{@edition.goodreads_book_id}", verdict.subject_key
          assert_predicate verdict, :proposed?
          assert_predicate verdict, :decided_by_ai?
          assert_equal ai_chats(:general_chat).id, verdict.ai_chat_id
          assert_equal({"user_id" => @user.id, "from_book_id" => @legacy.id, "to_book_id" => @resolved.id,
                        "goodreads_book_id" => @edition.goodreads_book_id, "rows" => [[501, 3]],
                        "match_decision_id" => decision_match.decision.id, "strip_identifiers" => [],
                        "row" => {"title" => "War and Peace", "author" => "Leo Tolstoy"}}, verdict.payload)
        end

        test "a rule-certain disagreement is approved on its own" do
          compare(match(@resolved, decided_by: :rule, confidence: :high))

          verdict = ::Books::RepairVerdict.relink.sole
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_rule?
        end

        test "when legacy's book contradicts the row's title and author, the relink also moves the row's identifiers" do
          ::Identifier.create!(identifiable: @legacy, identifier_type: :books_work_isbn13, value: "9780140447934") unless
            @legacy.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9780140447934")
          query = ::DataImporters::Books::Book::ImportQuery.new(title: "Some Other Novel", author_names: ["Nobody Known"])

          compare(match(@resolved), query: query)

          assert_equal [["books_work_goodreads_id", @edition.goodreads_book_id.to_s], ["books_work_isbn13", "9780140447934"]],
            ::Books::RepairVerdict.relink.sole.payload["strip_identifiers"]
        end

        test "legacy's book and the resolver's already being a duplicate pair is a duplicate finding, not a relink" do
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@legacy.id, @resolved.id], source: :ai)

          compare(match(@resolved))

          assert_predicate @row.reload, :replay_duplicate?
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "unmatched with a contradicting legacy book proposes stripping its identifiers, with cached page facts" do
          goodreads_page(goodreads_book_id: @edition.goodreads_book_id, title: "War and Peace", authors: [["Leo Tolstoy", "Author"]])
          query = ::DataImporters::Books::Book::ImportQuery.new(title: "Some Other Novel", author_names: ["Nobody Known"])

          compare(match(nil), query: query)

          verdict = ::Books::RepairVerdict.strip_identifier.sole
          assert_predicate @row.reload, :replay_unmatched?
          assert_equal "book:#{@legacy.id}:books_work_goodreads_id:#{@edition.goodreads_book_id}", verdict.subject_key
          assert_predicate verdict, :proposed?
          assert_equal [["books_work_goodreads_id", @edition.goodreads_book_id.to_s], ["books_work_isbn13", "9780140447934"]],
            verdict.payload["remove"]
          assert_equal [], verdict.payload["add"]
          assert_equal({"outcome" => "found", "title" => "War and Peace", "authors" => ["Leo Tolstoy"]}, verdict.payload["goodreads_page"])
        end

        test "unmatched where legacy's book still agrees on title or author is counted, not queued" do
          compare(match(nil))

          assert_predicate @row.reload, :replay_unmatched?
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "one user's two imports naming the edition give one relink, and both imports' rows are compared" do
          second = replay_import(legacy_import_id: 502)
          second_row = second.rows.create!(row_number: 9, goodreads_edition: @edition)

          compare(match(@resolved))

          verdict = ::Books::RepairVerdict.relink.sole
          assert_equal [[501, 3], [502, 9]], verdict.payload["rows"].sort
          assert_predicate second_row.reload, :replay_disagrees?
        end

        test "member imports' rows are not the replay's" do
          member = ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :member, status: :complete)
          member_row = member.rows.create!(row_number: 1, goodreads_edition: @edition)

          compare(match(@resolved))

          assert_nil member_row.reload.replay_finding
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/legacy_choice_test.rb test/lib/services/books/goodreads_replay/compare_edition_test.rb test/models/books/goodreads_import_row_test.rb`
Expected: FAIL. The enum, `LegacyChoice` and `CompareEdition` are undefined.

- [ ] **Step 4: Write the enum, LegacyChoice and CompareEdition**

In `web-app/app/models/books/goodreads_import_row.rb`, under the `outcome` enum:

```ruby
    # The legacy replay's comparison with the book legacy chose (spec §12.4).
    enum :replay_finding, {agrees: 0, duplicate: 1, disagrees: 2, unmatched: 3, no_legacy_choice: 4, awaiting_full_pass: 5},
      prefix: :replay
```

`web-app/app/lib/services/books/goodreads_replay/legacy_choice.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The book legacy chose for a user's row (Goodreads import spec §12.4):
      # the one that holds the row's Goodreads id and is on that user's lists.
      # Legacy stamped the id on whatever it picked, so this is its choice. The
      # id may be in slug form (32076670-ball-lightning) until the fix-ups are
      # applied; those 543 rows are read once and cached briefly, rather than
      # pattern-scanned per row.
      class LegacyChoice
        TYPE = "books_work_goodreads_id"
        SLUG_CACHE_KEY = "goodreads_replay:slug_goodreads_holders"

        def self.call(goodreads_book_id:, user_id:)
          id = goodreads_book_id.to_s
          holder_ids = (::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE, value: id).pluck(:identifiable_id) +
            slug_holders.fetch(id, [])).uniq
          return nil if holder_ids.empty?

          book_id = ::UserListItem.joins(:user_list).where(user_lists: {user_id: user_id})
            .where(listable_type: "Books::Book", listable_id: holder_ids).minimum(:listable_id)
          book_id && ::Books::Book.find_by(id: book_id)
        end

        # {"32076670" => [book_id, ...]} for every slug-form Goodreads id.
        def self.slug_holders
          Rails.cache.fetch(SLUG_CACHE_KEY, expires_in: 10.minutes) do
            ::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE).where("value !~ '^[0-9]+$'")
              .pluck(:value, :identifiable_id)
              .group_by { |value, _| value[/\A\d+/] }.except(nil)
              .transform_values { |pairs| pairs.map(&:last) }
          end
        end
      end
    end
  end
end
```

The "longer id sharing the digits" test passes by construction: `value[/\A\d+/]` of `"6567"` is `"6567"`, and a bare value never enters the slug map.

`web-app/app/lib/services/books/goodreads_replay/compare_edition.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Compares the resolver's answer for an edition with the book legacy chose
      # for each replay user who has it (Goodreads import spec §12.4), and
      # writes each replay row's finding.
      #
      # Findings:
      # - agrees: same book;
      # - duplicate: legacy's book and the resolver's are already a suspected
      #   pair, which the merge will settle;
      # - disagrees: another book;
      # - unmatched: no book;
      # - no_legacy_choice: legacy has nothing for this user.
      #
      # Verdicts come only from the final pass for the edition. On pass one, a
      # disagreement or an unmatched edition waits for the full pass
      # (awaiting_full_pass). On the final pass:
      # - a disagreement is a relink for that user. It is approved on its own
      #   only when a rule decided it at certain or high confidence;
      #   otherwise it is proposed. When legacy's book contradicts the row on
      #   both title and author, legacy's identifier was the mistake, so the
      #   relink also moves the row's identifiers.
      # - an unmatched edition whose legacy book contradicts the row on both
      #   counts proposes stripping those identifiers, with any cached Goodreads
      #   page attached. Any other unmatched edition is only counted.
      #
      # Writes findings and verdicts only, never catalog data.
      class CompareEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        WAITS_FOR_FULL_PASS = %i[disagrees unmatched].freeze

        def self.call(edition:, match:, finder:, query:, final:)
          new(edition: edition, match: match, finder: finder, query: query, final: final).call
        end

        def initialize(edition:, match:, finder:, query:, final:)
          @edition = edition
          @match = match
          @finder = finder
          @query = query
          @final = final
          @resolved = match.matched? ? match.record : nil
        end

        def call
          tally = Hash.new(0)
          replay_rows.group_by { |row| row.import.user_id }.each do |user_id, rows|
            legacy = LegacyChoice.call(goodreads_book_id: @edition.goodreads_book_id, user_id: user_id)
            finding = finding_for(legacy)
            finding = :awaiting_full_pass if !@final && WAITS_FOR_FULL_PASS.include?(finding)
            record(finding, user_id, rows, legacy) if @final
            ::Books::GoodreadsImportRow.where(id: rows.map(&:id))
              .update_all(replay_finding: finding, legacy_book_id: legacy&.id, updated_at: Time.current)
            tally[finding] += rows.size
          end
          Result.new(success?: true, data: {needs_full_pass: tally.key?(:awaiting_full_pass), tally: tally.to_h}, errors: [])
        end

        private

        def replay_rows
          ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay)
            .where(goodreads_edition_id: @edition.id).includes(:import).order(:id).to_a
        end

        def finding_for(legacy)
          return :no_legacy_choice if legacy.nil?
          return :unmatched if @resolved.nil?
          return :agrees if @resolved.id == legacy.id
          return :duplicate if suspected_pair?(legacy, @resolved)

          :disagrees
        end

        def suspected_pair?(book_a, book_b)
          a, b = [book_a.id, book_b.id].minmax
          ::DuplicateCandidate.where(item_type: "Books::Book", item_a_id: a, item_b_id: b).where.not(status: :not_duplicate).exists?
        end

        def record(finding, user_id, rows, legacy)
          case finding
          when :disagrees then record_relink(user_id, rows, legacy)
          when :unmatched then record_strip(user_id, rows, legacy) if contradicts?(legacy)
          end
        end

        def record_relink(user_id, rows, legacy)
          RecordVerdict.call(
            kind: :relink, subject_key: "user:#{user_id}:book:#{legacy.id}:goodreads:#{@edition.goodreads_book_id}",
            payload: base_payload(user_id, rows).merge(
              from_book_id: legacy.id, to_book_id: @resolved.id,
              strip_identifiers: contradicts?(legacy) ? held_identifiers(legacy) : []
            ),
            decided_by: decider, confidence: @match.confidence, reason: @match.reason,
            ai_chat_id: @match.decision&.ai_chat_id, auto: decider == :rule && %i[certain high].include?(@match.confidence)
          )
        end

        def record_strip(user_id, rows, legacy)
          RecordVerdict.call(
            kind: :strip_identifier, subject_key: "book:#{legacy.id}:books_work_goodreads_id:#{@edition.goodreads_book_id}",
            payload: base_payload(user_id, rows).merge(book_id: legacy.id, remove: held_identifiers(legacy), add: [],
              goodreads_page: page_facts),
            decided_by: decider, confidence: @match.confidence, ai_chat_id: @match.decision&.ai_chat_id,
            reason: "#{@match.reason}; legacy's book matches neither the row's title nor its author", auto: false
          )
        end

        def base_payload(user_id, rows)
          {user_id: user_id, goodreads_book_id: @edition.goodreads_book_id,
           rows: rows.map { |row| [row.import.legacy_import_id, row.row_number] },
           match_decision_id: @match.decision&.id, row: {title: @edition.title, author: @edition.primary_author}}
        end

        def contradicts?(book)
          !@finder.titles_agree?(@query, book) && !@finder.creators_agree?(@query, book)
        end

        # The row's own identifiers that the book holds: its Goodreads id (bare or
        # slug form) and its ISBNs.
        def held_identifiers(book)
          id = @edition.goodreads_book_id.to_s
          goodreads = book.identifiers.where(identifier_type: :books_work_goodreads_id).pluck(:value)
            .select { |value| value[/\A\d+/] == id }.sort.map { |value| ["books_work_goodreads_id", value] }
          isbns = [["books_work_isbn13", @edition.isbn13], ["books_work_isbn10", @edition.isbn10]].select do |type, value|
            value.present? && book.identifiers.exists?(identifier_type: type, value: value)
          end
          goodreads + isbns
        end

        def page_facts
          page = ::Books::GoodreadsPage.conclusive.find_by(goodreads_book_id: @edition.goodreads_book_id)
          page && {outcome: page.outcome, title: page.title, authors: page.contributors.map(&:name)}
        end

        def decider
          %i[identifier rule].include?(@match.decided_by) ? :rule : :ai
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/legacy_choice_test.rb test/lib/services/books/goodreads_replay/compare_edition_test.rb test/models/books/goodreads_import_row_test.rb`
Expected: PASS.

- The `strip_identifiers` test assumes `war_and_peace` already holds ISBN-13 `9780140447934` (`test/fixtures/identifiers.yml`); the guard creates it if it does not.
- If `GoodreadsPage#contributors` returns something other than objects with `name`, fix the call rather than the test. `test/support/goodreads_import_helper.rb`'s `goodreads_page` stores `[{name, role, primary}]`.

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb app/models/books/goodreads_import_row.rb app/lib/services/books/goodreads_replay \
  app/lib/services/books/goodreads_imports test/lib/services/books/goodreads_imports \
  test/lib/services/books/goodreads_replay test/models/books/goodreads_import_row_test.rb
git commit -m "Goodreads replay: legacy's choice and the per-row compare"
```

---
### Task 6: Resolving replay editions, in two passes (§12.3)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/resolve_edition.rb`
- Create (generator): `web-app/app/sidekiq/books/goodreads_replay/resolve_edition_job.rb` and its test
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake` (add `resolve`)
- Test: `web-app/test/lib/services/books/goodreads_replay/resolve_edition_test.rb`, `web-app/test/sidekiq/books/goodreads_replay/resolve_edition_job_test.rb`, the rake test

**Interfaces:**
- Consumes: `EditionQuery` and `CompareEdition` (Task 5), and `Finder.new(open_library:)` (Task 4).
- Produces: `Services::Books::GoodreadsReplay::ResolveEdition.call(edition:, pass:, finder: nil)` returns `Result(data: {match:, needs_full_pass:, tally:})`. It raises `ResolveEdition::MatchingFailed` when the AI call failed.
- Produces: `Books::GoodreadsReplay::ResolveEditionJob`, which runs on queue `low` with `retry: 3`.
  - `perform(edition_id, pass = 1)`: pass two is enqueued on `serial`.
  - `.enqueue_pending` returns `{first_pass: Integer, full_pass: Integer}`.

What the edition keeps: a replay match **warms the cache** (spec §12.3: "Results fill `books_goodreads_editions`"). The edition is recorded matched to the resolver's book once no full pass is pending. Three things are never written:
- an edition already settled by an import, or one a member import is waiting on;
- an unmatched edition, because the replay never creates books;
- `needs_review`, because replay decisions leave the match-decision queue (R9).

- [ ] **Step 1: Write the failing service tests**

`web-app/test/lib/services/books/goodreads_replay/resolve_edition_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class ResolveEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy")
          @book = books_books(:war_and_peace)
          @finder = stub("finder")
          @finder.stubs(:titles_agree?).returns(true)
          @finder.stubs(:creators_agree?).returns(true)
        end

        def finder_answers(record, decided_by: :ai, confidence: :medium, needs_review: true)
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: @edition, record: record,
            outcome: record ? :matched : :unmatched, confidence: confidence, decided_by: decided_by, needs_review: needs_review)
          match = ::DataImporters::Match.new(outcome: record ? :matched : :unmatched, record: record, confidence: confidence,
            decided_by: decided_by, reason: "test", candidates: [], decision: decision, sources_failed: [])
          @finder.expects(:call).with(has_entries(verify: true, subject: @edition)).returns(match)
          match
        end

        test "runs the finder in verify mode and warms the edition cache with an agreeing match" do
          finder_answers(@book)

          result = ResolveEdition.call(edition: @edition, pass: 1, finder: @finder)

          refute result.data[:needs_full_pass]
          assert_equal @book, @edition.reload.book
          assert_predicate @edition, :matched?
          assert_predicate @edition, :verification_not_needed?
          refute_nil @edition.resolved_at
        end

        test "replay decisions never wait in the match-decision review queue" do
          match = finder_answers(@book)

          ResolveEdition.call(edition: @edition, pass: 1, finder: @finder)

          refute match.decision.reload.needs_review
        end

        test "an unmatched edition creates nothing and stays unresolved" do
          finder_answers(nil)

          assert_no_difference -> { ::Books::Book.count } do
            ResolveEdition.call(edition: @edition, pass: 2, finder: @finder)
          end
          assert_nil @edition.reload.resolved_at
        end

        test "an edition a member import already settled is left as that import left it" do
          other = books_books(:crime_and_punishment)
          @edition.update!(book: other, resolution: :created, verification: :verified, resolved_at: 1.day.ago)
          finder_answers(@book)

          ResolveEdition.call(edition: @edition, pass: 1, finder: @finder)

          assert_equal other, @edition.reload.book
          assert_predicate @edition, :created?
        end

        test "a failed AI call raises so the job retries, and records no findings" do
          import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 9)
          row = import.rows.create!(row_number: 1, goodreads_edition: @edition)
          finder_answers(nil, decided_by: :fallback, confidence: :low)

          assert_raises(ResolveEdition::MatchingFailed) { ResolveEdition.call(edition: @edition, pass: 1, finder: @finder) }
          assert_nil row.reload.replay_finding
        end

        test "pass one uses the fast Open Library lookup and pass two adds /resolve" do
          assert_equal :identifiers, ResolveEdition.new(edition: @edition, pass: 1, finder: nil).send(:finder).instance_variable_get(:@open_library)
          assert_equal :all, ResolveEdition.new(edition: @edition, pass: 2, finder: nil).send(:finder).instance_variable_get(:@open_library)
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/resolve_edition_test.rb`
Expected: FAIL with `uninitialized constant Services::Books::GoodreadsReplay::ResolveEdition`.

- [ ] **Step 2: Write ResolveEdition**

`web-app/app/lib/services/books/goodreads_replay/resolve_edition.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Resolves one replay edition (Goodreads import spec §12.3) and compares
      # the answer with legacy's (CompareEdition). Always verify: true:
      # legacy's own wrong identifiers sit on the books, and only corroboration
      # rejects them.
      #
      # Passes:
      # - Pass one runs the fast sources (identifiers, exact, OpenSearch, Open
      #   Library's identifier lookup).
      # - Pass two adds Open Library /resolve. It runs only for editions where
      #   pass one disagreed or found nothing.
      #
      # Never creates a book. A match that needs no further pass is recorded on
      # the edition, which warms the cache for members' imports, unless an
      # import already settled the edition or is waiting on it. A failed AI call
      # raises (as in member resolution), so the job retries instead of
      # recording a non-answer.
      class ResolveEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MatchingFailed = Class.new(StandardError)

        def self.call(edition:, pass:, finder: nil)
          new(edition: edition, pass: pass, finder: finder).call
        end

        def initialize(edition:, pass:, finder:)
          @edition = edition
          @pass = pass
          @finder = finder
        end

        def call
          query = ::Services::Books::GoodreadsImports::EditionQuery.call(@edition)
          match = finder.call(query: query, verify: true, subject: @edition)
          raise MatchingFailed, "matching failed for Goodreads edition #{@edition.id}: #{match.reason}" if match.decided_by == :fallback

          match.decision.update!(needs_review: false) if match.decision&.needs_review?
          compared = CompareEdition.call(edition: @edition, match: match, finder: finder, query: query, final: @pass == 2).data
          warm_cache(match) if match.matched? && !compared[:needs_full_pass]
          Result.new(success?: true, data: {match: match, needs_full_pass: compared[:needs_full_pass], tally: compared[:tally]}, errors: [])
        end

        private

        def finder
          @finder ||= ::DataImporters::Books::Book::Finder.new(open_library: (@pass == 1) ? :identifiers : :all)
        end

        def warm_cache(match)
          return if @edition.verification_pending?
          return if @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)

          @edition.update!(book: match.record, resolution: :matched, verification: :not_needed,
            match_decision: match.decision, resolved_at: Time.current)
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/resolve_edition_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 3: Generate the job and write its failing tests**

```bash
bin/rails generate sidekiq:job books/goodreads_replay/resolve_edition
```

Replace `web-app/test/sidekiq/books/goodreads_replay/resolve_edition_job_test.rb` with:

```ruby
require "test_helper"

module Books
  module GoodreadsReplay
    class ResolveEditionJobTest < ActiveSupport::TestCase
      include GoodreadsImportHelper

      RESOLVE = ::Services::Books::GoodreadsReplay::ResolveEdition

      setup do
        @edition = goodreads_edition
        @import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 7)
        @row = @import.rows.create!(row_number: 1, goodreads_edition: @edition)
      end

      def answer(needs_full_pass)
        RESOLVE::Result.new(success?: true, data: {needs_full_pass: needs_full_pass, tally: {}}, errors: [])
      end

      test "pass one resolves the edition, and queues pass two on serial when it disagreed" do
        RESOLVE.expects(:call).with(edition: @edition, pass: 1).returns(answer(true))
        RESOLVE.expects(:call).with(edition: @edition, pass: 2).returns(answer(false))

        Sidekiq::Testing.fake! do
          ResolveEditionJob.new.perform(@edition.id, 1)
          job = ResolveEditionJob.jobs.sole
          assert_equal "serial", job["queue"]
          assert_equal [@edition.id, 2], job["args"]
          ResolveEditionJob.drain
        end
      end

      test "pass one is skipped for an edition whose replay rows all have findings" do
        @row.update!(replay_finding: :agrees)
        RESOLVE.expects(:call).never

        ResolveEditionJob.new.perform(@edition.id, 1)
      end

      test "a missing edition is nothing to do" do
        RESOLVE.expects(:call).never

        ResolveEditionJob.new.perform(0, 1)
      end

      test "enqueue_pending queues pass one for rows without findings and pass two for rows awaiting it" do
        waiting = goodreads_edition(title: "Another Book")
        @import.rows.create!(row_number: 2, goodreads_edition: waiting, replay_finding: :awaiting_full_pass)
        member = ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :member, status: :complete)
        member.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Member Only"))

        Sidekiq::Testing.fake! do
          assert_equal({first_pass: 1, full_pass: 1}, ResolveEditionJob.enqueue_pending)
          assert_equal [[@edition.id, 1], [waiting.id, 2]].sort, ResolveEditionJob.jobs.map { |job| job["args"] }.sort
          assert_equal %w[low serial], ResolveEditionJob.jobs.map { |job| job["queue"] }.sort
        end
      end
    end
  end
end
```

Run: `bin/rails test test/sidekiq/books/goodreads_replay/resolve_edition_job_test.rb`
Expected: FAIL. The generated job has no logic and `enqueue_pending` is undefined.

- [ ] **Step 4: Write the job**

Replace `web-app/app/sidekiq/books/goodreads_replay/resolve_edition_job.rb` with:

```ruby
# frozen_string_literal: true

module Books
  module GoodreadsReplay
    # One replay edition, one pass (Goodreads import spec §12.3).
    # - Pass one runs on low: there are ~188k editions, each at most one fast
    #   AI call.
    # - Pass two, with Open Library /resolve (5-6 s), runs one at a time on
    #   serial, and only for editions pass one could not settle.
    # Re-running is safe: pass one skips an edition whose replay rows all have
    # findings, and every write is an upsert of a finding or a verdict.
    class ResolveEditionJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 3

      BATCH = 1_000

      def self.replay_rows
        ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay)
          .where.not(goodreads_edition_id: nil)
      end

      def self.enqueue_pending
        first = replay_rows.where(replay_finding: nil).distinct.pluck(:goodreads_edition_id)
        full = replay_rows.replay_awaiting_full_pass.distinct.pluck(:goodreads_edition_id) - first
        first.each_slice(BATCH) { |ids| perform_bulk(ids.map { |id| [id, 1] }) }
        full.each_slice(BATCH) { |ids| set(queue: :serial).perform_bulk(ids.map { |id| [id, 2] }) }
        {first_pass: first.size, full_pass: full.size}
      end

      def perform(edition_id, pass = 1)
        edition = ::Books::GoodreadsEdition.find_by(id: edition_id)
        return unless edition
        return if pass == 1 && !self.class.replay_rows.where(goodreads_edition_id: edition.id, replay_finding: nil).exists?

        result = ::Services::Books::GoodreadsReplay::ResolveEdition.call(edition: edition, pass: pass)
        self.class.set(queue: :serial).perform_async(edition.id, 2) if pass == 1 && result.data[:needs_full_pass]
      end
    end
  end
end
```

Run: `bin/rails test test/sidekiq/books/goodreads_replay/resolve_edition_job_test.rb test/lib/services/books/goodreads_replay/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; `All is good!`

- [ ] **Step 5: Add the rake task, test first**

Add to the rake test:

```ruby
  test "resolve queues both passes and says how many" do
    Books::GoodreadsReplay::ResolveEditionJob.expects(:enqueue_pending).returns({first_pass: 12, full_pass: 3})

    assert_output(/queued 12 editions for pass one and 3 for the full pass/) { Rake::Task["books:goodreads_replay:resolve"].invoke }
  end
```

Run it. Expected: FAIL. Then add to the rake file:

```ruby
    desc "Queue replay editions: pass one (fast sources) for rows without a finding, pass two (with Open Library " \
      "/resolve, on serial) for rows awaiting it. Re-run until both counts are 0."
    task resolve: :environment do
      counts = Books::GoodreadsReplay::ResolveEditionJob.enqueue_pending
      puts "queued #{counts[:first_pass]} editions for pass one and #{counts[:full_pass]} for the full pass"
    end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/goodreads_replay/resolve_edition.rb app/sidekiq/books/goodreads_replay \
  lib/tasks/books/goodreads_replay.rake test/lib/services/books/goodreads_replay/resolve_edition_test.rb \
  test/sidekiq/books/goodreads_replay test/lib/tasks/books_goodreads_replay_rake_test.rb
git commit -m "Goodreads replay: resolve editions in two passes"
```

---
### Task 7: Applying a relink (§12.4)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/relink.rb`
- Test: `web-app/test/lib/services/books/goodreads_replay/apply/relink_test.rb`

**Interfaces:**
- Consumes: the relink payload (Task 5) and `Apply::StripIdentifier.change(book:, remove:, add:)` (Task 3).
- Produces: `Apply::Relink.call(verdict:)` returns `Result(data: {outcome: :applied | :noop, reason:})`.

Spec §12.4: "move this user's list items and review from A to B (on conflict keep B's, fill blank dates from A)". The steps:
- A list holding both books keeps B's item, filling its `completed_on` from A's when blank.
- A review on B wins. Otherwise A's review moves to B.
- Both books' review summaries are recalculated. `Review`'s `after_commit` recalculates only the book the review now points at.
- Public reading-goal pages showing A among the user's reads are purged, as `Books::Book::Merger` does.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_replay/apply/relink_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class RelinkTest < ActiveSupport::TestCase
          setup do
            @user = users(:regular_user)
            @read = user_lists(:regular_user_books_read)
            @favorites = user_lists(:regular_user_books_favorites)
            @from = books_books(:war_and_peace)
            @to = books_books(:of_mice_and_men)
            UserListItem.where(listable: [@from, @to]).delete_all
            Review.where(reviewable: [@from, @to]).delete_all
          end

          def verdict(user_id: @user.id, from: @from, to: @to, strip: [])
            ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:#{user_id}:book:#{from.id}:goodreads:1",
              decided_by: :ai, status: :approved,
              payload: {"user_id" => user_id, "from_book_id" => from.id, "to_book_id" => to.id, "goodreads_book_id" => 1,
                        "strip_identifiers" => strip})
          end

          test "moves the user's list items and review from the wrong book to the right one" do
            item = UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            review = Review.create!(user: @user, reviewable: @from, rating: 4)

            result = Relink.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal @to, item.reload.listable
            assert_equal @to, review.reload.reviewable
          end

          test "on a list holding both books, keeps the right one's item and fills its blank date from the wrong one's" do
            UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            kept = UserListItem.create!(user_list: @read, listable: @to)

            Relink.call(verdict: verdict)

            assert_equal [kept.id], UserListItem.where(user_list: @read, listable: [@from, @to]).pluck(:id)
            assert_equal Date.new(2025, 3, 1), kept.reload.completed_on
          end

          test "keeps a review the user already wrote on the right book" do
            Review.create!(user: @user, reviewable: @from, rating: 2)
            kept = Review.create!(user: @user, reviewable: @to, rating: 5)

            Relink.call(verdict: verdict)

            assert_equal [kept.id], Review.where(user: @user, reviewable: [@from, @to]).pluck(:id)
          end

          test "another user's items on the wrong book stay where they are" do
            other_list = ::Books::UserList.create!(user: users(:editor_user), name: "Read", list_type: :read)
            other = UserListItem.create!(user_list: other_list, listable: @from)
            UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict)

            assert_equal @from, other.reload.listable
          end

          test "moves the row's identifiers when the payload says legacy's identifier was wrong" do
            ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: "777")
            UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict(strip: [["books_work_goodreads_id", "777"]]))

            refute @from.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "777")
            assert @to.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "777")
          end

          test "applying twice does nothing the second time" do
            UserListItem.create!(user_list: @read, listable: @from)
            Relink.call(verdict: verdict)

            assert_equal :noop, Relink.call(verdict: verdict).data[:outcome]
          end

          test "a deleted user, or either book gone, is a no-op with a reason" do
            assert_equal "user 0 no longer exists", Relink.call(verdict: verdict(user_id: 0)).data[:reason]

            gone = verdict
            gone.payload["to_book_id"] = 0
            assert_equal "book 0 no longer exists", Relink.call(verdict: gone).data[:reason]
          end
        end
      end
    end
  end
end
```

Before running, check the `Books::UserList` creation attributes against `test/fixtures/user_lists.yml`. The fixtures use `list_type: 1 # read`. If `Books::UserList.create!` needs other attributes, add them and ledger the change.

Run: `bin/rails test test/lib/services/books/goodreads_replay/apply/relink_test.rb`
Expected: FAIL with `uninitialized constant ...Apply::Relink`.

- [ ] **Step 2: Write Apply::Relink**

`web-app/app/lib/services/books/goodreads_replay/apply/relink.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a relink verdict (Goodreads import spec §12.4): moves one
        # user's list items and review from the book legacy chose to the one the
        # resolver found.
        # - A list that already holds the right book keeps that item, with its
        #   blank completed_on filled from the wrong one's.
        # - A review the user already wrote on the right book wins.
        # - When legacy's identifier was the mistake, the row's identifiers move
        #   too.
        # Never touches another user's items. Idempotent: nothing left on the
        # wrong book is a no-op.
        class Relink
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            new(verdict.payload).call
          end

          def initialize(payload)
            @payload = payload
          end

          def call
            user = ::User.find_by(id: @payload["user_id"])
            return noop("user #{@payload["user_id"]} no longer exists") unless user

            from = ::Books::Book.find_by(id: @payload["from_book_id"])
            to = ::Books::Book.find_by(id: @payload["to_book_id"])
            missing = [[from, "from_book_id"], [to, "to_book_id"]].find { |book, _| book.nil? }
            return noop("book #{@payload[missing.last]} no longer exists") if missing

            items = ::UserListItem.joins(:user_list).where(user_lists: {user_id: user.id}, listable: from).to_a
            review = ::Review.find_by(user: user, reviewable: from)
            goal_urls = reading_goal_urls(user, items)
            changed = 0
            ActiveRecord::Base.transaction do
              items.each { |item| move_item(item, to) }
              move_review(review, user, to) if review
              strip = Array(@payload["strip_identifiers"])
              changed = StripIdentifier.change(book: from, remove: strip, add: []) + StripIdentifier.change(book: to, remove: [], add: strip)
            end
            return noop("already applied") if items.empty? && review.nil? && changed.zero?

            ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", from.id) if review
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", goal_urls) if goal_urls.any?
            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          private

          def move_item(item, to)
            kept = ::UserListItem.find_by(user_list_id: item.user_list_id, listable: to)
            if kept
              kept.update!(completed_on: item.completed_on) if kept.completed_on.nil? && item.completed_on
              item.destroy!
            else
              item.update!(listable: to)
            end
          end

          def move_review(review, user, to)
            ::Review.exists?(user: user, reviewable: to) ? review.destroy! : review.update!(reviewable: to)
          end

          # Public goal pages that list the wrong book among this user's reads,
          # captured before the move (as Books::Book::Merger does): the count is
          # unchanged, the book shown is not.
          def reading_goal_urls(user, items)
            items.select { |item| item.completed_on && item.user_list.is_a?(::Books::UserList) && item.user_list.read? }
              .flat_map do |item|
                user.books_reading_goals.public_goals
                  .where("starts_on <= ? AND ends_on >= ?", item.completed_on, item.completed_on).order(:id)
                  .flat_map do |goal|
                    count = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal).count
                    ::Services::Books::ReadingGoals::CachedUrls.call(goal: goal, count: count)
                  end
              end.uniq
          end

          def noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end
        end
      end
    end
  end
end
```

Check that `Books::UserList#read?` exists: the merger uses `.merge(::Books::UserList.read)`, so a `list_type` enum `read` exists. If the predicate has a prefix, use it and ledger the change.

Run: `bin/rails test test/lib/services/books/goodreads_replay/apply/relink_test.rb`
Expected: PASS, 7 runs.

- [ ] **Step 3: Commit**

```bash
git add app/lib/services/books/goodreads_replay/apply/relink.rb test/lib/services/books/goodreads_replay/apply/relink_test.rb
git commit -m "Goodreads replay: apply relink verdicts"
```

---
### Task 8: Author duplicates (§12.5, authors)

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/books/group_same_authors_task.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/find_author_duplicates.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/failed.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/merge_authors.rb`
- Test: `web-app/test/lib/services/ai/tasks/books/group_same_authors_task_test.rb`, `web-app/test/lib/services/books/goodreads_replay/find_author_duplicates_test.rb`, `web-app/test/lib/services/books/goodreads_replay/apply/merge_authors_test.rb`

**Interfaces:**
- Consumes: `Services::Ai::Tasks::BaseTask` and `Services::Books::Authors::AuthorProfile#line`.
- Consumes: `Books::Author::Merger.call(source:, target:)`, which returns `Result(success?, data, errors)`. It must not be called inside a transaction.
- Consumes: `DuplicateCandidate.not_duplicate?(item_type:, ids:)`.
- Produces: `Services::Ai::Tasks::Books::GroupSameAuthorsTask.new(author_lines:, parent: nil)`, whose `#call` returns `Services::Ai::Result`. Its `data` is `{groups: [{members: [Integer], confidence: "high"|"medium"|"low"}], reasoning: String}`. Members are 1-based, each group has at least two, and no member appears in two groups.
- Produces: `FindAuthorDuplicates.call(task_class: GroupSameAuthorsTask)` returns `Result(data: {tally: {checked:, too_large:, ai_failed:}, ai_calls: Integer})`.
- Produces: `merge_authors` verdicts with key `"authors:<min>:<max>"` and payload `{"source_id", "target_id", "names", "conflicts"}`.
- Produces: `Apply::Failed` (a StandardError) and `Apply::MergeAuthors.call(verdict:)`.

Spec §12.5 for authors: auto `merge_authors` only when all of these hold:
- the normalized names are equal (the group key);
- there is no birth or death year conflict (R7: both present and different);
- there is no conflicting external identifier (Open Library key, Wikidata QID, VIAF: both hold one and share none);
- a `fast` AI check of both authors' books says they are the same person, at `high` confidence (R6).

Everything else is proposed. One AI call per group (R5).

- [ ] **Step 1: Write the failing AI task tests**

`web-app/test/lib/services/ai/tasks/books/group_same_authors_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class GroupSameAuthorsTaskTest < ActiveSupport::TestCase
          setup do
            @lines = [
              "J.D. Robb | wrote: Naked in Death; Glory in Death",
              "J. D. Robb | wrote: Immortal in Death",
              "JD Robb | 1931–2019 | wrote: A Cookbook of Soups"
            ]
            @task = GroupSameAuthorsTask.new(author_lines: @lines)
          end

          test "runs on the fast role with json mode and needs no parent" do
            assert_equal :fast, @task.send(:task_role)
            assert_equal :openai, @task.send(:task_provider)
            assert_equal({type: "json_object"}, @task.send(:response_format))
          end

          test "the prompt numbers the authors and says a shared name proves nothing" do
            assert_includes @task.send(:user_prompt), "1. J.D. Robb | wrote: Naked in Death; Glory in Death"
            assert_includes @task.send(:user_prompt), "3. JD Robb"
            assert_includes @task.send(:system_message), "Matching names alone prove nothing"
            assert_includes @task.send(:system_message), "pen name"
          end

          test "keeps valid groups, drops out-of-range and repeated members, and groups of one" do
            response = {parsed: {reasoning: "Same books.", groups: [
              {members: [2, 1, 9], confidence: "high"}, {members: [1, 3], confidence: "low"}, {members: [3], confidence: "high"}
            ]}}

            result = @task.send(:process_and_persist, response)

            assert result.success?
            assert_equal [{members: [1, 2], confidence: "high"}], result.data[:groups]
            assert_equal "Same books.", result.data[:reasoning]
          end

          test "an unknown confidence is a failure" do
            result = @task.send(:process_and_persist, {parsed: {reasoning: "", groups: [{members: [1, 2], confidence: "sure"}]}})

            refute result.success?
            assert_match(/confidence/, result.error)
          end

          test "the response schema has groups of members with a confidence, and reasoning" do
            assert_equal %w[groups reasoning], GroupSameAuthorsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[members confidence], GroupSameAuthorsTask::Group.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/ai/tasks/books/group_same_authors_task_test.rb`
Expected: FAIL with `uninitialized constant ...GroupSameAuthorsTask`.

- [ ] **Step 2: Write the task**

`web-app/app/lib/services/ai/tasks/books/group_same_authors_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      module Books
        # One structured call over a group of author records that share a
        # normalized name (Goodreads import spec §12.5): which of them are the
        # same person? The legacy app created many authors by name alone, so a
        # group can be one person entered many times, several different people,
        # or a mix. Each line comes from AuthorProfile#line, plus identifiers.
        class GroupSameAuthorsTask < BaseTask
          VALID_CONFIDENCE = %w[high medium low].freeze

          attr_reader :author_lines

          def initialize(author_lines:, parent: nil, provider: nil, model: nil)
            @author_lines = author_lines
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :fast

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You are cleaning up an author catalog. You are given a numbered list of author records that share a name.
              Some may be one person entered more than once; others are different people who happen to share the name.

              Group the records that are the same person. Leave a record out of every group when it is a different person from all the others.
              - Judge by their books, life dates, other names and identifiers. Matching names alone prove nothing.
              - Two people with the same name are different authors unless their dates or their books connect them.
              - A pen name is a separate author from the person who uses it, and from other people using the same pen name.
              - Different identifiers of the same kind (two different Wikidata ids) mean different people.
              - A publisher, company or collective is the same entity only as the same organization.
              For each group give confidence: "high" when the books or dates make it unambiguous, "medium" when it is likely, "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Authors:"]
            author_lines.each_with_index { |line, index| lines << "#{index + 1}. #{line}" }
            lines << ""
            lines << "Answer with groups (each with its members' numbers and a confidence) and reasoning."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            groups = Array(data[:groups])
            invalid = groups.map { |group| value(group, :confidence) }.reject { |confidence| VALID_CONFIDENCE.include?(confidence) }
            return failure("Unexpected confidence value: #{invalid.first.inspect}") if invalid.any?

            Services::Ai::Result.new(success: true, data: {groups: clean(groups), reasoning: data[:reasoning].to_s}, ai_chat: chat)
          end

          # Members in range, each in at most one group (the first that names
          # it), groups of two or more.
          def clean(groups)
            taken = Set.new
            groups.filter_map do |group|
              members = Array(value(group, :members)).select { |m| m.is_a?(Integer) && m.between?(1, author_lines.size) }
                .uniq.sort.reject { |m| taken.include?(m) }
              next if members.size < 2

              taken.merge(members)
              {members: members, confidence: value(group, :confidence)}
            end
          end

          def value(group, key)
            group.respond_to?(key) ? group.public_send(key) : (group[key] || group[key.to_s])
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Group < OpenAI::BaseModel
            required :members, OpenAI::ArrayOf[Integer], doc: "Numbers of the records that are one and the same person"
            required :confidence, String, doc: "high, medium or low"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :groups, OpenAI::ArrayOf[Group], doc: "Groups of records that are the same person; empty when all are different people"
            required :reasoning, String, doc: "One or two sentences"
          end
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/ai/tasks/books/group_same_authors_task_test.rb`
Expected: PASS, 5 runs. In the "keeps valid groups" case, the first group keeps `[1, 2]`; the second loses 1 to it, leaving `[3]`, which is dropped; the third is a group of one.

- [ ] **Step 3: Write the failing finder and apply tests**

`web-app/test/lib/services/books/goodreads_replay/find_author_duplicates_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FindAuthorDuplicatesTest < ActiveSupport::TestCase
        # Stands in for GroupSameAuthorsTask: records each call's lines, answers
        # with the given groups.
        class FakeTask
          class << self
            attr_accessor :groups, :success, :calls
          end

          def initialize(author_lines:, parent:)
            self.class.calls << author_lines
          end

          def call
            Services::Ai::Result.new(success: self.class.success, data: {groups: self.class.groups, reasoning: "test"},
              error: (self.class.success ? nil : "boom"), ai_chat: nil)
          end
        end

        setup do
          FakeTask.calls = []
          FakeTask.success = true
          FakeTask.groups = [{members: [1, 2], confidence: "high"}]
          @first = ::Books::Author.create!(name: "J.D. Quillfeather")
          @second = ::Books::Author.create!(name: "J. D. Quillfeather")
          ::Books::BookAuthor.create!(book: books_books(:war_and_peace), author: @second)
        end

        def find
          FindAuthorDuplicates.call(task_class: FakeTask)
        end

        test "sends each name group once, with names that differ only in punctuation and spacing grouped together" do
          ::Books::Author.create!(name: "Someone Unique Entirely")

          result = find

          quill = FakeTask.calls.select { |lines| lines.any? { |line| line.include?("Quillfeather") } }
          assert_equal 1, quill.size
          assert_equal 2, quill.first.size
          assert_equal result.data[:ai_calls], FakeTask.calls.size
          refute(FakeTask.calls.flatten.any? { |line| line.include?("Someone Unique Entirely") })
        end

        test "a high-confidence group with no conflicts is an approved merge into the author with more books" do
          find

          verdict = ::Books::RepairVerdict.merge_authors.find_by!(subject_key: "authors:#{[@first.id, @second.id].minmax.join(":")}")
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_ai?
          assert_equal [@first.id, @second.id], [verdict.payload["source_id"], verdict.payload["target_id"]]
          assert_equal [], verdict.payload["conflicts"]
        end

        test "different birth years make it a proposal" do
          @first.update!(birth_year: 1950)
          @second.update!(birth_year: 1951)

          find

          verdict = ::Books::RepairVerdict.merge_authors.sole
          assert_predicate verdict, :proposed?
          assert_equal ["birth years differ (1950 vs 1951)"], verdict.payload["conflicts"]
        end

        test "different Wikidata ids make it a proposal" do
          ::Identifier.create!(identifiable: @first, identifier_type: :books_author_wikidata_qid, value: "Q1")
          ::Identifier.create!(identifiable: @second, identifier_type: :books_author_wikidata_qid, value: "Q2")

          find

          assert_equal ["different books_author_wikidata_qid"], ::Books::RepairVerdict.merge_authors.sole.payload["conflicts"]
          assert_predicate ::Books::RepairVerdict.merge_authors.sole, :proposed?
        end

        test "a medium-confidence group is a proposal" do
          FakeTask.groups = [{members: [1, 2], confidence: "medium"}]

          find

          assert_predicate ::Books::RepairVerdict.merge_authors.sole, :proposed?
        end

        test "a pair an admin marked not a duplicate is not proposed again" do
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Author", ids: [@first.id, @second.id], source: :human)
          ::DuplicateCandidate.sole.update!(status: :not_duplicate)

          find

          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "a group over the limit is not sent" do
          Rails.configuration.x.goodreads_replay.stubs(:max_author_group).returns(1)

          result = find

          assert_empty FakeTask.calls
          assert_operator result.data[:tally][:too_large], :>=, 1
        end

        test "a failed AI call records nothing and is counted" do
          FakeTask.success = false

          result = find

          assert_equal 0, ::Books::RepairVerdict.count
          assert_operator result.data[:tally][:ai_failed], :>=, 1
        end

        test "finds only; merges nothing" do
          assert_no_difference -> { ::Books::Author.count } { find }
        end
      end
    end
  end
end
```

The fixtures may already hold an author group under the loose key (for example two "Stephen King"-like names). If one exists, the fake answers `[1, 2]` for it too. The assertions above pick out the Quillfeather group explicitly, so they hold either way. The "different birth years" and "Wikidata" tests use `.sole` on `merge_authors`. If a fixture group yields a verdict as well, scope those lookups by the Quillfeather `subject_key` (as the high-confidence test does) and ledger the change.

`web-app/test/lib/services/books/goodreads_replay/apply/merge_authors_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MergeAuthorsTest < ActiveSupport::TestCase
          setup do
            @source = ::Books::Author.create!(name: "Ann Example")
            @target = ::Books::Author.create!(name: "Ann  Example")
          end

          def verdict(source_id: @source.id, target_id: @target.id)
            ::Books::RepairVerdict.create!(kind: :merge_authors, subject_key: "authors:#{source_id}:#{target_id}",
              decided_by: :ai, status: :approved, payload: {"source_id" => source_id, "target_id" => target_id})
          end

          test "merges the source into the target through the author merger" do
            ::Books::Author::Merger.expects(:call).with(source: @source, target: @target)
              .returns(::Books::Author::Merger::Result.new(success?: true, data: @target, errors: []))

            assert_equal :applied, MergeAuthors.call(verdict: verdict).data[:outcome]
          end

          test "a source already merged away is a no-op" do
            ::Books::Author::Merger.expects(:call).never

            result = MergeAuthors.call(verdict: verdict(source_id: 0))

            assert_equal :noop, result.data[:outcome]
            assert_equal "author 0 no longer exists", result.data[:reason]
          end

          test "a merger failure raises with its errors" do
            ::Books::Author::Merger.stubs(:call).returns(::Books::Author::Merger::Result.new(success?: false, data: nil, errors: ["nope"]))

            error = assert_raises(Failed) { MergeAuthors.call(verdict: verdict) }
            assert_equal "nope", error.message
          end
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/find_author_duplicates_test.rb test/lib/services/books/goodreads_replay/apply/merge_authors_test.rb`
Expected: FAIL. The constants are undefined.

- [ ] **Step 4: Write FindAuthorDuplicates, Apply::Failed and Apply::MergeAuthors**

`web-app/app/lib/services/books/goodreads_replay/find_author_duplicates.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.5, authors. Covers every author whose
      # normalized name another author shares, import-created or not: the legacy
      # add-book modal made authors with find_or_create_by!(name:) too.
      #
      # The normalized name is lowercase with everything but letters and digits
      # removed, so "J.D. Vance" and "J. D. Vance" are one group. Each group is
      # one fast AI call that clusters it into people (GroupSameAuthorsTask).
      # Each clustered pair becomes a merge_authors verdict, merging into the
      # author ranked first, then the one with the most books, then the oldest.
      #
      # A pair is approved on its own only when all three hold:
      # - the AI is highly confident;
      # - no birth or death year conflicts (both present and different);
      # - no external identifier conflicts (both hold one of a kind, and they
      #   share none).
      # The rest are proposed. A pair an admin marked not a duplicate is skipped.
      # Records findings only; merges nothing.
      class FindAuthorDuplicates
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KEY_SQL = "regexp_replace(lower(books_authors.name), '[^[:alnum:]]+', '', 'g')"
        IDENTIFIER_TYPES = %w[books_author_openlibrary_id books_author_wikidata_qid books_author_viaf].freeze

        def self.call(task_class: ::Services::Ai::Tasks::Books::GroupSameAuthorsTask)
          new(task_class: task_class).call
        end

        def initialize(task_class:)
          @task_class = task_class
          @ai_calls = 0
        end

        def call
          tally = Hash.new(0)
          group_keys.each { |key| tally[check(key)] += 1 }
          Result.new(success?: true, data: {tally: tally.to_h, ai_calls: @ai_calls}, errors: [])
        end

        private

        def group_keys
          ::Books::Author.where.not(Arel.sql("#{KEY_SQL} = ''")).group(Arel.sql(KEY_SQL)).having("count(*) > 1")
            .order(Arel.sql(KEY_SQL)).pluck(Arel.sql(KEY_SQL))
        end

        def check(key)
          authors = ::Books::Author.where("#{KEY_SQL} = ?", key).includes(:identifiers).order(:id).to_a
          return :too_large if authors.size > Rails.configuration.x.goodreads_replay.max_author_group

          @ai_calls += 1
          result = @task_class.new(author_lines: authors.map { |author| line(author) }, parent: authors.first).call
          return :ai_failed unless result.success?

          result.data[:groups].each { |group| record(group.fetch(:members).map { |n| authors[n - 1] }, group.fetch(:confidence), result.ai_chat) }
          :checked
        end

        def line(author)
          parts = [::Services::Books::Authors::AuthorProfile.new(author).line]
          parts << "kind: #{author.kind}" if author.kind.present? && author.kind != "person"
          ids = author.identifiers.select { |i| IDENTIFIER_TYPES.include?(i.identifier_type) }
            .map { |i| "#{i.identifier_type.delete_prefix("books_author_")} #{i.value}" }
          parts << "ids: #{ids.join(", ")}" if ids.any?
          parts.join(" | ")
        end

        def record(members, confidence, ai_chat)
          target = preferred(members)
          (members - [target]).each do |source|
            next if ::DuplicateCandidate.not_duplicate?(item_type: "Books::Author", ids: [source.id, target.id])

            conflicts = conflicts(source, target)
            RecordVerdict.call(
              kind: :merge_authors, subject_key: "authors:#{[source.id, target.id].minmax.join(":")}",
              payload: {source_id: source.id, target_id: target.id, names: [source.name, target.name], conflicts: conflicts},
              decided_by: :ai, confidence: confidence, ai_chat_id: ai_chat&.id,
              reason: conflicts.empty? ? "same person, by the AI's check of both authors' books" : "the AI says same person, but #{conflicts.join("; ")}",
              auto: conflicts.empty? && confidence == "high"
            )
          end
        end

        def preferred(members)
          ids = members.map(&:id)
          configuration = ::Books::Authors::RankingConfiguration.default_primary
          ranks = configuration ? ::RankedItem.where(ranking_configuration_id: configuration.id, item_type: "Books::Author", item_id: ids).pluck(:item_id, :rank).to_h : {}
          books = ::Books::BookAuthor.where(author_id: ids).group(:author_id).count
          members.min_by { |author| [ranks.key?(author.id) ? 0 : 1, ranks[author.id].to_i, -books.fetch(author.id, 0), author.id] }
        end

        def conflicts(a, b)
          years = %i[birth_year death_year].filter_map do |field|
            "#{field.to_s.tr("_", " ")}s differ (#{a[field]} vs #{b[field]})" if a[field] && b[field] && a[field] != b[field]
          end
          identifiers = IDENTIFIER_TYPES.filter_map do |type|
            held_a = values(a, type)
            held_b = values(b, type)
            "different #{type}" if held_a.any? && held_b.any? && (held_a & held_b).empty?
          end
          years + identifiers
        end

        def values(author, type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end
      end
    end
  end
end
```

`web-app/app/lib/services/books/goodreads_replay/apply/failed.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # A verdict that could not be applied; ApplyVerdicts records the message on it.
        class Failed < StandardError; end
      end
    end
  end
end
```

`web-app/app/lib/services/books/goodreads_replay/apply/merge_authors.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a merge_authors verdict through Books::Author::Merger, which
        # moves everything and reindexes. An author already merged away (or
        # deleted) is a no-op: the next pass re-derives the pair from what is
        # left.
        class MergeAuthors
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            source = ::Books::Author.find_by(id: verdict.payload["source_id"])
            return noop("author #{verdict.payload["source_id"]} no longer exists") unless source

            target = ::Books::Author.find_by(id: verdict.payload["target_id"])
            return noop("author #{verdict.payload["target_id"]} no longer exists") unless target

            result = ::Books::Author::Merger.call(source: source, target: target)
            raise Failed, result.errors.join("; ") unless result.success?

            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :noop
        end
      end
    end
  end
end
```

Check that `Books::Authors::RankingConfiguration` is the author ranking class: `grep -n "default_primary" app/sidekiq/books/calculate_author_rankings_job.rb`. If the class name differs, use the job's.

Run: `bin/rails test test/lib/services/ai/tasks/books/ test/lib/services/books/goodreads_replay/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; `All is good!`

- [ ] **Step 5: Commit** (Task 9 adds the `duplicates` rake task for both kinds)

```bash
git add app/lib/services/ai/tasks/books/group_same_authors_task.rb app/lib/services/books/goodreads_replay \
  test/lib/services/ai/tasks/books/group_same_authors_task_test.rb test/lib/services/books/goodreads_replay
git commit -m "Goodreads replay: author duplicates by one AI check per name group"
```

---
### Task 9: Book duplicates (§12.5, books)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/find_book_duplicates.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/merge_books.rb`
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake` (add `duplicates`)
- Test: `web-app/test/lib/services/books/goodreads_replay/find_book_duplicates_test.rb`, `web-app/test/lib/services/books/goodreads_replay/apply/merge_books_test.rb`, the rake test

**Interfaces:**
- Consumes: pending `DuplicateCandidate` pairs for `Books::Book`. The replay's finder runs flag them through AI `same_entity_groups` and identifier collisions.
- Consumes: `Books::Book::Merger.call(source:, target:)`, which must not run inside a transaction, and `Apply::Failed` (Task 8).
- Produces: `FindBookDuplicates.call` returns `Result(data: {recorded: Integer})`.
- Produces: `merge_books` verdicts with key `"books:<item_a_id>:<item_b_id>"` and payload `{"source_id", "target_id", "shared", "duplicate_candidate_id"}`, recorded with `decided_by: :rule`, `confidence: :certain`, `auto: true`.
- Produces: `Apply::MergeBooks.call(verdict:)`.

Spec §12.5 for books: "Pairs the finder flags go into the existing `DuplicateCandidate` queue. Auto `merge_books` only when the normalized titles are equal, the author id sets are identical, and the two books share a corroborated identifier." With equal titles and identical authors, a shared identifier is corroborated by construction: the record holding it agrees with it on both title and authors.
- Every pending pair is checked, not only this pass's. The rule is strict, so a superset is safe.
- A pair that fails the rule stays in the duplicates queue, where it already is. It gets no verdict.
- The target is the book ranked first under the default books configuration, then the one on the most curated lists, then the oldest.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_replay/find_book_duplicates_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FindBookDuplicatesTest < ActiveSupport::TestCase
        setup do
          @author = books_authors(:tolstoy)
          @older = book("Hadji Murat")
          @newer = book("Hadji  Murat")
          ::Identifier.create!(identifiable: @older, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Identifier.create!(identifiable: @newer, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@older.id, @newer.id], source: :ai)
        end

        def book(title, authors: [@author])
          ::Books::Book.create!(title: title).tap do |created|
            authors.each { |author| ::Books::BookAuthor.create!(book: created, author: author) }
          end
        end

        test "same title, same authors and a shared identifier is an approved merge into the older book" do
          assert_equal 1, FindBookDuplicates.call.data[:recorded]

          verdict = ::Books::RepairVerdict.merge_books.sole
          assert_equal "books:#{[@older.id, @newer.id].min}:#{[@older.id, @newer.id].max}", verdict.subject_key
          assert_equal [@newer.id, @older.id], [verdict.payload["source_id"], verdict.payload["target_id"]]
          assert_equal [["books_work_isbn13", "9780812969849"]], verdict.payload["shared"]
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_rule?
        end

        test "no shared identifier, a different author or a different title leaves the pair to the duplicates queue" do
          ::Identifier.where(identifiable: @newer).delete_all
          assert_equal 0, FindBookDuplicates.call.data[:recorded]

          other = book("Hadji Murat", authors: [books_authors(:king)])
          ::Identifier.create!(identifiable: other, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@older.id, other.id], source: :ai)
          renamed = book("Hadji Murad")
          ::Identifier.create!(identifiable: renamed, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@older.id, renamed.id], source: :ai)

          assert_equal 0, FindBookDuplicates.call.data[:recorded]
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "a dismissed or merged pair is not checked" do
          ::DuplicateCandidate.sole.update!(status: :not_duplicate)

          assert_equal 0, FindBookDuplicates.call.data[:recorded]
        end

        test "finds only; merges nothing" do
          assert_no_difference -> { ::Books::Book.count } { FindBookDuplicates.call }
        end
      end
    end
  end
end
```

`Books::Book.create!(title:)` must satisfy the model's validations. If it needs more attributes, copy them from the minimal `create!` an existing books test uses (`grep -rn "Books::Book.create!" test | head -3`) and ledger the change.

`web-app/test/lib/services/books/goodreads_replay/apply/merge_books_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MergeBooksTest < ActiveSupport::TestCase
          setup do
            @source = books_books(:cannery_row)
            @target = books_books(:of_mice_and_men)
          end

          def verdict(source_id: @source.id, target_id: @target.id)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{source_id}:#{target_id}",
              decided_by: :rule, status: :approved, payload: {"source_id" => source_id, "target_id" => target_id})
          end

          test "merges through the book merger" do
            ::Books::Book::Merger.expects(:call).with(source: @source, target: @target)
              .returns(::Books::Book::Merger::Result.new(success?: true, data: @target, errors: []))

            assert_equal :applied, MergeBooks.call(verdict: verdict).data[:outcome]
          end

          test "either book gone is a no-op" do
            ::Books::Book::Merger.expects(:call).never

            assert_equal "book 0 no longer exists", MergeBooks.call(verdict: verdict(source_id: 0)).data[:reason]
            assert_equal "book 0 no longer exists", MergeBooks.call(verdict: verdict(target_id: 0)).data[:reason]
          end

          test "a merger failure raises with its errors" do
            ::Books::Book::Merger.stubs(:call).returns(::Books::Book::Merger::Result.new(success?: false, data: nil, errors: ["locked"]))

            assert_raises(Failed) { MergeBooks.call(verdict: verdict) }
          end
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/find_book_duplicates_test.rb test/lib/services/books/goodreads_replay/apply/merge_books_test.rb`
Expected: FAIL. The constants are undefined.

- [ ] **Step 2: Write FindBookDuplicates and Apply::MergeBooks**

`web-app/app/lib/services/books/goodreads_replay/find_book_duplicates.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.5, books. The replay's finder runs flag
      # suspected pairs into the duplicates queue. A pending pair becomes an
      # approved merge_books verdict only when all three hold:
      # - the normalized titles are equal;
      # - the author id sets are identical (and not empty);
      # - the two books share an identifier. With the same title and the same
      #   authors, that identifier is corroborated by construction.
      # The book kept is the one ranked first under the default configuration,
      # then the one on more curated lists, then the oldest. Every other pair
      # stays in the duplicates queue for an admin. Records findings only.
      class FindBookDuplicates
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        IDENTIFIER_TYPES = %w[books_work_isbn13 books_work_isbn10 books_work_goodreads_id books_work_asin books_work_openlibrary_id].freeze

        def self.call
          new.call
        end

        def call
          recorded = 0
          ::DuplicateCandidate.where(item_type: "Books::Book").pending.find_each do |pair|
            recorded += 1 if check(pair)
          end
          Result.new(success?: true, data: {recorded: recorded}, errors: [])
        end

        private

        def check(pair)
          books = ::Books::Book.where(id: [pair.item_a_id, pair.item_b_id]).includes(:identifiers, :book_authors).to_a
          return false unless books.size == 2

          a, b = books
          return false unless normalize(a.title) == normalize(b.title)

          authors = books.map { |book| book.book_authors.map(&:author_id).sort }
          return false if authors.first.empty? || authors.first != authors.last

          shared = identifiers(a) & identifiers(b)
          return false if shared.empty?

          target = preferred(books)
          source = (books - [target]).first
          RecordVerdict.call(
            kind: :merge_books, subject_key: "books:#{pair.item_a_id}:#{pair.item_b_id}",
            payload: {source_id: source.id, target_id: target.id, shared: shared.sort, duplicate_candidate_id: pair.id},
            decided_by: :rule, confidence: :certain, auto: true,
            reason: "same title and authors, and both hold #{shared.map { |type, value| "#{type} #{value}" }.join(", ")}"
          )
          true
        end

        def identifiers(book)
          book.identifiers.select { |identifier| IDENTIFIER_TYPES.include?(identifier.identifier_type) }
            .map { |identifier| [identifier.identifier_type, identifier.value] }
        end

        def preferred(books)
          ids = books.map(&:id)
          configuration = ::Books::RankingConfiguration.default_primary
          ranks = configuration ? ::RankedItem.where(ranking_configuration_id: configuration.id, item_type: "Books::Book", item_id: ids).pluck(:item_id, :rank).to_h : {}
          lists = ::ListItem.joins(:list).where(listable_type: "Books::Book", listable_id: ids, lists: {auto_generated_kind: nil})
            .group(:listable_id).count
          books.min_by { |book| [ranks.key?(book.id) ? 0 : 1, ranks[book.id].to_i, -lists.fetch(book.id, 0), book.id] }
        end

        def normalize(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
        end
      end
    end
  end
end
```

`web-app/app/lib/services/books/goodreads_replay/apply/merge_books.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a merge_books verdict through Books::Book::Merger, which moves
        # list items, reviews, identifiers and editions, then reindexes and
        # recalculates rankings. Either book already gone is a no-op.
        class MergeBooks
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            source = ::Books::Book.find_by(id: verdict.payload["source_id"])
            return noop("book #{verdict.payload["source_id"]} no longer exists") unless source

            target = ::Books::Book.find_by(id: verdict.payload["target_id"])
            return noop("book #{verdict.payload["target_id"]} no longer exists") unless target

            result = ::Books::Book::Merger.call(source: source, target: target)
            raise Failed, result.errors.join("; ") unless result.success?

            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :noop
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/`
Expected: PASS.

- [ ] **Step 3: Add the `duplicates` rake task, test first**

Add to the rake test:

```ruby
  test "duplicates runs the author check, then the book rule, and reports both" do
    sequence = sequence("duplicates")
    REPLAY::FindAuthorDuplicates.expects(:call).in_sequence(sequence).returns(result(tally: {checked: 3188}, ai_calls: 3188))
    REPLAY::FindBookDuplicates.expects(:call).in_sequence(sequence).returns(result(recorded: 41))

    assert_output(/author name groups: checked 3188 \(3188 AI calls\)\nbook pairs: 41 merge verdicts/) do
      Rake::Task["books:goodreads_replay:duplicates"].invoke
    end
  end
```

Run it. Expected: FAIL. Then add to the rake file:

```ruby
    desc "Record merge verdicts: one AI check per author name group, then the rule over pending book pairs. " \
      "Run after the resolve jobs finish."
    task duplicates: :environment do
      authors = Services::Books::GoodreadsReplay::FindAuthorDuplicates.call.data
      puts "author name groups: #{tally.call(authors[:tally])} (#{authors[:ai_calls]} AI calls)"
      puts "book pairs: #{Services::Books::GoodreadsReplay::FindBookDuplicates.call.data[:recorded]} merge verdicts"
    end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/lib/services/books/goodreads_replay lib/tasks/books/goodreads_replay.rake \
  test/lib/services/books/goodreads_replay test/lib/tasks/books_goodreads_replay_rake_test.rb
git commit -m "Goodreads replay: book duplicates by rule, and the duplicates rake"
```

---
### Task 10: Junk goes provisional (§12.6)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/find_junk.rb`
- Create: `web-app/app/lib/services/books/goodreads_replay/apply/mark_provisional.rb`
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake` (add `junk`)
- Test: `web-app/test/lib/services/books/goodreads_replay/find_junk_test.rb`, `web-app/test/lib/services/books/goodreads_replay/apply/mark_provisional_test.rb`, the rake test

**Interfaces:**
- Consumes: approved `relink` verdicts (Task 5) and `RecordVerdict`.
- Produces: `FindJunk.call` returns `Result(data: {authorless: Integer, orphaned: Integer})`.
- Produces: `mark_provisional` verdicts with key `"book:<id>"` and payload `{"book_id", "reason" => "authorless" | "no support after relinks", …}`, recorded with `decided_by: :rule` and `confidence: :certain`.
- Produces: `Apply::MarkProvisional.call(verdict:)` and `.revert(verdict:)`. Both return `data[:ranking_configuration_ids]`, which `ApplyVerdicts` (Task 11) queues once.

Spec §12.6: auto `mark_provisional` (reversible) for two kinds of book:
- **Authorless fallback books.** An authorless book on a curated list is **proposed**, not auto (R3), so no curated list page loses a book unasked.
- **"Books left with no supporting replay row after relinks, no curated-list item, and no other user's list item."** A book qualifies when every user who has it on a list or reviewed it is a user an approved relink moves off it, and it is on no curated list.

Carried from increment 2: provisional books are filtered at **ranking calculation**. `mark_provisional` therefore queues a books ranking recalculation for every configuration that ranked the book, plus the default one, whose job cascades to the author rankings. The flag is set with `update!`, never `update_all`, so `SearchIndexable`'s `after_commit` queues the reindex.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_replay/find_junk_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FindJunkTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @orphan = ::Books::Book.create!(title: "Wrongly Matched Book")
          ::Books::BookAuthor.create!(book: @orphan, author: books_authors(:king))
          @item = UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @orphan)
        end

        def approved_relink(user: @user, from: @orphan)
          ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:#{user.id}:book:#{from.id}:goodreads:1",
            decided_by: :ai, status: :approved, reviewed_at: Time.current,
            payload: {"user_id" => user.id, "from_book_id" => from.id, "to_book_id" => books_books(:got).id})
        end

        def verdict_for(book)
          ::Books::RepairVerdict.mark_provisional.find_by(subject_key: "book:#{book.id}")
        end

        test "an authorless book on no curated list is marked provisional on its own" do
          authorless = ::Books::Book.create!(title: "Nobody Wrote This")

          FindJunk.call

          verdict = verdict_for(authorless)
          assert_predicate verdict, :approved?
          assert_equal "authorless", verdict.payload["reason"]
        end

        test "an authorless book on a curated list is only proposed, so no list page loses it unasked" do
          authorless = ::Books::Book.create!(title: "Nobody Wrote This Either")
          list = lists(:books_list)
          ListItem.create!(list: list, listable: authorless, position: 99)

          FindJunk.call

          verdict = verdict_for(authorless)
          assert_predicate verdict, :proposed?
          assert_equal [list.id], verdict.payload["curated_list_ids"]
        end

        test "a book every holder is relinked away from, on no curated list, is marked provisional" do
          approved_relink

          FindJunk.call

          verdict = verdict_for(@orphan)
          assert_predicate verdict, :approved?
          assert_equal "no support after relinks", verdict.payload["reason"]
        end

        test "another user's list item or review keeps the book" do
          approved_relink
          other_list = ::Books::UserList.create!(user: users(:editor_user), name: "Read", list_type: :read)
          UserListItem.create!(user_list: other_list, listable: @orphan)

          FindJunk.call

          assert_nil verdict_for(@orphan)
        end

        test "a proposed relink is not enough" do
          approved_relink.update!(status: :proposed, reviewed_at: nil)

          FindJunk.call

          assert_nil verdict_for(@orphan)
        end

        test "finds only; flags nothing provisional" do
          ::Books::Book.create!(title: "Nobody Wrote This")
          approved_relink

          assert_no_difference -> { ::Books::Book.where(provisional: true).count } { FindJunk.call }
        end
      end
    end
  end
end
```

Before running, check that `lists(:books_list)` is a `Books::List` without `auto_generated_kind`: `sed -n '/^books_list:/,/^$/p' test/fixtures/lists.yml`. If it is generated, use another books list fixture or create a `Books::List` in the test.

`web-app/test/lib/services/books/goodreads_replay/apply/mark_provisional_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MarkProvisionalTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @verdict = ::Books::RepairVerdict.create!(kind: :mark_provisional, subject_key: "book:#{@book.id}",
              decided_by: :rule, status: :approved, payload: {"book_id" => @book.id, "reason" => "authorless"})
          end

          test "flags the book, queues its reindex, and names the rankings to recalculate" do
            assert_difference -> { SearchIndexRequest.where(parent: @book).count }, 1 do
              @result = MarkProvisional.call(verdict: @verdict)
            end

            assert_equal :applied, @result.data[:outcome]
            assert @book.reload.provisional
            default = ::Books::RankingConfiguration.default_primary
            assert_includes @result.data[:ranking_configuration_ids], default.id if default
          end

          test "a book already provisional is a no-op" do
            @book.update!(provisional: true)

            assert_equal :noop, MarkProvisional.call(verdict: @verdict).data[:outcome]
          end

          test "revert clears the flag it set" do
            MarkProvisional.call(verdict: @verdict)

            result = MarkProvisional.revert(verdict: @verdict)

            assert_equal :applied, result.data[:outcome]
            refute @book.reload.provisional
          end

          test "a deleted book is a no-op either way" do
            @verdict.payload["book_id"] = 0

            assert_equal "book 0 no longer exists", MarkProvisional.call(verdict: @verdict).data[:reason]
            assert_equal "book 0 no longer exists", MarkProvisional.revert(verdict: @verdict).data[:reason]
          end
        end
      end
    end
  end
end
```

If `Services::BooksMigration.search_indexing_suppressed?` is true in test, the reindex assertion fails for that reason. Check `app/models/concerns/search_indexable.rb`. If that is the cause, assert on the flag and the configuration ids only, and ledger it.

Run: `bin/rails test test/lib/services/books/goodreads_replay/find_junk_test.rb test/lib/services/books/goodreads_replay/apply/mark_provisional_test.rb`
Expected: FAIL. The constants are undefined.

- [ ] **Step 2: Write FindJunk and Apply::MarkProvisional**

`web-app/app/lib/services/books/goodreads_replay/find_junk.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.6: clear junk goes provisional, hidden from
      # every public surface until an admin decides. Two kinds of book qualify:
      # - An authorless book: legacy root cause 5, a bare book no
      #   author-required search can find. On a curated list it is only
      #   proposed, so no list page loses a book unasked. Curated list pages are
      #   not filtered by provisional.
      # - A book every holder has been relinked away from (approved relinks),
      #   with no curated-list item and no other user's list item or review.
      # Records findings only; Apply::MarkProvisional sets the flag.
      class FindJunk
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call
          new.call
        end

        def call
          Result.new(success?: true, data: {authorless: authorless, orphaned: orphaned}, errors: [])
        end

        private

        def authorless
          count = 0
          ::Books::Book.where(provisional: false).where.not(id: ::Books::BookAuthor.select(:book_id)).find_each do |book|
            lists = curated_list_ids(book)
            RecordVerdict.call(
              kind: :mark_provisional, subject_key: "book:#{book.id}",
              payload: {book_id: book.id, reason: "authorless", curated_list_ids: lists},
              decided_by: :rule, confidence: :certain, auto: lists.empty?,
              reason: lists.empty? ? "authorless, on no curated list" : "authorless, but on curated lists #{lists.join(", ")}"
            )
            count += 1
          end
          count
        end

        def orphaned
          count = 0
          ::Books::RepairVerdict.relink.approved.to_a.group_by { |verdict| verdict.payload["from_book_id"] }.each do |book_id, verdicts|
            book = ::Books::Book.find_by(id: book_id, provisional: false)
            next unless book

            moved = verdicts.map { |verdict| verdict.payload["user_id"] }.uniq.sort
            next if curated_list_ids(book).any?
            next if ::UserListItem.joins(:user_list).where(listable: book).where.not(user_lists: {user_id: moved}).exists?
            next if ::Review.where(reviewable: book).where.not(user_id: moved).exists?

            RecordVerdict.call(
              kind: :mark_provisional, subject_key: "book:#{book.id}",
              payload: {book_id: book.id, reason: "no support after relinks", relinked_user_ids: moved},
              decided_by: :rule, confidence: :certain, auto: true,
              reason: "every user who had it is relinked away, and no curated list or other user has it"
            )
            count += 1
          end
          count
        end

        def curated_list_ids(book)
          ::ListItem.joins(:list).where(listable: book, lists: {auto_generated_kind: nil}).distinct.order(:list_id).pluck(:list_id)
        end
      end
    end
  end
end
```

`web-app/app/lib/services/books/goodreads_replay/apply/mark_provisional.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies (or, from the admin queue, reverts) a mark_provisional verdict.
        # Uses update!, never update_all, so SearchIndexable's after_commit
        # queues the reindex and public search drops the book. Rankings filter
        # provisional books when they are calculated, so the result names the
        # configurations to recalculate: those that ranked the book, plus the
        # default one, whose job cascades to the author rankings. ApplyVerdicts
        # queues each configuration once per run.
        class MarkProvisional
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            set(verdict, true)
          end

          def self.revert(verdict:)
            set(verdict, false)
          end

          def self.set(verdict, provisional)
            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return noop("book #{verdict.payload["book_id"]} no longer exists") unless book
            return noop(provisional ? "already provisional" : "not provisional") if book.provisional == provisional

            configurations = ranking_configuration_ids(book)
            book.update!(provisional: provisional)
            Result.new(success?: true, data: {outcome: :applied, ranking_configuration_ids: configurations}, errors: [])
          end

          def self.ranking_configuration_ids(book)
            ranked = ::RankedItem.where(item_type: "Books::Book", item_id: book.id).distinct.pluck(:ranking_configuration_id)
            (ranked + [::Books::RankingConfiguration.default_primary&.id]).compact.uniq
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :set, :ranking_configuration_ids, :noop
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/`
Expected: PASS.

- [ ] **Step 3: Add the `junk` rake task, test first**

Add to the rake test:

```ruby
  test "junk reports both kinds" do
    REPLAY::FindJunk.expects(:call).returns(result(authorless: 37, orphaned: 4))

    assert_output(/mark_provisional verdicts: 37 authorless, 4 with no support after relinks/) { Rake::Task["books:goodreads_replay:junk"].invoke }
  end
```

Run it. Expected: FAIL. Then add:

```ruby
    desc "Record mark_provisional verdicts for authorless books and for books every holder is relinked away from"
    task junk: :environment do
      counts = Services::Books::GoodreadsReplay::FindJunk.call.data
      puts "mark_provisional verdicts: #{counts[:authorless]} authorless, #{counts[:orphaned]} with no support after relinks"
    end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/lib/services/books/goodreads_replay lib/tasks/books/goodreads_replay.rake \
  test/lib/services/books/goodreads_replay test/lib/tasks/books_goodreads_replay_rake_test.rb
git commit -m "Goodreads replay: junk goes provisional"
```

---
### Task 11: Applying approved verdicts, behind the gate (§12.7, §12.9)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/apply_verdicts.rb`
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake` (add `apply`)
- Test: `web-app/test/lib/services/books/goodreads_replay/apply_verdicts_test.rb`, the rake test

**Interfaces:**
- Consumes: every `Apply::*` handler (Tasks 3, 7, 8, 9, 10) and `CalculateRankingsJob.perform_async(configuration_id)`.
- Produces: `ApplyVerdicts.call(auto_apply: Rails.configuration.x.goodreads_replay.auto_apply)` returns `Result`.
  - Off: `success?: false`, `errors: ["auto_apply is off …"]`.
  - On: `data: {tally: {"<kind> <outcome>" => Integer}, ranking_configuration_ids: [Integer]}`.

Order (spec §12.5): author merges, then book merges, then relinks. Book merges come after author merges because the book merger moves book_authors only when the target has none. Relinks come last because they move items onto books the merges have settled. Identifier strips follow, and `mark_provisional` comes after everything that could leave a book unsupported.

**Each pass re-applies every approved verdict** (spec §12.7: "approved ones re-apply"): after a books re-migration, the earlier passes' changes are gone and must be made again. That is safe because every handler is idempotent. `applied_at` records when a verdict last changed something; `error` records the last failure, and a later success clears it. A Postgres error re-raises (spec §13); any other error is recorded on the verdict, and the run goes on.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_replay/apply_verdicts_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class ApplyVerdictsTest < ActiveSupport::TestCase
        def verdict(kind, key, payload = {}, status: :approved)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, decided_by: :rule, status: status, payload: payload)
        end

        def answer(outcome, **data)
          Struct.new(:success?, :data, :errors, keyword_init: true).new(success?: true, data: {outcome: outcome, **data}, errors: [])
        end

        test "refuses to change anything while auto_apply is off" do
          verdict(:strip_identifier, "book:1:x")
          Apply::StripIdentifier.expects(:call).never

          result = ApplyVerdicts.call(auto_apply: false)

          refute result.success?
          assert_match(/auto_apply is off/, result.errors.first)
        end

        test "applies approved verdicts kind by kind: author merges, book merges, relinks, strips, provisional" do
          order = sequence("spec order")
          provisional = verdict(:mark_provisional, "book:9")
          strip = verdict(:strip_identifier, "book:8:x")
          relink = verdict(:relink, "user:1:book:2:goodreads:3")
          books = verdict(:merge_books, "books:4:5")
          authors = verdict(:merge_authors, "authors:6:7")
          verdict(:merge_books, "books:10:11", status: :proposed)
          Apply::MergeAuthors.expects(:call).with(verdict: authors).in_sequence(order).returns(answer(:applied))
          Apply::MergeBooks.expects(:call).with(verdict: books).in_sequence(order).returns(answer(:applied))
          Apply::Relink.expects(:call).with(verdict: relink).in_sequence(order).returns(answer(:noop, reason: "already applied"))
          Apply::StripIdentifier.expects(:call).with(verdict: strip).in_sequence(order).returns(answer(:applied))
          Apply::MarkProvisional.expects(:call).with(verdict: provisional).in_sequence(order)
            .returns(answer(:applied, ranking_configuration_ids: [42]))
          ::CalculateRankingsJob.expects(:perform_async).with(42).once

          result = ApplyVerdicts.call(auto_apply: true)

          assert_equal({"merge_authors applied" => 1, "merge_books applied" => 1, "relink noop" => 1,
                        "strip_identifier applied" => 1, "mark_provisional applied" => 1}, result.data[:tally])
          refute_nil authors.reload.applied_at
          assert_nil relink.reload.applied_at
        end

        test "a failing verdict records its error and the rest still apply; a later success clears it" do
          broken = verdict(:merge_books, "books:1:2")
          fine = verdict(:merge_books, "books:3:4")
          Apply::MergeBooks.stubs(:call).with(verdict: broken).raises(Apply::Failed, "locked")
          Apply::MergeBooks.stubs(:call).with(verdict: fine).returns(answer(:applied))

          result = ApplyVerdicts.call(auto_apply: true)

          assert_equal "Services::Books::GoodreadsReplay::Apply::Failed: locked", broken.reload.error
          assert_equal 1, result.data[:tally]["merge_books failed"]
          refute_nil fine.reload.applied_at

          Apply::MergeBooks.stubs(:call).with(verdict: broken).returns(answer(:applied))
          ApplyVerdicts.call(auto_apply: true)
          assert_nil broken.reload.error
        end

        test "a Postgres error stops the run" do
          verdict(:merge_books, "books:1:2")
          Apply::MergeBooks.stubs(:call).raises(ActiveRecord::StatementInvalid, "PG::ConnectionBad")

          assert_raises(ActiveRecord::StatementInvalid) { ApplyVerdicts.call(auto_apply: true) }
        end

        test "an author merge chain applies in id order, and a link whose author is gone is a harmless no-op" do
          ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
          a = ::Books::Author.create!(name: "Chain Author")
          b = ::Books::Author.create!(name: "Chain  Author")
          c = ::Books::Author.create!(name: "Chain Author.")
          verdict(:merge_authors, "authors:#{b.id}:#{c.id}", {"source_id" => b.id, "target_id" => c.id})
          verdict(:merge_authors, "authors:#{a.id}:#{b.id}", {"source_id" => a.id, "target_id" => b.id})

          result = ApplyVerdicts.call(auto_apply: true)

          assert_equal({"merge_authors applied" => 1, "merge_authors noop" => 1}, result.data[:tally])
          refute ::Books::Author.exists?(b.id)
          assert ::Books::Author.exists?(a.id), "A's target was merged away first; the next pass re-derives A with C"
        end

        test "applying the same verdicts twice leaves the same state" do
          book = books_books(:war_and_peace)
          ::Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "656-war-and-peace")
          verdict(:strip_identifier, "book:#{book.id}:books_work_goodreads_id:656-war-and-peace",
            {"book_id" => book.id, "remove" => [["books_work_goodreads_id", "656-war-and-peace"]], "add" => [["books_work_goodreads_id", "656"]]})

          ApplyVerdicts.call(auto_apply: true)
          first = book.identifiers.order(:id).pluck(:identifier_type, :value)
          second = ApplyVerdicts.call(auto_apply: true)

          assert_equal first, book.identifiers.order(:id).pluck(:identifier_type, :value)
          assert_equal({"strip_identifier noop" => 1}, second.data[:tally])
        end
      end
    end
  end
end
```

In the merge-chain test, the three names normalize to one key, which is irrelevant here: the verdicts are given directly. `Books::Author::Merger` runs for real. Its post-commit steps insert `SearchIndexRequest` rows and queue `CalculateAuthorRankingsJob`, stubbed above so that it does not run inline. If the merger needs more stubs in test (the author merger's own tests show which), add them and ledger the change.

Run: `bin/rails test test/lib/services/books/goodreads_replay/apply_verdicts_test.rb`
Expected: FAIL with `uninitialized constant ...ApplyVerdicts`.

- [ ] **Step 2: Write ApplyVerdicts**

`web-app/app/lib/services/books/goodreads_replay/apply_verdicts.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The one place the replay changes catalog data (Goodreads import spec
      # §12.7, §12.9). Applies every approved verdict in the spec's order:
      # author merges, then book merges (the book merger moves book_authors only
      # when the target has none), then relinks, identifier strips, and
      # mark_provisional last.
      #
      # Every pass re-applies all approved verdicts, because a books
      # re-migration undoes the last pass's changes. That is safe because each
      # handler is idempotent and does nothing when its records are gone or its
      # change is already there.
      #
      # Refuses to run while config.x.goodreads_replay.auto_apply is off: the
      # first full replay writes verdicts and applies nothing.
      class ApplyVerdicts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze
        HANDLERS = {
          merge_authors: Apply::MergeAuthors,
          merge_books: Apply::MergeBooks,
          relink: Apply::Relink,
          strip_identifier: Apply::StripIdentifier,
          mark_provisional: Apply::MarkProvisional
        }.freeze

        def self.call(auto_apply: Rails.configuration.x.goodreads_replay.auto_apply)
          new(auto_apply: auto_apply).call
        end

        def initialize(auto_apply:)
          @auto_apply = auto_apply
        end

        def call
          unless @auto_apply
            return Result.new(success?: false, data: {tally: {}},
              errors: ["auto_apply is off (config.x.goodreads_replay.auto_apply); nothing was applied"])
          end

          tally = Hash.new(0)
          configurations = Set.new
          HANDLERS.each do |kind, handler|
            ::Books::RepairVerdict.approved.where(kind: kind).find_each do |verdict|
              tally["#{kind} #{apply(verdict, handler, configurations)}"] += 1
            end
          end
          configurations.each { |id| ::CalculateRankingsJob.perform_async(id) }
          Result.new(success?: true, data: {tally: tally.to_h, ranking_configuration_ids: configurations.to_a}, errors: [])
        end

        private

        def apply(verdict, handler, configurations)
          result = handler.call(verdict: verdict)
          outcome = result.data[:outcome]
          configurations.merge(Array(result.data[:ranking_configuration_ids]))
          verdict.update!(applied_at: (outcome == :applied) ? Time.current : verdict.applied_at, error: nil)
          outcome
        rescue *POSTGRES_ERRORS
          raise
        rescue => e
          verdict.update!(error: "#{e.class}: #{e.message}")
          :failed
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/apply_verdicts_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 3: Add the `apply` rake task, test first**

Add to the rake test:

```ruby
  test "apply aborts with the gate's reason while auto_apply is off" do
    REPLAY::ApplyVerdicts.expects(:call).returns(Struct.new(:success?, :data, :errors, keyword_init: true)
      .new(success?: false, data: {tally: {}}, errors: ["auto_apply is off (config.x.goodreads_replay.auto_apply); nothing was applied"]))

    assert_output(nil, /auto_apply is off/) { assert_raises(SystemExit) { Rake::Task["books:goodreads_replay:apply"].invoke } }
  end

  test "apply prints what it applied" do
    REPLAY::ApplyVerdicts.expects(:call).returns(result(tally: {"merge_books applied" => 2}, ranking_configuration_ids: [1]))

    assert_output(/applied verdicts: merge_books applied 2; ranking recalculations queued: 1/) do
      Rake::Task["books:goodreads_replay:apply"].invoke
    end
  end
```

Run them. Expected: FAIL. Then add:

```ruby
    desc "Apply every approved replay verdict (author merges, book merges, relinks, identifier strips, provisional). " \
      "Refuses while config.x.goodreads_replay.auto_apply is false. Idempotent; re-run after every books migration pass."
    task apply: :environment do
      result = Services::Books::GoodreadsReplay::ApplyVerdicts.call
      abort result.errors.join("; ") unless result.success?

      puts "applied verdicts: #{tally.call(result.data[:tally])}; " \
        "ranking recalculations queued: #{result.data[:ranking_configuration_ids].size}"
    end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/lib/services/books/goodreads_replay/apply_verdicts.rb lib/tasks/books/goodreads_replay.rake \
  test/lib/services/books/goodreads_replay/apply_verdicts_test.rb test/lib/tasks/books_goodreads_replay_rake_test.rb
git commit -m "Goodreads replay: apply approved verdicts in order, behind auto_apply"
```

---
### Task 12: Admin queue — Books → Repair Verdicts (§12.7)

**Files:**
- Create (generator): `web-app/app/controllers/admin/books/repair_verdicts_controller.rb`, `web-app/app/views/admin/books/repair_verdicts/{index,show}.html.erb`, `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb`
- Modify: `web-app/config/routes.rb` (books admin namespace), `web-app/app/lib/admin/domain_nav.rb`, `web-app/app/models/books/repair_verdict.rb` (`book_ids`, `author_ids`)
- Modify: `web-app/lib/tasks/e2e.rake` (seed and cleanup)
- Create: `web-app/e2e/tests/books/admin/repair-verdicts.spec.ts`
- Test: `web-app/test/models/books/repair_verdict_test.rb` (add), `web-app/test/lib/tasks/e2e_repair_verdicts_rake_test.rb`

**Interfaces:**
- Consumes: `Books::RepairVerdict` (Tasks 1 and 5), `Apply::MarkProvisional.revert` (Task 10) and `Admin::DomainScopedAuth`.
- Produces: the routes `admin_books_repair_verdicts_path`, `admin_books_repair_verdict_path(v)`, `approve_admin_books_repair_verdict_path(v)`, `reject_admin_books_repair_verdict_path(v)` and `bulk_approve_admin_books_repair_verdicts_path`.

Behaviour:
- **Index.** Filters by kind, decided_by and confidence. Status tabs with counts, default `proposed`. Checkboxes with "Approve selected", plus "Approve all proposed matching this filter" behind a confirmation. Measurement 1 means relinks will number in the thousands.
- **Show.** The summary, the reason, links to both records (admin book or author pages) and to the match decision, the source rows (the legacy import id and row number, with the row's title, author and shelf), and any cached Goodreads page facts.
- **Approve.** Records `decided_by_user_id` and `reviewed_at` and leaves `decided_by` as it is (R8). It never applies; the next `books:goodreads_replay:apply` does (R11). Approving takes the **delete** gate, as the match-decision reject does: an approved merge destroys a row on the next apply.
- **Reject.** Takes the write gate. A verdict already applied cannot be rejected, except `mark_provisional`, whose reject reverts it and queues its ranking recalculations (R15).

- [ ] **Step 1: Add the model helpers, test first**

Add to `web-app/test/models/books/repair_verdict_test.rb`:

```ruby
    test "names the books and authors each kind is about" do
      assert_equal [2, 4], verdict.book_ids
      assert_equal [8, 9], verdict(kind: :merge_books, subject_key: "books:8:9", payload: {"source_id" => 8, "target_id" => 9}).book_ids
      merge = verdict(kind: :merge_authors, subject_key: "authors:5:6", payload: {"source_id" => 5, "target_id" => 6})
      assert_equal [[], [5, 6]], [merge.book_ids, merge.author_ids]
      assert_equal [7], verdict(kind: :mark_provisional, subject_key: "book:7", payload: {"book_id" => 7}).book_ids
      assert_empty verdict.author_ids
    end
```

Run it. Expected: FAIL (`NoMethodError: book_ids`). Then add to the model:

```ruby
    def book_ids
      ids = case kind
      when "relink" then [payload["from_book_id"], payload["to_book_id"]]
      when "merge_books" then [payload["source_id"], payload["target_id"]]
      when "strip_identifier", "mark_provisional" then [payload["book_id"]]
      else []
      end
      ids.compact
    end

    def author_ids
      merge_authors? ? [payload["source_id"], payload["target_id"]].compact : []
    end
```

Run: `bin/rails test test/models/books/repair_verdict_test.rb`
Expected: PASS.

- [ ] **Step 2: Generate the controller and add routes and nav**

```bash
bin/rails generate controller Admin::Books::RepairVerdicts index show --skip-routes --no-helper
```

In `config/routes.rb`, inside the books admin namespace (`namespace :admin, module: "admin/books", as: "admin_books"`), directly after `resources :duplicate_candidates …end`, add:

```ruby
    # The Goodreads replay's findings (Goodreads import spec §12.7).
    resources :repair_verdicts, only: [:index, :show] do
      member do
        post :approve
        post :reject
      end
      collection do
        post :bulk_approve
      end
    end
```

In `app/lib/admin/domain_nav.rb`, in the books `items:`, after the `Duplicates` line:

```ruby
          {label: "Repair Verdicts", icon: :list, path: -> { URL_HELPERS.admin_books_repair_verdicts_path }},
```

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: PASS. If a test enumerates the books items exactly, add "Repair Verdicts" after "Duplicates" there and ledger the change.

- [ ] **Step 3: Write the failing controller tests**

Replace `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb` with:

```ruby
require "test_helper"

module Admin
  module Books
    class RepairVerdictsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @book = books_books(:war_and_peace)
        @relink = verdict(:relink, "user:1:book:#{@book.id}:goodreads:9", decided_by: :ai, confidence: :high,
          payload: {"user_id" => 1, "from_book_id" => @book.id, "to_book_id" => books_books(:got).id, "goodreads_book_id" => 9,
                    "rows" => [[501, 3]]})
        @merge = verdict(:merge_books, "books:1:2", status: :approved, payload: {"source_id" => 2, "target_id" => 1})
      end

      def verdict(kind, key, status: :proposed, decided_by: :rule, confidence: :certain, payload: {})
        ::Books::RepairVerdict.create!(kind: kind, subject_key: key, status: status, decided_by: decided_by,
          confidence: confidence, payload: payload, reason: "test")
      end

      def verdict_ids
        css_select("[data-testid=verdict-row]").map { |row| row["data-verdict-id"].to_i }
      end

      test "index redirects unauthenticated users" do
        get admin_books_repair_verdicts_path
        assert_redirected_to books_root_path
      end

      test "index defaults to proposed verdicts and filters by kind, decider and confidence" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_repair_verdicts_path
        assert_equal [@relink.id], verdict_ids

        get admin_books_repair_verdicts_path(status: "approved")
        assert_equal [@merge.id], verdict_ids

        get admin_books_repair_verdicts_path(kind: "merge_books")
        assert_empty verdict_ids

        get admin_books_repair_verdicts_path(decided_by: "ai", confidence: "high", kind: "bogus", status: "bogus")
        assert_equal [@relink.id], verdict_ids
      end

      test "show renders the verdict with its source rows" do
        import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 501)
        import.rows.create!(row_number: 3, raw: {"Title" => "War and Peace", "Author" => "Leo Tolstoy"})
        sign_in_as(@admin, stub_auth: true)

        get admin_books_repair_verdict_path(@relink)

        assert_response :success
        assert_select "[data-testid=source-row]", 1
      end

      test "approve records the reviewer and leaves the finder's decider" do
        sign_in_as(@admin, stub_auth: true)

        post approve_admin_books_repair_verdict_path(@relink)

        @relink.reload
        assert_predicate @relink, :approved?
        assert_predicate @relink, :decided_by_ai?
        assert_equal @admin.id, @relink.decided_by_user_id
        refute_nil @relink.reviewed_at
        assert_nil @relink.applied_at
      end

      test "a books viewer cannot approve or reject" do
        sign_in_as(@viewer, stub_auth: true)

        post approve_admin_books_repair_verdict_path(@relink)
        assert_redirected_to books_root_path
        post reject_admin_books_repair_verdict_path(@relink)
        assert_redirected_to books_root_path
        assert_predicate @relink.reload, :proposed?
      end

      test "reject marks a verdict rejected" do
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_repair_verdict_path(@relink)

        assert_predicate @relink.reload, :rejected?
        assert_equal @admin.id, @relink.decided_by_user_id
      end

      test "an applied merge cannot be rejected" do
        @merge.update!(applied_at: Time.current)
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_repair_verdict_path(@merge)

        assert_predicate @merge.reload, :approved?
        assert_redirected_to admin_books_repair_verdict_path(@merge)
      end

      test "rejecting an applied mark_provisional reverts it" do
        @book.update!(provisional: true)
        flagged = verdict(:mark_provisional, "book:#{@book.id}", status: :approved, payload: {"book_id" => @book.id})
        flagged.update!(applied_at: Time.current)
        ::CalculateRankingsJob.stubs(:perform_async)
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_repair_verdict_path(flagged)

        assert_predicate flagged.reload, :rejected?
        refute @book.reload.provisional
      end

      test "bulk approve approves the selected proposed verdicts only" do
        other = verdict(:relink, "user:2:book:3:goodreads:4", decided_by: :ai)
        sign_in_as(@admin, stub_auth: true)

        post bulk_approve_admin_books_repair_verdicts_path, params: {ids: [@relink.id, @merge.id]}

        assert_predicate @relink.reload, :approved?
        assert_predicate other.reload, :proposed?
        assert_equal @admin.id, @relink.decided_by_user_id
      end

      test "bulk approve of all matching approves only proposed verdicts the filter selects" do
        ai = verdict(:relink, "user:2:book:3:goodreads:4", decided_by: :ai, confidence: :low)
        sign_in_as(@admin, stub_auth: true)

        post bulk_approve_admin_books_repair_verdicts_path, params: {all_matching: "1", kind: "relink", confidence: "high"}

        assert_predicate @relink.reload, :approved?
        assert_predicate ai.reload, :proposed?
      end
    end
  end
end
```

Run: `bin/rails test test/controllers/admin/books/repair_verdicts_controller_test.rb`
Expected: FAIL. The generated controller has empty actions and lacks `approve`, `reject` and `bulk_approve`.

- [ ] **Step 4: Write the controller**

Replace `web-app/app/controllers/admin/books/repair_verdicts_controller.rb` with:

```ruby
# The Goodreads replay's findings (Goodreads import spec §12.7). Approving
# never applies: books:goodreads_replay:apply does, in the spec's order, when
# config.x.goodreads_replay.auto_apply is on. decided_by stays the finder's
# (rule or ai); the reviewer is decided_by_user_id and reviewed_at.
class Admin::Books::RepairVerdictsController < Admin::Books::BaseController
  KINDS = ::Books::RepairVerdict.kinds.keys.freeze
  STATUSES = ::Books::RepairVerdict.statuses.keys.freeze
  DECIDED_BY = ::Books::RepairVerdict.decided_bies.keys.freeze
  CONFIDENCES = ::Books::RepairVerdict.confidences.keys.freeze
  FILTER_KEYS = %w[kind status decided_by confidence].freeze
  PER_PAGE = 50

  before_action :set_verdict, only: [:show, :approve, :reject]
  # An approved merge destroys a row on the next apply, so approving takes the
  # delete gate, as the match-decision reject does.
  before_action :require_domain_delete!, only: [:approve, :bulk_approve]
  before_action :require_domain_write!, only: [:reject]

  helper_method :filter_params

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "proposed"
    scope = filtered_scope
    @counts = scope.group(:status).count
    @pagy, @verdicts = pagy(scope.where(status: @status).newest_first, limit: PER_PAGE)
  end

  def show
    @source_rows = source_rows
    @books = ::Books::Book.where(id: @verdict.book_ids).index_by(&:id)
    @authors = ::Books::Author.where(id: @verdict.author_ids).index_by(&:id)
    @decision = ::MatchDecision.find_by(id: @verdict.payload["match_decision_id"])
  end

  def approve
    unless @verdict.proposed?
      redirect_to admin_books_repair_verdict_path(@verdict), alert: "This verdict is already #{@verdict.status}."
      return
    end

    review!(@verdict, :approved)
    redirect_to admin_books_repair_verdict_path(@verdict), notice: "Approved. The next books:goodreads_replay:apply applies it."
  end

  def reject
    if @verdict.rejected?
      redirect_to admin_books_repair_verdict_path(@verdict), alert: "This verdict is already rejected."
      return
    end
    if @verdict.applied_at.present?
      unless @verdict.mark_provisional?
        redirect_to admin_books_repair_verdict_path(@verdict), alert: "Already applied; it cannot be undone here."
        return
      end
      revert_provisional
    end

    review!(@verdict, :rejected)
    redirect_to admin_books_repair_verdict_path(@verdict), notice: "Rejected."
  end

  def bulk_approve
    scope = (params[:all_matching] == "1") ? filtered_scope : ::Books::RepairVerdict.where(id: Array(params[:ids]).map(&:to_i))
    now = Time.current
    count = scope.proposed.update_all(status: ::Books::RepairVerdict.statuses[:approved], decided_by_user_id: current_user.id,
      reviewed_at: now, updated_at: now)
    redirect_to admin_books_repair_verdicts_path(filter_params), notice: "Approved #{count}."
  end

  private

  def set_verdict
    @verdict = ::Books::RepairVerdict.find(params[:id])
  end

  def filtered_scope
    scope = ::Books::RepairVerdict.all
    scope = scope.where(kind: params[:kind]) if KINDS.include?(params[:kind])
    scope = scope.where(decided_by: params[:decided_by]) if DECIDED_BY.include?(params[:decided_by])
    scope = scope.where(confidence: params[:confidence]) if CONFIDENCES.include?(params[:confidence])
    scope
  end

  def review!(verdict, status)
    verdict.update!(status: status, decided_by_user_id: current_user.id, reviewed_at: Time.current)
  end

  def revert_provisional
    result = ::Services::Books::GoodreadsReplay::Apply::MarkProvisional.revert(verdict: @verdict)
    Array(result.data[:ranking_configuration_ids]).each { |id| ::CalculateRankingsJob.perform_async(id) }
    @verdict.update!(applied_at: nil)
  end

  # The import rows the finding came from: [legacy import id, row number] pairs.
  def source_rows
    pairs = Array(@verdict.payload["rows"])
    return [] if pairs.empty?

    imports = ::Books::GoodreadsImport.where(legacy_import_id: pairs.map(&:first)).index_by(&:legacy_import_id)
    pairs.filter_map { |legacy_id, row_number| imports[legacy_id]&.rows&.find_by(row_number: row_number) }
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end
```

`decided_bies` is Rails' pluralization of `decided_by`. Confirm it with `bin/rails runner 'p Books::RepairVerdict.decided_bies'`, and use whatever name it prints.

- [ ] **Step 5: Write the views**

`web-app/app/views/admin/books/repair_verdicts/index.html.erb`:

```erb
<%# web-app/app/views/admin/books/repair_verdicts/index.html.erb %>
<% content_for :title, "Repair Verdicts" %>

<div class="space-y-4">
  <h1 class="text-2xl font-bold">Repair Verdicts</h1>
  <p class="text-sm text-base-content/70">
    Findings from the legacy Goodreads replay. Approving queues a verdict for the next
    <code>books:goodreads_replay:apply</code>; nothing changes until then.
  </p>

  <%= form_with url: admin_books_repair_verdicts_path, method: :get, class: "flex flex-wrap items-end gap-3", data: {testid: "verdict-filters"} do |form| %>
    <%= hidden_field_tag :status, @status %>
    <% [["kind", "Kind", Admin::Books::RepairVerdictsController::KINDS],
        ["decided_by", "Decided by", Admin::Books::RepairVerdictsController::DECIDED_BY],
        ["confidence", "Confidence", Admin::Books::RepairVerdictsController::CONFIDENCES]].each do |key, label, values| %>
      <div>
        <%= form.label key, label, class: "label text-xs" %>
        <%= form.select key, options_for_select([["All", ""]] + values.map { |value| [value.humanize, value] }, params[key]), {}, class: "select select-sm" %>
      </div>
    <% end %>
    <%= form.submit "Filter", class: "btn btn-sm" %>
    <%= link_to "Reset", admin_books_repair_verdicts_path, class: "btn btn-sm btn-ghost" %>
  <% end %>

  <div role="tablist" class="tabs tabs-border">
    <% Admin::Books::RepairVerdictsController::STATUSES.each do |status| %>
      <%= link_to admin_books_repair_verdicts_path(filter_params(status: status)), role: "tab",
            class: "tab #{"tab-active" if @status == status}", data: {testid: "status-tab-#{status}"} do %>
        <%= status.humanize %>
        <span class="badge badge-sm ml-2" data-testid="status-count-<%= status %>"><%= @counts[status].to_i %></span>
      <% end %>
    <% end %>
  </div>

  <% if @verdicts.any? %>
    <%= form_with url: bulk_approve_admin_books_repair_verdicts_path(filter_params), method: :post, data: {testid: "bulk-approve-form"} do |form| %>
      <div class="overflow-x-auto">
        <table class="table bg-base-100">
          <thead>
            <tr><th></th><th>Finding</th><th>Kind</th><th>Decided by</th><th>Confidence</th><th>Updated</th></tr>
          </thead>
          <tbody>
            <% @verdicts.each do |verdict| %>
              <tr data-testid="verdict-row" data-verdict-id="<%= verdict.id %>" data-kind="<%= verdict.kind %>">
                <td>
                  <% if verdict.proposed? && current_user_can_delete? %>
                    <%= check_box_tag "ids[]", verdict.id, false, class: "checkbox checkbox-sm", aria: {label: "Select verdict #{verdict.id}"} %>
                  <% end %>
                </td>
                <td class="[overflow-wrap:anywhere]"><%= link_to verdict.summary, admin_books_repair_verdict_path(verdict), class: "link" %></td>
                <td><span class="badge badge-ghost badge-sm"><%= verdict.kind.humanize %></span></td>
                <td><%= verdict.decided_by.humanize %></td>
                <td><%= verdict.confidence&.humanize %></td>
                <td class="whitespace-nowrap"><%= verdict.updated_at.strftime("%Y-%m-%d %H:%M") %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      <% if @status == "proposed" && current_user_can_delete? %>
        <div class="flex flex-wrap gap-2 mt-3">
          <%= form.submit "Approve selected", class: "btn btn-sm btn-primary" %>
        </div>
      <% end %>
    <% end %>

    <% if @status == "proposed" && current_user_can_delete? %>
      <%= button_to "Approve all #{@counts["proposed"].to_i} proposed matching this filter",
            bulk_approve_admin_books_repair_verdicts_path(filter_params(all_matching: "1")), method: :post,
            class: "btn btn-sm btn-outline",
            form: {data: {testid: "approve-all-form", turbo_confirm: "Approve every proposed verdict this filter shows? They are applied on the next apply run."}} %>
    <% end %>
  <% else %>
    <p class="text-center text-base-content/70 py-8">No <%= @status %> verdicts.</p>
  <% end %>

  <% if @pagy.pages > 1 %>
    <div class="mt-4 flex justify-center"><%== @pagy.series_nav %></div>
  <% end %>
</div>
```

`web-app/app/views/admin/books/repair_verdicts/show.html.erb`:

```erb
<%# web-app/app/views/admin/books/repair_verdicts/show.html.erb %>
<% content_for :title, "Repair Verdict ##{@verdict.id}" %>

<div class="space-y-4">
  <%= link_to "← Repair Verdicts", admin_books_repair_verdicts_path(kind: @verdict.kind, status: @verdict.status), class: "link text-sm" %>
  <h1 class="text-2xl font-bold [overflow-wrap:anywhere]"><%= @verdict.summary %></h1>

  <div class="flex flex-wrap gap-2">
    <span class="badge"><%= @verdict.kind.humanize %></span>
    <span class="badge badge-outline" data-testid="verdict-status"><%= @verdict.status.humanize %></span>
    <span class="badge badge-ghost">Decided by <%= @verdict.decided_by %></span>
    <% if @verdict.confidence %><span class="badge badge-ghost"><%= @verdict.confidence %> confidence</span><% end %>
    <% if @verdict.applied_at %><span class="badge badge-success">Applied <%= @verdict.applied_at.strftime("%Y-%m-%d") %></span><% end %>
  </div>

  <% if @verdict.reason.present? %><p class="[overflow-wrap:anywhere]"><%= @verdict.reason %></p><% end %>
  <% if @verdict.error.present? %><div role="alert" class="alert alert-error"><%= @verdict.error %></div><% end %>

  <div class="card bg-base-100">
    <div class="card-body">
      <h2 class="card-title text-base">Records</h2>
      <ul class="list-disc ml-5">
        <% @verdict.book_ids.each do |id| %>
          <li>
            <% if (book = @books[id]) %>
              <%= link_to "Book ##{id}: #{book.title}", admin_books_book_path(book), class: "link" %>
              <% if book.provisional %><span class="badge badge-warning badge-sm ml-1">provisional</span><% end %>
            <% else %>
              Book #<%= id %> (no longer exists)
            <% end %>
          </li>
        <% end %>
        <% @verdict.author_ids.each do |id| %>
          <li>
            <% if (author = @authors[id]) %>
              <%= link_to "Author ##{id}: #{author.name}", admin_books_author_path(author), class: "link" %>
            <% else %>
              Author #<%= id %> (no longer exists)
            <% end %>
          </li>
        <% end %>
        <% if @decision %><li><%= link_to "Match decision ##{@decision.id}", admin_books_match_decision_path(@decision), class: "link" %></li><% end %>
      </ul>
    </div>
  </div>

  <% if @source_rows.any? %>
    <div class="overflow-x-auto">
      <h2 class="font-semibold mb-2">Source rows</h2>
      <table class="table bg-base-100">
        <thead><tr><th>Legacy import</th><th>Row</th><th>Title</th><th>Author</th><th>Shelf</th><th>Finding</th></tr></thead>
        <tbody>
          <% @source_rows.each do |row| %>
            <tr data-testid="source-row">
              <td><%= row.import.legacy_import_id %></td>
              <td><%= row.row_number %></td>
              <td class="[overflow-wrap:anywhere]"><%= row.raw["Title"] %></td>
              <td class="[overflow-wrap:anywhere]"><%= row.raw["Author"] %></td>
              <td><%= row.exclusive_shelf %></td>
              <td><%= row.replay_finding&.humanize %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% end %>

  <% if (page = @verdict.payload["goodreads_page"]) %>
    <div class="card bg-base-100">
      <div class="card-body">
        <h2 class="card-title text-base">Cached Goodreads page</h2>
        <p class="[overflow-wrap:anywhere]"><%= page["outcome"] %>: <%= page["title"] %> by <%= Array(page["authors"]).join(", ") %></p>
      </div>
    </div>
  <% end %>

  <details class="collapse collapse-arrow bg-base-100">
    <summary class="collapse-title font-semibold">Payload</summary>
    <div class="collapse-content"><pre class="text-xs [overflow-wrap:anywhere] whitespace-pre-wrap"><%= JSON.pretty_generate(@verdict.payload) %></pre></div>
  </details>

  <div class="flex flex-wrap gap-2">
    <% if @verdict.proposed? && current_user_can_delete? %>
      <%= button_to "Approve", approve_admin_books_repair_verdict_path(@verdict), method: :post, class: "btn btn-sm btn-primary" %>
    <% end %>
    <% if !@verdict.rejected? && current_user_can_write? && (@verdict.applied_at.nil? || @verdict.mark_provisional?) %>
      <%= button_to "Reject", reject_admin_books_repair_verdict_path(@verdict), method: :post, class: "btn btn-sm btn-error",
            form: {data: {testid: "reject-form"}} %>
    <% end %>
  </div>
</div>
```

Run: `bin/rails test test/controllers/admin/books/repair_verdicts_controller_test.rb test/lint/daisyui_v4_classes_test.rb`
Expected: PASS.
- Check that `admin_books_book_path(book)` and `admin_books_author_path(author)` resolve. If they do not, run `bin/rails routes -g admin_books_book` and use the name it prints.
- Add `target: "_top"` only if the views end up inside a turbo frame. They are not in one here.

- [ ] **Step 6: E2E seed and cleanup rakes, test first**

`web-app/test/lib/tasks/e2e_repair_verdicts_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eRepairVerdictsRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("e2e:repair_verdicts_seed")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    Rake::Task["e2e:repair_verdicts_seed"].reenable
    Rake::Task["e2e:repair_verdicts_cleanup"].reenable
  end

  test "seeds one proposed relink between two real books, idempotently, and cleans it up" do
    ENV["E2E_BOOK_A"] = books_books(:war_and_peace).slug
    ENV["E2E_BOOK_B"] = books_books(:got).slug
    out, = capture_io { Rake::Task["e2e:repair_verdicts_seed"].invoke }
    Rake::Task["e2e:repair_verdicts_seed"].reenable
    capture_io { Rake::Task["e2e:repair_verdicts_seed"].invoke }

    verdict = ::Books::RepairVerdict.find(JSON.parse(out.lines.last)["verdict_id"])
    assert_predicate verdict, :proposed?
    assert_equal 1, ::Books::RepairVerdict.where("subject_key LIKE 'e2e:%'").count

    capture_io { Rake::Task["e2e:repair_verdicts_cleanup"].invoke }
    assert_equal 0, ::Books::RepairVerdict.where("subject_key LIKE 'e2e:%'").count
  ensure
    ENV.delete("E2E_BOOK_A")
    ENV.delete("E2E_BOOK_B")
  end
end
```

Run it. Expected: FAIL (`Don't know how to build task 'e2e:repair_verdicts_seed'`). Then add to `lib/tasks/e2e.rake`, next to the import-finder tasks:

```ruby
  desc "Seed one proposed relink verdict for e2e/tests/books/admin/repair-verdicts.spec.ts (E2E_BOOK_A, E2E_BOOK_B override the slugs)"
  task repair_verdicts_seed: :environment do
    # A verdict names records by id only; rejecting it (what the spec does)
    # changes no catalog data, and approving would not either until an apply
    # run. Idempotent: resets the one e2e verdict.
    from = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_A", "headlong-hall"))
    to = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_B", "war-and-peace"))
    verdict = Books::RepairVerdict.find_or_initialize_by(kind: :relink, subject_key: "e2e:relink")
    verdict.update!(status: :proposed, decided_by: :ai, confidence: :high, reason: "E2E repair verdicts spec",
      decided_by_user_id: nil, reviewed_at: nil, applied_at: nil, error: nil,
      payload: {user_id: 0, from_book_id: from.id, to_book_id: to.id, goodreads_book_id: 0, rows: []})
    puts({verdict_id: verdict.id}.to_json)
  end

  desc "Remove the verdict e2e:repair_verdicts_seed created"
  task repair_verdicts_cleanup: :environment do
    puts "removed #{Books::RepairVerdict.where("subject_key LIKE 'e2e:%'").delete_all} verdict(s)"
  end
```

Run: `bin/rails test test/lib/tasks/e2e_repair_verdicts_rake_test.rb`
Expected: PASS.

- [ ] **Step 7: Write the E2E spec**

`web-app/e2e/tests/books/admin/repair-verdicts.spec.ts`:

```ts
import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Seeds one proposed relink verdict through a rake helper, finds it with the
// kind filter, opens it and rejects it. Rejecting an unapplied verdict changes
// no catalog data, so this is safe against the development database. Never
// approves: approval is safe too, but an apply run would then act on it.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let verdictId: number;

test.describe("Books admin — repair verdicts", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    const lines = rails("e2e:repair_verdicts_seed").trim().split("\n");
    verdictId = JSON.parse(lines[lines.length - 1]).verdict_id;
  });

  test.afterAll(() => {
    rails("e2e:repair_verdicts_cleanup");
  });

  test("the queue filters to the seeded relink, and rejecting it moves it to Rejected", async ({ page }) => {
    const row = page.locator(`[data-testid="verdict-row"][data-verdict-id="${verdictId}"]`);

    await page.goto("/admin/repair_verdicts?kind=merge_books");
    await expect(row).toHaveCount(0);
    await page.goto("/admin/repair_verdicts?kind=relink&decided_by=ai");
    await expect(row).toBeVisible();

    await row.getByRole("link").click();
    await expect(page).toHaveURL(new RegExp(`/admin/repair_verdicts/${verdictId}$`));
    await page.getByRole("button", { name: "Reject" }).click();
    await expect(page.getByRole("alert")).toContainText("Rejected.");
    await expect(page.getByTestId("verdict-status")).toHaveText("Rejected");

    await page.goto("/admin/repair_verdicts?kind=relink&status=rejected");
    await expect(row).toBeVisible();
  });
});
```

Run the E2E only after confirming port 3000 is yours (AGENTS.md) and building assets: `yarn build:all`, then `bin/rails server` in the background, then `yarn test:e2e e2e/tests/books/admin/repair-verdicts.spec.ts`.
Expected: 1 passed. If the admin E2E project needs an auth setup the other admin specs use, follow `import-finder-audit.spec.ts`; it uses none beyond the project's storage state.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin/books/repair_verdicts_controller.rb app/views/admin/books/repair_verdicts config/routes.rb \
  app/lib/admin/domain_nav.rb app/models/books/repair_verdict.rb lib/tasks/e2e.rake e2e/tests/books/admin/repair-verdicts.spec.ts \
  test/controllers/admin/books/repair_verdicts_controller_test.rb test/models/books/repair_verdict_test.rb \
  test/lib/tasks/e2e_repair_verdicts_rake_test.rb test/lib/admin/domain_nav_test.rb
git commit -m "Admin: Books → Repair Verdicts queue"
```

---
### Task 13: Report, hand-check sample, and docs (§12.9)

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/report.rb`
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake` (add `report`, `sample`)
- Modify: `docs/features/goodreads-import.md`, `docs/features/books-provisional-records.md`, `deployment/ENV.md`
- Test: `web-app/test/lib/services/books/goodreads_replay/report_test.rb`, the rake test

**Interfaces:**
- Consumes: replay imports, rows (`replay_finding`), verdicts and match decisions.
- Produces: `Report.call(now: Time.current)` returns `Result(data: {markdown: String})`.
- Produces: `Report.sample(kind:, count:)` returns `[String]`, one line per random unreviewed approved verdict of that kind.

Spec §12.9: the report covers the agreement rate; findings by kind, confidence and decider; unmatched counts; AI calls; and the script that produced it. "A sample of 50 auto verdicts per kind is hand-checked."

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books/goodreads_replay/report_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class ReportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 1)
          ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :legacy_replay, status: :failed, legacy_import_id: 2,
            error: "not a CSV upload: video/mp4")
          edition = goodreads_edition
          {agrees: 3, duplicate: 1, disagrees: 1, unmatched: 1, no_legacy_choice: 2}.each do |finding, count|
            count.times { |n| import.rows.create!(row_number: import.rows.count + 1, goodreads_edition: edition, replay_finding: finding) }
          end
          import.rows.create!(row_number: 99, goodreads_edition: edition)
          ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :matched,
            confidence: :high, decided_by: :ai, ai_chat: ai_chats(:general_chat))
          ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:1:book:2:goodreads:3", decided_by: :ai,
            confidence: :high, payload: {"user_id" => 1, "from_book_id" => 2, "to_book_id" => 4})
          ::Books::RepairVerdict.create!(kind: :strip_identifier, subject_key: "book:7:x", decided_by: :rule, confidence: :certain,
            status: :approved, applied_at: Time.current, payload: {"book_id" => 7, "remove" => [], "add" => []})
        end

        def markdown
          Report.call(now: Time.zone.parse("2026-10-06 12:00")).data[:markdown]
        end

        test "opens with the date, the database and the command that produced it" do
          assert_match(/\A# Goodreads legacy replay\n\n\*\*Measured 2026-10-06\*\*/, markdown)
          assert_includes markdown, "bin/rails \"books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]\""
        end

        test "counts imports by status, and rows by finding with the agreement rate" do
          assert_includes markdown, "| complete | 1 |"
          assert_includes markdown, "| failed | 1 |"
          assert_includes markdown, "| agrees | 3 |"
          assert_includes markdown, "| not compared yet | 1 |"
          # (agrees + duplicate) / rows with a legacy choice and a final finding = 4 / 6
          assert_includes markdown, "Agreement: **66.7%** (4 of 6 rows with a legacy choice)"
        end

        test "breaks verdicts down by kind, decider and confidence, and counts the matching AI calls" do
          assert_includes markdown, "| relink | ai | high | 1 | 0 | 0 | 0 |"
          assert_includes markdown, "| strip_identifier | rule | certain | 0 | 1 | 0 | 1 |"
          assert_includes markdown, "Matching AI calls on replay editions: 1"
        end

        test "sample lists unreviewed approved verdicts of a kind" do
          lines = Report.sample(kind: "strip_identifier", count: 50)

          assert_equal 1, lines.size
          assert_match(/\A#\d+ On book #7/, lines.first)
          assert_empty Report.sample(kind: "relink", count: 50)
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/goodreads_replay/report_test.rb`
Expected: FAIL with `uninitialized constant ...Report`.

- [ ] **Step 2: Write the report**

`web-app/app/lib/services/books/goodreads_replay/report.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The replay's measurement (Goodreads import spec §12.9), as markdown for
      # docs/data-quality/goodreads-replay.md. It covers imports by status,
      # rows by finding with the agreement rate, verdicts by kind, decider and
      # confidence, and the matching AI calls. Read-only. The author check's AI
      # calls are printed by books:goodreads_replay:duplicates, one per name
      # group, rather than counted here.
      class Report
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        COMMAND = 'bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"'
        AGREEING = %w[agrees duplicate].freeze
        FINAL = %w[agrees duplicate disagrees unmatched].freeze

        def self.call(now: Time.current)
          new(now: now).call
        end

        def self.sample(kind:, count:)
          ::Books::RepairVerdict.approved.where(kind: kind, reviewed_at: nil).order(Arel.sql("random()")).limit(count)
            .map { |verdict| "##{verdict.id} #{verdict.summary} (#{verdict.decided_by}, #{verdict.confidence}) — #{verdict.reason}" }
        end

        def initialize(now:)
          @now = now
        end

        def call
          lines = header + imports + rows + verdicts + ai_calls
          Result.new(success?: true, data: {markdown: lines.join("\n") + "\n"}, errors: [])
        end

        private

        def header
          ["# Goodreads legacy replay", "",
            "**Measured #{@now.to_date.iso8601}** against `#{ActiveRecord::Base.connection.current_database}`, " \
              "with `auto_apply` #{Rails.configuration.x.goodreads_replay.auto_apply ? "on" : "off"}.", "",
            "```bash", "cd web-app", COMMAND, "```", "",
            "Read-only. Produced by `Services::Books::GoodreadsReplay::Report` after a replay pass " \
              "(`docs/features/goodreads-import.md`, \"Legacy replay\").", ""]
        end

        def imports
          counts = ::Books::GoodreadsImport.legacy_replay.group(:status).count
          ["## Imports", "", "| Status | Imports |", "|---|---:|"] +
            counts.sort.map { |status, count| "| #{status} | #{count} |" } + [""]
        end

        def rows
          counts = replay_rows.group(:replay_finding).count
          with_choice = FINAL.sum { |finding| counts.fetch(finding, 0) }
          agreeing = AGREEING.sum { |finding| counts.fetch(finding, 0) }
          rate = with_choice.zero? ? "n/a" : "#{(100.0 * agreeing / with_choice).round(1)}%"
          ["## Rows", "", "Agreement: **#{rate}** (#{agreeing} of #{with_choice} rows with a legacy choice)", "",
            "| Finding | Rows |", "|---|---:|"] +
            counts.sort_by { |finding, _| finding.to_s }
              .map { |finding, count| "| #{finding ? finding.tr("_", " ") : "not compared yet"} | #{count} |" } + [""]
        end

        def verdicts
          table = ::Books::RepairVerdict.group(:kind, :decided_by, :confidence, :status).count
          applied = ::Books::RepairVerdict.where.not(applied_at: nil).group(:kind, :decided_by, :confidence).count
          keys = table.keys.map { |kind, decider, confidence, _| [kind, decider, confidence] }.uniq.sort_by { |key| key.map(&:to_s) }
          ["## Verdicts", "", "| Kind | Decided by | Confidence | Proposed | Approved | Rejected | Applied |", "|---|---|---|---:|---:|---:|---:|"] +
            keys.map do |kind, decider, confidence|
              counts = %w[proposed approved rejected].map { |status| table.fetch([kind, decider, confidence, status], 0) }
              "| #{kind} | #{decider} | #{confidence || "—"} | #{counts.join(" | ")} | #{applied.fetch([kind, decider, confidence], 0)} |"
            end + [""]
        end

        def ai_calls
          editions = replay_rows.select(:goodreads_edition_id)
          calls = ::MatchDecision.where(subject_type: "Books::GoodreadsEdition", subject_id: editions).where.not(ai_chat_id: nil).count
          ["## AI calls", "", "Matching AI calls on replay editions: #{calls}", ""]
        end

        def replay_rows
          ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay).where.not(goodreads_edition_id: nil)
        end
      end
    end
  end
end
```

`group(:replay_finding).count` returns the enum's string keys, plus `nil` for rows not compared yet.

Run: `bin/rails test test/lib/services/books/goodreads_replay/report_test.rb`
Expected: PASS, 4 runs.

- [ ] **Step 3: Add the `report` and `sample` rake tasks, test first**

Add to the rake test:

```ruby
  test "report writes the markdown to the given path" do
    REPLAY::Report.expects(:call).returns(result(markdown: "# Goodreads legacy replay\n"))
    path = Rails.root.join("tmp", "goodreads-replay-report-test.md")

    assert_output(/wrote #{Regexp.escape(path.to_s)}/) { Rake::Task["books:goodreads_replay:report"].invoke(path.to_s) }
    assert_equal "# Goodreads legacy replay\n", File.read(path)
  ensure
    FileUtils.rm_f(path)
  end

  test "report prints the markdown when no path is given" do
    REPLAY::Report.expects(:call).returns(result(markdown: "# Goodreads legacy replay\n"))

    assert_output(/# Goodreads legacy replay/) { Rake::Task["books:goodreads_replay:report"].invoke }
  end

  test "sample prints the lines for the kind, and refuses an unknown kind" do
    REPLAY::Report.expects(:sample).with(kind: "merge_books", count: 50).returns(["#1 Merge book #2 into book #3"])

    assert_output(/#1 Merge book #2 into book #3/) { Rake::Task["books:goodreads_replay:sample"].invoke("merge_books") }
    Rake::Task["books:goodreads_replay:sample"].reenable
    assert_output(nil, /usage: books:goodreads_replay:sample/) do
      assert_raises(SystemExit) { Rake::Task["books:goodreads_replay:sample"].invoke("bogus") }
    end
  end
```

Run them. Expected: FAIL. Then add:

```ruby
    desc "Write the replay report (spec §12.9) to a path, or print it. " \
      "Usage: books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
    task :report, [:path] => :environment do |_task, args|
      markdown = Services::Books::GoodreadsReplay::Report.call.data[:markdown]
      if args[:path].present?
        File.write(args[:path], markdown)
        puts "wrote #{args[:path]}"
      else
        puts markdown
      end
    end

    desc "Print a random sample of auto-approved verdicts to hand-check before switching auto_apply on. " \
      "Usage: books:goodreads_replay:sample[kind,count] (count defaults to 50)"
    task :sample, [:kind, :count] => :environment do |_task, args|
      kinds = Books::RepairVerdict.kinds.keys
      abort "usage: books:goodreads_replay:sample[kind,count] with kind one of #{kinds.join(", ")}" unless kinds.include?(args[:kind])

      puts Services::Books::GoodreadsReplay::Report.sample(kind: args[:kind], count: (args[:count].presence || 50).to_i)
    end
```

Run: `bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: PASS.

- [ ] **Step 4: Docs**

`docs/features/goodreads-import.md`:
- In the Status table, set increment 4 to `shipped` and increment 5 to `this doc`.
- Add a `## Legacy replay` section before `## Dry run`:

````markdown
## Legacy replay

Spec §12. The legacy app's 803 imports are replayed against the new resolver to measure it and to find the bad data
legacy left behind. Every finding is a `Books::RepairVerdict` (`books_repair_verdicts`, no foreign keys, keyed by
preserved ids): **never truncate that table**, the launch sequence relies on it. Nothing changes the catalog except
`books:goodreads_replay:apply`, which refuses to run while `config.x.goodreads_replay.auto_apply` is false (the default).

A pass, after every books migration pass and in the launch sequence:

```bash
bin/rails books:goodreads_replay:load        # legacy imports, uploads (legacy R2, LEGACY_R2_*), rows
bin/rails books:goodreads_replay:fix_slugs   # 543 slug-form Goodreads ids -> strip_identifier (rule, approved)
bin/rails books:goodreads_replay:apply       # re-applies every approved verdict from earlier passes (gated)
bin/rails books:goodreads_replay:resolve     # queues pass one (low) and pass two (serial); re-run until both are 0
bin/rails books:goodreads_replay:duplicates  # one AI check per author name group, then the book-pair rule
bin/rails books:goodreads_replay:junk        # authorless books, books relinks leave unsupported
bin/rails books:goodreads_replay:apply
bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
```

- **Resolve** runs the books finder in `verify: true`. Pass one uses the fast sources, with Open Library's identifier
  lookup in place of `/resolve`. Pass two adds `/resolve`, only for editions pass one disagreed on or could not match.
  Each replay row gets a `replay_finding` (agrees, duplicate, disagrees, unmatched, no legacy choice). Legacy's
  choice is the book holding the row's Goodreads id that is on that user's lists. Matches warm the edition cache.
  The replay never creates books and never fetches Goodreads pages; it only reads cached ones.
- **Relinks are all AI-decided.** Measured 2026-10-05: under `verify: true`, legacy's book always holds the row's
  Goodreads id, and that hit blocks the exact-match rule for any other book. So no rule ever decides a disagreement.
  Relinks are proposed, and the admin queue approves them in bulk. A relink also moves the row's identifiers when
  legacy's book contradicts the row on title and author.
- **Authors** are grouped by name with punctuation and spaces removed, and each group gets one `fast` AI call that
  clusters it into people (`Services::Ai::Tasks::Books::GroupSameAuthorsTask`). A merge is auto-approved only when the
  AI is highly confident and there is no year or external-identifier conflict.
- **Books** in a pending duplicate pair are auto-merged only with an equal title, identical authors and a shared
  identifier. Every other pair stays in the Duplicates queue.
- **Junk:** an authorless book is auto-flagged provisional unless it is on a curated list, in which case it is only
  proposed: curated list pages are not filtered. Flagging uses `update!`, so the book is reindexed, and apply queues a
  ranking recalculation for every configuration that ranked it, plus the default one, which cascades to authors.
- **Admin:** Books → Repair Verdicts filters by kind, status, decider and confidence, approves or rejects, and approves in
  bulk. Approval never applies; the next `apply` does. An applied merge or relink cannot be rejected. Rejecting an
  applied `mark_provisional` reverts it.
- **Before auto-apply:** hand-check 50 auto verdicts per kind with `books:goodreads_replay:sample[kind]`, then set
  `auto_apply: true` in `config/initializers/goodreads_replay.rb`.
````

`docs/features/books-provisional-records.md`: replace the sentence "Curated list pages (`Books::ListsController#show`) are not filtered: imports never write curated list items." with:

```markdown
Curated list pages (`Books::ListsController#show`) are not filtered: imports never write curated list items, and the
legacy replay never flags a book on a curated list provisional on its own. Such a book's `mark_provisional` is only
proposed, for an admin (`docs/features/goodreads-import.md`, "Legacy replay").
```

Also replace the sentence "Whoever flags an existing book provisional must queue a books ranking recalculation, then an author ranking recalculation (the legacy replay's `mark_provisional`, increment 5)." with:

```markdown
Whoever flags an existing book provisional must queue a books ranking recalculation, then an author ranking
recalculation. The legacy replay's apply step does this: one `CalculateRankingsJob` per configuration that ranked the
book, plus the default one, whose job cascades to the author rankings.
```

`deployment/ENV.md`: add a section after "Private import storage":

```markdown
### Legacy bucket (read-only)

`books:goodreads_replay:load` (and the one-time `data_migration:book_images`) download from the old TheGreatestBooks R2
bucket. Read-only credentials, via SOPS:

| Variable | Purpose |
|---|---|
| `LEGACY_R2_ACCOUNT_ID` | Cloudflare account id of the legacy bucket (the endpoint is `https://<id>.r2.cloudflarestorage.com`) |
| `LEGACY_R2_BUCKET` | Legacy bucket name |
| `LEGACY_R2_ACCESS_KEY` | Read-only R2 token key id |
| `LEGACY_R2_SECRET_KEY` | Its secret |

Unset, the replay loader fails on its first download. Nothing else needs them.
```

Match the surrounding table and heading style of `deployment/ENV.md`. If the file uses another heading level or table shape, follow it.

- [ ] **Step 5: Full verification**

Run, from `web-app/`:
```bash
bin/rails test > ../.superpowers/full-suite.log 2>&1; tail -5 ../.superpowers/full-suite.log
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```
Expected:
- The suite is green, with 0 failures and 0 errors.
- Running `grep -c "warning:" ../.superpowers/full-suite.log` shows no new warning lines beyond the two known upstream sources (AGENTS.md).
- `standardrb` prints nothing.
- `zeitwerk:check` prints `All is good!`.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/goodreads_replay/report.rb lib/tasks/books/goodreads_replay.rake \
  test/lib/services/books/goodreads_replay/report_test.rb test/lib/tasks/books_goodreads_replay_rake_test.rb \
  ../docs/features/goodreads-import.md ../docs/features/books-provisional-records.md ../deployment/ENV.md
git commit -m "Goodreads replay: report, hand-check sample, docs"
```
