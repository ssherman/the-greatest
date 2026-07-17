# Books Admin 4c — Inline Associations (BookAuthors, Credits, BookRelationships) + Author Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inline management of a book's authors, credits, and related books (and an edition's credits) on the books admin show pages, plus the author typeahead endpoint those pickers need.

**Architecture:** Three focused controllers (`BookAuthorsController`, `CreditsController`, `BookRelationshipsController`) mirror `Admin::Music::AlbumArtistsController`'s inline pattern: a "+ Add" modal on the parent show page (an `AutocompleteComponent` picker + selects) posts a nested `create`; the controller responds with a turbo_stream that replaces the `flash` and the association's list frame; per-row **Edit** modals (`update`) and **Remove** `button_to`s (`destroy`) are top-level shallow routes. `CreditsController` is polymorphic (book **or** edition creditable, resolved via the existing `DomainRouting.parent_from_params`). A `#search`-only `AuthorsController` serves the author typeahead from `Search::Books::Search::AuthorGeneral`. No schema, policy, or registry changes — every association authorizes its **parent** via the existing `BookPolicy`/`EditionPolicy` `:update?`.

**Tech Stack:** Rails 8, Pundit, Turbo Streams + Frames, `AutocompleteComponent` + `autocomplete`/`modal-form` Stimulus controllers, OpenSearch (`AuthorGeneral`), Minitest + fixtures + Mocha, Playwright.

## Global Constraints

- Run **all** commands from `web-app/`. Working dir: `/home/shane/dev/the-greatest/web-app`.
- **The development database is not disposable.** Books data exists only in dev. Never run a destructive DB command; `RAILS_ENV=test` must be explicit on anything touching fixtures.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- **No code comments** unless the shown code has them. Follow existing patterns.
- Namespace all books code under `Books::` / `Admin::Books::`. Tests mirror the namespace (`module Admin; module Books`).
- Controller tests assert **behavior** (status codes, redirects, `assert_difference` on counts) — never HTML/CSS/copy. Stub `AuthorGeneral` with Mocha in the search test.
- **`raise_on_missing_callback_actions` is ON in dev+test.** A `before_action ..., only: […]` list is validated in full on every dispatch. Each controller here defines all of its actions in a single task, so name only actions that exist.
- **Search endpoints do NOT call Pundit `authorize`** — they rely on the inherited `authenticate_admin!` (books-domain access) for the gate, exactly like 4a's `BooksController#search`. A bare `authorize ::Books::Author` in `#search` would make Pundit infer a nonexistent `search?` policy method and raise (the 4b `set_default?` landmine) — so do NOT add it.
- DaisyUI-5 patterns: forms use `<div class="form-control">` + `w-full`; list-partial action columns use the 4b row-actions pattern (`flex items-center gap-1` + `btn btn-outline btn-xs`, Remove `btn-outline btn-error btn-xs whitespace-nowrap`).
- Use the Rails generator for controllers (`--skip-routes --no-helper`); hand-write views by adapting the cited music templates.

## Deviations from the umbrella design (`docs/superpowers/specs/2026-07-13-books-admin-ui-design.md`)

Read `docs/superpowers/specs/2026-07-16-books-admin-4c-inline-associations-design.md` first — it is the increment-specific design. Key points:

1. **This is increment 4c of the 3-way split of design increment 4** (4a book CRUD, 4b editions — both merged; 4c inline associations — this plan). One increment / one PR.
2. **Three focused controllers, NOT a shared concern** (decision 4c-3). The associations are heterogeneous (Credits polymorphic; BookRelationships has no author/position), so a music-style shared concern would be a leaky abstraction. Each controller DRYs its own turbo_stream via a private render helper.
3. **Author search is `#search`-only** on a partial `AuthorsController`; full author CRUD + index + nav item are increment 5. No `DomainNav` change here.
4. **Credits are added to BOTH the book and edition show pages** — this is the credits section 4b deferred.
5. **A single shared frame id `credits_list`** serves credits on both pages (book show and edition show are separate pages, so no collision). BookAuthors uses `book_authors_list`, BookRelationships uses `book_relationships_list`.

## Prerequisite (already done; re-run if the dev author index is empty)

The author OpenSearch index was reindexed on 2026-07-16 via `bin/rails search:books:recreate_authors` (58,193 authors; `AuthorGeneral("Tolstoy")` verified returning hits). Unit tests stub `AuthorGeneral`; only the browser/Playwright typeahead needs the live index. If the author typeahead returns nothing in dev, re-run that task.

## Fixtures (no new fixtures needed)

- `books_books(:war_and_peace)`, `books_editions(:wp_maude)`, `books_authors(:tolstoy)` (from inc 3), `users(:admin_user)`, `users(:regular_user)`.
- For a second author/book in tests, create records inline (e.g. `::Books::Author.create!(name: "…", kind: :person)`).

---

### Task 1: Routes + author-search endpoint

**Files:**
- Modify: `web-app/config/routes.rb` (the books admin `resources :books` block)
- Create: `web-app/app/controllers/admin/books/authors_controller.rb`
- Test: `web-app/test/controllers/admin/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: `Admin::Books::BaseController` (exists); `Search::Books::Search::AuthorGeneral.call(text, size:)` → `[{id: "<string>", score:, source:}]`.
- Produces: all 4c route helpers (`admin_books_book_book_authors_path`, `admin_books_book_author_path`, `admin_books_book_relationships_path`, `admin_books_book_relationship_path`, `admin_books_book_credits_path`, `admin_books_edition_credits_path`, `admin_books_credit_path`, `search_admin_books_authors_path`); `search` returns JSON `[{value: id, text: name}]`.

- [ ] **Step 1: Write the failing author-search test**

Create `web-app/test/controllers/admin/books/authors_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class AuthorsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "search redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get search_admin_books_authors_path(q: "tol")
        assert_redirected_to books_root_path
      end

      test "search returns autocomplete JSON for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorGeneral.expects(:call).with("tol", size: 20).returns([{id: @author.id.to_s, score: 1.0, source: {"name" => @author.name}}])
        get search_admin_books_authors_path(q: "tol")
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal @author.id, body.first["value"]
        assert_equal @author.name, body.first["text"]
      end

      test "search returns an empty array when nothing matches" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([])
        get search_admin_books_authors_path(q: "zzz")
        assert_response :success
        assert_equal [], JSON.parse(response.body)
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/admin/books/authors_controller_test.rb`
Expected: FAIL — no route / no controller.

- [ ] **Step 3: Add the routes**

In `web-app/config/routes.rb`, replace the books admin `resources :books` block (inside the books `DomainConstraint`) with:

```ruby
      resources :books do
        resources :editions, shallow: true do
          member do
            post :set_default
          end
          resources :images, only: [:index, :create], controller: "/admin/images"
          resources :credits, only: [:create]
        end
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :book_authors, only: [:create]
        resources :book_relationships, only: [:create]
        resources :credits, only: [:create]
        collection do
          get :search
        end
      end

      resources :book_authors, only: [:update, :destroy]
      resources :book_relationships, only: [:update, :destroy]
      resources :credits, only: [:update, :destroy]
      resources :authors, only: [] do
        collection do
          get :search
        end
      end
```

- [ ] **Step 4: Create the AuthorsController**

Create `web-app/app/controllers/admin/books/authors_controller.rb`:

```ruby
class Admin::Books::AuthorsController < Admin::Books::BaseController
  def search
    results = ::Search::Books::Search::AuthorGeneral.call(params[:q], size: 20)
    author_ids = results.map { |r| r[:id].to_i }

    if author_ids.empty?
      render json: []
      return
    end

    authors = ::Books::Author.where(id: author_ids).in_order_of(:id, author_ids)
    render json: authors.map { |a| {value: a.id, text: a.name} }
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS (3/3).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/authors_controller.rb
git add config/routes.rb app/controllers/admin/books/authors_controller.rb test/controllers/admin/books/authors_controller_test.rb
git commit -m "Add 4c routes and the author-search typeahead endpoint"
```

---

### Task 2: BookAuthors — inline on the book show page

**Files:**
- Create: `web-app/app/controllers/admin/books/book_authors_controller.rb`
- Create: `web-app/app/views/admin/books/books/_book_authors_list.html.erb`
- Modify: `web-app/app/views/admin/books/books/show.html.erb` (add the Authors card + add-modal)
- Test: `web-app/test/controllers/admin/books/book_authors_controller_test.rb`

**Interfaces:**
- Consumes: routes from Task 1; `search_admin_books_authors_path` (Task 1); `Books::BookPolicy` (exists); `AutocompleteComponent`, `modal-form` Stimulus (exist).
- Produces: `book_authors_list` turbo frame + partial; create/update/destroy on `Books::BookAuthor`.

- [ ] **Step 1: Write the failing controller test**

Create `web-app/test/controllers/admin/books/book_authors_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class BookAuthorsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "create adds an author to the book and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        author = ::Books::Author.create!(name: "Fresh Author", kind: :person)
        assert_difference("@book.book_authors.count", 1) do
          post admin_books_book_book_authors_path(@book), params: {books_book_author: {author_id: author.id, role: "author", position: 1, credited_as: "F. Author"}}
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "F. Author", @book.book_authors.order(:created_at).last.credited_as
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::BookAuthor.count") do
          post admin_books_book_book_authors_path(@book), params: {books_book_author: {author_id: @author.id, role: "author"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the role and position" do
        sign_in_as(@admin_user, stub_auth: true)
        ba = @book.book_authors.create!(author: ::Books::Author.create!(name: "Up Author", kind: :person), role: :author, position: 1)
        patch admin_books_book_author_path(ba), params: {books_book_author: {role: "editor", position: 3}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "editor", ba.reload.role
        assert_equal 3, ba.position
      end

      test "destroy removes the association" do
        sign_in_as(@admin_user, stub_auth: true)
        ba = @book.book_authors.create!(author: ::Books::Author.create!(name: "Del Author", kind: :person), role: :author)
        assert_difference("::Books::BookAuthor.count", -1) do
          delete admin_books_book_author_path(ba)
        end
        assert_redirected_to admin_books_book_path(@book)
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/admin/books/book_authors_controller_test.rb`
Expected: FAIL — no controller.

- [ ] **Step 3: Create the controller**

Create `web-app/app/controllers/admin/books/book_authors_controller.rb`:

```ruby
class Admin::Books::BookAuthorsController < Admin::Books::BaseController
  before_action :set_book_author, only: [:update, :destroy]

  def create
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_author = @book.book_authors.build(book_author_params)

    if @book_author.save
      respond_to do |format|
        format.turbo_stream { render_book_authors("Author added.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Author added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_author) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_author.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @book = @book_author.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy

    if @book_author.update(book_author_params)
      respond_to do |format|
        format.turbo_stream { render_book_authors("Author updated.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Author updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_author) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_author.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @book = @book_author.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_author.destroy!

    respond_to do |format|
      format.turbo_stream { render_book_authors("Author removed.") }
      format.html { redirect_to admin_books_book_path(@book), notice: "Author removed." }
    end
  end

  private

  def set_book_author
    @book_author = ::Books::BookAuthor.find(params[:id])
  end

  def book_author_params
    params.require(:books_book_author).permit(:author_id, :role, :position, :credited_as)
  end

  def render_book_authors(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("book_authors_list", partial: "admin/books/books/book_authors_list", locals: {book: @book})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/controllers/admin/books/book_authors_controller_test.rb`
Expected: PASS (4/4). (The controller works before the views exist — tests use the html format.)

- [ ] **Step 5: Create the list partial**

Create `web-app/app/views/admin/books/books/_book_authors_list.html.erb`:

```erb
<%= turbo_frame_tag "book_authors_list" do %>
  <% if book.book_authors.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr><th>Position</th><th>Author</th><th>Role</th><th>Credited As</th><th class="text-right">Actions</th></tr>
        </thead>
        <tbody>
          <% book.book_authors.order(:position, :id).includes(:author).each do |book_author| %>
            <tr>
              <td><span class="badge badge-sm"><%= book_author.position %></span></td>
              <td><%= book_author.author.name %></td>
              <td><%= book_author.role.titleize %></td>
              <td class="text-sm text-base-content/70"><%= book_author.credited_as.presence || "—" %></td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-1">
                  <% if current_user_can_write? %>
                    <button class="btn btn-outline btn-xs whitespace-nowrap" onclick="edit_book_author_<%= book_author.id %>_modal.showModal()">Edit</button>
                  <% end %>
                  <% if current_user_can_delete? %>
                    <%= button_to "Remove", admin_books_book_author_path(book_author), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", data: {turbo_confirm: "Remove #{book_author.author.name} from this book?"}, form: {data: {turbo_frame: "book_authors_list"}} %>
                  <% end %>
                </div>
              </td>
            </tr>

            <% if current_user_can_write? %>
              <dialog id="edit_book_author_<%= book_author.id %>_modal" class="modal">
                <div class="modal-box">
                  <h3 class="font-bold text-lg mb-4">Edit Author</h3>
                  <%= form_with model: book_author, url: admin_books_book_author_path(book_author), method: :patch, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "edit_book_author_#{book_author.id}_modal", turbo_frame: "book_authors_list"} do |f| %>
                    <div class="form-control">
                      <%= f.label :role, class: "label" do %><span class="label-text font-semibold">Role</span><% end %>
                      <%= f.select :role, ::Books::BookAuthor.roles.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
                    </div>
                    <div class="form-control">
                      <%= f.label :position, class: "label" do %><span class="label-text font-semibold">Position</span><% end %>
                      <%= f.number_field :position, min: 1, class: "input input-bordered w-full" %>
                    </div>
                    <div class="form-control">
                      <%= f.label :credited_as, class: "label" do %><span class="label-text font-semibold">Credited As</span><% end %>
                      <%= f.text_field :credited_as, class: "input input-bordered w-full" %>
                    </div>
                    <div class="modal-action">
                      <button type="button" class="btn" onclick="edit_book_author_<%= book_author.id %>_modal.close()">Cancel</button>
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
    <p class="text-base-content/60 text-sm">No authors yet.</p>
  <% end %>
<% end %>
```

- [ ] **Step 6: Add the Authors card + add-modal to the book show page**

In `web-app/app/views/admin/books/books/show.html.erb`, insert this card **after** the Editions card's closing `</div>` (currently line 90) and **before** the `<% if current_user_can_write? %>` image-modal block (currently line 92):

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Authors <span class="badge badge-ghost"><%= @book.book_authors.count %></span></h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_book_author_modal.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= turbo_frame_tag "book_authors_list" do %>
        <%= render "admin/books/books/book_authors_list", book: @book %>
      <% end %>
    </div>
  </div>
```

Then insert the add-modal inside the existing `<% if current_user_can_write? %>` block (the same block that holds `add_book_image_modal`), right after that `<dialog id="add_book_image_modal" …>…</dialog>`:

```erb
    <dialog id="add_book_author_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Author</h3>
        <%= form_with model: ::Books::BookAuthor.new, url: admin_books_book_book_authors_path(@book), method: :post, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "add_book_author_modal"} do |f| %>
          <div class="form-control">
            <%= f.label :author_id, class: "label" do %><span class="label-text font-semibold">Author <span class="text-error">*</span></span><% end %>
            <%= render AutocompleteComponent.new(name: "books_book_author[author_id]", url: search_admin_books_authors_path, placeholder: "Search for an author…", required: true) %>
          </div>
          <div class="form-control">
            <%= f.label :role, class: "label" do %><span class="label-text font-semibold">Role</span><% end %>
            <%= f.select :role, ::Books::BookAuthor.roles.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
          </div>
          <div class="form-control">
            <%= f.label :position, class: "label" do %><span class="label-text font-semibold">Position</span><% end %>
            <%= f.number_field :position, value: @book.book_authors.maximum(:position).to_i + 1, min: 1, class: "input input-bordered w-full" %>
          </div>
          <div class="form-control">
            <%= f.label :credited_as, class: "label" do %><span class="label-text font-semibold">Credited As</span><% end %>
            <%= f.text_field :credited_as, class: "input input-bordered w-full" %>
          </div>
          <div class="modal-action">
            <button type="button" class="btn" onclick="add_book_author_modal.close()">Cancel</button>
            <%= f.submit "Add Author", class: "btn btn-primary" %>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
```

- [ ] **Step 7: Run the full admin/books tree + lint**

Run: `bin/rails test test/controllers/admin/books/`
Expected: PASS (existing + the 4 new book_authors tests).

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/book_authors_controller.rb
git add app/controllers/admin/books/book_authors_controller.rb app/views/admin/books/books/_book_authors_list.html.erb app/views/admin/books/books/show.html.erb test/controllers/admin/books/book_authors_controller_test.rb
git commit -m "Add inline BookAuthors management on the book show page"
```

---

### Task 3: BookRelationships — inline on the book show page (+ book-search exclude_id)

**Files:**
- Modify: `web-app/app/controllers/admin/books/books_controller.rb` (`search` gains `exclude_id`)
- Create: `web-app/app/controllers/admin/books/book_relationships_controller.rb`
- Create: `web-app/app/views/admin/books/books/_book_relationships_list.html.erb`
- Modify: `web-app/app/views/admin/books/books/show.html.erb` (Related Books card + add-modal)
- Test: `web-app/test/controllers/admin/books/book_relationships_controller_test.rb`
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb` (append an exclude_id test)

**Interfaces:**
- Consumes: routes from Task 1; `search_admin_books_books_path` (4a) now with `exclude_id`; `Books::BookPolicy`.
- Produces: `book_relationships_list` frame + partial; create/update/destroy on `Books::BookRelationship`.

- [ ] **Step 1: Write the failing exclude_id test**

Append to `web-app/test/controllers/admin/books/books_controller_test.rb` (inside the class):

```ruby
      test "search omits the excluded book id" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Other Book", book_kind: "standalone")
        ::Search::Books::Search::BookAutocomplete.stubs(:call).returns([{id: @book.id.to_s, score: 1.0, source: {}}, {id: other.id.to_s, score: 0.9, source: {}}])
        get search_admin_books_books_path(q: "book", exclude_id: @book.id)
        ids = JSON.parse(response.body).map { |r| r["value"] }
        assert_not_includes ids, @book.id
        assert_includes ids, other.id
      end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: FAIL — the excluded id is still present.

- [ ] **Step 3: Add exclude_id to BooksController#search**

In `web-app/app/controllers/admin/books/books_controller.rb`, in `search`, filter the ids after mapping. Change:

```ruby
    book_ids = results.map { |r| r[:id].to_i }

    if book_ids.empty?
```

to:

```ruby
    book_ids = results.map { |r| r[:id].to_i }
    book_ids.delete(params[:exclude_id].to_i) if params[:exclude_id].present?

    if book_ids.empty?
```

- [ ] **Step 4: Run to verify the exclude_id test passes**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing relationships controller test**

Create `web-app/test/controllers/admin/books/book_relationships_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class BookRelationshipsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a relationship and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related One", book_kind: "standalone")
        assert_difference("@book.book_relationships.count", 1) do
          post admin_books_book_book_relationships_path(@book), params: {books_book_relationship: {related_book_id: other.id, relation_type: "adaptation_of"}}
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "adaptation_of", @book.book_relationships.order(:created_at).last.relation_type
      end

      test "create rejects a self-reference" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::BookRelationship.count") do
          post admin_books_book_book_relationships_path(@book), params: {books_book_relationship: {related_book_id: @book.id, relation_type: "related_to"}}
        end
        assert_redirected_to admin_books_book_path(@book)
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related Two", book_kind: "standalone")
        assert_no_difference("::Books::BookRelationship.count") do
          post admin_books_book_book_relationships_path(@book), params: {books_book_relationship: {related_book_id: other.id, relation_type: "related_to"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the relation type" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related Three", book_kind: "standalone")
        rel = @book.book_relationships.create!(related_book: other, relation_type: :contains)
        patch admin_books_book_relationship_path(rel), params: {books_book_relationship: {relation_type: "revision_of"}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "revision_of", rel.reload.relation_type
      end

      test "destroy removes the relationship" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related Four", book_kind: "standalone")
        rel = @book.book_relationships.create!(related_book: other, relation_type: :contains)
        assert_difference("::Books::BookRelationship.count", -1) do
          delete admin_books_book_relationship_path(rel)
        end
        assert_redirected_to admin_books_book_path(@book)
      end
    end
  end
end
```

- [ ] **Step 6: Run to verify it fails**

Run: `bin/rails test test/controllers/admin/books/book_relationships_controller_test.rb`
Expected: FAIL — no controller.

- [ ] **Step 7: Create the controller**

Create `web-app/app/controllers/admin/books/book_relationships_controller.rb`:

```ruby
class Admin::Books::BookRelationshipsController < Admin::Books::BaseController
  before_action :set_book_relationship, only: [:update, :destroy]

  def create
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_relationship = @book.book_relationships.build(book_relationship_params)

    if @book_relationship.save
      respond_to do |format|
        format.turbo_stream { render_book_relationships("Related book added.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Related book added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_relationship) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @book = @book_relationship.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy

    if @book_relationship.update(book_relationship_params)
      respond_to do |format|
        format.turbo_stream { render_book_relationships("Relationship updated.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Relationship updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_relationship) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @book = @book_relationship.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_relationship.destroy!

    respond_to do |format|
      format.turbo_stream { render_book_relationships("Related book removed.") }
      format.html { redirect_to admin_books_book_path(@book), notice: "Related book removed." }
    end
  end

  private

  def set_book_relationship
    @book_relationship = ::Books::BookRelationship.find(params[:id])
  end

  def book_relationship_params
    params.require(:books_book_relationship).permit(:related_book_id, :relation_type)
  end

  def render_book_relationships(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("book_relationships_list", partial: "admin/books/books/book_relationships_list", locals: {book: @book})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
```

- [ ] **Step 8: Run to verify it passes**

Run: `bin/rails test test/controllers/admin/books/book_relationships_controller_test.rb`
Expected: PASS (5/5).

- [ ] **Step 9: Create the list partial**

Create `web-app/app/views/admin/books/books/_book_relationships_list.html.erb`:

```erb
<%= turbo_frame_tag "book_relationships_list" do %>
  <% if book.book_relationships.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr><th>Relation</th><th>Related Book</th><th class="text-right">Actions</th></tr>
        </thead>
        <tbody>
          <% book.book_relationships.includes(:related_book).each do |rel| %>
            <tr>
              <td><span class="badge badge-ghost"><%= rel.relation_type.titleize %></span></td>
              <td><%= link_to rel.related_book.title, admin_books_book_path(rel.related_book), class: "link link-hover", data: {turbo_frame: "_top"} %></td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-1">
                  <% if current_user_can_write? %>
                    <button class="btn btn-outline btn-xs whitespace-nowrap" onclick="edit_book_relationship_<%= rel.id %>_modal.showModal()">Edit</button>
                  <% end %>
                  <% if current_user_can_delete? %>
                    <%= button_to "Remove", admin_books_book_relationship_path(rel), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", data: {turbo_confirm: "Remove this relationship?"}, form: {data: {turbo_frame: "book_relationships_list"}} %>
                  <% end %>
                </div>
              </td>
            </tr>

            <% if current_user_can_write? %>
              <dialog id="edit_book_relationship_<%= rel.id %>_modal" class="modal">
                <div class="modal-box">
                  <h3 class="font-bold text-lg mb-4">Edit Relationship</h3>
                  <%= form_with model: rel, url: admin_books_book_relationship_path(rel), method: :patch, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "edit_book_relationship_#{rel.id}_modal", turbo_frame: "book_relationships_list"} do |f| %>
                    <div class="form-control">
                      <%= f.label :relation_type, class: "label" do %><span class="label-text font-semibold">Relation</span><% end %>
                      <%= f.select :relation_type, ::Books::BookRelationship.relation_types.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
                    </div>
                    <div class="modal-action">
                      <button type="button" class="btn" onclick="edit_book_relationship_<%= rel.id %>_modal.close()">Cancel</button>
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
    <p class="text-base-content/60 text-sm">No related books yet.</p>
  <% end %>
<% end %>
```

- [ ] **Step 10: Add the Related Books card + add-modal to the book show page**

In `web-app/app/views/admin/books/books/show.html.erb`, insert this card immediately **after** the Authors card (from Task 2), before the image-modal `<% if current_user_can_write? %>` block:

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Related Books <span class="badge badge-ghost"><%= @book.book_relationships.count %></span></h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_book_relationship_modal.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= turbo_frame_tag "book_relationships_list" do %>
        <%= render "admin/books/books/book_relationships_list", book: @book %>
      <% end %>
    </div>
  </div>
```

Then insert the add-modal alongside the other add-modals inside the `<% if current_user_can_write? %>` block (after `add_book_author_modal`):

```erb
    <dialog id="add_book_relationship_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Add Related Book</h3>
        <%= form_with model: ::Books::BookRelationship.new, url: admin_books_book_book_relationships_path(@book), method: :post, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "add_book_relationship_modal"} do |f| %>
          <div class="form-control">
            <%= f.label :related_book_id, class: "label" do %><span class="label-text font-semibold">Related Book <span class="text-error">*</span></span><% end %>
            <%= render AutocompleteComponent.new(name: "books_book_relationship[related_book_id]", url: search_admin_books_books_path(exclude_id: @book.id), placeholder: "Search for a book…", required: true) %>
          </div>
          <div class="form-control">
            <%= f.label :relation_type, class: "label" do %><span class="label-text font-semibold">Relation</span><% end %>
            <%= f.select :relation_type, ::Books::BookRelationship.relation_types.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
          </div>
          <div class="modal-action">
            <button type="button" class="btn" onclick="add_book_relationship_modal.close()">Cancel</button>
            <%= f.submit "Add Related Book", class: "btn btn-primary" %>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
```

- [ ] **Step 11: Run the admin/books tree + lint and commit**

Run: `bin/rails test test/controllers/admin/books/`
Expected: PASS.

```bash
bundle exec standardrb --fix app/controllers/admin/books/book_relationships_controller.rb app/controllers/admin/books/books_controller.rb
git add app/controllers/admin/books/book_relationships_controller.rb app/controllers/admin/books/books_controller.rb app/views/admin/books/books/_book_relationships_list.html.erb app/views/admin/books/books/show.html.erb test/controllers/admin/books/book_relationships_controller_test.rb test/controllers/admin/books/books_controller_test.rb
git commit -m "Add inline BookRelationships and a book-search exclude_id"
```

---

### Task 4: Credits — inline on the book AND edition show pages (polymorphic)

**Files:**
- Create: `web-app/app/controllers/admin/books/credits_controller.rb`
- Create: `web-app/app/views/admin/books/credits/_credits_list.html.erb`
- Create: `web-app/app/views/admin/books/credits/_add_credit_modal.html.erb`
- Modify: `web-app/app/views/admin/books/books/show.html.erb` (Credits card + add-credit modal for the book)
- Modify: `web-app/app/views/admin/books/editions/show.html.erb` (Credits card + add-credit modal for the edition)
- Test: `web-app/test/controllers/admin/books/credits_controller_test.rb`

**Interfaces:**
- Consumes: routes from Task 1 (`admin_books_book_credits_path`, `admin_books_edition_credits_path`, `admin_books_credit_path`); `Admin::DomainRouting.parent_from_params(params, domain: :books)` (resolves `book_id` → `Books::Book`, `edition_id` → `Books::Edition`); `Books::BookPolicy` / `Books::EditionPolicy`; the author search + `AutocompleteComponent`.
- Produces: a single `credits_list` frame shared across both show pages; create/update/destroy on the polymorphic `Books::Credit`.

- [ ] **Step 1: Write the failing controller test (both creditable types)**

Create `web-app/test/controllers/admin/books/credits_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class CreditsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @edition = books_editions(:wp_maude)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a credit to a book and redirects to the book" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("@book.credits.count", 1) do
          post admin_books_book_credits_path(@book), params: {books_credit: {author_id: @author.id, role: "translator", position: 1}}
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "translator", @book.credits.order(:created_at).last.role
      end

      test "create adds a credit to an edition and redirects to the edition" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("@edition.credits.count", 1) do
          post admin_books_edition_credits_path(@edition), params: {books_credit: {author_id: @author.id, role: "illustrator"}}
        end
        assert_redirected_to admin_books_edition_path(@edition)
        assert_equal "illustrator", @edition.credits.order(:created_at).last.role
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Credit.count") do
          post admin_books_book_credits_path(@book), params: {books_credit: {author_id: @author.id, role: "editor"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the role" do
        sign_in_as(@admin_user, stub_auth: true)
        credit = @book.credits.create!(author: @author, role: :translator)
        patch admin_books_credit_path(credit), params: {books_credit: {role: "editor", position: 2}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "editor", credit.reload.role
      end

      test "destroy removes the credit and redirects to its creditable" do
        sign_in_as(@admin_user, stub_auth: true)
        credit = @edition.credits.create!(author: @author, role: :narrator)
        assert_difference("::Books::Credit.count", -1) do
          delete admin_books_credit_path(credit)
        end
        assert_redirected_to admin_books_edition_path(@edition)
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/admin/books/credits_controller_test.rb`
Expected: FAIL — no controller.

- [ ] **Step 3: Create the polymorphic controller**

Create `web-app/app/controllers/admin/books/credits_controller.rb`:

```ruby
class Admin::Books::CreditsController < Admin::Books::BaseController
  before_action :set_credit, only: [:update, :destroy]

  def create
    @creditable = Admin::DomainRouting.parent_from_params(params, domain: :books)
    authorize_creditable
    @credit = @creditable.credits.build(credit_params)

    if @credit.save
      respond_to do |format|
        format.turbo_stream { render_credits("Credit added.") }
        format.html { redirect_to creditable_path(@creditable), notice: "Credit added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_credit_error }
        format.html { redirect_to creditable_path(@creditable), alert: @credit.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @creditable = @credit.creditable
    authorize_creditable

    if @credit.update(credit_params)
      respond_to do |format|
        format.turbo_stream { render_credits("Credit updated.") }
        format.html { redirect_to creditable_path(@creditable), notice: "Credit updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_credit_error }
        format.html { redirect_to creditable_path(@creditable), alert: @credit.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @creditable = @credit.creditable
    authorize_creditable
    @credit.destroy!

    respond_to do |format|
      format.turbo_stream { render_credits("Credit removed.") }
      format.html { redirect_to creditable_path(@creditable), notice: "Credit removed." }
    end
  end

  private

  def set_credit
    @credit = ::Books::Credit.find(params[:id])
  end

  def credit_params
    params.require(:books_credit).permit(:author_id, :role, :position)
  end

  def authorize_creditable
    policy_class = @creditable.is_a?(::Books::Edition) ? ::Books::EditionPolicy : ::Books::BookPolicy
    authorize @creditable, :update?, policy_class: policy_class
  end

  def creditable_path(creditable)
    creditable.is_a?(::Books::Edition) ? admin_books_edition_path(creditable) : admin_books_book_path(creditable)
  end

  def render_credits(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("credits_list", partial: "admin/books/credits/credits_list", locals: {creditable: @creditable})
    ]
  end

  def render_credit_error
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: @credit.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/controllers/admin/books/credits_controller_test.rb`
Expected: PASS (5/5).

- [ ] **Step 5: Create the shared credits list partial**

Create `web-app/app/views/admin/books/credits/_credits_list.html.erb`:

```erb
<%= turbo_frame_tag "credits_list" do %>
  <% if creditable.credits.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr><th>Position</th><th>Author</th><th>Role</th><th class="text-right">Actions</th></tr>
        </thead>
        <tbody>
          <% creditable.credits.ordered.includes(:author).each do |credit| %>
            <tr>
              <td><span class="badge badge-sm"><%= credit.position %></span></td>
              <td><%= credit.author.name %></td>
              <td><%= credit.role.titleize %></td>
              <td class="text-right">
                <div class="flex items-center justify-end gap-1">
                  <% if current_user_can_write? %>
                    <button class="btn btn-outline btn-xs whitespace-nowrap" onclick="edit_credit_<%= credit.id %>_modal.showModal()">Edit</button>
                  <% end %>
                  <% if current_user_can_delete? %>
                    <%= button_to "Remove", admin_books_credit_path(credit), method: :delete, class: "btn btn-outline btn-error btn-xs whitespace-nowrap", data: {turbo_confirm: "Remove this credit?"}, form: {data: {turbo_frame: "credits_list"}} %>
                  <% end %>
                </div>
              </td>
            </tr>

            <% if current_user_can_write? %>
              <dialog id="edit_credit_<%= credit.id %>_modal" class="modal">
                <div class="modal-box">
                  <h3 class="font-bold text-lg mb-4">Edit Credit</h3>
                  <%= form_with model: credit, url: admin_books_credit_path(credit), method: :patch, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "edit_credit_#{credit.id}_modal", turbo_frame: "credits_list"} do |f| %>
                    <div class="form-control">
                      <%= f.label :role, class: "label" do %><span class="label-text font-semibold">Role</span><% end %>
                      <%= f.select :role, ::Books::Credit.roles.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
                    </div>
                    <div class="form-control">
                      <%= f.label :position, class: "label" do %><span class="label-text font-semibold">Position</span><% end %>
                      <%= f.number_field :position, min: 1, class: "input input-bordered w-full" %>
                    </div>
                    <div class="modal-action">
                      <button type="button" class="btn" onclick="edit_credit_<%= credit.id %>_modal.close()">Cancel</button>
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
    <p class="text-base-content/60 text-sm">No credits yet.</p>
  <% end %>
<% end %>
```

- [ ] **Step 6: Create the shared add-credit modal partial**

Create `web-app/app/views/admin/books/credits/_add_credit_modal.html.erb` (takes locals `creditable` and `create_url`):

```erb
<dialog id="add_credit_modal" class="modal">
  <div class="modal-box">
    <h3 class="font-bold text-lg mb-4">Add Credit</h3>
    <%= form_with model: ::Books::Credit.new, url: create_url, method: :post, class: "space-y-4", data: {controller: "modal-form", modal_form_modal_id_value: "add_credit_modal"} do |f| %>
      <div class="form-control">
        <%= f.label :author_id, class: "label" do %><span class="label-text font-semibold">Author <span class="text-error">*</span></span><% end %>
        <%= render AutocompleteComponent.new(name: "books_credit[author_id]", url: search_admin_books_authors_path, placeholder: "Search for an author…", required: true) %>
      </div>
      <div class="form-control">
        <%= f.label :role, class: "label" do %><span class="label-text font-semibold">Role</span><% end %>
        <%= f.select :role, ::Books::Credit.roles.keys.map { |k| [k.titleize, k] }, {}, class: "select select-bordered w-full" %>
      </div>
      <div class="form-control">
        <%= f.label :position, class: "label" do %><span class="label-text font-semibold">Position</span><% end %>
        <%= f.number_field :position, value: creditable.credits.maximum(:position).to_i + 1, min: 1, class: "input input-bordered w-full" %>
      </div>
      <div class="modal-action">
        <button type="button" class="btn" onclick="add_credit_modal.close()">Cancel</button>
        <%= f.submit "Add Credit", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
```

- [ ] **Step 7: Add the Credits card + modal to the book show page**

In `web-app/app/views/admin/books/books/show.html.erb`, insert this card after the Related Books card (Task 3), before the image-modal block:

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Credits <span class="badge badge-ghost"><%= @book.credits.count %></span></h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_credit_modal.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= turbo_frame_tag "credits_list" do %>
        <%= render "admin/books/credits/credits_list", creditable: @book %>
      <% end %>
    </div>
  </div>
```

Then, inside the `<% if current_user_can_write? %>` block (after `add_book_relationship_modal`):

```erb
    <%= render "admin/books/credits/add_credit_modal", creditable: @book, create_url: admin_books_book_credits_path(@book) %>
```

- [ ] **Step 8: Add the Credits card + modal to the edition show page**

In `web-app/app/views/admin/books/editions/show.html.erb`, insert this card in the left column (`lg:col-span-2 space-y-6`) after the **Identifiers** card (which currently ends around line 62):

```erb
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Credits <span class="badge badge-ghost"><%= @edition.credits.count %></span></h2>
            <% if current_user_can_write? %>
              <button class="btn btn-sm btn-primary" onclick="add_credit_modal.showModal()">+ Add</button>
            <% end %>
          </div>
          <%= turbo_frame_tag "credits_list" do %>
            <%= render "admin/books/credits/credits_list", creditable: @edition %>
          <% end %>
        </div>
      </div>
```

Then, inside the edition show page's existing `<% if current_user_can_write? %>` block (the one holding `add_edition_image_modal`), after that dialog:

```erb
    <%= render "admin/books/credits/add_credit_modal", creditable: @edition, create_url: admin_books_edition_credits_path(@edition) %>
```

- [ ] **Step 9: Run the admin/books tree + lint**

Run: `bin/rails test test/controllers/admin/books/`
Expected: PASS.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/books/credits_controller.rb
git add app/controllers/admin/books/credits_controller.rb app/views/admin/books/credits/ app/views/admin/books/books/show.html.erb app/views/admin/books/editions/show.html.erb test/controllers/admin/books/credits_controller_test.rb
git commit -m "Add inline polymorphic Credits on the book and edition show pages"
```

---

### Task 5: Playwright smoke spec

**Files:**
- Create: `web-app/e2e/tests/books/admin/associations.spec.ts`

**Interfaces:**
- Consumes: the whole 4c flow (book show → add author / related book / credit; edition show → add credit). Runs against the **dev** database; the author + book typeaheads exercise the live OpenSearch indices (reindexed in the prerequisite).

- [ ] **Step 1: Write the smoke spec**

Create `web-app/e2e/tests/books/admin/associations.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('books admin — inline associations', () => {
  test('add an author and a credit to a book', async ({ page }) => {
    // Create a fresh book.
    await page.goto('/admin/books/new');
    const title = `E2E Assoc Book ${Date.now()}`;
    await page.locator('input[name="books_book[title]"]').fill(title);
    await page.getByRole('button', { name: 'Create Book' }).click();
    await expect(page.getByRole('heading', { name: title })).toBeVisible();

    // Add an author via the typeahead. Scope the "+ Add" click to the Authors card
    // (Images / Related Books / Credits cards also have a "+ Add" button).
    await page.locator('.card', { hasText: 'Authors' }).getByRole('button', { name: '+ Add' }).click();
    await expect(page.getByRole('heading', { name: 'Add Author' })).toBeVisible();
    await page.locator('#books_book_author_author_id_autocomplete').fill('Tolstoy');
    await page.locator('li', { hasText: /tolstoy/i }).first().click();
    await page.getByRole('button', { name: 'Add Author' }).click();
    await expect(page.locator('#book_authors_list')).toContainText(/tolstoy/i);

    // Add a credit via the typeahead.
    await page.locator('.card', { hasText: 'Credits' }).getByRole('button', { name: '+ Add' }).click();
    await expect(page.getByRole('heading', { name: 'Add Credit' })).toBeVisible();
    await page.locator('#books_credit_author_id_autocomplete').fill('Tolstoy');
    await page.locator('li', { hasText: /tolstoy/i }).first().click();
    await page.getByRole('button', { name: 'Add Credit' }).click();
    await expect(page.locator('#credits_list')).toContainText(/tolstoy/i);
  });
});
```

Notes for the implementer:
- **Autocomplete markup:** `AutocompleteComponent` uses autoComplete.js; result rows render as `<li class="… cursor-pointer …">` inside the results list (NOT `role="option"`), and the input id is derived from the field name (`books_book_author[author_id]` → `#books_book_author_author_id_autocomplete`; `books_credit[author_id]` → `#books_credit_author_id_autocomplete`). Clicking the `<li>` fills the hidden `author_id`. If `page.locator('li', { hasText: /tolstoy/i })` proves ambiguous, scope it to the open dialog: `page.locator('dialog[open] li', { hasText: /tolstoy/i })`. Do not add `data-testid` unless nothing else targets it.
- **Assertion:** the added author's name in dev may be lower-cased (`tolstoy`), so the frame assertions use a case-insensitive regex.
- **Card scoping:** every "+ Add" button shares the label "+ Add", so each click is scoped to its card by heading text.

- [ ] **Step 2: Run the spec against the local dev server**

Ensure the dev server is up (`bin/dev`) and the author index is reindexed (prerequisite). Then:

Run: `npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/admin/associations.spec.ts`
Expected: PASS (auth setup + 1 test). If the typeahead dropdown locator does not match, adjust it per the note in Step 1 and re-run.

- [ ] **Step 3: Commit**

```bash
git add e2e/tests/books/admin/associations.spec.ts
git commit -m "Add a Playwright smoke spec for the inline association flows"
```

---

## Verification

From `web-app/`:

- [ ] **Admin + models suite:** `bin/rails test test/controllers/admin/books/ test/lib/admin/domain_routing_test.rb test/models/books/` — all green.
- [ ] **Whole suite:** `bin/rails db:test:prepare && bin/rails test` — green, count ≥ the pre-4c baseline.
- [ ] **Lint:** `bundle exec standardrb` — clean.
- [ ] **Security:** `bin/brakeman --no-pager` — no new warnings.
- [ ] **E2E:** `npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/admin/` — green (dev server up, author index reindexed).
- [ ] **Manual smoke (browser, books host):** on a book show page — add an author (typeahead), edit its role, remove it; add a related book (typeahead excludes the current book); add a credit; on an edition show page — add a credit. Each updates its list frame in place and closes the modal.

## Out of scope (do NOT build here)

- Full author CRUD / author index / author nav item — **increment 5** (this plan adds only `AuthorsController#search`).
- Categories — **increment 6**.
- Any `DomainNav`, schema, policy, or `DomainRouting` change (Credits' polymorphic parent uses the `book_id`/`edition_id` entries already registered from 4a + 4b).
- The `Admin::ImagesController` domain-auth follow-up (pre-existing, cross-domain).
