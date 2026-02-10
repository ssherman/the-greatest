Rails.application.routes.draw do
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

    # Category pages (outside rc scope - always uses default primary configs for both artists and albums)
    get "categories/:id", to: "music/categories#show", as: :music_category

    # All music routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      # Album routes
      get "albums", to: "music/albums/ranked_items#index", as: :albums
      get "albums/lists", to: "music/albums/lists#index", as: :music_albums_lists
      get "albums/lists/:id", to: "music/albums/lists#show", as: :music_album_list
      get "albums/categories/:id", to: "music/albums/categories#show", as: :music_album_category
      # Year-filtered albums (must come before :id to avoid treating "1990s" as a slug)
      get "albums/since/:year", to: "music/albums/ranked_items#index", as: :albums_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "albums/through/:year", to: "music/albums/ranked_items#index", as: :albums_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "albums/:year", to: "music/albums/ranked_items#index", as: :albums_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "album/:slug", to: "music/albums#show", as: :album

      # Song routes
      get "songs", to: "music/songs/ranked_items#index", as: :songs
      get "songs/lists", to: "music/songs/lists#index", as: :music_songs_lists
      get "songs/lists/:id", to: "music/songs/lists#show", as: :music_song_list
      # Year-filtered songs (must come before :id to avoid treating "1990s" as a slug)
      get "songs/since/:year", to: "music/songs/ranked_items#index", as: :songs_since_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "since"}
      get "songs/through/:year", to: "music/songs/ranked_items#index", as: :songs_through_year,
        constraints: {year: /\d{4}/}, defaults: {year_mode: "through"}
      get "songs/:year", to: "music/songs/ranked_items#index", as: :songs_by_year,
        constraints: {year: /\d{4}(s|-\d{4})?/}
      get "song/:slug", to: "music/songs#show", as: :song

      # Artist routes
      get "artists/categories/:id", to: "music/artists/categories#show", as: :music_artist_category
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

      scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
        resources :ranked_items, only: [:index]
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

  # Domain-specific roots using Default controllers
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    root to: "music/default#index", as: :music_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:movies]) do
    root to: "movies/default#index", as: :movies_root
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
        collection do
          get :search
        end
      end

      resources :game_companies, only: [:update, :destroy]
      resources :game_platforms, only: [:destroy]

      resources :companies do
        resources :images, only: [:index, :create], controller: "/admin/images"
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
        collection do
          get :search
        end
      end

      resources :categories do
        collection do
          get :search
        end
      end
    end

    root to: "games/default#index", as: :games_root
  end

  # Admin routes (global - no domain constraint)
  namespace :admin do
    scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
      resources :penalty_applications, only: [:index, :create]
      resources :ranked_lists, only: [:index, :create]
    end

    resources :penalty_applications, only: [:update, :destroy]
    resources :ranked_lists, only: [:show, :destroy]

    scope "list/:list_id", as: "list" do
      resources :list_penalties, only: [:index, :create]
      resources :list_items, only: [:index, :create] do
        collection do
          delete :destroy_all
        end
      end
    end

    resources :list_penalties, only: [:destroy]
    resources :list_items, only: [:update, :destroy]
    resources :category_items, only: [:destroy]
    resources :images, only: [:update, :destroy], controller: "images" do
      member do
        post :set_primary
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
  direct :rails_public_blob do |blob|
    case Rails.env
    when "development"
      File.join("https://images-dev.thegreatestmusic.org", blob.key)
    when "production"
      File.join("https://images.thegreatestmusic.org", blob.key)
    else
      File.join("https://images-dev.thegreatestmusic.org", blob.key)
    end
  end
end
