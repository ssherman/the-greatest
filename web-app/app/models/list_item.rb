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
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#
class ListItem < ApplicationRecord
  belongs_to :list, touch: true
  belongs_to :listable, polymorphic: true, optional: true
  alias_method :item, :listable

  # Callbacks
  before_validation :parse_metadata_if_string
  before_destroy :prevent_destroy_when_auto_generated

  # Validations
  validates :list, presence: true
  validates :position, numericality: {greater_than: 0}, allow_blank: true
  validates :listable_id, uniqueness: {scope: [:list_id, :listable_type], message: "is already in this list"}, allow_nil: true
  validate :listable_type_compatible_with_list_type
  validate :metadata_format
  validate :list_must_not_be_auto_generated

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

  # The generator owns an auto-generated list's items and rewrites them on every
  # run, so anything edited by hand is destroyed on the next pass. Refuse the
  # edit rather than lose it silently.
  #
  # Services::Lists::GenerateUserFavorites writes through delete_all / insert_all,
  # which skip callbacks and validations by design -- so this guard needs no
  # escape hatch for the job itself.
  def list_must_not_be_auto_generated
    return if list.nil? || !list.auto_generated?

    errors.add(:base, "Items on an auto-generated list are managed by the generator and cannot be edited")
  end

  def prevent_destroy_when_auto_generated
    return if list.nil? || !list.auto_generated?

    errors.add(:base, "Items on an auto-generated list are managed by the generator and cannot be edited")
    throw :abort
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
