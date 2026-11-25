# frozen_string_literal: true

require "test_helper"

class Books::BookSubmissions::HitsComponentTest < ViewComponent::TestCase
  def routes = Rails.application.routes.url_helpers

  setup do
    @list = user_lists(:regular_user_books_favorites)
    author = Books::Author.create!(name: "Ursula Le Guin")
    @book = Books::Book.create!(title: "The <i>Dispossessed</i>", first_published_year: 1974)
    Books::BookAuthor.create!(book: @book, author: author, position: 1)
  end

  def render_hits(input)
    @doc = render_inline(Books::BookSubmissions::HitsComponent.new(list: @list, books: [@book], input: input))
  end

  test "shows each book's title, author and year as escaped text with an add form" do
    render_hits({"method" => "isbn", "isbn" => "9780441478125"})

    assert_includes @doc.text, "The <i>Dispossessed</i>"
    assert_includes @doc.text, "Ursula Le Guin"
    assert_includes @doc.text, "1974"
    assert_empty @doc.css("i")
    field = @doc.css("form[action='#{routes.user_list_items_path(@list)}'] input[name='user_list_item[listable_id]']").first
    assert_equal @book.id.to_s, field["value"]
  end

  test "None of these resends the input with confirmed_new, escaped" do
    render_hits({"method" => "title_authors", "title" => %(x"><script>), "authors" => ["A", "B"]})

    form = @doc.css("form").find { |f| f.css("input[name='confirmed_new']").any? }
    assert form
    assert_equal ["A", "B"], form.css("input[name='book_submission[authors][]']").map { |i| i["value"] }
    assert_equal %(x"><script>), form.css("input[name='book_submission[title]']").first["value"]
    assert_empty @doc.css("script")
  end

  test "drops input of the wrong type and keys it does not know" do
    render_hits({"method" => "goodreads", "goodreads_url" => {"a" => 1}, "bogus" => "x"})

    assert_empty @doc.css("input[name='book_submission[bogus]']")
    assert_empty @doc.css("input[name='book_submission[goodreads_url]']")
  end

  test "carries a valid replaces id and drops a bad one" do
    @doc = render_inline(Books::BookSubmissions::HitsComponent.new(list: @list, books: [@book], input: {"method" => "isbn"}, replaces: "42"))
    assert_equal "42", @doc.css("input[name='replaces']").first["value"]

    @doc = render_inline(Books::BookSubmissions::HitsComponent.new(list: @list, books: [@book], input: {"method" => "isbn"}, replaces: "4x"))
    assert_empty @doc.css("input[name='replaces']")
  end
end
