# frozen_string_literal: true

module Books
  module PublisherIntake
    module Sources
      # Hachette Book Group (US). Discovery pages through the site's WordPress
      # REST API (one record per ISBN); a product page is read from its JSON-LD
      # node plus the format list and the details the page shows.
      class HachetteUs < Base
        VERSION = 2

        ENDPOINT = "https://www.hachettebookgroup.com/wp-json/wp/v2/hbg-title"
        PER_PAGE = 100
        FIELDS = "id,date,modified,link,meta"
        PAST_THE_END = "rest_post_invalid_page_number"
        FIRST_RUN_MONTHS = 14
        PUBLISHER = "Hachette Book Group"
        ISBN_AT_END = %r{/(\d{13})/?\z}

        # A format label carries a qualifier such as "(Unabridged)" or "(Special
        # Edition)". A language edition is assumed to read "(Spanish Edition)";
        # that wording has not been seen on a real page yet.
        LANGUAGES = %w[Spanish French German Italian Portuguese Dutch Chinese Japanese Korean Russian Arabic
          Hebrew Polish Swedish Norwegian Danish Finnish Greek Turkish Hindi Vietnamese Thai Czech Hungarian
          English].freeze
        LANGUAGE_EDITION = /\((\p{L}+)(?:[- ]language)? edition\)/i

        # The API's `modified_after` filter is honoured: measured 2026-11-18,
        # `per_page=1` answered X-WP-Total 7140 with `modified_after` set to a
        # week earlier and 66,990 with no filter. A run that knows when the last
        # one started asks for records modified since then; a first run has no
        # such time and asks for records added in the last FIRST_RUN_MONTHS.
        MODIFIED_FILTER = "modified_after"
        ADDED_FILTER = "after"

        # JSON-LD `bookFormat` is not read: a page for an ebook states
        # "Paperback" there. The format list's own label is the signal.
        FORMAT_WORDS = [
          [/board/i, "board_book"],
          [/\be-?book\b/i, "ebook"],
          [/audio/i, "audiobook"],
          [/mass market/i, "mass_market"],
          [/hardcover|hardback/i, "hardcover"],
          [/paperback/i, "paperback"]
        ].freeze

        CONTRIBUTOR_ROLES = [
          [/\Aillustrated/i, "illustrator"],
          [/\Atranslated/i, "translator"],
          [/\Aedited/i, "editor"],
          [/\A(read|narrated)/i, "narrator"],
          [/\A(by|written)/i, "author"]
        ].freeze

        def key = "hachette_us"

        def name = PUBLISHER

        def discovery_requests(since:)
          filter = if since
            # A day of margin: records modified while the last run was still
            # discovering, or shifted by a timezone difference, are not missed.
            # Seeing a record twice is harmless.
            "#{MODIFIED_FILTER}=#{CGI.escape((since - 1.day).utc.iso8601)}"
          else
            "#{ADDED_FILTER}=#{CGI.escape(FIRST_RUN_MONTHS.months.ago.utc.iso8601)}"
          end
          [api_request(1, filter)]
        end

        def parse_discovery(request:, response:)
          body = response.inflated.dup.force_encoding(Encoding::UTF_8)
          return discovery(:ok) if response.status == 400 && past_the_end?(body)

          outcome = status_outcome(response.status)
          return discovery(outcome) if outcome

          records = JSON.parse(body)
          return discovery(:unparseable) unless records.is_a?(Array)

          # One malformed record must not lose the rest of the page.
          listings = records.filter_map { |record| listing_from(record) if record.is_a?(Hash) && record["meta"].is_a?(Hash) }
          requests = []
          if records.size >= PER_PAGE
            requests << api_request(request.context["page"].to_i + 1, request.context["filter"])
          end
          discovery(:ok, listings, requests)
        rescue JSON::ParserError
          discovery(:unparseable)
        end

        def listing_request(listing)
          Request.page(listing.url, wait_for_selector: "h1")
        end

        def parse_listing(listing:, page:)
          outcome = status_outcome(page.status)
          return reading(outcome) if outcome
          return reading(:blocked) unless page.title.to_s.include?(PUBLISHER)

          read_product(Nokogiri::HTML(page.html))
        end

        private

        def api_request(page, filter)
          Request.file("#{ENDPOINT}?per_page=#{PER_PAGE}&page=#{page}&#{filter}&_fields=#{FIELDS}",
            context: {"page" => page, "filter" => filter})
        end

        def discovery(outcome, listings = [], requests = [])
          Discovery.new(outcome: outcome, listings: listings, requests: requests)
        end

        def reading(outcome, facts = {}, sibling_keys = [])
          Reading.new(outcome: outcome, facts: facts, sibling_keys: sibling_keys)
        end

        def past_the_end?(body)
          parsed = JSON.parse(body)
          parsed.is_a?(Hash) && parsed["code"] == PAST_THE_END
        rescue JSON::ParserError
          false
        end

        def listing_from(record)
          isbn = Isbn.normalize(record["link"].to_s[ISBN_AT_END, 1])
          release = parse_date(record.dig("meta", "release_date"))
          return unless isbn && in_window?(release)

          ListingRef.new(url: record["link"], external_key: isbn, signal: record["modified"])
        end

        def parse_date(value)
          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end

        def read_product(doc)
          node = JsonLd.nodes(doc.to_html, types: %w[Book Product]).first
          return reading(:unparseable) unless node

          details = detail_terms(doc)
          own_isbn = Isbn.normalize(node["isbn"]) || Isbn.normalize(details["ISBN-13"])
          title = clean(node["name"]).presence || doc.at_css(".product-details__title")&.text&.squish
          return reading(:unparseable) if title.blank? || own_isbn.nil?

          released = parse_date(node["datePublished"]) || parse_on_sale(details["On Sale"])
          pages = (node["numberOfPages"].presence || details["Page Count"]).to_s[/\d+/]&.to_i
          formats = formats_from(doc, own_isbn, released, pages)

          facts = {
            title: title,
            subtitle: doc.at_css(".product-details__subtitle")&.text&.squish.presence,
            contributors: contributors_from(doc, node),
            formats: formats,
            imprint_name: clean(node.dig("brand", "name")).presence,
            publisher_name: PUBLISHER,
            language: language_from(formats, own_isbn),
            genres: Array.wrap(node["genre"]).map { |genre| clean(genre) }.reject { |genre| genre.blank? || genre == "Genres" },
            series_name: series_name(doc),
            series_position: nil,
            age_range: nil,
            description: clean(node["description"]).presence,
            cover_url: cover_from(node),
            on_sale_on: released
          }
          reading(:found, facts, formats.map { |format| format[:isbn13] } - [own_isbn])
        end

        def language_from(formats, own_isbn)
          label = formats.find { |format| format[:isbn13] == own_isbn }&.dig(:format_label)
          word = label.to_s[LANGUAGE_EDITION, 1]
          LANGUAGES.find { |language| language.casecmp?(word) } && word
        end

        # The site's stand-in image is not a cover.
        def cover_from(node)
          url = Array.wrap(node["image"]).first.to_s.sub(/\?.*\z/, "")
          url.presence unless url.include?("missingbook")
        end

        def clean(value) = CGI.unescapeHTML(value.to_s).squish

        # "On Sale", "Page Count", "ISBN-13"... as the page lists them.
        def detail_terms(doc)
          doc.css(".product-supplemental__details__group").to_h do |group|
            [group.at_css("dt")&.text.to_s.squish, group.at_css("dd")&.text.to_s.squish]
          end
        end

        def parse_on_sale(text)
          Date.strptime(text.to_s, "%b %d, %Y")
        rescue Date::Error
          nil
        end

        def contributors_from(doc, node)
          from_page = doc.css(".product-details__contributors p").flat_map do |line|
            prefix = line.children.take_while { |child| child.name != "a" }.map(&:text).join.squish
            role = CONTRIBUTOR_ROLES.find { |pattern, _| prefix.match?(pattern) }&.last || "other"
            line.css("a").map { |link| {name: link.text.squish, role: role} }
          end
          return from_page if from_page.any?

          Array.wrap(node["author"]).filter_map do |person|
            name = clean(person.is_a?(Hash) ? person["name"] : person)
            {name: name, role: "author"} if name.present?
          end
        end

        def series_name(doc)
          group = doc.css(".product-supplemental__taxonomies-genre").find do |node|
            node.at_css("h3")&.text.to_s.squish.match?(/\ASeries:?\z/)
          end
          group&.at_css("li a")&.text&.squish.presence
        end

        # The page's own format is a span; the others are links to their pages.
        def formats_from(doc, own_isbn, released, pages)
          items = doc.css(".title-formats-prices .title-formats-prices__item")
          entries = items.map do |item|
            isbn = item["href"] ? Isbn.normalize(item["href"][ISBN_AT_END, 1]) : own_isbn
            format_entry(item, isbn, own: isbn == own_isbn, released: released, pages: pages) if isbn
          end.compact
          return entries if entries.any? { |entry| entry[:isbn13] == own_isbn }

          label = doc.at_css(".title-formats__button .title-format-item")
          [format_entry(label, own_isbn, own: true, released: released, pages: pages)] + entries
        end

        def format_entry(node, isbn, own:, released:, pages:)
          label = format_label(node)
          price = node&.at_css('.title-format-item__price[data-price-currency="USD"]')&.text.to_s[/\d[\d,]*(\.\d+)?/]
          {
            isbn13: isbn,
            format: format_code(label),
            format_label: label,
            on_sale_on: own ? released : nil,
            pages: own ? pages : nil,
            price_cents: price && (BigDecimal(price.delete(",")) * 100).round.to_i,
            currency: price && "USD"
          }
        end

        def format_label(node)
          return nil unless node

          copy = node.dup
          copy.css(".title-format-item__price").each(&:remove)
          copy.text.squish.presence
        end

        def format_code(label)
          FORMAT_WORDS.find { |pattern, _| label.to_s.match?(pattern) }&.last || "other"
        end
      end
    end
  end
end
