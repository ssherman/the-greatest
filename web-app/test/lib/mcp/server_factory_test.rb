require "test_helper"

module Mcp
  class ServerFactoryTest < ActiveSupport::TestCase
    def principal
      Api::Principal.new(user: users(:regular_user), token: nil, scopes: ["books:read"], tier: :member)
    end

    def build(domain: :books)
      Mcp::ServerFactory.build(
        document: :public, domain: domain, principal: principal,
        request: ActionDispatch::Request.new(Rack::MockRequest.env_for("https://dev-new.thegreatestbooks.org/api/mcp"))
      )
    end

    test "build registers the catalogue's tools for the principal plus the site's composites" do
      catalog = Mcp::Catalog.for(document: :public, domain: :books)

      assert_equal (catalog.tools_for(principal).map(&:name_value) + ["find_book"]).sort, build.tools.keys.sort
    end

    test "a principal without the composite's scopes is not offered it" do
      music_only = Api::Principal.new(user: users(:regular_user), token: nil, scopes: ["music:read"], tier: :member)
      server = Mcp::ServerFactory.build(
        document: :public, domain: :books, principal: music_only,
        request: ActionDispatch::Request.new(Rack::MockRequest.env_for("https://dev-new.thegreatestbooks.org/api/mcp"))
      )

      assert_not_includes server.tools.keys, "find_book"
    end

    test "the server is named for the domain" do
      assert_equal "the-greatest-books", build.name
    end

    test "the gem's argument validation is off" do
      assert_equal false, build.configuration.validate_tool_call_arguments
    end

    test "the server context carries the principal and request" do
      server = build

      assert_equal principal.scopes, server.server_context[:principal].scopes
      assert_kind_of ActionDispatch::Request, server.server_context[:request]
    end

    test "a domain with no registered site gets the empty one" do
      site = Mcp::Sites.for(:music)

      assert_nil site.instructions(:public)
      assert_equal [], site.prompts(:public)
      assert_equal [], site.resources(:public)
      assert_equal [], site.composites(:public)
    end
  end
end
