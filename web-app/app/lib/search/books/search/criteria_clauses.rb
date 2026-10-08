# frozen_string_literal: true

module Search
  module Books
    module Search
      # The OpenSearch filter and must_not clauses a Books::SavedSearchCriteria
      # implies. Shared by BookAdvanced (saved searches) and BookRecommendations
      # (the recommendation engine) so the two can never disagree about what a
      # criterion means. Pure: no database, no OpenSearch.
      module CriteriaClauses
        # OpenSearch's match-nothing: an empty terms array matches no document,
        # regardless of which field it names. Used any time a criterion is
        # present but cannot be resolved -- see `unparseable_clauses` below and
        # the book_type-specific case in `filter_clauses` (spec §6: a criterion
        # that is present but unresolvable must match nothing, never
        # everything).
        MATCH_NOTHING_CLAUSE = {terms: {category_ids: []}}.freeze

        module_function

        def filter_clauses(criteria)
          clauses = []
          clauses.concat(category_clauses(criteria))
          clauses.concat(unparseable_clauses(criteria))

          unless criteria.book_type.nil?
            category_id = ::Books::BookType.category_id(criteria.book_type)
            # A book_type we cannot resolve must match NOTHING, not everything: dropping
            # the clause would turn an unresolvable criterion into a match-all. An empty
            # terms array is OpenSearch's match-nothing.
            clauses << (category_id ? {term: {category_ids: category_id}} : MATCH_NOTHING_CLAUSE)
          end

          languages = criteria.included_language_ids
          clauses << {terms: {original_language_id: languages}} if languages.any?

          countries = criteria.included_country_ids
          clauses << {terms: {country_ids: countries}} if countries.any?

          lengths = criteria.book_length
          clauses << {terms: {book_length: lengths}} if lengths.any?

          year = year_range(criteria)
          clauses << {range: {first_published_year: year}} if year.any?

          clauses << {exists: {field: "ranked_position"}} if criteria.ranked == :ranked

          max_position = criteria.max_ranked_position
          clauses << {range: {ranked_position: {lte: max_position}}} if max_position

          clauses
        end

        # `all` means a book must carry every category, which one terms clause
        # cannot express -- terms is an OR. One term filter per id is the AND.
        def category_clauses(criteria)
          ids = criteria.included_category_ids
          return [] if ids.empty?
          return [{terms: {category_ids: ids}}] if criteria.genre_match_mode == :any

          ids.map { |id| {term: {category_ids: id}} }
        end

        # One MATCH_NOTHING_CLAUSE per criterion that is present but did not
        # parse (spec §6). Placed in `filter`, which ANDs with everything
        # else, so this forces the whole query to zero hits regardless of
        # whether the source criterion was itself an include or an exclude --
        # an unparseable excluded_category_ids must not silently exclude
        # nothing (a broadening no-op), which is what it would do if this
        # clause were built as a must_not instead. The criteria that are
        # merely absent (blank raw value) contribute nothing here, same as
        # every other clause in this class.
        def unparseable_clauses(criteria)
          ::Books::SavedSearchCriteria::UNPARSEABLE_KEYS
            .select { |key| criteria.unparseable?(key) }
            .map { MATCH_NOTHING_CLAUSE }
        end

        def year_range(criteria)
          range = {}
          gt = criteria.first_year_published_gt
          lt = criteria.first_year_published_lt
          range[:gte] = gt if gt
          range[:lte] = lt if lt
          range
        end

        def must_not_clauses(criteria, excluded_book_ids)
          clauses = []

          categories = criteria.excluded_category_ids
          clauses << {terms: {category_ids: categories}} if categories.any?

          languages = criteria.excluded_language_ids
          clauses << {terms: {original_language_id: languages}} if languages.any?

          countries = criteria.excluded_country_ids
          clauses << {terms: {country_ids: countries}} if countries.any?

          clauses << {exists: {field: "ranked_position"}} if criteria.ranked == :unranked

          clauses << {ids: {values: excluded_book_ids}} if excluded_book_ids.any?

          clauses << ::Search::Books::BookIndex::EXCLUDE_PROVISIONAL

          clauses
        end
      end
    end
  end
end
