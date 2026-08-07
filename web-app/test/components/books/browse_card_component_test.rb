require "test_helper"

module Books
  class BrowseCardComponentTest < ViewComponent::TestCase
    test "renders the name, a delimited count and the given path" do
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_fiction_genre), count: 15875, path: "/the-greatest/fiction/books"
      ))

      assert_selector "a[href='/the-greatest/fiction/books']"
      assert_text "Fiction"
      assert_text "15,875"
    end

    test "works for a country too" do
      render_inline(Books::BrowseCardComponent.new(
        record: books_countries(:french), count: 1210, path: "/the-greatest-books/written-by/french/authors"
      ))

      assert_selector "a[href='/the-greatest-books/written-by/french/authors']"
      assert_text "French"
    end
  end
end
