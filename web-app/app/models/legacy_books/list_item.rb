# == Schema Information
#
# Table name: list_items
#
#  id                :bigint           not null, primary key
#  pending_book_data :text
#  position          :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  book_id           :integer
#  list_id           :bigint           not null
#
# Indexes
#
#  index_list_items_on_book_id              (book_id)
#  index_list_items_on_list_id_and_book_id  (list_id,book_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (list_id => lists.id)
#
module LegacyBooks
  class ListItem < Record
    self.table_name = "list_items"
  end
end
