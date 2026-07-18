# Books Admin 5b — Series CRUD + inline SeriesBooks + representative_book + images — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A full `Books::Series` admin at `/admin/series` on the books host — SQL-`ILIKE` index, full CRUD, and a show page that manages the series' books (`Books::SeriesBook`) inline with a book typeahead, `position`/`numbered`/`position_label`, and a per-row "Make representative" that sets `representative_book_id`. Plus series images.

**Architecture:** Series CRUD is a mirror of the merged 5a `Admin::Books::AuthorsController` **minus its search action** — the index filters via SQL `ILIKE` on `title` (D10; Series is not `SearchIndexable`). Inline `SeriesBooks` mirror 5a's `AuthorRelationshipsController` (nested create, shallow update/destroy, turbo_stream, parent authorized via `SeriesPolicy#update?`) plus a `make_representative` member action modeled on editions' `set_default`. Series images ride the shared `Admin::ImagesController` via `NESTED_PARENTS[:books][:series_id]`.

**Tech Stack:** Rails 8, Pundit, Pagy, Turbo Frames/Streams, ViewComponents (`Admin::SearchComponent`, `AutocompleteComponent`), DaisyUI 5 / Tailwind 4, Minitest + Mocha + fixtures, Playwright.

## Global Constraints

- Run **all** commands from `web-app/`.
- Lint with `bundle exec standardrb` (NOT rubocop). Do **not** run brakeman (the owner does not use it).
- No model/schema changes — all models exist.
- **`raise_on_missing_callback_actions` is ON** — never name an action in a `before_action only: […]` list before that action is defined. Grow the lists per task.
- **DaisyUI-5 form pattern** = `<div class="form-control">` + `f.label class:"label"` + `w-full` inputs inside a `card` (mirror `app/views/admin/books/authors/_form.html.erb`), NOT `<label class="form-control">`.
- **Row-action columns** = `<div class="flex items-center justify-end gap-1">` + `btn btn-outline btn-xs whitespace-nowrap` (Remove/Delete: `+ btn-error`).
- **No categories** anywhere (Series has no categories association at all).
- **Inline association controllers authorize the parent explicitly** — `authorize @series, :update?, policy_class: ::Books::SeriesPolicy` — in every action including `make_representative`. Never a bare `authorize @series`.
- **Do not double-wrap the turbo frame** — the show-page "Books in Series" card renders the `_series_books_list` partial directly; the partial opens `turbo_frame_tag "series_books_list"` exactly once.
- **⚠️ `series` is a Rails uncountable noun (singular == plural).** `resources :series` names the **index** helper `admin_books_series_index_path`; show/create/update/destroy use `admin_books_series_path(record)`. Use `_index` for the collection everywhere (nav item, index view links + search form, `_table` sort links, controller redirects to the collection). Task 1 verifies the exact helper names with `bin/rails routes -g series` before wiring views.
- **Verification per task:** `bin/rails test test/controllers/admin/books/ test/lib/admin/` (scoped) then the full suite before final review; `bundle exec standardrb` clean. Never claim done without running the commands and seeing the output.

**Fixtures used** (verify names before referencing): `users(:admin_user)`, `users(:regular_user)`; `books_series(:asoiaf)` (A Song of Ice and Fire, `representative_book_id` nil); `books_series_books(:asoiaf_got)` (book `got`, position 1.0, numbered), `books_series_books(:asoiaf_novella)` (book `crime_and_punishment`, position 1.5, not numbered), `books_series_books(:asoiaf_clash)` (book `clash`, position 2.0); `books_books(:got)`, `books_books(:clash)`, `books_books(:war_and_peace)`, `books_books(:crime_and_punishment)`.

---

### Task 1: Routes, registry, nav, series index (SQL ILIKE), index views

**Files:**
- Modify: `web-app/config/routes.rb` (add the series block inside `namespace :admin, module: "admin/books", as: "admin_books"`)
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`ENTITIES`, `NESTED_PARENTS[:books]`)
- Modify: `web-app/app/lib/admin/domain_nav.rb` (`CONFIGS[:books][:items]`)
- Create: `web-app/app/controllers/admin/books/series_controller.rb`
- Create: `web-app/app/views/admin/books/series/index.html.erb`
- Create: `web-app/app/views/admin/books/series/_table.html.erb`
- Test: `web-app/test/controllers/admin/books/series_controller_test.rb`
- Test: `web-app/test/lib/admin/domain_routing_test.rb` (extend)
- Test: `web-app/test/lib/admin/domain_nav_test.rb` (extend)

**Interfaces:**
- Consumes: `pagy`, `Admin::SearchComponent`.
- Produces: routes `admin_books_series_index_path` (index), `admin_books_series_path` (show/create/update/destroy), `new_admin_books_series_path`, `edit_admin_books_series_path`, `admin_books_series_images_path`, `admin_books_series_series_books_path(series)`, `admin_books_series_book_path(sb)`, `make_representative_admin_books_series_book_path(sb)`; `ENTITIES["Books::Series"]`, `NESTED_PARENTS[:books][:series_id]`; `SeriesController#index` (sets `@series_collection` + `@pagy`); `_table` partial (locals `series_collection:`, `pagy:`).

**Mirror note:** `Admin::Games::SeriesController` is an existing, proven mirror for this whole task (same uncountable-noun routing, same `sanitize_sql_like` + `ILIKE` search, same `@series_collection` index variable). Verified: `Games::Series.sanitize_sql_like` is callable from the controller, and games' route helpers are exactly `admin_games_series_index` (index) / `admin_games_series` (show). Single records use `@series` (as games does in show/new/create/edit/update/destroy); only the index collection is `@series_collection`.

- [ ] **Step 1: Add the routes** — in `web-app/config/routes.rb`, inside the `namespace :admin, module: "admin/books", as: "admin_books"` block, add (place it after the `resources :authors …` block, before the closing `end`):

```ruby
      resources :series do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :series_books, only: [:create]
      end
      resources :series_books, only: [:update, :destroy] do
        member do
          post :make_representative
        end
      end
```

- [ ] **Step 2: Verify the uncountable-noun route helper names**

Run: `cd web-app && bin/rails routes -g series`
Expected: confirm the index route is named `admin_books_series_index` (path `/admin/series`), show/update/destroy `admin_books_series` (`/admin/series/:id`), new `new_admin_books_series`, edit `edit_admin_books_series`, plus `admin_books_series_series_books` (nested create), `admin_books_series_book` (shallow update/destroy), `make_representative_admin_books_series_book`. If any helper differs, use the actual names from this output throughout the task.

- [ ] **Step 3: Write the failing tests** — create `web-app/test/controllers/admin/books/series_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class SeriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @series = books_series(:asoiaf)
        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_series_index_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_index_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      # Index behavior (SQL ILIKE — no OpenSearch, no stubbing; mirrors games series tests)

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      test "index with a matching query renders successfully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path(q: "song of ice")
        assert_response :success
      end

      test "index with a non-matching query renders successfully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious query without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_series_index_path(q: "100%_off'; DROP TABLE books_series; --")
        end
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_series_index_path(sort: "'; DROP TABLE books_series; --")
        end
        assert_response :success
      end
    end
  end
end
```

  Append to `web-app/test/lib/admin/domain_routing_test.rb` (inside the class):

```ruby
    test "domain_for resolves a Books::Series to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_series(:asoiaf))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Series)
    end

    test "path_for resolves a Books::Series admin path" do
      series = books_series(:asoiaf)
      assert_equal "/admin/series/#{series.slug}", Admin::DomainRouting.path_for(series)
    end

    test "parent_from_params resolves a series_id under the books domain" do
      series = books_series(:asoiaf)
      resolved = Admin::DomainRouting.parent_from_params({series_id: series.id}, domain: :books)
      assert_equal series, resolved
    end
```

  Append to `web-app/test/lib/admin/domain_nav_test.rb` (inside the class):

```ruby
    test "the books nav includes a Series item pointing at the index" do
      config = Admin::DomainNav.config_for(:books)
      series_item = config[:items].find { |item| item[:label] == "Series" }
      assert series_item, "books nav is missing a Series item"
      assert_equal "/admin/series", series_item[:path]
      assert series_item[:icon].present?
    end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb`
Expected: FAIL — no `SeriesController`/views, `path_for`/`parent_from_params` nil for series, no Series nav item.

- [ ] **Step 5: Register the entity + nested parent** — in `web-app/app/lib/admin/domain_routing.rb`, add to `ENTITIES` after the `"Books::Author"` entry:

```ruby
      "Books::Series" => {
        domain: :books,
        path: ->(r) { URL_HELPERS.admin_books_series_path(r) },
        category_items_path: nil
      }
```

  And in `NESTED_PARENTS[:books]`, add `series_id`:

```ruby
      books: {
        book_id: "Books::Book",
        edition_id: "Books::Edition",
        author_id: "Books::Author",
        series_id: "Books::Series"
      }
```

- [ ] **Step 6: Add the nav item** — in `web-app/app/lib/admin/domain_nav.rb`, append to `CONFIGS[:books][:items]` (after the `"Authors"` item):

```ruby
          {label: "Series", icon: :series, path: -> { URL_HELPERS.admin_books_series_index_path }}
```

- [ ] **Step 7: Create the controller** — `web-app/app/controllers/admin/books/series_controller.rb`:

```ruby
class Admin::Books::SeriesController < Admin::Books::BaseController
  def index
    authorize ::Books::Series
    load_series_for_index
  end

  private

  def load_series_for_index
    @series_collection = ::Books::Series.all

    if params[:q].present?
      sanitized = "%#{::Books::Series.sanitize_sql_like(params[:q])}%"
      @series_collection = @series_collection.where("title ILIKE ?", sanitized)
    end

    @series_collection = @series_collection.order(sortable_column(params[:sort]))
    @pagy, @series_collection = pagy(@series_collection, limit: 25)
  end

  def sortable_column(column)
    {
      "id" => "books_series.id",
      "title" => "books_series.title",
      "created_at" => "books_series.created_at"
    }.fetch(column, "books_series.title")
  end
end
```

- [ ] **Step 8: Create the index views** — `web-app/app/views/admin/books/series/index.html.erb`:

```erb
<% content_for :title, "Series" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">Series</h1>
    <% if current_user_can_write? %>
      <%= link_to "New Series", new_admin_books_series_path, class: "btn btn-primary" %>
    <% end %>
  </div>

  <%= render Admin::SearchComponent.new(
    url: admin_books_series_index_path,
    placeholder: "Search series by title…",
    value: params[:q],
    turbo_frame: "series_table"
  ) %>

  <%= turbo_frame_tag "series_table" do %>
    <%= render "table", series_collection: @series_collection, pagy: @pagy %>
  <% end %>
</div>
```

  `web-app/app/views/admin/books/series/_table.html.erb`:

```erb
<div class="overflow-x-auto">
  <table class="table table-zebra">
    <thead>
      <tr>
        <th><%= link_to "Title", admin_books_series_index_path(sort: "title", q: params[:q]), data: {turbo_frame: "series_table"} %></th>
        <th><%= link_to "Created", admin_books_series_index_path(sort: "created_at", q: params[:q]), data: {turbo_frame: "series_table"} %></th>
        <th class="text-right">Actions</th>
      </tr>
    </thead>
    <tbody>
      <% if series_collection.any? %>
        <% series_collection.each do |s| %>
          <tr>
            <td><%= link_to s.title, admin_books_series_path(s), data: {turbo_frame: "_top"} %></td>
            <td class="text-sm text-base-content/70"><%= s.created_at.to_date %></td>
            <td class="text-right">
              <div class="flex items-center justify-end gap-1">
                <%= link_to "View", admin_books_series_path(s), class: "btn btn-outline btn-xs whitespace-nowrap", data: {turbo_frame: "_top"} %>
                <% if current_user_can_write? %>
                  <%= link_to "Edit", edit_admin_books_series_path(s), class: "btn btn-outline btn-xs whitespace-nowrap", data: {turbo_frame: "_top"} %>
                <% end %>
                <% if current_user_can_delete? %>
                  <%= button_to "Delete", admin_books_series_path(s), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", form: {class: "inline", data: {turbo_frame: "_top", turbo_confirm: "Delete #{s.title}? This cannot be undone."}} %>
                <% end %>
              </div>
            </td>
          </tr>
        <% end %>
      <% else %>
        <tr>
          <td colspan="3" class="text-center text-base-content/70 py-8">
            <% if params[:q].present? %>
              No series match “<%= params[:q] %>”. <%= link_to "Clear", admin_books_series_index_path, data: {turbo_frame: "series_table"} %>
            <% else %>
              No series yet.
            <% end %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

<% if defined?(pagy) && pagy && pagy.pages > 1 %>
  <div class="mt-4 flex justify-center">
    <%== pagy.series_nav %>
  </div>
<% end %>
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb`
Expected: PASS.

- [ ] **Step 10: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/series_controller.rb app/lib/admin/domain_routing.rb app/lib/admin/domain_nav.rb config/routes.rb
git add config/routes.rb app/lib/admin/domain_routing.rb app/lib/admin/domain_nav.rb app/controllers/admin/books/series_controller.rb app/views/admin/books/series/index.html.erb app/views/admin/books/series/_table.html.erb test/controllers/admin/books/series_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb
git commit -m "Add books series index, routes, registry + nav (inc 5b task 1)"
```

---

### Task 2: Series show page

**Files:**
- Modify: `web-app/app/controllers/admin/books/series_controller.rb` (add `show` + `before_action`s + `set_series`/`authorize_series`)
- Create: `web-app/app/views/admin/books/series/show.html.erb`
- Test: `web-app/test/controllers/admin/books/series_controller_test.rb`

**Interfaces:**
- Consumes: routes + registry from Task 1.
- Produces: `SeriesController#show` (sets `@series` single record); `show.html.erb` (basic info + metadata + Back/Edit/Delete). Tasks 5/6 insert cards into this file.

- [ ] **Step 1: Write the failing tests** — append to `SeriesControllerTest`:

```ruby
      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_path(@series)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_path(@series)
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb -n "/show/"`
Expected: FAIL — `show` action / view missing.

- [ ] **Step 3: Add the `show` action + callbacks** — in `web-app/app/controllers/admin/books/series_controller.rb`, add the `before_action` lines at the top of the class and a `show` method + private helpers. Top of class:

```ruby
class Admin::Books::SeriesController < Admin::Books::BaseController
  before_action :set_series, only: [:show]
  before_action :authorize_series, only: [:show]

  def index
```

  Add `show` after `index`:

```ruby
  def show
  end
```

  Add to the `private` section (after `sortable_column`):

```ruby
  def set_series
    @series = ::Books::Series.find(params[:id])
  end

  def authorize_series
    authorize @series
  end
```

- [ ] **Step 4: Create the show view** — `web-app/app/views/admin/books/series/show.html.erb`:

```erb
<% content_for :title, @series.title %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-3xl font-bold"><%= @series.title %></h1>
    </div>
    <div class="flex gap-2">
      <%= link_to "Back", admin_books_series_index_path, class: "btn btn-ghost" %>
      <% if current_user_can_write? %>
        <%= link_to "Edit", edit_admin_books_series_path(@series), class: "btn btn-primary" %>
      <% end %>
      <% if current_user_can_delete? %>
        <%= button_to "Delete", admin_books_series_path(@series), method: :delete, class: "btn btn-error", form: {data: {turbo_confirm: "Delete this series? This cannot be undone."}} %>
      <% end %>
    </div>
  </div>

  <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2 space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Basic Information</h2>
          <dl class="grid grid-cols-1 gap-4">
            <div><dt class="text-sm text-base-content/60">Description</dt><dd class="whitespace-pre-line"><%= @series.description.presence || "—" %></dd></div>
          </dl>
        </div>
      </div>
    </div>

    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
          <dl class="space-y-2 text-sm">
            <div><dt class="text-base-content/60">ID</dt><dd><%= @series.id %></dd></div>
            <div><dt class="text-base-content/60">Slug</dt><dd><%= @series.slug %></dd></div>
            <div><dt class="text-base-content/60">Created</dt><dd><%= @series.created_at.to_date %></dd></div>
            <div><dt class="text-base-content/60">Updated</dt><dd><%= @series.updated_at.to_date %></dd></div>
          </dl>
        </div>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass** (index still passes — callback-list risk)

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/series_controller.rb
git add app/controllers/admin/books/series_controller.rb app/views/admin/books/series/show.html.erb test/controllers/admin/books/series_controller_test.rb
git commit -m "Add books series show page (inc 5b task 2)"
```

---

### Task 3: New / create + form

**Files:**
- Modify: `web-app/app/controllers/admin/books/series_controller.rb` (add `new`, `create`, `series_params`)
- Create: `web-app/app/views/admin/books/series/_form.html.erb`
- Create: `web-app/app/views/admin/books/series/new.html.erb`
- Test: `web-app/test/controllers/admin/books/series_controller_test.rb`

**Interfaces:**
- Consumes: routes from Task 1.
- Produces: `SeriesController#new`/`#create`; `_form` used by `new` and (Task 4) `edit`.

- [ ] **Step 1: Write the failing tests** — append to `SeriesControllerTest`:

```ruby
      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_series_path
        assert_response :success
      end

      test "create makes a series and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Series.count", 1) do
          post admin_books_series_index_path, params: {books_series: {title: "A Brand New Series", description: "desc"}}
        end
        assert_redirected_to admin_books_series_path(::Books::Series.order(:created_at).last)
      end

      test "create rejects an invalid series" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Series.count") do
          post admin_books_series_index_path, params: {books_series: {title: ""}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Series.count") do
          post admin_books_series_index_path, params: {books_series: {title: "Nope"}}
        end
        assert_redirected_to books_root_path
      end
```

  (Note: `POST /admin/series` is the create route — helper `admin_books_series_index_path` with `post`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb -n "/new|create/"`
Expected: FAIL — `new`/`create` / `_form` missing.

- [ ] **Step 3: Add `new`, `create`, and `series_params`** — in `web-app/app/controllers/admin/books/series_controller.rb`, add after `show`:

```ruby
  def new
    @series = ::Books::Series.new
    authorize @series
  end

  def create
    @series = ::Books::Series.new(series_params)
    authorize @series

    if @series.save
      redirect_to admin_books_series_path(@series), notice: "Series created."
    else
      render :new, status: :unprocessable_entity
    end
  end
```

  Add to the `private` section (after `sortable_column`, before `set_series`):

```ruby
  def series_params
    params.require(:books_series).permit(:title, :description)
  end
```

  (Leave the `before_action` lists as `only: [:show]` — `new`/`create` authorize inline.)

- [ ] **Step 4: Create the form + new views** — `web-app/app/views/admin/books/series/_form.html.erb`:

```erb
<%= form_with model: @series, url: (@series.persisted? ? admin_books_series_path(@series) : admin_books_series_index_path), class: "space-y-6" do |f| %>
  <% if @series.errors.any? %>
    <div class="alert alert-error">
      <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      <div>
        <h3 class="font-bold"><%= pluralize(@series.errors.count, "error") %> prohibited this series from being saved:</h3>
        <ul class="list-disc list-inside mt-2">
          <% @series.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">Basic Information</h2>

      <div class="grid grid-cols-1 gap-4">
        <div class="form-control">
          <%= f.label :title, class: "label" do %>
            <span class="label-text font-semibold">Title <span class="text-error">*</span></span>
          <% end %>
          <%= f.text_field :title,
              class: "input input-bordered w-full #{@series.errors[:title].any? ? 'input-error' : ''}",
              placeholder: "Enter series title",
              required: true,
              autofocus: true %>
          <% if @series.errors[:title].any? %>
            <label class="label"><span class="label-text-alt text-error"><%= @series.errors[:title].first %></span></label>
          <% end %>
        </div>

        <div class="form-control">
          <%= f.label :description, class: "label" do %>
            <span class="label-text font-semibold">Description</span>
          <% end %>
          <%= f.text_area :description, class: "textarea textarea-bordered w-full h-32" %>
        </div>
      </div>
    </div>
  </div>

  <div class="flex flex-col sm:flex-row gap-2 justify-end">
    <%= link_to "Cancel", (@series.persisted? ? admin_books_series_path(@series) : admin_books_series_index_path), class: "btn btn-ghost" %>
    <%= f.submit(@series.persisted? ? "Update Series" : "Create Series", class: "btn btn-primary") %>
  </div>
<% end %>
```

  `web-app/app/views/admin/books/series/new.html.erb`:

```erb
<% content_for :title, "New Series" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">New Series</h1>
    <%= link_to "Back", admin_books_series_index_path, class: "btn btn-ghost" %>
  </div>

  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/series_controller.rb
git add app/controllers/admin/books/series_controller.rb app/views/admin/books/series/_form.html.erb app/views/admin/books/series/new.html.erb test/controllers/admin/books/series_controller_test.rb
git commit -m "Add books series new/create + form (inc 5b task 3)"
```

---

### Task 4: Edit / update / destroy

**Files:**
- Modify: `web-app/app/controllers/admin/books/series_controller.rb` (add `edit`, `update`, `destroy`; grow `before_action` lists)
- Create: `web-app/app/views/admin/books/series/edit.html.erb`
- Test: `web-app/test/controllers/admin/books/series_controller_test.rb`

**Interfaces:**
- Consumes: `_form` + `series_params` (Task 3).
- Produces: full series CRUD. `edit.html.erb` reuses `_form`.

- [ ] **Step 1: Write the failing tests** — append to `SeriesControllerTest`:

```ruby
      # Edit / update / destroy

      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_series_path(@series)
        assert_response :success
      end

      test "update changes the series and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_series_path(@series), params: {books_series: {title: "ASOIAF (Revised)"}}
        assert_redirected_to admin_books_series_path(@series)
        assert_equal "ASOIAF (Revised)", @series.reload.title
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_series_path(@series), params: {books_series: {title: ""}}
        assert_response :unprocessable_entity
        assert @series.reload.title.present?
      end

      test "destroy deletes the series" do
        series = ::Books::Series.create!(title: "Disposable Series")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Series.count", -1) do
          delete admin_books_series_path(series)
        end
        assert_redirected_to admin_books_series_index_path
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Series.count") do
          delete admin_books_series_path(@series)
        end
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb -n "/edit|update|destroy/"`
Expected: FAIL — `edit`/`update`/`destroy` missing.

- [ ] **Step 3: Add the actions + grow callbacks** — in `web-app/app/controllers/admin/books/series_controller.rb`, change the two `before_action` lines to:

```ruby
  before_action :set_series, only: [:show, :edit, :update, :destroy]
  before_action :authorize_series, only: [:show, :edit, :update, :destroy]
```

  Add after `create`:

```ruby
  def edit
  end

  def update
    if @series.update(series_params)
      redirect_to admin_books_series_path(@series), notice: "Series updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @series.destroy!
    redirect_to admin_books_series_index_path, notice: "Series deleted."
  end
```

- [ ] **Step 4: Create the edit view** — `web-app/app/views/admin/books/series/edit.html.erb`:

```erb
<% content_for :title, "Edit #{@series.title}" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">Edit Series</h1>
    <%= link_to "Back", admin_books_series_path(@series), class: "btn btn-ghost" %>
  </div>

  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass** (index/show/create still pass)

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb`
Expected: PASS (full CRUD).

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/series_controller.rb
git add app/controllers/admin/books/series_controller.rb app/views/admin/books/series/edit.html.erb test/controllers/admin/books/series_controller_test.rb
git commit -m "Add books series edit/update/destroy (inc 5b task 4)"
```

---

### Task 5: Series images

**Files:**
- Modify: `web-app/app/views/admin/books/series/show.html.erb` (add Images card + upload modal)
- Test: `web-app/test/controllers/admin/books/series_controller_test.rb`

**Interfaces:**
- Consumes: the images route + `NESTED_PARENTS[:books][:series_id]` (both added in Task 1); the shared `Admin::ImagesController` (unchanged).
- Produces: the series show page renders a lazy `images_list` frame and an upload modal.

- [ ] **Step 1: Write the failing tests** — append to `SeriesControllerTest`:

```ruby
      # Images

      test "the series images index frame renders for the series" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_images_path(@series)
        assert_response :success
      end

      test "uploading an image attaches it to the series via the shared images controller" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_series_images_path(@series), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Cover",
              primary: true
            }
          }
        end
        assert_includes @series.reload.images.map(&:id), Image.order(:created_at).last.id
      end
```

- [ ] **Step 2: Run the tests to verify they fail (or pass — honest note)**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb -n "/image/"`
Expected: These may PASS immediately — Task 1 already added the route + `NESTED_PARENTS[:books][:series_id]`, so the shared `Admin::ImagesController` already works for series (exactly as 5a's image tests were green pre-UI). Note in the report whether they were already green; do NOT fake a RED. This task's real deliverable is the show-page card + modal.

- [ ] **Step 3: Add the Images card to the show page** — in `web-app/app/views/admin/books/series/show.html.erb`, insert the Images card into the right-hand column `<div class="space-y-6">` **before** the Metadata card. Find:

```erb
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
```

  Replace with:

```erb
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Images</h2>
            <% if current_user_can_write? %>
              <button class="btn btn-sm btn-ghost" onclick="add_series_image_modal.showModal()">+ Add</button>
            <% end %>
          </div>
          <%= turbo_frame_tag "images_list", loading: :lazy, src: admin_books_series_images_path(@series) do %>
            <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
```

- [ ] **Step 4: Add the upload modal** — in `web-app/app/views/admin/books/series/show.html.erb`, insert just before the final `</div>` that closes the top-level `<div class="space-y-6">`. Add:

```erb
  <% if current_user_can_write? %>
    <dialog id="add_series_image_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Image</h3>
        <%= form_with model: Image.new, url: admin_books_series_images_path(@series), method: :post, data: {controller: "modal-form", modal_form_modal_id_value: "add_series_image_modal"} do |f| %>
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
            <button type="button" class="btn" onclick="add_series_image_modal.close()">Cancel</button>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
  <% end %>
```

  (Task 6 will add the series-book add modal inside this same `current_user_can_write?` block.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb
git add app/views/admin/books/series/show.html.erb test/controllers/admin/books/series_controller_test.rb
git commit -m "Wire series images into the show page (inc 5b task 5)"
```

---

### Task 6: Inline SeriesBooks + make_representative

**Files:**
- Create: `web-app/app/controllers/admin/books/series_books_controller.rb`
- Create: `web-app/app/views/admin/books/series/_series_books_list.html.erb`
- Modify: `web-app/app/views/admin/books/series/show.html.erb` (add the "Books in Series" card + add modal)
- Test: `web-app/test/controllers/admin/books/series_books_controller_test.rb`

**Interfaces:**
- Consumes: routes `admin_books_series_series_books_path`, `admin_books_series_book_path`, `make_representative_admin_books_series_book_path`, `search_admin_books_books_path` (Task 1); `SeriesPolicy`; `AutocompleteComponent`; `admin/shared/flash`.
- Produces: `SeriesBooksController` (create/update/destroy/make_representative, turbo_stream + html); `_series_books_list` partial (frame `series_books_list`, local `series:`).

- [ ] **Step 1: Write the failing tests** — create `web-app/test/controllers/admin/books/series_books_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class SeriesBooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @series = books_series(:asoiaf)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a series book and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        book = books_books(:war_and_peace)
        assert_difference("@series.series_books.count", 1) do
          post admin_books_series_series_books_path(@series), params: {books_series_book: {book_id: book.id, position: "3", numbered: "1", position_label: "Book 3"}}
        end
        assert_redirected_to admin_books_series_path(@series)
        assert_equal book.id, @series.series_books.order(:created_at).last.book_id
      end

      test "create rejects a duplicate book in the series" do
        sign_in_as(@admin_user, stub_auth: true)
        existing = @series.series_books.first.book
        assert_no_difference("::Books::SeriesBook.count") do
          post admin_books_series_series_books_path(@series), params: {books_series_book: {book_id: existing.id, position: "9"}}
        end
        assert_redirected_to admin_books_series_path(@series)
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        book = books_books(:war_and_peace)
        assert_no_difference("::Books::SeriesBook.count") do
          post admin_books_series_series_books_path(@series), params: {books_series_book: {book_id: book.id, position: "3"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the position" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = books_series_books(:asoiaf_got)
        patch admin_books_series_book_path(sb), params: {books_series_book: {position: "5", numbered: "0", position_label: "Prequel"}}
        assert_redirected_to admin_books_series_path(@series)
        assert_equal 5.0, sb.reload.position
        assert_equal false, sb.numbered
      end

      test "destroy removes the series book" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = @series.series_books.create!(book: books_books(:war_and_peace), position: 4)
        assert_difference("::Books::SeriesBook.count", -1) do
          delete admin_books_series_book_path(sb)
        end
        assert_redirected_to admin_books_series_path(@series)
      end

      test "make_representative sets the series representative_book" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = books_series_books(:asoiaf_clash)
        post make_representative_admin_books_series_book_path(sb)
        assert_redirected_to admin_books_series_path(@series)
        assert_equal sb.book_id, @series.reload.representative_book_id
      end

      test "make_representative is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        sb = books_series_books(:asoiaf_clash)
        post make_representative_admin_books_series_book_path(sb)
        assert_redirected_to books_root_path
        assert_nil @series.reload.representative_book_id
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_books_controller_test.rb`
Expected: FAIL — `SeriesBooksController` / partial missing.

- [ ] **Step 3: Create the controller** — `web-app/app/controllers/admin/books/series_books_controller.rb`:

```ruby
class Admin::Books::SeriesBooksController < Admin::Books::BaseController
  before_action :set_series_book, only: [:update, :destroy, :make_representative]

  def create
    @series = ::Books::Series.find(params[:series_id])
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    @series_book = @series.series_books.build(series_book_params)

    if @series_book.save
      respond_to do |format|
        format.turbo_stream { render_series_books("Book added to series.") }
        format.html { redirect_to admin_books_series_path(@series), notice: "Book added to series." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@series_book) }
        format.html { redirect_to admin_books_series_path(@series), alert: @series_book.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy

    if @series_book.update(series_book_params)
      respond_to do |format|
        format.turbo_stream { render_series_books("Series book updated.") }
        format.html { redirect_to admin_books_series_path(@series), notice: "Series book updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@series_book) }
        format.html { redirect_to admin_books_series_path(@series), alert: @series_book.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    @series_book.destroy!

    respond_to do |format|
      format.turbo_stream { render_series_books("Book removed from series.") }
      format.html { redirect_to admin_books_series_path(@series), notice: "Book removed from series." }
    end
  end

  def make_representative
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    @series.update!(representative_book_id: @series_book.book_id)

    respond_to do |format|
      format.turbo_stream { render_series_books("Representative book updated.") }
      format.html { redirect_to admin_books_series_path(@series), notice: "Representative book updated." }
    end
  end

  private

  def set_series_book
    @series_book = ::Books::SeriesBook.find(params[:id])
  end

  def series_book_params
    params.require(:books_series_book).permit(:book_id, :position, :numbered, :position_label)
  end

  def render_series_books(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("series_books_list", partial: "admin/books/series/series_books_list", locals: {series: @series})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
```

- [ ] **Step 4: Create the list partial** — `web-app/app/views/admin/books/series/_series_books_list.html.erb`:

```erb
<%= turbo_frame_tag "series_books_list" do %>
  <p class="text-sm text-base-content/70 mb-3">
    Representative:
    <% if series.representative_book %>
      <%= link_to series.representative_book.title, admin_books_book_path(series.representative_book), class: "link", data: {turbo_frame: "_top"} %>
    <% else %>
      —
    <% end %>
  </p>

  <% if series.series_books.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr><th>#</th><th>Book</th><th>Numbered</th><th>Label</th><th class="text-right">Actions</th></tr>
        </thead>
        <tbody>
          <% series.series_books.includes(:book).each do |sb| %>
            <tr>
              <td><%= sb.position %></td>
              <td>
                <%= link_to sb.book.title, admin_books_book_path(sb.book), class: "link link-hover", data: {turbo_frame: "_top"} %>
                <% if series.representative_book_id == sb.book_id %>
                  <span class="badge badge-primary badge-sm ml-1">★ Representative</span>
                <% end %>
              </td>
              <td><%= sb.numbered? ? "Yes" : "No" %></td>
              <td class="text-sm text-base-content/70"><%= sb.position_label.presence || "—" %></td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-1">
                  <% if current_user_can_write? %>
                    <% if series.representative_book_id != sb.book_id %>
                      <%= button_to "★ Make representative", make_representative_admin_books_series_book_path(sb), method: :post, class: "btn btn-outline btn-xs whitespace-nowrap", form: {data: {turbo_frame: "series_books_list"}} %>
                    <% end %>
                    <button class="btn btn-outline btn-xs whitespace-nowrap" onclick="edit_series_book_<%= sb.id %>_modal.showModal()">Edit</button>
                    <%= button_to "Remove", admin_books_series_book_path(sb), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", data: {turbo_confirm: "Remove this book from the series?"}, form: {data: {turbo_frame: "series_books_list"}} %>
                  <% end %>
                </div>
              </td>
            </tr>

            <% if current_user_can_write? %>
              <dialog id="edit_series_book_<%= sb.id %>_modal" class="modal">
                <div class="modal-box">
                  <h3 class="font-bold text-lg mb-4">Edit Series Book</h3>
                  <%= form_with model: sb, url: admin_books_series_book_path(sb), method: :patch, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "edit_series_book_#{sb.id}_modal", turbo_frame: "series_books_list"} do |f| %>
                    <div class="form-control">
                      <%= f.label :position, class: "label" do %><span class="label-text font-semibold">Position</span><% end %>
                      <%= f.number_field :position, step: "0.01", class: "input input-bordered w-full" %>
                    </div>
                    <div class="form-control">
                      <label class="label cursor-pointer justify-start gap-2">
                        <%= f.check_box :numbered, class: "checkbox" %>
                        <span class="label-text font-semibold">Numbered</span>
                      </label>
                    </div>
                    <div class="form-control">
                      <%= f.label :position_label, class: "label" do %><span class="label-text font-semibold">Position Label</span><% end %>
                      <%= f.text_field :position_label, class: "input input-bordered w-full" %>
                    </div>
                    <div class="modal-action">
                      <button type="button" class="btn" onclick="edit_series_book_<%= sb.id %>_modal.close()">Cancel</button>
                      <%= f.submit "Update", class: "btn btn-primary" %>
                    </div>
                  <% end %>
                </div>
                <form method="dialog" class="modal-backdrop"><button>close</button></form>
              </dialog>
            <% end %>
          <% end %>
        </tbody>
      </table>
    </div>
  <% else %>
    <p class="text-base-content/60 text-sm">No books in this series yet.</p>
  <% end %>
<% end %>
```

- [ ] **Step 5: Add the "Books in Series" card + add modal to the show page** — in `web-app/app/views/admin/books/series/show.html.erb`:

  (a) Insert the card **after** the closing `</div>` of the `grid grid-cols-1 lg:grid-cols-3` block and **before** the `<% if current_user_can_write? %>` image-modal block (added in Task 5). Add:

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Books in Series</h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_series_book_modal.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= render "admin/books/series/series_books_list", series: @series %>
    </div>
  </div>
```

  (b) Add the add-book modal **inside** the existing `<% if current_user_can_write? %>` block from Task 5 (alongside `add_series_image_modal`, before that block's `<% end %>`):

```erb
    <dialog id="add_series_book_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Book to Series</h3>
        <%= form_with model: ::Books::SeriesBook.new, url: admin_books_series_series_books_path(@series), method: :post, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "add_series_book_modal"} do |f| %>
          <div class="form-control">
            <%= f.label :book_id, class: "label" do %><span class="label-text font-semibold">Book <span class="text-error">*</span></span><% end %>
            <%= render AutocompleteComponent.new(name: "books_series_book[book_id]", url: search_admin_books_books_path, placeholder: "Search for a book…", required: true) %>
          </div>
          <div class="form-control">
            <%= f.label :position, class: "label" do %><span class="label-text font-semibold">Position</span><% end %>
            <%= f.number_field :position, value: @series.series_books.maximum(:position).to_i + 1, step: "0.01", class: "input input-bordered w-full" %>
          </div>
          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-2">
              <%= f.check_box :numbered, checked: true, class: "checkbox" %>
              <span class="label-text font-semibold">Numbered</span>
            </label>
          </div>
          <div class="form-control">
            <%= f.label :position_label, class: "label" do %><span class="label-text font-semibold">Position Label</span><% end %>
            <%= f.text_field :position_label, class: "input input-bordered w-full" %>
          </div>
          <div class="modal-action">
            <button type="button" class="btn" onclick="add_series_book_modal.close()">Cancel</button>
            <%= f.submit "Add Book", class: "btn btn-primary" %>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/series_books_controller_test.rb test/controllers/admin/books/series_controller_test.rb`
Expected: PASS (series-book CRUD + make_representative + all prior series tests).

- [ ] **Step 7: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/series_books_controller.rb
git add app/controllers/admin/books/series_books_controller.rb app/views/admin/books/series/_series_books_list.html.erb app/views/admin/books/series/show.html.erb test/controllers/admin/books/series_books_controller_test.rb
git commit -m "Add inline series books + make_representative (inc 5b task 6)"
```

---

### Task 7: Playwright smoke spec

**Files:**
- Create: `web-app/e2e/tests/books/admin/series.spec.ts`

**Interfaces:**
- Consumes: the live books admin (`books-admin` Playwright project), the live book OpenSearch index (typeahead).

- [ ] **Step 1: Ensure the dev book index is populated** (the add-book typeahead exercises the live book index)

Run: `cd web-app && bin/rails runner 'puts Search::Books::Search::BookAutocomplete.call("war", size: 5, book_kind: nil).length'`
Expected: a nonzero count. If it prints 0, run `bin/rails search:books:recreate_and_reindex_all` and wait for it to finish.

- [ ] **Step 2: Write the spec** — `web-app/e2e/tests/books/admin/series.spec.ts` (mirror `books.spec.ts` + the `associations.spec.ts`/`authors.spec.ts` typeahead pattern; unique series title; name-based selectors where `getByLabel` is ambiguous):

```typescript
import { test, expect } from "@playwright/test";

test.describe("Books admin — series", () => {
  test("lists series and links to New Series", async ({ page }) => {
    await page.goto("/admin/series");
    await expect(page.getByRole("heading", { name: "Series", level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "New Series" })).toBeVisible();
  });

  test("creates a series and shows it", async ({ page }) => {
    const title = `Test Series ${Date.now()}`;
    await page.goto("/admin/series");
    await page.getByRole("link", { name: "New Series" }).click();

    await page.locator('input[name="books_series[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Series" }).click();

    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();
  });

  test("adds a book to the series and makes it representative", async ({ page }) => {
    const title = `Rep Series ${Date.now()}`;
    await page.goto("/admin/series");
    await page.getByRole("link", { name: "New Series" }).click();
    await page.locator('input[name="books_series[title]"]').fill(title);
    await page.getByRole("button", { name: "Create Series" }).click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();

    // Add a book via the typeahead
    await page.getByRole("button", { name: "+ Add" }).last().click();
    const modal = page.locator("dialog#add_series_book_modal");
    await expect(modal).toBeVisible();
    await modal.getByPlaceholder("Search for a book…").fill("War and Peace");
    await modal.locator("li.cursor-pointer").first().click();
    await modal.getByRole("button", { name: "Add Book" }).click();

    const frame = page.locator("turbo-frame#series_books_list");
    await expect(frame.getByText("War and Peace", { exact: false })).toBeVisible();

    // Make it representative
    await frame.getByRole("button", { name: "★ Make representative" }).click();
    await expect(frame.getByText("★ Representative")).toBeVisible();
  });
});
```

- [ ] **Step 3: Run the spec** (dev server already running per the books-admin project)

Run: `cd web-app && npx playwright test --config=e2e/playwright.config.ts --project=books-admin series.spec.ts`
Expected: 3 passed. If flaky on the below-the-fold card, add `scrollIntoViewIfNeeded()` before opening the add modal (the editions/authors precedent) — a SPEC fix, not an app change. If a real app bug surfaces, STOP and report BLOCKED.

- [ ] **Step 4: Commit**

```bash
cd web-app && git add e2e/tests/books/admin/series.spec.ts
git commit -m "Add books series Playwright smoke spec (inc 5b task 7)"
```

---

## Final verification (before the whole-branch review)

- [ ] `cd web-app && bin/rails test` — full suite green (0 failures).
- [ ] `cd web-app && bundle exec standardrb` — clean.
- [ ] `cd web-app && npx playwright test --config=e2e/playwright.config.ts --project=books-admin series.spec.ts` — 3/3.
- [ ] Append the increment record to `.superpowers/sdd/progress.md`.
- [ ] (Do NOT run brakeman — the owner does not use it.)

## Self-review notes (traceability to the spec)

- **Series CRUD + SQL ILIKE index** → Tasks 1–4 (`ILIKE` + `sanitize_sql_like`, sort allowlist, pagy 25, no `#search` action, no array field).
- **Inline SeriesBooks** → Task 6 (`SeriesBooksController` mirrors 5a `AuthorRelationshipsController`; parent authorized explicitly `:update?`).
- **make_representative** → Task 6 (member action; sets `representative_book_id`; explicit `:update?` authorize — no `SeriesPolicy` predicate needed; ★ badge + "Representative:" line inside the frame per 5b-4).
- **Series images** → Task 1 (route + `NESTED_PARENTS`) + Task 5 (card + modal + upload test).
- **`DomainNav` "Series" item (via `_index` helper) + `DomainRouting` `ENTITIES`/`NESTED_PARENTS`** → Task 1 (+ tests).
- **No categories / no `#search` / no OpenSearch** → structurally absent throughout.
- **`series_index` uncountable-noun helper** → verified in Task 1 Step 2 and used consistently.
- **Delete/Remove buttons ship with the destroy actions** → `_table` (Task 1), show page (Task 2), series-book Remove (Task 6).
- **Playwright smoke** → Task 7.
