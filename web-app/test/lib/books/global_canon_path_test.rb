require "test_helper"

module Books
  class GlobalCanonPathTest < ActiveSupport::TestCase
    test "returns the bare path for the defaults" do
      assert_equal "/global-canon", ::Books::GlobalCanonPath.call(settings)
    end

    test "spells out all three settings when any of them differs" do
      assert_equal "/global-canon/total_books/250/nonfiction/20/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(total_books: 250))
    end

    test "spells out a zero non-fiction share" do
      assert_equal "/global-canon/total_books/150/nonfiction/0/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(nonfiction_percentage: 0))
    end

    test "spells out a full non-fiction share" do
      assert_equal "/global-canon/total_books/150/nonfiction/100/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(nonfiction_percentage: 100))
    end

    private

    def settings(total_books: 150, nonfiction_percentage: 20, max_books_per_country: 3, excluded_genres: [])
      ::Books::GlobalCanonParams::Settings.new(
        total_books: total_books,
        nonfiction_percentage: nonfiction_percentage,
        max_books_per_country: max_books_per_country,
        excluded_genres: excluded_genres
      )
    end
  end
end
