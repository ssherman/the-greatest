# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # The one way a job ends or reschedules a submission that has no book yet.
      # The write is conditional on the row still being open (queued or looking
      # up) with no book, so a reader's cancel, a second job's finish or an
      # earlier run's book is never overwritten by a status this run read before
      # its slow external calls. It returns how many rows it changed; zero means
      # the row is closed and the caller stops quietly.
      module Settle
        module_function

        def call(submission, **attributes)
          ::Books::BookSubmission
            .where(id: submission.id, status: ::Books::BookSubmission::IN_PROGRESS_STATUSES, book_id: nil)
            .update_all(attributes.merge(updated_at: Time.current))
        end
      end
    end
  end
end
