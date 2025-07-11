# == Schema Information
#
# Table name: list_items
#
#  id            :bigint           not null, primary key
#  listable_type :string           not null
#  position      :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  list_id       :bigint           not null
#  listable_id   :bigint           not null
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
  belongs_to :list
  belongs_to :listable, polymorphic: true

  # Validations
  validates :list, presence: true
  validates :listable, presence: true
  validates :position, numericality: {greater_than: 0}, allow_blank: true
  validates :listable_id, uniqueness: {scope: [:list_id, :listable_type], message: "is already in this list"}

  # Scopes
  scope :ordered, -> { order(:position) }
  scope :by_list, ->(list) { where(list: list) }
  scope :by_listable_type, ->(type) { where(listable_type: type) }
end
