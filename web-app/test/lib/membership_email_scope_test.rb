require "test_helper"

class MembershipEmailScopeTest < ActiveSupport::TestCase
  Record = Struct.new(:sold_by_this_app?)

  test "defaults to own_only, so a record this app did not sell is not emailed about" do
    with_env(MembershipEmailScope::ENV_VAR => nil) do
      assert MembershipEmailScope.may_email?(Record.new(true))
      assert_not MembershipEmailScope.may_email?(Record.new(false))
    end
  end

  test "own_only is explicit and behaves the same as the default" do
    with_env(MembershipEmailScope::ENV_VAR => "own_only") do
      assert MembershipEmailScope.may_email?(Record.new(true))
      assert_not MembershipEmailScope.may_email?(Record.new(false))
    end
  end

  # The cutover setting. Once legacy is retired it stops emailing its own
  # subscribers, and this app must start -- otherwise every legacy-era member
  # silently never hears about a cancellation again.
  test "all emails about every record, including ones this app did not sell" do
    with_env(MembershipEmailScope::ENV_VAR => "all") do
      assert MembershipEmailScope.may_email?(Record.new(true))
      assert MembershipEmailScope.may_email?(Record.new(false))
    end
  end

  # A typo in production must not silently start double-emailing every legacy
  # subscriber. Unknown values fall back to the safe setting.
  test "an unrecognised value falls back to own_only rather than all" do
    with_env(MembershipEmailScope::ENV_VAR => "evrything") do
      assert_not MembershipEmailScope.may_email?(Record.new(false))
    end
  end
end
