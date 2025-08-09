# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      module Providers
        # MusicBrainz provider for Music::Album data
        class MusicBrainz < DataImporters::ProviderBase
          def populate(album, query:)
            # Get artist's MusicBrainz ID
            artist_mbid = get_artist_musicbrainz_id(query.artist)
            return failure_result(errors: ["Artist has no MusicBrainz ID"]) unless artist_mbid

            # Search for release groups using the two-step strategy
            search_result = search_for_release_groups(artist_mbid, query)
            return failure_result(errors: search_result[:errors]) unless search_result[:success]

            release_groups = search_result[:data]["release-groups"]
            return failure_result(errors: ["No albums found"]) if release_groups.empty?

            # Take the first result (highest MusicBrainz relevance score)
            release_group_data = release_groups.first

            # Populate album with MusicBrainz data
            populate_album_data(album, release_group_data, query.artist)
            create_identifiers(album, release_group_data)

            success_result(data_populated: data_fields_populated(release_group_data))
          rescue => e
            failure_result(errors: ["MusicBrainz error: #{e.message}"])
          end

          private

          def get_artist_musicbrainz_id(artist)
            artist.identifiers
              .find_by(identifier_type: :music_musicbrainz_artist_id)
              &.value
          end

          def search_for_release_groups(artist_mbid, query)
            if query.title.present?
              # Search for specific album by artist and title
              search_by_artist_and_title(artist_mbid, query.title, query.primary_albums_only)
            else
              # Search for all albums by artist (primary albums only if specified)
              search_by_artist_only(artist_mbid, query.primary_albums_only)
            end
          end

          def search_by_artist_and_title(artist_mbid, title, primary_albums_only)
            if primary_albums_only
              # First try primary albums only
              result = search_service.search_primary_albums_only(artist_mbid)

              if result[:success] && result[:data]["release-groups"].any?
                # Filter by title from primary albums
                filtered_result = filter_by_title(result, title)
                return filtered_result if filtered_result[:data]["release-groups"].any?
              end
            end

            # Fallback to general search by artist and title
            search_service.search_by_artist_mbid_and_title(artist_mbid, title)
          end

          def search_by_artist_only(artist_mbid, primary_albums_only)
            if primary_albums_only
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

          def populate_album_data(album, release_group_data, artist)
            # Set basic album information
            album.title = release_group_data["title"] if album.title.blank?
            album.primary_artist = artist

            # Extract year from first-release-date
            if release_group_data["first-release-date"].present?
              first_release_date = release_group_data["first-release-date"]
              if first_release_date.match?(/^\d{4}/)
                album.release_year = first_release_date[0..3].to_i
              end
            end
          end

          def create_identifiers(album, release_group_data)
            # Create MusicBrainz release group identifier
            if release_group_data["id"]
              album.identifiers.build(
                identifier_type: :music_musicbrainz_release_group_id,
                value: release_group_data["id"]
              )
            end
          end

          def data_fields_populated(release_group_data)
            fields = [:title, :primary_artist, :musicbrainz_release_group_id]
            fields << :release_year if release_group_data["first-release-date"]
            fields
          end
        end
      end
    end
  end
end
