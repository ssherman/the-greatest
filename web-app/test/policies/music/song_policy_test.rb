require "test_helper"

module Music
  class SongPolicyTest < ActiveSupport::TestCase
    test "a domain editor can execute non-destructive actions but cannot destroy" do
      policy = ::Music::SongPolicy.new(users(:contractor_user), music_songs(:money))

      assert policy.update?
      assert_not policy.destroy?
      assert policy.execute_action?,
        "execute_action carries non-destructive actions too; write access must be enough to reach it"
    end
  end
end
