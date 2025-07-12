# == Schema Information
#
# Table name: music_artists
#
#  id           :bigint           not null, primary key
#  born_on      :date
#  country      :string(2)
#  description  :text
#  died_on      :date
#  disbanded_on :date
#  formed_on    :date
#  kind         :integer          default("person"), not null
#  name         :string           not null
#  slug         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_music_artists_on_kind  (kind)
#  index_music_artists_on_slug  (slug) UNIQUE
#
class Music::Artist < ApplicationRecord
  extend FriendlyId
  friendly_id :name, use: [:slugged, :finders]

  # Enums
  enum :kind, {person: 0, band: 1}

  # Associations
  has_many :band_memberships, class_name: "Music::Membership", foreign_key: :artist_id
  has_many :memberships, class_name: "Music::Membership", foreign_key: :member_id
  has_many :albums, class_name: "Music::Album", foreign_key: :primary_artist_id
  has_many :credits, class_name: "Music::Credit"
  has_many :ai_chats, as: :parent, dependent: :destroy

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
