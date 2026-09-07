require "test_helper"

class ProviderEmailResolverTest < ActiveSupport::TestCase
  PROJECT = "the-greatest-books"

  def resolver(sign_in_provider: "facebook.com", fallback_email: nil)
    Services::ProviderEmailResolver.new(
      uid: "uid_1",
      sign_in_provider: sign_in_provider,
      project_id: PROJECT,
      fallback_email: fallback_email
    )
  end

  test "returns the email from the entry matching the sign-in provider" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "google.com", "email" => "wrong@example.com"},
      {"providerId" => "facebook.com", "email" => "right@example.com"}
    ])

    assert_equal "right@example.com", resolver.call
  end

  test "falls back to the token claim when the provider entry has no email" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "facebook.com", "rawId" => "10166754100896840"}
    ])

    assert_equal "claim@example.com", resolver(fallback_email: "claim@example.com").call
  end

  test "falls back to the token claim when no entry matches the provider" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "google.com", "email" => "other@example.com"}
    ])

    assert_equal "claim@example.com", resolver(fallback_email: "claim@example.com").call
  end

  test "returns nil when neither the provider entry nor the token has an email" do
    Services::FirebaseAccountLookup.stubs(:call).returns([])

    assert_nil resolver.call
  end

  test "an entry with a blank email falls back rather than returning the blank" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "facebook.com", "email" => ""}
    ])

    assert_equal "claim@example.com", resolver(fallback_email: "claim@example.com").call
  end

  test "a lookup failure propagates rather than degrading to the token claim" do
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::FirebaseAccountLookup::Error, "boom")

    # Spec D2: without the email we cannot tell a new user from an existing one
    # adding a provider, so the sign-in must be refused rather than guessing.
    # Silently returning fallback_email here would reintroduce exactly the
    # duplicate-account outcome this design exists to prevent.
    assert_raises(Services::FirebaseAccountLookup::Error) do
      resolver(fallback_email: "claim@example.com").call
    end
  end

  test "a token minting failure propagates too" do
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::GoogleServiceAccountToken::Error, "boom")

    assert_raises(Services::GoogleServiceAccountToken::Error) { resolver.call }
  end
end
