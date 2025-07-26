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
            title rgid arid artist artistname tag type
            country date firstreleasedate status comment
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

        # Search for albums by artist and title (common use case)
        # @param artist_name [String] the artist name
        # @param title [String] the album title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_and_title(artist_name, title, options = {})
          artist_query = build_field_query("artist", artist_name)
          title_query = build_field_query("title", title)
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
          title_query = build_field_query("title", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for albums by artist with optional filters
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param filters [Hash] additional filters (type:, country:, date:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_artist_albums(artist_mbid, filters = {}, options = {})
          criteria = { arid: artist_mbid }.merge(filters)
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
          rescue Music::Musicbrainz::Error => e
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
              raise QueryError, "Invalid search field: #{field}"
            end
          end
          
          if query_parts.empty?
            raise QueryError, "At least one search criterion must be provided"
          end
          
          query = query_parts.join(" AND ")
          search(query, options)
        end
      end
    end
  end
end 