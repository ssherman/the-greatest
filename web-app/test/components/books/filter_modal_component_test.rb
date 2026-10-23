require "test_helper"

module Books
  class FilterModalComponentTest < ViewComponent::TestCase
    def render_modal(**options)
      render_inline(Books::FilterModalComponent.new(**options))
    end

    def africa
      Collections::Registry.find(:books, "africa")
    end

    test "renders the dialog the filter bar opens, as a bottom sheet on small screens" do
      render_modal

      assert_selector "dialog##{Books::FilterBarComponent::MODAL_ID}.modal-bottom"
    end

    test "wires the Stimulus controller with caps, count url and initial count" do
      render_modal(total_count: 42)

      assert_selector "div.modal-box[data-controller='books--filter']"
      assert_selector "[data-books--filter-max-categories-value='#{Books::FilterParams::MAX_CATEGORIES}']"
      assert_selector "[data-books--filter-max-countries-value='#{Books::FilterParams::MAX_COUNTRIES}']"
      assert_selector "[data-books--filter-count-url-value='/filters/count']"
      assert_selector "[data-books--filter-initial-count-value='42']"
    end

    test "the form targets the redirect endpoint and escapes the frame" do
      render_modal

      assert_selector "form[action='/filters'][method='get'][data-turbo-frame='_top']"
    end

    test "store holds applied filters outside every turbo-frame" do
      render_modal(categories: [categories(:books_novels_genre)], countries: [books_countries(:french)])

      assert_selector "[data-books--filter-target='store'] input[name='category_slugs[]'][value='novels']", visible: :all
      assert_selector "[data-books--filter-target='store'] input[name='country_slugs[]'][value='french'][data-axis='country'][data-type='country'][data-name]", visible: :all
      assert_no_selector "turbo-frame [data-store-entry]", visible: :all
    end

    test "store entries carry the category type" do
      render_modal(categories: [categories(:books_politics_subject)])

      assert_selector "input[data-store-entry][name='category_slugs[]'][value='politics'][data-axis='category'][data-type='subject'][data-name='Politics']", visible: :all
    end

    test "the first page lists six rows in order" do
      render_modal

      targets = page.all("[data-action='books--filter#open']").map { |b| b["data-level-target"] }
      assert_equal %w[genre year audience country subject location], targets
    end

    test "every level but root is hidden" do
      render_modal

      assert_selector "[data-books--filter-target='level']", count: 7, visible: :all
      assert_selector "[data-level='root']:not([hidden])"
      assert_selector "[data-books--filter-target='level'][hidden]", count: 6, visible: :all
    end

    test "a collection hides the Origin row" do
      render_modal(collection: africa)

      targets = page.all("[data-action='books--filter#open']").map { |b| b["data-level-target"] }
      assert_equal %w[genre year audience subject location], targets
      assert_selector "input[name='collection'][value='africa']", visible: :all
    end

    test "summaries show applied names per type" do
      render_modal(categories: [categories(:books_novels_genre), categories(:books_politics_subject)])

      assert_selector "[data-books--filter-target='summary'][data-type='genre']", text: "Novels"
      assert_no_selector "[data-books--filter-target='summary'][data-type='genre']", text: "Politics"
      assert_selector "[data-books--filter-target='summary'][data-type='subject']", text: "Politics"
      assert_selector "[data-books--filter-target='summary'][data-type='audience']", text: "Any"
    end

    test "the year summary describes the range" do
      render_modal(year_start: "1900", year_end: "1949")

      assert_selector "[data-books--filter-target='summary'][data-type='year']", text: "1900–1949"
    end

    test "recent year buttons are the five years before this year" do
      travel_to Date.new(2026, 10, 22) do
        render_modal
      end

      singles = page.all("button[data-books--filter-target='yearPreset']", visible: :all).select { |b| b["data-start"].present? && b["data-start"] == b["data-end"] }
      assert_equal %w[2025 2024 2023 2022 2021], singles.map { |b| b["data-start"] }
      singles.each do |b|
        assert_equal "books--filter#pickYears", b["data-action"]
        assert b["aria-pressed"].present?
        assert_equal "button", b["type"]
      end
    end

    test "eras carry their bounds" do
      render_modal

      before = page.find("button[data-books--filter-target='yearPreset']", text: "Before 1800", visible: :all)
      assert_equal ["", "1799"], [before["data-start"], before["data-end"]]
      since = page.find("button[data-books--filter-target='yearPreset']", text: "Since 2000", visible: :all)
      assert_equal ["2000", ""], [since["data-start"], since["data-end"]]
    end

    test "an era matching the applied range is pressed" do
      render_modal(year_start: "1950", year_end: "1999")

      assert_selector "button[data-books--filter-target='yearPreset'][aria-pressed='true']", text: "1950–1999", visible: :all
      assert_selector "button[data-books--filter-target='yearPreset'][aria-pressed='true']", count: 1, visible: :all
    end

    test "renders the year inputs with the applied values" do
      render_modal(year_start: "1900", year_end: "2000")

      assert_selector "input[name='year_start'][value='1900'][data-books--filter-target='year']", visible: :all
      assert_selector "input[name='year_end'][value='2000'][data-action='input->books--filter#yearsChanged']", visible: :all
    end

    test "the submit button shows the total" do
      render_modal(total_count: 15_875)

      assert_selector "button[type='submit'][data-books--filter-target='submit']", text: "Show 15,875 books"
    end

    test "the submit button is singular for one book" do
      render_modal(total_count: 1)

      assert_selector "button[type='submit']", text: "Show 1 book"
      assert_no_selector "button[type='submit']", text: "1 books"
    end

    test "the footer sits outside the scroll region and holds clear and the cap notice" do
      render_modal

      assert_selector "[data-books--filter-target='scroll']"
      assert_no_selector "[data-books--filter-target='scroll'] [data-books--filter-target='submit']"
      assert_selector "button[type='button'][data-action='books--filter#clear']", text: "Clear"
      assert_selector "[data-books--filter-target='capNotice'][role='status']:not([hidden])", visible: :all
    end

    test "the advanced search link points at the new saved search page" do
      render_modal

      assert_selector "a[href='#{Rails.application.routes.url_helpers.new_saved_search_path}']", text: "Advanced search"
    end

    test "subject and setting pages have chips containers; genre does not" do
      render_modal

      assert_selector "[data-books--filter-target='chips'][data-type='subject']", visible: :all
      assert_selector "[data-books--filter-target='chips'][data-type='location']", visible: :all
      assert_no_selector "[data-books--filter-target='chips'][data-type='genre']", visible: :all
    end

    test "search boxes have the right mode and no name" do
      render_modal

      inputs = page.all("input[type='search'][data-books--filter-target='query']", visible: :all)
      assert_equal({"genre" => "filter", "country" => "filter", "subject" => "search", "location" => "search"},
        inputs.to_h { |i| [i["data-type"], i["data-mode"]] })
      inputs.each do |i|
        assert_nil i["name"]
        assert_equal "input->books--filter#query keydown->books--filter#suppressEnter", i["data-action"]
      end
    end

    test "each type has a lazy pane frame carrying its source and the current filters" do
      render_modal(categories: [categories(:books_novels_genre)], year_start: "1900")

      %w[genre audience subject location country].each do |key|
        frame = page.find("turbo-frame#books_filter_pane_#{key}", visible: :all)
        assert_equal key, frame["data-type"]
        assert_equal "turbo:frame-load->books--filter#frameLoaded", frame["data-action"]
        assert_nil frame["src"]
      end
      src = page.find("turbo-frame#books_filter_pane_genre", visible: :all)["data-pane-src"]
      assert_includes src, "/filters/categories?"
      assert_includes src, "type=genre"
      assert_includes src, "novels"
      assert_includes src, "1900"
      assert_includes page.find("turbo-frame#books_filter_pane_country", visible: :all)["data-pane-src"], "/filters/countries?"
    end

    test "a non-primary ranking configuration rides along as a hidden field" do
      alternate = ranking_configurations(:books_inherited)

      render_modal(ranking_configuration: alternate)

      assert_selector "input[type='hidden'][name='ranking_configuration_id'][value='#{alternate.id}']", visible: :all
    end

    test "the primary ranking configuration needs no hidden field" do
      render_modal(ranking_configuration: ranking_configurations(:books_global))

      assert_no_selector "input[name='ranking_configuration_id']", visible: :all
    end

    test "the dialog has an accessible name pointing at the root heading" do
      render_modal

      assert_selector "dialog[aria-labelledby='books_filter_modal_heading_root']"
      assert_selector "h3#books_filter_modal_heading_root", text: "Filters"
    end
  end
end
