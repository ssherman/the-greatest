# Descriptions (c2) — Admin Panel & Form Stripping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give admins a panel to view, create, edit, delete and select descriptions, and remove the now-dead description textarea from nine admin forms.

**Architecture:** `Admin::DescriptionsController` mirrors the existing `Admin::ImagesController` — one global controller, `index`/`create` nested per parent, `update`/`destroy`/`set_preferred` global, a lazily-loaded `turbo_frame_tag "descriptions_list"`, turbo-stream responses, `Admin::DomainScopedAuth` + `require_domain_write!`. `set_preferred` demotes the incumbent then promotes, inside a transaction, because the partial unique index rejects the other ordering.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Turbo Frames/Streams, DaisyUI 5 on Tailwind 4, Minitest + Mocha + fixtures, Playwright, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-07-29-descriptions-c-write-paths-admin-design.md` (the Admin panel, Parents, Forms, and Testing sections; decisions C3, C4, C5, C6, C7).

**Depends on:** increment c1 (branch `descriptions-c`, PR #183), which added `Describable#assign_description` and rewired the four write sites. This branch stacks on it. **Owner's decision 2026-07-30: c2 and c3 ship as ONE PR** — stripping the forms without the panel leaves no way to edit a description, and the panel without stripping leaves two competing editors writing to different places.

---

## Global Constraints

- Run **every** Rails command from `web-app/`. Docs live at the project root in `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (`--fix` autocorrects). **Never** `bin/rubocop`. **Never** run brakeman.
- **The development database is not disposable.** The books data exists only in dev and takes hours to rebuild. Never run `db:drop`, `db:reset`, `db:schema:load`, `create_fixtures`, `data_migration:*`, or any bulk mutation. **This increment needs no migration and no data run.**
- **Use Rails generators** for the controller so the matching test file is created: `bin/rails generate controller admin/descriptions --no-helper --no-assets`. Then replace the body.
- **`rank` must appear in no form** (C4). `create` always writes `rank: :normal`; rank changes only through `set_preferred`. A form that could set `preferred` directly would skip the demotion and raise `PG::UniqueViolation` against `index_descriptions_one_preferred_per_key`.
- **`kind` and `locale` are hardcoded** `:summary` / `"en"` on create (C5). Rows at other values still list and delete.
- **The polymorphic association is `describable`, not `parent`.** Do not copy `Admin::ImagesController`'s `params[:parent_type]` or `parent.images` — they have no equivalent.
- Controller tests assert **behaviour** (status codes, params, no errors) — never HTML/CSS/copy.
- Add `data-testid` (kebab-case) only where role/text/label cannot target an element.
- Every commit message ends with a blank line then `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

### Facts verified against the codebase (do not re-derive)

- `Admin::ImagesController` (`app/controllers/admin/images_controller.rb`, 167 lines) is the pattern: `include Admin::DomainScopedAuth`, `before_action :require_domain_write!, only: [...]`, `set_parent` via `Admin::DomainRouting.parent_from_params(params, domain: current_domain)`, `domain_auth_parent` overridden to resolve the parent from the record on global actions, turbo_stream responses replacing both `"flash"` and the list frame, `redirect_path_for_parent` via `Admin::DomainRouting.path_for`.
- Views live at `app/views/admin/images/{index.html.erb,_image_card.html.erb}`. `index.html.erb` renders `turbo_frame_tag "images_list"` and takes `parent`/`images` as locals with `@`-ivar fallbacks; it is rendered with `layout: false`.
- Show pages mount the panel as `turbo_frame_tag "images_list", loading: :lazy, src: admin_album_images_path(@album)`.
- Nested image routes exist on 7 parents; **`descriptions` needs 9**, including `music/songs` and `games/series`, which have **no** nested image routes today.
- Global image routes sit at `config/routes.rb:473` inside the `resources :images, only: [:update, :destroy], controller: "images" do member { post :set_primary } end` block — add `descriptions` beside it.
- `Admin::DomainRouting::ENTITIES` has 9 entries but **`Games::Series` is absent**, and `NESTED_PARENTS[:games]` has only `game_id` and `company_id`. `Books::Edition` IS in `ENTITIES` but is **not** `Describable` and gets no panel.
- The description field markup in each `_form.html.erb` is a `<div class="form-control md:col-span-2">` wrapping a label, `f.text_area :description`, a hint `<label class="label">`, and an errors block. All nine controllers `permit(... :description ...)`.
- `Admin::ImagesControllerTest` (`test/controllers/admin/images_controller_test.rb`) shows the auth-test shape: `host! Rails.application.config.domains[:music]`, `sign_in_as(@user, stub_auth: true)`, fixtures `users(:admin_user)`, `users(:editor_user)`, `users(:regular_user)`.
- E2E specs live under `web-app/e2e/tests/{books,games,music}/`.

### Description model facts

- `enum :source, {manual: 0, ai_generated: 1, wikipedia: 2, openlibrary: 3, musicbrainz: 4, igdb: 5, publisher: 6, goodreads: 7, other: 9}, prefix: true`
- `enum :license, {cc0: 0, cc_by_sa_4: 1, proprietary: 2}, prefix: true`; `enum :rank, {deprecated: -1, normal: 0, preferred: 1}`
- `validates :source_name, presence: true, if: :source_other?` **and** `absence: true, unless: :source_other?` — biconditional, mirrored by the `descriptions_source_name_matches_source` CHECK.
- `validates :source, uniqueness: {scope: [:describable_type, :describable_id, :kind, :locale, :source_name]}` — a duplicate surfaces as a form error, not a 500.
- Fixtures in `test/fixtures/descriptions.yml`: `war_and_peace_ai`, `war_and_peace_wikipedia`, `war_and_peace_fr`, `war_and_peace_long`, `crime_preferred` (manual, **preferred**), `crime_ai`, `crime_deprecated`, `lonely_deprecated`, `dark_side_ai` (**preferred**), `botw_igdb` (**preferred**), `tolstoy_google` (other + "Google Books").

---

## File Structure

| File | Responsibility |
|---|---|
| Modify `web-app/app/lib/admin/domain_routing.rb` | `Games::Series` in `ENTITIES` + `NESTED_PARENTS[:games]` |
| Modify `web-app/test/lib/admin/domain_routing_test.rb` | Pin the new entry (create the file if absent) |
| Modify `web-app/config/routes.rb` | Nested `descriptions` on 9 parents + global block with `set_preferred` |
| Create `web-app/app/controllers/admin/descriptions_controller.rb` | The panel's five actions |
| Create `web-app/app/views/admin/descriptions/index.html.erb` | The `descriptions_list` turbo frame |
| Create `web-app/app/views/admin/descriptions/_description_card.html.erb` | One row: content, source badge, rank badge, actions, edit modal |
| Create `web-app/app/views/admin/descriptions/_form_fields.html.erb` | Shared create/edit fields (source picker, content, source_name, source_url, license) |
| Create `web-app/test/controllers/admin/descriptions_controller_test.rb` | CRUD, `set_preferred`, auth denials |
| Modify 9 × `app/views/admin/**/_form.html.erb` | Remove the description field |
| Modify 9 × `app/controllers/admin/**/*_controller.rb` | Remove `:description` from `permit` |
| Modify 9 × show pages | Mount the panel |
| Create `web-app/e2e/tests/music/admin-descriptions.spec.ts` | add / set-preferred / delete |

---

### Task 1: `Games::Series` in the admin registry

`Games::Series` has full admin CRUD but is absent from `Admin::DomainRouting`, so `path_for` returns `nil` and it cannot host a nested panel (C6). It is also the show page whose `_table.html.erb:29` reads `series.description` and would break at increment (e).

**Files:**
- Modify: `web-app/app/lib/admin/domain_routing.rb`
- Test: `web-app/test/lib/admin/domain_routing_test.rb` (create if it does not exist)

**Interfaces:**
- Produces: `Admin::DomainRouting.path_for(games_series)` returns the admin path instead of `nil`; `Admin::DomainRouting.domain_for(Games::Series)` returns `:games`; `Admin::DomainRouting.parent_from_params({series_id: n}, domain: :games)` resolves a `Games::Series`. Task 2's controller depends on all three.

- [ ] **Step 1: Confirm the route helper name**

Run: `cd web-app && bin/rails routes | grep -E 'admin.*games.*series' | head -5`

Note the exact `admin_games_series_path`-style helper. **Use whatever the output shows** — do not assume; `Books::Series` uses `admin_books_series_path` and the games equivalent may differ.

- [ ] **Step 2: Write the failing test**

Create or append to `web-app/test/lib/admin/domain_routing_test.rb`:

```ruby
require "test_helper"

class Admin::DomainRoutingTest < ActiveSupport::TestCase
  test "Games::Series resolves to the games domain" do
    assert_equal :games, Admin::DomainRouting.domain_for(games_series(:resident_evil))
  end

  test "Games::Series has an admin path" do
    series = games_series(:resident_evil)
    assert_not_nil Admin::DomainRouting.path_for(series)
    assert_match(/#{series.id}/, Admin::DomainRouting.path_for(series))
  end

  test "Games::Series resolves as a nested parent" do
    series = games_series(:resident_evil)
    assert_equal series,
      Admin::DomainRouting.parent_from_params({series_id: series.id}, domain: :games)
  end

  test "Books::Series still resolves in the books domain" do
    series = books_series(:lord_of_the_rings)
    assert_equal series,
      Admin::DomainRouting.parent_from_params({series_id: series.id}, domain: :books)
  end
end
```

**Check the fixture names first** — `games_series(:resident_evil)` is referenced by `test/lib/services/description_column_backfill_test.rb`, so it exists; confirm the books series fixture name in `test/fixtures/books/series.yml` before using it.

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`

Expected: FAIL — `domain_for` returns `nil` and `path_for` returns `nil` for `Games::Series`.

- [ ] **Step 4: Add the registry entries**

In `web-app/app/lib/admin/domain_routing.rb`, add to `ENTITIES` (after `"Games::Company"`), using the helper name confirmed in Step 1:

```ruby
      "Games::Series" => {
        domain: :games,
        path: ->(r) { URL_HELPERS.admin_games_series_path(r) },
        category_items_path: nil
      },
```

and add `series_id` to `NESTED_PARENTS[:games]`:

```ruby
      games: {
        game_id: "Games::Game",
        company_id: "Games::Company",
        series_id: "Games::Series"
      },
```

`series_id` already appears under `books:` — that is fine, the two are scoped by domain and `parent_from_params` is called with the current domain.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb test/controllers/admin/`

Expected: PASS. The second path guards against the new `NESTED_PARENTS` entry changing parent resolution for existing controllers.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/lib/admin/domain_routing.rb test/lib/admin/domain_routing_test.rb
git add web-app/app/lib/admin/domain_routing.rb web-app/test/lib/admin/domain_routing_test.rb
git commit -m "Register Games::Series in the admin domain routing

Required before it can host a nested descriptions panel; path_for returned nil.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Admin::DescriptionsController`, routes and views

**Files:**
- Modify: `web-app/config/routes.rb`
- Create: `web-app/app/controllers/admin/descriptions_controller.rb`
- Create: `web-app/app/views/admin/descriptions/index.html.erb`
- Create: `web-app/app/views/admin/descriptions/_description_card.html.erb`
- Create: `web-app/app/views/admin/descriptions/_form_fields.html.erb`
- Test: `web-app/test/controllers/admin/descriptions_controller_test.rb`
- Read for the pattern: `app/controllers/admin/images_controller.rb`, `app/views/admin/images/{index.html.erb,_image_card.html.erb}`

**Interfaces:**
- Consumes: `Admin::DomainRouting.{parent_from_params, path_for, domain_for}` (Task 1 extends it), `Admin::DomainScopedAuth#require_domain_write!`.
- Produces: routes `admin_<parent>_descriptions_path(parent)` (index/create) for 9 parents, plus `admin_description_path(d)` (update/destroy) and `set_preferred_admin_description_path(d)`. Task 3 mounts the index path on show pages; Task 5's E2E drives the whole surface.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, add `resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"` inside each of these nine blocks, immediately after the existing `resources :images...` line where one is present:

`music`: `artists`, `albums`, `songs` · `games`: `games`, `companies`, `series` · `books`: `books`, `authors`, `series`

**`music/songs` and `games/series` have no `resources :images` line** — add the descriptions line inside their `resources` block anyway. `books`' nested `editions` block gets **nothing** (`Books::Edition` is not `Describable`).

Then add the global block beside the images one (around line 473):

```ruby
    resources :descriptions, only: [:update, :destroy], controller: "descriptions" do
      member do
        post :set_preferred
      end
    end
```

Verify with: `bin/rails routes | grep description` — expect 9 index + 9 create + update + destroy + set_preferred.

- [ ] **Step 2: Write the failing controller test**

Create `web-app/test/controllers/admin/descriptions_controller_test.rb`:

```ruby
require "test_helper"

class Admin::DescriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @album = music_albums(:dark_side_of_the_moon)
    @description = descriptions(:dark_side_ai)
    @admin_user = users(:admin_user)
    @regular_user = users(:regular_user)
    host! Rails.application.config.domains[:music]
  end

  test "redirects unauthenticated users from index" do
    get admin_album_descriptions_path(@album)
    assert_redirected_to music_root_path
  end

  test "redirects regular users from index" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_album_descriptions_path(@album)
    assert_redirected_to music_root_path
  end

  test "admins can view the index" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_album_descriptions_path(@album)
    assert_response :success
  end

  test "creates a description at rank normal" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    assert_difference "Description.count", 1 do
      post admin_album_descriptions_path(album), params: {
        description: {content: "A hand-written summary.", source: "manual"}
      }
    end

    row = Description.last
    assert_equal "manual", row.source
    assert_equal "summary", row.kind
    assert_equal "en", row.locale
    assert_equal "normal", row.rank
    assert_equal album, row.describable
  end

  test "create accepts source_url and license" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    post admin_album_descriptions_path(album), params: {
      description: {
        content: "From Wikipedia.", source: "wikipedia",
        source_url: "https://en.wikipedia.org/wiki/Animals", license: "cc_by_sa_4"
      }
    }

    row = Description.last
    assert_equal "https://en.wikipedia.org/wiki/Animals", row.source_url
    assert_equal "cc_by_sa_4", row.license
  end

  test "create requires source_name for :other" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(album), params: {
        description: {content: "Unattributed.", source: "other"}
      }
    end
  end

  test "create rejects a duplicate natural key without raising" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(@album), params: {
        description: {content: "A second ai_generated row.", source: "ai_generated"}
      }
    end
  end

  test "create ignores a rank parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    post admin_album_descriptions_path(album), params: {
      description: {content: "Sneaky.", source: "manual", rank: "preferred"}
    }

    assert_equal "normal", Description.last.rank
  end

  test "updates content" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_description_path(@description), params: {
      description: {content: "Edited by an admin."}
    }

    assert_equal "Edited by an admin.", @description.reload.content
  end

  test "update ignores a rank parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    row = music_albums(:animals).descriptions.create!(
      kind: :summary, locale: "en", source: :manual, content: "Normal rank."
    )

    patch admin_description_path(row), params: {description: {rank: "preferred"}}

    assert_equal "normal", row.reload.rank
  end

  test "destroys a description" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_difference "Description.count", -1 do
      delete admin_description_path(@description)
    end
  end

  test "set_preferred demotes the incumbent and promotes the target" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:dark_side_of_the_moon)
    incumbent = descriptions(:dark_side_ai)
    challenger = album.descriptions.create!(
      kind: :summary, locale: "en", source: :wikipedia, content: "A wikipedia row."
    )

    post set_preferred_admin_description_path(challenger)

    assert_equal "preferred", challenger.reload.rank
    assert_equal "normal", incumbent.reload.rank
    assert_equal 1, album.descriptions.where(rank: :preferred).count
  end

  test "set_preferred is idempotent on an already-preferred row" do
    sign_in_as(@admin_user, stub_auth: true)

    post set_preferred_admin_description_path(@description)

    assert_equal "preferred", @description.reload.rank
    assert_equal 1, @album.descriptions.where(rank: :preferred).count
  end

  test "set_preferred only demotes within the same kind and locale" do
    sign_in_as(@admin_user, stub_auth: true)
    book = books_books(:war_and_peace)
    other_kind = descriptions(:war_and_peace_long)
    other_kind.update!(rank: :preferred)
    target = descriptions(:war_and_peace_ai)
    host! Rails.application.config.domains[:books]

    post set_preferred_admin_description_path(target)

    assert_equal "preferred", target.reload.rank
    assert_equal "preferred", other_kind.reload.rank
  end

  test "regular users cannot create, update, destroy or set_preferred" do
    sign_in_as(@regular_user, stub_auth: true)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(@album), params: {
        description: {content: "Nope.", source: "manual"}
      }
    end
    assert_redirected_to music_root_path

    patch admin_description_path(@description), params: {description: {content: "Nope."}}
    assert_redirected_to music_root_path

    post set_preferred_admin_description_path(@description)
    assert_redirected_to music_root_path

    assert_no_difference "Description.count" do
      delete admin_description_path(@description)
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/controllers/admin/descriptions_controller_test.rb`

Expected: FAIL — the controller does not exist.

- [ ] **Step 4: Generate and write the controller**

Run: `bin/rails generate controller admin/descriptions --no-helper --no-assets`

Then replace its body. Read `app/controllers/admin/images_controller.rb` first and mirror its turbo-stream shape exactly; the differences are noted in comments below.

```ruby
class Admin::DescriptionsController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :require_domain_write!, only: [:create, :update, :destroy, :set_preferred]
  before_action :set_parent, only: [:index, :create]
  before_action :set_description, only: [:update, :destroy, :set_preferred]

  def index
    @descriptions = @parent.descriptions.order(rank: :desc, source: :asc)
    render layout: false
  end

  def create
    @description = @parent.descriptions.build(description_params)
    @description.kind = :summary
    @description.locale = "en"
    @description.rank = :normal

    if @description.save
      respond_with_list(@parent, notice: "Description added.")
    else
      respond_with_error(@description)
    end
  end

  def update
    if @description.update(description_params)
      respond_with_list(@description.describable, notice: "Description updated.")
    else
      respond_with_error(@description)
    end
  end

  def destroy
    describable = @description.describable
    @description.destroy!
    respond_with_list(describable, notice: "Description deleted.")
  end

  # Demote-then-promote in a transaction. This cannot mirror Image's after_save
  # promote-first callback: the partial unique index index_descriptions_one_preferred_per_key
  # rejects two preferred rows for the same (describable, kind, locale) mid-callback.
  def set_preferred
    Description.transaction do
      Description
        .where(describable_type: @description.describable_type,
          describable_id: @description.describable_id,
          kind: @description.kind, locale: @description.locale, rank: :preferred)
        .where.not(id: @description.id)
        .update_all(rank: 0)
      @description.update!(rank: :preferred)
    end

    respond_with_list(@description.describable, notice: "Preferred description updated.")
  end

  private

  def domain_auth_parent
    if action_name.in?(%w[update destroy set_preferred])
      Description.find(params[:id]).describable
    else
      Admin::DomainRouting.parent_from_params(params, domain: current_domain)
    end
  end

  def set_parent
    @parent = Admin::DomainRouting.parent_from_params(params, domain: current_domain)
  end

  def set_description
    @description = Description.find(params[:id])
  end

  # rank is deliberately absent (C4): only set_preferred changes it, transactionally.
  # kind and locale are absent too (C5) and are forced in create.
  def description_params
    params.require(:description).permit(:content, :source, :source_name, :source_url, :license)
  end

  def respond_with_list(describable, notice:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
          turbo_stream.replace("descriptions_list", template: "admin/descriptions/index",
            locals: {parent: describable, descriptions: describable.descriptions.reload.order(rank: :desc, source: :asc)})
        ]
      end
      format.html { redirect_to redirect_path_for(describable), notice: notice }
    end
  end

  def respond_with_error(description)
    message = description.errors.full_messages.join(", ")
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("flash", partial: "admin/shared/flash",
          locals: {flash: {error: message}}), status: :unprocessable_entity
      end
      format.html { redirect_to redirect_path_for(description.describable), alert: message }
    end
  end

  def redirect_path_for(describable)
    Admin::DomainRouting.path_for(describable) || admin_root_path
  end
end
```

`update_all(rank: 0)` takes the raw integer because `update_all` writes straight to SQL without the enum cast. `where.not(id:)` keeps `set_preferred` idempotent — without it, re-running on an already-preferred row would demote the row it is about to promote.

- [ ] **Step 5: Write the views**

`app/views/admin/descriptions/index.html.erb` — mirror `admin/images/index.html.erb`'s locals-with-ivar-fallback shape:

```erb
<% rows = defined?(descriptions) ? descriptions : @descriptions %>
<% parent_entity = defined?(parent) ? parent : @parent %>
<%= turbo_frame_tag "descriptions_list" do %>
  <% if rows.any? %>
    <div class="space-y-3">
      <% rows.each do |description| %>
        <%= render "admin/descriptions/description_card", description: description, parent: parent_entity %>
      <% end %>
    </div>
  <% else %>
    <p class="text-base-content/60 text-sm">No descriptions yet.</p>
  <% end %>

  <%= render "admin/descriptions/new_form", parent: parent_entity %>
<% end %>
```

`_description_card.html.erb` — one row showing the content, a badge for `source` (use `description.source_other? ? description.source_name : description.source.humanize`, matching `ExternalLink#source_display_name`), a `badge-primary` "Preferred" badge when `description.preferred?` and a `badge-ghost` "Deprecated" when `description.deprecated?`, a "Make preferred" `button_to set_preferred_admin_description_path(description), method: :post` shown **unless** already preferred, a delete `button_to ... method: :delete` with `data: {turbo_confirm: "Delete this description?"}`, and an edit `<dialog>` modal keyed `edit_description_<%= description.id %>_modal` following `_image_card.html.erb`'s modal pattern exactly (including `data: {controller: "modal-form", modal_form_modal_id_value: ...}`). The modal's form posts to `admin_description_path(description)` with `method: :patch` and renders the shared fields partial.

`_form_fields.html.erb` — takes an `f` form builder. Fields, each in the DaisyUI-5 `<div class="form-control">` + `w-full` pattern used by the existing admin forms:
- `f.text_area :content`, `textarea textarea-bordered w-full h-32`, required
- `f.select :source, Description.sources.keys.map { |s| [s.humanize, s] }`, `select select-bordered w-full`
- `f.text_field :source_name`, `input input-bordered w-full` — with a hint that it is required only for "Other"
- `f.url_field :source_url`, `input input-bordered w-full`
- `f.select :license, Description.licenses.keys.map { |l| [l.humanize, l] }, {include_blank: "Not recorded"}`, `select select-bordered w-full`

**No `rank` field, no `kind` field, no `locale` field** (C4, C5).

Also create `_new_form.html.erb` rendering an "Add Description" `<dialog>` modal posting to `admin_<parent>_descriptions_path`; derive the path with `Admin::DomainRouting` rather than a per-domain case statement — check whether a helper already exists for nested paths and add one if not, rather than branching on class name in the view.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/descriptions_controller_test.rb`

Expected: PASS, 15 runs, 0 failures.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/controllers/admin/descriptions_controller.rb config/routes.rb test/controllers/admin/descriptions_controller_test.rb
git add web-app/app/controllers/admin/descriptions_controller.rb web-app/app/views/admin/descriptions/ web-app/config/routes.rb web-app/test/controllers/admin/descriptions_controller_test.rb
git commit -m "Add Admin::DescriptionsController with transactional set_preferred

Demote-then-promote inside a transaction: the partial unique index rejects the
promote-first ordering Image#unset_other_primary_images uses.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Mount the panel on the nine show pages

**Files:** the nine `app/views/admin/{books/{books,authors,series},games/{games,companies,series},music/{albums,artists,songs}}/show.html.erb`

**Interfaces:**
- Consumes: `admin_<parent>_descriptions_path` from Task 2.
- Produces: a `descriptions_list` turbo frame on each show page. Task 5's E2E drives it.

- [ ] **Step 1: Add the panel to one page and verify by hand**

In `app/views/admin/music/albums/show.html.erb`, find the existing images panel (`turbo_frame_tag "images_list", loading: :lazy, src: admin_album_images_path(@album)`) and add a Descriptions card above or below it in the same style:

```erb
<div class="card bg-base-100 shadow-sm">
  <div class="card-body">
    <h2 class="card-title">Descriptions</h2>
    <%= turbo_frame_tag "descriptions_list", loading: :lazy,
        src: admin_album_descriptions_path(@album) do %>
      <div class="flex justify-center py-4">
        <span class="loading loading-spinner loading-md"></span>
      </div>
    <% end %>
  </div>
</div>
```

Match the surrounding card markup on each page rather than pasting this verbatim — the nine show pages are not identical.

- [ ] **Step 2: Repeat for the other eight**

Each uses its own path helper: `admin_artist_descriptions_path(@artist)`, `admin_song_descriptions_path(@song)`, `admin_games_game_descriptions_path(@game)`, `admin_games_company_descriptions_path(@company)`, `admin_games_series_descriptions_path(@series)`, `admin_books_book_descriptions_path(@book)`, `admin_books_author_descriptions_path(@author)`, `admin_books_series_descriptions_path(@series)`.

**Confirm each helper name against `bin/rails routes | grep descriptions`** rather than assuming — the games and books namespaces prefix differently from music.

- [ ] **Step 3: Verify every page renders**

Run: `bin/rails test test/controllers/admin/`

Expected: PASS. Existing show-page controller tests will catch a bad path helper as a 500.

- [ ] **Step 4: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/views/admin/
git add web-app/app/views/admin/
git commit -m "Mount the descriptions panel on the nine describable show pages

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Strip the description field from nine forms

Once the panel exists, a form writing the column is a control that silently does nothing — and at increment (e) it references a dropped column and errors (C7).

**Files:**
- Modify: 9 × `app/views/admin/**/_form.html.erb`
- Modify: 9 × `app/controllers/admin/**/*_controller.rb`
- Modify: any controller test asserting the description param round-trips

**Interfaces:** none produced; this only removes.

- [ ] **Step 1: Remove the field from all nine forms**

Delete the `<div class="form-control md:col-span-2">` block wrapping `f.text_area :description` from each of:
`admin/books/{books,authors,series}/_form.html.erb`, `admin/games/{games,companies,series}/_form.html.erb`, `admin/music/{albums,artists,songs}/_form.html.erb`.

Delete the whole block — label, textarea, hint label and the errors block that references `errors[:description]`. If removing it leaves a grid with an odd `md:col-span-2` gap, leave the surrounding grid alone; do not restyle.

**Do NOT touch** `admin/penalties/_form.html.erb` or either `ranking_configurations/_form.html.erb` — those descriptions are authored config, not sourced content, and their columns are not being dropped.

- [ ] **Step 2: Remove `:description` from the nine `permit` lists**

One occurrence in each of `app/controllers/admin/{books/{books,authors,series},games/{games,companies,series},music/{albums,artists,songs}}_controller.rb` — verified, exactly one each.

- [ ] **Step 3: Run the admin controller tests and fix fallout**

Run: `bin/rails test test/controllers/admin/`

Expected: some tests fail because they submit or assert `description` in form params. Update each to drop the param — the description no longer round-trips through these forms. Do **not** re-add the permit entry to make a test pass.

- [ ] **Step 4: Confirm nothing still permits it**

```bash
cd web-app && grep -rn ':description' app/controllers/admin/ | grep permit
```

Expected: only `penalties_controller.rb` and the two ranking-configuration controllers, if they permit it at all. No `books/`, `games/` or `music/` entity controller.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb --fix app/controllers/admin/ app/views/admin/ test/controllers/admin/
git add web-app/app/controllers/admin/ web-app/app/views/admin/ web-app/test/controllers/admin/
git commit -m "Strip the description field from the nine admin forms

The panel is the editor now; a form writing the column would silently do
nothing once increment (d) reads primary_description.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Playwright E2E

**Files:**
- Create: `web-app/e2e/tests/music/admin-descriptions.spec.ts`
- Read for the pattern: any existing spec under `web-app/e2e/tests/music/`

**Interfaces:** none produced.

- [ ] **Step 1: Read an existing admin spec**

Run: `ls web-app/e2e/tests/music/ && sed -n '1,40p' web-app/e2e/tests/music/<an-existing-admin-spec>.spec.ts`

Match its login helper, base-URL handling and locator style. Do not invent a new harness.

- [ ] **Step 2: Write the spec**

Cover the flow end to end on an album's admin show page: the descriptions panel loads; add a description via the modal (content + source); it appears in the list; click "Make preferred" and the Preferred badge moves to it; delete it and it disappears.

Target elements by role/text/label. Add `data-testid` (kebab-case) in the Task 2/3 views **only** where that is impossible — for example `data-testid="descriptions-panel"` on the frame if no heading uniquely identifies it.

- [ ] **Step 3: Run it**

Needs a local dev server (`bin/dev`) and `e2e/.env`.

Run: `cd web-app && yarn test:e2e --grep "descriptions"`

Expected: PASS. **If every admin spec times out on the public homepage**, the e2e user lost its role in a dev-DB reseed — fix with `bin/rails e2e:admin`, do not debug the login flow.

- [ ] **Step 4: Commit**

```bash
git add web-app/e2e/tests/music/admin-descriptions.spec.ts web-app/app/views/admin/
git commit -m "Add Playwright E2E for the admin descriptions panel

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Full gate

**Files:** none — verification only.

- [ ] **Step 1: Run the full suite, system tests and lint**

```bash
cd web-app && bundle exec standardrb && bin/rails db:test:prepare test test:system
```

Expected: `standardrb` clean; suite green (4,963 runs as of c1, plus this increment's tests); system tests green.

- [ ] **Step 2: Confirm the forms are clean**

```bash
cd web-app && grep -rn 'f.text_area :description\|f.text_field :description' app/views/admin/ | grep -v penalties | grep -v ranking_configuration
```

Expected: **no output.**

- [ ] **Step 3: Report**

No commit. Report the suite counts, system-test result, E2E result and both grep results. If anything is red, report it precisely and do not claim completion.

---

## Self-Review

**1. Spec coverage.** C3 (full source picker + `source_url`/`license`) → Task 2 Step 5's `_form_fields`. C4 (`rank` in no form; only `set_preferred`) → Task 2's `description_params` omits it, `create` forces `:normal`, and two tests pin that a submitted `rank` is ignored. C5 (`kind`/`locale` hardcoded) → forced in `create`, absent from the form. C6 (`Games::Series` registry) → Task 1. C7 (stripping is not optional) → Task 4. The spec's `set_preferred` transaction → Task 2 Step 4, pinned by three tests including the cross-kind isolation case. The "not to copy from ImagesController" note (`describable`, not `parent`) → reflected in `domain_auth_parent` and `respond_with_list`. Testing section → Tasks 2 and 5. Deliberately out of scope, per the spec: bulk set-preferred-by-list, a `deprecated` rank control, public read views (increment d), and Movies.

**2. Placeholder scan.** Every code step carries real code except the three view partials in Task 2 Step 5 and the E2E spec in Task 5, which specify content, classes, helpers and behaviour but point at a named existing file to mirror for markup. That is deliberate: the nine show pages and the image partials are not uniform, and inventing ~200 lines of ERB that silently diverges from house style would be worse than instructing the implementer to read the precedent. Each such step names the exact file to mirror and the exact differences.

**3. Type consistency.** `Admin::DomainRouting.parent_from_params(params, domain:)` and `path_for(record)` match the signatures read from source. `description_params` permits exactly `content, source, source_name, source_url, license` and is used in both `create` and `update`. `respond_with_list(describable, notice:)` and `respond_with_error(description)` are defined once and called from all four mutating actions. `Description.sources` / `Description.licenses` are the Rails enum class methods, returning `{name => value}` hashes whose `.keys` are Strings — matching the `select` options built from them.
