require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "should be valid with valid attributes" do
    assert users(:regular_user).valid?
  end

  test "should require email" do
    user = User.new(display_name: "Test User", name: "Test User Full Name")
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "should require unique email" do
    user = User.new(email: "user@example.com")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end

  test "should default to user role" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!
    assert user.user?
  end

  test "should accept valid roles" do
    user = users(:regular_user)
    user.role = :admin
    assert user.valid?
    user.role = :editor
    assert user.valid?
  end

  test "should accept valid external providers" do
    user = users(:regular_user)
    user.external_provider = :facebook
    assert user.valid?
    user.external_provider = :google
    assert user.valid?
  end

  test "should default email_verified to false" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!
    assert_not user.email_verified?
  end

  test "should serialize provider_data as JSON" do
    user = users(:regular_user)
    user.provider_data = {"provider_id" => "123", "name" => "John"}
    user.save!
    user.reload
    assert_equal "123", user.provider_data["provider_id"]
    assert_equal "John", user.provider_data["name"]
  end

  test "should have correct role from fixtures" do
    assert users(:admin_user).admin?
    assert users(:regular_user).user?
    assert users(:editor_user).editor?
  end
end
