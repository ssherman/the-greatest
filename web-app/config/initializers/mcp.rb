# frozen_string_literal: true

# The mcp gem's transport reports its own exceptions (a response it cannot
# serialise, an error escaping the server) through the global configuration, not
# the per-server one Mcp::ServerFactory passes. Without this they are dropped.
MCP.configure do |config|
  config.exception_reporter = ->(error, _context) { Rails.error.report(error) }
end
