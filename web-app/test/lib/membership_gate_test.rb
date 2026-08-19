require "test_helper"

class MembershipGateTest < ActiveSupport::TestCase
  test "members_only? is true for a registered feature" do
    assert MembershipGate.members_only?(:members_area)
  end

  test "members_only? accepts a string as well as a symbol" do
    assert MembershipGate.members_only?("members_area")
  end

  test "members_only? is false for anything not registered" do
    refute MembershipGate.members_only?(:ranked_lists)
  end

  test "every registered feature carries a human description" do
    # The registry exists to be read by a person asking "what is behind the
    # paywall?". A bare key with no description does not answer that.
    MembershipGate::FEATURES.each do |key, description|
      assert description.present?, "#{key} has no description"
    end
  end

  test "validate! raises for an unregistered feature" do
    assert_raises(MembershipGate::UnknownFeature) { MembershipGate.validate!(:not_a_feature) }
  end

  test "validate! returns the symbol for a registered feature" do
    assert_equal :members_area, MembershipGate.validate!("members_area")
  end
end
