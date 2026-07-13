# Admin Domain Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded per-domain `case` statements scattered through the "shared" admin layer with two registries, so that adding the books admin (and later movies) becomes a config entry rather than a dozen edits — and fix the live bug where games admins are served the music layout.

**Architecture:** Two new lookup modules under `app/lib/admin/`. `Admin::DomainRouting` answers *"given this record, what domain is it and what is its admin path?"*. `Admin::DomainNav` answers *"given this domain, what is its admin chrome?"* (layout, root path, title, sidebar items). A new `Admin::DomainScopedAuth` concern collapses eight verbatim copies of the same `authenticate_admin!` override. Every consumer then reads from these instead of pattern-matching class names.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, Pundit, Pagy, DaisyUI 5 / Tailwind 4.

This is **increment 1** of `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md`.

## Global Constraints

- **Working directory is `web-app/`.** Run every command from there. Docs live at the project root in `docs/`, not `web-app/docs/`.
- **No books code in this increment.** Books does not get a layout, a nav entry, controllers, policies, or routes here. It arrives in increment 3. Registering books/movies *list types* where the code already handles them today (see Task 1) is preserving existing behavior, not adding books support.
- **This increment is behavior-neutral except for one deliberate bug fix:** games admins currently get the music layout on `/admin/penalties`, `/admin/users`, and `/admin/ranked_lists/:id`. After Task 3 they get the games layout.
- **The existing test suite is the contract.** ~4,500 tests must pass. If an existing test needs editing, that is a signal you changed behavior — stop and ask, do not "fix" the test. The only permitted test edits are the new layout assertions added in Task 3.
- **Lint with `bundle exec standardrb`** (NOT `bin/rubocop` — omakase, conflicting style). `--fix` autocorrects.
- **No code comments** unless they state a constraint the code cannot express.
- Tests mirror app structure and namespace: `app/lib/admin/domain_routing.rb` → `test/lib/admin/domain_routing_test.rb`.
- Full suite: `bin/rails test`. There is no test CI; verification is local.

## File Structure

**Create:**
- `app/lib/admin/domain_routing.rb` — record → domain / admin path / list config / RC config / nested-parent lookup
- `app/lib/admin/domain_nav.rb` — domain → admin layout, root path, title, sidebar items
- `app/controllers/concerns/admin/domain_scoped_auth.rb` — the one `authenticate_admin!` override
- `test/lib/admin/domain_routing_test.rb`
- `test/lib/admin/domain_nav_test.rb`

**Modify:**
- `app/controllers/admin/base_controller.rb` — dynamic layout
- `app/controllers/admin/{penalties,users,ranked_lists}_controller.rb` — drop `layout "music/admin"`
- `app/controllers/admin/{images,category_items,list_items,list_penalties,penalty_applications,ranked_items,ranked_lists,penalties}_controller.rb` — consume `DomainRouting`
- `app/controllers/admin/music/{base,lists,categories,ranking_configurations}_controller.rb` — consume `DomainScopedAuth`
- `app/controllers/admin/games/{base,lists,categories,ranking_configurations}_controller.rb` — consume `DomainScopedAuth`
- `app/components/admin/{add_category,add_item_to_list,add_list_to_configuration,edit_list_item}_modal_component.rb` — consume `DomainRouting`
- `app/views/admin/shared/_sidebar.html.erb` — render from `DomainNav`

**Delete:**
- `app/controllers/concerns/ranking_configuration_domain_auth.rb` — absorbed by `DomainScopedAuth`

---

## Landmine: the `:books` fallback

`ApplicationController#detect_current_domain` (`app/controllers/application_controller.rb:56-69`) ends with:

```ruby
else
  :books # default
end
```

So **any host that isn't music, movies, or games resolves to `:books`.** A naive `layout -> { "#{current_domain}/admin" }` would therefore try to render `books/admin` — which does not exist until increment 3 — for every unmatched host. `Admin::DomainNav` must therefore map only the domains that *have* an admin layout, and fall back to `music/admin` otherwise. That fallback exactly reproduces today's behavior (music was hardcoded), so it is behavior-neutral, and increment 3 flips books over by adding one line.

The existing global admin controller tests all call `host! Rails.application.config.domains[:music]`, so they resolve to `:music` and are unaffected either way. Do not rely on that — the fallback is what makes real unmatched hosts safe.

---

### Task 1: `Admin::DomainRouting`

The registry. Nothing consumes it yet — that is Tasks 5 and 6.

**Files:**
- Create: `app/lib/admin/domain_routing.rb`
- Test: `test/lib/admin/domain_routing_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Admin::DomainRouting.domain_for(record_or_class)` → `:music | :games | :books | :movies | nil`
  - `Admin::DomainRouting.path_for(record)` → `String | nil` (admin show path)
  - `Admin::DomainRouting.list_config(list)` → `Hash | nil` with keys `:domain, :listable_type, :path, :autocomplete_path, :item_label`
  - `Admin::DomainRouting.ranking_configuration_config(rc)` → `Hash | nil` with keys `:domain, :path, :list_type, :ranked_item_includes`
  - `Admin::DomainRouting.penalty_class(type_string)` → `Class` (defaults to `Global::Penalty`)
  - `Admin::DomainRouting.parent_from_params(params, domain:)` → `ApplicationRecord | nil`

`path_for` and the `:path` values return `nil` for domains with no admin yet (books, movies). Callers keep their existing `else` fallbacks, so behavior does not change.

- [ ] **Step 1: Write the failing test**

Create `test/lib/admin/domain_routing_test.rb`. The fixture names below are verified against `test/fixtures/`: `music_albums(:dark_side_of_the_moon)`, `music_artists(:david_bowie)`, `games_games(:breath_of_the_wild)`, `games_companies(:nintendo)`, `users(:regular_user)`.

`Music::Album`, `Music::Artist`, `Games::Game`, and `Games::Company` all use `friendly_id ... use: [:slugged, :finders]`, so their admin paths carry a **slug, not an id**. That is why the assertions below use `to_param` — asserting `#{album.id}` would fail.

```ruby
require "test_helper"

module Admin
  class DomainRoutingTest < ActiveSupport::TestCase
    test "domain_for resolves a record to its domain" do
      assert_equal :music, Admin::DomainRouting.domain_for(music_albums(:dark_side_of_the_moon))
      assert_equal :games, Admin::DomainRouting.domain_for(games_games(:breath_of_the_wild))
    end

    test "domain_for accepts a class" do
      assert_equal :music, Admin::DomainRouting.domain_for(Music::Artist)
      assert_equal :games, Admin::DomainRouting.domain_for(Games::Company)
    end

    test "domain_for returns nil for an unregistered class" do
      assert_nil Admin::DomainRouting.domain_for(User)
    end

    test "path_for returns the admin show path" do
      album = music_albums(:dark_side_of_the_moon)
      assert_equal "/admin/albums/#{album.to_param}", Admin::DomainRouting.path_for(album)

      game = games_games(:breath_of_the_wild)
      assert_equal "/admin/games/#{game.to_param}", Admin::DomainRouting.path_for(game)
    end

    test "path_for returns nil for an unregistered record" do
      assert_nil Admin::DomainRouting.path_for(users(:regular_user))
    end

    test "list_config returns the listable type, paths and label" do
      config = Admin::DomainRouting.list_config(Music::Albums::List.new)

      assert_equal :music, config[:domain]
      assert_equal "Music::Album", config[:listable_type]
      assert_equal "Album", config[:item_label]
      assert_equal "/admin/albums/search", config[:autocomplete_path]
    end

    test "list_config covers every list type the admin can reach" do
      %w[Music::Albums::List Music::Songs::List Games::List].each do |type|
        config = Admin::DomainRouting.list_config(type.constantize.new)
        assert config, "#{type} is not registered"
        assert config[:listable_type].present?
        assert config[:item_label].present?
      end
    end

    test "ranking_configuration_config exposes list type and eager-load includes" do
      config = Admin::DomainRouting.ranking_configuration_config(Games::RankingConfiguration.new)

      assert_equal :games, config[:domain]
      assert_equal "Games::List", config[:list_type]
      assert_equal({item: :companies}, config[:ranked_item_includes])
    end

    test "ranking_configuration_config registers all six ranking configuration types" do
      %w[
        Music::Albums::RankingConfiguration
        Music::Songs::RankingConfiguration
        Music::Artists::RankingConfiguration
        Games::RankingConfiguration
        Books::RankingConfiguration
        Movies::RankingConfiguration
      ].each do |type|
        assert Admin::DomainRouting.ranking_configuration_config(type.constantize.new),
          "#{type} is not registered"
      end
    end

    test "ranking_configuration_config returns a nil path for domains without an admin" do
      config = Admin::DomainRouting.ranking_configuration_config(Books::RankingConfiguration.new)

      assert_equal :books, config[:domain]
      assert_equal "Books::List", config[:list_type]
      assert_nil config[:path]
    end

    test "penalty_class resolves a type string" do
      assert_equal Music::Penalty, Admin::DomainRouting.penalty_class("Music::Penalty")
      assert_equal Games::Penalty, Admin::DomainRouting.penalty_class("Games::Penalty")
      assert_equal Books::Penalty, Admin::DomainRouting.penalty_class("Books::Penalty")
      assert_equal Global::Penalty, Admin::DomainRouting.penalty_class("nonsense")
    end

    test "parent_from_params finds a nested parent scoped to the domain" do
      artist = music_artists(:david_bowie)
      found = Admin::DomainRouting.parent_from_params(
        ActionController::Parameters.new(artist_id: artist.id),
        domain: :music
      )

      assert_equal artist, found
    end

    test "parent_from_params ignores params belonging to another domain" do
      game = games_games(:breath_of_the_wild)
      found = Admin::DomainRouting.parent_from_params(
        ActionController::Parameters.new(game_id: game.id),
        domain: :music
      )

      assert_nil found
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`
Expected: FAIL — `NameError: uninitialized constant Admin::DomainRouting`

- [ ] **Step 3: Write the registry**

Create `app/lib/admin/domain_routing.rb`. The path lambdas are defined in the module body, so `self` inside them is the module — which extends `url_helpers`, making `admin_album_path` resolve.

```ruby
module Admin
  module DomainRouting
    extend Rails.application.routes.url_helpers

    ENTITIES = {
      "Music::Artist" => {domain: :music, path: ->(r) { admin_artist_path(r) }},
      "Music::Album" => {domain: :music, path: ->(r) { admin_album_path(r) }},
      "Music::Song" => {domain: :music, path: ->(r) { admin_song_path(r) }},
      "Games::Game" => {domain: :games, path: ->(r) { admin_games_game_path(r) }},
      "Games::Company" => {domain: :games, path: ->(r) { admin_games_company_path(r) }}
    }.freeze

    NESTED_PARENTS = {
      music: {
        artist_id: "Music::Artist",
        album_id: "Music::Album",
        song_id: "Music::Song"
      },
      games: {
        game_id: "Games::Game",
        company_id: "Games::Company"
      }
    }.freeze

    LISTS = {
      "Music::Albums::List" => {
        domain: :music,
        listable_type: "Music::Album",
        item_label: "Album",
        path: ->(l) { admin_albums_list_path(l) },
        autocomplete_path: -> { search_admin_albums_path }
      },
      "Music::Songs::List" => {
        domain: :music,
        listable_type: "Music::Song",
        item_label: "Song",
        path: ->(l) { admin_songs_list_path(l) },
        autocomplete_path: -> { search_admin_songs_path }
      },
      "Games::List" => {
        domain: :games,
        listable_type: "Games::Game",
        item_label: "Game",
        path: ->(l) { admin_games_list_path(l) },
        autocomplete_path: -> { search_admin_games_games_path }
      }
    }.freeze

    RANKING_CONFIGURATIONS = {
      "Music::Albums::RankingConfiguration" => {
        domain: :music,
        list_type: "Music::Albums::List",
        ranked_item_includes: {item: :artists},
        path: ->(rc) { admin_albums_ranking_configuration_path(rc) }
      },
      "Music::Songs::RankingConfiguration" => {
        domain: :music,
        list_type: "Music::Songs::List",
        ranked_item_includes: {item: :artists},
        path: ->(rc) { admin_songs_ranking_configuration_path(rc) }
      },
      "Music::Artists::RankingConfiguration" => {
        domain: :music,
        list_type: nil,
        ranked_item_includes: nil,
        path: ->(rc) { admin_artists_ranking_configuration_path(rc) }
      },
      "Games::RankingConfiguration" => {
        domain: :games,
        list_type: "Games::List",
        ranked_item_includes: {item: :companies},
        path: ->(rc) { admin_games_ranking_configuration_path(rc) }
      },
      "Books::RankingConfiguration" => {
        domain: :books,
        list_type: "Books::List",
        ranked_item_includes: nil,
        path: nil
      },
      "Movies::RankingConfiguration" => {
        domain: :movies,
        list_type: "Movies::List",
        ranked_item_includes: nil,
        path: nil
      }
    }.freeze

    PENALTIES = {
      "Global::Penalty" => "Global::Penalty",
      "Music::Penalty" => "Music::Penalty",
      "Games::Penalty" => "Games::Penalty",
      "Books::Penalty" => "Books::Penalty",
      "Movies::Penalty" => "Movies::Penalty"
    }.freeze

    class << self
      def domain_for(record_or_class)
        name = record_or_class.is_a?(Class) ? record_or_class.name : record_or_class.class.name

        ENTITIES.dig(name, :domain) ||
          LISTS.dig(name, :domain) ||
          RANKING_CONFIGURATIONS.dig(name, :domain)
      end

      def path_for(record)
        ENTITIES.dig(record.class.name, :path)&.call(record)
      end

      def list_config(list)
        resolve(LISTS[list.class.name], list)
      end

      def ranking_configuration_config(ranking_configuration)
        resolve(RANKING_CONFIGURATIONS[ranking_configuration.class.name], ranking_configuration)
      end

      def penalty_class(type_string)
        PENALTIES.fetch(type_string.to_s, "Global::Penalty").constantize
      end

      def parent_from_params(params, domain:)
        NESTED_PARENTS.fetch(domain.to_sym, {}).each do |param_key, class_name|
          id = params[param_key]
          return class_name.constantize.find(id) if id.present?
        end

        nil
      end

      private

      def resolve(config, record)
        return nil if config.nil?

        config.merge(
          path: config[:path]&.call(record),
          autocomplete_path: config[:autocomplete_path]&.call
        )
      end
    end
  end
end
```

`resolve` calls the lambdas and returns a hash of plain values. Books and movies have `path: nil`, so `config[:path]` is `nil` and callers fall through to their existing `music_root_path` default — exactly today's behavior.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/admin/domain_routing_test.rb`
Expected: PASS, 13 runs, 0 failures.

If a fixture name is wrong you will see `NoMethodError: undefined method 'music_albums'` or a missing-fixture error — fix the fixture reference, not the registry.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/admin/domain_routing.rb test/lib/admin/domain_routing_test.rb
git add app/lib/admin/domain_routing.rb test/lib/admin/domain_routing_test.rb
git commit -m "Add Admin::DomainRouting registry"
```

---

### Task 2: `Admin::DomainNav`

The admin chrome config: layout, root path, title, sidebar items per domain. Nothing consumes it yet — Tasks 3 and 7 do.

**Files:**
- Create: `app/lib/admin/domain_nav.rb`
- Test: `test/lib/admin/domain_nav_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Admin::DomainNav.layout_for(domain)` → `String` — always returns a real layout, falling back to `"music/admin"`
  - `Admin::DomainNav.config_for(domain)` → `Hash | nil` with keys `:title, :root_path, :logo, :items`
  - Each item: `{label: String, path: String, icon: String}` where `icon` is a Heroicons-style `d` attribute path string.

- [ ] **Step 1: Write the failing test**

Create `test/lib/admin/domain_nav_test.rb`:

```ruby
require "test_helper"

module Admin
  class DomainNavTest < ActiveSupport::TestCase
    test "layout_for returns the domain admin layout" do
      assert_equal "music/admin", Admin::DomainNav.layout_for(:music)
      assert_equal "games/admin", Admin::DomainNav.layout_for(:games)
    end

    test "layout_for falls back to music for domains with no admin layout" do
      assert_equal "music/admin", Admin::DomainNav.layout_for(:books)
      assert_equal "music/admin", Admin::DomainNav.layout_for(:movies)
      assert_equal "music/admin", Admin::DomainNav.layout_for(nil)
    end

    test "every layout_for result names a template that exists" do
      [:music, :games, :books, :movies, nil].each do |domain|
        layout = Admin::DomainNav.layout_for(domain)
        assert File.exist?(Rails.root.join("app/views/layouts/#{layout}.html.erb")),
          "layout #{layout} for domain #{domain.inspect} does not exist"
      end
    end

    test "config_for returns title, root path, section heading and nav items" do
      config = Admin::DomainNav.config_for(:games)

      assert_equal "The Greatest Games", config[:title]
      assert_equal "/admin", config[:root_path]
      assert_equal "Games", config[:section_label]
      assert config[:section_icon].present?
      assert config[:items].any?
    end

    test "nav items all carry a label, path and icon" do
      [:music, :games].each do |domain|
        Admin::DomainNav.config_for(domain)[:items].each do |item|
          assert item[:label].present?, "#{domain} item missing label"
          assert item[:path].present?, "#{domain} item #{item[:label]} missing path"
          assert item[:icon].present?, "#{domain} item #{item[:label]} missing icon"
        end
      end
    end

    test "config_for returns nil for a domain with no admin" do
      assert_nil Admin::DomainNav.config_for(:books)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: FAIL — `NameError: uninitialized constant Admin::DomainNav`

- [ ] **Step 3: Write the nav config**

Create `app/lib/admin/domain_nav.rb`. The icon strings are lifted **verbatim** from the `d="..."` attributes currently in `app/views/admin/shared/_sidebar.html.erb` — open that file and copy each one across so the rendered sidebar is pixel-identical. The ones below are the current values; verify each against the file as you go.

```ruby
module Admin
  module DomainNav
    extend Rails.application.routes.url_helpers

    FALLBACK_LAYOUT = "music/admin"

    ICONS = {
      artist: "M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z",
      album: "M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3",
      list: "M4 6h16M4 10h16M4 14h16M4 18h16",
      category: "M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z",
      chart: "M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z",
      chat: "M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z",
      game: "M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z",
      company: "M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4",
      platform: "M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z",
      series: "M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
    }.freeze

    CONFIGS = {
      music: {
        layout: "music/admin",
        title: "The Greatest Music",
        section_label: "Music",
        section_icon: ICONS[:album],
        logo: {type: :image, value: "music/logo.gif"},
        root_path: -> { admin_root_path },
        items: [
          {label: "Artists", icon: :artist, path: -> { admin_artists_path }},
          {label: "Albums", icon: :album, path: -> { admin_albums_path }},
          {label: "Songs", icon: :album, path: -> { admin_songs_path }},
          {label: "Lists: Albums", icon: :list, path: -> { admin_albums_lists_path }},
          {label: "Lists: Songs", icon: :list, path: -> { admin_songs_lists_path }},
          {label: "Rankings: Album", icon: :chart, path: -> { admin_albums_ranking_configurations_path }},
          {label: "Rankings: Song", icon: :chart, path: -> { admin_songs_ranking_configurations_path }},
          {label: "Rankings: Artist", icon: :chart, path: -> { admin_artists_ranking_configurations_path }},
          {label: "AI Chats", icon: :chat, path: -> { admin_ai_chats_path }},
          {label: "Categories", icon: :category, path: -> { admin_categories_path }}
        ]
      },
      games: {
        layout: "games/admin",
        title: "The Greatest Games",
        section_label: "Games",
        section_icon: ICONS[:game],
        logo: {type: :emoji, value: "🎮"},
        root_path: -> { admin_root_path },
        items: [
          {label: "Games", icon: :game, path: -> { admin_games_games_path }},
          {label: "Companies", icon: :company, path: -> { admin_games_companies_path }},
          {label: "Platforms", icon: :platform, path: -> { admin_games_platforms_path }},
          {label: "Series", icon: :series, path: -> { admin_games_series_index_path }},
          {label: "Categories", icon: :category, path: -> { admin_games_categories_path }},
          {label: "Lists", icon: :list, path: -> { admin_games_lists_path }},
          {label: "Rankings", icon: :chart, path: -> { admin_games_ranking_configurations_path }}
        ]
      }
    }.freeze

    class << self
      def layout_for(domain)
        CONFIGS.dig(domain&.to_sym, :layout) || FALLBACK_LAYOUT
      end

      def config_for(domain)
        config = CONFIGS[domain&.to_sym]
        return nil if config.nil?

        config.merge(
          root_path: config[:root_path].call,
          items: config[:items].map do |item|
            item.merge(path: item[:path].call, icon: ICONS.fetch(item[:icon]))
          end
        )
      end
    end
  end
end
```

**Copy every `d` path from the current `_sidebar.html.erb` — do not approximate.** The existing sidebar uses a *distinct* icon for several entries that the `ICONS` table above collapses: "Songs", "Rankings: Album", "Rankings: Song", and "Rankings: Artist" each have their own `d` path in the current markup. Open the file, and for every entry whose current `d` differs from the `ICONS` value you mapped it to, **add a new `ICONS` key** (e.g. `song:`, `rankings_album:`, `rankings_song:`, `rankings_artist:`) rather than reusing an approximate one. The `section_icon` values above are correct as written: the music `<summary>` uses the same note path as `:album`, and the games `<summary>` uses the same controller path as `:game`.

No test will catch a wrong icon — Task 7's e2e specs assert links, not SVG paths. A wrong icon silently changes the UI, which this increment must not do.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/admin/domain_nav_test.rb`
Expected: PASS, 6 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/admin/domain_nav.rb test/lib/admin/domain_nav_test.rb
git add app/lib/admin/domain_nav.rb test/lib/admin/domain_nav_test.rb
git commit -m "Add Admin::DomainNav admin chrome config"
```

---

### Task 3: Dynamic admin layout (the bug fix)

**Files:**
- Modify: `app/controllers/admin/base_controller.rb`
- Modify: `app/controllers/admin/penalties_controller.rb:2` (remove `layout "music/admin"`)
- Modify: `app/controllers/admin/users_controller.rb:2` (remove `layout "music/admin"`)
- Modify: `app/controllers/admin/ranked_lists_controller.rb:4` (remove `layout "music/admin", only: [:show]`)
- Test: `test/controllers/admin/penalties_controller_test.rb`, `test/controllers/admin/users_controller_test.rb`

**Interfaces:**
- Consumes: `Admin::DomainNav.layout_for(domain)` from Task 2.
- Produces: `Admin::BaseController` renders `Admin::DomainNav.layout_for(current_domain)` for every admin controller that does not override `layout`. `Admin::Music::BaseController` and `Admin::Games::BaseController` keep their explicit `layout` declarations — they are correct and are the domains' own choice.

This is the one deliberate behavior change in the increment: a games admin visiting `/admin/penalties`, `/admin/users`, or `/admin/ranked_lists/:id` now gets `games/admin` instead of `music/admin`.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/admin/penalties_controller_test.rb` (inside the existing class — read it first to match its `setup` and its `sign_in_as` usage):

```ruby
test "renders the games layout when browsing from the games host" do
  host! Rails.application.config.domains[:games]
  sign_in_as(@admin_user, stub_auth: true)

  get admin_penalties_path

  assert_response :success
  assert_select "aside[data-testid=admin-sidebar]"
  assert_select "h1", text: "The Greatest Games"
end

test "renders the music layout when browsing from the music host" do
  host! Rails.application.config.domains[:music]
  sign_in_as(@admin_user, stub_auth: true)

  get admin_penalties_path

  assert_response :success
  assert_select "h1", text: "The Greatest Music"
end
```

Add the equivalent pair to `test/controllers/admin/users_controller_test.rb` against `admin_users_path`. Use whatever admin-user fixture and sign-in helper those files already use — do not introduce a new one.

- [ ] **Step 2: Run the tests to verify the games one fails**

Run: `bin/rails test test/controllers/admin/penalties_controller_test.rb test/controllers/admin/users_controller_test.rb`
Expected: the two "games host" tests FAIL — the rendered `h1` is "The Greatest Music", proving the bug. The two "music host" tests PASS.

- [ ] **Step 3: Make the layout dynamic**

In `app/controllers/admin/base_controller.rb`, add the layout declaration below the includes:

```ruby
class Admin::BaseController < ApplicationController
  include Pagy::Method
  include Cacheable

  layout :admin_layout

  before_action :authenticate_admin!
  before_action :prevent_caching

  private

  def admin_layout
    Admin::DomainNav.layout_for(current_domain)
  end
```

Then delete the hardcoded layout lines:
- `app/controllers/admin/penalties_controller.rb` — remove line 2, `layout "music/admin"`
- `app/controllers/admin/users_controller.rb` — remove line 2, `layout "music/admin"`
- `app/controllers/admin/ranked_lists_controller.rb` — remove line 4, `layout "music/admin", only: [:show]`

Leave `Admin::Music::BaseController`'s `layout "music/admin"` and `Admin::Games::BaseController`'s `layout "games/admin"` alone, along with the `layout "games/admin"` / `layout "music/admin"` lines in the domain lists/categories/ranking-configuration subclasses. Those are correct, and removing them is a separate cleanup that would widen this diff.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/penalties_controller_test.rb test/controllers/admin/users_controller_test.rb test/controllers/admin/ranked_lists_controller_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 5: Run the full admin suite for regressions**

Run: `bin/rails test test/controllers/admin/`
Expected: PASS, 0 failures. Any failure here means a controller was relying on the music layout — investigate rather than editing the test.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/
git add app/controllers/admin/base_controller.rb app/controllers/admin/penalties_controller.rb app/controllers/admin/users_controller.rb app/controllers/admin/ranked_lists_controller.rb test/controllers/admin/penalties_controller_test.rb test/controllers/admin/users_controller_test.rb
git commit -m "Serve each domain its own admin layout

Admin::PenaltiesController, Admin::UsersController and
Admin::RankedListsController#show hardcoded layout \"music/admin\". Those
routes live in the global admin namespace, outside every domain constraint,
so a games admin clicking Penalties or Users was served the music layout —
music logo, music CSS bundle, music sidebar. The layout now resolves from
the current domain."
```

---

### Task 4: `Admin::DomainScopedAuth`

Eight controllers carry a verbatim copy of the same `authenticate_admin!` override. Collapse them into one concern, and absorb `RankingConfigurationDomainAuth` into it.

**Files:**
- Create: `app/controllers/concerns/admin/domain_scoped_auth.rb`
- Delete: `app/controllers/concerns/ranking_configuration_domain_auth.rb`
- Modify: `app/controllers/admin/music/{base,lists,categories,ranking_configurations}_controller.rb`
- Modify: `app/controllers/admin/games/{base,lists,categories,ranking_configurations}_controller.rb`
- Modify: `app/controllers/admin/{ranked_lists,ranked_items}_controller.rb` (they include `RankingConfigurationDomainAuth`)

**Interfaces:**
- Consumes: nothing (uses `current_domain` from `ApplicationController`).
- Produces: `Admin::DomainScopedAuth`, a concern overriding `authenticate_admin!`. Including classes may override the protected `domain_for_auth` (default: `current_domain.to_s`) to derive the domain from a record instead of the hostname.

`Admin::BaseController#authenticate_admin!` keeps its global-admin/editor-only semantics — the global controllers (penalties, users, cloudflare) must NOT be loosened by this task.

- [ ] **Step 1: Write the failing test**

The existing per-controller auth tests already cover this behavior (they assert a games-domain user can reach games admin and is redirected from music admin). They are the regression net. Add one focused test for the concern's fallback in `test/controllers/admin/domain_isolation_test.rb` — read the file first and match its existing style:

```ruby
test "a games-domain user reaches games admin but not music admin" do
  games_user = users(:regular_user)
  games_user.domain_roles.create!(domain: :games, permission_level: :editor)
  sign_in_as(games_user, stub_auth: true)

  host! Rails.application.config.domains[:games]
  get admin_games_games_path
  assert_response :success

  host! Rails.application.config.domains[:music]
  get admin_albums_path
  assert_redirected_to music_root_path
end
```

- [ ] **Step 2: Run it to see it pass already**

Run: `bin/rails test test/controllers/admin/domain_isolation_test.rb`
Expected: PASS. This test documents the behavior the refactor must preserve; it is green before and after. That is intentional — this task is a pure refactor with no new behavior, so its safety net is the existing suite, not a new red test.

- [ ] **Step 3: Write the concern**

Create `app/controllers/concerns/admin/domain_scoped_auth.rb`:

```ruby
module Admin
  module DomainScopedAuth
    extend ActiveSupport::Concern

    private

    def authenticate_admin!
      return if current_user&.admin? || current_user&.editor?

      domain = domain_for_auth
      return if domain.present? && current_user&.can_access_domain?(domain)

      redirect_to domain_root_path, alert: "Access denied. You need permission for #{domain || "this"} admin."
    end

    def domain_for_auth
      current_domain&.to_s
    end
  end
end
```

- [ ] **Step 4: Adopt it in the eight domain controllers**

In each of `app/controllers/admin/music/{base,lists,categories,ranking_configurations}_controller.rb` and `app/controllers/admin/games/{base,lists,categories,ranking_configurations}_controller.rb`: delete the `authenticate_admin!` private method entirely and add `include Admin::DomainScopedAuth` at the top of the class. For example, `Admin::Games::BaseController` becomes:

```ruby
class Admin::Games::BaseController < Admin::BaseController
  include Admin::DomainScopedAuth

  layout "games/admin"
end
```

Each of these controllers is reached only through routes inside its own domain's `DomainConstraint`, so `current_domain` is already the right domain — which is exactly why the hardcoded string is redundant.

- [ ] **Step 5: Replace `RankingConfigurationDomainAuth`**

`Admin::RankedListsController` and `Admin::RankedItemsController` are in the **global** admin namespace, so their domain must come from the ranking configuration, not the hostname. In both, swap `include RankingConfigurationDomainAuth` for:

```ruby
  include Admin::DomainScopedAuth

  private

  def domain_for_auth
    config = RankingConfiguration.find_by(id: ranking_configuration_id_for_auth)
    Admin::DomainRouting.domain_for(config)&.to_s if config
  end
```

`Admin::RankedListsController` already defines `ranking_configuration_id_for_auth` (falling back to the ranked list's own config for member routes) — keep it. `Admin::RankedItemsController` uses the concern's old default of `params[:ranking_configuration_id]`; add that method explicitly:

```ruby
  def ranking_configuration_id_for_auth
    params[:ranking_configuration_id]
  end
```

Then delete `app/controllers/concerns/ranking_configuration_domain_auth.rb`.

Note this widens the old concern's behavior: it only matched `/^Games::/` and `/^Music::/`, so a books or movies RC yielded `nil` and was denied. `DomainRouting.domain_for` now returns `:books`/`:movies` for those — but no user can hold a books/movies domain role and reach these routes today, and the global-admin/editor early return is unchanged. Verify with the existing `ranked_lists_controller_test.rb`.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/controllers/admin/`
Expected: PASS, 0 failures.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/
git add app/controllers/ test/controllers/admin/domain_isolation_test.rb
git commit -m "Collapse eight copies of authenticate_admin! into Admin::DomainScopedAuth"
```

---

### Task 5: Consume `DomainRouting` in the shared controllers

**Files:**
- Modify: `app/controllers/admin/images_controller.rb` (`set_parent`, `redirect_path_for_parent`)
- Modify: `app/controllers/admin/category_items_controller.rb` (`set_item`, `redirect_path`)
- Modify: `app/controllers/admin/list_items_controller.rb` (`expected_listable_type_for`, `redirect_path`)
- Modify: `app/controllers/admin/list_penalties_controller.rb` (`redirect_path`)
- Modify: `app/controllers/admin/penalty_applications_controller.rb` (`redirect_path`)
- Modify: `app/controllers/admin/ranked_items_controller.rb` (eager-load `case`)
- Modify: `app/controllers/admin/ranked_lists_controller.rb` (`redirect_path`)
- Modify: `app/controllers/admin/penalties_controller.rb` (`get_penalty_class`)

**Interfaces:**
- Consumes: everything from Task 1.
- Produces: no new interface. Behavior identical.

Every `else` branch that currently falls back to `music_root_path` or `admin_root_path` **stays**. `DomainRouting` returns `nil` for unregistered records, and the `||` keeps the old fallback. Do not "improve" the fallbacks in this task.

- [ ] **Step 1: Run the existing tests to establish the baseline**

Run: `bin/rails test test/controllers/admin/`
Expected: PASS. These tests are the contract — they must still pass unchanged at the end of this task. Write no new tests here; the refactor is covered.

- [ ] **Step 2: Rewrite `Admin::ImagesController`**

Replace `set_parent` and `redirect_path_for_parent`:

```ruby
  def set_parent
    @parent = Admin::DomainRouting.parent_from_params(params, domain: current_domain)
  end

  def redirect_path_for_parent(parent)
    Admin::DomainRouting.path_for(parent) || admin_root_path
  end
```

- [ ] **Step 3: Rewrite `Admin::CategoryItemsController`**

Replace `set_item` and `redirect_path`, and delete the two `# Future: ...` comments:

```ruby
  def set_item
    @item = Admin::DomainRouting.parent_from_params(params, domain: current_domain)
  end

  def redirect_path
    Admin::DomainRouting.path_for(@item) || admin_root_path
  end
```

- [ ] **Step 4: Rewrite `Admin::ListItemsController`**

```ruby
  def expected_listable_type_for(list)
    Admin::DomainRouting.list_config(list)&.dig(:listable_type)
  end

  def redirect_path
    Admin::DomainRouting.list_config(@list)&.dig(:path) || music_root_path
  end
```

- [ ] **Step 5: Rewrite `Admin::ListPenaltiesController#redirect_path`**

```ruby
  def redirect_path
    Admin::DomainRouting.list_config(@list)&.dig(:path) || music_root_path
  end
```

- [ ] **Step 6: Rewrite `Admin::PenaltyApplicationsController#redirect_path` and `Admin::RankedListsController#redirect_path`**

Both currently `case` on `@ranking_configuration.type`. Both become:

```ruby
  def redirect_path
    Admin::DomainRouting.ranking_configuration_config(@ranking_configuration)&.dig(:path) || music_root_path
  end
```

- [ ] **Step 7: Rewrite `Admin::RankedItemsController#index`**

```ruby
  def index
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_items = @ranking_configuration.ranked_items

    includes = Admin::DomainRouting.ranking_configuration_config(@ranking_configuration)&.dig(:ranked_item_includes)
    @ranked_items = @ranked_items.includes(includes) if includes

    @ranked_items = @ranked_items.order(rank: :asc)

    @pagy, @ranked_items = pagy(@ranked_items, limit: 25)

    render layout: false
  end
```

- [ ] **Step 8: Rewrite `Admin::PenaltiesController#get_penalty_class`**

```ruby
  def get_penalty_class(type_string)
    Admin::DomainRouting.penalty_class(type_string)
  end
```

- [ ] **Step 9: Run the tests**

Run: `bin/rails test test/controllers/admin/`
Expected: PASS, 0 failures, **with no test edits**. If a test fails, the registry is missing an entry or a fallback was dropped — fix the code, not the test.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/admin/
git add app/controllers/admin/
git commit -m "Resolve admin domains through Admin::DomainRouting

Replaces the per-domain case statements in the shared admin controllers.
Behavior is unchanged; unregistered records still fall through to the
existing music/admin root fallbacks."
```

---

### Task 6: Consume `DomainRouting` in the modal components

**Files:**
- Modify: `app/components/admin/add_category_modal_component.rb`
- Modify: `app/components/admin/add_item_to_list_modal_component.rb`
- Modify: `app/components/admin/add_list_to_configuration_modal_component.rb`
- Modify: `app/components/admin/edit_list_item_modal_component.rb`
- Test: the existing `test/components/admin/*_modal_component_test.rb` files

**Interfaces:**
- Consumes: everything from Task 1.
- Produces: no new interface. Behavior identical.

`AddCategoryModalComponent#form_url` needs the *nested category-items* path (`admin_album_category_items_path`), which `DomainRouting.path_for` does not provide — it returns the show path. Add a `category_items_path` lambda to each `ENTITIES` entry rather than inventing a second registry:

```ruby
"Music::Album" => {
  domain: :music,
  path: ->(r) { admin_album_path(r) },
  category_items_path: ->(r) { admin_album_category_items_path(r) }
},
```

`Games::Company` has images but no category_items route — give it `category_items_path: nil`. Extend the Task 1 test to assert `ENTITIES` entries that support categories expose a `category_items_path`.

- [ ] **Step 1: Run the existing component tests for a baseline**

Run: `bin/rails test test/components/admin/`
Expected: PASS. Read `add_category_modal_component_test.rb` and `edit_list_item_modal_component_test.rb` first — they are the contract.

- [ ] **Step 2: Add `category_items_path` to `ENTITIES` and a new accessor**

In `app/lib/admin/domain_routing.rb`, add the lambda to each entity that has a nested category-items route (`Music::Artist`, `Music::Album`, `Music::Song`, `Games::Game`) and add:

```ruby
      def category_items_path_for(record)
        ENTITIES.dig(record.class.name, :category_items_path)&.call(record)
      end
```

Add to `test/lib/admin/domain_routing_test.rb`:

```ruby
test "category_items_path_for returns the nested category items path" do
  album = music_albums(:dark_side_of_the_moon)
  assert_equal "/admin/albums/#{album.to_param}/category_items",
    Admin::DomainRouting.category_items_path_for(album)
end

test "category_items_path_for returns nil for an entity without categories" do
  assert_nil Admin::DomainRouting.category_items_path_for(games_companies(:nintendo))
end
```

- [ ] **Step 3: Rewrite `AddCategoryModalComponent`**

```ruby
class Admin::AddCategoryModalComponent < ViewComponent::Base
  def initialize(item:)
    @item = item
  end

  def form_url
    Admin::DomainRouting.category_items_path_for(@item)
  end

  def search_url
    if Admin::DomainRouting.domain_for(@item) == :games
      helpers.search_admin_games_categories_path
    else
      helpers.search_admin_categories_path
    end
  end

  def item_type_label
    @item.class.name.demodulize.downcase
  end
end
```

`search_url` keeps its music-default shape because that is exactly what it does today. Categories are domain-scoped STI, so increment 3 will add a books arm here — a `categories_search_path` entry per domain in `DomainNav` would be the right home for it then, but adding it now would be speculative.

- [ ] **Step 4: Rewrite `AddItemToListModalComponent`**

```ruby
class Admin::AddItemToListModalComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
    @config = Admin::DomainRouting.list_config(list) || {}
  end

  def autocomplete_url
    @config[:autocomplete_path]
  end

  def expected_listable_type
    @config[:listable_type]
  end

  def item_label
    @config.fetch(:item_label, "Item")
  end
end
```

- [ ] **Step 5: Rewrite `EditListItemModalComponent`**

Replace only `autocomplete_url` and `item_label`; leave `item_display_name`, `unverified_item_display_name`, and `metadata_json` untouched.

```ruby
  def initialize(list_item:)
    @list_item = list_item
    @list = list_item.list
    @config = Admin::DomainRouting.list_config(@list) || {}
  end

  def autocomplete_url
    @config[:autocomplete_path]
  end

  def item_label
    @config.fetch(:item_label, "Item")
  end
```

- [ ] **Step 6: Rewrite `AddListToConfigurationModalComponent#available_lists`**

This one **already** handles books and movies. Preserve that.

```ruby
  def available_lists
    list_type = Admin::DomainRouting.ranking_configuration_config(@ranking_configuration)&.dig(:list_type)

    return List.none if list_type.nil?

    already_added_list_ids = @ranking_configuration.ranked_lists.pluck(:list_id)

    List
      .where(type: list_type)
      .where(status: [:active, :approved])
      .where.not(id: already_added_list_ids)
      .order(created_at: :desc)
  end
```

`Music::Artists::RankingConfiguration` has `list_type: nil` in the registry, so it still returns `List.none` — matching today, where it falls off the end of the `case`.

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/components/admin/ test/lib/admin/`
Expected: PASS, 0 failures, no test edits beyond the two added in Step 2.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/components/admin/ app/lib/admin/ test/lib/admin/
git add app/components/admin/ app/lib/admin/ test/lib/admin/
git commit -m "Resolve modal component paths through Admin::DomainRouting"
```

---

### Task 7: Data-driven sidebar

**Files:**
- Modify: `app/views/admin/shared/_sidebar.html.erb`
- Test: `e2e/tests/music/admin/sidebar-nav.spec.ts`, `e2e/tests/games/admin/sidebar-nav.spec.ts` (existing — must pass unchanged)

**Interfaces:**
- Consumes: `Admin::DomainNav.config_for(current_domain)` from Task 2.
- Produces: no new interface. The rendered sidebar must be equivalent — same links, same order, same labels, same icons, same `data-testid="admin-sidebar"`.

- [ ] **Step 1: Read the existing e2e sidebar specs**

Read `e2e/tests/games/admin/sidebar-nav.spec.ts` and `e2e/tests/music/admin/sidebar-nav.spec.ts`. They assert the links present in each domain's sidebar and are the contract for this task. Do not edit them.

- [ ] **Step 2: Rewrite the sidebar**

Replace the `if current_domain == :games / else` block in `app/views/admin/shared/_sidebar.html.erb` with a render over `Admin::DomainNav`. Keep the Global section, the user-info footer, and the outer `<aside data-testid="admin-sidebar">` exactly as they are — only the domain block changes.

```erb
<% nav = Admin::DomainNav.config_for(current_domain) %>
<aside class="flex flex-col h-full bg-base-100 w-80" data-testid="admin-sidebar">
  <div class="p-6 border-b border-base-300">
    <%= link_to (nav ? nav[:root_path] : admin_root_path), class: "flex items-center gap-3 hover:opacity-80 transition-opacity" do %>
      <% if nav&.dig(:logo, :type) == :emoji %>
        <span class="text-3xl"><%= nav[:logo][:value] %></span>
      <% else %>
        <%= image_tag(nav&.dig(:logo, :value) || "music/logo.gif", alt: nav&.dig(:title), class: "w-10 h-10") %>
      <% end %>
      <div>
        <h1 class="text-xl font-bold"><%= nav&.dig(:title) || "The Greatest" %></h1>
        <p class="text-sm text-base-content/70">Admin</p>
      </div>
    <% end %>
  </div>

  <div class="flex-1 overflow-y-auto">
    <ul class="menu p-4 gap-2">
      <% if nav %>
        <li>
          <details open>
            <summary class="font-semibold">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="<%= nav[:section_icon] %>" />
              </svg>
              <%= nav[:section_label] %>
            </summary>
            <ul>
              <% nav[:items].each do |item| %>
                <li>
                  <%= link_to item[:path], class: "flex items-center gap-2" do %>
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="<%= item[:icon] %>" />
                    </svg>
                    <%= item[:label] %>
                  <% end %>
                </li>
              <% end %>
            </ul>
          </details>
        </li>
      <% end %>

      <%# Global section — unchanged, paste the existing block here verbatim %>
    </ul>
  </div>

  <%# User info footer — unchanged, paste the existing block here verbatim %>
</aside>
```

`section_label` and `section_icon` come from the `CONFIGS` entries defined in Task 2, so the `<summary>` heading renders unchanged.

- [ ] **Step 3: Verify the rendered sidebar by eye**

Start the dev server (`bin/dev`) and load the music admin and the games admin. Compare each against `git stash`-ed original if unsure. Same links, same order, same icons.

- [ ] **Step 4: Run the e2e sidebar specs**

Run: `yarn test:e2e --grep sidebar`
Expected: PASS for both music and games, **with no spec edits**. (Needs a running dev server and `e2e/.env`.)

- [ ] **Step 5: Run the full suite**

Run: `bin/rails test && bin/rails test:system && bundle exec standardrb`
Expected: all green, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/views/admin/shared/_sidebar.html.erb app/lib/admin/domain_nav.rb
git commit -m "Render the admin sidebar from Admin::DomainNav

Replaces the if-games/else-music block. Adding a domain is now an entry in
CONFIGS rather than a third branch."
```

---

## Done when

- `bin/rails test` — green, ~4,500 tests, and **no existing test was edited** except the layout assertions added in Task 3.
- `bin/rails test:system` — green.
- `bundle exec standardrb` — clean.
- `yarn test:e2e` — green.
- `grep -rn 'Music::\|Games::' app/controllers/admin/*.rb app/components/admin/*.rb` returns no per-domain `case`/`when` dispatch (the `app/controllers/admin/{music,games}/` subdirectories are domain-specific by design and are expected to match).
- A games admin loading `/admin/penalties` sees the games sidebar and logo.
