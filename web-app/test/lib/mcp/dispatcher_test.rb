require "test_helper"

module Mcp
  class DispatcherTest < ActionDispatch::IntegrationTest
    Argument = Mcp::Operation::Argument

    setup { host! "dev-new.thegreatestbooks.org" }

    def operation(**attrs)
      Mcp::Operation.new(operation_id: "op", tool_name: "op", title: "Op", description: "", http_method: "get",
        path: "/api/v1/books", scope: "books:read", destructive: false, arguments: {}, input_schema: {}, **attrs)
    end

    def get_book
      operation(path: "/api/v1/books/{slug}", arguments: {"slug" => Argument.new(location: :path, wire_name: "slug")})
    end

    def list_books
      operation(arguments: {
        "limit" => Argument.new(location: :query, wire_name: "per_page"),
        "page" => Argument.new(location: :query, wire_name: "page"),
        "category_id" => Argument.new(location: :query, wire_name: "category_id")
      })
    end

    def create_category
      operation(http_method: "post", path: "/api/v1/admin/categories", scope: "books:admin:write", arguments: {
        "name" => Argument.new(location: :body, wire_name: "name"),
        "category_type" => Argument.new(location: :body, wire_name: "category_type")
      })
    end

    def outer_request(remote_ip: "203.0.113.9")
      env = Rack::MockRequest.env_for("https://dev-new.thegreatestbooks.org/api/mcp", "action_dispatch.request_id" => "req-123")
      env["action_dispatch.remote_ip"] = remote_ip
      ActionDispatch::Request.new(env)
    end

    def principal_for(secret)
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/api/mcp", "HTTP_AUTHORIZATION" => "Bearer #{secret}"))
      Services::Api::Authenticator.call(request).data
    end

    def dispatch(operation, arguments, secret: ApiTokenSecrets::MEMBER, request: outer_request)
      Mcp::Dispatcher.call(operation, arguments, principal: principal_for(secret), request: request)
    end

    def capture_process_actions
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") { |*args| events << args.last }
      yield
      events
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test "a read returns the REST body for the same arguments" do
      result = dispatch(list_books, {limit: 2, page: 1})

      get "/api/v1/books?per_page=2&page=1", headers: bearer(ApiTokenSecrets::MEMBER)

      assert_equal 200, result.status
      assert_equal response.parsed_body, result.body
    end

    test "string and symbol argument keys both work" do
      assert_equal 200, dispatch(list_books, {"limit" => 2}).status
    end

    test "path arguments are percent-encoded, including . and /" do
      events = capture_process_actions do
        ["a/b", "x.json"].each do |slug|
          result = dispatch(get_book, {slug: slug})

          assert_equal 404, result.status
          assert_equal "not_found", result.body["code"]
        end
      end

      assert_equal [["Api::V1::Books::BooksController", "show"]] * 2, events.map { |e| [e[:controller], e[:action]] }
      # Unencoded, "x.json" would route as slug "x" with format json and still 404.
      assert_equal ["a/b", "x.json"], events.map { |e| e[:params]["slug"] }
    end

    test "a blank path argument is a missing argument, never an empty segment" do
      Rails.application.routes.expects(:call).never
      book_lists = operation(path: "/api/v1/books/{slug}/lists", arguments: {"slug" => Argument.new(location: :path, wire_name: "slug")})

      [[get_book, ""], [get_book, "  "], [book_lists, ""]].each do |op, slug|
        result = dispatch(op, {slug: slug})

        assert_equal 400, result.status
        assert_equal({"code" => "invalid_parameter", "detail" => "Missing argument: slug"}, result.body)
      end
    end

    test "null arguments are omitted" do
      assert_equal 200, dispatch(list_books, {category_id: nil}).status
    end

    test "an array argument reaches the API as its 400" do
      result = dispatch(list_books, {category_id: ["a", "b"]})

      assert_equal 400, result.status
      assert_equal "invalid_parameter", result.body["code"]
    end

    test "an unknown argument is an invalid_parameter error without dispatching" do
      Rails.application.routes.expects(:call).never

      result = dispatch(list_books, {bogus: 1})

      assert_equal 400, result.status
      assert_equal({"code" => "invalid_parameter", "detail" => "Unknown argument: bogus"}, result.body)
    end

    test "several unknown arguments are named together in sorted order" do
      Rails.application.routes.expects(:call).never

      result = dispatch(list_books, {zeta: 1, alpha: 2})

      assert_equal "Unknown argument: alpha, zeta", result.body["detail"]
    end

    test "the inner request sees the outer remote_ip and request id" do
      events = capture_process_actions { dispatch(list_books, {}) }

      inner = events.first[:request]
      assert_equal "203.0.113.9", inner.remote_ip
      assert_equal "req-123", inner.request_id
    end

    test "the inner request carries the app's parameter filter so its log line stays filtered" do
      events = capture_process_actions { dispatch(list_books, {}) }

      assert_equal Rails.application.env_config["action_dispatch.parameter_filter"], events.first[:request].env["action_dispatch.parameter_filter"]
      assert_not_empty events.first[:request].env["action_dispatch.parameter_filter"]
    end

    test "a dispatch counts no rate-limit hit and no token use" do
      principal = principal_for(ApiTokenSecrets::MEMBER)
      Services::Api::RateLimiter.expects(:hit).never
      Services::Api::Tokens.expects(:record_use).never

      result = Mcp::Dispatcher.call(list_books, {}, principal: principal, request: outer_request)

      assert_equal 200, result.status
    end

    test "a body operation sends JSON" do
      result = dispatch(create_category, {name: "Mcp Test Genre", category_type: "genre"}, secret: ApiTokenSecrets::ADMIN)

      assert_equal 201, result.status
      assert_equal "Mcp Test Genre", result.body["data"]["name"]
    end

    test "an exception in the controller becomes internal_error with the request id, reported" do
      Api::V1::Books::BooksController.any_instance.stubs(:show).raises(RuntimeError, "boom")
      Rails.error.expects(:report).once

      result = dispatch(get_book, {slug: "anything"})

      assert_equal 500, result.status
      assert_equal({"code" => "internal_error", "detail" => "The tool failed unexpectedly.", "request_id" => "req-123"}, result.body)
      refute_includes result.body.to_json, "boom"
    end

    test "a no-route response has a nil body" do
      result = dispatch(operation(path: "/api/v1/nope"), {})

      assert_equal 404, result.status
      assert_nil result.body
    end
  end
end
