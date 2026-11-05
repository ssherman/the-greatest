# frozen_string_literal: true

module Mcp
  # Builds the MCP server for one request. It is stateless and cheap, so there is
  # one per request (spec D2): the tools are filtered to what this principal's
  # scopes allow (D8), and the server context carries the principal and the
  # outer request that each tool call hands to Mcp::Dispatcher.
  class ServerFactory
    VERSION = "1.0.0"

    def self.build(document:, domain:, principal:, request:)
      catalog = ::Mcp::Catalog.for(document: document, domain: domain)
      site = ::Mcp::Sites.for(domain)
      composites = site.composites(document).select { |composite| composite.visible_to?(principal, catalog) }

      ::MCP::Server.new(
        name: "the-greatest-#{domain}",
        version: VERSION,
        instructions: site.instructions(document),
        tools: catalog.tools_for(principal) + composites.map { |composite| composite.tool(catalog) },
        prompts: site.prompts(document),
        resources: site.resources(document),
        server_context: {principal: principal, request: request},
        configuration: ::MCP::Configuration.new(
          validate_tool_call_arguments: false,
          exception_reporter: ->(error, _context) { ::Rails.error.report(error) }
        )
      )
    end
  end
end
