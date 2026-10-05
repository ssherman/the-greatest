# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class FetchGateTest < ActiveSupport::TestCase
      # CI has no Redis; FakeRedis models the hash commands and expiry. The
      # clock is frozen so a second passing mid-test cannot shift a wait.
      setup do
        freeze_time
        @config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 3, block_cooldown: 6.hours.to_i)
        @gate = FetchGate.new(redis: ::Books::OpenLibrary::FakeRedis.new, config: @config)
      end

      test "the first fetch starts now, and each next one an interval after the one before" do
        assert_equal [0, 15, 30], 3.times.map { @gate.reserve.wait }
      end

      test "once the line has run, the next fetch starts now" do
        2.times { @gate.reserve }
        travel 1.minute

        assert_equal 0, @gate.reserve.wait
      end

      test "the day's cap refuses further fetches until the next UTC day" do
        assert 3.times.map { @gate.reserve }.all?(&:granted?)
        assert_equal :daily_cap, @gate.reserve.refusal

        travel_to(Time.current.utc.tomorrow.beginning_of_day + 1.second)

        assert @gate.reserve.granted?
      end

      test "a block stops every fetch for the cooldown" do
        @gate.block!

        assert_equal [:blocked, true], [@gate.reserve.refusal, @gate.blocked?]

        travel 6.hours

        assert_equal [true, false], [@gate.reserve.granted?, @gate.blocked?]
      end

      test "a fetch that came due late still waits out the gap since the last one actually began" do
        assert_equal 0, @gate.spacing_wait

        @gate.started!
        travel 10.seconds

        assert_equal 5, @gate.spacing_wait
        travel 5.seconds
        assert_equal 0, @gate.spacing_wait
      end

      test "the defaults are the spec's" do
        config = Rails.application.config.x.goodreads

        assert_equal [15, 1_500, 21_600, 3, "h1", 30_000], [config.fetch_interval, config.daily_fetch_cap,
          config.block_cooldown, config.fetch_attempts, config.wait_for_selector, config.fetch_timeout_ms]
      end
    end
  end
end
