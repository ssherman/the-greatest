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
          import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, legacy_import_id: 91)
          import.rows.create!(row_number: 7, legacy_book_id: @derived_lump.id)
          member = ::Books::GoodreadsImport.create!(user: users(:editor_user), source: :member, status: :complete)
          member.rows.create!(row_number: 1, legacy_book_id: @derived_lump.id)

          verdict = MixedBooks.archive(@derived_lump)
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
          assert_equal [[import.id, 7]], payload["row_keys"]
        end

        test "archive twice keeps the first archive" do
          first = MixedBooks.archive(@derived_lump)
          snapshot = first.payload["archive"]
          Review.create!(user: @user, reviewable: @derived_lump, rating: 3, body: "late")

          second = MixedBooks.archive(@derived_lump)

          assert_equal first.id, second.id
          assert_equal snapshot, second.reload.payload["archive"]
          assert_equal 1, ::Books::RepairVerdict.reimport_mixed.where(subject_key: first.subject_key).count
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
