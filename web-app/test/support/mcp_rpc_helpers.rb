# JSON-RPC helpers for the MCP endpoint tests (/api/mcp and /api/mcp/admin).
# A test class includes this and overrides `mcp_path` to aim at another
# endpoint; any call can also pass `path:`.
module McpRpcHelpers
  MODERN_VERSION = "2026-07-28"

  def mcp_path = "/api/mcp"

  def json = response.parsed_body

  def post_raw(body, token: ApiTokenSecrets::MEMBER, headers: {}, path: mcp_path)
    post path, params: body, headers: {
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }.merge(token ? bearer(token) : {}).merge(headers)
  end

  def rpc(method, params = {}, id: 1, token: ApiTokenSecrets::MEMBER, headers: {}, path: mcp_path)
    post_raw({jsonrpc: "2.0", id: id, method: method, params: params}.to_json, token: token, headers: headers, path: path)
  end

  def call_tool(name, arguments = {}, **options)
    rpc("tools/call", {name: name, arguments: arguments}, **options)
  end

  def initialize_params
    {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: "test", version: "1"}}
  end

  def tool_text = JSON.parse(json.dig("result", "content", 0, "text"))

  # The 2026-07-28 lifecycle (what Claude Code speaks): no initialize, the
  # version on a header and in every request's _meta, the method and name
  # mirrored in headers.
  def modern_rpc(method, params = {}, name: nil, token: ApiTokenSecrets::MEMBER, path: mcp_path)
    meta = {
      "io.modelcontextprotocol/protocolVersion" => MODERN_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {},
      "io.modelcontextprotocol/clientInfo" => {name: "test", version: "1"}
    }
    headers = {"MCP-Protocol-Version" => MODERN_VERSION, "Mcp-Method" => method}
    headers["Mcp-Name"] = name if name
    rpc(method, params.merge(_meta: meta), token: token, headers: headers, path: path)
  end
end
