require "test_helper"

module Api
  class McpControllerTest < ActionDispatch::IntegrationTest
    include McpRpcHelpers

    RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
      X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

    setup do
      host! "dev-new.thegreatestbooks.org"
      @war_and_peace = books_books(:war_and_peace)
    end

    # Every info line the block logs, so a test can pick out the MCP one.
    def capture_log_lines
      lines = []
      Rails.logger.stubs(:info).with { |message| lines << message.to_s }
      yield
      lines
    end

    def mcp_log_line(lines) = lines.find { |message| message.start_with?("event=api_mcp") }

    test "initialize answers as a stateless JSON server" do
      rpc("initialize", initialize_params)

      assert_response :success
      assert_equal "the-greatest-books", json.dig("result", "serverInfo", "name")
      assert_nil response.headers["Mcp-Session-Id"]
      assert response.headers["Content-Type"].start_with?("application/json")
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end

    test "a second initialize also succeeds" do
      rpc("initialize", initialize_params)
      rpc("initialize", initialize_params, id: 2)

      assert_response :success
      assert_equal 2, json["id"]
    end

    test "notifications/initialized is a 202 with an empty body" do
      post_raw({jsonrpc: "2.0", method: "notifications/initialized"}.to_json)

      assert_response :accepted
      assert_equal "", response.body
    end

    test "tools/list lists the catalogue and never a paging name" do
      rpc("tools/list")

      assert_response :success
      names = json.dig("result", "tools").map { |tool| tool["name"] }
      assert_includes names, "get_book"
      assert_includes names, "list_books"
      assert_includes names, "search_books"
      assert names.none? { |name| name.include?("per_page") }
    end

    test "tools/call get_book returns the REST body" do
      call_tool("get_book", {slug: @war_and_peace.slug})
      assert_response :success
      assert_equal false, json.dig("result", "isError")
      from_tool = tool_text

      get "/api/v1/books/#{@war_and_peace.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_equal response.parsed_body.except("links"), from_tool
    end

    test "tools/call list_books with a filter and a limit returns the REST body" do
      RankedItem.create!(item: @war_and_peace, ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: ranking_configurations(:books_global), rank: 2, score: 90)

      call_tool("list_books", {year: 1869, limit: 5})
      assert_equal false, json.dig("result", "isError")
      from_tool = tool_text

      get "/api/v1/books?year=1869&per_page=5", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_equal response.parsed_body.except("links"), from_tool
      assert_equal %w[war-and-peace], from_tool["data"].map { |book| book["slug"] }
      assert_equal({"year" => 1869}, from_tool.dig("meta", "filters"))
    end

    test "tools/call get_book on a missing slug carries the REST problem" do
      call_tool("get_book", {slug: "no-such-book"})
      assert_equal true, json.dig("result", "isError")
      from_tool = tool_text

      get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_response :not_found
      assert_equal [response.parsed_body["code"], response.parsed_body["detail"]], [from_tool["code"], from_tool["detail"]]
    end

    test "tools/call list_books with limit 0 carries the REST invalid_parameter problem" do
      call_tool("list_books", {limit: 0})
      assert_equal true, json.dig("result", "isError")
      from_tool = tool_text

      get "/api/v1/books?per_page=0", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_response :bad_request
      assert_equal "invalid_parameter", from_tool["code"]
      assert_equal response.parsed_body["detail"], from_tool["detail"]
    end

    test "tools/call with an unknown argument is an invalid_parameter error" do
      call_tool("list_books", {bogus: 1})

      assert_equal true, json.dig("result", "isError")
      assert_equal "invalid_parameter", tool_text["code"]
    end

    test "tools/call with a missing required argument is the gem's error" do
      call_tool("get_book", {})

      assert_equal true, json.dig("result", "isError")
      assert_equal "Missing required arguments: slug", json.dig("result", "content", 0, "text")
    end

    test "tools/call works with and without an MCP-Protocol-Version header" do
      [{}, {"MCP-Protocol-Version" => "2025-06-18"}].each do |headers|
        call_tool("get_book", {slug: @war_and_peace.slug}, headers: headers)

        assert_response :success, headers.inspect
        assert_equal false, json.dig("result", "isError"), headers.inspect
      end
    end

    test "modern tools/call get_book is stateless and returns the REST body" do
      modern_rpc("tools/call", {name: "get_book", arguments: {slug: @war_and_peace.slug}}, name: "get_book")

      assert_response :success
      assert_nil response.headers["Mcp-Session-Id"]
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_equal false, json.dig("result", "isError")
      from_tool = tool_text

      get "/api/v1/books/#{@war_and_peace.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_equal response.parsed_body.except("links"), from_tool
    end

    test "modern server/discover returns the instructions" do
      modern_rpc("server/discover")

      assert_response :success
      assert_nil response.headers["Mcp-Session-Id"]
      assert_includes json.dig("result", "instructions"), "url"
    end

    test "a modern request with no token is the REST 401" do
      modern_rpc("tools/call", {name: "get_book", arguments: {slug: @war_and_peace.slug}}, name: "get_book", token: nil)

      assert_response :unauthorized
      assert_equal "unauthenticated", json["code"]
    end

    test "the response keeps the Content-Type the transport chose" do
      sse = "event: message\ndata: {}\n\n"
      ::MCP::Server::Transports::StreamableHTTPTransport.any_instance.stubs(:handle_request)
        .returns([200, {"content-type" => "text/event-stream"}, [sse]])

      rpc("tools/list")

      assert_response :success
      assert response.headers["Content-Type"].start_with?("text/event-stream")
      assert_equal sse, response.body
    end

    test "the global MCP exception reporter forwards to Rails.error" do
      error = RuntimeError.new("boom")
      Rails.error.expects(:report).with(error)

      ::MCP.configuration.exception_reporter.call(error, {})
    end

    test "an unknown tool is a JSON-RPC invalid params error" do
      call_tool("no_such_tool")

      assert_equal(-32602, json.dig("error", "code"))
    end

    test "no token is the REST 401" do
      rpc("tools/list", token: nil)

      assert_response :unauthorized
      assert_equal "unauthenticated", json["code"]
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
    end

    test "a non-member is a 403 membership_required" do
      rpc("tools/list", token: ApiTokenSecrets::NON_MEMBER)

      assert_response :forbidden
      assert_equal "membership_required", json["code"]
    end

    test "a token without the site's read scope is a 403 insufficient_scope" do
      rpc("tools/list", token: ApiTokenSecrets::MUSIC_ONLY)

      assert_response :forbidden
      assert_equal "insufficient_scope", json["code"]
    end

    test "an exhausted limit is a 429 with the rate-limit headers" do
      with_exhausted_limit { rpc("tools/list") }

      assert_response :too_many_requests
      RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
    end

    test "one MCP request is one rate-limit hit and one record_use" do
      verdict = Services::Api::RateLimiter::Verdict.new(
        minute: Services::Api::RateLimiter::Window.new(limit: 60, remaining: 59, reset_at: 30.seconds.from_now, exceeded: false),
        day: Services::Api::RateLimiter::Window.new(limit: 5000, remaining: 4999, reset_at: 1.day.from_now, exceeded: false)
      )
      Services::Api::RateLimiter.expects(:hit).once.returns(verdict)
      Services::Api::Tokens.expects(:record_use).once

      call_tool("list_books")

      assert_response :success
      assert_equal false, json.dig("result", "isError")
    end

    test "prompts/get usage answers with the rules" do
      rpc("prompts/get", {name: "usage"})

      assert_response :success
      assert_includes json.dig("result", "messages", 0, "content", "text"), "never invent a rank"
    end

    test "resources/list includes the methodology and resources/read returns its text" do
      rpc("resources/list")
      assert_includes json.dig("result", "resources").map { |resource| resource["uri"] }, "greatest://books/ranking-methodology"

      rpc("resources/read", {uri: "greatest://books/ranking-methodology"})
      assert_response :success
      assert_equal "text/markdown", json.dig("result", "contents", 0, "mimeType")
      assert_includes json.dig("result", "contents", 0, "text"), "ranking configuration"
    end

    test "initialize carries the instructions" do
      rpc("initialize", initialize_params)

      assert_includes json.dig("result", "instructions"), "url"
    end

    test "tools/list includes find_book for a books reader" do
      rpc("tools/list")

      assert_includes json.dig("result", "tools").map { |tool| tool["name"] }, "find_book"
    end

    test "tools/call find_book is one rate-limit hit however many dispatches it makes" do
      ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: @war_and_peace.id.to_s, score: 1.0, source: {}}])
      verdict = Services::Api::RateLimiter::Verdict.new(
        minute: Services::Api::RateLimiter::Window.new(limit: 60, remaining: 59, reset_at: 30.seconds.from_now, exceeded: false),
        day: Services::Api::RateLimiter::Window.new(limit: 5000, remaining: 4999, reset_at: 1.day.from_now, exceeded: false)
      )
      Services::Api::RateLimiter.expects(:hit).once.returns(verdict)

      call_tool("find_book", {title: "War and Peace"})

      assert_equal false, json.dig("result", "isError")
      assert_equal @war_and_peace.slug, tool_text.dig("book", "slug")
    end

    test "GET and DELETE are 405 with Allow: POST" do
      get "/api/mcp", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]

      delete "/api/mcp", headers: bearer(ApiTokenSecrets::MEMBER)
      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]
    end

    test "a malformed JSON-RPC body is a 4xx JSON-RPC error, never a 500" do
      ['{"jsonrpc":', "[]", '"x"'].each do |body|
        post_raw(body)

        assert_includes 400..499, response.status, body
        assert json.dig("error", "code").present?, body
      end
    end

    test "the endpoint is not served on the music host" do
      host! Rails.application.config.domains[:music].split(",").first
      rpc("tools/list")

      assert_response :not_found
    end

    test "a tools/call is logged with the method, the tool and the user, never the token" do
      lines = capture_log_lines { call_tool("get_book", {slug: @war_and_peace.slug}) }

      assert_match(%r{\Aevent=api_mcp rpc_method=tools/call tool=get_book user_id=\d+\z}, mcp_log_line(lines))
      assert lines.none? { |message| message.include?(ApiTokenSecrets::MEMBER) }
    end

    test "a tools/list is logged without a tool" do
      lines = capture_log_lines { rpc("tools/list") }

      assert_match(%r{\Aevent=api_mcp rpc_method=tools/list tool=- user_id=\d+\z}, mcp_log_line(lines))
    end

    test "an unparsable body is logged without a method or tool" do
      lines = capture_log_lines { post_raw('{"jsonrpc":') }

      assert_match(/\Aevent=api_mcp rpc_method=- tool=- user_id=\d+\z/, mcp_log_line(lines))
    end

    test "an invalid-UTF-8 method is logged as - and answered with a 4xx, never a 500" do
      body = %({"jsonrpc":"2.0","id":1,"method":"\xFF"}).b
      lines = capture_log_lines { post_raw(body, headers: {"Content-Type" => "text/plain"}) }

      assert_includes 400..499, response.status
      assert_match(/\Aevent=api_mcp rpc_method=- tool=- user_id=\d+\z/, mcp_log_line(lines))
    end

    test "a batch body is logged as a batch" do
      lines = capture_log_lines { post_raw([{jsonrpc: "2.0", id: 1, method: "tools/list"}].to_json) }

      assert_match(/\Aevent=api_mcp rpc_method=batch tool=- user_id=\d+\z/, mcp_log_line(lines))
    end
  end
end
