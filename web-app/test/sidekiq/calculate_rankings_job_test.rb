# frozen_string_literal: true

require "test_helper"

class CalculateRankingsJobTest < ActiveSupport::TestCase
  def setup
    @ranking_configuration = ranking_configurations(:music_albums_global)
  end

  test "perform calls calculate_rankings on configuration" do
    # Mock any ranking configuration instance to verify calculate_rankings is called
    RankingConfiguration.any_instance.expects(:calculate_rankings).returns(
      ItemRankings::Calculator::Result.new(success?: true, data: [], errors: [])
    )

    CalculateRankingsJob.new.perform(@ranking_configuration.id)
  end

  test "perform raises exception when calculation fails" do
    # Mock failed result
    failed_result = ItemRankings::Calculator::Result.new(
      success?: false,
      data: nil,
      errors: ["Test error message"]
    )
    RankingConfiguration.any_instance.stubs(:calculate_rankings).returns(failed_result)

    error = assert_raises StandardError do
      CalculateRankingsJob.new.perform(@ranking_configuration.id)
    end

    assert_includes error.message, "Ranking calculation failed: Test error message"
  end

  test "perform raises error when ranking configuration not found" do
    invalid_id = -1

    error = assert_raises ActiveRecord::RecordNotFound do
      CalculateRankingsJob.new.perform(invalid_id)
    end

    assert_includes error.message, "Couldn't find RankingConfiguration"
  end
end
