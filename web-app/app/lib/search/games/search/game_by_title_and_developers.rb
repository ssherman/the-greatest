# frozen_string_literal: true

module Search
  module Games
    module Search
      class GameByTitleAndDevelopers < ::Search::Base::Search
        def self.index_name
          ::Search::Games::GameIndex.index_name
        end

        def self.call(title:, artists: [], **options)
          developers = Array(artists)
          return empty_response if title.blank?

          min_score = options[:min_score] || 5.0
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(title, developers, min_score, size, from)

          Rails.logger.info "Game title+developers search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(title, developers, min_score, size, from)
          cleaned_title = ::Search::Shared::Utils.normalize_search_text(title)

          must_clauses = build_title_clauses(cleaned_title)
          should_clauses = build_developer_clauses(developers)

          bool_params = {
            must: [
              ::Search::Shared::Utils.build_bool_query(
                should: must_clauses,
                minimum_should_match: 1
              )
            ]
          }

          # Developer clauses boost score but are not required
          bool_params[:should] = should_clauses if should_clauses.any?

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(**bool_params)
          }
        end

        def self.build_title_clauses(cleaned_title)
          [
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_title, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_title.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("title", cleaned_title, boost: 8.0, operator: "and")
          ]
        end

        def self.build_developer_clauses(developers)
          clauses = []

          developers.each do |developer_name|
            next if developer_name.blank?

            cleaned_developer = ::Search::Shared::Utils.normalize_search_text(developer_name)

            clauses << ::Search::Shared::Utils.build_match_phrase_query("developer_names", cleaned_developer, boost: 6.0)
            clauses << ::Search::Shared::Utils.build_match_query("developer_names", cleaned_developer, boost: 5.0, operator: "and")
          end

          clauses
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_title_clauses, :build_developer_clauses
      end
    end
  end
end
