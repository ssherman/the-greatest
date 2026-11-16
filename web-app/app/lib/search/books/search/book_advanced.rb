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

        # `order: :random` replaces SORT with a seeded shuffle: function_score's
        # random_score scores every match from the seed and each document's
        # `_seq_no`, so one seed gives one stable order that pages consistently
        # (the same seed over an unchanged index covers every match exactly once).
        # `_id` again breaks any score tie.
        RANDOM_SORT = [
          {_score: {order: "desc"}},
          {_id: {order: "asc"}}
        ].freeze

        ORDERS = %i[rank random].freeze

        MATCH_NOTHING_CLAUSE = CriteriaClauses::MATCH_NOTHING_CLAUSE

        DEFAULT_PER_PAGE = 50

        # OpenSearch's ceiling on `from + size` (index.max_result_window,
        # §5.4). A page beyond it is unreachable; we clamp rather than let
        # OpenSearch raise a BadRequest.
        MAX_RESULT_WINDOW = 10_000

        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        # `track_total_hits: true` asks OpenSearch for an exact total instead of
        # stopping at 10,000; saved searches leave it off.
        def self.call(criteria, page: 1, per_page: DEFAULT_PER_PAGE, excluded_book_ids: [],
          order: :rank, seed: nil, track_total_hits: false)
          definition = build_query_definition(
            criteria, page: page, per_page: per_page, excluded_book_ids: excluded_book_ids,
            order: order, seed: seed, track_total_hits: track_total_hits
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

        def self.build_query_definition(criteria, page: 1, per_page: DEFAULT_PER_PAGE, excluded_book_ids: [],
          order: :rank, seed: nil, track_total_hits: false)
          raise ArgumentError, "page must be >= 1 (got #{page.inspect})" if page < 1
          raise ArgumentError, "order must be one of #{ORDERS.inspect} (got #{order.inspect})" unless ORDERS.include?(order)
          raise ArgumentError, "order: :random needs a seed" if order == :random && seed.nil?

          from = (page - 1) * per_page
          # `from + size` must stay <= MAX_RESULT_WINDOW or OpenSearch raises
          # BadRequest. Beyond the window there is nothing reachable to
          # return, so ask for `from: 0, size: 0` -- zero hits, but `total`
          # still comes back accurate. Within the window, clamp `size` so the
          # last reachable page returns short rather than raising: at the
          # legacy per_page of 120, page 84 computes from 9960 + size 120 =
          # 10080, over the ceiling.
          beyond_window = from >= MAX_RESULT_WINDOW

          query = ::Search::Shared::Utils.build_bool_query(
            filter: CriteriaClauses.filter_clauses(criteria),
            must_not: CriteriaClauses.must_not_clauses(criteria, excluded_book_ids)
          )
          if order == :random
            query = {function_score: {query: query, random_score: {seed: seed, field: "_seq_no"}, boost_mode: "replace"}}
          end

          definition = {
            query: query,
            sort: (order == :random) ? RANDOM_SORT : SORT,
            from: beyond_window ? 0 : from,
            size: beyond_window ? 0 : [per_page, MAX_RESULT_WINDOW - from].min
          }
          definition[:track_total_hits] = true if track_total_hits
          definition
        end
      end
    end
  end
end
