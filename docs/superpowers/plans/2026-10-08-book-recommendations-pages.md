# Book Recommendations Pages (Increments 3–4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the merged recommendation engine in front of users on the books host: a results page with reasons and a side panel, membership gating (free 10 / member 50, members-only preferences), a signed-out pitch, the four-step wizard, the settings page, the nav entry, and Playwright coverage.

**Architecture:** One domain-generic `RecommendationsController` (routes identical on every host, `DomainLayout`, domain resolved from `Current.domain`, 404 on a host with no entry in `Recommendations::Registry`). Books-specific data loading lives in `Recommendations::Books::Pages`, resolved through the registry; books-specific markup lives in `app/views/recommendations/books/` partials. The engine is called once per results page with `limit` from the membership and `overrides` from the user's stored criteria (the new "depth" setting maps to the engine's `quality_floor`). Wizard steps embed the site's existing widgets (`Books::CardComponent` with its list widget, `Reviews::WidgetComponent`) and a new Turbo-frame search action.

**Tech Stack:** Rails 8, ViewComponent, Turbo Frames, Stimulus (reusing `saved-search-picker`), daisyUI 5 on Tailwind 4, Minitest 6 + Mocha + fixtures, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-07-book-recommendations-design.md` (§2 product surface, §2.3 gating, §2.4 nav, §3 cross-domain shape, §5.5 failure, §8.3 explanations, §10 testing, §11 delivery). Engine facts: `docs/features/recommendations.md`. Measured knobs: `docs/data-quality/recommendations-2026-10-08.md`.

**Increments 3 and 4 ship on one branch.** The spec lists them separately, but the results page redirects a user with no history to wizard step 1, so a results page without the wizard sends new users to a 404. Tasks 1–5 are increment 3, Tasks 6–8 are increment 4; a reviewer can still gate each task alone.

**Deviations from the spec, decided while planning (the code was checked):**

- §2.3 says the locked form "opens the same membership modal `CsvExports::DownloadButtonComponent` uses". There is no shared membership modal; that component renders a CSV-specific top-500 dialog. The locked form instead shows a lock banner and a "Become a member" link to `membership_path`, which is where the plans and the join buttons live.
- §2.1 says the wizard's search box renders cards "inside a Turbo Frame" like the site search. The site search is a plain full-page form with no frame. This plan adds a `search` action that renders a frame of cards; the step views post to it with `data-turbo-frame`.
- §2.1 step 3 says "redirect to step 2 with a flash rendered via turbo-stream". A redirect cannot carry a turbo-stream. These pages are uncached and signed-in, so a session flash survives the redirect; the wizard template renders `flash[:alert]` inline itself (public layouts render no flash, see the `public-layouts-render-no-flash` memory). Same effect, simpler.
- Added, with Shane's approval on 2026-10-08: a **depth** setting on the preferences form ("Safer bets / Balanced / Deep cuts"), stored in the criteria JSON as `depth` and mapped to the engine's `quality_floor` (0.1 / default / 0.5). Measured in the 2026-10-08 data-quality record.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live at the project root.
- Limits come from `config/initializers/recommendations.rb`: `free_limit: 10`, `member_limit: 50`. Never hard-code 10 or 50 in a controller or view.
- Register `book_recommendations` in `MembershipGate::FEATURES` (spec §2.3). The settings POST rejects non-members server-side (`require_membership!`), regardless of the disabled form.
- Every page here is per-user: `before_action :prevent_caching` on the whole controller.
- Routes are global (no `DomainConstraint`), exactly like the saved-search routes; a host whose domain has no registry entry must 404 (spec §3). The legacy path `/recommendations` is kept.
- Every `turbo_frame_tag` whose contents link off-page carries `target: "_top"`; `assert_no_frame_trapped_links` must pass for every page with a frame (AGENTS.md).
- daisyUI 5 only: never `form-control`, `label-text`, `input-bordered`, `select-bordered`, `tabs-boxed` and the other removed classes (`test/lint/daisyui_v4_classes_test.rb` fails the build). Use `fieldset` + `fieldset-legend`.
- Generators for every new controller and component (`bin/rails generate controller`, `bin/rails generate component`); delete generated files the plan does not use (helpers, JS, stylesheets) but keep the generated test.
- Minitest 6: `assert_nil`, never `assert_equal nil`. No `assert_empty` as the only assertion. Controller tests assert status, redirects, `view_assigns` and database effects, never copy or CSS.
- Tests mirror the namespace of the code under test. `sign_in_as(user, stub_auth: true)` for signed-in integration tests; host is `host! "dev-new.thegreatestbooks.org"`.
- Controller tests never hit OpenSearch: stub `::Search::Books::Search::BookRecommendations.call` / `.ranked_only` and `::Search::Books::Search::BookGeneral.call`.
- E2E placement decides the account: `e2e/tests/books/` anonymous, `e2e/tests/books/account/` signed-in non-member, `e2e/tests/books/member/` member. Confirm port 3000 is yours before `yarn test:e2e` (AGENTS.md). Mutating specs clean up before and after.
- Wizard and pitch copy goes through the `avoid-ai-writing` skill before merge (spec §2.4).
- Before claiming done: `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`, no new warnings.

## Review Focus

Inputs the spec implies but names no test for; each has its test added to the owning task.

1. **A free account submits the settings form by hand** (the disabled form is client-side only): the POST must redirect to the membership page and leave the config row untouched. → Task 7.
2. **The engine succeeds with zero items and nothing degraded** (a user whose preferences exclude everything): the page must say "no books match your settings" with a link to settings, not "unavailable", and never 500. → Task 4.
3. **A stored category id that no longer exists** (categories get merged): the side panel shows "Unknown (#id)" and the preferences form skips the chip; neither raises. → Tasks 4 and 7.
4. **`q` blank, whitespace, or 2,000 characters long on the wizard search**: no OpenSearch call for a blank query, an empty frame with a message, never a 500. → Task 6.
5. **`criteria` posted as a string instead of a hash** (`recommendation_config[criteria]=x`): the controller must answer 422, not raise on `permit`. → Task 7.
6. **A reason whose category or book id has no name** (deleted between the query and the page): the reason line falls back to "#id" rather than raising. → Task 3.

---

## File structure

```
web-app/
  app/lib/membership_gate.rb                                   # modify: register :book_recommendations
  app/lib/recommendations/registry.rb                          # modify: DOMAIN_PAGES, MEMBERSHIP_FEATURES
  app/lib/recommendations/engine.rb                            # modify: degraded flag, rank_position on items
  app/lib/recommendations/books/pages.rb                       # create: books data for the pages
  app/lib/books/recommendation_criteria.rb                     # modify: depth + engine_overrides
  app/lib/books/recommendation_criteria_params.rb              # modify: depth
  app/models/books/recommendation_config.rb                    # modify: criteria_params_class
  config/initializers/recommendations.rb                       # modify: depth_floors
  config/routes.rb                                             # modify: recommendation routes
  app/controllers/recommendations_controller.rb                # create
  app/components/recommendations/reason_component.rb (+ .html.erb)
  app/components/recommendations/taste_component.rb (+ .html.erb)
  app/components/recommendations/progress_component.rb (+ .html.erb)
  app/views/recommendations/show.html.erb                      # results
  app/views/recommendations/wizard.html.erb                    # one template, renders the step partial
  app/views/recommendations/settings.html.erb
  app/views/recommendations/search.html.erb                    # the Turbo frame of cards
  app/views/recommendations/_alert.html.erb                    # inline flash
  app/views/recommendations/books/_pitch.html.erb
  app/views/recommendations/books/_side_panel.html.erb
  app/views/recommendations/books/_member_pitch.html.erb
  app/views/recommendations/books/_step_1.html.erb .. _step_4.html.erb
  app/views/recommendations/books/_search_form.html.erb
  app/views/recommendations/books/_book_row.html.erb
  app/views/recommendations/books/_settings_form.html.erb
  app/views/books/shared/_nav_links.html.erb                   # modify: both variants
  app/views/membership/_story_books.html.erb                   # modify: link to the pitch
  test/lib/membership_gate_test.rb                             # modify
  test/lib/recommendations/registry_test.rb                    # modify or create
  test/lib/recommendations/engine_test.rb                      # modify
  test/lib/recommendations/books/pages_test.rb                 # create
  test/lib/books/recommendation_criteria_test.rb               # modify
  test/lib/books/recommendation_criteria_params_test.rb        # modify
  test/components/recommendations/{reason,taste,progress}_component_test.rb
  test/controllers/recommendations_controller_test.rb          # create
  e2e/tests/books/recommendations-pitch.spec.ts
  e2e/tests/books/account/recommendations-locked.spec.ts
  e2e/tests/books/member/recommendations.spec.ts
docs/features/recommendations.md                               # modify: Pages section
```

Responsibilities: the controller routes, gates and chooses limits; `Pages` loads books data for views; components render one thing each; `_settings_form` is the only form; the engine is untouched except for two fields on its result.

---

### Task 1: Gate registration, registry entries, and the depth setting

**Files:**
- Modify: `web-app/app/lib/membership_gate.rb`
- Modify: `web-app/app/lib/recommendations/registry.rb`
- Modify: `web-app/app/lib/books/recommendation_criteria.rb`
- Modify: `web-app/app/lib/books/recommendation_criteria_params.rb`
- Modify: `web-app/app/models/books/recommendation_config.rb`
- Modify: `web-app/config/initializers/recommendations.rb`
- Test: `web-app/test/lib/membership_gate_test.rb`, `web-app/test/lib/recommendations/registry_test.rb` (create if absent), `web-app/test/lib/books/recommendation_criteria_test.rb`, `web-app/test/lib/books/recommendation_criteria_params_test.rb`

**Interfaces:**
- Consumes: `MembershipGate::FEATURES` (`app/lib/membership_gate.rb`), `Recommendations::Registry.adapter_class_for(domain)`, `Books::RecommendationCriteria::KEYS`, `Books::SavedSearchCriteriaParams.call(raw)`.
- Produces: `Recommendations::Registry.pages_class_for(domain) -> Class | nil`; `Recommendations::Registry.membership_feature_for(domain) -> Symbol | nil`; `Books::RecommendationCriteria::DEPTHS = %w[safe balanced deep]`, `#depth -> String` (default `"balanced"`), `#engine_overrides -> Hash` (`{quality_floor: Float}` or `{}`); `Books::RecommendationCriteriaParams.call(raw)` keeps `"depth"` when it is `"safe"` or `"deep"`; `Books::RecommendationConfig.criteria_params_class -> Books::RecommendationCriteriaParams`; initializer key `depth_floors: {"safe" => 0.1, "deep" => 0.5}`.

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/membership_gate_test.rb` (inside the existing test class):

```ruby
  test "book recommendations are a registered members-only feature" do
    assert MembershipGate.members_only?(:book_recommendations)
    assert_equal :book_recommendations, MembershipGate.validate!(:book_recommendations)
  end
```

Create or extend `test/lib/recommendations/registry_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class RegistryTest < ActiveSupport::TestCase
    test "resolves the books adapter, pages and membership feature" do
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for(:books)
      assert_equal Recommendations::Books::Pages, Registry.pages_class_for("books")
      assert_equal :book_recommendations, Registry.membership_feature_for(:books)
    end

    test "an unknown domain resolves to nothing" do
      assert_nil Registry.adapter_class_for(:music)
      assert_nil Registry.pages_class_for(:music)
      assert_nil Registry.membership_feature_for(:music)
    end
  end
end
```

(`Recommendations::Books::Pages` does not exist until Task 2; the first assertion fails with `NameError` until then. Leave it: Task 2 turns it green. Run the second test alone in this task.)

Append to `test/lib/books/recommendation_criteria_test.rb`:

```ruby
    test "depth defaults to balanced and only accepts the three known values" do
      assert_equal "balanced", RecommendationCriteria.new({}).depth
      assert_equal "deep", RecommendationCriteria.new("depth" => "deep").depth
      assert_equal "balanced", RecommendationCriteria.new("depth" => "sideways").depth
    end

    test "engine_overrides maps depth to the quality floor and balanced to nothing" do
      assert_equal({}, RecommendationCriteria.new({}).engine_overrides)
      assert_equal({quality_floor: 0.1}, RecommendationCriteria.new("depth" => "safe").engine_overrides)
      assert_equal({quality_floor: 0.5}, RecommendationCriteria.new("depth" => "deep").engine_overrides)
    end

    test "depth never reaches the search criteria" do
      criteria = RecommendationCriteria.new("depth" => "deep", "max_ranked_position" => 100)
      assert_equal 100, criteria.to_search_criteria.max_ranked_position
      assert_equal :ranked, criteria.to_search_criteria.ranked
    end
```

Append to `test/lib/books/recommendation_criteria_params_test.rb`:

```ruby
    test "keeps a non-default depth and drops balanced and unknown values" do
      assert_equal "deep", RecommendationCriteriaParams.call("depth" => "deep")["depth"]
      assert_equal "safe", RecommendationCriteriaParams.call("depth" => "safe")["depth"]
      assert_nil RecommendationCriteriaParams.call("depth" => "balanced")["depth"]
      assert_nil RecommendationCriteriaParams.call("depth" => "whatever")["depth"]
    end
```

Add to `test/models/books/recommendation_config_test.rb` (create the file if it does not exist, mirroring `test/models/recommendation_config_test.rb`'s style):

```ruby
    test "names its criteria params class" do
      assert_equal ::Books::RecommendationCriteriaParams, ::Books::RecommendationConfig.criteria_params_class
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/membership_gate_test.rb test/lib/books/ test/lib/recommendations/registry_test.rb test/models/books/recommendation_config_test.rb`
Expected: failures on `members_only?`, `pages_class_for`, `depth`, `engine_overrides`, the params depth test and `criteria_params_class` (`NoMethodError` / assertion failures).

- [ ] **Step 3: Implement**

`app/lib/membership_gate.rb`, inside `FEATURES` after `csv_export_full`:

```ruby
    book_recommendations: "Personalized book recommendations: 50 results and editable preferences (free accounts get 10 results on the default settings)"
```

`app/lib/recommendations/registry.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # Which adapter, page loader and membership feature serve which domain.
  # Mirrors SavedSearch::DOMAIN_SUBCLASSES. A domain absent here has no
  # recommendations: the controller 404s on its host.
  module Registry
    DOMAIN_ADAPTERS = {"books" => "Recommendations::Books::Adapter"}.freeze
    DOMAIN_PAGES = {"books" => "Recommendations::Books::Pages"}.freeze
    MEMBERSHIP_FEATURES = {"books" => :book_recommendations}.freeze

    def self.adapter_class_for(domain)
      DOMAIN_ADAPTERS[domain.to_s]&.constantize
    end

    def self.pages_class_for(domain)
      DOMAIN_PAGES[domain.to_s]&.constantize
    end

    def self.membership_feature_for(domain)
      MEMBERSHIP_FEATURES[domain.to_s]
    end
  end
end
```

`config/initializers/recommendations.rb`, after `quality_floor: 0.3,`:

```ruby
  # The user-facing "depth" setting (spec §9.4 "deep cuts"): a stored depth maps
  # to this quality_floor; "balanced" stores nothing and follows quality_floor.
  depth_floors: {"safe" => 0.1, "deep" => 0.5}.freeze,
```

`app/lib/books/recommendation_criteria.rb` — replace the class body:

```ruby
  class RecommendationCriteria
    KEYS = %w[
      included_category_ids excluded_category_ids genre_match_mode book_length
      first_year_published_gt first_year_published_lt max_ranked_position depth
    ].freeze

    # The keys SavedSearchCriteria understands; `depth` is the engine's, not the query's.
    SEARCH_KEYS = (KEYS - %w[depth]).freeze

    READERS = %i[
      included_category_ids excluded_category_ids genre_match_mode book_length
      first_year_published_gt first_year_published_lt max_ranked_position
    ].freeze

    DEPTHS = %w[safe balanced deep].freeze
    DEFAULT_DEPTH = "balanced"

    attr_reader :depth

    def initialize(raw)
      stored = (raw || {}).to_h.stringify_keys.slice(*KEYS)
      @depth = DEPTHS.include?(stored["depth"]) ? stored["depth"] : DEFAULT_DEPTH
      @search = ::Books::SavedSearchCriteria.new(stored.slice(*SEARCH_KEYS).merge("ranked" => "true"))
    end

    READERS.each do |reader|
      define_method(reader) { @search.public_send(reader) }
    end

    def unparseable?(key)
      @search.unparseable?(key)
    end

    # The object the clause builders (Search::Books::Search::CriteriaClauses) take.
    def to_search_criteria
      @search
    end

    # Per-call engine knobs this criteria implies (Recommendations::Engine
    # `overrides:`). Balanced overrides nothing, so it follows the initializer.
    def engine_overrides
      floor = Rails.application.config.x.recommendations[:depth_floors][depth]
      floor ? {quality_floor: floor} : {}
    end
  end
```

`app/lib/books/recommendation_criteria_params.rb`:

```ruby
  class RecommendationCriteriaParams
    def self.call(raw)
      out = ::Books::SavedSearchCriteriaParams.call(raw).slice(*::Books::RecommendationCriteria::KEYS)
      depth = (raw || {}).to_h.stringify_keys["depth"].to_s
      stored_depths = ::Books::RecommendationCriteria::DEPTHS - [::Books::RecommendationCriteria::DEFAULT_DEPTH]
      out["depth"] = depth if stored_depths.include?(depth)
      out
    end
  end
```

`app/models/books/recommendation_config.rb`, add beside `criteria_class`:

```ruby
    def self.criteria_params_class
      ::Books::RecommendationCriteriaParams
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/membership_gate_test.rb test/lib/books/ test/lib/recommendations/registry_test.rb test/models/ test/lib/services/books_migration/`
Expected: all pass except `RegistryTest#resolves the books adapter, pages and membership feature` (NameError until Task 2). The migrator tests must still pass: legacy rows carry no depth.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/membership_gate.rb app/lib/recommendations/registry.rb app/lib/books config/initializers/recommendations.rb test/lib
git add app/lib/membership_gate.rb app/lib/recommendations/registry.rb app/lib/books app/models/books/recommendation_config.rb config/initializers/recommendations.rb test/lib test/models
git commit -m "Register book recommendations as a member feature and add the depth setting"
```

---

### Task 2: `Recommendations::Books::Pages`

**Files:**
- Create: `web-app/app/lib/recommendations/books/pages.rb`
- Test: `web-app/test/lib/recommendations/books/pages_test.rb`

**Interfaces:**
- Consumes: `::Books::UserList` (enum `list_type` favorites/read/reading/want_to_read/custom), `::UserListItem` (`user_list`, `listable_type`, `listable_id`, `position`, `created_at`), `::Review` (`user`, `reviewable_type`, `reviewable_id`, `rating`), `::Books::BookSearchQuery.call(text, size:)`, `::Books::SavedSearchFilterLabels.call(criteria)` (returns `Group(label:, values:, note:)`), `Books::RecommendationCriteria#depth` / `#to_search_criteria`.
- Produces (all instance methods on `Recommendations::Books::Pages.new(user:)`):
  - `history? -> Boolean` (at least one favorite or read book)
  - `favorites -> StepBooks(books: [Books::Book], total: Integer)` ordered by list position
  - `read_books -> StepBooks` newest 500 by item created_at
  - `unrated_read -> [Books::Book]` read books (within the 500) with no rated review
  - `rated(limit: 50) -> [[Books::Book, Review]]` newest first
  - `list(list_type) -> Books::UserList | nil`
  - `search(query) -> [Books::Book]` (12, with `ranked_position`)
  - `category_names(ids) -> {id => name}`, `item_names(ids) -> {id => title}`
  - `criteria_groups(criteria) -> [Group]` for the side panel: the saved-search groups minus "Ranking status", plus a "Depth" group when depth is not balanced
  - `DEPTH_LABELS = {"safe" => "Safer bets", "balanced" => "Balanced", "deep" => "Deep cuts"}`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  module Books
    class PagesTest < ActiveSupport::TestCase
      # Fixtures: regular_user owns a favorites and a read list (both empty);
      # reviews: war_and_peace ★5 and crime_and_punishment ★3 by regular_user.
      def setup
        @user = users(:regular_user)
        @favorites = user_lists(:regular_user_books_favorites)
        @read = user_lists(:regular_user_books_read)
        @pages = Pages.new(user: @user)
      end

      def add(list, book, position: nil)
        ::UserListItem.create!(user_list: list, listable: book, position: position)
      end

      test "history? is false with empty lists and true once a favorite or read book exists" do
        assert_not @pages.history?
        add(@read, books_books(:got))
        assert Pages.new(user: @user).history?
      end

      test "favorites come back in list order with their total" do
        add(@favorites, books_books(:clash), position: 2)
        add(@favorites, books_books(:got), position: 1)
        result = @pages.favorites
        assert_equal [books_books(:got), books_books(:clash)], result.books
        assert_equal 2, result.total
        assert result.books.first.association(:book_authors).loaded?
      end

      test "read books are newest first and capped at the read limit" do
        old = add(@read, books_books(:got))
        old.update_columns(created_at: 2.days.ago)
        add(@read, books_books(:clash))
        with_limit = Pages.new(user: @user)
        with_limit.stubs(:read_limit).returns(1)
        result = with_limit.read_books
        assert_equal [books_books(:clash)], result.books
        assert_equal 2, result.total, "the total counts beyond the cap"
      end

      test "unrated_read drops read books the user has rated, and rated lists them with the review" do
        add(@read, books_books(:war_and_peace))
        add(@read, books_books(:got))
        assert_equal [books_books(:got)], @pages.unrated_read
        rated = @pages.rated
        assert_includes rated.map(&:first), books_books(:war_and_peace)
        assert_equal 5, rated.find { |book, _| book == books_books(:war_and_peace) }.last.rating
      end

      test "a text-only review does not count as rated" do
        add(@read, books_books(:got))
        ::Review.create!(user: @user, reviewable: books_books(:got), body: "Fine.")
        assert_includes @pages.unrated_read, books_books(:got)
      end

      test "a user with no lists has no history and empty steps" do
        pages = Pages.new(user: users(:books_viewer_user))
        assert_not pages.history?
        assert_equal 0, pages.favorites.total
        assert_equal [], pages.unrated_read
      end

      test "search delegates to the site search with the page size" do
        ::Books::BookSearchQuery.expects(:call).with("hall", size: Pages::SEARCH_SIZE).returns([books_books(:got)])
        assert_equal [books_books(:got)], @pages.search("hall")
      end

      test "names look up categories and books by id" do
        genre = categories(:books_classics_genre)
        assert_equal({genre.id => genre.name}, @pages.category_names([genre.id, 0]))
        assert_equal({books_books(:got).id => books_books(:got).title}, @pages.item_names([books_books(:got).id]))
      end

      test "criteria_groups drops the ranked group and adds a depth group when it is not balanced" do
        criteria = ::Books::RecommendationCriteria.new("max_ranked_position" => 100, "depth" => "deep")
        groups = @pages.criteria_groups(criteria)
        labels = groups.map(&:label)
        assert_includes labels, "Ranking limit"
        assert_not_includes labels, "Ranking status"
        assert_equal ["Deep cuts"], groups.find { |g| g.label == "Depth" }.values

        balanced = @pages.criteria_groups(::Books::RecommendationCriteria.new({}))
        assert_equal [], balanced.map(&:label)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/recommendations/books/pages_test.rb`
Expected: `NameError: uninitialized constant Recommendations::Books::Pages`.

- [ ] **Step 3: Implement**

```ruby
# frozen_string_literal: true

module Recommendations
  module Books
    # Everything the recommendation pages need that is books-specific and not
    # the engine's business: the user's shelves for the wizard steps, the
    # search box, and the names behind the ids the engine returns. The
    # controller is domain-generic and reaches this through
    # Registry.pages_class_for. Root-anchored constants throughout: inside
    # Recommendations::Books a bare `Books::Book` resolves to the wrong module.
    class Pages
      READ_LIMIT = 500
      RATED_LIMIT = 50
      SEARCH_SIZE = 12
      DEPTH_LABELS = {"safe" => "Safer bets", "balanced" => "Balanced", "deep" => "Deep cuts"}.freeze
      DROPPED_GROUP_LABELS = ["Ranking status"].freeze

      StepBooks = Struct.new(:books, :total, keyword_init: true)

      def initialize(user:)
        @user = user
      end

      def history?
        [list(:favorites), list(:read)].compact.any? do |l|
          ::UserListItem.where(user_list: l, listable_type: "Books::Book").exists?
        end
      end

      def favorites
        list_books(:favorites, order: {position: :asc, created_at: :desc}, limit: nil)
      end

      def read_books
        list_books(:read, order: {created_at: :desc}, limit: read_limit)
      end

      def unrated_read
        rated_ids = rated_reviews.pluck(:reviewable_id).to_set
        read_books.books.reject { |book| rated_ids.include?(book.id) }
      end

      def rated(limit: RATED_LIMIT)
        reviews = rated_reviews.order(updated_at: :desc, id: :desc).limit(limit).to_a
        books = load_books(reviews.map(&:reviewable_id))
        reviews.filter_map { |review| (book = books[review.reviewable_id]) && [book, review] }
      end

      def list(list_type)
        ::Books::UserList.find_by(user: @user, list_type: list_type)
      end

      def search(query)
        ::Books::BookSearchQuery.call(query, size: SEARCH_SIZE)
      end

      def category_names(ids)
        return {} if ids.empty?

        ::Books::Category.where(id: ids).pluck(:id, :name).to_h
      end

      def item_names(ids)
        return {} if ids.empty?

        ::Books::Book.where(id: ids).pluck(:id, :title).to_h
      end

      # The side panel's settings summary. The saved-search labels already
      # name categories and format years; the recommendation criteria pin
      # `ranked` to true, so that group is noise here and is dropped.
      def criteria_groups(criteria)
        groups = ::Books::SavedSearchFilterLabels.call(criteria.to_search_criteria)
          .reject { |group| DROPPED_GROUP_LABELS.include?(group.label) }
        if criteria.depth != ::Books::RecommendationCriteria::DEFAULT_DEPTH
          groups << ::Books::SavedSearchFilterLabels::Group.new(label: "Depth", values: [DEPTH_LABELS.fetch(criteria.depth)])
        end
        groups
      end

      private

      # Overridable in tests so the cap is exercised without 501 rows.
      def read_limit
        READ_LIMIT
      end

      def rated_reviews
        @user.reviews.where(reviewable_type: "Books::Book").where.not(rating: nil)
      end

      def list_books(list_type, order:, limit:)
        l = list(list_type)
        return StepBooks.new(books: [], total: 0) if l.nil?

        scope = ::UserListItem.where(user_list: l, listable_type: "Books::Book")
        total = scope.count
        ids = scope.order(order).then { |s| limit ? s.limit(limit) : s }.pluck(:listable_id)
        books = load_books(ids)
        StepBooks.new(books: ids.filter_map { |id| books[id] }, total: total)
      end

      def load_books(ids)
        return {} if ids.empty?

        ::Books::Book.where(id: ids)
          .includes(book_authors: :author)
          .includes(primary_image: {file_attachment: :blob})
          .index_by(&:id)
      end
    end
  end
end
```

Note `rated` is public but `rated_reviews` is private; the test stubs `read_limit`, which is private — Mocha stubs private methods on an instance; this is the one allowed exception because the alternative is 501 fixture rows. If `position` is nil for every favorite, the secondary `created_at` order keeps it deterministic.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/recommendations/books/pages_test.rb test/lib/recommendations/registry_test.rb`
Expected: all pass (the registry test from Task 1 now resolves `Pages`).

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/recommendations/books/pages.rb test/lib/recommendations/books/pages_test.rb
git add app/lib/recommendations/books/pages.rb test/lib/recommendations/books/pages_test.rb
git commit -m "Add Recommendations::Books::Pages for the wizard and results data"
```

---

### Task 3: Reason, taste and progress components

**Files:**
- Create (via generator): `web-app/app/components/recommendations/reason_component.rb` + `.html.erb`, `taste_component.rb` + `.html.erb`, `progress_component.rb` + `.html.erb`
- Test: `web-app/test/components/recommendations/reason_component_test.rb`, `taste_component_test.rb`, `progress_component_test.rb`

**Interfaces:**
- Consumes: `Recommendations::Reason` (`type` in `:because_of | :interests | :ranked`, `ids`), `Recommendations::Profile` (`genres`, `subjects`, `locations` as `[[id, weight]]`, `counts` hash with `:favorites`, `:read`, `:rated`).
- Produces:
  - `Recommendations::ReasonComponent.new(reason:, names:)` where `names` is `{id => String}` covering the reason's ids; `#text -> String`.
  - `Recommendations::TasteComponent.new(profile:, names:, max_per_type: 5)`; renders three lists with a bar per entry and the counts line.
  - `Recommendations::ProgressComponent.new(current_step:, unlocked:)`; `unlocked` false renders steps 3 and 4 as plain text, not links. `STEPS = [[1, "Favorites"], [2, "History"], [3, "Ratings"], [4, "Preferences"]]`.

- [ ] **Step 1: Generate the components**

```bash
bin/rails generate component Recommendations::Reason reason names
bin/rails generate component Recommendations::Taste profile names
bin/rails generate component Recommendations::Progress current_step unlocked
```

Keep the `.rb`, `.html.erb` and the generated tests; delete any generated preview files.

- [ ] **Step 2: Write the failing tests**

`test/components/recommendations/reason_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ReasonComponentTest < ViewComponent::TestCase
    def reason(type, ids)
      Recommendations::Reason.new(type: type, ids: ids)
    end

    test "interests name the two categories" do
      render_inline(ReasonComponent.new(reason: reason(:interests, [1, 2]), names: {1 => "Dark", 2 => "Guilt"}))
      assert_selector "[data-testid='recommendation-reason']", text: "Matches Dark and Guilt"
    end

    test "because_of names the book" do
      render_inline(ReasonComponent.new(reason: reason(:because_of, [9]), names: {9 => "Molloy"}))
      assert_text "Because you loved Molloy"
    end

    test "ranked states the position" do
      render_inline(ReasonComponent.new(reason: reason(:ranked, [37]), names: {}))
      assert_text "Ranked #37 of all time"
    end

    test "a missing name falls back to the id instead of raising" do
      render_inline(ReasonComponent.new(reason: reason(:interests, [1, 404]), names: {1 => "Dark"}))
      assert_text "Matches Dark and #404"
    end

    test "a ranked reason with no position still renders" do
      render_inline(ReasonComponent.new(reason: reason(:ranked, []), names: {}))
      assert_text "On the all-time list"
    end
  end
end
```

`test/components/recommendations/taste_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class TasteComponentTest < ViewComponent::TestCase
    def profile(genres: [], subjects: [], locations: [], counts: {favorites: 2, read: 7, rated: 3})
      Recommendations::Profile.new(genres: genres, subjects: subjects, locations: locations, demoted: [],
        fiction_share: nil, genre_distribution: {}, counts: counts)
    end

    test "lists each type with a bar scaled to the strongest weight" do
      render_inline(TasteComponent.new(profile: profile(genres: [[1, 4.0], [2, 2.0]], subjects: [[3, 1.0]]),
        names: {1 => "Dark", 2 => "Tragedy", 3 => "Guilt"}))
      assert_selector "[data-testid='taste-genre']", count: 2
      assert_selector "[data-testid='taste-subject']", count: 1
      assert_selector "[data-testid='taste-location']", count: 0
      assert_selector "[data-testid='taste-genre'] progress[value='100'][max='100']"
      assert_selector "[data-testid='taste-genre'] progress[value='50'][max='100']"
      assert_text "Dark"
    end

    test "caps each type and skips an id with no name" do
      genres = (1..8).map { |i| [i, 9.0 - i] }
      names = (1..8).to_h { |i| [i, "G#{i}"] }.except(2)
      render_inline(TasteComponent.new(profile: profile(genres: genres), names: names, max_per_type: 3))
      assert_selector "[data-testid='taste-genre']", count: 3
      assert_no_text "G2"
      assert_text "G4"
    end

    test "renders the counts line" do
      render_inline(TasteComponent.new(profile: profile, names: {}))
      assert_selector "[data-testid='taste-counts']", text: /2 favorites.*7 read.*3 rated/
    end
  end
end
```

`test/components/recommendations/progress_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ProgressComponentTest < ViewComponent::TestCase
    test "marks the current and earlier steps and links every step when unlocked" do
      render_inline(ProgressComponent.new(current_step: 2, unlocked: true))
      assert_selector "li.step.step-primary", count: 2
      assert_selector "li.step", count: 4
      assert_selector "a[href='/recommendations/wizard/4']"
    end

    test "steps 3 and 4 are not links while the user has no history" do
      render_inline(ProgressComponent.new(current_step: 1, unlocked: false))
      assert_selector "a[href='/recommendations/wizard/2']"
      assert_no_selector "a[href='/recommendations/wizard/3']"
      assert_no_selector "a[href='/recommendations/wizard/4']"
      assert_text "Ratings"
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/components/recommendations/`
Expected: failures (generated templates render placeholder text; the route helper in the progress test fails until Task 4 adds routes — write the component with `helpers.recommendations_wizard_path`, and expect this one test to stay red until Task 4; note it in the task report).

- [ ] **Step 4: Implement**

`app/components/recommendations/reason_component.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # One line under a recommended book saying why it is there (spec §8.3).
  # `names` maps every id the reason carries to a display string; an id with
  # no name renders as "#id" rather than raising, since a category or book
  # can disappear between the query and the page.
  class ReasonComponent < ViewComponent::Base
    def initialize(reason:, names:)
      @reason = reason
      @names = names
    end

    def text
      case @reason.type
      when :because_of
        "Because you loved #{name(@reason.ids.first)}"
      when :interests
        "Matches #{@reason.ids.map { |id| name(id) }.join(" and ")}"
      else
        position = @reason.ids.first
        position ? "Ranked ##{position} of all time" : "On the all-time list"
      end
    end

    private

    def name(id)
      @names.fetch(id) { "##{id}" }
    end
  end
end
```

`reason_component.html.erb`:

```erb
<p class="text-sm text-base-content/70 [overflow-wrap:anywhere]" data-testid="recommendation-reason"><%= text %></p>
```

`taste_component.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # The "your taste" block on the results side panel: the strongest genres,
  # subjects and locations the engine used, each with a bar scaled to the
  # strongest weight of its type, plus the counts that fed the profile.
  class TasteComponent < ViewComponent::Base
    TYPES = [["genre", "Genres", :genres], ["subject", "Subjects", :subjects], ["location", "Places", :locations]].freeze

    def initialize(profile:, names:, max_per_type: 5)
      @profile = profile
      @names = names
      @max_per_type = max_per_type
    end

    # [[testid_type, heading, [[name, percent], ...]], ...] with empty types dropped.
    def groups
      TYPES.filter_map do |key, heading, reader|
        pairs = @profile.public_send(reader).select { |id, _| @names.key?(id) }.first(@max_per_type)
        next if pairs.empty?

        top = pairs.map(&:last).max
        rows = pairs.map { |id, weight| [@names.fetch(id), ((weight / top) * 100).round] }
        [key, heading, rows]
      end
    end

    def counts_line
      c = @profile.counts
      "Built from #{c[:favorites].to_i} favorites, #{c[:read].to_i} read and #{c[:rated].to_i} rated books"
    end
  end
end
```

`taste_component.html.erb`:

```erb
<div class="space-y-4" data-testid="taste">
  <% groups.each do |key, heading, rows| %>
    <div>
      <h3 class="font-semibold mb-2"><%= heading %></h3>
      <ul class="space-y-1">
        <% rows.each do |name, percent| %>
          <li class="flex items-center gap-2" data-testid="taste-<%= key %>">
            <span class="flex-1 text-sm [overflow-wrap:anywhere]"><%= name %></span>
            <progress class="progress progress-primary w-24" value="<%= percent %>" max="100" aria-label="<%= name %> weight"></progress>
          </li>
        <% end %>
      </ul>
    </div>
  <% end %>
  <p class="text-sm text-base-content/70" data-testid="taste-counts"><%= counts_line %></p>
</div>
```

`progress_component.rb`:

```ruby
# frozen_string_literal: true

module Recommendations
  # The wizard's step bar. Steps 3 and 4 need at least one favorite or read
  # book; until then they render as text so the bar never links to a redirect.
  class ProgressComponent < ViewComponent::Base
    STEPS = [[1, "Favorites"], [2, "History"], [3, "Ratings"], [4, "Preferences"]].freeze
    GATED_FROM = 3

    def initialize(current_step:, unlocked:)
      @current_step = current_step
      @unlocked = unlocked
    end

    def steps
      STEPS.map do |number, label|
        {number: number, label: label, reached: number <= @current_step, linked: @unlocked || number < GATED_FROM}
      end
    end
  end
end
```

`progress_component.html.erb`:

```erb
<ul class="steps w-full mb-8" data-testid="wizard-progress">
  <% steps.each do |step| %>
    <li class="step <%= "step-primary" if step[:reached] %>" <%= "aria-current=step".html_safe if step[:number] == @current_step %>>
      <% if step[:linked] %>
        <%= link_to step[:label], helpers.recommendations_wizard_path(step: step[:number]), class: "link link-hover" %>
      <% else %>
        <span class="text-base-content/60"><%= step[:label] %></span>
      <% end %>
    </li>
  <% end %>
</ul>
```

(`link link-hover` is invisible as an affordance on its own; inside daisyUI `steps` the step circle carries the affordance, which is why it is acceptable here.)

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/components/recommendations/`
Expected: reason and taste tests pass; progress tests fail on the missing route helper until Task 4 (re-run them there).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/components/recommendations test/components/recommendations
git add app/components/recommendations test/components/recommendations
git commit -m "Add the recommendation reason, taste and progress components"
```

---

### Task 4: Routes, controller `show`, results page, pitch, and the engine's two new fields

**Files:**
- Modify: `web-app/config/routes.rb` (next to the saved-search routes, ~line 535)
- Modify: `web-app/app/lib/recommendations/engine.rb` (`degraded` flag, `rank_position` on items)
- Create (via generator): `web-app/app/controllers/recommendations_controller.rb`
- Create: `web-app/app/views/recommendations/show.html.erb`, `_alert.html.erb`, `books/_pitch.html.erb`, `books/_side_panel.html.erb`, `books/_member_pitch.html.erb`
- Test: `web-app/test/lib/recommendations/engine_test.rb`, `web-app/test/controllers/recommendations_controller_test.rb`, `web-app/test/components/recommendations/progress_component_test.rb` (re-run)

**Interfaces:**
- Consumes: `Recommendations::Engine.call(user:, domain:, limit:, overrides:)` → `Result(success?, data: {items:, profile:, signals_used:, fallback:}, errors:)`; `Recommendations::Registry.pages_class_for`, `.adapter_class_for`, `.membership_feature_for`; `RecommendationConfig.subclass_for(domain)`, `.for_user(user)`, `#criteria_object`; `Pages` (Task 2); `ReasonComponent`, `TasteComponent` (Task 3); `MembershipGated#require_membership!(feature)`; `DomainLayout#resolve_layout`; `Cacheable#prevent_caching`; `ApplicationController#require_signed_in!`, `current_user`, `signed_in?`.
- Produces:
  - Routes (global): `GET /recommendations` → `recommendations#show` (`recommendations_path`); `GET /recommendations/search` → `#search` (`recommendations_search_path`); `GET /recommendations/wizard/:step` (`[1-4]`) → `#wizard` (`recommendations_wizard_path(step:)`); `GET /recommendations/settings` → `#settings` (`recommendations_settings_path`); `POST /recommendations/settings` → `#update_settings`; `POST /recommendations/reset` → `#reset` (`recommendations_reset_path`). Tasks 6–7 fill `search`, `wizard`, `settings`, `update_settings`, `reset`; this task declares the routes and leaves those actions raising `NotImplementedError`-free: define them as empty methods that `head :not_found` so the routes exist without dead links (Task 6 replaces them).
  - Engine result `data` gains `degraded: Boolean` (a personalized signal raised) and each item gains `rank_position: Integer | nil`.
  - Controller instance state for views: `@items` (engine item hashes), `@profile`, `@state` (`:ok | :no_matches | :unavailable`), `@limit`, `@member`, `@reason_names`, `@taste_names`, `@groups`, `@counts`.

- [ ] **Step 1: Write the failing engine tests**

Append to `test/lib/recommendations/engine_test.rb` (it has a `FakeAdapter` with `raise_search:` and `engine(...)` helpers; follow its existing style for candidates and facts):

```ruby
    test "the result says it is degraded when a personalized signal raised, and not otherwise" do
      healthy = engine(candidates: [candidate(1, 2.0, rank: 5)], facts: {1 => fact(1)}).call
      assert_equal false, healthy.data[:degraded]

      broken = engine(raise_search: true, ranked: [candidate(1, 0.0, rank: 5)], facts: {1 => fact(1)}).call
      assert broken.success?
      assert broken.data[:degraded]
      assert broken.data[:fallback]
    end

    test "each item carries its global rank position" do
      result = engine(candidates: [candidate(1, 2.0, rank: 37)], facts: {1 => fact(1)}).call
      assert_equal 37, result.data[:items].first[:rank_position]
    end
```

(Use the file's own helper names for building a `Candidate` with a `rank_position` and an `ItemFact`; the names above are illustrative. Read the helpers first.)

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/recommendations/engine_test.rb`
Expected: `degraded` is nil and `rank_position` is nil → failures.

- [ ] **Step 3: Implement the engine fields**

In `app/lib/recommendations/engine.rb`:

- In `initialize`, add `@degraded = false`.
- In the method that guards signal calls (`guarded(name)`), set `@degraded = true` inside its `rescue` before logging.
- In `call`, add `degraded: @degraded` to the `data` hash.
- In `build_items`, add `rank_position: candidate.rank_position` to the item hash.

Run the engine tests: `bin/rails test test/lib/recommendations/engine_test.rb` → pass.

- [ ] **Step 4: Write the failing controller tests**

```ruby
# frozen_string_literal: true

require "test_helper"

class RecommendationsControllerTest < ActionDispatch::IntegrationTest
  # Fixtures: regular_user is a member (regular_user_monthly) and owns empty
  # favorites/read lists; books_viewer_user has no membership and no lists.
  def setup
    host! "dev-new.thegreatestbooks.org"
    @member = users(:regular_user)
    @free = users(:books_viewer_user)
    @books = ::Books::Book.limit(60).to_a
  end

  def give_history(user, book = books_books(:got))
    list = ::Books::UserList.find_or_create_by!(user: user, list_type: :favorites) { |l| l.name = "Favorites" }
    ::UserListItem.create!(user_list: list, listable: book)
  end

  def stub_candidates(books)
    hits = books.each_with_index.map { |b, i| {id: b.id, score: 10.0 - i * 0.01, rank_position: i + 1} }
    ::Search::Books::Search::BookRecommendations.stubs(:call).returns(hits)
    ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).returns(hits)
  end

  test "signed out gets the pitch with no engine call" do
    Recommendations::Engine.expects(:call).never
    get recommendations_path
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_nil @controller.view_assigns["items"]
  end

  test "a signed-in user with no favorites or read books is sent to wizard step 1" do
    sign_in_as @free, stub_auth: true
    get recommendations_path
    assert_redirected_to recommendations_wizard_path(step: 1)
  end

  test "a free account gets the free limit and a member the member limit" do
    give_history(@free)
    give_history(@member)
    stub_candidates(@books)

    sign_in_as @free, stub_auth: true
    get recommendations_path
    assert_response :success
    assert_equal :ok, @controller.view_assigns["state"]
    assert_equal Rails.application.config.x.recommendations[:free_limit], @controller.view_assigns["items"].size
    assert_equal false, @controller.view_assigns["member"]

    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
    assert_equal Rails.application.config.x.recommendations[:member_limit], @controller.view_assigns["items"].size
    assert_equal true, @controller.view_assigns["member"]
  end

  test "the stored depth reaches the engine as a quality floor override" do
    give_history(@member)
    ::Books::RecommendationConfig.create!(user: @member, criteria: {"depth" => "deep"})
    stub_candidates(@books.first(5))
    Recommendations::Engine.expects(:call).with { |args| args[:overrides] == {quality_floor: 0.5} }
      .returns(Recommendations::Engine::Result.new(success?: true, errors: [], data: {items: [], profile: nil, signals_used: [], fallback: false, degraded: false}))
    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
  end

  test "an engine that finds nothing is no_matches, and a broken search is unavailable" do
    give_history(@member)
    sign_in_as @member, stub_auth: true

    ::Search::Books::Search::BookRecommendations.stubs(:call).returns([])
    ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).returns([])
    get recommendations_path
    assert_response :success
    assert_equal :no_matches, @controller.view_assigns["state"]

    ::Search::Books::Search::BookRecommendations.stubs(:call).raises(StandardError, "opensearch down")
    ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).raises(StandardError, "opensearch down")
    get recommendations_path
    assert_response :success
    assert_equal :unavailable, @controller.view_assigns["state"]
  end

  test "a stored category that no longer exists does not break the side panel" do
    give_history(@member)
    ::Books::RecommendationConfig.create!(user: @member, criteria: {"excluded_category_ids" => [999_999]})
    stub_candidates(@books.first(3))
    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
    assert @controller.view_assigns["groups"].any? { |g| g.values.any? { |v| v.include?("999999") } }
  end

  test "a host with no recommendation domain 404s" do
    host! Rails.application.config.domains[:music]
    get recommendations_path
    assert_response :not_found
  end
end
```

- [ ] **Step 5: Run them to verify they fail**

Run: `bin/rails test test/controllers/recommendations_controller_test.rb`
Expected: `NameError`/routing errors (no controller, no routes).

- [ ] **Step 6: Routes**

In `config/routes.rb`, directly after the saved-search routes block (global, no constraint):

```ruby
  # Recommendations (spec 2026-10-07 §2): one controller for every host; the
  # domain comes from Current.domain and a host with no registry entry 404s.
  # `search` and `settings` are declared before `wizard/:step` on purpose.
  get "recommendations", to: "recommendations#show", as: :recommendations
  get "recommendations/search", to: "recommendations#search", as: :recommendations_search
  get "recommendations/settings", to: "recommendations#settings", as: :recommendations_settings
  post "recommendations/settings", to: "recommendations#update_settings"
  post "recommendations/reset", to: "recommendations#reset", as: :recommendations_reset
  get "recommendations/wizard/:step", to: "recommendations#wizard", as: :recommendations_wizard, constraints: {step: /[1-4]/}
```

- [ ] **Step 7: Generate and write the controller**

```bash
bin/rails generate controller Recommendations show --no-helper --no-assets --skip-routes
```

Delete the generated `app/views/recommendations/show.html.erb` placeholder content (the file is rewritten below) and the generated test (replaced by Step 4's file).

`app/controllers/recommendations_controller.rb`:

```ruby
# frozen_string_literal: true

# The recommendation pages (spec §2): results, the four-step wizard, settings.
# Domain-generic in the same way SavedSearchesController is: one set of routes
# on every host, the domain from Current.domain, books-specific data through
# Recommendations::Registry.pages_class_for and books-specific markup in
# app/views/recommendations/<domain>/. Every page varies per user, so nothing
# here is cacheable.
class RecommendationsController < ApplicationController
  include DomainLayout
  include MembershipGated

  layout :resolve_layout

  before_action :require_domain_support!
  before_action :prevent_caching
  before_action :require_signed_in!, except: [:show]
  before_action :require_member!, only: [:update_settings]

  def show
    return render "recommendations/#{domain}/pitch" unless signed_in?
    return redirect_to recommendations_wizard_path(step: 1) unless pages.history?

    @member = current_user.member?
    @limit = @member ? knobs[:member_limit] : knobs[:free_limit]
    result = Recommendations::Engine.call(user: current_user, domain: domain, limit: @limit,
      overrides: config.criteria_object.engine_overrides)
    @items = result.success? ? result.data[:items] : []
    @profile = result.success? ? result.data[:profile] : nil
    @state = if @items.any?
      :ok
    elsif !result.success? || result.data[:degraded]
      :unavailable
    else
      :no_matches
    end
    @reason_names = reason_names(@items)
    @taste_names = @profile ? pages.category_names(@profile.scored_ids) : {}
    @counts = @profile&.counts || {}
    @groups = pages.criteria_groups(config.criteria_object)
  end

  # Tasks 6 and 7 replace these.
  def search
    head :not_found
  end

  def wizard
    head :not_found
  end

  def settings
    head :not_found
  end

  def update_settings
    head :not_found
  end

  def reset
    head :not_found
  end

  private

  def domain
    Current.domain.to_s
  end

  def require_domain_support!
    raise ActiveRecord::RecordNotFound if Recommendations::Registry.pages_class_for(domain).nil? ||
      ::RecommendationConfig.subclass_for(domain).nil?
  end

  def require_member!
    require_membership!(Recommendations::Registry.membership_feature_for(domain))
  end

  def pages
    @pages ||= Recommendations::Registry.pages_class_for(domain).new(user: current_user)
  end

  # Never written on GET: for_user is find_or_initialize_by.
  def config
    @config ||= ::RecommendationConfig.subclass_for(domain).for_user(current_user)
  end

  def knobs
    Rails.application.config.x.recommendations
  end

  # {id => name} for every id the page's reasons mention, two queries at most.
  def reason_names(items)
    by_type = items.group_by { |entry| entry[:reason].type }
    category_ids = by_type.fetch(:interests, []).flat_map { |e| e[:reason].ids }
    item_ids = by_type.fetch(:because_of, []).flat_map { |e| e[:reason].ids }
    pages.category_names(category_ids.uniq).merge(pages.item_names(item_ids.uniq))
  end
end
```

Note `ApplicationController` already rescues `ActiveRecord::RecordNotFound` with the 404 page; `require_membership!` redirects to `membership_path` with an alert for free and signed-out users.

- [ ] **Step 8: Views**

`app/views/recommendations/_alert.html.erb` (an inline alert; public layouts render no flash):

```erb
<% if flash[:alert].present? %>
  <div role="alert" class="alert alert-warning mb-6" data-testid="recommendations-alert"><span><%= flash[:alert] %></span></div>
<% end %>
<% if flash[:notice].present? %>
  <div role="status" class="alert alert-success mb-6" data-testid="recommendations-notice"><span><%= flash[:notice] %></span></div>
<% end %>
```

`app/views/recommendations/show.html.erb`:

```erb
<% content_for :page_title, "Your recommendations" %>
<div class="container mx-auto px-4 py-8">
  <%= render "recommendations/alert" %>
  <div class="flex flex-col lg:flex-row gap-8">
    <main class="flex-1 min-w-0">
      <h1 class="text-3xl font-bold mb-6">Your recommendations</h1>

      <% case @state %>
      <% when :ok %>
        <div class="<%= Books::CardComponent::GRID_CONTAINER_CLASS %>" data-testid="recommendations-grid">
          <% @items.each_with_index do |entry, index| %>
            <div class="flex flex-col gap-2" data-testid="recommendation">
              <%= render Books::CardComponent.new(book: entry[:item], rank: entry[:rank_position], index: index) %>
              <%= render Recommendations::ReasonComponent.new(reason: entry[:reason], names: @reason_names) %>
            </div>
          <% end %>
        </div>
        <% unless @member %>
          <%= render "recommendations/#{Current.domain}/member_pitch", limit: @limit %>
        <% end %>
      <% when :no_matches %>
        <div role="status" class="alert" data-testid="recommendations-empty">
          <span>No books match your settings. <%= link_to "Loosen them", recommendations_settings_path, class: "link" %> or add more books to your lists.</span>
        </div>
      <% else %>
        <div role="alert" class="alert alert-warning" data-testid="recommendations-unavailable">
          <span>Recommendations are unavailable right now. Try again in a few minutes.</span>
        </div>
      <% end %>
    </main>

    <aside class="w-full lg:w-80 shrink-0">
      <%= render "recommendations/#{Current.domain}/side_panel" %>
    </aside>
  </div>
</div>
```

`app/views/recommendations/books/_side_panel.html.erb`:

```erb
<div class="space-y-6">
  <section class="card bg-base-200">
    <div class="card-body">
      <h2 class="card-title text-lg">Your settings</h2>
      <% if @groups.empty? %>
        <p class="text-sm text-base-content/70">Default settings: every ranked book, balanced depth.</p>
      <% else %>
        <dl class="space-y-2 text-sm">
          <% @groups.each do |group| %>
            <div>
              <dt class="font-semibold"><%= group.label %></dt>
              <dd class="[overflow-wrap:anywhere]"><%= group.values.join(", ") %><% if group.note %> <span class="text-base-content/60">(<%= group.note %>)</span><% end %></dd>
            </div>
          <% end %>
        </dl>
      <% end %>
      <div class="card-actions mt-4 flex-col items-stretch gap-2">
        <%= link_to "Change settings", recommendations_settings_path, class: "btn btn-sm btn-outline", data: {testid: "settings-link"} %>
        <%= link_to "Walk through the wizard", recommendations_wizard_path(step: 1), class: "btn btn-sm btn-ghost" %>
        <%= button_to "Reset everything", recommendations_reset_path, method: :post, class: "btn btn-sm btn-ghost text-error",
              form: {data: {turbo_confirm: "Reset your recommendation settings? Your lists and ratings stay."}}, data: {testid: "reset-button"} %>
      </div>
    </div>
  </section>

  <% if @profile && !@profile.empty? %>
    <section class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-lg">Your taste</h2>
        <%= render Recommendations::TasteComponent.new(profile: @profile, names: @taste_names) %>
      </div>
    </section>
  <% end %>
</div>
```

`app/views/recommendations/books/_member_pitch.html.erb` (local `limit`):

```erb
<section class="card bg-base-200 mt-10" data-testid="member-pitch">
  <div class="card-body items-center text-center">
    <h2 class="card-title">Want the full list?</h2>
    <p class="max-w-prose">Free accounts see <%= limit %> recommendations on the default settings. Members get <%= Rails.application.config.x.recommendations[:member_limit] %> at a time and can tune the length, era, genres and depth.</p>
    <div class="card-actions">
      <%= link_to "Become a member", membership_path, class: "btn btn-primary" %>
    </div>
  </div>
</section>
```

`app/views/recommendations/books/_pitch.html.erb` (signed-out; copy is a draft, Task 8 runs it through `avoid-ai-writing`):

```erb
<% content_for :page_title, "Book recommendations" %>
<div class="container mx-auto max-w-3xl px-4 py-10 space-y-10">
  <header class="text-center">
    <h1 class="text-3xl font-bold mb-4">Book recommendations built from what you have actually read</h1>
    <p class="text-lg text-base-content/80">Tell us your favorites, what you have read and how you rated it. We match that against every ranked book on the site and show you what fits, with a reason for each one.</p>
  </header>

  <section class="card bg-base-200">
    <div class="card-body">
      <h2 class="card-title">How it works</h2>
      <ul class="list-disc pl-5 space-y-2">
        <li><strong>Your favorites</strong> carry the most weight. They tell us which genres, subjects and settings you come back to.</li>
        <li><strong>Your ratings</strong> sharpen it. Four and five stars push a book's traits up; one and two stars push them down.</li>
        <li><strong>Your reading history</strong> keeps us from recommending books you already know.</li>
        <li><strong>Your settings</strong> let you exclude genres, cap by rank, pick lengths and eras, and choose safer bets or deeper cuts.</li>
      </ul>
    </div>
  </section>

  <section class="text-center">
    <p class="mb-4">A free account gets <%= Rails.application.config.x.recommendations[:free_limit] %> recommendations. Members get <%= Rails.application.config.x.recommendations[:member_limit] %> and every setting.</p>
    <button class="btn btn-primary btn-lg" onclick="login_modal.showModal()" data-testid="pitch-sign-in">Sign in or create an account</button>
  </section>
</div>
```

- [ ] **Step 9: Run the controller, component and frame tests**

Run: `bin/rails test test/controllers/recommendations_controller_test.rb test/components/recommendations/ test/lib/recommendations/`
Expected: all pass, including the progress component tests from Task 3 (routes now exist). If `books_viewer_user` lacks a books favorites list, `give_history` creates one; `::Books::UserList` may require a `name`, hence the block.

- [ ] **Step 10: Lint, zeitwerk, commit**

```bash
bundle exec standardrb app/controllers/recommendations_controller.rb app/lib/recommendations config/routes.rb test/controllers/recommendations_controller_test.rb test/lib/recommendations
CI=1 bin/rails zeitwerk:check
git add config/routes.rb app/controllers/recommendations_controller.rb app/views/recommendations app/lib/recommendations/engine.rb test/controllers/recommendations_controller_test.rb test/lib/recommendations/engine_test.rb
git commit -m "Add the recommendations results page, pitch and gating"
```

---

### Task 5: Nav entry and the membership story link

**Files:**
- Modify: `web-app/app/views/books/shared/_nav_links.html.erb` (both variants, after "Saved Searches")
- Modify: `web-app/app/views/membership/_story_books.html.erb`
- Test: `web-app/test/controllers/books/layout_test.rb` (add one test) and `web-app/test/controllers/membership_controller_test.rb` (add one test; create the assertion in whichever membership controller test exists)

**Interfaces:**
- Consumes: `recommendations_path` (Task 4).
- Produces: a "Recommendations" link in the My Books menu on desktop and mobile; one sentence in the books membership story linking to `/recommendations`.

- [ ] **Step 1: Write the failing tests**

In `test/controllers/books/layout_test.rb` (follow its existing setup; it already requests a books page):

```ruby
  test "the My Books menu links to recommendations in both nav variants" do
    get "/"
    assert_response :success
    assert_select "#navbar_my_books a[href='/recommendations']", minimum: 2
  end
```

In the membership controller test (e.g. `test/controllers/membership_controller_test.rb`, books host):

```ruby
  test "the books story links to the recommendations pitch" do
    host! "dev-new.thegreatestbooks.org"
    get membership_path
    assert_response :success
    assert_select "a[href='/recommendations']"
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/books/layout_test.rb test/controllers/membership_controller_test.rb`
Expected: `assert_select` failures.

- [ ] **Step 3: Implement**

In `_nav_links.html.erb`, add after each `Saved Searches` `<li>` (lines ~49 and ~62):

```erb
          <li><%= link_to "Recommendations", recommendations_path %></li>
```

In `app/views/membership/_story_books.html.erb`, append one paragraph at the end:

```erb
<p>Members also get the full set of <%= link_to "personalized recommendations", recommendations_path %>: fifty at a time, with every setting unlocked.</p>
```

- [ ] **Step 4: Run the tests, lint, commit**

Run: `bin/rails test test/controllers/books/layout_test.rb test/controllers/membership_controller_test.rb test/lint/`
Expected: pass (the daisyUI lint still clean).

```bash
git add app/views/books/shared/_nav_links.html.erb app/views/membership/_story_books.html.erb test/controllers
git commit -m "Link recommendations from the My Books menu and the membership story"
```

---

### Task 6: The wizard (steps 1–3), the search frame, and the step gate

**Files:**
- Modify: `web-app/app/controllers/recommendations_controller.rb` (`wizard`, `search`)
- Create: `web-app/app/views/recommendations/wizard.html.erb`, `search.html.erb`, `books/_step_1.html.erb`, `books/_step_2.html.erb`, `books/_step_3.html.erb`, `books/_search_form.html.erb`, `books/_book_row.html.erb`
- Test: `web-app/test/controllers/recommendations_controller_test.rb`

**Interfaces:**
- Consumes: `Pages#favorites`, `#read_books`, `#unrated_read`, `#rated`, `#list`, `#search`, `#history?`; `ProgressComponent`; `Books::CardComponent.new(book:, rank:, index:)` (renders its own list widget); `Reviews::WidgetComponent.new(reviewable:, review:)`; `Reviews::StarsComponent.new(rating:, size:, label:)`; `my_list_path(id)`, `books_my_goodreads_imports_path`.
- Produces: `GET /recommendations/wizard/:step` renders `wizard.html.erb` with `@step`, `@unlocked` (history?), and per step `@favorites`, `@read`, `@unrated`, `@rated`; step 4 is Task 7's (`@config`, `@locked`). `GET /recommendations/search?q=` renders the frame `wizard_search_results` (`target: "_top"`) with up to 12 cards; blank `q` renders the frame with a prompt and makes no search call.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/recommendations_controller_test.rb`:

```ruby
  test "wizard steps 1 and 2 render for any signed-in user" do
    sign_in_as @free, stub_auth: true
    get recommendations_wizard_path(step: 1)
    assert_response :success
    assert_equal 1, @controller.view_assigns["step"]
    get recommendations_wizard_path(step: 2)
    assert_response :success
  end

  test "steps 3 and 4 need a favorite or read book and bounce to step 2 with an alert" do
    sign_in_as @free, stub_auth: true
    get recommendations_wizard_path(step: 3)
    assert_redirected_to recommendations_wizard_path(step: 2)
    assert flash[:alert].present?
    get recommendations_wizard_path(step: 4)
    assert_redirected_to recommendations_wizard_path(step: 2)

    give_history(@free)
    get recommendations_wizard_path(step: 3)
    assert_response :success
    assert_equal [books_books(:got)], @controller.view_assigns["unrated"]
  end

  test "a step outside 1-4 is not routable" do
    sign_in_as @free, stub_auth: true
    assert_raises(ActionController::RoutingError) { get "/recommendations/wizard/5" }
  end

  test "the wizard is signed-in only" do
    get recommendations_wizard_path(step: 1)
    assert_response :redirect
  end

  test "search renders the frame of cards and skips the search for a blank query" do
    sign_in_as @free, stub_auth: true
    ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: books_books(:got).id.to_s, score: 1.0, source: {}}])
    get recommendations_search_path(q: "thrones")
    assert_response :success
    assert_select "turbo-frame#wizard_search_results[target='_top']"
    assert_equal [books_books(:got)], @controller.view_assigns["books"]

    ::Search::Books::Search::BookGeneral.expects(:call).never
    get recommendations_search_path(q: "   ")
    assert_response :success
    assert_equal [], @controller.view_assigns["books"]

    get recommendations_search_path(q: "x" * 2000)
    assert_response :success
  end

  test "no link inside the wizard search frame is trapped" do
    sign_in_as @free, stub_auth: true
    ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: books_books(:got).id.to_s, score: 1.0, source: {}}])
    assert_no_frame_trapped_links recommendations_search_path(q: "thrones")
  end

  test "step 3 lists rated books with their reviews" do
    give_history(@member, books_books(:war_and_peace))
    list = ::Books::UserList.find_by!(user: @member, list_type: :read)
    ::UserListItem.create!(user_list: list, listable: books_books(:war_and_peace))
    sign_in_as @member, stub_auth: true
    get recommendations_wizard_path(step: 3)
    assert_response :success
    rated = @controller.view_assigns["rated"]
    assert_equal books_books(:war_and_peace), rated.first.first
    assert_equal 5, rated.first.last.rating
  end
```

`BookGeneral.call` is what `Books::BookSearchQuery` calls; `source` may need the keys `BookSearchQuery.hydrate` reads — check `app/lib/books/book_search_query.rb` and match the stub shape used in `test/controllers/books/searches_controller_test.rb`.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/recommendations_controller_test.rb`
Expected: the new tests fail with 404s from the placeholder actions.

- [ ] **Step 3: Controller actions**

Replace the `search` and `wizard` placeholders:

```ruby
  WIZARD_STEPS = (1..4)
  GATED_STEPS = (3..4)
  NEEDS_HISTORY_ALERT = "Add a favorite book or a book you have read before rating books or setting preferences."

  def wizard
    @step = params[:step].to_i
    @unlocked = pages.history?
    if GATED_STEPS.cover?(@step) && !@unlocked
      return redirect_to recommendations_wizard_path(step: 2), alert: NEEDS_HISTORY_ALERT
    end

    case @step
    when 1 then @favorites = pages.favorites
    when 2 then @read = pages.read_books
    when 3
      @unrated = pages.unrated_read
      @rated = pages.rated
    when 4
      @config = config
      @locked = !current_user.member?
      @picked_categories = picked_categories(@config.criteria_object)
    end
  end

  def search
    @query = params[:q].to_s.strip.first(200)
    @books = @query.blank? ? [] : pages.search(@query)
    render layout: false
  end
```

Add the private helper (used by Task 7 as well):

```ruby
  # The category records behind the stored include/exclude ids, for the
  # picker's prerendered chips. One query; a missing id simply has no chip.
  def picked_categories(criteria)
    ids = criteria.included_category_ids + criteria.excluded_category_ids
    ids.empty? ? {} : ::Books::Category.where(id: ids).index_by(&:id)
  end
```

(`::Books::Category` in a domain-generic controller is the one books-specific line; move it onto `Pages` as `picked_categories(criteria)` if the reviewer prefers, and call `pages.picked_categories`.)

- [ ] **Step 4: Views**

`app/views/recommendations/wizard.html.erb`:

```erb
<% content_for :page_title, "Recommendation wizard, step #{@step}" %>
<div class="container mx-auto max-w-5xl px-4 py-8">
  <header class="text-center mb-6">
    <h1 class="text-3xl font-bold">Your next great read</h1>
    <p class="text-base-content/70">Four short steps. Each one makes the recommendations better.</p>
  </header>
  <%= render Recommendations::ProgressComponent.new(current_step: @step, unlocked: @unlocked) %>
  <%= render "recommendations/alert" %>
  <%= render "recommendations/#{Current.domain}/step_#{@step}" %>
</div>
```

`app/views/recommendations/books/_search_form.html.erb` (locals: `label`):

```erb
<div class="space-y-4" data-testid="wizard-search">
  <%= form_with url: recommendations_search_path, method: :get, data: {turbo_frame: "wizard_search_results"}, class: "join w-full" do |f| %>
    <%= f.search_field :q, placeholder: "Search by title or author", class: "input join-item flex-1", autocomplete: "off", "aria-label": label %>
    <button type="submit" class="btn btn-primary join-item"><%= label %></button>
  <% end %>
  <%= turbo_frame_tag "wizard_search_results", target: "_top" %>
</div>
```

`app/views/recommendations/search.html.erb` (rendered without layout; the frame id matches):

```erb
<%= turbo_frame_tag "wizard_search_results", target: "_top" do %>
  <% if @query.blank? %>
    <p class="text-sm text-base-content/70">Type a title or an author to find a book.</p>
  <% elsif @books.empty? %>
    <p class="text-sm text-base-content/70" data-testid="wizard-search-empty">No books match "<%= @query %>".</p>
  <% else %>
    <p class="text-sm text-base-content/70">Use "Add to list" on a card to put it on a list.</p>
    <div class="<%= Books::CardComponent::GRID_CONTAINER_CLASS %>" data-testid="wizard-search-results">
      <% @books.each_with_index do |book, index| %>
        <%= render Books::CardComponent.new(book: book, rank: book.ranked_position, index: index) %>
      <% end %>
    </div>
  <% end %>
<% end %>
```

`app/views/recommendations/books/_book_row.html.erb` (locals: `book`, `trailing` optional block-less HTML passed as `trailing:`):

```erb
<li class="flex items-center justify-between gap-4 py-2 border-b border-base-300 last:border-b-0" data-testid="wizard-book-row">
  <div class="min-w-0">
    <%= link_to book.title, book_path(book), class: "link link-hover font-medium [overflow-wrap:anywhere]" %>
    <div class="text-sm text-base-content/70"><%= book.book_authors.map { |ba| ba.author.name }.join(", ") %></div>
  </div>
  <% if local_assigns[:trailing] %><div class="shrink-0"><%= trailing %></div><% end %>
</li>
```

(Use the same book path helper `Books::CardComponent` uses; read `card_component.rb` for its name and copy it.)

`_step_1.html.erb`:

```erb
<div class="grid gap-8 lg:grid-cols-3">
  <section class="lg:col-span-2 space-y-6">
    <h2 class="text-2xl font-semibold">Step 1: your favorite books</h2>
    <p>Your favorites tell us more than anything else. They carry the most weight, so start here.</p>

    <% if @favorites.total.zero? %>
      <div class="alert" data-testid="favorites-empty"><span>No favorites yet. Search below and add a few.</span></div>
    <% else %>
      <p class="font-medium"><%= pluralize(@favorites.total, "favorite") %> so far.</p>
      <ul class="max-h-96 overflow-y-auto" data-testid="favorites-list">
        <% @favorites.books.each do |book| %>
          <%= render "recommendations/books/book_row", book: book %>
        <% end %>
      </ul>
      <% if (list = @pages_favorites_list ||= @controller.send(:pages).list(:favorites)) %>
        <p class="text-sm text-base-content/70">To reorder or remove favorites, open <%= link_to "your favorites list", my_list_path(list), class: "link" %>.</p>
      <% end %>
    <% end %>

    <%= render "recommendations/books/search_form", label: "Find a book" %>
  </section>

  <aside class="space-y-4">
    <div class="card bg-base-200"><div class="card-body">
      <h3 class="card-title text-lg">Why favorites matter</h3>
      <p>They show which genres, subjects and places you return to, and the writing you prefer. The more you add, the sharper the match.</p>
    </div></div>
    <%= link_to "Continue to step 2", recommendations_wizard_path(step: 2), class: "btn btn-primary w-full", data: {testid: "wizard-next"} %>
  </aside>
</div>
```

Replace the `@controller.send(:pages)` line with a controller-assigned `@favorites_list = pages.list(:favorites)` in `wizard` step 1 (views must not reach into the controller); the snippet above shows the intent, the implementation assigns it in the action.

`_step_2.html.erb`:

```erb
<div class="grid gap-8 lg:grid-cols-3">
  <section class="lg:col-span-2 space-y-6">
    <h2 class="text-2xl font-semibold">Step 2: what you have read</h2>
    <p>Books you have read show us patterns, and they are never recommended back to you.</p>

    <div class="alert alert-info" data-testid="goodreads-callout">
      <span>Have a Goodreads account? <%= link_to "Import your shelves", books_my_goodreads_imports_path, class: "link" %> and this step fills itself.</span>
    </div>

    <% if @read.total.zero? %>
      <div class="alert"><span>Nothing on your read list yet. Search below and add what you remember.</span></div>
    <% else %>
      <p class="font-medium"><%= pluralize(@read.total, "book") %> read<% if @read.total > @read.books.size %>, showing the latest <%= @read.books.size %><% end %>.</p>
      <ul class="max-h-[32rem] overflow-y-auto" data-testid="read-list">
        <% @read.books.each do |book| %>
          <%= render "recommendations/books/book_row", book: book %>
        <% end %>
      </ul>
    <% end %>

    <%= render "recommendations/books/search_form", label: "Find a book" %>
  </section>

  <aside class="space-y-4">
    <div class="card bg-base-200"><div class="card-body">
      <h3 class="card-title text-lg">Why history matters</h3>
      <p>It keeps books you know off the page and shows us which authors and series you follow.</p>
    </div></div>
    <% if @unlocked %>
      <%= link_to "Continue to step 3", recommendations_wizard_path(step: 3), class: "btn btn-primary w-full", data: {testid: "wizard-next"} %>
    <% else %>
      <button class="btn btn-primary w-full" disabled data-testid="wizard-next">Continue to step 3</button>
      <p class="text-sm text-warning">Add a favorite or a read book first.</p>
    <% end %>
    <%= link_to "Back to step 1", recommendations_wizard_path(step: 1), class: "btn btn-ghost w-full" %>
  </aside>
</div>
```

`_step_3.html.erb`:

```erb
<div class="grid gap-8 lg:grid-cols-3">
  <section class="lg:col-span-2 space-y-6">
    <h2 class="text-2xl font-semibold">Step 3: rate what you have read</h2>
    <p>Four and five stars push a book's traits up. One and two stars push them down. A three changes nothing.</p>

    <% if @unrated.empty? %>
      <div class="alert alert-success" data-testid="unrated-empty"><span>Everything on your read list is rated.</span></div>
    <% else %>
      <p class="font-medium"><%= pluralize(@unrated.size, "book") %> without a rating.</p>
      <ul data-testid="unrated-list">
        <% @unrated.each do |book| %>
          <%= render "recommendations/books/book_row", book: book,
                trailing: render(Reviews::WidgetComponent.new(reviewable: book)) %>
        <% end %>
      </ul>
    <% end %>

    <% if @rated.any? %>
      <h3 class="text-xl font-semibold mt-8">Already rated</h3>
      <ul data-testid="rated-list">
        <% @rated.each do |book, review| %>
          <%= render "recommendations/books/book_row", book: book,
                trailing: render(Reviews::StarsComponent.new(rating: review.rating, size: "size-4", label: "#{review.rating} stars")) %>
        <% end %>
      </ul>
    <% end %>
  </section>

  <aside class="space-y-4">
    <div class="card bg-base-200"><div class="card-body">
      <h3 class="card-title text-lg">Why ratings matter</h3>
      <p>They tell us which of your read books to learn from most, and which to learn from in reverse.</p>
    </div></div>
    <%= link_to "Continue to step 4", recommendations_wizard_path(step: 4), class: "btn btn-primary w-full", data: {testid: "wizard-next"} %>
    <%= link_to "Back to step 2", recommendations_wizard_path(step: 2), class: "btn btn-ghost w-full" %>
  </aside>
</div>
```

Check `Reviews::StarsComponent.new` keyword names against `app/components/reviews/stars_component.rb` before using them; the `Reviews::WidgetComponent` reads the current user's review client-side, so passing `review:` is optional.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/recommendations_controller_test.rb test/lint/`
Expected: pass. The frame-trapped guard passes because the frame's `target="_top"` releases the card links.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/controllers/recommendations_controller.rb test/controllers/recommendations_controller_test.rb
git add app/controllers/recommendations_controller.rb app/views/recommendations test/controllers/recommendations_controller_test.rb
git commit -m "Add wizard steps 1-3 and the Turbo-frame book search"
```

---

### Task 7: Preferences form, settings page, saving, reset, and the locked form

**Files:**
- Modify: `web-app/app/controllers/recommendations_controller.rb` (`settings`, `update_settings`, `reset`, strong params)
- Create: `web-app/app/views/recommendations/settings.html.erb`, `books/_step_4.html.erb`, `books/_settings_form.html.erb`
- Test: `web-app/test/controllers/recommendations_controller_test.rb`

**Interfaces:**
- Consumes: `RecommendationConfig#criteria=`, `#save`, `#destroy`, `#persisted?`; `Books::RecommendationConfig.criteria_params_class.call(permitted)`; `Books::RecommendationCriteria` readers + `#depth`; `::Books::Book.book_lengths`; `saved_search_categories_path` and the `saved-search-picker` Stimulus controller (values `url`, `name`, `max`; targets `query`, `results`, `chips`); `Category#name_with_type`; `membership_path`.
- Produces: `GET /recommendations/settings` (`@config`, `@locked`, `@picked_categories`); `POST /recommendations/settings` (members only) saves and redirects to `recommendations_path` with a notice, or 422 re-render; `POST /recommendations/reset` destroys the row and redirects to wizard step 1 (303). Form field names: `recommendation_config[criteria][depth]`, `[book_length][]`, `[max_ranked_position]`, `[first_year_published_gt]`, `[first_year_published_lt]`, `[included_category_ids][]`, `[excluded_category_ids][]`, `[genre_match_mode]`.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/recommendations_controller_test.rb`:

```ruby
  def settings_params(overrides = {})
    {recommendation_config: {criteria: {
      depth: "deep", max_ranked_position: "250", book_length: ["1", "2"],
      first_year_published_gt: "1900", excluded_category_ids: [categories(:books_politics_subject).id.to_s],
      genre_match_mode: "all"
    }.merge(overrides)}}
  end

  test "the settings page is locked for a free account and editable for a member" do
    sign_in_as @free, stub_auth: true
    get recommendations_settings_path
    assert_response :success
    assert_equal true, @controller.view_assigns["locked"]

    sign_in_as @member, stub_auth: true
    get recommendations_settings_path
    assert_response :success
    assert_equal false, @controller.view_assigns["locked"]
  end

  test "a free account cannot save settings even by hand" do
    sign_in_as @free, stub_auth: true
    assert_no_difference "RecommendationConfig.count" do
      post recommendations_settings_path, params: settings_params
    end
    assert_redirected_to membership_path
  end

  test "a member saves settings and lands on the results" do
    give_history(@member)
    sign_in_as @member, stub_auth: true
    assert_difference "RecommendationConfig.count", 1 do
      post recommendations_settings_path, params: settings_params
    end
    assert_redirected_to recommendations_path
    criteria = ::Books::RecommendationConfig.for_user(@member).criteria
    assert_equal "deep", criteria["depth"]
    assert_equal 250, criteria["max_ranked_position"]
    assert_equal [1, 2], criteria["book_length"]
    assert_equal [categories(:books_politics_subject).id], criteria["excluded_category_ids"]
    assert_equal "all", criteria["genre_match_mode"]
    assert_nil criteria["ranked"], "ranked never enters the stored criteria"
  end

  test "saving balanced depth clears a stored depth" do
    ::Books::RecommendationConfig.create!(user: @member, criteria: {"depth" => "deep"})
    sign_in_as @member, stub_auth: true
    post recommendations_settings_path, params: settings_params(depth: "balanced")
    assert_nil ::Books::RecommendationConfig.for_user(@member).criteria["depth"]
  end

  test "criteria posted as a string is a 422, not a 500" do
    sign_in_as @member, stub_auth: true
    post recommendations_settings_path, params: {recommendation_config: {criteria: "garbage"}}
    assert_response :unprocessable_entity
  end

  test "reset destroys the config and returns to step 1" do
    ::Books::RecommendationConfig.create!(user: @member, criteria: {"depth" => "deep"})
    sign_in_as @member, stub_auth: true
    assert_difference "RecommendationConfig.count", -1 do
      post recommendations_reset_path
    end
    assert_redirected_to recommendations_wizard_path(step: 1)
    assert_response :see_other
  end

  test "reset with no stored config is harmless" do
    sign_in_as @free, stub_auth: true
    assert_no_difference "RecommendationConfig.count" do
      post recommendations_reset_path
    end
    assert_redirected_to recommendations_wizard_path(step: 1)
  end

  test "the settings form skips a stored category that no longer exists" do
    ::Books::RecommendationConfig.create!(user: @member, criteria: {"included_category_ids" => [999_999]})
    sign_in_as @member, stub_auth: true
    get recommendations_settings_path
    assert_response :success
    assert_equal({}, @controller.view_assigns["picked_categories"])
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/controllers/recommendations_controller_test.rb`
Expected: the new tests fail (placeholder actions answer 404).

- [ ] **Step 3: Controller actions**

Replace the `settings`, `update_settings` and `reset` placeholders:

```ruby
  def settings
    @step = 4
    @config = config
    @locked = !current_user.member?
    @picked_categories = picked_categories(@config.criteria_object)
  end

  def update_settings
    permitted = criteria_params
    if permitted.nil?
      @step = 4
      @config = config
      @locked = false
      @picked_categories = picked_categories(@config.criteria_object)
      return render :settings, status: :unprocessable_entity
    end

    config.criteria = config.class.criteria_params_class.call(permitted)
    if config.save
      redirect_to recommendations_path, notice: "Settings saved."
    else
      @step = 4
      @config = config
      @locked = false
      @picked_categories = picked_categories(@config.criteria_object)
      render :settings, status: :unprocessable_entity
    end
  end

  def reset
    config.destroy if config.persisted?
    redirect_to recommendations_wizard_path(step: 1), status: :see_other, notice: "Settings reset. Start again from your favorites."
  end
```

And the strong params (private):

```ruby
  CRITERIA_PARAMS = [:genre_match_mode, :first_year_published_gt, :first_year_published_lt, :max_ranked_position, :depth,
    {book_length: [], included_category_ids: [], excluded_category_ids: []}].freeze

  # nil when the criteria is not a hash (a hand-rolled `criteria=x` would
  # otherwise raise on permit and 500), so the caller can answer 422.
  def criteria_params
    raw = params.fetch(:recommendation_config, {})[:criteria]
    return {} if raw.nil?
    return nil unless raw.respond_to?(:permit)

    raw.permit(*CRITERIA_PARAMS)
  end
```

`params.fetch(:recommendation_config, {})` returns a Parameters object when the key is present; when absent `{}` has no `[:criteria]` → `nil` → `{}` (an empty save, which clears every setting; that is the "reset to defaults" path a blank form produces and is intended).

- [ ] **Step 4: Views**

`app/views/recommendations/books/_settings_form.html.erb` (locals: `config`, `locked`, `picked_categories`):

```erb
<% criteria = config.criteria_object %>
<% knobs = Rails.application.config.x.recommendations %>

<% if locked %>
  <div role="note" class="alert alert-info mb-6" data-testid="settings-locked">
    <span>🔒 Settings are a member feature. Free accounts get <%= knobs[:free_limit] %> recommendations on the defaults; members get <%= knobs[:member_limit] %> and every setting below.</span>
    <%= link_to "Become a member", membership_path, class: "btn btn-primary btn-sm" %>
  </div>
<% end %>

<%= form_with model: config, url: recommendations_settings_path, scope: :recommendation_config, method: :post,
      id: "recommendation-settings-form", class: "space-y-6", data: {turbo: false} do |f| %>
  <fieldset class="space-y-6 <%= "opacity-70" if locked %>" <%= "disabled" if locked %> data-testid="settings-fields">
    <%= f.fields_for :criteria, criteria do |c| %>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Depth</legend>
        <% Recommendations::Books::Pages::DEPTH_LABELS.each do |value, label| %>
          <label class="label cursor-pointer justify-start gap-3">
            <%= c.radio_button :depth, value, checked: criteria.depth == value, class: "radio" %>
            <span><%= label %></span>
          </label>
        <% end %>
        <p class="text-sm text-base-content/70">Safer bets lean toward the best-known books that fit you. Deep cuts go further down the ranking.</p>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Book length</legend>
        <div class="flex flex-wrap gap-4">
          <% ::Books::Book.book_lengths.each do |key, value| %>
            <label class="label cursor-pointer gap-2">
              <%= check_box_tag "recommendation_config[criteria][book_length][]", value, criteria.book_length.include?(value), id: nil, class: "checkbox checkbox-sm" %>
              <span><%= key.to_s.titleize %></span>
            </label>
          <% end %>
        </div>
        <p class="text-sm text-base-content/70">Leave every box empty for any length.</p>
      </fieldset>

      <fieldset class="fieldset">
        <%= c.label :max_ranked_position, "Only the top N ranked books", class: "fieldset-legend" %>
        <%= c.number_field :max_ranked_position, value: criteria.max_ranked_position, min: 1, max: 20_000, class: "input w-full", placeholder: "Any rank" %>
      </fieldset>

      <div class="grid gap-4 sm:grid-cols-2">
        <fieldset class="fieldset">
          <%= c.label :first_year_published_gt, "Published from", class: "fieldset-legend" %>
          <%= c.number_field :first_year_published_gt, value: criteria.first_year_published_gt, class: "input w-full", placeholder: "1837" %>
        </fieldset>
        <fieldset class="fieldset">
          <%= c.label :first_year_published_lt, "Published to", class: "fieldset-legend" %>
          <%= c.number_field :first_year_published_lt, value: criteria.first_year_published_lt, class: "input w-full", placeholder: "<%= Date.current.year %>" %>
        </fieldset>
      </div>

      <% [["included", "Only books with these categories", criteria.included_category_ids],
          ["excluded", "Never these categories", criteria.excluded_category_ids]].each do |kind, legend, ids| %>
        <fieldset class="fieldset" data-controller="saved-search-picker"
                  data-saved-search-picker-url-value="<%= saved_search_categories_path %>"
                  data-saved-search-picker-name-value="recommendation_config[criteria][<%= kind %>_category_ids][]"
                  data-testid="picker-<%= kind %>">
          <legend class="fieldset-legend"><%= legend %></legend>
          <%= hidden_field_tag "recommendation_config[criteria][#{kind}_category_ids][]", "", id: nil %>
          <div class="relative">
            <input type="search" class="input w-full" placeholder="Search genres, subjects, settings" autocomplete="off"
                   data-saved-search-picker-target="query"
                   data-action="input->saved-search-picker#search keydown->saved-search-picker#suppressEnter">
            <div class="hidden absolute dropdown-content p-2 shadow-lg bg-base-100 rounded-box w-full mt-1 max-h-80 overflow-y-auto z-[9999] left-0 top-full flex flex-col gap-1"
                 data-saved-search-picker-target="results"></div>
          </div>
          <div class="flex flex-wrap gap-2 mt-2" data-saved-search-picker-target="chips">
            <% ids.each do |id| %>
              <% record = picked_categories[id] %>
              <% next if record.nil? %>
              <span class="badge badge-outline gap-1" data-chip="<%= id %>">
                <%= hidden_field_tag "recommendation_config[criteria][#{kind}_category_ids][]", id, id: nil %>
                <span><%= record.name_with_type %></span>
                <button type="button" class="btn btn-ghost btn-xs px-1" data-action="saved-search-picker#remove" aria-label="Remove <%= record.name %>">×</button>
              </span>
            <% end %>
          </div>
        </fieldset>
      <% end %>

      <fieldset class="fieldset">
        <%= c.label :genre_match_mode, "When several categories are included", class: "fieldset-legend" %>
        <%= c.select :genre_match_mode, [["A book needs any one of them", "any"], ["A book needs all of them", "all"]],
              {selected: criteria.genre_match_mode.to_s}, {class: "select w-full"} %>
      </fieldset>
    <% end %>
  </fieldset>

  <div class="flex flex-wrap gap-3">
    <% if locked %>
      <%= link_to "Become a member to save settings", membership_path, class: "btn btn-primary", data: {testid: "settings-join"} %>
    <% else %>
      <%= f.submit "Save settings", class: "btn btn-primary", data: {testid: "settings-save"} %>
    <% end %>
    <%= link_to "View my recommendations", recommendations_path, class: "btn btn-outline", data: {testid: "settings-view"} %>
  </div>
<% end %>
```

Copy the picker markup from `app/views/saved_searches/books/_criteria_fields.html.erb` exactly where this plan's version differs, keeping the `name-value` and the `recommendation_config[...]` names. `data: {turbo: false}` on the form is deliberate: the 422 path re-renders a full page and Turbo would otherwise require a turbo-stream.

`app/views/recommendations/books/_step_4.html.erb`:

```erb
<div class="grid gap-8 lg:grid-cols-3">
  <section class="lg:col-span-2 space-y-6">
    <h2 class="text-2xl font-semibold">Step 4: your preferences</h2>
    <p>Optional. The defaults already work; these narrow the page to what you want.</p>
    <%= render "recommendations/books/settings_form", config: @config, locked: @locked, picked_categories: @picked_categories %>
  </section>
  <aside class="space-y-4">
    <div class="card bg-base-200"><div class="card-body">
      <h3 class="card-title text-lg">About these settings</h3>
      <p>They filter the pool before it is ranked. Exclusions always win; a book with an excluded category never appears.</p>
      <p>Not sure? Leave everything blank and come back later from the results page.</p>
    </div></div>
    <%= link_to "Back to step 3", recommendations_wizard_path(step: 3), class: "btn btn-ghost w-full" %>
    <%= button_to "Reset everything", recommendations_reset_path, method: :post, class: "btn btn-ghost w-full text-error",
          form: {data: {turbo_confirm: "Reset your recommendation settings? Your lists and ratings stay."}}, data: {testid: "reset-button"} %>
  </aside>
</div>
```

`app/views/recommendations/settings.html.erb`:

```erb
<% content_for :page_title, "Recommendation settings" %>
<div class="container mx-auto max-w-3xl px-4 py-8 space-y-6">
  <%= render "recommendations/alert" %>
  <h1 class="text-3xl font-bold">Recommendation settings</h1>
  <%= render "recommendations/books/settings_form", config: @config, locked: @locked, picked_categories: @picked_categories %>
</div>
```

(`settings.html.erb` names the books partial directly; make it `"recommendations/#{Current.domain}/settings_form"` so a second domain only adds a partial.)

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/recommendations_controller_test.rb test/lint/ test/components/recommendations/`
Expected: pass.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/controllers/recommendations_controller.rb test/controllers/recommendations_controller_test.rb
git add app/controllers/recommendations_controller.rb app/views/recommendations test/controllers/recommendations_controller_test.rb
git commit -m "Add the preferences form, settings page, saving and reset"
```

---

### Task 8: Copy pass, feature doc, and Playwright coverage

**Files:**
- Modify: `web-app/app/views/recommendations/books/_pitch.html.erb`, `_step_1..4.html.erb`, `_member_pitch.html.erb` (copy only)
- Modify: `docs/features/recommendations.md` (new "Pages" section; update "Known gaps")
- Create: `web-app/e2e/tests/books/recommendations-pitch.spec.ts`, `web-app/e2e/tests/books/account/recommendations-locked.spec.ts`, `web-app/e2e/tests/books/member/recommendations.spec.ts`

**Interfaces:**
- Consumes: every `data-testid` named in Tasks 4–7 (`recommendations-grid`, `recommendation`, `recommendation-reason`, `member-pitch`, `settings-locked`, `settings-join`, `settings-save`, `settings-fields`, `wizard-search`, `wizard-search-results`, `wizard-next`, `review-widget-label` (existing), `reset-button`, `pitch-sign-in`); `#user_list_modal` and `#review_modal` (existing layout dialogs); `bin/rails e2e:member`.
- Produces: three specs, placement-selected accounts, cleanup before and after.

- [ ] **Step 1: Copy pass**

Invoke the `avoid-ai-writing` skill in edit-in-place mode on the six partials above with the "warm" voice. Keep every `data-testid`, helper call and limit interpolation unchanged; only prose changes. Re-run `bin/rails test test/controllers/recommendations_controller_test.rb test/lint/` afterwards.

- [ ] **Step 2: Feature doc**

Add to `docs/features/recommendations.md`, before "## Harness", a section:

```markdown
## Pages

Routes are global (`/recommendations`, `/recommendations/wizard/1..4`, `/recommendations/search`,
`/recommendations/settings`, `/recommendations/reset`); `RecommendationsController` resolves the
domain from `Current.domain`, 404s on a host with no `Registry` entry, and never caches. Books data
for the pages comes from `Recommendations::Books::Pages` (shelves for the wizard, the search box,
names behind ids, the settings summary); books markup lives in `app/views/recommendations/books/`.

| Visitor | `/recommendations` | Settings form |
|---|---|---|
| Signed out | pitch | — |
| Free account | `free_limit` results, side panel, member pitch | rendered, every field disabled, "Become a member" replaces Save; the POST is refused server-side (`require_membership!(:book_recommendations)`) |
| Member | `member_limit` results | editable |

A signed-in user with no favorite and no read book is sent to wizard step 1; steps 3 and 4 bounce
to step 2 until one exists. Steps 1 and 2 search through `GET /recommendations/search`, a Turbo
frame (`target: "_top"`) of `Books::CardComponent` cards whose list widget adds the book. Step 3
rates through `Reviews::WidgetComponent`. The results page shows `rank_position` on each card and
one `Recommendations::ReasonComponent` line beneath; `@state` is `:ok`, `:no_matches` (engine
succeeded, nothing matched) or `:unavailable` (a signal raised: `data[:degraded]`).

**Depth** is the one setting the spec did not list: stored as `criteria["depth"]` (`safe` or
`deep`; balanced stores nothing) and mapped by `RecommendationCriteria#engine_overrides` to
`quality_floor` through the `depth_floors` knob. Measured in
`docs/data-quality/recommendations-2026-10-08.md`.
```

In "Known gaps", remove "No pages yet" and "No 'deep cuts' setting yet"; add:

```markdown
- The wizard's "add" is the list widget's modal (pick a list), not a one-click add; the spec's
  "one click" is two.
- Results run the engine on every request (~15 queries + the OpenSearch call + ~110 ms
  calibration); no caching, by design, since the page is per-user.
```

- [ ] **Step 3: E2E specs**

`e2e/tests/books/recommendations-pitch.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('Recommendations, signed out', () => {
  test('shows the pitch with a sign-in button', async ({ page }) => {
    await page.goto('/recommendations');
    await expect(page.getByRole('heading', { level: 1 })).toContainText(/recommendations/i);
    await page.getByTestId('pitch-sign-in').click();
    await expect(page.locator('#login_modal')).toBeVisible();
  });
});
```

`e2e/tests/books/account/recommendations-locked.spec.ts` (the admin account is deliberately a non-member):

```ts
import { test, expect } from '@playwright/test';

test.describe('Recommendation settings, as a free account', () => {
  test('the form is locked and offers membership instead of save', async ({ page }) => {
    await page.goto('/recommendations/settings');
    await expect(page.getByTestId('settings-locked')).toBeVisible();
    await expect(page.locator('[data-testid="settings-fields"][disabled]')).toHaveCount(1);
    await expect(page.getByTestId('settings-join')).toHaveAttribute('href', /\/membership$/);
    await expect(page.getByTestId('settings-save')).toHaveCount(0);
  });

  test('the My Books menu links to recommendations', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#navbar_my_books a[href="/recommendations"]').first()).toBeAttached();
  });
});
```

`e2e/tests/books/member/recommendations.spec.ts` (serial; the member account is comped by `bin/rails e2e:member`; it must have no favorites, read books or reviews of BOOK before the run, and the spec restores that):

```ts
import { test, expect, type Page } from '@playwright/test';

// A real book on the dev database with no migrated reviews, like reviews-write.spec.ts.
const BOOK_TITLE = 'Headlong Hall';
const BOOK_PATH = '/book/headlong-hall';

async function untickEveryList(page: Page) {
  await page.goto(BOOK_PATH);
  const card = page.locator('[data-listable-type="Books::Book"]').first();
  await card.getByRole('button', { name: /Add to list|On \d+ list/i }).click();
  const modal = page.locator('#user_list_modal');
  await expect(modal).toBeVisible();
  for (const box of await modal.getByRole('checkbox').all()) {
    if (await box.isChecked()) {
      await box.uncheck();
      await expect(box).not.toBeChecked();
    }
  }
  await page.keyboard.press('Escape');
}

async function removeReview(page: Page) {
  await page.goto(BOOK_PATH);
  await page.getByTestId('review-widget-label').click();
  await expect(page.locator('#review_modal')).toBeVisible();
  const remove = page.getByTestId('review-remove');
  if (await remove.isVisible()) {
    await remove.click();
    await expect(page.locator('#review_modal')).not.toBeVisible();
  } else {
    await page.locator('#review_modal').press('Escape');
  }
}

async function resetSettings(page: Page) {
  await page.goto('/recommendations/settings');
  // The results side panel and step 4 carry the reset button; settings does not, so go via step 4.
  await page.goto('/recommendations/wizard/4');
  const reset = page.getByTestId('reset-button');
  if (await reset.isVisible()) {
    await reset.click();
    await expect(page).toHaveURL(/\/recommendations\/wizard\/1$/);
  }
}

test.describe.configure({ mode: 'serial' });

test.describe('Recommendations, as a member', () => {
  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    page.on('dialog', (d) => d.accept());
    await untickEveryList(page);
    await removeReview(page);
    await page.close();
  });

  test.afterAll(async ({ browser }) => {
    const page = await browser.newPage();
    page.on('dialog', (d) => d.accept());
    await resetSettings(page);
    await removeReview(page);
    await untickEveryList(page);
    await page.close();
  });

  test.beforeEach(async ({ page }) => {
    page.on('dialog', (d) => d.accept());
  });

  test('step 1: search for a book and add it to favorites', async ({ page }) => {
    await page.goto('/recommendations/wizard/1');
    await page.getByTestId('wizard-search').getByRole('searchbox').fill(BOOK_TITLE);
    await page.getByTestId('wizard-search').getByRole('button', { name: 'Find a book' }).click();
    const results = page.getByTestId('wizard-search-results');
    await expect(results).toBeVisible();
    const card = results.locator('[data-listable-type="Books::Book"]').first();
    await card.getByRole('button', { name: /Add to list/i }).click();
    const modal = page.locator('#user_list_modal');
    await expect(modal).toBeVisible();
    const favorites = modal.getByRole('checkbox', { name: /favorite/i }).first();
    await favorites.check();
    await expect(favorites).toBeChecked();
    await page.keyboard.press('Escape');

    await page.reload();
    await expect(page.getByTestId('favorites-list')).toContainText(BOOK_TITLE);
  });

  test('step 3: rate the favorite', async ({ page }) => {
    await page.goto('/recommendations/wizard/3');
    // Headlong Hall is a favorite, not a read book, so it is not in the unrated list;
    // add it to the read list from the book page first so step 3 has a row to rate.
    await page.goto(BOOK_PATH);
    const card = page.locator('[data-listable-type="Books::Book"]').first();
    await card.getByRole('button', { name: /Add to list|On \d+ list/i }).click();
    const modal = page.locator('#user_list_modal');
    const read = modal.getByRole('checkbox', { name: /^read$|books i.ve read|have read/i }).first();
    await read.check();
    await expect(read).toBeChecked();
    await page.keyboard.press('Escape');

    await page.goto('/recommendations/wizard/3');
    const row = page.getByTestId('unrated-list').locator('[data-testid="wizard-book-row"]', { hasText: BOOK_TITLE });
    await row.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal')).toBeVisible();
    await page.getByTestId('review-star-button').nth(3).click();
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await page.reload();
    await expect(page.getByTestId('rated-list')).toContainText(BOOK_TITLE);
  });

  test('step 4: save deep cuts and land on the results', async ({ page }) => {
    await page.goto('/recommendations/wizard/4');
    await page.getByLabel('Deep cuts').check();
    await page.getByTestId('settings-save').click();
    await expect(page).toHaveURL(/\/recommendations$/);
    await expect(page.getByTestId('recommendations-grid')).toBeVisible();
    await expect(page.getByTestId('recommendation').first()).toBeVisible();
    await expect(page.getByTestId('recommendation-reason').first()).not.toBeEmpty();
    await expect(page.getByTestId('member-pitch')).toHaveCount(0);
    await expect(page.locator('aside')).toContainText('Deep cuts');
  });

  test('the settings page is editable for a member', async ({ page }) => {
    await page.goto('/recommendations/settings');
    await expect(page.getByTestId('settings-save')).toBeVisible();
    await expect(page.locator('[data-testid="settings-fields"][disabled]')).toHaveCount(0);
    await expect(page.getByLabel('Deep cuts')).toBeChecked();
  });
});
```

The checkbox labels in `#user_list_modal` come from the member account's list names; the implementer verifies them on the dev database (`bin/rails runner 'puts Books::UserList.where(user: User.find_by(email: ENV["PLAYWRIGHT_MEMBER_EMAIL"])).pluck(:name, :list_type)'`) and adjusts the two regexes. The results assertion needs the local dev OpenSearch index populated (it is; the 2026-10-08 record rebuilt it).

- [ ] **Step 4: Run the E2E specs**

Build and start the app, confirm the port, run the three files:

```bash
yarn build:all
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1); [ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
bin/rails server -d
bin/rails e2e:member
yarn test:e2e -- tests/books/recommendations-pitch.spec.ts tests/books/account/recommendations-locked.spec.ts tests/books/member/recommendations.spec.ts
```

Expected: all green. If the port belongs to another checkout, stop and report rather than killing it.

- [ ] **Step 5: Full gate and commit**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
git add app/views/recommendations docs/features/recommendations.md e2e/tests/books
git commit -m "Recommendation pages: copy pass, feature doc, Playwright coverage"
```

---

## Self-review

**Spec coverage.** §2 paths: all six routes (Task 4). §2.1 steps 1–4 with embedded widgets, the step-3 gate, the Goodreads link (Tasks 6–7). §2.2 grid with rank and reason, side panel (settings summary, taste block, counts, links, reset), unavailable/no-match states (Task 4). §2.3 gate registration, free/member limits, locked form, server-side rejection (Tasks 1, 4, 7). §2.4 nav in both variants, story link, copy pass (Tasks 5, 8). §2.5 nothing ported. §3 global routes, registry, 404 on other hosts, per-domain partials (Tasks 1, 4). §5.5 unavailable state from the degraded flag (Task 4). §8.3 reason component (Task 3). §10 controller, component and Playwright coverage (every task). Not covered on purpose: a visual companion for the wizard layout (the layout copies the legacy 2/3 + 1/3 shape).

**Placeholders.** None: every step has code. Two "verify against the codebase" notes remain by design (the `Reviews::StarsComponent` keywords, the modal checkbox labels), both with the command to check.

**Type consistency.** `Pages#favorites`/`#read_books` return `StepBooks(books:, total:)`, used as such in steps 1–2; `#rated` returns `[[book, review]]`, used in step 3 and asserted in the controller test; `#criteria_groups` returns `Group(label:, values:, note:)`, read by `_side_panel`; `engine_overrides` returns `{quality_floor:}` and the controller test expects exactly that; `@state` symbols match between controller and view; the `data-testid`s used in Task 8 are all declared in Tasks 4–7.

**Review Focus.** 1 → Task 7 ("cannot save settings even by hand"); 2 → Task 4 (`:no_matches` test); 3 → Task 4 (side panel) and Task 7 (settings chips); 4 → Task 6 (blank and 2,000-char query); 5 → Task 7 (`criteria: "garbage"` → 422); 6 → Task 3 (missing name fallback).
