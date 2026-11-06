# frozen_string_literal: true

module Books
  module Goodreads
    # Reads the result rows of one Goodreads search page (enrichment spec
    # §4.2). A search with no hits answers 200 with "No results." and no rows;
    # a 200 with neither is a page whose shape changed, so :unparseable (kept,
    # with its HTML, for a parser fix).
    #
    # Two layouts, newest first:
    # - Cards (seen 2026-11-01): each result's fields carry a data-testid. The
    #   page streams in two passes and both copies stay in the HTML, so every
    #   result appears twice; the first copy of each id is kept. The series is
    #   its own line ("Name (Series #1)") and is put back on the title in the
    #   table layout's "(Name, #1)" form, which CandidateFilter strips.
    #   Large ratings counts are abbreviated ("12k ratings").
    # - Table (measured 2026-10-25, kept for stored pages): schema.org Book
    #   rows with the id in the title link, the authors, and a grey line of
    #   "N ratings — published Y — N editions".
    class SearchPage
      VERSION = 2
      NO_RESULTS_TEXT = "No results."
      # "Phantom Blood Deluxe (Series #1)"; the number can be a range or a decimal.
      CARD_SERIES = /\A(?<name>.+?)\s*\(Series\s+(?<number>#[^()]+)\)\z/
      ABBREVIATED = {"k" => 1_000, "m" => 1_000_000}.freeze

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

        rows = card_rows.presence || table_rows
        return Parsed.new(outcome: :found, rows: rows) if rows.any?
        return verdict(:no_results) if no_results?
        return verdict(:blocked) unless @status == 200 && goodreads_page?

        verdict(:unparseable)
      end

      private

      # Unparseable ends one book and leaves the gate open, so it is kept for a
      # 200 page Goodreads itself titled ("... | Goodreads", or the table
      # layout's "Search results for ..."). Anything else (a challenge, an
      # empty body, AWS WAF's 202/405) stands in for a block.
      def goodreads_page?
        title = doc.at_css("title")&.text.to_s.strip
        title.include?("Goodreads") || title.start_with?("Search results for")
      end

      def verdict(outcome) = Parsed.new(outcome: outcome, rows: [])

      def doc = (@doc ||= Nokogiri::HTML(@html))

      def no_results?
        doc.css('[data-testid="no-book-search-results"], h3.searchSubNavContainer').any? do |node|
          node.text.strip.start_with?(NO_RESULTS_TEXT)
        end
      end

      def card_rows
        doc.css('[data-testid="book-item-content"]').filter_map { |node| card_row(node) }.uniq(&:goodreads_book_id)
      end

      def card_row(node)
        link = node.at_css('[data-testid="book-item-title"] a')
        id = book_id(link)
        return nil if id.nil?

        Row.new(
          goodreads_book_id: id,
          title: card_title(link.text.squish, node.at_css('[data-testid="book-item-series"]')&.text.to_s.squish),
          author_names: names(node.css('[data-testid="book-item-contributors"] [data-testid="name"]')),
          year: node.at_css('[data-testid="book-item-publication-year"]')&.text.to_s[/(\d{1,4})/, 1]&.to_i,
          ratings_count: count(node.at_css('[data-testid="book-item-ratings-count"]')&.text.to_s, "ratings?"),
          editions_count: count(node.at_css('[data-testid="book-item-editions-count"]')&.text.to_s, "editions?")
        )
      end

      def card_title(title, series)
        match = CARD_SERIES.match(series)
        match ? "#{title} (#{match[:name]}, #{match[:number].strip})" : title
      end

      def table_rows
        doc.css('tr[itemtype="http://schema.org/Book"]').filter_map { |node| table_row(node) }
      end

      def table_row(node)
        link = node.at_css("a.bookTitle")
        id = book_id(link)
        return nil if id.nil?

        grey = node.at_css("span.greyText.smallText")&.text.to_s
        Row.new(
          goodreads_book_id: id,
          title: link.text.squish,
          author_names: names(node.css("a.authorName")),
          year: grey[/published\s+(\d{1,4})/, 1]&.to_i,
          ratings_count: count(grey, "ratings?"),
          editions_count: count(grey, "editions?")
        )
      end

      def book_id(link) = link && link["href"].to_s[%r{/book/show/(\d+)}, 1]&.to_i

      def names(nodes)
        nodes.filter_map { |a| ::Services::Text::NameNormalizer.call(a.text.to_s).presence }.uniq
      end

      # "907,547 ratings", "12k ratings", "1.2m ratings", "27 Editions"; a row
      # that omits one has none.
      def count(text, unit)
        match = text.match(/([\d,.]+)\s*([km])?\s+#{unit}\b/i)
        return 0 unless match

        number = match[1].delete(",")
        multiplier = ABBREVIATED[match[2].to_s.downcase]
        multiplier ? (number.to_f * multiplier).round : number.to_i
      end
    end
  end
end
