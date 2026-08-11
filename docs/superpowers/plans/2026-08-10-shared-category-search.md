# Shared Category Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace two drifted category-search implementations with one shared query, and give the public side the type label the admin side has always had.

**Architecture:** A top-level `CategorySearchQuery` takes the category scope to search, an optional list of `category_type`s, and a limit. `Admin::CategoriesBaseController#search` and `Books::FiltersController#render_pane_results` both call it; `Books::CategorySearchQuery` is deleted. A `Category#name_with_type` method makes `"Americana (Genre)"` a single definition shared by the admin JSON, the filter-modal rows, and the picker a later increment will build.

**Tech Stack:** Rails 8, ViewComponent, Minitest + fixtures, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-10-shared-category-search-design.md`. Read §1 and §7 before starting — the single most important fact in this change is a thing you must *not* do.

## Global Constraints

- **The books filter modal's Category axis returns genres, subjects AND settings on purpose. Do not scope it.** Its placeholder reads "Search genres, subjects, settings"; `e2e/tests/books/filters.spec.ts` asserts a `new york` search (a setting) returns rows; and `test/lib/books/category_search_query_test.rb` has a test literally named *"returns every category type, not just genres"*. This change adds a **label** to those results and changes nothing about which rows come back.
- Ruby lint is `bundle exec standardrb`, NEVER `bin/rubocop`.
- Do NOT run `bin/brakeman`.
- Never run destructive database commands against development. Tests only — never `ActiveRecord::FixtureSet.create_fixtures`, which truncates every table it names.
- Every commit must leave `bin/rails test` green. Run the full suite once before committing, not after every edit. CI eager-loads (`CI=true`), which is stricter than a local run.
- Root-anchor constants inside nested namespaces (`::Books::Category`, not `Books::Category`, when inside a `Books::` scope).
- The admin search JSON shape `{value:, text:}` is a contract with `AutocompleteComponent`'s `value_key`/`display_key` defaults. Changing it breaks every admin category picker at once.
- Do not touch anything to do with the movies domain.
- **Do NOT push and do NOT open a pull request.** That is the branch owner's decision.
- Work from `/home/shane/dev/the-greatest/.claude/worktrees/shared-category-search`, branch `worktree-shared-category-search`. Run Rails/yarn commands from `web-app/`; `docs/` is at the project root.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `app/lib/category_search_query.rb` | The one category search: scope + optional types + limit |
| `test/lib/category_search_query_test.rb` | Its unit tests |

**Modify:**

| File | Change |
|---|---|
| `app/models/category.rb` | `#name_with_type` |
| `test/models/category_test.rb` | Its tests |
| `test/fixtures/categories.yml` | Three categories sharing a name prefix, one per type |
| `app/controllers/admin/categories_base_controller.rb` | `#search` delegates to the query and the label |
| `app/controllers/books/filters_controller.rb` | Calls the shared query for the category axis |
| `app/components/books/filter_option_rows_component*` | Renders the type on a search result row |
| `e2e/tests/books/filters.spec.ts` | One assertion that a result shows its type |

**Delete:**

| File | Why |
|---|---|
| `app/lib/books/category_search_query.rb` | No callers after Task 3 |
| `test/lib/books/category_search_query_test.rb` | Its cases move to the shared query's test |

---

## Task 1: The shared query and the label

**Files:**
- Create: `app/lib/category_search_query.rb`
- Create: `test/lib/category_search_query_test.rb`
- Modify: `app/models/category.rb`, `test/models/category_test.rb`, `test/fixtures/categories.yml`

**Interfaces:**
- Produces: `CategorySearchQuery.call(query, scope:, types: [], limit: 10) -> [Category]`, and `Category#name_with_type -> String`.
- Consumes: `Category.active`, `Category.search_by_name` (both already exist, `app/models/category.rb:63`).

- [ ] **Step 1: Add the fixtures, and deal with the fallout first**

Three categories sharing the `Americ` prefix, one per type, with distinct `item_count`s so the same fixtures also pin ordering. Append to `test/fixtures/categories.yml`:

```yaml
# Three types sharing a name prefix, so a type filter can be proven to filter
# and ordering can be proven to order. Without an overlap like this, a
# types: [:genre] test passes whether or not the filter is implemented.
books_american_history_subject:
  type: "Books::Category"
  name: "American History"
  slug: "american-history"
  description: "Books about American history"
  category_type: 2  # subject
  alternative_names: []
  item_count: 1948
  deleted: false
  parent:

books_americana_genre:
  type: "Books::Category"
  name: "Americana"
  slug: "americana"
  description: "Americana"
  category_type: 0  # genre
  alternative_names: []
  item_count: 1634
  deleted: false
  parent:

books_american_location:
  type: "Books::Category"
  name: "American"
  slug: "american-setting"
  description: "Books set in America"
  category_type: 1  # location
  alternative_names: []
  item_count: 705
  deleted: false
  parent:
```

Adding category fixtures changes counts that other tests assert on. **Before writing any other code**, run the suite and fix whatever these three rows broke:

```bash
bin/rails test
```

These eight files reference category counts and are the likely casualties: `test/lib/services/books_migration/category_migrator_test.rb`, `test/lib/books/browse_query_test.rb`, `test/lib/categories/updater_test.rb`, `test/controllers/admin/games/categories_controller_test.rb`, `test/controllers/admin/books/categories_controller_test.rb`, `test/controllers/admin/music/viewer_permission_test.rb`, `test/controllers/admin/music/categories_controller_test.rb`, `test/models/category_item_test.rb`.

Fix each by correcting the expected number — do NOT weaken an exact assertion into `assert_operator :>=`. If a failure looks like something other than a count shifting by three, stop and report it.

- [ ] **Step 2: Write the failing tests**

Create `test/lib/category_search_query_test.rb`:

```ruby
require "test_helper"

class CategorySearchQueryTest < ActiveSupport::TestCase
  def search(query, **options)
    CategorySearchQuery.call(query, scope: Books::Category, **options)
  end

  test "returns nothing for a blank query" do
    assert_empty search("")
    assert_empty search(nil)
    assert_empty search("   ")
  end

  test "matches on a name substring, regardless of case" do
    assert_includes search("fict"), categories(:books_fiction_genre)
    assert_includes search("FICT"), categories(:books_fiction_genre)
  end

  # The Category axis of the books filter modal depends on this. See the spec's
  # landmines: scoping this by default would break two Playwright tests.
  test "returns every category type when no types are given" do
    results = search("americ", limit: 100)

    assert_includes results, categories(:books_americana_genre)
    assert_includes results, categories(:books_american_history_subject)
    assert_includes results, categories(:books_american_location)
  end

  test "types: narrows to one category_type" do
    results = search("americ", types: [:genre], limit: 100)

    assert_equal [categories(:books_americana_genre)], results
  end

  test "types: accepts several category_types" do
    results = search("americ", types: [:genre, :location], limit: 100)

    assert_includes results, categories(:books_americana_genre)
    assert_includes results, categories(:books_american_location)
    assert_not_includes results, categories(:books_american_history_subject)
  end

  # item_count DESC, not alphabetical: on a table this size the popular match
  # is nearly always the one meant.
  test "orders by item_count descending" do
    results = search("americ", limit: 100)

    assert_equal(
      [categories(:books_american_history_subject), categories(:books_americana_genre), categories(:books_american_location)],
      results.first(3)
    )
  end

  # Searches "retired", the fixture's actual name -- searching "deleted" would
  # match nothing and pass even if `.active` were dropped. The fixture also has
  # the highest item_count of any category (9999), so without `.active` it
  # would not merely appear, it would sort first.
  test "excludes soft-deleted categories" do
    results = search("retired", limit: 100)

    assert_not_includes results, categories(:books_deleted_genre)
    assert_empty results
  end

  test "honours limit" do
    assert_equal 2, search("americ", limit: 2).size
  end

  test "scope: keeps another domain's categories out" do
    results = CategorySearchQuery.call("rock", scope: Books::Category, limit: 100)

    assert_not_includes results, categories(:music_rock_genre)
  end
end
```

Append to `test/models/category_test.rb`:

```ruby
  test "name_with_type labels the category's type" do
    assert_equal "Fiction (Genre)", categories(:books_fiction_genre).name_with_type
    assert_equal "Politics (Subject)", categories(:books_politics_subject).name_with_type
    assert_equal "France (Location)", categories(:books_france_location).name_with_type
  end

  # The column is `default: 0` but nullable (db/schema.rb:224), so this is
  # reachable; the admin JSON has always guarded it.
  test "name_with_type says Unknown when the category has no type" do
    category = categories(:books_fiction_genre)
    category.update_column(:category_type, nil)

    assert_equal "Fiction (Unknown)", category.reload.name_with_type
  end
```

- [ ] **Step 3: Run them and watch them fail**

Run: `bin/rails test test/lib/category_search_query_test.rb test/models/category_test.rb`
Expected: FAIL — `NameError: uninitialized constant CategorySearchQuery`, and `NoMethodError: undefined method 'name_with_type'`.

- [ ] **Step 4: Implement**

Create `app/lib/category_search_query.rb`:

```ruby
# frozen_string_literal: true

# Searches one domain's categories by name.
#
# Replaces two independent implementations that had drifted apart on ordering,
# limit, blank-query handling, and whether a result says what type it is:
# Admin::CategoriesBaseController#search (cross-domain, labelled, admin-only)
# and Books::CategorySearchQuery (public, books-only, unlabelled).
#
# Takes `scope:` rather than a domain symbol because every caller already holds
# its class -- an admin controller has model_class -- and passing it keeps this
# object from growing a domain registry.
#
# `types:` defaults to unscoped, and that default is load-bearing. Both callers
# need every type: the admin add-category modal because a book is legitimately
# tagged with a subject or a setting, and the books filter modal because its
# Category axis is DEFINED as all three (see the spec's landmines).
class CategorySearchQuery
  DEFAULT_LIMIT = 10

  def self.call(query, scope:, types: [], limit: DEFAULT_LIMIT)
    new(query, scope: scope, types: types, limit: limit).call
  end

  def initialize(query, scope:, types: [], limit: DEFAULT_LIMIT)
    @query = query.to_s.strip
    @scope = scope
    @types = Array(types)
    @limit = limit
  end

  def call
    return [] if @query.blank?

    relation = @scope.active.search_by_name(@query)
    relation = relation.where(category_type: @types) if @types.any?

    relation.order(item_count: :desc, name: :asc).limit(@limit).to_a
  end
end
```

In `app/models/category.rb`, alongside the other instance methods:

```ruby
  # "Americana (Genre)". One definition, because three surfaces render it: the
  # admin autocomplete JSON, the books filter modal's search rows, and the
  # multi-select picker a later increment adds. category_type is nullable, so
  # the Unknown branch is reachable rather than defensive.
  def name_with_type
    "#{name} (#{category_type&.titleize || "Unknown"})"
  end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/category_search_query_test.rb test/models/category_test.rb`
Expected: PASS.

- [ ] **Step 6: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add app/lib/category_search_query.rb app/models/category.rb \
  test/lib/category_search_query_test.rb test/models/category_test.rb \
  test/fixtures/categories.yml
git commit -m "Add one category search every domain can use"
```

---

## Task 2: The admin controller uses it

**Files:**
- Modify: `app/controllers/admin/categories_base_controller.rb:55-65`
- Test: `test/controllers/admin/books/categories_controller_test.rb`, `test/controllers/admin/music/categories_controller_test.rb`

**Interfaces:**
- Consumes: `CategorySearchQuery.call` and `Category#name_with_type` (Task 1).
- Produces: no new interface. The JSON shape `{value:, text:}` is unchanged and must stay unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/admin/books/categories_controller_test.rb` (follow the file's existing sign-in and host setup):

```ruby
  test "search returns the autocomplete JSON shape with the type in the text" do
    get search_admin_books_categories_path(q: "fict"), as: :json

    assert_response :success
    row = response.parsed_body.find { |r| r["value"] == categories(:books_fiction_genre).id }
    assert_equal "Fiction (Genre)", row["text"]
  end

  # A book is legitimately tagged with a subject or a setting, so the admin
  # picker must keep offering every type.
  test "search is not scoped to any category_type by default" do
    get search_admin_books_categories_path(q: "americ"), as: :json

    texts = response.parsed_body.map { |r| r["text"] }
    assert_includes texts, "Americana (Genre)"
    assert_includes texts, "American History (Subject)"
    assert_includes texts, "American (Location)"
  end

  test "search orders by item_count descending" do
    get search_admin_books_categories_path(q: "americ"), as: :json

    assert_equal ["American History (Subject)", "Americana (Genre)", "American (Location)"],
      response.parsed_body.map { |r| r["text"] }.first(3)
  end

  test "search returns nothing for a blank query" do
    get search_admin_books_categories_path(q: ""), as: :json

    assert_equal [], response.parsed_body
  end

  test "search returns only this domain's categories" do
    get search_admin_books_categories_path(q: "rock"), as: :json

    assert_equal [], response.parsed_body
  end
```

Append the domain-isolation case to `test/controllers/admin/music/categories_controller_test.rb` too, asserting a music search does not return `books_fiction_genre` — the base controller is shared, so one domain's test does not cover the other's `model_class`.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/controllers/admin/books/categories_controller_test.rb`
Expected: FAIL on the ordering test (current ordering is `name`) and the blank-query test (currently returns the first 20 by name). The shape and label tests may already pass — the label string is what the controller builds inline today, which is the point.

- [ ] **Step 3: Delegate**

Replace `#search` in `app/controllers/admin/categories_base_controller.rb`:

```ruby
  # The JSON shape is a contract with AutocompleteComponent's value_key/
  # display_key defaults -- every admin category picker breaks at once if it
  # changes. `types` is accepted but unused by any current caller.
  def search
    categories = CategorySearchQuery.call(
      params[:q],
      scope: model_class,
      types: Array(params[:types]),
      limit: 20
    )

    render json: categories.map { |c| {value: c.id, text: c.name_with_type} }
  end
```

`scope: model_class`, not `model_class.active` — the query applies `.active` itself.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/controllers/admin/books/categories_controller_test.rb test/controllers/admin/music/categories_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Full suite, lint, commit**

```bash
bin/rails test && bundle exec standardrb
git add app/controllers/admin/categories_base_controller.rb \
  test/controllers/admin/books/categories_controller_test.rb \
  test/controllers/admin/music/categories_controller_test.rb
git commit -m "Point the admin category search at the shared query"
```

---

## Task 3: The filter modal shows the type, and the old query goes

**Files:**
- Modify: `app/controllers/books/filters_controller.rb:44`
- Modify: `app/components/books/filter_option_rows_component.rb` and its template
- Delete: `app/lib/books/category_search_query.rb`, `test/lib/books/category_search_query_test.rb`
- Modify: `e2e/tests/books/filters.spec.ts`
- Test: `test/controllers/books/filters_controller_test.rb`, the component's test if one exists

**Interfaces:**
- Consumes: `CategorySearchQuery.call`, `Category#name_with_type` (Task 1).
- Produces: no new interface.

- [ ] **Step 1: Read the component before changing it**

`Books::FilterOptionRowsComponent` renders rows for BOTH axes — categories and countries — and for both the browse list and the search results (`show_counts:` distinguishes them). A country has no `category_type` and must not grow a label. Establish how the component distinguishes its cases before editing, and make the label conditional on the row being a category, not on the axis name alone if the component does not already carry that.

- [ ] **Step 2: Write the failing tests**

Add to `test/controllers/books/filters_controller_test.rb`, matching the file's existing request style:

```ruby
  test "a category search result row shows its category type" do
    get books_filters_categories_path(q: "americ")

    assert_response :success
    assert_includes response.body, "Americana (Genre)"
  end

  # The Category axis spans genres, subjects and settings deliberately.
  # Scoping it here would break e2e/tests/books/filters.spec.ts.
  test "a category search still returns every category type" do
    get books_filters_categories_path(q: "americ")

    assert_includes response.body, "American History (Subject)"
    assert_includes response.body, "American (Location)"
  end

  test "a country search result row is not labelled with a category type" do
    get books_filters_countries_path(q: "fren")

    assert_response :success
    assert_not_includes response.body, "(Unknown)"
  end
```

If `books_filters_categories_path` is not the right helper, take the real one from `config/routes.rb` (`books/filters#categories`) — do not invent it.

- [ ] **Step 3: Run them and watch them fail**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: FAIL — the rows render bare names today.

- [ ] **Step 4: Swap the query and render the label**

In `app/controllers/books/filters_controller.rb`, replace the category half of `render_pane_results`:

```ruby
    rows = if axis == :category
      CategorySearchQuery.call(params[:q], scope: ::Books::Category)
    else
      ::Books::CountrySearchQuery.call(params[:q])
    end
```

No `types:` — the axis is all-types by design.

Then render `name_with_type` instead of `name` for category rows in `Books::FilterOptionRowsComponent`, leaving country rows alone.

- [ ] **Step 5: Delete the superseded query**

```bash
git rm app/lib/books/category_search_query.rb test/lib/books/category_search_query_test.rb
grep -rn "Books::CategorySearchQuery" app test e2e docs
```

The grep must come back empty except for historical mentions in `docs/superpowers/`. If it finds a live caller, stop and report it.

- [ ] **Step 6: Add the Playwright assertion**

In `e2e/tests/books/filters.spec.ts`, extend the existing search coverage with one assertion that a result row displays its type — for example that a `new york` search shows a row whose text contains `(Location)`. Do not alter the existing `new york` or `peruvian` tests; they pin behaviour this change must preserve.

- [ ] **Step 7: Run everything**

```bash
bin/rails test && bundle exec standardrb
```

Then the browser tests, which need a running server (`bin/dev` self-terminates in an agent shell — use `yarn build:all` then `bin/rails server`, and check what is actually on port 3000 first):

```bash
yarn test:e2e --grep "filters"
```

Expected: the existing filter specs still pass, including `new york` and `peruvian`, plus the new assertion. If `new york` fails, the Category axis has been scoped by mistake — revert that and re-read the spec's landmines.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Label category search results with their type"
```

---

## Task 4: Documentation and final gate

**Files:**
- Modify: an existing feature doc under `docs/features/`

- [ ] **Step 1: Document it where it belongs**

`docs/documentation.md` forbids class-level docs in this repo; feature-level architecture goes in `docs/features/`. Find the doc that already covers categories or search (`docs/features/search.md` is the likely home) and add a short section: that one `CategorySearchQuery` serves every domain, that `types:` is optional and defaults to all types, why the books filter modal's Category axis is deliberately unscoped, and that `Category#name_with_type` is the single definition of the label. A few paragraphs, not a page. If no existing doc is a sensible home, say so in your report rather than creating a new file.

- [ ] **Step 2: Final gate**

```bash
cd web-app && CI=true bin/rails test && bundle exec standardrb
```

Both must be clean.

- [ ] **Step 3: Commit**

```bash
git add docs/
git commit -m "Document the shared category search"
```

Do NOT push and do NOT open a PR.

---

## Self-Review

**Spec coverage.** §3 the query → Task 1. §4 the label → Task 1. §5 admin call site → Task 2. §5 filter modal + deleting the old query → Task 3. §6 testing → Tasks 1–3, including the fixture overlap §6 requires. §7 landmines → the Global Constraints block and Task 3's Step 7 failure mode.

**Known risks, stated rather than hidden.** Task 1 Step 1 adds fixtures that will break count assertions in up to eight files; the step says to fix the numbers rather than weaken the assertions, and to stop if a failure is not a count shifting by three. Task 3 Step 1 makes the implementer read `FilterOptionRowsComponent` before editing it, because it serves both axes and a country row must not be labelled.

**Deliberately unused surface.** `types:` has no caller in this plan. It is in the spec because it was explicitly requested and is two lines over an indexed column. Task 1's tests cover it so it is not shipped unexercised.
