# frozen_string_literal: true

# Picks the per-domain layout for a controller that is NOT inside a
# DomainConstraint -- my_lists and saved_searches both serve every host from
# one route, so the layout can only come from Current.domain at request time.
module DomainLayout
  extend ActiveSupport::Concern

  private

  def resolve_layout
    case Current.domain
    when :games then "games/application"
    when :movies then "movies/application"
    when :books then "books/application"
    else "music/application"
    end
  end
end
