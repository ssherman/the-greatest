# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      module Providers
        # AI Description provider for Music::Album data
        # This is an async provider - launches background job and returns success immediately
        class AiDescription < DataImporters::ProviderBase
          def populate(album, query:)
            # Validate we have required data for AI description
            return failure_result(errors: ["Album title required for AI description"]) if album.title.blank?
            return failure_result(errors: ["Album must have at least one artist for AI description"]) if album.artists.empty?

            # Launch background job for AI description processing
            # Job will handle AI task execution and description update
            ::Music::AlbumDescriptionJob.perform_async(album.id)

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
