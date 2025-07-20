# frozen_string_literal: true

require "test_helper"

module Rankings
  class WeightCalculatorTest < ActiveSupport::TestCase
    def setup
      @books_ranked_list = ranked_lists(:books_ranked_list)
      @books_config = ranking_configurations(:books_global)
    end

    # Test factory method for version selection
    test "for_version returns correct calculator class" do
      assert_equal WeightCalculatorV1, WeightCalculator.for_version(1)
    end

    test "for_version raises error for unsupported version" do
      error = assert_raises(ArgumentError) do
        WeightCalculator.for_version(999)
      end
      assert_match(/Unsupported algorithm version: 999/, error.message)
    end

    # Test factory method for ranked list
    test "for_ranked_list returns calculator instance for correct version" do
      calculator = WeightCalculator.for_ranked_list(@books_ranked_list)

      assert_instance_of WeightCalculatorV1, calculator
      assert_equal @books_ranked_list, calculator.ranked_list
    end

    # Test basic initialization
    test "initializes with ranked list" do
      calculator = WeightCalculator.new(@books_ranked_list)

      assert_equal @books_ranked_list, calculator.ranked_list
    end

    # Test abstract methods
    test "base class calculate_weight raises NotImplementedError" do
      calculator = WeightCalculator.new(@books_ranked_list)

      error = assert_raises(NotImplementedError) do
        calculator.send(:calculate_weight)
      end
      assert_match(/Subclasses must implement #calculate_weight/, error.message)
    end

    # Test protected helper methods
    test "list returns the associated list" do
      calculator = WeightCalculator.new(@books_ranked_list)

      assert_equal @books_ranked_list.list, calculator.send(:list)
    end

    test "ranking_configuration returns the associated configuration" do
      calculator = WeightCalculator.new(@books_ranked_list)

      assert_equal @books_ranked_list.ranking_configuration, calculator.send(:ranking_configuration)
    end

    test "base_weight returns default value" do
      calculator = WeightCalculator.new(@books_ranked_list)

      assert_equal 100, calculator.send(:base_weight)
    end

    test "minimum_weight returns configuration min_list_weight" do
      calculator = WeightCalculator.new(@books_ranked_list)

      assert_equal @books_config.min_list_weight, calculator.send(:minimum_weight)
    end

    # Test call method behavior (would work with concrete implementation)
    test "call method structure exists" do
      calculator = WeightCalculator.new(@books_ranked_list)

      # Should respond to call method
      assert_respond_to calculator, :call

      # Should raise error since base class is abstract
      assert_raises(NotImplementedError) do
        calculator.call
      end
    end
  end
end
