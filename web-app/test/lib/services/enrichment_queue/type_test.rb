require "test_helper"

module Services
  module EnrichmentQueue
    class TypeTest < ActiveSupport::TestCase
      test "ledger_result is a failure when there is no ledger row" do
        result = Type.ledger_result(nil)

        refute result.success?
        assert_equal ["no ledger row"], result.errors
      end

      test "ledger_result is a failure carrying the error of a failed row" do
        result = Type.ledger_result(::Enrichment.new(outcome: :failed, error: "model down"))

        refute result.success?
        assert_equal ["model down"], result.errors
      end

      test "ledger_result gives a failed row with no error text a message" do
        result = Type.ledger_result(::Enrichment.new(outcome: :failed, error: nil))

        refute result.success?
        assert_equal ["failed (no error recorded)"], result.errors
      end

      test "ledger_result is a failure naming the reason of a skipped row" do
        result = Type.ledger_result(::Enrichment.new(outcome: :skipped, reason: "disabled"))

        refute result.success?
        assert_equal ["skipped: disabled"], result.errors
      end

      test "ledger_result is a success with the row and its outcome for an applied row" do
        row = ::Enrichment.new(outcome: :applied)

        result = Type.ledger_result(row)

        assert result.success?
        assert_equal [row, "applied"], [result.data[:enrichment], result.data[:outcome]]
      end

      test "paid_research_blocker is nil unless a type says otherwise" do
        assert_nil Type.paid_research_blocker
        assert_nil EnrichmentQueueTestType.paid_research_blocker
      end
    end
  end
end
