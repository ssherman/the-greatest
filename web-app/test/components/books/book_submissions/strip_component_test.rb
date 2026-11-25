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

  # Row copy (spec section 6)

  def rows = @doc.css("[data-testid=book-submission-row]")

  def row_text(submission) = @doc.css("##{ActionView::RecordIdentifier.dom_id(submission)}").text.squish

  test "each status reads as the spec says" do
    cases = {
      queued: ["Adding: The Dispossessed", {resolved_title: "The Dispossessed"}],
      looking_up: ["Adding: The Dispossessed", {resolved_title: "The Dispossessed"}],
      needs_details: ["We couldn't find a book from that link. Try another way", {}],
      added: ["Added The Dispossessed", {resolved_title: "The Dispossessed", created_book: true}],
      failed: ["Could not add The Dispossessed", {resolved_title: "The Dispossessed"}]
    }
    cases.each do |status, (copy, attrs)|
      submission = row(status, **attrs)
      render_strip([submission])
      assert_includes row_text(submission), copy, status.to_s
    end
    existing = row(:added, resolved_title: "The Dispossessed")
    render_strip([existing])
    assert_includes row_text(existing), "Already on the site: added The Dispossessed"
  end

  test "a rejected row says it was removed" do
    rejected = row(:cancelled, resolved_title: "Odd Book", review_status: :rejected)
    render_strip([rejected])

    assert_includes row_text(rejected), "We couldn't verify Odd Book, so it was removed."
  end

  test "every row carries the book-submission-row test id" do
    render_strip([row(:queued), row(:failed)])

    assert_equal 2, rows.size
  end

  test "cancel shows only on an open row with no book" do
    bare = row(:queued)
    with_book = row(:looking_up, book: Books::Book.create!(title: "Has A Book"))
    render_strip([bare, with_book])

    assert_equal 1, @doc.css("form[action='#{routes.cancel_books_my_book_submission_path(bare)}']").size
    assert_empty @doc.css("form[action='#{routes.cancel_books_my_book_submission_path(with_book)}']")
    assert_includes row_text(with_book), "Adding:"
    assert_empty @doc.css("form[action='#{routes.dismiss_books_my_book_submission_path(with_book)}']")
  end

  test "needs_details and failed offer Try another way and the others do not" do
    stuck = row(:needs_details)
    failed = row(:failed)
    queued = row(:queued)
    render_strip([stuck, failed, queued])

    {stuck => true, failed => true, queued => false}.each do |submission, offered|
      buttons = @doc.css("##{ActionView::RecordIdentifier.dom_id(submission)} button[data-action*='tryAnother']")
      assert_equal offered, buttons.any?, submission.status
    end
  end

  test "Try another way carries the failed method and the typed title and authors as data" do
    failed = row(:failed, input_method: :title_authors, goodreads_book_id: nil, raw_input: nil,
      typed_title: %(A "Title"), typed_author_names: ["Ann <b>", "Bo"])
    render_strip([failed])

    button = @doc.css("button[data-action*='tryAnother']").first
    assert_equal failed.id.to_s, button["data-replaces"]
    assert_equal "title_authors", button["data-input-method"]
    assert_equal %(A "Title"), button["data-title"]
    assert_equal ["Ann <b>", "Bo"], JSON.parse(button["data-authors"])
    assert_empty @doc.css("b")
  end

  test "forms inside the strip stay in the strip frame" do
    render_strip([row(:queued), row(:added)])

    @doc.css("form").each { |form| assert_equal "book_submissions", form["data-turbo-frame"] }
  end

  test "reader text wraps anywhere" do
    render_strip([row(:added, resolved_title: "x" * 300)])

    assert @doc.css("[class*='overflow-wrap:anywhere']").any?
  end

  test "in_progress marks polling even when no shown row is in progress" do
    render_strip([row(:added)], in_progress: true)

    assert_equal "true", state["data-in-progress"]
  end
end
