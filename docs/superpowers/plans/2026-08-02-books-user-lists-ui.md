# Books User Lists UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing `Books::UserList` data (282,922 lists, 3,096,597 items) into the UI at parity with music and games, then add public viewing of shared lists.

**Architecture:** The user-lists feature is already domain-generic — `UserList::DOMAIN_SUBCLASSES` is the single source of truth that `MyListsController`, `UserListStateController`, and `UserListsController` all derive from. Books was deliberately excluded. Increment 1 adds books to that mapping and fills the eight gaps that made the exclusion necessary. Increment 2 makes `MyListsController#show` viewer-aware so public lists resolve for non-owners.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, Stimulus, Tailwind CSS 4 + DaisyUI 5, Pagy 43, OpenSearch, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-02-books-user-lists-ui-design.md`

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at the **project root** `docs/`, not `web-app/docs/`.
- Lint with `bundle exec standardrb` (NOT `bin/rubocop`). Never run brakeman.
- **Never run a destructive DB command against development.** Never call `ActiveRecord::FixtureSet.create_fixtures` — it TRUNCATES. To inspect a fixture, read the YAML.
- **Never create `test/fixtures/books/user_lists.yml`.** An STI-subclass fixture file for `user_lists` kills the entire suite. Books rows go in the existing `test/fixtures/user_lists.yml` with `type: Books::UserList`.
- Namespace all media code (`Books::`); shared models (`User`, `UserList`, `List`) stay global. Tests mirror the namespace.
- Rails 8 enum syntax: `enum :status, {active: 0}`.
- **No code comments unless the plan shows one.** Where this plan includes a comment in a code block, write it verbatim — each one records a non-obvious constraint.
- Controller tests assert behavior (status codes, params, absence of errors) — never HTML/CSS/copy that a designer could change freely.
- Movies is out of scope project-wide. Do not add, fix, or mention movies behavior beyond what already exists.
- Commit after every task. Do not push or open a PR without asking.

---

# Increment 1 — Books My Lists

### Task 1: Wire books into the domain and default-list constants

**Files:**
- Modify: `app/models/user_list.rb:28-45`
- Test: `test/models/user_list_test.rb:94-101`, `test/models/user_test.rb:167-170,196-198`, `test/models/books/user_list_test.rb:84-87`

**Interfaces:**
- Consumes: nothing.
- Produces: `UserList.subclasses_for(:books) # => [Books::UserList]`; `UserList::DEFAULT_SUBCLASSES` includes `"Books::UserList"`; `UserList.default_subclasses.size == 5`. Every later task depends on this.

- [ ] **Step 1: Update the three existing tests that assert the old counts**

In `test/models/user_list_test.rb`, replace the `default_subclasses` test:

```ruby
  test "default_subclasses returns 5 subclasses" do
    assert_equal 5, UserList.default_subclasses.size
    assert_includes UserList.default_subclasses, Music::Albums::UserList
    assert_includes UserList.default_subclasses, Music::Songs::UserList
    assert_includes UserList.default_subclasses, Games::UserList
    assert_includes UserList.default_subclasses, Movies::UserList
    assert_includes UserList.default_subclasses, Books::UserList
  end

  test "subclasses_for resolves the books domain" do
    assert_equal [Books::UserList], UserList.subclasses_for(:books)
  end
```

In `test/models/user_test.rb`, replace the two count assertions:

```ruby
  test "creates 16 default user lists on create" do
    user = User.create!(email: "defaults@example.com", display_name: "Defaults")
    assert_equal 16, user.user_lists.count
  end
```

```ruby
  test "destroying user destroys user_lists" do
    user = User.create!(email: "bye@example.com", display_name: "Bye")
    assert_difference "UserList.count", -16 do
      user.destroy
    end
  end
```

Still in `test/models/user_test.rb`, add a books line to the per-subclass count test (leave the existing four lines untouched):

```ruby
    assert_equal 4, user.user_lists.where(type: "Books::UserList").count
```

In `test/models/books/user_list_test.rb`, replace the exclusion test:

```ruby
    test "is registered in DEFAULT_SUBCLASSES and DOMAIN_SUBCLASSES" do
      assert_includes UserList::DEFAULT_SUBCLASSES, "Books::UserList"
      assert_equal [Books::UserList], UserList.subclasses_for(:books)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/models/user_list_test.rb test/models/user_test.rb test/models/books/user_list_test.rb
```

Expected: FAIL — `default_subclasses` returns 4, `subclasses_for(:books)` returns `[]`, user gets 12 lists.

- [ ] **Step 3: Add books to both constants**

In `app/models/user_list.rb`, replace lines 28-45 (the two constant declarations and the comment above `DOMAIN_SUBCLASSES`) with:

```ruby
  DEFAULT_SUBCLASSES = %w[
    Music::Albums::UserList
    Music::Songs::UserList
    Games::UserList
    Movies::UserList
    Books::UserList
  ].freeze

  # Maps a request domain to the UserList STI subclasses that live on it. Music
  # has two listables (albums + songs); the rest have one each. Shared by
  # MyListsController, UserListStateController, and UserListsController so the
  # domain→subclass mapping can never drift between them.
  DOMAIN_SUBCLASSES = {
    "music" => %w[Music::Albums::UserList Music::Songs::UserList],
    "games" => %w[Games::UserList],
    "movies" => %w[Movies::UserList],
    "books" => %w[Books::UserList]
  }.freeze
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/models/user_list_test.rb test/models/user_test.rb test/models/books/user_list_test.rb
```

Expected: PASS.

- [ ] **Step 5: Cover the knock-on effect on the create endpoint**

`UserListsController::ALLOWED_TYPES` is derived from `DOMAIN_SUBCLASSES.values.flatten`, so books lists became creatable through `POST /user_lists` as a side effect of Step 3. Append to `test/controllers/user_lists_controller_test.rb`:

```ruby
  test "creates a custom books list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    post user_lists_path,
      params: {user_list: {type: "Books::UserList", name: "Summer Reading"}},
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Books::UserList", body.dig("user_list", "type")
    assert_equal "custom", body.dig("user_list", "list_type")
  end
```

Check the existing tests in that file for the `@user` / `host!` setup shape and match it.

- [ ] **Step 6: Run the full suite to find collateral damage**

```bash
bin/rails test
```

Expected: PASS. `test/controllers/my_lists_controller_test.rb` has a test named "unknown host falls back to the music layout (books has no layout yet)" — it still passes (it uses `unknown.example.com`, not the books host). Leave it; Task 4 renames it.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add app/models/user_list.rb test/
git commit -m "Register Books::UserList in the domain and default-list constants"
```

---

### Task 2: Lazy default-list bootstrap

**Files:**
- Create: `app/lib/services/user_lists/ensure_defaults.rb`
- Create: `test/lib/services/user_lists/ensure_defaults_test.rb`
- Modify: `app/controllers/my_lists_controller.rb:20-24` (the `index` action)
- Modify: `app/controllers/user_list_state_controller.rb:16` (the `lists` assignment in `show`)

**Interfaces:**
- Consumes: `UserList.subclasses_for(domain)` (Task 1).
- Produces: `Services::UserLists::EnsureDefaults.call(user:, domain:, existing:) # => Array<UserList>`. Returns the `existing` array untouched when nothing is missing.

**Why:** `User#create_default_user_lists` is an `after_create` callback, so Task 1 only affects *new* signups. Existing music/games users would see an empty books dashboard with no way to get defaults (UI list creation only produces `custom` lists). This also repairs the ~145 legacy books users the migration deliberately left short.

- [ ] **Step 0: Vendor the `book-open` icon (hard prerequisite)**

The moment this task creates a books `reading` list, `UserLists::Dashboard::ListCardComponent` renders it and calls `helpers.icon("book-open", library: "lucide")`. That icon is not vendored, so the books dashboard raises. `ApplicationController#detect_current_domain` returns `:books` for **unrecognized** hosts, so this breaks the pre-existing "unknown host" controller test too — not only books-host requests. The icon must land in this task, before the service is wired up. (Task 3 lists these same three edits and will find them already done.)

1. Download the single `book-open` SVG from <https://lucide.dev/icons/book-open> and save it as `app/assets/svg/icons/lucide/outline/book-open.svg`. Match a sibling's shape exactly — compare against `app/assets/svg/icons/lucide/outline/bookmark.svg`. Do **not** run `bin/rails generate rails_icons:sync`; the curation policy in `app/assets/svg/icons/README.md` forbids syncing the full ~1,700-icon library.

2. Add it to the client-side template in `app/views/shared/_user_list_icon_template.html.erb` (the modal clones icons from here by `data-icon` name):

```erb
  <% %w[heart headphones bookmark check trophy gamepad-2 eye plus book-open].each do |name| %>
```

3. Add this row to the table in `app/assets/svg/icons/README.md`, immediately after the `bookmark` row:

```markdown
| `book-open` | `Books::UserList.list_type_icons[:reading]` |
```

4. Verify it resolves:

```bash
bin/rails runner 'puts ApplicationController.helpers.icon("book-open", library: "lucide", class: "size-4")'
```

Expected: an `<svg>` string. An exception means the file is in the wrong directory or malformed.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/user_lists/ensure_defaults_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "active_record/testing/query_assertions"

module Services
  module UserLists
    class EnsureDefaultsTest < ActiveSupport::TestCase
      include ActiveRecord::Assertions::QueryAssertions

      # admin_user owns exactly one fixture list (a games favorites) and no books
      # lists, so it starts from a clean slate for this domain. Do NOT switch to
      # regular_user — Task 4 gives it books fixtures, which would break the
      # "creates every missing default" assertion below.
      setup do
        @user = users(:admin_user)
        assert_equal [], @user.user_lists.where(type: "Books::UserList").to_a
      end

      def books_lists
        @user.user_lists.where(type: "Books::UserList").to_a
      end

      test "creates every missing default for the domain" do
        assert_equal [], books_lists

        result = EnsureDefaults.call(user: @user, domain: :books, existing: [])

        assert_equal 4, result.size
        assert_equal %w[favorites read reading want_to_read].sort,
          result.map(&:list_type).sort
        assert result.all? { |list| list.is_a?(::Books::UserList) }
      end

      test "uses the subclass's default names" do
        EnsureDefaults.call(user: @user, domain: :books, existing: [])
        list = @user.user_lists.find_by(type: "Books::UserList", list_type: :favorites)
        assert_equal "My Favorite Books", list.name
      end

      test "is idempotent and writes nothing on a second call" do
        EnsureDefaults.call(user: @user, domain: :books, existing: [])
        existing = books_lists

        assert_no_difference "UserList.count" do
          result = EnsureDefaults.call(user: @user, domain: :books, existing: existing)
          assert_equal existing.map(&:id).sort, result.map(&:id).sort
        end
      end

      test "issues zero queries when the set is already complete" do
        EnsureDefaults.call(user: @user, domain: :books, existing: [])
        existing = books_lists

        assert_queries_count(0) do
          EnsureDefaults.call(user: @user, domain: :books, existing: existing)
        end
      end

      test "fills only the gap when some defaults already exist" do
        ::Books::UserList.create!(user: @user, list_type: :favorites, name: "My Favorite Books")

        result = EnsureDefaults.call(user: @user, domain: :books, existing: books_lists)

        assert_equal 4, result.size
        assert_equal 4, books_lists.size
      end

      test "touches only the requested domain" do
        before = @user.user_lists.where.not(type: "Books::UserList").count

        EnsureDefaults.call(user: @user, domain: :books, existing: [])

        assert_equal before, @user.user_lists.where.not(type: "Books::UserList").count
      end

      test "returns the existing set for a domain with no subclasses" do
        existing = []
        assert_equal existing, EnsureDefaults.call(user: @user, domain: :nope, existing: existing)
      end

      test "survives losing the create race to a concurrent request" do
        winner = ::Books::UserList.create!(user: @user, list_type: :favorites, name: "My Favorite Books")
        # Simulate the other request having committed between our diff and our write:
        # find_or_create_by! trips one_default_per_type_per_user and raises.
        ::Books::UserList.stubs(:find_or_create_by!)
          .raises(ActiveRecord::RecordInvalid.new(::Books::UserList.new))

        result = nil
        assert_nothing_raised do
          result = EnsureDefaults.call(user: @user, domain: :books, existing: [])
        end

        # The three it could not create are dropped; the one that already exists is re-read.
        assert_equal [winner.id], result.map(&:id)
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/lib/services/user_lists/ensure_defaults_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Services::UserLists`.

- [ ] **Step 3: Write the service**

Create `app/lib/services/user_lists/ensure_defaults.rb`:

```ruby
# frozen_string_literal: true

module Services
  module UserLists
    # Idempotently creates any of a domain's default UserLists that a user is
    # missing, and returns the merged set.
    #
    # User#create_default_user_lists only fires on signup, so users created
    # before a subclass joined DEFAULT_SUBCLASSES have none of its lists. The
    # legacy books import also left ~145 users short of a default on purpose.
    #
    # Callers pass the lists they already loaded, so the common case (nothing
    # missing) costs zero extra queries and zero writes. That matters: one
    # caller runs on every signed-in page view.
    class EnsureDefaults
      def self.call(user:, domain:, existing:)
        new(user: user, domain: domain, existing: existing).call
      end

      def initialize(user:, domain:, existing:)
        @user = user
        @domain = domain
        @existing = existing
      end

      def call
        missing = missing_pairs
        return @existing if missing.empty?

        @existing + missing.filter_map { |klass, list_type| create(klass, list_type) }
      end

      private

      def missing_pairs
        present = @existing.map { |list| [list.class.name, list.list_type.to_s] }
        ::UserList.subclasses_for(@domain).flat_map do |klass|
          klass.default_list_types.filter_map do |list_type|
            [klass, list_type] unless present.include?([klass.name, list_type.to_s])
          end
        end
      end

      # one_default_per_type_per_user is a model-level validation with no backing
      # DB index, so two concurrent requests can both pass it. Lose the race
      # quietly and re-read rather than 500ing the page.
      def create(klass, list_type)
        klass.find_or_create_by!(user: @user, list_type: list_type) do |list|
          list.name = klass.default_list_name_for(list_type)
        end
      rescue ActiveRecord::RecordInvalid
        klass.find_by(user: @user, list_type: list_type)
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rails test test/lib/services/user_lists/ensure_defaults_test.rb
```

Expected: PASS.

- [ ] **Step 5: Wire it into `MyListsController#index`**

In `app/controllers/my_lists_controller.rb`, replace the first two lines of `index`:

```ruby
    types = UserList.subclasses_for(Current.domain).map(&:name)
    lists = current_user.user_lists.where(type: types).to_a
```

with:

```ruby
    types = UserList.subclasses_for(Current.domain).map(&:name)
    lists = Services::UserLists::EnsureDefaults.call(
      user: current_user,
      domain: Current.domain,
      existing: current_user.user_lists.where(type: types).to_a
    )
```

- [ ] **Step 6: Wire it into `UserListStateController#show`**

In `app/controllers/user_list_state_controller.rb`, replace:

```ruby
    lists = current_user.user_lists.where(type: subclass_names).order(:id).to_a
```

with:

```ruby
    lists = Services::UserLists::EnsureDefaults.call(
      user: current_user,
      domain: domain,
      existing: current_user.user_lists.where(type: subclass_names).order(:id).to_a
    ).sort_by(&:id)
```

- [ ] **Step 7: Add controller coverage for the backfill**

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  test "dashboard backfills missing default lists for the current domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    assert_difference -> { @user.user_lists.where(type: "Books::UserList").count }, 4 do
      get my_lists_path
    end
    assert_response :success
  end
```

Append to `test/controllers/user_list_state_controller_test.rb`:

```ruby
  test "state endpoint backfills missing default lists for the current domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    assert_difference -> { @user.user_lists.where(type: "Books::UserList").count }, 4 do
      get user_list_state_path, as: :json
    end

    body = JSON.parse(response.body)
    assert_equal "books", body["domain"]
    assert_equal ["Books::UserList"], body["lists"].map { |l| l["type"] }.uniq
  end
```

- [ ] **Step 8: Run the affected tests**

```bash
bin/rails test test/lib/services/user_lists/ensure_defaults_test.rb test/controllers/my_lists_controller_test.rb test/controllers/user_list_state_controller_test.rb
```

Expected: PASS. The books dashboard test renders through `resolve_layout`'s `else` branch (music layout) until Task 4 — that is fine, it asserts status only.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb
git add app/lib/services/user_lists/ app/controllers/my_lists_controller.rb app/controllers/user_list_state_controller.rb test/
git commit -m "Backfill missing default user lists on first visit to a domain"
```

---

### Task 3: Books layout wiring and the book-open icon

**Files:**
- Modify: `app/views/layouts/books/application.html.erb`
- Modify: `app/views/shared/_user_list_icon_template.html.erb`
- Create: `app/assets/svg/icons/lucide/outline/book-open.svg`
- Modify: `app/assets/svg/icons/README.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the books layout carries `data-controller="user-list-state"`, `#navbar_my_lists`, `UserLists::ModalComponent`, `Toast::RegionComponent`, and the icon `<template>`. Tasks 6 and 7 render widgets that require the modal and icon template to be present.

**Why the icon:** `Books::UserList.list_type_icons[:reading]` is `book-open`, which is neither vendored nor in the client-side template the modal clones from.

- [ ] **Steps 1-4: Icon — already done in Task 2 Step 0**

Task 2 had to vendor `book-open` to render the books dashboard at all, so these are done. Verify and move on:

```bash
ls app/assets/svg/icons/lucide/outline/book-open.svg
grep -c book-open app/views/shared/_user_list_icon_template.html.erb app/assets/svg/icons/README.md
```

Expected: the file exists and both greps return 1. If anything is missing, do it now — see Task 2 Step 0 for the exact content.

- [ ] **Step 5: Add the Stimulus hook to `<body>`**

In `app/views/layouts/books/application.html.erb`, replace:

```erb
  <body class="bg-base-200">
```

with:

```erb
  <body class="bg-base-200"
        data-controller="user-list-state"
        data-domain="<%= Current.domain %>"
        data-signed-in="<%= signed_in? %>">
```

- [ ] **Step 6: Add the My Lists nav item to both menus**

In the same file, in the **mobile dropdown** `<ul>`, after the Lists `<li>`:

```erb
            <%# Revealed client-side by user_list_state_controller when signed in. %>
            <li id="navbar_my_lists" class="hidden"><a href="/my/lists">My Lists</a></li>
```

And in the **desktop** `<ul class="menu menu-horizontal px-1">`, after its Lists `<li>`:

```erb
          <%# Revealed client-side by user_list_state_controller when signed in. %>
          <li id="navbar_my_lists" class="hidden"><a href="/my/lists">My Lists</a></li>
```

Both are required — the controller reveals whichever is visible at the current breakpoint, and the HTML stays identical for every visitor so it remains CDN-cacheable.

- [ ] **Step 7: Add the modal, toast region, and icon template**

In the same file, immediately before `<!-- Login Modal -->`:

```erb
    <%= render UserLists::ModalComponent.new %>
    <%= render Toast::RegionComponent.new %>
    <%= render "shared/user_list_icon_template" %>
```

- [ ] **Step 8: Select the books layout**

Nothing renders this layout yet — `MyListsController#resolve_layout` has no books branch. Add it now so this task's test can pass. In `app/controllers/my_lists_controller.rb`, replace the whole comment block above `resolve_layout` and the method itself with:

```ruby
  def resolve_layout
    case Current.domain
    when :games then "games/application"
    when :movies then "movies/application"
    when :books then "books/application"
    else "music/application"
    end
  end
```

The deleted comment described books falling through the `DOMAIN_SUBCLASSES` guard, which Task 1 removed.

- [ ] **Step 9: Write the failing test**

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  # --- books domain ---

  test "dashboard selects the books layout on the books domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success
    assert_includes response.body, 'data-theme="books"'
  end

  test "books layout carries the user-list state controller and modal" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success

    assert_includes response.body, 'data-controller="user-list-state"'
    assert_includes response.body, 'id="navbar_my_lists"'
    assert_includes response.body, 'id="user_list_modal"'
    assert_includes response.body, 'id="user-list-icons"'
  end
```

The existing test at line ~75, "unknown host falls back to the music layout (books has no layout yet)", now asserts the wrong thing. `ApplicationController#detect_current_domain` returns `:books` for unrecognized hosts, so once Step 8 adds the `when :books` branch, an unknown host renders the **books** layout, not music. `MyListsController` was the only controller still treating unknown hosts as music; this makes it consistent with the rest of the app. Replace that test with:

```ruby
  test "unknown host renders the books layout (detect_current_domain defaults to :books)" do
    host! "unknown.example.com"
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success
    assert_includes response.body, 'data-theme="books"'
  end
```

These tests need no books fixtures: Task 2's `EnsureDefaults` creates the four default lists on the first dashboard hit.

- [ ] **Step 10: Run the tests**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: PASS. If they were run before Step 8, they would have failed on `data-theme="light"`.

- [ ] **Step 11: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/views/layouts/books/application.html.erb app/views/shared/_user_list_icon_template.html.erb app/assets/svg/icons/ app/controllers/my_lists_controller.rb test/controllers/my_lists_controller_test.rb
git commit -m "Add user-list plumbing and the book-open icon to the books layout"
```

---

### Task 4: Books CSV export

**Files:**
- Modify: `app/controllers/my_lists_controller.rb` (`csv_headers`, `csv_row`, add `author_names`)
- Test: `test/controllers/my_lists_controller_test.rb`
- Modify: `test/fixtures/user_lists.yml`, `test/fixtures/user_list_items.yml`, `test/fixtures/books/book_authors.yml`

**Interfaces:**
- Consumes: Task 1's `subclasses_for(:books)`, Task 3's books layout and `resolve_layout` branch.
- Produces: fixtures `user_lists(:regular_user_books_favorites)`, `user_lists(:regular_user_books_read)`, and `user_list_items(:regular_user_books_item_1..3)`. Tasks 5, 7, 10, and 11 all reference these.

**Why:** `Books::Book` has no `release_year` column — every other listable does, which is why `csv_row`'s `else` branch was safe until now. Without a books branch the first "Download CSV" click on a books list raises `NoMethodError`.

- [ ] **Step 1: Add the books fixtures**

Append to `test/fixtures/books/book_authors.yml` (only `war_and_peace_tolstoy` exists today; `got` and `clash` need authors so the by-line and CSV have real values):

```yaml
got_king:
  book: got
  author: king
  position: 1
  role: 0

clash_king:
  book: clash
  author: king
  position: 1
  role: 0
```

Append to `test/fixtures/user_lists.yml`:

```yaml
regular_user_books_favorites:
  user: regular_user
  type: Books::UserList
  name: My Favorite Books
  list_type: 0 # favorites
  public: false

regular_user_books_read:
  user: regular_user
  type: Books::UserList
  name: Books I've Read
  list_type: 1 # read
  public: false
```

Append to `test/fixtures/user_list_items.yml`:

```yaml
regular_user_books_item_1:
  user_list: regular_user_books_favorites
  listable: war_and_peace (Books::Book)
  position: 1

regular_user_books_item_2:
  user_list: regular_user_books_favorites
  listable: got (Books::Book)
  position: 2

regular_user_books_item_3:
  user_list: regular_user_books_read
  listable: clash (Books::Book)
  position: 1
  completed_on: 2026-01-20
```

Do **not** create `test/fixtures/books/user_lists.yml` — an STI-subclass fixture file for `user_lists` kills the whole suite.

- [ ] **Step 2: Write the failing tests**

In `test/controllers/my_lists_controller_test.rb`, remove the `skip` line added in Task 3 Step 8, then append:

```ruby
  test "show renders a books list on the books domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :success
  end

  test "a books list 404s on the music domain" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "books CSV uses an Authors column and first_published_year" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_favorites), format: :csv)
    assert_response :success

    rows = CSV.parse(response.body.delete_prefix(BOM))
    assert_equal ["Position", "Title", "Authors", "Year"], rows.first
    assert_equal ["1", "War and Peace", "Leo Tolstoy", "1869"], rows.second
  end

  test "books CSV adds a Completed On column on a read list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_read), format: :csv)
    assert_response :success

    rows = CSV.parse(response.body.delete_prefix(BOM))
    assert_equal ["Position", "Title", "Authors", "Year", "Completed On"], rows.first
    assert_equal "2026-01-20", rows.second.last
  end
```

- [ ] **Step 3: Run them to verify they fail**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: the two CSV tests FAIL with `NoMethodError: undefined method 'release_year' for an instance of Books::Book`. The show/404 tests pass already.

- [ ] **Step 4: Add the books CSV branches**

In the same file, replace `csv_headers` and `csv_row`, and add `author_names` next to `artist_names`:

```ruby
  def csv_headers(listable_name, show_completed)
    headers =
      case listable_name
      when "Music::Album", "Music::Song" then ["Position", "Title", "Artists", "Year"]
      when "Books::Book" then ["Position", "Title", "Authors", "Year"]
      else ["Position", "Title", "Year"]
      end
    show_completed ? headers + ["Completed On"] : headers
  end

  def csv_row(item, listable_name, show_completed)
    listable = item.listable
    row =
      case listable_name
      when "Music::Album", "Music::Song"
        [item.position, listable.title, artist_names(listable), listable.release_year]
      when "Books::Book"
        [item.position, listable.title, author_names(listable), listable.first_published_year]
      else
        [item.position, listable.title, listable.release_year]
      end
    show_completed ? row + [item.completed_on&.iso8601] : row
  end

  def artist_names(listable)
    listable.artists.map(&:name).join(", ")
  end

  def author_names(listable)
    listable.book_authors.map { |book_author| book_author.author.name }.join(", ")
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/controllers/my_lists_controller.rb test/
git commit -m "Fix the books CSV export to use authors and first_published_year"
```

---

### Task 5: Books rendering in the list item component

**Files:**
- Modify: `app/components/user_lists/show/item_component.rb`
- Modify: `app/models/books/user_list.rb` (`listable_display_includes`)
- Modify: `app/components/books/card_component.rb:5` (the initializer)
- Test: `test/components/user_lists/show/item_component_test.rb`, `test/components/books/card_component_test.rb`, `test/controllers/my_lists_controller_test.rb`

**Interfaces:**
- Consumes: Task 4's fixtures.
- Produces: `UserLists::Show::ItemComponent.card_capable?("Books::Book") # => true`, so `my_lists/show.html.erb` shows the view switcher and picks a non-table wrapper for books. Also `Books::CardComponent.new(book:)` with no `rank:`/`index:` — Task 6 renders the widget into that same component.

**Two things happen here.** Books join `CARD_LISTABLES` (they have covers, descriptions, an author byline and a year — exactly the shape `default_view` was built for), and the preload is corrected: `listable_display_includes` currently loads `:authors`, but both `Books::CardComponent#author_names` and the new `by_line` read `book_authors` — a *different* association. Left alone, a 100-item books list in grid view fires 100 queries.

- [ ] **Step 1: Write the failing tests**

Append to `test/components/user_lists/show/item_component_test.rb`:

```ruby
  test "table_layout? is false for books outside table_view" do
    refute Component.table_layout?(listable_class: "Books::Book", view_mode: "default_view")
    refute Component.table_layout?(listable_class: "Books::Book", view_mode: "grid_view")
  end

  test "card_capable? is true for books" do
    assert Component.card_capable?("Books::Book")
  end

  test "renders a book card in grid_view" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_no_selector "tr"
    assert_selector "div.card[data-listable-id='#{item.listable_id}']"
  end

  test "renders the book title, author by-line and publication year in default_view" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "default_view", position: 1))

    assert_selector "a[href='/book/war-and-peace']", text: "War and Peace"
    assert_text "Leo Tolstoy"
    assert_text "1869"
  end

  test "renders a book table row in table_view with authors and year" do
    item = user_list_items(:regular_user_books_item_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_selector "tr td", text: "War and Peace"
    assert_selector "tr td", text: "Leo Tolstoy"
    assert_selector "tr td", text: "1869"
  end
```

Append to `test/components/books/card_component_test.rb` (inside `module Books; class CardComponentTest`) — the grid view renders this card with no rank to pass:

```ruby
    test "renders without a rank or index" do
      render_inline(Books::CardComponent.new(book: @book))

      assert_selector "a[href='/book/war-and-peace']", count: 1
      assert_no_selector ".badge"
    end
```

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  test "books grid view loads authors in one query regardless of item count" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    list = user_lists(:regular_user_books_favorites)

    author_queries = ->(sql_log) { sql_log.count { |sql| sql.include?("books_book_authors") } }

    two_item_log = capture_sql { get my_list_path(list, view_mode: "grid_view") }
    assert_response :success

    list.user_list_items.create!(listable: books_books(:of_mice_and_men))
    list.user_list_items.create!(listable: books_books(:cannery_row))
    ActiveRecord::Base.connection.clear_query_cache

    four_item_log = capture_sql { get my_list_path(list, view_mode: "grid_view") }
    assert_response :success

    assert_equal author_queries.call(two_item_log), author_queries.call(four_item_log),
      "author queries scaled with item count — the book_authors preload is missing"
  end
```

`capture_sql` is a helper this test file does not have yet. Add it as a private method at the bottom of the class:

```ruby
  private

  def capture_sql
    queries = []
    callback = ->(_n, _s, _f, _i, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end
```

This mirrors the notification-subscription idiom already used by the "dashboard counts come from a single grouped query" test in this same file. Comparing two item counts is more robust than a hard-coded `assert_queries_count(N)` here, because the show page's total query count also depends on the ranking configuration and pagination.

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/components/user_lists/show/item_component_test.rb test/components/books/card_component_test.rb test/controllers/my_lists_controller_test.rb
```

Expected: FAIL — `card_capable?("Books::Book")` is false, grid view renders a `<tr>`, by-line is empty, year is nil, and `Books::CardComponent.new(book:)` raises `ArgumentError: missing keywords: :rank, :index`.

- [ ] **Step 3: Give the card initializer defaults**

In `app/components/books/card_component.rb`, replace line 5:

```ruby
  def initialize(book:, rank: nil, index: 0)
```

The two existing call sites (`app/views/books/ranked_items/index.html.erb`, `app/views/books/lists/show.html.erb`) pass both and are unchanged.

- [ ] **Step 4: Fix the preload**

In `app/models/books/user_list.rb`, replace `listable_display_includes`:

```ruby
    def self.listable_display_includes
      [{book_authors: :author}, :categories, :primary_image, :descriptions]
    end
```

`Books::Book` declares `has_many :book_authors, -> { order(:position) }`, so ordering is preserved and matches `Books::CardComponent#author_names`.

- [ ] **Step 5: Add the books branches to the item component**

In `app/components/user_lists/show/item_component.rb`, make these five edits.

Add `Books::Book` to the constant and update its comment:

```ruby
  # Listables that have a dedicated card component (rendered as a <div> in
  # default/grid views). Everything else (songs, movies) renders as a <tr>
  # table row.
  CARD_LISTABLES = %w[Music::Album Games::Game Books::Book].freeze
```

`listable_card`:

```ruby
  def listable_card
    case listable
    when Music::Album then Music::Albums::CardComponent.new(album: listable)
    when Games::Game then Games::CardComponent.new(game: listable)
    when Books::Book then Books::CardComponent.new(book: listable)
    end
  end
```

`title_link` — books have no rc-aware path helper and My Lists is a global route with no rc context, so link directly:

```ruby
  def title_link
    case listable
    when Music::Album then link_to_album(listable, nil, class: "hover:text-primary")
    when Games::Game then link_to_game(listable, nil, class: "hover:text-primary")
    when Books::Book then link_to(listable.title, book_path(listable.slug), class: "hover:text-primary")
    else title
    end
  end
```

`cover_aspect_class` — books are taller than game box art:

```ruby
  def cover_aspect_class
    case listable
    when Books::Book then "aspect-[2/3]"
    when Games::Game then "aspect-[3/4]"
    else "aspect-square"
    end
  end
```

`by_line` and `year`:

```ruby
  def by_line
    if listable.is_a?(Books::Book)
      listable.book_authors.map { |book_author| book_author.author.name }.join(", ")
    elsif listable.respond_to?(:artists)
      listable.artists.map(&:name).join(", ")
    elsif listable.is_a?(Games::Game)
      listable.game_companies.select(&:developer?).map { |gc| gc.company.name }.join(", ")
    else
      ""
    end
  end
```

```ruby
  def year
    listable.is_a?(Books::Book) ? listable.first_published_year : listable.try(:release_year)
  end
```

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/components/user_lists/show/item_component_test.rb test/components/books/card_component_test.rb test/controllers/my_lists_controller_test.rb
```

Expected: PASS.

- [ ] **Step 7: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/components/user_lists/show/item_component.rb app/components/books/card_component.rb app/models/books/user_list.rb test/
git commit -m "Render books lists in list, grid, and table views"
```

---

### Task 6: Add-to-list widget on books surfaces

**Files:**
- Modify: `app/components/books/card_component.html.erb`
- Modify: `app/views/books/books/show.html.erb`
- Test: `test/components/books/card_component_test.rb`

**Interfaces:**
- Consumes: Task 3's icon template and modal (the widget renders `helpers.icon "plus"` and dispatches to `#user_list_modal`); Task 5's card-initializer defaults.
- Produces: every books card and `/book/:slug` carries a `UserLists::CardWidgetComponent`. The Task 8 E2E spec exercises it.

**Landmine — read before writing the template.** `Books::CardComponent`'s title link carries `after:absolute after:inset-0` (a stretched link) inside a `position: relative` DaisyUI card. That `::after` overlay is a positioned element with no `z-index`, so it paints above any later *non*-positioned sibling. Dropping the widget in unwrapped makes the button **silently unclickable**. It must be wrapped in `relative z-10`. Music and games cards have no stretched link, so copying their markup will not surface this, and no unit test can catch it — the Task 8 E2E spec is the real guard.

- [ ] **Step 1: Write the failing tests**

Append to `test/components/books/card_component_test.rb` (inside `module Books; class CardComponentTest`):

```ruby
    test "renders the add-to-list widget above the stretched link overlay" do
      render_inline(Books::CardComponent.new(book: @book, rank: 1, index: 0))

      assert_selector ".relative.z-10 [data-controller='user-list-widget']"
      assert_selector "[data-user-list-widget-listable-type-value='Books::Book']"
      assert_selector "[data-user-list-widget-listable-id-value='#{@book.id}']"
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/components/books/card_component_test.rb
```

Expected: FAIL — no widget selector.

- [ ] **Step 3: Add the widget to the card**

In `app/components/books/card_component.html.erb`, immediately after the `author_names` block and before the closing `</div>` of `card-body`:

```erb
    <%# relative z-10 keeps this above the title's after:absolute stretched-link
        overlay, which would otherwise swallow the click. %>
    <div class="card-actions justify-end mt-2 relative z-10">
      <%= render UserLists::CardWidgetComponent.new(listable: book) %>
    </div>
```

- [ ] **Step 4: Add the widget to the book show page**

In `app/views/books/books/show.html.erb`, immediately after the `<% if @ranked_item %> … <% end %>` block that closes the title `<div>`, and still inside that `<div>`:

```erb
      <div class="mt-4">
        <%= render UserLists::CardWidgetComponent.new(listable: @book) %>
      </div>
```

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/components/books/card_component_test.rb
```

Expected: PASS.

- [ ] **Step 6: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/components/books/card_component.html.erb app/views/books/books/show.html.erb test/components/books/card_component_test.rb
git commit -m "Add the add-to-list widget to books cards and the book show page"
```

---

### Task 7: Books typeahead for adding items

**Files:**
- Modify: `app/lib/search/listable_autocomplete.rb:16-32` (`CONFIGS`) and `:58-68` (`label_for`)
- Test: `test/lib/search/listable_autocomplete_test.rb`, `test/components/user_lists/show/add_item_component_test.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Search::ListableAutocomplete.searchable?("Books::Book") # => true`. This alone turns on `UserLists::Show::AddItemComponent` for books lists — it has a `render?` predicate gated on `searchable?`, so no view change is needed.

- [ ] **Step 1: Write the failing tests**

In `test/lib/search/listable_autocomplete_test.rb`, add `Books::Book` to the supported-types assertion and append:

```ruby
    test "searchable? is true for books" do
      assert Search::ListableAutocomplete.searchable?("Books::Book")
    end

    test "search labels books with their authors" do
      book = books_books(:war_and_peace)
      ::Search::Books::Search::BookAutocomplete.stubs(:call).returns([
        {id: book.id.to_s, score: 7.0, source: {}}
      ])

      results = Search::ListableAutocomplete.search(listable_type: "Books::Book", query: "war")

      assert_equal [book.id], results.map { |r| r[:value] }
      assert_equal "War and Peace — Leo Tolstoy", results.first[:text]
    end

    test "search falls back to the bare title for a book with no authors" do
      book = books_books(:crime_and_punishment)
      ::Search::Books::Search::BookAutocomplete.stubs(:call).returns([
        {id: book.id.to_s, score: 7.0, source: {}}
      ])

      results = Search::ListableAutocomplete.search(listable_type: "Books::Book", query: "crime")

      assert_equal book.title, results.first[:text]
    end
```

Append to `test/components/user_lists/show/add_item_component_test.rb`:

```ruby
  test "renders the typeahead for a books list" do
    list = user_lists(:regular_user_books_favorites)
    render_inline(Component.new(list: list))

    assert_selector "[data-testid='add-item-search']"
    assert_selector "[data-autocomplete-url-value*='Books%3A%3ABook']"
    assert_selector "input[placeholder='Search for a book to add…']"
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/lib/search/listable_autocomplete_test.rb test/components/user_lists/show/add_item_component_test.rb
```

Expected: FAIL — `searchable?("Books::Book")` is false and `search` returns `[]`.

- [ ] **Step 3: Register the books config**

In `app/lib/search/listable_autocomplete.rb`, add to `CONFIGS` after the `Games::Game` entry:

```ruby
      "Books::Book" => {
        service: ::Search::Books::Search::BookAutocomplete,
        model: ::Books::Book,
        includes: [{book_authors: :author}]
      }
```

`BookAutocomplete` defaults to `book_kind: "standalone"`, which is the correct filter here.

- [ ] **Step 4: Add the books label**

In the same file, add a branch to `label_for` before the `else`:

```ruby
      when "Books::Book"
        authors = record.book_authors.map { |book_author| book_author.author.name }.join(", ")
        authors.present? ? "#{record.title} — #{authors}" : record.title
```

`item_noun` in `AddItemComponent` already derives `"book"` from `"Books::Book"`, so the placeholder needs no change.

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/lib/search/listable_autocomplete_test.rb test/components/user_lists/show/add_item_component_test.rb
```

Expected: PASS.

- [ ] **Step 6: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/lib/search/listable_autocomplete.rb test/
git commit -m "Add books to the add-item typeahead"
```

---

### Task 8: E2E coverage for increment 1

**Files:**
- Modify: `e2e/playwright.config.ts`
- Create: `e2e/tests/books/account/my-lists.spec.ts`
- Create: `e2e/tests/books/account/add-to-list.spec.ts`

**Interfaces:**
- Consumes: everything from Tasks 1–7, running against a live local dev server.
- Produces: a `books-account` Playwright project for signed-in books specs. Task 13 adds an anonymous public-list spec to the existing `books` project.

**Why a new project:** the existing `books` project has **no** `storageState` — it runs anonymous — and only `books-admin` uses `booksAuthFile`. Signed-in non-admin specs need their own project with the `books-setup` dependency.

- [ ] **Step 1: Add the signed-in books project**

In `e2e/playwright.config.ts`, change the anonymous `books` project's `testMatch` so it does not swallow the new directory:

```ts
      testMatch: /books\/(?!admin\/)(?!account\/).*/,
```

Then add this project after `books-admin`:

```ts
    {
      name: 'books-account',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev-new.thegreatestbooks.org',
        storageState: booksAuthFile,
      },
      testMatch: /books\/account\/.*/,
      dependencies: ['books-setup'],
    },
```

- [ ] **Step 2: Write the My Lists spec**

Create `e2e/tests/books/account/my-lists.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('Books My Lists', () => {
  test('the My Lists nav link is revealed when signed in', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_my_lists').first()).not.toHaveClass(/hidden/);
  });

  test('the dashboard lists the four books defaults', async ({ page }) => {
    await page.goto('/my/lists');

    await expect(page.getByRole('heading', { name: 'My Lists', level: 1 })).toBeVisible();
    const dashboard = page.getByTestId('my-lists-dashboard');
    await expect(dashboard.getByText('My Favorite Books')).toBeVisible();
    await expect(dashboard.getByText("Books I've Read")).toBeVisible();
    await expect(dashboard.getByText("Books I'm Reading")).toBeVisible();
    await expect(dashboard.getByText('Books I Want to Read')).toBeVisible();
  });

  test('the dashboard renders in the books theme', async ({ page }) => {
    await page.goto('/my/lists');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'books');
  });

  test('a list page offers all three view modes and switches between them', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const toolbar = page.getByTestId('list-toolbar');
    await expect(toolbar.getByRole('link', { name: 'Grid' })).toBeVisible();
    await toolbar.getByRole('link', { name: 'Grid' }).click();

    await expect(page).toHaveURL(/view_mode=grid_view/);
  });

  test('a list page offers a CSV download', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const link = page.getByTestId('download-csv');
    await expect(link).toBeVisible();

    const response = await page.request.get((await link.getAttribute('href'))!);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
  });
});
```

- [ ] **Step 3: Write the add-to-list spec**

Create `e2e/tests/books/account/add-to-list.spec.ts`. This is the only guard on the Task 6 stretched-link fix — if the `relative z-10` wrapper is missing, the click below times out.

```ts
import { test, expect } from '@playwright/test';

test.describe('Books add-to-list widget', () => {
  test('the widget button on a ranked-grid card is clickable and opens the modal', async ({ page }) => {
    await page.goto('/');

    const card = page.locator('[data-listable-type="Books::Book"]').first();
    await card.getByRole('button', { name: /Add to list/i }).click();

    await expect(page.locator('#user_list_modal')).toBeVisible();
  });

  test('ticking a list adds the book and the state survives a reload', async ({ page }) => {
    await page.goto('/');

    const card = page.locator('[data-listable-type="Books::Book"]').first();
    const listableId = await card.getAttribute('data-listable-id');
    await card.getByRole('button', { name: /Add to list/i }).click();

    const modal = page.locator('#user_list_modal');
    await expect(modal).toBeVisible();
    const row = modal.getByRole('checkbox').first();
    await row.check();
    await expect(row).toBeChecked();
    await page.keyboard.press('Escape');

    await page.reload();
    const sameCard = page.locator(`[data-listable-id="${listableId}"]`).first();
    await expect(sameCard.locator('[data-user-list-widget-target="iconStrip"]')).not.toHaveClass(/hidden/);

    // Leave the account as we found it.
    await sameCard.getByRole('button', { name: /Add to list/i }).click();
    await modal.getByRole('checkbox').first().uncheck();
  });

  test('the widget on the book show page opens the modal', async ({ page }) => {
    await page.goto('/');
    await page.locator('[data-listable-type="Books::Book"] a').first().click();

    await page.getByRole('button', { name: /Add to list/i }).first().click();
    await expect(page.locator('#user_list_modal')).toBeVisible();
  });
});
```

If any assertion cannot target an element by role/text/label, add a kebab-case `data-testid` to the markup rather than a CSS-class selector.

- [ ] **Step 4: Run the specs**

Start the dev server in one shell (`bin/dev`), then:

```bash
yarn test:e2e --project=books-account
```

Expected: PASS. If every spec times out on the public homepage, the Playwright account lost its role in a dev-DB reseed — run `bin/rails e2e:admin` and retry.

- [ ] **Step 5: Commit**

```bash
git add e2e/playwright.config.ts e2e/tests/books/account/
git commit -m "Add E2E coverage for books My Lists and the add-to-list widget"
```

---

### Task 9: Document increment 1

**Files:**
- Modify: `docs/features/user-lists.md` (project root, **not** `web-app/docs/`)

**Interfaces:**
- Consumes: Tasks 1–8.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Update the default-list bootstrap section**

In the "Default-List Bootstrap" section, change "The result is **12 default lists** per new user" to **16**, and add a row to the table:

```markdown
| `Books::UserList`          | 4     | favorites, read, reading, want_to_read |
```

Then add a paragraph after the table:

```markdown
The callback only fires on signup, so `Services::UserLists::EnsureDefaults` fills the gap for
users created before a subclass joined `DEFAULT_SUBCLASSES`. `MyListsController#index` and
`UserListStateController#show` both pass it the lists they already loaded; it diffs against the
domain's `default_list_types`, creates only what's missing, and costs zero queries and zero writes
when the set is complete. It also repairs the ~145 legacy books users the migration deliberately
left short (`D-verbatim-defaults`).
```

- [ ] **Step 2: Update the resolver section**

In "Shared domain→subclass resolver", replace the sentence ending "Returns `[]` for unknown/unsupported domains (e.g. books)" with:

```markdown
`UserList::DOMAIN_SUBCLASSES` covers all four domains; `subclasses_for` returns `[]` only for an
unrecognized host.
```

In the "Scoping by Item Type" section, delete the parenthetical "(future books)" if present. Leave the "Class Hierarchy (STI)" block as-is — it already lists `Books::UserList` with the correct `list_type`s.

- [ ] **Step 2b: Delete the stale `release_year` 500 warning**

The books bullet in "What's Not Yet Implemented" claims a naive wiring "would 500 on the first
'Download CSV' click" because `Books::Book` lacks `release_year`. That was true when written and
stopped being true on **2026-07-22**, when commit `f0e9e75` added `Books::Book#release_year` as a
delegator to `first_published_year`. The real pre-fix defect was a silently missing Authors column,
not a crash. Step 3 deletes that whole bullet — make sure the claim does not survive anywhere else
in the file, and do not repeat it in the replacement text.

- [ ] **Step 3: Rewrite the books bullet in "What's Not Yet Implemented"**

Delete the long "A books layout and books UI wiring" bullet entirely and replace the public-list bullet with:

```markdown
- Public-list **discovery** (a browsable index of public lists) and "consumed" badge upgrades —
  the remainder of `user-lists-02d`. Direct-link viewing of a public list shipped with the books
  UI work; see `docs/superpowers/specs/2026-08-02-books-user-lists-ui-design.md`.
```

If Increment 2 is not yet merged when this task runs, keep the direct-link sentence out and add it in Task 14 instead.

- [ ] **Step 4: Add the spec to Related Documentation**

```markdown
- `docs/superpowers/specs/2026-08-02-books-user-lists-ui-design.md` — books UI wiring + public viewing
```

- [ ] **Step 5: Commit**

```bash
git add docs/features/user-lists.md
git commit -m "Document the books user-lists wiring"
```

---

# Increment 2 — Public list viewing

### Task 10: Visibility scope and policy

**Files:**
- Modify: `app/models/user_list.rb` (scopes block)
- Modify: `app/policies/user_list_policy.rb`
- Test: `test/models/user_list_test.rb`, `test/policies/user_list_policy_test.rb`

**Interfaces:**
- Consumes: Task 1.
- Produces: `UserList.visible_to(user_or_nil)` scope and `UserListPolicy#show?` returning `owner? || record.public?`. Task 11 uses both.

**Why the scope and not just the policy:** `ApplicationController` rescues `Pundit::NotAuthorizedError` with `redirect_back` + a flash. A redirect leaks that a private list exists. Keeping visibility in the query preserves today's 404-hides-existence behavior.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/user_list_test.rb`:

```ruby
  # setup already binds @user = users(:regular_user),
  # @list = user_lists(:regular_user_music_albums_favorites) (private),
  # @custom_list = user_lists(:regular_user_custom_albums) (public: true).

  test "visible_to returns public lists plus the viewer's own private ones" do
    visible = UserList.visible_to(@user)

    assert_includes visible, @custom_list
    assert_includes visible, @list
  end

  test "visible_to returns only public lists for an anonymous viewer" do
    visible = UserList.visible_to(nil)

    assert_includes visible, @custom_list
    assert_not_includes visible, @list
  end

  test "visible_to excludes another user's private list but keeps their public one" do
    stranger = users(:admin_user)
    visible = UserList.visible_to(stranger)

    assert_not_includes visible, @list
    assert_includes visible, @custom_list
    assert_includes visible, user_lists(:admin_user_games_favorites)
  end

  test "visible_to composes with a type filter" do
    visible = UserList.where(type: "Music::Albums::UserList").visible_to(@user)

    assert_includes visible, @custom_list
    assert_not_includes visible, user_lists(:regular_user_games_favorites)
  end
```

Append to `test/policies/user_list_policy_test.rb`:

```ruby
  test "show? allows the owner" do
    list = user_lists(:regular_user_books_favorites)
    assert UserListPolicy.new(list.user, list).show?
  end

  test "show? allows anyone to view a public list" do
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    assert UserListPolicy.new(users(:admin_user), list).show?
    assert UserListPolicy.new(nil, list).show?
  end

  test "show? denies a non-owner and an anonymous viewer on a private list" do
    list = user_lists(:regular_user_books_favorites)

    refute UserListPolicy.new(users(:admin_user), list).show?
    refute UserListPolicy.new(nil, list).show?
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/user_list_test.rb test/policies/user_list_policy_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'visible_to'`, and `show?` denies a public non-owner.

- [ ] **Step 3: Add the scope**

In `app/models/user_list.rb`, add after the existing `owned_by` scope:

```ruby
  # Lists a viewer may read: their own, plus anyone's public lists. Kept as a
  # query rather than a policy check because Pundit's NotAuthorizedError rescue
  # redirects, which would leak that a private list exists; falling out of this
  # scope 404s instead.
  scope :visible_to, ->(user) { user ? public_lists.or(owned_by(user)) : public_lists }
```

- [ ] **Step 4: Open up the policy**

In `app/policies/user_list_policy.rb`, replace `show?` and its comment:

```ruby
  # Owners always; everyone else only when the list is public (02d direct-link
  # viewing). Scope stays owner-only — it models "my lists", not "lists I may view".
  def show?
    owner? || record.public?
  end
```

Update the class-level comment so it no longer says "public-list viewing is 02d".

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/models/user_list_test.rb test/policies/user_list_policy_test.rb
```

Expected: PASS.

- [ ] **Step 6: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/models/user_list.rb app/policies/user_list_policy.rb test/
git commit -m "Allow reading a public user list"
```

---

### Task 11: Viewer-aware show page

**Files:**
- Modify: `app/controllers/my_lists_controller.rb` (`before_action`, `show`, `persist_view_mode`)
- Modify: `app/views/my_lists/show.html.erb`
- Test: `test/controllers/my_lists_controller_test.rb`

**Interfaces:**
- Consumes: `UserList.visible_to` and `UserListPolicy#show?` (Task 10); the books fixtures (Task 4).
- Produces: `@owner` (Boolean) and `@indexable = false` in the show view.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  # --- public viewing ---

  test "anonymous viewer can read a public list" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    get my_list_path(list)
    assert_response :success
  end

  test "anonymous viewer gets 404 on a private list" do
    host! Rails.application.config.domains[:books]
    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "non-owner gets 404 on someone else's private list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "non-owner reading a public list gets no add box and no backlink" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)
    assert_response :success
    assert_no_match(/data-testid="add-item-search"/, response.body)
    assert_no_match(/data-testid="back-to-lists"/, response.body)
  end

  test "owner still gets the add box and backlink" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :success
    assert_match(/data-testid="add-item-search"/, response.body)
    assert_match(/data-testid="back-to-lists"/, response.body)
  end

  test "a non-owner's view_mode param does not persist to the list" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true, view_mode: :default_view)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list, view_mode: "grid_view")
    assert_response :success
    assert_equal "default_view", list.reload.view_mode
  end

  test "an owner's view_mode param does persist" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(view_mode: :default_view)
    sign_in_as(@user, stub_auth: true)

    get my_list_path(list, view_mode: "grid_view")
    assert_equal "grid_view", list.reload.view_mode
  end

  test "CSV download works for a public list read by a non-owner" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list, format: :csv)
    assert_response :success
  end

  test "public list pages are never cached" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    get my_list_path(list)
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "the dashboard still requires sign-in" do
    host! Rails.application.config.domains[:books]
    get my_lists_path
    assert_redirected_to "/"
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: FAIL — anonymous access redirects to `/` instead of rendering, and non-owners 404 on public lists.

- [ ] **Step 3: Narrow the sign-in requirement**

In `app/controllers/my_lists_controller.rb`, replace:

```ruby
  before_action :require_signed_in!
```

with:

```ruby
  # show is reachable anonymously for public lists; visibility is enforced by the
  # visible_to scope below, which 404s rather than redirecting.
  before_action :require_signed_in!, only: [:index]
```

- [ ] **Step 4: Make `show` viewer-aware**

In the same file, replace the first four lines of `show` (the comment, `types`, `@list`, and `authorize`) with:

```ruby
    # Scoped to the current domain's subclasses so a list from another domain
    # (e.g. a games list opened on the music host) 404s rather than rendering in
    # the wrong layout. visible_to keeps private non-owner reads at 404 too —
    # Pundit's rescue would redirect, leaking existence.
    types = UserList.subclasses_for(Current.domain).map(&:name)
    @list = UserList.where(type: types).visible_to(current_user).find(params[:id])
    authorize @list, :show?, policy_class: UserListPolicy
    @owner = @list.user_id == current_user&.id
    @indexable = false
```

- [ ] **Step 5: Split view_mode resolution**

In the same file, replace:

```ruby
    persist_view_mode
    @view_mode = @list.view_mode
```

with:

```ruby
    persist_view_mode
    @view_mode = if @owner
      @list.view_mode
    else
      params[:view_mode].presence_in(UserList.view_modes.keys) || @list.view_mode
    end
```

and add an ownership guard to `persist_view_mode`:

```ruby
  # Persist the view_mode when the owner switches it via the query param. A
  # non-owner's param changes only their own render (see #show).
  def persist_view_mode
    return unless @owner
    requested = params[:view_mode]
    return if requested.blank? || !UserList.view_modes.key?(requested)
    @list.update!(view_mode: requested) unless @list.view_mode == requested
  end
```

- [ ] **Step 6: Gate the owner-only UI**

In `app/views/my_lists/show.html.erb`, wrap the backlink (the `link_to my_lists_path` block with `data: { testid: "back-to-lists" }`) in:

```erb
      <% if @owner %>
        …existing link_to block…
      <% end %>
```

And wrap the add-item component:

```erb
  <% if @owner %>
    <%= render UserLists::Show::AddItemComponent.new(list: @list) %>
  <% end %>
```

- [ ] **Step 7: Run the tests**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: PASS.

- [ ] **Step 8: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add app/controllers/my_lists_controller.rb app/views/my_lists/show.html.erb test/
git commit -m "Let non-owners read a public user list"
```

---

### Task 12: Owner attribution on public lists

**Files:**
- Modify: `app/views/my_lists/show.html.erb`
- Test: `test/controllers/my_lists_controller_test.rb`

**Interfaces:**
- Consumes: `@owner` and `@list` (Task 11).
- Produces: nothing consumed by later tasks.

**Why the fallback matters:** only 22 of 88 public-list owners have a `display_name`. Show nothing rather than inventing "Anonymous", and never render `email` or `name`.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  test "a public list read by a non-owner shows the owner's display name" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    list.user.update!(display_name: "Ada Lovelace")
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)
    assert_match(/Ada Lovelace/, response.body)
  end

  test "attribution is omitted when the owner has no display name" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    list.user.update_column(:display_name, nil)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)
    assert_response :success
    assert_no_match(/list-owner/, response.body)
    assert_no_match(Regexp.new(Regexp.escape(list.user.email)), response.body)
  end

  test "the owner does not see attribution on their own list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_no_match(/list-owner/, response.body)
  end
```

`update_column` bypasses validations — `display_name` may be required on `User`.

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: FAIL — no attribution is rendered.

- [ ] **Step 3: Render the attribution**

In `app/views/my_lists/show.html.erb`, immediately after the `<h1>` holding `@list.name`:

```erb
      <% if !@owner && @list.user.display_name.present? %>
        <p class="text-sm text-base-content/60" data-testid="list-owner">
          A list by <%= @list.user.display_name %>
        </p>
      <% end %>
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb
git add app/views/my_lists/show.html.erb test/controllers/my_lists_controller_test.rb
git commit -m "Attribute a public user list to its owner"
```

---

### Task 13: Legacy /user_lists redirects

**Files:**
- Modify: `config/routes.rb:282-287`
- Test: `test/controllers/my_lists_controller_test.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: three 301s. No later task depends on them.

**Ordering is load-bearing:** `user_lists/new` must be declared **before** `get "user_lists/:id"` or `:id` swallows `"new"`. `GET /user_lists` and the existing `POST /user_lists` (create) are different verbs and coexist.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  # --- legacy /user_lists redirects ---

  test "legacy /user_lists index 301s to /my/lists" do
    host! Rails.application.config.domains[:books]
    get "/user_lists"
    assert_response :moved_permanently
    assert_redirected_to "/my/lists"
  end

  test "legacy /user_lists/new 301s to /my/lists and is not read as an id" do
    host! Rails.application.config.domains[:books]
    get "/user_lists/new"
    assert_response :moved_permanently
    assert_redirected_to "/my/lists"
  end

  test "legacy /user_lists/:id/edit 301s to the read page" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    get "/user_lists/#{list.id}/edit"
    assert_response :moved_permanently
    assert_redirected_to "/my/lists/#{list.id}"
  end

  test "the /user_lists/:id alias still resolves to the show action" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get "/user_lists/#{user_lists(:regular_user_books_favorites).id}"
    assert_response :success
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: FAIL — `/user_lists` and `/user_lists/new` have no GET route (`new` will be caught by `:id` and 404 on lookup).

- [ ] **Step 3: Add the redirects**

In `config/routes.rb`, immediately **above** the existing `get "user_lists/:id", to: "my_lists#show", as: :user_list` line and below its comment block:

```ruby
  # The legacy site's index/new/edit have no equivalent here — the write surface
  # is Phase B (user-lists-02f) — so they land on the read pages. `new` must be
  # declared before `:id` or the wildcard swallows it.
  get "user_lists", to: redirect("/my/lists", status: 301)
  get "user_lists/new", to: redirect("/my/lists", status: 301)
  get "user_lists/:id/edit", to: redirect("/my/lists/%{id}", status: 301), constraints: {id: /\d+/}
```

Do not wrap these in a `scope "(/rc/...)"` block — a route-level `constraints:` inside that scope disables the optimized URL helper and binds the positional arg to the rc segment.

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/controllers/my_lists_controller_test.rb
```

Expected: PASS.

- [ ] **Step 5: Run the full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add config/routes.rb test/controllers/my_lists_controller_test.rb
git commit -m "Redirect the legacy /user_lists index, new, and edit URLs"
```

---

### Task 14: Public-list E2E and seed task, plus docs

**Files:**
- Modify: `lib/tasks/e2e.rake`
- Create: `e2e/tests/books/public-list.spec.ts`
- Modify: `docs/features/user-lists.md`

**Interfaces:**
- Consumes: Tasks 10–13.
- Produces: `bin/rails e2e:books_public_list`, which prints the list id the spec needs.

**Why a seed task:** a public books list **cannot be created through any UI** — the modal's inline create makes a private `custom` list, and the public toggle is Phase B. The spec lands in the existing anonymous `books` Playwright project (no `storageState`), which is exactly what it needs.

- [ ] **Step 1: Extract the shared email lookup and add the seed task**

In `lib/tasks/e2e.rake`, refactor the existing email-reading block into a helper and add the new task. Replace the whole file with:

```ruby
namespace :e2e do
  def playwright_email
    env_file = Rails.root.join("e2e", ".env")
    abort "Missing #{env_file}. Copy e2e/.env.example and fill it in." unless File.exist?(env_file)

    email = File.readlines(env_file)
      .grep(/\APLAYWRIGHT_ADMIN_EMAIL=/)
      .first
      &.split("=", 2)
      &.last
      &.strip
      &.delete_prefix('"')
      &.delete_suffix('"')

    abort "PLAYWRIGHT_ADMIN_EMAIL not set in #{env_file}" if email.blank?
    email
  end

  desc "Grant the Playwright admin account (e2e/.env PLAYWRIGHT_ADMIN_EMAIL) the global admin role"
  task admin: :environment do
    email = playwright_email
    user = User.find_by(email: email)

    if user.nil?
      abort <<~MSG
        No User with email #{email}.

        The account must exist in Firebase AND in this database. Sign in once through
        the browser as that account to create the Rails User record, then re-run this task.
      MSG
    end

    user.update!(role: :admin)
    puts "#{email} (id #{user.id}) is now a global admin."
  end

  desc "Ensure the Playwright account owns one public and one private books list, each with items"
  task books_public_list: :environment do
    email = playwright_email
    user = User.find_by(email: email)
    abort "No User with email #{email}. Run `bin/rails e2e:admin` first." if user.nil?

    books = Books::Book.where(book_kind: :standalone).limit(3).to_a
    abort "No standalone books in this database." if books.empty?

    public_list = Books::UserList.find_or_create_by!(user: user, name: "E2E Public Books") do |list|
      list.list_type = :custom
    end
    public_list.update!(public: true)
    books.each { |book| public_list.user_list_items.find_or_create_by!(listable: book) }

    private_list = Books::UserList.find_or_create_by!(user: user, name: "E2E Private Books") do |list|
      list.list_type = :custom
    end
    private_list.update!(public: false)
    books.first(1).each { |book| private_list.user_list_items.find_or_create_by!(listable: book) }

    puts "PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID=#{public_list.id}"
    puts "PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID=#{private_list.id}"
  end
end
```

- [ ] **Step 2: Run the seed task and record the ids**

```bash
bin/rails e2e:books_public_list
```

Add both printed lines to `e2e/.env`, and add them (with placeholder values) to `e2e/.env.example`:

```
PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID=0
PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID=0
```

- [ ] **Step 3: Write the spec**

Create `e2e/tests/books/public-list.spec.ts` (the anonymous `books` project picks this up automatically):

```ts
import { test, expect } from '@playwright/test';

const publicId = process.env.PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID!;
const privateId = process.env.PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID!;

test.describe('Public books user list', () => {
  test('an anonymous visitor can read a public list', async ({ page }) => {
    const response = await page.goto(`/my/lists/${publicId}`);

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'E2E Public Books', level: 1 })).toBeVisible();
    await expect(page.getByTestId('list-item-count')).toBeVisible();
  });

  test('an anonymous visitor sees no add box and no My Lists backlink', async ({ page }) => {
    await page.goto(`/my/lists/${publicId}`);

    await expect(page.getByTestId('add-item-search')).toHaveCount(0);
    await expect(page.getByTestId('back-to-lists')).toHaveCount(0);
  });

  test('a public list is noindex', async ({ page }) => {
    await page.goto(`/my/lists/${publicId}`);

    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
  });

  test('the legacy /user_lists/:id alias resolves for a public list', async ({ page }) => {
    const response = await page.goto(`/user_lists/${publicId}`);

    expect(response?.status()).toBe(200);
  });

  test('a private list 404s for an anonymous visitor', async ({ page }) => {
    const response = await page.goto(`/my/lists/${privateId}`);

    expect(response?.status()).toBe(404);
  });

  test('the legacy /user_lists index 301s to /my/lists', async ({ request }) => {
    // Asserted at the HTTP level, not via page.goto: /my/lists then bounces an
    // anonymous visitor to /, so the browser's final URL is not the redirect target.
    const response = await request.get('/user_lists', { maxRedirects: 0 });

    expect(response.status()).toBe(301);
    expect(response.headers()['location']).toContain('/my/lists');
  });
});
```

- [ ] **Step 4: Run the specs**

With `bin/dev` running:

```bash
yarn test:e2e --project=books
```

Expected: PASS.

- [ ] **Step 5: Document increment 2**

In `docs/features/user-lists.md`, add a subsection under "My Lists Read Surface":

```markdown
### Public list viewing (direct link)

`MyListsController#show` is viewer-aware. `UserList.visible_to(current_user)` returns the viewer's
own lists plus anyone's public lists; anything else falls out of the scope and 404s, which hides
existence. (Pundit's `NotAuthorizedError` rescue redirects with a flash, so the check cannot live in
the policy alone — `UserListPolicy#show?` mirrors the rule as defense in depth.) `require_signed_in!`
applies to `index` only.

Owner-gated on `@owner`: the add-item box, the "My Lists" backlink, and `view_mode` persistence — a
non-owner's `?view_mode=` changes only their own render. Sorting, pagination, CSV, and the per-item
Add-to-list widget are available to everyone.

Non-owners see "A list by <display_name>" when the owner has one, and nothing when they don't (only
22 of 88 public-list owners do). `email` and `name` are never rendered. Pages set `@indexable = false`
(`noindex, follow` via the books layout) and keep `prevent_caching` — the HTML is owner-aware, so
edge-caching it would serve one viewer's toolbar to another.

Legacy `GET /user_lists`, `/user_lists/new`, and `/user_lists/:id/edit` 301 to the read pages.

Still unbuilt: a public-list **discovery** index and "consumed" badges.
```

Also apply the Task 9 Step 3 change if it was deferred.

- [ ] **Step 6: Commit**

```bash
bin/rails test
bundle exec standardrb
git add lib/tasks/e2e.rake e2e/ docs/features/user-lists.md
git commit -m "Add public-list E2E coverage, its seed task, and docs"
```

---

## Final verification

- [ ] `bin/rails test` — full suite green
- [ ] `bundle exec standardrb` — clean
- [ ] `yarn test:e2e --project=books --project=books-account` — green with `bin/dev` running
- [ ] `git log --oneline` shows one commit per task, all on `worktree-books-user-lists-ui`

CI eager-loads (`CI=true`) and has no `.env`, so it is stricter than a local run. Do not push or open a PR without asking.
