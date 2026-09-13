# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class RequestRefreshTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_user)
        @statuses = ::RankingConfiguration.refresh_statuses
      end

      test "claims an idle configuration, clears the last error and enqueues the job" do
        @config.update_columns(last_refresh_error: "old")
        ::RankingConfigurations::RefreshJob.expects(:perform_async).with(@config.id).once

        result = RequestRefresh.call(config: @config)

        assert result.success?, result.errors.inspect
        @config.reload
        assert @config.refresh_queued?
        assert_nil @config.last_refresh_error
        assert_in_delta Time.current, @config.refresh_requested_at, 5.seconds
      end

      test "claims a failed configuration" do
        @config.update_columns(refresh_status: @statuses[:failed])
        ::RankingConfigurations::RefreshJob.expects(:perform_async).once

        assert RequestRefresh.call(config: @config).success?
      end

      test "refuses while a fresh refresh is in progress and enqueues nothing" do
        @config.update_columns(refresh_status: @statuses[:running], refresh_requested_at: 5.minutes.ago)
        ::RankingConfigurations::RefreshJob.expects(:perform_async).never

        result = RequestRefresh.call(config: @config)

        refute result.success?
        assert_equal :already_running, result.data[:reason]
        assert_equal [RequestRefresh::ALREADY_RUNNING], result.errors
        assert @config.reload.refresh_running?
      end

      test "reclaims a refresh abandoned longer than the stale window" do
        @config.update_columns(refresh_status: @statuses[:running],
          refresh_requested_at: (::RankingConfiguration::REFRESH_STALE_AFTER + 1.minute).ago)
        ::RankingConfigurations::RefreshJob.expects(:perform_async).once

        assert RequestRefresh.call(config: @config).success?
        assert @config.reload.refresh_queued?
      end

      test "only one of two back-to-back calls wins" do
        ::RankingConfigurations::RefreshJob.expects(:perform_async).once

        assert RequestRefresh.call(config: @config).success?
        refute RequestRefresh.call(config: ::RankingConfiguration.find(@config.id)).success?
      end

      test "an enqueue failure releases the claim into failed with the reason" do
        ::RankingConfigurations::RefreshJob.expects(:perform_async).raises(RedisClient::CannotConnectError, "redis is down")

        result = RequestRefresh.call(config: @config)

        refute result.success?
        assert_equal :enqueue_failed, result.data[:reason]
        assert_equal [RequestRefresh::ENQUEUE_FAILED], result.errors
        @config.reload
        assert @config.refresh_failed?, "the claim must not stay queued for the whole stale window"
        assert_includes @config.last_refresh_error, "redis is down"
        assert @config.refresh_claimable?, "the next click can try again immediately"
      end
    end
  end
end
