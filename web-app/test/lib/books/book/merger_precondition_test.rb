require "test_helper"

module Books
  class Book
    # The optional precondition a caller hands the merger: decided again under
    # the merger's own row locks, inside its transaction. merger_test.rb covers
    # the merge without one.
    class MergerPreconditionTest < ActiveSupport::TestCase
      setup do
        ::Books::PurgeShowPagesJob.stubs(:perform_async)
        ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
        @source = ::Books::Book.create!(title: "Precondition Source")
        @target = ::Books::Book.create!(title: "Precondition Target")
      end

      test "a reason from the precondition stops the merge and changes nothing" do
        seen = nil
        result = Merger.call(source: @source, target: @target, precondition: ->(source, target) {
          seen = [source.id, target.id]
          "not today"
        })

        assert_not result.success?
        assert_equal [["not today"], {precondition: true}], [result.errors, result.data]
        assert_equal [@source.id, @target.id], seen
        assert ::Books::Book.exists?(@source.id)
        assert_not RecordRedirect.exists?(item_type: "Books::Book", from_id: @source.id)
      end

      test "a precondition that returns nil lets the merge go ahead" do
        result = Merger.call(source: @source, target: @target, precondition: ->(*) {})

        assert result.success?, result.errors.inspect
        assert_not ::Books::Book.exists?(@source.id)
      end

      test "the precondition runs inside the merger's transaction, after the rows are locked" do
        open = ActiveRecord::Base.connection.open_transactions
        inside = nil
        Merger.call(source: @source, target: @target, precondition: ->(*) {
          inside = ActiveRecord::Base.connection.open_transactions
          nil
        })

        assert_operator inside, :>, open
      end

      test "AdminMerge hands the precondition on and reports its reason" do
        result = ::Services::Books::AdminMerge.call(source: @source, target: @target, precondition: ->(*) { "stop" })

        assert_not result.success?
        assert_equal [["stop"], {precondition: true}], [result.errors, result.data]
        assert ::Books::Book.exists?(@source.id)
      end
    end
  end
end
