# frozen_string_literal: true

module Search
  module Books
    module Search
      # One OpenSearch query scoring ranked books against a user's taste profile
      # (spec §7). Hard constraints (the user's criteria, their shelf, provisional
      # books) live in filter/must_not and contribute no score; the profile's
      # categories are one boosted `term` clause EACH so shared categories add up
      # (a single `terms` clause would score once -- see BookSimilar for the
      # measurement); disliked categories and the opposite book type sit in a
      # `boosting` query's negative half so they scale a score down rather than
      # remove the book; and the sum is divided by sqrt(category count) with a
      # floor, exactly as BookSimilar does, so a heavily tagged book cannot win
      # by volume. Finally, when `quality_scale` is positive, the score is
      # multiplied by a rank decay with a floor, so the global ranking shapes
      # the pool itself rather than only re-ordering it in fusion.
      class BookRecommendations < ::Search::Base::Search
        FIELDS = {"genre" => :genre_category_ids, "subject" => :subject_category_ids, "location" => :location_category_ids}.freeze
        MULTIPLIERS = {"genre" => :genre_multiplier, "subject" => :subject_multiplier, "location" => :location_multiplier}.freeze
        RANK_SORT = [{ranked_position: {order: "asc", missing: "_last"}}, {_id: {order: "asc"}}].freeze
        # floor + (1 − floor) · scale / (scale + rank): 1 at the top, half way to
        # the floor at rank = scale, the floor alone for a book with no rank.
        QUALITY_PRIOR_SOURCE = "if (doc['ranked_position'].size() == 0) { return params.floor; } " \
          "return params.floor + (1 - params.floor) * params.scale / (params.scale + doc['ranked_position'].value);"

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(profile:, criteria:, excluded_ids:, type_category_ids:, options: {})
          return [] if profile.empty?

          opts = Rails.application.config.x.recommendations.merge(options)
          extract(search(build_query_definition(profile: profile, criteria: criteria, excluded_ids: excluded_ids,
            type_category_ids: type_category_ids, opts: opts)))
        end

        # The same pool and constraints with no taste applied: the cold-start
        # fallback, the harness's rank baseline, and (with `ids`) the filter
        # the collaborative signal passes its candidates through so every
        # setting applies to that list exactly as to the taste list (spec 2 §6).
        def self.ranked_only(criteria:, excluded_ids:, options: {}, ids: nil)
          opts = Rails.application.config.x.recommendations.merge(options)
          search_criteria = criteria.to_search_criteria
          filter = CriteriaClauses.filter_clauses(search_criteria)
          filter << {ids: {values: ids.map(&:to_s)}} if ids
          extract(search({
            size: opts[:candidate_size],
            _source: false,
            docvalue_fields: ["ranked_position"],
            sort: RANK_SORT,
            query: {bool: {
              filter: filter,
              must_not: CriteriaClauses.must_not_clauses(search_criteria, excluded_ids)
            }}
          }))
        end

        def self.build_query_definition(profile:, criteria:, excluded_ids:, type_category_ids:, opts:)
          search_criteria = criteria.to_search_criteria
          positive = {bool: {
            filter: CriteriaClauses.filter_clauses(search_criteria),
            must_not: CriteriaClauses.must_not_clauses(search_criteria, excluded_ids),
            should: should_clauses(profile, opts),
            # Explicit: a bool carrying a `filter` defaults its should-minimum to 0.
            minimum_should_match: 1
          }}

          negatives = negative_clauses(profile, type_category_ids, opts)
          query = if negatives.any?
            {boosting: {positive: positive, negative: {bool: {should: negatives, minimum_should_match: 1}},
                        negative_boost: opts[:negative_boost]}}
          else
            positive
          end

          {
            size: opts[:candidate_size],
            min_score: opts[:min_score],
            _source: false,
            docvalue_fields: ["ranked_position"],
            query: wrap_in_quality_prior(wrap_in_normalization(query, opts), opts)
          }
        end

        def self.should_clauses(profile, opts)
          {"genre" => profile.genres, "subject" => profile.subjects, "location" => profile.locations}
            .flat_map do |type, pairs|
              pairs.map do |id, weight|
                {term: {FIELDS.fetch(type) => {value: id.to_s, boost: (weight * opts[MULTIPLIERS.fetch(type)]).round(4)}}}
              end
            end
        end

        # Demoted categories, plus the opposite book type when the reader's fiction
        # share is extreme. "Opposite AND not also ours" so books tagged both are
        # untouched -- the same shape as BookSimilar.opposite_type_clause.
        def self.negative_clauses(profile, type_category_ids, opts)
          clauses = profile.demoted.map { |id| {term: {category_ids: id.to_s}} }
          fiction = type_category_ids["Fiction"]
          nonfiction = type_category_ids["Nonfiction"]
          share = profile.fiction_share
          if fiction && nonfiction && share
            same, opposite = if share >= opts[:fiction_share_high]
              [fiction, nonfiction]
            elsif share <= opts[:fiction_share_low]
              [nonfiction, fiction]
            end
            if same
              clauses << {bool: {must: [{term: {genre_category_ids: opposite.to_s}}],
                                 must_not: [{term: {genre_category_ids: same.to_s}}]}}
            end
          end
          clauses
        end

        def self.wrap_in_normalization(query, opts)
          CategoryCountNormalization.wrap(query, floor: opts[:normalization_floor])
        end

        def self.wrap_in_quality_prior(query, opts)
          scale = opts[:quality_scale].to_f
          return query unless scale.positive?

          {
            function_score: {
              query: query,
              script_score: {script: {source: QUALITY_PRIOR_SOURCE, params: {floor: opts[:quality_floor].to_f, scale: scale}}},
              boost_mode: "multiply"
            }
          }
        end

        def self.extract(response)
          response["hits"]["hits"].map do |hit|
            {id: hit["_id"].to_i, score: hit["_score"].to_f, rank_position: hit.dig("fields", "ranked_position")&.first}
          end
        end

        private_class_method :should_clauses, :negative_clauses, :wrap_in_normalization, :wrap_in_quality_prior, :extract
      end
    end
  end
end
