# == Schema Information
#
# Table name: music_song_relationships
#
#  id                :bigint           not null, primary key
#  relation_type     :integer          default("cover"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  related_song_id   :bigint           not null
#  song_id           :bigint           not null
#  source_release_id :bigint
#
# Indexes
#
#  index_music_song_relationships_on_related_song_id    (related_song_id)
#  index_music_song_relationships_on_song_id            (song_id)
#  index_music_song_relationships_on_song_related_type  (song_id,related_song_id,relation_type) UNIQUE
#  index_music_song_relationships_on_source_release_id  (source_release_id)
#
# Foreign Keys
#
#  fk_rails_...  (related_song_id => music_songs.id)
#  fk_rails_...  (song_id => music_songs.id)
#  fk_rails_...  (source_release_id => music_releases.id)
#
class Music::SongRelationship < ApplicationRecord
  # Enums
  enum :relation_type, {cover: 0, remix: 1, sample: 2, alternate: 3}, prefix: true

  # Associations
  belongs_to :song, class_name: "Music::Song"
  belongs_to :related_song, class_name: "Music::Song"
  belongs_to :source_release, class_name: "Music::Release", optional: true

  # Validations
  validates :song, presence: true
  validates :related_song, presence: true
  validates :relation_type, presence: true
  validates :song_id, uniqueness: {scope: [:related_song_id, :relation_type], message: "relationship already exists"}
  validate :no_self_reference

  # Scopes
  scope :covers, -> { where(relation_type: :cover) }
  scope :remixes, -> { where(relation_type: :remix) }
  scope :samples, -> { where(relation_type: :sample) }
  scope :alternates, -> { where(relation_type: :alternate) }

  private

  def no_self_reference
    errors.add(:related_song_id, "cannot relate a song to itself") if song_id == related_song_id
  end
end
