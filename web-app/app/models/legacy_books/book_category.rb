# == Schema Information
#
# Table name: book_categories
#
#  id          :bigint           not null, primary key
#  deleted     :boolean          default(FALSE), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  book_id     :bigint           not null
#  category_id :bigint           not null
#
# Indexes
#
#  index_book_categories_on_book_id_and_category_id  (book_id,category_id) UNIQUE
#  index_book_categories_on_category_id              (category_id)
#  index_book_categories_on_deleted                  (deleted)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (category_id => categories.id)
#
module LegacyBooks
  class BookCategory < Record
    self.table_name = "book_categories"
  end
end
