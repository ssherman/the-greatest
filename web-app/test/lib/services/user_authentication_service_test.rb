require "test_helper"

class UserAuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    @provider_data = {
      user_id: "google_123",
      email: "test@example.com",
      name: "Test User",
      picture: "https://example.com/photo.jpg",
      email_verified: true,
      provider: "google",
      auth_time: Time.current.to_i,
      iat: Time.current.to_i,
      exp: (Time.current + 1.hour).to_i
    }
  end

  test "creates a new user when user does not exist" do
    assert_difference "User.count", 1 do
      user = Services::UserAuthenticationService.call(provider_data: @provider_data)

      assert_equal "google_123", user.auth_uid
      assert_equal "test@example.com", user.email
      assert_equal "Test User", user.display_name
      assert_equal "https://example.com/photo.jpg", user.photo_url
      assert_equal "google", user.external_provider
      assert user.email_verified
      assert_equal "user", user.role
      assert_not_nil user.last_sign_in_at
      assert_equal 1, user.sign_in_count
    end
  end

  test "finds existing user by email and updates" do
    existing_user = User.create!(
      email: "test@example.com",
      display_name: "Old Name",
      external_provider: "facebook"
    )

    user = Services::UserAuthenticationService.call(provider_data: @provider_data)

    assert_equal existing_user.id, user.id
    assert_equal "google_123", user.auth_uid
    assert_equal "test@example.com", user.email
    assert_equal "Test User", user.display_name
    assert_equal "https://example.com/photo.jpg", user.photo_url
    assert_equal "google", user.external_provider
    assert user.email_verified
    assert_equal 1, user.sign_in_count
  end

  test "finds existing user by auth_uid and updates" do
    existing_user = User.create!(
      email: "different@example.com",
      auth_uid: "google_123",
      display_name: "Old Name",
      external_provider: "facebook"
    )

    user = Services::UserAuthenticationService.call(provider_data: @provider_data)

    assert_equal existing_user.id, user.id
    assert_equal "google_123", user.auth_uid
    assert_equal "different@example.com", user.email  # Email should not change
    assert_equal "Test User", user.display_name
    assert_equal "https://example.com/photo.jpg", user.photo_url
    assert_equal "google", user.external_provider
    assert user.email_verified
    assert_equal 1, user.sign_in_count
  end

  test "increments sign_in_count for existing users" do
    User.create!(
      email: "test@example.com",
      sign_in_count: 5
    )

    user = Services::UserAuthenticationService.call(provider_data: @provider_data)

    assert_equal 6, user.sign_in_count
  end

  test "handles case insensitive email matching" do
    existing_user = User.create!(
      email: "TEST@EXAMPLE.COM",
      display_name: "Old Name"
    )

    user = Services::UserAuthenticationService.call(provider_data: @provider_data)

    assert_equal existing_user.id, user.id
    assert_equal "test@example.com", user.email.downcase
  end

  test "stores provider data correctly" do
    user = Services::UserAuthenticationService.call(provider_data: @provider_data)

    assert_not_nil user.provider_data
    provider_data = user.provider_data["google"] || user.provider_data[:google]
    if provider_data.nil?
      flunk "provider_data is nil; actual provider_data hash: #{user.provider_data.inspect}"
    end

    assert_equal @provider_data[:user_id], provider_data["user_id"]
    assert_equal @provider_data[:email], provider_data["email"]
    assert_equal @provider_data[:name], provider_data["name"]
    assert_equal @provider_data[:picture], provider_data["picture"]
    assert_equal @provider_data[:email_verified], provider_data["email_verified"]
    assert_equal @provider_data[:provider], provider_data["provider"]
  end

  test "handles missing optional fields" do
    minimal_data = {
      user_id: "google_123",
      email: "test@example.com",
      provider: "google"
    }

    user = Services::UserAuthenticationService.call(provider_data: minimal_data)

    assert_equal "google_123", user.auth_uid
    assert_equal "test@example.com", user.email
    assert_nil user.display_name
    assert_nil user.photo_url
    assert_equal "google", user.external_provider
    assert_not user.email_verified
  end

  test "preserves existing email_verified status if not provided" do
    User.create!(
      email: "test@example.com",
      email_verified: true
    )

    minimal_data = {
      user_id: "google_123",
      email: "test@example.com",
      provider: "google"
    }

    user = Services::UserAuthenticationService.call(provider_data: minimal_data)

    assert user.email_verified  # Should preserve existing true value
  end

  test "updates email_verified status when provided" do
    User.create!(
      email: "test@example.com",
      email_verified: false
    )

    user = Services::UserAuthenticationService.call(provider_data: @provider_data)

    assert user.email_verified  # Should update to true from provider data
  end

  test "raises error for invalid user data" do
    invalid_data = @provider_data.merge(email: nil)

    assert_raises ActiveRecord::RecordInvalid do
      Services::UserAuthenticationService.call(provider_data: invalid_data)
    end
  end

  test "raises error if provider is missing" do
    data_without_provider = @provider_data.except(:provider)

    assert_raises ArgumentError do
      Services::UserAuthenticationService.call(provider_data: data_without_provider)
    end
  end
end
