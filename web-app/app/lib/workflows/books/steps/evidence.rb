# frozen_string_literal: true

# The evidence step of the book workflow: Gather writes one books.evidence
# ledger row (Wikidata, Wikipedia and WorldCat facts about the book) for the
# later origin and category stages to read. A rate limit propagates out of
# Gather before it writes anything, so it waits instead of using an attempt,
# as Steps::Wikidata does.
#
# The result's "qid" is the facts' top-level wikidata_qid (the QID resolution
# ended with, or nil), not the wikidata section: that section is nil when the
# labels call failed after a QID was found.
module Workflows
  module Books
    module Steps
      class Evidence
        RESCHEDULE_JITTER = 0..30

        # reuse_fresh: skip Gather when the latest evidence row is current (this
        # schema version) and complete (no source failed).
        def initialize(reuse_fresh: false)
          @reuse_fresh = reuse_fresh
        end

        def call(step:, run:, target:)
          if @reuse_fresh && (row = fresh_row(target))
            return Workflows::Outcome.succeeded("reused", {"enrichment_id" => row.id, "qid" => row.facts["wikidata_qid"]})
          end

          enrichment = ::Services::Books::Evidence::Gather.call(book: target).data[:enrichment]
          qid = enrichment.facts["wikidata_qid"]
          Workflows::Outcome.succeeded(enrichment.outcome, {"enrichment_id" => enrichment.id, "qid" => qid})
        rescue ::Wikimedia::Exceptions::RateLimited => e
          Workflows::Outcome.wait(Time.current + e.retry_after.to_i + rand(RESCHEDULE_JITTER))
        end

        private

        def fresh_row(book)
          row = book.enrichments.where(kind: ::Services::Books::Evidence::Gather::KIND).order(:id).last
          return nil if row.nil?

          facts = row.facts || {}
          row if facts["schema_version"] == ::Services::Books::Evidence::Gather::SCHEMA_VERSION && Array(facts["sources_failed"]).empty?
        end
      end
    end
  end
end
