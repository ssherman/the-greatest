# == Schema Information
#
# Table name: categories
#
#  id                :bigint           not null, primary key
#  alternative_names :string           default([]), is an Array
#  category_type     :integer          default(0)
#  deleted           :boolean          default(FALSE)
#  description       :text
#  import_source     :integer
#  item_count        :integer          default(0)
#  name              :string           not null
#  slug              :string
#  type              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  parent_id         :bigint
#
# Indexes
#
#  index_categories_on_category_type  (category_type)
#  index_categories_on_deleted        (deleted)
#  index_categories_on_name           (name)
#  index_categories_on_parent_id      (parent_id)
#  index_categories_on_slug           (slug)
#  index_categories_on_type           (type)
#  index_categories_on_type_and_slug  (type,slug)
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => categories.id)
#
module Books
  class Category < ::Category
    # Books-specific associations - TODO: Uncomment when Books::Book model is created
    # has_many :books, through: :category_items, source: :item, source_type: 'Books::Book'

    # Books-specific scopes - TODO: Uncomment when Books::Book model is created
    # scope :by_book_ids, ->(book_ids) { joins(:category_items).where(category_items: { item_type: 'Books::Book', item_id: book_ids }) }
  end
end
