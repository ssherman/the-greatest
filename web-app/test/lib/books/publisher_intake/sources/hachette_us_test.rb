# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    module Sources
      # The product pages are real, trimmed by FixtureTrimmer and by hand; the
      # synthetic_* pages say in a comment why they are made up. api_page_1.json
      # and api_page_2.json are SYNTHETIC records in the real API's shape (ids
      # 900001-900004 and example-author are invented; JSON cannot carry a
      # comment); api_past_the_end.json is a real body.
      class HachetteUsTest < ActiveSupport::TestCase
        API = "https://www.hachettebookgroup.com/wp-json/wp/v2/hbg-title"
        FIELDS = "_fields=id,date,modified,link,meta"

        setup do
          travel_to Time.utc(2026, 11, 18, 12)
          @source = HachetteUs.new
        end

        def fixture_text(name)
          path = file_fixture("publisher_intake/hachette_us/#{name}")
          (name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread).force_encoding(Encoding::UTF_8)
        end

        def api_response(body, status: 200)
          PageFetcher::FileResponse.new(url: "u", final_url: "u", status: status, content_type: "application/json",
            body: body.b, elapsed_ms: 1, fetched_at: Time.current)
        end

        def api_request(page: 1, filter: "after=2025-09-18T12%3A00%3A00Z")
          Request.file("#{API}?per_page=100&page=#{page}&#{filter}&#{FIELDS}",
            context: {"page" => page, "filter" => filter})
        end

        def product_page(name, status: 200, title: nil)
          html = fixture_text(name)
          title ||= html[%r{<title>(.*?)</title>}m, 1]
          PageFetcher::Page.new(url: "u", final_url: "u", status: status, title: title, html: html,
            selector_found: true, elapsed_ms: 1, fetched_at: Time.current)
        end

        def read(name, key, **page_options)
          @source.parse_listing(listing: ListingRef.new(url: "u", external_key: key, signal: nil),
            page: product_page(name, **page_options))
        end

        def formats(reading) = reading.facts[:formats].map { |f| f.values_at(:isbn13, :format, :format_label) }

        test "identity" do
          assert_equal ["hachette_us", "Hachette Book Group", 1, false],
            [@source.key, @source.name, @source.parser_version, @source.baseline_on_first_run?]
          assert_equal HachetteUs, Sources.registry["hachette_us"]
        end

        test "discovery asks for the first page with the filter for a first run and for a later run" do
          first = @source.discovery_requests(since: nil)
          assert_equal 1, first.size
          assert_equal "file", first.first.kind
          assert_equal "#{API}?per_page=100&page=1&after=#{CGI.escape("2025-09-18T12:00:00Z")}&#{FIELDS}", first.first.url
          assert_equal({"page" => 1, "filter" => "after=#{CGI.escape("2025-09-18T12:00:00Z")}"}, first.first.context)

          # one day of margin before the last run's start
          later = @source.discovery_requests(since: Time.utc(2026, 11, 10, 6, 20))
          filter = "modified_after=#{CGI.escape("2026-11-09T06:20:00Z")}"
          assert_equal "#{API}?per_page=100&page=1&#{filter}&#{FIELDS}", later.first.url
          assert_equal({"page" => 1, "filter" => filter}, later.first.context)
        end

        test "a full page yields a next-page request; a short page ends discovery" do
          full = Array.new(100) { |i| {"link" => "https://x/titles/a/b/9780316000024/", "modified" => "t", "meta" => {"release_date" => "2026-12-01"}, "id" => i} }
          request = api_request(page: 3, filter: "modified_after=X")

          result = @source.parse_discovery(request: request, response: api_response(JSON.generate(full)))
          assert_equal :ok, result.outcome
          assert_equal 1, result.requests.size
          assert_equal "#{API}?per_page=100&page=4&modified_after=X&#{FIELDS}", result.requests.first.url
          assert_equal({"page" => 4, "filter" => "modified_after=X"}, result.requests.first.context)

          short = @source.parse_discovery(request: request, response: api_response(fixture_text("api_page_1.json")))
          assert_equal [:ok, []], [short.outcome, short.requests]
        end

        test "the page past the end is ok and empty, not an error" do
          result = @source.parse_discovery(request: api_request(page: 9999),
            response: api_response(fixture_text("api_past_the_end.json"), status: 400))

          assert_equal [:ok, [], []], [result.outcome, result.listings, result.requests]
        end

        test "a 400 that is not the past-the-end answer is unparseable" do
          result = @source.parse_discovery(request: api_request, response: api_response('{"code":"rest_invalid_param"}', status: 400))

          assert_equal :unparseable, result.outcome
        end

        test "only records on sale inside the window become listings" do
          result = @source.parse_discovery(request: api_request, response: api_response(fixture_text("api_page_1.json")))

          # 2026-11-18 less 30 days to plus 365 days: the 2011 record and the empty one are out.
          assert_equal %w[9781538792346 9780316612593 9780316000017], result.listings.map(&:external_key)
          assert_equal "https://www.hachettebookgroup.com/titles/fawn-weaver/blink-last/9781538792346/", result.listings.first.url

          second = @source.parse_discovery(request: api_request(page: 2), response: api_response(fixture_text("api_page_2.json")))
          assert_equal %w[9781668666289 9781454977902], second.listings.map(&:external_key)
        end

        test "a record with an empty or unparseable release date is skipped without raising" do
          page_1 = @source.parse_discovery(request: api_request, response: api_response(fixture_text("api_page_1.json")))
          page_2 = @source.parse_discovery(request: api_request(page: 2), response: api_response(fixture_text("api_page_2.json")))

          assert_equal [:ok, :ok], [page_1.outcome, page_2.outcome]
          refute_includes page_1.listings.map(&:external_key), "9780316000024"
          refute_includes page_2.listings.map(&:external_key), "9780316000031"
        end

        test "a record that is not a hash, or whose meta is not a hash, is skipped and the rest of the page is kept" do
          good = {"link" => "https://x/titles/a/b/9780316000024/", "modified" => "t", "meta" => {"release_date" => "2026-12-01"}}
          body = JSON.generate([good, "junk", nil, good.merge("meta" => []), good.merge("link" => "https://x/titles/a/b/9780316000017/")])

          result = @source.parse_discovery(request: api_request, response: api_response(body))

          assert_equal [:ok, %w[9780316000024 9780316000017]], [result.outcome, result.listings.map(&:external_key)]
        end

        test "a link whose last path segment is not exactly an ISBN-13 yields no listing" do
          body = JSON.generate([{"link" => "https://x/titles/a/b/129780316564861/", "modified" => "t", "meta" => {"release_date" => "2026-12-01"}}])

          assert_empty @source.parse_discovery(request: api_request, response: api_response(body)).listings
        end

        test "a record whose link does not end in an ISBN-13 is skipped" do
          page_2 = @source.parse_discovery(request: api_request(page: 2), response: api_response(fixture_text("api_page_2.json")))

          refute_includes page_2.listings.map(&:url), "https://www.hachettebookgroup.com/titles/example-author/no-isbn-in-link/"
        end

        test "each listing carries its ISBN and the record's modified time as its signal" do
          result = @source.parse_discovery(request: api_request, response: api_response(fixture_text("api_page_1.json")))

          assert_equal [["9781538792346", "2026-11-16T03:20:20"], ["9780316612593", "2026-11-17T03:03:52"],
            ["9780316000017", "2026-11-16T03:19:20"]], result.listings.map { |l| [l.external_key, l.signal] }
        end

        test "a 403 and a challenge page are blocked; a 500 is unavailable; a 404 is not found" do
          assert_equal :blocked, @source.parse_discovery(request: api_request, response: api_response("", status: 403)).outcome
          assert_equal :unavailable, @source.parse_discovery(request: api_request, response: api_response("", status: 500)).outcome

          assert_equal :blocked, read("synthetic_challenge.html", "k", status: 403).outcome
          assert_equal :blocked, read("synthetic_challenge.html", "k").outcome
          assert_equal :unavailable, read("synthetic_challenge.html", "k", status: 503).outcome
          assert_equal :not_found, read("series_novel.html.gz", "k", status: 404).outcome
        end

        test "a page that is not JSON is unparseable" do
          result = @source.parse_discovery(request: api_request, response: api_response("<html>not json</html>"))
          assert_equal [:unparseable, [], []], [result.outcome, result.listings, result.requests]

          object = @source.parse_discovery(request: api_request, response: api_response('{"a":1}'))
          assert_equal :unparseable, object.outcome
        end

        test "the listing request is a page request waiting for the heading" do
          request = @source.listing_request(ListingRef.new(url: "https://www.hachettebookgroup.com/titles/a/b/9780316564861/", external_key: "9780316564861", signal: nil))

          assert_equal ["page", "https://www.hachettebookgroup.com/titles/a/b/9780316564861/", "h1"],
            [request.kind, request.url, request.wait_for_selector]
        end

        test "the novel reads with title, authors, imprint, genres, pages, description and all four formats" do
          reading = read("novel_four_formats.html.gz", "9780316564861")
          facts = reading.facts

          assert_equal :found, reading.outcome
          assert_equal "The Legend Eternal", facts[:title]
          assert_nil facts[:subtitle]
          assert_equal [{name: "Andrea Stewart", role: "author"}], facts[:contributors]
          assert_equal ["Orbit", "Hachette Book Group", nil], [facts[:imprint_name], facts[:publisher_name], facts[:language]]
          assert_equal %w[Epic Fantasy Fiction], facts[:genres]
          assert_equal "https://www.hachettebookgroup.com/wp-content/uploads/2026/11/9780316564861.jpg", facts[:cover_url]
          assert_equal [Date.new(2026, 11, 17), "9780316564861"], [facts[:on_sale_on], facts[:source_key]]
          assert_includes facts[:description], "Andrea Stewart is one of the best fantasy writers"
          assert_equal [
            ["9780316564861", "hardcover", "Hardcover"],
            ["9780316564885", "ebook", "ebook"],
            ["9781668658772", "audiobook", "Audiobook Download (Unabridged)"],
            ["9780316564878", "paperback", "Trade Paperback"]
          ], formats(reading)

          own, ebook, _audio, paperback = facts[:formats]
          assert_equal [400, 3000, "USD", Date.new(2026, 11, 17)], own.values_at(:pages, :price_cents, :currency, :on_sale_on)
          assert_equal [nil, 1499, nil], ebook.values_at(:pages, :price_cents, :on_sale_on)
          assert_equal 1999, paperback[:price_cents]
        end

        test "the series title carries its series name and its subtitle" do
          series = read("series_novel.html.gz", "9780316129084")
          assert_equal "The Expanse", series.facts[:series_name]
          assert_nil series.facts[:series_position]
          assert_equal %w[Fiction Science\ Fiction Space\ Opera], series.facts[:genres]

          subtitled = read("series_audiobook.html.gz", "9781668666289")
          assert_equal ["The Last Wish", "Introducing the Witcher", nil], subtitled.facts.values_at(:title, :subtitle, :series_name)
          assert_equal [["9781668666289", "audiobook", "Audiobook Download (Unabridged)"]], formats(subtitled).first(1)
        end

        test "a backlist ebook takes its format from the page's label, not from the JSON-LD bookFormat" do
          reading = read("backlist_ebook.html.gz", "9780316134675")

          assert_equal [["9780316134675", "ebook", "ebook"], ["9781478998938", "audiobook", "Audiobook Download (Unabridged)"],
            ["9780316129084", "paperback", "Trade Paperback"]], formats(reading)
          assert_equal Date.new(2011, 6, 15), reading.facts[:on_sale_on]
          assert_equal [Date.new(2011, 6, 15), nil, nil], reading.facts[:formats].map { |f| f[:on_sale_on] }
        end

        test "the box set, the non-book product and the non-English title read as facts the hold rules then hold" do
          box = read("box_set.html.gz", "9781538789940")
          assert_equal :found, box.outcome
          assert_equal [["9781538789940", "other", "General merchandise (Special Edition)"]], formats(box)
          assert_equal [:held, :set], Hold.call(box.facts)

          calendar = read("synthetic_calendar.html", "9780316000024")
          assert_equal [["9780316000024", "other", "Calendar"]], formats(calendar)
          assert_equal [:held, :not_a_book], Hold.call(calendar.facts)

          spanish = read("synthetic_spanish.html", "9780316000031")
          assert_equal "Spanish", spanish.facts[:language]
          assert_equal "Trade Paperback (Spanish Edition)", spanish.facts[:formats].first[:format_label]
          assert_equal [:held, :non_english], Hold.call(spanish.facts)

          novel = read("novel_four_formats.html.gz", "9780316564861")
          assert_equal [:ready, nil], Hold.call(novel.facts)
        end

        test "a qualifier that is not a language edition leaves language nil" do
          {"series_audiobook.html.gz" => "9781668666289", "box_set.html.gz" => "9781538789940",
           "novel_four_formats.html.gz" => "9780316564861", "backlist_ebook.html.gz" => "9780316134675"}.each do |name, isbn|
            assert_nil read(name, isbn).facts[:language], name
          end
          assert_includes read("series_audiobook.html.gz", "9781668666289").facts[:formats].first[:format_label], "(Unabridged)"
          assert_includes read("box_set.html.gz", "9781538789940").facts[:formats].first[:format_label], "(Special Edition)"
        end

        test "an English Edition qualifier reads English and is ready; other edition words are not languages" do
          html = fixture_text("synthetic_spanish.html")
          {"(English Edition)" => "English", "(Large Print Edition)" => nil, "(Media Tie-In Edition)" => nil,
           "(Spanish-language edition)" => "Spanish", "(Klingon Edition)" => nil}.each do |qualifier, language|
            page = PageFetcher::Page.new(url: "u", final_url: "u", status: 200, title: "T | Hachette Book Group",
              html: html.gsub("(Spanish Edition)", qualifier), selector_found: true, elapsed_ms: 1, fetched_at: Time.current)
            reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "k", signal: nil), page: page)

            assert_equal [qualifier, language], [qualifier, reading.facts[:language]]
            assert_equal [:ready, nil], Hold.call(reading.facts) if language == "English"
          end
        end

        test "format words: ebook in any case is an ebook, a notebook is not" do
          html = fixture_text("synthetic_spanish.html")
          {"ebook" => "ebook", "eBook" => "ebook", "E-book" => "ebook", "Notebook" => "other"}.each do |label, format|
            page = PageFetcher::Page.new(url: "u", final_url: "u", status: 200, title: "T | Hachette Book Group",
              html: html.sub("Trade Paperback", label), selector_found: true, elapsed_ms: 1, fetched_at: Time.current)
            reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "k", signal: nil), page: page)

            assert_equal format, reading.facts[:formats].first[:format], label
          end
        end

        test "the site's placeholder cover is not a cover" do
          assert_nil read("non_book_product.html.gz", "9798894145822").facts[:cover_url]
          assert_nil read("series_audiobook.html.gz", "9781668666289").facts[:cover_url]
          assert_match(/9780316564861\.jpg\z/, read("novel_four_formats.html.gz", "9780316564861").facts[:cover_url])
        end

        test "the real non-book product page reads as the site presents it" do
          reading = read("non_book_product.html.gz", "9798894145822")

          assert_equal :found, reading.outcome
          assert_equal "Harry Potter Mini Levitating Nimbus 2000", reading.facts[:title]
          assert_equal [{name: "Running Press", role: "author"}], reading.facts[:contributors]
          assert_equal [["9798894145822", "paperback", "Trade Paperback"]], formats(reading)
        end

        test "a board book with an illustrator reads its format and contributors" do
          reading = read("synthetic_board_book.html", "9780316000017")

          assert_equal [["9780316000017", "board_book", "Board Book"]], formats(reading)
          assert_equal [{name: "Mara Quill", role: "author"}, {name: "Jo Ferris", role: "illustrator"}], reading.facts[:contributors]
          assert_equal ["A Bedtime Book", 899], [reading.facts[:subtitle], reading.facts[:formats].first[:price_cents]]
        end

        test "siblings are the other formats' ISBNs, not the page's own" do
          assert_equal %w[9780316564885 9781668658772 9780316564878], read("novel_four_formats.html.gz", "9780316564861").sibling_keys
          assert_equal %w[9780316134675 9781478998938], read("series_novel.html.gz", "9780316129084").sibling_keys
          assert_equal [], read("synthetic_calendar.html", "9780316000024").sibling_keys
        end

        test "a redesigned Hachette page is unparseable, not blocked" do
          reading = read("synthetic_redesigned.html", "k")

          assert_equal [:unparseable, {}, []], [reading.outcome, reading.facts, reading.sibling_keys]
        end

        test "a Hachette page with a title and no usable ISBN is unparseable" do
          html = fixture_text("series_novel.html.gz").gsub("9780316129084", "not-an-isbn")
          page = PageFetcher::Page.new(url: "u", final_url: "u", status: 200, title: "Leviathan Wakes | Hachette Book Group",
            html: html, selector_found: true, elapsed_ms: 1, fetched_at: Time.current)

          reading = @source.parse_listing(listing: ListingRef.new(url: "u", external_key: "k", signal: nil), page: page)

          assert_equal :unparseable, reading.outcome
        end
      end
    end
  end
end
