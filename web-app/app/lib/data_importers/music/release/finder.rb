# frozen_string_literal: true

module DataImporters
  module Music
    module Release
      class Finder < FinderBase
        def call(query:)
          # Get the release group MBID from the album's identifiers
          album = query.album
          release_group_mbid = get_release_group_mbid(album)
          return nil unless release_group_mbid

          # Search MusicBrainz for all releases in this release group
          release_search = ::Music::Musicbrainz::Search::ReleaseSearch.new
          search_results = release_search.search_by_release_group_mbid(release_group_mbid)

          return nil unless search_results&.dig(:data, "releases")&.any?

          # Check if any of these releases already exist in our database
          existing_releases = find_existing_releases(search_results[:data]["releases"], album)

          # Return the first existing release found, or nil if none exist
          existing_releases.first
        rescue => e
          Rails.logger.warn "MusicBrainz search failed in release finder: #{e.message}"
          nil
        end

        private

        def get_release_group_mbid(album)
          identifier = album.identifiers.find_by(identifier_type: :music_musicbrainz_release_group_id)
          identifier&.value
        end

        def find_existing_releases(musicbrainz_releases, album)
          release_mbids = musicbrainz_releases.map { |release| release["id"] }

          # Find existing releases by MusicBrainz release ID
          album.releases
            .joins(:identifiers)
            .where(identifiers: {
              identifier_type: :music_musicbrainz_release_id,
              value: release_mbids
            })
        end
      end
    end
  end
end
