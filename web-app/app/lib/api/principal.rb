# frozen_string_literal: true

# Who is calling the API and what they may do. Built only by
# Services::Api::Authenticator; controllers read it and never look at a token.
# `token` is an ApiToken (a personal access token) or an OauthAccessToken (a
# connector's sign-in); both authenticate into this same struct and nothing
# downstream changes. `token_kind` says which, for audit lines.
module Api
  Principal = Struct.new(:user, :token, :scopes, :tier, keyword_init: true) do
    def scope?(required) = Api::Scopes.satisfies?(scopes, required)

    def token_kind = token.is_a?(::OauthAccessToken) ? "oauth" : "personal"
  end
end
