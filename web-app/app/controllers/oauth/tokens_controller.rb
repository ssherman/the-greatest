# frozen_string_literal: true

module Oauth
  # The token endpoint (spec D11): authorization-code exchange, refresh, and
  # revocation. Doorkeeper's controller does the protocol (PKCE, client match,
  # scope checks, rotation); this one adds what it cannot know, in this order:
  #
  #   1. the per-address `:oauth_token` window, counted before anything else, so
  #      guessing codes and refresh tokens is throttled. An address inside a
  #      connector egress range shares that range's larger budget;
  #   2. Services::Oauth::TokenGate: reuse, lapse and resource refusals, which
  #      answer before Doorkeeper creates any row.
  #
  # Every response is `no-store`. The client is public: a bare `client_id` stands
  # in for credentials, and PKCE is the proof of possession.
  class TokensController < Doorkeeper::TokensController
    include CurrentDomain
    include Cacheable
    include VisitorIp
    include ::Api::ErrorRendering

    REFUSALS = {
      invalid_grant: "The grant is invalid, expired, revoked, or was issued to another client",
      invalid_target: "The resource does not match the one this authorization was granted for"
    }.freeze

    prepend_before_action :enforce_token_rate_limit!
    before_action :prevent_caching

    def create
      result = ::Services::Oauth::TokenGate.call(params: params, domain: current_domain)
      return render_refusal(result.errors.first) unless result.success?

      super
    end

    private

    def enforce_token_rate_limit!
      verdict = ::Services::Api::RateLimiter.hit_ip(:oauth_token, visitor_ip)
      apply_rate_limit_headers(verdict)
      return unless verdict.exceeded?

      prevent_caching
      render_rate_limited(verdict)
    end

    def render_refusal(code)
      render json: {error: code, error_description: REFUSALS.fetch(code)}, status: :bad_request
    end
  end
end
