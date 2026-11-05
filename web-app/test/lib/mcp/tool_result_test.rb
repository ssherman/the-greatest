require "test_helper"

module Mcp
  class ToolResultTest < ActiveSupport::TestCase
    def response_for(status, body)
      Mcp::Dispatcher::Response.new(status: status, body: body)
    end

    def text_of(tool_response)
      JSON.parse(tool_response.to_h[:content].first[:text])
    end

    test "a 2xx response is the JSON body without links" do
      result = Mcp::ToolResult.from(response_for(200, {"data" => [1], "meta" => {}, "links" => {"self" => "x"}}))

      assert_equal false, result.to_h[:isError]
      assert_equal "text", result.to_h[:content].first[:type]
      assert_equal({"data" => [1], "meta" => {}}, text_of(result))
    end

    test "a 2xx response with an empty body is an empty object" do
      result = Mcp::ToolResult.from(response_for(204, nil))

      assert_equal false, result.to_h[:isError]
      assert_equal({}, text_of(result))
    end

    test "a 2xx response whose body is not a Hash is emitted as is" do
      assert_equal [1, 2], text_of(Mcp::ToolResult.from(response_for(200, [1, 2])))
    end

    test "a problem body is the whole error" do
      problem = {"type" => "t", "title" => "Not found", "status" => 404, "code" => "not_found", "detail" => "No such book", "merged" => [1]}

      result = Mcp::ToolResult.from(response_for(404, problem))

      assert_equal true, result.to_h[:isError]
      assert_equal problem, text_of(result)
    end

    test "a 404 with no body is not_found" do
      result = Mcp::ToolResult.from(response_for(404, nil))

      assert_equal true, result.to_h[:isError]
      assert_equal({"code" => "not_found"}, text_of(result))
    end

    test "a 502 with no body is internal_error" do
      assert_equal({"code" => "internal_error"}, text_of(Mcp::ToolResult.from(response_for(502, nil))))
    end

    test "a 503 search_unavailable problem keeps its code" do
      result = Mcp::ToolResult.from(response_for(503, {"code" => "search_unavailable", "status" => 503}))

      assert_equal true, result.to_h[:isError]
      assert_equal "search_unavailable", text_of(result)["code"]
    end

    test "error wraps a hash as an isError result" do
      result = Mcp::ToolResult.error({"code" => "x"})

      assert_equal true, result.to_h[:isError]
      assert_equal({"code" => "x"}, text_of(result))
    end
  end
end
