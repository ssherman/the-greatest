require "test_helper"

module Services
  module CategoryCleanup
    class SampleTitlesTest < ActiveSupport::TestCase
      test "lists linked books as 'Title by Author'" do
        category = ::Books::Category.create!(name: "Russia", category_type: :location)
        book = books_books(:war_and_peace)
        CategoryItem.create!(category: category, item: book)
        expected = book.authors.any? ? "#{book.title} by #{book.authors.map(&:name).join(", ")}" : book.title

        assert_equal [expected], SampleTitles.for(category)
      end

      test "is capped by config" do
        Rails.configuration.x.categories_cleanup.stubs(:sample_titles).returns(1)
        category = ::Books::Category.create!(name: "Russia", category_type: :location)
        CategoryItem.create!(category: category, item: books_books(:war_and_peace))
        CategoryItem.create!(category: category, item: books_books(:crime_and_punishment))

        assert_equal 1, SampleTitles.for(category).size
      end
    end
  end
end
