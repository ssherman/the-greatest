module Movies
  class Movie < ApplicationRecord
    extend FriendlyId
    friendly_id :title, use: [:slugged, :finders]

    # Associations
    has_many :releases, class_name: "Movies::Release", foreign_key: "movie_id", dependent: :destroy

    # Enums
    enum :rating, {g: 0, pg: 1, pg_13: 2, r: 3, nc_17: 4, unrated: 5}

    # Validations
    validates :title, presence: true
    validates :slug, presence: true, uniqueness: true
    validates :release_year, numericality: {only_integer: true, greater_than: 1880, less_than_or_equal_to: Date.current.year + 5}, allow_nil: true
    validates :runtime_minutes, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  end
end
