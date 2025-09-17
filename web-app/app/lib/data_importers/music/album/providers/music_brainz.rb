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
          # - query: ImportQuery - contains artist OR release_group_musicbrainz_id, optional title, primary_albums_only
          #
          # Returns: Result(success:, data_populated:|errors:)
          def populate(album, query:)
            # Use different API based on what information we have
            api_result = if query.release_group_musicbrainz_id.present?
              lookup_release_group_by_mbid(query.release_group_musicbrainz_id)
            else
              search_release_groups_by_artist(album, query)
            end

            return failure_result(errors: api_result[:errors]) unless api_result[:success]

            release_groups = api_result[:data]["release-groups"]
            return failure_result(errors: ["No albums found"]) if release_groups.empty?

            # Take the first result (single lookup result or highest search relevance score)
            release_group_data = release_groups.first

            # Import/find artists from artist-credit data (for lookup) or use provided artist (for search)
            artists = if query.release_group_musicbrainz_id.present?
              import_artists_from_artist_credits(release_group_data["artist-credit"])
            else
              [query.artist]
            end

            return failure_result(errors: ["No valid artists found"]) if artists.empty?

            # Populate album with MusicBrainz data
            populate_album_data(album, release_group_data, artists)
            create_identifiers(album, release_group_data)
            create_categories_from_musicbrainz_data(album, release_group_data)

            success_result(data_populated: data_fields_populated(release_group_data))
          rescue => e
            failure_result(errors: ["MusicBrainz error: #{e.message}"])
          end

          private

          # Executes release group lookup on MusicBrainz using direct MBID lookup
          #
          # Params: mbid (String) - MusicBrainz Release Group ID
          # Returns: lookup result Hash
          def lookup_release_group_by_mbid(mbid)
            search_service.lookup_by_release_group_mbid(mbid)
          end

          # Executes release group search by artist (existing logic)
          #
          # Params: album (Music::Album), query (ImportQuery)
          # Returns: search result Hash
          def search_release_groups_by_artist(album, query)
            # Get artist's MusicBrainz ID
            artist_mbid = get_artist_musicbrainz_id(query.artist)
            return {success: false, errors: ["Artist has no MusicBrainz ID"]} unless artist_mbid

            # Search for release groups using the existing strategy
            search_for_release_groups(artist_mbid, query)
          end

          # Import artists from MusicBrainz artist-credit data
          #
          # Params: artist_credits (Array) - artist-credit array from MusicBrainz
          # Returns: Array of Music::Artist instances
          def import_artists_from_artist_credits(artist_credits)
            return [] unless artist_credits.is_a?(Array)

            artists = artist_credits.map do |credit|
              artist_mbid = credit.dig("artist", "id")
              next unless artist_mbid

              begin
                # Use existing artist importer with MusicBrainz ID
                result = DataImporters::Music::Artist::Importer.call(musicbrainz_id: artist_mbid)

                # Artist importer now always returns ImportResult
                if result.success?
                  Rails.logger.info "Artist imported: #{result.item.name}"
                  result.item
                else
                  Rails.logger.warn "Artist import failed for #{artist_mbid}: #{result.all_errors.join(", ")}"
                  nil
                end
              rescue => e
                Rails.logger.warn "Failed to import artist #{artist_mbid}: #{e.message}"
                Rails.logger.warn e.backtrace.join("\n")
                nil
              end
            end.compact

            Rails.logger.info "Imported #{artists.count} artists from artist-credits"
            artists
          end

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
          # Sets title, artists, and release_year
          def populate_album_data(album, release_group_data, artists)
            # Set basic album information - always use MusicBrainz title as authoritative source
            album.title = release_group_data["title"] if release_group_data["title"].present?

            # Associate all artists with the album
            existing_artist_ids = album.album_artists.map(&:artist_id)
            artists.each_with_index do |artist, index|
              unless existing_artist_ids.include?(artist.id)
                album.album_artists.build(artist: artist, position: index + 1)
              end
            end

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
              album.identifiers.find_or_initialize_by(
                identifier_type: :music_musicbrainz_release_group_id,
                value: release_group_data["id"]
              )
            end
          end

          # Creates genre categories for albums from MusicBrainz release group data
          # Creates genre categories from both "tags" and "genres" fields (top 5 combined, normalized)
          # Associates via CategoryItem and raises on errors
          def create_categories_from_musicbrainz_data(album, release_group_data)
            categories = []

            # Genres from both tags and genres (top 5 combined, normalized)
            genre_names = []
            genre_names += extract_category_names_from_field(release_group_data, "tags")
            genre_names += extract_category_names_from_field(release_group_data, "genres")

            if genre_names.any?
              categories += find_or_create_music_categories(genre_names.uniq, category_type: "genre")
            end

            # Associate categories with album via join to avoid through-write quirks
            categories.compact.uniq.each do |category|
              ::CategoryItem.find_or_create_by!(category: category, item: album)
            end
          rescue => e
            Rails.logger.error "MusicBrainz album categories error: #{e.message}"
            raise
          end

          # Extracts and processes category names from either "tags" or "genres" field
          # Returns top 5 non-zero entries, normalized
          # @param release_group_data [Hash] MusicBrainz release group data
          # @param field_name [String] either "tags" or "genres"
          # @return [Array<String>] normalized category names
          def extract_category_names_from_field(release_group_data, field_name)
            return [] unless release_group_data[field_name].is_a?(Array)

            release_group_data[field_name]
              .reject { |item| item["count"].to_i == 0 }
              .sort_by { |item| -item["count"].to_i }
              .first(5)
              .map { |item| normalize_tag_name(item["name"]) }
              .reject(&:blank?)
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
            fields = [:title, :artists, :musicbrainz_release_group_id]
            fields << :release_year if release_group_data["first-release-date"]
            fields
          end
        end
      end
    end
  end
end
