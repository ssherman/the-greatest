# frozen_string_literal: true

# The two Rack env keys an in-process dispatch uses to tell an API controller
# "this request is already authenticated and already counted". The MCP
# dispatcher (Mcp::Dispatcher) is the only writer: it authenticates and counts
# the outer /api/mcp POST once, then calls the API controllers through
# Rails.application.routes.call with an env marked here.
#
# Neither key has an HTTP_ prefix. Rack builds every request-header entry as
# HTTP_<NAME>, so no client header, whatever it is called, can ever land under
# these keys. That is the whole security argument: only server code holding the
# env can set them.
module Api
  module DispatchedRequest
    PRINCIPAL_KEY = "the_greatest.api.principal"
    DISPATCHED_KEY = "the_greatest.api.dispatched"

    # Stamps the env and returns it.
    def self.mark(env, principal)
      env[PRINCIPAL_KEY] = principal
      env[DISPATCHED_KEY] = true
      env
    end

    def self.principal(env) = env[PRINCIPAL_KEY]

    def self.dispatched?(env) = env[DISPATCHED_KEY] == true
  end
end
