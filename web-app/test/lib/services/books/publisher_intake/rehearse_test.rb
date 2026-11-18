# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class RehearseTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        Request = ::Books::PublisherIntake::Request
        Reading = ::Books::PublisherIntake::Reading
        Discovery = ::Books::PublisherIntake::Discovery
        Ref = ::Books::PublisherIntake::ListingRef
        Strategy = PublisherIntakeFetchHelper::TestStrategy

        setup do
          setup_intake_fetching
          ::Books::PublisherIntake.settings.enabled_sources = []
          @out = StringIO.new
          @sleeps = []
          @sleeper = ->(seconds) { @sleeps << seconds }
          @strategy = Strategy.new
        end

        teardown { teardown_intake_fetching }

        def ref(n) = Ref.new(url: "https://x.test/t/#{n}", external_key: "978080216999#{n}", signal: nil)

        def rehearse(limit: 5, max: nil) = Rehearse.call(source: @strategy, limit: limit, max_discovery_requests: max, out: @out, sleeper: @sleeper)

        def found_reading
          Reading.new(outcome: :found, sibling_keys: [], facts: {title: "A Fine Book", language: "English", genres: ["Fiction"],
                                                                 contributors: [{name: "Ada Example", role: "author"}],
                                                                 formats: [{isbn13: "9780802169990", format: :hardcover, format_label: "Hardcover", on_sale_on: "2027-03-02"}]})
        end

        test "reads at most limit listings and reports outcomes and holds" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/sitemap")]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [ref(1), ref(2), ref(3)], requests: [])
          Strategy.listing_reading = found_reading
          @client.stubs(:fetch).returns(page_response)

          result = rehearse(limit: 2)

          assert result.success?
          assert_equal({requests: 1, listings_seen: 3, read: 2}, result.data.slice(:requests, :listings_seen, :read))
          assert_equal({found: 2}, result.data[:outcomes])
          assert_equal({}, result.data[:held])
          assert_equal 1, ::Books::PublisherListing.where(source: SOURCE, state: :pending).count
          run = ::Books::PublisherIntakeRun.find_by!(source: SOURCE)
          assert run.kind_manual?
          assert run.status_finished?
        end

        test "counts the titles it held by reason" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/sitemap")]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [ref(1)], requests: [])
          Strategy.listing_reading = Reading.new(outcome: :found, sibling_keys: [], facts: found_reading.facts.merge(genres: ["Fiction"], title: "Box Set"))
          ::Books::PublisherIntake::Hold.stubs(:call).returns([:held, :set])
          @client.stubs(:fetch).returns(page_response)

          assert_equal({set: 1}, rehearse.data[:held])
        end

        test "waits between fetches, not before the first, and never uses the gate" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/sitemap")]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [ref(1), ref(2)], requests: [])
          Strategy.listing_reading = found_reading
          @client.stubs(:fetch).returns(page_response)
          @gate.expects(:reserve).never

          rehearse

          assert_equal [10, 10], @sleeps
        end

        test "prints a line per fetch with its URL and elapsed time and no page content" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/sitemap")]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [ref(1)], requests: [])
          Strategy.listing_reading = found_reading
          @client.stubs(:fetch).returns(page_response(html: "<html>SECRET PAGE BODY</html>"))

          rehearse

          assert_includes @out.string, "https://x.test/sitemap"
          assert_match(%r{https://x.test/t/1 status 200 \d+ms}, @out.string)
          assert_includes @out.string, "outcome found"
          assert_not_includes @out.string, "SECRET PAGE BODY"
        end

        test "stops discovery after max_discovery_requests and saves the run as failed" do
          first, second = Request.page("https://x.test/a"), Request.page("https://x.test/b")
          Strategy.discovery_requests_value = [first, second]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [], requests: [])
          @client.expects(:fetch).once.returns(page_response)

          result = rehearse(max: 1)

          assert_equal 1, result.data[:requests]
          assert ::Books::PublisherIntakeRun.find_by!(source: SOURCE).status_failed?
        end

        test "follows follow-ups and reaches seed requests last" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/a")]
          Strategy.seed_requests_value = [Request.page("https://x.test/seed")]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [], requests: [])
          urls = []
          @client.stubs(:fetch).with { |url, **| urls << url }.returns(page_response)
          Strategy.any_instance.stubs(:parse_discovery).returns(
            Discovery.new(outcome: :ok, listings: [], requests: [Request.page("https://x.test/child")]),
            Discovery.new(outcome: :ok, listings: [], requests: []),
            Discovery.new(outcome: :ok, listings: [], requests: [])
          )

          rehearse

          assert_equal %w[https://x.test/a https://x.test/seed https://x.test/child], urls
          assert ::Books::PublisherIntakeRun.find_by!(source: SOURCE).status_finished?
        end

        test "a discovery request that does not parse fails the run and reads nothing" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/a")]
          Strategy.discovery_value = nil
          @client.expects(:fetch).once.returns(page_response)
          new_pending_listing

          result = rehearse

          assert_equal 0, result.data[:read]
          assert ::Books::PublisherIntakeRun.find_by!(source: SOURCE).status_failed?
        end

        test "uses no gate turn, so nothing counts against the daily cap" do
          Strategy.discovery_requests_value = [Request.page("https://x.test/a")]
          Strategy.discovery_value = Discovery.new(outcome: :ok, listings: [], requests: [])
          @client.stubs(:fetch).returns(page_response)

          rehearse

          assert_equal 0, @gate.usage.count
        end

        test "refuses to run in production, creating and fetching nothing" do
          Rails.env.stubs(:production?).returns(true)
          @client.expects(:fetch).never

          result = nil
          assert_no_difference -> { ::Books::PublisherIntakeRun.count } do
            result = rehearse
          end

          assert_not result.success?
          assert_empty @sleeps
        end
      end
    end
  end
end
