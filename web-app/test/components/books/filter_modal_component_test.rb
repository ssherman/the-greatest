require "test_helper"

module Books
  class FilterModalComponentTest < ViewComponent::TestCase
    def render_modal(**options)
      render_inline(Books::FilterModalComponent.new(**options))
    end

    test "renders the dialog the filter bar opens" do
      render_modal

      assert_selector "dialog##{Books::FilterBarComponent::MODAL_ID}"
    end

    test "is a bottom sheet on small screens" do
      render_modal

      assert_selector "dialog.modal-bottom"
    end

    test "wires the Stimulus controller with both caps" do
      render_modal

      assert_selector "[data-controller='books--filter']"
      assert_selector "[data-books--filter-max-categories-value='#{Books::FilterParams::MAX_CATEGORIES}']"
      assert_selector "[data-books--filter-max-countries-value='#{Books::FilterParams::MAX_COUNTRIES}']"
    end

    test "the form targets the redirect endpoint and escapes the frame" do
      render_modal

      assert_selector "form[action='/filters'][method='get'][data-turbo-frame='_top']"
    end

    test "renders exactly four levels: root and three axes" do
      render_modal

      assert_selector "[data-books--filter-target='level']", count: 4
      assert_selector "[data-level='root']"
      assert_selector "[data-level='category']"
      assert_selector "[data-level='country']"
      assert_selector "[data-level='year']"
    end

    test "each axis row opens its own level" do
      render_modal

      assert_selector "[data-action='books--filter#open'][data-level-target='category']"
      assert_selector "[data-action='books--filter#open'][data-level-target='country']"
      assert_selector "[data-action='books--filter#open'][data-level-target='year']"
    end

    test "emits empty pane frames carrying their deferred source" do
      render_modal

      assert_selector "turbo-frame#books_filter_pane_category[data-pane-src]"
      assert_selector "turbo-frame#books_filter_pane_country[data-pane-src]"
      assert_no_selector "turbo-frame#books_filter_pane_category input"
    end

    test "panes are not lazy turbo-frames" do
      render_modal

      assert_no_selector "turbo-frame#books_filter_pane_category[loading='lazy']"
      assert_no_selector "turbo-frame#books_filter_pane_category[src]"
    end

    test "the pane source carries the current filters" do
      render_modal(categories: [categories(:books_novels_genre)], year_start: "1900")

      src = page.find("turbo-frame#books_filter_pane_category")["data-pane-src"]
      assert_includes src, "novels"
      assert_includes src, "1900"
    end

    test "renders the year inputs with the applied values" do
      render_modal(year_start: "1900", year_end: "2000")

      assert_selector "input[name='year_start'][value='1900']"
      assert_selector "input[name='year_end'][value='2000']"
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

    test "clear links to the unfiltered path" do
      render_modal(categories: [categories(:books_novels_genre)])

      assert_selector "a[href='/']"
    end

    test "summaries start with the applied selection" do
      render_modal(categories: [categories(:books_novels_genre)])

      assert_selector "[data-books--filter-target='summary'][data-axis='category']", text: "Novels"
    end
  end
end
