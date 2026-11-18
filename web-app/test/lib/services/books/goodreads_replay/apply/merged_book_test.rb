# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MergedBookTest < ActiveSupport::TestCase
          setup do
            @survivor = books_books(:crime_and_punishment)
          end

          def gone_ids(count) = Array.new(count) { |i| ::Books::Book.maximum(:id) + 1000 + i }

          test "a live book is itself" do
            assert_equal @survivor, MergedBook.call(@survivor.id)
          end

          test "an admin merge that left only a record_redirects row is followed to the survivor" do
            gone_id, = gone_ids(1)
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @survivor.id)

            assert_equal @survivor, MergedBook.call(gone_id)
          end

          test "the real merger's redirect is followed" do
            merged_away = ::Books::Book.create!(title: "Merged Away", book_kind: :standalone)
            gone_id = merged_away.id
            ::Books::Book::Merger.call(source: merged_away, target: @survivor)

            assert_equal @survivor, MergedBook.call(gone_id)
          end

          test "a redirect then a merge_books verdict are followed as one chain" do
            first, second = gone_ids(2)
            RecordRedirect.create!(item_type: "Books::Book", from_id: first, to_id: second)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{@survivor.id}:#{second}", decided_by: :rule, status: :approved,
              payload: {"source_id" => second, "target_id" => @survivor.id})

            assert_equal @survivor, MergedBook.call(first)
          end

          test "a deleted mixed book's redirect points at a guess and is not followed" do
            gone_id, = gone_ids(1)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{gone_id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => gone_id, "redirect_to_book_id" => @survivor.id, "archive" => {}})
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @survivor.id)

            assert_nil MergedBook.call(gone_id)
          end

          test "a deleted book (a redirect with no target) resolves to nothing" do
            gone_id, = gone_ids(1)
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: nil)

            assert_nil MergedBook.call(gone_id)
          end

          test "an author redirect with the same id is not a book redirect" do
            gone_id, = gone_ids(1)
            RecordRedirect.create!(item_type: "Books::Author", from_id: gone_id, to_id: @survivor.id)

            assert_nil MergedBook.call(gone_id)
          end
        end
      end
    end
  end
end
