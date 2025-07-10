require "test_helper"

class AuthControllerTest < ActionDispatch::IntegrationTest
  def setup
    @valid_jwt = "valid.jwt.token"
    @valid_provider = "google"
  end

  test "should authenticate with valid JWT and provider" do
    # Mock the authentication service
    mock_result = {
      success: true,
      user: User.new(id: 1, email: "test@example.com", name: "Test User"),
      provider_data: {provider: "google"}
    }

    Services::AuthenticationService.stubs(:call).returns(mock_result)

    post auth_sign_in_path, params: {
      jwt: @valid_jwt,
      provider: @valid_provider
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["success"]
    assert_equal 1, json_response["user"]["id"]
    assert_equal "test@example.com", json_response["user"]["email"]
    assert_equal "google", json_response["user"]["provider"]
  end

  test "should reject missing JWT" do
    post auth_sign_in_path, params: {provider: @valid_provider}

    assert_response :unauthorized
    json_response = JSON.parse(response.body)
    refute json_response["success"]
    assert_equal "Missing jwt or provider parameter", json_response["error"]
  end

  test "should reject missing provider" do
    post auth_sign_in_path, params: {jwt: @valid_jwt}

    assert_response :unauthorized
    json_response = JSON.parse(response.body)
    refute json_response["success"]
    assert_equal "Missing jwt or provider parameter", json_response["error"]
  end

  test "should reject invalid JWT" do
    # Mock authentication service failure
    mock_result = {
      success: false,
      error: "Invalid authentication token",
      error_code: :invalid_token
    }

    Services::AuthenticationService.stubs(:call).returns(mock_result)

    post auth_sign_in_path, params: {
      jwt: "invalid.jwt.token",
      provider: @valid_provider
    }

    assert_response :unauthorized
    json_response = JSON.parse(response.body)
    refute json_response["success"]
    assert_equal "Invalid authentication token", json_response["error"]
  end

  test "should handle authentication service errors" do
    # Mock authentication service to raise an exception
    Services::AuthenticationService.stubs(:call).raises(StandardError.new("Service error"))

    post auth_sign_in_path, params: {
      jwt: @valid_jwt,
      provider: @valid_provider
    }

    assert_response :internal_server_error
    json_response = JSON.parse(response.body)
    refute json_response["success"]
    assert_equal "Authentication failed", json_response["error"]
  end

  test "should sign out successfully" do
    # Set up a session first
    post auth_sign_in_path, params: {
      jwt: @valid_jwt,
      provider: @valid_provider
    }

    # Then sign out
    post auth_sign_out_path

    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["success"]
  end
end
