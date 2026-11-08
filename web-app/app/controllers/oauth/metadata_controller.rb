# frozen_string_literal: true

module Oauth
  # The two OAuth discovery documents (spec D3, D8, D9): RFC 8414 authorization
  # server metadata and RFC 9728 protected resource metadata. Public and
  # identical for every caller, so they are edge-cacheable like the OpenAPI
  # document. Hand-written hashes: the mcp gem's ProtectedResourceMetadata
  # belongs to its Rack middleware and adds nothing here.
  #
  # Every URL comes from Api::Host.base_url, never request.host.
  #
  # The authorization server document deliberately omits
  # authorization_response_iss_parameter_supported (RFC 9207), so clients
  # use their per-server callback path, which dynamic registration records.
  class MetadataController < ActionController::API
    include CurrentDomain

    def authorization_server
      base = ::Api::Host.base_url
      render_document(
        issuer: base,
        authorization_endpoint: base + "/oauth/authorize",
        token_endpoint: base + "/api/oauth/token",
        registration_endpoint: base + "/api/oauth/register",
        revocation_endpoint: base + "/api/oauth/revoke",
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        code_challenge_methods_supported: ["S256"],
        token_endpoint_auth_methods_supported: ["none"],
        scopes_supported: ::Oauth::Resources.all_scopes(Current.domain) + ["offline_access"]
      )
    end

    def protected_resource
      base = ::Api::Host.base_url
      resource = ::Oauth::Resources.fetch(params[:resource_key])
      render_document(
        resource: resource.url(base),
        authorization_servers: [base],
        scopes_supported: resource.scopes(Current.domain),
        bearer_methods_supported: ["header"]
      )
    end

    private

    def render_document(document)
      expires_in 1.hour, public: true
      render json: document
    end
  end
end
