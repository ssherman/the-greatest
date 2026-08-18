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

    test "applied categories render checked in the modal itself, not inside the pane frame" do
      render_modal(categories: [categories(:books_novels_genre)])

      assert_selector "[data-books--filter-target='selected'][data-axis='category'] input[value='novels'][checked]"
      assert_no_selector "turbo-frame#books_filter_pane_category input"
    end

    test "applied countries render checked in the modal itself, not inside the pane frame" do
      render_modal(countries: [books_countries(:french)])

      assert_selector "[data-books--filter-target='selected'][data-axis='country'] input[value='french'][checked]"
      assert_no_selector "turbo-frame#books_filter_pane_country input"
    end

    test "the selected container renders nothing when no filter is applied on that axis" do
      render_modal

      assert_selector "[data-books--filter-target='selected'][data-axis='category']"
      assert_no_selector "[data-books--filter-target='selected'][data-axis='category'] input"
    end

    test "the dialog has an accessible name pointing at the root heading" do
      render_modal

      assert_selector "dialog[aria-labelledby='books_filter_modal_heading_root']"
      assert_selector "h3#books_filter_modal_heading_root", text: "Filters"
    end

    test "each pane carries its own heading for the dialog's accessible name to target" do
      render_modal

      assert_selector "#books_filter_modal_heading_category"
      assert_selector "#books_filter_modal_heading_country"
      assert_selector "#books_filter_modal_heading_year"
    end

    test "search inputs carry an aria-label independent of the placeholder" do
      render_modal

      assert_selector "input[data-axis='category'][aria-label]"
      assert_selector "input[data-axis='country'][aria-label]"
    end

    test "the origin axis is offered on the unscoped list" do
      render_inline(Books::FilterModalComponent.new)

      assert_selector "[data-level-target='country']"
    end

    test "the origin axis is dropped on a collection page" do
      render_inline(Books::FilterModalComponent.new(
        collection: Collections::Registry.find(:books, "africa")
      ))

      assert_no_selector "[data-level-target='country']"
      assert_selector "[data-level-target='category']"
      assert_selector "[data-level-target='year']"
    end

    test "a collection page carries its slug through apply" do
      render_inline(Books::FilterModalComponent.new(
        collection: Collections::Registry.find(:books, "africa")
      ))

      assert_selector "input[name='collection'][value='africa']", visible: :all
    end

    test "clear returns to the bare collection" do
      render_inline(Books::FilterModalComponent.new(
        collection: Collections::Registry.find(:books, "africa")
      ))

      assert_selector "a[href='/africa']", text: "Clear"
    end
  end
end
