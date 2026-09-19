# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class RefreshJobTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_user)
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:queued],
        needs_refresh: true, refresh_requested_at: Time.current)
      @success = ItemRankings::Calculator::Result.new(success?: true, data: [], errors: [])
      @clean_weights = {processed: 1, updated: 1, errors: [], weights_calculated: []}
      Services::CsvExports::RequestGenerate.stubs(:call).returns(
        Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: [])
      )
    end

    test "runs on the low queue and never retries" do
      assert_equal "low", RefreshJob.get_sidekiq_options["queue"].to_s
      assert_equal false, RefreshJob.get_sidekiq_options["retry"]
    end

    test "calculates weights then rankings and marks the configuration up to date" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)

      RefreshJob.new.perform(@config.id)

      @config.reload
      assert @config.refresh_idle?
      refute @config.needs_refresh?
      assert_not_nil @config.last_refreshed_at
      assert_nil @config.last_refresh_error
    end

    test "an edit made mid-run leaves needs_refresh true even though the run succeeds" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.stubs(:calculate_rankings).with { |*|
        @config.update_columns(needs_refresh: true)
        true
      }.returns(@success)

      RefreshJob.new.perform(@config.id)

      @config.reload
      assert @config.refresh_idle?
      assert @config.needs_refresh?, "an edit made while the run was in flight must survive the run's end"
    end

    test "a ranking calculation failure marks the configuration failed and does not raise" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings)
        .returns(ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["boom"]))

      assert_nothing_raised { RefreshJob.new.perform(@config.id) }

      @config.reload
      assert @config.refresh_failed?
      assert @config.needs_refresh?, "a failed refresh leaves the configuration stale"
      assert_includes @config.last_refresh_error, "boom"
    end

    test "a weight calculation error marks the configuration failed before rankings run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(
        @clean_weights.merge(errors: [{ranked_list_id: 1, list_name: "L", error: "weight boom"}])
      )
      RankingConfiguration.any_instance.expects(:calculate_rankings).never

      RefreshJob.new.perform(@config.id)

      @config.reload
      assert @config.refresh_failed?
      assert_includes @config.last_refresh_error, "weight boom"
    end

    test "an unexpected exception marks the configuration failed and does not raise" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).raises(RuntimeError, "kaboom")

      assert_nothing_raised { RefreshJob.new.perform(@config.id) }

      assert @config.reload.refresh_failed?
      assert_includes @config.last_refresh_error, "kaboom"
    end

    test "a configuration deleted while queued is a silent no-op" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).never

      assert_nothing_raised { RefreshJob.new.perform(-1) }
    end

    test "does not enqueue the search reindex or author rankings" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)
      Books::ReindexRankedFieldsJob.expects(:perform_async).never
      Books::CalculateAuthorRankingsJob.expects(:perform_async).never

      RefreshJob.new.perform(@config.id)
    end

    test "requests a CSV export regenerate after a successful run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @config).once

      RefreshJob.new.perform(@config.id)
    end

    test "does not request a CSV export regenerate after a failed run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(
        ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["nope"])
      )
      Services::CsvExports::RequestGenerate.expects(:call).never

      RefreshJob.new.perform(@config.id)
    end
  end
end
