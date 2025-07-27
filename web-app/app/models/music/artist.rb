# == Schema Information
#
# Table name: music_artists
#
#  id             :bigint           not null, primary key
#  born_on        :date
#  country        :string(2)
#  description    :text
#  kind           :integer          default("person"), not null
#  name           :string           not null
#  slug           :string           not null
#  year_died      :integer
#  year_disbanded :integer
#  year_formed    :integer
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
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
  has_many :identifiers, as: :identifiable, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :kind, presence: true
  validates :country, length: {is: 2}, allow_blank: true
  validate :date_consistency

  # Scopes
  scope :people, -> { where(kind: :person) }
  scope :bands, -> { where(kind: :band) }
  scope :active, -> { where(year_disbanded: nil) }

  # AI Methods
  def populate_details_with_ai!
    Services::Ai::Tasks::ArtistDetailsTask.new(parent: self).call
  end

  # Search Methods
  def as_indexed_json
    {
      name: name
    }
  end

  private

  def date_consistency
    if person?
      errors.add(:year_formed, "cannot be set for a person") if year_formed.present?
      errors.add(:year_disbanded, "cannot be set for a person") if year_disbanded.present?
    elsif band?
      errors.add(:year_died, "cannot be set for a band") if year_died.present?
    end
  end
end
