class Music::Artist < ApplicationRecord
  extend FriendlyId
  friendly_id :name, use: [:slugged, :finders]

  # Enums
  enum :kind, {person: 0, band: 1}

  # Validations
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :kind, presence: true
  validates :country, length: {is: 2}, allow_blank: true
  validate :date_consistency

  # Scopes
  scope :people, -> { where(kind: :person) }
  scope :bands, -> { where(kind: :band) }
  scope :active, -> { where(disbanded_on: nil) }

  private

  def date_consistency
    if person?
      errors.add(:formed_on, "cannot be set for a person") if formed_on.present?
      errors.add(:disbanded_on, "cannot be set for a person") if disbanded_on.present?
    elsif band?
      errors.add(:born_on, "cannot be set for a band") if born_on.present?
      errors.add(:died_on, "cannot be set for a band") if died_on.present?
    end
  end
end
