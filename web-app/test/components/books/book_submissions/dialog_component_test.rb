# frozen_string_literal: true

require "test_helper"

class Books::BookSubmissions::DialogComponentTest < ViewComponent::TestCase
  def routes = Rails.application.routes.url_helpers

  setup do
    @list = user_lists(:regular_user_books_favorites)
    @doc = render_inline(Books::BookSubmissions::DialogComponent.new(list: @list))
  end

  test "is a native dialog named by its heading" do
    dialog = @doc.css("dialog[data-testid=book-submission-dialog]").first
    assert dialog
    heading = @doc.css("##{dialog["aria-labelledby"]}").first
    assert_equal "Add a book that isn't on the site", heading.text.strip
  end

  test "offers the four methods in order inside a fieldset with a legend, Goodreads checked" do
    radios = @doc.css("fieldset input[type=radio][name='book_submission[method]']")

    assert_equal %w[goodreads amazon isbn title_authors], radios.map { |radio| radio["value"] }
    assert_equal ["goodreads"], radios.select { |radio| radio["checked"] }.map { |radio| radio["value"] }
    assert @doc.css("fieldset > legend.fieldset-legend").any?
  end

  test "only the chosen method's inputs are enabled and every input has a label" do
    fields = @doc.css("input[name^='book_submission[']:not([type=radio])")
    enabled = fields.reject { |field| field["disabled"] }

    assert_equal ["book_submission[goodreads_url]"], enabled.map { |field| field["name"] }
    assert_equal ["book_submission[amazon_url]", "book_submission[authors][]", "book_submission[isbn]", "book_submission[title]"],
      fields.select { |field| field["disabled"] }.map { |field| field["name"] }.sort
    (fields + @doc.css("input[type=radio]")).each do |field|
      assert @doc.css("label[for='#{field["id"]}']").any?, "#{field["name"]} has no label"
    end
  end

  test "carries the limits as maxlength" do
    assert_equal ["2048"], @doc.css("input[name='book_submission[goodreads_url]']").map { |field| field["maxlength"] }
    assert_equal ["255"], @doc.css("input[name='book_submission[title]']").map { |field| field["maxlength"] }
    assert_equal ["255"], @doc.css("input[name='book_submission[authors][]']").map { |field| field["maxlength"] }
  end

  test "tells the reader which list the book will land on, escaped" do
    @list.name = %(<i>Mine</i> "list")
    doc = render_inline(Books::BookSubmissions::DialogComponent.new(list: @list))

    assert_includes doc.text.squish, %(We'll put it on "#{@list.name}" when it's ready.)
    assert_empty doc.css("dialog i")
  end

  test "the form posts to this list's endpoint, stays in the strip frame and carries no live replaces" do
    form = @doc.css("form[action='#{routes.books_my_list_book_submissions_path(@list)}']").first

    assert_equal "book_submissions", form["data-turbo-frame"]
    assert_equal "post", form["method"]
    assert form.css("input[name=replaces]").all? { |field| field["disabled"] }
  end

  test "errors are announced and hits have their own container" do
    errors = @doc.css("#book-submission-errors").first
    assert_equal "alert", errors["role"]
    assert errors.text.blank?
    assert @doc.css("#book-submission-hits[data-testid=book-submission-hits]").any?
  end
end
