# == Schema Information
#
# Table name: movies_releases
#
#  id              :bigint           not null, primary key
#  is_primary      :boolean          default(FALSE), not null
#  metadata        :jsonb
#  release_date    :date
#  release_format  :integer          default("theatrical"), not null
#  release_name    :string
#  runtime_minutes :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  movie_id        :bigint           not null
#
# Indexes
#
#  index_movies_releases_on_is_primary                 (is_primary)
#  index_movies_releases_on_movie_and_name_and_format  (movie_id,release_name,release_format) UNIQUE
#  index_movies_releases_on_movie_id                   (movie_id)
#  index_movies_releases_on_release_date               (release_date)
#  index_movies_releases_on_release_format             (release_format)
#
# Foreign Keys
#
#  fk_rails_...  (movie_id => movies_movies.id)
#
module Movies
  class Release < ApplicationRecord
    belongs_to :movie, class_name: "Movies::Movie", foreign_key: "movie_id"
    has_many :credits, as: :creditable, class_name: "Movies::Credit", dependent: :destroy

    # Enums
    enum :release_format, {theatrical: 0, dvd: 1, blu_ray: 2, digital: 3, vhs: 4, "4k_blu_ray": 5}

    # Validations
    validates :movie_id, presence: true
    validates :release_format, presence: true
    validates :is_primary, inclusion: {in: [true, false]}
    validates :release_name, uniqueness: {scope: [:movie_id, :release_format], message: "should be unique per movie and format"}, allow_nil: true
    validates :runtime_minutes, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
    validate :release_date_cannot_be_in_future

    # Scopes
    scope :primary, -> { where(is_primary: true) }
    scope :by_release_format, ->(fmt) { where(release_format: release_formats[fmt]) }
    scope :recent, -> { order(release_date: :desc) }

    private

    def release_date_cannot_be_in_future
      if release_date.present? && release_date > Date.current
        errors.add(:release_date, "cannot be in the future")
      end
    end
  end
end
