# == Schema Information
#
# Table name: books_book_countries
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  book_id    :bigint           not null
#  country_id :bigint           not null
#
# Indexes
#
#  index_books_book_countries_on_book_id                 (book_id)
#  index_books_book_countries_on_book_id_and_country_id  (book_id,country_id) UNIQUE
#  index_books_book_countries_on_country_id              (country_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (country_id => books_countries.id)
#
module Books
  class BookCountry < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"
    belongs_to :country, class_name: "Books::Country", counter_cache: :book_count
  end
end
