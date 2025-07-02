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
