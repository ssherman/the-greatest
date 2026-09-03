require "test_helper"

class UserAuthenticationServiceTest < ActiveSupport::TestCase
  def provider_data(overrides = {})
    {
      user_id: "google_123",
      email: "test@example.com",
      name: "Test User",
      picture: "https://example.com/photo.jpg",
      email_verified: true,
      provider: "google",
      auth_time: Time.current.to_i,
      iat: Time.current.to_i,
      exp: (Time.current + 1.hour).to_i
    }.merge(overrides)
  end

  # signup_domain: nil, **overrides (not overrides = {}, signup_domain: nil):
  # since this method declares a real keyword param, Ruby's keyword/positional
  # split means a bare call(user_id: ..., email: ...) below would otherwise
  # raise "unknown keywords" -- there is no positional hash for them to land
  # in unless every override is captured by **.
  def call(signup_domain: nil, **overrides)
    Services::UserAuthenticationService.call(
      provider_data: provider_data(overrides),
      signup_domain: signup_domain
    )
  end

  # --- Step 1 of the rule: the uid is the identity ---

  test "matches an existing user by auth_uid regardless of the email claim" do
    existing = users(:password_user)

    user = call(
      user_id: existing.auth_uid,
      email: "totally.different@example.com",
      email_verified: true,
      provider: "password"
    )

    assert_equal existing.id, user.id
    assert_equal existing.email, user.email, "email must never be reassigned by a sign-in"
  end

  test "an auth_uid match wins over a competing email match" do
    uid_owner = users(:password_user)
    email_owner = users(:google_user)

    user = call(
      user_id: uid_owner.auth_uid,
      email: email_owner.email,
      email_verified: true,
      provider: "password"
    )

    assert_equal uid_owner.id, user.id
  end

  # --- Step 2: a verified email links ---

  test "links a new uid to an existing account when the email is verified" do
    existing = users(:regular_user)
    assert_nil existing.auth_uid

    user = call(user_id: "new-uid-9", email: existing.email, email_verified: true)

    assert_equal existing.id, user.id
    assert_equal "new-uid-9", user.reload.auth_uid
  end

  # The V1-user-chooses-Google case. Refusing here would lock a migrated user
  # out of their own account, so a verified email must relink.
  test "relinks an account that already holds a different uid when the email is verified" do
    existing = users(:password_user)
    original_uid = existing.auth_uid

    user = call(user_id: "google-uid-later", email: existing.email, email_verified: true, provider: "google")

    assert_equal existing.id, user.id
    assert_equal "google-uid-later", user.reload.auth_uid
    refute_equal original_uid, user.auth_uid
  end

  # --- Step 3: an unverified email may never link. This IS the original bug. ---

  test "refuses to link an existing account when the email is unverified" do
    victim = users(:google_user)

    assert_no_difference "User.count" do
      assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
        call(user_id: "attacker-uid", email: victim.email, email_verified: false, provider: "password")
      end
    end

    victim.reload
    assert_equal "firebase-google-uid-456", victim.auth_uid, "victim's uid must be untouched"
    assert_equal "google", victim.external_provider
  end

  test "refuses to link when email_verified is absent entirely" do
    victim = users(:google_user)

    assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
      call(user_id: "attacker-uid", email: victim.email, email_verified: nil, provider: "password")
    end
  end

  # --- Step 4: create ---

  test "creates a user when neither the uid nor the email is known" do
    assert_difference "User.count", 1 do
      user = call(user_id: "fresh-uid", email: "fresh@example.com")

      assert_equal "fresh-uid", user.auth_uid
      assert_equal "fresh@example.com", user.email
      assert_equal "google", user.external_provider
      assert_equal "user", user.role
      assert_equal 1, user.sign_in_count
      assert_not_nil user.last_sign_in_at
    end
  end

  test "an unverified email that matches nothing still creates a user" do
    assert_difference "User.count", 1 do
      user = call(user_id: "fresh-unverified", email: "nobody.has.this@example.com", email_verified: false)

      assert_not user.email_verified
    end
  end

  test "records the signup domain on creation" do
    user = call(user_id: "dom-uid", email: "dom@example.com", signup_domain: "thegreatest.games")

    assert_equal "thegreatest.games", user.original_signup_domain
  end

  test "does not overwrite the signup domain of an existing account" do
    existing = users(:regular_user)
    original = existing.original_signup_domain

    call(user_id: "n-uid", email: existing.email, email_verified: true, signup_domain: "thegreatest.games")

    assert_equal original, existing.reload.original_signup_domain
  end

  # --- Bookkeeping ---

  test "matches email case-insensitively" do
    existing = users(:regular_user)

    user = call(user_id: "case-uid", email: existing.email.upcase, email_verified: true)

    assert_equal existing.id, user.id
  end

  test "increments sign_in_count and stores provider data" do
    existing = users(:password_user)
    before = existing.sign_in_count || 0

    user = call(user_id: existing.auth_uid, email: existing.email, provider: "password")

    assert_equal before + 1, user.sign_in_count
    assert_equal "password", user.provider_data["password"]["provider"]
  end

  test "never downgrades an already-verified email" do
    existing = users(:google_user)
    assert existing.email_verified

    user = call(user_id: existing.auth_uid, email: existing.email, email_verified: false, provider: "google")

    assert user.reload.email_verified
  end

  test "requires a provider" do
    assert_raises ArgumentError do
      Services::UserAuthenticationService.call(provider_data: provider_data.except(:provider))
    end
  end

  test "requires a user_id" do
    assert_raises ArgumentError do
      Services::UserAuthenticationService.call(provider_data: provider_data(user_id: nil))
    end
  end
end
