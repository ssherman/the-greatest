require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class StripIdentifierTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @other = books_books(:crime_and_punishment)
            ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656-war-and-peace")
          end

          def verdict(book_id: @book.id, remove: [["books_work_goodreads_id", "656-war-and-peace"]], add: [["books_work_goodreads_id", "656"]])
            ::Books::RepairVerdict.create!(kind: :strip_identifier, subject_key: "book:#{book_id}:x", decided_by: :rule,
              status: :approved, payload: {"book_id" => book_id, "remove" => remove, "add" => add})
          end

          def goodreads_ids(book)
            book.identifiers.where(identifier_type: :books_work_goodreads_id).pluck(:value).sort
          end

          test "replaces the slug with the bare id" do
            result = StripIdentifier.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal ["656"], goodreads_ids(@book)
          end

          test "drops the slug when the book already holds the bare id" do
            ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656")

            StripIdentifier.call(verdict: verdict)

            assert_equal ["656"], goodreads_ids(@book)
          end

          test "applying twice does nothing the second time" do
            fix = verdict
            StripIdentifier.call(verdict: fix)
            result = StripIdentifier.call(verdict: fix)

            assert_equal :noop, result.data[:outcome]
            assert_equal ["656"], goodreads_ids(@book)
          end

          test "a bare id another book already holds is added, and the two books are flagged as a suspected pair" do
            ::Identifier.create!(identifiable: @other, identifier_type: :books_work_goodreads_id, value: "656")

            StripIdentifier.call(verdict: verdict)

            pair = ::DuplicateCandidate.where(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min).sole
            assert_equal [@book.id, @other.id].minmax, [pair.item_a_id, pair.item_b_id]
            assert_predicate pair, :raised_by_identifier_collision?
          end

          test "a slug something else already removed is not replaced with the bare id" do
            ::Identifier.where(identifiable: @book, value: "656-war-and-peace").delete_all

            result = StripIdentifier.call(verdict: verdict)

            assert_equal :noop, result.data[:outcome]
            assert_empty goodreads_ids(@book)
          end

          test "a book that no longer exists is a no-op with a reason" do
            result = StripIdentifier.call(verdict: verdict(book_id: 0))

            assert_equal :noop, result.data[:outcome]
            assert_equal "book 0 no longer exists", result.data[:reason]
          end
        end
      end
    end
  end
end
