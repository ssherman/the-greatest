# == Schema Information
#
# Table name: list_items
#
#  id            :bigint           not null, primary key
#  listable_type :string
#  metadata      :jsonb
#  position      :integer
#  verified      :boolean          default(FALSE), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  list_id       :bigint           not null
#  listable_id   :bigint
#
# Indexes
#
#  index_list_items_on_list_and_listable_unique  (list_id,listable_type,listable_id) UNIQUE
#  index_list_items_on_list_id                   (list_id)
#  index_list_items_on_list_id_and_position      (list_id,position)
#  index_list_items_on_listable                  (listable_type,listable_id)
#  index_list_items_on_verified                  (verified)
#  index_list_items_on_verified_and_listable_id  (verified,listable_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#
class ListItem < ApplicationRecord
  belongs_to :list
  belongs_to :listable, polymorphic: true, optional: true
  alias_method :item, :listable

  # Callbacks
  before_validation :parse_metadata_if_string

  # Validations
  validates :list, presence: true
  validates :position, numericality: {greater_than: 0}, allow_blank: true
  validates :listable_id, uniqueness: {scope: [:list_id, :listable_type], message: "is already in this list"}, allow_nil: true
  validate :listable_type_compatible_with_list_type
  validate :metadata_format

  private

  def parse_metadata_if_string
    return unless metadata.is_a?(String) && metadata.present?

    begin
      self.metadata = JSON.parse(metadata)
    rescue JSON::ParserError
      # Let the validation catch this
    end
  end

  def metadata_format
    return if metadata.blank?
    return if metadata.is_a?(Hash) || metadata.is_a?(Array)

    if metadata.is_a?(String)
      JSON.parse(metadata)
    end
  rescue JSON::ParserError => e
    errors.add(:metadata, "must be valid JSON: #{e.message}")
  end

  def listable_type_compatible_with_list_type
    return if listable_type.blank? || list.blank?

    expected_type = case list.class.name
    when "Music::Albums::List"
      "Music::Album"
    when "Music::Songs::List"
      "Music::Song"
    when "Books::List"
      "Books::Book"
    when "Movies::List"
      "Movies::Movie"
    when "Games::List"
      "Games::Game"
    end

    if expected_type && listable_type != expected_type
      errors.add(:listable_type, "#{listable_type} is not compatible with list type #{list.class.name}")
    end
  end

  # Scopes
  scope :ordered, -> { order(:position) }
  scope :by_list, ->(list) { where(list: list) }
  scope :by_listable_type, ->(type) { where(listable_type: type) }
  scope :with_listable, -> { where.not(listable_id: nil) }
  scope :without_listable, -> { where(listable_id: nil) }
  scope :verified, -> { where(verified: true) }
  scope :unverified, -> { where(verified: false) }
end
