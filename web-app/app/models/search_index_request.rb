class SearchIndexRequest < ApplicationRecord
  belongs_to :parent, polymorphic: true

  # Enums
  enum :action, {index_item: 0, unindex_item: 1}

  # Validations
  validates :action, presence: true
  validates :parent_type, presence: true
  validates :parent_id, presence: true

  # Scopes
  scope :for_type, ->(type) { where(parent_type: type) }
  scope :for_action, ->(action) { where(action: action) }
  scope :oldest_first, -> { order(:created_at) }
end
