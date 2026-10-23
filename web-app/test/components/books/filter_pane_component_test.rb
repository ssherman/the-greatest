require "test_helper"

module Books
  class FilterPaneComponentTest < ViewComponent::TestCase
    def render_pane(**options)
      defaults = {type: "genre", rows: [{record: categories(:books_fiction_genre), count: 3}]}
      render_inline(Books::FilterPaneComponent.new(**defaults.merge(options)))
    end

    test "wraps itself in the pane frame for its type" do
      render_pane(type: "genre")
      assert_selector "turbo-frame#books_filter_pane_genre"

      render_pane(type: "country", rows: [{record: books_countries(:french), count: 2}])
      assert_selector "turbo-frame#books_filter_pane_country"
    end

    test "subject pane renders a results frame carrying its source" do
      render_pane(type: "subject", results_src: "/filters/categories?type=subject&year_start=1900")

      assert_selector "turbo-frame#books_filter_results_subject[data-results-src='/filters/categories?type=subject&year_start=1900']"
      assert_no_selector "turbo-frame#books_filter_results_subject input"
    end

    test "the results frame sits above the popular list" do
      render_pane(type: "location", results_src: "/filters/categories?type=location")

      assert_selector "turbo-frame#books_filter_results_location + [data-books--filter-target='browse']"
    end

    test "genre pane renders no results frame" do
      render_pane(type: "genre")

      assert_no_selector "turbo-frame[id^='books_filter_results_']"
    end

    test "renders rows unchecked with counts in the browse container" do
      render_pane(rows: [{record: categories(:books_fiction_genre), count: 4321}])

      assert_selector "[data-books--filter-target='browse'] input[data-slug='fiction']"
      assert_no_selector "input[checked]"
      assert_text "4,321"
    end

    test "an empty pane says so" do
      render_pane(rows: [])

      assert_selector "[data-testid='filter-pane-empty']"
      assert_no_selector "input"
    end

    test "client-filtered panes carry a hidden no-matches line" do
      %w[genre audience country].each do |type|
        render_pane(type: type)
        assert_selector "p[hidden][data-filter-no-matches]", visible: :all
      end

      %w[subject location].each do |type|
        render_pane(type: type, results_src: "/x")
        assert_no_selector "[data-filter-no-matches]", visible: :all
      end
    end

    test "the cap notice starts hidden, empty and live" do
      render_pane

      assert_selector "[data-books--filter-target='capNotice'].hidden[role='status'][aria-live='polite']", text: ""
    end

    test "links out to the type's own browse page" do
      {"genre" => "/categories", "subject" => "/categories/subjects", "location" => "/categories/settings",
       "audience" => "/categories/audiences", "country" => "/countries"}.each do |type, href|
        render_pane(type: type)
        assert_selector "a[href='#{href}'][data-turbo-frame='_top']"
      end
    end
  end
end
