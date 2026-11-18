# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class RecordDiscoveryTest < ActiveSupport::TestCase
        Ref = ::Books::PublisherIntake::ListingRef

        setup do
          @run = ::Books::PublisherIntakeRun.create!(source: "hachette_us", kind: :weekly, status: :running,
            baseline: false, started_at: Time.current)
          @url = "https://www.hachettebookgroup.com/titles/x/new-one/9780316111111/"
        end

        def call(refs, run: @run, seed: false)
          RecordDiscovery.call(run: run, listings: refs, seed: seed)
        end

        def listing(url = @url) = ::Books::PublisherListing.find_by!(source: "hachette_us", url: url)

        test "a new url on a normal run is created pending" do
          result = call([Ref.new(url: @url, external_key: "9780316111111", signal: "2026-11-01")])

          assert result.success?
          assert_equal({seen: 1, created: 1, changed: 0}, result.data)
          row = listing
          assert row.state_pending?
          assert_equal ["9780316111111", "2026-11-01"], [row.external_key, row.signal]
          assert_not_nil row.first_seen_at
          assert_not_nil row.last_seen_at
        end

        test "a new url on a baseline run is created baseline" do
          @run.update!(baseline: true)
          call([Ref.new(url: @url, external_key: nil, signal: nil)])

          assert listing.state_baseline?
        end

        test "a new url on a baseline run with seed is created pending" do
          @run.update!(baseline: true)
          call([Ref.new(url: @url, external_key: nil, signal: nil)], seed: true)

          assert listing.state_pending?
        end

        test "a baseline listing becomes pending when seeded" do
          row = books_publisher_listings(:baseline_listing)
          call([Ref.new(url: row.url, external_key: row.external_key, signal: nil)], seed: true)

          assert row.reload.state_pending?
        end

        test "a baseline listing stays baseline when not seeded and last_seen_at moves" do
          row = books_publisher_listings(:baseline_listing)
          before = row.last_seen_at
          call([Ref.new(url: row.url, external_key: row.external_key, signal: nil)])

          assert row.reload.state_baseline?
          assert_operator row.last_seen_at, :>, before
        end

        test "a read listing whose signal changed becomes pending, counted as changed" do
          row = books_publisher_listings(:read_listing)
          result = call([Ref.new(url: row.url, external_key: row.external_key, signal: "2026-11-12")])

          assert_equal({seen: 1, created: 0, changed: 1}, result.data)
          assert row.reload.state_pending?
          assert_equal "2026-11-12", row.signal
        end

        test "a read listing with the same or no signal is left read" do
          row = books_publisher_listings(:read_listing)
          result = call([Ref.new(url: row.url, external_key: nil, signal: row.signal)])
          assert_equal 0, result.data[:changed]
          assert row.reload.state_read?

          call([Ref.new(url: row.url, external_key: nil, signal: nil)])
          assert row.reload.state_read?
          assert_equal "2026-11-01", row.signal
        end

        test "a known listing stores a signal it did not have" do
          row = books_publisher_listings(:baseline_listing)
          call([Ref.new(url: row.url, external_key: row.external_key, signal: "2026-11-05")])

          assert_equal "2026-11-05", row.reload.signal
        end

        test "a pending listing is only touched" do
          row = books_publisher_listings(:pending_listing)
          before = row.last_seen_at
          result = call([Ref.new(url: row.url, external_key: row.external_key, signal: "other")])

          assert_equal 0, result.data[:changed]
          assert row.reload.state_pending?
          assert_equal "2026-11-09", row.signal
          assert_operator row.last_seen_at, :>, before
        end

        test "a covered or failed listing is only touched" do
          covered = books_publisher_listings(:covered_listing)
          call([Ref.new(url: covered.url, external_key: nil, signal: "x")])
          assert covered.reload.state_covered?

          failed = books_publisher_listings(:failed_listing)
          run = ::Books::PublisherIntakeRun.create!(source: "macmillan_us", kind: :weekly, status: :running,
            baseline: false, started_at: Time.current)
          call([Ref.new(url: failed.url, external_key: nil, signal: "x")], run: run)
          assert failed.reload.state_failed?
        end

        test "a blank url is skipped" do
          assert_no_difference -> { ::Books::PublisherListing.count } do
            result = call([Ref.new(url: "", external_key: nil, signal: nil), Ref.new(url: nil, external_key: nil, signal: nil)])
            assert_equal({seen: 0, created: 0, changed: 0}, result.data)
          end
        end

        test "the same url twice in one call makes one listing" do
          ref = Ref.new(url: @url, external_key: nil, signal: nil)
          result = call([ref, ref])

          assert_equal({seen: 1, created: 1, changed: 0}, result.data)
          assert_equal 1, ::Books::PublisherListing.where(url: @url).count
        end

        test "counts are added to the run and survive a second call" do
          call([Ref.new(url: @url, external_key: nil, signal: nil)])
          call([Ref.new(url: @url, external_key: nil, signal: nil),
            Ref.new(url: "#{@url}2", external_key: nil, signal: nil)])

          counts = @run.reload.counts
          assert_equal [3, 2, 0], [counts["listings_seen"], counts["listings_new"], counts["listings_changed"]]
        end

        test "other counts on the run are kept" do
          @run.update!(counts: {"requests" => 4})
          call([Ref.new(url: @url, external_key: nil, signal: nil)])

          assert_equal 4, @run.reload.counts["requests"]
        end
      end
    end
  end
end
