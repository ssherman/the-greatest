# frozen_string_literal: true

require "test_helper"

# config/auth_providers.json is read by Ruby; the browser gets it through a
# Stimulus value on the widget. The one thing that cannot travel as data is
# which Firebase class constructs each provider, so that map lives in JS -- and
# a provider present in the config but missing from the map fails silently at
# the moment someone clicks the button.
#
# There is no JS test runner in this project, so this is a source-level guard,
# same as test/lint/firebase_action_code_settings_test.rb.
class AuthProviderRegistryLintTest < ActiveSupport::TestCase
  OAUTH_PROVIDER_JS = Rails.root.join("app/javascript/services/auth_providers/oauth_provider.js")
  ENTRYPOINT_JS = Rails.root.join("app/javascript/entrypoints/firebase_auth.js")

  test "every configured provider has a Firebase constructor in the JS map" do
    source = File.read(OAUTH_PROVIDER_JS)

    Services::AuthProviderRegistry.all.each do |id, entry|
      assert_includes source, "'#{entry["firebase_id"]}'",
        "#{id} is in config/auth_providers.json but #{entry["firebase_id"]} is " \
        "absent from the constructor map in #{OAUTH_PROVIDER_JS.basename}. " \
        "The button would render and then fail on click."
    end
  end

  test "the per-provider singletons are gone" do
    removed = Rails.root.join("app/javascript/services/auth_providers/google_provider.js")

    refute File.exist?(removed),
      "google_provider.js should have been replaced by the generic oauth_provider.js"
  end

  test "the entrypoint exposes the generic provider, not a named singleton" do
    source = File.read(ENTRYPOINT_JS)

    assert_includes source, "oauthProvider",
      "the firebase bundle must expose the generic OAuth provider"
    refute_includes source, "googleProvider",
      "a named per-provider singleton defeats the registry"
  end

  test "email_provider is still exposed separately" do
    source = File.read(ENTRYPOINT_JS)

    assert_includes source, "emailProvider",
      "email/password is a different shape and must not be folded into the " \
      "OAuth abstraction"
  end

  CONTROLLER_JS = Rails.root.join("app/javascript/controllers/authentication_controller.js")

  test "the controller has one generic OAuth action, not one per provider" do
    source = File.read(CONTROLLER_JS)

    assert_includes source, "signInWithOauth",
      "the controller needs a single generic OAuth sign-in action"
    refute_match(/signInWith(Google|Twitter|Facebook|Apple)\b/, source,
      "a per-provider action defeats the registry: adding a provider must not " \
      "mean editing this 688-line controller")
  end

  test "the controller declares a providers value" do
    source = File.read(CONTROLLER_JS)

    assert_match(/providers:\s*Array/, source,
      "the registry reaches the browser as a Stimulus Array value -- there is " \
      "no @rollup/plugin-json in this project, so the config cannot be imported")
  end

  test "the generic action still marks the pending redirect" do
    source = File.read(CONTROLLER_JS)
    action = source[/async signInWithOauth\(event\)\s*\{.*?\n  \}/m]

    assert action, "could not find signInWithOauth in #{CONTROLLER_JS}"
    assert_includes action, "markPendingRedirect()",
      "without this, a reload mid-redirect loses the sign-in silently: tg_uid " \
      "is unset, markSignedIn has not run, and Firebase has consumed its own key"
    assert_includes action, "clearPendingRedirect()",
      "a failed redirect must clear the marker it set"
  end
end
