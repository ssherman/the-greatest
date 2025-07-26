# frozen_string_literal: true

module Music
  module Musicbrainz
    # Load exception classes
    require_relative "../exceptions"

    module Search
      class BaseSearch
        attr_reader :client

        def initialize(client = nil)
          @client = client || BaseClient.new
        end

        # Perform a search query
        # @param query [String] the search query
        # @param options [Hash] additional search options
        # @return [Hash] search results with metadata
        def search(query, options = {})
          raise NotImplementedError, "Subclasses must implement #search"
        end

        # Search by MBID (MusicBrainz ID)
        # @param mbid [String] the MusicBrainz ID
        # @param options [Hash] additional options
        # @return [Hash] search results
        def find_by_mbid(mbid, options = {})
          validate_mbid!(mbid)
          search_by_field(mbid_field, mbid, options)
        end

        # Get the entity type for this search (e.g., "artist", "release")
        # @return [String] the entity type
        def entity_type
          raise NotImplementedError, "Subclasses must implement #entity_type"
        end

        # Get the MBID field name for this entity (e.g., "arid", "rgid")
        # @return [String] the MBID field name
        def mbid_field
          raise NotImplementedError, "Subclasses must implement #mbid_field"
        end

        # Get available search fields for this entity
        # @return [Array<String>] list of searchable fields
        def available_fields
          raise NotImplementedError, "Subclasses must implement #available_fields"
        end

        protected

        # Search by a specific field
        # @param field [String] the field name
        # @param value [String] the field value
        # @param options [Hash] additional options
        # @return [Hash] search results
        def search_by_field(field, value, options = {})
          query = build_field_query(field, value)
          params = build_search_params(query, options)

          begin
            response = client.get(entity_type, params)
            process_search_response(response)
          rescue Music::Musicbrainz::Error => e
            handle_search_error(e, query, options)
          end
        end

        # Build a field-specific query
        # @param field [String] the field name
        # @param value [String] the field value
        # @return [String] the formatted query
        def build_field_query(field, value)
          # Escape special Lucene characters in the value
          escaped_value = escape_lucene_query(value)
          "#{field}:#{escaped_value}"
        end

        # Build search parameters for the API request
        # @param query [String] the search query
        # @param options [Hash] additional options
        # @return [Hash] API parameters
        def build_search_params(query, options = {})
          params = {query: query}

          # Add pagination parameters
          params[:limit] = options[:limit] if options[:limit]
          params[:offset] = options[:offset] if options[:offset]

          # Add dismax parameter for simpler queries
          params[:dismax] = options[:dismax] if options.key?(:dismax)

          validate_search_params!(params)
          params
        end

        # Process the search response and add entity-specific data
        # @param response [Hash] the raw API response
        # @return [Hash] processed response
        def process_search_response(response)
          return response unless response[:success]

          # Add entity-specific processing
          response[:data] = process_entity_data(response[:data]) if response[:data]
          response
        end

        # Process entity-specific data (override in subclasses)
        # @param data [Hash] the response data
        # @return [Hash] processed data
        def process_entity_data(data)
          data
        end

        # Handle search errors with context
        # @param error [Music::Musicbrainz::Error] the error that occurred
        # @param query [String] the search query
        # @param options [Hash] search options
        # @return [Hash] error response
        def handle_search_error(error, query, options)
          {
            success: false,
            data: nil,
            errors: [error.message],
            metadata: {
              entity_type: entity_type,
              query: query,
              options: options,
              error_type: error.class.name
            }
          }
        end

        private

        # Validate MBID format
        # @param mbid [String] the MBID to validate
        def validate_mbid!(mbid)
          uuid_pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

          unless mbid.match?(uuid_pattern)
            raise QueryError, "Invalid MBID format: #{mbid}"
          end
        end

        # Validate search parameters
        # @param params [Hash] the parameters to validate
        def validate_search_params!(params)
          if params[:limit] && (params[:limit] < 1 || params[:limit] > 100)
            raise QueryError, "Limit must be between 1 and 100"
          end

          if params[:offset] && params[:offset] < 0
            raise QueryError, "Offset must be non-negative"
          end

          if params[:query].blank?
            raise QueryError, "Query cannot be blank"
          end
        end

        # Escape special Lucene characters in search queries
        # @param query [String] the query to escape
        # @return [String] escaped query
        def escape_lucene_query(query)
          # For now, just escape the most common problematic characters
          # This can be improved later for full Lucene compliance
          escaped = query.dup

          # Escape basic special characters
          escaped.gsub!("\\", "\\\\\\\\")  # Each \ becomes \\
          escaped.gsub!(" ", '\\ ')
          escaped.gsub!(":", '\\:')
          escaped.gsub!("-", '\\-')

          escaped
        end
      end
    end
  end
end
