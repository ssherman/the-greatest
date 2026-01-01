# frozen_string_literal: true

module Music
  module Musicbrainz
    module Search
      class ReleaseGroupSearch < BaseSearch
        # Get the entity type for release group searches
        # @return [String] the entity type
        def entity_type
          "release-group"
        end

        # Get the MBID field name for release groups
        # @return [String] the MBID field name
        def mbid_field
          "rgid"
        end

        # Get available search fields for release groups
        # @return [Array<String>] list of searchable fields
        def available_fields
          %w[
            alias arid artist artistname comment creditname
            firstreleasedate primarytype reid release releasegroup
            releasegroupaccent releases rgid secondarytype status
            tag type title country date
          ]
        end

        # Search for release groups by title
        # @param title [String] the release group title to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_title(title, options = {})
          search_by_field("title", title, options)
        end

        # Search for release groups by artist MBID
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid(artist_mbid, options = {})
          search_by_field("arid", artist_mbid, options)
        end

        # Search for release groups by artist name
        # @param artist_name [String] the artist name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_name(artist_name, options = {})
          search_by_field("artist", artist_name, options)
        end

        # Search for release groups by tag
        # @param tag [String] the tag to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_tag(tag, options = {})
          search_by_field("tag", tag, options)
        end

        # Search for release groups by type (album, single, EP, etc.)
        # @param type [String] the release group type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_type(type, options = {})
          search_by_field("type", type, options)
        end

        # Search for release groups by country
        # @param country [String] the country code (e.g., "US", "GB")
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_country(country, options = {})
          search_by_field("country", country, options)
        end

        # Search for release groups by release date
        # @param date [String] the date (YYYY, YYYY-MM, or YYYY-MM-DD)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_date(date, options = {})
          search_by_field("date", date, options)
        end

        # Search for release groups by first release date
        # @param date [String] the first release date (YYYY, YYYY-MM, or YYYY-MM-DD)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_first_release_date(date, options = {})
          search_by_field("firstreleasedate", date, options)
        end

        # Search for release groups by primary type (Album, Single, EP, etc.)
        # @param primary_type [String] the primary type (e.g., "Album", "Single", "EP")
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_primary_type(primary_type, options = {})
          search_by_field("primarytype", primary_type, options)
        end

        # Search for release groups by secondary type (Compilation, Live, Soundtrack, etc.)
        # @param secondary_type [String] the secondary type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_secondary_type(secondary_type, options = {})
          search_by_field("secondarytype", secondary_type, options)
        end

        # Search for release groups by alias
        # @param alias_name [String] the alias to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_alias(alias_name, options = {})
          search_by_field("alias", alias_name, options)
        end

        # Search for release groups by credited artist name
        # @param credit_name [String] the credited artist name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_credit_name(credit_name, options = {})
          search_by_field("creditname", credit_name, options)
        end

        # Search for release groups by release MBID
        # @param release_mbid [String] the release MBID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release_mbid(release_mbid, options = {})
          search_by_field("reid", release_mbid, options)
        end

        # Search for release groups by release title
        # @param release_title [String] the release title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release_title(release_title, options = {})
          search_by_field("release", release_title, options)
        end

        # Search for release groups by number of releases
        # @param count [Integer] the number of releases
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release_count(count, options = {})
          search_by_field("releases", count.to_s, options)
        end

        # Search for primary albums only (no secondary types like Compilation, Soundtrack, etc.)
        # This is useful for finding official studio albums
        # @param artist_mbid [String, nil] optional artist MBID to filter by
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_primary_albums_only(artist_mbid = nil, options = {})
          query_parts = []
          query_parts << "primarytype:Album"
          query_parts << "-secondarytype:*"  # Exclude any secondary types
          query_parts << "status:Official"   # Only official releases

          if artist_mbid
            query_parts << build_field_query("arid", artist_mbid)
          end

          query = query_parts.join(" AND ")
          search(query, options)
        end

        # Search for albums by artist and title (common use case)
        # @param artist_name [String] the artist name
        # @param title [String] the album title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_and_title(artist_name, title, options = {})
          artist_query = build_field_query("artist", artist_name)
          # Use releasegroup field instead of title - it properly indexes Unicode
          # characters and also matches aliases (e.g., "cross" matches "✝")
          title_query = build_field_query("releasegroup", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for albums by artist MBID and title (most precise search)
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param title [String] the album title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid_and_title(artist_mbid, title, options = {})
          artist_query = build_field_query("arid", artist_mbid)
          # Use releasegroup field instead of title - it properly indexes Unicode
          # characters and also matches aliases (e.g., "cross" matches "✝")
          title_query = build_field_query("releasegroup", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for albums by artist with optional filters
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param filters [Hash] additional filters (type:, country:, date:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_artist_albums(artist_mbid, filters = {}, options = {})
          criteria = {arid: artist_mbid}.merge(filters)
          search_with_criteria(criteria, options)
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

        # Build a complex query with multiple criteria
        # @param criteria [Hash] search criteria (title:, arid:, type:, etc.)
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

        # Lookup release group by MusicBrainz ID using direct lookup API
        # Uses MusicBrainz lookup endpoint (/ws/2/release-group/{mbid}) for direct access
        # @param mbid [String] the MusicBrainz Release Group ID (UUID format)
        # @param options [Hash] additional options (inc parameter, etc.)
        # @return [Hash] lookup results with complete release group data
        def lookup_by_release_group_mbid(mbid, options = {})
          validate_mbid!(mbid)
          # Add inc parameter for artist-credits and genres, but don't override user's inc
          default_inc = "artist-credits+genres"
          enhanced_options = if options[:inc]
            options.merge(inc: "#{options[:inc]}+#{default_inc}")
          else
            options.merge(inc: default_inc)
          end

          response = client.get("release-group/#{mbid}", enhanced_options)
          process_lookup_response(response)
        rescue Music::Musicbrainz::Exceptions::QueryError
          # Re-raise validation errors instead of catching them
          raise
        rescue Music::Musicbrainz::Exceptions::Error => e
          handle_lookup_error(e, mbid, options)
        end

        private

        # Process lookup response - single item instead of array
        # @param response [Hash] the raw API response
        # @return [Hash] processed response with single release group wrapped in array
        def process_lookup_response(response)
          return response unless response[:success]

          # Wrap single release group result in array to match search format
          if response[:data].is_a?(Hash) && response[:data]["title"]
            response[:data] = {"release-groups" => [response[:data]]}
          end

          process_search_response(response)
        end

        # Handle lookup errors with context
        # @param error [Music::Musicbrainz::Exceptions::Error] the error that occurred
        # @param mbid [String] the MusicBrainz ID
        # @param options [Hash] lookup options
        # @return [Hash] error response
        def handle_lookup_error(error, mbid, options)
          {
            success: false,
            data: nil,
            errors: [error.message],
            metadata: {
              entity_type: entity_type,
              mbid: mbid,
              options: options,
              error_type: error.class.name
            }
          }
        end
      end
    end
  end
end
