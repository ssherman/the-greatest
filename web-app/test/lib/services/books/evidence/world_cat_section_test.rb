require "test_helper"

module Services
  module Books
    module Evidence
      class WorldCatSectionTest < ActiveSupport::TestCase
        class FakeClient
          attr_reader :looked_up, :fetched

          def initialize(lookup:, full: {})
            @lookup = lookup
            @full = full
            @looked_up = []
            @fetched = []
          end

          def lookup(isbns)
            @looked_up.concat(isbns)
            isbns.to_h { |isbn| [isbn, @lookup.fetch(isbn, [])] }
          end

          def record_by_oclc(oclc)
            @fetched << oclc
            @full.fetch(oclc) { raise ::Books::WorldCat::Exceptions::NotFoundError.new("none", 404, "") }
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

        setup do
          @map = ::Books::WorldCat::GenreMap.new("genres" => ["Fiction"], "terms" => {"Fiction" => {"verdict" => "genre", "genre" => "Fiction"}})
          @book = books_books(:war_and_peace)
        end

        test "a verified ISBN is accepted and full records are fetched only for text" do
          ::Identifier.where(identifiable: @book, identifier_type: :books_work_isbn13).update_all(source: ::Identifier.sources[:open_library])
          client = FakeClient.new(lookup: {MATCH => [slim(1, genre: "Fiction"), slim(2, genre: "Fiction")]},
            full: {1 => agreeing(1, summary: "A long novel.", place: "London"), 2 => agreeing(2, summary: "Short.", place: "London")})
          result = WorldCatSection.call(book: @book, client: client, map: @map)
          assert_equal [MATCH], result["isbns_accepted"]
          assert_equal 2, result["records"]
          assert_equal({"Fiction" => 2}, result["genre_terms"])
          assert_equal({"genre:Fiction" => 2}, result["mapped_genres"])
          assert_equal "A long novel.", result["summary"]
          assert_equal ["London"], result["publication_places"]
          assert_equal 2005, result["earliest_year"]
          assert_equal({"eng" => 2}, result["cataloging_languages"])
          assert_equal [1, 2], client.fetched.sort
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
          assert_equal 1, result["records"]
        end

        test "a 504 or a missing full record rejects the ISBN" do
          timeout = Class.new(FakeClient) do
            def record_by_oclc(_oclc) = raise(::Books::WorldCat::Exceptions::ServerError.new("slow", 504))
          end
          client = timeout.new(lookup: {MATCH => [slim(1, genre: "Fiction")]})
          assert_nil WorldCatSection.call(book: @book, client: client, map: @map)

          missing = FakeClient.new(lookup: {MATCH => [slim(1, genre: "Fiction")]})
          assert_nil WorldCatSection.call(book: @book, client: missing, map: @map)
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
