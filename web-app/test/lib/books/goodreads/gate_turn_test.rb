# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class GateTurnTest < ActiveSupport::TestCase
      def gate(reservation: FetchGate::Reservation.new(wait: 0, refusal: nil), blocked: false, spacing: 0)
        stub(reserve: reservation, blocked?: blocked, spacing_wait: spacing, started!: nil)
      end

      test "a refused reservation refuses the turn" do
        g = gate(reservation: FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))

        decision = GateTurn.call(gate: g, due: false)

        assert_equal [:refused, :daily_cap], [decision.action, decision.refusal]
      end

      test "a reservation with a wait asks to come back after it" do
        decision = GateTurn.call(gate: gate(reservation: FetchGate::Reservation.new(wait: 12, refusal: nil)), due: false)

        assert_equal [:wait, 12], [decision.action, decision.wait]
      end

      test "a due turn does not reserve again" do
        g = gate
        g.expects(:reserve).never

        assert_equal :fetch, GateTurn.call(gate: g, due: true).action
      end

      test "a block refuses the turn" do
        decision = GateTurn.call(gate: gate(blocked: true), due: true)

        assert_equal [:refused, :blocked], [decision.action, decision.refusal]
      end

      test "a fetch too soon after the last one waits out the spacing" do
        decision = GateTurn.call(gate: gate(spacing: 4), due: true)

        assert_equal [:wait, 4], [decision.action, decision.wait]
      end

      test "otherwise the fetch starts" do
        g = gate
        g.expects(:started!).once

        assert_equal :fetch, GateTurn.call(gate: g, due: false).action
      end

      test "priority reaches the reservation, the spacing check and the start" do
        g = mock
        g.expects(:reserve).with(priority: true).returns(FetchGate::Reservation.new(wait: 0, refusal: nil))
        g.expects(:blocked?).returns(false)
        g.expects(:spacing_wait).with(priority: true).returns(0)
        g.expects(:started!).with(priority: true)

        assert_equal :fetch, GateTurn.call(gate: g, due: false, priority: true).action
      end

      test "an ordinary turn leaves priority off" do
        g = mock
        g.expects(:reserve).with(priority: false).returns(FetchGate::Reservation.new(wait: 0, refusal: nil))
        g.expects(:blocked?).returns(false)
        g.expects(:spacing_wait).with(priority: false).returns(0)
        g.expects(:started!).with(priority: false)

        GateTurn.call(gate: g, due: false)
      end

      # Plays a backlog of ordinary turns and priority arrivals through the real
      # gate, a second at a time, the way the capsule's jobs reschedule themselves.
      test "priority turns start soon after a backlog, and the interval and the day's total hold" do
        travel_to Time.utc(2026, 11, 24, 10, 0, 0)
        config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 40, priority_reserved: 5, block_cooldown: 3600)
        real = FetchGate.new(redis: ::Books::OpenLibrary::FakeRedis.new, config: config)
        t0 = Time.current.to_i
        arrivals = [100, 200, 205, 210, 700] # seconds after t0
        jobs = []
        60.times do
          reservation = real.reserve
          jobs << {priority: false, due: true, wake: t0 + reservation.wait, arrived: t0} if reservation.granted?
        end
        starts = []
        1800.times do |tick|
          now = Time.current.to_i
          arrivals.each { |a| jobs << {priority: true, due: false, wake: now, arrived: now} if tick == a }
          jobs.select { |job| job[:wake] <= now }.each do |job|
            decision = GateTurn.call(gate: real, due: job[:due], priority: job[:priority])
            case decision.action
            when :fetch
              starts << {at: now, priority: job[:priority], arrived: job[:arrived]}
              jobs.reject! { |j| j.equal?(job) }
            when :wait then job.merge!(wake: now + decision.wait, due: true)
            else jobs.reject! { |j| j.equal?(job) }
            end
          end
          travel 1.second
        end

        times = starts.map { |s| s[:at] }
        assert_equal 35 + 5, starts.size
        assert times.each_cons(2).all? { |a, b| b - a >= 15 }, "starts closer than the interval"
        assert_operator starts.size, :<=, config.daily_fetch_cap
        priority = starts.select { |s| s[:priority] }
        assert_equal 5, priority.size
        assert priority.all? { |s| s[:at] - s[:arrived] <= 4 * 15 }, "a priority turn waited more than four intervals"
      end

      test "after_fetch leaves the gate open on an unparseable page" do
        g = mock
        g.expects(:block!).never

        GateTurn.after_fetch(gate: g, outcome: :unparseable)
      end

      test "after_fetch blocks the gate on a blocked fetch" do
        g = mock
        g.expects(:block!).once

        GateTurn.after_fetch(gate: g, outcome: :blocked)
      end

      test "after_fetch leaves the gate alone otherwise" do
        g = mock
        g.expects(:block!).never

        GateTurn.after_fetch(gate: g, outcome: :found)
      end
    end
  end
end
