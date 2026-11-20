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

          test "a pair survivor later merged away again resolves through its redirect, not back through the pair" do
            kept, folded = gone_ids(2)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: kept, item_b_id: folded, status: :merged, source: :ai)
            RecordRedirect.create!(item_type: "Books::Book", from_id: folded, to_id: @survivor.id)
            RecordRedirect.create!(item_type: "Books::Book", from_id: kept, to_id: @survivor.id)

            assert_equal @survivor, MergedBook.call(kept)
            assert_equal @survivor, MergedBook.call(folded)
          end

          test "a merged pair with no redirect is still followed" do
            gone_id, = gone_ids(1)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: @survivor.id, item_b_id: gone_id, status: :merged, source: :ai)

            assert_equal @survivor, MergedBook.call(gone_id)
          end

          test "a deleted mixed book's redirect points at a guess and is not followed" do
            gone_id, = gone_ids(1)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{gone_id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => gone_id, "redirect_to_book_id" => @survivor.id, "archive" => {}})
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @survivor.id)

            assert_nil MergedBook.call(gone_id)
          end

          test "a deleted mixed book that survived an earlier merged pair is not sent back to the book merged into it" do
            mixed_id, folded = gone_ids(2)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: mixed_id, item_b_id: folded, status: :merged, source: :ai)
            RecordRedirect.create!(item_type: "Books::Book", from_id: folded, to_id: mixed_id)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{mixed_id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => mixed_id, "redirect_to_book_id" => @survivor.id, "archive" => {}})
            RecordRedirect.create!(item_type: "Books::Book", from_id: mixed_id, to_id: @survivor.id)

            assert_nil MergedBook.merge_target(mixed_id)
            assert_nil MergedBook.call(mixed_id)
          end

          test "a deleted mixed book that absorbed a duplicate before redirects existed is not sent back to it" do
            mixed_id, folded = gone_ids(2)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: mixed_id, item_b_id: folded, status: :merged, source: :ai)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{mixed_id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => mixed_id, "redirect_to_book_id" => @survivor.id, "archive" => {}})
            RecordRedirect.create!(item_type: "Books::Book", from_id: mixed_id, to_id: @survivor.id)

            assert_nil MergedBook.merge_target(mixed_id)
          end

          test "a deleted mixed book that absorbed a duplicate through a merge_books verdict is not sent back to it" do
            mixed_id, folded = gone_ids(2)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: mixed_id, item_b_id: folded, status: :merged, source: :ai)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{mixed_id}:#{folded}", decided_by: :rule, status: :approved,
              payload: {"source_id" => folded, "target_id" => mixed_id})
            RecordRedirect.create!(item_type: "Books::Book", from_id: folded, to_id: nil)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{mixed_id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => mixed_id, "redirect_to_book_id" => @survivor.id, "archive" => {}})
            RecordRedirect.create!(item_type: "Books::Book", from_id: mixed_id, to_id: @survivor.id)

            assert_nil MergedBook.merge_target(mixed_id)
          end

          test "a pair-only chain through a gone middle book still reaches the survivor" do
            first, middle = gone_ids(2)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: first, item_b_id: middle, status: :merged, source: :ai)
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: @survivor.id, item_b_id: middle, status: :merged, source: :ai)

            assert_equal @survivor, MergedBook.call(first)
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
