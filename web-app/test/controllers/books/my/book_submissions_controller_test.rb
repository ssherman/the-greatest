require "test_helper"

class Books::My::BookSubmissionsControllerTest < ActionDispatch::IntegrationTest
  GOODREADS = {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/13651"}.freeze

  setup do
    @host = Rails.application.config.domains[:books]
    @user = users(:regular_user)
    @list = user_lists(:regular_user_books_favorites)
    @user.book_submissions.delete_all
    ::Books::ProcessBookSubmissionJob.stubs(:perform_async)
  end

  def post_submission(list = @list, input: GOODREADS, extra: {}, host: @host)
    post books_my_list_book_submissions_path(list),
      params: {book_submission: input}.merge(extra), as: :turbo_stream, headers: {"HOST" => host}
  end

  def row(status: :queued, user: @user, list: @list, **attrs)
    ::Books::BookSubmission.create!({
      user: user, user_list: list, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
      raw_input: "https://www.goodreads.com/book/show/1", status: status, fingerprint: SecureRandom.hex(4)
    }.merge(attrs))
  end

  def marked? = response.headers["Set-Cookie"].to_s.include?(UserStateChangeMarker::COOKIE.to_s)

  def stream? = response.media_type == "text/vnd.turbo-stream.html"

  # create

  test "create makes a submission and answers a turbo stream" do
    sign_in_as @user, stub_auth: true

    assert_difference -> { @user.book_submissions.count }, 1 do
      post_submission
    end

    assert_response :success
    assert stream?
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, "book_submissions"
  end

  test "a replayed POST answers success and leaves one row" do
    sign_in_as @user, stub_auth: true

    2.times { post_submission }

    assert_response :success
    assert_equal 1, @user.book_submissions.count
  end

  test "a failed enqueue still answers success" do
    ::Books::ProcessBookSubmissionJob.stubs(:perform_async).raises(RedisClient::CannotConnectError, "down")
    sign_in_as @user, stub_auth: true

    post_submission

    assert_response :success
    assert_equal 1, @user.book_submissions.count
  end

  test "hits answer 200 with the hits in the dialog and create no row" do
    book = ::Books::Book.create!(title: "Already Here")
    Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "13651", source: :open_library)
    sign_in_as @user, stub_auth: true

    post_submission

    assert_response :success
    assert stream?
    assert_includes response.body, "book-submission-hits"
    assert_includes response.body, "Already Here"
    assert_equal 0, @user.book_submissions.count
  end

  test "confirmed_new makes the submission despite hits" do
    book = ::Books::Book.create!(title: "Already Here")
    Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "13651", source: :open_library)
    sign_in_as @user, stub_auth: true

    post_submission(extra: {confirmed_new: "1"})

    assert_equal 1, @user.book_submissions.count
  end

  test "hits carry the reader's input back, escaped" do
    book = ::Books::Book.create!(title: "Hit")
    Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780441478125", source: :open_library)
    sign_in_as @user, stub_auth: true

    post_submission(input: {method: "isbn", isbn: "9780441478125"})

    assert_includes response.body, "9780441478125"
    assert_includes response.body, "confirmed_new"
  end

  test "invalid input is a 422 stream into the dialog's errors" do
    sign_in_as @user, stub_auth: true

    post_submission(input: {method: "goodreads", goodreads_url: "https://example.com/<script>"})

    assert_response :unprocessable_entity
    assert stream?
    assert_includes response.body, "book-submission-errors"
    refute_includes response.body, "<script>"
    assert_equal 0, @user.book_submissions.count
  end

  test "two methods in one request is a 422" do
    sign_in_as @user, stub_auth: true

    post_submission(input: GOODREADS.merge(isbn: "9780441478125"))

    assert_response :unprocessable_entity
    assert_equal 0, @user.book_submissions.count
  end

  test "strings that are arrays, hashes or missing never raise" do
    sign_in_as @user, stub_auth: true

    [{book_submission: "x"}, {book_submission: ["a"]}, {}, {book_submission: {method: {a: 1}}},
      {book_submission: {method: "title_authors", title: ["a"], authors: "x"}},
      {book_submission: GOODREADS, replaces: {a: 1}, confirmed_new: ["1"]}].each do |params|
      post books_my_list_book_submissions_path(@list), params: params, as: :turbo_stream, headers: {"HOST" => @host}
      assert_includes [200, 201, 422], response.status
    end
  end

  test "a title and authors request takes an author array" do
    sign_in_as @user, stub_auth: true

    post_submission(input: {method: "title_authors", title: "Zzyzx Unheard Book", authors: ["Ursula K. Le Guin"]})

    assert_response :success
    assert_equal ["Ursula K. Le Guin"], Books::BookSubmission.where(user_id: @user.id).first.typed_author_names
  end

  test "the 21st in 24 hours is refused as a stream and the 20th is not" do
    sign_in_as @user, stub_auth: true
    19.times { row(status: :added) }

    post_submission
    assert_response :success

    post_submission(input: {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/2"})
    assert_response :too_many_requests
    assert stream?
    assert_equal 20, @user.book_submissions.count
  end

  test "replaces cancels the failed row" do
    old = row(status: :failed)
    sign_in_as @user, stub_auth: true

    post_submission(extra: {replaces: old.id})

    assert_equal "cancelled", old.reload.status
  end

  test "another user's list, a music list and a missing list are 404 streams" do
    sign_in_as @user, stub_auth: true
    other = Books::UserList.where.not(user_id: @user.id).first || Books::UserList.create!(user: users(:editor_user), name: "Theirs", list_type: :custom)

    [other.id, user_lists(:regular_user_music_albums_favorites).id, 0].each do |id|
      post books_my_list_book_submissions_path(id), params: {book_submission: GOODREADS}, as: :turbo_stream, headers: {"HOST" => @host}

      assert_response :not_found
      assert stream?
    end
    assert_equal 0, @user.book_submissions.count
  end

  test "a list deleted between the lookup and the insert answers the 404 stream" do
    list = ::Books::UserList.create!(user: @user, name: "Going", list_type: :custom)
    sign_in_as @user, stub_auth: true
    gone = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if gone || payload[:sql] !~ /\ASELECT.*FROM "books_book_submissions"/m

      gone = true
      ::UserList.where(id: list.id).delete_all
    end

    post_submission(list)

    assert gone
    assert_response :not_found
    assert stream?
    assert_includes response.body, "That list or request no longer exists. Reload the page"
    assert_equal 0, @user.book_submissions.count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a signed-out POST is a 401 toast stream and the limiter never keys on nil" do
    12.times do
      post_submission
      assert_response :unauthorized
      assert stream?
    end
  end

  test "an invalid CSRF token is a stream" do
    sign_in_as @user, stub_auth: true
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post_submission(extra: {authenticity_token: "bogus"})

    assert_response :unprocessable_entity
    assert stream?
    assert_equal 0, @user.book_submissions.count
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "writes are rate limited per user and answer as a stream" do
    sign_in_as @user, stub_auth: true
    10.times { post_submission(input: {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/#{rand(10..999_999)}"}) }

    post_submission(input: {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/5"})

    assert_response :too_many_requests
    assert stream?
  end

  test "the limiter is per user" do
    sign_in_as @user, stub_auth: true
    10.times { post_submission(input: {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/#{rand(10..999_999)}"}) }
    other = users(:editor_user)
    other_list = Books::UserList.where(user: other).first || Books::UserList.create!(user: other, name: "Mine", list_type: :custom)
    sign_in_as other, stub_auth: true

    post_submission(other_list)

    assert_response :success
  end

  # cancel and dismiss

  test "cancel cancels an open row" do
    submission = row
    sign_in_as @user, stub_auth: true

    post cancel_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}

    assert_response :success
    assert stream?
    assert_equal "cancelled", submission.reload.status
  end

  test "cancel after a book exists is refused" do
    submission = row(status: :looking_up, book: ::Books::Book.create!(title: "Made"))
    sign_in_as @user, stub_auth: true

    post cancel_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}

    assert_response :unprocessable_entity
    assert stream?
    assert_equal "looking_up", submission.reload.status
  end

  test "cancel and dismiss of another user's row are 404 streams" do
    submission = row(user: users(:editor_user), list: nil)
    sign_in_as @user, stub_auth: true

    post cancel_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}
    assert_response :not_found
    assert stream?

    post dismiss_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}
    assert_response :not_found
    assert_equal "queued", submission.reload.status
  end

  test "signed-out cancel and dismiss are 401 streams" do
    post cancel_books_my_book_submission_path(row), as: :turbo_stream, headers: {"HOST" => @host}
    assert_response :unauthorized
    assert stream?

    post dismiss_books_my_book_submission_path(row), as: :turbo_stream, headers: {"HOST" => @host}
    assert_response :unauthorized
  end

  test "dismiss hides a finished row and refuses an open one" do
    done = row(status: :added)
    open = row
    sign_in_as @user, stub_auth: true

    post dismiss_books_my_book_submission_path(done), as: :turbo_stream, headers: {"HOST" => @host}
    assert_response :success
    assert_not_nil done.reload.dismissed_at

    post dismiss_books_my_book_submission_path(open), as: :turbo_stream, headers: {"HOST" => @host}
    assert_response :unprocessable_entity
    assert_nil open.reload.dismissed_at
  end

  # index (the strip)

  def strip(list = @list, headers: {})
    get books_my_list_book_submissions_path(list), headers: {"HOST" => @host}.merge(headers)
  end

  test "index renders the strip frame, never cached, newest first and limited to 20 of this list" do
    sign_in_as @user, stub_auth: true
    other_list = @user.user_lists.where(type: "Books::UserList").where.not(id: @list.id).first
    24.downto(0) { |i| row(status: :failed, typed_title: nil, resolved_title: "Title #{i}", created_at: i.minutes.ago) }
    row(list: other_list, resolved_title: "Elsewhere")

    strip

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.body, 'id="book_submissions"'
    refute_includes response.body, "Elsewhere"
    assert_equal 20, @controller.view_assigns.fetch("submissions").size
    assert_equal "Title 0", @controller.view_assigns.fetch("submissions").first.resolved_title
  end

  test "index hides dismissed and cancelled rows but shows a rejected one" do
    sign_in_as @user, stub_auth: true
    row(status: :added, resolved_title: "Dismissed One", dismissed_at: Time.current)
    row(status: :cancelled, resolved_title: "Cancelled One")
    row(status: :cancelled, resolved_title: "Rejected One", review_status: :rejected)
    row(status: :queued, resolved_title: "Open One")

    strip

    assert_equal %w[Open\ One Rejected\ One], @controller.view_assigns.fetch("submissions").map(&:resolved_title).sort
  end

  test "index announces a newly added row once, marks state once and asks for a reload once" do
    sign_in_as @user, stub_auth: true
    added = row(status: :added, resolved_title: "Fresh")

    strip
    assert_response :success
    assert_includes response.body, 'data-reload-list="true"'
    assert response.headers["Set-Cookie"].to_s.include?(UserStateChangeMarker::COOKIE.to_s)
    assert_not_nil added.reload.announced_at

    strip
    refute_includes response.body, "data-reload-list"
    refute response.headers["Set-Cookie"].to_s.include?(UserStateChangeMarker::COOKIE.to_s)
  end

  test "an index with nothing newly added does not mark state" do
    sign_in_as @user, stub_auth: true
    row

    strip

    refute_includes response.body, "data-reload-list"
    refute response.headers["Set-Cookie"].to_s.include?(UserStateChangeMarker::COOKIE.to_s)
  end

  test "when another poll announces the row after this poll finds the list, this one announces nothing" do
    sign_in_as @user, stub_auth: true
    added = row(status: :added)
    raced = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if raced || payload[:sql] !~ /\ASELECT.*FROM "user_lists"/m

      raced = true
      ::Books::BookSubmission.where(id: added.id).update_all(announced_at: Time.current)
    end

    strip

    assert raced
    refute_includes response.body, "data-reload-list"
    refute response.headers["Set-Cookie"].to_s.include?(UserStateChangeMarker::COOKIE.to_s)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a HEAD request does not announce" do
    sign_in_as @user, stub_auth: true
    added = row(status: :added)

    head books_my_list_book_submissions_path(@list), headers: {"HOST" => @host}

    assert_nil added.reload.announced_at
    refute marked?
  end

  {"Purpose" => "prefetch", "Sec-Purpose" => "prefetch", "X-Sec-Purpose" => "prefetch", "X-Purpose" => "preview", "X-Moz" => "prefetch"}.each do |header, value|
    test "a request with #{header}: #{value} does not announce" do
      sign_in_as @user, stub_auth: true
      added = row(status: :added)

      strip(headers: {header => value})

      assert_response :success
      assert_nil added.reload.announced_at
      refute_includes response.body, "data-reload-list"
      refute marked?
    end
  end

  test "cancelling one row announces another that was added and unannounced, then the next poll does not repeat it" do
    sign_in_as @user, stub_auth: true
    added = row(status: :added, resolved_title: "A")
    stuck = row(status: :needs_details)

    post cancel_books_my_book_submission_path(stuck), as: :turbo_stream, headers: {"HOST" => @host}

    assert_response :success
    assert_includes response.body, 'data-reload-list="true"'
    assert marked?
    assert_not_nil added.reload.announced_at

    strip
    refute_includes response.body, "data-reload-list"
    refute marked?
  end

  test "dismissing a row announces it and another added one in the same response, and the next poll does not repeat" do
    sign_in_as @user, stub_auth: true
    first = row(status: :added)
    second = row(status: :added)

    post dismiss_books_my_book_submission_path(first), as: :turbo_stream, headers: {"HOST" => @host}

    assert_includes response.body, 'data-reload-list="true"'
    assert marked?
    assert_not_nil first.reload.announced_at
    assert_not_nil second.reload.announced_at
    assert_not_nil first.dismissed_at

    strip
    refute_includes response.body, "data-reload-list"
  end

  test "create announces an added unannounced row in its stream" do
    sign_in_as @user, stub_auth: true
    added = row(status: :added)

    post_submission

    assert_response :created
    assert_includes response.body, 'data-reload-list="true"'
    assert marked?
    assert_not_nil added.reload.announced_at
  end

  test "a hits answer does not announce" do
    book = ::Books::Book.create!(title: "Already Here")
    Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "13651", source: :open_library)
    sign_in_as @user, stub_auth: true
    added = row(status: :added)

    post_submission

    assert_nil added.reload.announced_at
  end

  test "an added row behind 20 newer ones is announced" do
    sign_in_as @user, stub_auth: true
    old = row(status: :added, created_at: 2.days.ago)
    21.times { |i| row(status: :failed, created_at: i.minutes.ago) }

    strip

    assert_includes response.body, 'data-reload-list="true"'
    assert_not_nil old.reload.announced_at
  end

  test "a dismissed added unannounced row is announced" do
    sign_in_as @user, stub_auth: true
    gone = row(status: :added, dismissed_at: Time.current)

    strip

    assert_includes response.body, 'data-reload-list="true"'
    assert_not_nil gone.reload.announced_at
  end

  test "another list's and another user's added rows are not announced" do
    sign_in_as @user, stub_auth: true
    elsewhere = row(status: :added, list: @user.user_lists.where(type: "Books::UserList").where.not(id: @list.id).first)
    theirs = row(status: :added, user: users(:editor_user))

    strip

    assert_nil elsewhere.reload.announced_at
    assert_nil theirs.reload.announced_at
  end

  test "the state attributes are on a child of the frame" do
    sign_in_as @user, stub_auth: true
    row(status: :queued)

    strip

    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert_equal "true", doc.at_css("turbo-frame#book_submissions > [data-testid=book-submissions-state]")["data-in-progress"]
    assert_nil doc.at_css("turbo-frame#book_submissions")["data-in-progress"]
  end

  test "index of another user's list and a music list is a 404, signed out redirects" do
    sign_in_as @user, stub_auth: true
    strip(user_lists(:regular_user_music_albums_favorites))
    assert_response :not_found

    strip(0)
    assert_response :not_found
  end

  test "index signed out is turned away" do
    strip

    assert_response :redirect
  end

  test "raw input and titles are escaped and no link carries them" do
    sign_in_as @user, stub_auth: true
    row(raw_input: "javascript:alert(1)", status: :needs_details)
    row(raw_input: "javascript:alert(2)")
    evil = row(status: :added, resolved_title: "x")
    evil.update_columns(resolved_title: "<img src=x onerror=alert(3)>", raw_input: "javascript:alert(3)")

    strip

    refute_includes response.body, "<img src=x"
    assert_includes response.body, "&lt;img src=x"
    assert_no_match(/href=["'][^"']*(javascript|alert)/i, response.body)
  end

  test "a raw input with no title is never shown" do
    sign_in_as @user, stub_auth: true
    row(raw_input: "javascript:alert(1)").update_columns(resolved_title: nil, typed_title: nil)

    strip

    assert_includes response.body, "Adding a book from Goodreads"
    assert_no_match(/javascript/i, response.body)
  end

  test "a needs_details row names its request by its id and never shows the pasted text" do
    sign_in_as @user, stub_auth: true
    row(status: :needs_details, goodreads_book_id: 5107, raw_input: "javascript:alert(1)//<img src=x>")

    strip

    assert_includes response.body, "We couldn&#39;t find a book from that link."
    assert_includes response.body, "Goodreads book 5107"
    assert_no_match(/javascript/i, response.body)
  end

  test "index loads the books of its added rows in one query" do
    sign_in_as @user, stub_auth: true
    3.times { |i| row(status: :added, book: ::Books::Book.create!(title: "Linked #{i}"), announced_at: Time.current) }
    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries += 1 if payload[:sql].match?(/FROM "books_books"/)
    end

    strip

    assert_response :success
    assert_equal 3, response.body.scan("View book").size
    assert_equal 1, queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # Task 9: reading order, in-progress, refused writes, frame requests

  def frame_headers = {"Turbo-Frame" => "book_submissions"}

  test "a row that becomes added between reading the rows and announcing is shown in progress and announced by the next poll" do
    sign_in_as @user, stub_auth: true
    racing = row(status: :queued, resolved_title: "Racer")
    flipped = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if flipped || payload[:sql] !~ /\AUPDATE "books_book_submissions" SET "announced_at"/

      flipped = true
      ::Books::BookSubmission.where(id: racing.id).update_all(status: ::Books::BookSubmission.statuses[:added])
    end

    strip
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert flipped
    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert_includes doc.text, %(Adding "Racer")
    assert_equal "true", doc.at_css("[data-testid=book-submissions-state]")["data-in-progress"]
    refute_includes response.body, "data-reload-list"
    assert_nil racing.reload.announced_at
    refute marked?

    strip
    assert_includes response.body, 'data-reload-list="true"'
    assert_includes response.body, "added &quot;Racer&quot;"
    assert marked?
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a create stream also reads the rows before it announces" do
    sign_in_as @user, stub_auth: true
    racing = row(status: :queued, resolved_title: "Racer")
    flipped = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if flipped || payload[:sql] !~ /\AUPDATE "books_book_submissions" SET "announced_at"/

      flipped = true
      ::Books::BookSubmission.where(id: racing.id).update_all(status: ::Books::BookSubmission.statuses[:added])
    end

    post_submission(input: GOODREADS.merge(goodreads_url: "https://www.goodreads.com/book/show/777"))
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert flipped
    assert_includes response.body, "Adding &quot;Racer&quot;"
    assert_nil racing.reload.announced_at
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a row that becomes added right after the rows were read is shown in progress, polled for and not announced yet" do
    sign_in_as @user, stub_auth: true
    racing = row(status: :queued, resolved_title: "Racer")
    flipped = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if flipped || payload[:sql] !~ /\ASELECT.*FROM "books_book_submissions".*ORDER BY "books_book_submissions"."created_at" DESC.*LIMIT/m

      flipped = true
      ::Books::BookSubmission.where(id: racing.id).update_all(status: ::Books::BookSubmission.statuses[:added])
    end

    strip
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert flipped
    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert_includes doc.text, %(Adding "Racer")
    assert_equal "true", doc.at_css("[data-testid=book-submissions-state]")["data-in-progress"]
    assert_nil racing.reload.announced_at
    refute_includes response.body, "data-reload-list"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a row created and added after the rows were read is not announced by this response" do
    sign_in_as @user, stub_auth: true
    late = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if late || payload[:sql] !~ /\ASELECT.*FROM "books_book_submissions".*ORDER BY "books_book_submissions"."created_at" DESC.*LIMIT/m

      late = row(status: :added, resolved_title: "Latecomer", created_at: 1.minute.from_now)
    end

    strip
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert late
    assert_nil late.reload.announced_at
    refute_includes response.body, "data-reload-list"

    strip
    assert_includes response.body, "Latecomer"
    assert_includes response.body, 'data-reload-list="true"'
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "data-in-progress is true when an undismissed row behind the 20 shown is in progress" do
    sign_in_as @user, stub_auth: true
    row(status: :queued, created_at: 2.days.ago)
    21.times { |i| row(status: :failed, created_at: i.minutes.ago) }

    strip

    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert_equal "true", doc.at_css("[data-testid=book-submissions-state]")["data-in-progress"]
  end

  test "a dismissed in-progress-looking row or another list's row does not keep polling" do
    sign_in_as @user, stub_auth: true
    row(status: :queued, dismissed_at: Time.current)
    row(status: :queued, list: @user.user_lists.where(type: "Books::UserList").where.not(id: @list.id).first)

    strip

    refute_includes response.body, "data-in-progress"
  end

  test "a refused cancel also sends a fresh strip so the stale button goes" do
    submission = row(status: :looking_up, book: ::Books::Book.create!(title: "Made"), resolved_title: "Made")
    sign_in_as @user, stub_auth: true

    post cancel_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}

    assert_response :unprocessable_entity
    assert_includes response.body, 'target="toast-region"'
    assert_includes response.body, 'action="replace" target="book_submissions"'
    refute_includes response.body, cancel_books_my_book_submission_path(submission)
  end

  test "a refused dismiss also sends a fresh strip" do
    submission = row(status: :queued)
    sign_in_as @user, stub_auth: true

    post dismiss_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}

    assert_response :unprocessable_entity
    assert_includes response.body, 'action="replace" target="book_submissions"'
  end

  test "a destroyed provisional book's rows read as removed for the first and the second reader" do
    book = ::Books::Book.create!(title: "Provisional Doomed", provisional: true)
    second_user = users(:editor_user)
    second_list = ::Books::UserList.create!(user: second_user, name: "Second reader list", list_type: :custom)
    first = row(status: :added, book: book, created_book: true, review_status: :pending, resolved_title: "Provisional Doomed")
    second = row(status: :added, book: book, user: second_user, list: second_list, review_status: :not_needed, resolved_title: "Provisional Doomed")

    book.destroy!

    assert_equal %w[rejected rejected], [first, second].map { it.reload.review_status }
    {@user => @list, second_user => second_list}.each do |user, list|
      sign_in_as user, stub_auth: true

      strip(list)

      assert_response :success
      assert_includes response.body, "We couldn&#39;t verify &quot;Provisional Doomed&quot;, so it was removed."
    end
  end

  test "a book rejected after both readers dismissed it is shown as removed once, and dismissing again hides it" do
    ::Books::PurgeShowPagesJob.stubs(:perform_async)
    ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
    book = ::Books::Book.create!(title: "Dismissed Then Doomed", provisional: true)
    second_user = users(:editor_user)
    second_list = ::Books::UserList.create!(user: second_user, name: "Second reader list", list_type: :custom)
    first = row(status: :added, book: book, created_book: true, review_status: :pending, resolved_title: "Dismissed Then Doomed")
    second = row(status: :added, book: book, user: second_user, list: second_list, review_status: :not_needed, resolved_title: "Dismissed Then Doomed")
    readers = [[@user, @list, first], [second_user, second_list, second]]
    removed = "We couldn&#39;t verify &quot;Dismissed Then Doomed&quot;, so it was removed."
    dismiss = lambda do |submission|
      post dismiss_books_my_book_submission_path(submission), as: :turbo_stream, headers: {"HOST" => @host}
      assert_response :success
    end

    readers.each do |user, list, submission|
      sign_in_as user, stub_auth: true
      dismiss.call(submission)
      strip(list)
      refute_includes response.body, "Dismissed Then Doomed"
    end

    sign_in_as users(:admin_user), stub_auth: true
    post reject_admin_books_book_submission_path(first), params: {note: "not a real book", dry_run: "false"}, headers: {"HOST" => @host}
    assert_not ::Books::Book.exists?(book.id)

    readers.each do |user, list, submission|
      sign_in_as user, stub_auth: true
      strip(list)
      assert_response :success
      assert_includes response.body, removed
      dismiss.call(submission)
      refute_includes response.body, removed
      2.times do
        strip(list)
        refute_includes response.body, removed
      end
    end
  end

  test "a book deleted while its request was in progress shows the removed copy, stops polling and offers no Cancel" do
    book = ::Books::Book.create!(title: "Deleted In Flight", provisional: true)
    submission = row(status: :looking_up, book: book, created_book: true, review_status: :pending, resolved_title: "Deleted In Flight")
    ::Books::PurgeShowPagesJob.stubs(:perform_async)

    book.destroy!
    sign_in_as @user, stub_auth: true
    strip

    assert_response :success
    assert_equal %w[cancelled rejected], [submission.reload.status, submission.review_status]
    assert_includes response.body, "We couldn&#39;t verify &quot;Deleted In Flight&quot;, so it was removed."
    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert_nil doc.at_css("[data-testid=book-submissions-state]")["data-in-progress"]
    assert_not_includes response.body, cancel_books_my_book_submission_path(submission)
  end

  test "a signed-out frame request gets an empty strip frame and a 401, never a redirect" do
    strip(headers: frame_headers)

    assert_response :unauthorized
    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert doc.at_css("turbo-frame#book_submissions")
    assert_nil doc.at_css("[data-testid=book-submissions-state]")
    assert_equal "", doc.at_css("turbo-frame#book_submissions").text.strip
  end

  test "a frame request for a list that is not the reader's gets an empty frame and a 404, not the not-found page" do
    sign_in_as @user, stub_auth: true

    strip(user_lists(:regular_user_music_albums_favorites), headers: frame_headers)

    assert_response :not_found
    doc = Nokogiri::HTML::DocumentFragment.parse(response.body)
    assert doc.at_css("turbo-frame#book_submissions")
    assert_nil doc.at_css("html")
    assert_equal "", doc.at_css("turbo-frame#book_submissions").text.strip
  end

  test "a frame request for another frame's id is still handled as a normal request" do
    strip(headers: {"Turbo-Frame" => "list_items"})

    assert_response :redirect
  end
end
