require "test_helper"

module Books
  class FilterOptionRowsComponentTest < ViewComponent::TestCase
    def render_rows(**options)
      render_inline(Books::FilterOptionRowsComponent.new(**options))
    end

    test "renders one checkbox per row with the category input name" do
      render_rows(axis: :category, rows: [
        {record: categories(:books_novels_genre), count: 12},
        {record: categories(:books_fiction_genre), count: 9}
      ])

      assert_selector "input[name='category_slugs[]']", count: 2
      assert_selector "input[value='novels']"
      assert_selector "input[value='fiction']"
    end

    test "uses the country input name for the country axis" do
      render_rows(axis: :country, rows: [{record: books_countries(:french), count: 2}])

      assert_selector "input[name='country_slugs[]'][value='french']"
    end

    test "accepts bare records as well as count hashes" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])

      assert_selector "input[value='novels']"
    end

    test "rows are unchecked by default and checked on request" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])
      assert_no_selector "input[checked]"

      render_rows(axis: :category, rows: [categories(:books_novels_genre)], checked: true)
      assert_selector "input[checked]"
    end

    test "carries the data hooks the Stimulus controller reads" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])

      assert_selector "label[data-option-value='novels']"
      assert_selector "input[data-axis='category'][data-action='change->books--filter#toggle']"
    end

    test "shows counts by default and omits them on request" do
      render_rows(axis: :category, rows: [{record: categories(:books_novels_genre), count: 1234}])
      assert_text "1,234"

      render_rows(axis: :category, rows: [{record: categories(:books_novels_genre), count: 1234}], show_counts: false)
      assert_no_text "1,234"
    end

    # Every type is badged, genres included. Search spans all three types and a
    # row that says nothing is indistinguishable from the ones that do.
    test "badges every category type, calling a location a Setting" do
      render_rows(axis: :category, rows: [
        categories(:books_politics_subject),
        categories(:books_france_location),
        categories(:books_novels_genre)
      ])

      assert_selector "label[data-option-value='politics'] .badge", exact_text: "Subject"
      assert_selector "label[data-option-value='france'] .badge", exact_text: "Setting"
      assert_selector "label[data-option-value='novels'] .badge", exact_text: "Genre"
    end

    # category_type is nullable (db/schema.rb), so an untyped row must render a
    # row rather than a badge reading "Unknown".
    test "never badges a category with no type" do
      untyped = categories(:books_novels_genre)
      untyped.update_column(:category_type, nil)

      render_rows(axis: :category, rows: [untyped.reload])

      assert_selector "input[value='novels']"
      assert_no_selector ".badge"
    end

    test "never badges a country" do
      render_rows(axis: :country, rows: [books_countries(:french)])

      assert_no_selector ".badge"
    end

    test "renders nothing for an empty row set" do
      render_rows(axis: :category, rows: [])

      assert_no_selector "input"
    end

    test "marks the option name with a stable hook the filter controller can read" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])

      assert_selector "label[data-option-value='novels'] span[data-option-label]", exact_text: "Novels"
    end

    test "the count span is not mistaken for the option name" do
      render_rows(axis: :category, rows: [{record: categories(:books_novels_genre), count: 1234}])

      assert_selector "span[data-option-label]", count: 1
    end
  end
end
