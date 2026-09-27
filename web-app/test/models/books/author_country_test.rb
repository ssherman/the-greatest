# frozen_string_literal: true

require "test_helper"

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
