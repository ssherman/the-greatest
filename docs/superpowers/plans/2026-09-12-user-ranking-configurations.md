# User-Owned Ranking Configurations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Signed-in users create, tune, share and refresh their own ranking configurations on the books site, viewable at the existing public `/rc/<id>` pages, with a domain-generic core that music and games switch on later by adding registry entries.

**Architecture:** Global `/my/rankings` routes resolved from `Current.domain` (the saved-searches shape) over a one-entry registry; three transactional services (`Create`, `Save`, `AddLists`) plus two read-only query objects; one low-priority Sidekiq job that chains weights → rankings under an atomic per-configuration lock on the `ranking_configurations` row; and a single gating concern + one `Cacheable` guard that make every `/rc/` page 404 private configurations and never edge-cache user-owned ones.

**Tech Stack:** Rails 8, Postgres, Sidekiq 9 (`low` queue), Pundit, Turbo Frames/Streams, Stimulus, DaisyUI 5 / Tailwind 4, Pagy 43, Minitest + fixtures + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-12-user-ranking-configurations-design.md` — read it first; every task below cites the section it implements.

## Global Constraints

- Run every Rails/yarn command from `web-app/`. Docs live at the repo root `docs/`.
- Use generators: `bin/rails generate controller`, `bin/rails generate sidekiq:job <path>` (never `generate job`). Never hand-create controllers or jobs.
- Lint is `bundle exec standardrb` (`--fix` autocorrects). Never `bin/rubocop`, never brakeman.
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`. Sidekiq test mode is already `Sidekiq.testing!(:inline)` in `test_helper.rb`; wrap enqueues you don't want executed in `Sidekiq::Testing.fake! { }` or stub `perform_async`.
- Controller tests assert behaviour (status, redirects, assigns, flash keys, JSON) — never HTML, CSS or copy.
- Root-anchor model constants inside `module Services` (`::RankingConfiguration`, `::RankedList`, `::Penalty`, `::PenaltyApplication`, `::List`): `Services::RankingConfiguration` already exists as a **module**, so a bare `RankingConfiguration` inside `module Services` resolves to it, not the model.
- DaisyUI 5 markup only: `fieldset`/`fieldset-legend`, bare `input`/`select`/`checkbox`/`textarea`, `input-error`. Never `form-control`, `label-text`, `input-bordered` (the lint `test/lint/daisyui_v4_classes_test.rb` fails the suite).
- Public layouts render no flash; this feature renders `my/ranking_configurations/_notice` inside its own views.
- New Stimulus controllers are registered in `app/javascript/manifests/books_web.js`; `test/lint/stimulus_manifest_test.rb` fails on any `data-controller` that is referenced but unregistered, or registered but unreferenced.
- Commit after every task with the attribution footer:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM
  ```
- Books test host: `Rails.application.config.domains[:books]` (`dev-new.thegreatestbooks.org`). Sign in with `sign_in_as(user, stub_auth: true)`.
- Fixtures used throughout: users `regular_user` (owner), `editor_user` (non-owner), `admin_user`; ranking configurations `books_global` (primary), `books_user` (private, owned by `regular_user`), `books_user_shared` (added in Task 1, shared, owned by `regular_user`); lists `books_list` (`Books::List`, status `approved`); books `war_and_peace` (slug `war-and-peace`); authors slug `leo-tolstoy`; penalties `global_penalty`, `books_penalty`, `static_penalty` (all applied to `books_global`), `user_penalty` (user-specific, must be excluded from the catalogue).
- `List.statuses` is `{unapproved: 0, approved: 1, rejected: 2, active: 3}`. The calculator only reads `active` lists; **no `Books::List` fixture is active** — tests create one with `Books::List.create!(name:, source:, status: :active)`.

---

## File structure

**Created**

| Path | Responsibility |
|---|---|
| `db/migrate/<ts>_add_user_ownership_to_ranking_configurations.rb` | six columns (§4) |
| `app/lib/ranking_configurations/registry.rb` | domain → entries (§5) |
| `app/lib/ranking_configurations/missing_lists_query.rb` | official-minus-mine diff (§6) |
| `app/lib/ranking_configurations/penalty_rows.rb` | catalogue → grouped form rows |
| `app/lib/services/ranking_configurations/create.rb` | create + penalties + seed + first refresh (§6) |
| `app/lib/services/ranking_configurations/save.rb` | edit + penalty sync + stale flag (§6) |
| `app/lib/services/ranking_configurations/add_lists.rb` | bulk add (§6) |
| `app/sidekiq/ranking_configurations/refresh_job.rb` | weights → rankings on `low` (§7) |
| `app/policies/ranking_configuration_policy.rb` | owner policy (§7) |
| `app/controllers/concerns/ranking_configuration_gating.rb` | `/rc/` visibility (§9) |
| `app/controllers/concerns/ranking_configuration_owner_scoped.rb` | owner lookup + entry (§8) |
| `app/controllers/my/ranking_configurations_controller.rb` | CRUD, refresh, state (§8) |
| `app/controllers/my/ranking_configurations/lists_controller.rb` | lists page, search, add, remove (§8.5) |
| `app/views/my/ranking_configurations/*.html.erb` | index, new, edit, show, choose_kind, `_form`, `_notice` |
| `app/views/my/ranking_configurations/lists/index.html.erb`, `_frame.html.erb` | lists page + frame |
| `app/views/shared/_custom_ranking_banner.html.erb` | banner (§9) |
| `app/javascript/controllers/ranking_configuration_status_controller.js` | polling (§8.4) |
| `e2e/tests/books/account/ranking-configurations.spec.ts` | E2E (§12) |
| `docs/features/user-ranking-configurations.md` | feature doc |

**Modified**

| Path | Change |
|---|---|
| `app/models/ranking_configuration.rb` | enum, validations, `user_owned?`, `request_refresh!` |
| `app/models/list.rb` | `name_with_source` |
| `app/controllers/application_controller.rb` | include gating; call it in `load_ranking_configuration` |
| `app/controllers/ranked_items_controller.rb`, `games/ranked_items_controller.rb`, `books/filters_controller.rb` | call gating |
| `app/controllers/concerns/cacheable.rb` | user-owned guard |
| `app/sidekiq/calculate_rankings_job.rb` | author-rankings gate |
| `config/sidekiq.yml` | `- low` |
| `config/routes.rb` | `/my/rankings` block |
| `app/views/layouts/books/application.html.erb` | banner line |
| `app/views/books/shared/_nav_links.html.erb` | My Rankings link |
| `app/javascript/manifests/books_web.js` | register status controller |
| `test/fixtures/ranking_configurations.yml` | `books_user_shared` |

---

### Task 1: Migration, model rules, fixtures

**Spec:** §4, §11.

**Files:**
- Create: `db/migrate/<timestamp>_add_user_ownership_to_ranking_configurations.rb`
- Modify: `app/models/ranking_configuration.rb`
- Modify: `test/fixtures/ranking_configurations.yml`
- Test: `test/models/ranking_configuration_test.rb`

**Interfaces:**
- Produces: `RankingConfiguration::MAX_PER_USER` (5), `RankingConfiguration::REFRESH_STALE_AFTER` (1.hour), `RankingConfiguration::RANKING_SETTINGS` (six attribute names), `enum :refresh_status` with prefix `refresh` (`refresh_idle?`, `refresh_queued?`, `refresh_running?`, `refresh_failed?`, `RankingConfiguration.refresh_statuses`), `#user_owned?`, `#refresh_in_progress?`, `#refresh_stale?`, `#refresh_claimable?`, columns `user_shared`, `refresh_status`, `needs_refresh`, `refresh_requested_at`, `last_refreshed_at`, `last_refresh_error`.

- [ ] **Step 1: Generate the migration**

```bash
cd web-app
bin/rails generate migration AddUserOwnershipToRankingConfigurations
```

Replace the generated file's body with:

```ruby
class AddUserOwnershipToRankingConfigurations < ActiveRecord::Migration[8.0]
  def change
    add_column :ranking_configurations, :user_shared, :boolean, null: false, default: false
    add_column :ranking_configurations, :refresh_status, :integer, null: false, default: 0
    add_column :ranking_configurations, :needs_refresh, :boolean, null: false, default: false
    add_column :ranking_configurations, :refresh_requested_at, :datetime
    add_column :ranking_configurations, :last_refreshed_at, :datetime
    add_column :ranking_configurations, :last_refresh_error, :text
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `schema.rb` gains the six columns on `ranking_configurations`. Check `git diff db/schema.rb` shows only those lines (the dev DB is shared across worktrees — if unrelated migrations appear, do not commit them; see AGENTS.md "Worktrees share the dev DB").

- [ ] **Step 2: Add the fixture**

Append to `test/fixtures/ranking_configurations.yml`:

```yaml
books_user_shared:
  type: Books::RankingConfiguration
  name: "Shared User Books Ranking"
  description: "A user-owned books ranking that its owner shared by link"
  global: false
  primary: false
  archived: false
  algorithm_version: 1
  exponent: 3.0
  bonus_pool_percentage: 3.0
  min_list_weight: 0
  apply_list_dates_penalty: true
  max_list_dates_penalty_age: 50
  max_list_dates_penalty_percentage: 80
  inherit_penalties: true
  user: regular_user
  user_shared: true
```

- [ ] **Step 3: Write the failing model tests**

Append inside the class in `test/models/ranking_configuration_test.rb` (the file already exists and tests the existing validations; match its style):

```ruby
  # --- user-owned configuration rules (spec §4, §11) ---

  test "user_owned? is the inverse of global?" do
    assert ranking_configurations(:books_user).user_owned?
    refute ranking_configurations(:books_global).user_owned?
  end

  test "refresh_status defaults to idle and exposes prefixed predicates" do
    config = ranking_configurations(:books_user)
    assert config.refresh_idle?
    refute config.refresh_in_progress?

    config.refresh_status = :queued
    assert config.refresh_in_progress?
    config.refresh_status = :running
    assert config.refresh_in_progress?
    config.refresh_status = :failed
    refute config.refresh_in_progress?
  end

  test "refresh_stale? is true only for an in-progress refresh older than the stale window" do
    config = ranking_configurations(:books_user)
    refute config.refresh_stale?

    config.assign_attributes(refresh_status: :running, refresh_requested_at: 30.minutes.ago)
    refute config.refresh_stale?
    refute config.refresh_claimable?

    config.refresh_requested_at = (RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago
    assert config.refresh_stale?
    assert config.refresh_claimable?
  end

  test "refresh_claimable? is true when idle or failed" do
    config = ranking_configurations(:books_user)
    assert config.refresh_claimable?
    config.refresh_status = :failed
    assert config.refresh_claimable?
  end

  test "max_list_dates_penalty_age is capped at 200 for every configuration" do
    config = ranking_configurations(:books_global)
    config.max_list_dates_penalty_age = 201
    refute config.valid?
    assert_includes config.errors[:max_list_dates_penalty_age], "must be less than or equal to 200"

    config.max_list_dates_penalty_age = 200
    assert config.valid?
  end

  test "min_list_weight must be 0..100 on a user-owned configuration only" do
    user_config = ranking_configurations(:books_user)
    user_config.min_list_weight = -1
    refute user_config.valid?
    user_config.min_list_weight = 101
    refute user_config.valid?
    user_config.min_list_weight = 100
    assert user_config.valid?

    global_config = ranking_configurations(:books_global)
    global_config.min_list_weight = -50
    assert global_config.valid?, "the books primary stores -50 and must stay valid"
  end

  test "description is capped at 1000 characters on a user-owned configuration only" do
    user_config = ranking_configurations(:books_user)
    user_config.description = "x" * 1001
    refute user_config.valid?

    global_config = ranking_configurations(:books_global)
    global_config.description = "x" * 1001
    assert global_config.valid?
  end

  test "a user-owned configuration cannot be primary" do
    config = ranking_configurations(:books_user)
    config.primary = true
    refute config.valid?
    assert_includes config.errors[:primary], "cannot be set on a user-owned configuration"
  end

  test "a user may own at most MAX_PER_USER configurations of one type" do
    user = users(:regular_user)
    existing = RankingConfiguration.where(type: "Books::RankingConfiguration", user_id: user.id).count
    (RankingConfiguration::MAX_PER_USER - existing).times do |i|
      Books::RankingConfiguration.create!(name: "Cap #{i}", global: false, user: user, min_list_weight: 0)
    end

    overflow = Books::RankingConfiguration.new(name: "One too many", global: false, user: user, min_list_weight: 0)
    refute overflow.valid?
    assert_includes overflow.errors[:base], "You can have at most #{RankingConfiguration::MAX_PER_USER} rankings"

    other_type = Games::RankingConfiguration.new(name: "Games is separate", global: false, user: user, min_list_weight: 0)
    assert other_type.valid?, "the cap is per configuration type"
  end

  test "the cap does not block updates to an existing configuration at the limit" do
    user = users(:regular_user)
    existing = RankingConfiguration.where(type: "Books::RankingConfiguration", user_id: user.id).count
    (RankingConfiguration::MAX_PER_USER - existing).times do |i|
      Books::RankingConfiguration.create!(name: "Cap #{i}", global: false, user: user, min_list_weight: 0)
    end

    config = ranking_configurations(:books_user)
    config.name = "Renamed at the cap"
    assert config.valid?
  end

  test "RANKING_SETTINGS names the six user-tunable attributes" do
    assert_equal %w[exponent bonus_pool_percentage min_list_weight apply_list_dates_penalty
      max_list_dates_penalty_age max_list_dates_penalty_percentage], RankingConfiguration::RANKING_SETTINGS
  end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/models/ranking_configuration_test.rb`
Expected: failures such as `NoMethodError: undefined method 'user_owned?'` and `undefined method 'refresh_idle?'`.

- [ ] **Step 5: Implement the model changes**

In `app/models/ranking_configuration.rb`:

Add after the `class RankingConfiguration < ApplicationRecord` line (before `# Associations`):

```ruby
  # How many configurations one user may own per type (books, albums, songs, ...).
  MAX_PER_USER = 5

  # An in-progress refresh older than this is treated as abandoned -- the worker
  # was killed before its rescue could run -- and may be claimed again.
  REFRESH_STALE_AFTER = 1.hour

  # The attributes a user can tune and that change the computed result. Editing
  # any of these marks a user-owned configuration as needing a refresh.
  RANKING_SETTINGS = %w[
    exponent bonus_pool_percentage min_list_weight apply_list_dates_penalty
    max_list_dates_penalty_age max_list_dates_penalty_percentage
  ].freeze

  enum :refresh_status, {idle: 0, queued: 1, running: 2, failed: 3}, prefix: :refresh
```

Replace the existing `validates :max_list_dates_penalty_age, ...` line with:

```ruby
  validates :max_list_dates_penalty_age, numericality: {only_integer: true, greater_than: 0, less_than_or_equal_to: 200}, allow_nil: true
```

Add after the `validates :year, ...` line:

```ruby
  # User-owned only. The books primary stores -50 and must stay valid; the
  # weight calculator floors at 0 anyway (see #weight_floor).
  validates :min_list_weight, numericality: {only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100}, if: :user_owned?
  validates :description, length: {maximum: 1000}, if: :user_owned?
```

Add to the `# Custom validations` block:

```ruby
  validate :user_owned_cannot_be_primary, if: :primary?
  validate :user_owned_within_limit, on: :create, if: :user_owned?
```

Add public methods after `def default_primary?`:

```ruby
  def user_owned?
    !global?
  end

  def refresh_in_progress?
    refresh_queued? || refresh_running?
  end

  def refresh_stale?
    refresh_in_progress? && refresh_requested_at.present? && refresh_requested_at < REFRESH_STALE_AFTER.ago
  end

  def refresh_claimable?
    !refresh_in_progress? || refresh_stale?
  end
```

Add private methods at the end of the `private` section:

```ruby
  def user_owned_cannot_be_primary
    errors.add(:primary, "cannot be set on a user-owned configuration") if user_owned?
  end

  def user_owned_within_limit
    return if user_id.blank?

    owned = RankingConfiguration.where(type: type, user_id: user_id).count
    errors.add(:base, "You can have at most #{MAX_PER_USER} rankings") if owned >= MAX_PER_USER
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/ranking_configuration_test.rb test/models/penalty_application_test.rb test/models/ranked_list_test.rb`
Expected: all pass. Then run the full suite once — the tightened `max_list_dates_penalty_age` bound and the new `primary` rule touch every configuration:

Run: `bin/rails test`
Expected: green.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/models/ranking_configuration.rb test/models/ranking_configuration_test.rb
git add db/migrate db/schema.rb app/models/ranking_configuration.rb test/fixtures/ranking_configurations.yml test/models/ranking_configuration_test.rb
git commit -m "feat(rankings): user-ownership columns and rules on ranking configurations

user_shared, refresh_status, needs_refresh and the refresh timestamps;
min_list_weight 0..100 and description <= 1000 on user-owned rows only;
max_list_dates_penalty_age <= 200 everywhere; a user-owned row can never
be primary; five per user per type.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 2: `/rc/:id` gating and the no-cache guard

**Spec:** §9 (visibility + caching), §3 (the six resolvers).

**Files:**
- Create: `app/controllers/concerns/ranking_configuration_gating.rb`
- Modify: `app/controllers/application_controller.rb` (include + one call in `load_ranking_configuration`)
- Modify: `app/controllers/ranked_items_controller.rb:8-16`
- Modify: `app/controllers/games/ranked_items_controller.rb:42-48`
- Modify: `app/controllers/books/filters_controller.rb:100-104`
- Modify: `app/controllers/concerns/cacheable.rb:19-28`
- Test: `test/controllers/books/ranked_items_controller_test.rb`, `test/controllers/books/lists_controller_test.rb`, `test/controllers/books/books_controller_test.rb`, `test/controllers/books/authors_controller_test.rb`, `test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Produces: `ApplicationController#gate_ranking_configuration!(config)` (private) which raises `ActiveRecord::RecordNotFound` for a private user-owned configuration the current user does not own, and sets `@custom_ranking_configuration` for any user-owned configuration that passes. Task 13 renders the banner from that ivar.

- [ ] **Step 1: Write the failing controller tests**

Append to `test/controllers/books/ranked_items_controller_test.rb` inside the class:

```ruby
    # --- user-owned configurations at /rc/:id (spec §9) ---

    test "a shared user-owned configuration renders for an anonymous visitor and is never cached" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
      refute_match "public", response.headers["Cache-Control"].to_s
      assert_equal config, @controller.view_assigns["custom_ranking_configuration"]
    end

    test "a private user-owned configuration 404s for anonymous visitors and non-owners" do
      config = ranking_configurations(:books_user)

      get "/rc/#{config.id}"
      assert_response :not_found

      sign_in_as users(:editor_user), stub_auth: true
      get "/rc/#{config.id}"
      assert_response :not_found
    end

    test "a private user-owned configuration renders for its owner without caching" do
      config = ranking_configurations(:books_user)
      sign_in_as users(:regular_user), stub_auth: true

      get "/rc/#{config.id}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
      assert_equal config, @controller.view_assigns["custom_ranking_configuration"]
    end

    test "a global configuration is still edge-cached and sets no custom banner" do
      get "/rc/#{@rc.id}"

      assert_response :success
      assert_match "public", response.headers["Cache-Control"].to_s
      assert_match "max-age=21600", response.headers["Cache-Control"].to_s
      assert_nil @controller.view_assigns["custom_ranking_configuration"]
    end
```

Append to `test/controllers/books/lists_controller_test.rb` inside the class (its `setup` already sets the books host and `@rc`):

```ruby
    test "the lists index for a shared user-owned configuration is never cached" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}/lists"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "the lists index for a private user-owned configuration 404s for a non-owner" do
      get "/rc/#{ranking_configurations(:books_user).id}/lists"
      assert_response :not_found
    end

    test "a list page under a shared user-owned configuration is never cached" do
      config = ranking_configurations(:books_user_shared)
      list = Books::List.create!(name: "Shared config list", source: "Test", status: :active)
      RankedList.create!(list: list, ranking_configuration: config, weight: 50)

      get "/rc/#{config.id}/lists/#{list.id}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end
```

Append to `test/controllers/books/books_controller_test.rb` inside the class (its `setup` defines `@book` and the host):

```ruby
    test "a book page under a shared user-owned configuration is never cached" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}/book/#{@book.slug}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "a book page under a private user-owned configuration 404s for a non-owner" do
      get "/rc/#{ranking_configurations(:books_user).id}/book/#{@book.slug}"
      assert_response :not_found
    end
```

Append to `test/controllers/books/authors_controller_test.rb` inside the class (its `setup` defines `@author` and the host):

```ruby
    test "an author page under a shared user-owned configuration is never cached" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}/author/#{@author.slug}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "an author page under a private user-owned configuration 404s for a non-owner" do
      get "/rc/#{ranking_configurations(:books_user).id}/author/#{@author.slug}"
      assert_response :not_found
    end
```

Append to `test/controllers/books/filters_controller_test.rb` inside the class:

```ruby
    test "the filter modal for a private user-owned configuration 404s for a non-owner" do
      get "/filters", params: {ranking_configuration_id: ranking_configurations(:books_user).id}
      assert_response :not_found
    end

    test "the filter modal for a shared user-owned configuration renders" do
      get "/filters", params: {ranking_configuration_id: ranking_configurations(:books_user_shared).id}
      assert_response :success
    end
```

(`/filters` is not inside an `/rc/` scope — `Books::FiltersController#find_ranking_configuration` reads `params[:ranking_configuration_id]` from the query string the modal's form sends.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb test/controllers/books/lists_controller_test.rb test/controllers/books/books_controller_test.rb test/controllers/books/authors_controller_test.rb test/controllers/books/filters_controller_test.rb`
Expected: the new tests fail — private configurations return 200, shared ones carry `public` cache headers, `custom_ranking_configuration` is nil.

- [ ] **Step 3: Create the gating concern**

Create `app/controllers/concerns/ranking_configuration_gating.rb`:

```ruby
# frozen_string_literal: true

# Who may see a ranking configuration resolved from /rc/:id, and which of
# those views is a "custom ranking" the layout should flag.
#
# Global configurations (the primary and the year rollups) are visible to
# everyone and never touch the session, so the edge-cached pages stay
# session-free. A user-owned configuration is visible when its owner shared
# it or when the viewer is the owner; anything else is a 404, never a 403 --
# a redirect would confirm the id exists.
#
# Included by ApplicationController; every finder that reads
# params[:ranking_configuration_id] calls gate_ranking_configuration! on the
# record it found (load_ranking_configuration, RankedItemsController,
# Games::RankedItemsController, Books::FiltersController).
module RankingConfigurationGating
  extend ActiveSupport::Concern

  private

  def gate_ranking_configuration!(config)
    return if config.nil? || config.global?

    unless config.user_shared? || config.user_id == current_user&.id
      raise ActiveRecord::RecordNotFound
    end

    @custom_ranking_configuration = config
  end
end
```

- [ ] **Step 4: Wire the four resolvers**

`app/controllers/application_controller.rb` — add `include RankingConfigurationGating` after `include Cacheable`, and in `load_ranking_configuration` replace the final `instance_variable_set(instance_var, ranking_config)` with:

```ruby
    gate_ranking_configuration!(ranking_config)
    instance_variable_set(instance_var, ranking_config)
```

`app/controllers/ranked_items_controller.rb` — in `find_ranking_configuration`, after `raise ActiveRecord::RecordNotFound unless @ranking_configuration`, add:

```ruby
    gate_ranking_configuration!(@ranking_configuration)
```

`app/controllers/games/ranked_items_controller.rb` — in its `find_ranking_configuration`, after the `if/else/end` assignment, add:

```ruby
    gate_ranking_configuration!(@ranking_configuration)
```

`app/controllers/books/filters_controller.rb` — in its `find_ranking_configuration`, after the assignment line, add:

```ruby
    gate_ranking_configuration!(@ranking_configuration)
```

- [ ] **Step 5: Guard the cache headers**

In `app/controllers/concerns/cacheable.rb`, replace `cache_for_index_page` and `cache_for_show_page` with:

```ruby
  # 6 hours with 1 hour stale-while-revalidate (for index/list pages)
  def cache_for_index_page
    return prevent_caching if user_owned_ranking_configuration?

    skip_session_for_caching
    expires_in 6.hours, public: true, stale_while_revalidate: 1.hour
  end

  # 24 hours with 1 hour stale-while-revalidate (for show/detail pages)
  def cache_for_show_page
    return prevent_caching if user_owned_ranking_configuration?

    skip_session_for_caching
    expires_in 24.hours, public: true, stale_while_revalidate: 1.hour
  end
```

and add, after `skip_session_for_caching`:

```ruby
  # A user-owned ranking configuration's pages are personal (and may be
  # private), so they are never edge-cached. Every controller that resolves
  # /rc/:id loads @ranking_configuration before it sets cache headers, which
  # is what makes this one guard cover all of them; the controller tests for
  # each /rc/ page pin that ordering.
  def user_owned_ranking_configuration?
    instance_variable_defined?(:@ranking_configuration) && @ranking_configuration&.user_owned?
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/books/ test/controllers/games/ test/controllers/music/ test/controllers/public_lists_controller_test.rb`
Expected: green — music and games controllers share the edited resolvers and `Cacheable`, and every configuration they load is global, so nothing changes for them.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers test/controllers
git add app/controllers/concerns/ranking_configuration_gating.rb app/controllers/concerns/cacheable.rb app/controllers/application_controller.rb app/controllers/ranked_items_controller.rb app/controllers/games/ranked_items_controller.rb app/controllers/books/filters_controller.rb test/controllers/books
git commit -m "feat(rankings): gate /rc/:id by ownership and never edge-cache user-owned configurations

Global configurations are untouched (still public, still session-free).
A user-owned one 404s unless shared or viewed by its owner, and every
page under it is no-store.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 3: Gate the author-rankings side effect

**Spec:** §7 (`CalculateRankingsJob` fix), §10.

**Files:**
- Modify: `app/sidekiq/calculate_rankings_job.rb:11-14`
- Test: `test/sidekiq/calculate_rankings_job_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside the class in `test/sidekiq/calculate_rankings_job_test.rb`:

```ruby
  test "does not enqueue the author ranking job for a non-primary books configuration" do
    config = ranking_configurations(:books_user)
    RankingConfiguration.any_instance
      .expects(:calculate_rankings)
      .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))
    Books::CalculateAuthorRankingsJob.expects(:perform_async).never
    Books::ReindexRankedFieldsJob.expects(:perform_async).never

    CalculateRankingsJob.new.perform(config.id)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/sidekiq/calculate_rankings_job_test.rb`
Expected: the new test fails with `unexpected invocation: Books::CalculateAuthorRankingsJob.perform_async`.

- [ ] **Step 3: Gate the enqueue**

In `app/sidekiq/calculate_rankings_job.rb` replace lines 11-14 with:

```ruby
      # Both side effects are about the site's official books ranking. A
      # year rollup or a user-owned configuration recalculating must not
      # recompute global author rankings or reindex search.
      if ranking_configuration.type == "Books::RankingConfiguration" && ranking_configuration.default_primary?
        Books::CalculateAuthorRankingsJob.perform_async
        Books::ReindexRankedFieldsJob.perform_async
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/sidekiq/calculate_rankings_job_test.rb`
Expected: all pass, including the existing "enqueues the author ranking job after a books configuration succeeds" (it uses `books_global`, the primary).

- [ ] **Step 5: Commit**

```bash
bundle exec standardrb --fix app/sidekiq/calculate_rankings_job.rb test/sidekiq/calculate_rankings_job_test.rb
git add app/sidekiq/calculate_rankings_job.rb test/sidekiq/calculate_rankings_job_test.rb
git commit -m "fix(rankings): only the primary books configuration triggers author rankings

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 4: `low` queue, the refresh job, and `request_refresh!`

**Spec:** §4 (`request_refresh!`), §7 (job, queue).

**Files:**
- Modify: `config/sidekiq.yml`
- Create: `app/sidekiq/ranking_configurations/refresh_job.rb` (via generator)
- Modify: `app/models/ranking_configuration.rb`
- Test: `test/sidekiq/ranking_configurations/refresh_job_test.rb`, `test/models/ranking_configuration_test.rb`

**Interfaces:**
- Consumes: `RankingConfiguration.refresh_statuses`, `REFRESH_STALE_AFTER` (Task 1); `Rankings::BulkWeightCalculator#call` → `{processed:, updated:, errors: [ {ranked_list_id:, list_name:, error:} ], weights_calculated:}`; `RankingConfiguration#calculate_rankings` → `ItemRankings::Calculator::Result(success?:, data:, errors:)`.
- Produces: `RankingConfigurations::RefreshJob.perform_async(id)`; `RankingConfiguration#request_refresh!` → `true` when this call claimed the lock and enqueued, `false` otherwise.

- [ ] **Step 1: Add the queue**

`config/sidekiq.yml` becomes:

```yaml
---
:concurrency: 5
:queues:
  - critical
  - default
  - low
```

(Strict priority: `low` drains only when the two above are empty. Production runs `bundle exec sidekiq` with no `-C`, and Sidekiq loads `config/sidekiq.yml` by default, so this reaches production as-is.)

- [ ] **Step 2: Generate the job**

```bash
bin/rails generate sidekiq:job ranking_configurations/refresh
```

Expected: `app/sidekiq/ranking_configurations/refresh_job.rb` and `test/sidekiq/ranking_configurations/refresh_job_test.rb`.

- [ ] **Step 3: Write the failing job tests**

Replace the generated test with:

```ruby
# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class RefreshJobTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_user)
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:queued],
        needs_refresh: true, refresh_requested_at: Time.current)
      @success = ItemRankings::Calculator::Result.new(success?: true, data: [], errors: [])
      @clean_weights = {processed: 1, updated: 1, errors: [], weights_calculated: []}
    end

    test "runs on the low queue and never retries" do
      assert_equal "low", RefreshJob.get_sidekiq_options["queue"].to_s
      assert_equal false, RefreshJob.get_sidekiq_options["retry"]
    end

    test "calculates weights then rankings and marks the configuration up to date" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)

      RefreshJob.new.perform(@config.id)

      @config.reload
      assert @config.refresh_idle?
      refute @config.needs_refresh?
      assert_not_nil @config.last_refreshed_at
      assert_nil @config.last_refresh_error
    end

    test "a ranking calculation failure marks the configuration failed and does not raise" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings)
        .returns(ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["boom"]))

      assert_nothing_raised { RefreshJob.new.perform(@config.id) }

      @config.reload
      assert @config.refresh_failed?
      assert @config.needs_refresh?, "a failed refresh leaves the configuration stale"
      assert_includes @config.last_refresh_error, "boom"
    end

    test "a weight calculation error marks the configuration failed before rankings run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(
        @clean_weights.merge(errors: [{ranked_list_id: 1, list_name: "L", error: "weight boom"}])
      )
      RankingConfiguration.any_instance.expects(:calculate_rankings).never

      RefreshJob.new.perform(@config.id)

      @config.reload
      assert @config.refresh_failed?
      assert_includes @config.last_refresh_error, "weight boom"
    end

    test "an unexpected exception marks the configuration failed and does not raise" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).raises(RuntimeError, "kaboom")

      assert_nothing_raised { RefreshJob.new.perform(@config.id) }

      assert @config.reload.refresh_failed?
      assert_includes @config.last_refresh_error, "kaboom"
    end

    test "a configuration deleted while queued is a silent no-op" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).never

      assert_nothing_raised { RefreshJob.new.perform(-1) }
    end

    test "does not enqueue the search reindex or author rankings" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)
      Books::ReindexRankedFieldsJob.expects(:perform_async).never
      Books::CalculateAuthorRankingsJob.expects(:perform_async).never

      RefreshJob.new.perform(@config.id)
    end
  end
end
```

- [ ] **Step 4: Run them to verify they fail**

Run: `bin/rails test test/sidekiq/ranking_configurations/refresh_job_test.rb`
Expected: failures (queue is `default`, statuses do not change).

- [ ] **Step 5: Implement the job**

Replace `app/sidekiq/ranking_configurations/refresh_job.rb` with:

```ruby
# frozen_string_literal: true

# Recalculates one user-owned ranking configuration: list weights first, then
# item rankings, as one unit of work. Status lives on the configuration row
# (RankingConfiguration#refresh_status), which is why this never retries --
# the Refresh button is the retry, and a Sidekiq retry would rerun invisibly
# while the row still said "failed".
#
# Calls the calculators directly rather than CalculateRankingsJob so none of
# the primary-only side effects (author rankings, search reindex) can follow.
module RankingConfigurations
  class RefreshJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(ranking_configuration_id)
      config = ::RankingConfiguration.find_by(id: ranking_configuration_id)
      return if config.nil? # deleted while queued -- not a failure

      config.update_columns(refresh_status: ::RankingConfiguration.refresh_statuses[:running])

      weights = Rankings::BulkWeightCalculator.new(config).call
      if weights[:errors].any?
        first = weights[:errors].first
        raise "Weight calculation failed for #{weights[:errors].size} list(s): #{first[:list_name]}: #{first[:error]}"
      end

      result = config.calculate_rankings
      raise "Ranking calculation failed: #{result.errors.join(", ")}" unless result.success?

      config.update_columns(
        refresh_status: ::RankingConfiguration.refresh_statuses[:idle],
        needs_refresh: false,
        last_refreshed_at: Time.current,
        last_refresh_error: nil
      )
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{ranking_configuration_id}: #{e.message}"
      ::RankingConfiguration.where(id: ranking_configuration_id).update_all(
        refresh_status: ::RankingConfiguration.refresh_statuses[:failed],
        last_refresh_error: e.message.truncate(500)
      )
    end
  end
end
```

- [ ] **Step 6: Run the job tests**

Run: `bin/rails test test/sidekiq/ranking_configurations/refresh_job_test.rb`
Expected: all pass.

- [ ] **Step 7: Write the failing `request_refresh!` tests**

Append inside the class in `test/models/ranking_configuration_test.rb`:

```ruby
  # --- request_refresh! (spec §4) ---

  test "request_refresh! claims an idle configuration, clears the last error and enqueues the job" do
    config = ranking_configurations(:books_user)
    config.update_columns(last_refresh_error: "old")
    RankingConfigurations::RefreshJob.expects(:perform_async).with(config.id).once

    assert config.request_refresh!

    config.reload
    assert config.refresh_queued?
    assert_nil config.last_refresh_error
    assert_in_delta Time.current, config.refresh_requested_at, 5.seconds
  end

  test "request_refresh! claims a failed configuration" do
    config = ranking_configurations(:books_user)
    config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:failed])
    RankingConfigurations::RefreshJob.expects(:perform_async).once

    assert config.request_refresh!
  end

  test "request_refresh! returns false and enqueues nothing while a fresh refresh is in progress" do
    config = ranking_configurations(:books_user)
    config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running],
      refresh_requested_at: 5.minutes.ago)
    RankingConfigurations::RefreshJob.expects(:perform_async).never

    refute config.request_refresh!
    assert config.reload.refresh_running?
  end

  test "request_refresh! reclaims a refresh abandoned longer than the stale window" do
    config = ranking_configurations(:books_user)
    config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running],
      refresh_requested_at: (RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago)
    RankingConfigurations::RefreshJob.expects(:perform_async).once

    assert config.request_refresh!
    assert config.reload.refresh_queued?
  end

  test "only one of two back-to-back request_refresh! calls wins" do
    config = ranking_configurations(:books_user)
    RankingConfigurations::RefreshJob.expects(:perform_async).once

    assert config.request_refresh!
    refute RankingConfiguration.find(config.id).request_refresh!
  end
```

- [ ] **Step 8: Run them to verify they fail**

Run: `bin/rails test test/models/ranking_configuration_test.rb -n /request_refresh/`
Expected: `NoMethodError: undefined method 'request_refresh!'`.

- [ ] **Step 9: Implement `request_refresh!`**

Add to `app/models/ranking_configuration.rb` after `def refresh_claimable?` … `end`:

```ruby
  # Claims the refresh lock and enqueues the job. One atomic UPDATE ... WHERE:
  # two simultaneous callers serialize on the row lock and the loser
  # re-evaluates the WHERE against the winner's committed value, so at most one
  # caller sees a changed row. The stale clause reclaims a row wedged by a
  # worker killed mid-run, which no rescue can catch. Returns true when this
  # call won.
  def request_refresh!
    statuses = self.class.refresh_statuses
    claimed = RankingConfiguration.where(id: id)
      .where("refresh_status IN (:free) OR refresh_requested_at < :stale",
        free: [statuses[:idle], statuses[:failed]], stale: REFRESH_STALE_AFTER.ago)
      .update_all(refresh_status: statuses[:queued], refresh_requested_at: Time.current, last_refresh_error: nil)
    return false unless claimed == 1

    reload
    RankingConfigurations::RefreshJob.perform_async(id)
    true
  end
```

- [ ] **Step 10: Run the model tests, then zeitwerk**

Run: `bin/rails test test/models/ranking_configuration_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: green; `All is good!`.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb --fix app/sidekiq/ranking_configurations app/models/ranking_configuration.rb test/sidekiq/ranking_configurations test/models/ranking_configuration_test.rb
git add config/sidekiq.yml app/sidekiq/ranking_configurations test/sidekiq/ranking_configurations app/models/ranking_configuration.rb test/models/ranking_configuration_test.rb
git commit -m "feat(rankings): low-priority refresh job with an atomic one-run lock

RankingConfigurations::RefreshJob chains weights then rankings on the new
low queue and records the outcome on the row; request_refresh! is a
single conditional UPDATE so two clicks can never start two runs.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 5: Registry, `PenaltyRows`, `MissingListsQuery`, `List#name_with_source`

**Spec:** §5 (registry), §6 (`MissingListsQuery`), §8.2/§8.3 (penalty rows).

**Files:**
- Create: `app/lib/ranking_configurations/registry.rb`
- Create: `app/lib/ranking_configurations/penalty_rows.rb`
- Create: `app/lib/ranking_configurations/missing_lists_query.rb`
- Modify: `app/models/list.rb`
- Test: `test/lib/ranking_configurations/registry_test.rb`, `test/lib/ranking_configurations/penalty_rows_test.rb`, `test/lib/ranking_configurations/missing_lists_query_test.rb`, `test/models/list_test.rb`

**Interfaces:**
- Produces: `RankingConfigurations::Registry::Entry` (Struct: `domain`, `kind`, `ranking_configuration_class`, `list_class`, `penalty_classes`, `results_path`, `lists_path`, `list_path`, `official_rankings_path`), `Registry.for_domain(domain) → [Entry]`, `Registry.find(domain, kind) → Entry | nil`, `Registry.for_config(config) → Entry | nil`, `Registry.penalties_for(entry) → ActiveRecord::Relation<Penalty>`.
- `RankingConfigurations::PenaltyRows.call(entry:, values:) → [Group(title:, rows: [Row(penalty:, enabled:, value:)])]` where `values` is `Hash{Integer penalty_id => Integer value}` for the enabled penalties.
- `RankingConfigurations::MissingListsQuery.call(config:, entry:) → ActiveRecord::Relation<RankedList>` (rows of the official configuration, `includes(:list)`).
- `List#name_with_source → String`.

- [ ] **Step 1: Write the failing registry test**

Create `test/lib/ranking_configurations/registry_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class RegistryTest < ActiveSupport::TestCase
    test "books has exactly one entry" do
      entries = Registry.for_domain(:books)

      assert_equal 1, entries.size
      entry = entries.first
      assert_equal "books", entry.kind
      assert_equal "Books::RankingConfiguration", entry.ranking_configuration_class
      assert_equal "Books::List", entry.list_class
      assert_equal ["Global::Penalty", "Books::Penalty"], entry.penalty_classes
    end

    test "for_domain accepts a string and returns nothing for a domain with no entry" do
      assert_equal 1, Registry.for_domain("books").size
      assert_empty Registry.for_domain(:games)
      assert_empty Registry.for_domain(:music)
    end

    test "find resolves an entry by domain and kind" do
      assert_equal "Books::RankingConfiguration", Registry.find(:books, "books").ranking_configuration_class
      assert_nil Registry.find(:books, "albums")
      assert_nil Registry.find(:games, "games")
    end

    test "for_config resolves an entry from the record's STI type" do
      assert_equal "books", Registry.for_config(ranking_configurations(:books_user)).kind
      assert_nil Registry.for_config(ranking_configurations(:games_global))
    end

    test "path lambdas produce the public /rc/ URLs" do
      config = ranking_configurations(:books_user_shared)
      entry = Registry.for_config(config)
      list = lists(:books_list)

      assert_equal "/rc/#{config.id}", entry.results_path.call(config)
      assert_equal "/rc/#{config.id}/lists", entry.lists_path.call(config)
      assert_equal "/lists/#{list.id}", entry.list_path.call(list)
      assert_equal "/", entry.official_rankings_path.call
    end

    test "penalties_for returns the catalogue for the entry, excluding user-specific penalties" do
      entry = Registry.find(:books, "books")
      penalties = Registry.penalties_for(entry)

      assert_includes penalties, penalties(:global_penalty)
      assert_includes penalties, penalties(:books_penalty)
      refute_includes penalties, penalties(:user_penalty)
      refute_includes penalties, penalties(:user_books_penalty)
      refute_includes penalties, penalties(:games_penalty)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/ranking_configurations/registry_test.rb`
Expected: `NameError: uninitialized constant RankingConfigurations::Registry`.

- [ ] **Step 3: Create the registry**

Create `app/lib/ranking_configurations/registry.rb`:

```ruby
# frozen_string_literal: true

# Everything the user-owned ranking configuration feature needs to know about
# a domain, in one place. Switching a domain on is adding entries here (two
# for music: albums and songs), a nav link, and the banner line in its layout
# -- no controller, model or job changes (spec §14).
#
# A domain with no entry 404s the whole /my/rankings surface: every domain
# shares one Firebase project, so a music or games user can sign in and type
# the URL today; the empty registry is what keeps it closed.
module RankingConfigurations
  module Registry
    URL_HELPERS = Rails.application.routes.url_helpers

    Entry = Struct.new(
      :domain,                      # :books
      :kind,                        # URL/param token; only consulted by new/create
      :ranking_configuration_class, # "Books::RankingConfiguration"
      :list_class,                  # what the picker searches and AddLists accepts
      :penalty_classes,             # Penalty STI types a configuration of this kind may apply
      :results_path,                # ->(config) { public ranked page for this configuration }
      :lists_path,                  # ->(config) { public lists page for this configuration }
      :list_path,                   # ->(list)   { public page for one list }
      :official_rankings_path,      # -> { the site's official ranking }
      keyword_init: true
    )

    ENTRIES = [
      Entry.new(
        domain: :books,
        kind: "books",
        ranking_configuration_class: "Books::RankingConfiguration",
        list_class: "Books::List",
        penalty_classes: ["Global::Penalty", "Books::Penalty"],
        results_path: ->(config) { URL_HELPERS.books_rc_path(ranking_configuration_id: config.id) },
        lists_path: ->(config) { URL_HELPERS.books_rc_lists_path(ranking_configuration_id: config.id) },
        list_path: ->(list) { URL_HELPERS.books_list_path(list) },
        official_rankings_path: -> { URL_HELPERS.books_root_path }
      )
    ].freeze

    def self.for_domain(domain)
      ENTRIES.select { |entry| entry.domain == domain.to_sym }
    end

    def self.find(domain, kind)
      for_domain(domain).find { |entry| entry.kind == kind.to_s }
    end

    def self.for_config(config)
      ENTRIES.find { |entry| entry.ranking_configuration_class == config.type }
    end

    # The penalties a user may switch on for this kind: the catalogue rows,
    # never another user's private penalties.
    def self.penalties_for(entry)
      ::Penalty.where(type: entry.penalty_classes, user_id: nil)
    end
  end
end
```

- [ ] **Step 4: Run the registry test**

Run: `bin/rails test test/lib/ranking_configurations/registry_test.rb`
Expected: green.

- [ ] **Step 5: Write the failing `List#name_with_source` test**

Append inside the class in `test/models/list_test.rb`:

```ruby
  test "name_with_source appends source and year when present" do
    list = Books::List.new(name: "Guardian 100", source: "The Guardian", year_published: 2003)
    assert_equal "Guardian 100 (The Guardian, 2003)", list.name_with_source

    assert_equal "Guardian 100 (The Guardian)", Books::List.new(name: "Guardian 100", source: "The Guardian").name_with_source
    assert_equal "Guardian 100 (2003)", Books::List.new(name: "Guardian 100", year_published: 2003).name_with_source
    assert_equal "Guardian 100", Books::List.new(name: "Guardian 100").name_with_source
  end
```

Run: `bin/rails test test/models/list_test.rb -n /name_with_source/`
Expected: `NoMethodError`.

- [ ] **Step 6: Add the display string to the model**

In `app/models/list.rb`, in the `# Public Methods` section, add:

```ruby
  # "Name (Source, 2003)" for pickers and tables. A display string, so it
  # lives on the model rather than in a helper.
  def name_with_source
    detail = [source.presence, year_published].compact.join(", ")
    detail.present? ? "#{name} (#{detail})" : name
  end
```

Run: `bin/rails test test/models/list_test.rb`
Expected: green.

- [ ] **Step 7: Write the failing `PenaltyRows` test**

Create `test/lib/ranking_configurations/penalty_rows_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class PenaltyRowsTest < ActiveSupport::TestCase
    setup do
      @entry = Registry.find(:books, "books")
    end

    test "returns every catalogue penalty for the entry, grouped by category title" do
      groups = PenaltyRows.call(entry: @entry, values: {})

      rows = groups.flat_map(&:rows)
      assert_equal Registry.penalties_for(@entry).count, rows.size
      assert_includes rows.map(&:penalty), penalties(:books_penalty)
      refute_includes rows.map(&:penalty), penalties(:user_penalty)
      assert groups.all? { |group| group.title.present? && group.rows.any? }
    end

    test "marks a penalty enabled with its value when it appears in values, off with 0 otherwise" do
      on = penalties(:books_penalty)
      groups = PenaltyRows.call(entry: @entry, values: {on.id => 40})
      rows = groups.flat_map(&:rows).index_by(&:penalty)

      assert rows[on].enabled
      assert_equal 40, rows[on].value
      refute rows[penalties(:global_penalty)].enabled
      assert_equal 0, rows[penalties(:global_penalty)].value
    end

    test "orders groups by Penalty::CATEGORY_TITLES with uncategorized last" do
      groups = PenaltyRows.call(entry: @entry, values: {})
      titles = groups.map(&:title)
      expected_order = ::Penalty::CATEGORY_TITLES.values + ["Other"]

      assert_equal titles, expected_order.select { |title| titles.include?(title) }
    end
  end
end
```

- [ ] **Step 8: Run it to verify it fails**

Run: `bin/rails test test/lib/ranking_configurations/penalty_rows_test.rb`
Expected: `NameError: uninitialized constant RankingConfigurations::PenaltyRows`.

- [ ] **Step 9: Create `PenaltyRows`**

Create `app/lib/ranking_configurations/penalty_rows.rb`:

```ruby
# frozen_string_literal: true

# The penalty section of the new/edit form: every catalogue penalty for the
# entry, grouped under the same headings the public rankings explainer uses,
# each row carrying whether it is on and at what value.
#
# `values` is {penalty_id => value} for the enabled penalties only -- the
# official configuration's applications for a new form, the configuration's
# own for edit, or the submitted params on a re-render.
module RankingConfigurations
  class PenaltyRows
    Row = Struct.new(:penalty, :enabled, :value, keyword_init: true)
    Group = Struct.new(:title, :rows, keyword_init: true)

    def self.call(entry:, values:)
      penalties = Registry.penalties_for(entry).order(:name).to_a
      by_category = penalties.group_by(&:category)
      categories = ::Penalty::CATEGORY_TITLES.keys + [nil]

      categories.filter_map do |category|
        rows = (by_category[category] || []).map do |penalty|
          Row.new(penalty: penalty, enabled: values.key?(penalty.id), value: values[penalty.id] || 0)
        end
        next if rows.empty?

        Group.new(title: ::Penalty.category_title(category), rows: rows)
      end
    end
  end
end
```

Run: `bin/rails test test/lib/ranking_configurations/penalty_rows_test.rb`
Expected: green.

- [ ] **Step 10: Write the failing `MissingListsQuery` test**

Create `test/lib/ranking_configurations/missing_lists_query_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class MissingListsQueryTest < ActiveSupport::TestCase
    setup do
      @entry = Registry.find(:books, "books")
      @primary = ranking_configurations(:books_global)
      @config = ranking_configurations(:books_user)
      @in_primary = Books::List.create!(name: "Official only", source: "Test", status: :active)
      @in_both = Books::List.create!(name: "In both", source: "Test", status: :active)
      @inactive = Books::List.create!(name: "Inactive official", source: "Test", status: :approved)
      RankedList.create!(list: @in_primary, ranking_configuration: @primary, weight: 80)
      RankedList.create!(list: @in_both, ranking_configuration: @primary, weight: 60)
      RankedList.create!(list: @inactive, ranking_configuration: @primary, weight: 40)
      RankedList.create!(list: @in_both, ranking_configuration: @config)
    end

    test "returns the primary's active lists the configuration does not have, heaviest first" do
      rows = MissingListsQuery.call(config: @config, entry: @entry).to_a

      assert_includes rows.map(&:list), @in_primary
      refute_includes rows.map(&:list), @in_both
      refute_includes rows.map(&:list), @inactive
      assert_equal rows.map(&:weight), rows.map(&:weight).sort.reverse
      assert rows.all? { |row| row.ranking_configuration_id == @primary.id }
    end

    test "is empty once the configuration has every official list" do
      @config.ranked_lists.create!(list: @in_primary)
      assert_empty MissingListsQuery.call(config: @config, entry: @entry)
    end

    test "is empty when the domain has no primary" do
      @primary.update_columns(primary: false)
      assert_empty MissingListsQuery.call(config: @config, entry: @entry)
    end

    test "preloads lists" do
      relation = MissingListsQuery.call(config: @config, entry: @entry)
      assert_queries_count(2) { relation.to_a.each { |row| row.list.name } }
    end
  end
end
```

- [ ] **Step 11: Run it to verify it fails**

Run: `bin/rails test test/lib/ranking_configurations/missing_lists_query_test.rb`
Expected: `NameError`.

- [ ] **Step 12: Create the query**

Create `app/lib/ranking_configurations/missing_lists_query.rb`:

```ruby
# frozen_string_literal: true

# Lists in the domain's official ranking that a user-owned configuration
# lacks, as the official configuration's RankedList rows (so the weight
# shown is the official one). Diffs against the CURRENT primary rather than
# inherited_from so it stays right when a new primary is promoted, and works
# for a configuration that started from scratch.
module RankingConfigurations
  class MissingListsQuery
    def self.call(config:, entry:)
      primary = entry.ranking_configuration_class.constantize.default_primary
      return ::RankedList.none if primary.nil? || primary.id == config.id

      primary.ranked_lists
        .joins(:list)
        .includes(:list)
        .where(lists: {status: ::List.statuses[:active]})
        .where.not(list_id: config.ranked_lists.select(:list_id))
        .order(weight: :desc, id: :asc)
    end
  end
end
```

Run: `bin/rails test test/lib/ranking_configurations/missing_lists_query_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: green; `All is good!`. (The primary in fixtures also owns `books_ranked_list` → `books_list`, which is `approved`, not active — it is correctly excluded.)

- [ ] **Step 13: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/ranking_configurations app/models/list.rb test/lib/ranking_configurations test/models/list_test.rb
git add app/lib/ranking_configurations app/models/list.rb test/lib/ranking_configurations test/models/list_test.rb
git commit -m "feat(rankings): domain registry, penalty rows and the missing-lists diff

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 6: `Services::RankingConfigurations::Create`

**Spec:** §6 (`Create`), §8.2 (starting point), §8.3 (penalty params).

**Files:**
- Create: `app/lib/services/ranking_configurations/create.rb`
- Test: `test/lib/services/ranking_configurations/create_test.rb`

**Interfaces:**
- Consumes: `Registry::Entry` (Task 5), `RankingConfiguration#request_refresh!` (Task 4), `RankingConfiguration::RANKING_SETTINGS` (Task 1).
- Produces: `Services::RankingConfigurations::Create.call(user:, entry:, attributes:, penalties: {}, start: :official, seed_lists: true) → Result(success?:, data: {ranking_configuration:}, errors: [String])`. `penalties` is `Hash{String penalty_id => {"enabled" => "1", "value" => "40"}}` (string keys, as `ActionController::Parameters#to_h` produces).

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/ranking_configurations/create_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class CreateTest < ActiveSupport::TestCase
      setup do
        @user = users(:editor_user) # owns no configurations in fixtures
        @entry = ::RankingConfigurations::Registry.find(:books, "books")
        @primary = ranking_configurations(:books_global)
        @primary.update_columns(min_list_weight: -50, exponent: 2.5, bonus_pool_percentage: 4.0)
        @official_list = ::Books::List.create!(name: "Official", source: "Test", status: :active)
        ::RankedList.create!(list: @official_list, ranking_configuration: @primary, weight: 70)
        @attributes = {name: "My ranking", description: "Mine", user_shared: false}
        ::RankingConfigurations::RefreshJob.stubs(:perform_async)
      end

      test "official start copies settings, clamps min_list_weight, links inherited_from and seeds every list" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: true)

        assert result.success?, result.errors.inspect
        config = result.data[:ranking_configuration]
        assert config.persisted?
        assert_equal @user, config.user
        refute config.global?
        refute config.primary?
        assert_equal @primary.id, config.inherited_from_id
        assert_equal 2.5, config.exponent.to_f
        assert_equal 4.0, config.bonus_pool_percentage.to_f
        assert_equal 0, config.min_list_weight, "the primary's -50 is clamped to its weight_floor"
        assert_nil config.published_at
        assert_nil config.year
        assert_nil config.list_limit
        assert config.needs_refresh?
        assert_equal @primary.ranked_lists.pluck(:list_id).sort, config.ranked_lists.pluck(:list_id).sort
      end

      test "official start without seed_lists copies nothing into ranked_lists" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: false)

        assert result.success?
        assert_empty result.data[:ranking_configuration].ranked_lists
      end

      test "scratch start uses model defaults, no inheritance, no lists, no penalties" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: true)

        assert result.success?, result.errors.inspect
        config = result.data[:ranking_configuration]
        assert_nil config.inherited_from_id
        assert_equal 3.0, config.exponent.to_f
        assert_empty config.ranked_lists
        assert_empty config.penalty_applications
        assert config.needs_refresh?
      end

      test "writes one penalty application per enabled catalogue penalty and ignores foreign ids" do
        enabled = penalties(:books_penalty)
        skipped = penalties(:global_penalty)
        foreign = penalties(:user_penalty)
        submitted = {
          enabled.id.to_s => {"enabled" => "1", "value" => "35"},
          skipped.id.to_s => {"value" => "90"},
          foreign.id.to_s => {"enabled" => "1", "value" => "10"}
        }

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: submitted, start: :scratch, seed_lists: false)

        assert result.success?, result.errors.inspect
        applications = result.data[:ranking_configuration].penalty_applications.index_by(&:penalty_id)
        assert_equal 35, applications[enabled.id].value
        assert_nil applications[skipped.id]
        assert_nil applications[foreign.id]
      end

      test "the submitted attributes override the copied ones" do
        result = Create.call(user: @user, entry: @entry, attributes: @attributes.merge(exponent: 1.5, apply_list_dates_penalty: false), penalties: {}, start: :official, seed_lists: false)

        config = result.data[:ranking_configuration]
        assert_equal 1.5, config.exponent.to_f
        refute config.apply_list_dates_penalty?
      end

      test "requests the first refresh after the transaction" do
        ::RankingConfigurations::RefreshJob.unstub(:perform_async)
        ::RankingConfigurations::RefreshJob.expects(:perform_async).once

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: true)

        assert result.data[:ranking_configuration].reload.refresh_queued?
      end

      test "a validation failure returns the record with errors and persists nothing" do
        ::RankingConfigurations::RefreshJob.expects(:perform_async).never

        assert_no_difference ["::RankingConfiguration.count", "::RankedList.count", "::PenaltyApplication.count"] do
          result = Create.call(user: @user, entry: @entry, attributes: @attributes.merge(name: ""), penalties: {}, start: :official, seed_lists: true)

          refute result.success?
          assert_includes result.errors, "Name can't be blank"
          assert result.data[:ranking_configuration].errors[:name].any?
        end
      end

      test "an invalid penalty value rolls the whole create back" do
        submitted = {penalties(:books_penalty).id.to_s => {"enabled" => "1", "value" => "101"}}

        assert_no_difference ["::RankingConfiguration.count", "::PenaltyApplication.count"] do
          result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: submitted, start: :official, seed_lists: true)

          refute result.success?
          assert result.errors.any? { |message| message.include?("Value") }
        end
      end

      test "the fifth configuration succeeds and the sixth is refused" do
        (::RankingConfiguration::MAX_PER_USER - 1).times do |i|
          ::Books::RankingConfiguration.create!(name: "Existing #{i}", global: false, user: @user, min_list_weight: 0)
        end

        assert Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: false).success?

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :scratch, seed_lists: false)
        refute result.success?
        assert_includes result.errors, "You can have at most #{::RankingConfiguration::MAX_PER_USER} rankings"
      end

      test "official start fails cleanly when the domain has no primary" do
        @primary.update_columns(primary: false)

        result = Create.call(user: @user, entry: @entry, attributes: @attributes, penalties: {}, start: :official, seed_lists: true)

        refute result.success?
        assert_includes result.errors, "There is no official ranking to copy from"
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/ranking_configurations/create_test.rb`
Expected: `NameError: uninitialized constant Services::RankingConfigurations::Create`.

- [ ] **Step 3: Implement the service**

Create `app/lib/services/ranking_configurations/create.rb`:

```ruby
# frozen_string_literal: true

# Creates a user-owned ranking configuration in one transaction -- the row,
# its penalty applications, and (official start with seed_lists) one INSERT
# of every list the official configuration ranks -- then requests the first
# refresh. That automatic run never passes through the rate-limited
# controller action, which is how it stays exempt from the daily cap.
#
# Model constants are root-anchored: Services::RankingConfiguration is an
# existing module, so a bare RankingConfiguration here would resolve to it.
module Services
  module RankingConfigurations
    class Create
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      NO_PRIMARY = "There is no official ranking to copy from"

      def self.call(user:, entry:, attributes:, penalties: {}, start: :official, seed_lists: true)
        new(user: user, entry: entry, attributes: attributes, penalties: penalties, start: start, seed_lists: seed_lists).call
      end

      def initialize(user:, entry:, attributes:, penalties:, start:, seed_lists:)
        @user = user
        @entry = entry
        @attributes = attributes
        @penalties = penalties
        @start = start.to_sym
        @seed_lists = seed_lists
      end

      def call
        primary = configuration_class.default_primary if official?
        return failure(configuration_class.new, [NO_PRIMARY]) if official? && primary.nil?

        config = build(primary)
        config.assign_attributes(attributes)

        ::RankingConfiguration.transaction do
          config.save!
          apply_penalties(config)
          seed_lists_from(primary, config) if official? && seed_lists
        end

        config.request_refresh!
        Result.new(success?: true, data: {ranking_configuration: config}, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        failure(config || configuration_class.new, e.record.errors.full_messages)
      end

      private

      attr_reader :user, :entry, :attributes, :penalties, :start, :seed_lists

      def official? = start == :official

      def configuration_class
        @configuration_class ||= entry.ranking_configuration_class.constantize
      end

      def build(primary)
        return configuration_class.new(global: false, user: user, needs_refresh: true) unless official?

        config = primary.dup
        config.assign_attributes(
          global: false,
          user: user,
          user_shared: false,
          primary: false,
          archived: false,
          published_at: nil,
          year: nil,
          list_limit: nil,
          primary_mapped_list_id: nil,
          secondary_mapped_list_id: nil,
          primary_mapped_list_cutoff_limit: nil,
          secondary_mapped_list_cutoff_limit: nil,
          inherited_from_id: primary.id,
          min_list_weight: primary.weight_floor,
          refresh_status: :idle,
          needs_refresh: true,
          refresh_requested_at: nil,
          last_refreshed_at: nil,
          last_refresh_error: nil
        )
        config
      end

      # Iterates the catalogue, not the params: an unknown or foreign id is
      # ignored, and a missing key means off. Parent first, then children.
      def apply_penalties(config)
        ::RankingConfigurations::Registry.penalties_for(entry).find_each do |penalty|
          submitted = penalties[penalty.id.to_s]
          next unless submitted && ActiveModel::Type::Boolean.new.cast(submitted["enabled"])

          config.penalty_applications.create!(penalty: penalty, value: submitted["value"])
        end
      end

      def seed_lists_from(primary, config)
        list_ids = primary.ranked_lists.pluck(:list_id)
        return if list_ids.empty?

        now = Time.current
        ::RankedList.insert_all(list_ids.map { |list_id|
          {list_id: list_id, ranking_configuration_id: config.id, created_at: now, updated_at: now}
        })
      end

      def failure(config, errors)
        Result.new(success?: false, data: {ranking_configuration: config}, errors: errors)
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ranking_configurations/create_test.rb`
Expected: green. If the "invalid penalty value" test fails because `e.record` is the `PenaltyApplication` and its message reads "Value must be less than or equal to 100", that is the intended message — the assertion only checks for "Value".

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/ranking_configurations test/lib/services/ranking_configurations
git add app/lib/services/ranking_configurations/create.rb test/lib/services/ranking_configurations/create_test.rb
git commit -m "feat(rankings): Create service for user-owned ranking configurations

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 7: `Services::RankingConfigurations::Save`

**Spec:** §6 (`Save`).

**Files:**
- Create: `app/lib/services/ranking_configurations/save.rb`
- Test: `test/lib/services/ranking_configurations/save_test.rb`

**Interfaces:**
- Produces: `Services::RankingConfigurations::Save.call(config:, entry:, attributes:, penalties: {}) → Result(success?:, data: {ranking_configuration:}, errors:)`. Same `penalties` shape as `Create`.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/ranking_configurations/save_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class SaveTest < ActiveSupport::TestCase
      setup do
        @entry = ::RankingConfigurations::Registry.find(:books, "books")
        @config = ranking_configurations(:books_user)
        @config.update_columns(needs_refresh: false)
        @config.penalty_applications.destroy_all
        @on = penalties(:books_penalty)
        @off = penalties(:global_penalty)
        @config.penalty_applications.create!(penalty: @on, value: 20)
        @current = {@on.id.to_s => {"enabled" => "1", "value" => "20"}}
      end

      test "renaming or sharing does not mark the configuration stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {name: "Renamed", user_shared: true}, penalties: @current)

        assert result.success?, result.errors.inspect
        @config.reload
        assert_equal "Renamed", @config.name
        assert @config.user_shared?
        refute @config.needs_refresh?
      end

      test "changing a ranking setting marks the configuration stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {exponent: 4.0}, penalties: @current)

        assert result.success?
        assert @config.reload.needs_refresh?
      end

      test "enabling a penalty creates its application and marks stale" do
        submitted = @current.merge(@off.id.to_s => {"enabled" => "1", "value" => "55"})

        result = Save.call(config: @config, entry: @entry, attributes: {}, penalties: submitted)

        assert result.success?, result.errors.inspect
        assert_equal 55, @config.penalty_applications.find_by(penalty: @off).value
        assert @config.reload.needs_refresh?
      end

      test "changing a value updates the application and marks stale" do
        submitted = {@on.id.to_s => {"enabled" => "1", "value" => "45"}}

        Save.call(config: @config, entry: @entry, attributes: {}, penalties: submitted)

        assert_equal 45, @config.penalty_applications.find_by(penalty: @on).value
        assert @config.reload.needs_refresh?
      end

      test "disabling a penalty destroys its application and marks stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {}, penalties: {})

        assert result.success?
        assert_nil @config.penalty_applications.find_by(penalty: @on)
        assert @config.reload.needs_refresh?
      end

      test "an unchanged penalty set does not mark stale" do
        result = Save.call(config: @config, entry: @entry, attributes: {description: "same math"}, penalties: @current)

        assert result.success?
        refute @config.reload.needs_refresh?
      end

      test "one invalid penalty value rolls back every change" do
        submitted = @current.merge(@off.id.to_s => {"enabled" => "1", "value" => "500"})

        result = Save.call(config: @config, entry: @entry, attributes: {name: "Should not persist"}, penalties: submitted)

        refute result.success?
        assert result.errors.any? { |message| message.include?("Value") }
        @config.reload
        assert_equal "User Books Ranking", @config.name
        assert_nil @config.penalty_applications.find_by(penalty: @off)
        refute @config.needs_refresh?
      end

      test "an invalid setting returns the record with errors" do
        result = Save.call(config: @config, entry: @entry, attributes: {exponent: 50}, penalties: @current)

        refute result.success?
        assert result.data[:ranking_configuration].errors[:exponent].any?
      end

      test "user-specific penalties are never touched" do
        foreign = penalties(:user_penalty)
        submitted = @current.merge(foreign.id.to_s => {"enabled" => "1", "value" => "10"})

        Save.call(config: @config, entry: @entry, attributes: {}, penalties: submitted)

        assert_nil @config.penalty_applications.find_by(penalty: foreign)
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/ranking_configurations/save_test.rb`
Expected: `NameError`.

- [ ] **Step 3: Implement the service**

Create `app/lib/services/ranking_configurations/save.rb`:

```ruby
# frozen_string_literal: true

# Edits a user-owned ranking configuration and syncs its penalty
# applications in one transaction. A penalty is on when it has a row and off
# when it does not (spec §2 #4), so enabling creates, disabling destroys.
# Marks the configuration stale only when the computed result would change:
# a RANKING_SETTINGS attribute or any penalty row. Name, description and
# user_shared never do.
module Services
  module RankingConfigurations
    class Save
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(config:, entry:, attributes:, penalties: {})
        new(config: config, entry: entry, attributes: attributes, penalties: penalties).call
      end

      def initialize(config:, entry:, attributes:, penalties:)
        @config = config
        @entry = entry
        @attributes = attributes
        @penalties = penalties
      end

      def call
        ::RankingConfiguration.transaction do
          config.assign_attributes(attributes)
          settings_changed = (config.changed & ::RankingConfiguration::RANKING_SETTINGS).any?
          config.save!
          penalties_changed = sync_penalties
          config.update!(needs_refresh: true) if settings_changed || penalties_changed
        end

        Result.new(success?: true, data: {ranking_configuration: config}, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        messages = e.record.errors.full_messages
        messages.each { |message| config.errors.add(:base, message) } unless e.record.equal?(config)
        Result.new(success?: false, data: {ranking_configuration: config}, errors: messages)
      end

      private

      attr_reader :config, :entry, :attributes, :penalties

      def sync_penalties
        changed = false
        existing = config.penalty_applications.index_by(&:penalty_id)

        ::RankingConfigurations::Registry.penalties_for(entry).find_each do |penalty|
          submitted = penalties[penalty.id.to_s] || {}
          enabled = ActiveModel::Type::Boolean.new.cast(submitted["enabled"])
          application = existing[penalty.id]

          if enabled
            application ||= config.penalty_applications.build(penalty: penalty)
            application.value = submitted["value"]
            next unless application.new_record? || application.changed?

            application.save!
            changed = true
          elsif application
            application.destroy!
            changed = true
          end
        end

        changed
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ranking_configurations/save_test.rb`
Expected: green.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/ranking_configurations test/lib/services/ranking_configurations
git add app/lib/services/ranking_configurations/save.rb test/lib/services/ranking_configurations/save_test.rb
git commit -m "feat(rankings): Save service syncs settings and penalty applications

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 8: `Services::RankingConfigurations::AddLists`

**Spec:** §6 (`AddLists`).

**Files:**
- Create: `app/lib/services/ranking_configurations/add_lists.rb`
- Test: `test/lib/services/ranking_configurations/add_lists_test.rb`

**Interfaces:**
- Produces: `Services::RankingConfigurations::AddLists.call(config:, entry:, list_ids:) → Result(success?: true, data: {added: Integer}, errors: [])`.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/ranking_configurations/add_lists_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class AddListsTest < ActiveSupport::TestCase
      setup do
        @entry = ::RankingConfigurations::Registry.find(:books, "books")
        @config = ranking_configurations(:books_user)
        @config.update_columns(needs_refresh: false)
        @active = ::Books::List.create!(name: "Active", source: "T", status: :active)
        @another = ::Books::List.create!(name: "Another", source: "T", status: :active)
        @approved = ::Books::List.create!(name: "Approved only", source: "T", status: :approved)
        @present = ::Books::List.create!(name: "Already there", source: "T", status: :active)
        ::RankedList.create!(list: @present, ranking_configuration: @config)
      end

      test "adds active lists of the entry's type that are not already present, once" do
        result = AddLists.call(config: @config, entry: @entry, list_ids: [@active.id, @another.id, @active.id])

        assert result.success?
        assert_equal 2, result.data[:added]
        assert_equal [@active.id, @another.id, @present.id].sort, @config.ranked_lists.pluck(:list_id).sort
        assert @config.reload.needs_refresh?
      end

      test "skips lists that are not active, already present, of another type, or nonsense" do
        games_list = lists(:games_list)

        result = AddLists.call(config: @config, entry: @entry, list_ids: [@approved.id, @present.id, games_list.id, "abc", -1, nil])

        assert result.success?
        assert_equal 0, result.data[:added]
        assert_equal [@present.id], @config.ranked_lists.pluck(:list_id)
        refute @config.reload.needs_refresh?, "nothing changed, so nothing is stale"
      end

      test "accepts string ids as posted by a form" do
        result = AddLists.call(config: @config, entry: @entry, list_ids: [@active.id.to_s])

        assert_equal 1, result.data[:added]
      end
    end
  end
end
```

Check the games list fixture name first: `grep -n "^games_list:" test/fixtures/lists.yml`. If it is named differently, use that name.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/ranking_configurations/add_lists_test.rb`
Expected: `NameError`.

- [ ] **Step 3: Implement the service**

Create `app/lib/services/ranking_configurations/add_lists.rb`:

```ruby
# frozen_string_literal: true

# Adds lists to a user-owned ranking configuration in one INSERT. Only
# active lists of the entry's type count -- the calculator ignores every
# other status -- and lists already present are skipped rather than erroring,
# so the picker's "Add selected", each diff row's Add and "Add all" share
# this one path.
module Services
  module RankingConfigurations
    class AddLists
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(config:, entry:, list_ids:)
        new(config: config, entry: entry, list_ids: list_ids).call
      end

      def initialize(config:, entry:, list_ids:)
        @config = config
        @entry = entry
        @list_ids = Array(list_ids).map { |id| Integer(id.to_s, exception: false) }.compact.select(&:positive?).uniq
      end

      def call
        candidates = entry.list_class.constantize
          .where(status: :active, id: list_ids)
          .where.not(id: config.ranked_lists.select(:list_id))
          .pluck(:id)
        return Result.new(success?: true, data: {added: 0}, errors: []) if candidates.empty?

        now = Time.current
        ::RankingConfiguration.transaction do
          ::RankedList.insert_all(candidates.map { |list_id|
            {list_id: list_id, ranking_configuration_id: config.id, created_at: now, updated_at: now}
          })
          config.update!(needs_refresh: true)
        end

        Result.new(success?: true, data: {added: candidates.size}, errors: [])
      end

      private

      attr_reader :config, :entry, :list_ids
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/ranking_configurations/`
Expected: green.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/ranking_configurations test/lib/services/ranking_configurations
git add app/lib/services/ranking_configurations/add_lists.rb test/lib/services/ranking_configurations/add_lists_test.rb
git commit -m "feat(rankings): AddLists service for user-owned ranking configurations

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 9: `RankingConfigurationPolicy`

**Spec:** §7 (policy).

**Files:**
- Create: `app/policies/ranking_configuration_policy.rb`
- Test: `test/policies/ranking_configuration_policy_test.rb`

**Interfaces:**
- Produces: `RankingConfigurationPolicy` with `index? create? new? show? edit? update? destroy? refresh? state? manage_lists?` and `RankingConfigurationPolicy::Scope#resolve`.

- [ ] **Step 1: Write the failing tests**

Create `test/policies/ranking_configuration_policy_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class RankingConfigurationPolicyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:regular_user)
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @config = ranking_configurations(:books_user)
    @shared = ranking_configurations(:books_user_shared)
  end

  test "any signed-in user may list and create; anonymous may not" do
    assert RankingConfigurationPolicy.new(@editor, RankingConfiguration).index?
    assert RankingConfigurationPolicy.new(@editor, RankingConfiguration).create?
    assert RankingConfigurationPolicy.new(@editor, RankingConfiguration).new?
    refute RankingConfigurationPolicy.new(nil, RankingConfiguration).index?
    refute RankingConfigurationPolicy.new(nil, RankingConfiguration).create?
  end

  test "only the owner may manage a configuration, shared or not" do
    [:show?, :edit?, :update?, :destroy?, :refresh?, :state?, :manage_lists?].each do |action|
      assert RankingConfigurationPolicy.new(@owner, @config).public_send(action), action
      assert RankingConfigurationPolicy.new(@owner, @shared).public_send(action), action
      refute RankingConfigurationPolicy.new(@editor, @shared).public_send(action), "#{action}: a domain editor is not the owner"
      refute RankingConfigurationPolicy.new(@admin, @config).public_send(action), "#{action}: an admin is not the owner"
      refute RankingConfigurationPolicy.new(nil, @shared).public_send(action), action
    end
  end

  test "scope returns only the user's own rows" do
    assert_equal [@config.id, @shared.id].sort,
      RankingConfigurationPolicy::Scope.new(@owner, RankingConfiguration).resolve.pluck(:id).sort
    assert_empty RankingConfigurationPolicy::Scope.new(@admin, RankingConfiguration).resolve
    assert_empty RankingConfigurationPolicy::Scope.new(nil, RankingConfiguration).resolve
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/policies/ranking_configuration_policy_test.rb`
Expected: `NameError: uninitialized constant RankingConfigurationPolicy`.

- [ ] **Step 3: Create the policy**

Create `app/policies/ranking_configuration_policy.rb`:

```ruby
# frozen_string_literal: true

# Ownership policy for the /my/rankings surface. Separate from the admin
# Books::RankingConfigurationPolicy (domain roles, bulk actions): the question
# here is "does this user own this row", and neither admins nor domain
# editors get that answer for someone else's configuration.
#
# Pundit's default policy for a Books::RankingConfiguration record IS the
# admin one, so every authorize call must pass
# policy_class: RankingConfigurationPolicy explicitly.
#
# create? is where a membership gate goes later.
class RankingConfigurationPolicy < ApplicationPolicy
  def index? = user.present?
  def create? = user.present?
  def new? = create?
  def show? = owner?
  def update? = owner?
  def edit? = update?
  def destroy? = owner?
  def refresh? = owner?
  def state? = owner?
  def manage_lists? = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      scope.where(user: user)
    end
  end

  private

  def owner? = user.present? && record.respond_to?(:user_id) && record.user_id == user.id
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/policies/ranking_configuration_policy_test.rb`
Expected: green.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/policies/ranking_configuration_policy.rb test/policies/ranking_configuration_policy_test.rb
git add app/policies/ranking_configuration_policy.rb test/policies/ranking_configuration_policy_test.rb
git commit -m "feat(rankings): owner policy for user-owned ranking configurations

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 10: Routes, owner-scoped concern, `My::RankingConfigurationsController`, and the index/new/edit/show pages

**Spec:** §8 (routes, controllers, 8.1–8.4 minus the refresh button and polling, which Task 11 adds).

**Files:**
- Modify: `config/routes.rb` (new global block after the saved-searches block, before `# Domain-specific roots`)
- Create: `app/controllers/concerns/ranking_configuration_owner_scoped.rb`
- Create: `app/controllers/my/ranking_configurations_controller.rb` (generator)
- Create: `app/views/my/ranking_configurations/index.html.erb`, `new.html.erb`, `edit.html.erb`, `show.html.erb`, `choose_kind.html.erb`, `_form.html.erb`, `_notice.html.erb`, `_status.html.erb`, `_status_badge.html.erb`
- Test: `test/controllers/my/ranking_configurations_controller_test.rb`, `test/routing/my_ranking_configurations_routes_test.rb`

**Interfaces:**
- Consumes: `Registry`, `PenaltyRows` (Task 5), `Create`/`Save` (Tasks 6–7), `RankingConfigurationPolicy` (Task 9), `DomainLayout#resolve_layout`, `Cacheable#prevent_caching`, `ApplicationController#require_signed_in!`.
- Produces: route helpers `my_ranking_configurations_path`, `new_my_ranking_configuration_path(kind:, start:)`, `my_ranking_configuration_path(config)`, `edit_my_ranking_configuration_path(config)`, `refresh_my_ranking_configuration_path(config)`, `state_my_ranking_configuration_path(config)`, `my_ranking_configuration_lists_path(config)`, `search_my_ranking_configuration_lists_path(config)`, `add_missing_my_ranking_configuration_lists_path(config)`, `my_ranking_configuration_list_path(config, list_id)`; concern `RankingConfigurationOwnerScoped` (`domain_entries`, `require_domain_support!`, `set_ranking_configuration(query = nil)`, `current_entry` — also a helper method); partials `my/ranking_configurations/_notice`, `_status` (locals: `ranking_configuration`), `_status_badge` (locals: `ranking_configuration`).

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, directly after the saved-searches legacy redirects block (the three `get "v/:view_type/searches..."` lines) and before `# Domain-specific roots using Default controllers`, insert:

```ruby
  # My Rankings -- user-owned ranking configurations. Global routes like
  # /searches: the controller resolves the domain from Current.domain through
  # RankingConfigurations::Registry and 404s on a domain with no entry. Every
  # route here is owner-only and never cached; the public view of a
  # configuration is its /rc/:id page on the domain's own routes.
  get "my/rankings", to: "my/ranking_configurations#index", as: :my_ranking_configurations
  get "my/rankings/new", to: "my/ranking_configurations#new", as: :new_my_ranking_configuration
  post "my/rankings", to: "my/ranking_configurations#create"
  get "my/rankings/:id", to: "my/ranking_configurations#show", as: :my_ranking_configuration,
    constraints: {id: /\d+/}
  get "my/rankings/:id/edit", to: "my/ranking_configurations#edit", as: :edit_my_ranking_configuration,
    constraints: {id: /\d+/}
  patch "my/rankings/:id", to: "my/ranking_configurations#update", constraints: {id: /\d+/}
  put "my/rankings/:id", to: "my/ranking_configurations#update", constraints: {id: /\d+/}
  delete "my/rankings/:id", to: "my/ranking_configurations#destroy", constraints: {id: /\d+/}
  post "my/rankings/:id/refresh", to: "my/ranking_configurations#refresh",
    as: :refresh_my_ranking_configuration, constraints: {id: /\d+/}
  get "my/rankings/:id/state", to: "my/ranking_configurations#state",
    as: :state_my_ranking_configuration, constraints: {id: /\d+/}

  get "my/rankings/:ranking_configuration_id/lists", to: "my/ranking_configurations/lists#index",
    as: :my_ranking_configuration_lists, constraints: {ranking_configuration_id: /\d+/}
  get "my/rankings/:ranking_configuration_id/lists/search", to: "my/ranking_configurations/lists#search",
    as: :search_my_ranking_configuration_lists, constraints: {ranking_configuration_id: /\d+/}
  post "my/rankings/:ranking_configuration_id/lists", to: "my/ranking_configurations/lists#create",
    constraints: {ranking_configuration_id: /\d+/}
  post "my/rankings/:ranking_configuration_id/lists/add_missing", to: "my/ranking_configurations/lists#add_missing",
    as: :add_missing_my_ranking_configuration_lists, constraints: {ranking_configuration_id: /\d+/}
  delete "my/rankings/:ranking_configuration_id/lists/:list_id", to: "my/ranking_configurations/lists#destroy",
    as: :my_ranking_configuration_list, constraints: {ranking_configuration_id: /\d+/, list_id: /\d+/}
```

- [ ] **Step 2: Write the failing routing test**

Create `test/routing/my_ranking_configurations_routes_test.rb`:

```ruby
require "test_helper"

class MyRankingConfigurationsRoutesTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  test "my rankings routes resolve on the books host" do
    base = "http://#{HOST}"
    assert_routing({method: :get, path: "#{base}/my/rankings"},
      controller: "my/ranking_configurations", action: "index")
    assert_routing({method: :get, path: "#{base}/my/rankings/new"},
      controller: "my/ranking_configurations", action: "new")
    assert_routing({method: :post, path: "#{base}/my/rankings"},
      controller: "my/ranking_configurations", action: "create")
    assert_routing({method: :get, path: "#{base}/my/rankings/12"},
      controller: "my/ranking_configurations", action: "show", id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/edit"},
      controller: "my/ranking_configurations", action: "edit", id: "12")
    assert_routing({method: :patch, path: "#{base}/my/rankings/12"},
      controller: "my/ranking_configurations", action: "update", id: "12")
    assert_routing({method: :delete, path: "#{base}/my/rankings/12"},
      controller: "my/ranking_configurations", action: "destroy", id: "12")
    assert_routing({method: :post, path: "#{base}/my/rankings/12/refresh"},
      controller: "my/ranking_configurations", action: "refresh", id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/state"},
      controller: "my/ranking_configurations", action: "state", id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/lists"},
      controller: "my/ranking_configurations/lists", action: "index", ranking_configuration_id: "12")
    assert_routing({method: :get, path: "#{base}/my/rankings/12/lists/search"},
      controller: "my/ranking_configurations/lists", action: "search", ranking_configuration_id: "12")
    assert_routing({method: :post, path: "#{base}/my/rankings/12/lists"},
      controller: "my/ranking_configurations/lists", action: "create", ranking_configuration_id: "12")
    assert_routing({method: :post, path: "#{base}/my/rankings/12/lists/add_missing"},
      controller: "my/ranking_configurations/lists", action: "add_missing", ranking_configuration_id: "12")
    assert_routing({method: :delete, path: "#{base}/my/rankings/12/lists/34"},
      controller: "my/ranking_configurations/lists", action: "destroy", ranking_configuration_id: "12", list_id: "34")
  end

  test "non-numeric ids do not route" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/my/rankings/abc", method: :get)
    end
  end
end
```

Run: `bin/rails test test/routing/my_ranking_configurations_routes_test.rb`
Expected: green (routes exist; controllers are not loaded by `assert_routing`).

- [ ] **Step 3: Generate the controller**

```bash
bin/rails generate controller my/ranking_configurations --skip-routes --no-helper
```

Expected: `app/controllers/my/ranking_configurations_controller.rb`, `test/controllers/my/ranking_configurations_controller_test.rb`, an empty `app/views/my/ranking_configurations/`. If the generator also created `app/helpers/my/ranking_configurations_helper.rb` or an assets file, delete them.

- [ ] **Step 4: Write the failing controller tests**

Replace `test/controllers/my/ranking_configurations_controller_test.rb` with:

```ruby
require "test_helper"

class My::RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:books]
    @owner = users(:regular_user)
    @stranger = users(:editor_user)
    @config = ranking_configurations(:books_user)
    @shared = ranking_configurations(:books_user_shared)
    @primary = ranking_configurations(:books_global)
  end

  def valid_attributes(overrides = {})
    {
      name: "Mine", description: "A description", user_shared: "0",
      exponent: "3.0", bonus_pool_percentage: "3.0", min_list_weight: "0",
      apply_list_dates_penalty: "1", max_list_dates_penalty_age: "50", max_list_dates_penalty_percentage: "80"
    }.merge(overrides)
  end

  # Sidekiq runs inline in tests; the refresh job would really calculate.
  # fake! pushes onto RefreshJob.jobs instead so tests can count enqueues.
  def with_fake_sidekiq
    Sidekiq::Testing.fake! do
      RankingConfigurations::RefreshJob.clear
      yield
    end
  end

  def fill_to_cap(user)
    existing = RankingConfiguration.where(type: "Books::RankingConfiguration", user_id: user.id).count
    (RankingConfiguration::MAX_PER_USER - existing).times do |i|
      Books::RankingConfiguration.create!(name: "Cap #{i}", global: false, user: user, min_list_weight: 0)
    end
  end

  # --- access ---

  test "every page requires sign-in" do
    get my_ranking_configurations_path
    assert_redirected_to "/"
    get new_my_ranking_configuration_path
    assert_redirected_to "/"
    get my_ranking_configuration_path(@config)
    assert_redirected_to "/"
    post my_ranking_configurations_path, params: {ranking_configuration: valid_attributes}
    assert_redirected_to "/"
  end

  test "the surface 404s on a domain with no registry entry" do
    host! Rails.application.config.domains[:games]
    sign_in_as @owner, stub_auth: true

    get my_ranking_configurations_path
    assert_response :not_found
  end

  test "pages are never cached" do
    sign_in_as @owner, stub_auth: true
    get my_ranking_configurations_path
    assert_match "no-store", response.headers["Cache-Control"].to_s
  end

  # --- index ---

  test "index lists only the current user's configurations for this domain" do
    sign_in_as @owner, stub_auth: true

    get my_ranking_configurations_path

    assert_response :success
    ids = @controller.view_assigns["ranking_configurations"].map(&:id)
    assert_equal [@config.id, @shared.id].sort, ids.sort
    refute @controller.view_assigns["at_limit"]
  end

  test "index flags the cap" do
    fill_to_cap(@owner)
    sign_in_as @owner, stub_auth: true

    get my_ranking_configurations_path

    assert @controller.view_assigns["at_limit"]
  end

  # --- new ---

  test "new pre-fills settings and penalties from the official configuration" do
    @primary.update_columns(exponent: 2.5, min_list_weight: -50)
    sign_in_as @owner, stub_auth: true

    get new_my_ranking_configuration_path

    assert_response :success
    form = @controller.view_assigns["ranking_configuration"]
    assert_equal 2.5, form.exponent.to_f
    assert_equal 0, form.min_list_weight
    assert_equal :official, @controller.view_assigns["start"]
    enabled = @controller.view_assigns["penalty_groups"].flat_map(&:rows).select(&:enabled).map { |row| row.penalty.id }
    assert_equal @primary.penalty_applications.pluck(:penalty_id).sort, enabled.sort
    assert_equal @primary.ranked_lists.count, @controller.view_assigns["official_list_count"]
  end

  test "new with start=scratch pre-fills defaults with every penalty off" do
    sign_in_as @owner, stub_auth: true

    get new_my_ranking_configuration_path(start: "scratch")

    assert_response :success
    assert_equal :scratch, @controller.view_assigns["start"]
    assert_equal 3.0, @controller.view_assigns["ranking_configuration"].exponent.to_f
    assert @controller.view_assigns["penalty_groups"].flat_map(&:rows).none?(&:enabled)
  end

  # --- create ---

  test "create builds the configuration, seeds the official lists, applies penalties, queues the first refresh" do
    list = Books::List.create!(name: "Official", source: "T", status: :active)
    RankedList.create!(list: list, ranking_configuration: @primary, weight: 70)
    penalty = penalties(:books_penalty)
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      assert_difference "RankingConfiguration.count", 1 do
        post my_ranking_configurations_path, params: {
          start: "official", seed_lists: "1",
          ranking_configuration: valid_attributes,
          penalties: {penalty.id.to_s => {enabled: "1", value: "33"}}
        }
      end
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end

    created = RankingConfiguration.order(:id).last
    assert_redirected_to my_ranking_configuration_path(created)
    assert flash[:notice].present?
    assert_equal @owner, created.user
    assert_equal @primary.ranked_lists.count, created.ranked_lists.count
    assert_includes created.ranked_lists.pluck(:list_id), list.id
    assert_equal 33, created.penalty_applications.find_by(penalty: penalty).value
    assert created.refresh_queued?
  end

  test "create with start=scratch seeds nothing and inherits nothing" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      post my_ranking_configurations_path, params: {start: "scratch", ranking_configuration: valid_attributes}
    end

    created = RankingConfiguration.order(:id).last
    assert_empty created.ranked_lists
    assert_empty created.penalty_applications
    assert_nil created.inherited_from_id
  end

  test "create re-renders the form on a validation failure" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      assert_no_difference "RankingConfiguration.count" do
        post my_ranking_configurations_path, params: {start: "official", ranking_configuration: valid_attributes(name: "")}
      end
      assert_empty RankingConfigurations::RefreshJob.jobs
    end
    assert_response :unprocessable_entity
  end

  test "create refuses the sixth configuration" do
    fill_to_cap(@owner)
    sign_in_as @owner, stub_auth: true

    assert_no_difference "RankingConfiguration.count" do
      post my_ranking_configurations_path, params: {start: "scratch", ranking_configuration: valid_attributes}
    end
    assert_response :unprocessable_entity
  end

  # --- show ---

  test "show renders for the owner" do
    sign_in_as @owner, stub_auth: true

    get my_ranking_configuration_path(@config)

    assert_response :success
    assert_equal @config, @controller.view_assigns["ranking_configuration"]
  end

  test "show 404s for a non-owner, a shared configuration included, and for a global one" do
    sign_in_as @stranger, stub_auth: true
    get my_ranking_configuration_path(@config)
    assert_response :not_found
    get my_ranking_configuration_path(@shared)
    assert_response :not_found

    sign_in_as @owner, stub_auth: true
    get my_ranking_configuration_path(@primary)
    assert_response :not_found
  end

  # --- edit / update ---

  test "edit renders for the owner with the configuration's own penalty values" do
    @config.penalty_applications.create!(penalty: penalties(:books_penalty), value: 12)
    sign_in_as @owner, stub_auth: true

    get edit_my_ranking_configuration_path(@config)

    assert_response :success
    row = @controller.view_assigns["penalty_groups"].flat_map(&:rows).find { |r| r.penalty == penalties(:books_penalty) }
    assert row.enabled
    assert_equal 12, row.value
  end

  test "update saves settings and marks the configuration stale" do
    sign_in_as @owner, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {ranking_configuration: valid_attributes(name: "Renamed", exponent: "4.0")}

    assert_redirected_to my_ranking_configuration_path(@config)
    assert flash[:notice].present?
    @config.reload
    assert_equal "Renamed", @config.name
    assert_equal 4.0, @config.exponent.to_f
    assert @config.needs_refresh?
  end

  test "update re-renders on a validation failure" do
    sign_in_as @owner, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {ranking_configuration: valid_attributes(exponent: "50")}

    assert_response :unprocessable_entity
  end

  test "update ignores penalty ids outside the catalogue" do
    foreign = penalties(:user_penalty)
    @config.penalty_applications.where(penalty: foreign).destroy_all
    sign_in_as @owner, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {
      ranking_configuration: valid_attributes,
      penalties: {foreign.id.to_s => {enabled: "1", value: "10"}, "999999" => {enabled: "1", value: "10"}}
    }

    assert_redirected_to my_ranking_configuration_path(@config)
    assert_nil @config.penalty_applications.find_by(penalty: foreign)
  end

  test "a non-owner cannot update or destroy" do
    sign_in_as @stranger, stub_auth: true

    patch my_ranking_configuration_path(@config), params: {ranking_configuration: valid_attributes(name: "Hijacked")}
    assert_response :not_found
    delete my_ranking_configuration_path(@config)
    assert_response :not_found

    assert_equal "User Books Ranking", @config.reload.name
  end

  # --- destroy ---

  test "destroy removes the configuration and its children" do
    @config.penalty_applications.create!(penalty: penalties(:books_penalty), value: 5)
    @config.ranked_lists.create!(list: Books::List.create!(name: "L", source: "T", status: :active))
    sign_in_as @owner, stub_auth: true

    assert_difference ["RankingConfiguration.count", "RankedList.count"], -1 do
      delete my_ranking_configuration_path(@config)
    end
    assert_redirected_to my_ranking_configurations_path
    assert flash[:notice].present?
  end
end
```

- [ ] **Step 5: Run them to verify they fail**

Run: `bin/rails test test/controllers/my/ranking_configurations_controller_test.rb`
Expected: failures (`AbstractController::ActionNotFound` / missing templates).

- [ ] **Step 6: Create the owner-scoped concern**

Create `app/controllers/concerns/ranking_configuration_owner_scoped.rb`:

```ruby
# frozen_string_literal: true

# The owner-only half of /my/rankings: which registry entries serve this
# host, the owner-scoped lookup, and the entry for a loaded configuration.
# Named after SavedSearchDomainScoped, which does the same job for /searches.
#
# Every lookup is scoped through current_user.ranking_configurations, so a
# stranger's id -- shared or not -- is a 404, never a 403 that would confirm
# it exists. The type filter keeps a configuration from another domain off
# this host.
#
# Registry constants are root-anchored because the lists controller lives
# in the My::RankingConfigurations namespace, where a bare
# RankingConfigurations would resolve to that module.
module RankingConfigurationOwnerScoped
  extend ActiveSupport::Concern

  included do
    helper_method :current_entry
  end

  private

  def domain_entries
    @domain_entries ||= ::RankingConfigurations::Registry.for_domain(Current.domain)
  end

  # Before require_signed_in!, so a host with no entry 404s instead of
  # bouncing an anonymous visitor to a sign-in that would not have helped.
  def require_domain_support!
    raise ActiveRecord::RecordNotFound if domain_entries.empty?
  end

  def set_ranking_configuration(query = nil)
    id = params[:ranking_configuration_id] || params[:id]
    @ranking_configuration = current_user.ranking_configurations
      .where(type: domain_entries.map(&:ranking_configuration_class))
      .find(id)
    authorize @ranking_configuration, query, policy_class: RankingConfigurationPolicy
  end

  def current_entry
    @current_entry ||= ::RankingConfigurations::Registry.for_config(@ranking_configuration)
  end
end
```

- [ ] **Step 7: Write the controller**

Replace `app/controllers/my/ranking_configurations_controller.rb` with:

```ruby
# User-owned ranking configurations (spec: docs/superpowers/specs/
# 2026-09-12-user-ranking-configurations-design.md). Global routes; the
# domain comes from Current.domain via RankingConfigurations::Registry.
# Owner-only and never cached. The public view of a configuration is its
# /rc/:id page, gated by RankingConfigurationGating.
class My::RankingConfigurationsController < ApplicationController
  include Cacheable
  include DomainLayout
  include RankingConfigurationOwnerScoped

  layout :resolve_layout

  before_action :prevent_caching
  before_action :require_domain_support!
  before_action :require_signed_in!
  before_action :set_ranking_configuration, only: [:show, :edit, :update, :destroy]

  def index
    types = domain_entries.map(&:ranking_configuration_class)
    @ranking_configurations = current_user.ranking_configurations.where(type: types).order(created_at: :desc).to_a
    counts = @ranking_configurations.group_by(&:type).transform_values(&:size)
    @at_limit = types.all? { |type| counts.fetch(type, 0) >= ::RankingConfiguration::MAX_PER_USER }
  end

  def new
    if domain_entries.many? && params[:kind].blank?
      @entries = domain_entries
      return render :choose_kind
    end

    @entry = entry_for_new
    @start = start_param
    @ranking_configuration = @entry.ranking_configuration_class.constantize.new(new_defaults)
    authorize @ranking_configuration, policy_class: RankingConfigurationPolicy
    @penalty_groups = ::RankingConfigurations::PenaltyRows.call(entry: @entry, values: default_penalty_values)
    @seed_lists = true
    @official_list_count = official_list_count
  end

  def create
    @entry = entry_for_new
    @start = start_param
    authorize ::RankingConfiguration, policy_class: RankingConfigurationPolicy

    result = Services::RankingConfigurations::Create.call(
      user: current_user,
      entry: @entry,
      attributes: configuration_params,
      penalties: penalty_params(@entry),
      start: @start,
      seed_lists: params[:seed_lists] == "1"
    )

    if result.success?
      redirect_to my_ranking_configuration_path(result.data[:ranking_configuration]),
        notice: "Your ranking was created. We're calculating it now — this usually takes a few minutes.",
        status: :see_other
    else
      @ranking_configuration = result.data[:ranking_configuration]
      @penalty_groups = ::RankingConfigurations::PenaltyRows.call(entry: @entry, values: submitted_penalty_values(@entry))
      @seed_lists = params[:seed_lists] == "1"
      @official_list_count = official_list_count
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @entry = current_entry
    @lists_count = @ranking_configuration.ranked_lists.count
    @penalties_on = @ranking_configuration.penalty_applications.count
    @penalties_total = ::RankingConfigurations::Registry.penalties_for(@entry).count
  end

  def edit
    @entry = current_entry
    @penalty_groups = ::RankingConfigurations::PenaltyRows.call(
      entry: @entry,
      values: @ranking_configuration.penalty_applications.pluck(:penalty_id, :value).to_h
    )
  end

  def update
    @entry = current_entry
    result = Services::RankingConfigurations::Save.call(
      config: @ranking_configuration,
      entry: @entry,
      attributes: configuration_params,
      penalties: penalty_params(@entry)
    )

    if result.success?
      redirect_to my_ranking_configuration_path(@ranking_configuration), notice: "Your ranking was saved.", status: :see_other
    else
      @penalty_groups = ::RankingConfigurations::PenaltyRows.call(entry: @entry, values: submitted_penalty_values(@entry))
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @ranking_configuration.destroy
    redirect_to my_ranking_configurations_path, notice: "Your ranking was deleted.", status: :see_other
  end

  private

  def entry_for_new
    return domain_entries.first if domain_entries.one?

    ::RankingConfigurations::Registry.find(Current.domain, params[:kind]) || raise(ActiveRecord::RecordNotFound)
  end

  def start_param
    (params[:start] == "scratch") ? :scratch : :official
  end

  def official_configuration
    return @official_configuration if defined?(@official_configuration)

    @official_configuration = @entry.ranking_configuration_class.constantize.default_primary
  end

  def official_list_count
    official_configuration&.ranked_lists&.count.to_i
  end

  # The new form starts from the official configuration unless the visitor
  # chose to start from scratch (model defaults).
  def new_defaults
    return {} if @start == :scratch || official_configuration.nil?

    official_configuration.slice(*::RankingConfiguration::RANKING_SETTINGS)
      .merge("min_list_weight" => official_configuration.weight_floor)
  end

  def default_penalty_values
    return {} if @start == :scratch || official_configuration.nil?

    official_configuration.penalty_applications.pluck(:penalty_id, :value).to_h
  end

  def configuration_params
    params.require(:ranking_configuration).permit(:name, :description, :user_shared, *::RankingConfiguration::RANKING_SETTINGS)
  end

  # Only the catalogue's ids are permitted, each with enabled + value. A
  # hand-built request can send penalties as a scalar; that is an empty set,
  # not a 500.
  def penalty_params(entry)
    raw = params[:penalties]
    return {} unless raw.is_a?(ActionController::Parameters)

    allowed = ::RankingConfigurations::Registry.penalties_for(entry).pluck(:id)
      .index_with { [:enabled, :value] }.transform_keys(&:to_s)
    raw.permit(allowed).to_h
  end

  def submitted_penalty_values(entry)
    penalty_params(entry).each_with_object({}) do |(id, row), values|
      values[id.to_i] = row["value"].to_i if ActiveModel::Type::Boolean.new.cast(row["enabled"])
    end
  end
end
```

- [ ] **Step 8: Write the shared partials**

`app/views/my/ranking_configurations/_notice.html.erb`:

```erb
<%# Public layouts render no flash; this feature renders its own inside each view. %>
<% if flash[:notice].present? %>
  <div class="alert alert-success" role="status"><span><%= flash[:notice] %></span></div>
<% end %>
<% if flash[:alert].present? %>
  <div class="alert alert-error" role="alert"><span><%= flash[:alert] %></span></div>
<% end %>
```

`app/views/my/ranking_configurations/_status_badge.html.erb`:

```erb
<%
  config = ranking_configuration
  label, css = if config.refresh_in_progress?
    ["Calculating", "badge-info"]
  elsif config.refresh_failed?
    ["Failed", "badge-error"]
  elsif config.needs_refresh?
    ["Needs refresh", "badge-warning"]
  else
    ["Up to date", "badge-success"]
  end
%>
<span class="badge <%= css %>"><%= label %></span>
```

`app/views/my/ranking_configurations/_status.html.erb` (Task 11 adds the Refresh button and polling to this file):

```erb
<% config = ranking_configuration %>
<section id="ranking-status" class="card bg-base-100 border border-base-300 shadow-sm">
  <div class="card-body gap-3">
    <div class="flex flex-wrap items-center gap-3">
      <h2 class="card-title">Status</h2>
      <%= render "my/ranking_configurations/status_badge", ranking_configuration: config %>
    </div>
    <% if config.refresh_in_progress? %>
      <p>Calculating weights and rankings. This usually takes a few minutes — this page will update when it's done.</p>
    <% elsif config.refresh_failed? %>
      <p class="[overflow-wrap:anywhere]">The last refresh failed<% if config.last_refresh_error.present? %>: <%= config.last_refresh_error %><% end %>. You can try again.</p>
    <% elsif config.needs_refresh? %>
      <p>Your changes haven't been applied yet. Refresh weights and rankings to see them.</p>
    <% else %>
      <p>Up to date<% if config.last_refreshed_at %> — last refreshed <%= time_ago_in_words(config.last_refreshed_at) %> ago<% end %>.</p>
    <% end %>
  </div>
</section>
```

- [ ] **Step 9: Write the form partial**

`app/views/my/ranking_configurations/_form.html.erb` (locals: `ranking_configuration`, `entry`, `penalty_groups`, `start`, `seed_lists`, `official_list_count`):

```erb
<%
  persisted = ranking_configuration.persisted?
  noun = ranking_configuration.media_noun_plural
  errors = ranking_configuration.errors
  field_class = ->(attribute, base) { "#{base} w-full #{"input-error" if errors[attribute].any?}" }
%>
<%= form_with model: ranking_configuration, scope: :ranking_configuration,
      url: persisted ? my_ranking_configuration_path(ranking_configuration) : my_ranking_configurations_path,
      class: "space-y-6" do |form| %>
  <% unless persisted %>
    <%= hidden_field_tag :start, start, id: nil %>
    <%= hidden_field_tag :kind, entry.kind, id: nil %>
  <% end %>

  <% if errors[:base].any? %>
    <div class="alert alert-error" role="alert">
      <ul class="list-disc list-inside">
        <% errors[:base].each do |message| %><li><%= message %></li><% end %>
      </ul>
    </div>
  <% end %>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-5">
      <h2 class="card-title">Details</h2>

      <fieldset class="fieldset">
        <%= form.label :name, "Name", class: "fieldset-legend" %>
        <%= form.text_field :name, required: true, maxlength: 255,
              class: field_class.call(:name, "input"),
              aria: {describedby: "ranking-name-errors"} %>
        <div id="ranking-name-errors" class="space-y-1 text-sm text-error">
          <% errors.full_messages_for(:name).each do |message| %><p role="alert"><%= message %></p><% end %>
        </div>
      </fieldset>

      <fieldset class="fieldset">
        <%= form.label :description, "Description", class: "fieldset-legend" %>
        <%= form.text_area :description, rows: 3, maxlength: 1000,
              class: "textarea w-full #{"textarea-error" if errors[:description].any?}",
              aria: {describedby: "ranking-description-help ranking-description-errors"} %>
        <p id="ranking-description-help" class="text-sm text-base-content/70">Optional. Up to 1000 characters.</p>
        <div id="ranking-description-errors" class="space-y-1 text-sm text-error">
          <% errors.full_messages_for(:description).each do |message| %><p role="alert"><%= message %></p><% end %>
        </div>
      </fieldset>

      <fieldset class="fieldset">
        <label class="label cursor-pointer justify-start gap-3">
          <%= form.check_box :user_shared, class: "checkbox", aria: {describedby: "ranking-shared-help"} %>
          <span>Share via link</span>
        </label>
        <p id="ranking-shared-help" class="text-sm text-base-content/70">
          Anyone with the link can view this ranking. Private rankings are visible only to you.
        </p>
      </fieldset>
    </div>
  </section>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-5">
      <h2 class="card-title">Settings</h2>
      <p class="text-sm text-base-content/70">
        How lists are weighed and how positions turn into scores. The official rankings' values are noted under each setting.
      </p>

      <fieldset class="fieldset">
        <%= form.label :exponent, "Position bonus curve (exponent)", class: "fieldset-legend" %>
        <%= form.number_field :exponent, min: 0.01, max: 10, step: 0.01, required: true,
              class: field_class.call(:exponent, "input"),
              aria: {describedby: "ranking-exponent-help ranking-exponent-errors"} %>
        <p id="ranking-exponent-help" class="text-sm text-base-content/70">
          How much more a #1 placement is worth than a low one. Higher values reward top spots more steeply. The official rankings use 3.
        </p>
        <div id="ranking-exponent-errors" class="space-y-1 text-sm text-error">
          <% errors.full_messages_for(:exponent).each do |message| %><p role="alert"><%= message %></p><% end %>
        </div>
      </fieldset>

      <fieldset class="fieldset">
        <%= form.label :bonus_pool_percentage, "Bonus pool (%)", class: "fieldset-legend" %>
        <%= form.number_field :bonus_pool_percentage, min: 0, max: 100, step: 0.1, required: true,
              class: field_class.call(:bonus_pool_percentage, "input"),
              aria: {describedby: "ranking-bonus-help ranking-bonus-errors"} %>
        <p id="ranking-bonus-help" class="text-sm text-base-content/70">
          The share of each list's weight set aside as a bonus for higher positions. At 0, position on a list doesn't matter. The official rankings use 3.
        </p>
        <div id="ranking-bonus-errors" class="space-y-1 text-sm text-error">
          <% errors.full_messages_for(:bonus_pool_percentage).each do |message| %><p role="alert"><%= message %></p><% end %>
        </div>
      </fieldset>

      <fieldset class="fieldset">
        <%= form.label :min_list_weight, "Lowest possible weight", class: "fieldset-legend" %>
        <%= form.number_field :min_list_weight, min: 0, max: 100, step: 1, required: true,
              class: field_class.call(:min_list_weight, "input"),
              aria: {describedby: "ranking-min-weight-help ranking-min-weight-errors"} %>
        <p id="ranking-min-weight-help" class="text-sm text-base-content/70">
          No list can fall below this weight no matter how many penalties apply. The official rankings use 0.
        </p>
        <div id="ranking-min-weight-errors" class="space-y-1 text-sm text-error">
          <% errors.full_messages_for(:min_list_weight).each do |message| %><p role="alert"><%= message %></p><% end %>
        </div>
      </fieldset>

      <fieldset class="fieldset">
        <label class="label cursor-pointer justify-start gap-3">
          <%= form.check_box :apply_list_dates_penalty, class: "checkbox", aria: {describedby: "ranking-recency-help"} %>
          <span>Recency adjustment</span>
        </label>
        <p id="ranking-recency-help" class="text-sm text-base-content/70">
          Reduce the credit a list gives to <%= noun %> published shortly before the list came out. Classics are unaffected.
        </p>
      </fieldset>

      <div class="grid gap-5 sm:grid-cols-2">
        <fieldset class="fieldset">
          <%= form.label :max_list_dates_penalty_percentage, "Maximum recency reduction (%)", class: "fieldset-legend" %>
          <%= form.number_field :max_list_dates_penalty_percentage, min: 1, max: 100, step: 1,
                class: field_class.call(:max_list_dates_penalty_percentage, "input"),
                aria: {describedby: "ranking-recency-pct-help ranking-recency-pct-errors"} %>
          <p id="ranking-recency-pct-help" class="text-sm text-base-content/70">
            How much a placement is reduced when the list and the <%= noun.singularize %> share a year. Only applies while Recency adjustment is on. The official rankings use 80.
          </p>
          <div id="ranking-recency-pct-errors" class="space-y-1 text-sm text-error">
            <% errors.full_messages_for(:max_list_dates_penalty_percentage).each do |message| %><p role="alert"><%= message %></p><% end %>
          </div>
        </fieldset>

        <fieldset class="fieldset">
          <%= form.label :max_list_dates_penalty_age, "Recency reduction fades out after (years)", class: "fieldset-legend" %>
          <%= form.number_field :max_list_dates_penalty_age, min: 1, max: 200, step: 1,
                class: field_class.call(:max_list_dates_penalty_age, "input"),
                aria: {describedby: "ranking-recency-age-help ranking-recency-age-errors"} %>
          <p id="ranking-recency-age-help" class="text-sm text-base-content/70">
            The reduction shrinks as the gap grows and disappears at this many years. Only applies while Recency adjustment is on. The official rankings use 50.
          </p>
          <div id="ranking-recency-age-errors" class="space-y-1 text-sm text-error">
            <% errors.full_messages_for(:max_list_dates_penalty_age).each do |message| %><p role="alert"><%= message %></p><% end %>
          </div>
        </fieldset>
      </div>
    </div>
  </section>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-5">
      <h2 class="card-title">Penalties</h2>
      <p class="text-sm text-base-content/70">
        Each penalty lowers the weight of the lists it applies to by the value you set (0–100%). Untick a penalty to switch it off.
      </p>

      <% penalty_groups.each do |group| %>
        <h3 class="font-semibold"><%= group.title %></h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th scope="col">On</th>
                <th scope="col">Penalty</th>
                <th scope="col" class="w-32">Value (%)</th>
              </tr>
            </thead>
            <tbody>
              <% group.rows.each do |row| %>
                <% dom = "penalty-#{row.penalty.id}" %>
                <tr>
                  <td>
                    <%= check_box_tag "penalties[#{row.penalty.id}][enabled]", "1", row.enabled,
                          id: "#{dom}-enabled", class: "checkbox", aria: {label: "Apply #{row.penalty.name}"} %>
                  </td>
                  <td>
                    <label for="<%= dom %>-value" class="font-medium"><%= row.penalty.name %></label>
                    <% if row.penalty.dynamic? %>
                      <span class="badge badge-ghost badge-sm ml-1">applied automatically</span>
                    <% end %>
                    <% if row.penalty.description.present? %>
                      <p class="text-sm text-base-content/70"><%= row.penalty.description %></p>
                    <% end %>
                  </td>
                  <td>
                    <%= number_field_tag "penalties[#{row.penalty.id}][value]", row.value,
                          id: "#{dom}-value", min: 0, max: 100, step: 1, class: "input input-sm w-24" %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
  </section>

  <% if !persisted && start == :official %>
    <section class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body gap-3">
        <h2 class="card-title">Lists</h2>
        <fieldset class="fieldset">
          <label class="label cursor-pointer justify-start gap-3">
            <%= check_box_tag :seed_lists, "1", seed_lists, class: "checkbox" %>
            <span>Start with the <%= number_with_delimiter(official_list_count) %> lists from the official rankings</span>
          </label>
          <p class="text-sm text-base-content/70">You can add and remove lists after creating.</p>
        </fieldset>
      </div>
    </section>
  <% end %>

  <div class="flex flex-wrap gap-2">
    <%= form.submit persisted ? "Save changes" : "Create ranking", class: "btn btn-primary" %>
    <%= link_to "Cancel",
          persisted ? my_ranking_configuration_path(ranking_configuration) : my_ranking_configurations_path,
          class: "btn btn-ghost" %>
  </div>
<% end %>
```

- [ ] **Step 10: Write the pages**

`app/views/my/ranking_configurations/index.html.erb`:

```erb
<% content_for :page_title, "My Rankings | #{domain_name}" %>

<div class="space-y-8">
  <%= render "my/ranking_configurations/notice" %>

  <header class="flex flex-wrap items-center justify-between gap-4">
    <div>
      <h1 class="text-3xl sm:text-4xl font-bold">My Rankings</h1>
      <p class="mt-2 text-base-content/70">Your own versions of the rankings: pick the lists, tune the settings, share the result.</p>
    </div>
    <% if @at_limit %>
      <div class="text-right">
        <button type="button" class="btn btn-primary" disabled>New ranking</button>
        <p class="mt-1 text-sm text-base-content/70">You've reached the limit of <%= RankingConfiguration::MAX_PER_USER %> rankings.</p>
      </div>
    <% else %>
      <%= link_to "New ranking", new_my_ranking_configuration_path, class: "btn btn-primary" %>
    <% end %>
  </header>

  <% if @ranking_configurations.any? %>
    <div class="grid gap-4 lg:grid-cols-2">
      <% @ranking_configurations.each do |config| %>
        <% entry = ::RankingConfigurations::Registry.for_config(config) %>
        <article class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body gap-3">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <h2 class="card-title [overflow-wrap:anywhere]">
                <%= link_to config.name, my_ranking_configuration_path(config), class: "link" %>
              </h2>
              <div class="flex gap-2">
                <span class="badge badge-outline"><%= config.user_shared? ? "Shared" : "Private" %></span>
                <%= render "my/ranking_configurations/status_badge", ranking_configuration: config %>
              </div>
            </div>
            <% if config.description.present? %>
              <p class="text-base-content/70 [overflow-wrap:anywhere]"><%= config.description %></p>
            <% end %>
            <p class="text-sm text-base-content/70">
              <% if config.last_refreshed_at %>
                Last refreshed <%= time_ago_in_words(config.last_refreshed_at) %> ago.
              <% else %>
                Not calculated yet.
              <% end %>
            </p>
            <div class="card-actions justify-end">
              <%= link_to "Manage", my_ranking_configuration_path(config), class: "btn btn-sm btn-primary" %>
              <%= link_to "View rankings", entry.results_path.call(config), class: "btn btn-sm btn-ghost" %>
            </div>
          </div>
        </article>
      <% end %>
    </div>
  <% else %>
    <div class="text-center py-16">
      <h2 class="text-2xl font-bold mb-2">No rankings yet</h2>
      <p class="text-base-content/70">Create one to build the rankings your way.</p>
    </div>
  <% end %>
</div>
```

`app/views/my/ranking_configurations/new.html.erb`:

```erb
<% content_for :page_title, "New Ranking | #{domain_name}" %>

<div class="mx-auto max-w-3xl space-y-6">
  <%= render "my/ranking_configurations/notice" %>

  <div>
    <h1 class="text-3xl sm:text-4xl font-bold">New ranking</h1>
    <% if @start == :scratch %>
      <p class="mt-2 text-base-content/70">
        Starting from scratch: default settings, no penalties, no lists.
        <%= link_to "Start from the official rankings instead", new_my_ranking_configuration_path(kind: @entry.kind), class: "link link-primary" %>.
      </p>
    <% else %>
      <p class="mt-2 text-base-content/70">
        Starting from the official rankings: their settings, penalties and lists are filled in below.
        <%= link_to "Or start from scratch", new_my_ranking_configuration_path(kind: @entry.kind, start: "scratch"), class: "link link-primary" %>.
      </p>
    <% end %>
  </div>

  <%= render "my/ranking_configurations/form",
        ranking_configuration: @ranking_configuration, entry: @entry, penalty_groups: @penalty_groups,
        start: @start, seed_lists: @seed_lists, official_list_count: @official_list_count %>
</div>
```

`app/views/my/ranking_configurations/edit.html.erb`:

```erb
<% content_for :page_title, "Edit #{@ranking_configuration.name} | #{domain_name}" %>

<div class="mx-auto max-w-3xl space-y-6">
  <%= render "my/ranking_configurations/notice" %>

  <div>
    <h1 class="text-3xl sm:text-4xl font-bold [overflow-wrap:anywhere]">Edit <%= @ranking_configuration.name %></h1>
    <p class="mt-2 text-base-content/70">Changes to settings or penalties take effect after you refresh weights and rankings.</p>
  </div>

  <%= render "my/ranking_configurations/form",
        ranking_configuration: @ranking_configuration, entry: @entry, penalty_groups: @penalty_groups,
        start: :official, seed_lists: false, official_list_count: 0 %>
</div>
```

`app/views/my/ranking_configurations/show.html.erb`:

```erb
<% content_for :page_title, "#{@ranking_configuration.name} | #{domain_name}" %>

<div class="mx-auto max-w-3xl space-y-8">
  <%= render "my/ranking_configurations/notice" %>

  <header class="space-y-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <h1 class="text-3xl sm:text-4xl font-bold [overflow-wrap:anywhere]"><%= @ranking_configuration.name %></h1>
      <span class="badge badge-outline"><%= @ranking_configuration.user_shared? ? "Shared" : "Private" %></span>
    </div>
    <% if @ranking_configuration.description.present? %>
      <p class="text-base-content/70 [overflow-wrap:anywhere]"><%= @ranking_configuration.description %></p>
    <% end %>
    <% if @ranking_configuration.user_shared? %>
      <div data-controller="clipboard-copy" class="flex flex-wrap items-center gap-2">
        <label class="sr-only" for="ranking-share-url">Share link</label>
        <%= text_field_tag nil, request.base_url + @entry.results_path.call(@ranking_configuration),
              id: "ranking-share-url", readonly: true, class: "input input-sm w-full max-w-md",
              data: {"clipboard-copy-target": "source"} %>
        <button type="button" class="btn btn-sm btn-primary" data-action="clipboard-copy#copy">Copy link</button>
      </div>
    <% end %>
  </header>

  <%= render "my/ranking_configurations/status", ranking_configuration: @ranking_configuration %>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-4">
      <div class="flex items-center justify-between">
        <h2 class="card-title">Settings and penalties</h2>
        <%= link_to "Edit", edit_my_ranking_configuration_path(@ranking_configuration), class: "btn btn-sm btn-ghost" %>
      </div>
      <dl class="grid gap-3 sm:grid-cols-2 text-sm">
        <div><dt class="text-base-content/70">Position bonus curve</dt><dd><%= @ranking_configuration.exponent.to_f %></dd></div>
        <div><dt class="text-base-content/70">Bonus pool</dt><dd><%= @ranking_configuration.bonus_pool_percentage.to_f %>%</dd></div>
        <div><dt class="text-base-content/70">Lowest possible weight</dt><dd><%= @ranking_configuration.min_list_weight %></dd></div>
        <div>
          <dt class="text-base-content/70">Recency adjustment</dt>
          <dd>
            <% if @ranking_configuration.apply_list_dates_penalty? %>
              up to <%= @ranking_configuration.max_list_dates_penalty_percentage %>%, fading out over <%= @ranking_configuration.max_list_dates_penalty_age %> years
            <% else %>
              off
            <% end %>
          </dd>
        </div>
        <div><dt class="text-base-content/70">Penalties on</dt><dd><%= @penalties_on %> of <%= @penalties_total %></dd></div>
      </dl>
    </div>
  </section>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-4">
      <div class="flex items-center justify-between">
        <h2 class="card-title">Lists</h2>
        <%= link_to "Manage lists", my_ranking_configuration_lists_path(@ranking_configuration), class: "btn btn-sm btn-ghost" %>
      </div>
      <p class="text-sm">This ranking is built from <%= pluralize(number_with_delimiter(@lists_count), "list") %>.</p>
    </div>
  </section>

  <div class="flex flex-wrap items-center gap-2">
    <%= link_to "View rankings", @entry.results_path.call(@ranking_configuration), class: "btn btn-primary" %>
    <%= link_to "Back to my rankings", my_ranking_configurations_path, class: "btn btn-ghost" %>
    <%= button_to "Delete", my_ranking_configuration_path(@ranking_configuration), method: :delete,
          class: "btn btn-error btn-outline ml-auto",
          form: {data: {turbo_confirm: "Delete this ranking? This cannot be undone."}} %>
  </div>
</div>
```

`app/views/my/ranking_configurations/choose_kind.html.erb` (only rendered on a domain with more than one entry — dead on books until music is switched on):

```erb
<% content_for :page_title, "New Ranking | #{domain_name}" %>

<div class="mx-auto max-w-2xl space-y-6">
  <h1 class="text-3xl sm:text-4xl font-bold">New ranking</h1>
  <p class="text-base-content/70">Which ranking do you want to build your own version of?</p>
  <ul class="menu bg-base-100 border border-base-300 rounded-box w-full">
    <% @entries.each do |entry| %>
      <li>
        <%= link_to entry.ranking_configuration_class.constantize.new.media_noun_plural.capitalize,
              new_my_ranking_configuration_path(kind: entry.kind) %>
      </li>
    <% end %>
  </ul>
</div>
```

- [ ] **Step 11: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/my/ranking_configurations_controller_test.rb test/routing/my_ranking_configurations_routes_test.rb test/lint`
Expected: green, including the DaisyUI v4-class lint and the Stimulus manifest lint (`clipboard-copy` is already registered in `books_web.js`).

If "show renders for the owner" fails with a missing route for `my_ranking_configuration_lists_path`, re-check Step 1 — the lists routes are declared now, ahead of the controller Task 12 creates.

- [ ] **Step 12: Boot it once**

```bash
yarn build:all && bin/rails server -p 3000
```

(Confirm port 3000 is yours first per AGENTS.md.) Sign in on `https://dev-new.thegreatestbooks.org`, open `/my/rankings`, click New ranking, submit with defaults, confirm the redirect to the manage page and that `/rc/<id>` renders. Stop the server.

- [ ] **Step 13: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers config/routes.rb test/controllers/my test/routing
git add config/routes.rb app/controllers/concerns/ranking_configuration_owner_scoped.rb app/controllers/my app/views/my test/controllers/my test/routing/my_ranking_configurations_routes_test.rb
git commit -m "feat(rankings): /my/rankings — create, edit, view and delete your own ranking

Global routes resolved from Current.domain; owner-only; the new form
starts from the official configuration or from scratch.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 11: Refresh, daily cap, state endpoint, polling

**Spec:** §7 (throttle), §8.4 (status panel, polling), §2 #2.

**Files:**
- Modify: `app/controllers/my/ranking_configurations_controller.rb`
- Modify: `app/views/my/ranking_configurations/_status.html.erb`
- Create: `app/javascript/controllers/ranking_configuration_status_controller.js`
- Modify: `app/javascript/manifests/books_web.js`
- Test: `test/controllers/my/ranking_configurations_controller_test.rb`

**Interfaces:**
- Consumes: `RankingConfiguration#request_refresh!`, `#refresh_claimable?` (Tasks 1, 4).
- Produces: `POST /my/rankings/:id/refresh` (303 to show with `notice` or `alert`), `GET /my/rankings/:id/state` → `{refresh_status, needs_refresh, last_refreshed_at, last_refresh_error}`; constants `My::RankingConfigurationsController::REFRESH_LIMIT` (5), `REFRESH_WINDOW` (24.hours); Stimulus `ranking-configuration-status` with values `url` (String) and `active` (Boolean).

- [ ] **Step 1: Write the failing tests**

Append inside the class in `test/controllers/my/ranking_configurations_controller_test.rb`:

```ruby
  # --- refresh (spec §7) ---

  test "refresh claims the lock, enqueues the job and redirects with a notice" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      post refresh_my_ranking_configuration_path(@config)
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end

    assert_redirected_to my_ranking_configuration_path(@config)
    assert flash[:notice].present?
    assert @config.reload.refresh_queued?
  end

  test "refresh is rejected while a run is in progress and does not spend the daily allowance" do
    @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running], refresh_requested_at: Time.current)
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      (My::RankingConfigurationsController::REFRESH_LIMIT + 2).times do
        post refresh_my_ranking_configuration_path(@config)
        assert_redirected_to my_ranking_configuration_path(@config)
        assert flash[:alert].present?
      end
      assert_empty RankingConfigurations::RefreshJob.jobs
      assert @config.reload.refresh_running?

      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      post refresh_my_ranking_configuration_path(@config)
      assert flash[:notice].present?, "the rejected clicks did not count against the limit"
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end
  end

  test "refresh reclaims a run abandoned longer than the stale window" do
    @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running],
      refresh_requested_at: (RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago)
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      post refresh_my_ranking_configuration_path(@config)
      assert_equal 1, RankingConfigurations::RefreshJob.jobs.size
    end
    assert flash[:notice].present?
    assert @config.reload.refresh_queued?
  end

  test "the sixth refresh in a day is limited and claims nothing" do
    sign_in_as @owner, stub_auth: true

    with_fake_sidekiq do
      My::RankingConfigurationsController::REFRESH_LIMIT.times do
        @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
        post refresh_my_ranking_configuration_path(@config)
        assert flash[:notice].present?
      end

      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      post refresh_my_ranking_configuration_path(@config)

      assert_redirected_to my_ranking_configuration_path(@config)
      assert flash[:alert].present?
      assert @config.reload.refresh_idle?
      assert_equal My::RankingConfigurationsController::REFRESH_LIMIT, RankingConfigurations::RefreshJob.jobs.size
    end
  end

  test "the daily limit is per user" do
    sign_in_as @owner, stub_auth: true
    with_fake_sidekiq do
      My::RankingConfigurationsController::REFRESH_LIMIT.times do
        @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
        post refresh_my_ranking_configuration_path(@config)
      end
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      post refresh_my_ranking_configuration_path(@config)
      assert flash[:alert].present?

      other_config = Books::RankingConfiguration.create!(name: "Theirs", global: false, user: @stranger, min_list_weight: 0)
      sign_in_as @stranger, stub_auth: true
      post refresh_my_ranking_configuration_path(other_config)
      assert flash[:notice].present?
      assert other_config.reload.refresh_queued?
    end
  end

  test "a non-owner cannot refresh" do
    sign_in_as @stranger, stub_auth: true

    with_fake_sidekiq do
      post refresh_my_ranking_configuration_path(@config)
      assert_response :not_found
      assert_empty RankingConfigurations::RefreshJob.jobs
    end
  end

  # --- state ---

  test "state returns the refresh state as JSON for the owner" do
    @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:failed],
      needs_refresh: true, last_refresh_error: "boom")
    sign_in_as @owner, stub_auth: true

    get state_my_ranking_configuration_path(@config), as: :json

    assert_response :success
    assert_match "no-store", response.headers["Cache-Control"].to_s
    body = response.parsed_body
    assert_equal "failed", body["refresh_status"]
    assert_equal true, body["needs_refresh"]
    assert_equal "boom", body["last_refresh_error"]
    assert_nil body["last_refreshed_at"]
  end

  test "state is 401 anonymous and 404 for a non-owner" do
    get state_my_ranking_configuration_path(@config), as: :json
    assert_response :unauthorized

    sign_in_as @stranger, stub_auth: true
    get state_my_ranking_configuration_path(@config), as: :json
    assert_response :not_found
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/my/ranking_configurations_controller_test.rb`
Expected: the new tests fail with `ActionNotFound` for `refresh`/`state`.

- [ ] **Step 3: Add the actions and the throttle**

In `app/controllers/my/ranking_configurations_controller.rb`:

Add constants after the `include` lines:

```ruby
  REFRESH_LIMIT = 5
  REFRESH_WINDOW = 24.hours
```

Change the `set_ranking_configuration` before_action to include the two new actions, then add the pre-check and the rate limit **after** it (filters run in declaration order — an anonymous request or a click during a run must never reach the counter):

```ruby
  before_action :set_ranking_configuration, only: [:show, :edit, :update, :destroy, :refresh, :state]
  before_action :reject_refresh_in_progress, only: :refresh

  # Five manual refreshes per user per rolling day. Declared after the two
  # filters above so a click during a run is rejected before it counts, and
  # keyed by user id, never request.remote_ip (the Cloudflare edge IP). with:
  # is required: Rails' default raises and renders an HTML error body.
  rate_limit to: REFRESH_LIMIT, within: REFRESH_WINDOW,
    by: -> { current_user.id },
    with: -> { refresh_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "ranking-configuration-refresh",
    only: :refresh
```

Add the actions after `destroy`:

```ruby
  def refresh
    if @ranking_configuration.request_refresh!
      redirect_to my_ranking_configuration_path(@ranking_configuration),
        notice: "Refresh started. This usually takes a few minutes.", status: :see_other
    else
      refresh_already_running
    end
  end

  def state
    render json: {
      refresh_status: @ranking_configuration.refresh_status,
      needs_refresh: @ranking_configuration.needs_refresh?,
      last_refreshed_at: @ranking_configuration.last_refreshed_at&.iso8601,
      last_refresh_error: @ranking_configuration.last_refresh_error
    }
  end
```

Add private methods:

```ruby
  def reject_refresh_in_progress
    refresh_already_running unless @ranking_configuration.refresh_claimable?
  end

  def refresh_already_running
    redirect_to my_ranking_configuration_path(@ranking_configuration),
      alert: "A refresh is already running for this ranking.", status: :see_other
  end

  def refresh_limited
    redirect_to my_ranking_configuration_path(@ranking_configuration),
      alert: "You've used all #{REFRESH_LIMIT} refreshes for today. Try again later.", status: :see_other
  end
```

- [ ] **Step 4: Run the controller tests**

Run: `bin/rails test test/controllers/my/ranking_configurations_controller_test.rb`
Expected: green. (`test_helper.rb` clears the rate-limit store before every test, so the per-test counts start at zero.)

- [ ] **Step 5: Add the Refresh button and polling to the status panel**

Replace `app/views/my/ranking_configurations/_status.html.erb` with:

```erb
<% config = ranking_configuration %>
<section id="ranking-status" class="card bg-base-100 border border-base-300 shadow-sm"
         data-controller="ranking-configuration-status"
         data-ranking-configuration-status-url-value="<%= state_my_ranking_configuration_path(config) %>"
         data-ranking-configuration-status-active-value="<%= config.refresh_in_progress? %>">
  <div class="card-body gap-3">
    <div class="flex flex-wrap items-center gap-3">
      <h2 class="card-title">Status</h2>
      <%= render "my/ranking_configurations/status_badge", ranking_configuration: config %>
    </div>

    <% if config.refresh_in_progress? %>
      <p>Calculating weights and rankings. This usually takes a few minutes — this page will update when it's done.</p>
    <% elsif config.refresh_failed? %>
      <p class="[overflow-wrap:anywhere]">The last refresh failed<% if config.last_refresh_error.present? %>: <%= config.last_refresh_error %><% end %>. You can try again.</p>
    <% elsif config.needs_refresh? %>
      <p>Your changes haven't been applied yet. Refresh weights and rankings to see them.</p>
    <% else %>
      <p>Up to date<% if config.last_refreshed_at %> — last refreshed <%= time_ago_in_words(config.last_refreshed_at) %> ago<% end %>.</p>
    <% end %>

    <div>
      <%= button_to "Refresh weights and rankings", refresh_my_ranking_configuration_path(config), method: :post,
            class: "btn btn-primary btn-sm", disabled: config.refresh_in_progress?,
            data: {turbo_submits_with: "Starting…"} %>
      <p class="mt-2 text-xs text-base-content/70">
        Up to <%= My::RankingConfigurationsController::REFRESH_LIMIT %> refreshes a day. The first calculation after creating a ranking doesn't count.
      </p>
    </div>
  </div>
</section>
```

- [ ] **Step 6: Create the Stimulus controller and register it**

Create `app/javascript/controllers/ranking_configuration_status_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

const POLL_MS = 5000
const IN_PROGRESS = ["queued", "running"]

// Connects to data-controller="ranking-configuration-status".
//
// While a refresh is queued or running, asks the owner-only state endpoint
// every few seconds and reloads the page once the run has finished, so the
// status panel, badge and Refresh button re-render from the server. The page
// is complete without this -- a failed poll just tries again.
export default class extends Controller {
  static values = { url: String, active: Boolean }

  connect() {
    if (!this.activeValue || !this.hasUrlValue) return
    this.timer = setInterval(() => this.poll(), POLL_MS)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    try {
      const response = await fetch(this.urlValue, {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
      if (!response.ok) return

      const data = await response.json()
      if (IN_PROGRESS.includes(data.refresh_status)) return

      clearInterval(this.timer)
      window.Turbo.visit(window.location.href, { action: "replace" })
    } catch {
      // Keep polling on a transient failure.
    }
  }
}
```

Append to `app/javascript/manifests/books_web.js`:

```js
import RankingConfigurationStatusController from "../controllers/ranking_configuration_status_controller"
application.register("ranking-configuration-status", RankingConfigurationStatusController)
```

- [ ] **Step 7: Build, lint, run the controller and lint tests**

Run: `yarn build:all && bin/rails test test/controllers/my test/lint`
Expected: the Rollup build succeeds; the Stimulus manifest lint sees `ranking-configuration-status` both registered and referenced; green.

- [ ] **Step 8: Try it in the browser**

Start `bin/rails server` (port check first) **and** `bundle exec sidekiq -C config/sidekiq.yml` in another terminal, open a configuration's manage page, click Refresh, and watch the badge go Calculating → Up to date without a manual reload. Stop both.

- [ ] **Step 9: Commit**

```bash
bundle exec standardrb --fix app/controllers/my test/controllers/my
git add app/controllers/my/ranking_configurations_controller.rb app/views/my/ranking_configurations/_status.html.erb app/javascript/controllers/ranking_configuration_status_controller.js app/javascript/manifests/books_web.js test/controllers/my
git commit -m "feat(rankings): on-demand refresh with a per-user daily cap and live status

Five per user per rolling day via rate_limit; a click during a run is
rejected before it counts; the manage page polls until the run ends.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 12: Lists page — search, add, remove, add-missing

**Spec:** §8.5.

**Files:**
- Create: `app/controllers/my/ranking_configurations/lists_controller.rb` (generator)
- Create: `app/views/my/ranking_configurations/lists/index.html.erb`, `_frame.html.erb`
- Test: `test/controllers/my/ranking_configurations/lists_controller_test.rb`

**Interfaces:**
- Consumes: `AddLists` (Task 8), `MissingListsQuery` (Task 5), `List#name_with_source` (Task 5), `RankingConfigurationOwnerScoped#set_ranking_configuration(:manage_lists?)` (Task 10), route helpers (Task 10), `saved_search_picker_controller.js` (already registered in `books_web.js`; contract: `url-value` → JSON `[{value, text}]`, `name-value` → hidden input name).
- Produces: `My::RankingConfigurations::ListsController` with `index`, `search` (JSON), `create`, `add_missing`, `destroy`; constants `PER_PAGE` (50), `SEARCH_LIMIT` (10). `create`/`add_missing`/`destroy` answer a Turbo Stream request by replacing the `rc_lists` frame and an HTML request with a 303 to the lists page.

- [ ] **Step 1: Generate the controller**

```bash
bin/rails generate controller my/ranking_configurations/lists --skip-routes --no-helper
```

Expected: `app/controllers/my/ranking_configurations/lists_controller.rb`, `test/controllers/my/ranking_configurations/lists_controller_test.rb`. Delete any helper/asset file it adds.

- [ ] **Step 2: Write the failing tests**

Replace `test/controllers/my/ranking_configurations/lists_controller_test.rb` with:

```ruby
require "test_helper"

class My::RankingConfigurations::ListsControllerTest < ActionDispatch::IntegrationTest
  TURBO = {"Accept" => "text/vnd.turbo-stream.html"}.freeze

  setup do
    host! Rails.application.config.domains[:books]
    @owner = users(:regular_user)
    @stranger = users(:editor_user)
    @config = ranking_configurations(:books_user)
    @primary = ranking_configurations(:books_global)
    @config.update_columns(needs_refresh: false)
    @official = Books::List.create!(name: "Official Only", source: "Guardian", year_published: 2003, status: :active)
    @mine = Books::List.create!(name: "Mine Already", source: "Time", status: :active)
    @other = Books::List.create!(name: "Unattached Active", source: "NYT", status: :active)
    @approved = Books::List.create!(name: "Approved Not Active", source: "NYT", status: :approved)
    RankedList.create!(list: @official, ranking_configuration: @primary, weight: 70)
    RankedList.create!(list: @mine, ranking_configuration: @config, weight: 55)
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      count += 1 unless ["SCHEMA", "TRANSACTION"].include?(payload[:name])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- index ---

  test "index requires sign-in and the owner" do
    get my_ranking_configuration_lists_path(@config)
    assert_redirected_to "/"

    sign_in_as @stranger, stub_auth: true
    get my_ranking_configuration_lists_path(@config)
    assert_response :not_found
  end

  test "index renders the owner's lists and the diff against the official ranking, uncached" do
    sign_in_as @owner, stub_auth: true

    get my_ranking_configuration_lists_path(@config)

    assert_response :success
    assert_match "no-store", response.headers["Cache-Control"].to_s
    assert_equal [@mine.id], @controller.view_assigns["ranked_lists"].map(&:list_id)
    assert_equal [@official.id], @controller.view_assigns["missing"].map(&:list_id)
  end

  test "index has no frame-trapped links" do
    sign_in_as @owner, stub_auth: true
    assert_no_frame_trapped_links my_ranking_configuration_lists_path(@config)
  end

  test "the lists page runs a bounded number of queries regardless of list count" do
    sign_in_as @owner, stub_auth: true
    baseline = count_queries { get my_ranking_configuration_lists_path(@config) }

    4.times { |i| @config.ranked_lists.create!(list: Books::List.create!(name: "Bulk #{i}", source: "T", status: :active)) }
    4.times { |i| RankedList.create!(list: Books::List.create!(name: "Missing #{i}", source: "T", status: :active), ranking_configuration: @primary, weight: i) }
    grown = count_queries { get my_ranking_configuration_lists_path(@config) }

    assert_equal baseline, grown, "query count grew with the number of lists (N+1)"
  end

  # --- search ---

  test "search returns active lists of the domain's type not already in the configuration" do
    sign_in_as @owner, stub_auth: true

    get search_my_ranking_configuration_lists_path(@config, q: "NYT"), as: :json
    assert_response :success
    values = response.parsed_body.map { |row| row["value"] }
    assert_includes values, @other.id
    refute_includes values, @approved.id
    refute_includes values, lists(:games_list).id

    get search_my_ranking_configuration_lists_path(@config, q: "Mine Already"), as: :json
    assert_empty response.parsed_body, "lists already in the configuration are excluded"

    get search_my_ranking_configuration_lists_path(@config, q: ""), as: :json
    assert_empty response.parsed_body
  end

  test "search rows carry the list id and its display name" do
    sign_in_as @owner, stub_auth: true

    get search_my_ranking_configuration_lists_path(@config, q: "Official Only"), as: :json

    row = response.parsed_body.first
    assert_equal @official.id, row["value"]
    assert_equal @official.name_with_source, row["text"]
  end

  test "search is owner-only" do
    sign_in_as @stranger, stub_auth: true
    get search_my_ranking_configuration_lists_path(@config, q: "NYT"), as: :json
    assert_response :not_found
  end

  # --- create / add_missing / destroy ---

  test "create adds the posted active lists, marks stale and replaces the frame" do
    sign_in_as @owner, stub_auth: true

    post my_ranking_configuration_lists_path(@config), params: {list_ids: [@other.id, @approved.id], page: 1}, headers: TURBO

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, 'target="rc_lists"'
    assert_equal [@mine.id, @other.id].sort, @config.ranked_lists.pluck(:list_id).sort
    assert @config.reload.needs_refresh?
  end

  test "create without a Turbo Stream accept redirects back to the lists page" do
    sign_in_as @owner, stub_auth: true

    post my_ranking_configuration_lists_path(@config), params: {list_ids: [@other.id]}

    assert_redirected_to my_ranking_configuration_lists_path(@config, page: 1)
  end

  test "add_missing adds every official list the configuration lacks" do
    sign_in_as @owner, stub_auth: true

    post add_missing_my_ranking_configuration_lists_path(@config), headers: TURBO

    assert_response :success
    assert_includes @config.ranked_lists.pluck(:list_id), @official.id
    assert_empty @controller.view_assigns["missing"]
    assert @config.reload.needs_refresh?
  end

  test "destroy removes the list, marks stale and the list reappears in the diff" do
    sign_in_as @owner, stub_auth: true
    RankedList.create!(list: @mine, ranking_configuration: @primary, weight: 10)

    delete my_ranking_configuration_list_path(@config, @mine.id), headers: TURBO

    assert_response :success
    assert_empty @config.ranked_lists
    assert @config.reload.needs_refresh?
    assert_includes @controller.view_assigns["missing"].map(&:list_id), @mine.id
  end

  test "destroy 404s for a list that is not in the configuration" do
    sign_in_as @owner, stub_auth: true
    delete my_ranking_configuration_list_path(@config, @other.id), headers: TURBO
    assert_response :not_found
  end

  test "a page past the end is clamped after a removal" do
    sign_in_as @owner, stub_auth: true

    delete my_ranking_configuration_list_path(@config, @mine.id), params: {page: 9}, headers: TURBO

    assert_response :success
    assert_equal 1, @controller.view_assigns["pagy"].page
  end

  test "a non-owner cannot add or remove lists" do
    sign_in_as @stranger, stub_auth: true

    post my_ranking_configuration_lists_path(@config), params: {list_ids: [@other.id]}, headers: TURBO
    assert_response :not_found
    delete my_ranking_configuration_list_path(@config, @mine.id), headers: TURBO
    assert_response :not_found

    assert_equal [@mine.id], @config.ranked_lists.pluck(:list_id)
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/controllers/my/ranking_configurations/lists_controller_test.rb`
Expected: `ActionNotFound` / missing template failures.

- [ ] **Step 4: Write the controller**

Replace `app/controllers/my/ranking_configurations/lists_controller.rb` with:

```ruby
# The lists page of a user-owned ranking configuration: search-and-add,
# the diff against the official ranking, and the paginated list of what is
# in it. Every mutation answers a Turbo Stream request by re-rendering the
# rc_lists frame (the Admin::RankedListsController shape) and a plain
# request with a redirect back here.
class My::RankingConfigurations::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include DomainLayout
  include RankingConfigurationOwnerScoped

  PER_PAGE = 50
  SEARCH_LIMIT = 10

  layout :resolve_layout

  before_action :prevent_caching
  before_action :require_domain_support!
  before_action :require_signed_in!
  before_action { set_ranking_configuration(:manage_lists?) }

  def index
    load_frame
  end

  # JSON for the picker: active lists of this domain's type matching the
  # query, minus the ones already in the configuration.
  def search
    query = params[:q].is_a?(String) ? params[:q].strip : ""
    return render json: [] if query.blank?

    lists = current_entry.list_class.constantize
      .where(status: :active)
      .search_text(query)
      .where.not(id: @ranking_configuration.ranked_lists.select(:list_id))
      .order(:name)
      .limit(SEARCH_LIMIT)

    render json: lists.map { |list| {value: list.id, text: list.name_with_source} }
  end

  def create
    result = Services::RankingConfigurations::AddLists.call(
      config: @ranking_configuration, entry: current_entry, list_ids: params[:list_ids]
    )
    @frame_notice = "Added #{helpers.pluralize(result.data[:added], "list")}. Refresh weights and rankings to apply."
    respond_with_frame
  end

  def add_missing
    missing_ids = ::RankingConfigurations::MissingListsQuery.call(
      config: @ranking_configuration, entry: current_entry
    ).pluck(:list_id)
    result = Services::RankingConfigurations::AddLists.call(
      config: @ranking_configuration, entry: current_entry, list_ids: missing_ids
    )
    @frame_notice = "Added #{helpers.pluralize(result.data[:added], "list")} from the official rankings. Refresh weights and rankings to apply."
    respond_with_frame
  end

  def destroy
    ranked_list = @ranking_configuration.ranked_lists.find_by!(list_id: params[:list_id])
    name = ranked_list.list.name
    ranked_list.destroy
    @ranking_configuration.update!(needs_refresh: true)
    @frame_notice = "Removed #{name}. Refresh weights and rankings to apply."
    respond_with_frame
  end

  private

  def load_frame
    @missing = ::RankingConfigurations::MissingListsQuery.call(config: @ranking_configuration, entry: current_entry).to_a
    scope = @ranking_configuration.ranked_lists
      .includes(:list)
      .order(Arel.sql("ranked_lists.weight DESC NULLS LAST, ranked_lists.id ASC"))
    @pagy, @ranked_lists = pagy(scope, limit: PER_PAGE, page: clamped_page(scope))
  end

  # After a removal the requested page can lie past the end; clamp rather
  # than let Pagy raise or render an empty page.
  def clamped_page(scope)
    last = [(scope.count - 1) / PER_PAGE + 1, 1].max
    [[params[:page].to_i, 1].max, last].min
  end

  def respond_with_frame
    load_frame
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("rc_lists", partial: "my/ranking_configurations/lists/frame")
      end
      format.html do
        redirect_to my_ranking_configuration_lists_path(@ranking_configuration, page: @pagy.page), status: :see_other
      end
    end
  end
end
```

If `pagy(scope, page: n)` raises `ArgumentError` on this Pagy version, check `Pagy::DEFAULT.keys` / the `pagy` signature in `bundle open pagy` — Pagy 43 reads `:page` from the options hash; older 9.x read it the same way. Do not fall back to `params[:page]` — the clamp is the point.

- [ ] **Step 5: Write the views**

`app/views/my/ranking_configurations/lists/index.html.erb`:

```erb
<% content_for :page_title, "Lists — #{@ranking_configuration.name} | #{domain_name}" %>

<div class="mx-auto max-w-4xl space-y-6">
  <%= render "my/ranking_configurations/notice" %>

  <div>
    <p class="text-sm">
      <%= link_to "← #{@ranking_configuration.name}", my_ranking_configuration_path(@ranking_configuration), class: "link [overflow-wrap:anywhere]" %>
    </p>
    <h1 class="text-3xl sm:text-4xl font-bold">Lists</h1>
    <p class="mt-2 text-base-content/70">
      Choose which lists feed this ranking. Only active lists count, and changes take effect after a refresh.
    </p>
  </div>

  <%= render "my/ranking_configurations/lists/frame" %>
</div>
```

`app/views/my/ranking_configurations/lists/_frame.html.erb` (reads the controller's ivars; rendered by `index` and by every Turbo Stream reply):

```erb
<%
  config = @ranking_configuration
  entry = current_entry
  page = @pagy.page
  list_detail = ->(list) { [list.source.presence, list.year_published].compact.join(", ") }
%>
<%# target: "_top" releases every link (list names go to public pages); the
    forms that must stay in the frame opt back in with data-turbo-frame, and
    pagination via series_nav's anchor_string. %>
<%= turbo_frame_tag "rc_lists", target: "_top", class: "block space-y-8" do %>
  <% if @frame_notice.present? %>
    <div class="alert alert-success" role="status"><span><%= @frame_notice %></span></div>
  <% end %>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-3">
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="card-title">Status</h2>
        <%= render "my/ranking_configurations/status_badge", ranking_configuration: config %>
        <span class="text-sm text-base-content/70">Your ranking has <%= pluralize(number_with_delimiter(@pagy.count), "list") %>.</span>
      </div>
      <%# Deliberately NOT opted into the frame: this navigates to the manage
          page, where the status panel and polling live. %>
      <div>
        <%= button_to "Refresh weights and rankings", refresh_my_ranking_configuration_path(config), method: :post,
              class: "btn btn-primary btn-sm", disabled: config.refresh_in_progress? %>
      </div>
    </div>
  </section>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-4">
      <h2 class="card-title">Add lists</h2>
      <%= form_with url: my_ranking_configuration_lists_path(config), method: :post,
            data: {turbo_frame: "rc_lists"}, class: "space-y-3" do |form| %>
        <%= hidden_field_tag :page, page, id: nil %>
        <fieldset class="fieldset" data-controller="saved-search-picker"
                  data-saved-search-picker-url-value="<%= search_my_ranking_configuration_lists_path(config) %>"
                  data-saved-search-picker-name-value="list_ids[]">
          <legend class="fieldset-legend">Search lists</legend>
          <div class="relative">
            <input type="search" class="input w-full" placeholder="Search by list name or source"
                   aria-label="Search lists" autocomplete="off"
                   data-saved-search-picker-target="query"
                   data-action="input->saved-search-picker#search keydown->saved-search-picker#suppressEnter">
            <div class="hidden absolute dropdown-content p-2 shadow-lg bg-base-100 rounded-box w-full mt-1 max-h-80 overflow-y-auto z-[9999] left-0 top-full flex flex-col gap-1"
                 data-saved-search-picker-target="results"></div>
          </div>
          <div class="flex flex-wrap gap-2 mt-2" data-saved-search-picker-target="chips"></div>
        </fieldset>
        <%= form.submit "Add selected lists", class: "btn btn-primary btn-sm" %>
      <% end %>
    </div>
  </section>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="card-title">In the official rankings but not in yours (<%= number_with_delimiter(@missing.size) %>)</h2>
        <% if @missing.any? %>
          <%= button_to "Add all #{number_with_delimiter(@missing.size)}", add_missing_my_ranking_configuration_lists_path(config),
                method: :post, params: {page: page}, class: "btn btn-sm btn-secondary",
                form: {data: {turbo_frame: "rc_lists"}} %>
        <% end %>
      </div>
      <% if @missing.any? %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr><th scope="col">List</th><th scope="col">Official weight</th><th scope="col"><span class="sr-only">Add</span></th></tr>
            </thead>
            <tbody>
              <% @missing.each do |ranked_list| %>
                <tr id="missing-list-<%= ranked_list.list_id %>">
                  <td class="[overflow-wrap:anywhere]">
                    <%= link_to ranked_list.list.name, entry.list_path.call(ranked_list.list), class: "link" %>
                    <% detail = list_detail.call(ranked_list.list) %>
                    <% if detail.present? %><span class="text-sm text-base-content/70">(<%= detail %>)</span><% end %>
                  </td>
                  <td><%= ranked_list.weight.presence || "—" %></td>
                  <td>
                    <%= button_to "Add", my_ranking_configuration_lists_path(config), method: :post,
                          params: {list_ids: [ranked_list.list_id], page: page}, class: "btn btn-xs btn-primary",
                          form: {data: {turbo_frame: "rc_lists"}} %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-sm text-base-content/70">Your ranking includes every official list.</p>
      <% end %>
    </div>
  </section>

  <section class="card bg-base-100 border border-base-300 shadow-sm">
    <div class="card-body gap-4">
      <h2 class="card-title">Your lists (<%= number_with_delimiter(@pagy.count) %>)</h2>
      <% if @ranked_lists.any? %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr><th scope="col">List</th><th scope="col">Weight</th><th scope="col"><span class="sr-only">Remove</span></th></tr>
            </thead>
            <tbody>
              <% @ranked_lists.each do |ranked_list| %>
                <tr id="ranked-list-<%= ranked_list.list_id %>">
                  <td class="[overflow-wrap:anywhere]">
                    <%= link_to ranked_list.list.name, entry.list_path.call(ranked_list.list), class: "link" %>
                    <% detail = list_detail.call(ranked_list.list) %>
                    <% if detail.present? %><span class="text-sm text-base-content/70">(<%= detail %>)</span><% end %>
                  </td>
                  <td><%= ranked_list.weight.presence || "not yet calculated" %></td>
                  <td>
                    <%= button_to "Remove", my_ranking_configuration_list_path(config, ranked_list.list_id), method: :delete,
                          params: {page: page}, class: "btn btn-xs btn-ghost",
                          form: {data: {turbo_frame: "rc_lists", turbo_confirm: "Remove #{ranked_list.list.name} from your ranking?"}} %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <% if @pagy.pages > 1 %>
          <div class="flex justify-center py-2">
            <%== @pagy.series_nav(anchor_string: 'data-turbo-frame="rc_lists"') %>
          </div>
        <% end %>
      <% else %>
        <p class="text-sm text-base-content/70">No lists yet. Search above or add the official lists.</p>
      <% end %>
    </div>
  </section>
<% end %>
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/controllers/my test/lint`
Expected: green. If `assert_no_frame_trapped_links` reports a trapped link, the frame's `target: "_top"` did not render — check `turbo_frame_tag "rc_lists", target: "_top"` emits `<turbo-frame id="rc_lists" target="_top">`.

- [ ] **Step 7: Try it in the browser**

`yarn build:all && bin/rails server` (port check first). Open a configuration's lists page: type a list name, pick a result, click "Add selected lists" — the frame re-renders with the notice and the new row, and the URL does not change. Click a diff row's Add, then Remove something (confirm dialog). Stop the server.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/my test/controllers/my
git add app/controllers/my/ranking_configurations/lists_controller.rb app/views/my/ranking_configurations/lists test/controllers/my/ranking_configurations
git commit -m "feat(rankings): manage the lists in your own ranking

Search-and-add, the diff against the official ranking with one-click
and add-all, and removal, all inside one Turbo Frame.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 13: Custom-ranking banner and the nav link

**Spec:** §9 (banner), §8.6 (nav).

**Files:**
- Create: `app/views/shared/_custom_ranking_banner.html.erb`
- Modify: `app/views/layouts/books/application.html.erb:114-116`
- Modify: `app/views/books/shared/_nav_links.html.erb` (both `#navbar_my_books` lists)
- Test: `test/controllers/books/ranked_items_controller_test.rb`

**Interfaces:**
- Consumes: `@custom_ranking_configuration` (Task 2), `Registry.for_config(...).official_rankings_path` (Task 5), `my_ranking_configurations_path` (Task 10).

- [ ] **Step 1: Write the failing tests**

Append inside the class in `test/controllers/books/ranked_items_controller_test.rb`:

```ruby
    test "a shared user-owned configuration's page carries the custom-ranking banner" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}"

      assert_select "#custom-ranking-banner", count: 1
      assert_select "#custom-ranking-banner a[href=?]", "/"
    end

    test "a global configuration's page carries no custom-ranking banner" do
      get "/"
      assert_select "#custom-ranking-banner", count: 0
    end

    test "the books nav links to My Rankings" do
      get "/"
      assert_select "#navbar_my_books a[href=?]", "/my/rankings", minimum: 1
    end
```

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb`
Expected: the three new tests fail.

- [ ] **Step 2: Create the banner partial**

`app/views/shared/_custom_ranking_banner.html.erb`:

```erb
<%# Shown on every page under /rc/ for a user-owned configuration. Name only,
    never the owner (spec §2 #6). The layout renders this when
    RankingConfigurationGating set @custom_ranking_configuration. %>
<%
  entry = ::RankingConfigurations::Registry.for_config(ranking_configuration)
  official_path = entry ? entry.official_rankings_path.call : "/"
%>
<div id="custom-ranking-banner" class="alert alert-info mb-6" role="status">
  <span class="[overflow-wrap:anywhere]">
    You're viewing a custom ranking: <strong><%= ranking_configuration.name %></strong>.
    <%= link_to "See the official rankings →", official_path, class: "link font-medium" %>
  </span>
</div>
```

- [ ] **Step 3: Render it from the books layout**

In `app/views/layouts/books/application.html.erb`, change

```erb
        <main id="main" class="container mx-auto px-4 py-8 scroll-mt-20">
          <%= yield %>
        </main>
```

to

```erb
        <main id="main" class="container mx-auto px-4 py-8 scroll-mt-20">
          <% if @custom_ranking_configuration %>
            <%= render "shared/custom_ranking_banner", ranking_configuration: @custom_ranking_configuration %>
          <% end %>
          <%= yield %>
        </main>
```

- [ ] **Step 4: Add the nav link**

In `app/views/books/shared/_nav_links.html.erb`, in **both** `#navbar_my_books` `<ul>`s, add after the Reading Goals line:

```erb
        <li><%= link_to "My Rankings", my_ranking_configurations_path %></li>
```

(Indent to match each list.)

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb test/controllers/books/lists_controller_test.rb test/controllers/books/books_controller_test.rb test/controllers/books/authors_controller_test.rb`
Expected: green — the banner appears on every `/rc/` page for a shared configuration because the gating concern sets the ivar in every resolver.

- [ ] **Step 6: Commit**

```bash
git add app/views/shared/_custom_ranking_banner.html.erb app/views/layouts/books/application.html.erb app/views/books/shared/_nav_links.html.erb test/controllers/books/ranked_items_controller_test.rb
git commit -m "feat(rankings): custom-ranking banner on /rc/ pages and a My Rankings nav link

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

### Task 14: Playwright E2E and the feature doc

**Spec:** §12 (E2E), §14.

**Files:**
- Create: `e2e/tests/books/account/ranking-configurations.spec.ts`
- Create: `docs/features/user-ranking-configurations.md` (repo root `docs/`)

- [ ] **Step 1: Write the E2E spec**

Create `e2e/tests/books/account/ranking-configurations.spec.ts`:

```ts
import { test, expect, type Page } from '@playwright/test';

// Owner flow for user-owned ranking configurations (spec
// docs/superpowers/specs/2026-09-12-user-ranking-configurations-design.md).
//
// Budget: the shared E2E account may own 5 rankings and trigger 5 manual
// refreshes a day. This spec creates one from scratch (so the automatic
// first calculation is instant), spends ONE manual refresh, and deletes the
// ranking at the end; the first test also sweeps any leftovers from a
// failed run so the cap can never wedge the account. Do not run it more
// than five times a day.

const BASE_URL = 'https://dev-new.thegreatestbooks.org';
const PREFIX = 'E2E ranking';
const runId = Date.now();
const name = `${PREFIX} ${runId}`;

let configId: string;

async function sweepLeftovers(page: Page): Promise<void> {
  for (let attempt = 0; attempt < 6; attempt += 1) {
    await page.goto('/my/rankings');
    const leftover = page.getByRole('article').filter({ hasText: PREFIX }).first();
    if ((await leftover.count()) === 0) return;
    await leftover.getByRole('link', { name: 'Manage' }).click();
    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL(/\/my\/rankings$/);
  }
}

test.describe.serial('user-owned ranking configurations', () => {
  test('create from scratch, tune, manage lists, refresh, share', async ({ page }) => {
    await sweepLeftovers(page);

    await page.goto('/my/rankings');
    await page.getByRole('link', { name: 'New ranking' }).click();
    await page.getByRole('link', { name: 'Or start from scratch' }).click();
    await expect(page).toHaveURL(/start=scratch/);

    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Description').fill('Built by the E2E suite.');
    await page.getByLabel('Share via link').check();
    await page.getByRole('button', { name: 'Create ranking' }).click();

    await expect(page).toHaveURL(/\/my\/rankings\/\d+$/);
    configId = page.url().match(/\/my\/rankings\/(\d+)$/)![1];
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(name);
    await expect(page.getByLabel('Share link')).toHaveValue(`${BASE_URL}/rc/${configId}`);

    // A from-scratch ranking has nothing to calculate; the automatic first
    // run finishes almost immediately.
    await expect(page.getByText('Up to date', { exact: true })).toBeVisible({ timeout: 60_000 });

    // Manage lists: add one by search, add one from the diff, remove one.
    await page.getByRole('link', { name: 'Manage lists' }).click();
    await expect(page.getByRole('heading', { name: /^Your lists \(0\)/ })).toBeVisible();

    const search = page.getByLabel('Search lists');
    await search.fill('Guardian');
    const firstResult = page.locator('[data-saved-search-picker-target="results"] button').first();
    await expect(firstResult).toBeVisible();
    const pickedName = (await firstResult.innerText()).replace(/\s+\(.*\)$/, '');
    await firstResult.click();
    await page.getByRole('button', { name: 'Add selected lists' }).click();
    await expect(page.getByRole('heading', { name: /^Your lists \(1\)/ })).toBeVisible();
    await expect(page.locator('turbo-frame#rc_lists').getByRole('link', { name: pickedName })).toBeVisible();

    const firstMissingAdd = page.locator('turbo-frame#rc_lists tr[id^="missing-list-"]').first().getByRole('button', { name: 'Add' });
    await firstMissingAdd.click();
    await expect(page.getByRole('heading', { name: /^Your lists \(2\)/ })).toBeVisible();

    page.once('dialog', (dialog) => dialog.accept());
    await page.locator('turbo-frame#rc_lists tr[id^="ranked-list-"]').first().getByRole('button', { name: 'Remove' }).click();
    await expect(page.getByRole('heading', { name: /^Your lists \(1\)/ })).toBeVisible();
    await expect(page.getByText('Needs refresh', { exact: true })).toBeVisible();

    // Refresh (one of five for the day) and wait for the poller to reload.
    await page.getByRole('button', { name: 'Refresh weights and rankings' }).click();
    await expect(page).toHaveURL(`/my/rankings/${configId}`);
    await expect(page.getByText('Up to date', { exact: true })).toBeVisible({ timeout: 120_000 });

    // Public view with the banner.
    await page.goto(`/rc/${configId}`);
    await expect(page.getByRole('status').filter({ hasText: "You're viewing a custom ranking" })).toBeVisible();
    await expect(page.getByRole('status').filter({ hasText: name })).toBeVisible();
  });

  test('a shared ranking is public, a private one is not', async ({ browser, page }) => {
    const anonymous = await browser.newContext();
    const anonymousPage = await anonymous.newPage();

    const shared = await anonymousPage.goto(`/rc/${configId}`);
    expect(shared?.status()).toBe(200);
    await expect(anonymousPage.getByRole('status').filter({ hasText: name })).toBeVisible();

    await page.goto(`/my/rankings/${configId}/edit`);
    await page.getByLabel('Share via link').uncheck();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page).toHaveURL(`/my/rankings/${configId}`);

    const hidden = await anonymousPage.goto(`/rc/${configId}`);
    expect(hidden?.status()).toBe(404);
    await anonymous.close();
  });

  test('delete', async ({ page }) => {
    await page.goto(`/my/rankings/${configId}`);
    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL(/\/my\/rankings$/);
    await expect(page.getByRole('article').filter({ hasText: name })).toHaveCount(0);
  });
});
```

- [ ] **Step 2: Run it**

Confirm port 3000 is yours (AGENTS.md snippet), then in three terminals from `web-app/`:

```bash
yarn build:all && bin/rails server
bundle exec sidekiq -C config/sidekiq.yml
yarn test:e2e --project=books-account -g "user-owned ranking configurations"
```

Expected: 3 passed. If the picker returns nothing for "Guardian", the dev database has no active list matching it — change the query to any active list's name (`bin/rails runner 'puts Books::List.where(status: :active).limit(3).pluck(:name)'`).

- [ ] **Step 3: Write the feature doc**

Create `docs/features/user-ranking-configurations.md` (repo root `docs/`):

```markdown
# User-Owned Ranking Configurations

## Overview

Signed-in users create their own ranking configurations: name and describe
one, share it by link or keep it private, tune the six algorithm settings,
switch each catalogue penalty on or off with its own value, choose which lists
feed it, and view the result on the public `/rc/<id>` pages. Weights and
rankings are recalculated in the background on creation and on demand.

Books only for now. The core is domain-generic; see "Switching on a domain".

Design: `docs/superpowers/specs/2026-09-12-user-ranking-configurations-design.md`.

## Data model

Everything lives on `ranking_configurations` (STI, `Books::RankingConfiguration`):

| Column | Meaning |
|---|---|
| `global` / `user_id` | `global: false` + `user_id` = user-owned (pre-existing columns) |
| `user_shared` | the owner has shared it by link |
| `refresh_status` | enum `idle / queued / running / failed` (`refresh_*?` predicates) |
| `needs_refresh` | a setting, penalty or list changed since the last successful run |
| `refresh_requested_at` | set when a run is claimed; runs older than an hour are treated as abandoned |
| `last_refreshed_at`, `last_refresh_error` | shown on the manage page |
| `inherited_from_id` | the official configuration it was copied from (nil when started from scratch) |

Rules for user-owned rows only: `min_list_weight` 0..100, `description` ≤ 1000,
never `primary`, at most `RankingConfiguration::MAX_PER_USER` (5) per user per
type. Model-wide: `max_list_dates_penalty_age` ≤ 200.

A penalty is **on** when a `PenaltyApplication` row exists for it and **off**
when none does — the weight calculator already skips penalties without a row.

## Where the code is

- `app/lib/ranking_configurations/registry.rb` — one `Entry` per user-creatable
  configuration class: classes, penalty types, public path helpers.
- `app/lib/ranking_configurations/penalty_rows.rb`, `missing_lists_query.rb` —
  read-only helpers for the form and the lists page.
- `app/lib/services/ranking_configurations/{create,save,add_lists}.rb` — the
  transactional writes.
- `RankingConfiguration#request_refresh!` — one atomic `UPDATE … WHERE` that
  claims the lock and enqueues `RankingConfigurations::RefreshJob`.
- `app/sidekiq/ranking_configurations/refresh_job.rb` — weights then rankings,
  queue `low`, `retry: false`; the outcome lands on the row.
- `app/controllers/my/ranking_configurations_controller.rb` and
  `my/ranking_configurations/lists_controller.rb` — global `/my/rankings`
  routes, domain from `Current.domain`, owner-only, never cached.
- `app/policies/ranking_configuration_policy.rb` — ownership. Every
  `authorize` passes `policy_class:` explicitly because Pundit's default for a
  `Books::RankingConfiguration` is the admin policy.
- `app/controllers/concerns/ranking_configuration_gating.rb` — `/rc/:id`
  visibility: global → everyone; user-owned → shared or owner, else 404.
- `Cacheable#cache_for_*` — return `prevent_caching` for a user-owned
  configuration, so no page under `/rc/` for one is ever edge-cached.
- `app/views/shared/_custom_ranking_banner.html.erb` — rendered by the domain
  layout when the gating concern set `@custom_ranking_configuration`.

## Refresh throttling

- A refresh request during a run is rejected before the rate limit sees it.
- `rate_limit to: 5, within: 24.hours` keyed by `current_user.id` on the shared
  Redis store (`config/initializers/rate_limit_store.rb`).
- The automatic run on create never passes through the controller action, so
  it does not count.
- `low` is strict-priority behind `critical` and `default` (`config/sidekiq.yml`).

## Search indexing

Nothing indexes a user-owned configuration: `Books::Book#primary_ranked_item`
is scoped to `default_primary`, `Books::ReindexRankedFieldsJob` loads the
primary itself, and the refresh job enqueues no reindex. `CalculateRankingsJob`
only triggers author rankings and the reindex for the primary.

## Switching on a domain

Add the domain's entries to `RankingConfigurations::Registry::ENTRIES` (two for
music — albums and songs — which turns on the kind chooser on `new`), a "My
Rankings" nav link, the banner `render` line in that domain's layout, and an E2E
spec under `e2e/tests/<domain>/`. No controller, model, job or policy changes.

## Testing

- Model, registry, query, service, job and policy tests under `test/`.
- `test/controllers/my/**` covers CRUD, refresh, the cap, the state endpoint,
  lists, search, Turbo Stream replies, frame-trapped links, and an N+1 guard.
- `test/controllers/books/*` pins `/rc/` gating and cache headers for every
  books controller that resolves a configuration.
- `e2e/tests/books/account/ranking-configurations.spec.ts` — owner flow; uses
  one of the E2E account's five daily refreshes per run.
```

- [ ] **Step 4: Full verification**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: green, no offenses, `All is good!`. The suite must emit no new warning lines (AGENTS.md).

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/account/ranking-configurations.spec.ts ../docs/features/user-ranking-configurations.md
git commit -m "test(rankings): E2E for user-owned ranking configurations; feature doc

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012sEJn87kAQmg7QEzLz1cYM"
```

---

## Plan self-review

**Spec coverage.** §2 decisions: cap (T1, T10), daily refresh cap exempting create and in-progress clicks (T4, T11), bounds (T1), disabled = no row (T7), never cached + 404 (T2), banner (T13), `low` queue (T4), delete (T10), `user_shared` (T1), starting point (T6, T10), domain-generic (T5, T10), services only where multi-table (T6–T8; refresh on the model T4; delete and remove-list in controllers T10, T12). §4 model (T1, T4). §5 registry (T5). §6 services and queries (T5–T8). §7 job, throttle, policy, `CalculateRankingsJob` gate (T3, T4, T9, T11). §8 routes/controllers/pages (T10–T12), nav (T13). §9 gating/cache/banner (T2, T13). §10 indexing tests (T3, T4). §12 tests throughout; E2E (T14). §13 build order matches T1–T14. §14 enablement checklist (feature doc, T14).

**Placeholder scan.** No TBD/TODO. Two conditional instructions remain deliberately: the filters-route check in T2 Step 1 and the Pagy `page:` note in T12 Step 4 — both give the exact alternative.

**Type consistency.** `Registry.penalties_for(entry)` (T5) is what `Create`, `Save`, `PenaltyRows` and the controller call. `PenaltyRows.call(entry:, values:)` with `values` as `{Integer => Integer}` matches `default_penalty_values`, `submitted_penalty_values` and `edit`. `penalties` passed to `Create`/`Save` is `{String => {"enabled" =>, "value" =>}}` — produced by `penalty_params(entry).to_h` (indifferent-access hash, string keys) and consumed with `penalties[penalty.id.to_s]` / `submitted["enabled"]`. `set_ranking_configuration(query = nil)` (T10) is called with `:manage_lists?` in T12, which `RankingConfigurationPolicy` defines (T9). `RefreshJob` is referenced by `request_refresh!` (T4) before any controller exists — T4 defines both. `REFRESH_LIMIT`/`REFRESH_WINDOW` are on `My::RankingConfigurationsController` (T11) and read by the status partial and tests. `@custom_ranking_configuration` is set in T2 and read in T13.
