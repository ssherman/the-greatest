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
          www_authenticate: "Bearer")
      else
        render_problem(::Api::Problem.new(:invalid_token, detail: "The token is malformed, unknown, revoked or expired."),
          www_authenticate: %(Bearer error="invalid_token"))
      end
    end
  end
end
