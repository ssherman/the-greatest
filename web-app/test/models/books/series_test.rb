require "test_helper"

module Books
  class SeriesTest < ActiveSupport::TestCase
    test "is valid with a title" do
      assert_predicate Books::Series.new(title: "Mistborn"), :valid?
    end

    test "requires a title" do
      series = Books::Series.new
      assert_not series.valid?
      assert_includes series.errors[:title], "can't be blank"
    end

    test "generates a slug from the title" do
      series = Books::Series.create!(title: "The Wheel of Time")
      assert_equal "the-wheel-of-time", series.slug
    end

    test "representative_book is optional" do
      assert_nil books_series(:asoiaf).representative_book
    end
  end
end
