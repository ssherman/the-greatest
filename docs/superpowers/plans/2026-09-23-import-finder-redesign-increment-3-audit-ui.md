# Import Finder Redesign — Increment 3 (Audit UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two admin pages per domain (match decisions, duplicate candidates) so every finder decision and every suspected pair can be reviewed, re-checked, dismissed or merged, plus the Playwright spec that drives them on the books admin host.

**Architecture:** A small registry (`DataImporters::FinderRegistry`) says which finders and models each admin domain owns and how each model is merged. Two shared base controllers (`Admin::MatchDecisionsBaseController`, `Admin::DuplicateCandidatesBaseController`) scope every query by that registry and are subclassed per domain in a few lines, the way `Admin::ReviewsBaseController` is. Views live under the base controllers' view directories and are inherited. Merges post to each domain's existing `execute_action` endpoint (its delete gate and merger untouched) through one shared form partial carrying the same required confirm checkbox as the record pages' merge modal. Re-check runs the finder synchronously with `verify: true` and shows the new decision beside the old.

**Tech Stack:** Rails 8, Minitest 6 + fixtures + Mocha, pagy, DaisyUI 5 on Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` — §5 (data model), §13 (audit UI), §15 (testing), §16 (sweep). Increment 1 and 2 plans: `docs/superpowers/plans/2026-09-22-import-finder-redesign-increment-{1-core,2-books}.md`.

## Global Constraints

- Run every Rails/yarn command from `web-app/`. Docs live in `docs/` at the project root.
- Work only in this worktree on branch `worktree-import-finder-inc3-audit-ui`. Never commit to `main`. No push, no PR.
- **Agents run only `bin/rails test`, `bundle exec standardrb`, and `CI=1 bin/rails zeitwerk:check`.** Nothing touches the shared development database: no `bin/rails runner`, no rake task, no `yarn test:e2e`, no `e2e:import_finder_*` task. The Playwright spec and its seed tasks are delivered for Shane to run.
- Use generators for controllers and helpers (`bin/rails generate controller ...`, `bin/rails generate helper ...`), then edit what they produce. Delete generated files the plan says to delete.
- Every model constant inside `module Admin` or a controller is root-anchored (`::Books::Book`, `::MatchDecision`): a bare `Books::Book` inside `Admin::Books::...` resolves to the controller namespace.
- Route helper prefixes differ per domain and are fixed: books `admin_books_`, music `admin_` (its namespace carries no `as:`), games `admin_games_`. Confirm with `bin/rails routes -g match_decisions` after adding routes.
- Authorization: reading needs domain access (`authenticate_admin!` from `Admin::DomainScopedAuth`); review, re-check and dismiss are gated by `require_domain_write!`; merges are never performed by these controllers — the forms post to the domain's `execute_action`, whose `authorize @record, :destroy?` gate stands.
- Defaults (spec §13 plus the increment 2 carry-forward): the decisions index opens on `needs_review = true AND reviewed_at IS NULL` **with `verify: true` rows hidden** (the sweep writes one per ranked book); the duplicates index opens on `pending`.
- Every finder class under `app/lib/data_importers/**/finder.rb` has a `FinderRegistry` entry; the registry test enforces it.
- Views: `app/views/admin/match_decisions_base/`, `app/views/admin/duplicate_candidates_base/`, `app/views/admin/shared/_merge_form.html.erb`. Per-domain controllers add no views.
- Controller tests assert behaviour: status codes, redirects, `data-*` attributes, form actions and hidden field values. Never copy or CSS. Hosts: `host! Rails.application.config.domains[:books]` (`dev-new.thegreatestbooks.org`), `[:music]`, `[:games]`; sign in with `sign_in_as(user, stub_auth: true)`; a second host needs a second sign-in.
- Minitest 6: `assert_nil`, never `assert_equal nil`. No `require "sidekiq/testing"`.
- DaisyUI 5 only: none of `form-control label-text label-text-alt input-bordered select-bordered textarea-bordered file-input-bordered input-disabled table-hover tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any of them.
- Every new page gets `data-testid` attributes on rows and forms (kebab-case) because the E2E spec and the controller tests target them.
- Every Merge* action already exists; this plan adds none. `test/lint/merge_actions_destructive_test.rb` keeps passing untouched.
- Before claiming a task done: the task's tests, then `bin/rails test` (full suite), `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`. No new warnings.

## Rulings against the spec (recorded here, amended into the spec in Task 6)

1. **Pagination is `?page=N`**, as on every admin index (corrections, reviews). §13 says "path-based pagination"; the `PathBasedPagination` concern exists for edge-cached public pages, and the admin is `prevent_caching`. Cost if wrong: one include and one route each.
2. **Re-check is offered only where `FinderRegistry` says `recheck: true`** — books now. On a legacy-only finder `verify: true` would send one candidate to the AI for nothing (increment 1 carry-forward).
3. **The AI chat renders inline** (a `<details>` with the messages) instead of linking: the books admin has no AI chats page.
4. **Re-check excludes** the decision's subject when the subject is a record of the finder's own model (a sweep decision re-resolves that book against the rest), else the decision's record when the outcome was unmatched (the importer created it from this very query and it must not match itself), else nothing.
5. **Merge forms submit with `turbo: false`**, so `execute_action`'s HTML branch answers: a redirect to the surviving record with the result as flash. The turbo-stream branch would replace `#flash` and leave the page showing a pair or candidate that no longer exists.
6. **"Merge into candidate N" requires the decision to carry a record** (the importer sets it after creating the new item). A sweep decision has none; its pair is handled on the duplicates page.
7. **`Games::Company` has no merge action**, so its pairs and decisions offer dismissal and review only.
8. **The E2E spec is Shane's to run**: it writes to the development database through the seed task. Agents deliver it and say so.

---

### Task 1: `DataImporters::FinderRegistry`, `FinderBase#summarize`, `ImportQuery.from_snapshot`

**Files:**
- Create: `web-app/app/lib/data_importers/finder_registry.rb`
- Modify: `web-app/app/lib/data_importers/finder_base.rb` (public section, after `describe_candidate`)
- Modify: `web-app/app/lib/data_importers/books/book/import_query.rb`
- Test: `web-app/test/lib/data_importers/finder_registry_test.rb` (create)
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb` (add one test)
- Test: `web-app/test/lib/data_importers/books/book/import_query_test.rb` (add two tests; create the file if absent, `module DataImporters; module Books; module Book; class ImportQueryTest < ActiveSupport::TestCase`)

**Interfaces:**
- Produces: `DataImporters::FinderRegistry::Entry` with `finder`, `domain`, `model`, `label`, `query`, `preloads`, `merge_action`, `source_field`, `execute_action_path` (lambda record → path), `recheck`; methods `finder_class`, `model_class`, `query_class`, `mergeable?`, `recheck?`. Module methods `entry(finder_name)`, `entry_for_model(model_name)`, `for_domain(domain)`, `finders_for(domain)`, `models_for(domain)`.
- Produces: `FinderBase#summarize(record) -> Hash` with symbol keys `:title, :creators, :year, :ranked_position, :list_count, :identifiers` (array of `{type:, value:}`) plus the domain's extras (books: `:book_kind`, `:alternate_titles`).
- Produces: `DataImporters::Books::Book::ImportQuery.from_snapshot(hash) -> ImportQuery`.

- [ ] **Step 1: Write the failing registry test**

```ruby
# web-app/test/lib/data_importers/finder_registry_test.rb
# frozen_string_literal: true

require "test_helper"

module DataImporters
  class FinderRegistryTest < ActiveSupport::TestCase
    test "every finder class under app/lib/data_importers has exactly one entry" do
      files = Dir[Rails.root.join("app/lib/data_importers/**/finder.rb")]
      names = files.map { |file| file.sub(%r{.*app/lib/}, "").delete_suffix(".rb").camelize }

      assert names.any?, "no finder.rb files found -- did the layout change?"
      assert_equal names.sort, FinderRegistry::ENTRIES.map(&:finder).sort
    end

    test "each entry's finder is a FinderBase for the entry's model and its query class exists" do
      FinderRegistry::ENTRIES.each do |entry|
        assert_operator entry.finder_class, :<, FinderBase, entry.finder
        assert_equal entry.model_class, entry.finder_class.new.send(:model_class), entry.finder
        assert_operator entry.query_class, :<, DataImporters::ImportQuery, entry.finder
      end
    end

    test "a mergeable entry names a destructive admin action, a source field and an execute_action path" do
      records = {
        "Books::Book" => books_books(:war_and_peace),
        "Games::Game" => games_games(:half_life_2),
        "Music::Artist" => music_artists(:david_bowie),
        "Music::Album" => music_albums(:dark_side_of_the_moon),
        "Music::Song" => music_songs(:time)
      }

      mergeable = FinderRegistry::ENTRIES.select(&:mergeable?)
      assert_equal %w[Books::Book Games::Game Music::Album Music::Artist Music::Song], mergeable.map(&:model).sort

      mergeable.each do |entry|
        action = "Actions::Admin::#{entry.domain.to_s.camelize}::#{entry.merge_action}".constantize
        assert action.destructive?, entry.merge_action
        assert_match(/\Asource_\w+_id\z/, entry.source_field)
        assert_match %r{/admin/.+/execute_action\z}, entry.execute_action_path.call(records.fetch(entry.model))
      end
    end

    test "Games::Company is registered without a merge action" do
      entry = FinderRegistry.entry_for_model("Games::Company")

      assert_equal "DataImporters::Games::Company::Finder", entry.finder
      assert_not entry.mergeable?
      assert_nil entry.execute_action_path
    end

    test "for_domain groups entries by admin domain" do
      assert_equal ["Books::Book"], FinderRegistry.models_for(:books)
      assert_equal %w[Games::Company Games::Game], FinderRegistry.models_for(:games).sort
      assert_equal %w[Music::Album Music::Artist Music::Song], FinderRegistry.models_for("music").sort
      assert_equal ["DataImporters::Books::Book::Finder"], FinderRegistry.finders_for(:books)
      assert_empty FinderRegistry.for_domain(:movies)
    end

    test "only the books finder offers re-check" do
      assert_equal ["DataImporters::Books::Book::Finder"], FinderRegistry::ENTRIES.select(&:recheck?).map(&:finder)
    end

    test "entry lookups return nil for unknown names" do
      assert_nil FinderRegistry.entry("DataImporters::Nope::Finder")
      assert_nil FinderRegistry.entry_for_model("Books::Author")
    end
  end
end
```

Check the fixture names used above before running: `grep -n "^[a-z_]*:$" test/fixtures/music/artists.yml test/fixtures/music/songs.yml | head`. If `david_bowie` or `time` do not exist, substitute the first artist and song fixture names and keep the assertions.

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/data_importers/finder_registry_test.rb`
Expected: FAIL with `NameError: uninitialized constant DataImporters::FinderRegistry`.

- [ ] **Step 3: Write the registry**

```ruby
# web-app/app/lib/data_importers/finder_registry.rb
# frozen_string_literal: true

module DataImporters
  # Every finder the audit pages can show, keyed by the class name stored in
  # match_decisions.finder. An entry says which admin domain owns the finder,
  # which model it resolves, how that model is merged (the Actions::Admin::*
  # action name, the field that action reads the source id from, and the
  # record's execute_action route), what to preload for a summary, and whether
  # the finder's real sources have landed (recheck). A finder with no entry
  # never reaches an audit page: the decisions index filters by the domain's
  # registered finder names and the duplicates index by its registered models.
  module FinderRegistry
    URL_HELPERS = Rails.application.routes.url_helpers

    Entry = Struct.new(
      :finder, :domain, :model, :label, :query, :preloads,
      :merge_action, :source_field, :execute_action_path, :recheck,
      keyword_init: true
    ) do
      def finder_class = finder.constantize

      def model_class = model.constantize

      def query_class = query.constantize

      def mergeable? = merge_action.present?

      def recheck? = recheck == true
    end

    ENTRIES = [
      Entry.new(
        finder: "DataImporters::Books::Book::Finder", domain: :books, model: "Books::Book", label: "Book",
        query: "DataImporters::Books::Book::ImportQuery", preloads: [:authors],
        merge_action: "MergeBook", source_field: "source_book_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_books_book_path(record) },
        recheck: true
      ),
      Entry.new(
        finder: "DataImporters::Games::Game::Finder", domain: :games, model: "Games::Game", label: "Game",
        query: "DataImporters::Games::Game::ImportQuery", preloads: [:companies],
        merge_action: "MergeGame", source_field: "source_game_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_games_game_path(record) },
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Games::Company::Finder", domain: :games, model: "Games::Company", label: "Company",
        query: "DataImporters::Games::Company::ImportQuery", preloads: [],
        merge_action: nil, source_field: nil, execute_action_path: nil,
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Music::Artist::Finder", domain: :music, model: "Music::Artist", label: "Artist",
        query: "DataImporters::Music::Artist::ImportQuery", preloads: [],
        merge_action: "MergeArtist", source_field: "source_artist_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_artist_path(record) },
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Music::Album::Finder", domain: :music, model: "Music::Album", label: "Album",
        query: "DataImporters::Music::Album::ImportQuery", preloads: [:artists],
        merge_action: "MergeAlbum", source_field: "source_album_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_album_path(record) },
        recheck: false
      ),
      Entry.new(
        finder: "DataImporters::Music::Song::Finder", domain: :music, model: "Music::Song", label: "Song",
        query: "DataImporters::Music::Song::ImportQuery", preloads: [:artists],
        merge_action: "MergeSong", source_field: "source_song_id",
        execute_action_path: ->(record) { URL_HELPERS.execute_action_admin_song_path(record) },
        recheck: false
      )
    ].freeze

    BY_FINDER = ENTRIES.index_by(&:finder).freeze
    BY_MODEL = ENTRIES.index_by(&:model).freeze

    class << self
      def entry(finder_name) = BY_FINDER[finder_name.to_s]

      def entry_for_model(model_name) = BY_MODEL[model_name.to_s]

      def for_domain(domain) = ENTRIES.select { |entry| entry.domain == domain.to_sym }

      def finders_for(domain) = for_domain(domain).map(&:finder)

      def models_for(domain) = for_domain(domain).map(&:model)
    end
  end
end
```

The route helper names are confirmed by `bin/rails routes -g execute_action`: `execute_action_admin_books_book`, `execute_action_admin_games_game`, `execute_action_admin_artist`, `execute_action_admin_album`, `execute_action_admin_song`.

- [ ] **Step 4: Run the registry test**

Run: `bin/rails test test/lib/data_importers/finder_registry_test.rb`
Expected: PASS (7 runs). If the "every finder" test lists an extra file, register it; never delete a finder.

- [ ] **Step 5: Write the failing `summarize` test**

Append inside the existing test class in `web-app/test/lib/data_importers/books/book/finder_test.rb` (find its `setup`; use `Finder.new` with no client, as the existing tests construct it):

```ruby
      test "summarize returns the evidence the audit pages show for a local book" do
        book = books_books(:war_and_peace)
        summary = Finder.new.summarize(book)

        assert_equal "War and Peace", summary[:title]
        assert_equal ["Leo Tolstoy"], summary[:creators]
        assert_equal 1869, summary[:year]
        assert_equal book.list_items.count, summary[:list_count]
        assert_includes summary[:identifiers], {type: "books_work_isbn13", value: identifiers(:war_and_peace_isbn13).value}
        assert_equal "standalone", summary[:book_kind]
        assert_equal ["Voyna i mir"], summary[:alternate_titles]
        assert summary.key?(:ranked_position)
      end
```

If `book_kind` 0 is not `standalone` in `Books::Book`'s enum, read the enum and use its name for 0.

- [ ] **Step 6: Run it to verify it fails**

Run: `bin/rails test test/lib/data_importers/books/book/finder_test.rb -n /summarize/`
Expected: FAIL with `NoMethodError: undefined method 'summarize'`.

- [ ] **Step 7: Add `summarize` to `FinderBase`**

In `web-app/app/lib/data_importers/finder_base.rb`, directly after the `describe_candidate` method (still in the public section, before `protected`):

```ruby
    # The facts the audit pages show for a local record: the same evidence
    # hash every local candidate carries on a decision (title, creators,
    # year, ranked_position, list_count, identifiers, plus the domain's
    # extras), built live for a record the finder never saw.
    def summarize(record)
      evidence_for(record)
    end
```

- [ ] **Step 8: Run it**

Run: `bin/rails test test/lib/data_importers/books/book/finder_test.rb`
Expected: PASS.

- [ ] **Step 9: Write the failing `from_snapshot` tests**

In `web-app/test/lib/data_importers/books/book/import_query_test.rb` (create the file with `require "test_helper"` and the nested modules if it does not exist):

```ruby
      test "from_snapshot rebuilds a query from a stored match_decisions.query hash" do
        query = ImportQuery.from_snapshot(match_decisions(:low_confidence_book_match).query)

        assert_equal "War & Peace", query.title
        assert_equal ["Tolstoy"], query.author_names
        assert_nil query.year
        assert_empty query.isbn13
      end

      test "from_snapshot ignores keys the query does not know and keeps identifiers" do
        query = ImportQuery.from_snapshot({"title" => "Dune", "isbn13" => ["9780441013593"], "bogus" => 1, "year" => 1965})

        assert_equal ["9780441013593"], query.isbn13
        assert_equal 1965, query.year
        assert query.valid?
      end
```

- [ ] **Step 10: Run them to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/book/import_query_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'from_snapshot'`.

- [ ] **Step 11: Add `from_snapshot`**

In `web-app/app/lib/data_importers/books/book/import_query.rb`, after `attr_reader` and before `def initialize`:

```ruby
        SNAPSHOT_KEYS = %i[title author_names year isbn13 isbn10 asin goodreads_id open_library_work_key].freeze

        # Rebuilds a query from the hash FinderBase#query_snapshot stored on
        # match_decisions.query: one key per attribute above, string keys.
        # Unknown keys are dropped so an older row still loads. The audit
        # page's Re-check is the caller.
        def self.from_snapshot(snapshot)
          attributes = snapshot.to_h.symbolize_keys.slice(*SNAPSHOT_KEYS)
          new(title: attributes[:title], **attributes.except(:title))
        end
```

- [ ] **Step 12: Run them**

Run: `bin/rails test test/lib/data_importers/books/book/import_query_test.rb test/lib/data_importers/finder_registry_test.rb test/lib/data_importers/books/book/finder_test.rb`
Expected: PASS.

- [ ] **Step 13: Lint, zeitwerk, commit**

```bash
bundle exec standardrb app/lib/data_importers test/lib/data_importers
CI=1 bin/rails zeitwerk:check
git add app/lib/data_importers/finder_registry.rb app/lib/data_importers/finder_base.rb app/lib/data_importers/books/book/import_query.rb test/lib/data_importers/finder_registry_test.rb test/lib/data_importers/books/book/finder_test.rb test/lib/data_importers/books/book/import_query_test.rb
git commit -m "FinderRegistry names every finder's domain, model and merge action; FinderBase#summarize and ImportQuery.from_snapshot serve the audit pages"
```

---

### Task 2: Match decisions — fixtures, routes, base controller, per-domain controllers, index and show

**Files:**
- Modify: `web-app/test/fixtures/match_decisions.yml` (replace)
- Modify: `web-app/config/routes.rb` (three admin namespaces)
- Create (generator): `web-app/app/controllers/admin/match_decisions_base_controller.rb`
- Create (generator): `web-app/app/controllers/admin/books/match_decisions_controller.rb`, `web-app/app/controllers/admin/music/match_decisions_controller.rb`, `web-app/app/controllers/admin/games/match_decisions_controller.rb`
- Create (generator): `web-app/app/helpers/admin/import_finder_audit_helper.rb`
- Create: `web-app/app/views/admin/match_decisions_base/index.html.erb`, `web-app/app/views/admin/match_decisions_base/show.html.erb`
- Test: `web-app/test/controllers/admin/books/match_decisions_controller_test.rb`, `web-app/test/controllers/admin/music/match_decisions_controller_test.rb`, `web-app/test/controllers/admin/games/match_decisions_controller_test.rb`, `web-app/test/helpers/admin/import_finder_audit_helper_test.rb`

**Interfaces:**
- Consumes: `DataImporters::FinderRegistry` (Task 1).
- Produces: routes `admin_books_match_decisions_path`, `admin_books_match_decision_path(decision)` (and the `admin_`/`admin_games_` twins); controller helper methods `decisions_index_path(params = {})`, `decision_path(decision, params = {})`, `entries`, `entry_for(decision)`, `filter_params`; instance variables `@decision`, `@entry`, `@candidate_records` (hash keyed by `[record_type, record_id]`), `@compare`; view helpers `audit_query_line(decision)`, `audit_record_label(record)`, `audit_shared_identifiers(decision, candidate)`. Task 3 adds `review`/`recheck` and renders `admin/match_decisions_base/_actions.html.erb` from `show`.
- Filter params: `entity` (a label parameterized: `book`, `album`, ...), `outcome`, `confidence`, `decided_by`, `reviewed` ∈ `pending|reviewed|all` (default `pending`), `verify` ∈ `hide|include` (default `hide`), `page`.

- [ ] **Step 1: Replace the fixtures**

```yaml
# web-app/test/fixtures/match_decisions.yml
# The finders in test create their own rows; these give the audit pages
# rows to render, filter and scope. Candidate record ids go through
# FixtureSet.identify because fixture ids are hashes.

# Needs review, matched by the AI at low confidence. The default queue shows it.
low_confidence_book_match:
  finder: DataImporters::Books::Book::Finder
  record: war_and_peace (Books::Book)
  outcome: 0
  confidence: 3
  decided_by: 2
  verify: false
  query: {"title": "War & Peace", "author_names": ["Tolstoy"]}
  candidates: [{"record_type": "Books::Book", "record_id": <%= ActiveRecord::FixtureSet.identify(:war_and_peace) %>, "sources": ["opensearch"], "scores": {"opensearch": 7.2}, "evidence": {"title": "War and Peace", "creators": ["Leo Tolstoy"], "year": 1869, "identifiers": [{"type": "books_work_isbn13", "value": "9780140447934"}]}}]
  selected_index: 1
  reason: "Same title and author; year missing on the incoming item."
  needs_review: true

# A sweep row (Services::Books::FindDuplicates): verify on, the swept book as
# subject, nothing found. Hidden by default -- the sweep writes one per ranked book.
war_and_peace_sweep:
  finder: DataImporters::Books::Book::Finder
  subject: war_and_peace (Books::Book)
  outcome: 1
  confidence: 1
  decided_by: 1
  verify: true
  query: {"title": "War and Peace", "author_names": ["Leo Tolstoy"], "year": 1869, "isbn13": [], "isbn10": [], "asin": [], "goodreads_id": []}
  candidates: []
  reason: "No candidates."
  needs_review: false

# An import that created a new book (got) although a local candidate existed,
# sharing an ISBN with the query: the show page offers "Merge into candidate 1"
# (source got, target war_and_peace) and lists the shared identifier.
new_book_created:
  finder: DataImporters::Books::Book::Finder
  record: got (Books::Book)
  outcome: 1
  confidence: 3
  decided_by: 2
  verify: false
  query: {"title": "Game of Thrones", "author_names": ["George R. R. Martin"], "isbn13": ["9780553103540"]}
  candidates: [{"record_type": "Books::Book", "record_id": <%= ActiveRecord::FixtureSet.identify(:war_and_peace) %>, "sources": ["identifier", "opensearch"], "scores": {"opensearch": 4.1}, "evidence": {"title": "War and Peace", "creators": ["Leo Tolstoy"], "year": 1869, "identifiers": [{"type": "books_work_isbn13", "value": "9780553103540"}], "matched_identifier": {"type": "books_work_isbn13", "value": "9780553103540"}}}]
  reason: "The only candidate is a different work despite the shared ISBN."
  needs_review: true

# Reviewed already: absent from the default queue, present under reviewed=reviewed.
reviewed_book_match:
  finder: DataImporters::Books::Book::Finder
  record: crime_and_punishment (Books::Book)
  outcome: 0
  confidence: 2
  decided_by: 1
  verify: false
  query: {"title": "Crime & Punishment", "author_names": ["Dostoevsky"]}
  candidates: []
  reason: "Exact title match; one source failed."
  sources_failed: ["open_library"]
  needs_review: true
  reviewed_at: <%= 2.days.ago.to_fs(:db) %>
  reviewed_by: admin_user
  review_note: "Looks right."

# Another domain's decision, also needing review: never on the books pages.
dark_side_album_match:
  finder: DataImporters::Music::Album::Finder
  record: dark_side_of_the_moon (Music::Album)
  outcome: 0
  confidence: 2
  decided_by: 1
  verify: false
  query: {"title": "The Dark Side of the Moon", "artist": "Music::Artist#1"}
  candidates: []
  reason: "Title matched the artist's album."
  needs_review: true
```

Run `bin/rails test test/lib/data_importers test/models/match_decision_test.rb test/lib/services` afterwards: the old fixture's `record_id: 1` changed to a real id, and every existing test must still pass. If one asserts on the old literal, fix the test's expectation to the fixture's id.

- [ ] **Step 2: Add the routes**

In `web-app/config/routes.rb`, inside each of the three admin namespaces, directly after the `resources :corrections ... end` block for books (line ≈ 715) and games, and after `resources :corrections` in music (find it with `grep -n "resources :corrections" config/routes.rb`), add:

```ruby
      # Import finder audit (docs/features/import-finder.md): shared base
      # controllers subclassed per domain, like reviews.
      resources :match_decisions, only: [:index, :show] do
        member do
          post :review
          post :recheck
        end
      end
      resources :duplicate_candidates, only: [:index] do
        member do
          post :dismiss
        end
      end
```

The member routes for `review`, `recheck` and `dismiss` land in Tasks 3 and 4; a route to a not-yet-defined action is inert until requested. Confirm: `bin/rails routes -g match_decisions` shows `admin_books_match_decisions`, `admin_match_decisions`, `admin_games_match_decisions`, and `bin/rails routes -g duplicate_candidates` the same three prefixes.

- [ ] **Step 3: Generate the controllers and helper**

```bash
bin/rails generate controller admin/match_decisions_base --skip-routes --no-helper --no-assets --no-test-framework
bin/rails generate controller admin/books/match_decisions --skip-routes --no-helper --no-assets
bin/rails generate controller admin/music/match_decisions --skip-routes --no-helper --no-assets
bin/rails generate controller admin/games/match_decisions --skip-routes --no-helper --no-assets
bin/rails generate helper admin/import_finder_audit
```

The generators produce controllers inheriting from `ApplicationController` and empty test files; the next steps replace their bodies. Remove any `app/views/admin/books/match_decisions/` (or music/games) directory a generator created — views live in `app/views/admin/match_decisions_base/`.

- [ ] **Step 4: Write the failing books controller test (index and show)**

```ruby
# web-app/test/controllers/admin/books/match_decisions_controller_test.rb
require "test_helper"

module Admin
  module Books
    class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @regular = users(:regular_user)
        @pending = match_decisions(:low_confidence_book_match)
        @sweep = match_decisions(:war_and_peace_sweep)
        @created = match_decisions(:new_book_created)
        @reviewed = match_decisions(:reviewed_book_match)
        @music = match_decisions(:dark_side_album_match)
      end

      def row_ids
        css_select("[data-testid=decision-row]").map { |row| row["data-decision-id"].to_i }
      end

      test "index redirects unauthenticated users and regular users" do
        get admin_books_match_decisions_path
        assert_redirected_to books_root_path

        sign_in_as(@regular, stub_auth: true)
        get admin_books_match_decisions_path
        assert_redirected_to books_root_path
      end

      test "index allows a books domain viewer" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_match_decisions_path
        assert_response :success
      end

      test "index defaults to unreviewed decisions needing review, hides verify runs, and scopes to books finders" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path

        assert_response :success
        ids = row_ids
        assert_includes ids, @pending.id
        assert_includes ids, @created.id
        assert_not_includes ids, @sweep.id, "verify: true rows are hidden by default"
        assert_not_includes ids, @reviewed.id, "reviewed rows are hidden by default"
        assert_not_includes ids, @music.id, "another domain's finder never appears"
      end

      test "verify=include shows sweep rows under reviewed=all" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(verify: "include", reviewed: "all")

        assert_includes row_ids, @sweep.id
      end

      test "reviewed=reviewed shows only reviewed rows; reviewed=all shows both" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(reviewed: "reviewed")
        assert_equal [@reviewed.id], row_ids

        get admin_books_match_decisions_path(reviewed: "all")
        assert_includes row_ids, @reviewed.id
        assert_includes row_ids, @pending.id
      end

      test "outcome, confidence and decided_by filters narrow the rows" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decisions_path(outcome: "matched")
        assert_equal [@pending.id], row_ids

        get admin_books_match_decisions_path(outcome: "unmatched")
        assert_equal [@created.id], row_ids

        get admin_books_match_decisions_path(confidence: "medium", reviewed: "all")
        assert_equal [@reviewed.id], row_ids

        get admin_books_match_decisions_path(decided_by: "rule", reviewed: "all", verify: "include")
        assert_equal [@sweep.id, @reviewed.id].sort, row_ids.sort
      end

      test "an unknown filter value is ignored rather than raising" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(outcome: "nonsense", reviewed: "bogus", verify: "yes", entity: "cheese")

        assert_response :success
        assert_includes row_ids, @pending.id
      end

      test "entity filter matches the registry label" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(entity: "book")
        assert_includes row_ids, @pending.id

        get admin_books_match_decisions_path(entity: "album")
        assert_empty row_ids
      end

      test "rows carry the attributes the filters key on" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path

        assert_select "[data-testid=decision-row][data-decision-id=?][data-outcome=matched][data-confidence=low][data-decided-by=ai][data-verify=false]", @pending.id.to_s
      end

      test "index accepts a page parameter" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(page: 1)
        assert_response :success
      end

      test "show renders the decision, its candidates with the selected row marked, and the shared identifier" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@pending)

        assert_response :success
        assert_select "[data-testid=candidate-row][data-candidate-index='1'][data-selected=true]"

        get admin_books_match_decision_path(@created)
        assert_select "[data-testid=candidate-row][data-selected=false]"
        assert_select "[data-testid=shared-identifiers]", text: /9780553103540/
      end

      test "show links the candidate's admin page and the record's" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@created)

        assert_select "a[href=?]", admin_books_book_path(books_books(:war_and_peace))
        assert_select "a[href=?]", admin_books_book_path(books_books(:got))
      end

      test "show renders a compare panel for a re-check" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@sweep, compare: @pending.id)

        assert_select "[data-testid=recheck-comparison]"
        assert_select "[data-testid=recheck-comparison] a[href=?]", admin_books_match_decision_path(@pending)
      end

      test "show ignores a compare id from another domain" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@sweep, compare: @music.id)

        assert_response :success
        assert_select "[data-testid=recheck-comparison]", count: 0
      end

      test "show 404s for another domain's decision" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@music)
        assert_response :not_found
      end
    end
  end
end
```

Check `test/fixtures/users.yml` line 163: `books_viewer_user` exists with a `books_viewer` domain role (`test/fixtures/domain_roles.yml` line 51). If the role fixture is not linked to that user, create the role in `setup` instead: `@viewer.domain_roles.create!(domain: :books, permission_level: :viewer)`.

If `assert_response :not_found` fails because the test environment renders exceptions rather than 404 pages, use `assert_raises(ActiveRecord::RecordNotFound) { get ... }` — check how `test/controllers/admin/corrections_controller_test.rb` asserts a cross-domain miss and follow it.

- [ ] **Step 5: Write the music and games scoping tests**

```ruby
# web-app/test/controllers/admin/music/match_decisions_controller_test.rb
require "test_helper"

module Admin
  module Music
    class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:music]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index shows music finders' decisions and none of books'" do
        get admin_match_decisions_path

        assert_response :success
        ids = css_select("[data-testid=decision-row]").map { |row| row["data-decision-id"].to_i }
        assert_equal [match_decisions(:dark_side_album_match).id], ids
      end

      test "show renders a music decision" do
        get admin_match_decision_path(match_decisions(:dark_side_album_match))
        assert_response :success
      end
    end
  end
end
```

```ruby
# web-app/test/controllers/admin/games/match_decisions_controller_test.rb
require "test_helper"

module Admin
  module Games
    class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:games]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index renders with no games decisions and lists both games entities in the filter" do
        get admin_games_match_decisions_path

        assert_response :success
        assert_select "[data-testid=decision-row]", count: 0
        assert_select "select[name=entity] option[value=game]"
        assert_select "select[name=entity] option[value=company]"
      end
    end
  end
end
```

- [ ] **Step 6: Write the failing helper test**

```ruby
# web-app/test/helpers/admin/import_finder_audit_helper_test.rb
require "test_helper"

module Admin
  class ImportFinderAuditHelperTest < ActionView::TestCase
    include Admin::ImportFinderAuditHelper

    test "audit_query_line joins title, creators and year" do
      decision = MatchDecision.new(query: {"title" => "Dune", "author_names" => ["Frank Herbert"], "year" => 1965})
      assert_equal "Dune | by Frank Herbert | (1965)", audit_query_line(decision)
    end

    test "audit_query_line reads name and artist for other domains and falls back to the raw hash" do
      assert_equal "Pink Floyd", audit_query_line(MatchDecision.new(query: {"name" => "Pink Floyd"}))
      assert_equal "Animals | by Music::Artist#1", audit_query_line(MatchDecision.new(query: {"title" => "Animals", "artist" => "Music::Artist#1"}))
      assert_equal({"igdb_id" => 7}.to_json, audit_query_line(MatchDecision.new(query: {"igdb_id" => 7})))
    end

    test "audit_record_label prefers title, then name" do
      assert_equal "War and Peace", audit_record_label(books_books(:war_and_peace))
      assert_equal books_authors(:tolstoy).name, audit_record_label(books_authors(:tolstoy))
    end

    test "audit_shared_identifiers intersects the query's identifiers with the candidate's and adds the matched one" do
      decision = MatchDecision.new(query: {"isbn13" => ["111", "222"], "asin" => ["B1"]})
      candidate = {"evidence" => {"identifiers" => [{"type" => "books_work_isbn13", "value" => "222"}, {"type" => "books_work_asin", "value" => "B9"}], "matched_identifier" => {"type" => "books_work_asin", "value" => "B1"}}}

      assert_equal %w[222 B1], audit_shared_identifiers(decision, candidate)
      assert_empty audit_shared_identifiers(MatchDecision.new(query: {}), {"evidence" => {}})
    end
  end
end
```

- [ ] **Step 7: Run the new tests to verify they fail**

Run: `bin/rails test test/controllers/admin/books/match_decisions_controller_test.rb test/helpers/admin/import_finder_audit_helper_test.rb`
Expected: FAIL (undefined helper methods; `ActionController::MissingExactTemplate` or `NoMethodError` in the controllers).

- [ ] **Step 8: Write the helper**

```ruby
# web-app/app/helpers/admin/import_finder_audit_helper.rb
module Admin
  # View helpers shared by the match decisions and duplicate candidates pages.
  module ImportFinderAuditHelper
    # Keys a stored query may carry for its creators. Snapshots are per-domain
    # hashes (books: title/author_names/year; albums: title/artist; artists:
    # name), so this reads whichever is present rather than one ImportQuery.
    CREATOR_KEYS = %w[author_names artist artist_names company_names].freeze

    # Identifier keys a stored query may carry, across every domain's ImportQuery.
    IDENTIFIER_QUERY_KEYS = %w[
      isbn13 isbn10 asin goodreads_id open_library_work_key
      musicbrainz_id release_group_musicbrainz_id musicbrainz_recording_id igdb_id
    ].freeze

    # The stored query in one line: title or name, creators, year. A query
    # with none of those (an identifier-only import) shows as its JSON.
    def audit_query_line(decision)
      query = decision.query.to_h
      parts = [query["title"].presence || query["name"].presence]
      creators = CREATOR_KEYS.filter_map { |key| query[key].presence }.first
      parts << "by #{Array(creators).join(", ")}" if creators
      parts << "(#{query["year"]})" if query["year"].present?
      parts.compact.join(" | ").presence || query.to_json
    end

    def audit_record_label(record)
      record.respond_to?(:title) ? record.title : record.name
    end

    # Identifier values the query and a candidate snapshot both carry, plus
    # the value the Identifiers source matched on when the snapshot names it.
    def audit_shared_identifiers(decision, candidate)
      query = decision.query.to_h
      wanted = IDENTIFIER_QUERY_KEYS.flat_map { |key| Array(query[key]) }.map(&:to_s).compact_blank
      evidence = candidate.to_h["evidence"].to_h
      held = Array(evidence["identifiers"]).map { |identifier| identifier.to_h["value"].to_s }
      shared = wanted & held
      matched = evidence["matched_identifier"]
      shared |= [matched["value"].to_s] if matched.is_a?(Hash) && matched["value"].present?
      shared
    end
  end
end
```

- [ ] **Step 9: Write the base controller**

```ruby
# web-app/app/controllers/admin/match_decisions_base_controller.rb
# The audit surface for match_decisions (spec §13): the decisions the finders
# of one admin domain recorded. Each domain supplies a routable subclass
# naming its domain and route prefix (see Admin::Books::MatchDecisionsController);
# every query here is scoped to the finders DataImporters::FinderRegistry
# registers for that domain, so a books admin never reads, reviews or
# re-checks a music decision by id.
#
# Defaults are the queue's: decisions needing review and not yet reviewed,
# with verify runs hidden -- the duplicate sweep writes one verify: true row
# per ranked book, which would bury the imports this page exists for.
class Admin::MatchDecisionsBaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_decision, only: [:show]

  OUTCOMES = ::MatchDecision.outcomes.keys.freeze
  CONFIDENCES = ::MatchDecision.confidences.keys.freeze
  DECIDED_BY = ::MatchDecision.defined_enums.fetch("decided_by").keys.freeze
  REVIEWED = %w[pending reviewed all].freeze
  VERIFY = %w[hide include].freeze
  FILTER_KEYS = %w[entity outcome confidence decided_by reviewed verify].freeze
  PER_PAGE = 50

  helper_method :filter_params, :decisions_index_path, :decision_path, :entries, :entry_for

  def index
    @reviewed = REVIEWED.include?(params[:reviewed]) ? params[:reviewed] : "pending"
    @verify = VERIFY.include?(params[:verify]) ? params[:verify] : "hide"
    @pagy, @decisions = pagy(filtered_scope.includes(:record, :reviewed_by).newest_first, limit: PER_PAGE)
  end

  def show
    @entry = entry_for(@decision)
    @candidate_records = candidate_records(@decision)
    @compare = domain_scope.find_by(id: params[:compare]) if params[:compare].present?
  end

  private

  def domain
    raise NotImplementedError, "Subclass must implement domain"
  end

  # "admin_books_", "admin_" (music's namespace has no as:), "admin_games_".
  def route_prefix
    raise NotImplementedError, "Subclass must implement route_prefix"
  end

  def entries
    DataImporters::FinderRegistry.for_domain(domain)
  end

  def entry_for(decision)
    DataImporters::FinderRegistry.entry(decision.finder)
  end

  def domain_scope
    ::MatchDecision.where(finder: entries.map(&:finder))
  end

  def filtered_scope
    scope = domain_scope
    entity = entries.find { |entry| entry.label.parameterize == params[:entity].to_s }
    scope = scope.where(finder: entity.finder) if entity
    scope = scope.where(outcome: params[:outcome]) if OUTCOMES.include?(params[:outcome])
    scope = scope.where(confidence: params[:confidence]) if CONFIDENCES.include?(params[:confidence])
    scope = scope.where(decided_by: params[:decided_by]) if DECIDED_BY.include?(params[:decided_by])
    scope = case @reviewed
    when "pending" then scope.needing_review
    when "reviewed" then scope.where.not(reviewed_at: nil)
    else scope
    end
    scope = scope.where(verify: false) if @verify == "hide"
    scope
  end

  def set_decision
    @decision = domain_scope.find(params[:id])
  end

  # The local records the candidate snapshots name, one query per type, so
  # the candidate table can link them and the merge forms can target them.
  # Keyed by [record_type, record_id]; a record since merged away is absent.
  def candidate_records(decision)
    decision.candidates.group_by { |candidate| candidate["record_type"] }.each_with_object({}) do |(type, snapshots), records|
      entry = DataImporters::FinderRegistry.entry_for_model(type)
      next unless entry

      entry.model_class.where(id: snapshots.map { |candidate| candidate["record_id"] }).each do |record|
        records[[type, record.id]] = record
      end
    end
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end

  def decisions_index_path(params = {})
    public_send(:"#{route_prefix}match_decisions_path", params)
  end

  def decision_path(decision, params = {})
    public_send(:"#{route_prefix}match_decision_path", decision, params)
  end
end
```

`group_by` on `record_type` yields a `nil` key for external-only candidates; `entry_for_model(nil)` returns nil and the `next` skips it.

- [ ] **Step 10: Write the per-domain controllers**

```ruby
# web-app/app/controllers/admin/books/match_decisions_controller.rb
class Admin::Books::MatchDecisionsController < Admin::MatchDecisionsBaseController
  private

  def domain = :books

  def route_prefix = "admin_books_"
end
```

```ruby
# web-app/app/controllers/admin/music/match_decisions_controller.rb
class Admin::Music::MatchDecisionsController < Admin::MatchDecisionsBaseController
  private

  def domain = :music

  def route_prefix = "admin_"
end
```

```ruby
# web-app/app/controllers/admin/games/match_decisions_controller.rb
class Admin::Games::MatchDecisionsController < Admin::MatchDecisionsBaseController
  private

  def domain = :games

  def route_prefix = "admin_games_"
end
```

- [ ] **Step 11: Write the index view**

```erb
<%# web-app/app/views/admin/match_decisions_base/index.html.erb %>
<% content_for :title, "Match Decisions" %>

<div class="space-y-4">
  <h1 class="text-2xl font-bold">Match Decisions</h1>

  <%= form_with url: decisions_index_path, method: :get, class: "flex flex-wrap items-end gap-3", data: {testid: "decision-filters"} do |form| %>
    <div>
      <%= form.label :entity, "Entity", class: "label text-xs" %>
      <%= form.select :entity, options_for_select([["All", ""]] + entries.map { |entry| [entry.label, entry.label.parameterize] }, params[:entity]), {}, class: "select select-sm" %>
    </div>
    <div>
      <%= form.label :outcome, "Outcome", class: "label text-xs" %>
      <%= form.select :outcome, options_for_select([["All", ""]] + Admin::MatchDecisionsBaseController::OUTCOMES.map { |value| [value.humanize, value] }, params[:outcome]), {}, class: "select select-sm" %>
    </div>
    <div>
      <%= form.label :confidence, "Confidence", class: "label text-xs" %>
      <%= form.select :confidence, options_for_select([["All", ""]] + Admin::MatchDecisionsBaseController::CONFIDENCES.map { |value| [value.humanize, value] }, params[:confidence]), {}, class: "select select-sm" %>
    </div>
    <div>
      <%= form.label :decided_by, "Decided by", class: "label text-xs" %>
      <%= form.select :decided_by, options_for_select([["All", ""]] + Admin::MatchDecisionsBaseController::DECIDED_BY.map { |value| [value.humanize, value] }, params[:decided_by]), {}, class: "select select-sm" %>
    </div>
    <div>
      <%= form.label :reviewed, "Review", class: "label text-xs" %>
      <%= form.select :reviewed, options_for_select([["Needs review", "pending"], ["Reviewed", "reviewed"], ["All", "all"]], @reviewed), {}, class: "select select-sm" %>
    </div>
    <div>
      <%= form.label :verify, "Verify runs", class: "label text-xs" %>
      <%= form.select :verify, options_for_select([["Hide", "hide"], ["Include", "include"]], @verify), {}, class: "select select-sm" %>
    </div>
    <%= form.submit "Filter", class: "btn btn-sm" %>
    <%= link_to "Reset", decisions_index_path, class: "btn btn-sm btn-ghost" %>
  <% end %>

  <div class="overflow-x-auto">
    <table class="table bg-base-100">
      <thead>
        <tr><th>When</th><th>Query</th><th>Outcome</th><th>Record</th><th>Confidence</th><th>Decided by</th><th>Review</th></tr>
      </thead>
      <tbody>
        <% if @decisions.any? %>
          <% @decisions.each do |decision| %>
            <% entry = entry_for(decision) %>
            <tr data-testid="decision-row" data-decision-id="<%= decision.id %>" data-finder="<%= decision.finder %>"
                data-outcome="<%= decision.outcome %>" data-confidence="<%= decision.confidence %>"
                data-decided-by="<%= decision.decided_by %>" data-verify="<%= decision.verify %>"
                data-reviewed="<%= decision.reviewed_at.present? %>">
              <td class="whitespace-nowrap">
                <%= link_to decision.created_at.strftime("%Y-%m-%d %H:%M"), decision_path(decision), class: "link" %>
              </td>
              <td class="max-w-md truncate [overflow-wrap:anywhere]">
                <span class="badge badge-ghost badge-sm mr-1"><%= entry&.label || decision.finder.demodulize %></span>
                <%= audit_query_line(decision) %>
                <% if decision.verify? %><span class="badge badge-outline badge-sm ml-1">verify</span><% end %>
              </td>
              <td><span class="badge badge-sm <%= decision.matched? ? "badge-info" : "badge-ghost" %>"><%= decision.outcome %></span></td>
              <td class="[overflow-wrap:anywhere]">
                <% if decision.record %>
                  <% path = Admin::DomainRouting.path_for(decision.record) %>
                  <%= path ? link_to(audit_record_label(decision.record), path, class: "link") : audit_record_label(decision.record) %>
                <% else %>
                  —
                <% end %>
              </td>
              <td><%= decision.confidence %></td>
              <td><%= decision.decided_by %></td>
              <td class="whitespace-nowrap">
                <% if decision.reviewed_at %>
                  reviewed <%= decision.reviewed_at.to_date.iso8601 %>
                <% elsif decision.needs_review? %>
                  <span class="badge badge-warning badge-sm">needs review</span>
                <% else %>
                  —
                <% end %>
              </td>
            </tr>
          <% end %>
        <% else %>
          <tr><td colspan="7" class="text-center text-base-content/70 py-8">No decisions match these filters.</td></tr>
        <% end %>
      </tbody>
    </table>
  </div>

  <% if @pagy.pages > 1 %>
    <div class="mt-4 flex justify-center"><%== @pagy.series_nav %></div>
  <% end %>
</div>
```

- [ ] **Step 12: Write the show view**

```erb
<%# web-app/app/views/admin/match_decisions_base/show.html.erb %>
<% content_for :title, "Match Decision ##{@decision.id}" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <%= link_to "← Match Decisions", decisions_index_path, class: "btn btn-ghost btn-sm" %>
  </div>

  <% if @compare %>
    <div class="card bg-base-100 shadow" data-testid="recheck-comparison">
      <div class="card-body">
        <h2 class="card-title">Re-check of decision #<%= @compare.id %></h2>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead><tr><th></th><th>Original #<%= @compare.id %></th><th>Re-check #<%= @decision.id %></th></tr></thead>
            <tbody>
              <% [["Outcome", :outcome], ["Confidence", :confidence], ["Decided by", :decided_by]].each do |label, attribute| %>
                <tr><th><%= label %></th><td><%= @compare.public_send(attribute) %></td><td><%= @decision.public_send(attribute) %></td></tr>
              <% end %>
              <tr>
                <th>Record</th>
                <td><%= @compare.record ? audit_record_label(@compare.record) : "—" %></td>
                <td><%= @decision.record ? audit_record_label(@decision.record) : "—" %></td>
              </tr>
              <tr>
                <th>Reason</th>
                <td class="[overflow-wrap:anywhere]"><%= @compare.reason %></td>
                <td class="[overflow-wrap:anywhere]"><%= @decision.reason %></td>
              </tr>
            </tbody>
          </table>
        </div>
        <%= link_to "Back to the original decision", decision_path(@compare), class: "link" %>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <h1 class="card-title text-2xl">Match Decision #<%= @decision.id %></h1>
      <dl class="grid grid-cols-1 sm:grid-cols-3 gap-4 text-sm">
        <div><dt class="font-semibold">Finder</dt><dd><%= @entry&.label || @decision.finder %> <span class="text-base-content/60 [overflow-wrap:anywhere]"><%= @decision.finder %></span></dd></div>
        <div><dt class="font-semibold">When</dt><dd><%= @decision.created_at.strftime("%Y-%m-%d %H:%M:%S") %></dd></div>
        <div><dt class="font-semibold">Outcome</dt><dd><span class="badge <%= @decision.matched? ? "badge-info" : "badge-ghost" %>"><%= @decision.outcome %></span></dd></div>
        <div><dt class="font-semibold">Confidence</dt><dd><%= @decision.confidence %></dd></div>
        <div><dt class="font-semibold">Decided by</dt><dd><%= @decision.decided_by %></dd></div>
        <div><dt class="font-semibold">Verify</dt><dd><%= @decision.verify? ? "on (no early exit)" : "off" %></dd></div>
        <div><dt class="font-semibold">Sources failed</dt><dd><%= @decision.sources_failed.presence&.join(", ") || "—" %></dd></div>
        <div>
          <dt class="font-semibold">Record</dt>
          <dd class="[overflow-wrap:anywhere]">
            <% if @decision.record %>
              <% path = Admin::DomainRouting.path_for(@decision.record) %>
              <%= path ? link_to(audit_record_label(@decision.record), path, class: "link") : audit_record_label(@decision.record) %>
              <span class="text-base-content/60">#<%= @decision.record_id %></span>
            <% elsif @decision.record_id %>
              <%= @decision.record_type %> #<%= @decision.record_id %> <span class="badge badge-error badge-sm">missing</span>
            <% else %>
              —
            <% end %>
          </dd>
        </div>
        <div>
          <dt class="font-semibold">Subject</dt>
          <dd class="[overflow-wrap:anywhere]">
            <% if @decision.subject %>
              <% path = Admin::DomainRouting.path_for(@decision.subject) %>
              <% label = "#{@decision.subject_type} ##{@decision.subject_id}" %>
              <%= path ? link_to(label, path, class: "link") : label %>
            <% else %>
              —
            <% end %>
          </dd>
        </div>
        <div>
          <dt class="font-semibold">Review</dt>
          <dd>
            <% if @decision.reviewed_at %>
              reviewed <%= @decision.reviewed_at.strftime("%Y-%m-%d") %><%= " by #{@decision.reviewed_by.email}" if @decision.reviewed_by %>
              <% if @decision.review_note.present? %><p class="[overflow-wrap:anywhere]"><%= @decision.review_note %></p><% end %>
            <% elsif @decision.needs_review? %>
              <span class="badge badge-warning badge-sm">needs review</span>
            <% else %>
              not flagged
            <% end %>
          </dd>
        </div>
      </dl>
    </div>
  </div>

  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <h2 class="card-title">Query</h2>
      <dl class="grid grid-cols-1 sm:grid-cols-2 gap-2 text-sm">
        <% @decision.query.to_h.each do |key, value| %>
          <div>
            <dt class="font-semibold"><%= key.to_s.humanize %></dt>
            <dd class="[overflow-wrap:anywhere]"><%= value.is_a?(Array) ? (value.join(", ").presence || "—") : (value.to_s.presence || "—") %></dd>
          </div>
        <% end %>
      </dl>
    </div>
  </div>

  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <h2 class="card-title">Candidates <span class="badge badge-ghost"><%= @decision.candidates.size %></span></h2>
      <% if @decision.candidates.any? %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr><th>#</th><th>Where</th><th>Title</th><th>Creators</th><th>Year</th><th>Ranked</th><th>Sources</th><th>Scores</th><th>Shared identifiers</th></tr>
            </thead>
            <tbody>
              <% @decision.candidates.each_with_index do |candidate, i| %>
                <% index = i + 1 %>
                <% evidence = candidate["evidence"].to_h %>
                <% record = @candidate_records[[candidate["record_type"], candidate["record_id"]]] %>
                <% selected = (index == @decision.selected_index) %>
                <tr class="<%= "bg-primary/10 font-semibold" if selected %>" data-testid="candidate-row" data-candidate-index="<%= index %>" data-selected="<%= selected %>">
                  <td><%= index %></td>
                  <td>
                    <%= candidate["record_id"] ? "local" : "external" %>
                    <% if candidate["external_key"].present? %>
                      <span class="badge badge-ghost badge-sm"><%= candidate["external_source"] %> <%= candidate["external_key"] %></span>
                    <% end %>
                  </td>
                  <td class="[overflow-wrap:anywhere]">
                    <% title = evidence["title"].presence || evidence["external_title"].presence || candidate["external_key"] %>
                    <% path = Admin::DomainRouting.path_for(record) %>
                    <%= path ? link_to(title, path, class: "link") : title %>
                    <% if candidate["record_id"] && record.nil? %><span class="badge badge-error badge-sm">missing</span><% end %>
                  </td>
                  <td class="[overflow-wrap:anywhere]"><%= Array(evidence["creators"].presence || evidence["external_creators"]).join(", ") %></td>
                  <td><%= evidence["year"] || evidence["external_year"] %></td>
                  <td><%= evidence["ranked_position"] ? "##{evidence["ranked_position"]}" : "—" %></td>
                  <td><%= Array(candidate["sources"]).join(", ") %></td>
                  <td class="tabular-nums whitespace-nowrap">
                    <%= candidate["scores"].to_h.map { |source, score| "#{source} #{score.is_a?(Numeric) ? score.round(2) : score}" }.join(", ") %>
                  </td>
                  <td data-testid="shared-identifiers" class="[overflow-wrap:anywhere]">
                    <% shared = audit_shared_identifiers(@decision, candidate) %>
                    <%= shared.any? ? shared.join(", ") : "—" %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-base-content/70">No candidates were found.</p>
      <% end %>
    </div>
  </div>

  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <h2 class="card-title">Reasoning</h2>
      <p class="[overflow-wrap:anywhere]"><%= @decision.reason.presence || "—" %></p>
      <% if @decision.selected_index %>
        <p class="text-sm text-base-content/70">Selected candidate #<%= @decision.selected_index %>.</p>
      <% end %>
      <% if @decision.ai_chat %>
        <details class="collapse collapse-arrow bg-base-200" data-testid="ai-chat">
          <summary class="collapse-title text-sm font-semibold">AI chat #<%= @decision.ai_chat.id %> (<%= @decision.ai_chat.model %>)</summary>
          <div class="collapse-content">
            <pre class="bg-base-100 p-3 rounded-lg text-xs whitespace-pre-wrap break-words max-h-96 overflow-y-auto"><code><%= JSON.pretty_generate(@decision.ai_chat.messages || []) %></code></pre>
          </div>
        </details>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 13: Run the tests**

Run: `bin/rails test test/controllers/admin/books/match_decisions_controller_test.rb test/controllers/admin/music/match_decisions_controller_test.rb test/controllers/admin/games/match_decisions_controller_test.rb test/helpers/admin/import_finder_audit_helper_test.rb`
Expected: PASS.

- [ ] **Step 14: Full suite, lint, zeitwerk, commit**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
git add config/routes.rb test/fixtures/match_decisions.yml app/controllers/admin/match_decisions_base_controller.rb app/controllers/admin/books/match_decisions_controller.rb app/controllers/admin/music/match_decisions_controller.rb app/controllers/admin/games/match_decisions_controller.rb app/helpers/admin/import_finder_audit_helper.rb app/views/admin/match_decisions_base test/controllers/admin/books/match_decisions_controller_test.rb test/controllers/admin/music/match_decisions_controller_test.rb test/controllers/admin/games/match_decisions_controller_test.rb test/helpers/admin/import_finder_audit_helper_test.rb
git commit -m "Match decisions admin pages: per-domain index scoped by FinderRegistry (verify runs hidden by default) and a show page with the candidate table"
```

---

### Task 3: Match decisions — Mark reviewed, Re-check, Merge into candidate N

**Files:**
- Modify: `web-app/app/controllers/admin/match_decisions_base_controller.rb`
- Create: `web-app/app/views/admin/match_decisions_base/_actions.html.erb`
- Create: `web-app/app/views/admin/shared/_merge_form.html.erb`
- Modify: `web-app/app/views/admin/match_decisions_base/show.html.erb` (render the actions partial)
- Test: `web-app/test/controllers/admin/books/match_decisions_controller_test.rb`, `web-app/test/controllers/admin/music/match_decisions_controller_test.rb` (append)

**Interfaces:**
- Consumes: routes `review_<prefix>match_decision_path`, `recheck_<prefix>match_decision_path` (Task 2 routes); `FinderRegistry::Entry#recheck?`, `#query_class.from_snapshot`, `#finder_class`, `#mergeable?`, `#execute_action_path`, `#source_field`, `#merge_action`.
- Produces: `admin/shared/_merge_form` partial with locals `entry:`, `source:`, `target:`, `label:` — Task 4 reuses it. Controller helpers `review_decision_path(decision)`, `recheck_decision_path(decision)`.

- [ ] **Step 1: Write the failing tests**

Append to the books test class:

```ruby
      # ---- review ------------------------------------------------------------

      test "review marks the decision reviewed by the current user with the note" do
        sign_in_as(@admin, stub_auth: true)
        post review_admin_books_match_decision_path(@pending), params: {review_note: "Checked by hand."}

        assert_redirected_to admin_books_match_decision_path(@pending)
        @pending.reload
        assert_equal @admin, @pending.reviewed_by
        assert_equal "Checked by hand.", @pending.review_note
        assert_not_nil @pending.reviewed_at
      end

      test "review of an already reviewed decision changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        before = [@reviewed.reviewed_at, @reviewed.reviewed_by_id, @reviewed.review_note]

        post review_admin_books_match_decision_path(@reviewed), params: {review_note: "again"}

        assert_redirected_to admin_books_match_decision_path(@reviewed)
        assert_equal before, [@reviewed.reload.reviewed_at, @reviewed.reviewed_by_id, @reviewed.review_note]
      end

      test "a viewer cannot review and sees no action forms" do
        sign_in_as(@viewer, stub_auth: true)

        get admin_books_match_decision_path(@pending)
        assert_select "[data-testid=decision-actions]", count: 0

        post review_admin_books_match_decision_path(@pending), params: {review_note: "nope"}
        assert_redirected_to books_root_path
        assert_nil @pending.reload.reviewed_at
      end

      test "review of another domain's decision 404s" do
        sign_in_as(@admin, stub_auth: true)
        post review_admin_books_match_decision_path(@music)
        assert_response :not_found
      end

      # ---- recheck -----------------------------------------------------------

      test "recheck runs the finder with verify on, excluding a sweep decision's subject, and shows the new decision beside the old" do
        sign_in_as(@admin, stub_auth: true)
        book = books_books(:war_and_peace)
        new_decision = @pending
        DataImporters::Books::Book::Finder.any_instance.expects(:call).with do |args|
          args[:query].is_a?(DataImporters::Books::Book::ImportQuery) &&
            args[:query].title == "War and Peace" && args[:query].author_names == ["Leo Tolstoy"] &&
            args[:verify] == true && args[:subject] == book && args[:exclude] == book
        end.returns(DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule, reason: "No candidates.", decision: new_decision))

        post recheck_admin_books_match_decision_path(@sweep)

        assert_redirected_to admin_books_match_decision_path(new_decision, compare: @sweep.id)
      end

      test "recheck of an unmatched import excludes the record it created" do
        sign_in_as(@admin, stub_auth: true)
        DataImporters::Books::Book::Finder.any_instance.expects(:call)
          .with { |args| args[:exclude] == books_books(:got) && args[:subject].nil? && args[:query].isbn13 == ["9780553103540"] }
          .returns(DataImporters::Match.new(outcome: :matched, record: books_books(:war_and_peace), confidence: :high, decided_by: :ai, decision: @pending))

        post recheck_admin_books_match_decision_path(@created)

        assert_redirected_to admin_books_match_decision_path(@pending, compare: @created.id)
      end

      test "recheck of a matched import excludes nothing" do
        sign_in_as(@admin, stub_auth: true)
        DataImporters::Books::Book::Finder.any_instance.expects(:call)
          .with { |args| args[:exclude].nil? && args[:verify] == true }
          .returns(DataImporters::Match.new(outcome: :matched, record: books_books(:war_and_peace), confidence: :certain, decided_by: :identifier, decision: @sweep))

        post recheck_admin_books_match_decision_path(@pending)

        assert_redirected_to admin_books_match_decision_path(@sweep, compare: @pending.id)
      end

      test "a viewer cannot recheck" do
        sign_in_as(@viewer, stub_auth: true)
        DataImporters::Books::Book::Finder.any_instance.expects(:call).never

        post recheck_admin_books_match_decision_path(@pending)
        assert_redirected_to books_root_path
      end

      # ---- merge into candidate N -------------------------------------------

      test "show offers Merge into candidate N for an unmatched decision with a created record, posting to the candidate's execute_action with the created record as source" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@created)

        target = books_books(:war_and_peace)
        assert_select "[data-testid=merge-into-candidate][data-candidate-index='1']" do
          assert_select "form[data-testid=merge-form][action=?][data-turbo=false]", execute_action_admin_books_book_path(target) do
            assert_select "input[name=action_name][value=MergeBook]"
            assert_select "input[name=source_book_id][value=?]", books_books(:got).id.to_s
            assert_select "input[type=checkbox][name=confirm_merge][required]"
          end
        end
      end

      test "show offers no merge for a matched decision or a sweep decision" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decision_path(@pending)
        assert_select "[data-testid=merge-into-candidate]", count: 0

        get admin_books_match_decision_path(@sweep)
        assert_select "[data-testid=merge-into-candidate]", count: 0
      end

      test "show offers Re-check for a books decision" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@pending)

        assert_select "form[data-testid=recheck-form][action=?]", recheck_admin_books_match_decision_path(@pending)
      end
```

Append to the music test class:

```ruby
      test "recheck is refused for a finder whose real sources have not landed, and no Re-check form renders" do
        decision = match_decisions(:dark_side_album_match)
        DataImporters::Music::Album::Finder.any_instance.expects(:call).never

        get admin_match_decision_path(decision)
        assert_select "form[data-testid=recheck-form]", count: 0

        post recheck_admin_match_decision_path(decision)
        assert_redirected_to admin_match_decision_path(decision)
        assert_equal 1, MatchDecision.where(finder: "DataImporters::Music::Album::Finder").count
      end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/admin/books/match_decisions_controller_test.rb test/controllers/admin/music/match_decisions_controller_test.rb`
Expected: FAIL — `AbstractController::ActionNotFound` for review/recheck; the merge/recheck form assertions fail.

- [ ] **Step 3: Add the actions to the base controller**

In `web-app/app/controllers/admin/match_decisions_base_controller.rb`:

Replace the `before_action :set_decision, only: [:show]` line with:

```ruby
  before_action :set_decision, only: [:show, :review, :recheck]
  before_action :require_domain_write!, only: [:review, :recheck]
```

Extend the `helper_method` line to include `:review_decision_path, :recheck_decision_path`.

After `show`, add:

```ruby
  def review
    if @decision.reviewed_at.present?
      redirect_to decision_path(@decision), alert: "Already reviewed."
      return
    end

    @decision.review!(by: current_user, note: params[:review_note].presence)
    redirect_to decision_path(@decision), notice: "Marked reviewed."
  end

  # Runs the finder again, synchronously, with verify on: no early exit, every
  # source, the AI when the rules cannot decide. The finder records the new
  # decision itself; the show page renders it beside the old one. Offered
  # only where FinderRegistry says the finder's real sources have landed --
  # on a legacy-only finder verify would send one candidate to the AI for
  # nothing. Books this takes roughly the Open Library resolve plus the AI
  # call, within a request, which spec §13 accepts.
  def recheck
    entry = entry_for(@decision)
    unless entry&.recheck?
      redirect_to decision_path(@decision), alert: "Re-check is not available for #{entry&.label&.downcase || @decision.finder} decisions yet."
      return
    end

    query = entry.query_class.from_snapshot(@decision.query)
    match = entry.finder_class.new.call(
      query: query, verify: true, subject: @decision.subject, exclude: recheck_exclusion(@decision, entry)
    )

    redirect_to decision_path(match.decision, compare: @decision.id),
      notice: "Re-checked: #{match.outcome}, #{match.confidence} confidence, decided by #{match.decided_by}."
  end
```

In the private section, add:

```ruby
  # What the re-run must not consider. A decision made for a record of this
  # finder's own type (the sweep's subject) re-resolves that record against
  # the rest of the catalog, so the record is excluded. An unmatched import
  # created its record from this very query, so that record is excluded or
  # the re-check would match itself. A matched import excludes nothing: the
  # question is whether the match still holds.
  def recheck_exclusion(decision, entry)
    return decision.subject if decision.subject.instance_of?(entry.model_class)

    decision.record if decision.unmatched?
  end

  def review_decision_path(decision)
    public_send(:"review_#{route_prefix}match_decision_path", decision)
  end

  def recheck_decision_path(decision)
    public_send(:"recheck_#{route_prefix}match_decision_path", decision)
  end
```

- [ ] **Step 4: Write the shared merge form partial**

```erb
<%# web-app/app/views/admin/shared/_merge_form.html.erb
    Locals: entry (DataImporters::FinderRegistry::Entry), source, target (records of
    entry.model), label (submit text).

    Posts to the domain's existing execute_action endpoint, which enforces the
    delete gate (authorize :destroy? for a destructive action) and runs the
    merger; nothing here merges. The same required confirm checkbox as the
    record pages' merge modal. turbo: false so the endpoint's HTML branch
    answers -- a redirect to the surviving record with the result as flash --
    instead of a turbo-stream flash replace that would leave this page showing
    a pair or candidate that no longer exists. %>
<%= form_with url: entry.execute_action_path.call(target), method: :post, class: "space-y-2",
      data: {turbo: false, testid: "merge-form"} do |form| %>
  <%= form.hidden_field :action_name, value: entry.merge_action, id: nil %>
  <%= hidden_field_tag entry.source_field, source.id, id: nil %>
  <p class="text-sm [overflow-wrap:anywhere]">
    Merge <strong><%= audit_record_label(source) %></strong> (#<%= source.id %>)
    into <strong><%= audit_record_label(target) %></strong> (#<%= target.id %>).
    The first is permanently deleted; its associations move to the second.
  </p>
  <label class="label cursor-pointer justify-start gap-2">
    <%= check_box_tag :confirm_merge, "1", false, class: "checkbox checkbox-sm", required: true, id: nil %>
    <span>I understand this action cannot be undone</span>
  </label>
  <%= form.submit label, class: "btn btn-warning btn-sm" %>
<% end %>
```

`id: nil` on the inputs: several of these forms render on one page (two per pair, one per candidate), and duplicate ids would be invalid HTML.

- [ ] **Step 5: Write the actions partial and render it**

```erb
<%# web-app/app/views/admin/match_decisions_base/_actions.html.erb
    Locals: decision, entry, candidate_records. Rendered only for writers. %>
<div class="card bg-base-100 shadow" data-testid="decision-actions">
  <div class="card-body space-y-4">
    <h2 class="card-title">Actions</h2>

    <% unless decision.reviewed_at %>
      <%= form_with url: review_decision_path(decision), method: :post, class: "space-y-2", data: {testid: "review-form"} do |form| %>
        <%= form.label :review_note, "Review note", class: "label" %>
        <%= form.text_area :review_note, class: "textarea w-full", rows: 2 %>
        <%= form.submit "Mark reviewed", class: "btn btn-primary btn-sm" %>
      <% end %>
    <% end %>

    <% if entry&.recheck? %>
      <%= button_to "Re-check", recheck_decision_path(decision), method: :post, class: "btn btn-sm",
            form: {data: {testid: "recheck-form", turbo_confirm: "Run the finder again now, with every source and verify on? This may take several seconds."}} %>
    <% end %>

    <% if decision.unmatched? && decision.record && entry&.mergeable? %>
      <% decision.candidates.each_with_index do |candidate, i| %>
        <% target = candidate_records[[candidate["record_type"], candidate["record_id"]]] %>
        <% next unless target && candidate["record_type"] == entry.model && target.id != decision.record_id %>
        <details class="collapse collapse-arrow bg-base-200" data-testid="merge-into-candidate" data-candidate-index="<%= i + 1 %>">
          <summary class="collapse-title text-sm font-semibold">
            Merge into candidate <%= i + 1 %>: <%= audit_record_label(target) %>
          </summary>
          <div class="collapse-content">
            <%= render "admin/shared/merge_form", entry: entry, source: decision.record, target: target, label: "Merge into ##{i + 1}" %>
          </div>
        </details>
      <% end %>
    <% end %>
  </div>
</div>
```

In `show.html.erb`, after the Reasoning card (last card, before the closing `</div>` of the page), add:

```erb
  <% if current_user_can_write? %>
    <%= render "admin/match_decisions_base/actions", decision: @decision, entry: @entry, candidate_records: @candidate_records %>
  <% end %>
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/controllers/admin/books/match_decisions_controller_test.rb test/controllers/admin/music/match_decisions_controller_test.rb`
Expected: PASS. If `assert_select "form[...][data-turbo=false]"` fails on attribute quoting, assert `form[data-turbo='false']`.

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/controllers/admin/match_decisions_base_controller.rb app/views/admin/match_decisions_base app/views/admin/shared/_merge_form.html.erb test/controllers/admin/books/match_decisions_controller_test.rb test/controllers/admin/music/match_decisions_controller_test.rb
git commit -m "Match decisions: mark reviewed, re-check with verify on (books only) shown beside the original, merge into a local candidate through the domain's execute_action"
```

---

### Task 4: Duplicate candidates — fixtures, base controller, per-domain controllers, index and dismiss

**Files:**
- Modify: `web-app/test/fixtures/duplicate_candidates.yml` (append)
- Create (generator): `web-app/app/controllers/admin/duplicate_candidates_base_controller.rb`
- Create (generator): `web-app/app/controllers/admin/books/duplicate_candidates_controller.rb`, `.../music/duplicate_candidates_controller.rb`, `.../games/duplicate_candidates_controller.rb`
- Create: `web-app/app/views/admin/duplicate_candidates_base/index.html.erb`, `_pair.html.erb`, `_side.html.erb`
- Test: `web-app/test/controllers/admin/books/duplicate_candidates_controller_test.rb`, `.../music/duplicate_candidates_controller_test.rb`, `.../games/duplicate_candidates_controller_test.rb`

**Interfaces:**
- Consumes: routes from Task 2 (`<prefix>duplicate_candidates_path`, `dismiss_<prefix>duplicate_candidate_path`), `FinderBase#summarize`, `FinderRegistry::Entry#preloads`, `admin/shared/_merge_form` (Task 3), `audit_record_label`.
- Produces: controller helpers `duplicates_index_path(params = {})`, `dismiss_duplicate_path(pair)`, `decision_path_for(decision)`, `entry_for_pair(pair)`, `record_for(pair, id)`, `summary_for(pair, id)`; filter param `status` ∈ `pending|merged|not_duplicate` (default `pending`).

- [ ] **Step 1: Append the fixtures**

```yaml

# Books pairs for the audit pages. got + clash (both King) is the pending pair
# the books duplicates index opens on; cannery_row + clash is dismissed.
# Neither pair is one the finder or merger tests raise (those use
# war_and_peace + crime_and_punishment and combo_steinbeck). If a test
# elsewhere starts failing because of these rows, change THESE books, not
# the test.
<% king_a, king_b = [ActiveRecord::FixtureSet.identify(:got), ActiveRecord::FixtureSet.identify(:clash)].minmax %>
books_pending_pair:
  item_type: Books::Book
  item_a_id: <%= king_a %>
  item_b_id: <%= king_b %>
  source: 4
  status: 0
  evidence: {"reason": "Same author, similar titles; the sweep matched them.", "decided_by": "ai", "confidence": "medium"}
  occurrences: 2
  match_decision: low_confidence_book_match

<% dismissed_a, dismissed_b = [ActiveRecord::FixtureSet.identify(:cannery_row), ActiveRecord::FixtureSet.identify(:clash)].minmax %>
books_dismissed_pair:
  item_type: Books::Book
  item_a_id: <%= dismissed_a %>
  item_b_id: <%= dismissed_b %>
  source: 2
  status: 2
  evidence: {"reason": "Shared a Goodreads id."}
  occurrences: 1
  resolved_at: <%= 1.day.ago.to_fs(:db) %>
  resolved_by: admin_user
  resolution_note: "Different books."
```

Run `bin/rails test test/lib/data_importers test/lib/services/duplicate_candidates test/lib/books test/models/duplicate_candidate_test.rb` and fix any collision by changing the fixture's books.

- [ ] **Step 2: Generate the controllers**

```bash
bin/rails generate controller admin/duplicate_candidates_base --skip-routes --no-helper --no-assets --no-test-framework
bin/rails generate controller admin/books/duplicate_candidates --skip-routes --no-helper --no-assets
bin/rails generate controller admin/music/duplicate_candidates --skip-routes --no-helper --no-assets
bin/rails generate controller admin/games/duplicate_candidates --skip-routes --no-helper --no-assets
```

Remove any generated view directories under `app/views/admin/{books,music,games}/duplicate_candidates/`.

- [ ] **Step 3: Write the failing tests**

```ruby
# web-app/test/controllers/admin/books/duplicate_candidates_controller_test.rb
require "test_helper"

module Admin
  module Books
    class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @pending = duplicate_candidates(:books_pending_pair)
        @dismissed = duplicate_candidates(:books_dismissed_pair)
        @games_pair = duplicate_candidates(:resident_evil_4_pair)
        @got = books_books(:got)
        @clash = books_books(:clash)
      end

      def pair_ids
        css_select("[data-testid=pair-row]").map { |row| row["data-pair-id"].to_i }
      end

      test "index redirects unauthenticated users" do
        get admin_books_duplicate_candidates_path
        assert_redirected_to books_root_path
      end

      test "index defaults to pending books pairs only" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        assert_response :success
        assert_equal [@pending.id], pair_ids
        assert_select "[data-testid=pair-row][data-item-type='Books::Book'][data-status=pending]"
      end

      test "status filter shows dismissed pairs; an unknown status falls back to pending" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path(status: "not_duplicate")
        assert_equal [@dismissed.id], pair_ids

        get admin_books_duplicate_candidates_path(status: "merged")
        assert_empty pair_ids

        get admin_books_duplicate_candidates_path(status: "bogus")
        assert_equal [@pending.id], pair_ids
      end

      test "index reports counts per status for this domain" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        assert_select "[data-testid=status-count-pending]", text: DuplicateCandidate.where(item_type: "Books::Book", status: :pending).count.to_s
        assert_select "[data-testid=status-count-not_duplicate]", text: DuplicateCandidate.where(item_type: "Books::Book", status: :not_duplicate).count.to_s
      end

      test "a pair renders both records side by side with links to their admin pages" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        a, b = [@got, @clash].sort_by(&:id)
        assert_select "[data-testid=pair-side][data-side=A][data-record-id=?]", a.id.to_s do
          assert_select "a[href=?]", admin_books_book_path(a)
        end
        assert_select "[data-testid=pair-side][data-side=B][data-record-id=?]", b.id.to_s do
          assert_select "a[href=?]", admin_books_book_path(b)
        end
        assert_select "[data-testid=pair-row][data-pair-id=?] a[href=?]", @pending.id.to_s, admin_books_match_decision_path(@pending.match_decision)
      end

      test "a pending pair offers both merge directions through the target's execute_action, each with a required confirm" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        a, b = [@got, @clash].sort_by(&:id)
        assert_select "[data-testid=merge-a-into-b] form[data-testid=merge-form][action=?]", execute_action_admin_books_book_path(b) do
          assert_select "input[name=action_name][value=MergeBook]"
          assert_select "input[name=source_book_id][value=?]", a.id.to_s
          assert_select "input[type=checkbox][name=confirm_merge][required]"
        end
        assert_select "[data-testid=merge-b-into-a] form[data-testid=merge-form][action=?]", execute_action_admin_books_book_path(a) do
          assert_select "input[name=source_book_id][value=?]", b.id.to_s
        end
      end

      test "a dismissed pair offers no actions" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path(status: "not_duplicate")

        assert_select "[data-testid=pair-actions]", count: 0
        assert_select "form[data-testid=merge-form]", count: 0
      end

      test "a viewer sees pairs but no actions and cannot dismiss" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_duplicate_candidates_path
        assert_response :success
        assert_select "[data-testid=pair-actions]", count: 0

        post dismiss_admin_books_duplicate_candidate_path(@pending), params: {resolution_note: "nope"}
        assert_redirected_to books_root_path
        assert @pending.reload.pending?
      end

      test "a pair whose record no longer exists says so and offers dismissal only" do
        sign_in_as(@admin, stub_auth: true)
        ghost = DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: @got.id, item_b_id: 999_999_999, source: :ai, status: :pending, evidence: {})

        get admin_books_duplicate_candidates_path

        assert_select "[data-testid=pair-row][data-pair-id=?]", ghost.id.to_s do
          assert_select "[data-testid=pair-side][data-record-id='999999999'][data-missing=true]"
          assert_select "form[data-testid=dismiss-form]"
          assert_select "form[data-testid=merge-form]", count: 0
        end
      end

      test "dismiss marks the pair not a duplicate with the note and resolver" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@pending), params: {resolution_note: "Different novels."}

        assert_redirected_to admin_books_duplicate_candidates_path
        @pending.reload
        assert @pending.not_duplicate?
        assert_equal @admin, @pending.resolved_by
        assert_equal "Different novels.", @pending.resolution_note
        assert_not_nil @pending.resolved_at
      end

      test "dismiss of a resolved pair changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        before = [@dismissed.status, @dismissed.resolution_note, @dismissed.resolved_at]

        post dismiss_admin_books_duplicate_candidate_path(@dismissed), params: {resolution_note: "again"}

        assert_redirected_to admin_books_duplicate_candidates_path(status: "not_duplicate")
        assert_equal before, [@dismissed.reload.status, @dismissed.resolution_note, @dismissed.resolved_at]
      end

      test "dismiss of another domain's pair 404s" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@games_pair)
        assert_response :not_found
      end

      test "a dismissed pair is never re-raised by the finder's never-merge check" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@pending)

        assert DuplicateCandidate.not_duplicate?(item_type: "Books::Book", ids: [@clash.id, @got.id])
      end
    end
  end
end
```

```ruby
# web-app/test/controllers/admin/games/duplicate_candidates_controller_test.rb
require "test_helper"

module Admin
  module Games
    class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:games]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index shows the pending games pair and none of books'" do
        get admin_games_duplicate_candidates_path

        assert_response :success
        ids = css_select("[data-testid=pair-row]").map { |row| row["data-pair-id"].to_i }
        assert_equal [duplicate_candidates(:resident_evil_4_pair).id], ids
        assert_select "[data-testid=merge-a-into-b] input[name=action_name][value=MergeGame]"
        assert_select "[data-testid=merge-a-into-b] input[name=source_game_id]"
      end
    end
  end
end
```

```ruby
# web-app/test/controllers/admin/music/duplicate_candidates_controller_test.rb
require "test_helper"

module Admin
  module Music
    class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:music]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index renders empty for music" do
        get admin_duplicate_candidates_path

        assert_response :success
        assert_select "[data-testid=pair-row]", count: 0
      end
    end
  end
end
```

- [ ] **Step 4: Run them to verify they fail**

Run: `bin/rails test test/controllers/admin/books/duplicate_candidates_controller_test.rb`
Expected: FAIL (missing actions/templates).

- [ ] **Step 5: Write the base controller**

```ruby
# web-app/app/controllers/admin/duplicate_candidates_base_controller.rb
# The audit surface for duplicate_candidates (spec §13): suspected pairs of
# one domain's records, side by side. Each domain supplies a routable
# subclass naming its domain and route prefix (see
# Admin::Books::DuplicateCandidatesController); every query is scoped to the
# models DataImporters::FinderRegistry registers for that domain.
#
# Merging is not done here. The merge forms post to the domain's existing
# execute_action endpoint, whose delete gate and merger stand; on success the
# merger's Services::DuplicateCandidates::RecordMerge hook marks the pair
# merged. Dismissal is the one write this controller owns.
class Admin::DuplicateCandidatesBaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_pair, only: [:dismiss]
  before_action :require_domain_write!, only: [:dismiss]

  STATUSES = ::DuplicateCandidate.statuses.keys.freeze
  PER_PAGE = 25

  helper_method :duplicates_index_path, :dismiss_duplicate_path, :decision_path_for,
    :entry_for_pair, :record_for, :summary_for

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    @pagy, @pairs = pagy(domain_scope.where(status: @status).includes(:match_decision, :resolved_by).newest_first, limit: PER_PAGE)
    load_pair_records(@pairs)
  end

  def dismiss
    unless @pair.pending?
      redirect_to duplicates_index_path(status: @pair.status), alert: "This pair is already #{@pair.status.humanize.downcase}."
      return
    end

    @pair.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: current_user,
      resolution_note: params[:resolution_note].presence)
    redirect_to duplicates_index_path, notice: "Marked as not a duplicate."
  end

  private

  def domain
    raise NotImplementedError, "Subclass must implement domain"
  end

  def route_prefix
    raise NotImplementedError, "Subclass must implement route_prefix"
  end

  def entries
    DataImporters::FinderRegistry.for_domain(domain)
  end

  def domain_scope
    ::DuplicateCandidate.where(item_type: entries.map(&:model))
  end

  def set_pair
    @pair = domain_scope.find(params[:id])
  end

  def entry_for_pair(pair)
    DataImporters::FinderRegistry.entry_for_model(pair.item_type)
  end

  # One query per item type for the records and one finder per type for
  # their summaries (FinderBase#summarize: title, creators, year, ranked
  # position, list count, identifiers). A record a merge or delete has since
  # removed is simply absent; its side says so and the row offers dismissal
  # only. ranked_position and list_count are one query each per record --
  # fifty per page at most, accepted for an admin queue.
  def load_pair_records(pairs)
    @records = {}
    @summaries = {}
    pairs.group_by(&:item_type).each do |type, rows|
      entry = DataImporters::FinderRegistry.entry_for_model(type)
      next unless entry

      finder = entry.finder_class.new
      ids = rows.flat_map { |row| [row.item_a_id, row.item_b_id] }.uniq
      entry.model_class.where(id: ids).includes(:identifiers, *entry.preloads).each do |record|
        @records[[type, record.id]] = record
        @summaries[[type, record.id]] = finder.summarize(record)
      end
    end
  end

  def record_for(pair, id)
    @records[[pair.item_type, id]]
  end

  def summary_for(pair, id)
    @summaries[[pair.item_type, id]]
  end

  def duplicates_index_path(params = {})
    public_send(:"#{route_prefix}duplicate_candidates_path", params)
  end

  def dismiss_duplicate_path(pair)
    public_send(:"dismiss_#{route_prefix}duplicate_candidate_path", pair)
  end

  def decision_path_for(decision)
    public_send(:"#{route_prefix}match_decision_path", decision)
  end
end
```

Per-domain controllers, same shape as Task 2's:

```ruby
# web-app/app/controllers/admin/books/duplicate_candidates_controller.rb
class Admin::Books::DuplicateCandidatesController < Admin::DuplicateCandidatesBaseController
  private

  def domain = :books

  def route_prefix = "admin_books_"
end
```

Music: `domain = :music`, `route_prefix = "admin_"`. Games: `domain = :games`, `route_prefix = "admin_games_"`.

- [ ] **Step 6: Write the views**

```erb
<%# web-app/app/views/admin/duplicate_candidates_base/index.html.erb %>
<% content_for :title, "Duplicate Candidates" %>

<div class="space-y-4">
  <h1 class="text-2xl font-bold">Duplicate Candidates</h1>

  <div role="tablist" class="tabs tabs-border">
    <% Admin::DuplicateCandidatesBaseController::STATUSES.each do |status| %>
      <%= link_to duplicates_index_path(status: status), role: "tab",
            class: "tab #{"tab-active" if @status == status}", data: {testid: "status-tab-#{status}"} do %>
        <%= status.humanize %>
        <span class="badge badge-sm ml-2" data-testid="status-count-<%= status %>"><%= @counts[status].to_i %></span>
      <% end %>
    <% end %>
  </div>

  <% if @pairs.any? %>
    <div class="space-y-4">
      <%= render partial: "admin/duplicate_candidates_base/pair", collection: @pairs, as: :pair %>
    </div>
  <% else %>
    <p class="text-center text-base-content/70 py-8">No <%= @status.humanize.downcase %> pairs.</p>
  <% end %>

  <% if @pagy.pages > 1 %>
    <div class="mt-4 flex justify-center"><%== @pagy.series_nav %></div>
  <% end %>
</div>
```

```erb
<%# web-app/app/views/admin/duplicate_candidates_base/_pair.html.erb  Local: pair %>
<% entry = entry_for_pair(pair) %>
<% a = record_for(pair, pair.item_a_id) %>
<% b = record_for(pair, pair.item_b_id) %>
<div class="card bg-base-100 shadow" data-testid="pair-row" data-pair-id="<%= pair.id %>"
     data-item-type="<%= pair.item_type %>" data-status="<%= pair.status %>">
  <div class="card-body space-y-3">
    <div class="flex flex-wrap items-center gap-2 text-sm">
      <span class="badge badge-ghost"><%= entry&.label || pair.item_type %></span>
      <span class="badge badge-outline"><%= pair.source.humanize %></span>
      <span>seen <%= pair.occurrences %> <%= "time".pluralize(pair.occurrences) %></span>
      <span class="text-base-content/70"><%= pair.created_at.to_date.iso8601 %></span>
      <% if pair.match_decision %>
        <%= link_to "decision ##{pair.match_decision_id}", decision_path_for(pair.match_decision), class: "link" %>
      <% end %>
    </div>
    <% if pair.evidence.to_h["reason"].present? %>
      <p class="text-sm [overflow-wrap:anywhere]"><%= pair.evidence["reason"] %></p>
    <% end %>

    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <%= render "admin/duplicate_candidates_base/side", pair: pair, record: a, id: pair.item_a_id, side: "A" %>
      <%= render "admin/duplicate_candidates_base/side", pair: pair, record: b, id: pair.item_b_id, side: "B" %>
    </div>

    <% if pair.pending? && current_user_can_write? %>
      <div class="flex flex-wrap gap-4 items-start" data-testid="pair-actions">
        <%= form_with url: dismiss_duplicate_path(pair), method: :post, class: "flex gap-2 items-end", data: {testid: "dismiss-form"} do |form| %>
          <%= form.text_field :resolution_note, placeholder: "Why not a duplicate (optional)", class: "input input-sm w-64", id: nil %>
          <%= form.submit "Not a duplicate", class: "btn btn-sm" %>
        <% end %>
        <% if entry&.mergeable? && a && b %>
          <details class="collapse collapse-arrow bg-base-200 w-auto" data-testid="merge-a-into-b">
            <summary class="collapse-title text-sm font-semibold">Merge A into B</summary>
            <div class="collapse-content">
              <%= render "admin/shared/merge_form", entry: entry, source: a, target: b, label: "Merge A into B" %>
            </div>
          </details>
          <details class="collapse collapse-arrow bg-base-200 w-auto" data-testid="merge-b-into-a">
            <summary class="collapse-title text-sm font-semibold">Merge B into A</summary>
            <div class="collapse-content">
              <%= render "admin/shared/merge_form", entry: entry, source: b, target: a, label: "Merge B into A" %>
            </div>
          </details>
        <% end %>
      </div>
    <% elsif pair.resolved_at %>
      <p class="text-sm text-base-content/70">
        <%= pair.status.humanize %> <%= pair.resolved_at.to_date.iso8601 %><%= " by #{pair.resolved_by.email}" if pair.resolved_by %><%= " — #{pair.resolution_note}" if pair.resolution_note.present? %>
      </p>
    <% end %>
  </div>
</div>
```

```erb
<%# web-app/app/views/admin/duplicate_candidates_base/_side.html.erb  Locals: pair, record, id, side %>
<div class="rounded-box border border-base-300 p-3 text-sm" data-testid="pair-side"
     data-side="<%= side %>" data-record-id="<%= id %>" data-missing="<%= record.nil? %>">
  <% if record %>
    <% summary = summary_for(pair, id) %>
    <div class="font-semibold [overflow-wrap:anywhere]">
      <%= side %>.
      <% path = Admin::DomainRouting.path_for(record) %>
      <%= path ? link_to(summary[:title], path, class: "link") : summary[:title] %>
      <span class="text-base-content/60">#<%= id %></span>
    </div>
    <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 mt-2">
      <dt class="text-base-content/70">Creators</dt><dd class="[overflow-wrap:anywhere]"><%= Array(summary[:creators]).join(", ").presence || "—" %></dd>
      <dt class="text-base-content/70">Year</dt><dd><%= summary[:year] || "—" %></dd>
      <dt class="text-base-content/70">Ranked</dt><dd><%= summary[:ranked_position] ? "##{summary[:ranked_position]}" : "—" %></dd>
      <dt class="text-base-content/70">Lists</dt><dd><%= summary[:list_count] %></dd>
      <dt class="text-base-content/70">Identifiers</dt>
      <dd class="[overflow-wrap:anywhere]">
        <% identifiers = Array(summary[:identifiers]) %>
        <%= identifiers.first(6).map { |identifier| "#{identifier[:type]}: #{identifier[:value]}" }.join(", ").presence || "—" %><%= " …" if identifiers.size > 6 %>
      </dd>
    </dl>
  <% else %>
    <div class="font-semibold"><%= side %>. <span class="badge badge-error badge-sm">missing</span> record #<%= id %> no longer exists</div>
  <% end %>
</div>
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/controllers/admin/books/duplicate_candidates_controller_test.rb test/controllers/admin/games/duplicate_candidates_controller_test.rb test/controllers/admin/music/duplicate_candidates_controller_test.rb`
Expected: PASS. If the games finder's `summarize` raises on a games fixture (a legacy finder hook expecting something a fixture lacks), fix the hook, not the view.

- [ ] **Step 8: Full suite, lint, zeitwerk, commit**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
git add test/fixtures/duplicate_candidates.yml app/controllers/admin/duplicate_candidates_base_controller.rb app/controllers/admin/books/duplicate_candidates_controller.rb app/controllers/admin/music/duplicate_candidates_controller.rb app/controllers/admin/games/duplicate_candidates_controller.rb app/views/admin/duplicate_candidates_base test/controllers/admin/books/duplicate_candidates_controller_test.rb test/controllers/admin/music/duplicate_candidates_controller_test.rb test/controllers/admin/games/duplicate_candidates_controller_test.rb
git commit -m "Duplicate candidates admin pages: pending pairs side by side per domain, dismiss with a note, both merge directions through the domain's execute_action"
```

---

### Task 5: Sidebar entries, E2E seed and cleanup tasks, Playwright spec

**Files:**
- Modify: `web-app/app/lib/admin/domain_nav.rb` (three `items` arrays)
- Modify: `web-app/lib/tasks/e2e.rake` (append two tasks)
- Create: `web-app/e2e/tests/books/admin/import-finder-audit.spec.ts`
- Test: `web-app/test/lib/admin/domain_nav_test.rb` (append), `web-app/test/lib/tasks/e2e_import_finder_rake_test.rb` (create)

**Interfaces:**
- Consumes: routes from Task 2; `DataImporters::Candidate#snapshot`.
- Produces: rake `e2e:import_finder_seed` (prints one JSON line `{"decision_id":N,"pair_id":M}`; env `E2E_BOOK_A` default `nightmare-abbey`, `E2E_BOOK_B` default `war-and-peace`) and `e2e:import_finder_cleanup`; sidebar items "Match Decisions" and "Duplicates" in every domain.

- [ ] **Step 1: Write the failing nav test**

Append to `web-app/test/lib/admin/domain_nav_test.rb`:

```ruby
    test "every domain's sidebar links the import finder audit pages" do
      expected = {
        books: ["/admin/match_decisions", "/admin/duplicate_candidates"],
        music: ["/admin/match_decisions", "/admin/duplicate_candidates"],
        games: ["/admin/match_decisions", "/admin/duplicate_candidates"]
      }

      expected.each do |domain, (decisions_path, duplicates_path)|
        items = Admin::DomainNav.config_for(domain)[:items]
        decisions = items.find { |item| item[:label] == "Match Decisions" }
        duplicates = items.find { |item| item[:label] == "Duplicates" }

        assert decisions, "#{domain} has no Match Decisions item"
        assert duplicates, "#{domain} has no Duplicates item"
        assert_equal decisions_path, decisions[:path]
        assert_equal duplicates_path, duplicates[:path]
      end
    end
```

Check how the existing tests in that file read `item[:path]` (a resolved string, or a lambda needing `.call`) and match it.

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: FAIL: "books has no Match Decisions item".

- [ ] **Step 3: Add the sidebar items**

In `web-app/app/lib/admin/domain_nav.rb`, append to each domain's `items` array, after its "Corrections" entry:

music:
```ruby
          {label: "Match Decisions", icon: :chart, path: -> { URL_HELPERS.admin_match_decisions_path }},
          {label: "Duplicates", icon: :list, path: -> { URL_HELPERS.admin_duplicate_candidates_path }},
```
games:
```ruby
          {label: "Match Decisions", icon: :chart, path: -> { URL_HELPERS.admin_games_match_decisions_path }},
          {label: "Duplicates", icon: :list, path: -> { URL_HELPERS.admin_games_duplicate_candidates_path }},
```
books:
```ruby
          {label: "Match Decisions", icon: :chart, path: -> { URL_HELPERS.admin_books_match_decisions_path }},
          {label: "Duplicates", icon: :list, path: -> { URL_HELPERS.admin_books_duplicate_candidates_path }},
```

Run: `bin/rails test test/lib/admin/domain_nav_test.rb` → PASS.

- [ ] **Step 4: Write the failing rake test**

```ruby
# web-app/test/lib/tasks/e2e_import_finder_rake_test.rb
# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eImportFinderRakeTest < ActiveSupport::TestCase
  MARKER = "E2E import finder audit seed"

  setup do
    unless Rake::Task.task_defined?("e2e:import_finder_seed")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    @seed = Rake::Task["e2e:import_finder_seed"]
    @cleanup = Rake::Task["e2e:import_finder_cleanup"]
    @seed.reenable
    @cleanup.reenable
    @previous = ENV.slice("E2E_BOOK_A", "E2E_BOOK_B")
    ENV["E2E_BOOK_A"] = "crime-and-punishment"
    ENV["E2E_BOOK_B"] = "war-and-peace"
    @a = books_books(:crime_and_punishment)
    @b = books_books(:war_and_peace)
  end

  teardown do
    ENV.delete("E2E_BOOK_A")
    ENV.delete("E2E_BOOK_B")
    ENV.update(@previous)
  end

  def seeded_pair
    x, y = [@a.id, @b.id].minmax
    DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: x, item_b_id: y)
  end

  test "seed creates one unmatched needs-review decision with the created record and one local candidate, one pending pair, and prints their ids" do
    output = nil
    assert_difference("MatchDecision.count", 1) do
      assert_difference("DuplicateCandidate.count", 1) do
        output = capture_io { @seed.invoke }.first
      end
    end

    ids = JSON.parse(output.lines.last)
    decision = MatchDecision.find(ids["decision_id"])
    pair = DuplicateCandidate.find(ids["pair_id"])

    assert decision.unmatched?
    assert decision.needs_review?
    assert_equal @a, decision.record
    assert_equal MARKER, decision.reason
    assert_equal [@b.id], decision.candidates.map { |candidate| candidate["record_id"] }
    assert_equal @a.title, decision.query["title"]

    assert pair.pending?
    assert pair.raised_by_bulk_verify?
    assert_equal MARKER, pair.evidence["reason"]
    assert_equal decision, pair.match_decision
    assert_equal seeded_pair, pair
  end

  test "seed is idempotent and resets a reviewed decision and a dismissed pair" do
    capture_io { @seed.invoke }
    decision = MatchDecision.find_by!(reason: MARKER)
    decision.review!(by: users(:admin_user), note: "done")
    seeded_pair.update!(status: :not_duplicate, resolved_at: Time.current, resolution_note: "no")
    @seed.reenable

    assert_no_difference(["MatchDecision.count", "DuplicateCandidate.count"]) do
      capture_io { @seed.invoke }
    end

    assert_nil decision.reload.reviewed_at
    assert seeded_pair.pending?
    assert_nil seeded_pair.resolution_note
  end

  test "seed refuses to clobber a real pair between the two books" do
    x, y = [@a.id, @b.id].minmax
    DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: x, item_b_id: y, source: :ai, status: :pending, evidence: {"reason" => "a real one"})

    assert_output(nil, /already exists/) do
      assert_raises(SystemExit) { @seed.invoke }
    end
    assert_nil MatchDecision.find_by(reason: MARKER)
  end

  test "cleanup removes only what the seed created" do
    capture_io { @seed.invoke }
    untouched_decision = match_decisions(:low_confidence_book_match)
    untouched_pair = duplicate_candidates(:books_pending_pair)

    assert_difference("MatchDecision.count", -1) do
      assert_difference("DuplicateCandidate.count", -1) do
        assert_output(/removed 1 pair\(s\) and 1 decision\(s\)/) { @cleanup.invoke }
      end
    end
    assert MatchDecision.exists?(untouched_decision.id)
    assert DuplicateCandidate.exists?(untouched_pair.id)
    assert_nil MatchDecision.find_by(reason: MARKER)
  end
end
```

`capture_io` is Minitest's; `assert_output` is used the same way in `test/lib/tasks/books_duplicates_rake_test.rb`.

- [ ] **Step 5: Run it to verify it fails**

Run: `bin/rails test test/lib/tasks/e2e_import_finder_rake_test.rb`
Expected: FAIL: `Don't know how to build task 'e2e:import_finder_seed'`.

- [ ] **Step 6: Add the rake tasks**

Append inside `namespace :e2e do ... end` in `web-app/lib/tasks/e2e.rake` (before the final `end`):

```ruby
  # Marker on every row the two tasks below own. The spec finds its rows by
  # id (printed by the seed) and the cleanup finds them by this marker.
  IMPORT_FINDER_MARKER = "E2E import finder audit seed"

  desc "Seed one match decision and one duplicate pair for e2e/tests/books/admin/import-finder-audit.spec.ts (E2E_BOOK_A, E2E_BOOK_B override the slugs)"
  task import_finder_seed: :environment do
    # Exactly what the spec drives: one needs-review decision (unmatched, with
    # the created record set and one local candidate, so the show page offers
    # "Merge into candidate 1") and one pending pair between the same two
    # books. Idempotent: a second run resets the rows the spec reviewed and
    # dismissed instead of adding more. Prints one JSON line with the ids.
    book_a = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_A", "nightmare-abbey"))
    book_b = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_B", "war-and-peace"))
    a, b = [book_a.id, book_b.id].minmax

    pair = DuplicateCandidate.find_or_initialize_by(item_type: "Books::Book", item_a_id: a, item_b_id: b)
    if pair.persisted? && pair.evidence.to_h["reason"] != IMPORT_FINDER_MARKER
      abort "A real duplicate_candidates row already exists for #{book_a.slug} + #{book_b.slug} (##{pair.id}); " \
        "pick other books with E2E_BOOK_A / E2E_BOOK_B."
    end

    decision = MatchDecision.find_or_initialize_by(finder: "DataImporters::Books::Book::Finder", reason: IMPORT_FINDER_MARKER)
    candidate = DataImporters::Candidate.new(
      record: book_b, sources: [:opensearch], scores: {opensearch: 7.5},
      evidence: {title: book_b.title, creators: book_b.authors.map(&:name), year: book_b.first_published_year}
    )
    decision.assign_attributes(
      record: book_a, subject: nil, outcome: :unmatched, confidence: :low, decided_by: :ai, verify: false,
      query: {"title" => book_a.title, "author_names" => book_a.authors.map(&:name), "year" => book_a.first_published_year},
      candidates: [candidate.snapshot], selected_index: nil, sources_failed: [],
      needs_review: true, reviewed_at: nil, reviewed_by: nil, review_note: nil
    )
    decision.save!

    pair.assign_attributes(
      source: :bulk_verify, status: :pending, evidence: {"reason" => IMPORT_FINDER_MARKER}, occurrences: 1,
      match_decision: decision, resolved_at: nil, resolved_by: nil, resolution_note: nil
    )
    pair.save!

    puts({decision_id: decision.id, pair_id: pair.id}.to_json)
  end

  desc "Remove the rows e2e:import_finder_seed created"
  task import_finder_cleanup: :environment do
    pairs = DuplicateCandidate.where("evidence->>'reason' = ?", IMPORT_FINDER_MARKER).to_a
    decisions = MatchDecision.where(reason: IMPORT_FINDER_MARKER).to_a
    pairs.each(&:destroy!)
    decisions.each(&:destroy!)
    puts "removed #{pairs.size} pair(s) and #{decisions.size} decision(s)"
  end
```

Run: `bin/rails test test/lib/tasks/e2e_import_finder_rake_test.rb` → PASS.

- [ ] **Step 7: Write the Playwright spec**

```ts
// web-app/e2e/tests/books/admin/import-finder-audit.spec.ts
import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Spec §15: seed one decision and one pair against two development books
// through a rake helper, exercise the filters, mark reviewed, dismiss the
// pair, drive both merge forms to the confirm gate and stop, then remove what
// was seeded. This spec NEVER performs a merge: it runs against the
// development database and a merge destroys a row with no undo. Both merge
// attempts below click Submit with the required checkbox unticked, so the
// browser blocks the form and the page never leaves.
//
// The seed runs `bin/rails e2e:import_finder_seed` from web-app, so this spec
// needs the same Ruby environment the dev server has. Idempotent: rerunning
// after a failed run resets the seeded rows.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let decisionId: number;
let pairId: number;

test.describe("Books admin — import finder audit", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    const lines = rails("e2e:import_finder_seed").trim().split("\n");
    const ids = JSON.parse(lines[lines.length - 1]);
    decisionId = ids.decision_id;
    pairId = ids.pair_id;
  });

  test.afterAll(() => {
    rails("e2e:import_finder_cleanup");
  });

  test("the decisions queue lists the seeded decision, filters it, stops a merge at the confirm gate, and marks it reviewed", async ({ page }) => {
    const row = page.locator(`[data-testid="decision-row"][data-decision-id="${decisionId}"]`);

    await page.goto("/admin/match_decisions");
    await expect(row).toBeVisible();

    // outcome=matched excludes an unmatched decision; the matching filter set keeps it.
    await page.goto("/admin/match_decisions?outcome=matched");
    await expect(row).toHaveCount(0);
    await page.goto("/admin/match_decisions?outcome=unmatched&confidence=low&decided_by=ai&entity=book");
    await expect(row).toBeVisible();

    await row.getByRole("link").first().click();
    await expect(page).toHaveURL(new RegExp(`/admin/match_decisions/${decisionId}$`));
    await expect(page.locator('[data-testid="candidate-row"]')).toHaveCount(1);

    // Merge into candidate 1: the required checkbox blocks submission, so the URL does not change.
    const merge = page.getByTestId("merge-into-candidate");
    await merge.locator("summary").click();
    await merge.getByRole("button", { name: "Merge into #1" }).click();
    await expect(page).toHaveURL(new RegExp(`/admin/match_decisions/${decisionId}$`));

    await page.getByTestId("review-form").getByLabel("Review note").fill("E2E import finder audit spec");
    await page.getByRole("button", { name: "Mark reviewed" }).click();
    await expect(page.getByRole("alert")).toContainText("Marked reviewed.");

    await page.goto("/admin/match_decisions");
    await expect(row).toHaveCount(0);
    await page.goto("/admin/match_decisions?reviewed=reviewed");
    await expect(row).toBeVisible();
  });

  test("the duplicates queue lists the seeded pair, stops a merge at the confirm gate, and dismisses it", async ({ page }) => {
    const pair = page.locator(`[data-testid="pair-row"][data-pair-id="${pairId}"]`);

    await page.goto("/admin/duplicate_candidates");
    await expect(pair).toBeVisible();
    await expect(pair.locator('[data-testid="pair-side"]')).toHaveCount(2);

    const merge = pair.getByTestId("merge-a-into-b");
    await merge.locator("summary").click();
    await merge.getByRole("button", { name: "Merge A into B" }).click();
    await expect(page).toHaveURL(/\/admin\/duplicate_candidates$/);
    await expect(pair).toBeVisible();

    await pair.getByTestId("dismiss-form").getByPlaceholder("Why not a duplicate (optional)").fill("E2E import finder audit spec");
    await pair.getByRole("button", { name: "Not a duplicate" }).click();
    await expect(page.getByRole("alert")).toContainText("Marked as not a duplicate.");
    await expect(pair).toHaveCount(0);

    await page.goto("/admin/duplicate_candidates?status=not_duplicate");
    await expect(pair).toBeVisible();
  });
});
```

Do not run it (Global Constraints). Type-check only: `npx tsc --noEmit -p e2e/tsconfig.json` from `web-app/` if that config exists; otherwise skip and say so in the report.

- [ ] **Step 8: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/lib/admin/domain_nav.rb lib/tasks/e2e.rake e2e/tests/books/admin/import-finder-audit.spec.ts test/lib/admin/domain_nav_test.rb test/lib/tasks/e2e_import_finder_rake_test.rb
git commit -m "Audit pages in every admin sidebar; e2e:import_finder_seed/cleanup and the Playwright spec that drives both queues to the merge confirm gate"
```

---

### Task 6: Documentation and spec amendments

**Files:**
- Modify: `docs/features/import-finder.md`
- Modify: `docs/features/admin-domain-registry.md`
- Modify: `docs/features/e2e-testing.md`
- Modify: `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` (§13 and the decisions list)

- [ ] **Step 1: `docs/features/import-finder.md`**

Add a section after "## The duplicate sweep" (before the deploy paragraph about `ANALYZE`):

```markdown
## Audit UI (increment 3)

Two pages per admin domain, under **Match Decisions** and **Duplicates** in the sidebar:
`/admin/match_decisions` and `/admin/duplicate_candidates` on each admin host. Both are shared
base controllers (`Admin::MatchDecisionsBaseController`, `Admin::DuplicateCandidatesBaseController`)
subclassed per domain in three lines (`domain`, `route_prefix`), the same shape as reviews.
Everything they show is scoped by `DataImporters::FinderRegistry`, which names, for every
finder class stored in `match_decisions.finder`: its admin domain, its model, its ImportQuery,
what to preload for a summary, how the model is merged (the `Actions::Admin::*` merge action,
the field it reads the source id from, the record's `execute_action` route) and whether
Re-check is offered. A finder with no entry is on no page; the registry test fails if a
`finder.rb` exists without one.

**Match decisions** opens on decisions needing review and not yet reviewed, with `verify: true`
rows hidden -- the sweep writes one per ranked book. Filters: entity, outcome, confidence,
decided by, review state (`pending` / `reviewed` / `all`), verify runs (`hide` / `include`);
`?page=N` pagination like every admin index. The show page lists the stored query, every
candidate (local or external, creators, year, ranked position, sources, scores, identifiers
shared with the query) with the selected row marked, the reasoning, and the AI chat's messages
inline. Actions for writers: **Mark reviewed** with a note; **Re-check**, which runs the finder
again synchronously with `verify: true` (every source, no early exit) and redirects to the new
decision with the original beside it -- offered only where the registry says the finder's real
sources have landed (books today); **Merge into candidate N**, offered when the decision was
unmatched, carries the record the importer created, and candidate N is a local record of the
same model. Re-check excludes the decision's subject when the subject is a record of the
finder's model (a sweep decision re-resolves that book against the rest), else the created
record of an unmatched import (or it would match itself), else nothing.

**Duplicates** opens on pending pairs, newest first, each record summarized live through
`FinderBase#summarize` (title, creators, year, ranked position, list count, identifiers) with
the evidence reason, source, occurrence count and a link to the raising decision. Tabs for
merged and dismissed pairs. Actions for writers: **Not a duplicate** with a note (the pair
becomes `not_duplicate`, which `Flag` never reopens and the rules never merge); **Merge A into
B** and **Merge B into A**. A record that no longer exists shows as missing and the pair offers
dismissal only.

Merges are never performed by these controllers. Every merge form posts to the domain's
existing `execute_action` endpoint with the same required confirm checkbox as the record
pages' merge modal, so the endpoint's delete gate (`authorize :destroy?`) and the merger's
`RecordMerge` hook apply unchanged; the form submits without Turbo, so the browser lands on the
surviving record with the result as flash. `Games::Company` has no merge action and offers
dismissal and review only.

Reading needs domain access; review, re-check and dismiss need write access
(`require_domain_write!`).

E2E: `e2e/tests/books/admin/import-finder-audit.spec.ts` seeds one decision and one pair with
`bin/rails e2e:import_finder_seed` (idempotent; `E2E_BOOK_A` / `E2E_BOOK_B` override the
default `nightmare-abbey` + `war-and-peace`), drives filters, review, both merge forms to the
confirm gate, and dismissal, then runs `e2e:import_finder_cleanup`. It never merges.
```

Update the "State by increment" paragraph: replace "The audit UI is increment 3, the authors importer..." with "The audit UI (increment 3) is described below; the authors importer and the book provider's author step are increment 4, games is increment 5 and music is increment 6."

- [ ] **Step 2: `docs/features/admin-domain-registry.md`**

Append after item 11 in "What a new domain must add":

```markdown
### Import finder audit

The match decisions and duplicate candidates pages (`docs/features/import-finder.md`, "Audit
UI") are driven by a third registry, `DataImporters::FinderRegistry`. A domain that gains a
finder needs:

12. **A `DataImporters::FinderRegistry::ENTRIES` entry** for the finder: domain, model, label,
    ImportQuery class, preloads, and -- when the model has a merge action -- the
    `Actions::Admin::<Domain>::Merge*` name, the `source_<model>_id` field it reads, and the
    record's `execute_action` route. `test/lib/data_importers/finder_registry_test.rb` fails
    when a `finder.rb` has no entry.
13. **`Admin::<Domain>::MatchDecisionsController < Admin::MatchDecisionsBaseController`** and
    **`Admin::<Domain>::DuplicateCandidatesController < Admin::DuplicateCandidatesBaseController`**,
    each filling in `domain` and `route_prefix` (see `app/controllers/admin/books/`).
14. **Routes** inside the domain's admin namespace: `resources :match_decisions, only: [:index,
    :show]` with member `post :review` and `post :recheck`; `resources :duplicate_candidates,
    only: [:index]` with member `post :dismiss`.
15. **Sidebar items** "Match Decisions" and "Duplicates" in `Admin::DomainNav::CONFIGS[domain][:items]`;
    `test/lib/admin/domain_nav_test.rb` asserts every domain has both.
```

- [ ] **Step 3: `docs/features/e2e-testing.md`**

Where `bin/rails e2e:admin` is listed among setup tasks (around line 105 and 244), add one line:

```markdown
`e2e/tests/books/admin/import-finder-audit.spec.ts` seeds its own rows by shelling out to
`bin/rails e2e:import_finder_seed` and removes them with `e2e:import_finder_cleanup`; both are
idempotent and safe to re-run after an interrupted run.
```

- [ ] **Step 4: Spec amendments**

In `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` §13, change "path-based pagination" to "`?page=N` pagination as on every admin index", and "links to the AI chat" to "the AI chat's messages inline". Append to the "Decisions made during brainstorming" list:

```markdown
- **Increment 3 readings** (declared at implementation): `?page=N` pagination on the admin
  pages (path-based paging serves edge-cached public pages; the admin is never cached); Re-check
  offered only where `DataImporters::FinderRegistry` says the finder's real sources have landed
  (books), because `verify: true` on a legacy-only finder sends one candidate to the AI for
  nothing; the AI chat renders inline (the books admin has no AI chats page); Re-check excludes
  the subject when it is a record of the finder's own model, else the created record of an
  unmatched import, else nothing; merge forms submit without Turbo so the browser lands on the
  surviving record; "Merge into candidate N" needs the decision to carry a record (a sweep
  decision has none -- its pair is on the duplicates page); `Games::Company` has no merge
  action and offers dismissal and review only; the E2E spec seeds and cleans through
  `e2e:import_finder_seed` / `e2e:import_finder_cleanup` and is run by hand.
```

- [ ] **Step 5: Commit**

```bash
git add ../docs/features/import-finder.md ../docs/features/admin-domain-registry.md ../docs/features/e2e-testing.md ../docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md
git commit -m "Docs: the audit UI, the finder registry as a fourth admin registry, the E2E seed tasks, and the increment 3 readings in the spec"
```

---

## Self-review notes

- **Spec coverage.** §13 match decisions: index defaults (Task 2), filters (Task 2), pagination (Task 2, ruling 1), row fields (Task 2), show contents (Task 2), Mark reviewed / Re-check / Merge into candidate N (Task 3). §13 duplicate candidates: side by side with summary fields (Task 4), Not a duplicate (Task 4), both merge directions behind the confirm (Task 4 via Task 3's partial), status filter (Task 4). §13 authorization (Tasks 2–4, `DomainScopedAuth`). §15 controller tests behaviour-only (Tasks 2–4), one Playwright spec seeding through a rake helper (Task 5), zeitwerk/standardrb (every task). Sidebar (Task 5). Docs (Task 6).
- **Type consistency.** `Entry` fields: `finder domain model label query preloads merge_action source_field execute_action_path recheck`; methods `finder_class model_class query_class mergeable? recheck?` — used identically in Tasks 2–5. `summarize` returns symbol keys; `_side.html.erb` reads symbols. Candidate snapshots and `decision.query` are string-keyed JSON; views and helpers read strings. Merge partial locals `entry: source: target: label:` in both call sites. Route prefixes: `admin_books_`, `admin_`, `admin_games_` everywhere.
- **Fixture safety.** New pairs use `got + clash` and `cannery_row + clash`; the existing finder and merger tests raise `war_and_peace + crime_and_punishment` and `crime_and_punishment + combo_steinbeck`. The old `record_id: 1` literal becomes a real fixture id.
