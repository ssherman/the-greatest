# Books Saved Searches — Increment 5: Controller and Views

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the saved-search feature on for users — `/searches` lists a signed-in user's saved searches and `/searches/:id` renders one search's results — with every legacy URL still resolving.

**Architecture:** One global `SavedSearchesController` (no domain constraint) resolving its STI subclass from `Current.domain`, exactly as `MyListsController` does. `show` hands the already-built increment-4 query layer a criteria object and a page number, gets back one page of `Books::Book` records plus a total, and renders them through the existing `Books::CardComponent` grid. Everything domain-specific in the views sits behind two partials under `app/views/saved_searches/<domain>/`, which is the seam games and music will use later.

**Tech Stack:** Rails 8, Pundit, pagy 43 (path-based paging via the app's `PathBasedPagination` concern), ViewComponent, DaisyUI 5 / Tailwind 4, Minitest + Mocha + fixtures.

**Spec:** `docs/superpowers/specs/2026-08-08-books-saved-searches-design.md`, §8 (routes), §9 (UI), §6 (query layer contract), §11 (testing). The spec was amended on 2026-08-09 (commit `bb8d7fc5`) to record this increment's four decisions; read §8 and §9 before starting.

## Global Constraints

- **Ruby lint is `bundle exec standardrb`**, never `bin/rubocop`. Gate before every commit: `bin/rails test` + `bundle exec standardrb`.
- **Never run destructive commands against the development database.** Books data exists only in dev and takes hours to rebuild. `ActiveRecord::FixtureSet.create_fixtures` truncates every table it names — never run it outside the test env.
- **Do not mention, plan for, or touch the movies domain** beyond the one line already present in the layout switch being extracted in Task 1.
- **`per_page` is fixed at 50.** No `?limit=` param. 10,000 / 50 = 200 pages exactly, which is why `from + size` never crosses OpenSearch's `max_result_window`.
- **All work happens in the worktree** `/home/shane/dev/the-greatest/.claude/worktrees/books-saved-searches-inc5` on branch `worktree-books-saved-searches-inc5`. Run every command from `<worktree>/web-app`.
- **Root-anchor constants inside nested namespaces.** Inside `Books::`, a bare `Books::Book` can resolve to the nested module. Write `::Books::Book`. This has bitten three times.
- **Nothing in this increment writes to production.** No migration, no rake task, no data change. Deploy is code-only.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `app/controllers/concerns/domain_layout.rb` | The `Current.domain` → layout switch, shared by `MyListsController` and `SavedSearchesController` |
| `app/controllers/saved_searches_controller.rb` | index + show, domain resolution, `last_executed_at` write |
| `app/lib/books/saved_search_filter_labels.rb` | Criteria object → labelled filter groups for the active-filters card (3 queries) |
| `app/views/saved_searches/index.html.erb` | Domain-agnostic list of the user's searches |
| `app/views/saved_searches/show.html.erb` | Domain-agnostic chrome: title, owner line, total, pagination |
| `app/views/saved_searches/books/_active_filters.html.erb` | Books active-filters card |
| `app/views/saved_searches/books/_results.html.erb` | Books results grid |
| `test/controllers/saved_searches_controller_test.rb` | Integration tests for both actions and every legacy URL |
| `test/lib/books/saved_search_filter_labels_test.rb` | Unit tests for the labels PORO |

**Modify:**

| File | Change |
|---|---|
| `app/models/saved_search.rb` | `DOMAIN_SUBCLASSES`, `.subclass_for`, `.filter_labels_class` abstract |
| `app/models/books/saved_search.rb` | `.filter_labels_class_name` / `.filter_labels_class` |
| `app/lib/books/saved_search_query.rb` | `Result#capped?` |
| `app/controllers/concerns/path_based_pagination.rb` | `#pagy_path_count` |
| `app/controllers/my_lists_controller.rb` | Include `DomainLayout`, drop its private copy |
| `config/routes.rb` | The `/searches` block and the `/v/:view_type` 301s |
| `public/robots.txt` | `Disallow: /searches` |
| `app/views/layouts/books/application.html.erb` | `#navbar_my_searches` in both nav lists |
| `app/javascript/controllers/user_list_state_controller.js` | Reveal `#navbar_my_searches` alongside `#navbar_my_lists` |

---

## Task 1: Domain resolution and the shared layout concern

Nothing user-visible. This is the seam that lets one global controller serve books now and games later, plus the extraction of a layout switch that is about to have a second caller.

**Files:**
- Create: `app/controllers/concerns/domain_layout.rb`
- Modify: `app/models/saved_search.rb`
- Modify: `app/controllers/my_lists_controller.rb:9-14, 87-94`
- Test: `test/models/saved_search_test.rb`

**Interfaces:**
- Produces: `SavedSearch.subclass_for(domain)` → the STI subclass constant or `nil`; `SavedSearch::DOMAIN_SUBCLASSES` (Hash of String → String); `DomainLayout#resolve_layout` (private) → layout path String.

Note: the `filter_labels_class` hook that would naturally live beside `subclass_for` is in Task 2 instead, with the class it resolves. Splitting them would mean committing a test that cannot pass until the next task, and every commit in this plan must leave `bin/rails test` green.

- [ ] **Step 1: Write the failing model tests**

Append to `test/models/saved_search_test.rb`:

```ruby
  test "subclass_for returns the STI subclass for a registered domain" do
    assert_equal ::Books::SavedSearch, SavedSearch.subclass_for(:books)
    assert_equal ::Books::SavedSearch, SavedSearch.subclass_for("books")
  end

  test "subclass_for returns nil for a domain with no saved searches" do
    assert_nil SavedSearch.subclass_for(:music)
    assert_nil SavedSearch.subclass_for(:games)
    assert_nil SavedSearch.subclass_for(nil)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/saved_search_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'subclass_for' for SavedSearch`.

- [ ] **Step 3: Add the registry**

In `app/models/saved_search.rb`, immediately after `belongs_to :user`:

```ruby
  # Which STI subclass serves which host. Mirrors UserList::DOMAIN_SUBCLASSES.
  # A domain absent from this map has no saved searches, and the controller
  # 404s rather than rendering an empty page in the wrong layout.
  DOMAIN_SUBCLASSES = {"books" => "Books::SavedSearch"}.freeze

  def self.subclass_for(domain)
    DOMAIN_SUBCLASSES[domain.to_s]&.constantize
  end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/models/saved_search_test.rb`
Expected: PASS.

- [ ] **Step 5: Extract the layout concern**

Create `app/controllers/concerns/domain_layout.rb`:

```ruby
# frozen_string_literal: true

# Picks the per-domain layout for a controller that is NOT inside a
# DomainConstraint -- my_lists and saved_searches both serve every host from
# one route, so the layout can only come from Current.domain at request time.
module DomainLayout
  extend ActiveSupport::Concern

  private

  def resolve_layout
    case Current.domain
    when :games then "games/application"
    when :movies then "movies/application"
    when :books then "books/application"
    else "music/application"
    end
  end
end
```

In `app/controllers/my_lists_controller.rb`, add `include DomainLayout` below `include PathBasedPagination`, and delete the private `resolve_layout` method (lines 87-94) along with its now-orphaned position in the private section. Leave `layout :resolve_layout` exactly as it is.

- [ ] **Step 6: Run the my_lists suite to prove the extraction is behaviour-preserving**

Run: `bin/rails test test/controllers/my_lists_controller_test.rb`
Expected: PASS — it already asserts the games, music, and books layout markers.

- [ ] **Step 7: Lint and commit**

```bash
bin/rails test && bundle exec standardrb --fix app/models/saved_search.rb \
  app/controllers/concerns/domain_layout.rb app/controllers/my_lists_controller.rb
git add app/models/saved_search.rb app/controllers/concerns/domain_layout.rb \
  app/controllers/my_lists_controller.rb test/models/saved_search_test.rb
git commit -m "Resolve a saved-search subclass and a layout from Current.domain"
```

---

## Task 2: `Books::SavedSearchFilterLabels`

The show page names the categories, languages, and countries a search filters on. `#summary` cannot: it is rendered once per row on the index page and is deliberately lookup-free. This object does the lookups — three queries, one per taxonomy — and returns display-ready groups.

**Files:**
- Create: `app/lib/books/saved_search_filter_labels.rb`
- Modify: `app/models/saved_search.rb`
- Modify: `app/models/books/saved_search.rb`
- Test: `test/lib/books/saved_search_filter_labels_test.rb`, `test/models/saved_search_test.rb`, `test/models/books/saved_search_test.rb`

**Interfaces:**
- Consumes: `Books::SavedSearchCriteria` (already shipped in increment 4) — readers `book_type`, `book_length`, `first_year_published_gt/_lt`, `ranked`, `genre_match_mode`, `hide_read`, `max_ranked_position`, `included_/excluded_{category,language,country}_ids`, `unparseable?(key)`, and the constant `UNPARSEABLE_KEYS`. `Books::BookType.label(int)`.
- Produces: `Books::SavedSearchFilterLabels.call(criteria) -> [Group]` where `Group = Struct.new(:label, :values, :note, keyword_init: true)`, `values` is an Array of String and `note` is a String or nil. `Books::SavedSearch.filter_labels_class` → that class; `SavedSearch.filter_labels_class` raises `NotImplementedError`.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/books/saved_search_filter_labels_test.rb`:

```ruby
require "test_helper"
require "active_record/testing/query_assertions"

class Books::SavedSearchFilterLabelsTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  def labels(raw)
    ::Books::SavedSearchFilterLabels.call(::Books::SavedSearchCriteria.new(raw))
  end

  def group(groups, label)
    groups.find { |g| g.label == label }
  end

  test "empty criteria produce no groups" do
    assert_empty labels({})
  end

  test "genre_match_mode alone produces no groups" do
    assert_empty labels({"genre_match_mode" => "any"})
  end

  test "names included categories and explains any-mode" do
    fiction = categories(:books_fiction_genre)
    groups = labels({"included_category_ids" => [fiction.id], "genre_match_mode" => "any"})

    g = group(groups, "Including genres")
    assert_equal [fiction.name], g.values
    assert_equal "Books must have at least one of these genres", g.note
  end

  test "explains all-mode differently" do
    fiction = categories(:books_fiction_genre)
    classics = categories(:books_classics_genre)
    groups = labels({
      "included_category_ids" => [fiction.id, classics.id],
      "genre_match_mode" => "all"
    })

    g = group(groups, "Including genres")
    assert_equal [fiction.name, classics.name].sort, g.values.sort
    assert_equal "Books must have all of these genres", g.note
  end

  test "names excluded categories, languages and countries" do
    groups = labels({
      "excluded_category_ids" => [categories(:books_classics_genre).id],
      "included_language_ids" => [languages(:russian).id],
      "excluded_language_ids" => [languages(:latin).id],
      "included_country_ids" => [books_countries(:french).id],
      "excluded_country_ids" => [books_countries(:japanese).id]
    })

    assert_equal [categories(:books_classics_genre).name], group(groups, "Excluding genres").values
    assert_equal [languages(:russian).name], group(groups, "Including languages").values
    assert_equal [languages(:latin).name], group(groups, "Excluding languages").values
    assert_equal [books_countries(:french).name], group(groups, "Including origins").values
    assert_equal [books_countries(:japanese).name], group(groups, "Excluding origins").values
  end

  # An id the query will match nothing on must not render as an empty card --
  # a search returning zero books needs a filter card that explains why.
  test "an id with no record renders as unknown rather than vanishing" do
    groups = labels({"included_category_ids" => [999_999]})
    assert_equal ["Unknown (#999999)"], group(groups, "Including genres").values
  end

  test "the three taxonomies cost exactly one query each, include and exclude together" do
    raw = {
      "included_category_ids" => [categories(:books_fiction_genre).id],
      "excluded_category_ids" => [categories(:books_classics_genre).id],
      "included_language_ids" => [languages(:russian).id],
      "excluded_language_ids" => [languages(:latin).id],
      "included_country_ids" => [books_countries(:french).id],
      "excluded_country_ids" => [books_countries(:japanese).id]
    }
    assert_queries_count(3) { labels(raw) }
  end

  test "criteria with no ids cost no queries at all" do
    assert_queries_count(0) do
      labels({"book_type" => 0, "ranked" => "true", "hide_read" => true})
    end
  end

  test "renders the scalar criteria" do
    groups = labels({
      "book_type" => 0,
      "book_length" => [0],
      "first_year_published_gt" => 1900,
      "first_year_published_lt" => 1950,
      "ranked" => "true",
      "max_ranked_position" => 500,
      "hide_read" => true
    })

    # book_lengths is {very_short: 0, short: 1, medium: 2, moderate: 3,
    # long: 4, very_long: 5} -- 0 is very_short, not short.
    assert_equal ["Fiction"], group(groups, "Book type").values
    assert_equal ["Very Short"], group(groups, "Book length").values
    assert_equal ["Between 1900 and 1950"], group(groups, "Published").values
    assert_equal ["Only ranked books"], group(groups, "Ranking status").values
    assert_equal ["Top 500"], group(groups, "Ranking limit").values
    assert_equal ["Hiding books the owner has read"], group(groups, "Read books").values
  end

  test "renders an open-ended year bound" do
    assert_equal ["After 1900"],
      group(labels({"first_year_published_gt" => 1900}), "Published").values
    assert_equal ["Before 1950"],
      group(labels({"first_year_published_lt" => 1950}), "Published").values
  end

  # BookAdvanced turns an unparseable criterion into a match-nothing clause
  # (spec §6). The card has to say so, or the page shows zero results under a
  # filter list that looks perfectly satisfiable.
  test "flags a criterion that is present but unreadable" do
    groups = labels({"book_type" => "abc", "included_category_ids" => ["xyz"]})

    g = group(groups, "Unreadable filter")
    assert_equal ["Book type", "Included category ids"].sort, g.values.sort
    assert_equal "This search matches no books until it is edited", g.note
  end

  test "a blank criterion is absent, not unreadable" do
    assert_empty labels({"book_type" => "", "included_category_ids" => [""]})
  end

  test "book_length values outside the enum are dropped by the criteria reader" do
    assert_nil group(labels({"book_length" => [99]}), "Book length")
  end
end
```

Append to `test/models/saved_search_test.rb`:

```ruby
  test "filter_labels_class is abstract on the base class" do
    assert_raises(NotImplementedError) { SavedSearch.filter_labels_class }
  end
```

Append to `test/models/books/saved_search_test.rb`:

```ruby
  test "filter_labels_class resolves the books labels object" do
    assert_equal ::Books::SavedSearchFilterLabels, ::Books::SavedSearch.filter_labels_class
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/books/saved_search_filter_labels_test.rb test/models/saved_search_test.rb test/models/books/saved_search_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::SavedSearchFilterLabels` and `NoMethodError: undefined method 'filter_labels_class'`.

- [ ] **Step 3: Implement the labels object**

Create `app/lib/books/saved_search_filter_labels.rb`:

```ruby
# frozen_string_literal: true

module Books
  # A saved search's criteria as display-ready groups for the show page's
  # active-filters card.
  #
  # This exists because Books::SavedSearch#summary deliberately cannot do it:
  # summary renders once per row on the index page, so naming categories,
  # languages and countries there would be an N+1. Here there is exactly one
  # search on the page, so three queries -- one per taxonomy, include and
  # exclude ids unioned -- is the right trade.
  #
  # An id with no matching record renders as "Unknown (#id)" rather than
  # disappearing. BookAdvanced matches nothing on it, and a card that silently
  # omitted it would leave a zero-result page looking unexplained.
  class SavedSearchFilterLabels
    Group = Struct.new(:label, :values, :note, keyword_init: true)

    ANY_NOTE = "Books must have at least one of these genres"
    ALL_NOTE = "Books must have all of these genres"
    UNREADABLE_NOTE = "This search matches no books until it is edited"

    def self.call(criteria)
      new(criteria).call
    end

    def initialize(criteria)
      @criteria = criteria
    end

    def call
      [
        book_type_group,
        book_length_group,
        ranked_group,
        max_position_group,
        year_group,
        category_group("Including genres", criteria.included_category_ids, genre_note),
        category_group("Excluding genres", criteria.excluded_category_ids, nil),
        language_group("Including languages", criteria.included_language_ids),
        language_group("Excluding languages", criteria.excluded_language_ids),
        country_group("Including origins", criteria.included_country_ids),
        country_group("Excluding origins", criteria.excluded_country_ids),
        hide_read_group,
        unreadable_group
      ].compact
    end

    private

    attr_reader :criteria

    def book_type_group
      label = ::Books::BookType.label(criteria.book_type)
      return nil if label.nil?

      Group.new(label: "Book type", values: [label])
    end

    def book_length_group
      lengths = criteria.book_length
      return nil if lengths.empty?

      Group.new(
        label: "Book length",
        values: lengths.map { |value| ::Books::Book.book_lengths.key(value).to_s.titleize }
      )
    end

    def ranked_group
      value =
        case criteria.ranked
        when :ranked then "Only ranked books"
        when :unranked then "Only unranked books"
        end
      return nil if value.nil?

      Group.new(label: "Ranking status", values: [value])
    end

    def max_position_group
      position = criteria.max_ranked_position
      return nil if position.nil?

      Group.new(label: "Ranking limit", values: ["Top #{position}"])
    end

    def year_group
      gt = criteria.first_year_published_gt
      lt = criteria.first_year_published_lt
      return nil if gt.nil? && lt.nil?

      value =
        if gt && lt then "Between #{gt} and #{lt}"
        elsif gt then "After #{gt}"
        else "Before #{lt}"
        end

      Group.new(label: "Published", values: [value])
    end

    def hide_read_group
      return nil unless criteria.hide_read

      # "the owner", not "you": hide_read filters against the search's owner
      # even when a stranger is reading a public search (spec §6).
      Group.new(label: "Read books", values: ["Hiding books the owner has read"])
    end

    def unreadable_group
      keys = ::Books::SavedSearchCriteria::UNPARSEABLE_KEYS
        .select { |key| criteria.unparseable?(key) }
      return nil if keys.empty?

      Group.new(
        label: "Unreadable filter",
        values: keys.map { |key| key.humanize },
        note: UNREADABLE_NOTE
      )
    end

    def genre_note
      (criteria.genre_match_mode == :all) ? ALL_NOTE : ANY_NOTE
    end

    def category_group(label, ids, note)
      build_group(label, ids, category_names, note)
    end

    def language_group(label, ids)
      build_group(label, ids, language_names, nil)
    end

    def country_group(label, ids)
      build_group(label, ids, country_names, nil)
    end

    def build_group(label, ids, names, note)
      return nil if ids.empty?

      Group.new(label: label, values: ids.map { |id| names[id] || "Unknown (##{id})" }, note: note)
    end

    # One query per taxonomy, unioning the include and exclude ids -- memoized
    # so the include group and the exclude group share it. `|| {}` guards the
    # memo against a legitimately empty result re-querying.
    def category_names
      @category_names ||= name_map(
        ::Category, criteria.included_category_ids | criteria.excluded_category_ids
      )
    end

    def language_names
      @language_names ||= name_map(
        ::Language, criteria.included_language_ids | criteria.excluded_language_ids
      )
    end

    def country_names
      @country_names ||= name_map(
        ::Books::Country, criteria.included_country_ids | criteria.excluded_country_ids
      )
    end

    def name_map(klass, ids)
      return {} if ids.empty?

      klass.where(id: ids).pluck(:id, :name).to_h
    end
  end
end
```

- [ ] **Step 4: Wire the model hook**

In `app/models/saved_search.rb`, next to the other abstract class methods (after `.query_class`):

```ruby
  # Builds the show page's active-filters card. Separate from criteria_class
  # because it hits the database to name categories, languages, and countries,
  # which the criteria object deliberately never does.
  def self.filter_labels_class
    raise NotImplementedError, "#{name} must override .filter_labels_class"
  end
```

In `app/models/books/saved_search.rb`, after `.query_class`:

```ruby
    def self.filter_labels_class_name
      "Books::SavedSearchFilterLabels"
    end

    def self.filter_labels_class
      filter_labels_class_name.constantize
    end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/books/saved_search_filter_labels_test.rb test/models/saved_search_test.rb test/models/books/saved_search_test.rb`
Expected: PASS.

- [ ] **Step 6: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb --fix app/lib/books/saved_search_filter_labels.rb \
  app/models/saved_search.rb app/models/books/saved_search.rb \
  test/lib/books/saved_search_filter_labels_test.rb
git add app/lib/books/saved_search_filter_labels.rb app/models/saved_search.rb \
  app/models/books/saved_search.rb test/lib/books/saved_search_filter_labels_test.rb \
  test/models/saved_search_test.rb test/models/books/saved_search_test.rb
git commit -m "Name a saved search's categories, languages and origins for the filter card"
```

---

## Task 3: Routes, `#index`, and the index view

The first user-visible surface. A signed-in user's searches, newest-run first, paged at 50.

**Files:**
- Create: `app/controllers/saved_searches_controller.rb`
- Create: `app/views/saved_searches/index.html.erb`
- Create: `test/controllers/saved_searches_controller_test.rb`
- Modify: `config/routes.rb` (after the `user_lists` compatibility block, around line 296)

**Interfaces:**
- Consumes: `SavedSearch.subclass_for` and `DomainLayout` (Task 1); `pagy_path` from `PathBasedPagination`.
- Produces: `saved_searches_path`, `saved_searches_page_path(page)`, `saved_search_path(record)`; `SavedSearchesController#domain_class` (private) → the STI subclass.

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/saved_searches_controller_test.rb`:

```ruby
require "test_helper"
require "active_record/testing/query_assertions"

class SavedSearchesControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @user = users(:regular_user)
    @other = users(:admin_user)
    @public_search = saved_searches(:books_public)
    @private_search = saved_searches(:books_private)
    @other_search = saved_searches(:books_other_user)
    host! Rails.application.config.domains[:books]
  end

  # --- index ---

  test "anonymous request to the index redirects to sign in" do
    get saved_searches_path
    assert_redirected_to "/"
  end

  test "index lists only the current user's searches" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path
    assert_response :success

    assert_includes response.body, "Great Russian Novels"
    assert_includes response.body, "Search #{@private_search.id}"  # display_name fallback
    refute_includes response.body, "Someone else&#39;s search"
  end

  test "index orders by last executed, nulls last, then newest created" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    executed = response.body.index("Great Russian Novels")
    never_run = response.body.index("Search #{@private_search.id}")
    assert_operator executed, :<, never_run
  end

  test "index renders the public badge and the last-run time" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_includes response.body, "Public"
    assert_includes response.body, "Last run 2 days ago"
  end

  # result_count is stale by construction and no longer written (spec §6/§9).
  test "index shows no result count" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    refute_includes response.body, "42 results"
  end

  test "index is never cached" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  # summary must stay lookup-free -- it renders once per row.
  test "index does not query per row" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path  # warm the schema and session lookups

    assert_queries_count(4) { get saved_searches_path }
  end

  test "index 404s on a domain with no saved searches" do
    host! Rails.application.config.domains[:music]
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_response :not_found
  end

  test "index renders the books layout" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_includes response.body, 'data-theme="books"'
  end

  test "index page 1 redirects to the bare path" do
    sign_in_as(@user, stub_auth: true)
    get "/searches/page/1"

    assert_redirected_to "/searches"
    assert_equal 301, response.status
  end
end
```

`assert_queries_count(4)` is a starting guess — one session/user lookup, one count, one page, plus whatever the layout does. Run it, read the actual number from the failure message, and pin *that* number. Do not relax the assertion into a `<=`; the point is to notice when it changes.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'saved_searches_path'`.

- [ ] **Step 3: Add the read routes**

In `config/routes.rb`, immediately after the `user_lists/:id/page/:page` line (~line 296) and before the `# Domain-specific roots using Default controllers` comment:

```ruby
  # Saved searches -- global, never cached, per-domain layout resolved from
  # Current.domain in the controller. index is owner-only; show serves the
  # owner or any viewer when the search is public (404s otherwise via
  # SavedSearch.visible_to). The write actions are increment 6: a route
  # pointing at an action that does not exist yet is a 500, not a 404, and
  # `searches/new` falls through to a clean 404 while :id stays \d+-constrained.
  get "searches", to: "saved_searches#index", as: :saved_searches
  get "searches/page/1", to: redirect("/searches", status: 301)
  get "searches/page/:page", to: "saved_searches#index", as: :saved_searches_page,
    constraints: {page: /\d+/}
```

Order matters: `searches/page/1` must precede `searches/page/:page`, exactly as the books lists routes do.

- [ ] **Step 4: Write the controller**

Create `app/controllers/saved_searches_controller.rb`:

```ruby
# Saved searches, ported from the legacy books site (spec
# 2026-08-08-books-saved-searches-design.md). Global routes, no
# DomainConstraint: Current.domain picks the STI subclass, so games gets
# /searches on its own host later without a new controller.
#
# index is owner-only. show serves the owner or any viewer -- including
# anonymous -- when the search is public, and 404s everything else through
# SavedSearch.visible_to rather than 403ing, which would confirm the id exists.
#
# Never cached: these pages are per-user AND write last_executed_at on read.
class SavedSearchesController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include DomainLayout

  # Fixed, with no ?limit= escape hatch -- legacy honoured one, which makes the
  # page space unbounded. 50 also divides OpenSearch's 10,000-result window
  # exactly, so the last reachable page is full rather than short (spec §5.4).
  PER_PAGE = 50

  layout :resolve_layout

  # Before require_signed_in!, so /searches on a host with no saved searches
  # 404s instead of bouncing an anonymous visitor to a sign-in that would not
  # have helped.
  before_action :require_domain_support!
  before_action :require_signed_in!, only: [:index]
  before_action :prevent_caching

  # GET /searches(/page/:page)
  def index
    @pagy, @searches = pagy_path(
      domain_class.owned_by(current_user).by_last_executed.by_created,
      limit: PER_PAGE
    )
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
```

- [ ] **Step 5: Write the index view**

Create `app/views/saved_searches/index.html.erb`:

```erb
<%
  content_for :page_title, "My Saved Searches | #{domain_name}"
%>

<div class="space-y-6">
  <h1 class="text-3xl font-bold">My Saved Searches</h1>

  <% if @searches.any? %>
    <ul class="space-y-3" data-testid="saved-search-list">
      <% @searches.each do |search| %>
        <li>
          <%= link_to saved_search_path(search),
                class: "card bg-base-100 shadow-sm hover:shadow-md transition-shadow" do %>
            <div class="card-body gap-1">
              <h2 class="card-title text-lg"><%= search.display_name %></h2>
              <% if search.description.present? %>
                <p class="text-sm text-base-content/70"><%= search.description %></p>
              <% end %>
              <% if search.summary.present? %>
                <p class="text-sm text-base-content/60"><%= search.summary %></p>
              <% end %>
              <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
                <% if search.public? %>
                  <span class="badge badge-sm badge-info">Public</span>
                <% end %>
                <% if search.last_executed_at %>
                  <span>Last run <%= time_ago_in_words(search.last_executed_at) %> ago</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </li>
      <% end %>
    </ul>

    <% if @pagy.pages > 1 %>
      <div class="flex justify-center"><%== @pagy.series_nav(slots: 5) %></div>
    <% end %>
  <% else %>
    <div class="text-center py-16" data-testid="empty-saved-searches">
      <p class="text-base-content/70">You haven't saved any searches yet.</p>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: PASS, except `assert_queries_count(4)` if the real number differs — read the count from the failure and pin it.

- [ ] **Step 7: Run the full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: PASS, 5,951 runs plus the new ones, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/saved_searches_controller.rb \
  app/views/saved_searches/index.html.erb test/controllers/saved_searches_controller_test.rb
git commit -m "List a user's saved searches at /searches"
```

---

## Task 4: `#show`, `pagy_path_count`, and the results page

The increment's payload. `show` runs the increment-4 query layer and renders one page of books.

**Files:**
- Modify: `app/controllers/concerns/path_based_pagination.rb`
- Modify: `app/lib/books/saved_search_query.rb:20`
- Modify: `app/controllers/saved_searches_controller.rb`
- Modify: `config/routes.rb`
- Create: `app/views/saved_searches/show.html.erb`
- Create: `app/views/saved_searches/books/_active_filters.html.erb`
- Create: `app/views/saved_searches/books/_results.html.erb`
- Modify: `test/fixtures/saved_searches.yml:33`
- Test: `test/controllers/saved_searches_controller_test.rb`

**Interfaces:**
- Consumes: `Books::SavedSearchQuery.call(criteria:, owner:, ranking_configuration: nil, page:, per_page:) -> Result(books:, total:)`; `Books::SavedSearchFilterLabels.call(criteria) -> [Group]` (Task 2); `Books::CardComponent.new(book:, rank:, index:)` and `Books::CardComponent::GRID_CONTAINER_CLASS`.
- Produces: `PathBasedPagination#pagy_path_count(count, **options) -> Pagy::Offset`; `Books::SavedSearchQuery::Result#capped?`; `saved_search_path(record)`, `saved_search_page_path(record, page)`.

- [ ] **Step 1: Point the `books_public` fixture at a real language**

`test/fixtures/saved_searches.yml:33` reads `criteria: { "genre_match_mode": "any", "included_language_ids": [12] }`. Id 12 matches no `languages` fixture, so the filter card would render "Unknown (#12)" and the test below could not assert a real name. Nothing currently asserts on this criteria hash — the inc-3 model and policy tests use the fixture only for `display_name`, `public`, and `visible_to` — so it is safe to change:

```yaml
  criteria: { "genre_match_mode": "any", "included_language_ids": [<%= ActiveRecord::FixtureSet.identify(:russian) %>] }
```

Run `bin/rails test test/models/saved_search_test.rb test/policies/saved_search_policy_test.rb` afterwards to confirm nothing depended on the old value.

- [ ] **Step 2: Write the failing tests**

Append to `test/controllers/saved_searches_controller_test.rb`:

```ruby
  # --- show ---

  # BookAdvanced is stubbed, per house style -- the query layer has its own
  # tests against a real test index. These tests are about the controller.
  def stub_advanced(ids:, total:)
    ::Search::Books::Search::BookAdvanced.stubs(:call).returns({ids: ids, total: total})
  end

  test "the owner sees a private search" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    sign_in_as(@user, stub_auth: true)
    get saved_search_path(@private_search)

    assert_response :success
    assert_includes response.body, "War and Peace"
  end

  test "anonymous visitors see a public search" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    get saved_search_path(@public_search)

    assert_response :success
    assert_includes response.body, "Great Russian Novels"
  end

  test "a private search 404s for another user" do
    sign_in_as(@other, stub_auth: true)
    get saved_search_path(@private_search)

    assert_response :not_found
  end

  test "a private search 404s for an anonymous visitor" do
    get saved_search_path(@private_search)

    assert_response :not_found
  end

  test "show renders the active-filters card with named taxonomies" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_includes response.body, "Active filters"
    assert_includes response.body, "Including languages"
    assert_includes response.body, languages(:russian).name
  end

  test "show renders an empty state when nothing matches" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_response :success
    assert_includes response.body, "No books match this search"
  end

  test "show reports the total" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    get saved_search_path(@public_search)

    assert_includes response.body, "1 result"
  end

  test "a total at the window ceiling renders as 10,000+" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 10_000)
    get saved_search_path(@public_search)

    assert_includes response.body, "10,000+ results"
  end

  test "show writes last_executed_at, without touching updated_at" do
    stub_advanced(ids: [], total: 0)
    before = @public_search.updated_at
    travel_to 1.hour.from_now do
      get saved_search_path(@public_search)
    end

    @public_search.reload
    assert_operator @public_search.last_executed_at, :>, 1.minute.ago
    assert_equal before.to_i, @public_search.updated_at.to_i
  end

  test "a page past the last one 404s and records no execution" do
    stub_advanced(ids: [], total: 50)
    before = @public_search.last_executed_at
    get saved_search_page_path(@public_search, 3)

    assert_response :not_found
    assert_equal before.to_i, @public_search.reload.last_executed_at.to_i
  end

  # Legacy paged with ?page=N. Those links must keep working, and both forms
  # must land on the same page -- pagy_path_request merges query params with
  # the route's :page and Rails' params[:page] prefers the route segment, so
  # the page the controller sends OpenSearch and the page pagy renders agree.
  # Asserted through the rendered nav rather than a Mocha argument matcher,
  # which would have to match keyword args and is brittle about it.
  test "the path and query forms of a page resolve identically" do
    stub_advanced(ids: [], total: 500)

    get saved_search_page_path(@public_search, 2)
    assert_response :success
    assert_includes response.body, "Page 2 of 10"
    assert_includes response.body, "/searches/#{@public_search.id}/page/3"

    get "#{saved_search_path(@public_search)}?page=2"
    assert_response :success
    assert_includes response.body, "Page 2 of 10"
    # The nav canonicalises the query-string URL into the path form.
    assert_includes response.body, "/searches/#{@public_search.id}/page/3"
  end

  test "show page 1 redirects to the bare path" do
    get "/searches/#{@public_search.id}/page/1"

    assert_redirected_to "/searches/#{@public_search.id}"
    assert_equal 301, response.status
  end

  test "show is never cached" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "show is noindex" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_includes response.body, 'name="robots" content="noindex, follow"'
  end

  # The grid renders authors and a cover per book -- the exact N+1 shape.
  test "show does not query per result book" do
    ids = [books_books(:war_and_peace).id, books_books(:crime_and_punishment).id]
    stub_advanced(ids: ids, total: 2)
    get saved_search_path(@public_search)  # warm

    stub_advanced(ids: ids, total: 2)
    assert_queries_count(8) { get saved_search_path(@public_search) }
  end

  test "show 404s on a domain with no saved searches" do
    host! Rails.application.config.domains[:music]
    get saved_search_path(@public_search)

    assert_response :not_found
  end
```

As in Task 3, `assert_queries_count(8)` is a starting guess. Run it, read the real number, pin it — then delete one book from the stubbed ids and confirm the count does *not* drop, which is what proves there is no per-book query.

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: FAIL — `undefined local variable or method 'saved_search_path'`.

- [ ] **Step 4: Add `pagy_path_count`**

In `app/controllers/concerns/path_based_pagination.rb`, after `pagy_path`:

```ruby
  # pagy_path's sibling for a collection the caller has already paged. A saved
  # search's page is sized by OpenSearch, so there is nothing left for pagy to
  # slice and no relation for it to count -- it only needs to build the nav.
  #
  # Pagy's OffsetPaginator honours a pre-set :count (`options[:count] ||=`), so
  # passing an empty collection never triggers a count query; the records it
  # hands back are discarded and the caller renders its own. The bounds check is
  # pagy_path's, for the same reason: pagy serves an empty 200 past the last
  # page, which is an unbounded space of thin pages.
  def pagy_path_count(count, **options)
    pagy, _records = pagy(:offset, [], count: count, **options, **pagy_path_options)
    raise ActiveRecord::RecordNotFound if pagy.page > pagy.last

    pagy
  end
```

- [ ] **Step 5: Add `Result#capped?`**

In `app/lib/books/saved_search_query.rb`, replace the `Result` line:

```ruby
    # `capped?` because track_total_hits stays at OpenSearch's default of
    # 10,000 (spec §6): a broader search reports exactly 10,000 and means "at
    # least". The knowledge of which number that is belongs next to the query,
    # not in a controller or a view.
    Result = Struct.new(:books, :total, keyword_init: true) do
      def capped?
        total >= ::Search::Books::Search::BookAdvanced::MAX_RESULT_WINDOW
      end
    end
```

- [ ] **Step 6: Add the show routes**

In `config/routes.rb`, directly after the `searches/page/:page` line from Task 3:

```ruby
  get "searches/:id", to: "saved_searches#show", as: :saved_search,
    constraints: {id: /\d+/}
  get "searches/:id/page/1", to: redirect("/searches/%{id}", status: 301),
    constraints: {id: /\d+/}
  get "searches/:id/page/:page", to: "saved_searches#show", as: :saved_search_page,
    constraints: {id: /\d+/, page: /\d+/}
```

- [ ] **Step 7: Add the show action**

In `app/controllers/saved_searches_controller.rb`, after `index`:

```ruby
  # GET /searches/:id(/page/:page)
  #
  # Reachable anonymously for a public search. Scoped through visible_to, which
  # 404s a private search for anyone but its owner -- Pundit's rescue would
  # redirect, confirming the id exists.
  def show
    @search = domain_class.visible_to(current_user).find(params[:id])
    authorize @search, :show?, policy_class: SavedSearchPolicy
    @owner = @search.user_id == current_user&.id

    result = domain_class.query_class.call(
      # criteria_object, never the raw hash: the readers absorb both the
      # migrated storage shapes and form params. owner:, never current_user:
      # hide_read filters against whoever saved the search, which is what keeps
      # a public search's results stable for its owner (spec §6).
      criteria: @search.criteria_object,
      owner: @search.user,
      page: [params[:page].to_i, 1].max,
      per_page: PER_PAGE
    )

    # Before the last_executed_at write: this raises RecordNotFound past the
    # last page, and a 404 is not an execution.
    @pagy = pagy_path_count(result.total, limit: PER_PAGE)
    @books = result.books
    @total_capped = result.capped?
    @filter_groups = domain_class.filter_labels_class.call(@search.criteria_object)

    # A write on a read, and the only one in the app. It drives the index
    # page's default ordering. update_column so a read never bumps updated_at
    # and no callback fires. Legacy recorded this for any viewer, including a
    # stranger reading a public search; that is preserved.
    @search.update_column(:last_executed_at, Time.current)
  end
```

- [ ] **Step 8: Write the show views**

Create `app/views/saved_searches/show.html.erb`:

```erb
<%
  content_for :page_title, "#{@search.display_name} - Saved Search | #{domain_name}"
  total = @total_capped ? "10,000+ results" :
    "#{number_with_delimiter(@pagy.count)} #{"result".pluralize(@pagy.count)}"
%>

<div class="space-y-6">
  <div class="space-y-1">
    <% if @owner %>
      <%= link_to saved_searches_path,
            class: "text-sm text-base-content/60 hover:text-primary",
            data: {testid: "back-to-searches"} do %>
        ← My Saved Searches
      <% end %>
    <% end %>
    <h1 class="text-3xl font-bold"><%= @search.display_name %></h1>
    <% if @search.description.present? %>
      <p class="text-base-content/70"><%= @search.description %></p>
    <% end %>
    <% if !@owner && @search.user.display_name.present? %>
      <p class="text-sm text-base-content/60" data-testid="search-owner">
        A saved search by <%= @search.user.display_name %>
      </p>
    <% end %>
  </div>

  <%= render "saved_searches/#{Current.domain}/active_filters", groups: @filter_groups %>

  <p class="text-sm text-base-content/70" data-testid="saved-search-total"><%= total %></p>

  <%= render "saved_searches/#{Current.domain}/results", books: @books %>

  <% if @pagy.pages > 1 %>
    <div class="flex justify-center"><%== @pagy.series_nav(slots: 5) %></div>
    <p class="text-center text-sm text-base-content/70">
      Page <%= number_with_delimiter(@pagy.page) %> of <%= number_with_delimiter(@pagy.last) %>
    </p>
  <% end %>
</div>
```

Create `app/views/saved_searches/books/_active_filters.html.erb`:

```erb
<% if groups.any? %>
  <div class="card bg-base-100 shadow-sm" data-testid="active-filters">
    <div class="card-body">
      <h2 class="card-title text-lg">Active filters</h2>
      <dl class="grid gap-x-6 gap-y-4 sm:grid-cols-2 lg:grid-cols-3">
        <% groups.each do |group| %>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              <%= group.label %>
            </dt>
            <dd class="mt-1 flex flex-wrap gap-1">
              <% group.values.each do |value| %>
                <span class="badge badge-outline"><%= value %></span>
              <% end %>
            </dd>
            <% if group.note.present? %>
              <p class="mt-1 text-xs text-base-content/60"><%= group.note %></p>
            <% end %>
          </div>
        <% end %>
      </dl>
    </div>
  </div>
<% end %>
```

Create `app/views/saved_searches/books/_results.html.erb`:

```erb
<% if books.any? %>
  <div class="<%= Books::CardComponent::GRID_CONTAINER_CLASS %>">
    <% books.each_with_index do |book, index| %>
      <%= render Books::CardComponent.new(book: book, rank: book.ranked_position, index: index) %>
    <% end %>
  </div>
<% else %>
  <div class="text-center py-16" data-testid="empty-saved-search-results">
    <p class="text-base-content/70">No books match this search.</p>
  </div>
<% end %>
```

- [ ] **Step 9: Run the tests**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: PASS, except the two `assert_queries_count` guesses — pin the real numbers.

- [ ] **Step 10: Run the full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: 0 failures.

- [ ] **Step 11: Commit**

```bash
git add config/routes.rb app/controllers/saved_searches_controller.rb \
  app/controllers/concerns/path_based_pagination.rb app/lib/books/saved_search_query.rb \
  app/views/saved_searches/ test/fixtures/saved_searches.yml \
  test/controllers/saved_searches_controller_test.rb
git commit -m "Render a saved search's results at /searches/:id"
```

---

## Task 5: Legacy `/v/:view_type` URLs and robots

Legacy wrapped `resources :searches` in `scope "(/v/:view_type)"`. Those URLs are bookmarked and must not 404.

**Files:**
- Modify: `config/routes.rb`
- Modify: `public/robots.txt`
- Test: `test/controllers/saved_searches_controller_test.rb`

**Interfaces:**
- Consumes: `saved_search_path` (Task 4). Produces no new helpers — these routes are unnamed, like every other legacy redirect in this app.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/saved_searches_controller_test.rb`:

```ruby
  # --- legacy /v/:view_type URLs ---
  #
  # Legacy's BookListViewComponent emitted exactly two prefixes, /v/grid and
  # /v/table; its "List" button linked to the bare path. All three views now
  # render the same card grid (spec §9), so these 301 rather than rendering --
  # there is no bookmarked view left to discard.

  test "the legacy view-prefixed index 301s to /searches" do
    get "/v/grid/searches"
    assert_redirected_to "/searches"
    assert_equal 301, response.status
  end

  test "a legacy grid URL 301s to the canonical search" do
    get "/v/grid/searches/#{@public_search.id}"
    assert_redirected_to "/searches/#{@public_search.id}"
    assert_equal 301, response.status
  end

  test "a legacy table URL 301s and carries the page number through" do
    get "/v/table/searches/#{@public_search.id}/page/3"
    assert_redirected_to "/searches/#{@public_search.id}/page/3"
    assert_equal 301, response.status
  end

  # Unconstrained, /v/<anything>/searches/1 is an unbounded space of soft
  # duplicates -- the same reasoning the browse routes' sort/filter constraints
  # document. /v/list was never a legacy URL.
  test "an unknown view type 404s" do
    get "/v/list/searches/#{@public_search.id}"
    assert_response :not_found

    get "/v/anything/searches/#{@public_search.id}"
    assert_response :not_found
  end
```

And a robots assertion in `test/controllers/books/` — append to whichever existing test covers `public/robots.txt`, or if none exists, add to this file:

```ruby
  test "robots.txt disallows /searches" do
    assert_includes Rails.root.join("public/robots.txt").read, "Disallow: /searches"
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: FAIL — the `/v/…` requests raise `ActionController::RoutingError` (surfacing as 404 for the 301 tests, which is the wrong status).

- [ ] **Step 3: Add the legacy routes**

In `config/routes.rb`, directly after the `searches/:id/page/:page` route:

```ruby
  # Legacy `scope "(/v/:view_type)" { resources :searches }`. These 301 rather
  # than rendering: increment 5 dropped the view switcher, so grid, table and
  # the bare path all resolve to the same card grid and a redirect costs the
  # reader nothing while saving two duplicate URLs and two code paths. The page
  # number carries through -- an approximation either way, since legacy's grid
  # and table paged at 120 and this pages at 50.
  get "v/:view_type/searches", to: redirect("/searches", status: 301),
    constraints: {view_type: /grid|table/}
  get "v/:view_type/searches/:id", to: redirect("/searches/%{id}", status: 301),
    constraints: {view_type: /grid|table/, id: /\d+/}
  get "v/:view_type/searches/:id/page/:page",
    to: redirect("/searches/%{id}/page/%{page}", status: 301),
    constraints: {view_type: /grid|table/, id: /\d+/, page: /\d+/}
```

- [ ] **Step 4: Disallow /searches in robots.txt**

In `public/robots.txt`, add below the `/user_lists` line:

```
Disallow: /searches
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/saved_searches_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Hand-check the legacy URLs against the real dev corpus**

This is the increment's stated verification (spec §12: "hand-typed legacy URLs"), and increment 4's review is the reason it is not optional — three bugs survived a green fixture suite and only appeared against the real 126k index.

Start the server (`bin/dev` self-terminates in an agent shell; use these two):

```bash
yarn build:all
bin/rails server
```

Sign in as a user who owns migrated searches, then walk these by hand, checking the rendered books and not just the status code:

| URL | Expect |
|---|---|
| `/searches` | the user's searches, newest-run first |
| `/searches/<id>` of a search with `included_category_ids` | results, named genres in the card |
| `/searches/<id>` of a search with `book_type` set | results narrowed to that type |
| `/searches/<id>` of a search with only `genre_match_mode` | "10,000+ results" |
| `/searches/<id>/page/200` of that same search | the last full page, 50 books, no 500 |
| `/searches/<id>/page/201` | 404 |
| `/searches/<id>?page=2` | page 2, and the nav links point at `/page/3` |
| `/v/grid/searches/<id>` | 301 to `/searches/<id>` |
| `/v/table/searches/<id>/page/3` | 301 to `/searches/<id>/page/3` |
| `/searches/<id>` of a search with `hide_read` | fewer results than the same criteria without it |
| `/searches/<id>` of another user's private search | 404 |

Check what is actually listening on port 3000 before trusting any of this.

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add config/routes.rb public/robots.txt test/controllers/saved_searches_controller_test.rb
git commit -m "Keep legacy /v/grid and /v/table search URLs resolving"
```

---

## Task 6: Navigation

Without this, `/searches` is reachable only by bookmark. The link ships hidden and is revealed client-side once sign-in is detected, the same way My Lists is — the navbar has to stay CDN-cacheable.

**Files:**
- Modify: `app/views/layouts/books/application.html.erb:40, 54`
- Modify: `app/javascript/controllers/user_list_state_controller.js:53-60`
- Modify: `app/assets/builds/*` (regenerated, committed)

**Interfaces:**
- Consumes: nothing. Produces: a `#navbar_my_searches` element revealed by `_updateMyListsNav`.

- [ ] **Step 1: Add the nav item to both menus**

In `app/views/layouts/books/application.html.erb`, after each of the two `navbar_my_lists` lines (the mobile dropdown at ~line 40 and the desktop menu at ~line 54):

```erb
            <li id="navbar_my_searches" class="hidden"><a href="/searches">My Searches</a></li>
```

Match the surrounding indentation — the two sites differ by two spaces.

- [ ] **Step 2: Reveal it from the Stimulus controller**

In `app/javascript/controllers/user_list_state_controller.js`, change the selector and the comment in `_updateMyListsNav`:

```javascript
  // Reveals/hides the signed-in-only nav links. They ship hidden in cached
  // HTML and are revealed client-side once sign-in is detected — same approach
  // as the Login/Logout toggle — so the navbar stays CDN-cacheable.
  // querySelectorAll covers both the mobile and desktop menu copies.
  _updateMyListsNav(visible) {
    document.querySelectorAll("#navbar_my_lists, #navbar_my_searches").forEach((el) => {
      el.classList.toggle("hidden", !visible)
    })
  }
```

- [ ] **Step 3: Rebuild the bundles**

The built JS is committed to the repo, so a source-only change ships nothing.

Run: `yarn build:all`

- [ ] **Step 4: Verify the built output changed**

Run: `git diff --stat app/assets/builds/`
Expected: `application.js`, `books.js`, `games.js`, `movies.js`, `music.js` and their maps all show as modified, and `grep -c navbar_my_searches app/assets/builds/application.js` returns at least 1.

- [ ] **Step 5: Confirm in the browser**

With the server running, load `/` on the books host signed out — no "My Searches" in either menu. Sign in — it appears in both the desktop menu and the mobile dropdown, and clicking it lands on `/searches`.

- [ ] **Step 6: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add app/views/layouts/books/application.html.erb \
  app/javascript/controllers/user_list_state_controller.js app/assets/builds/
git commit -m "Link My Searches from the books navbar"
```

---

## Task 7: Documentation and PR

**Files:**
- Modify: `docs/` class documentation per the repo's convention (check `CLAUDE.md` for which files a new controller/PORO requires)

- [ ] **Step 1: Write the class documentation**

Check `CLAUDE.md` for the documentation convention, then document `SavedSearchesController`, `Books::SavedSearchFilterLabels`, and the `DomainLayout` concern to match how `MyListsController` and `Books::SavedSearchQuery` are documented.

- [ ] **Step 2: Final gate**

```bash
bin/rails test && bundle exec standardrb
```

Both must be clean. CI eager-loads (`CI=true`), which is stricter than a local run — if anything is going to surface a constant-resolution problem, it is that.

- [ ] **Step 3: Open the PR**

```bash
git push -u origin worktree-books-saved-searches-inc5
gh pr create --title "Books saved searches, increment 5: controller and views" --body "..."
```

The body should record: the four spec deviations (no view switcher, `/v/…` 301s instead of rendering, write routes deferred to increment 6, index pagination added), the hand-checked legacy URL table from Task 5 Step 6 with its actual results, and the fact that this increment needs **no production action after deploy** — no migration, no rake task, no reindex.

Two gotchas on merging: `main` has two overlapping merge gates, so a PR can show green checks and still be `BLOCKED` on unresolved bot review threads; and merging to `main` deploys to production.

---

## Self-Review

**Spec coverage.** §8 routes → Tasks 3, 4, 5. §8 `require_signed_in!` / `prevent_caching` / robots → Tasks 3, 5. §8 domain 404 → Tasks 3, 4. §8 `?page=N` → Task 4. §9 index → Task 3. §9 show + active filters → Tasks 2, 4. §9 view switcher → deliberately dropped, recorded in the spec. §6 `last_executed_at` on view → Task 4. §6 `result_count` not written → Task 3 asserts its absence. §11 controller cases → Tasks 3, 4, 5. §11 `assert_queries_count` → Tasks 3, 4. §12's "hand-typed legacy URLs" → Task 5 Step 6. Out of scope by increment: new/edit/create/update/destroy (6), Playwright (7).

**Known gaps, deliberate.** The two `assert_queries_count` numbers are guesses to be pinned on first run — stated in the steps rather than hidden. Task 7's documentation step defers to `CLAUDE.md` rather than naming files, because the convention is recorded there and duplicating it here would be the thing that goes stale.
