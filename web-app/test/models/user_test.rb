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

  # Email confirmation tests
  test "should not be confirmed by default" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!
    assert_not user.confirmed?
  end

  test "should generate confirmation token" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!

    user.generate_confirmation_token!

    assert user.confirmation_token.present?
    assert user.confirmation_sent_at.present?
    assert_equal 32, Base64.urlsafe_decode64(user.confirmation_token).length
  end

  test "should confirm email" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!
    user.generate_confirmation_token!

    user.confirm_email!

    assert user.confirmed?
    assert user.email_verified?
    assert_nil user.confirmation_token
    assert user.confirmed_at.present?
  end

  test "should detect expired confirmation token" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!
    user.generate_confirmation_token!

    # Should not be expired immediately
    assert_not user.confirmation_token_expired?

    # Travel to 25 hours later
    travel 25.hours do
      assert user.confirmation_token_expired?
    end
  end

  test "should not expire token if confirmation_sent_at is nil" do
    user = User.new(email: "newuser@example.com", display_name: "New User")
    user.save!

    assert_not user.confirmation_token_expired?
  end

  test "should require unique confirmation token" do
    user1 = User.create!(email: "user1@example.com", display_name: "User 1")
    user2 = User.create!(email: "user2@example.com", display_name: "User 2")

    user1.generate_confirmation_token!
    token = user1.confirmation_token

    # Try to set the same token on user2
    user2.confirmation_token = token
    assert_not user2.valid?
    assert_includes user2.errors[:confirmation_token], "has already been taken"
  end
end
