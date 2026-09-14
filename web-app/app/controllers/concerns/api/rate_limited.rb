# frozen_string_literal: true

module Api
  # Counts the authenticated request against its account's windows and answers
  # 429 when one is exhausted. Headers are set here, in the before_action, so
  # every later render -- success, 404, 429 -- carries them without an
  # after_action. Requires current_principal (Api::Authentication) to have run.
  #
  # apply_rate_limit_headers is also used by Api::Authentication for the
  # unauthenticated IP window; that verdict has no day window and emits only
  # the minute triple.
  module RateLimited
    extend ActiveSupport::Concern

    included do
      before_action :enforce_rate_limit!
    end

    private

    def enforce_rate_limit!
      verdict = Services::Api::RateLimiter.hit(current_principal)
      apply_rate_limit_headers(verdict)
      return unless verdict.exceeded?

      render_rate_limited(verdict)
    end

    def render_rate_limited(verdict)
      retry_after = verdict.retry_after
      response.headers["Retry-After"] = retry_after.to_s
      window = if verdict.minute.exceeded?
        "Per-minute limit of #{verdict.minute.limit}"
      else
        "Daily limit of #{verdict.day.limit}"
      end
      render_problem(::Api::Problem.new(:rate_limited, detail: "#{window} requests reached. Retry after #{retry_after} seconds."))
    end

    def apply_rate_limit_headers(verdict)
      minute = verdict.minute
      response.headers["X-RateLimit-Limit"] = minute.limit.to_s
      response.headers["X-RateLimit-Remaining"] = minute.remaining.to_s
      response.headers["X-RateLimit-Reset"] = minute.reset_at.to_i.to_s

      day = verdict.day
      return if day.nil?

      response.headers["X-RateLimit-Daily-Limit"] = day.limit.to_s
      response.headers["X-RateLimit-Daily-Remaining"] = day.remaining.to_s
      response.headers["X-RateLimit-Daily-Reset"] = day.reset_at.to_i.to_s
    end
  end
end
