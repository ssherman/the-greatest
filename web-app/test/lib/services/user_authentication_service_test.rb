require "test_helper"
require_relative "../../../app/lib/services/user_authentication_service"

class UserAuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    @google_provider_data = {
      email: "test@example.com",
      user_id: "google_123",
      name: "Test User",
      picture: "https://example.com/photo.jpg",
      email_verified: true,
      provider: :google
    }
  end

  test "creates a new user when user does not exist" do
    result = UserAuthenticationService.call(provider_data: @google_provider_data)

    assert result.persisted?
    assert_equal "test@example.com", result.email
    assert_equal "google_123", result.auth_uid
    assert_equal "Test User", result.display_name
    assert_equal "https://example.com/photo.jpg", result.photo_url
    assert_equal "google", result.external_provider
    assert result.email_verified?
    assert_equal "user", result.role
    assert_equal 1, result.sign_in_count
    assert result.last_sign_in_at.present?
    assert_equal "google", result.provider_data.keys.first
  end

  test "finds existing user by email and updates" do
    # Create existing user
    existing_user = User.create!(
      email: "test@example.com",
      display_name: "Old Name",
      role: :user
    )

    result = UserAuthenticationService.call(provider_data: @google_provider_data)

    assert_equal existing_user.id, result.id
    assert_equal "google_123", result.auth_uid
    assert_equal "Test User", result.display_name
    assert_equal "https://example.com/photo.jpg", result.photo_url
    assert_equal "google", result.external_provider
    assert result.email_verified?
    assert_equal 1, result.sign_in_count
    assert result.last_sign_in_at.present?
  end

  test "finds existing user by auth_uid and updates" do
    # Create existing user with different email but same auth_uid
    existing_user = User.create!(
      email: "different@example.com",
      auth_uid: "google_123",
      display_name: "Old Name",
      role: :user
    )

    result = UserAuthenticationService.call(provider_data: @google_provider_data)

    assert_equal existing_user.id, result.id
    assert_equal "different@example.com", result.email  # Email should not change
    assert_equal "Test User", result.display_name
    assert_equal 1, result.sign_in_count
  end

  test "increments sign_in_count for existing users" do
    User.create!(
      email: "test@example.com",
      sign_in_count: 5,
      role: :user
    )

    result = UserAuthenticationService.call(provider_data: @google_provider_data)

    assert_equal 6, result.sign_in_count
  end

  test "handles case insensitive email matching" do
    existing_user = User.create!(
      email: "TEST@EXAMPLE.COM",
      role: :user
    )

    result = UserAuthenticationService.call(provider_data: @google_provider_data)

    assert_equal existing_user.id, result.id
  end

  test "stores provider data correctly" do
    result = UserAuthenticationService.call(provider_data: @google_provider_data)

    assert_equal "google", result.provider_data.keys.first
    assert_equal @google_provider_data[:user_id], result.provider_data["google"]["user_id"]
    assert_equal @google_provider_data[:email], result.provider_data["google"]["email"]
  end

  test "handles missing optional fields" do
    minimal_data = {
      email: "minimal@example.com",
      user_id: "minimal_123",
      provider: :google
    }

    result = UserAuthenticationService.call(provider_data: minimal_data)

    assert result.persisted?
    assert_equal "minimal@example.com", result.email
    assert_equal "minimal_123", result.auth_uid
    assert_nil result.display_name
    assert_nil result.photo_url
    assert_not result.email_verified?
  end

  test "raises error for invalid user data" do
    invalid_data = {
      email: nil, # Required field
      user_id: "test_123",
      provider: :google
    }

    assert_raises ActiveRecord::RecordInvalid do
      UserAuthenticationService.call(provider_data: invalid_data)
    end
  end

  test "preserves existing email_verified status if not provided" do
    User.create!(
      email: "test@example.com",
      email_verified: true,
      role: :user
    )

    data_without_verification = @google_provider_data.merge(email_verified: nil)
    result = UserAuthenticationService.call(provider_data: data_without_verification)

    assert result.email_verified?
  end

  test "updates email_verified status when provided" do
    User.create!(
      email: "test@example.com",
      email_verified: false,
      role: :user
    )

    data_with_verification = @google_provider_data.merge(email_verified: true)
    result = UserAuthenticationService.call(provider_data: data_with_verification)

    assert result.email_verified?
  end

  test "raises error if provider is missing" do
    data = {
      email: "test@example.com",
      user_id: "google_123"
    }
    assert_raises ArgumentError do
      UserAuthenticationService.call(provider_data: data)
    end
  end
end
