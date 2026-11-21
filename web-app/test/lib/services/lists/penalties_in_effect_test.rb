require "test_helper"

module Services
  module Lists
    class PenaltiesInEffectTest < ActiveSupport::TestCase
      test "returns the penalties named in the details, ordered by category then name" do
        a = penalties(:global_penalty)
        b = penalties(:cross_media_penalty)
        ranked_list = RankedList.new(calculated_weight_details: {"penalties" => [{"penalty_id" => a.id}, {"penalty_id" => b.id}, {"value" => 3}]})

        result = PenaltiesInEffect.call(ranked_list)

        assert_equal [b, a], result
      end

      test "is empty without a ranked list or details" do
        assert_equal [], PenaltiesInEffect.call(nil)
        assert_equal [], PenaltiesInEffect.call(RankedList.new(calculated_weight_details: nil))
        assert_equal [], PenaltiesInEffect.call(RankedList.new(calculated_weight_details: {}))
        assert_equal [], PenaltiesInEffect.call(RankedList.new(calculated_weight_details: {"penalties" => []}))
      end
    end
  end
end
