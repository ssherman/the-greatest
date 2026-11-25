# frozen_string_literal: true

# Safety net for the submission jobs: a process job lost to a deploy or a
# Redis flush leaves a queued or looking-up row that nothing will touch. A row
# that has sat for 30 minutes with no attempt still to come is queued again.
# A row waiting on a future attempt (a backoff, a Goodreads turn) is left to
# its job, and a requeued row is touched so the next sweep leaves it to the job
# just queued. Running a submission twice is safe (ProcessSubmission resumes).
class Books::RequeueStuckBookSubmissionsJob
  include Sidekiq::Job

  sidekiq_options queue: :low

  IDLE_FOR = 30.minutes

  def perform
    ::Books::BookSubmission.where(status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
      .where(updated_at: ...IDLE_FOR.ago)
      .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
      .find_each do |submission|
        submission.touch
        ::Books::ProcessBookSubmissionJob.perform_async(submission.id)
      end
  end
end
