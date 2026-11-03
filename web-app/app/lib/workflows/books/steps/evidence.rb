# frozen_string_literal: true

# The evidence step of the book workflow: Gather writes one books.evidence
# ledger row (Wikidata, Wikipedia and WorldCat facts about the book) for the
# later origin and category stages to read. A rate limit propagates out of
# Gather before it writes anything, so it waits instead of using an attempt,
# as Steps::Wikidata does.
#
# The result's "qid" is the book's stored work QID, not the facts' wikidata
# section: that section is nil when the labels call failed after a QID was stored.
module Workflows
  module Books
    module Steps
      class Evidence
        RESCHEDULE_JITTER = 0..30

        def call(step:, run:, target:)
          enrichment = ::Services::Books::Evidence::Gather.call(book: target).data[:enrichment]
          qid = target.identifiers.find_by(identifier_type: :books_work_wikidata_qid)&.value
          Workflows::Outcome.succeeded(enrichment.outcome, {"enrichment_id" => enrichment.id, "qid" => qid})
        rescue ::Wikimedia::Exceptions::RateLimited => e
          Workflows::Outcome.wait(Time.current + e.retry_after.to_i + rand(RESCHEDULE_JITTER))
        end
      end
    end
  end
end
