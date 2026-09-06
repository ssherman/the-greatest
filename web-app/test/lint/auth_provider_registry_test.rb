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
end
