# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    module Sources
      # Real pages, cut by hand to what the parser reads (navigation, forms,
      # reviews, excerpts, author biographies and long copy removed, description
      # paragraphs cut to a sentence): novel_three_formats, translated_novel,
      # picture_book_illustrator, boxed_set_no_pages, graphic_boxed_set,
      # classic_two_formats and collection_coming_soon (the first five results
      # of the "Coming Soon" collection, plus the two featured books the site's
      # menu carries). sitemap_index.xml and sitemap_products_urlset.xml.gz are
      # HAND-BUILT from the recorded shape of the real files (real URL layout,
      # a few children and six entries). synthetic_* pages are made up and say
      # why in a comment; every other test body builds its markup inline from
      # structure seen on the real pages.
      class MacmillanUsTest < ActiveSupport::TestCase
        DIR = "publisher_intake/macmillan_us"
        SITE = "https://us.macmillan.com"
        COMING_SOON = "#{SITE}/search?dFR[collections.list.name][0]=Coming%20Soon&searchType=products"
        NEW_RELEASES = "#{SITE}/search?dFR[collections.list.name][0]=New%20Releases&searchType=products"

        setup do
          travel_to Time.utc(2026, 11, 17, 12)
          @source = MacmillanUs.new
        end

        def fixture_bytes(name)
          path = file_fixture("#{DIR}/#{name}")
          (name.end_with?(".html.gz") ? Zlib.gunzip(path.binread) : path.binread)
        end

        def fixture_text(name) = fixture_bytes(name).force_encoding(Encoding::UTF_8)

        def file_response(body, status: 200)
          PageFetcher::FileResponse.new(url: "u", final_url: "u", status: status, content_type: "application/xml",
            body: body.b, elapsed_ms: 1, fetched_at: Time.current)
        end

        def page(html, status: 200, title: nil)
          title ||= html[%r{<title>(.*?)</title>}m, 1]
          PageFetcher::Page.new(url: "u", final_url: "u", status: status, title: title, html: html,
            selector_found: true, elapsed_ms: 1, fetched_at: Time.current)
        end

        def request(step, **context) = Request.file("#{SITE}/x.xml", context: {"step" => step}.merge(context))

        def discover(step, body, status: 200)
          @source.parse_discovery(request: request(step), response: file_response(body, status: status))
        end

        def collection(html, status: 200, page: 1, **options)
          @source.parse_discovery(
            request: Request.page(COMING_SOON, context: {"step" => "collection", "page" => page}),
            response: page(html, status: status, **options)
          )
        end

        def read(name, key = "1", **options)
          @source.parse_listing(listing: ListingRef.new(url: "u", external_key: key, signal: nil),
            page: page(fixture_text("#{name}.html.gz"), **options))
        end

        def formats(reading) = reading.facts[:formats].map { |f| f.values_at(:isbn13, :format, :format_label) }

        test "identity" do
          assert_equal ["macmillan_us", "Macmillan", 1, true],
            [@source.key, @source.name, @source.parser_version, @source.baseline_on_first_run?]
          assert_equal MacmillanUs, Sources.registry["macmillan_us"]
        end

        test "discovery starts at the sitemap index and follows only the product files" do
          requests = @source.discovery_requests(since: nil)

          assert_equal ["file", "#{SITE}/sitemap_index.xml", {"step" => "index"}],
            [requests.first.kind, requests.first.url, requests.first.context]
          assert_equal 1, requests.size

          result = discover("index", fixture_text("sitemap_index.xml"))

          assert_equal :ok, result.outcome
          assert_empty result.listings
          assert_equal %W[#{SITE}/sitemaps/sitemap-products.1.xml.gz #{SITE}/sitemaps/sitemap-products.2.xml.gz
            #{SITE}/sitemaps/sitemap-products.70.xml.gz], result.requests.map(&:url)
          assert_equal [["file", {"step" => "products"}]] * 3, result.requests.map { |r| [r.kind, r.context] }
        end

        test "every product entry with an ISBN in its url becomes a listing with no signal" do
          result = discover("products", fixture_bytes("sitemap_products_urlset.xml.gz"))

          assert_equal :ok, result.outcome
          assert_empty result.requests
          assert_equal %w[9781429901345 9781250369550 9780374619206 9781250410153 9781250466631],
            result.listings.map(&:external_key)
          assert_equal "#{SITE}/books/9781429901345/aisforalibi/", result.listings.first.url
          assert_equal [nil], result.listings.map(&:signal).uniq
        end

        test "an entry without an ISBN is skipped" do
          urls = discover("products", fixture_bytes("sitemap_products_urlset.xml.gz")).listings.map(&:url)

          assert_equal 5, urls.size
          refute_includes urls, "#{SITE}/books/"
        end

        test "an ISBN is read from its own path segment" do
          body = <<~XML
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
              <url><loc>#{SITE}/authors/9781250369550/x/</loc></url>
              <url><loc>#{SITE}/xbooks/9781250369550/x/</loc></url>
              <url><loc>#{SITE}/books/97812503695501/x/</loc></url>
              <url><loc>#{SITE}/books/9781250369550/x/</loc></url>
            </urlset>
          XML

          assert_equal ["#{SITE}/books/9781250369550/x/"], discover("products", body).listings.map(&:url)
        end

        test "an unreadable or misplaced sitemap is unparseable, and statuses carry their own outcome" do
          assert_equal :unparseable, discover("index", "<html>not a sitemap</html>").outcome
          assert_equal :unparseable, discover("products", "").outcome
          assert_equal :unparseable, discover("index", fixture_bytes("sitemap_products_urlset.xml.gz")).outcome
          assert_equal :unparseable, discover("products", fixture_text("sitemap_index.xml")).outcome
          assert_equal :unparseable, discover("other", fixture_text("sitemap_index.xml")).outcome
          assert_equal :blocked, discover("index", "", status: 403).outcome
          assert_equal :unavailable, discover("products", "", status: 503).outcome
          assert_equal :not_found, discover("index", "", status: 404).outcome
        end

        test "the source baselines on its first run" do
          assert @source.baseline_on_first_run?
        end

        test "the seed asks for the Coming Soon and New Releases collections" do
          requests = @source.seed_requests

          assert_equal [COMING_SOON, NEW_RELEASES], requests.map(&:url)
          assert_equal [["page", "a[href*='/books/97']", {"step" => "collection", "page" => 1}]] * 2,
            requests.map { |r| [r.kind, r.wait_for_selector, r.context] }
        end

        test "a collection page yields one listing per distinct book link" do
          # five results, each linked twice (image and title), after two featured books in the menu
          result = collection(fixture_text("collection_coming_soon.html.gz"))

          assert_equal :ok, result.outcome
          assert_equal %w[9781250477330 9781250428677 9780374618810 9781250424853 9781250478580],
            result.listings.map(&:external_key)
          assert_equal "#{SITE}/books/9781250477330/source-code/", result.listings.first.url
          assert_equal [nil], result.listings.map(&:signal).uniq
        end

        test "collection paging is not followed: a collection page yields no follow-up request" do
          # The site's own page links ?p=1 for page 2, and fetching that URL answers "Page not found";
          # the next page is loaded by script. So only the first page of each collection is read.
          [1, 2, 19].each do |number|
            result = collection(fixture_text("collection_coming_soon.html.gz"), page: number)

            assert_equal 5, result.listings.size
            assert_empty result.requests
          end
        end

        test "a collection page with no book links is ok and empty on the site, blocked off it" do
          empty = collection("<html><head><title>Search - Macmillan Publishers</title></head><body></body></html>")
          assert_equal [:ok, [], []], [empty.outcome, empty.listings, empty.requests]

          wall = collection(fixture_text("synthetic_challenge.html"))
          assert_equal [:blocked, []], [wall.outcome, wall.listings]
        end

        test "a collection answers its status when the site gave one" do
          assert_equal :not_found, collection("", status: 404, title: "Page not found - Macmillan Publishers").outcome
          assert_equal :unavailable, collection("", status: 503, title: "").outcome
        end

        test "the listing request waits for the heading" do
          request = @source.listing_request(ListingRef.new(url: "#{SITE}/books/9781250369550/nightcurse/", external_key: "9781250369550", signal: nil))

          assert_equal ["page", "#{SITE}/books/9781250369550/nightcurse/", "h1"],
            [request.kind, request.url, request.wait_for_selector]
        end

        test "the novel reads with title, author, imprint, genre, age range, pages, on-sale date and three formats" do
          reading = read("novel_three_formats", "9781250369550")
          facts = reading.facts

          assert_equal :found, reading.outcome
          assert_equal "Nightcurse", facts[:title]
          assert_nil facts[:subtitle]
          assert_equal [{name: "Emma Hinds", role: "author"}], facts[:contributors]
          assert_equal "Wednesday Books", facts[:imprint_name]
          assert_equal "Macmillan", facts[:publisher_name]
          assert_equal ["Young Adult"], facts[:genres]
          assert_equal "13-18", facts[:age_range]
          assert_equal Date.new(2026, 11, 10), facts[:on_sale_on]
          assert_equal "9781250369550", facts[:source_key]
          assert_equal "https://mpd-biblio-covers.imgix.net/9781250369550.jpg", facts[:cover_url]
          assert_includes facts[:description], "Cursed with eternity"
          assert_includes facts[:description], "\n"
          assert_equal [["9781250369550", "hardcover", "Hardcover"], ["9781250369567", "ebook", "e-Book"],
            ["9781250472359", "audiobook", "Digital Audio"]], formats(reading)
          own, ebook, audio = facts[:formats]
          assert_equal [352, Date.new(2026, 11, 10), 2100, "USD"], own.values_at(:pages, :on_sale_on, :price_cents, :currency)
          assert_equal [nil, nil, nil, nil], ebook.values_at(:pages, :on_sale_on, :price_cents, :currency)
          assert_equal [nil, nil, nil, nil], audio.values_at(:pages, :on_sale_on, :price_cents, :currency)
        end

        test "the language is nil because the site shows no signal for it" do
          assert_nil read("novel_three_formats").facts[:language]
          assert_nil read("translated_novel").facts[:language]
        end

        test "the on-sale date parses from month/day/year" do
          assert_equal Date.new(2026, 11, 10), read("novel_three_formats").facts[:on_sale_on]
          assert_equal Date.new(2027, 2, 9), read("translated_novel").facts[:on_sale_on]
          assert_equal Date.new(2026, 10, 6), read("picture_book_illustrator").facts[:on_sale_on]
        end

        test "an on-sale date that is not month/day/year is nil, on the page and on its format" do
          html = fixture_text("novel_three_formats.html.gz").sub("11/10/2026", "13/45/2026")
          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil), page: page(html))

          assert_equal :found, reading.outcome
          assert_nil reading.facts[:on_sale_on]
          assert_nil reading.facts[:formats].first[:on_sale_on]
        end

        test "siblings are the other two formats' ISBNs" do
          assert_equal %w[9781250369567 9781250472359], read("novel_three_formats").sibling_keys
        end

        test "a page with one format has no siblings, and takes its format from the page's own label" do
          reading = read("picture_book_illustrator", "9781250410153")

          assert_equal [], reading.sibling_keys
          assert_equal [["9781250410153", "hardcover", "Hardcover"]], formats(reading)
          assert_equal [32, Date.new(2026, 10, 6), 2199], reading.facts[:formats].first.values_at(:pages, :on_sale_on, :price_cents)
        end

        test "a translated novel keeps the author and the translator apart" do
          reading = read("translated_novel")

          assert_equal [{name: "Ananda Devi", role: "author"}, {name: "Jeffrey Zuckerman", role: "translator"}],
            reading.facts[:contributors]
          assert_equal [["9780374619206", "paperback", "Trade Paperback"], ["9780374619213", "ebook", "e-Book"]], formats(reading)
          assert_equal %w[9780374619213], reading.sibling_keys
          assert_equal ["Literary Fiction"], reading.facts[:genres]
          assert_nil reading.facts[:age_range]
        end

        test "a picture book keeps the illustrator apart from the author" do
          reading = read("picture_book_illustrator")

          assert_equal [{name: "Bill Martin Jr.", role: "author"}, {name: "Eric Carle", role: "illustrator"}],
            reading.facts[:contributors]
          assert_equal "2-5", reading.facts[:age_range]
          assert_equal ["Children’s Literature"], reading.facts[:genres]
          assert_equal "Henry Holt and Co. (BYR)", reading.facts[:imprint_name]
        end

        test "a boxed set has no page count and reads like any other title" do
          reading = read("boxed_set_no_pages")

          assert_equal :found, reading.outcome
          assert_equal "Greenwild Boxed Set", reading.facts[:title]
          assert_equal [["9781250466631", "paperback", "Trade Paperback"]], formats(reading)
          assert_nil reading.facts[:formats].first[:pages]
          assert_equal 2997, reading.facts[:formats].first[:price_cents]
          assert_equal "Square Fish", reading.facts[:imprint_name]
        end

        test "a graphic-novel boxed set keeps its hardcover label and a description built from several paragraphs" do
          reading = read("graphic_boxed_set")

          assert_equal [["9781250449641", "hardcover", "Hardcover"]], formats(reading)
          assert_equal "First Second", reading.facts[:imprint_name]
          assert_match(/\n/, reading.facts[:description])
          assert_includes reading.facts[:description].lines.map(&:strip), "The InvestiGators are on the case...and in a slipcase!"
        end

        test "a two-format page lists the hardcover and the ebook, and its page count belongs to its own format" do
          reading = read("classic_two_formats")

          assert_equal [["9781035092512", "hardcover", "Hardcover"], ["9781035092529", "ebook", "e-Book"]], formats(reading)
          assert_equal [368, nil], reading.facts[:formats].map { |f| f[:pages] }
          assert_equal "Macmillan Collector's Library", reading.facts[:imprint_name]
        end

        test "the format class on the cover is not trusted: a paperback page reads as a paperback" do
          # The real boxed-set page puts a paperback in a "book-form__book--hardcover" element.
          assert_includes fixture_text("boxed_set_no_pages.html.gz"), "book-form__book--hardcover"
          assert_equal "paperback", read("boxed_set_no_pages").facts[:formats].first[:format]
        end

        test "the JSON-LD author is not trusted: it carries the translator, and the page line is split instead" do
          html = fixture_text("translated_novel.html.gz")

          assert_includes html, '"name":"Ananda Devi; Translated from the French by Jeffrey Zuckerman"'
          assert_equal %w[Ananda\ Devi Jeffrey\ Zuckerman], read("translated_novel").facts[:contributors].map { |c| c[:name] }
        end

        test "the page's own ISBN comes from the JSON-LD, then the details list, then the listing" do
          html = fixture_text("boxed_set_no_pages.html.gz")
          without_json = html.gsub(%r{<script type="application/ld\+json">.*?</script>}m, "")
          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "9780000000002", signal: nil), page: page(without_json))
          assert_equal "9781250466631", reading.facts[:source_key]

          without_details = without_json.sub("9781250466631</p>", "</p>")
          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "9781250466631", signal: nil), page: page(without_details))
          assert_equal "9781250466631", reading.facts[:formats].first[:isbn13]
        end

        test "an odd format entry is skipped and the rest are kept" do
          html = fixture_text("novel_three_formats.html.gz").gsub('data-format-isbn="9781250369567"', 'data-format-isbn="not-an-isbn"')
          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil), page: page(html))

          assert_equal %w[9781250369550 9781250472359], reading.facts[:formats].map { |f| f[:isbn13] }
          assert_equal %w[9781250472359], reading.sibling_keys
        end

        test "a missing or placeholder cover is nil" do
          html = fixture_text("novel_three_formats.html.gz")
          none = html.gsub(/<meta property="og:image"[^>]*>/, "").gsub(%r{"image":"[^"]*"}, '"image":""')
          placeholder = html.gsub(%r{https://mpd-biblio-covers\.imgix\.net/9781250369550\.jpg}, "#{SITE}/wp-content/themes/x/lazyload-book.jpg")

          [none, placeholder].each do |markup|
            assert_nil @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil),
              page: page(markup)).facts[:cover_url]
          end
        end

        test "malformed JSON-LD does not stop the read: the heading and the details list stand in" do
          html = fixture_text("novel_three_formats.html.gz")
          malformed = html.sub(/(<script type="application\/ld\+json">).*?(<\/script>)/m, '\1{not json\2')

          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil), page: page(malformed))

          assert_equal :found, reading.outcome
          assert_equal "Nightcurse", reading.facts[:title]
        end

        test "a redesigned page is unparseable, a challenge page is blocked, a 404 is not found" do
          redesigned = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil),
            page: page(fixture_text("synthetic_redesigned.html")))
          challenge = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil),
            page: page(fixture_text("synthetic_challenge.html")))
          missing = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil),
            page: page("", status: 404, title: "Page not found - Macmillan Publishers"))

          assert_equal [:unparseable, {}], [redesigned.outcome, redesigned.facts]
          assert_equal :blocked, challenge.outcome
          assert_equal :not_found, missing.outcome
        end

        test "a page that says it was not found with a 200 is not found, and other statuses carry their own outcome" do
          ref = ListingRef.new(url: "u", external_key: "1", signal: nil)

          assert_equal :not_found, @source.parse_listing(listing: ref, page: page("", title: "Page not found - Macmillan Publishers")).outcome
          assert_equal :blocked, @source.parse_listing(listing: ref, page: page("", status: 403, title: "x")).outcome
          assert_equal :unavailable, @source.parse_listing(listing: ref, page: page("", status: 503, title: "x")).outcome
        end

        test "every fixture is within the size limit" do
          Dir[Rails.root.join("test/fixtures/files/#{DIR}/*")].each do |path|
            body = path.end_with?(".gz") ? Zlib.gunzip(File.binread(path)) : File.binread(path)
            assert_operator body.bytesize, :<=, 60_000, path
          end
        end
      end
    end
  end
end
