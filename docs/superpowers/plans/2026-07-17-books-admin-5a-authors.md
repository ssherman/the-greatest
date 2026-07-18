# Books Admin 5a — Authors CRUD + inline AuthorRelationships + images — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow the `#search`-only `Admin::Books::AuthorsController` into a full `Books::Author` admin at `/admin/authors` on the books host — OpenSearch-backed index, full CRUD, and a show page that manages the author's relationships and images in place.

**Architecture:** Author CRUD is an exact mirror of 4a's `Admin::Books::BooksController` (OpenSearch `AuthorGeneral` index / `AuthorAutocomplete` typeahead, sort allowlist, pagy 25, `alternate_names_string` comma-split). Inline `AuthorRelationships` mirror 4c's `BookRelationshipsController` (nested create, top-level update/destroy, turbo_stream, parent authorized via `AuthorPolicy#update?`). A read-only "inbound relationships" card renders `inverse_author_relationships`. Author images ride the shared `Admin::ImagesController` via `NESTED_PARENTS[:books][:author_id]`.

**Tech Stack:** Rails 8, Pundit, Pagy, OpenSearch (`Search::Books::*`), Turbo Frames/Streams, ViewComponents (`Admin::SearchComponent`, `AutocompleteComponent`), DaisyUI 5 / Tailwind 4, Minitest + Mocha + fixtures, Playwright.

## Global Constraints

- Run **all** commands from `web-app/`.
- Lint with `bundle exec standardrb` (NOT rubocop). `--fix` autocorrects.
- Namespace all media code (`Books::`). Tests mirror the namespace (`module Admin; module Books`).
- **Skinny models, fat services.** No model changes in this plan — all four models already exist.
- **`raise_on_missing_callback_actions` is ON** — never name an action in a `before_action only: […]` list before that action is defined. Grow the lists per task.
- **DaisyUI-5 form pattern** = `<div class="form-control">` + `f.label class:"label"` + `w-full` inputs inside a `card` (mirror `app/views/admin/books/books/_form.html.erb`), NOT `<label class="form-control">`.
- **Row-action columns** = `<div class="flex items-center justify-end gap-1">` + `btn btn-outline btn-xs whitespace-nowrap` (Remove/Delete: `btn btn-outline btn-error btn-xs whitespace-nowrap`).
- **NO categories section** anywhere on the author pages (deferred to increment 6; `AddCategoryModalComponent` would fall back to the music categories path and STI has no type validation).
- **Search endpoints do NOT call `authorize`** (they would infer a nonexistent `search?` predicate and raise) — they rely on the inherited `authenticate_admin!`.
- **Inline association controllers authorize the parent explicitly** — `authorize @author, :update?, policy_class: ::Books::AuthorPolicy` — never a bare `authorize @author`.
- **Typeaheads use `AuthorAutocomplete`** (edge-ngram `name.autocomplete`); the index page uses `AuthorGeneral`.
- **Do not double-wrap the turbo frame** — the show-page card renders `_author_relationships_list` directly; the partial itself opens `turbo_frame_tag "author_relationships_list"`.
- **Dev prereq:** the author OpenSearch index is empty in dev by default — run `bin/rails search:books:recreate_authors` before exercising the live index/typeahead (unit tests stub the search classes).
- **Verification per task:** `bin/rails test test/controllers/admin/books/ test/lib/admin/` (scoped) then the full suite before final review; `bundle exec standardrb` clean. Never claim done without running the commands.

**Fixtures used** (verify names before referencing): `users(:admin_user)`, `users(:regular_user)`, `users(:editor_user)`; `books_authors(:tolstoy)` (Leo Tolstoy, person, birth 1828/death 1910, `alternate_names` set), `books_authors(:king)` (Stephen King, person, birth 1947), `books_authors(:bachman)` (Richard Bachman, pseudonym), `books_authors(:garnett)` (Constance Garnett); `books_author_relationships(:bachman_is_king)` (bachman `pseudonym_of` king).

---

### Task 1: Routes, registry, nav, author index + search `exclude_id`, index views

**Files:**
- Modify: `web-app/config/routes.rb` (the `resources :authors, only: []` block inside `namespace :admin, module: "admin/books", as: "admin_books"`)
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`ENTITIES`, `NESTED_PARENTS[:books]`)
- Modify: `web-app/app/lib/admin/domain_nav.rb` (`CONFIGS[:books][:items]`)
- Modify: `web-app/app/controllers/admin/books/authors_controller.rb` (add `index` + private index helpers; add `exclude_id` to `search`)
- Create: `web-app/app/views/admin/books/authors/index.html.erb`
- Create: `web-app/app/views/admin/books/authors/_table.html.erb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb` (extend existing)
- Test: `web-app/test/lib/admin/domain_routing_test.rb` (extend existing)
- Test: `web-app/test/lib/admin/domain_nav_test.rb` (extend existing)

**Interfaces:**
- Consumes: `Search::Books::Search::AuthorGeneral.call(q, size:)`, `Search::Books::Search::AuthorAutocomplete.call(q, size:)` (both exist), `pagy`, `Admin::SearchComponent`.
- Produces: routes `admin_books_authors_path`, `admin_books_author_path`, `new_admin_books_author_path`, `edit_admin_books_author_path`, `admin_books_author_images_path`, `admin_books_author_author_relationships_path(author)`, `admin_books_author_relationship_path(rel)`, `search_admin_books_authors_path`; `ENTITIES["Books::Author"]`, `NESTED_PARENTS[:books][:author_id]`; `AuthorsController#index` (sets `@authors`, `@pagy`); `_table` partial (locals `authors:`, `pagy:`).

- [ ] **Step 1: Write the failing tests** — append to `web-app/test/controllers/admin/books/authors_controller_test.rb` inside the existing `AuthorsControllerTest` class (keep the existing `setup` and 3 search tests; add `@regular_user`/`@editor_user` are already set via `users(...)` — add index/auth/exclude_id tests):

```ruby
      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_authors_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_authors_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_authors_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_authors_path
        assert_response :success
      end

      # Index behavior

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_authors_path
        assert_response :success
      end

      test "index with a query loads authors from OpenSearch in relevance order" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([{id: @author.id.to_s, score: 1.0, source: {"name" => @author.name}}])
        get admin_books_authors_path(q: "tol")
        assert_response :success
      end

      test "index with a query that matches nothing does not error" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([])
        get admin_books_authors_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_authors_path(sort: "'; DROP TABLE books_authors; --")
        end
        assert_response :success
      end

      # Typeahead exclude_id

      test "search omits the excluded author id" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        ::Search::Books::Search::AuthorAutocomplete.stubs(:call).returns([{id: @author.id.to_s, score: 1.0, source: {}}, {id: other.id.to_s, score: 0.9, source: {}}])
        get search_admin_books_authors_path(q: "e", exclude_id: @author.id)
        ids = JSON.parse(response.body).map { |r| r["value"] }
        assert_not_includes ids, @author.id
        assert_includes ids, other.id
      end
```

  Append to `web-app/test/lib/admin/domain_routing_test.rb` (inside the class, after the edition tests):

```ruby
    test "domain_for resolves a Books::Author to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_authors(:tolstoy))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Author)
    end

    test "path_for resolves a Books::Author admin path" do
      author = books_authors(:tolstoy)
      assert_equal "/admin/authors/#{author.slug}", Admin::DomainRouting.path_for(author)
    end

    test "parent_from_params resolves an author_id under the books domain" do
      author = books_authors(:tolstoy)
      resolved = Admin::DomainRouting.parent_from_params({author_id: author.id}, domain: :books)
      assert_equal author, resolved
    end
```

  Append to `web-app/test/lib/admin/domain_nav_test.rb` (inside the class):

```ruby
    test "the books nav includes an Authors item" do
      config = Admin::DomainNav.config_for(:books)
      authors_item = config[:items].find { |item| item[:label] == "Authors" }
      assert authors_item, "books nav is missing an Authors item"
      assert_equal "/admin/authors", authors_item[:path]
      assert authors_item[:icon].present?
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb`
Expected: FAIL — the new index tests error (no `index` action / no `_table`), `path_for`/`parent_from_params` return nil for authors, the Authors nav item is missing.

- [ ] **Step 3: Add the routes** — in `web-app/config/routes.rb`, replace the existing authors block. Find:

```ruby
      resources :book_authors, only: [:update, :destroy]
      resources :book_relationships, only: [:update, :destroy]
      resources :credits, only: [:update, :destroy]
      resources :authors, only: [] do
        collection do
          get :search
        end
      end
    end
```

  Replace with (adds top-level `author_relationships` update/destroy; grows `authors` to full CRUD with nested images + relationship-create + search):

```ruby
      resources :book_authors, only: [:update, :destroy]
      resources :book_relationships, only: [:update, :destroy]
      resources :credits, only: [:update, :destroy]
      resources :author_relationships, only: [:update, :destroy]
      resources :authors do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :author_relationships, only: [:create]
        collection do
          get :search
        end
      end
    end
```

- [ ] **Step 4: Register the entity + nested parent** — in `web-app/app/lib/admin/domain_routing.rb`, add to `ENTITIES` after the `"Books::Edition"` entry:

```ruby
      "Books::Author" => {
        domain: :books,
        path: ->(r) { URL_HELPERS.admin_books_author_path(r) },
        category_items_path: nil
      }
```

  And in `NESTED_PARENTS`, change the `books:` hash to include `author_id`:

```ruby
      books: {
        book_id: "Books::Book",
        edition_id: "Books::Edition",
        author_id: "Books::Author"
      }
```

- [ ] **Step 5: Add the nav item** — in `web-app/app/lib/admin/domain_nav.rb`, append to `CONFIGS[:books][:items]` (after the `"Books"` item):

```ruby
          {label: "Authors", icon: :artist, path: -> { URL_HELPERS.admin_books_authors_path }}
```

  (Result: `items: [{label: "Books", …}, {label: "Authors", icon: :artist, path: -> { URL_HELPERS.admin_books_authors_path }}]`.)

- [ ] **Step 6: Add `index` + private helpers and `exclude_id` to the controller** — replace the entire body of `web-app/app/controllers/admin/books/authors_controller.rb` with:

```ruby
class Admin::Books::AuthorsController < Admin::Books::BaseController
  def index
    authorize ::Books::Author
    load_authors_for_index
  end

  def search
    results = ::Search::Books::Search::AuthorAutocomplete.call(params[:q], size: 20)
    author_ids = results.map { |r| r[:id].to_i }
    author_ids.delete(params[:exclude_id].to_i) if params[:exclude_id].present?

    if author_ids.empty?
      render json: []
      return
    end

    authors = ::Books::Author.where(id: author_ids).in_order_of(:id, author_ids)
    render json: authors.map { |a| {value: a.id, text: a.name} }
  end

  private

  def load_authors_for_index
    if params[:q].present?
      results = ::Search::Books::Search::AuthorGeneral.call(params[:q], size: 1000)
      author_ids = results.map { |r| r[:id].to_i }

      @authors = if author_ids.empty?
        ::Books::Author.none
      else
        ::Books::Author.where(id: author_ids).in_order_of(:id, author_ids)
      end
    else
      @authors = ::Books::Author.all.order(sortable_column(params[:sort]))
    end

    @pagy, @authors = pagy(@authors, limit: 25)
  end

  def sortable_column(column)
    {
      "id" => "books_authors.id",
      "name" => "books_authors.name",
      "sort_name" => "books_authors.sort_name",
      "kind" => "books_authors.kind",
      "birth_year" => "books_authors.birth_year",
      "death_year" => "books_authors.death_year",
      "created_at" => "books_authors.created_at"
    }.fetch(column, "books_authors.name")
  end
end
```

- [ ] **Step 7: Create the index views** — `web-app/app/views/admin/books/authors/index.html.erb`:

```erb
<% content_for :title, "Authors" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">Authors</h1>
    <% if current_user_can_write? %>
      <%= link_to "New Author", new_admin_books_author_path, class: "btn btn-primary" %>
    <% end %>
  </div>

  <%= render Admin::SearchComponent.new(
    url: admin_books_authors_path,
    placeholder: "Search authors by name…",
    value: params[:q],
    turbo_frame: "authors_table"
  ) %>

  <%= turbo_frame_tag "authors_table" do %>
    <%= render "table", authors: @authors, pagy: @pagy %>
  <% end %>
</div>
```

  `web-app/app/views/admin/books/authors/_table.html.erb`:

```erb
<div class="overflow-x-auto">
  <table class="table table-zebra">
    <thead>
      <tr>
        <th><%= link_to "Name", admin_books_authors_path(sort: "name", q: params[:q]), data: {turbo_frame: "authors_table"} %></th>
        <th><%= link_to "Sort Name", admin_books_authors_path(sort: "sort_name", q: params[:q]), data: {turbo_frame: "authors_table"} %></th>
        <th><%= link_to "Kind", admin_books_authors_path(sort: "kind", q: params[:q]), data: {turbo_frame: "authors_table"} %></th>
        <th>Years</th>
        <th class="text-right">Actions</th>
      </tr>
    </thead>
    <tbody>
      <% if authors.any? %>
        <% authors.each do |author| %>
          <tr>
            <td><%= link_to author.name, admin_books_author_path(author), data: {turbo_frame: "_top"} %></td>
            <td class="text-sm text-base-content/70"><%= author.sort_name.presence || "—" %></td>
            <td><span class="badge badge-ghost"><%= author.kind.titleize %></span></td>
            <td class="text-sm text-base-content/70">
              <% if author.birth_year.present? || author.death_year.present? %>
                <%= author.birth_year || "?" %>&ndash;<%= author.death_year %>
              <% else %>
                —
              <% end %>
            </td>
            <td class="text-right">
              <div class="flex items-center justify-end gap-1">
                <%= link_to "View", admin_books_author_path(author), class: "btn btn-outline btn-xs whitespace-nowrap", data: {turbo_frame: "_top"} %>
                <% if current_user_can_write? %>
                  <%= link_to "Edit", edit_admin_books_author_path(author), class: "btn btn-outline btn-xs whitespace-nowrap", data: {turbo_frame: "_top"} %>
                <% end %>
                <% if current_user_can_delete? %>
                  <%= button_to "Delete", admin_books_author_path(author), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", form: {class: "inline", data: {turbo_frame: "_top", turbo_confirm: "Delete #{author.name}? This cannot be undone."}} %>
                <% end %>
              </div>
            </td>
          </tr>
        <% end %>
      <% else %>
        <tr>
          <td colspan="5" class="text-center text-base-content/70 py-8">
            <% if params[:q].present? %>
              No authors match “<%= params[:q] %>”. <%= link_to "Clear", admin_books_authors_path, data: {turbo_frame: "authors_table"} %>
            <% else %>
              No authors yet.
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

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb`
Expected: PASS (all author/registry/nav tests green; the pre-existing 3 search tests still pass).

- [ ] **Step 9: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/authors_controller.rb app/lib/admin/domain_routing.rb app/lib/admin/domain_nav.rb config/routes.rb
git add config/routes.rb app/lib/admin/domain_routing.rb app/lib/admin/domain_nav.rb app/controllers/admin/books/authors_controller.rb app/views/admin/books/authors/index.html.erb app/views/admin/books/authors/_table.html.erb test/controllers/admin/books/authors_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb
git commit -m "Add books authors index, routes, registry + nav (inc 5a task 1)"
```

---

### Task 2: Author show page

**Files:**
- Modify: `web-app/app/controllers/admin/books/authors_controller.rb` (add `show` + `before_action`s + `set_author`/`authorize_author`)
- Create: `web-app/app/views/admin/books/authors/show.html.erb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: routes + registry from Task 1.
- Produces: `AuthorsController#show` (sets `@author`); `show.html.erb` (basic info + metadata + Back/Edit/Delete). Later tasks (5, 6) insert cards into this file.

- [ ] **Step 1: Write the failing tests** — append to `AuthorsControllerTest`:

```ruby
      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_path(@author)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_author_path(@author)
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb -n "/show/"`
Expected: FAIL — `show` action / view missing.

- [ ] **Step 3: Add the `show` action + callbacks** — in `web-app/app/controllers/admin/books/authors_controller.rb`, add the `before_action` lines at the very top of the class (immediately after the class definition line) and a `show` method after `search`, plus the two private methods. The top of the class becomes:

```ruby
class Admin::Books::AuthorsController < Admin::Books::BaseController
  before_action :set_author, only: [:show]
  before_action :authorize_author, only: [:show]

  def index
```

  Add `show` after the `search` method:

```ruby
  def show
  end
```

  Add to the `private` section (after `sortable_column`):

```ruby
  def set_author
    @author = ::Books::Author.find(params[:id])
  end

  def authorize_author
    authorize @author
  end
```

- [ ] **Step 4: Create the show view** — `web-app/app/views/admin/books/authors/show.html.erb`:

```erb
<% content_for :title, @author.name %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-3xl font-bold"><%= @author.name %></h1>
      <p class="text-lg text-base-content/70"><%= @author.kind.titleize %></p>
    </div>
    <div class="flex gap-2">
      <%= link_to "Back", admin_books_authors_path, class: "btn btn-ghost" %>
      <% if current_user_can_write? %>
        <%= link_to "Edit", edit_admin_books_author_path(@author), class: "btn btn-primary" %>
      <% end %>
      <% if current_user_can_delete? %>
        <%= button_to "Delete", admin_books_author_path(@author), method: :delete, class: "btn btn-error", form: {data: {turbo_confirm: "Delete this author? This cannot be undone."}} %>
      <% end %>
    </div>
  </div>

  <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2 space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Basic Information</h2>
          <dl class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div><dt class="text-sm text-base-content/60">Kind</dt><dd><%= @author.kind.titleize %></dd></div>
            <div><dt class="text-sm text-base-content/60">Sort Name</dt><dd><%= @author.sort_name.presence || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Birth Year</dt><dd><%= @author.birth_year || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Death Year</dt><dd><%= @author.death_year || "—" %></dd></div>
            <div class="sm:col-span-2"><dt class="text-sm text-base-content/60">Alternate Names</dt><dd><%= @author.alternate_names.present? ? @author.alternate_names.join(", ") : "—" %></dd></div>
            <div class="sm:col-span-2"><dt class="text-sm text-base-content/60">Description</dt><dd class="whitespace-pre-line"><%= @author.description.presence || "—" %></dd></div>
          </dl>
        </div>
      </div>
    </div>

    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
          <dl class="space-y-2 text-sm">
            <div><dt class="text-base-content/60">ID</dt><dd><%= @author.id %></dd></div>
            <div><dt class="text-base-content/60">Slug</dt><dd><%= @author.slug %></dd></div>
            <div><dt class="text-base-content/60">Created</dt><dd><%= @author.created_at.to_date %></dd></div>
            <div><dt class="text-base-content/60">Updated</dt><dd><%= @author.updated_at.to_date %></dd></div>
          </dl>
        </div>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass** (and index/search still pass — the callback-list risk)

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS (show + all prior index/search tests).

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/authors_controller.rb
git add app/controllers/admin/books/authors_controller.rb app/views/admin/books/authors/show.html.erb test/controllers/admin/books/authors_controller_test.rb
git commit -m "Add books author show page (inc 5a task 2)"
```

---

### Task 3: New / create + form

**Files:**
- Modify: `web-app/app/controllers/admin/books/authors_controller.rb` (add `new`, `create`, `author_params`, `assign_author_attributes`)
- Create: `web-app/app/views/admin/books/authors/_form.html.erb`
- Create: `web-app/app/views/admin/books/authors/new.html.erb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: routes from Task 1.
- Produces: `AuthorsController#new`/`#create`; virtual param `books_author[alternate_names_string]` (comma-separated) mapped to `alternate_names`. `_form` used by `new` and (Task 4) `edit`.

- [ ] **Step 1: Write the failing tests** — append to `AuthorsControllerTest`:

```ruby
      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_author_path
        assert_response :success
      end

      test "create makes an author and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Author.count", 1) do
          post admin_books_authors_path, params: {books_author: {name: "A Brand New Author", kind: "person", birth_year: 1950}}
        end
        assert_redirected_to admin_books_author_path(::Books::Author.order(:created_at).last)
      end

      test "create sets the kind" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_authors_path, params: {books_author: {name: "A Collective", kind: "collective"}}
        assert_equal "collective", ::Books::Author.find_by(name: "A Collective").kind
      end

      test "create splits comma-separated alternate names into the array column" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_authors_path, params: {books_author: {name: "Alt Name Author", kind: "person", alternate_names_string: "First Alt,  Second Alt , "}}
        author = ::Books::Author.find_by(name: "Alt Name Author")
        assert_equal ["First Alt", "Second Alt"], author.alternate_names
      end

      test "create rejects an invalid author" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Author.count") do
          post admin_books_authors_path, params: {books_author: {name: "", kind: "person"}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Author.count") do
          post admin_books_authors_path, params: {books_author: {name: "Nope", kind: "person"}}
        end
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb -n "/new|create/"`
Expected: FAIL — `new`/`create` / `_form` missing.

- [ ] **Step 3: Add `new`, `create`, and param helpers** — in `web-app/app/controllers/admin/books/authors_controller.rb`, add after `show`:

```ruby
  def new
    @author = ::Books::Author.new
    authorize @author
  end

  def create
    @author = ::Books::Author.new
    assign_author_attributes(@author)
    authorize @author

    if @author.save
      redirect_to admin_books_author_path(@author), notice: "Author created."
    else
      render :new, status: :unprocessable_entity
    end
  end
```

  Add to the `private` section (after `sortable_column`, before `set_author`):

```ruby
  def author_params
    params.require(:books_author).permit(:name, :sort_name, :kind, :birth_year, :death_year, :description)
  end

  def assign_author_attributes(record)
    record.assign_attributes(author_params)
    raw = params.dig(:books_author, :alternate_names_string)
    record.alternate_names = raw.to_s.split(",").map(&:strip).reject(&:blank?) unless raw.nil?
  end
```

  (Leave the `before_action` lists as `only: [:show]` — `new`/`create` authorize inline.)

- [ ] **Step 4: Create the form + new views** — `web-app/app/views/admin/books/authors/_form.html.erb`:

```erb
<%= form_with model: @author, url: (@author.persisted? ? admin_books_author_path(@author) : admin_books_authors_path), class: "space-y-6" do |f| %>
  <% if @author.errors.any? %>
    <div class="alert alert-error">
      <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      <div>
        <h3 class="font-bold"><%= pluralize(@author.errors.count, "error") %> prohibited this author from being saved:</h3>
        <ul class="list-disc list-inside mt-2">
          <% @author.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">Basic Information</h2>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control md:col-span-2">
          <%= f.label :name, class: "label" do %>
            <span class="label-text font-semibold">Name <span class="text-error">*</span></span>
          <% end %>
          <%= f.text_field :name,
              class: "input input-bordered w-full #{@author.errors[:name].any? ? 'input-error' : ''}",
              placeholder: "Enter author name",
              required: true,
              autofocus: true %>
          <% if @author.errors[:name].any? %>
            <label class="label"><span class="label-text-alt text-error"><%= @author.errors[:name].first %></span></label>
          <% end %>
        </div>

        <div class="form-control">
          <%= f.label :sort_name, class: "label" do %>
            <span class="label-text font-semibold">Sort Name</span>
          <% end %>
          <%= f.text_field :sort_name, class: "input input-bordered w-full" %>
        </div>

        <div class="form-control">
          <%= f.label :kind, class: "label" do %>
            <span class="label-text font-semibold">Kind</span>
          <% end %>
          <%= f.select :kind,
              ::Books::Author.kinds.keys.map { |k| [k.titleize, k] },
              {},
              class: "select select-bordered w-full #{@author.errors[:kind].any? ? 'select-error' : ''}" %>
        </div>

        <div class="form-control">
          <%= f.label :birth_year, class: "label" do %>
            <span class="label-text font-semibold">Birth Year</span>
          <% end %>
          <%= f.number_field :birth_year, class: "input input-bordered w-full", min: -3000, max: 3000 %>
        </div>

        <div class="form-control">
          <%= f.label :death_year, class: "label" do %>
            <span class="label-text font-semibold">Death Year</span>
          <% end %>
          <%= f.number_field :death_year, class: "input input-bordered w-full", min: -3000, max: 3000 %>
        </div>

        <div class="form-control md:col-span-2">
          <%= f.label :alternate_names, class: "label" do %>
            <span class="label-text font-semibold">Alternate Names</span>
          <% end %>
          <%= text_field_tag "books_author[alternate_names_string]", @author.alternate_names.join(", "), class: "input input-bordered w-full" %>
          <label class="label"><span class="label-text-alt">Comma-separated</span></label>
        </div>

        <div class="form-control md:col-span-2">
          <%= f.label :description, class: "label" do %>
            <span class="label-text font-semibold">Description</span>
          <% end %>
          <%= f.text_area :description, class: "textarea textarea-bordered w-full h-32" %>
        </div>
      </div>
    </div>
  </div>

  <div class="flex flex-col sm:flex-row gap-2 justify-end">
    <%= link_to "Cancel", (@author.persisted? ? admin_books_author_path(@author) : admin_books_authors_path), class: "btn btn-ghost" %>
    <%= f.submit(@author.persisted? ? "Update Author" : "Create Author", class: "btn btn-primary") %>
  </div>
<% end %>
```

  `web-app/app/views/admin/books/authors/new.html.erb`:

```erb
<% content_for :title, "New Author" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">New Author</h1>
    <%= link_to "Back", admin_books_authors_path, class: "btn btn-ghost" %>
  </div>

  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/authors_controller.rb
git add app/controllers/admin/books/authors_controller.rb app/views/admin/books/authors/_form.html.erb app/views/admin/books/authors/new.html.erb test/controllers/admin/books/authors_controller_test.rb
git commit -m "Add books author new/create + form (inc 5a task 3)"
```

---

### Task 4: Edit / update / destroy

**Files:**
- Modify: `web-app/app/controllers/admin/books/authors_controller.rb` (add `edit`, `update`, `destroy`; grow `before_action` lists)
- Create: `web-app/app/views/admin/books/authors/edit.html.erb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: `_form` (Task 3), `assign_author_attributes` (Task 3).
- Produces: full author CRUD. `edit.html.erb` reuses `_form` unchanged.

- [ ] **Step 1: Write the failing tests** — append to `AuthorsControllerTest`:

```ruby
      # Edit / update / destroy

      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_author_path(@author)
        assert_response :success
      end

      test "update changes the author and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: "Lev Tolstoy (Revised)"}}
        assert_redirected_to admin_books_author_path(@author)
        assert_equal "Lev Tolstoy (Revised)", @author.reload.name
      end

      test "update leaves alternate_names untouched when the field is absent" do
        @author.update!(alternate_names: ["Lev Tolstoy"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: @author.name}}
        assert_equal ["Lev Tolstoy"], @author.reload.alternate_names
      end

      test "update clears alternate_names when the field is submitted empty" do
        @author.update!(alternate_names: ["Lev Tolstoy"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: @author.name, alternate_names_string: ""}}
        assert_equal [], @author.reload.alternate_names
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: ""}}
        assert_response :unprocessable_entity
        assert @author.reload.name.present?
      end

      test "destroy deletes the author" do
        author = ::Books::Author.create!(name: "Disposable Author", kind: "person")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Author.count", -1) do
          delete admin_books_author_path(author)
        end
        assert_redirected_to admin_books_authors_path
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Author.count") do
          delete admin_books_author_path(@author)
        end
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb -n "/edit|update|destroy/"`
Expected: FAIL — `edit`/`update`/`destroy` missing.

- [ ] **Step 3: Add the actions + grow callbacks** — in `web-app/app/controllers/admin/books/authors_controller.rb`, change the two `before_action` lines to include the new actions:

```ruby
  before_action :set_author, only: [:show, :edit, :update, :destroy]
  before_action :authorize_author, only: [:show, :edit, :update, :destroy]
```

  Add after `create`:

```ruby
  def edit
  end

  def update
    assign_author_attributes(@author)

    if @author.save
      redirect_to admin_books_author_path(@author), notice: "Author updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @author.destroy!
    redirect_to admin_books_authors_path, notice: "Author deleted."
  end
```

- [ ] **Step 4: Create the edit view** — `web-app/app/views/admin/books/authors/edit.html.erb`:

```erb
<% content_for :title, "Edit #{@author.name}" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">Edit Author</h1>
    <%= link_to "Back", admin_books_author_path(@author), class: "btn btn-ghost" %>
  </div>

  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass** (index/show/create still pass — callback growth risk)

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS (full CRUD).

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/authors_controller.rb
git add app/controllers/admin/books/authors_controller.rb app/views/admin/books/authors/edit.html.erb test/controllers/admin/books/authors_controller_test.rb
git commit -m "Add books author edit/update/destroy (inc 5a task 4)"
```

---

### Task 5: Author images

**Files:**
- Modify: `web-app/app/views/admin/books/authors/show.html.erb` (add Images card + upload modal)
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: the images route + `NESTED_PARENTS[:books][:author_id]` (both added in Task 1); the shared `Admin::ImagesController` (unchanged).
- Produces: the author show page renders a lazy `images_list` frame and an upload modal.

- [ ] **Step 1: Write the failing tests** — append to `AuthorsControllerTest`:

```ruby
      # Images

      test "the author images index frame renders for the author" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_images_path(@author)
        assert_response :success
      end

      test "uploading an image attaches it to the author via the shared images controller" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_author_images_path(@author), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Portrait",
              primary: true
            }
          }
        end
        assert_includes @author.reload.images.map(&:id), Image.order(:created_at).last.id
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb -n "/image/"`
Expected: The index-frame test may pass already (route + shared controller exist from Task 1); the **upload** test fails only if the shared controller can't resolve the parent — but since `NESTED_PARENTS[:books][:author_id]` was registered in Task 1, both may pass. If both already pass, this task's deliverable is the show-page UI (Steps 3–4); proceed to add it and re-run.

- [ ] **Step 3: Add the Images card to the show page** — in `web-app/app/views/admin/books/authors/show.html.erb`, inside the right-hand column `<div class="space-y-6">`, insert the Images card **before** the Metadata card. Find:

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
              <button class="btn btn-sm btn-ghost" onclick="add_author_image_modal.showModal()">+ Add</button>
            <% end %>
          </div>
          <%= turbo_frame_tag "images_list", loading: :lazy, src: admin_books_author_images_path(@author) do %>
            <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
```

- [ ] **Step 4: Add the upload modal** — in `web-app/app/views/admin/books/authors/show.html.erb`, insert the modal just before the final `</div>` that closes the top-level `<div class="space-y-6">`. Add:

```erb
  <% if current_user_can_write? %>
    <dialog id="add_author_image_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Image</h3>
        <%= form_with model: Image.new, url: admin_books_author_images_path(@author), method: :post, data: {controller: "modal-form", modal_form_modal_id_value: "add_author_image_modal"} do |f| %>
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
            <button type="button" class="btn" onclick="add_author_image_modal.close()">Cancel</button>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
  <% end %>
```

  (This `<% if current_user_can_write? %>` block sits as the last child of the outer `<div class="space-y-6">`. Task 6 will add the relationship modal inside the same block.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS (image tests + all prior).

- [ ] **Step 6: Lint + commit**

```bash
cd web-app && bundle exec standardrb
git add app/views/admin/books/authors/show.html.erb test/controllers/admin/books/authors_controller_test.rb
git commit -m "Wire author images into the show page (inc 5a task 5)"
```

---

### Task 6: Inline AuthorRelationships (editable) + read-only inbound card

**Files:**
- Create: `web-app/app/controllers/admin/books/author_relationships_controller.rb`
- Create: `web-app/app/views/admin/books/authors/_author_relationships_list.html.erb`
- Modify: `web-app/app/views/admin/books/authors/show.html.erb` (add Relationships card, Inbound card, add-relationship modal)
- Test: `web-app/test/controllers/admin/books/author_relationships_controller_test.rb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb` (inbound-card render)

**Interfaces:**
- Consumes: routes `admin_books_author_author_relationships_path`, `admin_books_author_relationship_path`, `search_admin_books_authors_path` (Task 1); `AuthorPolicy` (exists); `AutocompleteComponent`; `admin/shared/flash` partial.
- Produces: `AuthorRelationshipsController` (create/update/destroy, turbo_stream + html); `_author_relationships_list` partial (frame `author_relationships_list`, local `author:`).

- [ ] **Step 1: Write the failing tests** — create `web-app/test/controllers/admin/books/author_relationships_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class AuthorRelationshipsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a relationship and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        assert_difference("@author.author_relationships.count", 1) do
          post admin_books_author_author_relationships_path(@author), params: {books_author_relationship: {to_author_id: other.id, relation_type: "member_of"}}
        end
        assert_redirected_to admin_books_author_path(@author)
        assert_equal "member_of", @author.author_relationships.order(:created_at).last.relation_type
      end

      test "create rejects a self-reference" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::AuthorRelationship.count") do
          post admin_books_author_author_relationships_path(@author), params: {books_author_relationship: {to_author_id: @author.id, relation_type: "pseudonym_of"}}
        end
        assert_redirected_to admin_books_author_path(@author)
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        other = books_authors(:king)
        assert_no_difference("::Books::AuthorRelationship.count") do
          post admin_books_author_author_relationships_path(@author), params: {books_author_relationship: {to_author_id: other.id, relation_type: "member_of"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the relation type" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        rel = @author.author_relationships.create!(to_author: other, relation_type: :pseudonym_of)
        patch admin_books_author_relationship_path(rel), params: {books_author_relationship: {relation_type: "member_of"}}
        assert_redirected_to admin_books_author_path(@author)
        assert_equal "member_of", rel.reload.relation_type
      end

      test "destroy removes the relationship" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        rel = @author.author_relationships.create!(to_author: other, relation_type: :pseudonym_of)
        assert_difference("::Books::AuthorRelationship.count", -1) do
          delete admin_books_author_relationship_path(rel)
        end
        assert_redirected_to admin_books_author_path(@author)
      end
    end
  end
end
```

  Append one render test to `AuthorsControllerTest` in `web-app/test/controllers/admin/books/authors_controller_test.rb`:

```ruby
      # Inbound relationships card

      test "show renders for an author that has inbound relationships" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_path(books_authors(:king))
        assert_response :success
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/admin/books/author_relationships_controller_test.rb`
Expected: FAIL — `AuthorRelationshipsController` / partial missing.

- [ ] **Step 3: Create the controller** — `web-app/app/controllers/admin/books/author_relationships_controller.rb`:

```ruby
class Admin::Books::AuthorRelationshipsController < Admin::Books::BaseController
  before_action :set_author_relationship, only: [:update, :destroy]

  def create
    @author = ::Books::Author.find(params[:author_id])
    authorize @author, :update?, policy_class: ::Books::AuthorPolicy
    @author_relationship = @author.author_relationships.build(author_relationship_params)

    if @author_relationship.save
      respond_to do |format|
        format.turbo_stream { render_author_relationships("Relationship added.") }
        format.html { redirect_to admin_books_author_path(@author), notice: "Relationship added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@author_relationship) }
        format.html { redirect_to admin_books_author_path(@author), alert: @author_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @author = @author_relationship.from_author
    authorize @author, :update?, policy_class: ::Books::AuthorPolicy

    if @author_relationship.update(author_relationship_params)
      respond_to do |format|
        format.turbo_stream { render_author_relationships("Relationship updated.") }
        format.html { redirect_to admin_books_author_path(@author), notice: "Relationship updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@author_relationship) }
        format.html { redirect_to admin_books_author_path(@author), alert: @author_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @author = @author_relationship.from_author
    authorize @author, :update?, policy_class: ::Books::AuthorPolicy
    @author_relationship.destroy!

    respond_to do |format|
      format.turbo_stream { render_author_relationships("Relationship removed.") }
      format.html { redirect_to admin_books_author_path(@author), notice: "Relationship removed." }
    end
  end

  private

  def set_author_relationship
    @author_relationship = ::Books::AuthorRelationship.find(params[:id])
  end

  def author_relationship_params
    params.require(:books_author_relationship).permit(:to_author_id, :relation_type)
  end

  def render_author_relationships(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("author_relationships_list", partial: "admin/books/authors/author_relationships_list", locals: {author: @author})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
```

- [ ] **Step 4: Create the list partial** — `web-app/app/views/admin/books/authors/_author_relationships_list.html.erb`:

```erb
<%= turbo_frame_tag "author_relationships_list" do %>
  <% if author.author_relationships.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr><th>Relation</th><th>Author</th><th class="text-right">Actions</th></tr>
        </thead>
        <tbody>
          <% author.author_relationships.includes(:to_author).each do |rel| %>
            <tr>
              <td><span class="badge badge-ghost"><%= rel.relation_type.titleize %></span></td>
              <td><%= link_to rel.to_author.name, admin_books_author_path(rel.to_author), class: "link link-hover", data: {turbo_frame: "_top"} %></td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-1">
                  <% if current_user_can_write? %>
                    <button class="btn btn-outline btn-xs whitespace-nowrap" onclick="edit_author_relationship_<%= rel.id %>_modal.showModal()">Edit</button>
                    <%= button_to "Remove", admin_books_author_relationship_path(rel), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", data: {turbo_confirm: "Remove this relationship?"}, form: {data: {turbo_frame: "author_relationships_list"}} %>
                  <% end %>
                </div>
              </td>
            </tr>

            <% if current_user_can_write? %>
              <dialog id="edit_author_relationship_<%= rel.id %>_modal" class="modal">
                <div class="modal-box">
                  <h3 class="font-bold text-lg mb-4">Edit Relationship</h3>
                  <%= form_with model: rel, url: admin_books_author_relationship_path(rel), method: :patch, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "edit_author_relationship_#{rel.id}_modal", turbo_frame: "author_relationships_list"} do |f| %>
                    <div class="form-control">
                      <%= f.label :relation_type, class: "label" do %><span class="label-text font-semibold">Relation</span><% end %>
                      <%= f.select :relation_type, ::Books::AuthorRelationship.relation_types.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
                    </div>
                    <div class="modal-action">
                      <button type="button" class="btn" onclick="edit_author_relationship_<%= rel.id %>_modal.close()">Cancel</button>
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
    <p class="text-base-content/60 text-sm">No relationships yet.</p>
  <% end %>
<% end %>
```

- [ ] **Step 5: Add the Relationships + Inbound cards and add-modal to the show page** — in `web-app/app/views/admin/books/authors/show.html.erb`:

  (a) Insert the two cards **after** the closing `</div>` of the `grid grid-cols-1 lg:grid-cols-3` block and **before** the `<% if current_user_can_write? %>` image-modal block added in Task 5. Add:

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Relationships <span class="badge badge-ghost"><%= @author.author_relationships.count %></span></h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_author_relationship_modal.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= render "admin/books/authors/author_relationships_list", author: @author %>
    </div>
  </div>

  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <h2 class="card-title text-base">Inbound Relationships <span class="badge badge-ghost"><%= @author.inverse_author_relationships.count %></span></h2>
      <% if @author.inverse_author_relationships.any? %>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr><th>Author</th><th>Relation</th></tr>
            </thead>
            <tbody>
              <% @author.inverse_author_relationships.includes(:from_author).each do |rel| %>
                <tr>
                  <td><%= link_to rel.from_author.name, admin_books_author_path(rel.from_author), class: "link link-hover", data: {turbo_frame: "_top"} %></td>
                  <td><span class="badge badge-ghost"><%= rel.relation_type.titleize %></span></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-base-content/60 text-sm">No inbound relationships.</p>
      <% end %>
    </div>
  </div>
```

  (b) Add the add-relationship modal **inside** the existing `<% if current_user_can_write? %>` block from Task 5 (alongside `add_author_image_modal`, before that block's `<% end %>`):

```erb
    <dialog id="add_author_relationship_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Relationship</h3>
        <%= form_with model: ::Books::AuthorRelationship.new, url: admin_books_author_author_relationships_path(@author), method: :post, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "add_author_relationship_modal"} do |f| %>
          <div class="form-control">
            <%= f.label :to_author_id, class: "label" do %><span class="label-text font-semibold">Author <span class="text-error">*</span></span><% end %>
            <%= render AutocompleteComponent.new(name: "books_author_relationship[to_author_id]", url: search_admin_books_authors_path(exclude_id: @author.id), placeholder: "Search for an author…", required: true) %>
          </div>
          <div class="form-control">
            <%= f.label :relation_type, class: "label" do %><span class="label-text font-semibold">Relation</span><% end %>
            <%= f.select :relation_type, ::Books::AuthorRelationship.relation_types.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
          </div>
          <div class="modal-action">
            <button type="button" class="btn" onclick="add_author_relationship_modal.close()">Cancel</button>
            <%= f.submit "Add Relationship", class: "btn btn-primary" %>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/admin/books/author_relationships_controller_test.rb test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS (relationship CRUD + inbound-card render + all prior author tests).

- [ ] **Step 7: Lint + commit**

```bash
cd web-app && bundle exec standardrb app/controllers/admin/books/author_relationships_controller.rb
git add app/controllers/admin/books/author_relationships_controller.rb app/views/admin/books/authors/_author_relationships_list.html.erb app/views/admin/books/authors/show.html.erb test/controllers/admin/books/author_relationships_controller_test.rb test/controllers/admin/books/authors_controller_test.rb
git commit -m "Add inline author relationships + inbound card (inc 5a task 6)"
```

---

### Task 7: Playwright smoke spec

**Files:**
- Create: `web-app/e2e/tests/books/admin/authors.spec.ts`

**Interfaces:**
- Consumes: the live books admin (books-admin Playwright project, `.auth/books-user.json`), the live author OpenSearch index (typeahead).

- [ ] **Step 1: Ensure the dev author index is populated** (the typeahead exercises the live index)

Run: `cd web-app && bin/rails search:books:recreate_authors`
Expected: reindexes the authors (≈58k); `AuthorAutocomplete("tol")` returns hits.

- [ ] **Step 2: Write the spec** — `web-app/e2e/tests/books/admin/authors.spec.ts` (mirror `e2e/tests/books/admin/books.spec.ts` + the `associations.spec.ts` typeahead pattern; use a unique name to avoid slug collisions, and name-based input selectors where `getByLabel` is ambiguous):

```typescript
import { test, expect } from "@playwright/test";

test.describe("Books admin — authors", () => {
  test("lists authors and links to New Author", async ({ page }) => {
    await page.goto("/admin/authors");
    await expect(page.getByRole("heading", { name: "Authors", level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "New Author" })).toBeVisible();
  });

  test("creates an author and shows it", async ({ page }) => {
    const name = `Test Author ${Date.now()}`;
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "New Author" }).click();

    await page.locator('input[name="books_author[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Author" }).click();

    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  });

  test("adds a relationship via the author typeahead", async ({ page }) => {
    const name = `Rel Author ${Date.now()}`;
    await page.goto("/admin/authors");
    await page.getByRole("link", { name: "New Author" }).click();
    await page.locator('input[name="books_author[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Author" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("button", { name: "+ Add" }).last().click();
    const modal = page.locator("dialog#add_author_relationship_modal");
    await expect(modal).toBeVisible();

    await modal.getByPlaceholder("Search for an author…").fill("Tolstoy");
    await modal.locator("li.cursor-pointer").first().click();
    await modal.getByRole("button", { name: "Add Relationship" }).click();

    await expect(
      page.locator("turbo-frame#author_relationships_list").getByText("Tolstoy", { exact: false })
    ).toBeVisible();
  });
});
```

- [ ] **Step 3: Run the spec** (needs the local dev server per `docs/features/e2e-testing.md`)

Run: `cd web-app && yarn playwright test e2e/tests/books/admin/authors.spec.ts --project=books-admin`
Expected: 3 passed. If the relationship assertion is flaky on the lazy typeahead, add a `scrollIntoViewIfNeeded()` on the Relationships card before opening the modal (the editions-spec precedent), NOT an app change.

- [ ] **Step 4: Commit**

```bash
cd web-app && git add e2e/tests/books/admin/authors.spec.ts
git commit -m "Add books authors Playwright smoke spec (inc 5a task 7)"
```

---

## Final verification (before requesting the whole-branch review)

- [ ] `cd web-app && bin/rails test` — full suite green (target ≈ 4698 + the new author tests, 0 failures).
- [ ] `cd web-app && bundle exec standardrb` — clean.
- [ ] `cd web-app && bin/brakeman --no-pager` — no **new** warnings vs. main (main already exits nonzero on a pre-existing `application.html.erb` parse error + baseline warnings; confirm the delta is zero).
- [ ] `cd web-app && yarn playwright test e2e/tests/books/admin/authors.spec.ts --project=books-admin` — 3/3.
- [ ] Append the increment record to `.superpowers/sdd/progress.md`.

## Self-review notes (traceability to the spec)

- **Author CRUD + OpenSearch index** → Tasks 1–4 (`AuthorGeneral` index, `AuthorAutocomplete` typeahead, sort allowlist, pagy 25, `alternate_names_string` split incl. absent-no-op + empty-clears).
- **Inline AuthorRelationships (editable from-side)** → Task 6 (`AuthorRelationshipsController` mirrors `BookRelationshipsController`; parent authorized explicitly `:update?`).
- **Read-only inbound card** → Task 6 (`inverse_author_relationships`, no controller/route).
- **Author images** → Task 1 (route + `NESTED_PARENTS`) + Task 5 (card + modal + upload test).
- **`DomainNav` "Authors" item + `DomainRouting` `ENTITIES`/`NESTED_PARENTS`** → Task 1 (+ tests).
- **`exclude_id` on author search** → Task 1 (+ test).
- **No categories** → nowhere: the author show page has no categories card; `ENTITIES` `category_items_path: nil`; no `category_items` route.
- **Delete/Remove buttons ship with the destroy actions** → `_table` (Task 1), show page (Task 2), relationship Remove (Task 6).
- **DaisyUI-5 form pattern / row-actions pattern / no frame double-wrap / grow before_action lists / search omits authorize / inline authorize parent explicitly** → enforced in the relevant task steps above.
- **Playwright smoke** → Task 7.
