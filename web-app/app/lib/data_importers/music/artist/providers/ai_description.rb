# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      module Providers
        # AI Description provider for Music::Artist data
        # This is an async provider - launches background job and returns success immediately
        class AiDescription < DataImporters::ProviderBase
          def populate(artist, query:)
            # Validate we have required data for AI description
            return failure_result(errors: ["Artist name required for AI description"]) if artist.name.blank?

            # Launch background job for AI description processing
            # Job will handle AI task execution and description update
            ::Music::ArtistDescriptionJob.perform_async(artist.id)

            # Return success immediately - actual description generation happens in background
            success_result(data_populated: [:ai_description_queued])
          rescue => e
            failure_result(errors: ["AI Description provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
