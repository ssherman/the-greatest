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

      test "normalize_search_text normalizes smart quotes to straight quotes" do
        result = Search::Shared::Utils.normalize_search_text("\u2018Don\u2019t Stop Believin\u2019")
        assert_equal "'don't stop believin'", result

        result = Search::Shared::Utils.normalize_search_text("\u201CThe Time\u201D")
        assert_equal "the time", result
      end

      test "normalize_search_text preserves periods for acronyms" do
        result = Search::Shared::Utils.normalize_search_text("B.O.B.")
        assert_equal "b.o.b.", result

        result = Search::Shared::Utils.normalize_search_text("U.S.A.")
        assert_equal "u.s.a.", result

        result = Search::Shared::Utils.normalize_search_text("Dr. Dre")
        assert_equal "dr. dre", result
      end

      test "cleanup_for_indexing normalizes smart quotes to straight quotes" do
        text_array = ["\u2018Don\u2019t Stop\u2019", "\u201CThe Wall\u201D"]
        result = Search::Shared::Utils.cleanup_for_indexing(text_array)
        assert_equal ["'Don't Stop'", "\"The Wall\""], result
      end

      test "normalize_search_text keeps non-ASCII letters and still strips punctuation" do
        assert_equal "trilog\u00EDa de las fundaciones", ::Search::Shared::Utils.normalize_search_text("Trilog\u00EDa De Las Fundaciones!")
        assert_equal "\u0432\u043E\u0439\u043D\u0430 \u0438 \u043C\u0438\u0440", ::Search::Shared::Utils.normalize_search_text("\u0412\u043E\u0439\u043D\u0430 \u0438 \u043C\u0438\u0440")
        assert_equal "\u6751\u4E0A\u6625\u6A39", ::Search::Shared::Utils.normalize_search_text("\u6751\u4E0A\u6625\u6A39")
        assert_equal "war peace", ::Search::Shared::Utils.normalize_search_text("War & Peace:")
        assert_equal "b.o.b.", ::Search::Shared::Utils.normalize_search_text("B.O.B.")
      end

      test "cleanup_for_indexing keeps non-ASCII letters" do
        assert_equal ["Les Mis\u00E9rables", "Bj\u00F6rk"], ::Search::Shared::Utils.cleanup_for_indexing(["Les Mis\u00E9rables!", "Bj\u00F6rk", ""])
      end

      test "normalize_search_text composes a decomposed accent before stripping combining marks" do
        # "e" (U+0065) followed by a combining acute accent (U+0301), the
        # way some external data decomposes it, rather than the precomposed
        # "\u00E9". Without NFKC first, the bare combining mark is not
        # \p{L} and gets replaced with a space, fragmenting the word.
        decomposed = "Mise\u0301rables"

        assert_equal "mis\u00E9rables", ::Search::Shared::Utils.normalize_search_text(decomposed)
      end

      test "cleanup_for_indexing composes a decomposed accent before stripping combining marks" do
        decomposed = "Mise\u0301rables"

        assert_equal ["Mis\u00E9rables"], ::Search::Shared::Utils.cleanup_for_indexing([decomposed])
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
