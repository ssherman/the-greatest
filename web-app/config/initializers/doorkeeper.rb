# frozen_string_literal: true

# OAuth 2.1 authorization server for the MCP endpoint: a member clicks a link
# in Claude and approves, instead of pasting an API token. Design:
# docs/superpowers/specs/2026-11-02-mcp-oauth-design.md.
#
# Every client is public (PKCE, no client secret). Every route is hand-written
# in config/routes.rb rather than `use_doorkeeper`, so nothing here is exposed
# that is not routed on purpose.
Doorkeeper.configure do
  orm :active_record

  # Our own model classes (not Doorkeeper::*), so they can belong to an
  # OauthConnection and carry schema annotations.
  application_class "OauthApplication"
  access_grant_class "OauthAccessGrant"
  access_token_class "OauthAccessToken"

  # The authorize page is an ordinary page of this app: session sign-in, the
  # books layout, CSRF.
  base_controller "ApplicationController"

  # nil when signed out. The authorizations controller handles that case
  # itself, so this block never redirects.
  resource_owner_authenticator { current_user }

  access_token_expires_in 1.hour
  authorization_code_expires_in 10.minutes

  # Refresh tokens are rotated: a used one stops working (the
  # previous_refresh_token column is what makes Doorkeeper do that).
  use_refresh_token

  # Only SHA-256 digests of tokens and codes are stored.
  hash_token_secrets

  # Public clients must prove possession of the code: S256 only, never plain.
  force_pkce
  pkce_code_challenge_methods %w[S256]

  grant_flows %w[authorization_code]

  # The scope list itself is set in to_prepare below: app constants cannot be
  # autoloaded from an initializer. Unknown scopes are refused.
  enforce_configured_scopes

  # Copied grant -> token -> refreshed token, so each carries the connection
  # (the member's approval) it was issued under. Stamped server-side only.
  custom_access_token_attributes [:connection_id]

  # https redirect URIs only, except loopback (RFC 8252 native clients).
  force_ssl_in_redirect_uri ->(uri) { !::Oauth::RedirectUris.loopback?(uri) }

  # A refused authorize request goes back to the client as an error redirect.
  handle_auth_errors :redirect
end

# Doorkeeper decides "ignore the port" with IPAddr, which never treats the name
# `localhost` as loopback, so `http://localhost:53122/cb` would not match a
# registered `http://localhost/cb`. Claude Code and Codex register exactly that
# and then listen on a random port. Ours is the one definition of loopback
# (::Oauth::RedirectUris); the version-pin test in
# test/config/doorkeeper_config_test.rb says when to re-check this patch.
module OauthLoopbackUriChecker
  def loopback_uri?(uri)
    ::Oauth::RedirectUris.loopback?(uri)
  end
end

Rails.application.config.to_prepare do
  # The API scopes plus offline_access, which is accepted from clients that
  # send it (Codex does) and not stored: refresh tokens are always issued.
  # Goes through Doorkeeper's own builder so it stays a supported setting.
  Doorkeeper::Config::Builder.new(Doorkeeper.config) do
    optional_scopes(*Api::Scopes.all, "offline_access")
  end
  Doorkeeper.config.remove_instance_variable(:@scopes) if Doorkeeper.config.instance_variable_defined?(:@scopes)

  singleton = Doorkeeper::OAuth::Helpers::URIChecker.singleton_class
  singleton.prepend(OauthLoopbackUriChecker) unless singleton.include?(OauthLoopbackUriChecker)
end
