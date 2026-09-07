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
    # Anchored to the factory block itself, not the whole file -- otherwise a
    # quoted firebase_id sitting in a comment or anywhere else in the file
    # would satisfy assert_includes without the map actually containing it.
    factories = source[/const PROVIDER_FACTORIES = \{.*?\}/m]
    assert factories, "could not find PROVIDER_FACTORIES in #{OAUTH_PROVIDER_JS.basename}"

    Services::AuthProviderRegistry.all.each do |id, entry|
      assert_includes factories, "'#{entry["firebase_id"]}'",
        "#{id} is in config/auth_providers.json but #{entry["firebase_id"]} is " \
        "absent from the constructor map in #{OAUTH_PROVIDER_JS.basename}. " \
        "The button would render and then fail on click."
    end
  end

  # The feature doc used to claim adding a provider is a JSON entry plus an
  # icon. It also needs an entry in AuthenticationService::PROVIDER_MAP and a
  # value in User's external_provider enum -- without both, the button
  # renders, the redirect works, Firebase returns a valid token, and
  # /auth/sign_in answers "This sign-in method is not supported". That is the
  # exact silent drift this registry exists to prevent, moved one file over.
  test "every registry entry's firebase_id is mapped by AuthenticationService" do
    Services::AuthProviderRegistry.all.each do |id, entry|
      firebase_id = entry["firebase_id"]

      assert Services::AuthenticationService::PROVIDER_MAP.key?(firebase_id),
        "#{id} is in config/auth_providers.json but #{firebase_id} is absent " \
        "from Services::AuthenticationService::PROVIDER_MAP. The button would " \
        "render, the redirect would succeed, and /auth/sign_in would answer " \
        "\"This sign-in method is not supported\"."
    end
  end

  test "PROVIDER_MAP maps each registry firebase_id to that provider's own id and enum value" do
    Services::AuthProviderRegistry.all.each do |id, entry|
      firebase_id = entry["firebase_id"]
      mapped = Services::AuthenticationService::PROVIDER_MAP[firebase_id]

      assert_equal id, mapped,
        "#{firebase_id} maps to #{mapped.inspect} in PROVIDER_MAP, not " \
        "#{id.inspect} -- PROVIDER_MAP and the registry have drifted"
      assert_includes User.external_providers.keys, mapped,
        "#{mapped.inspect} is not a value in User's external_provider enum"
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
