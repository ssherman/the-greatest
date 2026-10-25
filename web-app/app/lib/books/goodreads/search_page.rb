# frozen_string_literal: true

module Books
  module Goodreads
    # Reads the result rows of one Goodreads search page (enrichment spec
    # §4.2, measured 2026-10-25): each result is a schema.org Book table row
    # carrying the book id in its title link, the authors, and a grey line of
    # "N ratings — published Y — N editions". A search with no hits answers
    # 200 with "No results." and no rows; a 200 with neither is a page whose
    # shape changed, so :unparseable (kept, with its HTML, for a parser fix).
    class SearchPage
      VERSION = 1
      NO_RESULTS_TEXT = "No results."

      Row = Data.define(:goodreads_book_id, :title, :author_names, :year, :ratings_count, :editions_count)
      # outcome: :found, :no_results, :blocked, :unavailable or :unparseable.
      Parsed = Data.define(:outcome, :rows)

      def self.parse(html:, status:)
        new(html: html, status: status).parse
      end

      def initialize(html:, status:)
        @html = html.to_s
        @status = status.to_i
      end

      def parse
        return verdict(:blocked) if [401, 403, 429].include?(@status)
        return verdict(:unavailable) if @status >= 500

        rows = doc.css('tr[itemtype="http://schema.org/Book"]').filter_map { |node| row(node) }
        return Parsed.new(outcome: :found, rows: rows) if rows.any?
        return verdict(:no_results) if doc.css("h3.searchSubNavContainer").any? { |node| node.text.strip == NO_RESULTS_TEXT }

        verdict(:unparseable)
      end

      private

      def verdict(outcome) = Parsed.new(outcome: outcome, rows: [])

      def doc = (@doc ||= Nokogiri::HTML(@html))

      def row(node)
        link = node.at_css("a.bookTitle")
        id = link && link["href"].to_s[%r{/book/show/(\d+)}, 1]
        return nil if id.nil?

        grey = node.at_css("span.greyText.smallText")&.text.to_s
        Row.new(
          goodreads_book_id: id.to_i,
          title: link.text.squish,
          author_names: node.css("a.authorName").filter_map { |a| ::Services::Text::NameNormalizer.call(a.text.to_s).presence }.uniq,
          year: grey[/published\s+(\d{1,4})/, 1]&.to_i,
          ratings_count: count(grey, "ratings?"),
          editions_count: count(grey, "editions?")
        )
      end

      # "907,547 ratings", "1 edition"; a row that omits one has none.
      def count(text, unit) = text[/([\d,]+)\s+#{unit}\b/, 1].to_s.delete(",").to_i
    end
  end
end
