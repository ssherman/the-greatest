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
