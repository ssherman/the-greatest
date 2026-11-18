# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module PublisherIntake
      # Re-reads a listing's stored page with the current parser (publisher
      # intake design §4, "promote"). Nothing is fetched. A listing is left
      # alone when it has no stored page or was parsed by the strategy's
      # current version already.
      #
      # A found reading is stored by StoreReading in reparse mode, so the stored
      # page, last_attempt_* and an already-read listing's read_at stay as they
      # were, and an unparseable listing that now parses becomes read. Any other
      # result only stamps parser_version, so the page is not re-read until the
      # parser changes again.
      #
      # data: {changed: true | false}
      class Reparse
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(listing:)
          new(listing: listing).call
        end

        def initialize(listing:)
          @listing = listing
        end

        def call
          strategy = ::Books::PublisherIntake::Sources.fetch(@listing.source)
          return unchanged if strategy.nil? || !@listing.html.attached?
          return unchanged unless @listing.parser_version.nil? || @listing.parser_version < strategy.parser_version

          page = stored_page
          reading = parse(strategy, page)
          stored = StoreReading.call(listing: @listing, reading: reading, page: page, parser_version: strategy.parser_version,
            reparse: true)
          Result.new(success?: true, data: {changed: stored.data[:outcome] == :found}, errors: [])
        end

        private

        def stored_page
          html = Zlib.gunzip(@listing.html.download).force_encoding(Encoding::UTF_8)
          status = @listing.http_status || 200
          PageFetcher::Page.new(url: @listing.url, final_url: @listing.url, status: status, title: nil, html: html,
            selector_found: true, elapsed_ms: 0, fetched_at: @listing.last_attempt_at || @listing.read_at || Time.current)
        end

        # Only the class name is logged: the message can carry page text.
        def parse(strategy, page)
          strategy.parse_listing(listing: @listing, page: page)
        rescue => e
          Rails.logger.warn("PublisherIntake: #{@listing.source} listing #{@listing.id} parser raised #{e.class.name}")
          ::Books::PublisherIntake::Reading.new(outcome: :unparseable, facts: nil, sibling_keys: [])
        end

        def unchanged = Result.new(success?: true, data: {changed: false}, errors: [])
      end
    end
  end
end
