# == Schema Information
#
# Table name: category_items
#
#  id          :bigint           not null, primary key
#  item_type   :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  category_id :bigint           not null
#  item_id     :bigint           not null
#
# Indexes
#
#  index_category_items_on_category_id                            (category_id)
#  index_category_items_on_category_id_and_item_type_and_item_id  (category_id,item_type,item_id) UNIQUE
#  index_category_items_on_item                                   (item_type,item_id)
#  index_category_items_on_item_type_and_item_id                  (item_type,item_id)
#
# Foreign Keys
#
#  fk_rails_...  (category_id => categories.id)
#
class CategoryItem < ApplicationRecord
  belongs_to :category, counter_cache: :item_count, inverse_of: :category_items
  belongs_to :item, polymorphic: true

  # Search indexing callbacks - reindex the associated item when categories change
  after_save :queue_item_for_reindexing
  after_destroy :queue_item_for_reindexing
  # after_commit :queue_item_for_reindexing, on: [:create, :update]
  # after_commit :queue_item_for_reindexing, on: :destroy

  # Validations
  validates :category_id, uniqueness: {scope: [:item_type, :item_id]}

  # Scopes
  scope :for_item_type, ->(type) { where(item_type: type) }
  scope :for_category_type, ->(category_type) { joins(:category).where(categories: {type: category_type}) }

  private

  def queue_item_for_reindexing
    # Only queue if the item is searchable and includes category_ids in its index
    return unless item_supports_category_indexing?

    # Always queue - let the Sidekiq job handle missing items gracefully
    SearchIndexRequest.create!(parent: item, action: :index_item)
  end

  def item_supports_category_indexing?
    # Check if item responds to as_indexed_json and includes category_ids
    return false unless item&.respond_to?(:as_indexed_json)

    indexed_data = item.as_indexed_json
    indexed_data.is_a?(Hash) && indexed_data.key?(:category_ids)
  rescue => e
    # If as_indexed_json fails for any reason, don't queue
    Rails.logger.warn "Failed to check category indexing support for #{item_type} ID #{item_id}: #{e.message}"
    false
  end
end
