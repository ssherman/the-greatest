require "test_helper"

module Api
  module V1
    module Books
      class CountryResourceTest < ActiveSupport::TestCase
        setup { Current.domain = :books }

        test "compact shape, with the web's ranked page as url" do
          country = books_countries(:french)
          hash = CountryResource.new(country, params: {book_count: 7}).to_h

          assert_equal %i[slug name book_count url], hash.keys
          assert_equal "french", hash[:slug]
          assert_equal "French", hash[:name]
          assert_equal 7, hash[:book_count]
          assert_equal "#{::Api::Host.base_url}#{::Books::FilterPath.call(countries: [country])}", hash[:url]
        end

        test "book_count defaults to 0" do
          assert_equal 0, CountryResource.new(books_countries(:french)).to_h[:book_count]
        end
      end
    end
  end
end
