# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      module Providers
        # Async provider (spec §2): plans an author enrichment run (spec §10) and
        # returns at once; the run is dispatched after the importer's transaction
        # commits. Providers run only for a new author (or a forced re-import), so
        # a matched author is never re-enriched from here. An author who already
        # has an active run keeps it.
        class Enrichment < DataImporters::ProviderBase
          def populate(author, query:, match: nil)
            return failure_result(errors: ["Author must be persisted before queuing enrichment"]) unless author.persisted?

            ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "author_importer")
            success_result(data_populated: [:author_enrichment_planned])
          rescue => e
            failure_result(errors: ["Author enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
