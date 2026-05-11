require "test_helper"

class UserListItemPolicyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:regular_user)
    @other = users(:editor_user)
    @item = user_list_items(:regular_user_fav_album_1)
  end

  test "create? allowed for owner" do
    assert UserListItemPolicy.new(@owner, @item).create?
  end

  test "create? denied for non-owner" do
    refute UserListItemPolicy.new(@other, @item).create?
  end

  test "create? denied for anonymous" do
    refute UserListItemPolicy.new(nil, @item).create?
  end

  test "destroy? mirrors create?" do
    assert UserListItemPolicy.new(@owner, @item).destroy?
    refute UserListItemPolicy.new(@other, @item).destroy?
    refute UserListItemPolicy.new(nil, @item).destroy?
  end
end
