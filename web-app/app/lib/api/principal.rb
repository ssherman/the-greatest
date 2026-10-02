# frozen_string_literal: true

# Who is calling the API and what they may do. Built only by
# Services::Api::Authenticator; controllers read it and never look at a token.
# When Doorkeeper access tokens arrive for the MCP server, the authenticator
# builds the same struct from them and nothing downstream changes.
module Api
  Principal = Struct.new(:user, :token, :scopes, :tier, keyword_init: true) do
    def scope?(required) = Api::Scopes.satisfies?(scopes, required)
  end
end
