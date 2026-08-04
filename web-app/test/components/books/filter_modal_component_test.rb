require "test_helper"

module Books
  class FilterModalComponentTest < ViewComponent::TestCase
    def render_modal(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      render_inline(
        Books::FilterModalComponent.new(
          categories: categories,
          countries: countries,
          year_start: year_start,
          year_end: year_end,
          ranking_configuration: ranking_configuration
        )
      )
    end

    def frame_query
      src = page.find("turbo-frame#books_filter_options")["src"]
      Rack::Utils.parse_nested_query(URI.parse(src).query)
    end

    test "renders the dialog with the shared modal id" do
      render_modal

      assert_selector "dialog#books_filter_modal"
    end

    test "renders a lazy-loading frame with a src" do
      render_modal

      assert_selector "turbo-frame#books_filter_options[loading=lazy][src]"
    end

    test "options_path round-trips multiple categories as array params" do
      render_modal(categories: [categories(:books_novels_genre), categories(:books_classics_genre)])

      assert_equal ["novels", "classics"].sort, frame_query["category_slugs"].sort
    end

    test "options_path round-trips multiple countries as array params" do
      render_modal(countries: [books_countries(:french), books_countries(:japanese)])

      assert_equal ["french", "japanese"].sort, frame_query["country_slugs"].sort
    end

    test "options_path carries the year bounds" do
      render_modal(year_start: "1900", year_end: "2000")

      query = frame_query
      assert_equal "1900", query["year_start"]
      assert_equal "2000", query["year_end"]
    end

    test "options_path carries ranking_configuration_id for a non-primary configuration" do
      alternate = ranking_configurations(:books_inherited)

      render_modal(ranking_configuration: alternate)

      assert_equal alternate.id.to_s, frame_query["ranking_configuration_id"]
    end

    test "options_path omits ranking_configuration_id for the primary configuration" do
      render_modal(ranking_configuration: ranking_configurations(:books_global))

      assert_nil frame_query["ranking_configuration_id"]
    end
  end
end
