# frozen_string_literal: true

require "test_helper"

module Search
  module Shared
    class UtilsTest < ActiveSupport::TestCase
      test "cleanup_for_indexing removes special characters and normalizes text" do
        text_array = ["Hello World!", "Test & Example", "  Multiple   Spaces  "]

        result = Search::Shared::Utils.cleanup_for_indexing(text_array)

        assert_equal ["Hello World", "Test Example", "Multiple Spaces"], result
      end

      test "cleanup_for_indexing handles blank and nil values" do
        text_array = ["Hello", "", nil, "  ", "World"]

        result = Search::Shared::Utils.cleanup_for_indexing(text_array)

        assert_equal ["Hello", "World"], result
      end

      test "cleanup_for_indexing returns empty array for blank input" do
        assert_equal [], Search::Shared::Utils.cleanup_for_indexing([])
        assert_equal [], Search::Shared::Utils.cleanup_for_indexing(nil)
      end

      test "normalize_search_text converts to lowercase and removes special characters" do
        result = Search::Shared::Utils.normalize_search_text("Hello World!")
        assert_equal "hello world", result

        result = Search::Shared::Utils.normalize_search_text("Test & Example")
        assert_equal "test example", result

        result = Search::Shared::Utils.normalize_search_text("  Multiple   Spaces  ")
        assert_equal "multiple spaces", result
      end

      test "normalize_search_text handles blank input" do
        assert_equal "", Search::Shared::Utils.normalize_search_text("")
        assert_equal "", Search::Shared::Utils.normalize_search_text(nil)
      end

      test "build_match_query creates correct match query structure" do
        result = Search::Shared::Utils.build_match_query("title", "test query", boost: 2.0, operator: "and")

        expected = {
          match: {
            "title" => {
              query: "test query",
              boost: 2.0,
              operator: "and"
            }
          }
        }

        assert_equal expected, result
      end

      test "build_match_phrase_query creates correct match phrase query structure" do
        result = Search::Shared::Utils.build_match_phrase_query("title", "test phrase", boost: 1.5)

        expected = {
          match_phrase: {
            "title" => {
              query: "test phrase",
              boost: 1.5
            }
          }
        }

        assert_equal expected, result
      end

      test "build_term_query creates correct term query structure" do
        result = Search::Shared::Utils.build_term_query("category", "music", boost: 3.0)

        expected = {
          term: {
            "category" => {
              value: "music",
              boost: 3.0
            }
          }
        }

        assert_equal expected, result
      end

      test "build_bool_query creates correct bool query structure with all clauses" do
        must_clauses = [{match: {title: "test"}}]
        should_clauses = [{match: {description: "example"}}]
        must_not_clauses = [{term: {status: "deleted"}}]
        filter_clauses = [{range: {year: {gte: 2000}}}]

        result = Search::Shared::Utils.build_bool_query(
          must: must_clauses,
          should: should_clauses,
          must_not: must_not_clauses,
          filter: filter_clauses,
          minimum_should_match: 1
        )

        expected = {
          bool: {
            must: must_clauses,
            should: should_clauses,
            must_not: must_not_clauses,
            filter: filter_clauses,
            minimum_should_match: 1
          }
        }

        assert_equal expected, result
      end

      test "build_bool_query creates correct bool query structure with only some clauses" do
        must_clauses = [{match: {title: "test"}}]

        result = Search::Shared::Utils.build_bool_query(must: must_clauses)

        expected = {
          bool: {
            must: must_clauses
          }
        }

        assert_equal expected, result
      end
    end
  end
end
