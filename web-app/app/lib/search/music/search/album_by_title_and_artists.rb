# frozen_string_literal: true

module Search
  module Music
    module Search
      class AlbumByTitleAndArtists < ::Search::Base::Search
        def self.index_name
          ::Search::Music::AlbumIndex.index_name
        end

        def self.call(title:, artists:, **options)
          return empty_response if title.blank?
          return empty_response if artists.blank? || !artists.is_a?(Array)

          min_score = options[:min_score] || 5.0
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(title, artists, min_score, size, from)

          Rails.logger.info "Album title+artists search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(title, artists, min_score, size, from)
          cleaned_title = ::Search::Shared::Utils.normalize_search_text(title)

          must_clauses = build_title_clauses(cleaned_title)
          should_clauses = build_artist_clauses(artists)

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              must: [
                ::Search::Shared::Utils.build_bool_query(
                  should: must_clauses,
                  minimum_should_match: 1
                )
              ],
              should: should_clauses,
              minimum_should_match: 1
            )
          }
        end

        def self.build_title_clauses(cleaned_title)
          [
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_title, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_title.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("title", cleaned_title, boost: 8.0, operator: "and")
          ]
        end

        def self.build_artist_clauses(artists)
          clauses = []

          artists.each do |artist_name|
            next if artist_name.blank?

            cleaned_artist = ::Search::Shared::Utils.normalize_search_text(artist_name)

            clauses << ::Search::Shared::Utils.build_match_phrase_query("artist_names", cleaned_artist, boost: 6.0)
            clauses << ::Search::Shared::Utils.build_match_query("artist_names", cleaned_artist, boost: 5.0, operator: "and")
          end

          clauses
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response, :build_title_clauses, :build_artist_clauses
      end
    end
  end
end
