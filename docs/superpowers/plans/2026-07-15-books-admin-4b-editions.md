# Books Admin 4b — Editions CRUD + set_default + Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working `Books::Edition` admin — nested CRUD under a book, a lazy turbo-frame editions card on the book show page, a dedicated edition show page (details + read-only identifiers + cover images), and a `set_default` action writing `books.default_edition_id` — on the books host.

**Architecture:** `Admin::Books::EditionsController` is a nested resource under `resources :books`, declared `shallow: true` so its member routes live at `/admin/editions/:id`. Editions have no top-level index and no sidebar link (umbrella design D5); the book show page hosts an `Editions` card that lazy-loads the nested `index` action into a turbo-frame, mirroring how the Images card loads. Create/edit are full pages mirroring the 4a book form. Cover images ride the already-domain-agnostic `Admin::ImagesController` once `Books::Edition` is registered in `Admin::DomainRouting`.

**Tech Stack:** Rails 8, Pundit, Pagy (unused here — editions aren't paginated), Turbo Frames, ActiveStorage (images), Minitest + fixtures + Mocha, Playwright.

## Global Constraints

- Run **all** commands from `web-app/`. Working dir: `/home/shane/dev/the-greatest/web-app`.
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. Never run a destructive DB command; `RAILS_ENV=test` must be explicit on anything touching fixtures. `ActiveRecord::FixtureSet.create_fixtures` TRUNCATES — never call it.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- **No code comments** unless the code shown here has them. Self-documenting code, follow existing patterns.
- Namespace all books code under `Books::` / `Admin::Books::`. Tests mirror the namespace (`module Admin; module Books`).
- Controller tests assert **behavior** (status codes, redirects, params, `assert_difference` on counts) — never HTML/CSS/copy.
- Rails 8 enum syntax (already defined on `Books::Edition`): `edition_type` and `book_binding` both use `prefix:`, so the class methods are `::Books::Edition.edition_types` / `.book_bindings` and the plain attribute readers (`edition.book_binding`) still return the bare string or `nil`.
- **`raise_on_missing_callback_actions` is on in dev+test.** A `before_action ..., only: […]` list is validated in full on every dispatch. Grow those lists exactly as actions land in each task — never name an action that this task does not yet define.
- Use the Rails generator for the controller (`--skip-routes --no-helper`); hand-write the views by adapting the 4a book templates and the games/music patterns cited per task.

## Deviations from the umbrella design (`docs/superpowers/specs/2026-07-13-books-admin-ui-design.md`)

Read these first — they scope what 4b contains.

1. **This is increment 4b of a 3-way split of the design's increment 4** (4a book CRUD + images — merged PR #169; **4b editions — this plan**; 4c inline BookAuthors/Credits/BookRelationships). The increment-specific decisions are captured in `docs/superpowers/specs/2026-07-15-books-admin-4b-editions-design.md`.
2. **Credits are deferred to 4c.** The design's D5 says the edition show page carries "identifiers, cover images, and credits" — but per the 4b/4c split, **the edition show page in 4b renders identifiers (read-only) and images only; NO credits section.** Do not add a credits UI or the author-search endpoint here.
3. **No sidebar/nav item for editions** (D5). The 4a landmine "every controller increment must add a `DomainNav` entry" deliberately does **not** apply to 4b — do NOT touch `Admin::DomainNav`.
4. **Identifiers stay read-only.** Editions display their identifiers but the admin never creates/edits them (nothing populates them through the UI).
5. **A Playwright smoke spec ships here** (CLAUDE.md requires an E2E test per new user-facing page). The exhaustive per-entity suite stays in increment 7.

## Fixtures available (no new fixtures needed)

- `books_books(:war_and_peace)` — the parent book.
- `books_editions(:wp_maude)` (`edition_type: 0`, `book_binding: 1`, `publication_year: 1990`, `language: english`) and `books_editions(:wp_volume_one)` (`volume_number: 1`) — both belong to `war_and_peace`.
- `users(:admin_user)`, `users(:editor_user)`, `users(:regular_user)`.
- `languages(:english)`.

---

### Task 1: Routes, registry registration, editions index frame, and the book show Editions card

**Files:**
- Modify: `web-app/config/routes.rb` (books admin namespace — the `resources :books` block near `config/routes.rb:278`)
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`ENTITIES`, `NESTED_PARENTS`)
- Create: `web-app/app/controllers/admin/books/editions_controller.rb`
- Create: `web-app/app/views/admin/books/editions/index.html.erb`
- Modify: `web-app/app/views/admin/books/books/show.html.erb` (add the Editions card + Default line)
- Test: `web-app/test/lib/admin/domain_routing_test.rb` (add edition assertions)
- Test: `web-app/test/controllers/admin/books/editions_controller_test.rb` (create; index tests)

**Interfaces:**
- Consumes: `Admin::Books::BaseController` (exists — `include Admin::DomainScopedAuth`); `Books::EditionPolicy` (exists from inc 3); `Books::Book has_many :editions`; `Admin::DomainRouting.parent_from_params(params, domain:)` (exists).
- Produces: route helpers `admin_books_book_editions_path(book)`, `new_admin_books_book_edition_path(book)`, `admin_books_edition_path(edition)`, `edit_admin_books_edition_path(edition)`, `set_default_admin_books_edition_path(edition)`, `admin_books_edition_images_path(edition)`; `Admin::DomainRouting.domain_for(Books::Edition) => :books`, `path_for(edition) => "/admin/editions/<id>"`, `parent_from_params({edition_id: id}, domain: :books) => edition`. Later tasks add the `show`/`new`/`create`/`edit`/`update`/`destroy`/`set_default` actions.

- [ ] **Step 1: Write the failing registry tests**

In `web-app/test/lib/admin/domain_routing_test.rb`, add a books-edition row to the existing `path_for` hash (find `test "path_for returns the admin show path for every registered entity"`):

```ruby
        books_books(:war_and_peace) => "/admin/books",
        books_editions(:wp_maude) => "/admin/editions"
```

(The `war_and_peace` row already exists — add only the `wp_maude` line.) Then add two dedicated tests near the existing books assertions:

```ruby
    test "domain_for resolves a Books::Edition to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_editions(:wp_maude))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Edition)
    end

    test "parent_from_params resolves an edition_id under the books domain" do
      edition = books_editions(:wp_maude)
      resolved = Admin::DomainRouting.parent_from_params({edition_id: edition.id}, domain: :books)
      assert_equal edition, resolved
    end
```

- [ ] **Step 2: Run the registry tests to verify they fail**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`
Expected: FAIL — `path_for` returns `nil` for the edition (not registered), and `domain_for`/`parent_from_params` don't resolve `Books::Edition`.

- [ ] **Step 3: Register `Books::Edition` in `DomainRouting`**

In `web-app/app/lib/admin/domain_routing.rb`, add to `ENTITIES` after the `"Books::Book"` entry:

```ruby
      "Books::Edition" => {
        domain: :books,
        path: ->(r) { URL_HELPERS.admin_books_edition_path(r) },
        category_items_path: nil
      }
```

and add `edition_id` to `NESTED_PARENTS[:books]`:

```ruby
      books: {
        book_id: "Books::Book",
        edition_id: "Books::Edition"
      }
```

- [ ] **Step 4: Add the editions routes**

In `web-app/config/routes.rb`, replace the books admin `resources :books` block (inside the books `DomainConstraint`, `namespace :admin, module: "admin/books", as: "admin_books"`) so editions nest under it:

```ruby
      resources :books do
        resources :editions, shallow: true do
          member do
            post :set_default
          end
          resources :images, only: [:index, :create], controller: "/admin/images"
        end
        resources :images, only: [:index, :create], controller: "/admin/images"
        collection do
          get :search
        end
      end
```

- [ ] **Step 5: Create the controller with `index` only**

Create `web-app/app/controllers/admin/books/editions_controller.rb`:

```ruby
class Admin::Books::EditionsController < Admin::Books::BaseController
  before_action :set_book, only: [:index]

  def index
    authorize ::Books::Edition
    @editions = @book.editions.includes(:language).order(popularity: :desc, id: :asc)
    render layout: false
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:book_id])
  end
end
```

- [ ] **Step 6: Create the index frame view**

Create `web-app/app/views/admin/books/editions/index.html.erb`:

```erb
<%= turbo_frame_tag "book_editions" do %>
  <% if @editions.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Edition</th>
            <th>Year</th>
            <th>Binding</th>
            <th>Publisher</th>
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <% @editions.each do |edition| %>
            <tr>
              <td>
                <%= link_to edition.title.presence || edition.edition_type.titleize, admin_books_edition_path(edition), class: "link link-hover", data: {turbo_frame: "_top"} %>
                <% if edition.id == @book.default_edition_id %>
                  <span class="badge badge-primary badge-sm ml-1">★ Default</span>
                <% end %>
              </td>
              <td><%= edition.publication_year || "—" %></td>
              <td><%= edition.book_binding&.titleize || "—" %></td>
              <td><%= edition.publisher_name.presence || "—" %></td>
              <td class="text-right">
                <%= link_to "View", admin_books_edition_path(edition), class: "btn btn-ghost btn-xs", data: {turbo_frame: "_top"} %>
                <% if current_user_can_write? %>
                  <%= link_to "Edit", edit_admin_books_edition_path(edition), class: "btn btn-ghost btn-xs", data: {turbo_frame: "_top"} %>
                  <% unless edition.id == @book.default_edition_id %>
                    <%= button_to "Set default", set_default_admin_books_edition_path(edition), method: :post, class: "btn btn-ghost btn-xs", form: {data: {turbo_frame: "_top"}} %>
                  <% end %>
                <% end %>
                <% if current_user_can_delete? %>
                  <%= button_to "Delete", admin_books_edition_path(edition), method: :delete, class: "btn btn-ghost btn-xs text-error", data: {turbo_confirm: "Delete this edition? This cannot be undone."}, form: {data: {turbo_frame: "_top"}} %>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% else %>
    <p class="text-base-content/60 text-sm">No editions yet.</p>
  <% end %>
<% end %>
```

- [ ] **Step 7: Add the Editions card to the book show page**

In `web-app/app/views/admin/books/books/show.html.erb`, insert this card immediately **after** the closing `</div>` of the `grid grid-cols-1 lg:grid-cols-3` block (currently line 66) and **before** the `<% if current_user_can_write? %>` image-modal block (currently line 68):

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="card-title text-base">Editions</h2>
          <p class="text-sm text-base-content/60">
            Default:
            <% if @book.default_edition %>
              <%= link_to (@book.default_edition.title.presence || @book.default_edition.edition_type.titleize), admin_books_edition_path(@book.default_edition), class: "link" %>
            <% else %>
              —
            <% end %>
          </p>
        </div>
        <% if current_user_can_write? %>
          <%= link_to "+ New Edition", new_admin_books_book_edition_path(@book), class: "btn btn-sm btn-primary" %>
        <% end %>
      </div>
      <%= turbo_frame_tag "book_editions", src: admin_books_book_editions_path(@book), loading: :lazy do %>
        <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
      <% end %>
    </div>
  </div>
```

- [ ] **Step 8: Write the failing controller tests**

Create `web-app/test/controllers/admin/books/editions_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class EditionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @edition = books_editions(:wp_maude)

        host! Rails.application.config.domains[:books]
      end

      # Index (nested, lazy frame)

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_redirected_to books_root_path
      end

      test "index renders the book's editions frame for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_response :success
      end
    end
  end
end
```

- [ ] **Step 9: Run the controller tests to verify they pass, and the registry tests too**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb test/lib/admin/domain_routing_test.rb`
Expected: PASS (all green — index + registry).

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/editions_controller.rb app/lib/admin/domain_routing.rb
git add config/routes.rb app/lib/admin/domain_routing.rb app/controllers/admin/books/editions_controller.rb app/views/admin/books/editions/index.html.erb app/views/admin/books/books/show.html.erb test/lib/admin/domain_routing_test.rb test/controllers/admin/books/editions_controller_test.rb
git commit -m "Add the editions index frame and register Books::Edition in the admin routing"
```

---

### Task 2: Edition show page + edition cover images

**Files:**
- Modify: `web-app/app/controllers/admin/books/editions_controller.rb` (add `show` + `set_edition`/`authorize_edition`)
- Create: `web-app/app/views/admin/books/editions/show.html.erb`
- Test: `web-app/test/controllers/admin/books/editions_controller_test.rb` (append show + images tests)

**Interfaces:**
- Consumes: the routes + registry from Task 1; the shared `Admin::ImagesController` (resolves its parent via `edition_id` → `Books::Edition`, registered in Task 1).
- Produces: `@edition` show page reachable at `admin_books_edition_path(edition)`; edition images at `admin_books_edition_images_path(edition)`.

- [ ] **Step 1: Write the failing show + images tests**

Append inside the test class in `web-app/test/controllers/admin/books/editions_controller_test.rb`:

```ruby
      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_edition_path(@edition)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_edition_path(@edition)
        assert_redirected_to books_root_path
      end

      # Images (shared controller, resolved via edition_id)

      test "the edition images index frame renders" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_edition_images_path(@edition)
        assert_response :success
      end

      test "uploading an image attaches it to the edition" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_edition_images_path(@edition), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Edition cover",
              primary: true
            }
          }
        end
        assert_includes @edition.reload.images.map(&:id), Image.order(:created_at).last.id
      end
```

- [ ] **Step 2: Run to verify the show tests fail**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: FAIL — `show` action / view missing (`AbstractController::ActionNotFound` or missing template). The image tests should already pass (the shared controller + Task 1 registration handle them).

- [ ] **Step 3: Add the `show` action**

In `web-app/app/controllers/admin/books/editions_controller.rb`, add `show` and the shared before_actions. The controller now reads:

```ruby
class Admin::Books::EditionsController < Admin::Books::BaseController
  before_action :set_book, only: [:index]
  before_action :set_edition, only: [:show]
  before_action :authorize_edition, only: [:show]

  def index
    authorize ::Books::Edition
    @editions = @book.editions.includes(:language).order(popularity: :desc, id: :asc)
    render layout: false
  end

  def show
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:book_id])
  end

  def set_edition
    @edition = ::Books::Edition.find(params[:id])
  end

  def authorize_edition
    authorize @edition
  end
end
```

- [ ] **Step 4: Create the show view**

Create `web-app/app/views/admin/books/editions/show.html.erb`:

```erb
<% content_for :title, (@edition.title.presence || "Edition ##{@edition.id}") %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-3xl font-bold"><%= @edition.title.presence || @edition.edition_type.titleize %></h1>
      <p class="text-base-content/70">
        Edition of <%= link_to @edition.book.title, admin_books_book_path(@edition.book), class: "link" %>
        <% if @edition.id == @edition.book.default_edition_id %>
          <span class="badge badge-primary badge-sm ml-1">★ Default</span>
        <% end %>
      </p>
    </div>
    <div class="flex gap-2">
      <%= link_to "Back", admin_books_book_path(@edition.book), class: "btn btn-ghost" %>
      <% if current_user_can_write? %>
        <% unless @edition.id == @edition.book.default_edition_id %>
          <%= button_to "Set as default", set_default_admin_books_edition_path(@edition), method: :post, class: "btn btn-secondary" %>
        <% end %>
        <%= link_to "Edit", edit_admin_books_edition_path(@edition), class: "btn btn-primary" %>
      <% end %>
      <% if current_user_can_delete? %>
        <%= button_to "Delete", admin_books_edition_path(@edition), method: :delete, class: "btn btn-error", form: {data: {turbo_confirm: "Delete this edition? This cannot be undone."}} %>
      <% end %>
    </div>
  </div>

  <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2 space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Details</h2>
          <dl class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div><dt class="text-sm text-base-content/60">Type</dt><dd><%= @edition.edition_type.titleize %></dd></div>
            <div><dt class="text-sm text-base-content/60">Binding</dt><dd><%= @edition.book_binding&.titleize || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Publication Year</dt><dd><%= @edition.publication_year || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Publisher</dt><dd><%= @edition.publisher_name.presence || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Page Count</dt><dd><%= @edition.page_count || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Volume</dt><dd><%= @edition.volume_number || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Language</dt><dd><%= @edition.language&.name || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Subtitle</dt><dd><%= @edition.subtitle.presence || "—" %></dd></div>
          </dl>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Identifiers <span class="badge badge-ghost"><%= @edition.identifiers.count %></span></h2>
          <% if @edition.identifiers.any? %>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <% @edition.identifiers.each do |identifier| %>
                <div>
                  <dt class="text-sm text-base-content/60"><%= identifier.identifier_type&.titleize %></dt>
                  <dd class="font-mono text-sm"><%= identifier.value %></dd>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="text-base-content/50 text-sm">No identifiers.</p>
          <% end %>
        </div>
      </div>
    </div>

    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Images</h2>
            <% if current_user_can_write? %>
              <button class="btn btn-sm btn-ghost" onclick="add_edition_image_modal.showModal()">+ Add</button>
            <% end %>
          </div>
          <%= turbo_frame_tag "images_list", loading: :lazy, src: admin_books_edition_images_path(@edition) do %>
            <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
          <dl class="space-y-2 text-sm">
            <div><dt class="text-base-content/60">ID</dt><dd><%= @edition.id %></dd></div>
            <div><dt class="text-base-content/60">Popularity</dt><dd><%= @edition.popularity || "—" %></dd></div>
            <div><dt class="text-base-content/60">Created</dt><dd><%= @edition.created_at.to_date %></dd></div>
            <div><dt class="text-base-content/60">Updated</dt><dd><%= @edition.updated_at.to_date %></dd></div>
          </dl>
        </div>
      </div>
    </div>
  </div>

  <% if current_user_can_write? %>
    <dialog id="add_edition_image_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Image</h3>
        <%= form_with model: Image.new, url: admin_books_edition_images_path(@edition), method: :post, data: {controller: "modal-form", modal_form_modal_id_value: "add_edition_image_modal"} do |f| %>
          <label class="form-control">
            <span class="label-text">File</span>
            <%= f.file_field :file, accept: "image/jpeg,image/png,image/webp,image/gif", required: true, class: "file-input file-input-bordered" %>
          </label>
          <label class="form-control mt-2">
            <span class="label-text">Notes</span>
            <%= f.text_field :notes, class: "input input-bordered" %>
          </label>
          <label class="label cursor-pointer mt-2 justify-start gap-2">
            <%= f.check_box :primary, class: "checkbox" %>
            <span class="label-text">Primary</span>
          </label>
          <div class="modal-action">
            <%= f.submit "Upload", class: "btn btn-primary" %>
            <button type="button" class="btn" onclick="add_edition_image_modal.close()">Cancel</button>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
  <% end %>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: PASS (index + show + images all green).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/editions_controller.rb
git add app/controllers/admin/books/editions_controller.rb app/views/admin/books/editions/show.html.erb test/controllers/admin/books/editions_controller_test.rb
git commit -m "Add the edition show page and edition cover images"
```

---

### Task 3: New + create + the edition form

**Files:**
- Modify: `web-app/app/controllers/admin/books/editions_controller.rb` (add `new`, `create`, `edition_params`; extend `set_book`)
- Create: `web-app/app/views/admin/books/editions/_form.html.erb`
- Create: `web-app/app/views/admin/books/editions/new.html.erb`
- Test: `web-app/test/controllers/admin/books/editions_controller_test.rb` (append new/create tests)

**Interfaces:**
- Consumes: `@book` (from `set_book`), the show page from Task 2 (create redirects to it).
- Produces: a working create at `POST admin_books_book_editions_path(book)` with param key `books_edition`, permitting the 10 fields `title, subtitle, edition_type, book_binding, publication_year, publisher_name, page_count, volume_number, language_id, popularity`.

- [ ] **Step 1: Write the failing new/create tests**

Append inside the test class:

```ruby
      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_book_edition_path(@book)
        assert_response :success
      end

      test "create makes an edition under the book and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("@book.editions.count", 1) do
          post admin_books_book_editions_path(@book), params: {books_edition: {edition_type: "annotated", publication_year: 2005, publisher_name: "Test House", book_binding: "paperback"}}
        end
        edition = @book.editions.order(:created_at).last
        assert_redirected_to admin_books_edition_path(edition)
        assert_equal "annotated", edition.edition_type
        assert_equal "Test House", edition.publisher_name
      end

      test "create rejects an edition with no edition_type" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Edition.count") do
          post admin_books_book_editions_path(@book), params: {books_edition: {edition_type: ""}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Edition.count") do
          post admin_books_book_editions_path(@book), params: {books_edition: {edition_type: "standard"}}
        end
        assert_redirected_to books_root_path
      end
```

Note: an empty-string `edition_type` fails the model's `validates :edition_type, presence: true` (Rails coerces `""` to `nil` for the enum on assignment), so `create` renders `:unprocessable_entity` rather than raising.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: FAIL — `new`/`create` actions missing.

- [ ] **Step 3: Add `new`, `create`, and `edition_params`**

In `web-app/app/controllers/admin/books/editions_controller.rb`, extend `set_book`'s `only:` list and add the actions + params. The controller now reads:

```ruby
class Admin::Books::EditionsController < Admin::Books::BaseController
  before_action :set_book, only: [:index, :new, :create]
  before_action :set_edition, only: [:show]
  before_action :authorize_edition, only: [:show]

  def index
    authorize ::Books::Edition
    @editions = @book.editions.includes(:language).order(popularity: :desc, id: :asc)
    render layout: false
  end

  def show
  end

  def new
    @edition = @book.editions.build
    authorize @edition
  end

  def create
    @edition = @book.editions.build(edition_params)
    authorize @edition

    if @edition.save
      redirect_to admin_books_edition_path(@edition), notice: "Edition created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:book_id])
  end

  def set_edition
    @edition = ::Books::Edition.find(params[:id])
  end

  def authorize_edition
    authorize @edition
  end

  def edition_params
    params.require(:books_edition).permit(
      :title, :subtitle, :edition_type, :book_binding,
      :publication_year, :publisher_name, :page_count,
      :volume_number, :language_id, :popularity
    )
  end
end
```

- [ ] **Step 4: Create the form partial**

Create `web-app/app/views/admin/books/editions/_form.html.erb`:

```erb
<%= form_with model: @edition, url: (@edition.persisted? ? admin_books_edition_path(@edition) : admin_books_book_editions_path(@book)), class: "space-y-6" do |f| %>
  <% if @edition.errors.any? %>
    <div class="alert alert-error">
      <div>
        <h3 class="font-bold"><%= pluralize(@edition.errors.count, "error") %> prohibited this edition from being saved:</h3>
        <ul class="list-disc list-inside mt-2">
          <% @edition.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">Edition Details</h2>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <%= f.label :edition_type, class: "label" do %>
            <span class="label-text font-semibold">Type <span class="text-error">*</span></span>
          <% end %>
          <%= f.select :edition_type,
              ::Books::Edition.edition_types.keys.map { |k| [k.titleize, k] },
              {},
              class: "select select-bordered w-full #{@edition.errors[:edition_type].any? ? 'select-error' : ''}",
              required: true %>
          <% if @edition.errors[:edition_type].any? %>
            <label class="label"><span class="label-text-alt text-error"><%= @edition.errors[:edition_type].first %></span></label>
          <% end %>
        </div>

        <div class="form-control">
          <%= f.label :book_binding, class: "label" do %>
            <span class="label-text font-semibold">Binding</span>
          <% end %>
          <%= f.select :book_binding,
              ::Books::Edition.book_bindings.keys.map { |k| [k.titleize, k] },
              {include_blank: "—"},
              class: "select select-bordered w-full" %>
        </div>

        <div class="form-control md:col-span-2">
          <%= f.label :title, class: "label" do %>
            <span class="label-text font-semibold">Title</span>
          <% end %>
          <%= f.text_field :title, class: "input input-bordered w-full", placeholder: "Leave blank to use the book title" %>
        </div>

        <div class="form-control md:col-span-2">
          <%= f.label :subtitle, class: "label" do %>
            <span class="label-text font-semibold">Subtitle</span>
          <% end %>
          <%= f.text_field :subtitle, class: "input input-bordered w-full" %>
        </div>

        <div class="form-control">
          <%= f.label :publication_year, class: "label" do %>
            <span class="label-text font-semibold">Publication Year</span>
          <% end %>
          <%= f.number_field :publication_year, class: "input input-bordered w-full", min: -3000, max: 3000 %>
        </div>

        <div class="form-control">
          <%= f.label :publisher_name, class: "label" do %>
            <span class="label-text font-semibold">Publisher</span>
          <% end %>
          <%= f.text_field :publisher_name, class: "input input-bordered w-full" %>
        </div>

        <div class="form-control">
          <%= f.label :page_count, class: "label" do %>
            <span class="label-text font-semibold">Page Count</span>
          <% end %>
          <%= f.number_field :page_count, class: "input input-bordered w-full", min: 0 %>
        </div>

        <div class="form-control">
          <%= f.label :volume_number, class: "label" do %>
            <span class="label-text font-semibold">Volume Number</span>
          <% end %>
          <%= f.number_field :volume_number, class: "input input-bordered w-full", min: 0 %>
        </div>

        <div class="form-control">
          <%= f.label :language_id, class: "label" do %>
            <span class="label-text font-semibold">Language</span>
          <% end %>
          <%= f.collection_select :language_id, Language.order(:name), :id, :name, {include_blank: "—"}, class: "select select-bordered w-full" %>
        </div>

        <div class="form-control">
          <%= f.label :popularity, class: "label" do %>
            <span class="label-text font-semibold">Popularity</span>
          <% end %>
          <%= f.number_field :popularity, class: "input input-bordered w-full" %>
        </div>
      </div>
    </div>
  </div>

  <div class="flex flex-col sm:flex-row gap-2 justify-end">
    <%= link_to "Cancel", (@edition.persisted? ? admin_books_edition_path(@edition) : admin_books_book_path(@book)), class: "btn btn-ghost" %>
    <%= f.submit(@edition.persisted? ? "Update Edition" : "Create Edition", class: "btn btn-primary") %>
  </div>
<% end %>
```

- [ ] **Step 5: Create the new view**

Create `web-app/app/views/admin/books/editions/new.html.erb`:

```erb
<% content_for :title, "New Edition" %>

<div class="max-w-3xl space-y-6">
  <h1 class="text-3xl font-bold">New Edition</h1>
  <p class="text-base-content/60">for <%= link_to @book.title, admin_books_book_path(@book), class: "link" %></p>
  <%= render "form" %>
</div>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/editions_controller.rb
git add app/controllers/admin/books/editions_controller.rb app/views/admin/books/editions/_form.html.erb app/views/admin/books/editions/new.html.erb test/controllers/admin/books/editions_controller_test.rb
git commit -m "Add edition create with the full edition form"
```

---

### Task 4: Edit + update + destroy

**Files:**
- Modify: `web-app/app/controllers/admin/books/editions_controller.rb` (add `edit`, `update`, `destroy`; extend before_action lists)
- Create: `web-app/app/views/admin/books/editions/edit.html.erb`
- Test: `web-app/test/controllers/admin/books/editions_controller_test.rb` (append edit/update/destroy tests)

**Interfaces:**
- Consumes: `_form` (Task 3), `set_edition`/`authorize_edition`/`edition_params` (Tasks 2–3).
- Produces: `update` redirects to the edition show page; `destroy` redirects to the parent book show page and lets the `default_edition_id` FK nullify.

- [ ] **Step 1: Write the failing edit/update/destroy tests**

Append inside the test class:

```ruby
      # Edit / update

      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_edition_path(@edition)
        assert_response :success
      end

      test "update changes the edition and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_edition_path(@edition), params: {books_edition: {publisher_name: "Revised House"}}
        assert_redirected_to admin_books_edition_path(@edition)
        assert_equal "Revised House", @edition.reload.publisher_name
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_edition_path(@edition), params: {books_edition: {edition_type: ""}}
        assert_response :unprocessable_entity
        assert @edition.reload.edition_type.present?
      end

      # Destroy

      test "destroy deletes the edition and redirects to the book" do
        edition = @book.editions.create!(edition_type: "revised")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Edition.count", -1) do
          delete admin_books_edition_path(edition)
        end
        assert_redirected_to admin_books_book_path(@book)
      end

      test "destroying the default edition nullifies the book's default_edition_id" do
        @book.update!(default_edition: @edition)
        sign_in_as(@admin_user, stub_auth: true)
        delete admin_books_edition_path(@edition)
        assert_nil @book.reload.default_edition_id
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Edition.count") do
          delete admin_books_edition_path(@edition)
        end
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: FAIL — `edit`/`update`/`destroy` actions missing.

- [ ] **Step 3: Add `edit`, `update`, `destroy`**

In `web-app/app/controllers/admin/books/editions_controller.rb`, extend the two before_action `only:` lists to include the new actions and add the methods. The `before_action` lines become:

```ruby
  before_action :set_edition, only: [:show, :edit, :update, :destroy]
  before_action :authorize_edition, only: [:show, :edit, :update, :destroy]
```

and add these methods (after `create`, before `private`):

```ruby
  def edit
  end

  def update
    if @edition.update(edition_params)
      redirect_to admin_books_edition_path(@edition), notice: "Edition updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    book = @edition.book
    @edition.destroy!
    redirect_to admin_books_book_path(book), notice: "Edition deleted."
  end
```

- [ ] **Step 4: Create the edit view**

Create `web-app/app/views/admin/books/editions/edit.html.erb`:

```erb
<% content_for :title, "Edit Edition" %>

<div class="max-w-3xl space-y-6">
  <h1 class="text-3xl font-bold">Edit Edition</h1>
  <p class="text-base-content/60">for <%= link_to @edition.book.title, admin_books_book_path(@edition.book), class: "link" %></p>
  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/editions_controller.rb
git add app/controllers/admin/books/editions_controller.rb app/views/admin/books/editions/edit.html.erb test/controllers/admin/books/editions_controller_test.rb
git commit -m "Add edition edit, update, and destroy"
```

---

### Task 5: set_default

**Files:**
- Modify: `web-app/app/controllers/admin/books/editions_controller.rb` (add `set_default`; extend before_action lists)
- Test: `web-app/test/controllers/admin/books/editions_controller_test.rb` (append set_default tests)

**Interfaces:**
- Consumes: `set_edition`/`authorize_edition` (Tasks 2–4); the `set_default` route + the `★ Default` badges / "Set default" buttons already wired into the Task 1 index frame and the Task 2 show page.
- Produces: `set_default` writes `book.default_edition_id` and redirects to the book show page.

- [ ] **Step 1: Write the failing set_default tests**

Append inside the test class:

```ruby
      # Set default

      test "set_default writes the book's default_edition_id and redirects to the book" do
        @book.update!(default_edition_id: nil)
        sign_in_as(@admin_user, stub_auth: true)
        post set_default_admin_books_edition_path(@edition)
        assert_redirected_to admin_books_book_path(@book)
        assert_equal @edition.id, @book.reload.default_edition_id
      end

      test "set_default is forbidden for a regular user" do
        @book.update!(default_edition_id: nil)
        sign_in_as(@regular_user, stub_auth: true)
        post set_default_admin_books_edition_path(@edition)
        assert_redirected_to books_root_path
        assert_nil @book.reload.default_edition_id
      end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: FAIL — `set_default` action missing.

- [ ] **Step 3: Add `set_default`**

In `web-app/app/controllers/admin/books/editions_controller.rb`, add `:set_default` to the two before_action `only:` lists:

```ruby
  before_action :set_edition, only: [:show, :edit, :update, :destroy, :set_default]
  before_action :authorize_edition, only: [:show, :edit, :update, :destroy, :set_default]
```

and add the method (after `destroy`, before `private`):

```ruby
  def set_default
    @edition.book.update!(default_edition_id: @edition.id)
    redirect_to admin_books_book_path(@edition.book), notice: "Default edition updated."
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/editions_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/editions_controller.rb
git add app/controllers/admin/books/editions_controller.rb test/controllers/admin/books/editions_controller_test.rb
git commit -m "Add set_default to write the book's default edition"
```

---

### Task 6: Playwright smoke spec

**Files:**
- Create: `web-app/e2e/tests/books/admin/editions.spec.ts`

**Interfaces:**
- Consumes: the whole 4b flow (book show → new edition → edition show → set default). Runs against the **dev** database (not fixtures), so it creates its own book first.

- [ ] **Step 1: Write the smoke spec**

Create `web-app/e2e/tests/books/admin/editions.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('books admin — editions', () => {
  test('create an edition from a book and set it as default', async ({ page }) => {
    // Create a fresh book to attach an edition to.
    await page.goto('/admin/books/new');
    const title = `E2E Edition Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole('button', { name: 'Create Book' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();

    // Add an edition from the book show page.
    await page.getByRole('link', { name: '+ New Edition' }).click();
    await expect(page.getByRole('heading', { name: 'New Edition' })).toBeVisible();
    await page.locator('input[name="books_edition[publisher_name]"]').fill('E2E Press');
    await page.locator('input[name="books_edition[publication_year]"]').fill('2011');
    await page.getByRole('button', { name: 'Create Edition' }).click();

    // Lands on the edition show page.
    await expect(page.getByText('Edition of')).toBeVisible();
    await expect(page.getByText('E2E Press')).toBeVisible();

    // Set it as the book's default; redirects to the book show page where the
    // lazy editions frame shows the ★ Default badge.
    await page.getByRole('button', { name: 'Set as default' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();
    await expect(page.getByText('★ Default')).toBeVisible();
  });
});
```

- [ ] **Step 2: Run the spec against the local dev server**

Ensure the dev server is running (`bin/dev`) and the e2e admin user has its role (`bin/rails e2e:admin` if admin specs are redirecting to the public homepage). Then:

Run: `yarn test:e2e e2e/tests/books/admin/editions.spec.ts`
Expected: PASS (1 test).

- [ ] **Step 3: Commit**

```bash
git add e2e/tests/books/admin/editions.spec.ts
git commit -m "Add a Playwright smoke spec for the editions admin flow"
```

---

## Verification

After all tasks, from `web-app/`:

- [ ] **Full controller + registry + policy scope:** `bin/rails test test/controllers/admin/books/ test/lib/admin/domain_routing_test.rb test/policies/books/` — all green.
- [ ] **Whole suite (no regressions):** `bin/rails db:test:prepare && bin/rails test` — green, count ≥ the pre-4b baseline (4622).
- [ ] **Lint:** `bundle exec standardrb` — clean.
- [ ] **Security:** `bin/brakeman --no-pager` — no new warnings.
- [ ] **E2E:** `yarn test:e2e e2e/tests/books/admin/editions.spec.ts` — green (dev server up).
- [ ] **Manual smoke (browser, books host):** open a book's show page → the Editions card lazy-loads → add an edition → land on its show page → upload a cover image → set it default → back on the book, the "Default:" line and `★ Default` badge reflect it → delete the default edition → the book's "Default:" line falls back to "—".

## Out of scope (do NOT build here)

- Credits on the edition show page, BookAuthors, BookRelationships, the author-search endpoint — **increment 4c**.
- Any `Admin::DomainNav` change (editions have no sidebar link — D5).
- Fixing the shared `Admin::ImagesController`'s lack of `DomainScopedAuth` (domain-only editors still can't manage images) — pre-existing cross-domain follow-up, same as 4a.
- Edition search/typeahead, categories on editions, `metadata` editing.
