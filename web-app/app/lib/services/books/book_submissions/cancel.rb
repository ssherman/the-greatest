# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Cancels one of the reader's own submissions that has no book yet. One
      # conditional write, so a lookup finishing at the same moment either wins
      # (nothing is cancelled) or loses (the job stops quietly on a cancelled
      # row). Zero rows changed means refused. A cancelled submission's match
      # decision leaves the review queue.
      #
      # `statuses` and `list` let Submit use the same write to replace a
      # needs_details or failed request.
      class Cancel
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        REFUSED = "That request can no longer be cancelled"

        def self.call(user:, id:, statuses: ::Books::BookSubmission::OPEN_STATUSES, list: nil)
          scope = ::Books::BookSubmission.where(id: id, user_id: user.id, status: statuses, book_id: nil)
          scope = scope.where(user_list_id: list.id) if list
          return Result.new(success?: false, data: nil, errors: [REFUSED]) if scope.update_all(status: :cancelled, updated_at: Time.current).zero?

          ProcessSubmission.clear_flags(id)
          Result.new(success?: true, data: nil, errors: [])
        end
      end
    end
  end
end
