Rails.application.routes.draw do
  # Music domain routes (scoped within domain constraint)
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    # Lists overview (no ranking configuration support)
    get "lists", to: "music/lists#index", as: :music_lists

    # Search
    get "search", to: "music/searches#index", as: :search

    # Artist rankings (outside rc scope - always uses default primary configs for both albums and songs)
    get "artists", to: "music/artists/ranked_items#index", as: :artists
    get "artists/page/:page", to: "music/artists/ranked_items#index"

    # Category pages (outside rc scope - always uses default primary configs for both artists and albums)
    get "categories/:id", to: "music/categories#show", as: :music_category

    # All music routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      # Album routes
      get "albums", to: "music/albums/ranked_items#index", as: :albums
      get "albums/page/:page", to: "music/albums/ranked_items#index", constraints: {page: /\d+|__pagy_page__/}
      get "albums/lists", to: "music/albums/lists#index", as: :music_albums_lists
      get "albums/lists/:id", to: "music/albums/lists#show", as: :music_album_list
      get "albums/categories/:id", to: "music/albums/categories#show", as: :music_album_category
      get "albums/:id", to: "music/albums#show", as: :album

      # Song routes
      get "songs", to: "music/songs/ranked_items#index", as: :songs
      get "songs/page/:page", to: "music/songs/ranked_items#index", constraints: {page: /\d+|__pagy_page__/}
      get "songs/lists", to: "music/songs/lists#index", as: :music_songs_lists
      get "songs/lists/:id", to: "music/songs/lists#show", as: :music_song_list
      get "songs/:id", to: "music/songs#show", as: :song

      # Artist routes
      get "artists/categories/:id", to: "music/artists/categories#show", as: :music_artist_category
      get "artists/:id", to: "music/artists#show", as: :artist
    end

    # Admin interface for music domain
    namespace :admin, module: "admin/music" do
      root to: "dashboard#index"

      resources :artists do
        member do
          post :execute_action
        end
        collection do
          post :bulk_action
          post :index_action
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

  # Domain-specific roots using Default controllers
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    root to: "music/default#index", as: :music_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:movies]) do
    root to: "movies/default#index", as: :movies_root
  end

  constraints DomainConstraint.new(Rails.application.config.domains[:games]) do
    root to: "games/default#index", as: :games_root
  end

  # Move Avo to /avo path
  mount Avo::Engine, at: :avo

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
