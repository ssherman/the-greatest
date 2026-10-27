require "test_helper"

# The sign-in widget renders from tg_uid, which mirrors the Rails session.
# Firebase only signs in and out, and a Firebase user with no tg_uid is signed
# out quietly to match. That reconciliation is exactly what would cancel a
# real sign-in, or strand an unverified reader with nothing to resend to, if
# one of its guards went missing -- and none of it is visible to the Rails
# suite.
#
# There is no JavaScript test runner in this project, so this is a source-level
# guard in the same spirit as daisyui_v4_classes_test.rb and
# firebase_action_code_settings_test.rb.
class RefusedIdentityUiStateTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/controllers/authentication_controller.js")

  def source
    @source ||= File.read(SOURCE)
  end

  # The body of one method: from its signature to the first line that closes a
  # method at class-body indentation.
  def method_body(signature)
    start = source.index(signature)
    assert start, "could not find #{signature} in #{SOURCE}"

    finish = source.index("\n  }\n", start)
    assert finish, "could not find the end of #{signature}"
    source[start...finish]
  end

  # Isolates handleAuthError's email_verification_required branch: from the
  # code check to the `return` that ends it.
  def verification_branch
    marker = "if (event.detail.code === 'email_verification_required') {"
    start = source.index(marker)
    assert start, "could not find the email_verification_required branch in #{SOURCE}"

    finish = source.index("return", start)
    assert finish, "the email_verification_required branch has no return"
    source[start...finish]
  end

  # Same isolation for handleAuthError's account_lookup_failed branch --
  # Google's token minter or the Identity Toolkit lookup can fail after
  # Firebase has already signed the reader in client-side.
  def account_lookup_branch
    marker = "if (event.detail.code === 'account_lookup_failed') {"
    start = source.index(marker)
    assert start, "could not find the account_lookup_failed branch in #{SOURCE}"

    finish = source.index("return", start)
    assert finish, "the account_lookup_failed branch has no return"
    source[start...finish]
  end

  test "the widget's signed-in presentation comes from tg_uid" do
    assert_includes method_body("renderSignInState() {"), "signedInUid()",
      "renderSignInState must decide from tg_uid. Firebase and Rails forget " \
      "users independently, so rendering from Firebase is how the navbar came " \
      "to say Login on a signed-in page"
  end

  test "Firebase's auth-state callback does not render signed-in chrome" do
    body = method_body("handleAuthStateChange(user) {")

    refute_includes body, "updateNavbarButton",
      "handleAuthStateChange must not drive the navbar: Firebase's view of the " \
      "visitor is not the server's"
  end

  test "refusing an unverified address marks it before rendering" do
    branch = verification_branch
    mark_at = branch.index("markPendingVerification()")
    render_at = branch.index("this.renderSignInState()")

    assert mark_at, "the email_verification_required branch must set the " \
      "pending-verification marker, or the next notification signs the " \
      "Firebase user out and the resend link has no one to send to"
    assert render_at, "the email_verification_required branch must re-render"
    assert mark_at < render_at,
      "renderSignInState shows the resend link only while the marker is set, " \
      "so the marker has to be written first"
  end

  test "refusing an unverified address keeps the Firebase user" do
    refute_includes verification_branch, "signOut",
      "the email_verification_required branch must not sign Firebase out: " \
      "resendVerification() reads Firebase's current user"
  end

  test "account_lookup_failed signs the Firebase user out" do
    assert_includes account_lookup_branch, "signOutFirebaseQuietly(",
      "the account_lookup_failed branch must sign the Firebase user out. " \
      "Nothing needs that refused identity afterwards, unlike the " \
      "verification branch, which keeps it for resendVerification"
  end

  test "the quiet Firebase sign-out never reaches /auth/sign_out" do
    body = method_body("signOutFirebaseQuietly(reason) {")

    refute_includes body, "firebaseAuthService.signOut()",
      "FirebaseAuthService#signOut also POSTs /auth/sign_out and dispatches " \
      "auth:signout. A reconciliation acting on a missing presentation cookie " \
      "must not end a server session it cannot see"
    assert_includes body, "getAuth().signOut()",
      "signOutFirebaseQuietly must sign Firebase itself out"
  end

  test "reconciliation never signs out a sign-in that has not finished" do
    body = method_body("reconcileFirebaseUser(user) {")

    ["signedInUid()", "this.signInInFlight", "pendingRedirect()", "pendingVerification()"].each do |guard|
      assert_includes body, guard,
        "reconcileFirebaseUser must check #{guard} before signing Firebase out; " \
        "without it a real sign-in (or an unverified reader's resend link) is " \
        "cancelled"
    end
  end

  test "the auth-state callback reads the redirect marker before clearing it" do
    body = method_body("handleAuthStateChange(user) {")
    read_at = body.index("const redirectWasPending = pendingRedirect()")
    clear_at = body.index("clearPendingRedirect()")

    assert read_at, "handleAuthStateChange must capture pendingRedirect() up front"
    assert clear_at, "handleAuthStateChange must clear the redirect marker"
    assert read_at < clear_at,
      "the notification that ends a redirect carries the new user before " \
      "/auth/sign_in answers; reading the marker after clearing it would sign " \
      "that sign-in out"
  end

  test "every sign-in entry point marks itself in flight" do
    ["async signInWithOauth(event) {", "async submitEmailForm(event) {"].each do |signature|
      body = method_body(signature)
      set_at = body.index("this.signInInFlight = true")
      load_at = body.index("await this.firebase()")

      assert set_at, "#{signature} must set signInInFlight"
      assert load_at, "#{signature} does not resolve the firebase bundle"
      assert set_at < load_at,
        "#{signature} must set signInInFlight before loading Firebase: loading " \
        "it registers the auth-state callback that would otherwise sign the " \
        "new user out"
    end
  end

  test "auth:success and auth:error end the in-flight sign-in" do
    ["handleAuthSuccess(event) {", "handleAuthError(event) {"].each do |signature|
      assert_includes method_body(signature), "this.signInInFlight = false",
        "#{signature} must clear signInInFlight, or reconciliation stays off " \
        "for the rest of the page"
    end
  end

  test "sign-out ends the Rails session before touching Firebase" do
    body = method_body("async signOut(event) {")
    rails_at = body.index("fetch('/auth/sign_out'")
    firebase_at = body.index("await this.firebase()")

    assert rails_at, "signOut must POST /auth/sign_out"
    assert firebase_at, "signOut must still sign Firebase out"
    assert rails_at < firebase_at,
      "the Rails session is the one that matters; a Firebase failure must not " \
      "be able to stop it ending"
  end
end
