# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module GoodreadsPages
      # Searches Goodreads by title through the page fetcher, reads the result
      # rows with Books::Goodreads::SearchPage and caches the whole search
      # (enrichment spec §4.2). Pacing is the caller's.
      #
      # data[:outcome] is FetchPage's: :found and :no_results are stored as the
      # answer; :blocked and :unparseable are stored with the HTML for a later
      # look and the caller backs off; :unavailable and :fetcher_down store
      # nothing. A search already stored for the query is replaced.
      class FetchSearch
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        URL = "https://www.goodreads.com/search?q=%s"
        FETCHER_DOWN = FetchPage::FETCHER_DOWN

        def self.call(query:, client: nil)
          new(query: query, client: client).call
        end

        def initialize(query:, client:)
          @query = query.to_s
          @client = client
        end

        def call
          fetched = client.fetch(format(URL, CGI.escape(normalized_query)), wait_for_selector: config.wait_for_selector,
            timeout_ms: config.fetch_timeout_ms)
          parsed = ::Books::Goodreads::SearchPage.parse(html: fetched.html, status: fetched.status)
          return done(:unavailable) if parsed.outcome == :unavailable

          done(parsed.outcome, store(parsed, fetched))
        rescue *FETCHER_DOWN => e
          Rails.logger.error("#{self.class.name}: Goodreads search #{@query.inspect}: #{e.class}: #{e.message}")
          done(:fetcher_down)
        rescue ::PageFetcher::Exceptions::Error => e
          Rails.logger.warn("#{self.class.name}: Goodreads search #{@query.inspect}: #{e.class}: #{e.message}")
          done(:unavailable)
        end

        private

        def client = (@client ||= ::PageFetcher::Client.new)

        def config = Rails.application.config.x.goodreads

        # The model's own normalization, so the URL searched and the row
        # stored are one key.
        def normalized_query = (@normalized_query ||= ::Books::GoodreadsSearch.normalize_value_for(:query, @query))

        def store(parsed, fetched)
          search = ::Books::GoodreadsSearch.find_or_initialize_by(query: normalized_query)
          search.assign_attributes(
            outcome: parsed.outcome, fetched_at: fetched.fetched_at, http_status: fetched.status,
            parser_version: ::Books::Goodreads::SearchPage::VERSION,
            rows: parsed.rows.map(&:to_h)
          )
          search.html.attach(io: StringIO.new(Zlib.gzip(fetched.html)), filename: "goodreads-search.html.gz",
            content_type: "application/gzip", identify: false, metadata: {analyzed: true})
          search.save!
          search
        end

        def done(outcome, search = nil)
          Result.new(success?: true, data: {outcome: outcome, search: search}, errors: [])
        end
      end
    end
  end
end
