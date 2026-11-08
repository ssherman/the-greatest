require "test_helper"

module Services
  module Books
    module Evidence
      class WorldCatSectionTest < ActiveSupport::TestCase
        class FakeClient
          attr_reader :looked_up, :fetched, :batches

          def initialize(lookup:, full: {})
            @lookup = lookup
            @full = full
            @looked_up = []
            @fetched = []
            @batches = []
          end

          def records_by_oclc(oclcs)
            @batches << oclcs
            @fetched.concat(oclcs)
            @full.slice(*oclcs)
          end

          def lookup(isbns)
            @looked_up.concat(isbns)
            isbns.to_h { |isbn| [isbn, @lookup.fetch(isbn, [])] }
          end
        end

        MATCH = "9780140447934"
        OTHER = "9780199232765"

        def slim(oclc, genre: nil, subjects: [], year: 2005, language: "eng", merged: [])
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre, "subjects" => subjects, "year" => year,
            "cataloging_language" => language, "merged_oclc" => merged)
        end

        def full(oclc, title:, creator:, summary: nil, place: nil, language: "eng")
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "title" => title, "creator" => creator, "year" => 2005,
            "summary" => summary, "publication_place" => place, "cataloging_language" => language)
        end

        def agreeing(oclc, **opts)
          full(oclc, title: "War and peace", creator: "Tolstoy, Leo, 1828-1910.", **opts)
        end

        def isbn13(body)
          total = body.chars.each_with_index.sum { |digit, index| digit.to_i * (index.even? ? 1 : 3) }
          "#{body}#{(10 - (total % 10)) % 10}"
        end

        setup do
          @map = ::Books::WorldCat::GenreMap.new("genres" => ["Fiction"], "terms" => {"Fiction" => {"verdict" => "genre", "genre" => "Fiction"}})
          @book = books_books(:war_and_peace)
        end

        test "a book with no usable ISBN-13 never loads the genre map" do
          ::Identifier.where(identifiable: @book, identifier_type: [:books_work_isbn13, :books_work_isbn10]).delete_all
          ::Books::WorldCat::GenreMap.expects(:load).never

          assert_nil WorldCatSection.call(book: @book, client: FakeClient.new(lookup: {}))
        end

        test "a verified ISBN is accepted without an identity check, even when its full record disagrees" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          client = FakeClient.new(lookup: {MATCH => [slim(1, genre: "Fiction"), slim(2, genre: "Fiction")]},
            full: {1 => full(1, title: "Leaves of Grass", creator: "Whitman, Walt, 1819-1892.", summary: "Poems.", place: "Paris", language: "fre"),
                   2 => agreeing(2, summary: "A long novel.", place: "London")})
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [MATCH], result["isbns_accepted"]
          assert_empty result["isbns_rejected"]
          assert_equal 2, result["records"]
          assert_equal({"Fiction" => 2}, result["genre_terms"])
          assert_equal({"genre:Fiction" => 2}, result["mapped_genres"])
          # Verified records are trusted, so every accepted full record is a text record.
          assert_equal "A long novel.", result["summary"]
          assert_equal %w[Paris London], result["publication_places"]
          assert_equal 2005, result["earliest_year"]
          assert_equal({"eng" => 2}, result["cataloging_languages"])
        end

        test "a verified ISBN's non-English full record gives places but not the summary" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          client = FakeClient.new(lookup: {MATCH => [slim(1)]}, full: {1 => agreeing(1, summary: "Un roman.", place: "Paris", language: "fre")})
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_nil result["summary"]
          assert_equal ["Paris"], result["publication_places"]
        end

        test "an unverified ISBN whose record names another book is rejected and its genres are dropped" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: OTHER)
          client = FakeClient.new(
            lookup: {MATCH => [slim(1, genre: "Fiction")], OTHER => [slim(9, genre: "Poetry")]},
            full: {1 => agreeing(1), 9 => full(9, title: "Leaves of Grass", creator: "Whitman, Walt, 1819-1892.")}
          )
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [MATCH], result["isbns_accepted"]
          assert_equal [OTHER], result["isbns_rejected"]
          assert_equal({"Fiction" => 1}, result["genre_terms"])
        end

        test "an unverified ISBN whose full record agrees is accepted" do
          client = FakeClient.new(lookup: {MATCH => [slim(1, genre: "Fiction")]}, full: {1 => agreeing(1)})
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [MATCH], result["isbns_accepted"]
          assert_empty result["isbns_rejected"]
          assert_empty result["isbns_unchecked"]
          assert_equal 1, result["records"]
        end

        test "a 504 on the identity fetch rejects the ISBN" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: OTHER)
          timeout = Class.new(FakeClient) do
            def records_by_oclc(oclcs)
              oclcs.include?(9) ? raise(::Books::WorldCat::Exceptions::ServerError.new("slow", 504)) : super
            end
          end
          client = timeout.new(lookup: {MATCH => [slim(1)], OTHER => [slim(9, genre: "Poetry")]}, full: {1 => agreeing(1)})
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [MATCH], result["isbns_accepted"]
          assert_equal [OTHER], result["isbns_rejected"]
        end

        test "an unknown OCLC number (nil full record) rejects the ISBN" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: OTHER)
          client = FakeClient.new(lookup: {MATCH => [slim(1)], OTHER => [slim(9, genre: "Poetry")]}, full: {1 => agreeing(1)})
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [OTHER], result["isbns_rejected"]
          assert_equal({}, result["genre_terms"])
        end

        test "only five unverified ISBNs are identity-checked, most records first, ties in ISBN order" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).delete_all
          isbns = (0..6).map { |n| isbn13("97800000000#{n}") }
          isbns.each { |isbn| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: isbn) }
          lookup = isbns.each_with_index.to_h { |isbn, n| [isbn, [slim(100 + n)]] }
          lookup[isbns[6]] = [slim(106), slim(206)]
          fulls = (0..6).to_h { |n| [100 + n, agreeing(100 + n)] }
          client = FakeClient.new(lookup: lookup, full: fulls)
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          # 106 has two records so goes first; then the earliest four. Text fetches add up to three more.
          assert_equal [106, 100, 101, 102, 103], client.fetched.first(5)
          assert_equal [isbns[6], isbns[0], isbns[1], isbns[2], isbns[3]], result["isbns_accepted"]
          assert_equal [isbns[4], isbns[5]], result["isbns_unchecked"]
          assert_empty result["isbns_rejected"]
        end

        test "the identity checks are made in a single batch call" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).delete_all
          isbns = (0..2).map { |n| isbn13("97800000000#{n}") }
          isbns.each { |isbn| ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: isbn) }
          lookup = isbns.each_with_index.to_h { |isbn, n| [isbn, [slim(100 + n)]] }
          client = FakeClient.new(lookup: lookup, full: (0..2).to_h { |n| [100 + n, agreeing(100 + n)] })
          WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [100, 101, 102], client.batches.first
        end

        test "at most three extra full records are fetched for text" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          records = (1..8).map { |n| slim(n) }
          client = FakeClient.new(lookup: {MATCH => records}, full: (1..8).to_h { |n| [n, agreeing(n, summary: "s#{n}")] })
          WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [1, 2, 3], client.fetched
        end

        test "the summary is cut to 1,500 characters" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          client = FakeClient.new(lookup: {MATCH => [slim(1)]}, full: {1 => agreeing(1, summary: "x" * 2_000)})
          assert_equal 1_500, WorldCatSection.call(book: @book, client: client, map: @map)["summary"].length
        end

        test "an ISBN with a bad check digit is never sent to lookup" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780140447935")
          client = FakeClient.new(lookup: {MATCH => [slim(1)]}, full: {1 => agreeing(1)})
          WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [MATCH], client.looked_up
        end

        test "subjects keep the full subdivided heading and are capped at 40" do
          heading = "World War, 1939-1945 -- France -- Paris -- Fiction"
          extra = (1..45).map { |n| "Heading #{n}" }
          client = FakeClient.new(lookup: {MATCH => [slim(1, subjects: [heading, *extra]), slim(2, subjects: [heading])]},
            full: {1 => agreeing(1), 2 => agreeing(2)})
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal 40, result["subjects"].size
          assert_equal 2, result["subjects"][heading]
        end

        test "merged duplicates count once" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          client = FakeClient.new(lookup: {MATCH => [slim(1, merged: [2]), slim(2)]}, full: {1 => agreeing(1)})
          assert_equal 1, WorldCatSection.call(book: @book, client: client, map: @map)["records"]
        end

        test "no records gives nil" do
          assert_nil WorldCatSection.call(book: @book, client: FakeClient.new(lookup: {}), map: @map)
        end

        test "no ISBNs gives nil without a lookup" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).delete_all
          client = FakeClient.new(lookup: {})
          assert_nil WorldCatSection.call(book: @book, client: client, map: @map)
          assert_empty client.looked_up
        end
      end
    end
  end
end
