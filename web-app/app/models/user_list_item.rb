# == Schema Information
#
# Table name: user_list_items
#
#  id            :bigint           not null, primary key
#  completed_on  :date
#  listable_type :string           not null
#  position      :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  listable_id   :bigint           not null
#  user_list_id  :bigint           not null
#
# Indexes
#
#  index_user_list_items_on_list_and_listable_unique       (user_list_id,listable_type,listable_id) UNIQUE
#  index_user_list_items_on_listable                       (listable_type,listable_id)
#  index_user_list_items_on_user_list_id                   (user_list_id)
#  index_user_list_items_on_user_list_id_and_completed_on  (user_list_id,completed_on)
#  index_user_list_items_on_user_list_id_and_position      (user_list_id,position)
#
# Foreign Keys
#
#  fk_rails_...  (user_list_id => user_lists.id)
#
class UserListItem < ApplicationRecord
  # Associations
  belongs_to :user_list, touch: true
  belongs_to :listable, polymorphic: true
  has_one :user, through: :user_list

  # Validations
  validates :position, numericality: {greater_than: 0}
  validates :listable_id, uniqueness: {scope: [:user_list_id, :listable_type], message: "is already in this list"}
  validate :listable_type_compatible_with_user_list

  # Callbacks
  before_validation :set_position, on: :create
  after_destroy_commit :shift_positions_up

  # Scopes
  scope :ordered, -> { order(:position) }

  private

  def listable_type_compatible_with_user_list
    return if listable_type.blank? || user_list.blank?
    expected_type = user_list.class.listable_class.name
    return if listable_type == expected_type
    errors.add(:listable_type, "#{listable_type} is not compatible with #{user_list.class.name}")
  end

  def set_position
    return if position.present?
    max_position = self.class.where(user_list_id: user_list_id).maximum(:position) || 0
    self.position = max_position + 1
  end

  # Skip when the parent list is being destroyed — `dependent: :destroy` cascades
  # through items one at a time and siblings are already being deleted.
  def shift_positions_up
    return if user_list.nil? || user_list.destroyed?
    self.class.where(user_list_id: user_list_id)
      .where("position > ?", position)
      .update_all("position = position - 1")
  end
end
