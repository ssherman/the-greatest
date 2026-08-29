# Public List Submission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let visitors — signed in or anonymous — submit a list for review on books, games and music, through one shared, rate-limited, spam-resistant path that replaces music's partial implementation.

**Architecture:** No new table. A submission is a `List` row with `status: :unapproved`, a new `submitted_at` stamp, and an optional submitter email/IP. A shared `ListSubmissionsController` modelled closely on the existing `CorrectionsController` serves an edge-cached form on all three domains; a `Services::Lists::SubmissionRegistry` maps the current domain to the list classes it accepts, so no user input is ever `constantize`d. A `Services::Lists::Submission` service enforces length caps and duplicate-URL detection. Admins find submissions through a new filter on the existing lists page.

**Tech Stack:** Rails 8.1, Ruby 4.0.6, Minitest 6 + fixtures + Mocha, ViewComponents, Turbo/Stimulus, daisyUI 5 on Tailwind 4, Sidekiq, Playwright for E2E.

**Spec:** `docs/superpowers/specs/2026-08-29-list-submissions-design.md`

## Global Constraints

- **Run every command from `web-app/`.** Docs live at the project root, not `web-app/docs/`.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. Do not run brakeman.
- **Use Rails generators** for new controllers/models/jobs/components — never hand-create them.
- **Namespace all media code** (`Books::`, `Music::`, `Games::`); shared models stay global. Tests mirror the namespace.
- **Skinny models, fat services.** Business logic goes in `app/lib/services/<domain>/` using `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Rails 8 enum syntax:** `enum :status, {active: 0}`.
- **Minitest is 6.x.** `assert_equal nil, x` is a hard failure — use `assert_nil`.
- **Sidekiq test mode is `:inline`**, set globally. Never `require "sidekiq/testing"`.
- **Never run destructive DB commands against development.** `ActiveRecord::FixtureSet.create_fixtures` TRUNCATES. To read a fixture, read the YAML.
- **daisyUI 5:** these classes were removed in v5 and fail silently — `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`/`checkbox`. `test/lint/daisyui_v4_classes_test.rb` fails on any new occurrence.
- **Turbo Frames trap links.** Any `<a>` inside a `turbo_frame_tag` navigates that frame. `assert_no_frame_trapped_links` guards this.
- **Public layouts render no flash.** A `redirect_to ..., notice:` on a public page is dead code. Use a dedicated thanks page.
- **Secrets are ENV vars via SOPS** — never `Rails.application.credentials`.
- **Every IP-keyed rate limit goes through `VisitorIp#visitor_ip`** (`CF-Connecting-IP`), never `request.remote_ip`.
- **A clean `bin/rails test` emits no warnings** beyond two known upstream sources. A new warning line is a regression.
- Before claiming done: `bin/rails test` and `bundle exec standardrb` must both pass.

### Worktree setup (already done, but re-do if starting fresh)

This worktree was created without the five gitignored files it needs. If `bin/rails db:test:prepare` fails with `PG::ConnectionBad: no password supplied`, copy them from the main checkout at `/home/shane/dev/the-greatest`:

```bash
cp /home/shane/dev/the-greatest/.env .env
cp /home/shane/dev/the-greatest/web-app/.env web-app/.env
cp /home/shane/dev/the-greatest/web-app/config/master.key web-app/config/master.key
cp /home/shane/dev/the-greatest/web-app/e2e/.env web-app/e2e/.env
ln -s /home/shane/dev/the-greatest/web-app/node_modules web-app/node_modules
cd web-app && yarn build:all && bin/rails db:test:prepare
```

`yarn build:all` is required: `assets/builds/` is gitignored, and without it every layout render fails with `The asset 'music.css' was not found in the load path.`

---

## File Structure

**Increment 1 — close the music leak**
- Modify: `app/controllers/music/albums/lists_controller.rb` — scope `show` and `index` to active
- Modify: `app/controllers/music/songs/lists_controller.rb` — same
- Modify: `test/fixtures/lists.yml:172` — `music_songs_list` status `1` → `3`
- Modify: `app/views/music/albums/lists/show.html.erb:68`, `app/views/music/songs/lists/show.html.erb:68`, `app/views/games/lists/show.html.erb:52` — add `nofollow`

**Increment 2 — shared machinery, wired to books**
- Create: `db/migrate/*_add_submission_fields_to_lists.rb`
- Modify: `app/models/list.rb` — `attr_accessor :skip_content_simplification`, guard the callback
- Create: `app/lib/services/lists/submission_registry.rb` — domain → allowed list classes
- Create: `app/lib/services/lists/submission.rb` — caps, duplicate detection, record build
- Rename: `app/controllers/correction_token_controller.rb` → `app/controllers/form_token_controller.rb`
- Rename: `app/javascript/controllers/corrections/form_controller.js` → `app/javascript/controllers/shared/form_token_controller.js`
- Create: `app/controllers/list_submissions_controller.rb`
- Create: `app/views/list_submissions/new.html.erb`, `_form.html.erb`, `thanks.html.erb`
- Modify: `app/mailers/admin_mailer.rb` + `app/views/admin_mailer/new_list_submission.{html,text}.erb`
- Modify: `config/routes.rb` — books GETs, global POST, `/form_token`

**Increment 3 — games and music**
- Modify: `config/routes.rb` — games and music GETs; games `lists/:id` id constraint; music `resources :lists, only: [:index]`
- Delete: `Music::ListsController#new/#create`, `app/views/music/lists/{new,_form}.html.erb`, and the submission tests in `test/controllers/music/lists_controller_test.rb`
- Modify: `app/views/{books,games,music}/lists/index.html.erb` — entry-point button

**Increment 4 — admin**
- Modify: `app/controllers/admin/lists_base_controller.rb` — `submitted` filter
- Modify: `app/components/admin/lists/index_component.html.erb`, `table_component.html.erb`, `show_component.html.erb`

**Increment 5 — finish**
- Modify: `public/robots.txt`
- Create: `e2e/tests/books/list-submission.spec.ts`
- Create: `docs/features/list-submissions.md`

---

# Increment 1 — Close the music list-show leak

Ships independently and first. Today `Music::Albums::ListsController#show` and the songs equivalent do `List.find(params[:id])` with no status filter, so any submitted list is immediately public, edge-cached 24h, indexable, and renders the submitter's URL as a followed outbound link.

### Task 1: Scope music list show and index to active lists

**Files:**
- Modify: `app/controllers/music/albums/lists_controller.rb:21,29`
- Modify: `app/controllers/music/songs/lists_controller.rb:21,29`
- Modify: `test/fixtures/lists.yml:172`
- Test: `test/controllers/music/albums/lists_controller_test.rb`, `test/controllers/music/songs/lists_controller_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: the invariant every later task relies on — a `List` whose status is not `active` is not reachable on any public page.

**Context you need:** `Games::ListsController#show` already does this correctly and is the template:

```ruby
@list = Games::List.where(status: :active).find_by!(id: params[:id])
```

`test/controllers/games/lists_controller_test.rb:91` has the matching regression test. `List` statuses are `{unapproved: 0, approved: 1, rejected: 2, active: 3}`.

**Already verified:** flipping `music_songs_list` to `status: 3` leaves the full 8,199-test suite green. `music_albums_list` is already `status: 3`, so albums needs no fixture change.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/music/albums/lists_controller_test.rb`, inside the existing `class ListsControllerTest`:

```ruby
test "show 404s for a non-active list" do
  list = lists(:music_albums_list)
  list.update!(status: :unapproved)

  get "/albums/lists/#{list.id}"

  assert_response :not_found
end

test "index excludes non-active lists" do
  list = lists(:music_albums_list)
  list.update!(status: :unapproved)

  get "/albums/lists"

  assert_response :success
  assert_select "a[href=?]", "/albums/lists/#{list.id}", count: 0
end
```

Append the songs equivalents to `test/controllers/music/songs/lists_controller_test.rb`:

```ruby
test "show 404s for a non-active list" do
  list = lists(:music_songs_list)
  list.update!(status: :unapproved)

  get "/songs/lists/#{list.id}"

  assert_response :not_found
end

test "index excludes non-active lists" do
  list = lists(:music_songs_list)
  list.update!(status: :unapproved)

  get "/songs/lists"

  assert_response :success
  assert_select "a[href=?]", "/songs/lists/#{list.id}", count: 0
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/music/albums/lists_controller_test.rb
bin/rails test test/controllers/music/songs/lists_controller_test.rb
```

Expected: the two `show 404s` tests FAIL with `Expected response to be a <404: Not Found>, but was a <200: OK>`. The `index excludes` tests may already pass if the fixture has no `RankedList`; that is fine — they pin the behaviour either way.

Note: Minitest 6 will not accept two file paths in one `bin/rails test` invocation. Run one file per command.

- [ ] **Step 3: Scope both show actions**

In `app/controllers/music/albums/lists_controller.rb`, replace line 29:

```ruby
    @list = Music::Albums::List.where(status: :active).find_by!(id: params[:id])
```

In `app/controllers/music/songs/lists_controller.rb`, replace line 29:

```ruby
    @list = Music::Songs::List.where(status: :active).find_by!(id: params[:id])
```

- [ ] **Step 4: Scope both index actions**

In `app/controllers/music/albums/lists_controller.rb`, replace line 21:

```ruby
      .where(lists: {type: "Music::Albums::List", status: ::List.statuses[:active]})
```

In `app/controllers/music/songs/lists_controller.rb`, replace line 21:

```ruby
      .where(lists: {type: "Music::Songs::List", status: ::List.statuses[:active]})
```

`::List.statuses[:active]` (the integer), root-anchored: inside `Music::Songs`, a bare `List` resolves to `Music::Songs::List` and the constant lookup silently gives you the wrong class. This codebase has been bitten by nested-namespace shadowing repeatedly.

- [ ] **Step 5: Flip the songs fixture to active**

In `test/fixtures/lists.yml`, in the `music_songs_list` block (line 172), change `status: 1` to:

```yaml
  status: 3
```

`music_albums_list` is already `status: 3`. This asymmetry is what breaks 6 existing songs tests without the flip; it is already verified to have no other effect.

- [ ] **Step 6: Run both test files to verify they pass**

```bash
bin/rails test test/controllers/music/albums/lists_controller_test.rb
bin/rails test test/controllers/music/songs/lists_controller_test.rb
```

Expected: PASS, 0 failures, 0 errors in both.

- [ ] **Step 7: Run the full suite**

```bash
bin/rails test
```

Expected: `8199 runs, 0 failures, 0 errors, 0 skips` (run count will be 8203 with the four new tests). This step is not optional — the fixture flip touches a fixture referenced by `ranked_lists.yml`, `list_items.yml`, `list_penalties.yml`, `ai_chats.yml` and eight test files.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb
git add app/controllers/music/albums/lists_controller.rb app/controllers/music/songs/lists_controller.rb test/fixtures/lists.yml test/controllers/music/albums/lists_controller_test.rb test/controllers/music/songs/lists_controller_test.rb
git commit -m "Scope music list show and index to active lists

Both actions did List.find with no status filter, unlike books and
games, so any unapproved list was publicly reachable, edge-cached and
indexable. With public submission arriving this becomes an SEO-spam
vector on a live site."
```

### Task 2: Add nofollow to outbound source links on list pages

**Files:**
- Modify: `app/views/music/albums/lists/show.html.erb:68`
- Modify: `app/views/music/songs/lists/show.html.erb:68`
- Modify: `app/views/games/lists/show.html.erb:52`
- Test: `test/controllers/music/albums/lists_controller_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing later tasks depend on.

**Context you need:** `app/views/books/lists/show.html.erb:28` already gets this right — `rel: "noopener nofollow"`. The other three render `rel: "noopener noreferrer"`, so a submitter-supplied URL earns a followed outbound link from an indexable page.

- [ ] **Step 1: Write the failing test**

Append to `test/controllers/music/albums/lists_controller_test.rb`:

```ruby
test "source link is nofollow" do
  list = lists(:music_albums_list)
  list.update!(url: "https://example.com/greatest-albums")

  get "/albums/lists/#{list.id}"

  assert_response :success
  assert_select "a[href=?][rel~=?]", "https://example.com/greatest-albums", "nofollow"
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/controllers/music/albums/lists_controller_test.rb
```

Expected: FAIL — `Expected at least 1 element matching "a[href=...][rel~=nofollow]", found 0.`

- [ ] **Step 3: Add nofollow in all three views**

In `app/views/music/albums/lists/show.html.erb` and `app/views/music/songs/lists/show.html.erb`, change line 68:

```erb
        <%= link_to @list.url, target: "_blank", rel: "noopener noreferrer nofollow",
```

In `app/views/games/lists/show.html.erb`, change line 52 the same way:

```erb
        <%= link_to @list.url, target: "_blank", rel: "noopener noreferrer nofollow",
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/controllers/music/albums/lists_controller_test.rb
```

Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb
git add app/views/music/albums/lists/show.html.erb app/views/music/songs/lists/show.html.erb app/views/games/lists/show.html.erb test/controllers/music/albums/lists_controller_test.rb
git commit -m "Add nofollow to outbound list source links

Books already did this; music and games passed link equity to a URL
that will shortly be submitter-supplied."
```

---

# Increment 2 — Shared machinery, wired to books

### Task 3: Migration for the submission fields

**Files:**
- Create: `db/migrate/<timestamp>_add_submission_fields_to_lists.rb`
- Modify: `db/schema.rb` (generated)
- Test: `test/models/list_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `List#submitted_at` (datetime, nullable), `List#submitter_email` (string, nullable), `List#submitter_ip` (string, nullable). Every later task uses `submitted_at` as the marker that a row came from the public form.

**Context you need:** `lists` already has `submitted_by_id` (FK `users`, nullable) and `status` `{unapproved: 0, approved: 1, rejected: 2, active: 3}`. `submitted_by_id` alone cannot identify submissions: 1,721 of 1,772 unapproved lists have no submitter and are import backlog.

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration AddSubmissionFieldsToLists
```

- [ ] **Step 2: Write the migration body**

Replace the generated file's contents:

```ruby
class AddSubmissionFieldsToLists < ActiveRecord::Migration[8.1]
  def up
    add_column :lists, :submitted_at, :datetime
    add_column :lists, :submitter_email, :string
    add_column :lists, :submitter_ip, :string
    add_index :lists, :submitted_at

    # Backfill the legacy submissions carried over from the old books site so the
    # admin "user submitted" filter finds them. A no-op in production -- all 209
    # such rows are Books::List and books data exists only in development.
    execute <<~SQL
      UPDATE lists SET submitted_at = created_at WHERE submitted_by_id IS NOT NULL
    SQL
  end

  def down
    remove_index :lists, :submitted_at
    remove_column :lists, :submitter_ip
    remove_column :lists, :submitter_email
    remove_column :lists, :submitted_at
  end
end
```

`up`/`down` rather than `change`: the backfill is not automatically reversible.

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
```

Expected: three columns and one index added, `db/schema.rb` updated.

- [ ] **Step 4: Write a test pinning the columns**

Append to `test/models/list_test.rb`:

```ruby
test "carries the public submission fields" do
  list = lists(:basic_list)
  list.update!(
    submitted_at: Time.current,
    submitter_email: "reader@example.com",
    submitter_ip: "203.0.113.7"
  )

  list.reload
  assert_not_nil list.submitted_at
  assert_equal "reader@example.com", list.submitter_email
  assert_equal "203.0.113.7", list.submitter_ip
end

test "submission fields default to nil for an admin-created list" do
  list = Books::List.create!(name: "Admin made", status: :unapproved)

  assert_nil list.submitted_at
  assert_nil list.submitter_email
  assert_nil list.submitter_ip
end
```

- [ ] **Step 5: Run it**

```bash
bin/rails test test/models/list_test.rb
```

Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
git add db/migrate db/schema.rb test/models/list_test.rb
git commit -m "Add submitted_at, submitter_email and submitter_ip to lists

submitted_at is the marker separating public submissions from admin
import backlog; submitted_by_id cannot do it, since 1,721 of 1,772
unapproved lists are backlog with no submitter."
```

### Task 4: Let the submission path skip the Nokogiri parse

**Files:**
- Modify: `app/models/list.rb:79`
- Test: `test/models/list_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `List#skip_content_simplification` (boolean accessor). Task 6 sets it to `true`.

**Context you need:** `app/models/list.rb:79` is `before_save :auto_simplify_content, if: :should_simplify_content?`, and `should_simplify_content?` (line 166) is `raw_content.present? && (new_record? || raw_content_changed?)`. So every submission carrying pasted content would run `Services::Html::SimplifierService` — a Nokogiri parse — synchronously in the request. Production `raw_content` reaches 1.5 MB.

This is safe to skip because `Services::Lists::ImportService` recomputes it unconditionally before parsing:

```ruby
simplified_content = Services::Html::SimplifierService.call(@list.raw_content)
@list.update!(simplified_content: simplified_content)
```

- [ ] **Step 1: Write the failing test**

Append to `test/models/list_test.rb`:

```ruby
test "simplifies raw content on save by default" do
  list = Books::List.create!(
    name: "Simplify me", status: :unapproved,
    raw_content: "<ul><li>One</li><li>Two</li></ul>"
  )

  assert_not_nil list.simplified_content
end

test "skips simplification when skip_content_simplification is set" do
  list = Books::List.new(
    name: "Skip me", status: :unapproved,
    raw_content: "<ul><li>One</li><li>Two</li></ul>"
  )
  list.skip_content_simplification = true
  list.save!

  assert_nil list.simplified_content
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/list_test.rb
```

Expected: the second test FAILS with `NoMethodError: undefined method 'skip_content_simplification='`.

- [ ] **Step 3: Add the accessor and guard the callback**

In `app/models/list.rb`, add above the `# Callbacks` section:

```ruby
  # Set by Services::Lists::Submission only. The simplifier is a Nokogiri parse
  # and auto_simplify_content runs it inline on every new record carrying
  # raw_content -- on an anonymous public endpoint that is a CPU lever, and
  # production raw_content reaches 1.5 MB. Deferring is safe because
  # Services::Lists::ImportService recomputes simplified_content unconditionally
  # before it parses, so nothing downstream needs it at insert time.
  attr_accessor :skip_content_simplification
```

Then change line 79 to:

```ruby
  before_save :auto_simplify_content, if: :should_simplify_content?
```

and change `should_simplify_content?` (line 166) to:

```ruby
  def should_simplify_content?
    return false if skip_content_simplification

    raw_content.present? && (new_record? || raw_content_changed?)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/models/list_test.rb
```

Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb
git add app/models/list.rb test/models/list_test.rb
git commit -m "Let the submission path defer content simplification

auto_simplify_content runs a Nokogiri parse inline on every new record
with raw_content. The wizard recomputes it before parsing anyway, so
the public endpoint has no reason to pay for it in-request."
```

### Task 5: Submission registry

**Files:**
- Create: `app/lib/services/lists/submission_registry.rb`
- Test: `test/lib/services/lists/submission_registry_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Services::Lists::SubmissionRegistry.types_for(domain)` → `Array<Class>`, `[]` for an unknown domain
  - `Services::Lists::SubmissionRegistry.resolve(domain, type_name)` → `Class` or `nil`
  - `Services::Lists::SubmissionRegistry.label_for(klass)` → `String` for the picker
  - `Services::Lists::SubmissionRegistry.domain_for(klass)` → `Symbol` or `nil`, used by the mailer for branding

**Context you need:** `Current.domain` is a symbol — `:books`, `:music`, `:games` — set by `ApplicationController#set_current_domain` from `request.host`. Legacy's `params[:changeable_type].constantize` is the anti-pattern this exists to avoid.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/lists/submission_registry_test.rb`:

```ruby
require "test_helper"

module Services
  module Lists
    class SubmissionRegistryTest < ActiveSupport::TestCase
      test "books accepts one list type" do
        assert_equal [::Books::List], SubmissionRegistry.types_for(:books)
      end

      test "games accepts one list type" do
        assert_equal [::Games::List], SubmissionRegistry.types_for(:games)
      end

      test "music accepts albums and songs" do
        assert_equal [::Music::Albums::List, ::Music::Songs::List],
          SubmissionRegistry.types_for(:music)
      end

      test "an unknown domain accepts nothing" do
        assert_equal [], SubmissionRegistry.types_for(:unrecognised)
        assert_equal [], SubmissionRegistry.types_for(nil)
      end

      test "resolve returns the class when the domain allows it" do
        assert_equal ::Books::List, SubmissionRegistry.resolve(:books, "Books::List")
      end

      test "resolve returns nil for a type the domain does not allow" do
        assert_nil SubmissionRegistry.resolve(:books, "Music::Albums::List")
      end

      test "resolve returns nil for an unknown constant and does not constantize it" do
        assert_nil SubmissionRegistry.resolve(:books, "Kernel")
        assert_nil SubmissionRegistry.resolve(:books, "NoSuchThing")
      end

      test "label_for names each type for the picker" do
        assert_equal "Album List", SubmissionRegistry.label_for(::Music::Albums::List)
        assert_equal "Song List", SubmissionRegistry.label_for(::Music::Songs::List)
      end

      test "domain_for maps a list class back to its domain" do
        assert_equal :books, SubmissionRegistry.domain_for(::Books::List)
        assert_equal :games, SubmissionRegistry.domain_for(::Games::List)
        assert_equal :music, SubmissionRegistry.domain_for(::Music::Albums::List)
        assert_equal :music, SubmissionRegistry.domain_for(::Music::Songs::List)
      end

      test "domain_for returns nil for a class no domain accepts" do
        assert_nil SubmissionRegistry.domain_for(::List)
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/lib/services/lists/submission_registry_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Services::Lists::SubmissionRegistry`.

- [ ] **Step 3: Write the registry**

Create `app/lib/services/lists/submission_registry.rb`:

```ruby
module Services
  module Lists
    # Which list types each domain accepts from the public submission form, and
    # the only thing that turns a submitted type string into a class.
    #
    # A submitted type NEVER reaches constantize. Legacy did
    # params[:changeable_type].constantize, which resolves an arbitrary constant
    # from a request param; here an unlisted name simply returns nil and the
    # controller answers 400.
    class SubmissionRegistry
      TYPES = {
        books: [::Books::List],
        games: [::Games::List],
        music: [::Music::Albums::List, ::Music::Songs::List]
      }.freeze

      LABELS = {
        "Books::List" => "Book List",
        "Games::List" => "Game List",
        "Music::Albums::List" => "Album List",
        "Music::Songs::List" => "Song List"
      }.freeze

      def self.types_for(domain)
        TYPES.fetch(domain&.to_sym, [])
      end

      def self.resolve(domain, type_name)
        types_for(domain).find { |klass| klass.name == type_name }
      end

      def self.label_for(klass)
        LABELS.fetch(klass.name)
      end

      # The mailer needs the domain to pick branding, and it runs in Sidekiq where
      # Current.domain is nil. Here rather than in the mailer so it is covered by
      # this class's own tests.
      def self.domain_for(klass)
        TYPES.find { |_domain, types| types.include?(klass) }&.first
      end
    end
  end
end
```

Root-anchored constants (`::Books::List`) throughout — inside `Services::Lists`, a bare `Books::List` is a nested-namespace shadowing trap this codebase has hit repeatedly.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/services/lists/submission_registry_test.rb
```

Expected: PASS, 10 runs.

- [ ] **Step 5: Verify autoloading**

```bash
CI=1 bin/rails zeitwerk:check
```

Expected: `All is good!`. `eager_load` is off in test, so a new `app/lib` directory can pass the suite and still break boot in production.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
git add app/lib/services/lists/submission_registry.rb test/lib/services/lists/submission_registry_test.rb
git commit -m "Add the list submission type registry

Maps each domain to the list types it accepts. A submitted type name
never reaches constantize."
```

### Task 6: Submission service

**Files:**
- Create: `app/lib/services/lists/submission.rb`
- Test: `test/lib/services/lists/submission_test.rb`

**Interfaces:**
- Consumes: `Services::Lists::SubmissionRegistry` (Task 5), `List#skip_content_simplification` (Task 4), `List#submitted_at/#submitter_email/#submitter_ip` (Task 3).
- Produces: `Services::Lists::Submission.call(list_class:, attributes:, user: nil, submitter_email: nil, submitter_ip: nil)` → `Result` with `success?`, `data` (the saved `List`), `errors` (array of strings). On a duplicate it returns `success?: false` and `errors: [Services::Lists::Submission::DUPLICATE_MESSAGE]`. Task 8 calls it and branches on `result.errors.include?(DUPLICATE_MESSAGE)`.

**Context you need:** the `Result` pattern in this repo is `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` declared inside the service class — see `app/lib/services/corrections/submission.rb:11`. `keyword_init` is deliberate and a Standard cop is disabled for it.

Caps exist because `List` has no length validations and cannot get them: production `raw_content` reaches 1,568,804 characters from admin paste, so a model-level cap would break the wizard.

22 duplicate `(type, url)` pairs already exist in production, so this is a courtesy check, never an invariant, and there is no unique index.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/lists/submission_test.rb`:

```ruby
require "test_helper"

module Services
  module Lists
    class SubmissionTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @attributes = {name: "Greatest Books Ever", source: "The Times",
                       url: "https://example.com/greatest", description: "A list."}
      end

      test "creates an unapproved list stamped as a submission" do
        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: @user, submitter_email: nil, submitter_ip: "203.0.113.7")

        assert result.success?
        list = result.data
        assert_equal "Greatest Books Ever", list.name
        assert_equal "Books::List", list.type
        assert list.unapproved?
        assert_not_nil list.submitted_at
        assert_equal @user, list.submitted_by
        assert_equal "203.0.113.7", list.submitter_ip
      end

      test "accepts an anonymous submission with an email" do
        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: "reader@example.com", submitter_ip: "203.0.113.7")

        assert result.success?
        assert_nil result.data.submitted_by
        assert_equal "reader@example.com", result.data.submitter_email
      end

      test "ignores a submitted email when a user is signed in" do
        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: @user, submitter_email: "typed@example.com", submitter_ip: nil)

        assert result.success?
        assert_nil result.data.submitter_email
        assert_equal @user, result.data.submitted_by
      end

      test "skips content simplification" do
        result = Submission.call(
          list_class: ::Books::List,
          attributes: @attributes.merge(raw_content: "<ul><li>One</li></ul>"),
          user: nil, submitter_email: nil, submitter_ip: nil
        )

        assert result.success?
        assert_nil result.data.simplified_content
      end

      test "rejects a name over the cap" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(name: "a" * 256),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "Name"
        assert_equal 0, ::Books::List.where(source: "The Times").count
      end

      test "rejects raw content over the cap" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(raw_content: "a" * 100_001),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "too long"
      end

      test "rejects a duplicate url in any status" do
        ::Books::List.create!(name: "Already here", status: :active,
          url: "https://example.com/greatest")

        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors, Submission::DUPLICATE_MESSAGE
      end

      test "treats scheme, www and a trailing slash as the same url" do
        ::Books::List.create!(name: "Already here", status: :active,
          url: "http://www.example.com/greatest/")

        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors, Submission::DUPLICATE_MESSAGE
      end

      test "a duplicate url under a different list type is allowed" do
        ::Music::Albums::List.create!(name: "Same page, albums", status: :active,
          url: "https://example.com/greatest")

        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert result.success?
      end

      test "a blank url skips the duplicate check entirely" do
        ::Books::List.create!(name: "No url", status: :active, url: nil)

        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(url: ""),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert result.success?
      end

      test "rejects a submission with no name" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(name: ""),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "Name"
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/lib/services/lists/submission_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Services::Lists::Submission`.

- [ ] **Step 3: Write the service**

Create `app/lib/services/lists/submission.rb`:

```ruby
module Services
  module Lists
    # Turns a public submission form into an unapproved List.
    #
    # Length caps live here rather than on the model on purpose: production
    # raw_content reaches 1,568,804 characters from admin paste feeding the
    # wizard, so a model-level cap would break the admin path. Only the public
    # endpoint needs bounding.
    class Submission
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      DUPLICATE_MESSAGE = "We already have this list — thanks for checking."

      CAPS = {
        name: 255,
        source: 255,
        url: 2_000,
        description: 5_000,
        raw_content: 100_000
      }.freeze

      MAX_EMAIL_LENGTH = 255

      # Everything the public form may set. Anything else submitted is dropped
      # silently -- status, submitted_by_id and estimated_quality are not the
      # submitter's to choose. Legacy permitted every ranking-weight field while
      # its form exposed none of them.
      PERMITTED = [
        :name, :source, :url, :description, :raw_content, :year_published,
        :number_of_voters, :num_years_covered, :location_specific,
        :category_specific, :yearly_award, :voter_count_estimated,
        :voter_names_unknown, :voter_count_unknown
      ].freeze

      def self.call(list_class:, attributes:, user: nil, submitter_email: nil, submitter_ip: nil)
        new(list_class: list_class, attributes: attributes, user: user,
          submitter_email: submitter_email, submitter_ip: submitter_ip).call
      end

      def initialize(list_class:, attributes:, user:, submitter_email:, submitter_ip:)
        @list_class = list_class
        @attributes = (attributes || {}).symbolize_keys.slice(*PERMITTED)
        @user = user
        @submitter_email = submitter_email
        @submitter_ip = submitter_ip
      end

      def call
        oversized = cap_errors
        return failure(oversized) if oversized.any?
        return failure([DUPLICATE_MESSAGE]) if duplicate?

        list = build_list
        return failure(list.errors.full_messages) unless list.save

        Result.new(success?: true, data: list, errors: [])
      end

      private

      def build_list
        list = @list_class.new(@attributes)
        list.status = :unapproved
        list.submitted_at = Time.current
        list.submitted_by = @user
        # Only for anonymous submitters. A signed-in account address is verified
        # and already on file; the typed one is neither.
        list.submitter_email = @user ? nil : normalized_email
        list.submitter_ip = @submitter_ip
        list.skip_content_simplification = true
        list
      end

      # REJECTED, never truncated. Silently storing half of what someone pasted
      # is how an admin ends up importing a list that stops mid-entry, with the
      # submitter given no way to know.
      def cap_errors
        errors = CAPS.filter_map do |field, cap|
          value = @attributes[field]
          next if value.blank? || value.to_s.length <= cap

          "#{field.to_s.humanize} is too long (maximum is #{cap} characters)"
        end

        if normalized_email.present? && normalized_email.length > MAX_EMAIL_LENGTH
          errors << "Email is too long (maximum is #{MAX_EMAIL_LENGTH} characters)"
        end

        errors
      end

      def normalized_email
        @normalized_email ||= @submitter_email.to_s.strip.presence
      end

      # Scoped by type: the same page can legitimately back both an albums and a
      # songs list. Compared in Ruby against a narrowed candidate set rather than
      # in SQL so the normalisation rules live in one readable, testable place.
      #
      # This is a courtesy, never an invariant -- 22 duplicate (type, url) pairs
      # already exist, so there is no unique index and none can be added.
      def duplicate?
        target = normalize_url(@attributes[:url])
        return false if target.blank?

        @list_class
          .where(type: @list_class.name)
          .where.not(url: [nil, ""])
          .pluck(:url)
          .any? { |existing| normalize_url(existing) == target }
      end

      def normalize_url(url)
        value = url.to_s.strip.downcase
        return "" if value.blank?

        value = value.sub(%r{\Ahttps?://}, "")
        value = value.sub(/\Awww\./, "")
        value.chomp("/")
      end

      def failure(errors)
        Result.new(success?: false, data: nil, errors: errors)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/services/lists/submission_test.rb
```

Expected: PASS, 11 runs.

Note: `.pluck(:url)` over the whole type is acceptable at current scale (758 active books lists, 1,772 unapproved overall). If it ever needs narrowing, add a host prefix filter — do not move the normalisation into SQL.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb
git add app/lib/services/lists/submission.rb test/lib/services/lists/submission_test.rb
git commit -m "Add the list submission service

Caps, duplicate-URL detection and the submission stamps. Caps live here
rather than on List because admin raw_content reaches 1.5 MB and a model
cap would break the wizard."
```

### Task 7: Generalise the CSRF token endpoint

**Files:**
- Rename: `app/controllers/correction_token_controller.rb` → `app/controllers/form_token_controller.rb`
- Rename: `app/javascript/controllers/corrections/form_controller.js` → `app/javascript/controllers/shared/form_token_controller.js`
- Modify: `config/routes.rb:318`
- Modify: `app/javascript/controllers/index.js` (or the domain entrypoints that register it)
- Modify: `app/views/corrections/new.html.erb` (controller identifier)
- Test: `test/controllers/form_token_controller_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `GET /form_token` → `{csrf_token: "..."}`, and a Stimulus controller identifier `shared--form-token` that fetches it on first interaction and writes it into the form's `authenticity_token` hidden field. Task 8's form uses both.

**Context you need:** `CorrectionTokenController` already does exactly this and does no database work by design. `GET /correction_token` must keep working: corrections form pages are edge-cached for 24 hours and already-cached copies point at the old path.

Read `app/javascript/controllers/corrections/form_controller.js` fully before moving it — it also owns the honeypot and any other form behaviour, which must survive the rename.

- [ ] **Step 1: Write the failing test**

`test/controllers/correction_token_controller_test.rb` already exists with three tests, including an `assert_queries_count(0)` case that is the point of the endpoint. **Keep all three.** Rename the file and class and add the `/form_token` coverage:

```bash
git mv test/controllers/correction_token_controller_test.rb test/controllers/form_token_controller_test.rb
```

Then rewrite `test/controllers/form_token_controller_test.rb` as:

```ruby
require "test_helper"
require "active_record/testing/query_assertions"

class FormTokenControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "returns a csrf token anonymously" do
    get form_token_path, as: :json

    assert_response :success
    assert JSON.parse(response.body)["csrf_token"].present?
  end

  test "is never cached" do
    get form_token_path, as: :json

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "issues no database query" do
    assert_queries_count(0) do
      get form_token_path, as: :json
    end
  end

  # Correction form pages are edge-cached for 24 hours and already-cached copies
  # still fetch this path. Dropping it would make them fall back to null_session
  # -- which works, but silently loses attribution for signed-in submitters until
  # the cache turns over.
  test "the legacy correction_token path still works" do
    get correction_token_path, as: :json

    assert_response :success
    assert JSON.parse(response.body)["csrf_token"].present?
  end
end
```

The original used `assert ....present?` rather than `assert_not_nil`; that is kept deliberately — an empty-string token would pass `assert_not_nil`.

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/controllers/form_token_controller_test.rb
```

Expected: FAIL — `/form_token` has no route.

- [ ] **Step 3: Rename the controller**

```bash
git mv app/controllers/correction_token_controller.rb app/controllers/form_token_controller.rb
```

Rename the class inside it to `FormTokenController` and generalise its comment — it now serves every edge-cached public form, not just corrections. Change nothing else: the body is already generic (`render json: {csrf_token: form_authenticity_token}`) and its "no database work" property is load-bearing and tested.

- [ ] **Step 4: Route both paths**

In `config/routes.rb`, replace line 318:

```ruby
  # Uncached, no database query. Serves every edge-cached public form: a cached
  # page's <meta name="csrf-token"> belongs to whoever populated the cache.
  #
  # /correction_token is kept because corrections form pages are edge-cached for
  # 24 hours and already-cached copies still point at it. Removing it would make
  # those pages fall back to null_session, which works, but silently loses
  # attribution for signed-in submitters until the cache turns over.
  get "form_token", to: "form_token#show", as: :form_token
  get "correction_token", to: "form_token#show", as: :correction_token
```

- [ ] **Step 5: Move the Stimulus controller**

```bash
mkdir -p app/javascript/controllers/shared
git mv app/javascript/controllers/corrections/form_controller.js app/javascript/controllers/shared/form_token_controller.js
```

Update its registration so the identifier is `shared--form-token`, change the fetch target from `/correction_token` to `/form_token`, and update `app/views/corrections/new.html.erb` to the new `data-controller` value. Grep for the old identifier before assuming you have found every reference — this codebase writes most Stimulus bindings through the Rails hash idiom (`data: {controller: ...}`), so a search for `data-controller="..."` misses most of it:

```bash
grep -rn "corrections--form\|corrections/form_controller\|correction_token" app/ --include="*.erb" --include="*.js" --include="*.rb"
```

- [ ] **Step 6: Rebuild assets and run the tests**

```bash
yarn build:all
bin/rails test test/controllers/form_token_controller_test.rb
bin/rails test test/controllers/corrections_controller_test.rb
```

Expected: PASS in both. The corrections suite passing is what proves the rename did not break the live feature.

- [ ] **Step 7: Run the full suite, lint and commit**

```bash
bin/rails test
bundle exec standardrb
git add -A
git commit -m "Generalise the correction token endpoint to /form_token

Every edge-cached public form needs a real CSRF token; nothing about the
endpoint was correction-specific. /correction_token is kept so the
24h-cached correction pages keep their attribution."
```

### Task 8: Submission controller, routes and views (books)

**Files:**
- Create: `app/controllers/list_submissions_controller.rb`
- Create: `app/views/list_submissions/new.html.erb`, `_form.html.erb`, `thanks.html.erb`
- Modify: `config/routes.rb` — books domain block, plus the global POST
- Test: `test/controllers/list_submissions_controller_test.rb`

**Interfaces:**
- Consumes: `Services::Lists::SubmissionRegistry` (Task 5), `Services::Lists::Submission` (Task 6), `shared--form-token` (Task 7), and `AdminMailer.new_list_submission`, which Task 9 implements and this task's tests stub.
- Produces: routes `new_books_list_submission_path`, `books_list_submission_thanks_path`, `list_submissions_path`; the `@submittable_types` and `@list_class` ivars the views read.

**Context you need:** read `app/controllers/corrections_controller.rb` in full first. This controller mirrors it closely, including the reasons recorded in its comments. Key constraints:

- The form page is edge-cached, so `current_user` is **nil while it renders**. Never branch the form on sign-in state; the email field is always rendered and `#create` ignores it when a user is present.
- `with:` on a rate limit must render, never redirect — the redirect target is edge-cached, so a flash would never be read.
- Rate-limit declarations must come **after** `set_submittable_types`; `rate_limit` installs its own `before_action` and filters run in declaration order.
- A filled honeypot returns the **same** redirect as success. A 200 stops a bot retrying; a 422 brings it back.

- [ ] **Step 1: Generate the controller**

```bash
bin/rails generate controller ListSubmissions new create thanks --skip-routes --no-helper
```

- [ ] **Step 2: Write the failing test**

Replace `test/controllers/list_submissions_controller_test.rb`:

```ruby
require "test_helper"

class ListSubmissionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @user = users(:regular_user)
    @params = {
      list: {name: "Greatest Books Ever", source: "The Times",
             url: "https://example.com/greatest", description: "A list."},
      list_type: "Books::List"
    }
    # AdminMailer.new_list_submission is built in Task 9. Stubbing it here keeps
    # this task independently testable -- Mocha defines the method on the stub, so
    # these tests pass before the mailer exists and keep passing after.
    AdminMailer.stubs(:new_list_submission).returns(stub(deliver_later: true))
  end

  test "new renders the form" do
    get "/lists/new"

    assert_response :success
    assert_select "form[action=?]", "/list_submissions"
  end

  # Read the books layout's robots helper and match this assertion to the markup it
  # ACTUALLY emits before running the test -- the selector below is the expected
  # shape, not verified output. Books defaults to noindex unless @indexable is
  # truthy, so this passes on books either way; the assertion exists to pin it.
  test "new is not indexable" do
    get "/lists/new"

    assert_response :success
    assert_select "meta[name=robots][content*=?]", "noindex"
  end

  test "new does not render a type picker on books" do
    get "/lists/new"

    assert_response :success
    assert_select "input[name=list_type][type=radio]", count: 0
  end

  test "create stores an anonymous submission and redirects to thanks" do
    assert_difference "Books::List.count", 1 do
      post "/list_submissions", params: @params
    end

    assert_redirected_to "/lists/thanks"
    list = Books::List.order(:created_at).last
    assert list.unapproved?
    assert_not_nil list.submitted_at
    assert_nil list.submitted_by
  end

  test "create attributes a signed-in submission" do
    sign_in_as(@user, stub_auth: true)

    post "/list_submissions", params: @params

    assert_redirected_to "/lists/thanks"
    assert_equal @user, Books::List.order(:created_at).last.submitted_by
  end

  test "create stores an anonymous submitter email" do
    post "/list_submissions", params: @params.merge(submitter_email: "reader@example.com")

    assert_equal "reader@example.com", Books::List.order(:created_at).last.submitter_email
  end

  test "a filled honeypot is discarded but still looks like success" do
    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params.merge(website: "http://spam.example")
    end

    assert_redirected_to "/lists/thanks"
  end

  test "create re-renders the form with an error when the name is blank" do
    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params.deep_merge(list: {name: ""})
    end

    assert_response :unprocessable_entity
  end

  test "create tells the submitter when the url is already known" do
    Books::List.create!(name: "Already here", status: :active,
      url: "https://example.com/greatest")

    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params
    end

    assert_response :unprocessable_entity
    assert_match(/already have this list/i, response.body)
  end

  test "create rejects a list type the domain does not accept" do
    post "/list_submissions", params: @params.merge(list_type: "Music::Albums::List")

    assert_response :bad_request
  end

  test "create rejects an unknown list type without constantizing it" do
    post "/list_submissions", params: @params.merge(list_type: "Kernel")

    assert_response :bad_request
  end

  test "thanks renders" do
    get "/lists/thanks"

    assert_response :success
  end

  test "create notifies the owner" do
    AdminMailer.unstub(:new_list_submission)
    AdminMailer.expects(:new_list_submission).once.returns(stub(deliver_later: true))

    post "/list_submissions", params: @params
  end

  test "an anonymous submitter is rate limited" do
    Services::Lists::Submission.stubs(:call).returns(
      Services::Lists::Submission::Result.new(success?: true, data: Books::List.new, errors: [])
    )

    11.times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/#{i}"})
    end

    assert_response :too_many_requests
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rails test test/controllers/list_submissions_controller_test.rb
```

Expected: FAIL — no routes.

- [ ] **Step 4: Add the routes**

In `config/routes.rb`, inside the **books** `DomainConstraint` block, near the other `lists` routes (around line 697) but **not** inside any `scope "(/rc/:ranking_configuration_id)"`:

```ruby
    # Deliberately NOT inside the (/rc/:ranking_configuration_id) scope, and
    # constrained to html, for the same reason the corrections routes are:
    # ListSubmissionsController never calls load_ranking_configuration, so an
    # rc-prefixed or .json URL would render 200 for any value of that segment,
    # and every distinct value is another Cloudflare cache key and another full
    # render at origin. The router rejects them before a controller is involved.
    get "lists/new", to: "list_submissions#new", as: :new_books_list_submission,
      constraints: {format: /html/}
    get "lists/thanks", to: "list_submissions#thanks", as: :books_list_submission_thanks,
      constraints: {format: /html/}
```

And in the global (non-domain-constrained) section, next to `resources :corrections, only: [:create]` at line 319:

```ruby
  # One global POST for all three domains: it is never cached, and the domain
  # comes from the host through Current.domain regardless. One route means the
  # honeypot, both rate limits and the registry check are wired in one place.
  post "list_submissions", to: "list_submissions#create", as: :list_submissions
```

- [ ] **Step 5: Write the controller**

Replace `app/controllers/list_submissions_controller.rb`:

```ruby
# Public list submission, for every domain. Modelled on CorrectionsController --
# read that one alongside this; the reasoning recorded in its comments applies
# here almost line for line.
class ListSubmissionsController < ApplicationController
  include Cacheable
  include VisitorIp

  layout :domain_layout

  # The form page is edge-cached, so its <meta name="csrf-token"> belongs to
  # whoever populated the cache. The Stimulus controller fetches a real token from
  # /form_token on first interaction -- but if that fetch never happened (JS off,
  # blocked, slow), null_session accepts the write as ANONYMOUS rather than
  # showing the submitter a 422 they cannot act on.
  #
  # CSRF exists to stop a forged request riding a victim's ambient session
  # authority; null_session removes exactly that authority. What lands is a
  # submission the attacker could have posted directly, and it is moderated
  # before it is visible anywhere.
  protect_from_forgery with: :null_session, only: [:create]

  before_action :set_submittable_types
  before_action :set_list_class, only: [:create]
  before_action :cache_for_show_page, only: [:new, :thanks]
  before_action :prevent_caching, only: [:create]

  # Two buckets, sized from the legacy corpus rather than guessed. One
  # contributor submitted 25 lists in a single day and 8 separate days exceeded
  # 5, so a flat low cap would reject exactly the people who made this feature
  # worth porting -- 152 of their 209 submissions are live on the site today.
  #
  # Anonymous submitters share an IP bucket and cannot be identified, so they get
  # a tighter cap. Nothing an anonymous flood produces is published; it costs
  # triage time.
  #
  # by: goes through visitor_ip, NEVER request.remote_ip -- in production that is
  # the Cloudflare edge IP, so keying on it puts every visitor in one bucket and
  # throttles the whole site.
  #
  # with: renders rather than redirects: the redirect target is edge-cached, so a
  # flash set there is never read. Rails' default raise renders an HTML error body.
  #
  # Declared AFTER set_submittable_types, and that ordering is load-bearing:
  # filters run in declaration order and rate_limit installs its own
  # before_action, so @submittable_types is set when the with: lambda re-renders.
  SIGNED_IN_RATE = 30
  ANONYMOUS_RATE = 10
  RATE_WINDOW = 1.hour

  rate_limit to: SIGNED_IN_RATE, within: RATE_WINDOW,
    by: -> { current_user.id },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "list-submissions-create-signed-in",
    only: [:create],
    if: -> { current_user.present? }

  rate_limit to: ANONYMOUS_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "list-submissions-create-anonymous",
    only: [:create],
    unless: -> { current_user.present? }

  def new
    @indexable = false
    @list = List.new
  end

  def create
    # Same destination as a real success: a bot redirected somewhere else has
    # learned its submission was discarded.
    return redirect_to(thanks_path) if honeypot_filled?

    result = Services::Lists::Submission.call(
      list_class: @list_class,
      attributes: list_params.to_h,
      user: current_user,
      submitter_email: params[:submitter_email],
      submitter_ip: visitor_ip
    )

    if result.success?
      # deliver_later, not deliver_now: legacy built and sent this inline in the
      # request, blocking the submitter on SendGrid with no retry.
      AdminMailer.new_list_submission(result.data).deliver_later
      redirect_to thanks_path
    else
      @indexable = false
      @list = @list_class.new(list_params)
      @error = result.errors.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  # Cacheable GET, reached only via the redirect from #create. Exists so the
  # confirmation can be shown without a flash -- public layouts render none.
  def thanks
    @indexable = false
  end

  private

  def set_submittable_types
    @submittable_types = Services::Lists::SubmissionRegistry.types_for(Current.domain)
    raise ActionController::BadRequest, "No submittable list types" if @submittable_types.empty?
  end

  def set_list_class
    # Never constantize. A single-type domain does not need the param at all.
    @list_class =
      if @submittable_types.one?
        @submittable_types.first
      else
        Services::Lists::SubmissionRegistry.resolve(Current.domain, params[:list_type])
      end

    raise ActionController::BadRequest, "Unknown list type" if @list_class.nil?
  end

  # A bot fills every input it finds.
  def honeypot_filled?
    params[:website].present?
  end

  def list_params
    # ActionController::Parameters.new, not {} -- Hash has no #permit, so a POST
    # with no list key at all would 500 instead of returning a validation error.
    params.fetch(:list, ActionController::Parameters.new)
      .permit(*Services::Lists::Submission::PERMITTED)
  end

  def render_rate_limited
    @indexable = false
    @list = List.new
    @error = "Thanks — you've sent us several lists just now. Please try again shortly."
    render :new, status: :too_many_requests
  end

  # Four sites share one route file, so each domain names its own helpers.
  # fetch, not []: a domain with no thanks path is a wiring mistake that should
  # raise in that domain's own tests, not produce a nil redirect in production.
  THANKS_PATHS = {
    books: :books_list_submission_thanks_path,
    music: :music_list_submission_thanks_path,
    games: :games_list_submission_thanks_path
  }.freeze

  def thanks_path
    public_send(THANKS_PATHS.fetch(Current.domain))
  end
  helper_method :thanks_path

  def domain_layout
    "#{Current.domain}/application"
  end
end
```

Note: `THANKS_PATHS` names music and games helpers that Task 11/12 create. Until then, only the books key resolves — which is exactly what this task's tests exercise.

- [ ] **Step 6: Write the views**

`app/views/list_submissions/new.html.erb`:

```erb
<% content_for :page_title, "Submit a List | #{domain_settings[:name]}" %>
<% content_for :meta_description, "Submit a list for review and help us expand our rankings." %>

<div class="container mx-auto px-4 py-8 max-w-4xl">
  <div class="mb-8">
    <h1 class="text-4xl font-bold text-base-content mb-2">Submit a List</h1>
    <p class="text-base-content/70">
      Know a great list we're missing? Send it over and we'll review it. We especially
      welcome lists covering under-represented countries, genres and perspectives.
    </p>
  </div>

  <%= render "form" %>
</div>
```

`app/views/list_submissions/_form.html.erb`:

```erb
<%= form_with url: list_submissions_path, method: :post,
      data: {controller: "shared--form-token", action: "focusin->shared--form-token#fetch input->shared--form-token#fetch"},
      class: "space-y-6" do |f| %>

  <% if @error.present? %>
    <div class="alert alert-error" role="alert">
      <span><%= @error %></span>
    </div>
  <% end %>

  <%# Honeypot. Hidden from people, irresistible to bots. Not type="hidden" --
      bots skip those; this is a real input positioned out of view. %>
  <div class="absolute left-[-9999px]" aria-hidden="true">
    <label for="website">Website</label>
    <input type="text" name="website" id="website" tabindex="-1" autocomplete="off">
  </div>

  <% if @submittable_types.many? %>
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">List Type</h2>
        <div class="flex flex-col sm:flex-row gap-4">
          <% @submittable_types.each_with_index do |type, index| %>
            <label class="label cursor-pointer justify-start gap-3 flex-1 p-4 border border-base-300 rounded-lg hover:border-primary has-[:checked]:border-primary has-[:checked]:bg-primary/5">
              <%= radio_button_tag :list_type, type.name, index.zero?, class: "radio radio-primary" %>
              <span class="font-semibold"><%= Services::Lists::SubmissionRegistry.label_for(type) %></span>
            </label>
          <% end %>
        </div>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">About the list</h2>

      <%# Every input carries an explicit aria-label matching its legend. daisyUI 5's
          fieldset/fieldset-legend pattern is visual only -- a <legend> does not label
          the input the way <label for> does, so without this a screen reader
          announces an unlabelled field and Playwright's getByLabel finds nothing. %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend">List name <span class="text-error">*</span></legend>
        <%= f.text_field "list[name]", value: @list.name, required: true, autofocus: true,
              class: "input w-full", "aria-label": "List name",
              placeholder: "e.g. Rolling Stone's 500 Greatest Albums" %>
        <p class="label">The official name of the list.</p>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Source or publication</legend>
        <%= f.text_field "list[source]", value: @list.source, class: "input w-full",
              "aria-label": "Source or publication",
              placeholder: "e.g. Rolling Stone, NME, Pitchfork" %>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Link to the list</legend>
        <%= f.url_field "list[url]", value: @list.url, class: "input w-full",
              "aria-label": "Link to the list",
              placeholder: "https://example.com/best-albums" %>
        <p class="label">Leave blank if it isn't online.</p>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Description</legend>
        <%= f.text_area "list[description]", value: @list.description, rows: 4,
              class: "textarea w-full", "aria-label": "Description",
              placeholder: "What makes this list notable? How was it compiled?" %>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Paste the list</legend>
        <%= f.text_area "list[raw_content]", value: @list.raw_content, rows: 12,
              class: "textarea w-full font-mono text-sm", "aria-label": "Paste the list",
              placeholder: "1. Marvin Gaye - What's Going On\n2. The Beach Boys - Pet Sounds\n..." %>
        <p class="label">Optional, but it gets your list added much faster. One entry per line.</p>
      </fieldset>

      <%# Always rendered, for everyone. This page is edge-cached with the session
          skipped, so current_user is nil while it renders and the HTML is identical
          for every visitor. A conditional here would bake one visitor's state into
          the copy served to everyone else. #create ignores this when someone is
          signed in. %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend">Your email</legend>
        <%= email_field_tag :submitter_email, nil, class: "input w-full",
              "aria-label": "Your email", placeholder: "you@example.com" %>
        <p class="label">Optional. Only used if we need to ask you about the list. If you're signed in we'll use your account email.</p>
      </fieldset>
    </div>
  </div>

  <details class="card bg-base-100 shadow-xl">
    <summary class="card-body cursor-pointer font-semibold">More detail (optional)</summary>
    <div class="card-body pt-0">
      <p class="text-sm text-base-content/70">
        Only if you know them — we'll work the rest out during review.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Year published</legend>
          <%= f.number_field "list[year_published]", value: @list.year_published,
                class: "input w-full", "aria-label": "Year published",
                min: 1900, max: Date.current.year + 1 %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Number of voters</legend>
          <%= f.number_field "list[number_of_voters]", value: @list.number_of_voters,
                class: "input w-full", "aria-label": "Number of voters", min: 1 %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Years covered</legend>
          <%= f.number_field "list[num_years_covered]", value: @list.num_years_covered,
                class: "input w-full", "aria-label": "Years covered", min: 1 %>
        </fieldset>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-2 mt-4">
        <% {
             location_specific: "Focuses on one country or region",
             category_specific: "Focuses on one genre or style",
             yearly_award: "An annual award that recurs each year",
             voter_count_estimated: "The voter count is an estimate",
             voter_names_unknown: "The voters are anonymous",
             voter_count_unknown: "The number of voters is unknown"
           }.each do |field, description| %>
          <label class="label cursor-pointer justify-start gap-3 items-start p-3 border border-base-300 rounded-lg">
            <%= f.check_box "list[#{field}]", checked: @list.public_send(field),
                  class: "checkbox checkbox-primary shrink-0 mt-0.5" %>
            <span class="text-sm"><%= description %></span>
          </label>
        <% end %>
      </div>
    </div>
  </details>

  <div class="flex justify-end">
    <%= f.submit "Submit list", class: "btn btn-primary" %>
  </div>
<% end %>
```

`app/views/list_submissions/thanks.html.erb`:

```erb
<% content_for :page_title, "Thanks | #{domain_settings[:name]}" %>

<div class="container mx-auto px-4 py-16 max-w-2xl text-center">
  <h1 class="text-4xl font-bold text-base-content mb-4">Thanks — we've got it</h1>
  <p class="text-base-content/70 mb-8">
    Your list is in the review queue. If we add it, it'll show up on the lists page.
    We read every submission, but we can't reply to all of them.
  </p>
  <%= link_to "Back to all lists", books_lists_path, class: "btn btn-primary" %>
</div>
```

Note: the thanks page hardcodes `books_lists_path`. Task 11/12 replace that with a per-domain lookup when games and music arrive.

- [ ] **Step 7: Run the tests**

```bash
yarn build:all
bin/rails test test/controllers/list_submissions_controller_test.rb
```

Expected: PASS, 14 runs. `AdminMailer.new_list_submission` is stubbed in `setup`, so this task does not depend on Task 9 being done first.

- [ ] **Step 8: Check for trapped links and daisyUI regressions**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS. If it fails, the fix is to remove the offending class, never to add an allowlist entry.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "Add the shared public list submission form, wired to books

Edge-cached form, honeypot, two rate-limit buckets, registry-validated
list type, and a thanks page rather than a flash public layouts do not
render."
```

### Task 9: Admin notification email

**Files:**
- Modify: `app/mailers/admin_mailer.rb`
- Create: `app/views/admin_mailer/new_list_submission.html.erb`, `new_list_submission.text.erb`
- Test: `test/mailers/admin_mailer_test.rb`

**Interfaces:**
- Consumes: `List#submitted_by`, `#submitter_email` (Task 3).
- Produces: `AdminMailer.new_list_submission(list)`, called by Task 8's `#create`.

**Context you need:** read `AdminMailer#new_correction` (`app/mailers/admin_mailer.rb:52`) — this is a near-copy. Subclasses call `branded_mail(domain:, ...)`, **never** `mail`; the domain must be passed explicitly because mailers run in Sidekiq where `Current.domain` is nil. The recipient is `ENV["ADMIN_NOTIFICATION_EMAIL"]`, and `admin_address` raises `MissingAdminAddress` when unset.

Any `_url` helper must be called **from the view**, not eagerly in the mailer method — `branded_mail` sets `default_url_options` immediately before it calls `mail`, so calling one earlier raises "Missing host to link to!" in dev/test and silently links to the books host in production. Both `.html.erb` and `.text.erb` are always provided.

- [ ] **Step 1: Write the failing test**

Append to `test/mailers/admin_mailer_test.rb`:

```ruby
test "new_list_submission is addressed to the admin and names the list" do
  list = Books::List.create!(name: "Greatest Books Ever", status: :unapproved,
    submitted_at: Time.current, url: "https://example.com/greatest")

  mail = AdminMailer.new_list_submission(list)

  assert_equal [ENV["ADMIN_NOTIFICATION_EMAIL"]], mail.to
  assert_match "Greatest Books Ever", mail.subject
  assert_match "Greatest Books Ever", mail.body.encoded
end

test "new_list_submission replies to a signed-in submitter" do
  user = users(:regular_user)
  list = Books::List.create!(name: "With account", status: :unapproved,
    submitted_at: Time.current, submitted_by: user)

  mail = AdminMailer.new_list_submission(list)

  assert_equal [user.email], mail.reply_to
end

test "new_list_submission replies to an anonymous submitted email" do
  list = Books::List.create!(name: "Anon with email", status: :unapproved,
    submitted_at: Time.current, submitter_email: "reader@example.com")

  mail = AdminMailer.new_list_submission(list)

  assert_equal ["reader@example.com"], mail.reply_to
end

test "new_list_submission has no reply_to for a fully anonymous submission" do
  list = Books::List.create!(name: "Fully anon", status: :unapproved,
    submitted_at: Time.current)

  mail = AdminMailer.new_list_submission(list)

  assert_nil mail.reply_to
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/mailers/admin_mailer_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'new_list_submission'`.

- [ ] **Step 3: Add the mailer action**

In `app/mailers/admin_mailer.rb`, after `new_correction`:

```ruby
  def new_list_submission(list)
    @list = list
    # domain_for, not Current.domain: this runs in Sidekiq, where Current.domain
    # is nil and the branding would silently fall back to books.
    domain = Services::Lists::SubmissionRegistry.domain_for(list.class)
    @site_name = MailBranding.for(domain).site_name

    branded_mail(
      domain: domain,
      to: admin_address,
      subject: "New list submission on #{@site_name}: #{list.name}",
      # Account address first: it is verified and already on file. The typed one
      # is neither, but it is better than no reply channel at all.
      reply_to: list.submitted_by&.email || list.submitter_email.presence
    )
  end
```

- [ ] **Step 4: Write both mailer views**

`app/views/admin_mailer/new_list_submission.text.erb`:

```erb
A new list has been submitted to <%= @site_name %>.

Name: <%= @list.name %>
Type: <%= @list.type %>
Source: <%= @list.source.presence || "(not given)" %>
URL: <%= @list.url.presence || "(not given)" %>
Submitted by: <%= @list.submitted_by&.email || @list.submitter_email.presence || "Anonymous" %>
Pasted content: <%= @list.raw_content.present? ? "#{@list.raw_content.length} characters" : "none" %>

Description:
<%= @list.description.presence || "(none)" %>
```

`app/views/admin_mailer/new_list_submission.html.erb`:

```erb
<h1>New list submission on <%= @site_name %></h1>

<table>
  <tr><td><strong>Name</strong></td><td><%= @list.name %></td></tr>
  <tr><td><strong>Type</strong></td><td><%= @list.type %></td></tr>
  <tr><td><strong>Source</strong></td><td><%= @list.source.presence || "(not given)" %></td></tr>
  <tr>
    <td><strong>URL</strong></td>
    <td>
      <% if @list.url.present? %>
        <%= link_to @list.url, @list.url, rel: "noopener nofollow" %>
      <% else %>
        (not given)
      <% end %>
    </td>
  </tr>
  <tr>
    <td><strong>Submitted by</strong></td>
    <td><%= @list.submitted_by&.email || @list.submitter_email.presence || "Anonymous" %></td>
  </tr>
  <tr>
    <td><strong>Pasted content</strong></td>
    <td><%= @list.raw_content.present? ? "#{@list.raw_content.length} characters" : "none" %></td>
  </tr>
</table>

<% if @list.description.present? %>
  <h2>Description</h2>
  <p><%= @list.description %></p>
<% end %>
```

`rel="noopener nofollow"` on a submitter-supplied URL even in email — it is untrusted input.

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/mailers/admin_mailer_test.rb
bin/rails test test/controllers/list_submissions_controller_test.rb
```

Expected: PASS in both. Remove any temporary stub added in Task 8.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "Notify the owner on a new list submission

deliver_later, unlike legacy, which built and sent this inline in the
request with no retry."
```

### Task 10: Books entry point

**Files:**
- Modify: `app/views/books/lists/index.html.erb`
- Test: `test/controllers/books/lists_controller_test.rb`

**Interfaces:**
- Consumes: `new_books_list_submission_path` (Task 8).
- Produces: nothing later tasks depend on.

**Context you need:** `app/views/music/lists/index.html.erb:12` already links to `new_music_list_path` and is the precedent. Check whether the surrounding markup sits inside a `turbo_frame_tag` — if it does, the link needs `data: {turbo_frame: "_top"}` or it will render "Content missing".

- [ ] **Step 1: Write the failing test**

Append to `test/controllers/books/lists_controller_test.rb`:

```ruby
test "index links to the submission form" do
  get "/lists"

  assert_response :success
  assert_select "a[href=?]", "/lists/new"
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb
```

Expected: FAIL — no matching element.

- [ ] **Step 3: Add the link**

In `app/views/books/lists/index.html.erb`, in the header area near the existing sort links:

```erb
<%= link_to "Submit a list", new_books_list_submission_path, class: "btn btn-primary btn-sm" %>
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb
```

Expected: PASS. If `assert_no_frame_trapped_links` now fails, add `data: {turbo_frame: "_top"}` to the link.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "Link the books lists page to the submission form"
```

---

# Increment 3 — Games and music

### Task 11: Wire games

**Files:**
- Modify: `config/routes.rb` — games domain block (around line 1038)
- Modify: `app/views/games/lists/index.html.erb`
- Modify: `app/controllers/list_submissions_controller.rb` — `THANKS_PATHS` already has the key
- Modify: `app/views/list_submissions/thanks.html.erb` — per-domain back link
- Test: `test/controllers/list_submissions_controller_test.rb`

**Interfaces:**
- Consumes: everything from Increment 2.
- Produces: `new_games_list_submission_path`, `games_list_submission_thanks_path`.

**Context you need:** `get "lists/:id", to: "games/lists#show"` at line 1040 has **no id constraint**, so `/lists/new` would resolve to `show` with `id: "new"`. Books constrains its equivalent to `/\d+/`. This is a latent bug independent of this feature.

- [ ] **Step 1: Write the failing test**

Append to `test/controllers/list_submissions_controller_test.rb`:

```ruby
test "games renders the form without a type picker" do
  host! "dev.thegreatest.games"

  get "/lists/new"

  assert_response :success
  assert_select "input[name=list_type][type=radio]", count: 0
end

test "games creates a games list" do
  host! "dev.thegreatest.games"

  assert_difference "Games::List.count", 1 do
    post "/list_submissions", params: {
      list: {name: "Greatest Games", url: "https://example.com/games"},
      list_type: "Games::List"
    }
  end

  assert_redirected_to "/lists/thanks"
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/controllers/list_submissions_controller_test.rb
```

Expected: FAIL — `/lists/new` on games routes to `games/lists#show`.

- [ ] **Step 3: Constrain the games show route and add the submission routes**

In `config/routes.rb`, change line 1040:

```ruby
      get "lists/:id", to: "games/lists#show", as: :games_list, constraints: {id: /\d+/}
```

and line 1041 the same way (add `id: /\d+/` alongside the existing `page` constraint). Then add **above** those lines:

```ruby
      get "lists/new", to: "list_submissions#new", as: :new_games_list_submission,
        constraints: {format: /html/}
      get "lists/thanks", to: "list_submissions#thanks", as: :games_list_submission_thanks,
        constraints: {format: /html/}
```

- [ ] **Step 4: Make the thanks back-link per-domain**

In `app/controllers/list_submissions_controller.rb`, add beside `THANKS_PATHS`:

```ruby
  LISTS_PATHS = {
    books: :books_lists_path,
    music: :music_lists_path,
    games: :games_lists_path
  }.freeze

  def domain_lists_path
    public_send(LISTS_PATHS.fetch(Current.domain))
  end
  helper_method :domain_lists_path
```

and in `app/views/list_submissions/thanks.html.erb` replace `books_lists_path` with `domain_lists_path`.

- [ ] **Step 5: Add the games entry point**

In `app/views/games/lists/index.html.erb`, mirroring Task 10:

```erb
<%= link_to "Submit a list", new_games_list_submission_path, class: "btn btn-primary btn-sm" %>
```

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/controllers/list_submissions_controller_test.rb
bin/rails test test/controllers/games/lists_controller_test.rb
```

Expected: PASS in both. The games lists suite passing proves the id constraint did not break existing show routing.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "Wire games to the shared list submission form

Also constrains games' lists/:id to digits -- without it /lists/new
resolved to show with id 'new'."
```

### Task 12: Wire music and delete the old implementation

**Files:**
- Modify: `config/routes.rb:11` — `resources :lists, only: [:index]`, plus the two new GETs
- Modify: `app/controllers/music/lists_controller.rb` — delete `new`, `create`, `list_class_from_type`, `list_params`
- Delete: `app/views/music/lists/new.html.erb`, `app/views/music/lists/_form.html.erb`
- Modify: `test/controllers/music/lists_controller_test.rb` — delete the submission tests
- Modify: `app/views/music/lists/index.html.erb` — point the existing button at the new route
- Test: `test/controllers/list_submissions_controller_test.rb`

**Interfaces:**
- Consumes: everything from Increment 2.
- Produces: `new_music_list_submission_path`, `music_list_submission_thanks_path`. Removes `new_music_list_path` and the `POST /lists` music route.

**Context you need:** music is the only domain with two submittable types, so it is the only one that renders the picker. The existing `Music::ListsController#create` redirects with a `notice:` to an edge-cached page — a message no one has ever seen. Its test asserts on `flash[:notice]` and passes; delete that test rather than porting it.

- [ ] **Step 1: Write the failing test**

Append to `test/controllers/list_submissions_controller_test.rb`:

```ruby
test "music renders a type picker with both list types" do
  host! "dev.thegreatestmusic.org"

  get "/lists/new"

  assert_response :success
  assert_select "input[name=list_type][value=?]", "Music::Albums::List"
  assert_select "input[name=list_type][value=?]", "Music::Songs::List"
end

test "music creates an album list when albums is chosen" do
  host! "dev.thegreatestmusic.org"

  assert_difference "Music::Albums::List.count", 1 do
    post "/list_submissions", params: {
      list: {name: "Greatest Albums", url: "https://example.com/albums"},
      list_type: "Music::Albums::List"
    }
  end

  assert_redirected_to "/lists/thanks"
end

test "music creates a song list when songs is chosen" do
  host! "dev.thegreatestmusic.org"

  assert_difference "Music::Songs::List.count", 1 do
    post "/list_submissions", params: {
      list: {name: "Greatest Songs", url: "https://example.com/songs"},
      list_type: "Music::Songs::List"
    }
  end

  assert_redirected_to "/lists/thanks"
end

test "music rejects a submission with no type chosen" do
  host! "dev.thegreatestmusic.org"

  post "/list_submissions", params: {list: {name: "No type"}}

  assert_response :bad_request
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/controllers/list_submissions_controller_test.rb
```

Expected: FAIL — `/lists/new` on music still routes to `Music::ListsController#new`.

- [ ] **Step 3: Change the music routes**

In `config/routes.rb`, replace line 11:

```ruby
      resources :lists, only: [:index], controller: "music/lists"
      get "lists/new", to: "list_submissions#new", as: :new_music_list_submission,
        constraints: {format: /html/}
      get "lists/thanks", to: "list_submissions#thanks", as: :music_list_submission_thanks,
        constraints: {format: /html/}
```

- [ ] **Step 4: Strip the old controller**

In `app/controllers/music/lists_controller.rb`, delete `#new`, `#create`, `#list_class_from_type` and `#list_params`. What remains is `#index` plus `load_ranking_configurations`.

```bash
git rm app/views/music/lists/new.html.erb app/views/music/lists/_form.html.erb
```

- [ ] **Step 5: Delete the superseded tests**

In `test/controllers/music/lists_controller_test.rb`, delete every test covering `new` and `create` — including the one asserting on `flash[:notice]`, which passes while testing a message no visitor can see. Keep the `index` tests.

- [ ] **Step 6: Repoint the music entry point**

In `app/views/music/lists/index.html.erb:12`, change `new_music_list_path` to `new_music_list_submission_path`.

- [ ] **Step 7: Run the tests**

```bash
yarn build:all
bin/rails test test/controllers/list_submissions_controller_test.rb
bin/rails test test/controllers/music/lists_controller_test.rb
```

Expected: PASS in both.

- [ ] **Step 8: Run the full suite, lint and commit**

```bash
bin/rails test
bundle exec standardrb
git add -A
git commit -m "Move music onto the shared list submission form

Deletes Music::ListsController#new/#create, its 291-line form and the
test asserting on a flash notice that an edge-cached public layout has
never rendered."
```

---

# Increment 4 — Admin

### Task 13: User-submitted filter and submitter column

**Files:**
- Modify: `app/controllers/admin/lists_base_controller.rb`
- Modify: `app/components/admin/lists/index_component.html.erb`
- Modify: `app/components/admin/lists/table_component.html.erb`
- Modify: `app/components/admin/lists/show_component.html.erb:121-126`
- Test: `test/controllers/admin/books/lists_controller_test.rb`

**Interfaces:**
- Consumes: `List#submitted_at`, `#submitter_email` (Task 3).
- Produces: nothing later tasks depend on.

**Context you need:** `Admin::ListsBaseController#apply_status_filter` (line 82) is the pattern to copy:

```ruby
def apply_status_filter(scope)
  return scope if params[:status].blank? || params[:status] == "all"
  status_value = params[:status].to_s.downcase
  return scope unless List.statuses.key?(status_value)
  scope.where(status: status_value)
end
```

`index` and `show` already `.includes(:submitted_by)`. The index component renders the status `<select>` at `index_component.html.erb:31-41`. The show component already renders `submitted_by.email` at line 121-126.

This filter matters because filtering by "Unapproved" alone returns 1,772 rows, of which 1,721 are import backlog with no submitter.

- [ ] **Step 1: Write the failing test**

Append to `test/controllers/admin/books/lists_controller_test.rb`, following the sign-in pattern already used in that file:

```ruby
test "index filters to user submitted lists" do
  submitted = Books::List.create!(name: "From a reader", status: :unapproved,
    submitted_at: Time.current, submitter_email: "reader@example.com")
  admin_made = Books::List.create!(name: "From an import", status: :unapproved)

  get admin_books_lists_path(submitted: "submitted")

  assert_response :success
  assert_match submitted.name, response.body
  assert_no_match admin_made.name, response.body
end

test "index filters to admin created lists" do
  submitted = Books::List.create!(name: "From a reader", status: :unapproved,
    submitted_at: Time.current)
  admin_made = Books::List.create!(name: "From an import", status: :unapproved)

  get admin_books_lists_path(submitted: "admin")

  assert_response :success
  assert_match admin_made.name, response.body
  assert_no_match submitted.name, response.body
end

test "index shows every list when the submitted filter is absent" do
  submitted = Books::List.create!(name: "From a reader", status: :unapproved,
    submitted_at: Time.current)
  admin_made = Books::List.create!(name: "From an import", status: :unapproved)

  get admin_books_lists_path

  assert_response :success
  assert_match submitted.name, response.body
  assert_match admin_made.name, response.body
end

test "index shows the submitter for an anonymous submission" do
  Books::List.create!(name: "Anon list", status: :unapproved, submitted_at: Time.current)

  get admin_books_lists_path(submitted: "submitted")

  assert_response :success
  assert_match "Anonymous", response.body
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/controllers/admin/books/lists_controller_test.rb
```

Expected: FAIL — the filter is ignored, so both names appear.

- [ ] **Step 3: Add the filter**

In `app/controllers/admin/lists_base_controller.rb`, add beside `apply_status_filter` and call it from `index` in the same chain:

```ruby
  # "Unapproved" alone is not a submission queue: 1,721 of 1,772 unapproved lists
  # are import backlog with no submitter. submitted_at is set only by the public
  # form, so it is the marker that separates the two.
  def apply_submitted_filter(scope)
    case params[:submitted]
    when "submitted" then scope.where.not(submitted_at: nil)
    when "admin" then scope.where(submitted_at: nil)
    else scope
    end
  end
```

- [ ] **Step 4: Add the dropdown**

In `app/components/admin/lists/index_component.html.erb`, after the status `<select>`:

```erb
          <%= f.select :submitted,
              options_for_select([
                ["All sources", ""],
                ["User submitted", "submitted"],
                ["Added by admin", "admin"]
              ], selected_submitted),
              {},
              class: "select",
              onchange: "this.form.requestSubmit()" %>
```

Wire the reader through the component the same way `selected_status` already is. In `app/components/admin/lists/index_component.rb`, add `selected_submitted` to the `initialize` keyword list, assign it to an ivar, and expose it with the other `attr_reader`s:

```ruby
  def initialize(lists:, pagy:, domain_config:, search_query: nil, selected_status: nil, selected_submitted: nil)
    @lists = lists
    @pagy = pagy
    @domain_config = domain_config
    @search_query = search_query
    @selected_status = selected_status
    @selected_submitted = selected_submitted
  end

  private

  attr_reader :lists, :pagy, :domain_config, :search_query, :selected_status, :selected_submitted
```

Keep the existing parameter names and order exactly as the file already has them — the snippet above shows the shape, not a replacement for what is there. Then pass `selected_submitted: params[:submitted]` from wherever `Admin::ListsBaseController` renders `Admin::Lists::IndexComponent`, beside the existing `selected_status:`.

- [ ] **Step 5: Add the submitter column**

In `app/components/admin/lists/table_component.html.erb`, add a header cell "Submitted by" and a matching body cell:

```erb
<td>
  <% if list.submitted_at.present? %>
    <%= list.submitted_by&.email || list.submitter_email.presence || "Anonymous" %>
  <% else %>
    <span class="text-base-content/50">—</span>
  <% end %>
</td>
```

In `app/components/admin/lists/show_component.html.erb`, extend the existing block at line 121-126 to fall back to `submitter_email` and then "Anonymous" when `submitted_at` is present.

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/controllers/admin/books/lists_controller_test.rb
```

Expected: PASS. Then confirm no N+1 was introduced — `index` already `.includes(:submitted_by)`, and the new column reads only that association plus two columns.

- [ ] **Step 7: Run the full suite, lint and commit**

```bash
bin/rails test
bundle exec standardrb
git add -A
git commit -m "Filter the admin lists page by submission source

Filtering by Unapproved alone returns 1,772 rows, 1,721 of them import
backlog with no submitter."
```

---

# Increment 5 — Finish

### Task 14: robots.txt, E2E and documentation

**Files:**
- Modify: `public/robots.txt`
- Create: `e2e/tests/books/list-submission.spec.ts`
- Create: `docs/features/list-submissions.md`
- Modify: `docs/todo.md` — tick "add new lists page"

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

**Context you need:** `public/robots.txt` already carries `Disallow: /*/suggest-correction` (line 24) with an explanatory comment above it. E2E tests need a local dev server and `e2e/.env`; check port 3000 is yours before running, since Caddy proxies every dev hostname to it regardless of which worktree is listening.

- [ ] **Step 1: Add the robots rules**

Append to `public/robots.txt`, with a comment matching the style of the existing block:

```
# The list submission form and its confirmation page. Both are edge-cached and
# set @indexable = false, but the books layout is opt-in for robots meta while
# music and games are opt-out, so this is the belt to that braces.
Disallow: /lists/new
Disallow: /lists/thanks
```

- [ ] **Step 2: Write the E2E test**

Create `e2e/tests/books/list-submission.spec.ts`, following the structure of an existing spec in `e2e/tests/books/`:

```typescript
import { test, expect } from "@playwright/test";

test.describe("book list submission", () => {
  test("an anonymous visitor can submit a list", async ({ page }) => {
    await page.goto("/lists");
    await page.getByRole("link", { name: "Submit a list" }).click();

    await expect(page).toHaveURL(/\/lists\/new$/);

    const name = `E2E Test List ${Date.now()}`;
    await page.getByLabel("List name").fill(name);
    await page.getByLabel("Source or publication").fill("Playwright");
    await page.getByLabel("Link to the list").fill(`https://example.com/${Date.now()}`);

    await page.getByRole("button", { name: "Submit list" }).click();

    await expect(page).toHaveURL(/\/lists\/thanks$/);
    await expect(page.getByRole("heading", { name: /Thanks/ })).toBeVisible();
  });

  test("the optional detail section is collapsed by default", async ({ page }) => {
    await page.goto("/lists/new");

    await expect(page.getByLabel("Number of voters")).toBeHidden();
    await page.getByText("More detail (optional)").click();
    await expect(page.getByLabel("Number of voters")).toBeVisible();
  });
});
```

- [ ] **Step 3: Confirm port 3000 is yours, then run the E2E suite**

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If the path printed is not this worktree, stop that server first — otherwise Playwright tests another worktree's code and reports the result as yours. Then:

```bash
yarn build:all
bin/rails server &
yarn test:e2e
```

Expected: both new specs pass.

- [ ] **Step 4: Write the feature documentation**

Create `docs/features/list-submissions.md` covering: the entry points per domain, the registry and why a submitted type never reaches `constantize`, the two rate-limit buckets and the data that sized them, the honeypot and null_session layering, why the form is edge-cached and what the Cloudflare cache rule would add, the caps and where they live, the duplicate check, and how an admin finds and processes a submission. Do **not** write class-level docs — code is the source of truth in this repo.

- [ ] **Step 5: Final verification**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: full suite green with no new warning lines, clean lint, `All is good!`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Document list submissions, add robots rules and E2E coverage"
```

---

## Deploy notes

These are **not** code changes. Record them on the PR.

1. **`Music::Albums::List #10093`** ("500 CDs You Must Own Before You Die") is `approved`, not `active`, and has a weighted `RankedList`. After Increment 1 deploys it will 404. Set it to `active` — it is plainly meant to be live. The only other two `RankedList` rows on non-active lists are `Books::List` #789 and #886, which already 404 today.
2. **`ADMIN_NOTIFICATION_EMAIL`** must be set, or `AdminMailer` raises `MissingAdminAddress`. It is already required by the corrections and membership mailers, so it is almost certainly set — confirm rather than assume.
3. **Optional Cloudflare Cache Rule:** ignore query strings on `/lists/new` for all three hostnames. Without it the edge-caching of the form buys much less, since `?x=1`, `?x=2` … are distinct cache keys. Lower priority than the corrections rule — that form is linked from 156k book pages, this one from three list index pages.
4. **The migration backfills** `submitted_at` from `created_at` where `submitted_by_id IS NOT NULL`. This is a no-op in production (all 209 such rows are `Books::List`, and books data exists only in development). A failing migration is an outage — `docker-entrypoint` migrates before exec'ing the server — but this one only adds nullable columns and runs one indexed UPDATE.
