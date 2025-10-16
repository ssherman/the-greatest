# frozen_string_literal: true

module Music
  module Musicbrainz
    module Search
      class ArtistSearch < BaseSearch
        # Get the entity type for artist searches
        # @return [String] the entity type
        def entity_type
          "artist"
        end

        # Get the MBID field name for artists
        # @return [String] the MBID field name
        def mbid_field
          "arid"
        end

        # Get available search fields for artists
        # @return [Array<String>] list of searchable fields
        def available_fields
          %w[
            name arid alias tag type country gender
            begin end area sortname comment
          ]
        end

        # Search for artists by name
        # @param name [String] the artist name to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_name(name, options = {})
          search_by_field("name", name, options)
        end

        # Search for artists by alias
        # @param alias_name [String] the alias to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_alias(alias_name, options = {})
          search_by_field("alias", alias_name, options)
        end

        # Search for artists by tag
        # @param tag [String] the tag to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_tag(tag, options = {})
          search_by_field("tag", tag, options)
        end

        # Search for artists by type (person, group, etc.)
        # @param type [String] the artist type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_type(type, options = {})
          search_by_field("type", type, options)
        end

        # Search for artists by country
        # @param country [String] the country code (e.g., "US", "GB")
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_country(country, options = {})
          search_by_field("country", country, options)
        end

        # Search for artists by gender
        # @param gender [String] the gender (male, female, other)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_gender(gender, options = {})
          search_by_field("gender", gender, options)
        end

        # Perform a general search query with custom Lucene syntax
        # @param query [String] the search query
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search(query, options = {})
          params = build_search_params(query, options)

          begin
            response = client.get(entity_type, params)
            process_search_response(response)
          rescue Music::Musicbrainz::Exceptions::Error => e
            handle_search_error(e, query, options)
          end
        end

        # Lookup artist by MusicBrainz ID using direct lookup API
        # Uses MusicBrainz lookup endpoint (/ws/2/artist/{mbid}) for direct access
        # @param mbid [String] the MusicBrainz ID (UUID format)
        # @param options [Hash] additional options (inc parameter, etc.)
        # @return [Hash] lookup results with complete artist data
        def lookup_by_mbid(mbid, options = {})
          validate_mbid!(mbid)

          # Add inc parameter for genres and other detailed data
          enhanced_options = options.merge(inc: "genres")

          begin
            # Direct lookup uses /ws/2/artist/{mbid} endpoint
            response = client.get("artist/#{mbid}", enhanced_options)
            process_lookup_response(response)
          rescue Music::Musicbrainz::Exceptions::Error => e
            handle_browse_error(e, {artist_mbid: mbid}, options)
          end
        end

        # Build a complex query with multiple criteria
        # @param criteria [Hash] search criteria (name:, country:, type:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_with_criteria(criteria, options = {})
          query_parts = []

          criteria.each do |field, value|
            next if value.blank?

            if available_fields.include?(field.to_s)
              query_parts << build_field_query(field.to_s, value)
            else
              raise Exceptions::QueryError, "Invalid search field: #{field}"
            end
          end

          if query_parts.empty?
            raise Exceptions::QueryError, "At least one search criterion must be provided"
          end

          query = query_parts.join(" AND ")
          search(query, options)
        end

        private

        # Process lookup response for single artist lookup
        # @param response [Hash] the raw API response
        # @return [Hash] processed response
        def process_lookup_response(response)
          return response unless response[:success]

          # For artist lookup, we get a single artist object
          # Transform it to match search response format for consistency
          if response[:data]
            artist_data = response[:data]
            response[:data] = {
              "count" => 1,
              "offset" => 0,
              "artists" => [artist_data],
              "created" => Time.current.iso8601
            }
          end

          response
        end
      end
    end
  end
end
