# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      module Providers
        # MusicBrainz provider for Music::Album data
        class MusicBrainz < DataImporters::ProviderBase
          # Populates an album (release group) with MusicBrainz data and genre categories
          #
          # Params:
          # - album: Music::Album - the album to enrich
          # - query: ImportQuery - contains artist, optional title, primary_albums_only
          #
          # Returns: Result(success:, data_populated:|errors:)
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
            create_categories_from_musicbrainz_data(album, release_group_data)

            success_result(data_populated: data_fields_populated(release_group_data))
          rescue => e
            failure_result(errors: ["MusicBrainz error: #{e.message}"])
          end

          private

          # Retrieves the MusicBrainz artist MBID from identifiers
          # Returns: String or nil
          def get_artist_musicbrainz_id(artist)
            artist.identifiers
              .find_by(identifier_type: :music_musicbrainz_artist_id)
              &.value
          end

          # Selects appropriate search strategy for release groups
          # Returns: search result Hash
          def search_for_release_groups(artist_mbid, query)
            if query.title.present?
              # Search for specific album by artist and title
              search_by_artist_and_title(artist_mbid, query.title, query.primary_albums_only)
            else
              # Search for all albums by artist (primary albums only if specified)
              search_by_artist_only(artist_mbid, query.primary_albums_only)
            end
          end

          # Searches by artist MBID and title with optional primary-albums-first strategy
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

          # Searches all release groups by artist MBID
          def search_by_artist_only(artist_mbid, primary_albums_only)
            if primary_albums_only
              search_service.search_primary_albums_only(artist_mbid)
            else
              search_service.search_by_artist_mbid(artist_mbid)
            end
          end

          # Filters a release-groups result by case-insensitive title match
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

          # Lazily instantiates the MusicBrainz search service
          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::ReleaseGroupSearch.new
          end

          # Maps core fields from release group to album
          # Sets title, primary_artist, and release_year
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

          # Builds MusicBrainz release group identifier on album
          def create_identifiers(album, release_group_data)
            # Create MusicBrainz release group identifier
            if release_group_data["id"]
              album.identifiers.build(
                identifier_type: :music_musicbrainz_release_group_id,
                value: release_group_data["id"]
              )
            end
          end

          # Creates genre categories for albums from MusicBrainz release group data
          # Creates genre categories based on top 5 non-zero tags from release group data
          # Associates via CategoryItem and raises on errors
          def create_categories_from_musicbrainz_data(album, release_group_data)
            return unless release_group_data["tags"].is_a?(Array)

            tag_names = release_group_data["tags"]
              .reject { |t| t["count"].to_i == 0 }
              .sort_by { |t| -t["count"].to_i }
              .first(5)
              .map { |t| normalize_tag_name(t["name"]) }
              .uniq

            categories = find_or_create_music_categories(tag_names, category_type: "genre")

            # Associate via join model
            categories.compact.uniq.each do |category|
              ::CategoryItem.find_or_create_by!(category: category, item: album)
            end
          rescue => e
            Rails.logger.error "MusicBrainz album categories error: #{e.message}"
            raise
          end

          # Finds or creates Music::Category records by name and type
          def find_or_create_music_categories(names, category_type:)
            names.map do |name|
              next if name.blank?
              ::Music::Category.find_or_create_by!(
                name: name,
                category_type: category_type,
                import_source: "musicbrainz"
              )
            end
          end

          # Normalizes a MusicBrainz tag to Title Case preserving hyphens
          def normalize_tag_name(name)
            return "" if name.blank?
            # Preserve hyphens within words while capitalizing each part (e.g., "synth-pop" => "Synth-Pop")
            name.split(/\s+/).map { |word| word.split("-").map(&:capitalize).join("-") }.join(" ")
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
