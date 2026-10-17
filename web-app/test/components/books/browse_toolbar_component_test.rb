require "test_helper"

module Books
  class BrowseToolbarComponentTest < ViewComponent::TestCase
    test "the default type and sort omit both segments from every active link" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories,
        type: Books::BrowseQuery::TYPES.first,
        sort: Books::BrowseQuery::SORTS.first,
        show_types: true
      ))

      # The sort links sit in a closed <details>, which Capybara treats as hidden.
      assert_selector "a[href='/categories']", count: 2, visible: :all
    end

    test "a non-active link composes both axes into path segments" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "subject", sort: "name", show_types: true
      ))

      assert_selector "a[href='/categories/settings/sorted-by/name']"
      assert_selector "a[href='/categories/subjects']", visible: :all
    end

    test "tabs are links in a labelled nav, the active one marked" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "subject", sort: "name", show_types: true
      ))

      assert_selector "nav[aria-label='Category type'] a.tab", count: 3
      assert_selector "a.tab.tab-active[aria-current=page][href='/categories/subjects/sorted-by/name']", exact_text: "Subjects"
      assert_selector "a.tab[href='/categories/settings/sorted-by/name']", exact_text: "Settings"
      assert_selector "a.tab[aria-current]", count: 1
    end

    test "tabs are page links, not ARIA tabs" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "genre", sort: "book_count", show_types: true
      ))

      assert_no_selector "[role=tablist]"
      assert_no_selector "[role=tab]"
    end

    test "the sort dropdown names the current sort and links to both" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "location", sort: "book_count", show_types: true
      ))

      assert_selector "details.dropdown summary", exact_text: "Sort: Most books"
      assert_selector "details.dropdown a[href='/categories/settings'][aria-current=page]", exact_text: "Most books", visible: :all
      assert_selector "details.dropdown a[href='/categories/settings/sorted-by/name']", exact_text: "A–Z", visible: :all
      assert_selector "details.dropdown a[aria-current]", count: 1, visible: :all
    end

    test "the sort links are not styled as tabs" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "location", sort: "book_count", show_types: true
      ))

      assert_no_selector "details.dropdown a.tab", visible: :all
    end

    test "no link carries a query string" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "location", sort: "name", show_types: true
      ))

      links = page.all("a", visible: :all)
      assert_equal 5, links.size
      links.each do |link|
        assert_not_includes link[:href], "?"
      end
    end

    test "show_types false omits the type group entirely" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :categories, type: "genre", sort: "book_count", show_types: false
      ))

      assert_selector "[aria-label='Category type']", count: 0
    end

    test "countries gets the dropdown and no tabs" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :countries, sort: "name"))

      assert_no_selector "nav[aria-label='Category type']"
      assert_selector "details.dropdown summary", exact_text: "Sort: A–Z"
      assert_selector "details.dropdown a[href='/countries']", visible: :all
      assert_selector "details.dropdown a[href='/countries/sorted-by/name']", visible: :all
    end
  end
end
