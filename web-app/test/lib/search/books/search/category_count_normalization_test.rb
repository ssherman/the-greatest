# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class CategoryCountNormalizationTest < ActiveSupport::TestCase
        test "wraps the query in a replace-mode script_score carrying the floor" do
          query = {bool: {filter: []}}
          result = CategoryCountNormalization.wrap(query, floor: 10)

          function_score = result[:function_score]
          assert_equal query, function_score[:query]
          assert_equal "replace", function_score[:boost_mode]
          assert_equal({floor: 10}, function_score[:script_score][:script][:params])
        end

        test "the script guards a missing or zero count and clamps to the floor" do
          source = CategoryCountNormalization.wrap({}, floor: 10)[:function_score][:script_score][:script][:source]

          assert_includes source, "count < params.floor"
          assert_includes source, "count < 1 ? 1 : count"
        end

        test "a nil floor becomes zero" do
          result = CategoryCountNormalization.wrap({}, floor: nil)

          assert_equal({floor: 0}, result[:function_score][:script_score][:script][:params])
        end
      end
    end
  end
end
