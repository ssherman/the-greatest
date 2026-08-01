# == Schema Information
#
# Table name: book_authors
#
#  id         :bigint           not null, primary key
#  position   :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  author_id  :bigint           not null
#  book_id    :bigint           not null
#
# Indexes
#
#  index_book_authors_on_author_id              (author_id)
#  index_book_authors_on_book_id_and_author_id  (book_id,author_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (author_id => authors.id)
#  fk_rails_...  (book_id => books.id)
#
module LegacyBooks
  class BookAuthor < Record
    self.table_name = "book_authors"
  end
end
