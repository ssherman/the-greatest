# == Schema Information
#
# Table name: music_releases
#
#  id           :bigint           not null, primary key
#  format       :integer          default("vinyl"), not null
#  metadata     :jsonb
#  release_date :date
#  release_name :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  album_id     :bigint           not null
#
# Indexes
#
#  index_music_releases_on_album_id                  (album_id)
#  index_music_releases_on_album_name_format_unique  (album_id,release_name,format) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (album_id => music_albums.id)
#
class Music::Release < ApplicationRecord
  # Enums
  enum :format, {vinyl: 0, cd: 1, digital: 2, cassette: 3, blu_ray: 4}, prefix: true

  # Associations
  belongs_to :album, class_name: "Music::Album"
  has_many :tracks, -> { order(:medium_number, :position) }, class_name: "Music::Track"
  has_many :songs, through: :tracks, class_name: "Music::Song"
  has_many :credits, as: :creditable, class_name: "Music::Credit"

  # Validations
  validates :album, presence: true
  validates :format, presence: true

  # Scopes
  scope :by_format, ->(format) { where(format: format) }
  scope :released_before, ->(date) { where("release_date <= ?", date) }
  scope :released_after, ->(date) { where("release_date >= ?", date) }
end
