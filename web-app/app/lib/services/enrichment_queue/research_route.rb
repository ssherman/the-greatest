# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # Where an enricher's would-be web search goes. With config.x.ai.research_via
    # "queue" the paid enrichers never spend it: they write a skipped research
    # row (reason "queued") and call defer, which leaves a pending row in the
    # queue for an agent. Deferring is best effort: a queue failure is logged
    # and never fails the enrichment that asked.
    module ResearchRoute
      REASON = "research_wanted"

      class << self
        def queue? = Rails.application.config.x.ai.research_via == "queue"

        # True while the record's research is still owed to the queue: it has no
        # row of this kind, or its row is pending, claimed or submitted. A
        # submitted row holds an agent's web-verified answer that the apply job
        # has yet to write, so the research is done but has not landed, and a
        # guess applied now would leave that answer only blanks to fill. A
        # resolved row (done, skipped, failed) means the queue is finished.
        def open_for?(kind:, record:)
          !::EnrichmentRequest.where(enrichable: record, kind: kind)
            .where.not(status: [:pending, :claimed, :submitted]).exists?
        end

        # Inserts one pending row unless the type no longer needs the record.
        # Returns true when a row was inserted. The skip row that asked for the
        # research must already be written: the types read it in still_needed?.
        def defer(kind:, record:)
          type = Registry.fetch(kind)
          return false unless type.still_needed?(record)

          row = {enrichable_type: type.target_class.polymorphic_name, enrichable_id: record.id, kind: type.kind,
                 reason: REASON, version: type.version, priority: type.priority_for(record), sources: []}
          result = ::EnrichmentRequest.insert_all([row], unique_by: Fill::UNIQUE_INDEX, returning: %w[id])
          result.rows.any?
        rescue => e
          Rails.logger.error("event=enrichment_queue_defer_failed kind=#{kind} record_id=#{record&.id} error=#{e.message}")
          false
        end
      end
    end
  end
end
