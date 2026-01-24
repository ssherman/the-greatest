# frozen_string_literal: true

module Search
  module Music
    module Search
      class ArtistAutocomplete < ::Search::Base::Search
        def self.index_name
          ::Search::Music::ArtistIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 0.1
          size = options[:size] || 20
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            ::Search::Shared::Utils.build_match_query("name.autocomplete", cleaned_text, boost: 10.0),
            ::Search::Shared::Utils.build_match_phrase_query("name", cleaned_text, boost: 8.0),
            ::Search::Shared::Utils.build_term_query("name.keyword", cleaned_text.downcase, boost: 6.0)
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
