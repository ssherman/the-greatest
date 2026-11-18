# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # Row counts for one kind: every status (zeros included, in the enum's
    # order) and the outcomes of the done rows.
    class Counts
      def self.call(kind:)
        rows = ::EnrichmentRequest.for_kind(kind)
        by_status = rows.group(:status).count
        {
          statuses: ::EnrichmentRequest.statuses.keys.index_with { |status| by_status.fetch(status, 0) },
          outcomes: rows.done.where.not(outcome: nil).group(:outcome).count
        }
      end
    end
  end
end
