require "test_helper"

module Services
  module Books
    module SeriesEdits
      class MergeTest < ActiveSupport::TestCase
        setup do
          @source = ::Books::Series.create!(title: "Merge Source")
          @target = ::Books::Series.create!(title: "Merge Target")
          @a = books_books(:war_and_peace)
          @b = books_books(:crime_and_punishment)
        end

        def link(series, book, position: 1, numbered: true, label: nil)
          ::Books::SeriesBook.create!(series: series, book: book, position: position, numbered: numbered, position_label: label)
        end

        test "merge moves links and marks the source deleted and merged_into the target" do
          link(@source, @a)
          link(@source, @b, position: 2)

          result = Merge.call(target: @target, source: @source)

          assert result.success?
          assert_equal({moved: 2, dropped: 0}, result.data)
          assert_equal [@a.id, @b.id].sort, @target.series_books.pluck(:book_id).sort
          assert_equal 0, ::Books::SeriesBook.where(series_id: @source.id).count
          @source.reload
          assert @source.deleted?
          assert_equal @target, @source.merged_into
        end

        test "merge keeps the target's link for a shared book" do
          mine = link(@target, @a, position: 3, numbered: false, label: "Prequel")
          link(@source, @a, position: 1)
          link(@source, @b, position: 2)

          result = Merge.call(target: @target, source: @source)

          assert_equal({moved: 1, dropped: 1}, result.data)
          assert_equal 1, ::Books::SeriesBook.where(book_id: @a.id, series_id: [@source.id, @target.id]).count
          mine.reload
          assert_equal @target.id, mine.series_id
          assert_equal [3, false, "Prequel"], [mine.position, mine.numbered, mine.position_label]
        end

        test "merge repoints series previously merged into the source" do
          older = ::Books::Series.create!(title: "Older", deleted: true, merged_into: @source)

          Merge.call(target: @target, source: @source)

          assert_equal @target, older.reload.merged_into
          assert_equal @target, older.canonical
        end

        test "merge keeps the target's representative, else adopts the source's when that book moved" do
          link(@source, @a)
          @source.update!(representative_book: @a)
          Merge.call(target: @target, source: @source)
          assert_equal @a.id, @target.reload.representative_book_id

          other_source = ::Books::Series.create!(title: "Other Source", representative_book: @b)
          link(other_source, @b)
          Merge.call(target: @target, source: other_source)
          assert_equal @a.id, @target.reload.representative_book_id
        end

        test "merge does not adopt a representative whose link was dropped" do
          link(@target, @a)
          link(@source, @a)
          @source.update!(representative_book: @a)

          Merge.call(target: @target, source: @source)

          assert_nil @target.reload.representative_book_id
        end

        test "merge keeps the source's goodreads identifier on the source" do
          @source.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "555002", source: :goodreads)

          Merge.call(target: @target, source: @source)

          identifier = ::Identifier.find_by(identifier_type: :books_series_goodreads_id, value: "555002")
          assert_equal @source, identifier.identifiable
          assert_equal @target, identifier.identifiable.canonical
        end

        test "dry run changes nothing and reports moved and dropped" do
          link(@target, @a)
          link(@source, @a)
          link(@source, @b, position: 2)

          result = Merge.call(target: @target, source: @source, dry_run: true)

          assert result.success?
          assert_equal({moved: 1, dropped: 1}, result.data)
          assert_not @source.reload.deleted?
          assert_equal 2, @source.series_books.count
          assert_equal 1, @target.series_books.count
        end

        test "refuses merging a series into itself" do
          result = Merge.call(target: @source, source: @source)
          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["A series can't be merged into itself."], result.errors
        end

        test "refuses a deleted source" do
          @source.update!(deleted: true)
          assert_equal "Deleted series can't be merged.", Merge.refusal(source: @source, target: @target)
          assert_not Merge.call(target: @target, source: @source).success?
        end

        test "refuses a deleted target" do
          @target.update!(deleted: true)
          assert_equal "Deleted series can't be merged.", Merge.refusal(source: @source, target: @target)
        end

        test "refuses a merged target" do
          @target.update!(merged_into: books_series(:asoiaf))
          assert_equal "Merged series can't be merge targets.", Merge.refusal(source: @source, target: @target)
        end

        test "refusal is nil for a valid pair" do
          assert_nil Merge.refusal(source: @source, target: @target)
        end

        test "stale in-memory state is re-checked after the lock" do
          stale = ::Books::Series.find(@source.id)
          @source.update!(deleted: true)

          assert_not Merge.call(target: @target, source: stale).success?
        end
      end
    end
  end
end
