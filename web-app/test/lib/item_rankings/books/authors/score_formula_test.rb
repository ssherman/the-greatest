require "test_helper"

module ItemRankings
  module Books
    module Authors
      class ScoreFormulaTest < ActiveSupport::TestCase
        test "count_multiplier follows the saturating ladder" do
          expected = {
            1 => 0.3056,
            2 => 0.5556,
            3 => 0.7500,
            4 => 0.8889,
            5 => 0.9722,
            6 => 1.0000
          }

          expected.each do |count, multiplier|
            assert_in_delta multiplier,
              ScoreFormula.count_multiplier(count),
              0.0001,
              "multiplier for #{count} book(s)"
          end
        end

        test "count_multiplier saturates above six books" do
          assert_equal ScoreFormula.count_multiplier(6), ScoreFormula.count_multiplier(7)
          assert_equal ScoreFormula.count_multiplier(6), ScoreFormula.count_multiplier(70)
        end

        test "a single ranked book is floored, not zeroed" do
          score = ScoreFormula.call(book_count: 1, total_score: 1000)

          assert score > 0, "a one-book author must not score zero"
          assert_in_delta 305.6, score, 0.1
        end

        test "six or more books keep the full total" do
          assert_in_delta 1000.0, ScoreFormula.call(book_count: 6, total_score: 1000), 0.01
          assert_in_delta 1000.0, ScoreFormula.call(book_count: 20, total_score: 1000), 0.01
        end

        test "the five to six transition is not a cliff" do
          five = ScoreFormula.call(book_count: 5, total_score: 1000)
          six = ScoreFormula.call(book_count: 6, total_score: 1000)

          assert_in_delta 0.0278, (six - five) / six, 0.001,
            "the jump from five to six books must stay near 2.8 percent"
        end

        test "returns zero for a non-positive book count" do
          assert_equal 0, ScoreFormula.call(book_count: 0, total_score: 1000)
        end

        test "returns a BigDecimal" do
          assert_instance_of BigDecimal, ScoreFormula.call(book_count: 3, total_score: 100)
        end

        test "accepts string inputs from a raw SQL result row" do
          assert_in_delta 750.0, ScoreFormula.call(book_count: "3", total_score: "1000.0"), 0.01
        end
      end
    end
  end
end
