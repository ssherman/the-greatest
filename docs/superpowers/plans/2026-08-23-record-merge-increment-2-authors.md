# Record Merge — Increment 2: Authors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a books admin merge a duplicate author into another from the author's admin show page, transferring every association rather than destroying it, absorbing the duplicate's name into the survivor's alternate names, and gating the action on delete permission.

**Architecture:** A `::Books::Author::Merger` service following the shipped `::Games::Game::Merger` exactly — one transaction that moves associations, reconciles scalars, and destroys the source, with reindexing and ranking work in a separate post-commit block whose failures never turn a committed merge into a reported failure. A thin `Actions::Admin::Books::MergeAuthor` action wraps it, reached through a new `execute_action` route on the books authors resource and a show-page modal. Two things are unique to authors: every book the source authored has to be reindexed explicitly (a book's search document embeds `author_names`/`author_ids`), and ranking recalculation is a single argument-less `Books::CalculateAuthorRankingsJob` rather than per-configuration jobs.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, Pundit, Sidekiq, Turbo Streams, ViewComponents, DaisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-23-record-merge-design.md` (sections "`Books::Author` merger", "Departures from the music pattern", "Ordering constraints", "Transaction boundary", "Failure handling", "Admin plumbing", "Namespace hazard", "Testing")

**Worktree:** `/home/shane/dev/the-greatest/.claude/worktrees/record-merge` — run everything from `web-app/` inside it.

**Prior art to copy from, not re-derive:** `app/lib/games/game/merger.rb`, `app/lib/actions/admin/games/merge_game.rb`, `app/controllers/admin/games/games_controller.rb#execute_action`, `app/views/admin/games/games/show.html.erb` (merge button + modal), `test/lib/games/game/merger_test.rb`, `test/lib/actions/admin/games/merge_game_test.rb`, `e2e/tests/games/admin/games-merge.spec.ts`. All of these shipped in increment 1 (PR #257) and are on `main`.

## Global Constraints

- **Run all commands from `web-app/`.** Docs live at the project root, not `web-app/docs/`.
- **Root-anchor every namespaced constant** as `::Books::Author`, `::Books::BookAuthor`, `::Books::Credit`, `::Books::AuthorRelationship` — in production code *and* test files. This bites hardest in `Actions::Admin::Books::*`: from inside that module a bare `Books::Author` resolves to `Actions::Admin::Books::Author` and raises a confusing `NameError`.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. `--fix` autocorrects.
- **Never run `ActiveRecord::FixtureSet.create_fixtures`** — it truncates every table it names. To inspect a fixture, read the YAML.
- **Never run a destructive DB command against development.** The books data exists only in development and takes hours to rebuild.
- **Check `ps aux | grep "[r]ails test"` before running the suite.** This worktree shares `the_greatest_test` with the main checkout; a concurrent run manufactures phantom failures.
- **Minitest is 6.x.** Use `assert_nil`, never `assert_equal nil` (a hard failure). No `assert_send`, no `minitest/mock`, no `MiniTest` namespace.
- **Sidekiq test mode is `:inline`**, set globally in `test_helper.rb`. Never `require "sidekiq/testing"`. `Books::CalculateAuthorRankingsJob.perform_async` therefore runs a **real** author-ranking calculation unless it is stubbed — see the hazard note in "Verified context".
- **Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. `keyword_init` is deliberate; a Standard cop is disabled for it.
- **A clean `bin/rails test` emits no warnings** beyond two known upstream sources. A new warning line is a regression — fix the cause.
- **daisyUI is 5.x.** These classes were removed and fail *silently*: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence; the fix is to remove the class, never to add an allowlist entry.
- **Controller tests assert behavior** (status codes, redirects, records changed) — never HTML/CSS/copy.
- **Commit freely on this branch.** Do not push or open a PR without asking.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `app/lib/books/author/merger.rb` | The whole merge operation for one author into another |
| `app/lib/actions/admin/books/merge_author.rb` | Admin action: validate form input, delegate to the merger, format the message |
| `test/lib/books/author/merger_test.rb` | Merger unit tests |
| `test/lib/actions/admin/books/merge_author_test.rb` | Action-class tests |
| `e2e/tests/books/admin/authors-merge.spec.ts` | End-to-end merge-modal flow (does **not** perform a real merge) |

**Modify:**

| Path | Change |
|---|---|
| `config/routes.rb` | `member { post :execute_action }` on the books `resources :authors` |
| `app/controllers/admin/books/authors_controller.rb` | `execute_action`; `:execute_action` in both `before_action` lists |
| `app/policies/books/author_policy.rb` | Add `execute_action?` gated on `can_write?` |
| `app/views/admin/books/authors/show.html.erb` | Merge button + merge modal |
| `test/controllers/admin/books/authors_controller_test.rb` | `execute_action` tests, including the editor/moderator gate |
| `docs/features/record-merge.md` | Extend from games-only to games + authors |

**Not created, deliberately:** no new fixture files and no new rows in `test/fixtures/users.yml` or `test/fixtures/domain_roles.yml`. Increment 1 added `games_editor_user`/`games_moderator_user` fixtures because no games role fixture existed. The books authors controller test already establishes the opposite idiom — `@regular_user.domain_roles.create!(domain: :books, permission_level: :editor)` inline in the test (see `test/controllers/admin/books/authors_controller_test.rb:56`) — and `domain_roles` has a unique index on `(user_id, domain)`, so an inline role is unambiguous. Follow the existing books idiom.

---

## Verified context

Facts confirmed against the codebase on this branch; do not re-derive them.

**Model shape — `app/models/books/author.rb`:**

- Associations to move: `author_relationships` (FK `from_author_id`), `inverse_author_relationships` (FK `to_author_id`), `credits`, `book_authors`, `identifiers` (`as: :identifiable`), `ai_chats` (`as: :parent`), `images` (`as: :parent`) with `has_one :primary_image`, `external_links` (`as: :parent`), `category_items` (`as: :item`), `descriptions` (via `Describable`, `as: :describable`), `ranked_items` (`as: :item`).
- **Authors are not listable.** There is no `list_items` and no `user_list_items` association. The games modal's "including entries in users' personal saved lists" clause does not apply here and must not be copied.
- Columns: `alternate_names` (string array, NOT NULL default `[]`, GIN-indexed), `birth_year`, `death_year`, `description`, `gender` (enum), `kind` (enum, NOT NULL default 0), `name` (NOT NULL), `slug` (unique), `sort_name`, `exclude_from_rankings` (boolean NOT NULL default false).
- `include SearchIndexable` — `after_commit :queue_for_indexing, on: [:create, :update]` and `queue_for_unindexing, on: :destroy`. Unindexing the source is therefore automatic; the target's reindex is not.
- `after_commit :queue_books_for_reindexing, if: :saved_change_to_name?` — fires only on a **name** change and only for `book_ids` at that moment, i.e. the source's books, which are about to be reassigned. It does nothing useful for a merge; the merger does the fan-out itself.
- `friendly_id :name, use: [:slugged, :finders]` — `find` resolves slugs, so `set_author` needs no change.

**Related models:**

- `Books::BookAuthor` — unique index on `(book_id, author_id)`; `after_commit :queue_book_for_reindexing` (fires on create/update/destroy, checks `Books::Book.exists?`). `position`, `role`, `credited_as` columns.
- `Books::AuthorRelationship` — unique index on `(from_author_id, to_author_id, relation_type)`; `enum :relation_type, {pseudonym_of: 0, member_of: 1}, prefix: true`; `validate :no_self_reference`.
- `Books::Credit` — **no** unique index. Dedup is the merger's job, on `(creditable_type, creditable_id, role)`. `enum :role, {translator: 0, illustrator: 1, editor: 2, ...}`. `creditable` is polymorphic (`Books::Edition` in fixtures).
- `Description` — `enum :rank, {deprecated: -1, normal: 0, preferred: 1}`; unique index on `(describable_type, describable_id, kind, locale, source, source_name)` with `nulls_not_distinct`, plus a partial unique index allowing a single `rank = 1` per `(describable_type, describable_id, kind, locale)`.
- `Identifier` — author-level enum values are `books_author_viaf: 30`, `books_author_isni: 31`, `books_author_wikidata_qid: 32`, `books_author_openlibrary_id: 33`, `books_author_goodreads_id: 34`, `books_author_librarything_id: 35`, `books_author_lcnaf: 36`.
- `SearchIndexRequest` — columns `parent_type`, `parent_id`, `action` (`enum {index_item: 0, unindex_item: 1}`), `created_at`, `updated_at`. `belongs_to :parent, polymorphic: true`.
- `Services::BooksMigration.search_indexing_suppressed?` — thread-local flag; `SearchIndexable` checks it and so must the merger.

**Rankings:**

- `Books::CalculateAuthorRankingsJob#perform` takes **no arguments**; it resolves `Books::Authors::RankingConfiguration.default_primary` itself and **raises** when there is none. It is already fired by `CalculateRankingsJob` for books configurations.
- `test/fixtures/ranking_configurations.yml` has `books_authors_global` (primary) and `books_authors_secondary`.
- `test/fixtures/ranked_items.yml` contains **no** `Books::Author` rows, so unlike the games merger test there is nothing to clear in `setup`.

**⚠ Test hazard — the ranking job runs for real.** Sidekiq test mode is `:inline`, and the author merger fires `Books::CalculateAuthorRankingsJob.perform_async` unconditionally (no configuration ids to gate on). Every test that performs a successful merge would run a full author ranking calculation. Stub it in `setup` in all three test files:

```ruby
::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
```

The one test that asserts scheduling re-declares it with `expects`, which Mocha checks ahead of the `setup` stub.

**⚠ Test hazard — `run_post_commit_steps` swallows Mocha errors.** `Mocha::ExpectationError` descends from `StandardError`, and post-commit steps run inside `rescue => error`. A violated expectation raised in there is caught and recorded as `stats[:post_commit_error]` rather than failing loudly at the point of failure. In every post-commit test, build the merger with `.new` and assert `assert_nil merger.stats[:post_commit_error]` alongside the real assertion.

**⚠ Test hazard — `target.save!` manufactures the index request.** `reconcile_scalars` almost always dirties the target (alternate-name absorption alone does it), and `target_author.save!` then fires `SearchIndexable`'s `after_commit`, creating exactly the `index_item` row the reindex tests are trying to attribute to `reindex_target_author`. Those tests would pass with `reindex_target_author` stubbed empty. Neutralize it first — see the `neutralize_scalar_confound` helper in Task 8.

**Fixtures (`test/fixtures/books/`):**

- `authors.yml`: `tolstoy` (birth 1828, death 1910, `alternate_names: ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"]`), `king` (birth 1947, no sort_name/death_year/gender/description, `alternate_names` empty), `bachman` (kind 2 = pseudonym, everything else blank), `garnett`, `excluded_placeholder` (`exclude_from_rankings: true`).
- `book_authors.yml`: `war_and_peace_tolstoy`, `got_king` (book `got`), `clash_king` (book `clash`). `bachman` has none.
- `author_relationships.yml`: `bachman_is_king` — `from_author: bachman`, `to_author: king`, `relation_type: 0`.
- `credits.yml`: `wp_translator` — `author: garnett`, `creditable: wp_maude (Books::Edition)`, `role: 0`.
- `descriptions.yml`: `tolstoy_google` — `describable: tolstoy (Books::Author)`, kind `summary`, locale `en`, source `other`, source_name `"Google Books"`, rank `normal`.
- No `Books::Author` rows exist in `identifiers.yml`, `images.yml`, `external_links.yml`, `ai_chats.yml`, or `category_items.yml`. Those tests build rows inline.
- **Chosen pair: source `bachman`, target `king`** — a genuine pseudonym duplicate, and the `bachman_is_king` relationship (bachman → king) naturally exercises the "would become a self-relation" drop.

**Fixtures and attributes used by the new tests, all verified against the repo:**

- `test/fixtures/books/books.yml` has `war_and_peace`, `crime_and_punishment`, `combo_steinbeck`, `got`, `clash`, `of_mice_and_men`, `cannery_row`.
- `test/fixtures/books/editions.yml` has `wp_maude` and `wp_volume_one`.
- `test/fixtures/categories.yml` has `books_fiction_genre` (`type: "Books::Category"`), plus `books_nonfiction_genre`, `books_novels_genre`, `books_classics_genre` and others.
- `AiChat` — `belongs_to :parent, polymorphic: true, optional: true`; `model` is NOT NULL; `chat_type` (`general: 0`, …) and `provider` (`openai: 0`, …) are enums with defaults. `AiChat.create!(parent:, chat_type: :general, model: "gpt-4", provider: :openai)` is valid.
- `ExternalLink` — `validates :name, :url` (URL must be http/https); `enum :source` includes `wikipedia` and `enum :link_category` includes `information`, both `prefix: true`, so the symbol forms used in the tests are correct.

**Admin plumbing:**

- Routes: `constraints DomainConstraint.new(...[:books]) { namespace :admin, module: "admin/books", as: "admin_books" { ... resources :authors do ... end } }`. The member route yields `execute_action_admin_books_author_path`.
- `Admin::Books::AuthorsController#search` **already supports `exclude_id`** (`app/controllers/admin/books/authors_controller.rb:15-17`) and is already tested (`test/controllers/admin/books/authors_controller_test.rb:95`). Nothing to add there — unlike games in increment 1.
- `Books::AuthorPolicy` currently defines only `domain` and `Scope`. It inherits `destroy?` → `global_role? || domain_role&.can_delete?` from `ApplicationPolicy`. It has **no** `execute_action?`, so Pundit would raise until one is added.
- `current_user_can_delete?` is a `helper_method` on `Admin::BaseController`. `app/views/admin/books/authors/show.html.erb` already gates its Delete button on it.
- The admin layout has `<div id="flash">` and `app/views/admin/shared/_flash.html.erb` handles a `result` local, so the Turbo Stream response works unchanged.
- `AutocompleteComponent.new(name:, url:, placeholder:, required:)` — no changes needed.
- `Actions::Admin::BaseAction.destructive?` defaults `false`; `test/lint/merge_actions_destructive_test.rb` discovers every `app/lib/actions/admin/**/merge_*.rb` by glob and fails if one does not override it. `MergeAuthor` is picked up automatically — nothing to register.

**E2E:**

- Books admin specs use plain `@playwright/test` (no custom auth fixture) and navigate with `page.goto("/admin/authors")`. See `e2e/tests/books/admin/authors.spec.ts`.
- The authors index table renders a "View" link per row (`app/views/admin/books/authors/_table.html.erb`).
- **The spec must not perform a real merge.** E2E runs against the development database, whose books data is irreversible. Drive the modal up to but not past submission, exactly as `games-merge.spec.ts` does.

### Refinements to the spec

1. **`book_authors` are moved with `delete_all` + `update_all`, not per-record `update!`.** The spec's table says "repoint-or-drop … fans out reindex requests". Doing that per-record would fire `Books::BookAuthor`'s own `after_commit :queue_book_for_reindexing` once per row, duplicating the batched fan-out the merger already performs, and would be N queries for an author who may have thousands of books. Bulk operations skip the callback, which is the point — the merger owns the fan-out. This mirrors the reviews shape the spec already prescribes for increment 3.
2. **No `collect_affected_ranking_configurations`.** Games and books collect configuration ids because their ranking jobs are keyed on them. Author rankings recalculate globally from one argument-less job, so there is nothing to collect and the ordering constraint about collecting first does not apply. The step is simply absent.
3. **`exclude_from_rankings` and `kind` are excluded from `BLANK_FILLABLE`**, per the spec's "Survivor always wins" line — and the reason is worth a code comment: `false.present?` is `false`, so including `exclude_from_rankings` would let a source's `true` silently overwrite the survivor's `false`.

---

## Task 1: Merger spine

**Files:**
- Create: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `::Books::Author::Merger.call(source:, target:) -> Result`; `::Books::Author::Merger.new(source:, target:)` with public `#call`, `#stats` (a Hash), `#source_author`, `#target_author`. `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. Private hooks later tasks fill in: `#merge_all_associations`, `#reconcile_scalars`, `#run_post_commit_steps`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/books/author/merger_test.rb`:

```ruby
require "test_helper"

module Books
  class Author
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = books_authors(:bachman)
        @target = books_authors(:king)

        # Sidekiq test mode is :inline, and the merger fires this job
        # unconditionally (author rankings recalculate globally, so there are no
        # configuration ids to gate on). Left unstubbed it runs a real ranking
        # calculation on every test in this file. The scheduling test in Task 8
        # re-declares this with `expects`, which Mocha checks ahead of this stub.
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
      end

      test "merges successfully and returns the target author" do
        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source author" do
        source_id = @source.id

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not ::Books::Author.exists?(source_id)
      end

      test "refuses to merge an author with itself" do
        result = ::Books::Author::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge an author with itself"], result.errors
        assert ::Books::Author.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Books::Author::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Books::Author.exists?(@source.id), "source must survive a failed merge"
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ps aux | grep "[r]ails test"    # must print nothing before running the suite
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Books::Author::Merger`.

- [ ] **Step 3: Write the minimal implementation**

Create `web-app/app/lib/books/author/merger.rb`:

```ruby
module Books
  class Author
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_author, :target_author, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_author = source
        @target_author = target
        @stats = {}
        @affected_book_ids = []
      end

      def call
        if source_author.id == target_author.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge an author with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          merge_all_associations
          reconcile_scalars
          target_author.save! if target_author.changed?
          destroy_source_author
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_author, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      # Unlike the games and books mergers there is no
      # collect_affected_ranking_configurations step: author rankings do not derive
      # from lists, so recalculation is one argument-less job rather than a set of
      # per-configuration ones, and there is nothing to capture before the destroy.
      def merge_all_associations
      end

      def reconcile_scalars
      end

      def run_post_commit_steps
      end

      def destroy_source_author
        source_author.destroy!
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 4 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the rollback test is not vacuous**

Temporarily change `ActiveRecord::Base.transaction do` to a bare `begin` block, re-run, and confirm "rolls the whole merge back when a step raises" goes **red**. Restore the transaction and confirm green again. (Increment 1's retro: merger assertions pass against dead code unusually easily; every rule needs this treatment.)

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): add Books::Author::Merger spine"
```

---

## Task 2: Identifiers, external links, AI chats, images, category items

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations` from Task 1.
- Produces: private `#merge_identifiers`, `#merge_external_links`, `#merge_ai_chats`, `#merge_images`, `#merge_category_items`. Stats keys `:identifiers`, `:external_links`, `:ai_chats`, `:images`, `:category_items` (each an Integer count of rows **moved**).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest` in `web-app/test/lib/books/author/merger_test.rb`:

```ruby
      test "moves identifiers the target does not already have" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_author_viaf, value: "111"
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, identifier.reload.identifiable_id
      end

      test "drops a source identifier the target already has" do
        Identifier.create!(identifiable: @source, identifier_type: :books_author_viaf, value: "222")
        Identifier.create!(identifiable: @target, identifier_type: :books_author_viaf, value: "222")

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, Identifier.where(
          identifiable: @target, identifier_type: :books_author_viaf, value: "222"
        ).count
      end

      test "moves external links" do
        link = ExternalLink.create!(
          parent: @source,
          name: "Wikipedia",
          url: "https://example.com/bachman",
          source: :wikipedia,
          link_category: :information
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.parent_id
      end

      test "moves AI chats" do
        chat = AiChat.create!(parent: @source, chat_type: :general, model: "gpt-4", provider: :openai)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, chat.reload.parent_id
      end

      test "demotes a moved image when the target already has a primary" do
        attach_image(@target, primary: true)
        source_image = attach_image(@source, primary: true)

        ::Books::Author::Merger.call(source: @source, target: @target)

        source_image.reload
        assert_equal @target.id, source_image.parent_id
        assert_not source_image.primary, "a second primary image would break primary_image"
      end

      test "keeps a moved image primary when the target has none" do
        source_image = attach_image(@source, primary: true)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert source_image.reload.primary
      end

      test "copies source categories the target lacks" do
        category = categories(:books_fiction_genre)
        CategoryItem.create!(category: category, item: @source)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.category_items.map(&:category_id), category.id
      end

      test "does not duplicate a category both authors share" do
        category = categories(:books_fiction_genre)
        CategoryItem.create!(category: category, item: @source)
        CategoryItem.create!(category: category, item: @target)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, CategoryItem.where(category: category, item: @target).count
      end
```

And add this helper as the last method inside `class MergerTest` (before its closing `end`):

```ruby
      def attach_image(author, primary:)
        author.images.create!(primary: primary) do |image|
          image.file.attach(
            io: StringIO.new("fake image data"),
            filename: "portrait.jpg",
            content_type: "image/jpeg"
          )
        end
      end
```

Every fixture and attribute above is verified — see "Verified context". Use them as written.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: the 8 new tests FAIL (nothing moves; e.g. `Expected: <king.id> Actual: <bachman.id>`).

- [ ] **Step 3: Write the implementation**

In `web-app/app/lib/books/author/merger.rb`, replace the empty `merge_all_associations` with:

```ruby
      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_ai_chats
        merge_images
        merge_category_items
      end

      def merge_identifiers
        count = 0
        source_author.identifiers.find_each do |identifier|
          existing = target_author.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_author.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_external_links
        @stats[:external_links] = source_author.external_links.update_all(parent_id: target_author.id)
      end

      def merge_ai_chats
        @stats[:ai_chats] = source_author.ai_chats.update_all(parent_id: target_author.id)
      end

      def merge_images
        has_target_primary = target_author.primary_image.present?
        count = 0

        source_author.images.find_each do |image|
          image.update!(
            parent_id: target_author.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end

      def merge_category_items
        count = 0
        source_author.category_items.find_each do |category_item|
          target_author.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 12 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify both branches of each repoint-or-drop are load-bearing**

Delete the `if existing ... identifier.destroy!` branch (leave only the `update!`), re-run, and confirm "drops a source identifier the target already has" goes **red**. Restore. Do the same for `has_target_primary` (delete the ternary, always keep `image.primary`) and confirm "demotes a moved image…" goes red. Restore and confirm green.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): move identifiers, links, chats, images and categories on author merge"
```

---

## Task 3: Descriptions

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations`.
- Produces: private `#merge_descriptions`; stats key `:descriptions` (Integer count moved).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest`:

```ruby
      test "moves a description the target does not have" do
        description = Description.create!(
          describable: @source, kind: :summary, locale: "en",
          source: :other, source_name: "Wikipedia", content: "A pen name."
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, description.reload.describable_id
      end

      test "drops a source description that collides with the target's" do
        Description.create!(
          describable: @source, kind: :summary, locale: "en",
          source: :other, source_name: "Wikipedia", content: "From the duplicate."
        )
        Description.create!(
          describable: @target, kind: :summary, locale: "en",
          source: :other, source_name: "Wikipedia", content: "From the survivor."
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        kept = Description.where(
          describable_type: "Books::Author", describable_id: @target.id,
          kind: :summary, locale: "en", source: :other, source_name: "Wikipedia"
        )
        assert_equal 1, kept.count
        assert_equal "From the survivor.", kept.first.content
      end

      test "demotes a moved description when the target already has a preferred one" do
        Description.create!(
          describable: @target, kind: :summary, locale: "en",
          source: :other, source_name: "Survivor Source", content: "Preferred.", rank: :preferred
        )
        moved = Description.create!(
          describable: @source, kind: :summary, locale: "en",
          source: :other, source_name: "Duplicate Source", content: "Also preferred.", rank: :preferred
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        moved.reload
        assert_equal @target.id, moved.describable_id
        assert_equal "normal", moved.rank,
          "two preferred rows for the same kind+locale violate the partial unique index"
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 3 new tests FAIL.

- [ ] **Step 3: Write the implementation**

Add `merge_descriptions` to the `merge_all_associations` list (after `merge_category_items`) and add the method:

```ruby
      # Two unique indexes apply: one on
      # (describable, kind, locale, source, source_name) with nulls_not_distinct,
      # and a partial one allowing a single rank=1 row per (describable, kind, locale).
      def merge_descriptions
        preferred_keys = target_author.descriptions.select(&:preferred?)
          .map { |description| [description.kind, description.locale] }
          .to_set
        count = 0

        source_author.descriptions.find_each do |description|
          collides = target_author.descriptions.exists?(
            kind: description.kind,
            locale: description.locale,
            source: description.source,
            source_name: description.source_name
          )

          if collides
            description.destroy!
            next
          end

          attrs = {describable_id: target_author.id}
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

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 15 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the demotion branch is load-bearing**

Delete the `if description.preferred? && preferred_keys.include?(...)` block, re-run, and confirm "demotes a moved description…" goes **red** (it should raise `RecordNotUnique` or fail the rank assertion). Restore and confirm green.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): move descriptions on author merge, honouring both unique indexes"
```

---

## Task 4: Book links and the affected-book collection

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations`.
- Produces: public `attr_reader :affected_book_ids` (Array of Integer, populated during the merge, consumed by Task 8's fan-out). Private `#merge_book_authors`; stats keys `:book_authors` (moved) and `:book_authors_dropped` (deleted as duplicates).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest`:

```ruby
      test "repoints the source's book links to the target" do
        link = ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2, role: :author
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.author_id
      end

      test "drops a book link the target already has" do
        # got_king already links :got to the target.
        ::Books::BookAuthor.create!(book: books_books(:got), author: @source, position: 2)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::BookAuthor.where(
          book: books_books(:got), author: @target
        ).count
      end

      test "records every book the source authored, including one dropped as a duplicate" do
        ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2
        )
        ::Books::BookAuthor.create!(book: books_books(:got), author: @source, position: 2)

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.call

        assert_equal(
          [books_books(:war_and_peace).id, books_books(:got).id].sort,
          merger.affected_book_ids.sort,
          "a book whose duplicate link was dropped still changed authorship and must be reindexed"
        )
      end
```

`books_books(:war_and_peace)` and `books_books(:got)` are both real fixtures — verified.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 3 new tests FAIL — the third with `NoMethodError: undefined method 'affected_book_ids'`.

- [ ] **Step 3: Write the implementation**

Add `affected_book_ids` to the `attr_reader` line:

```ruby
      attr_reader :source_author, :target_author, :stats, :affected_book_ids
```

Add `merge_book_authors` to `merge_all_associations` (after `merge_descriptions`) and add the method:

```ruby
      # Collected BEFORE any write: once the links are repointed there is no way to
      # tell which books changed authorship, and a book whose duplicate link was
      # *dropped* changed too -- it used to carry both authors and now carries one.
      #
      # delete_all/update_all rather than per-record destroy!/update!, for two
      # reasons. Books::BookAuthor has its own after_commit reindex hook that would
      # fire once per row and duplicate the batched fan-out run_post_commit_steps
      # already performs; and a prolific author can carry thousands of links, which
      # is a row-at-a-time query storm inside the merge transaction. The colliding
      # rows are deleted first, so the (book_id, author_id) unique index is never at
      # risk even though update_all skips the model's uniqueness validation.
      #
      # A subquery, not a plucked id list: this codebase has already hit
      # PostgreSQL's 65,535 bind-parameter cap with a large IN.
      #
      # `position` is not renumbered. It is scoped to the book, which does not
      # change, so every moved row keeps a valid position; a dropped duplicate can
      # leave a gap in one book's sequence, which is cosmetic.
      def merge_book_authors
        @affected_book_ids = source_author.book_ids

        dropped = ::Books::BookAuthor
          .where(author_id: source_author.id)
          .where(book_id: ::Books::BookAuthor.where(author_id: target_author.id).select(:book_id))
          .delete_all

        moved = ::Books::BookAuthor
          .where(author_id: source_author.id)
          .update_all(author_id: target_author.id)

        @stats[:book_authors] = moved
        @stats[:book_authors_dropped] = dropped
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 18 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the drop branch and the collection point are load-bearing**

Delete the `dropped = ...delete_all` statement, re-run, and confirm "drops a book link the target already has" goes **red** with a `RecordNotUnique` / `PG::UniqueViolation`. Restore. Then move `@affected_book_ids = source_author.book_ids` to the *end* of the method, re-run, and confirm "records every book the source authored…" goes **red** (it will come back empty). Restore both and confirm green.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): repoint book links on author merge and collect the affected books"
```

---

## Task 5: Credits

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations`.
- Produces: private `#merge_credits`; stats key `:credits` (Integer count moved).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest`:

```ruby
      test "moves a credit the target does not have" do
        credit = ::Books::Credit.create!(
          author: @source, creditable: books_editions(:wp_maude), role: :illustrator
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, credit.reload.author_id
      end

      test "drops a credit the target already has for the same work and role" do
        ::Books::Credit.create!(
          author: @source, creditable: books_editions(:wp_maude), role: :translator
        )
        ::Books::Credit.create!(
          author: @target, creditable: books_editions(:wp_maude), role: :translator
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::Credit.where(
          author: @target, creditable: books_editions(:wp_maude), role: :translator
        ).count
      end

      test "keeps a credit for the same work in a different role" do
        ::Books::Credit.create!(
          author: @source, creditable: books_editions(:wp_maude), role: :illustrator
        )
        ::Books::Credit.create!(
          author: @target, creditable: books_editions(:wp_maude), role: :translator
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        roles = ::Books::Credit.where(author: @target, creditable: books_editions(:wp_maude))
          .pluck(:role).sort
        assert_equal %w[illustrator translator].sort,
          roles.map { |role| ::Books::Credit.roles.key(role) || role }.sort,
          "role is part of the dedup key -- a different role is a different credit"
      end
```

**Note on the third test's `pluck`:** `pluck(:role)` returns raw integers, not enum strings. The `roles.key(...)` mapping converts them back. If that reads awkwardly when you write it, `::Books::Credit.where(...).map(&:role).sort` is equivalent and returns strings directly — either is fine, but do not assert on integers, which would silently pass if the enum mapping changed.

`books_editions(:wp_maude)` is a real fixture — verified.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 3 new tests FAIL.

- [ ] **Step 3: Write the implementation**

Add `merge_credits` to `merge_all_associations` (after `merge_book_authors`) and add the method:

```ruby
      # books_credits has NO unique index, so the dedup key -- creditable + role --
      # is enforced here or not at all. Two rows crediting the same person as
      # translator of the same edition is exactly the duplicate a merge is supposed
      # to remove, and nothing downstream would reject it.
      def merge_credits
        count = 0
        source_author.credits.find_each do |credit|
          collides = target_author.credits.exists?(
            creditable_type: credit.creditable_type,
            creditable_id: credit.creditable_id,
            role: credit.role
          )

          if collides
            credit.destroy!
          else
            credit.update!(author_id: target_author.id)
            count += 1
          end
        end
        @stats[:credits] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 21 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify both branches are load-bearing**

Delete the `role: credit.role` line from the `exists?` call, re-run, and confirm "keeps a credit for the same work in a different role" goes **red**. Restore. Then delete the whole `collides` check (always `update!`), re-run, and confirm "drops a credit the target already has…" goes **red**. Restore and confirm green. (Because there is no DB constraint here, the second check is the only thing standing between this rule and a silent regression.)

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): move credits on author merge, deduping on creditable and role"
```

---

## Task 6: Author relationships, both directions

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#merge_all_associations`.
- Produces: private `#merge_author_relationships`, `#merge_inverse_author_relationships`; stats keys `:author_relationships`, `:inverse_author_relationships` (Integer counts moved).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest`:

```ruby
      test "moves an outbound relationship to the target" do
        relationship = ::Books::AuthorRelationship.create!(
          from_author: @source, to_author: books_authors(:garnett), relation_type: :member_of
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.from_author_id
      end

      test "drops an outbound relationship that would point at the target itself" do
        # The bachman_is_king fixture is exactly this: bachman -> king.
        relationship = books_author_relationships(:bachman_is_king)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not ::Books::AuthorRelationship.exists?(relationship.id),
          "repointing this would make the survivor a pseudonym of itself"
      end

      test "drops an outbound relationship the target already has" do
        ::Books::AuthorRelationship.create!(
          from_author: @source, to_author: books_authors(:garnett), relation_type: :member_of
        )
        ::Books::AuthorRelationship.create!(
          from_author: @target, to_author: books_authors(:garnett), relation_type: :member_of
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::AuthorRelationship.where(
          from_author: @target, to_author: books_authors(:garnett), relation_type: :member_of
        ).count
      end

      test "moves an inbound relationship to the target" do
        relationship = ::Books::AuthorRelationship.create!(
          from_author: books_authors(:garnett), to_author: @source, relation_type: :member_of
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.to_author_id
      end

      test "drops an inbound relationship that would come from the target itself" do
        relationship = ::Books::AuthorRelationship.create!(
          from_author: @target, to_author: @source, relation_type: :member_of
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not ::Books::AuthorRelationship.exists?(relationship.id),
          "repointing this would make the survivor a member of itself"
      end

      test "drops an inbound relationship the target already has" do
        ::Books::AuthorRelationship.create!(
          from_author: books_authors(:garnett), to_author: @source, relation_type: :member_of
        )
        ::Books::AuthorRelationship.create!(
          from_author: books_authors(:garnett), to_author: @target, relation_type: :member_of
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::AuthorRelationship.where(
          from_author: books_authors(:garnett), to_author: @target, relation_type: :member_of
        ).count
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: the 6 new tests FAIL. Several will fail with `ActiveRecord::RecordInvalid` ("cannot relate an author to itself") or a unique-index violation surfacing as a failed `result.success?` — that is the point: without these rules the merge rolls back entirely.

- [ ] **Step 3: Write the implementation**

Add both methods to `merge_all_associations` (after `merge_credits`, outbound first) and add:

```ruby
      # Repoints from_author_id. Two rows must be dropped instead: one that already
      # points AT the target (repointing it makes the survivor relate to itself,
      # which no_self_reference rejects and the whole merge would roll back on), and
      # one the target already holds, which the (from, to, relation_type) unique
      # index would reject.
      def merge_author_relationships
        count = 0
        source_author.author_relationships.find_each do |relationship|
          if relationship.to_author_id == target_author.id
            relationship.destroy!
            next
          end

          collides = ::Books::AuthorRelationship.exists?(
            from_author_id: target_author.id,
            to_author_id: relationship.to_author_id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(from_author_id: target_author.id)
            count += 1
          end
        end
        @stats[:author_relationships] = count
      end

      # The mirror image: repoints to_author_id, with the same two drops. Direction
      # is meaningful (A is a pseudonym of B is not B is a pseudonym of A), so a
      # relationship that survives in one direction is not a duplicate of one in the
      # other and both are kept.
      def merge_inverse_author_relationships
        count = 0
        source_author.inverse_author_relationships.find_each do |relationship|
          if relationship.from_author_id == target_author.id
            relationship.destroy!
            next
          end

          collides = ::Books::AuthorRelationship.exists?(
            from_author_id: relationship.from_author_id,
            to_author_id: target_author.id,
            relation_type: relationship.relation_type
          )

          if collides
            relationship.destroy!
          else
            relationship.update!(to_author_id: target_author.id)
            count += 1
          end
        end
        @stats[:inverse_author_relationships] = count
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 27 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify every branch is load-bearing**

Four separate checks, restoring after each:

1. Delete the `to_author_id == target_author.id` guard → "drops an outbound relationship that would point at the target itself" goes red.
2. Delete the outbound `collides` check → "drops an outbound relationship the target already has" goes red.
3. Delete the `from_author_id == target_author.id` guard → "drops an inbound relationship that would come from the target itself" goes red.
4. Delete the inbound `collides` check → "drops an inbound relationship the target already has" goes red.

Confirm all green after restoring.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): move author relationships in both directions on merge"
```

---

## Task 7: Scalar reconciliation and name absorption

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#reconcile_scalars` from Task 1.
- Produces: `BLANK_FILLABLE` constant; private `#fill_blank_fields`, `#absorb_alternate_names`. Stats keys `:filled_fields` (Array of Symbol) and `:alternate_names_added` (Array of String).

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest`:

```ruby
      test "fills a blank sort name from the source" do
        @source.update!(sort_name: "Bachman, Richard")

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal "Bachman, Richard", @target.reload.sort_name
      end

      test "never overwrites a field the target already has" do
        @source.update!(birth_year: 1900)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal 1947, @target.reload.birth_year, "the survivor's own value always wins"
      end

      test "absorbs the source's name into the target's alternate names" do
        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.alternate_names, "Richard Bachman",
          "folding a pseudonym in should leave the deleted spelling searchable"
      end

      test "absorbs the source's own alternate names too" do
        @source.update!(alternate_names: ["R. Bachman"])

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.alternate_names, "R. Bachman"
      end

      test "does not duplicate an alternate name the target already has" do
        @target.update!(alternate_names: ["Richard Bachman"])

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal ["Richard Bachman"], @target.reload.alternate_names
      end

      test "never records the survivor's own name as one of its alternate names" do
        @source.update!(alternate_names: [@target.name])

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not_includes @target.reload.alternate_names, @target.name
      end

      test "never lets the source's exclude_from_rankings overwrite the target's" do
        @source.update!(exclude_from_rankings: true)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not @target.reload.exclude_from_rankings,
          "false.present? is false, so a naive blank-fill would flip the survivor's flag"
      end

      test "never lets the source's kind overwrite the target's" do
        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal "person", @target.reload.kind,
          "the survivor must not become a pseudonym because the duplicate was one"
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: the first six FAIL; "never lets the source's exclude_from_rankings…" and "never lets the source's kind…" PASS already (nothing fills them yet). That is fine — they are regression guards for Step 3, and Step 5 proves they bite.

- [ ] **Step 3: Write the implementation**

Add the constant just below `Result` in `web-app/app/lib/books/author/merger.rb`:

```ruby
      # The survivor's own non-blank value always wins; these are only filled when it
      # has none. `kind` and `exclude_from_rankings` are deliberately absent. `kind`
      # is NOT NULL with a default, so it is never blank -- and folding a pseudonym
      # into a person must not turn the person into a pseudonym. `exclude_from_rankings`
      # is a NOT NULL boolean defaulting to false, and `false.present?` is false, so
      # including it here would let a source's `true` silently overwrite a survivor's
      # `false` and drop the survivor out of the rankings.
      BLANK_FILLABLE = %i[sort_name birth_year death_year gender description].freeze
```

Replace the empty `reconcile_scalars` with:

```ruby
      def reconcile_scalars
        fill_blank_fields
        absorb_alternate_names
      end

      def fill_blank_fields
        filled = []

        BLANK_FILLABLE.each do |field|
          next if target_author.public_send(field).present?

          value = source_author.public_send(field)
          next if value.blank?

          target_author.public_send(:"#{field}=", value)
          filled << field
        end

        @stats[:filled_fields] = filled
      end

      # Absorbing the duplicate's name is often the whole point of the merge: folding
      # "J.R.R. Tolkien" into "J. R. R. Tolkien" should leave the deleted spelling
      # findable. alternate_names is GIN-indexed and feeds as_indexed_json, so the
      # search index picks this up on the target's reindex.
      def absorb_alternate_names
        existing = Array(target_author.alternate_names)
        incoming = ([source_author.name] + Array(source_author.alternate_names))
          .map { |value| value.to_s.strip }
          .compact_blank

        merged = (existing + incoming).uniq - [target_author.name]
        return if merged == existing

        @stats[:alternate_names_added] = merged - existing
        target_author.alternate_names = merged
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 35 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the exclusions are load-bearing**

Add `:exclude_from_rankings` to `BLANK_FILLABLE`, re-run, and confirm "never lets the source's exclude_from_rankings overwrite the target's" goes **red**. Remove it. Add `:kind`, re-run, and confirm "never lets the source's kind overwrite the target's" goes **red**. Remove it. Then delete the `- [target_author.name]` from `absorb_alternate_names`, re-run, and confirm "never records the survivor's own name…" goes **red**. Restore all three and confirm green.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): blank-fill scalars and absorb alternate names on author merge"
```

---

## Task 8: Post-commit — reindexing, the book fan-out, and the ranking job

**Files:**
- Modify: `web-app/app/lib/books/author/merger.rb`
- Test: `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: `#run_post_commit_steps` from Task 1, `@affected_book_ids` from Task 4.
- Produces: `REINDEX_BATCH_SIZE` constant; private `#reindex_target_author`, `#reindex_affected_books`, `#schedule_ranking_recalculation`. Stats key `:post_commit_error` (String, set only on failure). This is the last change to the merger; after this task `::Books::Author::Merger` is complete and Task 9 consumes it.

- [ ] **Step 1: Write the failing tests**

Append inside `class MergerTest`, and add the `neutralize_scalar_confound` helper next to `attach_image`:

```ruby
      test "queues the target for reindexing" do
        neutralize_scalar_confound

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error]
        assert SearchIndexRequest.exists?(
          parent_type: "Books::Author", parent_id: @target.id, action: "index_item"
        )
      end

      test "does not queue indexing while migration suppression is on" do
        neutralize_scalar_confound
        Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not SearchIndexRequest.exists?(
          parent_type: "Books::Author", parent_id: @target.id, action: "index_item"
        )
      end

      test "queues a reindex for every book the source authored" do
        ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2
        )
        ::Books::BookAuthor.create!(book: books_books(:got), author: @source, position: 2)
        SearchIndexRequest.where(parent_type: "Books::Book").delete_all

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.call

        assert_nil merger.stats[:post_commit_error]
        queued = SearchIndexRequest.where(
          parent_type: "Books::Book", action: "index_item"
        ).pluck(:parent_id).uniq.sort
        assert_equal(
          [books_books(:war_and_peace).id, books_books(:got).id].sort, queued,
          "a book's search document embeds author_names/author_ids, so both the moved " \
          "link and the dropped duplicate change what the book indexes"
        )
      end

      test "does not queue book reindexes while migration suppression is on" do
        ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2
        )
        SearchIndexRequest.where(parent_type: "Books::Book").delete_all
        Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 0, SearchIndexRequest.where(parent_type: "Books::Book").count
      end

      test "schedules the author ranking recalculation" do
        ::Books::CalculateAuthorRankingsJob.expects(:perform_async).once

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error],
          "a violated Mocha expectation in a post-commit step is swallowed into this key"
      end

      test "still reports success when scheduling the ranking job fails" do
        source_id = @source.id

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.stubs(:schedule_ranking_recalculation).raises(StandardError.new("redis down"))

        result = merger.call

        assert result.success?,
          "a post-commit failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not ::Books::Author.exists?(source_id), "the merge itself must still have committed"
        assert_equal "redis down", merger.stats[:post_commit_error]
      end

      test "still reports success when reindexing the target fails" do
        source_id = @source.id

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.stubs(:reindex_target_author).raises(StandardError.new("opensearch down"))

        result = merger.call

        assert result.success?,
          "a post-commit failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not ::Books::Author.exists?(source_id), "the merge itself must still have committed"
        assert_equal "opensearch down", merger.stats[:post_commit_error]
      end
```

Helper (place beside `attach_image`):

```ruby
      # reconcile_scalars all but always dirties the target -- absorbing the source's
      # name into alternate_names alone does it -- and target_author.save! then fires
      # SearchIndexable's after_commit, creating the very index_item row the two
      # reindex tests are trying to attribute to reindex_target_author. Without this
      # they pass with that method stubbed empty. Pre-load the absorption result so
      # reconcile_scalars finds nothing to change, using update_columns to skip both
      # validations and callbacks.
      def neutralize_scalar_confound
        @target.update_columns(alternate_names: [@source.name])
        @target.reload
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: the 7 new tests FAIL — no index requests, no job scheduled, `NoMethodError` on the stubbed private methods.

- [ ] **Step 3: Write the implementation**

Add the constant below `BLANK_FILLABLE`:

```ruby
      # 1,000 rows x 4 columns is 4,000 bind parameters per statement, comfortably
      # under PostgreSQL's 65,535 cap even for an author with tens of thousands of
      # books.
      REINDEX_BATCH_SIZE = 1000
```

Replace the empty `run_post_commit_steps` with:

```ruby
      # The merge is committed by this point. Reindexing and ranking recalculation
      # are follow-up work: if they fail, the merge still happened, so a failure
      # here must not be reported as a failed merge. `success?` means "the merge
      # committed", and that is what the admin UI reports.
      def run_post_commit_steps
        reindex_target_author
        reindex_affected_books
        schedule_ranking_recalculation
      rescue => error
        Rails.logger.error(
          "Books::Author::Merger: merge of #{source_author.id} into #{target_author.id} " \
          "committed, but post-commit follow-up failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
      end

      # SearchIndexable already respects this flag on its own callbacks; the merger
      # matches it rather than writing requests during a bulk migration.
      def reindex_target_author
        return if Services::BooksMigration.search_indexing_suppressed?

        SearchIndexRequest.create!(parent: target_author, action: :index_item)
      end

      # Books must be reindexed explicitly. Books::Book#as_indexed_json embeds
      # author_names and author_ids, but Books::Author#queue_books_for_reindexing
      # fires only on a *name* change and only for the source's books, which are
      # about to be reassigned -- and merge_book_authors uses bulk operations that
      # skip Books::BookAuthor's own reindex callback. So the fan-out lives here,
      # over the ids collected before the repoint.
      def reindex_affected_books
        return if Services::BooksMigration.search_indexing_suppressed?
        return if affected_book_ids.blank?

        now = Time.current
        affected_book_ids.each_slice(REINDEX_BATCH_SIZE) do |batch|
          rows = batch.map do |book_id|
            {
              parent_type: "Books::Book",
              parent_id: book_id,
              action: SearchIndexRequest.actions[:index_item],
              created_at: now,
              updated_at: now
            }
          end
          SearchIndexRequest.insert_all(rows)
        end
      end

      # Author rankings derive from book rankings rather than from lists, so unlike
      # the games and books mergers there are no per-configuration jobs to schedule.
      # This one job resolves Books::Authors::RankingConfiguration.default_primary
      # itself. perform_async writes to Redis, which a rollback cannot undo -- hence
      # post-commit, never inside the transaction.
      def schedule_ranking_recalculation
        ::Books::CalculateAuthorRankingsJob.perform_async
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/author/merger_test.rb
```

Expected: 42 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the reindex tests are not confounded**

Stub `reindex_target_author` to do nothing (`def reindex_target_author; end`), re-run, and confirm "queues the target for reindexing" goes **red**. If it stays green, `neutralize_scalar_confound` is not doing its job — the `target.save!` callback is creating the row instead. Restore. Then do the same for `reindex_affected_books` and confirm "queues a reindex for every book the source authored" goes red. Restore and confirm green.

- [ ] **Step 6: Lint and run the whole merger + adjacent suites, then commit**

```bash
ps aux | grep "[r]ails test"
bundle exec standardrb app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
bin/rails test test/lib/books/ test/models/books/
git add app/lib/books/author/merger.rb test/lib/books/author/merger_test.rb
git commit -m "feat(books): reindex the target and its books and recalculate author rankings after merge"
```

---

## Task 9: The MergeAuthor action class

**Files:**
- Create: `web-app/app/lib/actions/admin/books/merge_author.rb`
- Test: `web-app/test/lib/actions/admin/books/merge_author_test.rb`

**Interfaces:**
- Consumes: `::Books::Author::Merger` (complete after Task 8), `Actions::Admin::BaseAction`.
- Produces: `Actions::Admin::Books::MergeAuthor` with `.name`, `.message`, `.confirm_button_label`, `.visible?(context)`, `.destructive? # => true`, and `#call -> Actions::Admin::BaseAction::ActionResult`. Reads `fields[:source_author_id]` and `fields[:confirm_merge]`. Task 10's controller and Task 11's modal both depend on the field names `source_author_id` and `confirm_merge` and on the action name string `"MergeAuthor"`.

**⚠ Namespace hazard.** This file lives in `module Actions::Admin::Books`. A bare `Books::Author` there resolves to `Actions::Admin::Books::Author` and raises `NameError`. Every reference must be `::Books::Author`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/actions/admin/books/merge_author_test.rb`:

```ruby
require "test_helper"

module Actions
  module Admin
    module Books
      class MergeAuthorTest < ActiveSupport::TestCase
        def setup
          @user = users(:admin_user)
          @target = books_authors(:king)
          @source = books_authors(:bachman)

          ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
        end

        def call(fields)
          Actions::Admin::Books::MergeAuthor.call(
            user: @user, models: [@target], fields: fields
          )
        end

        test "is destructive" do
          assert Actions::Admin::Books::MergeAuthor.destructive?
        end

        test "merges and reports success" do
          result = call({source_author_id: @source.id.to_s, confirm_merge: "1"})

          assert result.success?, result.message
          assert_match(/Richard Bachman/, result.message)
          assert_not ::Books::Author.exists?(@source.id)
        end

        test "reports a warning, not a plain success, when the post-commit follow-up fails" do
          ::Books::Author::Merger.any_instance.stubs(:reindex_target_author)
            .raises(StandardError.new("opensearch down"))

          result = call({source_author_id: @source.id.to_s, confirm_merge: "1"})

          assert result.warning?, result.message
          assert_not result.success?, "a warning must not also report as a plain success"
          assert_match(/Richard Bachman/, result.message)
          assert_match(/source author has been deleted/, result.message)
          assert_match(/could not be scheduled/, result.message)
          assert_match(/opensearch down/, result.message)
          assert_not ::Books::Author.exists?(@source.id), "the merge itself must still have committed"
        end

        test "requires a source author id" do
          result = call({confirm_merge: "1"})

          assert result.error?
          assert_equal "Please select an author to merge.", result.message
          assert ::Books::Author.exists?(@source.id)
        end

        test "requires the confirmation checkbox" do
          result = call({source_author_id: @source.id.to_s})

          assert result.error?
          assert_match(/confirm/i, result.message)
          assert ::Books::Author.exists?(@source.id)
        end

        test "reports a missing source author" do
          result = call({source_author_id: "999999", confirm_merge: "1"})

          assert result.error?
          assert_equal "Author with ID 999999 not found.", result.message
        end

        test "refuses to merge an author with itself" do
          result = call({source_author_id: @target.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_equal "Cannot merge an author with itself. Please select a different author.", result.message
          assert ::Books::Author.exists?(@target.id)
        end

        test "refuses to act on more than one author" do
          result = Actions::Admin::Books::MergeAuthor.call(
            user: @user,
            models: [@target, @source],
            fields: {source_author_id: @source.id.to_s, confirm_merge: "1"}
          )

          assert result.error?
          assert_match(/single author/, result.message)
        end

        test "surfaces merger failures" do
          ::Books::Author::Merger.any_instance.stubs(:call).returns(
            ::Books::Author::Merger::Result.new(success?: false, data: nil, errors: ["nope"])
          )

          result = call({source_author_id: @source.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_match(/nope/, result.message)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/actions/admin/books/merge_author_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Actions::Admin::Books::MergeAuthor`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/actions/admin/books/merge_author.rb`:

```ruby
module Actions
  module Admin
    module Books
      # Every Books:: constant in here is root-anchored. Inside
      # Actions::Admin::Books, a bare `Books::Author` resolves to
      # Actions::Admin::Books::Author and raises a confusing NameError.
      class MergeAuthor < Actions::Admin::BaseAction
        def self.name
          "Merge Another Author Into This One"
        end

        def self.message
          "Search for a duplicate author to merge into the current author. The source author will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Author"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def self.destructive?
          true
        end

        def call
          return error("This action can only be performed on a single author.") if models.count != 1

          target_author = models.first

          source_author_id = fields[:source_author_id] || fields["source_author_id"]
          confirm_merge = fields[:confirm_merge] || fields["confirm_merge"]

          unless source_author_id.present?
            return error("Please select an author to merge.")
          end

          unless confirm_merge == "1" || confirm_merge == true
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_author = ::Books::Author.find_by(id: source_author_id)

          unless source_author
            return error("Author with ID #{source_author_id} not found.")
          end

          if source_author.id == target_author.id
            return error("Cannot merge an author with itself. Please select a different author.")
          end

          source_name = source_author.name
          source_id = source_author.id

          merger = ::Books::Author::Merger.new(source: source_author, target: target_author)
          result = merger.call

          if result.success?
            message = "Successfully merged '#{source_name}' (ID: #{source_id}) into '#{target_author.name}'. The source author has been deleted."

            if merger.stats[:post_commit_error].present?
              warn "#{message} Note: search reindexing and ranking recalculation could not be " \
                "scheduled (#{merger.stats[:post_commit_error]}); they will need to be re-run."
            else
              succeed message
            end
          else
            error "Failed to merge authors: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
```

**Note on `find_by(id: source_author_id)`:** `Books::Author` uses `friendly_id` with `:finders`, so `find` would also resolve slugs. `find_by(id:)` is deliberate and matches games — the modal always submits a numeric id from the autocomplete, and an id lookup cannot accidentally resolve a slug belonging to another record.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/actions/admin/books/merge_author_test.rb
```

Expected: 9 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the destructive? lint guard picks it up**

```bash
bin/rails test test/lint/merge_actions_destructive_test.rb
```

Expected: PASS. Then temporarily delete the `def self.destructive?` override, re-run, and confirm the lint test goes **red** naming `Actions::Admin::Books::MergeAuthor`. Restore it and confirm green. (This is the only place the merge permission gate is enforced; a silently missing override is exactly what this guard exists for.)

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/actions/admin/books/merge_author.rb test/lib/actions/admin/books/merge_author_test.rb
git add app/lib/actions/admin/books/merge_author.rb test/lib/actions/admin/books/merge_author_test.rb
git commit -m "feat(books): add the MergeAuthor admin action"
```

---

## Task 10: Route, policy, and controller

**Files:**
- Modify: `web-app/config/routes.rb` (the books `resources :authors` block, currently around line 474)
- Modify: `web-app/app/policies/books/author_policy.rb`
- Modify: `web-app/app/controllers/admin/books/authors_controller.rb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: `Actions::Admin::Books::MergeAuthor` from Task 9.
- Produces: route helper `execute_action_admin_books_author_path(author)` (POST); `Books::AuthorPolicy#execute_action?`; `Admin::Books::AuthorsController#execute_action` responding to both `turbo_stream` and `html`. Task 11's modal posts to this route.

- [ ] **Step 1: Write the failing tests**

Append inside `class AuthorsControllerTest` in `web-app/test/controllers/admin/books/authors_controller_test.rb`:

```ruby
      # Execute Action

      test "admin can merge one author into another" do
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
        sign_in_as(@admin_user, stub_auth: true)
        target = books_authors(:king)
        source = books_authors(:bachman)

        post execute_action_admin_books_author_path(target), params: {
          action_name: "MergeAuthor",
          source_author_id: source.id.to_s,
          confirm_merge: "1"
        }

        assert_redirected_to admin_books_author_path(target)
        assert_not ::Books::Author.exists?(source.id)
      end

      test "merge via turbo_stream replaces the flash target and still performs the merge" do
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
        sign_in_as(@admin_user, stub_auth: true)
        target = books_authors(:king)
        source = books_authors(:bachman)

        post execute_action_admin_books_author_path(target), params: {
          action_name: "MergeAuthor",
          source_author_id: source.id.to_s,
          confirm_merge: "1"
        }, as: :turbo_stream

        assert_response :success
        assert_match(/turbo-stream/, response.content_type)
        assert_includes response.body, 'target="flash"'
        assert_not ::Books::Author.exists?(source.id)
      end

      test "a books domain editor cannot merge" do
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        target = books_authors(:king)
        source = books_authors(:bachman)

        post execute_action_admin_books_author_path(target), params: {
          action_name: "MergeAuthor",
          source_author_id: source.id.to_s,
          confirm_merge: "1"
        }

        assert_redirected_to books_root_path
        assert ::Books::Author.exists?(source.id), "an editor must not be able to delete via merge"
      end

      test "a books domain moderator can merge" do
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
        @regular_user.domain_roles.create!(domain: :books, permission_level: :moderator)
        sign_in_as(@regular_user, stub_auth: true)
        target = books_authors(:king)
        source = books_authors(:bachman)

        post execute_action_admin_books_author_path(target), params: {
          action_name: "MergeAuthor",
          source_author_id: source.id.to_s,
          confirm_merge: "1"
        }

        assert_not ::Books::Author.exists?(source.id)
      end
```

The editor/moderator pair is the load-bearing test for the whole permission design and belongs at this layer, not in the policy unit test — the controller is the real entry point, and `execute_action?` alone returns `true` for an editor by design.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/admin/books/authors_controller_test.rb
```

Expected: FAIL — `NameError: undefined local variable or method 'execute_action_admin_books_author_path'`.

- [ ] **Step 3: Write the implementation**

**3a.** In `web-app/config/routes.rb`, inside the books `resources :authors do` block, add a `member` block alongside the existing `collection do get :search end`:

```ruby
      resources :authors do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :author_relationships, only: [:create]
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        member do
          post :execute_action
        end
        collection do
          get :search
        end
      end
```

**3b.** In `web-app/app/policies/books/author_policy.rb`, add `execute_action?` above the `Scope` class:

```ruby
    # execute_action is a shared admin endpoint: write access is the floor to
    # reach it at all. The controller additionally requires destroy? for any
    # action that declares itself destructive (currently only MergeAuthor), so
    # a domain-scoped editor (can_write? but not can_delete?) still cannot
    # merge, even though this policy method returns true for them.
    def execute_action?
      global_role? || domain_role&.can_write?
    end
```

**3c.** In `web-app/app/controllers/admin/books/authors_controller.rb`, add `:execute_action` to both `before_action` lists and add the action after `destroy`:

```ruby
  before_action :set_author, only: [:show, :edit, :update, :destroy, :execute_action]
  before_action :authorize_author, only: [:show, :edit, :update, :destroy, :execute_action]
```

```ruby
  def execute_action
    fields_hash = params.except(:controller, :action, :id, :action_name, :author_ids)

    action_class = "Actions::Admin::Books::#{params[:action_name]}".constantize
    authorize @author, :destroy? if action_class.destructive?
    result = action_class.call(
      user: current_user,
      models: [@author],
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
      format.html { redirect_to admin_books_author_path(@author), notice: result.message }
    end
  end
```

The `authorize @author, :destroy? if action_class.destructive?` line is the entire permission gate for merge — it must sit after the class is resolved and before it is invoked. Everything else here is a verbatim port of `Admin::Games::GamesController#execute_action`, including the `constantize` of a params-derived class name, which follows the music and games precedent.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/admin/books/authors_controller_test.rb
```

Expected: all tests in the file pass, including the 4 new ones.

- [ ] **Step 5: Verify the gate is load-bearing**

Delete the `authorize @author, :destroy? if action_class.destructive?` line, re-run, and confirm "a books domain editor cannot merge" goes **red** (the editor now succeeds in deleting a record). Restore and confirm green. Then confirm the route exists as expected:

```bash
bin/rails routes -g execute_action | grep authors
```

Expected: one POST row for `execute_action_admin_books_author`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb config/routes.rb app/policies/books/author_policy.rb app/controllers/admin/books/authors_controller.rb test/controllers/admin/books/authors_controller_test.rb
git add config/routes.rb app/policies/books/author_policy.rb app/controllers/admin/books/authors_controller.rb test/controllers/admin/books/authors_controller_test.rb
git commit -m "feat(books): route and authorize execute_action on admin authors"
```

---

## Task 11: Merge button and modal

**Files:**
- Modify: `web-app/app/views/admin/books/authors/show.html.erb`

**Interfaces:**
- Consumes: `execute_action_admin_books_author_path` (Task 10), the `"MergeAuthor"` action name and the `source_author_id` / `confirm_merge` field names (Task 9), `search_admin_books_authors_path(exclude_id:)` (already shipped), `AutocompleteComponent`, `current_user_can_delete?`.
- Produces: `data-testid="merge-author-button"` and the dialog `id="merge-author-modal"`, both consumed by Task 12's E2E spec.

- [ ] **Step 1: Add the Merge button**

In `web-app/app/views/admin/books/authors/show.html.erb`, inside the header's `<div class="flex gap-2">`, between the Edit link and the Delete button:

```erb
      <% if current_user_can_delete? %>
        <button type="button"
                class="btn btn-warning btn-outline"
                data-testid="merge-author-button"
                onclick="document.getElementById('merge-author-modal').showModal()">
          <span>Merge</span>
        </button>
      <% end %>
```

Both Merge and Delete sit behind `current_user_can_delete?`, matching the controller gate.

- [ ] **Step 2: Add the modal at the end of the file**

Append to `web-app/app/views/admin/books/authors/show.html.erb`, after the last closing tag:

```erb
<!-- Merge Author Modal -->
<dialog id="merge-author-modal" class="modal">
  <div class="modal-box max-w-2xl">
    <h3 class="font-bold text-lg">Merge Another Author Into This One</h3>
    <p class="py-4">
      Search for a duplicate author to merge into <strong><%= @author.name %></strong>.
      Books, credits, relationships, categories, identifiers, images, links,
      descriptions and AI chats move across.
    </p>
    <p class="pb-4">
      Where <strong><%= @author.name %></strong> already has its own equivalent
      &mdash; the same book, the same credit, the same identifier, the same kind
      of description &mdash; the duplicate's copy is discarded rather than kept
      alongside it. <strong><%= @author.name %></strong> may also take details
      from the duplicate: any field it was missing, plus the duplicate's name and
      alternate names, which are added to its own alternate names.
      The duplicate author will be permanently deleted.
    </p>

    <%= form_with url: execute_action_admin_books_author_path(@author),
                  method: :post,
                  class: "space-y-4",
                  data: {
                    controller: "modal-form",
                    modal_form_modal_id_value: "merge-author-modal"
                  } do |f| %>
      <%= f.hidden_field :action_name, value: "MergeAuthor" %>

      <div>
        <%= f.label :source_author_id, class: "label" do %>
          <span class="font-semibold">Source Author <span class="text-error">*</span></span>
        <% end %>
        <%= render AutocompleteComponent.new(
          name: "source_author_id",
          url: search_admin_books_authors_path(exclude_id: @author.id),
          placeholder: "Search for author to merge...",
          required: true
        ) %>
        <label class="label">
          <span>Search for the duplicate author you want to merge into this one</span>
        </label>
      </div>

      <div>
        <label class="label cursor-pointer justify-start gap-2">
          <%= f.check_box :confirm_merge, class: "checkbox", required: true %>
          <span>I understand this action cannot be undone</span>
        </label>
        <label class="label">
          <span class="text-warning">The source author will be permanently deleted after merging</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="document.getElementById('merge-author-modal').close()">Cancel</button>
        <%= f.submit "Merge Author", class: "btn btn-warning" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

**On the copy:** this is the games wording adapted, and the adaptation is deliberate in two places. The games modal's "including entries in users' personal saved lists" clause is **removed** — authors are not listable, so there are no `user_list_items` to warn about. The "plus the duplicate's release year if that one is earlier" clause is **replaced** by the alternate-names sentence, which is author merge's equivalent mutation of the survivor. The general collision caveat is kept verbatim in shape: it took three review rounds in increment 1 precisely because enumerating exceptions per-association just surfaces the next one.

- [ ] **Step 3: Verify no removed daisyUI classes crept in**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS. If it fails, remove the offending class (`label-text`, `form-control`, …) — never add an allowlist entry.

- [ ] **Step 4: Verify the page still renders**

```bash
bin/rails test test/controllers/admin/books/authors_controller_test.rb
```

Expected: PASS — in particular "show renders for an admin" and "show renders for an author that has inbound relationships", which exercise this template.

- [ ] **Step 5: Commit**

```bash
git add app/views/admin/books/authors/show.html.erb
git commit -m "feat(books): add the merge button and modal to the admin author page"
```

---

## Task 12: E2E spec, documentation, and full-suite verification

**Files:**
- Create: `web-app/e2e/tests/books/admin/authors-merge.spec.ts`
- Modify: `docs/features/record-merge.md` (project root, **not** `web-app/docs/`)

**Interfaces:**
- Consumes: `data-testid="merge-author-button"` and the modal heading/submit copy from Task 11.
- Produces: nothing further.

- [ ] **Step 1: Write the E2E spec**

Create `web-app/e2e/tests/books/admin/authors-merge.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

// Deliberately does NOT perform a real merge. E2E runs against the development
// database, whose books data is irreversible and takes hours to rebuild, and a
// merge destroys a row with no undo. These drive the modal up to but not past
// submission, exactly as games-merge.spec.ts does.
test.describe("Books admin — author merge", () => {
  test("merge button opens the modal on an author show page", async ({ page }) => {
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/authors\/[^/]+$/);

    await page.getByTestId("merge-author-button").click();

    await expect(page.getByRole("heading", { name: "Merge Another Author Into This One" }))
      .toBeVisible();
    await expect(page.getByRole("button", { name: "Merge Author" })).toBeVisible();
  });

  test("merge requires the confirmation checkbox", async ({ page }) => {
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "View" }).first().click();
    await page.waitForURL(/\/admin\/authors\/[^/]+$/);

    await page.getByTestId("merge-author-button").click();
    await page.getByRole("button", { name: "Merge Author" }).click();

    // The checkbox is `required`, so the browser blocks submission and the modal stays open.
    await expect(page.getByRole("heading", { name: "Merge Another Author Into This One" }))
      .toBeVisible();
  });
});
```

- [ ] **Step 2: Run the E2E spec**

The dev server must be running and reachable on port 3000 — and it must be **this** worktree's server, not another one. `bin/dev` self-terminates in a non-TTY shell; use the split form:

```bash
lsof -i :3000            # confirm what is already serving, if anything
yarn build:all
bin/rails server         # in its own terminal, from this worktree
yarn test:e2e e2e/tests/books/admin/authors-merge.spec.ts
```

Expected: 2 passed. If every books admin spec times out on the public homepage instead, the e2e admin user lost its role — `bin/rails e2e:admin` restores it. CI does not run Playwright, so this is local-only verification.

- [ ] **Step 3: Update the feature doc**

Edit `docs/features/record-merge.md` (project root). Four changes:

**3a.** In "## Overview", replace the sentence that scopes the doc to games. It currently reads "Books and authors are planned as increments 2 and 3 of the same design; **this doc covers games only**, which is what exists today." Replace with:

```markdown
Books are planned as increment 3 of the same design; **this doc covers games and authors**, which
is what exists today. For the full three-domain design, including the per-association table for
books, see `docs/superpowers/specs/2026-08-23-record-merge-design.md`.
```

Also update the paragraph's opening so it names both mergers: `::Games::Game::Merger`
(`app/lib/games/game/merger.rb`) and `::Books::Author::Merger` (`app/lib/books/author/merger.rb`).

**3b.** Add a new section immediately after "## Games-specific rules":

```markdown
## Author-specific rules

- **Books are reindexed explicitly, and the ids are collected before any write.** A book's search
  document embeds `author_names` and `author_ids`, so every book the duplicate authored changes
  when its authorship moves. `Books::Author#queue_books_for_reindexing` cannot do this job: it
  fires only on a *name* change, and only over the source's books, which are about to be
  reassigned. The merger captures `source.book_ids` before repointing anything and bulk-inserts a
  `SearchIndexRequest` per book after the transaction commits, in batches of 1,000 to stay well
  under PostgreSQL's bind-parameter cap. Books whose duplicate link was *dropped* are in that set
  too — they used to carry both authors and now carry one.
- **`book_authors` move with `delete_all` + `update_all`, not per-record saves.** Colliding rows
  are deleted via a subquery first, then the rest are repointed in one statement. Both bulk
  operations skip `Books::BookAuthor`'s own `after_commit` reindex hook, which is the point: the
  merger owns the fan-out and does it once per book rather than once per link.
- **Ranking recalculation is one argument-less job.** Books and games schedule
  `BulkCalculateWeightsJob` + `CalculateRankingsJob` per affected ranking configuration, because
  their rankings derive from lists. Author rankings derive from *book* rankings, so an author merge
  fires `Books::CalculateAuthorRankingsJob.perform_async`, which resolves
  `Books::Authors::RankingConfiguration.default_primary` itself. There is consequently no
  `collect_affected_ranking_configurations` step in this merger, and no ordering constraint about
  running it first. (The converse also holds: a *book* merge gets author recalculation for free,
  because `CalculateRankingsJob` already cascades into that job.)
- **`credits` are deduped by the merger or not at all.** `books_credits` has no unique index, so
  the `(creditable_type, creditable_id, role)` key is enforced in application code. Two rows
  crediting the same person as translator of the same edition is exactly the duplicate a merge
  should remove, and nothing downstream would reject it.
- **Relationships are dropped in two cases, in both directions.** A relationship pointing at the
  survivor would become a self-relation, which `Books::AuthorRelationship`'s `no_self_reference`
  validation rejects — and since that raise happens inside the transaction, leaving it in place
  would roll the entire merge back. One the survivor already holds would violate the
  `(from_author_id, to_author_id, relation_type)` unique index. Direction is meaningful, so a
  surviving relationship in one direction is never treated as a duplicate of one in the other.
- **Authors are not listable.** There is no `list_items` or `user_list_items` on `Books::Author`,
  so the personal-saved-list caveat in the games modal has no author equivalent and is absent from
  the author modal by design, not by omission.
```

**3c.** In "## Scalar reconciliation", after the games bullet list and before the closing
`alternate_titles` paragraph, add:

```markdown
For authors the blank-filled fields are `sort_name`, `birth_year`, `death_year`, `gender` and
`description`. `kind` and `exclude_from_rankings` are deliberately excluded: `kind` is NOT NULL
with a default so it is never blank (and folding a pseudonym into a person must not turn the
person into a pseudonym), and `exclude_from_rankings` is a NOT NULL boolean defaulting to false —
`false.present?` is `false`, so blank-filling it would let a duplicate's `true` silently drop the
survivor out of the rankings.

Authors also **absorb names**: the duplicate's `name` and its own `alternate_names` are added to
the survivor's `alternate_names`, deduped, with the survivor's own name never listed among them.
This is often the point of the merge — folding "J.R.R. Tolkien" into "J. R. R. Tolkien" should
leave the deleted spelling findable. `alternate_names` is GIN-indexed and feeds `as_indexed_json`,
so the survivor's post-commit reindex picks it up.
```

Then amend the last line of that section, which currently says games have no `alternate_titles`
column "unlike the design's plan for books and authors" — authors now do this, so it should read
"unlike authors above, and unlike the design's plan for books".

**3d.** In "## Testing", add after the existing paragraph:

```markdown
`test/lib/books/author/merger_test.rb` follows the same shape with two additions specific to
authors. `Books::CalculateAuthorRankingsJob.perform_async` is stubbed in `setup`: Sidekiq runs
inline in tests and the author merger fires that job unconditionally, so an unstubbed merge would
run a real ranking calculation in every test. And the two reindex tests call a
`neutralize_scalar_confound` helper first — scalar reconciliation nearly always dirties the target
(absorbing the duplicate's name alone does it), and the resulting `target.save!` fires
`SearchIndexable`'s own `after_commit`, creating exactly the `index_item` row those tests mean to
attribute to the merger's explicit reindex. Without the helper they pass against a merger that
does no reindexing at all.
```

**3e.** In "## Related documentation", update the spec bullet so it no longer claims the
`Books::Author` merger is "not yet built" — only `Books::Book` remains.

- [ ] **Step 4: Run the full suite and linter**

```bash
ps aux | grep "[r]ails test"     # must print nothing
bin/rails db:test:prepare test
bundle exec standardrb
```

Expected: 0 failures, 0 errors, and **no new warning lines** beyond the two known upstream sources (`weighted_list_rank`'s position `puts`, and npm/yarn during `test:prepare`). A new warning is a regression — fix its cause rather than filtering the output.

- [ ] **Step 5: Confirm the increment is complete against the spec**

Re-read the "`Books::Author` merger" table in `docs/superpowers/specs/2026-08-23-record-merge-design.md` and confirm every row has a corresponding `merge_*` method and a test for **both** branches where the pattern is repoint-or-drop. Confirm the two author asymmetries (explicit book reindex fan-out; the different ranking job) are implemented and documented.

- [ ] **Step 6: Commit**

```bash
git add e2e/tests/books/admin/authors-merge.spec.ts ../docs/features/record-merge.md
git commit -m "test(books): add the author merge e2e spec and document the author merger"
```

- [ ] **Step 7: Report and stop**

Summarise what shipped, what was verified and how, and anything left open. **Do not push and do not open a PR without asking.** If a PR is wanted, note that the branch name lands in the merge commit message on `main` permanently — increment 1 shipped as `worktree-record-merge`, which is not a name anyone would choose deliberately, so rename the branch before pushing.

---

## Self-Review

**1. Spec coverage.** Every row of the spec's `Books::Author` merger table maps to a task:
`book_authors` → Task 4; `credits` → Task 5; `author_relationships` and
`inverse_author_relationships` → Task 6; `identifiers`, `category_items`, `images`,
`external_links`, `ai_chats` → Task 2; `descriptions` → Task 3; `ranked_items` (derived, dies with
the source) → nothing to do, covered by the absence of a collection step and explained in Task 1's
comment and the Task 12 doc. Scalars (`sort_name`, `birth_year`, `death_year`, `gender`,
`description` blank-filled; `kind` and `exclude_from_rankings` survivor-wins; `alternate_names`
absorbed) → Task 7. The two author asymmetries → Task 8. Admin plumbing (route, controller,
policy, action class, modal) → Tasks 9–11. Testing layers (merger unit, action class, controller,
E2E) → Tasks 1–8, 9, 10, 12 respectively. `exclude_id` on the search endpoint needs no work — it
already ships for authors, which the "Verified context" section records so nobody re-implements it.

**2. Ordering constraints.** Of the spec's five, three do not apply to authors (editions/
`default_edition_id`, the authors/credits gate, and inbound-FK repointing — authors have no
`on_delete: nullify` inbound FK). Constraint 3, "collect `source.book_ids` before repointing
`book_authors`", is Task 4, is asserted by a dedicated test, and Task 4's Step 5 proves the
assertion bites by moving the collection to the end of the method. Constraint 1, collecting
ranking configuration ids first, is void here and its absence is explained in code rather than
left as a silent omission.

**3. Type consistency.** `Result` is `Struct.new(:success?, :data, :errors, keyword_init: true)`
throughout. Stats keys are consistent across tasks and the action class reads exactly one of them,
`:post_commit_error` (String), set only in Task 8's rescue. `affected_book_ids` is introduced as a
public reader in Task 4 and consumed by name in Task 8. The action name string `"MergeAuthor"` and
the field names `source_author_id` / `confirm_merge` appear identically in Task 9's class, Task
10's controller tests, and Task 11's modal. `data-testid="merge-author-button"` and
`id="merge-author-modal"` are defined in Task 11 and used in Task 12.

**4. Placeholder scan.** No task defers work with "TBD", "similar to Task N", or "add error
handling". Every fixture name and model attribute the tests reference was checked against the repo
while writing this plan and is recorded in "Verified context" — nothing is left for the
implementer to guess or look up mid-task.

**5. Anti-vacuous-test discipline.** Every task has a Step 5 that deletes the code under test and
requires the corresponding test to go red. This is not ceremony: increment 1's retro recorded that
merger assertions pass against dead code unusually easily, and this repo has a documented history
of `assert_empty`, Capybara substring matching, and fixture-id coincidence producing green tests
over deleted branches.
