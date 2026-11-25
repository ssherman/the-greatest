# frozen_string_literal: true

require "test_helper"

class Books::BookSubmissions::MountComponentTest < ViewComponent::TestCase
  def routes = Rails.application.routes.url_helpers

  test "the strip frame loads lazily from this list's endpoint inside the element that polls it, beside the dialog" do
    list = user_lists(:regular_user_books_favorites)
    doc = render_inline(Books::BookSubmissions::MountComponent.new(list: list))

    frame = doc.css("[data-controller='books--book-submissions'] > turbo-frame#book_submissions").first
    assert_equal routes.books_my_list_book_submissions_path(list), frame["src"]
    assert_equal "_top", frame["target"]
    assert_equal "polite", doc.css("[data-testid=book-submission-strip]").first["aria-live"]
    assert_equal 1, doc.css("dialog[data-testid=book-submission-dialog]").size
  end
end
