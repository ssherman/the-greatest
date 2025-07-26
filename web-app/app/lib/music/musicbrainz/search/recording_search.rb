# frozen_string_literal: true

module Music
  module Musicbrainz
    module Search
      class RecordingSearch < BaseSearch
        # Get the entity type for recording searches
        # @return [String] the entity type
        def entity_type
          "recording"
        end

        # Get the MBID field name for recordings
        # @return [String] the MBID field name
        def mbid_field
          "rid"
        end

        # Get available search fields for recordings
        # @return [Array<String>] list of searchable fields
        def available_fields
          %w[
            title rid arid artist artistname tag type
            country date dur length isrc comment
            release rgid status
          ]
        end

        # Search for recordings by title
        # @param title [String] the recording title to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_title(title, options = {})
          search_by_field("title", title, options)
        end

        # Search for recordings by artist MBID
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid(artist_mbid, options = {})
          search_by_field("arid", artist_mbid, options)
        end

        # Search for recordings by artist name
        # @param artist_name [String] the artist name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_name(artist_name, options = {})
          search_by_field("artist", artist_name, options)
        end

        # Search for recordings by ISRC
        # @param isrc [String] the International Standard Recording Code
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_isrc(isrc, options = {})
          search_by_field("isrc", isrc, options)
        end

        # Search for recordings by tag
        # @param tag [String] the tag to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_tag(tag, options = {})
          search_by_field("tag", tag, options)
        end

        # Search for recordings by duration (in milliseconds)
        # @param duration [Integer] the duration in milliseconds
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_duration(duration, options = {})
          search_by_field("dur", duration.to_s, options)
        end

        # Search for recordings by length (alias for duration)
        # @param length [Integer] the length in milliseconds
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_length(length, options = {})
          search_by_field("length", length.to_s, options)
        end

        # Search for recordings by release group MBID
        # @param release_group_mbid [String] the release group's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release_group_mbid(release_group_mbid, options = {})
          search_by_field("rgid", release_group_mbid, options)
        end

        # Search for recordings by release title
        # @param release_title [String] the release title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_release(release_title, options = {})
          search_by_field("release", release_title, options)
        end

        # Search for recordings by country
        # @param country [String] the country code (e.g., "US", "GB")
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_country(country, options = {})
          search_by_field("country", country, options)
        end

        # Search for recordings by date
        # @param date [String] the date (YYYY, YYYY-MM, or YYYY-MM-DD)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_date(date, options = {})
          search_by_field("date", date, options)
        end

        # Search for songs by artist and title (most common use case)
        # @param artist_name [String] the artist name
        # @param title [String] the song title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_and_title(artist_name, title, options = {})
          artist_query = build_field_query("artist", artist_name)
          title_query = build_field_query("title", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for songs by artist MBID and title (most precise search)
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param title [String] the song title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid_and_title(artist_mbid, title, options = {})
          artist_query = build_field_query("arid", artist_mbid)
          title_query = build_field_query("title", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for recordings by artist with optional filters
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param filters [Hash] additional filters (release:, dur:, isrc:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_artist_recordings(artist_mbid, filters = {}, options = {})
          criteria = {arid: artist_mbid}.merge(filters)
          search_with_criteria(criteria, options)
        end

        # Search for recordings within a duration range
        # @param min_duration [Integer] minimum duration in milliseconds
        # @param max_duration [Integer] maximum duration in milliseconds
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_duration_range(min_duration, max_duration, options = {})
          query = "dur:[#{min_duration} TO #{max_duration}]"
          search(query, options)
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
        # @param criteria [Hash] search criteria (title:, arid:, isrc:, etc.)
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
