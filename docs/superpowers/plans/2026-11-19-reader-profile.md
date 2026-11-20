# Reader Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A books profile page for every signed-in reader at `/my/profile`, and an opt-in public version at `/profiles/:id` showing only the sections the owner switched on.

**Architecture:** One service, `Services::Books::Profiles::Build`, computes a plain data object on request for an audience (`:owner` or `:public`); both pages render it with the same ViewComponents. The own page is never cached. The public page is cached at the edge only for 10 minutes and purged synchronously when the owner hides something. New storage is one table, `books_profiles`, added in phase 2.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, daisyUI 5.7 / Tailwind 4, Sidekiq, Playwright. All commands run from `web-app/`.

**Spec:** `docs/superpowers/specs/2026-11-19-reader-profile-design.md` — read it before any task.

## Global Constraints

- Books host only. Routes go inside the books host constraint block in `config/routes.rb`, next to `my/reading-goals` (around line 836).
- Never commit to `main`. Work on branch `reader-profile` in a worktree made with the `EnterWorktree` tool. Do not push or open a PR without asking the owner. Phase 1 and phase 2 are separate PRs.
- Use Rails generators for every model, controller, component and job (`bin/rails generate component ...`, `generate controller ...`, `generate model ...`). Never hand-create them.
- Run annotaterb with the migration (`bin/rails db:migrate` does it). Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Delete only annotation lines for columns this branch's `schema.rb` lacks.
- Services live in `app/lib/services/books/profiles/`, use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`, and hold all logic. Models hold validations and associations only.
- daisyUI 5 only: `stats`/`stat`, `card`, `progress`, `badge`, `avatar avatar-placeholder`. Check anything unfamiliar against `docs/external-libraries/daisyui-llms.txt`. None of the ten removed v4 classes. No meaning carried by colour alone.
- Controller tests assert behaviour (status, headers, assigns, records), never markup or copy. Check real fixture names before using them. Minitest 6: `assert_nil`, never `assert_equal nil`.
- Public page: catalog books only (`Books::Book.catalog`), `noindex`, not in sitemaps, identical for every viewer, no prompts, no empty sections.
- Never derive a displayed name from an email address.
- Exact values from the spec: favorites 8, reading now 4, recently read 8, highest rated 8, recent reviews 3, recommendations 6, genres 5, subjects 8, taste minimum 10 books, display name 2–40 characters, edge cache 600 seconds, trailing window 12 months.
- Before claiming a phase done: `bin/rails test`, `bundle exec standardrb`, and the Playwright spec for that phase (confirm port 3000 is this checkout's first, per AGENTS.md).

## Review Focus

1. **A reader with tens of thousands of read books** (one account has 24,563). The page must issue a fixed number of queries regardless of library size or shelf length. Test in Task 1 (query count does not grow with items) and a manual timing in Task 3.
2. **A reader missing default lists, or with ratings on books that are on no list.** Every section returns its empty value; nothing raises. Test in Task 1.
3. **A list item whose book is provisional or gone.** Own page shows provisional books; public page omits them from shelves, counts and ratings; a missing book is skipped. Tests in Tasks 1 and 6.
4. **A display name that is whitespace, 1 character, 41 characters, or contains markup.** Rejected or stripped by the model; rendered escaped. Test in Task 5; rendering assertion in Task 8.
5. **A profile switched public → private → public, and a visit to a private profile's URL.** 404 with `no-store` for everyone, owner included; the purge runs on the hiding save and the page works again after re-publishing. Tests in Tasks 7 and 9.

Also pinned: the recommendation engine failing or raising must not fail the page (Task 3).

---

## File structure

```
app/lib/services/books/profiles/
  library.rb        # list shelves, stats, ratings, reviews, goals — SQL only
  taste.rb          # genres/subjects via Recommendations::ProfileBuilder
  recommended.rb    # recommendations card state + items
  build.rb          # orchestrates the three for an audience; owns the data structs
  cached_urls.rb    # phase 2: public URLs to purge
  save_settings.rb  # phase 2: settings write + purge
app/components/books/profiles/   # header, stat_tiles, shelf_card, goal_card,
                                 # taste_card, reviews_card, recommendations_card
app/controllers/books/my/profiles_controller.rb   # show; phase 2: settings, update_settings, preview
app/controllers/books/profiles_controller.rb      # phase 2: public show
app/views/books/profiles/_dashboard.html.erb      # the shared grid, takes `data`
app/models/books/profile.rb                       # phase 2
docs/features/reader-profile.md
```

---

# Phase 1 — own profile

### Task 0: Branch and documents

- [ ] Enter a worktree named `reader-profile` with `EnterWorktree`.
- [ ] Copy the spec and this plan into it if they are not there (they were written uncommitted on `main`), and commit both: `git commit -m "Reader profile: design and plan"`.

### Task 1: Library queries

**Files:**
- Create: `app/lib/services/books/profiles/library.rb`
- Test: `test/lib/services/books/profiles/library_test.rb`
- Modify: `test/fixtures/users.yml` — add `profile_reader` and `profile_empty_reader`, copying the shape of `regular_user`, with no list, review or goal fixtures pointing at them.

**Interfaces — Produces:**

```ruby
module Services::Books::Profiles
  class Library
    Shelf = Struct.new(:books, :total, :list, keyword_init: true)       # books: [Books::Book] in display order
    Stats = Struct.new(:books_read, :read_last_12_months, :average_rating,
                       :ratings_count, :reviews_count, keyword_init: true) # each nil when there is nothing to count
    RatedBook = Struct.new(:book, :rating, keyword_init: true)
    GoalProgress = Struct.new(:goal, :count, :bar_percentage, :days_left, keyword_init: true)

    def initialize(user:, catalog_only:, today: Date.current)
    def stats           # => Stats
    def favorites       # => Shelf, first 8 in list position order
    def reading_now     # => Shelf, up to 4
    def recently_read   # => Shelf, 8: completed_on DESC NULLS LAST, then user_list_items.created_at DESC
    def top_rated       # => [RatedBook], 8: rating DESC, then reviews.created_at DESC
    def recent_reviews  # => [Review], 3 with a body, newest first, reviewable preloaded
    def goals           # => [GoalProgress] for Books::ReadingGoal.owned_by(user).active_on(today)
  end
end
```

Rules the signatures do not show:
- `Stats#books_read` counts `read`-list items; `nil` when 0. `read_last_12_months` counts read items with `completed_on` in `(today - 12.months + 1.day)..today`; `nil` when 0. `average_rating` is the mean rating rounded to one decimal; `nil` with no ratings. `ratings_count`/`reviews_count` (`body` present) are `nil` when 0.
- `catalog_only: true` restricts every method, counts included, to `Books::Book.catalog`. Goals use `ReadingGoals::ProgressQuery.call(goal:, catalog_only:)`; `days_left` is `(goal.ends_on - today).to_i`.
- A missing list yields `Shelf.new(books: [], total: 0, list: nil)`. A list item whose book no longer exists is skipped.
- Books are loaded with `Books::UserList.listable_display_includes`. No per-book queries.

- [ ] **Step 1: Write the failing tests.** Build data in each test for `users(:profile_reader)` with `Books::UserList.create!(user:, list_type:, name:)`, `user_list_items.create!(listable: books(...), position:, completed_on:)` and `Review.create!`. Use real `books.yml` fixture names.

```ruby
test "stats count read books, dated reads in the trailing 12 months, and ratings"
  # 3 read items: completed today, completed 13 months ago, undated; 2 ratings (4.0, 5.0), one with a body
  assert_equal [3, 1, 4.5, 2, 1], stats.to_a

test "stats are nil, not zero, when there is nothing to count"
  assert_equal [nil, nil, nil, nil, nil], Library.new(user: users(:profile_empty_reader), catalog_only: false).stats.to_a

test "a dated read exactly 12 months ago today is outside the window; one day later is inside"

test "favorites follow list position and stop at 8"          # 9 items -> 8 books, total 9
test "recently_read puts dated reads newest first, then undated by newest added"
test "top_rated orders by rating then most recently rated and stops at 8"
test "recent_reviews returns only reviews with a body, newest first, at most 3"
test "goals returns only goals active today with count and days_left"
test "a user with no lists at all gets empty shelves and no error"      # profile_empty_reader
test "a rating on a book that is on no list still counts in ratings and top_rated"
test "catalog_only hides a provisional book from shelves, counts, ratings and reviews"
  # mark one read+rated book provisional: true -> books_read drops by 1, absent from every list
test "catalog_only false keeps the provisional book"
test "query count does not grow with shelf size"
  # count SQL for favorites with 2 items vs 8 items via ActiveSupport::Notifications "sql.active_record"; assert equal
```

- [ ] **Step 2:** Run `bin/rails test test/lib/services/books/profiles/library_test.rb` — expect failures for the missing constant.
- [ ] **Step 3:** Implement `Library`.
- [ ] **Step 4:** Run the test file — expect PASS. Run `bundle exec standardrb`.
- [ ] **Step 5:** Commit: `Reader profile: library queries`.

### Task 2: Taste

**Files:**
- Create: `app/lib/services/books/profiles/taste.rb`
- Test: `test/lib/services/books/profiles/taste_test.rb`

**Interfaces — Produces:**

```ruby
module Services::Books::Profiles
  class Taste
    MIN_BOOKS = 10
    MAX_GENRES = 5
    MAX_SUBJECTS = 8
    Data = Struct.new(:ready, :qualifying_count, :genres, :subjects, keyword_init: true)
    # genres: [[Category, Float 0.0..1.0]] strongest first, scaled so the first is 1.0
    # subjects: [Category] strongest first
    def self.call(user:)   # => Data
  end
end
```

Approach: build the profile exactly as `Recommendations::Engine#build_profile` does, with `adapter = Recommendations::Books::Adapter.new(config: Recommendations::Config.resolve)`, `interactions = adapter.interactions(user)` and `Recommendations::ProfileBuilder.call(interactions:, categories: adapter.categories_for(ids), catalog_size: adapter.catalog_size, type_category_ids: adapter.type_category_ids, config:)`. `qualifying_count` is the number of interactions whose `kind` is `:favorite` or `:read`, or whose `rating` is present; `:reading`, `:want_to_read` do not count. `ready` is `qualifying_count >= MIN_BOOKS && (genres.any? || subjects.any?)`. When not ready, skip the builder and return empty arrays. Load categories in one query; drop ids that no longer resolve.

- [ ] **Step 1: Write the failing tests** (stub `Recommendations::Books::Adapter#interactions` and `ProfileBuilder.call` with Mocha; use real category fixtures).

```ruby
test "not ready below 10 qualifying books and reports the count"
  # 9 :read interactions + 5 :want_to_read -> ready false, qualifying_count 9, builder never called
test "reading and want_to_read do not count; favorite, read and rated-only do"
test "ready returns at most 5 genres scaled to the strongest and at most 8 subjects"
  # profile genres [[g1, 2.0], [g2, 1.0]] -> [[g1, 1.0], [g2, 0.5]]
test "ready is false when the profile has no genres and no subjects"
test "a category id that no longer exists is dropped"
```

- [ ] **Steps 2–5:** fail, implement, pass + standardrb, commit `Reader profile: taste`.

### Task 3: Recommendations card and the build service (owner)

**Files:**
- Create: `app/lib/services/books/profiles/recommended.rb`, `app/lib/services/books/profiles/build.rb`
- Test: `test/lib/services/books/profiles/recommended_test.rb`, `test/lib/services/books/profiles/build_test.rb`

**Interfaces — Consumes:** `Library`, `Taste` as above.

**Interfaces — Produces:**

```ruby
module Services::Books::Profiles
  class Recommended
    LIMIT = 6
    Data = Struct.new(:state, :books, keyword_init: true)   # state: :ok | :no_history | :unavailable
    def self.call(user:)   # => Data; never raises
  end

  class Build
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)
    Header = Struct.new(:name, :member_since_year, keyword_init: true)   # name nil => "Your profile"
    Data = Struct.new(:audience, :header, :stats, :favorites, :goals, :reading_now, :taste,
                      :recently_read, :top_rated, :recent_reviews, :recommendations, keyword_init: true)
    def self.call(user:, audience:, profile: nil, today: Date.current)   # => Result, data: Data
  end
end
```

Rules:
- `Recommended`: `:no_history` when `Recommendations::Books::Pages.new(user:).history?` is false. Otherwise call `Recommendations::Engine.call(user:, domain: "books", limit: 6, overrides: RecommendationConfig.subclass_for("books").for_user(user).criteria_object.engine_overrides)`; `:ok` with `result.data[:items].map { _1[:item] }` when there are items; `:unavailable` for a failed result, an empty item list, or any `StandardError` (log it).
- `Build` with `audience: :owner`: every section is present (possibly empty); `header.name` is `user.display_name.presence`; `recommendations` is set. Phase 2 adds `:public`; until then raise `ArgumentError` for any other audience.

- [ ] **Step 1: Write the failing tests.**

```ruby
# recommended_test.rb
test "no_history when the user has no favorites, reads or ratings"
test "ok with up to 6 books from the engine"                 # stub Engine.call
test "unavailable when the engine result fails"
test "unavailable when the engine returns no items"
test "unavailable, not an exception, when the engine raises"  # Engine.stubs(:call).raises(RuntimeError)
test "passes the user's stored engine overrides"

# build_test.rb
test "owner data has every section and the header name from users.display_name"
test "owner header name is nil when the user has no display name"   # never the email
test "member_since_year is the year of users.created_at"
test "an empty account builds successfully with empty sections"     # profile_empty_reader
test "an unknown audience raises ArgumentError"
```

- [ ] **Steps 2–4:** fail, implement, pass + standardrb.
- [ ] **Step 5: Measure.** In `bin/rails runner`, time `Build.call(user: <the user with the most read items>, audience: :owner)` three times and record the result in the commit message. If it exceeds 1 second, wrap `Taste.call` in `Rails.cache.fetch(["books-profile-taste", user.id], expires_in: 1.hour)` and add a test that a second call does not invoke the builder. Read-only: no writes to the dev database.
- [ ] **Step 6:** Commit: `Reader profile: recommendations card and build service`.

### Task 4: Own profile page

**Files:**
- Create (generators): `app/controllers/books/my/profiles_controller.rb`; components under `app/components/books/profiles/`: `Header`, `StatTiles`, `ShelfCard`, `GoalCard`, `TasteCard`, `ReviewsCard`, `RecommendationsCard`
- Create: `app/views/books/my/profiles/show.html.erb`, `app/views/books/profiles/_dashboard.html.erb`
- Modify: `config/routes.rb` (books block), `app/views/books/shared/_nav_links.html.erb` (both variants, first entry under "My Books")
- Test: `test/controllers/books/my/profiles_controller_test.rb`, one component test per component

**Interfaces — Consumes:** `Build.call(user: current_user, audience: :owner)`.

**Interfaces — Produces:**
- Route `get "my/profile", to: "books/my/profiles#show", as: :books_my_profile`.
- Controller follows `Books::My::ReadingGoalsController`: `include Cacheable`, `layout "books/application"`, `before_action :prevent_caching`, `before_action :require_signed_in!`. Assigns `@profile_data`.
- `_dashboard.html.erb` takes local `data` and renders: header, stat tile row (`stats`), then a `grid grid-cols-1 md:grid-cols-2 gap-4` of cards in the spec's order. Every component takes the section's struct plus `audience:` and is the only place that decides between content, an owner prompt, and nothing.
- Component contract, both audiences: with `audience: :owner`, an empty primary card (Favorites, Goal, Taste, Recent reviews, Recommendations) renders a dashed card (`card card-dash`) with one sentence and one link; empty secondary blocks (Highest rated, Reading now) render nothing; a `nil` stat renders a dash; a `nil` `read_last_12_months` adds an "Add finish dates" link to the read list; recommendations `:no_history` links to `recommendations_wizard_path(step: 1)`, `:unavailable` renders nothing. With `audience: :public`, a `nil` or empty section and a `nil` stat render nothing at all (`render?` returns false).
- "See all" targets for the owner: `my_list_path(list)`, `my_reviews_path`, `books_my_reading_goals_path`, `recommendations_path`. Subject and genre names link to the books category page (find the helper with `bin/rails routes -g categor`).
- Taste not ready: the card says how many qualifying books there are out of 10.
- Header: name or "Your profile"; avatar is `avatar avatar-placeholder` with the name's first letter, or a generic user icon when there is no name; "Member since <year>".
- Covers: render as `app/components/books/card_component` does; reuse it if it fits at shelf size.
- User-entered text (review bodies, goal names) gets `[overflow-wrap:anywhere]`.

- [ ] **Step 1: Write the failing tests.**

```ruby
# controller
test "signed out is sent through the usual sign-in handling"   # same expectation as books_my_reading_goals_path signed out
test "renders for a reader with data and is no-store"
  assert_response :success
  assert_includes response.headers.fetch("Cache-Control"), "no-store"
  assert_equal :owner, @controller.view_assigns.fetch("profile_data").audience
test "renders for an empty account"                            # profile_empty_reader -> :success
test "renders when the recommendation engine raises"           # Recommendations::Engine.stubs(:call).raises -> :success
test "is not routable on the music host"                       # 404

# components (render_inline; assert on render?/presence via data-testid, not copy)
test "stat tiles: owner gets a tile for a nil stat, public does not"
test "shelf card: owner + empty primary renders the prompt card; public + empty does not render"
test "shelf card: secondary and empty does not render for either audience"
test "taste card: not ready shows progress for owner, nothing for public"
test "recommendations card: unavailable does not render; no_history renders the prompt"
```

- [ ] **Steps 2–4:** fail, implement, pass. Also run `bin/rails test test/lint/` (daisyUI v4 class lint) and `bundle exec standardrb`.
- [ ] **Step 5:** `yarn build:all`, start `bin/rails server`, open the page signed in as a reader with data and as one without, at phone and desktop widths, and fix what looks wrong. Do not restart a healthy server that belongs to another checkout.
- [ ] **Step 6:** Commit: `Reader profile: own profile page`.

### Task 5: E2E and feature doc (phase 1)

**Files:**
- Create: `e2e/tests/books/account/profile.spec.ts`, `docs/features/reader-profile.md`

- [ ] **Step 1:** Playwright spec in the signed-in `account` project: open `/my/profile` from the "My Books" menu; the heading, the stat row and the Favorites card are visible; a "See all" link reaches the list page. The empty-account render is covered by the Task 4 controller test, because the three E2E accounts are not empty.
- [ ] **Step 2:** Confirm port 3000 serves this checkout, then `yarn test:e2e e2e/tests/books/account/profile.spec.ts` — expect PASS.
- [ ] **Step 3:** Write `docs/features/reader-profile.md`: what each section means, the empty-state rules, where the code lives. No per-class documentation.
- [ ] **Step 4:** `bin/rails test` and `bundle exec standardrb` — both clean, no new warnings.
- [ ] **Step 5:** Commit: `Reader profile: E2E and feature doc`. Tell the owner phase 1 is ready and the branch is unpushed; ask before pushing or opening the PR.

---

# Phase 2 — sharing

### Task 6: `Books::Profile`

**Files:**
- Create (generator): `bin/rails generate model Books::Profile` → migration, `app/models/books/profile.rb`, `test/models/books/profile_test.rb`, `test/fixtures/books/profiles.yml`
- Modify: `app/models/user.rb`

**Interfaces — Produces:**
- Table `books_profiles`: `user_id` bigint, not null, **unique** index, FK; `public` boolean, default false, not null; `display_name` string; and eight booleans, default false, not null: `show_stats`, `show_favorites`, `show_goals`, `show_reading_now`, `show_taste`, `show_recently_read`, `show_top_rated`, `show_reviews`.
- `Books::Profile`: `belongs_to :user`; `SECTIONS = %i[stats favorites goals reading_now taste recently_read top_rated reviews].freeze`; `def show?(section)` reads `show_<section>`; `display_name` is stripped before validation (internal whitespace runs squished), length 2..40 and presence required only when `public`; uniqueness on `user_id`.
- `User`: `has_one :books_profile, class_name: "Books::Profile", dependent: :destroy`.
- Fixtures: `public_profile` (user `profile_reader`, public, display name "Avid Reader", all eight switches true) and `private_profile` (user `profile_empty_reader`, not public).

- [ ] **Step 1: Write the failing tests.**

```ruby
test "a private profile needs no display name"
test "a public profile requires a display name of 2 to 40 characters"   # nil, " ", "A", "A"*41 invalid; "Al", "A"*40 valid
test "display name is stripped and squished"                             # "  Al   B " -> "Al B"
test "one profile per user"
test "show? reads the matching switch and defaults to false"
test "destroying the user destroys the profile"
```

- [ ] **Step 2:** fail. **Step 3:** write the migration, `bin/rails db:migrate` (annotaterb runs; check the annotation diff), implement the model. **Step 4:** pass + standardrb.
- [ ] **Step 5:** Commit migration, schema, model, annotations, fixtures together: `Reader profile: books_profiles`.

### Task 7: Public audience in the build service

**Files:**
- Modify: `app/lib/services/books/profiles/build.rb`
- Test: `test/lib/services/books/profiles/build_test.rb`

**Interfaces — Produces:** `Build.call(user:, audience: :public, profile:)`:
- `profile` is required; `ArgumentError` without it.
- `Library` is built with `catalog_only: true`. `Taste` is unchanged (same calculation as the owner's, by the owner's decision).
- A section whose switch is off is `nil` **and its query method is never called**. A section that is on but empty is also `nil`. `stats` is `nil` when `show_stats` is off or every stat is `nil`. `taste` is `nil` unless ready. `recommendations` is always `nil` and `Recommended` is never called.
- `header.name` is `profile.display_name`. Never `users.display_name`.
- `Library::Shelf#list` and `GoalProgress#goal` stay on the structs; add `Data#linkable?(record)` → `audience == :owner || record&.public?`, which the components use to decide whether to render "See all". On the public page the targets are `user_list_path(list)` and `books_reading_goal_path(goal)`; the reviews "See all" is never shown publicly.

- [ ] **Step 1: Write the failing tests.**

```ruby
test "public requires a profile"
test "a switched-off section is nil and is never queried"
  # all switches off except favorites; Library.any_instance.expects(:top_rated).never (and stats, goals, ...); Taste.expects(:call).never
test "a switched-on but empty section is nil"
test "public never builds recommendations"                    # Recommended.expects(:call).never
test "public uses catalog-only data"                           # provisional favorite absent; books_read excludes it
test "public header uses the profile display name, not the account one"
test "linkable? is true for the owner, and for public only when the list or goal is public"
test "with every switch off the data is the header alone"
```

- [ ] **Steps 2–4:** fail, implement, pass + standardrb. **Step 5:** Commit: `Reader profile: public audience`.

### Task 8: Saving settings and purging

**Files:**
- Create: `app/lib/services/books/profiles/cached_urls.rb`, `app/lib/services/books/profiles/save_settings.rb`
- Modify: `app/models/books/profile.rb` (one destroy callback)
- Test: `test/lib/services/books/profiles/cached_urls_test.rb`, `test/lib/services/books/profiles/save_settings_test.rb`, `test/models/books/profile_test.rb`

**Interfaces — Produces:**

```ruby
Services::Books::Profiles::CachedUrls.call(profile:)
# => ["https://<host>/profiles/<id>", ...] one per host in Rails.application.config.domains[:books] (comma-separated), like ReadingGoals::CachedUrls

Services::Books::Profiles::SaveSettings.call(user:, attributes:)
# => Result, data: {profile:, persisted:, purge_confirmed:}   # purge_confirmed: true | false | nil
```

Rules for `SaveSettings`:
- `find_or_initialize_by(user:)`, assign, save. Invalid → `success?: false, persisted: false`, model errors.
- **Hiding save** = the profile was public before the save and, after it, is not public, or any switch went true → false, or `display_name` changed. After commit, purge `CachedUrls` synchronously with `Cloudflare::PurgeService.new.purge_urls(:books, urls)`, exactly as `ReadingGoals::SaveGoal#revoke_public_cache` does: with no `CLOUDFLARE_CACHE_PURGE_TOKEN` outside production return `purge_confirmed: true`; on a failed or raising purge log `[ALERT] Books profile <id> hid content but cache revocation failed: <error>`, enqueue `Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls)` and return `success?: false, persisted: true, purge_confirmed: false`.
- Any other save of a profile that is public after it: enqueue the job (so newly shown sections appear promptly), `purge_confirmed: nil`.
- A save of a profile that was and stays private: no purge.
- Do not copy `SaveGoal`'s owner-row lock or its open-transaction refusal; they guard goal count windows that profiles do not have.
- Model: `after_destroy_commit` enqueues the purge job for a profile that was public (this is the account-deletion path; a cascade cannot wait on a confirmed purge).

- [ ] **Step 1: Write the failing tests** (stub `Cloudflare::PurgeService` with Mocha; set the token env in the tests that need the real path).

```ruby
test "cached_urls returns the profile URL on every books host"
test "creates the profile on first save"
test "invalid attributes do not persist and return the model errors"
test "making a public profile private purges synchronously and confirms"
test "switching one section off on a public profile purges synchronously"
test "changing the display name on a public profile purges synchronously"
test "switching a section on enqueues the job and does not purge synchronously"
test "a private profile staying private purges nothing"
test "a failed purge keeps the save, enqueues the job, and reports purge_confirmed false"
test "a raising purge is handled the same way"
test "publishing a private profile enqueues the job"
test "private -> public -> private purges on the second hide"
test "destroying a public profile enqueues the purge; a private one does not"
```

- [ ] **Steps 2–4:** fail, implement, pass + standardrb. **Step 5:** Commit: `Reader profile: settings save and cache purge`.

### Task 9: Settings, preview and the public page

**Files:**
- Modify: `app/controllers/books/my/profiles_controller.rb`, `app/controllers/concerns/cacheable.rb`, `config/routes.rb`, `app/components/books/profiles/header_component.*`, `app/views/books/my/profiles/show.html.erb`
- Create (generator): `app/controllers/books/profiles_controller.rb`
- Create: `app/views/books/my/profiles/settings.html.erb`, `app/views/books/my/profiles/preview.html.erb`, `app/views/books/profiles/show.html.erb`
- Test: `test/controllers/books/my/profiles_controller_test.rb`, `test/controllers/books/profiles_controller_test.rb`

**Interfaces — Consumes:** `Build` (`:public`), `SaveSettings`, `Books::Profile`.

**Interfaces — Produces:**
- Routes (books block): `get "my/profile/settings"` → `books/my/profiles#settings`, as `books_my_profile_settings`; `patch "my/profile/settings"` → `#update_settings`; `get "my/profile/preview"` → `#preview`, as `books_my_profile_preview`; `get "profiles/:id"` → `books/profiles#show`, as `books_profile`, `constraints: {id: /\d+/}`.
- `Cacheable#cache_at_edge_only(ttl)`: `skip_session_for_caching`, then `Cache-Control: public, max-age=0, s-maxage=<ttl seconds>`.
- `settings` (GET): `current_user.books_profile || current_user.build_books_profile(display_name: current_user.display_name)`. **Never saves on GET.** Form: public toggle, display name (`input`, inside `fieldset` + `fieldset-legend`), eight `checkbox`/`toggle` switches, and once public the full public URL in a read-only field. Next to the taste switch: taste is worked out from all your lists and ratings, and shows only genre and subject names.
- `update_settings`: permit `:public, :display_name` and the eight `show_*`. Persisted and confirmed/nil → redirect to settings with notice "Profile settings saved." Persisted with `purge_confirmed: false` → redirect with alert "Saved. Your profile is updated, but we could not confirm the cached copy was cleared. It will clear within 10 minutes." Not persisted → re-render `:settings` with `status: :unprocessable_entity` (as a full page; the form must not sit in a Turbo Frame).
- `preview`: renders the shared dashboard with `Build.call(user: current_user, audience: :public, profile:)`, uncached, whether or not the profile is public; with no profile row it redirects to settings.
- Public `show`: find `Books::Profile` by id. Not found or not public → `prevent_caching` and `raise ActiveRecord::RecordNotFound`, for everyone including the owner and admins. Public → `cache_at_edge_only(10.minutes)`, render with `audience: :public`, `<meta name="robots" content="noindex">` through the layout's existing mechanism (find how another books view sets robots; do not add the route to the sitemap).
- Own page header gains the privacy status ("Private" / "Public") and a "Share settings" button.

- [ ] **Step 1: Write the failing tests.**

```ruby
# my/profiles
test "settings GET does not create a profile row"             # assert_no_difference "Books::Profile.count"
test "settings prefill the display name from the account for a new profile"
test "update creates the profile and redirects"
test "update with public on and a blank display name re-renders 422 and saves nothing"
test "update that hides a section calls the synchronous purge"            # expects purge_urls
test "update reports an unconfirmed purge with an alert and still saves"
test "update ignores parameters outside the permitted list"               # user_id in params does not move the profile
test "preview renders the public audience uncached for a private profile" # no-store; view_assigns audience :public
test "preview without a profile redirects to settings"
test "all three actions require sign-in"

# profiles (public)
test "a public profile renders signed out with edge-only cache headers"
  cc = response.headers.fetch("Cache-Control")
  assert_includes cc, "s-maxage=600"; assert_includes cc, "max-age=0"; assert_includes cc, "public"
  assert_nil response.headers["Set-Cookie"]
test "a private profile is 404 and no-store for a visitor, the owner and an admin"
test "an unknown id is 404"
test "the response is the same signed in and signed out"                  # equal bodies
test "a switched-off section's data is not in the response"
  # public_profile with show_favorites false: a favorite-only book's title is absent from response.body
test "a provisional book is not in the response"
test "the display name is escaped"                                         # "<b>Al</b>" appears escaped, never as a tag
test "the page carries noindex"
test "private -> public makes the URL work again"
test "assert_no_frame_trapped_links on the public page and the own page"
```

- [ ] **Steps 2–4:** fail, implement, pass; run the lint tests and `bundle exec standardrb`.
- [ ] **Step 5:** Look at settings, preview and the public page in the browser at phone and desktop widths, including a public profile with every switch off (header alone must look finished).
- [ ] **Step 6:** Commit: `Reader profile: settings, preview and public page`.

### Task 10: E2E and docs (phase 2)

**Files:**
- Modify: `e2e/tests/books/account/profile.spec.ts`, `lib/tasks/e2e.rake` (reset the e2e account's profile to private in `e2e:prepare` so the spec is repeatable), `docs/features/reader-profile.md`

- [ ] **Step 1:** Extend the spec: from `/my/profile` open Share settings, turn public on, set a display name and two sections, save; read the public URL from the page; open it in a signed-out context (`browser.newContext({storageState: undefined})` — a plain `newContext` inherits the signed-in state) and see the name and those two sections and not a third; back signed in, switch public off, and the signed-out URL is a 404.
- [ ] **Step 2:** Confirm port 3000 is this checkout's, run `yarn test:e2e e2e/tests/books/account/profile.spec.ts` twice — PASS both times (proves `e2e:prepare` resets it).
- [ ] **Step 3:** Update the feature doc: sharing model, switches, caching and purge behaviour, what taste draws on, no moderation.
- [ ] **Step 4:** `bin/rails test`, `CI=1 bin/rails zeitwerk:check`, `bundle exec standardrb` — clean.
- [ ] **Step 5:** Commit: `Reader profile: sharing E2E and docs`. Tell the owner phase 2 is ready and unpushed; ask before pushing. Note for the owner: merging deploys, and the migration only adds a table.
