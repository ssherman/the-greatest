# Record Merge — Increment 1: Games Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a games admin merge a duplicate game into another from the game's show page, transferring every association rather than destroying it, and gate the action on delete permission.

**Architecture:** A `Games::Game::Merger` service modelled on `Music::Album::Merger` — one transaction that moves associations, reconciles scalars, and destroys the source, with reindexing and ranking jobs scheduled after commit. A thin `Actions::Admin::Games::MergeGame` action wraps it, reached through a new `execute_action` route and a show-page modal. This increment also establishes the `execute_action` plumbing that increments 2 and 3 reuse, and corrects the music policies' permission gap.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, Pundit, Sidekiq, Turbo Streams, ViewComponents, DaisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-23-record-merge-design.md`

**Worktree:** `/home/shane/dev/the-greatest/.claude/worktrees/record-merge` — run everything from `web-app/` inside it.

## Global Constraints

- **Run all commands from `web-app/`.** Docs live at the project root, not `web-app/docs/`.
- **Root-anchor every namespaced constant** as `::Games::Game`, `::Books::Book` — in production code *and* test files. Inside `module Games`, a bare `Games::Game` resolves to the nested module and raises a confusing `NameError`.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. `--fix` autocorrects.
- **Never run `ActiveRecord::FixtureSet.create_fixtures`** — it truncates every table it names. To inspect a fixture, read the YAML.
- **Never run a destructive DB command against development.** Tests only, with `RAILS_ENV=test` explicit where relevant.
- **Check `ps aux | grep "[r]ails test"` before running the suite.** This worktree shares `the_greatest_test` with the main checkout; a concurrent run manufactures phantom failures.
- **Minitest is 6.x.** Use `assert_nil`, never `assert_equal nil` (a hard failure). No `assert_send`, no `minitest/mock`, no `MiniTest` namespace.
- **Sidekiq test mode is `:inline`**, set globally in `test_helper.rb`. Never `require "sidekiq/testing"`. Ranking jobs must be intercepted with Mocha or they really run.
- **Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. `keyword_init` is deliberate; a Standard cop is disabled for it.
- **A clean `bin/rails test` emits no warnings** beyond two known upstream sources. A new warning line is a regression — fix the cause.
- **daisyUI is 5.x.** These classes were removed and fail *silently*: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence; the fix is to remove the class, never to add an allowlist entry.
- **Commit freely on this branch.** Do not push or open a PR without asking.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `app/lib/games/game/merger.rb` | The whole merge operation for one game into another |
| `app/lib/actions/admin/games/merge_game.rb` | Admin action: validate form input, delegate to the merger, format the message |
| `test/lib/games/game/merger_test.rb` | Merger unit tests |
| `test/lib/actions/admin/games/merge_game_test.rb` | Action-class tests |
| `e2e/tests/games/admin/games-merge.spec.ts` | End-to-end merge flow |
| `docs/games/game_merger.md` | Service doc, per the project's documentation convention |

**Modify:**

| Path | Change |
|---|---|
| `config/routes.rb` | `member do post :execute_action end` on games `resources :games` |
| `app/controllers/admin/games/games_controller.rb` | `execute_action`; `:execute_action` in the two `before_action` lists; `exclude_id` in `search` |
| `app/policies/games/game_policy.rb` | `execute_action?` gated on `can_delete?` |
| `app/policies/music/album_policy.rb` | `execute_action?` → `can_delete?` |
| `app/policies/music/artist_policy.rb` | `execute_action?` → `can_delete?` |
| `app/policies/music/song_policy.rb` | `execute_action?` → `can_delete?` |
| `app/views/admin/games/games/show.html.erb` | Merge button + merge modal |
| `test/fixtures/users.yml` | Two users with domain-scoped games roles |
| `test/fixtures/domain_roles.yml` | Games editor and games moderator roles |
| `test/controllers/admin/games/games_controller_test.rb` | `execute_action` and `exclude_id` tests |
| `test/policies/music/*_policy_test.rb` | Assert the corrected gate (create if absent) |

---

## Verified context

Facts confirmed against the codebase; do not re-derive them.

- `Admin::BaseController` sets `layout "admin"`; `app/views/layouts/admin.html.erb:35` has `<div id="flash">`, and `app/views/admin/shared/_flash.html.erb` already handles a `result` local. The Turbo Stream response works for games with no layout changes.
- `current_user_can_delete?` is a `helper_method` on `Admin::BaseController` (available in all admin views). It returns true for global admins *and* global editors; the permission hole is specific to **domain-scoped** roles.
- `DomainRole` enums: `domain` = `{music: 0, games: 1, books: 2, movies: 3}`; `permission_level` = `{viewer: 0, editor: 1, moderator: 2, admin: 3}`.
- `User` enum: `role` = `[:user, :admin, :editor]` (user 0, admin 1, editor 2).
- `domain_roles.yml` currently holds only `music_editor` and `games_viewer`, both on `contractor_user`. The unique index `(user_id, domain)` means a second games role cannot be added to that user — new users are required.
- Games fixtures: `breath_of_the_wild` (series zelda), `resident_evil_4` (series resident_evil), `resident_evil_4_remake` (game_type 1, parent_game resident_evil_4), `half_life_2` (no series), `tears_of_the_kingdom` (series zelda).
- `ranked_items.yml` has a row for **all four** of BOTW, RE4, Half-Life 2, and TOTK. Every merger test must clear them in `setup` or the ranking jobs fire for real.
- Games polymorphic fixtures exist only on `breath_of_the_wild` (`descriptions`, `list_items`, `user_list_items`) and on `tears_of_the_kingdom` / `resident_evil_4` (`category_items`). There are **no** games rows in `identifiers.yml`, `images.yml`, or `external_links.yml` — those tests build rows inline.
- `Identifier.identifier_type` games values: `games_igdb_id: 400`, `games_rawg_id: 401`, `games_igdb_company_id: 410`.
- `Games::Game` has **no** `reviews`, `credits`, or `ai_chats`.

### One refinement to the spec

The spec calls for a parent/child cycle guard evaluated before the transaction opens. A cycle can only arise from **filling** `parent_game_id` from the source, so the guard lives in that fill step and simply declines to fill. Refusing to fill one optional field is strictly better than refusing an otherwise valid merge. Self-merge stays a pre-transaction guard as specified.

---

## Task 1: Merger spine

**Files:**
- Create: `app/lib/games/game/merger.rb`
- Test: `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `::Games::Game::Merger.call(source:, target:)` → `Result` responding to `success?`, `data`, `errors`. Private hooks later tasks fill in: `#merge_all_associations`, `#reconcile_scalars`, `#collect_affected_ranking_configurations`, `#reindex_target_game`, `#schedule_ranking_recalculation`. Public reader `#stats` → Hash.

- [ ] **Step 1: Write the failing test**

Create `test/lib/games/game/merger_test.rb`:

```ruby
require "test_helper"

module Games
  class Game
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = games_games(:half_life_2)
        @target = games_games(:breath_of_the_wild)

        # ranked_items.yml has rows for every game fixture; leaving them in place
        # makes the merger schedule real ranking jobs, which run inline in tests.
        RankedItem.where(item: @source).destroy_all
        RankedItem.where(item: @target).destroy_all
      end

      test "merges successfully and returns the target game" do
        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source game" do
        source_id = @source.id

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_not ::Games::Game.exists?(source_id)
      end

      test "refuses to merge a game with itself" do
        result = ::Games::Game::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge a game with itself"], result.errors
        assert ::Games::Game.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Games::Game::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Games::Game.exists?(@source.id), "source must survive a failed merge"
      end
    end
  end
end
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: `NameError: uninitialized constant Games::Game::Merger`.

- [ ] **Step 3: Write the minimal implementation**

Create `app/lib/games/game/merger.rb`:

```ruby
module Games
  class Game
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_game, :target_game, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_game = source
        @target_game = target
        @stats = {}
        @affected_ranking_configurations = []
      end

      def call
        if source_game.id == target_game.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge a game with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          collect_affected_ranking_configurations
          merge_all_associations
          reconcile_scalars
          target_game.save! if target_game.changed?
          destroy_source_game
        end

        reindex_target_game
        schedule_ranking_recalculation

        Result.new(success?: true, data: target_game, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      # Filled in by later tasks.
      def merge_all_associations
      end

      def reconcile_scalars
      end

      def collect_affected_ranking_configurations
      end

      def reindex_target_game
      end

      def schedule_ranking_recalculation
      end

      def destroy_source_game
        source_game.destroy!
      end
    end
  end
end
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: 4 runs, 0 failures.

- [ ] **Step 5: Verify the tests aren't vacuous**

Comment out the self-merge guard's `return`, re-run, and confirm "refuses to merge a game with itself" goes **red**. Restore it. Merger assertions pass against dead code unusually easily; this check is not optional.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git add app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git commit -m "feat(games): add Games::Game::Merger spine"
```

---

## Task 2: Identifiers, external links, images, category items

**Files:**
- Modify: `app/lib/games/game/merger.rb`
- Test: `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations` from Task 1.
- Produces: `stats[:identifiers]`, `stats[:external_links]`, `stats[:images]`, `stats[:category_items]` — all Integer.

- [ ] **Step 1: Write the failing tests**

Append inside the `MergerTest` class:

```ruby
test "moves identifiers the target does not already have" do
  identifier = Identifier.create!(
    identifiable: @source, identifier_type: :games_igdb_id, value: "111"
  )

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, identifier.reload.identifiable_id
end

test "drops a source identifier the target already has" do
  Identifier.create!(identifiable: @source, identifier_type: :games_igdb_id, value: "222")
  Identifier.create!(identifiable: @target, identifier_type: :games_igdb_id, value: "222")

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal 1, Identifier.where(
    identifiable: @target, identifier_type: :games_igdb_id, value: "222"
  ).count
end

test "moves external links" do
  link = ExternalLink.create!(
    parent: @source,
    name: "Wikipedia",
    url: "https://example.com/hl2",
    source: :wikipedia,
    link_category: :information
  )

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, link.reload.parent_id
end

test "demotes a moved image when the target already has a primary" do
  attach_image(@target, primary: true)
  source_image = attach_image(@source, primary: true)

  ::Games::Game::Merger.call(source: @source, target: @target)

  source_image.reload
  assert_equal @target.id, source_image.parent_id
  assert_not source_image.primary, "a second primary image would break primary_image"
end

test "keeps a moved image primary when the target has none" do
  source_image = attach_image(@source, primary: true)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert source_image.reload.primary
end

test "copies source categories the target lacks" do
  category = categories(:games_action_genre)
  CategoryItem.create!(category: category, item: @source)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_includes @target.reload.category_items.map(&:category_id), category.id
end

test "does not duplicate a category both games share" do
  category = categories(:games_action_genre)
  CategoryItem.create!(category: category, item: @source)
  CategoryItem.create!(category: category, item: @target)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal 1, CategoryItem.where(category: category, item: @target).count
end
```

`Image` validates `file` presence, and there are no games rows in `images.yml`, so add this helper
to the test class (the pattern is lifted from `test/lib/services/music/amazon_product_service_test.rb`):

```ruby
def attach_image(game, primary:)
  game.images.create!(primary: primary) do |image|
    image.file.attach(
      io: StringIO.new("fake image data"),
      filename: "cover.jpg",
      content_type: "image/jpeg"
    )
  end
end
```

`ExternalLink#source` and `#link_category` are enums with `prefix: true`; assignment by symbol still
works, but `source: :other` would additionally require `source_name`, so the test uses `:wikipedia`.

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: the seven new tests fail (associations still point at the destroyed source, or the records are gone).

- [ ] **Step 3: Implement**

In `merger.rb`, replace the empty `merge_all_associations` and add the four private methods:

```ruby
      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_images
        merge_category_items
      end

      def merge_identifiers
        count = 0
        source_game.identifiers.find_each do |identifier|
          existing = target_game.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_game.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_external_links
        @stats[:external_links] = source_game.external_links.update_all(parent_id: target_game.id)
      end

      def merge_images
        has_target_primary = target_game.primary_image.present?
        count = 0

        source_game.images.find_each do |image|
          image.update!(
            parent_id: target_game.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end

      def merge_category_items
        count = 0
        source_game.category_items.find_each do |category_item|
          target_game.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end
```

Note `merge_images` counts as it goes. `Music::Album::Merger` reads `source_album.images.count` *after* reassigning them, which always yields 0 — do not copy that.

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: 11 runs, 0 failures.

- [ ] **Step 5: Verify the conflict branches aren't vacuous**

Change `identifier.destroy!` to `identifier.update!(identifiable_id: target_game.id)` and confirm "drops a source identifier the target already has" goes **red**. Restore. Repeat for the `has_target_primary` ternary against the demotion test.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git add app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git commit -m "feat(games): merge identifiers, links, images, and categories"
```

---

## Task 3: List items, user list items, descriptions

**Files:**
- Modify: `app/lib/games/game/merger.rb`
- Test: `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations`.
- Produces: `stats[:list_items]`, `stats[:user_list_items]`, `stats[:descriptions]` — all Integer.

- [ ] **Step 1: Write the failing tests**

```ruby
test "moves a list item to the target" do
  list = lists(:games_list)
  item = ListItem.create!(list: list, listable: @source, position: 3, verified: false)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, item.reload.listable_id
end

test "promotes the surviving list item to verified when the source was verified" do
  list = lists(:games_list)
  ListItem.create!(list: list, listable: @target, position: 1, verified: false)
  ListItem.create!(list: list, listable: @source, position: 2, verified: true)

  ::Games::Game::Merger.call(source: @source, target: @target)

  survivor = ListItem.find_by(list: list, listable: @target)
  assert survivor.verified, "a verified source must not silently downgrade the survivor"
  assert_equal 1, ListItem.where(list: list, listable: @target).count
end

test "moves a personal list entry to the target" do
  user_list = user_lists(:regular_user_games_favorites)
  entry = UserListItem.create!(user_list: user_list, listable: @source, position: 5)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, entry.reload.listable_id
end

test "drops a personal list entry when that list already holds the target" do
  user_list = user_lists(:regular_user_games_favorites)
  UserListItem.create!(user_list: user_list, listable: @target, position: 1)
  UserListItem.create!(user_list: user_list, listable: @source, position: 2)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal 1, UserListItem.where(user_list: user_list, listable: @target).count
end

test "moves a description the target does not have" do
  description = Description.create!(
    describable: @source, content: "Source blurb",
    kind: :long, locale: "en", source: :ai_generated, rank: :normal
  )

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, description.reload.describable_id
end

test "drops a source description that collides with the target's" do
  # descriptions(:botw_igdb) is already summary/en/igdb/preferred on the target.
  Description.create!(
    describable: @source, content: "Source blurb",
    kind: :summary, locale: "en", source: :igdb, rank: :normal
  )

  result = ::Games::Game::Merger.call(source: @source, target: @target)

  assert result.success?, "collision must not raise: #{result.errors.inspect}"
  assert_equal 1, Description.where(
    describable: @target, kind: :summary, locale: "en", source: :igdb
  ).count
end

test "demotes a moved description when the target already has a preferred one" do
  # descriptions(:botw_igdb) is already summary/en/preferred on the target. A different
  # source avoids the composite index but still hits the one-preferred-per-key index.
  moved = Description.create!(
    describable: @source, content: "Other", kind: :summary, locale: "en",
    source: :ai_generated, rank: :preferred
  )

  result = ::Games::Game::Merger.call(source: @source, target: @target)

  assert result.success?,
    "two preferred rows would violate the partial unique index: #{result.errors.inspect}"
  assert_equal "normal", moved.reload.rank
  assert_equal @target.id, moved.describable_id
end
```

**`Description#rank` is an enum**, not an integer: `{deprecated: -1, normal: 0, preferred: 1}`.
`description.rank` returns the string `"preferred"`, so `description.rank == 1` is always false. Use
the `preferred?` predicate and assign `:normal`. `#kind` is `{summary: 0, long: 1, first_sentence: 2,
blurb: 3}` and `#source` is `{manual: 0, ai_generated: 1, wikipedia: 2, openlibrary: 3, musicbrainz:
4, igdb: 5, publisher: 6, goodreads: 7, other: 9}` with `prefix: true` — there is no `:ai`. A
`source_name` is required when the source is `other` and forbidden otherwise, so these tests avoid
`:other`.

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

- [ ] **Step 3: Implement**

Extend `merge_all_associations`:

```ruby
      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_images
        merge_category_items
        merge_list_items
        merge_user_list_items
        merge_descriptions
      end
```

Add:

```ruby
      def merge_list_items
        count = 0
        source_game.list_items.find_each do |list_item|
          existing = target_game.list_items.find_by(list_id: list_item.list_id)

          if existing
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            target_game.list_items.create!(
              list_id: list_item.list_id,
              position: list_item.position,
              verified: list_item.verified
            )
          end
          count += 1
        end
        @stats[:list_items] = count
      end

      # position is scoped to the user_list, which does not change, so a moved row
      # keeps a valid position.
      def merge_user_list_items
        count = 0
        source_game.user_list_items.find_each do |entry|
          if UserListItem.exists?(user_list_id: entry.user_list_id, listable: target_game)
            entry.destroy!
          else
            entry.update!(listable_id: target_game.id)
            count += 1
          end
        end
        @stats[:user_list_items] = count
      end

      # Two unique indexes apply: one on
      # (describable, kind, locale, source, source_name) with nulls_not_distinct,
      # and a partial one allowing a single rank=1 row per (describable, kind, locale).
      def merge_descriptions
        preferred_keys = target_game.descriptions.select(&:preferred?)
          .map { |description| [description.kind, description.locale] }
          .to_set
        count = 0

        source_game.descriptions.find_each do |description|
          collides = target_game.descriptions.exists?(
            kind: description.kind,
            locale: description.locale,
            source: description.source,
            source_name: description.source_name
          )

          if collides
            description.destroy!
            next
          end

          attrs = {describable_id: target_game.id}
          if description.preferred? &&
              preferred_keys.include?([description.kind, description.locale])
            attrs[:rank] = :normal
          end

          description.update!(attrs)
          count += 1
        end
        @stats[:descriptions] = count
      end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: 18 runs, 0 failures.

- [ ] **Step 5: Verify the conflict branches aren't vacuous**

Delete the `attrs[:rank] = :normal` line and confirm the demotion test goes **red** (it should raise `RecordNotUnique` on the partial index). Restore. Delete the `existing.update!(verified: true)` line and confirm the promotion test goes red. Restore.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git add app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git commit -m "feat(games): merge list items, personal lists, and descriptions"
```

---

## Task 4: Companies, platforms, and child games

**Files:**
- Modify: `app/lib/games/game/merger.rb`
- Test: `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations`.
- Produces: `stats[:game_companies]`, `stats[:game_platforms]`, `stats[:child_games]` — all Integer.

- [ ] **Step 1: Write the failing tests**

```ruby
test "moves a company link the target does not have" do
  link = games_game_companies(:hl2_valve_dev)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, link.reload.game_id
end

test "ORs developer and publisher flags when both games share a company" do
  company = games_companies(:nintendo)
  ::Games::GameCompany.where(game: @source, company: company).destroy_all
  ::Games::GameCompany.create!(game: @source, company: company, developer: false, publisher: true)
  target_link = ::Games::GameCompany.find_by(game: @target, company: company)
  target_link.update!(developer: true, publisher: false)

  ::Games::Game::Merger.call(source: @source, target: @target)

  target_link.reload
  assert target_link.developer, "the target's own developer flag must survive"
  assert target_link.publisher, "the source's publisher flag must not be discarded"
  assert_equal 1, ::Games::GameCompany.where(game: @target, company: company).count
end

test "moves a platform link the target does not have" do
  link = games_game_platforms(:hl2_pc)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal @target.id, link.reload.game_id
end

test "drops a platform link both games share" do
  platform = games_platforms(:pc)
  ::Games::GamePlatform.find_or_create_by!(game: @target, platform: platform)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal 1, ::Games::GamePlatform.where(game: @target, platform: platform).count
end

test "repoints child games to the target instead of orphaning them" do
  source = games_games(:resident_evil_4)
  target = games_games(:half_life_2)
  child = games_games(:resident_evil_4_remake)
  RankedItem.where(item: source).destroy_all
  RankedItem.where(item: target).destroy_all

  ::Games::Game::Merger.call(source: source, target: target)

  assert_equal target.id, child.reload.parent_game_id,
    "child_games is dependent: :nullify, so doing nothing orphans the subtree"
end

test "nullifies rather than self-parents when the target is a child of the source" do
  source = games_games(:resident_evil_4)
  target = games_games(:resident_evil_4_remake)
  RankedItem.where(item: source).destroy_all
  RankedItem.where(item: target).destroy_all

  result = ::Games::Game::Merger.call(source: source, target: target)

  assert result.success?, "a game cannot be its own parent: #{result.errors.inspect}"
  assert_nil target.reload.parent_game_id
end
```

Fixture names confirmed: companies are `nintendo`, `capcom`, `valve`; platforms are `switch`,
`ps5`, `ps4`, `pc`, `xbox_series`.

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

- [ ] **Step 3: Implement**

Extend `merge_all_associations` with `merge_game_companies`, `merge_game_platforms`, and
`merge_child_games`, then add:

```ruby
      # developer/publisher are ORed rather than dropped: a source row marking a
      # company as publisher carries information the target's row may not have.
      def merge_game_companies
        count = 0
        source_game.game_companies.find_each do |link|
          existing = target_game.game_companies.find_by(company_id: link.company_id)

          if existing
            existing.update!(
              developer: existing.developer? || link.developer?,
              publisher: existing.publisher? || link.publisher?
            )
            link.destroy!
          else
            link.update!(game_id: target_game.id)
            count += 1
          end
        end
        @stats[:game_companies] = count
      end

      def merge_game_platforms
        count = 0
        source_game.game_platforms.find_each do |link|
          if target_game.game_platforms.exists?(platform_id: link.platform_id)
            link.destroy!
          else
            link.update!(game_id: target_game.id)
            count += 1
          end
        end
        @stats[:game_platforms] = count
      end

      # child_games is dependent: :nullify, so leaving these alone orphans the whole
      # subtree when the source is destroyed. The target itself cannot become its own
      # parent, so it is nullified instead.
      def merge_child_games
        children = ::Games::Game.where(parent_game_id: source_game.id)

        children.where(id: target_game.id).update_all(parent_game_id: nil)
        count = children.where.not(id: target_game.id).update_all(parent_game_id: target_game.id)

        target_game.reload if target_game.parent_game_id == source_game.id
        @stats[:child_games] = count
      end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: 24 runs, 0 failures.

- [ ] **Step 5: Verify the branches aren't vacuous**

Replace the `existing.update!` OR-ing with a plain `link.destroy!` and confirm the OR test goes
**red**. Restore. Delete the whole `merge_child_games` body and confirm the repoint test goes red.
Restore.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git add app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git commit -m "feat(games): merge company, platform, and child-game links"
```

---

## Task 5: Scalar reconciliation

**Files:**
- Modify: `app/lib/games/game/merger.rb`
- Test: `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: `#reconcile_scalars` from Task 1.
- Produces: `stats[:release_year_updated]` (Boolean, only set when changed), `stats[:filled_fields]` (Array of Symbol).

- [ ] **Step 1: Write the failing tests**

```ruby
test "fills a blank description from the source" do
  @source.update!(description: "A source blurb")
  @target.update!(description: nil)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal "A source blurb", @target.reload.description
end

test "never overwrites a field the target already has" do
  @source.update!(description: "Source wins?")
  @target.update!(description: "Target's own")

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal "Target's own", @target.reload.description
end

test "fills a blank series from the source" do
  source = games_games(:resident_evil_4)
  target = games_games(:half_life_2)
  RankedItem.where(item: source).destroy_all
  RankedItem.where(item: target).destroy_all
  assert_nil target.series_id, "fixture precondition"

  ::Games::Game::Merger.call(source: source, target: target)

  assert_equal source.series_id, target.reload.series_id
end

test "keeps the earliest release year" do
  @source.update!(release_year: 1998)
  @target.update!(release_year: 2017)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal 1998, @target.reload.release_year
end

test "does not move the release year later" do
  @source.update!(release_year: 2020)
  @target.update!(release_year: 2017)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_equal 2017, @target.reload.release_year
end

test "absorbs the source title only into games that track alternates" do
  # Games have no alternate_titles column; this test documents that the merger
  # must not attempt to write one. It passes as long as the merge succeeds.
  result = ::Games::Game::Merger.call(source: @source, target: @target)

  assert result.success?, result.errors.inspect
  assert_not ::Games::Game.column_names.include?("alternate_titles")
end

test "does not give a main game a parent" do
  source = games_games(:resident_evil_4_remake)
  target = games_games(:half_life_2)
  RankedItem.where(item: source).destroy_all
  RankedItem.where(item: target).destroy_all
  assert target.main_game?, "fixture precondition"

  result = ::Games::Game::Merger.call(source: source, target: target)

  assert result.success?, "parent_game_valid_for_type would reject this: #{result.errors.inspect}"
  assert_nil target.reload.parent_game_id
end
```

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

- [ ] **Step 3: Implement**

Replace the empty `reconcile_scalars`:

```ruby
      # Games have no alternate_titles column, so there is no name absorption here.
      # Books and authors (increments 2 and 3) do.
      BLANK_FILLABLE = %i[description series_id].freeze

      def reconcile_scalars
        fill_blank_fields
        merge_release_year
        fill_parent_game
      end

      def fill_blank_fields
        filled = []

        BLANK_FILLABLE.each do |field|
          next if target_game.public_send(field).present?

          value = source_game.public_send(field)
          next if value.blank?

          target_game.public_send(:"#{field}=", value)
          filled << field
        end

        @stats[:filled_fields] = filled
      end

      def merge_release_year
        return if source_game.release_year.blank?

        if target_game.release_year.nil? || source_game.release_year < target_game.release_year
          target_game.release_year = source_game.release_year
          @stats[:release_year_updated] = true
        end
      end

      # Only fills a genuinely blank parent, and only when doing so is legal:
      # parent_game_valid_for_type rejects a parent on a main game, and a parent that
      # is the target itself (or a descendant of it) would be a cycle.
      def fill_parent_game
        return if target_game.parent_game_id.present?
        return if target_game.main_game?

        candidate_id = source_game.parent_game_id
        return if candidate_id.blank?
        return if candidate_id == target_game.id
        return if descendant_of_target?(candidate_id)

        target_game.parent_game_id = candidate_id
      end

      def descendant_of_target?(game_id)
        seen = Set.new
        current = game_id

        while current.present? && seen.add?(current)
          return true if current == target_game.id
          current = ::Games::Game.where(id: current).pick(:parent_game_id)
        end

        false
      end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: 31 runs, 0 failures.

- [ ] **Step 5: Verify the branches aren't vacuous**

Change `next if target_game.public_send(field).present?` to `next if false` and confirm "never
overwrites a field the target already has" goes **red**. Restore. Remove the
`return if target_game.main_game?` line and confirm the main-game test goes red. Restore.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git add app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git commit -m "feat(games): reconcile scalar fields on merge"
```

---

## Task 6: Reindexing, ranking jobs, and the service doc

**Files:**
- Modify: `app/lib/games/game/merger.rb`
- Create: `docs/games/game_merger.md` (project root `docs/`, not `web-app/docs/`)
- Test: `test/lib/games/game/merger_test.rb`

**Interfaces:**
- Consumes: `#collect_affected_ranking_configurations`, `#reindex_target_game`, `#schedule_ranking_recalculation` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing tests**

```ruby
test "queues the target for reindexing" do
  ::Games::Game::Merger.call(source: @source, target: @target)

  assert SearchIndexRequest.exists?(
    parent_type: "Games::Game", parent_id: @target.id, action: "index_item"
  )
end

test "does not queue indexing while migration suppression is on" do
  Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

  ::Games::Game::Merger.call(source: @source, target: @target)

  assert_not SearchIndexRequest.exists?(
    parent_type: "Games::Game", parent_id: @target.id, action: "index_item"
  )
end

test "schedules recalculation for every affected ranking configuration" do
  config = ranking_configurations(:games_global)
  RankedItem.create!(item: @source, ranking_configuration: config, rank: 5, score: 10)

  BulkCalculateWeightsJob.expects(:perform_async).with(config.id)
  CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)

  ::Games::Game::Merger.call(source: @source, target: @target)
end

test "schedules nothing when neither game is ranked" do
  BulkCalculateWeightsJob.expects(:perform_async).never
  CalculateRankingsJob.expects(:perform_in).never

  ::Games::Game::Merger.call(source: @source, target: @target)
end
```

Fixture names confirmed: `games_global` and `games_secondary` are the two games ranking
configurations.

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

- [ ] **Step 3: Implement**

Replace the three empty methods:

```ruby
      def collect_affected_ranking_configurations
        source_configs = RankedItem.where(item_type: "Games::Game", item_id: source_game.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Games::Game", item_id: target_game.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
      end

      # SearchIndexable already respects this flag on its own callbacks; the merger
      # matches it rather than writing requests during a bulk migration.
      def reindex_target_game
        return if Services::BooksMigration.search_indexing_suppressed?

        SearchIndexRequest.create!(parent: target_game, action: :index_item)
      end

      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          BulkCalculateWeightsJob.perform_async(config_id)
          CalculateRankingsJob.perform_in(5.minutes, config_id)
        end
      end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/lib/games/game/merger_test.rb
```

Expected: 35 runs, 0 failures.

- [ ] **Step 5: Write the service doc**

Create `docs/games/game_merger.md` documenting: purpose, `call(source:, target:)` signature and
`Result` shape, the per-association table from the spec's `Games::Game` section, the scalar rules,
the transaction boundary, and what is scheduled after commit. Cross-reference
`docs/superpowers/specs/2026-08-23-record-merge-design.md`.

- [ ] **Step 6: Run the full merger file plus lint, then commit**

```bash
ps aux | grep "[r]ails test"   # must be empty before running
bin/rails test test/lib/games/game/merger_test.rb
bundle exec standardrb --fix app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb
git add app/lib/games/game/merger.rb test/lib/games/game/merger_test.rb docs/games/game_merger.md
git commit -m "feat(games): reindex and reschedule rankings after merge"
```

---

## Task 7: Policies and role fixtures

**Files:**
- Modify: `app/policies/games/game_policy.rb`
- Modify: `app/policies/music/album_policy.rb`, `artist_policy.rb`, `song_policy.rb`
- Modify: `test/fixtures/users.yml`, `test/fixtures/domain_roles.yml`
- Test: `test/policies/games/game_policy_test.rb`, `test/policies/music/album_policy_test.rb` (create if absent)

**Interfaces:**
- Consumes: nothing.
- Produces: `Games::GamePolicy#execute_action?` → Boolean; fixtures `users(:games_editor_user)`, `users(:games_moderator_user)`, `domain_roles(:games_editor)`, `domain_roles(:games_moderator)`.

- [ ] **Step 1: Add the fixtures**

Append to `test/fixtures/users.yml`:

```yaml
games_editor_user:
  email: games-editor@example.com
  display_name: Games Editor
  name: Games Editor Full Name
  role: 0
  email_verified: true
  original_signup_domain: thegreatestgames.org

games_moderator_user:
  email: games-moderator@example.com
  display_name: Games Moderator
  name: Games Moderator Full Name
  role: 0
  email_verified: true
  original_signup_domain: thegreatestgames.org
```

`role: 0` is `:user` — a *global* editor would pass `global_role?` and prove nothing.

Append to `test/fixtures/domain_roles.yml`:

```yaml
# Domain-scoped games editor: can_write? but NOT can_delete?
games_editor:
  user: games_editor_user
  domain: 1  # games
  permission_level: 1  # editor

# Domain-scoped games moderator: can_delete?
games_moderator:
  user: games_moderator_user
  domain: 1  # games
  permission_level: 2  # moderator
```

- [ ] **Step 2: Write the failing tests**

Create `test/policies/games/game_policy_test.rb`:

```ruby
require "test_helper"

module Games
  class GamePolicyTest < ActiveSupport::TestCase
    setup do
      @game = games_games(:breath_of_the_wild)
    end

    test "a domain editor cannot execute admin actions" do
      policy = ::Games::GamePolicy.new(users(:games_editor_user), @game)

      assert policy.update?, "an editor should still be able to edit"
      assert_not policy.destroy?
      assert_not policy.execute_action?,
        "merge deletes a record, so write access must not be enough"
    end

    test "a domain moderator can execute admin actions" do
      policy = ::Games::GamePolicy.new(users(:games_moderator_user), @game)

      assert policy.destroy?
      assert policy.execute_action?
    end

    test "a global admin can execute admin actions" do
      assert ::Games::GamePolicy.new(users(:admin_user), @game).execute_action?
    end
  end
end
```

Create the equivalent `test/policies/music/album_policy_test.rb` using
`music_albums(:dark_side_of_the_moon)` and `domain_roles(:music_editor)`'s `contractor_user`:

```ruby
require "test_helper"

module Music
  class AlbumPolicyTest < ActiveSupport::TestCase
    test "a domain editor cannot merge, because merging deletes a record" do
      policy = ::Music::AlbumPolicy.new(users(:contractor_user), music_albums(:dark_side_of_the_moon))

      assert policy.update?
      assert_not policy.destroy?
      assert_not policy.execute_action?
    end
  end
end
```

Fixture name confirmed: `dark_side_of_the_moon`. `contractor_user` holds `domain_roles(:music_editor)`
— a domain-scoped music editor, which is exactly the role this test needs.

- [ ] **Step 3: Run and verify they fail**

```bash
bin/rails test test/policies/games/game_policy_test.rb test/policies/music/album_policy_test.rb
```

Expected: the games tests fail with `NoMethodError: undefined method 'execute_action?'`; the music
test fails because `execute_action?` currently returns true for an editor.

- [ ] **Step 4: Implement**

Add to `app/policies/games/game_policy.rb`:

```ruby
    # Gated on can_delete?, not can_write?: the only action routed through
    # execute_action is a merge, which destroys the source record.
    def execute_action?
      global_role? || domain_role&.can_delete?
    end
```

In each of `app/policies/music/album_policy.rb`, `artist_policy.rb`, and `song_policy.rb`, change:

```ruby
    # Allow execute_action (custom admin actions) for editors and above
    def execute_action?
      global_role? || domain_role&.can_write?
    end
```

to:

```ruby
    # Gated on can_delete?, not can_write?: execute_action routes merges, which
    # destroy the source record. A domain editor could otherwise delete a record
    # they are not permitted to delete.
    def execute_action?
      global_role? || domain_role&.can_delete?
    end
```

- [ ] **Step 5: Run and verify they pass**

```bash
bin/rails test test/policies/
```

- [ ] **Step 6: Run the music admin controller tests for regressions**

```bash
bin/rails test test/controllers/admin/music/
```

Any failure here means an existing test signed in as a domain editor and expected `execute_action`
to succeed. That expectation is now wrong — update the test to use a moderator, do **not** revert
the policy.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/policies test/policies
git add app/policies test/policies test/fixtures/users.yml test/fixtures/domain_roles.yml
git commit -m "fix: require delete permission for admin merge actions

execute_action? was gated on can_write?, but the only actions routed through
it are merges, which destroy the source record. A domain-scoped editor could
delete an album, artist, or song they had no delete permission for."
```

---

## Task 8: The MergeGame action class

**Files:**
- Create: `app/lib/actions/admin/games/merge_game.rb`
- Test: `test/lib/actions/admin/games/merge_game_test.rb`

**Interfaces:**
- Consumes: `::Games::Game::Merger.call(source:, target:)` from Tasks 1–6.
- Produces: `Actions::Admin::Games::MergeGame.call(user:, models:, fields:)` → `Actions::Admin::BaseAction::ActionResult` responding to `status`, `message`, `success?`, `error?`. Reads `fields[:source_game_id]` and `fields[:confirm_merge]`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/actions/admin/games/merge_game_test.rb`:

```ruby
require "test_helper"

module Actions
  module Admin
    module Games
      class MergeGameTest < ActiveSupport::TestCase
        def setup
          @user = users(:admin_user)
          @target = games_games(:breath_of_the_wild)
          @source = games_games(:half_life_2)

          RankedItem.where(item: @source).destroy_all
          RankedItem.where(item: @target).destroy_all
        end

        def call(fields)
          Actions::Admin::Games::MergeGame.call(
            user: @user, models: [@target], fields: fields
          )
        end

        test "merges and reports success" do
          result = call({source_game_id: @source.id.to_s, confirm_merge: "1"})

          assert result.success?, result.message
          assert_match(/Half-Life 2/, result.message)
          assert_not ::Games::Game.exists?(@source.id)
        end

        test "requires a source game id" do
          result = call({confirm_merge: "1"})

          assert result.error?
          assert_equal "Please select a game to merge.", result.message
          assert ::Games::Game.exists?(@source.id)
        end

        test "requires the confirmation checkbox" do
          result = call({source_game_id: @source.id.to_s})

          assert result.error?
          assert_match(/confirm/i, result.message)
          assert ::Games::Game.exists?(@source.id)
        end

        test "reports a missing source game" do
          result = call({source_game_id: "999999", confirm_merge: "1"})

          assert result.error?
          assert_equal "Game with ID 999999 not found.", result.message
        end

        test "refuses to merge a game with itself" do
          result = call({source_game_id: @target.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_match(/itself/, result.message)
          assert ::Games::Game.exists?(@target.id)
        end

        test "refuses to act on more than one game" do
          result = Actions::Admin::Games::MergeGame.call(
            user: @user,
            models: [@target, @source],
            fields: {source_game_id: @source.id.to_s, confirm_merge: "1"}
          )

          assert result.error?
          assert_match(/single game/, result.message)
        end

        test "surfaces merger failures" do
          ::Games::Game::Merger.stubs(:call).returns(
            ::Games::Game::Merger::Result.new(success?: false, data: nil, errors: ["nope"])
          )

          result = call({source_game_id: @source.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_match(/nope/, result.message)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run and verify it fails**

```bash
bin/rails test test/lib/actions/admin/games/merge_game_test.rb
```

Expected: `NameError: uninitialized constant Actions::Admin::Games`.

- [ ] **Step 3: Implement**

Create `app/lib/actions/admin/games/merge_game.rb`:

```ruby
module Actions
  module Admin
    module Games
      class MergeGame < Actions::Admin::BaseAction
        def self.name
          "Merge Another Game Into This One"
        end

        def self.message
          "Search for a duplicate game to merge into the current game. The source game will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Game"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single game.") if models.count != 1

          target_game = models.first

          source_game_id = fields[:source_game_id] || fields["source_game_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_game_id.present?
            return error("Please select a game to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_game = ::Games::Game.find_by(id: source_game_id)

          unless source_game
            return error("Game with ID #{source_game_id} not found.")
          end

          if source_game.id == target_game.id
            return error("Cannot merge a game with itself. Please select a different game.")
          end

          source_title = source_game.title
          source_id = source_game.id

          result = ::Games::Game::Merger.call(source: source_game, target: target_game)

          if result.success?
            succeed "Successfully merged '#{source_title}' (ID: #{source_id}) into '#{target_game.title}'. The source game has been deleted."
          else
            error "Failed to merge games: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
```

The title and id are captured **before** the merger runs — the source record is destroyed by then,
and the music actions read them afterwards from an in-memory object that no longer has a row.

- [ ] **Step 4: Run and verify it passes**

```bash
bin/rails test test/lib/actions/admin/games/merge_game_test.rb
```

Expected: 7 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/actions/admin/games test/lib/actions/admin/games
git add app/lib/actions/admin/games test/lib/actions/admin/games
git commit -m "feat(games): add MergeGame admin action"
```

---

## Task 9: Route, controller, and exclude_id

**Files:**
- Modify: `config/routes.rb` (games `resources :games` block, near line 777)
- Modify: `app/controllers/admin/games/games_controller.rb`
- Test: `test/controllers/admin/games/games_controller_test.rb`

**Interfaces:**
- Consumes: `Actions::Admin::Games::MergeGame` from Task 8; `Games::GamePolicy#execute_action?` from Task 7.
- Produces: route helper `execute_action_admin_games_game_path(game)`; `search` honouring `params[:exclude_id]`.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/admin/games/games_controller_test.rb`:

```ruby
# Execute Action Tests

test "admin can merge one game into another" do
  sign_in_as(@admin_user, stub_auth: true)
  source = games_games(:half_life_2)
  RankedItem.where(item: source).destroy_all
  RankedItem.where(item: @game).destroy_all

  post execute_action_admin_games_game_path(@game), params: {
    action_name: "MergeGame",
    source_game_id: source.id.to_s,
    confirm_merge: "1"
  }

  assert_redirected_to admin_games_game_path(@game)
  assert_not ::Games::Game.exists?(source.id)
end

test "a domain editor cannot merge" do
  sign_in_as(users(:games_editor_user), stub_auth: true)
  source = games_games(:half_life_2)

  post execute_action_admin_games_game_path(@game), params: {
    action_name: "MergeGame",
    source_game_id: source.id.to_s,
    confirm_merge: "1"
  }

  assert_redirected_to games_root_path
  assert ::Games::Game.exists?(source.id), "an editor must not be able to delete via merge"
end

test "a domain moderator can merge" do
  sign_in_as(users(:games_moderator_user), stub_auth: true)
  source = games_games(:half_life_2)
  RankedItem.where(item: source).destroy_all
  RankedItem.where(item: @game).destroy_all

  post execute_action_admin_games_game_path(@game), params: {
    action_name: "MergeGame",
    source_game_id: source.id.to_s,
    confirm_merge: "1"
  }

  assert_not ::Games::Game.exists?(source.id)
end

# Search exclude_id

test "search omits the excluded game" do
  sign_in_as(@admin_user, stub_auth: true)
  ::Search::Games::Search::GameAutocomplete.stubs(:call).returns([
    {id: @game.id.to_s}, {id: games_games(:half_life_2).id.to_s}
  ])

  get search_admin_games_games_path(q: "zelda", exclude_id: @game.id)

  ids = JSON.parse(response.body).map { |row| row["value"] }
  assert_not_includes ids, @game.id
  assert_includes ids, games_games(:half_life_2).id
end
```

`Admin::DomainScopedAuth#authenticate_admin!` redirects an unauthorized user to `domain_root_path`;
the existing tests in this file already assert `games_root_path`, so that is the expected target.

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/controllers/admin/games/games_controller_test.rb
```

Expected: `NameError: undefined local variable or method 'execute_action_admin_games_game_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the games `resources :games do` block, add a `member` block alongside
the existing `collection` block:

```ruby
      resources :games do
        resources :game_companies, only: [:create], shallow: true
        resources :game_platforms, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :import_from_igdb
          get :igdb_search
          get :search
        end
      end
```

- [ ] **Step 4: Implement the controller changes**

In `app/controllers/admin/games/games_controller.rb`, extend both before_action lists:

```ruby
  before_action :set_game, only: [:show, :edit, :update, :destroy, :execute_action]
  before_action :authorize_game, only: [:show, :edit, :update, :destroy, :execute_action]
```

Add `execute_action` as a public action (place it after `destroy`):

```ruby
  def execute_action
    fields_hash = params.except(:controller, :action, :id, :action_name, :game_ids)

    action_class = "Actions::Admin::Games::#{params[:action_name]}".constantize
    result = action_class.call(
      user: current_user,
      models: [@game],
      fields: fields_hash
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: {result: result}
        )
      end
      format.html { redirect_to admin_games_game_path(@game), notice: result.message }
    end
  end
```

Note `show` re-finds `@game` with its own `includes`, overwriting what `set_game` loaded. That is
existing behaviour and `execute_action` is unaffected — `set_game` supplies `@game` for it.

Add `exclude_id` to `search`, matching how books already does it:

```ruby
  def search
    search_results = ::Search::Games::Search::GameAutocomplete.call(params[:q], size: 20)
    game_ids = search_results.map { |r| r[:id].to_i }
    game_ids.delete(params[:exclude_id].to_i) if params[:exclude_id].present?

    if game_ids.empty?
      render json: []
      return
    end

    games = Games::Game
      .where(id: game_ids)
      .in_order_of(:id, game_ids)

    render json: games.map { |g| {value: g.id, text: "#{g.title}#{" (#{g.release_year})" if g.release_year.present?}"} }
  end
```

- [ ] **Step 5: Run and verify they pass**

```bash
bin/rails test test/controllers/admin/games/games_controller_test.rb
```

- [ ] **Step 6: Verify the authorization test isn't vacuous**

Temporarily change `Games::GamePolicy#execute_action?` back to `can_write?` and confirm "a domain
editor cannot merge" goes **red**. Restore. This is the single most important assertion in the
increment.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix config/routes.rb app/controllers/admin/games/games_controller.rb test/controllers/admin/games/games_controller_test.rb
git add config/routes.rb app/controllers/admin/games/games_controller.rb test/controllers/admin/games/games_controller_test.rb
git commit -m "feat(games): route and controller for admin merge action"
```

---

## Task 10: Merge button and modal

**Files:**
- Modify: `app/views/admin/games/games/show.html.erb`

**Interfaces:**
- Consumes: `execute_action_admin_games_game_path` (Task 9), `search_admin_games_games_path` with `exclude_id` (Task 9), `Actions::Admin::Games::MergeGame` (Task 8).
- Produces: a dialog with `id="merge-game-modal"` and a submit button labelled "Merge Game".

- [ ] **Step 1: Add the Merge button**

In the `<div class="flex gap-2">` action block (currently around line 23), insert **between** the
Edit link and the Delete button:

```erb
      <% if current_user_can_delete? %>
        <button type="button"
                class="btn btn-warning btn-outline"
                data-testid="merge-game-button"
                onclick="document.getElementById('merge-game-modal').showModal()">
          <span>Merge</span>
        </button>
      <% end %>
```

This page currently guards none of its controls; the Merge button is deliberately the first guarded
one, matching the policy. Leaving the existing Edit and Delete controls ungated is out of scope.

- [ ] **Step 2: Add the modal**

Append at the end of the file, ported from `app/views/admin/music/artists/show.html.erb`:

```erb
<!-- Merge Game Modal -->
<dialog id="merge-game-modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Merge Another Game Into This One</h3>
    <p class="py-4">
      Search for a duplicate game to merge into <strong><%= @game.title %></strong>.
      Companies, platforms, categories, identifiers, images, links, list entries, and any
      child games will be transferred. The source game will be permanently deleted.
    </p>

    <%= form_with url: execute_action_admin_games_game_path(@game),
                  method: :post,
                  class: "space-y-4",
                  data: {
                    controller: "modal-form",
                    modal_form_modal_id_value: "merge-game-modal"
                  } do |f| %>
      <%= f.hidden_field :action_name, value: "MergeGame" %>

      <div>
        <%= f.label :source_game_id, class: "label" do %>
          <span class="font-semibold">Source Game <span class="text-error">*</span></span>
        <% end %>
        <%= render AutocompleteComponent.new(
          name: "source_game_id",
          url: search_admin_games_games_path(exclude_id: @game.id),
          placeholder: "Search for game to merge...",
          required: true
        ) %>
        <label class="label">
          <span>Search for the duplicate game you want to merge into this one</span>
        </label>
      </div>

      <div>
        <label class="label cursor-pointer justify-start gap-2">
          <%= f.check_box :confirm_merge, class: "checkbox", required: true %>
          <span>I understand this action cannot be undone</span>
        </label>
        <label class="label">
          <span class="text-warning">The source game will be permanently deleted after merging</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="document.getElementById('merge-game-modal').close()">Cancel</button>
        <%= f.submit "Merge Game", class: "btn btn-warning" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

None of the ten removed daisyUI v4 classes appear here — `label`, `checkbox`, and bare `btn` are all
v5-correct.

- [ ] **Step 3: Verify the view renders and the lint guard passes**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bin/rails test test/controllers/admin/games/games_controller_test.rb
```

Expected: both green. The show-page tests exercise the template, so a syntax error surfaces here.

- [ ] **Step 4: Commit**

```bash
git add app/views/admin/games/games/show.html.erb
git commit -m "feat(games): merge button and modal on the game show page"
```

---

## Task 11: End-to-end spec and full-suite verification

**Files:**
- Create: `e2e/tests/games/admin/games-merge.spec.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Read the existing page object**

```bash
cat e2e/pages/games/admin/games-page.ts
```

Reuse its `goto` and selectors rather than inventing new ones. The auth fixture is
`e2e/fixtures/games-auth.ts`, exposing `gamesPage`.

- [ ] **Step 2: Write the spec**

Create `e2e/tests/games/admin/games-merge.spec.ts`:

```ts
import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Merge', () => {
  test('merge button opens the modal on a game show page', async ({ gamesPage, page }) => {
    await gamesPage.goto();
    await gamesPage.tableRows.first().getByRole('link').first().click();
    await page.waitForURL(/\/admin\/games\/\d+|\/admin\/games\/[a-z0-9-]+/);

    await page.getByTestId('merge-game-button').click();

    await expect(page.getByRole('heading', { name: 'Merge Another Game Into This One' }))
      .toBeVisible();
    await expect(page.getByRole('button', { name: 'Merge Game' })).toBeVisible();
  });

  test('merge requires the confirmation checkbox', async ({ gamesPage, page }) => {
    await gamesPage.goto();
    await gamesPage.tableRows.first().getByRole('link').first().click();
    await page.waitForURL(/\/admin\/games\//);

    await page.getByTestId('merge-game-button').click();
    await page.getByRole('button', { name: 'Merge Game' }).click();

    // The checkbox is `required`, so the browser blocks submission and the modal stays open.
    await expect(page.getByRole('heading', { name: 'Merge Another Game Into This One' }))
      .toBeVisible();
  });
});
```

These two cases deliberately avoid performing a real destructive merge against the dev database.

- [ ] **Step 3: Run the E2E spec**

```bash
yarn build:all
bin/rails server        # in a separate terminal; bin/dev needs a TTY and self-terminates
yarn test:e2e --grep "Games Admin Merge"
```

If admin specs time out on the public homepage, the e2e admin user lost its role — fix with
`bin/rails e2e:admin`. Confirm port 3000 is serving *this* worktree, not another one.

- [ ] **Step 4: Run the full suite and linter**

```bash
ps aux | grep "[r]ails test"   # must be empty
bin/rails db:test:prepare test
bundle exec standardrb
```

Expected: zero failures, zero new warning lines. A new warning is a regression — fix the cause, do
not filter the output.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/games/admin/games-merge.spec.ts
git commit -m "test(games): e2e coverage for the merge modal"
```

- [ ] **Step 6: Report, do not push**

Summarise: tests added, full-suite result, and anything deferred. **Do not push or open a PR without
asking.**

---

## Self-Review

**Spec coverage.** Every `Games::Game` row in the spec's association table maps to a task:
`game_companies`/`game_platforms`/`child_games` → Task 4; `identifiers`/`category_items`/`images`/
`external_links` → Task 2; `list_items`/`user_list_items`/`descriptions` → Task 3; `ranked_items` →
Task 6. Scalars → Task 5. Transaction boundary and failure handling → Task 1. Search suppression →
Task 6. Policy correction → Task 7. Admin plumbing → Tasks 8–10. Testing requirements → embedded in
every task, with the authorization test in Task 9 and E2E in Task 11.

**Deliberately deferred to increments 2 and 3:** `Books::Book::Merger`, `Books::Author::Merger`,
their action classes, routes, controllers, policies, and views. Games has no reviews, credits, or
AI chats, so those spec rules have no games counterpart.

**Fixture and enum names are all resolved and verified** against the codebase: `categories(:games_action_genre)`,
`lists(:games_list)`, `user_lists(:regular_user_games_favorites)`, `ranking_configurations(:games_global)`,
`games_companies(:nintendo|:capcom|:valve)`, `games_platforms(:switch|:ps5|:ps4|:pc|:xbox_series)`,
`music_albums(:dark_side_of_the_moon)`, `descriptions(:botw_igdb)`. No step asks the executor to
guess a name.

**Three enum traps were corrected during self-review** and are called out inline where they bite:
`Description#rank` is an enum (`rank == 1` is always false — use `preferred?`); `Description#source`
has no `:ai`, only `:ai_generated`, and both it and `ExternalLink#source` carry `prefix: true`;
`Image` validates `file` presence, so games images must be built with an attachment block rather
than a bare `create!`.

**Type consistency.** `Result` is constructed identically in Tasks 1 and 8. `stats` keys are
introduced once each and never renamed. `source_game`/`target_game` are the reader names throughout;
the action class uses `source_game_id`/`confirm_merge` field names, matching the modal's
`name="source_game_id"` and `f.check_box :confirm_merge` in Task 10 and the controller test params
in Task 9.

**One correction folded in.** `Music::Album::Merger#merge_images` computes
`@stats[:images] = source_album.images.count` *after* reassigning the images, which always records
0. Task 2 counts during the loop instead and calls this out so the bug is not copied forward.
