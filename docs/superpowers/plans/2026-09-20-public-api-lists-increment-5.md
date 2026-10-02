# Public API — Increment 5 (Lists) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `GET /api/v1/lists`, `GET /api/v1/lists/{id}`, `GET /api/v1/lists/{id}/items`, `GET /api/v1/books/{slug}/lists` and `GET /api/v1/ranking_configurations/{id}/lists` on the books host, add `lists_api_url` to the ranking-configuration payload, all documented in the OpenAPI contract and covered by the contract-coverage gate.

**Architecture:** Nothing new in the framework's auth, rate-limit or error layers. A new Alba `ListResource` (compact + `:full`) and three controllers under `Api::V1::Books::BaseController`: `ListsController` (index, optionally nested under a configuration exactly as `BooksController#index` is; show), `ListItemsController` (a list's books in list order) and `BookListsController` (the lists a book is on). Every collection batches its per-page lookups (item counts, ranks) through `render_page`. Two predicates are made shared so counts and rows can never disagree: `ListsQuery.active_list_conditions` (what "an active list of this medium" means, already used by `RankingConfigurationsController#counts_for`) and `Books::BaseController#book_items` (what "a served list item" means). The one framework change: `render_page` counts with `count(:all)` so a relation carrying a custom `select` (a book's listings ride their weight along) can be paginated.

**Tech Stack:** Rails 8.1, Postgres, Minitest 6 + fixtures + Mocha, Alba 4 (symbol keys via `config/initializers/alba.rb`), openapi_first 3.4 (test only), Playwright (local only).

**Spec:** `docs/superpowers/specs/2026-09-20-public-api-lists-and-rankings-design.md` — D1 (`weight` is "on the configuration you read it through"; show uses the primary and is null off it), D2 (one index action, optionally nested), D4 (integer ids with a `/\d+/` route constraint), D5 (show answers for any active list; index is the configuration's lists), D6 (list items are `{position, book}`, `position ASC NULLS LAST, id ASC`, restricted to rows whose listable is a set `Books::Book`), D7 (a book's listings: every active list it is on, weight from the primary or null, `weight DESC NULLS LAST, lists.id`), D10 (no editorial flags, no weight breakdown, no `metadata`/`verified`), D11 (no new codes, scopes or parameters), §Increments item 2. The framework spec (`docs/superpowers/specs/2026-09-12-public-api-framework-design.md`) still governs everything this rides on. Increment 4's plan (`docs/superpowers/plans/2026-09-20-public-api-ranking-configurations-increment-4.md`) is the shape this one copies; it has shipped (PR #321, merge `8fc77d03`) — do not re-execute it.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **Work in a worktree** created with the `EnterWorktree` tool (never `git worktree add`), name `public-api-lists`, based on `main`. Never commit to `main`. **On this machine (MacBook Air) the tool copies none of the gitignored files** — after `EnterWorktree`, from the worktree root: `cp` the main checkout's `.env`, `web-app/.env` and `web-app/node_modules` (`cp -R`; `web-app/config/master.key` and `web-app/e2e/.env` do not exist here), then `cd web-app && yarn build:all && RAILS_ENV=test bin/rails db:create db:test:prepare`. If this plan was committed on `main` locally and is missing from the branch, `git merge --ff-only main` inside the worktree brings it in.
- **Use Rails generators** for every controller (`bin/rails generate controller …`); never hand-create one. Delete any `app/views/api/` directory the generator leaves behind.
- **Root-anchor every model reference inside `module Api::V1::Books`** — in controllers AND in the tests, which sit in the same module nesting: `::Books::List`, `::Books::Book`, `::Books::RankingConfiguration`, `::Books::ListsQuery`, `::ListItem`, `::RankedItem`, `::RankedList`, `::List`, `::Api::Host`. `ListsController` is the sharp case: a bare `List` resolves (to `::List`, the STI base — the wrong class) and a bare `Books::List` raises `NameError` at request time, not load time. `contract_coverage_test.rb` sits in `module Api::V1`, where a bare `Books::` also resolves to `Api::V1::Books::` — root-anchor there too.
- **Lists and configurations are addressed by integer id** (D4): `constraints: {id: /\d+/}` on the `resources` line, `constraints: {list_id: /\d+/}` and `constraints: {ranking_configuration_id: /\d+/}` on the nested `get` lines. A non-numeric id is a routing 404; an unknown numeric id is the `not_found` problem, whose detail names the missing record (`"No list at that address"`, `"No ranking configuration at that address"`, `"No book at that address"` — `Api::ErrorRendering` derives the noun from `error.model`).
- **Only `::Books::List.active` rows are addressable** (D5): `find` on that scope everywhere; an approved-not-active list, and a list of another medium (STI), are 404s.
- **Parent before page**: every nested action resolves its parent before `Api::Page` parses `page`/`per_page`, so `/lists/<unknown>/items?page=0` is a 404, not a 400.
- **The configuration id comes from the path only**: `Books::BaseController#ranking_configuration` and `#collection_path` read `request.path_parameters`, never `params[]`. `ListsController#index` calls both exactly as `BooksController#index` does and adds nothing of its own.
- **One active-list predicate.** `ListsQuery.active_list_conditions` (Task 2) is the only place `{lists: {type:, status: active}}` is written. `RankingConfigurationsController#counts_for`, `ListsQuery#call` and `BookListsController` all filter on it, so `list_count == /ranking_configurations/{id}/lists` `total_count`.
- **One served-item predicate.** `Books::BaseController#book_items(scope)` (`by_listable_type("Books::Book").with_listable`) is the only place it is written; `item_counts_for` and `ListItemsController#index` use it, so a list's `item_count == /lists/{id}/items` `total_count`. A row with no listable or a mismatched `listable_type` is neither counted nor served (D6).
- **Counts and ranks are batched per page, never per row**, and an empty page issues no lookups. `BookResource` gets `params[:rank]` with the key always present (nil for an unranked book) so it never falls back to the per-row `primary_ranked_item` lookup.
- **`preload`, not `includes`, wherever the relation also has `where(lists: …)`**: a hash `where` keyed on a table name adds `references`, which promotes `includes` to an eager-load JOIN — verified on this database 2026-09-20 (`eager_loading?` → true) — and that clashes with the custom `select` in `BookListsController`. `ListItemsController` keeps `includes(listable: …)` like the site's list page: nothing there references a joined table.
- **`render_page` counts with `count(:all)`** from Task 6 on. Verified 2026-09-20: `relation.count` on a relation with `select("list_items.*, NULL::integer AS weight")` raises `PG::SyntaxError`; `count(:all)` works and is what Pagy does for the site.
- **Payload keys, in order** (the contract): List compact `id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url`; `:full` appends `description source_url`. `url` is the site page `https://<host>/lists/{id}`; `source_url` is the `lists.url` column. RankingConfiguration gains `lists_api_url` after `books_api_url`. No editorial flags, no `calculated_weight_details`, no `metadata`/`verified` (D10).
- **Nullable in the contract:** `source`, `year_published`, `yearly_award`, `number_of_voters`, `activated_at`, `description`, `source_url`, `weight`, `position`. Measured on the development database 2026-09-20 over the 758 active book lists: `year_published` null on 46, `number_of_voters` on 141, `yearly_award` on 1, `url` on 1. **`source_url` carries no `format: uri`**: 5 of the 758 hold a leading space or several addresses joined with `&`/`；`.
- Timestamps are ISO 8601 UTC strings (`Time#utc.iso8601`), `null` when unset.
- **Every API integration test ends in `assert_api_conform(status:)`** (request + response) or, for deliberately invalid requests, `assert_api_response_conform(status:)`. New endpoints need `openapi.yaml` path items with `x-domain: books`, and `EXERCISES` in `test/integration/api/v1/contract_coverage_test.rb` must gain every new (method, path, status) or the gate fails. **`test/controllers/api/v1/openapi_controller_test.rb` pins the books-host `paths.keys` list TWICE** ("on the books host every books operation is present", line ~30, and "the document itself is valid enough to load", line ~98) — update both in the same task as any new path.
- **Fixture facts:** no `Books::List` fixture is `active`; `lists(:books_list)` carries an item whose listable (`one (Books::Book)`) does not exist; `lists(:high_quality_list)` and `lists(:approved_list)` are `Books::List` rows holding `Movies::Movie` items. **Create lists and items in test `setup`**; never activate those fixtures in a test that renders items. 38,184 of the 56,500 items on active book lists have `position: null` — it is a first-class state and every ordering test has null positions in it.
- Alba returns **symbol** keys (`config/initializers/alba.rb`). Key order in a resource IS the order in `openapi.yaml`. Trait attributes append after the base ones.
- Rails 8.1 ships `assert_no_queries`; `capture_sql` comes from `test/support/sql_capture.rb`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- Minitest 6: `assert_nil x`, never `assert_equal nil, x`.
- A clean `bin/rails test` adds **no warning lines** beyond the two known npm/yarn ones during `test:prepare`.
- Tests mirror `app/` and are namespaced to match (`module Api; module V1; module Books; class ListsControllerTest`).
- Controller tests assert behaviour (status, headers, JSON keys and values), never HTML or copy.
- The dev database is shared with other worktrees and not disposable: no `db:reset`, no `delete_all` outside `RAILS_ENV=test`. This increment has **no migration**.
- `CI=1 bin/rails zeitwerk:check` must pass after every task that adds a file under `app/lib`.
- Commit after every task, ending the message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **The E2E addition (Task 7) cannot run on this machine**: `web-app/e2e/.env` is absent, and the `books-member` project needs it. Add the assertion, do not run it, and say so in the task report. If it ever is run: port 3000 is usually held by the owner's own dev server in the main checkout (`lsof -nP -iTCP:3000 -sTCP:LISTEN`, then `lsof -p <pid> | awk '$4=="cwd"'`) — do not kill it, do not use another port.
- **Deferred minors from increment 4, resolved here:** the shared active-list predicate is extracted (Task 2). `AuthorsController#index`'s local `ranking_configuration` is NOT renamed — that file is not touched by this increment. `render_ranked_page` is NOT renamed to `render_rows` — every collection in this increment batches, so all three new callers use `render_page` and `render_ranked_page` gains no caller; increment 6's `AuthorBooksController#index` will be the next per-row caller, rename it then.

---

## File structure

| File | Responsibility |
|---|---|
| `app/lib/api/v1/books/list_resource.rb` | Alba: the list shape, compact + `:full` |
| `test/lib/api/v1/books/list_resource_test.rb` | shape, trait order, nullables, `fetch`-required params, URLs, no D10 fields |
| `app/lib/lists_query.rb` | **modify**: `ListsQuery.active_list_conditions`; `call` filters on it |
| `test/lib/lists_query_test.rb`, `test/lib/books/lists_query_test.rb` | **modify**: the predicate is defined by `list_type` |
| `app/controllers/api/v1/books/ranking_configurations_controller.rb` | **modify**: `counts_for` filters on the shared predicate |
| `app/controllers/api/v1/books/base_controller.rb` | **modify**: `book_items(scope)`, `item_counts_for(list_ids)` |
| `app/controllers/api/v1/base_controller.rb` | **modify** (Task 6): `render_page` counts with `count(:all)` |
| `app/controllers/api/v1/books/lists_controller.rb` | index (bare and nested), show |
| `test/controllers/api/v1/books/lists_controller_test.rb` | order, scope, batching, nested, show, 404s |
| `app/controllers/api/v1/books/list_items_controller.rb` | a list's books in list order |
| `test/controllers/api/v1/books/list_items_controller_test.rb` | `NULLS LAST`, filtering, batched ranks, item_count cross-check |
| `app/controllers/api/v1/books/book_lists_controller.rb` | the lists a book is on |
| `test/controllers/api/v1/books/book_lists_controller_test.rb` | weighted-first order, null weights, no-primary branch |
| `app/lib/api/v1/books/ranking_configuration_resource.rb` | **modify**: `lists_api_url` |
| `test/lib/api/v1/books/ranking_configuration_resource_test.rb`, `test/controllers/api/v1/books/ranking_configurations_controller_test.rb` | **modify**: the key list |
| `config/routes.rb` | **modify**: `resources :lists`, three nested `get` lines, in the books API scope |
| `config/api/v1/openapi.yaml` | **modify**: five path items; schemas `List`, `ListFull`, `ListCollection`, `ListItem`, `ListItemRow`, `ListItemCollection`, `BookListingRow`, `BookListingCollection`; `lists_api_url` |
| `test/integration/api/v1/contract_coverage_test.rb` | **modify**: 28 `EXERCISES` entries; an active list in `setup` |
| `test/controllers/api/v1/openapi_controller_test.rb` | **modify**: both books-host `paths.keys` pins |
| `test/controllers/developers_controller_test.rb` | **modify**: the five new endpoint anchors |
| `e2e/tests/books/member/developers-tokens.spec.ts` | **modify**: one `page.request.get('/api/v1/lists?per_page=1')` |
| `docs/features/public-api.md` | **modify**: lists are shipped; "Not yet" shrinks |

What this increment does **not** touch: the three `Api::` concerns, `Services::Api::*`, `Api::Page`/`Problem`/`Host`, `BookResource`, `BooksController`, `AuthorsController`, `::Books::RankedBooksQuery`, any model, any site controller or view.

---

### Task 1: `Api::V1::Books::ListResource`

**Files:**
- Create: `web-app/app/lib/api/v1/books/list_resource.rb`
- Test: `web-app/test/lib/api/v1/books/list_resource_test.rb`

**Interfaces:**
- Consumes: `Api::Host.base_url` (→ `"https://dev-new.thegreatestbooks.org"` when `Current.domain = :books` in test); `::Books::List` — `id`, `name`, `source`, `year_published`, `yearly_award`, `number_of_voters`, `activated_at`, `description`, `url` (the original list on the web).
- Produces: `Api::V1::Books::ListResource.new(list, params: {weight: Integer | nil, item_count: Integer}).to_h`, and `with_traits: :full` for show. Compact keys, in order: `id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url`; `:full` appends `description source_url`. Both params are **required** (`fetch`) — `weight: nil` must be passed explicitly for a list that is off the configuration.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/api/v1/books/list_resource_test.rb`:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class ListResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          # Created, not a fixture: no Books::List fixture is active, and the
          # resource's activated_at reads the column the model stamps on
          # activation.
          @list = ::Books::List.create!(
            name: "100 Novels", source: "The Guardian", url: "https://example.com/100-novels",
            description: "A century of novels.", year_published: 2015, number_of_voters: 12,
            yearly_award: false, status: :active
          )
          @list.update_column(:activated_at, Time.zone.parse("2026-09-19 08:15:00 UTC"))
        end

        test "compact shape" do
          hash = ListResource.new(@list, params: {weight: 42, item_count: 100}).to_h

          assert_equal(
            %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url],
            hash.keys
          )
          assert_equal @list.id, hash[:id]
          assert_equal "100 Novels", hash[:name]
          assert_equal "The Guardian", hash[:source]
          assert_equal 2015, hash[:year_published]
          assert_equal false, hash[:yearly_award]
          assert_equal 12, hash[:number_of_voters]
          assert_equal 100, hash[:item_count]
          assert_equal 42, hash[:weight]
          assert_equal "2026-09-19T08:15:00Z", hash[:activated_at]
          assert_equal "https://dev-new.thegreatestbooks.org/lists/#{@list.id}", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}", hash[:api_url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}/items", hash[:items_api_url]
        end

        test "full trait appends description and source_url in order" do
          hash = ListResource.new(@list, params: {weight: 42, item_count: 100}, with_traits: :full).to_h

          assert_equal(
            %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url description source_url],
            hash.keys
          )
          assert_equal "A century of novels.", hash[:description]
          assert_equal "https://example.com/100-novels", hash[:source_url]
        end

        test "a list off the configuration carries an explicit null weight" do
          hash = ListResource.new(@list, params: {weight: nil, item_count: 0}).to_h

          assert hash.key?(:weight)
          assert_nil hash[:weight]
        end

        test "nullable columns render as null" do
          list = ::Books::List.create!(name: "Bare", status: :approved)

          hash = ListResource.new(list, params: {weight: nil, item_count: 0}, with_traits: :full).to_h

          assert_nil hash[:source]
          assert_nil hash[:year_published]
          assert_nil hash[:yearly_award]
          assert_nil hash[:number_of_voters]
          assert_nil hash[:activated_at]
          assert_nil hash[:description]
          assert_nil hash[:source_url]
        end

        test "weight and item_count are required" do
          assert_raises(KeyError) { ListResource.new(@list).to_h }
          assert_raises(KeyError) { ListResource.new(@list, params: {item_count: 1}).to_h }
          assert_raises(KeyError) { ListResource.new(@list, params: {weight: 1}).to_h }
        end

        test "the shape carries no editorial flags, status or weight breakdown" do
          hash = ListResource.new(@list, params: {weight: 1, item_count: 1}, with_traits: :full).to_h

          %i[status high_quality_source category_specific location_specific creator_specific estimated_quality
            voter_count_estimated voter_count_unknown voter_names_unknown calculated_weight_details raw_content
            simplified_content items_json].each do |key|
            refute hash.key?(key), key
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/api/v1/books/list_resource_test.rb`
Expected: every test errors with `NameError: uninitialized constant Api::V1::Books::ListResource`.

- [ ] **Step 3: Write the resource**

`web-app/app/lib/api/v1/books/list_resource.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # A list as the API presents it. Compact by default (every collection
      # row), with a :full trait for show. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      #
      # `weight` and `item_count` are params the controller settles per page:
      # weight is a property of the (list, configuration) pair, not of the
      # list (spec D1), so the resource never looks it up itself; item_count is
      # batched. Both use `fetch` -- a caller that forgets one fails loudly
      # instead of rendering null, and a list that is off the configuration
      # passes weight: nil on purpose.
      #
      # `url` is the list's page on the site; the lists.url column (the
      # original list on the web) is `source_url`, in the full shape only. The
      # editorial flags and the weight breakdown are deliberately absent (D10).
      class ListResource
        include Alba::Resource

        attributes :id, :name, :source, :year_published, :yearly_award, :number_of_voters

        attribute :item_count do
          params.fetch(:item_count)
        end

        attribute :weight do
          params.fetch(:weight)
        end

        attribute :activated_at do |list|
          list.activated_at&.utc&.iso8601
        end

        attribute :url do |list|
          "#{::Api::Host.base_url}/lists/#{list.id}"
        end

        attribute :api_url do |list|
          "#{::Api::Host.base_url}/api/v1/lists/#{list.id}"
        end

        attribute :items_api_url do |list|
          "#{::Api::Host.base_url}/api/v1/lists/#{list.id}/items"
        end

        trait :full do
          attributes :description

          attribute :source_url do |list|
            list.url
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/api/v1/books/list_resource_test.rb`
Expected: 6 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/lib/api/v1/books/list_resource.rb test/lib/api/v1/books/list_resource_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; `All is good!`.

```bash
git add app/lib/api/v1/books/list_resource.rb test/lib/api/v1/books/list_resource_test.rb
git commit -m "$(cat <<'EOF'
API: ListResource

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: One active-list predicate on `ListsQuery`

The predicate "a `Books::List` with status `active`, joined as `lists`" is written twice today (`ListsQuery#call`, `RankingConfigurationsController#counts_for`) and this increment would write it a third time. Extract it once; every later task filters on it.

**Files:**
- Modify: `web-app/app/lib/lists_query.rb`
- Modify: `web-app/app/controllers/api/v1/books/ranking_configurations_controller.rb` (`counts_for`)
- Test: `web-app/test/lib/lists_query_test.rb`, `web-app/test/lib/books/lists_query_test.rb`

**Interfaces:**
- Consumes: `ListsQuery.list_type` (`"Books::List"` on `Books::ListsQuery`, `"Games::List"` on `Games::ListsQuery`), `::List.statuses[:active]` (3).
- Produces: `ListsQuery.active_list_conditions` → `{lists: {type: list_type, status: 3}}`, a hash for `where` on any relation that has `joins(:list)`. Raises `NotImplementedError` on the base class. Tasks 3–6 call `::Books::ListsQuery.active_list_conditions`.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/lists_query_test.rb`, after the test "the base class refuses to run without a list type", add:

```ruby
  test "the base class refuses to give the active-list predicate without a list type" do
    assert_raises(NotImplementedError) { ListsQuery.active_list_conditions }
  end
```

In `web-app/test/lib/books/lists_query_test.rb`, before `private`, add:

```ruby
    test "active_list_conditions is the predicate call filters on" do
      assert_equal({lists: {type: "Books::List", status: List.statuses[:active]}}, Books::ListsQuery.active_list_conditions)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/lists_query_test.rb test/lib/books/lists_query_test.rb`
Expected: the two new tests error with `NoMethodError: undefined method 'active_list_conditions'`; the rest pass.

- [ ] **Step 3: Extract the predicate**

In `web-app/app/lib/lists_query.rb`, after `def self.list_type … end`, add:

```ruby
  # The "an active list of this medium" predicate, for a relation that has
  # joined lists. Anything that must agree with this query's row count -- the
  # API's list_count on a configuration, the lists a book is on -- filters on
  # this rather than restating it.
  def self.active_list_conditions
    {lists: {type: list_type, status: ::List.statuses[:active]}}
  end
```

and in `call`, replace

```ruby
      .where(lists: {type: self.class.list_type, status: ::List.statuses[:active]})
```

with

```ruby
      .where(self.class.active_list_conditions)
```

- [ ] **Step 4: Switch `counts_for` to it**

In `web-app/app/controllers/api/v1/books/ranking_configurations_controller.rb`, replace the `counts_for` method (comment included) with:

```ruby
        # {id => {item_count:, list_count:}} in two grouped queries whatever the
        # page size, and none at all for an empty page. list_count filters on
        # ::Books::ListsQuery's own predicate, so it equals the lists
        # sub-collection's total_count.
        def counts_for(ids)
          return {} if ids.empty?

          items = ::RankedItem.where(ranking_configuration_id: ids, item_type: "Books::Book").where.not(rank: nil)
            .group(:ranking_configuration_id).count
          lists = ::RankedList.where(ranking_configuration_id: ids).joins(:list)
            .where(::Books::ListsQuery.active_list_conditions)
            .group(:ranking_configuration_id).count

          ids.index_with { |id| {item_count: items.fetch(id, 0), list_count: lists.fetch(id, 0)} }
        end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/lists_query_test.rb test/lib/books/lists_query_test.rb test/lib/games/lists_query_test.rb test/controllers/api/v1/books/ranking_configurations_controller_test.rb test/controllers/books/lists_controller_test.rb test/controllers/games/`
Expected: 0 failures, 0 errors — the site's lists pages and the configuration counts behave exactly as before.

- [ ] **Step 6: Lint, commit**

Run: `bundle exec standardrb app/lib/lists_query.rb app/controllers/api/v1/books/ranking_configurations_controller.rb test/lib/lists_query_test.rb test/lib/books/lists_query_test.rb`
Expected: no offenses.

```bash
git add app/lib/lists_query.rb app/controllers/api/v1/books/ranking_configurations_controller.rb test/lib/lists_query_test.rb test/lib/books/lists_query_test.rb
git commit -m "$(cat <<'EOF'
Lists: one active-list predicate on ListsQuery

RankingConfigurationsController#counts_for filtered on a copy of the
predicate ListsQuery#call uses; the lists endpoints would have made a
third. active_list_conditions is now the only place it is written.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `ListsController` — `GET /api/v1/lists` and `/api/v1/lists/{id}`

The contract-coverage gate is what makes these one task: the document, the endpoints and the `EXERCISES` map land together or `contract_coverage_test.rb` is red in between. The nested lists route is Task 4; this task ships the resource alone. The base-controller helpers (`book_items`, `item_counts_for`) land here because this is their first caller.

**Files:**
- Modify: `web-app/app/controllers/api/v1/books/base_controller.rb`
- Modify: `web-app/config/routes.rb` (the `scope module: :books do` block inside `namespace :api … namespace :v1`, line ~625)
- Create (generator): `web-app/app/controllers/api/v1/books/lists_controller.rb`, `web-app/test/controllers/api/v1/books/lists_controller_test.rb`
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `Api::V1::Books::BaseController#ranking_configuration` and `#collection_path(suffix)` (increment 4, path-only), `#render_page(relation, path:) { |rows| … }`, `Api::V1::Books::ListResource` (Task 1), `::Books::ListsQuery.call(ranking_configuration:)` (yields `RankedList` rows with `list` loaded, `weight DESC, lists.id ASC`), `::Books::List.active`, `::Books::RankingConfiguration.default_primary`, `RankingConfiguration#ranked_lists`, `::ListItem.by_listable_type`/`.with_listable`; test helpers `bearer`, `assert_api_conform`, `assert_api_response_conform`, `capture_sql`, `ApiTokenSecrets::{MEMBER, MUSIC_ONLY, NON_MEMBER}`, fixtures `ranking_configurations(:books_global, :books_year_2025)`, `books_books(:war_and_peace, :crime_and_punishment)`, `lists(:music_albums_list)`.
- Produces: `Api::V1::Books::BaseController#book_items(scope)` → the scope narrowed to served items; `#item_counts_for(list_ids)` → `{list_id => Integer}` with no key for a list with no served items (callers `fetch(id, 0)`), `{}` for `[]`. `GET /api/v1/lists`, `GET /api/v1/lists/:id` on the books host; `openapi.yaml` path items `/api/v1/lists`, `/api/v1/lists/{id}`, schemas `List`, `ListFull`, `ListCollection`, `ListItem`. Task 5's `ListItemsController` uses `book_items`; Task 6's `BookListsController` uses `item_counts_for`.

- [ ] **Step 1: Routes**

In `web-app/config/routes.rb`, inside `scope module: :books do`, after the `get "ranking_configurations/:ranking_configuration_id/books", …` line (two lines), add:

```ruby
          resources :lists, only: [:index, :show], constraints: {id: /\d+/}
```

Run: `bin/rails routes -g 'api/v1/lists'`
Expected:
```
api_v1_lists GET /api/v1/lists(.:format)     api/v1/books/lists#index {format: :json}
 api_v1_list GET /api/v1/lists/:id(.:format) api/v1/books/lists#show {format: :json, id: /\d+/}
```

- [ ] **Step 2: Generate the controller**

Run:
```bash
bin/rails generate controller api/v1/books/lists index show --skip-routes --no-helper -e none --parent=Api::V1::Books::BaseController
```
Expected: `app/controllers/api/v1/books/lists_controller.rb` and `test/controllers/api/v1/books/lists_controller_test.rb`. Run `ls app/views/api 2>/dev/null` and delete that directory if the generator created it (`rm -r app/views/api`).

- [ ] **Step 3: Write the failing controller tests**

Replace `web-app/test/controllers/api/v1/books/lists_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class ListsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @year = ranking_configurations(:books_year_2025)
          # No Books::List fixture is active, and the ones that carry items point
          # at a book that does not exist or at a movie, so every list here is
          # created rather than reshaped from a fixture other suites depend on.
          # On the primary: three active (90, 50, 50 -- the tie breaks on id) and
          # one approved-not-active; one active on the year configuration only;
          # one active on no configuration at all.
          @heavy = create_list("Heavy", weight: 90)
          @mid_a = create_list("Mid A", weight: 50)
          @mid_b = create_list("Mid B", weight: 50)
          @approved = create_list("Approved", weight: 99, status: :approved)
          @year_only = create_list("Year only", weight: 70, ranking_configuration: @year)
          @orphan = ::Books::List.create!(name: "On no configuration", status: :active)
          # Heavy has two served items and one row with no listable, which is
          # neither counted here nor served by /items. Positions include a null:
          # 38k of the 56k real items have none.
          ListItem.create!(list: @heavy, listable: books_books(:war_and_peace), position: 1)
          ListItem.create!(list: @heavy, listable: books_books(:crime_and_punishment), position: nil)
          ListItem.create!(list: @heavy, listable: nil, metadata: {title: "Unresolved"})
          ListItem.create!(list: @mid_a, listable: books_books(:crime_and_punishment), position: 1)
        end

        def json = response.parsed_body.deep_symbolize_keys

        # --- index ---------------------------------------------------------------

        test "index lists the primary's active lists heaviest first, id as the tiebreak, with meta and links" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal [90, 50, 50], json[:data].map { |row| row[:weight] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index rows are the compact shape with batched item counts" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          heavy = json[:data].first
          assert_equal %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url], heavy.keys
          assert_equal 2, heavy[:item_count], "item_count must exclude the row with no listable"
          assert_equal "https://dev-new.thegreatestbooks.org/lists/#{@heavy.id}", heavy[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@heavy.id}", heavy[:api_url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@heavy.id}/items", heavy[:items_api_url]
          assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, heavy[:activated_at])
          assert_equal [2, 1, 0], json[:data].map { |row| row[:item_count] }
        end

        test "index excludes active lists off the configuration and inactive lists on it" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          ids = json[:data].map { |row| row[:id] }
          refute_includes ids, @approved.id, "approved, not active, though weighted on the primary"
          refute_includes ids, @year_only.id, "active, but weighted on the year configuration only"
          refute_includes ids, @orphan.id, "active, on no configuration"
        end

        test "index paginates" do
          get "/api/v1/lists?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200 and runs no item-count lookup" do
          get "/api/v1/lists?page=9", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up
          queries = capture_sql { get "/api/v1/lists?page=9", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
          refute queries.any? { |sql| sql.include?("list_items") },
            "an empty page must not count items:\n#{queries.join("\n")}"
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "invalid_parameter", json[:code]
        end

        test "index with no primary ranking configuration is an empty 200" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index query count does not grow with page size" do
          get "/api/v1/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/lists?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders the full list with its weight on the primary" do
          get "/api/v1/lists/#{@heavy.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url description source_url], json[:data].keys
          assert_equal @heavy.id, json[:data][:id]
          assert_equal 90, json[:data][:weight]
          assert_equal 2, json[:data][:item_count]
          assert_equal "About Heavy", json[:data][:description]
          assert_equal "https://example.com/heavy", json[:data][:source_url]
        end

        test "show answers for an active list off the primary with a null weight" do
          [@year_only, @orphan].each do |list|
            get "/api/v1/lists/#{list.id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 200)

            assert_response :success, list.name
            assert json[:data].key?(:weight), list.name
            assert_nil json[:data][:weight]
          end
        end

        test "show with no primary ranking configuration has a null weight" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/lists/#{@heavy.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_nil json[:data][:weight]
        end

        test "show of a list that is not active is a 404 problem" do
          get "/api/v1/lists/#{@approved.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_equal "No list at that address", json[:detail]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "show of an unknown id is a 404 problem" do
          get "/api/v1/lists/999999999", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_equal "not_found", json[:code]
        end

        test "show never serves a list of another medium" do
          get "/api/v1/lists/#{lists(:music_albums_list).id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "a non-numeric id is a routing 404" do
          get "/api/v1/lists/best", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- framework confirmations ---------------------------------------------

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/lists"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "unauthenticated", json[:code]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        test "every authenticated response carries the six rate-limit headers and is not cacheable" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end

        private

        def create_list(name, weight:, ranking_configuration: @primary, status: :active)
          list = ::Books::List.create!(
            name: name, source: "#{name} Source", url: "https://example.com/#{name.parameterize}",
            description: "About #{name}", year_published: 2020, number_of_voters: 100, yearly_award: false, status: status
          )
          RankedList.create!(list: list, ranking_configuration: ranking_configuration, weight: weight)
          list
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/lists_controller_test.rb`
Expected: the 200 tests fail (the generated actions render nothing useful and `assert_api_conform` reports the path matches no documented operation); the routing/host tests may already pass. No `NameError` from the file itself.

- [ ] **Step 5: The base helpers**

In `web-app/app/controllers/api/v1/books/base_controller.rb`, after the `collection_path` method (still inside `private`), add:

```ruby

        # The list items the API serves and counts: rows whose listable is a
        # Books::Book that is set. Importers can leave listable_id null or write
        # another listable_type; filtering in the relation rather than in the
        # serializer keeps total_count, per_page and the rows consistent (spec
        # D6), and item_counts_for uses the same predicate so a list's
        # item_count always equals its /items total_count.
        def book_items(scope)
          scope.by_listable_type("Books::Book").with_listable
        end

        # {list_id => item_count} in one grouped query for a page of lists, and
        # none at all for an empty page. A list with no served items has no
        # key -- callers fetch with a default of 0.
        def item_counts_for(list_ids)
          return {} if list_ids.empty?

          book_items(::ListItem.where(list_id: list_ids)).group(:list_id).count
        end
```

- [ ] **Step 6: Write the controller**

Replace `web-app/app/controllers/api/v1/books/lists_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/lists      -- the primary ranking's active lists, heaviest first
      # GET /api/v1/lists/:id  -- any active list, full shape
      #
      # weight is a property of the (list, configuration) pair (spec D1): a
      # collection row carries the weight on the configuration it was read
      # through; show reads the primary and answers null off it (D5).
      #
      # Every model reference is root-anchored. This is the sharp case: inside
      # Api::V1::Books a bare `List` resolves (to ::List, the STI base) while a
      # bare `Books::List` raises NameError -- so it is ::Books::List throughout.
      class ListsController < BaseController
        def index
          configuration = ranking_configuration
          relation = configuration && ::Books::ListsQuery.call(ranking_configuration: configuration)

          render_page(relation, path: collection_path("lists")) do |ranked_lists|
            counts = item_counts_for(ranked_lists.map(&:list_id))
            ranked_lists.map do |ranked_list|
              ListResource.new(ranked_list.list, params: {weight: ranked_list.weight, item_count: counts.fetch(ranked_list.list_id, 0)}).to_h
            end
          end
        end

        def show
          list = ::Books::List.active.find(params[:id])
          counts = item_counts_for([list.id])

          render json: {
            data: ListResource.new(list, params: {weight: primary_weight(list), item_count: counts.fetch(list.id, 0)}, with_traits: :full).to_h
          }
        end

        private

        # The list's weight on the primary configuration: nil off it, and nil
        # when there is no primary yet.
        def primary_weight(list)
          primary = ::Books::RankingConfiguration.default_primary
          return if primary.nil?

          primary.ranked_lists.find_by(list: list)&.weight
        end
      end
    end
  end
end
```

- [ ] **Step 7: Contract entries**

In `web-app/config/api/v1/openapi.yaml`:

(a) After the `/api/v1/ranking_configurations/{id}/books:` path item (before `components:`), add:

```yaml
  /api/v1/lists:
    x-domain: books
    get:
      operationId: listLists
      summary: Lists behind the primary ranking
      description: The active lists that feed The Greatest Books' primary ranking, heaviest first. `weight` is the list's weight on that ranking; `item_count` is the number of books `items_api_url` serves.
      parameters:
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of lists.
          headers:
            X-RateLimit-Limit:
              $ref: "#/components/headers/X-RateLimit-Limit"
            X-RateLimit-Remaining:
              $ref: "#/components/headers/X-RateLimit-Remaining"
            X-RateLimit-Reset:
              $ref: "#/components/headers/X-RateLimit-Reset"
            X-RateLimit-Daily-Limit:
              $ref: "#/components/headers/X-RateLimit-Daily-Limit"
            X-RateLimit-Daily-Remaining:
              $ref: "#/components/headers/X-RateLimit-Daily-Remaining"
            X-RateLimit-Daily-Reset:
              $ref: "#/components/headers/X-RateLimit-Daily-Reset"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ListCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/lists/{id}:
    x-domain: books
    get:
      operationId: getList
      summary: One list
      description: Any active list, whether or not it feeds the primary ranking; `weight` is null when it does not.
      parameters:
        - $ref: "#/components/parameters/id"
      responses:
        "200":
          description: The list.
          headers:
            X-RateLimit-Limit:
              $ref: "#/components/headers/X-RateLimit-Limit"
            X-RateLimit-Remaining:
              $ref: "#/components/headers/X-RateLimit-Remaining"
            X-RateLimit-Reset:
              $ref: "#/components/headers/X-RateLimit-Reset"
            X-RateLimit-Daily-Limit:
              $ref: "#/components/headers/X-RateLimit-Daily-Limit"
            X-RateLimit-Daily-Remaining:
              $ref: "#/components/headers/X-RateLimit-Daily-Remaining"
            X-RateLimit-Daily-Reset:
              $ref: "#/components/headers/X-RateLimit-Daily-Reset"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ListItem"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
```

(b) At the end of `components.schemas` (after `RankingConfigurationItem`), add:

```yaml
    List:
      type: object
      required: [id, name, source, year_published, yearly_award, number_of_voters, item_count, weight, activated_at, url, api_url, items_api_url]
      properties:
        id: {type: integer}
        name: {type: string}
        source: {type: [string, "null"], description: Who published the list.}
        year_published: {type: [integer, "null"]}
        yearly_award:
          type: [boolean, "null"]
          description: Whether the list is one year's award or best-of rather than an all-time list.
        number_of_voters: {type: [integer, "null"]}
        item_count:
          type: integer
          minimum: 0
          description: Books on the list — the rows `items_api_url` serves.
        weight:
          type: [integer, "null"]
          description: The list's weight on the ranking configuration it was read through — the primary for `/api/v1/lists`, `/api/v1/lists/{id}` and a book's listings; null when the list does not feed it.
        activated_at:
          type: [string, "null"]
          format: date-time
          description: When the list went live on the site.
        url: {type: string, format: uri, description: The list's page on the site.}
        api_url: {type: string, format: uri}
        items_api_url: {type: string, format: uri, description: The list's books, in list order.}
    ListFull:
      allOf:
        - $ref: "#/components/schemas/List"
        - type: object
          required: [description, source_url]
          properties:
            description: {type: [string, "null"]}
            source_url:
              type: [string, "null"]
              description: The original list on the web, as recorded — a few carry more than one address.
    ListCollection:
      type: object
      required: [data, meta, links]
      properties:
        data:
          type: array
          items:
            $ref: "#/components/schemas/List"
        meta:
          $ref: "#/components/schemas/PaginationMeta"
        links:
          $ref: "#/components/schemas/PaginationLinks"
    ListItem:
      type: object
      required: [data]
      properties:
        data:
          $ref: "#/components/schemas/ListFull"
```

- [ ] **Step 8: Coverage entries and the served-paths pins**

In `web-app/test/integration/api/v1/contract_coverage_test.rb`:

(a) Add to `EXERCISES` after the last `/api/v1/ranking_configurations/{id}/books` entry. That entry is currently the hash's last and has no trailing comma — add one, since these now follow it (the last of these has none):

```ruby
        ["GET", "/api/v1/lists", "200"] => -> { get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists", "400"] => -> { get "/api/v1/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists", "401"] => -> { get "/api/v1/lists" },
        ["GET", "/api/v1/lists", "403"] => -> { get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/lists", "429"] => -> { with_exhausted_limit { get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/lists/{id}", "200"] => -> { get "/api/v1/lists/#{@list.id}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists/{id}", "401"] => -> { get "/api/v1/lists/#{@list.id}" },
        ["GET", "/api/v1/lists/{id}", "403"] => -> { get "/api/v1/lists/#{@list.id}", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/lists/{id}", "404"] => -> { get "/api/v1/lists/999999999", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/lists/#{@list.id}", headers: bearer(ApiTokenSecrets::MEMBER) } }
```

(b) In `setup`, after the two `RankedItem.create!` lines, add (the lambdas run under `instance_exec`, so `@list` is visible to them):

```ruby
        # One active books list, weighted on the primary and carrying one
        # resolved item, so every lists response in the map renders a row. The
        # fixtures cannot supply it: none is active, and the two that carry
        # items point at a book that does not exist or at a movie.
        @list = ::Books::List.create!(name: "Coverage list", status: :active)
        ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 1)
        RankedList.create!(list: @list, ranking_configuration: ranking_configurations(:books_global), weight: 10)
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, **both** books-host pins ("on the books host every books operation is present" and "the document itself is valid enough to load") become:

```ruby
        ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}", "/api/v1/ranking_configurations/{id}/books",
          "/api/v1/lists", "/api/v1/lists/{id}"]
```

(keep each test's own right-hand side: `response.parsed_body["paths"].keys` in the first, `::Api::OpenapiDocument.raw["paths"].keys` in the second).

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/ test/integration/api/v1/ test/lib/api/`
Expected: 0 failures, 0 errors. If `contract_coverage_test` reports "documented responses and EXERCISES disagree", diff the two lists it prints — a status is missing on one side.

- [ ] **Step 10: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/controllers/api config/routes.rb test/controllers/api test/integration/api && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; `All is good!`.

```bash
git add app/controllers/api/v1/books/base_controller.rb app/controllers/api/v1/books/lists_controller.rb config/routes.rb config/api/v1/openapi.yaml test/controllers/api/v1/books/lists_controller_test.rb test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "$(cat <<'EOF'
API: GET /api/v1/lists and /{id}

The index is the primary's active lists through ::Books::ListsQuery;
show answers for any active list with its weight on the primary or
null. Item counts are batched per page through one served-item
predicate the items endpoint will share.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `/api/v1/ranking_configurations/{id}/lists` and `lists_api_url`

The nested lists index is `ListsController#index` resolving the configuration from the path, the same way `/ranking_configurations/{id}/books` is `BooksController#index`. `lists_api_url` joins the configuration payload in this task, not earlier, because a link to a route that 404s is worse than a field added later (spec §Increments item 1).

**Files:**
- Modify: `web-app/config/routes.rb` (same block as Task 3)
- Modify: `web-app/app/controllers/api/v1/books/lists_controller.rb` (class comment only)
- Modify: `web-app/app/lib/api/v1/books/ranking_configuration_resource.rb`
- Modify: `web-app/test/lib/api/v1/books/ranking_configuration_resource_test.rb`, `web-app/test/controllers/api/v1/books/ranking_configurations_controller_test.rb`
- Modify: `web-app/test/controllers/api/v1/books/lists_controller_test.rb` (new tests appended before `# --- show`)
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `ListsController#index` (Task 3), `Books::BaseController#ranking_configuration`/`#collection_path` (path-only), `RankingConfigurationResource`.
- Produces: `GET /api/v1/ranking_configurations/:ranking_configuration_id/lists` on the books host; `RankingConfigurationResource` key `lists_api_url` after `books_api_url`; `openapi.yaml` path item `/api/v1/ranking_configurations/{id}/lists`, `RankingConfiguration.lists_api_url`.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/controllers/api/v1/books/lists_controller_test.rb`, add before the `# --- show` comment block:

```ruby
        # --- nested under a ranking configuration --------------------------------

        test "the nested index on the primary returns the same rows with nested links" do
          get "/api/v1/ranking_configurations/#{@primary.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal [90, 50, 50], json[:data].map { |row| row[:weight] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists?page=1&per_page=50", json[:links][:self]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists?page=1&per_page=50", json[:links][:first]
        end

        test "the nested index reads the named configuration, and weight is relative to it" do
          RankedList.create!(list: @heavy, ranking_configuration: @year, weight: 5)

          get "/api/v1/ranking_configurations/#{@year.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@year_only.id, @heavy.id], json[:data].map { |row| row[:id] }
          assert_equal [70, 5], json[:data].map { |row| row[:weight] }
          assert_equal 2, json[:meta][:total_count]
        end

        test "the nested total_count equals the configuration's list_count, which links here" do
          get "/api/v1/ranking_configurations/#{@primary.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          total = json[:meta][:total_count]

          get "/api/v1/ranking_configurations/#{@primary.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 3, total
          assert_equal total, json[:data][:list_count]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists", json[:data][:lists_api_url]
        end

        test "the nested index paginates with nested links" do
          get "/api/v1/ranking_configurations/#{@primary.id}/lists?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists?page=1&per_page=2", json[:links][:prev]
        end

        test "the nested index never serves a user-owned, archived or author configuration" do
          archived = ranking_configurations(:books_inherited)
          archived.update!(archived: true)

          [archived, ranking_configurations(:books_user), ranking_configurations(:books_user_shared),
            ranking_configurations(:books_authors_global)].each do |configuration|
            get "/api/v1/ranking_configurations/#{configuration.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_response :not_found, configuration.name
            assert_equal "not_found", json[:code]
          end
        end

        test "a missing parent is a 404 even when the page is also bad" do
          get "/api/v1/ranking_configurations/999999999/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
          assert_equal "No ranking configuration at that address", json[:detail]
        end

        test "a non-numeric configuration id is a routing 404" do
          get "/api/v1/ranking_configurations/primary/lists", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "the bare index ignores a ranking_configuration_id query parameter" do
          get "/api/v1/lists?ranking_configuration_id=#{@year.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          # Response-only: the parameter is deliberately undocumented, and
          # request validation would reject it -- which is the point.
          assert_api_response_conform(status: 200)

          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=50", json[:links][:self]
        end
```

In `web-app/test/lib/api/v1/books/ranking_configuration_resource_test.rb`, in the test "shape", the expected key list becomes:

```ruby
            %i[id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url lists_api_url],
```

and after the `books_api_url` assertion add:

```ruby
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@configuration.id}/lists", hash[:lists_api_url]
```

In `web-app/test/controllers/api/v1/books/ranking_configurations_controller_test.rb`, in the test "index rows are the documented shape with batched counts", the `primary.keys` expectation becomes:

```ruby
          assert_equal %i[id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url lists_api_url], primary.keys
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/lists_controller_test.rb test/lib/api/v1/books/ranking_configuration_resource_test.rb test/controllers/api/v1/books/ranking_configurations_controller_test.rb`
Expected: seven of the eight nested tests fail (routing 404 — the route does not exist yet; "the bare index ignores…" already passes, and "the nested total_count equals…" fails first on the routing 404 and would then fail on the missing `lists_api_url`); the two key-list tests fail on the missing `lists_api_url`.

- [ ] **Step 3: The route**

In `web-app/config/routes.rb`, directly after the `resources :lists, …` line from Task 3:

```ruby
          get "ranking_configurations/:ranking_configuration_id/lists", to: "lists#index",
            as: :ranking_configuration_lists, constraints: {ranking_configuration_id: /\d+/}
```

Run: `bin/rails routes -g 'ranking_configurations/:ranking_configuration_id/lists'`
Expected: one line ending `api/v1/books/lists#index {format: :json, ranking_configuration_id: /\d+/}`.

In `web-app/app/controllers/api/v1/books/lists_controller.rb`, the class comment's route lines become:

```ruby
      # GET /api/v1/lists                              -- the primary ranking's active lists, heaviest first
      # GET /api/v1/ranking_configurations/:id/lists   -- the same, on the named configuration
      # GET /api/v1/lists/:id                          -- any active list, full shape
```

No code change in the controller: `ranking_configuration` and `collection_path` already read the nested id from the path.

- [ ] **Step 4: `lists_api_url` on the resource**

In `web-app/app/lib/api/v1/books/ranking_configuration_resource.rb`, after the `books_api_url` attribute add:

```ruby

        attribute :lists_api_url do |configuration|
          "#{::Api::Host.base_url}/api/v1/ranking_configurations/#{configuration.id}/lists"
        end
```

- [ ] **Step 5: Contract entry, schema field, coverage, served-paths pins**

In `web-app/config/api/v1/openapi.yaml`:

(a) After the `/api/v1/ranking_configurations/{id}/books:` path item (before `/api/v1/lists:`), add:

```yaml
  /api/v1/ranking_configurations/{id}/lists:
    x-domain: books
    get:
      operationId: listRankingConfigurationLists
      summary: Lists behind one configuration
      description: The same rows and shape as `/api/v1/lists`, on the named configuration; `weight` is relative to it.
      parameters:
        - $ref: "#/components/parameters/id"
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of lists.
          headers:
            X-RateLimit-Limit:
              $ref: "#/components/headers/X-RateLimit-Limit"
            X-RateLimit-Remaining:
              $ref: "#/components/headers/X-RateLimit-Remaining"
            X-RateLimit-Reset:
              $ref: "#/components/headers/X-RateLimit-Reset"
            X-RateLimit-Daily-Limit:
              $ref: "#/components/headers/X-RateLimit-Daily-Limit"
            X-RateLimit-Daily-Remaining:
              $ref: "#/components/headers/X-RateLimit-Daily-Remaining"
            X-RateLimit-Daily-Reset:
              $ref: "#/components/headers/X-RateLimit-Daily-Reset"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ListCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
```

(b) In `components.schemas.RankingConfiguration`, the `required` list gains `lists_api_url` at the end:

```yaml
      required: [id, name, kind, primary, year, description, published_at, last_refreshed_at, item_count, list_count, url, api_url, books_api_url, lists_api_url]
```

and after the `books_api_url` property add:

```yaml
        lists_api_url: {type: string, format: uri, description: The active lists that feed it, heaviest first.}
```

In `web-app/test/integration/api/v1/contract_coverage_test.rb`, add to `EXERCISES` after the `/api/v1/ranking_configurations/{id}/books` entries and before the `/api/v1/lists` ones:

```ruby
        ["GET", "/api/v1/ranking_configurations/{id}/lists", "200"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/lists", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/lists", "400"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/lists", "401"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/lists" },
        ["GET", "/api/v1/ranking_configurations/{id}/lists", "403"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/ranking_configurations/{id}/lists", "404"] => -> { get "/api/v1/ranking_configurations/999999999/lists", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/lists", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/lists", headers: bearer(ApiTokenSecrets::MEMBER) } },
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, **both** books-host pins become:

```ruby
        ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}", "/api/v1/ranking_configurations/{id}/books",
          "/api/v1/ranking_configurations/{id}/lists", "/api/v1/lists", "/api/v1/lists/{id}"]
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/ test/integration/api/v1/ test/lib/api/`
Expected: 0 failures, 0 errors.

- [ ] **Step 7: Lint, commit**

Run: `bundle exec standardrb app/controllers/api app/lib/api config/routes.rb test/controllers/api test/integration/api test/lib/api`
Expected: no offenses.

```bash
git add config/routes.rb app/controllers/api/v1/books/lists_controller.rb app/lib/api/v1/books/ranking_configuration_resource.rb config/api/v1/openapi.yaml test/controllers/api/v1/books/lists_controller_test.rb test/lib/api/v1/books/ranking_configuration_resource_test.rb test/controllers/api/v1/books/ranking_configurations_controller_test.rb test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "$(cat <<'EOF'
API: GET /api/v1/ranking_configurations/{id}/lists; lists_api_url

Same action as /api/v1/lists, resolving the configuration from the
path; weight is relative to the configuration the row was read through.
The configuration payload links here now that the route exists.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `ListItemsController` — `GET /api/v1/lists/{id}/items`

**Files:**
- Modify: `web-app/config/routes.rb` (same block)
- Create (generator): `web-app/app/controllers/api/v1/books/list_items_controller.rb`, `web-app/test/controllers/api/v1/books/list_items_controller_test.rb`
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `Books::BaseController#book_items(scope)` (Task 3), `#render_page`, `BookResource.new(book, params: {rank:})` (compact), `::Books::List.active`, `List#list_items`, `::RankedItem`, `::Books::RankingConfiguration.default_primary`; fixtures `books_books(:war_and_peace, :crime_and_punishment, :got, :of_mice_and_men)`, `movies_movies(:matrix)`, `ranking_configurations(:books_global)`.
- Produces: `GET /api/v1/lists/:list_id/items` on the books host, rows `{position: Integer | nil, book: {…compact Book…}}`; `openapi.yaml` path item `/api/v1/lists/{id}/items`, schemas `ListItemRow`, `ListItemCollection`.

- [ ] **Step 1: The route**

In `web-app/config/routes.rb`, directly after the `get "ranking_configurations/:ranking_configuration_id/lists", …` line (two lines) from Task 4:

```ruby
          get "lists/:list_id/items", to: "list_items#index", as: :list_items, constraints: {list_id: /\d+/}
```

Run: `bin/rails routes -g 'lists/:list_id/items'`
Expected: one line `api_v1_list_items GET /api/v1/lists/:list_id/items(.:format) api/v1/books/list_items#index {format: :json, list_id: /\d+/}`.

- [ ] **Step 2: Generate the controller**

Run:
```bash
bin/rails generate controller api/v1/books/list_items index --skip-routes --no-helper -e none --parent=Api::V1::Books::BaseController
```
Expected: `app/controllers/api/v1/books/list_items_controller.rb` and `test/controllers/api/v1/books/list_items_controller_test.rb`. Delete `app/views/api` if the generator created it.

- [ ] **Step 3: Write the failing controller tests**

Replace `web-app/test/controllers/api/v1/books/list_items_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class ListItemsControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @war_and_peace = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @got = books_books(:got)
          @mice = books_books(:of_mice_and_men)
          @list = ::Books::List.create!(name: "Ordered and not", status: :active)
          # Two positioned rows created out of order, two unpositioned rows
          # (served after them, by id), a row with no listable and a row whose
          # listable is a movie -- the last two are neither counted nor served.
          # The movie row is written without validation, which is exactly how
          # an importer would leave it.
          @second = ListItem.create!(list: @list, listable: @crime, position: 2)
          @first = ListItem.create!(list: @list, listable: @war_and_peace, position: 1)
          @unpositioned_a = ListItem.create!(list: @list, listable: @got, position: nil)
          @unpositioned_b = ListItem.create!(list: @list, listable: @mice, position: nil)
          ListItem.create!(list: @list, listable: nil, metadata: {title: "Unresolved"})
          ListItem.new(list: @list, listable: movies_movies(:matrix), position: 3).save!(validate: false)
          # Ranked on the primary: war_and_peace and crime; the other two are unranked.
          RankedItem.create!(item: @war_and_peace, ranking_configuration: @primary, rank: 1, score: 100)
          RankedItem.create!(item: @crime, ranking_configuration: @primary, rank: 2, score: 90)
          @approved = ::Books::List.create!(name: "Approved only", status: :approved)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "index orders by position with nulls last and id as the tiebreak" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal %w[war-and-peace crime-and-punishment a-game-of-thrones of-mice-and-men], json[:data].map { |row| row[:book][:slug] }
          assert_equal [1, 2, nil, nil], json[:data].map { |row| row[:position] }
          assert_equal({page: 1, per_page: 50, total_count: 4, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}/items?page=1&per_page=50", json[:links][:self]
        end

        test "rows are {position, book} with the compact book and its rank on the primary" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          row = json[:data].first
          assert_equal %i[position book], row.keys
          assert_equal %i[id slug title subtitle first_published_year rank authors cover_url url api_url], row[:book].keys
          assert_equal [1, 2, nil, nil], json[:data].map { |r| r[:book][:rank] }, "rank is the primary's and null for an unranked book"
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace", row[:book][:api_url]
        end

        test "a row with no listable and a row whose listable is not a book are neither counted nor served" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 4, json[:meta][:total_count]
          assert_equal 4, json[:data].size
          refute_includes json[:data].map { |row| row[:position] }, 3, "the movie row"
        end

        test "a list's item_count on /lists/{id} equals this endpoint's total_count" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          total = json[:meta][:total_count]

          get "/api/v1/lists/#{@list.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 4, total
          assert_equal total, json[:data][:item_count]
        end

        test "index paginates with the list's links" do
          get "/api/v1/lists/#{@list.id}/items?page=2&per_page=3", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal ["of-mice-and-men"], json[:data].map { |row| row[:book][:slug] }
          assert_equal({page: 2, per_page: 3, total_count: 4, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}/items?page=1&per_page=3", json[:links][:prev]
        end

        test "rank lookups are batched: one ranked_items query whatever the page size" do
          get "/api/v1/lists/#{@list.id}/items?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/lists/#{@list.id}/items?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          four = capture_sql { get "/api/v1/lists/#{@list.id}/items?per_page=4", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, four.size, "query count grew with page size:\n#{four.join("\n")}"
          assert_equal 1, four.count { |sql| sql.include?("ranked_items") }, four.join("\n")
        end

        test "a page past the end is an empty 200 and runs no rank lookup" do
          get "/api/v1/lists/#{@list.id}/items?page=9", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up
          queries = capture_sql { get "/api/v1/lists/#{@list.id}/items?page=9", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 4, json[:meta][:total_count]
          refute queries.any? { |sql| sql.include?("ranked_items") }, "an empty page must not look ranks up:\n#{queries.join("\n")}"
        end

        test "with no primary ranking configuration every rank is null" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [nil, nil, nil, nil], json[:data].map { |row| row[:book][:rank] }
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/lists/#{@list.id}/items?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
        end

        test "a list that is not active is a 404 problem" do
          get "/api/v1/lists/#{@approved.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_equal "No list at that address", json[:detail]
        end

        test "an unknown list is a 404 even when the page is also bad" do
          get "/api/v1/lists/999999999/items?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
        end

        test "a non-numeric list id is a routing 404" do
          get "/api/v1/lists/best/items", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/lists/#{@list.id}/items"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal "insufficient_scope", json[:code]
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/list_items_controller_test.rb`
Expected: the 200 tests fail (nothing rendered; `assert_api_conform` reports no documented operation); the routing 404 and auth tests may already pass.

- [ ] **Step 5: Write the controller**

Replace `web-app/app/controllers/api/v1/books/list_items_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/lists/:list_id/items -- the list's books in list order
      #
      # Rows are {position, book}: position ASC with the unpositioned rows
      # last, then by row id -- the site's order (spec D6). Only rows whose
      # listable is a set Books::Book are counted or served (book_items), so
      # total_count matches the rows. rank on the embedded book is the
      # primary's, batched per page.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class ListItemsController < BaseController
        def index
          list = ::Books::List.active.find(params[:list_id])
          relation = book_items(list.list_items)
            .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
            .order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC"))

          render_page(relation, path: "/api/v1/lists/#{list.id}/items") do |items|
            ranks = ranks_for(items.map(&:listable_id))
            items.map do |item|
              {position: item.position, book: BookResource.new(item.listable, params: {rank: ranks[item.listable_id]}).to_h}
            end
          end
        end

        private

        # {book_id => rank} on the primary configuration in one query; {} when
        # there is no primary or the page is empty. The key is always passed to
        # BookResource (nil for an unranked book) so it never falls back to the
        # per-row primary_ranked_item lookup.
        def ranks_for(book_ids)
          primary = ::Books::RankingConfiguration.default_primary
          return {} if primary.nil? || book_ids.empty?

          ::RankedItem.where(ranking_configuration_id: primary.id, item_type: "Books::Book", item_id: book_ids)
            .pluck(:item_id, :rank).to_h
        end
      end
    end
  end
end
```

- [ ] **Step 6: Contract entry, coverage, served-paths pins**

In `web-app/config/api/v1/openapi.yaml`:

(a) After the `/api/v1/lists/{id}:` path item (before `components:`), add:

```yaml
  /api/v1/lists/{id}/items:
    x-domain: books
    get:
      operationId: listListItems
      summary: Books on one list
      description: The list's books in list order — `position` ascending, unpositioned rows last, then by row id. `position` is null on an unordered list. `rank` on the embedded book is the primary ranking's.
      parameters:
        - $ref: "#/components/parameters/id"
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of the list's books.
          headers:
            X-RateLimit-Limit:
              $ref: "#/components/headers/X-RateLimit-Limit"
            X-RateLimit-Remaining:
              $ref: "#/components/headers/X-RateLimit-Remaining"
            X-RateLimit-Reset:
              $ref: "#/components/headers/X-RateLimit-Reset"
            X-RateLimit-Daily-Limit:
              $ref: "#/components/headers/X-RateLimit-Daily-Limit"
            X-RateLimit-Daily-Remaining:
              $ref: "#/components/headers/X-RateLimit-Daily-Remaining"
            X-RateLimit-Daily-Reset:
              $ref: "#/components/headers/X-RateLimit-Daily-Reset"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ListItemCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
```

(b) At the end of `components.schemas` (after `ListItem`), add:

```yaml
    ListItemRow:
      type: object
      required: [position, book]
      properties:
        position:
          type: [integer, "null"]
          minimum: 1
          description: The book's place on the list as published; null when the list is unordered.
        book:
          $ref: "#/components/schemas/Book"
    ListItemCollection:
      type: object
      required: [data, meta, links]
      properties:
        data:
          type: array
          items:
            $ref: "#/components/schemas/ListItemRow"
        meta:
          $ref: "#/components/schemas/PaginationMeta"
        links:
          $ref: "#/components/schemas/PaginationLinks"
```

In `web-app/test/integration/api/v1/contract_coverage_test.rb`, add to `EXERCISES` after the `/api/v1/lists/{id}` entries — the `/api/v1/lists/{id}` 429 entry is currently last and needs a trailing comma added:

```ruby
        ["GET", "/api/v1/lists/{id}/items", "200"] => -> { get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists/{id}/items", "400"] => -> { get "/api/v1/lists/#{@list.id}/items?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists/{id}/items", "401"] => -> { get "/api/v1/lists/#{@list.id}/items" },
        ["GET", "/api/v1/lists/{id}/items", "403"] => -> { get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/lists/{id}/items", "404"] => -> { get "/api/v1/lists/999999999/items", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/lists/{id}/items", "429"] => -> { with_exhausted_limit { get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER) } }
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, **both** books-host pins gain `"/api/v1/lists/{id}/items"` at the end:

```ruby
        ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}", "/api/v1/ranking_configurations/{id}/books",
          "/api/v1/ranking_configurations/{id}/lists", "/api/v1/lists", "/api/v1/lists/{id}", "/api/v1/lists/{id}/items"]
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/ test/integration/api/v1/`
Expected: 0 failures, 0 errors.

- [ ] **Step 8: Lint, commit**

Run: `bundle exec standardrb app/controllers/api config/routes.rb test/controllers/api test/integration/api`
Expected: no offenses.

```bash
git add app/controllers/api/v1/books/list_items_controller.rb config/routes.rb config/api/v1/openapi.yaml test/controllers/api/v1/books/list_items_controller_test.rb test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "$(cat <<'EOF'
API: GET /api/v1/lists/{id}/items

The list's books in the site's order (position, nulls last, then id),
restricted to rows that resolve to a book so total_count matches the
rows; ranks on the primary batched per page.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `BookListsController` — `GET /api/v1/books/{slug}/lists`

**Files:**
- Modify: `web-app/app/controllers/api/v1/base_controller.rb` (`render_page`)
- Modify: `web-app/config/routes.rb` (same block)
- Create (generator): `web-app/app/controllers/api/v1/books/book_lists_controller.rb`, `web-app/test/controllers/api/v1/books/book_lists_controller_test.rb`
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `Books::BaseController#item_counts_for(list_ids)` (Task 3), `#render_page`, `ListResource` (compact), `::Books::ListsQuery.active_list_conditions` (Task 2), `::Books::Book.find_by!(slug:)`, `::ListItem`, `::Books::RankingConfiguration.default_primary`; fixtures `books_books(:war_and_peace, :crime_and_punishment)`, `ranking_configurations(:books_global, :books_year_2025)`.
- Produces: `Api::V1::BaseController#render_page` counting with `count(:all)` (no signature change); `GET /api/v1/books/:slug/lists` on the books host, rows `{position: Integer | nil, list: {…compact List…}}`; `openapi.yaml` path item `/api/v1/books/{slug}/lists`, schemas `BookListingRow`, `BookListingCollection`.

- [ ] **Step 1: The route**

In `web-app/config/routes.rb`, directly after `resources :books, only: [:index, :show], param: :slug`:

```ruby
          get "books/:slug/lists", to: "book_lists#index", as: :book_lists
```

Run: `bin/rails routes -g 'books/:slug/lists'`
Expected: one line `api_v1_book_lists GET /api/v1/books/:slug/lists(.:format) api/v1/books/book_lists#index {format: :json}`.

- [ ] **Step 2: Generate the controller**

Run:
```bash
bin/rails generate controller api/v1/books/book_lists index --skip-routes --no-helper -e none --parent=Api::V1::Books::BaseController
```
Expected: `app/controllers/api/v1/books/book_lists_controller.rb` and `test/controllers/api/v1/books/book_lists_controller_test.rb`. Delete `app/views/api` if the generator created it.

- [ ] **Step 3: Write the failing controller tests**

Replace `web-app/test/controllers/api/v1/books/book_lists_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class BookListsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @book = books_books(:war_and_peace)
          # Created in an order that differs from the weight order, so the two
          # orderings (weighted first on the primary; by id with no primary)
          # are distinguishable. Two weighted on the primary, one active on no
          # configuration, one active on the year configuration only, one
          # approved-not-active, and one the book is not on at all.
          @weighted_low = list_with(@book, "Weighted low", position: nil, weight: 20)
          @weighted_high = list_with(@book, "Weighted high", position: 3, weight: 80)
          @unweighted = list_with(@book, "Unweighted", position: 7, weight: nil)
          @year_only = list_with(@book, "Year only", position: 1, weight: nil)
          RankedList.create!(list: @year_only, ranking_configuration: ranking_configurations(:books_year_2025), weight: 60)
          @approved = list_with(@book, "Approved", position: 1, weight: 50, status: :approved)
          @other = list_with(books_books(:crime_and_punishment), "Another book's list", position: 1, weight: 99)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "index lists the active lists the book is on, weighted first, with its position on each" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal [@weighted_high.id, @weighted_low.id, @unweighted.id, @year_only.id], json[:data].map { |row| row[:list][:id] }
          assert_equal [80, 20, nil, nil], json[:data].map { |row| row[:list][:weight] }, "weight is the primary's; null off it, ordered after the weighted rows"
          assert_equal [3, nil, 7, 1], json[:data].map { |row| row[:position] }
          assert_equal({page: 1, per_page: 50, total_count: 4, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace/lists?page=1&per_page=50", json[:links][:self]
        end

        test "rows are {position, list} with the compact list and a batched item_count" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          row = json[:data].first
          assert_equal %i[position list], row.keys
          assert_equal %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url], row[:list].keys
          assert_equal [1, 1, 1, 1], json[:data].map { |r| r[:list][:item_count] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@weighted_high.id}/items", row[:list][:items_api_url]
        end

        test "index excludes a list that is not active and lists the book is not on" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          ids = json[:data].map { |row| row[:list][:id] }
          refute_includes ids, @approved.id, "approved, not active"
          refute_includes ids, @other.id, "another book's list"
        end

        test "index paginates" do
          get "/api/v1/books/#{@book.slug}/lists?page=2&per_page=3", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@year_only.id], json[:data].map { |row| row[:list][:id] }
          assert_equal({page: 2, per_page: 3, total_count: 4, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace/lists?page=1&per_page=3", json[:links][:prev]
        end

        test "with no primary ranking configuration every weight is null and the order is by list id" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@weighted_low.id, @weighted_high.id, @unweighted.id, @year_only.id], json[:data].map { |row| row[:list][:id] }
          assert_equal [nil, nil, nil, nil], json[:data].map { |row| row[:list][:weight] }
          assert_equal 4, json[:meta][:total_count]
        end

        test "a book on no list is an empty 200" do
          get "/api/v1/books/#{books_books(:got).slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index query count does not grow with page size" do
          get "/api/v1/books/#{@book.slug}/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/books/#{@book.slug}/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          four = capture_sql { get "/api/v1/books/#{@book.slug}/lists?per_page=4", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, four.size, "query count grew with page size:\n#{four.join("\n")}"
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/books/#{@book.slug}/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
        end

        test "an unknown slug is a 404 problem" do
          get "/api/v1/books/no-such-book/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_equal "No book at that address", json[:detail]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "a missing book is a 404 even when the page is also bad" do
          get "/api/v1/books/no-such-book/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
        end

        test "the lookup does not fall back to a primary key" do
          get "/api/v1/books/#{@book.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/books/#{@book.slug}/lists"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal "insufficient_scope", json[:code]
        end

        private

        def list_with(book, name, position:, weight:, status: :active)
          list = ::Books::List.create!(name: name, status: status)
          ListItem.create!(list: list, listable: book, position: position)
          RankedList.create!(list: list, ranking_configuration: @primary, weight: weight) if weight
          list
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/book_lists_controller_test.rb`
Expected: the 200 tests fail (nothing rendered; no documented operation); the routing/host and auth tests may already pass.

- [ ] **Step 5: `render_page` counts with `count(:all)`**

In `web-app/app/controllers/api/v1/base_controller.rb`, replace the `render_page` method's comment and first line so they read:

```ruby
      # Paginates a relation (or nil, when there is nothing to read from) and
      # renders the collection envelope. The block receives the page's rows as
      # an Array and returns their hashes, so a controller can batch per-page
      # lookups (counts, ranks) before mapping. Page params are validated even
      # when the relation is nil so a bad page is always a 400 -- the COUNT is
      # cheap and runs regardless, but a page beyond total_pages skips the
      # offset query entirely rather than asking Postgres to run and discard it.
      #
      # count(:all), not count: a relation carrying a custom select (a book's
      # listings ride their weight along) would otherwise be counted as
      # COUNT(<select list>), which Postgres rejects. It is what Pagy does too.
      def render_page(relation, path:)
        page = ::Api::Page.from_params(params, total_count: relation&.count(:all) || 0)
```

(the rest of the method is unchanged).

- [ ] **Step 6: Write the controller**

Replace `web-app/app/controllers/api/v1/books/book_lists_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/books/:slug/lists -- every active list the book is on
      #
      # Rows are {position, list}: the book's position on that list and the
      # compact list, whose weight is the primary configuration's or null when
      # the list does not feed it (spec D7). Weighted lists come first; a
      # null-weight row is self-describing, so "100 Notable Books of 2024" is
      # visible from the book's side while /lists/{id} serves it.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class BookListsController < BaseController
        def index
          # find_by!(slug:), never friendly.find: 137 books have purely numeric
          # slugs and friendly_id resolves slugs before primary keys.
          book = ::Books::Book.find_by!(slug: params[:slug])

          render_page(listings_for(book), path: "/api/v1/books/#{book.slug}/lists") do |items|
            counts = item_counts_for(items.map(&:list_id))
            items.map do |item|
              {position: item.position, list: ListResource.new(item.list, params: {weight: item.weight, item_count: counts.fetch(item.list_id, 0)}).to_h}
            end
          end
        end

        private

        # The book's rows on active books lists, each carrying the list's
        # weight on the primary configuration (NULL off it) so the database
        # orders weighted lists first and pagination stays consistent. With
        # no primary yet every weight is NULL and the order is by list id.
        #
        # preload, not includes: where(lists: …) references the lists table,
        # which would promote includes to an eager-load JOIN and clash with
        # the custom select.
        def listings_for(book)
          relation = ::ListItem.where(listable: book).joins(:list)
            .where(::Books::ListsQuery.active_list_conditions)
            .preload(:list)
          primary = ::Books::RankingConfiguration.default_primary

          if primary.nil?
            return relation
                .select("list_items.*, NULL::integer AS weight")
                .order(Arel.sql("lists.id ASC"))
          end

          relation
            .joins(
              "LEFT OUTER JOIN ranked_lists ON ranked_lists.list_id = lists.id " \
              "AND ranked_lists.ranking_configuration_id = #{primary.id.to_i}"
            )
            .select("list_items.*, ranked_lists.weight AS weight")
            .order(Arel.sql("ranked_lists.weight DESC NULLS LAST, lists.id ASC"))
        end
      end
    end
  end
end
```

- [ ] **Step 7: Contract entry, coverage, served-paths pins**

In `web-app/config/api/v1/openapi.yaml`:

(a) After the `/api/v1/books/{slug}:` path item (before `/api/v1/authors:`), add:

```yaml
  /api/v1/books/{slug}/lists:
    x-domain: books
    get:
      operationId: listBookLists
      summary: Lists a book is on
      description: Every active list the book appears on, with its `position` there. Lists that feed the primary ranking come first, heaviest first; the rest follow by id with `weight` null.
      parameters:
        - $ref: "#/components/parameters/slug"
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of the book's listings.
          headers:
            X-RateLimit-Limit:
              $ref: "#/components/headers/X-RateLimit-Limit"
            X-RateLimit-Remaining:
              $ref: "#/components/headers/X-RateLimit-Remaining"
            X-RateLimit-Reset:
              $ref: "#/components/headers/X-RateLimit-Reset"
            X-RateLimit-Daily-Limit:
              $ref: "#/components/headers/X-RateLimit-Daily-Limit"
            X-RateLimit-Daily-Remaining:
              $ref: "#/components/headers/X-RateLimit-Daily-Remaining"
            X-RateLimit-Daily-Reset:
              $ref: "#/components/headers/X-RateLimit-Daily-Reset"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/BookListingCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
```

(b) At the end of `components.schemas` (after `ListItemCollection`), add:

```yaml
    BookListingRow:
      type: object
      required: [position, list]
      properties:
        position:
          type: [integer, "null"]
          minimum: 1
          description: The book's place on this list as published; null when the list is unordered.
        list:
          $ref: "#/components/schemas/List"
    BookListingCollection:
      type: object
      required: [data, meta, links]
      properties:
        data:
          type: array
          items:
            $ref: "#/components/schemas/BookListingRow"
        meta:
          $ref: "#/components/schemas/PaginationMeta"
        links:
          $ref: "#/components/schemas/PaginationLinks"
```

In `web-app/test/integration/api/v1/contract_coverage_test.rb`, add to `EXERCISES` after the `/api/v1/books/{slug}` entries and before the `/api/v1/authors` ones:

```ruby
        ["GET", "/api/v1/books/{slug}/lists", "200"] => -> { get "/api/v1/books/#{books_books(:war_and_peace).slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}/lists", "400"] => -> { get "/api/v1/books/war-and-peace/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}/lists", "401"] => -> { get "/api/v1/books/war-and-peace/lists" },
        ["GET", "/api/v1/books/{slug}/lists", "403"] => -> { get "/api/v1/books/war-and-peace/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/books/{slug}/lists", "404"] => -> { get "/api/v1/books/no-such-book/lists", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}/lists", "429"] => -> { with_exhausted_limit { get "/api/v1/books/war-and-peace/lists", headers: bearer(ApiTokenSecrets::MEMBER) } },
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, **both** books-host pins become (final form — `/api/v1/books/{slug}/lists` sits after `/api/v1/books/{slug}`, matching the document):

```ruby
        ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/books/{slug}/lists", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}", "/api/v1/ranking_configurations/{id}/books",
          "/api/v1/ranking_configurations/{id}/lists", "/api/v1/lists", "/api/v1/lists/{id}", "/api/v1/lists/{id}/items"]
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/ test/integration/api/v1/ test/lib/api/`
Expected: 0 failures, 0 errors — including every earlier collection, which now counts with `count(:all)`.

- [ ] **Step 9: Lint, commit**

Run: `bundle exec standardrb app/controllers/api config/routes.rb test/controllers/api test/integration/api`
Expected: no offenses.

```bash
git add app/controllers/api/v1/base_controller.rb app/controllers/api/v1/books/book_lists_controller.rb config/routes.rb config/api/v1/openapi.yaml test/controllers/api/v1/books/book_lists_controller_test.rb test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "$(cat <<'EOF'
API: GET /api/v1/books/{slug}/lists

Every active list the book is on, weighted on the primary first and the
rest by id with a null weight; the weight rides along on a LEFT JOIN so
the order is the database's. render_page counts with count(:all) so a
relation with a custom select can be paginated.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Docs page pins, E2E assertion, feature doc, full verification

**Files:**
- Modify: `web-app/test/controllers/developers_controller_test.rb` (the tests "documents the endpoints this host serves and only those", line ~56, and "lists query parameters only, never a path parameter", line ~78)
- Modify: `web-app/e2e/tests/books/member/developers-tokens.spec.ts` (after the ranking-configurations block, line ~82)
- Modify: `docs/features/public-api.md`

**Interfaces:**
- Consumes: the five operationIds from Tasks 3–6 (`listLists`, `getList`, `listListItems`, `listBookLists`, `listRankingConfigurationLists`); the E2E member fixture's `secret`.
- Produces: nothing new; this task proves and records.

- [ ] **Step 1: Pin the anchors on `/developers`**

In `web-app/test/controllers/developers_controller_test.rb`, in the test "documents the endpoints this host serves and only those", after `assert_select "[id=?]", "endpoint-listRankingConfigurationBooks"` add:

```ruby
    assert_select "[id=?]", "endpoint-listRankingConfigurationLists"
    assert_select "[id=?]", "endpoint-listLists"
    assert_select "[id=?]", "endpoint-getList"
    assert_select "[id=?]", "endpoint-listListItems"
    assert_select "[id=?]", "endpoint-listBookLists"
```

and in the music-host half, after `assert_select "[id=?]", "endpoint-listRankingConfigurations", count: 0` add:

```ruby
    assert_select "[id=?]", "endpoint-listLists", count: 0
```

In the test "lists query parameters only, never a path parameter", the two loops become:

```ruby
    %w[listBooks listAuthors listLists].each do |operation_id|
      assert_select "[id=endpoint-#{operation_id}] code", text: "page"
      assert_select "[id=endpoint-#{operation_id}] code", text: "per_page"
    end
    %w[getBook getAuthor].each do |operation_id|
      assert_select "[id=endpoint-#{operation_id}] code", text: "slug", count: 0
    end
    assert_select "[id=endpoint-getList] code", text: "id", count: 0
```

Run: `bin/rails test test/controllers/developers_controller_test.rb`
Expected: passes — the page renders from the document, so the anchors already exist.

- [ ] **Step 2: The E2E assertion (not run on this machine)**

In `web-app/e2e/tests/books/member/developers-tokens.spec.ts`, after the block ending `expect(configurationsBody.data[0]).toMatchObject({ kind: 'books', primary: true });`, add:

```ts
    // The lists resource answers on the same token; its first row is the
    // heaviest list on the primary and carries the weight that ranking gave it.
    const lists = await page.request.get('/api/v1/lists?per_page=1', {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(lists.status()).toBe(200);
    const listsBody = await lists.json();
    expect(listsBody.data).toHaveLength(1);
    expect(listsBody.data[0]).toHaveProperty('weight');
    expect(listsBody.data[0]).toHaveProperty('items_api_url');
```

Do **not** run it here: `web-app/e2e/.env` is absent on this machine and the `books-member` project needs it. State that in the task report. Wherever it can run: `yarn build:all && bin/rails server` in one terminal (only if port 3000 is this worktree's — see Global Constraints), then `yarn test:e2e --project books-member e2e/tests/books/member/developers-tokens.spec.ts`.

- [ ] **Step 3: Feature doc**

In `docs/features/public-api.md`:

(a) In the "Shape" bullet, after the sentence ending "an unknown one the `not_found` problem." and before "Spec: `docs/superpowers/specs/2026-09-20-…`", add:

```
`/api/v1/lists` is the primary configuration's active lists, heaviest first, and `/api/v1/ranking_configurations/{id}/lists` the same rows on the named configuration — `weight` is always relative to the configuration the row was read through; `/api/v1/lists/{id}` answers for any active list with its weight on the primary or `null`. `/api/v1/lists/{id}/items` is the list's books in the site's order (`position` ascending, unpositioned rows last, then id), restricted to rows that resolve to a book so `total_count` matches the rows and equals the list's `item_count`; `/api/v1/books/{slug}/lists` is the other side, every active list a book is on with its `position`, weighted lists first. Lists have no slug and are addressed by integer id. The list payload carries no editorial flags and no weight breakdown; a list's `source_url` is the original list on the web and is not validated as a URI (a few hold more than one address).
```

(b) Replace the "Not yet" line with:

```
`/api/v1/authors/{slug}/books` (increment 6); search, filters, music/games resources, OAuth/MCP.
```

- [ ] **Step 4: Full verification**

Run, from `web-app/`:

```bash
bin/rails test 2>&1 | tail -20
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: `0 failures, 0 errors, 0 skips`; no offenses; `All is good!`. Scan the full test output for warning lines: none beyond the two known npm/yarn ones during `test:prepare` (and `weighted_list_rank`'s position `puts`).

- [ ] **Step 5: Commit**

```bash
git add test/controllers/developers_controller_test.rb e2e/tests/books/member/developers-tokens.spec.ts ../docs/features/public-api.md
git commit -m "$(cat <<'EOF'
API docs and E2E: lists

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

Then open the PR against `main` (title `Public API: lists`, body summarising the five endpoints, `lists_api_url`, the two shared predicates and the `count(:all)` change, noting that the E2E assertion was added but not run on this machine, ending with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`).

---

## Self-review against the spec

- **D1** — `weight` relative to the configuration read through: Task 4 test "weight is relative to it"; show on the primary or null (Task 3 tests "off the primary with a null weight", "no primary … null weight"). ✔
- **D2** — one index action, optionally nested: Task 4 routes `lists#index` for both paths; no code change in the controller, the base helpers do it. ✔
- **D4** — integer ids: `constraints:` on all four new routes; routing-404 tests in Tasks 3–5; unknown-id 404 problems in the coverage map. ✔
- **D5** — `/lists/{id}` any active list, `/lists` the primary's: Task 3 tests "excludes active lists off the configuration and inactive lists on it", "show answers for an active list off the primary", "not active is a 404", "never serves a list of another medium". ✔
- **D6** — `{position, book}`, `position ASC NULLS LAST, id ASC`, filtered to set `Books::Book` rows: Task 5 tests "orders by position with nulls last", "neither counted nor served", "item_count … equals … total_count". ✔
- **D7** — a book's listings, weight from the primary or null, `weight DESC NULLS LAST, lists.id`: Task 6 tests "weighted first", "no primary … by list id", "excludes … not active". ✔
- **D10** — no editorial flags, breakdown, `metadata`, `verified`: Task 1 test "carries no editorial flags"; rows in Tasks 5–6 expose only `position`. ✔
- **D11** — no new codes, scopes or parameters: only `page`/`per_page`; `Api::Problem::CODES` untouched. ✔
- **Parent before page** — Task 4 "a missing parent is a 404 even when the page is also bad", Task 5 "an unknown list is a 404 even when the page is also bad", Task 6 "a missing book is a 404 even when the page is also bad". ✔
- **§2 counts and ranks batched per page, none on an empty page** — `item_counts_for`/`ranks_for` return `{}` for `[]`; Task 3 "runs no item-count lookup", Task 5 "runs no rank lookup", "one ranked_items query whatever the page size"; query-count tests in Tasks 3, 5, 6. ✔
- **§2 `list_count == /ranking_configurations/{id}/lists` `total_count`** — Task 2 shares the predicate; Task 4 test "the nested total_count equals the configuration's list_count". ✔
- **§2 `item_count == /lists/{id}/items` `total_count`** — Task 3 `book_items`/`item_counts_for`; Task 5 cross-check test. ✔
- **§2 root-anchoring** — Global Constraints; every controller and test is written `::Books::…`. ✔
- **§4 payloads** — key orders pinned in Task 1 (resource) and Tasks 3, 5, 6 (rows); `lists_api_url` in Task 4; nullables per the measured data. ✔
- **§5 contract** — five path items, eight schemas, `x-domain: books`; 404 only on the id/parent-addressed paths (`/lists` documents none); both served-paths pins updated in every task that adds a path; `/developers` anchors pinned in Task 7. ✔
- **§6 errors** — no new codes; `not_found` details name the missing record. ✔
- **§Testing → E2E** — Task 7 Step 2, added and deliberately not run here. ✔
- **§Increments item 2** — everything listed is in a task; nothing from item 3 (author books) is. ✔
- **Deferred minors** — the active-list predicate: Task 2. The other two are left alone on purpose (Global Constraints, last bullet). ✔
