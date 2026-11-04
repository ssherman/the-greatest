# frozen_string_literal: true

module Mcp
  # One REST operation as the MCP layer sees it: what to call and how each tool
  # argument maps onto the request. The catalogue generator builds these from the
  # OpenAPI document; Mcp::Dispatcher consumes them.
  #
  #   http_method  lowercase ("get")
  #   path         the OpenAPI template ("/api/v1/books/{slug}")
  #   arguments    Hash{String => Argument}, keyed by the tool argument's name
  Operation = Struct.new(
    :operation_id, :tool_name, :title, :description, :http_method, :path, :scope,
    :destructive, :arguments, :input_schema,
    keyword_init: true
  )

  # Where a tool argument goes on the wire (:path, :query or :body) and the name
  # it has there, which can differ from the tool argument's own name (the tool
  # says `limit`, the REST API says `per_page`).
  Operation::Argument = Struct.new(:location, :wire_name, keyword_init: true)
end
