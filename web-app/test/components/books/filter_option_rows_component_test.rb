require "test_helper"

module Books
  class FilterOptionRowsComponentTest < ViewComponent::TestCase
    def render_rows(**options)
      render_inline(Books::FilterOptionRowsComponent.new(axis: :category, type: "genre", **options))
    end

    test "checkboxes carry no name so they are never submitted" do
      render_rows(rows: [{record: categories(:books_novels_genre), count: 12}])

      assert_selector "input[type=checkbox]"
      assert_no_selector "input[name]"
    end

    test "checkboxes carry axis, type, slug and display name" do
      render_rows(rows: [categories(:books_novels_genre)])

      assert_selector "input[data-filter-option][data-axis='category'][data-type='genre'][data-slug='novels'][data-name='Novels']" \
        "[data-action='change->books--filter#toggle']"
    end

    test "the country axis is reported on the checkbox" do
      render_rows(axis: :country, type: "country", rows: [books_countries(:french)])

      assert_selector "input[data-axis='country'][data-type='country'][data-slug='french']"
    end

    test "each row's label carries the lowercased text the client filter matches" do
      render_rows(rows: [categories(:books_novels_genre)])

      assert_selector "label[data-filter-row][data-filter-text='novels']"
    end

    test "accepts bare records as well as count hashes" do
      render_rows(rows: [categories(:books_novels_genre)])

      assert_selector "input[data-slug='novels']"
    end

    test "rows are never rendered checked" do
      render_rows(rows: [categories(:books_novels_genre)])

      assert_no_selector "input[checked]"
    end

    test "shows counts by default and omits them on request" do
      rows = [{record: categories(:books_novels_genre), count: 1234}]
      render_rows(rows: rows)
      assert_text "1,234"

      render_rows(rows: rows, show_counts: false)
      assert_no_text "1,234"
    end

    test "has no type badge" do
      render_rows(rows: [categories(:books_politics_subject)], type: "subject")

      assert_no_selector ".badge"
    end

    test "renders nothing for an empty row set" do
      render_rows(rows: [])

      assert_no_selector "input"
    end

    test "marks the option name with a stable hook" do
      render_rows(rows: [{record: categories(:books_novels_genre), count: 1234}])

      assert_selector "span[data-option-label]", count: 1, exact_text: "Novels"
    end
  end
end
