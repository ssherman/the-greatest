# frozen_string_literal: true

module Search
  module Books
    module Search
      # The books finder's OpenSearch source: candidates for "is this
      # title (by these authors, from this year) already in the catalog?".
      # The title, or an alternate title, is required; authors and year are
      # boosts. A title-only query is held to a higher minimum score because
      # a bare title is ambiguous in books.
      class BookByTitleAndAuthors < ::Search::Base::Search
        MIN_SCORE_WITH_AUTHORS = 5.0
        MIN_SCORE_TITLE_ONLY = 8.0

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(title:, authors: [], year: nil, **options)
          return empty_response if title.blank?
          return empty_response if ::Search::Shared::Utils.normalize_search_text(title).blank?

          authors = Array(authors).compact_blank
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(title, authors, year, options[:min_score], size, from)

          Rails.logger.info "Book title+authors search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(title, authors, year, min_score, size, from)
          cleaned_title = ::Search::Shared::Utils.normalize_search_text(title)
          author_clauses = build_author_clauses(authors)
          min_score ||= author_clauses.any? ? MIN_SCORE_WITH_AUTHORS : MIN_SCORE_TITLE_ONLY

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              must: [
                ::Search::Shared::Utils.build_bool_query(
                  should: build_title_clauses(cleaned_title),
                  minimum_should_match: 1
                )
              ],
              should: author_clauses + build_year_clauses(year)
            )
          }
        end

        # alternate_titles is inside the required group on purpose: the
        # merger folds a merged-away title into it so the deleted spelling
        # stays findable here.
        def self.build_title_clauses(cleaned_title)
          [
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_title, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_title.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("title", cleaned_title, boost: 8.0, operator: "and"),
            ::Search::Shared::Utils.build_match_phrase_query("alternate_titles", cleaned_title, boost: 7.0),
            ::Search::Shared::Utils.build_match_query("alternate_titles", cleaned_title, boost: 6.0, operator: "and")
          ]
        end

        def self.build_author_clauses(authors)
          authors.flat_map do |author_name|
            cleaned_author = ::Search::Shared::Utils.normalize_search_text(author_name)
            next [] if cleaned_author.blank?

            [
              ::Search::Shared::Utils.build_match_phrase_query("author_names", cleaned_author, boost: 6.0),
              ::Search::Shared::Utils.build_match_query("author_names", cleaned_author, boost: 5.0, operator: "and")
            ]
          end
        end

        def self.build_year_clauses(year)
          return [] if year.blank?

          [{range: {first_published_year: {gte: year.to_i - 1, lte: year.to_i + 1, boost: 2.0}}}]
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_title_clauses, :build_author_clauses, :build_year_clauses
      end
    end
  end
end
