# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class ReadListingTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        Reading = ::Books::PublisherIntake::Reading
        Request = ::Books::PublisherIntake::Request
        TIMEOUT = 30_000

        setup do
          freeze_time
          setup_intake_fetching
          @listing = new_pending_listing
        end

        teardown { teardown_intake_fetching }

        def facts
          {title: "A Fine Book", contributors: [{name: "Ada Example", role: "author"}],
           formats: [{isbn13: "9780802169990", format: :hardcover, on_sale_on: "2027-03-02"}]}
        end

        def reading(outcome, facts: nil) = Reading.new(outcome: outcome, facts: facts, sibling_keys: [])

        def read(due: true, listing: @listing) = ReadListing.call(listing: listing, due: due)

        test "a pending listing is fetched, parsed and stored" do
          @client.expects(:fetch).returns(page_response)
          PublisherIntakeFetchHelper::TestStrategy.listing_reading = reading(:found, facts: facts)

          result = read

          assert_equal [:done, :found], [result.data[:action], result.data[:outcome]]
          assert_predicate @listing.reload, :state_read?
          assert_equal 7, @listing.parser_version
          assert_equal "A Fine Book", @listing.publisher_title.title
          assert_equal @listing, PublisherIntakeFetchHelper::TestStrategy.seen[:listing]
        end

        test "a page request and a file request call fetch and fetch_file with the settings timeout" do
          PublisherIntakeFetchHelper::TestStrategy.listing_reading = reading(:unparseable)
          @client.expects(:fetch).with(@listing.url, wait_for_selector: "h1", timeout_ms: TIMEOUT).returns(page_response)
          read
          travel 10.seconds

          PublisherIntakeFetchHelper::TestStrategy.listing_request_value = Request.file("https://x.test/f.pdf", page_url: "https://x.test/p")
          @client.expects(:fetch_file).with("https://x.test/f.pdf", page_url: "https://x.test/p", timeout_ms: TIMEOUT)
            .returns(file_response)
          read
        end

        test "a refused turn fetches nothing and leaves the listing pending" do
          @gate.block!
          @client.expects(:fetch).never

          result = read(due: false)

          assert_equal :refused, result.data[:action]
          assert_predicate @listing.reload, :state_pending?
          assert_nil @listing.queued_at
        end

        test "a wait is returned without fetching" do
          @gate.reserve
          @client.expects(:fetch).never

          result = read(due: false)

          assert_equal [:wait, 10], [result.data[:action], result.data[:wait]]
          assert_predicate @listing.reload, :state_pending?
        end

        test "a blocked page blocks the gate for that source only" do
          other = ::Books::FetchGate.new(key: "test:other", config: ::Books::PublisherIntake.settings, label: "o",
            redis: ::Books::OpenLibrary::FakeRedis.new)
          @client.stubs(:fetch).returns(page_response(status: 403))
          PublisherIntakeFetchHelper::TestStrategy.listing_reading = reading(:blocked)

          read

          assert_predicate @gate, :blocked?
          assert_not other.blocked?
          assert_predicate @listing.reload, :state_pending?
          assert_equal "blocked", @listing.last_attempt_outcome
        end

        test "an unparseable page does not block the gate" do
          @client.stubs(:fetch).returns(page_response)
          PublisherIntakeFetchHelper::TestStrategy.listing_reading = reading(:unparseable)

          read

          assert_not @gate.blocked?
          assert_equal "unparseable", @listing.reload.last_attempt_outcome
        end

        test "a fetcher-down error stores nothing and does not count as an attempt" do
          [PageFetcher::Exceptions::CircuitOpenError.new("open"), PageFetcher::Exceptions::ConfigurationError.new("config"),
            PageFetcher::Exceptions::ClientError.new("refused", 400)].each do |error|
            @client.stubs(:fetch).raises(error)
            travel 10.seconds
            result = read
            assert_equal [:done, :fetcher_down], [result.data[:action], result.data[:outcome]]
          end

          @listing.reload
          assert_equal [0, "pending", "fetcher_down", nil], [@listing.attempts, @listing.state, @listing.last_attempt_outcome, @listing.queued_at]
          assert_not @listing.html.attached?
        end

        test "a timeout counts as an unavailable attempt" do
          @client.stubs(:fetch).raises(PageFetcher::Exceptions::TimeoutError, "slow")

          result = read

          assert_equal :unavailable, result.data[:outcome]
          assert_equal [1, "pending", "unavailable"], [@listing.reload.attempts, @listing.state, @listing.last_attempt_outcome]
        end

        test "a listing whose source is switched off is skipped without a gate turn" do
          ::Books::PublisherIntake.settings.enabled_sources = []
          @client.expects(:fetch).never

          result = read(due: false)

          assert_equal :skipped, result.data[:action]
          assert_equal 0, @gate.usage.count
        end

        test "a listing whose source has no strategy is skipped" do
          listing = new_pending_listing(source: "nonexistent")
          ::Books::PublisherIntake.settings.enabled_sources = ["nonexistent"]
          @client.expects(:fetch).never

          assert_equal :skipped, read(listing: listing).data[:action]
        end

        test "a listing that is no longer pending is skipped" do
          @listing.update!(state: :covered)
          @client.expects(:fetch).never

          result = read(due: false)

          assert_equal :skipped, result.data[:action]
          assert_equal 0, @gate.usage.count
        end
      end
    end
  end
end
