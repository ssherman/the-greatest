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
      # a failure and must not use that window up, so wait_until shifts
      # processing_started_at by the length of the wait. It must shift, not
      # restart: a page that always answers 503 would otherwise get a fresh
      # window at every turn of a long backlog and never end.
      #
      # Both write through Settle, so a closed row is left alone.
      module RetrySchedule
        FIRST_DELAY = 30
        MAX_DELAY = 600

        module_function

        # Schedules the next attempt and returns its time; nil when the window
        # has passed (the caller gives up); :closed when the row is no longer
        # open (the caller stops).
        def retry_later(submission)
          return nil unless window_open?(submission)

          attempts = submission.attempts + 1
          at = Time.current + [FIRST_DELAY * (2**[attempts - 1, 10].min), MAX_DELAY].min
          written = Settle.call(submission, attempts: attempts, next_attempt_at: at, status: :looking_up)
          written.zero? ? :closed : at
        end

        # The submission waits for the gate until `at`; the window is pushed
        # back by the wait, so the time left is what it was. Extra columns are
        # written in the same statement. Returns the rows changed.
        def wait_until(submission, at, **extra)
          started = (submission.processing_started_at || Time.current) + (at - Time.current)
          Settle.call(submission, next_attempt_at: at, processing_started_at: started, status: :looking_up, **extra)
        end

        def window_open?(submission)
          started = submission.processing_started_at || Time.current
          Time.current < started + Rails.application.config.x.book_submissions.retry_window
        end
      end
    end
  end
end
