require "test_helper"

class BulkCalculateWeightsJobTest < ActiveSupport::TestCase
  def setup
    @job = BulkCalculateWeightsJob.new
  end

  test "performs successfully with valid ranking configuration" do
    # Use an existing music albums ranking configuration from fixtures
    ranking_config = ranking_configurations(:music_albums_global)

    # Should not raise any errors and should return actual results
    result = @job.perform(ranking_config.id)

    # Should return a hash with the expected keys
    assert_kind_of Hash, result
    assert result.key?(:processed)
    assert result.key?(:updated)
    assert result.key?(:errors)

    # Values should be reasonable
    assert_kind_of Integer, result[:processed]
    assert_kind_of Integer, result[:updated]
    assert_kind_of Array, result[:errors]

    # Processed count should be >= updated count
    assert_operator result[:processed], :>=, result[:updated]
  end

  test "raises ActiveRecord::RecordNotFound for non-existent ranking configuration" do
    non_existent_id = 999999

    assert_raises(ActiveRecord::RecordNotFound) do
      @job.perform(non_existent_id)
    end
  end

  test "logs error and re-raises when calculator fails" do
    ranking_config = ranking_configurations(:music_albums_global)

    # Stub the calculator to raise an error
    Rankings::BulkWeightCalculator.stubs(:new).raises(StandardError, "Calculator failed")

    assert_raises(StandardError) do
      @job.perform(ranking_config.id)
    end
  end
end
