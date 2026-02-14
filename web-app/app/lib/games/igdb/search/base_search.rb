# frozen_string_literal: true

module Games
  module Igdb
    module Search
      class BaseSearch
        attr_reader :client

        def initialize(client = nil)
          @client = client || BaseClient.new
        end

        def endpoint
          raise NotImplementedError, "Subclasses must implement #endpoint"
        end

        def default_fields
          raise NotImplementedError, "Subclasses must implement #default_fields"
        end

        def find_by_id(id, fields: nil)
          validate_id!(id)
          query = Query.new
            .fields(*(fields || default_fields))
            .where(id: id)
          execute(query)
        end

        def find_by_ids(ids, fields: nil)
          ids.each { |id| validate_id!(id) }
          query = Query.new
            .fields(*(fields || default_fields))
            .where(id: ids)
          execute(query)
        end

        def search(term, fields: nil, limit: 10, offset: nil)
          query = Query.new
            .fields(*(fields || default_fields))
            .search(term)
            .limit(limit)
          query = query.offset(offset) if offset
          execute(query)
        end

        def where(conditions, fields: nil, sort: nil, limit: 10, offset: nil)
          query = Query.new
            .fields(*(fields || default_fields))
            .where(conditions)
            .limit(limit)
          query = query.sort(*sort) if sort
          query = query.offset(offset) if offset
          execute(query)
        end

        def all(fields: nil, limit: 10, offset: nil, sort: nil)
          query = Query.new
            .fields(*(fields || default_fields))
            .limit(limit)
          query = query.sort(*sort) if sort
          query = query.offset(offset) if offset
          execute(query)
        end

        def count(conditions = nil)
          endpoint_with_count = "#{endpoint}/count"
          query = if conditions
            Query.new.where(conditions)
          else
            Query.new.fields_all
          end

          begin
            client.post(endpoint_with_count, query.to_s)
          rescue Exceptions::Error => e
            handle_error(e, query.to_s)
          end
        end

        protected

        def execute(query)
          query_string = query.to_s

          begin
            client.post(endpoint, query_string)
          rescue Exceptions::Error => e
            handle_error(e, query_string)
          end
        end

        def handle_error(error, query_string)
          {
            success: false,
            data: nil,
            errors: [error.message],
            metadata: {
              endpoint: endpoint,
              query: query_string,
              error_type: error.class.name
            }
          }
        end

        private

        def validate_id!(id)
          unless id.is_a?(Integer) && id > 0
            raise Exceptions::QueryError, "Invalid IGDB ID: #{id.inspect} (must be a positive integer)"
          end
        end
      end
    end
  end
end
