# frozen_string_literal: true

module Services
  module Books
    module PublisherIntake
      # Fetches one Books::PublisherIntake::Request through the page fetcher and
      # classifies a failure the way Services::Books::GoodreadsPages::FetchPage
      # does. Shared by ReadListing and RunDiscoveryRequest. Never stores
      # anything, and never logs a response: only the error class and message of
      # a failure, which carry no page body.
      #
      # Returns [response, nil] on an answer (a PageFetcher::Page for kind "page",
      # a PageFetcher::FileResponse for "file"), or [nil, :fetcher_down |
      # :unavailable].
      module FetchRequest
        FETCHER_DOWN = Services::Books::GoodreadsPages::FetchPage::FETCHER_DOWN

        def self.call(request)
          timeout_ms = ::Books::PublisherIntake.settings.fetch_timeout_ms
          client = ::Books::PublisherIntake.client
          response =
            if request.kind == "file"
              client.fetch_file(request.url, page_url: request.page_url, timeout_ms: timeout_ms)
            else
              client.fetch(request.url, wait_for_selector: request.wait_for_selector, timeout_ms: timeout_ms)
            end
          [response, nil]
        rescue *FETCHER_DOWN => e
          Rails.logger.error("PublisherIntake fetch: #{e.class}: #{e.message}")
          [nil, :fetcher_down]
        rescue ::PageFetcher::Exceptions::Error => e
          Rails.logger.warn("PublisherIntake fetch: #{e.class}: #{e.message}")
          [nil, :unavailable]
        end
      end
    end
  end
end
