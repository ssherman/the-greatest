require "test_helper"

module Books
  class Author
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = books_authors(:bachman)
        @target = books_authors(:king)

        # Sidekiq test mode is :inline, and the merger fires this job
        # unconditionally (author rankings recalculate globally, so there are no
        # configuration ids to gate on). Left unstubbed it runs a real ranking
        # calculation on every test in this file. The scheduling test in Task 8
        # re-declares this with `expects`, which Mocha checks ahead of this stub.
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
      end

      test "merges successfully and returns the target author" do
        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source author" do
        source_id = @source.id

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not ::Books::Author.exists?(source_id)
      end

      test "refuses to merge an author with itself" do
        result = ::Books::Author::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge an author with itself"], result.errors
        assert ::Books::Author.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Books::Author::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Books::Author.exists?(@source.id), "source must survive a failed merge"
      end
    end
  end
end
