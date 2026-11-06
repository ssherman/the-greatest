# frozen_string_literal: true

# The Wikidata step of the author workflow (also its forced re-run after VIAF
# finds a QID). Fixed `refresh:` for the re-run; `refresh_from: :options` reads
# the run's "refresh" option for the chain's own first step.
#
# A service outcome of :failed is a business outcome (the ledger already holds
# the failed row), not an exception: the chain goes on as it does today. Only a
# rate limit is special, and it waits instead of using an attempt.
module Workflows
  module Books
    module Steps
      class Wikidata
        RESCHEDULE_JITTER = 0..30

        def initialize(refresh: false, refresh_from: nil)
          @refresh = refresh
          @refresh_from = refresh_from
        end

        def call(step:, run:, target:)
          result = ::Services::Books::Authors::EnrichFromWikidata.call(author: target, refresh: refresh?(run))
          Workflows::Outcome.succeeded(result.data[:outcome].to_s)
        rescue ::Wikimedia::Exceptions::RateLimited => e
          Workflows::Outcome.wait(Time.current + e.retry_after.to_i + rand(RESCHEDULE_JITTER))
        end

        private

        def refresh?(run)
          (@refresh_from == :options) ? run.options.fetch("refresh", false) : @refresh
        end
      end
    end
  end
end
