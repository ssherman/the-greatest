require "test_helper"

module Services
  module MatchDecisions
    class FilterTest < ActiveSupport::TestCase
      setup do
        @scope = MatchDecision.where(finder: DataImporters::FinderRegistry.for_domain(:books).map(&:finder))
      end

      def ids(params) = Filter.call(@scope, params).pluck(:id)

      test "defaults to pending with verify runs hidden" do
        result = ids({})

        assert_includes result, match_decisions(:low_confidence_book_match).id
        assert_not_includes result, match_decisions(:war_and_peace_sweep).id
        assert_not_includes result, match_decisions(:reviewed_book_match).id
      end

      test "reviewed and verify values select reviewed rows and include verify runs" do
        assert_equal [match_decisions(:reviewed_book_match).id], ids({reviewed: "reviewed"})
        assert_includes ids({reviewed: "all", verify: "include"}), match_decisions(:war_and_peace_sweep).id
      end

      test "an entity of another domain matches nothing and an unknown one is ignored" do
        assert_empty ids({entity: "album"})
        assert_equal ids({}), ids({entity: "cheese"})
      end

      test "outcome, confidence and decided_by narrow the scope and unknown values are ignored" do
        assert_equal [match_decisions(:new_book_created).id], ids({outcome: "unmatched", confidence: "low"})
        assert_equal ids({}), ids({outcome: "maybe", confidence: "huge", decided_by: "magic"})
      end
    end
  end
end
