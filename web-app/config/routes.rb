Rails.application.routes.draw do
  # rails_icons preview UI is only useful in development
  mount RailsIcons::Engine, at: "/rails_icons" if Rails.env.development?

  # Music domain routes (scoped within domain constraint)
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    # All music routes are prefixed with 'music_' for route helpers to avoid
    # conflicts when other domains (games, movies) add similar resources
    scope as: "music" do
      # Lists overview and public submission
      resources :lists, only: [:index, :new, :create], controller: "music/lists"

      # Search
      get "search", to: "music/searches#index"
    end

    # Artist rankings (outside rc scope - always uses default primary configs for both albums and songs)
    get "artists", to: "music/artists/ranked_items#index", as: :artists
    get "artists/page/:page", to: "music/artists/ranked_items#index", as: :artists_page, constraints: {page: /\d+/}

    # Category pages (outside rc scope - always uses default primary configs for both artists and albums)
    get "categories/:id", to: "music/categories#show", as: :music_category

    # All music routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      # Album routes
      get "albums", to: "music/albums/ranked_items#index", as: :albums
      get "albums/page/:page", to: "music/albums/ranked_items#index", as: :albums_page, constraints: {page: /\d+/}
      get "albums/lists", to: "music/albums/lists#index", as: :music_albums_lists
      get "albums/lists/page/:page", to: "music/albums/lists#index", as: :music_albums_lists_page, constraints: {page: /\d+/}
      get "albums/lists/:id", to: "music/albums/lists#show", as: :music_album_list
      get "albums/lists/:id/page/:page", to: "music/albums/lists#show", as: :music_album_list_page, constraints: {page: /\d+/}
      get "albums/categories/:id", to: "music/albums/categories#show", as: :music_album_category
      get "albums/categories/:id/page/:page", to: "music/albums/categories#show", as: :music_album_category_page, constraints: {page: /\d+/}
      # Year-filtered albums (must come before :id to avoid treating "1990s" as a slug)
      get "albums/since/:year", to: "music/albums/ranked_items#index", as: :albums_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "albums/since/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "albums/through/:year", to: "music/albums/ranked_items#index", as: :albums_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "albums/through/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "albums/:year", to: "music/albums/ranked_items#index", as: :albums_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "albums/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "album/:slug", to: "music/albums#show", as: :album

      # Song routes
      get "songs", to: "music/songs/ranked_items#index", as: :songs
      get "songs/page/:page", to: "music/songs/ranked_items#index", as: :songs_page, constraints: {page: /\d+/}
      get "songs/lists", to: "music/songs/lists#index", as: :music_songs_lists
      get "songs/lists/page/:page", to: "music/songs/lists#index", as: :music_songs_lists_page, constraints: {page: /\d+/}
      get "songs/lists/:id", to: "music/songs/lists#show", as: :music_song_list
      get "songs/lists/:id/page/:page", to: "music/songs/lists#show", as: :music_song_list_page, constraints: {page: /\d+/}
      # Year-filtered songs (must come before :id to avoid treating "1990s" as a slug)
      get "songs/since/:year", to: "music/songs/ranked_items#index", as: :songs_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "songs/since/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "songs/through/:year", to: "music/songs/ranked_items#index", as: :songs_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "songs/through/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "songs/:year", to: "music/songs/ranked_items#index", as: :songs_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "songs/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "song/:slug", to: "music/songs#show", as: :song

      # Artist routes
      get "artists/categories/:id", to: "music/artists/categories#show", as: :music_artist_category
      get "artists/categories/:id/page/:page", to: "music/artists/categories#show", as: :music_artist_category_page, constraints: {page: /\d+/}
      get "artists/:id", to: "music/artists#show", as: :artist
    end

    # Admin interface for music domain
    namespace :admin, module: "admin/music" do
      root to: "dashboard#index"

      # MusicBrainz search endpoints (shared across admin features)
      scope :musicbrainz, controller: "musicbrainz_search", as: "musicbrainz" do
        get :artists
      end

      # Ranking configuration routes must come BEFORE the resource routes
      # to prevent friendly_id from treating "ranking_configurations" as a slug
      namespace :artists do
        resources :ranking_configurations do
          member do
            post :execute_action
          end
          collection do
            post :index_action
          end
        end
      end

      namespace :albums do
        resources :ranking_configurations do
          member do
            post :execute_action
          end
          collection do
            post :index_action
          end
        end

        resources :lists do
          resource :wizard, only: [:show], controller: "list_wizard" do
            get "step/:step", action: :show_step, as: :step
            get "step/:step/status", action: :step_status, as: :step_status
            post "step/:step/advance", action: :advance_step, as: :advance_step
            post "step/:step/back", action: :back_step, as: :back_step
            post "save_html", action: :save_html, as: :save_html
            post "reparse", action: :reparse, as: :reparse
            post "restart", action: :restart
            get "musicbrainz_release_search", to: "list_items_actions#musicbrainz_release_search", as: :musicbrainz_release_search
          end

          resources :items, controller: "list_items_actions", only: [] do
            member do
              get "modal/:modal_type", action: :modal, as: :modal
              post :verify
              post :skip
              patch :metadata
              post :re_enrich
              post :manual_link
              post :link_musicbrainz_release
              post :link_musicbrainz_artist
              post :link_musicbrainz_url
              post :queue_import
              delete :destroy
            end

            collection do
              post :bulk_verify
              post :bulk_skip
              delete :bulk_delete
            end
          end
        end
      end

      namespace :songs do
        resources :ranking_configurations do
          member do
            post :execute_action
          end
          collection do
            post :index_action
          end
        end

        resources :lists do
          resource :wizard, only: [:show], controller: "list_wizard" do
            get "step/:step", action: :show_step, as: :step
            get "step/:step/status", action: :step_status, as: :step_status
            post "step/:step/advance", action: :advance_step, as: :advance_step
            post "step/:step/back", action: :back_step, as: :back_step
            post "save_html", action: :save_html, as: :save_html
            post "reparse", action: :reparse, as: :reparse
            post "restart", action: :restart
            get "musicbrainz_recording_search", to: "list_items_actions#musicbrainz_recording_search", as: :musicbrainz_recording_search
          end

          resources :items, controller: "list_items_actions", only: [] do
            member do
              get "modal/:modal_type", action: :modal, as: :modal
              post :verify
              post :skip
              patch :metadata
              post :re_enrich
              post :manual_link
              post :link_musicbrainz_recording
              post :link_musicbrainz_artist
              post :link_musicbrainz_url
              post :queue_import
              delete :destroy
            end

            collection do
              post :bulk_verify
              post :bulk_skip
              delete :bulk_delete
            end
          end
        end
      end

      resources :artists do
        resources :album_artists, only: [:create], shallow: true
        resources :song_artists, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :import_from_musicbrainz
          post :bulk_action
          post :index_action
          get :search
        end
      end

      resources :albums do
        resources :album_artists, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :bulk_action
          get :search
        end
      end

      resources :album_artists, only: [:update, :destroy]

      resources :songs do
        resources :song_artists, only: [:create], shallow: true
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        member do
          post :execute_action
        end
        collection do
          post :bulk_action
          get :search
        end
      end

      resources :song_artists, only: [:update, :destroy]

      resources :ai_chats, only: [:index, :show]

      resources :categories do
        collection do
          get :search
        end
      end
    end
  end
  require "sidekiq/web"
  require "sidekiq/cron/web"

  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_ADMIN_USERNAME"].to_s)) &
      ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_ADMIN_PASSWORD"].to_s))
  end
  mount Sidekiq::Web => "/sidekiq-admin"

  post "auth/sign_in"
  post "auth/sign_out"
  post "auth/check_provider"

  # User-list endpoints — global (non-domain-constrained), JSON-only.
  # The state endpoint is scoped to Current.domain via the controller.
  get "user_list_state", to: "user_list_state#show", as: :user_list_state
  post "user_lists", to: "user_lists#create", as: :user_lists
  post "user_lists/:user_list_id/items",
    to: "user_list_items#create",
    as: :user_list_items
  delete "user_lists/:user_list_id/items/:id",
    to: "user_list_items#destroy",
    as: :user_list_item

  # Type-scoped typeahead for the "add item from list page" search box (02e).
  # Signed-in, never cached; scoped by listable_type (e.g. Music::Album).
  get "listable_search", to: "listable_searches#index", as: :listable_search

  # My Lists read surface (Phase A) — global, never cached, per-domain layout
  # resolved from Current.domain in the controller. Owner-only HTML + CSV.
  get "my/lists", to: "my_lists#index", as: :my_lists
  get "my/lists/:id", to: "my_lists#show", as: :my_list
  get "my/lists/:id/page/:page", to: "my_lists#show", as: :my_list_page, constraints: {page: /\d+/}

  # Compatibility alias: the books site (and earlier Greatest sites) link to a
  # user list at /user_lists/:id. Point it at the same owner-only show action so
  # those URLs keep working once books migrates onto this app. (The POST create
  # and nested item routes below are distinct verbs/paths and don't conflict.)
  get "user_lists/:id", to: "my_lists#show", as: :user_list
  get "user_lists/:id/page/:page", to: "my_lists#show", as: :user_list_page, constraints: {page: /\d+/}

  # Domain-specific roots using Default controllers
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    get "rankings", to: "music/default#rankings", as: :music_rankings
    root to: "music/default#index", as: :music_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:movies]) do
    root to: "movies/default#index", as: :movies_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:books]) do
    # Admin interface for books domain
    namespace :admin, module: "admin/books", as: "admin_books" do
      root to: "dashboard#index"

      resources :books do
        resources :editions, shallow: true do
          member do
            post :set_default
          end
          resources :images, only: [:index, :create], controller: "/admin/images"
          resources :credits, only: [:create]
        end
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :book_authors, only: [:create]
        resources :book_relationships, only: [:create]
        resources :credits, only: [:create]
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        collection do
          get :search
        end
      end

      resources :book_authors, only: [:update, :destroy]
      resources :book_relationships, only: [:update, :destroy]
      resources :credits, only: [:update, :destroy]
      resources :author_relationships, only: [:update, :destroy]
      resources :authors do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :author_relationships, only: [:create]
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        collection do
          get :search
        end
      end

      resources :series do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        resources :series_books, only: [:create]
      end
      resources :series_books, only: [:update, :destroy] do
        member do
          post :make_representative
        end
      end

      resources :categories do
        collection do
          get :search
        end
      end

      resources :lists

      resources :ranking_configurations do
        member { post :execute_action }
        collection { post :index_action }
      end
    end

    scope "(/rc/:ranking_configuration_id)" do
      get "book/:slug", to: "books/books#show", as: :book
    end

    # Legacy 301s. /books/:id is the legacy CANONICAL book url (~156k indexed);
    # /items/:id is its older alias. Legacy rc ids are meaningless here, so the
    # rc segment is matched and discarded.
    scope "(/rc/:ranking_configuration_id)" do
      get "books/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}
    end
    get "items/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}

    # Ranked index. Root is canonical; pagination is path-based.
    # Order matters: /page/1 must precede the generic /page/:page.
    root to: "books/ranked_items#index", as: :books_root
    get "page/1", to: redirect("/", status: 301)
    get "page/:page", to: "books/ranked_items#index", as: :books_page, constraints: {page: /\d+/}
    get "the-greatest-books", to: redirect("/", status: 301)
    get "rc/:ranking_configuration_id", to: "books/ranked_items#index", as: :books_rc
    get "rc/:ranking_configuration_id/page/:page", to: "books/ranked_items#index",
      as: :books_rc_page, constraints: {page: /\d+/}
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:games]) do
    # Admin interface for games domain
    namespace :admin, module: "admin/games", as: "admin_games" do
      root to: "dashboard#index"

      resources :games do
        resources :game_companies, only: [:create], shallow: true
        resources :game_platforms, only: [:create], shallow: true
        resources :category_items, only: [:index, :create], controller: "/admin/category_items"
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        collection do
          post :import_from_igdb
          get :igdb_search
          get :search
        end
      end

      resources :game_companies, only: [:update, :destroy]
      resources :game_platforms, only: [:destroy]

      resources :companies do
        resources :images, only: [:index, :create], controller: "/admin/images"
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        collection do
          get :search
        end
      end

      resources :platforms do
        collection do
          get :search
        end
      end

      resources :series do
        resources :descriptions, only: [:index, :create], controller: "/admin/descriptions"
        collection do
          get :search
        end
      end

      resources :categories do
        collection do
          get :search
        end
      end

      resources :lists do
        resource :wizard, only: [:show], controller: "list_wizard" do
          get "step/:step", action: :show_step, as: :step
          get "step/:step/status", action: :step_status, as: :step_status
          post "step/:step/advance", action: :advance_step, as: :advance_step
          post "step/:step/back", action: :back_step, as: :back_step
          post "save_html", action: :save_html, as: :save_html
          post "reparse", action: :reparse, as: :reparse
          post "restart", action: :restart
          get "igdb_game_search", to: "list_items_actions#igdb_game_search", as: :igdb_game_search
        end

        resources :items, controller: "list_items_actions", only: [] do
          member do
            get "modal/:modal_type", action: :modal, as: :modal
            post :verify
            post :skip
            patch :metadata
            post :re_enrich
            post :manual_link
            post :link_igdb_game
            post :queue_import
            delete :destroy
          end

          collection do
            post :bulk_verify
            post :bulk_skip
            delete :bulk_delete
          end
        end
      end

      resources :ranking_configurations do
        member do
          post :execute_action
        end
        collection do
          post :index_action
        end
      end
    end

    scope as: "games" do
      get "search", to: "games/searches#index"
    end

    get "rankings", to: "games/default#rankings", as: :games_rankings

    # All games routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      get "lists", to: "games/lists#index", as: :games_lists
      get "lists/:id", to: "games/lists#show", as: :games_list
      get "lists/:id/page/:page", to: "games/lists#show", as: :games_list_page, constraints: {page: /\d+/}
      get "video-games", to: "games/ranked_items#index", as: :video_games
      get "video-games/page/:page", to: "games/ranked_items#index", as: :video_games_page, constraints: {page: /\d+/}
      # Year-filtered games (must come before generic patterns)
      get "video-games/since/:year", to: "games/ranked_items#index", as: :video_games_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "video-games/since/:year/page/:page", to: "games/ranked_items#index", as: :video_games_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "video-games/through/:year", to: "games/ranked_items#index", as: :video_games_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "video-games/through/:year/page/:page", to: "games/ranked_items#index", as: :video_games_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "video-games/:year", to: "games/ranked_items#index", as: :video_games_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "video-games/:year/page/:page", to: "games/ranked_items#index", as: :video_games_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "game/:slug", to: "games/games#show", as: :game
      get "categories/:id", to: "games/categories#show", as: :games_category
      get "categories/:id/page/:page", to: "games/categories#show", as: :games_category_page, constraints: {page: /\d+/}
    end

    root to: "games/ranked_items#index", as: :games_root
    get "page/:page", to: "games/ranked_items#index", as: :games_root_page, constraints: {page: /\d+/}
  end

  # Admin routes (global - no domain constraint)
  namespace :admin do
    scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
      resources :penalty_applications, only: [:index, :create]
      resources :ranked_lists, only: [:index, :create]
      resources :ranked_items, only: [:index]
    end

    resources :penalty_applications, only: [:update, :destroy]
    resources :ranked_lists, only: [:show, :destroy]

    scope "list/:list_id", as: "list" do
      resources :list_penalties, only: [:index, :create]
      resources :list_items, only: [:index, :create] do
        collection do
          delete :destroy_all
          delete :clear_positions
        end
      end
    end

    resources :list_penalties, only: [:destroy]
    resources :list_items, only: [:edit, :update, :destroy]
    resources :category_items, only: [:destroy]
    resources :images, only: [:update, :destroy], controller: "images" do
      member do
        post :set_primary
      end
    end
    resources :descriptions, only: [:update, :destroy], controller: "descriptions" do
      member do
        post :set_preferred
      end
    end
    resources :penalties
    resources :users, except: [:new, :create] do
      resources :domain_roles, only: [:index, :create, :update, :destroy]
    end

    # Cloudflare cache management
    resource :cloudflare, only: [], controller: "cloudflare" do
      post :purge_cache
    end
  end

  # Health check
  get "up" => "rails/health#show", :as => :rails_health_check

  # Custom direct route for serving images via CDN
  # Uses Current.domain to serve images from the correct domain-specific CDN
  direct :rails_public_blob do |blob|
    domain = Current.domain || :music
    settings = Rails.application.config.domain_settings[domain]
    cdn = settings&.dig(:images_cdn)

    host = if Rails.env.production?
      cdn&.fetch(:production)
    else
      cdn&.fetch(:default)
    end

    host ||= "https://images-dev.thegreatestmusic.org"
    File.join(host, blob.key)
  end
end
