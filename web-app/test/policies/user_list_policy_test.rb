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

  test "show? allows the owner only" do
    assert UserListPolicy.new(@user, @list).show?
    refute UserListPolicy.new(users(:admin_user), @list).show?
    refute UserListPolicy.new(nil, @list).show?
  end

  test "show? is owner-only even for public lists (public viewing is 02d)" do
    public_list = user_lists(:regular_user_custom_albums)
    assert public_list.public?
    assert UserListPolicy.new(@user, public_list).show?
    refute UserListPolicy.new(users(:admin_user), public_list).show?
  end

  test "Scope resolves to only the user's own lists" do
    resolved = UserListPolicy::Scope.new(@user, UserList).resolve
    assert resolved.all? { |l| l.user_id == @user.id }
    assert_includes resolved, @list
    refute_includes resolved, user_lists(:admin_user_games_favorites)
  end

  test "Scope returns nothing for an anonymous user" do
    assert_empty UserListPolicy::Scope.new(nil, UserList).resolve
  end
end
