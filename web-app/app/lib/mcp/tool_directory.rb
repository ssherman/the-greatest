# frozen_string_literal: true

module Mcp
  # Every tool an MCP endpoint can offer, listed without a principal. It exists
  # for documentation pages, which render for any visitor and so have no scopes
  # to filter by. It is not a listing for a request: that is
  # Mcp::ServerFactory, which offers a caller only the tools its scopes allow.
  #
  # The entries come from the same catalogue and the same site composites the
  # factory builds from, catalogue tools first in catalogue order and then the
  # site's composites, so a page that renders them cannot drift from the
  # endpoint.
  module ToolDirectory
    Entry = Struct.new(:name, :title, :description, :destructive, keyword_init: true)

    def self.entries(document:, domain:)
      catalog = ::Mcp::Catalog.for(document: document, domain: domain)

      operations = catalog.operations.map do |operation|
        Entry.new(name: operation.tool_name, title: operation.title, description: operation.description,
          destructive: operation.annotations.fetch(:destructive_hint))
      end
      composites = ::Mcp::Sites.for(domain).composites(document).map do |composite|
        Entry.new(name: composite.tool_name, title: composite.title, description: composite.description,
          destructive: composite.annotations(catalog).fetch(:destructive_hint))
      end

      operations + composites
    end
  end
end
