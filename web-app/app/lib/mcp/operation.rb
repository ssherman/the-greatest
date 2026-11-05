# frozen_string_literal: true

module Mcp
  # One REST operation as the MCP layer sees it: what to call and how each tool
  # argument maps onto the request. The catalogue generator builds these from the
  # OpenAPI document; Mcp::Dispatcher consumes them.
  #
  #   http_method  lowercase ("get")
  #   path         the OpenAPI template ("/api/v1/widgets/{slug}")
  #   arguments    Hash{String => Argument}, keyed by the tool argument's name
  Operation = Struct.new(
    :operation_id, :tool_name, :title, :description, :http_method, :path, :scope,
    :destructive, :arguments, :input_schema,
    keyword_init: true
  ) do
    # Idempotence follows the HTTP method; destructiveness is declared per
    # operation. Every hint is set explicitly because the gem defaults
    # destructive_hint (and open_world_hint) to true. This is the one method
    # table: the catalogue's tools and the composites' derived hints use it.
    def annotations
      read_only = http_method == "get"
      {
        read_only_hint: read_only,
        idempotent_hint: Operation::IDEMPOTENT_METHODS.include?(http_method),
        destructive_hint: !read_only && destructive == true,
        open_world_hint: false
      }
    end
  end

  # (Defined here, not in the Struct block above: a constant assigned in a block
  # belongs to the enclosing module, not to the struct.)
  Operation::IDEMPOTENT_METHODS = %w[get put delete].freeze

  # Where a tool argument goes on the wire (:path, :query or :body) and the name
  # it has there, which can differ from the tool argument's own name (the tool
  # says `limit`, the REST API says `per_page`).
  Operation::Argument = Struct.new(:location, :wire_name, keyword_init: true)
end
