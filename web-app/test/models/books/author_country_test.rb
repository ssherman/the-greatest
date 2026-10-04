# frozen_string_literal: true

require "test_helper"

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
  class AuthorCountryTest < ActiveSupport::TestCase
    test "links an author to a country once" do
      author = books_authors(:tolstoy)
      country = books_countries(:french)
      ::Books::AuthorCountry.create!(author: author, country: country)

      assert_equal [country], author.reload.countries.to_a
      assert_not ::Books::AuthorCountry.new(author: author, country: country).valid?
    end

    test "is removed with its author and with its country" do
      author = books_authors(:king)
      country = books_countries(:japanese)
      ::Books::AuthorCountry.create!(author: author, country: country)

      assert_difference -> { ::Books::AuthorCountry.count }, -1 do
        country.destroy!
      end
    end
  end
end
