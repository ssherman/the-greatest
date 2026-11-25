# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # When a submission's lookup tries again, shared by the process job's
      # service and the Goodreads fetch job so the two cannot drift.
      #
      # A retry is for a source that is down: it backs off from 30 seconds,
      # doubling to a cap of 10 minutes, until the retry window (counted from
      # processing_started_at) has passed. Waiting for the Goodreads gate is not
      # a failure and must not use that window up, so wait_until moves
      # processing_started_at to the time the wait ends.
      module RetrySchedule
        FIRST_DELAY = 30
        MAX_DELAY = 600

        module_function

        # Schedules the next attempt and returns its time, or nil when the
        # window has passed (the caller then gives up).
        def retry_later(submission)
          return nil unless window_open?(submission)

          attempts = submission.attempts + 1
          at = Time.current + [FIRST_DELAY * (2**[attempts - 1, 10].min), MAX_DELAY].min
          submission.update!(attempts: attempts, next_attempt_at: at, status: :looking_up)
          at
        end

        # The submission waits for the gate until `at`, and its window starts
        # again there.
        def wait_until(submission, at)
          submission.update!(next_attempt_at: at, processing_started_at: at, status: :looking_up)
        end

        def window_open?(submission)
          started = submission.processing_started_at || Time.current
          Time.current < started + Rails.application.config.x.book_submissions.retry_window
        end
      end
    end
  end
end
