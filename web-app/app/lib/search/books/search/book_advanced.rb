# frozen_string_literal: true

module Search
  module Books
    module Search
      # A saved search's criteria as an OpenSearch bool query, returning one
      # page of book ids and the total match count.
      #
      # This class owns EVERY filter, including max_ranked_position and
      # hide_read. OpenSearch sizes the page here, so a filter applied
      # downstream in Postgres would remove rows from a page already counted --
      # short pages under an overstated total.
      #
      # It does no database work: hide_read's ids arrive as excluded_book_ids,
      # looked up by ::Books::SavedSearchQuery.
      class BookAdvanced < ::Search::Base::Search
        # Ranked books first in rank order, then unranked. Mirrors the SQL
        # ordering ::Books::AuthorsController#all_books_relation already ships.
        #
        # `_id` is a final tie-breaker, not a fourth ranking key. Books that tie
        # on all three real keys are common among unranked books (which all tie
        # on key 1): the dev index has 52 books titled "star wars", 40 "d
        # ceased", 32 "batman". Without a deterministic tiebreak, OpenSearch
        # falls back to internal document order, which is not stable across
        # replicas or index merges -- a `from`/`size` page boundary landing
        # inside a tie group can duplicate or skip a book on the next page.
        # `_id` is metadata, not an indexed field, so sorting on it needs no
        # mapping change and costs nothing measurable; an indexed numeric id
        # would need a mapping change, and this codebase's books mapping only
        # changes on a full delete-and-recreate.
        SORT = [
          {ranked_position: {order: "asc", missing: "_last"}},
          {first_published_year: {order: "asc", missing: "_last"}},
          {"title.keyword" => {order: "asc"}},
          {_id: {order: "asc"}}
        ].freeze

        # OpenSearch's match-nothing: an empty terms array matches no document,
        # regardless of which field it names. Used any time a criterion is
        # present but cannot be resolved -- see `unparseable_clauses` below and
        # the book_type-specific case in `filter_clauses` (spec §6: a criterion
        # that is present but unresolvable must match nothing, never
        # everything).
        MATCH_NOTHING_CLAUSE = {terms: {category_ids: []}}.freeze

        DEFAULT_PER_PAGE = 50

        # OpenSearch's ceiling on `from + size` (index.max_result_window,
        # §5.4). A page beyond it is unreachable; we clamp rather than let
        # OpenSearch raise a BadRequest.
        MAX_RESULT_WINDOW = 10_000

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(criteria, page: 1, per_page: DEFAULT_PER_PAGE, excluded_book_ids: [])
          definition = build_query_definition(
            criteria, page: page, per_page: per_page, excluded_book_ids: excluded_book_ids
          )
          response = search(definition)

          # `relation` is "eq" when total is exact and "gte" when
          # track_total_hits stopped counting at its ceiling. Without it, a
          # search matching exactly 10,000 books is indistinguishable from one
          # matching a million, and both render as "10,000+".
          {
            ids: extract_ids(response).map(&:to_i),
            total: response["hits"]["total"]["value"],
            total_relation: response["hits"]["total"]["relation"]
          }
        end

        def self.build_query_definition(criteria, page: 1, per_page: DEFAULT_PER_PAGE, excluded_book_ids: [])
          raise ArgumentError, "page must be >= 1 (got #{page.inspect})" if page < 1

          from = (page - 1) * per_page
          # `from + size` must stay <= MAX_RESULT_WINDOW or OpenSearch raises
          # BadRequest. Beyond the window there is nothing reachable to
          # return, so ask for `from: 0, size: 0` -- zero hits, but `total`
          # still comes back accurate. Within the window, clamp `size` so the
          # last reachable page returns short rather than raising: at the
          # legacy per_page of 120, page 84 computes from 9960 + size 120 =
          # 10080, over the ceiling.
          beyond_window = from >= MAX_RESULT_WINDOW

          {
            query: ::Search::Shared::Utils.build_bool_query(
              filter: filter_clauses(criteria),
              must_not: must_not_clauses(criteria, excluded_book_ids)
            ),
            sort: SORT,
            from: beyond_window ? 0 : from,
            size: beyond_window ? 0 : [per_page, MAX_RESULT_WINDOW - from].min
          }
        end

        def self.filter_clauses(criteria)
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
        def self.category_clauses(criteria)
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
        def self.unparseable_clauses(criteria)
          ::Books::SavedSearchCriteria::UNPARSEABLE_KEYS
            .select { |key| criteria.unparseable?(key) }
            .map { MATCH_NOTHING_CLAUSE }
        end

        def self.year_range(criteria)
          range = {}
          gt = criteria.first_year_published_gt
          lt = criteria.first_year_published_lt
          range[:gte] = gt if gt
          range[:lte] = lt if lt
          range
        end

        def self.must_not_clauses(criteria, excluded_book_ids)
          clauses = []

          categories = criteria.excluded_category_ids
          clauses << {terms: {category_ids: categories}} if categories.any?

          languages = criteria.excluded_language_ids
          clauses << {terms: {original_language_id: languages}} if languages.any?

          countries = criteria.excluded_country_ids
          clauses << {terms: {country_ids: countries}} if countries.any?

          clauses << {exists: {field: "ranked_position"}} if criteria.ranked == :unranked

          clauses << {ids: {values: excluded_book_ids}} if excluded_book_ids.any?

          clauses
        end

        private_class_method :filter_clauses, :category_clauses, :unparseable_clauses, :year_range, :must_not_clauses
      end
    end
  end
end
