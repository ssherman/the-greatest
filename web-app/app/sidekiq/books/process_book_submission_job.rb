# frozen_string_literal: true

# Takes one reader's book submission to a book on their list
# (Services::Books::BookSubmissions::ProcessSubmission). Each run is one pass;
# a retry for a source that is down, or the wait for a Goodreads page, is
# scheduled by the service's answer and never slept on. An unexpected error is
# raised for Sidekiq to retry, and the submission fails only when the last
# retry does.
class Books::ProcessBookSubmissionJob
  include Sidekiq::Job

  sidekiq_options queue: :critical, retry: 3

  sidekiq_retries_exhausted do |job, exception|
    ::Services::Books::BookSubmissions::ProcessSubmission.record_unexpected_failure(job["args"].first, exception)
  end

  def perform(submission_id)
    submission = ::Books::BookSubmission.find_by(id: submission_id)
    return if submission.nil?

    result = ::Services::Books::BookSubmissions::ProcessSubmission.call(submission: submission)
    case result.data[:outcome]
    when :retry then self.class.perform_at(result.data[:retry_at], submission_id)
    when :waiting_for_goodreads then ::Books::FetchSubmissionGoodreadsPageJob.perform_async(submission_id)
    end
  end
end
