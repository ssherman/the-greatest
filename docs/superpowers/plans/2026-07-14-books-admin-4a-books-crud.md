# Books Admin 4a — Book CRUD + Search + Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working `Books::Book` admin — OpenSearch-backed index with sort + pagination + typeahead, full CRUD, and cover-image management on the show page — at `/admin/books` on the books host.

**Architecture:** `Admin::Books::BooksController` mirrors `Admin::Games::GamesController` field-for-field: index loads via `Search::Books::Search::BookGeneral` (or a sorted SQL list when no query), a `search` collection action serves the typeahead JSON via `Search::Books::Search::BookAutocomplete`, and images ride the already-domain-agnostic `Admin::ImagesController` once `Books::Book` is registered in `Admin::DomainRouting`. Books CRUD triggers OpenSearch reindexing automatically through the existing `SearchIndexable` model callback + `Search::IndexerJob` cron — no indexing code in the controller.

**Tech Stack:** Rails 8, Pundit, OpenSearch (`Search::Books::*`), Pagy, Turbo Frames + `AutocompleteComponent`/`Admin::SearchComponent` Stimulus, ActiveStorage (images), Minitest + fixtures + Mocha, Playwright.

## Global Constraints

- Run **all** commands from `web-app/`. Working dir: `/home/shane/dev/the-greatest/web-app`.
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. Never run a destructive DB command; `RAILS_ENV=test` must be explicit on anything touching fixtures. `ActiveRecord::FixtureSet.create_fixtures` TRUNCATES — never call it.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- **No code comments** unless the code shown here has them. Self-documenting code, follow existing patterns.
- Namespace all books code under `Books::` / `Admin::Books::`. Tests mirror the namespace (`module Admin; module Books`).
- Controller tests assert **behavior** (status codes, redirects, params, `assert_difference` on counts) — never HTML/CSS/copy. Stub OpenSearch (`Search::Books::Search::BookGeneral`/`BookAutocomplete`) with Mocha — never hit a live index in a unit test.
- Rails 8 enum syntax (`enum :book_kind, {standalone: 0}`), already defined on the models.
- Use Rails generators for the controller (`--skip-routes --no-helper`); hand-write views by adapting the games templates.

## Deviations from the umbrella design (`docs/superpowers/specs/2026-07-13-books-admin-ui-design.md`)

Read these first — they change what 4a contains.

1. **This is increment 4a of a 3-way split** (4a book CRUD + images; 4b editions; 4c inline associations). The design's increment 4 bundled all of it; the owner split it 2026-07-14 after recon showed ~14 tasks across independent subsystems. 4a is self-contained and shippable: a browsable, editable book admin with cover images.

2. **Categories are deferred to increment 6 — do NOT wire them.** `Admin::AddCategoryModalComponent#search_url` falls back to the *music* categories-search path when `DomainNav::CONFIGS[:books][:categories_search_path]` is nil (it is, until inc 6). Categories are STI (`Category` base, `type` column) with no type-mismatch validation, so a book show page rendering that modal would let an admin attach a `Music::Category` to a `Books::Book` — silent wrong-taxonomy data. Therefore: **the book show page renders NO categories section and NO `Admin::AddCategoryModalComponent`; `ENTITIES["Books::Book"][:category_items_path]` is `nil`; no `category_items` route is nested.** Increment 6 flips all three on together with the books categories search endpoint. Images have no such dependency and ship fully here.

3. **A Playwright smoke spec ships here** (CLAUDE.md requires an E2E test per new user-facing page). It covers the book index + create→show happy path; the exhaustive per-entity suite stays in increment 7.

## Prerequisite (run once in dev before verifying Task 1)

The books OpenSearch indices exist but hold **0 documents** — the 126K-row migration suppressed indexing. Until they are populated, the book index page returns empty for any search query (the no-query sorted list still works off Postgres). Run once, in dev, before browser-verifying the search path:

```bash
bin/rails search:books:recreate_and_reindex_all
```

This is NOT a test dependency (unit tests stub OpenSearch) and NOT a code change — it is a dev-data step. If the index page shows no results when you type a query but the plain list renders, this is why.

---

### Task 1: Routes, registry registration, and the book index + typeahead

**Files:**
- Modify: `web-app/config/routes.rb` (books admin namespace, currently `config/routes.rb:273-278`)
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`ENTITIES`, `NESTED_PARENTS`)
- Create: `web-app/app/controllers/admin/books/books_controller.rb`
- Create: `web-app/app/views/admin/books/books/index.html.erb`
- Create: `web-app/app/views/admin/books/books/_table.html.erb`
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb`
- Test: `web-app/test/lib/admin/domain_routing_test.rb` (add Books::Book assertions)

**Interfaces:**
- Consumes: `Admin::Books::BaseController` (exists — `include Admin::DomainScopedAuth`); `Books::BookPolicy` (exists); `Search::Books::Search::BookGeneral.call(text, size:)` and `BookAutocomplete.call(text, size:)` — both return `[{id: "<string>", score:, source:}]`.
- Produces: route helpers `admin_books_books_path`, `admin_books_book_path(book)`, `new_admin_books_book_path`, `edit_admin_books_book_path(book)`, `search_admin_books_books_path`; `Admin::DomainRouting.domain_for(Books::Book) => :books` and `path_for(book) => "/admin/books/<slug>"`. Later tasks add `show`/`new`/`create`/`edit`/`update`/`destroy` actions and the images nesting.

- [ ] **Step 1: Write the failing registry test**

In `web-app/test/lib/admin/domain_routing_test.rb`, extend the existing `path_for` test to cover `Books::Book`. Find `test "path_for returns the admin show path for every registered entity"` and add a books row to its hash:

```ruby
        books_books(:war_and_peace) => "/admin/books"
```

so the block reads (existing rows plus the new one):

```ruby
      {
        music_artists(:david_bowie) => "/admin/artists",
        music_albums(:dark_side_of_the_moon) => "/admin/albums",
        music_songs(:time) => "/admin/songs",
        games_games(:breath_of_the_wild) => "/admin/games",
        games_companies(:nintendo) => "/admin/companies",
        books_books(:war_and_peace) => "/admin/books"
      }.each do |record, prefix|
        assert_equal "#{prefix}/#{record.to_param}", Admin::DomainRouting.path_for(record)
      end
```

Add a dedicated test too:

```ruby
    test "domain_for resolves a Books::Book to books" do
      assert_equal :books, Admin::DomainRouting.domain_for(books_books(:war_and_peace))
      assert_equal :books, Admin::DomainRouting.domain_for(::Books::Book)
    end

    test "parent_from_params resolves a book_id under the books domain" do
      book = books_books(:war_and_peace)
      resolved = Admin::DomainRouting.parent_from_params({book_id: book.id}, domain: :books)
      assert_equal book, resolved
    end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`
Expected: FAIL — `path_for` returns `nil` for the book (unregistered), and `domain_for` returns `nil`; `parent_from_params` returns `nil` because `NESTED_PARENTS` has no `:books` key.

- [ ] **Step 3: Register Books::Book in the routing registry**

In `web-app/app/lib/admin/domain_routing.rb`, add to `ENTITIES` (after the `Games::Company` entry). `category_items_path` is deliberately `nil` — categories defer to increment 6 (see Deviation 2):

```ruby
      "Books::Book" => {
        domain: :books,
        path: ->(r) { URL_HELPERS.admin_books_book_path(r) },
        category_items_path: nil
      }
```

Add a `books:` key to `NESTED_PARENTS` (for image nesting in Task 5; harmless now):

```ruby
      books: {
        book_id: "Books::Book"
      }
```

- [ ] **Step 4: Run the registry test — still red on the route helper**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`
Expected: FAIL — `admin_books_book_path` raises `NoMethodError`/`undefined method` because the `resources :books` route does not exist yet. (`domain_for` and `parent_from_params` now pass; `path_for` still errors.) This is expected; the route lands in Step 5.

- [ ] **Step 5: Add the books admin routes**

In `web-app/config/routes.rb`, expand the books admin namespace. It currently reads:

```ruby
    namespace :admin, module: "admin/books", as: "admin_books" do
      root to: "dashboard#index"
    end
```

Change it to:

```ruby
    namespace :admin, module: "admin/books", as: "admin_books" do
      root to: "dashboard#index"

      resources :books do
        collection do
          get :search
        end
      end
    end
```

- [ ] **Step 6: Run the registry test to green**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`
Expected: PASS. The route now resolves, so `path_for(book) => "/admin/books/<slug>"`.

- [ ] **Step 7: Write the failing index + search controller test**

Create `web-app/test/controllers/admin/books/books_controller_test.rb`. This task covers index + search; later tasks append show/create/update/destroy sections. Mirror `test/controllers/admin/games/games_controller_test.rb`.

```ruby
require "test_helper"

module Admin
  module Books
    class BooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)

        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_books_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_books_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      # Index behavior

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      test "index with a query loads books from OpenSearch in relevance order" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: @book.id.to_s, score: 1.0, source: {"title" => @book.title}}])
        get admin_books_books_path(q: "war")
        assert_response :success
      end

      test "index with a query that matches nothing does not error" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([])
        get admin_books_books_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_books_path(sort: "'; DROP TABLE books_books; --")
        end
        assert_response :success
      end

      # Typeahead

      test "search returns autocomplete JSON" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookAutocomplete.expects(:call).with("war", size: 20).returns([{id: @book.id.to_s, score: 1.0, source: {"title" => @book.title}}])
        get search_admin_books_books_path(q: "war")
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal @book.id, body.first["value"]
        assert_includes body.first["text"], @book.title
      end

      test "search returns an empty array when nothing matches" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookAutocomplete.stubs(:call).returns([])
        get search_admin_books_books_path(q: "zzz")
        assert_response :success
        assert_equal [], JSON.parse(response.body)
      end
    end
  end
end
```

- [ ] **Step 8: Run it to confirm it fails**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: FAIL — `uninitialized constant Admin::Books::BooksController`.

- [ ] **Step 9: Generate the controller**

```bash
bin/rails generate controller Admin::Books::Books --skip-routes --no-helper
```

This creates `app/controllers/admin/books/books_controller.rb` and an empty test file — **do not let it overwrite the test from Step 7** (answer `n`, or `git checkout` the test afterward).

- [ ] **Step 10: Write the controller (index + search only for now)**

Replace `web-app/app/controllers/admin/books/books_controller.rb` with:

```ruby
class Admin::Books::BooksController < Admin::Books::BaseController
  before_action :set_book, only: [:show, :edit, :update, :destroy]
  before_action :authorize_book, only: [:show, :edit, :update, :destroy]

  def index
    authorize ::Books::Book
    load_books_for_index
  end

  def search
    results = ::Search::Books::Search::BookAutocomplete.call(params[:q], size: 20)
    book_ids = results.map { |r| r[:id].to_i }

    if book_ids.empty?
      render json: []
      return
    end

    books = ::Books::Book.where(id: book_ids).in_order_of(:id, book_ids)
    render json: books.map { |b| {value: b.id, text: autocomplete_label(b)} }
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:id])
  end

  def authorize_book
    authorize @book
  end

  def load_books_for_index
    if params[:q].present?
      results = ::Search::Books::Search::BookGeneral.call(params[:q], size: 1000)
      book_ids = results.map { |r| r[:id].to_i }

      @books = if book_ids.empty?
        ::Books::Book.none
      else
        ::Books::Book.where(id: book_ids).includes(:authors).in_order_of(:id, book_ids)
      end
    else
      @books = ::Books::Book.all.includes(:authors).order(sortable_column(params[:sort]))
    end

    @pagy, @books = pagy(@books, limit: 25)
  end

  def sortable_column(column)
    {
      "id" => "books_books.id",
      "title" => "books_books.title",
      "first_published_year" => "books_books.first_published_year",
      "book_kind" => "books_books.book_kind",
      "created_at" => "books_books.created_at"
    }.fetch(column, "books_books.title")
  end

  def autocomplete_label(book)
    year = book.first_published_year
    "#{book.title}#{" (#{year})" if year.present?}"
  end
end
```

- [ ] **Step 11: Write the index + table views**

Create `web-app/app/views/admin/books/books/index.html.erb` (adapted from `app/views/admin/games/games/index.html.erb`, minus the IGDB import modal):

```erb
<% content_for :title, "Books" %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">Books</h1>
    <% if current_user_can_write? %>
      <%= link_to "New Book", new_admin_books_book_path, class: "btn btn-primary" %>
    <% end %>
  </div>

  <%= render Admin::SearchComponent.new(
    url: admin_books_books_path,
    placeholder: "Search books by title or author…",
    value: params[:q],
    turbo_frame: "books_table"
  ) %>

  <%= turbo_frame_tag "books_table" do %>
    <%= render "table", books: @books, pagy: @pagy %>
  <% end %>
</div>
```

Create `web-app/app/views/admin/books/books/_table.html.erb` (adapted from the games `_table`, columns swapped to book fields):

```erb
<div class="overflow-x-auto">
  <table class="table table-zebra">
    <thead>
      <tr>
        <th><%= link_to "Title", admin_books_books_path(sort: "title", q: params[:q]), data: {turbo_frame: "books_table"} %></th>
        <th><%= link_to "First Published", admin_books_books_path(sort: "first_published_year", q: params[:q]), data: {turbo_frame: "books_table"} %></th>
        <th><%= link_to "Kind", admin_books_books_path(sort: "book_kind", q: params[:q]), data: {turbo_frame: "books_table"} %></th>
        <th>Authors</th>
        <th class="text-right">Actions</th>
      </tr>
    </thead>
    <tbody>
      <% if books.any? %>
        <% books.each do |book| %>
          <tr>
            <td><%= link_to book.title, admin_books_book_path(book), data: {turbo_frame: "_top"} %></td>
            <td><%= book.first_published_year || "—" %></td>
            <td><span class="badge badge-ghost"><%= book.book_kind.titleize %></span></td>
            <td class="text-sm text-base-content/70"><%= book.authors.map(&:name).join(", ") %></td>
            <td class="text-right">
              <%= link_to "View", admin_books_book_path(book), class: "btn btn-ghost btn-xs", data: {turbo_frame: "_top"} %>
              <% if current_user_can_write? %>
                <%= link_to "Edit", edit_admin_books_book_path(book), class: "btn btn-ghost btn-xs", data: {turbo_frame: "_top"} %>
              <% end %>
            </td>
          </tr>
        <% end %>
      <% else %>
        <tr>
          <td colspan="5" class="text-center text-base-content/70 py-8">
            <% if params[:q].present? %>
              No books match “<%= params[:q] %>”. <%= link_to "Clear", admin_books_books_path, data: {turbo_frame: "books_table"} %>
            <% else %>
              No books yet.
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

Note: if the helper for pagination nav differs in this codebase, check how `app/views/admin/games/games/_table.html.erb` renders `pagy` and match it exactly (it uses `pagy.series_nav` per recon; if that raises, mirror whatever the games table does).

- [ ] **Step 12: Run the controller + registry tests to green**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb test/lib/admin/domain_routing_test.rb`
Expected: PASS.

- [ ] **Step 13: Lint and commit**

```bash
bundle exec standardrb --fix
bundle exec standardrb
git add -A
git commit -m "Add the books admin index and typeahead backed by OpenSearch"
```

---

### Task 2: Book show page

**Files:**
- Modify: `web-app/app/controllers/admin/books/books_controller.rb` (add `show`)
- Create: `web-app/app/views/admin/books/books/show.html.erb`
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb` (add show section)

**Interfaces:**
- Consumes: `set_book`/`authorize_book` (Task 1).
- Produces: a show page that Task 5 (images) and increments 4b/4c extend with more sections. **No categories section** (Deviation 2).

- [ ] **Step 1: Write the failing show test**

Append to the test file, inside the class:

```ruby
      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_path(@book)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_path(@book)
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb -n /show/`
Expected: FAIL — `AbstractController::ActionNotFound` / missing template (no `show` action/view).

- [ ] **Step 3: Wire the before_actions for show, then add the show action**

Task 1 deliberately did NOT register `before_action :set_book`/`:authorize_book`, because this repo runs `config.action_controller.raise_on_missing_callback_actions = true` — an `only:` list that names an action which doesn't exist yet makes **every** request 404. So each task adds the callbacks only for the actions that exist at its commit.

Add the two before_action lines at the very top of the class body:

```ruby
class Admin::Books::BooksController < Admin::Books::BaseController
  before_action :set_book, only: [:show]
  before_action :authorize_book, only: [:show]

  def index
```

Then add the `show` action above `private`:

```ruby
  def show
  end
```

(`set_book` now loads `@book` for `show`; `authorize_book` calls `authorize @book`, and Pundit infers `show?` from the action name.)

- [ ] **Step 4: Write the show view**

Create `web-app/app/views/admin/books/books/show.html.erb`. Basic-information card + a metadata sidebar. **No categories section.** The images section is added in Task 5 (leave the placeholder comment out — just build the two cards here):

```erb
<% content_for :title, @book.title %>

<div class="space-y-6">
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-3xl font-bold"><%= @book.title %></h1>
      <% if @book.subtitle.present? %>
        <p class="text-lg text-base-content/70"><%= @book.subtitle %></p>
      <% end %>
    </div>
    <div class="flex gap-2">
      <%= link_to "Back", admin_books_books_path, class: "btn btn-ghost" %>
      <% if current_user_can_write? %>
        <%= link_to "Edit", edit_admin_books_book_path(@book), class: "btn btn-primary" %>
      <% end %>
    </div>
  </div>

  <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2 space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Basic Information</h2>
          <dl class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div><dt class="text-sm text-base-content/60">Kind</dt><dd><%= @book.book_kind.titleize %></dd></div>
            <div><dt class="text-sm text-base-content/60">First Published</dt><dd><%= @book.first_published_year || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Sort Title</dt><dd><%= @book.sort_title.presence || "—" %></dd></div>
            <div><dt class="text-sm text-base-content/60">Original Language</dt><dd><%= @book.original_language&.name || "—" %></dd></div>
            <div class="sm:col-span-2"><dt class="text-sm text-base-content/60">Alternate Titles</dt><dd><%= @book.alternate_titles.present? ? @book.alternate_titles.join(", ") : "—" %></dd></div>
            <div class="sm:col-span-2"><dt class="text-sm text-base-content/60">Description</dt><dd class="whitespace-pre-line"><%= @book.description.presence || "—" %></dd></div>
          </dl>
        </div>
      </div>
    </div>

    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-base">Metadata</h2>
          <dl class="space-y-2 text-sm">
            <div><dt class="text-base-content/60">ID</dt><dd><%= @book.id %></dd></div>
            <div><dt class="text-base-content/60">Slug</dt><dd><%= @book.slug %></dd></div>
            <div><dt class="text-base-content/60">Created</dt><dd><%= @book.created_at.to_date %></dd></div>
            <div><dt class="text-base-content/60">Updated</dt><dd><%= @book.updated_at.to_date %></dd></div>
          </dl>
        </div>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 5: Run to green**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix && bundle exec standardrb
git add -A
git commit -m "Add the books admin show page"
```

---

### Task 3: New + create (with the alternate_titles array field)

**Files:**
- Modify: `web-app/app/controllers/admin/books/books_controller.rb` (`new`, `create`, `book_params`, `assign_book_attributes`)
- Create: `web-app/app/views/admin/books/books/_form.html.erb`
- Create: `web-app/app/views/admin/books/books/new.html.erb`
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb` (create section)

**Interfaces:**
- Consumes: nothing new.
- Produces: `assign_book_attributes(record)` — the shared attribute-assignment path (permitted scalars + the comma-split `alternate_titles`), reused by `update` in Task 4.

- [ ] **Step 1: Write the failing create tests**

Append to the test file:

```ruby
      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_book_path
        assert_response :success
      end

      test "create makes a book and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Book.count", 1) do
          post admin_books_books_path, params: {books_book: {title: "A Brand New Book", book_kind: "standalone", first_published_year: 1999}}
        end
        assert_redirected_to admin_books_book_path(::Books::Book.order(:created_at).last)
      end

      test "create splits comma-separated alternate titles into the array column" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_books_path, params: {books_book: {title: "Alt Title Book", book_kind: "standalone", alternate_titles_string: "First Alt,  Second Alt , "}}
        book = ::Books::Book.find_by(title: "Alt Title Book")
        assert_equal ["First Alt", "Second Alt"], book.alternate_titles
      end

      test "create rejects an invalid book" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Book.count") do
          post admin_books_books_path, params: {books_book: {title: "", book_kind: "standalone"}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Book.count") do
          post admin_books_books_path, params: {books_book: {title: "Nope", book_kind: "standalone"}}
        end
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run to confirm failure**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb -n /create|new/`
Expected: FAIL — no `new`/`create` action.

- [ ] **Step 3: Add new + create + params handling**

In `books_controller.rb`, add the actions (place `new`/`create` near the other public actions) and the private helpers:

```ruby
  def new
    @book = ::Books::Book.new
    authorize @book
  end

  def create
    @book = ::Books::Book.new
    assign_book_attributes(@book)
    authorize @book

    if @book.save
      redirect_to admin_books_book_path(@book), notice: "Book created."
    else
      render :new, status: :unprocessable_entity
    end
  end
```

Add to the `private` section:

```ruby
  def book_params
    params.require(:books_book).permit(
      :title, :subtitle, :sort_title, :description,
      :first_published_year, :book_kind, :original_language_id
    )
  end

  def assign_book_attributes(record)
    record.assign_attributes(book_params)
    raw = params.dig(:books_book, :alternate_titles_string)
    record.alternate_titles = raw.to_s.split(",").map(&:strip).reject(&:blank?) unless raw.nil?
  end
```

Note: `alternate_titles_string` is a virtual form field (NOT a model attribute and NOT in `book_params`), split in the controller per design D9. `unless raw.nil?` means an omitted field leaves the array untouched (matters for `update` in Task 4); an empty string clears it.

- [ ] **Step 4: Write the form + new views**

Create `web-app/app/views/admin/books/books/_form.html.erb`:

```erb
<%= form_with model: @book, url: (@book.persisted? ? admin_books_book_path(@book) : admin_books_books_path) do |f| %>
  <% if @book.errors.any? %>
    <div class="alert alert-error">
      <ul class="list-disc list-inside">
        <% @book.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %>
      </ul>
    </div>
  <% end %>

  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    <label class="form-control md:col-span-2">
      <span class="label-text">Title</span>
      <%= f.text_field :title, class: "input input-bordered #{"input-error" if @book.errors[:title].any?}", required: true %>
    </label>

    <label class="form-control">
      <span class="label-text">Subtitle</span>
      <%= f.text_field :subtitle, class: "input input-bordered" %>
    </label>

    <label class="form-control">
      <span class="label-text">Sort Title</span>
      <%= f.text_field :sort_title, class: "input input-bordered" %>
    </label>

    <label class="form-control">
      <span class="label-text">Kind</span>
      <%= f.select :book_kind, ::Books::Book.book_kinds.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered" %>
    </label>

    <label class="form-control">
      <span class="label-text">First Published Year</span>
      <%= f.number_field :first_published_year, class: "input input-bordered", min: -3000, max: 3000 %>
    </label>

    <label class="form-control">
      <span class="label-text">Original Language</span>
      <%= f.collection_select :original_language_id, Language.order(:name), :id, :name, {include_blank: "—"}, class: "select select-bordered" %>
    </label>

    <label class="form-control md:col-span-2">
      <span class="label-text">Alternate Titles (comma-separated)</span>
      <%= text_field_tag "books_book[alternate_titles_string]", @book.alternate_titles.join(", "), class: "input input-bordered" %>
    </label>

    <label class="form-control md:col-span-2">
      <span class="label-text">Description</span>
      <%= f.text_area :description, rows: 6, class: "textarea textarea-bordered" %>
    </label>
  </div>

  <div class="mt-6 flex gap-2">
    <%= f.submit(@book.persisted? ? "Update Book" : "Create Book", class: "btn btn-primary") %>
    <%= link_to "Cancel", (@book.persisted? ? admin_books_book_path(@book) : admin_books_books_path), class: "btn btn-ghost" %>
  </div>
<% end %>
```

Create `web-app/app/views/admin/books/books/new.html.erb`:

```erb
<% content_for :title, "New Book" %>

<div class="max-w-3xl space-y-6">
  <h1 class="text-3xl font-bold">New Book</h1>
  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run to green**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix && bundle exec standardrb
git add -A
git commit -m "Add books admin create with comma-split alternate titles"
```

---

### Task 4: Edit + update + destroy

**Files:**
- Modify: `web-app/app/controllers/admin/books/books_controller.rb` (`edit`, `update`, `destroy`)
- Create: `web-app/app/views/admin/books/books/edit.html.erb`
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb` (update/destroy section)

**Interfaces:**
- Consumes: `assign_book_attributes` (Task 3), `set_book`/`authorize_book` (Task 1).

- [ ] **Step 1: Write the failing update/destroy tests**

Append:

```ruby
      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_book_path(@book)
        assert_response :success
      end

      test "update changes the book and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: "War and Peace (Revised)"}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "War and Peace (Revised)", @book.reload.title
      end

      test "update leaves alternate_titles untouched when the field is absent" do
        @book.update!(alternate_titles: ["Voyna i mir"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: @book.title}}
        assert_equal ["Voyna i mir"], @book.reload.alternate_titles
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: ""}}
        assert_response :unprocessable_entity
        assert @book.reload.title.present?
      end

      test "destroy deletes the book" do
        book = ::Books::Book.create!(title: "Disposable", book_kind: "standalone")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Book.count", -1) do
          delete admin_books_book_path(book)
        end
        assert_redirected_to admin_books_books_path
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Book.count") do
          delete admin_books_book_path(@book)
        end
        assert_redirected_to books_root_path
      end
```

- [ ] **Step 2: Run to confirm failure**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb -n /edit|update|destroy/`
Expected: FAIL — no `edit`/`update`/`destroy`.

- [ ] **Step 3: Grow the before_actions, then add edit + update + destroy**

First extend both before_action `only:` lists at the top of the class to include the three new actions (they now exist at this commit, so `raise_on_missing_callback_actions` is satisfied):

```ruby
  before_action :set_book, only: [:show, :edit, :update, :destroy]
  before_action :authorize_book, only: [:show, :edit, :update, :destroy]
```

Then add the actions above `private`:

```ruby
  def edit
  end

  def update
    assign_book_attributes(@book)

    if @book.save
      redirect_to admin_books_book_path(@book), notice: "Book updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @book.destroy!
    redirect_to admin_books_books_path, notice: "Book deleted."
  end
```

(`set_book` loads `@book`; `authorize_book` runs `authorize @book`, Pundit inferring `edit?`/`update?`/`destroy?` per action.)

- [ ] **Step 4: Write the edit view**

Create `web-app/app/views/admin/books/books/edit.html.erb`:

```erb
<% content_for :title, "Edit #{@book.title}" %>

<div class="max-w-3xl space-y-6">
  <h1 class="text-3xl font-bold">Edit Book</h1>
  <%= render "form" %>
</div>
```

- [ ] **Step 5: Run to green**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: PASS (full CRUD green).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix && bundle exec standardrb
git add -A
git commit -m "Add books admin edit, update and destroy"
```

---

### Task 5: Cover-image management on the book show page

**Files:**
- Modify: `web-app/config/routes.rb` (nest `images` under `books`)
- Modify: `web-app/app/views/admin/books/books/show.html.erb` (add the images section + upload dialog)
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb` (images-frame wiring test)

**Interfaces:**
- Consumes: the domain-agnostic `Admin::ImagesController` (unchanged) + `NESTED_PARENTS[:books][:book_id] => "Books::Book"` (registered in Task 1) + `Books::Book has_many :images, as: :parent` (exists).
- Produces: route helpers `admin_books_book_images_path(book)` (index/create). `update`/`destroy`/`set_primary` ride the existing flat `admin_image_path` routes.

- [ ] **Step 1: Write the failing images-wiring test**

The image upload itself (ActiveStorage multipart) is already covered by the shared controller's own tests; here we prove the books nesting resolves the parent and the frame renders. Append:

```ruby
      test "the book images index frame renders for the book" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_images_path(@book)
        assert_response :success
      end
```

- [ ] **Step 2: Run to confirm failure**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb -n /images/`
Expected: FAIL — `admin_books_book_images_path` is undefined (route not nested yet).

- [ ] **Step 3: Nest the images route**

In `web-app/config/routes.rb`, expand the `resources :books` block:

```ruby
      resources :books do
        resources :images, only: [:index, :create], controller: "/admin/images"
        collection do
          get :search
        end
      end
```

- [ ] **Step 4: Run to green (wiring works)**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb -n /images/`
Expected: PASS — the shared `Admin::ImagesController#index` resolves `@parent` via `parent_from_params({book_id:…}, domain: :books)` and renders.

- [ ] **Step 5: Add the images section + upload dialog to the show page**

In `web-app/app/views/admin/books/books/show.html.erb`, inside the sidebar `<div class="space-y-6">` (above or below the Metadata card), add an Images card with a lazy turbo frame, and add the upload `<dialog>` at the very end of the outer `<div class="space-y-6">`. Adapt the games version (`app/views/admin/games/games/show.html.erb`), swapping the URLs to `admin_books_book_images_path(@book)`:

Images card (sidebar):

```erb
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Images</h2>
            <% if current_user_can_write? %>
              <button class="btn btn-sm btn-ghost" onclick="add_book_image_modal.showModal()">+ Add</button>
            <% end %>
          </div>
          <%= turbo_frame_tag "images_list", loading: :lazy, src: admin_books_book_images_path(@book) do %>
            <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
          <% end %>
        </div>
      </div>
```

Upload dialog (place just before the final closing `</div>` of the page's outer container):

```erb
  <% if current_user_can_write? %>
    <dialog id="add_book_image_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Image</h3>
        <%= form_with model: Image.new, url: admin_books_book_images_path(@book), method: :post, data: {controller: "modal-form", modal_form_modal_id_value: "add_book_image_modal"} do |f| %>
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
            <button type="button" class="btn" onclick="add_book_image_modal.close()">Cancel</button>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
  <% end %>
```

Before writing, open `app/views/admin/games/games/show.html.erb` and copy the exact structure of its `add_image_modal` + images frame so the `modal-form` Stimulus wiring and field names match the shared `Admin::ImagesController#image_params` (`:file, :notes, :primary`) precisely.

- [ ] **Step 6: Run the full controller test**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Browser-verify the upload (dev)**

With `bin/dev` running, on `https://dev-new.thegreatestbooks.org/admin/books` open a book, click **+ Add** under Images, upload a small JPEG, and confirm it appears in the frame and (if Primary was checked) is marked primary. This is the ActiveStorage path unit tests don't exercise; confirm it works end-to-end. Report the outcome.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix && bundle exec standardrb
git add -A
git commit -m "Wire cover-image management into the books admin show page"
```

---

### Task 6: Playwright smoke spec

**Files:**
- Create: `web-app/e2e/tests/books/admin/books.spec.ts`
- Test: the spec itself

**Interfaces:**
- Consumes: the `books-admin` Playwright project + auth (built in increment 3); the book index/show pages (Tasks 1-5).

**Prerequisites:** `bin/dev` running; `e2e/.env` present; the Playwright account is a global admin (`bin/rails e2e:admin` if admin specs land on the public homepage); and `bin/rails search:books:recreate_and_reindex_all` has been run so the search box returns results. The `books-admin` project auth is host-scoped and already wired.

- [ ] **Step 1: Write the smoke spec**

Create `web-app/e2e/tests/books/admin/books.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('books admin — books', () => {
  test('index lists books and links to a show page', async ({ page }) => {
    await page.goto('/admin/books');
    await expect(page.getByRole('heading', { name: 'Books', exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: 'New Book' })).toBeVisible();
  });

  test('create a book and land on its show page', async ({ page }) => {
    await page.goto('/admin/books/new');
    const title = `E2E Smoke Book ${Date.now()}`;
    await page.getByLabel('Title').fill(title);
    await page.getByRole('button', { name: 'Create Book' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();
    await expect(page.getByText('Basic Information')).toBeVisible();
  });
});
```

Note: `Date.now()` is fine inside a Playwright spec (this is Node, not the workflow sandbox). It keeps repeated local runs from colliding on the slug.

- [ ] **Step 2: Verify routing, then run**

```bash
npx playwright test --list --project=books-admin
yarn test:e2e --project=books-admin
```

Expected: the new `books.spec.ts` is listed under `books-admin` (not the public `books` project), and both tests pass. If the run lands on the public homepage, run `bin/rails e2e:admin` and retry.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Add a Playwright smoke spec for the books admin"
```

---

## Verification

Before declaring 4a done, run and paste:

```bash
bin/rails test                # 0 failures, 0 errors — report the total vs the 4622 baseline
bundle exec standardrb        # no offenses
yarn test:e2e --project=books-admin   # book smoke spec passes
yarn test:e2e --project=books          # public books homepage spec still runs
```

Then update `.superpowers/sdd/progress.md` and surface to the owner:
- Categories deferred to increment 6 (the wrong-taxonomy trap), so the book show page has images but no categories section.
- The dev reindex prerequisite (`search:books:recreate_and_reindex_all`) — needed for the search box to return results in dev; unit tests stub it.
- The new test total vs. the 4622 baseline.
