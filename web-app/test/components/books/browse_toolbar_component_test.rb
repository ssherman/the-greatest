require "test_helper"

module Books
  class BrowseToolbarComponentTest < ViewComponent::TestCase
    test "the default type and sort omit both params from every active link" do
      render_inline(Books::BrowseToolbarComponent.new(
        base_path: "/genres",
        type: Books::BrowseQuery::TYPES.first,
        sort: Books::BrowseQuery::SORTS.first,
        show_types: true
      ))

      assert_selector "a[href='/genres']", count: 2
    end

    test "a non-active link composes both axes into the query string" do
      render_inline(Books::BrowseToolbarComponent.new(
        base_path: "/genres", type: "subject", sort: "name", show_types: true
      ))

      assert_selector "a[href='/genres?filter=location&sort=name']"
      assert_selector "a[href='/genres?filter=subject']"
    end

    test "show_types false omits the type group entirely" do
      render_inline(Books::BrowseToolbarComponent.new(
        base_path: "/genres", type: "genre", sort: "book_count", show_types: false
      ))

      assert_selector "[aria-label='Category type']", count: 0
    end
  end
end
