# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Finds an existing Music::Album before import and answers with a Match.
      # Increment 1: the pre-redesign lookup (release-group MBID, else an
      # artist-scoped MusicBrainz search resolved to a local MBID, else exact
      # title within the artist) runs as the single decisive source.
      # Increment 6 replaces it with the real sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Music::Album

        def ranking_configuration_class = ::Music::Albums::RankingConfiguration

        # Evidence for the audit pages and the AI prompt. The legacy source
        # decides on its own, so these do not change any decision yet.
        def record_creators(record) = record.artists.map(&:name)

        def record_year(record) = record.release_year

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          # Handle direct release group MBID lookup
          if query.release_group_musicbrainz_id.present?
            return find_by_musicbrainz_id_only(query.release_group_musicbrainz_id)
          end

          # Handle artist-based search (existing logic)
          return nil unless query.artist.present?

          # Get artist's MusicBrainz ID
          artist_mbid = get_artist_musicbrainz_id(query.artist)
          return nil unless artist_mbid

          # Search MusicBrainz to get the release group MBID for this album
          search_result = search_musicbrainz(artist_mbid, query)

          if search_result[:success] && search_result[:data]["release-groups"].any?
            release_group_id = search_result[:data]["release-groups"].first["id"]

            # Try to find existing album by MusicBrainz release group ID (most reliable)
            existing = find_by_musicbrainz_id(release_group_id, query.artist)
            return existing if existing
          end

          # Fallback: try to find by exact title match for the same artist
          if query.title.present?
            existing = find_by_title(query.title, query.artist)
            return existing if existing
          end

          nil
        end

        def get_artist_musicbrainz_id(artist)
          artist.identifiers
            .find_by(identifier_type: :music_musicbrainz_artist_id)
            &.value
        end

        def search_musicbrainz(artist_mbid, query)
          if query.title.present?
            # Search for specific album by artist and title
            search_by_artist_and_title(artist_mbid, query)
          else
            # Search for albums by artist (primary albums only if specified)
            search_by_artist_only(artist_mbid, query)
          end
        rescue => e
          Rails.logger.warn "MusicBrainz search failed in finder: #{e.message}"
          {success: false, errors: [e.message]}
        end

        def search_by_artist_and_title(artist_mbid, query)
          if query.primary_albums_only
            # First try primary albums only
            result = search_service.search_primary_albums_only(artist_mbid)

            if result[:success] && result[:data]["release-groups"].any?
              # Filter by title from primary albums
              filtered_result = filter_by_title(result, query.title)
              return filtered_result if filtered_result[:data]["release-groups"].any?
            end
          end

          # Fallback to general search by artist and title
          search_service.search_by_artist_mbid_and_title(artist_mbid, query.title)
        end

        def search_by_artist_only(artist_mbid, query)
          if query.primary_albums_only
            search_service.search_primary_albums_only(artist_mbid)
          else
            search_service.search_by_artist_mbid(artist_mbid)
          end
        end

        def filter_by_title(result, title)
          # Simple case-insensitive title filtering
          filtered_albums = result[:data]["release-groups"].select do |rg|
            rg["title"].downcase.include?(title.downcase) ||
              title.downcase.include?(rg["title"].downcase)
          end

          {
            success: true,
            data: result[:data].merge("release-groups" => filtered_albums),
            errors: []
          }
        end

        def search_service
          @search_service ||= ::Music::Musicbrainz::Search::ReleaseGroupSearch.new
        end

        def find_by_musicbrainz_id_only(release_group_id)
          ::Music::Album.joins(:identifiers)
            .where(identifiers: {
              identifier_type: :music_musicbrainz_release_group_id,
              value: release_group_id
            })
            .first
        end

        def find_by_musicbrainz_id(release_group_id, artist)
          ::Music::Album.joins(:identifiers)
            .joins(:album_artists)
            .where(identifiers: {
              identifier_type: :music_musicbrainz_release_group_id,
              value: release_group_id
            })
            .where(music_album_artists: {artist: artist})
            .first
        end

        def find_by_title(title, artist)
          artist.albums.find_by(title: title)
        end
      end
    end
  end
end
