# frozen_string_literal: true

module Search
  module Books
    module Search
      # The authors finder's OpenSearch source: candidates for "is this
      # person already in the catalog?". The name, or an alternate name, is
      # required; the query's own alternate names are boosts.
      # alternate_names sits inside the required group because the merger
      # folds a merged-away name into it, so the deleted spelling stays
      # findable here (the same reasoning as BookByTitleAndAuthors).
      class AuthorByName < ::Search::Base::Search
        MIN_SCORE = 5.0

        def self.index_name
          ::Search::Books::AuthorIndex.index_name
        end

        def self.call(name:, alternate_names: [], **options)
          return empty_response if name.blank?

          cleaned_name = ::Search::Shared::Utils.normalize_search_text(name)
          return empty_response if cleaned_name.blank?

          size = options[:size] || 10
          from = options[:from] || 0
          min_score = options[:min_score] || MIN_SCORE

          query_definition = build_query_definition(cleaned_name, Array(alternate_names), min_score, size, from)

          Rails.logger.debug { "Author by name search query: #{query_definition.inspect}" }

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(cleaned_name, alternate_names, min_score, size, from)
          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              must: [
                ::Search::Shared::Utils.build_bool_query(
                  should: build_name_clauses(cleaned_name),
                  minimum_should_match: 1
                )
              ],
              should: build_alternate_clauses(alternate_names)
            )
          }
        end

        def self.build_name_clauses(cleaned_name)
          [
            ::Search::Shared::Utils.build_match_phrase_query("name", cleaned_name, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("name.keyword", cleaned_name.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("name", cleaned_name, boost: 8.0, operator: "and"),
            ::Search::Shared::Utils.build_match_phrase_query("alternate_names", cleaned_name, boost: 7.0),
            ::Search::Shared::Utils.build_match_query("alternate_names", cleaned_name, boost: 6.0, operator: "and")
          ]
        end

        def self.build_alternate_clauses(alternate_names)
          alternate_names.flat_map do |alternate|
            cleaned = ::Search::Shared::Utils.normalize_search_text(alternate)
            next [] if cleaned.blank?

            [
              ::Search::Shared::Utils.build_match_phrase_query("name", cleaned, boost: 4.0),
              ::Search::Shared::Utils.build_match_phrase_query("alternate_names", cleaned, boost: 3.0)
            ]
          end
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_name_clauses, :build_alternate_clauses
      end
    end
  end
end
