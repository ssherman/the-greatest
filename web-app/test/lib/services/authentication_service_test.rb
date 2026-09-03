require "test_helper"

class AuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    Services::JwtValidationService.reset_cert_cache!
    FirebaseTokenHelper.stub_certs
    @project_id = Rails.application.config.x.firebase_project_id
  end

  def call(token, signup_domain: nil)
    Services::AuthenticationService.call(
      auth_token: token,
      project_id: @project_id,
      signup_domain: signup_domain
    )
  end

  test "authenticates a well-formed token and creates the user" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-new-1",
      "email" => "brand.new@example.com",
      "firebase" => {"sign_in_provider" => "google.com"}
    })

    result = call(token)

    assert result[:success]
    assert_equal "uid-new-1", result[:user].auth_uid
    assert_equal "brand.new@example.com", result[:user].email
    assert_equal "google", result[:user].external_provider
  end

  # F2. The whole class of bug: user_data was client-supplied params, and its
  # email won over the signed claim. This asserts the parameter is gone.
  test "call does not accept a user_data argument at all" do
    assert_raises ArgumentError do
      Services::AuthenticationService.call(
        auth_token: FirebaseTokenHelper.token,
        project_id: @project_id,
        user_data: {"providerData" => [{"providerId" => "password", "email" => "victim@example.com"}]}
      )
    end
  end

  test "provider comes from the token's sign_in_provider, not from a parameter" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-apple-1",
      "email" => "apple.person@example.com",
      "firebase" => {"sign_in_provider" => "apple.com"}
    })

    result = call(token)

    assert result[:success]
    assert_equal "apple", result[:user].external_provider
  end

  test "rejects a provider the app does not model" do
    token = FirebaseTokenHelper.token({"firebase" => {"sign_in_provider" => "anonymous"}})

    result = call(token)

    refute result[:success]
    assert_equal :unsupported_provider, result[:error_code]
  end

  test "rejects a token with no firebase claim" do
    token = FirebaseTokenHelper.token({"firebase" => nil})

    result = call(token)

    refute result[:success]
    assert_equal :unsupported_provider, result[:error_code]
  end

  test "maps an invalid token to invalid_token without raising" do
    result = call(FirebaseTokenHelper.token({"aud" => "another-project"}))

    refute result[:success]
    assert_equal :invalid_token, result[:error_code]
    assert_equal "Invalid authentication token", result[:error]
  end

  test "surfaces the unverified-email conflict as its own error code" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-attacker",
      "email" => users(:regular_user).email,
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "password"}
    })

    result = call(token)

    refute result[:success]
    assert_equal :email_verification_required, result[:error_code]
  end

  test "passes the signup domain through to user creation" do
    token = FirebaseTokenHelper.token({"sub" => "uid-dom-1", "email" => "domain.person@example.com"})

    result = call(token, signup_domain: "thegreatest.games")

    assert result[:success]
    assert_equal "thegreatest.games", result[:user].original_signup_domain
  end

  test "does not log the token payload" do
    logged = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    begin
      call(FirebaseTokenHelper.token({"sub" => "uid-log-1", "email" => "logged.person@example.com"}))
    ensure
      Rails.logger = original
    end

    refute_includes logged.string, "logged.person@example.com"
    refute_includes logged.string, "JWT Payload"
  end

  test "maps a user save failure to user_creation_failed" do
    token = FirebaseTokenHelper.token({"sub" => "uid-no-email", "email" => nil})

    result = call(token)

    refute result[:success]
    assert_equal :user_creation_failed, result[:error_code]
  end

  test "maps an unexpected error to authentication_failed" do
    Services::JwtValidationService.stubs(:call).raises(StandardError.new("boom"))

    result = call(FirebaseTokenHelper.token)

    refute result[:success]
    assert_equal :authentication_failed, result[:error_code]
  end
end
