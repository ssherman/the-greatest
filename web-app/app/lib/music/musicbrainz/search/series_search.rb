# frozen_string_literal: true

module Music
  module Musicbrainz
    module Search
      class SeriesSearch < BaseSearch
        # Get the entity type for series searches
        # @return [String] the entity type
        def entity_type
          "series"
        end

        # Get the MBID field name for series
        # @return [String] the MBID field name
        def mbid_field
          "sid"
        end

        # Get available search fields for series
        # @return [Array<String>] list of searchable fields
        def available_fields
          %w[
            series seriesaccent alias comment sid tag type
          ]
        end

        # Search for series by name
        # @param name [String] the series name to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_name(name, options = {})
          search_by_field("series", name, options)
        end

        # Search for series by name with diacritics
        # @param name [String] the series name with diacritics to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_name_with_diacritics(name, options = {})
          search_by_field("seriesaccent", name, options)
        end

        # Search for series by alias
        # @param alias_name [String] the alias to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_alias(alias_name, options = {})
          search_by_field("alias", alias_name, options)
        end

        # Search for series by type (focus on "Release group series")
        # @param type [String] the series type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_type(type, options = {})
          search_by_field("type", type, options)
        end

        # Search for series by tag
        # @param tag [String] the tag to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_tag(tag, options = {})
          search_by_field("tag", tag, options)
        end

        # Search for series by disambiguation comment
        # @param comment [String] the disambiguation comment
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_comment(comment, options = {})
          search_by_field("comment", comment, options)
        end

        # Browse series with release group relationships
        # Uses the browse API to get series details with release group relationships
        # @param series_mbid [String] the series MusicBrainz ID
        # @param options [Hash] additional options
        # @return [Hash] browse results with release group relationships
        def browse_series_with_release_groups(series_mbid, options = {})
          validate_mbid!(series_mbid)

          # Use direct lookup API for series with release group relationships
          # This uses /ws/2/series/{mbid}?inc=release-group-rels
          enhanced_options = options.merge(inc: "release-group-rels")

          begin
            response = client.get("series/#{series_mbid}", enhanced_options)
            process_browse_response(response)
          rescue Music::Musicbrainz::Exceptions::Error => e
            handle_browse_error(e, {series_mbid: series_mbid}, options)
          end
        end

        # Browse series with recording relationships
        # Uses the browse API to get series details with recording relationships
        # @param series_mbid [String] the series MusicBrainz ID
        # @param options [Hash] additional options
        # @return [Hash] browse results with recording relationships
        def browse_series_with_recordings(series_mbid, options = {})
          validate_mbid!(series_mbid)

          # Use direct lookup API for series with recording relationships
          # This uses /ws/2/series/{mbid}?inc=recording-rels
          enhanced_options = options.merge(inc: "recording-rels")

          begin
            response = client.get("series/#{series_mbid}", enhanced_options)
            process_browse_response(response)
          rescue Music::Musicbrainz::Exceptions::Error => e
            handle_browse_error(e, {series_mbid: series_mbid}, options)
          end
        end

        # Search for "Release group series" specifically (most common use case)
        # @param name [String] optional series name to search for
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_release_group_series(name = nil, options = {})
          criteria = {type: "Release group series"}
          criteria[:series] = name if name.present?

          search_with_criteria(criteria, options)
        end

        # Search for series by name and type combination
        # @param name [String] the series name
        # @param type [String] the series type
        # @param options [Hash] additional search options
        # @return [Hash] search results
        def search_by_name_and_type(name, type, options = {})
          criteria = {series: name, type: type}
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
        # @param criteria [Hash] search criteria (series:, type:, tag:, etc.)
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

        # Process browse response for series lookup
        # @param response [Hash] the raw API response
        # @return [Hash] processed response
        def process_browse_response(response)
          return response unless response[:success]

          # For series browse, we get a single series object rather than a list
          if response[:data] && response[:data]["series"]
            # Transform the single series object to match search response format
            series_data = response[:data]["series"]
            created_time = response[:data]["created"] || Time.current.iso8601
            response[:data] = {
              "count" => 1,
              "offset" => 0,
              "results" => [series_data],
              "created" => created_time
            }
          end

          response
        end
      end
    end
  end
end
