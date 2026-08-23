require "test_helper"

module Music
  class AlbumPolicyTest < ActiveSupport::TestCase
    test "a domain editor cannot merge, because merging deletes a record" do
      policy = ::Music::AlbumPolicy.new(users(:contractor_user), music_albums(:dark_side_of_the_moon))

      assert policy.update?
      assert_not policy.destroy?
      assert_not policy.execute_action?
    end
  end
end
