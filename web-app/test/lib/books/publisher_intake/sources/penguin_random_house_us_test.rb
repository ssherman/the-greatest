# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    module Sources
      # Product pages (novel_four_formats, manga_single_format, spanish_edition,
      # spanish_childrens, picture_book, reissue) are real pages, cut by hand to
      # what the parser reads: scripts, forms, images and long copy removed,
      # JSON-LD strings cut to a sentence. sitemap_index.xml and
      # sitemap_works_urlset.xml are HAND-BUILT from the real files (real URLs,
      # a few dates edited, said so in each file's comment). synthetic_* pages
      # are made up and say why in a comment.
      class PenguinRandomHouseUsTest < ActiveSupport::TestCase
        DIR = "publisher_intake/penguin_random_house_us"
        SITE = "https://www.penguinrandomhouse.com"

        setup do
          travel_to Time.utc(2026, 11, 17, 12)
          @source = PenguinRandomHouseUs.new
        end

        def fixture_text(name)
          path = file_fixture("#{DIR}/#{name}")
          (name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread).force_encoding(Encoding::UTF_8)
        end

        def file_response(body, status: 200)
          PageFetcher::FileResponse.new(url: "u", final_url: "u", status: status, content_type: "application/xml",
            body: body.b, elapsed_ms: 1, fetched_at: Time.current)
        end

        def request(step) = Request.file("#{SITE}/x.xml", context: {"step" => step})

        def discover(step, body, status: 200)
          @source.parse_discovery(request: request(step), response: file_response(body, status: status))
        end

        def product_page(html, status: 200, title: nil)
          title ||= html[%r{<title>(.*?)</title>}m, 1]
          PageFetcher::Page.new(url: "u", final_url: "u", status: status, title: title, html: html,
            selector_found: true, elapsed_ms: 1, fetched_at: Time.current)
        end

        def read(name, key = "1", **page_options)
          @source.parse_listing(listing: ListingRef.new(url: "u", external_key: key, signal: nil),
            page: product_page(fixture_text(name), **page_options))
        end

        def formats(reading) = reading.facts[:formats].map { |f| f.values_at(:isbn13, :format, :format_label) }

        test "identity" do
          assert_equal ["penguin_random_house_us", "Penguin Random House", 1, false],
            [@source.key, @source.name, @source.parser_version, @source.baseline_on_first_run?]
          assert_equal PenguinRandomHouseUs, Sources.registry["penguin_random_house_us"]
        end

        test "discovery starts at the sitemap index" do
          requests = @source.discovery_requests(since: nil)

          assert_equal 1, requests.size
          assert_equal ["file", "#{SITE}/sitemap.xml", {"step" => "index"}],
            [requests.first.kind, requests.first.url, requests.first.context]
          assert_equal requests.first.url, @source.discovery_requests(since: Time.current).first.url
        end

        test "the index yields only this year's and the horizon year's works files" do
          # today 2026-11-17 plus 365 days is 2027-11-17: the files for 2026 and 2027, not 2025, cats, auths or series
          result = discover("index", fixture_text("sitemap_index.xml"))

          assert_equal :ok, result.outcome
          assert_empty result.listings
          assert_equal ["#{SITE}/sitemap-works-2027.xml", "#{SITE}/sitemap-works-2026.xml"], result.requests.map(&:url)
          assert_equal [["file", {"step" => "works"}]] * 2, result.requests.map { |r| [r.kind, r.context] }
        end

        test "a works file for a year past the horizon is not followed" do
          travel_to Time.utc(2026, 12, 31) do
            urls = discover("index", fixture_text("sitemap_index.xml")).requests.map(&:url)

            assert_equal ["#{SITE}/sitemap-works-2027.xml", "#{SITE}/sitemap-works-2026.xml"], urls
          end
          travel_to Time.utc(2025, 1, 5) do
            assert_equal ["#{SITE}/sitemap-works-2026.xml", "#{SITE}/sitemap-works-2025.xml"],
              discover("index", fixture_text("sitemap_index.xml")).requests.map(&:url)
          end
        end

        test "only works whose date is inside the window become listings" do
          result = discover("works", fixture_text("sitemap_works_urlset.xml"))

          assert_equal :ok, result.outcome
          assert_empty result.requests
          assert_equal %w[743565 855221 839216], result.listings.map(&:external_key)
          assert_equal "#{SITE}/books/743565/the-collateral-heart-by-jeffery-deaver/", result.listings.first.url
        end

        test "entries dated 1976 and 2079, with no date, or with no work id are skipped without raising" do
          keys = discover("works", fixture_text("sitemap_works_urlset.xml")).listings.map(&:external_key)

          # 2519 is dated 1976, 859986 is dated 2079, 863063 is 31 days ago, 3325 has no lastmod,
          # and the site's root page has a date inside the window but no work id.
          %w[2519 859986 863063 3325].each { |id| refute_includes keys, id }
          assert_equal 3, keys.size
        end

        test "the listing's key is the work id and its signal the lastmod" do
          listings = discover("works", fixture_text("sitemap_works_urlset.xml")).listings

          assert_equal [["743565", "2026-11-17"], ["855221", "2026-12-08"], ["839216", "2026-11-17"]],
            listings.map { |l| [l.external_key, l.signal] }
        end

        test "a work id is read from its own path segment" do
          body = <<~XML
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
              <url><loc>#{SITE}/authors/555/books/by-someone/</loc><lastmod>2026-11-20</lastmod></url>
              <url><loc>#{SITE}/xbooks/556/slug/</loc><lastmod>2026-11-20</lastmod></url>
              <url><loc>#{SITE}/books/557/slug/</loc><lastmod>2026-11-20</lastmod></url>
            </urlset>
          XML

          assert_equal ["557"], discover("works", body).listings.map(&:external_key)
        end

        test "an unreadable sitemap is unparseable, and statuses carry their own outcome" do
          assert_equal :unparseable, discover("index", "<html>not a sitemap</html>").outcome
          assert_equal :unparseable, discover("works", "").outcome
          assert_equal :blocked, discover("index", "", status: 403).outcome
          assert_equal :unavailable, discover("works", "", status: 503).outcome
          assert_equal :not_found, discover("works", "", status: 404).outcome
        end

        test "a sitemap kind that does not match the step is unparseable" do
          assert_equal :unparseable, discover("index", fixture_text("sitemap_works_urlset.xml")).outcome
          assert_equal :unparseable, discover("works", fixture_text("sitemap_index.xml")).outcome
        end

        test "the listing request is a page request waiting for the heading" do
          request = @source.listing_request(ListingRef.new(url: "#{SITE}/books/1/a-b/", external_key: "1", signal: nil))

          assert_equal ["page", "#{SITE}/books/1/a-b/", "h1"], [request.kind, request.url, request.wait_for_selector]
        end

        test "the novel reads with every format from workExample, its imprint, genres, pages and language" do
          reading = read("novel_four_formats.html.gz", "743565")
          facts = reading.facts

          assert_equal :found, reading.outcome
          assert_equal [], reading.sibling_keys
          assert_equal "The Collateral Heart", facts[:title]
          assert_nil facts[:subtitle]
          assert_equal [{name: "Jeffery Deaver", role: "author"}], facts[:contributors]
          assert_equal ["G.P. Putnam's Sons", "Penguin Random House", "English"],
            [facts[:imprint_name], facts[:publisher_name], facts[:language]]
          assert_equal ["Crime Fiction", "Suspense & Thriller"], facts[:genres]
          assert_equal ["Lincoln Rhyme Novel", nil], [facts[:series_name], facts[:series_position]]
          assert_equal "https://images.penguinrandomhouse.com/cover/9780593717523", facts[:cover_url]
          assert_includes facts[:description], "returns with a propulsive new thriller"
          assert_equal [
            ["9798217414055", "paperback", "Large Print"],
            ["9780593717523", "hardcover", "Hardcover"],
            ["9780593717530", "ebook", "Ebook"],
            ["9798217355853", "audiobook", "Audiobook Download"]
          ], formats(reading)

          large_print, hardcover, ebook, audio = facts[:formats]
          assert_equal [512, 3400, "USD"], large_print.values_at(:pages, :price_cents, :currency)
          assert_equal [416, 3200, Date.new(2026, 11, 17)], hardcover.values_at(:pages, :price_cents, :on_sale_on)
          assert_equal [416, 1499], ebook.values_at(:pages, :price_cents)
          assert_equal [nil, 2400], audio.values_at(:pages, :price_cents)
        end

        test "the novel's JSON-LD formats and dates agree with the page's own format rows" do
          # Checked against the rows the page shows for each ISBN: same ISBNs, same dates. Only the
          # wording differs (a large-print paperback is a Paperback in the JSON-LD).
          reading = read("novel_four_formats.html.gz", "743565")
          html = fixture_text("novel_four_formats.html.gz")

          assert_equal reading.facts[:formats].map { |f| f[:isbn13] }.sort,
            html[/data-id="([^"]*)"/, 1].split(",").sort
          rows = Nokogiri::HTML(html).css(".bookRow[isbn]")
          assert_equal reading.facts[:formats].map { |f| f[:isbn13] }.sort, rows.map { |row| row["isbn"] }.sort
          assert(rows.all? { |row| row.text.include?("Published on Nov 17, 2026") })
          assert_equal [Date.new(2026, 11, 17)], reading.facts[:formats].map { |f| f[:on_sale_on] }.uniq
        end

        test "the earliest format date is what on-sale date will be, and each format keeps its own" do
          reading = read("picture_book.html.gz", "545998")

          assert_equal [["9781536255003", Date.new(2026, 12, 29)], ["9780763699413", Date.new(2018, 3, 6)]],
            reading.facts[:formats].map { |f| f.values_at(:isbn13, :on_sale_on) }
          assert_equal Date.new(2018, 3, 6), reading.facts[:on_sale_on]
        end

        test "the Spanish edition reads as Spanish and is held as non_english although its JSON-LD says English" do
          reading = read("spanish_edition.html.gz", "855221")

          assert_equal :found, reading.outcome
          assert_equal "Los propios dioses / The Gods Themselves", reading.facts[:title]
          assert_equal ["Spanish", "Debolsillo"], reading.facts.values_at(:language, :imprint_name)
          assert_equal ["Spanish Language Fiction"], reading.facts[:genres]
          assert_equal [[{name: "Isaac Asimov", role: "author"}]], [reading.facts[:contributors]]
          assert_equal [:held, :non_english], Hold.call(reading.facts)
          assert_includes fixture_text("spanish_edition.html.gz"), '"inLanguage":"English"'
        end

        test "a Spanish children's edition is recognised by its genre" do
          reading = read("spanish_childrens.html.gz", "843286")

          assert_equal "Spanish", reading.facts[:language]
          assert_equal ["Children’s Spanish Language Books"], reading.facts[:genres]
          assert_equal "6-9 years", reading.facts[:age_range]
          assert_equal [:held, :non_english], Hold.call(reading.facts)
        end

        test "the manga volume reads as a ready single-format title with its series and position" do
          reading = read("manga_single_format.html.gz", "839216")
          facts = reading.facts

          assert_equal :found, reading.outcome
          assert_equal "KILLING ME / KILLING YOU Vol. 3", facts[:title]
          assert_equal [{name: "Imomushi Narita", role: "author"}], facts[:contributors]
          assert_equal [["9798897652754", "paperback", "Paperback"]], formats(reading)
          assert_equal [196, 1499, Date.new(2026, 11, 17)], facts[:formats].first.values_at(:pages, :price_cents, :on_sale_on)
          assert_equal ["Seven Seas", ["Manga", "Fiction Graphic Novels"]], [facts[:imprint_name], facts[:genres]]
          assert_equal ["Killing Me / Killing You", "3"], facts.values_at(:series_name, :series_position)
          assert_equal [:ready, nil], Hold.call(facts)
        end

        test "the picture book reads as a ready board book with an illustrator-author, subtitle and age range" do
          reading = read("picture_book.html.gz", "545998")
          facts = reading.facts

          assert_equal :found, reading.outcome
          assert_equal "Love", facts[:title]
          assert_includes facts[:subtitle], "A Heartwarming Baby Board Book"
          assert_equal [{name: "Emma Dodd", role: "author"}], facts[:contributors]
          assert_equal [["9781536255003", "board_book", "Board Book"], ["9780763699413", "board_book", "Board Book"]], formats(reading)
          assert_equal ["0-3 years", "Candlewick Press", "Emma Dodd's Love You Books"],
            facts.values_at(:age_range, :imprint_name, :series_name)
          assert_equal [22, 1299], facts[:formats].first.values_at(:pages, :price_cents)
          assert_equal [22, 999], facts[:formats].last.values_at(:pages, :price_cents)
          assert_equal [:ready, nil], Hold.call(facts)
        end

        test "the reissue reads with its subtitle and its own date" do
          reading = read("reissue.html.gz", "855455")

          assert_equal "Confessions of a Shopaholic (Deluxe 25th Anniversary Edition)", reading.facts[:title]
          assert_equal "A Novel", reading.facts[:subtitle]
          assert_equal [["9798217199853", "paperback", "Paperback"]], formats(reading)
          assert_equal [Date.new(2026, 11, 24), "Dial Press Trade Paperback"], reading.facts.values_at(:on_sale_on, :imprint_name)
          assert_equal [:ready, nil], Hold.call(reading.facts)
        end

        test "the title's source key is the work id" do
          assert_equal "743565", read("novel_four_formats.html.gz", "743565").facts[:source_key]
          assert_equal "855455", read("reissue.html.gz", "855455").facts[:source_key]
        end

        test "a redesigned page is unparseable, a challenge page is blocked" do
          redesigned = read("synthetic_redesigned.html")
          assert_equal [:unparseable, {}, []], [redesigned.outcome, redesigned.facts, redesigned.sibling_keys]

          assert_equal :blocked, read("synthetic_challenge.html").outcome
          assert_equal :blocked, read("synthetic_challenge.html", status: 403).outcome
          assert_equal :unavailable, read("synthetic_challenge.html", status: 503).outcome
          assert_equal :not_found, read("novel_four_formats.html.gz", status: 404).outcome
        end

        test "the site's not-found page is not found even when it comes with status 200" do
          assert_equal :not_found, read("synthetic_not_found.html").outcome
        end

        test "a record shape that is wrong skips that format or field and keeps the rest" do
          html = fixture_text("novel_four_formats.html.gz")
          ld = html[%r{<script type="application/ld\+json">(.*?)</script>}m, 1]
          data = JSON.parse(ld)
          book = data["mainEntity"]
          book["workExample"] = ["junk", nil, 7, {"isbn" => "not-an-isbn", "bookFormat" => "https://schema.org/Ebook"},
            {"@type" => ["Book"], "isbn" => 9780593717530, "bookFormat" => ["x"], "datePublished" => ["2026-11-17"]},
            {"isbn" => 9780593717523, "bookFormat" => "https://schema.org/Hardcover", "datePublished" => "garbage"}]
          book["author"] = [{"name" => "Jeffery Deaver"}, "Second Author", 5, nil]
          book["image"] = ["https://images.penguinrandomhouse.com/cover/9780593717523?x=1"]
          mangled = html.sub(ld, JSON.generate(data)).sub(/<h2 class="contributors[^"]*show">.*?<\/h2>/m, "")

          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "743565", signal: nil), page: product_page(mangled))

          assert_equal :found, reading.outcome
          # the junk and the bad ISBN are skipped; the two ISBNs the page's rows show but the JSON-LD lost are kept
          assert_equal %w[9780593717530 9780593717523 9798217414055 9798217355853], reading.facts[:formats].map { |f| f[:isbn13] }
          # the ebook's own date is unusable, so the page's row date is used; the hardcover's "garbage" likewise
          assert_equal [[Date.new(2026, 11, 17), "ebook"], [Date.new(2026, 11, 17), "hardcover"]],
            reading.facts[:formats].first(2).map { |f| f.values_at(:on_sale_on, :format) }
          assert_equal [{name: "Jeffery Deaver", role: "author"}, {name: "Second Author", role: "author"}], reading.facts[:contributors]
          assert_equal "https://images.penguinrandomhouse.com/cover/9780593717523", reading.facts[:cover_url]
        end

        test "an ISBN given as a JSON number reads, and a work whose page has no ISBN is unparseable" do
          html = fixture_text("manga_single_format.html.gz")
          numeric = html.gsub('"isbn":"9798897652754"', '"isbn":9798897652754')
          assert_equal "9798897652754", read_html(numeric).facts[:formats].first[:isbn13]

          stripped = html.gsub("9798897652754", "0")
          assert_equal :unparseable, read_html(stripped).outcome
        end

        test "a missing or placeholder cover is nil" do
          html = fixture_text("manga_single_format.html.gz")
          without = html.gsub(%r{"image":"[^"]*"}, '"image":""')
          assert_nil read_html(without).facts[:cover_url]

          absent = html.gsub(%r{"image":"[^"]*",?}, "")
          assert_nil read_html(absent).facts[:cover_url]
        end

        test "format words: board and mass market are recognised, an unknown label falls back to bookFormat, then other" do
          html = fixture_text("manga_single_format.html.gz")
          {"Mass Market Paperback" => "mass_market", "Board Book" => "board_book", "Audiobook CD" => "audiobook",
           "Hardcover" => "hardcover", "Ebook" => "ebook", "Large Print" => "paperback", "Calendar" => "paperback"}.each do |label, format|
            changed = html.gsub('format-name="Paperback"', %(format-name="#{label}")).gsub(">Paperback<", ">#{label}<")
            assert_equal [label, format], [label, read_html(changed).facts[:formats].first[:format]]
          end

          no_json_format = html.gsub(%r{"bookFormat":"[^"]*"}, '"bookFormat":"https://schema.org/Thing"')
            .gsub('format-name="Paperback"', 'format-name="Calendar"').gsub(">Paperback<", ">Calendar<")
          assert_equal "other", read_html(no_json_format).facts[:formats].first[:format]
        end

        def read_html(html)
          @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "1", signal: nil), page: product_page(html))
        end
      end
    end
  end
end
