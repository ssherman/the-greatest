# frozen_string_literal: true

module Music
  module Musicbrainz
    module Search
      class WorkSearch < BaseSearch
        # Get the entity type for work searches
        # @return [String] the entity type
        def entity_type
          "work"
        end

        # Get the MBID field name for works
        # @return [String] the MBID field name
        def mbid_field
          "wid"
        end

        # Get available search fields for works
        # @return [Array<String>] list of searchable fields
        def available_fields
          %w[
            work workaccent wid alias arid artist tag type
            comment iswc lang recording recording_count rid
          ]
        end

        # Search for works by title
        # @param title [String] the work title to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_title(title, options = {})
          search_by_field("work", title, options)
        end

        # Search for works by title with diacritics
        # @param title [String] the work title with specific diacritics
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_title_with_accent(title, options = {})
          search_by_field("workaccent", title, options)
        end

        # Search for works by artist MBID
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid(artist_mbid, options = {})
          search_by_field("arid", artist_mbid, options)
        end

        # Search for works by artist name
        # @param artist_name [String] the artist name
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_name(artist_name, options = {})
          search_by_field("artist", artist_name, options)
        end

        # Search for works by alias
        # @param alias_name [String] the alias to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_alias(alias_name, options = {})
          search_by_field("alias", alias_name, options)
        end

        # Search for works by ISWC (International Standard Musical Work Code)
        # @param iswc [String] the ISWC code
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_iswc(iswc, options = {})
          search_by_field("iswc", iswc, options)
        end

        # Search for works by tag
        # @param tag [String] the tag to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_tag(tag, options = {})
          search_by_field("tag", tag, options)
        end

        # Search for works by type (e.g., "song", "symphony", "opera")
        # @param type [String] the work type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_type(type, options = {})
          search_by_field("type", type, options)
        end

        # Search for works by language code
        # @param language_code [String] the ISO 639-3 language code
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_language(language_code, options = {})
          search_by_field("lang", language_code, options)
        end

        # Search for works by related recording title
        # @param recording_title [String] the recording title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_recording_title(recording_title, options = {})
          search_by_field("recording", recording_title, options)
        end

        # Search for works by related recording MBID
        # @param recording_mbid [String] the recording's MusicBrainz ID
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_recording_mbid(recording_mbid, options = {})
          search_by_field("rid", recording_mbid, options)
        end

        # Search for works by number of recordings
        # @param count [Integer] the number of recordings
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_recording_count(count, options = {})
          search_by_field("recording_count", count.to_s, options)
        end

        # Search for works by disambiguation comment
        # @param comment [String] the disambiguation comment
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_comment(comment, options = {})
          search_by_field("comment", comment, options)
        end

        # Search for works by artist and title (common use case)
        # @param artist_name [String] the artist name
        # @param title [String] the work title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_and_title(artist_name, title, options = {})
          artist_query = build_field_query("artist", artist_name)
          title_query = build_field_query("work", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for works by artist MBID and title (most precise search)
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param title [String] the work title
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_artist_mbid_and_title(artist_mbid, title, options = {})
          artist_query = build_field_query("arid", artist_mbid)
          title_query = build_field_query("work", title)
          query = "#{artist_query} AND #{title_query}"
          search(query, options)
        end

        # Search for works by artist with optional filters
        # @param artist_mbid [String] the artist's MusicBrainz ID
        # @param filters [Hash] additional filters (type:, lang:, iswc:, etc.)
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_artist_works(artist_mbid, filters = {}, options = {})
          criteria = {arid: artist_mbid}.merge(filters)
          search_with_criteria(criteria, options)
        end

        # Search for works with recording count in a range
        # @param min_count [Integer] minimum number of recordings
        # @param max_count [Integer] maximum number of recordings
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_recording_count_range(min_count, max_count, options = {})
          query = "recording_count:[#{min_count} TO #{max_count}]"
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
          rescue Music::Musicbrainz::Exceptions::Error => e
            handle_search_error(e, query, options)
          end
        end

        # Build a complex query with multiple criteria
        # @param criteria [Hash] search criteria (work:, arid:, iswc:, etc.)
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
      end
    end
  end
end
