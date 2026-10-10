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

    def queue!(config)
      config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:queued], refresh_requested_at: Time.current)
      config
    end

    def stub_clean_run
      Rankings::BulkWeightCalculator.any_instance.stubs(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.stubs(:calculate_rankings).returns(@success)
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

    test "a member's ranking requests neither the author rankings nor the search reindex" do
      stub_clean_run
      Books::ReindexRankedFieldsJob.expects(:perform_async).never
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).never

      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_idle?
    end

    test "requests a CSV export regenerate after a successful run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @config, rerun_if_generating: true).once

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

    test "a failure requesting the CSV regenerate does not fail the refresh" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)
      Services::CsvExports::RequestGenerate.expects(:call).raises(StandardError, "csv_exports hiccup")

      RefreshJob.new.perform(@config.id)

      @config.reload
      assert @config.refresh_idle?
      refute @config.needs_refresh?
      assert_nil @config.last_refresh_error
    end

    test "a run whose row is not queued is skipped, so a second job never calculates alongside the first" do
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running])
      Rankings::BulkWeightCalculator.any_instance.expects(:call).never
      RankingConfiguration.any_instance.expects(:calculate_rankings).never

      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_running?, "the run that holds the row is left alone"
    end

    test "a Sidekiq shutdown mid-run hands the row back to queued and re-raises, so the pushed-back job reruns" do
      Rankings::BulkWeightCalculator.any_instance.stubs(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.stubs(:calculate_rankings).raises(::Sidekiq::Shutdown)

      assert_raises(::Sidekiq::Shutdown) { RefreshJob.new.perform(@config.id) }
      assert @config.reload.refresh_queued?, "the requeued job only runs from queued"

      RankingConfiguration.any_instance.unstub(:calculate_rankings)
      RankingConfiguration.any_instance.expects(:calculate_rankings).once.returns(@success)
      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_idle?
    end

    test "an idle row is skipped too" do
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:idle])
      Rankings::BulkWeightCalculator.any_instance.expects(:call).never

      RefreshJob.new.perform(@config.id)

      assert @config.reload.refresh_idle?
    end

    test "weights are calculated before rankings" do
      order = sequence("weights then rankings")
      Rankings::BulkWeightCalculator.any_instance.expects(:call).in_sequence(order).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).in_sequence(order).returns(@success)

      RefreshJob.new.perform(@config.id)
    end

    test "the books primary requests the author rankings and the search reindex after it lands" do
      primary = queue!(ranking_configurations(:books_global))
      stub_clean_run
      ::Services::RankingConfigurations::RequestRefresh.expects(:call)
        .with(config: ranking_configurations(:books_authors_global)).once
      Books::ReindexRankedFieldsJob.expects(:perform_async).once

      RefreshJob.new.perform(primary.id)

      assert primary.reload.refresh_idle?
    end

    test "a global configuration other than the books primary requests no follow-ups" do
      [:books_authors_global, :music_albums_global].each do |name|
        config = queue!(ranking_configurations(name))
        stub_clean_run
        ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
        Books::ReindexRankedFieldsJob.expects(:perform_async).never

        RefreshJob.new.perform(config.id)

        assert config.reload.refresh_idle?, "#{name} should end idle"
      end
    end

    test "with no authors primary the books primary still finishes and reindexes" do
      ranking_configurations(:books_authors_global).update_columns(primary: false)
      primary = queue!(ranking_configurations(:books_global))
      stub_clean_run
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).never
      Books::ReindexRankedFieldsJob.expects(:perform_async).once

      RefreshJob.new.perform(primary.id)

      assert primary.reload.refresh_idle?
    end

    test "a failure requesting the follow-ups does not fail a run that landed" do
      primary = queue!(ranking_configurations(:books_global))
      stub_clean_run
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).raises(StandardError, "redis hiccup")
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: primary, rerun_if_generating: true).once

      RefreshJob.new.perform(primary.id)

      primary.reload
      assert primary.refresh_idle?
      assert_nil primary.last_refresh_error
    end

    test "a run stamps its own start, so a request made mid-run after a long wait in the queue is refused" do
      @config.update_columns(refresh_requested_at: (RankingConfiguration::REFRESH_STALE_AFTER + 5.minutes).ago)
      id = @config.id
      mid_run = nil
      Rankings::BulkWeightCalculator.any_instance.stubs(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.stubs(:calculate_rankings).with { |*|
        mid_run = Services::RankingConfigurations::RequestRefresh.call(config: RankingConfiguration.find(id))
        true
      }.returns(@success)

      RefreshJob.new.perform(id)

      refute mid_run.success?
      assert_equal :already_running, mid_run.data[:reason]
      assert @config.reload.refresh_idle?
    end
  end
end
