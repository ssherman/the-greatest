require "test_helper"

module Books
  class GlobalCanonParamsTest < ActiveSupport::TestCase
    test "returns the defaults when no segments are given" do
      settings = Books::GlobalCanonParams.call({})

      assert_equal 150, settings.total_books
      assert_equal 20, settings.nonfiction_percentage
      assert_equal 3, settings.max_books_per_country
      assert_equal [], settings.excluded_genres
    end

    test "default? is true only for the exact default triple" do
      assert Books::GlobalCanonParams.call({}).default?
      refute Books::GlobalCanonParams.call(total_books: "250").default?
      refute Books::GlobalCanonParams.call(nonfiction_percentage: "0").default?
      refute Books::GlobalCanonParams.call(max_books_per_country: "1").default?
    end

    test "reads each setting from the params" do
      settings = Books::GlobalCanonParams.call(
        total_books: "250", nonfiction_percentage: "100", max_books_per_country: "1"
      )

      assert_equal 250, settings.total_books
      assert_equal 100, settings.nonfiction_percentage
      assert_equal 1, settings.max_books_per_country
    end

    test "accepts a non-fiction percentage the menu does not offer" do
      # The menu offers multiples of five; the route accepts any integer 0..100
      # so a hand-typed or bookmarked value still resolves.
      assert_equal 37, Books::GlobalCanonParams.call(nonfiction_percentage: "37").nonfiction_percentage
    end

    test "accepts both ends of the non-fiction range" do
      assert_equal 0, Books::GlobalCanonParams.call(nonfiction_percentage: "0").nonfiction_percentage
      assert_equal 100, Books::GlobalCanonParams.call(nonfiction_percentage: "100").nonfiction_percentage
    end

    test "404s on a total the menu does not offer" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(total_books: "175") }
    end

    test "404s on a percentage above 100" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(nonfiction_percentage: "101") }
    end

    test "404s on a country cap outside 1..10" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(max_books_per_country: "0") }
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(max_books_per_country: "11") }
    end

    test "404s on a non-numeric value" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(total_books: "many") }
    end
  end
end
