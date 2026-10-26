# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module GoodreadsPages
      # Re-reads a page's stored HTML under the current BookPage::VERSION, so
      # a parser that learned new fields fills them without fetching again.
      # Like FetchPage's refresh it writes only the enrichment columns and the
      # version: what the import verified stays. A page with no HTML, one
      # already at the current version, and one whose HTML no longer parses
      # as found are returned as they are.
      class Reparse
        def self.call(page:)
          new(page: page).call
        end

        def initialize(page:)
          @page = page
        end

        def call
          return @page unless @page.html.attached?
          return @page if @page.parser_version.to_i >= ::Books::Goodreads::BookPage::VERSION

          html = Zlib.gunzip(@page.html.download).force_encoding(Encoding::UTF_8)
          parsed = ::Books::Goodreads::BookPage.parse(html: html, status: @page.http_status || 200)
          return @page unless parsed.found?

          facts = parsed.facts
          @page.update!(parser_version: ::Books::Goodreads::BookPage::VERSION, description: facts.description,
            genres: facts.genres, page_count: facts.page_count, format: facts.format, best_book_id: facts.best_book_id)
          @page
        end
      end
    end
  end
end
