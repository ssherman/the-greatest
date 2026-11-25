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
    assert_equal [15.seconds.from_now, 2.hours.ago + 15.seconds], [@submission.next_attempt_at, @submission.processing_started_at],
      "the window is pushed back by the wait; the time left is what it was"
  end

  test "a gate wait with no start time yet still leaves a window" do
    @submission.update_columns(processing_started_at: nil)
    @gate.reserve(priority: true)
    JOB.expects(:perform_in).with(15, @submission.id, true)

    perform

    assert_equal 15.seconds.from_now, @submission.reload.processing_started_at
  end

  test "a refusal does not reschedule a row cancelled while the gate was asked" do
    @gate.stubs(:reserve).with { |**|
      ::Books::BookSubmission.where(id: @submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])
      true
    }.returns(Books::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
    JOB.expects(:perform_at).never

    perform

    assert_equal "cancelled", @submission.reload.status
  end

  test "a cancel during the fetch is not overwritten, and nothing is rescheduled" do
    FETCH.stubs(:call).with { |**|
      ::Books::BookSubmission.where(id: @submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])
      true
    }.returns(fetched(:unparseable))
    JOB.expects(:perform_at).never

    perform

    assert_equal "cancelled", @submission.reload.status
  end

  test "a cancel during the fetch is not overwritten by a retry either" do
    FETCH.stubs(:call).with { |**|
      ::Books::BookSubmission.where(id: @submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])
      true
    }.returns(fetched(:unavailable))
    JOB.expects(:perform_at).never

    perform

    assert_equal ["cancelled", 0], [@submission.reload.status, @submission.attempts]
  end

  test "a page that always answers 503 ends even while the gate keeps making the job wait" do
    # Each pass: a gate wait of ten minutes, then a 503 and its backoff. The
    # waits push the window back, but only by their own length.
    FETCH.stubs(:call).returns(fetched(:unavailable))
    passes = 0
    until @submission.reload.needs_details? || passes > 60
      passes += 1
      Services::Books::BookSubmissions::RetrySchedule.wait_until(@submission, 10.minutes.from_now)
      travel 10.minutes
      perform(true)
      next if @submission.reload.needs_details?

      travel_to @submission.next_attempt_at
    end

    assert @submission.reload.needs_details?, "still looking up after #{passes} passes"
    assert_operator passes, :<=, 12
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

  def cancel_row = ::Books::BookSubmission.where(id: @submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])

  test "an error after the turn reschedules a minute later, not due, with the raise counted, and the sweep leaves the row alone" do
    FETCH.stubs(:call).raises(RuntimeError, "boom")
    Rails.logger.expects(:error).with(regexp_matches(/RuntimeError: boom/)).at_least_once
    JOB.expects(:perform_at).with(1.minute.from_now, @submission.id, false)

    assert_nothing_raised { perform(true) }

    @submission.reload
    assert_equal ["looking_up", 1.minute.from_now, 0, 1], [@submission.status, @submission.next_attempt_at, @submission.attempts, @submission.fetch_errors]
  end

  test "the rescheduled job takes a fresh reservation before it fetches again" do
    FETCH.stubs(:call).raises(RuntimeError, "boom").then.returns(fetched(:found))
    @gate.stubs(:spacing_wait).returns(0)
    perform(true)
    @gate.expects(:reserve).with(priority: true).once.returns(Books::FetchGate::Reservation.new(wait: 0, refusal: nil))

    JOB.new.perform(@submission.id, false)
  end

  test "an unparseable page whose write raises is rescheduled through a new turn, not retried as due" do
    FETCH.stubs(:call).returns(fetched(:unparseable))
    Services::Books::BookSubmissions::Settle.stubs(:call).raises(RuntimeError, "write failed").then.returns(1)
    JOB.expects(:perform_at).with(1.minute.from_now, @submission.id, false)

    perform(true)
    Services::Books::BookSubmissions::Settle.unstub(:call)
    @gate.expects(:reserve).with(priority: true).once.returns(Books::FetchGate::Reservation.new(wait: 0, refusal: nil))
    @gate.stubs(:spacing_wait).returns(0)
    JOB.new.perform(@submission.id, false)
  end

  test "an unavailable page whose reschedule raises is rescheduled through a new turn, not retried as due" do
    FETCH.stubs(:call).returns(fetched(:unavailable))
    JOB.stubs(:perform_at).raises(RuntimeError, "redis blip").then.returns(nil)

    perform(true)

    assert_equal ["looking_up", 1.minute.from_now], [@submission.reload.status, @submission.next_attempt_at]
  end

  test "an error in the rescue's own write propagates to Sidekiq and schedules nothing" do
    FETCH.stubs(:call).raises(RuntimeError, "boom")
    Services::Books::BookSubmissions::Settle.stubs(:call).raises(ActiveRecord::StatementInvalid, "db down")
    JOB.expects(:perform_at).never

    assert_raises(ActiveRecord::StatementInvalid) { perform(true) }
  end

  test "a fetch that always raises is tried three times, then fails the submission with the error, logged, and schedules nothing" do
    FETCH.expects(:call).times(3).raises(RuntimeError, "boom")
    Rails.logger.expects(:error).with(regexp_matches(/RuntimeError: boom/)).at_least_once
    scheduled = []
    JOB.stubs(:perform_at).with { |*args|
      scheduled << args
      true
    }
    args = [@submission.id, true]

    loop do
      JOB.new.perform(*args)
      break if scheduled.empty?

      _at, *args = scheduled.shift
      travel 1.minute
    end

    @submission.reload
    assert_equal "failed", @submission.status
    assert_includes @submission.error, "RuntimeError: boom"
    assert_empty scheduled
  end

  test "a cancel committed during a raising fetch stays cancelled and schedules nothing" do
    FETCH.stubs(:call).with { |**|
      cancel_row
      true
    }.raises(RuntimeError, "boom")
    JOB.expects(:perform_at).never

    perform(true)

    assert_equal ["cancelled", 0], [@submission.reload.status, @submission.fetch_errors], "a closed row is not counted"
  end

  test "a cancel committed during the third raising fetch is not failed over" do
    FETCH.stubs(:call).with { |**|
      cancel_row
      true
    }.raises(RuntimeError, "boom")

    @submission.update!(fetch_errors: 2)
    JOB.new.perform(@submission.id, false)

    assert_equal ["cancelled", nil], [@submission.reload.status, @submission.error]
  end

  # Runs the jobs the job under test schedules, in time order, on the real gate,
  # until nothing is left. Returns how many ran.
  def drive(ids, limit: 600)
    queue = ids.map { |id| [Time.current, id, false] }
    JOB.stubs(:perform_at).with { |at, id, due|
      queue << [at, id, due]
      true
    }
    JOB.stubs(:perform_in).with { |wait, id, due|
      queue << [Time.current + wait, id, due]
      true
    }
    runs = 0
    until queue.empty? || runs >= limit
      at, id, due = queue.min_by(&:first).tap { |entry| queue.delete(entry) }
      travel_to at if at > Time.current
      JOB.new.perform(id, due)
      runs += 1
    end
    runs
  end

  test "a busy line and a fetch that always raises end failed after exactly three fetches" do
    3.times { @gate.reserve(priority: true) }
    FETCH.expects(:call).times(3).raises(RuntimeError, "boom")

    drive([@submission.id])

    @submission.reload
    assert_equal ["failed", 3], [@submission.status, @submission.fetch_errors]
    assert_includes @submission.error, "RuntimeError: boom"
  end

  test "eight submissions whose fetch always raises all end after exactly 24 fetches" do
    others = Array.new(7) do |index|
      book_submission(input_method: :goodreads, raw_input: "x", goodreads_book_id: 6000 + index, typed_title: nil,
        typed_author_names: nil, status: :looking_up, processing_started_at: Time.current)
    end
    all = [@submission, *others]
    FETCH.expects(:call).times(24).raises(RuntimeError, "boom")

    drive(all.map(&:id))

    assert_equal ["failed"], all.map { |row| row.reload.status }.uniq
  end

  test "raises alternating with an unavailable page end failed at the third raise with the error stored" do
    FETCH.expects(:call).times(5)
      .raises(RuntimeError, "boom").then.returns(fetched(:unavailable))
      .then.raises(RuntimeError, "boom").then.returns(fetched(:unavailable))
      .then.raises(RuntimeError, "boom")

    drive([@submission.id])

    @submission.reload
    assert_equal ["failed", 3], [@submission.status, @submission.fetch_errors]
    assert_includes @submission.error, "RuntimeError: boom"
  end

  test "a raise, then a block refusal, then raises still ends at three" do
    calls = 0
    FETCH.expects(:call).times(3).with { |**|
      calls += 1
      @gate.block! if calls == 1
      true
    }.raises(RuntimeError, "boom")

    drive([@submission.id])

    @submission.reload
    assert_equal ["failed", 3], [@submission.status, @submission.fetch_errors]
  end

  test "a book that lands during the third raising fetch leaves the row alone" do
    @submission.update!(fetch_errors: 2)
    book = books_books(:war_and_peace)
    FETCH.stubs(:call).with { |**|
      ::Books::BookSubmission.where(id: @submission.id).update_all(book_id: book.id)
      true
    }.raises(RuntimeError, "boom")
    JOB.expects(:perform_at).never

    perform(true)

    @submission.reload
    assert_equal ["looking_up", book.id, nil, 2], [@submission.status, @submission.book_id, @submission.error, @submission.fetch_errors]
  end

  test "a book that lands between the third error being counted and the failure being written is not failed over" do
    @submission.update!(fetch_errors: 2)
    book = books_books(:war_and_peace)
    FETCH.stubs(:call).raises(RuntimeError, "boom")
    Services::Books::BookSubmissions::ProcessSubmission.stubs(:failure_message).with { |_error|
      ::Books::BookSubmission.where(id: @submission.id).update_all(book_id: book.id)
      true
    }.returns("RuntimeError: boom")

    perform(true)

    @submission.reload
    assert_equal ["looking_up", book.id, nil], [@submission.status, @submission.book_id, @submission.error]
  end

  test "the first blocked fetch is counted and waits for the gate; the second needs details and holds nothing" do
    FETCH.stubs(:call).returns(fetched(:blocked))
    JOB.expects(:perform_at).with(6.hours.from_now, @submission.id, false).once

    perform
    assert_equal [1, "looking_up"], [@submission.reload.blocked_fetches, @submission.status]

    travel 7.hours
    perform

    @submission.reload
    assert_equal [1, "needs_details"], [@submission.blocked_fetches, @submission.status]
  end

  test "refusals that never fetched are not counted and wait without limit" do
    @gate.stubs(:reserve).returns(Books::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
    @gate.stubs(:reopens_at).returns(1.hour.from_now)
    JOB.stubs(:perform_at)

    3.times { perform }

    assert_equal [0, "looking_up"], [@submission.reload.blocked_fetches, @submission.status]
  end

  test "once the retries are used up the submission fails with the error recorded" do
    JOB.sidekiq_retries_exhausted_block.call({"args" => [@submission.id, false]}, RuntimeError.new("gone"))

    @submission.reload
    assert_equal "failed", @submission.status
    assert_includes @submission.error, "RuntimeError: gone"
  end
end
