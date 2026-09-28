# == Schema Information
#
# Table name: books_author_countries
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  author_id  :bigint           not null
#  country_id :bigint           not null
#
# Indexes
#
#  index_books_author_countries_on_author_id                 (author_id)
#  index_books_author_countries_on_author_id_and_country_id  (author_id,country_id) UNIQUE
#  index_books_author_countries_on_country_id                (country_id)
#
# Foreign Keys
#
#  fk_rails_...  (author_id => books_authors.id)
#  fk_rails_...  (country_id => books_countries.id)
#
module Books
  class AuthorCountry < ApplicationRecord
    belongs_to :author, class_name: "Books::Author"
    belongs_to :country, class_name: "Books::Country"

    validates :country_id, uniqueness: {scope: :author_id}
  end
end
