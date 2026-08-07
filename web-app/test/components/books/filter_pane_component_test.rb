require "test_helper"

module Books
  class FilterPaneComponentTest < ViewComponent::TestCase
    def render_pane(**options)
      defaults = {axis: :category, facet_rows: [], results_src: "/filters/categories"}
      render_inline(Books::FilterPaneComponent.new(**defaults.merge(options)))
    end

    test "wraps itself in the pane frame for its axis" do
      render_pane(axis: :category)
      assert_selector "turbo-frame#books_filter_pane_category"

      render_pane(axis: :country, results_src: "/filters/countries")
      assert_selector "turbo-frame#books_filter_pane_country"
    end

    test "emits an empty results frame carrying its source" do
      render_pane(axis: :category, results_src: "/filters/categories?year_start=1900")

      assert_selector "turbo-frame#books_filter_results_category[data-results-src='/filters/categories?year_start=1900']"
      assert_no_selector "turbo-frame#books_filter_results_category input"
    end

    test "renders facet rows unchecked with counts in the browse container" do
      render_pane(facet_rows: [{record: categories(:books_fiction_genre), count: 4321}])

      assert_selector "[data-books--filter-target='browse'] input[value='fiction']"
      assert_no_selector "[data-books--filter-target='browse'] input[checked]"
      assert_text "4,321"
    end

    test "carries the axis on every container the controller queries" do
      render_pane(axis: :category)

      assert_selector "[data-books--filter-target='results'][data-axis='category']"
      assert_selector "[data-books--filter-target='browse'][data-axis='category']"
      assert_selector "[data-books--filter-target='capNotice'][data-axis='category']"
    end

    test "does not render a selected container -- that lives in the modal now" do
      render_pane(axis: :category)

      assert_no_selector "[data-books--filter-target='selected']"
    end

    test "the cap notice starts hidden and empty" do
      render_pane

      assert_selector "[data-books--filter-target='capNotice'].hidden"
      assert_selector "[data-books--filter-target='capNotice']", text: ""
    end

    test "uses the country input name on the country axis" do
      render_pane(axis: :country, facet_rows: [{record: books_countries(:french), count: 2}], results_src: "/filters/countries")

      assert_selector "input[name='country_slugs[]'][value='french']"
    end

    test "the cap notice is a live region" do
      render_pane

      assert_selector "[data-books--filter-target='capNotice'][role='status'][aria-live='polite']"
    end

    test "links out to the matching browse page" do
      render_pane(axis: :category)
      assert_selector "a[href='/genres']"

      render_pane(axis: :country, results_src: "/filters/countries")
      assert_selector "a[href='/countries']"
    end
  end
end
