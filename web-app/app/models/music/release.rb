# == Schema Information
#
# Table name: music_releases
#
#  id           :bigint           not null, primary key
#  country      :string
#  format       :integer          default("vinyl"), not null
#  labels       :string           default([]), is an Array
#  metadata     :jsonb
#  release_date :date
#  release_name :string
#  status       :integer          default("official"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  album_id     :bigint           not null
#
# Indexes
#
#  index_music_releases_on_album_id  (album_id)
#  index_music_releases_on_country   (country)
#  index_music_releases_on_status    (status)
#
# Foreign Keys
#
#  fk_rails_...  (album_id => music_albums.id)
#
class Music::Release < ApplicationRecord
  # Enums
  enum :format, {vinyl: 0, cd: 1, digital: 2, cassette: 3, other: 4}, prefix: true
  enum :status, {
    official: 0,
    promotion: 1,
    bootleg: 2,
    pseudo_release: 3,
    withdrawn: 4,
    expunged: 5,
    cancelled: 6
  }, prefix: true

  # Associations
  belongs_to :album, class_name: "Music::Album"
  has_many :tracks, -> { order(:medium_number, :position) }, class_name: "Music::Track", dependent: :destroy
  has_many :songs, through: :tracks, class_name: "Music::Song"
  has_many :credits, as: :creditable, class_name: "Music::Credit", dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :song_relationships, class_name: "Music::SongRelationship", foreign_key: :source_release_id, dependent: :nullify

  # Image associations
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"

  # External link associations
  has_many :external_links, as: :parent, dependent: :destroy

  # Validations
  validates :album, presence: true
  validates :format, presence: true
  validates :status, presence: true

  # Scopes
  scope :by_format, ->(format) { where(format: format) }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_country, ->(country) { where(country: country) }
  scope :released_before, ->(date) { where("release_date <= ?", date) }
  scope :released_after, ->(date) { where("release_date >= ?", date) }
end
