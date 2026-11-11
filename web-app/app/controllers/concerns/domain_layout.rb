# frozen_string_literal: true

# Picks the per-domain layout for a controller that is NOT inside a
# DomainConstraint -- my_lists and saved_searches both serve every host from
# one route, so the layout can only come from Current.domain at request time.
module DomainLayout
  extend ActiveSupport::Concern

  # Public so ApplicationController#render_not_found can pick the same layout
  # without including this concern into every controller, some of which define
  # a resolve_layout of their own.
  def self.for(domain)
    case domain
    when :games then "games/application"
    when :movies then "movies/application"
    when :books then "books/application"
    else "music/application"
    end
  end

  private

  def resolve_layout
    DomainLayout.for(Current.domain)
  end
end
