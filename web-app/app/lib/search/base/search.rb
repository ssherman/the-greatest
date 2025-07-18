# frozen_string_literal: true

module Search
  module Base
    class Search
      def self.client
        @client ||= OpenSearch::Client.new(host: ENV.fetch("OPENSEARCH_URL"))
      end

      def self.index_name
        raise NotImplementedError, "Subclasses must implement index_name"
      end

      def self.search(query_definition)
        response = client.search(
          index: index_name,
          body: query_definition
        )

        Rails.logger.info "Search executed on '#{index_name}' - #{response["hits"]["total"]["value"]} results"
        response
      rescue => e
        Rails.logger.error "Search failed on '#{index_name}'. Error: #{e.message}"
        raise
      end

      def self.raw_search(query_definition, **options)
        search_params = {
          index: index_name,
          body: query_definition
        }.merge(options)

        response = client.search(**search_params)

        Rails.logger.info "Raw search executed on '#{index_name}' - #{response["hits"]["total"]["value"]} results"
        response
      rescue => e
        Rails.logger.error "Raw search failed on '#{index_name}'. Error: #{e.message}"
        raise
      end

      def self.count(query_definition = {})
        response = client.count(
          index: index_name,
          body: query_definition
        )

        response["count"]
      rescue => e
        Rails.logger.error "Count failed on '#{index_name}'. Error: #{e.message}"
        raise
      end

      def self.build_query_definition(query_params)
        raise NotImplementedError, "Subclasses must implement build_query_definition"
      end

      def self.extract_ids(response)
        response["hits"]["hits"].map { |hit| hit["_id"] }
      end

      def self.extract_hits_with_scores(response)
        response["hits"]["hits"].map do |hit|
          {
            id: hit["_id"],
            score: hit["_score"],
            source: hit["_source"]
          }
        end
      end

      def self.default_analyzer
        "folding"
      end

      def self.default_boost_values
        {
          exact_match: 10.0,
          phrase_match: 5.0,
          fuzzy_match: 1.0
        }
      end

      def self.apply_min_score(query_definition, min_score)
        return query_definition unless min_score

        query_definition[:min_score] = min_score
        query_definition
      end

      def self.apply_size_and_from(query_definition, size: 10, from: 0)
        query_definition[:size] = size
        query_definition[:from] = from
        query_definition
      end

      private_class_method :default_analyzer, :default_boost_values, :apply_min_score, :apply_size_and_from
    end
  end
end
