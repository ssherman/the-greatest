# frozen_string_literal: true

# Safety net for the submission jobs: a process job lost to a deploy or a
# Redis flush leaves a queued or looking-up row that nothing will touch.
#
# A row is stuck when it has sat for 30 minutes and no attempt is due or
# recently due: next_attempt_at is nil or at least 30 minutes old. A row held
# by the Goodreads gate has a next_attempt_at at or near now (a spent cap
# reopens at 00:00:00 UTC, the very minute the cron fires), and its fetch job
# is still on its way, so it is left alone. A stuck row is queued again and
# touched; each requeue is counted in `sweeps`, and a row still stuck after
# MAX_SWEEPS requeues is failed as a lost job, so a submission that kills its
# worker does not run paid lookups forever. Running a submission twice is safe
# (ProcessSubmission resumes).
class Books::RequeueStuckBookSubmissionsJob
  include Sidekiq::Job

  sidekiq_options queue: :low

  IDLE_FOR = 30.minutes
  MAX_SWEEPS = 3

  def perform
    stuck.find_each do |submission|
      if submission.sweeps >= MAX_SWEEPS
        lose(submission)
      elsif requeue(submission)
        ::Books::ProcessBookSubmissionJob.perform_async(submission.id)
      end
    end
  end

  private

  def stuck
    cutoff = IDLE_FOR.ago
    ::Books::BookSubmission.where(status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
      .where.not(review_status: :rejected)
      .where(updated_at: ...cutoff)
      .where("next_attempt_at IS NULL OR next_attempt_at <= ?", cutoff)
  end

  # Both writes re-check that the row is still stuck, so a row that finished
  # since the query is left alone.
  def requeue(submission)
    stuck.where(id: submission.id).update_all(["sweeps = sweeps + 1, updated_at = ?", Time.current]).positive?
  end

  def lose(submission)
    stuck.where(id: submission.id).update_all(status: :failed, error: "lost job", updated_at: Time.current)
    ::Services::Books::BookSubmissions::ProcessSubmission.clear_flags(submission.id)
    Rails.logger.error "Books::BookSubmission #{submission.id} failed: lost job (swept #{MAX_SWEEPS} times without finishing)"
  end
end
