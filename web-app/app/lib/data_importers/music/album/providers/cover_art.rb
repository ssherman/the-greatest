# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      module Providers
        class CoverArt < DataImporters::ProviderBase
          def populate(album, query:)
            return failure_result(errors: ["Album must be persisted before queuing cover art download job"]) unless album.persisted?

            ::Music::CoverArtDownloadJob.perform_async(album.id)

            success_result(data_populated: [:cover_art_queued])
          rescue => e
            failure_result(errors: ["Cover Art provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
