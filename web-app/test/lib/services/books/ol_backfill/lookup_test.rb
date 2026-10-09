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

        test "an identifier the service rejects (422) is no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::ClientError.new("bad isbn", 422)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_equal :resolve, Lookup.call(book: @book, client: client).lookup
        end

        test "an identifier lookup answered 403 is raised, not treated as no hit" do
          client = FakeOlClient.new(
            hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::ClientError.new("forbidden", 403)},
            resolution: ol_resolution(verdict: "accept", work: @work)
          )

          assert_raises(::Books::OpenLibrary::Exceptions::ClientError) { Lookup.call(book: @book, client: client) }
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

        test "the fast pass fetches author records when the names differ, and settles on an alternate name" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Лев Толстой"]])
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => work},
            authors: {"OL1A" => ol_author("OL1A", name: "Лев Толстой", alternate_names: ["Leo Tolstoy"])})

          answer = Lookup.call(book: @book, client: client)

          assert_equal [:identifiers, "OL1W"], [answer.lookup, answer.work.key]
          assert_equal [[:authors_batch, ["OL1A"]]], client.calls.select { |call| call.first == :authors_batch }
        end

        test "no author records are fetched when the plain check passes" do
          client = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => @work})

          Lookup.call(book: @book, client: client)

          assert_not client.calls.any? { |call| call.first == :authors_batch }
        end

        test "an accepted work is checked with its author records too" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Лев Толстой"]])
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: work),
            authors: {"OL1A" => ol_author("OL1A", name: "Лев Толстой", alternate_names: ["Leo Tolstoy"])})

          assert_equal "OL1W", Lookup.call(book: @book, client: client).work.key
        end

        test "at most RESOLVE_IDENTIFIERS_PER_TYPE values of each identifier type go to /resolve" do
          5.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "978000000000#{i}") }
          5.times { |i| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "90#{i}") }
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain"))

          Lookup.call(book: @book, client: client)

          args = client.calls.find { |call| call.first == :resolve }.last
          assert_equal [3, 3], [args[:isbn13].size, args[:goodreads_id].size]
        end

        test "an abstain whose top candidate is the stored key and agrees is confirmed with no changes" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: @work, duplicates: ["OL2W"]))

          answer = Lookup.call(book: @book, client: client)

          assert_equal ["OL1W", true, [], []], [answer.work.key, answer.confirm_only, answer.duplicates, answer.redirect_sources]
        end

        test "an abstain whose top candidate is not the stored key stays unsure" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL9W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: @work))

          answer = Lookup.call(book: @book, client: client)

          assert_nil answer.work
          assert_equal false, answer.confirm_only
        end

        test "an abstain whose top candidate is the stored key but fails the check stays unsure" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_id, value: "OL1W")
          other = ol_work("OL1W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: other))

          assert_nil Lookup.call(book: @book, client: client).work
        end

        test "a confident accept is not a confirm_only answer" do
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work))

          assert_equal false, Lookup.call(book: @book, client: client).confirm_only
        end

        test "any other Open Library error is raised" do
          client = FakeOlClient.new(errors: [::Books::OpenLibrary::Exceptions::ServerError.new("boom", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { Lookup.call(book: @book, client: client) }
        end
      end
    end
  end
end
