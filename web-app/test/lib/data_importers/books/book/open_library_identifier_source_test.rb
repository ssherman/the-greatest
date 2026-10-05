require "test_helper"

module DataImporters
  module Books
    module Book
      class OpenLibraryIdentifierSourceTest < ActiveSupport::TestCase
        setup do
          @holder = books_books(:crime_and_punishment) # holds OL262758W (fixture)
          @client = stub("open_library_client")
        end

        def hit(work_key, redirected_from: [])
          ::Books::OpenLibrary::IdentifierHit.new(work_key: work_key, source: "dump", redirected_from: redirected_from,
            edition_keys: [], id_type: "isbn13", value: "x")
        end

        def query(**attributes)
          ImportQuery.new(title: "Crime and Punishment", **attributes)
        end

        test "a local book holding the work an ISBN maps to becomes a candidate" do
          @client.expects(:identifier).with("isbn13", "9780143058144").returns([hit("OL262758W")])

          candidates = OpenLibraryIdentifierSource.new(query: query(isbn13: ["9780143058144"]), client: @client).call

          assert_equal [@holder], candidates.map(&:record)
          assert_equal [:open_library_identifier], candidates.first.sources
          assert_equal({type: "open_library isbn13", value: "9780143058144"}, candidates.first.evidence[:matched_identifier])
        end

        test "a redirected work key finds the book holding the old key" do
          @client.stubs(:identifier).returns([hit("OL999W", redirected_from: ["OL262758W"])])

          candidates = OpenLibraryIdentifierSource.new(query: query(goodreads_id: ["7144"]), client: @client).call

          assert_equal [@holder], candidates.map(&:record)
        end

        test "an identifier Open Library does not know, or refuses, is no candidate and no failure" do
          @client.stubs(:identifier).with("isbn13", "9780000000002").returns([])
          @client.stubs(:identifier).with("isbn10", "000000000X")
            .raises(::Books::OpenLibrary::Exceptions::ClientError.new("bad", 422))

          source = OpenLibraryIdentifierSource.new(query: query(isbn13: ["9780000000002"], isbn10: ["000000000X"]), client: @client)

          assert_empty source.call
        end

        test "a query with no identifiers asks nothing" do
          @client.expects(:identifier).never

          assert_empty OpenLibraryIdentifierSource.new(query: query, client: @client).call
        end

        test "an outage raises, so the finder records a failed source" do
          @client.stubs(:identifier).raises(::Books::OpenLibrary::Exceptions::NetworkError.new("down"))

          assert_raises(::Books::OpenLibrary::Exceptions::NetworkError) do
            OpenLibraryIdentifierSource.new(query: query(isbn13: ["9780143058144"]), client: @client).call
          end
        end
      end
    end
  end
end
