# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      module Providers
        # MusicBrainz provider for Music::Artist data
        class MusicBrainz < DataImporters::ProviderBase
          # Populates an artist with MusicBrainz data and categories
          #
          # Params:
          # - artist: Music::Artist - the artist to enrich
          # - query: ImportQuery - contains name
          #
          # Returns: Result(success:, data_populated:|errors:)
          def populate(artist, query:)
            # Use different API based on what information we have
            api_result = if query.musicbrainz_id.present?
              lookup_artist_by_mbid(query.musicbrainz_id)
            else
              search_for_artist(query.name)
            end

            return failure_result(errors: api_result[:errors]) unless api_result[:success]

            artists_data = api_result[:data]["artists"]
            return failure_result(errors: ["No artists found"]) if artists_data.empty?

            # Take the first result (top match by score or single lookup result)
            artist_data = artists_data.first

            # Populate artist with all available data from API result
            populate_artist_data(artist, artist_data)
            create_identifiers(artist, artist_data)
            create_categories_from_musicbrainz_data(artist, artist_data)

            success_result(data_populated: data_fields_populated(artist_data))
          rescue => e
            failure_result(errors: ["MusicBrainz error: #{e.message}"])
          end

          private

          # Executes artist search on MusicBrainz
          #
          # Params: name (String)
          # Returns: search result Hash
          def search_for_artist(name)
            search_service.search_by_name(name)
          end

          # Executes artist lookup on MusicBrainz using direct MBID lookup
          #
          # Params: mbid (String) - MusicBrainz ID
          # Returns: lookup result Hash
          def lookup_artist_by_mbid(mbid)
            search_service.lookup_by_mbid(mbid)
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::ArtistSearch.new
          end

          # Maps core fields from MusicBrainz response to artist
          # Sets name, kind, country and life-span
          def populate_artist_data(artist, artist_data)
            # Set basic artist information - always use MusicBrainz name as authoritative source
            artist.name = artist_data["name"] if artist_data["name"].present?

            # Map MusicBrainz type to our kind enum
            if artist_data["type"]
              artist.kind = map_musicbrainz_type_to_kind(artist_data["type"])
            end

            # Set country if available
            if artist_data["country"]
              artist.country = artist_data["country"]
            end

            # Parse and set life-span data
            if artist_data["life-span"]
              populate_life_span_data(artist, artist_data["life-span"])
            end
          end

          # Populates life-span fields based on response
          # Sets born_on/year_died for people and year_formed/year_disbanded for bands
          def populate_life_span_data(artist, life_span_data)
            return unless life_span_data

            begin_date = life_span_data["begin"]
            end_date = life_span_data["ended"]

            if begin_date.present?
              if artist.person?
                # For persons, set born_on if we have a full date, otherwise year_formed (which we don't have)
                # Note: MusicBrainz uses "begin" for birth date for persons
                if begin_date.match?(/^\d{4}-\d{2}-\d{2}$/)
                  artist.born_on = Date.parse(begin_date)
                end
              elsif artist.band?
                # For bands, "begin" is formation date
                if begin_date.match?(/^\d{4}/)
                  artist.year_formed = begin_date[0..3].to_i
                end
              end
            end

            if end_date.present?
              if artist.person?
                # For persons, "ended" is death date
                if end_date.match?(/^\d{4}/)
                  artist.year_died = end_date[0..3].to_i
                end
              elsif artist.band?
                # For bands, "ended" is disbandment date
                if end_date.match?(/^\d{4}/)
                  artist.year_disbanded = end_date[0..3].to_i
                end
              end
            end
          end

          # Maps MusicBrainz type to internal kind enum
          # Returns: "person" or "band"
          def map_musicbrainz_type_to_kind(mb_type)
            case mb_type.downcase
            when "group", "orchestra", "choir"
              "band"
            when "person", "character"
              "person"
            else
              "person" # Default fallback
            end
          end

          # Builds external identifiers on the artist from MusicBrainz data
          # Creates: music_musicbrainz_artist_id and optional ISNI(s)
          def create_identifiers(artist, artist_data)
            # Create MusicBrainz identifier
            if artist_data["id"]
              artist.identifiers.build(
                identifier_type: :music_musicbrainz_artist_id,
                value: artist_data["id"]
              )
            end

            # Create ISNI identifiers if present
            if artist_data["isnis"]&.any?
              artist_data["isnis"].each do |isni|
                artist.identifiers.build(
                  identifier_type: :music_isni,
                  value: isni
                )
              end
            end
          end

          # Creates genre and location categories for artists from MusicBrainz data
          # Creates genre and location categories based on MusicBrainz tags, genres, and area data
          # - Genres: top 5 from both "tags" and "genres" fields (normalized, hyphens preserved)
          # - Locations: area and begin-area names
          # Associates via CategoryItem and raises on errors
          def create_categories_from_musicbrainz_data(artist, artist_data)
            categories = []

            # Genres from both tags and genres (top 5 combined, normalized)
            genre_names = []
            genre_names += extract_category_names_from_field(artist_data, "tags")
            genre_names += extract_category_names_from_field(artist_data, "genres")

            if genre_names.any?
              categories += find_or_create_music_categories(genre_names.uniq, category_type: "genre")
            end

            # Locations from area and begin-area (artist only)
            area_names = []
            area_names << artist_data.dig("area", "name") if artist_data.dig("area", "name").present?
            area_names << artist_data.dig("begin-area", "name") if artist_data.dig("begin-area", "name").present?

            if area_names.any?
              categories += find_or_create_music_categories(area_names, category_type: "location")
            end

            # Associate categories with artist via join to avoid through-write quirks
            categories.compact.uniq.each do |category|
              ::CategoryItem.find_or_create_by!(category: category, item: artist)
            end
          rescue => e
            Rails.logger.error "MusicBrainz artist categories error: #{e.message}"
            raise
          end

          # Finds or creates Music::Category records by name and type
          # Params:
          # - names: Array<String>
          # - category_type: "genre" | "location"
          # Returns: Array<Music::Category>
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

          # Extracts and processes category names from either "tags" or "genres" field
          # Returns top 5 non-zero entries, normalized
          # @param artist_data [Hash] MusicBrainz artist data
          # @param field_name [String] either "tags" or "genres"
          # @return [Array<String>] normalized category names
          def extract_category_names_from_field(artist_data, field_name)
            return [] unless artist_data[field_name].is_a?(Array)

            artist_data[field_name]
              .reject { |item| item["count"].to_i == 0 }
              .sort_by { |item| -item["count"].to_i }
              .first(5)
              .map { |item| normalize_tag_name(item["name"]) }
              .reject(&:blank?)
          end

          # Normalizes a MusicBrainz tag to Title Case preserving hyphens
          # Example: "synth-pop" => "Synth-Pop"
          def normalize_tag_name(name)
            return "" if name.blank?
            # Preserve hyphens within words while capitalizing each part (e.g., "synth-pop" => "Synth-Pop")
            name.split(/\s+/).map { |word| word.split("-").map(&:capitalize).join("-") }.join(" ")
          end

          def data_fields_populated(artist_data)
            fields = [:name, :kind, :musicbrainz_id]

            fields << :country if artist_data["country"]
            fields << :life_span_data if artist_data["life-span"]
            fields << :isni if artist_data["isnis"]&.any?

            fields
          end
        end
      end
    end
  end
end
