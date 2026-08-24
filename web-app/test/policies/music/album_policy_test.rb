require "test_helper"

module Music
  class AlbumPolicyTest < ActiveSupport::TestCase
    test "a domain editor can execute non-destructive actions but cannot destroy" do
      policy = ::Music::AlbumPolicy.new(users(:contractor_user), music_albums(:dark_side_of_the_moon))

      assert policy.update?
      assert_not policy.destroy?
      assert policy.execute_action?,
        "execute_action carries non-destructive actions too; write access must be enough to reach it"
    end
  end
end
