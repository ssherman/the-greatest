# Books List Wizard and Shared Wizard Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a books list wizard (Paste → Parse → Match → Review → Import → Done) built on a new domain-agnostic wizard core, where only suspect rows reach a human, and fix two data-loss flaws in the old music/games wizards.

**Architecture:** A core under `app/lib/services/lists/wizard/core/` owns row state (`list_items.metadata["wizard"]`), the outcome rules, the parse / match / import services and the review data; three generic Sidekiq jobs under `app/sidekiq/lists/wizard/` call them. Books plugs in through one adapter (`Services::Lists::Wizard::Books::Adapter`) that supplies the parser, the finder query, the finder, the importer, search and display. A controller concern (`ListWizardCore`) and shared ViewComponents (`Wizard::Core::*`) give the screens, mounted for books in the `admin_books` namespace.

**Tech Stack:** Rails 8, Sidekiq 9 (inline in tests), Minitest 6 + fixtures + Mocha 3, WebMock, ViewComponent, Turbo Drive, Stimulus (`wizard_step_controller.js`, `autocomplete_controller.js`), daisyUI 5 on Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-06-books-list-wizard-design.md` (binding). Read it with this plan.

## Global Constraints

- **No migration.** Row state lives in `list_items.metadata` under a `wizard` key.
- Steps, in order: `paste parse match review import done` (spec: "Paste → Parse → Match → Review → Import → Done").
- Input is pasted HTML or text only. No URL fetching.
- New books are normal books: `provisional: false`, `enrich: true`.
- Match: one Sidekiq job per row, on the `default` queue.
- Import: one Sidekiq job per list; creates rows one at a time; never fans out a job per row or per author.
- Permissions come from `Admin::DomainScopedAuth`: write access for every action, delete access for restart.
- AI calls (parser, finder) run on the `fast` role (already true of both tasks; do not change roles).
- Music and games get only the two fixes in spec §9. No other change to the old wizards.
- No name-uniqueness rule on books or authors.
- `verified` is true exactly when a row is linked to a book (matched, created or linked by Import, linked by an admin); every unlinked row, settled or not (create pending, removed, flagged), has `verified: false` (controller ruling; the spec is amended).
- Only one wizard job runs per list at a time: Parse, Match and Import never overlap, and restart waits for them (controller ruling).
- Services live under `app/lib/services/<…>/` with `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`; jobs under `app/sidekiq/`; new jobs via `bin/rails generate sidekiq:job …`, components via `bin/rails generate component …`, controllers via `bin/rails generate controller …`.
- Inside `Services::Lists::…` always root-anchor model and job constants (`::Books::Book`, `::ListItem`, `::MatchDecision`, `::Lists::Wizard::MatchRowJob`): `Books` and `Lists` resolve to the wrong module there otherwise.
- daisyUI 5 classes only (no `form-control`, `label-text`, `input-bordered`, `tabs-boxed`, …). No Turbo Frames on the books wizard screens (every action is a full Turbo Drive visit), so no frame can trap a link.
- Run every Rails/yarn command from `web-app/`. Lint is `bundle exec standardrb`. Minitest 6: `assert_nil`, never `assert_equal nil`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never commit to `main`.

## Review Focus

1. **Two parallel Match jobs land on the same book at once.** Expected: one row links, the other is flagged `on_list_twice`, no crashed job and no stuck step. Test: Task 8, "a uniqueness clash at save time flags the row instead of crashing".
2. **A list that already has rows from before the wizard** (migrated, or added on the list page; no `wizard` metadata). Expected: parse, match and restart never change or delete them, and a parsed duplicate of one is not added. Tests: Task 7 "a row from before the wizard is kept and not parsed again", Task 8 "rows from before the wizard are never queued", Task 13 "restart keeps rows from before the wizard".
3. **A re-parse whose AI call fails.** Expected: the unsettled rows from the last parse survive; nothing is deleted until a parse succeeds. Test: Task 7, "a failed re-parse deletes nothing".
4. **Import run a second time** (admin goes back from Done, fixes a failed row, imports again). Expected: rows created the first time are not created again. Test: Task 9, "a second import run creates nothing for rows it already created".
5. **Odd input in the edit form** (blank title, a non-numeric or padded year, blank author lines). Expected: blank title refused; year stored as Integer or nil; authors a clean array. Test: Task 10, "edit cleans the year and the author lines, and refuses a blank title".

---

## File map

Create:
- `web-app/app/lib/services/lists/wizard/core/signature.rb` — text normalization for row comparison.
- `web-app/app/lib/services/lists/wizard/core/row_state.rb` — read/write `metadata["wizard"]`, reason labels, holder lookup.
- `web-app/app/lib/services/lists/wizard/core/outcome.rb` — spec §3 bucket and reason rules.
- `web-app/app/lib/services/lists/wizard/core/on_list_twice.rb` — the once-per-match pass.
- `web-app/app/lib/services/lists/wizard/core/adapters.rb` — list type → adapter.
- `web-app/app/lib/services/lists/wizard/core/parse_rows.rb`, `start_match.rb`, `match_row.rb`, `match_progress.rb`, `import_rows.rb`, `row_actions.rb`, `summary.rb`, `review_rows.rb`.
- `web-app/app/lib/services/lists/wizard/books/state_manager.rb`, `adapter.rb`.
- `web-app/app/sidekiq/lists/wizard/parse_job.rb`, `match_job.rb`, `match_row_job.rb`, `import_job.rb`.
- `web-app/app/controllers/concerns/list_wizard_core.rb`, `web-app/app/controllers/admin/books/list_wizard_controller.rb`.
- `web-app/app/views/admin/list_wizard_core/show_step.html.erb`.
- `web-app/app/components/wizard/core/{paste_step,job_step,review_step,review_row,done_step}_component.{rb,html.erb}`.
- `web-app/test/support/list_wizard_helper.rb` and the tests named in each task.
- `web-app/e2e/tests/books/admin/list-wizard.spec.ts`.

Modify:
- `web-app/app/lib/data_importers/books/book/{import_query,open_library_source,importer}.rb`, `providers/open_library.rb`.
- `web-app/app/lib/services/ai/tasks/lists/books/raw_parser_task.rb`.
- `web-app/app/controllers/concerns/wizard_controller.rb` (restart).
- `web-app/app/sidekiq/base_wizard_validate_list_items_job.rb`, the three `*list_items_validator_task.rb`, `web-app/app/models/list_item.rb`.
- `web-app/app/lib/services/lists/wizard/state_manager.rb`.
- `web-app/app/components/wizard/navigation_component.{rb,html.erb}`, `web-app/app/components/autocomplete_component.{rb,html.erb}`.
- `web-app/app/components/admin/lists/show_component.{rb,html.erb}`.
- `web-app/app/controllers/admin/books/lists_controller.rb`, `web-app/config/routes.rb`, `web-app/test/test_helper.rb`.
- `docs/features/list-wizard.md`.

## Row state keys (used by every task from 4 on)

`list_items.metadata["wizard"]` is a Hash:

| Key | Type | Meaning |
|---|---|---|
| `bucket` | `"pending" \| "matched" \| "create" \| "flagged" \| "removed"` | `pending` = parsed or queued for Match, no decision yet |
| `reasons` | Array of `"unsure" "not_found" "ai_only_pick" "on_list_twice" "match_failed" "import_failed" "changed_since_match"` | why a row is flagged (or, for `changed_since_match`, a note for Done) |
| `settled`, `settled_by_id`, `settled_at` | Boolean, Integer/nil, ISO8601 | admin decisions and Import results |
| `match_decision_id` | Integer | the row's current `MatchDecision` |
| `decided_by`, `confidence` | String | copied from the match, for the AI-decided filter |
| `ol_keys` | Array of String | Open Library keys saved at Match for the Import re-check |
| `ol_work_key` | String/nil | the work a `create` row is created from (nil = from the row's text) |
| `target_record_id` | Integer/nil | the local book the row landed on (set for `matched`, kept when uniqueness blocked the link) |
| `matched_at` | ISO8601 | when Match decided the row |
| `import_result` | `"created" \| "linked_existing"` | what Import did |
| `import_error`, `error` | String | Import failure / Match failure text |

A row **without** a `wizard` key predates the wizard and counts as settled.

---

### Task 1: Subtitle through the parser, `ImportQuery`, `/resolve` and the importer

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/import_query.rb`
- Modify: `web-app/app/lib/data_importers/books/book/open_library_source.rb` (`resolve_args`)
- Modify: `web-app/app/lib/data_importers/books/book/importer.rb` (`self.call`, `initialize_item`)
- Modify: `web-app/app/lib/services/ai/tasks/lists/books/raw_parser_task.rb`
- Test: `web-app/test/lib/data_importers/books/book/import_query_test.rb`, `open_library_source_test.rb`, `importer_test.rb`
- Create test: `web-app/test/lib/services/ai/tasks/lists/books/raw_parser_task_test.rb`

**Interfaces:**
- Consumes: `Books::OpenLibrary::Client#resolve(subtitle:)` (already accepted; blank is dropped).
- Produces: `DataImporters::Books::Book::ImportQuery.new(title:, subtitle: nil, author_names: [], year: nil, …)` with `#subtitle` (blank → nil) and `"subtitle"` in snapshots; `DataImporters::Books::Book::Importer.call(…, subtitle: nil, …)` seeds `Books::Book#subtitle`; `RawParserTask` returns `{books: [{rank:, title:, subtitle:, authors:, publication_year:}]}`.

- [ ] **Step 1: Write the failing tests**

Add to `import_query_test.rb` (inside the class):

```ruby
        test "subtitle is kept, a blank one reads as nil, and it survives a snapshot round trip" do
          query = ImportQuery.new(title: "Sapiens", subtitle: "A Brief History of Humankind")
          snapshot = query.instance_variables.to_h { |ivar| [ivar.to_s.delete("@"), query.instance_variable_get(ivar)] }

          assert_equal "A Brief History of Humankind", ImportQuery.from_snapshot(snapshot).subtitle
          assert_nil ImportQuery.new(title: "Sapiens", subtitle: "  ").subtitle
        end
```

Add to `open_library_source_test.rb`:

```ruby
        test "sends the query's subtitle to /resolve" do
          stub_resolve(resolve_response(verdict: "abstain")) do |request|
            JSON.parse(request.body)["subtitle"] == "A Novel"
          end

          source(query(subtitle: "A Novel")).call

          assert_requested(:post, "#{BASE_URL}/resolve", times: 1)
        end
```

Add to `importer_test.rb`:

```ruby
        test "a new book is seeded with the query's subtitle, and the finder sends it to /resolve" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve")
            .with { |request| JSON.parse(request.body)["subtitle"] == "A Brief History of Humankind" }
            .to_return(status: 200, body: accept_response(diff: []).to_json)

          result = Importer.call(title: "Sapiens", subtitle: "A Brief History of Humankind", author_names: ["Yuval Noah Harari"])

          assert result.item.persisted?
          assert_equal "A Brief History of Humankind", result.item.subtitle
        end
```

Create `web-app/test/lib/services/ai/tasks/lists/books/raw_parser_task_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Books
          class RawParserTaskTest < ActiveSupport::TestCase
            test "the response schema requires a subtitle on every book" do
              schema = RawParserTask::Book.to_json_schema

              assert_includes schema[:properties].keys.map(&:to_s), "subtitle"
              assert_includes Array(schema[:required]).map(&:to_s), "subtitle"
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/import_query_test.rb test/lib/data_importers/books/book/open_library_source_test.rb test/lib/data_importers/books/book/importer_test.rb test/lib/services/ai/tasks/lists/books/raw_parser_task_test.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :subtitle` in the three importer tests; the schema test fails on the missing `"subtitle"` property.

- [ ] **Step 3: Implement**

In `import_query.rb`:

```ruby
        attr_reader :title, :subtitle, :author_names, :year, :isbn13, :isbn10, :asin, :goodreads_id, :open_library_work_key,
          :series_name, :series_number, :context_author_names

        SNAPSHOT_KEYS = %i[title subtitle author_names year isbn13 isbn10 asin goodreads_id open_library_work_key
          series_name series_number context_author_names].freeze
```

and change the initializer's signature and first lines to:

```ruby
        def initialize(title:, subtitle: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, series_name: nil, series_number: nil, context_author_names: [])
          @title = title
          # The list wizard's parser splits it out of the title (books list
          # wizard spec §2). Only /resolve reads it; Exact and OpenSearch keep
          # matching on the title.
          @subtitle = subtitle.presence
          @author_names = Array(author_names)
```

(the rest of the initializer is unchanged).

In `open_library_source.rb`, `resolve_args` gains one line after `title:`:

```ruby
            title: @query.title.to_s,
            subtitle: @query.subtitle,
```

In `importer.rb`, add `subtitle: nil` to `self.call`'s keywords (after `title: nil`) and pass it to the query:

```ruby
        def self.call(title: nil, subtitle: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false,
          match: nil, provisional: false, stamp_identifiers: false, enrich: true)
          importer = new(provisional: provisional, stamp_identifiers: stamp_identifiers, enrich: enrich)
          if item.present?
            importer.call(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              title: title,
              subtitle: subtitle,
              author_names: author_names,
```

and seed it in `initialize_item`:

```ruby
        def initialize_item(query)
          ::Books::Book.new(
            title: query.title,
            subtitle: query.subtitle,
            first_published_year: query.year,
            provisional: @provisional
          )
        end
```

In `raw_parser_task.rb`:

```ruby
            def extraction_fields
              [
                "Rank (if present, can be null)",
                "Book title, without its subtitle",
                "Subtitle (if present, can be null)",
                "Author name(s)",
                "Publication year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding book information:
                - Books may have multiple authors
                - Publication year may be mentioned in parentheses or as separate text
                - A subtitle usually follows the title after a colon or a dash, or sits on its own line.
                  Put the main title in the title field and the subtitle in the subtitle field.
                  Never invent a subtitle; use null when there is none.
                - Remove publisher information from titles
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. To Kill a Mockingbird - Harper Lee (1960)":
                - Rank: 1
                - Title: "To Kill a Mockingbird"
                - Subtitle: null
                - Authors: ["Harper Lee"]
                - Publication Year: 1960

                For "Sapiens: A Brief History of Humankind by Yuval Noah Harari":
                - Rank: null
                - Title: "Sapiens"
                - Subtitle: "A Brief History of Humankind"
                - Authors: ["Yuval Noah Harari"]
                - Publication Year: null
              EXAMPLES
            end
```

and the schema:

```ruby
            class Book < OpenAI::BaseModel
              required :rank, Integer, nil?: true, doc: "Rank position in the list"
              required :title, String, doc: "Book title, without its subtitle"
              required :subtitle, String, nil?: true, doc: "Subtitle split from the title, or null"
              required :authors, OpenAI::ArrayOf[String], doc: "Author name(s)"
              required :publication_year, Integer, nil?: true, doc: "Year the book was published"
            end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/books/book/ test/lib/services/ai/tasks/lists/books/raw_parser_task_test.rb test/lib/services/books/goodreads_imports/`
Expected: PASS (the Goodreads tests confirm nothing that builds an `ImportQuery` without a subtitle broke).

- [ ] **Step 5: Commit**

```bash
git add app/lib/data_importers/books/book/import_query.rb app/lib/data_importers/books/book/open_library_source.rb app/lib/data_importers/books/book/importer.rb app/lib/services/ai/tasks/lists/books/raw_parser_task.rb test/lib/data_importers/books/book/import_query_test.rb test/lib/data_importers/books/book/open_library_source_test.rb test/lib/data_importers/books/book/importer_test.rb test/lib/services/ai/tasks/lists/books/raw_parser_task_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
Books list wizard: carry a subtitle from the parser to /resolve

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Old wizards — restart keeps verified rows (spec §9.1)

**Files:**
- Modify: `web-app/app/controllers/concerns/wizard_controller.rb` (`restart` and its comment)
- Modify: `web-app/app/components/wizard/navigation_component.html.erb` (restart confirmation text)
- Test: `web-app/test/controllers/admin/games/list_wizard_controller_test.rb`, `web-app/test/controllers/admin/music/songs/list_wizard_controller_test.rb`, `web-app/test/controllers/admin/music/albums/list_wizard_controller_test.rb`

**Interfaces:**
- Consumes: `ListItem.unverified` scope.
- Produces: `WizardController#restart` deletes only `verified: false` rows, then `reset!`.

- [ ] **Step 1: Write the failing tests**

In `test/controllers/admin/games/list_wizard_controller_test.rb`, replace the test `"should restart wizard and delete list items"` with:

```ruby
  test "restart deletes unverified list items and keeps verified ones" do
    @list.update!(wizard_state: {"current_step" => 5, "completed_at" => Time.current.iso8601})
    @list.list_items.destroy_all
    kept = ListItem.create!(list: @list, listable_type: "Games::Game", position: 1, verified: true, metadata: {"title" => "Kept Game"})
    ListItem.create!(list: @list, listable_type: "Games::Game", position: 2, verified: false, metadata: {"title" => "Dropped Game"})

    post restart_admin_games_list_wizard_path(list_id: @list.id)

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_nil @list.wizard_state["completed_at"]
    assert_equal [kept.id], @list.list_items.pluck(:id)
    assert_redirected_to admin_games_list_wizard_path(list_id: @list.id)
  end
```

In `test/controllers/admin/music/songs/list_wizard_controller_test.rb`, replace `"should restart wizard and delete list items"` with:

```ruby
  test "restart deletes unverified list items and keeps verified ones" do
    @list.update!(wizard_state: {"current_step" => 5, "completed_at" => Time.current.iso8601})
    @list.list_items.destroy_all
    kept = ListItem.create!(list: @list, listable_type: "Music::Song", position: 1, verified: true, metadata: {"title" => "Kept Song"})
    ListItem.create!(list: @list, listable_type: "Music::Song", position: 2, verified: false, metadata: {"title" => "Dropped Song"})

    post restart_admin_songs_list_wizard_path(list_id: @list.id)

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_nil @list.wizard_state["completed_at"]
    assert_equal [kept.id], @list.list_items.pluck(:id)
    assert_redirected_to admin_songs_list_wizard_path(list_id: @list.id)
  end
```

In `test/controllers/admin/music/albums/list_wizard_controller_test.rb`, replace `"should restart wizard and delete list items"` with:

```ruby
  test "restart deletes unverified list items and keeps verified ones" do
    @list.update!(wizard_state: {"current_step" => 5, "completed_at" => Time.current.iso8601})
    @list.list_items.destroy_all
    kept = ListItem.create!(list: @list, listable_type: "Music::Album", position: 1, verified: true, metadata: {"title" => "Kept Album"})
    ListItem.create!(list: @list, listable_type: "Music::Album", position: 2, verified: false, metadata: {"title" => "Dropped Album"})

    post restart_admin_albums_list_wizard_path(list_id: @list.id)

    @list.reload
    assert_equal 0, @list.wizard_manager.current_step
    assert_nil @list.wizard_state["completed_at"]
    assert_equal [kept.id], @list.list_items.pluck(:id)
    assert_redirected_to admin_albums_list_wizard_path(list_id: @list.id)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/admin/games/list_wizard_controller_test.rb test/controllers/admin/music/songs/list_wizard_controller_test.rb test/controllers/admin/music/albums/list_wizard_controller_test.rb`
Expected: FAIL — `Expected: [<id>] Actual: []` (restart destroys the verified row too).

- [ ] **Step 3: Implement**

In `wizard_controller.rb`, replace `restart` and its comment with:

```ruby
  # Resets the wizard to its initial state and redirects to the first step.
  # Deletes only unverified list items: a verified row is a human's decision
  # (a manual link, an approved match) and restarting must not throw it away
  # (books list wizard spec §9.1).
  def restart
    wizard_entity.list_items.unverified.destroy_all
    wizard_entity.wizard_manager.reset!
    redirect_to action: :show
  end
```

In `navigation_component.html.erb`, change the Restart button's confirmation to:

```erb
        data: { turbo_confirm: "Are you sure you want to restart the wizard? Items you have not verified are deleted; verified items are kept." } %>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/games/ test/controllers/admin/music/ test/components/wizard/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/concerns/wizard_controller.rb app/components/wizard/navigation_component.html.erb test/controllers/admin/games/list_wizard_controller_test.rb test/controllers/admin/music/songs/list_wizard_controller_test.rb test/controllers/admin/music/albums/list_wizard_controller_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
Old list wizards: restart keeps verified rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Old wizards — AI validation leaves hand-made links alone (spec §9.2)

**Files:**
- Modify: `web-app/app/models/list_item.rb`
- Modify: `web-app/app/sidekiq/base_wizard_validate_list_items_job.rb` (`enriched_items`, `clear_previous_validation_flags`)
- Modify: `web-app/app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb`, `.../music/songs/list_items_validator_task.rb`, `.../music/albums/list_items_validator_task.rb` (`enriched_items`)
- Test: `web-app/test/models/list_item_test.rb`, `web-app/test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb` (rewrite the pinning test), `web-app/test/sidekiq/music/albums/wizard_validate_list_items_job_test.rb`, `web-app/test/sidekiq/games/wizard_validate_list_items_job_test.rb`, `web-app/test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb`, `web-app/test/lib/services/ai/tasks/lists/music/albums/list_items_validator_task_test.rb`
- Create test: `web-app/test/lib/services/ai/tasks/lists/games/list_items_validator_task_test.rb`

**Interfaces:**
- Produces: `ListItem::MANUAL_LINK_KEYS = %w[manual_link manual_musicbrainz_link manual_igdb_link]` and `ListItem#manually_linked?` → Boolean.

- [ ] **Step 1: Write the failing tests**

`test/models/list_item_test.rb` (inside the class):

```ruby
  test "manually_linked? is true for each hand-link flag and false without one" do
    ListItem::MANUAL_LINK_KEYS.each do |key|
      assert ListItem.new(metadata: {key => true}).manually_linked?, key
    end
    assert_not ListItem.new(metadata: {"manual_link" => false}).manually_linked?
    assert_not ListItem.new(metadata: {"title" => "Abbey Road"}).manually_linked?
    assert_not ListItem.new(metadata: nil).manually_linked?
  end
```

In `test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb`, replace the test `"job is idempotent - resets verified to false before validation"` with these three:

```ruby
  test "re-validation still resets a verified row that nobody linked by hand" do
    @list_items.first.update!(verified: true, metadata: @list_items.first.metadata.merge("ai_match_invalid" => true))
    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list_items.first.reload
    assert_not @list_items.first.verified?
    refute @list_items.first.metadata.key?("ai_match_invalid")
  end

  test "re-validation leaves a hand-linked row verified and linked" do
    song = music_songs(:wish_you_were_here)
    manual = ListItem.create!(list: @list, listable: song, verified: true, position: 3,
      metadata: {"title" => "Wish You Were Here", "song_id" => song.id, "manual_link" => true})
    @list_items << manual
    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    manual.reload
    assert manual.verified?
    assert_equal song.id, manual.listable_id
  end

  test "batch mode never hands a hand-linked row to the validator" do
    @list.update!(wizard_state: {"current_step" => 3, "batch_mode" => true, "steps" => {"validate" => {"status" => "idle"}}})
    # Unverified on purpose: this pins the enriched_items filter itself, not
    # the flag-clearing skip (a verified row is left out of the unverified
    # scope either way once the clearing stops resetting it).
    manual = ListItem.create!(list: @list, listable_type: "Music::Song", verified: false, position: 3,
      metadata: {"title" => "Something", "song_id" => 77, "manual_musicbrainz_link" => true})
    @list_items << manual
    task = stub(call: Services::Ai::Result.new(success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, reasoning: "ok"}))
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.expects(:new)
      .with(has_entries(items: Not(includes(manual)))).returns(task)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    refute manual.reload.metadata.key?("ai_match_invalid")
  end
```

Add to `test/sidekiq/music/albums/wizard_validate_list_items_job_test.rb`:

```ruby
  test "re-validation leaves a row linked by MusicBrainz release by hand verified" do
    manual = ListItem.create!(list: @list, listable_type: "Music::Album", verified: true, position: 9,
      metadata: {"title" => "Abbey Road", "mb_release_group_id" => "9162580e-5df4-32de-80cc-f45a8d8a9b1d", "manual_musicbrainz_link" => true})
    @list_items << manual
    result = Services::Ai::Result.new(success: true,
      data: {valid_count: 1, invalid_count: 0, verified_count: 1, total_count: 1, reasoning: "ok"})
    Services::Ai::Tasks::Lists::Music::Albums::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardValidateListItemsJob.new.perform(@list.id)

    assert manual.reload.verified?
  end
```

Add to `test/sidekiq/games/wizard_validate_list_items_job_test.rb`:

```ruby
  test "re-validation leaves a row linked to an IGDB game by hand verified" do
    manual = ListItem.create!(list: @list, listable_type: "Games::Game", verified: true, position: 2,
      metadata: {"title" => "Hades", "igdb_id" => 113112, "igdb_name" => "Hades", "manual_igdb_link" => true})
    result = Services::Ai::Result.new(success: true,
      data: {valid_count: 1, invalid_count: 0, verified_count: 1, total_count: 1, reasoning: "ok"})
    Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Games::WizardValidateListItemsJob.new.perform(@list.id)

    assert manual.reload.verified?
  end
```

Add to `test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb` (inside the class, plus the helper in a `private` section at the end of the class):

```ruby
              test "a hand-linked row handed to the validator is left out of the prompt and untouched" do
                manual = @list.list_items.create!(position: 4, verified: true,
                  metadata: {"title" => "Let It Be", "artists" => ["The Beatles"], "song_id" => 456, "manual_link" => true})
                stub_validator_response(invalid: [1])

                result = ListItemsValidatorTask.new(parent: @list, items: [manual, @item1]).call

                assert result.success?
                assert manual.reload.verified?
                refute manual.metadata.key?("ai_match_invalid")
                assert_equal true, @item1.reload.metadata["ai_match_invalid"]
              end

              private

              def stub_validator_response(invalid:)
                data = {invalid: invalid, reasoning: "test"}
                strategy = mock("strategy")
                strategy.stubs(:send_message!).returns({content: data.to_json, parsed: data, id: "chatcmpl-1", model: "gpt-5",
                  usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}})
                strategy.stubs(:provider_key).returns("openai")
                strategy.stubs(:default_model).returns("gpt-5")
                strategy.stubs(:capabilities).returns([:json_mode, :json_schema])
                Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(strategy)
              end
```

Add to `test/lib/services/ai/tasks/lists/music/albums/list_items_validator_task_test.rb` (its setup's first enriched row is `@item1`), the test inside the class and the helper in a `private` section at the end of the class:

```ruby
              test "a hand-linked row handed to the validator is left out of the prompt and untouched" do
                manual = @list.list_items.create!(position: 4, verified: true,
                  metadata: {"title" => "Revolver", "artists" => ["The Beatles"], "album_id" => 456, "manual_link" => true})
                stub_validator_response(invalid: [1])

                result = ListItemsValidatorTask.new(parent: @list, items: [manual, @item1]).call

                assert result.success?
                assert manual.reload.verified?
                refute manual.metadata.key?("ai_match_invalid")
                assert_equal true, @item1.reload.metadata["ai_match_invalid"]
              end

              private

              def stub_validator_response(invalid:)
                data = {invalid: invalid, reasoning: "test"}
                strategy = mock("strategy")
                strategy.stubs(:send_message!).returns({content: data.to_json, parsed: data, id: "chatcmpl-1", model: "gpt-5",
                  usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}})
                strategy.stubs(:provider_key).returns("openai")
                strategy.stubs(:default_model).returns("gpt-5")
                strategy.stubs(:capabilities).returns([:json_mode, :json_schema])
                Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(strategy)
              end
```

Create `test/lib/services/ai/tasks/lists/games/list_items_validator_task_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Games
          class ListItemsValidatorTaskTest < ActiveSupport::TestCase
            setup do
              @list = lists(:games_list)
              @list.list_items.destroy_all
              @plain = @list.list_items.create!(position: 1, verified: false,
                metadata: {"title" => "Zelda", "developers" => ["Nintendo"], "igdb_id" => 1, "igdb_name" => "Zelda II"})
              @manual = @list.list_items.create!(position: 2, verified: true,
                metadata: {"title" => "Hades", "igdb_id" => 113112, "igdb_name" => "Hades", "manual_igdb_link" => true})
            end

            test "a hand-linked row handed to the validator is left out of the prompt and untouched" do
              stub_validator_response(invalid: [1])

              result = ListItemsValidatorTask.new(parent: @list, items: [@manual, @plain]).call

              assert result.success?
              assert @manual.reload.verified?
              refute @manual.metadata.key?("ai_match_invalid")
              assert_equal true, @plain.reload.metadata["ai_match_invalid"]
            end

            test "without provided items a hand-linked row is still skipped" do
              # Unverified, so the task's own unverified scope would pick it up.
              # Were it validated it would be marked valid and verified.
              @manual.update!(verified: false)
              stub_validator_response(invalid: [1])

              ListItemsValidatorTask.new(parent: @list).call

              refute @manual.reload.verified?
              refute @manual.metadata.key?("ai_match_invalid")
              assert_equal true, @plain.reload.metadata["ai_match_invalid"]
            end

            private

            def stub_validator_response(invalid:)
              data = {invalid: invalid, reasoning: "test"}
              strategy = mock("strategy")
              strategy.stubs(:send_message!).returns({content: data.to_json, parsed: data, id: "chatcmpl-1", model: "gpt-5",
                usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}})
              strategy.stubs(:provider_key).returns("openai")
              strategy.stubs(:default_model).returns("gpt-5")
              strategy.stubs(:capabilities).returns([:json_mode, :json_schema])
              Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(strategy)
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/list_item_test.rb test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb test/sidekiq/music/albums/wizard_validate_list_items_job_test.rb test/sidekiq/games/wizard_validate_list_items_job_test.rb test/lib/services/ai/tasks/lists/`
Expected: FAIL — `NameError: uninitialized constant ListItem::MANUAL_LINK_KEYS`, `NoMethodError: manually_linked?`; the job tests fail with `Expected false to be truthy` (the manual row was reset), the batch test with an unexpected invocation of `new`; the task tests fail because the manual row got `ai_match_invalid`.

- [ ] **Step 3: Implement**

`app/models/list_item.rb` — add near the top of the class body (after the error class):

```ruby
  # Metadata flags the old wizards set when a person linked a row by hand.
  # AI re-validation must leave those rows alone (books list wizard spec §9.2).
  MANUAL_LINK_KEYS = %w[manual_link manual_musicbrainz_link manual_igdb_link].freeze

  def manually_linked?
    metadata.is_a?(Hash) && MANUAL_LINK_KEYS.any? { |key| metadata[key].present? }
  end
```

`app/sidekiq/base_wizard_validate_list_items_job.rb`:

```ruby
  def enriched_items
    @list.list_items.unverified.ordered.select do |item|
      has_enrichment?(item) && !item.manually_linked?
    end
  end

  def clear_previous_validation_flags
    @list.list_items.reorder(nil).find_each do |item|
      next if item.manually_linked?

      needs_update = false

      if item.metadata["ai_match_invalid"].present?
        item.metadata.delete("ai_match_invalid")
        needs_update = true
      end

      if item.verified && has_enrichment?(item)
        needs_update = true
      end

      if needs_update
        item.update_columns(metadata: item.metadata, verified: false)
      end
    end
  end
```

`games/list_items_validator_task.rb`:

```ruby
            def enriched_items
              @enriched_items ||= begin
                items = @provided_items || parent.list_items.unverified.ordered.select { |item|
                  item.listable_id.present? || item.metadata["game_id"].present? || item.metadata["igdb_id"].present?
                }
                items.reject(&:manually_linked?)
              end
            end
```

`music/songs/list_items_validator_task.rb`:

```ruby
              def enriched_items
                @enriched_items ||= begin
                  items = @provided_items || parent.list_items.unverified.ordered.select { |item|
                    item.listable_id.present? || item.metadata["song_id"].present? || item.metadata["mb_recording_id"].present?
                  }
                  items.reject(&:manually_linked?)
                end
              end
```

`music/albums/list_items_validator_task.rb`:

```ruby
              def enriched_items
                @enriched_items ||= begin
                  items = @provided_items || parent.list_items.unverified.ordered.select { |item|
                    item.listable_id.present? || item.metadata["album_id"].present? || item.metadata["mb_release_group_id"].present?
                  }
                  items.reject(&:manually_linked?)
                end
              end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/list_item_test.rb test/sidekiq/music/ test/sidekiq/games/ test/lib/services/ai/tasks/lists/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/list_item.rb app/sidekiq/base_wizard_validate_list_items_job.rb app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb test/models/list_item_test.rb test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb test/sidekiq/music/albums/wizard_validate_list_items_job_test.rb test/sidekiq/games/wizard_validate_list_items_job_test.rb test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb test/lib/services/ai/tasks/lists/music/albums/list_items_validator_task_test.rb test/lib/services/ai/tasks/lists/games/list_items_validator_task_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
Old list wizards: AI re-validation skips hand-linked rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Core row state, outcome rules and the `on_list_twice` pass

**Files:**
- Create: `web-app/app/lib/services/lists/wizard/core/signature.rb`, `row_state.rb`, `outcome.rb`, `on_list_twice.rb`
- Create: `web-app/test/support/list_wizard_helper.rb`; modify `web-app/test/test_helper.rb` (require it)
- Test: `web-app/test/lib/services/lists/wizard/core/signature_test.rb`, `row_state_test.rb`, `outcome_test.rb`, `on_list_twice_test.rb`

**Interfaces:**
- Consumes: `DataImporters::Match` (`matched?`, `unmatched?`, `confidence`, `decided_by`, `needs_review?`, `candidates`, `external`, `record`), `DataImporters::Candidate#external?`, `#external_accepted?`, `#external_key`.
- Produces:
  - `Services::Lists::Wizard::Core::Signature.normalize(text) → String|nil`; `.call(title, creators) → [String, Array<String>]`.
  - `Services::Lists::Wizard::Core::RowState` — constants `KEY`, `INITIAL`, `PENDING`, `REASON_LABELS`; class methods `.unsettled(list) → Array<ListItem>`, `.holder_of(list, record, except: nil) → ListItem|nil`, `.label_for(reason) → String`, `.unlink(item)`; instance `#present?`, `#data`, `#bucket`, `#reasons`, `#pending?`, `#decided?`, `#flagged?`, `#removed?`, `#settled?`, `#settled_by_id`, `#ol_keys`, `#ol_work_key`, `#target_record_id`, `#match_decision_id`, `#decided_by`, `#matched_at → Time|nil`, `#import_result`, `#import_error`, `#error`, `#merge(hash) → self` (sets `item.metadata`, does not save), `#settle(by:) → self`.
  - `Services::Lists::Wizard::Core::Outcome.classify(match) → Outcome::Result(bucket:, reasons:, target_record_id:, external_key:)`.
  - `Services::Lists::Wizard::Core::OnListTwice.call(list:) → Integer` (rows flagged).
  - Test helper `ListWizardHelper`: `wizard_list`, `wizard_row`, `wizard_match`, `ol_candidate`, `local_candidate`, `ListWizardHelper::FakeFinder`.

Decision: **exact metadata key names** are the table above ("Row state keys"); the namespace is `metadata["wizard"]`.
Decision: **a row with no `wizard` key counts as settled**, so restart, re-parse and re-match never touch rows from before the wizard (migrated lists, rows added on the list page).
Decision: **an unlinked row keeps `listable_type`** (`RowState.unlink` clears only `listable_id` and `verified`), matching how the parser writes rows.
Decision: **a flagged row that no specific reason covers gets `unsure`.** The one case in practice: the AI picks the Open Library work the service accepted while local candidates exist. The spec's table sends it to `flagged` (create needs `decided_by == :rule`) but lists no reason for it.

- [ ] **Step 1: Write the test helper and the failing tests**

`web-app/test/support/list_wizard_helper.rb`:

```ruby
# frozen_string_literal: true

# Builders for the list wizard core's tests (books list wizard spec): a books
# list, wizard rows, and finder answers that carry a persisted MatchDecision.
module ListWizardHelper
  def wizard_list(name: "Wizard Test List", raw_content: "<ol><li>War and Peace by Leo Tolstoy</li></ol>")
    ::Books::List.create!(name: name, status: :unapproved, raw_content: raw_content)
  end

  def wizard_row(list, position:, title:, authors: [], subtitle: nil, year: nil, listable: nil, verified: false, wizard: {})
    attributes = {
      position: position, verified: verified,
      metadata: {
        "title" => title, "subtitle" => subtitle, "authors" => authors, "year" => year,
        "wizard" => {"bucket" => "pending", "reasons" => [], "settled" => false}.merge(wizard.deep_stringify_keys)
      }
    }
    if listable
      attributes[:listable] = listable
    else
      attributes[:listable_type] = "Books::Book"
    end
    list.list_items.create!(attributes)
  end

  def wizard_match(subject:, outcome:, record: nil, confidence: :high, decided_by: :rule, external: nil,
    candidates: [], external_resolution: nil, sources_failed: [])
    decision = ::MatchDecision.create!(
      finder: "DataImporters::Books::Book::Finder", subject: subject, record: record, outcome: outcome,
      confidence: confidence, decided_by: decided_by, query: {}, candidates: candidates.map(&:snapshot),
      needs_review: %i[medium low].include?(confidence) || decided_by == :fallback
    )
    ::DataImporters::Match.new(
      outcome: outcome, record: record, confidence: confidence, decided_by: decided_by, reason: "test",
      candidates: candidates, external: external, external_resolution: external_resolution, decision: decision,
      sources_failed: sources_failed
    )
  end

  def ol_candidate(key, verdict: "accept", title: "An Open Library Work", creators: [], year: nil)
    ::DataImporters::Candidate.new(
      external_key: key, external_source: :open_library, sources: [:open_library], scores: {open_library: 0.9},
      evidence: {external_verdict: verdict, title: title, creators: creators, year: year}
    )
  end

  def local_candidate(book, list_count: 0)
    ::DataImporters::Candidate.new(
      record: book, sources: [:exact],
      evidence: {title: book.title, creators: book.authors.map(&:name), year: book.first_published_year, list_count: list_count}
    )
  end

  # A finder stand-in. Each call answers with the next answer given (the last
  # one repeats); an answer that responds to #call gets the row, so a test can
  # build a match whose decision belongs to that row.
  class FakeFinder
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
    end

    def call(query:, subject: nil, verify: false, exclude: nil)
      @calls << {query: query, subject: subject}
      answer = (@answers.size > 1) ? @answers.shift : @answers.first
      answer.respond_to?(:call) ? answer.call(subject) : answer
    end
  end
end
```

In `web-app/test/test_helper.rb`, after `require_relative "support/goodreads_import_helper"`:

```ruby
require_relative "support/list_wizard_helper"
```

`web-app/test/lib/services/lists/wizard/core/signature_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class SignatureTest < ActiveSupport::TestCase
          test "case, curly quotes, spacing and creator order do not change a signature" do
            assert_equal Signature.call("The Hitchhiker’s Guide", ["Douglas Adams", "Eoin Colfer"]),
              Signature.call("  the hitchhiker's   guide ", ["eoin colfer", "DOUGLAS ADAMS"])
          end

          test "a different title or a different creator does" do
            base = Signature.call("Emma", ["Jane Austen"])

            assert_not_equal base, Signature.call("Persuasion", ["Jane Austen"])
            assert_not_equal base, Signature.call("Emma", ["Emma Tennant"])
          end

          test "normalize answers nil for nil and drops blank creators" do
            assert_nil Signature.normalize(nil)
            assert_equal ["emma", ["jane austen"]], Signature.call("Emma", ["Jane Austen", "", nil])
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/row_state_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class RowStateTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
          end

          test "a row with no wizard key is settled and not pending; a parsed row is pending and unsettled" do
            old = @list.list_items.create!(listable: books_books(:war_and_peace), position: 1)
            parsed = wizard_row(@list, position: 2, title: "Emma")

            assert RowState.new(old).settled?
            assert_not RowState.new(old).present?
            assert_not RowState.new(parsed).settled?
            assert RowState.new(parsed).pending?
          end

          test "merge writes into metadata under the wizard key without saving and keeps the rest" do
            row = wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"])

            RowState.new(row).merge(bucket: "flagged", reasons: ["unsure"])

            assert row.changed?
            assert_equal "Emma", row.metadata["title"]
            assert_equal ["flagged", ["unsure"], false], row.metadata["wizard"].values_at("bucket", "reasons", "settled")
            assert_equal "pending", row.reload.metadata.dig("wizard", "bucket")
          end

          test "settle records who and when" do
            row = wizard_row(@list, position: 1, title: "Emma")
            admin = users(:admin_user)

            freeze_time do
              state = RowState.new(row).settle(by: admin)
              assert state.settled?
              assert_equal [admin.id, Time.current.iso8601], [state.settled_by_id, state.data["settled_at"]]
            end
          end

          test "readers parse the stored values" do
            row = wizard_row(@list, position: 1, title: "Emma", wizard: {
              bucket: "create", ol_keys: ["OL1W"], ol_work_key: "OL1W", target_record_id: 7, match_decision_id: 9,
              decided_by: "ai", matched_at: "2026-10-06T10:00:00Z", import_result: "created", import_error: "boom", error: "bad"
            })
            state = RowState.new(row)

            assert_equal [["OL1W"], "OL1W", 7, 9, "ai", "created", "boom", "bad"],
              [state.ol_keys, state.ol_work_key, state.target_record_id, state.match_decision_id, state.decided_by,
                state.import_result, state.import_error, state.error]
            assert_equal Time.utc(2026, 10, 6, 10), state.matched_at
            assert state.decided?
            assert_not state.flagged?
            assert_not state.removed?
          end

          test "unsettled lists only rows the wizard may still change" do
            parsed = wizard_row(@list, position: 1, title: "Emma")
            wizard_row(@list, position: 2, title: "Persuasion", wizard: {settled: true})
            @list.list_items.create!(listable: books_books(:war_and_peace), position: 3)

            assert_equal [parsed.id], RowState.unsettled(@list).map(&:id)
          end

          test "holder_of finds another row holding the record, never the row asked about" do
            book = books_books(:war_and_peace)
            holder = wizard_row(@list, position: 1, title: "War and Peace", listable: book)
            other = wizard_row(@list, position: 2, title: "Emma")

            assert_equal holder, RowState.holder_of(@list, book, except: other)
            assert_nil RowState.holder_of(@list, book, except: holder)
            assert_nil RowState.holder_of(@list, books_books(:crime_and_punishment))
          end

          test "unlink clears the link and verification but keeps the listable type" do
            row = wizard_row(@list, position: 1, title: "War and Peace", listable: books_books(:war_and_peace), verified: true)

            RowState.unlink(row)

            assert_nil row.listable_id
            assert_equal ["Books::Book", false], [row.listable_type, row.verified]
          end

          test "label_for gives plain words for every reason and humanizes an unknown one" do
            RowState::REASON_LABELS.each_key { |reason| assert RowState.label_for(reason).present? }
            assert_equal "Something odd", RowState.label_for("something_odd")
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/outcome_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class OutcomeTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @row = wizard_row(wizard_list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"])
            @book = books_books(:war_and_peace)
          end

          def classify(**attributes)
            Outcome.classify(wizard_match(subject: @row, **attributes))
          end

          test "a certain identifier match is matched, pointing at the book" do
            result = classify(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier, candidates: [local_candidate(@book)])

            assert_equal ["matched", [], @book.id, nil], [result.bucket, result.reasons, result.target_record_id, result.external_key]
          end

          test "an AI match at high confidence passes through as matched" do
            result = classify(outcome: :matched, record: @book, confidence: :high, decided_by: :ai, candidates: [local_candidate(@book)])

            assert_equal "matched", result.bucket
          end

          test "a match at medium confidence (a failed source caps high at medium) is flagged unsure" do
            result = classify(outcome: :matched, record: @book, confidence: :medium, decided_by: :rule, candidates: [local_candidate(@book)])

            assert_equal ["flagged", ["unsure"]], [result.bucket, result.reasons]
          end

          test "a fallback is flagged unsure" do
            result = classify(outcome: :unmatched, confidence: :low, decided_by: :fallback, candidates: [local_candidate(@book)])

            assert_equal ["flagged", ["unsure"]], [result.bucket, result.reasons]
          end

          test "rule 5 (the service accepted a work nobody holds) is create, with that work" do
            work = ol_candidate("OL9W")
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :rule, external: work, candidates: [work])

            assert_equal ["create", [], "OL9W"], [result.bucket, result.reasons, result.external_key]
          end

          test "no candidates at all is flagged not_found" do
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])

            assert_equal ["flagged", ["not_found"]], [result.bucket, result.reasons]
          end

          test "the AI picking none of the candidates is flagged not_found" do
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :ai, candidates: [local_candidate(@book)])

            assert_equal ["flagged", ["not_found"]], [result.bucket, result.reasons]
          end

          test "the AI picking an Open Library work the service did not accept is flagged ai_only_pick, never create" do
            work = ol_candidate("OL3W", verdict: "abstain")
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :ai, external: work, candidates: [work])

            assert_equal ["flagged", ["ai_only_pick"]], [result.bucket, result.reasons]
            assert_nil result.external_key
          end

          test "the AI picking the accepted work while local candidates exist is flagged unsure, not ai_only_pick" do
            work = ol_candidate("OL4W")
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :ai, external: work,
              candidates: [local_candidate(@book), work])

            assert_equal ["flagged", ["unsure"]], [result.bucket, result.reasons]
          end

          test "a medium AI none carries both reasons" do
            result = classify(outcome: :unmatched, confidence: :medium, decided_by: :ai, candidates: [local_candidate(@book)])

            assert_equal ["unsure", "not_found"], result.reasons
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/on_list_twice_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class OnListTwiceTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @book = books_books(:war_and_peace)
          end

          test "two rows landing on the same local book are both flagged and the linked one is unlinked" do
            linked = wizard_row(@list, position: 1, title: "War and Peace", listable: @book, verified: true,
              wizard: {bucket: "matched", target_record_id: @book.id})
            blocked = wizard_row(@list, position: 2, title: "War & Peace",
              wizard: {bucket: "flagged", reasons: ["on_list_twice"], target_record_id: @book.id})

            assert_equal 2, OnListTwice.call(list: @list)

            linked.reload
            assert_equal ["flagged", ["on_list_twice"]], linked.metadata["wizard"].values_at("bucket", "reasons")
            assert_nil linked.listable_id
            assert_not linked.verified?
            assert_equal ["on_list_twice"], blocked.reload.metadata.dig("wizard", "reasons")
          end

          test "two create rows for the same Open Library work are both flagged" do
            a = wizard_row(@list, position: 1, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            b = wizard_row(@list, position: 2, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})

            OnListTwice.call(list: @list)

            assert_equal ["flagged", "flagged"], [a, b].map { |row| row.reload.metadata.dig("wizard", "bucket") }
          end

          test "a settled row in a clash is left alone and the unsettled one is flagged" do
            settled = wizard_row(@list, position: 1, title: "War and Peace", listable: @book, verified: true,
              wizard: {bucket: "matched", target_record_id: @book.id, settled: true})
            unsettled = wizard_row(@list, position: 2, title: "War and Peace",
              wizard: {bucket: "flagged", reasons: ["on_list_twice"], target_record_id: @book.id})

            assert_equal 1, OnListTwice.call(list: @list)
            assert_equal [@book.id, "matched"], [settled.reload.listable_id, settled.metadata.dig("wizard", "bucket")]
            assert_equal "flagged", unsettled.reload.metadata.dig("wizard", "bucket")
          end

          test "rows on different books or works, and removed rows, are not a clash" do
            wizard_row(@list, position: 1, title: "War and Peace", listable: @book, wizard: {bucket: "matched", target_record_id: @book.id})
            crime = books_books(:crime_and_punishment)
            other = wizard_row(@list, position: 2, title: "Crime and Punishment", listable: crime, wizard: {bucket: "matched", target_record_id: crime.id})
            wizard_row(@list, position: 3, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            wizard_row(@list, position: 4, title: "Dune again", wizard: {bucket: "removed", settled: true, ol_work_key: "OL5W"})
            wizard_row(@list, position: 5, title: "Emma", wizard: {bucket: "create", ol_work_key: "OL6W"})

            assert_equal 0, OnListTwice.call(list: @list)
            assert_equal "matched", other.reload.metadata.dig("wizard", "bucket")
          end

          test "running the pass twice changes nothing more" do
            wizard_row(@list, position: 1, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            wizard_row(@list, position: 2, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            OnListTwice.call(list: @list)
            first = @list.list_items.reload.map { |row| row.metadata["wizard"] }

            OnListTwice.call(list: @list)

            assert_equal first, @list.list_items.reload.map { |row| row.metadata["wizard"] }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/wizard/core/`
Expected: FAIL — `NameError: uninitialized constant Services::Lists::Wizard::Core`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/core/signature.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # How the wizard compares row text: the finder's normalization (quotes,
        # Unicode width, spacing, case) on the title and each creator, creators
        # sorted. Re-parse uses it to skip a row a kept row already covers.
        module Signature
          def self.normalize(text)
            return nil if text.nil?

            ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
          end

          def self.call(title, creators)
            [normalize(title).to_s, Array(creators).map { |name| normalize(name) }.compact_blank.sort]
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/core/row_state.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # A list item's wizard state, kept in metadata["wizard"] (books list
        # wizard spec §7). Writers change item.metadata and never save.
        class RowState
          KEY = "wizard"
          DECIDED_BUCKETS = %w[matched create flagged].freeze
          REASON_LABELS = {
            "unsure" => "The finder was not sure",
            "not_found" => "No match found",
            "ai_only_pick" => "Only the AI picked this Open Library work",
            "on_list_twice" => "Another row on this list lands on the same book",
            "match_failed" => "The lookup failed",
            "import_failed" => "Import failed",
            "changed_since_match" => "A matching book appeared after Match"
          }.freeze
          INITIAL = {"bucket" => "pending", "reasons" => [], "settled" => false}.freeze
          PENDING = {"bucket" => "pending", "reasons" => [], "target_record_id" => nil, "ol_work_key" => nil,
                     "import_error" => nil, "error" => nil}.freeze

          def self.unsettled(list)
            list.list_items.reload.reject { |item| new(item).settled? }
          end

          def self.holder_of(list, record, except: nil)
            scope = list.list_items.where(listable: record)
            scope = scope.where.not(id: except.id) if except
            scope.order(:position, :id).first
          end

          def self.label_for(reason)
            REASON_LABELS.fetch(reason.to_s) { reason.to_s.humanize }
          end

          def self.unlink(item)
            item.listable_id = nil
            item.verified = false
          end

          def initialize(item)
            @item = item
          end

          def present? = @item.metadata.is_a?(Hash) && @item.metadata[KEY].is_a?(Hash)

          def data = present? ? @item.metadata[KEY] : {}

          def bucket = data["bucket"]

          def reasons = Array(data["reasons"])

          def pending? = bucket == "pending"

          def decided? = DECIDED_BUCKETS.include?(bucket)

          def flagged? = bucket == "flagged"

          def removed? = bucket == "removed"

          # A row with no wizard state predates the wizard and is not its to change.
          def settled? = !present? || data["settled"] == true

          def settled_by_id = data["settled_by_id"]

          def ol_keys = Array(data["ol_keys"])

          def ol_work_key = data["ol_work_key"].presence

          def target_record_id = data["target_record_id"]

          def match_decision_id = data["match_decision_id"]

          def decided_by = data["decided_by"]

          def import_result = data["import_result"]

          def import_error = data["import_error"]

          def error = data["error"]

          def matched_at
            value = data["matched_at"]
            value.present? ? Time.zone.parse(value) : nil
          end

          def merge(attributes)
            base = @item.metadata.is_a?(Hash) ? @item.metadata : {}
            @item.metadata = base.merge(KEY => data.merge(attributes.to_h.transform_keys(&:to_s)))
            self
          end

          def settle(by:)
            merge("settled" => true, "settled_by_id" => by&.id, "settled_at" => Time.current.iso8601)
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/core/outcome.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: every row lands in exactly one bucket.
        class Outcome
          Result = Struct.new(:bucket, :reasons, :target_record_id, :external_key, keyword_init: true)

          def self.classify(match)
            new(match).classify
          end

          def initialize(match)
            @match = match
          end

          def classify
            if matched_confidently?
              Result.new(bucket: "matched", reasons: [], target_record_id: @match.record.id, external_key: nil)
            elsif creatable?
              Result.new(bucket: "create", reasons: [], target_record_id: nil, external_key: @match.external.external_key)
            else
              Result.new(bucket: "flagged", reasons: reasons, target_record_id: nil, external_key: nil)
            end
          end

          private

          def matched_confidently?
            @match.matched? && %i[certain high].include?(@match.confidence) && !@match.needs_review?
          end

          def creatable?
            @match.unmatched? && @match.decided_by == :rule && !@match.needs_review? && accepted_external?
          end

          def accepted_external?
            external = @match.external
            !external.nil? && external.external? && external.external_accepted?
          end

          def reasons
            found = []
            found << "unsure" if @match.needs_review?
            found << "not_found" if @match.candidates.empty? || ai_picked_none?
            found << "ai_only_pick" if ai_picked_unaccepted_external?
            found << "unsure" if found.empty?
            found.uniq
          end

          def ai_picked_none?
            @match.decided_by == :ai && @match.unmatched? && @match.external.nil?
          end

          def ai_picked_unaccepted_external?
            @match.decided_by == :ai && @match.unmatched? && !@match.external.nil? && !accepted_external?
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/core/on_list_twice.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: rows that land on the same local book, or
        # on the same Open Library work to create, are all flagged. Settled rows
        # are never changed (§8). Safe to run again.
        class OnListTwice
          def self.call(list:)
            new(list).call
          end

          def initialize(list)
            @list = list
          end

          def call
            rows = @list.list_items.to_a.reject { |item| RowState.new(item).removed? }
            groups = rows.group_by { |item| target_key(item) }
            groups.delete(nil)

            flagged = 0
            groups.each_value do |members|
              next if members.size < 2

              members.each do |item|
                state = RowState.new(item)
                next if state.settled?

                state.merge("bucket" => "flagged", "reasons" => (state.reasons + ["on_list_twice"]).uniq)
                RowState.unlink(item)
                item.save!
                flagged += 1
              end
            end
            flagged
          end

          private

          def target_key(item)
            state = RowState.new(item)
            record_id = item.listable_id || state.target_record_id
            return "record:#{record_id}" if record_id
            return "work:#{state.ol_work_key}" if state.bucket == "create" && state.ol_work_key

            nil
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests and the autoload check**

Run: `bin/rails test test/lib/services/lists/wizard/core/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; `All is good!`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/core/ test/lib/services/lists/wizard/core/ test/support/list_wizard_helper.rb test/test_helper.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: row state, outcome rules and the on-list-twice pass

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Books state manager and the step-scoped state write

**Files:**
- Modify: `web-app/app/lib/services/lists/wizard/state_manager.rb` (`.for`, `#write_step!`, `#go_to_step!`)
- Create: `web-app/app/lib/services/lists/wizard/books/state_manager.rb`
- Test: `web-app/test/lib/services/lists/wizard/state_manager_test.rb` (two tests change, three added); create `web-app/test/lib/services/lists/wizard/books/state_manager_test.rb`

**Interfaces:**
- Produces: `Services::Lists::Wizard::Books::StateManager#steps → %w[paste parse match review import done]`; `StateManager.for(books_list)` returns it; `StateManager#write_step!(step:, status:, progress: nil, error: nil, metadata: {})` (row-locks and re-reads the list, writes only `steps[step]`); `StateManager#go_to_step!(index, completed: false)` (row-locks, re-reads, writes only `current_step` / `completed_at`).

Decision: **the state-write rule** is a `with_lock` (row lock + reload) around the existing merge, used by the new jobs and the new controller only; old jobs are untouched. This is a row lock for one read-modify-write, not the creation lock decision 10 rules out.
Decision: **a list whose `wizard_state` is nil** opens at step 0 (Paste): `current_step` already falls back to 0, and nothing else needs a non-nil state.

- [ ] **Step 1: Write the failing tests**

In `test/lib/services/lists/wizard/state_manager_test.rb`, replace `".for returns base StateManager for Books::List"` with:

```ruby
        test ".for returns the books StateManager for Books::List" do
          manager = StateManager.for(lists(:books_list))
          assert_instance_of Services::Lists::Wizard::Books::StateManager, manager
        end

        test ".for returns the base StateManager for Games::List" do
          manager = StateManager.for(lists(:games_list))
          assert_instance_of Services::Lists::Wizard::StateManager, manager
        end
```

replace `"#steps returns default wizard steps for base class"` with:

```ruby
        test "#steps returns default wizard steps for base class" do
          manager = StateManager.new(lists(:books_list))
          assert_equal %w[source parse enrich validate review import complete], manager.steps
        end
```

and add:

```ruby
        test "#write_step! re-reads the list, so a Back click made meanwhile survives" do
          @list.update!(wizard_state: {"current_step" => 1, "steps" => {}})
          stale = List.find(@list.id)
          List.find(@list.id).wizard_manager.go_to_step!(3)

          stale.wizard_manager.write_step!(step: "parse", status: "completed", progress: 100, metadata: {"total_items" => 4})

          @list.reload
          assert_equal 3, @list.wizard_manager.current_step
          assert_equal ["completed", 100, {"total_items" => 4}],
            [@list.wizard_manager.step_status("parse"), @list.wizard_manager.step_progress("parse"), @list.wizard_manager.step_metadata("parse")]
        end

        test "#go_to_step! re-reads the list, so a job's step write made meanwhile survives" do
          @list.update!(wizard_state: {"current_step" => 1, "steps" => {}})
          stale = List.find(@list.id)
          List.find(@list.id).wizard_manager.write_step!(step: "parse", status: "running", progress: 40)

          stale.wizard_manager.go_to_step!(2, completed: true)

          @list.reload
          assert_equal [2, "running", 40], [@list.wizard_manager.current_step, @list.wizard_manager.step_status("parse"), @list.wizard_manager.step_progress("parse")]
          assert @list.wizard_state["completed_at"].present?
        end

        test "#go_to_step! leaves completed_at alone unless asked" do
          @list.update!(wizard_state: {"current_step" => 1})

          @list.wizard_manager.go_to_step!(2)

          assert_nil @list.reload.wizard_state["completed_at"]
        end
```

Create `test/lib/services/lists/wizard/books/state_manager_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Books
        class StateManagerTest < ActiveSupport::TestCase
          test "names the books wizard's six steps, Paste first" do
            manager = StateManager.new(lists(:books_list))

            assert_equal %w[paste parse match review import done], manager.steps
            assert_equal "paste", manager.current_step_name
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/wizard/state_manager_test.rb test/lib/services/lists/wizard/books/state_manager_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Lists::Wizard::Books`, `NoMethodError: undefined method 'go_to_step!'`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/books/state_manager.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Books
        # Books list wizard steps (books list wizard spec, decision 7).
        class StateManager < Services::Lists::Wizard::StateManager
          STEPS = %w[paste parse match review import done].freeze

          def steps
            STEPS
          end
        end
      end
    end
  end
end
```

In `state_manager.rb`, add the branch to `.for`:

```ruby
          when "Books::List"
            Services::Lists::Wizard::Books::StateManager
```

and add these public methods after `update_step_status!`:

```ruby
        # The list wizard core's write (books list wizard spec §7): lock the
        # list row, re-read it, and write only this step's entry, so a Back or
        # Next click made while a job ran is not overwritten by a stale copy.
        def write_step!(step:, status:, progress: nil, error: nil, metadata: {})
          list.with_lock do
            update_step_status!(step: step, status: status, progress: progress, error: error, metadata: metadata)
          end
        end

        # The controller's half of the same rule: move the current step without
        # overwriting a step entry a job wrote meanwhile.
        def go_to_step!(index, completed: false)
          list.with_lock do
            changes = {"current_step" => index}
            changes["completed_at"] = Time.current.iso8601 if completed
            list.update!(wizard_state: safe_wizard_state.merge(changes))
          end
        end
```

- [ ] **Step 4: Run the tests and the autoload check**

Run: `bin/rails test test/lib/services/lists/wizard/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; `All is good!`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/state_manager.rb app/lib/services/lists/wizard/books/state_manager.rb test/lib/services/lists/wizard/state_manager_test.rb test/lib/services/lists/wizard/books/state_manager_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: books steps and the step-scoped state write

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Books adapter (parse, query, finder, saved keys, display) and the adapter registry

**Files:**
- Create: `web-app/app/lib/services/lists/wizard/books/adapter.rb`
- Create: `web-app/app/lib/services/lists/wizard/core/adapters.rb`
- Test: `web-app/test/lib/services/lists/wizard/books/adapter_test.rb`, `web-app/test/lib/services/lists/wizard/core/adapters_test.rb`

**Interfaces:**
- Consumes: Task 1 (`ImportQuery subtitle:`, `RawParserTask` subtitle), Task 4 (`Core::Signature`).
- Produces: `Services::Lists::Wizard::Books::Adapter` with `Result` struct and:
  - `#listable_type → "Books::Book"`, `#listable_includes → [:authors]`
  - `#parse(list, content: nil) → Result(success?, data: Array<Hash{"rank","title","subtitle","authors","year"}>, errors)` (`content:` = one batch, passed to the parser task's `content:`)
  - `#signature(title, authors) → Array`, `#row_signature(list_item) → Array`
  - `#query_for(list_item) → DataImporters::Books::Book::ImportQuery`
  - `#finder → DataImporters::Books::Book::Finder` (new instance per call)
  - `#recheck_keys(match) → Array<String>`
  - `#find_record(id) → Books::Book|nil`
  - `#row_display(list_item) → {title:, subtitle:, authors:, year:}`, `#record_display(book) → {title:, authors:, year:}`
  - `Services::Lists::Wizard::Core::Adapters.for(list) → adapter` (raises `ArgumentError` for a list type with no adapter).
  - Later tasks add `#recheck`, `#create` (Task 9) and `#wizard_path`, `#search_path`, `#lists_path`, `#list_path` (Task 12).

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/lists/wizard/books/adapter_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Books
        class AdapterTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @adapter = Adapter.new
            @list = wizard_list
          end

          def resolution(accept_key:, duplicates: [], duplicate_redirects: [], redirect_sources: [])
            key = ->(value) { {"source" => "openlibrary", "key" => value} }
            ::Books::OpenLibrary::Resolution.from_response({
              "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                                   "pipeline_version" => 1, "matcher_version" => 2},
              "data" => {
                "decision" => {"verdict" => "accept", "key" => key.call(accept_key), "score" => 0.9, "margin" => 0.3, "reason" => "test",
                               "duplicates" => duplicates.map(&key), "duplicate_redirect_sources" => duplicate_redirects.map(&key)},
                "guards_tripped" => [], "volume_guards_tripped" => [],
                "candidates" => [{"key" => key.call(accept_key), "score" => 0.9, "rules" => [], "margin" => 0.3, "verdict" => "accept",
                                  "evidence" => {}, "conflicts" => [], "diff" => [], "record" => nil,
                                  "redirect_sources" => redirect_sources.map(&key)}]
              }
            })
          end

          test "parse maps the parser's books to wizard rows, subtitle and year included, and drops untitled ones" do
            data = {books: [
              {rank: 1, title: " Sapiens ", subtitle: "A Brief History of Humankind", authors: ["Yuval Noah Harari", " "], publication_year: 2011},
              {rank: nil, title: "", subtitle: nil, authors: [], publication_year: nil}
            ]}
            ::Services::Ai::Tasks::Lists::Books::RawParserTask.any_instance.stubs(:call)
              .returns(::Services::Ai::Result.new(success: true, data: data))

            result = @adapter.parse(@list)

            assert result.success?
            assert_equal [{"rank" => 1, "title" => "Sapiens", "subtitle" => "A Brief History of Humankind",
                           "authors" => ["Yuval Noah Harari"], "year" => 2011}], result.data
          end

          test "parse hands a batch's content to the parser" do
            task = stub(call: ::Services::Ai::Result.new(success: true, data: {books: []}))
            ::Services::Ai::Tasks::Lists::Books::RawParserTask.expects(:new).with(parent: @list, content: "1. Emma by Jane Austen").returns(task)

            assert @adapter.parse(@list, content: "1. Emma by Jane Austen").success?
          end

          test "parse reports the parser's error" do
            ::Services::Ai::Tasks::Lists::Books::RawParserTask.any_instance.stubs(:call)
              .returns(::Services::Ai::Result.new(success: false, error: "rate limited"))

            result = @adapter.parse(@list)

            assert_not result.success?
            assert_equal ["rate limited"], result.errors
          end

          test "row_signature uses the row's text, and falls back to the linked book's for a row without it" do
            text_row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"])
            bare_row = @list.list_items.create!(listable: books_books(:war_and_peace), position: 2)

            expected = @adapter.signature("war and peace", ["LEO TOLSTOY"])
            assert_equal expected, @adapter.row_signature(text_row)
            assert_equal expected, @adapter.row_signature(bare_row)
          end

          test "query_for builds the finder query from the row, subtitle and year included" do
            row = wizard_row(@list, position: 1, title: "Sapiens", subtitle: "A Brief History of Humankind",
              authors: ["Yuval Noah Harari"], year: "2011")

            query = @adapter.query_for(row)

            assert_instance_of ::DataImporters::Books::Book::ImportQuery, query
            assert_equal ["Sapiens", "A Brief History of Humankind", ["Yuval Noah Harari"], 2011],
              [query.title, query.subtitle, query.author_names, query.year]
          end

          test "query_for drops a year that is not a year" do
            row = wizard_row(@list, position: 1, title: "Sapiens", year: "circa 2011")

            assert_nil @adapter.query_for(row).year
          end

          test "finder is a fresh books finder" do
            assert_instance_of ::DataImporters::Books::Book::Finder, @adapter.finder
            assert_not_same @adapter.finder, @adapter.finder
          end

          test "recheck_keys saves the chosen work, the accepted key, its duplicates and both redirect-source lists" do
            row = wizard_row(@list, position: 1, title: "Dune")
            match = wizard_match(subject: row, outcome: :unmatched, external: ol_candidate("OL1W"),
              external_resolution: resolution(accept_key: "OL1W", duplicates: ["OL2W"], duplicate_redirects: ["OL3W"], redirect_sources: ["OL4W"]))

            assert_equal %w[OL1W OL2W OL3W OL4W], @adapter.recheck_keys(match).sort
          end

          test "recheck_keys without a resolution keeps only an Open Library external key" do
            row = wizard_row(@list, position: 1, title: "Dune")
            ol = wizard_match(subject: row, outcome: :unmatched, external: ol_candidate("OL1W"))
            other = wizard_match(subject: row, outcome: :unmatched,
              external: ::DataImporters::Candidate.new(external_key: "X1", external_source: :igdb))

            assert_equal ["OL1W"], @adapter.recheck_keys(ol)
            assert_equal [], @adapter.recheck_keys(other)
          end

          test "find_record finds a book by id and answers nil for an unknown one" do
            assert_equal books_books(:got), @adapter.find_record(books_books(:got).id.to_s)
            assert_nil @adapter.find_record("0")
          end

          test "row_display and record_display give title, authors and year" do
            row = wizard_row(@list, position: 1, title: "Sapiens", subtitle: "A Brief History", authors: ["Yuval Noah Harari"], year: 2011)

            assert_equal({title: "Sapiens", subtitle: "A Brief History", authors: ["Yuval Noah Harari"], year: 2011}, @adapter.row_display(row))
            assert_equal({title: "War and Peace", authors: ["Leo Tolstoy"], year: 1869}, @adapter.record_display(books_books(:war_and_peace)))
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/adapters_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class AdaptersTest < ActiveSupport::TestCase
          test "a books list gets the books adapter" do
            assert_instance_of ::Services::Lists::Wizard::Books::Adapter, Adapters.for(lists(:books_list))
          end

          test "a list type with no adapter is refused" do
            assert_raises(ArgumentError) { Adapters.for(lists(:games_list)) }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/wizard/books/adapter_test.rb test/lib/services/lists/wizard/core/adapters_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Lists::Wizard::Books::Adapter`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/core/adapters.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # The one place a list type picks its wizard adapter. Music and games
        # add theirs when they move onto the core.
        module Adapters
          def self.for(list)
            case list.type
            when "Books::List" then ::Services::Lists::Wizard::Books::Adapter.new
            else raise ArgumentError, "no list wizard adapter for #{list.type}"
            end
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/books/adapter.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Books
        # The books side of the list wizard core (books list wizard spec §1):
        # parser, finder query, finder, importer, search and display.
        class Adapter
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)
          LISTABLE_TYPE = "Books::Book"

          def listable_type = LISTABLE_TYPE

          def listable_includes = [:authors]

          def parse(list, content: nil)
            result = ::Services::Ai::Tasks::Lists::Books::RawParserTask.new(parent: list, content: content).call
            return Result.new(success?: false, data: [], errors: [result.error.presence || "Parsing failed"]) unless result.success?

            books = Array(result.data[:books] || result.data["books"])
            rows = books.map do |book|
              book = book.to_h.transform_keys(&:to_sym)
              {
                "rank" => book[:rank],
                "title" => book[:title].to_s.strip,
                "subtitle" => book[:subtitle].to_s.strip.presence,
                "authors" => Array(book[:authors]).map { |name| name.to_s.strip }.compact_blank,
                "year" => book[:publication_year]
              }
            end
            Result.new(success?: true, data: rows.reject { |row| row["title"].empty? }, errors: [])
          end

          def signature(title, authors)
            ::Services::Lists::Wizard::Core::Signature.call(title, authors)
          end

          def row_signature(item)
            metadata = item.metadata || {}
            book = item.listable
            title = metadata["title"].presence || book&.title
            authors = Array(metadata["authors"]).presence || Array(book&.authors&.map(&:name))
            signature(title, authors)
          end

          def query_for(item)
            metadata = item.metadata || {}
            ::DataImporters::Books::Book::ImportQuery.new(
              title: metadata["title"], subtitle: metadata["subtitle"],
              author_names: Array(metadata["authors"]), year: year_of(metadata)
            )
          end

          def finder
            ::DataImporters::Books::Book::Finder.new
          end

          # The Open Library keys a later Import re-check needs (spec §3): the
          # chosen work, the accepted key, its duplicates and both redirect-
          # source lists.
          def recheck_keys(match)
            keys = []
            external = match.external
            keys << external.external_key if external&.external_source == :open_library
            resolution = match.external_resolution
            if resolution
              keys << resolution.decision.key if resolution.accept?
              keys.concat(Array(resolution.decision.duplicates), Array(resolution.decision.duplicate_redirect_sources))
              keys.concat(Array(resolution.accepted&.redirect_sources))
            end
            keys.compact_blank.uniq
          end

          def find_record(id)
            ::Books::Book.find_by(id: id)
          end

          def row_display(item)
            metadata = item.metadata || {}
            {
              title: metadata["title"].presence || item.listable&.title,
              subtitle: metadata["subtitle"],
              authors: Array(metadata["authors"]).presence || Array(item.listable&.authors&.map(&:name)),
              year: metadata["year"]
            }
          end

          def record_display(book)
            {title: book.title, authors: book.authors.map(&:name), year: book.first_published_year}
          end

          private

          def year_of(metadata)
            value = metadata["year"]
            return value if value.is_a?(Integer)

            value.to_s.strip.match?(/\A\d{1,4}\z/) ? value.to_i : nil
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests and the autoload check**

Run: `bin/rails test test/lib/services/lists/wizard/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS; `All is good!`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/books/adapter.rb app/lib/services/lists/wizard/core/adapters.rb test/lib/services/lists/wizard/books/adapter_test.rb test/lib/services/lists/wizard/core/adapters_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
Books list wizard: the books adapter and the adapter registry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Parse (service + job)

**Files:**
- Create: `web-app/app/lib/services/lists/wizard/core/parse_rows.rb`
- Create (generator): `bin/rails generate sidekiq:job lists/wizard/parse` → `web-app/app/sidekiq/lists/wizard/parse_job.rb`, `web-app/test/sidekiq/lists/wizard/parse_job_test.rb`
- Test: `web-app/test/lib/services/lists/wizard/core/parse_rows_test.rb`

**Interfaces:**
- Consumes: adapter `#parse`, `#signature`, `#row_signature`, `#listable_type`, `#listable_includes` (Task 6); `RowState` (Task 4); `StateManager#write_step!` (Task 5).
- Produces: `Services::Lists::Wizard::Core::ParseRows.call(list:, adapter:) → Integer|nil` (rows added; nil on failure), with `ParseRows::BATCH_SIZE = 100`; `Lists::Wizard::ParseJob#perform(list_id)`.

Batch mode (controller ruling; mirrors `BaseWizardParseListJob#perform_batched_parse`, `web-app/app/sidekiq/base_wizard_parse_list_job.rb:115+`): when `wizard_state["batch_mode"] == true`, `simplified_content` is split into batches of 100 non-blank lines, the parser runs once per batch with `content:`, positions are strictly sequential across batches (AI ranks ignored), and a failed batch fails the parse and deletes nothing.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/lists/wizard/core/parse_rows_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class ParseRowsTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @adapter = ::Services::Lists::Wizard::Books::Adapter.new
          end

          def parsed(*rows)
            @adapter.stubs(:parse).returns(::Services::Lists::Wizard::Books::Adapter::Result.new(success?: true, data: rows, errors: []))
          end

          def row(title, authors = [], rank: nil, subtitle: nil, year: nil)
            {"rank" => rank, "title" => title, "subtitle" => subtitle, "authors" => authors, "year" => year}
          end

          test "each parsed book becomes a pending row at its rank, with its text in metadata" do
            parsed(row("Emma", ["Jane Austen"]), row("Sapiens", ["Yuval Noah Harari"], rank: 5, subtitle: "A Brief History", year: 2011))

            assert_equal 2, ParseRows.call(list: @list, adapter: @adapter)

            by_title = @list.list_items.reload.index_by { |item| item.metadata["title"] }
            emma = by_title.fetch("Emma")
            sapiens = by_title.fetch("Sapiens")
            assert_equal [1, 5], [emma.position, sapiens.position]
            assert_equal ["Sapiens", "A Brief History", ["Yuval Noah Harari"], 2011, "Books::Book"],
              [sapiens.metadata["title"], sapiens.metadata["subtitle"], sapiens.metadata["authors"], sapiens.metadata["year"], sapiens.listable_type]
            assert_equal({"bucket" => "pending", "reasons" => [], "settled" => false}, sapiens.metadata["wizard"])
            manager = @list.reload.wizard_manager
            assert_equal ["completed", 2], [manager.step_status("parse"), manager.step_metadata("parse")["total_items"]]
          end

          test "a re-parse replaces unsettled rows" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            parsed(row("Emma", ["Jane Austen"]))

            ParseRows.call(list: @list, adapter: @adapter)

            assert_not ::ListItem.exists?(old.id)
            assert_equal ["Emma"], @list.list_items.reload.map { |item| item.metadata["title"] }
          end

          test "a settled or removed row is kept, and a parsed row equal to it is not added again" do
            settled = wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"], wizard: {bucket: "matched", settled: true})
            removed = wizard_row(@list, position: 2, title: "Persuasion", authors: ["Jane Austen"], wizard: {bucket: "removed", settled: true})
            parsed(row(" emma ", ["JANE AUSTEN"]), row("Persuasion", ["Jane Austen"]), row("Mansfield Park", ["Jane Austen"]))

            assert_equal 1, ParseRows.call(list: @list, adapter: @adapter)

            titles = @list.list_items.reload.map { |item| item.metadata["title"] }
            assert_equal ["Emma", "Mansfield Park", "Persuasion"], titles.sort
            assert ::ListItem.exists?(settled.id)
            assert ::ListItem.exists?(removed.id)
          end

          test "a row from before the wizard is kept and not parsed again" do
            book = books_books(:war_and_peace)
            old = @list.list_items.create!(listable: book, position: 1)
            parsed(row("War and Peace", ["Leo Tolstoy"]), row("Emma", ["Jane Austen"]))

            ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            assert_equal 2, @list.list_items.reload.count
          end

          test "a failed re-parse deletes nothing and marks the step failed" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            @adapter.stubs(:parse).returns(::Services::Lists::Wizard::Books::Adapter::Result.new(success?: false, data: [], errors: ["rate limited"]))

            assert_nil ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            manager = @list.reload.wizard_manager
            assert_equal ["failed", "rate limited"], [manager.step_status("parse"), manager.step_error("parse")]
          end

          test "blank content fails without calling the parser" do
            @list.update_columns(raw_content: nil)
            @adapter.expects(:parse).never

            assert_nil ParseRows.call(list: @list, adapter: @adapter)
            assert_equal "failed", @list.reload.wizard_manager.step_status("parse")
          end

          test "batch mode parses 100 non-blank lines at a time and numbers rows sequentially, ignoring AI ranks" do
            lines = (1..150).map { |n| "Book #{n} by Author #{n}" }
            @list.update_columns(simplified_content: lines.each_slice(10).map { |slice| slice.join("\n") }.join("\n\n  \n"),
              wizard_state: {"batch_mode" => true})
            first = (1..100).map { |n| row("Book #{n}", ["Author #{n}"], rank: 1) }
            second = (101..150).map { |n| row("Book #{n}", ["Author #{n}"], rank: 1) }
            result = ->(rows) { ::Services::Lists::Wizard::Books::Adapter::Result.new(success?: true, data: rows, errors: []) }
            @adapter.expects(:parse).with(@list, content: lines.first(100).join("\n")).returns(result.call(first))
            @adapter.expects(:parse).with(@list, content: lines.last(50).join("\n")).returns(result.call(second))

            assert_equal 150, ParseRows.call(list: @list, adapter: @adapter)

            positions = @list.list_items.reload.to_h { |item| [item.metadata["title"], item.position] }
            assert_equal (1..150).to_a, positions.values.sort
            assert_equal [1, 100, 101, 150], positions.values_at("Book 1", "Book 100", "Book 101", "Book 150")
          end

          test "in batch mode a failed second batch deletes nothing and fails the step" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            @list.update_columns(simplified_content: (1..150).map { |n| "Book #{n}" }.join("\n"), wizard_state: {"batch_mode" => true})
            ok = ::Services::Lists::Wizard::Books::Adapter::Result.new(success?: true, data: [row("Book 1")], errors: [])
            bad = ::Services::Lists::Wizard::Books::Adapter::Result.new(success?: false, data: [], errors: ["rate limited"])
            @adapter.stubs(:parse).returns(ok).then.returns(bad)

            assert_nil ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            assert_equal 1, @list.list_items.reload.count
            manager = @list.reload.wizard_manager
            assert_equal "failed", manager.step_status("parse")
            assert_match(/batch 2/, manager.step_error("parse"))
          end

          test "null bytes are stripped before they reach jsonb" do
            parsed(row("Em\u0000ma", ["Jane\u0000 Austen"]))

            ParseRows.call(list: @list, adapter: @adapter)

            item = @list.list_items.reload.first
            assert_equal ["Emma", ["Jane Austen"]], [item.metadata["title"], item.metadata["authors"]]
          end
        end
      end
    end
  end
end
```

Generate the job, then replace `web-app/test/sidekiq/lists/wizard/parse_job_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::ParseJobTest < ActiveSupport::TestCase
  test "runs the parse for the list with its adapter" do
    list = lists(:books_list)
    ::Services::Lists::Wizard::Core::ParseRows.expects(:call)
      .with(has_entries(list: list, adapter: instance_of(::Services::Lists::Wizard::Books::Adapter))).returns(0)

    Lists::Wizard::ParseJob.new.perform(list.id)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails generate sidekiq:job lists/wizard/parse` then `bin/rails test test/lib/services/lists/wizard/core/parse_rows_test.rb test/sidekiq/lists/wizard/parse_job_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Lists::Wizard::Core::ParseRows`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/core/parse_rows.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §2 and §8: pasted content becomes pending rows.
        # A re-parse replaces unsettled rows and never re-adds a row whose
        # normalized title and creators equal a kept row's. Nothing is deleted
        # until the parser has succeeded.
        class ParseRows
          STEP = "parse"
          BATCH_SIZE = 100

          def self.call(list:, adapter:)
            new(list: list, adapter: adapter).call
          end

          def initialize(list:, adapter:)
            @list = list
            @adapter = adapter
          end

          def call
            manager.write_step!(step: STEP, status: "running", progress: 0, error: nil)
            return fail!("Paste the list before parsing.") if @list.raw_content.blank?

            rows = batch_mode? ? parse_in_batches : parse_once
            return if rows.nil?

            added = replace_rows(rows)
            manager.write_step!(step: STEP, status: "completed", progress: 100,
              metadata: {"total_items" => added, "processed_items" => added, "parsed_at" => Time.current.iso8601})
            added
          rescue => e
            fail!(e.message)
            raise
          end

          private

          def manager = @list.wizard_manager

          def batch_mode? = @list.wizard_state&.dig("batch_mode") == true

          def parse_once
            result = @adapter.parse(@list)
            return fail!(Array(result.errors).join(", ").presence || "Parsing failed") unless result.success?

            result.data
          end

          # As BaseWizardParseListJob#perform_batched_parse: batches of 100
          # non-blank lines, one parser call each, positions strictly in order.
          # A failed batch fails the whole parse before anything is deleted.
          def parse_in_batches
            lines = @list.simplified_content.to_s.split("\n").reject { |line| line.strip.empty? }
            batches = lines.each_slice(BATCH_SIZE).map { |slice| slice.join("\n") }
            rows = []
            batches.each_with_index do |content, index|
              result = @adapter.parse(@list, content: content)
              unless result.success?
                return fail!("Parsing failed on batch #{index + 1}: #{Array(result.errors).join(", ")}")
              end

              rows.concat(result.data)
              manager.write_step!(step: STEP, status: "running", progress: (index + 1) * 100 / batches.size,
                metadata: {"batches_completed" => index + 1, "total_batches" => batches.size, "processed_items" => rows.size})
            end
            @sequential = true
            rows
          end

          def fail!(message)
            manager.write_step!(step: STEP, status: "failed", progress: 0, error: message)
            nil
          end

          def replace_rows(rows)
            ::ActiveRecord::Base.transaction do
              ::ListItem.where(id: RowState.unsettled(@list).map(&:id)).destroy_all
              kept = @list.list_items.includes(listable: @adapter.listable_includes).map { |item| @adapter.row_signature(item) }.to_set

              now = Time.current
              inserts = []
              rows.each_with_index do |row, index|
                next if kept.include?(@adapter.signature(row["title"], row["authors"]))

                inserts << {
                  list_id: @list.id, listable_type: @adapter.listable_type, listable_id: nil, verified: false,
                  position: position_for(row, index), metadata: clean(row).merge(RowState::KEY => RowState::INITIAL),
                  created_at: now, updated_at: now
                }
              end
              ::ListItem.insert_all(inserts) if inserts.any?
              @list.touch
              inserts.size
            end
          end

          def position_for(row, index)
            return index + 1 if @sequential

            rank = row["rank"]
            (rank.is_a?(Integer) && rank.positive?) ? rank : index + 1
          end

          # jsonb cannot store a NUL byte.
          def clean(row)
            row.transform_values do |value|
              case value
              when String then value.delete("\u0000")
              when Array then value.map { |entry| entry.is_a?(String) ? entry.delete("\u0000") : entry }
              else value
              end
            end
          end
        end
      end
    end
  end
end
```

`web-app/app/sidekiq/lists/wizard/parse_job.rb`:

```ruby
# frozen_string_literal: true

class Lists::Wizard::ParseJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::List.find(list_id)
    ::Services::Lists::Wizard::Core::ParseRows.call(list: list, adapter: ::Services::Lists::Wizard::Core::Adapters.for(list))
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/wizard/core/parse_rows_test.rb test/sidekiq/lists/wizard/parse_job_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/core/parse_rows.rb app/sidekiq/lists/wizard/parse_job.rb test/lib/services/lists/wizard/core/parse_rows_test.rb test/sidekiq/lists/wizard/parse_job_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: parse pasted content into rows, keeping settled rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Match (fan-out, per-row job, completion)

**Files:**
- Create: `web-app/app/lib/services/lists/wizard/core/start_match.rb`, `match_row.rb`, `match_progress.rb`
- Create (generator): `bin/rails generate sidekiq:job lists/wizard/match` and `bin/rails generate sidekiq:job lists/wizard/match_row`
- Test: `web-app/test/lib/services/lists/wizard/core/start_match_test.rb`, `match_row_test.rb`, `match_progress_test.rb`, `web-app/test/sidekiq/lists/wizard/match_job_test.rb`, `match_row_job_test.rb`

**Interfaces:**
- Consumes: adapter `#finder`, `#query_for`, `#recheck_keys` (Task 6); `Outcome`, `OnListTwice`, `RowState` (Task 4); `write_step!` (Task 5).
- Produces:
  - `Services::Lists::Wizard::Core::StartMatch.call(list:) → Integer` (rows queued)
  - `Services::Lists::Wizard::Core::MatchRow.call(list_item:, adapter:, single_row: false)`
  - `Services::Lists::Wizard::Core::MatchProgress.call(list:, single_row: false)`
  - `Lists::Wizard::MatchJob#perform(list_id)`; `Lists::Wizard::MatchRowJob#perform(list_item_id, single_row = false)`

Decision: **how row jobs signal completion.** Each row job saves its row, then calls `MatchProgress`, which locks the list row, counts pending rows, and either writes progress (decided ÷ all non-removed rows) or, when none are pending and the step is not yet `completed`, runs `OnListTwice` and marks the step completed. The status check sits inside the lock, so the pass runs exactly once per bulk run. A single-row re-match (Review action 5, `single_row: true`) re-runs the pass after it finishes and never writes "running".
Decision: **a row job applies its answer only to a row still pending.** After the finder returns, the row is re-read; a row the admin settled (or restart deleted) meanwhile is left alone, and `MatchProgress` runs either way. `MatchProgress` counts rows in SQL (rows with a `wizard` key, removed excluded), instantiating nothing under the lock.
Decision: **a Match failure that raises** (anything but our own database) flags the row with a new reason, `match_failed`, plus the error text, so the step can still complete. The spec lists no reason for it.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/lists/wizard/core/match_row_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class MatchRowTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @list.wizard_manager.write_step!(step: "match", status: "running")
            @adapter = ::Services::Lists::Wizard::Books::Adapter.new
            @book = books_books(:war_and_peace)
            @row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"])
          end

          def answer(**attributes)
            finder = ListWizardHelper::FakeFinder.new(->(row) { wizard_match(subject: row, **attributes) })
            @adapter.stubs(:finder).returns(finder)
            finder
          end

          test "a confident match links the row, verifies it and records the decision" do
            finder = answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter)

            @row.reload
            state = RowState.new(@row)
            assert_equal [@book.id, true, "matched", @book.id, "identifier"],
              [@row.listable_id, @row.verified, state.bucket, state.target_record_id, state.decided_by]
            assert_equal ::MatchDecision.where(subject: @row).last.id, state.match_decision_id
            assert state.matched_at.present?
            assert_equal @row, finder.calls.first[:subject]
            assert_equal "War and Peace", finder.calls.first[:query].title
          end

          test "an AI match at high confidence passes through, remembered as AI-decided" do
            answer(outcome: :matched, record: @book, confidence: :high, decided_by: :ai, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_equal [@book.id, "matched", "ai"], [@row.reload.listable_id, RowState.new(@row).bucket, RowState.new(@row).decided_by]
          end

          test "an unsure match is flagged and left unlinked" do
            answer(outcome: :matched, record: @book, confidence: :medium, decided_by: :ai, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["unsure"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "a rule-5 create saves the work and the keys the re-check needs" do
            work = ol_candidate("OL9W")
            answer(outcome: :unmatched, confidence: :high, decided_by: :rule, external: work, candidates: [work])
            @adapter.stubs(:recheck_keys).returns(%w[OL9W OL8W])

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_equal ["create", "OL9W", %w[OL9W OL8W]], [state.bucket, state.ol_work_key, state.ol_keys]
          end

          test "a match on a book another row already holds is flagged on_list_twice, not linked" do
            wizard_row(@list, position: 2, title: "War and Peace (again)", listable: @book, wizard: {bucket: "matched", settled: true})
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_nil @row.listable_id
            assert_equal ["flagged", ["on_list_twice"], @book.id], [state.bucket, state.reasons, state.target_record_id]
          end

          test "a uniqueness clash at save time flags the row instead of crashing" do
            wizard_row(@list, position: 2, title: "War and Peace (again)", listable: @book, wizard: {bucket: "matched", settled: true})
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            # The other row linked the book after this job looked (two jobs at once).
            RowState.stubs(:holder_of).returns(nil)

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["on_list_twice"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "the unique index firing (two jobs at once, validation bypassed) also flags the row" do
            wizard_row(@list, position: 2, title: "War and Peace (again)", listable: @book, wizard: {bucket: "matched", settled: true})
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            RowState.stubs(:holder_of).returns(nil)
            # Skip the uniqueness validation so the save reaches the database index.
            ::ListItem.any_instance.stubs(:valid?).returns(true)

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["on_list_twice"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "a row the admin settled while its job was in flight is left alone, and progress still runs" do
            finder = ListWizardHelper::FakeFinder.new(->(row) {
              fresh = ::ListItem.find(row.id)
              RowState.new(fresh).merge("bucket" => "removed", "reasons" => []).settle(by: users(:admin_user))
              fresh.save!
              wizard_match(subject: row, outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            })
            @adapter.stubs(:finder).returns(finder)

            MatchRow.call(list_item: @row, adapter: @adapter)

            @row.reload
            assert_nil @row.listable_id
            assert_equal ["removed", true], [RowState.new(@row).bucket, RowState.new(@row).settled?]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "a finder error flags the row match_failed and the step can still finish" do
            finder = Object.new
            def finder.call(**) = raise(StandardError, "open library timed out")
            @adapter.stubs(:finder).returns(finder)

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_equal ["flagged", ["match_failed"], "open library timed out"], [state.bucket, state.reasons, state.error]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "a re-match replaces an earlier link" do
            @row.update!(listable: books_books(:crime_and_punishment), verified: true)
            answer(outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_not @row.verified?
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/match_progress_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class MatchProgressTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @list.wizard_manager.write_step!(step: "match", status: "running")
          end

          test "while rows are pending it writes progress as decided rows out of all rows" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            wizard_row(@list, position: 2, title: "B", wizard: {bucket: "flagged"})
            wizard_row(@list, position: 3, title: "C")
            wizard_row(@list, position: 4, title: "D")
            wizard_row(@list, position: 5, title: "E", wizard: {bucket: "removed", settled: true})
            @list.list_items.create!(listable: books_books(:got), position: 6) # from before the wizard: not counted
            OnListTwice.expects(:call).never

            MatchProgress.call(list: @list)

            manager = @list.reload.wizard_manager
            assert_equal ["running", 50, 2, 4], [manager.step_status("match"), manager.step_progress("match"),
              manager.step_metadata("match")["processed_items"], manager.step_metadata("match")["total_items"]]
          end

          test "the last row completes the step and runs the on-list-twice pass once" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            OnListTwice.expects(:call).with(list: @list).once

            MatchProgress.call(list: @list)
            MatchProgress.call(list: @list) # a second finisher in the same run

            assert_equal ["completed", 100], [@list.reload.wizard_manager.step_status("match"), @list.wizard_manager.step_progress("match")]
          end

          test "a single-row re-match after completion runs the pass again" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
            OnListTwice.expects(:call).once

            MatchProgress.call(list: @list, single_row: true)
          end

          test "a single-row re-match never flips the step back to running" do
            wizard_row(@list, position: 1, title: "A")
            wizard_row(@list, position: 2, title: "B")
            @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)

            MatchProgress.call(list: @list, single_row: true)

            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/start_match_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class StartMatchTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
          end

          test "queues one job per unsettled row after marking each pending and unlinked" do
            matched = wizard_row(@list, position: 1, title: "War and Peace", listable: books_books(:war_and_peace), verified: true,
              wizard: {bucket: "matched", target_record_id: books_books(:war_and_peace).id})
            flagged = wizard_row(@list, position: 2, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(matched.id)
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(flagged.id)

            assert_equal 2, StartMatch.call(list: @list)

            matched.reload
            assert_nil matched.listable_id
            assert_equal [["pending", []], ["pending", []]], [matched, flagged.reload].map { |row| RowState.new(row).data.values_at("bucket", "reasons") }
            assert_equal ["running", 2], [@list.reload.wizard_manager.step_status("match"), @list.wizard_manager.step_metadata("match")["total_items"]]
          end

          test "settled rows and rows from before the wizard are never queued" do
            settled = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched", settled: true})
            old = @list.list_items.create!(listable: books_books(:got), position: 2)
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).never

            assert_equal 0, StartMatch.call(list: @list)

            assert_equal "matched", RowState.new(settled.reload).bucket
            assert_equal books_books(:got).id, old.reload.listable_id
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "inline, the whole run ends with the step completed" do
            row = wizard_row(@list, position: 1, title: "Emma")
            adapter = ::Services::Lists::Wizard::Books::Adapter.new
            adapter.stubs(:finder).returns(ListWizardHelper::FakeFinder.new(->(subject) {
              wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])
            }))
            Adapters.stubs(:for).returns(adapter)

            StartMatch.call(list: @list)

            assert_equal ["flagged", ["not_found"]], [RowState.new(row.reload).bucket, RowState.new(row).reasons]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end
        end
      end
    end
  end
end
```

Replace the generated `web-app/test/sidekiq/lists/wizard/match_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::MatchJobTest < ActiveSupport::TestCase
  test "starts the match for the list" do
    list = lists(:books_list)
    ::Services::Lists::Wizard::Core::StartMatch.expects(:call).with(list: list).returns(0)

    Lists::Wizard::MatchJob.new.perform(list.id)
  end
end
```

Replace the generated `web-app/test/sidekiq/lists/wizard/match_row_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::MatchRowJobTest < ActiveSupport::TestCase
  include ListWizardHelper

  test "matches the row with its list's adapter, passing single_row through" do
    row = wizard_row(wizard_list, position: 1, title: "Emma")
    ::Services::Lists::Wizard::Core::MatchRow.expects(:call)
      .with(has_entries(list_item: row, single_row: true, adapter: instance_of(::Services::Lists::Wizard::Books::Adapter)))

    Lists::Wizard::MatchRowJob.new.perform(row.id, true)
  end

  test "a row deleted since it was queued (a restart) is skipped" do
    ::Services::Lists::Wizard::Core::MatchRow.expects(:call).never

    Lists::Wizard::MatchRowJob.new.perform(0)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails generate sidekiq:job lists/wizard/match && bin/rails generate sidekiq:job lists/wizard/match_row` then `bin/rails test test/lib/services/lists/wizard/core/start_match_test.rb test/lib/services/lists/wizard/core/match_row_test.rb test/lib/services/lists/wizard/core/match_progress_test.rb test/sidekiq/lists/wizard/`
Expected: FAIL — `NameError: uninitialized constant Services::Lists::Wizard::Core::MatchRow` (and `StartMatch`, `MatchProgress`).

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/core/start_match.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: one job per unsettled row. Every row is
        # marked pending before any job is queued, so the last job to finish
        # (inline in tests, or under Sidekiq) is the one that completes the step.
        class StartMatch
          STEP = "match"

          def self.call(list:)
            new(list).call
          end

          def initialize(list)
            @list = list
          end

          def call
            rows = RowState.unsettled(@list).sort_by { |item| [item.position || 0, item.id] }
            rows.each do |item|
              RowState.new(item).merge(RowState::PENDING)
              RowState.unlink(item)
              item.save!
            end
            @list.wizard_manager.write_step!(step: STEP, status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0})

            if rows.empty?
              MatchProgress.call(list: @list)
            else
              rows.each { |item| ::Lists::Wizard::MatchRowJob.perform_async(item.id) }
            end
            rows.size
          rescue => e
            @list.wizard_manager.write_step!(step: STEP, status: "failed", progress: 0, error: e.message)
            raise
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/core/match_row.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # One finder run for one row (books list wizard spec §3), with the row
        # as the decision's subject. A confident match links the row now; a
        # book another row holds is never linked twice (§4).
        class MatchRow
          def self.call(list_item:, adapter:, single_row: false)
            new(list_item, adapter, single_row).call
          end

          def initialize(item, adapter, single_row)
            @item = item
            @adapter = adapter
            @single_row = single_row
            @record = nil
          end

          def call
            attributes = begin
              decide
            rescue ::ActiveRecord::ActiveRecordError
              raise
            rescue => e
              {"bucket" => "flagged", "reasons" => ["match_failed"], "error" => e.message.to_s.truncate(500),
               "matched_at" => Time.current.iso8601}
            end
            list = @item.list
            # The finder can take seconds; the admin may have settled the row
            # (or restart deleted it) meanwhile. Apply only to a row still pending.
            fresh = ::ListItem.find_by(id: @item.id)
            if fresh && RowState.new(fresh).pending?
              @item = fresh
              save(attributes)
            end
            MatchProgress.call(list: list, single_row: @single_row)
          end

          private

          def decide
            match = @adapter.finder.call(query: @adapter.query_for(@item), subject: @item)
            outcome = Outcome.classify(match)
            @record = match.record if outcome.bucket == "matched"
            {
              "bucket" => outcome.bucket, "reasons" => outcome.reasons,
              "match_decision_id" => match.decision&.id, "decided_by" => match.decided_by&.to_s,
              "confidence" => match.confidence&.to_s, "ol_keys" => @adapter.recheck_keys(match),
              "ol_work_key" => outcome.external_key, "target_record_id" => outcome.target_record_id,
              "matched_at" => Time.current.iso8601, "error" => nil, "import_error" => nil
            }
          end

          def save(attributes)
            state = RowState.new(@item).merge(attributes)
            RowState.unlink(@item)
            if @record
              if RowState.holder_of(@item.list, @record, except: @item)
                state.merge("bucket" => "flagged", "reasons" => ["on_list_twice"])
              else
                @item.listable = @record
                @item.verified = true
              end
            end
            @item.save!
          rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid => e
            raise if @item.listable_id.nil?
            raise if e.is_a?(::ActiveRecord::RecordInvalid) && !@item.errors.include?(:listable_id)

            RowState.unlink(@item)
            RowState.new(@item).merge("bucket" => "flagged", "reasons" => ["on_list_twice"])
            @item.save!
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/core/match_progress.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Called by every row job after it saves its row. Under the list's row
        # lock: write progress, or, once no row is pending and the step is not
        # yet completed, run the on-list-twice pass and complete the step. The
        # status check is inside the lock, so the pass runs once per bulk run.
        class MatchProgress
          STEP = "match"

          def self.call(list:, single_row: false)
            new(list, single_row).call
          end

          def initialize(list, single_row)
            @list = list
            @single_row = single_row
          end

          def call
            @list.with_lock do
              # Counted in SQL: no row is instantiated while the list is locked.
              # Rows with no wizard key (from before the wizard) are not counted.
              scope = @list.list_items
                .where("list_items.metadata->'wizard' IS NOT NULL")
                .where("COALESCE(list_items.metadata->'wizard'->>'bucket', '') <> 'removed'")
              total = scope.count
              pending = scope.where("list_items.metadata->'wizard'->>'bucket' = 'pending'").count
              manager = @list.wizard_manager

              if pending.zero?
                if manager.step_status(STEP) != "completed"
                  OnListTwice.call(list: @list)
                  manager.update_step_status!(step: STEP, status: "completed", progress: 100,
                    metadata: {"total_items" => total, "processed_items" => total, "completed_at" => Time.current.iso8601})
                elsif @single_row
                  OnListTwice.call(list: @list)
                end
              elsif !@single_row
                decided = total - pending
                manager.update_step_status!(step: STEP, status: "running", progress: decided * 100 / total,
                  metadata: {"total_items" => total, "processed_items" => decided})
              end
            end
          end
        end
      end
    end
  end
end
```

`web-app/app/sidekiq/lists/wizard/match_job.rb`:

```ruby
# frozen_string_literal: true

class Lists::Wizard::MatchJob
  include Sidekiq::Job

  def perform(list_id)
    ::Services::Lists::Wizard::Core::StartMatch.call(list: ::List.find(list_id))
  end
end
```

`web-app/app/sidekiq/lists/wizard/match_row_job.rb`:

```ruby
# frozen_string_literal: true

class Lists::Wizard::MatchRowJob
  include Sidekiq::Job

  def perform(list_item_id, single_row = false)
    item = ::ListItem.find_by(id: list_item_id)
    return if item.nil?

    ::Services::Lists::Wizard::Core::MatchRow.call(
      list_item: item, adapter: ::Services::Lists::Wizard::Core::Adapters.for(item.list), single_row: single_row
    )
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/wizard/core/ test/sidekiq/lists/wizard/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/core/start_match.rb app/lib/services/lists/wizard/core/match_row.rb app/lib/services/lists/wizard/core/match_progress.rb app/sidekiq/lists/wizard/match_job.rb app/sidekiq/lists/wizard/match_row_job.rb test/lib/services/lists/wizard/core/start_match_test.rb test/lib/services/lists/wizard/core/match_row_test.rb test/lib/services/lists/wizard/core/match_progress_test.rb test/sidekiq/lists/wizard/match_job_test.rb test/sidekiq/lists/wizard/match_row_job_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: match each row in its own job and complete once

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Import (trusted work key, re-check, serial creation, duplicate authors)

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/providers/open_library.rb`
- Modify: `web-app/app/lib/data_importers/books/book/importer.rb` (`trust_work_key:`)
- Modify: `web-app/app/lib/services/lists/wizard/books/adapter.rb` (`#recheck`, `#create`)
- Create: `web-app/app/lib/services/lists/wizard/core/import_rows.rb`
- Create (generator): `bin/rails generate sidekiq:job lists/wizard/import`
- Test: `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb`, `web-app/test/lib/data_importers/books/book/importer_test.rb`, `web-app/test/lib/services/lists/wizard/books/adapter_test.rb`, create `web-app/test/lib/services/lists/wizard/core/import_rows_test.rb`, `web-app/test/sidekiq/lists/wizard/import_job_test.rb`

**Interfaces:**
- Consumes: Task 1 (`Importer.call(subtitle:)`), Tasks 4–6.
- Produces:
  - `DataImporters::Books::Book::Providers::OpenLibrary.new(client: nil, new_author_ids: [], provisional: false, trust_work_key: false)`
  - `DataImporters::Books::Book::Importer.call(…, trust_work_key: false)` / `.new(…, trust_work_key: false)`
  - `Books::Adapter#recheck(list_item) → Books::Book|nil`; `#create(list_item, importer: DataImporters::Books::Book::Importer) → Books::Book` (raises `Books::Adapter::CreateFailed`); `Adapter::TEXT_PROVIDERS`
  - `Services::Lists::Wizard::Core::ImportRows.call(list:, adapter:, run_id: nil) → Integer|nil` (create rows processed; nil when another run owns the running step); `Lists::Wizard::ImportJob#perform(list_id, run_id = nil)`

Decision: **how the importer stamps an admin-chosen Open Library key.** The importer gains `trust_work_key:` and passes it to the Open Library provider. With it set, the provider uses the query's `open_library_work_key` instead of the service's decision: if that work is among the `/resolve` candidates its fills, key and author keys are applied as for an accept; if not, only the key is stamped and the Authors provider links authors by name. Without it, behaviour is unchanged. Stamping the key after the fact was rejected: when the re-resolve accepts a different work, the book would carry two keys and that other work's authors.
Decision: **a row created from its own text skips the Open Library provider** (`providers: %i[authors ai_enrichment author_enrichment]`): the admin said "no Open Library work", so a re-resolve must not attach one.
Decision: **the rebuilt match never carries the finder's resolution** (as in `SettleEdition#match_from_decision`), so each created row costs one more `/resolve` call; the finder itself does not run again.
Decision: **creation runs in `transaction(requires_new: true)` and a new book with no author is rolled back** (`CreateFailed`), as `CreateBook` does; the row is flagged `import_failed`.
Decision: **Import runs never overlap.** The controller writes a `run_id` into the import step when it starts the job and passes it along; `ImportRows` claims the step under the list's row lock and gives up when the step is running under another run id. Each row is re-read before it is imported and skipped once no longer a `create` row.
Decision: **the text-row re-check compares in Ruby** with `Core::Signature.normalize` (title and author names, alternate names included); SQL only narrows to books created since the row's Match that have an author. SQL `LOWER()` cannot match the wizard's normalization (curly quotes, Unicode width).
Decision: **a trusted work key survives a failed `/resolve`**: the provider then stamps only the key.
Decision: **removed rows are deleted when Import finishes** (controller ruling); a re-parse after Import may therefore re-add a row that was removed. Task 16's docs say so.
Decision: **restart against rows already imported:** Import marks every row it created or linked as settled, so restart keeps them; after Import the row's bucket becomes `matched` with `import_result` set.

- [ ] **Step 1: Write the failing tests**

Add to `test/lib/data_importers/books/book/providers/open_library_test.rb`:

```ruby
          test "a trusted work key wins over the service's accept: that candidate's facts and key are applied" do
            provider = Providers::OpenLibrary.new(client: @client, trust_work_key: true)
            body = resolve_response(verdict: "accept", key: "OL1W")
            body["data"]["candidates"] << candidate_hash(key: "OL2W", verdict: "reject",
              diff: [diff_entry(field: "first_published_year", ours: nil, theirs: 1951, kind: "fill")])
            stub_resolve(body)
            book = ::Books::Book.new(title: "The Chosen")
            query = DataImporters::Books::Book::ImportQuery.new(title: "The Chosen", open_library_work_key: "OL2W")

            result = provider.populate(book, query: query)

            assert result.success?
            assert_equal ["OL2W"], book.identifiers.select { |i| i.identifier_type == "books_work_openlibrary_id" }.map(&:value)
            assert_equal 1951, book.first_published_year
          end

          test "a trusted work key the service did not return is still stamped" do
            provider = Providers::OpenLibrary.new(client: @client, trust_work_key: true)
            stub_resolve(resolve_response(verdict: "abstain"))
            book = ::Books::Book.new(title: "The Chosen")

            result = provider.populate(book, query: DataImporters::Books::Book::ImportQuery.new(title: "The Chosen", open_library_work_key: "OL7W"))

            assert result.success?
            assert_equal ["OL7W"], book.identifiers.select { |i| i.identifier_type == "books_work_openlibrary_id" }.map(&:value)
          end

          test "a trusted work key is stamped even when /resolve fails" do
            provider = Providers::OpenLibrary.new(client: @client, trust_work_key: true)
            stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "{}")
            book = ::Books::Book.new(title: "The Chosen")

            result = provider.populate(book, query: DataImporters::Books::Book::ImportQuery.new(title: "The Chosen", open_library_work_key: "OL7W"))

            assert result.success?
            assert_equal ["OL7W"], book.identifiers.select { |i| i.identifier_type == "books_work_openlibrary_id" }.map(&:value)
          end

          test "without trust, a /resolve failure is still a failure" do
            stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "{}")
            book = ::Books::Book.new(title: "The Chosen")

            result = @provider.populate(book, query: DataImporters::Books::Book::ImportQuery.new(title: "The Chosen", open_library_work_key: "OL7W"))

            assert_not result.success?
            assert_empty book.identifiers.select { |i| i.identifier_type == "books_work_openlibrary_id" }
          end

          test "without trust, the query's work key does not override the service's accept" do
            body = resolve_response(verdict: "accept", key: "OL1W")
            body["data"]["candidates"] << candidate_hash(key: "OL2W", verdict: "reject", diff: [])
            stub_resolve(body)
            book = ::Books::Book.new(title: "The Chosen")

            @provider.populate(book, query: DataImporters::Books::Book::ImportQuery.new(title: "The Chosen", open_library_work_key: "OL2W"))

            assert_equal ["OL1W"], book.identifiers.select { |i| i.identifier_type == "books_work_openlibrary_id" }.map(&:value)
          end
```

Add to `test/lib/data_importers/books/book/importer_test.rb`:

```ruby
        test "trust_work_key reaches the provider: the chosen key lands on the new book, not the service's" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: []).to_json)
          match = DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule, candidates: [])

          result = Importer.call(title: "The Chosen", author_names: ["Chaim Potok"], open_library_work_key: "OL5W",
            match: match, trust_work_key: true)

          assert result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL5W")
          assert_not result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL468431W")
        end
```

Add to `test/lib/services/lists/wizard/books/adapter_test.rb`:

```ruby
          test "recheck finds a book holding the chosen work or any key saved at Match" do
            held = books_books(:crime_and_punishment) # holds OL262758W (fixture)
            chosen = wizard_row(@list, position: 1, title: "Crime and Punishment", wizard: {bucket: "create", ol_work_key: "OL262758W"})
            saved = wizard_row(@list, position: 2, title: "Crime and Punishment", wizard: {bucket: "create", ol_work_key: "OL1W", ol_keys: ["OL1W", "OL262758W"]})
            missing = wizard_row(@list, position: 3, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL2W", ol_keys: ["OL2W"]})

            assert_equal held, @adapter.recheck(chosen)
            assert_equal held, @adapter.recheck(saved)
            assert_nil @adapter.recheck(missing)
          end

          test "recheck for a text row finds a book with the same title and an agreeing author created after its match" do
            row = wizard_row(@list, position: 1, title: "A Winter of Crows", authors: ["Wren Halloway"],
              wizard: {bucket: "create", matched_at: 1.hour.ago.iso8601})
            author = ::Books::Author.create!(name: "Wren Halloway")
            book = ::Books::Book.create!(title: "A Winter of Crows")
            book.book_authors.create!(author: author, position: 1)

            assert_equal book, @adapter.recheck(row)
          end

          test "recheck for a text row ignores a book made before its match, or by someone else" do
            row = wizard_row(@list, position: 1, title: "A Winter of Crows", authors: ["Wren Halloway"],
              wizard: {bucket: "create", matched_at: 1.hour.from_now.iso8601})
            author = ::Books::Author.create!(name: "Wren Halloway")
            ::Books::Book.create!(title: "A Winter of Crows").book_authors.create!(author: author, position: 1)
            later = wizard_row(@list, position: 2, title: "A Winter of Crows", authors: ["Somebody Else"],
              wizard: {bucket: "create", matched_at: 1.hour.ago.iso8601})

            assert_nil @adapter.recheck(row)
            assert_nil @adapter.recheck(later)
          end

          test "create sends a chosen work, trusted, as a normal enriched book with the rebuilt match" do
            book = books_books(:war_and_peace)
            row = wizard_row(@list, position: 1, title: "War and Peace", subtitle: "A Novel", authors: ["Leo Tolstoy"], year: 1869)
            decision = wizard_match(subject: row, outcome: :unmatched, candidates: [local_candidate(books_books(:got))]).decision
            row.update!(metadata: row.metadata.deep_merge("wizard" => {"bucket" => "create", "ol_work_key" => "OL5W", "match_decision_id" => decision.id}))
            importer = mock("importer")
            importer.expects(:call).with { |**kw|
              kw.values_at(:title, :subtitle, :author_names, :year, :open_library_work_key, :trust_work_key, :provisional, :enrich, :subject) ==
                ["War and Peace", "A Novel", ["Leo Tolstoy"], 1869, "OL5W", true, false, true, row] &&
                kw[:match].decision == decision && kw[:match].candidates.map(&:record) == [books_books(:got)] && !kw.key?(:providers)
            }.returns(::DataImporters::ImportResult.new(item: book, provider_results: [], success: true, created: true))

            assert_equal book, @adapter.create(row, importer: importer)
          end

          test "create for a text row skips the Open Library provider" do
            row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"], wizard: {bucket: "create"})
            importer = mock("importer")
            importer.expects(:call).with { |**kw| kw[:providers] == Adapter::TEXT_PROVIDERS && !kw.key?(:open_library_work_key) }
              .returns(::DataImporters::ImportResult.new(item: books_books(:war_and_peace), provider_results: [], success: true, created: true))

            @adapter.create(row, importer: importer)
          end

          test "create raises when nothing was created, and rolls back a book left with no author" do
            row = wizard_row(@list, position: 1, title: "Nobody's Book", wizard: {bucket: "create"})
            failed = mock("importer")
            failed.stubs(:call).returns(::DataImporters::ImportResult.new(item: ::Books::Book.new(title: "x"), provider_results: [], success: false))
            authorless = Object.new
            def authorless.call(**)
              ::DataImporters::ImportResult.new(item: ::Books::Book.create!(title: "Nobody's Book"), provider_results: [], success: true, created: true)
            end

            assert_raises(Adapter::CreateFailed) { @adapter.create(row, importer: failed) }
            assert_raises(Adapter::CreateFailed) { @adapter.create(row, importer: authorless) }
            assert_not ::Books::Book.exists?(title: "Nobody's Book")
          end
```


`web-app/test/lib/services/lists/wizard/core/import_rows_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class ImportRowsTest < ActiveSupport::TestCase
          include ListWizardHelper
          include GoodreadsImportHelper

          SOURCE_VERSION = {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                            "pipeline_version" => 1, "matcher_version" => 2}.freeze

          setup do
            @list = wizard_list
            @adapter = ::Services::Lists::Wizard::Books::Adapter.new
          end

          def create_row(position, title, authors: ["Wren Halloway"], work: nil)
            row = wizard_row(@list, position: position, title: title, authors: authors,
              wizard: {bucket: "create", ol_work_key: work, ol_keys: Array(work), matched_at: Time.current.iso8601})
            decision = wizard_match(subject: row, outcome: :unmatched, confidence: :high, decided_by: :rule).decision
            RowState.new(row).merge("match_decision_id" => decision.id)
            row.save!
            row
          end

          def work_record(key, title)
            {"key" => {"source" => "openlibrary", "key" => key}, "redirected_from" => [], "title" => title, "subtitle" => nil,
             "description" => nil, "subjects" => [], "year_evidence" => nil, "popularity" => nil,
             "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL900A"}, "name" => "Wren Halloway"}]}
          end

          def stub_works
            candidates = [["OL901W", "The Salt Ledger"], ["OL902W", "A Winter of Crows"]].map do |key, title|
              {"key" => {"source" => "openlibrary", "key" => key}, "score" => 0.8, "rules" => ["title_author"], "margin" => 0.1,
               "verdict" => "abstain", "evidence" => {}, "conflicts" => [], "diff" => [], "record" => work_record(key, title)}
            end
            body = {"source_version" => SOURCE_VERSION, "data" => {
              "decision" => {"verdict" => "abstain", "key" => nil, "score" => 0.0, "margin" => 0.0, "reason" => "test"},
              "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => candidates
            }}
            stub_request(:post, "#{OPEN_LIBRARY_URL}/resolve").to_return(status: 200, body: body.to_json)
            author = {"source_version" => SOURCE_VERSION, "data" => {"key" => {"source" => "openlibrary", "key" => "OL900A"},
              "redirected_from" => [], "name" => "Wren Halloway", "alternate_names" => [], "birth_year" => nil, "death_year" => nil}}
            stub_request(:get, "#{OPEN_LIBRARY_URL}/authors/OL900A").to_return(status: 200, body: author.to_json)
          end

          test "a create row is created, linked, verified and settled, and Import completes" do
            book = books_books(:war_and_peace)
            row = create_row(1, "War and Peace", work: "OL5W")
            @adapter.stubs(:recheck).returns(nil)
            @adapter.expects(:create).with(row).returns(book)

            assert_equal 1, ImportRows.call(list: @list, adapter: @adapter)

            state = RowState.new(row.reload)
            assert_equal [book.id, true, "matched", "created", true], [row.listable_id, row.verified, state.bucket, state.import_result, state.settled?]
            assert_equal "completed", @list.reload.wizard_manager.step_status("import")
          end

          test "a book found by the re-check is linked and marked changed_since_match, not created and not flagged" do
            book = books_books(:crime_and_punishment)
            row = create_row(1, "Crime and Punishment", work: "OL262758W")
            @adapter.expects(:create).never

            ImportRows.call(list: @list, adapter: @adapter)

            state = RowState.new(row.reload)
            assert_equal [book.id, "matched", "linked_existing", ["changed_since_match"]],
              [row.listable_id, state.bucket, state.import_result, state.reasons]
          end

          test "a failing row is flagged import_failed with the error and the next row still imports" do
            bad = create_row(1, "Bad Row")
            good = create_row(2, "Good Row")
            @adapter.stubs(:recheck).returns(nil)
            @adapter.stubs(:create).with(bad).raises(StandardError, "open library exploded")
            @adapter.stubs(:create).with(good).returns(books_books(:got))

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal ["flagged", ["import_failed"], "open library exploded"],
              RowState.new(bad.reload).data.values_at("bucket", "reasons", "import_error")
            assert_equal books_books(:got).id, good.reload.listable_id
            assert_equal 1, @list.reload.wizard_manager.step_metadata("import")["failed_count"]
          end

          test "a found book another row already holds flags the row on_list_twice" do
            book = books_books(:crime_and_punishment)
            wizard_row(@list, position: 9, title: "Crime and Punishment", listable: book, wizard: {bucket: "matched", settled: true})
            row = create_row(1, "Crime and Punishment", work: "OL262758W")

            ImportRows.call(list: @list, adapter: @adapter)

            assert_nil row.reload.listable_id
            assert_equal ["flagged", ["on_list_twice"]], RowState.new(row).data.values_at("bucket", "reasons")
          end

          test "removed rows are deleted when Import finishes; other rows stay" do
            removed = wizard_row(@list, position: 1, title: "Made Up", wizard: {bucket: "removed", settled: true})
            flagged = wizard_row(@list, position: 2, title: "Unsure", wizard: {bucket: "flagged", reasons: ["unsure"]})

            ImportRows.call(list: @list, adapter: @adapter)

            assert_not ::ListItem.exists?(removed.id)
            assert ::ListItem.exists?(flagged.id)
          end

          test "a second import run creates nothing for rows it already created" do
            row = create_row(1, "War and Peace", work: "OL5W")
            @adapter.stubs(:recheck).returns(nil)
            @adapter.expects(:create).once.returns(books_books(:war_and_peace))

            ImportRows.call(list: @list, adapter: @adapter)
            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal books_books(:war_and_peace).id, row.reload.listable_id
          end

          test "a second start is refused while another run owns the step" do
            row = create_row(1, "War and Peace", work: "OL5W")
            @list.wizard_manager.write_step!(step: "import", status: "running", metadata: {"run_id" => "other-run"})
            @adapter.expects(:create).never

            assert_nil ImportRows.call(list: @list, adapter: @adapter, run_id: "late-run")

            assert_nil row.reload.listable_id
            assert_equal "other-run", @list.reload.wizard_manager.step_metadata("import")["run_id"]
          end

          test "the run that was started is the one that runs" do
            create_row(1, "War and Peace", work: "OL5W")
            @list.wizard_manager.write_step!(step: "import", status: "running", metadata: {"run_id" => "run-1"})
            @adapter.stubs(:recheck).returns(nil)
            @adapter.expects(:create).once.returns(books_books(:war_and_peace))

            assert_equal 1, ImportRows.call(list: @list, adapter: @adapter, run_id: "run-1")
          end

          test "a row another run created after this run listed it is skipped" do
            first = create_row(1, "War and Peace", work: "OL5W")
            second = create_row(2, "A Game of Thrones", work: "OL6W")
            got = books_books(:got)
            created = []
            @adapter.stubs(:recheck).returns(nil)
            @adapter.define_singleton_method(:create) do |item, **|
              created << item.id
              # Meanwhile a concurrent run imports the second row.
              other = ::ListItem.find(second.id)
              ::Services::Lists::Wizard::Core::RowState.new(other).merge("bucket" => "matched", "import_result" => "created", "settled" => true)
              other.update!(listable: got, verified: true)
              ::Books::Book.find_by!(title: "War and Peace")
            end

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal [first.id], created
            assert_equal got.id, second.reload.listable_id
          end

          test "a text row whose title differs only in its apostrophe finds the book the first row made" do
            stub_resolution_services
            curly = create_row(1, "The Hitchhiker’s Guide", authors: ["Douglas Adams"])
            straight = create_row(2, "The Hitchhiker's Guide", authors: ["Douglas Adams"])

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal 1, ::Books::Book.where(title: ["The Hitchhiker’s Guide", "The Hitchhiker's Guide"]).count
            assert curly.reload.listable_id.present?
            assert_equal ["flagged", ["on_list_twice"]], RowState.new(straight.reload).data.values_at("bucket", "reasons")
          end

          test "an admin-chosen work the service did not accept still lands on the new book" do
            stub_resolution_services # /resolve abstains with no candidates
            row = create_row(1, "The Chosen", authors: ["Chaim Potok"], work: "OL55W")

            ImportRows.call(list: @list, adapter: @adapter)

            book = row.reload.listable
            assert book.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL55W")
            assert_not book.provisional?
          end

          test "two books by an author we do not hold create exactly one author" do
            stub_resolution_services
            stub_works
            first = create_row(1, "The Salt Ledger", work: "OL901W")
            second = create_row(2, "A Winter of Crows", work: "OL902W")

            ImportRows.call(list: @list, adapter: @adapter)

            authors = ::Books::Author.where(name: "Wren Halloway")
            assert_equal 1, authors.count
            assert_equal [[authors.first], [authors.first]], [first.reload.listable.authors.to_a, second.reload.listable.authors.to_a]
          end

          test "the same when one book comes from Open Library and one from the row's text" do
            stub_resolution_services
            stub_works
            from_work = create_row(1, "The Salt Ledger", work: "OL901W")
            from_text = create_row(2, "A Winter of Crows")

            ImportRows.call(list: @list, adapter: @adapter)

            authors = ::Books::Author.where(name: "Wren Halloway")
            assert_equal 1, authors.count
            assert_equal [[authors.first], [authors.first]], [from_work.reload.listable.authors.to_a, from_text.reload.listable.authors.to_a]
          end

          test "and when both come from the rows' text" do
            stub_resolution_services
            create_row(1, "The Salt Ledger")
            create_row(2, "A Winter of Crows")

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal 1, ::Books::Author.where(name: "Wren Halloway").count
          end
        end
      end
    end
  end
end
```

Replace the generated `web-app/test/sidekiq/lists/wizard/import_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::ImportJobTest < ActiveSupport::TestCase
  test "runs the import for the list with its adapter and the run id it was started with" do
    list = lists(:books_list)
    ::Services::Lists::Wizard::Core::ImportRows.expects(:call)
      .with(has_entries(list: list, run_id: "run-1", adapter: instance_of(::Services::Lists::Wizard::Books::Adapter))).returns(0)

    Lists::Wizard::ImportJob.new.perform(list.id, "run-1")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails generate sidekiq:job lists/wizard/import` then `bin/rails test test/lib/data_importers/books/book/providers/open_library_test.rb test/lib/data_importers/books/book/importer_test.rb test/lib/services/lists/wizard/books/adapter_test.rb test/lib/services/lists/wizard/core/import_rows_test.rb test/sidekiq/lists/wizard/import_job_test.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :trust_work_key`, `NoMethodError: recheck`/`create`, `NameError: ImportRows`.

- [ ] **Step 3: Implement**

In `providers/open_library.rb`:

```ruby
          def initialize(client: nil, new_author_ids: [], provisional: false, trust_work_key: false)
            @client = client
            @new_author_ids = new_author_ids
            @provisional = provisional
            @trust_work_key = trust_work_key
          end
```

```ruby
          def populate(book, query: nil, match: nil)
            trusted_key = trusted_work_key(query)
            resolution = begin
              reusable_resolution(book, match) || client.resolve(**resolve_args(book, query))
            rescue => e
              # A person chose this work; an unreachable service must not lose
              # it. Without a trusted key the error is reported as before.
              raise e unless trusted_key

              nil
            end

            if trusted_key
              apply_trusted(book, resolution, query, trusted_key)
            elsif resolution.accept?
              apply_accept(book, resolution, query)
            elsif resolution.abstain?
              failure_result(errors: ["Open Library abstained: #{resolution.decision.reason}"])
            else
              failure_result(errors: ["Open Library rejected: #{resolution.decision.reason}"])
            end
          rescue => e
            failure_result(errors: ["Open Library #{e.class.name.demodulize}: #{e.message}"])
          end
```

Replace `apply_accept` with these three private methods (the body of `apply_candidate` is the old `apply_accept` from `filled = apply_fills(...)` down):

```ruby
          # A person confirmed this work (the list wizard's Review, books list
          # wizard spec §6), so it wins over the service's own choice. Applied
          # like an accept when /resolve returned it; otherwise only its key is
          # stamped and the Authors provider links authors by name.
          def trusted_work_key(query)
            @trust_work_key ? query&.open_library_work_key : nil
          end

          def apply_trusted(book, resolution, query, key)
            candidate = resolution&.candidates&.find { |entry| entry.work_key == key }
            return apply_candidate(book, candidate, query) if candidate
            return failure_result(errors: ["Open Library work #{key} was chosen but the book has no title"]) if book.title.blank?

            book.identifiers.find_or_initialize_by(identifier_type: :books_work_openlibrary_id, value: key)
            persist_query_identifiers(book, query)
            success_result(data_populated: ["open_library_work_key"])
          end

          # The service guarantees an accept decision names a candidate with
          # that key, but this is defensive rather than trusted blindly.
          def apply_accept(book, resolution, query)
            candidate = resolution.accepted
            return failure_result(errors: ["Open Library accepted with no matching candidate"]) unless candidate

            apply_candidate(book, candidate, query)
          end

          def apply_candidate(book, candidate, query)
            filled = apply_fills(book, candidate)

            # R113: ImporterBase#run_providers_with_saving skips save! when
            # item.valid? is false but still keeps this provider's success --
            # so an identifier-only import whose title diff was "absent"
            # (never filled) would otherwise report success with nothing
            # persisted. Bail before any identifier gets stamped on a book
            # that cannot be saved.
            if book.title.blank?
              return failure_result(errors: ["Open Library accepted #{candidate.work_key} but the book still has no title"])
            end

            data_populated = filled + report_skipped(candidate)

            book.identifiers.find_or_initialize_by(
              identifier_type: :books_work_openlibrary_id,
              value: candidate.work_key
            )

            persist_query_identifiers(book, query)

            data_populated << "authors" if link_open_library_authors(book, candidate)

            success_result(data_populated: data_populated)
          end
```

In `importer.rb`: add `trust_work_key: false` to `self.call`'s keywords (after `enrich: true`) and to `new(...)`; then:

```ruby
        def initialize(provisional: false, stamp_identifiers: false, enrich: true, trust_work_key: false)
          @provisional = provisional
          @stamp_identifiers = stamp_identifiers
          @enrich = enrich
          @trust_work_key = trust_work_key
        end
```

```ruby
              Providers::OpenLibrary.new(new_author_ids: new_author_ids, provisional: @provisional, trust_work_key: @trust_work_key),
```

with `self.call` creating `new(provisional: provisional, stamp_identifiers: stamp_identifiers, enrich: enrich, trust_work_key: trust_work_key)`. Extend the `initialize` comment with one line: "trust_work_key: the query's Open Library work key wins over the service's decision (a person confirmed it; the list wizard)."

In `adapter.rb`, add the constants and public methods (`year_of` already exists):

```ruby
          # A row created from its own text has no Open Library work: the
          # Open Library provider is left out, so a re-resolve cannot attach one.
          TEXT_PROVIDERS = %i[authors ai_enrichment author_enrichment].freeze
          CreateFailed = Class.new(StandardError)

          # Spec §6: the Import re-check. A chosen work: a book holding it or any
          # key saved at Match. A text row: a book with the same normalized title
          # and an agreeing author, created after the row's Match.
          def recheck(item)
            state = ::Services::Lists::Wizard::Core::RowState.new(item)
            return book_holding(([state.ol_work_key] + state.ol_keys).compact_blank.uniq) if state.ol_work_key

            book_created_from_text_since_match(item, state)
          end

          # A normal book (provisional: false, enrich: true) with the row as the
          # subject and the match rebuilt from the row's decision, so the finder
          # does not run again. Rolled back when it ends up with no author.
          def create(item, importer: ::DataImporters::Books::Book::Importer)
            state = ::Services::Lists::Wizard::Core::RowState.new(item)
            metadata = item.metadata || {}
            arguments = {
              title: metadata["title"], subtitle: metadata["subtitle"], author_names: Array(metadata["authors"]),
              year: year_of(metadata), subject: item, provisional: false, enrich: true,
              match: match_from_decision(::MatchDecision.find_by(id: state.match_decision_id))
            }
            arguments = if state.ol_work_key
              arguments.merge(open_library_work_key: state.ol_work_key, trust_work_key: true)
            else
              arguments.merge(providers: TEXT_PROVIDERS)
            end

            ::ActiveRecord::Base.transaction(requires_new: true) do
              result = importer.call(**arguments)
              book = result.item
              raise CreateFailed, "no book created: #{result.all_errors.join("; ")}" unless result.created? && book&.persisted?
              raise CreateFailed, "the new book got no author: #{result.all_errors.join("; ")}" unless ::Books::BookAuthor.exists?(book: book)

              book
            end
          end
```

and private helpers:

```ruby
          def book_holding(keys)
            return nil if keys.empty?

            ::Books::Book.joins(:identifiers)
              .where(identifiers: {identifier_type: ::Identifier.identifier_types[:books_work_openlibrary_id], value: keys})
              .order(:id).first
          end

          def book_created_from_text_since_match(item, state)
            metadata = item.metadata || {}
            title = ::Services::Lists::Wizard::Core::Signature.normalize(metadata["title"])
            names = Array(metadata["authors"]).map { |name| ::Services::Lists::Wizard::Core::Signature.normalize(name) }.compact_blank
            return nil if title.blank? || names.empty?

            # SQL narrows to books created since the row's Match that have an
            # author (a handful during one run); the comparison is in Ruby with
            # the wizard's own normalization, which SQL LOWER() cannot match
            # (curly quotes, Unicode width, spacing).
            ::Books::Book
              .where("books_books.created_at > ?", state.matched_at || item.created_at)
              .where(id: ::Books::BookAuthor.select(:book_id))
              .includes(:authors).order(:id)
              .find do |book|
                ::Services::Lists::Wizard::Core::Signature.normalize(book.title) == title &&
                  book.authors.flat_map { |author| [author.name, *Array(author.alternate_names)] }
                    .map { |name| ::Services::Lists::Wizard::Core::Signature.normalize(name) }.intersect?(names)
              end
          end

          # As Services::Books::GoodreadsImports::SettleEdition#match_from_decision:
          # the books the finder considered, and its decision.
          def match_from_decision(decision)
            considered = Array(decision&.candidates).filter_map do |snapshot|
              next unless snapshot["record_type"] == "Books::Book"

              book = ::Books::Book.find_by(id: snapshot["record_id"])
              ::DataImporters::Candidate.new(record: book) if book
            end
            ::DataImporters::Match.new(
              outcome: :unmatched, record: nil, confidence: decision&.confidence&.to_sym,
              decided_by: decision&.decided_by&.to_sym, reason: decision&.reason, candidates: considered, decision: decision
            )
          end
```

`web-app/app/lib/services/lists/wizard/core/import_rows.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §6: one run per list, creating rows one after
        # another so a second book by a new author finds the author the first
        # one made. A failing row is flagged and the run goes on. Removed rows
        # are deleted at the end.
        class ImportRows
          STEP = "import"

          def self.call(list:, adapter:, run_id: nil)
            new(list, adapter, run_id).call
          end

          def initialize(list, adapter, run_id)
            @list = list
            @adapter = adapter
            @run_id = run_id
            @failed = 0
          end

          # nil when another run owns the step (it is running under a different
          # run_id): two Import runs never overlap.
          def call
            return nil unless claim

            rows = @list.list_items.ordered.to_a.select { |item| creatable?(item) }
            manager.write_step!(step: STEP, status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0, "failed_count" => 0})

            rows.each_with_index do |item, index|
              import_row(item)
              manager.write_step!(step: STEP, status: "running", progress: (index + 1) * 100 / rows.size,
                metadata: {"processed_items" => index + 1, "failed_count" => @failed})
            end

            delete_removed_rows
            manager.write_step!(step: STEP, status: "completed", progress: 100,
              metadata: {"total_items" => rows.size, "processed_items" => rows.size, "failed_count" => @failed,
                         "imported_at" => Time.current.iso8601})
            rows.size
          rescue => e
            manager.write_step!(step: STEP, status: "failed", progress: 0, error: e.message)
            raise
          end

          private

          def manager = @list.wizard_manager

          # Under the list's row lock: a step already running under another run
          # id belongs to that run. Otherwise this run takes it.
          def claim
            @list.with_lock do
              owner = manager.step_metadata(STEP)["run_id"]
              next false if manager.step_status(STEP) == "running" && owner.present? && owner != @run_id

              manager.update_step_status!(step: STEP, status: "running", progress: 0, error: nil,
                metadata: {"run_id" => @run_id || SecureRandom.uuid})
              true
            end
          end

          def creatable?(item)
            RowState.new(item).bucket == "create" && item.listable_id.nil?
          end

          def import_row(item)
            return unless ::ListItem.exists?(item.id)

            # Re-read: another run (a Sidekiq retry, a double start) may have
            # handled the row since this run listed it.
            item.reload
            return unless creatable?(item)

            found = @adapter.recheck(item)
            return link(item, found, "linked_existing", ["changed_since_match"]) if found

            link(item, @adapter.create(item), "created", [])
          rescue => e
            @failed += 1
            state = RowState.new(item)
            state.merge("bucket" => "flagged", "reasons" => (state.reasons + ["import_failed"]).uniq,
              "import_error" => e.message.to_s.truncate(500))
            RowState.unlink(item)
            item.save!
          end

          def link(item, record, result, reasons)
            state = RowState.new(item)
            if RowState.holder_of(@list, record, except: item)
              state.merge("bucket" => "flagged", "reasons" => (state.reasons + ["on_list_twice"]).uniq, "target_record_id" => record.id)
              item.save!
              return
            end

            state.merge(
              "bucket" => "matched", "import_result" => result, "target_record_id" => record.id, "import_error" => nil,
              "reasons" => ((state.reasons - ["import_failed"]) + reasons).uniq,
              "settled" => true, "settled_at" => state.data["settled_at"] || Time.current.iso8601
            )
            item.listable = record
            item.verified = true
            item.save!
          end

          def delete_removed_rows
            ids = @list.list_items.reload.select { |item| RowState.new(item).removed? }.map(&:id)
            ::ListItem.where(id: ids).destroy_all
          end
        end
      end
    end
  end
end
```

`web-app/app/sidekiq/lists/wizard/import_job.rb`:

```ruby
# frozen_string_literal: true

class Lists::Wizard::ImportJob
  include Sidekiq::Job

  def perform(list_id, run_id = nil)
    list = ::List.find(list_id)
    ::Services::Lists::Wizard::Core::ImportRows.call(list: list, adapter: ::Services::Lists::Wizard::Core::Adapters.for(list), run_id: run_id)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/data_importers/books/ test/lib/services/lists/wizard/ test/sidekiq/lists/wizard/ test/lib/services/books/goodreads_imports/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS (Goodreads tests confirm the provider refactor kept `apply_accept` behaviour).

- [ ] **Step 5: Commit**

```bash
git add app/lib/data_importers/books/book/providers/open_library.rb app/lib/data_importers/books/book/importer.rb app/lib/services/lists/wizard/books/adapter.rb app/lib/services/lists/wizard/core/import_rows.rb app/sidekiq/lists/wizard/import_job.rb test/lib/data_importers/books/book/providers/open_library_test.rb test/lib/data_importers/books/book/importer_test.rb test/lib/services/lists/wizard/books/adapter_test.rb test/lib/services/lists/wizard/core/import_rows_test.rb test/sidekiq/lists/wizard/import_job_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: import create rows serially with a re-check

The importer can trust an admin-chosen Open Library work key.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Review row actions

**Files:**
- Create: `web-app/app/lib/services/lists/wizard/core/row_actions.rb`
- Test: `web-app/test/lib/services/lists/wizard/core/row_actions_test.rb`

**Interfaces:**
- Consumes: `RowState` (Task 4), `Lists::Wizard::MatchRowJob` (Task 8), `MatchDecision#review!(by:, note:)`, `MatchDecision#selected_candidate`, verdict enum `confirmed`/`rejected`.
- Produces: `Services::Lists::Wizard::Core::RowActions.new(list_item:, user:)` with `#link(record)`, `#create_from_external(external_key)`, `#create_from_text`, `#edit_and_rematch(title:, subtitle:, authors:, year:)`, `#remove`, each → `RowActions::Result(success?:, data: {message:}, errors: [String])`.

Decision: **verdict** is `confirmed` when the admin's choice equals the finder's answer (same record; same external work with no record; "create from text" when the finder picked nothing), else `rejected`; edit and remove are `rejected`. Reviewer and time come from `review!`. A row with no decision (a Match failure) is acted on without recording one.
Decision: **edit-and-re-match settles the row and re-queues it** (`MatchRowJob.perform_async(id, true)`); the re-match may change it because the admin asked for it. If it lands flagged again it stays in the default Review view, which shows every `flagged` row (see Task 11).

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/lists/wizard/core/row_actions_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class RowActionsTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @admin = users(:admin_user)
            @book = books_books(:war_and_peace)
            @other = books_books(:got)
            @row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"], wizard: {bucket: "flagged", reasons: ["unsure"]})
          end

          def with_decision(**attributes)
            decision = wizard_match(subject: @row, **attributes).decision
            RowState.new(@row).merge("match_decision_id" => decision.id)
            @row.save!
            decision
          end

          def actions = RowActions.new(list_item: @row, user: @admin)

          test "link links the book, settles the row and confirms a decision that named the same book" do
            decision = with_decision(outcome: :matched, record: @book, confidence: :medium, candidates: [local_candidate(@book)])

            result = actions.link(@book)

            assert result.success?
            @row.reload
            state = RowState.new(@row)
            assert_equal [@book.id, true, "matched", [], true, @admin.id], [@row.listable_id, @row.verified, state.bucket, state.reasons, state.settled?, state.settled_by_id]
            decision.reload
            assert_equal [true, @admin.id], [decision.verdict_confirmed?, decision.reviewed_by_id]
            assert decision.reviewed_at.present?
          end

          test "link to a different book than the finder named rejects its decision" do
            decision = with_decision(outcome: :matched, record: @other, confidence: :medium)

            actions.link(@book)

            assert decision.reload.verdict_rejected?
          end

          test "link refuses a book another row holds, changes nothing and reviews nothing" do
            wizard_row(@list, position: 2, title: "War and Peace", listable: @book, wizard: {bucket: "matched"})
            decision = with_decision(outcome: :matched, record: @book, confidence: :medium)

            result = actions.link(@book)

            assert_not result.success?
            assert result.errors.first.present?
            assert_nil @row.reload.listable_id
            assert_equal "flagged", RowState.new(@row).bucket
            assert_nil decision.reload.reviewed_at
          end

          test "link refuses a missing record" do
            assert_not actions.link(nil).success?
          end

          test "create_from_external moves the row to create with that work" do
            work = ol_candidate("OL9W")
            with_decision(outcome: :unmatched, decided_by: :ai, external: work, candidates: [local_candidate(@other), work])

            result = actions.create_from_external("OL9W")

            assert result.success?
            state = RowState.new(@row.reload)
            assert_equal ["create", "OL9W", true], [state.bucket, state.ol_work_key, state.settled?]
            assert_includes state.ol_keys, "OL9W"
          end

          test "create_from_external refuses a work that is not a candidate, and one a book we hold carries" do
            held = ::DataImporters::Candidate.new(record: @other, external_key: "OL7W", external_source: :open_library, sources: [:open_library])
            with_decision(outcome: :unmatched, decided_by: :ai, candidates: [held])

            assert_not actions.create_from_external("OL1W").success?
            assert_not actions.create_from_external("OL7W").success?
            assert_equal "flagged", RowState.new(@row.reload).bucket
          end

          test "create_from_text moves the row to create with no work and unlinks it" do
            @row.update!(listable: @book, verified: true)

            assert actions.create_from_text.success?

            @row.reload
            assert_nil @row.listable_id
            assert_not @row.verified?
            assert_equal ["create", nil, true], [RowState.new(@row).bucket, RowState.new(@row).ol_work_key, RowState.new(@row).settled?]
          end

          test "edit_and_rematch saves the new text, settles the row, queues a single-row re-match and rejects the old decision" do
            decision = with_decision(outcome: :unmatched, decided_by: :rule, candidates: [])
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(@row.id, true)

            result = actions.edit_and_rematch(title: "War and Peace", subtitle: "A Novel", authors: "Leo Tolstoy\nLouise Maude", year: "1869")

            assert result.success?
            @row.reload
            assert_equal ["A Novel", ["Leo Tolstoy", "Louise Maude"], 1869], @row.metadata.values_at("subtitle", "authors", "year")
            assert_equal ["pending", true], [RowState.new(@row).bucket, RowState.new(@row).settled?]
            assert decision.reload.verdict_rejected?
          end

          test "edit cleans the year and the author lines, and refuses a blank title" do
            ::Lists::Wizard::MatchRowJob.stubs(:perform_async)

            actions.edit_and_rematch(title: " Emma ", subtitle: "", authors: "\n Jane Austen \n\n", year: " 1815 ")
            assert_equal ["Emma", nil, ["Jane Austen"], 1815], @row.reload.metadata.values_at("title", "subtitle", "authors", "year")

            actions.edit_and_rematch(title: "Emma", subtitle: nil, authors: "Jane Austen", year: "early 1800s")
            assert_nil @row.reload.metadata["year"]

            result = actions.edit_and_rematch(title: "  ", subtitle: nil, authors: "Jane Austen", year: nil)
            assert_not result.success?
            assert_equal "Emma", @row.reload.metadata["title"]
          end

          test "remove hides the row as removed, settled and unlinked" do
            @row.update!(listable: @book, verified: true)

            assert actions.remove.success?

            @row.reload
            assert_nil @row.listable_id
            assert_not @row.verified?
            assert_equal ["removed", true], [RowState.new(@row).bucket, RowState.new(@row).settled?]
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/wizard/core/row_actions_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::Lists::Wizard::Core::RowActions`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/core/row_actions.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §4: the Review actions. Every action settles the
        # row and records itself on the row's MatchDecision (verdict, reviewer,
        # time), so it also shows on the match audit pages.
        class RowActions
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def initialize(list_item:, user:)
            @item = list_item
            @user = user
          end

          def link(record)
            return failure("That book was not found.") if record.nil?

            holder = RowState.holder_of(@item.list, record, except: @item)
            return failure(already_on_list(holder)) if holder

            ::ActiveRecord::Base.transaction do
              record_review(verdict: same_record?(record) ? :confirmed : :rejected, note: "Linked #{record.class.name}##{record.id} in the list wizard")
              settle("bucket" => "matched", "reasons" => [], "target_record_id" => record.id, "ol_work_key" => nil, "import_error" => nil)
              @item.listable = record
              @item.verified = true
              @item.save!
            end
            success("Row linked.")
          rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid
            failure("That book is already on this list.")
          end

          def create_from_external(external_key)
            snapshots = candidates.select { |snapshot| snapshot["external_key"] == external_key }
            return failure("That work is not one of this row's candidates.") if snapshots.empty?
            if snapshots.none? { |snapshot| snapshot["record_id"].nil? }
              return failure("A book we hold already carries that work; link the book instead.")
            end

            ::ActiveRecord::Base.transaction do
              agreed = decision&.record_id.nil? && decision&.selected_candidate&.dig("external_key") == external_key
              record_review(verdict: agreed ? :confirmed : :rejected, note: "Create from Open Library #{external_key} in the list wizard")
              settle("bucket" => "create", "reasons" => [], "ol_work_key" => external_key,
                "ol_keys" => (state.ol_keys + [external_key]).uniq, "target_record_id" => nil, "import_error" => nil)
              RowState.unlink(@item)
              @item.save!
            end
            success("The row will be created from that work at Import.")
          end

          def create_from_text
            ::ActiveRecord::Base.transaction do
              agreed = decision.present? && decision.record_id.nil? && decision.selected_candidate.nil?
              record_review(verdict: agreed ? :confirmed : :rejected, note: "Create from the row's text in the list wizard")
              settle("bucket" => "create", "reasons" => [], "ol_work_key" => nil, "target_record_id" => nil, "import_error" => nil)
              RowState.unlink(@item)
              @item.save!
            end
            success("The row will be created from its text at Import.")
          end

          def edit_and_rematch(title:, subtitle:, authors:, year:)
            title = title.to_s.strip
            return failure("Title can't be blank.") if title.empty?

            ::ActiveRecord::Base.transaction do
              record_review(verdict: :rejected, note: "Edited and re-matched in the list wizard")
              @item.metadata = (@item.metadata || {}).merge(
                "title" => title,
                "subtitle" => subtitle.to_s.strip.presence,
                "authors" => authors.to_s.split(/\r?\n/).map(&:strip).compact_blank,
                "year" => clean_year(year)
              )
              settle(RowState::PENDING)
              RowState.unlink(@item)
              @item.save!
            end
            ::Lists::Wizard::MatchRowJob.perform_async(@item.id, true)
            success("The row is being matched again.")
          end

          def remove
            ::ActiveRecord::Base.transaction do
              record_review(verdict: :rejected, note: "Removed from the list in the list wizard")
              settle("bucket" => "removed", "reasons" => [])
              RowState.unlink(@item)
              @item.save!
            end
            success("Row removed.")
          end

          private

          def state = RowState.new(@item)

          def decision
            return @decision if defined?(@decision)

            @decision = ::MatchDecision.find_by(id: state.match_decision_id)
          end

          def candidates = Array(decision&.candidates)

          def same_record?(record)
            decision.present? && decision.record_type == record.class.name && decision.record_id == record.id
          end

          def record_review(verdict:, note:)
            return if decision.nil?

            decision.verdict = verdict
            decision.review!(by: @user, note: note)
          end

          def settle(attributes)
            RowState.new(@item).merge(attributes).settle(by: @user)
          end

          def clean_year(value)
            text = value.to_s.strip
            text.match?(/\A\d{1,4}\z/) ? text.to_i : nil
          end

          def already_on_list(holder)
            "That book is already on this list, at position #{holder.position || "?"}."
          end

          def success(message) = Result.new(success?: true, data: {message: message}, errors: [])

          def failure(message) = Result.new(success?: false, data: {}, errors: [message])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/wizard/core/row_actions_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/core/row_actions.rb test/lib/services/lists/wizard/core/row_actions_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: review row actions that settle and record the row

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Review data and summaries

**Files:**
- Create: `web-app/app/lib/services/lists/wizard/core/summary.rb`, `review_rows.rb`
- Test: `web-app/test/lib/services/lists/wizard/core/summary_test.rb`, `review_rows_test.rb`

**Interfaces:**
- Consumes: `RowState` (Task 4), `DuplicateCandidate.match_decision_id`, `Services::DuplicateCandidates::Flag.call(item_type:, ids:, source:, evidence:, match_decision:)`.
- Produces:
  - `Services::Lists::Wizard::Core::Summary.new(list)` → `#review_counts → {"matched","create","flagged","settled" => Integer}`, `#flagged_count → Integer`, `#done_counts → {"matched","created","admin_linked","unlinked","changed_since_match","duplicate_pairs" => Integer}`
  - `Services::Lists::Wizard::Core::ReviewRows.new(list:, filter: "flagged", listable_includes: [])` → `FILTERS = %w[flagged all create ai]`, `#filter → String`, `#rows → Array<ReviewRows::Row(item:, state:, decision:, candidates:)>`; `ReviewRows::CandidateView(record_id:, record_type:, external_key:, title:, creators:, year:, list_count:)` with `#local?`.

Decision: **the review row's candidate list comes from the `MatchDecision.candidates` snapshot** (top 6, the finder's order), not a re-query: it is what the finder actually weighed, and it costs one decision query per page. The list count shown for a local book is the snapshot's `list_count`.
Decision: **"AI-decided" means `metadata["wizard"]["decided_by"] == "ai"`**, copied from the match at Match time, so the filter needs no join.
Decision: **Done reports NEW duplicate pairs** ("New duplicate pairs raised"): pairs whose `match_decision_id` is one of this list's decisions. `Flag` keeps the first decision on a pair that already existed, so a pre-existing pair this list bumped is not counted.
Decision: **the default view is every `flagged` row**, which is the spec's "flagged, unsettled rows" plus the two cases where a settled row is still flagged (Import failed; an edit's re-match was flagged again), both of which need the admin. The "finish with N unlinked" count uses the same set.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/lists/wizard/core/summary_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class SummaryTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @admin = users(:admin_user)
            wizard_row(@list, position: 1, title: "Matched", listable: books_books(:war_and_peace), wizard: {bucket: "matched"})
            wizard_row(@list, position: 2, title: "Created", listable: books_books(:got),
              wizard: {bucket: "matched", import_result: "created", settled: true})
            wizard_row(@list, position: 3, title: "Admin linked", listable: books_books(:clash),
              wizard: {bucket: "matched", settled: true, settled_by_id: @admin.id})
            wizard_row(@list, position: 4, title: "Changed", listable: books_books(:cannery_row),
              wizard: {bucket: "matched", import_result: "linked_existing", reasons: ["changed_since_match"], settled: true})
            @flagged = wizard_row(@list, position: 5, title: "Flagged", wizard: {bucket: "flagged", reasons: ["unsure"]})
            wizard_row(@list, position: 6, title: "To create", wizard: {bucket: "create"})
            wizard_row(@list, position: 7, title: "Removed", wizard: {bucket: "removed", settled: true})
            @list.list_items.create!(listable: books_books(:of_mice_and_men), position: 8)
          end

          test "review counts buckets and settled rows, leaving out removed rows and rows from before the wizard" do
            assert_equal({"matched" => 4, "create" => 1, "flagged" => 1, "settled" => 3}, Summary.new(@list).review_counts)
            assert_equal 1, Summary.new(@list).flagged_count
          end

          test "done counts what the wizard did, and duplicate pairs raised by the rows' decisions" do
            decision = wizard_match(subject: @flagged, outcome: :unmatched).decision
            RowState.new(@flagged).merge("match_decision_id" => decision.id)
            @flagged.save!
            # A pair no fixture holds: an existing pair keeps the decision that first
            # raised it, so it would not count as new here.
            ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book",
              ids: [books_books(:war_and_peace).id, books_books(:crime_and_punishment).id],
              source: :ai, evidence: {}, match_decision: decision)

            assert_equal({"matched" => 1, "created" => 1, "admin_linked" => 1, "unlinked" => 2, "changed_since_match" => 1, "duplicate_pairs" => 1},
              Summary.new(@list).done_counts)
          end
        end
      end
    end
  end
end
```

`web-app/test/lib/services/lists/wizard/core/review_rows_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class ReviewRowsTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @matched = wizard_row(@list, position: 1, title: "Matched", listable: books_books(:war_and_peace), wizard: {bucket: "matched", decided_by: "rule"})
            @flagged = wizard_row(@list, position: 2, title: "Flagged", wizard: {bucket: "flagged", reasons: ["unsure"], decided_by: "ai"})
            @create = wizard_row(@list, position: 3, title: "Create", wizard: {bucket: "create", decided_by: "rule"})
            @removed = wizard_row(@list, position: 4, title: "Removed", wizard: {bucket: "removed", settled: true})
          end

          def ids(filter) = ReviewRows.new(list: @list, filter: filter).rows.map { |row| row.item.id }

          test "the default view is flagged rows only" do
            assert_equal [@flagged.id], ids("flagged")
            assert_equal [@flagged.id], ids(nil)
            assert_equal "flagged", ReviewRows.new(list: @list, filter: "bogus").filter
          end

          test "the filters: all rows, rows to create, AI-decided rows; removed rows never show" do
            assert_equal [@matched.id, @flagged.id, @create.id], ids("all")
            assert_equal [@create.id], ids("create")
            assert_equal [@flagged.id], ids("ai")
          end

          test "each row carries its decision and its top candidates from the snapshot" do
            got = books_books(:got)
            candidates = [local_candidate(got, list_count: 4), ol_candidate("OL9W", title: "A Game of Thrones", creators: ["George R. R. Martin"], year: 1996)] +
              Array.new(6) { |i| ol_candidate("OL#{i}X") }
            decision = wizard_match(subject: @flagged, outcome: :unmatched, decided_by: :ai, candidates: candidates).decision
            RowState.new(@flagged).merge("match_decision_id" => decision.id)
            @flagged.save!

            row = ReviewRows.new(list: @list).rows.first

            assert_equal decision, row.decision
            assert_equal 6, row.candidates.size
            local, external = row.candidates
            assert_equal [true, got.id, "A Game of Thrones", 4], [local.local?, local.record_id, local.title, local.list_count]
            assert_equal [false, "OL9W", ["George R. R. Martin"], 1996], [external.local?, external.external_key, external.creators, external.year]
          end

          test "a row without a decision has no candidates" do
            assert_equal [], ReviewRows.new(list: @list).rows.first.candidates
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/wizard/core/summary_test.rb test/lib/services/lists/wizard/core/review_rows_test.rb`
Expected: FAIL — `NameError: uninitialized constant …::Summary` / `…::ReviewRows`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/lists/wizard/core/summary.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # The counts the Review header (spec §4) and the Done screen (spec §6) show.
        class Summary
          def initialize(list)
            @list = list
          end

          def review_counts
            states = wizard_rows.map(&:last)
            {
              "matched" => states.count { |state| state.bucket == "matched" },
              "create" => states.count { |state| state.bucket == "create" },
              "flagged" => states.count(&:flagged?),
              "settled" => states.count(&:settled?)
            }
          end

          def flagged_count
            wizard_rows.count { |_item, state| state.flagged? }
          end

          def done_counts
            rows = all_rows
            {
              "matched" => rows.count { |item, state| state.present? && item.listable_id && state.import_result.nil? && state.settled_by_id.nil? },
              "created" => rows.count { |_item, state| state.import_result == "created" },
              "admin_linked" => rows.count { |item, state| item.listable_id && state.import_result.nil? && state.settled_by_id.present? },
              "unlinked" => rows.count { |item, _state| item.listable_id.nil? },
              "changed_since_match" => rows.count { |_item, state| state.import_result == "linked_existing" },
              # NEW pairs this list's decisions raised: Services::DuplicateCandidates::Flag
              # keeps the first decision on a pair that already existed and only
              # bumps its occurrences, so a pre-existing pair is not counted.
              "duplicate_pairs" => ::DuplicateCandidate.where(match_decision_id: rows.filter_map { |_item, state| state.match_decision_id }).count
            }
          end

          private

          def all_rows
            @all_rows ||= @list.list_items.to_a.map { |item| [item, RowState.new(item)] }.reject { |_item, state| state.removed? }
          end

          def wizard_rows
            all_rows.select { |_item, state| state.present? }
          end
        end
      end
    end
  end
end
```

`web-app/app/lib/services/lists/wizard/core/review_rows.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # The Review table's rows (spec §4): the filtered rows in list order, each
        # with its current decision and the top candidates the finder weighed.
        class ReviewRows
          FILTERS = %w[flagged all create ai].freeze
          MAX_CANDIDATES = 6

          Row = Struct.new(:item, :state, :decision, :candidates, keyword_init: true)
          CandidateView = Struct.new(:record_id, :record_type, :external_key, :title, :creators, :year, :list_count, keyword_init: true) do
            def local? = !record_id.nil?
          end

          attr_reader :filter

          def initialize(list:, filter: "flagged", listable_includes: [])
            @list = list
            @filter = FILTERS.include?(filter) ? filter : FILTERS.first
            @listable_includes = listable_includes
          end

          def rows
            items = @list.list_items.includes(listable: @listable_includes).order(:position, :id).to_a
            items = items.select { |item| keep?(RowState.new(item)) }
            decisions = ::MatchDecision.where(id: items.filter_map { |item| RowState.new(item).match_decision_id }).index_by(&:id)
            items.map do |item|
              state = RowState.new(item)
              decision = decisions[state.match_decision_id]
              Row.new(item: item, state: state, decision: decision, candidates: candidates_for(decision))
            end
          end

          private

          def keep?(state)
            return false if state.removed?

            case filter
            when "all" then true
            when "create" then state.bucket == "create"
            when "ai" then state.decided_by == "ai"
            else state.flagged?
            end
          end

          def candidates_for(decision)
            Array(decision&.candidates).first(MAX_CANDIDATES).map do |snapshot|
              evidence = snapshot["evidence"] || {}
              CandidateView.new(
                record_id: snapshot["record_id"], record_type: snapshot["record_type"], external_key: snapshot["external_key"],
                title: evidence["title"] || evidence["external_title"],
                creators: Array(evidence["creators"].presence || evidence["external_creators"]),
                year: evidence["year"] || evidence["external_year"], list_count: evidence["list_count"]
              )
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/wizard/core/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/lists/wizard/core/summary.rb app/lib/services/lists/wizard/core/review_rows.rb test/lib/services/lists/wizard/core/summary_test.rb test/lib/services/lists/wizard/core/review_rows_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: review rows, filters and summary counts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Routes, adapter paths and the wizard screens (ViewComponents)

**Files:**
- Modify: `web-app/config/routes.rb` (admin_books `resources :lists`)
- Modify: `web-app/app/lib/services/lists/wizard/books/adapter.rb` (paths)
- Modify: `web-app/app/components/wizard/navigation_component.{rb,html.erb}` (`next_confirm`, `next_params`, `restart_confirm`)
- Modify: `web-app/app/components/autocomplete_component.{rb,html.erb}` (optional `id:`)
- Create (generator): `bin/rails generate component Wizard::Core::PasteStep list adapter`, `… Wizard::Core::JobStep list adapter step`, `… Wizard::Core::ReviewStep list adapter filter`, `… Wizard::Core::ReviewRow row list adapter filter`, `… Wizard::Core::DoneStep list adapter`
- Test: generated `web-app/test/components/wizard/core/*_component_test.rb`, `web-app/test/components/wizard/navigation_component_test.rb`, `web-app/test/components/autocomplete_component_test.rb`, `web-app/test/lib/services/lists/wizard/books/adapter_test.rb`

**Interfaces:**
- Consumes: `Summary`, `ReviewRows`, `RowState` (Tasks 4, 11); adapter display methods (Task 6).
- Produces:
  - Routes (all under `/admin/lists/:list_id/wizard`, names `*_admin_books_list_wizard_path`): `show` (GET `/`), `step` (GET `step/:step`), `step_status` (GET `step/:step/status`), `advance_step`, `back_step` (POST `step/:step/…`), `save_content`, `reparse`, `rematch`, `restart` (POST), `link_row`, `create_row`, `create_row_from_text`, `edit_row`, `remove_row` (POST `rows/:row_id/…`).
  - `Books::Adapter#wizard_path(name, list, **params) → String` (`name` nil → `admin_books_list_wizard_path`), `#search_path`, `#lists_path`, `#list_path(list)`.
  - `Wizard::NavigationComponent.new(…, next_confirm: nil, next_params: {}, restart_confirm: DEFAULT_RESTART_CONFIRM)` with public `#next_button_data`, `#next_params`, `#restart_button_data`.
  - `AutocompleteComponent.new(…, id: nil)`.
  - `Wizard::Core::PasteStepComponent.new(list:, adapter:)` (renders a `batch_mode` checkbox, value `"1"`), `JobStepComponent.new(list:, adapter:, step:)`, `ReviewStepComponent.new(list:, adapter:, filter:)`, `ReviewRowComponent.new(row:, list:, adapter:, filter:)`, `DoneStepComponent.new(list:, adapter:)`.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside `namespace :admin, module: "admin/books", as: "admin_books"`, replace `resources :lists` with:

```ruby
      resources :lists do
        # The list wizard core (books list wizard spec §1).
        resource :wizard, only: [:show], controller: "list_wizard" do
          get "step/:step", action: :show_step, as: :step
          get "step/:step/status", action: :step_status, as: :step_status
          post "step/:step/advance", action: :advance_step, as: :advance_step
          post "step/:step/back", action: :back_step, as: :back_step
          post "save_content", action: :save_content, as: :save_content
          post "reparse", action: :reparse, as: :reparse
          post "rematch", action: :rematch, as: :rematch
          post "restart", action: :restart
          post "rows/:row_id/link", action: :link_row, as: :link_row
          post "rows/:row_id/create", action: :create_row, as: :create_row
          post "rows/:row_id/create_from_text", action: :create_row_from_text, as: :create_row_from_text
          post "rows/:row_id/edit", action: :edit_row, as: :edit_row
          post "rows/:row_id/remove", action: :remove_row, as: :remove_row
        end
      end
```

Run: `bin/rails routes -g admin_books_list_wizard`
Expected: the 15 routes above.

- [ ] **Step 2: Write the failing tests**

Add to `test/lib/services/lists/wizard/books/adapter_test.rb`:

```ruby
          test "paths point at the books admin wizard, the book search and the list pages" do
            assert_equal "/admin/lists/#{@list.id}/wizard", @adapter.wizard_path(nil, @list)
            assert_equal "/admin/lists/#{@list.id}/wizard/step/review?filter=ai", @adapter.wizard_path(:step, @list, step: "review", filter: "ai")
            assert_equal "/admin/lists/#{@list.id}/wizard/rows/7/link", @adapter.wizard_path(:link_row, @list, row_id: 7)
            assert_equal "/admin/books/search", @adapter.search_path
            assert_equal ["/admin/lists", "/admin/lists/#{@list.id}"], [@adapter.lists_path, @adapter.list_path(@list)]
          end
```

Add to `test/components/wizard/navigation_component_test.rb`:

```ruby
  test "the next button carries a confirmation and extra params only when given" do
    plain = Wizard::NavigationComponent.new(list: @list, step_name: "review", step_index: 3, total_steps: 6)
    confirming = Wizard::NavigationComponent.new(list: @list, step_name: "review", step_index: 3, total_steps: 6,
      next_confirm: "Finish with 2 rows unlinked?", next_params: {confirm_unlinked: "1"}, restart_confirm: "Restart?")

    assert_equal({wizard_step_target: "nextButton"}, plain.next_button_data)
    assert_equal({}, plain.next_params)
    assert_equal "Finish with 2 rows unlinked?", confirming.next_button_data[:turbo_confirm]
    assert_equal({confirm_unlinked: "1"}, confirming.next_params)
    assert_equal({turbo_confirm: "Restart?"}, confirming.restart_button_data)
    assert_equal Wizard::NavigationComponent::DEFAULT_RESTART_CONFIRM, plain.restart_button_data[:turbo_confirm]
  end
```

Add to `test/components/autocomplete_component_test.rb`:

```ruby
  test "an explicit id keeps two widgets with the same field name apart" do
    render_inline(AutocompleteComponent.new(name: "record_id", url: "/search", id: "row_5_record"))

    assert_selector "input#row_5_record_autocomplete[type=search]"
    assert_selector "input#row_5_record[type=hidden][name=record_id]", visible: :all
  end
```

Replace the generated `test/components/wizard/core/paste_step_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Wizard::Core::PasteStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  test "the form posts the pasted content to save_content and shows what was pasted before" do
    list = wizard_list(raw_content: "1. Emma by Jane Austen")
    adapter = ::Services::Lists::Wizard::Books::Adapter.new

    render_inline(Wizard::Core::PasteStepComponent.new(list: list, adapter: adapter))

    assert_selector "form[action='#{adapter.wizard_path(:save_content, list)}'][method=post]"
    assert_selector "textarea[name=raw_content]#raw_content", text: "1. Emma by Jane Austen"
    assert_selector "label[for=raw_content]"
    assert_selector "input[type=checkbox][name=batch_mode][value='1']:not([checked])"
  end

  test "the large-list checkbox shows the list's batch mode" do
    list = wizard_list
    list.update!(wizard_state: {"batch_mode" => true})

    render_inline(Wizard::Core::PasteStepComponent.new(list: list, adapter: ::Services::Lists::Wizard::Books::Adapter.new))

    assert_selector "input[type=checkbox][name=batch_mode][value='1'][checked]"
  end
end
```

Replace the generated `test/components/wizard/core/job_step_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Wizard::Core::JobStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  setup do
    @list = wizard_list
    @adapter = ::Services::Lists::Wizard::Books::Adapter.new
  end

  def render_step(step) = render_inline(Wizard::Core::JobStepComponent.new(list: @list, adapter: @adapter, step: step))

  test "a running step polls its status and reloads its own page" do
    @list.wizard_manager.write_step!(step: "match", status: "running", progress: 40)

    render_step("match")

    assert_selector "[data-controller=wizard-step][data-wizard-step-status-url-value='#{@adapter.wizard_path(:step_status, @list, step: "match")}'][data-wizard-step-step-url-value='#{@adapter.wizard_path(:step, @list, step: "match")}']"
    assert_selector "progress[data-wizard-step-target=progressBar][value='40']"
  end

  test "an idle step offers to start it, a failed one shows its error and offers to retry" do
    render_step("parse")
    assert_selector "form[action='#{@adapter.wizard_path(:advance_step, @list, step: "parse")}']"

    @list.wizard_manager.write_step!(step: "parse", status: "failed", error: "rate limited")
    render_step("parse")
    assert_selector "[role=alert]", text: "rate limited"
    assert_selector "form[action='#{@adapter.wizard_path(:advance_step, @list, step: "parse")}']"
  end

  test "a completed parse lists the parsed rows, without removed ones, and offers a re-parse" do
    wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"])
    wizard_row(@list, position: 2, title: "Gone", wizard: {bucket: "removed", settled: true})
    @list.wizard_manager.write_step!(step: "parse", status: "completed", progress: 100)

    render_step("parse")

    assert_selector "[data-testid=parsed-rows] tbody tr", count: 1
    assert_selector "form[action='#{@adapter.wizard_path(:reparse, @list)}']"
  end

  test "a completed match shows its counts and offers a re-match; a completed import shows its summary" do
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
    @list.wizard_manager.write_step!(step: "import", status: "completed", progress: 100, metadata: {"processed_items" => 3, "failed_count" => 1})

    render_step("match")
    assert_selector "[data-testid=match-counts] [data-stat=flagged] .stat-value", text: "1"
    assert_selector "form[action='#{@adapter.wizard_path(:rematch, @list)}']"

    render_step("import")
    assert_selector "[data-testid=import-summary] [data-stat=failed] .stat-value", text: "1"
    assert_selector "[data-testid=import-summary] [data-stat=processed] .stat-value", text: "3"
  end
end
```

Replace the generated `test/components/wizard/core/review_step_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Wizard::Core::ReviewStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  setup do
    @list = wizard_list
    @adapter = ::Services::Lists::Wizard::Books::Adapter.new
    wizard_row(@list, position: 1, title: "Matched", listable: books_books(:war_and_peace), wizard: {bucket: "matched"})
    wizard_row(@list, position: 2, title: "Flagged", wizard: {bucket: "flagged", reasons: ["not_found"]})
    wizard_row(@list, position: 3, title: "Create", wizard: {bucket: "create"})
  end

  test "the default view shows only flagged rows, with the counts and a link per filter" do
    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "flagged"))

    assert_selector "[data-testid=review-row]", count: 1
    assert_selector "[data-testid=review-counts] [data-stat=matched] .stat-value", text: "1"
    %w[flagged all create ai].each do |filter|
      assert_selector "a[role=tab][href='#{@adapter.wizard_path(:step, @list, step: "review", filter: filter)}']"
    end
    assert_selector "a.tab-active[href*='filter=flagged']"
  end

  test "the all filter shows every row, and an empty view says so" do
    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "all"))
    assert_selector "[data-testid=review-row]", count: 3

    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "ai"))
    assert_selector "[data-testid=review-row]", count: 0
    assert_selector "[data-testid=review-empty]"
  end
end
```

Replace the generated `test/components/wizard/core/review_row_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Wizard::Core::ReviewRowComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  setup do
    @list = wizard_list
    @adapter = ::Services::Lists::Wizard::Books::Adapter.new
    @got = books_books(:got)
    @item = wizard_row(@list, position: 1, title: "A Game of Thrones", authors: ["George R. R. Martin"], wizard: {bucket: "flagged", reasons: ["unsure"]})
    held = ::DataImporters::Candidate.new(record: books_books(:clash), external_key: "OL7W", external_source: :open_library,
      sources: [:open_library], evidence: {title: "A Clash of Kings", creators: [], list_count: 2})
    decision = wizard_match(subject: @item, outcome: :unmatched, decided_by: :ai,
      candidates: [local_candidate(@got, list_count: 4), ol_candidate("OL9W", title: "A Game of Thrones"), held]).decision
    ::Services::Lists::Wizard::Core::RowState.new(@item).merge("match_decision_id" => decision.id)
    @item.save!
  end

  def render_row(filter: "flagged")
    row = ::Services::Lists::Wizard::Core::ReviewRows.new(list: @list, filter: "all").rows.first
    render_inline(Wizard::Core::ReviewRowComponent.new(row: row, list: @list, adapter: @adapter, filter: filter))
  end

  def path(name) = @adapter.wizard_path(name, @list, row_id: @item.id)

  test "a local candidate can be linked, an Open Library-only one created from, a held one only linked" do
    render_row

    assert_selector "[data-testid=row-candidate]", count: 3
    assert_selector "form[action='#{path(:link_row)}'] input[name=record_id][value='#{@got.id}']", visible: :all
    assert_selector "form[action='#{path(:create_row)}'] input[name=external_key][value=OL9W]", visible: :all
    assert_selector "form[action='#{path(:link_row)}'] input[name=record_id][value='#{books_books(:clash).id}']", visible: :all
    assert_no_selector "form[action='#{path(:create_row)}'] input[name=external_key][value=OL7W]", visible: :all
  end

  test "every row offers search, create from text, edit and remove, each keeping the current filter" do
    render_row(filter: "ai")

    assert_selector "form[action='#{path(:link_row)}'] input#row_#{@item.id}_record[type=hidden][name=record_id]", visible: :all
    assert_selector "form[action='#{path(:create_row_from_text)}'] input[name=filter][value=ai]", visible: :all
    assert_selector "form[action='#{path(:edit_row)}'] input[name=title][value='A Game of Thrones']", visible: :all
    assert_selector "form[action='#{path(:edit_row)}'] textarea[name=authors]", text: "George R. R. Martin", visible: :all
    assert_selector "form[action='#{path(:remove_row)}'] input[name=filter][value=ai]", visible: :all
    assert_selector "[data-testid=row-reasons] li", count: 1
  end
end
```

Replace the generated `test/components/wizard/core/done_step_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Wizard::Core::DoneStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  test "shows each Done count and links back to the list" do
    list = wizard_list
    adapter = ::Services::Lists::Wizard::Books::Adapter.new
    wizard_row(list, position: 1, title: "Created", listable: books_books(:got), wizard: {bucket: "matched", import_result: "created", settled: true})
    wizard_row(list, position: 2, title: "Left", wizard: {bucket: "flagged"})

    render_inline(Wizard::Core::DoneStepComponent.new(list: list, adapter: adapter))

    assert_selector "[data-testid=done-summary] [data-stat=created] .stat-value", text: "1"
    assert_selector "[data-testid=done-summary] [data-stat=unlinked] .stat-value", text: "1"
    %w[matched admin_linked changed_since_match duplicate_pairs].each do |key|
      assert_selector "[data-testid=done-summary] [data-stat=#{key}] .stat-value", text: "0"
    end
    assert_selector "a[href='#{adapter.list_path(list)}']"
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: generate the five components (commands in **Files**), then `bin/rails test test/components/wizard/ test/components/autocomplete_component_test.rb test/lib/services/lists/wizard/books/adapter_test.rb`
Expected: FAIL — `NoMethodError: wizard_path`, `ArgumentError: unknown keyword: :next_confirm` / `:id`, and missing selectors in the generated components.

- [ ] **Step 4: Implement**

Adapter paths (add to `adapter.rb`):

```ruby
          def wizard_path(name, list, **params)
            helper = [name, "admin_books_list_wizard_path"].compact.join("_")
            url_helpers.public_send(helper, list_id: list.id, **params)
          end

          def search_path = url_helpers.search_admin_books_books_path

          def lists_path = url_helpers.admin_books_lists_path

          def list_path(list) = url_helpers.admin_books_list_path(list)
```

and privately:

```ruby
          def url_helpers = ::Rails.application.routes.url_helpers
```

`navigation_component.rb`:

```ruby
# frozen_string_literal: true

class Wizard::NavigationComponent < ViewComponent::Base
  DEFAULT_RESTART_CONFIRM = "Are you sure you want to restart the wizard? Items you have not verified are deleted; verified items are kept."

  attr_reader :next_params

  def initialize(list:, step_name:, step_index:, total_steps:, back_enabled: true, next_enabled: true, next_label: "Next →",
    next_confirm: nil, next_params: {}, restart_confirm: DEFAULT_RESTART_CONFIRM)
    @list = list
    @step_name = step_name
    @step_index = step_index
    @total_steps = total_steps
    @back_enabled = back_enabled
    @next_enabled = next_enabled
    @next_label = next_label
    @next_confirm = next_confirm
    @next_params = next_params
    @restart_confirm = restart_confirm
  end

  def show_back_button?
    @step_index > 0 && @back_enabled
  end

  def show_next_button?
    @step_index < @total_steps - 1
  end

  def next_button_disabled?
    !@next_enabled || @list.wizard_manager.step_status(@step_name) == "running"
  end

  def next_button_data
    {wizard_step_target: "nextButton", turbo_confirm: @next_confirm}.compact
  end

  def restart_button_data
    {turbo_confirm: @restart_confirm}
  end

  private

  attr_reader :list, :step_name, :step_index, :total_steps, :back_enabled, :next_enabled, :next_label
end
```

`navigation_component.html.erb`:

```erb
<div class="flex justify-between items-center">
  <div>
    <% if show_back_button? %>
      <%= button_to "← Back",
          { action: :back_step, step: step_name },
          method: :post,
          class: "btn btn-outline" %>
    <% end %>
  </div>

  <div class="flex gap-2">
    <%= button_to "Restart",
        { action: :restart },
        method: :post,
        class: "btn btn-outline",
        data: restart_button_data %>

    <% if show_next_button? %>
      <%= button_to next_label,
          { action: :advance_step, step: step_name },
          method: :post,
          params: next_params,
          class: "btn btn-primary",
          disabled: next_button_disabled?,
          data: next_button_data %>
    <% end %>
  </div>
</div>
```

`autocomplete_component.rb`: add `id: nil` to `initialize`'s keywords, `@id = id`, and:

```ruby
  def input_id
    @id.presence || @name.to_s.gsub(/[\[\]]/, "_").squeeze("_").sub(/_$/, "")
  end
```

`autocomplete_component.html.erb`: the hidden field gains an explicit id (same value as Rails' default for every existing caller):

```erb
    <%= hidden_field_tag name, value,
        id: input_id,
        data: { autocomplete_target: "hiddenField" },
        required: required %>
```

`app/components/wizard/core/paste_step_component.rb`:

```ruby
# frozen_string_literal: true

class Wizard::Core::PasteStepComponent < ViewComponent::Base
  def initialize(list:, adapter:)
    @list = list
    @adapter = adapter
  end

  def form_path = @adapter.wizard_path(:save_content, @list)

  def batch_mode? = @list.wizard_state&.dig("batch_mode") == true

  private

  attr_reader :list
end
```

`paste_step_component.html.erb`:

```erb
<%= render(Wizard::StepComponent.new(title: "Paste the list", description: "Paste the list's HTML or its plain text. The parser reads every book on it.")) do |step| %>
  <% step.with_step_content do %>
    <%= form_with url: form_path, method: :post do |form| %>
      <label class="label mb-2" for="raw_content">List content</label>
      <%= form.text_area :raw_content, id: "raw_content", value: list.raw_content, rows: 15, required: true,
          class: "textarea w-full font-mono text-sm" %>
      <label class="label mt-3 cursor-pointer">
        <%= check_box_tag :batch_mode, "1", batch_mode?, class: "checkbox checkbox-sm" %>
        Large plain-text list (1000+ lines): parse 100 lines at a time
      </label>
      <div class="mt-4">
        <%= form.submit "Save and parse", class: "btn btn-primary" %>
      </div>
    <% end %>
  <% end %>
<% end %>
```

`job_step_component.rb`:

```ruby
# frozen_string_literal: true

class Wizard::Core::JobStepComponent < ViewComponent::Base
  TITLES = {"parse" => "Parse", "match" => "Match", "import" => "Import"}.freeze
  DESCRIPTIONS = {
    "parse" => "The parser turns the pasted list into rows.",
    "match" => "Every row is looked up. Confident answers pass through; the rest are flagged for review.",
    "import" => "Rows marked to create become books, one at a time."
  }.freeze
  RERUN = {"parse" => [:reparse, "Re-parse"], "match" => [:rematch, "Re-match unsettled rows"]}.freeze

  def initialize(list:, adapter:, step:)
    @list = list
    @adapter = adapter
    @step = step
  end

  def title = TITLES.fetch(@step)

  def description = DESCRIPTIONS.fetch(@step)

  def status = manager.step_status(@step)

  def progress = manager.step_progress(@step)

  def error = manager.step_error(@step)

  def metadata = manager.step_metadata(@step)

  def start_label = error.present? ? "Try again" : "Start"

  def start_path = @adapter.wizard_path(:advance_step, @list, step: @step)

  def status_path = @adapter.wizard_path(:step_status, @list, step: @step)

  def step_path = @adapter.wizard_path(:step, @list, step: @step)

  def rerun_path = RERUN[@step] && @adapter.wizard_path(RERUN[@step].first, @list)

  def rerun_label = RERUN[@step]&.last

  def parsed_rows
    @list.list_items.ordered.to_a
      .reject { |item| ::Services::Lists::Wizard::Core::RowState.new(item).removed? }
      .map { |item| [item, @adapter.row_display(item)] }
  end

  def counts = @counts ||= ::Services::Lists::Wizard::Core::Summary.new(@list).review_counts

  private

  attr_reader :step

  def manager = @list.wizard_manager
end
```

`job_step_component.html.erb`:

```erb
<%= render(Wizard::StepComponent.new(title: title, description: description)) do |s| %>
  <% s.with_step_content do %>
    <% if status == "running" %>
      <div data-controller="wizard-step"
           data-wizard-step-status-url-value="<%= status_path %>"
           data-wizard-step-step-url-value="<%= step_path %>">
        <div class="flex justify-between items-center mb-2">
          <span class="text-sm font-medium" data-wizard-step-target="statusText">Working…</span>
          <span class="text-sm text-base-content/70"><%= progress %>%</span>
        </div>
        <progress class="progress progress-primary w-full" value="<%= progress %>" max="100" data-wizard-step-target="progressBar"></progress>
      </div>
    <% elsif status == "completed" %>
      <% case step %>
      <% when "parse" %>
        <div class="overflow-x-auto max-h-96 overflow-y-auto" data-testid="parsed-rows">
          <table class="table table-sm table-pin-rows bg-base-100">
            <thead><tr><th>#</th><th>Title</th><th>Authors</th><th>Year</th></tr></thead>
            <tbody>
              <% parsed_rows.each do |item, display| %>
                <tr>
                  <td><%= item.position %></td>
                  <td class="[overflow-wrap:anywhere]"><%= display[:title] %><% if display[:subtitle].present? %>: <%= display[:subtitle] %><% end %></td>
                  <td class="[overflow-wrap:anywhere]"><%= Array(display[:authors]).join(", ") %></td>
                  <td><%= display[:year] || "—" %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% when "match" %>
        <div class="stats stats-vertical lg:stats-horizontal shadow bg-base-100" data-testid="match-counts">
          <% {"matched" => "Matched", "create" => "To create", "flagged" => "Flagged"}.each do |key, label| %>
            <div class="stat" data-stat="<%= key %>">
              <div class="stat-title"><%= label %></div>
              <div class="stat-value"><%= counts[key] %></div>
            </div>
          <% end %>
        </div>
      <% when "import" %>
        <div class="stats stats-vertical lg:stats-horizontal shadow bg-base-100" data-testid="import-summary">
          <div class="stat" data-stat="processed">
            <div class="stat-title">Rows processed</div>
            <div class="stat-value"><%= metadata["processed_items"].to_i %></div>
          </div>
          <div class="stat" data-stat="failed">
            <div class="stat-title">Failed</div>
            <div class="stat-value"><%= metadata["failed_count"].to_i %></div>
          </div>
        </div>
      <% end %>
      <% if rerun_path %>
        <%= button_to rerun_label, rerun_path, method: :post, class: "btn btn-outline btn-sm mt-4" %>
      <% end %>
    <% else %>
      <% if error.present? %>
        <div class="alert alert-error mb-4" role="alert"><span class="[overflow-wrap:anywhere]"><%= error %></span></div>
      <% end %>
      <%= button_to start_label, start_path, method: :post, class: "btn btn-primary" %>
    <% end %>
  <% end %>
<% end %>
```

`review_step_component.rb`:

```ruby
# frozen_string_literal: true

class Wizard::Core::ReviewStepComponent < ViewComponent::Base
  FILTER_LABELS = {"flagged" => "Flagged", "all" => "All rows", "create" => "To create", "ai" => "AI-decided"}.freeze
  COUNT_LABELS = {"matched" => "Matched", "create" => "To create", "flagged" => "Flagged", "settled" => "Settled"}.freeze

  def initialize(list:, adapter:, filter:)
    @list = list
    @adapter = adapter
    @review = ::Services::Lists::Wizard::Core::ReviewRows.new(list: list, filter: filter, listable_includes: adapter.listable_includes)
  end

  def filter = @review.filter

  def rows = @rows ||= @review.rows

  def counts = @counts ||= ::Services::Lists::Wizard::Core::Summary.new(@list).review_counts

  def filter_path(name) = @adapter.wizard_path(:step, @list, step: "review", filter: name)

  private

  attr_reader :list, :adapter
end
```

`review_step_component.html.erb`:

```erb
<%= render(Wizard::StepComponent.new(title: "Review", description: "Only rows that might be wrong are shown first. Every action settles the row.")) do |step| %>
  <% step.with_step_content do %>
    <div class="stats stats-vertical lg:stats-horizontal shadow bg-base-100 mb-6" data-testid="review-counts">
      <% COUNT_LABELS.each do |key, label| %>
        <div class="stat" data-stat="<%= key %>">
          <div class="stat-title"><%= label %></div>
          <div class="stat-value"><%= counts[key] %></div>
        </div>
      <% end %>
    </div>

    <div role="tablist" class="tabs tabs-box mb-4">
      <% FILTER_LABELS.each do |name, label| %>
        <%= link_to label, filter_path(name), role: "tab", class: class_names("tab", "tab-active" => name == filter) %>
      <% end %>
    </div>

    <% if rows.empty? %>
      <p class="text-base-content/70" data-testid="review-empty">Nothing to review in this view.</p>
    <% else %>
      <div class="space-y-4">
        <% rows.each do |row| %>
          <%= render(Wizard::Core::ReviewRowComponent.new(row: row, list: list, adapter: adapter, filter: filter)) %>
        <% end %>
      </div>
    <% end %>
  <% end %>
<% end %>
```

`review_row_component.rb`:

```ruby
# frozen_string_literal: true

class Wizard::Core::ReviewRowComponent < ViewComponent::Base
  BADGES = {"matched" => "badge-success", "create" => "badge-info", "flagged" => "badge-warning"}.freeze

  attr_reader :filter

  def initialize(row:, list:, adapter:, filter:)
    @row = row
    @list = list
    @adapter = adapter
    @filter = filter
  end

  def item = @row.item

  def state = @row.state

  def candidates = @row.candidates

  def row_text = @row_text ||= @adapter.row_display(item)

  def linked = item.listable && @adapter.record_display(item.listable)

  def reasons = state.reasons.map { |reason| ::Services::Lists::Wizard::Core::RowState.label_for(reason) }

  def problem = state.import_error.presence || state.error.presence

  def bucket_badge = BADGES.fetch(state.bucket.to_s, "badge-ghost")

  def bucket_label = state.bucket.to_s.humanize.presence || "Not in the wizard"

  def search_path = @adapter.search_path

  def search_id = "row_#{item.id}_record"

  def field_id(name) = "row_#{item.id}_#{name}"

  def path(name) = @adapter.wizard_path(name, @list, row_id: item.id)
end
```

`review_row_component.html.erb`:

```erb
<div class="card bg-base-100 border border-base-300" data-testid="review-row">
  <div class="card-body gap-3">
    <div class="flex flex-wrap items-start justify-between gap-2">
      <div class="min-w-0">
        <p class="text-sm text-base-content/70">#<%= item.position %></p>
        <h3 class="font-semibold [overflow-wrap:anywhere]"><%= row_text[:title] %><% if row_text[:subtitle].present? %>: <%= row_text[:subtitle] %><% end %></h3>
        <p class="text-sm [overflow-wrap:anywhere]"><%= Array(row_text[:authors]).join(", ") %><% if row_text[:year].present? %> (<%= row_text[:year] %>)<% end %></p>
      </div>
      <span class="badge <%= bucket_badge %>"><%= bucket_label %></span>
    </div>

    <% if reasons.any? %>
      <ul class="text-sm list-disc list-inside" data-testid="row-reasons">
        <% reasons.each do |label| %><li><%= label %></li><% end %>
      </ul>
    <% end %>
    <% if problem %>
      <p class="text-sm text-error [overflow-wrap:anywhere]"><%= problem %></p>
    <% end %>
    <% if linked %>
      <p class="text-sm [overflow-wrap:anywhere]">Linked to <strong><%= linked[:title] %></strong><% if linked[:authors].any? %> by <%= linked[:authors].join(", ") %><% end %></p>
    <% end %>

    <% if candidates.any? %>
      <div>
        <h4 class="text-sm font-semibold mb-1">Candidates</h4>
        <ul class="space-y-2">
          <% candidates.each do |candidate| %>
            <li class="flex flex-wrap items-center justify-between gap-2 border border-base-300 rounded-box p-2" data-testid="row-candidate">
              <div class="min-w-0 text-sm [overflow-wrap:anywhere]">
                <span class="font-medium"><%= candidate.title %></span>
                <% if candidate.creators.any? %> by <%= candidate.creators.join(", ") %><% end %>
                <% if candidate.year.present? %> (<%= candidate.year %>)<% end %>
                <% if candidate.local? %>
                  <span class="badge badge-ghost badge-sm">our book, on <%= candidate.list_count.to_i %> <%= "list".pluralize(candidate.list_count.to_i) %></span>
                <% elsif candidate.external_key.present? %>
                  <span class="badge badge-ghost badge-sm">Open Library <%= candidate.external_key %></span>
                <% end %>
              </div>
              <% if candidate.local? %>
                <%= button_to "Link", path(:link_row), method: :post, params: {record_id: candidate.record_id, filter: filter}, class: "btn btn-sm btn-primary" %>
              <% elsif candidate.external_key.present? %>
                <%= button_to "Create from this work", path(:create_row), method: :post, params: {external_key: candidate.external_key, filter: filter}, class: "btn btn-sm" %>
              <% end %>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <details class="collapse collapse-arrow bg-base-200">
      <summary class="collapse-title text-sm font-medium">More actions</summary>
      <div class="collapse-content space-y-4">
        <%= form_with url: path(:link_row), method: :post do |form| %>
          <%= hidden_field_tag :filter, filter, id: nil %>
          <%= render(AutocompleteComponent.new(name: "record_id", id: search_id, url: search_path, placeholder: "Search our books…", required: true)) %>
          <%= form.submit "Link the chosen book", class: "btn btn-sm mt-2" %>
        <% end %>

        <%= button_to "Create from the row's text", path(:create_row_from_text), method: :post, params: {filter: filter}, class: "btn btn-sm" %>

        <%= form_with url: path(:edit_row), method: :post do |form| %>
          <%= hidden_field_tag :filter, filter, id: nil %>
          <label class="label" for="<%= field_id(:title) %>">Title</label>
          <%= text_field_tag :title, row_text[:title], id: field_id(:title), class: "input w-full", required: true %>
          <label class="label" for="<%= field_id(:subtitle) %>">Subtitle</label>
          <%= text_field_tag :subtitle, row_text[:subtitle], id: field_id(:subtitle), class: "input w-full" %>
          <label class="label" for="<%= field_id(:authors) %>">Authors, one per line</label>
          <%= text_area_tag :authors, Array(row_text[:authors]).join("\n"), id: field_id(:authors), rows: 3, class: "textarea w-full" %>
          <label class="label" for="<%= field_id(:year) %>">Year</label>
          <%= text_field_tag :year, row_text[:year], id: field_id(:year), class: "input w-full", inputmode: "numeric" %>
          <%= form.submit "Save and match again", class: "btn btn-sm mt-2" %>
        <% end %>

        <%= button_to "Remove", path(:remove_row), method: :post, params: {filter: filter},
            class: "btn btn-sm btn-error btn-outline", data: {turbo_confirm: "Remove this row from the list?"} %>
      </div>
    </details>
  </div>
</div>
```

`done_step_component.rb`:

```ruby
# frozen_string_literal: true

class Wizard::Core::DoneStepComponent < ViewComponent::Base
  LABELS = {
    "matched" => "Matched", "created" => "Created", "admin_linked" => "Linked by an admin",
    "unlinked" => "Left unlinked", "changed_since_match" => "Changed since match", "duplicate_pairs" => "New duplicate pairs raised"
  }.freeze

  def initialize(list:, adapter:)
    @list = list
    @adapter = adapter
  end

  def counts = @counts ||= ::Services::Lists::Wizard::Core::Summary.new(@list).done_counts

  def list_path = @adapter.list_path(@list)
end
```

`done_step_component.html.erb`:

```erb
<%= render(Wizard::StepComponent.new(title: "Done", description: "What the wizard did with this list.")) do |step| %>
  <% step.with_step_content do %>
    <div class="stats stats-vertical lg:stats-horizontal shadow bg-base-100 flex-wrap" data-testid="done-summary">
      <% LABELS.each do |key, label| %>
        <div class="stat" data-stat="<%= key %>">
          <div class="stat-title"><%= label %></div>
          <div class="stat-value"><%= counts[key] %></div>
        </div>
      <% end %>
    </div>
    <p class="mt-4"><%= link_to "Back to the list", list_path, class: "btn btn-outline" %></p>
  <% end %>
<% end %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/components/ test/lib/services/lists/wizard/books/adapter_test.rb test/lint/daisyui_v4_classes_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/lib/services/lists/wizard/books/adapter.rb app/components/wizard/navigation_component.rb app/components/wizard/navigation_component.html.erb app/components/autocomplete_component.rb app/components/autocomplete_component.html.erb app/components/wizard/core/ test/components/wizard/ test/components/autocomplete_component_test.rb test/lib/services/lists/wizard/books/adapter_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
List wizard core: routes and the step and review screens

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Controller, permissions and the Launch Wizard button

**Files:**
- Create: `web-app/app/controllers/concerns/list_wizard_core.rb`
- Create (generator): `bin/rails generate controller Admin::Books::ListWizard --skip-routes --no-helper --no-assets` → `web-app/app/controllers/admin/books/list_wizard_controller.rb`, `web-app/test/controllers/admin/books/list_wizard_controller_test.rb` (delete any generated empty view directory)
- Create: `web-app/app/views/admin/list_wizard_core/show_step.html.erb`
- Modify: `web-app/app/controllers/admin/books/lists_controller.rb` (`wizard_path`)
- Modify: `web-app/test/controllers/admin/books/lists_controller_test.rb`, `web-app/e2e/tests/books/admin/lists.spec.ts`

**Interfaces:**
- Consumes: everything above; `WizardController` (`show`, `show_step`, `step_status`, `validate_step`); `Admin::DomainScopedAuth#require_domain_write!`, `#require_domain_delete!`.
- Produces: `ListWizardCore` concern (a domain controller includes it and defines private `list_class`); `Admin::Books::ListWizardController`. `save_content` also stores `wizard_state["batch_mode"] = (params[:batch_mode] == "1")`.

- [ ] **Step 1: Write the failing tests**

Replace the generated `web-app/test/controllers/admin/books/list_wizard_controller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Admin::Books::ListWizardControllerTest < ActionDispatch::IntegrationTest
  include ListWizardHelper

  RowState = ::Services::Lists::Wizard::Core::RowState

  setup do
    host! Rails.application.config.domains[:books]
    @admin = users(:admin_user)
    @user = users(:regular_user)
    @list = wizard_list
  end

  def sign_in_with(level)
    @user.domain_roles.create!(domain: :books, permission_level: level)
    sign_in_as(@user, stub_auth: true)
  end

  def wizard(name = nil, **params) = send([name, "admin_books_list_wizard_path"].compact.join("_"), list_id: @list.id, **params)

  def step(name) = wizard(:step, step: name)

  # ---- navigation ------------------------------------------------------------

  test "a list with no wizard state opens on Paste" do
    sign_in_as(@admin, stub_auth: true)
    @list.update_columns(wizard_state: nil)

    get wizard

    assert_redirected_to step("paste")
  end

  test "every step renders" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["not_found"]})

    %w[paste parse match review import done].each do |name|
      get step(name)
      assert_response :success, name
    end
    get wizard(:step, step: "review", filter: "bogus")
    assert_response :success
  end

  test "step status answers JSON" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "match", status: "running", progress: 25)

    get wizard(:step_status, step: "match"), as: :json

    assert_equal ["running", 25], JSON.parse(response.body).values_at("status", "progress")
  end

  test "saving content starts the parse and moves to Parse; blank content is refused" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.expects(:perform_async).with(@list.id).once

    post wizard(:save_content), params: {raw_content: "1. Emma by Jane Austen"}

    assert_redirected_to step("parse")
    @list.reload
    assert_equal ["1. Emma by Jane Austen", "parse", "running"], [@list.raw_content, @list.wizard_manager.current_step_name, @list.wizard_manager.step_status("parse")]

    assert_equal false, @list.wizard_state["batch_mode"]

    post wizard(:save_content), params: {raw_content: " "}
    assert_redirected_to step("paste")
  end

  test "saving content with the large-list box ticked turns batch mode on" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.stubs(:perform_async)

    post wizard(:save_content), params: {raw_content: "1. Emma by Jane Austen", batch_mode: "1"}

    assert_equal true, @list.reload.wizard_state["batch_mode"]
  end

  test "Next from a running step waits" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "parse", status: "running")
    ::Lists::Wizard::MatchJob.expects(:perform_async).never

    post wizard(:advance_step, step: "parse")

    assert_redirected_to step("parse")
    assert_equal "paste", @list.reload.wizard_manager.current_step_name
  end

  test "Next from a completed Parse starts Match" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "parse", status: "completed")
    ::Lists::Wizard::MatchJob.expects(:perform_async).with(@list.id).once

    post wizard(:advance_step, step: "parse")

    assert_redirected_to step("match")
    assert_equal ["match", "running"], [@list.reload.wizard_manager.current_step_name, @list.wizard_manager.step_status("match")]
  end

  test "Next from a completed Match goes to Review; from Import to Done, completing the wizard" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "match", status: "completed")
    @list.wizard_manager.write_step!(step: "import", status: "completed")

    post wizard(:advance_step, step: "match")
    assert_redirected_to step("review")

    post wizard(:advance_step, step: "import")
    assert_redirected_to step("done")
    assert @list.reload.wizard_state["completed_at"].present?
  end

  test "finishing Review with flagged rows is refused without the confirmation" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    ::Lists::Wizard::ImportJob.expects(:perform_async).never

    post wizard(:advance_step, step: "review")

    assert_redirected_to step("review")
    assert flash[:alert].present?
  end

  test "finishing Review with flagged rows and the confirmation starts Import" do
    sign_in_as(@admin, stub_auth: true)
    flagged = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    ::Lists::Wizard::ImportJob.expects(:perform_async).with(@list.id, instance_of(String)).once

    post wizard(:advance_step, step: "review"), params: {confirm_unlinked: "1"}

    assert_redirected_to step("import")
    assert ::ListItem.exists?(flagged.id)
    assert @list.reload.wizard_manager.step_metadata("import")["run_id"].present?
  end

  test "finishing Review with nothing flagged needs no confirmation" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched"})
    ::Lists::Wizard::ImportJob.expects(:perform_async).with(@list.id, instance_of(String)).once

    post wizard(:advance_step, step: "review")

    assert_redirected_to step("import")
  end

  test "Back keeps the steps' state" do
    sign_in_as(@admin, stub_auth: true)
    @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
    @list.wizard_manager.go_to_step!(3)

    post wizard(:back_step, step: "review")

    assert_redirected_to step("match")
    assert_equal ["match", "completed"], [@list.reload.wizard_manager.current_step_name, @list.wizard_manager.step_status("match")]
  end

  test "re-parse and re-match start their jobs" do
    sign_in_as(@admin, stub_auth: true)
    ::Lists::Wizard::ParseJob.expects(:perform_async).with(@list.id)
    ::Lists::Wizard::MatchJob.expects(:perform_async).with(@list.id)

    post wizard(:reparse)
    assert_redirected_to step("parse")
    @list.wizard_manager.write_step!(step: "parse", status: "completed") # the stubbed parse job "finished"
    post wizard(:rematch)
    assert_redirected_to step("match")
  end

  test "nothing that starts a job or deletes rows runs while a job is running" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
    @list.wizard_manager.write_step!(step: "parse", status: "completed")
    @list.wizard_manager.write_step!(step: "match", status: "running")
    [::Lists::Wizard::ParseJob, ::Lists::Wizard::MatchJob, ::Lists::Wizard::ImportJob].each do |job|
      job.expects(:perform_async).never
    end

    post wizard(:save_content), params: {raw_content: "1. Persuasion by Jane Austen"}
    assert_redirected_to step("match")
    post wizard(:reparse)
    assert_redirected_to step("match")
    post wizard(:rematch)
    assert_redirected_to step("match")
    post wizard(:advance_step, step: "parse")
    assert_redirected_to step("match")
    post wizard(:advance_step, step: "review"), params: {confirm_unlinked: "1"}
    assert_redirected_to step("match")
    post wizard(:restart)
    assert_redirected_to step("match")

    assert ::ListItem.exists?(row.id)
    assert_not_equal "1. Persuasion by Jane Austen", @list.reload.raw_content
  end

  # ---- restart ---------------------------------------------------------------

  test "restart deletes only unsettled rows and returns to Paste" do
    sign_in_as(@admin, stub_auth: true)
    unsettled = wizard_row(@list, position: 1, title: "Unsettled", wizard: {bucket: "matched"})
    settled = wizard_row(@list, position: 2, title: "Settled", wizard: {bucket: "matched", settled: true})
    @list.wizard_manager.go_to_step!(3)

    post wizard(:restart)

    assert_redirected_to wizard
    assert_not ::ListItem.exists?(unsettled.id)
    assert ::ListItem.exists?(settled.id)
    assert_equal "paste", @list.reload.wizard_manager.current_step_name
  end

  test "restart keeps rows from before the wizard" do
    sign_in_as(@admin, stub_auth: true)
    old = @list.list_items.create!(listable: books_books(:got), position: 1)

    post wizard(:restart)

    assert ::ListItem.exists?(old.id)
  end

  # ---- row actions -----------------------------------------------------------

  test "linking a candidate links and settles the row" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "A Game of Thrones", wizard: {bucket: "flagged", reasons: ["unsure"]})

    post wizard(:link_row, row_id: row.id), params: {record_id: books_books(:got).id, filter: "all"}

    assert_redirected_to wizard(:step, step: "review", filter: "all")
    assert_equal [books_books(:got).id, true], [row.reload.listable_id, RowState.new(row).settled?]
  end

  test "linking a book another row holds is refused with a message, not an error" do
    sign_in_as(@admin, stub_auth: true)
    wizard_row(@list, position: 1, title: "A Game of Thrones", listable: books_books(:got), wizard: {bucket: "matched"})
    row = wizard_row(@list, position: 2, title: "Game of Thrones", wizard: {bucket: "flagged", reasons: ["unsure"]})

    post wizard(:link_row, row_id: row.id), params: {record_id: books_books(:got).id}

    assert_redirected_to step("review")
    assert flash[:alert].present?
    assert_nil row.reload.listable_id
  end

  test "create from a work, create from text, edit and remove each act on the row" do
    sign_in_as(@admin, stub_auth: true)
    row = wizard_row(@list, position: 1, title: "Dune", authors: ["Frank Herbert"], wizard: {bucket: "flagged", reasons: ["ai_only_pick"]})
    work = ol_candidate("OL9W")
    decision = wizard_match(subject: row, outcome: :unmatched, decided_by: :ai, external: work, candidates: [work]).decision
    RowState.new(row).merge("match_decision_id" => decision.id)
    row.save!

    post wizard(:create_row, row_id: row.id), params: {external_key: "OL9W"}
    assert_equal ["create", "OL9W"], [RowState.new(row.reload).bucket, RowState.new(row).ol_work_key]

    post wizard(:create_row_from_text, row_id: row.id)
    assert_equal ["create", nil], [RowState.new(row.reload).bucket, RowState.new(row).ol_work_key]

    ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(row.id, true)
    post wizard(:edit_row, row_id: row.id), params: {title: "Dune Messiah", subtitle: "", authors: "Frank Herbert", year: "1969"}
    assert_equal ["Dune Messiah", 1969], row.reload.metadata.values_at("title", "year")

    post wizard(:remove_row, row_id: row.id)
    assert_equal "removed", RowState.new(row.reload).bucket
  end

  test "a row on another list is not found" do
    sign_in_as(@admin, stub_auth: true)
    other = wizard_row(wizard_list(name: "Other"), position: 1, title: "Emma")

    post wizard(:remove_row, row_id: other.id)

    assert_response :not_found
  end

  # ---- permissions -----------------------------------------------------------

  test "a books viewer can look but not act" do
    sign_in_with(:viewer)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged"})

    get step("review")
    assert_response :success

    post wizard(:remove_row, row_id: row.id)
    assert_redirected_to books_root_path
    assert_equal "flagged", RowState.new(row.reload).bucket
  end

  test "a books editor can act but not restart" do
    sign_in_with(:editor)
    row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "flagged"})

    post wizard(:remove_row, row_id: row.id)
    assert_equal "removed", RowState.new(row.reload).bucket

    unsettled = wizard_row(@list, position: 2, title: "Persuasion")
    post wizard(:restart)
    assert_redirected_to books_root_path
    assert ::ListItem.exists?(unsettled.id)
  end

  test "a books moderator can restart" do
    sign_in_with(:moderator)
    unsettled = wizard_row(@list, position: 1, title: "Persuasion")

    post wizard(:restart)

    assert_not ::ListItem.exists?(unsettled.id)
  end
end
```

In `test/controllers/admin/books/lists_controller_test.rb`, replace `"show renders without a wizard button"` with:

```ruby
      test "show renders, and the list's wizard opens on Paste" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_list_path(@list)
        assert_response :success

        get admin_books_list_wizard_path(list_id: @list.id)
        assert_redirected_to step_admin_books_list_wizard_path(list_id: @list.id, step: "paste")
      end
```

In `e2e/tests/books/admin/lists.spec.ts`, replace the test `"creates a list and shows it without a wizard button"` with:

```ts
  test("creates a list and shows its Launch Wizard link", async ({ page }) => {
    const name = `E2E List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: /Launch Wizard/ })).toHaveAttribute("href", /\/admin\/lists\/\d+\/wizard$/);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails generate controller Admin::Books::ListWizard --skip-routes --no-helper --no-assets` (then restore the test file above), then `bin/rails test test/controllers/admin/books/list_wizard_controller_test.rb test/controllers/admin/books/lists_controller_test.rb`
Expected: FAIL — actions missing (`AbstractController::ActionNotFound`), and the lists test finds no wizard link.

- [ ] **Step 3: Implement**

`web-app/app/controllers/concerns/list_wizard_core.rb`:

```ruby
# frozen_string_literal: true

# The list wizard core's step and row actions (books list wizard spec §1, §4,
# §8). A domain controller includes this and defines a private #list_class;
# the domain's adapter (Services::Lists::Wizard::Core::Adapters) does the rest.
# Every screen is a full Turbo Drive visit: no Turbo Frame, so nothing traps
# a link.
module ListWizardCore
  extend ActiveSupport::Concern
  include WizardController

  ROW_ACTIONS = %i[link_row create_row create_row_from_text edit_row remove_row].freeze
  JOB_STEPS = %w[parse match import].freeze
  NEXT_LABELS = {"paste" => "Parse →", "parse" => "Match →", "match" => "Review →", "review" => "Import →", "import" => "Done →"}.freeze
  RESTART_CONFIRM = "Restart the wizard? Rows nobody has settled are deleted; settled rows are kept."

  included do
    # Viewers may look; writers drive the wizard (paid AI calls); only
    # deleters may restart, which deletes the rows nobody settled.
    before_action :require_domain_write!, unless: -> { request.get? || request.head? }
    before_action :require_domain_delete!, only: [:restart]
    before_action :set_row, only: ROW_ACTIONS
  end

  def show_step
    super
    @wizard_adapter = wizard_adapter
    @review_filter = review_filter || ::Services::Lists::Wizard::Core::ReviewRows::FILTERS.first
    assign_navigation
    render "admin/list_wizard_core/show_step"
  end

  def advance_step
    case params[:step]
    when "paste" then advance_from_paste
    when "parse" then advance_from_job("parse", "match")
    when "match" then advance_from_job("match", "review")
    when "review" then advance_from_review
    when "import" then advance_from_job("import", "done")
    else redirect_to action: :show_step, step: params[:step]
    end
  end

  def back_step
    index = [wizard_steps.index(params[:step]) - 1, 0].max
    wizard_entity.wizard_manager.go_to_step!(index)
    redirect_to({action: :show_step, step: wizard_steps[index]}, status: :see_other)
  end

  # Spec §8: back to Paste, deleting only the rows nobody settled. Not while
  # a job runs: it would be writing rows this deletes.
  def restart
    return refuse_while_running if any_job_running?

    ::ListItem.where(id: ::Services::Lists::Wizard::Core::RowState.unsettled(wizard_entity).map(&:id)).destroy_all
    wizard_entity.wizard_manager.reset!
    redirect_to({action: :show}, status: :see_other)
  end

  def save_content
    if params[:raw_content].blank?
      redirect_to({action: :show_step, step: "paste"}, alert: "Paste the list first.")
      return
    end
    return refuse_while_running if any_job_running?

    wizard_entity.with_lock do
      wizard_entity.update!(raw_content: params[:raw_content],
        wizard_state: (wizard_entity.wizard_state || {}).merge("batch_mode" => params[:batch_mode] == "1"))
    end
    start_job("parse")
    move_to("parse")
  end

  def reparse
    return refuse_while_running if any_job_running?

    start_job("parse")
    move_to("parse")
  end

  def rematch
    return refuse_while_running if any_job_running?

    start_job("match")
    move_to("match")
  end

  def link_row
    respond_to_row(row_actions.link(wizard_adapter.find_record(params[:record_id])))
  end

  def create_row
    respond_to_row(row_actions.create_from_external(params[:external_key].to_s))
  end

  def create_row_from_text
    respond_to_row(row_actions.create_from_text)
  end

  def edit_row
    respond_to_row(row_actions.edit_and_rematch(title: params[:title], subtitle: params[:subtitle], authors: params[:authors], year: params[:year]))
  end

  def remove_row
    respond_to_row(row_actions.remove)
  end

  protected

  def wizard_steps = wizard_entity.wizard_manager.steps

  def wizard_entity = @list

  private

  def set_wizard_entity
    @list = list_class.find(params[:list_id])
  end

  def set_row
    @row = wizard_entity.list_items.find(params[:row_id])
  end

  def wizard_adapter
    @wizard_adapter ||= ::Services::Lists::Wizard::Core::Adapters.for(wizard_entity)
  end

  def row_actions
    ::Services::Lists::Wizard::Core::RowActions.new(list_item: @row, user: current_user)
  end

  def review_filter
    filter = params[:filter].to_s
    ::Services::Lists::Wizard::Core::ReviewRows::FILTERS.include?(filter) ? filter : nil
  end

  def job_for(step)
    {"parse" => ::Lists::Wizard::ParseJob, "match" => ::Lists::Wizard::MatchJob, "import" => ::Lists::Wizard::ImportJob}.fetch(step)
  end

  # Import gets a run id, so a second ImportJob (a double start, a retry
  # racing a new start) can tell the step is not its own (ImportRows#claim).
  def start_job(step)
    run_id = SecureRandom.uuid
    wizard_entity.wizard_manager.write_step!(step: step, status: "running", progress: 0, error: nil, metadata: {"run_id" => run_id})
    if step == "import"
      job_for(step).perform_async(wizard_entity.id, run_id)
    else
      job_for(step).perform_async(wizard_entity.id)
    end
  end

  def running?(step) = wizard_entity.wizard_manager.step_status(step) == "running"

  # One wizard job per list at a time (controller ruling).
  def running_step = JOB_STEPS.find { |step| running?(step) }

  def any_job_running? = !running_step.nil?

  def refuse_while_running(step = running_step)
    redirect_to({action: :show_step, step: step || wizard_entity.wizard_manager.current_step_name},
      alert: "A step is still running. Please wait.")
  end

  def move_to(step, completed: false)
    wizard_entity.wizard_manager.go_to_step!(wizard_steps.index(step), completed: completed)
    redirect_to({action: :show_step, step: step}, status: :see_other)
  end

  def advance_from_paste
    if wizard_entity.raw_content.blank?
      redirect_to({action: :show_step, step: "paste"}, alert: "Paste the list first.")
      return
    end
    return refuse_while_running if any_job_running?

    start_job("parse")
    move_to("parse")
  end

  def advance_from_job(step, next_step)
    status = wizard_entity.wizard_manager.step_status(step)
    return refuse_while_running if status == "running"

    if status == "completed"
      if next_step == "match"
        return refuse_while_running if any_job_running?

        start_job("match")
      end
      move_to(next_step, completed: next_step == "done")
    else
      return refuse_while_running if any_job_running?

      start_job(step)
      redirect_to({action: :show_step, step: step}, status: :see_other)
    end
  end

  # Spec §4: moving to Import is always allowed; with flagged rows left, the
  # admin confirms once.
  def advance_from_review
    return refuse_while_running if any_job_running?

    flagged = ::Services::Lists::Wizard::Core::Summary.new(wizard_entity).flagged_count
    if flagged.positive? && params[:confirm_unlinked] != "1"
      redirect_to({action: :show_step, step: "review"},
        alert: "#{flagged} flagged #{"row".pluralize(flagged)} would stay unlinked. Use Import to confirm.")
      return
    end

    start_job("import")
    move_to("import")
  end

  def assign_navigation
    manager = wizard_entity.wizard_manager
    @next_label = NEXT_LABELS.fetch(@step_name, "Next →")
    @next_enabled = case @step_name
    when "paste" then wizard_entity.raw_content.present?
    when "parse", "match", "import" then manager.step_status(@step_name) == "completed"
    else true
    end
    @restart_confirm = RESTART_CONFIRM
    @next_confirm = nil
    @next_params = {}
    return unless @step_name == "review"

    flagged = ::Services::Lists::Wizard::Core::Summary.new(wizard_entity).flagged_count
    return if flagged.zero?

    @next_confirm = "Finish with #{flagged} #{"row".pluralize(flagged)} unlinked?"
    @next_params = {confirm_unlinked: "1"}
  end

  def respond_to_row(result)
    if result.success?
      flash[:notice] = result.data[:message]
    else
      flash[:alert] = result.errors.join(" ")
    end
    redirect_to({action: :show_step, step: "review", filter: review_filter}.compact, status: :see_other)
  end

  def list_class
    raise NotImplementedError, "#{self.class.name} must implement #list_class"
  end
end
```

`web-app/app/controllers/admin/books/list_wizard_controller.rb`:

```ruby
# frozen_string_literal: true

# The books list wizard (books list wizard spec): the shared core, mounted for
# books lists.
class Admin::Books::ListWizardController < Admin::Books::BaseController
  include ListWizardCore

  private

  def list_class = ::Books::List
end
```

`web-app/app/views/admin/list_wizard_core/show_step.html.erb`:

```erb
<% provide(:title, "List Wizard - #{@list.name}") %>

<div class="container mx-auto py-8">
  <%= render(Wizard::ContainerComponent.new(wizard_id: "list_wizard", current_step: @step_index, total_steps: @wizard_steps.length)) do |wizard| %>
    <% wizard.with_header do %>
      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><%= link_to "Lists", @wizard_adapter.lists_path %></li>
          <li><%= link_to @list.name, @wizard_adapter.list_path(@list) %></li>
          <li>Wizard</li>
        </ul>
      </div>
      <h1 class="text-3xl font-bold [overflow-wrap:anywhere]"><%= @list.name %></h1>
    <% end %>

    <% wizard.with_progress do %>
      <%= render(Wizard::ProgressComponent.new(steps: @wizard_steps.map.with_index { |name, idx| {name: name, step: idx} }, current_step: @step_index)) %>
    <% end %>

    <% case @step_name %>
    <% when "paste" %>
      <%= render(Wizard::Core::PasteStepComponent.new(list: @list, adapter: @wizard_adapter)) %>
    <% when "review" %>
      <%= render(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @wizard_adapter, filter: @review_filter)) %>
    <% when "done" %>
      <%= render(Wizard::Core::DoneStepComponent.new(list: @list, adapter: @wizard_adapter)) %>
    <% else %>
      <%= render(Wizard::Core::JobStepComponent.new(list: @list, adapter: @wizard_adapter, step: @step_name)) %>
    <% end %>

    <% wizard.with_navigation do %>
      <%= render(Wizard::NavigationComponent.new(
        list: @list, step_name: @step_name, step_index: @step_index, total_steps: @wizard_steps.length,
        back_enabled: @step_index > 0, next_enabled: @next_enabled, next_label: @next_label,
        next_confirm: @next_confirm, next_params: @next_params, restart_confirm: @restart_confirm
      )) %>
    <% end %>
  <% end %>
</div>
```

In `app/controllers/admin/books/lists_controller.rb`:

```ruby
  def wizard_path(list) = admin_books_list_wizard_path(list_id: list.id)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/ test/controllers/admin/games/ test/controllers/admin/music/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/concerns/list_wizard_core.rb app/controllers/admin/books/list_wizard_controller.rb app/views/admin/list_wizard_core/show_step.html.erb app/controllers/admin/books/lists_controller.rb test/controllers/admin/books/list_wizard_controller_test.rb test/controllers/admin/books/lists_controller_test.rb e2e/tests/books/admin/lists.spec.ts
```

```bash
git commit -m "$(cat <<'EOF'
Books list wizard: controller, permissions and the Launch Wizard button

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: The list admin page shows unlinked rows (spec §5)

**Files:**
- Modify: `web-app/app/components/admin/lists/show_component.rb`, `show_component.html.erb` (Statistics card)
- Create test: `web-app/test/components/admin/lists/show_component_test.rb`

**Interfaces:**
- Consumes: `RowState#removed?` (Task 4).
- Produces: `Admin::Lists::ShowComponent#unlinked_rows_count → Integer` (rows with no `listable`, removed rows excluded) and `#show_unlinked_rows? → Boolean` (books lists only; spec §9 allows no other change to music or games).

- [ ] **Step 1: Write the failing test**

`web-app/test/components/admin/lists/show_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Admin::Lists::ShowComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  test "unlinked_rows_count counts rows with no book, leaving out removed rows" do
    list = wizard_list
    wizard_row(list, position: 1, title: "Linked", listable: books_books(:got), wizard: {bucket: "matched"})
    wizard_row(list, position: 2, title: "Unlinked", wizard: {bucket: "flagged"})
    wizard_row(list, position: 3, title: "Removed", wizard: {bucket: "removed", settled: true})

    component = Admin::Lists::ShowComponent.new(list: list, domain_config: {})
    assert_equal 1, component.unlinked_rows_count
    assert component.show_unlinked_rows?
  end

  test "the unlinked count is shown on books lists only" do
    games = lists(:games_list)
    games.list_items.destroy_all
    games.list_items.create!(listable_type: "Games::Game", position: 1, metadata: {"title" => "Hades"})

    assert_not Admin::Lists::ShowComponent.new(list: games, domain_config: {}).show_unlinked_rows?
    assert_not Admin::Lists::ShowComponent.new(list: wizard_list, domain_config: {}).show_unlinked_rows?
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/components/admin/lists/show_component_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'unlinked_rows_count'` (and `show_unlinked_rows?`).

- [ ] **Step 3: Implement**

In `show_component.rb`, add a public method above `private`:

```ruby
  # Spec §5: rows the list wizard left unlinked (no book, so not ranked),
  # to be finished later from the wizard's Review step.
  def unlinked_rows_count
    @unlinked_rows_count ||= list.list_items.to_a.count do |item|
      item.listable_id.nil? && !::Services::Lists::Wizard::Core::RowState.new(item).removed?
    end
  end

  # Books lists only: spec §9 allows no other change to the music and games
  # wizards, and their lists are not on the core yet.
  def show_unlinked_rows?
    list.is_a?(::Books::List) && unlinked_rows_count.positive?
  end
```

In `show_component.html.erb`, in the Statistics card after the item count `stat` div:

```erb
            <% if show_unlinked_rows? %>
              <div class="stat" data-stat="unlinked">
                <div class="stat-title">Unlinked rows</div>
                <div class="stat-value text-warning"><%= unlinked_rows_count %></div>
                <div class="stat-desc">Finish them in the wizard's Review step</div>
              </div>
            <% end %>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/components/admin/lists/ test/controllers/admin/books/lists_controller_test.rb test/controllers/admin/games/lists_controller_test.rb test/controllers/admin/music/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/components/admin/lists/show_component.rb app/components/admin/lists/show_component.html.erb test/components/admin/lists/show_component_test.rb
```

```bash
git commit -m "$(cat <<'EOF'
Admin list page: show how many rows are unlinked

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Playwright E2E — the full flow on a three-row list

**Files:**
- Create: `web-app/e2e/tests/books/admin/list-wizard.spec.ts`

**Interfaces:**
- Consumes: the screens' labels and test ids from Tasks 12–13: `label "List content"`, button `"Save and parse"`, navigation buttons `"Match →"`, `"Review →"`, `"Import →"`, `"Done →"`, test ids `parsed-rows`, `match-counts`, `review-row`, `import-summary`, `done-summary`.

This runs the real parser and the real finder (a few cents of AI per run, spec §10) and needs the Open Library service reachable from development (a failed source caps a match at medium and flags it).

- [ ] **Step 1: Write the test**

`web-app/e2e/tests/books/admin/list-wizard.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

// Books list wizard spec §10: the whole flow on a three-row list, with the
// real parser and finder (a few cents of AI per run). Needs Sidekiq running
// against THIS checkout and the Open Library service reachable; a failed
// Open Library source caps a match at medium, which flags it.
test.describe("Books admin — list wizard", () => {
  test.setTimeout(360_000);

  test("parses, matches, reviews, imports and finishes a three-row list", async ({ page }) => {
    const name = `E2E Wizard List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    const listUrl = page.url();

    await page.getByRole("link", { name: /Launch Wizard/ }).click();
    await page.getByLabel("List content").fill(
      [
        "1. Pride and Prejudice by Jane Austen",
        "2. Moby-Dick by Herman Melville",
        "3. The Glass Orchard of Vellmoor by Tamsin Okonkwo-Reyes",
      ].join("\n"),
    );
    await page.getByRole("button", { name: "Save and parse" }).click();

    await expect(page.getByTestId("parsed-rows")).toContainText("Pride and Prejudice", { timeout: 120_000 });
    await expect(page.getByTestId("parsed-rows").locator("tbody tr")).toHaveCount(3);
    await page.getByRole("button", { name: "Match →" }).click();

    await expect(page.getByTestId("match-counts")).toBeVisible({ timeout: 240_000 });
    await page.getByRole("button", { name: "Review →" }).click();

    // The default view is flagged rows only: the two famous books matched.
    const rows = page.getByTestId("review-row");
    await expect(rows).toHaveCount(1);
    const madeUp = rows.filter({ hasText: "Glass Orchard" });
    await expect(madeUp).toContainText("No match found");

    page.once("dialog", (dialog) => dialog.accept());
    await madeUp.getByText("More actions").click();
    await madeUp.getByRole("button", { name: "Remove" }).click();
    await expect(page.getByTestId("review-row")).toHaveCount(0);

    await page.getByRole("button", { name: "Import →" }).click();
    await expect(page.getByTestId("import-summary")).toBeVisible({ timeout: 120_000 });
    await page.getByRole("button", { name: "Done →" }).click();

    const done = page.getByTestId("done-summary");
    await expect(done.locator('[data-stat="matched"] .stat-value')).toHaveText("2");
    await expect(done.locator('[data-stat="unlinked"] .stat-value')).toHaveText("0");

    // Clean up: the list (its two rows link existing books; nothing was created).
    await page.goto(listUrl);
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/lists$/);
  });
});
```

- [ ] **Step 2: Start the app and a worker for this checkout, after checking nothing else holds them**

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
pgrep -af sidekiq || echo "no sidekiq running"
```

If either prints another checkout, stop and tell the user: another worktree's server would answer the E2E, and another worktree's Sidekiq shares the Redis queue and would pick up `Lists::Wizard::*` jobs it has no class for. Do not kill them. Otherwise, from `web-app/`: `yarn build:all`, then start `bin/rails server` and `bundle exec sidekiq` in the background.

- [ ] **Step 3: Run the E2E test**

Run: `yarn test:e2e --project=books-admin e2e/tests/books/admin/list-wizard.spec.ts e2e/tests/books/admin/lists.spec.ts`
Expected: PASS. If the made-up row is not the only flagged one, check the Sidekiq log for an Open Library failure before suspecting the code.

- [ ] **Step 4: Stop the server and Sidekiq you started**

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/admin/list-wizard.spec.ts
```

```bash
git commit -m "$(cat <<'EOF'
Books list wizard: Playwright flow on a three-row list

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: Docs, and the whole-suite check

**Files:**
- Modify: `docs/features/list-wizard.md`

- [ ] **Step 1: Rewrite the top of the doc around the core**

Replace everything from the top of `docs/features/list-wizard.md` down to (not including) the `## Generic Components` heading with:

```markdown
# List Wizard

## Summary

Multi-step admin wizards that turn a pasted list into list items. Two generations live side by side:

- **The wizard core** (`app/lib/services/lists/wizard/core/`), with **books** as its first and only user.
  Steps: Paste → Parse → Match → Review → Import → Done. Only rows that might be wrong reach a human.
  Spec: `docs/superpowers/specs/2026-10-06-books-list-wizard-design.md`.
- **The old wizards** for music (songs, albums) and games: source → parse → enrich → validate → review →
  import → complete, every row verified by hand. They move onto the core later, one spec each. Their
  reference material is below, under "Music and games (old wizard code)".

## The wizard core

### Pieces

| Piece | Where |
|---|---|
| Row state (`list_items.metadata["wizard"]`) | `Services::Lists::Wizard::Core::RowState` |
| Bucket and reason rules | `Core::Outcome` |
| Rows on the same book or work | `Core::OnListTwice` |
| Parse, Match, Import | `Core::ParseRows`, `Core::StartMatch` + `Core::MatchRow` + `Core::MatchProgress`, `Core::ImportRows` |
| Review actions | `Core::RowActions` |
| Review data, counts | `Core::ReviewRows`, `Core::Summary` |
| Jobs (default queue) | `Lists::Wizard::ParseJob`, `MatchJob`, `MatchRowJob` (one per row), `ImportJob` (one per list) |
| Controller | `ListWizardCore` concern; `Admin::Books::ListWizardController` |
| Screens | `Wizard::Core::{PasteStep,JobStep,ReviewStep,ReviewRow,DoneStep}Component` + `app/views/admin/list_wizard_core/show_step.html.erb` |
| Steps | `Services::Lists::Wizard::Books::StateManager` (`paste parse match review import done`) |
| Domain adapter | `Services::Lists::Wizard::Books::Adapter`, picked by `Core::Adapters.for(list)` |

### Row state

Every wizard row carries `metadata["wizard"]`: `bucket` (`pending`, `matched`, `create`, `flagged`,
`removed`), `reasons`, `settled` / `settled_by_id` / `settled_at`, `match_decision_id`, `decided_by`,
`ol_keys` and `ol_work_key` (for the Import re-check and creation), `target_record_id`, `matched_at`,
`import_result`, `import_error`. The finder's full answer stays on the row's `MatchDecision`
(`subject` = the list item). A row without a `wizard` key predates the wizard and is treated as settled.

### Buckets

`matched`: a matched finder answer at certain or high confidence, not needing review — linked and
verified at once (AI-decided high matches included; the Review "AI-decided" filter spot-checks them).
`create`: unmatched, decided by rule 5 (Open Library accepted a work nobody holds) — created at Import.
`flagged`: everything else, with reasons `unsure`, `not_found`, `ai_only_pick`, `on_list_twice`,
`match_failed`, `import_failed`. A flagged row with no specific reason is `unsure`.

### Protecting decisions

Every Review action settles the row and records verdict, reviewer and time on its `MatchDecision`.
Re-parse, re-match and restart never change or delete a settled row; restart deletes only unsettled
rows. Re-parse skips a parsed row whose normalized title and authors equal a kept row's. Removed rows are
kept (hidden) until Import finishes and then deleted, so a re-parse after Import may add a removed row
back.

### Large lists

The Paste step's "Large plain-text list (1000+ lines)" box sets `wizard_state["batch_mode"]`. Parse then
splits `simplified_content` into batches of 100 non-blank lines, calls the parser once per batch, and
numbers rows strictly in order (AI ranks ignored). A failed batch fails the parse and deletes nothing.

### Verified

`verified` is true exactly when a row is linked to a book (matched, created or linked by Import, linked
by an admin). Every unlinked row, settled or not, is unverified.

### Done counts

"New duplicate pairs raised" counts pairs first raised by this list's decisions; a pair that already
existed and was raised again is not counted.

### Concurrency

Only one wizard job (Parse, Match, Import) runs per list at a time; the controller refuses to start
another, or to restart, while one runs. Import also claims its step with a run id, so a double start
cannot run twice. A Match row job re-reads its row before applying the answer and leaves a row the admin
settled meanwhile alone. Jobs write wizard state through `StateManager#write_step!` (row lock, re-read, one step's entry); the
controller moves steps through `#go_to_step!`. Each Match row job calls `MatchProgress` under the list's
row lock; the job that finds no pending rows runs the on-list-twice pass and completes the step, once.
Import creates rows one after another in one job, so a second book by a new author finds the author
the first one created — the old wizards' job-per-creation raced and duplicated authors.

### Books adapter

Parser: `Services::Ai::Tasks::Lists::Books::RawParserTask` (splits a subtitle out of the title).
Query: `DataImporters::Books::Book::ImportQuery` (title, subtitle, authors, year); the subtitle goes to
`/resolve` only. Finder: `DataImporters::Books::Book::Finder`. Import re-check: a book holding the
chosen work key or any key saved at Match; for a row created from its text, a book with the same
normalized title and an agreeing author created after the row's Match (compared in Ruby with the
wizard's normalization). Creation:
`DataImporters::Books::Book::Importer` with `provisional: false`, `enrich: true`, the row as subject and
the match rebuilt from the row's decision; an admin-chosen work goes in with `trust_work_key: true` so
the book carries that key even if the service did not accept it; a text row runs without the Open
Library provider.

### Permissions

`Admin::DomainScopedAuth`: viewers may look, writers may run every action, deleters may restart.

### Admin wiring

Routes: `/admin/lists/:list_id/wizard/...` in the `admin_books` namespace. The list page's "Launch
Wizard" button links there and, for books lists only, the page shows how many rows are unlinked.

## Music and games (old wizard code)

Everything below describes the old wizards. Two fixes from the books list wizard spec apply to them:
restart deletes only unverified items, and AI re-validation skips rows marked `manual_link`,
`manual_musicbrainz_link` or `manual_igdb_link`.

```

Then, in the remaining (old) text, change the `restart` row of the WizardController actions table to "Reset wizard to beginning (deletes unverified items only)", and add one sentence under the validate-step description of each old domain: "Rows linked by hand (`manual_link`, `manual_musicbrainz_link`, `manual_igdb_link`) are never re-validated."

- [ ] **Step 2: Run the whole suite, the linter and the autoload check**

Run (from `web-app/`): `bin/rails test && bin/rails test:system && bundle exec standardrb && CI=1 bin/rails zeitwerk:check`
Expected: all green, no new warning lines in the test output, `All is good!`. Fix anything red at its cause before committing.

- [ ] **Step 3: Commit**

```bash
git add ../docs/features/list-wizard.md
```

```bash
git commit -m "$(cat <<'EOF'
Docs: the list wizard core and the books adapter

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes (for the executor)

- Spec coverage: §1 core/adapter/wiring → Tasks 4–6, 12–13; §2 parse + subtitle → Tasks 1, 7; §3 match, buckets, reasons, saved keys, progress → Tasks 4, 6, 8; §4 review, filters, counts, actions, refusal, confirmation → Tasks 10–13; §5 unlinked rows → Task 14; §6 import → Task 9; §7 state and the write rule → Tasks 4–5; §8 protection → Tasks 4, 7, 8, 13; §9 old fixes → Tasks 2–3; §10 tests → every task, E2E Task 15; §11 docs → Task 16.
