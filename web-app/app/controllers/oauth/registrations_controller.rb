# frozen_string_literal: true

module Oauth
  # Dynamic Client Registration (RFC 7591, spec D6). MCP clients that have never
  # seen this server (Claude Code, Codex, claude.ai) register themselves here
  # before they start the authorization flow. Every client is public: PKCE
  # stands in for a secret, so no secret is generated, stored or returned.
  #
  # The endpoint is unauthenticated, so every request is counted against the
  # per-address `:oauth_register` window before anything is parsed. A client
  # inside a connector egress range shares that range's larger budget.
  #
  # The body is read raw and parsed here, never through `params`, so a
  # malformed body is answered in the RFC's own error shape instead of Rails'
  # generic 400.
  #
  # The request's own fields are validated against what this server supports
  # (P-k); fields it does not know are ignored, as RFC 7591 allows.
  class RegistrationsController < ActionController::API
    include CurrentDomain
    include Cacheable
    include VisitorIp
    include ::Api::ErrorRendering

    MAX_REDIRECT_URIS = 10
    MAX_REDIRECT_URI_LENGTH = 2_000
    MAX_CLIENT_NAME_LENGTH = 100
    DEFAULT_CLIENT_NAME = "MCP client"
    SUPPORTED_GRANT_TYPES = %w[authorization_code refresh_token].freeze

    # Raised for a request this server refuses; carries the RFC 7591 error code.
    class Rejected < StandardError
      attr_reader :error

      def initialize(error, description)
        @error = error
        super(description)
      end
    end

    before_action :prevent_caching
    before_action :enforce_registration_rate_limit!

    def create
      metadata = parse_metadata
      redirect_uris = validated_redirect_uris(metadata)
      client_name = validated_client_name(metadata)
      validate_supported_fields(metadata)

      application = OauthApplication.create!(
        name: client_name,
        redirect_uri: redirect_uris.join("\n"),
        scopes: "",
        confidential: false
      )

      render json: registration_response(application, redirect_uris), status: :created
    rescue Rejected => error
      render json: {error: error.error, error_description: error.message}, status: :bad_request
    end

    private

    def enforce_registration_rate_limit!
      verdict = Services::Api::RateLimiter.hit_ip(:oauth_register, visitor_ip)
      apply_rate_limit_headers(verdict)
      render_rate_limited(verdict) if verdict.exceeded?
    end

    def parse_metadata
      metadata = JSON.parse(request.raw_post)
      return metadata if metadata.is_a?(Hash)

      raise Rejected.new("invalid_client_metadata", "The request body must be a JSON object")
    rescue JSON::ParserError
      raise Rejected.new("invalid_client_metadata", "The request body is not valid JSON")
    end

    def validated_redirect_uris(metadata)
      uris = metadata["redirect_uris"]
      unless uris.is_a?(Array) && uris.size.between?(1, MAX_REDIRECT_URIS)
        raise Rejected.new("invalid_redirect_uri", "redirect_uris must be an array of 1 to #{MAX_REDIRECT_URIS} URIs")
      end

      uris.each do |uri|
        valid = uri.is_a?(String) && uri.length <= MAX_REDIRECT_URI_LENGTH && ::Oauth::RedirectUris.valid_registration?(uri)
        raise Rejected.new("invalid_redirect_uri", "Each redirect URI must be https, or http on localhost, 127.0.0.1 or [::1], with no fragment or credentials") unless valid
      end
      uris
    end

    def validated_client_name(metadata)
      return DEFAULT_CLIENT_NAME unless metadata.key?("client_name")

      name = metadata["client_name"]
      unless name.is_a?(String) && name.length <= MAX_CLIENT_NAME_LENGTH
        raise Rejected.new("invalid_client_metadata", "client_name must be a string of at most #{MAX_CLIENT_NAME_LENGTH} characters")
      end

      name.presence || DEFAULT_CLIENT_NAME
    end

    def validate_supported_fields(metadata)
      if metadata.key?("token_endpoint_auth_method") && metadata["token_endpoint_auth_method"] != "none"
        raise Rejected.new("invalid_client_metadata", "Only token_endpoint_auth_method \"none\" is supported")
      end

      if metadata.key?("grant_types")
        grants = metadata["grant_types"]
        unless grants.is_a?(Array) && grants.all? { |grant| SUPPORTED_GRANT_TYPES.include?(grant) }
          raise Rejected.new("invalid_client_metadata", "grant_types may only contain #{SUPPORTED_GRANT_TYPES.join(" and ")}")
        end
      end

      if metadata.key?("response_types") && metadata["response_types"] != ["code"]
        raise Rejected.new("invalid_client_metadata", "Only response_types [\"code\"] is supported")
      end
    end

    def registration_response(application, redirect_uris)
      {
        client_id: application.uid,
        client_id_issued_at: application.created_at.to_i,
        client_name: application.name,
        redirect_uris: redirect_uris,
        grant_types: SUPPORTED_GRANT_TYPES,
        response_types: ["code"],
        token_endpoint_auth_method: "none"
      }
    end
  end
end
