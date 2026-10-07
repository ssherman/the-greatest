# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Async provider (spec §10): starts the author chain for each author
        # this import created. It runs after Providers::AiEnrichment, so the
        # book's deferral row already exists when the chain starts. The
        # importer saves the book after each successful provider, so the book
        # and its book_authors rows exist when the Wikidata step reads the
        # author's titles. The author importer's own async provider is left
        # out of a book import for that reason (Author::Importer::BOOK_STEP_PROVIDERS).
        class AuthorEnrichment < DataImporters::ProviderBase
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end

          def populate(book, query:, match: nil)
            # Checked before the empty-ids no-op, not after: an import whose
            # book never got persisted (every earlier provider failed) must
            # not look like a success just because there was nothing here to
            # queue either.
            return failure_result(errors: ["Book must be persisted before author enrichment"]) unless book.persisted?

            ids = @new_author_ids.uniq
            return success_result(data_populated: []) if ids.empty?

            # After the outermost commit, as in AiEnrichment: the job looks the
            # author up and drops itself when it is not there yet.
            ::ActiveRecord.after_all_transactions_commit do
              ids.each { |author_id| ::Books::Authors::WikidataJob.perform_async(author_id) }
            end
            success_result(data_populated: [:author_enrichment_queued])
          rescue => e
            failure_result(errors: ["Author enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
