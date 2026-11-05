# frozen_string_literal: true

module Api
  # POST /api/mcp/admin: the admin OpenAPI document's tools, for tokens that
  # hold at least the site's admin read scope (spec D3, D8).
  #
  # Everything else is Api::McpController's: the transport, the factory, the
  # logging, and the rate limit (an admin token's verdict comes from its tier).
  # This subclass changes only which document the catalogue is built from and
  # which scope gets a request in. The listing is then filtered by each tool's
  # own scope, and the REST controller behind a call enforces its scope and
  # policies again.
  class McpAdminController < ::Api::McpController
    self.mcp_document = :admin

    private

    def required_scope = "#{Current.domain}:admin:read"
  end
end
