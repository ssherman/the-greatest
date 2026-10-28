# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class GatherEvidenceTest < ActiveSupport::TestCase
        setup do
          @world_cat = mock("world_cat")
          @open_library = mock("open_library")
        end

        def edition(isbn13: "9780679731726", isbn10: nil, title: "The Remains of the Day", author: "Kazuo Ishiguro")
          ::Books::GoodreadsEdition.new(id: 1, goodreads_book_id: 28921, signature: "sig-28921", title: title,
            primary_author: author, additional_authors: [], isbn13: isbn13, isbn10: isbn10)
        end

        def record(title, creator, year: 1990)
          ::Books::WorldCat::Record.from_hash("title" => title, "creator" => creator, "year" => year)
        end

        def hit(key) = ::Books::OpenLibrary::IdentifierHit.new(work_key: key, source: nil, redirected_from: [], edition_keys: [],
          id_type: "isbn_13", value: "9780679731726")

        def gather(edition = self.edition) = GatherEvidence.call(edition: edition, world_cat: @world_cat, open_library: @open_library)

        test "an agreeing record and an Open Library work" do
          @world_cat.expects(:record_by_isbn).with("9780679731726").returns([record("The remains of the day /", "Ishiguro, Kazuo")])
          @open_library.expects(:identifier).with("isbn_13", "9780679731726").returns([hit("OL15936W")])

          evidence = gather

          assert_predicate evidence, :agrees?
          assert_equal ["OL15936W"], evidence.ol_work_keys
          assert_equal ["The remains of the day /", "Ishiguro, Kazuo", 1990],
            [evidence.world_cat_title, evidence.world_cat_creator, evidence.world_cat_year]
          assert_equal [28921, "sig-28921", "9780679731726"], [evidence.goodreads_book_id, evidence.signature, evidence.isbn13]
        end

        test "a record for another book disagrees" do
          @world_cat.expects(:record_by_isbn).returns([record("Cooking for one /", "Smith, Jane")])
          @open_library.expects(:identifier).returns([])

          assert_predicate gather, :disagrees?
        end

        test "no record" do
          @world_cat.expects(:record_by_isbn).returns([])
          @open_library.expects(:identifier).returns([])

          evidence = gather
          assert_predicate evidence, :no_record?
          assert_nil evidence.world_cat_title
        end

        test "no ISBN, a bad checksum or text makes no call" do
          @world_cat.expects(:record_by_isbn).never
          @open_library.expects(:identifier).never

          [nil, "9780679731727", "Twelfth Night"].each_with_index do |isbn, index|
            evidence = GatherEvidence.call(edition: edition(isbn13: isbn).tap { |e| e.goodreads_book_id = 100 + index },
              world_cat: @world_cat, open_library: @open_library)

            assert_predicate evidence, :no_isbn?
            assert_equal [], evidence.ol_work_keys
          end
        end

        test "ISBN-10 only is looked up as ISBN-13" do
          @world_cat.expects(:record_by_isbn).with("9780679731726").returns([])
          @open_library.expects(:identifier).with("isbn_13", "9780679731726").returns([])

          gather(edition(isbn13: nil, isbn10: "0679731725"))
        end

        test "a service error writes nothing" do
          @world_cat.expects(:record_by_isbn).raises(::Books::WorldCat::Exceptions::Error, "down")

          assert_raises(::Books::WorldCat::Exceptions::Error) { gather }
          assert_equal 0, ::Books::RebuildEditionEvidence.where(goodreads_book_id: 28921).count
        end

        test "a second call updates the row" do
          @world_cat.stubs(:record_by_isbn).returns([]).then.returns([record("The remains of the day /", "Ishiguro, Kazuo")])
          @open_library.stubs(:identifier).returns([])

          gather
          evidence = gather

          assert_predicate evidence, :agrees?
          assert_equal 1, ::Books::RebuildEditionEvidence.where(goodreads_book_id: 28921).count
        end
      end
    end
  end
end
