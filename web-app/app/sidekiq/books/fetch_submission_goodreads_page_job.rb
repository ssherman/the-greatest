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
# down) is tried again through a new turn within the window. An error after
# the turn was taken is a different thing (see `raised`): three of them fail
# the submission. A page that
# loaded but cannot be read needs details from the reader.
class Books::FetchSubmissionGoodreadsPageJob
  include Sidekiq::Job

  sidekiq_options queue: :goodreads_fetch_priority, retry: 3

  # With no reopening time to read (the gate answered nothing useful) the job
  # looks again in this long.
  UNKNOWN_REOPEN = 10.minutes
  MAX_BLOCKED_FETCHES = 2
  MAX_RAISES = 3
  RAISE_DELAY = 1.minute

  sidekiq_retries_exhausted do |job, exception|
    ::Services::Books::BookSubmissions::ProcessSubmission.record_unexpected_failure(job["args"].first, exception)
  end

  # raises: how many times the work after the turn has raised for this
  # submission, carried through the reschedules.
  def perform(submission_id, due = false, raises = 0)
    submission = ::Books::BookSubmission.find_by(id: submission_id)
    return unless submission&.in_progress? && submission.method_goodreads?
    return process_later(submission) if submission.book_id || page_cached?(submission)

    turn = ::Books::Goodreads::GateTurn.call(gate: gate, due: due, priority: true)
    case turn.action
    when :refused then return reschedule_at(submission, reopening)
    when :wait then return wait_for_turn(submission, turn.wait)
    end

    # From here the turn is spent. Anything that raises (the fetch, after_fetch,
    # the outcome handling) must not come back through Sidekiq's retry, which
    # would run as `due`, skip the gate and fetch again without a turn.
    begin
      handle(submission, fetch(submission))
    rescue => error
      raised(submission, error, raises + 1)
    end
  end

  private

  def gate = (@gate ||= ::Books::Goodreads::FetchGate.new)

  def fetch(submission)
    outcome = ::Services::Books::GoodreadsPages::FetchPage.call(goodreads_book_id: submission.goodreads_book_id).data[:outcome]
    ::Books::Goodreads::GateTurn.after_fetch(gate: gate, outcome: outcome)
    outcome
  end

  def handle(submission, outcome)
    case outcome
    when :found, :not_found then process_later(submission)
    when :blocked then blocked(submission)
    when :unparseable then needs_details(submission)
    else retry_later(submission)
    end
  end

  # An error is a bug or a failing store, not a source that is down: the job
  # tries again through a new turn a minute later, and the third error fails
  # the submission with the error stored. If this method's own write or
  # reschedule raises, it propagates to Sidekiq: Redis or Postgres is down, and
  # the gate's spacing and daily start cap still hold for a retry.
  def raised(submission, error, count)
    Rails.logger.error "Books::FetchSubmissionGoodreadsPageJob: submission #{submission.id} raised #{error.class}: #{error.message} (#{count} of #{MAX_RAISES})"
    return ::Services::Books::BookSubmissions::ProcessSubmission.record_unexpected_failure(submission.id, error) if count >= MAX_RAISES

    at = RAISE_DELAY.from_now
    written = ::Services::Books::BookSubmissions::Settle.call(submission, next_attempt_at: at, status: :looking_up)
    self.class.perform_at(at, submission.id, false, count) if written.positive?
  end

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
