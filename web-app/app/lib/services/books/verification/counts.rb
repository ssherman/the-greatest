# frozen_string_literal: true

module Services
  module Books
    module Verification
      # The report's counters on the row, recounted from its findings.
      module Counts
        module_function

        def call(verification)
          kinds = verification.findings.group(:kind).count
          verification.update!(
            added_count: kinds.fetch("added", 0),
            confirmed_count: kinds.fetch("confirmed", 0),
            wrong_count: kinds.fetch("wrong_identifier", 0),
            candidate_count: ::Books::EditionCandidate.where(book_id: verification.book_id).count
          )
        end
      end
    end
  end
end
