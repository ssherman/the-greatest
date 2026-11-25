require "test_helper"

class Books::FetchSubmissionGoodreadsPageJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper
  include BookSubmissionHelper

  FETCH = Services::Books::GoodreadsPages::FetchPage
  JOB = Books::FetchSubmissionGoodreadsPageJob

  # CI has no Redis: the gate runs on FakeRedis, with the clock frozen. Sidekiq
  # runs inline in tests, so every job this one queues or reschedules is stubbed.
  setup do
    freeze_time
    config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 1_500, block_cooldown: 6.hours.to_i,
      priority_reserved: 100)
    @gate = Books::Goodreads::FetchGate.new(redis: Books::OpenLibrary::FakeRedis.new, config: config)
    Books::Goodreads::FetchGate.stubs(:new).returns(@gate)
    Books::ProcessBookSubmissionJob.stubs(:perform_async)
    JOB.stubs(:perform_in)
    JOB.stubs(:perform_at)
    @window = Rails.application.config.x.book_submissions.retry_window
    @submission = book_submission(input_method: :goodreads, raw_input: "https://www.goodreads.com/book/show/5107",
      goodreads_book_id: 5107, typed_title: nil, typed_author_names: nil, status: :looking_up, processing_started_at: Time.current)
  end

  def fetched(outcome)
    FETCH::Result.new(success?: true, data: {outcome: outcome, page: nil}, errors: [])
  end

  def perform(due = false) = JOB.new.perform(@submission.id, due)

  test "runs on the priority Goodreads fetch queue with three retries" do
    options = JOB.get_sidekiq_options

    assert_equal ["goodreads_fetch_priority", 3], [options["queue"].to_s, options["retry"]]
  end

  test "takes one priority turn, fetches, and queues the process job for a found page" do
    @gate.expects(:reserve).with(priority: true).once.returns(Books::FetchGate::Reservation.new(wait: 0, refusal: nil))
    FETCH.expects(:call).with(goodreads_book_id: 5107).once.returns(fetched(:found))
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(@submission.id)

    perform
  end

  test "a page Goodreads has no record of is an answer too" do
    FETCH.expects(:call).returns(fetched(:not_found))
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(@submission.id)

    perform
  end

  test "a job on its turn fetches without taking another" do
    @gate.expects(:reserve).never
    FETCH.expects(:call).once.returns(fetched(:found))
    JOB.expects(:perform_in).never

    perform(true)
  end

  test "a page already answered is not fetched and the process job is queued" do
    goodreads_page(goodreads_book_id: 5107)
    FETCH.expects(:call).never
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(@submission.id)

    perform
  end

  test "a submission that no longer needs the page is left alone" do
    FETCH.expects(:call).never
    Books::ProcessBookSubmissionJob.expects(:perform_async).never
    cancelled = book_submission(input_method: :goodreads, raw_input: "x", goodreads_book_id: 5108, typed_title: nil,
      typed_author_names: nil, status: :cancelled)

    JOB.new.perform(cancelled.id)
    JOB.new.perform(0)
  end

  test "a submission that already has its book goes straight to the process job, which resumes it" do
    @submission.update!(book: books_books(:war_and_peace))
    FETCH.expects(:call).never
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(@submission.id)

    perform
  end

  test "a busy line reschedules for the turn, due, and the wait does not use up the retry window" do
    @submission.update!(processing_started_at: 2.hours.ago)
    @gate.reserve(priority: true)
    FETCH.expects(:call).never
    JOB.expects(:perform_in).with(15, @submission.id, true)

    perform

    @submission.reload
    assert_equal [15.seconds.from_now, 15.seconds.from_now], [@submission.next_attempt_at, @submission.processing_started_at]
  end

  test "a refusal reschedules at the gate's reopening time" do
    @gate.stubs(:reserve).returns(Books::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
    @gate.stubs(:reopens_at).with(priority: true).returns(3.hours.from_now)
    FETCH.expects(:call).never
    JOB.expects(:perform_at).with(3.hours.from_now, @submission.id, false)

    perform

    @submission.reload
    assert_equal [3.hours.from_now, 3.hours.from_now], [@submission.next_attempt_at, @submission.processing_started_at]
  end

  test "a refusal with no reopening time reschedules in ten minutes" do
    @gate.stubs(:reserve).returns(Books::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
    @gate.stubs(:reopens_at).returns(nil)
    JOB.expects(:perform_at).with(10.minutes.from_now, @submission.id, false)

    perform

    assert_equal 10.minutes.from_now, @submission.reload.next_attempt_at
  end

  test "a block seen after the fetch reschedules at the end of the block" do
    FETCH.expects(:call).returns(fetched(:blocked))
    JOB.expects(:perform_at).with(6.hours.from_now, @submission.id, false)
    Books::ProcessBookSubmissionJob.expects(:perform_async).never

    perform

    assert @gate.blocked?
    @submission.reload
    assert_equal [6.hours.from_now, 6.hours.from_now], [@submission.next_attempt_at, @submission.processing_started_at]
  end

  test "an unparseable page needs details" do
    FETCH.expects(:call).returns(fetched(:unparseable))
    Books::ProcessBookSubmissionJob.expects(:perform_async).never

    perform

    assert_equal "needs_details", @submission.reload.status
  end

  test "an unavailable page or a fetcher that is down retries through a new turn, within the window" do
    FETCH.stubs(:call).returns(fetched(:unavailable)).then.returns(fetched(:fetcher_down))
    JOB.expects(:perform_at).with(30.seconds.from_now, @submission.id, false)

    perform
    @submission.reload
    assert_equal [1, "looking_up", 30.seconds.from_now], [@submission.attempts, @submission.status, @submission.next_attempt_at]

    travel 30.seconds
    JOB.expects(:perform_at).with(60.seconds.from_now, @submission.id, false)
    perform

    assert_equal 2, @submission.reload.attempts
  end

  test "an unavailable page after the window needs details" do
    @submission.update!(processing_started_at: Time.current - @window - 1.second)
    FETCH.expects(:call).returns(fetched(:unavailable))
    JOB.expects(:perform_at).never

    perform

    assert_equal "needs_details", @submission.reload.status
  end

  test "an unexpected error is raised for Sidekiq to retry" do
    FETCH.expects(:call).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { perform }

    assert_equal "looking_up", @submission.reload.status
  end

  test "once the retries are used up the submission fails with the error recorded" do
    JOB.sidekiq_retries_exhausted_block.call({"args" => [@submission.id, false]}, RuntimeError.new("gone"))

    @submission.reload
    assert_equal "failed", @submission.status
    assert_includes @submission.error, "RuntimeError: gone"
  end
end
