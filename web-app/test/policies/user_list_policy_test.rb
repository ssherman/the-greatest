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

  test "show? allows a non-owner to view a public list" do
    public_list = user_lists(:regular_user_custom_albums)
    assert public_list.public?
    assert UserListPolicy.new(@user, public_list).show?
    assert UserListPolicy.new(users(:admin_user), public_list).show?
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

  test "show? allows the owner" do
    list = user_lists(:regular_user_books_favorites)
    assert UserListPolicy.new(list.user, list).show?
  end

  test "show? allows anyone to view a public list" do
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    assert UserListPolicy.new(users(:admin_user), list).show?
    assert UserListPolicy.new(nil, list).show?
  end

  test "show? denies a non-owner and an anonymous viewer on a private list" do
    list = user_lists(:regular_user_books_favorites)

    refute UserListPolicy.new(users(:admin_user), list).show?
    refute UserListPolicy.new(nil, list).show?
  end
end
