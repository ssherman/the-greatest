# == Schema Information
#
# Table name: music_memberships
#
#  id         :bigint           not null, primary key
#  joined_on  :date
#  left_on    :date
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  artist_id  :bigint           not null
#  member_id  :bigint           not null
#
# Indexes
#
#  index_music_memberships_on_artist_id             (artist_id)
#  index_music_memberships_on_artist_member_joined  (artist_id,member_id,joined_on) UNIQUE
#  index_music_memberships_on_member_id             (member_id)
#
# Foreign Keys
#
#  fk_rails_...  (artist_id => music_artists.id)
#  fk_rails_...  (member_id => music_artists.id)
#
class Music::Membership < ApplicationRecord
  # Associations
  belongs_to :artist, class_name: "Music::Artist"  # The band
  belongs_to :member, class_name: "Music::Artist"  # The person

  # Validations
  validates :artist_id, presence: true
  validates :member_id, presence: true
  validate :artist_is_band
  validate :member_is_person
  validate :member_not_same_as_artist
  validate :date_consistency

  # Scopes
  scope :active, -> { where(left_on: nil) }
  scope :current, -> { active }
  scope :former, -> { where.not(left_on: nil) }

  private

  def artist_is_band
    return unless artist
    unless artist.band?
      errors.add(:artist, "must be a band")
    end
  end

  def member_is_person
    return unless member
    unless member.person?
      errors.add(:member, "must be a person")
    end
  end

  def member_not_same_as_artist
    if artist_id == member_id
      errors.add(:member, "cannot be the same as the artist")
    end
  end

  def date_consistency
    return unless joined_on && left_on
    if left_on < joined_on
      errors.add(:left_on, "cannot be before joined_on")
    end
  end
end
