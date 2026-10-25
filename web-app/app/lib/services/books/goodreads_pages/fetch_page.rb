# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module GoodreadsPages
      # Fetches one Goodreads book page through the page fetcher, reads it
      # with Books::Goodreads::BookPage, and stores the answer (Goodreads
      # import spec §6). Pacing is Books::Goodreads::FetchPageJob's: this
      # fetches when called.
      #
      # data[:outcome]:
      # - :found, :not_found: stored, and the answer from now on;
      # - :blocked, :unparseable: stored with the HTML for a later look, and
      #   fetched again later; the caller stops all fetches for a while;
      # - :unavailable: Goodreads' error page, a timeout or a network failure;
      #   nothing stored, worth another try;
      # - :fetcher_down: the page fetcher cannot fetch at all (its breaker is
      #   open, it is not configured, or it refused the request); nothing
      #   stored.
      #
      # refresh: true refetches a found page whose row predates the enrichment
      # columns (a legacy row has no HTML at all) and fills them. Nothing the
      # import verified changes: a refetch that does not parse as found leaves
      # the row alone and the answer stays :found.
      #
      # The HTML is gzipped whole onto the private service (spec §6, "HTML
      # storage"): stripping it would be a parser decision of its own.
      class FetchPage
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        URL = "https://www.goodreads.com/book/show/%d"
        FETCHER_DOWN = [::PageFetcher::Exceptions::CircuitOpenError, ::PageFetcher::Exceptions::ConfigurationError,
          ::PageFetcher::Exceptions::ClientError].freeze

        def self.call(goodreads_book_id:, client: nil, refresh: false)
          new(goodreads_book_id: goodreads_book_id, client: client, refresh: refresh).call
        end

        def initialize(goodreads_book_id:, client:, refresh:)
          @goodreads_book_id = goodreads_book_id.to_i
          @client = client
          @refresh = refresh
        end

        def call
          fetched = client.fetch(format(URL, @goodreads_book_id), wait_for_selector: config.wait_for_selector,
            timeout_ms: config.fetch_timeout_ms)
          parsed = ::Books::Goodreads::BookPage.parse(html: fetched.html, status: fetched.status)
          return done(:unavailable) if parsed.outcome == :unavailable

          page = store(parsed, fetched)
          done(page.outcome.to_sym, page)
        rescue *FETCHER_DOWN => e
          Rails.logger.error("#{self.class.name}: Goodreads #{@goodreads_book_id}: #{e.class}: #{e.message}")
          done(:fetcher_down)
        rescue ::PageFetcher::Exceptions::Error => e
          Rails.logger.warn("#{self.class.name}: Goodreads #{@goodreads_book_id}: #{e.class}: #{e.message}")
          done(:unavailable)
        end

        private

        def client = (@client ||= ::PageFetcher::Client.new)

        def config = Rails.application.config.x.goodreads

        # A page another job answered first stands; a blocked or unparseable
        # one is replaced, HTML included.
        def store(parsed, fetched)
          page = ::Books::GoodreadsPage.find_or_initialize_by(goodreads_book_id: @goodreads_book_id)
          return refresh(page, parsed, fetched) if @refresh && page.persisted? && page.outcome_found?
          return page if page.persisted? && page.conclusive?

          facts = parsed.facts
          page.assign_attributes(
            source: :fetched, outcome: parsed.outcome, fetched_at: fetched.fetched_at, http_status: fetched.status,
            parser_version: ::Books::Goodreads::BookPage::VERSION,
            title: facts&.title,
            series: Array(facts&.series).map { |s| {"goodreads_series_id" => s.goodreads_series_id, "title" => s.title, "position" => s.position} },
            authors: Array(facts&.contributors).map { |c| {"name" => c.name, "role" => c.role, "primary" => c.primary} },
            original_publication_year: facts&.original_publication_year,
            isbn13: facts&.isbn13, isbn10: facts&.isbn10, asin: facts&.asin,
            **enrichment(facts)
          )
          attach_html(page, fetched)
          page.save!
          page
        end

        # Only the enrichment columns, the HTML and the parser version: the
        # verified title, authors and ISBNs stay as the import left them.
        def refresh(page, parsed, fetched)
          return page unless parsed.outcome == :found

          page.assign_attributes(parser_version: ::Books::Goodreads::BookPage::VERSION, **enrichment(parsed.facts))
          attach_html(page, fetched)
          page.save!
          page
        end

        def enrichment(facts)
          {description: facts&.description, genres: Array(facts&.genres), page_count: facts&.page_count,
           format: facts&.format, best_book_id: facts&.best_book_id}
        end

        def attach_html(page, fetched)
          page.html.attach(io: StringIO.new(Zlib.gzip(fetched.html)), filename: "goodreads-#{@goodreads_book_id}.html.gz",
            content_type: "application/gzip", identify: false, metadata: {analyzed: true})
        end

        def done(outcome, page = nil)
          Result.new(success?: true, data: {outcome: outcome, page: page}, errors: [])
        end
      end
    end
  end
end
