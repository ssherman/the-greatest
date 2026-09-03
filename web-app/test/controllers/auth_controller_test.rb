require "test_helper"

class AuthControllerTest < ActionDispatch::IntegrationTest
  def setup
    Services::JwtValidationService.reset_cert_cache!
    FirebaseTokenHelper.stub_certs
  end

  test "signs in with a valid token and returns the user" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-ctrl-1",
      "email" => "ctrl.one@example.com",
      "firebase" => {"sign_in_provider" => "password"}
    })

    post auth_sign_in_path, params: {jwt: token}, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "ctrl.one@example.com", body["user"]["email"]
    assert_equal "password", body["user"]["provider"]
  end

  test "rejects a missing jwt" do
    post auth_sign_in_path, params: {}, as: :json

    assert_response :unauthorized
    refute JSON.parse(response.body)["success"]
  end

  # F2 end to end: the payload that used to grant takeover must now be inert.
  test "a client-supplied user_data email cannot claim another user's account" do
    victim = users(:google_user)
    token = FirebaseTokenHelper.token({
      "sub" => "attacker-uid",
      "email" => "attacker@example.com",
      "firebase" => {"sign_in_provider" => "password"}
    })

    post auth_sign_in_path, params: {
      jwt: token,
      provider: "password",
      user_data: {"providerData" => [{"providerId" => "password", "email" => victim.email}]}
    }, as: :json

    assert_response :success
    victim.reload
    assert_equal "firebase-google-uid-456", victim.auth_uid
    refute_equal victim.id, JSON.parse(response.body)["user"]["id"]
  end

  test "rejects a token minted for another Firebase project" do
    post auth_sign_in_path, params: {jwt: FirebaseTokenHelper.token({"aud" => "other-project"})}, as: :json

    assert_response :unauthorized
    assert_equal "Invalid authentication token", JSON.parse(response.body)["error"]
  end

  test "rejects an alg=none token" do
    post auth_sign_in_path, params: {jwt: FirebaseTokenHelper.token({}, alg: "none")}, as: :json

    assert_response :unauthorized
  end

  test "returns email_verification_required when an unverified email hits an existing account" do
    token = FirebaseTokenHelper.token({
      "sub" => "attacker-uid-2",
      "email" => users(:google_user).email,
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "password"}
    })

    post auth_sign_in_path, params: {jwt: token}, as: :json

    assert_response :unauthorized
    assert_equal "email_verification_required", JSON.parse(response.body)["error_code"]
  end

  # F3. Comparing the raw session cookie (as the sign-out test below does)
  # doesn't work here: sign_in unconditionally writes to `session`, so a
  # freshly (re-)encrypted cookie goes out whether or not reset_session ran --
  # and this app has no page that establishes a session before authentication
  # (public pages are edge-cached and deliberately carry no per-visitor
  # session state), so there's no real pre-auth cookie to capture as "before"
  # either way. What reset_session actually changes is the session id
  # CookieStore embeds *inside* the encrypted payload: an ordinary write
  # preserves whatever id was already there, and only reset_session (via
  # Rack's delete_session) replaces it. So this establishes a real prior
  # session with one sign-in, then confirms a second sign-in rotates that
  # embedded id rather than just re-encrypting the same one.
  test "rotates the session id on sign in" do
    post auth_sign_in_path, params: {
      jwt: FirebaseTokenHelper.token({"sub" => "uid-fix-1a", "email" => "fix.one.a@example.com"})
    }, as: :json
    before = request.session.id.public_id

    post auth_sign_in_path, params: {
      jwt: FirebaseTokenHelper.token({"sub" => "uid-fix-1", "email" => "fix.one@example.com"})
    }, as: :json

    assert_response :success
    refute_equal before, request.session.id.public_id, "session id must rotate to prevent fixation"
  end

  # Comparing raw cookie bytes here has the same flaw the sign-in test above
  # documents in detail: a mutation back to the pre-fix body
  # (`session[:user_id] = nil; session[:provider] = nil`) still *writes* to
  # `session`, so it still re-emits a freshly (re-)encrypted cookie and the
  # raw-bytes comparison stays green even with fixation fully reopened.
  # Comparing CookieStore's internal session id (only replaced by
  # reset_session's delete_session, preserved by an ordinary write) is what
  # actually distinguishes the two.
  test "rotates the session id on sign out" do
    post auth_sign_in_path, params: {
      jwt: FirebaseTokenHelper.token({"sub" => "uid-fix-2", "email" => "fix.two@example.com"})
    }, as: :json
    before = request.session.id.public_id

    post auth_sign_out_path, as: :json

    assert_response :success
    refute_equal before, request.session.id.public_id, "session id must rotate to prevent fixation"
  end

  test "records the request host as the signup domain for a new user" do
    post auth_sign_in_path,
      params: {jwt: FirebaseTokenHelper.token({"sub" => "uid-host-1", "email" => "host.one@example.com"})},
      headers: {"HOST" => "dev.thegreatest.games"},
      as: :json

    assert_response :success
    assert_equal "dev.thegreatest.games", User.find_by(auth_uid: "uid-host-1").original_signup_domain
  end

  # check_provider's asymmetry -- disclose an OAuth provider, never disclose
  # that a password account exists -- IS the security control (avoids email
  # enumeration of password accounts). These tests restore coverage the Task 6
  # brief's full-file replacement silently dropped.
  test "check_provider returns the neutral body for a blank email" do
    post auth_check_provider_path, params: {email: ""}, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    refute body["has_oauth_provider"]
    assert_nil body["provider"]
    assert_nil body["message"]
  end

  test "check_provider discloses the provider for an OAuth account" do
    post auth_check_provider_path, params: {email: users(:google_user).email}, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["has_oauth_provider"]
    assert_equal "google", body["provider"]
  end

  test "check_provider discloses nothing for a password account" do
    post auth_check_provider_path, params: {email: users(:password_user).email}, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    refute body["has_oauth_provider"]
    assert_nil body["provider"]
    assert_nil body["message"]
  end

  test "check_provider is indistinguishable between a password account and no account at all" do
    post auth_check_provider_path, params: {email: users(:password_user).email}, as: :json
    password_body = JSON.parse(response.body)

    post auth_check_provider_path, params: {email: "no-such-account@example.com"}, as: :json
    no_account_body = JSON.parse(response.body)

    assert_response :success
    assert_equal password_body, no_account_body
  end

  test "check_provider looks up the email case-insensitively" do
    post auth_check_provider_path, params: {email: users(:google_user).email.upcase}, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["has_oauth_provider"]
    assert_equal "google", body["provider"]
  end
end
