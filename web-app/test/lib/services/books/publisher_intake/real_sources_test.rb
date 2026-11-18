# frozen_string_literal: true

require "test_helper"
require "zlib"

module Services
  module Books
    module PublisherIntake
      # Runs each real strategy, on a committed real page, through ReadListing and
      # Reparse. The other service tests use a throwaway strategy, so nothing else
      # would notice a service handing a strategy a page it cannot read (the
      # page's own <title> is part of what a strategy checks).
      class RealSourcesTest < ActiveSupport::TestCase
        CASES = {
          "hachette_us" => {file: "hachette_us/novel_four_formats.html.gz", key: "9780316564861", title: "The Legend Eternal",
                            isbns: %w[9780316564861 9780316564885 9781668658772 9780316564878]},
          "macmillan_us" => {file: "macmillan_us/novel_three_formats.html.gz", key: "9781250369550", title: "Nightcurse",
                             isbns: %w[9781250369550 9781250369567 9781250472359]},
          "penguin_random_house_us" => {file: "penguin_random_house_us/novel_four_formats.html.gz", key: "743565",
                                        title: "The Collateral Heart", isbns: nil}
        }.freeze

        setup do
          @original_enabled = ::Books::PublisherIntake.settings.enabled_sources
          ::Books::PublisherIntake.settings.enabled_sources = CASES.keys
          fresh_gate
          @client = mock("page fetcher client")
          ::Books::PublisherIntake.stubs(:client).returns(@client)
        end

        teardown { ::Books::PublisherIntake.settings.enabled_sources = @original_enabled }

        def fresh_gate
          config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 10, daily_fetch_cap: 100, block_cooldown: 6.hours.to_i)
          gate = ::Books::FetchGate.new(key: "real:gate", config: config, label: "real", redis: ::Books::OpenLibrary::FakeRedis.new)
          ::Books::PublisherIntake.stubs(:gate_for).returns(gate)
        end

        def html_of(spec)
          Zlib.gunzip(file_fixture("publisher_intake/#{spec[:file]}").binread).force_encoding(Encoding::UTF_8)
        end

        def page_of(html, url)
          PageFetcher::Page.new(url: url, final_url: url, status: 200, title: html[%r{<title>(.*?)</title>}m, 1], html: html,
            selector_found: true, elapsed_ms: 1, fetched_at: Time.current)
        end

        def new_listing(source, spec, url: "https://x.test/#{source}/#{SecureRandom.hex(3)}", **attrs)
          ::Books::PublisherListing.create!(source: source, url: url, external_key: spec[:key], state: :pending,
            first_seen_at: Time.current, last_seen_at: Time.current, **attrs)
        end

        def strategy(source) = ::Books::PublisherIntake::Sources.fetch(source)

        CASES.each do |source, spec|
          test "#{source}: reads a real page into a title" do
            listing = new_listing(source, spec)
            @client.expects(:fetch).returns(page_of(html_of(spec), listing.url))

            ReadListing.call(listing: listing, due: true)

            listing.reload
            title = listing.publisher_title
            assert listing.state_read?, "state was #{listing.state}, outcome #{listing.last_attempt_outcome}"
            assert_equal spec[:title], title.title
            assert_operator title.contributors.size, :>=, 1
            assert_equal spec[:isbns].sort, title.isbn13s.sort if spec[:isbns]
            assert_operator title.isbn13s.size, :>=, 1
            assert(title.isbn13s.all? { |isbn| isbn.match?(/\A97[89]\d{10}\z/) })
          end

          test "#{source}: re-parses its stored page" do
            listing = new_listing(source, spec)
            @client.expects(:fetch).once.returns(page_of(html_of(spec), listing.url))
            ReadListing.call(listing: listing, due: true)
            listing.reload
            facts_before = listing.publisher_title.slice(:title, :isbn13s, :contributors, :formats)
            current = strategy(source).parser_version
            listing.update!(parser_version: current - 1)

            result = Reparse.call(listing: listing)

            listing.reload
            assert result.data[:changed]
            assert listing.state_read?
            assert_equal current, listing.parser_version
            assert_equal facts_before, listing.publisher_title.slice(:title, :isbn13s, :contributors, :formats)
          end

          test "#{source}: promotes an unparseable stored page" do
            listing = new_listing(source, spec, outcome: :unparseable, last_attempt_outcome: :unparseable,
              last_attempt_at: 2.days.ago, parser_version: strategy(source).parser_version - 1)
            html = html_of(spec)
            listing.html.attach(io: StringIO.new(Zlib.gzip(html)), filename: "p.html.gz", content_type: "application/gzip",
              identify: false, metadata: {analyzed: true})
            listing.update!(http_status: 200)
            @client.expects(:fetch).never

            Reparse.call(listing: listing)

            listing.reload
            assert listing.state_read?
            assert_equal spec[:title], listing.publisher_title.title
          end
        end

        test "a second format page of the same work lands on the same title" do
          %w[hachette_us macmillan_us].each do |source|
            spec = CASES[source]
            fresh_gate
            first = new_listing(source, spec)
            second = new_listing(source, spec.merge(key: "9780000000002"))
            @client.stubs(:fetch).returns(page_of(html_of(spec), first.url))

            ReadListing.call(listing: first, due: true)
            after_first = ::Books::PublisherTitle.where(source: source).count
            fresh_gate # the first read took the gate's turn
            ReadListing.call(listing: second, due: true)
            assert_equal after_first, ::Books::PublisherTitle.where(source: source).count, source
            first.reload
            second.reload
            assert_equal first.publisher_title_id, second.publisher_title_id, source
          end
        end
      end
    end
  end
end
