require "test_helper"

module Books
  class BrowseToolbarComponentTest < ViewComponent::TestCase
    test "the default type and sort omit both segments from every active link" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres,
        type: Books::BrowseQuery::TYPES.first,
        sort: Books::BrowseQuery::SORTS.first,
        show_types: true
      ))

      assert_selector "a[href='/genres']", count: 2
    end

    test "a non-active link composes both axes into path segments" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres, type: "subject", sort: "name", show_types: true
      ))

      assert_selector "a[href='/genres/filtered-by/location/sorted-by/name']"
      assert_selector "a[href='/genres/filtered-by/subject']"
    end

    test "no link carries a query string" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres, type: "location", sort: "name", show_types: true
      ))

      page.all("a").each do |link|
        assert_not_includes link[:href], "?"
      end
    end

    test "show_types false omits the type group entirely" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres, type: "genre", sort: "book_count", show_types: false
      ))

      assert_selector "[aria-label='Category type']", count: 0
    end

    test "the countries axis builds countries paths" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :countries, sort: "name"))

      assert_selector "a[href='/countries']"
      assert_selector "a[href='/countries/sorted-by/name']"
    end
  end
end
