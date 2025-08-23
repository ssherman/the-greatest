Rails.application.routes.draw do
  require "sidekiq/web"
  require 'sidekiq/cron/web'

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
end
