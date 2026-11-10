# frozen_string_literal: true

module Books
  module Goodreads
    # One log line per Goodreads fetch that came back from the page fetcher,
    # whatever the parser made of it. Before this, a successful fetch logged
    # nothing and an error page logged nothing either: a step failed with
    # "unavailable" and the status that caused it was gone. Fetches that never
    # got a page (a timeout, a down fetcher) are logged where they are rescued.
    #
    #   Goodreads fetch: book 17912195 status=503 outcome=unavailable elapsed_ms=1713 selector_found=false
    #
    # Grep the worker log for "Goodreads fetch:" to see the 200/503 mix.
    module FetchLog
      def self.fetched(target:, page:, outcome:)
        Rails.logger.info("Goodreads fetch: #{target} status=#{page.status} outcome=#{outcome} " \
          "elapsed_ms=#{page.elapsed_ms} selector_found=#{page.selector_found.inspect}")
      end
    end
  end
end
