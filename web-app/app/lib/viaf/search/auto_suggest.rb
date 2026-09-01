# frozen_string_literal: true

module Viaf
  module Search
    # Cheap candidate resolution. 3 KB returns ten ranked candidates carrying
    # VIAF IDs, name types, dates embedded in the heading, and agency IDs.
    class AutoSuggest
      ENDPOINT = "viaf/AutoSuggest"

      def initialize(client = nil)
        @client = client || BaseClient.new
      end

      def call(query)
        raise ArgumentError, "query cannot be blank" if query.blank?

        response = @client.get(ENDPOINT, {query: query})
        data = response[:data]
        unless data.is_a?(Hash)
          raise Exceptions::ParseError.new("Expected a Hash response body", data.to_s[0, 500])
        end

        Normalizer.array(data["result"]).map do |result|
          Suggestion.from_result(result)
        end
      end
    end
  end
end
