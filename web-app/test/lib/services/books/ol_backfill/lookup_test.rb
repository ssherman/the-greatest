# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class LookupTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # isbn13 9780140447934, Leo Tolstoy
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])
        end

        test "one work behind every identifier, agreeing, is settled by the fast pass" do
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => @work})

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :identifiers, []], [answer.work.key, answer.lookup, answer.duplicates]
          assert_equal "2026-07-31", answer.source_version[:dump_date]
          assert_not client.calls.any? { |call| call.first == :resolve }
        end

        test "identifiers pointing at two works go to /resolve with everything we know" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "656"] => [ol_hit("OL2W", id_type: "goodreads", value: "656")]},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", :resolve], [answer.work.key, answer.lookup]
          resolve_args = client.calls.find { |call| call.first == :resolve }.last
          assert_equal "War and Peace", resolve_args[:title]
          assert_equal ["Leo Tolstoy"], resolve_args[:author_names]
          assert_equal ["9780140447934"], resolve_args[:isbn13]
          assert_equal ["656"], resolve_args[:goodreads_id]
          assert_nil resolve_args[:existing_ol_key]
        end

        test "a fast hit whose work disagrees on the title goes to /resolve" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL9W")]},
            works: {"OL9W" => ol_work("OL9W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])},
            resolution: ol_resolution(verdict: "abstain")
          )

          answer = Lookup.call(book: @book, client: client)

          assert_nil answer.work
          assert_equal :resolve, answer.lookup
        end

        test "an identifier Open Library does not know (404) is no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::NotFoundError.new("no such isbn", 404)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_equal :resolve, Lookup.call(book: @book, client: client).lookup
        end

        test "a book with no identifiers goes straight to /resolve with its stored key as a hint" do
          book = books_books(:crime_and_punishment) # holds OL262758W, no ISBN, no author
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: ol_work("OL262758W", title: "Crime and Punishment")))

          answer = Lookup.call(book: book, client: client)

          assert_equal "OL262758W", client.calls.last.last[:existing_ol_key]
          assert_nil answer.work, "no author, so the check cannot pass"
        end

        test "an accepted work that fails our check is no answer" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: ol_work("OL5W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "an accepted, agreeing work brings its duplicates (minus itself) and redirect sources" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W", "OL1W"], redirect_sources: ["OL0W"]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal [["OL2W"], ["OL0W"]], [answer.duplicates, answer.redirect_sources]
        end

        test "no more than MAX_FAST_LOOKUPS identifier calls" do
          12.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn10, value: "000000000#{i}") }
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain"))

          Lookup.call(book: @book, client: client)

          assert_equal Lookup::MAX_FAST_LOOKUPS, client.calls.count { |call| call.first == :identifier }
        end

        test "any other Open Library error is raised" do
          client = FakeOlClient.new(errors: [::Books::OpenLibrary::Exceptions::ServerError.new("boom", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { Lookup.call(book: @book, client: client) }
        end
      end
    end
  end
end
