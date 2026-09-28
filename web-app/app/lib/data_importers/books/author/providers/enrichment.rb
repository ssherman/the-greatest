# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      module Providers
        # Async provider (spec §2): queues the Wikidata step for the author and
        # returns at once. Providers run only for a new author (or a forced
        # re-import), so a matched author is never re-enriched from here; the
        # chain continues from the job.
        class Enrichment < DataImporters::ProviderBase
          def populate(author, query:, match: nil)
            return failure_result(errors: ["Author must be persisted before queuing enrichment"]) unless author.persisted?

            ::Books::Authors::WikidataJob.perform_async(author.id)
            success_result(data_populated: [:author_enrichment_queued])
          rescue => e
            failure_result(errors: ["Author enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
