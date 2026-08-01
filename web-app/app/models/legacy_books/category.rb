# == Schema Information
#
# Table name: categories
#
#  id                    :bigint           not null, primary key
#  ai_fix_response       :text
#  book_count            :integer
#  category_type         :integer          default(0), not null
#  deleted               :boolean          default(FALSE), not null
#  description           :text
#  import_source         :integer
#  location              :boolean          default(FALSE), not null
#  merged_category_names :string           default([]), not null, is an Array
#  name                  :string           not null
#  primary               :boolean          default(FALSE), not null
#  slug                  :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  parent_category_id    :integer
#
# Indexes
#
#  index_categories_on_book_count             (book_count)
#  index_categories_on_category_type          (category_type)
#  index_categories_on_deleted                (deleted)
#  index_categories_on_location               (location)
#  index_categories_on_merged_category_names  (merged_category_names) USING gin
#  index_categories_on_name                   (name)
#  index_categories_on_parent_category_id     (parent_category_id)
#  index_categories_on_primary                (primary)
#  index_categories_on_slug                   (slug) UNIQUE
#
module LegacyBooks
  class Category < Record
    self.table_name = "categories"
  end
end
