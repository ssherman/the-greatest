# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class MixedBooksTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @derived_lump = book(20_101, :lump)
          @trusted_lump = book(20_102, :lump)
          @coherent = book(20_103, :coherent)
          @unsurveyed = book(20_104, nil)
          ListItem.create!(list: lists(:basic_list), listable: @trusted_lump, position: 1)
        end

        test "ids holds derived lumps only" do
          ids = MixedBooks.ids

          assert_kind_of Set, ids
          assert_includes ids, @derived_lump.id
          refute_includes ids, @trusted_lump.id
          refute_includes ids, @coherent.id
          refute_includes ids, @unsurveyed.id
        end

        test "archive stores everything on the book and its row keys" do
          ::Identifier.create!(identifiable: @derived_lump, identifier_type: :books_work_goodreads_id, value: "55", source: :goodreads_import)
          edition = ::Books::Edition.create!(book: @derived_lump, title: "An Edition")
          ::Identifier.create!(identifiable: edition, identifier_type: :books_edition_isbn13, value: "9780000000002")
          list = ::Books::UserList.create!(user: @user, name: "Shelf", list_type: :custom)
          item = UserListItem.create!(user_list: list, listable: @derived_lump, completed_on: Date.new(2020, 1, 2))
          review = Review.create!(user: @user, reviewable: @derived_lump, rating: 4.5, title: "T", body: "B")
          link = ExternalLink.create!(parent: @derived_lump, name: "Shop", url: "https://example.com/x")
          ExternalLink.create!(parent: edition, name: "Ed", url: "https://example.com/e", source: :amazon)
          category = ::Books::Category.create!(name: "Archived Cat")
          CategoryItem.create!(category: category, item: @derived_lump, source: :admin)
          second = ::Books::Author.create!(name: "Second")
          first = ::Books::Author.create!(name: "First")
          ::Books::BookAuthor.create!(book: @derived_lump, author: second, position: 2)
          ::Books::BookAuthor.create!(book: @derived_lump, author: first, position: 1)
          import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, legacy_import_id: 91)
          matched = ::Books::GoodreadsEdition.create!(goodreads_book_id: 88_001, signature: "mb-sig", title: "T", primary_author: "A")
          import.rows.create!(row_number: 7, legacy_book_id: @derived_lump.id, goodreads_edition: matched)
          import.rows.create!(row_number: 8, legacy_book_id: 999_999, goodreads_edition: matched)
          # A row with no edition is never decided, so DecideGuesses would wait for it forever.
          import.rows.create!(row_number: 9, legacy_book_id: @derived_lump.id)
          member = ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :member, status: :complete)
          member.rows.create!(row_number: 1, legacy_book_id: @derived_lump.id)

          verdict = MixedBooks.archive(@derived_lump, legacy_map: GoodreadsRebuild::LegacyBookMap.new(@derived_lump.id => [999_999]))
          payload = verdict.payload
          archive = payload["archive"]

          assert_equal "reimport:book:#{@derived_lump.id}", verdict.subject_key
          assert_predicate verdict, :reimport_mixed?
          assert_predicate verdict, :approved?
          assert_equal [@derived_lump.id, "Book 20101"], payload.values_at("book_id", "title")
          assert_equal [["books_work_goodreads_id", "55", "goodreads_import"]], archive["identifiers"]
          assert_equal [edition.id], archive["editions"].map { |e| e["id"] }
          assert_equal [["books_edition_isbn13", "9780000000002", nil]], archive["editions"].first["identifiers"]
          assert_equal [[list.id, @user.id, item.position, "2020-01-02", item.created_at.as_json]], archive["list_items"]
          assert_equal [[@user.id, review.rating.to_s, "T", "B", review.created_at.as_json]], archive["reviews"]
          assert_equal [link.id], archive["external_links"].map { |l| l["id"] }
          assert_equal [], archive["images"]
          assert_equal [[import.id, 7], [import.id, 8]], payload["row_keys"]
          assert_equal %w[First Second], payload["author_names"]
          assert_equal [[category.id, "admin"]], archive["category_items"]
          assert_equal [["https://example.com/e", "amazon"]], archive["editions"].first["external_links"]
          assert_equal [], archive["editions"].first["images"]
        end

        test "archive keeps each image's attributes and its blob's identity, for the book and its editions" do
          edition = ::Books::Edition.create!(book: @derived_lump, title: "An Edition")
          book_image = attach_image(@derived_lump, "cover.jpg", primary: true)
          edition_image = attach_image(edition, "ed.jpg")

          archive = MixedBooks.archive(@derived_lump, legacy_map: GoodreadsRebuild::LegacyBookMap.new({})).payload["archive"]

          blob = book_image.file.blob
          assert_equal [{"id" => book_image.id, "primary" => true, "notes" => "n", "metadata" => book_image.metadata,
                         "parent_type" => "Books::Book", "parent_id" => @derived_lump.id, "created_at" => book_image.created_at.as_json,
                         "blob" => {"id" => blob.id, "key" => blob.key, "filename" => "cover.jpg", "content_type" => "image/jpeg",
                                    "checksum" => blob.checksum, "byte_size" => blob.byte_size}}], archive["images"]
          assert_equal [edition_image.id], archive["editions"].first["images"].map { |i| i["id"] }
          assert_equal edition_image.file.blob.key, archive["editions"].first["images"].first.dig("blob", "key")
        end

        def attach_image(parent, filename, primary: false)
          image = Image.new(parent: parent, primary: primary, notes: "n")
          image.file.attach(io: StringIO.new("fake image data #{filename}"), filename: filename, content_type: "image/jpeg")
          image.save!
          image
        end

        test "archive twice keeps the first snapshot" do
          author = ::Books::Author.create!(name: "Original")
          ::Books::BookAuthor.create!(book: @derived_lump, author: author, position: 1)
          first = MixedBooks.archive(@derived_lump)
          snapshot = first.payload.slice("title", "subtitle", "author_names", "archive", "row_keys")
          first.update!(payload: first.payload.merge("redirect_to_book_id" => 42))
          Review.create!(user: @user, reviewable: @derived_lump, rating: 3, body: "late")
          @derived_lump.update!(title: "Renamed")
          ::Books::BookAuthor.create!(book: @derived_lump, author: ::Books::Author.create!(name: "Added"), position: 2)

          second = MixedBooks.archive(@derived_lump)

          assert_equal first.id, second.id
          assert_equal snapshot, second.reload.payload.slice("title", "subtitle", "author_names", "archive", "row_keys")
          assert_equal ["Original"], second.payload["author_names"]
          assert_equal 42, second.payload["redirect_to_book_id"]
          assert_equal 1, ::Books::RepairVerdict.reimport_mixed.where(subject_key: first.subject_key).count
        end

        test "a passed legacy map is used instead of building one" do
          GoodreadsRebuild::LegacyBookMap.expects(:build).never

          MixedBooks.archive(@derived_lump, legacy_map: GoodreadsRebuild::LegacyBookMap.new({}))
        end

        private

        def book(id, classification)
          record = ::Books::Book.create!(id: id, title: "Book #{id}")
          if classification
            ::Books::RebuildBookSurvey.create!(book: record, classification: classification, surveyed_at: Time.current)
          end
          record
        end
      end
    end
  end
end
