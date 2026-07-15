# frozen_string_literal: true

module Search
  module Books
    module Search
      class BookGeneral < ::Search::Base::Search
        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0
          book_kind = options.fetch(:book_kind, "standalone")

          query_definition = build_query_definition(text, min_score, size, from, book_kind)

          Rails.logger.info "Book search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from, book_kind = "standalone")
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_text, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_text.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("title", cleaned_text, boost: 8.0, operator: "and"),
            ::Search::Shared::Utils.build_match_query("alternate_titles", cleaned_text, boost: 7.0),
            ::Search::Shared::Utils.build_match_phrase_query("author_names", cleaned_text, boost: 6.0),
            ::Search::Shared::Utils.build_match_query("author_names", cleaned_text, boost: 5.0, operator: "and"),
            ::Search::Shared::Utils.build_match_query("subtitle", cleaned_text, boost: 4.0, operator: "and")
          ]

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              should: should_clauses,
              filter: book_kind.nil? ? [] : [{term: {book_kind: book_kind}}],
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
