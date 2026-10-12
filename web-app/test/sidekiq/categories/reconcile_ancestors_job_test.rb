require "test_helper"

module Categories
  class ReconcileAncestorsJobTest < ActiveSupport::TestCase
    test "reconciles every book" do
      Categories::AncestorReconciler.expects(:call).with.returns(Categories::AncestorReconciler::Result.new(success?: true, data: {added: 0, removed: 0}, errors: []))

      Categories::ReconcileAncestorsJob.new.perform
    end
  end
end
