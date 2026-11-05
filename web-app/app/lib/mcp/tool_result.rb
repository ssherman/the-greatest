# frozen_string_literal: true

module Mcp
  # Turns an API response (Mcp::Dispatcher::Response) into an MCP tool result
  # (spec D11). Failures stay inside the protocol as isError results so the
  # agent can read the problem and recover; only transport problems are HTTP.
  module ToolResult
    # The REST `links` member points at REST URLs, which mean nothing to a tool
    # caller, so it is dropped from successes.
    def self.from(response)
      if (200..299).cover?(response.status)
        build(success_payload(response.body), error: false)
      else
        error(response.body || {"code" => fallback_code(response.status)})
      end
    end

    def self.error(body)
      build(body, error: true)
    end

    def self.success_payload(body)
      case body
      when nil then {}
      when Hash then body.except("links")
      else body
      end
    end
    private_class_method :success_payload

    # A non-JSON error: the router's no-route 404, or a proxy's 502.
    def self.fallback_code(status)
      (status == 404) ? "not_found" : "internal_error"
    end
    private_class_method :fallback_code

    def self.build(payload, error:)
      ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(payload)}], error: error)
    end
    private_class_method :build
  end
end
