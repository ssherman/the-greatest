require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MergeBooksTest < ActiveSupport::TestCase
          setup do
            @source = books_books(:cannery_row)
            @target = books_books(:of_mice_and_men)
          end

          def verdict(source_id: @source.id, target_id: @target.id)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{source_id}:#{target_id}",
              decided_by: :rule, status: :approved, payload: {"source_id" => source_id, "target_id" => target_id})
          end

          test "merges through the book merger" do
            ::Books::Book::Merger.expects(:call).with(source: @source, target: @target)
              .returns(::Books::Book::Merger::Result.new(success?: true, data: @target, errors: []))

            assert_equal :applied, MergeBooks.call(verdict: verdict).data[:outcome]
          end

          test "either book gone is a no-op" do
            ::Books::Book::Merger.expects(:call).never

            assert_equal "book 0 no longer exists", MergeBooks.call(verdict: verdict(source_id: 0)).data[:reason]
            assert_equal "book 0 no longer exists", MergeBooks.call(verdict: verdict(target_id: 0)).data[:reason]
          end

          test "a merger failure raises with its errors" do
            ::Books::Book::Merger.stubs(:call).returns(::Books::Book::Merger::Result.new(success?: false, data: nil, errors: ["locked"]))

            assert_raises(Failed) { MergeBooks.call(verdict: verdict) }
          end
        end
      end
    end
  end
end
