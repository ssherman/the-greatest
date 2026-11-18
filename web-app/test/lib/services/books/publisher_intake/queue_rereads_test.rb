# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class QueueRereadsTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        setup do
          freeze_time
          setup_intake_fetching
          @source = ::Books::PublisherIntake::Sources.fetch(SOURCE)
        end

        teardown { teardown_intake_fetching }

        def title(status: :ready, hold_reason: nil, on_sale_on: nil)
          ::Books::PublisherTitle.create!(source: SOURCE, title: "Title #{SecureRandom.hex(3)}", status: status,
            hold_reason: hold_reason, on_sale_on: on_sale_on)
        end

        def listing(title:, signal: nil, read_at: 40.days.ago, state: :read, source: SOURCE)
          ::Books::PublisherListing.create!(source: source, url: "https://x.test/#{SecureRandom.hex(4)}",
            external_key: SecureRandom.hex(4), state: state, signal: signal, read_at: read_at,
            publisher_title: title, first_seen_at: 50.days.ago, last_seen_at: 1.day.ago)
        end

        def queue = QueueRereads.call(source: @source)

        test "a held placeholder older than 28 days is re-read whether or not the source has a signal" do
          with_signal = listing(title: title(status: :held, hold_reason: :placeholder), signal: "v1")
          without = listing(title: title(status: :held, hold_reason: :incomplete))

          assert_equal 2, queue.data[:queued]
          assert_predicate with_signal.reload, :state_pending?
          assert_predicate without.reload, :state_pending?
          assert_nil with_signal.queued_at
        end

        test "a future-dated title is re-read only when its listing has no signal" do
          future = title(on_sale_on: Date.current + 30)
          undated = title(on_sale_on: nil)
          signalled = listing(title: future, signal: "v1")
          plain_future = listing(title: future)
          plain_undated = listing(title: undated)

          assert_equal 2, queue.data[:queued]
          assert_predicate signalled.reload, :state_read?
          assert_predicate plain_future.reload, :state_pending?
          assert_predicate plain_undated.reload, :state_pending?
        end

        test "a title already on sale, or read within 28 days, is left alone" do
          on_sale = listing(title: title(on_sale_on: Date.current - 1))
          recent = listing(title: title(status: :held, hold_reason: :placeholder), read_at: 5.days.ago)

          assert_equal 0, queue.data[:queued]
          assert_predicate on_sale.reload, :state_read?
          assert_predicate recent.reload, :state_read?
        end

        test "listings in other states and of other sources are left alone" do
          held = title(status: :held, hold_reason: :placeholder)
          failed = listing(title: held, state: :failed)
          other = listing(title: held, source: "removed_source")

          assert_equal 0, queue.data[:queued]
          assert_predicate failed.reload, :state_failed?
          assert_predicate other.reload, :state_read?
        end

        def failed_listing(outcome: :unavailable, attempted: 8.days.ago, source: SOURCE)
          ::Books::PublisherListing.create!(source: source, url: "https://x.test/#{SecureRandom.hex(4)}", external_key: SecureRandom.hex(4),
            state: :failed, attempts: 3, last_attempt_outcome: outcome, last_attempt_at: attempted, queued_at: 9.days.ago,
            first_seen_at: 50.days.ago, last_seen_at: 1.day.ago)
        end

        test "a listing that failed unavailable more than 7 days ago goes back to pending with its attempts reset" do
          failed = failed_listing

          result = queue

          failed.reload
          assert_equal 1, result.data[:revived]
          assert_equal 0, result.data[:queued]
          assert_predicate failed, :state_pending?
          assert_equal 0, failed.attempts
          assert_nil failed.queued_at
        end

        test "a listing that failed unavailable 6 days ago is left failed" do
          failed = failed_listing(attempted: 6.days.ago)

          assert_equal 0, queue.data[:revived]
          assert_predicate failed.reload, :state_failed?
        end

        test "a not found listing is never revived" do
          failed = failed_listing(outcome: :not_found, attempted: 90.days.ago)

          assert_equal 0, queue.data[:revived]
          assert_predicate failed.reload, :state_failed?
        end

        test "a failed listing of another source is left alone" do
          failed = failed_listing(source: "removed_source")

          assert_equal 0, queue.data[:revived]
          assert_predicate failed.reload, :state_failed?
        end
      end
    end
  end
end
