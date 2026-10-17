require "test_helper"

module Books
  class BrowseToolbarComponentTest < ViewComponent::TestCase
    test "search form targets the results frame and keeps the current type" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "location", sort: "name",
        show_types: true, search: true, query: "par"))
      assert_selector "form[action='/categories/search'][method=get][data-turbo-frame=categories_results]"
      assert_selector "input[type=search][name=q][value=par][placeholder='Search categories…']"
      assert_selector "input[type=hidden][name=filter][value=location]", visible: :all
      assert_selector "label", text: "Search categories", visible: :all
    end

    test "the search form is wired to the live-search controller" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "subject", sort: "book_count",
        show_types: true, search: true, browse_path: "/categories/subjects"))
      assert_selector "form[data-controller='books--category-search'][data-books--category-search-frame-value=categories_results][data-books--category-search-browse-url-value='/categories/subjects']"
      assert_selector "form[data-action~='submit->books--category-search#submitted']"
      assert_selector "input[name=q][data-action~='input->books--category-search#search']"
    end

    test "one persistent status region sits in the search form, empty and polite" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "subject", sort: "book_count",
        search: true, browse_path: "/categories/subjects"))
      assert_selector "form [role=status][aria-live=polite][data-books--category-search-target=announcer]", count: 1, visible: :all
      assert_selector "[role=status]", exact_text: "", visible: :all
    end

    test "show_sort false omits the sort dropdown" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "genre", sort: "book_count",
        show_types: true, show_sort: false, search: true))
      assert_no_selector "details.dropdown", visible: :all
      assert_selector "nav[aria-label='Category type'] a.tab", count: 3
    end

    test "the sort dropdown closes itself before Turbo caches the page" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :categories, sort: "name"))
      assert_selector "details.dropdown[data-controller='books--dropdown-close']", visible: :all
    end

    test "no search form unless asked" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "genre", sort: "name"))
      assert_no_selector "form"
    end

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

      assert_selector "details.dropdown summary [data-testid=sort-label]", exact_text: "Sort: Most books"
      assert_selector "details.dropdown summary [data-testid=sort-caret][aria-hidden=true]", exact_text: "▾"
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
      assert_selector "details.dropdown summary [data-testid=sort-label]", exact_text: "Sort: A–Z"
      assert_selector "details.dropdown a[href='/countries']", visible: :all
      assert_selector "details.dropdown a[href='/countries/sorted-by/name']", visible: :all
    end
  end
end
