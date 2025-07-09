require "test_helper"
require_relative "../../../app/lib/services/authentication_service"

class AuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    @valid_token = "valid.jwt.token"
    @valid_payload = {
      "sub" => "google_123",
      "email" => "test@example.com",
      "name" => "Test User",
      "picture" => "https://example.com/photo.jpg",
      "email_verified" => true,
      "auth_time" => 1635729600,
      "iat" => 1635729600,
      "exp" => 1635733200
    }
  end

  test "successfully authenticates with valid token" do
    # Mock JWT validation
    JwtValidationService.stubs(:call).with(@valid_token, project_id: nil).returns(@valid_payload)

    # Mock user authentication
    mock_user = mock
    UserAuthenticationService.stubs(:call).with(provider_data: anything).returns(mock_user)

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google
    )

    assert result[:success]
    assert_equal mock_user, result[:user]
    assert_equal :google, result[:provider_data][:provider]
    assert_equal "google_123", result[:provider_data][:user_id]
    assert_equal "test@example.com", result[:provider_data][:email]
  end

  test "validates project_id when provided" do
    # Mock JWT validation with project_id
    JwtValidationService.stubs(:call).with(@valid_token, project_id: "test-project").returns(@valid_payload)

    # Mock user authentication
    mock_user = mock
    UserAuthenticationService.stubs(:call).with(provider_data: anything).returns(mock_user)

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google,
      project_id: "test-project"
    )

    assert result[:success]
  end

  test "handles JWT validation failure" do
    # Mock JWT validation failure
    JwtValidationService.stubs(:call).raises(JWT::DecodeError.new("Invalid token"))

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google
    )

    assert_not result[:success]
    assert_equal "Invalid authentication token", result[:error]
    assert_equal :invalid_token, result[:error_code]
  end

  test "handles user creation failure" do
    # Mock JWT validation success
    JwtValidationService.stubs(:call).with(@valid_token, project_id: nil).returns(@valid_payload)

    # Mock user authentication failure
    UserAuthenticationService.stubs(:call).raises(ActiveRecord::RecordInvalid.new(User.new))

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google
    )

    assert_not result[:success]
    assert_equal "Failed to create user account", result[:error]
    assert_equal :user_creation_failed, result[:error_code]
  end

  test "handles general authentication failure" do
    # Mock JWT validation success
    JwtValidationService.stubs(:call).with(@valid_token, project_id: nil).returns(@valid_payload)

    # Mock user authentication with general error
    UserAuthenticationService.stubs(:call).raises(StandardError.new("Database connection failed"))

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google
    )

    assert_not result[:success]
    assert_equal "Authentication failed", result[:error]
    assert_equal :authentication_failed, result[:error_code]
  end

  test "extracts provider data correctly" do
    # Mock JWT validation
    JwtValidationService.stubs(:call).with(@valid_token, project_id: nil).returns(@valid_payload)

    # Mock user authentication
    mock_user = mock
    UserAuthenticationService.stubs(:call).with(provider_data: anything).returns(mock_user)

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google
    )

    provider_data = result[:provider_data]
    assert_equal "google_123", provider_data[:user_id]
    assert_equal "test@example.com", provider_data[:email]
    assert_equal "Test User", provider_data[:name]
    assert_equal "https://example.com/photo.jpg", provider_data[:picture]
    assert provider_data[:email_verified]
    assert_equal :google, provider_data[:provider]
    assert_equal 1635729600, provider_data[:auth_time]
    assert_equal 1635729600, provider_data[:iat]
    assert_equal 1635733200, provider_data[:exp]
  end

  test "handles missing optional fields in payload" do
    minimal_payload = {
      "sub" => "google_123",
      "email" => "test@example.com"
    }

    # Mock JWT validation
    JwtValidationService.stubs(:call).with(@valid_token, project_id: nil).returns(minimal_payload)

    # Mock user authentication
    mock_user = mock
    UserAuthenticationService.stubs(:call).with(provider_data: anything).returns(mock_user)

    result = AuthenticationService.call(
      auth_token: @valid_token,
      provider: :google
    )

    assert result[:success]
    provider_data = result[:provider_data]
    assert_equal "google_123", provider_data[:user_id]
    assert_equal "test@example.com", provider_data[:email]
    assert_nil provider_data[:name]
    assert_nil provider_data[:picture]
    assert_nil provider_data[:email_verified]
  end
end
