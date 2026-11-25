# frozen_string_literal: true

# Fetches the Goodreads page a reader's submission is waiting for, on the
# priority lane of the goodreads_fetch capsule (one job at a time, so the
# gate's pacing holds), then hands the submission back to the process job. The
# only caller of FetchPage besides Books::Goodreads::FetchPageJob.
#
# It first checks the submission still needs the page: open, no book yet, and
# no conclusive page cached. A job takes exactly one gate turn per fetch, a
# priority one (a reader passes the backlog), and reschedules itself for a
# wait, a refusal or a block instead of sleeping. Waiting for the gate does not
# use up the submission's retry window (RetrySchedule.wait_until). A page
# nobody could answer (Goodreads' error page, a timeout, a fetcher that is
# down, or anything that raised after the turn was taken) is tried again
# through a new turn within the window. A page that
# loaded but cannot be read needs details from the reader.
class Books::FetchSubmissionGoodreadsPageJob
  include Sidekiq::Job

  sidekiq_options queue: :goodreads_fetch_priority, retry: 3

  # With no reopening time to read (the gate answered nothing useful) the job
  # looks again in this long.
  UNKNOWN_REOPEN = 10.minutes
  MAX_BLOCKED_FETCHES = 2

  sidekiq_retries_exhausted do |job, exception|
    ::Services::Books::BookSubmissions::ProcessSubmission.record_unexpected_failure(job["args"].first, exception)
  end

  def perform(submission_id, due = false)
    submission = ::Books::BookSubmission.find_by(id: submission_id)
    return unless submission&.in_progress? && submission.method_goodreads?
    return process_later(submission) if submission.book_id || page_cached?(submission)

    turn = ::Books::Goodreads::GateTurn.call(gate: gate, due: due, priority: true)
    case turn.action
    when :refused then return reschedule_at(submission, reopening)
    when :wait then return wait_for_turn(submission, turn.wait)
    end

    begin
      outcome = ::Services::Books::GoodreadsPages::FetchPage.call(goodreads_book_id: submission.goodreads_book_id).data[:outcome]
      ::Books::Goodreads::GateTurn.after_fetch(gate: gate, outcome: outcome)
    rescue => error
      # The turn is spent: a Sidekiq retry would run as `due` and fetch again
      # without taking another, so the next try goes through a new turn.
      Rails.logger.warn "Books::FetchSubmissionGoodreadsPageJob: fetch for submission #{submission.id} raised #{error.class}: #{error.message}"
      return retry_later(submission)
    end
    case outcome
    when :found, :not_found then process_later(submission)
    when :blocked then blocked(submission)
    when :unparseable then needs_details(submission)
    else retry_later(submission)
    end
  end

  private

  def gate = (@gate ||= ::Books::Goodreads::FetchGate.new)

  def page_cached?(submission)
    ::Books::GoodreadsPage.conclusive.exists?(goodreads_book_id: submission.goodreads_book_id)
  end

  def process_later(submission)
    ::Books::ProcessBookSubmissionJob.perform_async(submission.id)
  end

  def reopening = gate.reopens_at(priority: true) || UNKNOWN_REOPEN.from_now

  # A second blocked fetch for one submission ends it: one reader-supplied
  # link must not hold the gate shut for everyone (each block stops every
  # fetch for the cooldown), as Steps::Goodreads#bad_fetch ends its step.
  def blocked(submission)
    count = submission.blocked_fetches + 1
    return needs_details(submission) if count >= MAX_BLOCKED_FETCHES

    reschedule_at(submission, reopening, blocked_fetches: count)
  end

  def reschedule_at(submission, time, **extra)
    return if ::Services::Books::BookSubmissions::RetrySchedule.wait_until(submission, time, **extra).zero?

    self.class.perform_at(time, submission.id, false)
  end

  def wait_for_turn(submission, seconds)
    return if ::Services::Books::BookSubmissions::RetrySchedule.wait_until(submission, seconds.seconds.from_now).zero?

    self.class.perform_in(seconds, submission.id, true)
  end

  def retry_later(submission)
    at = ::Services::Books::BookSubmissions::RetrySchedule.retry_later(submission)
    return if at == :closed
    return self.class.perform_at(at, submission.id, false) if at

    needs_details(submission)
  end

  def needs_details(submission)
    ::Services::Books::BookSubmissions::Settle.call(submission, status: :needs_details, next_attempt_at: nil)
  end
end
