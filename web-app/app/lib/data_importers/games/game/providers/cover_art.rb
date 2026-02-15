# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      module Providers
        # CoverArt provider for Games::Game data
        # Queues a background job to download cover art from IGDB CDN
        # This is an async provider - returns success immediately after queuing
        class CoverArt < DataImporters::ProviderBase
          def populate(game, query:)
            # Game must be persisted for the job to find it
            return failure_result(errors: ["Game must be persisted"]) unless game.persisted?

            # Game must have an IGDB identifier for the job to look up cover art
            igdb_identifier = game.identifiers.find_by(identifier_type: :games_igdb_id)
            return failure_result(errors: ["Game must have IGDB identifier"]) unless igdb_identifier

            # Queue background job
            ::Games::CoverArtDownloadJob.perform_async(game.id)

            success_result(data_populated: [:cover_art_queued])
          rescue => e
            failure_result(errors: ["CoverArt provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
