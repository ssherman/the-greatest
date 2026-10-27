# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # The enrichment ledger row for a Goodreads attempt that did not apply
      # (a match is recorded by Apply). A plan-time skip and a final failure
      # live on the workflow step instead, never here.
      module Ledger
        KIND = "books.goodreads"
        PROVIDER = "goodreads"

        module_function

        def record(book:, outcome:, reason: nil, facts: {}, error: nil)
          book.enrichments.create!(kind: KIND, provider: PROVIDER, outcome: outcome, reason: reason&.to_s, facts: facts, error: error)
        end
      end
    end
  end
end
