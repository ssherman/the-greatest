require "test_helper"

module Books
  class FilterBarComponentTest < ViewComponent::TestCase
    def render_bar(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      render_inline(
        Books::FilterBarComponent.new(
          categories: categories,
          countries: countries,
          year_start: year_start,
          year_end: year_end,
          ranking_configuration: ranking_configuration
        )
      )
    end

    test "renders a button that opens the modal" do
      render_bar

      assert_selector "button[onclick='books_filter_modal.showModal()']"
    end

    test "renders no chips when nothing is filtered" do
      render_bar

      assert_no_selector "[data-testid=filter-chip]"
    end

    test "a genre chip links to the path without that genre" do
      render_bar(categories: [categories(:books_novels_genre)])

      assert_selector "[data-testid=filter-chip]", count: 1
      assert_selector "a[href='/']"
    end

    test "removing one genre keeps the others" do
      render_bar(categories: [categories(:books_novels_genre), categories(:books_classics_genre)])

      assert_selector "[data-testid=filter-chip]", count: 2
      assert_selector "a[href='/the-greatest/classics/books']"
      assert_selector "a[href='/the-greatest/novels/books']"
    end

    test "a country chip links to the path without that country" do
      render_bar(categories: [categories(:books_novels_genre)], countries: [books_countries(:french)])

      assert_selector "a[href='/the-greatest/novels/books']"
    end

    test "the date range is a single chip that clears both bounds" do
      render_bar(categories: [categories(:books_novels_genre)], year_start: "1900", year_end: "2000")

      assert_selector "[data-testid=filter-chip]", count: 2
      assert_selector "a[href='/the-greatest/novels/books']"
    end

    test "chips keep a non-primary ranking configuration" do
      alternate = ranking_configurations(:books_inherited)

      render_bar(categories: [categories(:books_novels_genre)], countries: [books_countries(:french)], ranking_configuration: alternate)

      assert_selector "a[href='/rc/#{alternate.id}/the-greatest/novels/books']"
    end
  end
end
