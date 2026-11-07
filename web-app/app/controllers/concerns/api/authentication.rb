# frozen_string_literal: true

module Api
  # Resolves the bearer token into current_principal, or halts with an RFC 6750
  # response. Unauthenticated failures count against a per-IP window so junk
  # cannot turn into database load; an address already over that window is
  # refused before any lookup. Requires VisitorIp and Api::RateLimited's
  # apply_rate_limit_headers.
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :authenticate!
    end

    private

    attr_reader :current_principal

    def authenticate!
      peek = Services::Api::RateLimiter.peek_unauthenticated(visitor_ip)
      if peek.exceeded?
        apply_rate_limit_headers(peek)
        return render_rate_limited(peek)
      end

      result = Services::Api::Authenticator.call(request)
      if result.success?
        @current_principal = result.data
        return
      end

      # Every failed-auth outcome below -- membership_required included -- counts
      # against the visitor-IP window, so a rejected token can't be replayed for
      # free database load.
      apply_rate_limit_headers(Services::Api::RateLimiter.hit_unauthenticated(visitor_ip))

      case result.errors.first
      when :membership_required
        render_problem(::Api::Problem.new(
          :membership_required,
          detail: "API access is a membership benefit. Membership covers every site."
        ))
      when :unauthenticated
        render_problem(::Api::Problem.new(:unauthenticated, detail: "Send a personal access token as `Authorization: Bearer <token>`."),
          www_authenticate: bearer_challenge)
      else
        render_problem(::Api::Problem.new(:invalid_token, detail: "The token is malformed, unknown, revoked or expired."),
          www_authenticate: bearer_challenge("invalid_token"))
      end
    end

    # The RFC 6750 `WWW-Authenticate` value for a 401. On a path that is an OAuth
    # resource it also points at the protected-resource metadata (RFC 9728) and
    # names the scope to ask for, which is how a connector discovers where to sign
    # in. Every other path keeps the bare challenge.
    def bearer_challenge(error = nil)
      parts = []
      parts << %(error="#{error}") if error
      resource = ::Oauth::Resources.for_path(request.path)
      if resource
        parts << %(resource_metadata="#{::Api::Host.base_url}#{resource.metadata_path}")
        parts << %(scope="#{resource.scopes(Current.domain).join(" ")}")
      end
      parts.empty? ? "Bearer" : "Bearer #{parts.join(", ")}"
    end
  end
end
