require "test_helper"

module Services
  module Books
    module WorldCat
      class VocabularySnapshotTest < ActiveSupport::TestCase
        class FakeClient
          attr_reader :asked

          def initialize(map)
            @map = map
            @asked = []
          end

          def lookup(isbns)
            @asked.concat(isbns)
            isbns.to_h { |i| [i, @map.fetch(i, [])] }
          end
        end

        def record(oclc, genre)
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre)
        end

        setup do
          @dir = Dir.mktmpdir
          ::Identifier.create!(identifiable: books_books(:crime_and_punishment), identifier_type: :books_work_isbn13, value: "9780140449136")
          @client = FakeClient.new(
            "9780140447934" => [record(1, "Fiction"), record(2, "Fiction"), record(3, "Romans")],
            "9780140449136" => [record(4, "Fiction"), record(5, nil)]
          )
        end

        teardown { FileUtils.remove_entry(@dir) }

        test "counts uses and books per term and splits head from tail at the share" do
          result = VocabularySnapshot.call(client: @client, out_dir: @dir, head_share: 0.75)

          assert result.success?
          assert_equal 2, result.data[:books_matched]
          assert_equal({"Fiction" => {uses: 3, books: 2}, "Romans" => {uses: 1, books: 1}}, result.data[:terms])
          assert_equal ["Fiction"], result.data[:head]
          assert_equal ["Romans"], result.data[:tail]
          assert_equal "term,uses,books\nFiction,3,2\n", File.read(File.join(@dir, "genre_terms.csv"))
          assert_equal "term,uses,books\nRomans,1,1\n", File.read(File.join(@dir, "genre_terms_tail.csv"))
        end

        test "a term carried only by a book with one record still counts one book" do
          result = VocabularySnapshot.call(client: @client, out_dir: @dir)
          assert_equal 1, result.data[:terms]["Romans"][:books]
        end

        test "an invalid ISBN never reaches the client, the valid one on the same book still does" do
          ::Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_isbn13, value: "9780000000001")

          result = VocabularySnapshot.call(client: @client, out_dir: @dir)

          assert result.success?
          assert_not_includes @client.asked, "9780000000001"
          assert_includes @client.asked, "9780140447934"
          assert_equal 3, result.data[:terms]["Fiction"][:uses]
        end

        test "a client failure is a failed result, not an exception" do
          client = mock
          client.stubs(:lookup).raises(::Books::WorldCat::Exceptions::ServerError.new("boom", 500))
          result = VocabularySnapshot.call(client: client, out_dir: @dir)
          assert_not result.success?
          assert_match(/boom/, result.errors.first)
        end
      end
    end
  end
end
