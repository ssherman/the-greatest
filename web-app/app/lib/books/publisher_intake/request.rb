# frozen_string_literal: true

module Books
  module PublisherIntake
    # What to fetch. kind "file" goes through PageFetcher::Client#fetch_file,
    # "page" through #fetch. It travels through Sidekiq, so it round-trips
    # through string-keyed JSON-safe hashes.
    Request = Data.define(:kind, :url, :page_url, :wait_for_selector, :context) do
      def self.page(url, wait_for_selector: nil, context: {})
        new(kind: "page", url: url, page_url: nil, wait_for_selector: wait_for_selector, context: context)
      end

      def self.file(url, page_url: nil, context: {})
        new(kind: "file", url: url, page_url: page_url, wait_for_selector: nil, context: context)
      end

      def self.from_h(hash)
        hash = hash.to_h.transform_keys(&:to_s)
        new(
          kind: hash["kind"],
          url: hash["url"],
          page_url: hash["page_url"],
          wait_for_selector: hash["wait_for_selector"],
          context: (hash["context"] || {}).to_h.transform_keys(&:to_s)
        )
      end

      def to_h
        {
          "kind" => kind,
          "url" => url,
          "page_url" => page_url,
          "wait_for_selector" => wait_for_selector,
          "context" => context
        }
      end
    end
  end
end
