# frozen_string_literal: true

module Books
  module PublisherIntake
    module Sources
      # Penguin Random House (US). Discovery follows the sitemap index to the
      # yearly "works" files, whose `lastmod` is a work's on-sale date; a work
      # page is read from its JSON-LD (one `Book` node whose `workExample`
      # lists every format) and from the format rows and headings the page shows.
      #
      # Checked against the visible page on real captures (2026-11-18): the
      # JSON-LD `workExample` ISBNs and `datePublished` values match the page's
      # format rows exactly, so formats are listed from it. Three JSON-LD facts
      # are NOT trusted:
      # - `inLanguage` reads "English" on a Spanish-language edition; the page's
      #   Spanish genre ("Spanish Language Fiction") is the signal for Spanish.
      # - `bookFormat` is coarser than the page ("Large Print" is a Paperback;
      #   a board book is "https://schema.org/Board Book"), so the page's own
      #   format name is read first and `bookFormat` is the fallback.
      # - `numberOfPages` is one figure for the work; each format row carries
      #   its own page count.
      class PenguinRandomHouseUs < Base
        VERSION = 1

        SITE = "https://www.penguinrandomhouse.com"
        PUBLISHER = "Penguin Random House"
        WORKS_FILE = %r{/sitemap-works-(\d{4})\.xml\z}
        WORK_ID = %r{\Ahttps?://[^/]+/books/(\d+)/}
        SITE_TITLE = /PenguinRandomhouse\.com|Penguin Random House/i
        NOT_FOUND_TITLE = /\APage Not Found/i
        SPANISH_GENRE = %r{\A/books/spanish-language}
        JSON_LD_PREFIX = %r{\Ahttps?://schema\.org/}

        FORMAT_WORDS = [
          [/board/i, "board_book"],
          [/\be-?book\b/i, "ebook"],
          [/audio/i, "audiobook"],
          [/mass market/i, "mass_market"],
          [/hardcover|hardback/i, "hardcover"],
          [/paperback/i, "paperback"]
        ].freeze

        # The prefix of a contributor line on the page ("By", "Read by", ...).
        CONTRIBUTOR_ROLES = [
          [/\Aread/i, "narrator"],
          [/\Atranslated/i, "translator"],
          [/\Aedited/i, "editor"],
          [/\A(written|by)/i, "author"],
          [/\Aillustrated/i, "illustrator"]
        ].freeze

        def key = "penguin_random_house_us"

        def name = PUBLISHER

        def discovery_requests(since:)
          [Request.file("#{SITE}/sitemap.xml", context: {"step" => "index"})]
        end

        def parse_discovery(request:, response:)
          outcome = status_outcome(response.status)
          return discovery(outcome) if outcome

          sitemap = SitemapReader.call(response.body)
          case request.context["step"]
          when "index" then (sitemap.kind == :index) ? index_discovery(sitemap) : discovery(:unparseable)
          when "works" then (sitemap.kind == :urlset) ? works_discovery(sitemap) : discovery(:unparseable)
          else discovery(:unparseable)
          end
        rescue SitemapReader::Unreadable
          discovery(:unparseable)
        end

        def listing_request(listing)
          Request.page(listing.url, wait_for_selector: "h1")
        end

        def parse_listing(listing:, page:)
          outcome = status_outcome(page.status)
          return reading(outcome) if outcome
          return reading(:not_found) if page.title.to_s.match?(NOT_FOUND_TITLE)
          return reading(:blocked) unless page.title.to_s.match?(SITE_TITLE)

          read_work(Nokogiri::HTML(page.html), listing)
        end

        private

        def discovery(outcome, listings = [], requests = [])
          Discovery.new(outcome: outcome, listings: listings, requests: requests)
        end

        def reading(outcome, facts = {}, sibling_keys = [])
          Reading.new(outcome: outcome, facts: facts, sibling_keys: sibling_keys)
        end

        # The current year's file and each later year up to the horizon's. A
        # file for an earlier year holds only back-catalog, which the lookback
        # window excludes anyway.
        def index_discovery(sitemap)
          last_year = (Date.current + ::Books::PublisherIntake.settings.horizon_days).year
          requests = sitemap.entries.filter_map do |entry|
            year = entry.loc[WORKS_FILE, 1]&.to_i
            next unless year&.between?(Date.current.year, last_year)

            Request.file(entry.loc, context: {"step" => "works"})
          end
          discovery(:ok, [], requests)
        end

        def works_discovery(sitemap)
          listings = sitemap.entries.filter_map do |entry|
            work_id = entry.loc[WORK_ID, 1]
            next unless work_id && in_window?(entry.lastmod)

            ListingRef.new(url: entry.loc, external_key: work_id, signal: entry.lastmod.iso8601)
          end
          discovery(:ok, listings)
        end

        def read_work(doc, listing)
          book = JsonLd.nodes(doc.to_html, types: "Book").find { |node| node["name"].is_a?(String) && node["name"].present? }
          return reading(:unparseable) unless book

          title = clean(book["name"])
          rows = format_rows(doc)
          formats = formats_from(book, rows)
          return reading(:unparseable) if title.blank? || formats.empty?

          genres = doc.css(".book-description-genres a.drawer-link")
          facts = {
            title: title,
            subtitle: clean(book["alternativeHeadline"]).presence || doc.at_css("p.subtitle.show")&.text&.squish.presence,
            contributors: contributors_from(doc, book),
            formats: formats,
            imprint_name: clean(book["publisherImprint"]).presence || rows.values.filter_map { |row| row[:imprint] }.first,
            publisher_name: PUBLISHER,
            language: language_from(book, genres),
            genres: genres.map { |link| link.text.squish }.reject(&:blank?),
            series_name: clean(book.dig("isPartOf", "name")).presence,
            series_position: doc.at_css("h3.series.show")&.text.to_s[/\ABook (\d+) of/i, 1],
            age_range: doc.at_css("h3.age-range.show")&.text.to_s[/Age Range:\s*(.+)/i, 1]&.squish.presence ||
              clean(book["typicalAgeRange"]).presence,
            description: description_from(doc),
            cover_url: cover_from(book),
            on_sale_on: formats.filter_map { |format| format[:on_sale_on] }.min,
            source_key: doc.at_css("#tmpl-indc")&.[]("data-workid").to_s[/\A\d+\z/] || listing.external_key.to_s
          }
          reading(:found, facts)
        end

        def clean(value) = CGI.unescapeHTML(value.is_a?(String) ? value : "").squish

        # What the page shows for each ISBN: the mobile rows (`.bookRow`, all
        # formats) and the desktop list (`li[data-isbn]`). Either may hold
        # formats the other lacks.
        def format_rows(doc)
          rows = {}
          doc.css(".bookRow[isbn]").each do |node|
            isbn = Isbn.normalize(node["isbn"])
            next if isbn.nil? || rows.key?(isbn)

            rows[isbn] = {label: node["format-name"].to_s.squish.presence, imprint: node["imprint"].to_s.squish.presence,
                          price: node["price"], info: node.at_css(".frmtInfo")&.text.to_s}
          end
          doc.css("li[data-isbn]").each do |node|
            isbn = Isbn.normalize(node["data-isbn"])
            next if isbn.nil? || rows.key?(isbn)

            container = node.at_css(".title-price-container")&.dup
            container&.css(".price")&.each(&:remove)
            rows[isbn] = {label: container&.text&.squish.presence, imprint: nil,
                          price: node.at_css(".price")&.text.to_s[/\d[\d,]*(\.\d+)?/]&.delete(","),
                          info: node.at_css(".title-details")&.text.to_s}
          end
          rows
        end

        def formats_from(book, rows)
          own_isbn = Isbn.normalize(book["isbn"].to_s)
          examples = Array(book["workExample"]).select { |example| example.is_a?(Hash) }.to_h do |example|
            [Isbn.normalize(example["isbn"].to_s), example]
          end
          examples[own_isbn] ||= {} if own_isbn
          rows.each_key { |isbn| examples[isbn] ||= {} }
          examples.delete(nil)

          examples.map do |isbn, example|
            format_entry(isbn, example, rows[isbn], book, own: isbn == own_isbn)
          end
        end

        def format_entry(isbn, example, row, book, own:)
          json_format = example["bookFormat"].is_a?(String) ? example["bookFormat"].sub(JSON_LD_PREFIX, "").squish : nil
          json_format ||= book["bookFormat"].to_s.sub(JSON_LD_PREFIX, "").squish.presence if own
          label = row&.dig(:label) || json_format
          offer = example.dig("potentialAction", "expectsAcceptanceOf")
          price = [offer.is_a?(Hash) ? offer["Price"] : nil, row&.dig(:price)].map(&:to_s).find { |value| value.match?(/\A\d+(\.\d+)?\z/) }
          info = row&.dig(:info).to_s
          {
            isbn13: isbn,
            format: format_code(row&.dig(:label)) || format_code(json_format) || "other",
            format_label: label,
            on_sale_on: parse_iso(example["datePublished"]) || parse_page_date(info),
            pages: info[/(\d[\d,]*)\s+Pages/i, 1]&.delete(",")&.to_i || (own ? book["numberOfPages"].to_s[/\A\d+\z/]&.to_i : nil),
            price_cents: price && (BigDecimal(price) * 100).round.to_i,
            currency: price && "USD"
          }
        end

        def format_code(label)
          FORMAT_WORDS.find { |pattern, _| label.to_s.match?(pattern) }&.last
        end

        def parse_iso(value)
          Date.iso8601(value) if value.is_a?(String)
        rescue Date::Error
          nil
        end

        def parse_page_date(text)
          Date.strptime(text[/(?:Published|Available) on (\w{3} \d{1,2}, \d{4})/, 1].to_s, "%b %d, %Y")
        rescue Date::Error
          nil
        end

        # The heading for the page's own format. The JSON-LD author is the
        # fallback, and may be a string, an object or an array of either.
        def contributors_from(doc, book)
          from_page = doc.css("h2.contributors.show .contributor").flat_map do |line|
            prefix = line.children.find(&:text?)&.text.to_s.squish
            role = CONTRIBUTOR_ROLES.find { |pattern, _| prefix.match?(pattern) }&.last || "other"
            line.css("a").reject { |link| link["class"].to_s.include?("on-tour-chip") }
              .filter_map { |link| {name: link.text.squish, role: role} if link.text.squish.present? }
          end
          return from_page if from_page.any?

          Array(book["author"]).filter_map do |person|
            name = clean(person.is_a?(Hash) ? person["name"] : person)
            {name: name, role: "author"} if name.present?
          end
        end

        # The Spanish genre is the only language signal the page gives; see the
        # class comment on `inLanguage`.
        def language_from(book, genres)
          return "Spanish" if genres.any? { |link| link["href"].to_s.match?(SPANISH_GENRE) }

          clean(book["inLanguage"]).presence
        end

        # The full copy the page shows; og:description is a cut-off of it.
        def description_from(doc)
          doc.at_css("#book-description-copy")&.text&.squish.presence ||
            doc.at_css('meta[property="og:description"]')&.[]("content").to_s.squish.presence
        end

        # A missing image is nil; a query string is dropped.
        def cover_from(book)
          url = Array(book["image"]).first
          url = url.is_a?(String) ? url.sub(/\?.*\z/, "").strip : ""
          url.presence
        end
      end
    end
  end
end
