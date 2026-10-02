# frozen_string_literal: true

module Services
  module Books
    module Authors
      # What the Wikidata and VIAF steps share about their ledger rows (spec
      # §11, §12, §14). A run writes at most one row of its class's KIND,
      # tied to the run's decision (@decision) once one exists.
      #
      # "Processed" is a row with a done outcome, newer than the author row
      # (after the production re-migration an author is re-created with its
      # id and starts again), whose decision no person rejected. A row with
      # no decision counts, so the verdict comparison is NULL-safe.
      #
      # An including class defines KIND, PROVIDER and `author`, and sets
      # @decision when its resolver records one. @restored, when a run put
      # back an earlier decision's id (RestoreIdentifier), is recorded on
      # its row.
      module LedgerRun
        PROCESSED = %w[applied nothing_to_apply unrecognized].freeze
        CONFIDENCE = {"certain" => "high", "high" => "high", "medium" => "medium", "low" => "low"}.freeze

        # Every author's done rows of this kind: the backfill's selection
        # (Backfill) and one author's own check (#processed?) read the same rule.
        def self.processed(kind)
          ::Enrichment.for_kind(kind).where(enrichable_type: "Books::Author", outcome: PROCESSED)
            .joins("INNER JOIN books_authors ON books_authors.id = enrichments.enrichable_id")
            .where("enrichments.created_at > books_authors.created_at")
            .left_joins(:match_decision)
            .where("match_decisions.verdict IS DISTINCT FROM ?", ::MatchDecision.verdicts[:rejected])
        end

        private

        def processed? = LedgerRun.processed(self.class::KIND).where(enrichable_id: author.id).exists?

        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          facts = facts.merge("restored_identifier" => @restored) if @restored
          author.enrichments.create!(
            kind: self.class::KIND, provider: self.class::PROVIDER, outcome: outcome, reason: reason, recognized: recognized,
            confidence: CONFIDENCE[@decision&.confidence], facts: facts, citations: citations,
            error: error, match_decision: @decision
          )
        end

        # An error no rescue above expected (a bug, a constraint): one failed
        # row, tied to the decision if one was recorded, so no decision is
        # left without its run, and the author is tried again next time.
        # Raising instead would have Sidekiq retry the whole run, recording a
        # new decision each time.
        def unexpected(error, facts: {})
          Rails.logger.error("#{self.class.name}: author #{author.id}: #{error.class.name}: #{error.message}")
          write(outcome: :failed, reason: "unexpected_error", error: "#{error.class.name}: #{error.message}", facts: facts)
        end
      end
    end
  end
end
