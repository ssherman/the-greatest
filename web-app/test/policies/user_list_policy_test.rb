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

  test "an anonymous visitor does not own an unsaved list" do
    list = UserList.new
    refute UserListPolicy.new(nil, list).owner?
    refute UserListPolicy.new(nil, list).update?
    refute UserListPolicy.new(nil, list).destroy?
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

  test "update? and destroy? allow the owner" do
    assert UserListPolicy.new(@user, @list).update?
    assert UserListPolicy.new(@user, @list).destroy?
  end

  test "update? and edit? refuse a global admin or editor who does not own the list" do
    [users(:admin_user), users(:editor_user)].each do |staff|
      refute UserListPolicy.new(staff, @list).update?, "#{staff.email} must not update another user's list"
      refute UserListPolicy.new(staff, @list).edit?, "#{staff.email} must not edit another user's list"
    end
  end

  # Decided 2026-10-01 (Shane): an admin can delete anything, a user list included.
  test "destroy? allows a global admin on a list they do not own" do
    assert UserListPolicy.new(users(:admin_user), @list).destroy?
  end

  test "destroy? refuses a global editor who does not own the list" do
    refute UserListPolicy.new(users(:editor_user), @list).destroy?
  end

  test "update? and destroy? refuse an anonymous visitor" do
    refute UserListPolicy.new(nil, @list).update?
    refute UserListPolicy.new(nil, @list).destroy?
  end
end
