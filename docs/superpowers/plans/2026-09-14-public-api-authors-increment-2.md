# Public API — Increment 2 (Authors) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `GET /api/v1/authors` (the primary author ranking, best first, paginated) and `GET /api/v1/authors/{slug}` on the books host, documented in the OpenAPI contract and covered by the contract-coverage gate.

**Architecture:** Nothing new in the framework. A `Books::Author#primary_ranked_item` association (mirroring `Books::Book`'s) gives show its rank; an Alba `Api::V1::Books::AuthorResource` with a `:full` trait renders the two shapes from spec §6; `Api::V1::Books::AuthorsController < Api::V1::Books::BaseController` reuses `render_ranked_page` for the index and `find_by!(slug:)` for show. The contract gains two path items tagged `x-domain: books`, and `contract_coverage_test.rb`'s `EXERCISES` map gains the ten new (method, path, status) triples.

**Tech Stack:** Rails 8.1, Postgres, Minitest 6 + fixtures + Mocha, Alba 4 (symbol keys via `config/initializers/alba.rb`), openapi_first 3.4 (test only).

**Spec:** `docs/superpowers/specs/2026-09-12-public-api-framework-design.md` — §6 defines the author payloads; D12 (slug-only lookup) and D13 (show does not embed books) bind this increment. Increment 1's plan (`docs/superpowers/plans/2026-09-13-public-api-framework-increment-1.md`) is the shape this one copies; do not re-execute it.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **Use Rails generators** for the controller (`bin/rails generate controller …`); never hand-create it. Delete any `app/views/api/` directory the generator leaves behind.
- **Root-anchor every model reference inside `module Api::V1::Books`**: `::Books::Author`, `::Books::RankedAuthorsQuery`, `::Books::Authors::RankingConfiguration`, `::Api::Host`. A bare `Books::` inside `Api::V1::Books` resolves to `Api::V1::Books::…` and raises `NameError` at request time, not load time — the controller tests are what catch it.
- **Lookup by slug only** (D12): `::Books::Author.find_by!(slug: params[:slug])`, never `friendly.find` — `Books::Author` uses friendly_id with `:finders`, which resolves slugs before primary keys.
- **Author show does not embed books** (D13). No `books` key, no `books_count`. `GET /api/v1/authors/{slug}/books` is a later spec.
- `rank` on index comes from the `RankedItem` row (`params: {rank:}`); on show from `primary_ranked_item&.rank`; `null` for an unranked author. `Books::Authors::RankingConfiguration.default_primary` nil → index is a 200 with `data: []`, `total_count: 0`.
- **Every API integration test ends in `assert_api_conform(status:)`** (request + response) or, for deliberately invalid requests, `assert_api_response_conform(status:)`. New endpoints need `openapi.yaml` entries with `x-domain: books` on the path item, and `EXERCISES` in `test/integration/api/v1/contract_coverage_test.rb` must gain every new (method, path, status) or the gate fails.
- Alba returns **symbol** keys (`config/initializers/alba.rb`). Key order in a resource IS the order in `openapi.yaml`.
- Rails 8.1 ships `assert_no_queries`; `capture_sql` comes from `test/support/sql_capture.rb`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- Minitest 6: `assert_nil x`, never `assert_equal nil, x`.
- A clean `bin/rails test` adds **no warning lines** beyond the two known npm/yarn ones during `test:prepare`.
- Tests mirror `app/` and are namespaced to match (`module Api; module V1; module Books; class AuthorsControllerTest`).
- Controller tests assert behaviour (status, headers, JSON keys and values), never HTML or copy.
- The dev database is shared with other worktrees and not disposable: no `db:reset`, no `delete_all` outside `RAILS_ENV=test`. This increment has **no migration**.
- `CI=1 bin/rails zeitwerk:check` must pass after every task that adds a file under `app/lib`.
- Commit after every task with the attribution trailer from the session reminder. Never commit to `main`; the branch is `worktree-public-api-authors` (worktree `.claude/worktrees/public-api-authors`, based on `origin/main` at #310).
- No E2E in this increment: the Playwright spec that exercises the API through a real token is increment 3's (spec §Testing → E2E), where it already calls `GET /api/v1/books`; authors join it there.

---

## File structure

| File | Responsibility |
|---|---|
| `app/models/books/author.rb` | **modify**: `has_one :primary_ranked_item` scoped to the default primary author ranking |
| `test/models/books/author_test.rb` | **modify**: three `primary_ranked_item` tests |
| `app/lib/api/v1/books/author_resource.rb` | Alba: compact author + `:full` trait |
| `test/lib/api/v1/books/author_resource_test.rb` | shape, rank fallback, image URL, description source |
| `app/controllers/api/v1/books/authors_controller.rb` | index (rank order) and show |
| `test/controllers/api/v1/books/authors_controller_test.rb` | endpoint behaviour + the framework confirmations that depend on this controller |
| `config/routes.rb` | **modify**: `resources :authors` in the books API scope |
| `config/api/v1/openapi.yaml` | **modify**: two path items, `Author`/`AuthorFull`/`AuthorCollection`/`AuthorItem` |
| `test/integration/api/v1/contract_coverage_test.rb` | **modify**: ten `EXERCISES` entries + a ranked author in setup |
| `test/controllers/api/v1/openapi_controller_test.rb` | **modify**: the two `paths.keys` lists |
| `docs/features/public-api.md` | **modify**: authors shipped; "Not yet" shrinks |

What this increment does **not** touch: `Api::V1::BaseController`, the three `Api::` concerns, `Services::Api::*`, `Api::Page`/`Problem`/`Host`, `BookResource`, `AuthorSummaryResource` (the compact `{id, slug, name}` embedded in books stays as is — the author index's compact shape is a different, larger object and gets its own resource per spec §5), `Books::RankedAuthorsQuery` (shared with the site; the extra include is merged onto the relation in the controller).

---

### Task 1: `Books::Author#primary_ranked_item`

**Files:**
- Modify: `web-app/app/models/books/author.rb` (after `has_many :ranked_items`, line ~46)
- Test: `web-app/test/models/books/author_test.rb`

**Interfaces:**
- Consumes: `Books::Authors::RankingConfiguration.default_primary` (exists: `RankingConfiguration.default_primary` = `global.primary.first`), `RankedItem` (polymorphic `item`, validates the item class against the configuration type).
- Produces: `Books::Author#primary_ranked_item` → the `RankedItem` for this author in `Books::Authors::RankingConfiguration.default_primary`, or `nil`. Preloadable (`includes(:primary_ranked_item)`), exactly like `Books::Book#primary_ranked_item`.

- [ ] **Step 1: Write the failing tests**

Append inside `module Books; class AuthorTest` in `web-app/test/models/books/author_test.rb`, before the final `end`s (fixture names: `books_authors(:tolstoy)`, `ranking_configurations(:books_authors_global)` is `primary: true`, `ranking_configurations(:books_authors_secondary)` is `primary: false`):

```ruby
    # primary_ranked_item: the API's show reads the author's rank through this
    # (mirrors Books::Book#primary_ranked_item).
    test "primary_ranked_item is the row in the default primary author ranking" do
      author = books_authors(:tolstoy)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 9, score: 10)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 2, score: 90)

      assert_equal 2, Books::Author.find(author.id).primary_ranked_item.rank
    end

    test "primary_ranked_item is nil for an author the primary ranking does not rank" do
      author = books_authors(:king)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 1, score: 100)

      assert_nil Books::Author.find(author.id).primary_ranked_item
    end

    test "primary_ranked_item is nil when there is no primary author ranking" do
      author = books_authors(:tolstoy)
      RankedItem.create!(item: author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 1, score: 100)
      Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

      assert_nil Books::Author.find(author.id).primary_ranked_item
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/models/books/author_test.rb`
Expected: 3 failures — `NoMethodError: undefined method 'primary_ranked_item'`.

- [ ] **Step 3: Add the association**

In `web-app/app/models/books/author.rb`, directly after `has_many :ranked_items, as: :item, dependent: :destroy`:

```ruby
  # Scoped to the primary AUTHOR ranking (Books::Authors::, not Books::). The
  # lambda runs once per query, not once per record, so a preload costs one
  # query for the batch and the value is always read live. Derived from
  # ranked_items, so Books::Author::Merger has nothing extra to migrate.
  has_one :primary_ranked_item,
    -> { where(ranking_configuration_id: Books::Authors::RankingConfiguration.default_primary&.id) },
    as: :item, class_name: "RankedItem"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/author_test.rb`
Expected: 18 runs, 0 failures. If the third test fails with the rank still present, the stub is not reaching the lambda — confirm the lambda references `Books::Authors::RankingConfiguration` (plural `Authors`), not `Books::RankingConfiguration`.

- [ ] **Step 5: Lint and commit**

Run: `bundle exec standardrb app/models/books/author.rb test/models/books/author_test.rb`

```bash
git add app/models/books/author.rb test/models/books/author_test.rb
git commit -m "feat(books): Books::Author#primary_ranked_item, scoped to the primary author ranking

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Api::V1::Books::AuthorResource`

**Files:**
- Create: `web-app/app/lib/api/v1/books/author_resource.rb`
- Test: `web-app/test/lib/api/v1/books/author_resource_test.rb`

**Interfaces:**
- Consumes: `Api::Host.base_url` (→ `"https://dev-new.thegreatestbooks.org"` when `Current.domain = :books` in test); `rails_public_blob_url` direct route; `Books::Author` — `id`, `slug`, `name`, `sort_name`, `birth_year`, `death_year`, `alternate_names` (string array), `kind` (enum: `person`/`organization`/`pseudonym`/`collective`), `primary_image` → `file`, `primary_description(kind: :summary)` (Describable), `primary_ranked_item` (Task 1).
- Produces: `Api::V1::Books::AuthorResource.new(author, params: {rank: Integer|nil}).to_h` (compact) and `.new(author, with_traits: :full).to_h` (full). Compact keys, in order: `id slug name sort_name birth_year death_year rank image_url url api_url`. Full appends `alternate_names kind description`. These orders are the contract in `openapi.yaml` (Task 3).

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/api/v1/books/author_resource_test.rb`:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class AuthorResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          @author = books_authors(:tolstoy)
        end

        test "compact shape" do
          hash = AuthorResource.new(@author, params: {rank: 4}).to_h

          assert_equal(
            %i[id slug name sort_name birth_year death_year rank image_url url api_url],
            hash.keys
          )
          assert_equal @author.id, hash[:id]
          assert_equal "leo-tolstoy", hash[:slug]
          assert_equal "Leo Tolstoy", hash[:name]
          assert_nil hash[:sort_name]
          assert_equal 1828, hash[:birth_year]
          assert_equal 1910, hash[:death_year]
          assert_equal 4, hash[:rank]
          assert_nil hash[:image_url]
          assert_equal "https://dev-new.thegreatestbooks.org/author/leo-tolstoy", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors/leo-tolstoy", hash[:api_url]
        end

        test "rank falls back to the primary author ranking when not supplied" do
          RankedItem.create!(item: @author, ranking_configuration: ranking_configurations(:books_authors_global), rank: 3, score: 90)

          assert_equal 3, AuthorResource.new(@author).to_h[:rank]
        end

        test "rank ignores a ranking that is not the primary one" do
          RankedItem.create!(item: @author, ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 3, score: 90)

          assert_nil AuthorResource.new(@author).to_h[:rank]
        end

        test "rank is null for an unranked author" do
          assert_nil AuthorResource.new(@author).to_h[:rank]
        end

        test "a rank of nil passed explicitly stays nil" do
          assert_nil AuthorResource.new(@author, params: {rank: nil}).to_h[:rank]
        end

        test "image_url is the CDN URL of the primary image" do
          file = stub(attached?: true, key: "authors/abc123.jpg")
          @author.stubs(:primary_image).returns(stub(file: file))

          assert_equal "https://images-dev.thegreatestbooks.org/authors/abc123.jpg", AuthorResource.new(@author).to_h[:image_url]
        end

        test "image_url is null when the primary image has no attachment" do
          @author.stubs(:primary_image).returns(stub(file: stub(attached?: false)))

          assert_nil AuthorResource.new(@author).to_h[:image_url]
        end

        test "full trait adds the detail fields in order" do
          hash = AuthorResource.new(@author, with_traits: :full).to_h

          assert_equal(
            %i[id slug name sort_name birth_year death_year rank image_url url api_url
              alternate_names kind description],
            hash.keys
          )
          assert_equal ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"], hash[:alternate_names]
          assert_equal "person", hash[:kind]
          # tolstoy carries one fixture description (descriptions.yml: tolstoy_google,
          # kind summary, locale en) -- Descriptions::Resolver returns it.
          assert_equal "Russian writer widely regarded as one of the greatest novelists.", hash[:description]
        end

        test "full trait never embeds books" do
          hash = AuthorResource.new(@author, with_traits: :full).to_h

          refute hash.key?(:books)
        end

        test "full trait renders the enum kind as a string" do
          assert_equal "pseudonym", AuthorResource.new(books_authors(:bachman), with_traits: :full).to_h[:kind]
        end

        test "full trait description is null for an author without one" do
          assert_nil AuthorResource.new(books_authors(:king), with_traits: :full).to_h[:description]
        end

        test "full trait description comes from the descriptions subsystem, not the legacy column" do
          author = books_authors(:king)
          author.update_column(:description, "Legacy column text")

          assert_nil AuthorResource.new(author.reload, with_traits: :full).to_h[:description]
        end

        test "full trait resolves a summary description assigned through Describable" do
          author = books_authors(:king)
          author.assign_description(source: :ai_generated, content: "Master of horror.", kind: :summary)
          author.save!

          assert_equal "Master of horror.", AuthorResource.new(author.reload, with_traits: :full).to_h[:description]
        end
      end
    end
  end
end
```

Before running, confirm the fixture facts the tests lean on: `grep -n -A6 '^tolstoy_google:' test/fixtures/descriptions.yml` (kind `summary`, locale `en`, the quoted content), `grep -n -A3 '^bachman:' test/fixtures/books/authors.yml` (`kind: 2` = pseudonym), and that `king` has no description fixture (`grep -n 'king (Books::Author)' test/fixtures/descriptions.yml` prints nothing). If any differ, fix the assertion to the fixture — do not weaken it to `assert hash.key?(:description)`.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/api/v1/books/author_resource_test.rb`
Expected: FAIL — `NameError: uninitialized constant Api::V1::Books::AuthorResource`.

- [ ] **Step 3: Write the resource**

`web-app/app/lib/api/v1/books/author_resource.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # The author as the API presents it. Compact by default (the index), with a
      # :full trait for show. Key order here IS the order in config/api/v1/openapi.yaml.
      #
      # Not AuthorSummaryResource: that is the {id, slug, name} embedded in a
      # book. This is the author as a resource of its own.
      #
      # Every model reference is root-anchored: inside Api::V1::Books a bare
      # `Books::Author` resolves to Api::V1::Books::Author and raises NameError.
      #
      # `params[:rank]` lets the index pass the rank it already has from the
      # RankedItem row instead of triggering a query per author; show omits it
      # and the resource reads the primary author ranking itself.
      #
      # Show does not embed books (spec D13): an unbounded array is the wrong
      # shape; /api/v1/authors/{slug}/books is the follow-up.
      class AuthorResource
        include Alba::Resource

        attributes :id, :slug, :name, :sort_name, :birth_year, :death_year

        attribute :rank do |author|
          params.key?(:rank) ? params[:rank] : author.primary_ranked_item&.rank
        end

        attribute :image_url do |author|
          file = author.primary_image&.file
          file&.attached? ? Rails.application.routes.url_helpers.rails_public_blob_url(file) : nil
        end

        attribute :url do |author|
          "#{::Api::Host.base_url}/author/#{author.slug}"
        end

        attribute :api_url do |author|
          "#{::Api::Host.base_url}/api/v1/authors/#{author.slug}"
        end

        trait :full do
          attributes :alternate_names, :kind

          # The descriptions subsystem, not the legacy books_authors.description
          # column (which the descriptions spec's step D7 drops).
          attribute :description do |author|
            author.primary_description(kind: :summary)&.content
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/api/v1/books/author_resource_test.rb`
Expected: 13 runs, 0 failures.

- [ ] **Step 5: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/lib/api/v1/books/author_resource.rb test/lib/api/v1/books/author_resource_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: no offences; `All is good!`

```bash
git add app/lib/api/v1/books/author_resource.rb test/lib/api/v1/books/author_resource_test.rb
git commit -m "feat(api): Alba resource for authors with a :full trait

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Routes, `AuthorsController`, contract entries, coverage

The contract-coverage gate is what makes these one task: the document, the endpoints and the `EXERCISES` map have to land together or `contract_coverage_test.rb` is red in between.

**Files:**
- Modify: `web-app/config/routes.rb` (the books `namespace :api` block, line ~597)
- Create (generator): `web-app/app/controllers/api/v1/books/authors_controller.rb`, `web-app/test/controllers/api/v1/books/authors_controller_test.rb`
- Modify: `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`

**Interfaces:**
- Consumes: `Api::V1::Books::BaseController` (`require_scope "books:read"`, inherited `render_ranked_page(relation, path:) { |ranked_item| hash }`), `Api::V1::Books::AuthorResource` (Task 2), `::Books::RankedAuthorsQuery.call(ranking_configuration:)` (returns a `RankedItem` relation ordered by rank with `includes(item: :descriptions)`), `::Books::Authors::RankingConfiguration.default_primary`, `::Books::Author#primary_ranked_item` (Task 1), test helpers `bearer(secret)`, `assert_api_conform`, `assert_api_response_conform`, `capture_sql`, `ApiTokenSecrets::{MEMBER, MUSIC_ONLY, NON_MEMBER}`.
- Produces: `GET /api/v1/authors`, `GET /api/v1/authors/:slug` on the books host; `openapi.yaml` path items `/api/v1/authors`, `/api/v1/authors/{slug}` and schemas `Author`, `AuthorFull`, `AuthorCollection`, `AuthorItem`.

- [ ] **Step 1: Routes**

In `web-app/config/routes.rb`, inside the books `namespace :api … scope module: :books do` block, after `resources :books, only: [:index, :show], param: :slug`:

```ruby
          resources :authors, only: [:index, :show], param: :slug
```

Run: `bin/rails routes -g 'api/v1/authors'`
Expected:
```
api_v1_authors GET /api/v1/authors(.:format)       api/v1/books/authors#index {format: :json}
 api_v1_author GET /api/v1/authors/:slug(.:format) api/v1/books/authors#show {format: :json}
```

- [ ] **Step 2: Generate the controller**

Run:
```bash
bin/rails generate controller api/v1/books/authors index show --skip-routes --no-helper -e none --parent=Api::V1::Books::BaseController
```
Expected: `app/controllers/api/v1/books/authors_controller.rb` and `test/controllers/api/v1/books/authors_controller_test.rb`. Run `ls app/views/api 2>/dev/null` and delete that directory if the generator created it (`rm -r app/views/api`).

- [ ] **Step 3: Write the failing controller tests**

Replace `web-app/test/controllers/api/v1/books/authors_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class AuthorsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_authors_global)
          @tolstoy = books_authors(:tolstoy)
          @king = books_authors(:king)
          @bachman = books_authors(:bachman)
          RankedItem.create!(item: @tolstoy, ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: @king, ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: @bachman, ranking_configuration: @rc, rank: 3, score: 80)
          # No author fixture has an image. Attach one to rank 1 AND rank 2 so the
          # nested image -> attachment -> blob preload runs for per_page=1 and
          # per_page=3 alike; with only rank 2 pictured, per_page=1 would skip the
          # nested preloads entirely and the N+1 test would fail for the wrong reason.
          attach_primary_image(@tolstoy)
          attach_primary_image(@king)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def attach_primary_image(author)
          image = Image.new(parent: author, primary: true)
          image.file.attach(io: StringIO.new("fake image data"), filename: "#{author.slug}.jpg", content_type: "image/jpeg")
          image.save!
        end

        # --- index ---------------------------------------------------------------

        test "index lists ranked authors best first with meta and links" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal %w[leo-tolstoy stephen-king richard-bachman], json[:data].map { |a| a[:slug] }
          assert_equal [1, 2, 3], json[:data].map { |a| a[:rank] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index rows are the compact shape with a CDN image URL where one exists" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          tolstoy, _king, bachman = json[:data]
          assert_equal %i[id slug name sort_name birth_year death_year rank image_url url api_url], tolstoy.keys
          assert_match %r{\Ahttps://images-dev\.thegreatestbooks\.org/}, tolstoy[:image_url]
          assert_nil bachman[:image_url]
          assert_equal "https://dev-new.thegreatestbooks.org/author/leo-tolstoy", tolstoy[:url]
        end

        test "index excludes unranked authors" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute_includes json[:data].map { |a| a[:slug] }, books_authors(:garnett).slug
        end

        test "index reads the primary author ranking, not another author ranking" do
          RankedItem.create!(item: books_authors(:garnett), ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 1, score: 100)

          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute_includes json[:data].map { |a| a[:slug] }, "constance-garnett"
          assert_equal 3, json[:meta][:total_count]
        end

        test "index paginates" do
          get "/api/v1/authors?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal ["richard-bachman"], json[:data].map { |a| a[:slug] }
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200" do
          get "/api/v1/authors?page=9", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
        end

        test "invalid pagination parameters are a 400 problem" do
          {"page=0" => /page/, "per_page=101" => /per_page/}.each do |query, detail|
            get "/api/v1/authors?#{query}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 400)

            assert_response :bad_request, query
            assert_equal "application/problem+json; charset=utf-8", response.content_type
            assert_equal "invalid_parameter", json[:code]
            assert_match detail, json[:detail]
          end
        end

        test "index with no primary author ranking configuration is an empty 200" do
          ::Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal({page: 1, per_page: 50, total_count: 0, total_pages: 1}, json[:meta])
        end

        test "index with no primary author ranking still validates the page" do
          ::Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/authors?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal "invalid_parameter", json[:code]
        end

        test "index does not N+1 on images" do
          get "/api/v1/authors?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/authors?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/authors?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders the full author" do
          get "/api/v1/authors/#{@tolstoy.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal(
            %i[id slug name sort_name birth_year death_year rank image_url url api_url alternate_names kind description],
            json[:data].keys
          )
          assert_equal "leo-tolstoy", json[:data][:slug]
          assert_equal 1, json[:data][:rank]
          assert_equal ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"], json[:data][:alternate_names]
          assert_equal "person", json[:data][:kind]
          assert_equal "Russian writer widely regarded as one of the greatest novelists.", json[:data][:description]
          assert_match %r{\Ahttps://images-dev\.thegreatestbooks\.org/}, json[:data][:image_url]
          assert_equal "https://dev-new.thegreatestbooks.org/author/leo-tolstoy", json[:data][:url]
        end

        test "show does not embed books" do
          get "/api/v1/authors/#{@tolstoy.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute json[:data].key?(:books)
        end

        test "show of an unranked author has a null rank" do
          get "/api/v1/authors/#{books_authors(:garnett).slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_nil json[:data][:rank]
          assert_nil json[:data][:description]
        end

        test "show of an unknown slug is a 404 problem" do
          get "/api/v1/authors/no-such-author", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_match(/author/, json[:detail])
        end

        test "show does not fall back to a primary-key lookup" do
          get "/api/v1/authors/#{@tolstoy.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "show does not answer to an alternate name" do
          get "/api/v1/authors/lev-tolstoy", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "a non-JSON format is a routing 404" do
          get "/api/v1/authors.xml", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- framework confirmations that depend on THIS controller ---------------
        # The full auth / rate-limit matrix lives in BooksControllerTest; these
        # prove the authors controller inherits the books base (scope), and
        # that its errors pass through the same rendering.

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/authors"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "unauthenticated", json[:code]
        end

        test "a non-member's token is a 403 membership_required" do
          get "/api/v1/authors/#{@tolstoy.slug}", headers: bearer(ApiTokenSecrets::NON_MEMBER)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal "membership_required", json[:code]
        end

        test "a token without books:read is a 403 insufficient_scope naming books:read" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        test "every authenticated response carries the six rate-limit headers" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }

          get "/api/v1/authors/no-such-author", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "responses are never cacheable by a shared cache" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/authors_controller_test.rb`
Expected: every test fails. The generated controller has empty `index`/`show` (204 No Content, or a missing-template error), and `assert_api_conform` reports `matched no documented operation` because the contract has no `/api/v1/authors` yet.

- [ ] **Step 5: Add the contract entries**

In `web-app/config/api/v1/openapi.yaml`:

**(a)** Under `paths:`, after the `/api/v1/books/{slug}:` path item and before `components:`, add:

```yaml
  /api/v1/authors:
    x-domain: books
    get:
      operationId: listAuthors
      summary: Authors in rank order
      description: The Greatest Books' primary author ranking, best first. Only ranked authors appear. Empty until an author ranking has been calculated.
      parameters:
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of ranked authors.
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
                $ref: "#/components/schemas/AuthorCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/authors/{slug}:
    x-domain: books
    get:
      operationId: getAuthor
      summary: One author
      description: The author alone. Their books are not embedded; a paginated sub-collection is a later addition.
      parameters:
        - $ref: "#/components/parameters/slug"
      responses:
        "200":
          description: The author.
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
                $ref: "#/components/schemas/AuthorItem"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
```

**(b)** Under `components.schemas`, after `BookItem:` (the last schema), add:

```yaml
    Author:
      type: object
      required: [id, slug, name, sort_name, birth_year, death_year, rank, image_url, url, api_url]
      properties:
        id: {type: integer}
        slug: {type: string}
        name: {type: string}
        sort_name: {type: [string, "null"]}
        birth_year: {type: [integer, "null"]}
        death_year: {type: [integer, "null"]}
        rank:
          type: [integer, "null"]
          description: Position in the site's primary author ranking; null when unranked.
        image_url: {type: [string, "null"], format: uri}
        url: {type: string, format: uri, description: The author's page on the site.}
        api_url: {type: string, format: uri}
    AuthorFull:
      allOf:
        - $ref: "#/components/schemas/Author"
        - type: object
          required: [alternate_names, kind, description]
          properties:
            alternate_names:
              type: array
              items: {type: string}
            kind:
              type: string
              enum: [person, organization, pseudonym, collective]
            description: {type: [string, "null"]}
    AuthorCollection:
      type: object
      required: [data, meta, links]
      properties:
        data:
          type: array
          items:
            $ref: "#/components/schemas/Author"
        meta:
          $ref: "#/components/schemas/PaginationMeta"
        links:
          $ref: "#/components/schemas/PaginationLinks"
    AuthorItem:
      type: object
      required: [data]
      properties:
        data:
          $ref: "#/components/schemas/AuthorFull"
```

Run: `bin/rails runner 'puts Api::OpenapiDocument.raw["paths"].keys'`
Expected: five paths, `/api/v1/authors` and `/api/v1/authors/{slug}` last. (A YAML indentation slip shows up here as a `Psych::SyntaxError` or a missing key.)

- [ ] **Step 6: Write the controller**

Replace the generated `web-app/app/controllers/api/v1/books/authors_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/authors        -- the primary author ranking, best first, paginated
      # GET /api/v1/authors/:slug  -- one author, full shape; books are NOT embedded (spec D13)
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class AuthorsController < BaseController
        def index
          ranking_configuration = ::Books::Authors::RankingConfiguration.default_primary
          # The shared query preloads descriptions for the site; the compact
          # resource needs the primary image too, merged here rather than in the
          # query so the site does not pay for a preload it never reads.
          relation = ranking_configuration && ::Books::RankedAuthorsQuery
            .call(ranking_configuration: ranking_configuration)
            .includes(item: {primary_image: {file_attachment: :blob}})

          render_ranked_page(relation, path: "/api/v1/authors") do |ranked_item|
            AuthorResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end

        def show
          # find_by!(slug:), never friendly.find: Books::Author uses friendly_id
          # with :finders, which resolves slugs before primary keys.
          author = ::Books::Author
            .includes(:descriptions, {primary_image: {file_attachment: :blob}})
            .find_by!(slug: params[:slug])

          render json: {data: AuthorResource.new(author, with_traits: :full).to_h}
        end
      end
    end
  end
end
```

- [ ] **Step 7: Run the controller tests**

Run: `bin/rails test test/controllers/api/v1/books/authors_controller_test.rb`
Expected: 23 runs, 0 failures. Likely first-run issues and their fixes:
- `assert_api_conform` failing on `image_url` with a format error: the CDN URL is built by `rails_public_blob_url` and is a valid absolute URI; if json_schemer objects, print `json[:data].first[:image_url]` and check `Current.domain` was set (it is, by `CurrentDomain` in the base controller).
- The N+1 test differing between page sizes: print the captured SQL. A per-row `images`/`active_storage_attachments`/`active_storage_blobs` query means the `includes(item: {primary_image: …})` did not merge onto the relation — confirm it is chained on the `RankedAuthorsQuery.call(...)` result, not on `RankedItem` afresh. A per-row `descriptions` query cannot happen (the shared query preloads them). Do not "fix" it by loosening the assertion.
- Show's `rank` raising `NameError` from inside the association scope: Task 1's lambda must reference `Books::Authors::RankingConfiguration` (resolvable from `Books::Author`'s lexical scope). Fix the model, not the controller.
- `NameError: uninitialized constant Api::V1::Books::Books` — a model reference in the controller lost its leading `::`.

- [ ] **Step 8: Coverage map and the OpenAPI controller test**

In `web-app/test/integration/api/v1/contract_coverage_test.rb`:

**(a)** Add to `EXERCISES`, after the last `/api/v1/books/{slug}` entry (keep the trailing entry without a comma):

```ruby
        ["GET", "/api/v1/authors", "200"] => -> { get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors", "400"] => -> { get "/api/v1/authors?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors", "401"] => -> { get "/api/v1/authors" },
        ["GET", "/api/v1/authors", "403"] => -> { get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/authors", "429"] => -> { with_exhausted_limit { get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/authors/{slug}", "200"] => -> { get "/api/v1/authors/#{books_authors(:tolstoy).slug}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors/{slug}", "401"] => -> { get "/api/v1/authors/leo-tolstoy" },
        ["GET", "/api/v1/authors/{slug}", "403"] => -> { get "/api/v1/authors/leo-tolstoy", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/authors/{slug}", "404"] => -> { get "/api/v1/authors/no-such-author", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors/{slug}", "429"] => -> { with_exhausted_limit { get "/api/v1/authors/leo-tolstoy", headers: bearer(ApiTokenSecrets::MEMBER) } }
```

**(b)** In `setup`, after the books `RankedItem.create!`, add a ranked author so the `/api/v1/authors` 200 validates a non-empty `data` array against `Author` rather than an empty one against nothing:

```ruby
        RankedItem.create!(item: books_authors(:tolstoy), ranking_configuration: ranking_configurations(:books_authors_global), rank: 1, score: 100)
```

In `web-app/test/controllers/api/v1/openapi_controller_test.rb`, both assertions on `paths.keys` change to the five-element list, in YAML order:

```ruby
          assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}"], response.parsed_body["paths"].keys
```

and

```ruby
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}"], ::Api::OpenapiDocument.raw["paths"].keys
```

The music/games assertion (`["/api/v1/openapi.json"]`) is unchanged: both new path items carry `x-domain: books`, so `OpenapiDocument.for_host` drops them off-host. Add one assertion to that test's loop, after the existing `assert_equal ["/api/v1/openapi.json"], body["paths"].keys, hostname`, so the filtering of the new items is asserted by name rather than by absence:

```ruby
          refute body["paths"].key?("/api/v1/authors"), hostname
```

- [ ] **Step 9: Run every API test**

Run: `bin/rails test test/controllers/api test/integration/api test/lib/api`
Expected: 0 failures (70 existing + the new ones). If `the map and the document describe the same responses` fails, its message names the side that is short — a typo in a path key (`{slug}` with braces, exactly as the YAML) is the usual cause.

- [ ] **Step 10: Lint, zeitwerk, site regression, commit**

Run:
```bash
bundle exec standardrb app/controllers/api config/routes.rb test/controllers/api test/integration/api && CI=1 bin/rails zeitwerk:check && bin/rails test test/controllers/books/authors_controller_test.rb test/controllers/books/authors
```
Expected: no offences; `All is good!`; the site's author pages still green (the shared `RankedAuthorsQuery` is untouched, this just proves it).

```bash
git add config/routes.rb app/controllers/api/v1/books/authors_controller.rb test/controllers/api/v1/books/authors_controller_test.rb config/api/v1/openapi.yaml test/integration/api/v1/contract_coverage_test.rb test/controllers/api/v1/openapi_controller_test.rb
git commit -m "feat(api): GET /api/v1/authors and /authors/:slug, documented and coverage-gated

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Feature doc and full verification

**Files:**
- Modify: `docs/features/public-api.md` (project root `docs/`, not `web-app/docs/`)

**Interfaces:**
- Consumes: everything above.
- Produces: a green suite on the branch and a feature doc that says authors shipped.

- [ ] **Step 1: Update the feature doc**

In `docs/features/public-api.md`:

**(a)** Replace the first bullet under `## Shape`:

```markdown
- Per-site path, JSON only: `https://thegreatestbooks.org/api/v1/books`, `/api/v1/books/{slug}`, `/api/v1/authors`, `/api/v1/authors/{slug}`. The domain comes from the host. Indexes are the site's primary ranking, best first; when there is no primary author ranking yet `/api/v1/authors` is a 200 with empty `data`. Lookup is by slug only, and author show does not embed books — a paginated `/api/v1/authors/{slug}/books` is the planned follow-up. Music and games resources are later increments.
```

**(b)** Replace the `## Not yet` paragraph:

```markdown
`/developers` and `/developers/tokens` (increment 3), `/api/v1/authors/{slug}/books`, search, filters, music/games, OAuth/MCP.
```

- [ ] **Step 2: Full suite**

Run: `bin/rails test 2>&1 | tee /tmp/claude-1001/-home-shane-dev-the-greatest/820e56f3-f562-45a0-9a41-064115d601fd/scratchpad/full-suite.log | tail -6`
Expected: 0 failures, 0 errors. Then count warning lines:

```bash
grep -c -i "warning" /tmp/claude-1001/-home-shane-dev-the-greatest/820e56f3-f562-45a0-9a41-064115d601fd/scratchpad/full-suite.log
```

Expected: only the two known npm/yarn lines from `test:prepare` (and `weighted_list_rank`'s position `puts` is not a warning). Any new `warning:` line names a file this increment touched — fix the cause.

- [ ] **Step 3: Lint everything and zeitwerk**

Run: `bundle exec standardrb && CI=1 bin/rails zeitwerk:check`
Expected: no offences; `All is good!`

- [ ] **Step 4: Commit**

```bash
git add ../docs/features/public-api.md
git commit -m "docs(api): authors shipped -- update the public API feature doc

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-review against the spec

- **§6 author payloads** — compact (`id`, `slug`, `name`, `sort_name`, `birth_year`, `death_year`, `rank`, `image_url`, `url`, `api_url`) and full (`+ alternate_names`, `kind`, `description`): Task 2 resource + tests, Task 3 contract schemas. ✔
- **`GET /api/v1/authors` on `RankedAuthorsQuery` / `Books::Authors::RankingConfiguration.default_primary`; nil → empty 200 with `total_count: 0`**: Task 3 controller + `index with no primary author ranking configuration is an empty 200`. ✔
- **`GET /api/v1/authors/{slug}` = `find_by!(slug:)`** (D12): Task 3 controller + `does not fall back to a primary-key lookup`. ✔
- **D13 no embedded books**: resource test `full trait never embeds books`, controller test `show does not embed books`, contract has no `books` property. ✔
- **`rank` from `primary_ranked_item` on show, `RankedItem` row on index, null when unranked**: Task 1 association, Task 2 fallback tests, Task 3 `show of an unranked author has a null rank`. ✔
- **`image_url` CDN via `rails_public_blob_url`, null if none**: Task 2 + Task 3 index-shape test with a real attachment. ✔
- **`url` = `https://<host>/author/<slug>`**: Task 2. ✔
- **Query count pinned on the index**: Task 3 N+1 test with images attached to ranks 1 and 2. ✔
- **§7 contract**: `x-domain: books` on both path items; `Author`/`AuthorFull`/`AuthorCollection`/`AuthorItem`; every test ends in `assert_api_conform`; coverage map complete; music/games documents unchanged. ✔
- **Testing section — 401/403/404/400/429 on the new paths**: 401/403/404/400 in the controller test; 429 through `EXERCISES` (`with_exhausted_limit`), which also asserts conformance. ✔
- **Root-anchoring**: every `::Books::…` and `::Api::Host` in Tasks 2–3 carries the leading `::`; the controller tests exercise every reference. ✔
- **Placeholder scan**: no TBD/TODO; every code step has its code. ✔
- **Type consistency**: `AuthorResource.new(author, params: {rank:})` / `with_traits: :full` used identically in Tasks 2 and 3; `primary_ranked_item` name identical in Tasks 1–3; contract key lists match the resource's `attributes` order. ✔
