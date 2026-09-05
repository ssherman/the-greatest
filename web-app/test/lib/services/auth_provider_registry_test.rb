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
    enabled = Services::AuthProviderRegistry.enabled

    assert_includes enabled.keys, "google"
    assert_includes enabled.keys, "twitter"
    refute_includes enabled.keys, "facebook",
      "Facebook must ship disabled: the Meta app is restricted to development mode."
    refute_includes enabled.keys, "apple",
      "Apple is not implemented in this pass."
  end

  test "enabled_for_view exposes symbol keys in file order" do
    entries = Services::AuthProviderRegistry.enabled_for_view

    assert_equal %w[google twitter], entries.map { |e| e[:id] }
    google = entries.first
    assert_equal "google.com", google[:firebase_id]
    assert_equal "Google", google[:label]
    assert_equal ["profile", "email"], google[:scopes]
  end

  test "the X entry is labelled X and requests no scopes" do
    x = Services::AuthProviderRegistry.all.fetch("twitter")

    assert_equal "twitter.com", x["firebase_id"]
    assert_equal "X", x["label"]
    assert_empty x["scopes"], "Firebase's Twitter provider takes no scopes"
  end
end
