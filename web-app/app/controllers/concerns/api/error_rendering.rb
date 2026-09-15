# frozen_string_literal: true

module Api
  # Renders ::Api::Problem bodies and maps the exceptions the API expects onto
  # them. Anything not listed here is a bug and reaches Rails' own handler
  # (a generic JSON 500) -- deliberately not rescued, so tests fail loudly
  # instead of passing against a friendly body.
  #
  # The rate-limit renderers live here rather than in Api::RateLimited so a
  # controller outside the authenticated base (Api::V1::OpenapiController) can
  # answer 429 in the same shape without inheriting the account window.
  module ErrorRendering
    extend ActiveSupport::Concern

    included do
      rescue_from ActiveRecord::RecordNotFound do
        render_problem(::Api::Problem.new(:not_found, detail: "No #{controller_name.singularize} with that slug"))
      end

      rescue_from ::Api::Page::InvalidParameter do |error|
        render_problem(::Api::Problem.new(:invalid_parameter, detail: error.message))
      end

      rescue_from ActionController::ParameterMissing do |error|
        render_problem(::Api::Problem.new(:invalid_parameter, detail: error.message))
      end
    end

    private

    def render_problem(problem, www_authenticate: nil)
      response.headers["WWW-Authenticate"] = www_authenticate if www_authenticate
      render json: problem.to_h, status: problem.status, content_type: ::Api::Problem::CONTENT_TYPE
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

    # The minute triple always; the daily triple only when the verdict has a
    # day window (the unauthenticated IP window has none).
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
