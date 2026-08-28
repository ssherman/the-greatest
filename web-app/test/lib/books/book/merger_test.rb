require "test_helper"

module Books
  class Book
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = books_books(:crime_and_punishment)
        @target = books_books(:war_and_peace)
      end

      test "merges successfully and returns the target book" do
        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source book" do
        source_id = @source.id

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::Book.exists?(source_id)
      end

      test "refuses to merge a book with itself" do
        result = ::Books::Book::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge a book with itself"], result.errors
        assert ::Books::Book.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Books::Book::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Books::Book.exists?(@source.id), "source must survive a failed merge"
      end

      test "rolls back writes already made when a later step raises" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_work_isbn10, value: "0140449132"
        )
        ::Books::Book::Merger.any_instance.stubs(:reconcile_scalars)
          .raises(StandardError.new("boom"))

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_equal @source.id, identifier.reload.identifiable_id,
          "the identifier move must have rolled back"
        assert ::Books::Book.exists?(@source.id)
      end
    end
  end
end
