# Books Saved Searches — Increment 6: The Write Surface

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a signed-in user create, edit and delete a saved search, so the feature stops being a read-only view of 4,391 migrated rows.

**Architecture:** Five controller actions on the existing `SavedSearchesController`, six write routes declared with `searches/new` ahead of `searches/:id`, and one shared `new`/`edit` form whose body is a per-domain partial. Form params pass through a new `Books::SavedSearchCriteriaParams` normalizer before being stored, so newly created rows carry a clean criteria shape while the readers stay tolerant of the migrated one. Categories get a JSON endpoint over the shared `CategorySearchQuery` plus a Stimulus chips picker; languages and countries are plain multi-selects with no round trip.

**Tech Stack:** Rails 8, ViewComponent, Stimulus, DaisyUI 5, Minitest + fixtures, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-08-books-saved-searches-design.md`. Read §8 (routes), §9 (UI), §6 (criteria readers) and §13 (landmines) before starting.

## Global Constraints

- **Run all Rails/yarn commands from `web-app/`.** `docs/` is at the project root.
- Ruby lint is `bundle exec standardrb`, NEVER `bin/rubocop`. Do NOT run `bin/brakeman`.
- Every commit must leave `bin/rails test` green. Run the full suite once before committing, not after every edit. CI eager-loads (`CI=true`), which is stricter.
- Never run destructive database commands against development. Never `ActiveRecord::FixtureSet.create_fixtures` — it TRUNCATES every table it names.
- Root-anchor constants inside nested namespaces: `::Books::Category`, not `Books::Category`, when inside a `Books::` scope.
- Do not touch anything to do with the movies domain.
- **Do NOT push and do NOT open a pull request.** That is the branch owner's decision.

### Decisions this plan locks in

**Normalize criteria on write; keep the readers tolerant.** `Books::SavedSearchCriteria`'s header comment says normalization "was the alternative and is worse". That judgement was about using normalization *as a substitute* for tolerant readers — which would still be wrong, because 4,727 already-stored rows will never be normalized. This plan does both: readers stay exactly as they are, and the write path additionally emits a clean shape. The reason is `#unparseable?`. A form that posts `first_year_published_gt: ""` stores a present-but-blank value; `blank_raw?` currently rescues that specific case, but a form posting `included_category_ids: ["", "abc"]` would store a present value parsing to nothing, and the query layer would correctly match nothing — a search that silently returns zero results with no visible cause. Dropping blanks at the boundary makes that unreachable from the form. **Do not weaken any reader on the grounds that the writer now normalizes.**

**`ranked` is stored as the string `"true"` / `"false"`, or the key is dropped.** This matches the migrated corpus exactly. Storing a real boolean would work — the reader accepts both — but would leave two shapes in one column for no gain. Never store `""`.

**Private and other-user searches 404, never 403** on edit/update/destroy, mirroring `show`. Scope through `owned_by(current_user)` so `RecordNotFound` is what happens; Pundit's rescue redirects, which would confirm the id exists.

**Out of scope, deliberately:** a "save this search" button on the books browse/filter page. It is the most natural way to create one and it is not in the spec; adding it means deciding how filter-modal state maps onto criteria, which is its own design question. Users create searches from the form in this increment.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `app/lib/books/saved_search_criteria_params.rb` | Form params → clean criteria hash |
| `test/lib/books/saved_search_criteria_params_test.rb` | Its unit tests |
| `app/controllers/saved_searches/categories_controller.rb` | JSON category search for the picker |
| `test/controllers/saved_searches/categories_controller_test.rb` | Its tests |
| `app/views/saved_searches/new.html.erb` | Renders the shared form |
| `app/views/saved_searches/edit.html.erb` | Renders the shared form |
| `app/views/saved_searches/_form.html.erb` | Shared shell: name, description, public, submit |
| `app/views/saved_searches/books/_criteria_fields.html.erb` | The books criteria body (the domain seam) |
| `app/javascript/controllers/saved_search_picker_controller.js` | Chips picker over the JSON endpoint |
| `e2e/tests/books/saved_searches_write.spec.ts` | Playwright write-flow coverage |

**Modify:**

| File | Change |
|---|---|
| `config/routes.rb:306-337` | Six write routes + the picker endpoint, `new` before `:id` |
| `app/controllers/saved_searches_controller.rb` | `new`/`create`/`edit`/`update`/`destroy`, strong params |
| `app/models/saved_search.rb` | `self.category_class` hook |
| `app/models/books/saved_search.rb` | `self.category_class` → `::Books::Category` |
| `app/views/saved_searches/index.html.erb` | "New Saved Search" button, empty-state call to action |
| `app/views/saved_searches/show.html.erb` | Edit + Delete for the owner |
| `app/javascript/controllers/index.js` | Register `saved-search-picker` |
| `test/controllers/saved_searches_controller_test.rb` | Write-action tests |

---

## Task 1: DROPPED before execution — its premise was false

This task was going to add an image fixture to a books book, on the grounds that no fixture book has one and every books grid's `assert_queries_count` guard is therefore blind to the `primary_image -> file_attachment -> blob` preload.

The first half is true and the second is not. `test/controllers/books/lists_controller_test.rb:160` builds its covered books' images programmatically — `Image.new(parent:, primary: true)` plus `image.file.attach(io: StringIO.new(...))` — then calls `ActiveRecord::Base.connection.clear_query_cache` and pins `assert_queries_count(12)`. `books/authors_controller_test.rb`, `books/authors/ranked_items_controller_test.rb` and `lib/books/ranked_books_query_test.rb` do the same. The guards exercise the preload; they simply do not use fixtures to do it.

Adding a fixture would therefore buy nothing and cost real risk: an `images.yml` books row shifts counts in unrelated tests, and an ActiveStorage blob fixture references a storage key with no bytes behind it.

**Task numbering is unchanged** so cross-references and `task-brief` extraction stay stable. Execution starts at Task 2.

---

## Task 2: The criteria write normalizer

**Files:**
- Create: `app/lib/books/saved_search_criteria_params.rb`, `test/lib/books/saved_search_criteria_params_test.rb`

**Interfaces:**
- Produces: `Books::SavedSearchCriteriaParams.call(hash) -> Hash` with string keys, ready to assign to `criteria`.
- Consumes: `::Books::Book.book_lengths`, `Books::SavedSearchCriteria::ID_ARRAY_KEYS`.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/books/saved_search_criteria_params_test.rb`:

```ruby
require "test_helper"

module Books
  class SavedSearchCriteriaParamsTest < ActiveSupport::TestCase
    def normalize(hash)
      Books::SavedSearchCriteriaParams.call(hash)
    end

    test "drops unknown keys" do
      assert_equal({}, normalize({"nonsense" => "1", "user_id" => "7"}))
    end

    test "drops blank scalars rather than storing them" do
      result = normalize({"book_type" => "", "first_year_published_gt" => "  ", "max_ranked_position" => nil})

      assert_equal({}, result)
    end

    # A present-but-unparseable value makes the query match nothing (spec §6).
    # Dropping blanks at the boundary keeps the form out of that state.
    test "drops an id array that is entirely blank" do
      assert_equal({}, normalize({"included_category_ids" => ["", nil]}))
    end

    test "casts id arrays to integers and drops unparseable entries" do
      result = normalize({"included_category_ids" => ["12", "", "abc", "34"]})

      assert_equal({"included_category_ids" => [12, 34]}, result)
    end

    test "deduplicates id arrays" do
      result = normalize({"excluded_language_ids" => ["5", "5", "6"]})

      assert_equal({"excluded_language_ids" => [5, 6]}, result)
    end

    test "casts book_type to an integer" do
      assert_equal({"book_type" => 0}, normalize({"book_type" => "0"}))
    end

    test "keeps only book_length values that are real enum values" do
      result = normalize({"book_length" => ["0", "99", "abc", "4"]})

      assert_equal({"book_length" => [0, 4]}, result)
    end

    # Stored as the string "true"/"false" to match all 4,391 migrated rows.
    # "" is the "All Books" option and must drop the key entirely -- storing ""
    # and storing nothing must not be two different shapes in one column.
    test "stores ranked as a string, or not at all" do
      assert_equal({"ranked" => "true"}, normalize({"ranked" => "true"}))
      assert_equal({"ranked" => "false"}, normalize({"ranked" => "false"}))
      assert_equal({}, normalize({"ranked" => ""}))
      assert_equal({}, normalize({"ranked" => "nonsense"}))
    end

    test "stores hide_read only when it is true" do
      assert_equal({"hide_read" => true}, normalize({"hide_read" => "1"}))
      assert_equal({}, normalize({"hide_read" => "0"}))
      assert_equal({}, normalize({"hide_read" => ""}))
    end

    test "stores genre_match_mode only when it is all" do
      assert_equal({"genre_match_mode" => "all"}, normalize({"genre_match_mode" => "all"}))
      assert_equal({}, normalize({"genre_match_mode" => "any"}))
      assert_equal({}, normalize({"genre_match_mode" => ""}))
    end

    test "casts the year bounds to integers" do
      result = normalize({"first_year_published_gt" => "1900", "first_year_published_lt" => "1999"})

      assert_equal({"first_year_published_gt" => 1900, "first_year_published_lt" => 1999}, result)
    end

    test "accepts ActionController::Parameters that have been permitted" do
      params = ActionController::Parameters.new(book_type: "1").permit(:book_type)

      assert_equal({"book_type" => 1}, normalize(params))
    end

    test "returns an empty hash for nil" do
      assert_equal({}, normalize(nil))
    end

    # The whole point: what comes out must read back identically through the
    # reader the query layer uses.
    test "output round-trips through SavedSearchCriteria" do
      criteria = Books::SavedSearchCriteria.new(
        normalize({"ranked" => "true", "book_type" => "2", "included_category_ids" => ["9"]})
      )

      assert_equal :ranked, criteria.ranked
      assert_equal 2, criteria.book_type
      assert_equal [9], criteria.included_category_ids
      assert_not criteria.unparseable?(:book_type)
      assert_not criteria.unparseable?(:included_category_ids)
    end
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/books/saved_search_criteria_params_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::SavedSearchCriteriaParams`.

- [ ] **Step 3: Implement**

Create `app/lib/books/saved_search_criteria_params.rb`:

```ruby
# frozen_string_literal: true

module Books
  # Form params -> the criteria hash we store. The mirror image of
  # SavedSearchCriteria, which READS the column: this writes it.
  #
  # SavedSearchCriteria stays tolerant of both storage shapes and must not be
  # narrowed on the strength of this class -- 4,727 migrated rows will never
  # pass through here. What this buys is that a criterion is either absent or
  # valid in every row the form creates, so `#unparseable?` (which makes the
  # query match nothing, by design) is unreachable from the UI.
  #
  # `ranked` is stored as the string "true"/"false" because that is what all
  # 4,391 migrated rows store. The reader accepts a real boolean too; using one
  # here would just put two shapes in one column.
  class SavedSearchCriteriaParams
    SCALAR_INT_KEYS = %w[book_type first_year_published_gt first_year_published_lt max_ranked_position].freeze
    ID_ARRAY_KEYS = ::Books::SavedSearchCriteria::ID_ARRAY_KEYS

    def self.call(raw)
      new(raw).call
    end

    def initialize(raw)
      @raw = normalize_input(raw)
    end

    def call
      out = {}

      SCALAR_INT_KEYS.each do |key|
        value = integer_or_nil(@raw[key])
        out[key] = value unless value.nil?
      end

      ID_ARRAY_KEYS.each do |key|
        ids = Array(@raw[key]).filter_map { |v| integer_or_nil(v) }.uniq
        out[key] = ids if ids.any?
      end

      lengths = Array(@raw["book_length"]).filter_map { |v| integer_or_nil(v) }
        .uniq.select { |v| ::Books::Book.book_lengths.value?(v) }
      out["book_length"] = lengths if lengths.any?

      # .to_s on the ASSIGNMENT too, not just the guard: a JSON request body
      # preserves native true/false, and storing one puts a second shape in the column.
      out["ranked"] = @raw["ranked"].to_s if %w[true false].include?(@raw["ranked"].to_s)
      out["hide_read"] = true if ActiveModel::Type::Boolean.new.cast(@raw["hide_read"])
      out["genre_match_mode"] = "all" if @raw["genre_match_mode"].to_s == "all"

      out
    end

    private

    # Accepts a permitted ActionController::Parameters as well as a plain hash;
    # to_h on an unpermitted Parameters raises, which is the correct failure.
    def normalize_input(raw)
      return {} if raw.nil?

      (raw.respond_to?(:to_unsafe_h) ? raw.to_h : raw).stringify_keys
    end

    # Integer(..., exception: false) rather than to_i: "abc".to_i is 0, which is
    # a valid book_type (Fiction) and a valid book_length.
    def integer_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value, exception: false)
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/books/saved_search_criteria_params_test.rb`
Expected: PASS.

- [ ] **Step 5: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add app/lib/books/saved_search_criteria_params.rb test/lib/books/saved_search_criteria_params_test.rb
git commit -m "Normalize saved-search criteria on write"
```

---

## Task 3: Routes, the five write actions, and a working form

At the end of this task a user can create, edit and delete a search using every criterion except the three taxonomies. Those come in Tasks 4 and 5.

**Files:**
- Modify: `config/routes.rb`, `app/controllers/saved_searches_controller.rb`
- Create: `app/views/saved_searches/new.html.erb`, `edit.html.erb`, `_form.html.erb`, `books/_criteria_fields.html.erb`
- Test: `test/controllers/saved_searches_controller_test.rb`

**Interfaces:**
- Consumes: `Books::SavedSearchCriteriaParams.call` (Task 2), `SavedSearchPolicy` (exists), `SavedSearch.subclass_for` (exists).
- Produces: routes `new_saved_search_path`, `edit_saved_search_path(id)`, `saved_searches_path` (POST), `saved_search_path(id)` (PATCH/DELETE); the partial `saved_searches/books/_criteria_fields` that Task 4 and 5 extend.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, in the saved-searches block. **`searches/new` MUST come before `searches/:id`** — the `\d+` constraint is a second line of defence, not a substitute (spec §8):

```ruby
  # Write surface (increment 6). `new` is declared before `:id` deliberately:
  # Rails tries routes in declaration order, and the day `:id` is loosened to
  # admit a slug, a `searches/:id` above this would swallow GET /searches/new.
  get "searches/new", to: "saved_searches#new", as: :new_saved_search
  post "searches", to: "saved_searches#create"
  get "searches/:id/edit", to: "saved_searches#edit", as: :edit_saved_search,
    constraints: {id: /\d+/}
  patch "searches/:id", to: "saved_searches#update", constraints: {id: /\d+/}
  put "searches/:id", to: "saved_searches#update", constraints: {id: /\d+/}
  delete "searches/:id", to: "saved_searches#destroy", constraints: {id: /\d+/}
```

Place this block immediately **above** the existing `get "searches/:id"` line.

- [ ] **Step 2: Write the failing tests**

Append to `test/controllers/saved_searches_controller_test.rb`, following the file's existing sign-in and host setup:

```ruby
    # --- new / create ---

    test "new renders the form for a signed-in user" do
      sign_in_as(@user, stub_auth: true)

      get new_saved_search_path

      assert_response :success
      assert_select "form[action=?]", saved_searches_path
    end

    test "new redirects an anonymous visitor" do
      get new_saved_search_path

      assert_response :redirect
    end

    test "create stores a search owned by the current user" do
      sign_in_as(@user, stub_auth: true)

      assert_difference "Books::SavedSearch.count", 1 do
        post saved_searches_path, params: {saved_search: {
          name: "Long Victorian novels",
          description: "For winter",
          public: "1",
          criteria: {book_type: "0", first_year_published_gt: "1837", ranked: "true"}
        }}
      end

      search = Books::SavedSearch.order(:id).last
      assert_redirected_to saved_search_path(search)
      assert_equal @user, search.user
      assert_equal "Long Victorian novels", search.name
      assert search.public?
    end

    # The normalizer is wired in, not merely defined (Task 2).
    test "create drops blank criteria rather than storing them" do
      sign_in_as(@user, stub_auth: true)

      post saved_searches_path, params: {saved_search: {
        name: "Sparse",
        criteria: {book_type: "", ranked: "", included_category_ids: ["", ""], first_year_published_gt: "1900"}
      }}

      criteria = Books::SavedSearch.order(:id).last.criteria
      assert_equal({"first_year_published_gt" => 1900}, criteria)
    end

    test "create ignores a user_id in the params" do
      sign_in_as(@user, stub_auth: true)
      other = users(:regular_user)

      post saved_searches_path, params: {saved_search: {
        name: "Not yours", user_id: other.id, criteria: {book_type: "0"}
      }}

      assert_equal @user, Books::SavedSearch.order(:id).last.user
    end

    test "create re-renders the form when the record is invalid" do
      sign_in_as(@user, stub_auth: true)

      assert_no_difference "Books::SavedSearch.count" do
        post saved_searches_path, params: {saved_search: {name: "Empty", criteria: {}}}
      end

      assert_response :unprocessable_entity
    end

    test "create redirects an anonymous visitor without writing" do
      assert_no_difference "Books::SavedSearch.count" do
        post saved_searches_path, params: {saved_search: {name: "x", criteria: {book_type: "0"}}}
      end

      assert_response :redirect
    end

    # --- edit / update ---

    test "edit renders the form for the owner" do
      sign_in_as(@user, stub_auth: true)

      get edit_saved_search_path(@private_search)

      assert_response :success
      assert_select "form[action=?]", saved_search_path(@private_search)
    end

    # 404, never 403 -- a 403 confirms the id exists (spec §8).
    test "edit 404s for a stranger, even on a public search" do
      @private_search.update_column(:public, true)
      sign_in_as(@other, stub_auth: true)

      get edit_saved_search_path(@private_search)

      assert_response :not_found
    end

    test "update changes the search" do
      sign_in_as(@user, stub_auth: true)

      patch saved_search_path(@private_search), params: {saved_search: {
        name: "Renamed", criteria: {book_type: "1"}
      }}

      assert_redirected_to saved_search_path(@private_search)
      assert_equal "Renamed", @private_search.reload.name
      assert_equal({"book_type" => 1}, @search.criteria)
    end

    test "update 404s for a stranger" do
      sign_in_as(@other, stub_auth: true)

      patch saved_search_path(@private_search), params: {saved_search: {name: "Hijacked"}}

      assert_response :not_found
      assert_not_equal "Hijacked", @private_search.reload.name
    end

    # --- destroy ---

    test "destroy removes the search" do
      sign_in_as(@user, stub_auth: true)

      assert_difference "Books::SavedSearch.count", -1 do
        delete saved_search_path(@private_search)
      end

      assert_redirected_to saved_searches_path
    end

    test "destroy 404s for a stranger" do
      sign_in_as(@other, stub_auth: true)

      assert_no_difference "Books::SavedSearch.count" do
        delete saved_search_path(@private_search)
      end

      assert_response :not_found
    end

    # --- routing ---

    test "searches/new resolves to new, not show" do
      assert_routing({method: "get", path: "/searches/new"},
        {controller: "saved_searches", action: "new"})
    end
```

The file's `setup` already defines `@user` (`regular_user`), `@other` (`admin_user`), `@public_search`, `@private_search` (both owned by `@user`) and `@other_search`. It also does `include ActiveRecord::Assertions::QueryAssertions` after `require "active_record/testing/query_assertions"`. Use those names; do not add new fixtures or rename anything.

- [ ] **Step 3: Run them and watch them fail**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: FAIL — `AbstractController::ActionNotFound` / missing template for the new actions.

- [ ] **Step 4: Add the controller actions**

In `app/controllers/saved_searches_controller.rb`, extend the `before_action` list and add the actions above `private`:

```ruby
  before_action :require_signed_in!, only: [:index, :new, :create, :edit, :update, :destroy]
  before_action :set_owned_search, only: [:edit, :update, :destroy]
```

```ruby
  # GET /searches/new
  def new
    @search = domain_class.new(user: current_user, criteria: {})
    authorize @search, :new?, policy_class: SavedSearchPolicy
  end

  # POST /searches
  def create
    @search = domain_class.new(saved_search_params)
    @search.user = current_user
    @search.criteria = criteria_params
    authorize @search, :create?, policy_class: SavedSearchPolicy

    if @search.save
      redirect_to saved_search_path(@search), notice: "Search saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /searches/:id/edit
  def edit
  end

  # PATCH/PUT /searches/:id
  def update
    @search.assign_attributes(saved_search_params)
    @search.criteria = criteria_params if params[:saved_search].key?(:criteria)

    if @search.save
      redirect_to saved_search_path(@search), notice: "Search updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /searches/:id
  def destroy
    @search.destroy
    redirect_to saved_searches_path, notice: "Search deleted.", status: :see_other
  end
```

And in the `private` section:

```ruby
  # Scoped to the owner, so a stranger gets RecordNotFound -- a 404, not the
  # 403 Pundit would raise, which would confirm the id exists (spec §8).
  # authorize still runs: the scope is the security boundary, the policy is the
  # statement of intent, and Pundit's verify_authorized would flag its absence.
  def set_owned_search
    @search = domain_class.owned_by(current_user).find(params[:id])
    authorize @search, :"#{action_name}?", policy_class: SavedSearchPolicy
  end

  def saved_search_params
    params.require(:saved_search).permit(:name, :description, :public)
  end

  # Permitted explicitly rather than with `criteria: {}` -- a bare hash permit
  # would store whatever the form posted, including keys no reader knows.
  def criteria_params
    domain_class.criteria_params_class.call(
      params.require(:saved_search).fetch(:criteria, nil)&.permit(
        :book_type, :ranked, :hide_read, :genre_match_mode,
        :first_year_published_gt, :first_year_published_lt, :max_ranked_position,
        book_length: [],
        included_category_ids: [], excluded_category_ids: [],
        included_language_ids: [], excluded_language_ids: [],
        included_country_ids: [], excluded_country_ids: []
      )
    )
  end
```

`destroy` uses `status: :see_other` because Turbo requires a 303 on a redirect following a non-GET.

- [ ] **Step 5: Add the `criteria_params_class` hook**

`SavedSearchesController` is domain-generic, so it must not name `Books::` anything. Add the seam alongside the existing hooks.

In `app/models/saved_search.rb`:

```ruby
  def self.criteria_params_class
    raise NotImplementedError, "#{name} must override .criteria_params_class"
  end
```

In `app/models/books/saved_search.rb`:

```ruby
    def self.criteria_params_class_name
      "Books::SavedSearchCriteriaParams"
    end

    def self.criteria_params_class
      criteria_params_class_name.constantize
    end
```

- [ ] **Step 6: Add the views**

`app/views/saved_searches/new.html.erb`:

```erb
<%
  content_for :page_title, "New Saved Search | #{domain_name}"
%>

<div class="space-y-6">
  <h1 class="text-3xl font-bold">New Saved Search</h1>
  <%= render "form", search: @search, url: saved_searches_path %>
</div>
```

`app/views/saved_searches/edit.html.erb`:

```erb
<%
  content_for :page_title, "Edit #{@search.display_name} | #{domain_name}"
%>

<div class="space-y-6">
  <h1 class="text-3xl font-bold">Edit Saved Search</h1>
  <%= render "form", search: @search, url: saved_search_path(@search) %>
</div>
```

`app/views/saved_searches/_form.html.erb` — the shared shell. The criteria body is a per-domain partial, which is the whole domain seam (spec §9):

```erb
<%# scope: :saved_search is load-bearing. Without it form_with derives the key from
    the STI subclass -- books_saved_search[...] -- which matches neither the
    hardcoded check_box_tag names below nor the controller's require(:saved_search),
    and a real submission silently saves a record with name: nil. It is `scope:`,
    not `as:`; the latter is form_for's. %>
<%= form_with model: search, url: url, scope: :saved_search, class: "space-y-6" do |f| %>
  <% if search.errors.any? %>
    <div class="alert alert-error" role="alert">
      <ul class="list-disc list-inside">
        <% search.errors.full_messages.each do |message| %>
          <li><%= message %></li>
        <% end %>
      </ul>
    </div>
  <% end %>

  <div class="card bg-base-100 shadow-sm">
    <div class="card-body gap-4">
      <div class="form-control">
        <%= f.label :name, class: "label" do %><span class="label-text font-semibold">Name</span><% end %>
        <%= f.text_field :name, class: "input input-bordered w-full",
              placeholder: "Long Victorian novels" %>
      </div>

      <div class="form-control">
        <%= f.label :description, class: "label" do %><span class="label-text font-semibold">Description</span><% end %>
        <%= f.text_area :description, rows: 2, class: "textarea textarea-bordered w-full" %>
      </div>

      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-3">
          <%= f.check_box :public, class: "checkbox" %>
          <span class="label-text">Make this search public</span>
        </label>
      </div>
    </div>
  </div>

  <%= render "saved_searches/#{Current.domain}/criteria_fields", f: f, search: search %>

  <div class="flex flex-wrap gap-2">
    <%= f.submit search.persisted? ? "Save changes" : "Create search", class: "btn btn-primary" %>
    <%= link_to "Cancel", search.persisted? ? saved_search_path(search) : saved_searches_path,
          class: "btn btn-ghost" %>
  </div>
<% end %>
```

`app/views/saved_searches/books/_criteria_fields.html.erb` — everything except the three taxonomies, which Tasks 4 and 5 add:

```erb
<% criteria = search.criteria_object %>

<div class="card bg-base-100 shadow-sm">
  <div class="card-body gap-4">
    <h2 class="card-title text-lg">Filters</h2>

    <%= f.fields_for :criteria, search.criteria do |c| %>
      <div class="form-control">
        <%= c.label :book_type, class: "label" do %><span class="label-text font-semibold">Type</span><% end %>
        <%= c.select :book_type,
              ::Books::BookType::LABELS.map { |value, label| [label, value] },
              {include_blank: "Any type"},
              {class: "select select-bordered w-full", selected: criteria.book_type} %>
      </div>

      <fieldset class="form-control">
        <legend class="label-text font-semibold">Length</legend>
        <div class="flex flex-wrap gap-3">
          <% ::Books::Book.book_lengths.each do |key, value| %>
            <label class="label cursor-pointer justify-start gap-2">
              <%= check_box_tag "saved_search[criteria][book_length][]", value,
                    criteria.book_length.include?(value), id: nil, class: "checkbox checkbox-sm" %>
              <span class="label-text"><%= key.to_s.titleize %></span>
            </label>
          <% end %>
        </div>
      </fieldset>

      <div class="grid gap-4 sm:grid-cols-2">
        <div class="form-control">
          <%= c.label :first_year_published_gt, class: "label" do %><span class="label-text font-semibold">Published from</span><% end %>
          <%= c.number_field :first_year_published_gt, value: criteria.first_year_published_gt,
                class: "input input-bordered w-full", placeholder: "1837" %>
        </div>
        <div class="form-control">
          <%= c.label :first_year_published_lt, class: "label" do %><span class="label-text font-semibold">Published to</span><% end %>
          <%= c.number_field :first_year_published_lt, value: criteria.first_year_published_lt,
                class: "input input-bordered w-full", placeholder: "1901" %>
        </div>
      </div>

      <div class="form-control">
        <%= c.label :ranked, class: "label" do %><span class="label-text font-semibold">Ranking</span><% end %>
        <%# Tri-state, not a boolean: "" is All Books, and collapsing it into
            false silently changes what 437 stored searches return (spec §6). %>
        <%= c.select :ranked,
              [["All books", ""], ["Ranked books only", "true"], ["Unranked books only", "false"]],
              {},
              {class: "select select-bordered w-full",
               selected: {ranked: "true", unranked: "false"}[criteria.ranked].to_s} %>
      </div>

      <div class="form-control">
        <%= c.label :max_ranked_position, class: "label" do %><span class="label-text font-semibold">Top N ranked books</span><% end %>
        <%= c.number_field :max_ranked_position, value: criteria.max_ranked_position,
              class: "input input-bordered w-full", placeholder: "100" %>
      </div>

      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-3">
          <%= c.check_box :hide_read, {checked: criteria.hide_read}, "1", "0" %>
          <span class="label-text">Hide books I've read</span>
        </label>
      </div>
    <% end %>
  </div>
</div>
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: PASS.

- [ ] **Step 8: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add config/routes.rb app/controllers/saved_searches_controller.rb \
  app/models/saved_search.rb app/models/books/saved_search.rb \
  app/views/saved_searches/ test/controllers/saved_searches_controller_test.rb
git commit -m "Add the saved-search write actions and form"
```

---

## Task 4: Language and country multi-selects

201 languages and 253 countries are small enough to render in the page — no autocomplete, no endpoint, no round trip (spec §9). Legacy's mutual-exclusion JavaScript, which disabled "exclude" once "include" had values, is **dropped**: including French while excluding German is coherent, and the guard only ever prevented redundancy.

**Files:**
- Modify: `app/views/saved_searches/books/_criteria_fields.html.erb`, `app/controllers/saved_searches_controller.rb`
- Test: `test/controllers/saved_searches_controller_test.rb`

**Interfaces:**
- Consumes: the form partial from Task 3.
- Produces: `@languages` / `@countries` assigned for `new` and `edit`.

- [ ] **Step 1: Write the failing tests**

```ruby
    test "the form offers every language and country" do
      sign_in_as(@user, stub_auth: true)

      get new_saved_search_path

      assert_select "select[name='saved_search[criteria][included_language_ids][]'] option",
        count: Language.count
      assert_select "select[name='saved_search[criteria][excluded_country_ids][]'] option",
        count: ::Books::Country.count
    end

    test "create stores selected language and country ids as integers" do
      sign_in_as(@user, stub_auth: true)
      language = languages(:english)
      country = books_countries(:french)

      post saved_searches_path, params: {saved_search: {
        name: "Taxonomies",
        criteria: {included_language_ids: [language.id.to_s], excluded_country_ids: [country.id.to_s]}
      }}

      criteria = Books::SavedSearch.order(:id).last.criteria
      assert_equal [language.id], criteria["included_language_ids"]
      assert_equal [country.id], criteria["excluded_country_ids"]
    end

    # Loading 201 + 253 rows must not become one query per option.
    test "the form loads its taxonomies in a bounded number of queries" do
      sign_in_as(@user, stub_auth: true)
      get new_saved_search_path # warm any cached lookups
      ActiveRecord::Base.connection.clear_query_cache

      assert_queries_count(EXPECTED) do
        get new_saved_search_path
      end
    end
```

`languages(:english)` and `books_countries(:french)` both exist; verify any other fixture you reach for, since names here are semantic and never `one`/`two`.

`assert_queries_count` takes an **exact** integer, not a range — replace `EXPECTED` by running the test once, reading the actual count from the failure message, and pinning that number. A range silently tolerates the regression this test exists to catch. The `clear_query_cache` call is not optional: fixtures pre-enable the query cache pool-wide, so without it this measures 0 and passes against anything (precedent in `books/lists_controller_test.rb`).

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: FAIL — no such selects in the rendered form.

- [ ] **Step 3: Load the taxonomies in the controller**

Add to `SavedSearchesController`, and call it from both `new` and `edit`:

```ruby
  before_action :load_taxonomies, only: [:new, :create, :edit, :update]
```

```ruby
  # Ordered by name so the two multi-selects are scannable. Loaded for create
  # and update too, because both re-render the form on a validation failure.
  def load_taxonomies
    @languages = Language.order(:name)
    @countries = ::Books::Country.order(:name)
  end
```

`::Books::Country` is books-specific in a domain-generic controller. That is acceptable only because this increment ships one domain; when games arrives, move both loads behind a `domain_class.taxonomies_for_form` hook rather than adding a conditional here.

- [ ] **Step 4: Add the selects to the criteria partial**

Insert before the closing `<% end %>` of the `fields_for` block:

```erb
      <% {language: @languages, country: @countries}.each do |axis, records| %>
        <div class="grid gap-4 sm:grid-cols-2">
          <% [:included, :excluded].each do |mode| %>
            <% key = "#{mode}_#{axis}_ids" %>
            <div class="form-control">
              <label class="label" for="saved_search_criteria_<%= key %>">
                <span class="label-text font-semibold"><%= "#{mode} #{axis}".titleize %></span>
              </label>
              <%= select_tag "saved_search[criteria][#{key}][]",
                    options_from_collection_for_select(records, :id, :name, criteria.public_send(key)),
                    multiple: true, size: 8, id: "saved_search_criteria_#{key}",
                    class: "select select-bordered w-full h-auto" %>
            </div>
          <% end %>
        </div>
      <% end %>
```

A `multiple` select posts nothing at all when the user deselects everything, so an existing selection could never be cleared. Rails' `select_tag` does not add a blank hidden field the way `f.select` does, so add one immediately before each select:

```erb
              <%= hidden_field_tag "saved_search[criteria][#{key}][]", "", id: nil %>
```

The normalizer drops the resulting `[""]` to nothing, which is exactly the "cleared" state.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: PASS. The option counts include the hidden field's blank, so if a count is off by one, that is why — assert on the select's options as written above, not on all inputs with that name.

- [ ] **Step 6: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add app/controllers/saved_searches_controller.rb app/views/saved_searches/books/_criteria_fields.html.erb \
  test/controllers/saved_searches_controller_test.rb
git commit -m "Add language and country selects to the saved-search form"
```

---

## Task 5: The category picker

52,757 books categories cannot be a multi-select. This is the one taxonomy that needs a server round trip (spec §9), and it is what PR #217's shared `CategorySearchQuery` was built for.

**Files:**
- Create: `app/controllers/saved_searches/categories_controller.rb`, `test/controllers/saved_searches/categories_controller_test.rb`, `app/javascript/controllers/saved_search_picker_controller.js`
- Modify: `config/routes.rb`, `app/models/saved_search.rb`, `app/models/books/saved_search.rb`, `app/javascript/controllers/index.js`, `app/views/saved_searches/books/_criteria_fields.html.erb`

**Interfaces:**
- Consumes: `CategorySearchQuery.call(q, scope:, limit:)` and `Category#name_with_type` (both shipped in PR #217).
- Produces: `GET /searches/categories?q=` → `[{value:, text:}]`; Stimulus controller `saved-search-picker`.

- [ ] **Step 1: Add the domain hook and the route**

In `app/models/saved_search.rb`:

```ruby
  def self.category_class
    raise NotImplementedError, "#{name} must override .category_class"
  end
```

In `app/models/books/saved_search.rb`:

```ruby
    def self.category_class
      ::Books::Category
    end
```

In `config/routes.rb`, **above** `searches/:id` and alongside `searches/new`:

```ruby
  get "searches/categories", to: "saved_searches/categories#index", as: :saved_search_categories
```

- [ ] **Step 2: Write the failing tests**

Create `test/controllers/saved_searches/categories_controller_test.rb`:

```ruby
require "test_helper"

module SavedSearches
  class CategoriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @user = users(:regular_user)
    end

    test "returns the autocomplete shape with the type in the text" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "fict"), as: :json

      assert_response :success
      row = response.parsed_body.find { |r| r["value"] == categories(:books_fiction_genre).id }
      assert_equal "Fiction (Genre)", row["text"]
    end

    # The picker spans every type, exactly as the filter modal's does.
    test "is not scoped to any category_type" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "americ"), as: :json

      texts = response.parsed_body.map { |r| r["text"] }
      assert_includes texts, "Americana (Genre)"
      assert_includes texts, "American History (Subject)"
    end

    test "returns only this domain's categories" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "rock"), as: :json

      assert_equal [], response.parsed_body
    end

    test "returns nothing for a blank query" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: ""), as: :json

      assert_equal [], response.parsed_body
    end

    test "requires a signed-in user" do
      get saved_search_categories_path(q: "fict"), as: :json

      assert_response :redirect
    end

    test "404s on a host with no saved searches" do
      host! Rails.application.config.domains[:music]
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "rock"), as: :json

      assert_response :not_found
    end
  end
end
```

This file is its own test class, so it needs its own `setup`; `users(:regular_user)` is the user `saved_searches_controller_test.rb` uses.

- [ ] **Step 3: Run them and watch them fail**

Run: `bin/rails test test/controllers/saved_searches/categories_controller_test.rb`
Expected: FAIL — uninitialized constant / no route.

- [ ] **Step 4: Implement the endpoint**

Create `app/controllers/saved_searches/categories_controller.rb`:

```ruby
# frozen_string_literal: true

module SavedSearches
  # JSON category search for the saved-search form's picker. Signed-in only,
  # and 404s on a host with no SavedSearch subclass, matching
  # SavedSearchesController's own guards.
  #
  # The {value:, text:} shape matches the admin autocomplete, so the picker and
  # every admin category select consume the same contract.
  class CategoriesController < ApplicationController
    LIMIT = 10

    before_action :require_domain_support!
    before_action :require_signed_in!

    def index
      categories = CategorySearchQuery.call(
        params[:q],
        scope: domain_class.category_class,
        limit: LIMIT
      )

      render json: categories.map { |c| {value: c.id, text: c.name_with_type} }
    end

    private

    def domain_class
      return @domain_class if defined?(@domain_class)

      @domain_class = SavedSearch.subclass_for(Current.domain)
    end

    def require_domain_support!
      raise ActiveRecord::RecordNotFound if domain_class.nil?
    end
  end
end
```

- [ ] **Step 5: Write the Stimulus picker**

Create `app/javascript/controllers/saved_search_picker_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Connects to data-controller="saved-search-picker"
//
// One instance per include/exclude box. Chips already chosen are server-
// rendered into the chips target on edit, so this controller must read the
// existing hidden inputs rather than assume it starts empty.
export default class extends Controller {
  static targets = ["query", "results", "chips"]
  static values = { url: String, name: String }

  connect() {
    this.timer = null
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  // The picker sits inside the saved-search form, so Enter would submit it
  // mid-search. On a phone the keyboard's Search key IS Enter.
  suppressEnter(event) {
    if (event.key === "Enter") event.preventDefault()
  }

  async run() {
    const query = this.queryTarget.value.trim()
    if (query === "") {
      this.resultsTarget.replaceChildren()
      return
    }

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)

    let rows = []
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      rows = await response.json()
    } catch {
      return
    }

    this.resultsTarget.replaceChildren(...rows.map((row) => this.resultButton(row)))
  }

  resultButton(row) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-ghost btn-sm justify-start w-full"
    button.textContent = row.text
    button.dataset.value = row.value
    button.dataset.action = "saved-search-picker#add"
    return button
  }

  add(event) {
    const { value } = event.currentTarget.dataset
    const label = event.currentTarget.textContent

    if (this.selectedValues().includes(value)) return

    this.chipsTarget.appendChild(this.chip(value, label))
    this.queryTarget.value = ""
    this.resultsTarget.replaceChildren()
  }

  remove(event) {
    event.currentTarget.closest("[data-chip]").remove()
  }

  selectedValues() {
    return Array.from(this.chipsTarget.querySelectorAll("input[type=hidden]")).map((el) => el.value)
  }

  chip(value, label) {
    const wrapper = document.createElement("span")
    wrapper.className = "badge badge-outline gap-1"
    wrapper.dataset.chip = value

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = this.nameValue
    hidden.value = value

    const text = document.createElement("span")
    text.textContent = label

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "btn btn-ghost btn-xs px-1"
    remove.textContent = "×"
    remove.setAttribute("aria-label", `Remove ${label}`)
    remove.dataset.action = "saved-search-picker#remove"

    wrapper.append(hidden, text, remove)
    return wrapper
  }
}
```

Register it in `app/javascript/controllers/index.js`, following the file's existing style:

```javascript
import SavedSearchPickerController from "./saved_search_picker_controller"
application.register("saved-search-picker", SavedSearchPickerController)
```

- [ ] **Step 6: Add the picker to the form**

Insert into the criteria partial, alongside the language and country blocks. The already-chosen chips are server-rendered so `edit` shows them without JavaScript having to fetch:

```erb
      <% selected_categories = ::Books::Category.where(
           id: criteria.included_category_ids + criteria.excluded_category_ids
         ).index_by(&:id) %>

      <div class="grid gap-4 sm:grid-cols-2">
        <% [:included, :excluded].each do |mode| %>
          <% key = "#{mode}_category_ids" %>
          <div class="form-control" data-controller="saved-search-picker"
               data-saved-search-picker-url-value="<%= saved_search_categories_path %>"
               data-saved-search-picker-name-value="saved_search[criteria][<%= key %>][]">
            <label class="label" for="saved_search_criteria_<%= key %>">
              <span class="label-text font-semibold"><%= "#{mode} categories".titleize %></span>
            </label>
            <%# Cleared state: without this, deselecting every chip posts no key
                at all and the stored ids survive. The normalizer drops [""]. %>
            <%= hidden_field_tag "saved_search[criteria][#{key}][]", "", id: nil %>
            <input type="search" id="saved_search_criteria_<%= key %>"
                   class="input input-bordered w-full"
                   placeholder="Search genres, subjects, settings"
                   autocomplete="off"
                   data-saved-search-picker-target="query"
                   data-action="input->saved-search-picker#search keydown->saved-search-picker#suppressEnter">
            <div class="flex flex-col gap-1 mt-1" data-saved-search-picker-target="results"></div>
            <div class="flex flex-wrap gap-2 mt-2" data-saved-search-picker-target="chips">
              <% criteria.public_send(key).each do |id| %>
                <% category = selected_categories[id] %>
                <span class="badge badge-outline gap-1" data-chip="<%= id %>">
                  <%= hidden_field_tag "saved_search[criteria][#{key}][]", id, id: nil %>
                  <span><%= category ? category.name_with_type : "Category #{id}" %></span>
                  <button type="button" class="btn btn-ghost btn-xs px-1"
                          aria-label="Remove <%= category&.name_with_type || id %>"
                          data-action="saved-search-picker#remove">×</button>
                </span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
```

`category ? … : "Category #{id}"` matters: a stored id whose category was since soft-deleted must still render a removable chip rather than vanishing, which would silently drop it from the search on the next save.

- [ ] **Step 7: Add a controller test for the rendered chips**

```ruby
    test "edit renders a chip for each stored category, labelled with its type" do
      sign_in_as(@user, stub_auth: true)
      category = categories(:books_fiction_genre)
      @private_search.update!(criteria: {"included_category_ids" => [category.id]})

      get edit_saved_search_path(@private_search)

      assert_select "[data-chip='#{category.id}']" do
        assert_select "input[name='saved_search[criteria][included_category_ids][]'][value=?]", category.id.to_s
      end
      assert_select "[data-chip='#{category.id}']", text: /Fiction \(Genre\)/
    end
```

- [ ] **Step 8: Run everything**

```bash
bin/rails test && bundle exec standardrb && yarn build:all
```

`yarn build:all` must succeed — a syntax error in the Stimulus controller fails there, not in the Ruby suite.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Add the saved-search category picker"
```

---

## Task 6: Entry points and browser coverage

Nothing so far links to any of it. The increments table lists Playwright as increment 6's verification.

**Files:**
- Modify: `app/views/saved_searches/index.html.erb`, `app/views/saved_searches/show.html.erb`
- Create: `e2e/tests/books/saved_searches_write.spec.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing later depends on.

- [ ] **Step 1: Add the entry points**

In `index.html.erb`, add a button above the list and a call to action in the empty state:

```erb
  <div class="flex items-center justify-between gap-4">
    <h1 class="text-3xl font-bold">My Saved Searches</h1>
    <%= link_to "New Saved Search", new_saved_search_path, class: "btn btn-primary" %>
  </div>
```

and inside the empty state, after the existing paragraph:

```erb
      <%= link_to "Create your first search", new_saved_search_path, class: "btn btn-primary mt-4" %>
```

In `show.html.erb`, for the owner only — `@owner` is already assigned by the controller:

```erb
  <% if @owner %>
    <div class="flex flex-wrap gap-2">
      <%= link_to "Edit", edit_saved_search_path(@search), class: "btn btn-sm btn-outline" %>
      <%= button_to "Delete", saved_search_path(@search), method: :delete,
            class: "btn btn-sm btn-error btn-outline",
            form: {data: {turbo_confirm: "Delete this saved search?"}} %>
    </div>
  <% end %>
```

- [ ] **Step 2: Guard against a frame-trapped link**

`show` renders results outside any turbo frame on purpose (spec §9). The repo has a guard for this; run it over the new views:

```bash
grep -rn "assert_no_frame_trapped_links" test/ | head -3
```

Add the assertion to the saved-search controller tests for `new`, `edit`, `index` and `show`, matching how other tests call it. The guard is anchors-only, so it will not see the `button_to`.

- [ ] **Step 3: Write the Playwright spec**

Create `e2e/tests/books/saved_searches_write.spec.ts`. The `books-account` project already carries a signed-in storage state and matches `books/account/*`, so check `e2e/playwright.config.ts` and either place this file where a signed-in project picks it up or add a project for it — **do not** put a signed-in spec where the anonymous `books` project runs it.

```typescript
import { test, expect } from '@playwright/test';

test.describe('Saved search write flow', () => {
  test('a user can create, edit and delete a saved search', async ({ page }) => {
    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const name = `E2E search ${Date.now()}`;
    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Type').selectOption({ label: 'Fiction' });
    await page.getByLabel('Ranking').selectOption({ label: 'Ranked books only' });

    // The category picker is the only field needing a round trip.
    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    await included.getByPlaceholder('Search genres, subjects, settings').fill('fict');
    await included.locator('[data-action="saved-search-picker#add"]').first().click();
    await expect(included.locator('[data-chip]')).toHaveCount(1);

    await page.getByRole('button', { name: 'Create search' }).click();

    await expect(page.getByRole('heading', { level: 1 })).toContainText(name);

    // Edit: the stored chip must come back server-rendered.
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page.locator('[data-saved-search-picker-name-value*="included_category_ids"] [data-chip]'))
      .toHaveCount(1);

    await page.getByLabel('Name').fill(`${name} (edited)`);
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText('(edited)');

    // Delete, and confirm it is gone from the index rather than merely redirected.
    page.on('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL('/searches');
    await expect(page.getByText(`${name} (edited)`)).toHaveCount(0);
  });

  test('removing every category chip clears the stored ids', async ({ page }) => {
    // The hidden blank field is what makes this possible; without it the form
    // posts no key at all and the stored ids survive the save.
    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const name = `E2E clear ${Date.now()}`;
    await page.getByLabel('Name').fill(name);
    const included = page.locator('[data-saved-search-picker-name-value*="included_category_ids"]');
    await included.getByPlaceholder('Search genres, subjects, settings').fill('fict');
    await included.locator('[data-action="saved-search-picker#add"]').first().click();
    await page.getByRole('button', { name: 'Create search' }).click();

    await page.getByRole('link', { name: 'Edit' }).click();
    await page.locator('[data-chip] button').first().click();
    await page.getByRole('button', { name: 'Save changes' }).click();

    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page.locator('[data-saved-search-picker-name-value*="included_category_ids"] [data-chip]'))
      .toHaveCount(0);
  });
});
```

- [ ] **Step 4: Run the browser tests**

`bin/dev` self-terminates in an agent shell. Check what is on port 3000 first, then:

```bash
yarn build:all
bin/rails server -p 3000   # background this
yarn test:e2e --grep "Saved search" --reporter=list
```

If a spec fails, fix the code or the selector — do not delete the assertion. Confirm the two specs are not vacuous: break the `hidden_field_tag` blank in the picker block and watch the "clears the stored ids" spec fail, then restore it.

- [ ] **Step 5: Final gate and commit**

```bash
CI=true bin/rails test && bundle exec standardrb
git add -A
git commit -m "Add saved-search entry points and write-flow browser coverage"
```

Do NOT push and do NOT open a PR.

---

## Self-Review

**Spec coverage.** §8 write routes and the `new`-before-`:id` ordering → Task 3 Step 1. §9 shared `new`/`edit` form → Task 3 Step 6; the `saved_searches/books/_criteria_fields` domain seam → Task 3 Step 6; languages and countries as plain multi-selects → Task 4; the category picker over `CategorySearchQuery` → Task 5; mutual-exclusion JavaScript dropped → Task 4 preamble, by omission and stated. §6's tri-state `ranked` → Task 2 and the form's three-option select. §12's "verifiable by Playwright" → Task 6.

**Deliberately not covered.** A "save this search" button on the browse page (stated in Global Constraints). Increment 7's own scope: broader E2E for the index and show pages, plus `docs/features/saved_searches.md` updates.

**Known risks, stated rather than hidden.** Task 1 was dropped before execution once its premise turned out to be false (see the task). Task 4 loads `::Books::Country` in a domain-generic controller and says what to do when games arrives instead of pretending the seam is clean. Task 5's chip rendering handles a stored id whose category no longer resolves, which would otherwise drop silently on the next save.

**Type consistency.** `Books::SavedSearchCriteriaParams.call(hash) -> Hash` is defined in Task 2 and consumed in Task 3 via the `criteria_params_class` hook added in Task 3 Step 5. `category_class` is added in Task 5 Step 1 and consumed in Task 5 Step 4. The Stimulus identifier is `saved-search-picker` in the controller file, the registration, the `data-controller`, every `data-action`, and both Playwright specs.
