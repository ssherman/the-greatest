# frozen_string_literal: true

require "json"

module Books
  module Goodreads
    # Reads the identity facts from one fetched Goodreads book page (Goodreads
    # import spec §6): canonical title, series, contributors with their roles,
    # original publication year, ISBN-13/10 and ASIN. Descriptions, genres and
    # ratings are never read.
    #
    # Measured on 22 real fetches (2026-10-04):
    # - 19 of 20 book pages carry Next.js __NEXT_DATA__, whose Apollo state
    #   names the book through ROOT_QUERY's getBookByLegacyId entry. One page
    #   came without it; its markup and schema.org ld+json carry the same
    #   facts, with roles only for the contributors the markup shows.
    # - An unknown id is a 200 titled "Page not found", not a 404.
    # - Goodreads' own error page ("page unavailable") came as a 503 and was
    #   gone on retry: it says nothing about the book.
    class BookPage
      VERSION = 1
      # Roles that make a contributor a creator. Translators, illustrators,
      # editors and writers of an introduction or preface never are.
      CREATOR_ROLES = %w[Author Writer].freeze
      # A trailing "(Series, #N)", closed or not: Goodreads' own data has
      # "The Corpse in Oozak's Pond (Peter Shandy #6".
      SERIES_SUFFIX = /\s*\([^()]*#[^()]*\)?\s*\z/
      NOT_FOUND_TITLE = "Page not found"
      ERROR_HEADING = "page unavailable"

      # primary: the contributor Goodreads shows the book "by", which is what
      # an export's Author column holds, whatever the role (an anthology's
      # editor). role nil: unknown.
      Contributor = Data.define(:name, :role, :primary) do
        def creator? = CREATOR_ROLES.include?(role)
      end
      # goodreads_series_id: from the series URL (/series/130291-batman-2011),
      # Goodreads' own key for the series. position: as Goodreads writes it
      # ("6", "1-2"), nil when blank.
      Series = Data.define(:goodreads_series_id, :title, :position)
      Facts = Data.define(:goodreads_book_id, :title, :series, :contributors,
        :original_publication_year, :isbn13, :isbn10, :asin)
      # outcome: :found (facts set), :not_found, :blocked, :unparseable, or
      # :unavailable (Goodreads' error page or a 5xx: try again later).
      Parsed = Data.define(:outcome, :facts) do
        def found? = outcome == :found
      end

      def self.parse(html:, status:)
        new(html: html, status: status).parse
      end

      def initialize(html:, status:)
        @html = html.to_s
        @status = status.to_i
      end

      def parse
        return verdict(:not_found) if [404, 410].include?(@status)
        return verdict(:blocked) if [401, 403, 429].include?(@status)
        return verdict(:unavailable) if @status >= 500

        facts = usable(from_next_data) || usable(from_markup)
        return Parsed.new(outcome: :found, facts: facts) if facts
        return verdict(:not_found) if doc.at_css("title")&.text.to_s.strip == NOT_FOUND_TITLE
        return verdict(:unavailable) if doc.at_css("h1")&.text.to_s.strip == ERROR_HEADING

        verdict(:unparseable)
      end

      private

      def verdict(outcome) = Parsed.new(outcome: outcome, facts: nil)

      # Facts with no title or no contributors mean the page's shape changed
      # under the parser. Stored as found they would be a permanent mismatch
      # that parks every edition naming the id; unparseable keeps the HTML,
      # stops fetching, and gets the page fetched again after a fix.
      def usable(facts)
        facts if facts&.title.present? && facts.contributors.any?
      end

      def doc = (@doc ||= Nokogiri::HTML(@html))

      def from_next_data
        script = doc.at_css("script#__NEXT_DATA__") or return nil
        apollo = JSON.parse(script.text).dig("props", "pageProps", "apolloState")
        return nil unless apollo.is_a?(Hash) && apollo["ROOT_QUERY"].is_a?(Hash)

        root_key = apollo["ROOT_QUERY"].keys.find { |key| key.start_with?("getBookByLegacyId") }
        book = root_key && apollo[apollo["ROOT_QUERY"][root_key].to_h["__ref"]]
        return nil unless book.is_a?(Hash) && book["legacyId"]

        details = book["details"].to_h
        isbn13, isbn10 = isbns(details["isbn13"], details["isbn"])
        Facts.new(
          goodreads_book_id: book["legacyId"].to_i,
          title: clean_title(book["titleComplete"].presence || book["title"]),
          series: next_data_series(apollo, book),
          contributors: next_data_contributors(apollo, book),
          original_publication_year: year_from_ms(apollo[book.dig("work", "__ref")].to_h.dig("details", "publicationTime")),
          isbn13: isbn13,
          isbn10: isbn10,
          asin: (details["asin"].presence unless details["asin"] == isbn10)
        )
      rescue JSON::ParserError
        nil
      end

      def next_data_series(apollo, book)
        Array(book["bookSeries"]).filter_map { |entry|
          record = apollo[entry.to_h.dig("series", "__ref")]
          next unless record.is_a?(Hash) && record["title"].present?

          Series.new(goodreads_series_id: series_id(record["webUrl"]), title: record["title"].strip,
            position: entry["userPosition"].presence)
        }.uniq
      end

      def next_data_contributors(apollo, book)
        edges = [book["primaryContributorEdge"], *book["secondaryContributorEdges"]]
        edges.each_with_index.filter_map { |edge, index|
          name = normalize_name(apollo.dig(edge.to_h.dig("node", "__ref"), "name"))
          next if name.nil?

          Contributor.new(name: name, role: edge["role"].presence, primary: index.zero? && !book["primaryContributorEdge"].nil?)
        }.uniq(&:name)
      end

      def from_markup
        heading = doc.at_css('h1[data-testid="bookTitle"]') or return nil
        linked = linked_data
        isbn13, isbn10 = isbns(linked["isbn"])
        Facts.new(
          goodreads_book_id: doc.at_css('link[rel="canonical"]')&.[]("href").to_s[%r{/book/show/(\d+)}, 1]&.to_i,
          title: clean_title(heading.text),
          series: markup_series,
          contributors: markup_contributors(linked),
          original_publication_year: doc.at_css('[data-testid="publicationInfo"]')&.text.to_s[/First published.*?(\d{3,4})\s*\z/, 1]&.to_i,
          isbn13: isbn13,
          isbn10: isbn10,
          asin: nil
        )
      end

      # "Mastering the Art of French Cooking #1": the position follows the last #.
      def markup_series
        doc.css('h3 a[href*="/series/"]').filter_map { |link|
          title, position = link.text.strip.split(/\s+#(?=[^#]*\z)/, 2)
          Series.new(goodreads_series_id: series_id(link["href"]), title: title.strip, position: position.presence) if title.present?
        }.uniq
      end

      # Roles come from the contributors the markup shows (an author has no
      # role label); the rest of the ld+json author list has none (unknown).
      # The markup renders the list twice (desktop and mobile): the first is
      # read.
      def markup_contributors(linked)
        shown = Array(doc.at_css(".ContributorLinksList")&.css(".ContributorLink")).each_with_index.filter_map do |link, index|
          name = normalize_name(link.at_css('[data-testid="name"]')&.text)
          next if name.nil?

          role = link.at_css('[data-testid="role"]')&.text.to_s[/\((.+)\)/, 1]&.strip || "Author"
          Contributor.new(name: name, role: role, primary: index.zero?)
        end
        listed = Array(linked["author"]).filter_map { |person| normalize_name(person["name"]) if person.is_a?(Hash) }
        (shown + listed.map { |name| Contributor.new(name: name, role: nil, primary: false) }).uniq(&:name)
      end

      def linked_data
        doc.css('script[type="application/ld+json"]').each do |script|
          data = JSON.parse(script.text)
          return data if data.is_a?(Hash) && data["@type"] == "Book"
        rescue JSON::ParserError
          next
        end
        {}
      end

      def normalize_name(name)
        ::Services::Text::NameNormalizer.call(name.to_s).presence
      end

      def series_id(url) = url.to_s[%r{/series/(\d+)}, 1]&.to_i

      def clean_title(title) = title.to_s.sub(SERIES_SUFFIX, "").strip.presence

      def isbns(*values)
        normalized = values.filter_map { |value| ::Books::Isbn.normalize(value) }.first
        [normalized&.isbn13, normalized&.isbn10]
      end

      def year_from_ms(milliseconds)
        Time.at(milliseconds / 1000).utc.year if milliseconds.is_a?(Numeric)
      end
    end
  end
end
