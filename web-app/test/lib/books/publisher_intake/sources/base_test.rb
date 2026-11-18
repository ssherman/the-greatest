# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    module Sources
      class BaseTest < ActiveSupport::TestCase
        class TestSource < Base
          VERSION = 7
        end

        setup { @source = TestSource.new }

        test "parser_version is the strategy's VERSION" do
          assert_equal 7, @source.parser_version
        end

        test "defaults: no baseline and no seed requests" do
          assert_equal [false, []], [@source.baseline_on_first_run?, @source.seed_requests]
        end

        test "required methods raise NotImplementedError" do
          assert_raises(NotImplementedError) { @source.key }
          assert_raises(NotImplementedError) { @source.parse_listing(listing: nil, page: nil) }
        end

        test "status_outcome maps statuses to outcomes" do
          table = {404 => :not_found, 410 => :not_found, 401 => :blocked, 403 => :blocked, 429 => :blocked,
                   500 => :unavailable, 503 => :unavailable, 200 => nil, 301 => nil, 400 => nil}

          assert_equal table, table.keys.index_with { |status| @source.status_outcome(status) }
        end

        test "in_window? is true across the lookback and horizon, inclusive" do
          travel_to Time.zone.local(2026, 11, 17, 12) do
            today = Date.current

            assert_equal [true, true, true], [today, today - 30, today + 365].map { |d| @source.in_window?(d) }
          end
        end

        test "in_window? is false outside the window and for nil" do
          travel_to Time.zone.local(2026, 11, 17, 12) do
            today = Date.current

            assert_equal [false, false, false], [today - 31, today + 366, nil].map { |d| @source.in_window?(d) }
          end
        end
      end
    end
  end
end
