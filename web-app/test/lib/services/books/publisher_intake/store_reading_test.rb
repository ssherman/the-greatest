# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class StoreReadingTest < ActiveSupport::TestCase
        Reading = ::Books::PublisherIntake::Reading

        HTML = "<html><body>a page</body></html>"
        ISBN_A = "9780802169990"
        ISBN_B = "9780802170002"
        ISBN_C = "9780802170019"

        def isbn13(stem)
          digits = stem.to_s
          sum = digits.chars.each_with_index.sum { |c, i| c.to_i * (i.even? ? 1 : 3) }
          "#{digits}#{(10 - sum % 10) % 10}"
        end

        def format_for(isbn, label: "Hardcover", date: "2027-03-02")
          {isbn13: isbn, format: :hardcover, format_label: label, on_sale_on: date, pages: 300, price_cents: 2800,
           currency: "USD"}
        end

        def facts(formats: [format_for(ISBN_A)], **overrides)
          {title: "A Fine Book", subtitle: "A Novel", contributors: [{name: "Ada Example", role: "author"}],
           formats: formats, language: "English", genres: ["Fiction"], description: "Short.", publisher_name: "Pub",
           imprint_name: "Imp"}.merge(overrides)
        end

        def found(facts_hash = facts, siblings: [])
          Reading.new(outcome: :found, facts: facts_hash, sibling_keys: siblings)
        end

        def outcome(name) = Reading.new(outcome: name, facts: nil, sibling_keys: [])

        def fetched(html = HTML, status: 200)
          PageFetcher::Page.new(url: "https://x.test/", final_url: "https://x.test/", status: status, title: "T",
            html: html, selector_found: true, elapsed_ms: 10, fetched_at: Time.current)
        end

        def new_listing(key: ISBN_A, state: :pending, source: "hachette_us", **attrs)
          ::Books::PublisherListing.create!(source: source, url: "https://x.test/#{source}/#{key}/#{SecureRandom.hex(3)}",
            external_key: key, state: state, first_seen_at: Time.current, last_seen_at: Time.current,
            queued_at: Time.current, **attrs)
        end

        def store(listing, reading, page: fetched, parser_version: 2)
          StoreReading.call(listing: listing, reading: reading, page: page, parser_version: parser_version)
        end

        # A listing as a re-read finds it: read before, then put back to pending
        # by discovery or the daily job.
        def reread_listing(**attrs)
          listing = new_listing(**attrs)
          store(listing, found)
          listing.reload.update!(state: :pending, read_at: 2.days.ago, queued_at: Time.current)
          listing
        end

        def snapshot(listing)
          listing.reload
          {checksum: listing.html.blob.checksum, title: listing.publisher_title.attributes,
           listing: listing.attributes.slice("outcome", "http_status", "parser_version", "read_at", "attempts", "publisher_title_id")}
        end

        def stored_html(listing)
          Zlib.gunzip(listing.reload.html.download)
        end

        test "a found reading makes a title with its formats, earliest on-sale date and hold status" do
          listing = new_listing
          formats = [format_for(ISBN_A, date: "2027-05-01"), format_for(ISBN_B, label: "eBook", date: "2027-03-02")]

          result = store(listing, found(facts(formats: formats, source_key: "wk-1")))

          assert result.success?
          assert_equal :found, result.data[:outcome]
          title = result.data[:title]
          assert title.persisted?
          assert_equal "hachette_us", title.source
          assert_equal "wk-1", title.source_key
          assert_equal [ISBN_A, ISBN_B].sort, title.isbn13s.sort
          assert_equal Date.new(2027, 3, 2), title.on_sale_on
          assert_equal "A Fine Book", title.title
          assert_equal [ISBN_A, ISBN_B], title.formats.map { |f| f["isbn13"] }
          assert_equal "2027-05-01", title.formats.first["on_sale_on"]
          assert_equal [{"name" => "Ada Example", "role" => "author"}], title.contributors
          assert_equal ["Fiction"], title.genres
          assert title.status_ready?
          assert_nil title.hold_reason
          assert_equal 2, title.parser_version
          assert_not_nil title.first_read_at
          assert_not_nil title.last_read_at

          listing.reload
          assert listing.state_read?
          assert listing.outcome_found?
          assert listing.last_attempt_found?
          assert_equal [200, 2, 0], [listing.http_status, listing.parser_version, listing.attempts]
          assert_not_nil listing.read_at
          assert_not_nil listing.last_attempt_at
          assert_nil listing.queued_at
          assert_equal title, listing.publisher_title
        end

        test "a held classification is stored on the title" do
          result = store(new_listing, found(facts(contributors: [])))

          assert result.data[:title].status_held?
          assert result.data[:title].hold_reason_incomplete?
        end

        test "the earliest on-sale date falls back to the facts date, then to nil" do
          formats = [format_for(ISBN_A, date: nil)]
          result = store(new_listing, found(facts(formats: formats, on_sale_on: Date.new(2027, 1, 5))))
          assert_equal Date.new(2027, 1, 5), result.data[:title].on_sale_on

          other = [format_for(ISBN_B, date: nil)]
          result = store(new_listing(key: ISBN_B), found(facts(formats: other)))
          assert_nil result.data[:title].on_sale_on
        end

        test "a second listing of the same title lands on the same title by ISBN overlap" do
          a = new_listing(key: ISBN_A)
          b = new_listing(key: ISBN_B)
          both = [format_for(ISBN_A), format_for(ISBN_B, label: "eBook")]

          store(a, found(facts(formats: both), siblings: [ISBN_B]))
          # a covered B; make it pending again as if it had been queued before A was read
          b.reload.update!(state: :pending)
          assert_no_difference -> { ::Books::PublisherTitle.count } do
            store(b, found(facts(formats: [format_for(ISBN_B, label: "eBook"), format_for(ISBN_C, label: "Audio")])))
          end

          assert_equal a.reload.publisher_title, b.reload.publisher_title
          assert_equal [ISBN_A, ISBN_B, ISBN_C].sort, b.publisher_title.isbn13s.sort
        end

        test "a re-read replaces facts and unions isbns" do
          listing = new_listing
          first = store(listing, found(facts)).data[:title]
          first_read = first.first_read_at

          travel 1.day do
            second = store(listing.reload, found(facts(title: "Renamed", formats: [format_for(ISBN_A), format_for(ISBN_B)]))).data[:title]
            assert_equal first, second
            assert_equal "Renamed", second.title
            assert_equal [ISBN_A, ISBN_B].sort, second.isbn13s.sort
            assert_equal first_read.to_i, second.first_read_at.to_i
            assert_operator second.last_read_at, :>, first_read
          end
        end

        test "siblings that are baseline or pending become covered, a read sibling is left alone" do
          listing = new_listing(key: ISBN_A)
          pending = new_listing(key: ISBN_B)
          baseline = new_listing(key: ISBN_C, state: :baseline)
          read_sibling = new_listing(key: isbn13("978080217002"), state: :read)
          other_source = new_listing(key: ISBN_B, source: "macmillan_us")
          formats = [ISBN_A, ISBN_B, ISBN_C, read_sibling.external_key].map { |i| format_for(i) }

          title = store(listing, found(facts(formats: formats), siblings: [ISBN_B, "978-0-8021-7001-9", read_sibling.external_key])).data[:title]

          assert pending.reload.state_covered?
          assert baseline.reload.state_covered?
          assert_equal title, pending.publisher_title
          assert_equal title, baseline.publisher_title
          assert read_sibling.reload.state_read?
          assert_nil read_sibling.publisher_title
          assert other_source.reload.state_pending?
          assert listing.reload.state_read?
        end

        test "a source key beats ISBN overlap when both are present" do
          by_isbn = ::Books::PublisherTitle.create!(source: "hachette_us", isbn13s: [ISBN_A], title: "Old")
          by_key = ::Books::PublisherTitle.create!(source: "hachette_us", source_key: "wk-9", isbn13s: [ISBN_C], title: "Key")

          title = store(new_listing, found(facts(source_key: "wk-9"))).data[:title]

          assert_equal by_key, title
          assert_equal [ISBN_A, ISBN_C].sort, title.isbn13s.sort
          assert_equal [ISBN_A], by_isbn.reload.isbn13s
        end

        test "a new source key makes a new title even when isbns overlap another" do
          ::Books::PublisherTitle.create!(source: "hachette_us", source_key: "wk-1", isbn13s: [ISBN_A], title: "Old")

          assert_difference -> { ::Books::PublisherTitle.count }, 1 do
            store(new_listing, found(facts(source_key: "wk-2")))
          end
        end

        test "titles of another source are never matched" do
          ::Books::PublisherTitle.create!(source: "macmillan_us", isbn13s: [ISBN_A], title: "Other")

          assert_difference -> { ::Books::PublisherTitle.count }, 1 do
            store(new_listing, found(facts))
          end
        end

        test "two overlapping titles: the one sharing more ISBNs wins and a warning names both" do
          one = ::Books::PublisherTitle.create!(source: "hachette_us", isbn13s: [ISBN_A], title: "One")
          two = ::Books::PublisherTitle.create!(source: "hachette_us", isbn13s: [ISBN_B, ISBN_C], title: "Two")
          Rails.logger.expects(:warn).with { |m| m.to_s.include?(one.id.to_s) && m.to_s.include?(two.id.to_s) }.once
          Rails.logger.stubs(:warn).with { |m| !(m.to_s.include?(one.id.to_s) && m.to_s.include?(two.id.to_s)) }

          formats = [ISBN_A, ISBN_B, ISBN_C].map { |i| format_for(i) }
          title = store(new_listing, found(facts(formats: formats))).data[:title]

          assert_equal two, title
        end

        test "on a tie the lower id wins" do
          one = ::Books::PublisherTitle.create!(source: "hachette_us", isbn13s: [ISBN_A], title: "One")
          ::Books::PublisherTitle.create!(source: "hachette_us", isbn13s: [ISBN_B], title: "Two")
          Rails.logger.stubs(:warn)

          title = store(new_listing, found(facts(formats: [ISBN_A, ISBN_B].map { |i| format_for(i) }))).data[:title]

          assert_equal one, title
        end

        test "ISBNs are normalised; an invalid one drops its format; none left is unparseable" do
          listing = new_listing
          formats = [format_for("978-0-8021-6999-0"), format_for("0802169996", label: "Paperback"),
            format_for("9780802169991", label: "Bad")]

          title = store(listing, found(facts(formats: formats))).data[:title]

          assert_equal ["9780802169990"], title.isbn13s
          assert_equal ["9780802169990"], title.formats.map { |f| f["isbn13"] }.uniq

          bad = new_listing(key: "x")
          assert_no_difference -> { ::Books::PublisherTitle.count } do
            result = store(bad, found(facts(formats: [format_for("9780802169991"), format_for("nope")])))
            assert_equal :unparseable, result.data[:outcome]
            assert_nil result.data[:title]
          end
          bad.reload
          assert bad.state_pending?
          assert bad.outcome_unparseable?
          assert_equal HTML, stored_html(bad)
        end

        test "a reading with a blank title is unparseable" do
          listing = new_listing
          result = store(listing, found(facts(title: " ")))

          assert_equal :unparseable, result.data[:outcome]
          assert listing.reload.outcome_unparseable?
        end

        test "a re-read downgraded to unparseable keeps the stored page and facts and returns to read" do
          [facts(title: ""), facts(formats: [format_for("9780802169991"), format_for("nope")])].each do |bad|
            listing = reread_listing(key: SecureRandom.hex(4))
            before = snapshot(listing)

            result = store(listing, found(bad), page: fetched("<p>other</p>"), parser_version: 9)

            assert_equal :unparseable, result.data[:outcome]
            assert listing.reload.state_read?
            assert listing.last_attempt_unparseable?
            assert_nil listing.queued_at
            assert_equal before, snapshot(listing)
          end
        end

        test "a found reading with no page keeps the stored attachment" do
          listing = new_listing
          store(listing, found)
          checksum = listing.reload.html.blob.checksum

          store(listing, found(facts(title: "Again")), page: nil)

          assert_equal checksum, listing.reload.html.blob.checksum
          assert_equal "Again", listing.publisher_title.title
        end

        test "not_found fails the listing and leaves page and title alone" do
          listing = reread_listing
          before = snapshot(listing)

          result = store(listing, outcome(:not_found), page: fetched("<p>404</p>", status: 404))

          assert_equal :not_found, result.data[:outcome]
          listing.reload
          assert listing.state_failed?
          assert listing.outcome_not_found?
          assert listing.last_attempt_not_found?
          assert_nil listing.queued_at
          after = snapshot(listing)
          assert_equal [before[:checksum], before[:title]], [after[:checksum], after[:title]]
        end

        test "not_found on a never-read listing stores no page" do
          listing = new_listing
          store(listing, outcome(:not_found), page: fetched("<p>404</p>", status: 404))

          assert listing.reload.state_failed?
          assert_not listing.html.attached?
        end

        test "a blocked or unparseable reading of a pending listing stays pending and stores the page" do
          %i[blocked unparseable].each do |name|
            listing = new_listing(key: name.to_s)
            store(listing, outcome(name), page: fetched("<p>#{name}</p>", status: 403))

            listing.reload
            assert listing.state_pending?, name
            assert_equal name.to_s, listing.outcome
            assert_equal name.to_s, listing.last_attempt_outcome
            assert_equal "<p>#{name}</p>", stored_html(listing)
            assert_nil listing.queued_at
          end
        end

        test "a blocked or unparseable re-read keeps the stored page, outcome, facts and title and returns to read" do
          listing = reread_listing
          before = snapshot(listing)

          %i[blocked unparseable].each do |name|
            listing.update!(state: :pending, queued_at: Time.current)
            store(listing, outcome(name), page: fetched("<p>bad</p>", status: 403), parser_version: 9)

            assert listing.reload.state_read?, name
            assert_equal name.to_s, listing.last_attempt_outcome
            assert_nil listing.queued_at
            assert_equal before, snapshot(listing)
            assert listing.outcome_found?
          end
        end

        test "unavailable on an unread listing counts attempts and fails on the last" do
          listing = new_listing
          limit = ::Books::PublisherIntake.settings.fetch_attempts
          (limit - 1).times do |i|
            store(listing, outcome(:unavailable), page: nil)
            listing.reload
            assert listing.state_pending?
            assert_equal i + 1, listing.attempts
            assert listing.last_attempt_unavailable?
            assert_nil listing.queued_at
            assert_nil listing.outcome
          end

          store(listing, outcome(:unavailable), page: nil)

          assert listing.reload.state_failed?
          assert_equal limit, listing.attempts
          assert_not listing.html.attached?
        end

        test "any other outcome resets attempts" do
          listing = new_listing(attempts: 2)
          store(listing, outcome(:blocked), page: fetched("<p>b</p>", status: 403))
          assert_equal 0, listing.reload.attempts

          listing.update!(attempts: 2)
          store(listing, found)
          assert_equal 0, listing.reload.attempts
        end

        test "an unavailable re-read returns to read with attempts and everything else unchanged" do
          listing = reread_listing
          listing.update!(attempts: 1)
          before = snapshot(listing)

          store(listing, outcome(:unavailable), page: nil)

          assert listing.reload.state_read?
          assert listing.last_attempt_unavailable?
          assert_nil listing.queued_at
          assert_equal before, snapshot(listing)
        end

        test "fetcher_down leaves a re-read listing pending" do
          listing = reread_listing
          store(listing, outcome(:fetcher_down), page: nil)

          assert listing.reload.state_pending?
          assert listing.last_attempt_fetcher_down?
          assert_nil listing.queued_at
        end

        test "fetcher_down records the attempt and leaves the listing pending" do
          listing = new_listing(attempts: 1)
          store(listing, outcome(:fetcher_down), page: nil)

          listing.reload
          assert listing.state_pending?
          assert listing.last_attempt_fetcher_down?
          assert_equal 1, listing.attempts
          assert_nil listing.queued_at
        end

        test "the stored page is gzipped HTML on the private imports service" do
          listing = new_listing
          store(listing, found)
          listing.reload

          assert listing.html.attached?
          assert_equal "private_imports", listing.html.blob.service_name
          assert_equal "application/gzip", listing.html.blob.content_type
          assert_equal "hachette_us-#{listing.id}.html.gz", listing.html.filename.to_s
          assert_equal HTML, stored_html(listing)
        end

        test "a later good page replaces the stored page" do
          listing = new_listing
          store(listing, found)
          store(listing.reload, found, page: fetched("<p>newer</p>"))

          assert_equal "<p>newer</p>", stored_html(listing)
        end

        test "nothing is written to books, editions, authors or identifiers" do
          listing = new_listing
          assert_no_difference [-> { ::Books::Book.count }, -> { ::Books::Edition.count }, -> { ::Books::Author.count }, -> { ::Identifier.count }] do
            store(listing, found(siblings: [ISBN_B]))
          end
        end

        test "the page html never reaches the log or an error" do
          Rails.logger.stubs(:warn)
          Rails.logger.expects(:warn).with { |m| m.to_s.include?("a page") }.never
          result = store(new_listing, found)

          assert_empty Array(result.errors).grep(/a page/)
        end
      end
    end
  end
end
