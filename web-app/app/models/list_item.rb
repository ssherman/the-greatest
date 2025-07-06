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
