require "test_helper"

module Services
  module CategoryCleanup
    class CostGuardTest < ActiveSupport::TestCase
      setup do
        Rails.configuration.x.categories_cleanup.stubs(:estimated_cost_per_call).returns(0.01)
        Rails.configuration.x.categories_cleanup.stubs(:max_unforced_cost).returns(50)
      end

      test "returns the estimate under the limit" do
        assert_in_delta 10.0, CostGuard.check!(calls: 1000)
      end

      test "refuses over the limit unless forced" do
        assert_raises(CostGuard::TooExpensive) { CostGuard.check!(calls: 6000) }
        assert_in_delta 60.0, CostGuard.check!(calls: 6000, force: true)
      end
    end
  end
end
