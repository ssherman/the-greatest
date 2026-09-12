require "test_helper"

class Services::AuthProviderRegistryTest < ActiveSupport::TestCase
  test "all returns every known provider keyed by id" do
    assert_kind_of Hash, Services::AuthProviderRegistry.all
    assert_includes Services::AuthProviderRegistry.provider_names, "google"
    assert_includes Services::AuthProviderRegistry.provider_names, "twitter"
    assert_includes Services::AuthProviderRegistry.provider_names, "facebook"
    assert_includes Services::AuthProviderRegistry.provider_names, "apple"
  end

  test "every entry declares the keys the view and the client need" do
    Services::AuthProviderRegistry.all.each do |id, entry|
      assert_match(/\A[a-z]+\z/, id, "provider id #{id.inspect} must be lowercase letters")
      assert_kind_of String, entry["firebase_id"], "#{id} needs a firebase_id"
      assert_kind_of String, entry["label"], "#{id} needs a label"
      assert_kind_of Array, entry["scopes"], "#{id} needs a scopes array"
      assert_includes [true, false], entry["enabled"], "#{id} needs an explicit enabled boolean"
    end
  end

  test "enabled excludes providers that are turned off" do
    # Every real provider is enabled now, so the flag is proven on a stubbed
    # config rather than on whichever provider happens to be off this month.
    # Stubbing `all` is enough: `enabled` reaches the config through it.
    Services::AuthProviderRegistry.stubs(:all).returns({
      "on" => {"firebase_id" => "on.example", "label" => "On", "scopes" => [], "enabled" => true},
      "off" => {"firebase_id" => "off.example", "label" => "Off", "scopes" => [], "enabled" => false}
    })

    assert_equal ["on"], Services::AuthProviderRegistry.enabled.keys
  end

  test "enabled_for_view exposes symbol keys in file order" do
    entries = Services::AuthProviderRegistry.enabled_for_view

    assert_equal %w[google twitter facebook apple], entries.map { |e| e[:id] }
    google = entries.first
    assert_equal "google.com", google[:firebase_id]
    assert_equal "Google", google[:label]
    assert_equal ["profile", "email"], google[:scopes]
  end

  test "the Apple entry is enabled and requests the email and name scopes" do
    apple = Services::AuthProviderRegistry.all.fetch("apple")

    assert_equal "apple.com", apple["firebase_id"]
    assert apple["enabled"], "Sign in with Apple shipped enabled (spec 2026-09-12)"
    # Load-bearing, not cosmetic. Under this project's "multiple accounts per
    # email address" setting Firebase requests NO scopes for Apple unless the
    # client passes them. Drop "email" and every new Apple user gets a token
    # with no address on the provider record either -- an email-less row that
    # can never be linked to anything (spec F3).
    assert_equal %w[email name], apple["scopes"]
  end

  test "the X entry is labelled X and requests no scopes" do
    x = Services::AuthProviderRegistry.all.fetch("twitter")

    assert_equal "twitter.com", x["firebase_id"]
    assert_equal "X", x["label"]
    assert_empty x["scopes"], "Firebase's Twitter provider takes no scopes"
  end
end
