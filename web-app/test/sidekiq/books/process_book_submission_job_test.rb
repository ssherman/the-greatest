require "test_helper"

class Books::ProcessBookSubmissionJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper
  include BookSubmissionHelper

  setup do
    stub_resolution_services
    freeze_time
    # Sidekiq runs inline in tests: a job that reschedules itself would run again at once.
    Books::ProcessBookSubmissionJob.stubs(:perform_at)
    Books::FetchSubmissionGoodreadsPageJob.stubs(:perform_async)
  end

  def perform(submission) = Books::ProcessBookSubmissionJob.new.perform(submission.id)

  test "runs on the critical queue with three retries" do
    options = Books::ProcessBookSubmissionJob.get_sidekiq_options

    assert_equal ["critical", 3], [options["queue"].to_s, options["retry"]]
  end

  test "processes the submission" do
    submission = book_submission

    perform(submission)

    assert_equal "added", submission.reload.status
  end

  test "a submission that no longer exists is ignored" do
    assert_nothing_raised { Books::ProcessBookSubmissionJob.new.perform(0) }
  end

  test "a retry is scheduled for the time the service chose" do
    submission = book_submission
    stub_finder(finder_match(subject: submission, decided_by: :fallback))
    Books::ProcessBookSubmissionJob.expects(:perform_at).with(30.seconds.from_now, submission.id)

    perform(submission)

    assert_equal 30.seconds.from_now, submission.reload.next_attempt_at
  end

  test "a submission waiting for its Goodreads page queues the fetch job on the priority lane" do
    submission = book_submission(input_method: :goodreads, raw_input: "https://www.goodreads.com/book/show/5107",
      goodreads_book_id: 5107, typed_title: nil, typed_author_names: nil)
    Books::FetchSubmissionGoodreadsPageJob.expects(:perform_async).with(submission.id)

    perform(submission)
  end

  test "a finished submission queues nothing" do
    submission = book_submission(status: :cancelled)
    Books::ProcessBookSubmissionJob.expects(:perform_at).never
    Books::FetchSubmissionGoodreadsPageJob.expects(:perform_async).never

    perform(submission)
  end

  test "an unexpected error is raised for Sidekiq to retry, not turned into a failure at once" do
    submission = book_submission
    Services::Books::BookSubmissions::ProcessSubmission.stubs(:call).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { perform(submission) }

    assert_equal "queued", submission.reload.status
  end

  test "once the retries are used up the submission fails with the error's class and scrubbed message, and it is logged" do
    submission = book_submission(status: :looking_up)
    error = RuntimeError.new("lost \xFF connection\x00 here".b)
    Rails.logger.expects(:error).with(regexp_matches(/RuntimeError/)).at_least_once

    Books::ProcessBookSubmissionJob.sidekiq_retries_exhausted_block.call({"args" => [submission.id]}, error)

    submission.reload
    assert_equal "failed", submission.status
    assert_includes submission.error, "RuntimeError"
    assert_includes submission.error, "lost  connection here"
  end

  test "once the retries are used up the submission's flagged decisions leave the review queue" do
    submission = book_submission(status: :looking_up)
    flagged = finder_match(subject: submission, needs_review: true).decision

    Books::ProcessBookSubmissionJob.sidekiq_retries_exhausted_block.call({"args" => [submission.id]}, RuntimeError.new("x"))

    assert_not flagged.reload.needs_review?
  end

  test "retries running out never overwrite a submission that has finished" do
    submission = book_submission(status: :added)

    Books::ProcessBookSubmissionJob.sidekiq_retries_exhausted_block.call({"args" => [submission.id]}, RuntimeError.new("late"))

    assert_equal ["added", nil], [submission.reload.status, submission.error]
  end
end
