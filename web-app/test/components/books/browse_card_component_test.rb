require "test_helper"

module Books
  class BrowseCardComponentTest < ViewComponent::TestCase
    def render_chain(chain)
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_france_location), count: 3, path: "/x", chain: chain
      ))
    end

    # The chain line's text with the given nodes removed: ".sr-only" leaves what
    # a sighted reader sees, "[aria-hidden=true]" what a screen reader reads.
    def chain_text_without(selector)
      line = Nokogiri::HTML.fragment(rendered_content).at_css("[data-testid=browse-card-chain]")
      line.css(selector).each(&:remove)
      line.text.squish
    end
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

    test "shows the chain root first with › separators" do
      render_chain(["Europe", "France", "Île-de-France"])

      assert_equal "Europe › France › Île-de-France", chain_text_without(".sr-only")
    end

    # The whole card is one link, so the chain is part of its accessible name.
    # Without context it reads "Paris Europe right-pointing angle quotation
    # mark France", so the arrows are hidden and an "in" and commas are spoken.
    test "a screen reader hears the chain as a phrase, not arrows" do
      render_chain(["Europe", "France", "Île-de-France"])

      assert_equal "in Europe, France, Île-de-France", chain_text_without("[aria-hidden=true]")
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
