# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Hides a finished submission from the reader's strip. An open one is
      # refused; dismissing twice keeps the first time and succeeds.
      class Dismiss
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        REFUSED = "That request is still in progress"

        def self.call(user:, id:)
          changed = ::Books::BookSubmission.where(id: id, user_id: user.id)
            .where.not(status: ::Books::BookSubmission::OPEN_STATUSES)
            .update_all(["dismissed_at = COALESCE(dismissed_at, ?), updated_at = ?", Time.current, Time.current])
          return Result.new(success?: false, data: nil, errors: [REFUSED]) if changed.zero?

          Result.new(success?: true, data: nil, errors: [])
        end
      end
    end
  end
end
