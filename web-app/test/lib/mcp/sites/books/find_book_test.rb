require "test_helper"

module Mcp
  module Sites
    module Books
      class FindBookTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @war = books_books(:war_and_peace)
        end

        def catalog = Mcp::Catalog.for(document: :public, domain: :books)

        def principal_for(secret)
          request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/api/mcp", "HTTP_AUTHORIZATION" => "Bearer #{secret}"))
          Services::Api::Authenticator.call(request).data
        end

        def outer_request
          env = Rack::MockRequest.env_for("https://dev-new.thegreatestbooks.org/api/mcp", "action_dispatch.request_id" => "req-1")
          env["action_dispatch.remote_ip"] = "203.0.113.9"
          ActionDispatch::Request.new(env)
        end

        def hits(*books) = books.map { |book| {id: book.id.to_s, score: 1.0, source: {}} }

        def find_book(title, secret: ApiTokenSecrets::MEMBER, **extra)
          arguments = title.nil? ? extra : {title: title}.merge(extra)
          response = Mcp::Sites::Books::FindBook.tool(catalog).call(
            **arguments, server_context: {principal: principal_for(secret), request: outer_request}
          )
          [response, JSON.parse(response.content.first[:text])]
        end

        test "a match returns the book and the lists it is on in one payload" do
          ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@war))

          response, payload = find_book("War and Peace")

          assert_equal false, response.error?
          assert_equal @war.slug, payload.dig("book", "slug")
          assert_kind_of Array, payload["lists"]
          assert_kind_of Integer, payload["lists_total_count"]
        end

        test "it searches for the top hit only and asks for up to 100 lists" do
          seen = []
          Mcp::Dispatcher.stubs(:call).with { |operation, args, **| seen << [operation.operation_id, args] }
            .returns(
              Mcp::Dispatcher::Response.new(status: 200, body: {"data" => [{"slug" => "war"}], "meta" => {}}),
              Mcp::Dispatcher::Response.new(status: 200, body: {"data" => {"slug" => "war"}}),
              Mcp::Dispatcher::Response.new(status: 200, body: {"data" => [], "meta" => {"total_count" => 0}})
            )

          find_book("war")

          assert_equal [
            ["searchBooks", {q: "war", limit: 1}],
            ["getBook", {slug: "war"}],
            ["listBookLists", {slug: "war", limit: 100}]
          ], seen
        end

        test "an unknown argument is an invalid_parameter error without dispatching" do
          Mcp::Dispatcher.expects(:call).never

          response, payload = find_book("war", bogus: 1)

          assert_equal true, response.error?
          assert_equal({"code" => "invalid_parameter", "detail" => "Unknown argument: bogus"}, payload)
        end

        test "a blank or missing title is an invalid_parameter error naming title" do
          Mcp::Dispatcher.expects(:call).never

          [find_book("  "), find_book(nil)].each do |response, payload|
            assert_equal true, response.error?
            assert_equal "invalid_parameter", payload["code"]
            assert_includes payload["detail"], "title"
            assert_not_includes payload["detail"], "q"
          end
        end

        test "no hits is a not_found error naming the title" do
          ::Search::Books::Search::BookGeneral.stubs(:call).returns([])

          response, payload = find_book("Nothing Like It")

          assert_equal true, response.error?
          assert_equal "not_found", payload["code"]
          assert_includes payload["detail"], "Nothing Like It"
        end

        test "a search outage is the search_unavailable error" do
          ::Search::Books::Search::BookGeneral.stubs(:call).raises(Faraday::ConnectionFailed.new("down"))

          response, payload = find_book("War and Peace")

          assert_equal true, response.error?
          assert_equal "search_unavailable", payload["code"]
        end

        test "a failing later step returns that step's error and stops" do
          Mcp::Dispatcher.stubs(:call).returns(
            Mcp::Dispatcher::Response.new(status: 200, body: {"data" => [{"slug" => "war"}]}),
            Mcp::Dispatcher::Response.new(status: 404, body: {"code" => "not_found", "detail" => "gone"})
          )

          response, payload = find_book("war")

          assert_equal true, response.error?
          assert_equal "gone", payload["detail"]
        end

        test "every operation a composite uses exists in its endpoint's catalogue" do
          Mcp::Sites::REGISTRY.each do |domain, site|
            site.composites(:public).each do |composite|
              composite_catalog = Mcp::Catalog.for(document: :public, domain: domain)
              composite.operation_ids.each { |id| assert composite_catalog.fetch(id), "#{composite} uses #{id}" }
            end
          end
        end

        test "it is visible to a books:read principal and not to a music:read-only one" do
          assert Mcp::Sites::Books::FindBook.visible_to?(principal_for(ApiTokenSecrets::MEMBER), catalog)
          assert_not Mcp::Sites::Books::FindBook.visible_to?(principal_for(ApiTokenSecrets::MUSIC_ONLY), catalog)
        end

        test "the tool is memoised per catalogue and named find_book" do
          tool = Mcp::Sites::Books::FindBook.tool(catalog)

          assert_same tool, Mcp::Sites::Books::FindBook.tool(catalog)
          assert_equal "find_book", tool.name_value
        end

        test "a different catalogue gets its own tool, kept for that catalogue" do
          other = Mcp::Catalog.new(::Api::OpenapiDocument.for_host(::Api::Host.base_url(:books), domain: :books, document: :public))
          tool = Mcp::Sites::Books::FindBook.tool(other)

          assert_not_same tool, Mcp::Sites::Books::FindBook.tool(catalog)
          assert_same tool, Mcp::Sites::Books::FindBook.tool(other)
        end
      end
    end
  end
end
