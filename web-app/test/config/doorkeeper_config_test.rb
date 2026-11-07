require "test_helper"

# Pins the settings the sign-in flow's security rests on, so a Doorkeeper
# upgrade or a stray edit to the initializer fails here and not in production.
class DoorkeeperConfigTest < ActiveSupport::TestCase
  test "Doorkeeper is pinned to the version whose internals this app prepends to" do
    assert_equal "5.9.9", Doorkeeper::VERSION::STRING,
      "re-check URIChecker.matches?/loopback_uri? and AuthorizationsController#pre_auth_param_fields before bumping"
  end

  test "PKCE is forced and S256 is the only method" do
    assert Doorkeeper.config.force_pkce?
    assert_equal ["S256"], Doorkeeper.config.pkce_code_challenge_methods
  end

  test "the authorization code grant is the only flow, with refresh tokens" do
    assert_equal ["authorization_code"], Doorkeeper.config.grant_flows
    assert Doorkeeper.config.refresh_token_enabled?
  end

  test "access tokens last an hour" do
    assert_equal 1.hour, Doorkeeper.config.access_token_expires_in
  end

  test "tokens are stored as SHA-256 hashes" do
    assert_equal Doorkeeper::SecretStoring::Sha256Hash, Doorkeeper.config.token_secret_strategy
  end

  test "the connection id is copied from grant to token" do
    assert_equal [:connection_id], Doorkeeper.config.custom_access_token_attributes
  end

  test "scopes are the API scopes plus offline_access, and unknown ones are refused" do
    assert_equal (Api::Scopes.all + ["offline_access"]).sort, Doorkeeper.config.scopes.all.sort
    assert Doorkeeper.config.enforce_configured_scopes?
  end

  test "the grants table has the PKCE columns, so the verifier check is not skipped" do
    assert OauthAccessGrant.pkce_supported?
  end

  test "a refresh token stops working once it has been used" do
    assert OauthAccessToken.refresh_token_revoked_on_use?
  end

  test "Doorkeeper uses this app's model classes" do
    assert_equal OauthApplication, Doorkeeper.config.application_class.constantize
    assert_equal OauthAccessGrant, Doorkeeper.config.access_grant_class.constantize
    assert_equal OauthAccessToken, Doorkeeper.config.access_token_class.constantize
  end
end
