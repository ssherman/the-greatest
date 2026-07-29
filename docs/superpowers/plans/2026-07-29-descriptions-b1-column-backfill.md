# Descriptions Subsystem — Increment (b1): Games/Music Column Backfill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the five in-app games/music `description` columns onto `Description` rows — 11,382 of them — without touching the columns themselves or changing any page.

**Architecture:** A standalone `Services::DescriptionColumnBackfill` streams each model, skips blank values, and bulk-inserts `Description` rows with `insert_all` (ON CONFLICT DO NOTHING). It deliberately does **not** subclass `Services::BooksMigration::BulkUpsertMigrator`: that base and its parent both stream from a `legacy_model` and wrap the load in `BooksMigration.without_search_indexing`, and this backfill has neither. A rake task under the existing `data_migration:` namespace runs it.

**Tech Stack:** Rails 8.1.3, Ruby 3.4.7, PostgreSQL 17.4, Minitest + fixtures.

**Spec:** `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md` (increment b1)

## Global Constraints

- Run every command from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` — **not** `bin/rubocop`. `--fix` autocorrects.
- Do **not** run `bin/brakeman`.
- **Never run a destructive DB command against development.** `db:migrate` / `db:test:prepare` are fine; `db:drop`/`db:reset`/`db:schema:load` and `ActiveRecord::FixtureSet.create_fixtures` are hard-blocked by a `PreToolUse` hook and would destroy books data that exists **only** in development. This increment needs no schema change at all.
- Services live in `app/lib/services/`, **not** `app/services/`. Tests mirror to `test/lib/services/`.
- Skinny models, fat services. Result pattern: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` — `keyword_init` is kept deliberately (a Standard cop is disabled for it).
- **No code comments** unless a comment explains something non-obvious the code cannot say itself.
- **`insert_all`, never `upsert_all`.** Verified on PG 17: an `upsert_all` re-run resets a human's `rank: :preferred` back to `:normal` and overwrites edited content, violating D5 ("importers may never write `rank`"). `insert_all` with `unique_by:` leaves existing rows untouched. Both cast enum symbols correctly.
- Every row written here is `kind: :summary`, `locale: "en"`, `rank: :normal`, `source_name: nil`, `license: nil`, `source_url: nil`, `retrieved_at: nil`. `source_name` **must** be nil — the `descriptions_source_name_matches_source` check constraint rejects a named source that carries one.

## Scope note

Increment b1 covers **only** the five games/music columns. The spec's books/authors safety net (~50 books, ~21 authors created in-app rather than migrated) depends on the legacy backfill having already run, so it belongs to **b2**, after `BookDescriptionMigrator` and `AuthorDescriptionMigrator`.

## Verified current state (2026-07-29)

| Model | non-null `description` | non-empty | empty-string |
|---|---|---|---|
| `Games::Game` | 1,602 | **1,602** | 0 |
| `Games::Company` | 673 | **658** | 15 |
| `Games::Series` | 15 | **5** | 10 |
| `Music::Album` | 3,662 | **3,649** | 13 |
| `Music::Artist` | 5,471 | **5,468** | 3 |
| **total** | | **11,382** | **41** |

Those **41 empty-string rows are the point of the `.presence` guard.** A `build_rows` testing truthiness instead would try to insert 41 blank-content rows, and `descriptions_content_not_blank` would reject the whole batch with a `CheckViolation`. This is not a hypothetical — it fires on the first run.

`Description.count` is currently 0. `Music::Album.polymorphic_name` → `"Music::Album"`, so `record.class.polymorphic_name` is the correct value for `describable_type`.

---

### Task 1: `Services::DescriptionColumnBackfill`

**Files:**
- Create: `web-app/app/lib/services/description_column_backfill.rb`
- Create: `web-app/test/lib/services/description_column_backfill_test.rb`

**Interfaces:**
- Consumes: `Description` (enums `kind`/`rank` unprefixed, `source`/`license` prefixed), and the unique index `index_descriptions_on_describable_and_key`.
- Produces: `Services::DescriptionColumnBackfill.call -> Result`, where `Result` responds to `success?`, `data`, `errors`. `data` is `{counts: {"Games::Game" => 1602, ...}, total: 11382}` keyed by model name. Task 2's rake task prints this.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/description_column_backfill_test.rb`:

```ruby
require "test_helper"

module Services
  class DescriptionColumnBackfillTest < ActiveSupport::TestCase
    test "creates a description row per populated column with the right source" do
      games_games(:tears_of_the_kingdom).update_column(:description, "A sequel across sky islands.")
      games_companies(:capcom).update_column(:description, "A Japanese game developer and publisher.")
      games_series(:resident_evil).update_column(:description, "A survival horror series.")
      music_albums(:animals).update_column(:description, "A concept album loosely based on Animal Farm.")
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")

      Services::DescriptionColumnBackfill.call

      assert_equal "igdb", Description.find_by(describable: games_games(:tears_of_the_kingdom)).source
      assert_equal "igdb", Description.find_by(describable: games_companies(:capcom)).source
      assert_equal "manual", Description.find_by(describable: games_series(:resident_evil)).source
      assert_equal "ai_generated", Description.find_by(describable: music_albums(:animals)).source
      assert_equal "ai_generated", Description.find_by(describable: music_artists(:roger_waters)).source
    end

    test "writes summary kind, en locale, normal rank and no source_name" do
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")

      Services::DescriptionColumnBackfill.call

      row = Description.find_by(describable: music_artists(:roger_waters))
      assert_equal "summary", row.kind
      assert_equal "en", row.locale
      assert_equal "normal", row.rank
      assert_nil row.source_name
      assert_nil row.license
      assert_nil row.retrieved_at
      assert_equal "English songwriter and bassist.", row.content
    end

    test "skips nil, empty and whitespace-only descriptions" do
      music_artists(:roger_waters).update_column(:description, "")
      music_artists(:david_gilmour).update_column(:description, "   ")
      music_albums(:animals).update_column(:description, nil)

      Services::DescriptionColumnBackfill.call

      assert_nil Description.find_by(describable: music_artists(:roger_waters))
      assert_nil Description.find_by(describable: music_artists(:david_gilmour))
      assert_nil Description.find_by(describable: music_albums(:animals))
    end

    test "leaves an existing description row untouched" do
      existing = descriptions(:dark_side_ai)
      music_albums(:dark_side_of_the_moon).update_column(:description, "column text that must not win")

      Services::DescriptionColumnBackfill.call

      existing.reload
      assert_equal "preferred", existing.rank
      assert_not_equal "column text that must not win", existing.content
    end

    test "is idempotent" do
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")
      Services::DescriptionColumnBackfill.call
      after_first = Description.count

      assert_no_difference "Description.count" do
        Services::DescriptionColumnBackfill.call
      end
      assert_equal after_first, Description.count
    end

    test "does not create rows for books" do
      before = Description.where(describable_type: ["Books::Book", "Books::Author"]).count

      Services::DescriptionColumnBackfill.call

      assert_equal before, Description.where(describable_type: ["Books::Book", "Books::Author"]).count
    end

    test "returns a successful result with per-model counts and a total" do
      games_games(:tears_of_the_kingdom).update_column(:description, "A sequel across sky islands.")
      music_artists(:roger_waters).update_column(:description, "English songwriter and bassist.")

      result = Services::DescriptionColumnBackfill.call

      assert result.success?
      assert_empty result.errors
      assert_equal Games::Game.where.not(description: [nil, ""]).count,
        result.data[:counts]["Games::Game"]
      assert_equal Music::Artist.where.not(description: [nil, ""]).count,
        result.data[:counts]["Music::Artist"]
      assert_equal result.data[:counts].values.sum, result.data[:total]
    end
  end
end
```

`update_column` writes straight to the database, skipping validations and callbacks, so these fixtures are modified without side effects and the change rolls back with the test transaction.

Note that `music/albums.yml` and `music/artists.yml` already set `description` on six fixtures each, so the backfill legitimately creates rows for them on every run. That is why the blank-skipping test asserts per-record `nil` rather than a global `Description.count`, and why the counts test derives its expectation from the database instead of hardcoding a number. The games fixtures set no descriptions.

The fourth test is the one that matters most: `descriptions(:dark_side_ai)` is a `preferred` row on `dark_side_of_the_moon`, so it pins the invariant that a re-run cannot demote or overwrite an editorial choice. It fails if anyone swaps `insert_all` for `upsert_all`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/description_column_backfill_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::DescriptionColumnBackfill`.

- [ ] **Step 3: Write the service**

Create `app/lib/services/description_column_backfill.rb`:

```ruby
module Services
  class DescriptionColumnBackfill
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    INSERT_BATCH = 1000

    SOURCE_BY_MODEL = {
      "Games::Game" => :igdb,
      "Games::Company" => :igdb,
      "Games::Series" => :manual,
      "Music::Album" => :ai_generated,
      "Music::Artist" => :ai_generated
    }.freeze

    def self.call
      new.call
    end

    def call
      counts = SOURCE_BY_MODEL.each_with_object({}) do |(model_name, source), acc|
        acc[model_name] = backfill(model_name.constantize, source)
      end
      Result.new(success?: true, data: {counts: counts, total: counts.values.sum}, errors: [])
    rescue => e
      Result.new(success?: false, data: {}, errors: [e.message])
    end

    private

    def backfill(model, source)
      written = 0
      buffer = []

      model.where.not(description: [nil, ""]).find_each(batch_size: INSERT_BATCH) do |record|
        content = record.description.presence
        next if content.nil?

        buffer << row_for(record, source, content)
        if buffer.size >= INSERT_BATCH
          written += flush(buffer)
          buffer = []
        end
      end

      written += flush(buffer) if buffer.any?
      written
    end

    def row_for(record, source, content)
      {
        describable_type: record.class.polymorphic_name,
        describable_id: record.id,
        kind: :summary,
        locale: "en",
        source: source,
        content: content,
        rank: :normal
      }
    end

    # insert_all, not upsert_all: ON CONFLICT DO NOTHING leaves an existing row alone.
    # upsert_all would reset a human's rank: :preferred back to :normal and overwrite
    # edited content on every re-run.
    def flush(rows)
      Description.insert_all(rows, unique_by: :index_descriptions_on_describable_and_key)
      rows.size
    end
  end
end
```

`.presence` catches whitespace-only values that the `where.not` cannot; the `where.not` merely avoids loading obvious blanks. Both are needed — 41 rows in production data are empty strings, and `descriptions_content_not_blank` would reject the whole batch if they got through.

Note `flush` returns `rows.size`, which counts rows *offered*, not rows actually inserted — a row skipped by ON CONFLICT still counts. That is intentional: the number is a progress figure for the rake output, and the authoritative check is `Description.count` in Task 2.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/description_column_backfill_test.rb`
Expected: PASS, 7 tests, 0 failures.

- [ ] **Step 5: Lint and run the full suite**

```bash
bundle exec standardrb --fix app/lib/services/description_column_backfill.rb test/lib/services/description_column_backfill_test.rb
bundle exec standardrb
bin/rails test
```

Expected: standardrb clean, suite green with no new failures.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/description_column_backfill.rb test/lib/services/description_column_backfill_test.rb
git commit -m "Add Services::DescriptionColumnBackfill

Lifts the five in-app games/music description columns onto Description rows.
insert_all rather than upsert_all: a re-run must not reset a human's
rank: :preferred or overwrite edited content, which upsert_all does.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rake task and the dev run

**Files:**
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `Services::DescriptionColumnBackfill.call -> Result` from Task 1.
- Produces: `bin/rails data_migration:description_columns`.

- [ ] **Step 1: Add the rake task**

In `lib/tasks/data_migration.rake`, add immediately before the final `task all:` line (this task is standalone and must **not** join `:all`, which is the legacy books Phase-1 chain):

```ruby
  desc "Backfill Description rows from the in-app games/music description columns (reads the current DB, no legacy connection)"
  task description_columns: :environment do
    pp Services::DescriptionColumnBackfill.call
  end
```

- [ ] **Step 2: Verify the task is registered**

Run: `bin/rails -T data_migration | grep description_columns`
Expected: one line describing the task.

- [ ] **Step 3: Snapshot the development database**

```bash
bin/snapshot-dev-db.sh --label pre-b1-description-columns
```

This is a data-writing run against a database whose books content exists nowhere else. The snapshot turns any mistake into a ~1 minute restore.

- [ ] **Step 4: Record the pre-run state**

```bash
bin/rails runner 'puts "Description.count before: #{Description.count}"'
```

Expected: `0`.

- [ ] **Step 5: Run the backfill**

Run: `bin/rails data_migration:description_columns`

Expected output — a `Result` with `success?: true` and:

```
counts: {"Games::Game"=>1602, "Games::Company"=>658, "Games::Series"=>5,
         "Music::Album"=>3649, "Music::Artist"=>5468}
total: 11382
```

- [ ] **Step 6: Verify the result against the database**

```bash
bin/rails runner '
puts "total: #{Description.count} (expected 11382)"
puts Description.group(:describable_type).count.inspect
puts "non-summary kinds:  #{Description.where.not(kind: :summary).count} (expected 0)"
puts "non-en locales:     #{Description.where.not(locale: "en").count} (expected 0)"
puts "non-normal ranks:   #{Description.where.not(rank: :normal).count} (expected 0)"
puts "with source_name:   #{Description.where.not(source_name: nil).count} (expected 0)"
puts "blank content:      #{Description.where("btrim(content) = ?", "").count} (expected 0)"
puts "books rows:         #{Description.where(describable_type: ["Books::Book", "Books::Author"]).count} (expected 0)"
'
```

Expected: total 11382; per-type `{"Music::Artist"=>5468, "Music::Album"=>3649, "Games::Game"=>1602, "Games::Company"=>658, "Games::Series"=>5}`; every other line 0.

If the total is short, the likely cause is the `.presence` guard behaving differently than expected on the 41 empty-string rows — report the actual counts rather than adjusting the expectation.

- [ ] **Step 7: Verify idempotency and non-clobbering on real data**

```bash
bin/rails runner '
d = Description.find_by(describable_type: "Music::Album")
original_content = d.content
original_rank = d.rank
d.update!(rank: :preferred, content: "editorial override")
before = Description.count

Services::DescriptionColumnBackfill.call

d.reload
puts "count stable:   #{Description.count == before} (#{before})"
puts "rank preserved: #{d.rank == "preferred"}"
puts "content kept:   #{d.content == "editorial override"}"

d.update!(rank: original_rank, content: original_content)
puts "restored:       rank=#{d.reload.rank} content_matches=#{d.content == original_content}"
'
```

Expected: the three checks `true`, then `restored: rank=normal content_matches=true`. This is the real-data version of the fourth unit test and the reason `insert_all` was chosen. Both the rank *and* the content must be restored — an earlier draft of this step restored only the rank and would have left `"editorial override"` in the development database.

- [ ] **Step 8: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Add data_migration:description_columns rake task

Standalone -- deliberately not part of data_migration:all, which is the
legacy books Phase-1 chain. This reads the current database.

Dev run verified: 11,382 rows, idempotent, existing rows untouched.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Done when

- `bin/rails test` passes and `bundle exec standardrb` is clean
- `bin/rails data_migration:description_columns` reports `total: 11382`
- `Description.count` is 11,382 in development, split
  `{Music::Artist 5468, Music::Album 3649, Games::Game 1602, Games::Company 658, Games::Series 5}`
- A second run changes nothing and preserves an edited row's rank and content
- No schema change, no page behaviour change — the eleven `description` columns are still authoritative

## Not in this increment

b2 adds `BookDescriptionMigrator` (139,851 rows) and `AuthorDescriptionMigrator` (46,784), both of which need the `legacy_books` connection, plus the books/authors safety net that has to run after them. (c) cuts the write paths over. (d) cuts the read paths over. (e) drops the eleven columns.

**Carry to b2:** the same `upsert_all` clobber applies there. b2 intentionally writes `rank: :preferred` for the 2,139 legacy `use_description` books, so it cannot simply switch to `insert_all` — decide its re-run semantics deliberately when planning it.
