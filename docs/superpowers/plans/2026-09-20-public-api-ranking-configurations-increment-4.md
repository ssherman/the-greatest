# Public API — Increment 4 (Ranking configurations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `GET /api/v1/ranking_configurations`, `GET /api/v1/ranking_configurations/{id}` and `GET /api/v1/ranking_configurations/{id}/books` on the books host, documented in the OpenAPI contract and covered by the contract-coverage gate.

**Architecture:** Nothing new in the framework's auth, rate-limit or error layers. `Api::V1::BaseController` gains `render_page` (yields the page's rows as an array so a controller can batch per-page lookups) and `render_ranked_page` is re-expressed on top of it. `Api::V1::Books::BaseController` gains `ranking_configuration` (the configuration named in the path, else the primary) and `collection_path` (the nested or bare base path for `links`); `BooksController#index` switches to both, which is what makes `/api/v1/ranking_configurations/{id}/books` the same action as `/api/v1/books`. A new Alba `RankingConfigurationResource` and `RankingConfigurationsController` (index, show) complete the resource. The contract gains three path items tagged `x-domain: books`.

**Tech Stack:** Rails 8.1, Postgres, Minitest 6 + fixtures + Mocha, Alba 4 (symbol keys via `config/initializers/alba.rb`), openapi_first 3.4 (test only), Playwright (local only).

**Spec:** `docs/superpowers/specs/2026-09-20-public-api-lists-and-rankings-design.md` — D1 (configurations are a resource; `rank` is "on the configuration you read it through"), D2 (one index action, optionally nested), D3 (only global, unarchived `Books::RankingConfiguration` rows are addressable; `kind` from day one), D4 (integer ids with a `/\d+/` route constraint), D10 (no algorithm parameters), §Increments item 1 (no `lists_api_url` until the lists route exists). The framework spec (`docs/superpowers/specs/2026-09-12-public-api-framework-design.md`) still governs everything this rides on. Increment 2's plan (`docs/superpowers/plans/2026-09-14-public-api-authors-increment-2.md`) is the shape this one copies; do not re-execute it.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **Work in a worktree** created with the `EnterWorktree` tool (never `git worktree add`), branch `public-api-ranking-configurations`, based on `main`. Never commit to `main`.
- **Use Rails generators** for the controller (`bin/rails generate controller …`); never hand-create it. Delete any `app/views/api/` directory the generator leaves behind.
- **Root-anchor every model reference inside `module Api::V1::Books`**: `::Books::RankingConfiguration`, `::Books::RankedBooksQuery`, `::RankedItem`, `::RankedList`, `::List`, `::Api::Host`. A bare `Books::` inside `Api::V1::Books` resolves to `Api::V1::Books::…` and raises `NameError` at request time, not load time — the controller tests are what catch it.
- **Only `::Books::RankingConfiguration.global.active` rows are addressable** (D3). `find` on that scope is the lookup everywhere; STI means the authors configuration (`Books::Authors::RankingConfiguration`) is not found by it either. A user-owned configuration is a 404 whether or not it is `user_shared`.
- **Ids are integers** (D4): `constraints: {id: /\d+/}` on the `resources` line, `constraints: {ranking_configuration_id: /\d+/}` on the nested `get`. A non-numeric id is a routing 404; an unknown numeric id is the `not_found` problem.
- **Parent before page**: the nested books index resolves the configuration before `Api::Page` parses `page`/`per_page`, so `/ranking_configurations/<private>/books?page=0` is a 404, not a 400.
- **Payload keys, in order** (the contract): `id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url`. No `lists_api_url` in this increment. No algorithm parameters (D10).
- Timestamps are ISO 8601 UTC strings (`Time#utc.iso8601`), `null` when unset.
- `item_count` = `RankedItem` rows on the configuration with `item_type: "Books::Book"` and a non-null `rank`. `list_count` = `RankedList` rows on the configuration whose list is a `Books::List` with status `active` — the same predicate `::Books::ListsQuery` uses, so it will equal increment 5's `/ranking_configurations/{id}/lists` `total_count`.
- **Every API integration test ends in `assert_api_conform(status:)`** (request + response) or, for deliberately invalid requests, `assert_api_response_conform(status:)`. New endpoints need `openapi.yaml` entries with `x-domain: books` on the path item, and `EXERCISES` in `test/integration/api/v1/contract_coverage_test.rb` must gain every new (method, path, status) or the gate fails. `test/controllers/api/v1/openapi_controller_test.rb` pins the exact `paths.keys` list on the books host and must be updated in the same task as any new path.
- Alba returns **symbol** keys (`config/initializers/alba.rb`). Key order in a resource IS the order in `openapi.yaml`.
- Rails 8.1 ships `assert_no_queries`; `capture_sql` comes from `test/support/sql_capture.rb`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- Minitest 6: `assert_nil x`, never `assert_equal nil, x`.
- A clean `bin/rails test` adds **no warning lines** beyond the two known npm/yarn ones during `test:prepare`.
- Tests mirror `app/` and are namespaced to match (`module Api; module V1; module Books; class RankingConfigurationsControllerTest`).
- Controller tests assert behaviour (status, headers, JSON keys and values), never HTML or copy.
- The dev database is shared with other worktrees and not disposable: no `db:reset`, no `delete_all` outside `RAILS_ENV=test`. This increment has **no migration**.
- `CI=1 bin/rails zeitwerk:check` must pass after every task that adds a file under `app/lib`.
- Commit after every task, ending the message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- The E2E addition (Task 4) is not run by CI. Before `yarn test:e2e` confirm port 3000 is this worktree's server (`lsof -nP -iTCP:3000 -sTCP:LISTEN` on macOS); if another checkout holds it, stop and say so — do not kill it, do not use another port.

---

## File structure

| File | Responsibility |
|---|---|
| `app/controllers/api/v1/base_controller.rb` | **modify**: add `render_page(relation, path:) { \|rows\| … }`; `render_ranked_page` delegates to it |
| `app/controllers/api/v1/books/base_controller.rb` | **modify**: `ranking_configuration`, `collection_path(suffix)` |
| `app/controllers/api/v1/books/books_controller.rb` | **modify**: `index` reads `ranking_configuration` and `collection_path("books")` |
| `app/lib/api/v1/books/ranking_configuration_resource.rb` | Alba: the one configuration shape |
| `test/lib/api/v1/books/ranking_configuration_resource_test.rb` | shape, `kind`, timestamps, counts from params, URLs |
| `app/controllers/api/v1/books/ranking_configurations_controller.rb` | index (primary first) and show |
| `test/controllers/api/v1/books/ranking_configurations_controller_test.rb` | endpoint behaviour, scope (D3), counts, N+1 |
| `test/controllers/api/v1/books/books_controller_test.rb` | **modify**: the nested index cases |
| `config/routes.rb` | **modify**: `resources :ranking_configurations` + the nested `get` in the books API scope |
| `config/api/v1/openapi.yaml` | **modify**: three path items, `RankingConfiguration`/`RankingConfigurationCollection`/`RankingConfigurationItem` schemas, the `id` parameter |
| `test/integration/api/v1/contract_coverage_test.rb` | **modify**: sixteen `EXERCISES` entries |
| `test/controllers/api/v1/openapi_controller_test.rb` | **modify**: the books-host `paths.keys` list |
| `test/controllers/developers_controller_test.rb` | **modify**: pin the three new endpoint anchors |
| `e2e/tests/books/member/developers-tokens.spec.ts` | **modify**: one `page.request.get('/api/v1/ranking_configurations')` |
| `docs/features/public-api.md` | **modify**: the resource is shipped; "Not yet" shrinks |

What this increment does **not** touch: the three `Api::` concerns, `Services::Api::*`, `Api::Page`/`Problem`/`Host`, `BookResource`, `AuthorsController`, `::Books::RankedBooksQuery`, any model.

---

### Task 1: `Api::V1::Books::RankingConfigurationResource`

**Files:**
- Create: `web-app/app/lib/api/v1/books/ranking_configuration_resource.rb`
- Test: `web-app/test/lib/api/v1/books/ranking_configuration_resource_test.rb`

**Interfaces:**
- Consumes: `Api::Host.base_url` (→ `"https://dev-new.thegreatestbooks.org"` when `Current.domain = :books` in test); `Books::RankingConfiguration` — `id`, `name`, `primary` (boolean), `year` (integer or nil), `description`, `published_at`, `last_refreshed_at` (times or nil).
- Produces: `Api::V1::Books::RankingConfigurationResource.new(configuration, params: {item_count: Integer, list_count: Integer}).to_h`. Keys, in order: `id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url`. Both params are **required** (`fetch`) — a caller that forgets one gets a `KeyError` in tests, not a silent `null` in production.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/api/v1/books/ranking_configuration_resource_test.rb`:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class RankingConfigurationResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          @configuration = ranking_configurations(:books_global)
        end

        test "shape" do
          hash = RankingConfigurationResource.new(@configuration, params: {item_count: 12, list_count: 3}).to_h

          assert_equal(
            %i[id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url],
            hash.keys
          )
          assert_equal @configuration.id, hash[:id]
          assert_equal "Global Books Ranking", hash[:name]
          assert_equal "books", hash[:kind]
          assert_equal true, hash[:primary]
          assert_nil hash[:year]
          assert_equal "The main ranking configuration for books", hash[:description]
          assert_equal "2025-07-09T23:38:50Z", hash[:published_at]
          assert_nil hash[:last_refreshed_at]
          assert_equal 12, hash[:item_count]
          assert_equal 3, hash[:list_count]
          assert_equal "https://dev-new.thegreatestbooks.org/rc/#{@configuration.id}", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@configuration.id}", hash[:api_url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@configuration.id}/books", hash[:books_api_url]
        end

        test "a non-primary configuration with a year" do
          hash = RankingConfigurationResource.new(ranking_configurations(:books_year_2025), params: {item_count: 0, list_count: 0}).to_h

          assert_equal false, hash[:primary]
          assert_equal 2025, hash[:year]
          assert_nil hash[:published_at]
        end

        test "timestamps are ISO 8601 in UTC" do
          @configuration.update!(last_refreshed_at: Time.zone.parse("2026-09-19 08:15:00 UTC"))

          hash = RankingConfigurationResource.new(@configuration, params: {item_count: 0, list_count: 0}).to_h

          assert_equal "2026-09-19T08:15:00Z", hash[:last_refreshed_at]
        end

        test "the counts are required" do
          assert_raises(KeyError) { RankingConfigurationResource.new(@configuration).to_h }
          assert_raises(KeyError) { RankingConfigurationResource.new(@configuration, params: {item_count: 1}).to_h }
        end

        test "the shape carries no algorithm parameters" do
          hash = RankingConfigurationResource.new(@configuration, params: {item_count: 0, list_count: 0}).to_h

          %i[exponent bonus_pool_percentage min_list_weight list_limit algorithm_version].each do |key|
            refute hash.key?(key), key
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/api/v1/books/ranking_configuration_resource_test.rb`
Expected: every test errors with `NameError: uninitialized constant Api::V1::Books::RankingConfigurationResource`.

- [ ] **Step 3: Write the resource**

`web-app/app/lib/api/v1/books/ranking_configuration_resource.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # A ranking configuration as the API presents it: one shape for index
      # and show. Key order here IS the order in config/api/v1/openapi.yaml.
      #
      # `kind` is always "books" on this host today; it is in the payload so
      # that author configurations (and, on music, albums vs songs) can join
      # additively. The algorithm parameters are deliberately absent (spec D10).
      #
      # Both counts are params the controller batches per page -- `fetch`, so a
      # caller that forgets one fails loudly instead of rendering null.
      class RankingConfigurationResource
        include Alba::Resource

        attributes :id, :name

        attribute :kind do
          "books"
        end

        attributes :primary, :year, :description

        attribute :published_at do |configuration|
          configuration.published_at&.utc&.iso8601
        end

        attribute :last_refreshed_at do |configuration|
          configuration.last_refreshed_at&.utc&.iso8601
        end

        attribute :item_count do
          params.fetch(:item_count)
        end

        attribute :list_count do
          params.fetch(:list_count)
        end

        attribute :url do |configuration|
          "#{::Api::Host.base_url}/rc/#{configuration.id}"
        end

        attribute :api_url do |configuration|
          "#{::Api::Host.base_url}/api/v1/ranking_configurations/#{configuration.id}"
        end

        attribute :books_api_url do |configuration|
          "#{::Api::Host.base_url}/api/v1/ranking_configurations/#{configuration.id}/books"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/api/v1/books/ranking_configuration_resource_test.rb`
Expected: 5 runs, 0 failures, 0 errors.

- [ ] **Step 5: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/lib/api/v1/books/ranking_configuration_resource.rb test/lib/api/v1/books/ranking_configuration_resource_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; `All is good!`.

```bash
git add app/lib/api/v1/books/ranking_configuration_resource.rb test/lib/api/v1/books/ranking_configuration_resource_test.rb
git commit -m "$(cat <<'EOF'
API: RankingConfigurationResource

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `RankingConfigurationsController`, routes, contract entries, coverage

The contract-coverage gate is what makes these one task: the document, the endpoints and the `EXERCISES` map have to land together or `contract_coverage_test.rb` is red in between. The nested books route is Task 3; this task ships the resource alone.

**Files:**
- Modify: `web-app/app/controllers/api/v1/base_controller.rb` (`render_ranked_page`, lines ~44–56)
- Modify: `web-app/config/routes.rb` (the `scope module: :books do` block inside `namespace :api … namespace :v1`, line ~625)
- Create (generator): `web-app/app/controllers/api/v1/books/ranking_configurations_controller.rb`, `web-app/test/controllers/api/v1/books/ranking_configurations_controller_test.rb`
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `Api::V1::Books::BaseController` (`require_scope "books:read"`), `Api::V1::Books::RankingConfigurationResource` (Task 1), `::Books::RankingConfiguration.global.active`, `::RankedItem`, `::RankedList`, `::List.statuses`, test helpers `bearer(secret)`, `assert_api_conform`, `assert_api_response_conform`, `capture_sql`, `ApiTokenSecrets::{MEMBER, MUSIC_ONLY, NON_MEMBER}`, fixtures `ranking_configurations(:books_global, :books_inherited, :books_year_2025, :books_user, :books_user_shared, :books_authors_global)`, `lists(:books_list)`, `ranked_lists(:books_ranked_list)`, `books_books(:war_and_peace, :crime_and_punishment)`.
- Produces: `Api::V1::BaseController#render_page(relation, path:) { |rows| array_of_hashes }` (rows is an `Array`, possibly empty); `GET /api/v1/ranking_configurations`, `GET /api/v1/ranking_configurations/:id` on the books host; `openapi.yaml` path items `/api/v1/ranking_configurations`, `/api/v1/ranking_configurations/{id}`, schemas `RankingConfiguration`, `RankingConfigurationCollection`, `RankingConfigurationItem`, parameter `id`.

- [ ] **Step 1: `render_page` in the base controller**

In `web-app/app/controllers/api/v1/base_controller.rb`, replace the `render_ranked_page` method (comment included) with:

```ruby
      # Paginates a relation (or nil, when there is nothing to read from) and
      # renders the collection envelope. The block receives the page's rows as
      # an Array and returns their hashes, so a controller can batch per-page
      # lookups (counts, ranks) before mapping. Page params are validated even
      # when the relation is nil so a bad page is always a 400 -- the COUNT is
      # cheap and runs regardless, but a page beyond total_pages skips the
      # offset query entirely rather than asking Postgres to run and discard it.
      def render_page(relation, path:)
        page = ::Api::Page.from_params(params, total_count: relation&.count || 0)
        rows = (relation && page.page <= page.total_pages) ? relation.offset(page.offset).limit(page.per_page).to_a : []

        render json: {
          data: yield(rows),
          meta: page.meta,
          links: page.links("#{::Api::Host.base_url}#{path}")
        }
      end

      # One row at a time, for collections with no per-page lookups. The block
      # turns one row into its hash.
      def render_ranked_page(relation, path:, &row)
        render_page(relation, path:) { |rows| rows.map(&row) }
      end
```

Run: `bin/rails test test/controllers/api/v1/books/`
Expected: the existing books and authors tests still pass (they call `render_ranked_page`).

- [ ] **Step 2: Routes**

In `web-app/config/routes.rb`, inside `scope module: :books do`, after `resources :authors, only: [:index, :show], param: :slug`:

```ruby
          resources :ranking_configurations, only: [:index, :show], constraints: {id: /\d+/}
```

Run: `bin/rails routes -g 'api/v1/ranking_configurations'`
Expected:
```
api_v1_ranking_configurations GET /api/v1/ranking_configurations(.:format)     api/v1/books/ranking_configurations#index {format: :json}
 api_v1_ranking_configuration GET /api/v1/ranking_configurations/:id(.:format) api/v1/books/ranking_configurations#show {format: :json, id: /\d+/}
```

- [ ] **Step 3: Generate the controller**

Run:
```bash
bin/rails generate controller api/v1/books/ranking_configurations index show --skip-routes --no-helper -e none --parent=Api::V1::Books::BaseController
```
Expected: `app/controllers/api/v1/books/ranking_configurations_controller.rb` and `test/controllers/api/v1/books/ranking_configurations_controller_test.rb`. Run `ls app/views/api 2>/dev/null` and delete that directory if the generator created it (`rm -r app/views/api`).

- [ ] **Step 4: Write the failing controller tests**

Replace `web-app/test/controllers/api/v1/books/ranking_configurations_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @inherited = ranking_configurations(:books_inherited)
          @year_2025 = ranking_configurations(:books_year_2025)
          # Two ranked books and one unranked RankedItem row on the primary: item_count
          # must count the ranked ones only.
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @primary, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @primary, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:got), ranking_configuration: @primary, rank: nil, score: 0)
          # The fixture ranked list points at an approved (not active) list; activate
          # it so list_count sees one, and add a second RankedList whose list stays
          # approved so the status predicate is exercised.
          lists(:books_list).update!(status: :active)
          RankedList.create!(list: lists(:approved_list), ranking_configuration: @primary, weight: 5)
        end

        def json = response.parsed_body.deep_symbolize_keys

        # --- index ---------------------------------------------------------------

        test "index lists the global book configurations, primary first" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal @primary.id, json[:data].first[:id]
          rest = [@inherited, @year_2025].map(&:id).sort.reverse
          assert_equal rest, json[:data].drop(1).map { |row| row[:id] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index rows are the documented shape with batched counts" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          primary = json[:data].first
          assert_equal %i[id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url], primary.keys
          assert_equal "books", primary[:kind]
          assert_equal true, primary[:primary]
          assert_equal 2, primary[:item_count], "item_count must exclude the RankedItem with a nil rank"
          assert_equal 1, primary[:list_count], "list_count must exclude the ranked list whose list is not active"
          assert_equal "2025-07-09T23:38:50Z", primary[:published_at]
          assert_equal "https://dev-new.thegreatestbooks.org/rc/#{@primary.id}", primary[:url]

          year = json[:data].find { |row| row[:id] == @year_2025.id }
          assert_equal 2025, year[:year]
          assert_equal 0, year[:item_count]
          assert_equal 0, year[:list_count]
        end

        test "index excludes user-owned, archived and author configurations" do
          @inherited.update!(archived: true)

          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          ids = json[:data].map { |row| row[:id] }
          refute_includes ids, @inherited.id, "archived"
          refute_includes ids, ranking_configurations(:books_user).id, "private user-owned"
          refute_includes ids, ranking_configurations(:books_user_shared).id, "shared user-owned"
          refute_includes ids, ranking_configurations(:books_authors_global).id, "authors configuration"
          assert_equal 2, json[:meta][:total_count]
        end

        test "index paginates" do
          get "/api/v1/ranking_configurations?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 1, json[:data].size
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200 and runs no count lookups" do
          get "/api/v1/ranking_configurations?page=9", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up
          queries = capture_sql { get "/api/v1/ranking_configurations?page=9", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
          refute queries.any? { |sql| sql.include?("ranked_items") || sql.include?("ranked_lists") },
            "an empty page must not run the count lookups:\n#{queries.join("\n")}"
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/ranking_configurations?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "invalid_parameter", json[:code]
        end

        test "index query count does not grow with page size" do
          get "/api/v1/ranking_configurations?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/ranking_configurations?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/ranking_configurations?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders one configuration with its counts" do
          get "/api/v1/ranking_configurations/#{@primary.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal @primary.id, json[:data][:id]
          assert_equal 2, json[:data][:item_count]
          assert_equal 1, json[:data][:list_count]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/books", json[:data][:books_api_url]
        end

        test "show of a non-primary configuration" do
          get "/api/v1/ranking_configurations/#{@year_2025.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal false, json[:data][:primary]
          assert_equal 2025, json[:data][:year]
        end

        test "show of an unknown id is a 404 problem" do
          get "/api/v1/ranking_configurations/999999999", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "show never serves a user-owned, archived or author configuration" do
          @inherited.update!(archived: true)

          [@inherited, ranking_configurations(:books_user), ranking_configurations(:books_user_shared),
            ranking_configurations(:books_authors_global)].each do |configuration|
            get "/api/v1/ranking_configurations/#{configuration.id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_response :not_found, configuration.name
            assert_equal "not_found", json[:code]
          end
        end

        test "a non-numeric id is a routing 404" do
          get "/api/v1/ranking_configurations/primary", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- framework confirmations ---------------------------------------------

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/ranking_configurations"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "unauthenticated", json[:code]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        test "every authenticated response carries the six rate-limit headers and is not cacheable" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/ranking_configurations_controller_test.rb`
Expected: the 200 tests fail (the generated actions render nothing useful and `assert_api_conform` reports the path matches no documented operation); the routing/host tests may already pass. No `NameError` from the file itself.

- [ ] **Step 6: Write the controller**

Replace `web-app/app/controllers/api/v1/books/ranking_configurations_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/ranking_configurations      -- global book rankings, primary first
      # GET /api/v1/ranking_configurations/:id  -- one of them
      #
      # Only global, unarchived Books::RankingConfiguration rows are addressable
      # (spec D3): a member's own configuration, shared or not, an archived one,
      # or the authors configuration is a 404 -- STI keeps the last of those out
      # of the scope without a type predicate.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class RankingConfigurationsController < BaseController
        def index
          relation = ::Books::RankingConfiguration.global.active.order(primary: :desc, created_at: :desc, id: :desc)

          render_page(relation, path: "/api/v1/ranking_configurations") do |configurations|
            counts = counts_for(configurations.map(&:id))
            configurations.map do |configuration|
              RankingConfigurationResource.new(configuration, params: counts.fetch(configuration.id)).to_h
            end
          end
        end

        def show
          configuration = ::Books::RankingConfiguration.global.active.find(params[:id])
          counts = counts_for([configuration.id])

          render json: {data: RankingConfigurationResource.new(configuration, params: counts.fetch(configuration.id)).to_h}
        end

        private

        # {id => {item_count:, list_count:}} in two grouped queries whatever the
        # page size, and none at all for an empty page. list_count uses the
        # predicate ::Books::ListsQuery uses, so it equals the lists
        # sub-collection's total_count once that ships.
        def counts_for(ids)
          return {} if ids.empty?

          items = ::RankedItem.where(ranking_configuration_id: ids, item_type: "Books::Book").where.not(rank: nil)
            .group(:ranking_configuration_id).count
          lists = ::RankedList.where(ranking_configuration_id: ids).joins(:list)
            .where(lists: {type: "Books::List", status: ::List.statuses[:active]})
            .group(:ranking_configuration_id).count

          ids.index_with { |id| {item_count: items.fetch(id, 0), list_count: lists.fetch(id, 0)} }
        end
      end
    end
  end
end
```

- [ ] **Step 7: Contract entries**

In `web-app/config/api/v1/openapi.yaml`:

(a) After the `/api/v1/authors/{slug}:` path item (before `components:`), add:

```yaml
  /api/v1/ranking_configurations:
    x-domain: books
    get:
      operationId: listRankingConfigurations
      summary: Ranking configurations
      description: The global book rankings the site publishes, primary first. A book's `rank` and a list's `weight` are always relative to one of these.
      parameters:
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of ranking configurations.
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
                $ref: "#/components/schemas/RankingConfigurationCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/ranking_configurations/{id}:
    x-domain: books
    get:
      operationId: getRankingConfiguration
      summary: One ranking configuration
      parameters:
        - $ref: "#/components/parameters/id"
      responses:
        "200":
          description: The ranking configuration.
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
                $ref: "#/components/schemas/RankingConfigurationItem"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
```

(b) In `components.parameters`, after `slug:`, add:

```yaml
    id:
      name: id
      in: path
      required: true
      description: The resource's integer id.
      schema:
        type: integer
        minimum: 1
```

(c) At the end of `components.schemas` (after `AuthorItem`), add:

```yaml
    RankingConfiguration:
      type: object
      required: [id, name, kind, primary, year, description, published_at, last_refreshed_at, item_count, list_count, url, api_url, books_api_url]
      properties:
        id: {type: integer}
        name: {type: string}
        kind:
          type: string
          enum: [books]
          description: What this configuration ranks. Only `books` today; more kinds will be added, never removed.
        primary:
          type: boolean
          description: Whether this is the site's primary ranking — the one `/api/v1/books` and every `rank` outside this resource refer to.
        year: {type: [integer, "null"]}
        description: {type: [string, "null"]}
        published_at: {type: [string, "null"], format: date-time}
        last_refreshed_at:
          type: [string, "null"]
          format: date-time
          description: When the ranking was last calculated.
        item_count:
          type: integer
          minimum: 0
          description: Books ranked by this configuration.
        list_count:
          type: integer
          minimum: 0
          description: Active lists that feed this configuration.
        url: {type: string, format: uri, description: The ranking's page on the site.}
        api_url: {type: string, format: uri}
        books_api_url: {type: string, format: uri, description: The ranked books, best first.}
    RankingConfigurationCollection:
      type: object
      required: [data, meta, links]
      properties:
        data:
          type: array
          items:
            $ref: "#/components/schemas/RankingConfiguration"
        meta:
          $ref: "#/components/schemas/PaginationMeta"
        links:
          $ref: "#/components/schemas/PaginationLinks"
    RankingConfigurationItem:
      type: object
      required: [data]
      properties:
        data:
          $ref: "#/components/schemas/RankingConfiguration"
```

- [ ] **Step 8: Coverage entries and the served-paths pin**

In `web-app/test/integration/api/v1/contract_coverage_test.rb`, add to `EXERCISES` after the last `/api/v1/authors/{slug}` entry (keep the trailing-comma rhythm of the hash):

```ruby
        ["GET", "/api/v1/ranking_configurations", "200"] => -> { get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations", "400"] => -> { get "/api/v1/ranking_configurations?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations", "401"] => -> { get "/api/v1/ranking_configurations" },
        ["GET", "/api/v1/ranking_configurations", "403"] => -> { get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/ranking_configurations", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/ranking_configurations/{id}", "200"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}", "401"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}" },
        ["GET", "/api/v1/ranking_configurations/{id}", "403"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}", "404"] => -> { get "/api/v1/ranking_configurations/999999999", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}", headers: bearer(ApiTokenSecrets::MEMBER) } }
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, the "on the books host every books operation is present" assertion becomes:

```ruby
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}"], response.parsed_body["paths"].keys
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/ test/integration/api/v1/ test/lib/api/`
Expected: 0 failures, 0 errors. If `contract_coverage_test` reports "documented responses and EXERCISES disagree", diff the two lists it prints — a status is missing on one side.

- [ ] **Step 10: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/controllers/api config/routes.rb test/controllers/api test/integration/api && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; `All is good!`.

```bash
git add app/controllers/api/v1/base_controller.rb app/controllers/api/v1/books/ranking_configurations_controller.rb config/routes.rb config/api/v1/openapi.yaml test/controllers/api/v1/books/ranking_configurations_controller_test.rb test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "$(cat <<'EOF'
API: GET /api/v1/ranking_configurations and /{id}

Only global, unarchived book configurations are addressable; counts are
batched per page through the new render_page.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `/api/v1/ranking_configurations/{id}/books` — the nested books index

**Files:**
- Modify: `web-app/app/controllers/api/v1/books/base_controller.rb`
- Modify: `web-app/app/controllers/api/v1/books/books_controller.rb` (`index`)
- Modify: `web-app/config/routes.rb` (same block as Task 2)
- Modify: `web-app/test/controllers/api/v1/books/books_controller_test.rb` (new tests appended before `# --- show`)
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `render_ranked_page` (unchanged signature), `::Books::RankedBooksQuery.call(ranking_configuration:)`, `::Books::RankingConfiguration.global.active`, `BookResource`.
- Produces: `Api::V1::Books::BaseController#ranking_configuration` → `::Books::RankingConfiguration` or `nil` (raises `ActiveRecord::RecordNotFound` for an unaddressable id); `#collection_path(suffix)` → `"/api/v1/<suffix>"` or `"/api/v1/ranking_configurations/<id>/<suffix>"`. Increment 5's `ListsController#index` uses both exactly as `BooksController#index` does here. `GET /api/v1/ranking_configurations/:ranking_configuration_id/books` on the books host; `openapi.yaml` path item `/api/v1/ranking_configurations/{id}/books`.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/controllers/api/v1/books/books_controller_test.rb`, add before the `# --- show` comment block:

```ruby
        # --- nested under a ranking configuration --------------------------------

        test "the nested index on the primary returns the same rows with nested links" do
          get "/api/v1/ranking_configurations/#{@rc.id}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal %w[war-and-peace crime-and-punishment of-mice-and-men], json[:data].map { |b| b[:slug] }
          assert_equal [1, 2, 3], json[:data].map { |b| b[:rank] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@rc.id}/books?page=1&per_page=50", json[:links][:self]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@rc.id}/books?page=1&per_page=50", json[:links][:first]
        end

        test "the nested index reads the named configuration, and rank is relative to it" do
          year = ranking_configurations(:books_year_2025)
          RankedItem.create!(item: @mice, ranking_configuration: year, rank: 1, score: 100)
          RankedItem.create!(item: @war_and_peace, ranking_configuration: year, rank: 2, score: 90)

          get "/api/v1/ranking_configurations/#{year.id}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[of-mice-and-men war-and-peace], json[:data].map { |b| b[:slug] }
          assert_equal [1, 2], json[:data].map { |b| b[:rank] }
          assert_equal 2, json[:meta][:total_count]
        end

        test "the nested index paginates with nested links" do
          get "/api/v1/ranking_configurations/#{@rc.id}/books?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal ["of-mice-and-men"], json[:data].map { |b| b[:slug] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@rc.id}/books?page=1&per_page=2", json[:links][:prev]
        end

        test "the nested index never serves a user-owned, archived or author configuration" do
          archived = ranking_configurations(:books_inherited)
          archived.update!(archived: true)

          [archived, ranking_configurations(:books_user), ranking_configurations(:books_user_shared),
            ranking_configurations(:books_authors_global)].each do |configuration|
            get "/api/v1/ranking_configurations/#{configuration.id}/books", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_response :not_found, configuration.name
            assert_equal "not_found", json[:code]
          end
        end

        test "a missing parent is a 404 even when the page is also bad" do
          get "/api/v1/ranking_configurations/999999999/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
        end

        test "a non-numeric configuration id is a routing 404" do
          get "/api/v1/ranking_configurations/primary/books", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "the bare index still reads the primary and links to itself" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books?page=1&per_page=50", json[:links][:self]
        end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/books_controller_test.rb`
Expected: the six nested tests fail (routing 404 — the route does not exist yet); "the bare index still reads the primary" passes already.

- [ ] **Step 3: The base helpers**

Replace `web-app/app/controllers/api/v1/books/base_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # Root-anchored superclass: inside Api::V1::Books a bare BaseController
      # is this class itself.
      class BaseController < ::Api::V1::BaseController
        require_scope "books:read"

        private

        # The configuration an index reads: the one named in the path when the
        # request came in under /ranking_configurations/:ranking_configuration_id,
        # else the site's primary (nil when there is none yet). Only global,
        # unarchived book configurations are addressable -- a member's own,
        # shared or not, an archived one, or the authors configuration is a 404
        # (spec D3). Runs before Api::Page parses the page params, so a missing
        # parent is a 404 even when the page is also bad.
        def ranking_configuration
          if params[:ranking_configuration_id]
            ::Books::RankingConfiguration.global.active.find(params[:ranking_configuration_id])
          else
            ::Books::RankingConfiguration.default_primary
          end
        end

        # The base path for a collection's `links`: the nested form when the
        # request came in nested, so a client paging a configuration's books
        # stays on that configuration.
        def collection_path(suffix)
          if params[:ranking_configuration_id]
            "/api/v1/ranking_configurations/#{params[:ranking_configuration_id]}/#{suffix}"
          else
            "/api/v1/#{suffix}"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Switch `BooksController#index` to the helpers**

In `web-app/app/controllers/api/v1/books/books_controller.rb`, replace the `index` method with:

```ruby
        def index
          configuration = ranking_configuration
          relation = configuration && ::Books::RankedBooksQuery.call(ranking_configuration: configuration)

          render_ranked_page(relation, path: collection_path("books")) do |ranked_item|
            BookResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end
```

and update the class comment's first line to read:

```ruby
      # GET /api/v1/books                                  -- the primary ranking, best first, paginated
      # GET /api/v1/ranking_configurations/:id/books       -- the same, on the named configuration
      # GET /api/v1/books/:slug                            -- one book, full shape
```

- [ ] **Step 5: The route**

In `web-app/config/routes.rb`, directly after the `resources :ranking_configurations` line from Task 2:

```ruby
          get "ranking_configurations/:ranking_configuration_id/books", to: "books#index",
            as: :ranking_configuration_books, constraints: {ranking_configuration_id: /\d+/}
```

Run: `bin/rails routes -g 'ranking_configurations/:ranking_configuration_id/books'`
Expected: one line ending `api/v1/books/books#index {format: :json, ranking_configuration_id: /\d+/}`.

- [ ] **Step 6: Contract entry, coverage, served-paths pin**

In `web-app/config/api/v1/openapi.yaml`, after the `/api/v1/ranking_configurations/{id}:` path item, add:

```yaml
  /api/v1/ranking_configurations/{id}/books:
    x-domain: books
    get:
      operationId: listRankingConfigurationBooks
      summary: Books in rank order on one configuration
      description: The same rows and shape as `/api/v1/books`, ranked by the named configuration; `rank` is relative to it. Only ranked books appear.
      parameters:
        - $ref: "#/components/parameters/id"
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of ranked books.
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
                $ref: "#/components/schemas/BookCollection"
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

In `web-app/test/integration/api/v1/contract_coverage_test.rb`, add to `EXERCISES` after the Task 2 entries:

```ruby
        ["GET", "/api/v1/ranking_configurations/{id}/books", "200"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "400"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "401"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books" },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "403"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "404"] => -> { get "/api/v1/ranking_configurations/999999999/books", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books", headers: bearer(ApiTokenSecrets::MEMBER) } }
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, the books-host list gains `"/api/v1/ranking_configurations/{id}/books"` at the end:

```ruby
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}", "/api/v1/ranking_configurations/{id}/books"], response.parsed_body["paths"].keys
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/ test/integration/api/v1/`
Expected: 0 failures, 0 errors, including the existing books index tests (the bare path still reads the primary, the N+1 test still holds, `default_primary` stubbed to nil still yields an empty 200).

- [ ] **Step 8: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/controllers/api config/routes.rb test/controllers/api test/integration/api && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; `All is good!`.

```bash
git add app/controllers/api/v1/books/base_controller.rb app/controllers/api/v1/books/books_controller.rb config/routes.rb config/api/v1/openapi.yaml test/controllers/api/v1/books/books_controller_test.rb test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "$(cat <<'EOF'
API: GET /api/v1/ranking_configurations/{id}/books

Same action as /api/v1/books, resolving the configuration from the path;
rank is relative to the configuration the row was read through.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Docs page pin, E2E call, feature doc, full verification

**Files:**
- Modify: `web-app/test/controllers/developers_controller_test.rb` (the "documents the endpoints this host serves" test, line ~56)
- Modify: `web-app/e2e/tests/books/member/developers-tokens.spec.ts` (after the `/api/v1/books` assertions, line ~75)
- Modify: `docs/features/public-api.md`

**Interfaces:**
- Consumes: the three operationIds from Tasks 2–3 (`listRankingConfigurations`, `getRankingConfiguration`, `listRankingConfigurationBooks`); the E2E member fixture's `secret`.
- Produces: nothing new; this task proves and records.

- [ ] **Step 1: Pin the anchors on `/developers`**

In `web-app/test/controllers/developers_controller_test.rb`, in the test "documents the endpoints this host serves and only those", after `assert_select "[id=?]", "endpoint-getAuthor"` add:

```ruby
    assert_select "[id=?]", "endpoint-listRankingConfigurations"
    assert_select "[id=?]", "endpoint-getRankingConfiguration"
    assert_select "[id=?]", "endpoint-listRankingConfigurationBooks"
```

and in the music-host half, after `assert_select "[id=?]", "endpoint-listAuthors", count: 0` add:

```ruby
    assert_select "[id=?]", "endpoint-listRankingConfigurations", count: 0
```

Run: `bin/rails test test/controllers/developers_controller_test.rb`
Expected: passes — the page renders from the document, so the anchors already exist.

- [ ] **Step 2: The E2E call**

In `web-app/e2e/tests/books/member/developers-tokens.spec.ts`, after the block ending `expect(body.data[0]).toHaveProperty('rank');`, add:

```ts
    // The ranking configurations resource answers on the same token, and its
    // first row is the primary the books call above was ranked by.
    const configurations = await page.request.get('/api/v1/ranking_configurations', {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(configurations.status()).toBe(200);
    const configurationsBody = await configurations.json();
    expect(configurationsBody.data[0]).toMatchObject({ kind: 'books', primary: true });
```

Run, only if port 3000 is this worktree's server (see Global Constraints): `yarn build:all && bin/rails server` in one terminal, then `yarn test:e2e --project books-member e2e/tests/books/member/developers-tokens.spec.ts`.
Expected: passes. If the port belongs to another checkout, skip the run, say so in the task report, and leave the assertion in — the spec is still exercised the next time the member suite runs locally.

- [ ] **Step 3: Feature doc**

In `docs/features/public-api.md`:

(a) In the "Shape" bullet, after the sentence ending "Music and games resources are later increments.", add:

```
`/api/v1/ranking_configurations` lists the global book rankings (primary first; `kind` is `books` for all of them today), `/api/v1/ranking_configurations/{id}` shows one, and `/api/v1/ranking_configurations/{id}/books` is `/api/v1/books` on that configuration — the same action, resolved from the path, with `rank` relative to it. Only global, unarchived book configurations are addressable; a member's own, an archived one, or the authors configuration is a 404. Configurations are the first resource looked up by integer id (lists have no slug either); a non-numeric id is a routing 404, an unknown one the `not_found` problem. Spec: `docs/superpowers/specs/2026-09-20-public-api-lists-and-rankings-design.md`.
```

(b) Replace the "Not yet" line with:

```
`/api/v1/lists`, `/api/v1/lists/{id}`, `/api/v1/lists/{id}/items`, `/api/v1/books/{slug}/lists`, `/api/v1/ranking_configurations/{id}/lists` and `lists_api_url` on the configuration payload (increment 5); `/api/v1/authors/{slug}/books` (increment 6); search, filters, music/games resources, OAuth/MCP.
```

- [ ] **Step 4: Full verification**

Run, from `web-app/`:

```bash
bin/rails test 2>&1 | tail -20
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: `0 failures, 0 errors, 0 skips`; no offenses; `All is good!`. Scan the full test output for warning lines: none beyond the two known npm/yarn ones during `test:prepare`.

- [ ] **Step 5: Commit**

```bash
git add test/controllers/developers_controller_test.rb e2e/tests/books/member/developers-tokens.spec.ts ../docs/features/public-api.md
git commit -m "$(cat <<'EOF'
API docs and E2E: ranking configurations

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

Then open the PR against `main` (title `Public API: ranking configurations`, body summarising the three endpoints and the D3 scope rule, ending with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`).

---

## Self-review against the spec

- **D1** — `rank` relative to the configuration read through: Task 3 test "rank is relative to it"; `/api/v1/books` unchanged (Task 3 "bare index still reads the primary"). ✔
- **D2** — one index action, optionally nested: Task 3 routes `books#index` for both paths; the helpers live in `Books::BaseController` for increment 5's `ListsController`. ✔
- **D3** — scope and `kind`: Tasks 2–3 tests cover private, shared, archived and authors configurations on index, show and the nested index; `kind` in the resource (Task 1). ✔
- **D4** — integer ids: `constraints:` on both routes; routing-404 tests in Tasks 2–3; unknown-id 404 problems in the coverage map. ✔
- **Parent before page** — Task 3 test "a missing parent is a 404 even when the page is also bad". ✔
- **§2 counts batched per page, none on an empty page** — `counts_for` returns `{}` for `[]`; Task 2 tests "runs no count lookups" and "query count does not grow with page size". ✔
- **§4 payload** — key order pinned in Task 1 and Task 2 tests; `lists_api_url` deferred per §Increments item 1; no algorithm parameters (Task 1 test). ✔
- **§5 contract** — three path items, `id` parameter, three schemas, `x-domain: books`; served-paths pin updated in both tasks; `/developers` anchors pinned in Task 4. ✔
- **§6 errors** — no new codes; 404 only on the id-addressed paths. ✔
- **§Testing → E2E** — Task 4 Step 2. ✔
- **Not in this plan, by design** — lists, list items, book listings, author books (increments 5 and 6, their own plans).
