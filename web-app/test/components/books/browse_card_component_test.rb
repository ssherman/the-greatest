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

    test "renders the chain root first with › separators" do
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_france_location), count: 3,
        path: "/x", chain: ["Europe", "France", "Île-de-France"]
      ))

      assert_selector "[data-testid=browse-card-chain]", exact_text: "Europe › France › Île-de-France"
    end

    test "no chain line when the chain is empty" do
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_fiction_genre), count: 3, path: "/x"
      ))

      assert_no_selector "[data-testid=browse-card-chain]"
    end

    test "shows the label when given" do
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_politics_subject), count: 3, path: "/x", label: "Subject"
      ))

      assert_text(/\bSubject\b/)
    end

    test "shows no label when none is given" do
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_politics_subject), count: 3, path: "/x"
      ))

      assert_no_selector ".badge"
    end
  end
end
