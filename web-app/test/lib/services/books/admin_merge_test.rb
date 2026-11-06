require "test_helper"

module Services
  module Books
    class AdminMergeTest < ActiveSupport::TestCase
      setup do
        @source = books_books(:crime_and_punishment)
        @target = books_books(:war_and_peace)
      end

      def stub_merger(klass, stats)
        merger = stub(call: klass::Result.new(success?: true, data: nil, errors: []), stats: stats)
        klass.expects(:new).returns(merger)
      end

      test "a dry run calls no merger and has no warnings" do
        ::Books::Book::Merger.expects(:new).never

        result = AdminMerge.call(source: @source, target: @target, dry_run: true)

        assert result.success?
        assert_equal({warnings: []}, result.data)
        assert ::Books::Book.exists?(@source.id)
      end

      test "merging a record with itself fails" do
        ::Books::Book::Merger.expects(:new).never

        result = AdminMerge.call(source: @target, target: @target)

        assert_not result.success?
        assert_equal ["Cannot merge a record with itself"], result.errors
      end

      test "a real book merge deletes the source" do
        result = AdminMerge.call(source: @source, target: @target)

        assert result.success?, result.errors.inspect
        assert_not ::Books::Book.exists?(@source.id)
        assert ::Books::Book.exists?(@target.id)
      end

      test "a real author merge deletes the source" do
        source = books_authors(:king)
        target = books_authors(:tolstoy)

        result = AdminMerge.call(source: source, target: target)

        assert result.success?, result.errors.inspect
        assert_not ::Books::Author.exists?(source.id)
      end

      test "a merger failure carries the merger's errors" do
        merger = stub(call: ::Books::Book::Merger::Result.new(success?: false, data: nil, errors: ["boom"]), stats: {})
        ::Books::Book::Merger.expects(:new).returns(merger)

        result = AdminMerge.call(source: @source, target: @target)

        assert_not result.success?
        assert_equal ["boom"], result.errors
      end

      test "a post-commit error becomes a book warning" do
        stub_merger(::Books::Book::Merger, post_commit_error: "Redis down")

        result = AdminMerge.call(source: @source, target: @target)

        assert_equal [{code: "post_commit_error", detail: "Search reindexing, ranking recalculation and the generated favorites rebuild could not be scheduled (Redis down); they will need to be re-run."}],
          result.data[:warnings]
      end

      test "an author post-commit warning omits the favorites rebuild" do
        stub_merger(::Books::Author::Merger, post_commit_error: "Redis down")

        result = AdminMerge.call(source: books_authors(:king), target: books_authors(:tolstoy))

        assert_equal [{code: "post_commit_error", detail: "Search reindexing and ranking recalculation could not be scheduled (Redis down); they will need to be re-run."}],
          result.data[:warnings]
      end

      test "untransferred authors and credits become warnings" do
        stub_merger(::Books::Book::Merger, book_authors_not_transferred: 2, credits_not_transferred: 1)

        result = AdminMerge.call(source: @source, target: @target)

        assert_equal [
          {code: "book_authors_not_transferred", detail: "2 author(s) did not transfer because the surviving book already has its own."},
          {code: "credits_not_transferred", detail: "1 credit(s) did not transfer because the surviving book already has its own."}
        ], result.data[:warnings]
      end

      test "zero counts produce no warning" do
        stub_merger(::Books::Book::Merger, book_authors_not_transferred: 0, credits_not_transferred: 0)

        assert_equal [], AdminMerge.call(source: @source, target: @target).data[:warnings]
      end

      test "mismatched classes raise ArgumentError" do
        assert_raises(ArgumentError) { AdminMerge.call(source: @source, target: books_authors(:king)) }
      end
    end
  end
end
