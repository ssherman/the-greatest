# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class RunDiscoveryRequestTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        Discovery = ::Books::PublisherIntake::Discovery
        Request = ::Books::PublisherIntake::Request
        Ref = ::Books::PublisherIntake::ListingRef
        URL = "https://x.test/sitemap.xml"

        setup do
          freeze_time
          setup_intake_fetching
          @run = new_running_run
          @request = Request.page(URL)
        end

        teardown { teardown_intake_fetching }

        def discovery(outcome, listings: [], requests: [])
          PublisherIntakeFetchHelper::TestStrategy.discovery_value = Discovery.new(outcome: outcome, listings: listings, requests: requests)
        end

        def run_request(request: @request, due: true, attempt: 1) = RunDiscoveryRequest.call(run: @run, request: request, due: due, attempt: attempt)

        test "an ok response records listings and returns the follow-up requests" do
          child = Request.page("https://x.test/child.xml")
          @client.expects(:fetch).returns(page_response)
          discovery(:ok, listings: [Ref.new(url: "https://x.test/t/1", external_key: "9780802169990", signal: "a")], requests: [child])

          result = run_request

          assert_equal [:done, [child]], [result.data[:action], result.data[:requests]]
          assert_equal "pending", ::Books::PublisherListing.find_by!(source: "test_source", url: "https://x.test/t/1").state
        end

        test "a file request hands the file response to the strategy" do
          @client.expects(:fetch_file).with(URL, page_url: nil, timeout_ms: 30_000).returns(file_response)
          discovery(:ok)

          run_request(request: Request.file(URL))

          assert_kind_of PageFetcher::FileResponse, PublisherIntakeFetchHelper::TestStrategy.seen[:response]
        end

        test "a seed request's listings are pending even in a baseline run" do
          @run.update!(baseline: true)
          @client.stubs(:fetch).returns(page_response)
          discovery(:ok, listings: [Ref.new(url: "https://x.test/t/2", external_key: "9780802169990", signal: "a")])

          run_request(request: Request.page(URL, context: {"seed" => true}))
          travel 10.seconds
          discovery(:ok, listings: [Ref.new(url: "https://x.test/t/3", external_key: "9780802170002", signal: "a")])
          run_request

          states = ::Books::PublisherListing.where(url: ["https://x.test/t/2", "https://x.test/t/3"]).order(:url).pluck(:state)
          assert_equal %w[pending baseline], states
        end

        test "a refused turn waits until the gate reopens" do
          @gate.block!
          @client.expects(:fetch).never

          result = run_request(due: false)

          assert_equal :wait, result.data[:action]
          assert_equal 6.hours.to_i, result.data[:wait]
        end

        test "a refused turn with nothing to reopen waits at least a minute" do
          @gate.stubs(:reserve).returns(::Books::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
          @gate.stubs(:reopens_at).returns(nil)

          assert_equal 60, run_request(due: false).data[:wait]
        end

        test "a wait from the gate is returned without fetching" do
          @gate.reserve
          @client.expects(:fetch).never

          result = run_request(due: false)

          assert_equal [:wait, 10], [result.data[:action], result.data[:wait]]
        end

        test "a blocked response blocks the gate and waits for the cooldown; the run stays running" do
          @client.stubs(:fetch).returns(page_response(status: 403))
          discovery(:blocked)

          result = run_request

          assert_predicate @gate, :blocked?
          assert_equal [:wait, 6.hours.to_i], [result.data[:action], result.data[:wait]]
          assert_predicate @run.reload, :status_running?
        end

        test "unavailable retries until fetch_attempts, then fails the run with the url in the error" do
          @client.stubs(:fetch).raises(PageFetcher::Exceptions::TimeoutError, "slow")

          assert_equal :retry, run_request(attempt: 2).data[:action]
          assert_predicate @run.reload, :status_running?
          travel 10.seconds

          result = run_request(attempt: 3)

          assert_equal :done, result.data[:action]
          @run.reload
          assert_predicate @run, :status_failed?
          assert_includes @run.error, URL
          assert_includes @run.error, "unavailable"
          assert_equal Time.current, @run.finished_at
        end

        test "a fetcher-down error retries the same way" do
          @client.stubs(:fetch).raises(PageFetcher::Exceptions::CircuitOpenError, "open")

          assert_equal :retry, run_request.data[:action]
          travel 10.seconds
          assert_equal :done, run_request(attempt: 3).data[:action]
          assert_includes @run.reload.error, "fetcher_down"
        end

        test "an unavailable response from the strategy is handled as a failed fetch" do
          @client.stubs(:fetch).returns(page_response(status: 503))
          discovery(:unavailable)

          assert_equal :retry, run_request.data[:action]
        end

        test "an unparseable response fails the run at once" do
          @client.stubs(:fetch).returns(page_response(html: "<secret body>"))
          discovery(:unparseable)

          result = run_request

          assert_equal :done, result.data[:action]
          @run.reload
          assert_predicate @run, :status_failed?
          assert_includes @run.error, URL
          assert_not_includes @run.error, "secret body"
        end

        test "a request for a run that is not running is skipped" do
          @run.update!(status: :finished)
          @client.expects(:fetch).never

          result = run_request(due: false)

          assert_equal :skipped, result.data[:action]
          assert_equal 0, @gate.usage.count
        end

        test "a run whose source is switched off is skipped" do
          ::Books::PublisherIntake.settings.enabled_sources = []
          @client.expects(:fetch).never

          assert_equal :skipped, run_request(due: false).data[:action]
        end
      end
    end
  end
end
