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

          def merger(success: true, errors: [], configurations: [])
            stub("merger", call: ::Books::Book::Merger::Result.new(success?: success, data: @target, errors: errors),
              affected_ranking_configurations: configurations)
          end

          test "merges through the book merger, leaving its ranking and favorites jobs to the run" do
            ::Books::Book::Merger.expects(:new).with(source: @source, target: @target, defer_rankings: true)
              .returns(merger(configurations: [7]))

            result = MergeBooks.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal [7], result.data[:reweigh_configuration_ids]
            assert_equal [:user_favorites], result.data[:follow_ups]
          end

          test "either book gone is a no-op" do
            ::Books::Book::Merger.expects(:new).never

            assert_equal "book 0 no longer exists", MergeBooks.call(verdict: verdict(source_id: 0)).data[:reason]
            assert_equal "book 0 no longer exists", MergeBooks.call(verdict: verdict(target_id: 0)).data[:reason]
          end

          test "a merger failure raises with its errors" do
            ::Books::Book::Merger.stubs(:new).returns(merger(success: false, errors: ["locked"]))

            assert_raises(Failed) { MergeBooks.call(verdict: verdict) }
          end
        end
      end
    end
  end
end
