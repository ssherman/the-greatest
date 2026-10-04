# == Schema Information
#
# Table name: music_credits
#
#  id              :bigint           not null, primary key
#  creditable_type :string           not null
#  position        :integer
#  role            :integer          default("writer"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  artist_id       :bigint           not null
#  creditable_id   :bigint           not null
#
# Indexes
#
#  index_music_credits_on_artist_id                          (artist_id)
#  index_music_credits_on_artist_id_and_role                 (artist_id,role)
#  index_music_credits_on_creditable                         (creditable_type,creditable_id)
#  index_music_credits_on_creditable_type_and_creditable_id  (creditable_type,creditable_id)
#
# Foreign Keys
#
#  fk_rails_...  (artist_id => music_artists.id)
#
class Music::Credit < ApplicationRecord
  # Enums
  enum :role, {
    writer: 0, composer: 1, lyricist: 2, arranger: 3, performer: 4, vocalist: 5, guitarist: 6, bassist: 7, drummer: 8, keyboardist: 9, producer: 10, engineer: 11, mixer: 12, mastering: 13, featured: 14, guest: 15, remixer: 16, sampler: 17
  }

  # Associations
  belongs_to :artist, class_name: "Music::Artist"
  belongs_to :creditable, polymorphic: true

  # Validations
  validates :artist, presence: true
  validates :creditable, presence: true
  validates :role, presence: true

  # Scopes
  scope :by_role, ->(role) { where(role: role) }
  scope :ordered, -> { order(:position, :id) }
  scope :for_songs, -> { where(creditable_type: "Music::Song") }
  scope :for_albums, -> { where(creditable_type: "Music::Album") }
  scope :for_releases, -> { where(creditable_type: "Music::Release") }
end
