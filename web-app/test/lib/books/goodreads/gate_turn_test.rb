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

      test "after_fetch blocks the gate on an unparseable page" do
        g = mock
        g.expects(:block!).once

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
