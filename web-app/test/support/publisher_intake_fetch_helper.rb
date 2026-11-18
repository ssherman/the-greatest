# frozen_string_literal: true

# Shared setup for the publisher intake fetching tests: a throwaway strategy
# registered under "test_source", a gate on FakeRedis (CI has no Redis) and a
# Mocha client. The strategy's answers are set per test on its class.
module PublisherIntakeFetchHelper
  class TestStrategy < Books::PublisherIntake::Sources::Base
    VERSION = 7

    class << self
      attr_accessor :listing_request_value, :listing_reading, :discovery_value, :seen
    end

    def key = "test_source"

    def name = "Test source"

    def listing_request(listing)
      self.class.listing_request_value || Books::PublisherIntake::Request.page(listing.url, wait_for_selector: "h1")
    end

    def parse_listing(listing:, page:)
      self.class.seen = {listing: listing, page: page}
      self.class.listing_reading
    end

    def parse_discovery(request:, response:)
      self.class.seen = {request: request, response: response}
      self.class.discovery_value
    end
  end

  SOURCE = "test_source"

  def setup_intake_fetching
    @original_enabled = Books::PublisherIntake.settings.enabled_sources
    Books::PublisherIntake.settings.enabled_sources = [SOURCE]
    Books::PublisherIntake::Sources.stubs(:registry).returns({SOURCE => TestStrategy})
    TestStrategy.listing_request_value = nil
    TestStrategy.listing_reading = nil
    TestStrategy.discovery_value = nil
    TestStrategy.seen = nil
    config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 10, daily_fetch_cap: 100, block_cooldown: 6.hours.to_i)
    @gate = Books::FetchGate.new(key: "test:gate", config: config, label: SOURCE, redis: Books::OpenLibrary::FakeRedis.new)
    Books::PublisherIntake.stubs(:gate_for).returns(@gate)
    @client = mock("page fetcher client")
    Books::PublisherIntake.stubs(:client).returns(@client)
  end

  def teardown_intake_fetching
    Books::PublisherIntake.settings.enabled_sources = @original_enabled
  end

  def page_response(html: "<html>page</html>", status: 200)
    PageFetcher::Page.new(url: "https://x.test/", final_url: "https://x.test/", status: status, title: "T", html: html,
      selector_found: true, elapsed_ms: 10, fetched_at: Time.current)
  end

  def file_response
    PageFetcher::FileResponse.new(url: "https://x.test/s.xml.gz", final_url: "https://x.test/s.xml.gz", status: 200,
      content_type: "application/gzip", body: "bytes".b, elapsed_ms: 10, fetched_at: Time.current)
  end

  def new_pending_listing(source: SOURCE, state: :pending)
    Books::PublisherListing.create!(source: source, url: "https://x.test/#{SecureRandom.hex(4)}", external_key: "9780802169990",
      state: state, first_seen_at: Time.current, last_seen_at: Time.current, queued_at: Time.current)
  end

  def new_running_run(source: SOURCE, counts: {"requests" => 1, "outstanding" => 1})
    Books::PublisherIntakeRun.create!(source: source, kind: :weekly, status: :running, baseline: false,
      started_at: Time.current, counts: counts)
  end
end
