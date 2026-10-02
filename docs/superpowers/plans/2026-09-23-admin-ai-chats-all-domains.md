# Admin AI Chats for Every Domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace music's admin AI Chats pages with one shared implementation that serves music, books and games.

**Architecture:** A single `Admin::AiChatsController`, routed from each domain's admin namespace with `controller: "/admin/ai_chats"` (the `Admin::CorrectionsController` precedent). Which chats a domain sees, and every parent's admin path, comes from the existing `Admin::DomainRouting` registry (`ENTITIES`, `LISTS`) instead of hard-coded music classes.

**Tech Stack:** Rails 8, Minitest + fixtures, Pagy, DaisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-23-admin-ai-chats-all-domains-design.md`

## Global Constraints

- Run all Rails/yarn commands from `web-app/` of the worktree: `/home/shane/dev/the-greatest/.claude/worktrees/admin-ai-chats/web-app`.
- Music's path `/admin/ai_chats` and helpers `admin_ai_chats_path` / `admin_ai_chat_path` must not change.
- Parentless chats (`parent_type IS NULL`) appear on every domain.
- Chats whose parent type is in no domain's registry (`Category`, movies) appear on no domain.
- Lint is `bundle exec standardrb` (never `bin/rubocop`). Do not run brakeman.
- Controller tests assert behavior (status, redirects), never markup or copy.
- Minitest 6: use `assert_nil`, never `assert_equal nil, x`.
- Never commit to `main`; this work is on branch `worktree-admin-ai-chats`. Do not push.
- Commit message trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A domain page that shows every chat — each domain's index test must prove the other two domains' chats (entity AND list parents) are excluded. Pinned in Task 1 (scope test) and Task 3 (controller test).
2. Opening another domain's chat by id — must 404, not render. Pinned in Task 3 in all directions.
3. A chat whose parent record was deleted (`parent_type` set, record gone; real for `Games::Game`, which has no `dependent: :destroy`) — index and show must render, label falls back to the stored type, no link. Pinned in Task 2 (helper) and Task 3 (show 200).
4. A domain-role user reaching another domain's AI chats — `books_viewer_user` on games and `games_editor_user` on books must be redirected. Pinned in Task 3.
5. A list parent whose STI type is not in `LISTS` (e.g. `Movies::List`) — label "List", no path, no crash. Pinned in Task 2.

---

### Task 1: Domain scoping — registry lookups, model scope, fixtures

**Files:**
- Modify: `web-app/app/lib/admin/domain_routing.rb` (add two class methods)
- Modify: `web-app/app/models/ai_chat.rb` (add scope)
- Modify: `web-app/test/fixtures/ai_chats.yml`
- Test: `web-app/test/lib/admin/domain_routing_test.rb`, `web-app/test/models/ai_chat_test.rb`

**Interfaces:**
- Produces: `Admin::DomainRouting.entity_types_for(domain) -> Array<String>`, `Admin::DomainRouting.list_types_for(domain) -> Array<String>` (domain may be Symbol or String); `AiChat.for_parent_types(entity_types, list_types) -> ActiveRecord::Relation`.
- Produces fixtures: `ai_chats(:books_book_chat)` (parent `Books::Book` war_and_peace), `ai_chats(:games_game_chat)` (parent `Games::Game` breath_of_the_wild); `ai_chats(:ranking_chat)` now a real `Books::List` list parent (`parent_type: "List"`).

- [ ] **Step 1: Fix and extend fixtures**

In `test/fixtures/ai_chats.yml`, in `ranking_chat`, replace the line `  parent: books_list (Books::List)` with:

```yaml
  parent_type: "List"
  parent_id: <%= ActiveRecord::FixtureSet.identify(:books_list) %>
```

Append after `games_list_chat`:

```yaml
# Direct (non-STI) parents for books and games, so every domain has both an
# entity parent and a list parent to scope.
books_book_chat:
  chat_type: analysis
  model: "gpt-5-mini"
  provider: openai
  temperature: 0.2
  json_mode: true
  messages: [{ role: "system", content: "Pick the matching book", timestamp: "2024-01-04T10:00:00Z" }]
  parent: war_and_peace (Books::Book)

games_game_chat:
  chat_type: analysis
  model: "gpt-5-mini"
  provider: openai
  temperature: 0.2
  json_mode: true
  messages: [{ role: "system", content: "Pick the matching IGDB game", timestamp: "2024-01-04T11:00:00Z" }]
  parent: breath_of_the_wild (Games::Game)
```

Also change the comment above `no_parent_chat` from `(should be included in music admin)` to `(shown on every domain's admin)`.

- [ ] **Step 2: Write failing registry tests**

Add to `test/lib/admin/domain_routing_test.rb` inside the class:

```ruby
    test "entity_types_for returns the entity types registered to a domain" do
      assert_equal %w[Music::Artist Music::Album Music::Song].sort,
        Admin::DomainRouting.entity_types_for(:music).sort
      assert_equal %w[Books::Book Books::Edition Books::Author Books::Series].sort,
        Admin::DomainRouting.entity_types_for(:books).sort
      assert_equal %w[Games::Game Games::Company Games::Series].sort,
        Admin::DomainRouting.entity_types_for("games").sort
    end

    test "list_types_for returns the list STI types registered to a domain" do
      assert_equal %w[Music::Albums::List Music::Songs::List].sort,
        Admin::DomainRouting.list_types_for(:music).sort
      assert_equal %w[Books::List], Admin::DomainRouting.list_types_for(:books)
      assert_equal %w[Games::List], Admin::DomainRouting.list_types_for("games")
    end

    test "entity_types_for and list_types_for are empty for a domain with nothing registered" do
      assert_empty Admin::DomainRouting.entity_types_for(:movies)
      assert_empty Admin::DomainRouting.list_types_for(:movies)
    end
```

- [ ] **Step 3: Write failing scope tests**

Add to `test/models/ai_chat_test.rb` after the `with_list_parent_types` tests:

```ruby
  # Tests for for_parent_types scope
  test "for_parent_types returns a domain's entity chats, list chats and parentless chats only" do
    result = AiChat.for_parent_types(%w[Books::Book Books::Author], %w[Books::List])

    assert_includes result, ai_chats(:books_book_chat)
    assert_includes result, ai_chats(:ranking_chat) # Books::List
    assert_includes result, ai_chats(:no_parent_chat)
    assert_includes result, ai_chats(:general_chat)

    assert_not_includes result, ai_chats(:music_artist_chat)
    assert_not_includes result, ai_chats(:music_albums_list_chat)
    assert_not_includes result, ai_chats(:games_game_chat)
    assert_not_includes result, ai_chats(:games_list_chat)
  end

  test "for_parent_types with no list types still returns entity and parentless chats" do
    result = AiChat.for_parent_types(%w[Games::Game], [])

    assert_includes result, ai_chats(:games_game_chat)
    assert_includes result, ai_chats(:no_parent_chat)
    assert_not_includes result, ai_chats(:games_list_chat)
    assert_not_includes result, ai_chats(:ranking_chat)
  end

  test "for_parent_types with nothing registered returns only parentless chats" do
    result = AiChat.for_parent_types([], [])

    assert_equal AiChat.where(parent_type: nil).pluck(:id).sort, result.pluck(:id).sort
  end
```

(`general_chat` has a user and no parent — verified.)

- [ ] **Step 4: Run to verify failure**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb test/models/ai_chat_test.rb`
Expected: FAIL/ERROR with `NoMethodError` for `entity_types_for`, `list_types_for`, `for_parent_types`. All pre-existing tests still pass (the `ranking_chat` exclusions in `with_list_parent_types` tests stay true — it is now a real Books::List chat, so those assertions stop being vacuous).

- [ ] **Step 5: Implement the registry methods**

In `app/lib/admin/domain_routing.rb`, inside `class << self`, after `domain_for`:

```ruby
      def entity_types_for(domain)
        types_in(ENTITIES, domain)
      end

      def list_types_for(domain)
        types_in(LISTS, domain)
      end
```

and in the `private` section, before `resolve`:

```ruby
      def types_in(table, domain)
        table.filter_map { |type, config| type if config[:domain] == domain.to_sym }
      end
```

- [ ] **Step 6: Implement the scope**

In `app/models/ai_chat.rb`, after `with_list_parent_types`:

```ruby
  # A domain's AI chats: direct parents of its entity types, List parents of its
  # list STI types, and chats with no parent at all (which cannot be attributed
  # to any domain, so every domain shows them). The list branch is a subquery so
  # no ids are loaded into memory.
  scope :for_parent_types, ->(entity_types, list_types) {
    where(parent_type: entity_types)
      .or(where(parent_type: nil))
      .or(where(id: with_list_parent_types(list_types).select(:id)))
  }
```

- [ ] **Step 7: Run to verify pass**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb test/models/ai_chat_test.rb test/controllers/admin/music/ai_chats_controller_test.rb`
Expected: PASS. If `for_parent_types([], [])` raises on the `none` subquery, replace the list branch with `list_types.present? ? ... : none`-style guarding inside the lambda and re-run.

- [ ] **Step 8: Run the tests that load AI chat fixtures for books/games parents**

Run: `bin/rails test test/lib/books/book/merger_test.rb test/models/books test/models/games`
Expected: PASS. If the books merger test asserts on `war_and_peace`'s ai_chats, move `books_book_chat` to `crime_and_punishment` and re-run.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/lib/admin/domain_routing.rb app/models/ai_chat.rb test/lib/admin/domain_routing_test.rb test/models/ai_chat_test.rb
git add app/lib/admin/domain_routing.rb app/models/ai_chat.rb test/fixtures/ai_chats.yml test/lib/admin/domain_routing_test.rb test/models/ai_chat_test.rb
git commit -m "AI chats scope to a domain through the admin registry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Helper reads the registry

**Files:**
- Modify: `web-app/app/helpers/admin/ai_chats_helper.rb`
- Test: `web-app/test/helpers/admin/ai_chats_helper_test.rb`

**Interfaces:**
- Consumes: fixtures from Task 1; `Admin::DomainRouting.path_for`, `.list_config`, `LISTS`.
- Produces (unchanged names, used by the Task 3 views): `admin_ai_chat_parent_path(ai_chat) -> String|nil`, `ai_chat_parent_display_name(ai_chat) -> String|nil`, `ai_chat_parent_type_label(ai_chat) -> String|nil`, `ai_chat_type_badge_class(chat_type)`, `ai_chat_provider_badge_class(provider)`.

- [ ] **Step 1: Update and extend the helper tests**

In `test/helpers/admin/ai_chats_helper_test.rb`:

Change the two list label tests' expectations — list labels now come from `LISTS[:item_label]`:

```ruby
  test "ai_chat_parent_type_label returns Album List for Music::Albums::List parent" do
    assert_equal "Album List", ai_chat_parent_type_label(@music_albums_list_chat)
  end

  test "ai_chat_parent_type_label returns Song List for Music::Songs::List parent" do
    assert_equal "Song List", ai_chat_parent_type_label(@music_songs_list_chat)
  end
```

Add:

```ruby
  test "ai_chat_parent_type_label covers books and games parents" do
    assert_equal "Book", ai_chat_parent_type_label(ai_chats(:books_book_chat))
    assert_equal "Book List", ai_chat_parent_type_label(ai_chats(:ranking_chat))
    assert_equal "Game", ai_chat_parent_type_label(ai_chats(:games_game_chat))
    assert_equal "Game List", ai_chat_parent_type_label(ai_chats(:games_list_chat))
  end

  test "ai_chat_parent_type_label falls back to the stored type when the parent is gone" do
    chat = AiChat.new(parent_type: "Games::Game", parent_id: 0)
    assert_equal "Game", ai_chat_parent_type_label(chat)
  end

  test "ai_chat_parent_type_label says List for a list type no domain registers" do
    list = List.new(type: "Movies::List", name: "Unregistered")
    chat = AiChat.new(parent: list)
    assert_equal "List", ai_chat_parent_type_label(chat)
  end

  test "admin_ai_chat_parent_path resolves entity and list parents in every domain" do
    assert_equal "/admin/artists/#{@music_artist_chat.parent.to_param}", admin_ai_chat_parent_path(@music_artist_chat)
    assert_equal "/admin/books/#{books_books(:war_and_peace).to_param}", admin_ai_chat_parent_path(ai_chats(:books_book_chat))
    assert_equal "/admin/games/#{games_games(:breath_of_the_wild).to_param}", admin_ai_chat_parent_path(ai_chats(:games_game_chat))
    assert_equal Admin::DomainRouting.list_config(lists(:books_list))[:path], admin_ai_chat_parent_path(ai_chats(:ranking_chat))
    assert_equal Admin::DomainRouting.list_config(lists(:games_list))[:path], admin_ai_chat_parent_path(ai_chats(:games_list_chat))
    assert_equal Admin::DomainRouting.list_config(lists(:music_albums_list))[:path], admin_ai_chat_parent_path(@music_albums_list_chat)
  end

  test "admin_ai_chat_parent_path is nil without a parent or for an unregistered parent" do
    assert_nil admin_ai_chat_parent_path(@general_chat)
    assert_nil admin_ai_chat_parent_path(AiChat.new(parent_type: "Games::Game", parent_id: 0))
    assert_nil admin_ai_chat_parent_path(AiChat.new(parent: List.new(type: "Movies::List", name: "x")))
  end

  test "ai_chat_parent_display_name uses title or name for books and games parents" do
    assert_equal "War and Peace", ai_chat_parent_display_name(ai_chats(:books_book_chat))
    assert_equal "The Legend of Zelda: Breath of the Wild", ai_chat_parent_display_name(ai_chats(:games_game_chat))
    assert_equal "Books Test List", ai_chat_parent_display_name(ai_chats(:ranking_chat))
  end
```

(`lists(:music_albums_list)`, `lists(:games_list)`, `lists(:books_list)` all exist — verified.) If `List.new(type: "Movies::List")` raises (STI class resolution), build it as `Movies::List.new(name: "x")` instead — the point is a List subclass absent from `LISTS`.

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/helpers/admin/ai_chats_helper_test.rb`
Expected: FAIL — music list labels are still "Albums List"/"Songs List", books/games parents return nil paths and fall through to `demodulize` / `"#{class} ##{id}"`.

- [ ] **Step 3: Rewrite the three parent helpers**

Replace the bodies of `admin_ai_chat_parent_path`, `ai_chat_parent_display_name` and `ai_chat_parent_type_label` in `app/helpers/admin/ai_chats_helper.rb` (leave the two badge helpers exactly as they are):

```ruby
module Admin::AiChatsHelper
  # Returns the admin path for an AI chat's parent, or nil if no path available
  def admin_ai_chat_parent_path(ai_chat)
    parent = ai_chat.parent
    return nil unless parent

    if parent.is_a?(List)
      Admin::DomainRouting.list_config(parent)&.dig(:path)
    else
      Admin::DomainRouting.path_for(parent)
    end
  end

  # Returns a display name for the parent. Every registered parent model has
  # exactly one of a name or a title column.
  def ai_chat_parent_display_name(ai_chat)
    parent = ai_chat.parent
    return nil unless parent

    parent.try(:name).presence || parent.try(:title).presence || "#{parent.class.name} ##{parent.id}"
  end

  # Returns the human-readable parent type.
  # Lists are STI and Rails stores the base class ("List") in parent_type, so a
  # list's label comes from the loaded record's own class.
  def ai_chat_parent_type_label(ai_chat)
    return nil if ai_chat.parent_type.blank?

    parent = ai_chat.parent
    return ai_chat.parent_type.demodulize if parent.nil?
    return parent.class.name.demodulize unless parent.is_a?(List)

    item_label = Admin::DomainRouting::LISTS.dig(parent.class.name, :item_label)
    item_label ? "#{item_label} List" : "List"
  end
```

(followed by the unchanged badge helpers and the closing `end`).

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/helpers/admin/ai_chats_helper_test.rb test/controllers/admin/music/ai_chats_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/helpers/admin/ai_chats_helper.rb test/helpers/admin/ai_chats_helper_test.rb
git add app/helpers/admin/ai_chats_helper.rb test/helpers/admin/ai_chats_helper_test.rb
git commit -m "AI chat parent paths and labels come from the admin registry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Shared controller, routes and views; music's copy removed

**Files:**
- Create (generator): `web-app/app/controllers/admin/ai_chats_controller.rb`, `web-app/test/controllers/admin/ai_chats_controller_test.rb`
- Move: `web-app/app/views/admin/music/ai_chats/{index,show,_table}.html.erb` → `web-app/app/views/admin/ai_chats/`
- Delete: `web-app/app/controllers/admin/music/ai_chats_controller.rb`, `web-app/test/controllers/admin/music/ai_chats_controller_test.rb`
- Modify: `web-app/config/routes.rb` (music line ~287; books admin namespace ~line 660–760; games admin namespace ~line 1069–1185)

**Interfaces:**
- Consumes: `AiChat.for_parent_types`, `Admin::DomainRouting.entity_types_for/list_types_for` (Task 1); helper methods (Task 2); `current_domain` (from the `CurrentDomain` concern, Symbol).
- Produces: routes `admin_ai_chats_path`/`admin_ai_chat_path` (music, unchanged), `admin_books_ai_chats_path`/`admin_books_ai_chat_path`, `admin_games_ai_chats_path`/`admin_games_ai_chat_path` — all served at `/admin/ai_chats[/:id]` on their own host. View helpers `ai_chats_index_path(**opts)` and `ai_chat_path_for(ai_chat)`.

- [ ] **Step 1: Generate the controller and its test**

```bash
bin/rails generate controller Admin::AiChats --skip-routes --no-helper
```

(no actions → no view files generated; `Admin::AiChatsHelper` already exists and must not be overwritten.)

- [ ] **Step 2: Write the failing controller test**

Replace `test/controllers/admin/ai_chats_controller_test.rb` with:

```ruby
require "test_helper"

class Admin::AiChatsControllerTest < ActionDispatch::IntegrationTest
  DOMAIN_CHATS = {
    music: %i[music_artist_chat music_album_chat music_albums_list_chat music_songs_list_chat],
    books: %i[books_book_chat ranking_chat],
    games: %i[games_game_chat games_list_chat]
  }.freeze

  setup do
    @admin = users(:admin_user)
  end

  def visit_domain(domain, as: @admin)
    host! Rails.application.config.domains[domain]
    sign_in_as(as, stub_auth: true) if as
  end

  def index_url_for(domain)
    public_send(:"#{domain == :music ? "admin" : "admin_#{domain}"}_ai_chats_url")
  end

  def show_url_for(domain, chat)
    public_send(:"#{domain == :music ? "admin" : "admin_#{domain}"}_ai_chat_url", chat)
  end

  def show_path_for(domain, chat)
    public_send(:"#{domain == :music ? "admin" : "admin_#{domain}"}_ai_chat_path", chat)
  end

  %i[music books games].each do |domain|
    test "#{domain}: index lists only this domain's chats plus parentless ones" do
      visit_domain(domain)
      get index_url_for(domain)
      assert_response :success

      # Which records the index lists is behavior: each listed chat carries a
      # link to its own show path. Fixture ids are large hashes, so one id's path
      # is never a prefix of another's closing quote-delimited href.
      DOMAIN_CHATS.fetch(domain).each { |name| assert_includes response.body, %(href="#{show_path_for(domain, ai_chats(name))}"), name }
      assert_includes response.body, %(href="#{show_path_for(domain, ai_chats(:no_parent_chat))}")
      DOMAIN_CHATS.except(domain).values.flatten.each do |name|
        assert_not_includes response.body, %(href="#{show_path_for(domain, ai_chats(name))}"), name
      end
    end

    test "#{domain}: shows each of its own chats" do
      visit_domain(domain)
      DOMAIN_CHATS.fetch(domain).each do |name|
        get show_url_for(domain, ai_chats(name))
        assert_response :success, name
      end
    end

    test "#{domain}: shows a parentless chat" do
      visit_domain(domain)
      get show_url_for(domain, ai_chats(:no_parent_chat))
      assert_response :success
    end

    test "#{domain}: another domain's chat is not found" do
      visit_domain(domain)
      DOMAIN_CHATS.except(domain).values.flatten.each do |name|
        get show_url_for(domain, ai_chats(name))
        assert_response :not_found, name
      end
    end

    test "#{domain}: an unknown id is not found" do
      visit_domain(domain)
      get show_url_for(domain, 999_999_999)
      assert_response :not_found
    end

    test "#{domain}: index renders the empty state" do
      AiChat.delete_all
      visit_domain(domain)
      get index_url_for(domain)
      assert_response :success
    end

    test "#{domain}: editor is allowed" do
      visit_domain(domain, as: users(:editor_user))
      get index_url_for(domain)
      assert_response :success
    end

    test "#{domain}: regular user is redirected to the domain root" do
      visit_domain(domain, as: users(:regular_user))
      get index_url_for(domain)
      assert_redirected_to public_send(:"#{domain}_root_url")
    end

    test "#{domain}: signed-out visitor is redirected to the domain root" do
      visit_domain(domain, as: nil)
      get index_url_for(domain)
      assert_redirected_to public_send(:"#{domain}_root_url")
    end
  end

  test "a chat whose parent record is gone still renders" do
    chat = AiChat.create!(model: "gpt-5-mini", provider: :openai, chat_type: :analysis,
      parent_type: "Games::Game", parent_id: 0)
    visit_domain(:games)
    get admin_games_ai_chats_url
    assert_response :success
    get admin_games_ai_chat_url(chat)
    assert_response :success
  end

  test "a books domain role reaches books AI chats but not games" do
    visit_domain(:books, as: users(:books_viewer_user))
    get admin_books_ai_chats_url
    assert_response :success

    visit_domain(:games, as: users(:books_viewer_user))
    get admin_games_ai_chats_url
    assert_redirected_to games_root_url
  end

  test "a games domain role reaches games AI chats but not books" do
    visit_domain(:games, as: users(:games_editor_user))
    get admin_games_ai_chats_url
    assert_response :success

    visit_domain(:books, as: users(:games_editor_user))
    get admin_books_ai_chats_url
    assert_redirected_to books_root_url
  end
end
```

(`rails-controller-testing` is not in the Gemfile, so `assigns` is unavailable — hence the href check. The table links each chat's id and its View button to the same path, so the check survives either being restyled.)

The `AiChat.delete_all` in the empty-state test runs under `RAILS_ENV=test` inside a transactional test; it is not a dev-database command.

- [ ] **Step 3: Run to verify failure**

Run: `bin/rails test test/controllers/admin/ai_chats_controller_test.rb`
Expected: ERROR — `admin_books_ai_chats_url` / `admin_games_ai_chats_url` undefined; music tests fail against the generated empty controller.

- [ ] **Step 4: Write the controller**

Replace `app/controllers/admin/ai_chats_controller.rb` with:

```ruby
class Admin::AiChatsController < Admin::BaseController
  include Admin::DomainScopedAuth

  # Each domain's admin namespace names its own `resources :ai_chats`: music's
  # `namespace :admin, module: "admin/music"` carries no `as:`, so its helpers
  # are the bare `admin_ai_chats_path` family; books and games add their prefix.
  ROUTE_PREFIXES = {
    music: "admin",
    books: "admin_books",
    games: "admin_games"
  }.freeze

  before_action :set_ai_chat, only: [:show]

  def index
    @pagy, @ai_chats = pagy(
      domain_scope.includes(:parent, :user).order(created_at: :desc),
      limit: 25
    )
  end

  def show
  end

  def ai_chats_index_path(**options)
    public_send(:"#{route_prefix}_ai_chats_path", **options)
  end
  helper_method :ai_chats_index_path

  def ai_chat_path_for(ai_chat)
    public_send(:"#{route_prefix}_ai_chat_path", ai_chat)
  end
  helper_method :ai_chat_path_for

  private

  def route_prefix
    ROUTE_PREFIXES.fetch(current_domain.to_sym)
  end

  def domain_scope
    AiChat.for_parent_types(
      Admin::DomainRouting.entity_types_for(current_domain),
      Admin::DomainRouting.list_types_for(current_domain)
    )
  end

  def set_ai_chat
    @ai_chat = domain_scope.find(params[:id])
  end
end
```

- [ ] **Step 5: Route every domain to it**

In `config/routes.rb`:

Music (inside `namespace :admin, module: "admin/music"`, currently `resources :ai_chats, only: [:index, :show]` near line 287) becomes:

```ruby
      # Shared controller, routed per domain -- same shape as corrections. The
      # domain comes from the host, so the index scopes to this domain's parents.
      resources :ai_chats, only: [:index, :show], controller: "/admin/ai_chats"
```

Books: inside `namespace :admin, module: "admin/books", as: "admin_books"`, immediately before its `resources :corrections, ...` block, add the same three lines.

Games: inside `namespace :admin, module: "admin/games", as: "admin_games"`, immediately before its `resources :corrections, ...` block, add the same three lines.

Verify: `bin/rails routes -g ai_chat` shows six routes, all `admin/ai_chats#index|show`, with names `admin_ai_chats`, `admin_ai_chat`, `admin_books_ai_chats`, `admin_books_ai_chat`, `admin_games_ai_chats`, `admin_games_ai_chat`, and no `admin/music/ai_chats`.

- [ ] **Step 6: Move the views and point their links at the domain-neutral helpers**

```bash
mkdir -p app/views/admin/ai_chats
git mv app/views/admin/music/ai_chats/index.html.erb app/views/admin/ai_chats/index.html.erb
git mv app/views/admin/music/ai_chats/show.html.erb app/views/admin/ai_chats/show.html.erb
git mv app/views/admin/music/ai_chats/_table.html.erb app/views/admin/ai_chats/_table.html.erb
```

Then in those three files:
- `_table.html.erb`: both `admin_ai_chat_path(ai_chat)` → `ai_chat_path_for(ai_chat)`.
- `show.html.erb`: `admin_ai_chats_path` → `ai_chats_index_path`.
- `index.html.erb`: subtitle `View AI chat interactions for music content` → `AI chat interactions for this site's records`.

Confirm nothing domain-specific remains: `grep -n "admin_ai_chat\|music" app/views/admin/ai_chats/*` returns nothing.

- [ ] **Step 7: Delete music's controller and test**

```bash
git rm app/controllers/admin/music/ai_chats_controller.rb test/controllers/admin/music/ai_chats_controller_test.rb
rmdir app/views/admin/music/ai_chats 2>/dev/null || true
```

`grep -rn "Admin::Music::AiChats\|admin/music/ai_chats" app config test` must return nothing.

- [ ] **Step 8: Run to verify pass**

Run: `bin/rails test test/controllers/admin/ai_chats_controller_test.rb test/helpers/admin/ai_chats_helper_test.rb test/models/ai_chat_test.rb`
Expected: PASS.

Mutation check (Review Focus 1 and 2): temporarily change `domain_scope` to return `AiChat.all`, re-run the controller test, confirm the index-exclusion and cross-domain-404 tests FAIL, then revert.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/controllers/admin/ai_chats_controller.rb test/controllers/admin/ai_chats_controller_test.rb config/routes.rb
git add -A app/controllers/admin app/views/admin config/routes.rb test/controllers/admin
git commit -m "One AI chats admin controller serves music, books and games

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Sidebar nav items and E2E

**Files:**
- Modify: `web-app/app/lib/admin/domain_nav.rb` (books and games `items`)
- Test: `web-app/test/lib/admin/domain_nav_test.rb`
- Create: `web-app/e2e/tests/books/admin/ai-chats.spec.ts`, `web-app/e2e/tests/games/admin/ai-chats.spec.ts`

**Interfaces:**
- Consumes: routes `admin_books_ai_chats_path`, `admin_games_ai_chats_path` (Task 3).

- [ ] **Step 1: Write the failing nav test**

Add to `test/lib/admin/domain_nav_test.rb` inside the class:

```ruby
    test "every domain's nav links to its AI Chats page" do
      %i[music books games].each do |domain|
        item = Admin::DomainNav.config_for(domain)[:items].find { |i| i[:label] == "AI Chats" }
        assert item, "#{domain} nav is missing an AI Chats item"
        assert_equal "/admin/ai_chats", item[:path]
      end
    end
```

(`config_for` calls each item's `path` lambda, so `item[:path]` is a String — verified.)

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: FAIL — "books nav is missing an AI Chats item".

- [ ] **Step 3: Add the nav items**

In `app/lib/admin/domain_nav.rb`, in the games `items`, directly before the `Corrections` item:

```ruby
          {label: "AI Chats", icon: :chat, path: -> { URL_HELPERS.admin_games_ai_chats_path }},
```

In the books `items`, directly before the `Corrections` item:

```ruby
          {label: "AI Chats", icon: :chat, path: -> { URL_HELPERS.admin_books_ai_chats_path }},
```

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the E2E specs**

`e2e/tests/games/admin/ai-chats.spec.ts`:

```ts
import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin AI Chats', () => {
  test('sidebar reaches AI Chats and a chat opens', async ({ page, gamesDashboardPage }) => {
    await gamesDashboardPage.goto();
    await page.getByTestId('admin-sidebar').getByRole('link', { name: 'AI Chats', exact: true }).click();

    await expect(page).toHaveURL(/\/admin\/ai_chats/);
    await expect(page.getByRole('heading', { name: 'AI Chats', exact: true })).toBeVisible();

    const view = page.getByTitle('View').first();
    if (await view.count() === 0) {
      await expect(page.getByText('No AI chats found')).toBeVisible();
      return;
    }
    await view.click();
    await expect(page).toHaveURL(/\/admin\/ai_chats\/\d+/);
    await expect(page.getByRole('heading', { name: /^AI Chat #\d+$/ })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Basic Information' })).toBeVisible();
  });
});
```

`e2e/tests/books/admin/ai-chats.spec.ts` (the `books-admin` project supplies storage state; `page.goto('/admin')` is how `sidebar-nav.spec.ts` opens the dashboard):

```ts
import { test, expect } from '@playwright/test';

test.describe('Books Admin AI Chats', () => {
  test('sidebar reaches AI Chats and a chat opens', async ({ page }) => {
    await page.goto('/admin');
    await page.getByTestId('admin-sidebar').getByRole('link', { name: 'AI Chats', exact: true }).click();

    await expect(page).toHaveURL(/\/admin\/ai_chats/);
    await expect(page.getByRole('heading', { name: 'AI Chats', exact: true })).toBeVisible();

    const view = page.getByTitle('View').first();
    if (await view.count() === 0) {
      await expect(page.getByText('No AI chats found')).toBeVisible();
      return;
    }
    await view.click();
    await expect(page).toHaveURL(/\/admin\/ai_chats\/\d+/);
    await expect(page.getByRole('heading', { name: /^AI Chat #\d+$/ })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Basic Information' })).toBeVisible();
  });
});
```

- [ ] **Step 6: Run the E2E specs**

From the worktree's `web-app/`:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If another checkout owns the port, STOP and report to the user — do not kill it or use another port. If free: `yarn build:all`, start `bin/rails server` in the background, then
`yarn test:e2e e2e/tests/books/admin/ai-chats.spec.ts e2e/tests/games/admin/ai-chats.spec.ts`
Expected: PASS (dev has games chats and a few books chats, so both specs exercise the show page). Stop the server afterwards.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/admin/domain_nav.rb test/lib/admin/domain_nav_test.rb
git add app/lib/admin/domain_nav.rb test/lib/admin/domain_nav_test.rb e2e/tests/books/admin/ai-chats.spec.ts e2e/tests/games/admin/ai-chats.spec.ts
git commit -m "Books and games admin nav link to AI Chats

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Full verification

- [ ] **Step 1:** `bin/rails test` — expect 0 failures, 0 errors, and no new warning lines (only `weighted_list_rank`'s position `puts` and yarn noise are known).
- [ ] **Step 2:** `bundle exec standardrb` — no offenses.
- [ ] **Step 3:** `CI=1 bin/rails zeitwerk:check` — "All is good!"
- [ ] **Step 4:** `bin/rails routes -g ai_chat` — exactly the six routes from Task 3, no `admin/music/ai_chats`.
- [ ] **Step 5:** Report to the user: branch `worktree-admin-ai-chats`, commits, test counts, E2E result (or that it was skipped because port 3000 belonged to another checkout), and that the branch is unpushed.
