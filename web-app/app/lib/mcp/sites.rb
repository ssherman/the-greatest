# frozen_string_literal: true

module Mcp
  # The per-site parts of an MCP endpoint: the instructions, prompts, resources
  # and composite tools that are about one site's subject matter. Everything
  # else in Mcp:: is generic. A site is a module answering instructions,
  # prompts, resources and composites for a document (:public or :admin); a
  # domain with no entry gets None, so a site with API operations carrying
  # `x-mcp` serves tools with no per-site code.
  module Sites
    module None
      def self.instructions(_document) = nil

      def self.prompts(_document) = []

      def self.resources(_document) = []

      def self.composites(_document) = []
    end

    REGISTRY = {books: ::Mcp::Sites::Books}.freeze

    def self.for(domain) = REGISTRY.fetch(domain, None)
  end
end
