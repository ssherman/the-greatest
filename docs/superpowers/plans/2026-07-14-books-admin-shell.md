# Books Admin Shell (Increment 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the books admin shell — a working, books-branded admin dashboard at `/admin` on the books host, with the seven Pundit policies later increments authorize against.

**Architecture:** Books plugs into the registry-driven admin layer built in increment 1. A books admin route namespace inside the existing books `DomainConstraint`, an `Admin::Books::BaseController` that inherits the shared auth + dynamic layout, a dashboard, `layouts/books/admin.html.erb`, and a `books` entry in `Admin::DomainNav` (which is what makes the dynamic layout resolve to `books/admin` and the sidebar render books branding). No books entity CRUD — that is increments 4–6.

**Tech Stack:** Rails 8, Pundit, Minitest + fixtures, DaisyUI 5 / Tailwind 4, Playwright.

## Global Constraints

- Run **all** commands from `web-app/`.
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. Never run a destructive DB command; `RAILS_ENV=test` must be explicit on anything that touches fixtures. `ActiveRecord::FixtureSet.create_fixtures` TRUNCATES — never call it.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- **No code comments** unless asked. Self-documenting code, follow existing patterns.
- Namespace all books code under `Books::` / `Admin::Books::`. Tests mirror the namespace.
- Controller tests assert **behavior** (status codes, redirects, no errors) — never HTML copy. Layout assertions are the exception already established in `test/controllers/admin/penalties_controller_test.rb:257-260` (they assert the CSS bundle and `<title>`, which is domain-correctness, not design).
- Every new user-facing page needs a Playwright E2E test (`web-app/e2e/tests/`).

## Deviations from the design doc (`docs/superpowers/specs/2026-07-13-books-admin-ui-design.md`)

Read these before starting — they change what "increment 3" contains.

1. **The routes skeleton is the namespace + `root`, not the full books route table.** Rails resolves controllers lazily, so declaring `resources :books, :authors, :series, …` now would boot fine and give every route helper — but every sidebar link would 500 with `uninitialized constant Admin::Books::BooksController` until increments 4–6 landed. Each increment ships its own routes with its own controllers, so every state is consistent.

2. **No books entries in `Admin::DomainRouting`.** Its `ENTITIES` / `LISTS` tables key off admin path helpers (`admin_books_book_path`, `search_admin_books_books_path`) that do not exist until increments 4 and 6. Registering books with `path: nil` would half-wire the shared images / category-items / list-items controllers. Increments 4–6 register each entity alongside its routes. (`RANKING_CONFIGURATIONS` already carries `Books::RankingConfiguration` with a nil path — leave it.)

3. **The books nav section starts empty.** `Admin::DomainNav::CONFIGS[:books][:items]` is `[]`; increments 4–6 each append their own entry. The sidebar is changed to skip a domain section with no items, so books renders its logo/title + the Global section and no empty `<details>`.

4. **`categories_search_path` becomes optional.** Books has no categories admin until increment 6. `config_for` currently calls `.call` on it unconditionally, and `test/lib/admin/domain_nav_test.rb:48` asserts every domain has one. Both are re-pointed at the invariant that actually matters: a domain whose nav links to **Categories** must supply the search path (that is what `Admin::AddCategoryModalComponent#search_url` needs; without it the modal silently falls back to the *music* search path — the same wrong-domain leak increment 1 fixed).

5. **An E2E dashboard smoke spec ships here, not in increment 7.** CLAUDE.md requires an E2E test for every new user-facing page. Increment 7 still builds the full suite; this is one spec plus the books-admin Playwright project it needs.

---

### Task 1: The books admin shell

The whole shell in one task: routes, layout, base controller, dashboard, and the `DomainNav` entry. These cannot be split without a broken intermediate — `DomainNav[:books][:root_path]` needs the route, `layout_for(:books)` is asserted to name a template that exists, and without the `DomainNav` entry the dashboard renders in the *music* layout (the `FALLBACK_LAYOUT`).

**Files:**
- Create: `web-app/config/routes.rb` — new namespace inside the existing books `DomainConstraint` block (currently `config/routes.rb:273-275`)
- Create: `web-app/app/views/layouts/books/admin.html.erb`
- Create: `web-app/app/controllers/admin/books/base_controller.rb`
- Create: `web-app/app/controllers/admin/books/dashboard_controller.rb`
- Create: `web-app/app/views/admin/books/dashboard/index.html.erb`
- Modify: `web-app/app/lib/admin/domain_nav.rb` (`ICONS[:book]`, `CONFIGS[:books]`, nil-safe `categories_search_path`)
- Modify: `web-app/app/views/admin/shared/_sidebar.html.erb:21` (skip a domain section with no items)
- Test: `web-app/test/controllers/admin/books/dashboard_controller_test.rb`
- Test: `web-app/test/lib/admin/domain_nav_test.rb` (flip the three "books has no admin" assertions)

**Interfaces:**
- Consumes: `Admin::BaseController` (`layout :admin_layout` → `Admin::DomainNav.layout_for(current_domain)`; `#domain_root_path` already falls through to `books_root_path`); `Admin::DomainScopedAuth` (grants access on `current_user.can_access_domain?("books")`).
- Produces: route helper `admin_books_root_path` (`/admin` on the books host); `Admin::Books::BaseController` — the superclass every controller in increments 4–6 inherits; `Admin::DomainNav::CONFIGS[:books]` — later increments append to its `:items` array; `ICONS[:book]`.

- [ ] **Step 1: Write the failing dashboard controller test**

Create `web-app/test/controllers/admin/books/dashboard_controller_test.rb`. Mirrors `test/controllers/admin/games/dashboard_controller_test.rb`, plus the domain-role case (books is the first domain whose admin is built after `DomainScopedAuth` existed, so cover it here).

```ruby
require "test_helper"

module Admin
  module Books
    class DashboardControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:books]
      end

      test "should redirect to root for unauthenticated users" do
        get admin_books_root_path
        assert_redirected_to books_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_root_path
        assert_redirected_to books_root_path
      end

      test "should allow admin users to access dashboard" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_root_path
        assert_response :success
      end

      test "should allow editor users to access dashboard" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_books_root_path
        assert_response :success
      end

      test "should allow a books domain role to access dashboard" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_root_path
        assert_response :success
      end

      test "renders the books layout, not the music fallback" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_root_path

        assert_response :success
        assert_select "title", text: /The Greatest Books/
        assert_match %r{/assets/books-[^"]*\.css}, response.body
        assert_no_match %r{/assets/music-[^"]*\.css}, response.body
      end
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bin/rails test test/controllers/admin/books/dashboard_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'admin_books_root_path'` (the route does not exist yet).

- [ ] **Step 3: Add the books admin route namespace**

In `web-app/config/routes.rb`, replace the books constraint block (currently `config/routes.rb:273-275`):

```ruby
  constraints DomainConstraint.new(Rails.application.config.domains[:books]) do
    root to: "books/default#index", as: :books_root
  end
```

with:

```ruby
  constraints DomainConstraint.new(Rails.application.config.domains[:books]) do
    # Admin interface for books domain
    namespace :admin, module: "admin/books", as: "admin_books" do
      root to: "dashboard#index"
    end

    root to: "books/default#index", as: :books_root
  end
```

- [ ] **Step 4: Run the test to see the failure move**

Run: `bin/rails test test/controllers/admin/books/dashboard_controller_test.rb`
Expected: FAIL — `uninitialized constant Admin::Books` / `Admin::Books::DashboardController`. The route now resolves; the controller does not exist.

- [ ] **Step 5: Generate the dashboard controller**

Use the generator (project rule), skipping routes so it does not append a stray `get "admin/books/dashboard/index"` line, and skipping the helper:

```bash
bin/rails generate controller Admin::Books::Dashboard index --skip-routes --no-helper
```

This creates `app/controllers/admin/books/dashboard_controller.rb`, `app/views/admin/books/dashboard/index.html.erb`, and `test/controllers/admin/books/dashboard_controller_test.rb`. **The generator will overwrite the test you wrote in Step 1 — answer `n` if prompted to overwrite, or restore it with `git checkout test/controllers/admin/books/dashboard_controller_test.rb` afterwards.**

- [ ] **Step 6: Write the base controller**

Create `web-app/app/controllers/admin/books/base_controller.rb` by hand (an abstract superclass has nothing to generate and no test of its own — `Admin::Games::BaseController` and `Admin::Music::BaseController` are the same five lines).

Note there is deliberately **no** `layout` line: increment 1 made `Admin::BaseController` resolve the layout dynamically from the domain, and books is the first domain to rely on it rather than hardcode it.

```ruby
class Admin::Books::BaseController < Admin::BaseController
  include Admin::DomainScopedAuth
end
```

- [ ] **Step 7: Rewrite the generated dashboard controller**

Replace `web-app/app/controllers/admin/books/dashboard_controller.rb` with:

```ruby
class Admin::Books::DashboardController < Admin::Books::BaseController
  def index
    @book_count = ::Books::Book.count
    @author_count = ::Books::Author.count
    @edition_count = ::Books::Edition.count
    @series_count = ::Books::Series.count
    @category_count = ::Books::Category.count
    @list_count = ::Books::List.count
    @recent_books = ::Books::Book.order(created_at: :desc).limit(5)
  end
end
```

- [ ] **Step 8: Write the dashboard view**

Replace `web-app/app/views/admin/books/dashboard/index.html.erb` with the following. It carries **no quick links** — every books CRUD route arrives in increments 4–6, and a link to a route that does not exist raises at render time.

```erb
<% content_for :title, "Dashboard" %>

<div class="space-y-6">
  <div>
    <h1 class="text-4xl font-bold">Welcome to Books Admin</h1>
    <p class="text-lg text-base-content/70 mt-2">Manage books, authors, editions, and more</p>
  </div>

  <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
    <div class="stats shadow" data-testid="stat-card-books">
      <div class="stat">
        <div class="stat-title">Total Books</div>
        <div class="stat-value text-primary"><%= number_with_delimiter(@book_count) %></div>
      </div>
    </div>

    <div class="stats shadow" data-testid="stat-card-authors">
      <div class="stat">
        <div class="stat-title">Total Authors</div>
        <div class="stat-value text-secondary"><%= number_with_delimiter(@author_count) %></div>
      </div>
    </div>

    <div class="stats shadow" data-testid="stat-card-editions">
      <div class="stat">
        <div class="stat-title">Total Editions</div>
        <div class="stat-value text-accent"><%= number_with_delimiter(@edition_count) %></div>
      </div>
    </div>

    <div class="stats shadow" data-testid="stat-card-series">
      <div class="stat">
        <div class="stat-title">Total Series</div>
        <div class="stat-value text-info"><%= number_with_delimiter(@series_count) %></div>
      </div>
    </div>

    <div class="stats shadow" data-testid="stat-card-categories">
      <div class="stat">
        <div class="stat-title">Total Categories</div>
        <div class="stat-value text-warning"><%= number_with_delimiter(@category_count) %></div>
      </div>
    </div>

    <div class="stats shadow" data-testid="stat-card-lists">
      <div class="stat">
        <div class="stat-title">Total Lists</div>
        <div class="stat-value text-success"><%= number_with_delimiter(@list_count) %></div>
      </div>
    </div>
  </div>

  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">Recently Added Books</h2>
      <% if @recent_books.any? %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Title</th>
                <th>First Published</th>
                <th>Added</th>
              </tr>
            </thead>
            <tbody>
              <% @recent_books.each do |book| %>
                <tr>
                  <td><%= book.title %></td>
                  <td><%= book.first_published_year || "-" %></td>
                  <td class="text-sm text-base-content/70"><%= time_ago_in_words(book.created_at) %> ago</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-base-content/70">No books yet.</p>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 9: Write the books admin layout**

Create `web-app/app/views/layouts/books/admin.html.erb` — `app/views/layouts/games/admin.html.erb` with the books stylesheet, title and theme. The theme `cmyk` matches `layouts/books/application.html.erb`, and `books/application.css` declares `@plugin "daisyui" { themes: cmyk --default; }`, so the DaisyUI admin components (drawer, stats, table, card) build for books exactly as they do for games.

```erb
<!DOCTYPE html>
<html lang="en" data-theme="cmyk">
<head>
  <title><%= content_for?(:title) ? yield(:title) : "Admin" %> - The Greatest Books</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <%= csrf_meta_tags %>
  <%= csp_meta_tag %>

  <%= stylesheet_link_tag "books", "data-turbo-track": "reload" %>
  <%= javascript_include_tag "application", "data-turbo-track": "reload" %>

  <script>
    window.addEventListener('auth:signout', function() {
      window.location.href = '/';
    });
  </script>
</head>
<body class="bg-base-200" data-controller="authentication">
  <div class="drawer lg:drawer-open">
    <input id="admin-drawer" type="checkbox" class="drawer-toggle" />

    <!-- Main content -->
    <div class="drawer-content flex flex-col">
      <%= render "admin/shared/navbar" %>

      <div id="flash" class="mx-4 mt-4">
        <%= render "admin/shared/flash" if flash.any? %>
      </div>

      <main class="flex-1 p-6">
        <%= yield %>
      </main>
    </div>

    <!-- Sidebar -->
    <div class="drawer-side z-40">
      <label for="admin-drawer" aria-label="close sidebar" class="drawer-overlay"></label>
      <%= render "admin/shared/sidebar" %>
    </div>
  </div>
</body>
</html>
```

- [ ] **Step 10: Run the dashboard test — the layout assertion must still fail**

Run: `bin/rails test test/controllers/admin/books/dashboard_controller_test.rb`
Expected: the four access tests PASS; **`renders the books layout, not the music fallback` FAILS** — `Admin::DomainNav.layout_for(:books)` still returns the `music/admin` fallback, so the page ships the music CSS bundle. This is the red for the next step.

- [ ] **Step 11: Write the failing DomainNav test**

In `web-app/test/lib/admin/domain_nav_test.rb`, **replace** the three assertions that encode "books has no admin":

Replace the body of `test "layout_for falls back to music for domains with no admin layout"`:

```ruby
    test "layout_for falls back to music for domains with no admin layout" do
      assert_equal "music/admin", Admin::DomainNav.layout_for(:movies)
      assert_equal "music/admin", Admin::DomainNav.layout_for(nil)
    end
```

Add `:books` to the first test:

```ruby
    test "layout_for returns the domain admin layout" do
      assert_equal "music/admin", Admin::DomainNav.layout_for(:music)
      assert_equal "games/admin", Admin::DomainNav.layout_for(:games)
      assert_equal "books/admin", Admin::DomainNav.layout_for(:books)
    end
```

Replace `test "config_for returns nil for a domain with no admin"` with:

```ruby
    test "config_for returns nil for a domain with no admin" do
      assert_nil Admin::DomainNav.config_for(:movies)
    end

    test "config_for returns the books config with no nav items yet" do
      config = Admin::DomainNav.config_for(:books)

      assert_equal "The Greatest Books", config[:title]
      assert_equal "/admin", config[:root_path]
      assert_equal "Books", config[:section_label]
      assert config[:section_icon].present?
      assert_empty config[:items]
    end
```

Replace `test "every domain in CONFIGS has a categories_search_path"` with the invariant that actually protects `Admin::AddCategoryModalComponent#search_url` from falling back to the music path:

```ruby
    test "a domain whose nav links to Categories has a categories_search_path" do
      Admin::DomainNav::CONFIGS.each_key do |domain|
        config = Admin::DomainNav.config_for(domain)
        next unless config[:items].any? { |item| item[:label] == "Categories" }

        assert config[:categories_search_path].present?,
          "#{domain} links to Categories but is missing categories_search_path"
      end
    end
```

And widen the nav-item loop to every configured domain:

```ruby
    test "nav items all carry a label, path and icon" do
      Admin::DomainNav::CONFIGS.each_key do |domain|
        Admin::DomainNav.config_for(domain)[:items].each do |item|
          assert item[:label].present?, "#{domain} item missing label"
          assert item[:path].present?, "#{domain} item #{item[:label]} missing path"
          assert item[:icon].present?, "#{domain} item #{item[:label]} missing icon"
        end
      end
    end
```

- [ ] **Step 12: Run it to make sure it fails**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: FAIL — `layout_for(:books)` returns `"music/admin"`, and `config_for(:books)` returns `nil` (so `config[:title]` raises `NoMethodError` on nil).

- [ ] **Step 13: Register books in DomainNav**

In `web-app/app/lib/admin/domain_nav.rb`:

Add a `book` icon to `ICONS` (keep the hash's existing order — append after `series:`):

```ruby
      book: "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253",
```

Add the books config to `CONFIGS`, after the `games:` entry. `items` is empty on purpose — increments 4–6 append Books, Authors, Series, Categories, Lists and Rankings as each ships its routes. `categories_search_path` is nil until increment 6 builds the books categories admin.

```ruby
      books: {
        layout: "books/admin",
        title: "The Greatest Books",
        section_label: "Books",
        section_icon: ICONS[:book],
        logo: {type: :emoji, value: "📚"},
        root_path: -> { URL_HELPERS.admin_books_root_path },
        categories_search_path: nil,
        items: []
      }
```

Make `config_for` tolerate a nil `categories_search_path`:

```ruby
      def config_for(domain)
        config = CONFIGS[domain&.to_sym]
        return nil if config.nil?

        config.merge(
          root_path: config[:root_path].call,
          categories_search_path: config[:categories_search_path]&.call,
          items: config[:items].map do |item|
            item.merge(path: item[:path].call, icon: ICONS.fetch(item[:icon]))
          end
        )
      end
```

- [ ] **Step 14: Run both test files to verify they pass**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb test/controllers/admin/books/dashboard_controller_test.rb`
Expected: PASS (all tests, including `renders the books layout, not the music fallback` — the dashboard now ships `/assets/books-*.css`).

- [ ] **Step 15: Write the failing sidebar test**

The books nav has no items, so the sidebar would render an empty `<details>Books</details>`. Add this test to `web-app/test/controllers/admin/books/dashboard_controller_test.rb`:

```ruby
      test "renders books branding with no empty domain nav section" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_root_path

        assert_response :success
        assert_select "aside[data-testid=admin-sidebar]" do
          assert_select "h1", text: "The Greatest Books"
          assert_select "summary", text: /Books/, count: 0
          assert_select "a[href=?]", admin_penalties_path
          assert_select "a[href=?]", admin_users_path
        end
      end
```

- [ ] **Step 16: Run it to make sure it fails**

Run: `bin/rails test test/controllers/admin/books/dashboard_controller_test.rb -n /empty_domain_nav_section/`
Expected: FAIL on `assert_select "summary", text: /Books/, count: 0` — the sidebar currently renders the section header for any non-nil nav.

- [ ] **Step 17: Skip a domain section with no items**

In `web-app/app/views/admin/shared/_sidebar.html.erb:21`, change:

```erb
      <% if nav %>
```

to:

```erb
      <% if nav && nav[:items].any? %>
```

- [ ] **Step 18: Run the test to verify it passes**

Run: `bin/rails test test/controllers/admin/books/dashboard_controller_test.rb`
Expected: PASS (all seven tests).

- [ ] **Step 19: Run the full admin + registry suite for regressions**

Run: `bin/rails test test/controllers/admin test/lib/admin`
Expected: PASS, 0 failures, 0 errors. The music and games admin tests are the contract — **if one of them fails, stop and report it rather than editing the test.**

- [ ] **Step 20: Lint and commit**

```bash
bundle exec standardrb --fix
bundle exec standardrb
git add -A
git commit -m "Add the books admin shell: routes, layout, base controller and dashboard"
```

---

### Task 2: The seven books policies

Pundit is real here — `Admin::CategoriesBaseController:8`, `Admin::ListsBaseController:8` and the games controllers all call `authorize`. Increments 4–6 authorize against these policies, so they land now with the shell.

**Files:**
- Create: `web-app/app/policies/books/book_policy.rb`, `edition_policy.rb`, `author_policy.rb`, `series_policy.rb`, `category_policy.rb`, `list_policy.rb`, `ranking_configuration_policy.rb`
- Test: `web-app/test/policies/books/domain_policy_assertions.rb` (shared matrix, not a test case)
- Test: `web-app/test/policies/books/book_policy_test.rb`, `edition_policy_test.rb`, `author_policy_test.rb`, `series_policy_test.rb`, `category_policy_test.rb`, `list_policy_test.rb`, `ranking_configuration_policy_test.rb`

**Interfaces:**
- Consumes: `ApplicationPolicy` (`app/policies/application_policy.rb`) — `#domain` returns a string; `global_role?` (admin or editor) bypasses; otherwise `domain_role&.can_read?/can_write?/can_delete?/can_manage?`. `DomainRole` permission levels are `viewer(0), editor(1), moderator(2), admin(3)`; `can_write?` needs editor+, `can_delete?` needs moderator+, `can_manage?` needs admin.
- Produces: `Books::{Book,Edition,Author,Series,Category,List,RankingConfiguration}Policy`, each with a nested `Scope`. Increment 6's `Admin::Books::ListsController` must return `::Books::ListPolicy` from its `policy_class` hook.

**Fixtures (verified 2026-07-14 — use these exact keys):**

| Model | Fixture accessor |
|---|---|
| `Books::Book` | `books_books(:war_and_peace)` |
| `Books::Edition` | `books_editions(:wp_maude)` |
| `Books::Author` | `books_authors(:tolstoy)` |
| `Books::Series` | `books_series(:asoiaf)` |
| `Books::Category` | `categories(:books_fiction_genre)` (STI on `categories`) |
| `Books::List` | `lists(:basic_list)` (STI on `lists`) |
| `Books::RankingConfiguration` | `ranking_configurations(:books_global)` |

- [ ] **Step 1: Write the shared policy assertions**

Create `web-app/test/policies/books/domain_policy_assertions.rb`. This is a plain module, not a test case — Minitest will not pick it up as a test file, and each policy test requires it explicitly.

```ruby
module Books
  module DomainPolicyAssertions
    def assert_books_domain_policy(policy_class, record)
      assert policy_class.new(users(:admin_user), record).index?
      assert policy_class.new(users(:admin_user), record).show?
      assert policy_class.new(users(:admin_user), record).create?
      assert policy_class.new(users(:admin_user), record).update?
      assert policy_class.new(users(:admin_user), record).destroy?
      assert policy_class.new(users(:admin_user), record).manage?

      assert policy_class.new(users(:editor_user), record).show?
      assert policy_class.new(users(:editor_user), record).update?
      assert policy_class.new(users(:editor_user), record).destroy?
      refute policy_class.new(users(:editor_user), record).manage?

      refute policy_class.new(nil, record).show?
      refute policy_class.new(users(:regular_user), record).show?
      refute policy_class.new(books_user(:viewer), record).manage?

      assert policy_class.new(books_user(:viewer), record).show?
      refute policy_class.new(books_user(:viewer), record).update?
      refute policy_class.new(books_user(:viewer), record).destroy?

      assert policy_class.new(books_user(:editor), record).update?
      refute policy_class.new(books_user(:editor), record).destroy?

      assert policy_class.new(books_user(:moderator), record).destroy?
      refute policy_class.new(books_user(:moderator), record).manage?

      assert policy_class.new(books_user(:admin), record).manage?
    end

    def assert_books_scope(policy_class, model)
      assert_equal model.count, policy_class::Scope.new(users(:admin_user), model).resolve.count
      assert_equal model.count, policy_class::Scope.new(books_user(:viewer), model).resolve.count
      assert_empty policy_class::Scope.new(users(:regular_user), model).resolve
      assert_empty policy_class::Scope.new(nil, model).resolve
    end

    def books_user(permission_level)
      @books_users ||= {}
      @books_users[permission_level] ||= begin
        user = User.create!(
          email: "books-#{permission_level}@example.com",
          name: "Books #{permission_level}",
          role: :user
        )
        user.domain_roles.create!(domain: :books, permission_level: permission_level)
        user
      end
    end

    def music_user
      @music_user ||= users(:contractor_user)
    end
  end
end
```

- [ ] **Step 2: Write the failing book policy test**

Create `web-app/test/policies/books/book_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class BookPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @book = books_books(:war_and_peace)
    end

    test "domain is books" do
      assert_equal "books", ::Books::BookPolicy.new(users(:admin_user), @book).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::BookPolicy, @book)
    end

    test "a music-only user has no access" do
      refute ::Books::BookPolicy.new(music_user, @book).show?
      refute ::Books::BookPolicy.new(music_user, @book).update?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::BookPolicy, ::Books::Book)
    end
  end
end
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `bin/rails test test/policies/books/book_policy_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::BookPolicy`.

- [ ] **Step 4: Write the book policy**

Create `web-app/app/policies/books/book_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class BookPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/policies/books/book_policy_test.rb`
Expected: PASS.

- [ ] **Step 6: Write the five remaining standard policies**

Create each of these — identical to `book_policy.rb` but for its own class:

`web-app/app/policies/books/edition_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class EditionPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

`web-app/app/policies/books/author_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class AuthorPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

`web-app/app/policies/books/series_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class SeriesPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

`web-app/app/policies/books/category_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class CategoryPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

`web-app/app/policies/books/list_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class ListPolicy < ApplicationPolicy
    def domain
      "books"
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

- [ ] **Step 7: Write their tests**

One test file per policy. Note `Books::Category` and `Books::List` are STI on the shared `categories` / `lists` tables, so their fixture accessors are `categories(...)` / `lists(...)`, not `books_categories(...)`.

`web-app/test/policies/books/edition_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class EditionPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @edition = books_editions(:wp_maude)
    end

    test "domain is books" do
      assert_equal "books", ::Books::EditionPolicy.new(users(:admin_user), @edition).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::EditionPolicy, @edition)
    end

    test "a music-only user has no access" do
      refute ::Books::EditionPolicy.new(music_user, @edition).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::EditionPolicy, ::Books::Edition)
    end
  end
end
```

`web-app/test/policies/books/author_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class AuthorPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @author = books_authors(:tolstoy)
    end

    test "domain is books" do
      assert_equal "books", ::Books::AuthorPolicy.new(users(:admin_user), @author).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::AuthorPolicy, @author)
    end

    test "a music-only user has no access" do
      refute ::Books::AuthorPolicy.new(music_user, @author).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::AuthorPolicy, ::Books::Author)
    end
  end
end
```

`web-app/test/policies/books/series_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class SeriesPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @series = books_series(:asoiaf)
    end

    test "domain is books" do
      assert_equal "books", ::Books::SeriesPolicy.new(users(:admin_user), @series).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::SeriesPolicy, @series)
    end

    test "a music-only user has no access" do
      refute ::Books::SeriesPolicy.new(music_user, @series).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::SeriesPolicy, ::Books::Series)
    end
  end
end
```

`web-app/test/policies/books/category_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class CategoryPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @category = categories(:books_fiction_genre)
    end

    test "domain is books" do
      assert_equal "books", ::Books::CategoryPolicy.new(users(:admin_user), @category).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::CategoryPolicy, @category)
    end

    test "a music-only user has no access" do
      refute ::Books::CategoryPolicy.new(music_user, @category).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::CategoryPolicy, ::Books::Category)
    end
  end
end
```

`web-app/test/policies/books/list_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class ListPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @list = lists(:basic_list)
    end

    test "the fixture is a books list" do
      assert_instance_of ::Books::List, @list
    end

    test "domain is books" do
      assert_equal "books", ::Books::ListPolicy.new(users(:admin_user), @list).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::ListPolicy, @list)
    end

    test "a music-only user has no access" do
      refute ::Books::ListPolicy.new(music_user, @list).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::ListPolicy, ::Books::List)
    end
  end
end
```

- [ ] **Step 8: Run the six policy tests**

Run: `bin/rails test test/policies/books/`
Expected: PASS.

- [ ] **Step 9: Write the failing ranking configuration policy test**

Ranking configurations are system-level: create/update/destroy require **manage** (global admin or books domain admin — a *global editor* is denied), while execute/index actions are open to writers. This mirrors `app/policies/games/ranking_configuration_policy.rb`.

Create `web-app/test/policies/books/ranking_configuration_policy_test.rb`:

```ruby
require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class RankingConfigurationPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @rc = ranking_configurations(:books_global)
    end

    test "domain is books" do
      assert_equal "books", ::Books::RankingConfigurationPolicy.new(users(:admin_user), @rc).domain
    end

    test "reading is open to global roles and any books domain role" do
      assert ::Books::RankingConfigurationPolicy.new(users(:admin_user), @rc).index?
      assert ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).show?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:viewer), @rc).show?
      refute ::Books::RankingConfigurationPolicy.new(users(:regular_user), @rc).show?
    end

    test "writing requires manage, so a global editor is denied" do
      refute ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).create?
      refute ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).update?
      refute ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).destroy?

      refute ::Books::RankingConfigurationPolicy.new(books_user(:moderator), @rc).update?

      assert ::Books::RankingConfigurationPolicy.new(users(:admin_user), @rc).update?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:admin), @rc).update?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:admin), @rc).destroy?
    end

    test "execute and index actions are open to writers" do
      assert ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).execute_action?
      assert ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).index_action?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:editor), @rc).execute_action?
      refute ::Books::RankingConfigurationPolicy.new(books_user(:viewer), @rc).execute_action?
      refute ::Books::RankingConfigurationPolicy.new(music_user, @rc).execute_action?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::RankingConfigurationPolicy, ::Books::RankingConfiguration)
    end
  end
end
```

- [ ] **Step 10: Run it to make sure it fails**

Run: `bin/rails test test/policies/books/ranking_configuration_policy_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::RankingConfigurationPolicy`.

- [ ] **Step 11: Write the ranking configuration policy**

Create `web-app/app/policies/books/ranking_configuration_policy.rb`:

```ruby
# frozen_string_literal: true

module Books
  class RankingConfigurationPolicy < ApplicationPolicy
    def domain
      "books"
    end

    def create?
      manage?
    end

    def new?
      create?
    end

    def update?
      manage?
    end

    def edit?
      update?
    end

    def destroy?
      manage?
    end

    def execute_action?
      global_admin? || global_editor? || domain_role&.can_write?
    end

    def index_action?
      global_admin? || global_editor? || domain_role&.can_write?
    end

    class Scope < ApplicationPolicy::Scope
      def domain
        "books"
      end
    end
  end
end
```

- [ ] **Step 12: Run the whole policy suite to verify it passes**

Run: `bin/rails test test/policies/`
Expected: PASS, 0 failures.

- [ ] **Step 13: Lint and commit**

```bash
bundle exec standardrb --fix
bundle exec standardrb
git add -A
git commit -m "Add the seven books admin policies"
```

---

### Task 3: Domain isolation coverage for books

Two things need proving: a books-domain user reaches the books admin and nothing else, and the global admin controllers (penalties, users) now render in the *books* layout on the books host — the last domain to inherit increment 1's `layout "music/admin"` fix.

**Files:**
- Modify: `web-app/test/controllers/admin/domain_isolation_test.rb`
- Modify: `web-app/test/controllers/admin/penalties_controller_test.rb:276-289`

**Interfaces:**
- Consumes: `admin_books_root_path` and `Admin::DomainNav::CONFIGS[:books]` (Task 1).

- [ ] **Step 1: Write the failing isolation tests**

Append to `web-app/test/controllers/admin/domain_isolation_test.rb`, before the final `end`:

```ruby
  test "a books-domain user reaches books admin but not music admin" do
    books_user = users(:regular_user)
    books_user.domain_roles.create!(domain: :books, permission_level: :editor)

    host! Rails.application.config.domains[:books]
    sign_in_as(books_user, stub_auth: true)
    get admin_books_root_path
    assert_response :success

    host! Rails.application.config.domains[:music]
    sign_in_as(books_user, stub_auth: true)
    get admin_albums_path
    assert_redirected_to music_root_path
  end

  test "a music-domain user cannot reach books admin" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@contractor, stub_auth: true)
    get admin_books_root_path
    assert_redirected_to books_root_path
  end

  test "a books-domain user cannot access the global penalties controller" do
    books_user = users(:regular_user)
    books_user.domain_roles.create!(domain: :books, permission_level: :editor)

    host! Rails.application.config.domains[:books]
    sign_in_as(books_user, stub_auth: true)
    get admin_penalties_path
    assert_redirected_to books_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end
```

- [ ] **Step 2: Run them and confirm they pass**

Run: `bin/rails test test/controllers/admin/domain_isolation_test.rb`
Expected: PASS. These assert behavior that Task 1 already delivered (`DomainScopedAuth` + the books route + `domain_root_path`'s books fallthrough); they are the regression net, so a failure here means Task 1 is wrong — **stop and report** rather than adjusting the test.

- [ ] **Step 3: Write the failing books-layout test for the global controllers**

In `web-app/test/controllers/admin/penalties_controller_test.rb`, replace `test "renders the sidebar with no domain nav section when browsing from the books host"` (currently at lines 276-289) with:

```ruby
  test "renders the books layout with no domain nav section when browsing from the books host" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@admin, stub_auth: true)

    get admin_penalties_path

    assert_response :success
    assert_select "title", text: /The Greatest Books/
    assert_match %r{/assets/books-[^"]*\.css}, response.body
    assert_no_match %r{/assets/music-[^"]*\.css}, response.body
    assert_select "aside[data-testid=admin-sidebar]" do
      assert_select "a[href=?]", admin_penalties_path
      assert_select "a[href=?]", admin_users_path
      assert_select "a[href=?]", admin_artists_path, count: 0
      assert_select "a[href=?]", admin_games_games_path, count: 0
    end
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/controllers/admin/penalties_controller_test.rb`
Expected: PASS. (Before Task 1 this page fell back to the music layout on the books host; the books CSS assertion is what proves the fallback is gone.)

- [ ] **Step 5: Run the full suite**

Run: `bin/rails test`
Expected: PASS — 0 failures, 0 errors. Compare the test count against the last known-good run (4,576 tests as of increment 2) and report the new total.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix
bundle exec standardrb
git add -A
git commit -m "Cover books domain isolation and the books admin layout"
```

---

### Task 4: Playwright smoke spec for the books admin

The books Playwright project exists (`e2e/playwright.config.ts:44-51`) but is unauthenticated — it only runs the public `homepage.spec.ts`. The admin needs a signed-in project, and browser sessions are host-scoped, so books needs its own auth setup exactly as games has one.

**Files:**
- Create: `web-app/e2e/auth/books-auth.setup.ts`
- Create: `web-app/e2e/tests/books/admin/dashboard.spec.ts`
- Modify: `web-app/e2e/playwright.config.ts`

**Interfaces:**
- Consumes: `PLAYWRIGHT_ADMIN_EMAIL` / `PLAYWRIGHT_ADMIN_PASSWORD` from `e2e/.env`; the books admin dashboard's `data-testid` stat cards from Task 1.
- Produces: the `books-admin` Playwright project — increment 7's specs go under `e2e/tests/books/admin/` and inherit its auth.

**Prerequisites:** a dev server is running (`bin/dev`), `e2e/.env` exists, and the Playwright account is a global admin (`bin/rails e2e:admin` — it sets `role: :admin`, which bypasses domain checks). If the books admin specs all time out on the public books homepage, the e2e user lost its role in a dev-DB reseed; re-run `bin/rails e2e:admin`.

- [ ] **Step 1: Write the books auth setup**

Create `web-app/e2e/auth/books-auth.setup.ts` — `games-auth.setup.ts` with the books host and its own storage-state file:

```ts
import { test as setup, expect } from '@playwright/test';
import path from 'path';

const authFile = path.join(__dirname, '..', '.auth', 'books-user.json');

setup.use({ baseURL: 'https://dev-new.thegreatestbooks.org' });

setup('authenticate as admin on books domain', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('button', { name: 'Login' }).click();

  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_ADMIN_EMAIL!);
  await modal.getByRole('button', { name: 'Continue' }).click();

  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(process.env.PLAYWRIGHT_ADMIN_PASSWORD!);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(3000);

  await page.context().storageState({ path: authFile });
});
```

- [ ] **Step 2: Register the books-admin project**

In `web-app/e2e/playwright.config.ts`:

Add the auth file constant next to the existing two (after `const gamesAuthFile = ...`):

```ts
const booksAuthFile = path.join(__dirname, '.auth', 'books-user.json');
```

Add a setup project after `games-setup`:

```ts
    { name: 'books-setup', testDir: './auth', testMatch: 'books-auth.setup.ts' },
```

Then replace the existing `books` project with these two. The public project's `testMatch` gains a negative lookahead so the admin specs run **only** under the authenticated project — without it, every admin spec would also run unauthenticated and fail.

```ts
    {
      name: 'books',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev-new.thegreatestbooks.org',
      },
      testMatch: /books\/(?!admin\/).*/,
    },
    {
      name: 'books-admin',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev-new.thegreatestbooks.org',
        storageState: booksAuthFile,
      },
      testMatch: /books\/admin\/.*/,
      dependencies: ['books-setup'],
    },
```

- [ ] **Step 3: Write the dashboard spec**

Create `web-app/e2e/tests/books/admin/dashboard.spec.ts`. Assert the page is the *books* admin (branding + stats), that the sidebar carries the global links, and that it does **not** carry music/games links — the wrong-domain leak this shell exists to avoid.

```ts
import { test, expect } from '@playwright/test';

test.describe('books admin dashboard', () => {
  test('loads with books branding and entity counts', async ({ page }) => {
    await page.goto('/admin');

    await expect(page).toHaveTitle(/The Greatest Books/);
    await expect(page.getByRole('heading', { name: 'Welcome to Books Admin' })).toBeVisible();

    await expect(page.getByTestId('stat-card-books')).toBeVisible();
    await expect(page.getByTestId('stat-card-authors')).toBeVisible();
    await expect(page.getByTestId('stat-card-editions')).toBeVisible();
    await expect(page.getByTestId('stat-card-series')).toBeVisible();
    await expect(page.getByTestId('stat-card-categories')).toBeVisible();
    await expect(page.getByTestId('stat-card-lists')).toBeVisible();
  });

  test('sidebar shows books branding and the global section only', async ({ page }) => {
    await page.goto('/admin');

    const sidebar = page.getByTestId('admin-sidebar');
    await expect(sidebar).toBeVisible();
    await expect(sidebar.getByRole('heading', { name: 'The Greatest Books' })).toBeVisible();

    await expect(sidebar.getByRole('link', { name: 'Penalties' })).toBeVisible();
    await expect(sidebar.getByRole('link', { name: 'Users' })).toBeVisible();

    await expect(sidebar.getByRole('link', { name: 'Albums' })).toHaveCount(0);
    await expect(sidebar.getByRole('link', { name: 'Games' })).toHaveCount(0);
  });
});
```

- [ ] **Step 4: Run the books e2e project**

Run: `yarn test:e2e --project=books-admin`
Expected: 2 passed. If the run lands on the public books homepage instead of the admin, the Playwright account is not an admin — run `bin/rails e2e:admin` and retry.

- [ ] **Step 5: Run the whole e2e suite for regressions**

Run: `yarn test:e2e`
Expected: all specs pass (158/158 as of increment 2, plus the 2 new ones). The `books` public project must still pick up `homepage.spec.ts` — confirm it appears in the run and did not get excluded by the new `testMatch` lookahead.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add a Playwright smoke spec for the books admin dashboard"
```

---

## Verification

Before declaring the increment done, run and paste the output of each:

```bash
bin/rails test                # expect 0 failures, 0 errors
bin/rails test:system         # expect 0 failures
bundle exec standardrb        # expect no offenses
yarn test:e2e                 # expect all passing
```

Then update `.superpowers/sdd/progress.md` with the increment-3 ledger and surface to the owner:
- the four deviations above (empty books nav section, no `DomainRouting` books entries yet, `categories_search_path` now optional, E2E pulled forward),
- the new test count vs. the 4,576 baseline.

---

### Task 1b: Collapse the three admin layouts into one config-driven template

**Inserted after Task 1 by owner decision (2026-07-14).** The task reviewer flagged `layouts/books/admin.html.erb` as the third verbatim copy of the admin layout, and increment 1's `Admin::DomainNav` registry was built so a domain is a config entry, not a new layout file. Owner chose to pay the duplication down now rather than defer.

Full brief (authored directly, not extracted from a numbered section): `.superpowers/sdd/inc3-task-1b-brief.md`.

**Summary:** replace `layouts/{music,games,books}/admin.html.erb` with a single `layouts/admin.html.erb` driven by a new `Admin::DomainNav.chrome_for(current_domain)` → `{theme:, stylesheet:, title:, favicon_dir:}`. `Admin::BaseController` gains `layout "admin"` (replacing `layout :admin_layout` + the `admin_layout` method and `DomainNav.layout_for`/`FALLBACK_LAYOUT`). Remove the 8 redundant `layout "music/admin"`/`layout "games/admin"` overrides in the music/games base + shared-subclass controllers. **Not the simple 3-token swap the design doc implied:** only the music layout carries a favicon block (games/books have none), so `favicon_dir` (music → `"music/favicon"`, else nil) preserves it; and 8 hardcoded overrides break when the templates are deleted. Behavior-neutral: existing penalties/dashboard CSS+title assertions are the contract; add favicon regression pins.
