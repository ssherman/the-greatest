require "test_helper"

class UserListPolicyTest < ActiveSupport::TestCase
  setup do
    @user = users(:regular_user)
    @list = user_lists(:regular_user_music_albums_favorites)
  end

  test "create? requires a signed-in user" do
    assert UserListPolicy.new(@user, @list).create?
    refute UserListPolicy.new(nil, @list).create?
  end
end
