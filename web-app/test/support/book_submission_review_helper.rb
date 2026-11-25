# frozen_string_literal: true

# Builders for the review service tests: a provisional book a reader asked
# for, its submission, and a lease held by an agent.
module BookSubmissionReviewHelper
  TOKEN = "lease-token-1"

  def stub_review_side_effects
    stub_workflow_dispatch
    ::Books::PurgeShowPagesJob.stubs(:perform_async)
    ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
    ::GenerateUserFavoritesListsJob.stubs(:perform_async)
    ::Books::ProcessBookSubmissionJob.stubs(:perform_async)
  end

  def serial
    @serial = (@serial || 0) + 1
  end

  # A provisional book with one provisional author, and the submission that
  # created it (pending review, on the reader's Read list).
  def reviewable_submission(user: users(:regular_user), title: nil, review_status: :pending, status: :added, book: :new, **attributes)
    n = serial
    if book == :new
      book = ::Books::Book.create!(title: title || "Reviewable Book #{n}", provisional: true)
      author = ::Books::Author.create!(name: "Reviewable Author #{n}", provisional: true)
      ::Books::BookAuthor.create!(book: book, author: author, position: 1)
    end
    ::Books::BookSubmission.create!({
      user: user, user_list: user_lists(:regular_user_books_read), input_method: :goodreads,
      goodreads_book_id: 7_000_000 + n, fingerprint: SecureRandom.hex(4), status: status,
      review_status: review_status, created_book: true, book: book
    }.merge(attributes))
  end

  def lease(submission, token: TOKEN, expires_at: 30.minutes.from_now, by: users(:admin_user))
    submission.update_columns(lease_token: token, lease_expires_at: expires_at, claimed_by_id: by.id)
    submission
  end

  def fresh(submission) = ::Books::BookSubmission.find(submission.id)

  def assert_failure(result, code, fragment = nil)
    assert_not result.success?, "expected a failure"
    assert_equal code, result.errors.first[:code], result.errors.inspect
    assert_includes result.errors.first[:detail], fragment if fragment
  end

  def assert_success(result)
    assert result.success?, result.errors.inspect
  end
end
