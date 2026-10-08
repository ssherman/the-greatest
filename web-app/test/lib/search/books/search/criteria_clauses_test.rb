# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class CriteriaClausesTest < ActiveSupport::TestCase
        def criteria(raw)
          ::Books::SavedSearchCriteria.new(raw)
        end

        test "filter clauses cover categories, length, year, ranked and max position" do
          clauses = CriteriaClauses.filter_clauses(criteria(
            "included_category_ids" => [1, 2], "book_length" => [1],
            "first_year_published_gt" => 1900, "first_year_published_lt" => 1950,
            "ranked" => "true", "max_ranked_position" => 100
          ))
          assert_includes clauses, {terms: {category_ids: [1, 2]}}
          assert_includes clauses, {terms: {book_length: [1]}}
          assert_includes clauses, {range: {first_published_year: {gte: 1900, lte: 1950}}}
          assert_includes clauses, {exists: {field: "ranked_position"}}
          assert_includes clauses, {range: {ranked_position: {lte: 100}}}
        end

        test "genre_match_mode all emits one term per category" do
          clauses = CriteriaClauses.filter_clauses(criteria("included_category_ids" => [1, 2], "genre_match_mode" => "all"))
          assert_includes clauses, {term: {category_ids: 1}}
          assert_includes clauses, {term: {category_ids: 2}}
        end

        test "an unparseable criterion yields the match-nothing clause" do
          clauses = CriteriaClauses.filter_clauses(criteria("max_ranked_position" => "abc"))
          assert_includes clauses, CriteriaClauses::MATCH_NOTHING_CLAUSE
        end

        test "must_not clauses cover excluded categories, excluded ids and provisional" do
          clauses = CriteriaClauses.must_not_clauses(criteria("excluded_category_ids" => [7]), [11, 12])
          assert_includes clauses, {terms: {category_ids: [7]}}
          assert_includes clauses, {ids: {values: [11, 12]}}
          assert_includes clauses, ::Search::Books::BookIndex::EXCLUDE_PROVISIONAL
        end
      end
    end
  end
end
