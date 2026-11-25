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

      test "a priority turn sent back for spacing re-arms its protection" do
        g = mock
        g.expects(:blocked?).returns(false)
        g.expects(:spacing_wait).with(priority: true).returns(4)
        g.expects(:hold_priority!).with(4)

        assert_equal [:wait, 4], GateTurn.call(gate: g, due: true, priority: true).then { |d| [d.action, d.wait] }
      end

      test "an ordinary turn sent back for spacing does not touch priority protection" do
        g = mock
        g.expects(:blocked?).returns(false)
        g.expects(:spacing_wait).with(priority: false).returns(4)
        g.expects(:hold_priority!).never

        GateTurn.call(gate: g, due: true)
      end

      INTERVAL = 15

      def sim_gate(cap:, reserved:)
        config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: INTERVAL, daily_fetch_cap: cap, priority_reserved: reserved, block_cooldown: 3600)
        FetchGate.new(redis: ::Books::OpenLibrary::FakeRedis.new, config: config)
      end

      # Plays turns through the real gate in simulated time, jumping from one
      # wake to the next. events: [seconds from start, :ordinary | :priority];
      # :ordinary hands a backlog turn out through reserve, :priority is a reader
      # arriving. Ordinary jobs run before priority jobs that are due the same
      # second, and priority waits wake through wake_at (late, or on a sweep).
      # Returns the starts: {at:, priority:, arrived:}.
      def simulate(gate:, events:, horizon:, wake_at: ->(now, wait) { now + wait }, outage: nil)
        t0 = Time.current.to_i
        pending = events.sort_by(&:first)
        jobs = []
        starts = []
        loop do
          now = Time.current.to_i
          while pending.first && t0 + pending.first[0] <= now
            kind = pending.shift[1]
            if kind == :ordinary
              reservation = gate.reserve
              jobs << {priority: false, due: true, wake: now + reservation.wait, arrived: now} if reservation.granted?
            else
              jobs << {priority: true, due: false, wake: now, arrived: now}
            end
          end
          blocked = outage&.cover?(now - t0)
          jobs.select { |job| !blocked && job[:wake] <= now }.sort_by { |job| job[:priority] ? 1 : 0 }.each do |job|
            decision = GateTurn.call(gate: gate, due: job[:due], priority: job[:priority])
            if decision.action == :wait
              job.merge!(wake: job[:priority] ? wake_at.call(now, decision.wait) : now + decision.wait, due: true)
            else
              starts << {at: now, priority: job[:priority], arrived: job[:arrived]} if decision.action == :fetch
              jobs.reject! { |j| j.equal?(job) }
            end
          end
          upcoming = (jobs.map { |j| j[:wake] } + pending.map { |e| t0 + e[0] }).select { |t| t > now }.min
          upcoming = [upcoming, t0 + outage.end].compact.max if blocked
          break if upcoming.nil? || upcoming > t0 + horizon

          travel_to Time.at(upcoming).utc
        end
        starts
      end

      def assert_spaced(starts)
        times = starts.map { |s| s[:at] }.sort
        assert times.each_cons(2).all? { |a, b| b - a >= INTERVAL }, "starts closer than the interval"
      end

      def delays(starts) = starts.select { |s| s[:priority] }.map { |s| s[:at] - s[:arrived] }

      test "a burst of priority turns behind a long backlog, ordinary jobs first, each start within a bound" do
        travel_to Time.utc(2026, 11, 24, 6, 0, 0)
        rng = Random.new(7)
        events = Array.new(150) { [0, :ordinary] } + Array.new(8) { [100, :priority] }
        starts = simulate(gate: sim_gate(cap: 200, reserved: 20), events: events, horizon: 4000,
          wake_at: ->(now, wait) { now + wait + rng.rand(0..20) })

        delays = delays(starts).sort
        assert_equal 8, delays.size
        assert_spaced(starts)
        assert_operator starts.size, :<=, 200
        # The k-th of the burst starts about k intervals after the first; allow
        # the wake jitter (up to 20 s) on top of each hop.
        delays.each_with_index do |delay, k|
          assert_operator delay, :<=, ((k + 1) * (INTERVAL + 20)) + INTERVAL, "priority turn #{k} waited #{delay}s"
        end
      end

      test "priority turns whose waits only wake on a one-minute sweep still start within a bound" do
        travel_to Time.utc(2026, 11, 24, 6, 0, 0)
        sweep = ->(now, wait) { ((now + wait) / 60.0).ceil * 60 }
        events = Array.new(150) { [0, :ordinary] } + Array.new(3) { [100, :priority] }
        starts = simulate(gate: sim_gate(cap: 200, reserved: 20), events: events, horizon: 4000, wake_at: sweep)

        delays = delays(starts)
        assert_equal 3, delays.size
        assert_spaced(starts)
        assert_operator delays.max, :<=, 5 * 60, "a priority turn waited #{delays.max}s on the sweep"
      end

      test "a backlog crossing midnight does not push either day past the cap, spacing intact" do
        travel_to Time.utc(2026, 11, 24, 23, 55, 0)
        midnight = Time.utc(2026, 11, 25, 0, 0, 0).to_i - Time.current.to_i
        events = Array.new(35) { [0, :ordinary] } +
          Array.new(5) { |i| [10 + (i * 20), :priority] } +
          Array.new(20) { [midnight + 3600, :ordinary] } +
          Array.new(5) { |i| [midnight + 3600 + (i * 20), :priority] }
        starts = simulate(gate: sim_gate(cap: 40, reserved: 5), events: events, horizon: 3 * 86_400)

        per_day = starts.group_by { |s| Time.at(s[:at]).utc.to_date }.transform_values(&:size)
        assert_operator per_day[Date.new(2026, 11, 24)], :<=, 40
        assert_operator per_day[Date.new(2026, 11, 25)], :<=, 40
        assert_spaced(starts)
      end

      test "ordinary turns carried past midnight and a full refill at 00:00 leave the readers' slice alone" do
        travel_to Time.utc(2026, 11, 24, 23, 40, 0)
        refill = 20 * 60
        readers = Array.new(5) { |i| [refill + (8 * 3600) + (i * 900), :priority] }
        # 35 turns are reserved on the 24th, but nothing runs until midnight (an outage).
        events = Array.new(35) { [0, :ordinary] } + Array.new(35) { [refill, :ordinary] } + readers
        starts = simulate(gate: sim_gate(cap: 40, reserved: 5), events: events, horizon: 3 * 86_400, outage: 0...refill)

        per_day = starts.group_by { |s| Time.at(s[:at]).utc.to_date }.transform_values(&:size)
        assert_operator per_day.values.max, :<=, 40
        assert_spaced(starts)
        delays = delays(starts)
        assert_equal 5, delays.size
        assert_operator delays.max, :<=, 60, "a reader waited #{delays.max}s"
        displaced = starts.count { |s| !s[:priority] && s[:arrived] == starts.map { |x| x[:arrived] }.min && Time.at(s[:at]).utc.to_date == Date.new(2026, 11, 25) }
        assert_equal 35, displaced
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
