# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module GoodreadsPages
      # Re-reads an unparseable search's stored HTML under the current
      # SearchPage::VERSION, so a parser fix recovers searches already fetched
      # instead of fetching them again. Only unparseable rows: a found or
      # no-results search is already the answer. fetched_at is kept, so the
      # search ages out of GoodreadsSearch.fresh on its original schedule.
      #
      # HTML that still does not read is stamped with the current version, so
      # it is not re-read on every look until the parser changes again.
      class ReparseSearch
        def self.call(search:)
          new(search: search).call
        end

        def initialize(search:)
          @search = search
        end

        def call
          return @search unless @search.outcome_unparseable? && @search.html.attached?
          return @search if @search.parser_version.to_i >= ::Books::Goodreads::SearchPage::VERSION

          html = Zlib.gunzip(@search.html.download).force_encoding(Encoding::UTF_8)
          parsed = ::Books::Goodreads::SearchPage.parse(html: html, status: @search.http_status || 200)
          attributes = {parser_version: ::Books::Goodreads::SearchPage::VERSION}
          attributes.update(outcome: parsed.outcome, rows: parsed.rows.map(&:to_h)) if %i[found no_results].include?(parsed.outcome)
          @search.update!(attributes)
          @search
        end
      end
    end
  end
end
