require "test_helper"

class UserAuthenticationServiceTest < ActiveSupport::TestCase
  def provider_data(overrides = {})
    {
      user_id: "google_123",
      email: "test@example.com",
      name: "Test User",
      picture: "https://example.com/photo.jpg",
      email_verified: true,
      # The permissive value, so the happy-path tests below read the way they
      # always did. It is the linking decision's input, so any test of the
      # refusal path must override it -- leaving it alone there would let the
      # attacker link and the test would pass for the wrong reason.
      email_trusted: true,
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
    assert user.reload.email_verified
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

  # --- Step 3: an untrusted email may never link. This IS the original bug. ---
  #
  # Both tests in this section spell out email_trusted rather than leaning on
  # the helper's permissive default, because these are the takeover cases and
  # that default would let the attacker link.

  # "password" plus an unverified claim is exactly what extract_provider_data
  # turns into email_trusted: false, so this is the hash production would
  # hand the service.
  test "refuses to link an existing account when the email is unverified" do
    victim = users(:google_user)

    assert_no_difference "User.count" do
      assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
        call(user_id: "attacker-uid", email: victim.email, email_verified: false, email_trusted: false, provider: "password")
      end
    end

    victim.reload
    assert_equal "firebase-google-uid-456", victim.auth_uid, "victim's uid must be untouched"
    assert_equal "google", victim.external_provider
  end

  # Unlike the test above, this is NOT the hash production would hand the
  # service: extract_provider_data compares both claims with == true, so
  # email_trusted and email_verified can never actually come out nil, only
  # true or false. nil here is a deliberately out-of-band value, used to pin
  # the `== true` fail-closed strictness against a caller that omits the key
  # entirely, rather than to reproduce a real payload shape.
  test "refuses to link when the email claims are absent entirely" do
    victim = users(:google_user)

    assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
      call(user_id: "attacker-uid", email: victim.email, email_verified: nil, email_trusted: nil, provider: "password")
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

  # A token that carries no email claim at all: find_user misses on uid,
  # short-circuits on `return nil if email.nil?`, and this must still create
  # an account rather than raise -- an email-less OAuth row is a supported
  # state (see User#external_oauth_account?), not an error.
  test "a token with no email creates a new user with a blank email" do
    assert_difference "User.count", 1 do
      user = call(user_id: "fresh-uid-no-email", email: nil, email_verified: false, provider: "twitter")

      assert_nil user.email
      assert_equal "fresh-uid-no-email", user.auth_uid
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

  test "a trusted provider links to an existing account despite an unverified claim" do
    existing = users(:google_user)

    user = call(
      user_id: "brand-new-x-uid",
      email: existing.email,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_equal existing.id, user.id, "X sign-in must land on the existing account"
    assert_equal "brand-new-x-uid", user.reload.auth_uid
  end

  test "an untrusted provider still refuses to link on an unverified email" do
    existing = users(:google_user)

    assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
      call(
        user_id: "attacker-uid",
        email: existing.email,
        email_verified: false,
        email_trusted: false,
        provider: "password"
      )
    end
  end

  test "the linking decision reads email_trusted, not email_verified" do
    existing = users(:google_user)

    # Deliberately contradictory: verified false, trusted true. If the guard
    # still read email_verified this would raise.
    user = call(
      user_id: "contradiction-uid",
      email: existing.email,
      email_verified: false,
      email_trusted: true,
      provider: "facebook"
    )

    assert_equal existing.id, user.id
  end

  test "a trusted sign-in does not mark the column verified" do
    existing = users(:google_user)
    existing.update!(email_verified: false)

    call(
      user_id: "x-uid-column-check",
      email: existing.email,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    refute existing.reload.email_verified,
      "the column records the provider's actual claim, not our trust inference"
  end

  test "a sign-in fills a blank email" do
    blank = User.create!(
      auth_uid: "x-uid-blank-email",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    call(
      user_id: blank.auth_uid,
      email: "now.has.one@example.com",
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_equal "now.has.one@example.com", blank.reload.email,
      "an email-less row must pick up an address so it becomes linkable"
  end

  # The mirror of the fill test above: an untrusted claim must not fill a
  # blank email either. Without this gate, an attacker who controls an
  # email-less OAuth row could link a password credential to the same
  # Firebase user with any unclaimed address, have this fill write it onto
  # their row on the next sign-in, and then have a later trusted sign-in
  # match on it via find_user's email lookup.
  #
  # This uid-matched row still has its external_provider overwritten to
  # "password" (update_existing always writes the incoming provider), and
  # password accounts require a present email -- so with the fill correctly
  # withheld, the whole update fails its presence validation rather than
  # silently landing with a blank email. That is still the property this
  # test is after: either way, the attacker-chosen address never reaches the
  # row.
  test "an untrusted sign-in does not fill a blank email" do
    blank = User.create!(
      auth_uid: "pw-uid-untrusted-fill",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    assert_raises ActiveRecord::RecordInvalid do
      call(
        user_id: blank.auth_uid,
        email: "attacker.chosen@example.com",
        email_verified: false,
        email_trusted: false,
        provider: "password"
      )
    end

    assert_nil blank.reload.email,
      "an untrusted claim must not fill a blank email"
  end

  test "a sign-in never overwrites an existing email" do
    existing = users(:google_user)
    original = existing.email

    call(
      user_id: existing.auth_uid,
      email: "attacker.controlled@example.com",
      email_verified: true,
      email_trusted: true,
      provider: "google"
    )

    assert_equal original, existing.reload.email,
      "a sign-in must never rewrite the address an account is known by"
  end

  test "a sign-in with no email leaves a blank email blank" do
    blank = User.create!(
      auth_uid: "x-uid-still-blank",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    call(
      user_id: blank.auth_uid,
      email: nil,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_nil blank.reload.email
  end

  # find_user matches on uid alone, with no requirement that a blank row's
  # email agree with the token's -- so the token's address can turn out to
  # already belong to a totally different row (the class comment notes the
  # table holds case-insensitive duplicates). Filling it in anyway would hit
  # :email's uniqueness validation and fail a sign-in that had already
  # matched by uid. It must not: the fill is a convenience, not the point of
  # the sign-in, so a collision just skips the fill and leaves the row blank.
  # --- external_provider_uid: the only reconnection key for an email-less OAuth user ---

  test "a new user gets external_provider_uid from the token" do
    user = call(user_id: "fresh-uid-pu", email: "fresh.pu@example.com", provider_uid: "x-1406121503133888515")

    assert_equal "x-1406121503133888515", user.external_provider_uid
  end

  test "an existing row with a blank external_provider_uid gets it filled" do
    existing = users(:google_user)
    assert_nil existing.external_provider_uid

    call(user_id: existing.auth_uid, email: existing.email, provider_uid: "new-provider-uid")

    assert_equal "new-provider-uid", existing.reload.external_provider_uid
  end

  # The real-world shape of this: a row carries a legacy X id (X ids are the
  # only globally stable ones -- see F5), and a LATER sign-in with a
  # different provider (Google) must not clobber it with that provider's id.
  # This is the scenario the design comment and the task's named risk call
  # out -- not merely "the incoming value differs", but "the incoming
  # provider differs from the one on file" -- so the row's existing
  # external_provider is deliberately set to twitter while the sign-in
  # itself is google.
  test "an existing row that already holds a provider uid keeps it when a different provider signs in" do
    existing = users(:google_user)
    existing.update!(external_provider: :twitter, external_provider_uid: "legacy-x-id-123")

    call(user_id: existing.auth_uid, email: existing.email, provider: "google", provider_uid: "new-google-uid")

    assert_equal "legacy-x-id-123", existing.reload.external_provider_uid
  end

  test "a blank-email fill is skipped when the address already belongs to a different row" do
    other = users(:regular_user)
    blank = User.create!(
      auth_uid: "x-uid-collision",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    user = call(
      user_id: blank.auth_uid,
      email: other.email,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_equal blank.id, user.id, "the uid match must still win the sign-in"
    assert_nil blank.reload.email, "a collision must skip the fill, not raise"
    assert_equal other.email, other.reload.email, "the other row's email must be untouched"
  end

  # --- Lazy email resolution ---

  # The whole cost argument for resolving lazily: a returning user whose row
  # already has an address must not pay a network round trip.
  # password_user, not regular_user: these two need a row that already has an
  # auth_uid to match on, and regular_user's is nil -- passing that as user_id
  # raises ArgumentError before any of this is exercised.
  test "a uid match on a row that already has an email never calls the resolver" do
    existing = users(:password_user)
    assert existing.email.present?, "fixture precondition"
    resolver = mock
    resolver.expects(:call).never

    Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: existing.auth_uid, provider: "google"),
      email_resolver: resolver
    )
  end

  test "a uid match on a blank-email row resolves once and fills the blank" do
    existing = users(:password_user)
    # update_columns, not update!: :email's presence rule is only relaxed for
    # external_oauth_account?, and this row is a password account until the
    # same statement changes it.
    existing.update_columns(email: nil, external_provider: User.external_providers[:twitter])
    resolver = mock
    resolver.expects(:call).once.returns("filled@example.com")

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(
        user_id: existing.auth_uid, provider: "twitter", email_trusted: true
      ),
      email_resolver: resolver
    )

    assert_equal "filled@example.com", user.reload.email
  end

  test "a uid miss resolves the email and links by it" do
    existing = users(:regular_user)
    existing.update!(email: "target@example.com")
    resolver = mock
    resolver.expects(:call).once.returns("TARGET@example.com")

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(
        user_id: "brand_new_uid", email: nil, provider: "facebook", email_trusted: true
      ),
      email_resolver: resolver
    )

    assert_equal existing.id, user.id, "the resolved address must drive the link"
  end

  test "the resolver is consulted at most once per sign-in" do
    resolver = mock
    resolver.expects(:call).once.returns("new.person@example.com")

    Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: "brand_new_uid", email: nil, provider: "facebook"),
      email_resolver: resolver
    )
  end

  test "a resolver returning nil creates a user with no email" do
    resolver = mock
    resolver.stubs(:call).returns(nil)

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: "brand_new_uid", email: nil, provider: "facebook"),
      email_resolver: resolver
    )

    assert_nil user.email
    assert_predicate user, :persisted?
  end

  test "an untrusted provider still raises against an existing row even when resolved" do
    existing = users(:regular_user)
    existing.update!(email: "victim@example.com")
    resolver = mock
    resolver.stubs(:call).returns("victim@example.com")

    assert_raises(Services::UserAuthenticationService::UnverifiedEmailConflict) do
      Services::UserAuthenticationService.call(
        provider_data: provider_data(
          user_id: "attacker_uid", email: nil, provider: "password", email_trusted: false
        ),
        email_resolver: resolver
      )
    end
  end

  test "with no resolver the service reads provider_data[:email] as before" do
    existing = users(:regular_user)
    existing.update!(email: "legacy@example.com")

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: "brand_new_uid", email: "legacy@example.com")
    )

    assert_equal existing.id, user.id
  end
end
