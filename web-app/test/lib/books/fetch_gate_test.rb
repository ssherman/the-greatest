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

    # Priority lane: a reader's single fetch must not queue behind a backlog,
    # yet the interval and the day's total must hold.
    def priority_gate(cap: 3, reserved: 1, key: "x", interval: 15)
      gate(key, config: @config.merge(daily_fetch_cap: cap, priority_reserved: reserved, fetch_interval: interval))
    end

    test "a priority turn passes a backlog already handed out" do
      g = priority_gate(cap: 20, reserved: 5)
      10.times { g.reserve }

      assert_equal 0, g.reserve(priority: true).wait
    end

    test "ordinary turns stop at the cap less the reserved slice, and priority turns use the slice" do
      g = priority_gate

      assert_equal [true, true, false], 3.times.map { g.reserve.granted? }
      assert g.reserve(priority: true).granted?
      assert_equal :daily_cap, g.reserve(priority: true).refusal
    end

    test "a priority reservation never moves the ordinary line" do
      g = priority_gate(cap: 20, reserved: 5)
      g.reserve
      g.reserve(priority: true)

      assert_equal 15, g.reserve.wait
    end

    test "two priority turns are an interval apart" do
      g = priority_gate(cap: 20, reserved: 5)

      assert_equal [0, 15, 30], 3.times.map { g.reserve(priority: true).wait }
    end

    test "a priority turn starts an interval after the last fetch began" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      travel 4.seconds

      assert_equal 11, g.reserve(priority: true).wait
    end

    test "a priority turn falls back to an ordinary reservation once the slice is spent" do
      g = priority_gate(cap: 20, reserved: 1)
      g.reserve(priority: true)
      fallback = g.reserve(priority: true)

      assert_equal [true, 0], [fallback.granted?, fallback.wait]
      assert_equal 15, g.reserve.wait
    end

    test "a priority start just after midnight counts on the new day" do
      travel_to Time.utc(2026, 11, 17, 23, 59, 55)
      g = priority_gate(cap: 20, reserved: 1)
      g.reserve(priority: true)
      travel_to Time.utc(2026, 11, 18, 0, 0, 1)

      # The slice is whole again on the new day, so this is a priority turn
      # (an interval after the previous priority start), not an ordinary fallback.
      assert_equal 9, g.reserve(priority: true).wait
      assert_equal 0, g.usage.count
    end

    test "a block refuses a priority turn and reopens_at gives the block's end" do
      g = priority_gate
      g.block!

      assert_equal :blocked, g.reserve(priority: true).refusal
      assert_equal Time.current + @config.block_cooldown, g.reopens_at(priority: true)
    end

    test "priority reopens_at is nil while the ordinary line could still serve a priority turn" do
      g = priority_gate(cap: 3, reserved: 1)
      g.reserve(priority: true)

      assert_nil g.reopens_at(priority: true)
    end

    test "priority reopens_at is the next UTC midnight once both lines are spent" do
      travel_to Time.utc(2026, 11, 17, 10, 0, 0)
      g = priority_gate(cap: 3, reserved: 1)
      2.times { g.reserve }
      g.reserve(priority: true)

      assert_equal :daily_cap, g.reserve(priority: true).refusal
      assert_equal Time.utc(2026, 11, 18, 0, 0, 0), g.reopens_at(priority: true)
    end

    test "priority reopens_at is nil when only the ordinary line is spent" do
      g = priority_gate(cap: 3, reserved: 1)
      2.times { g.reserve }

      assert_equal :daily_cap, g.reserve.refusal
      assert_nil g.reopens_at(priority: true)
    end

    test "priority reopens_at is the earlier of the slice's and the ordinary line's day" do
      travel_to Time.utc(2026, 11, 17, 22, 30, 0)
      g = priority_gate(cap: 4, reserved: 1, interval: 3600)
      # The ordinary line runs past midnight, so its newest day is the 18th.
      5.times { g.reserve }
      g.reserve(priority: true)

      assert_equal :daily_cap, g.reserve(priority: true).refusal
      assert_equal Time.utc(2026, 11, 19, 0, 0, 0), g.reopens_at
      assert_equal Time.utc(2026, 11, 18, 0, 0, 0), g.reopens_at(priority: true)
    end

    test "ordinary reopens_at uses the cap less the reserved slice" do
      travel_to Time.utc(2026, 11, 17, 10, 0, 0)
      g = priority_gate(cap: 3, reserved: 1)
      2.times { g.reserve }

      assert_equal Time.utc(2026, 11, 18, 0, 0, 0), g.reopens_at
    end

    test "a gate with no priority_reserved behaves as before" do
      g = gate("x")

      assert_equal [true, true, true], 3.times.map { g.reserve.granted? }
      assert_equal :daily_cap, g.reserve.refusal
      assert_equal :daily_cap, g.reserve(priority: true).refusal
      assert_equal Time.utc(Time.current.year, Time.current.month, Time.current.day).tomorrow, g.reopens_at
    end

    test "with no priority_reserved a priority turn is an ordinary one" do
      g = gate("x")

      assert_equal [0, 15], 2.times.map { g.reserve(priority: true).wait }
    end

    test "an ordinary turn yields while a priority turn is due, and stops yielding 90 seconds later" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      travel 15.seconds
      g.reserve(priority: true)

      assert_equal 15, g.spacing_wait
      assert_equal 0, g.spacing_wait(priority: true)

      travel 89.seconds
      assert_equal 15, g.spacing_wait

      travel 2.seconds
      assert_equal 0, g.spacing_wait
    end

    test "a priority start releases ordinary turns" do
      g = priority_gate(cap: 20, reserved: 5)
      g.reserve(priority: true)
      g.started!(priority: true)
      travel 15.seconds

      assert_equal 0, g.spacing_wait
    end

    test "nothing due within an interval does not hold ordinary turns" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      travel 15.seconds
      g.hold_priority!(100)

      assert_equal 0, g.spacing_wait
    end

    test "a priority turn sent back for spacing re-arms its protection when nothing protects it" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      travel 15.seconds
      g.hold_priority!(10)

      assert_equal 15, g.spacing_wait
    end

    test "re-arming leaves a protection that is already outstanding alone" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      travel 15.seconds
      g.reserve(priority: true)
      g.hold_priority!(10)
      travel 91.seconds

      assert_equal 0, g.spacing_wait
    end

    test "a new priority reservation keeps an earlier waiting start, however far ahead" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      g.hold_priority!(40)
      g.reserve(priority: true)
      travel 110.seconds

      assert_equal 15, g.spacing_wait
    end

    test "a priority turn that lost the slot to an ordinary fetch is protected again after it re-arms" do
      g = priority_gate(cap: 20, reserved: 5)
      g.reserve(priority: true)
      g.started!
      travel 15.seconds

      assert_equal 0, g.spacing_wait
      g.hold_priority!(1)

      assert_equal 15, g.spacing_wait
    end

    test "ordinary turns keep yielding to the earliest waiting priority turn when more are reserved behind it" do
      g = priority_gate(cap: 20, reserved: 5)
      g.started!
      travel 15.seconds
      3.times { g.reserve(priority: true) }

      assert_equal 15, g.spacing_wait
    end

    test "when a priority turn starts, ordinary turns yield to the next one reserved behind it" do
      g = priority_gate(cap: 20, reserved: 5)
      3.times { g.reserve(priority: true) }
      g.started!(priority: true)
      travel 14.seconds

      assert_equal 15, g.spacing_wait
    end

    test "usage keeps reporting the ordinary day and count" do
      g = priority_gate(cap: 20, reserved: 5)
      g.reserve
      g.reserve(priority: true)

      assert_equal [Time.current.utc.to_date, 1], g.usage.deconstruct
    end

    [[50, 100], [50, 50], [0, 100], [10, -5], [10, 0], [3, 2]].each do |cap, reserved|
      test "cap #{cap} with slice #{reserved}: no more than the cap is granted, and a refusal always reopens" do
        travel_to Time.utc(2026, 11, 17, 6, 0, 0)
        g = priority_gate(cap: cap, reserved: reserved)
        granted = 0
        300.times { granted += 1 if g.reserve.granted? }
        300.times { granted += 1 if g.reserve(priority: true).granted? }

        assert_operator granted, :<=, cap
        assert g.reopens_at, "ordinary refusal must reopen"
        assert g.reopens_at(priority: true), "priority refusal must reopen"
      end
    end

    test "a cap of zero refuses on a blank gate and reopens at the next UTC midnight" do
      travel_to Time.utc(2026, 11, 17, 6, 0, 0)
      g = priority_gate(cap: 0, reserved: 100)

      assert_equal :daily_cap, g.reserve.refusal
      assert_equal Time.utc(2026, 11, 18, 0, 0, 0), g.reopens_at
      assert_equal Time.utc(2026, 11, 18, 0, 0, 0), g.reopens_at(priority: true)
    end

    test "once the day's actual starts reach the cap every turn waits for the next UTC midnight" do
      travel_to Time.utc(2026, 11, 17, 6, 0, 0)
      g = priority_gate(cap: 3, reserved: 1)
      3.times do
        g.started!
        travel 15.seconds
      end
      to_midnight = Time.utc(2026, 11, 18, 0, 0, 0) - Time.current

      assert_equal [to_midnight, to_midnight], [g.spacing_wait, g.spacing_wait(priority: true)]

      travel_to Time.utc(2026, 11, 18, 0, 0, 0)

      assert_equal 0, g.spacing_wait

      # The new day's count starts from zero, not from yesterday's three.
      g.started!
      travel 15.seconds

      assert_equal 0, g.spacing_wait
    end

    # Starts at 15 s apart on one UTC day; returns nothing, only advances the clock.
    def start_turns(gate, ordinary: 0, priority: 0)
      ordinary.times do
        gate.started!
        travel 15.seconds
      end
      priority.times do
        gate.started!(priority: true)
        travel 15.seconds
      end
    end

    test "with no readers ordinary starts stop at the cap less the slice, and a reader still runs" do
      travel_to Time.utc(2026, 11, 17, 6, 0, 0)
      g = priority_gate(cap: 10, reserved: 3)
      start_turns(g, ordinary: 6)

      assert_equal 0, g.spacing_wait

      start_turns(g, ordinary: 1)
      to_midnight = Time.utc(2026, 11, 18, 0, 0, 0) - Time.current

      assert_equal [to_midnight, 0], [g.spacing_wait, g.spacing_wait(priority: true)]
    end

    test "priority starts release the slice they used to ordinary turns" do
      travel_to Time.utc(2026, 11, 17, 6, 0, 0)
      g = priority_gate(cap: 10, reserved: 3)
      start_turns(g, priority: 2, ordinary: 6)

      assert_equal 0, g.spacing_wait

      start_turns(g, ordinary: 1)

      assert_operator g.spacing_wait, :>, 0
    end

    test "priority starts past the slice leave nothing to hold back, and the cap is never exceeded" do
      travel_to Time.utc(2026, 11, 17, 6, 0, 0)
      g = priority_gate(cap: 10, reserved: 3)
      start_turns(g, priority: 4, ordinary: 5)

      assert_equal 0, g.spacing_wait

      start_turns(g, ordinary: 1)

      assert_operator g.spacing_wait, :>, 0
      assert_operator g.spacing_wait(priority: true), :>, 0
    end

    test "the day's priority starts roll over at midnight" do
      travel_to Time.utc(2026, 11, 17, 23, 0, 0)
      g = priority_gate(cap: 10, reserved: 3)
      start_turns(g, priority: 3)
      travel_to Time.utc(2026, 11, 18, 6, 0, 0)
      start_turns(g, ordinary: 7)

      assert_operator g.spacing_wait, :>, 0
    end

    test "yesterday's priority starts do not release today's slice before today's first start" do
      travel_to Time.utc(2026, 11, 17, 23, 0, 0)
      g = priority_gate(cap: 3, reserved: 3)
      start_turns(g, priority: 3)
      travel_to Time.utc(2026, 11, 18, 6, 0, 0)

      assert_operator g.spacing_wait, :>, 0
      assert_equal 0, g.spacing_wait(priority: true)
    end

    test "a cap of zero holds every due turn" do
      travel_to Time.utc(2026, 11, 17, 6, 0, 0)

      assert_operator priority_gate(cap: 0, reserved: 0).spacing_wait, :>, 0
    end

    test "a gate that never stored a start day counts the day as zero" do
      g = priority_gate(cap: 3, reserved: 1)
      @redis.hset("x", "last_start", (Time.current - 1.hour).to_i.to_s)

      assert_equal 0, g.spacing_wait
    end

    test "the block log line names the label" do
      Rails.logger.expects(:warn).with("Books::FetchGate: Acme blocked a fetch; no fetches for 21600s")

      gate("x", label: "Acme").block!
    end
  end
end
