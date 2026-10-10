# frozen_string_literal: true

require "test_helper"

# CalculateRankingsJob is a one-release shim (see the class). Delete this file
# with it.
class CalculateRankingsJobTest < ActiveSupport::TestCase
  test "forwards to a refresh request instead of calculating" do
    config = ranking_configurations(:music_albums_global)
    ::Services::RankingConfigurations::RequestRefresh.expects(:call).with(config: config).once
    RankingConfiguration.any_instance.expects(:calculate_rankings).never

    CalculateRankingsJob.new.perform(config.id)
  end

  test "a configuration deleted since the job was queued is a silent no-op" do
    ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

    assert_nothing_raised { CalculateRankingsJob.new.perform(-1) }
  end

  test "a backlog of old jobs for one configuration collapses into one refresh" do
    config = ranking_configurations(:books_global)

    Sidekiq::Testing.fake! do
      ::RankingConfigurations::RefreshJob.clear

      50.times { CalculateRankingsJob.new.perform(config.id) }

      assert_equal 1, ::RankingConfigurations::RefreshJob.jobs.size
    end
  end
end
