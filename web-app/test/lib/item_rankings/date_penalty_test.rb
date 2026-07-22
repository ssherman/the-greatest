# frozen_string_literal: true

require "test_helper"

module ItemRankings
  class DatePenaltyTest < ActiveSupport::TestCase
    def penalty(list_year: 2000, item_year: 1980, yearly_award: false, max_age: 50, max_penalty_percentage: 80)
      ItemRankings::DatePenalty.call(
        list_year: list_year, item_year: item_year, yearly_award: yearly_award,
        max_age: max_age, max_penalty_percentage: max_penalty_percentage
      )
    end

    test "graduated penalty for an item older than the list within max_age" do
      # year_difference = 20; ((50-20)/50)*80/100 = 0.48
      assert_in_delta 0.48, penalty(item_year: 1980), 0.0001
    end

    test "max penalty when the item is newer than the list" do
      assert_in_delta 0.80, penalty(item_year: 2005), 0.0001
    end

    test "no penalty when the item is older than max_age" do
      assert_nil penalty(item_year: 1940) # diff 60 > 50
    end

    test "max penalty when the item has no year" do
      assert_in_delta 0.80, penalty(item_year: nil), 0.0001
    end

    test "a yearly-award list forces max penalty even with a good year gap" do
      assert_in_delta 0.80, penalty(item_year: 1940, yearly_award: true), 0.0001
    end

    test "a yearly-award list max-penalizes even with no list year" do
      assert_in_delta 0.80, penalty(list_year: nil, item_year: 1980, yearly_award: true), 0.0001
    end

    test "nil when the penalty config is incomplete" do
      assert_nil penalty(max_age: nil)
      assert_nil penalty(max_penalty_percentage: nil)
    end

    test "nil when the list has no year and the item is not award/nil-year" do
      assert_nil penalty(list_year: nil)
    end
  end
end
