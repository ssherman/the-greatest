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
  belongs_to :category, counter_cache: :item_count
  belongs_to :item, polymorphic: true

  # Validations
  validates :category_id, uniqueness: {scope: [:item_type, :item_id]}

  # Scopes
  scope :for_item_type, ->(type) { where(item_type: type) }
  scope :for_category_type, ->(category_type) { joins(:category).where(categories: {type: category_type}) }
end
