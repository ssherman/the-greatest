# Mints OAuth tokens through Doorkeeper's own create_for, so the stored values
# are hashed exactly as in production. The fixtures for grants and tokens are
# empty for that reason: a stored value is a hash, never the secret a client
# would present.
module OauthTestHelper
  # Returns [access_token_plaintext, refresh_token_plaintext].
  def issue_oauth_token(connection, expires_in: 1.hour)
    token = OauthAccessToken.create_for(
      application: connection.application,
      resource_owner: connection.user,
      scopes: Doorkeeper::OAuth::Scopes.from_array(connection.scopes),
      expires_in: expires_in.to_i,
      use_refresh_token: true,
      connection_id: connection.id
    )
    [token.plaintext_token, token.plaintext_refresh_token]
  end
end
