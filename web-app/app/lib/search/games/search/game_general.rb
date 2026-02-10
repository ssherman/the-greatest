# frozen_string_literal: true

module Search
  module Games
    module Search
      class GameGeneral < ::Search::Base::Search
        def self.index_name
          ::Search::Games::GameIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          Rails.logger.info "Game search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            # Exact match on title gets highest boost
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_text, boost: 10.0),

            # Keyword exact match for precise title matches
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_text.downcase, boost: 9.0),

            # Regular match on title with high boost (requires all words)
            ::Search::Shared::Utils.build_match_query("title", cleaned_text, boost: 8.0, operator: "and"),

            # Developer name phrase match
            ::Search::Shared::Utils.build_match_phrase_query("developer_names", cleaned_text, boost: 6.0),

            # Developer name match with medium boost (requires all words)
            ::Search::Shared::Utils.build_match_query("developer_names", cleaned_text, boost: 5.0, operator: "and")
          ]

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              should: should_clauses,
              minimum_should_match: 1
            )
          }
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response
      end
    end
  end
end
