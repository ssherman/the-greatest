require "test_helper"

class AuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    Services::JwtValidationService.reset_cert_cache!
    FirebaseTokenHelper.stub_certs
    @project_id = Rails.application.config.x.firebase_project_id
    stub_account_lookup_empty
  end

  # AuthenticationService now builds a real ProviderEmailResolver on every
  # call, which -- on an auth_uid miss -- reaches Identity Toolkit. Every
  # pre-existing test in this file predates that and expects the token's own
  # `email` claim to win, so the default here makes the provider-record
  # lookup find nothing, which is exactly what makes the resolver fall back
  # to that claim. GoogleServiceAccountToken.access_token is stubbed (not
  # FirebaseAccountLookup.call itself) and the lookup endpoint is stubbed
  # with WebMock rather than mocked away, so the REAL accounts:lookup code
  # path still runs -- which is what lets "a token minting failure refuses
  # the sign-in with the same code" below override just the token stub and
  # see that error travel the real path into the rescue clause.
  def stub_account_lookup_empty
    Services::GoogleServiceAccountToken.stubs(:access_token).returns("test-service-account-token")
    WebMock.stub_request(:post, %r{\Ahttps://identitytoolkit\.googleapis\.com/v1/projects/[^/]+/accounts:lookup\z})
      .to_return(
        status: 200,
        body: {users: []}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
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

  # F1. The guard's real question is not "did the token say verified" but
  # "could someone have registered this address at this provider without
  # controlling it". For X the answer is no -- it verifies by confirmation
  # mail -- but Firebase sends no flag saying so.
  test "a trusted OAuth provider is email-trusted even when the claim is false" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-x-1",
      "email" => "x.person@example.com",
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "twitter.com"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert result[:provider_data][:email_trusted], "twitter.com must be email-trusted"
    refute result[:provider_data][:email_verified],
      "the raw claim must still be recorded as false"
  end

  test "every trusted provider is trusted with a false claim" do
    # Without this, emptying TRUSTED_EMAIL_PROVIDERS would make the loop
    # below iterate zero times and the test would pass with zero assertions.
    refute_empty Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS

    Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS.each_with_index do |sign_in_provider, i|
      token = FirebaseTokenHelper.token({
        "sub" => "uid-trusted-#{i}",
        "email" => "trusted#{i}@example.com",
        "email_verified" => false,
        "firebase" => {"sign_in_provider" => sign_in_provider}
      })

      result = call(token)

      assert result[:success], "#{sign_in_provider}: #{result[:error]}"
      assert result[:provider_data][:email_trusted], "#{sign_in_provider} must be email-trusted"
    end
  end

  test "password is never email-trusted on a false claim" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-pw-untrusted",
      "email" => "pw.person@example.com",
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "password"}
    })

    result = call(token)

    assert result[:success], result[:error]
    refute result[:provider_data][:email_trusted],
      "a Firebase password account can be created for any address without " \
      "proving control -- this is the takeover vector the guard blocks"
  end

  test "password IS email-trusted once the claim is genuinely true" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-pw-verified",
      "email" => "pw.verified@example.com",
      "email_verified" => true,
      "firebase" => {"sign_in_provider" => "password"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert result[:provider_data][:email_trusted]
  end

  test "the trusted list never contains password" do
    refute_includes Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS, "password"
  end

  # The provider's own user id (X's numeric id, Facebook's app-scoped id) lives
  # under the firebase claim's identities map, keyed by sign_in_provider, as an
  # array. It is the only reconnection key for an email-less OAuth user, so it
  # must survive extraction even though nothing upstream of this claim is ever
  # trusted input.
  test "captures the provider's own user id from the firebase identities claim" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-provider-uid-1",
      "email" => "provider.uid.person@example.com",
      "firebase" => {
        "sign_in_provider" => "twitter.com",
        "identities" => {"twitter.com" => ["1406121503133888515"]}
      }
    })

    result = call(token)

    assert result[:success], result[:error]
    assert_equal "1406121503133888515", result[:provider_data][:provider_uid]
  end

  test "a token with no identities claim yields no provider_uid" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-provider-uid-2",
      "email" => "no.identities@example.com",
      "firebase" => {"sign_in_provider" => "twitter.com"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert_nil result[:provider_data][:provider_uid]
  end

  test "a token with an empty identities array for the provider yields no provider_uid" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-provider-uid-3",
      "email" => "empty.identities@example.com",
      "firebase" => {
        "sign_in_provider" => "twitter.com",
        "identities" => {"twitter.com" => []}
      }
    })

    result = call(token)

    assert result[:success], result[:error]
    assert_nil result[:provider_data][:provider_uid]
  end

  # --- Provider email resolution ---

  test "builds a resolver from the token's sub and sign_in_provider" do
    payload = {
      "sub" => "uid_1",
      "firebase" => {"sign_in_provider" => "facebook.com", "identities" => {"facebook.com" => ["1016"]}},
      "email" => "claim@example.com"
    }
    Services::JwtValidationService.stubs(:call).returns(payload)

    Services::ProviderEmailResolver.expects(:new).with(
      uid: "uid_1",
      sign_in_provider: "facebook.com",
      project_id: "the-greatest-books",
      fallback_email: "claim@example.com"
    ).returns(stub(call: "resolved@example.com"))

    Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")
  end

  test "a lookup failure refuses the sign-in with a retriable code" do
    payload = {
      "sub" => "uid_1",
      "firebase" => {"sign_in_provider" => "facebook.com"}
    }
    Services::JwtValidationService.stubs(:call).returns(payload)
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::FirebaseAccountLookup::Error, "boom")

    result = Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")

    assert_equal false, result[:success]
    assert_equal :account_lookup_failed, result[:error_code],
      "must not be swallowed by the catch-all rescue into :authentication_failed"
  end

  test "a token minting failure refuses the sign-in with the same code" do
    payload = {
      "sub" => "uid_1",
      "firebase" => {"sign_in_provider" => "facebook.com"}
    }
    Services::JwtValidationService.stubs(:call).returns(payload)
    Services::GoogleServiceAccountToken.stubs(:access_token)
      .raises(Services::GoogleServiceAccountToken::Error, "no credential")

    result = Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")

    assert_equal :account_lookup_failed, result[:error_code]
  end

  test "a refused sign-in creates no user row" do
    payload = {
      "sub" => "uid_never_seen",
      "firebase" => {"sign_in_provider" => "facebook.com"}
    }
    Services::JwtValidationService.stubs(:call).returns(payload)
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::FirebaseAccountLookup::Error, "boom")

    assert_no_difference "User.count" do
      Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")
    end
  end
end
