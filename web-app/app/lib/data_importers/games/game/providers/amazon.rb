# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      module Providers
        # Amazon Product API provider for Games::Game data
        # Queues a background job for Amazon product enrichment with AI validation
        # This is an async provider - returns success immediately after queuing
        class Amazon < DataImporters::ProviderBase
          def populate(game, query:)
            # Validate we have required data for Amazon search
            return failure_result(errors: ["Game title required for Amazon search"]) if game.title.blank?

            # Validate game is persisted before queuing background job
            return failure_result(errors: ["Game must be persisted before queuing Amazon enrichment job"]) unless game.persisted?

            # Queue background job for Amazon API processing
            ::Games::AmazonProductEnrichmentJob.perform_async(game.id)

            # Return success immediately - actual enrichment happens in background
            success_result(data_populated: [:amazon_enrichment_queued])
          rescue => e
            failure_result(errors: ["Amazon provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
