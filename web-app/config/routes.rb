Rails.application.routes.draw do
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
