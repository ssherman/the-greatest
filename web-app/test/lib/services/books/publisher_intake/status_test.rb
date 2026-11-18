# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class StatusTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        setup { setup_intake_fetching }
        teardown { teardown_intake_fetching }

        def new_title(source: SOURCE, status: :ready, hold_reason: nil)
          ::Books::PublisherTitle.create!(source: source, title: "T", status: status, hold_reason: hold_reason,
            isbn13s: [SecureRandom.random_number(10**12).to_s.rjust(12, "0") + "0"], first_read_at: Time.current, last_read_at: Time.current)
        end

        def entry(key) = Status.call.data[:sources].find { |s| s[:key] == key }

        test "reports listings by state and titles by status and hold reason per source" do
          new_pending_listing
          new_pending_listing
          new_pending_listing(state: :baseline)
          new_title
          new_title(status: :held, hold_reason: :set)
          new_title(status: :held, hold_reason: :set)
          new_title(status: :held, hold_reason: :non_english)
          run = new_running_run

          source = entry(SOURCE)

          assert_equal({pending: 2, baseline: 1}, source[:listings])
          assert_equal({ready: 1, held: {set: 2, non_english: 1}}, source[:titles])
          assert_equal [SOURCE, "Test source", true, true], source.values_at(:key, :name, :enabled, :registered)
          assert_equal [run.id, "running"], [source[:last_run][:id], source[:last_run][:status]]
        end

        test "includes a source that has rows but is no longer registered" do
          new_pending_listing(source: "gone_press")
          new_title(source: "gone_press")

          source = entry("gone_press")

          assert_equal [false, false], source.values_at(:registered, :enabled)
          assert_equal({pending: 1}, source[:listings])
          assert_equal 1, source[:titles][:ready]
          assert_not_nil entry(SOURCE)
        end

        test "reports today's fetch count, the cap and blocked_until from the source's gate" do
          travel_to Time.utc(2026, 11, 18, 12, 0, 0) do
            2.times { @gate.reserve }
            @gate.block!
            source = entry(SOURCE)

            assert_equal 2, source[:fetches_today]
            assert_equal ::Books::PublisherIntake.settings.daily_fetch_cap, source[:daily_cap]
            assert_equal 6.hours.from_now.to_i, source[:blocked_until].to_i
          end
        end

        test "a count from another day is not today's" do
          travel_to Time.utc(2026, 11, 17, 12, 0, 0) { @gate.reserve }
          travel_to Time.utc(2026, 11, 18, 12, 0, 0) do
            assert_equal 0, entry(SOURCE)[:fetches_today]
          end
        end

        test "includes every registered source" do
          keys = Status.call.data[:sources].map { |s| s[:key] }

          assert_empty ::Books::PublisherIntake::Sources.registry.keys - keys
        end
      end
    end
  end
end
