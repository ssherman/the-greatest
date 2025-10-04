Rails.application.routes.draw do
  # Music domain routes (scoped within domain constraint)
  constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
    # All music routes with optional ranking configuration parameter
    scope "(/rc/:ranking_configuration_id)" do
      # Album routes
      get "albums", to: "music/albums/ranked_items#index", as: :albums
      get "albums/page/:page", to: "music/albums/ranked_items#index", constraints: {page: /\d+|__pagy_page__/}
      get "albums/:id", to: "music/albums#show", as: :album

      # Song routes
      get "songs", to: "music/songs/ranked_items#index", as: :songs
      get "songs/page/:page", to: "music/songs/ranked_items#index", constraints: {page: /\d+|__pagy_page__/}
      get "songs/:id", to: "music/songs#show", as: :song

      # Artist routes
      get "artists/:id", to: "music/artists#show", as: :artist
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

  mount_avo

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
