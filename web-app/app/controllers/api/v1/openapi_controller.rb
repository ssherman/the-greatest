# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/openapi.json -- public, no token, cacheable for an hour.
    # Not a BaseController subclass on purpose: that base authenticates.
    #
    # It is still behind the API's per-IP unauthenticated window: the edge skips
    # Cloudflare's own rate limiting for /api/*, and until the new books host
    # has a cache rule this document is served from Rails on every request, so
    # without this an unauthenticated client could hit it without limit. The
    # window is shared with 401s from the same address, which is the intent --
    # it is one budget for "requests this IP made without a token".
    class OpenapiController < ActionController::API
      include CurrentDomain
      include VisitorIp
      include ::Api::ErrorRendering

      before_action :enforce_ip_window!

      def show
        expires_in 1.hour, public: true
        render json: ::Api::OpenapiDocument.for_host(::Api::Host.base_url, domain: Current.domain)
      end

      private

      # Headers only on the 429: a successful response is edge-cacheable, and a
      # cached copy carrying one caller's remaining count would mislead the next.
      def enforce_ip_window!
        verdict = Services::Api::RateLimiter.hit_unauthenticated(visitor_ip)
        return unless verdict.exceeded?

        apply_rate_limit_headers(verdict)
        render_rate_limited(verdict)
      end
    end
  end
end
