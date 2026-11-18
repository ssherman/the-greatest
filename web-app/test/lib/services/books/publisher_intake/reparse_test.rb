# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class ReparseTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        Reading = ::Books::PublisherIntake::Reading
        HTML = "<html><body>stored page é</body></html>"

        setup do
          setup_intake_fetching
          @attempted_at = 2.days.ago.change(usec: 0)
          @version = PublisherIntakeFetchHelper::TestStrategy::VERSION
        end

        teardown { teardown_intake_fetching }

        def facts
          {title: "A Fine Book", contributors: [{name: "Ada Example", role: "author"}], language: "English", genres: ["Fiction"],
           formats: [{isbn13: "9780802169990", format: :hardcover, format_label: "Hardcover", on_sale_on: "2027-03-02", pages: 300,
                      price_cents: 2800, currency: "USD"}]}
        end

        def parse_as(outcome, facts: nil)
          PublisherIntakeFetchHelper::TestStrategy.listing_reading = Reading.new(outcome: outcome, facts: facts, sibling_keys: [])
        end

        # A listing that was fetched and stored with its page, as an
        # unparseable one: still pending and never read.
        def stored_listing(version: @version - 1, state: :pending)
          listing = new_pending_listing(state: state)
          StoreReading.call(listing: listing, reading: Reading.new(outcome: :unparseable, facts: nil, sibling_keys: []),
            page: page_response(html: HTML), parser_version: version)
          listing.reload.update!(last_attempt_at: @attempted_at, queued_at: nil)
          listing.reload
        end

        test "an unparseable listing whose stored page now parses becomes read with a title" do
          listing = stored_listing
          parse_as(:found, facts: facts)

          result = Reparse.call(listing: listing)

          listing.reload
          assert result.data[:changed]
          assert listing.state_read?
          assert listing.outcome_found?
          assert_equal @version, listing.parser_version
          assert_equal "A Fine Book", listing.publisher_title.title
          assert_equal listing.last_attempt_at, listing.read_at
          assert_equal HTML, PublisherIntakeFetchHelper::TestStrategy.seen[:page].html
        end

        test "a read listing's facts are refreshed and its stored page, read_at and last attempt are unchanged" do
          listing = stored_listing
          parse_as(:found, facts: facts)
          Reparse.call(listing: listing)
          read_at = 5.days.ago.change(usec: 0)
          listing.reload.update!(parser_version: @version - 1, read_at: read_at, last_attempt_outcome: :found)
          blob_id = listing.html.blob.id
          parse_as(:found, facts: facts.merge(title: "Corrected Title"))

          result = Reparse.call(listing: listing)

          listing.reload
          assert result.data[:changed]
          assert_equal "Corrected Title", listing.publisher_title.title
          assert_equal [read_at, @attempted_at, "found", blob_id, @version],
            [listing.read_at, listing.last_attempt_at, listing.last_attempt_outcome, listing.html.blob.id, listing.parser_version]
        end

        test "a page that still does not parse only gets the new parser version" do
          listing = stored_listing
          parse_as(:unparseable)

          result = Reparse.call(listing: listing)

          listing.reload
          assert_not result.data[:changed]
          assert_equal [@version, "pending", nil, nil], [listing.parser_version, listing.state, listing.read_at, listing.publisher_title]
          assert_equal 0, ::Books::PublisherTitle.where(source: SOURCE).count
        end

        test "a parser that raises is treated as not parsing" do
          listing = stored_listing
          PublisherIntakeFetchHelper::TestStrategy.any_instance.stubs(:parse_listing).raises(NoMethodError, "secret page text")

          assert_not Reparse.call(listing: listing).data[:changed]
          assert_equal @version, listing.reload.parser_version
        end

        test "a current listing, and a listing with no stored page, are left alone" do
          current = stored_listing(version: @version)
          without_page = new_pending_listing
          parse_as(:found, facts: facts)

          assert_not Reparse.call(listing: current).data[:changed]
          assert_not Reparse.call(listing: without_page).data[:changed]
          assert_nil TestStrategy.seen
          assert_equal 0, ::Books::PublisherTitle.where(source: SOURCE).count
        end

        test "nothing is fetched" do
          listing = stored_listing
          parse_as(:found, facts: facts)
          ::Books::PublisherIntake.expects(:client).never

          assert Reparse.call(listing: listing).data[:changed]
        end

        TestStrategy = PublisherIntakeFetchHelper::TestStrategy
      end
    end
  end
end
