# == Schema Information
#
# Table name: movies_movies
#
#  id              :bigint           not null, primary key
#  description     :text
#  rating          :integer
#  release_year    :integer
#  runtime_minutes :integer
#  slug            :string           not null
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_movies_movies_on_rating        (rating)
#  index_movies_movies_on_release_year  (release_year)
#  index_movies_movies_on_slug          (slug) UNIQUE
#
module Movies
  class Movie < ApplicationRecord
    extend FriendlyId
    friendly_id :title, use: [:slugged, :finders]

    # Associations
    has_many :releases, class_name: "Movies::Release", foreign_key: "movie_id", dependent: :destroy
    has_many :credits, as: :creditable, class_name: "Movies::Credit", dependent: :destroy
    has_many :ai_chats, as: :parent, dependent: :destroy
    has_many :identifiers, as: :identifiable, dependent: :destroy

    # Enums
    enum :rating, {g: 0, pg: 1, pg_13: 2, r: 3, nc_17: 4, unrated: 5}

    # Validations
    validates :title, presence: true
    validates :release_year, numericality: {only_integer: true, greater_than: 1880, less_than_or_equal_to: Date.current.year + 5}, allow_nil: true
    validates :runtime_minutes, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  end
end
