# == Schema Information
#
# Table name: music_albums
#
#  id                :bigint           not null, primary key
#  description       :text
#  release_year      :integer
#  slug              :string           not null
#  title             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  primary_artist_id :bigint           not null
#
# Indexes
#
#  index_music_albums_on_primary_artist_id  (primary_artist_id)
#  index_music_albums_on_slug               (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (primary_artist_id => music_artists.id)
#
class Music::Album < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  # Associations
  belongs_to :primary_artist, class_name: "Music::Artist"
  has_many :releases, class_name: "Music::Release"
  # has_many :songs, through: :releases
  has_many :credits, as: :creditable, class_name: "Music::Credit"
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy

  # Validations
  validates :title, presence: true
  validates :primary_artist, presence: true
  validates :release_year, numericality: {only_integer: true, allow_nil: true}

  # Search Methods
  def as_indexed_json
    {
      title: title,
      primary_artist_name: primary_artist&.name
    }
  end
end
