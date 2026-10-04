# frozen_string_literal: true

require "test_helper"

module Books
  class GoodreadsIdTest < ActiveSupport::TestCase
    test "a bare id is kept" do
      assert_equal "4671", GoodreadsId.normalize("4671")
      assert_equal "4671", GoodreadsId.normalize(" 4671 ")
    end

    test "slug forms keep only the leading digits" do
      assert_equal "32076670", GoodreadsId.normalize("32076670-ball-lightning")
      assert_equal "49122921", GoodreadsId.normalize("49122921-konosuba?from_search=true&from_srp=true")
      assert_equal "4671", GoodreadsId.normalize("4671.The_Great_Gatsby")
    end

    test "a book page URL yields its id" do
      assert_equal "4671", GoodreadsId.normalize("https://www.goodreads.com/book/show/4671.The_Great_Gatsby")
    end

    test "leading zeros are dropped" do
      assert_equal "7", GoodreadsId.normalize("007")
    end

    test "values with no usable id are nil" do
      [nil, "", "abc", "0", "1" * 19].each do |raw|
        assert_nil GoodreadsId.normalize(raw), raw.inspect
      end
    end
  end
end
