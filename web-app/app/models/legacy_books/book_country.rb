# == Schema Information
#
# Table name: book_countries
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  book_id    :bigint           not null
#  country_id :bigint           not null
#
# Indexes
#
#  index_book_countries_on_book_id     (book_id)
#  index_book_countries_on_country_id  (country_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (country_id => countries.id)
#
module LegacyBooks
  class BookCountry < Record
    self.table_name = "book_countries"
  end
end
