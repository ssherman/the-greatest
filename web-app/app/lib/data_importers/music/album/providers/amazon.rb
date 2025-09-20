# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      module Providers
        # Amazon Product API provider for Music::Album data
        # This is our first async provider - launches background job and returns success immediately
        class Amazon < DataImporters::ProviderBase
          def populate(album, query:)
            # Validate we have required data for Amazon search
            return failure_result(errors: ["Album title required for Amazon search"]) if album.title.blank?
            return failure_result(errors: ["Album must have at least one artist for Amazon search"]) if album.artists.empty?

            # Launch background job for Amazon API processing
            # Job will handle API calls, AI validation, external links, and image download
            ::Music::AmazonProductEnrichmentJob.perform_async(album.id)

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
