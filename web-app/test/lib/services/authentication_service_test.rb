require "test_helper"

class AuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    @valid_payload = {
      "sub" => "user123",
      "email" => "test@example.com",
      "name" => "Test User",
      "picture" => "https://example.com/photo.jpg",
      "email_verified" => true,
      "auth_time" => Time.current.to_i,
      "iat" => Time.current.to_i,
      "exp" => (Time.current + 1.hour).to_i
    }
  end

  test "successfully authenticates with valid token" do
    # Mock JWT validation
    Services::JwtValidationService.stubs(:call).returns(@valid_payload)

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "google"
    )

    assert result[:success]
    assert_equal "user123", result[:user].auth_uid
    assert_equal "test@example.com", result[:user].email
    assert_equal "google", result[:user].external_provider
  end

  test "validates project_id when provided" do
    # Mock JWT validation with project_id validation
    Services::JwtValidationService.stubs(:call).returns(@valid_payload)

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "google",
      project_id: "test-project"
    )

    assert result[:success]
  end

  test "handles JWT validation failure" do
    Services::JwtValidationService.stubs(:call).raises(JWT::DecodeError.new("Invalid token"))

    result = Services::AuthenticationService.call(
      auth_token: "invalid.jwt.token",
      provider: "google"
    )

    refute result[:success]
    assert_equal "Invalid authentication token", result[:error]
    assert_equal :invalid_token, result[:error_code]
  end

  test "handles user creation failure" do
    # Mock JWT validation to succeed
    Services::JwtValidationService.stubs(:call).returns(@valid_payload)

    # Mock user save to fail
    User.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(User.new))

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "google"
    )

    refute result[:success]
    assert_equal "Failed to create user account", result[:error]
    assert_equal :user_creation_failed, result[:error_code]
  end

  test "handles general authentication failure" do
    Services::JwtValidationService.stubs(:call).raises(StandardError.new("Unexpected error"))

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "google"
    )

    refute result[:success]
    assert_equal "Authentication failed", result[:error]
    assert_equal :authentication_failed, result[:error_code]
  end

  test "extracts provider data correctly" do
    # Mock JWT validation
    Services::JwtValidationService.stubs(:call).returns(@valid_payload)

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "google"
    )

    assert result[:success]
    provider_data = result[:provider_data]

    assert_equal "user123", provider_data[:user_id]
    assert_equal "test@example.com", provider_data[:email]
    assert_equal "Test User", provider_data[:name]
    assert_equal "https://example.com/photo.jpg", provider_data[:picture]
    assert provider_data[:email_verified]
    assert_equal "google", provider_data[:provider]
    assert provider_data[:auth_time]
    assert provider_data[:iat]
    assert provider_data[:exp]
  end

  test "extracts provider data from password provider user_data" do
    Services::JwtValidationService.stubs(:call).returns(@valid_payload)

    user_data = {
      "providerData" => [
        {
          "providerId" => "password",
          "uid" => "passworduser@example.com",
          "email" => "passworduser@example.com"
        }
      ],
      "displayName" => nil,
      "photoURL" => nil,
      "emailVerified" => false
    }

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "password",
      user_data: user_data
    )

    assert result[:success]
    assert_equal "passworduser@example.com", result[:provider_data][:email]
    assert_equal "password", result[:provider_data][:provider]
  end

  test "handles missing optional fields in payload" do
    minimal_payload = {
      "sub" => "user123",
      "email" => "test@example.com"
    }

    Services::JwtValidationService.stubs(:call).returns(minimal_payload)

    result = Services::AuthenticationService.call(
      auth_token: "valid.jwt.token",
      provider: "google"
    )

    assert result[:success]
    provider_data = result[:provider_data]

    assert_equal "user123", provider_data[:user_id]
    assert_equal "test@example.com", provider_data[:email]
    assert_nil provider_data[:name]
    assert_nil provider_data[:picture]
    assert_equal false, provider_data[:email_verified]
    assert_equal "google", provider_data[:provider]
  end
end
