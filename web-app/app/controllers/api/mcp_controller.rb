# frozen_string_literal: true

module Api
  # POST /api/mcp: the site's tools over MCP's Streamable HTTP transport, in
  # the gem's stateless JSON mode (spec D2, D3).
  #
  # Inheriting Api::V1::BaseController is the point (D4): the domain, the
  # no-store header, the bearer token, the rate limit and the scope all run
  # before any MCP server is built, so an unauthenticated or over-quota request
  # costs nothing and gets the REST bodies. For the same reason the transport's
  # own `token_verifier` is not passed: there is one authenticator.
  #
  # GET and DELETE are routed to #method_not_allowed and never reach the
  # transport (in stateless mode it answers DELETE with a 200, and there is no
  # stream to GET).
  #
  # Nothing here reads `params`: the body is a JSON-RPC document the transport
  # parses itself, and a malformed one must reach it to be answered as a
  # JSON-RPC error, not as a Rails parameter-parsing failure.
  class McpController < ::Api::V1::BaseController
    # The OpenAPI document whose operations this endpoint serves. Increment 2
    # subclasses this controller for :admin.
    class_attribute :mcp_document, default: :public

    def create
      log_request
      status, headers, body = transport.handle_request(request)

      headers.each { |name, value| response.headers[name] = value unless name.casecmp?("Cache-Control") }
      text = read(body)
      return head(status) if text.empty?

      render body: text, status: status, content_type: content_type_of(headers) || "application/json"
    end

    def method_not_allowed
      response.headers["Allow"] = "POST"
      head :method_not_allowed
    end

    private

    def required_scope = "#{Current.domain}:read"

    def transport
      server = ::Mcp::ServerFactory.build(
        document: mcp_document, domain: Current.domain, principal: current_principal, request: request
      )
      ::MCP::Server::Transports::StreamableHTTPTransport.new(
        server,
        stateless: true,
        enable_json_response: true,
        serve_subscriptions_listen: false,
        allowed_hosts: ::Rails.application.config.domains.fetch(Current.domain).split(",")
      )
    end

    # The transport's own Content-Type (a modern response that carries
    # notifications is an event stream), whatever its header's case.
    def content_type_of(headers)
      headers.find { |name, _| name.to_s.casecmp?("Content-Type") }&.last.presence
    end

    def read(body)
      chunks = []
      body.each { |chunk| chunks << chunk }
      chunks.join
    ensure
      body.close if body.respond_to?(:close)
    end

    # One line per MCP POST, so API logs can split MCP traffic from REST (D15).
    # The token is never logged. The body is read raw for this and only here.
    def log_request
      rpc_method, tool = describe_rpc
      ::Rails.logger.info(
        "event=api_mcp document=#{mcp_document} rpc_method=#{rpc_method} tool=#{tool} user_id=#{current_principal.user.id}"
      )
    end

    def describe_rpc
      payload = JSON.parse(request.raw_post)
      return ["batch", "-"] if payload.is_a?(Array)
      return ["-", "-"] unless payload.is_a?(Hash)

      rpc_method = loggable(payload["method"])
      tool = (rpc_method == "tools/call" && payload["params"].is_a?(Hash)) ? loggable(payload["params"]["name"]) : "-"
      [rpc_method, tool]
    rescue JSON::ParserError, EncodingError, ArgumentError
      # Logging must never fail the request: whatever the body is, the
      # transport answers it.
      ["-", "-"]
    end

    # A value from the wire, kept to a short token so it cannot forge a second
    # log field or a second line.
    def loggable(value)
      (value.is_a?(String) && value.valid_encoding? && value.match?(%r{\A[\w./-]{1,100}\z})) ? value : "-"
    end
  end
end
