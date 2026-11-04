# frozen_string_literal: true

module Api
  # Counts the authenticated request against its account's windows and answers
  # 429 when one is exhausted. Headers are set here, in the before_action, so
  # every later render -- success, 404, 429 -- carries them without an
  # after_action. Requires current_principal (Api::Authentication) to have run
  # and the rendering helpers from Api::ErrorRendering.
  #
  # A request dispatched in-process by the MCP server (Api::DispatchedRequest)
  # is not counted: the outer /api/mcp POST already took its one hit and its
  # response carries the headers. The MCP dispatcher is the only writer of the
  # dispatched flag, so this sets no headers and counts nothing.
  module RateLimited
    extend ActiveSupport::Concern

    included do
      before_action :enforce_rate_limit!
    end

    private

    def enforce_rate_limit!
      return if ::Api::DispatchedRequest.dispatched?(request.env)

      verdict = Services::Api::RateLimiter.hit(current_principal)
      apply_rate_limit_headers(verdict)
      return unless verdict.exceeded?

      render_rate_limited(verdict)
    end
  end
end
