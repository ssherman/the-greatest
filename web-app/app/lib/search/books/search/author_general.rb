# frozen_string_literal: true

module Search
  module Books
    module Search
      class AuthorGeneral < ::Search::Base::Search
        def self.index_name
          ::Search::Books::AuthorIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          Rails.logger.info "Author search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            ::Search::Shared::Utils.build_match_phrase_query("name", cleaned_text, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("name.keyword", cleaned_text.downcase, boost: 8.0),
            ::Search::Shared::Utils.build_match_query("name", cleaned_text, boost: 5.0, operator: "and"),
            ::Search::Shared::Utils.build_match_query("alternate_names", cleaned_text, boost: 3.0)
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
