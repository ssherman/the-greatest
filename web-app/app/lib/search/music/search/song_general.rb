# frozen_string_literal: true

module Search
  module Music
    module Search
      class SongGeneral < ::Search::Base::Search
        def self.index_name
          ::Search::Music::SongIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          Rails.logger.info "Song search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            # Exact match on title gets highest boost
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_text, boost: 10.0),

            # Regular match on title with high boost
            ::Search::Shared::Utils.build_match_query("title", cleaned_text, boost: 8.0),

            # Keyword exact match for precise title matches
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_text.downcase, boost: 9.0),

            # Artist name match with medium boost
            ::Search::Shared::Utils.build_match_query("artist_names", cleaned_text, boost: 5.0),

            # Artist name phrase match
            ::Search::Shared::Utils.build_match_phrase_query("artist_names", cleaned_text, boost: 6.0)
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
