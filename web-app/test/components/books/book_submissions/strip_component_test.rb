# frozen_string_literal: true

require "test_helper"

class Books::BookSubmissions::StripComponentTest < ViewComponent::TestCase
  def routes = Rails.application.routes.url_helpers

  setup do
    @user = users(:regular_user)
    @list = user_lists(:regular_user_books_favorites)
  end

  def row(status, **attrs)
    Books::BookSubmission.create!({
      user: @user, user_list: @list, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
      raw_input: "https://www.goodreads.com/book/show/1", status: status, fingerprint: SecureRandom.hex(4)
    }.merge(attrs))
  end

  def state = @doc.css("turbo-frame#book_submissions > [data-testid=book-submissions-state]").first

  def render_strip(submissions, **options)
    @doc = render_inline(Books::BookSubmissions::StripComponent.new(list: @list, submissions: submissions, **options))
  end

  test "always renders the frame, even with nothing to show" do
    render_strip([])

    assert_equal 1, @doc.css("turbo-frame#book_submissions").size
  end

  test "marks the state element, a child of the frame, for polling only while something is in progress" do
    render_strip([row(:queued)])
    assert_equal "true", state["data-in-progress"]

    render_strip([row(:added)])
    assert_nil state["data-in-progress"]
  end

  test "reload_list is set only when asked" do
    render_strip([row(:added)], reload_list: true)
    assert_equal "true", state["data-reload-list"]

    render_strip([row(:added)])
    assert_nil state["data-reload-list"]
  end

  test "open rows offer cancel and finished rows offer dismiss" do
    open = row(:queued)
    done = row(:added)
    render_strip([open, done])

    assert_equal 1, @doc.css("form[action='#{routes.cancel_books_my_book_submission_path(open)}']").size
    assert_equal 1, @doc.css("form[action='#{routes.dismiss_books_my_book_submission_path(done)}']").size
    assert_empty @doc.css("form[action='#{routes.dismiss_books_my_book_submission_path(open)}']")
  end

  test "a needs_details row carries its id so the dialog can replace it" do
    stuck = row(:needs_details)
    render_strip([stuck])

    assert_equal stuck.id.to_s, @doc.css("[data-replaces]").first["data-replaces"]
  end

  test "reader text is escaped and nothing links to it" do
    submission = row(:added, raw_input: "javascript:alert(1)")
    submission.update_columns(resolved_title: "<b>Bold</b>")
    render_strip([submission])

    assert_includes @doc.text, "<b>Bold</b>"
    assert_empty @doc.css("b")
    assert_empty @doc.css("a")
  end
end
