require "test_helper"

# Firebase signs a reader in client-side before Rails ever sees the token, so
# its auth-state callback flips the navbar to Logout, hides the sign-in
# controls, and persists the localStorage signed-in hint. When Rails then
# refuses that identity with email_verification_required, all of that has to be
# rolled back -- otherwise the browser keeps presenting a signed-in identity,
# across reloads, with no Rails session behind it.
#
# There is no JavaScript test runner in this project, so this is a source-level
# guard in the same spirit as daisyui_v4_classes_test.rb and
# firebase_action_code_settings_test.rb.
class RefusedIdentityUiStateTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/controllers/authentication_controller.js")

  def source
    @source ||= File.read(SOURCE)
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
  # Firebase has already signed the reader in client-side, so this branch
  # needs the identical rollback.
  def account_lookup_branch
    marker = "if (event.detail.code === 'account_lookup_failed') {"
    start = source.index(marker)
    assert start, "could not find the account_lookup_failed branch in #{SOURCE}"

    finish = source.index("return", start)
    assert finish, "the account_lookup_failed branch has no return"
    source[start...finish]
  end

  test "refusing an identity clears the persisted signed-in hint" do
    assert_includes verification_branch, "clearSignedInHint()",
      "the email_verification_required branch must clear the localStorage " \
      "signed-in hint, or the refused identity is presented as signed in " \
      "again on the next page load"
  end

  test "refusing an identity rolls the UI back to anonymous" do
    assert_includes verification_branch, "this.showUnauthenticatedState()",
      "the email_verification_required branch must reset the UI, or the navbar " \
      "keeps showing Logout and the sign-in controls stay hidden over an " \
      "anonymous Rails session"
  end

  test "the verification affordance is shown after the UI reset, not before" do
    branch = verification_branch
    reset_at = branch.index("this.showUnauthenticatedState()")
    info_at = branch.index("this.showInfo(")

    assert reset_at, "branch does not call showUnauthenticatedState"
    assert info_at, "branch does not call showInfo"
    assert reset_at < info_at,
      "showUnauthenticatedState hides verificationMessageTarget, so it must run " \
      "BEFORE the message is shown or the affordance is immediately hidden"
  end

  test "refusing an identity via account_lookup_failed clears the persisted signed-in hint" do
    assert_includes account_lookup_branch, "clearSignedInHint()",
      "the account_lookup_failed branch must clear the localStorage signed-in " \
      "hint, or the refused identity is presented as signed in again on the " \
      "next page load"
  end

  test "refusing an identity via account_lookup_failed rolls the UI back to anonymous" do
    assert_includes account_lookup_branch, "this.showUnauthenticatedState()",
      "the account_lookup_failed branch must reset the UI, or the navbar keeps " \
      "showing Logout and the sign-in controls stay hidden over an anonymous " \
      "Rails session"
  end

  test "a later Firebase notification cannot re-present a refused identity" do
    marker = "if (user) {"
    start = source.index(marker)
    assert start, "could not find the auth-state user branch"

    finish = source.index("markSignedIn()", start)
    assert finish, "the auth-state user branch does not call markSignedIn"

    assert_includes source[start...finish], "this.pendingVerification",
      "handleAuthStateChange must check pendingVerification before markSignedIn: " \
      "Firebase re-notifies on its own schedule (a token refresh is enough), " \
      "which would otherwise silently re-present an identity Rails refused"
  end

  test "a fresh sign-in attempt stops suppressing auth-state notifications" do
    marker = "async submitEmailForm(event) {"
    start = source.index(marker)
    assert start, "could not find submitEmailForm"

    finish = source.index("await this.firebase()", start)
    assert finish, "submitEmailForm does not resolve the firebase bundle"

    assert_includes source[start...finish], "this.pendingVerification = false",
      "submitEmailForm must clear pendingVerification, or the guard outlives " \
      "the refusal and a genuinely verified retry never updates the UI"
  end

  # Rolling the UI back is not enough on its own. Firebase re-notifies on its
  # own schedule, and that notification calls markSignedIn(). The
  # email_verification_required branch has been guarded since it was written;
  # account_lookup_failed shipped the visible half of that rollback without the
  # guard, and a PR review caught it. These pin both halves.

  test "account_lookup_failed suppresses later auth-state notifications" do
    assert_includes account_lookup_branch, "this.identityRefused = true",
      "the account_lookup_failed branch must set identityRefused, or a token " \
      "refresh re-presents the refused identity as signed in with no Rails " \
      "session behind it"
  end

  test "account_lookup_failed signs the Firebase user out" do
    assert_includes account_lookup_branch, "signOut()",
      "the account_lookup_failed branch must sign the Firebase user out. The " \
      "identityRefused flag dies with the page, so without this a reload " \
      "re-presents the same refused identity. Nothing needs that Firebase " \
      "user afterwards -- unlike the verification branch, which keeps it for " \
      "resendVerification"
  end

  test "a later Firebase notification cannot re-present a lookup-refused identity" do
    marker = "if (user) {"
    start = source.index(marker)
    assert start, "could not find the auth-state user branch"

    finish = source.index("markSignedIn()", start)
    assert finish, "the auth-state user branch does not call markSignedIn"

    assert_includes source[start...finish], "this.identityRefused",
      "handleAuthStateChange must check identityRefused before markSignedIn: " \
      "the branch signs Firebase out, but signOut() is async and a token " \
      "refresh can land in between"
  end

  test "a fresh sign-in attempt stops suppressing lookup-refused notifications" do
    marker = "async submitEmailForm(event) {"
    start = source.index(marker)
    assert start, "could not find submitEmailForm"

    finish = source.index("await this.firebase()", start)
    assert finish, "submitEmailForm does not resolve the firebase bundle"

    assert_includes source[start...finish], "this.identityRefused = false",
      "submitEmailForm must clear identityRefused, or the guard outlives the " \
      "refusal and a successful retry never updates the UI"
  end
end
