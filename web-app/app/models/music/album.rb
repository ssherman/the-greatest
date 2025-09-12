# == Schema Information
#
# Table name: music_albums
#
#  id           :bigint           not null, primary key
#  description  :text
#  release_year :integer
#  slug         :string           not null
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_music_albums_on_slug  (slug) UNIQUE
#
class Music::Album < ApplicationRecord
  include SearchIndexable

  extend FriendlyId

  friendly_id :title, use: [:slugged, :finders]

  # Associations
  has_many :album_artists, -> { order(:position) }, class_name: "Music::AlbumArtist", dependent: :destroy
  has_many :artists, through: :album_artists, class_name: "Music::Artist"
  has_many :releases, class_name: "Music::Release", dependent: :destroy
  # has_many :songs, through: :releases
  has_many :credits, as: :creditable, class_name: "Music::Credit", dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy

  # Category associations
  has_many :category_items, as: :item, dependent: :destroy
  has_many :categories, through: :category_items, class_name: "Music::Category"

  # Image associations
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"

  # External link associations
  has_many :external_links, as: :parent, dependent: :destroy

  # Validations
  validates :title, presence: true
  validates :release_year, numericality: {only_integer: true, allow_nil: true}

  # Scopes
  scope :with_identifier, ->(identifier_type, value) {
    joins(:identifiers).where(identifiers: {identifier_type: identifier_type, value: value})
  }

  scope :with_musicbrainz_release_group_id, ->(mbid) {
    with_identifier("music_musicbrainz_release_group_id", mbid)
  }

  # Callbacks
  after_commit :queue_release_import, on: :create

  # Search Methods
  def as_indexed_json
    {
      title: title,
      artist_names: artists.map(&:name),
      artist_ids: artists.map(&:id),
      category_ids: categories.active.pluck(:id)
    }
  end

  private

  def queue_release_import
    Music::ImportAlbumReleasesJob.perform_async(id)
  end
end
