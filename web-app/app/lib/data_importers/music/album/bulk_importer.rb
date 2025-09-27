# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Bulk importer for discovering and importing all albums for an artist from MusicBrainz
      # This is separate from the single Album::Importer to handle different semantics:
      # - Single importer: Import/create a specific album (succeeds even if not in MusicBrainz)
      # - Bulk importer: Discover albums from MusicBrainz (fails if nothing found to import)
      class BulkImporter
        def self.call(artist:, primary_albums_only: false)
          new(artist: artist, primary_albums_only: primary_albums_only).call
        end

        def initialize(artist:, primary_albums_only: false)
          @artist = artist
          @primary_albums_only = primary_albums_only
        end

        def call
          # Validate artist has MusicBrainz ID
          musicbrainz_id = extract_musicbrainz_id
          return failure_result("Artist has no MusicBrainz ID") if musicbrainz_id.blank?

          # Search MusicBrainz for albums
          albums_data = fetch_albums_from_musicbrainz(musicbrainz_id)
          return failure_result("No albums found in MusicBrainz") if albums_data.empty?

          # Import each album using the single Album::Importer
          import_results = []
          albums_data.each do |album_data|
            result = Importer.call(release_group_musicbrainz_id: album_data["id"])
            import_results << result
          end

          # Return aggregated results
          successful_imports = import_results.select(&:success?)
          BulkImportResult.new(
            artist: @artist,
            total_found: albums_data.size,
            successful_imports: successful_imports.size,
            failed_imports: import_results.size - successful_imports.size,
            import_results: import_results,
            success: successful_imports.any?
          )
        rescue => e
          failure_result("Bulk import failed: #{e.message}")
        end

        private

        def extract_musicbrainz_id
          identifier = @artist.identifiers.find_by(identifier_type: :music_musicbrainz_artist_id)
          identifier&.value
        end

        def fetch_albums_from_musicbrainz(musicbrainz_id)
          search_service = ::Music::Musicbrainz::Search::ReleaseGroupSearch.new

          api_result = if @primary_albums_only
            search_service.search_primary_albums_only(musicbrainz_id)
          else
            search_service.search_by_artist_mbid(musicbrainz_id)
          end

          return [] unless api_result[:success]

          api_result[:data]["release-groups"] || []
        end

        def failure_result(error_message)
          BulkImportResult.new(
            artist: @artist,
            total_found: 0,
            successful_imports: 0,
            failed_imports: 0,
            import_results: [],
            success: false,
            error: error_message
          )
        end

        # Result object for bulk import operations
        class BulkImportResult
          attr_reader :artist, :total_found, :successful_imports, :failed_imports,
            :import_results, :error

          def initialize(artist:, total_found:, successful_imports:, failed_imports:,
            import_results:, success:, error: nil)
            @artist = artist
            @total_found = total_found
            @successful_imports = successful_imports
            @failed_imports = failed_imports
            @import_results = import_results
            @success = success
            @error = error
          end

          def success?
            @success
          end

          def albums
            @import_results.filter_map { |result| result.item if result.success? }
          end
        end
      end
    end
  end
end
