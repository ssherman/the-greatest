# frozen_string_literal: true

module Books
  module PublisherIntake
    module Sources
      # Macmillan (US). The product sitemap files carry no dates, so discovery
      # is by list comparison: the framework stores every URL of the first run
      # without reading it (`baseline_on_first_run?`) and reads only URLs that
      # appear later. A one-time seed from the site's own collections covers the
      # titles announced before that first run.
      #
      # A book page is read from what it shows: the heading, the creator line,
      # the format dropdown, the "About This Book" facts (page count, genre, on
      # sale, age range) and the details list (imprint, ISBN). Checked against
      # the visible page on real captures (2026-11-18); these are NOT trusted:
      # - The JSON-LD `Book` node's `author` is the creator line verbatim, so a
      #   translator or illustrator is folded into the author's name
      #   ("Bill Martin Jr.; illustrated by Eric Carle"). Contributors are
      #   split from the page's creator line instead. The node's `name`, `isbn`
      #   and `image` do match the page and are fallbacks for the heading, the
      #   details list and og:image.
      # - The `book-form__book--hardcover` class on the cover is there on
      #   paperback pages too; a format comes from the dropdown's own label.
      # - Page count, on-sale date and price are shown for the page's own
      #   ISBN only, so only that format carries them.
      # - `:language` is always nil: no element of these pages states the
      #   edition's language (a translated novel says what it was translated
      #   from, which is not the edition's language).
      # - The series is read from the heading's own series link ("Orphan X
      #   (Volume 12)"), never from the title. `:subtitle` is nil: the line the
      #   page shows under the title on a series book ("An Orphan X Novel") is
      #   a series tagline, and no other page shows a subtitle apart from the
      #   title itself.
      # - A page is read only when it shows its own markup (the creator line
      #   and a format control); a page that keeps only the JSON-LD and the
      #   site's meta tags is unparseable, not a title with empty facts.
      class MacmillanUs < Base
        VERSION = 1

        SITE = "https://us.macmillan.com"
        PUBLISHER = "Macmillan"
        PRODUCT_FILE = %r{sitemaps/sitemap-products\.\d+\.xml\.gz\z}
        PRODUCT_URL = %r{\Ahttps://us\.macmillan\.com/books/(97[89]\d{10})/}
        NAME_SUFFIX = /\A(?:jr\.?|sr\.?|ph\.?d\.?|m\.?d\.?|esq\.?|ii|iii|iv|dds|mba)\z/i
        BOOK_PATH = %r{\A(?:https://us\.macmillan\.com)?/books/(97[89]\d{10})(?:/([^/?#]+))?}
        SITE_NAME = /Macmillan/i
        SITE_URL = %r{\Ahttps://us\.macmillan\.com/}
        NOT_FOUND_TITLE = /\APage not found/i
        PLACEHOLDER_COVER = /lazyload|placeholder|no-?cover/i
        COLLECTIONS = %w[Coming%20Soon New%20Releases].freeze

        FORMAT_WORDS = [
          [/board/i, "board_book"],
          [/\be-?book\b/i, "ebook"],
          [/audio/i, "audiobook"],
          [/mass market/i, "mass_market"],
          [/hardcover|hardback/i, "hardcover"],
          [/paperback/i, "paperback"]
        ].freeze

        # A creator line is "Author; illustrated by X; Translated from the French by Y".
        CONTRIBUTOR_ROLES = [
          [/\A(?:with )?illustrat(?:ed|ions?) by\s+/i, "illustrator"],
          [/\Atranslated(?: from [^;]*?)? by\s+/i, "translator"],
          [/\Aedited by\s+/i, "editor"],
          [/\A(?:read|narrated) by\s+/i, "narrator"],
          [/\A(?:foreword|introduction|afterword|with)\b[^;]*?\bby\s+/i, "other"],
          [/\Aby\s+/i, "author"]
        ].freeze

        def key = "macmillan_us"

        def name = PUBLISHER

        def baseline_on_first_run? = true

        def discovery_requests(since:)
          [Request.file("#{SITE}/sitemap_index.xml", context: {"step" => "index"})]
        end

        # Step 1 (2026-11-18) established that a collection cannot be paged by
        # URL. The "Coming Soon" collection's first page has 22 distinct book
        # links: 20 results in its grid (each linked twice) and 2 featured books
        # in the site's menu, which are not results. Its pager has 7 numbered
        # links. Its links to page 2 (`search?p=1&...`) and the same URL with
        # `&page=2` both answer "Page not found": the next page is loaded by the
        # page's own script. So the seed is the first page of each collection,
        # and a collection page yields no follow-up request.
        def seed_requests
          COLLECTIONS.map do |name|
            Request.page("#{SITE}/search?dFR[collections.list.name][0]=#{name}&searchType=products",
              wait_for_selector: ".book-grid__grid a[href*='/books/97']", context: {"step" => "collection", "page" => 1})
          end
        end

        def parse_discovery(request:, response:)
          outcome = status_outcome(response.status)
          return discovery(outcome) if outcome

          step = request.context["step"]
          return collection_discovery(response) if step == "collection"

          sitemap = SitemapReader.call(response.body)
          case step
          when "index" then (sitemap.kind == :index) ? index_discovery(sitemap) : discovery(:unparseable)
          when "products" then (sitemap.kind == :urlset) ? products_discovery(sitemap) : discovery(:unparseable)
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

          doc = Nokogiri::HTML(page.html)
          return reading(:blocked) unless site_page?(page.title, doc)
          return reading(:not_found) if page.title.to_s.match?(NOT_FOUND_TITLE)

          read_book(doc, listing)
        end

        private

        def discovery(outcome, listings = [], requests = [])
          Discovery.new(outcome: outcome, listings: listings, requests: requests)
        end

        def reading(outcome, facts = {}, sibling_keys = [])
          Reading.new(outcome: outcome, facts: facts, sibling_keys: sibling_keys)
        end

        # A real book page's <title> is the book's title alone; the site's name
        # is in og:site_name there, and in the <title> of its other pages. Two
        # more markers keep a page that loses the meta tag from reading as a
        # block: the book heading block, and a JSON-LD Book url on the site.
        def site_page?(title, doc)
          title.to_s.match?(SITE_NAME) ||
            doc.at_css('meta[property="og:site_name"]')&.[]("content").to_s.match?(SITE_NAME) ||
            doc.at_css(".section-title--book-main").present? ||
            JsonLd.nodes(doc.to_html, types: "Book").any? { |node| node["url"].to_s.match?(SITE_URL) }
        end

        def index_discovery(sitemap)
          requests = sitemap.entries.filter_map do |entry|
            Request.file(entry.loc, context: {"step" => "products"}) if entry.loc.match?(PRODUCT_FILE)
          end
          discovery(:ok, [], requests)
        end

        def products_discovery(sitemap)
          listings = sitemap.entries.filter_map do |entry|
            isbn = entry.loc[PRODUCT_URL, 1]
            ListingRef.new(url: entry.loc, external_key: isbn, signal: nil) if isbn
          end
          discovery(:ok, listings)
        end

        # The results grid only: the site's menu also links two featured books.
        def collection_discovery(page)
          doc = Nokogiri::HTML(page.html)
          return discovery(:blocked) unless site_page?(page.title, doc)

          seen = {}
          doc.css(".book-grid__grid a[href]").each do |link|
            match = link["href"].to_s.match(BOOK_PATH)
            next unless match

            seen[match[1]] ||= "#{SITE}/books/#{match[1]}/#{"#{match[2]}/" if match[2]}"
          end
          # An empty grid is a renamed grid or a page filled by script too late,
          # not an empty collection: it must not read as "nothing new".
          return discovery(:unparseable) if seen.empty?

          discovery(:ok, seen.map { |isbn, url| ListingRef.new(url: url, external_key: isbn, signal: nil) })
        end

        def read_book(doc, listing)
          book = JsonLd.nodes(doc.to_html, types: "Book").find { |node| node["name"].is_a?(String) }
          info = labelled(doc, ".book-about__info-item", ".book-about__info-item-label", ".book-about__info-item-text")
          details = labelled(doc, ".book-details__item", ".book-details__item-title", ".book-details__item-text")
          own_isbn = Isbn.normalize(book&.dig("isbn").to_s) || Isbn.normalize(details["ISBN"]&.text.to_s) ||
            Isbn.normalize(listing.external_key.to_s)
          title = doc.at_css(".section-title--book-main h1")&.text&.squish.presence || book&.dig("name").to_s.squish.presence
          return reading(:unparseable) if title.blank? || own_isbn.nil? || !book_markup?(doc)

          on_sale = parse_date(info["On Sale"]&.text)
          series = series_from(doc)
          formats = formats_from(doc, own_isbn, info, on_sale)
          facts = {
            title: title,
            subtitle: nil,
            contributors: contributors_from(doc),
            formats: formats,
            imprint_name: details["Imprint Publisher"]&.text&.squish.presence,
            publisher_name: PUBLISHER,
            language: nil,
            genres: genres_from(info["Genre"]),
            series_name: series[:name],
            series_position: series[:position],
            age_range: info["Age Range"]&.text&.squish.presence,
            description: paragraphs(doc.at_css(".book-details__description")),
            cover_url: cover_from(book, doc),
            on_sale_on: on_sale,
            source_key: own_isbn
          }
          reading(:found, facts, formats.map { |format| format[:isbn13] } - [own_isbn])
        end

        # The page's own markup: the creator line and a format control.
        def book_markup?(doc)
          doc.at_css(".section-title--book-main .section-title__creator").present? &&
            (doc.at_css("select.book-formats-dropdown option[data-format-isbn]") || doc.at_css("div.select-input__el")).present?
        end

        # "Orphan X (Volume 12)" -> name "Orphan X", position "12" (a plain number only).
        def series_from(doc)
          text = doc.at_css(".section-title--book-main a[href^='/series/']")&.text.to_s.squish
          return {} if text.blank?

          name = text.sub(/\s*\(Volume[^)]*\)\z/i, "").squish
          {name: name.presence, position: text[/\(Volume\s+(\d+)\)\z/i, 1]}
        end

        # label => the element holding its text, for the first row of each label.
        def labelled(doc, row, label, text)
          doc.css(row).each_with_object({}) do |node, found|
            name = node.at_css(label)&.text&.squish
            value = node.at_css(text)
            found[name] ||= value if name.present? && value
          end
        end

        def genres_from(node)
          return [] unless node

          names = node.css("a").map { |link| link.text.squish }
          (names.presence || [node.text.squish]).reject(&:blank?)
        end

        # The format dropdown lists every format with its ISBN (the page has
        # two, mobile and desktop). A page with one format shows its label as
        # plain text instead, so the page's own ISBN is added when the
        # dropdown lacks it.
        def formats_from(doc, own_isbn, info, on_sale)
          labels = {}
          doc.css("select.book-formats-dropdown option[data-format-isbn]").each do |option|
            isbn = Isbn.normalize(option["data-format-isbn"])
            labels[isbn] ||= option.text.squish.presence if isbn
          end
          labels = {own_isbn => doc.at_css("div.select-input__el")&.text&.squish.presence}.merge(labels) unless labels.key?(own_isbn)

          labels.map do |isbn, label|
            own = isbn == own_isbn
            {
              isbn13: isbn,
              format: format_code(label) || "other",
              format_label: label,
              on_sale_on: own ? on_sale : nil,
              pages: own ? info["Page Count"]&.text.to_s[/\d[\d,]*/]&.delete(",")&.to_i : nil,
              price_cents: own ? price_cents(doc) : nil,
              currency: (own && price_cents(doc)) ? "USD" : nil
            }
          end
        end

        def format_code(label)
          FORMAT_WORDS.find { |pattern, _| label.to_s.match?(pattern) }&.last
        end

        def price_cents(doc)
          amount = doc.at_css(".book-form__price")&.text.to_s[/\$\s*(\d[\d,]*(?:\.\d+)?)/, 1]
          amount && (BigDecimal(amount.delete(",")) * 100).round.to_i
        end

        def parse_date(text)
          Date.strptime(text.to_s.strip, "%m/%d/%Y")
        rescue Date::Error
          nil
        end

        def contributors_from(doc)
          doc.css(".section-title--book-main .section-title__creator").flat_map do |line|
            copy = line.dup
            copy.css(".section-title__label").each(&:remove)
            copy.text.split(";").map(&:squish).reject(&:blank?).flat_map { |segment| contributor(segment) }
          end.uniq
        end

        # Every name in a segment gets the segment's role. Co-authors are joined
        # with " and " or ", "; a name suffix after a comma ("King, Jr.",
        # "Rader, PhD") stays with its name.
        def contributor(segment)
          pattern, role = CONTRIBUTOR_ROLES.find { |regexp, _| segment.match?(regexp) }
          names = (pattern ? segment.sub(pattern, "") : segment).squish.split(/\s+and\s+|,\s+/).map(&:squish)
          names = names.each_with_object([]) do |part, joined|
            (part.match?(NAME_SUFFIX) && joined.any?) ? joined[-1] = "#{joined.last}, #{part}" : joined << part
          end
          names.reject(&:blank?).map { |name| {name: name, role: role || "author"} }
        end

        # Paragraphs are separated by <br>, which has no text of its own.
        def paragraphs(node)
          return nil unless node

          copy = node.dup
          copy.css("br").each { |br| br.replace("\n") }
          copy.text.split("\n").map(&:squish).reject(&:blank?).join("\n").presence
        end

        # A missing or placeholder image is nil; a query string is dropped.
        def cover_from(book, doc)
          url = [book&.dig("image"), doc.at_css('meta[property="og:image"]')&.[]("content")]
            .find { |value| value.is_a?(String) && value.present? }.to_s.sub(/\?.*\z/, "").strip
          (url.blank? || url.match?(PLACEHOLDER_COVER)) ? nil : url
        end
      end
    end
  end
end
