# Descriptions (c1) — Write Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the four importer/AI write sites from clobbering the `description` column, and have each write its own source's `Description` row instead.

**Architecture:** One helper, `Describable#assign_description`, does the lookup-or-build and assigns content without saving. The two music AI tasks save the returned row directly (their parent is always persisted); the two IGDB providers assign only and let `ImporterBase#run_providers_with_saving`'s `item.save!` cascade through a newly-added `autosave: true`. No UI, no schema change, no data migration.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + Mocha + fixtures, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-07-29-descriptions-c-write-paths-admin-design.md` (increment c1 — decisions C1, C2, C2a). Parent spec: `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md` (D5).

---

## Global Constraints

- Run **every** Rails command from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (`--fix` autocorrects). **Never** `bin/rubocop`. **Never** run brakeman.
- **The development database is not disposable.** The books data exists only in dev and takes hours to rebuild. Never run `db:drop`, `db:reset`, `db:schema:load`, `create_fixtures`, or any bulk mutation. **This increment needs no migration and no data run — tests only.**
- **No code comments inside method bodies.** Short method-level comments explaining *why* are fine and match the surrounding code.
- **`assign_description` must never assign `rank`** (D5). Only deliberate selection operations set rank, and none of them live in this increment.
- **Use `detect`, never `find_or_initialize_by`** (C2a). This is the single most important constraint in the plan — see the verified behaviour table below.
- `.presence`/`.blank?`, never truthiness, on content.
- Do not change any public view or admin form in this increment. Increment c3 strips the forms.

### Verified behaviour (probed on PG 17 / Rails 8.1, 2026-07-30 — do not re-derive)

| Case | Result |
|---|---|
| `find_or_initialize_by` + `parent.save!`, persisted parent, existing row | **Silently does not update.** `find_by` issues a query and returns an instance that is **not in the association's target**; `autosave` only iterates the target. |
| ...same, with the association pre-loaded first | **Still does not update** — `find_by` issues a fresh query regardless. |
| `detect` over the association + `parent.save!` | **Updates correctly** — `detect` returns the target instance. |
| `detect` + `parent.save!` **without** `autosave: true` | **Does not update.** So `autosave: true` is genuinely required. |
| `build` on a **new** parent, no `autosave` | Saves fine — new children always do. `autosave` matters only for the changed-existing case. |
| `autosave: true` with an invalid **changed** child | Blocks the parent save with `ActiveRecord::RecordInvalid`. |

### Fixture facts (checked — do not guess)

- `test/fixtures/descriptions.yml` already attaches **`dark_side_ai`** to `music_albums(:dark_side_of_the_moon)` at `source: ai_generated, rank: preferred`, and **`botw_igdb`** to `games_games(:breath_of_the_wild)` at `source: igdb, rank: preferred`.
- `music_albums(:animals)`, `music_artists(:roger_waters)`, `games_games(:tears_of_the_kingdom)` and `games_companies(:capcom)` have **no** description rows — use these when a test needs a clean parent.
- `Services::Ai::Tasks::Music::AlbumDescriptionTaskTest#setup` uses `music_albums(:dark_side_of_the_moon)`; the artist test uses `music_artists(:pink_floyd)` — confirm before editing.
- `DataImporters::Games::Game::Providers::IgdbTest#setup` uses `@game = ::Games::Game.new` — an **unsaved** record.

---

## File Structure

| File | Responsibility |
|---|---|
| Modify `web-app/app/models/concerns/describable.rb` | `autosave: true` + `assign_description` |
| Modify `web-app/test/models/concerns/describable_test.rb` | Pin the helper and the autosave semantics |
| Modify `web-app/app/lib/services/ai/tasks/music/album_description_task.rb` | Write the `:ai_generated` row |
| Modify `web-app/app/lib/services/ai/tasks/music/artist_description_task.rb` | Same |
| Modify `web-app/test/lib/services/ai/tasks/album_description_task_test.rb` | Assert the row, plus the clobber regression |
| Modify `web-app/test/lib/services/ai/tasks/artist_description_task_test.rb` | Same |
| Modify `web-app/app/lib/data_importers/games/game/providers/igdb.rb` | Write the `:igdb` row |
| Modify `web-app/app/lib/data_importers/games/company/providers/igdb.rb` | Same |
| Modify `web-app/test/lib/data_importers/games/game/providers/igdb_test.rb` | Assert the row + the re-import persistence test |
| Modify `web-app/test/lib/data_importers/games/company/providers/igdb_test.rb` | Same |

---

### Task 1: `Describable#assign_description` + `autosave: true`

**Files:**
- Modify: `web-app/app/models/concerns/describable.rb`
- Test: `web-app/test/models/concerns/describable_test.rb` (exists; append to `DescribableTest`)

**Interfaces:**
- Consumes: the `Description` model (`kind`, `locale`, `source`, `content`, `rank`, `retrieved_at`, `source_url`, `license`) and its natural-key unique index.
- Produces: `Describable#assign_description(source:, content:, **attrs) → Description | nil`. Returns `nil` when `content` is blank. Returns an **unsaved-or-dirty** `Description` that is already in the parent's `descriptions` association target, with `content` and `retrieved_at` assigned plus any `**attrs` (e.g. `source_url:`, `license:`). It **never** assigns `rank`. Tasks 2 and 3 both call it.

- [ ] **Step 1: Write the failing tests**

Append inside `DescribableTest` in `web-app/test/models/concerns/describable_test.rb`:

```ruby
  test "assign_description returns nil for blank content" do
    album = music_albums(:animals)
    [nil, "", "   ", "\t\n"].each do |blank|
      assert_nil album.assign_description(source: :ai_generated, content: blank),
        "expected #{blank.inspect} to be rejected"
    end
    assert_empty album.descriptions
  end

  test "assign_description builds a summary/en row at the given source" do
    album = music_albums(:animals)

    row = album.assign_description(source: :ai_generated, content: "A concept album about pigs.")

    assert_equal "summary", row.kind
    assert_equal "en", row.locale
    assert_equal "ai_generated", row.source
    assert_equal "A concept album about pigs.", row.content
    assert_equal "normal", row.rank
    assert_not_nil row.retrieved_at
    assert row.new_record?
  end

  test "assign_description accepts extra attributes" do
    album = music_albums(:animals)

    row = album.assign_description(
      source: :wikipedia,
      content: "From Wikipedia.",
      source_url: "https://en.wikipedia.org/wiki/Animals",
      license: :cc_by_sa_4
    )

    assert_equal "https://en.wikipedia.org/wiki/Animals", row.source_url
    assert_equal "cc_by_sa_4", row.license
  end

  # dark_side_ai is an existing ai_generated row on this album, at rank: preferred.
  test "assign_description updates the existing row for that source instead of building a second" do
    album = music_albums(:dark_side_of_the_moon)
    existing = descriptions(:dark_side_ai)

    assert_no_difference "Description.count" do
      row = album.assign_description(source: :ai_generated, content: "Rewritten by the AI task.")
      assert_equal existing.id, row.id
      album.save!
    end

    assert_equal "Rewritten by the AI task.", existing.reload.content
  end

  # D5: importers may never write rank.
  test "assign_description never changes rank" do
    album = music_albums(:dark_side_of_the_moon)

    album.assign_description(source: :ai_generated, content: "New text.")
    album.save!

    assert_equal "preferred", descriptions(:dark_side_ai).reload.rank
  end

  test "assign_description leaves a different source's row alone" do
    album = music_albums(:dark_side_of_the_moon)

    album.assign_description(source: :wikipedia, content: "A wikipedia row.")
    album.save!

    assert_equal 2, album.descriptions.reload.size
    assert_equal "preferred", descriptions(:dark_side_ai).reload.rank
  end

  test "assign_description works on an unsaved parent and persists with it" do
    book = Books::Book.new(title: "Assign Description On New Parent")

    book.assign_description(source: :manual, content: "Written before the parent existed.")
    book.save!

    row = book.descriptions.reload.sole
    assert_equal "manual", row.source
    assert_equal "Written before the parent existed.", row.content
  end

  test "assign_description called twice on an unsaved parent updates one row, not two" do
    book = Books::Book.new(title: "Assign Description Twice")

    book.assign_description(source: :manual, content: "first")
    book.assign_description(source: :manual, content: "second")
    book.save!

    assert_equal ["second"], book.descriptions.reload.pluck(:content)
  end

  # The autosave contract: without autosave: true this is a silent no-op.
  test "saving the parent persists a changed existing description" do
    album = music_albums(:animals)
    album.descriptions.create!(kind: :summary, locale: "en", source: :ai_generated, content: "old")
    album.reload

    album.assign_description(source: :ai_generated, content: "new")
    album.save!

    assert_equal "new", album.descriptions.reload.sole.content
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/concerns/describable_test.rb`

Expected: FAIL — `NoMethodError: undefined method 'assign_description'`.

- [ ] **Step 3: Write the implementation**

In `web-app/app/models/concerns/describable.rb`, add `autosave: true` to the association and the helper:

```ruby
module Describable
  extend ActiveSupport::Concern

  included do
    has_many :descriptions, -> { order(:id) }, as: :describable, dependent: :destroy, autosave: true
  end

  def primary_description(kind: :summary, locale: "en")
    Descriptions::Resolver.call(descriptions, kind: kind, locale: locale)
  end

  # Assigns without saving, so an importer can call this on a record that is not
  # persisted yet and let the parent's save cascade. Looks the row up with detect
  # rather than find_or_initialize_by: the latter queries and returns an instance
  # that is not in the association target, which autosave never sees, so the write
  # is silently lost. Never assigns rank (D5).
  def assign_description(source:, content:, **attrs)
    return nil if content.blank?

    row = descriptions.detect { |d| d.kind == "summary" && d.locale == "en" && d.source == source.to_s } ||
      descriptions.build(kind: :summary, locale: "en", source: source)
    row.assign_attributes(content: content, retrieved_at: Time.current, **attrs)
    row
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/concerns/describable_test.rb`

Expected: PASS, all tests green (the 8 pre-existing plus 9 new).

- [ ] **Step 5: Run the broader model suite for autosave regressions**

`autosave: true` is an app-wide association change across 11 models, so check more than the one file.

Run: `bin/rails test test/models/ test/lib/services/description_column_backfill_test.rb`

Expected: PASS, no failures. If anything fails, it is a real interaction with the new autosave — report it rather than working around it.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/models/concerns/describable.rb test/models/concerns/describable_test.rb
git add web-app/app/models/concerns/describable.rb web-app/test/models/concerns/describable_test.rb
git commit -m "Add Describable#assign_description with autosave

detect, not find_or_initialize_by: the latter returns an instance outside the
association target, which autosave never sees, so the write is silently lost.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Music AI description tasks

Both tasks currently call `parent.update!(description:)`, which overwrites whatever is there — so an AI regeneration destroys hand-written text. Writing to the `:ai_generated` row instead leaves a `:manual` row untouched, and `:manual` precedes `:ai_generated` in `Descriptions::SourcePriority::ORDER`, so the human's text keeps winning.

**Files:**
- Modify: `web-app/app/lib/services/ai/tasks/music/album_description_task.rb`
- Modify: `web-app/app/lib/services/ai/tasks/music/artist_description_task.rb`
- Test: `web-app/test/lib/services/ai/tasks/album_description_task_test.rb`
- Test: `web-app/test/lib/services/ai/tasks/artist_description_task_test.rb`

**Interfaces:**
- Consumes: `Describable#assign_description(source:, content:) → Description | nil` (Task 1).
- Produces: no new public interface. `process_and_persist` keeps returning `Services::Ai::Result.new(success: true, data: data, ai_chat: chat)`.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/services/ai/tasks/album_description_task_test.rb`, replace the body of the existing `"process_and_persist updates album description when provided"` test's assertions so it asserts the row rather than the column, and add two tests. The existing test's `provider_response` construction stays as-is; only the assertion changes:

```ruby
            # was: assert_equal "...", @album.description
            row = @album.descriptions.reload.find_by(source: :ai_generated)
            assert_equal "The Dark Side of the Moon is Pink Floyd's groundbreaking concept album exploring themes of conflict and mental illness.", row.content
            assert_equal "summary", row.kind
            assert_equal "en", row.locale
```

Then add:

```ruby
          test "process_and_persist does not write the description column" do
            provider_response = {
              parsed: {
                description: "A new AI description.",
                abstained: false,
                abstain_reason: nil
              }
            }
            original_column = @album.description

            @task.send(:process_and_persist, provider_response)

            assert_equal original_column, @album.reload.description
          end

          # Regression: the old parent.update!(description:) clobbered whatever was there.
          test "process_and_persist leaves a preferred manual description untouched" do
            album = music_albums(:animals)
            manual = album.descriptions.create!(
              kind: :summary, locale: "en", source: :manual,
              content: "Hand-written by an editor.", rank: :preferred
            )
            task = AlbumDescriptionTask.new(parent: album)
            provider_response = {
              parsed: {
                description: "AI text that must not win.",
                abstained: false,
                abstain_reason: nil
              }
            }

            task.send(:process_and_persist, provider_response)

            manual.reload
            assert_equal "Hand-written by an editor.", manual.content
            assert_equal "preferred", manual.rank
            assert_equal "AI text that must not win.",
              album.descriptions.reload.find_by(source: :ai_generated).content
            assert_equal manual, album.primary_description
          end
```

Apply the same three changes to `artist_description_task_test.rb`, substituting the artist fixtures — `@artist` for `@album`, `music_artists(:roger_waters)` for the clean parent, and `ArtistDescriptionTask`. Confirm the existing setup's fixture name before editing.

The two existing "does not update when nil / blank" tests keep working unchanged, since a blank description still writes nothing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/album_description_task_test.rb test/lib/services/ai/tasks/artist_description_task_test.rb`

Expected: FAIL — the new row does not exist, because the task still writes the column.

- [ ] **Step 3: Write the implementation**

In `album_description_task.rb`, replace the persist branch:

```ruby
          def process_and_persist(provider_response)
            data = provider_response[:parsed]

            if data[:description].present? && !data[:abstained]
              parent.assign_description(source: :ai_generated, content: data[:description])&.save!
            end

            Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
          end
```

The row is saved directly rather than via `parent.save!` because the parent is always persisted here, and saving the album would fire its search-indexing callbacks for a change that does not affect the index.

Make the identical change in `artist_description_task.rb`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/album_description_task_test.rb test/lib/services/ai/tasks/artist_description_task_test.rb`

Expected: PASS.

- [ ] **Step 5: Run the AI provider tests that wrap these tasks**

Run: `bin/rails test test/lib/data_importers/music/album/providers/ai_description_test.rb test/lib/data_importers/music/artist/providers/ai_description_test.rb`

Expected: PASS. These drive the tasks through the importer; if they assert on `.description`, update them the same way.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/services/ai/tasks/music/ test/lib/services/ai/tasks/
git add web-app/app/lib/services/ai/tasks/music/ web-app/test/lib/services/ai/tasks/ web-app/test/lib/data_importers/music/
git commit -m "Write music AI descriptions to their own Description row

Ends the clobber: regenerating an AI description no longer overwrites a
hand-written manual row, which still outranks it in SourcePriority::ORDER.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: IGDB providers

These assign attributes to a record that **may not be persisted yet** — `ImporterBase#run_providers_with_saving` calls `provider.populate(item, query:)` and then `item.save!`. So the provider must only assign, exactly as `create_identifier` already does, and let the parent's save cascade through `autosave: true`.

**Files:**
- Modify: `web-app/app/lib/data_importers/games/game/providers/igdb.rb`
- Modify: `web-app/app/lib/data_importers/games/company/providers/igdb.rb`
- Test: `web-app/test/lib/data_importers/games/game/providers/igdb_test.rb`
- Test: `web-app/test/lib/data_importers/games/company/providers/igdb_test.rb`

**Interfaces:**
- Consumes: `Describable#assign_description(source:, content:) → Description | nil` (Task 1) and the `autosave: true` association from the same task.
- Produces: no new public interface. `populate` keeps returning a `ProviderResult`.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/data_importers/games/game/providers/igdb_test.rb`, change the assertion in `"populate sets game attributes from IGDB data"`:

```ruby
            # was: assert_equal "An open-world adventure game", @game.description
            row = @game.descriptions.detect { |d| d.source == "igdb" }
            assert_not_nil row, "expected an igdb description to be built"
            assert_equal "An open-world adventure game", row.content
            assert_equal "summary", row.kind
            assert_equal "normal", row.rank
            assert_nil @game.description
```

Then add two tests to the same file:

```ruby
          # The C1/C2a contract: a re-import must persist a CHANGED summary.
          # This fails silently if autosave: true is removed, or if assign_description
          # is refactored back to find_or_initialize_by.
          test "re-import persists a changed summary on an already-saved game" do
            game = games_games(:tears_of_the_kingdom)
            game.descriptions.create!(
              kind: :summary, locale: "en", source: :igdb, content: "Stale summary."
            )
            game.reload

            search_service = mock
            search_service.expects(:find_with_details).with(119388).returns(
              success: true,
              data: [{"name" => "Tears of the Kingdom", "summary" => "Fresh summary from IGDB."}]
            )
            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            result = @provider.populate(game, query: ImportQuery.new(igdb_id: 119388))
            assert result.success?
            game.save!

            assert_equal "Fresh summary from IGDB.",
              game.descriptions.reload.find_by(source: :igdb).content
          end

          test "populate leaves the game saveable with a description attached" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [{"name" => "Breath of the Wild 2", "summary" => "A summary."}]
            )
            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            @provider.populate(@game, query: ImportQuery.new(igdb_id: 7346))

            assert @game.valid?, @game.errors.full_messages.join(", ")
            assert_difference "Description.count", 1 do
              @game.save!
            end
          end
```

Apply the equivalent changes to `company/providers/igdb_test.rb`, substituting `games_companies(:capcom)` as the already-saved parent and the company provider's own IGDB id and payload shape. Read that file's existing stubs before editing — the company payload key is `"description"`, not `"summary"`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/games/game/providers/igdb_test.rb test/lib/data_importers/games/company/providers/igdb_test.rb`

Expected: FAIL — no description row is built, because the providers still write the column.

- [ ] **Step 3: Write the implementation**

In `game/providers/igdb.rb`, inside `populate_game_data`:

```ruby
          def populate_game_data(game, game_data)
            game.title = game_data["name"] if game_data["name"].present?
            game.assign_description(source: :igdb, content: game_data["summary"]) if game_data["summary"].present?
```

In `company/providers/igdb.rb`, inside `populate_company_data`:

```ruby
          def populate_company_data(company, company_data)
            company.name = company_data["name"] if company_data["name"].present?
            company.assign_description(source: :igdb, content: company_data["description"]) if company_data["description"].present?
```

Leave the rest of both methods untouched. The `.present?` guard is redundant with the helper's own blank check but is kept for symmetry with the surrounding lines.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/games/game/providers/igdb_test.rb test/lib/data_importers/games/company/providers/igdb_test.rb`

Expected: PASS.

- [ ] **Step 5: Run the full games importer suite**

Run: `bin/rails test test/lib/data_importers/games/`

Expected: PASS. These exercise the full `ImporterBase` save path, which is where an autosave interaction would surface.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/data_importers/games/ test/lib/data_importers/games/
git add web-app/app/lib/data_importers/games/ web-app/test/lib/data_importers/games/
git commit -m "Write IGDB summaries to their own Description row

Providers assign only; ImporterBase's item.save! cascades via autosave, which
is what makes a re-import persist a changed summary.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full-suite gate

`autosave: true` touches 11 models, so the increment is not done until the whole suite is green.

**Files:** none — verification only.

**Interfaces:** none.

- [ ] **Step 1: Run the full suite and lint**

```bash
cd web-app && bundle exec standardrb && bin/rails test
```

Expected: `standardrb` clean; suite green (4,944 runs as of increment b2, plus this increment's new tests, 0 failures, 0 errors).

- [ ] **Step 2: Confirm no `description` column writes remain in the four sites**

```bash
cd web-app && grep -rn 'description' \
  app/lib/services/ai/tasks/music/album_description_task.rb \
  app/lib/services/ai/tasks/music/artist_description_task.rb \
  app/lib/data_importers/games/game/providers/igdb.rb \
  app/lib/data_importers/games/company/providers/igdb.rb | grep -E '\.description\s*=|update!\(description'
```

Expected: **no output.** Any hit is a site that still writes the column.

- [ ] **Step 3: Report**

No commit. Report the suite counts and the grep result. If the suite is not green, report the failures precisely and do not claim completion.

---

## Self-Review

**1. Spec coverage.** C1 (`autosave: true`) → Task 1. C2 (one helper, callers persist) → Task 1 + the persistence split across Tasks 2 and 3. C2a (`detect`, not `find_or_initialize_by`) → Task 1 Step 3, pinned by Task 1's "persists a changed existing description" and Task 3's re-import test. The spec's write-path table's four rows → Tasks 2 and 3. The clobber regression → Task 2. "An import still succeeds end-to-end" → Task 3's "leaves the game saveable" plus Task 3 Step 5. Out of scope here and deferred to c2/c3 as the spec says: the admin panel, the `Games::Series` registry entry, form stripping, E2E.

**2. Placeholder scan.** Every code step carries real code. Three steps deliberately say "read the file first and substitute" rather than inventing content — the artist task test's fixture name, the company IGDB payload shape, and the music AI-provider tests' assertions — because those files were not read in full while planning and guessing their contents would be worse than instructing the implementer to look. Each names exactly what to check.

**3. Type consistency.** `assign_description(source:, content:, **attrs)` returns `Description | nil` in Task 1 and is called with exactly that signature in Tasks 2 and 3. Task 2 uses `&.save!` on the return value (parent persisted); Task 3 discards the return value and relies on the parent's cascade (parent may be new) — the two persistence styles are deliberate and match the spec's table. `d.source == source.to_s` in the helper because the enum reader returns a `String` while every caller passes a `Symbol`.
