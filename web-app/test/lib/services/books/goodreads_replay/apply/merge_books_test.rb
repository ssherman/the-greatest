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

          test "a reset_source merge clears the source's legacy data before merging" do
            source = ::Books::Book.create!(id: GoodreadsRebuild::Cohort.post_import_range.first + 5_000, title: "Derived")
            source.identifiers.create!(identifier_type: :books_work_asin, value: "B00LEGACY1", source: :legacy)
            source.category_items.create!(category: categories(:books_fiction_genre))
            item = UserListItem.create!(user_list: user_lists(:regular_user_books_favorites), listable: source, position: 1)
            v = verdict(source_id: source.id)
            v.update!(payload: v.payload.merge("reset_source" => true))
            categories_before = @target.category_items.count

            result = MergeBooks.call(verdict: v)

            assert_equal :applied, result.data[:outcome]
            refute @target.identifiers.exists?(value: "B00LEGACY1")
            assert_equal categories_before, @target.category_items.reload.count
            assert_equal @target.id, item.reload.listable_id
            assert_includes v.reload.payload["removed"]["identifiers"], ["books_work_asin", "B00LEGACY1", "legacy"]
          end

          test "a failure right after the reset rolls back the reset and the archive together" do
            source = ::Books::Book.create!(id: GoodreadsRebuild::Cohort.post_import_range.first + 5_000, title: "Derived")
            source.identifiers.create!(identifier_type: :books_work_asin, value: "B00LEGACY1", source: :legacy)
            v = verdict(source_id: source.id)
            v.update!(payload: v.payload.merge("reset_source" => true))
            v.class.any_instance.stubs(:update_columns).raises(ActiveRecord::StatementInvalid, "boom")

            assert_raises(ActiveRecord::StatementInvalid) { MergeBooks.call(verdict: v) }

            assert source.reload.identifiers.exists?(value: "B00LEGACY1")
            refute v.reload.payload.key?("removed")
          end

          test "refuses a reset_source merge from a trusted source" do
            ::Books::Book::Merger.expects(:new).never
            v = verdict
            v.update!(payload: v.payload.merge("reset_source" => true))

            error = assert_raises(Failed) { MergeBooks.call(verdict: v) }
            assert_match(/source is trusted now/, error.message)
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
