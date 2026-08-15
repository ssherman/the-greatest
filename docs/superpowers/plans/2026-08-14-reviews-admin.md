# Reviews Admin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give admins a per-review detail page they can read and delete from, surface a user's
review history on the admin user page, and lift the reviews list out of the books folder so music
and games cost four lines each later.

**Architecture:** `Admin::ReviewsBaseController` is already domain-generic and already does
`index` + `destroy`. This adds a `show` action to it, moves its two templates into a shared
`app/views/admin/reviews_base/` directory that Rails resolves automatically for every subclass, and
adds a reviews card to the global `Admin::UsersController#show`. Because the user page routes on all
four hostnames while `/admin/reviews` routes only on the books hostname, links from the user page
into a review must be absolute URLs carrying the books host.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponents, DaisyUI 5 on Tailwind CSS 4,
Playwright for E2E.

**Spec:** `docs/superpowers/specs/2026-08-14-reviews-admin-design.md`

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at the **project root** `docs/`, not `web-app/docs/`.
- Lint is `bundle exec standardrb`. **Never** `bin/rubocop`. **Never** brakeman.
- **Never run a destructive DB command against development.** No `create_fixtures`, no `db:reset`,
  no bulk `delete_all`. To read a fixture, read the YAML. The books dev data takes hours to rebuild.
- Ruby 3-style Rails 8 enum syntax, `Books::`/`Music::`/`Games::` namespacing, tests mirror the
  namespace.
- **daisyUI 5 / Tailwind 4.** These ten classes were removed and fail silently:
  `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`,
  `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`.
  `test/lint/daisyui_v4_classes_test.rb` fails the build on any occurrence; its allowlist is empty
  and stays empty.
- Controller tests assert **behavior** — status codes, params, query counts, generated URLs — never
  HTML, CSS or copy.
- Scoped test runs: `bin/rails test test/controllers/admin/` etc. Full gate before done:
  `bin/rails test` **and** `bundle exec standardrb`.

## File Structure

| File | Responsibility |
| --- | --- |
| `app/controllers/admin/reviews_base_controller.rb` | *(modify)* add `show`; add `review_detail_path` / `reviewable_label` seams; expose the three path/label seams as `helper_method` |
| `app/controllers/admin/books/reviews_controller.rb` | *(modify)* fill in the two new seams |
| `app/views/admin/reviews_base/index.html.erb` | *(move from `admin/books/reviews/`)* domain-agnostic list |
| `app/views/admin/reviews_base/show.html.erb` | *(create)* domain-agnostic detail page |
| `app/lib/reviews/registry.rb` | *(modify)* add `domain_for_type` and `admin_path_for` — it is already the single source of truth for type→domain |
| `app/helpers/admin/reviews_helper.rb` | *(create)* build the cross-host absolute URL for a review |
| `app/controllers/admin/users_controller.rb` | *(modify)* load the user's 10 newest reviews + count |
| `app/views/admin/users/show.html.erb` | *(modify)* Reviews card + Related Data count |
| `config/routes.rb` | *(modify)* books admin `resources :reviews` gains `:show` |
| `test/controllers/admin/books/reviews_controller_test.rb` | *(modify)* `show` coverage |
| `test/controllers/admin/users_controller_test.rb` | *(modify)* reviews card, N+1 pin, cross-host URL |
| `test/helpers/admin/reviews_helper_test.rb` | *(create)* URL construction in isolation |
| `e2e/tests/books/admin/reviews.spec.ts` | *(create)* browse → open → delete |

---

### Task 1: Shared list view and per-domain seams

Pure refactor. The existing `test/controllers/admin/books/reviews_controller_test.rb` is a thorough
safety net — it asserts on `admin_books_review_path` form actions, the written filter, and search —
so it must stay green throughout with no edits.

**Files:**
- Modify: `app/controllers/admin/reviews_base_controller.rb`
- Modify: `app/controllers/admin/books/reviews_controller.rb`
- Move: `app/views/admin/books/reviews/index.html.erb` → `app/views/admin/reviews_base/index.html.erb`
- Test: `test/controllers/admin/books/reviews_controller_test.rb`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: three controller `helper_method`s available to every reviews template —
  `reviews_index_path` → `String`, `review_detail_path(review)` → `String`,
  `reviewable_label` → `String`. Task 2's `show.html.erb` uses all three.

- [ ] **Step 1: Write the failing test**

Append inside `module Admin / module Books / class ReviewsControllerTest`, after the last test:

```ruby
      # The entire multi-domain design rests on Rails resolving this controller's
      # templates from the BASE controller's prefix, so one shared view serves
      # every domain subclass. That prefix is derived from the base controller's
      # class name -- rename Admin::ReviewsBaseController and every reviews view
      # 500s with "missing template", far from the rename that caused it.
      test "view lookup falls back to the shared reviews_base prefix" do
        assert_includes Admin::Books::ReviewsController._prefixes, "admin/reviews_base"
      end
```

- [ ] **Step 2: Run it and watch it pass, then prove it is not vacuous**

```bash
bin/rails test test/controllers/admin/books/reviews_controller_test.rb -n "/reviews_base prefix/"
```

Expected: PASS. This one is a characterization test — it passes before the change because the
prefix already exists; it exists to fail if the base controller is ever renamed. Confirm it is not
vacuous by temporarily changing the asserted string to `"admin/nope"` and re-running: expect FAIL.
Change it back.

- [ ] **Step 3: Move the template**

```bash
mkdir -p app/views/admin/reviews_base
git mv app/views/admin/books/reviews/index.html.erb app/views/admin/reviews_base/index.html.erb
rmdir app/views/admin/books/reviews
```

- [ ] **Step 4: Run the tests and watch them still pass**

```bash
bin/rails test test/controllers/admin/books/reviews_controller_test.rb
```

Expected: PASS. Rails finds the template at the base prefix. If this fails with "missing template",
stop — the prefix assumption is wrong and the rest of the plan needs revisiting.

- [ ] **Step 5: Add the two new seams to the base controller**

In `app/controllers/admin/reviews_base_controller.rb`, extend the existing `helper_method` line to
expose the path and label seams to the view:

```ruby
  helper_method :filter_params, :reviews_index_path, :review_detail_path, :reviewable_label
```

The existing `reviews_index_path` takes no argument, but the view's Written/All toggle links need to
pass filter params through it. Change its base-class signature:

```ruby
  def reviews_index_path(params = {})
    raise NotImplementedError, "Subclass must implement reviews_index_path"
  end
```

Then, in the `private` section beside it, add:

```ruby
  # review_detail_path, not review_path: the global route helper `review_path`
  # already names the public PATCH /reviews/:id endpoint (routes.rb), so a
  # helper_method of that name would shadow it for every admin view. Same trap,
  # and same reasoning, as reviews_index_path vs. the public reviews_path above.
  def review_detail_path(review)
    raise NotImplementedError, "Subclass must implement review_detail_path"
  end

  # Titles one column in one admin table. Deliberately a controller string and
  # not a method on the reviewable model: what a books admin calls this column
  # is not a property of a book.
  def reviewable_label
    raise NotImplementedError, "Subclass must implement reviewable_label"
  end
```

- [ ] **Step 6: Fill the seams in the books subclass**

In `app/controllers/admin/books/reviews_controller.rb`, replace the existing `reviews_index_path` and
add the two new seams:

```ruby
  def reviews_index_path(params = {}) = admin_books_reviews_path(params)

  def review_detail_path(review) = admin_books_review_path(review)

  def reviewable_label = "Book"
```

`destroy`'s existing `redirect_to reviews_index_path` still works — the default argument covers it.

- [ ] **Step 7: Point the moved view at the seams**

In `app/views/admin/reviews_base/index.html.erb`, replace every hardcoded books path and the column
header. Four edits:

Replace the two toggle links:

```erb
    <%= link_to "Written", reviews_index_path(filter_params.except("written")),
          class: "btn btn-sm #{"btn-active" if @written_only}" %>
    <%= link_to "All", reviews_index_path(filter_params(written: "all")),
          class: "btn btn-sm #{"btn-active" unless @written_only}" %>
```

`reviews_index_path` currently takes no arguments — change its books implementation to forward them:

```ruby
  def reviews_index_path(params = {}) = admin_books_reviews_path(params)
```

Replace the search form's `url:`:

```erb
<%= form_with url: reviews_index_path, method: :get, class: "flex gap-2 mb-4" do |form| %>
```

Replace the placeholder and column header, so neither says "book":

```erb
  <%= form.search_field :q, value: @search_query, placeholder: "Reviewer or #{reviewable_label.downcase}",
        class: "input w-72", "aria-label": "Search reviews" %>
```

```erb
      <tr><th>Reviewer</th><th><%= reviewable_label %></th><th>Rating</th><th>Review</th><th>Date</th><th></th></tr>
```

Replace the delete button's path:

```erb
              <%= button_to "Delete", review_detail_path(review), method: :delete,
                    class: "btn btn-sm btn-error",
                    form: {data: {turbo_confirm: "Delete this review permanently?"}} %>
```

- [ ] **Step 8: Run the tests**

```bash
bin/rails test test/controllers/admin/books/reviews_controller_test.rb
```

Expected: PASS, all of them. The existing `assert_select "form[action=?]", admin_books_review_path(...)`
assertions are what prove the seams produce the same URLs as before.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/controllers/admin/ && \
git add app/controllers/admin app/views/admin test/controllers/admin && \
git commit -m "Move the admin reviews list to a shared, domain-agnostic view

Rails resolves Admin::Books::ReviewsController's templates through the base
controller's own prefix (admin/reviews_base), so one template now serves every
future domain subclass. The three books-specific bits -- index path, member
path and column label -- become controller seams.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The review detail page

**Files:**
- Modify: `config/routes.rb:435`
- Modify: `app/controllers/admin/reviews_base_controller.rb`
- Create: `app/views/admin/reviews_base/show.html.erb`
- Modify: `app/views/admin/reviews_base/index.html.erb`
- Test: `test/controllers/admin/books/reviews_controller_test.rb`

**Interfaces:**
- Consumes: `reviews_index_path`, `review_detail_path(review)`, `reviewable_label` from Task 1.
- Produces: `GET /admin/reviews/:id` on the books host, named `admin_books_review_path(review)` —
  the same helper the existing `DELETE` already uses, since both are the `:show`/`:destroy` member
  route. Task 3 links to this URL from another host.

- [ ] **Step 1: Write the failing tests**

Append inside `class ReviewsControllerTest`:

```ruby
      test "show renders a books review for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_review_path(@review)
        assert_response :success
      end

      test "show allows a books domain viewer" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_review_path(@review)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_review_path(@review)
        assert_redirected_to books_root_path
      end

      # Mirrors the destroy scoping test below it. authenticate_admin! proves
      # access to the domain this controller is mounted under and nothing about
      # which reviewable a given id belongs to, so without reviewable_type
      # scoping a books-only user could READ a music review by guessing an id.
      test "show 404s for a review whose reviewable is outside this domain" do
        sign_in_as(@admin_user, stub_auth: true)
        other_domain_review = @regular_user.reviews.create!(
          reviewable: music_albums(:dark_side_of_the_moon), rating: 3
        )

        get admin_books_review_path(other_domain_review)
        assert_response :not_found
      end

      # A rating-only review has a nil body. BodySanitizer.render must not be
      # handed nil and the page must still render -- roughly 7 of every 8
      # reviews in production carry no text at all.
      test "show renders a review with no body" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_review_path(reviews(:admin_user_war_and_peace))
        assert_response :success
      end
```

- [ ] **Step 2: Run them and verify they fail**

```bash
bin/rails test test/controllers/admin/books/reviews_controller_test.rb -n "/show/"
```

Expected: FAIL — `ActionController::UrlGenerationError` or `RoutingError`, because the `show` route
does not exist yet.

- [ ] **Step 3: Add the route**

In `config/routes.rb` line 435, inside the books admin namespace:

```ruby
      resources :reviews, only: [:index, :show, :destroy]
```

- [ ] **Step 4: Add the `show` action**

In `app/controllers/admin/reviews_base_controller.rb`, directly above `def destroy`:

```ruby
  # Scoped to this controller's reviewable_type for the same reason destroy is,
  # one action below: require_domain_write! is absent here on purpose because a
  # read-only domain viewer may read a review, but authenticate_admin! only ever
  # proves access to the domain this controller is MOUNTED under -- it says
  # nothing about which reviewable the id in the URL actually belongs to.
  def show
    @review = Review.where(reviewable_type: reviewable_class.name)
      .includes(:user)
      .preload(reviewable: reviewable_includes)
      .find(params[:id])
  end
```

- [ ] **Step 5: Create the detail view**

Create `app/views/admin/reviews_base/show.html.erb`:

```erb
<% content_for :title, "Review ##{@review.id}" %>

<div class="flex items-center justify-between mb-6">
  <%= link_to "← Reviews", reviews_index_path, class: "btn btn-ghost btn-sm" %>
  <%= button_to "Delete", review_detail_path(@review), method: :delete,
        class: "btn btn-sm btn-error",
        form: {data: {turbo_confirm: "Delete this review permanently?"}} %>
</div>

<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex flex-wrap items-center gap-3">
      <%= render Reviews::StarsComponent.new(rating: @review.rating, size: "size-5",
            label: "Rated #{@review.rating} out of 5 stars") %>
      <span class="tabular-nums text-base-content/70"><%= @review.rating %> / 5</span>
    </div>

    <% if @review.title.present? %>
      <h1 class="text-2xl font-bold mt-2 [overflow-wrap:anywhere]"><%= @review.title %></h1>
    <% end %>

    <dl class="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-4 text-sm">
      <div>
        <dt class="font-semibold">Reviewer</dt>
        <dd class="[overflow-wrap:anywhere]">
          <%= link_to @review.user.email, admin_user_path(@review.user), class: "link" %>
        </dd>
      </div>
      <div>
        <dt class="font-semibold"><%= reviewable_label %></dt>
        <dd class="[overflow-wrap:anywhere]">
          <% reviewable_path = Admin::DomainRouting.path_for(@review.reviewable) %>
          <% if reviewable_path %>
            <%= link_to @review.reviewable.title, reviewable_path, class: "link" %>
          <% else %>
            <%= @review.reviewable.title %>
          <% end %>
        </dd>
      </div>
      <div>
        <dt class="font-semibold">Written</dt>
        <dd><%= @review.created_at.strftime("%B %d, %Y at %I:%M %p") %></dd>
      </div>
      <div>
        <dt class="font-semibold">Last updated</dt>
        <dd><%= @review.updated_at.strftime("%B %d, %Y at %I:%M %p") %></dd>
      </div>
    </dl>

    <% body_html = Services::Reviews::BodySanitizer.render(@review.body) %>
    <% if body_html %>
      <%# data-controller is load-bearing, not decorative: books/reviews.css blurs
          .review-spoiler unconditionally, and only Reviews__SpoilerController adds
          the --revealed class. Drop this attribute and spoiler passages render
          permanently unreadable with no way to unblur them. The controller is
          registered in the shared app/javascript/controllers/index.js, which the
          admin layout already loads -- no bundling change needed. %>
      <div class="review-body mt-6 max-w-[68ch] leading-relaxed [overflow-wrap:anywhere]"
           data-controller="reviews--spoiler"
           data-testid="admin-review-body"><%= body_html %></div>
    <% else %>
      <p class="mt-6 text-base-content/60 italic">Rating only — no written review.</p>
    <% end %>
  </div>
</div>
```

- [ ] **Step 6: Link the list rows to the detail page**

In `app/views/admin/reviews_base/index.html.erb`, replace the review-text cell:

```erb
            <td class="max-w-md truncate [overflow-wrap:anywhere]">
              <%= link_to review.title.presence || review.body&.truncate(80) || "Rating only",
                    review_detail_path(review), class: "link" %>
            </td>
```

- [ ] **Step 7: Run the tests and verify they pass**

```bash
bin/rails test test/controllers/admin/books/reviews_controller_test.rb
```

Expected: PASS, all of them — the pre-existing list tests included, since `review_detail_path` is
the same URL the delete form already posts to.

- [ ] **Step 8: Run the daisyUI guard and lint**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb && bundle exec standardrb app/ config/routes.rb
```

Expected: PASS. If the guard fails, remove the offending class — never add an allowlist entry.

- [ ] **Step 9: Commit**

```bash
git add app config/routes.rb test && \
git commit -m "Add an admin detail page for a single review

The list truncates a review at 80 characters, so there was nowhere to read one
before deciding whether to delete it. Scoped to the controller's reviewable_type
exactly as destroy is; spoilers blur and click-to-reveal as on the public page.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: A user's reviews on the admin user page

**Files:**
- Modify: `app/lib/reviews/registry.rb`
- Create: `app/helpers/admin/reviews_helper.rb`
- Create: `test/helpers/admin/reviews_helper_test.rb`
- Modify: `app/controllers/admin/users_controller.rb`
- Modify: `app/views/admin/users/show.html.erb`
- Test: `test/controllers/admin/users_controller_test.rb`

**Interfaces:**
- Consumes: `GET /admin/reviews/:id` from Task 2, generated as `admin_books_review_path(review)`.
- Produces: `Reviews::Registry.domain_for_type(type)` → `String` or `nil`;
  `Reviews::Registry.admin_path_for(review)` → `String` or `nil`;
  `Admin::ReviewsHelper#admin_review_url(review)` → absolute `String` or `nil`.

**Why this task is not just a partial:** `resources :users` sits in the *global* `namespace :admin`
(`config/routes.rb:726`) with no `DomainConstraint`, so `/admin/users/482` answers on all four
hostnames. `/admin/reviews` lives inside `constraints DomainConstraint.new(config.domains[:books])`
(line 378) and routes on the books host only. A path-only link therefore 404s whenever an admin is
browsing on the music or games host — and `Admin::UsersControllerTest` already runs with
`host! Rails.application.config.domains[:music]`, so this is the default case, not the edge case.

- [ ] **Step 1: Write the failing registry and helper tests**

Create `test/helpers/admin/reviews_helper_test.rb`:

```ruby
require "test_helper"

module Admin
  class ReviewsHelperTest < ActionView::TestCase
    include Admin::ReviewsHelper

    setup do
      @review = reviews(:regular_user_war_and_peace)
    end

    # The admin user page answers on every hostname; /admin/reviews answers only
    # on the books host. A path-only link is therefore broken for any admin who
    # happens to be browsing on music or games, and is invisible in development
    # where every host resolves to localhost.
    test "admin_review_url carries the books host" do
      books_host = Rails.application.config.domains[:books]
      assert_includes admin_review_url(@review), books_host
      assert_match %r{\Ahttps?://}, admin_review_url(@review)
      assert_includes admin_review_url(@review), "/admin/reviews/#{@review.id}"
    end

    # A user page must not 500 because one of its reviews points at a class no
    # domain claims. The card renders such a row unlinked instead.
    test "admin_review_url returns nil for an unregistered reviewable type" do
      orphan = Review.new(reviewable_type: "Nope::Thing", reviewable_id: 1, rating: 3)
      assert_nil admin_review_url(orphan)
    end

    test "registry maps a reviewable type to its domain" do
      assert_equal "books", ::Reviews::Registry.domain_for_type("Books::Book")
      assert_nil ::Reviews::Registry.domain_for_type("Nope::Thing")
    end
  end
end
```

- [ ] **Step 2: Run them and verify they fail**

```bash
bin/rails test test/helpers/admin/reviews_helper_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Admin::ReviewsHelper`.

- [ ] **Step 3: Extend the registry**

In `app/lib/reviews/registry.rb`, below the existing `DOMAIN_TYPES` constant, add the path map and
the two lookups:

```ruby
    # Where a review of each reviewable type is administered. Lives here rather
    # than in Admin::DomainRouting::ENTITIES because those lambdas are keyed by,
    # and receive, the ENTITY -- a Books::Book -- while this one is keyed by the
    # entity's type but receives the REVIEW. This class is already the single
    # source of truth for type-to-domain, so the routing belongs beside it.
    ADMIN_PATHS = {
      "Books::Book" => ->(review) { Rails.application.routes.url_helpers.admin_books_review_path(review) }
    }.freeze

    def self.domain_for_type(type)
      DOMAIN_TYPES.find { |_domain, types| types.include?(type.to_s) }&.first
    end

    def self.admin_path_for(review)
      ADMIN_PATHS[review.reviewable_type]&.call(review)
    end
```

- [ ] **Step 4: Create the helper**

Create `app/helpers/admin/reviews_helper.rb`:

```ruby
module Admin
  module ReviewsHelper
    # An absolute URL, not a path, and deliberately so. /admin/users/:id is in the
    # global admin namespace with no DomainConstraint, so it answers on all four
    # hostnames; /admin/reviews is inside the books DomainConstraint and routes on
    # the books host alone. A path-only link is dead for any admin browsing on
    # music or games.
    #
    # Scheme and port come from the current request rather than being hardcoded:
    # development serves these hostnames over http on port 3000, production over
    # https on 443. request.port_string is "" on a default port.
    #
    # Returns nil for a reviewable type no domain claims, so the caller can render
    # the row unlinked. A user page must not 500 over one stray review.
    def admin_review_url(review)
      path = ::Reviews::Registry.admin_path_for(review)
      return nil if path.nil?

      domain = ::Reviews::Registry.domain_for_type(review.reviewable_type)
      return nil if domain.nil?

      host = Rails.application.config.domains[domain.to_sym]
      return nil if host.blank?

      "#{request.protocol}#{host}#{request.port_string}#{path}"
    end
  end
end
```

- [ ] **Step 5: Run the helper tests and verify they pass**

```bash
bin/rails test test/helpers/admin/reviews_helper_test.rb
```

Expected: PASS, 3 runs.

- [ ] **Step 6: Write the failing controller tests**

Append to `test/controllers/admin/users_controller_test.rb`, inside the class:

```ruby
  test "show renders for a user with reviews" do
    assert_operator @regular_user.reviews.count, :>, 0
    get admin_user_url(@regular_user)
    assert_response :success
  end

  test "show renders for a user with no reviews" do
    user = users(:editor_user)
    user.reviews.destroy_all
    get admin_user_url(user)
    assert_response :success
  end

  # The setup block puts this request on the MUSIC host, which is exactly the
  # case a path-only link breaks in: /admin/reviews routes on the books host
  # only. Asserts on the generated URL, not on markup -- this is a routing
  # decision, not presentation, and it is invisible in development where every
  # host resolves to localhost.
  test "review links on the user page carry the books host" do
    get admin_user_url(@regular_user)
    assert_response :success
    assert_includes response.body, Rails.application.config.domains[:books]
  end

  # Not a fixed query count -- that would break every time an unrelated panel is
  # added to this page. Instead: adding four more reviews must not add any
  # queries. Drop includes(:reviewable) from the controller and this fails by
  # exactly four.
  test "the reviews card does not issue a query per review" do
    baseline = sql_query_count { get admin_user_url(@regular_user) }

    [:combo_steinbeck, :got, :clash, :of_mice_and_men].each do |slug|
      @regular_user.reviews.create!(reviewable: books_books(slug), rating: 3)
    end

    grown = sql_query_count { get admin_user_url(@regular_user) }

    assert_equal baseline, grown,
      "the reviews card N+1s: 4 extra reviews cost #{grown - baseline} extra queries"
  end

  private

  def sql_query_count
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless payload[:name].in?(["SCHEMA", "TRANSACTION"])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
```

- [ ] **Step 7: Run them and verify they fail**

```bash
bin/rails test test/controllers/admin/users_controller_test.rb -n "/review/"
```

Expected: the host test FAILS (the books host appears nowhere in the page yet). The N+1 test passes
vacuously for now — no reviews are rendered, so no queries scale. It becomes meaningful in Step 8;
verify it after implementing by temporarily deleting `includes(:reviewable)` and watching it fail by
four.

- [ ] **Step 8: Load the reviews in the controller**

In `app/controllers/admin/users_controller.rb`, replace the empty `show`:

```ruby
  def show
    # includes(:reviewable) is load-bearing: the card renders reviewable.title in
    # a loop, which is a query per row without it. Pinned by a test.
    @reviews = @user.reviews.recent.includes(:reviewable).limit(10)
    @reviews_count = @user.reviews.count
  end
```

`Review.recent` is the existing model scope (`order(created_at: :desc, id: :desc)`) and is covered
by the `user_id, created_at` index.

- [ ] **Step 9: Add the Reviews card to the view**

In `app/views/admin/users/show.html.erb`, insert this card in the left column
(`lg:col-span-2`), directly after the closing `</div>` of the "Activity" card and before the Billing
`<% if @user.stripe_customer_id.present? %>` block:

```erb
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Reviews <span class="badge badge-lg"><%= @reviews_count %></span></h2>
          <% if @reviews.any? %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr><th>Item</th><th>Rating</th><th>Review</th><th>Date</th></tr>
                </thead>
                <tbody>
                  <% @reviews.each do |review| %>
                    <% url = admin_review_url(review) %>
                    <tr>
                      <td class="[overflow-wrap:anywhere]">
                        <% if url %>
                          <%= link_to review.reviewable.title, url, class: "link" %>
                        <% else %>
                          <%= review.reviewable.title %>
                        <% end %>
                      </td>
                      <td class="tabular-nums"><%= review.rating %></td>
                      <td class="max-w-xs truncate [overflow-wrap:anywhere]">
                        <%= review.title.presence || review.body&.truncate(60) || "Rating only" %>
                      </td>
                      <td class="whitespace-nowrap"><%= review.created_at.to_date.iso8601 %></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
            <% if @reviews_count > @reviews.size %>
              <p class="text-sm text-base-content/60 mt-2">
                Showing <%= @reviews.size %> of <%= @reviews_count %>, newest first.
              </p>
            <% end %>
          <% else %>
            <p class="text-base-content/70">No reviews.</p>
          <% end %>
        </div>
      </div>
```

Then add a Reviews row to the Related Data panel in the right column, directly above the
`Ranking Configurations` row:

```erb
            <div class="flex justify-between items-center">
              <span>Reviews</span>
              <span class="badge badge-lg"><%= @reviews_count %></span>
            </div>
```

- [ ] **Step 10: Run the tests and verify they pass**

```bash
bin/rails test test/controllers/admin/users_controller_test.rb
```

Expected: PASS, all of them.

- [ ] **Step 11: Prove the N+1 test is not vacuous**

Temporarily delete `.includes(:reviewable)` from `Admin::UsersController#show`, then:

```bash
bin/rails test test/controllers/admin/users_controller_test.rb -n "/does not issue a query per review/"
```

Expected: FAIL, reporting 4 extra queries. Restore `.includes(:reviewable)` and re-run: PASS. Do not
skip this step — a preload assertion that never fails is worse than none, because it reads as
protection.

- [ ] **Step 12: Lint, run the daisyUI guard, and commit**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb && \
bundle exec standardrb app/ test/ && \
git add app test && \
git commit -m "Show a user's recent reviews on the admin user page

The 10 newest, with a count beside the other Related Data totals. Links are
absolute URLs carrying the books host: /admin/users/:id answers on all four
hostnames while /admin/reviews routes on the books host alone, so a path-only
link is dead for an admin browsing on music or games.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Playwright E2E

**Files:**
- Create: `e2e/tests/books/admin/reviews.spec.ts`

**Interfaces:**
- Consumes: `/admin/reviews`, `/admin/reviews/:id` from Tasks 1–2; `data-testid="admin-review-body"`
  from Task 2's view.
- Produces: nothing consumed downstream.

**Prerequisites:** the dev server must be running and `e2e/.env` present. If every admin spec times
out on the public homepage, the e2e account lost its role — fix with `bin/rails e2e:admin`.

**Scratch-data contract — read before writing this spec.** Deleting is irreversible and the dev
books data cannot be rebuilt in less than hours, so this spec must never delete a pre-existing
review. It creates its own through the normal public write flow on `/book/nightmare-abbey` — the
one slug `lib/tasks/e2e.rake` deliberately excludes from the `/my/reviews` seed and that
`reviews-write.spec.ts` already uses as scratch. `playwright.config.ts` runs `workers: 1` and
`fullyParallel: false`, so specs never interleave. The `afterEach` is a safety net for a mid-test
crash: without it a failed run leaves a stray review behind and
`e2e/tests/books/account/my-reviews.spec.ts`'s exact `SEEDED_COUNT = 30` assertion then fails on
every later run, for a reason nowhere near where it broke. Clean up by **identity**, never by
counting rows.

- [ ] **Step 1: Write the spec**

Create `e2e/tests/books/admin/reviews.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

// nightmare-abbey is the scratch book: lib/tasks/e2e.rake excludes it from the
// /my/reviews seed precisely so specs can create and destroy reviews on it.
const SCRATCH_BOOK = "/book/nightmare-abbey";

test.describe("Books admin — reviews", () => {
  test("the list renders newest-first and links into a review", async ({ page }) => {
    await page.goto("/admin/reviews");
    await expect(page.getByRole("heading", { name: "Reviews", level: 1 })).toBeVisible();

    const firstReviewLink = page.locator("tbody tr").first().getByRole("link").first();
    await firstReviewLink.click();

    await expect(page).toHaveURL(/\/admin\/reviews\/\d+$/);
    await expect(page.getByRole("link", { name: "← Reviews" })).toBeVisible();
  });

  test.describe("deleting a review", () => {
    // Safety net only -- the happy path deletes through the admin UI itself.
    // A mid-test failure would otherwise strand a review that breaks
    // my-reviews.spec.ts's exact seeded-count assertion on every later run.
    test.afterEach(async ({ page }) => {
      await page.unrouteAll();
      await page.goto("/my/reviews");
      const scratchRow = page.locator("li", { has: page.locator(`a[href="${SCRATCH_BOOK}"]`) });

      while ((await scratchRow.count()) > 0) {
        page.once("dialog", (d) => d.accept());
        await scratchRow.first().getByTestId("delete-review").click();
        await expect(page.locator(`a[href="${SCRATCH_BOOK}"]`)).toHaveCount(0);
      }
    });

    test("an admin reads the full review, then deletes it", async ({ page }) => {
      // Create the review to destroy, through the normal public write flow.
      const body = `E2E admin scratch review ${Date.now()}`;
      await page.goto(SCRATCH_BOOK);
      await page.getByTestId("review-widget-label").click();
      await expect(page.locator("#review_modal")).toBeVisible();
      await page.getByTestId("review-star-button").nth(2).click();
      await page.locator("#review_modal textarea").fill(body);
      await page.getByRole("button", { name: "Save" }).click();
      await expect(page.locator("#review_modal")).not.toBeVisible();

      // Find it in the admin list by its own text, never by position -- the list
      // is newest-first but other specs write reviews too.
      await page.goto("/admin/reviews?q=nightmare");
      const row = page.locator("tbody tr", { hasText: "E2E admin scratch review" }).first();
      await expect(row).toBeVisible();
      await row.getByRole("link").first().click();

      // The detail page shows the whole body, which the list truncates at 80 chars.
      await expect(page).toHaveURL(/\/admin\/reviews\/\d+$/);
      await expect(page.getByTestId("admin-review-body")).toContainText(body);

      page.once("dialog", (d) => {
        expect(d.message()).toContain("permanently");
        d.accept();
      });
      await page.getByRole("button", { name: "Delete" }).click();

      await expect(page).toHaveURL(/\/admin\/reviews$/);
      await expect(
        page.locator("tbody tr", { hasText: "E2E admin scratch review" })
      ).toHaveCount(0);
    });
  });
});
```

- [ ] **Step 2: Run the spec**

Start the dev server first (`bin/dev` needs a TTY — in a non-interactive shell use
`yarn build:all` then `bin/rails server`, and check what is already on port 3000). Then:

```bash
yarn test:e2e e2e/tests/books/admin/reviews.spec.ts
```

Expected: PASS, 2 tests. If the review-modal selectors have drifted, read
`e2e/tests/books/account/reviews-write.spec.ts` — it drives the same widget and is the authority on
those testids.

- [ ] **Step 3: Confirm no scratch data was left behind**

```bash
yarn test:e2e e2e/tests/books/account/my-reviews.spec.ts
```

Expected: PASS. This is the canary — its exact `SEEDED_COUNT = 30` assertion fails if the new spec
stranded a review.

- [ ] **Step 4: Run the full gate**

```bash
bin/rails test && bundle exec standardrb
```

Expected: both clean. CI runs exactly these two and blocks the merge on either.

- [ ] **Step 5: Commit**

```bash
git add e2e && \
git commit -m "Add E2E coverage for the admin reviews list and detail page

Creates its own scratch review on nightmare-abbey rather than touching the dev
corpus, and cleans up by identity in an afterEach so a mid-test crash cannot
strand a row that breaks my-reviews.spec.ts's exact seeded-count assertion.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
| --- | --- |
| Increment 1 — move view to `admin/reviews_base/` | Task 1 Steps 3–4 |
| Increment 1 — three per-domain seams | Task 1 Steps 5–7 |
| Increment 1 — delete the books-specific directory | Task 1 Step 3 (`rmdir`) |
| Increment 2 — `show` action, `reviewable_type`-scoped | Task 2 Step 4 |
| Increment 2 — route gains `:show` | Task 2 Step 3 |
| Increment 2 — detail view, reviewer/reviewable links, exact timestamps | Task 2 Step 5 |
| Increment 2 — spoiler controller attached | Task 2 Step 5 (`data-controller`) |
| Increment 2 — list row links to detail | Task 2 Step 6 |
| Increment 3 — controller loads 10 newest + count | Task 3 Step 8 |
| Increment 3 — Reviews card + Related Data count | Task 3 Step 9 |
| Increment 3 — cross-host absolute URLs | Task 3 Steps 3–4 |
| Increment 3 — unmapped type renders unlinked, no 500 | Task 3 Steps 1, 4, 9 |
| Testing — `show` 200 / 404 / viewer | Task 2 Step 1 |
| Testing — N+1 pin | Task 3 Steps 6, 11 |
| Testing — absolute-URL assertion | Task 3 Step 6 |
| Testing — Playwright both flows | Task 4 Step 1 |
| Gates — `bin/rails test`, standardrb, daisyUI guard | Tasks 2, 3, 4 |

No spec requirement is unimplemented.

**Type consistency**

`reviews_index_path` is used with an argument in Task 1 Step 7 and without one in Task 2 Step 5 and
in the existing `destroy` redirect, so both the base class (Task 1 Step 5) and the books subclass
(Task 1 Step 6) declare it as `reviews_index_path(params = {})`.

`review_detail_path(review)` is spelled identically in Task 1 (definition), Task 1 Step 7 (delete
button), Task 2 Step 5 (detail page delete), and Task 2 Step 6 (list link).
`Reviews::Registry.domain_for_type` returns a **String** (`"books"`) — the helper calls `.to_sym`
before indexing `config.domains`, whose keys are symbols. `Reviews::Registry.admin_path_for` takes a
**Review**, not a reviewable.

**Placeholder scan:** none. Every code step carries the literal code.
