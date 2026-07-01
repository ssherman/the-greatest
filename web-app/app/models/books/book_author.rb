# == Schema Information
#
# Table name: books_book_authors
#
#  id          :bigint           not null, primary key
#  credited_as :string
#  position    :integer
#  role        :integer          default(0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  author_id   :bigint           not null
#  book_id     :bigint           not null
#
# Indexes
#
#  index_books_book_authors_on_author_id              (author_id)
#  index_books_book_authors_on_book_id                (book_id)
#  index_books_book_authors_on_book_id_and_author_id  (book_id,author_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (author_id => books_authors.id)
#  fk_rails_...  (book_id => books_books.id)
#
class Books::BookAuthor < ApplicationRecord
  enum :role, { author: 0, editor: 1 }

  belongs_to :book, class_name: "Books::Book"
  belongs_to :author, class_name: "Books::Author"

  validates :book_id, uniqueness: { scope: :author_id }
end
