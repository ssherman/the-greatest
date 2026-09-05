require "test_helper"

# sendPasswordResetEmail and sendEmailVerification without actionCodeSettings
# fall back to Firebase's project-wide default action URL -- a books URL. A
# reader who resets their password on games would be emailed a link that lands
# on books.
#
# There is no JS test runner in this project, so this is a source-level guard in
# the same spirit as test/lint/daisyui_v4_classes_test.rb.
class FirebaseActionCodeSettingsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/services/auth_providers/email_provider.js")

  test "every action-code email call passes actionCodeSettings" do
    source = File.read(SOURCE)

    %w[sendPasswordResetEmail sendEmailVerification].each do |fn|
      calls = source.scan(/#{fn}\(([^)]*)\)/m).flatten
      invocations = calls.reject { |args| args.strip.empty? }

      assert invocations.any?, "expected at least one #{fn} call in #{SOURCE}"

      invocations.each do |args|
        assert_includes args, "actionCodeSettings",
          "#{fn}(#{args.strip}) omits actionCodeSettings, so its email would " \
          "link to the Firebase project default domain instead of the caller's"
      end
    end
  end

  test "the settings are derived from the live origin, not a hardcoded host" do
    source = File.read(SOURCE)

    assert_includes source, "window.location.origin"
    refute_match(/url:\s*['"]https:\/\/[a-z]/, source,
      "actionCodeSettings.url must be derived from the current origin")
  end

  # The plan named two call sites to fix. There are three -- resend-verification
  # was missed. Pinning the count means a fourth added later cannot quietly ship
  # without settings, which is the whole failure mode this guards.
  test "all three known action-code call sites are covered" do
    source = File.read(SOURCE)
    invocations = source.scan(/send(?:PasswordResetEmail|EmailVerification)\(([^)]*)\)/m)
      .flatten
      .reject { |args| args.strip.empty? }

    assert_equal 3, invocations.length,
      "expected 3 action-code calls (sign-up verification, password reset, resend verification); " \
      "found #{invocations.length}. If a call was added, give it actionCodeSettings and update this count."
  end
end
