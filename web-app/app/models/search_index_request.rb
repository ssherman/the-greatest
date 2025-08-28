# == Schema Information
#
# Table name: search_index_requests
#
#  id          :bigint           not null, primary key
#  action      :integer          not null
#  parent_type :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  parent_id   :bigint           not null
#
# Indexes
#
#  index_search_index_requests_on_action                     (action)
#  index_search_index_requests_on_created_at                 (created_at)
#  index_search_index_requests_on_parent                     (parent_type,parent_id)
#  index_search_index_requests_on_parent_type_and_parent_id  (parent_type,parent_id)
#
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
