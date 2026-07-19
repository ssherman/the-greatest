# Books Admin — Increment 6a: Categories + Category Tagging + Shared-Controller Domain-Auth Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `Books::Category` admin at `/admin/categories`, wire category tagging onto the book and author show pages, and fix the shared `CategoryItems`/`Images` controllers so domain-only editors can manage them.

**Architecture:** `Admin::Books::CategoriesController` is a ~15-line thin subclass of `Admin::CategoriesBaseController` (mirrors `Admin::Games::CategoriesController`); its views are one-line wrappers around the existing shared `Admin::Categories::*Component`s driven by `domain_config`. Tagging rides the already-de-forked shared `Admin::CategoryItemsController`, unblocked by two registry data-values (`ENTITIES[...][:category_items_path]` + `CONFIGS[:books][:categories_search_path]`). The auth fix adds a `domain_auth_parent` hook to `Admin::DomainScopedAuth` so `CategoryItems`/`Images` authorize against the parent record's domain instead of the request host.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, Turbo Frames, DaisyUI 5 / Tailwind 4, Playwright.

## Global Constraints

- Run all commands from `web-app/`. Lint with `bundle exec standardrb` (NOT rubocop). Do not run brakeman.
- Namespace all books code `Books::`; tests mirror the namespace (`module Admin; module Books`).
- Rails 8 enum syntax (`enum :x, {a: 0}`); polymorphic `_able`/`item` suffixes; skinny models.
- Controller tests assert **behavior only** (status, params, record deltas) — never HTML/CSS/copy.
- Check actual fixture names before referencing; auth in integration tests via `sign_in_as(user, stub_auth: true)`; JSON/turbo requests use `as: :turbo_stream` / `as: :json`.
- `raise_on_missing_callback_actions` is ON in dev+test — never name an action in a `before_action only: [...]` list before it exists.
- **Do not double-wrap a turbo frame:** a `turbo_frame_tag "X"` that lazy-loads via `src:` must contain only a spinner placeholder; the fetched partial opens `turbo_frame_tag "X"` itself. Never render a frame-opening partial *inside* a same-id frame.
- DaisyUI-5 form pattern: `<div class="form-control">` + `f.label class: "label"` + `w-full` inputs inside a `card`.
- **The dev database is not disposable** — never run destructive DB commands; `create_fixtures` TRUNCATES. This plan touches only test-env fixtures and additive dev data (e2e-created rows).
- Verify with `bin/rails test` (+ `test:system` for UI) and `bundle exec standardrb`; run the Playwright spec with `yarn test:e2e`.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch `books-admin-6a` (already created off main).

---

### Task 1: `DomainScopedAuth` parent hook + `CategoryItemsController` domain auth

Lets a domain-only editor manage category items on their own domain's records; denies cross-domain. The concern change is behavior-neutral for every existing consumer (they don't define `domain_auth_parent`). Tested via the existing music routes (books category-item routes don't exist until Task 4).

**Files:**
- Modify: `web-app/app/controllers/concerns/admin/domain_scoped_auth.rb`
- Modify: `web-app/app/controllers/admin/category_items_controller.rb`
- Test: `web-app/test/controllers/admin/category_items_controller_test.rb`

**Interfaces:**
- Produces: `Admin::DomainScopedAuth#domain_auth_parent` (private, default `nil`); `#domain_for_auth` now resolves `Admin::DomainRouting.domain_for(domain_auth_parent)` when a parent is present, else `current_domain`.
- Consumes: `Admin::DomainRouting.domain_for(record)` → `:music|:games|:books|nil`; `Admin::DomainRouting.parent_from_params(params, domain:)` → parent record or nil.

- [ ] **Step 1: Write the failing tests**

Add these tests inside `Admin::CategoryItemsControllerTest` (the music-host class) in `web-app/test/controllers/admin/category_items_controller_test.rb`, after the existing destroy tests:

```ruby
    # Domain-scoped editor access (shared-controller domain-auth fix)

    test "allows a music domain editor to create a category_item on a music artist" do
      @artist.category_items.destroy_all
      sign_in_as(users(:contractor_user), stub_auth: true) # music editor via domain_roles fixture

      assert_difference "CategoryItem.count", 1 do
        post admin_artist_category_items_path(@artist),
          params: {category_item: {category_id: @rock_category.id}},
          as: :turbo_stream
      end
      assert_response :success
    end

    test "allows a music domain editor to destroy a category_item on a music artist" do
      category_item = CategoryItem.create!(category: @rock_category, item: @artist)
      sign_in_as(users(:contractor_user), stub_auth: true)

      assert_difference "CategoryItem.count", -1 do
        delete admin_category_item_path(category_item), as: :turbo_stream
      end
      assert_response :success
    end

    test "denies a books-only editor on a music artist category_item" do
      @artist.category_items.destroy_all
      books_editor = users(:regular_user)
      books_editor.domain_roles.create!(domain: :books, permission_level: :editor)
      sign_in_as(books_editor, stub_auth: true)

      assert_no_difference "CategoryItem.count" do
        post admin_artist_category_items_path(@artist),
          params: {category_item: {category_id: @rock_category.id}},
          as: :turbo_stream
      end
      assert_redirected_to music_root_path
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/admin/category_items_controller_test.rb -n "/domain editor/"`
Expected: the two "allows a music domain editor…" tests FAIL — the create test gets a redirect (302) instead of `:success` because `CategoryItemsController` still inherits the global-admin/editor-only `authenticate_admin!`. (The "denies a books-only editor" test already passes — it is the isolation guard.)

- [ ] **Step 3: Add the `domain_auth_parent` hook to the concern**

Replace the `domain_for_auth` method in `web-app/app/controllers/concerns/admin/domain_scoped_auth.rb` and add `domain_auth_parent` immediately below it:

```ruby
    def domain_for_auth
      parent = domain_auth_parent
      return Admin::DomainRouting.domain_for(parent)&.to_s if parent

      current_domain&.to_s
    end

    # Controllers that manage a nested/polymorphic parent (images, category items)
    # override this to authorize against the parent record's domain rather than the
    # request host. Default nil → fall back to current_domain (behavior-neutral).
    def domain_auth_parent
      nil
    end
```

Leave `authenticate_admin!`, `domain_with_ranking_configuration_admin_for`, and `access_denied_message` unchanged.

- [ ] **Step 4: Wire `CategoryItemsController` onto the concern**

In `web-app/app/controllers/admin/category_items_controller.rb`, add the include as the first line of the class body and define `domain_auth_parent` in the private section:

```ruby
class Admin::CategoryItemsController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_item, only: [:index, :create]
  before_action :set_category_item, only: [:destroy]
```

Add this method in the `private` section (e.g. above `set_item`):

```ruby
  def domain_auth_parent
    if params[:id].present?
      CategoryItem.find(params[:id]).item
    else
      Admin::DomainRouting.parent_from_params(params, domain: current_domain)
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/category_items_controller_test.rb`
Expected: PASS (all tests, including the pre-existing admin_user ones).

- [ ] **Step 6: Run standardrb**

Run: `bundle exec standardrb app/controllers/concerns/admin/domain_scoped_auth.rb app/controllers/admin/category_items_controller.rb test/controllers/admin/category_items_controller_test.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/concerns/admin/domain_scoped_auth.rb app/controllers/admin/category_items_controller.rb test/controllers/admin/category_items_controller_test.rb
git commit -m "$(cat <<'EOF'
Let domain editors manage category items (inc 6a task 1)

Add a domain_auth_parent hook to DomainScopedAuth so CategoryItemsController
authorizes against the parent record's domain instead of the request host.
Behavior-neutral for existing consumers (default hook returns nil).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `ImagesController` domain auth

Same fix for the shared images controller. The concern hook already exists from Task 1.

**Files:**
- Modify: `web-app/app/controllers/admin/images_controller.rb`
- Test: `web-app/test/controllers/admin/images_controller_test.rb`

**Interfaces:**
- Consumes: `Admin::DomainScopedAuth#domain_auth_parent` (from Task 1).

- [ ] **Step 1: Write the failing tests**

Add these tests inside `Admin::ImagesControllerTest` (the music-host class) in `web-app/test/controllers/admin/images_controller_test.rb`, after the Set Primary tests:

```ruby
  # Domain-scoped editor access (shared-controller domain-auth fix)

  test "should allow a music domain editor to create an image on a music artist" do
    sign_in_as(users(:contractor_user), stub_auth: true) # music editor via domain_roles fixture

    assert_difference("Image.count", 1) do
      post admin_artist_images_path(@artist), params: {
        image: {file: fixture_file_upload("test_image.png", "image/png"), notes: "editor upload"}
      }
    end
  end

  test "should allow a music domain editor to destroy an image" do
    sign_in_as(users(:contractor_user), stub_auth: true)

    assert_difference("Image.count", -1) do
      delete admin_image_path(@image_alt)
    end
  end

  test "should deny a books-only editor on a music artist image" do
    books_editor = users(:regular_user)
    books_editor.domain_roles.create!(domain: :books, permission_level: :editor)
    sign_in_as(books_editor, stub_auth: true)

    assert_no_difference("Image.count") do
      post admin_artist_images_path(@artist), params: {
        image: {file: fixture_file_upload("test_image.png", "image/png"), notes: "nope"}
      }
    end
    assert_redirected_to music_root_path
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/admin/images_controller_test.rb -n "/domain editor/"`
Expected: the two "allow a music domain editor…" tests FAIL (302 redirect / no Image delta) because `ImagesController` still inherits the global-only `authenticate_admin!`.

- [ ] **Step 3: Wire `ImagesController` onto the concern**

In `web-app/app/controllers/admin/images_controller.rb`, add the include as the first line of the class body:

```ruby
class Admin::ImagesController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_parent, only: [:index, :create]
  before_action :set_image, only: [:update, :destroy, :set_primary]
```

Add this method in the `private` section (e.g. above `set_parent`):

```ruby
  def domain_auth_parent
    if params[:id].present?
      Image.find(params[:id]).parent
    else
      Admin::DomainRouting.parent_from_params(params, domain: current_domain)
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/images_controller_test.rb`
Expected: PASS (all tests).

- [ ] **Step 5: Run standardrb**

Run: `bundle exec standardrb app/controllers/admin/images_controller.rb test/controllers/admin/images_controller_test.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/admin/images_controller.rb test/controllers/admin/images_controller_test.rb
git commit -m "$(cat <<'EOF'
Let domain editors manage images (inc 6a task 2)

ImagesController authorizes against the parent record's domain via the
DomainScopedAuth domain_auth_parent hook.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Books categories admin (controller + routes + views + nav + search path)

Full `Books::Category` CRUD at `/admin/categories`, plus the `DomainNav` "Categories" item and `categories_search_path`. Setting the search path together with the nav item is what makes the generic `domain_nav_test` "Categories ⇒ categories_search_path" invariant hold — and closes the music-genre fallback.

**Files:**
- Modify: `web-app/config/routes.rb` (books admin namespace, ~line 307–316)
- Create: `web-app/app/controllers/admin/books/categories_controller.rb`
- Create: `web-app/app/views/admin/books/categories/index.html.erb`
- Create: `web-app/app/views/admin/books/categories/_table.html.erb`
- Create: `web-app/app/views/admin/books/categories/show.html.erb`
- Create: `web-app/app/views/admin/books/categories/new.html.erb`
- Create: `web-app/app/views/admin/books/categories/edit.html.erb`
- Create: `web-app/app/views/admin/books/categories/_form.html.erb`
- Modify: `web-app/app/lib/admin/domain_nav.rb` (`CONFIGS[:books]`)
- Test: `web-app/test/controllers/admin/books/categories_controller_test.rb` (create)
- Test: `web-app/test/lib/admin/domain_nav_test.rb` (add books-categories assertions)

**Interfaces:**
- Produces routes: `admin_books_categories_path`, `admin_books_category_path(c)`, `new_admin_books_category_path`, `edit_admin_books_category_path(c)`, `search_admin_books_categories_path`.
- Produces: `Admin::Books::CategoriesController` (thin subclass; all actions inherited from `Admin::CategoriesBaseController`).

- [ ] **Step 1: Add the routes**

In `web-app/config/routes.rb`, inside the books `namespace :admin, module: "admin/books", as: "admin_books"` block (after the `resources :series_books …` block, before the closing `end` at ~line 316), add:

```ruby
      resources :categories do
        collection do
          get :search
        end
      end
```

- [ ] **Step 2: Verify the route helpers exist**

Run: `bin/rails routes -g admin_books_categor`
Expected: rows for `admin_books_categories` (GET/POST), `search_admin_books_categories` (GET), `new_admin_books_category`, `edit_admin_books_category`, `admin_books_category` (GET/PATCH/PUT/DELETE), all at `/admin/categories…`.

- [ ] **Step 3: Write the failing controller test**

Create `web-app/test/controllers/admin/books/categories_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class CategoriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @category = categories(:books_fiction_genre)
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_categories_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_categories_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_categories_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_categories_path
        assert_response :success
      end

      # Index

      test "index with a search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_categories_path(q: "Fiction")
        assert_response :success
      end

      test "index tolerates a sort-injection attempt" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_categories_path(sort: "'; DROP TABLE categories; --")
        end
        assert_response :success
      end

      # Show

      test "show for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_path(@category)
        assert_response :success
      end

      # Create

      test "creates a category for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Category.count", 1) do
          post admin_books_categories_path, params: {
            books_category: {name: "Magical Realism", description: "Blends realism with magical elements", category_type: "genre"}
          }
        end
        assert_redirected_to admin_books_category_path(::Books::Category.last)
      end

      test "does not create a category with a blank name" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Category.count") do
          post admin_books_categories_path, params: {books_category: {name: "", category_type: "genre"}}
        end
        assert_response :unprocessable_entity
      end

      # Update

      test "updates a category for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_category_path(@category), params: {books_category: {name: "Updated Fiction"}}
        @category.reload
        assert_redirected_to admin_books_category_path(@category)
        assert_equal "Updated Fiction", @category.name
      end

      # Destroy (soft delete)

      test "soft-deletes a category for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Category.count") do
          delete admin_books_category_path(@category)
        end
        assert_redirected_to admin_books_categories_path
        @category.reload
        assert @category.deleted
      end

      # Search

      test "search returns JSON" do
        sign_in_as(@admin_user, stub_auth: true)
        get search_admin_books_categories_path(q: "Fic"), as: :json
        assert_response :success
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/controllers/admin/books/categories_controller_test.rb`
Expected: FAIL — `Admin::Books::CategoriesController` is uninitialized / actions raise (no controller yet).

- [ ] **Step 5: Create the controller**

Create `web-app/app/controllers/admin/books/categories_controller.rb`:

```ruby
class Admin::Books::CategoriesController < Admin::CategoriesBaseController
  include Admin::DomainScopedAuth

  protected

  def model_class = ::Books::Category

  def param_key = :books_category

  def category_path(category) = admin_books_category_path(category)

  def categories_path = admin_books_categories_path

  def new_category_path = new_admin_books_category_path

  def edit_category_path(category) = edit_admin_books_category_path(category)

  def domain_label = "Books"

  def subtitle = "Manage book genres, subjects, locations, and themes"

  def load_show_stats
    @stats = {
      "Books" => @category.books.count,
      "Authors" => @category.authors.count
    }
  end
end
```

- [ ] **Step 6: Create the views (one-line component wrappers, identical to games)**

Create `web-app/app/views/admin/books/categories/index.html.erb`:

```erb
<% content_for :title, "Categories" %>
<%= render Admin::Categories::IndexComponent.new(categories: @categories, pagy: @pagy, domain_config: domain_config) %>
```

Create `web-app/app/views/admin/books/categories/_table.html.erb`:

```erb
<%= render Admin::Categories::TableComponent.new(categories: categories, pagy: pagy, domain_config: domain_config) %>
```

Create `web-app/app/views/admin/books/categories/show.html.erb`:

```erb
<% content_for :title, @category.name %>
<%= render Admin::Categories::ShowComponent.new(category: @category, domain_config: domain_config, stats: @stats) %>
```

Create `web-app/app/views/admin/books/categories/new.html.erb`:

```erb
<% content_for :title, "New Category" %>
<%= render Admin::Categories::NewComponent.new(category: @category, domain_config: domain_config) %>
```

Create `web-app/app/views/admin/books/categories/edit.html.erb`:

```erb
<% content_for :title, "Edit Category: #{@category.name}" %>
<%= render Admin::Categories::EditComponent.new(category: @category, domain_config: domain_config) %>
```

Create `web-app/app/views/admin/books/categories/_form.html.erb`:

```erb
<%= render Admin::Categories::FormComponent.new(category: @category, domain_config: domain_config) %>
```

- [ ] **Step 7: Run the controller test to verify it passes**

Run: `bin/rails test test/controllers/admin/books/categories_controller_test.rb`
Expected: PASS (all tests).

- [ ] **Step 8: Add the nav item + search path to DomainNav**

In `web-app/app/lib/admin/domain_nav.rb`, in `CONFIGS[:books]`, change the `categories_search_path: nil` line to:

```ruby
        categories_search_path: -> { URL_HELPERS.search_admin_books_categories_path },
```

and append a Categories item to `CONFIGS[:books][:items]` (after the Series item):

```ruby
          {label: "Categories", icon: :category, path: -> { URL_HELPERS.admin_books_categories_path }}
```

- [ ] **Step 9: Write the DomainNav test assertions**

Add to `web-app/test/lib/admin/domain_nav_test.rb`, inside `Admin::DomainNavTest`, before the final `end`:

```ruby
    test "the books nav includes a Categories item with a categories_search_path" do
      config = Admin::DomainNav.config_for(:books)
      categories_item = config[:items].find { |item| item[:label] == "Categories" }
      assert categories_item, "books nav is missing a Categories item"
      assert_equal "/admin/categories", categories_item[:path]
      assert categories_item[:icon].present?
      assert config[:categories_search_path].present?
    end
```

- [ ] **Step 10: Run the DomainNav test**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: PASS — both the new books-categories test and the pre-existing generic "a domain whose nav links to Categories has a categories_search_path" invariant pass.

- [ ] **Step 11: Run standardrb + commit**

Run: `bundle exec standardrb app/controllers/admin/books/categories_controller.rb app/lib/admin/domain_nav.rb config/routes.rb test/controllers/admin/books/categories_controller_test.rb test/lib/admin/domain_nav_test.rb`
Expected: no offenses.

```bash
git add config/routes.rb app/controllers/admin/books/categories_controller.rb app/views/admin/books/categories app/lib/admin/domain_nav.rb test/controllers/admin/books/categories_controller_test.rb test/lib/admin/domain_nav_test.rb
git commit -m "$(cat <<'EOF'
Add books categories admin + nav item (inc 6a task 3)

Books::Category CRUD at /admin/categories (thin subclass of
CategoriesBaseController), the DomainNav Categories item, and
categories_search_path — closing the music-genre search fallback.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Category tagging on the book + author show pages

Wire `category_items` onto both show pages via the shared `Admin::CategoryItemsController`, unblocked by the two `ENTITIES` `category_items_path`s. Both `Books::Book` and `Books::Author` carry a `categories` association.

**Files:**
- Modify: `web-app/config/routes.rb` (nest `category_items` under `:books` and `:authors`)
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`ENTITIES["Books::Book"]`, `ENTITIES["Books::Author"]`)
- Modify: `web-app/app/views/admin/books/books/show.html.erb`
- Modify: `web-app/app/views/admin/books/authors/show.html.erb`
- Test: `web-app/test/controllers/admin/category_items_controller_test.rb` (new books-host class)
- Test: `web-app/test/lib/admin/domain_routing_test.rb` (category_items_path resolution)
- Test: `web-app/test/components/admin/add_category_modal_component_test.rb` (create — the form_url/search_url landmine)

**Interfaces:**
- Consumes: `Admin::CategoryItemsController` (domain-auth from Task 1); `Admin::AddCategoryModalComponent#form_url`/`#search_url`; `Admin::DomainRouting.category_items_path_for(record)`.
- Produces routes: `admin_books_book_category_items_path(book)`, `admin_books_author_category_items_path(author)`.

- [ ] **Step 1: Add the nested routes**

In `web-app/config/routes.rb`, add a `category_items` line inside the existing `resources :books do … end` block:

```ruby
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
```

and inside the existing `resources :authors do … end` block:

```ruby
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
```

- [ ] **Step 2: Verify the helpers**

Run: `bin/rails routes -g category_items | grep books`
Expected: `admin_books_book_category_items` and `admin_books_author_category_items` (GET index, POST create).

- [ ] **Step 3: Write the failing registry + component tests**

Add to `web-app/test/lib/admin/domain_routing_test.rb` (inside the existing test class, before its final `end`):

```ruby
    test "category_items_path_for resolves for a books book and author" do
      book = books_books(:war_and_peace)
      author = books_authors(:tolstoy)
      assert_equal Rails.application.routes.url_helpers.admin_books_book_category_items_path(book),
        Admin::DomainRouting.category_items_path_for(book)
      assert_equal Rails.application.routes.url_helpers.admin_books_author_category_items_path(author),
        Admin::DomainRouting.category_items_path_for(author)
    end
```

Create `web-app/test/components/admin/add_category_modal_component_test.rb`:

```ruby
require "test_helper"

module Admin
  class AddCategoryModalComponentTest < ActiveSupport::TestCase
    test "a book targets the books category-tag and search endpoints, never music" do
      book = books_books(:war_and_peace)
      component = Admin::AddCategoryModalComponent.new(item: book)
      helpers = Rails.application.routes.url_helpers

      assert_equal helpers.admin_books_book_category_items_path(book), component.form_url
      assert_equal helpers.search_admin_books_categories_path, component.search_url
      refute_equal helpers.search_admin_categories_path, component.search_url
    end

    test "an author targets the books author category-tag endpoint" do
      author = books_authors(:tolstoy)
      component = Admin::AddCategoryModalComponent.new(item: author)
      helpers = Rails.application.routes.url_helpers

      assert_equal helpers.admin_books_author_category_items_path(author), component.form_url
      assert_equal helpers.search_admin_books_categories_path, component.search_url
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb test/components/admin/add_category_modal_component_test.rb`
Expected: FAIL — `category_items_path_for` returns `nil` (both `ENTITIES` entries still have `category_items_path: nil`), so `form_url` is nil and the assertions fail.

- [ ] **Step 5: Set the registry paths**

In `web-app/app/lib/admin/domain_routing.rb`, change the `"Books::Book"` and `"Books::Author"` entries so `category_items_path` is populated:

```ruby
      "Books::Book" => {
        domain: :books,
        path: ->(r) { URL_HELPERS.admin_books_book_path(r) },
        category_items_path: ->(r) { URL_HELPERS.admin_books_book_category_items_path(r) }
      },
```

```ruby
      "Books::Author" => {
        domain: :books,
        path: ->(r) { URL_HELPERS.admin_books_author_path(r) },
        category_items_path: ->(r) { URL_HELPERS.admin_books_author_category_items_path(r) }
      },
```

- [ ] **Step 6: Run the registry + component tests to verify they pass**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb test/components/admin/add_category_modal_component_test.rb`
Expected: PASS.

- [ ] **Step 7: Write the failing tagging controller tests**

Add a new test class to `web-app/test/controllers/admin/category_items_controller_test.rb`, after the existing `Admin::GamesCategoryItemsControllerTest` class (still inside `module Admin`):

```ruby
  class BooksCategoryItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @book = books_books(:war_and_peace)
      @author = books_authors(:tolstoy)
      @genre = categories(:books_fiction_genre)

      host! Rails.application.config.domains[:books]
      sign_in_as(@admin_user, stub_auth: true)
    end

    test "index for a book with categories" do
      CategoryItem.create!(category: @genre, item: @book)
      get admin_books_book_category_items_path(@book)
      assert_response :success
      assert_match @genre.name, response.body
    end

    test "index for a book without categories" do
      @book.category_items.destroy_all
      get admin_books_book_category_items_path(@book)
      assert_response :success
      assert_match "No categories assigned", response.body
    end

    test "creates a category_item for a book" do
      @book.category_items.destroy_all
      assert_difference "CategoryItem.count", 1 do
        post admin_books_book_category_items_path(@book),
          params: {category_item: {category_id: @genre.id}},
          as: :turbo_stream
      end
      assert_response :success
      assert_match "Category added successfully", response.body
    end

    test "creates a category_item for an author" do
      @author.category_items.destroy_all
      assert_difference "CategoryItem.count", 1 do
        post admin_books_author_category_items_path(@author),
          params: {category_item: {category_id: @genre.id}},
          as: :turbo_stream
      end
      assert_response :success
    end

    test "destroys a category_item for a book" do
      category_item = CategoryItem.create!(category: @genre, item: @book)
      assert_difference "CategoryItem.count", -1 do
        delete admin_category_item_path(category_item), as: :turbo_stream
      end
      assert_response :success
      assert_match "Category removed successfully", response.body
    end

    test "a books domain editor can tag a book" do
      @book.category_items.destroy_all
      books_editor = users(:regular_user)
      books_editor.domain_roles.create!(domain: :books, permission_level: :editor)
      sign_in_as(books_editor, stub_auth: true)

      assert_difference "CategoryItem.count", 1 do
        post admin_books_book_category_items_path(@book),
          params: {category_item: {category_id: @genre.id}},
          as: :turbo_stream
      end
      assert_response :success
    end
  end
```

- [ ] **Step 8: Run the tagging tests to verify they pass**

Run: `bin/rails test test/controllers/admin/category_items_controller_test.rb -n "/BooksCategoryItems/"`
Expected: PASS — the shared controller is already de-forked and the routes now exist.

- [ ] **Step 9: Add the categories card to the book show page**

In `web-app/app/views/admin/books/books/show.html.erb`, insert this card immediately after the Credits card (after its closing `</div>` at ~line 126, before the `<% if current_user_can_write? %>` modals block):

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Categories <span class="badge badge-ghost"><%= @book.categories.count %></span></h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_category_modal_dialog.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= turbo_frame_tag "category_items_list", loading: :lazy, src: admin_books_book_category_items_path(@book) do %>
        <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
      <% end %>
    </div>
  </div>
```

Inside the existing `<% if current_user_can_write? %>` modals block (after the `add_credit_modal` render at ~line 204, before the block's `<% end %>`), add:

```erb
    <%= render Admin::AddCategoryModalComponent.new(item: @book) %>
```

- [ ] **Step 10: Add the categories card to the author show page**

In `web-app/app/views/admin/books/authors/show.html.erb`, insert this card immediately after the "Inbound Relationships" card (after its closing `</div>` at ~line 101, before the `<% if current_user_can_write? %>` modals block):

```erb
  <div class="card bg-base-100 shadow">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Categories <span class="badge badge-ghost"><%= @author.categories.count %></span></h2>
        <% if current_user_can_write? %>
          <button class="btn btn-sm btn-primary" onclick="add_category_modal_dialog.showModal()">+ Add</button>
        <% end %>
      </div>
      <%= turbo_frame_tag "category_items_list", loading: :lazy, src: admin_books_author_category_items_path(@author) do %>
        <div class="flex justify-center py-8"><span class="loading loading-spinner loading-lg"></span></div>
      <% end %>
    </div>
  </div>
```

Inside the author page's existing `<% if current_user_can_write? %>` modals block (after the `add_author_relationship_modal` dialog at ~line 148, before the block's `<% end %>`), add:

```erb
    <%= render Admin::AddCategoryModalComponent.new(item: @author) %>
```

- [ ] **Step 11: Verify both show pages still render**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb test/controllers/admin/books/authors_controller_test.rb`
Expected: PASS — both `show` requests render the new Categories card + `AddCategoryModalComponent` without error (the lazy frame only fetches its `src` in a browser, so the show request itself stays green; the modal's `form_url`/`search_url` resolve to the books endpoints set in Tasks 3–4).

- [ ] **Step 12: Run standardrb + the full touched-test set + commit**

Run: `bundle exec standardrb config/routes.rb app/lib/admin/domain_routing.rb test/controllers/admin/category_items_controller_test.rb test/lib/admin/domain_routing_test.rb test/components/admin/add_category_modal_component_test.rb`
Expected: no offenses.

Run: `bin/rails test test/controllers/admin/category_items_controller_test.rb test/lib/admin/domain_routing_test.rb test/components/admin/add_category_modal_component_test.rb`
Expected: PASS.

```bash
git add config/routes.rb app/lib/admin/domain_routing.rb app/views/admin/books/books/show.html.erb app/views/admin/books/authors/show.html.erb test/controllers/admin/category_items_controller_test.rb test/lib/admin/domain_routing_test.rb test/components/admin/add_category_modal_component_test.rb
git commit -m "$(cat <<'EOF'
Wire category tagging onto book + author show pages (inc 6a task 4)

Nested category_items routes + ENTITIES category_items_path for Books::Book
and Books::Author, and a Categories card on both show pages using the shared
AddCategoryModalComponent (books search + tag endpoints, no music fallback).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Playwright smoke spec

Mirrors `e2e/tests/books/admin/authors.spec.ts`: list + create a category, then tag a book via the live typeahead — asserting the tag lands in the `category_items_list` frame (proves the books, not music, search path end-to-end).

**Files:**
- Create: `web-app/e2e/tests/books/admin/categories.spec.ts`

- [ ] **Step 1: Write the spec**

Create `web-app/e2e/tests/books/admin/categories.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

test.describe("Books admin — categories", () => {
  test("lists categories and links to New Category", async ({ page }) => {
    await page.goto("/admin/categories");
    await expect(page.getByRole("heading", { name: "Categories", level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "New Category" })).toBeVisible();
  });

  test("creates a category and shows it", async ({ page }) => {
    const name = `Test Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();

    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();

    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  });

  test("tags a book with a category via the typeahead", async ({ page }) => {
    const name = `Tag Genre ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.goto("/admin/books");
    await page.locator("table tbody tr").first().getByRole("link", { name: "View" }).click();
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();

    const categoriesCard = page.locator(".card", { hasText: "Categories" });
    await categoriesCard.getByRole("button", { name: "+ Add" }).click();

    const modal = page.locator("dialog#add_category_modal_dialog");
    await expect(modal).toBeVisible();
    await modal.getByPlaceholder("Search for category...").fill(name);
    await modal.locator("li.cursor-pointer").first().click();
    await modal.getByRole("button", { name: "Add Category" }).click();

    await expect(
      page.locator("turbo-frame#category_items_list").getByText(name, { exact: false })
    ).toBeVisible();
  });
});
```

- [ ] **Step 2: Ensure the dev server + books admin user are ready**

The e2e suite needs the local dev server (`bin/dev`) and a books-admin e2e session. If admin specs redirect to the public homepage, the e2e user lost its role — run `bin/rails e2e:admin` to restore it (see the project memory note on e2e admin user).

- [ ] **Step 3: Run the spec**

Run: `yarn test:e2e e2e/tests/books/admin/categories.spec.ts`
Expected: 3 passed. (The tag test navigates to a real dev-DB book; the newly created category is immediately searchable because category search uses SQL `search_by_name`, not OpenSearch.)

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/books/admin/categories.spec.ts
git commit -m "$(cat <<'EOF'
Add books categories Playwright smoke spec (inc 6a task 5)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] Run the full admin suite: `bin/rails test test/controllers/admin test/lib/admin test/components/admin` — expected: all green, no regressions in music/games category or image controller tests.
- [ ] Run the whole suite: `bin/rails test` — expected: green (baseline was 4695+/0).
- [ ] Run `bundle exec standardrb` — expected: no offenses.
- [ ] Run `yarn test:e2e e2e/tests/books/admin/categories.spec.ts` — expected: 3 passed.
- [ ] Confirm no music/games test files were edited except the two shared-controller test files (which only gained tests). Any change to an existing assertion is a red flag — stop and investigate.

## Notes / carried context

- **Viewer vs editor:** `DomainScopedAuth#authenticate_admin!` gates on `can_access_domain?`, which is true for any domain role (viewer included), matching every other domain-scoped admin controller. The category-item/image controllers have no Pundit layer, so a domain *viewer* can now tag/upload. This mirrors the pre-existing shared-partial Remove buttons (unguarded across all domains) and is out of scope to tighten here.
- **6b (next increment, separate plan):** Lists (`Books::List` in the `LISTS` registry) + Ranking configurations (registry `path:` gates auth — will intentionally flip the `ranked_lists`/`ranked_items`/`penalty_applications` books-denial tests red) + the `calculate_books_year_range` fix (D8).
