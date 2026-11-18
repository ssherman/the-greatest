require "test_helper"

module Services
  module EnrichmentQueue
    class ResearchRouteTest < ActiveSupport::TestCase
      KIND = "books.test_type"

      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @book = books_books(:war_and_peace)
      end

      teardown { EnrichmentQueueTestType.reset! }

      def request_with(status)
        attrs = {enrichable: @book, kind: KIND, reason: "missing", version: 1, priority: 1, sources: [], status: status}
        attrs.merge!(outcome: "x", note: "n", resolved_at: Time.current) if %w[done skipped failed].include?(status.to_s)
        ::EnrichmentRequest.create!(attrs)
      end

      test "queue? is false by default" do
        refute ResearchRoute.queue?
      end

      test "queue? is true when research_via is queue" do
        Rails.application.config.x.ai.stubs(:research_via).returns("queue")
        assert ResearchRoute.queue?
      end

      test "open_for? is true with no row" do
        assert ResearchRoute.open_for?(kind: KIND, record: @book)
      end

      test "open_for? is true for a pending or a claimed row" do
        row = request_with(:pending)
        assert ResearchRoute.open_for?(kind: KIND, record: @book)
        row.update_columns(status: ::EnrichmentRequest.statuses.fetch("claimed"))
        assert ResearchRoute.open_for?(kind: KIND, record: @book)
      end

      %i[submitted done skipped failed].each do |status|
        test "open_for? is false for a #{status} row" do
          request_with(status)
          refute ResearchRoute.open_for?(kind: KIND, record: @book)
        end
      end

      test "defer inserts one pending row with the type's version and priority" do
        assert ResearchRoute.defer(kind: KIND, record: @book)

        row = ::EnrichmentRequest.find_by!(enrichable: @book, kind: KIND)
        assert_equal ["pending", "research_wanted", 1, @book.id, []], [row.status, row.reason, row.version, row.priority, row.sources]
      end

      test "defer inserts nothing when a row of any status exists" do
        request_with(:done)

        refute ResearchRoute.defer(kind: KIND, record: @book)
        assert_equal 1, ::EnrichmentRequest.where(enrichable: @book, kind: KIND).count
        assert ::EnrichmentRequest.find_by!(enrichable: @book, kind: KIND).done?
      end

      test "defer inserts nothing when the type no longer needs the record" do
        EnrichmentQueueTestType.needed = false

        refute ResearchRoute.defer(kind: KIND, record: @book)
        assert_equal 0, ::EnrichmentRequest.where(enrichable: @book, kind: KIND).count
      end

      test "defer returns false and does not raise when the insert fails" do
        ::EnrichmentRequest.stubs(:insert_all).raises(ActiveRecord::StatementInvalid.new("boom"))

        refute ResearchRoute.defer(kind: KIND, record: @book)
      end
    end
  end
end
