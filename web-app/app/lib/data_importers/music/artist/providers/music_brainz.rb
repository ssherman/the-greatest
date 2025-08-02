# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      module Providers
        # MusicBrainz provider for Music::Artist data
        class MusicBrainz < DataImporters::ProviderBase
          def populate(artist, query:)
            # Search for artist - MusicBrainz search already returns detailed data
            search_result = search_for_artist(query.name)
            
            return failure_result(errors: search_result[:errors]) unless search_result[:success]
            
            artists_data = search_result[:data]["artists"]
            return failure_result(errors: ["No artists found"]) if artists_data.empty?

            # Take the first result (top match by score) - already contains all the rich data
            artist_data = artists_data.first
            
            # Populate artist with all available data from search result
            populate_artist_data(artist, artist_data)
            create_identifiers(artist, artist_data)
            
            success_result(data_populated: data_fields_populated(artist_data))
          rescue => e
            failure_result(errors: ["MusicBrainz error: #{e.message}"])
          end

          private

          def search_for_artist(name)
            search_service.search_by_name(name)
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::ArtistSearch.new
          end

          def populate_artist_data(artist, artist_data)
            # Set basic artist information
            artist.name = artist_data["name"] if artist.name.blank?
            
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