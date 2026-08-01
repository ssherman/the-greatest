# == Schema Information
#
# Table name: user_list_books
#
#  id           :bigint           not null, primary key
#  position     :integer
#  read_date    :date
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  book_id      :bigint           not null
#  user_list_id :bigint           not null
#
# Indexes
#
#  index_user_list_books_on_book_id                    (book_id)
#  index_user_list_books_on_read_date                  (read_date)
#  index_user_list_books_on_user_list_id_and_book_id   (user_list_id,book_id) UNIQUE
#  index_user_list_books_on_user_list_id_and_position  (user_list_id,position)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (user_list_id => user_lists.id)
#
module LegacyBooks
  class UserListBook < Record
    self.table_name = "user_list_books"
  end
end
