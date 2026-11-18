# frozen_string_literal: true

require "test_helper"

module Books
  class FetchGateTest < ActiveSupport::TestCase
    setup do
      freeze_time
      @redis = ::Books::OpenLibrary::FakeRedis.new
      @config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 3, block_cooldown: 6.hours.to_i)
    end

    def gate(key, config: @config, label: key)
      FetchGate.new(key: key, config: config, label: label, redis: @redis)
    end

    test "two gates with different keys do not share a line, a cap or a block" do
      a = gate("x")
      b = gate("y")
      a.block!

      assert_equal [true, false], [a.blocked?, b.blocked?]

      c = gate("p")
      d = gate("q")

      assert_equal [0, 15], 2.times.map { c.reserve.wait }
      assert_equal 0, d.reserve.wait
      assert_equal [2, 1], [c.usage.count, d.usage.count]
    end

    test "reopens_at is the block's end while blocked" do
      t = Time.utc(2026, 11, 17, 10, 0, 0)
      travel_to t
      g = gate("x")
      g.block!

      assert_equal t + @config.block_cooldown, g.reopens_at
    end

    test "reopens_at is the next UTC midnight once the day's cap is spent" do
      travel_to Time.utc(2026, 11, 17, 10, 0, 0)
      g = gate("x", config: @config.merge(daily_fetch_cap: 1))
      g.reserve

      assert_equal :daily_cap, g.reserve.refusal
      assert_equal Time.utc(2026, 11, 18, 0, 0, 0), g.reopens_at
    end

    test "reopens_at is nil when the gate is open" do
      g = gate("x")

      assert_nil g.reopens_at

      g.reserve

      assert_nil g.reopens_at
    end

    test "the block log line names the label" do
      Rails.logger.expects(:warn).with("Books::FetchGate: Acme blocked a fetch; no fetches for 21600s")

      gate("x", label: "Acme").block!
    end
  end
end
