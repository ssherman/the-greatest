# frozen_string_literal: true

module Search
  module Shared
    class Utils
      class << self
        def cleanup_for_indexing(text_array)
          return [] if text_array.blank?

          text_array.map do |text|
            next if text.blank?

            # Remove special characters and normalize
            cleaned = text.to_s
              .strip
              .gsub(/[^\w\s\-'"]/, " ")  # Replace special chars with space
              .gsub(/\s+/, " ")          # Collapse multiple spaces
              .strip

            cleaned.blank? ? nil : cleaned
          end.compact
        end

        def normalize_search_text(text)
          return "" if text.blank?

          text.to_s
            .strip
            .downcase
            .gsub(/[^\w\s\-']/, " ")  # Replace special chars with space
            .gsub(/\s+/, " ")         # Collapse multiple spaces
            .strip
        end

        def build_match_query(field, query, boost: 1.0, operator: "or")
          {
            match: {
              field => {
                query: query,
                boost: boost,
                operator: operator
              }
            }
          }
        end

        def build_match_phrase_query(field, query, boost: 1.0)
          {
            match_phrase: {
              field => {
                query: query,
                boost: boost
              }
            }
          }
        end

        def build_term_query(field, value, boost: 1.0)
          {
            term: {
              field => {
                value: value,
                boost: boost
              }
            }
          }
        end

        def build_bool_query(must: [], should: [], must_not: [], filter: [], minimum_should_match: nil)
          query = {bool: {}}

          query[:bool][:must] = must if must.any?
          query[:bool][:should] = should if should.any?
          query[:bool][:must_not] = must_not if must_not.any?
          query[:bool][:filter] = filter if filter.any?
          query[:bool][:minimum_should_match] = minimum_should_match if minimum_should_match

          query
        end
      end
    end
  end
end
