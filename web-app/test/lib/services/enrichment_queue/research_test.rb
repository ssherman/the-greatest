require "test_helper"

module Services
  module EnrichmentQueue
    class ResearchTest < ActiveSupport::TestCase
      Result = Type::Result

      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        EnrichmentQueueTestType.paid = true
        @book = books_books(:war_and_peace)
        @row = ::EnrichmentRequest.create!(enrichable: @book, kind: "books.test_type", reason: "missing", priority: 1)
      end

      teardown { EnrichmentQueueTestType.reset! }

      def ledger_row = ::Enrichment.create!(enrichable: @book, kind: "books.test_type", mode: :research, outcome: :applied, facts: {})

      test "a successful research closes the row done with the outcome and the paid_research stamp" do
        ledger = ledger_row
        EnrichmentQueueTestType.research_result = Result.new(success?: true, data: {enrichment: ledger, outcome: "applied"}, errors: [])

        assert Research.call(kind: "books.test_type").success?

        @row.reload
        assert_equal ["done", "applied", ledger.id, "paid_research", nil, nil, nil, 1],
          [@row.status, @row.outcome, @row.enrichment_id, @row.resolved_via, @row.resolved_by_id, @row.lease_token, @row.lease_expires_at, @row.attempts]
        assert_not_nil @row.resolved_at
      end

      test "a failed result leaves the row failed with the error and returns a failure" do
        EnrichmentQueueTestType.research_result = Result.new(success?: false, data: nil, errors: ["model down"])

        result = Research.call(kind: "books.test_type")

        assert_not result.success?
        @row.reload
        assert_equal ["failed", "model down", "paid_research", nil], [@row.status, @row.error, @row.resolved_via, @row.lease_token]
        assert_not_nil @row.resolved_at
      end

      test "a raise leaves the row failed and does not propagate" do
        EnrichmentQueueTestType.research_result = ->(_request) { raise "boom" }

        result = nil
        assert_nothing_raised { result = Research.call(kind: "books.test_type") }

        assert_not result.success?
        @row.reload
        assert_equal ["failed", "RuntimeError: boom"], [@row.status, @row.error]
      end

      test "an error longer than the cap is truncated" do
        EnrichmentQueueTestType.research_result = Result.new(success?: false, data: nil, errors: ["x" * 5_000])
        Research.call(kind: "books.test_type")
        assert_equal Apply::MAX_ERROR, @row.reload.error.length
      end

      test "an empty queue is a success with no request and never researches" do
        @row.update!(status: :done)
        EnrichmentQueueTestType.research_result = ->(_request) { flunk "researched with nothing claimed" }

        result = Research.call(kind: "books.test_type")

        assert result.success?
        assert_nil result.data[:request]
      end

      test "a type without a paid path is a failure and claims nothing" do
        EnrichmentQueueTestType.paid = false

        result = Research.call(kind: "books.test_type")

        assert_not result.success?
        assert_match(/no paid research path/, result.errors.first)
        assert_equal "pending", @row.reload.status
      end

      test "a row taken over while the research ran is not overwritten" do
        EnrichmentQueueTestType.research_result = lambda do |request|
          ::EnrichmentRequest.where(id: request.id).update_all(lease_token: "someone-else")
          Result.new(success?: true, data: {enrichment: nil, outcome: "applied"}, errors: [])
        end

        result = Research.call(kind: "books.test_type")

        assert result.success?
        assert_nil result.data[:request]
        assert_equal ["claimed", "someone-else"], [@row.reload.status, @row.lease_token]
      end

      test "a row whose gap closed is closed by the claim and not researched" do
        EnrichmentQueueTestType.needed = false
        EnrichmentQueueTestType.research_result = ->(_request) { flunk "researched a closed gap" }

        result = Research.call(kind: "books.test_type")

        assert result.success?
        assert_equal ["done", "no_longer_needed"], [@row.reload.status, @row.outcome]
      end
    end
  end
end
