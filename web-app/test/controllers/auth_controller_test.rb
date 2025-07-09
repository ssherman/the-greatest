require "test_helper"
require "minitest/mock"
require Rails.root.join("app/lib/services/authentication_service")

class AuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    @valid_jwt = "valid.jwt.token"
    @invalid_jwt = "invalid.jwt.token"
  end

  test "should authenticate with valid JWT and provider" do
    mock_result = {
      success: true,
      user: @user,
      provider_data: {}
    }
    AuthenticationService.stub(:call, mock_result) do
      post auth_sign_in_url, params: {
        jwt: @valid_jwt,
        provider: "google"
      }
    end
    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["success"]
    assert_equal @user.id, response_data["user"]["id"]
    assert_equal @user.email, response_data["user"]["email"]
    assert_equal "google", response_data["user"]["provider"]
  end

  test "should reject invalid JWT" do
    mock_result = {
      success: false,
      error: "Invalid JWT token"
    }
    AuthenticationService.stub(:call, mock_result) do
      post auth_sign_in_url, params: {
        jwt: @invalid_jwt,
        provider: "google"
      }
    end
    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    refute response_data["success"]
    assert_equal "Invalid JWT token", response_data["error"]
  end

  test "should handle missing JWT parameter" do
    post auth_sign_in_url, params: {provider: "google"}
    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    refute response_data["success"]
  end

  test "should handle missing provider parameter" do
    post auth_sign_in_url, params: {jwt: @valid_jwt}
    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    refute response_data["success"]
  end

  test "should handle authentication service errors" do
    AuthenticationService.stub(:call, ->(*) { raise StandardError, "Service error" }) do
      post auth_sign_in_url, params: {
        jwt: @valid_jwt,
        provider: "google"
      }
    end
    assert_response :internal_server_error
    response_data = JSON.parse(response.body)
    refute response_data["success"]
    assert_equal "Authentication failed", response_data["error"]
  end

  test "should sign out successfully" do
    post auth_sign_out_url
    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["success"]
  end

  test "should sign out even without existing session" do
    post auth_sign_out_url
    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["success"]
  end
end
