require "test_helper"

module Books
  class CategoryTest < ActiveSupport::TestCase
    test "location categories associate books" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_books(:war_and_peace))
      assert_includes russia.books, books_books(:war_and_peace)
    end

    test "location categories associate authors as nationality" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_authors(:tolstoy))
      assert_includes russia.authors, books_authors(:tolstoy)
    end

    test "by_book_ids scope filters" do
      fiction = Books::Category.create!(name: "Fiction", category_type: :genre)
      CategoryItem.create!(category: fiction, item: books_books(:war_and_peace))
      assert_includes Books::Category.by_book_ids([ books_books(:war_and_peace).id ]), fiction
    end
  end
end
