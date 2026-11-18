# frozen_string_literal: true

module Services
  module Books
    module QueueTypes
      # Ledger rows for the fact types (books.book_facts, books.author_facts)
      # keep one entry per fact, every one shaped {"value", "applied", "reason"}.
      # The non-fact keys a queue apply adds (context, queue_request_id) take
      # that same shape so a reader of the ledger never meets a bare scalar.
      module LedgerEntries
        def self.input(value)
          {"value" => value, "applied" => false, "reason" => "input"}
        end

        def self.for_request(request, context:)
          {"context" => input(context), "queue_request_id" => input(request.id)}
        end
      end
    end
  end
end
