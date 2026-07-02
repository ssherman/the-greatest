# == Schema Information
#
# Table name: books_series_books
#
#  id             :bigint           not null, primary key
#  numbered       :boolean          default(TRUE), not null
#  position       :decimal(8, 2)
#  position_label :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  book_id        :bigint           not null
#  series_id      :bigint           not null
#
# Indexes
#
#  index_books_series_books_on_book_id                (book_id)
#  index_books_series_books_on_series_id              (series_id)
#  index_books_series_books_on_series_id_and_book_id  (series_id,book_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (series_id => books_series.id)
#
class Books::SeriesBook < ApplicationRecord
  belongs_to :series, class_name: "Books::Series"
  belongs_to :book, class_name: "Books::Book"

  validates :series_id, uniqueness: {scope: :book_id}
end
