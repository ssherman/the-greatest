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

      test "a global configuration runs on the default queue, immediately" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert RequestRefresh.call(config: global).success?

          job = ::RankingConfigurations::RefreshJob.jobs.sole
          assert_equal "default", job["queue"]
          assert_equal [global.id], job["args"]
          assert_nil job["at"]
        end
      end

      test "a member's configuration keeps the job's own low queue" do
        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert RequestRefresh.call(config: @config).success?

          assert_equal "low", ::RankingConfigurations::RefreshJob.jobs.sole["queue"]
        end
      end

      test "a delay schedules the run that far ahead and the row is queued now" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert RequestRefresh.call(config: global, delay: 5.minutes).success?

          job = ::RankingConfigurations::RefreshJob.jobs.sole
          assert_in_delta 5.minutes.from_now.to_f, job["at"], 2
          assert global.reload.refresh_queued?
        end
      end

      test "a burst of delayed requests for one configuration queues one run" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          results = 5.times.map { RequestRefresh.call(config: ::RankingConfiguration.find(global.id), delay: 5.minutes) }

          assert_equal [true, false, false, false, false], results.map(&:success?)
          assert_equal 1, ::RankingConfigurations::RefreshJob.jobs.size
        end
      end

      test "call_for_ids claims each configuration once, skipping nil, duplicate and missing ids" do
        global = ranking_configurations(:books_global)

        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          results = RequestRefresh.call_for_ids([global.id, @config.id, global.id, nil, -1], delay: 5.minutes)

          assert_equal 2, results.size
          assert results.all?(&:success?)
          assert_equal [global.id, @config.id].sort,
            ::RankingConfigurations::RefreshJob.jobs.map { |job| job["args"].first }.sort
        end
      end

      test "call_for_ids with nothing to refresh does nothing" do
        Sidekiq::Testing.fake! do
          ::RankingConfigurations::RefreshJob.clear

          assert_equal [], RequestRefresh.call_for_ids(nil)
          assert_equal [], RequestRefresh.call_for_ids([])
          assert_empty ::RankingConfigurations::RefreshJob.jobs
        end
      end
    end
  end
end
