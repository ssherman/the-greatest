# Import Finder Redesign — Increment 1 (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `DataImporters::*::Finder` returns a `DataImporters::Match` (matched or unmatched, with confidence, candidates, who decided and why) and records a `MatchDecision` row on every call, with the shared candidate sources, deterministic rules, AI selection task, `duplicate_candidates` table and merger hook in place, while every finder keeps exactly today's lookup behaviour behind the new return type.

**Architecture:** `FinderBase#call` becomes a fixed four-stage pipeline (gather → rules → AI → record). Candidate sources are small objects returning `Candidate`s; a `CandidateSet` unions them; `Decider` runs the deterministic rules; `AiSelection` interprets one structured `SelectCandidateTask` call; the finder writes a `MatchDecision` and flags `DuplicateCandidate` pairs. In this increment each domain finder wraps its existing lookup as a single decisive `Sources::Legacy` source, so behaviour does not change; increments 2, 5 and 6 replace that with the real sources. `ImporterBase` reads `match.record`, passes the match to providers (`populate(item, query:, match: nil)`), and points the decision at a newly created record. Six mergers call `DuplicateCandidate.record_merge`.

**Tech Stack:** Rails 8.1, Postgres, Minitest 6 + fixtures + Mocha, `openai` gem structured outputs (`OpenAI::BaseModel`), Standard (standardrb), annotaterb, zeitwerk.

**Spec:** `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` — §1 (contract), §2 (sources), §3 (rules), §4 (AI step), §5 (data model), §6 (importer/provider changes), §7 (mergers), §15 (testing), Increments item 1. Three names deviate from the spec for Ruby/Rails reasons and Task 13 amends the spec to match: the outcome enum is `matched | unmatched` (an enum value `new` would define a class-level scope `MatchDecision.new`); the pair status enum is `pending | merged | not_duplicate` (the spec's "open"); sources expose `#call` with no arguments and `#name` (they are built with what they need).

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **The worktree already exists**: `/home/shane/dev/the-greatest/.claude/worktrees/import-finder-redesign`, branch `worktree-import-finder-redesign` (the spec is committed there). Work in it; never commit to `main`. Before the first task confirm the five gitignored files are present — `.env`, `web-app/.env`, `web-app/config/master.key`, `web-app/e2e/.env`, `web-app/node_modules` — and copy any missing one from the main checkout (`git worktree list --porcelain | head -1 | cut -d' ' -f2`). Then `cd web-app && RAILS_ENV=test bin/rails db:create db:test:prepare` (the test database is per-checkout).
- **The development database is shared with every other worktree and is not disposable.** Tasks 2, 3 and 4 add migrations; run them with `bin/rails db:migrate` (they only add tables and indexes). If annotaterb's post-migrate hook errors on the missing legacy database, re-run with `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`. Never `db:reset`, never `db:schema:load`, no `delete_all`/`destroy_all` outside `RAILS_ENV=test`.
- **Use Rails generators for models** (`bin/rails generate model …`), then replace the generated migration, model, test and fixture bodies with the code in the task. Never hand-create a model.
- **Root-anchor model constants inside `module DataImporters`**: `::Books::Book`, `::Music::Album`, `::Identifier`, `::RankedItem`, `::MatchDecision`, `::DuplicateCandidate`, `::Services::Text::NameNormalizer`. `DataImporters::Books` shadows `::Books` (see `nested-namespace-constant-shadowing` in memory), and `DataImporters::Candidate` is a different class from `::Books::OpenLibrary::Candidate`.
- **Rails 8 enum syntax:** `enum :status, {pending: 0}`. Enum keys must not collide with Active Record class methods, which is why the outcome is `unmatched`, not `new`.
- `Result`-style value objects use `Struct.new(..., keyword_init: true)` (a Standard cop is disabled for it).
- **Minitest 6:** `assert_nil x`, never `assert_equal nil, x`. Tests mirror `app/` and are namespaced to match (`module DataImporters; class MatchTest < ActiveSupport::TestCase`). Stub external calls with Mocha at the class level; never hit OpenSearch or the network in finder tests.
- **Sidekiq runs inline in tests** (`Sidekiq.testing!(:inline)`). Merger tests already neutralize ranking jobs in `setup`; copy their setup when adding merger tests.
- **A clean `bin/rails test` adds no warning lines** beyond the two known npm/yarn ones. Linter is `bundle exec standardrb` (NOT `bin/rubocop`); `--fix` autocorrects.
- `CI=1 bin/rails zeitwerk:check` must pass after every task that adds a directory under `app/lib` (Tasks 5, 6, 7, 8).
- **Every rule test must go red when its rule is removed.** After a task's tests pass, the executor comments out the rule under test, confirms the failure, and restores it. The task report names the mutation and the failing assertion.
- Commit after every task with a message ending in `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Nothing in this increment is user-facing: no views, no E2E.

---

## File structure

| File | Responsibility |
|---|---|
| `app/lib/services/text/name_normalizer.rb` | NFKC + Unicode-space folding + squeeze + strip |
| `app/models/books/author.rb`, `app/models/books/book.rb` | **modify**: chain `NameNormalizer` after `QuoteNormalizer` |
| `db/migrate/*_add_lower_title_and_name_indexes_for_finders.rb` | btree expression indexes for the exact source |
| `app/models/match_decision.rb` + migration + fixture | one row per finder call |
| `app/models/duplicate_candidate.rb` + migration + fixture | one row per suspected pair; `flag!`, `record_merge`, `not_duplicate?` |
| `app/models/user.rb`, `app/models/list_item.rb`, the seven importable models | **modify**: `has_many` for the new FKs and polymorphic links |
| `app/lib/data_importers/match.rb` | the finder's return value |
| `app/lib/data_importers/candidate.rb` | one thing considered; `absorb`, `snapshot` |
| `app/lib/data_importers/candidate_set.rb` | union by local id / external key |
| `app/lib/data_importers/decision.rb` | the decided outcome before it is recorded |
| `app/lib/data_importers/sources/identifiers.rb`, `exact.rb`, `open_search.rb`, `legacy.rb` | candidate sources |
| `app/lib/data_importers/decider.rb` | rules 0–5 |
| `app/lib/data_importers/ai_selection.rb` | task result → `Decision`, ranked post-rule, duplicate pairs |
| `app/lib/services/ai/tasks/matching/select_candidate_task.rb` | the structured AI call |
| `app/lib/data_importers/finder_base.rb` | **rewrite**: the pipeline + domain hooks |
| `app/lib/data_importers/importer_base.rb`, `provider_base.rb`, `import_result.rb` | **modify**: `match` plumbing |
| the 13 provider files, the 6 importer files | **modify**: signatures |
| the 6 finder files (+ delete `music/release/finder.rb`) | **modify**: `candidate_sources` + `legacy_lookup` |
| the 6 merger files | **modify**: `resolve_duplicate_candidates` before destroy |
| `docs/features/import-finder.md`, `docs/features/data_importers.md`, the spec | docs |

---

### Task 1: `Services::Text::NameNormalizer`, chained into author names and book titles

**Files:**
- Create: `app/lib/services/text/name_normalizer.rb`
- Modify: `app/models/books/author.rb:75-77`, `app/models/books/book.rb:237-239`
- Test: `test/lib/services/text/name_normalizer_test.rb`, `test/models/books/author_test.rb`, `test/models/books/book_test.rb`

**Interfaces:**
- Produces: `Services::Text::NameNormalizer.call(text) -> String | nil` (nil for nil, "" for "").

- [ ] **Step 1: Write the failing tests**

`test/lib/services/text/name_normalizer_test.rb`:

```ruby
require "test_helper"

module Services
  module Text
    class NameNormalizerTest < ActiveSupport::TestCase
      test ".call returns nil for nil and empty string for empty string" do
        assert_nil NameNormalizer.call(nil)
        assert_equal "", NameNormalizer.call("")
      end

      test ".call folds a narrow no-break space to a plain space" do
        assert_equal "Kathleen Alcott", NameNormalizer.call("Kathleen Alcott")
      end

      test ".call folds a no-break space, an em space and a zero-width space" do
        assert_equal "Leo Tolstoy", NameNormalizer.call("Leo Tolstoy")
        assert_equal "Leo Tolstoy", NameNormalizer.call("Leo Tolstoy")
        assert_equal "Leo Tolstoy", NameNormalizer.call("Leo​ Tolstoy")
      end

      test ".call collapses runs of spaces and strips the ends" do
        assert_equal "War and Peace", NameNormalizer.call("  War   and   Peace  ")
      end

      test ".call applies NFKC so a ligature and a fullwidth letter compare equal to ASCII" do
        assert_equal "fine", NameNormalizer.call("ﬁne")
        assert_equal "A", NameNormalizer.call("Ａ")
      end

      test ".call leaves ordinary text alone" do
        assert_equal "Crime and Punishment", NameNormalizer.call("Crime and Punishment")
      end
    end
  end
end
```

Add to `test/models/books/author_test.rb` (inside the existing `AuthorTest` class):

```ruby
    test "normalizes exotic whitespace in the name on save" do
      author = ::Books::Author.create!(name: "Kathleen Alcott")

      assert_equal "Kathleen Alcott", author.reload.name
    end
```

Add to `test/models/books/book_test.rb` (inside the existing `BookTest` class):

```ruby
    test "normalizes exotic whitespace in the title on save" do
      book = ::Books::Book.create!(title: "The Secret Lives")

      assert_equal "The Secret Lives", book.reload.title
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/text/name_normalizer_test.rb test/models/books/author_test.rb test/models/books/book_test.rb`
Expected: the normalizer tests fail with `NameError: uninitialized constant Services::Text::NameNormalizer`; the two model tests fail on the unnormalized string.

- [ ] **Step 3: Write the implementation**

`app/lib/services/text/name_normalizer.rb`:

```ruby
module Services
  module Text
    # Folds the Unicode variety of "a space" and of composed characters down
    # to one form, so two renderings of the same name or title compare equal.
    # 128 duplicate author groups in the books data came from a U+202F
    # narrow no-break space that an exact-string lookup could not see.
    class NameNormalizer
      # Every Unicode space separator (Zs), plus the zero-width space, the
      # word joiner and the byte-order mark, which are invisible and never
      # meaningful inside a name.
      SPACES = /[\p{Zs}​⁠﻿]+/

      def self.call(text)
        return nil if text.nil?
        return "" if text.empty?

        text.unicode_normalize(:nfkc).gsub(SPACES, " ").squeeze(" ").strip
      end
    end
  end
end
```

`app/models/books/author.rb`, replace lines 75-77:

```ruby
  def normalize_name
    return if name.blank?

    self.name = Services::Text::NameNormalizer.call(Services::Text::QuoteNormalizer.call(name))
  end
```

`app/models/books/book.rb`, replace lines 237-239:

```ruby
  def normalize_title
    return if title.blank?

    self.title = Services::Text::NameNormalizer.call(Services::Text::QuoteNormalizer.call(title))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/text/name_normalizer_test.rb test/models/books/author_test.rb test/models/books/book_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/text/name_normalizer.rb app/models/books/author.rb app/models/books/book.rb test/lib/services/text/name_normalizer_test.rb
git add app/lib/services/text/name_normalizer.rb app/models/books/author.rb app/models/books/book.rb test/lib/services/text/name_normalizer_test.rb test/models/books/author_test.rb test/models/books/book_test.rb
git commit -m "Fold Unicode whitespace in author names and book titles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Expression indexes on `lower(title)` / `lower(name)`

**Files:**
- Create: `db/migrate/<timestamp>_add_lower_title_and_name_indexes_for_finders.rb`
- Modify: `db/schema.rb` (generated)

**Interfaces:**
- Produces: the indexes `index_books_books_on_lower_title`, `index_books_authors_on_lower_name`, `index_music_albums_on_lower_title`, `index_music_artists_on_lower_name`, `index_music_songs_on_lower_title`, `index_games_games_on_lower_title`, `index_games_companies_on_lower_name`. Task 6's `Sources::Exact` queries `LOWER(<column>) = ?`, which these serve.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration AddLowerTitleAndNameIndexesForFinders`

- [ ] **Step 2: Replace the migration body**

```ruby
class AddLowerTitleAndNameIndexesForFinders < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction. books_books holds ~157k
  # rows and music/games are live on this database, so a plain CREATE INDEX
  # would hold a SHARE lock on each table for the build.
  disable_ddl_transaction!

  # The finders' exact source queries LOWER(title) = ? (or LOWER(name) = ?).
  # No table but games_companies has any index on the column, and none has
  # one on the lowercased expression, so today each lookup is a sequential
  # scan. The expression is written to match what the planner records for a
  # varchar column: lower((title)::text).
  INDEXES = [
    [:books_books, "LOWER(title)", "index_books_books_on_lower_title"],
    [:books_authors, "LOWER(name)", "index_books_authors_on_lower_name"],
    [:music_albums, "LOWER(title)", "index_music_albums_on_lower_title"],
    [:music_artists, "LOWER(name)", "index_music_artists_on_lower_name"],
    [:music_songs, "LOWER(title)", "index_music_songs_on_lower_title"],
    [:games_games, "LOWER(title)", "index_games_games_on_lower_title"],
    [:games_companies, "LOWER(name)", "index_games_companies_on_lower_name"]
  ].freeze

  def up
    INDEXES.each do |table, expression, name|
      add_index table, expression, name: name, algorithm: :concurrently, if_not_exists: true
    end
  end

  def down
    INDEXES.each do |table, _expression, name|
      remove_index table, name: name, algorithm: :concurrently, if_exists: true
    end
  end
end
```

- [ ] **Step 3: Migrate and check the schema**

Run: `bin/rails db:migrate` (add `ANNOTATERB_SKIP_ON_DB_TASKS=1` in front if annotaterb errors on the legacy database).
Then: `grep -n "lower_title\|lower_name" db/schema.rb`
Expected: seven `t.index "lower((title)::text)"` / `"lower((name)::text)"` lines, one per table, each with the name above.

- [ ] **Step 4: Confirm the test schema follows and the suite still loads**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: PASS (the test database reloads the schema on its own).

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "Index lower(title) and lower(name) for the finders' exact lookups

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `MatchDecision`

**Files:**
- Create (generator): `app/models/match_decision.rb`, `db/migrate/<timestamp>_create_match_decisions.rb`, `test/models/match_decision_test.rb`, `test/fixtures/match_decisions.yml`
- Modify: `app/models/user.rb:70-75`, `app/models/list_item.rb:44`, `app/models/books/book.rb:105`, `app/models/books/author.rb:45`, `app/models/music/artist.rb:42`, `app/models/music/album.rb:42`, `app/models/music/song.rb:38`, `app/models/games/game.rb:89`, `app/models/games/company.rb` (associations block)

**Interfaces:**
- Produces: `MatchDecision` with enums `outcome {matched: 0, unmatched: 1}`, `confidence {certain: 0, high: 1, medium: 2, low: 3}`, `decided_by {identifier: 0, rule: 1, ai: 2, fallback: 3}` (prefixed: `decided_by_identifier?` …), polymorphic `record` and `subject`, `ai_chat`, `reviewed_by`; scopes `needing_review`, `newest_first`; `#review!(by:, note: nil)`.
- Consumed by Task 9 (`FinderBase#record`), Task 10 (`ImporterBase` updates `record`), Task 4 (`DuplicateCandidate belongs_to :match_decision`).

- [ ] **Step 1: Generate the model**

Run: `bin/rails generate model MatchDecision finder:string`

- [ ] **Step 2: Replace the generated migration body**

```ruby
class CreateMatchDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :match_decisions do |t|
      # The finder class name, so the audit page can filter by domain/entity.
      t.string :finder, null: false
      # The matched record, or the created one once the importer saves it.
      # Nullable: an unmatched decision has no record until the importer
      # creates one, and a finder called on its own never gets one.
      t.references :record, polymorphic: true, null: true
      # What the caller was resolving for (a list item), when it said.
      t.references :subject, polymorphic: true, null: true
      t.integer :outcome, null: false
      t.integer :confidence, null: false
      t.integer :decided_by, null: false
      t.boolean :verify, null: false, default: false
      t.jsonb :query, null: false, default: {}
      t.jsonb :candidates, null: false, default: []
      t.integer :selected_index
      t.text :reason
      t.references :ai_chat, null: true, foreign_key: {on_delete: :nullify}
      t.string :sources_failed, array: true, null: false, default: []
      t.boolean :needs_review, null: false, default: false
      t.datetime :reviewed_at
      t.references :reviewed_by, null: true, foreign_key: {to_table: :users, on_delete: :nullify}
      t.text :review_note

      t.timestamps
    end

    add_index :match_decisions, :finder
    add_index :match_decisions, [:needs_review, :reviewed_at]
    add_index :match_decisions, :created_at
  end
end
```

- [ ] **Step 3: Write the failing model tests**

Replace `test/models/match_decision_test.rb`:

```ruby
require "test_helper"

class MatchDecisionTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
  end

  test "is valid with a finder, outcome, confidence and decided_by and no record" do
    decision = MatchDecision.new(
      finder: "DataImporters::Books::Book::Finder",
      outcome: :unmatched, confidence: :high, decided_by: :rule, reason: "no candidates"
    )

    assert decision.valid?
  end

  test "requires a finder" do
    decision = MatchDecision.new(outcome: :matched, confidence: :certain, decided_by: :identifier)

    assert_not decision.valid?
    assert_includes decision.errors[:finder], "can't be blank"
  end

  test "records a polymorphic record and subject" do
    item = list_items(:music_albums_item)
    decision = MatchDecision.create!(
      finder: "DataImporters::Books::Book::Finder", record: @book, subject: item,
      outcome: :matched, confidence: :certain, decided_by: :identifier
    )

    assert_equal @book, decision.reload.record
    assert_equal item, decision.subject
  end

  test "decided_by predicates are prefixed" do
    decision = MatchDecision.new(finder: "F", outcome: :matched, confidence: :high, decided_by: :ai)

    assert decision.decided_by_ai?
    assert_not decision.decided_by_rule?
  end

  test "needing_review returns only unreviewed rows flagged for review, newest first" do
    old = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true, created_at: 2.days.ago)
    newer = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true, created_at: 1.day.ago)
    MatchDecision.create!(finder: "F", outcome: :matched, confidence: :high, decided_by: :rule, needs_review: false)
    reviewed = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true)
    reviewed.review!(by: users(:admin_user), note: "fine")

    assert_equal [newer, old], MatchDecision.needing_review.newest_first.to_a
  end

  test "review! stamps who, when and the note" do
    decision = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :fallback, needs_review: true)

    decision.review!(by: users(:admin_user), note: "checked")

    decision.reload
    assert_equal users(:admin_user), decision.reviewed_by
    assert_not_nil decision.reviewed_at
    assert_equal "checked", decision.review_note
  end

  test "destroying the record nullifies the decision's record link" do
    game = games_games(:half_life_2)
    RankedItem.where(item: game).destroy_all
    decision = MatchDecision.create!(finder: "F", record: game, outcome: :matched, confidence: :certain, decided_by: :identifier)

    game.destroy!

    assert_nil decision.reload.record_id
  end

  test "destroying the reviewing user nullifies reviewed_by" do
    user = User.create!(email: "reviewer-#{SecureRandom.hex(4)}@example.com", display_name: "R", name: "R")
    decision = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true)
    decision.review!(by: user)

    user.destroy!

    assert_nil decision.reload.reviewed_by_id
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails db:migrate && bin/rails test test/models/match_decision_test.rb`
Expected: failures on the enums, scopes, `review!` and the nullify behaviour (`NoMethodError` / `ArgumentError`), not on the schema.

- [ ] **Step 5: Write the model, the fixture and the associations**

`app/models/match_decision.rb` (keep the annotaterb header the generator/hook produced above the class, if present):

```ruby
class MatchDecision < ApplicationRecord
  # Associations
  belongs_to :record, polymorphic: true, optional: true
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :ai_chat, optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :duplicate_candidates, dependent: :nullify

  # Enums. `unmatched` is the spec's "new": an enum value `new` would define
  # a class-level scope that shadows MatchDecision.new.
  enum :outcome, {matched: 0, unmatched: 1}
  enum :confidence, {certain: 0, high: 1, medium: 2, low: 3}
  enum :decided_by, {identifier: 0, rule: 1, ai: 2, fallback: 3}, prefix: true

  # Validations
  validates :finder, presence: true

  # Scopes
  scope :needing_review, -> { where(needs_review: true, reviewed_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :for_finder, ->(finder_class) { where(finder: finder_class.to_s) }

  def review!(by:, note: nil)
    update!(reviewed_at: Time.current, reviewed_by: by, review_note: note)
  end
end
```

`test/fixtures/match_decisions.yml` (replace the generated `one:`/`two:` rows; keep the schema header if the hook added one):

```yaml
# One low-confidence decision, so later increments' audit pages have a row to
# render. The finders in test create their own rows.
low_confidence_book_match:
  finder: DataImporters::Books::Book::Finder
  record: war_and_peace (Books::Book)
  outcome: 0
  confidence: 3
  decided_by: 2
  verify: false
  query: {"title": "War & Peace", "author_names": ["Tolstoy"]}
  candidates: [{"record_type": "Books::Book", "record_id": 1, "sources": ["opensearch"], "scores": {"opensearch": 7.2}, "evidence": {"title": "War and Peace"}}]
  selected_index: 1
  reason: "Same title and author; year missing on the incoming item."
  needs_review: true
```

The fixture's `record_id` inside `candidates` is illustrative JSON, not a foreign key.

Associations. `app/models/user.rb`, after line 74 (`has_many :granted_memberships …`):

```ruby
  has_many :reviewed_match_decisions, class_name: "MatchDecision", foreign_key: :reviewed_by_id, dependent: :nullify
```

`app/models/list_item.rb`, after line 44 (`belongs_to :listable …`):

```ruby
  has_many :match_decisions, as: :subject, dependent: :nullify
```

Add the same line, with `as: :record`, next to `has_many :ai_chats` (or the last `has_many`) in each of the seven importable models:

```ruby
  has_many :match_decisions, as: :record, dependent: :nullify
```

Files: `app/models/books/book.rb` (after line 105), `app/models/books/author.rb` (after line 45), `app/models/music/artist.rb` (after line 42), `app/models/music/album.rb` (after line 42), `app/models/music/song.rb` (after line 38), `app/models/games/game.rb` (after line 89), `app/models/games/company.rb` (after its last `has_many`).

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/match_decision_test.rb test/models/user_test.rb test/models/list_item_test.rb`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/models/match_decision.rb app/models/user.rb app/models/list_item.rb app/models/books app/models/music app/models/games test/models/match_decision_test.rb
git add app/models db/migrate db/schema.rb test/models/match_decision_test.rb test/fixtures/match_decisions.yml
git commit -m "Add match_decisions: one row per finder call

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `DuplicateCandidate`

**Files:**
- Create (generator): `app/models/duplicate_candidate.rb`, `db/migrate/<timestamp>_create_duplicate_candidates.rb`, `test/models/duplicate_candidate_test.rb`, `test/fixtures/duplicate_candidates.yml`
- Modify: `app/models/user.rb` (one `has_many`)

**Interfaces:**
- Produces:
  - `DuplicateCandidate.flag!(item_type:, ids:, source:, evidence: {}, match_decision: nil) -> DuplicateCandidate | nil` (nil when both ids are equal; never reopens a `merged` or `not_duplicate` row; bumps `occurrences` and merges evidence on a `pending` row).
  - `DuplicateCandidate.record_merge(item_type:, source_id:, target_id:) -> void` (marks the pair merged, repoints other pending pairs, repoints `match_decisions.record`).
  - `DuplicateCandidate.not_duplicate?(item_type:, ids:) -> Boolean`.
  - Enums `source {identifier_collision: 0, external_key_collision: 1, ai: 2, human: 3, bulk_verify: 4}` (prefix `raised_by`), `status {pending: 0, merged: 1, not_duplicate: 2}`.
- Consumed by Task 9 (flagging) and Task 12 (mergers).

- [ ] **Step 1: Generate the model**

Run: `bin/rails generate model DuplicateCandidate item_type:string`

- [ ] **Step 2: Replace the generated migration body**

```ruby
class CreateDuplicateCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :duplicate_candidates do |t|
      # Both records share item_type. No foreign keys on the ids, matching
      # ranked_items: a merge destroys one side and the row is history.
      t.string :item_type, null: false
      t.bigint :item_a_id, null: false
      t.bigint :item_b_id, null: false
      t.integer :source, null: false
      t.integer :status, null: false, default: 0
      t.jsonb :evidence, null: false, default: {}
      t.integer :occurrences, null: false, default: 1
      t.references :match_decision, null: true, foreign_key: {on_delete: :nullify}
      t.datetime :resolved_at
      t.references :resolved_by, null: true, foreign_key: {to_table: :users, on_delete: :nullify}
      t.text :resolution_note

      t.timestamps
    end

    # One row per unordered pair: a < b is enforced, so (a, b) is canonical.
    add_check_constraint :duplicate_candidates, "item_a_id < item_b_id", name: "duplicate_candidates_a_before_b"
    add_index :duplicate_candidates, [:item_type, :item_a_id, :item_b_id], unique: true, name: "index_duplicate_candidates_on_pair"
    add_index :duplicate_candidates, [:item_type, :item_b_id], name: "index_duplicate_candidates_on_type_and_b"
    add_index :duplicate_candidates, [:status, :created_at]
  end
end
```

- [ ] **Step 3: Write the failing model tests**

Replace `test/models/duplicate_candidate_test.rb`:

```ruby
require "test_helper"

class DuplicateCandidateTest < ActiveSupport::TestCase
  def setup
    @a = games_games(:resident_evil_4)
    @b = games_games(:resident_evil_4_remake)
    @c = games_games(:half_life_2)
    @type = "Games::Game"
  end

  test "flag! creates a pending row with the ids in ascending order whatever order they arrive in" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@b.id, @a.id], source: :ai, evidence: {reason: "same title"})

    assert row.persisted?
    assert row.pending?
    assert row.raised_by_ai?
    assert_equal [@a.id, @b.id].minmax, [row.item_a_id, row.item_b_id]
    assert_equal 1, row.occurrences
    assert_equal({"reason" => "same title"}, row.evidence)
  end

  test "flag! returns nil and writes nothing when both ids are the same record" do
    assert_nil DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @a.id], source: :ai)
    assert_equal 0, DuplicateCandidate.count
  end

  test "flag! on a pending pair bumps occurrences and merges evidence instead of creating a second row" do
    DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai, evidence: {reason: "first"})

    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :identifier_collision, evidence: {identifier: "igdb 1"})

    assert_equal 1, DuplicateCandidate.count
    assert_equal 2, row.occurrences
    assert_equal({"reason" => "first", "identifier" => "igdb 1"}, row.evidence)
    assert row.raised_by_ai?, "the first source is kept"
  end

  test "flag! never reopens a pair a human ruled not a duplicate" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    row.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: users(:admin_user))

    again = DuplicateCandidate.flag!(item_type: @type, ids: [@b.id, @a.id], source: :ai, evidence: {reason: "again"})

    assert_equal row, again
    assert again.reload.not_duplicate?
    assert_equal 1, again.occurrences
    assert_equal({}, again.evidence)
  end

  test "flag! leaves a merged pair alone" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    row.update!(status: :merged)

    again = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)

    assert again.merged?
    assert_equal 1, again.occurrences
  end

  test "not_duplicate? is true only for a pair a human dismissed" do
    assert_not DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@a.id, @b.id])
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    assert_not DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@b.id, @a.id])

    row.update!(status: :not_duplicate)

    assert DuplicateCandidate.not_duplicate?(item_type: @type, ids: [@b.id, @a.id])
  end

  test "record_merge marks the merged pair, repoints other pending pairs to the survivor and repoints decisions" do
    merged_pair = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @b.id], source: :ai)
    other_pair = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @c.id], source: :ai)
    decision = MatchDecision.create!(finder: "F", record: @a, outcome: :matched, confidence: :high, decided_by: :ai)

    DuplicateCandidate.record_merge(item_type: @type, source_id: @a.id, target_id: @b.id)

    assert merged_pair.reload.merged?
    assert_not_nil merged_pair.resolved_at
    other_pair.reload
    assert_equal [@b.id, @c.id].minmax, [other_pair.item_a_id, other_pair.item_b_id]
    assert other_pair.pending?
    assert_equal @b.id, decision.reload.record_id
    assert_equal @type, decision.record_type
  end

  test "record_merge drops a repointed pair that would collide with an existing row" do
    DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @c.id], source: :ai)
    survivor_pair = DuplicateCandidate.flag!(item_type: @type, ids: [@b.id, @c.id], source: :ai)

    DuplicateCandidate.record_merge(item_type: @type, source_id: @a.id, target_id: @b.id)

    assert_equal [survivor_pair], DuplicateCandidate.pending.to_a
  end

  test "record_merge leaves a not_duplicate pair that named the source alone" do
    row = DuplicateCandidate.flag!(item_type: @type, ids: [@a.id, @c.id], source: :ai)
    row.update!(status: :not_duplicate)

    DuplicateCandidate.record_merge(item_type: @type, source_id: @a.id, target_id: @b.id)

    row.reload
    assert row.not_duplicate?
    assert_equal [@a.id, @c.id].minmax, [row.item_a_id, row.item_b_id]
  end

  test "the database refuses a pair whose ids are out of order" do
    assert_raises(ActiveRecord::StatementInvalid) do
      DuplicateCandidate.insert_all([{item_type: @type, item_a_id: @b.id, item_b_id: @a.id, source: 2, status: 0, created_at: Time.current, updated_at: Time.current}])
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails db:migrate && bin/rails test test/models/duplicate_candidate_test.rb`
Expected: `NoMethodError` on `flag!`, `record_merge`, `not_duplicate?`, `pending?`.

- [ ] **Step 5: Write the model, fixture and association**

`app/models/duplicate_candidate.rb`:

```ruby
class DuplicateCandidate < ApplicationRecord
  # Associations
  belongs_to :match_decision, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  # Enums. `pending` is the spec's "open".
  enum :source, {identifier_collision: 0, external_key_collision: 1, ai: 2, human: 3, bulk_verify: 4}, prefix: :raised_by
  enum :status, {pending: 0, merged: 1, not_duplicate: 2}

  # Validations
  validates :item_type, presence: true
  validates :item_a_id, :item_b_id, presence: true
  validates :item_b_id, uniqueness: {scope: [:item_type, :item_a_id]}
  validate :ids_in_order

  # Scopes
  scope :for_type, ->(item_type) { where(item_type: item_type) }
  scope :newest_first, -> { order(created_at: :desc) }

  # Raise (or re-raise) a suspected pair. Ids may arrive in any order. A pair
  # a human dismissed is never reopened, and a merged one is left alone; a
  # pending one gains an occurrence and any new evidence.
  def self.flag!(item_type:, ids:, source:, evidence: {}, match_decision: nil)
    a, b = ids.map(&:to_i).minmax
    return nil if a == b

    row = find_or_initialize_by(item_type: item_type, item_a_id: a, item_b_id: b)
    if row.persisted?
      return row unless row.pending?

      row.occurrences += 1
      row.evidence = merge_evidence(row.evidence, evidence)
      row.save!
      return row
    end

    row.assign_attributes(source: source, evidence: evidence.deep_stringify_keys, match_decision: match_decision, status: :pending, occurrences: 1)
    row.save!
    row
  end

  def self.not_duplicate?(item_type:, ids:)
    a, b = ids.map(&:to_i).minmax
    where(item_type: item_type, item_a_id: a, item_b_id: b).not_duplicate.exists?
  end

  # Called by every merger inside its transaction, before the source row is
  # destroyed. The (source, target) pair itself becomes `merged`; every other
  # PENDING pair naming the source is re-keyed onto the target unless a row
  # for that pair already exists, in which case the stale one is dropped.
  # Decisions whose record was the source now point at the target.
  def self.record_merge(item_type:, source_id:, target_id:)
    a, b = [source_id, target_id].minmax
    where(item_type: item_type, item_a_id: a, item_b_id: b)
      .update_all(status: statuses[:merged], resolved_at: Time.current, updated_at: Time.current)

    where(item_type: item_type, status: statuses[:pending])
      .where("item_a_id = :id OR item_b_id = :id", id: source_id)
      .find_each do |row|
        other = (row.item_a_id == source_id) ? row.item_b_id : row.item_a_id
        next row.destroy! if other == target_id

        new_a, new_b = [other, target_id].minmax
        if exists?(item_type: item_type, item_a_id: new_a, item_b_id: new_b)
          row.destroy!
        else
          row.update!(item_a_id: new_a, item_b_id: new_b)
        end
      end

    MatchDecision.where(record_type: item_type, record_id: source_id)
      .update_all(record_id: target_id, updated_at: Time.current)
  end

  def self.merge_evidence(existing, incoming)
    existing.merge(incoming.deep_stringify_keys) do |_key, old, new|
      (old.is_a?(Array) && new.is_a?(Array)) ? (old | new) : new
    end
  end
  private_class_method :merge_evidence

  private

  def ids_in_order
    return if item_a_id.blank? || item_b_id.blank?

    errors.add(:item_b_id, "must be greater than item_a_id") unless item_a_id < item_b_id
  end
end
```

`test/fixtures/duplicate_candidates.yml` (replace the generated rows):

```yaml
# The two "Resident Evil 4" game fixtures are a ready-made same-title pair.
# Ids are fixture-hash ids, so item_a_id/item_b_id are set through ERB in
# ascending order.
<% a, b = [ActiveRecord::FixtureSet.identify(:resident_evil_4), ActiveRecord::FixtureSet.identify(:resident_evil_4_remake)].minmax %>
resident_evil_4_pair:
  item_type: Games::Game
  item_a_id: <%= a %>
  item_b_id: <%= b %>
  source: 2
  status: 0
  evidence: {"reason": "same title, different release year"}
  occurrences: 1
```

`app/models/user.rb`, after the `reviewed_match_decisions` line added in Task 3:

```ruby
  has_many :resolved_duplicate_candidates, class_name: "DuplicateCandidate", foreign_key: :resolved_by_id, dependent: :nullify
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/duplicate_candidate_test.rb test/models/user_test.rb`
Expected: PASS. If the fixture pair collides with a test that flags the same two games, the tests above use `flag!`, which finds the fixture row; if that makes a count assertion off by one, change the fixture to name `resident_evil_4` and `half_life_2`... no: keep the fixture and instead start the two `count`-asserting tests with `DuplicateCandidate.delete_all` is forbidden outside `RAILS_ENV=test`? It is allowed in tests, but simpler: the tests above pair `@a` with `@b` and the fixture pairs the same two games, so replace the fixture's second game with `half_life_2` and in the test that asserts `assert_equal [survivor_pair], DuplicateCandidate.pending.to_a` use `DuplicateCandidate.pending.where.not(id: duplicate_candidates(:resident_evil_4_pair).id).to_a`. Apply whichever of the two the first run shows is needed and note it in the task report.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/models/duplicate_candidate.rb app/models/user.rb test/models/duplicate_candidate_test.rb
git add app/models db/migrate db/schema.rb test/models/duplicate_candidate_test.rb test/fixtures/duplicate_candidates.yml
git commit -m "Add duplicate_candidates: suspected pairs with a never-re-raise verdict

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `Match`, `Candidate`, `CandidateSet`, `Decision`

**Files:**
- Create: `app/lib/data_importers/match.rb`, `app/lib/data_importers/candidate.rb`, `app/lib/data_importers/candidate_set.rb`, `app/lib/data_importers/decision.rb`
- Test: `test/lib/data_importers/match_test.rb`, `test/lib/data_importers/candidate_test.rb`, `test/lib/data_importers/candidate_set_test.rb`

**Interfaces:**
- Produces:
  - `DataImporters::Match` (Struct, keyword_init): `outcome`, `record`, `confidence`, `decided_by`, `reason`, `candidates`, `external`, `external_resolution`, `decision`, `sources_failed`; `#matched?`, `#unmatched?`, `#needs_review?`.
  - `DataImporters::Candidate` (Struct, keyword_init): `record`, `external_key`, `external_source`, `external_record`, `sources`, `scores`, `evidence`, `decisive`; `#local?`, `#external?`, `#decisive?`, `#ranked?`, `#external_verdict`, `#external_accepted?`, `#absorb(other)`, `#snapshot`.
  - `DataImporters::CandidateSet`: `#add(candidate)`, `#to_a`, `#locals`, `#size`, `#empty?`.
  - `DataImporters::Decision` (Struct, keyword_init): `outcome`, `record`, `confidence`, `decided_by`, `reason`, `external`, `selected_index`, `duplicate_pairs` (array of `[record_a, record_b, source_symbol]`); `Decision.fallback(reason)`.

- [ ] **Step 1: Write the failing tests**

`test/lib/data_importers/match_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class MatchTest < ActiveSupport::TestCase
    test "matched? and unmatched? read the outcome" do
      assert Match.new(outcome: :matched, record: books_books(:war_and_peace)).matched?
      assert Match.new(outcome: :unmatched).unmatched?
      assert_not Match.new(outcome: :unmatched).matched?
    end

    test "needs_review? is true for medium or low confidence and for a fallback decision" do
      assert Match.new(outcome: :matched, confidence: :medium, decided_by: :ai).needs_review?
      assert Match.new(outcome: :unmatched, confidence: :low, decided_by: :ai).needs_review?
      assert Match.new(outcome: :unmatched, confidence: :low, decided_by: :fallback).needs_review?
      assert_not Match.new(outcome: :matched, confidence: :certain, decided_by: :identifier).needs_review?
      assert_not Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule).needs_review?
    end

    test "defaults candidates and sources_failed to empty arrays" do
      match = Match.new(outcome: :unmatched)

      assert_equal [], match.candidates
      assert_equal [], match.sources_failed
    end
  end
end
```

`test/lib/data_importers/candidate_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class CandidateTest < ActiveSupport::TestCase
    def setup
      @book = books_books(:war_and_peace)
    end

    test "local? and external? describe which halves are present" do
      local = Candidate.new(record: @book, sources: [:exact])
      external = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library])
      both = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library)

      assert local.local?
      assert_not local.external?
      assert_not external.local?
      assert external.external?
      assert both.local?
      assert both.external?
    end

    test "defaults sources, scores and evidence, and decisive is false" do
      candidate = Candidate.new(record: @book)

      assert_equal [], candidate.sources
      assert_equal({}, candidate.scores)
      assert_equal({}, candidate.evidence)
      assert_not candidate.decisive?
    end

    test "ranked? reads the ranked_position evidence" do
      assert Candidate.new(record: @book, evidence: {ranked_position: 12}).ranked?
      assert_not Candidate.new(record: @book, evidence: {ranked_position: nil}).ranked?
    end

    test "external_accepted? reads the external_verdict evidence" do
      assert Candidate.new(external_key: "OL1W", evidence: {external_verdict: "accept"}).external_accepted?
      assert_not Candidate.new(external_key: "OL1W", evidence: {external_verdict: "abstain"}).external_accepted?
    end

    test "absorb unions sources, merges scores and evidence, fills missing halves and keeps decisive if either is" do
      local = Candidate.new(record: @book, sources: [:exact], scores: {}, evidence: {title: "War and Peace", year: 1869})
      external = Candidate.new(
        record: @book, external_key: "OL1W", external_source: :open_library,
        sources: [:open_library], scores: {open_library: 0.9}, evidence: {external_verdict: "accept", year: nil}, decisive: true
      )

      local.absorb(external)

      assert_equal [:exact, :open_library], local.sources
      assert_equal({open_library: 0.9}, local.scores)
      assert_equal "OL1W", local.external_key
      assert_equal :open_library, local.external_source
      assert_equal 1869, local.evidence[:year], "an absorbed nil never overwrites a value"
      assert_equal "accept", local.evidence[:external_verdict]
      assert local.decisive?
    end

    test "snapshot is JSON-safe and carries no record object" do
      candidate = Candidate.new(
        record: @book, external_key: "OL1W", external_source: :open_library,
        sources: [:exact, :open_library], scores: {opensearch: 7.5}, evidence: {title: "War and Peace", creators: ["Leo Tolstoy"]}
      )

      snapshot = candidate.snapshot

      assert_equal "Books::Book", snapshot[:record_type]
      assert_equal @book.id, snapshot[:record_id]
      assert_equal "open_library", snapshot[:external_source]
      assert_equal "OL1W", snapshot[:external_key]
      assert_equal %w[exact open_library], snapshot[:sources]
      assert_equal({"opensearch" => 7.5}, snapshot[:scores])
      assert_equal({"title" => "War and Peace", "creators" => ["Leo Tolstoy"]}, snapshot[:evidence])
      assert_nothing_raised { JSON.generate(snapshot) }
    end
  end
end
```

`test/lib/data_importers/candidate_set_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class CandidateSetTest < ActiveSupport::TestCase
    def setup
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
    end

    test "merges two candidates for the same local record into one" do
      set = CandidateSet.new
      set.add(Candidate.new(record: @book, sources: [:exact]))
      set.add(Candidate.new(record: @book, sources: [:opensearch], scores: {opensearch: 9.1}))

      assert_equal 1, set.size
      assert_equal [:exact, :opensearch], set.to_a.first.sources
      assert_equal({opensearch: 9.1}, set.to_a.first.scores)
    end

    test "merges two candidates for the same external key into one" do
      set = CandidateSet.new
      set.add(Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library]))
      set.add(Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:musicbrainz]))

      assert_equal 1, set.size
      assert_equal [:open_library, :musicbrainz], set.to_a.first.sources
    end

    test "an external candidate that later turns out to be a known local record folds into the local one" do
      set = CandidateSet.new
      set.add(Candidate.new(record: @book, sources: [:opensearch]))
      set.add(Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library]))
      set.add(Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library]))

      assert_equal 1, set.size
      merged = set.to_a.first
      assert_equal @book, merged.record
      assert_equal "OL1W", merged.external_key
      assert_equal [:opensearch, :open_library], merged.sources
    end

    test "keeps distinct records and distinct keys apart, in insertion order" do
      set = CandidateSet.new
      set.add(Candidate.new(record: @book, sources: [:exact]))
      set.add(Candidate.new(record: @other, sources: [:exact]))
      set.add(Candidate.new(external_key: "OL9W", external_source: :open_library, sources: [:open_library]))

      assert_equal 3, set.size
      assert_equal [@book, @other, nil], set.to_a.map(&:record)
      assert_equal [@book, @other], set.locals.map(&:record)
    end

    test "empty? and size" do
      set = CandidateSet.new

      assert set.empty?
      set.add(Candidate.new(record: @book))
      assert_not set.empty?
      assert_equal 1, set.size
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/match_test.rb test/lib/data_importers/candidate_test.rb test/lib/data_importers/candidate_set_test.rb`
Expected: `NameError: uninitialized constant DataImporters::Match` (and the same for `Candidate`, `CandidateSet`).

- [ ] **Step 3: Write the value objects**

`app/lib/data_importers/match.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # What a finder returns: the decision, the record it names (nil when
  # unmatched), how sure it is, who decided, why, and what it considered.
  # `external` is the best external candidate to hydrate from when
  # unmatched; `external_resolution` is a whole external response a source
  # kept for the provider (books: the Open Library Resolution); `decision`
  # is the persisted MatchDecision.
  Match = Struct.new(
    :outcome, :record, :confidence, :decided_by, :reason, :candidates,
    :external, :external_resolution, :decision, :sources_failed,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.candidates ||= []
      self.sources_failed ||= []
    end

    def matched?
      outcome == :matched
    end

    def unmatched?
      outcome == :unmatched
    end

    def needs_review?
      %i[medium low].include?(confidence) || decided_by == :fallback
    end
  end
end
```

`app/lib/data_importers/candidate.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # One thing a finder considered: a local record, an external record, or
  # both once an external key turns out to be held locally. `sources` names
  # every source that reached it; `scores` is per source; `evidence` is a
  # JSON-safe hash the rules and the AI prompt read (title, creators, year,
  # ranked_position, identifiers, external_verdict, ...).
  Candidate = Struct.new(
    :record, :external_key, :external_source, :external_record,
    :sources, :scores, :evidence, :decisive,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.sources ||= []
      self.scores ||= {}
      self.evidence ||= {}
      self.decisive = false if decisive.nil?
    end

    def local?
      !record.nil?
    end

    def external?
      !external_key.nil?
    end

    def decisive?
      decisive == true
    end

    def ranked?
      evidence[:ranked_position].present?
    end

    def external_verdict
      evidence[:external_verdict]
    end

    def external_accepted?
      external_verdict == "accept"
    end

    # Fold another candidate for the same thing into this one. A present
    # value is never overwritten by an absent one.
    def absorb(other)
      self.record ||= other.record
      self.external_key ||= other.external_key
      self.external_source ||= other.external_source
      self.external_record ||= other.external_record
      self.sources = sources | other.sources
      self.scores = scores.merge(other.scores)
      self.evidence = evidence.merge(other.evidence) { |_key, mine, theirs| mine.nil? ? theirs : mine }
      self.decisive = decisive? || other.decisive?
      self
    end

    # The JSON stored on match_decisions.candidates: ids and evidence only,
    # never the record or the external payload.
    def snapshot
      {
        record_type: record&.class&.name,
        record_id: record&.id,
        external_source: external_source&.to_s,
        external_key: external_key,
        sources: sources.map(&:to_s),
        scores: scores.deep_stringify_keys,
        evidence: evidence.deep_stringify_keys
      }
    end
  end
end
```

`app/lib/data_importers/candidate_set.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # The union of every source's candidates, merged by local record or by
  # external key. Insertion order is kept, which is the order sources ran.
  class CandidateSet
    def initialize
      @candidates = []
    end

    def add(candidate)
      by_record = candidate.local? ? find_local(candidate.record) : nil
      by_key = candidate.external? ? find_external(candidate.external_source, candidate.external_key) : nil

      if by_record && by_key && !by_record.equal?(by_key)
        # A local candidate and an external-only candidate turn out to be
        # the same thing: fold the external one into the local one.
        by_record.absorb(by_key)
        @candidates.delete(by_key)
        by_record.absorb(candidate)
      elsif by_record
        by_record.absorb(candidate)
      elsif by_key
        by_key.absorb(candidate)
      else
        @candidates << candidate
      end
    end

    def to_a
      @candidates.dup
    end

    def locals
      @candidates.select(&:local?)
    end

    def size
      @candidates.size
    end

    def empty?
      @candidates.empty?
    end

    private

    def find_local(record)
      @candidates.find { |c| c.local? && c.record.class == record.class && c.record.id == record.id }
    end

    def find_external(source, key)
      @candidates.find { |c| c.external? && c.external_source == source && c.external_key == key }
    end
  end
end
```

`app/lib/data_importers/decision.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # The outcome the rules or the AI settled on, before it is recorded.
  # `duplicate_pairs` is a list of [record_a, record_b, source_symbol] the
  # finder turns into DuplicateCandidate rows.
  Decision = Struct.new(
    :outcome, :record, :confidence, :decided_by, :reason,
    :external, :selected_index, :duplicate_pairs,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.duplicate_pairs ||= []
    end

    def self.fallback(reason)
      new(outcome: :unmatched, record: nil, confidence: :low, decided_by: :fallback, reason: reason)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/match_test.rb test/lib/data_importers/candidate_test.rb test/lib/data_importers/candidate_set_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS; zeitwerk clean.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/match.rb app/lib/data_importers/candidate.rb app/lib/data_importers/candidate_set.rb app/lib/data_importers/decision.rb test/lib/data_importers
git add app/lib/data_importers/match.rb app/lib/data_importers/candidate.rb app/lib/data_importers/candidate_set.rb app/lib/data_importers/decision.rb test/lib/data_importers/match_test.rb test/lib/data_importers/candidate_test.rb test/lib/data_importers/candidate_set_test.rb
git commit -m "Finder value objects: Match, Candidate, CandidateSet, Decision

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The candidate sources

**Files:**
- Create: `app/lib/data_importers/sources/identifiers.rb`, `app/lib/data_importers/sources/exact.rb`, `app/lib/data_importers/sources/open_search.rb`, `app/lib/data_importers/sources/legacy.rb`
- Test: `test/lib/data_importers/sources/identifiers_test.rb`, `test/lib/data_importers/sources/exact_test.rb`, `test/lib/data_importers/sources/open_search_test.rb`, `test/lib/data_importers/sources/legacy_test.rb`

**Interfaces:**
- Produces, each with `#name -> Symbol` and `#call -> [Candidate]`:
  - `Sources::Identifiers.new(model_class:, lookups:)` — `lookups` is `[[identifier_type_symbol, value_string], ...]` in priority order; name `:identifier`; evidence `{matched_identifier: {type:, value:}}`.
  - `Sources::Exact.new(scope:, limit: 5)` — `scope` is an `ActiveRecord::Relation`; name `:exact`.
  - `Sources::OpenSearch.new(model_class:, search_class:, params:, size: 5, min_score: nil, includes: [])` — calls `search_class.call(**params, size:, [min_score:])`, loads the hits; name `:opensearch`; scores `{opensearch: score}`.
  - `Sources::Legacy.new { record_or_nil }` — name `:legacy`; one decisive candidate or none.

- [ ] **Step 1: Write the failing tests**

`test/lib/data_importers/sources/identifiers_test.rb`:

```ruby
require "test_helper"

module DataImporters
  module Sources
    class IdentifiersTest < ActiveSupport::TestCase
      test "returns one candidate per matching identifier, in lookup order, with the identifier as evidence" do
        source = Identifiers.new(
          model_class: ::Books::Book,
          lookups: [[:books_work_openlibrary_id, "OL262758W"], [:books_work_isbn13, "9780140447934"]]
        )

        candidates = source.call

        assert_equal [books_books(:crime_and_punishment), books_books(:war_and_peace)], candidates.map(&:record)
        assert_equal [[:identifier]] * 2, candidates.map(&:sources)
        assert_equal({matched_identifier: {type: "books_work_openlibrary_id", value: "OL262758W"}}, candidates.first.evidence)
        assert_not candidates.first.decisive?, "decisiveness is the finder's call, after corroboration"
      end

      test "returns nothing for values nobody holds" do
        source = Identifiers.new(model_class: ::Books::Book, lookups: [[:books_work_isbn13, "0000000000000"]])

        assert_equal [], source.call
      end

      test "only looks inside the given model class" do
        source = Identifiers.new(model_class: ::Music::Album, lookups: [[:books_work_isbn13, "9780140447934"]])

        assert_equal [], source.call
      end

      test "returns every record sharing a value, so a collision is visible" do
        other = books_books(:crime_and_punishment)
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780140447934")
        source = Identifiers.new(model_class: ::Books::Book, lookups: [[:books_work_isbn13, "9780140447934"]])

        records = source.call.map(&:record)

        assert_equal 2, records.size
        assert_includes records, books_books(:war_and_peace)
        assert_includes records, other
      end

      test "name is :identifier" do
        assert_equal :identifier, Identifiers.new(model_class: ::Books::Book, lookups: []).name
      end
    end
  end
end
```

`test/lib/data_importers/sources/exact_test.rb`:

```ruby
require "test_helper"

module DataImporters
  module Sources
    class ExactTest < ActiveSupport::TestCase
      test "returns the scope's records as :exact candidates, capped at the limit" do
        scope = ::Books::Book.where("LOWER(books_books.title) = LOWER(?)", "war and peace")

        candidates = Exact.new(scope: scope).call

        assert_equal [books_books(:war_and_peace)], candidates.map(&:record)
        assert_equal [:exact], candidates.first.sources
      end

      test "returns nothing for an empty scope" do
        assert_equal [], Exact.new(scope: ::Books::Book.where(title: "no such title")).call
      end

      test "caps the number of candidates" do
        candidates = Exact.new(scope: ::Books::Book.all, limit: 2).call

        assert_equal 2, candidates.size
      end

      test "name is :exact" do
        assert_equal :exact, Exact.new(scope: ::Books::Book.none).name
      end
    end
  end
end
```

`test/lib/data_importers/sources/open_search_test.rb`:

```ruby
require "test_helper"

module DataImporters
  module Sources
    class OpenSearchTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
      end

      test "calls the search class with the params plus size, loads the hits and scores them" do
        ::Search::Music::Search::AlbumByTitleAndArtists.expects(:call)
          .with(title: "War and Peace", artists: ["Leo Tolstoy"], size: 5)
          .returns([{id: @book.id.to_s, score: 9.5, source: {}}, {id: @other.id.to_s, score: 6.1, source: {}}])

        candidates = OpenSearch.new(
          model_class: ::Books::Book,
          search_class: ::Search::Music::Search::AlbumByTitleAndArtists,
          params: {title: "War and Peace", artists: ["Leo Tolstoy"]}
        ).call

        assert_equal [@book, @other], candidates.map(&:record)
        assert_equal [{opensearch: 9.5}, {opensearch: 6.1}], candidates.map(&:scores)
        assert_equal [[:opensearch]] * 2, candidates.map(&:sources)
      end

      test "passes min_score through when given" do
        ::Search::Music::Search::AlbumByTitleAndArtists.expects(:call)
          .with(title: "x", artists: [], size: 3, min_score: 4.0).returns([])

        OpenSearch.new(
          model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists,
          params: {title: "x", artists: []}, size: 3, min_score: 4.0
        ).call
      end

      test "drops a hit whose record no longer exists" do
        ::Search::Music::Search::AlbumByTitleAndArtists.stubs(:call).returns([{id: "0", score: 9.5, source: {}}, {id: @book.id.to_s, score: 8.0, source: {}}])

        candidates = OpenSearch.new(model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists, params: {title: "x", artists: []}).call

        assert_equal [@book], candidates.map(&:record)
      end

      test "returns nothing without calling the search when params are nil" do
        ::Search::Music::Search::AlbumByTitleAndArtists.expects(:call).never

        assert_equal [], OpenSearch.new(model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists, params: nil).call
      end

      test "lets a search error propagate so the finder can record the failed source" do
        ::Search::Music::Search::AlbumByTitleAndArtists.stubs(:call).raises(StandardError, "opensearch down")

        assert_raises(StandardError) do
          OpenSearch.new(model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists, params: {title: "x", artists: []}).call
        end
      end

      test "name is :opensearch" do
        assert_equal :opensearch, OpenSearch.new(model_class: ::Books::Book, search_class: nil, params: nil).name
      end
    end
  end
end
```

`test/lib/data_importers/sources/legacy_test.rb`:

```ruby
require "test_helper"

module DataImporters
  module Sources
    class LegacyTest < ActiveSupport::TestCase
      test "wraps a found record as one decisive :legacy candidate" do
        book = books_books(:war_and_peace)

        candidates = Legacy.new { book }.call

        assert_equal 1, candidates.size
        assert_equal book, candidates.first.record
        assert_equal [:legacy], candidates.first.sources
        assert candidates.first.decisive?
      end

      test "returns nothing when the lookup finds nothing" do
        assert_equal [], Legacy.new { nil }.call
      end

      test "runs the lookup lazily, once per call" do
        calls = 0
        source = Legacy.new { calls += 1; nil }

        assert_equal 0, calls
        source.call
        assert_equal 1, calls
      end

      test "name is :legacy" do
        assert_equal :legacy, Legacy.new { nil }.name
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/sources`
Expected: `NameError: uninitialized constant DataImporters::Sources`.

- [ ] **Step 3: Write the sources**

`app/lib/data_importers/sources/identifiers.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Sources
    # Postgres lookup of the query's identifier values, in the domain's
    # priority order, through the (identifiable_type, value) index. Two
    # records carrying the same value both come back: the unique index on
    # identifiers includes identifiable_id, so it allows that, and the
    # finder wants to see the collision. Never marks a candidate decisive;
    # whether an identifier hit can be trusted is the finder's corroboration
    # call.
    class Identifiers
      def initialize(model_class:, lookups:)
        @model_class = model_class
        @lookups = lookups
      end

      def name
        :identifier
      end

      def call
        @lookups.flat_map do |identifier_type, value|
          ::Identifier
            .includes(:identifiable)
            .where(identifiable_type: @model_class.name, identifier_type: identifier_type, value: value)
            .order(:identifiable_id)
            .map do |identifier|
              Candidate.new(
                record: identifier.identifiable,
                sources: [:identifier],
                evidence: {matched_identifier: {type: identifier_type.to_s, value: value}}
              )
            end
        end
      end
    end
  end
end
```

`app/lib/data_importers/sources/exact.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Sources
    # One Postgres query the finder builds (normalized title or name
    # equality, joined to a creator when the query has one). Kept alongside
    # OpenSearch because the search index is written by a queued job, so a
    # record created seconds ago is not yet searchable.
    class Exact
      def initialize(scope:, limit: 5)
        @scope = scope
        @limit = limit
      end

      def name
        :exact
      end

      def call
        @scope.limit(@limit).map { |record| Candidate.new(record: record, sources: [:exact]) }
      end
    end
  end
end
```

`app/lib/data_importers/sources/open_search.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Sources
    # The domain's title-plus-creators dedup query. `params` is the keyword
    # hash the search class takes (nil when the query has nothing to
    # search on). Hits are loaded as records; a hit whose record is gone is
    # dropped. A search error propagates so the finder records the source
    # as failed.
    class OpenSearch
      def initialize(model_class:, search_class:, params:, size: 5, min_score: nil, includes: [])
        @model_class = model_class
        @search_class = search_class
        @params = params
        @size = size
        @min_score = min_score
        @includes = includes
      end

      def name
        :opensearch
      end

      def call
        return [] if @params.nil?

        options = {size: @size}
        options[:min_score] = @min_score if @min_score
        hits = @search_class.call(**@params, **options)
        return [] if hits.empty?

        records = @model_class.where(id: hits.map { |hit| hit[:id].to_i })
        records = records.includes(*@includes) if @includes.any?
        by_id = records.index_by(&:id)

        hits.filter_map do |hit|
          record = by_id[hit[:id].to_i]
          next unless record

          Candidate.new(record: record, sources: [:opensearch], scores: {opensearch: hit[:score]})
        end
      end
    end
  end
end
```

`app/lib/data_importers/sources/legacy.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Sources
    # Increment 1 only: a domain finder's pre-redesign lookup, wrapped as the
    # single, decisive source so the pipeline runs for real while behaviour
    # stays exactly what it was. Each domain's increment replaces it with the
    # real sources and deletes the lookup it wraps.
    class Legacy
      def initialize(&lookup)
        @lookup = lookup
      end

      def name
        :legacy
      end

      def call
        record = @lookup.call
        return [] unless record

        [Candidate.new(record: record, sources: [:legacy], decisive: true)]
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/sources && CI=1 bin/rails zeitwerk:check`
Expected: PASS; zeitwerk clean.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/sources test/lib/data_importers/sources
git add app/lib/data_importers/sources test/lib/data_importers/sources
git commit -m "Finder candidate sources: identifiers, exact, OpenSearch, legacy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `Decider` — the deterministic rules

**Files:**
- Create: `app/lib/data_importers/decider.rb`
- Test: `test/lib/data_importers/decider_test.rb`

**Interfaces:**
- Consumes: `Candidate`, `Decision` (Task 5); a finder responding to `corroborated?(query, candidate)`, `exact_match?(query, candidate)`, `ranked?(record)`, `list_count(record)` (Task 9 implements them on `FinderBase`).
- Produces: `DataImporters::Decider.new(finder:, query:, candidates:, verify:, sources_run:).call -> Decision | nil` (nil means the AI must decide).

Rules, in order (spec §3, plus rule 0 for this increment):

0. A `:legacy` candidate → matched, certain, decided_by rule. Not under `verify`.
1. Corroborated identifier hits → matched, certain, decided_by identifier; several → prefer ranked, then most lists, then lowest id; the rest become `identifier_collision` pairs. Not under `verify`.
2. A local candidate whose external verdict is accept, corroborated → matched, certain, decided_by identifier. Not under `verify`.
3. No candidates → unmatched, high, decided_by rule.
4. Exactly one local candidate and `finder.exact_match?` → matched, high, decided_by rule.
5. No local candidates and an external candidate with verdict accept → unmatched, high, decided_by rule, `external` set.
6. Otherwise nil.

- [ ] **Step 1: Write the failing tests**

`test/lib/data_importers/decider_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class DeciderTest < ActiveSupport::TestCase
    # A stand-in for the finder: the four judgements the rules ask it for.
    class FakeFinder
      def initialize(corroborated: true, exact: false, ranked_ids: [], list_counts: {})
        @corroborated = corroborated
        @exact = exact
        @ranked_ids = ranked_ids
        @list_counts = list_counts
      end

      def corroborated?(_query, candidate)
        @corroborated.respond_to?(:call) ? @corroborated.call(candidate) : @corroborated
      end

      def exact_match?(_query, candidate)
        @exact.respond_to?(:call) ? @exact.call(candidate) : @exact
      end

      def ranked?(record) = @ranked_ids.include?(record.id)

      def list_count(record) = @list_counts.fetch(record.id, 0)
    end

    def setup
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
      @third = books_books(:combo_steinbeck)
      @query = {title: "War and Peace"}
    end

    def decide(candidates, finder: FakeFinder.new, verify: false, sources_run: 2)
      Decider.new(finder: finder, query: @query, candidates: candidates, verify: verify, sources_run: sources_run).call
    end

    def identifier_candidate(record, type: "books_work_isbn13", value: "978")
      Candidate.new(record: record, sources: [:identifier], evidence: {matched_identifier: {type: type, value: value}})
    end

    test "rule 0: a legacy candidate is a certain rule match" do
      decision = decide([Candidate.new(record: @book, sources: [:legacy], decisive: true)])

      assert_equal [:matched, @book, :certain, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_match(/legacy/, decision.reason)
    end

    test "rule 0 does not fire under verify, so a lone legacy candidate goes to the AI" do
      assert_nil decide([Candidate.new(record: @book, sources: [:legacy], decisive: true)], verify: true)
    end

    test "rule 1: a corroborated identifier hit is a certain identifier match" do
      decision = decide([identifier_candidate(@book)])

      assert_equal [:matched, @book, :certain, :identifier], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_match(/books_work_isbn13 978/, decision.reason)
      assert_equal [], decision.duplicate_pairs
    end

    test "rule 1: an uncorroborated identifier hit is not decisive and, alone, goes to the AI" do
      finder = FakeFinder.new(corroborated: false, exact: false)

      assert_nil decide([identifier_candidate(@book)], finder: finder)
    end

    test "rule 1 does not fire under verify" do
      assert_nil decide([identifier_candidate(@book)], verify: true)
    end

    test "rule 1: several corroborated hits prefer the ranked record and flag the others as identifier collisions" do
      finder = FakeFinder.new(ranked_ids: [@other.id])

      decision = decide([identifier_candidate(@book), identifier_candidate(@other)], finder: finder)

      assert_equal @other, decision.record
      assert_equal [[@other, @book, :identifier_collision]], decision.duplicate_pairs
    end

    test "rule 1: with no ranked record, the one on more lists wins, then the lowest id" do
      by_lists = FakeFinder.new(list_counts: {@book.id => 1, @other.id => 4})
      assert_equal @other, decide([identifier_candidate(@book), identifier_candidate(@other)], finder: by_lists).record

      tie = FakeFinder.new
      low, high = [@book, @other].sort_by(&:id)
      assert_equal low, decide([identifier_candidate(high), identifier_candidate(low)], finder: tie).record
    end

    test "rule 2: a local candidate the external source accepted, corroborated, is a certain match" do
      candidate = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})

      decision = decide([candidate])

      assert_equal [:matched, @book, :certain, :identifier], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_equal candidate, decision.external
    end

    test "rule 2 needs corroboration and does not fire under verify" do
      candidate = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})

      assert_nil decide([candidate], finder: FakeFinder.new(corroborated: false))
      assert_nil decide([candidate], verify: true)
    end

    test "rule 3: no candidates is a high-confidence unmatched, naming how many sources ran" do
      decision = decide([], sources_run: 3)

      assert_equal [:unmatched, nil, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_match(/3 sources/, decision.reason)
    end

    test "rule 4: exactly one local candidate that matches exactly is a high-confidence rule match" do
      decision = decide([Candidate.new(record: @book, sources: [:exact])], finder: FakeFinder.new(exact: true))

      assert_equal [:matched, @book, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
    end

    test "rule 4 does not fire for two local candidates, or for one that is not exact" do
      assert_nil decide([Candidate.new(record: @book, sources: [:exact]), Candidate.new(record: @other, sources: [:exact])], finder: FakeFinder.new(exact: true))
      assert_nil decide([Candidate.new(record: @book, sources: [:opensearch])], finder: FakeFinder.new(exact: false))
    end

    test "rule 4 still fires under verify" do
      decision = decide([Candidate.new(record: @book, sources: [:exact])], finder: FakeFinder.new(exact: true), verify: true)

      assert_equal :matched, decision.outcome
    end

    test "rule 5: only external candidates, one accepted, is a high-confidence unmatched with that external set" do
      accepted = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})
      other = Candidate.new(external_key: "OL2W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "reject"})

      decision = decide([other, accepted])

      assert_equal [:unmatched, nil, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_equal accepted, decision.external
    end

    test "rule 5 does not fire when a local candidate is also present" do
      accepted = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})

      assert_nil decide([Candidate.new(record: @book, sources: [:opensearch]), accepted])
    end

    test "rule 6: anything else is nil" do
      assert_nil decide([Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "abstain"})])
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/decider_test.rb`
Expected: `NameError: uninitialized constant DataImporters::Decider`.

- [ ] **Step 3: Write the Decider**

`app/lib/data_importers/decider.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # The deterministic stage of FinderBase#call. Returns a Decision, or nil
  # when the AI has to decide. The first rule that applies wins; rules 0-2
  # are the early exits and never fire under `verify`.
  class Decider
    def initialize(finder:, query:, candidates:, verify:, sources_run: 0)
      @finder = finder
      @query = query
      @candidates = candidates
      @verify = verify
      @sources_run = sources_run
    end

    def call
      unless @verify
        decision = legacy_decision || identifier_decision || external_accept_decision
        return decision if decision
      end

      return no_candidates_decision if @candidates.empty?

      exact_decision || external_only_accept_decision
    end

    private

    # Rule 0 (increment 1 only): the pre-redesign lookup found it.
    def legacy_decision
      candidate = @candidates.find { |c| c.local? && c.sources.include?(:legacy) }
      return nil unless candidate

      matched(candidate.record, :certain, :rule, "legacy lookup found #{label(candidate)}")
    end

    # Rule 1: a corroborated identifier hit. Several: prefer ranked, then
    # most lists, then oldest; the rest are identifier collisions.
    def identifier_decision
      hits = @candidates.select { |c| c.local? && c.sources.include?(:identifier) && @finder.corroborated?(@query, c) }
      return nil if hits.empty?

      chosen, *rest = preferred(hits)
      identifier = chosen.evidence[:matched_identifier] || {}
      pairs = rest.map { |c| [chosen.record, c.record, :identifier_collision] }
      matched(
        chosen.record, :certain, :identifier,
        "identifier #{identifier[:type]} #{identifier[:value]} held by #{label(chosen)}",
        external: (chosen.external? ? chosen : nil), duplicate_pairs: pairs
      )
    end

    # Rule 2: the external source accepted a key a local record holds.
    def external_accept_decision
      candidate = @candidates.find { |c| c.local? && c.external_accepted? && @finder.corroborated?(@query, c) }
      return nil unless candidate

      matched(
        candidate.record, :certain, :identifier,
        "#{candidate.external_source} accepted #{candidate.external_key}, held by #{label(candidate)}",
        external: candidate
      )
    end

    # Rule 3.
    def no_candidates_decision
      Decision.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule,
        reason: "no candidates from #{@sources_run} sources")
    end

    # Rule 4.
    def exact_decision
      locals = @candidates.select(&:local?)
      return nil unless locals.size == 1 && @finder.exact_match?(@query, locals.first)

      candidate = locals.first
      matched(candidate.record, :high, :rule, "exact title and creator match on #{label(candidate)}",
        external: (candidate.external? ? candidate : nil))
    end

    # Rule 5.
    def external_only_accept_decision
      return nil if @candidates.any?(&:local?)

      accepted = @candidates.find(&:external_accepted?)
      return nil unless accepted

      Decision.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule,
        reason: "#{accepted.external_source} accepted #{accepted.external_key}; nobody holds it locally",
        external: accepted)
    end

    def preferred(candidates)
      candidates.sort_by do |c|
        [@finder.ranked?(c.record) ? 0 : 1, -@finder.list_count(c.record), c.record.id]
      end
    end

    def matched(record, confidence, decided_by, reason, external: nil, duplicate_pairs: [])
      Decision.new(outcome: :matched, record: record, confidence: confidence, decided_by: decided_by,
        reason: reason, external: external, duplicate_pairs: duplicate_pairs)
    end

    def label(candidate)
      "#{candidate.record.class.name}##{candidate.record.id}"
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/decider_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation check**

Comment out the `legacy_decision ||` term in `call`, run the file, confirm "rule 0" fails; restore. Comment out the `@finder.corroborated?(@query, c)` condition in `identifier_decision` (replace with `true`), confirm "uncorroborated identifier hit" fails; restore. Name both in the task report.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/decider.rb test/lib/data_importers/decider_test.rb
git add app/lib/data_importers/decider.rb test/lib/data_importers/decider_test.rb
git commit -m "Finder rules: legacy, corroborated identifiers, exact, external accept

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `Services::Ai::Tasks::Matching::SelectCandidateTask`

**Files:**
- Create: `app/lib/services/ai/tasks/matching/select_candidate_task.rb`
- Test: `test/lib/services/ai/tasks/matching/select_candidate_task_test.rb`

**Interfaces:**
- Produces: `SelectCandidateTask.new(parent: nil, entity_noun:, query_line:, candidate_lines:, guidance: "", provider: nil, model: nil)`; `#call -> Services::Ai::Result` whose `data` is `{selected_index: Integer (0 = none), confidence: "high"|"medium"|"low", reasoning: String, same_entity_groups: [[Integer, ...], ...]}` with 1-based candidate numbers, every group cleaned to in-range, unique, sorted numbers of size ≥ 2.
- `parent` may be nil (a finder called with no subject); `AiChat.parent` is optional.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/ai/tasks/matching/select_candidate_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Matching
        class SelectCandidateTaskTest < ActiveSupport::TestCase
          def setup
            @lines = [
              "War and Peace | by Leo Tolstoy | (1869) | ranked #3 | in catalog",
              "Voyna i mir | by Lev Tolstoy | (1867) | in catalog",
              "War and Peace | by Leo Tolstoy | open_library OL1W | open_library verdict accept"
            ]
            @task = SelectCandidateTask.new(
              parent: nil, entity_noun: "book", query_line: "War & Peace | by Tolstoy",
              candidate_lines: @lines, guidance: "Prefer the original novel over an abridgement."
            )
          end

          test "accepts a nil parent" do
            assert_nothing_raised { SelectCandidateTask.new(parent: nil, entity_noun: "book", query_line: "x", candidate_lines: []) }
          end

          test "uses gpt-5-mini on openai with json mode" do
            assert_equal :openai, @task.send(:task_provider)
            assert_equal "gpt-5-mini", @task.send(:task_model)
            assert_equal({type: "json_object"}, @task.send(:response_format))
          end

          test "system message names the entity, the ranked rule, the identifier caveat and the domain guidance" do
            message = @task.send(:system_message)

            assert_includes message, "incoming book"
            assert_includes message, "ranked"
            assert_includes message, "identifiers in this catalog are sometimes wrong"
            assert_includes message, "same_entity_groups"
            assert_includes message, "Prefer the original novel over an abridgement."
          end

          test "user prompt numbers the candidates from 1 and asks for 0 when none match" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "Incoming book: War & Peace | by Tolstoy"
            assert_includes prompt, "1. War and Peace | by Leo Tolstoy | (1869) | ranked #3 | in catalog"
            assert_includes prompt, "3. War and Peace | by Leo Tolstoy | open_library OL1W"
            assert_includes prompt, "0 for none"
          end

          test "response schema has the four fields and a nested group model" do
            keys = SelectCandidateTask::ResponseSchema.to_json_schema.dig(:properties).keys.map(&:to_s)

            assert_equal %w[selected_index confidence reasoning same_entity_groups], keys
            assert_equal ["members"], SelectCandidateTask::Group.to_json_schema.dig(:properties).keys.map(&:to_s)
          end

          test "process_and_persist returns the selection with cleaned groups" do
            response = {parsed: {selected_index: 1, confidence: "high", reasoning: "Same work.", same_entity_groups: [{members: [2, 1, 2]}, {members: [3]}, {members: [1, 9]}]}}

            result = @task.send(:process_and_persist, response)

            assert result.success?
            assert_equal 1, result.data[:selected_index]
            assert_equal "high", result.data[:confidence]
            assert_equal "Same work.", result.data[:reasoning]
            assert_equal [[1, 2]], result.data[:same_entity_groups]
          end

          test "process_and_persist accepts 0 for none and an empty group list" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 0, confidence: "medium", reasoning: "None.", same_entity_groups: []}})

            assert result.success?
            assert_equal 0, result.data[:selected_index]
            assert_equal [], result.data[:same_entity_groups]
          end

          test "process_and_persist reads groups given as string-keyed hashes or objects" do
            group = Struct.new(:members).new([3, 2])
            result = @task.send(:process_and_persist, {parsed: {selected_index: 0, confidence: "low", reasoning: "", same_entity_groups: [{"members" => [1, 2]}, group]}})

            assert_equal [[1, 2], [2, 3]], result.data[:same_entity_groups]
          end

          test "process_and_persist fails on an out-of-range index" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 4, confidence: "high", reasoning: "", same_entity_groups: []}})

            assert result.failure?
            assert_includes result.error, "selected_index"
          end

          test "process_and_persist fails on an unknown confidence" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 1, confidence: "certain", reasoning: "", same_entity_groups: []}})

            assert result.failure?
            assert_includes result.error, "confidence"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/matching/select_candidate_task_test.rb`
Expected: `NameError: uninitialized constant Services::Ai::Tasks::Matching`.

- [ ] **Step 3: Write the task**

`app/lib/services/ai/tasks/matching/select_candidate_task.rb`:

```ruby
module Services
  module Ai
    module Tasks
      module Matching
        # One structured call: here is the incoming entity, here are up to
        # six candidates, select the one that is the same entity or 0.
        # Follows the "select one or none" pattern (Wang et al. 2024), which
        # beats pairwise yes/no on both accuracy and cost. The task takes a
        # serializable case (lines of text) so a future agent loop can
        # replace this class without touching the finder.
        class SelectCandidateTask < BaseTask
          attr_reader :entity_noun, :query_line, :candidate_lines, :guidance

          VALID_CONFIDENCE = %w[high medium low].freeze

          def initialize(parent: nil, entity_noun:, query_line:, candidate_lines:, guidance: "", provider: nil, model: nil)
            @entity_noun = entity_noun
            @query_line = query_line
            @candidate_lines = candidate_lines
            @guidance = guidance.to_s
            super(parent: parent, provider: provider, model: model)
          end

          private

          # A finder may run with no subject; AiChat.parent is optional.
          def validate_parent!
          end

          def task_provider = :openai

          def task_model = "gpt-5-mini"

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You decide whether an incoming #{entity_noun} already exists in a catalog.
              You are given the incoming #{entity_noun} and a numbered list of candidates. Candidates marked "in catalog" are records already held; the others come from an external source and are not held yet.

              Select the one candidate that is the same #{entity_noun} as the incoming one, or 0 if none is.
              - A translation, an alternate spelling, a subtitle difference or a reissue of the same #{entity_noun} counts as the same one.
              - A different edition or volume, a sequel, a remake, or a collection that merely contains it is NOT the same one.
              - A candidate marked "shares <identifier>" carries the same identifier as the incoming #{entity_noun}. Treat that as strong evidence, not proof: identifiers in this catalog are sometimes wrong.
              - Two candidates may themselves be the same #{entity_noun}. Report every such group in same_entity_groups, as lists of candidate numbers.
              - When two candidates are the same #{entity_noun} and one is marked "ranked", select the ranked one.
              #{guidance}
              Confidence is "high" when the evidence is unambiguous, "medium" when one detail is missing or slightly off, and "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Incoming #{entity_noun}: #{query_line}", "", "Candidates:"]
            candidate_lines.each_with_index { |line, index| lines << "#{index + 1}. #{line}" }
            lines << ""
            lines << "Answer with selected_index (the candidate number, or 0 for none), confidence, reasoning, and same_entity_groups."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            index = data[:selected_index]
            confidence = data[:confidence]
            count = candidate_lines.size

            unless VALID_CONFIDENCE.include?(confidence)
              return failure("Unexpected confidence value: #{confidence.inspect}")
            end
            unless index.is_a?(Integer) && index.between?(0, count)
              return failure("selected_index #{index.inspect} is outside 0..#{count}")
            end

            Services::Ai::Result.new(
              success: true,
              data: {
                selected_index: index,
                confidence: confidence,
                reasoning: data[:reasoning].to_s,
                same_entity_groups: clean_groups(data[:same_entity_groups], count)
              },
              ai_chat: chat
            )
          end

          def clean_groups(groups, count)
            Array(groups).filter_map do |group|
              members = members_of(group).select { |m| m.is_a?(Integer) && m.between?(1, count) }.uniq.sort
              members if members.size >= 2
            end.uniq
          end

          def members_of(group)
            if group.respond_to?(:members)
              Array(group.members)
            elsif group.is_a?(Hash)
              Array(group[:members] || group["members"])
            else
              []
            end
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Group < OpenAI::BaseModel
            required :members, OpenAI::ArrayOf[Integer], doc: "Candidate numbers that are the same entity as each other"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :selected_index, Integer, doc: "The number of the candidate that is the same entity as the incoming one, or 0 if none is"
            required :confidence, String, doc: "high, medium or low"
            required :reasoning, String, doc: "One or two sentences"
            required :same_entity_groups, OpenAI::ArrayOf[Group], doc: "Groups of candidate numbers that are the same entity as each other; empty when there are none"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/matching/select_candidate_task_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS; zeitwerk clean. If `OpenAI::ArrayOf[Group]` raises at load because `Group` is defined after `ResponseSchema` references it, move `Group` above `ResponseSchema` (it already is above in the code as written; keep it that way).

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/ai/tasks/matching test/lib/services/ai/tasks/matching
git add app/lib/services/ai/tasks/matching test/lib/services/ai/tasks/matching
git commit -m "AI selection task: pick one candidate or none, with same-entity groups

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `AiSelection` and the `FinderBase` pipeline

**Files:**
- Create: `app/lib/data_importers/ai_selection.rb`
- Rewrite: `app/lib/data_importers/finder_base.rb`
- Test: `test/lib/data_importers/ai_selection_test.rb`, `test/lib/data_importers/finder_base_test.rb`

**Interfaces:**
- Consumes: Tasks 3–8.
- Produces:
  - `DataImporters::AiSelection.new(finder:, shown:, data:).call -> Decision` (`shown` is the candidate list the AI saw, `data` is the task's result data).
  - `DataImporters::FinderBase#call(query:, verify: false, subject: nil, exclude: nil) -> Match`.
  - Domain hooks (protected, override in subclasses): `candidate_sources(query)` (required), `model_class` (required), `entity_noun`, `ranking_configuration_class`, `domain_guidance`, `creators_required?`, `query_title(query)`, `query_creators(query)`, `query_year(query)`, `record_title(record)`, `record_alternate_titles(record)`, `record_creators(record)`, `record_creator_alternate_names(record)`, `record_year(record)`, `record_identifiers(record)`.
  - Public judgements used by `Decider`/`AiSelection`: `titles_agree?(query, record)`, `creators_agree?(query, record)`, `corroborated?(query, candidate)`, `exact_match?(query, candidate)`, `ranked_position(record)`, `ranked?(record)`, `list_count(record)`, `never_merge?(record_a, record_b)`, `describe_query(query)`, `describe_candidate(candidate)`.
  - Protected helper kept for the legacy lookups: `find_by_identifier(identifier_type:, identifier_value:, model_class:)`.
  - A source that responds to `#resolution` after `#call` has it copied onto the match as `external_resolution` (increment 2's Open Library source uses this).

- [ ] **Step 1: Write the failing tests**

`test/lib/data_importers/ai_selection_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class AiSelectionTest < ActiveSupport::TestCase
    class FakeFinder
      def initialize(never_merge: [])
        @never_merge = never_merge
      end

      def never_merge?(a, b)
        @never_merge.any? { |pair| pair.sort_by(&:id) == [a, b].sort_by(&:id) }
      end
    end

    def setup
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
      @local = Candidate.new(record: @book, sources: [:opensearch], evidence: {title: "War and Peace", ranked_position: nil})
      @ranked = Candidate.new(record: @other, sources: [:opensearch], evidence: {title: "Crime and Punishment", ranked_position: 4})
      @external = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {title: "War and Peace"})
    end

    def select(shown, data, finder: FakeFinder.new)
      AiSelection.new(finder: finder, shown: shown, data: data).call
    end

    test "selecting a local candidate is a matched AI decision at the given confidence" do
      decision = select([@local, @external], {selected_index: 1, confidence: "high", reasoning: "Same work.", same_entity_groups: []})

      assert_equal [:matched, @book, :high, :ai, "Same work.", 1], [decision.outcome, decision.record, decision.confidence, decision.decided_by, decision.reason, decision.selected_index]
      assert_nil decision.external
    end

    test "selecting an external-only candidate is unmatched with that external set" do
      decision = select([@local, @external], {selected_index: 2, confidence: "medium", reasoning: "New here.", same_entity_groups: []})

      assert_equal [:unmatched, nil, :medium, :ai, 2], [decision.outcome, decision.record, decision.confidence, decision.decided_by, decision.selected_index]
      assert_equal @external, decision.external
    end

    test "selecting 0 is unmatched with no external" do
      decision = select([@local], {selected_index: 0, confidence: "low", reasoning: "Nothing fits.", same_entity_groups: []})

      assert_equal [:unmatched, nil, :low], [decision.outcome, decision.record, decision.confidence]
      assert_nil decision.external
      assert_nil decision.selected_index
    end

    test "a local candidate that also carries an external key keeps it as the external" do
      both = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:opensearch, :open_library], evidence: {title: "War and Peace"})

      decision = select([both], {selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: []})

      assert_equal both, decision.external
    end

    test "a same-entity group of two local candidates becomes an :ai duplicate pair" do
      decision = select([@local, @ranked, @external], {selected_index: 3, confidence: "high", reasoning: "", same_entity_groups: [[1, 2], [1, 3]]})

      assert_equal [[@book, @other, :ai]], decision.duplicate_pairs
    end

    test "when the selected local candidate is in a group with a ranked one, the ranked one wins and the reason says so" do
      decision = select([@local, @ranked], {selected_index: 1, confidence: "high", reasoning: "Picked the first.", same_entity_groups: [[1, 2]]})

      assert_equal @other, decision.record
      assert_equal 2, decision.selected_index
      assert_match(/Preferred ranked #4/, decision.reason)
      assert_equal [[@book, @other, :ai]], decision.duplicate_pairs
    end

    test "the ranked switch and the pair are skipped for a pair a human ruled not a duplicate" do
      finder = FakeFinder.new(never_merge: [[@book, @other]])

      decision = select([@local, @ranked], {selected_index: 1, confidence: "high", reasoning: "Picked the first.", same_entity_groups: [[1, 2]]}, finder: finder)

      assert_equal @book, decision.record
      assert_equal [], decision.duplicate_pairs
    end

    test "a selected candidate that is itself ranked is never switched" do
      decision = select([@ranked, @local], {selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: [[1, 2]]})

      assert_equal @other, decision.record
    end
  end
end
```

`test/lib/data_importers/finder_base_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class FinderBaseTest < ActiveSupport::TestCase
    class FakeSource
      attr_reader :name

      def initialize(name, candidates: [], error: nil, resolution: nil)
        @name = name
        @candidates = candidates
        @error = error
        @resolution = resolution
        @calls = 0
      end

      attr_reader :calls, :resolution

      def call
        @calls += 1
        raise @error if @error

        @candidates
      end
    end

    # A books finder whose query is a Hash and whose sources are injected.
    class TestFinder < DataImporters::FinderBase
      attr_accessor :sources

      protected

      def model_class = ::Books::Book

      def ranking_configuration_class = ::Books::RankingConfiguration

      def candidate_sources(_query) = sources

      def creators_required? = true

      def query_title(query) = query[:title]

      def query_creators(query) = Array(query[:creators])

      def query_year(query) = query[:year]

      def record_creators(record) = record.authors.map(&:name)

      def record_creator_alternate_names(record) = record.authors.flat_map { |a| Array(a.alternate_names) }

      def record_year(record) = record.first_published_year
    end

    def setup
      @book = books_books(:war_and_peace)      # Leo Tolstoy, 1869, alternate title "Voyna i mir"
      @other = books_books(:crime_and_punishment)
      @finder = TestFinder.new
      @query = {title: "War and Peace", creators: ["Leo Tolstoy"], year: 1869}
      @task = mock("select_candidate_task")
    end

    def stub_ai(data, success: true, error: nil)
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: success, data: data, error: error, ai_chat: ai_chats(:general_chat)))
    end

    # ---- agreement judgements ------------------------------------------

    test "titles_agree? compares normalized titles and alternate titles" do
      assert @finder.titles_agree?({title: "war and peace"}, @book)
      assert @finder.titles_agree?({title: "Voyna i mir"}, @book)
      assert_not @finder.titles_agree?({title: "War"}, @book)
      assert_not @finder.titles_agree?({title: nil}, @book)
    end

    test "creators_agree? needs one query creator to match a record creator or alternate name" do
      assert @finder.creators_agree?({creators: ["leo tolstoy"]}, @book)
      assert_not @finder.creators_agree?({creators: ["Fyodor Dostoevsky"]}, @book)
      assert_not @finder.creators_agree?({creators: []}, @book)
    end

    test "corroborated? is true when nothing can be compared, else when titles or creators agree" do
      candidate = Candidate.new(record: @book)

      assert @finder.corroborated?({}, candidate)
      assert @finder.corroborated?({title: "Nothing like it", creators: ["Leo Tolstoy"]}, candidate)
      assert @finder.corroborated?({title: "War and Peace", creators: ["Nobody"]}, candidate)
      assert_not @finder.corroborated?({title: "Nothing like it", creators: ["Nobody"]}, candidate)
    end

    test "exact_match? needs title, creators (when required) and no year conflict" do
      candidate = Candidate.new(record: @book)

      assert @finder.exact_match?(@query, candidate)
      assert @finder.exact_match?({title: "War and Peace", creators: ["Leo Tolstoy"]}, candidate), "missing year is not a conflict"
      assert @finder.exact_match?({title: "War and Peace", creators: ["Leo Tolstoy"], year: 1871}, candidate), "two years apart is not a conflict"
      assert_not @finder.exact_match?({title: "War and Peace", creators: ["Leo Tolstoy"], year: 1900}, candidate)
      assert_not @finder.exact_match?({title: "War and Peace", creators: []}, candidate), "creators are required in this domain"
      assert_not @finder.exact_match?({title: "War", creators: ["Leo Tolstoy"]}, candidate)
    end

    test "ranked_position reads the primary configuration and ranked? follows it" do
      assert_nil @finder.ranked_position(@book)
      RankedItem.create!(item: @book, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 1.0)

      assert_equal 7, @finder.ranked_position(@book)
      assert @finder.ranked?(@book)
    end

    test "never_merge? consults the duplicate_candidates verdict" do
      assert_not @finder.never_merge?(@book, @other)
      DuplicateCandidate.flag!(item_type: "Books::Book", ids: [@book.id, @other.id], source: :ai).update!(status: :not_duplicate)

      assert @finder.never_merge?(@other, @book)
    end

    test "describe_candidate lays out title, creators, year, rank, where it lives and shared identifiers" do
      candidate = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library,
        evidence: {title: "War and Peace", creators: ["Leo Tolstoy"], year: 1869, ranked_position: 3,
                   matched_identifier: {type: "books_work_isbn13", value: "978"}, external_verdict: "accept"})

      line = @finder.describe_candidate(candidate)

      assert_equal "War and Peace | by Leo Tolstoy | (1869) | ranked #3 | in catalog | open_library OL1W | shares books_work_isbn13 | open_library verdict accept", line
    end

    # ---- the pipeline -----------------------------------------------------

    test "a legacy hit is a certain rule match and is recorded" do
      @finder.sources = [FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)])]

      match = @finder.call(query: @query)

      assert match.matched?
      assert_equal @book, match.record
      assert_equal [:certain, :rule], [match.confidence, match.decided_by]
      assert_not match.needs_review?
      decision = match.decision
      assert_equal "DataImporters::FinderBaseTest::TestFinder", decision.finder
      assert_equal @book, decision.record
      assert decision.matched?
      assert decision.certain?
      assert decision.decided_by_rule?
      assert_equal 1, decision.selected_index
      assert_equal "War and Peace", decision.query["title"]
      assert_equal ["Leo Tolstoy"], decision.query["creators"]
      assert_equal "Books::Book", decision.candidates.first["record_type"]
      assert_equal @book.id, decision.candidates.first["record_id"]
      assert_equal ["Leo Tolstoy"], decision.candidates.first["evidence"]["creators"]
      assert_not decision.needs_review
    end

    test "no candidates is a high-confidence unmatched, recorded with no record" do
      @finder.sources = [FakeSource.new(:exact), FakeSource.new(:opensearch)]

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_nil match.record
      assert_equal [:high, :rule], [match.confidence, match.decided_by]
      assert_match(/2 sources/, match.reason)
      assert_nil match.decision.record
      assert match.decision.unmatched?
    end

    test "a decisive candidate stops gathering; verify runs every source" do
      first = FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)])
      second = FakeSource.new(:opensearch, candidates: [Candidate.new(record: @other, sources: [:opensearch])])
      @finder.sources = [first, second]

      @finder.call(query: @query)
      assert_equal 0, second.calls

      stub_ai({selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: []})
      match = @finder.call(query: @query, verify: true)

      assert_equal 1, second.calls
      assert match.decision.verify
      assert_equal 2, match.candidates.size
    end

    test "exclude drops that record from every source" do
      @finder.sources = [FakeSource.new(:exact, candidates: [Candidate.new(record: @book, sources: [:exact]), Candidate.new(record: @other, sources: [:exact])])]
      stub_ai({selected_index: 0, confidence: "high", reasoning: "", same_entity_groups: []})

      match = @finder.call(query: @query, exclude: @book)

      assert_equal [@other], match.candidates.map(&:record)
    end

    test "a failing source contributes nothing, is recorded, and caps a high confidence at medium" do
      @finder.sources = [FakeSource.new(:opensearch, error: StandardError.new("opensearch down"))]

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_equal ["opensearch"], match.sources_failed
      assert_equal :medium, match.confidence
      assert match.needs_review?
      assert_equal ["opensearch"], match.decision.sources_failed
      assert match.decision.needs_review
    end

    test "a failing source does not downgrade a certain decision" do
      @finder.sources = [
        FakeSource.new(:opensearch, error: StandardError.new("down")),
        FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)])
      ]

      match = @finder.call(query: @query)

      assert_equal :certain, match.confidence
      assert_not match.needs_review?
    end

    test "candidates that the rules cannot settle go to the AI with at most six lines, and the selection is recorded" do
      candidates = [@book, @other, books_books(:combo_steinbeck), books_books(:got)].map { |b| Candidate.new(record: b, sources: [:opensearch], scores: {opensearch: 5.0}) }
      @finder.sources = [FakeSource.new(:opensearch, candidates: candidates)]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with do |args|
        args[:entity_noun] == "book" && args[:candidate_lines].size == 4 && args[:query_line].include?("War and Peace") && args[:parent].nil?
      end.returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 2, confidence: "medium", reasoning: "Closest.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

      match = @finder.call(query: @query)

      assert match.matched?
      assert_equal @other, match.record
      assert_equal [:medium, :ai, "Closest."], [match.confidence, match.decided_by, match.reason]
      assert match.needs_review?
      assert_equal ai_chats(:general_chat), match.decision.ai_chat
      assert_equal 2, match.decision.selected_index
      assert match.decision.decided_by_ai?
      assert match.decision.needs_review
    end

    test "the subject is passed to the AI task as its parent and recorded on the decision" do
      subject = list_items(:music_albums_item)
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with { |args| args[:parent] == subject }.returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 0, confidence: "low", reasoning: "", same_entity_groups: []}))

      match = @finder.call(query: @query, subject: subject)

      assert_equal subject, match.decision.subject
    end

    test "an AI same-entity group of two local records is flagged as a duplicate pair tied to the decision" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      stub_ai({selected_index: 1, confidence: "high", reasoning: "Both the same.", same_entity_groups: [[1, 2]]})

      match = @finder.call(query: @query)

      pair = DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
      assert pair.pending?
      assert pair.raised_by_ai?
      assert_equal match.decision, pair.match_decision
      assert_equal "Both the same.", pair.evidence["reason"]
    end

    test "the ranked candidate wins a same-entity group over the AI's unranked pick" do
      RankedItem.create!(item: @other, ranking_configuration: ranking_configurations(:books_global), rank: 2, score: 1.0)
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      stub_ai({selected_index: 1, confidence: "high", reasoning: "Picked one.", same_entity_groups: [[1, 2]]})

      match = @finder.call(query: @query)

      assert_equal @other, match.record
      assert_match(/Preferred ranked #2/, match.reason)
    end

    test "an AI failure falls back to unmatched, low, decided_by fallback, and never raises" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      stub_ai(nil, success: false, error: "boom")

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_equal [:low, :fallback], [match.confidence, match.decided_by]
      assert_includes match.reason, "boom"
      assert match.needs_review?
      assert match.decision.decided_by_fallback?
    end

    test "an exception building the AI task is also a fallback" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).raises(ArgumentError, "Unknown provider")

      match = @finder.call(query: @query)

      assert match.decision.decided_by_fallback?
      assert_includes match.reason, "Unknown provider"
    end

    test "a source's resolution is carried onto the match" do
      resolution = Object.new
      @finder.sources = [FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)], resolution: resolution)]

      match = @finder.call(query: @query)

      assert_same resolution, match.external_resolution
    end

    test "evidence for a local candidate is filled from the record and keeps what the source supplied" do
      @finder.sources = [FakeSource.new(:identifier, candidates: [Candidate.new(record: @book, sources: [:identifier], evidence: {matched_identifier: {type: "books_work_isbn13", value: "9780140447934"}})])]

      match = @finder.call(query: @query)

      evidence = match.candidates.first.evidence
      assert_equal "War and Peace", evidence[:title]
      assert_equal ["Leo Tolstoy"], evidence[:creators]
      assert_equal 1869, evidence[:year]
      assert_equal({type: "books_work_isbn13", value: "9780140447934"}, evidence[:matched_identifier])
      assert_includes evidence[:identifiers], {type: "books_work_isbn13", value: "9780140447934"}
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/ai_selection_test.rb test/lib/data_importers/finder_base_test.rb`
Expected: `NameError` for `AiSelection`; `NotImplementedError`/`ArgumentError` from the old `FinderBase#call(query:)`.

- [ ] **Step 3: Write `AiSelection`**

`app/lib/data_importers/ai_selection.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # Turns SelectCandidateTask's data into a Decision: the selection itself,
  # the ranked post-rule (a ranked record wins a same-entity group over the
  # unranked pick), and the duplicate pairs every same-entity group of two
  # local records implies. A pair a human ruled not_duplicate is neither
  # re-raised nor used to switch the selection.
  class AiSelection
    def initialize(finder:, shown:, data:)
      @finder = finder
      @shown = shown
      @data = data
    end

    def call
      index = @data[:selected_index].to_i
      chosen = index.positive? ? @shown[index - 1] : nil
      confidence = @data[:confidence].to_s.to_sym
      reason = @data[:reasoning].to_s
      pairs = []

      Array(@data[:same_entity_groups]).each do |members|
        group = members.filter_map { |m| @shown[m - 1] }
        locals = group.select(&:local?)
        locals.combination(2).each do |a, b|
          next if @finder.never_merge?(a.record, b.record)

          pairs << [a.record, b.record, :ai]
        end

        next unless chosen&.local? && !chosen.ranked? && members.include?(index)

        ranked = locals.find { |c| c.ranked? && !c.equal?(chosen) }
        next unless ranked && !@finder.never_merge?(chosen.record, ranked.record)

        reason = "#{reason} Preferred ranked ##{ranked.evidence[:ranked_position]} #{ranked.evidence[:title]} over the unranked pick.".strip
        index = @shown.index(ranked) + 1
        chosen = ranked
      end

      if chosen.nil?
        Decision.new(outcome: :unmatched, record: nil, confidence: confidence, decided_by: :ai, reason: reason,
          external: nil, selected_index: nil, duplicate_pairs: pairs)
      elsif chosen.local?
        Decision.new(outcome: :matched, record: chosen.record, confidence: confidence, decided_by: :ai, reason: reason,
          external: (chosen.external? ? chosen : nil), selected_index: index, duplicate_pairs: pairs)
      else
        Decision.new(outcome: :unmatched, record: nil, confidence: confidence, decided_by: :ai, reason: reason,
          external: chosen, selected_index: index, duplicate_pairs: pairs)
      end
    end
  end
end
```

- [ ] **Step 4: Rewrite `FinderBase`**

`app/lib/data_importers/finder_base.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  # Base class for finding an existing record before import.
  #
  # A finder answers "is this thing already in our catalog?" with a Match
  # (matched or unmatched, with confidence, the candidates considered, who
  # decided and why) and records that answer as a MatchDecision. The four
  # stages are fixed: gather candidates from the sources, apply the rules,
  # ask the AI when the rules could not decide, record. A domain subclass
  # supplies the sources and the hooks the rules and the AI prompt need.
  #
  # The finder never creates or mutates catalog records and is not
  # transactional. It can be called on its own (the wizard enrichers do).
  class FinderBase
    MAX_AI_CANDIDATES = 6

    Run = Struct.new(
      :query, :verify, :subject, :exclude, :candidates, :sources_run,
      :sources_failed, :external_resolution, :decision, :ai_chat,
      keyword_init: true
    )

    def call(query:, verify: false, subject: nil, exclude: nil)
      run = Run.new(query: query, verify: verify, subject: subject, exclude: exclude,
        candidates: [], sources_run: 0, sources_failed: [])
      gather(run)
      decide(run)
      record(run)
    end

    # ---- judgements the Decider and AiSelection ask for ----------------------

    def titles_agree?(query, record)
      wanted = normalize(query_title(query))
      return false if wanted.blank?

      ([record_title(record)] + record_alternate_titles(record)).any? { |title| normalize(title) == wanted }
    end

    def creators_agree?(query, record)
      wanted = query_creators(query).map { |name| normalize(name) }.compact_blank
      return false if wanted.empty?

      held = (record_creators(record) + record_creator_alternate_names(record)).map { |name| normalize(name) }.compact_blank
      (wanted & held).any?
    end

    # An identifier (or an external accept) is trusted only when the record
    # agrees with the query on its title or its creators, or when the query
    # carried nothing to compare (an identifier-only import).
    def corroborated?(query, candidate)
      return true if query_title(query).blank? && query_creators(query).empty?

      titles_agree?(query, candidate.record) || creators_agree?(query, candidate.record)
    end

    # Rule 4's test: equal normalized title, agreeing creators where the
    # domain has creators, and no year conflict (both present, > 2 apart).
    def exact_match?(query, candidate)
      return false unless titles_agree?(query, candidate.record)
      return false if creators_required? && !creators_agree?(query, candidate.record)

      !year_conflict?(query_year(query), record_year(candidate.record))
    end

    def ranked_position(record)
      configuration = ranking_configuration_class&.default_primary
      return nil unless configuration

      ::RankedItem.where(item: record, ranking_configuration_id: configuration.id).pick(:rank)
    end

    def ranked?(record)
      ranked_position(record).present?
    end

    def list_count(record)
      record.respond_to?(:list_items) ? record.list_items.count : 0
    end

    def never_merge?(record_a, record_b)
      ::DuplicateCandidate.not_duplicate?(item_type: model_class.name, ids: [record_a.id, record_b.id])
    end

    def describe_query(query)
      parts = [query_title(query).presence]
      creators = query_creators(query)
      parts << "by #{creators.join(", ")}" if creators.any?
      parts << "(#{query_year(query)})" if query_year(query).present?
      parts.compact.join(" | ")
    end

    def describe_candidate(candidate)
      evidence = candidate.evidence
      creators = Array(evidence[:creators])
      parts = [evidence[:title].presence || candidate.external_key.to_s]
      parts << "by #{creators.join(", ")}" if creators.any?
      parts << "(#{evidence[:year]})" if evidence[:year].present?
      parts << "ranked ##{evidence[:ranked_position]}" if evidence[:ranked_position].present?
      parts << "in catalog" if candidate.local?
      parts << "#{candidate.external_source} #{candidate.external_key}" if candidate.external?
      parts << "shares #{evidence.dig(:matched_identifier, :type)}" if evidence[:matched_identifier]
      parts << "#{candidate.external_source} verdict #{candidate.external_verdict}" if candidate.external_verdict
      parts.join(" | ")
    end

    protected

    # ---- hooks a domain subclass overrides ------------------------------------

    def candidate_sources(query)
      raise NotImplementedError, "#{self.class.name} must implement #candidate_sources(query)"
    end

    def model_class
      raise NotImplementedError, "#{self.class.name} must implement #model_class"
    end

    def entity_noun
      model_class.name.demodulize.underscore.humanize.downcase
    end

    def ranking_configuration_class
      nil
    end

    def domain_guidance
      ""
    end

    def creators_required?
      false
    end

    def query_title(query)
      return query.title if query.respond_to?(:title)
      return query.name if query.respond_to?(:name)

      nil
    end

    def query_creators(_query)
      []
    end

    def query_year(query)
      query.respond_to?(:year) ? query.year : nil
    end

    def record_title(record)
      record.respond_to?(:title) ? record.title : record.name
    end

    def record_alternate_titles(record)
      return Array(record.alternate_titles) if record.respond_to?(:alternate_titles)
      return Array(record.alternate_names) if record.respond_to?(:alternate_names)

      []
    end

    def record_creators(_record)
      []
    end

    def record_creator_alternate_names(_record)
      []
    end

    def record_year(_record)
      nil
    end

    def record_identifiers(record)
      return [] unless record.respond_to?(:identifiers)

      record.identifiers.map { |identifier| {type: identifier.identifier_type, value: identifier.value} }
    end

    # Kept for the legacy lookups (increment 1); the Identifiers source
    # replaces it as each domain migrates.
    def find_by_identifier(identifier_type:, identifier_value:, model_class:)
      identifier = ::Identifier.includes(:identifiable).find_by(
        identifier_type: identifier_type,
        value: identifier_value,
        identifiable_type: model_class.name
      )

      identifier&.identifiable
    end

    private

    # ---- stage 1: gather ------------------------------------------------------

    def gather(run)
      set = CandidateSet.new
      candidate_sources(run.query).each do |source|
        run.sources_run += 1
        begin
          found = source.call
        rescue => e
          Rails.logger.warn "#{self.class.name}: source #{source.name} failed: #{e.class}: #{e.message}"
          run.sources_failed << source.name.to_s
          next
        end
        run.external_resolution ||= source.resolution if source.respond_to?(:resolution)

        found.each do |candidate|
          next if excluded?(run, candidate)

          candidate.evidence = evidence_for(candidate.record).merge(candidate.evidence) { |_key, base, given| given.nil? ? base : given } if candidate.local?
          set.add(candidate)
        end

        break if !run.verify && set.to_a.any? { |candidate| decisive?(run.query, candidate) }
      end
      run.candidates = order(set.to_a)
    end

    def excluded?(run, candidate)
      run.exclude && candidate.local? &&
        candidate.record.class == run.exclude.class && candidate.record.id == run.exclude.id
    end

    def decisive?(query, candidate)
      return true if candidate.sources.include?(:legacy)
      return false unless candidate.local?

      (candidate.sources.include?(:identifier) || candidate.external_accepted?) && corroborated?(query, candidate)
    end

    def evidence_for(record)
      {
        title: record_title(record),
        creators: record_creators(record),
        year: record_year(record),
        ranked_position: ranked_position(record),
        list_count: list_count(record),
        identifiers: record_identifiers(record)
      }
    end

    # Local and multi-source candidates first, then by best score; stable.
    def order(candidates)
      candidates.each_with_index.sort_by do |candidate, index|
        [candidate.local? ? 0 : 1, -candidate.sources.size, -(candidate.scores.values.compact.max || 0.0), index]
      end.map(&:first)
    end

    # ---- stage 2 and 3: rules, then the AI -----------------------------------

    def decide(run)
      run.decision = Decider.new(finder: self, query: run.query, candidates: run.candidates,
        verify: run.verify, sources_run: run.sources_run).call
      return if run.decision

      shown = run.candidates.first(MAX_AI_CANDIDATES)
      begin
        task = ::Services::Ai::Tasks::Matching::SelectCandidateTask.new(
          parent: run.subject,
          entity_noun: entity_noun,
          query_line: describe_query(run.query),
          candidate_lines: shown.map { |candidate| describe_candidate(candidate) },
          guidance: domain_guidance
        )
        result = task.call
      rescue => e
        Rails.logger.error "#{self.class.name}: AI selection raised #{e.class}: #{e.message}"
        run.decision = Decision.fallback("AI selection failed: #{e.class}: #{e.message}")
        return
      end

      run.ai_chat = result.ai_chat
      run.decision = if result.success?
        AiSelection.new(finder: self, shown: shown, data: result.data).call
      else
        Decision.fallback("AI selection failed: #{result.error}")
      end
    end

    # ---- stage 4: record ------------------------------------------------------

    def record(run)
      decision = run.decision
      confidence = decision.confidence
      confidence = :medium if confidence == :high && run.sources_failed.any?
      needs_review = %i[medium low].include?(confidence) || decision.decided_by == :fallback
      selected_index = decision.selected_index || index_of(run.candidates, decision.record)

      row = ::MatchDecision.create!(
        finder: self.class.name,
        record: decision.record,
        subject: run.subject,
        outcome: decision.outcome,
        confidence: confidence,
        decided_by: decision.decided_by,
        verify: run.verify,
        query: query_snapshot(run.query),
        candidates: run.candidates.map(&:snapshot),
        selected_index: selected_index,
        reason: decision.reason,
        ai_chat: run.ai_chat,
        sources_failed: run.sources_failed,
        needs_review: needs_review
      )

      decision.duplicate_pairs.each do |record_a, record_b, source|
        ::DuplicateCandidate.flag!(
          item_type: model_class.name, ids: [record_a.id, record_b.id], source: source,
          evidence: {reason: decision.reason, decided_by: decision.decided_by.to_s}, match_decision: row
        )
      end

      Match.new(
        outcome: decision.outcome, record: decision.record, confidence: confidence,
        decided_by: decision.decided_by, reason: decision.reason, candidates: run.candidates,
        external: decision.external, external_resolution: run.external_resolution,
        decision: row, sources_failed: run.sources_failed
      )
    end

    def index_of(candidates, record)
      return nil unless record

      position = candidates.index { |candidate| candidate.local? && candidate.record.class == record.class && candidate.record.id == record.id }
      position && position + 1
    end

    def query_snapshot(query)
      return query.deep_stringify_keys.transform_values { |value| snapshot_value(value) } if query.is_a?(Hash)

      query.instance_variables.to_h do |ivar|
        [ivar.to_s.delete("@"), snapshot_value(query.instance_variable_get(ivar))]
      end
    end

    def snapshot_value(value)
      case value
      when ActiveRecord::Base then "#{value.class.name}##{value.id}"
      when Array then value.map { |item| snapshot_value(item) }
      when Hash then value.to_h { |key, item| [key.to_s, snapshot_value(item)] }
      when String, Integer, Float, TrueClass, FalseClass, NilClass then value
      else value.to_s
      end
    end

    def year_conflict?(year_a, year_b)
      year_a.present? && year_b.present? && (year_a.to_i - year_b.to_i).abs > 2
    end

    def normalize(text)
      return nil if text.nil?

      ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/ai_selection_test.rb test/lib/data_importers/finder_base_test.rb`
Expected: PASS. The existing domain finder tests now fail (their finders still define `call` with the old contract); Task 11 fixes them, so do not run the whole suite yet.

- [ ] **Step 6: Mutation check**

In `record`, remove the `confidence = :medium if …` line: "a failing source … caps a high confidence at medium" must fail. In `AiSelection#call`, delete the `next unless chosen&.local? …` block: "the ranked candidate wins" must fail. Restore both and name them in the task report.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/ai_selection.rb app/lib/data_importers/finder_base.rb test/lib/data_importers/ai_selection_test.rb test/lib/data_importers/finder_base_test.rb
git add app/lib/data_importers/ai_selection.rb app/lib/data_importers/finder_base.rb test/lib/data_importers/ai_selection_test.rb test/lib/data_importers/finder_base_test.rb
git commit -m "FinderBase pipeline: gather, rules, AI selection, record

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `ImporterBase`, `ProviderBase`, `ImportResult`, the 13 providers and the 6 importer entry points

**Files:**
- Modify: `app/lib/data_importers/importer_base.rb` (rewrite `call`, `run_providers`, `run_providers_with_saving`), `app/lib/data_importers/provider_base.rb:7`, `app/lib/data_importers/import_result.rb`
- Modify (one line each): `app/lib/data_importers/games/game/providers/amazon.rb:11`, `games/game/providers/igdb.rb:33`, `games/game/providers/cover_art.rb:11`, `games/company/providers/igdb.rb:15`, `music/album/providers/music_brainz.rb:16`, `music/album/providers/ai_description.rb:10`, `music/album/providers/cover_art.rb:8`, `music/album/providers/amazon.rb:10`, `music/artist/providers/music_brainz.rb:16`, `music/artist/providers/ai_description.rb:10`, `music/song/providers/musicbrainz/music_brainz.rb:10`, `music/release/providers/music_brainz.rb:8`, `books/book/providers/open_library.rb:40`
- Modify: `app/lib/data_importers/books/book/importer.rb:9-25`, `games/game/importer.rb:9-18`, `games/company/importer.rb:9-12`, `music/artist/importer.rb:9-12`, `music/album/importer.rb:9-18`, `music/song/importer.rb:7-10`
- Modify: `test/lib/data_importers/music/album/importer_test.rb:66,234`, `test/lib/data_importers/music/song/importer_test.rb:119`
- Test: `test/lib/data_importers/importer_base_test.rb`

**Interfaces:**
- Consumes: `Match` (Task 5), `MatchDecision` (Task 3), `FinderBase#call(query:, verify:, subject:)` (Task 9).
- Produces: `ImporterBase.call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)`; `ProviderBase#populate(item, query:, match: nil)`; `ImportResult#match`; every domain `Importer.call` accepts `subject:` and `verify:`.

- [ ] **Step 1: Write the failing test**

`test/lib/data_importers/importer_base_test.rb`:

```ruby
require "test_helper"

module DataImporters
  class ImporterBaseTest < ActiveSupport::TestCase
    class FakeQuery
      attr_reader :title

      def initialize(title = "Seeded")
        @title = title
      end

      def valid? = true
    end

    class FakeFinder
      attr_reader :calls

      def initialize(match)
        @match = match
        @calls = []
      end

      def call(**kwargs)
        @calls << kwargs
        @match
      end
    end

    class RecordingProvider < DataImporters::ProviderBase
      attr_reader :received

      def populate(item, query:, match: nil)
        @received = {item: item, query: query, match: match}
        item.title = "#{item.title} (provided)"
        success_result(data_populated: [:title])
      end
    end

    class TestImporter < DataImporters::ImporterBase
      attr_reader :fake_finder, :provider

      def initialize(match:)
        @fake_finder = FakeFinder.new(match)
        @provider = RecordingProvider.new
      end

      protected

      def finder = fake_finder

      def providers = [provider]

      def initialize_item(query) = ::Books::Book.new(title: query.title)
    end

    def setup
      @existing = books_books(:war_and_peace)
      @query = FakeQuery.new
    end

    def decision_for(match)
      MatchDecision.create!(finder: "F", record: match.record, outcome: match.outcome, confidence: match.confidence, decided_by: match.decided_by)
    end

    test "a matched finder result returns the existing record, runs no provider, and carries the match" do
      match = Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)
      importer = TestImporter.new(match: match)

      result = importer.call(query: @query)

      assert result.success?
      assert_equal @existing, result.item
      assert_same match, result.match
      assert_nil importer.provider.received
      assert_equal [{query: @query, verify: false, subject: nil}], importer.fake_finder.calls
    end

    test "subject and verify are passed through to the finder" do
      subject = list_items(:music_albums_item)
      match = Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)
      importer = TestImporter.new(match: match)

      importer.call(query: @query, subject: subject, verify: true)

      assert_equal [{query: @query, verify: true, subject: subject}], importer.fake_finder.calls
    end

    test "force_providers runs the providers on the existing record and hands them the match" do
      match = Match.new(outcome: :matched, record: @existing, confidence: :certain, decided_by: :identifier)
      importer = TestImporter.new(match: match)

      result = importer.call(query: @query, force_providers: true)

      assert_equal @existing, result.item
      assert_same match, importer.provider.received[:match]
      assert_equal @query, importer.provider.received[:query]
    end

    test "an unmatched finder result creates the record, hands providers the match, and points the decision at the new record" do
      match = Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule)
      match.decision = decision_for(match)
      importer = TestImporter.new(match: match)

      result = importer.call(query: @query)

      assert result.success?
      assert result.item.persisted?
      assert_equal "Seeded (provided)", result.item.title
      assert_same match, importer.provider.received[:match]
      assert_equal result.item, match.decision.reload.record
      assert_same match, result.match
    end

    test "an unmatched result whose providers all fail leaves the decision without a record" do
      match = Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule)
      match.decision = decision_for(match)
      importer = TestImporter.new(match: match)
      importer.provider.stubs(:populate).returns(ProviderResult.failure(provider: "RecordingProvider", errors: ["nope"]))

      result = importer.call(query: @query)

      assert result.failure?
      assert_not result.item.persisted?
      assert_nil match.decision.reload.record
    end

    test "an item-based import skips the finder and hands providers a nil match" do
      importer = TestImporter.new(match: nil)

      result = importer.call(item: @existing)

      assert_equal [], importer.fake_finder.calls
      assert_nil importer.provider.received[:match]
      assert_nil result.match
    end

    test "ImportResult#summary names the match outcome and confidence when there is one" do
      match = Match.new(outcome: :matched, record: @existing, confidence: :high, decided_by: :rule)
      result = ImportResult.new(item: @existing, provider_results: [], success: true, match: match)

      assert_equal :matched, result.summary[:match_outcome]
      assert_equal :high, result.summary[:match_confidence]
      assert_nil ImportResult.new(item: nil, provider_results: [], success: false).summary[:match_outcome]
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/data_importers/importer_base_test.rb`
Expected: `ArgumentError: unknown keywords: subject, verify` and `undefined method 'match'`.

- [ ] **Step 3: Rewrite `ImporterBase#call` and the provider runners**

Replace `app/lib/data_importers/importer_base.rb` lines 1-66 (`self.call` through the end of `call`) with:

```ruby
# frozen_string_literal: true

module DataImporters
  # Base class for all importers
  # Orchestrates the import process: find existing, create new, run providers, save
  class ImporterBase
    def self.call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
      new.call(query: query, item: item, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
    end

    def call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
      # Validate input parameters
      if item.nil? && query.nil?
        raise ArgumentError, "Either item or query must be provided"
      end

      if item.present? && query.present?
        raise ArgumentError, "Cannot specify both item and query - use one or the other"
      end

      # Validate query if provided
      validate_query!(query) if query.present?

      if multi_item_import?
        # For multi-item imports (like releases), providers handle creation
        # Item parameter not supported for multi-item imports
        if item.present?
          raise ArgumentError, "Item parameter not supported for multi-item imports"
        end

        # Don't use finder to return early - let providers handle existing vs new logic
        provider_results = run_providers(nil, query, providers)

        ImportResult.new(
          item: nil,
          provider_results: provider_results,
          success: provider_results.any?(&:success?)
        )
      else
        match = nil

        # Determine the item to work with
        if item.present?
          # Item-based import: use provided item
          target_item = item
          is_existing_item = true
        else
          # Query-based import: ask the finder. It always answers, and records
          # the answer; `match.record` is nil when nothing matched.
          match = finder.call(query: query, verify: verify, subject: subject)
          existing = match.record
          if existing && !force_providers
            return ImportResult.new(
              item: existing,
              provider_results: [],
              success: true,
              match: match
            )
          end

          # Use existing item or create new one
          target_item = existing || initialize_item(query)
          is_existing_item = existing.present?
        end

        # Run providers to populate data, saving after each successful provider
        provider_results = run_providers_with_saving(target_item, query, is_existing_item, providers, match: match)

        # A new record now exists: point the finder's decision at it.
        if match && !is_existing_item && target_item.persisted?
          match.decision&.update!(record: target_item)
        end

        # Overall success if any provider succeeded
        success = provider_results.any?(&:success?)

        # Return aggregated results
        ImportResult.new(
          item: target_item,
          provider_results: provider_results,
          success: success,
          match: match
        )
      end
    end
```

Then change the two runner signatures and their `populate` calls (lines 102-137 of the old file):

```ruby
    def run_providers(item, query, selected_providers = nil, match: nil)
      target_providers = filter_providers(selected_providers)

      target_providers.map do |provider|
        provider.populate(item, query: query, match: match)
      rescue => e
        ProviderResult.failure(
          provider: provider.class.name,
          errors: ["Provider error: #{e.message}"]
        )
      end
    end

    def run_providers_with_saving(item, query, is_existing_item, selected_providers = nil, match: nil)
      provider_results = []
      target_providers = filter_providers(selected_providers)

      target_providers.each do |provider|
        result = provider.populate(item, query: query, match: match)
        provider_results << result
```

(the rest of `run_providers_with_saving` and `filter_providers` are unchanged.)

`app/lib/data_importers/provider_base.rb` line 7:

```ruby
    # `match` is the finder's Match for a query-based import (nil for an
    # item-based one): a provider may hydrate from `match.external` or reuse
    # `match.external_resolution` instead of searching again.
    def populate(item, query:, match: nil)
      raise NotImplementedError, "Subclasses must implement #populate(item, query:, match: nil)"
    end
```

`app/lib/data_importers/import_result.rb`:

```ruby
    attr_reader :item, :provider_results, :success, :match

    def initialize(item:, provider_results:, success:, match: nil)
      @item = item
      @provider_results = Array(provider_results)
      @success = success
      @match = match
    end
```

and in `summary`, after `errors: all_errors`:

```ruby
        errors: all_errors,
        match_outcome: match&.outcome,
        match_confidence: match&.confidence
```

- [ ] **Step 4: Add `match: nil` to every provider's `populate`**

Change each listed line to take the keyword; the body is untouched:

| File:line | Before | After |
|---|---|---|
| `games/game/providers/amazon.rb:11` | `def populate(game, query:)` | `def populate(game, query:, match: nil)` |
| `games/game/providers/igdb.rb:33` | `def populate(game, query:)` | `def populate(game, query:, match: nil)` |
| `games/game/providers/cover_art.rb:11` | `def populate(game, query:)` | `def populate(game, query:, match: nil)` |
| `games/company/providers/igdb.rb:15` | `def populate(company, query:)` | `def populate(company, query:, match: nil)` |
| `music/album/providers/music_brainz.rb:16` | `def populate(album, query:)` | `def populate(album, query:, match: nil)` |
| `music/album/providers/ai_description.rb:10` | `def populate(album, query:)` | `def populate(album, query:, match: nil)` |
| `music/album/providers/cover_art.rb:8` | `def populate(album, query:)` | `def populate(album, query:, match: nil)` |
| `music/album/providers/amazon.rb:10` | `def populate(album, query:)` | `def populate(album, query:, match: nil)` |
| `music/artist/providers/music_brainz.rb:16` | `def populate(artist, query:)` | `def populate(artist, query:, match: nil)` |
| `music/artist/providers/ai_description.rb:10` | `def populate(artist, query:)` | `def populate(artist, query:, match: nil)` |
| `music/song/providers/musicbrainz/music_brainz.rb:10` | `def populate(song, query:)` | `def populate(song, query:, match: nil)` |
| `music/release/providers/music_brainz.rb:8` | `def populate(item, query:)` | `def populate(item, query:, match: nil)` |
| `books/book/providers/open_library.rb:40` | `def populate(book, query: nil)` | `def populate(book, query: nil, match: nil)` |

Run `grep -rn "def populate(" app/lib/data_importers` afterwards: every line must contain `match: nil`.

- [ ] **Step 5: Pass `subject:` and `verify:` through the six importer entry points**

`app/lib/data_importers/books/book/importer.rb` lines 9-25:

```ruby
        def self.call(title: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
          if item.present?
            super(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              title: title,
              author_names: author_names,
              year: year,
              isbn13: isbn13,
              isbn10: isbn10,
              asin: asin,
              goodreads_id: goodreads_id,
              open_library_work_key: open_library_work_key
            )
            super(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end
```

`app/lib/data_importers/games/game/importer.rb` lines 9-18:

```ruby
        def self.call(igdb_id: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false, **options)
          if item.present?
            # Item-based import: use provided game
            super(item: item, force_providers: force_providers, providers: providers)
          else
            # Query-based import: create query object
            query = ImportQuery.new(igdb_id: igdb_id, **options)
            super(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end
```

`app/lib/data_importers/games/company/importer.rb` lines 9-12:

```ruby
        def self.call(igdb_id: nil, force_providers: false, subject: nil, verify: false, **options)
          query = ImportQuery.new(igdb_id: igdb_id, **options)
          super(query: query, force_providers: force_providers, subject: subject, verify: verify)
        end
```

`app/lib/data_importers/music/artist/importer.rb` lines 9-12:

```ruby
        def self.call(name: nil, musicbrainz_id: nil, force_providers: false, subject: nil, verify: false, **options)
          query = ImportQuery.new(name: name, musicbrainz_id: musicbrainz_id, **options)
          super(query: query, force_providers: force_providers, subject: subject, verify: verify)
        end
```

`app/lib/data_importers/music/album/importer.rb` lines 9-18:

```ruby
        def self.call(artist: nil, release_group_musicbrainz_id: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false, **options)
          if item.present?
            # Item-based import: use existing album
            super(item: item, force_providers: force_providers, providers: providers)
          else
            # Query-based import: create query object
            query = ImportQuery.new(artist: artist, release_group_musicbrainz_id: release_group_musicbrainz_id, **options)
            super(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end
```

`app/lib/data_importers/music/song/importer.rb` lines 7-10:

```ruby
        def self.call(title: nil, musicbrainz_recording_id: nil, force_providers: false, subject: nil, verify: false, **options)
          query = ImportQuery.new(title: title, musicbrainz_recording_id: musicbrainz_recording_id, **options)
          super(query: query, force_providers: force_providers, subject: subject, verify: verify)
        end
```

- [ ] **Step 6: Update the three importer tests that mock the finder**

`test/lib/data_importers/music/album/importer_test.rb` line 66 and line 234, each `finder.expects(:call).returns(existing_album)` becomes:

```ruby
          finder.expects(:call).returns(DataImporters::Match.new(outcome: :matched, record: existing_album, confidence: :certain, decided_by: :identifier))
```

`test/lib/data_importers/music/song/importer_test.rb` line 119, `finder.expects(:call).returns(existing_song)` becomes:

```ruby
          finder.expects(:call).returns(DataImporters::Match.new(outcome: :matched, record: existing_song, confidence: :certain, decided_by: :identifier))
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/lib/data_importers/importer_base_test.rb test/lib/data_importers/music/album/importer_test.rb test/lib/data_importers/music/song/importer_test.rb test/lib/data_importers/music/release`
Expected: PASS for the base test and the two mocked tests. Any remaining importer-test failure is a real finder returning the old contract; Task 11 fixes those, so run the other importer tests only after it.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers test/lib/data_importers/importer_base_test.rb
git add app/lib/data_importers test/lib/data_importers/importer_base_test.rb test/lib/data_importers/music/album/importer_test.rb test/lib/data_importers/music/song/importer_test.rb
git commit -m "ImporterBase reads match.record and hands the match to providers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Every finder on the new contract, behaviour unchanged; the Release finder deleted

**Files:**
- Modify: `app/lib/data_importers/books/book/finder.rb`, `games/game/finder.rb`, `games/company/finder.rb`, `music/artist/finder.rb`, `music/album/finder.rb`, `music/song/finder.rb`
- Delete: `app/lib/data_importers/music/release/finder.rb`, `test/lib/data_importers/music/release/finder_test.rb`
- Modify: `app/lib/data_importers/music/release/importer.rb:14-16` (remove `finder`)
- Modify tests: `test/lib/data_importers/books/book/finder_test.rb`, `games/game/finder_test.rb`, `games/company/finder_test.rb`, `music/artist/finder_test.rb`, `music/album/finder_test.rb`, `music/song/finder_test.rb`

**Interfaces:**
- Consumes: `FinderBase` (Task 9), `Sources::Legacy` (Task 6).
- Produces: each finder's `#call(query:, …) -> Match`; each finder's old `call` body lives on as the private `legacy_lookup(query)`, unchanged, wrapped as the one decisive source. Increments 2, 5 and 6 replace `candidate_sources` and delete `legacy_lookup`.

The shape every finder takes:

```ruby
class Finder < DataImporters::FinderBase
  protected

  def model_class = ::Books::Book                              # the domain's model
  def ranking_configuration_class = ::Books::RankingConfiguration   # or nil (companies)

  # Increment 1: the pre-redesign lookup, wrapped as the single decisive
  # source so the pipeline runs for real and behaviour stays what it was.
  # Increment N replaces this with the real sources and deletes legacy_lookup.
  def candidate_sources(query)
    [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
  end

  private

  def legacy_lookup(query)
    # the old #call body, verbatim
  end

  # the old private methods, verbatim
end
```

- [ ] **Step 1: Update the finder tests first (they define the behaviour that must not change)**

In every finder test, an assertion on the finder's return value becomes an assertion on `.record`. Change exactly these lines:

`test/lib/data_importers/books/book/finder_test.rb` — lines 19, 28, 37, 50, 58: `assert_equal books_books(:x), result` → `assert_equal books_books(:x), result.record`; lines 66, 74, 82: `assert_nil result` → `assert_nil result.record`.

`test/lib/data_importers/games/company/finder_test.rb` — line 24 → `assert_equal @nintendo, result.record`; lines 31, 42 → `assert_nil result.record`.

`test/lib/data_importers/games/game/finder_test.rb` — line 24 → `assert_equal @zelda, result.record`; lines 31, 42 → `assert_nil result.record`.

`test/lib/data_importers/music/album/finder_test.rb` — lines 39, 57, 187, 200, 224: append `.record` to `result`; lines 74, 90, 99, 125, 142, 159, 212, 243, 251: `assert_nil result` → `assert_nil result.record` (keep any trailing comment).

`test/lib/data_importers/music/artist/finder_test.rb` — lines 30, 45, 76, 111, 127, 151, 171: append `.record`; lines 61, 91, 136: `assert_nil result.record`.

`test/lib/data_importers/music/song/finder_test.rb` — lines 26, 35, 74, 83, 98: append `.record`; lines 44, 51, 105: `assert_nil result.record`.

Then add these two tests to `test/lib/data_importers/books/book/finder_test.rb` (inside the class), which pin the new contract for a finder on the legacy source:

```ruby
        test "a hit is a certain, rule-decided match recorded as a MatchDecision" do
          isbn = identifiers(:war_and_peace_isbn13).value
          query = ImportQuery.new(title: nil, isbn13: [isbn])

          result = @finder.call(query: query)

          assert result.matched?
          assert_equal [:certain, :rule], [result.confidence, result.decided_by]
          assert_equal [:legacy], result.candidates.first.sources
          decision = result.decision
          assert_equal "DataImporters::Books::Book::Finder", decision.finder
          assert_equal books_books(:war_and_peace), decision.record
          assert decision.certain?
          assert_equal [isbn], decision.query["isbn13"]
          assert_not decision.needs_review
        end

        test "a miss is a high-confidence unmatched, recorded with no record" do
          query = ImportQuery.new(title: "No Such Book", author_names: ["Nobody"])

          result = @finder.call(query: query)

          assert result.unmatched?
          assert_nil result.record
          assert_equal [:high, :rule], [result.confidence, result.decided_by]
          assert result.decision.unmatched?
          assert_nil result.decision.record
        end
```

And this one to `test/lib/data_importers/games/game/finder_test.rb`:

```ruby
        test "records a decision on every call" do
          query = ImportQuery.new(igdb_id: 999999)
          query.stubs(:valid?).returns(true)

          assert_difference("MatchDecision.count", 1) { @finder.call(query: query) }
          assert_equal "DataImporters::Games::Game::Finder", MatchDecision.last.finder
        end
```

- [ ] **Step 2: Run the finder tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/finder_test.rb test/lib/data_importers/games test/lib/data_importers/music/artist/finder_test.rb test/lib/data_importers/music/album/finder_test.rb test/lib/data_importers/music/song/finder_test.rb`
Expected: `NoMethodError: undefined method 'record'` (the finders still return records) or `ArgumentError` from the new base `call`.

- [ ] **Step 3: Reshape the six finders**

`app/lib/data_importers/books/book/finder.rb` — replace the whole file:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Finds an existing ::Books::Book before import and answers with a
      # Match (see FinderBase).
      #
      # Increment 1: the pre-redesign lookup -- identifiers first (Open
      # Library work key, ISBN-13, ISBN-10, ASIN, Goodreads id), then an exact
      # title+author match -- runs as the single decisive source, so behaviour
      # is unchanged. Increment 2 replaces it with the identifier, exact,
      # OpenSearch and Open Library sources.
      #
      # Never calls the Open Library service (or any other external API).
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Books::Book

        def ranking_configuration_class = ::Books::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          find_by_identifiers(query) || find_by_title_and_author(query)
        end

        def find_by_identifiers(query)
          if query.open_library_work_key.present?
            found = find_by_identifier(
              identifier_type: :books_work_openlibrary_id,
              identifier_value: query.open_library_work_key,
              model_class: ::Books::Book
            )
            return found if found
          end

          found = find_by_identifier_values(:books_work_isbn13, query.isbn13)
          return found if found

          found = find_by_identifier_values(:books_work_isbn10, query.isbn10)
          return found if found

          found = find_by_identifier_values(:books_work_asin, query.asin)
          return found if found

          find_by_identifier_values(:books_work_goodreads_id, query.goodreads_id)
        end

        def find_by_identifier_values(identifier_type, values)
          values.each do |value|
            found = find_by_identifier(identifier_type: identifier_type, identifier_value: value, model_class: ::Books::Book)
            return found if found
          end

          nil
        end

        def find_by_title_and_author(query)
          return nil if query.title.blank? || query.author_names.empty?

          normalized_title = ::Services::Text::QuoteNormalizer.call(query.title)

          ::Books::Book
            .joins(book_authors: :author)
            .where("LOWER(books_books.title) = LOWER(?)", normalized_title)
            .where("LOWER(books_authors.name) IN (?)", query.author_names.map(&:downcase))
            .first
        end
      end
    end
  end
end
```

`app/lib/data_importers/games/game/finder.rb` — replace the whole file:

```ruby
# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      # Finds an existing Games::Game before import and answers with a Match.
      # Increment 1: the IGDB id lookup runs as the single decisive source;
      # increment 5 adds the exact, OpenSearch and IGDB search sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Games::Game

        def ranking_configuration_class = ::Games::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return nil if query.igdb_id.blank?

          find_by_identifier(
            identifier_type: :games_igdb_id,
            identifier_value: query.igdb_id.to_s,
            model_class: ::Games::Game
          )
        end
      end
    end
  end
end
```

`app/lib/data_importers/games/company/finder.rb` — replace the whole file:

```ruby
# frozen_string_literal: true

module DataImporters
  module Games
    module Company
      # Finds an existing Games::Company before import and answers with a
      # Match. Companies have no ranking, no search index and no external
      # search; the IGDB company id is the lookup, now and after increment 5.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Games::Company

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return nil if query.igdb_id.blank?

          find_by_identifier(
            identifier_type: :games_igdb_company_id,
            identifier_value: query.igdb_id.to_s,
            model_class: ::Games::Company
          )
        end
      end
    end
  end
end
```

`app/lib/data_importers/music/artist/finder.rb` — replace lines 6-19 (the class header through the end of `call`) with:

```ruby
      # Finds an existing Music::Artist before import and answers with a Match.
      # Increment 1: the pre-redesign lookup (MBID, else a MusicBrainz name
      # search resolved to a local MBID, else exact name) runs as the single
      # decisive source. Increment 6 replaces it with the real sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Music::Artist

        def ranking_configuration_class = ::Music::Artists::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return find_existing_item(query) if query.musicbrainz_id.present?

          find_existing_item_by_name(query)
        end
```

Delete the now-duplicated `private` line that followed the old `call` (the file had `private` at line 13); everything from `find_existing_item` on stays verbatim.

`app/lib/data_importers/music/album/finder.rb` — replace lines 6-8 (`class Finder < DataImporters::FinderBase` and `def call(query:)`) with:

```ruby
      # Finds an existing Music::Album before import and answers with a Match.
      # Increment 1: the pre-redesign lookup (release-group MBID, else an
      # artist-scoped MusicBrainz search resolved to a local MBID, else exact
      # title within the artist) runs as the single decisive source.
      # Increment 6 replaces it with the real sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Music::Album

        def ranking_configuration_class = ::Music::Albums::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
```

The body of the old `call` (from `# Handle direct release group MBID lookup` through the closing `nil` / `end`) is now the body of `legacy_lookup`, verbatim. Delete the old `private` line that followed it (line 40 of the original); the old private methods stay verbatim beneath. Mocha still stubs `search_service`, `find_by_musicbrainz_id`, `find_by_musicbrainz_id_only` and `find_by_title` on the instance exactly as the tests do today.

`app/lib/data_importers/music/song/finder.rb` — replace the whole file:

```ruby
# frozen_string_literal: true

module DataImporters
  module Music
    module Song
      # Finds an existing Music::Song before import and answers with a Match.
      # Increment 1: the pre-redesign lookup (recording MBID, else a bare
      # title match) runs as the single decisive source. Increment 6 replaces
      # it, and retires the title-only fallback, with the real sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Music::Song

        def ranking_configuration_class = ::Music::Songs::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return find_by_musicbrainz_id(query.musicbrainz_recording_id) if query.musicbrainz_recording_id.present?

          find_by_title(query.title)
        end

        def find_by_musicbrainz_id(mbid)
          find_by_identifier(
            identifier_type: :music_musicbrainz_recording_id,
            identifier_value: mbid,
            model_class: ::Music::Song
          )
        end

        def find_by_title(title)
          ::Music::Song.find_by(title: title)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Delete the unreachable Release finder**

```bash
git rm app/lib/data_importers/music/release/finder.rb test/lib/data_importers/music/release/finder_test.rb
```

and remove lines 14-16 of `app/lib/data_importers/music/release/importer.rb` (`def finder … end`). `ImporterBase#call` never calls `finder` when `multi_item_import?` is true, so nothing else references it.

- [ ] **Step 5: Run every data_importers test**

Run: `bin/rails test test/lib/data_importers && CI=1 bin/rails zeitwerk:check`
Expected: PASS, including every importer and provider test. If an importer test now sees one more `Rails.logger.warn` than it `expects`, the extra call is the finder's source-failure warning and means a legacy lookup raised instead of rescuing; the legacy lookups rescue internally (album, artist, release-group search), so this should not happen. Report it rather than loosening the expectation.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers test/lib/data_importers
git add -A app/lib/data_importers test/lib/data_importers
git commit -m "Every finder answers with a Match; the unreachable Release finder is gone

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: The merger hook

**Files:**
- Modify: `app/lib/books/book/merger.rb:60-68`, `app/lib/books/author/merger.rb:53-60`, `app/lib/music/album/merger.rb:30-36`, `app/lib/music/artist/merger.rb:30-36`, `app/lib/music/song/merger.rb:30-36`, `app/lib/games/game/merger.rb:30-38`
- Test: `test/lib/books/book/merger_test.rb`, `test/lib/books/author/merger_test.rb`, `test/lib/music/album/merger_test.rb`, `test/lib/music/artist/merger_test.rb`, `test/lib/music/song/merger_test.rb`, `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: `DuplicateCandidate.record_merge(item_type:, source_id:, target_id:)` (Task 4).
- Produces: each merger calls it inside its transaction, immediately before destroying the source.

- [ ] **Step 1: Write the failing tests**

Add one test to each merger test file, inside the existing class, using that file's `setup` ivars.

`test/lib/books/book/merger_test.rb`:

```ruby
    test "records the merge on duplicate_candidates and repoints match decisions to the target" do
      third = books_books(:combo_steinbeck)
      pair = DuplicateCandidate.flag!(item_type: "Books::Book", ids: [@source.id, @target.id], source: :ai)
      other_pair = DuplicateCandidate.flag!(item_type: "Books::Book", ids: [@source.id, third.id], source: :ai)
      decision = MatchDecision.create!(finder: "F", record: @source, outcome: :matched, confidence: :high, decided_by: :ai)

      result = ::Books::Book::Merger.call(source: @source, target: @target)

      assert result.success?, result.errors.inspect
      assert pair.reload.merged?
      assert_equal [@target.id, third.id].minmax, [other_pair.reload.item_a_id, other_pair.item_b_id]
      assert_equal [@target.id, "Books::Book"], [decision.reload.record_id, decision.record_type]
    end
```

`test/lib/books/author/merger_test.rb`:

```ruby
    test "records the merge on duplicate_candidates and repoints match decisions to the target" do
      third = books_authors(:tolstoy)
      pair = DuplicateCandidate.flag!(item_type: "Books::Author", ids: [@source.id, @target.id], source: :ai)
      other_pair = DuplicateCandidate.flag!(item_type: "Books::Author", ids: [@source.id, third.id], source: :ai)
      decision = MatchDecision.create!(finder: "F", record: @source, outcome: :matched, confidence: :high, decided_by: :ai)

      result = ::Books::Author::Merger.call(source: @source, target: @target)

      assert result.success?, result.errors.inspect
      assert pair.reload.merged?
      assert_equal [@target.id, third.id].minmax, [other_pair.reload.item_a_id, other_pair.item_b_id]
      assert_equal @target.id, decision.reload.record_id
    end
```

`test/lib/music/album/merger_test.rb`:

```ruby
    test "records the merge on duplicate_candidates and repoints match decisions to the target" do
      third = music_albums(:animals)
      pair = DuplicateCandidate.flag!(item_type: "Music::Album", ids: [@source_album.id, @target_album.id], source: :ai)
      other_pair = DuplicateCandidate.flag!(item_type: "Music::Album", ids: [@source_album.id, third.id], source: :ai)
      decision = MatchDecision.create!(finder: "F", record: @source_album, outcome: :matched, confidence: :high, decided_by: :ai)

      result = Music::Album::Merger.call(source: @source_album, target: @target_album)

      assert result.success?, result.errors.inspect
      assert pair.reload.merged?
      assert_equal [@target_album.id, third.id].minmax, [other_pair.reload.item_a_id, other_pair.item_b_id]
      assert_equal @target_album.id, decision.reload.record_id
    end
```

`test/lib/music/artist/merger_test.rb`:

```ruby
    test "records the merge on duplicate_candidates and repoints match decisions to the target" do
      third = music_artists(:david_bowie)
      pair = DuplicateCandidate.flag!(item_type: "Music::Artist", ids: [@source_artist.id, @target_artist.id], source: :ai)
      other_pair = DuplicateCandidate.flag!(item_type: "Music::Artist", ids: [@source_artist.id, third.id], source: :ai)
      decision = MatchDecision.create!(finder: "F", record: @source_artist, outcome: :matched, confidence: :high, decided_by: :ai)

      result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

      assert result.success?, result.errors.inspect
      assert pair.reload.merged?
      assert_equal [@target_artist.id, third.id].minmax, [other_pair.reload.item_a_id, other_pair.item_b_id]
      assert_equal @target_artist.id, decision.reload.record_id
    end
```

`test/lib/music/song/merger_test.rb`:

```ruby
    test "records the merge on duplicate_candidates and repoints match decisions to the target" do
      third = music_songs(:wish_you_were_here)
      pair = DuplicateCandidate.flag!(item_type: "Music::Song", ids: [@source_song.id, @target_song.id], source: :ai)
      other_pair = DuplicateCandidate.flag!(item_type: "Music::Song", ids: [@source_song.id, third.id], source: :ai)
      decision = MatchDecision.create!(finder: "F", record: @source_song, outcome: :matched, confidence: :high, decided_by: :ai)

      result = Music::Song::Merger.call(source: @source_song, target: @target_song)

      assert result.success?, result.errors.inspect
      assert pair.reload.merged?
      assert_equal [@target_song.id, third.id].minmax, [other_pair.reload.item_a_id, other_pair.item_b_id]
      assert_equal @target_song.id, decision.reload.record_id
    end
```

`test/lib/games/game/merger_test.rb`:

```ruby
    test "records the merge on duplicate_candidates and repoints match decisions to the target" do
      third = games_games(:resident_evil_4)
      pair = DuplicateCandidate.flag!(item_type: "Games::Game", ids: [@source.id, @target.id], source: :ai)
      other_pair = DuplicateCandidate.flag!(item_type: "Games::Game", ids: [@source.id, third.id], source: :ai)
      decision = MatchDecision.create!(finder: "F", record: @source, outcome: :matched, confidence: :high, decided_by: :ai)

      result = ::Games::Game::Merger.call(source: @source, target: @target)

      assert result.success?, result.errors.inspect
      assert pair.reload.merged?
      assert_equal [@target.id, third.id].minmax, [other_pair.reload.item_a_id, other_pair.item_b_id]
      assert_equal @target.id, decision.reload.record_id
    end
```

If `music_songs(:wish_you_were_here)` does not exist, use any third song fixture name from `test/fixtures/music/songs.yml` and say which in the task report.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb test/lib/music/album/merger_test.rb test/lib/music/artist/merger_test.rb test/lib/music/song/merger_test.rb test/lib/games/game/merger_test.rb -n /duplicate_candidates/`
Expected: six failures — the pair is still `pending`.

- [ ] **Step 3: Add the hook to each merger**

Insert one call inside each transaction block, on the line before the destroy, and one private method next to the destroy method. The ivar and target names differ per merger:

`app/lib/books/book/merger.rb`, transaction (lines 60-68) becomes:

```ruby
      ActiveRecord::Base.transaction do
        lock_books
        collect_affected_ranking_configurations
        merge_all_associations
        reconcile_scalars
        target_book.save! if target_book.changed?
        resolve_duplicate_candidates
        destroy_source_book
        @transaction_body_completed = true
      end
```

and next to `destroy_source_book` (line 602):

```ruby
    # The (source, target) pair on duplicate_candidates becomes merged, other
    # pending pairs naming the source re-key onto the target, and
    # match_decisions that named the source now name the target. Inside the
    # transaction so a rollback undoes it with the rest.
    def resolve_duplicate_candidates
      ::DuplicateCandidate.record_merge(item_type: "Books::Book", source_id: @source_book_id, target_id: target_book.id)
    end
```

`app/lib/books/author/merger.rb`: insert `resolve_duplicate_candidates` before `destroy_source_author` (line 58); method uses `item_type: "Books::Author", source_id: @source_author_id, target_id: target_author.id`.

`app/lib/music/album/merger.rb`: before `destroy_source_album` (line 34); `item_type: "Music::Album", source_id: @source_album_id, target_id: target_album.id`.

`app/lib/music/artist/merger.rb`: before `destroy_source_artist` (line 34); `item_type: "Music::Artist", source_id: @source_artist_id, target_id: target_artist.id`.

`app/lib/music/song/merger.rb`: before `destroy_source_song` (line 34); `item_type: "Music::Song", source_id: @source_song_id, target_id: target_song.id`.

`app/lib/games/game/merger.rb`: before `destroy_source_game` (line 36); `item_type: "Games::Game", source_id: @source_game_id, target_id: target_game.id`.

Each method carries the same comment as the books one, with its own item type.

- [ ] **Step 4: Run the merger tests**

Run: `bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb test/lib/music/album/merger_test.rb test/lib/music/artist/merger_test.rb test/lib/music/song/merger_test.rb test/lib/games/game/merger_test.rb`
Expected: PASS, every test in all six files.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books app/lib/music app/lib/games test/lib/books test/lib/music test/lib/games
git add app/lib/books/book/merger.rb app/lib/books/author/merger.rb app/lib/music/album/merger.rb app/lib/music/artist/merger.rb app/lib/music/song/merger.rb app/lib/games/game/merger.rb test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb test/lib/music/album/merger_test.rb test/lib/music/artist/merger_test.rb test/lib/music/song/merger_test.rb test/lib/games/game/merger_test.rb
git commit -m "Mergers record the merge on duplicate_candidates and repoint decisions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Docs, spec amendments, full verification

**Files:**
- Create: `docs/features/import-finder.md`
- Modify: `docs/features/data_importers.md` (the "Core Design Principles" bullet on duplicate detection, the "Import Flow" step 2, the `FinderBase` line in "Base Classes"), `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` (three naming amendments)

- [ ] **Step 1: Write the feature doc**

`docs/features/import-finder.md`:

```markdown
# Import finder

Every `DataImporters::<Domain>::<Model>::Finder` answers "is this thing already in our
catalog?" with a `DataImporters::Match`, and records that answer as a `MatchDecision` row.
Design: `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md`.

## The contract

`Finder#call(query:, verify: false, subject: nil, exclude: nil) -> Match`

| Field | Meaning |
|---|---|
| `outcome` | `:matched` or `:unmatched` (the spec calls the latter "new") |
| `record` | the local record, nil when unmatched |
| `confidence` | `:certain`, `:high`, `:medium`, `:low` |
| `decided_by` | `:identifier`, `:rule`, `:ai`, `:fallback` |
| `reason` | one sentence |
| `candidates` | every `Candidate` considered, in the order the AI saw them |
| `external` | the best external candidate to hydrate from when unmatched |
| `external_resolution` | a whole external response a source kept for the provider |
| `decision` | the persisted `MatchDecision` |
| `sources_failed` | names of sources that raised |
| `needs_review?` | medium or low confidence, or a fallback |

`verify: true` disables every early exit (identifier hits become evidence, every source
runs). `subject:` is what the caller was resolving for (a list item) and is stored on the
decision and used as the AI chat's parent. `exclude:` drops one record from every source,
which is how a record is resolved against the rest of the catalog.

The finder never creates or mutates catalog records and is not transactional. `ImporterBase`
reads `match.record`, hands the match to every provider (`populate(item, query:, match: nil)`),
and points the decision at a record it creates.

## The four stages (`FinderBase#call`)

1. **Gather.** Each source in `candidate_sources(query)` is called; results are unioned by
   `CandidateSet` (merged by local record or by external key). A source that raises adds
   nothing and is named in `sources_failed`. Gathering stops early at a decisive candidate
   (a `:legacy` hit, or a corroborated identifier hit or external accept) unless `verify`.
2. **Rules** (`Decider`): 0 legacy hit → matched certain; 1 corroborated identifier hit →
   matched certain (several: ranked, then most lists, then oldest; the rest flagged as
   `identifier_collision` pairs); 2 external accept on a locally held key, corroborated →
   matched certain; 3 no candidates → unmatched high; 4 one local candidate that matches
   exactly → matched high; 5 no local candidates and an accepted external → unmatched high
   with `external`; else the AI. Rules 0–2 never fire under `verify`.
3. **AI** (`Services::Ai::Tasks::Matching::SelectCandidateTask`, one gpt-5-mini call): the
   incoming item and at most six candidate lines, select one or 0, with confidence,
   reasoning and `same_entity_groups`. `AiSelection` turns that into a decision: a ranked
   record wins a same-entity group over an unranked pick; every group of two local records
   becomes a duplicate pair. A failed call falls back to unmatched, low, `:fallback`.
4. **Record.** A `MatchDecision` is always written (a failed fuzzy source caps a high
   confidence at medium so the decision is reviewed). Pairs go through
   `DuplicateCandidate.flag!`.

**Corroboration**: an identifier hit or an external accept is trusted only when the record
agrees with the query on its title (or an alternate title) or on a creator (or an alternate
name), or when the query carried nothing to compare. **Exact match** (rule 4): equal
normalized title, agreeing creators where the domain has them, no year conflict (both
present and more than two apart).

## Sources (`DataImporters::Sources`)

Each has `#name` and `#call -> [Candidate]`. `Identifiers` (Postgres, never decisive on its
own), `Exact` (one relation the finder builds; the `lower(title)`/`lower(name)` expression
indexes serve it), `OpenSearch` (the domain's title-plus-creators query, top five), and
`Legacy` (increment 1 only: the pre-redesign lookup as a single decisive source). A source
that responds to `#resolution` after `#call` has it copied onto the match.

## Tables

`match_decisions`: one row per finder call — finder, polymorphic record and subject,
outcome/confidence/decided_by enums, `verify`, `query` and `candidates` jsonb snapshots,
`selected_index` (1-based), `reason`, `ai_chat_id`, `sources_failed`, and the audit columns
`needs_review`, `reviewed_at`, `reviewed_by_id`, `review_note`.

`duplicate_candidates`: one row per unordered pair of local records (`item_a_id <
item_b_id`, unique with `item_type`), `source` (identifier_collision, external_key_collision,
ai, human, bulk_verify), `status` (pending, merged, not_duplicate), `evidence`,
`occurrences`, the first `match_decision_id`, and the resolution columns. `flag!` never
reopens a `merged` or `not_duplicate` row; a pending one gains an occurrence and evidence.
Every merger calls `DuplicateCandidate.record_merge` inside its transaction: the pair
becomes merged, other pending pairs naming the source re-key onto the target, and decisions
that named the source now name the target.

## State after increment 1

Every finder wraps its pre-redesign lookup as the `Legacy` source, so what matches today is
exactly what matched before; the difference is the return type and the decision row.
Increment 2 (books), 5 (games) and 6 (music) replace `candidate_sources` with the real
sources and delete each `legacy_lookup`. The audit UI is increment 3; the authors importer
is increment 4.

## Adding a domain

Subclass `FinderBase`, implement `model_class` and `candidate_sources(query)`, and override
the hooks the rules and the prompt need: `ranking_configuration_class`, `creators_required?`,
`query_title`, `query_creators`, `query_year`, `record_creators`,
`record_creator_alternate_names`, `record_year`, and `domain_guidance` (prompt text).
`describe_query` and `describe_candidate` have sensible defaults built from those hooks.
```

- [ ] **Step 2: Update `docs/features/data_importers.md`**

Replace the bullet `- **Intelligent Duplicate Detection**: Uses external identifiers and fallback matching strategies` (line 13) with:

```markdown
- **Finder returns a decision, not a record**: every finder answers with a `Match` (matched or unmatched, confidence, candidates, who decided, why) and records a `MatchDecision`. See [Import finder](./import-finder.md).
```

Replace the `FinderBase` line (line 19) with:

```markdown
- **FinderBase** - The four-stage finder pipeline (gather candidates, rules, AI selection, record); see [Import finder](./import-finder.md)
```

Replace "Import Flow" step 2 and 3 (lines 249-250) with:

```markdown
2. **Find Existing**: The finder returns a `Match`; `match.record` is the existing record or nil
3. **Early Return**: Skip providers if a record matched (unless force_providers: true); providers otherwise receive the match as `populate(item, query:, match:)`
```

- [ ] **Step 3: Amend the spec for the three names**

In `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md`:

- §1: in the `Match` sketch change `outcome        :matched | :new` to `outcome        :matched | :unmatched   (the spec's "new"; an enum value \`new\` would shadow MatchDecision.new)` and `needs_review?`'s line stays; change `FinderBase#call` prose that says "matched or new" nowhere else.
- §5: `| \`outcome\` | enum: matched 0, new 1 | |` → `| \`outcome\` | enum: matched 0, unmatched 1 | |`; `| \`status\` | enum: open 0, merged 1, not_duplicate 2 | |` → `| \`status\` | enum: pending 0, merged 1, not_duplicate 2 | | ` and the sentence "an open row gains an occurrence" → "a pending row gains an occurrence".
- §2: "Sources are small objects with `call(query) -> [Candidate]`" → "Sources are small objects with `#name` and `#call -> [Candidate]`, built by the finder with what they need".
- Add to "Decisions made during brainstorming": `- **Three names changed at implementation:** outcome \`unmatched\` (not \`new\`), pair status \`pending\` (not \`open\`), and sources take no argument on \`call\`. Increment 1's plan explains each.`

- [ ] **Step 4: Full verification**

Run, from `web-app/`, and paste the tail of each into the task report:

```bash
bin/rails test 2>&1 | tail -5
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
bin/rails test 2>&1 | grep -ci "warning"
```

Expected: `0 failures, 0 errors`; standardrb silent; zeitwerk "All is good!"; the warning count no higher than on `main` (compare with `git stash`-free method: check out `main` in a second terminal is not needed — the count on main is the two known npm/yarn lines during `test:prepare`).

- [ ] **Step 5: Commit**

```bash
git add docs/features/import-finder.md docs/features/data_importers.md ../docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md
git commit -m "Docs: the import finder contract, tables and increment-1 state

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(`docs/` is at the project root; from `web-app/` the paths are `../docs/…` — use those in the `git add`.)

---

## Plan self-review

**Spec coverage (increment 1 items):** contract and hooks (Task 9); Match/Candidate (Task 5); the three shared sources plus Legacy (Task 6); rules with corroboration, `verify`, tie-break, collision pairs (Task 7); `SelectCandidateTask` with the select-one-or-none prompt, cleaned groups, nil parent (Task 8); ranked post-rule and never-merge (Task 9 via `AiSelection`); `match_decisions` (Task 3) and `duplicate_candidates` with never-re-raise, occurrences, `record_merge` (Task 4); `ImporterBase`/`ProviderBase`/13 providers/6 importers/`ImportResult#match`, decision pointed at the created record (Task 10); every finder on the contract with unchanged lookups, Release finder deleted (Task 11); six merger hooks (Task 12); expression indexes (Task 2); `NameNormalizer` on author names and book titles (Task 1); `sources_failed` and the confidence cap (Task 9); `exclude:` (Task 9). Docs and the three spec amendments (Task 13). Not in this increment by design: real sources per domain, the audit UI, the authors importer, the whitespace one-off task, the sweep job.

**Type consistency:** `Match` fields are the same in Tasks 5, 9, 10; `Candidate#snapshot` keys match the `MatchDecision.candidates` reads in Task 9's tests; `Decision#duplicate_pairs` triples are consumed by `FinderBase#record`; `Sources::*#name` symbols (`:identifier`, `:exact`, `:opensearch`, `:legacy`) are the same symbols the rules test for in `sources`; `DuplicateCandidate.flag!`/`record_merge`/`not_duplicate?` signatures match Tasks 9 and 12; `SelectCandidateTask.new` keywords match `FinderBase#decide`.
