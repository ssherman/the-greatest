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

  # Row copy (docs/superpowers/specs/2026-11-25-book-submission-alerts-design.md)

  HINT = "It can take a while. You can leave this page and we'll still add it."
  STALLED = "Still working on it. Reload the page to check."

  def rows = @doc.css("[data-testid=book-submission-row]")

  def node(submission) = @doc.css("##{ActionView::RecordIdentifier.dom_id(submission)}").first

  def row_text(submission) = node(submission).text.squish

  def amazon_row(status, **attrs)
    row(status, input_method: :amazon, goodreads_book_id: nil, asin: "0593188985",
      raw_input: "https://www.amazon.com/Long-Wave-Novel/dp/0593188985/ref=sr_1_1?dib=eyJ2Ijoi", **attrs)
  end

  def isbn_row(status, **attrs)
    row(status, input_method: :isbn, goodreads_book_id: nil, isbn13: "9780061054884", raw_input: "0-06-105488-7", **attrs)
  end

  def title_row(title, status = :needs_details, **attrs)
    row(status, input_method: :title_authors, goodreads_book_id: nil, raw_input: nil, typed_title: title,
      typed_author_names: ["A"], **attrs)
  end

  test "a request with a title is called by it" do
    cases = {
      queued: [%(Adding "The Dispossessed" #{HINT} #{STALLED} Cancel), {}],
      looking_up: [%(Adding "The Dispossessed" #{HINT} #{STALLED} Cancel), {}],
      added: [%(Added "The Dispossessed" Dismiss), {created_book: true}],
      failed: [%(Could not add "The Dispossessed" Try another way Dismiss), {}]
    }
    cases.each do |status, (copy, attrs)|
      submission = row(status, resolved_title: "The Dispossessed", **attrs)
      render_strip([submission])
      assert_equal copy, row_text(submission), status.to_s
    end
    existing = row(:added, resolved_title: "The Dispossessed")
    render_strip([existing])
    assert_equal %(Already on the site: added "The Dispossessed" Dismiss), row_text(existing)
  end

  test "a request with no title yet is called by where it came from, with its short reference" do
    cases = {
      row(:queued, goodreads_book_id: 5107) => "Adding a book from Goodreads Goodreads book 5107. #{HINT} #{STALLED} Cancel",
      amazon_row(:looking_up) => "Adding a book from Amazon Amazon item 0593188985. #{HINT} #{STALLED} Cancel",
      isbn_row(:queued) => "Adding a book by ISBN ISBN 9780061054884. #{HINT} #{STALLED} Cancel",
      isbn_row(:queued, isbn13: nil, isbn10: "0061054887") => "Adding a book by ISBN ISBN 0061054887. #{HINT} #{STALLED} Cancel",
      title_row("The Quiet Year", :queued) => %(Adding "The Quiet Year" #{HINT} #{STALLED} Cancel),
      amazon_row(:failed) => "Could not add a book from Amazon Amazon item 0593188985 Try another way Dismiss",
      amazon_row(:cancelled, review_status: :rejected) =>
        "We couldn't verify a book from Amazon, so it was removed. Amazon item 0593188985 Dismiss",
      amazon_row(:added, created_book: true) => "Added a book from Amazon Amazon item 0593188985 Dismiss"
    }
    render_strip(cases.keys)

    cases.each { |submission, copy| assert_equal copy, row_text(submission) }
  end

  test "a needs_details row says what was not found, by how the reader asked, and names the request" do
    link = "We couldn't find a book from that link."
    cases = {
      row(:needs_details, goodreads_book_id: 5107) => [link, "Goodreads book 5107"],
      amazon_row(:needs_details) => [link, "Amazon item 0593188985"],
      isbn_row(:needs_details) => ["We couldn't find a book with that ISBN.", "ISBN 9780061054884"],
      title_row("The Quiet Year") => ["We couldn't find that book.", "The Quiet Year"]
    }

    render_strip(cases.keys)

    cases.each do |submission, (copy, label)|
      assert_equal "#{copy} #{label} Try another way Cancel", row_text(submission), submission.input_method
    end
  end

  test "the pasted text is never shown, whatever the status" do
    submissions = %i[queued looking_up needs_details added failed].flat_map do |status|
      [row(status, raw_input: "https://www.goodreads.com/PASTED"), amazon_row(status).tap { |s| s.update!(raw_input: "https://www.amazon.com/PASTED") },
        isbn_row(status).tap { |s| s.update!(raw_input: "PASTED") }]
    end
    submissions << row(:cancelled, review_status: :rejected, raw_input: "https://www.goodreads.com/PASTED")
    render_strip(submissions)

    assert_equal submissions.size, rows.size
    assert_no_match(/PASTED/, @doc.to_html)
  end

  test "two needs_details rows of one kind can be told apart, and their text is escaped" do
    first = title_row("<b>One</b>")
    second = title_row("Two")
    render_strip([first, second])

    assert_includes row_text(first), "<b>One</b>"
    assert_includes row_text(second), "Two"
    assert_empty @doc.css("b")
    assert_empty @doc.css("a")
  end

  test "every row names its request once" do
    submissions = %i[queued looking_up needs_details added failed].map { |status| row(status, resolved_title: "Once #{status}") }
    submissions << row(:cancelled, resolved_title: "Once rejected", review_status: :rejected)
    render_strip(submissions)

    submissions.each { |submission| assert_equal 1, row_text(submission).scan(submission.resolved_title).size, submission.status }
  end

  test "only a request in progress has a spinner, and a clock and line for when the page stopped checking" do
    working = row(:looking_up)
    others = %i[needs_details added failed].map { |status| row(status) }
    render_strip([working, *others])

    assert_equal 1, node(working).css(".loading").size
    assert_equal 2, node(working).css("[data-when=stalled]").size
    others.each do |other|
      assert_empty node(other).css(".loading"), other.status
      assert_empty node(other).css("[data-when=stalled]"), other.status
    end
  end

  test "icons and spinners are silent, and no row is a live region of its own" do
    render_strip(%i[looking_up needs_details added failed].map { |status| row(status) })

    assert_equal 4, rows.size
    icons = @doc.css("svg, .loading")
    assert_operator icons.size, :>=, 4
    icons.each { |icon| assert_equal "true", icon["aria-hidden"] }
    assert_empty @doc.css("[role=alert], [role=status], [aria-live]")
  end

  test "an added row links to its book's page and nothing else does" do
    book = Books::Book.create!(title: "A Linked Book")
    added = row(:added, book: book, created_book: true)
    gone = row(:added, created_book: true)
    working = row(:looking_up, book: book)
    rejected = row(:added, book: book, review_status: :rejected)
    render_strip([added, gone, working, rejected])

    assert_equal [routes.book_path(book.slug)], @doc.css("a").map { |a| a["href"] }
    assert_equal "View book", node(added).css("a").text.strip
  end

  test "a rejected row says it was removed" do
    rejected = row(:cancelled, resolved_title: "Odd Book", review_status: :rejected)
    render_strip([rejected])

    assert_includes row_text(rejected), %(We couldn't verify "Odd Book", so it was removed.)
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
    assert_includes row_text(with_book), "Adding"
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
