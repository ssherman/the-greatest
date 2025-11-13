require "test_helper"

module Services
  module RankingConfiguration
    class CalculateWeightsTest < ActiveSupport::TestCase
      setup do
        @ranking_configuration = ranking_configurations(:music_albums_global)
      end

      # Call Tests

      test "calls Rankings::BulkWeightCalculator with ranking configuration" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 10, updated: 10, errors: []})

        Rankings::BulkWeightCalculator.expects(:new).with(@ranking_configuration).returns(calculator)

        CalculateWeights.call(@ranking_configuration)
      end

      test "returns success hash when no errors" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 10, updated: 10, errors: []})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        result = CalculateWeights.call(@ranking_configuration)

        assert result[:success]
        assert_includes result[:message], "Successfully calculated weights"
        assert_includes result[:message], "10 ranked lists"
        assert_includes result[:message], "10 processed"
      end

      test "returns failure hash when errors exist" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 10, updated: 8, errors: ["Error 1", "Error 2"]})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        result = CalculateWeights.call(@ranking_configuration)

        assert_not result[:success]
        assert_includes result[:error], "Weight calculation completed with 2 errors"
        assert_includes result[:error], "8 weights updated"
        assert_includes result[:error], "10 processed"
      end

      test "returns success with correct counts when some updates succeed" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 5, updated: 5, errors: []})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        result = CalculateWeights.call(@ranking_configuration)

        assert result[:success]
        assert_includes result[:message], "5 ranked lists"
        assert_includes result[:message], "5 processed"
      end

      test "returns failure with error count when all updates fail" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 5, updated: 0, errors: ["Error 1", "Error 2", "Error 3", "Error 4", "Error 5"]})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        result = CalculateWeights.call(@ranking_configuration)

        assert_not result[:success]
        assert_includes result[:error], "5 errors"
        assert_includes result[:error], "0 weights updated"
      end

      test "can be called using instance method" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 10, updated: 10, errors: []})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        service = CalculateWeights.new(@ranking_configuration)
        result = service.call

        assert result[:success]
      end

      test "works with different ranking configuration types" do
        songs_config = ranking_configurations(:music_songs_global)

        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 3, updated: 3, errors: []})
        Rankings::BulkWeightCalculator.expects(:new).with(songs_config).returns(calculator)

        result = CalculateWeights.call(songs_config)

        assert result[:success]
      end

      test "handles zero processed items" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 0, updated: 0, errors: []})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        result = CalculateWeights.call(@ranking_configuration)

        assert result[:success]
        assert_includes result[:message], "0 ranked lists"
        assert_includes result[:message], "0 processed"
      end

      test "handles partial updates with errors" do
        calculator = mock("calculator")
        calculator.stubs(:call).returns({processed: 10, updated: 7, errors: ["Error 1", "Error 2", "Error 3"]})
        Rankings::BulkWeightCalculator.stubs(:new).returns(calculator)

        result = CalculateWeights.call(@ranking_configuration)

        assert_not result[:success]
        assert_includes result[:error], "3 errors"
        assert_includes result[:error], "7 weights updated"
        assert_includes result[:error], "10 processed"
      end
    end
  end
end
